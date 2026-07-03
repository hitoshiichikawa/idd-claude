#!/usr/bin/env bash
# impl-pipeline-review.sh — impl pipeline の Reviewer stage 実行 + 検証 + escalation
#
# family: impl-pipeline / prefix: なし（#501 で impl-pipeline.sh から分割。family マニフェストは
#   impl-pipeline.sh 冒頭ヘッダを参照）
#
# 用途:
#   Reviewer サブエージェントの起動と RESULT 判定、Stage 完了直後の push/PR 実在 verify、
#   claude-failed / needs-decisions への escalation を担う。
#   - run_reviewer_stage                 : Reviewer サブエージェント 1 回起動 + RESULT 抽出
#   - reviewer_skip_files_match          : REVIEWER_SKIP_PATTERN 全一致判定（純粋関数 / #333）
#   - _reviewer_skip_check               : REVIEWER_SKIP_PATTERN 評価本体（自動 approve 生成 / #333）
#   - publish_terminal_failure_artifacts : terminal failure 時の診断 artifact 保全ラッパー（#306）
#   - verify_pushed_or_retry             : Stage A/A'/B 完了直後の push 状態 verify + 自動リトライ（#106）
#   - verify_stagec_pr_or_retry          : Stage C 完了直後の PR 実在 verify + fallback（#108 / #110）
#   - mark_issue_failed                  : claude-failed 遷移の共通 escalation ヘルパー
#   - mark_issue_needs_decisions         : needs-decisions 遷移ヘルパー（Partial Status Gate / #148）
#   - handle_partial_status              : Partial Status Gate coordinator（#148）
#
# 配置先:
#   $HOME/bin/modules/impl-pipeline-review.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - impl-pipeline.sh（orchestrator）の run_impl_pipeline から呼ばれる（遅延束縛）。
#   - impl-pipeline-prompt.sh の build_reviewer_prompt を run_reviewer_stage から呼ぶ（遅延束縛）。
#   - mark_issue_failed / handle_partial_status は watcher 全域（slot-worker / 各 gate / per-task /
#     dependency-resolver / failed-recovery / pr-iteration 等）から呼ばれる中核 escalation
#     ヘルパーであり、本 family 内の他ファイルに閉じない（#501 分割時に代表経路の green を確認）。
#   - publish_terminal_failure_artifacts は per-task-loop.sh / debugger-gate.sh からも呼ばれる。
#   - build_recovery_hint（pr-iteration-exec.sh）を mark_issue_failed から呼ぶ（遅延束縛）。
#   - グローバル変数（$NUMBER / $REPO / $LOG / $MODE / $BRANCH / $REPO_DIR / $SPEC_DIR_REL /
#     $LABEL_* 等）は watcher-config.sh / 本体 main loop。
#   - 外部 CLI: gh / jq / git。
#
# SC2153 disable の背景（#501 / split 起因の info 級誤検知抑止）:
#   本ファイルの `_reviewer_skip_check` / `handle_partial_status` 等は大文字グローバル環境変数
#   `$BRANCH` を、`publish_terminal_failure_artifacts` の docstring / `run_reviewer_stage` は
#   `$REPO_DIR` / `$SPEC_DIR_REL` を参照する（いずれも本体 main loop / Slot Runner で代入）。
#   同一ファイル内に小文字ローカル `branch`（verify_pushed_or_retry / verify_stagec_pr_or_retry）・
#   `repo_dir` / `spec_dir_rel`（publish_terminal_failure_artifacts）が存在するため、分割前の
#   impl-pipeline.sh 単体では大文字側の実代入が同一ファイルに見えて非発火だった SC2153
#   （「typo では」）が、module 単体では cross-file 可視性の喪失で新規発火する。
#   関数移動対象自体は無改変（#455 共通規約）。MODE / BODY 側は #501 split で prompt.sh /
#   review.sh に自然分離されたため、本ファイルでは disable 不要（実測 shellcheck で確認済み）。
# shellcheck disable=SC2153

# ─── reviewer_skip_files_match <pattern> ───
#
# stdin の変更ファイル一覧（1 行 1 path）が「1 件以上あり、かつ全行が pattern（POSIX ERE）に
# 一致する」かを判定する純粋関数（#333）。`--` でパターン以降をオプション解釈から切り離す
# （`-` 始まりの path / pattern によるフラグ注入防止。#318 hardening と同方針）。
#
# 戻り値:
#   0 = スキップ適用可（非空リスト + 全行一致）
#   1 = それ以外（pattern 空 / リスト空 / 1 行でも不一致）
reviewer_skip_files_match() {
  local pattern="$1"
  [ -n "$pattern" ] || return 1
  local line
  local seen=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    seen=0
    if ! printf '%s\n' "$line" | grep -Eq -- "$pattern"; then
      return 1
    fi
  done
  [ "$seen" -eq 0 ]
}

# ─── _reviewer_skip_check ───
#
# REVIEWER_SKIP_PATTERN（opt-in）の評価本体（#333）。スキップ適用時のみ 0 を返し、副作用として
# 自動 approve の review-notes.md（hidden marker `idd-claude:reviewer-skip:v1` 付き）生成と
# rv_log 出力を行う。以下はすべて「スキップしない」（fail-safe / 戻り値 1）:
#   - REVIEWER_SKIP_PATTERN 未設定・空（既定）
#   - git diff 失敗 / 変更ファイル 0 件
#   - 1 ファイルでもパターン不一致
#
# 入力 (環境変数経由): REVIEWER_SKIP_PATTERN, BASE_BRANCH, BRANCH, NUMBER, REPO_DIR,
#                      SPEC_DIR_REL, LOG
# 副作用: $REPO_DIR/$SPEC_DIR_REL/review-notes.md の生成（commit は Stage C の責務 / 既存契約）
_reviewer_skip_check() {
  [ -n "${REVIEWER_SKIP_PATTERN:-}" ] || return 1

  local files
  if ! files=$(git diff --name-only "origin/${BASE_BRANCH}..HEAD" 2>/dev/null); then
    rv_log "skip-pattern: git diff 失敗 → 通常 Reviewer 起動（fail-safe）" >> "$LOG"
    return 1
  fi
  if [ -z "$files" ]; then
    rv_log "skip-pattern: 変更ファイル 0 件 → 通常 Reviewer 起動（fail-safe）" >> "$LOG"
    return 1
  fi
  if ! reviewer_skip_files_match "$REVIEWER_SKIP_PATTERN" <<< "$files"; then
    return 1
  fi

  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  local head_sha file_count
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")
  file_count=$(printf '%s\n' "$files" | grep -c . || true)
  mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
  cat > "$notes_path" <<EOF
# Review Notes

<!-- idd-claude:reviewer-skip:v1 pattern=${REVIEWER_SKIP_PATTERN} files=${file_count} -->

## Reviewed Scope

- Branch: ${BRANCH}
- HEAD commit: ${head_sha}
- Compared to: ${BASE_BRANCH}..HEAD

## Verified Requirements

（独立 Reviewer はスキップされました: 変更ファイル ${file_count} 件すべてが
REVIEWER_SKIP_PATTERN（\`${REVIEWER_SKIP_PATTERN}\`）に一致 / #333 opt-in）

## Findings

なし（自動 approve。内容レビューは PR 上の人間レビューで実施してください）

## Summary

REVIEWER_SKIP_PATTERN による Stage B スキップ（自動 approve / #333）。

RESULT: approve
EOF
  rv_log "round=1 result=approve reason=skip-pattern pattern='${REVIEWER_SKIP_PATTERN}' files=${file_count}" >> "$LOG"
  echo "⏭️  #$NUMBER: Reviewer スキップ（REVIEWER_SKIP_PATTERN 全一致 → 自動 approve）" | tee -a "$LOG"
  return 0
}

# ─── run_reviewer_stage <round> ───
#
# Reviewer サブエージェントを 1 回起動し、review-notes.md の最終 RESULT 行を抽出して
# 戻り値で結果を呼び出し元に返す。
#
# 入力:
#   $1 = round (1 | 2)
#   環境変数: NUMBER, BRANCH, SPEC_DIR_REL, LOG, REPO_DIR
# 副作用:
#   - $LOG に Reviewer 起動ログ（model / max-turns / 結果）を append
#   - $REPO_DIR/$SPEC_DIR_REL/review-notes.md が Reviewer によって作成 / 上書き
# 戻り値:
#   0 = approve
#   1 = reject
#   2 = 異常終了（claude crash / parse 失敗 / RESULT 行欠落 = 装飾起因 parse 失敗）
#   4 = ファイル不在で 1 回限定リトライ後も生成されず（Issue #296 Req 2 で導入）
#   99 = quota 超過
#
# Issue #296（ファイル不在検出 + 1 回限定リトライ）:
#   - 初回起動後 `parse_review_result` が rc=3（ファイル不在）を返した場合、同一 round 内で
#     Reviewer を 1 回だけ再起動して救済を試みる（Req 2.1, 2.4, NFR 3.1）。
#   - 再起動でファイルが生成されれば通常経路（approve / reject）に合流する（Req 2.2）。
#   - 再起動後も rc=3 のままなら本関数は rc=4 を返し、呼び出し側で `reviewer-missing-file`
#     カテゴリの `claude-failed` 付与に分岐する（Req 2.3, NFR 2.2 で reason 区別が必須）。
#   - rc=2（装飾起因 parse 失敗 = ファイルあり）経路はリトライ対象としない（Req 5.3）。
run_reviewer_stage() {
  local round="$1"
  local prev_result="(none)"

  # round=2 の場合、直前 review-notes.md の RESULT 行を Reviewer に伝える。
  # Issue #63: 装飾・インライン記述に耐性のある extract_review_result_token に委譲。
  # トークンが見つからない場合は従来どおり "(none)" を維持して prompt 互換性を保つ。
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  rv_log "round=$round start (model=$REVIEWER_MODEL, max-turns=$REVIEWER_MAX_TURNS)" >> "$LOG"

  local prompt
  prompt=$(build_reviewer_prompt "$round" "$prev_result")

  # Issue #296 Req 2.4 / NFR 3.1: ファイル不在起因の再起動は同一 round 内で最大 1 回まで。
  # ループ展開はせず attempt=1（初回）/ attempt=2（リトライ）の 2 段固定で実装する。
  # Issue #442 Req 1: 上記 missing-file リトライとは直交する形で、turn 切れ（error_max_turns）
  # 起因の拡張リトライを同一 round 内で最大 1 回だけ追加する。`_current_max_turns_rv`（初期
  # REVIEWER_MAX_TURNS）を可変化し、`_max_turns_retry_used_rv` で 1 回限定を担保する（Req 1.3）。
  # turn 切れ以外の非ゼロ exit は従来どおり即 return 2（Req 2.1）。
  local attempt
  local parsed=""
  local parse_rc
  local _current_max_turns_rv="$REVIEWER_MAX_TURNS"
  local _max_turns_retry_used_rv="false"
  for attempt in 1 2; do
    if [ "$attempt" = "2" ]; then
      # 再起動前のログ（NFR 2.1: 単発経路でのファイル不在起因リトライを観測可能にする）
      rv_log "round=$round attempt=2 retry reason=missing-file" >> "$LOG"
      echo "--- Reviewer 実行 (round=$round, retry attempt=2 / missing-file) ---" >> "$LOG"
    else
      echo "--- Reviewer 実行 (round=$round) ---" >> "$LOG"
    fi

    # Issue #66: Quota-Aware Watcher 経由で claude を起動。99 を受領した場合は
    # quota 超過検出として呼び出し側（run_impl_pipeline）に伝搬する。
    # Issue #442: 同一 attempt 内で turn 切れ拡張リトライを最大 1 回まで回す内側ループ。
    # 反復上限を 2（初回 + 拡張リトライ 1 回）に固定し無限ループを防ぐ（Req 1.3）。
    local _qa_reset_file_rv _qa_rc_rv=0 _qa_ts_rv _qa_stage_label_rv _rev_log_offset_rv _mt_inner_rv
    for _mt_inner_rv in 1 2; do
      _qa_ts_rv=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_rv="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-reviewer-r${round}-a${attempt}-m${_mt_inner_rv}-${_qa_ts_rv}"
      _qa_stage_label_rv="Reviewer-r${round}-a${attempt}-m${_mt_inner_rv}"
      # claude 実行前の $LOG 行数を記録（直前 stage の result 行誤検出を避ける / Req 2.4）。
      if declare -F tu_mark_log_offset >/dev/null 2>&1; then
        _rev_log_offset_rv=$(tu_mark_log_offset)
      else
        _rev_log_offset_rv=0
      fi
      _qa_rc_rv=0
      # #329: --agent reviewer で agent 定義をトップレベル実行（オーケストレーター層なし）。
      # agent 解決失敗時は claude が非ゼロ exit → 既存の reviewer-error 遷移 + run-summary の
      # degraded パターン（"Agent type .* not found"）で外形検知される。
      qa_run_claude_stage "$_qa_stage_label_rv" "$_qa_reset_file_rv" -- \
        claude \
          --agent reviewer \
          --print "$prompt" \
          --model "$REVIEWER_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$_current_max_turns_rv" \
          --output-format stream-json \
          --verbose \
          "${CLAUDE_HOOK_ARGS[@]}" \
          >> "$LOG" 2>&1 || _qa_rc_rv=$?

      # turn 切れ起因の非ゼロ exit のみ、同一 round 内で 1 回だけ拡張 turn 予算で再実行する。
      if [ "$_qa_rc_rv" != "0" ] && [ "$_qa_rc_rv" != "99" ] \
         && [ "$_max_turns_retry_used_rv" = "false" ] \
         && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset_rv"; then
        rm -f "$_qa_reset_file_rv"
        _max_turns_retry_used_rv="true"
        _current_max_turns_rv="$REVIEWER_MAX_TURNS_EXTENDED"
        # NFR 2.1 / Req 4.6: round / attempt / 拡張 turn 予算 / reason を 1 行で記録
        rv_log "round=$round attempt=$attempt retry reason=max-turns-extended extended-max-turns=$_current_max_turns_rv" >> "$LOG"
        echo "--- Reviewer 実行 (round=$round, retry / max-turns-extended=$_current_max_turns_rv) ---" >> "$LOG"
        continue
      fi
      break
    done
    case "$_qa_rc_rv" in
      0)
        rm -f "$_qa_reset_file_rv"
        ;;
      99)
        local _qa_epoch_rv
        _qa_epoch_rv=$(cat "$_qa_reset_file_rv")
        qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label_rv" "$_qa_epoch_rv"
        rm -f "$_qa_reset_file_rv"
        rv_log "round=$round attempt=$attempt result=quota-exceeded → needs-quota-wait" >> "$LOG"
        # run サマリ: Reviewer quota（独立 context で起動したが quota 超過 / Req 3.1, 3.3）
        rs_record_reviewer independent quota "$round"
        return 99
        ;;
      *)
        rm -f "$_qa_reset_file_rv"
        # Issue #442 Req 3.1, 3.3, 3.4: 拡張リトライ後も turn 切れ枯渇なら区別された
        # return code 6（reviewer-max-turns-exhausted）で escalation。run-summary は
        # degraded で記録（reviewer-error / missing-file と同じ degraded 系 / Req 3.3）。
        # それ以外の非ゼロ exit は従来どおり即 return 2（claude crash / Req 2.1）。
        if [ "$_max_turns_retry_used_rv" = "true" ] && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset_rv"; then
          rv_log "round=$round attempt=$attempt result=error reason=max-turns-exhausted extended-max-turns=$_current_max_turns_rv" >> "$LOG"
          rs_record_reviewer degraded "" "$round"
          return 6
        fi
        rv_log "round=$round attempt=$attempt result=error reason=claude-exit-nonzero" >> "$LOG"
        # run サマリ: Reviewer degraded（claude 異常終了で verdict 取得不能 / Req 3.4）
        rs_record_reviewer degraded "" "$round"
        return 2
        ;;
    esac

    # review-notes.md を parse
    parse_rc=0
    parsed=$(parse_review_result "$notes_path") || parse_rc=$?
    case "$parse_rc" in
      0) break ;;  # 抽出成功 → ループを抜けて通常経路へ
      3)
        # ファイル不在 → 1 回だけリトライ。リトライ後も rc=3 なら rc=4 で抜ける。
        if [ "$attempt" = "1" ]; then
          rv_log "round=$round attempt=1 result=missing-file" >> "$LOG"
          continue
        fi
        rv_log "round=$round attempt=2 result=missing-file-after-retry" >> "$LOG"
        # run サマリ: Reviewer degraded（ファイル不在で verdict 取得不能）
        rs_record_reviewer degraded "" "$round"
        return 4
        ;;
      *)
        # rc=2: 装飾起因の parse 失敗（ファイルあり）。リトライしない（Req 5.3）。
        rv_log "round=$round attempt=$attempt result=error reason=parse-failed" >> "$LOG"
        # run サマリ: Reviewer degraded（parse 失敗で verdict 取得不能 / Req 3.4）
        rs_record_reviewer degraded "" "$round"
        return 2
        ;;
    esac
  done

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      rv_log "round=$round result=approve verified=$targets" >> "$LOG"
      # run サマリ: Reviewer approve（独立 context で起動し verdict 取得 / Req 3.1, 3.2, 3.3）
      rs_record_reviewer independent approve "$round"
      return 0
      ;;
    reject)
      rv_log "round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      # run サマリ: Reviewer reject（独立 context で起動し verdict 取得 / Req 3.1, 3.2, 3.3）
      rs_record_reviewer independent reject "$round"
      return 1
      ;;
    *)
      rv_log "round=$round result=error reason=unknown-result" >> "$LOG"
      # run サマリ: Reviewer degraded（RESULT 欠落で verdict 取得不能 / Req 3.4）
      rs_record_reviewer degraded "" "$round"
      return 2
      ;;
  esac
}

# ─── per-task terminal failure 時の診断 artifact 保全ヘルパー (Issue #306) ───
#
# per-task ループの terminal failure 経路（`per-task-reviewer-reject2` /
# `per-task-reviewer-reject3` / `per-task-reviewer-error` /
# `per-task-reviewer-missing-file` / `debugger-notes-invalid` 等）で
# `mark_issue_failed` を呼び出す **直前** に経由するラッパー。Reviewer / Debugger
# サブエージェントには git / gh 権限を付与しない設計（Req 3.1, 3.2, 3.3）のため、
# watcher 側が以下を担う:
#
#   1. push state（branch / local HEAD / origin HEAD / ahead / worktree path）を
#      失敗コメントに常時埋め込む（Req 2.1, 2.4 / NFR 1.2）
#   2. `review-notes.md` / `debugger-notes.md` が untracked または未 commit / 未 push なら
#      diagnostic commit を 1 件作成し origin branch に push する（Req 1.1, 1.3）
#   3. diagnostic commit の commit / push が失敗したら artifact 本文（または長文時は
#      先頭・末尾要約）を Issue コメント本文に埋め込んで fallback する（Req 1.4, NFR 3.1）
#   4. 既に tracked かつ pushed 済みの artifact は重複保全しない（Req 1.2）
#   5. 保全処理が失敗しても `mark_issue_failed` を必ず呼ぶ（Req 1.5, NFR 2.1）
#
# 本ヘルパーは `mark_issue_failed` の **ラッパー** として動作し、
# 呼び出し側は `mark_issue_failed` の代わりに本関数を呼ぶだけで artifact 保全と
# push state 可視化を行える（call site 変更最小化）。
#
# 引数:
#   $1 = stage 識別子（既存 mark_issue_failed と同じ。例: per-task-reviewer-reject2）
#   $2 = 既存 extra_body（call site が組み立てる失敗コメント追加情報）
#
# 戻り値: 0 always（best-effort、既存 mark_issue_failed と同方針）
#
# 副作用:
#   - cwd が `$REPO_DIR`（slot worktree）であることを前提とする（_slot_run_issue が cd 済）
#   - push state 情報と artifact 状態を $2 (extra_body) に append してから
#     `mark_issue_failed` を呼び出す
#   - diagnostic commit 作成 / push を試行する（必要時のみ）
#   - 保全処理の各段階を `$LOG` に grep 可能な形で 1 行記録する（NFR 2.2）
#   - `git reset` / `git rebase` / force push は **使わない**（Req 3.4）
#
# 設計判断:
#   - 既存 `verify_pushed_or_retry` は ahead 数の verify と自動 push リトライに責務を
#     絞っており、artifact の commit / 本文埋め込みまでは扱わない。本関数は
#     **新規ヘルパー**として導入し、`verify_pushed_or_retry` の意味論は変更しない
#     （Req 4.3 / NFR 1.1）
#   - artifact 本文の埋め込み閾値は 16384 文字（NFR 3.1: GitHub Issue コメント 65,536
#     文字制限の余裕を取った保守的しきい値）。超過時は先頭 80 行 + 末尾 80 行の抜粋に
#     切り替える（Open Question の design 確定）
#   - 既存 `verify_pushed_or_retry` 風の `timeout` 既存検出ロジックを踏襲し、
#     `command -v timeout` で GNU coreutils の有無を判定（NFR 1.2）
publish_terminal_failure_artifacts() {
  local stage="$1"
  local extra_body="$2"

  # 防御: BRANCH / REPO_DIR / SPEC_DIR_REL が未設定でも処理を完遂する（Req 1.5 / NFR 2.1）
  local branch="${BRANCH:-}"
  local spec_dir_rel="${SPEC_DIR_REL:-}"
  local repo_dir="${REPO_DIR:-}"

  local _git_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _git_timeout=(timeout 30)
  fi

  # ── push state 収集（Req 2.1, 2.3, 2.4）──
  # ahead 数 / origin HEAD SHA を取得。エラー時は安全側で "(unknown)" 等を埋める
  local local_head="(unknown)" origin_head="未 push" ahead_count="(unknown)"
  local worktree_path="${repo_dir:-(unknown)}"

  local _lh
  _lh=$("${_git_timeout[@]}" git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$_lh" ]; then
    local_head="$_lh"
  fi

  # origin branch HEAD を取得する。fetch せず ls-remote で軽量に確認する（NFR 2.1）
  local _origin_out _origin_rc=0
  if [ -n "$branch" ]; then
    _origin_out=$("${_git_timeout[@]}" git ls-remote origin "refs/heads/$branch" 2>/dev/null) || _origin_rc=$?
    if [ "$_origin_rc" -eq 0 ] && [ -n "$_origin_out" ]; then
      origin_head=$(echo "$_origin_out" | awk '{print $1}' | head -n 1)
      if [ -z "$origin_head" ]; then
        origin_head="未 push"
      fi
    fi
  fi

  # ahead count を算出
  if [ "$origin_head" = "未 push" ]; then
    # 初回 push 前: BASE_BRANCH..HEAD の commit 数を使う（Req 2.3）
    local _base_ahead
    _base_ahead=$("${_git_timeout[@]}" git rev-list --count "${BASE_BRANCH:-main}..HEAD" 2>/dev/null || true)
    if [[ "$_base_ahead" =~ ^[0-9]+$ ]]; then
      ahead_count="$_base_ahead"
    fi
  else
    local _ah
    _ah=$("${_git_timeout[@]}" git rev-list --count "${origin_head}..HEAD" 2>/dev/null || true)
    if [[ "$_ah" =~ ^[0-9]+$ ]]; then
      ahead_count="$_ah"
    fi
  fi

  echo "[$(date '+%F %T')] terminal-failure-artifacts: stage=${stage} issue=#${NUMBER:-?} branch=${branch} local_head=${local_head} origin_head=${origin_head} ahead=${ahead_count}" >> "$LOG" 2>/dev/null || true

  # ── artifact 単位の保全処理（Req 1.1, 1.2, 1.3）──
  # artifact ごとに status を判定し、必要なら commit / push を試みる。失敗時は
  # 本文を extra_body に埋め込んで fallback。各 artifact ごとに以下を保存:
  #   <name> <status_token> <content_or_summary_or_empty>
  # status_token: tracked-pushed | tracked-unpushed | untracked | absent | embedded | committed
  local artifact_lines=""
  local artifact_embed=""
  local _need_commit=0

  _ptfa_artifact_status() {
    # echo "<status_token>" — file 状態を判定して返す
    local rel_path="$1"
    local abs_path="${repo_dir}/${rel_path}"
    if [ ! -f "$abs_path" ]; then
      echo "absent"
      return 0
    fi
    # tracked check: ls-files で確認
    local _tracked
    _tracked=$("${_git_timeout[@]}" git ls-files --error-unmatch -- "$rel_path" 2>/dev/null || true)
    if [ -z "$_tracked" ]; then
      echo "untracked"
      return 0
    fi
    # 変更が staged / unstaged に残っているか
    local _status_out
    _status_out=$("${_git_timeout[@]}" git status --porcelain -- "$rel_path" 2>/dev/null || true)
    if [ -n "$_status_out" ]; then
      echo "modified"
      return 0
    fi
    # commit 済み: origin に到達しているか
    if [ "$origin_head" = "未 push" ]; then
      echo "tracked-unpushed"
      return 0
    fi
    # 当該ファイルの最新 commit が origin に到達しているか:
    # log <origin_head>..HEAD で当該ファイルを変更した commit が出れば unpushed
    local _unpushed
    _unpushed=$("${_git_timeout[@]}" git log --oneline "${origin_head}..HEAD" -- "$rel_path" 2>/dev/null || true)
    if [ -n "$_unpushed" ]; then
      echo "tracked-unpushed"
      return 0
    fi
    echo "tracked-pushed"
    return 0
  }

  # artifact 一覧（順序保証）
  local _artifacts=("review-notes.md" "debugger-notes.md")
  local artifact_rel artifact_status artifact_rel_full
  local _need_save_list=()
  for artifact_rel in "${_artifacts[@]}"; do
    artifact_rel_full="${spec_dir_rel}/${artifact_rel}"
    artifact_status=$(_ptfa_artifact_status "$artifact_rel_full")
    artifact_lines="${artifact_lines}- \`${artifact_rel_full}\`: ${artifact_status}"$'\n'
    echo "[$(date '+%F %T')] terminal-failure-artifacts: artifact=${artifact_rel_full} status=${artifact_status} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
    case "$artifact_status" in
      untracked|modified|tracked-unpushed)
        _need_commit=1
        _need_save_list+=("$artifact_rel_full")
        ;;
      *) ;;
    esac
  done

  # ── 保全が必要なら diagnostic commit を試みる（Req 1.1, 1.3）──
  local _commit_pushed=0
  if [ "$_need_commit" = "1" ] && [ -n "$branch" ] && [ -n "$spec_dir_rel" ]; then
    local _add_rc=0 _commit_rc=0 _push_rc=0
    local _commit_msg="docs(spec): preserve terminal-failure diagnostics (#${NUMBER:-?} / stage=${stage})"

    # add: 対象 artifact のみ stage する
    local _save_path
    for _save_path in "${_need_save_list[@]}"; do
      "${_git_timeout[@]}" git add -- "$_save_path" 2>/dev/null || _add_rc=$?
    done

    if [ "$_add_rc" -eq 0 ]; then
      # commit を作成（user.email / user.name は cron 環境で global 設定済み前提）
      "${_git_timeout[@]}" git -c commit.gpgsign=false commit -m "$_commit_msg" -- \
        "${_need_save_list[@]}" >/dev/null 2>&1 || _commit_rc=$?
      if [ "$_commit_rc" -eq 0 ]; then
        "${_git_timeout[@]}" git push origin "$branch" >/dev/null 2>&1 || _push_rc=$?
        if [ "$_push_rc" -eq 0 ]; then
          _commit_pushed=1
          echo "[$(date '+%F %T')] terminal-failure-artifacts: diagnostic-commit pushed branch=${branch} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
          # push 成功後の origin_head / ahead を更新（コメント上の情報を最新化）
          local _new_origin
          _new_origin=$("${_git_timeout[@]}" git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{print $1}' | head -n 1)
          if [ -n "$_new_origin" ]; then
            origin_head="$_new_origin"
          fi
          local _new_local
          _new_local=$("${_git_timeout[@]}" git rev-parse HEAD 2>/dev/null || true)
          if [ -n "$_new_local" ]; then
            local_head="$_new_local"
          fi
          ahead_count="0"
          # artifact_lines を再生成（status を更新）
          artifact_lines=""
          for artifact_rel in "${_artifacts[@]}"; do
            artifact_rel_full="${spec_dir_rel}/${artifact_rel}"
            local _newst
            _newst=$(_ptfa_artifact_status "$artifact_rel_full")
            # commit/push 成功直後は committed として明示
            case "$_newst" in
              tracked-pushed) _newst="committed" ;;
              *) ;;
            esac
            artifact_lines="${artifact_lines}- \`${artifact_rel_full}\`: ${_newst}"$'\n'
          done
        else
          echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit push 失敗 push_rc=${_push_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
        fi
      else
        echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit commit 失敗 commit_rc=${_commit_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
      fi
    else
      echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit add 失敗 add_rc=${_add_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
    fi
  fi

  # ── push / commit が失敗（または skip）した場合の fallback 埋め込み（Req 1.3, 1.4, NFR 3.1）──
  if [ "$_need_commit" = "1" ] && [ "$_commit_pushed" != "1" ]; then
    local _save_path _abs _content _content_len
    local _max_chars=16384  # 約 16KB 上限（GitHub Issue コメント 65,536 文字制限の余裕保守値）
    for _save_path in "${_need_save_list[@]}"; do
      _abs="${repo_dir}/${_save_path}"
      if [ ! -f "$_abs" ]; then
        continue
      fi
      _content=$(cat "$_abs" 2>/dev/null || true)
      _content_len=${#_content}
      if [ "$_content_len" -gt "$_max_chars" ]; then
        # 長文時: 先頭 80 行 + 末尾 80 行に切り替える（NFR 3.1）
        local _head_part _tail_part
        _head_part=$(echo "$_content" | head -n 80)
        _tail_part=$(echo "$_content" | tail -n 80)
        artifact_embed="${artifact_embed}

#### \`${_save_path}\` の内容（要約 / 長文のため先頭 80 行 + 末尾 80 行）

\`\`\`
${_head_part}

… (中略 / 全文 ${_content_len} 文字) …

${_tail_part}
\`\`\`"
      else
        artifact_embed="${artifact_embed}

#### \`${_save_path}\` の内容（全文）

\`\`\`
${_content}
\`\`\`"
      fi
    done
    echo "[$(date '+%F %T')] terminal-failure-artifacts: artifact 本文を Issue コメントに fallback 埋め込み stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
  fi

  # ── extra_body に append する情報ブロックを組み立て ──
  local push_state_block
  push_state_block="### 診断 artifact / push 状態（Issue #306）

- 実装 branch: \`${branch:-(unknown)}\`
- local HEAD : \`${local_head}\`
- origin HEAD: \`${origin_head}\`
- ahead count: ${ahead_count}
- worktree  : \`${worktree_path}\`

#### artifact 状態

${artifact_lines}"

  if [ "$_commit_pushed" = "1" ]; then
    push_state_block="${push_state_block}
> ℹ️ watcher が未 push の診断 artifact を検出し、diagnostic commit を作成して origin に push しました。
> 上記 SHA / ahead 数は push 後の状態を反映しています。"
  elif [ "$_need_commit" = "1" ]; then
    push_state_block="${push_state_block}
> ⚠️ watcher が未 push の診断 artifact を検出しましたが、diagnostic commit / push に失敗しました。
> 下記の artifact 本文（または抜粋）が fallback として埋め込まれています。"
  fi

  local merged_body="$extra_body"
  if [ -n "$merged_body" ]; then
    merged_body="${merged_body}

${push_state_block}"
  else
    merged_body="$push_state_block"
  fi
  if [ -n "$artifact_embed" ]; then
    merged_body="${merged_body}${artifact_embed}"
  fi

  # ── 必ず claude-failed ラベルを付与する（Req 1.5, NFR 2.1）──
  mark_issue_failed "$stage" "$merged_body"
  return 0
}

# ─── Stage 完了直後の push 状態 verify ヘルパー (Issue #106) ───
#
# Stage A / A' / B 完了直後に「ローカル commit が origin に到達しているか」を verify し、
# 未 push を検出したら自動 push を 1 回だけリトライする。リトライ成功時は WARN ログ +
# Issue コメントで観測可能性を維持し、リトライ失敗時は mark_issue_failed 経路で
# claude-failed 化する。
#
# 引数:
#   $1 = stage 識別子（mark_issue_failed に渡す identifier。例: stageA-push-missing
#        / stageA-prime-push-missing / stageB-push-missing。NFR 2.1 / Req 4.4 と整合）
#   $2 = 対象 branch（典型的には $BRANCH）
#   $3 = stage label（ログ可読性のための短い文字列。例: "Stage A" / "Stage A'" / "Stage B"）
#
# 戻り値:
#   0 = ahead == 0（通常成功 / Req 1.3, 2.3, 5.1）、または自動 push リトライ成功
#       （Req 4.2, 4.3）
#   1 = 自動 push リトライ失敗 → mark_issue_failed 既発射、呼び出し側は伝搬 return 1 する
#       （Req 4.4, 4.5）
#
# 副作用:
#   - $LOG に検出経路 / ahead 数 / リトライ結果を WARN 行で記録（NFR 2.1, Req 1.2, 2.2, 3.2）
#   - リトライ成功時に gh issue comment で復旧通知を投稿（Req 4.3, NFR 2.2）
#   - リトライ失敗時に mark_issue_failed "$stage_id" で claude-failed 化（Req 4.4, NFR 2.3）
#
# 設計判断:
#   - `git rev-list --count @{u}..HEAD` で ahead 数を測る。本関数は cwd が slot worktree
#     ($REPO_DIR が指す path) であることを前提とする（_slot_run_issue が cd 済）。
#   - timeout は 30 秒上限（NFR 1.2）。本体 git クエリと push リトライそれぞれに timeout を
#     かける。`command -v timeout` で GNU coreutils の有無を判定し、無い環境
#     （BSD / macOS 標準）では timeout なしで実行する（既存 cron 互換性のため）。
#   - 結果不確定（git rev-list が timeout / 失敗）は「未 push と同等扱い」で安全側に倒す
#     （Req 1.4）。リトライを試み、失敗なら claude-failed 化する。
#   - push オプションは plain `git push origin <branch>` の fast-forward のみ。
#     `--force-with-lease` 等の force 系は **使わない**（既稼働 cron 環境で意図せぬ
#     history 書き換えを防止するため。Open Question 3 の design 確定）。
#   - Stage B の review-notes.md 識別ログ粒度（Req 3.4）は呼び出し側で stage label を
#     "Stage B" と明示し、本関数のログ行に stage label を含めることで観測可能性を担保。
verify_pushed_or_retry() {
  local stage_id="$1"
  local branch="$2"
  local stage_label="$3"

  # ── ahead 数を測定（安全側ロジック付き）──
  # 結果が空 / 取得失敗時は ahead=unknown とし、安全側で push リトライへ進む（Req 1.4）。
  local ahead_count="" rev_rc=0
  local _git_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _git_timeout=(timeout 30)
  fi
  ahead_count=$("${_git_timeout[@]}" git rev-list --count "@{u}..HEAD" 2>/dev/null) || rev_rc=$?
  # 数値以外（空文字 / エラー）は unknown 扱い
  if ! [[ "$ahead_count" =~ ^[0-9]+$ ]]; then
    ahead_count="unknown"
  fi

  # ── 通常成功ケース: ahead == 0（Req 1.3 / 2.3 / 3.3 / 5.1）──
  if [ "$ahead_count" = "0" ]; then
    return 0
  fi

  # ── ahead > 0 または unknown: WARN ログ → 自動 push リトライ 1 回（Req 4.1, 4.6）──
  qa_warn "${stage_label} push-state verify: ahead=${ahead_count} (rev_rc=${rev_rc}) issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
  echo "[$(date '+%F %T')] ${stage_label} ahead=${ahead_count} detected → auto-push retry 1/1 (Req 4.1, Issue #106)" >> "$LOG"

  local push_rc=0
  local push_stderr_tmp
  push_stderr_tmp=$(mktemp -t verify-push-XXXXXX.err 2>/dev/null || echo "")
  if [ -n "$push_stderr_tmp" ]; then
    "${_git_timeout[@]}" git push origin "$branch" 2>"$push_stderr_tmp" || push_rc=$?
  else
    "${_git_timeout[@]}" git push origin "$branch" || push_rc=$?
  fi

  if [ "$push_rc" -eq 0 ]; then
    # ── リトライ成功（Req 1.1, 1.2, 1.3, 1.4）──
    # #248: 成功時の Issue コメント投稿は誤検知ノイズ（ahead>0 は commit-only 設計の
    # 正常状態）となるため抑止する。監査トレーサビリティは $LOG の単一 info 行に
    # Issue 番号 / stage 識別子 / branch / 復旧 commit 数を機械可読フィールドとして
    # 含めて担保する（Req 2.1〜2.4 / NFR 3.1）。「push 漏れ」原因示唆文言は出さない。
    qa_warn "${stage_label} auto-push retry SUCCESS: ahead=${ahead_count} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
    echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ成功 → 継続 issue=#${NUMBER:-?} stage_id=${stage_id} branch=${branch} recovered_commits=${ahead_count}" >> "$LOG"

    if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi
    return 0
  fi

  # ── リトライ失敗（Req 4.4, 4.5, NFR 2.3）──
  local push_stderr_tail=""
  if [ -n "$push_stderr_tmp" ] && [ -f "$push_stderr_tmp" ]; then
    push_stderr_tail=$(tail -c 1500 "$push_stderr_tmp" 2>/dev/null || true)
  fi
  qa_warn "${stage_label} auto-push retry FAILED: ahead=${ahead_count} push_rc=${push_rc} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id} stderr_tail='${push_stderr_tail//$'\n'/ }'"
  echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ失敗 push_rc=${push_rc} → claude-failed (stage_id=${stage_id})" >> "$LOG"

  local fail_body
  fail_body="${stage_label} 完了直後に未 push commit（ahead=${ahead_count}）を検出し、自動 push リトライを 1 回試みましたが失敗しました（push exit code: ${push_rc}）。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 未 push commit 数: ${ahead_count}

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 worktree の HEAD と origin/${branch} の差分を確認
2. 必要に応じ手動で \`git push origin ${branch}\` を実行
3. 問題が解消したら \`claude-failed\` ラベルを外して再 pickup させる"
  if [ -n "$push_stderr_tail" ]; then
    fail_body="${fail_body}

### git push stderr (tail)

\`\`\`
${push_stderr_tail}
\`\`\`"
  fi

  if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi

  mark_issue_failed "$stage_id" "$fail_body"
  return 1
}

# ─── Stage C 完了直後の PR 実在 verify ヘルパー (Issue #108 / #110) ───
#
# Stage C の Claude 実行が return code 0 で終了した直後に、対象 branch を head と
# する impl PR が GitHub 側で参照可能か `gh pr list --head <branch> --state all` で verify する
# （`gh pr view` は `--head` 非対応で常に失敗し、かつ open のみ探索だと高速 merge 済み PR を
#  取りこぼすため、list + `--state all` で open/merged 双方を検出する）。GitHub の
# eventual consistency により PR 作成直後数十秒は当該クエリが空応答を返すケースが
# 観測されているため、主経路は最大 6 回までリトライ可能とし、整合性遅延に起因する
# false negative を吸収する。さらに主経路が全試行で空応答 / 失敗で終わった場合は、
# 主経路と独立な edge cache 経路である List Pulls API（`gh api repos/.../pulls?head=...`）
# に対して 1 度だけ fallback 探索を試みる（Issue #110: KeyNest #32 で観測された
# 73 秒経過後の主経路空応答に対する救済路）。
#
# 引数:
#   $1 = 対象 branch（典型的には $BRANCH）
#   $2 = Issue 番号（ログ識別用。典型的には $NUMBER）
#
# 戻り値:
#   0 = 主経路 / 代替経路のいずれかで PR URL が取得できた（PR URL を stdout に出力）
#   1 = 主経路全試行 + 代替経路の 1 ターンを全て使い切っても PR URL を取得できなかった
#
# 副作用:
#   - 各主経路試行の結果（成功 / 空応答 / 非 0 / タイムアウト）を `$LOG` に記録（NFR 2.1）
#   - 代替経路の呼び出し開始・結果を `$LOG` に記録（Req 3.3 / 3.4 / NFR 2.2）
#   - 1 回目即時成功時は追加ログを出さない（Req 4.1 / 4.6 / NFR 1.1: 通常成功ケースの
#     外形挙動を本変更前と同一に保つ）
#
# 設計判断:
#   - 主経路試行回数 6 / 待機 (0, 5, 10, 20, 40, 60) 秒 / 1 試行 timeout 15 秒
#     （Req 1.1 / 1.2 / 1.3 / 1.6 / NFR 1.2 / 1.3）。sleep 合計 135 秒で 73 秒の edge
#     cache lag を余裕を持って吸収できる。
#   - 待機は `${STAGEC_VERIFY_SLEEP_CMD:-sleep}` 経由で実行する。テストで `:` 等の
#     no-op コマンドを注入することで実時間待機なしに retry 系列を再現できる
#     （Req 5.8）。env var 名は Issue #108 の既存 fixture と互換。
#   - 主経路リトライ系列は `${STAGEC_VERIFY_DELAYS:-}` （スペース区切り秒数）と
#     `${STAGEC_VERIFY_MAX_ATTEMPTS:-}` で override 可能（Req 4.7 / NFR 3.4）。
#     未指定時のデフォルトで Req 1.1 / 1.2 / NFR 1.2 を満たす。既存 env var 名
#     （REPO / REPO_DIR / LOG / TRIAGE_MODEL / DEV_MODEL / STAGEC_VERIFY_SLEEP_CMD 等）
#     とは衝突しない新規 env var を採用している。
#   - `command -v timeout` で timeout コマンドの存在を確認し、無い環境では timeout
#     なしで gh を実行する（既存 verify_pushed_or_retry と同方針 / 既存 cron
#     互換性のため）。1 試行・代替経路ともに `${STAGEC_VERIFY_TIMEOUT_SECS:-15}` 秒
#     上限（Req 1.6 / 2.5 / NFR 1.3 / 1.4）。
#   - 代替経路は List Pulls API を直接叩く `gh api repos/{owner}/{repo}/pulls?head={owner}:BRANCH&state=all`
#     パターン。`{owner}` は `$REPO`（owner/repo 形式）から prefix を抽出。
#     edge cache の独立性を期待する経路設計のため、代替経路自体のリトライは
#     行わない（Req 2.6）。
#   - 主経路のいずれかで PR が見つかった場合、代替経路は呼び出さない（Req 2.7）。
#   - 成功時の "Stage C 完了 / PR 作成済み" 相当ログは呼び出し側に残し、本関数は
#     PR URL の取得と試行ログのみに責務を絞る。これにより Req 4.1 の「1 回目で
#     PR が確認できたとき本変更前と同じ成功ログ」を呼び出し側 echo で保証する。
verify_stagec_pr_or_retry() {
  local branch="$1"
  local issue_number="$2"

  # 試行間 sleep の注入点（テスト時に `:` 等で no-op 化できる / Req 5.8）
  local _sleep_cmd="${STAGEC_VERIFY_SLEEP_CMD:-sleep}"

  # 1 試行 / 代替経路あたりの timeout 上限秒数（Req 1.6 / 2.5 / NFR 1.3 / 1.4）
  local _timeout_secs="${STAGEC_VERIFY_TIMEOUT_SECS:-15}"

  # timeout コマンドの有無で gh 呼び出しを切り替える（既存 verify_pushed_or_retry と同方針）
  local _gh_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _gh_timeout=(timeout "$_timeout_secs")
  fi

  # 待機スケジュール（即時 / 5 / 10 / 20 / 40 / 60 秒。sleep 合計 135 秒 / Req 1.1 / NFR 1.2）
  # STAGEC_VERIFY_DELAYS env で override 可能（Req 4.7 / NFR 3.4）
  local _delays=()
  if [ -n "${STAGEC_VERIFY_DELAYS:-}" ]; then
    # shellcheck disable=SC2206  # 意図的に空白で word split する
    _delays=(${STAGEC_VERIFY_DELAYS})
  else
    _delays=(0 5 10 20 40 60)
  fi
  local _max_attempts="${STAGEC_VERIFY_MAX_ATTEMPTS:-${#_delays[@]}}"

  local attempt=1
  local pr_url="" rc=0
  local last_outcome="empty"
  while [ "$attempt" -le "$_max_attempts" ]; do
    local _delay="${_delays[$((attempt - 1))]:-0}"
    if [ "$_delay" -gt 0 ]; then
      "$_sleep_cmd" "$_delay"
    fi

    pr_url=""
    rc=0
    pr_url=$("${_gh_timeout[@]}" gh pr list --repo "$REPO" --head "$branch" --state all \
              --json url --jq '.[0].url // empty' 2>/dev/null) || rc=$?

    if [ "$rc" -eq 0 ] && [ -n "$pr_url" ]; then
      # 1 回目以降の試行回数判定: N >= 2 の場合のみ「リトライで成功」ログを残す
      # （Req 3.2 / Req 4.1 / 4.6 / NFR 1.1 を満たすため 1 回目は無 log で本変更前と外形互換）
      if [ "$attempt" -gt 1 ]; then
        echo "[$(date '+%F %T')] stageC PR verify SUCCESS attempt=${attempt}/${_max_attempts} issue=#${issue_number} branch=${branch} pr_url=${pr_url}" >> "$LOG"
      fi
      printf '%s\n' "$pr_url"
      return 0
    fi

    # 失敗種別を分類してログに残す（NFR 2.1: 試行結果を事後識別可能にする）
    local outcome=""
    if [ "$rc" -eq 124 ]; then
      outcome="timeout"
    elif [ "$rc" -ne 0 ]; then
      outcome="exit=${rc}"
    else
      outcome="empty"
    fi
    last_outcome="$outcome"
    # Req 3.1: 2 回目以降の進捗を 1 行で残す。1 回目失敗も Req 3.5「全失敗時の原因
    # 特定」のため残しておく（最終失敗時にまとめて参照できるよう attempt=1 から記録）
    echo "[$(date '+%F %T')] stageC PR verify attempt=${attempt}/${_max_attempts} outcome=${outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

    attempt=$((attempt + 1))
  done

  # ─── 主経路全試行失敗 → 代替経路（List Pulls API）への 1 ターン fallback ───
  # Req 2.1 / 2.6: 代替経路は主経路と独立に 1 回だけ呼び出す（リトライしない）。
  # Req 2.5 / NFR 1.4: 代替経路にも timeout 上限を適用する。
  local _owner="${REPO%%/*}"
  echo "[$(date '+%F %T')] stageC PR verify fallback start (List Pulls API) issue=#${issue_number} branch=${branch} owner=${_owner}" >> "$LOG"
  local _fb_url="" _fb_rc=0 _fb_outcome=""
  _fb_url=$("${_gh_timeout[@]}" gh api "repos/${REPO}/pulls?head=${_owner}:${branch}&state=all" \
            --jq '.[0].html_url // empty' 2>/dev/null) || _fb_rc=$?
  if [ "$_fb_rc" -eq 0 ] && [ -n "$_fb_url" ]; then
    # Req 2.2 / 3.4: 代替経路で救済（主経路全失敗 / 代替経路で成功）
    echo "[$(date '+%F %T')] stageC PR verify fallback SUCCESS rescued issue=#${issue_number} branch=${branch} pr_url=${_fb_url} primary_attempts=${_max_attempts}" >> "$LOG"
    printf '%s\n' "$_fb_url"
    return 0
  fi
  # Req 2.3 / 2.4 / NFR 2.2: 代替経路の結果分類（empty / timeout / exit=N / 認証失敗等）を残す
  if [ "$_fb_rc" -eq 124 ]; then
    _fb_outcome="timeout"
  elif [ "$_fb_rc" -ne 0 ]; then
    _fb_outcome="exit=${_fb_rc}"
  else
    _fb_outcome="empty"
  fi
  echo "[$(date '+%F %T')] stageC PR verify fallback FAILED outcome=${_fb_outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

  # Req 3.5: 主経路試行回数 / 最終 primary 失敗要因 / 代替経路最終結果を 1 行で残す
  echo "[$(date '+%F %T')] stageC PR verify FAILED after ${_max_attempts} attempts + fallback issue=#${issue_number} branch=${branch} last_primary_outcome=${last_outcome} fallback_outcome=${_fb_outcome}" >> "$LOG"
  return 1
}

# ─── failure 共通遷移ヘルパー ───
#
# Stage 失敗時の claude-failed 遷移を一元化。引数で原因種別と Issue コメント追加情報を受け取る。
# - $1 = stage 識別子（"stageA" / "stageA-redo" / "stageB" / "stageC" / "reviewer-error" / "reviewer-reject2"）
# - $2 = Issue コメントに追加する補足（reject 理由など。空文字可）
mark_issue_failed() {
  local stage="$1"
  local extra_body="$2"

  # run サマリ: 最終遷移を claude-failed として記録（Req 7.1, 7.2）。変数代入のみの副作用で
  # ラベル遷移 / exit code / 既存ログ行に影響しない（NFR 1.1, 1.2）。REQUIRED_MODULES で
  # run-summary.sh が source 済みのため bare 呼び出し（task 5 learning 準拠 / set -e 安全）。
  rs_set_result claude-failed

  # Issue #52: 通常経路では Stage A 開始時点で Issue は claude-picked-up のみ持つ
  # （Slot Runner が Triage 通過時に claude-claimed → claude-picked-up に付け替え済）。
  # 想定外シーケンス（design ルート Stage C 失敗で本ヘルパへ流入する等）でも残置を防ぐ
  # ため、両系統除去で安全側に倒す。gh CLI は未付与ラベルの除去を no-op として扱う。
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: ${stage}）。

ログ: \`$LOG\`"
  if [ -n "$extra_body" ]; then
    body="${body}

${extra_body}"
  fi

  # Issue #259: 現在の実行ログから Claude API 一時混雑エラー (529 Overloaded) の痕跡を
  # 検出した場合、失敗通知コメント本文に警告ブロックを差し込む。検知ロジックが失敗・
  # 例外を起こしても既存の `claude-failed` ラベル付与・失敗コメント投稿の責務を妨げない
  # よう、すべて defensive に握り、検知なし / 検知失敗時は本機能導入前と完全に同一の
  # コメントを投稿する（Req 2.4 / 4.4 / NFR 1.1）。
  local _mif_529_rc=0
  claude_log_detect_529 "$LOG" || _mif_529_rc=$?
  case "$_mif_529_rc" in
    0)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529-overloaded detected issue=#${NUMBER} stage=${stage} log=${LOG}" >> "$LOG" 2>/dev/null || true
      body="${body}

---

:warning: **Claude API 一時混雑エラー (529 Overloaded) が検出されました**: 開発中に Claude API が高負荷（529 Overloaded）となったため、処理が中断された可能性があります。一時的な混雑によるエラーの可能性があるため、時間をおいて再試行してください。"
      ;;
    2)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529 検知用ログファイルが不在または読み取り不能のためスキップ issue=#${NUMBER} stage=${stage} log=${LOG}" >> "$LOG" 2>/dev/null || true
      ;;
    *)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529-overloaded not detected issue=#${NUMBER} stage=${stage}" >> "$LOG" 2>/dev/null || true
      ;;
  esac

  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # mark_issue_failed は run_impl_pipeline 内の各 stage 失敗から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# Partial Status Gate (#148) のラベル付け替え + コメント投稿ヘルパー。
# `mark_issue_failed` の `claude-failed` 専用設計と分離し、`needs-decisions` 経路の責務を
# 1 関数に集約する。LABEL_FAILED は **付与しない**（NFR 1.3 / 既存ラベル併存禁止）。
#
# Args:
#   $1 = status_code   (NFR 2.1 / grep 可能ログ用。本関数は body 組立済前提のため値だけ受領)
#   $2 = comment_body  (build_partial_escalation_comment の出力)
# Return: 0 always（best-effort、既存 mark_issue_failed と同方針）
# 副作用:
#   1. claude-claimed / claude-picked-up を除去
#   2. needs-decisions を付与（1 コマンド原子的に発行）
#   3. escalation コメントを 1 件投稿
# Requirements: 3.3, 3.4, 3.6, NFR 1.3
mark_issue_needs_decisions() {
  local status_code="$1"
  local comment_body="$2"

  # ラベル付け替え（gh CLI は未付与ラベルの除去を no-op として扱う / 既存
  # qa_handle_quota_exceeded / mark_issue_failed と同方針で 1 コマンド原子的に発行）。
  # LABEL_FAILED (`claude-failed`) は **付与しない**（NFR 1.3 / Req 3.3, 3.4）。
  if ! gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    # best-effort: 失敗してもコメント投稿は試行（既存 quota / failed 経路と同方針）
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN ラベル付け替え失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi

  # escalation コメント投稿（best-effort）
  if ! gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN コメント投稿失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi
  return 0
}

# Partial Status Gate (#148) の coordinator。Stage A 完了直後の各経路から
# 1 行 `handle_partial_status || _rc=$?; case ...` の形で呼ばれる。
#
# 入力 (環境変数経由):
#   NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG / BASE_BRANCH
# 出力:
#   stdout なし（log のみ）
# Return:
#   0  = continue（既存フロー継続。status 行不在 or `complete`）
#   10 = partial 検出済（呼出側は run_impl_pipeline から return 0 で抜けて Reviewer skip）
#   1  = 不正 status / parse 失敗（mark_issue_failed 実行済。呼出側は return 1）
#
# 副作用:
#   - partial 検出時: `mark_issue_needs_decisions` 経由でラベル付け替え + コメント投稿
#     + grep 可能ログ 1 行（NFR 2.1）
#   - 不正値時: `mark_issue_failed` 実行（NFR 3.1） + grep 可能ログ
#   - continue 時: 副作用なし（既存挙動と外形等価 / NFR 1.1, 1.4）
#
# 不変条件:
#   - 既存 `LABEL_NEEDS_DECISIONS` 以外のラベルを新規生成しない（Req 3.3, 3.4 / NFR 1.3）
#   - 戻り値 10 は run_impl_pipeline 既存 return code 0/1 と衝突しない（quota 99 とも区別）
#
# Requirements: 1.3, 3.1, 3.2, 3.5, NFR 1.1, NFR 1.4, NFR 2.1, NFR 3.1, NFR 3.2
handle_partial_status() {
  local impl_notes="$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"
  local status_code rc=0
  status_code=$(detect_partial_status "$impl_notes") || rc=$?
  case "$rc" in
    1|2)
      # STATUS 行不在 or ファイル不在 → continue（NFR 1.1 / NFR 3.2）
      # 既存挙動と外形完全等価（partial gate 導入前と同じ Stage B 起動経路へ）
      return 0
      ;;
    0)
      case "$status_code" in
        complete)
          # 明示的 complete = continue（NFR 1.4）
          return 0
          ;;
        partial_blocked|partial_overrun)
          # ── partial 検出: needs-decisions エスカレーション ──
          # 1. grep 可能ログ（NFR 2.1）
          echo "[$(date '+%F %T')] [$REPO] partial-status: detected issue=#${NUMBER} status=${status_code} branch=${BRANCH}" | tee -a "$LOG"
          # 2. コメント本文組立
          local body
          body=$(build_partial_escalation_comment \
            "$status_code" \
            "$impl_notes" \
            "$REPO_DIR/$SPEC_DIR_REL/tasks.md" \
            "$BRANCH")
          # 3. ラベル付け替え + コメント投稿（best-effort）
          mark_issue_needs_decisions "$status_code" "$body"
          # 4. partial 検出を呼出側に伝搬（return 10 = Reviewer skip + run_impl_pipeline 正常終了）
          return 10
          ;;
        *)
          # ── 不正 status code（NFR 3.1） ──
          echo "[$(date '+%F %T')] [$REPO] partial-status: invalid issue=#${NUMBER} status='${status_code}'" | tee -a "$LOG"
          mark_issue_failed "partial-status-invalid" \
            "Developer 出力の \`STATUS:\` 行が \`${status_code}\` で、契約 (\`complete\` / \`partial_blocked\` / \`partial_overrun\`) のいずれにも該当しません。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    *)
      # 想定外の rc（防御的）: detect_partial_status は 0/1/2 しか返さない契約だが、
      # 未来の規約変更に備えて safe-fallback で continue を選択（既存挙動を壊さない /
      # NFR 1.1）。
      echo "[$(date '+%F %T')] [$REPO] partial-status: WARN detect_partial_status unexpected rc=$rc → continue (safe-fallback)" >&2
      return 0
      ;;
  esac
}
