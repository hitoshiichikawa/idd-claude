#!/usr/bin/env bash
# failed-recovery.sh — watcher の Failed Recovery Processor モジュール（family orchestrator）
#
# family: failed-recovery / prefix: fr_
#   #471 で本モジュールを責務単位の module family へ分割した。orchestrator（本ファイル）と
#   2 つの sub-file が同一 prefix `fr_` を共有する（family 全体で 1 prefix）。分割マニフェスト
#   （どの関数がどのファイルにあるか）:
#     - failed-recovery.sh         … 本ファイル: エントリ / 候補列挙 / dispatch
#         process_failed_recovery（エントリ）/ fr_is_enabled（二重 opt-in gate）/
#         fr_fetch_failed_issues / fr_fetch_failed_prs（候補列挙）/
#         _fr_dispatch_candidate（1 candidate の rc を attempt/terminate 経路へ分岐）
#     - failed-recovery-attempt.sh … attempt budget / state 永続化 / no-progress 判定 / 終端処理
#         fr_state_path / fr_load_state / fr_save_state / fr_is_terminated /
#         fr_filter_terminated_candidates / fr_compute_failure_signature /
#         fr_detect_no_progress / fr_should_recover / fr_post_attempt_comment /
#         fr_finalize_success / fr_run_recovery_attempt（1 試行を駆動する orchestrator）/
#         fr_terminate_max_attempts / fr_terminate_no_progress /
#         fr_terminate_immediate_failure_streak
#     - failed-recovery-invoke.sh  … context 収集・claude 起動・作業ツリー準備
#         fr_collect_issue_context / fr_collect_pr_ci_context /
#         fr_resolve_dedicated_log_path / fr_classify_immediate_failure /
#         fr_prepare_repo_worktree / fr_invoke_claude
#
#   注: failed-recovery-attempt.sh 内の「Orchestrator Layer」見出しは本 family split 以前
#   から存在する本体内セクション名（1 Issue/PR の 1 試行を駆動するという意味の
#   "orchestrator"）で、family レベルの orchestrator（本ファイル）とは別概念（#471 で
#   混同しないよう明記。セクション見出し自体は #455 共通規約により無変更で保持）。
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
#   - fr_fetch_failed_issues / fr_fetch_failed_prs : 候補列挙
#   - _fr_dispatch_candidate : fr_run_recovery_attempt の rc を attempt/terminate 経路へ分岐
#   - process_failed_recovery : watcher 本体からの単一エントリ
#                               （_fr_dispatch_candidate 経由で候補列挙と terminate 配線を直列実行）
#
# 配置先:
#   $HOME/bin/modules/failed-recovery*.sh（install.sh が local-watcher/bin/modules/ から *.sh を
#   glob 配布するため、family の全ファイルが同時に配布される）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - family の sub-file は REQUIRED_MODULES で orchestrator より前に登録する（bash の遅延束縛
#     により source 順は不問だが、規約に従い sub → orchestrator の順に並べる）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（fr_log / fr_warn / fr_error）は core_utils.sh にあるため本モジュールでは
#     再定義しない（task 1 で追加済み）。
#   - グローバル変数（$FAILED_RECOVERY_ENABLED / $FULL_AUTO_ENABLED /
#     $FAILED_RECOVERY_MAX_ATTEMPTS / $FAILED_RECOVERY_STATE_DIR 等）は本体冒頭の
#     Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - family 内の cross-file 呼び出し（例: _fr_dispatch_candidate → fr_run_recovery_attempt /
#     fr_terminate_*）も遅延束縛で解決される（loader が main loop 前に全 module を source）。
#   - 外部 CLI: gh / jq / git / claude（claude は failed-recovery-invoke.sh の Execution Layer
#     のみで利用）。
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
