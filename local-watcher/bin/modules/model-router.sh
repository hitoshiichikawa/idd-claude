#!/usr/bin/env bash
# shellcheck shell=bash
# model-router.sh — watcher のモデルルーティングモジュール (#507 Phase 1 / #508 Phase 2)
#
# 用途:
#   Phase 1 (#507): Triage が出力した変更規模判定 `complexity` を安全に解釈し、
#   `size:<complexity>` ラベルとして Issue に冪等・fail-open で永続化する。ラベルに
#   永続化することで、Triage を再実行しないサイクル（impl-resume / PR Iteration /
#   Failed Recovery）でも判定結果を sticky に参照でき、人間が事前にラベルを貼ることで
#   判定を override できる。mr_is_enabled / mr_parse_triage_complexity /
#   mr_has_size_label / mr_persist_size_label。
#
#   Phase 2 (#508): 永続化された `size:*` ラベルから当該 Issue の Developer 実行モデル ID を
#   決める **解決規則**（副作用なしの純粋関数）を提供する。mr_extract_size_label /
#   mr_resolve_dev_model。gate 判定・`DEV_MODEL` への適用・ログ出力は呼び出し側
#   （slot-worker.sh の Slot Runner = `_slot_apply_dev_model_routing`）が担い、本 module 側は
#   「size 値と設定値からモデル ID を決める」責務のみを持つ（#508 Req 1.7 / 1.8）。
#
#   分割提案（Phase 3 / #509）は含まない。gate は Phase 共通の単一変数
#   `MODEL_ROUTING_ENABLED` とし、Phase 別 gate は設けない（#507 Req 3.6 / #508 Req 5.1）。
#
# 配置先:
#   $HOME/bin/modules/model-router.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー mr_log / mr_warn は本モジュール内で定義する（新規 module のため。
#     path-overlap.sh の po_log / po_warn と同型）。
#   - グローバル変数（$REPO / $MODEL_ROUTING_ENABLED / $DEV_MODEL / $DEV_MODEL_SMALL /
#     $DEV_MODEL_MEDIUM）は watcher-config.sh の Config ブロックで定義済み。bash の
#     遅延束縛により呼び出し時に解決される。
#   - slot-worker.sh から呼ばれる（Phase 1: Triage 消費部の 1 箇所 / Phase 2: Slot Runner
#     `_slot_run_issue` 冒頭の 1 箇所）。
#   - 外部 CLI: gh / jq（Phase 1 の永続化系のみ。Phase 2 の解決系は外部コマンドを使わない）。
#
# 関数 prefix: mr_
#
# セットアップ参照先:
#   - 設計: docs/specs/507-feat-watcher-triage-complexity-size-phas/design.md
#   - 要件: docs/specs/508-feat-watcher-size-developer-phase-2/requirements.md
#   - README「Model Routing Phase 1: Triage complexity → size ラベル (#507)」節
#   - README「Model Routing Phase 2: size ラベル → Developer モデル (#508)」節

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
# `case` 厳密一致で検証する（Req 5.2 / NFR 4.1）。`gh` へは変数をクォートし、
# `--add-label="size:<complexity>"` の `=` 束縛形で値をフラグへ構文的に束縛して
# オプション解釈を封じる（NFR 4.2 / 理由は下記 gh 呼び出し箇所のコメント参照）。
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

  # rc=3 / rc=4: 既存ラベルの有無を判定する。prefix は mr_has_size_label の既定引数に
  # 委ねる（literal をここで再掲すると命名変更時の変更点が増えるため / design.md）。
  local has_rc=0
  mr_has_size_label "$labels_json" || has_rc=$?
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
  # gh 呼び出し 2 回目（NFR 3.1）。
  #
  # NFR 4.2（オプション解釈の打ち切り）は `--add-label=<値>` の **`=` 束縛形**で満たす。
  # `gh`（cobra/pflag）は値を取るフラグの直後の引数を無条件に値として消費するため、
  # `--add-label -- "$label_name"` と書くと `--` 自体が `--add-label` の値として消費され、
  # ラベル名が 2 つ目の positional 引数として残って `invalid issue format` で必ず失敗する
  # （実機 gh 2.96.0 で確認 / design.md 196・298・384 の記述からの意図的な逸脱。詳細は
  # impl-notes.md「確認事項」）。`=` 形は値をフラグへ構文的に束縛するため、値が `-` で
  # 始まってもフラグとして解釈される余地がない。
  # なお `complexity` は上の `case` で許可値 3 種に厳密一致検証済みのため、ラベル名が
  # `-` 始まりになること自体が構造的にあり得ない（Req 5.2 / NFR 4.1 で担保）。
  if ! gh issue edit "$issue_number" --repo "$REPO" --add-label="$label_name" >/dev/null 2>&1; then
    mr_warn "issue=#${issue_number} size ラベルの付与に失敗しました label=${label_name}（対象ラベル未定義の可能性: idd-claude-labels.sh の再実行を検討 / 処理は継続）"
    return 5
  fi

  # rc=0: 付与成功。Issue 番号と確定した complexity 値をログに残す（Req 4.1 / NFR 2.1）。
  mr_log "issue=#${issue_number} size ラベルを付与しました complexity=${complexity} label=${label_name}"
  return 0
}

# ─── Phase 2: Size Label Extractor (#508 Req 3.2〜3.5 / NFR 3.1 / 3.2) ───
# slot 起動時点で取得済みの Issue ラベル集合（`jq -r '.labels[].name'` 由来の改行区切り
# リスト）から、`^size:(small|medium|large)$` に **厳密一致** するラベルがちょうど 1 つ
# 存在する場合に限り size 値を stdout へ返す純粋関数。
#
# 未信頼入力（Issue ラベル名）は外部コマンドへ一切渡さず、bash の `case` による完全一致
# のみで検証する（grep / sed を経由しないため、`-` 始まりのラベル名によるオプション注入も
# 正規表現メタ文字の解釈も構造的に発生しない / NFR 3.1 / 3.2）。
#
# 副作用を持たず、同一入力に対して常に同一の出力を返す（Req 1.7 / 1.8 と同じ性質）。
# 判定不能・fail-safe のケースは stdout を空にし、rc で理由を返す（呼び出し側がログの
# fallback 理由を判別できるようにするため / Req 6.2）。
#
# Args: $1 = ラベル名の改行区切りリスト
# Stdout: 厳密一致した size 値（small|medium|large）。それ以外のケースでは無出力。
# Return:
#   0 = size 値を 1 つ確定（Req 3.2）
#   1 = `size:` prefix を持つラベルが 0 件（Req 3.3）
#   2 = `size:` prefix を持つラベルが 2 件以上（採用しない / Req 3.4）
#   3 = `size:` prefix ラベルが 1 件だが厳密一致に失敗（`size:huge` / `size:Small` /
#       末尾に空白を含む 等 / Req 3.5）
# 注: 先頭に空白を含むラベル（` size:small`）は prefix 判定に一致しないため rc=1
#     （0 件）へ倒れる。いずれの rc でも呼び出し側の適用結果は `DEV_MODEL` で同一。
mr_extract_size_label() {
  local labels="${1:-}"
  local line candidate="" count=0

  while IFS= read -r line; do
    case "$line" in
      "size:"*) ;;
      *) continue ;;
    esac
    count=$((count + 1))
    candidate="$line"
  done <<<"$labels"

  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    return 2
  fi

  # 許可値集合との完全一致（= `^size:(small|medium|large)$` の厳密一致 / Req 3.2）。
  case "$candidate" in
    "size:small") echo "small" ;;
    "size:medium") echo "medium" ;;
    "size:large") echo "large" ;;
    *) return 3 ;;
  esac
  return 0
}

# ─── Phase 2: Developer Model Resolver (#508 Req 1.1〜1.8) ───
# size 値と設定値から Developer 実行モデル ID を決める **解決規則そのもの**（the Model
# Router）。副作用を一切持たず（GitHub API / ラベル変更 / ファイル書き込み / 呼び出し元の
# 状態変更のいずれも行わない）、解決結果のみを stdout へ出力する（Req 1.7）。
#
# 解決規則:
#   small  かつ DEV_MODEL_SMALL  が非空 → DEV_MODEL_SMALL   （Req 1.1）
#   medium かつ DEV_MODEL_MEDIUM が非空 → DEV_MODEL_MEDIUM  （Req 1.2）
#   large                               → DEV_MODEL         （Req 1.3 / `DEV_MODEL_LARGE` は持たない）
#   許可値以外 / 空 / 未指定             → DEV_MODEL         （fail-safe / Req 1.4）
#   size 値に対応する設定が未設定・空文字 → DEV_MODEL         （Req 1.5）
#
# 設定された値は許可値リストとの照合・変換・補完のいずれも行わずそのまま返す
# （モデル ID の許可値リストを持たない / Req 1.6）。同一入力（size 値 + DEV_MODEL /
# DEV_MODEL_SMALL / DEV_MODEL_MEDIUM）に対して常に同一の結果を返す（Req 1.8）。
#
# gate（MODEL_ROUTING_ENABLED）は **本関数では判定しない**。Req 1.8 が解決結果の入力を
# 上記 4 値に限定しており、gate を解決規則へ持ち込むと決定性の定義がぶれるため。gate 無効時
# に「読み取りも解決も行わない」責務は Req 5.2 / 5.3 のとおり Slot Runner 側にある
# （呼び出し側 `_slot_apply_dev_model_routing` が gate 判定して本関数を呼ばない）。
#
# Args: $1 = size 値（small|medium|large|それ以外|空）
# Stdout: 適用すべき Developer モデル ID（DEV_MODEL 未設定という想定外状態では空文字）
# Return: 0 always（fail-safe。呼び出し側は rc を分岐に使わない）
mr_resolve_dev_model() {
  local size="${1:-}"

  case "$size" in
    small)
      if [ -n "${DEV_MODEL_SMALL:-}" ]; then
        printf '%s\n' "$DEV_MODEL_SMALL"
        return 0
      fi
      ;;
    medium)
      if [ -n "${DEV_MODEL_MEDIUM:-}" ]; then
        printf '%s\n' "$DEV_MODEL_MEDIUM"
        return 0
      fi
      ;;
    large)
      : # large は常に DEV_MODEL（専用設定値を設けない / Req 1.3）
      ;;
    *)
      : # 許可値以外 / 空文字 / 未指定 → fail-safe（Req 1.4）
      ;;
  esac

  # Req 1.3 / 1.4 / 1.5 の合流点。DEV_MODEL 自体が未設定という想定外状態では空文字を返し、
  # 呼び出し側が「再代入しない」判断をできるようにする（fail-open / Req 5.6）。
  printf '%s\n' "${DEV_MODEL:-}"
  return 0
}
