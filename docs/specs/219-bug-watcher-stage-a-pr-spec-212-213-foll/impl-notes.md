# 実装ノート（#219）

## Implementation Notes

### Task 1.1

- **採用方針**: `build_dev_prompt_a` の heredoc テキストのみを変更し、制御フロー・関数シグネチャ・戻り値は不変に保った（design.md Decision D1 / Boundary: build_dev_prompt_a）。
- **重要な判断**:
  - 後段提示表現の削除は impl / impl-resume 双方の heredoc（旧 L3242 / L3259）に同一の置換文を適用した。既存の前段制約文（「本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。Developer 完了後、独立 context の Reviewer サブエージェント…」）は維持し、削除対象は最後の「Reviewer の approve 後に…PR を作成します。」の 1 文のみとした。
  - 主語の弱化は `build_dev_prompt_a` の cat heredoc 冒頭（旧 L3327）のみに限定し、`build_dev_prompt_redo` 等の他関数の主語には触れていない。これにより tasks.md 不在で Stage A へ fallback した design-less impl 経路でも同一の責務限定表現が適用される。
  - 制約節（`## 制約`）には既存の「PR は作成しないこと」を維持したまま「reviewer / project-manager サブエージェントを起動しないこと」を 1 行追加した（Req 1.2 / 1.3）。
  - NFR 1.1 への配慮: 変更はプロンプト本文の責務限定のみで、tasks.md ありの Developer 実装内容や呼び出し元の制御フローには一切影響しない。
- **残存課題**: なし（task 2 以降の越境観測・spec 完全性保証関数の追加は別 task。本 task のスコープ外）。

## 受入基準の達成確認（本 task 担保分）

idd-claude には unit test framework が無く、本 task はプロンプト heredoc のテキスト変更のため、検証は静的解析（`shellcheck` / `bash -n`）と heredoc 内容の目視確認で担保する。

| Req ID | 担保内容 |
|--------|----------|
| 1.1 | Stage A プロンプトの「PR は作成しないこと」制約を維持しつつ、PjM 起動による PR 作成を促す後段提示文を削除。impl PR 作成を促す表現の排除を `build_dev_prompt_a` heredoc で確認 |
| 1.2 | 制約節に「reviewer / project-manager サブエージェントを起動しないこと」を明記。Reviewer 起動表現の除去を確認 |
| 1.3 | 同上（project-manager サブエージェント起動の禁止を制約節に明記） |
| 1.4 | 主語を「サブオーケストレーター（PM + Developer 担当）」へ弱化し、後段フロー全体（Reviewer / PjM 起動・PR 作成）の完遂を促す表現を排除。design-less impl 経路（Stage A fallback）でも同一プロンプトが適用される |
| NFR 1.1 | heredoc テキスト変更のみで制御フロー・関数シグネチャ・戻り値・呼び出し元の分岐は不変。tasks.md あり経路の Developer 実装内容を変えないことを確認 |

## 検証ログ（本 task）

- `bash -n local-watcher/bin/issue-watcher.sh` → `syntax OK`
- `shellcheck local-watcher/bin/issue-watcher.sh` → 既存の SC2317 (info) 5 件のみ。いずれも logger 関数群（L987 / L1346 / L2778 / L5401 / L5915）に関するもので本 task の変更箇所外。本変更による新規警告ゼロを確認

## 確認事項

- 現時点で design.md / tasks.md / requirements.md 間の矛盾は確認されなかった。
