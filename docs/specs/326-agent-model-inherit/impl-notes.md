# 実装ノート — Issue #326 / agent frontmatter の model ハードコード削除（inherit 化）

## 概要

`.claude/agents/` と `repo-template/.claude/agents/`（byte 一致同期）の全エージェント定義から
`model: claude-opus-4-7` 行を削除し、Claude Code の省略時挙動 **inherit**（メイン会話 =
watcher が `--model` で渡す `DEV_MODEL` / `REVIEWER_MODEL` を継承）に切り替えた。
`project-manager.md` のみ `model: sonnet`（エイリアス）固定を維持。

## 変更ファイル

1. `.claude/agents/{product-manager,architect,developer,reviewer,qa,debugger}.md`
   - frontmatter の `model: claude-opus-4-7` 行を削除（6 ファイル）
2. `.claude/agents/project-manager.md`
   - `model: claude-sonnet-4-6` → `model: sonnet`（バージョン陳腐化防止のエイリアス化）
3. `.claude/agents/reviewer.md`
   - 本文の review-notes テンプレート例 `model=claude-opus-4-7` → `model=<model-id>`
4. `repo-template/.claude/agents/` — 上記 1〜3 と byte 一致で同期
5. `README.md` — Reviewer「環境変数」節に Migration note（#326）を追加
   （解決順位 / 既定有効モデル不変 / `CLAUDE_CODE_SUBAGENT_MODEL` の存在）

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | 6 agent ファイルの `model:` 行削除 | `grep "^model:" .claude/agents/*.md` が project-manager のみ |
| Req 1.2 | project-manager.md `model: sonnet` | 同上 grep |
| Req 1.3 | reviewer.md テンプレート `model=<model-id>` | `grep -rn "claude-opus-4-7" .claude/agents/` → 0 件 |
| Req 1.4 | repo-template 同期 | `diff -r .claude/agents repo-template/.claude/agents` → 空 |
| Req 2.1 / 2.2 | README Migration note + `CLAUDE_CODE_SUBAGENT_MODEL` 記載 | 文面確認 |
| NFR 1 | 既定有効モデル不変（inherit 先 = `DEV_MODEL` 既定 `claude-opus-4-7`） | 設計判断（下記） |
| NFR 2 | name / description / tools / 本文役割は不変 | `git diff` で frontmatter `model:` 行とテンプレ例のみ |
| NFR 3 | スクリプト変更なし | `git diff --stat` に .sh / .yml なし。frontmatter `model:` への script 依存も grep で不在を確認 |

## 検証結果

- `diff -r .claude/agents repo-template/.claude/agents` → 空（IN SYNC）
- `grep -rn "claude-opus-4-7\|claude-sonnet-4-6" .claude/agents/ repo-template/.claude/agents/` → 0 件
- `grep -rn "model:" local-watcher/bin/ install.sh setup.sh .github/`（非 .md / 非 env var）→ 0 件
  （frontmatter を parse するスクリプトは存在せず、削除による watcher 側の影響なし）
- 既存テストスイートは agent 定義を参照しないため影響なし（変更ファイルに .sh なし）

## 設計上の判断

- **`model:` 省略 = inherit**: Claude Code 公式 docs（sub-agents）で「Defaults to `inherit`」を確認
  済み。解決順位は `CLAUDE_CODE_SUBAGENT_MODEL` env > 呼び出しパラメータ > frontmatter >
  メイン会話モデル
- **project-manager のみ固定維持**: design ルート（PM → Architect → PjM を 1 セッション実行）では
  PjM が Opus セッション内のサブエージェントとして起動されるため、inherit にすると design ルートの
  PR 作成だけ Opus に格上げされてしまう。軽量固定の意図を保ちつつ、フル ID → エイリアスで
  バージョン追従させる
- **既定挙動の等価性**: env 未設定環境では inherit 先（`DEV_MODEL` / `REVIEWER_MODEL` 既定）が
  従来の固定値と同一の `claude-opus-4-7` のため、本変更単体では有効モデルが変わらない

## 確認事項（PR レビュワー向け）

- `DEV_MODEL` / `REVIEWER_MODEL` を**明示 override している既存ユーザー**は、本変更後その値が
  サブエージェントまで届くようになる（= 従来は意図に反して Opus 固定だったものが、設定どおりに
  なる）。「設定が効くようになる」方向の変更だが、想定外のモデル変化に見える可能性があるため
  README の Migration note で明示した
- 実機での継承確認（`DEV_MODEL=claude-sonnet-4-6` で `modelUsage` に sonnet が現れること）は、
  #325 Token Usage Report の merge 後に dogfooding で観測可能

## 派生タスク候補

- `AUTO_REBASE_MODEL` / `PR_ITERATION_DEV_MODEL` 等のフル ID 既定値をエイリアスへ寄せる検討
  （モデル世代更新時の README / env default 一括更新の手間削減）
