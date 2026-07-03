#!/usr/bin/env bash
# impl-pipeline-prompt.sh — impl pipeline の Stage prompt builders
#
# family: impl-pipeline / prefix: なし（#501 で impl-pipeline.sh から分割。family マニフェストは
#   impl-pipeline.sh 冒頭ヘッダを参照）
#
# 用途:
#   impl / impl-resume モードの各 Stage で Developer / PjM subagent に渡す prompt 本文を
#   heredoc で組み立てる。既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲し、
#   環境変数（NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL / MODE / ARCHITECT_REASON /
#   REPO / BASE_BRANCH）と関数引数を入力に stdout へ prompt 文字列を出力する。
#   - build_dev_prompt_a                 : Stage A prompt（既存 DEV_PROMPT から PjM 起動を除外）
#   - build_dev_prompt_redo              : Stage A' redo prompt（reject 後の Developer 是正 / PM 再起動なし）
#   - build_dev_prompt_redo_with_fix_plan: Stage A' redo prompt（Debugger fix plan 付き）
#   - build_reviewer_prompt              : Stage B Reviewer prompt（inline diff を撤廃し固定サイズ）
#   - build_dev_prompt_c                 : Stage C prompt（PjM = PR 作成）
#
# 配置先:
#   $HOME/bin/modules/impl-pipeline-prompt.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - impl-pipeline.sh（orchestrator）の run_impl_pipeline から呼ばれる（遅延束縛）。
#   - グローバル変数（$NUMBER / $TITLE / $URL / $BODY / $BRANCH / $SPEC_DIR_REL / $MODE /
#     $ARCHITECT_REASON / $REPO / $BASE_BRANCH 等）は watcher-config.sh / 本体 main loop。
#   - 外部 CLI: なし（純粋な文字列組み立て）。

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
