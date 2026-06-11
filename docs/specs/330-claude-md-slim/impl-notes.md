# 実装ノート — Issue #330 / CLAUDE.md のスリム化と重複 Read 指示の削除

## 概要

CLAUDE.md（self / template）冒頭の再 Read 指示を自動ロード前提の記述へ置換し、developer.md /
reviewer.md の CLAUDE.md 明示 Read を削除した。これにより **developer / reviewer の実行ごとに
発生していた CLAUDE.md 全文（self 約 27K 字 / consumer 約 21K 字）のツール結果二重注入が消える**
（本 Issue の支配的効果）。あわせて PjM 専用の「PR 品質チェック」を project-manager.md へ移設し、
self CLAUDE.md 内で #322 ガイドライン §4 と重複していた二重管理長文規定をポインタへ統合した。

## 変更ファイル

1. `CLAUDE.md` — 冒頭文言 / 二重管理規定のポインタ化（-818 字） / rules 表導入文（#327 整合）/
   PR 品質チェックのポインタ化
2. `repo-template/CLAUDE.md` — 冒頭文言 / rules 導入文 / PR 品質チェックのポインタ化（+164 字。
   条件ロードの説明追加が移設削減を上回った。後述「設計上の判断」）
3. `.claude/agents/developer.md`（×2）— FF 採否確認を「自動ロード済み CLAUDE.md を確認（Read 不要）」へ
4. `.claude/agents/reviewer.md`（×2）— 必読リストから CLAUDE.md Read を除去（参照すべき節は明記）
5. `.claude/agents/project-manager.md`（×2）— 「PR 品質チェック（implementation モード）」節を新設
   （self / consumer 両対応の読み替え注記付きで統合）

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| 1.1 | 両 CLAUDE.md 冒頭（自動ロード + 再 Read 不要 + #327 言及） | 文面確認 |
| 1.2 / 1.3 | developer.md / reviewer.md（×2） | `grep "Read し" / "自動ロード済み"` |
| 1.4 | 自動ロードは Claude Code の挙動（変更なし）。参照すべき節名を明記 | 設計判断 |
| 2.1 / 2.2 | 両 CLAUDE.md のポインタ + project-manager.md の新節 | 文面確認 |
| 2.3 | self CLAUDE.md の二重管理行 → ガイドライン §4 ポインタ（同内容は §4 に既存） | diff 確認 |
| 2.4 | rules 表導入文の条件ロード説明 | 文面確認 |
| NFR 1 | 削除した実体規約なし（移設 + ポインタ化のみ。§4 と重複していた文面は §4 側に全項目存在） | diff 突合 |
| NFR 2 | `diff -r .claude/agents repo-template/.claude/agents` → 空 | 検証結果 |
| NFR 3 | issue-watcher.sh 不変 | `git diff --stat` |

## 検証結果

- `diff -r .claude/agents repo-template/.claude/agents` → 空（IN SYNC）
- 文字数: self CLAUDE.md 27,748 → 26,930（-818）/ template 20,771 → 20,935（+164）
- markdown のみの変更。テストスイート・shellcheck 影響なし

## 設計上の判断

- **支配的効果はファイルサイズでなく再 Read 排除**: CLAUDE.md は自動ロードで全コンテキストに
  載り続けるため、ファイル本体の数百字の増減より「developer / reviewer 実行ごとの全文二重注入
  （21〜27K 字 × 実行回数）」の排除が桁違いに大きい。実体規約を削ってファイルを縮める案は
  品質リスク（規約の脱落）に見合わないため採らなかった
- **template が +164 字になった理由**: 条件ロード（#327）の説明追加が、短かった旧チェックリストの
  移設分を上回った。consumer 全コンテキストから PjM 専用チェックリストが消える効果（および
  reviewer/developer の再 Read 排除）が勝るため許容
- **「機能追加ガイドライン」の paths 付きルール化を見送った理由**: `.claude/rules/` は root ↔
  repo-template の byte 一致が鉄則（ガイドライン §4 自身の規定）だが、本ガイドラインは
  idd-claude 固有内容のため consumer へ配布できず、invariant を壊す。CLAUDE.md 内に残置した
- **issue-watcher.sh のプロンプト内「CLAUDE.md を Read」言及（build_dev_prompt_a 等）は不変**:
  #329 ブランチと同領域のため競合回避。両 PR merge 後に残存があれば軽微な派生課題として整理

## 確認事項（PR レビュワー向け）

- reviewer.md の必読リストから CLAUDE.md を外したが、reviewer の判定正本（テスト規約）への参照は
  本文に維持している。自動ロードが無効化された特殊環境（`--bare` 等）では到達しない点に注意
  （現行 watcher は Stage B で `--bare` を使わないため影響なし）
