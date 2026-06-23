# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T20:40:00Z -->

## Reviewed Scope

- Branch: claude/issue-399-impl-feat-pr-reviewer-spec
- HEAD commit: 7d92cf96bf5f545be3b9b850623f9175ab70d456
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/modules/pr-reviewer.sh`（+24 行 / `pr_default_prompt` 本文のヒアドキュメント追記のみ）
  - `local-watcher/test/pr_default_prompt_test.sh`（新規 +319 行 / 52 アサーション）
  - `README.md`（+22 行 / #399 小節追加）
  - `docs/specs/399-feat-pr-reviewer-spec/requirements.md`（新規）
  - `docs/specs/399-feat-pr-reviewer-spec/impl-notes.md`（新規）

## Verified Requirements

- 1.1 — `pr-reviewer.sh:318` 「差分全体を 1 パスで網羅的に走査し、検出した指摘は **列挙漏れなく一度に** 出力すること」 / `pr_default_prompt_test.sh` Req 1.1 系（2 アサーション）
- 1.2 — `pr-reviewer.sh:319-320` 「同一観点で複数箇所に同種の問題がある場合は **drip-feed（小出し）せず**、最初のパスで該当箇所をすべて列挙すること」 / Req 1.2 系（2 アサーション）
- 1.3 — `pr-reviewer.sh:324-329` 既存 5 観点（正確性のバグ / 受入基準の未カバー / テスト不足 / セキュリティ退行 / 後方互換性の破壊）が順序保持で温存 / Req 1.3 系（7 アサーション・順序検証含む）
- 1.4 — `pr_build_prompt_file` の解決順序（line 386-389）が不変。`PR_REVIEWER_PROMPT` 未設定 / 空時は `pr_default_prompt` を採用 / Req 1.4 系（6 アサーション・置換確認含む）
- 1.5 — 同上の解決順序で override が優先される。Req 1.5 系（2 アサーション）
- 2.1 — `pr-reviewer.sh:331-335` 「差分に `docs/specs/<番号>-<slug>/` 配下のファイル変更（`requirements.md` / `design.md` / `tasks.md` のいずれか）が含まれる **場合に限り**」明示 / Req 2.1 系（5 アサーション）
- 2.2 — `pr-reviewer.sh:337-338` 「requirements ⇄ design: `requirements.md` の各 AC（numeric ID）が `design.md` でカバーされているか」 / Req 2.2 系（3 アサーション）
- 2.3 — `pr-reviewer.sh:339-340` 「design ⇄ tasks: `design.md` の Components / Interfaces が `tasks.md` のタスクで実装手順化されているか」 / Req 2.3 系（1 アサーション）
- 2.4 — `pr-reviewer.sh:341-343` 「tasks ⇄ requirements: `tasks.md` の各タスクの `_Requirements:_` アノテーションが `requirements.md` に実在する AC ID を参照しているか」 / Req 2.4 系（2 アサーション）
- 2.5 — `pr-reviewer.sh:331,334-335` 「条件付き適用」表現と「`docs/specs/` 配下のファイルが含まれない PR では本節をスキップし、上記「レビュー観点」の実施を阻害しないこと」 / Req 2.5 系（2 アサーション）
- 3.1 — `pr-reviewer.sh:354,356,359` 3 セクション見出し温存 / Req 3.1 系（3 アサーション）
- 3.2 — `pr-reviewer.sh:360-362` 「本文の最終行に、次のいずれか 1 行だけを単独で出力」/`VERDICT: needs-iteration` / `VERDICT: approve` 温存 / Section 3 で既定 ITERATION_PATTERN が `needs-iteration` にマッチし `approve` に誤発火しないことを確認（3 アサーション）
- 3.3 — `pr-reviewer.sh:357` `[high|medium|low] <file>:<line> — <内容と根拠>` 温存 / Req 3.3 系（1 アサーション）
- 3.4 — `pr-reviewer.sh:358` 「（指摘が無ければ「指摘なし」）」温存 / Req 3.4 系（1 アサーション）
- 3.5 — `pr-reviewer.sh:349-351` read-only / file:line 引用 / スタイル lint 対象外 の 3 制約温存 / Req 3.5 系（3 アサーション）
- 3.6 — `pr-reviewer.sh:313` `<<'PR_REVIEWER_DEFAULT_PROMPT_EOF'`（quoted heredoc）で `{BASE}` / `{HEAD}` / `{PR}` が未置換のまま出力されることを温存 / Req 3.6 系（3 アサーション）
- 4.1 — diff 範囲が `pr_default_prompt` のヒアドキュメント本文のみ。env var 名 / 既定値 / 意味の変更なし（`grep` で `PR_REVIEWER_PROMPT` / `PR_REVIEWER_ITERATION_PATTERN` 等の宣言箇所に変化なし）
- 4.2 — diff にラベル名（`needs-iteration` / `ready-for-review` / `claude-failed`）への変更なし
- 4.3 — diff に exit code / ログ prefix / 出力先への変更なし
- 4.4 — `pr_build_prompt_file` の解決順序・置換ロジック・一時ファイル経由の引き渡し方式は不変（line 381-399 で変更なし）
- 4.5 — `pr_default_prompt_test.sh` Req 4.5 系で「網羅性要求」「drip-feed」「spec 文書間整合チェック」が override 時に流入しないことをネガティブ検証（3 アサーション）
- 5.1 — `repo-template/local-watcher/bin/modules/` ディレクトリが存在しないこと確認済み（`ls repo-template/local-watcher/bin/modules/` → no such dir）。AC 5.1 の「片系統のみが存在する場合は当該系統のみを更新する」分岐に該当
- 5.2 — 同上（repo-template 系統に該当ファイル不在のため `diff -r` 対象外）
- 5.3 — `README.md:2856-2877` で `PR_REVIEWER_PROMPT` 環境変数による override 経路で新文言が流入しない旨を明記、`README.md:2904` で既存の env var 表記温存
- NFR 1.1 — 反復ラウンド削減の観測指標（`pr-iteration:` ログ）が温存されていることを確認（コードフロー無変更によって担保。具体的な数値は運用観測で別 Issue にて検証する旨が impl-notes に明記）
- NFR 1.2 — 1 パスあたりトークン量増加の許容と累計トークン削減目標の方針が要件本文と整合（運用観測フェーズで数値化される旨が impl-notes に明記）
- NFR 2.1 — `pr_log` / `pr_warn` / `pr_error` の prefix・timestamp 書式に diff なし
- NFR 2.2 — 観測ログ行を新規追加しておらず（diff は prompt 本文と test とドキュメントのみ）、1 サイクルあたりのログ行数は不変

## Findings

なし

## Summary

既定プロンプトのヒアドキュメント本文に「網羅性要求」節と「spec 文書間整合チェック（条件付き
適用）」節が追加され、既存の 5 観点 / 3 セクション見出し / `VERDICT:` 出力契約 /
`{BASE}` `{HEAD}` `{PR}` プレースホルダ / 3 制約はすべて温存されている。`pr_build_prompt_file`
の解決順序・置換ロジックは未変更で、`PR_REVIEWER_PROMPT` 非空時に新文言が流入しないことが
ネガティブ検証されている。新規 `pr_default_prompt_test.sh` 52 アサーションが PASS、既存
回帰テスト 3 件も無回帰で PASS。`repo-template/local-watcher/bin/modules/` は不在のため
Req 5.1 / 5.2 は片系統運用に該当し、README には #399 小節が追加されている。3 カテゴリ
（AC 未カバー / missing test / boundary 逸脱）いずれも検出されず。

RESULT: approve
