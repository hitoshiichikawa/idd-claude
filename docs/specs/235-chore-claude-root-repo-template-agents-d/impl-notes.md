# Implementation Notes — #235 root↔repo-template 4 agent reconciliation

design レス（tasks.md 無し）で直接実装。root `.claude/agents/` と
`repo-template/.claude/agents/` の 4 agent（developer / reviewer / project-manager /
product-manager）を byte 一致に reconciliation した。

## 各 agent の diff 3 カテゴリ分析結果

カテゴリ凡例:

- **(A) パラメータ化差異**: root `main..HEAD` ⇔ template `<BASE_BRANCH>`（実コンテンツの差ではない）
- **(B) template 固有節**: template にあって root に無い実コンテンツ → 最終形に含める
- **(C) root 固有節**: root にあって template に無い実コンテンツ → 絶対に失わない

### developer.md（root 固有節 C **あり**）

最も注意を要したファイル。`git log` で両系統が共通祖先 `38db7a6`（#155 STATUS 行追加）
まで同一履歴を持ち、その後に **双方向ドリフト** が発生していたことを確認した:

- **root 側のみ**: `7d8f034`（#133「checkbox 必須規約と整合」）が root にだけ適用され
  template に未伝播 → これが真の **(C) root 固有節**
- **template 側のみ**: `5ca3c74`（#21 per-task ループ節）/ `9f13cfc`（BLOCKED 規約）/
  `cd2d31d`（#164 1 commit = 1 task ID）が template にだけ適用され root に未伝播 → **(B)**

特定した **(C) root 固有節（3 点）**:

1. impl-resume 節内の「**タスク完了は checkbox 編集で表現する**」箇条書き（進捗の正本が
   checkbox であり TaskCreate/TaskUpdate・hidden marker を正本としない旨）
2. 「進捗 commit は別 commit」の補足「**（batch commit は不可。1 タスク完了 = 1 marker commit）**」
3. impl-resume 節内の「**tasks.md は checkbox 形式である前提**」箇条書き
   （design-review-gate の checkbox enforcement check 参照と、違反発見時は書き換えず
   Architect へ差し戻す旨）

**扱い**: いずれも template の最新構造（per-task / BLOCKED 節を含む superset）の対応箇所
（impl-resume 節）へマージして両系統に反映。`7d8f034` の commit 本文が「既存規約
『batch commit は不可』を明示維持」「tasks.md は checkbox 形式である前提（違反発見時は
書き換えず Architect へ差し戻し）」と明記しており、(C) であることを裏取りした。

(A)/(B) 差異:

- (A) `main..HEAD` → `<BASE_BRANCH>` 化（冒頭の design.md/tasks.md レビュー済み文言 /
  opt-in flag 節の `git diff` セルフチェック行 / impl-resume の `git log` 行 /
  「やらないこと」の直接 push 文言）
- (B) 末尾に per-task ループ節 + BLOCKED 規約節を追加。TaskCreate 節冒頭文言と
  「進捗の正本は checkbox である」節の文言を template 版（重複排除・集約済み）に整合

### reviewer.md（root 固有節 C **なし**）

差分は全て (A) パラメータ化（`main..HEAD`×6 → `<BASE_BRANCH>`、`Compared to:` ヘッダ等）と
(B) template 固有節（末尾の per-task ループ Reviewer 責務節、`<BASE_BRANCH>` 解決方法の
説明段落、flag 分岐文言の一般化「main path」→「実行パス」）のみ。root 側 `<` 行は全て
(A)/(B) に分類され、root にしか無い実コンテンツは存在しなかった。template が完全 superset
のため template 内容を root へ反映した。

### project-manager.md（root 固有節 C **なし**）

当初 root に `ee25830`（design-review STEP 3 のラベルを `claude-picked-up` →
`claude-claimed` に変更）/ `3cecd68`（PR-only iteration label）が double-drift として
残っている懸念があったため git 履歴と現物 grep で精査した。結果:

- `ee25830` の design-review STEP 3 ラベル変更（`claude-claimed`）は template にも
  `1ad05db`（mirror PjM design-review label change into repo-template）として **既に
  伝播済み**（root line 30 / template line 78 が両方 `claude-claimed`）。失われる (C) なし
- `3cecd68` の `needs-iteration` 案内は template でさらに拡張・包含されており (B) 側に内包

差分は全て (A)（`base: \`main\`` 等）+ (B)（冒頭の base ブランチ解決節、`--base
<resolved-base>` 明示と baseRefName 検証、1 PR = design or impl 節、push 文言）。
template が完全 superset のため template 内容を root へ反映した。

### product-manager.md（root 固有節 C **なし**）

差分は 1 箇所のみ（template が「Issue 依存表現の明記（canonical 記法）」節を持つ = (B)）。
base ブランチ参照は両系統 0（`main..HEAD` 不使用の agent）。root 側 `<` 行ゼロの純 superset。
root に当該節を挿入した。

## 最終形の決定根拠

- 最終形 = (B) template 固有節 + (C) root 固有節 を含み、base ブランチ参照は両系統とも
  `<BASE_BRANCH>` プレースホルダ（root に `main` を焼き込まない / Req 2）
- developer.md は (C) があるため「template を基底に (C) をマージ」する形（root を直接編集して
  (A) 解消 + (B) 取り込み、template には (C) のみ追加）で両系統を収束させた
- reviewer / project-manager / product-manager は (C) が無いため template（superset）の内容を
  root に反映するのみ（template 側は変更不要）
- architect / debugger / qa は着手前から byte 一致のため一切触れていない（Req 1.3）

## Test plan（検証 1〜6 の実行結果）

1. **`diff -r .claude/agents repo-template/.claude/agents` が空（Req 3 正本）**: PASS
   （exit 0 / `AGENTS: BYTE-IDENTICAL`）。参考として `diff -r .claude/rules
   repo-template/.claude/rules` も空（#233 で同期済み、スモーク健全性確認）
2. **architect / debugger / qa が未変更**: PASS。`git diff --stat` の変更ファイルは
   `.claude/agents/{developer,product-manager,project-manager,reviewer}.md` と
   `repo-template/.claude/agents/developer.md` の 5 ファイルのみ。architect/debugger/qa は
   両系統とも非出現
3. **base ブランチ**: PASS。`grep -n 'main\.\.HEAD' .claude/agents/*.md` が空。
   `<BASE_BRANCH>` 出現数が root/template で一致（developer 4/4、reviewer 9/9、
   project-manager 1/1、product-manager 0/0）
4. **root 固有節 (C) の保全**: PASS。developer.md 両系統で「タスク完了は checkbox 編集で
   表現する」「tasks.md は checkbox 形式である前提」「1 タスク完了 = 1 marker commit」が
   各 1 件ずつ存在
5. **markdown 構造の健全性**: PASS。各 agent は YAML frontmatter + 複数の `# ` セクション
   見出しという既存スタイルを維持（frontmatter 後の `# ` はセクション見出しであり markdown
   body の h1 重複ではない。既存全 agent 共通スタイル）。新規 h1 重複・フェンス言語タグ崩れは
   導入していない。shellcheck/actionlint は対象拡張子（.md / CLAUDE.md）が無いため該当なし
6. **`<BASE_BRANCH>` 解決前提の非破壊**: PASS。reviewer.md に `<BASE_BRANCH>` の解決方法
   （「オーケストレーターから渡される prompt の `Compared to:` ヘッダ行で実際の値を確認
   できる」/ `Compared to: <BASE_BRANCH>..HEAD`）が明記されており、root を `<BASE_BRANCH>`
   化しても orchestrator が `Compared to:` ヘッダで解決値を渡す前提と矛盾しない。idd-claude
   self-hosting で root agent を使う際も同じ解決経路で動作する

## CLAUDE.md スモーク追記（Req 4）

root の CLAUDE.md「テスト・検証」→「静的解析」節に以下 2 行を追記（既存 shellcheck /
actionlint 箇条書きと同じトーン）:

- `diff -r .claude/agents repo-template/.claude/agents` — 差分時は二重管理規約違反である旨を明示
- `diff -r .claude/rules repo-template/.claude/rules` — 同上

repo-template の CLAUDE.md（consumer 配布用）は consumer 固有内容を持ち二重管理規約の対象外。
consumer repo には root↔repo-template の二重管理構造が存在しない（consumer は配布された
単一系統のみを持つ）ため、当該スモークは consumer にとって無意味であり repo-template の
CLAUDE.md には追記しなかった（両 CLAUDE.md の byte 一致は要求されない / 要件 Out of Scope と整合）。

## 確認事項（人手レビュー観点）

本件は要人手レビュー Issue。union 判断で人間が確認すべき点:

- **(C) 判定の妥当性（developer.md）**: `7d8f034`（#133）の 3 点を root 固有節 (C) と判定し
  template の最新構造へマージした。マージ位置（impl-resume 節内、TaskCreate 節より前）と
  文言の整合（TaskCreate 節冒頭が「タスク完了 = `- [ ]` → `- [x]` の checkbox 編集」規定を
  前節として参照する形）が意図通りか確認をお願いしたい
- **project-manager の double-drift 解消の確認**: root の `ee25830`（design-review ラベルを
  `claude-claimed` に変更）が template に伝播済み（`1ad05db`）で (C) なしと判定した。
  impl モード STEP 3 のラベル削除は両系統とも `claude-picked-up` のままで一致している。
  この「design-review は `claude-claimed` / impl は `claude-picked-up`」というラベル運用の
  非対称が意図的な設計か（ラベル遷移契約の後方互換）を確認いただきたい
- **reviewer / project-manager / product-manager を template 内容で反映した点**: これら 3 つは
  (C) なしと判定し template（superset）を root に反映した。万一見落とした root 固有の挙動規約が
  あれば指摘いただきたい（diff 分析上は (A)/(B) のみで root-only 実コンテンツは検出されなかった）
- **挙動規約の不変性**: 本 PR はパラメータ化（`main..HEAD` → `<BASE_BRANCH>`）と節の union の
  みで、新判定基準・新責務は追加していない（Req 1.2 / Out of Scope）。consumer 配布物
  （repo-template）の 4 agent 機能内容は developer.md への (C) 追記を除き不変であり、その
  (C) 追記も root に既存の規約を template へ伝播したもの（root self-hosting と consumer の
  機能差を解消する方向）であるため migration note は不要と判断した（NFR 1.1 / 1.2）

STATUS: complete
