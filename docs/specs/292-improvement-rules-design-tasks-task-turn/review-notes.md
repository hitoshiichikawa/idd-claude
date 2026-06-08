# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-08T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-292-impl-improvement-rules-design-tasks-task-turn
- HEAD commit: b79898e3222d6ddafdad32ba85425f7f9531e289
- Compared to: main..HEAD
- Note: design-less impl（`design.md` / `tasks.md` 不在）。判定は requirements.md の AC と
  diff（4 files / 212 insertions / 0 deletions）の突き合わせで行う。CLAUDE.md には
  `## Feature Flag Protocol` 節が無いため flag 観点は適用外（opt-out）。

## Verified Requirements

- 1.1 — `.claude/rules/design-review-gate.md` に新節「Task turn 予算 sanity check（過大 task 検出）」を追加（diff +96 行）
- 1.2 — `.claude/rules/tasks-generation.md` の「turn 予算ガイドライン」節末尾にサブ節「Architect 自己レビュー時の検出観点との相互参照（#292）」を追加し相互参照リンク設置
- 1.3 — diff は insertions のみ（deletions=0）。Mechanical Checks 節（Requirements traceability / File Structure Plan 充填 / orphan component / Budget overflow / checkbox enforcement / verify block well-formed）の本文は無変更
- 1.4 — 「レビュー・ループ」節および `/goal` 自動ループ運用節は diff に登場せず無変更
- 1.5 — 新節は「実行可能性レビュー」直後、「Mechanical Checks」の手前に独立節として配置（判断レビュー側）
- 2.1 — 検出シグナル #1「異種責務の同居」で `API クライアント lib(+test)` / 複数 component(+test) / 状態管理 / スタイルを列挙
- 2.2 — 検出シグナル #2「兄弟比突出」で詳細項目数 / 想定新規ファイル数の兄弟比を列挙
- 2.3 — 検出シグナル #3「新規ファイル件数の目安」で「**目安として 3 件以上**」と明記
- 2.4 — 検出シグナル #4「重い子タスクの同居」で最上位 task への昇格検討を列挙
- 2.5 — 検出シグナル #5「turn コスト密度差」および「背景: 層対称分割の落とし穴」サブ節で frontend > backend の密度差を明示
- 3.1 — 冒頭で「**推奨（指針）レベル**」「reject 条件ではありません」と明示
- 3.2 — 新節は Mechanical Checks の **手前** に配置、独立サブ節「Mechanical Checks 節に含めない理由」で補強
- 3.3 — 数値は「**目安**」と明記、「絶対閾値としては運用しない」と緩めている
- 3.4 — 冒頭で「当該 task の分割または最上位昇格を **検討** し、判断結果（分割するか据え置くか）を `design.md` / `tasks.md` に反映」と明記
- 3.5 — diff に `local-watcher/` / `.claude/agents/` の変更なし（markdown 規約のみ変更）
- 4.1 — `.claude/rules/design-review-gate.md` と `repo-template/.claude/rules/design-review-gate.md` の双方に同一差分が存在
- 4.2 — `.claude/rules/tasks-generation.md` と `repo-template/.claude/rules/tasks-generation.md` の双方に同一差分が存在
- 4.3 — `diff -r .claude/rules repo-template/.claude/rules` → exit 0（"RULES DIFF CLEAN"）
- 4.4 — 両系統に同時反映済
- 4.5 — `repo-template/CLAUDE.md` は diff に登場せず無変更
- 5.1 — Budget overflow / checkbox enforcement / verify block well-formed 節は無変更（diff は新節挿入のみ）
- 5.2 — requirements.md / design.md / tasks.md の traceability 規約は無変更
- 5.3 — 「最大 2 パス」/ `/goal` 自動ループ手順は無変更
- 5.4 — 「既存規約との関係」サブ節で「既に main に merge 済みの spec への遡及的な違反検出は要求しません」と明記
- 5.5 — `DEV_MAX_TURNS`（既定 60）の言及は説明用途のみで既定値は変更されていない
- 6.1 — `tasks-generation.md` の既存サブ節（fresh session 仕様 / 粒度指針 / 強度）は無変更（insertions のみ）
- 6.2 — `design-review-gate.md` 側 = 自己レビュー検出観点、`tasks-generation.md` 側 = 生成段階の指針、と役割分担を明示
- 6.3 — `tasks-generation.md` → `design-review-gate.md` のリンクを新サブ節で、`design-review-gate.md` → `tasks-generation.md` のリンクを「既存規約との関係」で双方向設置
- 6.4 — README / QUICK-HOWTO は diff に登場せず無変更
- NFR 1.1 — h2（新節）/ h3（サブ節）の階層を既存スタイルに合わせて追加
- NFR 1.2 — 日本語ベース（識別子・env var 名・EARS キーワードのみ英語）
- NFR 1.3 — 既存 Mechanical Checks 節と同等の節構成（サブ節での詳細化 / 相互リンク）
- NFR 2.1 — `design-review-gate.md` の h2 直下（1 ホップ）に配置
- NFR 2.2 — `tasks-generation.md` 「turn 予算ガイドライン」節末尾のサブ節からリンク（1 ホップ）
- NFR 2.3 — 節名「Task turn 予算 sanity check（過大 task 検出）」が検索キーワード 3 種すべてを含む
- NFR 3.1 — markdown のみの変更。watcher / agent / install / GHA は diff に無し
- NFR 3.2 — 既存後方互換規約を踏襲（追加機能は markdown 観点のみ）

## Boundary 確認

design-less impl のため tasks.md / `_Boundary:_` アノテーションは不在。requirements.md / impl-notes.md
で示された変更対象（`.claude/rules/design-review-gate.md` / `.claude/rules/tasks-generation.md` および
repo-template 側の対応ファイル）のみが diff に含まれており、境界逸脱は無し。

## Findings

なし

## Summary

requirements.md の全 numeric ID（1.1〜1.5 / 2.1〜2.5 / 3.1〜3.5 / 4.1〜4.5 / 5.1〜5.5 / 6.1〜6.4 /
NFR 1.1〜1.3 / 2.1〜2.3 / 3.1〜3.2）が design-review-gate.md / tasks-generation.md 両系統への追記で
適切にカバーされており、二重管理規約（`diff -r` clean）も満たされている。boundary 逸脱なし。

RESULT: approve
