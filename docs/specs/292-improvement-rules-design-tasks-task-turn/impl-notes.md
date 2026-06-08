# Implementation Notes — #292

## 概要

Architect の自己レビューゲートに「Task turn 予算 sanity check（過大 task 検出）」の **観点
（指針レベル）** を追加する design-less impl。`design-review-gate.md` 本体に新節を 1 つ追加し、
`tasks-generation.md` の既存「turn 予算ガイドライン」節からの相互参照を 1 サブ節として追記
した。root と `repo-template/` の二系統に byte 一致で反映済み。

## 変更ファイル一覧

- `.claude/rules/design-review-gate.md` — 新節「Task turn 予算 sanity check（過大 task 検出）」を
  「実行可能性レビュー」節の **直後**かつ「Mechanical Checks」節の **手前** に追加（判断レビュー側）
- `.claude/rules/tasks-generation.md` — 既存「turn 予算ガイドライン」節の末尾に
  「Architect 自己レビュー時の検出観点との相互参照（#292）」サブ節を追加
- `repo-template/.claude/rules/design-review-gate.md` — root と byte 一致
- `repo-template/.claude/rules/tasks-generation.md` — root と byte 一致

`diff --stat` 結果（参考）:

```
.claude/rules/design-review-gate.md               | 96 +++++++++++++++++++++++
.claude/rules/tasks-generation.md                 | 10 +++
repo-template/.claude/rules/design-review-gate.md | 96 +++++++++++++++++++++++
repo-template/.claude/rules/tasks-generation.md   | 10 +++
4 files changed, 212 insertions(+)
```

**insertions のみ、deletions = 0**。既存節の本文は 1 文字も変更していない。

## 追加内容のサマリ

### `design-review-gate.md` 側の新節

節名: `## Task turn 予算 sanity check（過大 task 検出）`

構成:

- 冒頭: 推奨レベルである旨と、`tasks-generation.md` の turn 予算ガイドラインとの役割分担を明示
- 「背景: 層対称分割の落とし穴」サブ節
- 「検出シグナル」サブ節（5 件、Req 2.1〜2.5 に対応）
  1. 異種責務の同居 (API クライアント lib + 複数 component 等)
  2. 兄弟比突出 (詳細項目数 / 想定新規ファイル数)
  3. 新規ファイル件数の目安 (目安として 3 件以上)
  4. 重い子タスクの同居 (最上位 task への昇格を検討)
  5. turn コスト密度差 (frontend > backend)
- 「是正方針: 責務不変の粒度分割」サブ節
- 「Mechanical Checks 節に含めない理由」サブ節
- 「既存規約との関係」サブ節（`tasks-generation.md` との役割分担 / レビュー・ループ / Mechanical
  Checks 不変 / retrofit 不要を明示）
- 「適用タイミング」サブ節

### `tasks-generation.md` 側の相互参照

「強度（推奨どまり / Mechanical Check 不在）」サブ節と「構造化 verify ブロック」節の間に、新規
サブ節「Architect 自己レビュー時の検出観点との相互参照（#292）」を 1 つ挿入。`design-review-gate.md`
側の新節へリンクを張る記述で完結。

## Requirements 達成確認

| Req ID | 内容 | 達成箇所 |
|---|---|---|
| 1.1 | `design-review-gate.md` に sanity check の節 / 箇条書きを 1 つ以上 | 新節「Task turn 予算 sanity check（過大 task 検出）」 |
| 1.2 | `tasks-generation.md` の turn 予算ガイドライン節と相互参照 | 「Architect 自己レビュー時の検出観点との相互参照（#292）」サブ節 |
| 1.3 | 既存 Mechanical Checks を削除・改変しない | git diff: deletions=0 / 該当節本文は無変更 |
| 1.4 | 「最大 2 パス」/ `/goal` 自動ループ節を変更しない | 「レビュー・ループ」「`/goal` による自動ループ運用」節は無変更 |
| 1.5 | 判断レビュー側（または独立節）への配置 | 「実行可能性レビュー」と「Mechanical Checks」の間に独立節として配置 |
| 2.1 | API クライアント + 複数 component 等の異種責務同居 | 検出シグナル #1 |
| 2.2 | 兄弟比 / 詳細項目数 / 新規ファイル数の突出 | 検出シグナル #2 |
| 2.3 | 新規ファイル数 3 件以上の目安 | 検出シグナル #3 |
| 2.4 | 重い子タスクの同居 → 最上位昇格 | 検出シグナル #4 |
| 2.5 | frontend > backend の turn コスト密度 | 検出シグナル #5 + 「背景」サブ節 |
| 3.1 | 推奨（指針）レベル / reject 条件として宣言しない | 冒頭で明示、「Mechanical Checks 節に含めない理由」で補強 |
| 3.2 | Mechanical Checks 節には追加しない | 新節は Mechanical Checks の **手前**（判断レビュー側）に配置 |
| 3.3 | 数値閾値は「目安」と明示 | 「目安として 3 件以上」「目安」と明記、絶対閾値としては運用しないと明記 |
| 3.4 | 該当時の Architect の振る舞い | 冒頭「分割または最上位昇格を **検討** し判断結果を design.md / tasks.md に反映」と明記 |
| 3.5 | watcher / agent コードの挙動変更を伴わない | 追記は markdown のみ。`local-watcher/` および `.claude/agents/` は無変更 |
| 4.1 | `design-review-gate.md` の両系統 byte 一致 | `cp` で複製、`diff -r` で確認済 |
| 4.2 | `tasks-generation.md` の両系統 byte 一致 | `cp` で複製、`diff -r` で確認済 |
| 4.3 | `diff -r .claude/rules repo-template/.claude/rules` が空 | 確認済（"RULES DIFF CLEAN AFTER COPY"） |
| 4.4 | 片系統だけの更新を許容しない | 両系統に同時反映済 |
| 4.5 | `repo-template/CLAUDE.md` のエージェント参照ルール一覧を変更しない | 無変更 |
| 5.1 | Mechanical Checks 既存判定基準を変更しない | Budget overflow / checkbox enforcement / verify well-formed 節は無変更 |
| 5.2 | 既存 traceability 規約を変更しない | requirements.md / design.md / tasks.md の関係は無変更 |
| 5.3 | 最大 2 パス / `/goal` 自動ループ手順を変更しない | 該当節は無変更 |
| 5.4 | merge 済み spec への retrofit 不要 | 「既存規約との関係」サブ節で明記 |
| 5.5 | env 変数名 / ラベル名 / 既定値の意味を変更しない | `DEV_MAX_TURNS` の意味・既定値 60 への言及はあるが変更なし |
| 6.1 | #289 の `tasks-generation.md` 節を削除・改変しない | git diff: 既存サブ節（fresh session / 粒度指針 / 強度）は無変更、insertions のみ |
| 6.2 | #289 と差別化し、検出観点を補う形で記述 | `design-review-gate.md` 側は「自己レビュー時の検出観点」、`tasks-generation.md` 側は「タスク生成段階の粒度指針」と役割分担を明示 |
| 6.3 | 両節間の相互リンク | `tasks-generation.md` → `design-review-gate.md` のリンクを新サブ節で、`design-review-gate.md` → `tasks-generation.md` のリンクを「既存規約との関係」サブ節および冒頭で配置 |
| 6.4 | README / QUICK-HOWTO を変更しない | 無変更 |
| NFR 1.1 | h2 / h3 階層を破壊しない | 新節を h2、サブ節を h3 で追加（既存スタイル踏襲） |
| NFR 1.2 | 日本語ベース | EARS / env / ラベル名以外は日本語で記述 |
| NFR 1.3 | 既存 Mechanical Checks と語彙・記述スタイルを揃える | 既存節と同様の構成（サブ節での詳細化、関連節への相互リンク） |
| NFR 2.1 | 2 ホップ以内で到達できる目次配置 | `design-review-gate.md` の h2 直下（1 ホップ）に配置 |
| NFR 2.2 | `tasks-generation.md` 「turn 予算ガイドライン」から 1 ホップ | 同節末尾のサブ節からリンク |
| NFR 2.3 | 検索キーワード（`turn 予算` / `過大 task` / `sanity check`）を含む | 節名「Task turn 予算 sanity check（過大 task 検出）」がすべて含む |
| NFR 3.1 | watcher / agent / install / GHA の挙動変更なし | markdown のみの変更 |
| NFR 3.2 | Claude Code v2.1.139 未満含む後方互換 | 既存後方互換規約を踏襲 |

## 確認事項（人間レビュー向け）

- 新節の配置位置を「実行可能性レビュー」直後 / 「Mechanical Checks」手前としたが、別案として
  「レビュー・ループ」節の手前（Mechanical Checks 後）に置くことも検討可能。判断レビュー側
  という位置付け（Req 1.5）には現案がより整合する
- 検出シグナル #3 の「目安として 3 件以上」という具体数値は、Open Question (b) の暫定方針
  どおり requirements.md の Req 2.3 に基づいて採用。文中で「**目安** であり絶対閾値として
  運用しない」と緩めている
- 特定 repo の事例引用（ab-extweb 等）は本文に含めず、汎用的な事例（「API クライアント lib +
  複数 component」）で言及するに留めた（requirements.md Out of Scope と整合）

## 検証結果

- `diff -r .claude/rules repo-template/.claude/rules` → exit 0（差分なし）
- `git diff --stat .claude/rules repo-template/.claude/rules` → 4 files changed, 212
  insertions(+), 0 deletions(-)（既存節の本文は無変更を担保）
- 既存 Mechanical Checks（Budget overflow / checkbox enforcement / verify block well-formed）の
  判定基準セクションは git diff 上で改変ゼロ
- 既存「turn 予算ガイドライン（per-task Implementer ループ運用時の粒度指針）」「構造化 verify
  ブロック」節は git diff 上で改変ゼロ（追加サブ節は既存サブ節末尾と新節の間に挿入）

STATUS: complete
