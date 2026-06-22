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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Candidate Selection Layer
#
# `claude-failed` Issue 群と auto-merge 待ち PR 群を server-side / client-side
# 二段フィルタで列挙し、Failed Recovery Processor の入力となる候補集合を返す。
# 取得失敗時は空 JSON 配列 `[]` を返し `fr_warn` で警告（fail-continue / 既存
# pr-iteration.sh `pi_fetch_candidate_prs` と同パターン）。
#
# 関連 AC:
#   - Req 2.1: claude-failed ラベル付き Issue を走査対象とする
#   - Req 2.2: reviewer-reject 由来も label 付与経緯非依存で含める（auto-dev かつ
#              claude-failed が立っていれば対象。`mark_issue_failed` /
#              `pi_escalate_to_failed` / `_slot_mark_failed` 何れの経路で付与
#              されたかは問わない）
#   - Req 2.3: auto-merge 待ち PR の CI error を走査対象とする
#   - Req 2.4: needs-decisions / needs-quota-wait / blocked / awaiting-slot などの
#              人間判断待ちラベルを持つ候補は server-side filter で除外
#   - Req 2.5: auto-dev ラベル未付与の Issue は除外（手動運用 Issue 保護）
#   - NFR 3.1: jq へ渡す未信頼入力（branch 名等）は `--arg` 経由で sanitize
#   - NFR 5.2: 取得失敗時も非破壊（fr_warn + `[]` 返却 / fail-continue）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_fetch_failed_issues: claude-failed Issue 群を列挙する。
#
# 仕様:
#   - `gh issue list` の `--search` に `label:"claude-failed" label:"auto-dev"` で
#     AND 必須条件を、`-label:"needs-decisions" -label:"needs-quota-wait"
#     -label:"blocked" -label:"awaiting-slot"` で除外条件を組み立てる。
#   - --limit は `$FAILED_RECOVERY_MAX_PRS`（既定 3）で truncate。
#   - `timeout "$FAILED_RECOVERY_GIT_TIMEOUT"` で外部呼び出しを保護。
#   - 取得失敗（timeout / gh エラー）時は `fr_warn` を 1 件記録し `[]` を返す。
#
#   ラベル変数は issue-watcher.sh Config ブロックで定義済みの既存定数
#   （`LABEL_FAILED="claude-failed"` / `LABEL_TRIGGER="auto-dev"` /
#   `LABEL_NEEDS_DECISIONS` / `LABEL_NEEDS_QUOTA_WAIT` / `LABEL_BLOCKED` /
#   `LABEL_AWAITING_SLOT`）を参照する。既存 `pi_fetch_candidate_prs` と同方針で
#   server-side filter の保険のため除外条件を二重展開している。
#
# Stdout: JSON 配列文字列（候補なし / 取得失敗時は `[]`）
# Returns: 0（常に。fail-continue）
fr_fetch_failed_issues() {
  local issues_json
  if ! issues_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_FAILED\" label:\"$LABEL_TRIGGER\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\" -label:\"$LABEL_AWAITING_SLOT\"" \
      --json number,labels,body,title,url \
      --limit "$FAILED_RECOVERY_MAX_PRS" 2>/dev/null); then
    fr_warn "fr_fetch_failed_issues: gh issue list 失敗（timeout または API エラー）"
    echo "[]"
    return 0
  fi

  # 取得成功でも非 JSON / 空文字なら安全側で `[]` に正規化
  if [ -z "$issues_json" ]; then
    echo "[]"
    return 0
  fi
  if ! printf '%s' "$issues_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    fr_warn "fr_fetch_failed_issues: gh issue list が JSON 配列を返さなかった"
    echo "[]"
    return 0
  fi
  printf '%s' "$issues_json"
  return 0
}

# fr_fetch_failed_prs: auto-merge 待ちかつ CI error の PR 群を列挙する。
#
# 仕様:
#   - 1 次絞り: `gh pr list --search 'label:"claude-failed"
#     -label:"needs-decisions" -label:"needs-quota-wait" -label:"blocked"
#     -label:"awaiting-slot" -draft:true'` で `claude-failed` ラベル + 人間判断
#     待ち除外 + 非 draft の PR を取得。`--json number,headRefName,
#     headRepositoryOwner,url,labels` で 1 次データを得る。
#   - 2 次絞り: 1 次結果の各 PR に対し `gh pr view --json mergeStateStatus,
#     autoMergeRequest,statusCheckRollup` を呼び、以下を client-side filter:
#       (a) `.autoMergeRequest` が null でない（auto-merge 有効化済み）
#       (b) `.statusCheckRollup[]` に state=FAILURE または conclusion=
#           FAILURE/TIMED_OUT が 1 件以上含まれる（CI error）
#   - head pattern `^claude/` で fork PR を除外（idd-claude 管理下 PR のみ）
#     + headRepositoryOwner.login == repo_owner で fork 強制除外
#   - `FAILED_RECOVERY_MAX_PRS` で件数 truncate（jq で `.[0:N]`）
#   - 取得失敗時は `fr_warn` を記録し `[]` を返す（fail-continue）
#
#   全ての未信頼入力（branch 名等）は jq `--arg` 経由で展開し inline 展開しない
#   （NFR 3.1）。
#
# Stdout: JSON 配列文字列（候補なし / 取得失敗時は `[]`）
# Returns: 0（常に。fail-continue）
fr_fetch_failed_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\" -label:\"$LABEL_AWAITING_SLOT\" -draft:true" \
      --json number,headRefName,headRepositoryOwner,url,labels \
      --limit "$FAILED_RECOVERY_MAX_PRS" 2>/dev/null); then
    fr_warn "fr_fetch_failed_prs: gh pr list 失敗（timeout または API エラー）"
    echo "[]"
    return 0
  fi
  if [ -z "$prs_json" ]; then
    echo "[]"
    return 0
  fi
  if ! printf '%s' "$prs_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    fr_warn "fr_fetch_failed_prs: gh pr list が JSON 配列を返さなかった"
    echo "[]"
    return 0
  fi

  # head pattern `^claude/` と headRepositoryOwner で fork PR を server-side
  # filter の保険として除外（NFR 3.1: branch 名は --arg で展開）。
  local filtered_first
  if ! filtered_first=$(printf '%s' "$prs_json" | jq -c \
      --arg owner "$repo_owner" \
      '[.[]
        | select((.headRepositoryOwner.login // "") == $owner)
        | select((.headRefName // "") | test("^claude/"))
      ]' 2>/dev/null); then
    fr_warn "fr_fetch_failed_prs: 1 次結果の jq filter 失敗"
    echo "[]"
    return 0
  fi

  # 各 PR について `gh pr view` で auto-merge 状況 + CI rollup を取得し、
  # client-side で auto-merge 有効 AND CI error を残す。
  local result="[]"
  local count
  count=$(printf '%s' "$filtered_first" | jq -r 'length' 2>/dev/null || echo "0")
  if [ "$count" = "0" ] || [ -z "$count" ]; then
    echo "[]"
    return 0
  fi

  local idx=0
  while [ "$idx" -lt "$count" ]; do
    local pr_meta pr_number
    pr_meta=$(printf '%s' "$filtered_first" | jq -c --argjson i "$idx" '.[$i]')
    pr_number=$(printf '%s' "$pr_meta" | jq -r '.number')
    # 数値検証（^[0-9]+$ / NFR 3.1）
    if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
      fr_warn "fr_fetch_failed_prs: 不正な PR number=$pr_number を skip"
      idx=$((idx + 1))
      continue
    fi
    local view_json
    if ! view_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr view "$pr_number" \
        --repo "$REPO" \
        --json mergeStateStatus,autoMergeRequest,statusCheckRollup 2>/dev/null); then
      fr_warn "fr_fetch_failed_prs: gh pr view 失敗 pr=#${pr_number}（skip）"
      idx=$((idx + 1))
      continue
    fi
    if [ -z "$view_json" ]; then
      idx=$((idx + 1))
      continue
    fi

    # auto-merge 有効化 (.autoMergeRequest != null) かつ CI error が 1 件以上ある
    # PR のみを残す。CI error は state=FAILURE または conclusion=FAILURE/TIMED_OUT。
    local keep
    keep=$(printf '%s' "$view_json" | jq -r '
      (.autoMergeRequest != null) as $auto
      | ((.statusCheckRollup // []) | map(
          select(
            (.state // "") == "FAILURE"
            or (.conclusion // "") == "FAILURE"
            or (.conclusion // "") == "TIMED_OUT"
          )
        ) | length > 0) as $err
      | if ($auto and $err) then "yes" else "no" end
    ' 2>/dev/null || echo "no")

    if [ "$keep" = "yes" ]; then
      # 1 次 PR メタに view の auto-merge / rollup 概要をマージして結果配列に append。
      local merged
      merged=$(jq -n \
        --argjson meta "$pr_meta" \
        --argjson view "$view_json" \
        '$meta + {
          mergeStateStatus: $view.mergeStateStatus,
          autoMergeRequest: $view.autoMergeRequest,
          statusCheckRollup: $view.statusCheckRollup
        }')
      result=$(printf '%s' "$result" | jq -c --argjson item "$merged" '. + [$item]')
    fi
    idx=$((idx + 1))
  done

  printf '%s' "$result"
  return 0
}
