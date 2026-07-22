#!/usr/bin/env bash
# shellcheck shell=bash
# model-router.sh — watcher のモデルルーティングモジュール (#507, Phase 1)
#
# 用途:
#   Triage が出力した変更規模判定 `complexity` を安全に解釈し、`size:<complexity>`
#   ラベルとして Issue に冪等・fail-open で永続化する。ラベルに永続化することで、
#   Triage を再実行しないサイクル（impl-resume / PR Iteration / Failed Recovery）でも
#   判定結果を sticky に参照でき、人間が事前にラベルを貼ることで判定を override できる。
#   mr_is_enabled / mr_parse_triage_complexity / mr_has_size_label /
#   mr_persist_size_label ほか。
#
#   本 Phase（#507）はサイズ判定の永続化までを担当し、判定結果を使ったモデル解決
#   （Phase 2 / #508）と分割提案（Phase 3 / #509）は含まない。gate は Phase 共通の
#   単一変数 `MODEL_ROUTING_ENABLED` とし、Phase 別 gate は設けない（Req 3.6）。
#
# 配置先:
#   $HOME/bin/modules/model-router.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー mr_log / mr_warn は本モジュール内で定義する（新規 module のため。
#     path-overlap.sh の po_log / po_warn と同型）。
#   - グローバル変数（$REPO / $MODEL_ROUTING_ENABLED）は watcher-config.sh の Config
#     ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - slot-worker.sh の Triage 消費部（Triage 直後の 1 箇所のみ）から呼ばれる。
#   - 外部 CLI: gh / jq。
#
# 関数 prefix: mr_
#
# セットアップ参照先:
#   - 設計: docs/specs/507-feat-watcher-triage-complexity-size-phas/design.md
#   - README「Model Routing Phase 1: Triage complexity → size ラベル (#507)」節

mr_log() {
  echo "[$(date '+%F %T')] [$REPO] model-router: $*"
}
mr_warn() {
  echo "[$(date '+%F %T')] [$REPO] model-router: WARN: $*" >&2
}

# ラベル prefix リテラル。命名変更時の変更点を局所化するため、`size:` の literal は
# 本モジュール内では mr_has_size_label の既定引数と mr_persist_size_label のラベル名
# 構成部の 2 箇所にのみ出現させる（design.md「実装方針メモ」）。

# ─── Phase 1: opt-in Gate (#507 Req 3.1〜3.3) ───
# モデルルーティング機能 family の opt-in gate。`MODEL_ROUTING_ENABLED` が
# リテラル `true` に厳密一致するときのみ rc=0（有効）を返す。
#
# 未設定 / 空 / `false` / `off` / `True` / `1` / typo はすべて安全側（無効）へ正規化する
# （Req 3.1 / 3.3）。既存 gate 慣習（PATH_OVERLAP_CHECK の `= "true"` 厳密一致）と同型。
#
# Args: なし
# Return: 0 = 有効 / 1 = 無効
mr_is_enabled() {
  [ "${MODEL_ROUTING_ENABLED:-false}" = "true" ]
}

# ─── Phase 1: Triage Complexity Parser (#507 Req 2.3 / 2.4 / 5.1) ───
# Triage 結果 JSON から `complexity` を fail-safe に抽出する純粋関数。
# - key 不在 / null / 文字列以外（数値・配列・object・真偽値）→ 空文字
# - 許可値（small / medium / large）以外（`huge` / `SMALL` / 前後空白付き / 注入狙い）→ 空文字
# - ファイル不在 / 不正 JSON / jq 失敗 → 空文字
# 既存 key 抽出（jq -r '.status' 等）は一切変更しない（Req 2.1 / 2.5）。
#
# Args: $1 = Triage 結果 JSON ファイルパス
# Stdout: 正規化済み complexity（small|medium|large）または空文字
# Return: 0 always（失敗時も空文字を返す fail-safe / Req 2.4）
mr_parse_triage_complexity() {
  local triage_file="$1"
  if [ ! -f "$triage_file" ]; then
    echo ""
    return 0
  fi
  # `.complexity` が文字列型のときのみ値を採り、それ以外（key 不在 / null / 非文字列）は
  # 空文字へ倒す。jq 自体の失敗（不正 JSON 等）も `|| echo ""` で吸収する
  # （po_parse_triage_edit_paths と同型の fail-safe）。
  local raw
  raw=$(jq -r '
    if (.complexity | type) == "string" then
      .complexity
    else
      ""
    end
  ' "$triage_file" 2>/dev/null || echo "")

  # 許可値集合との厳密一致で正規化する（前後空白付き / 大文字 / 未知の値はすべて空文字）。
  case "$raw" in
    small|medium|large) echo "$raw" ;;
    *) echo "" ;;
  esac
  return 0
}

# ─── Phase 1: Existing Size Label Detector (#507 Req 4.2 / 4.3 / 5.4) ───
# `gh issue view --json labels` の JSON から、指定 prefix を持つラベルの有無を判定する。
# 人間が付与した size ラベルと過去の Triage が付与した size ラベルは区別しない
# （先に存在するラベルを優先する / Req 4.3）。
#
# prefix は `jq --arg` で束縛し、フィルタ文字列へ未信頼値を inline 展開しない（NFR 4.2）。
# jq 失敗 / 非数値（JSON 解析不能）は rc=2（判定不能）へ倒し、呼び出し側で安全側
# （付与しない）に扱わせる（Req 5.4）。
#
# Args: $1 = labels JSON（`{"labels":[{"name":"..."}]}`）, $2 = ラベル prefix（既定 `size:`）
# Return: 0 = 既存あり / 1 = なし / 2 = 判定不能
mr_has_size_label() {
  local labels_json="$1"
  local prefix="${2:-size:}"
  local count
  count=$(printf '%s' "$labels_json" | jq -r --arg p "$prefix" '
    [.labels[]?.name // empty]
    | map(select(startswith($p)))
    | length
  ' 2>/dev/null || echo "")
  # jq 失敗（空文字）/ 非数値は判定不能として rc=2（安全側 / Req 5.4）。
  case "$count" in
    ''|*[!0-9]*) return 2 ;;
  esac
  [ "$count" -gt 0 ] && return 0
  return 1
}

# ─── Phase 1: Size Label Persister (#507 Req 4.1〜4.4 / 4.7 / 5.1〜5.6) ───
# Triage が返した complexity に対応する `size:<complexity>` ラベルを Issue へ付与する。
# 既存 `size:*` ラベルが 1 つ以上あれば追加・付け替え・削除のいずれも行わない
# （Req 4.2 / 4.3 / 4.4）。`--add-label` のみを使い `--remove-label` を持たないため、
# 既存のラベル遷移契約（claude-claimed 等）には構造的に一切触れない（Req 5.5）。
#
# 未信頼値（LLM 出力の complexity）は **ラベル名構成の直前** に許可値集合との
# `case` 厳密一致で検証する（Req 5.2 / NFR 4.1）。`gh` へは変数をクォートし
# `--add-label -- "size:<complexity>"` と `--` でオプション解釈を打ち切る（NFR 4.2）。
# `complexity_reason` はラベル名の構成に用いない（NFR 4.3）。
#
# gh 呼び出し回数は labels 取得 1 回 + 付与 1 回の計 2 回以下、gate 無効時は 0 回
# （NFR 3.1 / 3.2）。silent fail を作らず全 rc 分岐でログを 1 行残す（Req 5.6 / NFR 2.2）。
#
# Args: $1 = issue number, $2 = complexity（Triage 由来 / 未検証の未信頼値）
# Return:
#   0 = 付与成功（mr_log / Req 4.1, NFR 2.1）
#   1 = gate 無効（defense-in-depth。ログ・API ともゼロ / Req 3.4, NFR 1.1）
#   2 = complexity が欠落 / 不正値（mr_warn。API 呼び出しゼロ / Req 5.1, 5.2）
#   3 = 既存 size:* あり（mr_log で skip 理由を明示 / Req 4.2, 4.3, 4.4, 4.7）
#   4 = labels 取得失敗 / JSON 解析不能（mr_warn。付与しない安全側 / Req 5.4）
#   5 = ラベル付与失敗（mr_warn。呼び出し側は継続 / Req 5.3）
# 呼び出し側は rc を分岐に使わず無条件に吸収する（ログは本関数側で完結して出す）。
mr_persist_size_label() {
  local issue_number="$1"
  local complexity="${2:-}"

  # rc=1: gate 二重防御。gate 無効時は導入前と同一（ログ 0 行 / gh 0 回）に倒す
  # （Req 3.4 / NFR 1.1）。呼び出し側でも gate するが fail-safe に再確認する。
  mr_is_enabled || return 1

  # rc=2: 未信頼値の厳密一致検証（Req 5.1 / 5.2 / NFR 4.1）。ここを通過した値のみを
  # ラベル名の構成に用いる。API 呼び出しは一切行わない。
  case "$complexity" in
    small|medium|large) ;;
    *)
      mr_warn "issue=#${issue_number} complexity が欠落または不正なため size ラベルを付与しません（value=$(printf '%q' "$complexity")）"
      return 2
      ;;
  esac

  # 既存ラベル一覧を取得（gh 呼び出し 1 回目 / NFR 3.1）。
  # rc=4: 取得失敗は誤った上書きを避けるため付与しない安全側へ倒す（Req 5.4）。
  local labels_json
  if ! labels_json=$(gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    mr_warn "issue=#${issue_number} 既存ラベル一覧の取得に失敗したため size ラベルを付与しません（安全側 / 次回 Triage で再評価）"
    return 4
  fi

  # rc=3 / rc=4: 既存 size:* ラベルの有無を判定する。
  local has_rc=0
  mr_has_size_label "$labels_json" "size:" || has_rc=$?
  case "$has_rc" in
    0)
      # 既存あり → 追加・付け替え・削除のいずれも行わない（Req 4.2 / 4.3 / 4.4）。
      # skip 理由を判別できるログを残す（Req 4.7 / NFR 2.2）。
      mr_log "issue=#${issue_number} size ラベル付与を skip（既存 size:* ラベルあり / 人間 override・過去 Triage 由来を区別せず先に存在するラベルを優先）"
      return 3
      ;;
    1)
      : # 既存なし → 付与へ進む
      ;;
    *)
      mr_warn "issue=#${issue_number} 既存ラベル一覧の JSON 解析に失敗したため size ラベルを付与しません（安全側 / 次回 Triage で再評価）"
      return 4
      ;;
  esac

  # ラベル名の構成（許可値検証済みの値のみを使用 / Req 5.2）。
  local label_name="size:${complexity}"

  # rc=5: 付与失敗（API 不達 / レート制限 / 権限不足 / 対象ラベル未定義等）は WARN を
  # 残して呼び出し側の処理を継続させる（fail-open / Req 5.3）。
  # gh 呼び出し 2 回目（NFR 3.1）。`--` でオプション解釈を打ち切る（NFR 4.2）。
  if ! gh issue edit "$issue_number" --repo "$REPO" --add-label -- "$label_name" >/dev/null 2>&1; then
    mr_warn "issue=#${issue_number} size ラベルの付与に失敗しました label=${label_name}（対象ラベル未定義の可能性: idd-claude-labels.sh の再実行を検討 / 処理は継続）"
    return 5
  fi

  # rc=0: 付与成功。Issue 番号と確定した complexity 値をログに残す（Req 4.1 / NFR 2.1）。
  mr_log "issue=#${issue_number} size ラベルを付与しました complexity=${complexity} label=${label_name}"
  return 0
}
