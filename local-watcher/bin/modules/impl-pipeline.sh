#!/usr/bin/env bash
# impl-pipeline.sh — Reviewer Gate / impl 系 stage 分割パイプライン モジュール（#20 Phase 1 / #463-464 切り出し）
#
# 用途:
#   `run_impl_pipeline` が impl / impl-resume モードを Stage A（PM + Developer）/ Stage B
#   （Reviewer round=1）/ Stage A'（Developer 再実行）/ Stage B'（Reviewer round=2）/ Stage C
#   （PjM = PR 作成）へ分割して駆動する際に使う stage prompt builder 群（前半 = #463）。
#   各 builder は既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲し、環境変数
#   （NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL / MODE / ARCHITECT_REASON / REPO /
#   BASE_BRANCH）と関数引数を入力に stdout へ prompt 文字列を出力する。
#
#   関数一覧（前半 = #463 / Stage prompt builders）:
#     - build_dev_prompt_a                 : Stage A prompt（既存 DEV_PROMPT から PjM 起動を除外）
#     - build_dev_prompt_redo              : Stage A' redo prompt（reject 後の Developer 是正 / PM 再起動なし）
#     - build_dev_prompt_redo_with_fix_plan: Stage A' redo prompt（Debugger fix plan 付き）
#     - build_reviewer_prompt              : Stage B Reviewer prompt（inline diff を撤廃し固定サイズ）
#     - build_dev_prompt_c                 : Stage C prompt（PjM = PR 作成）
#
#   後半（#464 / stage runner + escalation）:
#     - _assert_base_branch_resolved       : Stage C / design-review prompt 前の BASE_BRANCH 空値ガード（Req 1.5）
#     - reviewer_skip_files_match          : REVIEWER_SKIP_PATTERN 全一致判定（純粋関数 / #333）
#     - _reviewer_skip_check               : REVIEWER_SKIP_PATTERN 評価本体（自動 approve 生成 / #333）
#     - run_reviewer_stage                 : Reviewer サブエージェント 1 回起動 + RESULT 抽出
#     - publish_terminal_failure_artifacts : terminal failure 時の診断 artifact 保全ラッパー（#306）
#     - verify_pushed_or_retry             : Stage A/A'/B 完了直後の push 状態 verify + 自動リトライ（#106）
#     - verify_stagec_pr_or_retry          : Stage C 完了直後の PR 実在 verify + fallback（#108 / #110）
#     - mark_issue_failed                  : claude-failed 遷移の共通 escalation ヘルパー
#     - mark_issue_needs_decisions         : needs-decisions 遷移ヘルパー（Partial Status Gate / #148）
#     - handle_partial_status              : Partial Status Gate coordinator（#148）
#     - stage_a_verify_round1_defer        : stage-a-verify round=1 差し戻しの再 pickup 化（#219）
#     - run_impl_pipeline                  : impl / impl-resume の Stage 状態機械（前半 builder + 各 runner を駆動）
#
#   詳細: docs/specs/20-phase-1-reviewer-subagent-gate/design.md
#
# 配置先:
#   $HOME/bin/modules/impl-pipeline.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 実行時に本体グローバル（$NUMBER / $TITLE / $URL / $BODY / $BRANCH / $SPEC_DIR_REL / $MODE /
#     $ARCHITECT_REASON / $REPO / $BASE_BRANCH 等）を Slot Runner 実行時に参照（呼び出し時解決 /
#     bash 遅延束縛で loader が全 module source 後に解決）。
#   - 空値ガード `_assert_base_branch_resolved`（Req 1.5）は builder ではなく呼び出し元
#     （pipeline / design 分岐 = 本体残置）が prompt 組み立て直前に実行する契約。
#
# prefix: なし（impl pipeline 固有の非 prefix 関数 build_dev_prompt_* / build_reviewer_prompt）
#
# SC2153 disable の背景（#464 / split 起因の info 級誤検知抑止）:
#   本 module の runner / escalation 関数は大文字グローバル環境変数 `$BODY`（Issue 本文）・
#   `$MODE`（実行モード）・`$BRANCH`・`$REPO_DIR`・`$SPEC_DIR_REL`（いずれも本体 main loop /
#   Slot Runner で代入）を prompt heredoc・ログ文言・パス組み立て内で参照する。同一ファイル内の
#   別関数に小文字ローカル `mode`（build_dev_prompt_a）/ `body`（mark_issue_failed）/
#   `branch`（verify_pushed_or_retry）等が存在するため、分割前の issue-watcher.sh 単体では
#   大文字側の実代入が同一ファイルに見えて非発火だった SC2153（「typo では」）が、module 単体では
#   cross-file 可視性の喪失で新規発火する。関数移動対象自体は無改変（#455 共通規約）。
# shellcheck disable=SC2153

# Stage A: PM + Developer（impl では PM 起動、impl-resume では Developer のみ）
# 既存 DEV_PROMPT の STEPS から「PjM 起動」を除外したもの。
build_dev_prompt_a() {
  local mode="$1"
  local flow_label
  local steps

  case "$mode" in
    impl)
      flow_label="PM → Developer（Reviewer ゲート前）"
      steps=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\`
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。本ステージのゴールは impl-notes.md の保存までです。後段の Reviewer / PjM 起動・PR 作成は watcher が別ステージで行うため、本ステージでは一切起動・実行しないでください。
EOF
)
      ;;
    impl-resume)
      flow_label="Developer（Reviewer ゲート前 / 設計 PR merge 済み）"
      steps=$(cat <<EOF
1. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は設計 PR で人間レビュー済み（${BASE_BRANCH} に merge 済み）。**書き換えないこと**
   - tasks.md の numeric ID 順にタスクを消化する
   - 矛盾や疑問があれば PR 本文「確認事項」に記載（書き換えはしない）
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。本ステージのゴールは impl-notes.md の保存までです。後段の Reviewer / PjM 起動・PR 作成は watcher が別ステージで行うため、本ステージでは一切起動・実行しないでください。
EOF
)
      ;;
  esac

  # Issue #67: impl-resume + IMPL_RESUME_PRESERVE_COMMITS=true 時のみ追加注入する
  # 「resume 指示」セクションと、`IMPL_RESUME_PROGRESS_TRACKING` の値による
  # `tasks.md` 進捗マーカー更新指示の分岐。既存 prompt の Step 1 / 制約節は変更せず、
  # 末尾に節を追加するだけ（既存挙動と差分等価 / NFR 1.1）。
  #
  # `RESUME_PRESERVE` は `_resume_branch_init` が export している（Slot Runner 内）。
  # `IMPL_RESUME_PROGRESS_TRACKING` は cron / launchd 経由で渡される env 値。
  # `_resume_normalize_flag` で 2 値正規化（Req 3.6: "false" 完全一致のみ false、
  # それ以外は true）。
  local resume_section=""
  if [ "$mode" = "impl-resume" ] && [ "${RESUME_PRESERVE:-false}" = "true" ]; then
    local tracking
    tracking=$(_resume_normalize_flag tracking_default_on "${IMPL_RESUME_PROGRESS_TRACKING:-}")

    local progress_block
    if [ "$tracking" = "true" ]; then
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=true）

- 各タスクが完了した時点で `tasks.md` の対応する未完了マーカー行 `- [ ] N.M ...` を
  `- [x] N.M ...` に書き換えること
- 進捗マーカー更新は **専用 commit** として積む:
  - commit メッセージ: `docs(tasks): mark <task-id> as done`（例: `docs(tasks): mark 1.2 as done`）
  - 当該 commit には `tasks.md` 以外のファイルを含めない
- **書き換え禁止領域**: タスク本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` /
  タスク順序 / 親タスクのインデント / deferrable 印 `- [ ]*`（アスタリスク付き）
- 親タスク（例: `- [ ] 1.`）は、その配下の全子タスクが `- [x]` になったタイミングで親側も
  `- [x]` に更新する（deferrable 子タスク `- [ ]*` は未完了のまま親完了を判定可能）
- すべてのタスクが完了済み（未完了マーカー `- [ ]` が残っていない）なら、追加実装を行わず
  impl-notes.md にその旨を記録すること
EOF
)
    else
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=false）

- 本サイクルでは `tasks.md` の進捗マーカー（`- [ ]` ↔ `- [x]`）を **書き換えない**
- 通常通り numeric ID 順にタスクを消化し、impl-notes.md に進捗の根拠を記録する
EOF
)
    fi

    resume_section=$(cat <<EOF

## 既存 commit からの resume（IMPL_RESUME_PRESERVE_COMMITS=true）

このサイクルは **既存の作業ブランチからの resume** で起動されました。
worktree は \`origin/${BASE_BRANCH}\` から fresh init されておらず、\`origin/${BRANCH}\` の先端から
checkout されています。**過去 Developer / 人間が積んだ commit を温存してください**。

- 作業前に必ず \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 未完了タスクの判定基準: \`tasks.md\` の \`- [ ]\` 行（未完了マーカー）の先頭から再開
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積む
  か、impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ

${progress_block}
EOF
)
  fi

  cat <<EOF
あなたは Stage A（PM + Developer）担当のサブオーケストレーターです。本ステージの責務は PM 要件定義と Developer 実装・コミットに限定されます。
以下の Issue を ${flow_label} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方
${steps}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（次の Reviewer ステージで独立レビューを受けます）
- **reviewer / project-manager サブエージェントを起動しないこと**（後段ステージで watcher が起動します）
${resume_section}
EOF
}

# Stage A' (Developer 再実行用): Reviewer reject の Findings を inline で渡し、
# Developer に是正を依頼する。PM は再起動しない（要件は不変）。
build_dev_prompt_redo() {
  local review_notes_path="$1"
  local review_notes_content
  if [ -f "$review_notes_path" ]; then
    review_notes_content=$(cat "$review_notes_path")
  else
    review_notes_content="(review-notes.md が見つかりません)"
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
直前の Reviewer サブエージェントが reject を出したため、Developer の再実装を依頼します。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`

## 進め方

1. developer サブエージェントを起動し、上記 Findings の **Required Action** を順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後 \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- product-manager / project-manager サブエージェントは起動しないこと
  （PM は不要、PjM は次の Reviewer round=2 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
EOF
}

# Stage A' / A'' (Debugger 経由 Developer 再実行): Debugger Gate (#22 Phase 3) で
# 生成された `debugger-notes.md` の Fix Plan を inline 注入して Developer 再起動を依頼する。
# 既存 `build_dev_prompt_redo` の heredoc 形式を踏襲し、review-notes.md は trigger が
# `round2-reject` の場合のみ埋め込む（BLOCKED 経路では review-notes.md は無い / 古いため
# 「(Reviewer 経由ではないため review-notes.md は無し)」と明示）。
#
# Requirements: 3.2, 4.3
build_dev_prompt_redo_with_fix_plan() {
  local review_notes_path="$1"
  local debugger_notes_path="$2"

  local debugger_notes_content
  if [ -f "$debugger_notes_path" ]; then
    debugger_notes_content=$(cat "$debugger_notes_path")
  else
    debugger_notes_content="(debugger-notes.md が見つかりません: $debugger_notes_path)"
  fi

  local review_notes_block
  if [ -n "$review_notes_path" ] && [ -f "$review_notes_path" ]; then
    local review_notes_content
    review_notes_content=$(cat "$review_notes_path")
    review_notes_block=$(cat <<EOF
## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`
EOF
)
  else
    review_notes_block=$(cat <<'EOF'
## Reviewer の reject 理由

(Reviewer 経由ではないため review-notes.md は無し / 古い内容のままです。BLOCKED 経路で起動された
Debugger の Fix Plan を起点に是正を進めてください)
EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
直前の Debugger サブエージェント（Phase 3 / #22）が \`debugger-notes.md\` に Fix Plan を
出力しました。本 Fix Plan を起点に Developer の再実装を依頼します。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

${review_notes_block}

## Debugger の Fix Plan（debugger-notes.md より）

\`\`\`markdown
${debugger_notes_content}
\`\`\`

## 進め方

1. developer サブエージェントを起動し、Debugger の Fix Plan に記載された **\`修正手順\`** を
   順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後に Fix Plan の **\`検証方法\`** に従って挙動確認を実行する（テストコマンド / 期待挙動）
3. \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記する（Debugger 経由再実行で
   実施したこと / 残課題があれば記載）

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- product-manager / project-manager サブエージェントは起動しないこと
  （PM は不要、PjM は次の Reviewer round=3 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
- \`debugger-notes.md\` は **書き換えないこと**（Debugger の Fix Plan は記録として残す）
- requirements.md / design.md / tasks.md / review-notes.md は書き換えないこと（既存契約）
EOF
}

# Stage B (Reviewer): reviewer agent 定義（.claude/agents/reviewer.md）を `--agent reviewer`
# でトップレベルセッションとして直接実行し、review-notes.md を書かせる（#329 フラット化。
# 従来はオーケストレーターセッションが reviewer サブエージェントを Task 起動する 2 層構成
# だった。独立性はプロセス分離で担保されるため契約は不変）。差分は reviewer 自身が Bash
# ツールで取得する設計（Issue #92: 大規模差分時の `Argument list too long` 回避のため、
# prompt から inline diff 全文を撤廃した）。prompt は差分サイズに依存せず固定サイズに収まる。
build_reviewer_prompt() {
  local round="$1"
  local prev_result="$2"   # round=2 のみ意味あり、round=1 は "(none)"
  local head_sha
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")

  cat <<EOF
あなたは reviewer（独立レビューゲート）として起動されています。
Developer の実装が一段落したため、**独立レビュー**（round=${round} / 最大 2 round）を
実施してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- HEAD commit  : ${head_sha}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 必読ファイル

着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（\`_Requirements:_\` / \`_Boundary:_\` アノテーション）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

prompt には差分本文を埋め込みません（Issue #92: 大差分時の \`Argument list too long\`
回避のため）。着手直後に **Bash ツールで** 以下を実行し、
全体把握 → 必要箇所のファイル単位詳細の順で差分を取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${BASE_BRANCH}..HEAD
   git log --oneline ${BASE_BRANCH}..HEAD
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${BASE_BRANCH}..HEAD -- <path>
   \`\`\`
3. 差分が空または取得できなかった場合は、その旨を review-notes.md の Summary に明記し、
   AC カバレッジ判定は requirements.md と既存コードの突き合わせで行ってください。

## 進め方

以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（あなたのシステムプロンプト = reviewer.md の出力契約に従う）。

- 判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 つに限定
- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと（review-notes.md は次の
  Developer または PjM が commit します）
- スタイル / 命名 / lint / フォーマットの観点での reject はしないこと
EOF
}

# Stage C (PjM): project-manager agent 定義（.claude/agents/project-manager.md）を
# `--agent project-manager` でトップレベルセッションとして直接実行し、最終 PR を作成させる
# （#329 フラット化。従来はオーケストレーターセッションが PjM サブエージェントを Task 起動
# する 2 層構成だった）。PR 本文の構造は本機能導入前と等価（要件 6.5）。
#
# Issue #96: PjM への PR 作成指示に、解決済み BASE_BRANCH の **実値** を `--base` 引数として
# 明示する肯定的な指示を含める（Req 1.1, 2.1, 2.2）。プレースホルダ `<BASE_BRANCH>` ではなく、
# 当該サイクルで watcher が解決した BASE_BRANCH 値そのもの（`${BASE_BRANCH}` を heredoc で
# 展開済みの文字列）を埋め込む。空値ガード（Req 1.5）は呼び出し元 `_assert_base_branch_resolved`
# で行う。
build_dev_prompt_c() {
  local mode="$1"
  local design_pr_note=""
  if [ "$mode" = "impl-resume" ]; then
    design_pr_note="   - PR 本文に対応する設計 PR 番号を記載（直近の ${BASE_BRANCH} 上の merge commit から \`git log --oneline --merges\` で探す）"
  else
    design_pr_note='   - 設計 PR は走っていないため「関連 PR: なし」と明記すること'
  fi

  cat <<EOF
あなたは project-manager（**implementation モード**）として起動されています。
Developer の実装と Reviewer の独立レビュー（approve）が完了したため、最終 PR を作成してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（実装 commit が積まれた状態。push 済み）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

\`gh pr create\` 実行時に **必ず \`--base ${BASE_BRANCH}\`** を
明示してください（GitHub のデフォルト base に依存しないこと）。これは本サイクル開始時に
watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダではありません。
PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で取得した値が
\`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方

1. \`${SPEC_DIR_REL}/review-notes.md\` を **本ブランチに git add / git commit** してから push する
   - commit メッセージ: \`docs(review): add reviewer notes for #${NUMBER}\`
   - 既に commit 済みなら skip
2. **implementation モード**の規約（あなたのシステムプロンプト = project-manager.md）に従って PR を作成
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を明示すること）
   - PR 本文は project-manager.md の「実装 PR 本文テンプレート」に従う
${design_pr_note}
   - PR 本文の「確認事項」セクションに、必要なら review-notes.md の参照リンクを 1 行記載
   - Issue ラベル: claude-picked-up → ready-for-review に付け替え
   - Issue にコメントで実装 PR リンクを投稿

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- Reviewer の approve 判定を覆さないこと（PR 本文に判定結果を逐語転載しない。review-notes.md の
  参照に留める）
- 仕様変更や追加実装はしないこと（PjM はコードを変更しない）
EOF
}

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
