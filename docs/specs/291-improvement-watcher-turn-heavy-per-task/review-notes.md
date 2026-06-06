# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-06T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-291-impl-improvement-watcher-turn-heavy-per-task
- HEAD commit: ac8be59397a1e95dc0163d5921c0ffe8b8858e9d
- Compared to: main..HEAD
- Mode: design-less impl（`tasks.md` 不在。spec ディレクトリには `requirements.md` /
  `impl-notes.md` のみ。本 spec は requirements で「ドキュメント追記のみ」と明記されており、
  `tasks.md` の不在は意図通り。stage-a-verify gate も対象外 / SKIP の設計と整合）
- Changed files: `README.md` (+144), `QUICK-HOWTO.md` (+7),
  `docs/specs/291-improvement-watcher-turn-heavy-per-task/{requirements,impl-notes}.md`
- 編集対象に `local-watcher/bin/issue-watcher.sh` / `.claude/agents/*.md` /
  `.claude/rules/*.md` / GitHub Actions workflow が **含まれていない**ことを diff で確認

## Verified Requirements

- 1.1 — README.md L5624 に `#### 分割復旧手順（turn-heavy 親タスクが溢れたときの tasks.md
  フラット化手順）` を h4 として追加。既存 h3 `### per-task-implementer-failed /
  error_max_turns 対応`（L5476）配下に配置されている
- 1.2 — h5 `##### ステップ 1: 診断` 〜 `##### ステップ 6: 監視` の 6 ステップが requirements
  指定の順序（診断 → 分割設計 → tasks.md フラット化編集 → commit & push → ラベル復旧 →
  監視）で並んでいる
- 1.3 — ステップ 1（診断）が「ログ」「ラベル」「git 履歴」の観測入力を bullet で列挙、ステップ
  3〜5 が tasks.md 編集 / git コマンド / gh ラベル操作の運用者アクションを記述しており、
  入力と操作が分離されている
- 1.4 — QUICK-HOWTO.md L291-295 に README 該当アンカーへの相互リンクを追加 + L307 の
  「次に読むもの」リストにも追加。アンカー
  `#分割復旧手順turn-heavy-親タスクが溢れたときの-tasksmd-フラット化手順` で 1 クリック到達可能
- 1.5 — 新サブセクションは h4（`####`）で配置され、既存 #289 で追加された h4「症状」
  「原因」「診断手順」「対応の優先順位」「ラベルの意味と次アクション」「復旧手順（impl PR
  の有無別）」を上書きしていない（diff は純粋な追記のみ）
- 2.1 — 「分岐基準」表の左列「in-branch 編集で対応可能（粒度のみ）」で File Structure Plan・
  Components 境界・Interfaces 不変、アノテーション温存可能等の判断条件を列挙
- 2.2 — 同表右列「design iteration が必要（設計変更）」で File Structure Plan 改訂・Components
  追加・Interfaces / 契約変更・`_Boundary:_` 逸脱・AC 追加の判断条件を列挙
- 2.3 — 同表「次アクション」列で 6 ステップ実行 / `needs-decisions` 付与 + 人間判断 /
  `design` モードでの Architect 再起動依頼 を明示
- 2.4 — 表直後の段落で「判断に迷うケース」は PR 本文の「確認事項」セクションに明記、または
  Issue コメントで PjM / Architect への差し戻し提案、というエスカレーション運用を明示
- 3.1 — ステップ 3 bullet 1 で `- [x]` 行は編集対象から除外し不変として保持（追加・削除・並び
  替え・ID 変更すべて禁止）と明示
- 3.2 — ステップ 3 bullet 2「アノテーション温存」で `_Requirements:_` / `_Boundary:_` /
  `_Depends:_` / `(P)` すべて保持と明示
- 3.3 — ステップ 3 末尾 bullet「design.md File Structure Plan との齟齬警告」で齟齬可能性を
  記述
- 3.4 — 同 bullet 末尾で「Plan 書き換えが必要と感じた時点で design iteration 側へ切り替える
  判断」を案内（分岐基準表との連動）
- 3.5 — ステップ 3 bullet「numeric ID 採番方針」で既存 ID 温存 + 新規分割タスクは最上位 ID
  として追番する旨を明示
- 3.6 — ステップ 3 bullet「`tasks-generation.md` 既存規約との整合」で checkbox 必須化・
  Budget overflow check・numeric ID 階層との非矛盾を明示、`tasks-generation.md` への
  相対リンクも記載
- 4.1 — ステップ 5 bullet「impl PR が存在しないケース」で既存「復旧手順 A」を参照し
  `claude-failed` 除去で再 pickup する手順を案内
- 4.2 — ステップ 5 bullet「impl PR が既に存在するケース」で「**必ず** `ready-for-review` を
  **先に** 付与してから `claude-failed` を除去」と順序を明示
- 4.3 — ステップ 5 末尾に ⚠️ 警告 blockquote を配置し、破壊事象（watcher が想定外の追加
  commit / push を実施するリスク）と回避策（順序遵守）を本文と視覚的に区別
- 4.4 — ステップ 6（監視）で impl PR の有無別に期待ラベル状態と次アクションを明示
- 4.5 — サブセクション全体で gh ラベル付与・除去の運用者操作のみを記述。watcher 内部の
  関数名・コードパスには踏み込んでいない
- 5.1 — ステップ 6 bullet 末尾で「完了済み `- [x]` 行はそのまま温存される（#270 / #263 で
  確立された per-task ループ運用と整合）」と明示
- 5.2 — ステップ 3 の `- [x]` 行不変規約 + ステップ 6 の `- [ ]` 行先頭からの impl-resume
  継続記述で、`- [ ]` ↔ `- [x]` を進捗の正本とする impl-resume 運用の温存を明示
- 5.3 — ステップ 4「進捗追跡コミット運用の継続」で `docs(tasks): mark <id> as done` を
  1 タスク = 1 commit として継続、フラット化前 commit を rebase / squash / amend で書き換え
  ない旨を明示
- 5.4 — サブセクション冒頭の blockquote で「対応の優先順位」(1) の具体実行手順として接続
  する位置付けと、(2) / (3) を選んだ場合は対象外とする切り分けを明示
- 6.1 — env 変数名（`DEV_MAX_TURNS` / `PR_ITERATION_MAX_TURNS` 等）は既存名・既定値のまま
  参照のみ（差分で名称・意味・既定値の変更なし）
- 6.2 — ラベル名（`claude-failed` / `per-task-implementer-failed` / `ready-for-review` /
  `auto-dev` / `claude-picked-up` / `claude-claimed` / `needs-decisions`）は既存名のまま
  参照のみ
- 6.3 — 編集対象は `README.md` / `QUICK-HOWTO.md` / spec ディレクトリの md のみ。watcher /
  agent / rules の挙動・規約は未変更（git diff --stat で確認）
- 6.4 — #289 で追加された h4「症状」〜「復旧手順（impl PR の有無別）」の本文は削除・改変
  されず、新サブセクションは末尾に追記された形（diff は純追加）
- 6.5 — `.claude/rules/*.md` / `.claude/agents/*.md` の編集が差分に無いため、root ↔
  repo-template の byte 一致規約には影響しない
- NFR 1.1 — h2 `## トラブルシューティング` → h3 #289 節 → h4 分割復旧手順 の経路。h3 内に
  配置されているため #289 Troubleshooting 節からは 1 ホップ以内で到達可能
- NFR 1.2 — QUICK-HOWTO.md → README アンカーへのリンクを 2 箇所追加（節本文 +「次に読むもの」
  リスト）。逆方向はトップから QUICK-HOWTO を辿る既存設計で成立
- NFR 1.3 — 検索キーワード `turn-heavy` / `分割復旧` / `tasks.md フラット化` を h4 タイトルと
  冒頭段落に含めている
- NFR 2.1 — ステップ 5 本文で順序（`ready-for-review` 先付与 → `claude-failed` 後除去）を
  実行手順の中で明示
- NFR 2.2 — ステップ 5 末尾の blockquote 形式 ⚠️ 警告ブロックで順序ミスのリスクを本文と
  視覚的に区別して記載
- NFR 2.3 — ステップ 3 で `- [x]` 行不変 + アノテーション温存規約 + ⚠️ 警告 blockquote
  （impl-resume 進捗破壊リスクに言及）
- NFR 3.1 — 日本語ベースで記述、識別子（env 変数名・ラベル名・コマンド名・branch 名）は
  英語固定
- NFR 3.2 — #289 節と同じ blockquote 警告スタイル / 表 / コードフェンス言語タグ / h4 / h5
  階層を踏襲

## Boundary 確認

- `tasks.md` 不在のため `_Boundary:_` アノテーションによる機械的判定は不可
- requirements.md の Out of Scope セクションで明示された境界（`local-watcher/bin/issue-watcher.sh`
  および `.claude/agents/*.md` の挙動変更 / `.claude/rules/*.md` の追記 / 既存 env・ラベル名
  の変更 / #289 本文の書き換え）に対し、git diff --stat の結果は `README.md` / `QUICK-HOWTO.md`
  および spec ディレクトリ内の `requirements.md` / `impl-notes.md` のみで、Out of Scope に
  対する逸脱は検出されない

## Findings

なし

## Summary

#291 はドキュメント追記のみで完結する design-less spec。Requirement 1〜6 と NFR 1〜3 の各 AC
について README の新 h4 サブセクションおよび QUICK-HOWTO の相互リンクで観測可能にカバーされ
ており、AC 未カバー / missing test / boundary 逸脱のいずれも検出されない。watcher 本体・
agent 定義・rules ファイル・既存 env / ラベル契約への変更は無く、後方互換性も保持されている。

RESULT: approve
