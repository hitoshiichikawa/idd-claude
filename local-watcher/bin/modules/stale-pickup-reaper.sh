#!/usr/bin/env bash
# stale-pickup-reaper.sh — watcher の Stale Pickup Reaper モジュール
#
# 用途:
#   watcher セッションがクラッシュ / OOM / マシン再起動などで異常終了したとき、
#   `claude-picked-up` / `claude-claimed` ラベルが Issue に残り続け、dispatcher が
#   「処理中」とみなして候補から永久除外する停止状態を、3 観点（marker 経過時間 /
#   slot ロック保持 / セッション存在）の AND 判定で「非アクティブ」と確定した Issue
#   についてのみ `auto-dev` 状態へ自動復帰させる Stale Pickup Reaper を集約する。
#   failed-recovery (#359) が `claude-failed` のみを扱う構造の gap を埋める位置付け。
#
#   - sr_is_enabled    : 単独 opt-in gate（STALE_PICKUP_REAPER_ENABLED=true 厳密一致）
#   - sr_marker_path   : marker JSON の絶対パスを返す純粋関数
#   - sr_load_marker   : marker JSON 読み出し（不在 / parse 失敗で `{}` を返す fail-open）
#   - sr_save_marker   : marker JSON の atomic write（mktemp → mv -f）
#
#   - sr_fetch_candidates  : 候補列挙（label filter / claude-picked-up + claude-claimed）
#
#   後続 task で以下を追加予定（task 4 以降）:
#   - sr_check_marker_age / sr_check_slot_lock / sr_check_session / sr_is_active
#   - sr_revert_to_auto_dev : ラベル除去 + auto-dev 残存確認
#   - process_stale_pickup_reaper : watcher 本体からの単一エントリ
#
# 配置先:
#   $HOME/bin/modules/stale-pickup-reaper.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（sr_log / sr_warn / sr_error）は core_utils.sh にあるため本モジュールでは
#     再定義しない（task 1 で追加済み）。
#   - グローバル変数（$STALE_PICKUP_REAPER_ENABLED / $STALE_PICKUP_REAPER_THRESHOLD_MINUTES /
#     $STALE_PICKUP_REAPER_STATE_DIR / $STALE_PICKUP_REAPER_MAX_ISSUES /
#     $STALE_PICKUP_REAPER_GH_TIMEOUT）は本体冒頭の Config ブロックで定義済み
#     （task 1 で追加済み）。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: jq / mktemp（永続化レイヤ）/ gh / date / flock / fuser / lsof（後続 task）。
#   - 関数 prefix `sr_` を namespace として採用する。
#
# セットアップ参照先:
#   README.md（オプション機能一覧 / Stale Pickup Reaper 節）/ install.sh（配置ロジック）
#   設計参照: docs/specs/379-feat-watcher-claude-picked-up-issue-reap/design.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Stale Pickup Reaper の単独 opt-in gate（純粋関数 / 副作用なし / Req 1.1〜1.4 /
# NFR 1.1）。`STALE_PICKUP_REAPER_ENABLED=true` 厳密一致のときのみ 0 を返し、それ以外
# （未設定 / 空 / `false` / 0 / True / TRUE / 1 / on / yes / 前後空白 / typo 等）は
# 1 を返して OFF として扱う。Config ブロック側 `case` で値は既に `true` / `false` に
# 正規化されているが、本関数も二重防御として `=true` のみ enabled として読む。
#
# failed-recovery の `fr_is_enabled` と異なり、FULL_AUTO_ENABLED は要求しない単独 gate
# である（design.md "FULL_AUTO_ENABLED 配下に置くか単独 gate か" の判定根拠 1〜3）。
#
# Returns:
#   0 = enabled（処理可）
#   1 = disabled（処理しない）
sr_is_enabled() {
  [ "${STALE_PICKUP_REAPER_ENABLED:-false}" = "true" ] || return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Persistence Layer
#
# 各候補 Issue ごとに 1 ファイルの marker JSON を
# $STALE_PICKUP_REAPER_STATE_DIR/<issue>.json に保存する。failed-recovery (#359) の
# state schema と同じ atomic write + repo-slug 分離方針を採用する（NFR 2.3）。
#
# JSON schema（design.md "Marker State Model" 節）:
#   {
#     "issue": <int>,
#     "first_seen_at": "<ISO 8601 UTC>",
#     "last_seen_at":  "<ISO 8601 UTC>",
#     "last_known_labels": ["claude-picked-up", "auto-dev", ...],
#     "status": "observing" | "reverted",
#     "revert_at": "<ISO 8601 UTC or empty>"
#   }
#
#   - first_seen_at: SPR が当該 Issue の pickup ラベル滞留を最初に観測した時刻
#                    （= タイムスタンプ marker の起算点）
#   - last_seen_at:  直近の観測時刻（毎サイクル更新）
#   - status:        observing（観測中）/ reverted（既に SPR が auto-dev へ戻した）
#   - revert_at:     revert 実施時刻（status=reverted のときのみ非空、observing は空文字）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Args: $1 = issue number
# Stdout: 絶対パス（$STALE_PICKUP_REAPER_STATE_DIR/<issue>.json）
# Returns: 0（常に）
sr_marker_path() {
  local issue_number="$1"
  printf '%s/%s.json' "$STALE_PICKUP_REAPER_STATE_DIR" "$issue_number"
}

# Issue 番号に対応する marker JSON を stdout に出力する（NFR 2.2 / NFR 2.3）。
# ファイル不在 / JSON parse 失敗時は安全側 fallback として `{}` を返し、呼出側は
# 既定値（first_seen_at=now, last_known_labels=[] 等）で初期化できる（fail-open）。
#
# Args: $1 = issue number
# Stdout: JSON 全体（不在 / 破損時は `{}`）
# Returns: 0（常に）
sr_load_marker() {
  local issue_number="$1"
  local marker_file
  marker_file=$(sr_marker_path "$issue_number")
  if [ ! -f "$marker_file" ]; then
    printf '%s' "{}"
    return 0
  fi
  # jq -e で parse 失敗時は非 0 終了 → `{}` で fallback
  local content
  if ! content=$(jq -c '.' "$marker_file" 2>/dev/null); then
    printf '%s' "{}"
    return 0
  fi
  printf '%s' "$content"
  return 0
}

# marker JSON を atomic write で永続化する（NFR 2.3 / NFR 3.1）。`mkdir -p` で
# state_dir を冪等確保し、同一 dir 上の `mktemp` で temp file を作成して `mv -f` で
# atomic rename することで、read-modify-write 中の中断でも破損ファイルを残さない。
# すべての値を `jq --arg` / `--argjson` で sanitize（NFR 3.1）。
#
# Args:
#   $1 = issue number (int)
#   $2 = first_seen_at (ISO 8601 UTC string)
#   $3 = last_seen_at  (ISO 8601 UTC string)
#   $4 = labels_json   (JSON array string, 例: '["claude-picked-up","auto-dev"]')
#   $5 = status        (enum: "observing" | "reverted")
#   $6 = revert_at     (ISO 8601 UTC string、status=observing 時は空文字)
#
# 副作用:
#   - $STALE_PICKUP_REAPER_STATE_DIR を mkdir -p で作成（既存なら no-op）
#   - marker JSON ファイルを atomic に書き換える
#
# Returns: 0 = persisted, 1 = failure (呼出側を落とさない / sr_warn で警告)
sr_save_marker() {
  local issue_number="$1"
  local first_seen_at="$2"
  local last_seen_at="$3"
  local labels_json="$4"
  local status="$5"
  local revert_at="$6"

  # state_dir を冪等確保（既存なら no-op、所有者は cron 実行ユーザー）
  if ! mkdir -p "$STALE_PICKUP_REAPER_STATE_DIR" 2>/dev/null; then
    sr_warn "sr_save_marker: mkdir -p \"$STALE_PICKUP_REAPER_STATE_DIR\" 失敗"
    return 1
  fi

  local marker_file
  marker_file=$(sr_marker_path "$issue_number")

  # labels_json が空 / 非 JSON 配列なら空配列で正規化（NFR 3.1 / fail-safe）。
  # 呼出側が `[]` 既定を渡すケースに加え、想定外入力（空文字 / null / 非配列値）に
  # 対する保険として正規化する。`jq` は空入力に対しても rc=0 で空出力を返すため、
  # 空出力もここで `[]` に倒す（後続 `--argjson` が空文字で失敗するのを防ぐ）。
  local labels_normalized=""
  if [ -n "$labels_json" ]; then
    labels_normalized=$(printf '%s' "$labels_json" | jq -c 'if type == "array" then . else [] end' 2>/dev/null) || labels_normalized=""
  fi
  if [ -z "$labels_normalized" ]; then
    labels_normalized="[]"
  fi

  # marker JSON を組み立てる（全値 --arg / --argjson 経由 / NFR 3.1）。
  local new_marker
  if ! new_marker=$(jq -n \
      --argjson issue "$issue_number" \
      --arg first_seen_at "$first_seen_at" \
      --arg last_seen_at "$last_seen_at" \
      --argjson last_known_labels "$labels_normalized" \
      --arg status "$status" \
      --arg revert_at "$revert_at" \
      '{
        issue: $issue,
        first_seen_at: $first_seen_at,
        last_seen_at: $last_seen_at,
        last_known_labels: $last_known_labels,
        status: $status,
        revert_at: $revert_at
      }' 2>/dev/null); then
    sr_warn "sr_save_marker: JSON 組み立て失敗 issue=$issue_number"
    return 1
  fi

  # atomic write: 同一 dir に temp file → mv -f で rename
  local tmp_file
  if ! tmp_file=$(mktemp "${marker_file}.XXXXXX" 2>/dev/null); then
    sr_warn "sr_save_marker: mktemp 失敗 issue=$issue_number"
    return 1
  fi
  if ! printf '%s\n' "$new_marker" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    sr_warn "sr_save_marker: temp file 書き込み失敗 issue=$issue_number"
    return 1
  fi
  if ! mv -f "$tmp_file" "$marker_file" 2>/dev/null; then
    rm -f "$tmp_file"
    sr_warn "sr_save_marker: atomic rename 失敗 issue=$issue_number"
    return 1
  fi
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Candidate Selection Layer
#
# `claude-picked-up` / `claude-claimed` ラベルが残ったままの open Issue を server-side
# filter で列挙し、Stale Pickup Reaper の入力となる候補集合を返す。failed-recovery
# (#359) の `fr_fetch_failed_issues` と同方針の 4 段ガード（timeout / JSON 検証 /
# 空入力 / 非 array fallback）を踏襲し、取得失敗時は空 JSON 配列 `[]` を返して
# `sr_warn` 1 行で警告（fail-continue）。
#
# 関連 AC:
#   - Req 2.1: claude-picked-up ラベル付き Issue を走査対象とする
#   - Req 2.2: claude-claimed ラベル付き Issue も走査対象に含める
#   - Req 2.3: 人間判断待ちラベル（needs-decisions / awaiting-design-review /
#              needs-quota-wait / blocked / staged-for-release / hold）を server-side
#              filter で除外
#   - Req 2.4: claude-failed Issue は failed-recovery の領分のため除外
#   - Req 2.5: server-side label filter のみで走査する（client-side filter 不使用）
#   - NFR 1.2: `--repo` / `--state open` で対象範囲を明示し既存 dispatcher と整合
#   - NFR 3.1: 既存 `LABEL_*` 定数を参照し未定義ラベル文字列の inline 展開を避ける
#   - NFR 5.2: 取得失敗時も非破壊（sr_warn + `[]` 返却 / fail-continue）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# sr_fetch_candidates: claude-picked-up / claude-claimed Issue 群を列挙する。
#
# 仕様:
#   - 2 クエリを発行する（`gh --search` の `label:"A" OR label:"B"` 構文は
#     server-side で安定しないため、1 次条件を分けて発行し jq で結合する方式を
#     採用 / failed-recovery と異なる点）。
#     クエリ 1: `label:"$LABEL_PICKED"` + 除外条件
#     クエリ 2: `label:"$LABEL_CLAIMED"` + 除外条件
#   - 除外条件（両クエリ共通 / Req 2.3, 2.4）:
#       -label:"$LABEL_FAILED"
#       -label:"$LABEL_NEEDS_DECISIONS"
#       -label:"$LABEL_AWAITING_DESIGN"
#       -label:"$LABEL_NEEDS_QUOTA_WAIT"
#       -label:"$LABEL_BLOCKED"
#       -label:"$LABEL_STAGED_FOR_RELEASE"
#       -label:"hold"   # LABEL_HOLD 定数は未定義のため literal で渡す（design.md 準拠）
#   - 取得後、jq で 2 結果を結合 + `unique_by(.number)` で dedup し、`--limit
#     "$STALE_PICKUP_REAPER_MAX_ISSUES"` で truncate（jq 側で `.[0:N]`）。
#   - `timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT"` で外部呼び出しを保護。
#   - 取得失敗（timeout / gh エラー / 非 JSON / 空文字）時は `sr_warn` 1 行 + `[]` 返却。
#
# Stdout: JSON 配列文字列（候補なし / 取得失敗時は `[]`）
# Returns: 0（常に。fail-continue）
sr_fetch_candidates() {
  local exclude_filter
  exclude_filter="-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"hold\""

  # クエリ 1: claude-picked-up 候補
  local picked_json
  if ! picked_json=$(timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_PICKED\" $exclude_filter" \
      --json number,labels,title,url,updatedAt \
      --limit "$STALE_PICKUP_REAPER_MAX_ISSUES" 2>/dev/null); then
    sr_warn "sr_fetch_candidates: gh issue list 失敗（label:$LABEL_PICKED / timeout または API エラー）"
    echo "[]"
    return 0
  fi
  # 空文字 / 非 JSON は安全側で `[]` に正規化（fr_fetch_failed_issues と同パターン）
  if [ -z "$picked_json" ]; then
    picked_json="[]"
  fi
  if ! printf '%s' "$picked_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    sr_warn "sr_fetch_candidates: gh issue list が JSON 配列を返さなかった（label:$LABEL_PICKED）"
    picked_json="[]"
  fi

  # クエリ 2: claude-claimed 候補
  local claimed_json
  if ! claimed_json=$(timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_CLAIMED\" $exclude_filter" \
      --json number,labels,title,url,updatedAt \
      --limit "$STALE_PICKUP_REAPER_MAX_ISSUES" 2>/dev/null); then
    sr_warn "sr_fetch_candidates: gh issue list 失敗（label:$LABEL_CLAIMED / timeout または API エラー）"
    echo "[]"
    return 0
  fi
  if [ -z "$claimed_json" ]; then
    claimed_json="[]"
  fi
  if ! printf '%s' "$claimed_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    sr_warn "sr_fetch_candidates: gh issue list が JSON 配列を返さなかった（label:$LABEL_CLAIMED）"
    claimed_json="[]"
  fi

  # 2 結果を結合 + dedup + truncate（jq で完結 / NFR 3.1: --argjson 経由）
  local merged_json
  if ! merged_json=$(jq -n -c \
      --argjson picked "$picked_json" \
      --argjson claimed "$claimed_json" \
      --argjson limit "$STALE_PICKUP_REAPER_MAX_ISSUES" \
      '($picked + $claimed) | unique_by(.number) | .[0:$limit]' 2>/dev/null); then
    sr_warn "sr_fetch_candidates: jq 結合 / dedup 失敗"
    echo "[]"
    return 0
  fi
  printf '%s' "$merged_json"
  return 0
}
