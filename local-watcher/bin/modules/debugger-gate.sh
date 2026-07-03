#!/usr/bin/env bash
# debugger-gate.sh — Debugger Gate モジュール（#22 Phase 3 / #458 切り出し）
#
# 用途:
#   `DEBUGGER_ENABLED=true` のときに `run_impl_pipeline` の Stage B' (Round 2) reject 直前
#   / Stage A 完了直後 BLOCKED 検出経路で起動される Debugger サブエージェントの補助関数群。
#   `DEBUGGER_ENABLED` が未指定 / `=true` 以外の場合、これらの関数はどこからも呼ばれない
#   ため、本機能導入前と外形挙動は完全一致する（NFR 1.1 / Req 1.1, 1.2）。
#
#   - dbg_log / dbg_warn                : Debugger 専用ロガー（rv_log / pt_log と同形式）
#   - detect_blocked_marker             : impl-notes.md の行頭 `BLOCKED: <reason>` を検出
#   - detect_partial_status             : impl-notes.md の行頭 `STATUS: <value>` を検出
#   - detect_debugger_already_invoked   : sentinel file ベースで再起動抑止判定
#   - validate_debugger_notes           : debugger-notes.md の必須 h2 セクション 4 つを verify
#   - build_debugger_prompt             : Debugger 起動用 prompt を組立
#   - run_debugger_stage                : claude --print で fresh Debugger 起動 + 結果 verify
#
#   詳細: docs/specs/22-phase-3-debugger-subagent-blocked-2-reje/design.md
#
#   注意（#458）: `build_dev_prompt_redo_with_fix_plan` は本 module 冒頭バナー旧文言の
#   「関数一覧」に記載されていたが、実際の物理セクション境界（本体側の従来コメント
#   「Debugger Gate helper はここまで」）より後ろの別セクションで定義されている別関数
#   であり、#458 の対象 8 関数には含まれないため本 module には含めない（本体に残置）。
#
# 配置先:
#   $HOME/bin/modules/debugger-gate.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $NUMBER / $SPEC_DIR_REL / $LOG / $DEBUGGER_MODEL /
#     $DEBUGGER_MAX_TURNS / $REPO_SLUG / $CLAUDE_HOOK_ARGS）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 呼び出し先（前方参照。呼び出し時＝source 完了後に解決される）: qa_run_claude_stage /
#     qa_handle_quota_exceeded / mark_issue_failed / publish_terminal_failure_artifacts。
#   - 呼び出し元（per-task loop / impl pipeline。Reviewer Round 2 直前・BLOCKED 検出）は
#     実行順序温存のため本体側に残る（#458 では移動しない）。
#   - 外部 CLI: grep / date / claude。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# ─── dbg_log ───
# Debugger 専用ロガー。`[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: <msg>` 形式で stdout
# に出力。呼び出し側で `>> "$LOG"` する規約（既存 rv_log / pt_log / qa_log と同じ）。
# Issue #119 規約準拠で時刻 prefix と processor prefix の間に `[$REPO]` を 1 つだけ挿入。
# NFR 2.1 / NFR 2.2 を満たす。
dbg_log() {
  echo "[$(date '+%F %T')] [$REPO] debugger: $*"
}
dbg_warn() {
  echo "[$(date '+%F %T')] [$REPO] debugger: WARN: $*" >&2
}

# ─── detect_blocked_marker <impl_notes_path> ───
#
# impl-notes.md の **行頭固定** で `BLOCKED: <reason>` 行を検出し、reason 部を stdout に
# 出力する。検出時 return 0、未検出 / ファイル不在時 return 1。
#
# 規約（Req 4.2 / 誤検出抑止）:
#   - regex は `^BLOCKED: (.+)$`（行頭固定、半角コロン + 半角スペース + 任意 reason 文字列）
#   - インデント / list marker `- ` / 引用 `> ` の prefix は **検出対象外**
#   - reason 部の `:` 文字は破壊しない（grep -E で行マッチした上で sed で先頭 `BLOCKED: ` を剥がす）
#   - 複数マッチ時は **1 行目** のみ採用
#
# Requirements: 4.1, 4.2
detect_blocked_marker() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 1
  fi
  local line
  # grep -E で行頭固定マッチ。set -euo pipefail 配下では grep no-match で関数全体が止まるため
  # `|| true` で吸収。
  line=$(grep -E '^BLOCKED: .+$' "$impl_notes" 2>/dev/null | head -n 1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  # 先頭 `BLOCKED: `（10 文字）を剥がして reason のみ stdout に出す。
  # reason 部に `:` が含まれても破壊されないよう、置換ではなく substring 切り出しを行う。
  printf '%s\n' "${line#BLOCKED: }"
  return 0
}

# ─── detect_partial_status <impl_notes_path> ───
#
# impl-notes.md の **行頭固定** で `STATUS: <value>` 行を検出し、value 部を stdout に
# 出力する（Partial Status Gate / #148）。
#
# 戻り値:
#   0 = STATUS 行検出（stdout に値を出力。値の妥当性チェックは呼出側責務）
#   1 = STATUS 行不在（既存 complete fallback / NFR 1.1）
#   2 = ファイル不在
#
# 規約（design.md 「Service Interface」/ Req 1.1, 1.2, 1.3 / NFR 3.2）:
#   - regex は `^STATUS: (.+)$`（行頭固定、半角コロン + 半角スペース + 任意 value 文字列）
#   - インデント / list marker `- ` / 引用 `> ` / バッククォートの prefix は **検出対象外**
#   - 複数マッチ時は **最終行** を採用（Developer 再実行で上書きされた場合に新しい値を採用）
#   - 値は前後の空白を trim
#   - status 値の正規化（complete / partial_blocked / partial_overrun / 不正）は呼出側
#     （handle_partial_status）の責務（テスト容易性のため本関数では raw 値を返す）
#
# Requirements: 1.1, 1.2, 1.3, NFR 1.1, NFR 3.2
detect_partial_status() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 2
  fi
  local line
  # grep -E で行頭固定マッチ。`tail -n 1` で複数マッチ時は最終行採用（detect_blocked_marker
  # との違い: BLOCKED は 1 行目採用 / STATUS は最終行採用 = 再実行で上書きされた新しい値を優先）。
  # set -euo pipefail 配下では grep no-match で関数全体が止まるため `|| true` で吸収。
  line=$(grep -E '^STATUS: .+$' "$impl_notes" 2>/dev/null | tail -n 1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  # 先頭 `STATUS: `（8 文字）を剥がして value のみ取り出す。
  local value="${line#STATUS: }"
  # 前後の空白を trim（POSIX 互換: ${var#"..."} / ${var%"..."} で extglob 不要）。
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
  return 0
}

# ─── detect_debugger_already_invoked [<task_id>] ───
#
# sentinel file ベースで「当該 scope（Issue or task）で Debugger が既に 1 回起動済み」を
# 判定する。Issue 単位 / task 単位の両方に対応。
#
# 判定ロジック:
#   - Issue 単位（task_id 空 / 引数なし）: `$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md` が
#     存在すれば「起動済み」（return 0）
#   - task 単位（task_id 指定）: 上記ファイル内に `## Task <task_id>` セクション見出しが
#     存在すれば「起動済み」（grep で行頭マッチ）
#   - 未起動時は return 1（呼び出し側が run_debugger_stage を起動可能）
#
# 既存 commit に乗っている sentinel は impl-resume 経由の pickup 再開でも観測可能（Req 5.5）。
#
# Requirements: 5.1, 5.2, 5.5, 6.3, 6.4
# shellcheck disable=SC2120  # task_id は意図的に optional（Issue 単位起動時は引数なしで呼ぶ / Req 6.4）
detect_debugger_already_invoked() {
  local task_id="${1:-}"
  local sentinel="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
  if [ ! -f "$sentinel" ]; then
    return 1
  fi
  if [ -z "$task_id" ]; then
    # Issue 単位: ファイル存在で「起動済み」
    return 0
  fi
  # task 単位: `## Task <id>` 見出しの存在で判定（行頭固定マッチ）。
  if grep -qE "^## Task ${task_id}\$" "$sentinel" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─── validate_debugger_notes <debugger_notes_path> [<task_id>] ───
#
# Debugger 終了後、`debugger-notes.md` の必須セクション 4 つが存在するかを grep で verify する。
#
# 必須セクション:
#   - Issue 単位（task_id 空 / 引数なし）: `## 根本原因` / `## 修正手順` / `## 検証方法` / `## 関連参考資料`
#   - Phase 2 有効時（task_id 指定）: `## Task <id>` 配下に
#     `### 根本原因` / `### 修正手順` / `### 検証方法` / `### 関連参考資料`
#
# 1 つでも欠落していたら return 1（呼び出し側は claude-failed）。ファイル不在時も return 1。
#
# Requirements: 2.3, 3.6, 4.3
validate_debugger_notes() {
  local notes_path="$1"
  local task_id="${2:-}"
  if [ ! -f "$notes_path" ]; then
    return 1
  fi
  local prefix sec
  if [ -z "$task_id" ]; then
    prefix="## "
  else
    # task 単位は h2 `## Task <id>` の存在を前提に h3 4 つを verify
    if ! grep -qE "^## Task ${task_id}\$" "$notes_path" 2>/dev/null; then
      return 1
    fi
    prefix="### "
  fi
  for sec in "根本原因" "修正手順" "検証方法" "関連参考資料"; do
    if ! grep -qF "${prefix}${sec}" "$notes_path" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

# ─── build_debugger_prompt <trigger> [<task_id>] [<review_notes_path>] ───
#
# Debugger 起動用 prompt を組み立てて stdout に出力。trigger / task_id / review-notes 有無
# に応じて入力対象を切り替える。既存 `build_reviewer_prompt` の heredoc 形式を踏襲。
#
# 引数:
#   $1 = trigger ∈ {round2-reject | blocked}
#   $2 = task_id (空文字なら Issue 単位 / Phase 2 有効時のみ指定)
#   $3 = review_notes_path (trigger=round2-reject のみ、BLOCKED 時は空文字)
#
# Requirements: 2.2, 2.4, 2.5, 6.5
build_debugger_prompt() {
  local trigger="$1"
  local task_id="${2:-}"
  local review_notes_path="${3:-}"

  local trigger_label
  case "$trigger" in
    round2-reject) trigger_label="Reviewer Round 2 reject 直前" ;;
    blocked)       trigger_label="Developer BLOCKED 宣言経路" ;;
    *)             trigger_label="(unknown trigger: ${trigger})" ;;
  esac

  local task_block
  if [ -n "$task_id" ]; then
    task_block=$(cat <<EOF
## 対象 task（Phase 2 per-task loop 有効時）

- **対象 task ID**: \`${task_id}\`
- 本起動では \`tasks.md\` の **task ${task_id} 1 件の \`_Requirements:_\` で列挙された AC のみ** を verify 対象としてください
- 他 task の context は参照しないこと（task 単位の独立性 / Req 6.5）
- \`git diff\` / \`git log\` は当該 task の \`docs(tasks): mark ${task_id} as done\` commit 範囲のみを対象に絞り込むこと
- \`debugger-notes.md\` 出力時は **既存ファイルの末尾に append**: \`## Task ${task_id}\` 見出しを追加し、その配下に h3 4 セクション
EOF
)
  else
    task_block=$(cat <<EOF
## 対象 scope

- 本起動は **Issue 単位** で起動されています（Phase 2 per-task loop 無効）
- \`tasks.md\` 全体 / \`requirements.md\` の全 AC を verify 対象としてください
- \`debugger-notes.md\` は新規作成: h1 \`# Debugger Notes (Issue #${NUMBER})\` + h2 4 セクション
EOF
)
  fi

  local review_notes_block
  case "$trigger" in
    round2-reject)
      if [ -n "$review_notes_path" ] && [ -f "$review_notes_path" ]; then
        review_notes_block=$(cat <<EOF
## Reviewer の reject 理由（review-notes.md より）

Round 2 reject の経路です。以下の \`review-notes.md\` の Findings を **重点的に** 参照し、
Developer の差し戻し 1 回（Stage A'）でも解消できなかった根本原因を特定してください。

\`\`\`markdown
$(cat "$review_notes_path")
\`\`\`
EOF
)
      else
        review_notes_block="## Reviewer の reject 理由

（\`review-notes.md\` が見つかりませんでした: \`${review_notes_path}\`。\`gh issue view ${NUMBER}\`
や \`$LOG\` を Bash で参照して reject 理由を推定してください）"
      fi
      ;;
    blocked)
      review_notes_block=$(cat <<EOF
## Developer の BLOCKED 宣言

本起動は \`impl-notes.md\` の行頭 \`BLOCKED: <reason>\` 検出経路です。
Reviewer 経由ではないため \`review-notes.md\` は無し / 古い内容のままです（参照不要）。

\`impl-notes.md\` の \`BLOCKED:\` 行を **重点的に** 参照し、Developer が「自身の context では原因究明
不可能」と判断した具体的な疑問点（試したこと / 不明点 / 推奨される web search 観点）を起点に
root cause を分析してください。
EOF
)
      ;;
    *)
      review_notes_block="## トリガー識別不能

（trigger 値 \`${trigger}\` が想定外です。\`gh issue view ${NUMBER}\` で状況を確認してください）"
      ;;
  esac

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **Debugger Gate**（DEBUGGER_ENABLED=true）の下で、${trigger_label}に
fresh な Claude CLI セッションで起動されました。

あなたの **唯一の責務** は、対象 Issue / task の **root cause 分析と Fix Plan markdown 出力** です。
コード / spec / ラベル / commit / PR の改変は一切行わないでください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- TRIGGER      : ${trigger}
- TASK_ID      : ${task_id:-(none / Issue 単位)}

${task_block}

${review_notes_block}

## 必読ファイル

debugger サブエージェントを起動し、以下を **必ず** Read してください:

- \`CLAUDE.md\`（プロジェクト憲章）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（特に対象 task の \`_Requirements:_\` / \`_Boundary:_\`）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
$( [ "$trigger" = "round2-reject" ] && echo "- \`${SPEC_DIR_REL}/review-notes.md\`（Reviewer の Findings）" )

## 差分の取得（Bash で実行）

prompt には差分本文を埋め込みません。Bash ツールで以下を実行して取得してください:

\`\`\`bash
git diff --stat ${BASE_BRANCH}..HEAD
git log --oneline ${BASE_BRANCH}..HEAD
git diff ${BASE_BRANCH}..HEAD -- <path>   # 必要に応じてファイル単位
\`\`\`

## web search の活用

外部知識が必要な原因分析には WebSearch / WebFetch を活用してください:

- 外部ライブラリの ABI / API 仕様 / breaking changes
- フレームワーク内部の挙動 / known issue / GitHub issues
- CI / 実行環境固有の制約（OS / runtime version）
- ベンダー公式ドキュメント / changelog

検索した URL とタイトル / 要約は \`## 関連参考資料\` セクションに \`[n]\` 形式で番号付け参照
してください。

## 出力先と必須セクション

出力先: \`${SPEC_DIR_REL}/debugger-notes.md\`（**追記モード**）

必須セクション（watcher が grep で verify します。1 つでも欠落すると claude-failed になります）:

$( if [ -z "$task_id" ]; then
cat <<INNER
- \`## 根本原因\`
- \`## 修正手順\`
- \`## 検証方法\`
- \`## 関連参考資料\`
INNER
else
cat <<INNER
- \`## Task ${task_id}\`（既存ファイル末尾に append、既存セクションは改変しない）
  - \`### 根本原因\`
  - \`### 修正手順\`
  - \`### 検証方法\`
  - \`### 関連参考資料\`
INNER
fi )

見出し文字列は **厳密に上記の 4 語**（日本語）です。\`## 原因\` や \`## Fix Plan\` 等の言い換え
は不可（watcher の verify が失敗します）。

## 禁止事項（やってはいけないこと）

- コードファイル（実装 / テスト）を Edit / Write しない
- spec md（\`requirements.md\` / \`design.md\` / \`tasks.md\` / \`review-notes.md\`）を Edit / Write しない
- ラベル付け替え（\`gh issue edit\` / \`gh pr edit\`）を行わない
- commit / push（\`git add\` / \`git commit\` / \`git push\`）を行わない
- PR 作成 / コメント投稿（\`gh pr create\` / \`gh issue comment\` 等）を行わない
- \`approve\` / \`reject\` 等の判定文字列を出力しない（Reviewer の責務）
- 他エージェント（PM / Architect / Developer / Reviewer / PjM）の役割を兼任しない
- \`debugger-notes.md\` 以外への Write
- 既存 \`### Task <id>\` セクションの改変 / 削除 / 並び替え（task 単位の append のみ許可）

## 進め方

1. 必読ファイルを順に Read
2. Bash で \`git diff\` / \`git log\` を実行して実装差分を全体把握
3. trigger に応じた手がかり（review-notes.md の Findings / impl-notes.md の BLOCKED 行）から問題箇所を特定
4. 必要に応じて WebSearch / WebFetch で外部知識を収集
5. 根本原因を 1 つに絞り込む
6. 具体的な修正手順を Developer が機械的に実施できる粒度で書く
7. 検証方法（テストコマンド / 期待挙動）を明示
8. \`debugger-notes.md\` を上記フォーマットで Write（追記モード）して終了
EOF
}

# ─── run_debugger_stage <trigger> [<task_id>] [<review_notes_path>] ───
#
# fresh Claude CLI セッションで Debugger を 1 回起動し、`debugger-notes.md` の存在 /
# 必須セクション形式を verify する。既存 `run_reviewer_stage` と同形（独立 context）。
#
# 引数:
#   $1 = trigger ∈ {round2-reject | blocked}
#   $2 = task_id (空文字なら Issue 単位)
#   $3 = review_notes_path (trigger=round2-reject のみ)
#
# 戻り値:
#   0   = Debugger 正常終了 + debugger-notes.md 形式 verify 成功（呼び出し側は Stage A''/A' を起動）
#   1   = claude 非 0 exit / debugger-notes.md 不在 / 必須セクション欠落
#         （呼び出し側で mark_issue_failed → return 1）
#   99  = quota 超過（呼び出し側で needs-quota-wait 退避）
#
# Requirements: 2.6, 3.6, 7.4, NFR 2.1, NFR 2.2, NFR 2.3, NFR 5.1
run_debugger_stage() {
  local trigger="$1"
  local task_id="${2:-}"
  local review_notes_path="${3:-}"

  local notes_path="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
  local task_label="${task_id:-none}"

  dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} start (model=$DEBUGGER_MODEL, max-turns=$DEBUGGER_MAX_TURNS)" >> "$LOG"
  echo "--- Debugger 実行 (trigger=$trigger, task=${task_label}) ---" >> "$LOG"

  local prompt
  prompt=$(build_debugger_prompt "$trigger" "$task_id" "$review_notes_path")

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-debugger-${trigger}-${task_label}-${_qa_ts}"
  _qa_stage_label="Debugger-${trigger}-${task_label}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$DEBUGGER_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEBUGGER_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      "${CLAUDE_HOOK_ARGS[@]}" \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=0" >> "$LOG"
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=99 result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=$_qa_rc result=error" >> "$LOG"
      mark_issue_failed "debugger-failed" "Debugger サブエージェント（trigger=\`${trigger}\`, task=\`${task_label}\`）が非 0 exit で異常終了しました（claude rc=${_qa_rc}）。Stage A'' / Stage A' / Stage B'' / Round 3 は実行されません。\`$LOG\` の Debugger 実行ログを確認してください。"
      return 1
      ;;
  esac

  # debugger-notes.md の必須セクション verify
  if ! validate_debugger_notes "$notes_path" "$task_id"; then
    dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} debugger-notes.md validation failed" >> "$LOG"
    publish_terminal_failure_artifacts "debugger-notes-invalid" "Debugger が \`${SPEC_DIR_REL}/debugger-notes.md\` を期待形式で出力しませんでした（必須 4 セクション \`根本原因\` / \`修正手順\` / \`検証方法\` / \`関連参考資料\` のいずれかが欠落、もしくはファイル自体が不在）。\`$LOG\` の Debugger 実行ログを確認してください。"
    return 1
  fi
  dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} debugger-notes.md verified (sections=4)" >> "$LOG"
  return 0
}
