#!/usr/bin/env bash
# stage-checkpoint.sh — Stage Checkpoint モジュール（#68 / #459 切り出し）
#
# 静的解析ノート:
#   本 module 内 `_spec_missing_artifacts` は `local spec_dir_rel="${1:-$SPEC_DIR_REL}"`
#   （小文字ローカル変数 + 大文字グローバル環境変数の意図的な同名フォールバック idiom）を
#   使う。分割前の issue-watcher.sh 単体では大文字側の実代入（Config ブロック）が同一
#   ファイル内に見えていたため info 級誤検知は非発火だったが、module 単体では見えなく
#   なり「typo では」という info 級の誤検知が新規発生する（ファイル分割に伴う
#   cross-file 可視性の副作用。関数移動対象自体は無改変、新設ヘッダの一部として付与）。
# shellcheck disable=SC2153
#
# 用途:
#   impl / impl-resume の Stage A/B/C の完了 checkpoint を成果物（impl-notes.md /
#   review-notes.md / 既存 impl PR）の存在で観測し、failed Stage 以降のみを再実行する
#   機能。標準機能としてデフォルト有効（#112）。`STAGE_CHECKPOINT_ENABLED=true`（既定）
#   のとき run_impl_pipeline 冒頭から呼び出される。`=false` 明示時は呼ばれない。
#
#   - sc_log / sc_warn / sc_error               : `stage-checkpoint:` prefix logger
#   - stage_checkpoint_has_impl_notes           : Stage A 完了観測（branch HEAD tracked）
#   - sc_issue_state                            : Issue の状態観測ヘルパ
#   - sc_tasks_unchecked_count                  : tasks.md 未完了件数カウント
#   - stage_checkpoint_read_review_result       : Stage B 完了観測（review-notes.md）
#   - stage_checkpoint_find_impl_pr             : Stage C 完了観測（既存 impl PR）
#   - stage_checkpoint_resolve_resume_point     : decision table → START_STAGE 決定
#   - stage_c_existing_pr_guard                 : Stage C 二重 PR 作成防止ガード
#   - stage_a_crossing_probe                    : spec 越境検出プローブ
#   - _spec_missing_artifacts                   : 標準構成の欠落種別判定
#   - _spec_create_docs_pr                      : docs-only 補完追従 PR 作成
#   - _spec_escalate_incomplete                 : 補完失敗時のエスカレーション
#   - spec_artifacts_completeness_guard         : 上記の orchestrator（pipeline 最終フック）
#
#   設計参照: docs/specs/68-feat-watcher-stage-checkpoint-reviewer-p/design.md
#
#   注意（#459 / 取り違え注意）: Slot Runner 内に `_stage_checkpoint_assert_slug_match` /
#   `_stage_checkpoint_has_resumable_state` という類似名の別関数があるが、これらは
#   Slot Runner 側の所属であり本 module には含めない（後続の slot-worker 切り出し issue
#   で扱う）。
#
# 配置先:
#   $HOME/bin/modules/stage-checkpoint.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $NUMBER / $SPEC_DIR_REL / $BASE_BRANCH / $LOG /
#     $STAGE_CHECKPOINT_ENABLED / $LABEL_NEEDS_DECISIONS / $STAGE_A_CROSSING_DETECTED /
#     $STAGE_A_CROSSING_PR）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛に
#     より呼び出し時に解決される。
#   - 呼び出し元（run_impl_pipeline 冒頭 / pipeline 最終フック等）は実行順序温存のため
#     本体側に残る（#459 では移動しない）。
#   - 外部 CLI: gh / jq / git。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# Stage Checkpoint 専用ロガー（既存 mq_log / pi_log / rv_log と同形式）。
# `stage-checkpoint:` prefix で grep 抽出可能（NFR 2.2）。warn / error は stderr へ。
sc_log() {
  echo "[$(date '+%F %T')] stage-checkpoint: $*"
}
sc_warn() {
  echo "[$(date '+%F %T')] stage-checkpoint: WARN: $*" >&2
}
sc_error() {
  echo "[$(date '+%F %T')] stage-checkpoint: ERROR: $*" >&2
}

# ─── stage_checkpoint_has_impl_notes ───
#
# Stage A 完了 checkpoint（impl-notes.md）の **当該 Issue branch HEAD 上での tracked**
# を判定する。working tree のみに存在し未 commit のファイルは不採用とする
# （Req 4.1, 4.2, 4.4 / 部分実行を許さない、Req 5.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL（呼び出し元 _slot_run_issue が設定済み）
# 戻り値: 0 = checkpoint 採用 / 1 = 不採用（不在 or untracked）
# 副作用: なし
stage_checkpoint_has_impl_notes() {
  local rel="$SPEC_DIR_REL/impl-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 1
  # branch HEAD で tracked であることを確認（main 由来 or 未 commit ファイルは不採用）。
  # `git ls-tree --name-only HEAD -- <path>` は tracked なら path をそのまま echo し、
  # untracked なら空出力。`>/dev/null` で出力を捨て、exit code のみで判定。
  local out
  out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$out" ]
}

# ─── sc_issue_state ───
#
# 対象 Issue (`$NUMBER`) の state を 1 トークン (`OPEN` / `CLOSED`) で stdout に返す
# read-only ヘルパ。`stage_checkpoint_find_impl_pr` が MERGED PR を terminal として
# 採用する前に、Issue が reopen されていないかを確認するために使う
# （Issue #273 / Req 2.3, 3.1, 4.3）。
#
# 入力: 環境変数 NUMBER / REPO（呼び出し元 _slot_run_issue が設定済み）
# 戻り値: 0 = 取得成功（stdout = "OPEN" / "CLOSED"）/ 1 = API 失敗（stdout 空）
# 副作用: なし（read-only）
sc_issue_state() {
  local state
  state=$(gh issue view "$NUMBER" --repo "$REPO" --json state --jq '.state' 2>/dev/null || true)
  case "$state" in
    OPEN|CLOSED) echo "$state"; return 0 ;;
    *)           return 1 ;;
  esac
}

# ─── sc_tasks_unchecked_count ───
#
# `tasks.md` の **最上位 numeric ID 未チェックタスク** 件数を整数で stdout に返す
# read-only ヘルパ。`stage_checkpoint_find_impl_pr` が MERGED PR を terminal として
# 採用する前に、tasks.md に未着手タスクが残存していないかを確認するために使う
# （Issue #273 / Req 2.1, 2.4, 3.2, 3.3）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL（呼び出し元 _slot_run_issue が設定済み）
# 戻り値:
#   0 = 取得成功（stdout = 件数）
#   1 = I/O 失敗（読み取り権限なし等、stdout = 0、safe fallback）
#   2 = ファイル不在（design-less impl 等価扱い、stdout = 0）
# 副作用: なし（read-only）
#
# 判定 regex 正本: `.claude/rules/tasks-generation.md` の「Checkbox 形式の必須化」節および
# `.claude/rules/design-review-gate.md` の Budget overflow count 抽出 regex
# (`^- \[ \]\*? [0-9]+\. `) と **完全一致**。両者は別実行基盤のため共有コードを持てず、
# 同一 regex を明記してドリフトを防ぐ（design.md L252-255）。
sc_tasks_unchecked_count() {
  local rel="$SPEC_DIR_REL/tasks.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || { echo 0; return 2; }
  [ -r "$path" ] || { echo 0; return 1; }
  # `grep -cE` は 0 件マッチで rc=1 + stdout="0" を返すため、`|| echo 0` 形式だと
  # `0\n0` の重複出力になる（task 1 で観測済み）。`|| count=0` 形式で受けて
  # stdout 単独の整数 1 トークンを保証する。
  local count
  count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$path" 2>/dev/null) || count=0
  echo "$count"
  return 0
}

# ─── stage_checkpoint_read_review_result ───
#
# Stage B 完了 checkpoint（review-notes.md）の RESULT 行を抽出する。
# 既存 parse_review_result を再利用し、契約は変更しない（Req 1.2, 4.3, 4.4）。
# branch HEAD tracked チェックを先行して、未 commit / main 由来の残骸は不採用とする。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = approve / 1 = reject / 2 = 不在 or RESULT 行欠落 or untracked
# stdout: parse_review_result と同形式の TSV `<result>\t<categories>\t<targets>`
#         （戻り値 2 のときは何も出力しない）
stage_checkpoint_read_review_result() {
  local rel="$SPEC_DIR_REL/review-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 2
  local tracked
  tracked=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$tracked" ] || return 2
  local parsed
  parsed=$(parse_review_result "$path") || return 2
  local result
  result=$(echo "$parsed" | cut -f1)
  echo "$parsed"
  case "$result" in
    approve) return 0 ;;
    reject)  return 1 ;;
    *)       return 2 ;;
  esac
}

# ─── stage_checkpoint_find_impl_pr ───
#
# Stage C 完了（impl PR の存在）を観測する。OPEN / MERGED を「Stage C 後の状態」とみなして
# 自動進行を停止する。CLOSED 未マージ PR は人間が意図的に close した「やり直したい / 途中で
# 打ち切った」状態として扱い、resume 地点判定の停止根拠から **除外** する（Issue #265 /
# Req 1.1, 1.4, 1.5）。これにより `claude-failed` ラベル除去後に CLOSED PR が残っていても
# 次サイクルの自動進行（Stage A 再開）がブロックされない。
#
# 採用優先順位（Req 1.5）: OPEN を最優先、次に MERGED、CLOSED は既定で除外。
# 第 1 引数に `true` を渡したときのみ CLOSED を最終 fallback として採用する（Issue #212 の
# Stage C CLOSED ガード経路を保持する目的。Out of Scope: needs-decisions 付与経路は不変）。
#
# 入力:
#   $1 = include_closed（true なら CLOSED を最終 fallback として採用。省略時は false）
#   環境変数 REPO / BRANCH / LOG
# 戻り値: 0 = 既存 impl PR あり / 1 = なし（CLOSED のみのケース含む） / 2 = gh API エラー
# stdout: `<pr_number>,<state>`（採用優先順位に従って 1 件のみ）
# 副作用: CLOSED を除外したときに $LOG へ `stage-checkpoint:` prefix の観測ログを 1 行出力
#         （Req 4.1, 4.3 / NFR 2.1）
stage_checkpoint_find_impl_pr() {
  local include_closed="${1:-false}"
  local prs
  prs=$(gh pr list --repo "$REPO" --head "$BRANCH" --state all \
        --json number,state --limit 5 2>/dev/null) || return 2

  # OPEN / MERGED を優先採用（OPEN > MERGED の順）。CLOSED の件数も観測ログのために抽出する。
  local open_pr merged_pr closed_pr closed_count
  open_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "OPEN")] | .[0] // empty' 2>/dev/null || true)
  merged_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "MERGED")] | .[0] // empty' 2>/dev/null || true)
  closed_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "CLOSED")] | .[0] // empty' 2>/dev/null || true)
  closed_count=$(echo "$prs" | jq -r '[.[] | select(.state == "CLOSED")] | length' 2>/dev/null || echo 0)

  local found=""
  if [ -n "$open_pr" ]; then
    found="$open_pr"
  elif [ -n "$merged_pr" ]; then
    # MERGED PR を terminal として採用する前の再判定ガード（Issue #273 / Req 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 4.1, 4.2）。
    # 部分実装 PR が `Closes #N` で merge → Issue 自動 close → reopen + 残タスクあり、
    # というシナリオで MERGED PR を terminal とみなして自動進行を止めてしまう取りこぼし
    # を防ぐ。OPEN PR がある経路には到達しないため、追加 `gh issue view` は OPEN PR 不在
    # かつ MERGED PR 存在時のみ発火する（Req 2.5）。
    local merged_num issue_state="" issue_rc=0 tasks_unchecked=0 tasks_rc=0 reason=""
    merged_num=$(echo "$merged_pr" | jq -r '.number // "?"' 2>/dev/null || echo '?')
    issue_state=$(sc_issue_state) || true
    issue_rc=$?
    if [ "$issue_rc" -ne 0 ]; then
      reason="issue-api-failure"
      found="$merged_pr"
    elif [ "$issue_state" = "CLOSED" ]; then
      reason="closed-issue"
      found="$merged_pr"
    else
      # issue_state == "OPEN"
      tasks_unchecked=$(sc_tasks_unchecked_count) || true
      tasks_rc=$?
      case "$tasks_rc" in
        2)
          reason="no-tasks-file"
          found="$merged_pr"
          ;;
        1)
          reason="tasks-io-failure"
          found="$merged_pr"
          ;;
        0)
          if [ "$tasks_unchecked" -ge 1 ] 2>/dev/null; then
            reason="open-issue-with-unchecked-tasks"
            found=""
          else
            reason="all-checked"
            found="$merged_pr"
          fi
          ;;
        *)
          # 想定外 rc は safe fallback（既存挙動維持）
          reason="tasks-unknown-rc"
          found="$merged_pr"
          ;;
      esac
    fi

    if [ -z "$found" ]; then
      sc_log "find-impl-pr: merged-non-terminal pr=#${merged_num} issue=#${NUMBER} issue_state=OPEN unchecked=${tasks_unchecked} reason=${reason} branch=${BRANCH}" >> "$LOG"
    else
      sc_log "find-impl-pr: merged-terminal pr=#${merged_num} issue=#${NUMBER} issue_state=${issue_state:-unknown} unchecked=${tasks_unchecked} reason=${reason} branch=${BRANCH}" >> "$LOG"
    fi
  elif [ -n "$closed_pr" ] && [ "$include_closed" = "true" ]; then
    # Stage C CLOSED ガード（Issue #212）専用: include_closed=true のときのみ CLOSED を採用。
    # 既定の resolve_resume_point / stage_a_crossing_probe / spec_completeness 経路には届かない。
    found="$closed_pr"
  fi

  # OPEN / MERGED 不在 + CLOSED 存在のときは「CLOSED を除外した」観測ログを残す（Req 4.1, 4.3 / NFR 2.1）。
  # include_closed=true で CLOSED を採用したケースでは除外していないのでログを出さない。
  if [ -z "$open_pr" ] && [ -z "$merged_pr" ] && [ -n "$closed_pr" ] && [ "$include_closed" != "true" ]; then
    local closed_num
    closed_num=$(echo "$closed_pr" | jq -r '.number // "?"' 2>/dev/null || echo '?')
    sc_log "find-impl-pr: excluded-closed pr=#${closed_num} count=${closed_count} reason=closed-unmerged-not-stop-signal branch=${BRANCH} issue=#${NUMBER:-?}" >> "$LOG"
  fi

  [ -n "$found" ] || return 1
  echo "$found" | jq -r '"\(.number),\(.state)"' 2>/dev/null || return 2
  return 0
}

# ─── stage_checkpoint_resolve_resume_point ───
#
# Stage A/B/C の checkpoint を観測し、START_STAGE を 1 つに決定する。
# 出力 domain: A / B / C / TERMINAL_OK / TERMINAL_FAILED。
#
# Decision Table（design.md と同期、設計参照: docs/specs/68-*/design.md）:
#   既存 PR あり（OPEN / MERGED）                     → TERMINAL_OK
#   既存 PR が CLOSED 未マージのみ                    → 「既存 PR なし」扱い（Issue #265 / Req 1.1, 1.4）
#   impl-notes 無 / review-notes 有 (任意)            → A (INCONSISTENT, Req 5.1)
#   impl-notes 無 / review-notes 無                   → A (Req 2.2)
#   impl-notes 有 / review-notes 無                   → B (Req 2.3)
#   impl-notes 有 / review-notes parse 失敗            → B (Req 4.3)
#   impl-notes 有 / RESULT=approve                     → C (Req 2.4)
#   impl-notes 有 / RESULT=reject (round=2 と推定)     → TERMINAL_FAILED (Req 2.5)
#   impl-notes 有 / RESULT=reject (round=1 と推定)     → A (D-3, INCONSISTENT 扱い)
#
# round=1 / round=2 判別: review-notes.md 内 `<!-- idd-claude:review round=N -->`
# を grep。いずれも見つからなければ INCONSISTENT として Stage A から再実行する
# （safe fallback）。
#
# 入力: 環境変数 NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG
# 副作用:
#   - グローバル変数 START_STAGE に "A" / "B" / "C" / "TERMINAL_OK" / "TERMINAL_FAILED" を代入
#   - $LOG / stdout に 1 ブロックの判定根拠ログを sc_log で出力（NFR 2.1, NFR 2.2）
# 戻り値:
#   0 = 判定成功（START_STAGE 設定済）
#   1 = 内部エラー（START_STAGE="A" にフォールバック、Req 5.4）
stage_checkpoint_resolve_resume_point() {
  # 内部エラーの安全側フォールバックのため、エラーを補足できるよう || true で個別ガード。
  # START_STAGE は呼び出し元 run_impl_pipeline（task 4）が読み取る共有変数。
  # task 3 単独では read 側が無いため SC2034 を一括抑制（task 4 で消える）。
  # shellcheck disable=SC2034
  START_STAGE="A"

  sc_log "--- begin resolve (issue=#$NUMBER branch=$BRANCH) ---" >> "$LOG"
  sc_log "input: spec_dir=$SPEC_DIR_REL" >> "$LOG"

  # 1) 既存 impl PR を最優先で検出（Req 2.6: TERMINAL_OK）。
  local pr_info pr_rc
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) && pr_rc=0 || pr_rc=$?
  case "$pr_rc" in
    0)
      sc_log "input: existing-impl-pr=$pr_info" >> "$LOG"
      START_STAGE="TERMINAL_OK"
      sc_log "decision: START_STAGE=TERMINAL_OK reason=existing-impl-pr" >> "$LOG"
      sc_log "--- end resolve ---" >> "$LOG"
      return 0
      ;;
    1)
      sc_log "input: existing-impl-pr=none" >> "$LOG"
      ;;
    *)
      sc_warn "gh pr list failed (rc=$pr_rc) → safe fallback: existing-impl-pr=unknown" >> "$LOG"
      sc_log "input: existing-impl-pr=unknown" >> "$LOG"
      # gh API エラーは判定継続（fallback="A"）。Stage A 再実行は安全（Req 5.4）
      ;;
  esac

  # 2) impl-notes.md tracked 判定（Stage A 完了 checkpoint）。
  local has_impl="no"
  if stage_checkpoint_has_impl_notes; then
    has_impl="yes"
  fi
  sc_log "input: impl-notes.md tracked=$has_impl" >> "$LOG"

  # 3) review-notes.md tracked + RESULT 行 parse（Stage B 完了 checkpoint）。
  # stdout 側の TSV は本箇所では未使用（result/round は別途 grep で取得）。
  local rev_rc=0
  stage_checkpoint_read_review_result >/dev/null 2>&1 || rev_rc=$?
  local rev_result="(none)"
  case "$rev_rc" in
    0) rev_result="approve" ;;
    1) rev_result="reject" ;;
    *) rev_result="(missing-or-unparsed)" ;;
  esac
  # tracked 判定（rev_rc から逆算するのではなく、ls-tree で実態を直接観測する）。
  local rev_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  local rev_tracked="no"
  if [ -f "$rev_path" ]; then
    local rev_ls_out
    rev_ls_out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$SPEC_DIR_REL/review-notes.md" 2>/dev/null || true)
    [ -n "$rev_ls_out" ] && rev_tracked="yes"
  fi
  # round 判定: review-notes.md 内に round=N が無ければ "unknown"（INCONSISTENT 扱い）
  local rev_round="unknown"
  if [ "$has_impl" = "yes" ] && [ -f "$rev_path" ]; then
    if grep -q '^<!-- idd-claude:review round=2' "$rev_path" 2>/dev/null \
       || grep -q '^round=2$' "$rev_path" 2>/dev/null; then
      rev_round="2"
    elif grep -q '^<!-- idd-claude:review round=1' "$rev_path" 2>/dev/null \
       || grep -q '^round=1$' "$rev_path" 2>/dev/null; then
      rev_round="1"
    fi
  fi
  sc_log "input: review-notes.md tracked=$rev_tracked result=$rev_result round=$rev_round" >> "$LOG"

  # 4) Decision Table（評価順序: 矛盾検出 → 通常分岐）。
  if [ "$has_impl" = "no" ]; then
    if [ "$rev_rc" -eq 2 ]; then
      # impl-notes 無 / review-notes 無 → 通常の Stage A (Req 2.2)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=no-checkpoint" >> "$LOG"
    else
      # impl-notes 無 / review-notes 有 → INCONSISTENT (Req 5.1)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=inconsistent-review-notes-without-impl-notes" >> "$LOG"
    fi
    sc_log "--- end resolve ---" >> "$LOG"
    return 0
  fi

  # ここから has_impl=yes 系
  case "$rev_rc" in
    2)
      # review-notes 不在 or 解釈不能。
      # #251: per-task ループ未完（tasks.md に残必須タスクあり）の場合は、impl-notes.md が
      # tracked でも Stage A を再開して残タスクを完了させる。per-task ループ (#21) は task 1
      # 完了時点で impl-notes.md へ learning を commit するため、これを「Stage A 完了」と
      # みなして Stage B へ skip すると、残タスク（後続）が永久に未完になり、後続タスクが
      # 作る成果物（test fixture 等）に依存する stage-a-verify が無限に失敗する（#68 と
      # #194 hold-resume の衝突）。残必須タスクが無い場合のみ従来どおり Stage B へ skip する。
      local _sc_tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
      local _sc_pending=""
      if [ -f "$_sc_tasks_md" ]; then
        _sc_pending=$(pt_extract_pending_tasks "$_sc_tasks_md" 2>/dev/null || true)
      fi
      if [ -n "$_sc_pending" ]; then
        local _sc_pending_count
        _sc_pending_count=$(printf '%s\n' "$_sc_pending" | grep -c . 2>/dev/null || echo 0)
        # shellcheck disable=SC2034
        START_STAGE="A"
        sc_log "decision: START_STAGE=A reason=per-task-incomplete (#251: impl-notes.md ありだが tasks.md に残必須タスク ${_sc_pending_count} 件 → Stage A 再開)" >> "$LOG"
      else
        # tasks.md 不在（design-less impl）/ 残必須タスク 0 件（完走済み）→ 従来どおり Stage B
        START_STAGE="B"
        sc_log "decision: START_STAGE=B reason=impl-notes-only-or-review-unparsed" >> "$LOG"
      fi
      ;;
    0)
      # approve → Stage C (Req 2.4)
      START_STAGE="C"
      sc_log "decision: START_STAGE=C reason=approve+no-pr" >> "$LOG"
      ;;
    1)
      # reject → round で分岐 (D-3, Req 2.5)
      case "$rev_round" in
        2)
          START_STAGE="TERMINAL_FAILED"
          sc_log "decision: START_STAGE=TERMINAL_FAILED reason=round2-reject-residual" >> "$LOG"
          ;;
        1)
          # round=1 reject の中断状態は同 tick 完結前提が破れた状況 → Stage A 再実行 (D-3)
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=round1-reject-mid-tick-fallback" >> "$LOG"
          ;;
        *)
          # round=N が読み取れない（手動編集 / 旧フォーマット）→ INCONSISTENT 扱い
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=reject-with-unknown-round" >> "$LOG"
          ;;
      esac
      ;;
  esac

  sc_log "--- end resolve ---" >> "$LOG"
  return 0
}

# ─── stage_c_existing_pr_guard ───
#
# Stage C の PR 作成処理へ進む直前に、同一 head ブランチの既存 impl PR を
# 「再確認」する冪等ガード（Issue #212）。サイクル開始時の
# `stage_checkpoint_resolve_resume_point` による 1 回限りの観測では、同一サイクル内で
# Stage A の worker が越境して PR を作成したケースを検出できないため、PR 作成段階でも
# 既存 PR を再観測して二重 PR を防ぐ（Req 1.4 / NFR 2.1）。
#
# 本ガードは Stage Checkpoint モジュールの観測ヘルパ `stage_checkpoint_find_impl_pr` を
# 再利用し、`STAGE_CHECKPOINT_ENABLED=true`（#112 以降の既定）時のみ有効化する。
# `true` 以外（明示 opt-out その他の任意の値）では本関数は副作用を一切持たず、即座に
# 「作成方向へ進む」を意味する return 1 を返す（Req 1.2 / NFR 1.2）。
#
# 状態別の挙動（Req 2 / 3 / 4 / 6）:
#   - OPEN   → 新規作成抑止。判定根拠を sc_log で出力。Issue コメントは投稿しない。return 0
#   - MERGED → 着地済みとみなし停止。判定根拠を sc_log で出力。Issue コメントなし。return 0
#   - CLOSED → 新規作成抑止 + needs-decisions 付与 + Issue コメント 1 件投稿
#              （claude-failed は付与しない）。return 0
#   - none (rc=1) → 従来どおり PR 作成へ進む。return 1
#   - gh API エラー (rc=2) → 警告ログ（二重 PR の可能性を含む）を出して作成方向へ
#              フォールバック。return 1（既存 resolve_resume_point の API エラー fallback と同方針）
#
# 入力: 環境変数 STAGE_CHECKPOINT_ENABLED / NUMBER / BRANCH / REPO / LOG /
#       LABEL_NEEDS_DECISIONS（既存）
# 副作用:
#   - $LOG への sc_log / sc_warn 出力（NFR 3.1 / 3.2）
#   - CLOSED 検出時のみ gh issue edit --add-label / gh issue comment（fail-open）
# 戻り値:
#   0 = 既存 PR を検出し新規作成を抑止した（呼び出し側は return 0 で pipeline を停止する）
#   1 = 既存 PR なし / gate off / gh API エラー → 従来どおり PR 作成へ進む
stage_c_existing_pr_guard() {
  # gate: STAGE_CHECKPOINT_ENABLED=true（既定）時のみ実行。`=true` 以外では本ガードを
  # 1 行も実行せず作成方向へ抜ける（Req 1.2 / NFR 1.2）。`:-true` で unset も既定有効扱い。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" != "true" ]; then
    return 1
  fi

  # include_closed=true: 同一サイクル内で Stage A 越境後に CLOSED 状態の PR を新規検出する
  # ケースについて Issue #212 の既存規約（needs-decisions 付与 + Issue コメント）を保持する
  # （Issue #265 Out of Scope と整合）。include_closed=false な他経路（resolve_resume_point /
  # stage_a_crossing_probe / spec_artifacts_completeness_guard）では CLOSED は除外される。
  local pr_info pr_rc
  pr_info=$(stage_checkpoint_find_impl_pr true 2>/dev/null) && pr_rc=0 || pr_rc=$?

  case "$pr_rc" in
    1)
      # 既存 PR なし → 従来どおり PR 作成へ進む（Req 5.1）。本機能導入前と挙動不変。
      return 1
      ;;
    2)
      # gh API エラー → 既存有無を確定できない。作成方向へフォールバック（Req 6.2）。
      # 二重 PR の可能性を含む警告を残す（Req 6.1 / 6.3 / NFR 3.2）。
      sc_warn "Stage C 既存 PR 再確認が gh API エラー → 作成方向へフォールバック（二重 PR の可能性あり / issue=#$NUMBER branch=$BRANCH）" >> "$LOG"
      sc_log "stage-c-guard: existing-impl-pr=unknown reason=gh-api-error fallback=create" >> "$LOG"
      return 1
      ;;
  esac

  # pr_rc=0: 既存 impl PR を検出。`<pr_number>,<state>` を分解する（Req 1.3）。
  local pr_number pr_state
  pr_number="${pr_info%%,*}"
  pr_state="${pr_info##*,}"

  case "$pr_state" in
    OPEN)
      # Req 2.1/2.2/2.3/2.4: 新規作成抑止 + return 0。ログのみ、Issue コメントなし。
      sc_log "stage-c-guard: existing-impl-pr=$pr_info state=OPEN action=skip-create reason=reuse-open-pr (issue=#$NUMBER branch=$BRANCH)" >> "$LOG"
      return 0
      ;;
    MERGED)
      # Req 3.1/3.2/3.3/3.4: 着地済みとみなし停止。ログのみ、Issue コメントなし。
      sc_log "stage-c-guard: existing-impl-pr=$pr_info state=MERGED action=skip-create reason=already-merged (issue=#$NUMBER branch=$BRANCH)" >> "$LOG"
      return 0
      ;;
    CLOSED)
      # Req 4.1〜4.5: 新規作成抑止 + needs-decisions 付与 + Issue コメント 1 件。
      # claude-failed は付与しない（mark_issue_failed を使わない）。
      sc_log "stage-c-guard: existing-impl-pr=$pr_info state=CLOSED action=skip-create+needs-decisions reason=human-closed (issue=#$NUMBER branch=$BRANCH)" >> "$LOG"
      local guard_body
      guard_body="🛑 自動処理を中止しました（既存 impl PR が CLOSED 済み / Issue #212 冪等ガード）。

- 対象 Issue: #${NUMBER:-?}
- 検出した既存 impl PR: #${pr_number}（状態: CLOSED）
- head ブランチ: \`${BRANCH}\`

同一 head ブランチに対する impl PR が既に CLOSED されているため、Stage C での
新規 PR 作成を抑止しました。人間が意図的に close した PR を自動再生成して運用判断を
上書きしないための安全側の停止です。

### 次の手順

1. 既存 PR #${pr_number} を再オープンするか、改めて手動で対応するか判断してください
2. 自動処理を再開してよい場合は、本 Issue から \`${LABEL_NEEDS_DECISIONS}\` ラベルを
   外してください（次サイクルで再評価されます）"
      gh issue edit "$NUMBER" --repo "$REPO" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
      gh issue comment "$NUMBER" --repo "$REPO" --body "$guard_body" >/dev/null 2>&1 || true
      return 0
      ;;
    *)
      # 想定外の state（find_impl_pr の select で除外されるはずだが防御的に扱う）。
      # 既存有無を確定できないとみなし作成方向へフォールバック（Req 6.2 と同方針）。
      sc_warn "Stage C 既存 PR 再確認で想定外の state='$pr_state'（pr_info='$pr_info'）→ 作成方向へフォールバック（issue=#$NUMBER branch=$BRANCH）" >> "$LOG"
      sc_log "stage-c-guard: existing-impl-pr=$pr_info state=unexpected fallback=create" >> "$LOG"
      return 1
      ;;
  esac
}

# ─── stage_a_crossing_probe ───
#
# Stage A 完了直後に、当該 head ブランチに紐づく先行 impl PR の有無を観測し、存在すれば
# 「越境（Stage A worker が制約に反して PR を作成した）」として記録して後段の spec 成果物
# 完全性チェック（spec_artifacts_completeness_guard）へグローバル変数で引き継ぐ（Issue #219
# Req 2）。#212 の `stage_c_existing_pr_guard` が Stage C 直前で行う再確認より「早い時点
# （Stage A 完了直後）」で越境を検出することが目的であり、PR の close / ラベル付与等の
# 副作用は一切持たない read-only 観測（Req 2 のスコープ）。
#
# 本関数は Stage Checkpoint モジュールの観測ヘルパ `stage_checkpoint_find_impl_pr` を
# 再利用し、`STAGE_CHECKPOINT_ENABLED=true`（#112 以降の既定）時のみ有効化する。
# `true` 以外（明示 opt-out その他の任意の値）では本関数は 1 行も実行せず即 return 0 する。
# このとき検出フラグも set せず、本修正導入前と完全に同一の挙動を保つ（Req 2.5 / NFR 1.1）。
#
# `find_impl_pr` を include_closed=false（既定）で呼ぶため、CLOSED 未マージ PR は越境根拠
# として記録されない（Issue #265 / Req 3.3）。OPEN / MERGED の既存挙動は不変。
#
# 入力: 環境変数 STAGE_CHECKPOINT_ENABLED / NUMBER / BRANCH / REPO / LOG
# 副作用:
#   - $LOG への sc_log / sc_warn 出力（検出時のみ sc_log / NFR 3.1）
#   - グローバル変数 STAGE_A_CROSSING_DETECTED（yes/no）/ STAGE_A_CROSSING_PR（PR 番号 or 空）
#     の set（gate off 時は set しない）
# 戻り値: 常に 0（観測は pipeline を止めない / NFR 1.4）
stage_a_crossing_probe() {
  # gate: STAGE_CHECKPOINT_ENABLED=true（既定）時のみ実行。`=true` 以外では本観測を
  # 1 行も実行せず即 return 0（Req 2.5 / NFR 1.1）。`:-true` で unset も既定有効扱い。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" != "true" ]; then
    return 0
  fi

  local pr_info pr_rc
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) && pr_rc=0 || pr_rc=$?

  case "$pr_rc" in
    0)
      # 先行 impl PR を検出 = Stage A 越境。`<pr_number>,<state>` を分解する（Req 2.3）。
      local pr_number pr_state
      pr_number="${pr_info%%,*}"
      pr_state="${pr_info##*,}"
      STAGE_A_CROSSING_DETECTED="yes"
      STAGE_A_CROSSING_PR="$pr_number"
      # 検出時のみ越境を既存ログ書式で記録（PR 番号と head ブランチを判定根拠に / Req 2.2, 2.3, NFR 3.1）。
      sc_log "stage-a-crossing: detected pr=#${pr_number} state=${pr_state} branch=${BRANCH} issue=#${NUMBER}" >> "$LOG"
      ;;
    1)
      # 先行 PR なし → 越境なし（通常フロー）。本修正導入前と挙動不変。
      STAGE_A_CROSSING_DETECTED="no"
      STAGE_A_CROSSING_PR=""
      ;;
    *)
      # gh API エラー → 越境有無を確定できない。安全側（越境未検出）として継続し
      # 二重処理を生まない。警告を残す（NFR 3.1 / silent fail を作らない）。
      sc_warn "Stage A 越境観測が gh API エラー（rc=$pr_rc）→ 越境未検出として継続（issue=#$NUMBER branch=$BRANCH）" >> "$LOG"
      STAGE_A_CROSSING_DETECTED="no"
      STAGE_A_CROSSING_PR=""
      ;;
  esac
  return 0
}

# ─── _spec_missing_artifacts ───
#
# spec ディレクトリ（$REPO_DIR/$SPEC_DIR_REL）配下の必須成果物のうち、branch HEAD tracked
# で欠落しているものの種別を stdout に列挙する read-only 検査関数（Issue #219 Req 3.4）。
# 判定は `stage_checkpoint_has_impl_notes` と同じく `git ls-tree --name-only HEAD -- <path>`
# を用い、working tree のみに存在し未 commit のファイルは欠落扱いとする。
#
# 本機能の補完対象は `requirements.md` / `review-notes.md` の 2 種に限定する（Req 3.2）。
# design.md / tasks.md は設計 PR で別途 main に merge される成果物であり、impl 経路の
# 越境補完では docs commit で機械再構築できないため **補完対象外** とする。ただし検査
# ログには design 系の不足も `missing-design` として記録し、人間が grep で観測できるように
# する（design.md Data Models / 検査は記録するが補完しない）。
#
# 入力: 引数 $1 = spec_dir_rel（省略時は環境変数 SPEC_DIR_REL）/ 環境変数 REPO_DIR / LOG
# stdout: 補完対象の欠落種別をスペース区切りで列挙（例: `requirements review`）。欠落なしなら空。
# 戻り値: 常に 0
# 副作用: $LOG への sc_log 出力（不足検出時のみ / Req 3.4 / NFR 3.2）
_spec_missing_artifacts() {
  local spec_dir_rel="${1:-$SPEC_DIR_REL}"
  local missing=""
  local missing_log=""

  # 補完対象（requirements.md / review-notes.md）の欠落判定。
  local f key
  for f in requirements:requirements.md review:review-notes.md; do
    key="${f%%:*}"
    local fname="${f##*:}"
    local rel="$spec_dir_rel/$fname"
    local out
    out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
    if [ -z "$out" ]; then
      missing="${missing:+$missing }$key"
    fi
  done

  # design 系（design.md / tasks.md）は補完対象外だが検査ログには記録する。
  local d dkey dfname drel dout design_missing=""
  for d in design:design.md tasks:tasks.md; do
    dkey="${d%%:*}"
    dfname="${d##*:}"
    drel="$spec_dir_rel/$dfname"
    dout=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$drel" 2>/dev/null || true)
    if [ -z "$dout" ]; then
      design_missing="${design_missing:+$design_missing }$dkey"
    fi
  done

  # 検査ログ（不足を検出したときのみ。補完対象 + 補完対象外の design 系を併記 / Req 3.4 / NFR 3.2）。
  if [ -n "$missing" ] || [ -n "$design_missing" ]; then
    missing_log="missing=${missing:-none}"
    [ -n "$design_missing" ] && missing_log="$missing_log missing-design=${design_missing}"
    sc_log "spec-completeness: $missing_log dir=$spec_dir_rel" >> "$LOG"
  fi

  # 補完対象のみを stdout へ（design 系は補完対象外のため出力しない / Req 3.2）。
  [ -n "$missing" ] && printf '%s' "$missing"
  return 0
}

# ─── _spec_create_docs_pr ───
#
# spec 成果物の欠落を解消する docs-only の補完追従 PR を作成する（Issue #219 Req 3.2 /
# 4.2 / 4.3 / Decision D2 / D3）。impl PR とは別系統の head ブランチ
# `claude/issue-<NUMBER>-docs-<SLUG>` を使うことで、#213 の MERGED ガード（`--head $BRANCH`
# 判定）と衝突せず、新規 impl PR を二重に作らない（Req 4.3）。
#
# 冪等性（NFR 2.1 / 2.2）: 作成前に `gh pr list --head <docs-branch> --state all` で既存の
# docs 補完 PR を再観測し、あれば作成しない。
#
# 入力: 引数 $1 = missing（_spec_missing_artifacts の出力。例: `requirements review`）/
#       環境変数 NUMBER / SLUG / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / BASE_BRANCH / LOG
# 戻り値: 0 = 補完 PR 作成成功 or 既存 docs PR を検出してスキップ（冪等）/
#         1 = gh pr create 失敗（呼び出し側はエスカレーションへフォールバック）
# 副作用: docs-only branch への commit + push + gh pr create（失敗時 sc_warn）
_spec_create_docs_pr() {
  local missing="$1"
  local docs_branch="claude/issue-${NUMBER}-docs-${SLUG}"

  # 冪等ガード: 既存の docs 補完 PR があれば作成しない（NFR 2.1 / 2.2）。
  local existing_docs_pr
  existing_docs_pr=$(gh pr list --repo "$REPO" --head "$docs_branch" --state all \
                     --json number --limit 1 2>/dev/null \
                     | jq -r '.[0].number // empty' 2>/dev/null || true)
  if [ -n "$existing_docs_pr" ]; then
    sc_log "spec-completeness: action=docs-pr result=skip-existing pr=#${existing_docs_pr} branch=${docs_branch} issue=#${NUMBER}" >> "$LOG"
    return 0
  fi

  # docs-only branch を base から切る（impl ブランチとは別系統 / Req 4.3）。
  # 失敗は補完不能としてエスカレーションへフォールバックさせる。
  if ! git -C "$REPO_DIR" checkout -B "$docs_branch" "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    sc_warn "spec-completeness: docs-only branch 作成失敗（branch=$docs_branch base=origin/$BASE_BRANCH issue=#$NUMBER）→ エスカレーションへ" >> "$LOG"
    return 1
  fi

  # 不足している requirements.md / review-notes.md のみを最小限の placeholder で補完する。
  # 内容は spec パスと不足種別のみ（実値の機密情報を埋め込まない / Security Considerations）。
  local spec_abs="$REPO_DIR/$SPEC_DIR_REL"
  mkdir -p "$spec_abs"
  local added=""
  local m
  for m in $missing; do
    case "$m" in
      requirements)
        if [ ! -f "$spec_abs/requirements.md" ]; then
          {
            echo "# Requirements Document"
            echo ""
            echo "> このファイルは spec 成果物完全性保証（Issue #219 / spec-completeness）により"
            echo "> 自動補完された placeholder です。先行 impl PR が requirements.md を含まないまま"
            echo "> MERGED されたため、spec ディレクトリの標準構成を満たす目的で作成されました。"
            echo "> 元の要件定義が別途存在する場合は、人間がこのファイルを正規の内容へ更新してください。"
          } > "$spec_abs/requirements.md"
          added="${added:+$added }requirements.md"
        fi
        ;;
      review)
        if [ ! -f "$spec_abs/review-notes.md" ]; then
          {
            echo "# Review Notes"
            echo ""
            echo "> このファイルは spec 成果物完全性保証（Issue #219 / spec-completeness）により"
            echo "> 自動補完された placeholder です。先行 impl PR が review-notes.md を含まないまま"
            echo "> MERGED されたため、spec ディレクトリの標準構成を満たす目的で作成されました。"
            echo "> 元のレビュー記録が別途存在する場合は、人間がこのファイルを正規の内容へ更新してください。"
          } > "$spec_abs/review-notes.md"
          added="${added:+$added }review-notes.md"
        fi
        ;;
    esac
  done

  if [ -z "$added" ]; then
    # 追加対象が無い（既に working tree 上に存在）→ 作成不要として成功扱い。
    sc_log "spec-completeness: action=docs-pr result=nothing-to-add dir=$SPEC_DIR_REL issue=#${NUMBER}" >> "$LOG"
    return 0
  fi

  git -C "$REPO_DIR" add "$SPEC_DIR_REL" >/dev/null 2>&1 || true
  if ! git -C "$REPO_DIR" commit -m "docs(specs): #${NUMBER} の不足成果物を補完（spec-completeness）" >/dev/null 2>&1; then
    sc_warn "spec-completeness: docs-only commit 失敗（issue=#$NUMBER added=$added）→ エスカレーションへ" >> "$LOG"
    return 1
  fi
  if ! git -C "$REPO_DIR" push -u origin "$docs_branch" >/dev/null 2>&1; then
    sc_warn "spec-completeness: docs-only push 失敗（branch=$docs_branch issue=#$NUMBER）→ エスカレーションへ" >> "$LOG"
    return 1
  fi

  # docs-only PR を作成（base は BASE_BRANCH を明示 / #96 踏襲。ready-for-review は付与しない / Req 4.3）。
  local pr_body
  pr_body="🤖 spec 成果物完全性保証（Issue #219 / spec-completeness）による docs-only 補完 PR です。

- 対象 Issue: #${NUMBER}
- 対象 spec ディレクトリ: \`${SPEC_DIR_REL}\`
- 補完したファイル: ${added}

先行 impl PR が上記成果物を含まないまま MERGED されたため、spec ディレクトリの
標準構成（requirements.md / review-notes.md / impl-notes.md）を満たす目的で
不足分を補完しました。本 PR は impl PR とは別系統の docs-only 追従 PR です
（\`ready-for-review\` は付与していません。内容を確認のうえ人間が merge してください）。"
  if ! gh pr create --repo "$REPO" \
        --base "$BASE_BRANCH" \
        --head "$docs_branch" \
        --title "docs(specs): #${NUMBER} の不足成果物を補完（spec-completeness）" \
        --body "$pr_body" >/dev/null 2>&1; then
    sc_warn "spec-completeness: gh pr create 失敗（branch=$docs_branch base=$BASE_BRANCH issue=#$NUMBER）→ エスカレーションへ" >> "$LOG"
    return 1
  fi
  sc_log "spec-completeness: action=docs-pr result=created branch=${docs_branch} base=${BASE_BRANCH} added=${added} dir=${SPEC_DIR_REL} issue=#${NUMBER}" >> "$LOG"
  return 0
}

# ─── _spec_escalate_incomplete ───
#
# spec 成果物の欠落を watcher が自動で解消できないとき（docs-only 補完 PR 作成失敗等）に、
# 人間が判別可能な形でエスカレーションする（Issue #219 Req 3.3 / Decision D4）。`needs-decisions`
# ラベル付与 + Issue コメント 1 件を発射する。#212 の過剰通知回避方針（補完成功時はログのみ）
# と整合し、本関数は **補完不能時のみ** 呼ばれる。
#
# 冪等性（NFR 2.2）: `needs-decisions` が既付与なら Issue コメントを再投稿しない。`gh` 系の
# 副作用は `|| true` で fail-open（既存 `_slug_mismatch_escalate` / Stage C CLOSED 分岐と同方針）。
#
# 入力: 引数 $1 = missing / 環境変数 NUMBER / REPO / SPEC_DIR_REL / LABEL_NEEDS_DECISIONS / LOG
# 戻り値: 常に 0
# 副作用: gh issue edit --add-label / gh issue comment（既付与時はコメントを抑止）
_spec_escalate_incomplete() {
  local missing="$1"

  # 冪等: needs-decisions が既付与ならコメントを再投稿しない（同一サイクル再実行・複数 slot で重複しない）。
  local label_json existing_label_match=""
  if label_json=$(gh issue view "$NUMBER" --repo "$REPO" --json labels 2>/dev/null); then
    existing_label_match=$(echo "$label_json" \
      | jq -r --arg L "$LABEL_NEEDS_DECISIONS" '.labels[]? | select(.name == $L) | .name' 2>/dev/null \
      || true)
  fi

  if [ -n "$existing_label_match" ]; then
    sc_log "spec-completeness: action=escalate result=skip-already-needs-decisions missing=${missing:-?} dir=${SPEC_DIR_REL} issue=#${NUMBER}" >> "$LOG"
    return 0
  fi

  local body
  body="🛑 spec 成果物の自動補完に失敗しました（Issue #219 / spec-completeness）。

- 対象 Issue: #${NUMBER}
- 対象 spec ディレクトリ: \`${SPEC_DIR_REL}\`
- 不足している成果物: ${missing:-?}

先行 impl PR が MERGED 済みで、上記成果物が spec ディレクトリに不足しています。
docs-only 補完追従 PR の自動作成に失敗したため、人間判断に委ねます。

### 次の手順

1. 不足している成果物（${missing:-?}）を \`${SPEC_DIR_REL}\` 配下へ手動で補完してください
2. 補完後、本 Issue から \`${LABEL_NEEDS_DECISIONS}\` ラベルを外してください（次サイクルで再評価されます）"

  gh issue edit "$NUMBER" --repo "$REPO" \
    --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  sc_log "spec-completeness: action=escalate result=needs-decisions missing=${missing:-?} dir=${SPEC_DIR_REL} issue=#${NUMBER}" >> "$LOG"
  return 0
}

# ─── spec_artifacts_completeness_guard ───
#
# pipeline 最終局面で、main 着地後の spec ディレクトリが標準構成（requirements.md /
# review-notes.md / impl-notes.md）を満たすことを保証する orchestrator（Issue #219 Req 3 / 4）。
# 越境有無やどのステージが PR を作ったかに関わらず、先行 impl PR が MERGED 済みで req/review が
# 欠落しているケース（#216 で実発生）に対し docs-only 補完追従 PR を 1 本だけ作成し、補完不能
# なら 1 回だけエスカレーションする。
#
# #213 ガードとの非干渉（Req 4.1）: 本関数は `stage_c_existing_pr_guard` を呼ばず、その後段に
# 置かれる。MERGED ガードの「新規 impl PR 抑止」は維持され、本関数は impl PR を作らず
# docs-only PR のみ作成する（Req 4.2 / 4.3）。MERGED 以外（OPEN/none）では補完を起動しない
# （OPEN は通常フローで review-notes が commit され、none は本来の Stage C 経路 / Req 4.1）。
# CLOSED 未マージ PR のみのケースは `find_impl_pr`（include_closed=false）が rc=1 を返し
# pr_state="(none)" として扱われるため、補完起動条件の MERGED マッチには到達しない
# （Issue #265 / Req 3.4 と整合: MERGED のみが起動条件、その他は無起動）。
#
# `STAGE_CHECKPOINT_ENABLED=true`（既定）時のみ有効化する。`=true` 以外では 1 行も実行せず
# 即 return 0 し、本修正導入前と完全に同一の挙動を保つ（Req 3.5 / NFR 1.1）。
#
# 入力: 環境変数 STAGE_CHECKPOINT_ENABLED / NUMBER / SLUG / BRANCH / REPO / REPO_DIR /
#       SPEC_DIR_REL / BASE_BRANCH / LABEL_NEEDS_DECISIONS / LOG /
#       STAGE_A_CROSSING_DETECTED（stage_a_crossing_probe が set / Req 2.4 引き継ぎ）
# 戻り値: 常に 0（pipeline 最終結果を変えない / NFR 1.4）
# 副作用: docs-only 補完 PR 1 本 or needs-decisions+コメント or 無し
spec_artifacts_completeness_guard() {
  # gate: STAGE_CHECKPOINT_ENABLED=true（既定）時のみ実行（Req 3.5 / NFR 1.1）。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" != "true" ]; then
    return 0
  fi

  # 標準構成の充足判定（補完対象 = requirements / review の欠落種別）。
  local missing
  missing=$(_spec_missing_artifacts "$SPEC_DIR_REL")
  if [ -z "$missing" ]; then
    # 標準構成を既に満たす → 追加処理なしで return 0（Req 3.1, 3.5 / NFR 1.1）。
    return 0
  fi

  # Req 2.4 引き継ぎ: stage_a_crossing_probe が set した越境検出フラグを判定根拠ログに含める
  # （越境有無に関わらず欠落があれば完全性保証は動くが、越境起因の欠落を grep で識別可能にする）。
  local crossing_note="crossing=${STAGE_A_CROSSING_DETECTED:-no}"
  [ "${STAGE_A_CROSSING_DETECTED:-no}" = "yes" ] && crossing_note="$crossing_note crossing-pr=#${STAGE_A_CROSSING_PR:-?}"

  # 先行 impl PR の state を取得（補完起動条件の判定 / Req 3.2）。
  local pr_info pr_rc pr_state="(none)"
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) && pr_rc=0 || pr_rc=$?
  case "$pr_rc" in
    0) pr_state="${pr_info##*,}" ;;
    1) pr_state="(none)" ;;
    *)
      # gh API エラー → state 不明。誤補完で二重 PR を作るより安全側に倒し、補完を起動せず
      # 警告を残して return 0。次サイクルで再評価される（Error Handling）。
      sc_warn "spec-completeness: 先行 impl PR の state 取得が gh API エラー（rc=$pr_rc）→ 補完を起動せず継続（missing=$missing dir=$SPEC_DIR_REL issue=#$NUMBER）" >> "$LOG"
      sc_log "spec-completeness: action=none reason=gh-api-error missing=${missing} dir=${SPEC_DIR_REL} ${crossing_note} issue=#${NUMBER}" >> "$LOG"
      return 0
      ;;
  esac

  case "$pr_state" in
    MERGED)
      # MERGED かつ req/review 欠落 → docs-only 補完追従 PR を起動。失敗時はエスカレーションへ
      # フォールバック（Req 3.2, 3.3）。impl PR は作らない（Req 4.2）。
      sc_log "spec-completeness: trigger=merged missing=${missing} dir=${SPEC_DIR_REL} ${crossing_note} issue=#${NUMBER}" >> "$LOG"
      if ! _spec_create_docs_pr "$missing"; then
        _spec_escalate_incomplete "$missing"
      fi
      ;;
    *)
      # MERGED 以外（OPEN/CLOSED/none）は補完を起動しない（#213 ガード非干渉 / Req 4.1）。
      # 補完対象外として記録のみ（過剰通知回避 / Decision D4）。
      sc_log "spec-completeness: action=none reason=not-merged state=${pr_state} missing=${missing} dir=${SPEC_DIR_REL} ${crossing_note} issue=#${NUMBER}" >> "$LOG"
      ;;
  esac
  return 0
}
