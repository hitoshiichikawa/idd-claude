#!/usr/bin/env bash
# per-task-loop-exec.sh — per-task loop の Implementer/Reviewer 実行 + escalation
#
# family: per-task-loop / prefix: pt_（#500 で per-task-loop.sh から分割。family マニフェストは
#   per-task-loop.sh 冒頭ヘッダを参照）
#
# 用途:
#   task 単位の Implementer / Reviewer を実際に起動し、fail-fast・diff-range 解決失敗・
#   post-marker 検出・無進捗の各判定結果を受けて claude-failed 化する escalation を担う。
#   - run_per_task_implementer               : per-task Implementer を起動
#   - run_per_task_implementer_redo          : Implementer の redo（BLOCKED/reject 後の再実行）を起動
#   - run_per_task_reviewer                  : per-task Reviewer を起動（round 1-3 + Debugger 連携）
#   - pt_mark_fail_fast_failed               : fail-fast 時に claude-failed を付与
#   - pt_mark_diff_range_resolve_failed      : diff-range 解決失敗時に claude-failed を付与
#   - pt_mark_post_marker_commits_detected   : post-marker commit 検出時に claude-failed を付与
#   - pt_post_docs_only_auto_refresh_comment : docs-only auto-refresh 発火を事実記録として投稿
#   - pt_mark_no_progress_failed             : Implementer rc=0 だが進捗ゼロの場合に claude-failed を付与
#
# 配置先:
#   $HOME/bin/modules/per-task-loop-exec.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - mark_issue_failed（issue-watcher.sh 本体）を pt_mark_* 系から呼ぶ。
#   - qa_run_claude_stage（quota-aware.sh）を runner 3 関数から呼ぶ。
#   - per-task-loop-prompt.sh の build_per_task_implementer_prompt / build_per_task_reviewer_prompt
#     を runner から呼ぶ（遅延束縛）。
#   - グローバル変数（$MODE / $REPO_DIR / $SPEC_DIR_REL / $NUMBER / $LOG / $REVIEWER_MAX_TURNS /
#     $REVIEWER_MAX_TURNS_EXTENDED 等）は watcher-config.sh / 本体 main loop。
#   - 外部 CLI: gh / jq / git / claude（qa_run_claude_stage 経由）。

# ─── pt_mark_fail_fast_failed <task_id> <category> <target> ───
#
# fail-fast 検出時に `claude-failed` 化 + 運用者向け診断 Issue コメントを投稿する
# （Issue #305 Req 3.3, NFR 1.3, NFR 3.2）。
#
# 既存 `pt_mark_no_progress_failed` / `pt_mark_diff_range_resolve_failed` と
# 同パターンで `mark_issue_failed` に `per-task-implementer-fail-fast-loop`
# カテゴリで委譲する。新規カテゴリ追加であり既存カテゴリの意味は変更しない
# （NFR 1.3）。
#
# Args:
#   $1 = task_id  (例: `1.2`)
#   $2 = category (連続 reject 対象の Finding カテゴリ / AC 未カバー / missing test
#                  / boundary 逸脱 等)
#   $3 = target   (連続 reject 対象の Finding target / numeric requirement ID
#                  または `boundary:<component>`)
#
# 副作用（mark_issue_failed と等価 / NFR 1.3）:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿
#
# Requirements: 3.3, NFR 1.3, NFR 3.2
pt_mark_fail_fast_failed() {
  local task_id="$1"
  local category="$2"
  local target="$3"

  local extra_body
  extra_body=$(cat <<EOF
## 失敗カテゴリ
- カテゴリ: \`per-task-implementer-fail-fast-loop\`
- 対象 task ID: \`${task_id}\`
- 連続 reject 対象 Finding: Category=\`${category}\` / Target=\`${target}\`
- ログ: \`$LOG\`

## 検出条件
per-task ループの round=1 と round=2 の **連続 2 round**で Reviewer Findings が
「同一カテゴリ かつ 同一 target」を 1 件以上共有しており、かつ round=2 redo の
Developer 再実行（直前の \`run_per_task_implementer_redo\` 起動）で **テスト
ファイルに差分が積まれていない**ことを検出しました（Issue #305 Req 3.2 / 3.3）。

このまま Debugger Gate 経由 round=3 redo に進んでも、同一指摘が再度 reject される
構造になっており、turn 予算を無駄に消費するため自動進行を停止しました。

## 参照ファイル
- \`${SPEC_DIR_REL}/review-notes.md\` — 直近 round の Reviewer Findings
- \`${SPEC_DIR_REL}/debugger-notes.md\` — Debugger 経路を経た場合のみ存在
- \`${SPEC_DIR_REL}/impl-notes.md\` — Developer の Finding Closure Matrix と learning
- \`$LOG\` — watcher ログ全文（fail-fast 検出 1 行 + 直前の Reviewer 判定行）

## 次の手順
1. \`${SPEC_DIR_REL}/review-notes.md\` と \`${SPEC_DIR_REL}/impl-notes.md\` を読み、
   連続 reject されている Finding（Category=\`${category}\` / Target=\`${target}\`）の
   妥当性を確認する
2. **妥当な指摘**であれば、手動で修正 commit を積み、対応テストを追加した上で
   \`claude-failed\` ラベルを外す（次サイクルで watcher が当該 Issue を再 pickup）
3. **妥当でない指摘**（Reviewer の誤判定 / 要件側の曖昧さ）であれば、Architect /
   PM への差し戻しを判断し、必要なら requirements.md / design.md / tasks.md の
   再検討を実施する
EOF
)

  pt_log "task=${task_id} fail-fast → claude-failed (per-task-implementer-fail-fast-loop) category=${category} target=${target}" >> "$LOG"

  mark_issue_failed "per-task-implementer-fail-fast-loop" "$extra_body"
}

# ─── run_per_task_implementer <task_id> ───
#
# 当該 task 1 件のみを対象に fresh Claude session で Implementer を起動。
#
# 戻り値:
#   0  = success（Implementer が正常終了 + `docs(tasks): mark <id> as done` commit が積まれた前提）
#   1  = claude 非 0 exit / 規約違反（claude-failed は呼び出し側で付与）
#   99 = quota 超過（既存 #66 規約に従い呼び出し側に伝搬）
#
# Requirements: 2.2, 2.6, NFR 1.3, NFR 2.1, NFR 2.2
run_per_task_implementer() {
  local task_id="$1"
  local prompt
  prompt=$(build_per_task_implementer_prompt "$task_id")

  pt_log "task=$task_id implementer start (model=$DEV_MODEL, max-turns=$DEV_MAX_TURNS)" >> "$LOG"
  echo "--- per-task Implementer 実行 (task=$task_id) ---" >> "$LOG"

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-pt-impl-${task_id}-${_qa_ts}"
  _qa_stage_label="PerTask-Impl-${task_id}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      "${CLAUDE_HOOK_ARGS[@]}" \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=0" >> "$LOG"
      return 0
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=99 result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=$_qa_rc result=error" >> "$LOG"
      return 1
      ;;
  esac
}

# ─── run_per_task_implementer_redo <task_id> <redo_mode> ───
#
# Reviewer reject / Debugger 経由 redo 経路専用の Implementer 起動 wrapper。
# `run_per_task_implementer` をベースに以下 2 点のみ差分:
#
#   1. prompt 組み立て時に `build_per_task_implementer_prompt "$task_id" "$redo_mode"` を呼び、
#      Reviewer Findings / Debugger Fix Plan / Finding Closure Matrix 規約節を inline 注入する
#      （注入ロジックは build 関数側に実装済み / Issue #305 task 3 で実装）
#   2. stage_label を `PerTask-Impl-Redo-${task_id}-${redo_mode}` に変更し、quota log /
#      grep フィルタで初回起動 (`PerTask-Impl-${task_id}`) と区別可能にする
#
# `redo_mode` は build 関数側で `initial|after-round1|after-debugger` のみ受け付け、未知の値は
# 安全側に `initial` へ fallback する。本 wrapper はその値を stage_label 用にもそのまま使うが、
# stage_label への ASCII 制約は redo_mode の値域が事前定義されているため別途検証しない。
#
# 既存 `run_per_task_implementer <task_id>` は **無改変**（NFR 1.1 を構造保証）。
# BLOCKED 経路 (`run_per_task_loop` の `_pt_blocked_reason` 分岐) は本 wrapper を呼ばず
# 既存 `run_per_task_implementer` を継続使用する（BLOCKED は Reviewer reject ではないため
# Findings 注入対象外 / Issue #305 task 4）。
#
# 戻り値:
#   0  = success
#   1  = claude 非 0 exit / 規約違反（claude-failed は呼び出し側で付与）
#   99 = quota 超過（既存 #66 規約に従い呼び出し側に伝搬）
#
# Requirements: 1.1, 1.2, 4.3 (Issue #305), NFR 1.1, NFR 1.2
run_per_task_implementer_redo() {
  local task_id="$1"
  local redo_mode="$2"
  local prompt
  prompt=$(build_per_task_implementer_prompt "$task_id" "$redo_mode")

  pt_log "task=$task_id implementer-redo start (model=$DEV_MODEL, max-turns=$DEV_MAX_TURNS, redo_mode=$redo_mode)" >> "$LOG"
  echo "--- per-task Implementer Redo 実行 (task=$task_id, redo_mode=$redo_mode) ---" >> "$LOG"

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-pt-impl-redo-${task_id}-${redo_mode}-${_qa_ts}"
  _qa_stage_label="PerTask-Impl-Redo-${task_id}-${redo_mode}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      "${CLAUDE_HOOK_ARGS[@]}" \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer-redo end rc=0 redo_mode=$redo_mode" >> "$LOG"
      return 0
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer-redo end rc=99 redo_mode=$redo_mode result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer-redo end rc=$_qa_rc redo_mode=$redo_mode result=error" >> "$LOG"
      return 1
      ;;
  esac
}

# ─── run_per_task_reviewer <task_id> <round> ───
#
# 当該 task の diff range のみを対象に fresh Claude session で Reviewer を起動。
# `pt_resolve_diff_range` で range を解決し、`build_per_task_reviewer_prompt` で prompt を
# 組み立てて `claude --print` 起動 → `parse_review_result` で RESULT を抽出。
#
# 戻り値:
#   0  = approve
#   1  = reject
#   2  = 異常終了（claude crash / parse 失敗 = 装飾起因 parse 失敗）
#   3  = diff range 解決失敗（marker commit が単記でも連記でも見つからない / Issue #164）
#   4  = ファイル不在で 1 回限定リトライ後も生成されず（Issue #296 Req 2 / Req 4.2 で導入）
#   5  = post-marker commit を marker 後に検出 + POST_MARKER_RECOVERY_MODE=fail-with-diagnostic
#        （default）で停止（idd-codex #14 同型 commit shape / Issue #304 Req 2.1, 2.2, 2.3）
#   99 = quota 超過
#
# 戻り値 2 / 3 / 4 / 5 の使い分け:
#   - rc=2: claude プロセスが起動した後の異常終了（claude crash / RESULT 行欠落 = 装飾起因 parse 失敗）。
#     呼び出し側は既存の `per-task-reviewer-error` カテゴリで `claude-failed` 付与。
#   - rc=3: claude プロセス起動前に diff range が解決できなかった（marker 不在 / Issue #164 Req 4）。
#     呼び出し側は専用の復旧手順付き Issue コメントで `claude-failed` 付与する。
#     NFR 3.1 に従い「reflog で push 前 commit を回収」「1 commit = 1 task ID で分割」
#     旨を運用者向けに 5 分以内に判断できる粒度で出力する。
#   - rc=4: review-notes.md がファイル不在で 1 回限定リトライ後も生成されず（Issue #296 Req 2.3 /
#     Req 4.2）。呼び出し側は `per-task-reviewer-missing-file` カテゴリで `claude-failed` 付与し、
#     NFR 2.2 に従い装飾起因 parse 失敗（rc=2）と grep で区別可能な reason を出力する。
#   - rc=5: claude プロセス起動前に marker 後の未レビュー commit を検出した（Issue #304）。
#     `pt_mark_post_marker_commits_detected` で `per-task-post-marker-commits-detected` カテゴリの
#     `claude-failed` を本関数内で付与済みのため、呼び出し側は Issue コメント投稿を重ねずに
#     即停止（既存 rc=3 のように `pt_mark_diff_range_resolve_failed` を loop 側で呼ぶ pattern
#     と異なり、本経路は marker_sha / post_marker_list を本関数内で保持済みなため loop 側に
#     データを引き上げず本関数で完結させる）。
#
# Requirements: 3.1, 3.2, 3.3, NFR 2.1, NFR 2.2, NFR 2.3, Issue #164 Req 4.1, 4.2, 4.3, NFR 2.2,
#               Issue #304 Req 2.1, 2.2, 2.3, NFR 1.1, NFR 1.3
run_per_task_reviewer() {
  local task_id="$1"
  local round="$2"

  # diff range 解決
  local range_line range_start range_end
  if ! range_line=$(pt_resolve_diff_range "$task_id"); then
    # Issue #164 NFR 2.2: 単記 / 連記いずれの候補も見つからなかった旨を明示
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-resolve-failed detail=no-marker-commit-found(single-id-and-multi-id-both-missing)" >> "$LOG"
    return 3
  fi
  range_start=$(printf '%s' "$range_line" | cut -f1)
  range_end=$(printf '%s' "$range_line" | cut -f2)
  if [ -z "$range_start" ] || [ -z "$range_end" ]; then
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-empty detail=resolved-but-empty-pair" >> "$LOG"
    return 3
  fi

  # ─── Issue #304: post-marker commit の safety net ──────────────────────────
  # `pt_resolve_diff_range` で得た range_end（= 当該 task の marker commit）より後ろに
  # 未レビュー commit が積まれていないかを `pt_detect_post_marker_commits` で確認する。
  # idd-codex #14 同型の Implementer 契約違反（Reviewer reject 後の再実行で修正 commit を
  # 旧 marker 後ろに残置）を検出して silent range truncation を防ぐ。
  #
  # 後方互換性（NFR 1.1, 1.3）:
  #   - 検出 0 件（rc=1）: post-marker commit が無い典型シナリオ → 既存ルートで Reviewer 起動
  #   - git エラー（rc=2）: fail-safe で既存ルート fall-through（NFR 1.3 と同方針）
  #   - 検出 1 件以上（rc=0）: `pt_handle_post_marker_commits` で recovery dispatch
  #     - extend-range（rc=0）: 新 range で Reviewer を起動（range_end を HEAD まで拡張）
  #     - fail-with-diagnostic（rc=5）: `pt_mark_post_marker_commits_detected` を呼んで
  #       claude-failed を付与した上で rc=5 を呼び出し側に返す
  local post_marker_list pt_detect_rc=0 extended="false"
  post_marker_list=$(pt_detect_post_marker_commits "$range_end") || pt_detect_rc=$?
  case "$pt_detect_rc" in
    0)
      # 1 件以上検出 → recovery dispatcher を起動
      local pt_handle_out pt_handle_rc=0
      pt_handle_out=$(pt_handle_post_marker_commits "$task_id" "$round" "$range_start" "$range_end" "$post_marker_list") || pt_handle_rc=$?
      case "$pt_handle_rc" in
        0)
          # rc=0 経路は以下 2 パターンのいずれか:
          #   (a) POST_MARKER_RECOVERY_MODE=extend-range で既存どおり range を HEAD まで拡張
          #   (b) Issue #356: docs-only-auto-refresh で marker を HEAD まで auto-refresh
          # 両者は stdout フォーマット（<new_range_start>\t<new_range_end>）が同一なため、
          # 呼び出し側 では `POST_MARKER_RECOVERY_MODE` の正規化値で判別する
          # （`pt_handle_post_marker_commits` 内と同じ正規化規則）。
          local new_range_start new_range_end
          new_range_start=$(printf '%s' "$pt_handle_out" | cut -f1)
          new_range_end=$(printf '%s' "$pt_handle_out" | cut -f2)
          if [ -z "$new_range_start" ] || [ -z "$new_range_end" ]; then
            pt_log "task=$task_id reviewer start round=$round result=error reason=post-marker-extend-range-empty detail=handle-returned-empty-pair" >> "$LOG"
            # fail-safe: 拡張結果が空なら fail-with-diagnostic と同等扱いで停止
            pt_mark_post_marker_commits_detected "$task_id" "$round" "$range_end" "$post_marker_list" || true
            return 5
          fi
          local _recovery_kind="extend-range"
          local _normalized_mode="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"
          case "$_normalized_mode" in
            extend-range) _recovery_kind="extend-range" ;;
            *)            _recovery_kind="docs-only-auto-refresh" ;;
          esac
          pt_log "task=$task_id reviewer start round=$round post-marker-commits-detected recovery=${_recovery_kind} old_range_end=${range_end:0:7} new_range_end=${new_range_end:0:7}" >> "$LOG"
          if [ "$_recovery_kind" = "docs-only-auto-refresh" ]; then
            # Req 1.3: 当該 Issue に 1 行の事実記録を残す（auto-refresh が起きた task_id と理由）
            pt_post_docs_only_auto_refresh_comment "$task_id" "$round" "$range_end" "$new_range_end" "$post_marker_list" || true
          fi
          range_start="$new_range_start"
          range_end="$new_range_end"
          extended="true"
          ;;
        5)
          # fail-with-diagnostic: claude-failed を付与して rc=5 を返す
          pt_log "task=$task_id reviewer start round=$round result=error reason=per-task-post-marker-commits-detected marker=${range_end:0:7}" >> "$LOG"
          pt_mark_post_marker_commits_detected "$task_id" "$round" "$range_end" "$post_marker_list" || true
          return 5
          ;;
        *)
          # 想定外の rc: 安全側に倒して fail-with-diagnostic 相当の停止
          pt_log "task=$task_id reviewer start round=$round result=error reason=post-marker-handle-unexpected-rc rc=$pt_handle_rc marker=${range_end:0:7}" >> "$LOG"
          pt_mark_post_marker_commits_detected "$task_id" "$round" "$range_end" "$post_marker_list" || true
          return 5
          ;;
      esac
      ;;
    1)
      # 0 件 → 既存ルート（NFR 1.3 既存挙動温存）
      :
      ;;
    2)
      # git エラー → fail-safe で既存ルート fall-through（NFR 1.3 同方針）
      pt_log "task=$task_id reviewer start round=$round post-marker-commits-detect-git-error marker=${range_end:0:7} (fall-through to existing route)" >> "$LOG"
      ;;
    *)
      # 想定外の rc → fail-safe で既存ルート fall-through
      pt_log "task=$task_id reviewer start round=$round post-marker-commits-detect-unexpected-rc rc=$pt_detect_rc marker=${range_end:0:7} (fall-through to existing route)" >> "$LOG"
      ;;
  esac

  # prev_result（round=2 のみ意味あり）
  local prev_result="(none)"
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  pt_log "task=$task_id reviewer start round=$round model=$REVIEWER_MODEL max-turns=$REVIEWER_MAX_TURNS range=${range_start:0:7}..${range_end:0:7} extended=${extended}" >> "$LOG"

  local prompt
  # Issue #304 Req 3.3: post-marker recovery で extend-range 経路に入った場合は extended="true"。
  # normal 経路では extended="false"（task 5 で初期化済み）。`build_per_task_reviewer_prompt`
  # の 6 番目の引数として渡し、prompt の `range_extended:` 行と extended-range 説明文に反映。
  prompt=$(build_per_task_reviewer_prompt "$task_id" "$range_start" "$range_end" "$round" "$prev_result" "$extended")

  # Issue #296 Req 2.4 / NFR 3.1 / Req 4.2: per-task 経路でもファイル不在起因の再起動は
  # 同一 round 内で最大 1 回まで（単発経路 run_reviewer_stage と対称）。
  # Issue #442 Req 1: 上記 missing-file リトライ（for attempt in 1 2）とは直交する形で、
  # turn 切れ（error_max_turns）起因の拡張リトライを同一 round 内で最大 1 回だけ追加する。
  # `_current_max_turns`（初期 REVIEWER_MAX_TURNS）を可変化し、`_max_turns_retry_used` で
  # 1 回限定を担保する（Req 1.3）。turn 切れ以外の非ゼロ exit は従来どおり即 return 2（Req 2.1）。
  local attempt
  local parsed=""
  local parse_rc
  local _current_max_turns="$REVIEWER_MAX_TURNS"
  local _max_turns_retry_used="false"
  for attempt in 1 2; do
    if [ "$attempt" = "2" ]; then
      pt_log "task=$task_id reviewer round=$round attempt=2 retry reason=missing-file" >> "$LOG"
      echo "--- per-task Reviewer 実行 (task=$task_id, round=$round, retry attempt=2 / missing-file) ---" >> "$LOG"
    else
      echo "--- per-task Reviewer 実行 (task=$task_id, round=$round) ---" >> "$LOG"
    fi

    # Issue #442: 同一 attempt 内で turn 切れ拡張リトライを最大 1 回まで回す内側ループ。
    # 反復上限を 2（初回 + 拡張リトライ 1 回）に固定し無限ループを防ぐ（Req 1.3）。
    local _qa_rc=0 _mt_inner
    for _mt_inner in 1 2; do
      local _qa_reset_file _qa_ts _qa_stage_label _rev_log_offset
      _qa_ts=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-pt-rev-${task_id}-r${round}-a${attempt}-m${_mt_inner}-${_qa_ts}"
      _qa_stage_label="PerTask-Rev-${task_id}-r${round}-a${attempt}-m${_mt_inner}"
      # claude 実行前の $LOG 行数を記録（直前 stage の result 行誤検出を避ける / Req 2.4）。
      # token-usage.sh 未ロード時は 0（reviewer_is_error_max_turns 側で安全側に倒れる）。
      if declare -F tu_mark_log_offset >/dev/null 2>&1; then
        _rev_log_offset=$(tu_mark_log_offset)
      else
        _rev_log_offset=0
      fi
      _qa_rc=0
      qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
        claude \
          --print "$prompt" \
          --model "$REVIEWER_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$_current_max_turns" \
          --output-format stream-json \
          --verbose \
          "${CLAUDE_HOOK_ARGS[@]}" \
          >> "$LOG" 2>&1 || _qa_rc=$?

      # turn 切れ起因の非ゼロ exit のみ、同一 round 内で 1 回だけ拡張 turn 予算で再実行する。
      if [ "$_qa_rc" != "0" ] && [ "$_qa_rc" != "99" ] \
         && [ "$_max_turns_retry_used" = "false" ] \
         && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset"; then
        rm -f "$_qa_reset_file"
        _max_turns_retry_used="true"
        _current_max_turns="$REVIEWER_MAX_TURNS_EXTENDED"
        # NFR 2.1 / Req 4.6: round / attempt / 拡張 turn 予算 / reason を 1 行で記録
        pt_log "task=$task_id reviewer round=$round attempt=$attempt retry reason=max-turns-extended extended-max-turns=$_current_max_turns" >> "$LOG"
        echo "--- per-task Reviewer 実行 (task=$task_id, round=$round, retry / max-turns-extended=$_current_max_turns) ---" >> "$LOG"
        continue
      fi
      break
    done

    case "$_qa_rc" in
      0)
        rm -f "$_qa_reset_file"
        ;;
      99)
        local _qa_epoch
        _qa_epoch=$(cat "$_qa_reset_file")
        qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
        rm -f "$_qa_reset_file"
        pt_log "task=$task_id reviewer end round=$round attempt=$attempt result=quota-exceeded" >> "$LOG"
        return 99
        ;;
      *)
        rm -f "$_qa_reset_file"
        # Issue #442 Req 3.1, 3.4: 拡張リトライ後も turn 切れ枯渇なら区別された return code 6
        # （per-task-reviewer-max-turns-exhausted）で escalation。それ以外の非ゼロ exit は
        # 従来どおり即 return 2（claude crash / parse 失敗と同じ扱い / Req 2.1）。
        if [ "$_max_turns_retry_used" = "true" ] && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset"; then
          pt_log "task=$task_id reviewer end round=$round attempt=$attempt result=error reason=max-turns-exhausted extended-max-turns=$_current_max_turns" >> "$LOG"
          return 6
        fi
        pt_log "task=$task_id reviewer end round=$round attempt=$attempt result=error reason=claude-exit-nonzero rc=$_qa_rc" >> "$LOG"
        return 2
        ;;
    esac

    # review-notes.md を parse
    parse_rc=0
    parsed=$(parse_review_result "$notes_path") || parse_rc=$?
    case "$parse_rc" in
      0) break ;;
      3)
        if [ "$attempt" = "1" ]; then
          pt_log "task=$task_id reviewer round=$round attempt=1 result=missing-file" >> "$LOG"
          continue
        fi
        pt_log "task=$task_id reviewer end round=$round attempt=2 result=missing-file-after-retry" >> "$LOG"
        return 4
        ;;
      *)
        # rc=2: 装飾起因 parse 失敗（ファイルあり）。リトライしない（Req 5.3）。
        pt_log "task=$task_id reviewer end round=$round attempt=$attempt result=error reason=parse-failed" >> "$LOG"
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
      pt_log "task=$task_id reviewer end round=$round result=approve verified=$targets" >> "$LOG"
      return 0
      ;;
    reject)
      # NFR 2.3: reject 時は task ID / カテゴリ / 対応 requirement ID をログに 1 行で記録
      pt_log "task=$task_id reviewer end round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      return 1
      ;;
    *)
      pt_log "task=$task_id reviewer end round=$round result=error reason=unknown-result" >> "$LOG"
      return 2
      ;;
  esac
}

# ─── pt_mark_diff_range_resolve_failed <task_id> <round> ───
#
# diff-range-resolve-failed カテゴリで `claude-failed` を付与し、復旧手順付き Issue
# コメントを投稿する専用ヘルパー（Issue #164 Req 4）。
#
# 通常の `per-task-reviewer-error` 経路（claude crash / parse 失敗等）との違い:
#   - claude プロセス起動 **前** の失敗（marker commit 単記 / 連記いずれも見つからない）
#   - 重大なデータ損失リスク（push 前の Developer commit が次サイクル worktree reset で
#     失われる）を回避するため、運用者向けに `git reflog` 復旧手順と marker commit 分割
#     規約（1 commit = 1 task ID）を明示する
#
# 重複コメント抑制（Req 4.4）:
#   - HTML コメント marker `<!-- idd-claude:per-task-diff-range-resolve-failed:#<issue>:<task> -->`
#     を本文末尾に埋め込み、当該 Issue に同一 marker のコメントが既存なら新規投稿を skip
#     して既存コメントに「追記」する形式の単発コメントのみ追加する
#
# Args:
#   $1 = task_id (例: `1.2`)
#   $2 = round (1 / 2 / 3 のいずれか / どの round で失敗したかを Issue に明示するため)
#
# 副作用:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿（既存があれば追記コメント）
#
# Requirements: Issue #164 Req 4.1, 4.2, 4.3, 4.4, NFR 1.2, NFR 3.1
pt_mark_diff_range_resolve_failed() {
  local task_id="$1"
  local round="$2"
  local hostname_val
  hostname_val=$(hostname)
  local marker="<!-- idd-claude:per-task-diff-range-resolve-failed:#${NUMBER}:${task_id} -->"

  # NFR 1.2: 重複コメント抑制のため既存 marker を gh API で検索
  local comments_json existing_count=0
  if comments_json=$(gh issue view "$NUMBER" --repo "$REPO" --json comments 2>/dev/null); then
    existing_count=$(echo "$comments_json" | jq -r --arg marker "$marker" '
      (.comments // []) | map(select(.body | contains($marker))) | length
    ' 2>/dev/null || echo "0")
    [ -n "$existing_count" ] || existing_count=0
  fi

  # ラベル付け替え（既存 mark_issue_failed と同方針 / 1 コマンド原子的に発行）
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local body_header
  if [ "$existing_count" -gt 0 ]; then
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-diff-range-resolve-failed / round=${round}）— **追記コメント**

本 Issue には同一カテゴリ (\`diff-range-resolve-failed\` / task=\`${task_id}\`) の失敗コメントが既に存在します。
本コメントは状況が再発生したことを示す追記です。詳細な復旧手順は既存コメントを参照してください。"
  else
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-diff-range-resolve-failed / round=${round}）"
  fi

  local body
  body=$(cat <<EOF
${body_header}

## 失敗カテゴリ
- カテゴリ: \`diff-range-resolve-failed\`
- 対象 task ID: \`${task_id}\`
- 失敗 round: ${round}
- ログ: \`$LOG\`

## 原因
per-task Reviewer が当該 task の \`docs(tasks): mark ${task_id} as done\` marker commit を
\`${BASE_BRANCH}..HEAD\` 範囲で解決できませんでした（単記 marker / 連記 marker いずれも
不一致）。Developer が以下のいずれかに該当した可能性があります:

- 進捗 marker commit を作成せずに実装 commit のみで完了した
- marker commit subject が canonical 形式 \`docs(tasks): mark <id> as done\` から逸脱した
  （例: prefix 違い / suffix の追加 / typo）
- 連記 marker commit に task ID \`${task_id}\` と完全一致するトークンが含まれていない
  （Issue #164 で許容拡大した連記マッチ機構でも検出できなかった）

## 復旧手順（重要 / データ損失リスク回避）

**【重要】次サイクルで本ブランチの worktree が reset される可能性があります。**
push 前の Developer commit が残っていれば、次サイクル前に必ず以下を実施してください:

1. **push 前 commit の有無を確認**:
   \`\`\`bash
   cd <worktree-or-repo-dir>
   git reflog --date=iso | head -50
   git log --oneline ${BASE_BRANCH}..HEAD
   git status
   \`\`\`
2. **push 前 commit がある場合は手動で push して保護**:
   \`\`\`bash
   git push origin <current-branch>
   \`\`\`
   または、reflog から拾い直して別ブランチに退避:
   \`\`\`bash
   git branch <rescue-branch-name> <reflog-sha>
   git push origin <rescue-branch-name>
   \`\`\`
3. **marker commit の補完**: 不足している \`docs(tasks): mark ${task_id} as done\` commit を
   手動で作成（tasks.md の \`- [ ]\` → \`- [x]\` を 1 行編集して 1 commit）してから
   \`claude-failed\` ラベルを外す。これにより次サイクルで watcher が当該 task を resume できる

## 推奨される marker commit 分割の規約（1 commit = 1 task ID）

per-task Reviewer の diff range 解決は **task ID 単位**で行われます。Developer は以下を厳守すること:

- **1 つの \`docs(tasks): mark <id> as done\` commit には 1 つの task ID のみを含める**
- 親 task の完了昇格も **別 commit に分割**する（例: 子 \`1.1\` 完了で親 \`1\` も全完了に
  なる場合、\`docs(tasks): mark 1.1 as done\` と \`docs(tasks): mark 1 as done\` を別 commit
  にする）
- 連記表記（\`mark 1 / 1.1 as done\` / \`mark 1, 1.1 as done\`）は watcher が fallback 解決を
  試行するが、canonical ではない。発見次第、commit を分割し直すこと

詳細は \`repo-template/.claude/agents/developer.md\` の「per-task ループ下での Implementer の
責務」節を参照してください。

${marker}
EOF
)

  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── pt_mark_post_marker_commits_detected <task_id> <round> <marker_sha> <post_marker_list> ───
#
# `per-task-post-marker-commits-detected` カテゴリで `claude-failed` を付与し、復旧手順付き
# Issue コメントを投稿する専用ヘルパー（Issue #304 Req 2.3, NFR 2.1）。
#
# 通常の `per-task-reviewer-error` 経路（claude crash / parse 失敗等）および
# `diff-range-resolve-failed`（marker 不在）との違い:
#   - marker commit は見つかったが、その後ろに未レビュー commit が積まれた状態を検出した
#     ケース（idd-codex #14 同型 / Implementer 契約違反: marker を task の終端 commit として
#     refresh せずに修正 commit を旧 marker 後ろに残置）
#   - silent range truncation（marker で range_end を止めて post-marker commit を見逃す）を
#     防ぐため、`POST_MARKER_RECOVERY_MODE=fail-with-diagnostic`（default）経路で
#     `run_per_task_reviewer` 起動を中止し、本ヘルパーで運用者向けの復旧手順を提示する
#
# 重複コメント抑制:
#   - HTML コメント marker `<!-- idd-claude:per-task-post-marker-commits-detected:#<issue>:<task> -->`
#     を本文末尾に埋め込み、当該 Issue に同一 marker のコメントが既存なら新規投稿を skip
#     して既存コメントに「追記」する形式の単発コメントのみ追加する
#     （`pt_mark_diff_range_resolve_failed` と同パターン）
#
# Args:
#   $1 = task_id (例: `1.2`)
#   $2 = round (1 / 2 / 3 のいずれか / どの round で検出したかを Issue に明示するため)
#   $3 = marker_sha (検出時の対象 marker commit SHA)
#   $4 = post_marker_list (改行区切りの post-marker SHA 列。`git log --format=%H` 由来 /
#        新しい順 / 0 件の状態では本関数は呼ばれない想定だが空文字を許容する)
#
# 副作用:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿（既存があれば追記コメント）
#
# Requirements: Issue #304 Req 2.3, NFR 2.1
pt_mark_post_marker_commits_detected() {
  local task_id="$1"
  local round="$2"
  local marker_sha="$3"
  local post_marker_list="$4"
  local hostname_val
  hostname_val=$(hostname)
  local marker="<!-- idd-claude:per-task-post-marker-commits-detected:#${NUMBER}:${task_id} -->"

  # post-marker SHA を CSV / bullet 表記に整形（NFR 2.1: 観測可能性）
  local post_csv post_bullets
  post_csv=$(printf '%s' "$post_marker_list" | tr '\n' ',' | sed 's/,$//')
  post_bullets=$(printf '%s\n' "$post_marker_list" | sed '/^$/d' | sed 's/^/  - `/' | sed 's/$/`/')

  # 重複コメント抑制のため既存 marker を gh API で検索
  local comments_json existing_count=0
  if comments_json=$(gh issue view "$NUMBER" --repo "$REPO" --json comments 2>/dev/null); then
    existing_count=$(echo "$comments_json" | jq -r --arg marker "$marker" '
      (.comments // []) | map(select(.body | contains($marker))) | length
    ' 2>/dev/null || echo "0")
    [ -n "$existing_count" ] || existing_count=0
  fi

  # ラベル付け替え（既存 mark_issue_failed / pt_mark_diff_range_resolve_failed と同方針 /
  # 1 コマンド原子的に発行）
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local body_header
  if [ "$existing_count" -gt 0 ]; then
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-post-marker-commits-detected / round=${round}）— **追記コメント**

本 Issue には同一カテゴリ (\`per-task-post-marker-commits-detected\` / task=\`${task_id}\`) の失敗コメントが既に存在します。
本コメントは状況が再発生したことを示す追記です。詳細な復旧手順は既存コメントを参照してください。"
  else
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-post-marker-commits-detected / round=${round}）"
  fi

  local body
  body=$(cat <<EOF
${body_header}

## 失敗カテゴリ
- カテゴリ: \`per-task-post-marker-commits-detected\`
- 対象 task ID: \`${task_id}\`
- 失敗 round: ${round}
- 対象 marker SHA: \`${marker_sha}\`
- post-marker SHA リスト（新しい順 / CSV）: \`${post_csv}\`
- post-marker SHA リスト（詳細）:
${post_bullets}
- ログ: \`$LOG\`

## 原因
per-task Reviewer 起動前の safety net (\`pt_detect_post_marker_commits\`) が、当該 task の
\`docs(tasks): mark ${task_id} as done\` marker commit (\`${marker_sha}\`) より後ろに、未レビューの
commit が積まれている状態を検出しました。このまま Reviewer を起動すると range_end が marker
で止まり、post-marker commit が判定対象から漏れる **silent range truncation** を引き起こすため、
\`POST_MARKER_RECOVERY_MODE=fail-with-diagnostic\`（default）に従って Reviewer 起動前に停止しました
（idd-codex #14 同型の failure mode 予防 / Issue #304）。

Implementer 側で以下のいずれかに該当した可能性があります:

- Reviewer reject / Debugger guidance 後の再実行で、修正 commit を旧 marker 後ろに積んだまま
  marker を refresh しなかった
- marker contract（marker は task の終端 commit / retry 時に refresh）に違反した順序で
  marker commit を作成した

## 復旧手順（重要 / データ損失リスク回避）

**【重要】次サイクルで本ブランチの worktree が reset される可能性があります。**
push 前の Developer commit が残っていれば、次サイクル前に必ず以下を実施してください:

1. **push 前 commit の有無と現状の commit 列を確認**:
   \`\`\`bash
   cd <worktree-or-repo-dir>
   git reflog --date=iso | head -50
   git log --oneline ${BASE_BRANCH}..HEAD
   git status
   \`\`\`
2. **push 前 commit がある場合は手動で push して保護**:
   \`\`\`bash
   git push origin <current-branch>
   \`\`\`
   または、reflog から拾い直して別ブランチに退避:
   \`\`\`bash
   git branch <rescue-branch-name> <reflog-sha>
   git push origin <rescue-branch-name>
   \`\`\`
3. **marker commit を refresh**（marker を task の終端 commit に戻す）:
   - 推奨 (a): 旧 marker を \`git reset --soft <marker^>\` で剥がし、修正 commit を含めた状態で
     新 marker を末尾に作り直す
   - 推奨 (b): \`git rebase -i ${BASE_BRANCH}\` で marker commit を tip に移動し、続けて
     marker SHA を更新する
   - いずれの場合も「\`docs(tasks): mark ${task_id} as done\` commit が \`${BASE_BRANCH}..HEAD\` の
     最終 commit」になっていることを \`git log --oneline ${BASE_BRANCH}..HEAD\` で確認すること
4. **修正完了後**: 修正 push を実施し、\`claude-failed\` ラベルを外すと watcher が次サイクルで
   再 pickup する

## Marker contract（再周知）

per-task Implementer は以下の contract を厳守してください（詳細は
\`repo-template/.claude/agents/developer.md\` の「per-task ループ下での Implementer の責務」節
「Marker contract」subsection を参照）:

- \`docs(tasks): mark <id> as done\` marker commit は、当該 task の **終端 commit**。
  実装・テスト・learning 追記が完了した時点でのみ作成する
- Reviewer reject / Debugger guidance 後の再実行では、修正 commit を旧 marker 後ろに残してはならない。
  必要なら旧 marker を剥がして新 marker を末尾に積み直す（marker refresh）
- 1 commit = 1 task ID（連記 \`mark 1 / 1.1 as done\` を作らない / 親 task 完了昇格は別 commit）

## 切替 env（運用者向け / 通常は変更不要）

- \`POST_MARKER_RECOVERY_MODE=fail-with-diagnostic\`（**default**）: 本コメントのような失敗扱いで停止
- \`POST_MARKER_RECOVERY_MODE=extend-range\`: marker を捨てて HEAD まで range を拡張して
  Reviewer を起動（marker contract 違反を黙って吸収するため、Implementer 側の修正契約が
  弱くなる点に注意）

${marker}
EOF
)

  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── pt_post_docs_only_auto_refresh_comment <task_id> <round> <old_marker_sha> <new_range_end_sha> <post_marker_list> ───
#
# Issue #356: docs-only auto-refresh が発火したことを当該 Issue に 1 行の事実記録として残す
# 専用ヘルパー（Req 1.3）。`pt_mark_post_marker_commits_detected` と異なりラベル付け替えは
# 行わず、`claude-failed` も付与しない（auto-refresh 続行のため）。
#
# 重複コメント抑制:
#   - HTML コメント marker `<!-- idd-claude:per-task-post-marker-docs-only-auto-refresh:#<issue>:<task> -->`
#     を本文末尾に埋め込み、当該 Issue に同一 marker のコメントが既存なら新規投稿を skip する
#     （既存コメント末尾への追記もしない / 同一 task で auto-refresh が複数回発火した場合の
#     コメント増殖を抑制）。
#
# Args:
#   $1 = task_id
#   $2 = round
#   $3 = old_marker_sha (auto-refresh 前の marker SHA)
#   $4 = new_range_end_sha (auto-refresh 後の new range_end = HEAD SHA)
#   $5 = post_marker_list (改行区切りの post-marker SHA 列)
#
# 副作用:
#   - 既存マーカー無し: 1 件 Issue コメントを投稿
#   - 既存マーカー有り: 何もしない（rc=0）
#
# Requirements: Issue #356 Req 1.3, NFR 1.3, NFR 2.2
pt_post_docs_only_auto_refresh_comment() {
  local task_id="$1"
  local round="$2"
  local old_marker_sha="$3"
  local new_range_end_sha="$4"
  local post_marker_list="$5"
  local marker="<!-- idd-claude:per-task-post-marker-docs-only-auto-refresh:#${NUMBER}:${task_id} -->"

  local post_csv post_bullets
  post_csv=$(printf '%s' "$post_marker_list" | tr '\n' ',' | sed 's/,$//')
  post_bullets=$(printf '%s\n' "$post_marker_list" | sed '/^$/d' | sed 's/^/  - `/' | sed 's/$/`/')

  # 重複コメント抑制
  local comments_json existing_count=0
  if comments_json=$(gh issue view "$NUMBER" --repo "$REPO" --json comments 2>/dev/null); then
    existing_count=$(echo "$comments_json" | jq -r --arg marker "$marker" '
      (.comments // []) | map(select(.body | contains($marker))) | length
    ' 2>/dev/null || echo "0")
    [ -n "$existing_count" ] || existing_count=0
  fi

  if [ "$existing_count" -gt 0 ]; then
    return 0
  fi

  local body
  body=$(cat <<EOF
ℹ️ per-task post-marker docs-only auto-refresh が発火しました（task=\`${task_id}\` / round=${round}）。

\`docs(tasks): mark ${task_id} as done\` marker commit (\`${old_marker_sha}\`) より後ろに、
docs-only allowlist（\`POST_MARKER_DOCS_ALLOWLIST\` 既定: \`**/impl-notes.md,docs/specs/**/*.md\`）
内のファイルのみで構成される commit が積まれている状態を検出したため、
marker を HEAD (\`${new_range_end_sha}\`) まで auto-refresh して per-task Reviewer を続行します。
本コメントは事実記録のみであり、自動開発は停止していません。

- 旧 marker SHA: \`${old_marker_sha}\`
- 新 range_end SHA: \`${new_range_end_sha}\`
- post-marker SHA リスト（新しい順 / CSV）: \`${post_csv}\`
- post-marker SHA リスト（詳細）:
${post_bullets}

参考: 本判定は Issue #356 の docs-only auto-refresh 機能によるものです。
${marker}
EOF
)

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── pt_mark_no_progress_failed <task_id> <stage_phase> <check_rc> ───
#
# per-task Implementer が rc=0 で終了したにもかかわらず対象 task の
# `- [ ] → - [x]` 遷移が検出できなかった場合に `claude-failed` 化する専用ヘルパー
# （Issue #263）。`mark_issue_failed` を流用し、stage 識別子と Issue コメント本文だけを
# 本機能用に組み立てる（NFR 1.2: 既存失敗ハンドラの挙動を変更せず流用のみ）。
#
# Args:
#   $1 = task_id (例: `1.2`)
#   $2 = stage_phase (`initial` / `blocked-redo` / `round2-redo` / `round3-redo`)
#        Implementer 呼出 4 箇所のどの段階で進捗ゼロが検出されたかを識別する
#   $3 = check_rc (`1` = `- [ ]` のまま / `2` = 該当行不在 or tasks.md 不在)
#
# 副作用（mark_issue_failed と等価 / Req 2.1, 2.2, 4.x, NFR 1.2）:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿
#   3. watcher ログに grep 可能な 1 行を出力（呼び出し側で pt_log を発射する想定）
#
# Requirements: #263 Req 2.1, 2.2, 2.5, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, NFR 1.2, NFR 2.1
pt_mark_no_progress_failed() {
  local task_id="$1"
  local stage_phase="$2"
  local check_rc="$3"

  local cause_desc
  case "$check_rc" in
    2)
      cause_desc="tasks.md 上で task=\`${task_id}\` に対応する \`- [ ]\` / \`- [x]\` 行が見つかりませんでした（tasks.md 読取失敗 / 該当行不在）。fail-safe として無限ループに入る前に停止します（Req 5.3）。"
      ;;
    *)
      cause_desc="tasks.md 上の task=\`${task_id}\` 行が \`- [ ]\` のまま \`- [x]\` に遷移していません。Implementer が編集失敗（置換競合・コンパイルエラー等）から復旧できなかった可能性があります。"
      ;;
  esac

  local extra_body
  extra_body=$(cat <<EOF
## 失敗カテゴリ
- カテゴリ: \`per-task-implementer-no-progress\`
- 対象 task ID: \`${task_id}\`
- 検出フェーズ: \`${stage_phase}\` (Implementer 呼出 4 箇所のいずれか: initial / blocked-redo / round2-redo / round3-redo)
- 判定根拠: pt_check_task_completed rc=${check_rc}
- ログ: \`$LOG\`

## 原因
per-task Implementer が rc=0（正常終了扱い）で終了したにもかかわらず、対象 task の
\`- [ ]\` → \`- [x]\` 遷移が \`tasks.md\` で確認できませんでした。${cause_desc}

このまま再開すると次 tick の dispatcher が同じ Issue を再 pickup し、Implementer が同じ
失敗を rc=0 で繰り返す無限リトライループに陥るため、自動再開を停止しました（Issue #263）。

## 次の手順
1. watcher ログ \`$LOG\` を確認し、当該 task=\`${task_id}\` の Implementer 実行で
   何が失敗していたか（編集競合・テスト失敗・prompt 不備等）を特定する
2. 必要なら手動で修正 commit を積み、tasks.md の該当行を \`- [x]\` に更新する
   （または Architect 差し戻し / Issue 分割を判断する）
3. 復旧操作完了後、Issue から \`claude-failed\` ラベルを外すと watcher が次サイクルで
   再 pickup する
EOF
)

  # grep 可能ログを 1 行出力（NFR 2.1, NFR 2.2 / 既存 per-task ログ書式と整合）
  pt_log "task=${task_id} implementer end rc=0 progress=zero phase=${stage_phase} check_rc=${check_rc} → claude-failed (per-task-implementer-no-progress)" >> "$LOG"

  mark_issue_failed "per-task-implementer-no-progress" "$extra_body"
}

