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
#   - fr_fetch_failed_issues / fr_fetch_failed_prs : 候補列挙
#   - fr_compute_failure_signature / fr_detect_no_progress : no-progress 判定
#   - fr_collect_issue_context / fr_collect_pr_ci_context  : context 収集
#   - fr_invoke_claude     : fresh Claude session wrapper (quota 検出 sentinel)
#   - fr_should_recover    : 通算 attempt 上限の純粋判定
#   - fr_post_attempt_comment / fr_finalize_success / fr_run_recovery_attempt : Orchestrator
#   - fr_terminate_max_attempts / fr_terminate_no_progress : 終端処理（claude-failed 据え置き）
#   - process_failed_recovery : watcher 本体からの単一エントリ
#                               （_fr_dispatch_candidate 経由で候補列挙と terminate 配線を直列実行）
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
# JSON schema (design.md Data Model 節 + #411 拡張):
#   {
#     "issue": <int>,
#     "total_attempts": <int>,
#     "last_status": "in-progress" | "succeeded" | "max-attempts" | "no-progress" | "immediate-failure-streak",
#     "last_failure_signature": "<sha-1 hex>",
#     "last_head_sha": "<commit sha or empty string>",
#     "last_attempt_at": "<ISO 8601 UTC>",
#     "immediate_failure_streak": <int>,  // #411 Req 1.4 で追加（連続即時失敗回数）
#     "history": [
#       {"attempt": <int>, "at": "<ISO 8601>", "signature": "<hex>", "head_sha": "<sha>", "outcome": "<status>"},
#       ...  // append-only、古いものから 8 件で truncate
#     ]
#   }
# 後方互換: 既存 state ファイル（#411 導入前に書かれたもの）は immediate_failure_streak
# フィールドを持たない。fr_load_state は内容をそのまま返し、呼出側で `.immediate_failure_streak
# // 0` で 0 fallback して読む（#411 NFR 1.1）。
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
#   $3 = last_status (enum: "in-progress" | "succeeded" | "max-attempts" | "no-progress" |
#                          "immediate-failure-streak")
#   $4 = last_failure_signature (hex string、空可)
#   $5 = last_head_sha (sha string、空可)
#   $6 = immediate_failure_streak (int / #411 Req 1.4. 省略時は既存 state から継承)
#
# 副作用:
#   - $FAILED_RECOVERY_STATE_DIR を mkdir -p で作成（既存なら no-op）
#   - 状態 JSON ファイルを atomic に書き換える
#
# Returns: 0 = persisted, 1 = failure (呼出側を落とさない / fr_warn で警告)
#
# 後方互換: $6 を省略した呼び出し（#411 導入前の既存呼出側コード）は、prev_state から
# `.immediate_failure_streak // 0` を継承して保存する。これにより既存呼出側を変更せずに
# streak フィールドだけが追加で永続化される（#411 NFR 1.1）。
fr_save_state() {
  local issue_number="$1"
  local total_attempts="$2"
  local last_status="$3"
  local last_failure_signature="$4"
  local last_head_sha="$5"
  # #411: 6 番目の引数は immediate_failure_streak（省略時は既存 state から継承）。
  local immediate_failure_streak="${6-}"

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

  # #411: immediate_failure_streak は省略時に既存 state から継承する（NFR 1.1 後方互換）。
  # 既存 state が当該フィールドを持たないなら 0 fallback。明示指定の場合は数値検証する。
  if [ -z "$immediate_failure_streak" ]; then
    if ! immediate_failure_streak=$(printf '%s' "$prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
      immediate_failure_streak=0
    fi
  fi
  if ! [[ "$immediate_failure_streak" =~ ^[0-9]+$ ]]; then
    immediate_failure_streak=0
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
      --argjson immediate_failure_streak "$immediate_failure_streak" \
      --argjson history "$new_history" \
      '{
        issue: $issue,
        total_attempts: $total_attempts,
        last_status: $last_status,
        last_failure_signature: $last_failure_signature,
        last_head_sha: $last_head_sha,
        last_attempt_at: $last_attempt_at,
        immediate_failure_streak: $immediate_failure_streak,
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

# fr_is_terminated: state JSON の last_status から「max-attempts / no-progress 終端済み」
# を判定する純粋関数（#417）。
#
# Args:
#   $1 = state_json (string、`{}` または schema 準拠 JSON、空可)
#
# Stdout: 終端理由（"max-attempts" / "no-progress"）。未終端なら空文字。
# Returns:
#   0 = 終端済み（max-attempts または no-progress）
#   1 = 未終端（state 不在 / 破損 / それ以外の status / status 不在 → fail-open）
#
# 設計判断（#417 仮案 C）:
#   - state JSON の `last_status` 既存 enum をそのまま使う（新規フィールド追加せず NFR 1.1
#     後方互換を維持する）
#   - state 不在・破損は呼出元の `fr_load_state` で `{}` に正規化されるため、本関数は
#     status を読み出せれば判定し、読み出せなければ未終端として扱う（fail-open / Req 5.1〜5.3）
#   - jq parse 失敗時も同様に未終端扱いで rc=1 を返す
#
# 副作用なし（純粋関数）。
fr_is_terminated() {
  local state_json="${1-}"
  if [ -z "$state_json" ]; then
    return 1
  fi
  local status
  if ! status=$(printf '%s' "$state_json" | jq -r '.last_status // ""' 2>/dev/null); then
    return 1
  fi
  case "$status" in
    max-attempts|no-progress)
      printf '%s' "$status"
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# fr_filter_terminated_candidates: 候補列挙の JSON 配列から terminal 状態（max-attempts /
# no-progress）に永続化済みの番号を client-side filter で除外する（#417）。
#
# Args:
#   $1 = kind ("issue" | "pr"、ログ識別用)
#   $2 = candidates_json (JSON 配列文字列)
#
# Stdout: フィルタ後の JSON 配列（terminal 除外済み）
# Returns: 0（常に。fail-continue）
#
# 設計判断（#417 Req 2.1〜2.6）:
#   - state 不在 / 破損は fr_load_state が `{}` を返すため fr_is_terminated が rc=1
#     （未終端）で fail-open（Req 5.1〜5.3）
#   - 抑止時は NFR 2.1 の観点で 1 行ログを `failed-recovery: <kind>=#<n> terminated
#     reason=<status> suppressed=enumeration` 形式で残し、運用者が `grep` で重複コメント
#     spam の収束を確認可能にする（NFR 2.2）
#   - number が非数値なら fail-open で残す（candidate_json の他のフィルタが処理する）
#   - 入力が空 / JSON 配列でない場合は `[]` を返す
fr_filter_terminated_candidates() {
  local kind="$1"
  local candidates_json="${2-}"

  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_filter_terminated_candidates: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      printf '%s' "[]"
      return 0
      ;;
  esac

  if [ -z "$candidates_json" ]; then
    printf '%s' "[]"
    return 0
  fi
  if ! printf '%s' "$candidates_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "[]"
    return 0
  fi

  local count
  count=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
  if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" = "0" ]; then
    printf '%s' "[]"
    return 0
  fi

  local result="[]"
  local idx=0
  while [ "$idx" -lt "$count" ]; do
    local item number state_json terminal_reason
    item=$(printf '%s' "$candidates_json" | jq -c --argjson i "$idx" '.[$i]' 2>/dev/null || echo "")
    if [ -z "$item" ]; then
      idx=$((idx + 1))
      continue
    fi
    number=$(printf '%s' "$item" | jq -r '.number // ""' 2>/dev/null || echo "")
    if ! [[ "$number" =~ ^[0-9]+$ ]]; then
      # 数値検証失敗は fail-open で残す（候補列挙側で再度 sanitize される）
      result=$(printf '%s' "$result" | jq -c --argjson it "$item" '. + [$it]' 2>/dev/null || printf '%s' "$result")
      idx=$((idx + 1))
      continue
    fi
    state_json=$(fr_load_state "$number")
    terminal_reason=""
    if terminal_reason=$(fr_is_terminated "$state_json"); then
      # 終端済み → 除外 + 抑止ログ（NFR 2.1 / 2.2）
      fr_log "${kind}=#${number} terminated reason=${terminal_reason} suppressed=enumeration"
    else
      result=$(printf '%s' "$result" | jq -c --argjson it "$item" '. + [$it]' 2>/dev/null || printf '%s' "$result")
    fi
    idx=$((idx + 1))
  done

  printf '%s' "$result"
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
  # #417: terminal 状態（max-attempts / no-progress）に永続化済みの番号を除外する。
  # state 不在 / 破損は fr_load_state が `{}` を返すので fr_is_terminated が 1（未終端）
  # で fail-open する（Req 5.1〜5.3）。各 issue ごとに状態を確認し、抑止時は NFR 2.1 の
  # 観点で 1 行ログを残す。
  printf '%s' "$(fr_filter_terminated_candidates "issue" "$issues_json")"
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

  # #417: terminal 状態（max-attempts / no-progress）に永続化済みの PR 番号を除外する
  # （Req 2.1〜2.6 / fail-open は fr_filter_terminated_candidates 内で担保 / Req 5.1〜5.3）
  printf '%s' "$(fr_filter_terminated_candidates "pr" "$result")"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Recovery Decision Layer
#
# 失敗ログから正規化 hash（reason key）を生成して、直前試行と同一原因かつ無進捗の
# 修正反復を検出する。設計参照: design.md の Recovery Decision Layer 節
# （fr_should_recover / fr_compute_failure_signature / fr_detect_no_progress）。
#
# 関連 AC:
#   - Req 5.1: 修正試行ごとに直前試行との比較を行う
#   - Req 5.2: 同一失敗理由 + 無進捗で no-progress と判定する
#   - Req 5.5: 直前試行情報（signature / head_sha）を永続化済み state から参照する
#   - NFR 5.2: 失敗情報の取得失敗・空 state でも安全側に倒し caller を落とさない
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_compute_failure_signature: 失敗ログから揮発要素を正規化して SHA-1 hex を返す。
#
# 入力:
#   stdin: 正規化対象の失敗ログ本文（複数行可）
# 出力:
#   stdout: SHA-1 hex（40 桁）。空入力でも sha1sum が固定の空文字列 hash を返すため
#           常に 40 桁文字列が出力される
#
# 正規化対象（揮発要素を除去して同原因の再発を同一 signature として扱うため）:
#   - ISO 8601 タイムスタンプ（`2026-06-22T10:34:56Z` 等）
#   - SHA-1 ライクな 40-hex（commit SHA / object SHA）
#   - 絶対パス + 行番号（`/foo/bar/baz.sh:123` 等）
#   - URL（`http://...` / `https://...`）
#   - GitHub Actions の `Run #N`
#
# 設計参照: design.md 行 439-449。本実装は sed -E パターンを忠実に踏襲する。
fr_compute_failure_signature() {
  sed -E '
    s|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z||g
    s|[0-9a-f]{40}|<sha>|g
    s|/[A-Za-z0-9._/-]+:[0-9]+||g
    s|https?://[^[:space:]]+|<url>|g
    s|Run #[0-9]+||g
  ' | sha1sum | cut -d' ' -f1
}

# fr_detect_no_progress: 直前 state と現在 signature / head_sha を比較して
# no-progress を判定する。
#
# Args:
#   $1 = current_signature (string、空可)
#   $2 = current_head_sha (string、空文字なら Issue 経路として扱う)
#   $3 = prev_state_json (string、`{}` または schema 準拠 JSON、空可)
#
# Returns:
#   0 = no-progress（同一 signature + 進捗なし → 終端候補）
#   1 = progress（prev state なし / signature 異 / head 進捗あり）
#
# 判定ロジック（design.md 行 459-466）:
#   - prev_state_json が `{}` または `last_failure_signature` が空 / null → progress
#   - 直前 signature と現在 signature が異 → progress
#   - PR 経路（current_head_sha が非空）:
#       last_head_sha == current_head_sha かつ signature 一致 → no-progress
#       last_head_sha != current_head_sha（head 進捗あり） → progress
#   - Issue 経路（current_head_sha が空文字）:
#       signature 一致のみで no-progress（branch HEAD を持たないため厳しめ）
#
# 副作用なし（純粋関数）。caller の qa_log / fr_log 経由でログ出力する想定。
fr_detect_no_progress() {
  local current_signature="$1"
  local current_head_sha="$2"
  # 第 3 引数省略時は空 state として扱う。bash の `${var:-default}` 展開は default
  # 内の `{}` がリテラルとして安全に通らないため、明示的な空チェックで分岐する。
  local prev_state_json="${3-}"
  if [ -z "$prev_state_json" ]; then
    prev_state_json="{}"
  fi

  # prev_state_json から last_failure_signature / last_head_sha を抽出。
  # jq parse 失敗 / 不在は空文字に正規化（fail-open）。
  local prev_signature
  if ! prev_signature=$(printf '%s' "$prev_state_json" | jq -r '.last_failure_signature // ""' 2>/dev/null); then
    prev_signature=""
  fi
  local prev_head_sha
  if ! prev_head_sha=$(printf '%s' "$prev_state_json" | jq -r '.last_head_sha // ""' 2>/dev/null); then
    prev_head_sha=""
  fi

  # prev state なし / signature 空（初回 / 破損 fallback） → progress
  if [ -z "$prev_signature" ]; then
    return 1
  fi

  # signature 異 → progress
  if [ "$prev_signature" != "$current_signature" ]; then
    return 1
  fi

  # PR 経路: head_sha が非空。head が進んでいたら progress
  if [ -n "$current_head_sha" ]; then
    if [ "$prev_head_sha" != "$current_head_sha" ]; then
      return 1
    fi
    return 0
  fi

  # Issue 経路（current_head_sha 空）: signature 一致のみで no-progress
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Context Collection Layer
#
# claude session に渡す context 文字列を `gh issue view` / `gh pr checks` /
# `gh run view` で組み立てる。すべて fail-continue（API エラー時は警告 + 部分結果
# を返し caller を落とさない / NFR 5.2）。未信頼入力（Issue 本文・PR 本文・branch
# 名・コメント）は jq --arg / --argjson 経由で sanitize（NFR 3.1）。
#
# 関連 AC:
#   - Req 3.1: Issue コメントおよび関連ログから失敗原因 hint を抽出
#   - Req 3.2: auto-merge 待ち PR の CI ログを解析
#   - Req 3.5: 未信頼入力の quote / sanitize / ID 検証
#   - NFR 3.1: jq --arg / --argjson、gh -- / git --、ID `^[0-9]+$` / SHA `^[0-9a-f]{40}$`
#   - NFR 5.2: 取得失敗時も非破壊（fr_warn + 部分結果 / fail-continue）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_collect_issue_context: claude-failed Issue の context（title + labels + body +
# 直近 5 件コメント本文）を 1 つの平文に集約する。
#
# Args:
#   $1 = issue_number（^[0-9]+$ で使用前検証）
#
# Stdout: 集約済みの context 文字列（取得失敗時は警告 + 空文字）
# Returns:
#   0 = 成功（部分結果含む。API 失敗時も fail-continue で 0 を返し warn のみ）
#   1 = issue_number の形式不正（NFR 3.1 ガード）
fr_collect_issue_context() {
  local issue_number="$1"

  # NFR 3.1: Issue 番号の形式検証（^[0-9]+$）
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_issue_context: 不正な Issue 番号 issue=$(printf '%s' "$issue_number" | tr -cd '[:alnum:]_-' | head -c 32) を skip"
    return 1
  fi

  # gh issue view を呼び出す。失敗時は warn + 空 JSON で続行（fail-continue）
  local view_json
  if ! view_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue view "$issue_number" \
      --repo "$REPO" \
      --json comments,body,title,labels 2>/dev/null); then
    fr_warn "fr_collect_issue_context: gh issue view 失敗 issue=#${issue_number}"
    view_json="{}"
  fi
  if [ -z "$view_json" ]; then
    view_json="{}"
  fi

  # 直近 5 件のコメントを抽出する。jq parse 失敗時は空配列に正規化（fail-open）。
  # すべて jq filter 内で完結（未信頼値の inline 展開は無し / NFR 3.1）。
  local context
  if ! context=$(printf '%s' "$view_json" | jq -r '
    "## Title\n" + ((.title // "") | tostring) + "\n\n" +
    "## Labels\n" + (((.labels // []) | map(.name) | join(", "))) + "\n\n" +
    "## Body\n" + ((.body // "") | tostring) + "\n\n" +
    "## Recent Comments (last 5)\n" +
    (((.comments // [])[-5:]) | map("--- comment by " + ((.author.login // "unknown") | tostring) + " ---\n" + ((.body // "") | tostring)) | join("\n\n"))
  ' 2>/dev/null); then
    fr_warn "fr_collect_issue_context: jq による context 組み立て失敗 issue=#${issue_number}"
    printf '%s' ""
    return 0
  fi

  printf '%s' "$context"
  return 0
}

# fr_collect_pr_ci_context: auto-merge 待ち PR の failing checks ログ tail を集約する。
#
# Args:
#   $1 = pr_number（^[0-9]+$ で使用前検証）
#
# Stdout: 集約済みの context（failing check 一覧 + 各 check の log tail 200 行）
# Returns:
#   0 = 成功（部分結果含む。API 失敗時も fail-continue で 0 を返し warn のみ）
#   1 = pr_number の形式不正（NFR 3.1 ガード）
#
# 仕様:
#   - `gh pr checks <pr_number> --json name,state,conclusion,detailsUrl` で
#     failing check 列を取得（state=FAILURE または conclusion=FAILURE/TIMED_OUT）
#   - 各 failing check の detailsUrl から regex `actions/runs/([0-9]+)` で run id を
#     抽出。`^[0-9]+$` で再検証してから `gh run view <run_id> --log-failed` を呼ぶ
#   - 出力ログは tail で 200 行に cap（context 長制御）
#   - すべての API 失敗を fr_warn で吸収し残り check の処理を継続（fail-continue）
fr_collect_pr_ci_context() {
  local pr_number="$1"

  # NFR 3.1: PR 番号の形式検証（^[0-9]+$）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_pr_ci_context: 不正な PR 番号 pr=$(printf '%s' "$pr_number" | tr -cd '[:alnum:]_-' | head -c 32) を skip"
    return 1
  fi

  # failing checks を取得（gh pr checks --json）
  local checks_json
  if ! checks_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr checks "$pr_number" \
      --repo "$REPO" \
      --json name,state,conclusion,detailsUrl 2>/dev/null); then
    fr_warn "fr_collect_pr_ci_context: gh pr checks 失敗 pr=#${pr_number}"
    printf '%s' ""
    return 0
  fi
  if [ -z "$checks_json" ]; then
    printf '%s' ""
    return 0
  fi

  # failing check のみ filter（state=FAILURE または conclusion=FAILURE/TIMED_OUT）
  local failing_checks
  if ! failing_checks=$(printf '%s' "$checks_json" | jq -c '
    [.[] | select(
      ((.state // "") == "FAILURE")
      or ((.conclusion // "") == "FAILURE")
      or ((.conclusion // "") == "TIMED_OUT")
    )]
  ' 2>/dev/null); then
    fr_warn "fr_collect_pr_ci_context: failing checks の jq filter 失敗 pr=#${pr_number}"
    printf '%s' ""
    return 0
  fi

  # failing check の概要 header を組み立てる
  local header
  header=$(printf '%s' "$failing_checks" | jq -r '
    "## Failing Checks (count: " + ((. | length) | tostring) + ")\n" +
    (map("- " + ((.name // "unknown") | tostring) + " [state=" + ((.state // "") | tostring) + " conclusion=" + ((.conclusion // "") | tostring) + "]") | join("\n"))
  ' 2>/dev/null || echo "## Failing Checks")

  # 各 failing check の log tail を取得して append する
  local count
  count=$(printf '%s' "$failing_checks" | jq -r 'length' 2>/dev/null || echo "0")
  if [ -z "$count" ]; then
    count="0"
  fi

  local logs_section=""
  local idx=0
  while [ "$idx" -lt "$count" ]; do
    local check_meta details_url check_name run_id
    check_meta=$(printf '%s' "$failing_checks" | jq -c --argjson i "$idx" '.[$i]')
    details_url=$(printf '%s' "$check_meta" | jq -r '.detailsUrl // ""')
    check_name=$(printf '%s' "$check_meta" | jq -r '.name // "unknown"')

    # detailsUrl から run id を抽出（actions/runs/<id> の形式）
    run_id=""
    if [[ "$details_url" =~ actions/runs/([0-9]+) ]]; then
      run_id="${BASH_REMATCH[1]}"
    fi

    # NFR 3.1: run id の再検証（^[0-9]+$）
    if [ -n "$run_id" ] && [[ "$run_id" =~ ^[0-9]+$ ]]; then
      local log_tail
      if log_tail=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh run view "$run_id" \
          --repo "$REPO" \
          --log-failed 2>/dev/null | tail -n 200); then
        logs_section="${logs_section}"$'\n\n'"### Log for check: ${check_name} (run #${run_id})"$'\n'"${log_tail}"
      else
        fr_warn "fr_collect_pr_ci_context: gh run view 失敗 pr=#${pr_number} run=${run_id}（skip）"
      fi
    else
      fr_warn "fr_collect_pr_ci_context: detailsUrl から run id を抽出できず check=${check_name}（skip）"
    fi
    idx=$((idx + 1))
  done

  printf '%s\n%s' "$header" "$logs_section"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Recovery Execution Layer
#
# fresh Claude session を起動して context を解析・修正させる wrapper。quota-aware
# モジュールの qa_detect_rate_limit を再利用し、quota 検出時は exit 99 sentinel を
# caller に伝播する（呼出側で qa_handle_quota_exceeded 経路へ流す）。
#
# 関連 AC:
#   - Req 3.1: 修正試行を伴う再開を実行する
#   - Req 3.2: PR の CI 修正コミット投入
#   - Req 3.5: 未信頼入力の sanitize
#   - NFR 3.1: prompt は printf '%s' で値埋め込み、claude には引数として個別に渡す
#   - NFR 3.2: secrets を prompt 本文に埋め込まない（GH_TOKEN 等を直接展開しない）
#   - NFR 5.2: claude 実行失敗を fail-continue で扱う（quota 検出は別経路 exit 99）
#
# #411 拡張:
#   - 専用ログファイル（`$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log`）への保存を
#     必ず行う（Req 2.1〜2.5）。LOG が未設定でも /dev/null に捨てず自前で確定する
#   - stream-json 中の tool_use イベントを観測し、セッション継続時間と合わせて即時失敗
#     を判定する（Req 1.2）。即時失敗時は exit 98 sentinel を返す（Req 1.1）
#   - 対象 repo の作業ツリーで claude を起動する（Req 3.1〜3.3 / `fr_prepare_repo_worktree`）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_resolve_dedicated_log_path: failed-recovery 専用ログファイルのパスを返す純粋関数。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#
# Stdout: 絶対パス（`$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log`）
# Returns:
#   0 = 成功
#   1 = kind / number が不正（caller は /dev/null fallback または fail）
#
# 仕様:
#   - 識別語 `failed-recovery` を必ず含める（Req 2.3 / NFR 2.2）
#   - kind は `issue` / `pr` のみ受理、number は `^[0-9]+$` のみ受理（NFR 3.1）
#   - timestamp は ASCII 安全文字（`+%Y%m%dT%H%M%SZ` 互換 UTC）のみで構成
#   - $LOG_DIR が未設定なら $HOME/.issue-watcher/logs/$REPO_SLUG にフォールバック
#     （issue-watcher.sh Config ブロックの default と同じ規約 / Req 2.4）
fr_resolve_dedicated_log_path() {
  local kind="$1"
  local number="$2"

  # kind / number の sanitize（NFR 3.1）
  case "$kind" in
    issue|pr) : ;;
    *) return 1 ;;
  esac
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # LOG_DIR fallback: 未設定なら $HOME/.issue-watcher/logs/$REPO_SLUG（NFR 1.1 / Req 2.4）
  local log_dir="${LOG_DIR:-}"
  if [ -z "$log_dir" ]; then
    local repo_slug="${REPO_SLUG:-${REPO//\//-}}"
    log_dir="${HOME}/.issue-watcher/logs/${repo_slug}"
  fi

  # ASCII 安全な UTC タイムスタンプ（`date -u` 失敗時は epoch を fallback として使用）
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%s 2>/dev/null || echo "unknown")
  # timestamp が想定外形式（ASCII 安全文字以外）を含まないよう保険で sanitize
  ts=$(printf '%s' "$ts" | tr -cd '[:alnum:]')

  printf '%s/failed-recovery-%s-%s-%s.log' "$log_dir" "$kind" "$number" "$ts"
  return 0
}

# fr_classify_immediate_failure: claude session の終了情報から即時失敗を判定する純粋関数。
#
# Args:
#   $1 = claude_rc (int / claude 本体の exit code)
#   $2 = quota_detected ("1" = quota 検出済 / "0" = 検出なし)
#   $3 = tool_use_observed ("1" = tool_use 観測済 / "0" = 未観測)
#   $4 = elapsed_seconds (int / セッション継続時間)
#   $5 = threshold_seconds (int / 即時失敗判定の継続時間閾値)
#
# Returns:
#   0 = 即時失敗（attempt budget から除外すべき）
#   1 = 通常の試行（attempt budget に加算する）
#
# 判定ロジック（Req 1.2 / 1.8）:
#   - quota 検出（exit 99 sentinel）は本判定経路を適用しない → 1 (通常扱い)
#   - claude_rc == 0（success） → 1 (通常扱い)
#   - tool_use_observed == 1（実質作業に着手） → 1 (通常扱い)
#   - elapsed_seconds >= threshold（一定時間経過） → 1 (通常扱い)
#   - 上記いずれにも該当しない（rc != 0 かつ quota 以外 かつ tool_use 無し かつ短時間）
#     → 0 (即時失敗)
fr_classify_immediate_failure() {
  local claude_rc="$1"
  local quota_detected="$2"
  local tool_use_observed="$3"
  local elapsed_seconds="$4"
  local threshold_seconds="$5"

  # quota 検出経路は適用しない（Req 1.8）
  if [ "$quota_detected" = "1" ]; then
    return 1
  fi
  # claude が正常終了した場合は即時失敗ではない（Req 1.7）
  if [ "$claude_rc" = "0" ]; then
    return 1
  fi
  # tool_use を観測した場合は実質作業に着手しているため通算 attempt に加算（Req 1.7）
  if [ "$tool_use_observed" = "1" ]; then
    return 1
  fi
  # 閾値以上の時間継続していたら通常の試行として扱う（Req 1.7）
  if ! [[ "$elapsed_seconds" =~ ^[0-9]+$ ]]; then
    elapsed_seconds=0
  fi
  if ! [[ "$threshold_seconds" =~ ^[0-9]+$ ]]; then
    threshold_seconds=10
  fi
  if [ "$elapsed_seconds" -ge "$threshold_seconds" ]; then
    return 1
  fi
  # rc != 0 かつ quota 以外 かつ tool_use 無し かつ短時間 = 即時失敗
  return 0
}

# fr_prepare_repo_worktree: 対象 repo の作業ツリーを recovery claude 起動可能な状態に
# checkout する（Req 3.1〜3.3 / 3.5）。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$)
#   $3 = pr_head_ref (PR の headRefName / kind=pr の時のみ使用、空文字可)
#
# Stdout: 採用した checkout 参照名（Req 3.6 のログ記録に使う）
# Returns:
#   0 = checkout 成功
#   1 = checkout 失敗（caller は即時失敗扱いに倒す / Req 3.4）
#
# 仕様:
#   - $REPO_DIR を作業ツリー起点として採用（Req 3.5 / 既存 impl 系プロセッサと同一起点）
#   - kind=pr の場合: pr_head_ref を `origin/<ref>` から checkout
#   - kind=issue の場合:
#       既存 `claude/issue-<number>-*` branch があればその先頭を、無ければ
#       `origin/$BASE_BRANCH` を checkout
#   - すべての git 操作は `timeout` + `git -C` で REPO_DIR に対して実行（NFR 3.1）
#   - 失敗時は fr_warn で原因を残しつつ rc=1 で caller に通知（fail-continue / Req 3.4）
fr_prepare_repo_worktree() {
  local kind="$1"
  local number="$2"
  local pr_head_ref="${3-}"

  # kind / number の sanitize（NFR 3.1）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_prepare_repo_worktree: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_prepare_repo_worktree: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # REPO_DIR の存在確認（Req 3.5 / NFR 3.1）
  local repo_dir="${REPO_DIR:-}"
  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir/.git" ]; then
    fr_warn "fr_prepare_repo_worktree: REPO_DIR が未設定または git repo ではない repo_dir=${repo_dir:-<unset>}"
    return 1
  fi

  # base branch（fetch / fallback 用）
  local base_branch="${BASE_BRANCH:-main}"
  local git_timeout="${FAILED_RECOVERY_GIT_TIMEOUT:-60}"

  # まず origin の最新を取得（fetch 失敗時は既存 cache で続行 / Req 3.4 の fail-continue）
  timeout "$git_timeout" git -C "$repo_dir" fetch --prune origin >/dev/null 2>&1 || \
    fr_warn "fr_prepare_repo_worktree: git fetch origin 失敗（既存 cache で続行）"

  local target_ref=""
  if [ "$kind" = "pr" ]; then
    # PR head branch を checkout（Req 3.2 / NFR 3.1: head_ref は -- でオプション解釈打ち切り）
    if [ -z "$pr_head_ref" ]; then
      fr_warn "fr_prepare_repo_worktree: pr=#${number} の headRefName が空"
      return 1
    fi
    # head_ref を `^claude/` で再検証（既存 fetch 結果との整合性確認）
    if ! [[ "$pr_head_ref" =~ ^claude/ ]]; then
      fr_warn "fr_prepare_repo_worktree: pr=#${number} の headRefName が ^claude/ パターン外 head_ref=$(printf '%s' "$pr_head_ref" | tr -cd '[:alnum:]/_.-' | head -c 64)"
      return 1
    fi
    target_ref="$pr_head_ref"
  else
    # kind=issue: `claude/issue-<number>-*` 既存 branch を origin から検索（Req 3.3）
    local found_ref=""
    found_ref=$(timeout "$git_timeout" git -C "$repo_dir" ls-remote --heads origin "claude/issue-${number}-*" 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's|^refs/heads/||')
    if [ -n "$found_ref" ]; then
      target_ref="$found_ref"
    else
      # 既存 claude branch 無し → base branch を採用（Req 3.3）
      target_ref="$base_branch"
    fi
  fi

  # `--` でオプション解釈打ち切り（NFR 3.1）
  if ! timeout "$git_timeout" git -C "$repo_dir" checkout -B "$target_ref" "origin/$target_ref" -- >/dev/null 2>&1; then
    # origin/$target_ref が無い場合は target_ref そのものを試す（local-only branch / fallback）
    if ! timeout "$git_timeout" git -C "$repo_dir" checkout "$target_ref" -- >/dev/null 2>&1; then
      fr_warn "fr_prepare_repo_worktree: git checkout 失敗 ${kind}=#${number} target_ref=$(printf '%s' "$target_ref" | tr -cd '[:alnum:]/_.-' | head -c 64)"
      return 1
    fi
  fi

  printf '%s' "$target_ref"
  return 0
}

# fr_invoke_claude: fresh claude session を起動し stream-json を qa_detect_rate_limit
# で fold + tool_use 観測 + 経過時間計測する。
#
# Args:
#   $1 = prompt（claude へ -p で渡す本文。secrets を含めないこと / NFR 3.2）
#   $2 = stage_label（ログ識別用ラベル。例: "failed-recovery-issue-42"）
#   $3 = dedicated_log_path（専用ログ保存先パス / 空文字なら $LOG fallback）
#
# Returns:
#   0     = claude 正常終了 + quota 検出なし
#   98    = 即時失敗判定（attempt budget から除外すべき / #411 Req 1.1）
#   99    = quota 検出（caller は qa_handle_quota_exceeded 経路に流す / Req 3.x）
#   N≠0,98,99 = claude 自体の非ゼロ exit（quota 以外 / 即時失敗以外の失敗、fail-continue）
#
# 副作用:
#   - dedicated_log_path（または $LOG fallback）に stream-json を tee で append
#   - $LOG（caller 側で設定済みの実行ログ）にも tee で append（cron.log 観測の互換維持）
#   - prompt 本文を bash 引数として claude に渡す（環境変数経由ではなく引数）
#   - 専用ログファイル作成失敗時は fr_warn で警告しつつセッション自体は継続（Req 2.6）
#
# 実装メモ:
#   quota-aware.sh の qa_run_claude_stage と同じ tee + qa_detect_rate_limit 構成を
#   採用するが、本機能は QUOTA_AWARE_ENABLED gate を**経由しない**（Failed Recovery
#   は claude-failed 復旧の核となる処理なので、quota 検出のみは常時必要）。
#   そのため qa_run_claude_stage を呼ばず独自 wrapper として実装する。
#
#   #411 で stream-json の tool_use 検出 + セッション継続時間計測を追加。tool_use 検出は
#   stream-json 1 行に `"type":"tool_use"` を含む grep で観測する（grep -q で stream を
#   早期短絡せず最後まで読む必要があるため、tee 出力先 file を後段で 1 度だけ grep する）。
fr_invoke_claude() {
  local prompt="$1"
  local stage_label="$2"
  local dedicated_log_path="${3-}"

  # quota 検出用の中間 TSV ファイル（同一 cycle 内の他 stage と衝突しないよう mktemp）
  local detect_file
  if ! detect_file=$(mktemp 2>/dev/null); then
    fr_warn "fr_invoke_claude: mktemp 失敗 stage=$stage_label"
    return 1
  fi
  : > "$detect_file"

  # 専用ログファイルの確保（Req 2.1 / 2.4 / 2.6）。
  # 親ディレクトリ作成 + touch を試行し、失敗したら警告して /dev/null fallback で続行
  # （fail-continue / Req 2.6）。dedicated_log_path が空文字なら最初から fallback。
  local effective_dedicated_log="${dedicated_log_path:-}"
  if [ -n "$effective_dedicated_log" ]; then
    local _ded_dir
    _ded_dir=$(dirname "$effective_dedicated_log")
    if ! mkdir -p "$_ded_dir" 2>/dev/null; then
      fr_warn "fr_invoke_claude: 専用ログ親 dir 作成失敗 path=$_ded_dir（/dev/null fallback）"
      effective_dedicated_log=""
    elif ! : > "$effective_dedicated_log" 2>/dev/null; then
      fr_warn "fr_invoke_claude: 専用ログファイル truncate 失敗 path=$effective_dedicated_log（/dev/null fallback）"
      effective_dedicated_log=""
    fi
  fi

  # $LOG（呼出側 cron.log への観測互換）と dedicated_log の両方に append するため、
  # tee 1 段だけでは賄えない場合は 2 段 tee する。effective_dedicated_log が空文字なら
  # $LOG のみへ append（既存挙動互換）、$LOG も空文字なら /dev/null へ捨てる。
  local primary_log="${LOG:-/dev/null}"
  local secondary_log="${effective_dedicated_log:-/dev/null}"

  # NFR 2.2 / Req 2.5: 専用ログ名と保存先を一次運用ログ（cron.log）にも記録
  if [ -n "$effective_dedicated_log" ]; then
    fr_log "claude session start label=$stage_label model=${FAILED_RECOVERY_DEV_MODEL} max_turns=${FAILED_RECOVERY_MAX_TURNS} dedicated_log=$effective_dedicated_log"
  else
    fr_log "claude session start label=$stage_label model=${FAILED_RECOVERY_DEV_MODEL} max_turns=${FAILED_RECOVERY_MAX_TURNS}"
  fi

  # セッション継続時間計測（#411 Req 1.2）
  local session_start_epoch
  session_start_epoch=$(date +%s 2>/dev/null || echo "0")

  # 2 段 tee: claude → tee primary_log → tee secondary_log → qa_detect_rate_limit
  # set +e/-e で囲って pipefail 起因の即時 exit を一時抑止し、PIPESTATUS[0] で
  # claude 本体の exit code を取り出す（quota-aware の同型ロジックを踏襲）。
  local claude_rc=0
  set +e
  claude -p "$prompt" \
    --model "$FAILED_RECOVERY_DEV_MODEL" \
    --max-turns "$FAILED_RECOVERY_MAX_TURNS" \
    --permission-mode bypassPermissions \
    --output-format stream-json 2>&1 \
    | tee -a "$primary_log" \
    | tee -a "$secondary_log" \
    | qa_detect_rate_limit > "$detect_file"
  local _fr_pipestatus=("${PIPESTATUS[@]}")
  set -e
  claude_rc="${_fr_pipestatus[0]:-0}"

  # セッション継続時間（end - start）
  local session_end_epoch
  session_end_epoch=$(date +%s 2>/dev/null || echo "$session_start_epoch")
  local elapsed_seconds=$((session_end_epoch - session_start_epoch))
  if [ "$elapsed_seconds" -lt 0 ]; then
    elapsed_seconds=0
  fi

  # quota 検出（epoch 付き行が 1 行でもあれば exit 99 sentinel）
  local quota_detected=0
  if [ -s "$detect_file" ]; then
    local epoch_line
    epoch_line=$(awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ { last = $0 } END { print last }' "$detect_file")
    if [ -n "$epoch_line" ]; then
      quota_detected=1
      local path_field
      path_field="${epoch_line%%$'\t'*}"
      fr_log "claude session quota detected label=$stage_label path=$path_field"
      rm -f "$detect_file"
      return 99
    fi
  fi
  rm -f "$detect_file"

  # #411 Req 1.2: stream-json 中の tool_use イベント観測。
  # primary_log / secondary_log 双方の末尾を grep する（どちらか可読な方で十分）。
  # claude --output-format stream-json は tool_use を `"type":"tool_use"` JSON 行で出力する。
  local tool_use_observed=0
  local _grep_source=""
  if [ -n "$effective_dedicated_log" ] && [ -r "$effective_dedicated_log" ]; then
    _grep_source="$effective_dedicated_log"
  elif [ -n "${LOG:-}" ] && [ -r "${LOG:-}" ]; then
    _grep_source="$LOG"
  fi
  if [ -n "$_grep_source" ]; then
    if grep -qE '"type"[[:space:]]*:[[:space:]]*"tool_use"' "$_grep_source" 2>/dev/null; then
      tool_use_observed=1
    fi
  fi

  # 即時失敗判定（#411 Req 1.2 / 1.7）
  local threshold_seconds="${FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS:-10}"
  if fr_classify_immediate_failure "$claude_rc" "$quota_detected" "$tool_use_observed" "$elapsed_seconds" "$threshold_seconds"; then
    # NFR 2.1: 判定根拠を一次運用ログに残す（exit code / tool_use 観測有無 / 経過秒）
    fr_log "claude session immediate-failure label=$stage_label rc=$claude_rc tool_use=$tool_use_observed elapsed=${elapsed_seconds}s threshold=${threshold_seconds}s"
    return 98
  fi

  fr_log "claude session end label=$stage_label rc=$claude_rc tool_use=$tool_use_observed elapsed=${elapsed_seconds}s"
  return "$claude_rc"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Orchestrator Layer
#
# 1 Issue / PR ごとの 1 試行を駆動する orchestrator 関数群。前段で生成した
# Gate / Candidate / State / Decision / Context / Execution Layer の各関数を
# 連結し、attempt budget 加算（試行開始時 / Req 4.2）、no-progress 判定
# （Req 5.1, 5.2）、結果コメント投稿（Req 3.3）、成功時のラベル除去（Req 3.4,
# 6.1, 6.2）を行う。
#
# 関連 AC:
#   - Req 3.1〜3.5: 失敗解析 → 修正 → 結果コメント → ラベル除去 → 未信頼入力 sanitize
#   - Req 4.2: 試行開始時に attempt++（quota 燃焼上界保証）
#   - Req 4.3: 通算カウンタは Reviewer marker / pr-iteration marker を読まず独立
#   - Req 4.4: 通算 attempt < FAILED_RECOVERY_MAX_ATTEMPTS なら次の試行を実行可
#   - Req 6.1: 復旧成功後の同サイクル内追加試行は in-memory set で抑止
#   - Req 6.2: 成功時 state JSON に last_status="succeeded" を残す
#   - NFR 2.1: in-memory set FR_PROCESSED_THIS_CYCLE で重複起動防止
#   - NFR 3.2: secrets を comment 本文に埋め込まない
#   - NFR 5.2: API 失敗時も fail-continue（fr_warn + caller を落とさない）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_should_recover: 通算 attempt カウンタが上限未満かを判定する純粋関数。
#
# Args:
#   $1 = total_attempts (int)
#
# Returns:
#   0 = まだ試行可能（total < FAILED_RECOVERY_MAX_ATTEMPTS）
#   1 = 上限到達（total >= FAILED_RECOVERY_MAX_ATTEMPTS）
#
# 副作用なし。Config ブロックで MAX_ATTEMPTS は正規化済み（既定 4 / Req 4.8）
# のため、ここで再度範囲チェックはしない。design.md 行 416-422 参照。
fr_should_recover() {
  local total="$1"
  [ "$total" -lt "$FAILED_RECOVERY_MAX_ATTEMPTS" ] || return 1
  return 0
}

# fr_post_attempt_comment: Issue / PR に 1 件コメントを投稿する。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#   $3 = body (printf '%s' で値埋め込み済みの本文 / secrets を含めないこと / NFR 3.2)
#
# 副作用:
#   - gh issue comment / gh pr comment を 1 回呼ぶ
#
# Returns:
#   0 = 投稿成功
#   1 = 投稿失敗（fr_warn で警告 / fail-continue、caller を落とさない）
fr_post_attempt_comment() {
  local kind="$1"
  local number="$2"
  local body="$3"

  # kind の不正値ガード（issue / pr のみ受理）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_post_attempt_comment: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_post_attempt_comment: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # `gh issue comment` / `gh pr comment` を呼ぶ。本文は --body 引数として渡し、
  # secrets を含む env を直接 inline 展開しない（NFR 3.2 / 既存 pr-iteration の
  # コメント投稿パターンと同方針）。
  if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh "$kind" comment "$number" \
      --repo "$REPO" \
      --body "$body" >/dev/null 2>&1; then
    fr_warn "fr_post_attempt_comment: gh $kind comment 失敗 ${kind}=#${number}"
    return 1
  fi
  return 0
}

# fr_finalize_success: 復旧成功時に claude-failed ラベルを除去し、同サイクル内の
# 重複起動を in-memory set に記録する。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$)
#   $3 = total_attempts (int / state JSON 上書き用)
#   $4 = signature (string)
#   $5 = head_sha (string、Issue 経路は空文字を渡す)
#
# 副作用:
#   - gh issue edit / gh pr edit --remove-label でラベル除去
#   - FR_PROCESSED_THIS_CYCLE に "<kind>:<number>" を idempotent に append
#   - fr_save_state で last_status="succeeded" を永続化（Req 6.2）
#
# Returns:
#   0 = 成功（ラベル除去 + state 保存 + in-memory set 反映が全完了）
#   1 = 部分失敗（fr_warn で警告 / caller は判断する）
fr_finalize_success() {
  local kind="$1"
  local number="$2"
  local total_attempts="$3"
  local signature="$4"
  local head_sha="$5"

  # kind の不正値ガード
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_finalize_success: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_finalize_success: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # claude-failed ラベルを除去（Req 3.4）。失敗は fr_warn + return 1 で caller に通知。
  local rc=0
  if ! timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh "$kind" edit "$number" \
      --repo "$REPO" \
      --remove-label "$LABEL_FAILED" >/dev/null 2>&1; then
    fr_warn "fr_finalize_success: gh $kind edit --remove-label 失敗 ${kind}=#${number}"
    rc=1
  fi

  # in-memory set に "<kind>:<number>" を idempotent に追加（Req 6.1 / NFR 2.1）。
  local key="${kind}:${number}"
  FR_PROCESSED_THIS_CYCLE="${FR_PROCESSED_THIS_CYCLE:-}"
  case " $FR_PROCESSED_THIS_CYCLE " in
    *" $key "*) : ;;
    *) FR_PROCESSED_THIS_CYCLE="${FR_PROCESSED_THIS_CYCLE} ${key}" ;;
  esac
  # 先頭空白の正規化（読みやすさのため）
  FR_PROCESSED_THIS_CYCLE="${FR_PROCESSED_THIS_CYCLE# }"
  export FR_PROCESSED_THIS_CYCLE

  # state JSON に last_status="succeeded" を残す（Req 6.2）。Issue 経路でも PR
  # 経路でも同一 state ファイル（<number>.json）に書き込む（state は番号単位）。
  if ! fr_save_state "$number" "$total_attempts" "succeeded" "$signature" "$head_sha"; then
    fr_warn "fr_finalize_success: fr_save_state 失敗 ${kind}=#${number}"
    rc=1
  fi

  # Issue #370 task 5: Slack 通知 emitter（fail-open / gate OFF 時は no-op / NFR 3.3 で
  # signature 値は detail に含めない）。
  sn_notify failed-recovery "$number" "https://github.com/$REPO/${kind}s/$number" recovered "kind=${kind} attempts=${total_attempts}" || true

  return "$rc"
}

# fr_run_recovery_attempt: 1 Issue / PR に対する 1 試行を駆動する orchestrator。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$)
#
# Returns:
#   0  = success path（claude が修正を完了し fr_finalize_success まで実行）
#   1  = claude session 失敗（attempt 加算済み、次サイクルで resume）
#   2  = max-attempts 到達
#   3  = no-progress 判定
#   4  = #411 即時失敗連続上限到達（fr_terminate_immediate_failure_streak に委譲）
#   99 = quota 検出（fr_invoke_claude からの sentinel 伝播。caller は次サイクル待ち）
#
# 副作用:
#   - gh comment（着手 1 件 + 結果 1 件 = 2 件 / Req 3.3）
#   - claude session 起動（fr_invoke_claude 経由）
#   - state JSON 上書き（試行終了時に 1 回 / Req 4.2）
#   - 成功時のみ claude-failed ラベル除去 + FR_PROCESSED_THIS_CYCLE 反映
#   - #411 即時失敗時は attempt 加算をロールバックし、immediate_failure_streak のみ ++
#
# 重要な不変条件:
#   - 重複起動防止: FR_PROCESSED_THIS_CYCLE に "<kind>:<number>" が既存なら即 0 return
#   - 試行開始時 attempt++ （Req 4.2 / quota 燃焼上界保証）。途中失敗でも加算は確定
#   - **#411 例外**: rc=98（即時失敗）の場合のみ attempt をロールバックする（Req 1.1）
#   - Reviewer marker / pr-iteration marker（`idd-claude:pr-iteration round=N`）を
#     **読まない**（Req 4.3 / D-19b の独立カウンタ規約）
fr_run_recovery_attempt() {
  local kind="$1"
  local number="$2"

  # kind の不正値ガード
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_run_recovery_attempt: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_run_recovery_attempt: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # 重複起動防止（Req 6.1 / NFR 2.1）。同一サイクル内で既に成功 finalize 済みなら no-op
  local key="${kind}:${number}"
  FR_PROCESSED_THIS_CYCLE="${FR_PROCESSED_THIS_CYCLE:-}"
  case " $FR_PROCESSED_THIS_CYCLE " in
    *" $key "*)
      fr_log "fr_run_recovery_attempt: ${kind}=#${number} は本サイクル処理済み（skip）"
      return 0
      ;;
  esac

  # 直前 state を読み出す（Req 4.3: Reviewer marker / pr-iteration marker は読まない）。
  # state JSON は本 module が独自管理する <number>.json 1 ファイルだけを参照する。
  local prev_state
  prev_state=$(fr_load_state "$number")
  local prev_total
  if ! prev_total=$(printf '%s' "$prev_state" | jq -r '.total_attempts // 0' 2>/dev/null); then
    prev_total=0
  fi
  # jq が空文字 / null を返したケースを 0 に正規化
  if ! [[ "$prev_total" =~ ^[0-9]+$ ]]; then
    prev_total=0
  fi

  # #411 Req 1.4: 直前の immediate_failure_streak を読み出す（不在なら 0 fallback）。
  local prev_streak
  if ! prev_streak=$(printf '%s' "$prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
    prev_streak=0
  fi
  if ! [[ "$prev_streak" =~ ^[0-9]+$ ]]; then
    prev_streak=0
  fi

  # #411 Req 1.5 / 1.6: 即時失敗連続上限の事前チェック（attempt 上限とは独立した経路）。
  # 既に上限到達していたら、attempt budget を消費せず即 terminate 経路（rc=4）へ。
  local streak_max="${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}"
  if ! [[ "$streak_max" =~ ^[0-9]+$ ]] || [ "$streak_max" -le 0 ]; then
    streak_max=3
  fi
  if [ "$prev_streak" -ge "$streak_max" ]; then
    fr_log "fr_run_recovery_attempt: ${kind}=#${number} 即時失敗連続上限到達 streak=$prev_streak max=$streak_max"
    return 4
  fi

  # 上限判定（Req 4.4 / 4.5）。上限到達時は terminate 関数に委譲するため return 2 で
  # caller に通知。
  if ! fr_should_recover "$prev_total"; then
    fr_log "fr_run_recovery_attempt: ${kind}=#${number} 通算 attempt 上限到達 total=$prev_total"
    return 2
  fi

  # context 収集（Req 3.1 / 3.2）。kind に応じて Issue / PR 別の収集関数を呼ぶ。
  local context=""
  if [ "$kind" = "issue" ]; then
    context=$(fr_collect_issue_context "$number" || printf '%s' "")
  else
    context=$(fr_collect_pr_ci_context "$number" || printf '%s' "")
  fi

  # failure signature 計算（Req 5.1 / 5.5）。collect が空文字を返したケースでも
  # sha1sum は固定の hash を返すため signature 自体は常に得られる。
  local signature
  signature=$(printf '%s' "$context" | fr_compute_failure_signature)

  # head_sha 取得（PR 経路のみ。Issue 経路は空文字）。
  # 失敗時は空文字に正規化し、no-progress 判定は signature 一致のみで動く。
  local head_sha=""
  if [ "$kind" = "pr" ]; then
    if ! head_sha=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr view "$number" \
        --repo "$REPO" \
        --json headRefOid \
        --jq '.headRefOid' 2>/dev/null); then
      fr_warn "fr_run_recovery_attempt: gh pr view --json headRefOid 失敗 pr=#${number}"
      head_sha=""
    fi
    # 末尾改行を trim（jq -r が改行を付ける）
    head_sha="${head_sha%$'\n'}"
    # 取得値が空 / 不正 SHA なら空文字に正規化
    if ! [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
      head_sha=""
    fi
  fi

  # no-progress 判定（Req 5.1 / 5.2）。判定 0=no-progress なら terminate 関数
  # （task 7）に委譲するため return 3 で caller に通知（stub）。
  if fr_detect_no_progress "$signature" "$head_sha" "$prev_state"; then
    fr_log "fr_run_recovery_attempt: ${kind}=#${number} no-progress 判定 signature=$signature"
    return 3
  fi

  # 着手コメント投稿（Req 3.3 の 1 件目 / 着手表明）。新 total_attempts = prev + 1
  # を本文に含めて運用者が試行回数を追跡できるようにする。
  local new_total=$((prev_total + 1))
  local start_body
  start_body=$(printf 'Failed Recovery Processor (#359): 修正試行を開始します（通算 %s 回目 / 上限 %s）。\n\nclaude-failed 復旧フローで自動的に分析・修正を試みます。' \
      "$new_total" "$FAILED_RECOVERY_MAX_ATTEMPTS")
  fr_post_attempt_comment "$kind" "$number" "$start_body" || true

  # 試行開始時の attempt++ 確定（Req 4.2 / quota 燃焼上界保証）。
  # ここで一度 in-progress を永続化することで、claude が exit する前に
  # cron が中断しても次サイクルで total_attempts=new_total から resume できる。
  # streak は前回値をそのまま継承（即時失敗判定後にロールバック / 加算）。
  if ! fr_save_state "$number" "$new_total" "in-progress" "$signature" "$head_sha" "$prev_streak"; then
    fr_warn "fr_run_recovery_attempt: 開始時 fr_save_state 失敗 ${kind}=#${number}"
  fi

  # #411 Req 3.1〜3.5: 作業ツリーを対象 repo の REPO_DIR に checkout してから claude を起動。
  # PR の場合は headRefName を取得して PR head branch を、Issue の場合は claude/issue-<N>-*
  # 既存 branch または BASE_BRANCH を採用する。失敗時は即時失敗扱い（Req 3.4）。
  local pr_head_ref=""
  if [ "$kind" = "pr" ]; then
    if ! pr_head_ref=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr view "$number" \
        --repo "$REPO" \
        --json headRefName \
        --jq '.headRefName' 2>/dev/null); then
      fr_warn "fr_run_recovery_attempt: gh pr view --json headRefName 失敗 pr=#${number}"
      pr_head_ref=""
    fi
    pr_head_ref="${pr_head_ref%$'\n'}"
  fi

  local checkout_ref=""
  local worktree_ok=0
  if checkout_ref=$(fr_prepare_repo_worktree "$kind" "$number" "$pr_head_ref" 2>/dev/null); then
    worktree_ok=1
    fr_log "fr_run_recovery_attempt: ${kind}=#${number} 作業ツリー checkout 完了 repo_dir=${REPO_DIR:-<unset>} ref=$checkout_ref"
  else
    # Req 3.4: 作業ツリー確保失敗を即時失敗扱いに倒す（attempt budget からは除外）
    fr_warn "fr_run_recovery_attempt: ${kind}=#${number} 作業ツリー checkout 失敗（即時失敗扱い）"
  fi

  # #411 Req 2.1〜2.5: 専用ログ保存先を確定（LOG 未設定でも /dev/null に逃さない）
  local dedicated_log_path=""
  if ! dedicated_log_path=$(fr_resolve_dedicated_log_path "$kind" "$number" 2>/dev/null); then
    fr_warn "fr_run_recovery_attempt: 専用ログパス解決失敗 ${kind}=#${number}（/dev/null fallback）"
    dedicated_log_path=""
  fi

  local claude_rc=0
  if [ "$worktree_ok" = "1" ]; then
    # claude session を起動（Req 3.1 / 3.2）。prompt は context + 修正指示 +
    # attempt 回数を平文で組み立てる。secrets を含めない（NFR 3.2 / fr_invoke_claude
    # は値を引数として claude に渡す）。
    local prompt
    prompt=$(printf 'Failed Recovery Processor: claude-failed %s #%s の修正試行 (通算 %s 回目 / 上限 %s)\n\n以下の context から失敗原因を分析し、修正コミットを push してください。\n修正完了したら通常の Reviewer / pr-iteration フローに復帰させるため、本コメントへの追記応答は不要です。\n\n=== Context ===\n%s\n=== End of Context ===\n' \
        "$kind" "$number" "$new_total" "$FAILED_RECOVERY_MAX_ATTEMPTS" "$context")

    local stage_label="failed-recovery-${kind}-${number}"
    # fr_invoke_claude は内部で set +e/-e を toggle するため subshell で隔離。
    # subshell 内で REPO_DIR に cd して claude を起動することで、claude が当該 worktree
    # 上で git 操作・ファイル編集を行えるようにする（Req 3.1）。subshell が exit すれば
    # cd は caller に波及しない（NFR 1.1 後方互換）。
    (
      cd "$REPO_DIR" 2>/dev/null || true
      fr_invoke_claude "$prompt" "$stage_label" "$dedicated_log_path"
    ) || claude_rc=$?
  else
    # 作業ツリー確保失敗 → claude を起動せず即時失敗 sentinel に倒す（Req 3.4）
    claude_rc=98
  fi

  if [ "$claude_rc" = "99" ]; then
    # quota 検出: 結果コメント投稿 + state in-progress 維持 + caller は次サイクル待ち
    local quota_body
    quota_body=$(printf 'Failed Recovery Processor (#359): quota 検出により本試行を中断しました（通算 %s 回目）。\n\nquota reset 後の次サイクルで再試行されます。attempt カウンタは加算済みです。' \
        "$new_total")
    fr_post_attempt_comment "$kind" "$number" "$quota_body" || true
    # quota 起因の燃焼回避: attempt は加算済みなので state は in-progress を維持
    return 99
  fi

  if [ "$claude_rc" = "0" ]; then
    # success path: 結果コメント投稿 → fr_finalize_success（ラベル除去 + state succeeded）
    # 成功時は immediate_failure_streak を 0 にリセット（Req 1.7）。
    local success_body
    success_body=$(printf 'Failed Recovery Processor (#359): 修正試行が完了しました（通算 %s 回目）。\n\nclaude-failed ラベルを除去し、通常の処理フローに復帰させます。\n適用した修正の概要は本 %s の最新コミット / PR 差分を参照してください。' \
        "$new_total" "$kind")
    fr_post_attempt_comment "$kind" "$number" "$success_body" || true
    # streak リセット用に state を 1 度書く（fr_finalize_success が succeeded を上書きする
    # 前に streak=0 を確定させておく）。
    fr_save_state "$number" "$new_total" "in-progress" "$signature" "$head_sha" "0" || true
    if ! fr_finalize_success "$kind" "$number" "$new_total" "$signature" "$head_sha"; then
      fr_warn "fr_run_recovery_attempt: fr_finalize_success が部分失敗 ${kind}=#${number}"
      return 1
    fi
    return 0
  fi

  if [ "$claude_rc" = "98" ]; then
    # #411 Req 1.1 / 1.4 即時失敗判定: attempt を prev_total へロールバックし、
    # immediate_failure_streak のみ ++ する。Req 1.5 上限到達時は caller (_fr_dispatch_candidate)
    # が terminate 経路に流すため return 4 を返す。
    local new_streak=$((prev_streak + 1))
    fr_log "fr_run_recovery_attempt: ${kind}=#${number} 即時失敗 → attempt ロールバック new_streak=$new_streak max=$streak_max"
    # state を上書き（total を prev_total へ巻き戻し + streak を加算）。
    if ! fr_save_state "$number" "$prev_total" "in-progress" "$signature" "$head_sha" "$new_streak"; then
      fr_warn "fr_run_recovery_attempt: 即時失敗時の fr_save_state 失敗 ${kind}=#${number}"
    fi

    if [ "$new_streak" -ge "$streak_max" ]; then
      # 上限到達: caller が fr_terminate_immediate_failure_streak を呼ぶ。コメントはそちらに委譲。
      return 4
    fi

    # 上限未到達: 結果コメント投稿 + 次サイクル待ち
    local imm_body
    imm_body=$(printf 'Failed Recovery Processor (#411): claude セッションが実質作業前に即時失敗しました（連続即時失敗 %s 回目 / 上限 %s / 通算 attempt は加算せず %s 回のまま）。\n\nclaude-failed ラベルは据え置きます。次サイクルで再試行されます。' \
        "$new_streak" "$streak_max" "$prev_total")
    fr_post_attempt_comment "$kind" "$number" "$imm_body" || true
    return 1
  fi

  # その他の失敗 (rc != 0, 98, 99): 結果コメント投稿 + state in-progress 維持
  # 通常の失敗（claude が tool_use を観測した、あるいは閾値時間を超えた）の場合は
  # streak を 0 にリセットする（Req 1.7）。
  if ! fr_save_state "$number" "$new_total" "in-progress" "$signature" "$head_sha" "0"; then
    fr_warn "fr_run_recovery_attempt: 通常失敗時の fr_save_state 失敗 ${kind}=#${number}"
  fi
  local failure_body
  failure_body=$(printf 'Failed Recovery Processor (#359): 修正試行が失敗しました（通算 %s 回目 / 上限 %s / claude rc=%s）。\n\nclaude-failed ラベルは据え置きます。次サイクルで再試行されます（上限到達時は手動レビューへエスカレーション）。' \
      "$new_total" "$FAILED_RECOVERY_MAX_ATTEMPTS" "$claude_rc")
  fr_post_attempt_comment "$kind" "$number" "$failure_body" || true
  return 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Termination Layer
#
# `fr_run_recovery_attempt` が return 2 / return 3 で caller に通知する終端経路
# （max-attempts / no-progress）を受け取り、`claude-failed` ラベルを据え置いた
# まま、運用者向けの終端理由コメントと run-summary 連携を行う。
#
# 共通契約:
#   - `claude-failed` ラベルは **据え置く**（Req 4.5 / 5.3。手動介入待ち）
#   - 終端理由コメントを **1 件のみ**投稿（着手 + 結果のような 2 件投稿はしない）
#   - `rs_set_result claude-failed` を **1 度だけ**呼ぶ（多重発火しない / NFR 4.2）
#   - `fr_log` で `failed-recovery:` prefix + Issue/PR 番号でログ抽出可能（NFR 4.1）
#   - fail-continue: gh comment 失敗は `fr_post_attempt_comment` 内で fr_warn 済み
#     のため、Returns は常に 0
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_terminate_max_attempts: 通算 attempt 上限到達時の終端処理。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#   $3 = total_attempts (int / state の total_attempts をそのまま渡す)
#
# 副作用:
#   - 終端理由コメント 1 件を投稿（Req 4.6。本文に通算回数 + 上限値を含む）
#   - rs_set_result "claude-failed" を呼ぶ（NFR 4.2 / run-summary 連携）
#   - fr_log で終端理由をログ出力（NFR 4.1）
#   - claude-failed ラベルは **除去しない**（Req 4.5 / 手動介入待ち）
#
# Returns:
#   0 = fail-continue（コメント / rs_set_result 投稿失敗時も 0 を返す）
#   1 = 不正な引数（kind が issue/pr 以外 or number が非数値）
fr_terminate_max_attempts() {
  local kind="$1"
  local number="$2"
  local total_attempts="$3"

  # kind の不正値ガード（issue / pr のみ受理）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_terminate_max_attempts: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_terminate_max_attempts: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # #417 Req 1.1 / 1.3 / 2.3 / 2.6: cross-cycle のべき等ガード。state JSON の last_status
  # が既に max-attempts / no-progress なら、終端コメント・rs_set_result・sn_notify の
  # いずれも再発火させずに即 return 0（NFR 4.2 多重発火しない契約と整合）。
  # state 不在 / 破損は fr_load_state が `{}` を返すため fr_is_terminated が 1（未終端）
  # で fail-open（Req 5.1〜5.3）。
  local _prev_state _prev_status
  _prev_state=$(fr_load_state "$number")
  if _prev_status=$(fr_is_terminated "$_prev_state"); then
    # 抑止ログ（NFR 2.1 / 2.2 / Req 6.1：grep でコメント spam 収束を確認可能）
    fr_log "${kind}=#${number} terminated reason=${_prev_status} suppressed=terminate-max-attempts"
    return 0
  fi

  # 終端理由コメント 1 件を投稿（Req 4.6）。本文に通算回数 + 上限値を含めて
  # 運用者が手動レビュー時に試行履歴を把握できるようにする。secrets は含めない
  # （NFR 3.2 / printf '%s' で値埋め込み）。
  local body
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
  body=$(printf 'Failed Recovery Processor (#359): 通算 attempt 上限到達のため修正試行を停止します（通算 %s 回 / 上限 %s 回 / 終端理由: max-attempts）。\n\n`claude-failed` ラベルは据え置きます。手動レビューに移行してください。' \
      "$total_attempts" "$FAILED_RECOVERY_MAX_ATTEMPTS")
  fr_post_attempt_comment "$kind" "$number" "$body" || true

  # run-summary 連携（NFR 4.2 / Req 4.6）。rs_set_result は run-summary.sh の
  # 関数で、副作用は環境変数 RUN_SUMMARY_RESULT への代入のみ（戻り値常に 0）。
  rs_set_result "claude-failed" || true

  # NFR 4.1: `failed-recovery:` prefix と Issue/PR 番号でログ抽出可能にする。
  # fr_log は core_utils.sh で `[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: $*`
  # の 3 段 prefix を付与する。
  fr_log "${kind}=#${number} terminated reason=max-attempts total=${total_attempts} max=${FAILED_RECOVERY_MAX_ATTEMPTS}"

  # #417 Req 1.5 / 3.1〜3.3: cross-cycle の終端済み判定情報源として state JSON に
  # last_status="max-attempts" を永続化する。既存 schema の last_failure_signature /
  # last_head_sha / immediate_failure_streak は前回値を継承する（NFR 1.1）。fr_save_state
  # 失敗時は fr_warn で記録するが、コメント・rs_set_result は既に確定済みなので
  # caller は落とさない（fail-continue）。
  local _prev_sig _prev_head_sha _prev_streak
  if ! _prev_sig=$(printf '%s' "$_prev_state" | jq -r '.last_failure_signature // ""' 2>/dev/null); then
    _prev_sig=""
  fi
  if ! _prev_head_sha=$(printf '%s' "$_prev_state" | jq -r '.last_head_sha // ""' 2>/dev/null); then
    _prev_head_sha=""
  fi
  if ! _prev_streak=$(printf '%s' "$_prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
    _prev_streak=0
  fi
  if ! [[ "$_prev_streak" =~ ^[0-9]+$ ]]; then
    _prev_streak=0
  fi
  fr_save_state "$number" "$total_attempts" "max-attempts" "$_prev_sig" "$_prev_head_sha" "$_prev_streak" \
    || fr_warn "fr_terminate_max_attempts: fr_save_state 失敗 ${kind}=#${number}（cross-cycle べき等性が失われる可能性）"

  # Issue #370 task 5: Slack 通知 emitter（fail-open / gate OFF 時は no-op）
  sn_notify failed-recovery "$number" "https://github.com/$REPO/${kind}s/$number" max-attempts "kind=${kind} attempts=${total_attempts} max=${FAILED_RECOVERY_MAX_ATTEMPTS}" || true

  return 0
}

# fr_terminate_no_progress: no-progress 判定時の終端処理。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#   $3 = total_attempts (int / 参考表示用)
#   $4 = signature (string / 直前 signature 一致を確認した値。本文には含めず log で参照)
#
# 副作用:
#   - 終端理由コメント 1 件を投稿（Req 5.3。本文に no-progress + 同原因再発を含む）
#   - rs_set_result "claude-failed" を呼ぶ（Req 5.4 / run-summary 連携）
#   - fr_log で終端理由をログ出力（NFR 4.1）
#   - claude-failed ラベルは **除去しない**（Req 5.3 / 手動介入待ち）
#
# Returns:
#   0 = fail-continue（コメント投稿失敗時も 0 を返す）
#   1 = 不正な引数（kind が issue/pr 以外 or number が非数値）
fr_terminate_no_progress() {
  local kind="$1"
  local number="$2"
  local total_attempts="$3"
  local signature="${4:-}"

  # kind の不正値ガード（issue / pr のみ受理）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_terminate_no_progress: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_terminate_no_progress: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # #417 Req 1.2 / 1.4 / 2.3 / 2.6: cross-cycle のべき等ガード。state JSON の last_status
  # が既に max-attempts / no-progress なら、終端コメント・rs_set_result・sn_notify の
  # いずれも再発火させずに即 return 0（NFR 4.2 多重発火しない契約と整合）。
  # state 不在 / 破損は fail-open（Req 5.1〜5.3）。
  local _prev_state _prev_status
  _prev_state=$(fr_load_state "$number")
  if _prev_status=$(fr_is_terminated "$_prev_state"); then
    fr_log "${kind}=#${number} terminated reason=${_prev_status} suppressed=terminate-no-progress"
    return 0
  fi

  # 終端理由コメント 1 件を投稿（Req 5.3）。本文には「no-progress」「同原因再発」
  # 「無進捗」のキーワードを含めて運用者が手動レビュー時に検索可能にする。
  # signature の hex 値は運用者向け本文の可読性を優先して**含めない**（log には残す）。
  local body
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
  body=$(printf 'Failed Recovery Processor (#359): no-progress を検出したため修正試行を停止します（通算 %s 回 / 終端理由: no-progress / 直前と同一の失敗 signature が再発・無進捗）。\n\n`claude-failed` ラベルは据え置きます。手動レビューに移行してください。' \
      "$total_attempts")
  fr_post_attempt_comment "$kind" "$number" "$body" || true

  # run-summary 連携（Req 5.4）。rs_set_result は副作用が環境変数代入のみで
  # 戻り値常に 0 なので fail-continue の防御 `|| true` を付ける必要は無いが、
  # NFR 4.2 の「多重発火しない」契約を物理的に守るため明示的に 1 度だけ呼ぶ。
  rs_set_result "claude-failed" || true

  # NFR 4.1: ログには signature の先頭 8 桁を参考値として含める（運用者が
  # `failed-recovery: ... terminated reason=no-progress` で grep 抽出可能）。
  local sig_prefix=""
  if [ -n "$signature" ]; then
    sig_prefix=" signature=$(printf '%s' "$signature" | cut -c1-8)"
  fi
  fr_log "${kind}=#${number} terminated reason=no-progress total=${total_attempts}${sig_prefix}"

  # #417 Req 1.6 / 3.1〜3.3: cross-cycle の終端済み判定情報源として state JSON に
  # last_status="no-progress" を永続化する。signature は引数のものを保持（既存 schema
  # の last_failure_signature を上書き）、head_sha / streak は前回値を継承（NFR 1.1）。
  local _prev_head_sha _prev_streak
  if ! _prev_head_sha=$(printf '%s' "$_prev_state" | jq -r '.last_head_sha // ""' 2>/dev/null); then
    _prev_head_sha=""
  fi
  if ! _prev_streak=$(printf '%s' "$_prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
    _prev_streak=0
  fi
  if ! [[ "$_prev_streak" =~ ^[0-9]+$ ]]; then
    _prev_streak=0
  fi
  fr_save_state "$number" "$total_attempts" "no-progress" "$signature" "$_prev_head_sha" "$_prev_streak" \
    || fr_warn "fr_terminate_no_progress: fr_save_state 失敗 ${kind}=#${number}（cross-cycle べき等性が失われる可能性）"

  # Issue #370 task 5: Slack 通知 emitter（fail-open / gate OFF 時は no-op）。
  # signature 値は detail に含めない（NFR 3.3 / fr_log 側で先頭 8 桁を維持）。
  sn_notify failed-recovery "$number" "https://github.com/$REPO/${kind}s/$number" no-progress "kind=${kind} attempts=${total_attempts}" || true

  return 0
}

# fr_terminate_immediate_failure_streak: 即時失敗連続上限到達時の終端処理 (#411 Req 4.1)。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#   $3 = streak_count (int / 直近の即時失敗連続回数。コメント本文に表示)
#
# 副作用:
#   - 終端理由コメント 1 件を投稿（Req 4.3。本文に streak_count と識別子を含む）
#   - rs_set_result "claude-failed" を呼ぶ（Req 4.5 / run-summary 連携）
#   - fr_log で終端理由 `immediate-failure-streak` をログ出力（Req 4.2 / NFR 4.1）
#   - claude-failed ラベルは **除去しない**（Req 4.4 / 手動介入待ち）
#   - sn_notify でも識別子と回数を detail に含めて Slack 通知（Req 4.6 / NFR 3.2 で
#     failure signature 等の機微値は含めない）
#
# Returns:
#   0 = fail-continue（コメント投稿失敗時も 0 を返す）
#   1 = 不正な引数（kind が issue/pr 以外 or number が非数値）
fr_terminate_immediate_failure_streak() {
  local kind="$1"
  local number="$2"
  local streak_count="${3:-0}"

  # kind の不正値ガード（issue / pr のみ受理）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_terminate_immediate_failure_streak: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac

  # NFR 3.1: 番号の形式検証（^[0-9]+$）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_terminate_immediate_failure_streak: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi
  if ! [[ "$streak_count" =~ ^[0-9]+$ ]]; then
    streak_count=0
  fi

  # 終端理由コメント 1 件を投稿（Req 4.3）。本文に streak_count と識別子
  # `immediate-failure-streak` を含めて、運用者が手動レビュー時に max-attempts と区別可能にする。
  local body
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
  body=$(printf 'Failed Recovery Processor (#411): claude セッションが連続 %s 回、実質作業前の即時失敗を起こしました（終端理由: `immediate-failure-streak` / 上限 %s）。\n\nrecovery claude が起動不能の可能性があります（cwd / branch checkout / CLI 環境差など）。`claude-failed` ラベルは据え置きます。手動レビューに移行してください。' \
      "$streak_count" "${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}")
  fr_post_attempt_comment "$kind" "$number" "$body" || true

  # run-summary 連携（Req 4.5 / 既存 max-attempts / no-progress と同様 1 度だけ確定）
  rs_set_result "claude-failed" || true

  # NFR 4.1 / Req 4.2: `failed-recovery:` prefix + 識別子で `grep` 抽出可能にする。
  fr_log "${kind}=#${number} terminated reason=immediate-failure-streak streak=${streak_count} max=${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}"

  # Req 4.6: Slack 通知 emitter（fail-open / gate OFF 時は no-op）。
  # detail には kind / streak のみ含め、failure signature 等の機微値は含めない（NFR 3.2）。
  sn_notify failed-recovery "$number" "https://github.com/$REPO/${kind}s/$number" immediate-failure-streak "kind=${kind} streak=${streak_count} max=${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}" || true

  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Orchestrator Entry Point
#
# watcher サイクルから呼ばれる単一エントリ。gate → 候補列挙 → 各 candidate に試行 →
# terminate 経路（max-attempts / no-progress）配線 を直列実行する。本機能は claude-failed
# 復旧の核なので、API 失敗・claude session 失敗・terminate 関数の例外はすべて fr_warn で
# 吸収し、watcher 本体の後続 Issue 処理を止めない（fail-continue / NFR 5.2）。
#
# 関連 AC:
#   - Req 1.1: gate=on 時のみ起動
#   - Req 1.4: gate=off / 不正値 / 未設定で副作用ゼロ（NFR 1.1 / 1.3 と整合）
#   - Req 2.1: claude-failed Issue を走査対象とする
#   - Req 2.3: auto-merge 待ち PR の CI error を走査対象とする
#   - NFR 1.1: gate off では本機能導入前と完全に同一の外部挙動を保つ
#   - NFR 1.3: gate off / 不正値で副作用ゼロ
#   - NFR 2.1: 同一サイクル内の重複起動を FR_PROCESSED_THIS_CYCLE で抑止
#   - NFR 5.2: 取得失敗 / 例外時も fail-continue
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# _fr_dispatch_candidate: 1 candidate（kind + number）に対して fr_run_recovery_attempt を
# 呼び、return code を terminate 経路に分岐する private helper。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$)
#
# Returns: 常に 0（fail-continue）
#
# rc 解釈:
#   0  = success / 通常完了
#   1  = claude session 失敗。次サイクル再試行（fr_run_recovery_attempt 内で結果コメント済み）
#   2  = max-attempts 到達 → fr_terminate_max_attempts に委譲（state から total を再読み込み）
#   3  = no-progress 判定 → fr_terminate_no_progress に委譲（state から signature を再読み込み）
#   4  = #411 即時失敗連続上限到達 → fr_terminate_immediate_failure_streak に委譲
#        （state から immediate_failure_streak を再読み込み）
#   99 = quota 検出 → 次サイクル待ち（fr_run_recovery_attempt 内で結果コメント済み）
#   その他 = 未知 rc 警告 + 次候補へ
_fr_dispatch_candidate() {
  local kind="$1"
  local number="$2"
  local rc=0
  fr_run_recovery_attempt "$kind" "$number" || rc=$?
  case "$rc" in
    0|1|99)
      # 通常完了 / 再試行待ち / quota は本サイクルでは何もしない（必要なコメント・state
      # 更新は fr_run_recovery_attempt 内で完結している）
      :
      ;;
    2)
      # max-attempts 到達: terminate 関数を呼ぶ。total_attempts は state JSON から
      # 再読み込みする（fr_run_recovery_attempt 内で in-progress save 済みのため最新値）
      local prev_state total
      prev_state=$(fr_load_state "$number")
      if ! total=$(printf '%s' "$prev_state" | jq -r '.total_attempts // 0' 2>/dev/null); then
        total=0
      fi
      if ! [[ "$total" =~ ^[0-9]+$ ]]; then
        total=0
      fi
      fr_terminate_max_attempts "$kind" "$number" "$total" || true
      ;;
    3)
      # no-progress 判定: terminate 関数を呼ぶ。signature も state JSON から再読み込み
      local prev_state total signature
      prev_state=$(fr_load_state "$number")
      if ! total=$(printf '%s' "$prev_state" | jq -r '.total_attempts // 0' 2>/dev/null); then
        total=0
      fi
      if ! [[ "$total" =~ ^[0-9]+$ ]]; then
        total=0
      fi
      if ! signature=$(printf '%s' "$prev_state" | jq -r '.last_failure_signature // ""' 2>/dev/null); then
        signature=""
      fi
      fr_terminate_no_progress "$kind" "$number" "$total" "$signature" || true
      ;;
    4)
      # #411 即時失敗連続上限到達: streak は state JSON から再読み込み
      local prev_state streak
      prev_state=$(fr_load_state "$number")
      if ! streak=$(printf '%s' "$prev_state" | jq -r '.immediate_failure_streak // 0' 2>/dev/null); then
        streak=0
      fi
      if ! [[ "$streak" =~ ^[0-9]+$ ]]; then
        streak=0
      fi
      fr_terminate_immediate_failure_streak "$kind" "$number" "$streak" || true
      ;;
    *)
      fr_warn "_fr_dispatch_candidate: 未知の rc=$rc ${kind}=#${number}（skip）"
      ;;
  esac
  return 0
}

# process_failed_recovery: watcher サイクルからの単一エントリ。
#
# 仕様:
#   - 冒頭で `fr_is_enabled || return 0` で gate off の場合は副作用ゼロで return（NFR 1.3）
#   - Issue 候補（fr_fetch_failed_issues）と PR 候補（fr_fetch_failed_prs）を列挙し、各
#     candidate を直列に `_fr_dispatch_candidate` へ流す
#   - 重複起動防止は `fr_run_recovery_attempt` 内部の FR_PROCESSED_THIS_CYCLE で実装済み
#     （本関数は重複ガードを二重実装しない / NFR 2.1）
#   - 例外（候補列挙失敗・dispatch 失敗）は fr_warn で吸収して次の候補に進む（fail-continue
#     / NFR 5.2）
#
# Returns: 常に 0（caller の `process_failed_recovery || fr_warn ...` 経路が念のための保険）
process_failed_recovery() {
  # gate off / 不正値 / 未設定 → no-op（Req 1.1〜1.5 / NFR 1.1 / 1.3）
  if ! fr_is_enabled; then
    return 0
  fi

  fr_log "process_failed_recovery: 起動 (FAILED_RECOVERY_MAX_ATTEMPTS=${FAILED_RECOVERY_MAX_ATTEMPTS} FAILED_RECOVERY_MAX_PRS=${FAILED_RECOVERY_MAX_PRS})"

  # Issue 候補（Req 2.1 / 2.2 / 2.5）
  local issues_json
  issues_json=$(fr_fetch_failed_issues 2>/dev/null || echo "[]")
  if [ -z "$issues_json" ]; then
    issues_json="[]"
  fi
  local issues_count
  issues_count=$(printf '%s' "$issues_json" | jq -r 'length' 2>/dev/null || echo "0")
  if ! [[ "$issues_count" =~ ^[0-9]+$ ]]; then
    issues_count=0
  fi
  fr_log "process_failed_recovery: issue 候補 ${issues_count} 件"

  local i=0
  while [ "$i" -lt "$issues_count" ]; do
    local number
    number=$(printf '%s' "$issues_json" | jq -r --argjson i "$i" '.[$i].number' 2>/dev/null || echo "")
    if [[ "$number" =~ ^[0-9]+$ ]]; then
      _fr_dispatch_candidate "issue" "$number" || fr_warn "process_failed_recovery: issue=#${number} の dispatch で例外（次候補に進む）"
    else
      fr_warn "process_failed_recovery: 不正な issue number index=${i}（skip）"
    fi
    i=$((i + 1))
  done

  # PR 候補（Req 2.3 / 2.4）
  local prs_json
  prs_json=$(fr_fetch_failed_prs 2>/dev/null || echo "[]")
  if [ -z "$prs_json" ]; then
    prs_json="[]"
  fi
  local prs_count
  prs_count=$(printf '%s' "$prs_json" | jq -r 'length' 2>/dev/null || echo "0")
  if ! [[ "$prs_count" =~ ^[0-9]+$ ]]; then
    prs_count=0
  fi
  fr_log "process_failed_recovery: pr 候補 ${prs_count} 件"

  local j=0
  while [ "$j" -lt "$prs_count" ]; do
    local pr_number
    pr_number=$(printf '%s' "$prs_json" | jq -r --argjson i "$j" '.[$i].number' 2>/dev/null || echo "")
    if [[ "$pr_number" =~ ^[0-9]+$ ]]; then
      _fr_dispatch_candidate "pr" "$pr_number" || fr_warn "process_failed_recovery: pr=#${pr_number} の dispatch で例外（次候補に進む）"
    else
      fr_warn "process_failed_recovery: 不正な pr number index=${j}（skip）"
    fi
    j=$((j + 1))
  done

  fr_log "process_failed_recovery: サマリ issues=${issues_count} prs=${prs_count}"
  return 0
}
