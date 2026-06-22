#!/usr/bin/env bash
# failed-recovery.sh — watcher の Failed Recovery Processor モジュール
#
# 用途:
#   `claude-failed` ラベル付き Issue（reviewer-reject 由来も含む）と auto-merge 待ち
#   PR の CI 失敗を、fresh Claude session で自動解析・修正して開発を再開させる
#   Failed Recovery Processor を集約する。Issue 単位の **通算 attempt budget**
#   （既定 4 / `FAILED_RECOVERY_MAX_ATTEMPTS`）を唯一のカウンタとして扱い、Reviewer
#   内部 2/2 試行や pr-iteration 3R と掛け算しない（D-19b）。同原因再発 + 無進捗の
#   no-progress ガードで早期終端する。
#
#   - fr_is_enabled     : 二重 opt-in gate（FAILED_RECOVERY_ENABLED && FULL_AUTO_ENABLED）
#   - fr_state_path     : 状態ファイル絶対パスを返す純粋関数
#   - fr_load_state     : 状態 JSON 読み出し（不在 / parse 失敗で `{}` を返す fail-open）
#   - fr_save_state     : 状態 JSON の atomic write（mktemp → mv -f）
#
#   後続 task で `fr_fetch_failed_issues` / `fr_fetch_failed_prs` /
#   `fr_compute_failure_signature` / `fr_detect_no_progress` /
#   `fr_collect_issue_context` / `fr_collect_pr_ci_context` / `fr_invoke_claude` /
#   `fr_should_recover` / `fr_run_recovery_attempt` / `fr_finalize_success` /
#   `fr_post_attempt_comment` / `fr_terminate_max_attempts` /
#   `fr_terminate_no_progress` / `process_failed_recovery` を追加する。
#
# 配置先:
#   $HOME/bin/modules/failed-recovery.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（fr_log / fr_warn / fr_error）は core_utils.sh にあるため本モジュールでは
#     再定義しない（task 1 で追加済み）。
#   - グローバル変数（$FAILED_RECOVERY_ENABLED / $FULL_AUTO_ENABLED /
#     $FAILED_RECOVERY_MAX_ATTEMPTS / $FAILED_RECOVERY_STATE_DIR 等）は本体冒頭の
#     Config ブロックで定義済み（task 2 で追加済み）。bash の遅延束縛により呼び出し時に
#     解決される。
#   - 外部 CLI: gh / jq / git / claude（claude は後続 task の Execution Layer のみで利用）。
#   - 関数 prefix `fr_` を namespace として採用する。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note）/ install.sh（配置ロジック）
#   設計参照: docs/specs/359-feat-watcher-failed-recovery-sh-claude-f/design.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 二重 opt-in 評価。`FAILED_RECOVERY_ENABLED=true` AND `FULL_AUTO_ENABLED=true` の
# 双方が「lowercase の `true` 完全一致」の場合のみ 0 を返す純粋関数（副作用なし）。
# それ以外（未設定 / 空 / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` /
# typo 等）はすべて 1 を返し OFF として扱う（Req 1.1〜1.5 / NFR 1.3 の安全側 fallback）。
#
# Returns:
#   0 = 両 gate が ON（Failed Recovery 起動可能）
#   1 = いずれかの gate が OFF（処理しない）
fr_is_enabled() {
  [ "${FAILED_RECOVERY_ENABLED:-false}" = "true" ] || return 1
  [ "${FULL_AUTO_ENABLED:-false}" = "true" ] || return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# State Persistence Layer
#
# Issue 単位で通算 attempt カウンタ + 直前試行情報を JSON ファイルに永続化する。
# `$FAILED_RECOVERY_STATE_DIR/<issue>.json` に 1 Issue = 1 ファイルで保存し、cron
# サイクル跨ぎ・watcher プロセスの再起動でもカウンタを継承する（Req 4.1, 4.7, 6.2 /
# NFR 2.2, NFR 2.3）。
#
# JSON schema (design.md Data Model 節):
#   {
#     "issue": <int>,
#     "total_attempts": <int>,
#     "last_status": "in-progress" | "succeeded" | "max-attempts" | "no-progress",
#     "last_failure_signature": "<sha-1 hex>",
#     "last_head_sha": "<commit sha or empty string>",
#     "last_attempt_at": "<ISO 8601 UTC>",
#     "history": [
#       {"attempt": <int>, "at": "<ISO 8601>", "signature": "<hex>", "head_sha": "<sha>", "outcome": "<status>"},
#       ...  // append-only、古いものから 8 件で truncate
#     ]
#   }
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Args: $1 = issue number
# Stdout: 絶対パス（$FAILED_RECOVERY_STATE_DIR/<issue>.json）
# Returns: 0（常に）
fr_state_path() {
  local issue_number="$1"
  printf '%s/%s.json' "$FAILED_RECOVERY_STATE_DIR" "$issue_number"
}

# Issue 番号に対応する状態 JSON を stdout に出力する（Req 4.7, NFR 2.2, NFR 2.3）。
# ファイル不在 / JSON parse 失敗時は安全側 fallback として `{}` を返し、呼出側は
# 既定値（total_attempts=0, history=[] 等）で初期化できる（fail-open）。
#
# Args: $1 = issue number
# Stdout: JSON 全体（不在 / 破損時は `{}`）
# Returns: 0（常に）
fr_load_state() {
  local issue_number="$1"
  local state_file
  state_file=$(fr_state_path "$issue_number")
  if [ ! -f "$state_file" ]; then
    printf '%s' "{}"
    return 0
  fi
  # jq -e で parse 失敗時は非 0 終了 → `{}` で fallback
  local content
  if ! content=$(jq -c '.' "$state_file" 2>/dev/null); then
    printf '%s' "{}"
    return 0
  fi
  printf '%s' "$content"
  return 0
}

# 状態 JSON を atomic write で永続化する（Req 4.1, 4.2, 5.5, 6.2 / NFR 2.3）。
# 既存 history を読み出して新エントリを append し、古いものから 8 件で truncate
# する（hot-spot 防止 / design.md Data Model 節）。`mkdir -p` で state_dir を
# 冪等確保し、同一 dir 上の `mktemp` で temp file を作成して `mv -f` で atomic
# rename することで read-modify-write 中の中断でも破損ファイルを残さない。
# すべての値を `jq --arg` / `--argjson` で sanitize（NFR 3.1）。
#
# Args:
#   $1 = issue number (int)
#   $2 = total_attempts (int)
#   $3 = last_status (enum: "in-progress" | "succeeded" | "max-attempts" | "no-progress")
#   $4 = last_failure_signature (hex string、空可)
#   $5 = last_head_sha (sha string、空可)
#
# 副作用:
#   - $FAILED_RECOVERY_STATE_DIR を mkdir -p で作成（既存なら no-op）
#   - 状態 JSON ファイルを atomic に書き換える
#
# Returns: 0 = persisted, 1 = failure (呼出側を落とさない / fr_warn で警告)
fr_save_state() {
  local issue_number="$1"
  local total_attempts="$2"
  local last_status="$3"
  local last_failure_signature="$4"
  local last_head_sha="$5"

  # state_dir を冪等確保（既存なら no-op、所有者は cron 実行ユーザー）
  if ! mkdir -p "$FAILED_RECOVERY_STATE_DIR" 2>/dev/null; then
    fr_warn "fr_save_state: mkdir -p \"$FAILED_RECOVERY_STATE_DIR\" 失敗"
    return 1
  fi

  local state_file
  state_file=$(fr_state_path "$issue_number")

  # ISO 8601 UTC 形式のタイムスタンプ
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # 既存 history を読み出す（存在しなければ空配列）。fr_load_state は破損時に
  # `{}` を返すため、`// []` で history 不在を空配列に正規化する。
  local prev_state
  prev_state=$(fr_load_state "$issue_number")
  local prev_history
  if ! prev_history=$(printf '%s' "$prev_state" | jq -c '.history // []' 2>/dev/null); then
    prev_history="[]"
  fi

  # 新規 history エントリを append し、古いものから 8 件で truncate。
  # すべて --arg / --argjson 経由（NFR 3.1）。
  local new_history
  if ! new_history=$(printf '%s' "$prev_history" | jq -c \
      --argjson attempt "$total_attempts" \
      --arg at "$now_iso" \
      --arg signature "$last_failure_signature" \
      --arg head_sha "$last_head_sha" \
      --arg outcome "$last_status" \
      '. + [{
        attempt: $attempt,
        at: $at,
        signature: $signature,
        head_sha: $head_sha,
        outcome: $outcome
      }] | .[-8:]' 2>/dev/null); then
    fr_warn "fr_save_state: history 構築失敗 issue=$issue_number"
    return 1
  fi

  # state JSON 全体を組み立てる。
  local new_state
  if ! new_state=$(jq -n \
      --argjson issue "$issue_number" \
      --argjson total_attempts "$total_attempts" \
      --arg last_status "$last_status" \
      --arg last_failure_signature "$last_failure_signature" \
      --arg last_head_sha "$last_head_sha" \
      --arg last_attempt_at "$now_iso" \
      --argjson history "$new_history" \
      '{
        issue: $issue,
        total_attempts: $total_attempts,
        last_status: $last_status,
        last_failure_signature: $last_failure_signature,
        last_head_sha: $last_head_sha,
        last_attempt_at: $last_attempt_at,
        history: $history
      }' 2>/dev/null); then
    fr_warn "fr_save_state: JSON 組み立て失敗 issue=$issue_number"
    return 1
  fi

  # atomic write: 同一 dir に temp file → mv -f で rename
  local tmp_file
  if ! tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null); then
    fr_warn "fr_save_state: mktemp 失敗 issue=$issue_number"
    return 1
  fi
  if ! printf '%s\n' "$new_state" > "$tmp_file" 2>/dev/null; then
    rm -f "$tmp_file"
    fr_warn "fr_save_state: temp file 書き込み失敗 issue=$issue_number"
    return 1
  fi
  if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    rm -f "$tmp_file"
    fr_warn "fr_save_state: atomic rename 失敗 issue=$issue_number"
    return 1
  fi
  return 0
}
