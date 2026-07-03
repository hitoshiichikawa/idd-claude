#!/usr/bin/env bash
# impl-pipeline.sh — Reviewer Gate／impl 系 stage 分割パイプライン モジュール（family orchestrator）
#
# family: impl-pipeline / prefix: なし
#   #501 で本モジュールを責務単位の module family へ分割した。orchestrator（本ファイル）と
#   2 つの sub-file が family を構成する（impl-pipeline 固有の非 prefix 関数群のため、pt_ / pi_ 等の
#   共有 prefix は持たない）。分割マニフェスト（どの関数がどのファイルにあるか）:
#     - impl-pipeline.sh         … 本ファイル: Stage 状態機械本体 + 補助ガード
#         run_impl_pipeline（impl / impl-resume の Stage 状態機械）/
#         stage_a_verify_round1_defer（stage-a-verify round=1 差し戻しの再 pickup 化）/
#         _assert_base_branch_resolved（BASE_BRANCH 空値ガード）
#     - impl-pipeline-prompt.sh  … Stage prompt builders
#         build_dev_prompt_a / build_dev_prompt_redo / build_dev_prompt_redo_with_fix_plan /
#         build_reviewer_prompt / build_dev_prompt_c
#     - impl-pipeline-review.sh  … Reviewer stage 実行 + 検証 + escalation
#         run_reviewer_stage / reviewer_skip_files_match / _reviewer_skip_check /
#         publish_terminal_failure_artifacts / verify_pushed_or_retry / verify_stagec_pr_or_retry /
#         mark_issue_failed / mark_issue_needs_decisions / handle_partial_status
#
# 用途:
#   `run_impl_pipeline` が impl / impl-resume モードを Stage A（PM + Developer）/ Stage B
#   （Reviewer round=1）/ Stage A'（Developer 再実行）/ Stage B'（Reviewer round=2）/ Stage C
#   （PjM = PR 作成）へ分割して駆動する Stage 状態機械の本体。prompt 組み立ては
#   impl-pipeline-prompt.sh、Reviewer 起動・push/PR 検証・claude-failed 遷移は
#   impl-pipeline-review.sh の関数群を呼び出す（family 内 cross-file 呼び出しは遅延束縛で解決）。
#
#   詳細: docs/specs/20-phase-1-reviewer-subagent-gate/design.md
#
# 配置先:
#   $HOME/bin/modules/impl-pipeline*.sh（install.sh が modules/*.sh を glob 配布するため、
#   family の全ファイルが同時に配布される）。
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - family の sub-file は REQUIRED_MODULES で orchestrator より前に登録する（bash の遅延束縛
#     により source 順は不問だが、規約に従い sub → orchestrator の順に並べる）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 実行時に本体グローバル（$NUMBER / $TITLE / $URL / $BODY / $BRANCH / $SPEC_DIR_REL / $MODE /
#     $ARCHITECT_REASON / $REPO / $BASE_BRANCH 等）を Slot Runner 実行時に参照（呼び出し時解決 /
#     bash 遅延束縛で loader が全 module source 後に解決）。
#   - impl-pipeline-prompt.sh の build_dev_prompt_* / build_reviewer_prompt、
#     impl-pipeline-review.sh の run_reviewer_stage / verify_pushed_or_retry /
#     verify_stagec_pr_or_retry / mark_issue_failed / handle_partial_status を
#     run_impl_pipeline から呼ぶ（遅延束縛）。
#   - `_assert_base_branch_resolved` は run_impl_pipeline（Stage C 直前）と slot-worker.sh
#     （design 分岐）の両方から呼ばれる（Req 1.5）。
#   - 外部 CLI: gh / jq / git / claude（呼び出し先の各 stage 経由）。

# ─── _assert_base_branch_resolved ───
#
# Issue #96 Req 1.5: PR 作成系プロンプト（Stage C / design-review）を組み立てる直前に
# 解決済み `BASE_BRANCH` の実値が空文字でないことを検証する防御的ガード。
# 通常パスでは起動直後の `BASE_BRANCH="${BASE_BRANCH:-main}"` で必ず非空になるため
# 発火しないが、コード変更で誤って空文字を導入した場合に PR 作成段階で爆破するためのもの。
#
# 失敗時の挙動: stderr にエラー出力し、戻り値 1 を返す。呼び出し側（pipeline / design 分岐）が
# `_slot_mark_failed` で `claude-failed` ラベルを付与して人間にエスカレーションする。
_assert_base_branch_resolved() {
  if [ -z "${BASE_BRANCH:-}" ]; then
    echo "Error: BASE_BRANCH が空または未定義です。PR 作成プロンプトを組み立てられません（Issue #96 Req 1.5）" >&2
    return 1
  fi
  return 0
}

# ─── stage_a_verify_round1_defer ───
#
# stage-a-verify round=1 差し戻し時に、当該 Issue を再 pickup 可能な bare auto-dev
# candidate へ戻すためのラベル除去を行う（Issue #219）。`claude-picked-up` を残すと
# dispatcher の候補クエリ（`-label:"$LABEL_PICKED"`）から除外され二度と再 pickup されず
# stuck になるため、per-task hold (#198) と同様に claude-picked-up / claude-claimed を
# 除去して次 tick の再 pickup → Stage Checkpoint resume → stage-a-verify 再評価
# （round=2 escalate への前進）を成立させる。round counter sidecar は呼び出し側で
# 温存されるため、次回失敗で round=2 → claude-failed に進む。
#
# 入力 (環境変数経由): NUMBER / REPO / LOG / LABEL_PICKED / LABEL_CLAIMED
# 副作用: gh issue edit（ラベル除去） / $LOG への grep 可能なログ 1 行
# 戻り値: 0 = ラベル除去成功 / 1 = gh 失敗（fail-open。呼び出し側は return 3 を維持し、
#         ラベル残置の旨を警告ログに残す。手動除去で復旧可能）
stage_a_verify_round1_defer() {
  if gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] stage-a-verify: round=1 差し戻し: claude-picked-up 除去 → bare auto-dev candidate へ復帰（次 tick 再 pickup / issue=#$NUMBER）" >> "$LOG"
    return 0
  fi
  echo "[$(date '+%F %T')] stage-a-verify: WARN: round=1 差し戻しで claude-picked-up 除去に失敗（ラベル残置 → 次 tick で候補に上がらない恐れ / 手動除去で復旧可能 / issue=#$NUMBER）" >> "$LOG"
  return 1
}

# ─── run_impl_pipeline ───
#
# impl / impl-resume モードの Stage 状態機械を実装する。
#
#   START → Stage A → Stage B(round=1)
#                    ├─ approve → Stage C → TERMINAL_OK
#                    ├─ reject  → Stage A' → Stage B(round=2)
#                    │                       ├─ approve → Stage C → TERMINAL_OK
#                    │                       ├─ reject  → TERMINAL_FAILED (with Issue comment)
#                    │                       └─ error   → TERMINAL_FAILED (with $LOG path)
#                    └─ error   → TERMINAL_FAILED (with $LOG path)
#
#   Stage A / A' / C の非 0 exit は既存 Developer 失敗時遷移と同等メッセージ。
#
# Stage Checkpoint Resume (#68, デフォルト有効 / #112): `STAGE_CHECKPOINT_ENABLED=true`
#   （既定）のときに、関数冒頭で stage_checkpoint_resolve_resume_point を呼び
#   START_STAGE を取得する。START_STAGE ∈ {A, B, C, TERMINAL_OK, TERMINAL_FAILED}。
#     - TERMINAL_OK     → 既存 impl PR 検出。何もせず return 0（自動進行停止、ラベル不変）
#     - TERMINAL_FAILED → round=2 reject 残骸検出。claude-failed 化して return 1
#     - A               → 通常通り Stage A から実行（fallback / no-checkpoint / INCONSISTENT）
#     - B               → Stage A をスキップ（既存 impl-notes.md を再利用）
#     - C               → Stage A / Stage B をスキップ（既存 impl-notes / approve を再利用）
#   `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）では resolve は呼ばず、本関数は本機能
#   導入前と 1 行も挙動を変えない（NFR 1.1）。
#
# stage-a-verify gate (#125, デフォルト有効): `STAGE_A_VERIFY_ENABLED=true`（既定）の
#   ときに、Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク
#   （build/test/lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
#   （START_STAGE=B|C）でも本ブロックを通すため、Stage Checkpoint resume 経由のフロー
#   でも gate が機能する。`STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run
#   が即 return 0 して本機能導入前と user-observable に完全同一の挙動になる
#   （Req 4.1 / NFR 1.1）。失敗時は round=1 で Developer 差し戻し（**return 3 / 再 pickup
#   可能な保留・claude-failed 未付与**, Issue #219）、round=2 で claude-failed escalate
#   （return 1、内部で mark_issue_failed 済）。
#
# 入力 (環境変数経由): NUMBER, TITLE, BODY, URL, BRANCH, MODE, SPEC_DIR_REL, LOG, REPO,
#                      DEV_MODEL, DEV_MAX_TURNS, REVIEWER_MODEL, REVIEWER_MAX_TURNS,
#                      STAGE_CHECKPOINT_ENABLED (#68, default=true since #112),
#                      STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT /
#                      STAGE_A_VERIFY_COMMAND (#125)
# 戻り値:
#   0 = pipeline 成功（Stage C も成功 / PR 作成済み）または TERMINAL_OK 相当の停止
#   3 = 再 pickup 可能な保留（stage-a-verify round=1 差し戻し / Issue #219）。claude-failed
#       未付与・claude-picked-up 除去済みで次 tick に再評価される
#   1 = Stage A / A' / B / B' / C / stage-a-verify round=2 いずれかで失敗 → claude-failed 既に付与済み
run_impl_pipeline() {
  local prompt_a prompt_redo prompt_c
  local rev_rc
  # START_STAGE: STAGE_CHECKPOINT_ENABLED=true（既定）時は resolve_resume_point が
  # 値を上書きする。`=false` 明示時は "A" 固定で本機能導入前と完全一致
  # （Req 3.2 / NFR 1.1）。
  local START_STAGE="A"
  # Issue #219 Req 2.4: Stage A 完了直後の越境観測（stage_a_crossing_probe）が set し、
  # pipeline 末尾の spec_artifacts_completeness_guard へ引き継ぐ越境検出フラグ。既存
  # START_STAGE と同じく run_impl_pipeline スコープで保持する（Data Models）。set/read は
  # 別途定義された関数間の dynamic scope 経由のため SC2034 を抑制する（START_STAGE と同様）。
  # shellcheck disable=SC2034
  local STAGE_A_CROSSING_DETECTED="no"
  # shellcheck disable=SC2034
  local STAGE_A_CROSSING_PR=""

  # Stage Checkpoint Resume (#68): START_STAGE を resolve_resume_point で上書き。
  # `STAGE_CHECKPOINT_ENABLED=false` 明示時は本ブロックを skip し START_STAGE="A"
  # のままで、本機能導入前と完全等価な挙動になる（NFR 1.1）。
  # `:-true` で `unset` も既定有効として扱う（#112 でデフォルト反転）。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" = "true" ]; then
    if ! stage_checkpoint_resolve_resume_point; then
      sc_warn "resolve 異常 → Stage A 起点で安全フォールバック" >> "$LOG"
      START_STAGE="A"
    fi
    case "$START_STAGE" in
      TERMINAL_OK)
        sc_log "既存 impl PR 検出 → Stage C 再実行を停止 (Req 2.6)" >> "$LOG"
        echo "✅ #$NUMBER: 既存 impl PR を検出（Stage Checkpoint）→ 自動進行を停止" | tee -a "$LOG"
        return 0
        ;;
      TERMINAL_FAILED)
        sc_log "round=2 reject 残骸検出 → claude-failed 化 (Req 2.5)" >> "$LOG"
        echo "❌ #$NUMBER: Reviewer round=2 reject の checkpoint 残骸検出 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "stage-checkpoint-terminal-failed" \
          "Reviewer round=2 reject の checkpoint が当該 branch に残っているため、自動進行を停止します。\`${SPEC_DIR_REL}/review-notes.md\` の RESULT 行を確認し、人間判断で対応してください。"
        return 1
        ;;
    esac
  fi

  # ── Stage A: PM + Developer（impl-resume では PM スキップ / Stage Checkpoint resume 時は skip 可）──
  #
  # Phase 2 (#21): `PER_TASK_LOOP_ENABLED=true` のときは Stage A の実体を
  # `run_per_task_loop`（task 単位 fresh Implementer + fresh Reviewer のループ）に
  # 置き換える Strategy 分岐を挿入する。`PER_TASK_LOOP_ENABLED` 未指定 / `=true` 以外
  # では従来の単一 Developer 起動経路に流れ、本機能導入前と外形挙動は完全一致する
  # （Req 1.1 / NFR 1.1）。loop 完了後の verify_pushed_or_retry / stage-a-verify /
  # Stage B / Stage C は分岐の外で従来通り実行される（NFR 1.4）。
  case "$START_STAGE" in
    A)
      # per-task loop は `tasks.md` が存在する場合にのみ起動する。`PER_TASK_LOOP_ENABLED=true`
      # でも tasks.md 不在（Architect 不要 triage を通過した Issue 等）の場合は、Issue を
      # 失敗扱いせず従来の単一 Developer 経路（else ブランチ）へフォールバックする（#166 /
      # Req 1.1, 1.2, 3.1）。判定を if 条件に畳むことで、従来 Stage A ブロックを重複させずに
      # 到達させる（NFR 2.1: per-task ループ dispatcher 本体は変更しない）。
      local _pt_tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
      local _pt_loop_enabled=false
      if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then
        if [ -f "$_pt_tasks_md" ]; then
          _pt_loop_enabled=true
        else
          # AC5: フォールバック発生を判別可能なログ行を slot ログに出力（claude-failed は付けない）
          echo "--- per-task: tasks.md 不在 → Stage A fallback（$_pt_tasks_md）---" | tee -a "$LOG"
        fi
      fi
      if [ "$_pt_loop_enabled" = "true" ]; then
        echo "--- Stage A 実行（$MODE / per-task loop / PER_TASK_LOOP_ENABLED=true）---" >> "$LOG"
        if ! run_per_task_loop; then
          # run サマリ: Stage A は実行された（claude-failed 終端でも stage は走った / Req 2.1）。
          rs_record_stage A
          rs_scan_degraded_log "$LOG"
          # run_per_task_loop 内で claude-failed 付与済 / 既に Issue コメント済。
          return 1
        fi
        # run サマリ: Stage A（per-task loop）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
        rs_record_stage A
        rs_scan_degraded_log "$LOG"
        # ── per-task 全 task 完了ゲート (#194) ──
        # `run_per_task_loop` の `return 0` は「全 task 消化成功」と「quota 超過等による
        # 中間早期 return」の双方を含むため、戻り値 0 だけでは全 task 完了を保証できない。
        # ここで tasks.md を再読込し、必須 task（deferrable `- [ ]*` を除く `- [ ]`）が
        # 1 件でも残っていれば Reviewer / PR / ready-for-review へ進めず、未完了状態として
        # `return 0`（resumable）で抜ける。後続 tick の Resume Processor が残り task を消化する。
        # mark_issue_failed は呼ばない（失敗ではなく中断のため。quota 早期 return と同じ扱い）。
        # 本ゲートは `_pt_loop_enabled=true` 分岐内にのみ存在し、PER_TASK_LOOP 無効時の
        # 通常 Developer 経路（else ブランチ）には一切影響しない（Req 1.1, 1.3, 1.4, 1.5, 2.1, NFR 1.1）。
        local _pt_remaining
        _pt_remaining=$(pt_extract_pending_tasks "$_pt_tasks_md" || true)
        if [ -n "$_pt_remaining" ]; then
          local _pt_remaining_count
          _pt_remaining_count=$(printf '%s\n' "$_pt_remaining" | wc -l | tr -d '[:space:]')
          pt_log "issue=#${NUMBER} 必須未完了 task=${_pt_remaining_count} 残存 → ready-for-review 遷移を保留し resumable return 0（残: $(printf '%s' "$_pt_remaining" | tr '\n' ' '))" | tee -a "$LOG"
          echo "⏸️ #$NUMBER: per-task ループ終了時に必須未完了 task が ${_pt_remaining_count} 件残存 → ready-for-review へ進めず後続 tick で再開" | tee -a "$LOG"
          # ── 保留前の完了済み task commit を origin に push (#198 欠陥②: push-skip) ──
          # per-task ループ内に逐次 push は無く、Implementer は commit のみを積む（push は
          # 本 Stage A 末尾の verify_pushed_or_retry に集約される設計）。従来この保留経路
          # （return 0）が後段の verify_pushed_or_retry（全完了経路 / 9228 付近）より手前に
          # あったため、必須未完了のまま保留すると **完了済み task の commit が origin に
          # push されないまま** 次サイクルの branch 再初期化（impl-resume の
          # `git checkout -B "$BRANCH" "origin/$BRANCH"`）で失われ、再 pickup されても
          # task 1 からやり直す無限空転になっていた（#180 Part 2 実測）。ここで保留する前に
          # verify_pushed_or_retry で完了済み commit を origin に確実に残すことで、次サイクルの
          # impl-resume が `- [x]` skip で task N+1 から継続でき、直後の再 pickup 可能化
          # （ラベル除去）とセットで初めて「中断 → 後続 tick で継続 → 完了」が成立する
          # （Req 1.2, 2.1, NFR 3.1）。
          #
          # push リトライにも失敗した場合は verify_pushed_or_retry が mark_issue_failed を
          # 既発射している（claude-failed 付与 + claude-picked-up / claude-claimed 除去）。
          # 未 push のまま再 pickup すると空転が再発するため、保留（return 0）ではなく失敗
          # （return 1）に倒して人間に委ねる。
          if ! verify_pushed_or_retry "stageA-pt-hold-push-missing" "$BRANCH" "Stage A (per-task loop hold)"; then
            return 1
          fi
          # ── 保留 Issue の再 pickup 可能化 (#198 / Req 1.1, 1.4, NFR 2.1) ──
          # dispatcher の候補クエリは `-label:"$LABEL_PICKED"`（claude-picked-up）を除外条件に
          # 持つため、保留時に `claude-picked-up` を残したままだと当該 Issue が二度と pickup
          # 候補に上がらず impl-resume が再開せず stuck になる（#180 Part 2 の事例）。ここで
          # `claude-picked-up`（および念のため `claude-claimed`）を除去して bare auto-dev
          # candidate に戻すことで、次 tick の dispatcher が当該 Issue を再選択 → mode 判定が
          # 既存 spec/branch を検出して impl-resume を起動 → 残 task を消化する（残 task の
          # `- [x]` skip による冪等性は既存 impl-resume 機構が担保 / Req 2.1）。
          #
          # quota パスとの非干渉 (Req 3.2/3.3): 本保留は `needs-quota-wait` を一切付与しない。
          # quota 中断は `qa_handle_quota_exceeded` が `needs-quota-wait` を付け
          # `process_quota_resume` が reset+grace 経過まで待つ別経路であり、本保留はラベル除去
          # のみで `needs-quota-wait` を触らないため、quota processor の走査対象（needs-quota-wait
          # のみ）に乗らず二重処理は構造的に発生しない。
          #
          # 副作用失敗の扱い (Req 1.4): `gh issue edit` の失敗は warn 吸収して `return 0` を
          # 維持する（quota ハンドラと同じく副作用失敗で全体を落とさない方針）。失敗時は
          # `claude-picked-up` が残り当該 Issue は次 tick でも候補に上がらないが、その旨を
          # ログに残し次 tick で再評価される（人間が手動でラベル除去する余地も残す）。
          #
          # 同一 tick 即時再開について (Req 1.1): dispatcher は tick 冒頭に候補スナップショットを
          # 取得するため、tick 途中の本ラベル除去は当該 tick のキューに影響しない（同一 tick 内
          # 即時再 claim は構造的に起きず、再開は後続 tick から）。
          if gh issue edit "$NUMBER" --repo "$REPO" \
              --remove-label "$LABEL_PICKED" \
              --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
            pt_log "issue=#${NUMBER} claude-picked-up を除去し bare auto-dev candidate へ復帰 → 後続 tick で impl-resume 再開" | tee -a "$LOG"
          else
            # pt_warn は stderr 出力のため、$LOG への grep 可能な記録は別途 tee で残す（NFR 2.1）
            pt_warn "issue=#${NUMBER} claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）"
            pt_log "issue=#${NUMBER} WARN claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）" | tee -a "$LOG"
          fi
          return 0
        fi
        # per-task loop 内では Implementer が commit のみを積み push しない（push は本 Stage A
        # に集約する設計）。全 task 完了経路では loop 終了後の HEAD が完了済み commit 分だけ
        # ahead になっているため、ここで verify_pushed_or_retry が origin へ push する。push
        # 漏れ時は 1 回リトライし、失敗時は claude-failed 化して return 1 する。
        if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A (per-task loop)"; then
          return 1
        fi
        echo "✅ #$NUMBER: Stage A 完了（per-task loop）" | tee -a "$LOG"
        # ── Stage A 越境観測 (#219 Req 2) ──
        # Stage A 完了直後に当該 head ブランチの先行 impl PR を観測し、越境を検出・記録して
        # 後段の spec_artifacts_completeness_guard へグローバル変数で引き継ぐ。read-only 観測
        # で常に return 0（pipeline を止めない / NFR 1.4）。`STAGE_CHECKPOINT_ENABLED != true`
        # では 1 行も実行されず本修正導入前と完全等価（Req 2.5 / NFR 1.1）。
        stage_a_crossing_probe
        # ── Partial Status Gate (#148) ──
        # Developer が impl-notes.md 末尾に `STATUS: partial_*` を出力した場合は
        # Reviewer 起動を skip して needs-decisions エスカレーションする。status 行不在
        # / `complete` の場合は副作用なしで既存フローへ続行（NFR 1.1, 1.4）。
        local _partial_rc=0
        handle_partial_status || _partial_rc=$?
        case "$_partial_rc" in
          0)  : ;;        # continue（既存フロー）
          10) return 0 ;; # partial 検出: Reviewer skip + 正常終了
          *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
        esac
      else
        echo "--- Stage A 実行（$MODE / PM + Developer）---" >> "$LOG"
        prompt_a=$(build_dev_prompt_a "$MODE")
        # Issue #66: Quota-Aware Watcher 経由で claude を起動（Req 1.1, 1.2, 2.1）
        local _qa_reset_file_a _qa_rc_a=0 _qa_ts_a
        _qa_ts_a=$(date +%Y%m%d-%H%M%S)
        _qa_reset_file_a="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-${_qa_ts_a}"
        qa_run_claude_stage "StageA" "$_qa_reset_file_a" -- \
          claude \
            --print "$prompt_a" \
            --model "$DEV_MODEL" \
            --permission-mode bypassPermissions \
            --max-turns "$DEV_MAX_TURNS" \
            --output-format stream-json \
            --verbose \
            "${CLAUDE_HOOK_ARGS[@]}" \
            >> "$LOG" 2>&1 || _qa_rc_a=$?
        # run サマリ: Stage A（通常 Developer 経路）実行を記録し degraded 兆候を反映
        # （quota 99 / 失敗 * でも claude 起動は試みられたため stage は走った / Req 2.1, 6.x）。
        rs_record_stage A
        rs_scan_degraded_log "$LOG"
        case "$_qa_rc_a" in
          0)
            # Issue #106 Req 1: Stage A 成功宣言の前にローカル HEAD が origin に到達しているか
            # verify する。ahead == 0 なら従来どおり成功メッセージ（Req 1.3 / 5.1）、
            # ahead > 0 なら自動 push リトライ 1 回。リトライ失敗時は claude-failed 化済で
            # return 1 を伝搬する（Req 1.4, 4.4, 4.5）。
            rm -f "$_qa_reset_file_a"
            if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A"; then
              return 1
            fi
            echo "✅ #$NUMBER: Stage A 完了" | tee -a "$LOG"
            # ── Stage A 越境観測 (#219 Req 2) ──
            # 通常 Developer 経路の Stage A 完了直後に先行 impl PR を観測し、越境を検出・記録
            # して後段の spec_artifacts_completeness_guard へ引き継ぐ。read-only / 常に return 0
            # （NFR 1.4）。gate off では 1 行も実行されない（Req 2.5 / NFR 1.1）。
            stage_a_crossing_probe
            # ── Partial Status Gate (#148) ──
            # 通常 Developer 経路 (PM + Developer / 単一 Implementer) の Stage A 完了直後
            # に impl-notes.md の `STATUS:` 行を検出し、partial を 1st-class に処理する。
            # status 行不在 / `complete` の場合は副作用なし（NFR 1.1, 1.4）。
            local _partial_rc_n=0
            handle_partial_status || _partial_rc_n=$?
            case "$_partial_rc_n" in
              0)  : ;;        # continue
              10) return 0 ;; # partial 検出: Reviewer skip
              *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
            esac
            ;;
          99)
            local _qa_epoch_a
            _qa_epoch_a=$(cat "$_qa_reset_file_a")
            qa_handle_quota_exceeded "$NUMBER" "StageA" "$_qa_epoch_a"
            rm -f "$_qa_reset_file_a"
            echo "⏸️ #$NUMBER: Stage A で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            rm -f "$_qa_reset_file_a"
            echo "❌ #$NUMBER: Stage A 失敗" | tee -a "$LOG"
            mark_issue_failed "stageA" ""
            return 1
            ;;
        esac
      fi
      ;;
    B|C)
      sc_log "Stage A をスキップ（START_STAGE=$START_STAGE / 既存 impl-notes.md を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage A スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Debugger Gate (#22 Phase 3): Stage A 完了直後 BLOCKED 検出 ──
  # `DEBUGGER_ENABLED=true` 時のみ、Stage A 完了直後・stage-a-verify gate 直前で
  # `impl-notes.md` の行頭 `BLOCKED: <reason>` を検出し、Developer 自己宣言経路として
  # Debugger を 1 回起動する。BLOCKED 経路の Stage A' は通常の Round 1 サイクルに合流
  # するため、Stage B / B' で再度 Debugger 起動候補になっても sentinel が「起動済み」
  # を返すため再起動はされない（Req 5.1, 5.2）。
  # `DEBUGGER_ENABLED != "true"` の場合は本ブロックが構造的に skip され、BLOCKED 行は
  # 判定材料に使われず stage-a-verify に直行する（Req 1.2 / NFR 1.1）。
  if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
    local _blocked_reason=""
    if _blocked_reason=$(detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"); then
      if detect_debugger_already_invoked; then
        # 既起動状態での BLOCKED 再発生 → 直行 claude-failed (Req 5.2)
        dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" result=skipped reason=debugger-already-invoked" >> "$LOG"
        echo "❌ #$NUMBER: Developer BLOCKED 宣言を検出したが Debugger は既起動 → claude-failed (Req 5.2)" | tee -a "$LOG"
        mark_issue_failed "debugger-blocked-but-invoked" "Developer が \`impl-notes.md\` に \`BLOCKED:\` 行を出力しましたが、本 Issue では既に Debugger が 1 回起動済みのため再起動を抑止し人間判断に委ねます（Req 5.1, 5.2）。

- BLOCKED reason: ${_blocked_reason}
- 既存 Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\`
- impl-notes.md: \`${SPEC_DIR_REL}/impl-notes.md\`

\`$LOG\` を確認し、Fix Plan の追加修正 / 別 Issue 切り出し等を判断してください。"
        return 1
      fi

      # 未起動: Stage D (BLOCKED 経路) → Stage A' (通常差し戻し + Fix Plan 注入) → 通常 Round 1 サイクル
      echo "🐛 #$NUMBER: Developer BLOCKED 宣言検出 → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
      dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" start (detected at impl-notes.md)" >> "$LOG"
      local _dbg_rc=0
      run_debugger_stage "blocked" "" "" || _dbg_rc=$?
      case "$_dbg_rc" in
        99)
          echo "⏸️ #$NUMBER: Debugger (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        0)
          echo "✅ #$NUMBER: Debugger (BLOCKED 経路) 完了 → Stage A' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
          ;;
        *)
          # Debugger 異常終了 → mark_issue_failed 既発射、Stage A' 実行なし (Req 3.6)
          return 1
          ;;
      esac

      # ── Stage A' (Developer 再起動 + Fix Plan 注入 / BLOCKED 経路、review-notes.md なし) ──
      echo "--- Stage A' 実行（Developer 再起動 / BLOCKED 経路 Debugger Fix Plan 注入）---" >> "$LOG"
      local prompt_redo_bl
      # BLOCKED 経路では review-notes.md は無いため空文字を渡す（build_dev_prompt_redo_with_fix_plan
      # が「(Reviewer 経由ではないため review-notes.md は無し)」と明示する）
      prompt_redo_bl=$(build_dev_prompt_redo_with_fix_plan \
        "" \
        "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
      local _qa_reset_file_bl _qa_rc_bl=0 _qa_ts_bl
      _qa_ts_bl=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_bl="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-prime-blocked-${_qa_ts_bl}"
      qa_run_claude_stage "StageA-prime-blocked" "$_qa_reset_file_bl" -- \
        claude \
          --print "$prompt_redo_bl" \
          --model "$DEV_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$DEV_MAX_TURNS" \
          --output-format stream-json \
          --verbose \
          "${CLAUDE_HOOK_ARGS[@]}" \
          >> "$LOG" 2>&1 || _qa_rc_bl=$?
      # run サマリ: Stage A'（BLOCKED 経路 Developer 再起動）実行を記録（Req 2.1, 6.x）。
      rs_record_stage "A'"
      rs_scan_degraded_log "$LOG"
      case "$_qa_rc_bl" in
        0)
          rm -f "$_qa_reset_file_bl"
          if ! verify_pushed_or_retry "stageA-prime-blocked-push-missing" "$BRANCH" "Stage A' (BLOCKED 経路)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Stage A' (BLOCKED 経路) 完了 → 通常 Round 1 サイクルに合流 (Req 4.4)" | tee -a "$LOG"
          # ── Partial Status Gate (#148) ──
          # BLOCKED 経路の Stage A' 完了直後でも partial 検出を有効化する（Debugger Fix Plan
          # 注入後の再実装で Developer が partial を宣言した場合に Reviewer 起動を skip）。
          local _partial_rc_bl=0
          handle_partial_status || _partial_rc_bl=$?
          case "$_partial_rc_bl" in
            0)  : ;;        # continue
            10) return 0 ;; # partial 検出: Reviewer skip
            *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
          esac
          ;;
        99)
          local _qa_epoch_bl
          _qa_epoch_bl=$(cat "$_qa_reset_file_bl")
          qa_handle_quota_exceeded "$NUMBER" "StageA-prime-blocked" "$_qa_epoch_bl"
          rm -f "$_qa_reset_file_bl"
          echo "⏸️ #$NUMBER: Stage A' (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        *)
          rm -f "$_qa_reset_file_bl"
          echo "❌ #$NUMBER: Stage A' (BLOCKED 経路 Developer 再実行) 失敗" | tee -a "$LOG"
          mark_issue_failed "stageA-prime-blocked" "BLOCKED 経路の Debugger 経由 Developer 再実行（Stage A'）が claude 非 0 exit で失敗しました（rc=${_qa_rc_bl}）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      # 続行: stage-a-verify → Stage B (Round 1) に合流（Req 4.4）
    fi
  fi

  # ── stage-a-verify gate (#125) ──
  # Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク（build /
  # test / lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
  # （START_STAGE=B|C）でも通すことで Stage Checkpoint resume 経由のフローでも
  # gate が機能する（design.md「stage-a-verify と Stage Checkpoint の協調」参照）。
  # `STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run が即 return 0 して
  # 本機能導入前と user-observable に完全同一の挙動になる（Req 4.1 / NFR 1.1）。
  # `stage_a_verify_run` の戻り値 0/1/2 を `run_impl_pipeline` の戻り値契約にマップする
  # （NFR 1.3）:
  #   - 0 = SUCCESS / SKIPPED / DISABLED → 続行
  #   - 1 = round=1 差し戻し → run_impl_pipeline は **3（再 pickup 可能な保留）** を返す。
  #         claude-failed は付与されておらず、ここで claude-picked-up / claude-claimed を
  #         除去して次 tick の再 pickup を成立させる（Issue #219）。
  #   - 2 = round=2 escalate → 内部で `mark_issue_failed` 発火済み（claude-failed）。
  #         run_impl_pipeline は従来どおり 1（失敗）を返す。
  local _sav_rc=0
  stage_a_verify_run || _sav_rc=$?
  # ── run サマリ: stage-a-verify 結果記録（#239 task 5 / Req 4.1, 4.2, 4.3） ──
  # `stage_a_verify_run` が露出する `_SAV_LAST_OUTCOME`（success / skip / disabled /
  # round1 / round2）を `rs_record_sav` に渡し run サマリの `stage-a-verify=` を確定する。
  # 戻り値 0 は SUCCESS / SKIPPED / DISABLED を区別できないため outcome 変数を使う。
  # 変数代入のみの副作用（戻り値常に 0）で `_sav_rc` の case 分岐・ラベル遷移・exit code に
  # 影響しない（NFR 1.1, 1.2）。run-summary.sh は本体 REQUIRED_MODULES で source 済みのため
  # task 3 の rs_set_mode と同じく bare 呼び出し（空入力時は no-op で既定 n/a を維持）。
  rs_record_sav "${_SAV_LAST_OUTCOME:-}"
  case "$_sav_rc" in
    0)
      : ;;  # SUCCESS / SKIPPED / DISABLED → 続行
    1)
      # stage-a-verify round=1 差し戻し（次 tick で再評価）。`claude-picked-up` を残すと
      # dispatcher の候補クエリ（`-label:"$LABEL_PICKED"`）から除外され二度と再 pickup
      # されず stuck になる（per-task hold #198 と同根 / Issue #219）。ここで
      # claude-picked-up / claude-claimed を除去して bare auto-dev candidate へ復帰させ、
      # 次 tick の再 pickup → Stage Checkpoint resume → stage-a-verify 再評価
      # （round=2 escalate への前進）を成立させる。round counter sidecar は温存するため、
      # 次回失敗で round=2 → claude-failed に進む。戻り値 3 は呼び出し側で「再 pickup 可能な
      # 保留」として扱われ、虚偽の「claude-failed 付与済み」ログを出さない。
      echo "🔁 #$NUMBER: stage-a-verify 失敗（round=1）→ Developer 差し戻し（claude-picked-up 除去 / 次 tick で再評価）" | tee -a "$LOG"
      # run サマリ: 最終遷移を hold（保留 = claude-failed を付けず次 tick で再 pickup する
      # round=1 defer）として記録（design.md L59-60「round=1 defer（保留）」/ Req 7.1）。
      # 変数代入のみで return 3 の保留契約・ラベル除去・exit code に影響しない（NFR 1.1, 1.2）。
      rs_set_result hold
      # claude-picked-up を除去して再 pickup 可能化（fail-open: 除去失敗でも保留は維持）。
      stage_a_verify_round1_defer || true
      return 3
      ;;
    2)
      echo "❌ #$NUMBER: stage-a-verify 連続 2 回失敗 → claude-failed" | tee -a "$LOG"
      return 1
      ;;
  esac

  # ── Stage B (round=1): Reviewer / Stage A' / Stage B(round=2) ──
  case "$START_STAGE" in
    A|B)
      rev_rc=0
      # #333: REVIEWER_SKIP_PATTERN（opt-in）— 全変更ファイルがパターンに一致する場合のみ
      # Stage B をスキップして自動 approve に倒す（_reviewer_skip_check が自動 approve の
      # review-notes.md 生成とログ出力まで実施済み）。スキップ時は Reviewer が実行されて
      # いないため rs_record_stage B は記録しない（run-summary の実行実態と一致させる）。
      if _reviewer_skip_check; then
        rev_rc=0
      else
        run_reviewer_stage 1 || rev_rc=$?
        # run サマリ: Stage B（Reviewer round=1）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
        # Reviewer verdict / round の記録は task 6 の責務。ここは stage 記録のみ。
        rs_record_stage B
        rs_scan_degraded_log "$LOG"
      fi
      case $rev_rc in
        0)
          # Issue #106 Req 3: Stage B (Reviewer round=1 approve) 完了直後に push 状態 verify。
          # review-notes.md が Reviewer によって commit されているが未 push のケースを検出する
          # （Req 3.4 review-notes.md 識別ログ粒度は stage label "Stage B (round=1 approve)" で表現）。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 approve)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Reviewer round=1 approve" | tee -a "$LOG"
          # Issue #349 Req 3.1: review-notes.md 確定 + push 済の状態で claude-review status を publish。
          # AND 二重 opt-in (PR_REVIEWER_STATUS_CHECK_ENABLED && FULL_AUTO_ENABLED) が成立した場合のみ動く。
          publish_claude_review_status 1 || true
          ;;
        99)
          # Issue #66: Reviewer round=1 で quota 超過検出。run_reviewer_stage 内で
          # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
          echo "⏸️ #$NUMBER: Reviewer round=1 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        1)
          # Issue #106 Req 3: Stage B (Reviewer round=1 reject) 完了直後にも push 状態 verify。
          # 「reject だが review-notes.md 未 push」状態で Stage A' を起動すると Stage A' 側の
          # build_dev_prompt_redo が origin の古い review-notes.md を参照する事故を防ぐ。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 reject)"; then
            return 1
          fi
          # Issue #349 Req 3.2: round=1 reject 段階の review-notes.md からも claude-review=failure
          # を publish しておく（後続 round=2 で再 publish して上書き / Req 4.3 latest-wins）。
          publish_claude_review_status 1 || true
          echo "🔁 #$NUMBER: Reviewer round=1 reject → Developer 再実行" | tee -a "$LOG"
          rv_dev_log "redo by reviewer reject (round=1)" >> "$LOG"

          # ── Stage A' (Developer 再実行) ──
          echo "--- Stage A' 実行（Developer 再実行 / Reviewer reject 差し戻し）---" >> "$LOG"
          prompt_redo=$(build_dev_prompt_redo "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")
          # Issue #66: Quota-Aware Watcher 経由で claude を起動
          local _qa_reset_file_aredo _qa_rc_aredo=0 _qa_ts_aredo
          _qa_ts_aredo=$(date +%Y%m%d-%H%M%S)
          _qa_reset_file_aredo="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-redo-${_qa_ts_aredo}"
          qa_run_claude_stage "StageA-redo" "$_qa_reset_file_aredo" -- \
            claude \
              --print "$prompt_redo" \
              --model "$DEV_MODEL" \
              --permission-mode bypassPermissions \
              --max-turns "$DEV_MAX_TURNS" \
              --output-format stream-json \
              --verbose \
              "${CLAUDE_HOOK_ARGS[@]}" \
              >> "$LOG" 2>&1 || _qa_rc_aredo=$?
          # run サマリ: Stage A'（Reviewer reject 差し戻し Developer 再実行）実行を記録
          # （Req 2.1, 6.x）。
          rs_record_stage "A'"
          rs_scan_degraded_log "$LOG"
          case "$_qa_rc_aredo" in
            0)
              # Issue #106 Req 2: Stage A' 成功宣言の前にローカル HEAD が origin に到達して
              # いるか verify する（Req 2.1〜2.3, 4.1〜4.5）。
              rm -f "$_qa_reset_file_aredo"
              if ! verify_pushed_or_retry "stageA-prime-push-missing" "$BRANCH" "Stage A'"; then
                return 1
              fi
              echo "✅ #$NUMBER: Stage A' 完了" | tee -a "$LOG"
              # ── Partial Status Gate (#148) ──
              # Reviewer reject 差し戻し経路の Stage A' 完了直後でも partial 検出を有効化
              # する（再実装中に Developer が partial を宣言した場合に Reviewer round=2
              # 起動を skip）。
              local _partial_rc_aredo=0
              handle_partial_status || _partial_rc_aredo=$?
              case "$_partial_rc_aredo" in
                0)  : ;;        # continue
                10) return 0 ;; # partial 検出: Reviewer skip
                *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
              esac
              ;;
            99)
              local _qa_epoch_aredo
              _qa_epoch_aredo=$(cat "$_qa_reset_file_aredo")
              qa_handle_quota_exceeded "$NUMBER" "StageA-redo" "$_qa_epoch_aredo"
              rm -f "$_qa_reset_file_aredo"
              echo "⏸️ #$NUMBER: Stage A' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            *)
              rm -f "$_qa_reset_file_aredo"
              echo "❌ #$NUMBER: Stage A' (Developer 再実行) 失敗" | tee -a "$LOG"
              mark_issue_failed "stageA-redo" ""
              return 1
              ;;
          esac

          # ── Stage B (round=2): Reviewer 最終回 ──
          rev_rc=0
          run_reviewer_stage 2 || rev_rc=$?
          # run サマリ: Stage B'（Reviewer round=2 最終回）実行を記録し degraded 兆候を反映
          # （Req 2.1, 6.x）。Reviewer verdict / round の記録は task 6 の責務。
          rs_record_stage "B'"
          rs_scan_degraded_log "$LOG"
          case $rev_rc in
            0)
              # Issue #106 Req 3: Stage B (Reviewer round=2 approve) 完了直後の push 状態 verify。
              if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 approve)"; then
                return 1
              fi
              echo "✅ #$NUMBER: Reviewer round=2 approve" | tee -a "$LOG"
              # Issue #349 Req 3.1: round=2 approve → claude-review=success を publish
              publish_claude_review_status 2 || true
              ;;
            99)
              # Issue #66: Reviewer round=2 で quota 超過検出。run_reviewer_stage 内で
              # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
              echo "⏸️ #$NUMBER: Reviewer round=2 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            1)
              # Issue #106 Req 3.1: Stage B 完了は reject / approve いずれも verify 対象。
              # 本ケース（round=2 reject）は Debugger Gate 経路への分岐 / もしくは
              # reviewer-reject2 で claude-failed に確定するため、verify 自体は best-effort
              # で実行し失敗してもより情報量の多い後続経路を優先する。ahead > 0 検出時の
              # WARN ログ / 自動 push 復旧コメントは verify_pushed_or_retry 内で出力済
              # （観測可能性は維持）。
              verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 reject)" || true
              # Issue #349 Req 3.2: round=2 reject → claude-review=failure を publish（Debugger
              # 経路 / reject2 経路いずれに進む場合でも、現時点の RESULT を反映する）。
              publish_claude_review_status 2 || true

              # Phase 3 (#22): DEBUGGER_ENABLED=true 時のみ Debugger Gate に分岐。
              # Debugger 未起動（sentinel 不在）なら Stage D (Round 2 reject) → Stage A''
              # (Developer 再起動 + Fix Plan 注入) → Stage B'' (Reviewer Round 3) を 1 回だけ
              # 試行する。`DEBUGGER_ENABLED != "true"` または sentinel 既起動の場合は
              # 既存 reviewer-reject2 経路（claude-failed 直行）にフォールバック。
              # 本分岐が構造的に skip されるため、DEBUGGER_ENABLED 未指定 / `=false` の
              # 既存挙動は完全に不変（NFR 1.1 / Req 1.1, 1.2）。
              if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked; then
                echo "🐛 #$NUMBER: Reviewer round=2 reject → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
                local _dbg_rc=0
                run_debugger_stage "round2-reject" "" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" || _dbg_rc=$?
                case "$_dbg_rc" in
                  99)
                    # quota 超過: 既存 #66 規約に従い watcher は正常終了。Resume Processor が次 tick で再開
                    echo "⏸️ #$NUMBER: Debugger で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  0)
                    # Debugger 正常終了 + debugger-notes.md verify 成功 → Stage A'' へ
                    echo "✅ #$NUMBER: Debugger 完了 → Stage A'' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
                    ;;
                  *)
                    # Debugger 異常終了 / verify 失敗 → mark_issue_failed 既発射、Stage A''/B'' 実行なし (Req 3.6)
                    return 1
                    ;;
                esac

                # ── Stage A'' (Developer 再起動 + Fix Plan 注入) ──
                echo "--- Stage A'' 実行（Developer 再起動 / Debugger Fix Plan 注入）---" >> "$LOG"
                local prompt_redo_fp
                prompt_redo_fp=$(build_dev_prompt_redo_with_fix_plan \
                  "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" \
                  "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
                local _qa_reset_file_app _qa_rc_app=0 _qa_ts_app
                _qa_ts_app=$(date +%Y%m%d-%H%M%S)
                _qa_reset_file_app="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-pp-${_qa_ts_app}"
                qa_run_claude_stage "StageA-pp" "$_qa_reset_file_app" -- \
                  claude \
                    --print "$prompt_redo_fp" \
                    --model "$DEV_MODEL" \
                    --permission-mode bypassPermissions \
                    --max-turns "$DEV_MAX_TURNS" \
                    --output-format stream-json \
                    --verbose \
                    "${CLAUDE_HOOK_ARGS[@]}" \
                    >> "$LOG" 2>&1 || _qa_rc_app=$?
                case "$_qa_rc_app" in
                  0)
                    rm -f "$_qa_reset_file_app"
                    if ! verify_pushed_or_retry "stageA-pp-push-missing" "$BRANCH" "Stage A''"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Stage A'' 完了" | tee -a "$LOG"
                    # ── Partial Status Gate (#148) ──
                    # Debugger 経由 Stage A'' 完了直後でも partial 検出を有効化する。
                    # Fix Plan を注入されてもなお Developer が partial を宣言した場合に
                    # Reviewer round=3 起動を skip。
                    local _partial_rc_app=0
                    handle_partial_status || _partial_rc_app=$?
                    case "$_partial_rc_app" in
                      0)  : ;;        # continue
                      10) return 0 ;; # partial 検出: Reviewer skip
                      *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
                    esac
                    ;;
                  99)
                    local _qa_epoch_app
                    _qa_epoch_app=$(cat "$_qa_reset_file_app")
                    qa_handle_quota_exceeded "$NUMBER" "StageA-pp" "$_qa_epoch_app"
                    rm -f "$_qa_reset_file_app"
                    echo "⏸️ #$NUMBER: Stage A'' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  *)
                    rm -f "$_qa_reset_file_app"
                    echo "❌ #$NUMBER: Stage A'' (Debugger 経由 Developer 再実行) 失敗" | tee -a "$LOG"
                    mark_issue_failed "stageA-pp" "Debugger 経由 Developer 再実行（Stage A''）が claude 非 0 exit で失敗しました（rc=${_qa_rc_app}）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac

                # ── Stage B'' (Reviewer Round 3): Debugger 経由の最終 Reviewer ──
                local rev_rc3=0
                run_reviewer_stage 3 || rev_rc3=$?
                # Round 3 結果をログに記録（NFR 2.1 の 4 イベント目）
                case "$rev_rc3" in
                  0)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=approve" >> "$LOG"
                    if ! verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 approve)"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Reviewer round=3 approve（Debugger 経由）" | tee -a "$LOG"
                    # Issue #349 Req 3.1: round=3 approve → claude-review=success
                    publish_claude_review_status 3 || true
                    # 既存 approve 後経路（Stage C）に合流するため case を抜ける
                    ;;
                  99)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=quota-exceeded" >> "$LOG"
                    echo "⏸️ #$NUMBER: Reviewer round=3 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  1)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=reject" >> "$LOG"
                    verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 reject)" || true
                    # Issue #349 Req 3.2: round=3 reject → claude-review=failure
                    publish_claude_review_status 3 || true
                    echo "❌ #$NUMBER: Reviewer round=3 reject → claude-failed（Debugger 再起動なし / Req 3.5）" | tee -a "$LOG"
                    local parsed3 cat3 tgt3
                    parsed3=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                    cat3=$(echo "$parsed3" | cut -f2)
                    tgt3=$(echo "$parsed3" | cut -f3)
                    local reject_body3
                    reject_body3="Debugger 経由の Reviewer round=3 でも reject となったため、自動 iteration を打ち切り人間判断に委ねます（Debugger は 1 Issue あたり 1 回のみ起動するため再起動しません / Req 3.5）。

- 対象 requirement ID: ${tgt3:-(unknown)}
- reject カテゴリ: ${cat3:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照
- Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` を参照

### 次の手順
1. review-notes.md / debugger-notes.md / watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                    mark_issue_failed "reviewer-reject3" "$reject_body3"
                    # run サマリ: Reviewer reject による差し戻しループ打ち切り終端を
                    # needs-iteration として記録（Req 7.1）。mark_issue_failed が記録した
                    # claude-failed を、Reviewer 判定起因の終端として needs-iteration に
                    # 上書きする（design.md result enum / tasks.md task 6 を正本とする）。
                    # 変数代入のみで claude-failed ラベル遷移・exit code は不変（NFR 1.1, 1.2）。
                    rs_set_result needs-iteration
                    return 1
                    ;;
                  4)
                    # Issue #296 Req 2.3 / Req 4.3 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
                    # → `reviewer-missing-file` カテゴリで `claude-failed`。装飾起因 parse 失敗
                    # （reviewer-error）と grep で区別可能な reason を発行する。
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=missing-file-after-retry" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
                    mark_issue_failed "reviewer-missing-file" "Debugger 経由の Reviewer round=3 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                  6)
                    # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇 → `reviewer-max-turns-exhausted`
                    # カテゴリで `claude-failed`（Debugger 経由 round=3）。run-summary degraded は記録済み。
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=max-turns-exhausted" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
                    mark_issue_failed "reviewer-max-turns-exhausted" "Debugger 経由の Reviewer round=3 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                  *)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=error" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 異常終了 → claude-failed" | tee -a "$LOG"
                    mark_issue_failed "reviewer-error" "Debugger 経由の Reviewer round=3 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac
              else
                # DEBUGGER_ENABLED != "true" もしくは sentinel 既起動 → 既存 reviewer-reject2 経路
                if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
                  # Debugger 既起動状態での Round 2 reject 再発生 (Req 5.2)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=none result=skipped reason=debugger-already-invoked" >> "$LOG"
                fi
                # 2 回目 reject → claude-failed + Issue コメントに reject 理由 / 対象 ID を含める
                echo "❌ #$NUMBER: Reviewer round=2 reject → claude-failed" | tee -a "$LOG"
                local parsed2 cat2 tgt2
                parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                cat2=$(echo "$parsed2" | cut -f2)
                tgt2=$(echo "$parsed2" | cut -f3)
                local reject_body
                reject_body="Reviewer が 2 回連続で reject を出したため、自動 iteration を打ち切り、人間判断に委ねます。

- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                mark_issue_failed "reviewer-reject2" "$reject_body"
                # run サマリ: Reviewer 2 回連続 reject による差し戻しループ打ち切り終端を
                # needs-iteration として記録（Req 7.1）。mark_issue_failed が記録した
                # claude-failed を、Reviewer 判定起因の終端として needs-iteration に
                # 上書きする（design.md result enum / tasks.md task 6 を正本とする）。
                # 変数代入のみで claude-failed ラベル遷移・exit code は不変（NFR 1.1, 1.2）。
                rs_set_result needs-iteration
                return 1
              fi
              ;;
            4)
              # Issue #296 Req 2.3 / Req 4.1 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
              # → `reviewer-missing-file` カテゴリで `claude-failed`（round=2）。
              echo "❌ #$NUMBER: Reviewer round=2 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
              mark_issue_failed "reviewer-missing-file" "Reviewer round=2 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
              return 1
              ;;
            6)
              # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇 → `reviewer-max-turns-exhausted`
              # カテゴリで `claude-failed`（round=2）。run-summary degraded は run_reviewer_stage 内で記録済み。
              echo "❌ #$NUMBER: Reviewer round=2 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
              mark_issue_failed "reviewer-max-turns-exhausted" "Reviewer round=2 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
              return 1
              ;;
            *)
              # round=2 reviewer error
              echo "❌ #$NUMBER: Reviewer round=2 異常終了 → claude-failed" | tee -a "$LOG"
              mark_issue_failed "reviewer-error" "Reviewer round=2 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
              return 1
              ;;
          esac
          ;;
        4)
          # Issue #296 Req 2.3 / Req 4.1 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
          # → `reviewer-missing-file` カテゴリで `claude-failed`（round=1）。
          echo "❌ #$NUMBER: Reviewer round=1 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
          mark_issue_failed "reviewer-missing-file" "Reviewer round=1 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
          return 1
          ;;
        6)
          # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇（error_max_turns）で
          # verdict 未到達 → `reviewer-max-turns-exhausted` カテゴリで `claude-failed`（round=1）。
          # reviewer-error（claude crash）/ reviewer-missing-file（ファイル不在）/ code reject の
          # いずれとも grep 区別可能な reason を発行する。run-summary degraded は run_reviewer_stage
          # 内で記録済み（Req 3.3）。
          echo "❌ #$NUMBER: Reviewer round=1 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
          mark_issue_failed "reviewer-max-turns-exhausted" "Reviewer round=1 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
          return 1
          ;;
        *)
          # round=1 reviewer error → claude-failed + Issue コメント (要件 4.8)
          echo "❌ #$NUMBER: Reviewer round=1 異常終了 → claude-failed" | tee -a "$LOG"
          mark_issue_failed "reviewer-error" "Reviewer round=1 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    C)
      sc_log "Stage B をスキップ（START_STAGE=C / 既存 review-notes.md approve を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage B スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Stage C: PjM (PR 作成) ──
  echo "--- Stage C 実行（PjM / PR 作成）---" >> "$LOG"
  # Issue #212: PR 作成処理へ進む直前に同一 head ブランチの既存 impl PR を再確認する
  # 冪等ガード。サイクル開始時の resolve_resume_point とは別に、同一サイクル内で Stage A
  # が越境して PR を作成したケースを検出して二重 PR を防ぐ（Req 1.4 / NFR 2.1）。
  # `STAGE_CHECKPOINT_ENABLED=true`（既定）時のみ実行（Req 1.2 / NFR 1.2）。
  # return 0（既存 PR 検出で作成抑止）の場合のみ pipeline を成功停止する。OPEN/MERGED は
  # 既存 TERMINAL_OK と同一の return 0、CLOSED はガード内で needs-decisions 付与済み。
  if stage_c_existing_pr_guard; then
    echo "✅ #$NUMBER: 既存 impl PR を検出（Stage C 冪等ガード）→ 新規 PR 作成を抑止して停止" | tee -a "$LOG"
    # ── spec 成果物完全性保証 (#219 Req 3 / 4) ──
    # #213 ガードが OPEN/MERGED/CLOSED で停止したケースを後段の独立経路として捕捉し、
    # MERGED 先行 PR + req/review 欠落のときだけ docs-only 補完追従 PR を起動する。
    # stage_c_existing_pr_guard は一切変更せず、その後段で呼ぶことで Req 4.1 退行を防ぐ。
    # 常に return 0（pipeline 最終結果を変えない / NFR 1.4）。gate off では無効（Req 3.5 / NFR 1.1）。
    spec_artifacts_completeness_guard
    return 0
  fi
  # Issue #96 Req 1.5: PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
  if ! _assert_base_branch_resolved; then
    echo "❌ #$NUMBER: Stage C 中断（BASE_BRANCH 未解決）→ claude-failed" | tee -a "$LOG"
    mark_issue_failed "stageC-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため Stage C を中断しました（Issue #96 Req 1.5）。"
    return 1
  fi
  prompt_c=$(build_dev_prompt_c "$MODE")
  # Issue #66: Quota-Aware Watcher 経由で claude を起動
  local _qa_reset_file_c _qa_rc_c=0 _qa_ts_c
  _qa_ts_c=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_c="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageC-${_qa_ts_c}"
  # #329: --agent project-manager で agent 定義をトップレベル実行（オーケストレーター層なし）。
  # agent 解決失敗時は claude 非ゼロ exit → 既存 stageC 失敗遷移 + run-summary degraded 検知。
  qa_run_claude_stage "StageC" "$_qa_reset_file_c" -- \
    claude \
      --agent project-manager \
      --print "$prompt_c" \
      --model "$PJM_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      "${CLAUDE_HOOK_ARGS[@]}" \
      >> "$LOG" 2>&1 || _qa_rc_c=$?
  # run サマリ: Stage C（PjM / PR 作成）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
  # 既存 PR ガード（stage_c_existing_pr_guard）で PjM 起動前に early return したケースでは
  # PjM が走らないため本行に到達せず Stage C は記録されない（実際に走った stage のみ / Req 2.1）。
  rs_record_stage C
  rs_scan_degraded_log "$LOG"
  case "$_qa_rc_c" in
    0)
      # Issue #104 Bug 3 / Req 4.1〜4.4: claude RC=0 + quota 検出なし時点では
      # 「PR が実際に作成されたか」が未確認。PjM サブエージェントが 1 turn で
      # 空転終了しても claude RC=0 を返すため、PR 実在を gh で verify する。
      # Issue #108: GitHub の eventual consistency による false negative を吸収する
      # ため、verify_stagec_pr_or_retry で主経路リトライを実施。
      # Issue #110: 73 秒以上の edge cache lag を観測した実例（KeyNest #32）への
      # 対応として主経路を 6 回 / 合計 135 秒に延長し、最終 attempt 後に List Pulls
      # API への独立 fallback を 1 ターン追加。1 回目で成功する通常ケースの外形
      # 挙動は本変更前と同一（Req 4.1 / 4.6 / NFR 1.1）。
      rm -f "$_qa_reset_file_c"
      local _stagec_pr_url _stagec_verify_rc=0
      _stagec_pr_url=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || _stagec_verify_rc=$?
      if [ "$_stagec_verify_rc" -eq 0 ] && [ -n "$_stagec_pr_url" ]; then
        # Req 4.3 / Issue #108 Req 3.4 / Issue #110 Req 3.6: 主経路 1 回目即時成功
        # でも代替経路救済でも、呼び出し側の成功ログは共通（外形互換）
        echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み (${_stagec_pr_url})" | tee -a "$LOG"
        # run サマリ: Stage C 成功（impl PR 作成 → ready-for-review へ向かう終端 / Req 7.1）。
        # 変数代入のみで PR 作成 / ラベル遷移 / exit code に影響しない（NFR 1.1, 1.2）。
        rs_set_result ready-for-review
        # ── spec 成果物完全性保証 (#219 Req 3 / 4) ──
        # Stage C で新規 impl PR を作った通常成功ケースも通過点として完全性を最終確認する。
        # 標準構成を満たしていれば追加処理なしで return 0（design-full impl の通常成功は
        # ここで早期 return 相当 / Req 3.5 / NFR 1.1）。常に return 0（NFR 1.4）。
        spec_artifacts_completeness_guard
        return 0
      fi
      # Req 4.2 / 4.4 / Issue #108 Req 2.1 / Issue #110 Req 2.3 / 2.4:
      # 主経路リトライ + 代替経路 1 ターンを使い切っても PR 不在の場合は
      # 安全側に倒し claude-failed 化（NFR 2.2: 人間が原因を特定できる粒度のログを残す）
      echo "❌ #$NUMBER: Stage C 完了報告だが対応 PR 不在 → claude-failed (branch=$BRANCH verify_rc=$_stagec_verify_rc, 主経路リトライ + 代替 API 経路 fallback 後)" | tee -a "$LOG"
      qa_warn "stageC PR verify failed after retry+fallback issue=#$NUMBER branch=$BRANCH verify_rc=$_stagec_verify_rc pr_url='${_stagec_pr_url:-(empty)}'"
      mark_issue_failed "stageC-pr-missing" "Stage C の Claude 実行は return code 0 で終了しましたが、対応する impl PR が GitHub 側に検出できませんでした（branch=\`$BRANCH\`、主経路リトライ + 代替 API 経路 fallback 後）。PjM サブエージェントが 1 turn で空転終了した可能性 / GitHub API 一時障害の可能性のいずれかです。\`$LOG\` を確認してください。"
      return 1
      ;;
    99)
      local _qa_epoch_c
      _qa_epoch_c=$(cat "$_qa_reset_file_c")
      qa_handle_quota_exceeded "$NUMBER" "StageC" "$_qa_epoch_c"
      rm -f "$_qa_reset_file_c"
      echo "⏸️ #$NUMBER: Stage C で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
      return 0
      ;;
    *)
      rm -f "$_qa_reset_file_c"
      echo "❌ #$NUMBER: Stage C (PjM) 失敗" | tee -a "$LOG"
      mark_issue_failed "stageC" ""
      return 1
      ;;
  esac
}
