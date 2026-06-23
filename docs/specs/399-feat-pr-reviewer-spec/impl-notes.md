# 実装ノート — Issue #399 PR Reviewer 既定プロンプト改訂

## 変更ファイル

- `local-watcher/bin/modules/pr-reviewer.sh`
  - `pr_default_prompt` 関数のヒアドキュメント（`PR_REVIEWER_DEFAULT_PROMPT_EOF`）に
    「網羅性要求」節と「spec 文書間整合チェック（条件付き適用）」節を追加。
  - 既存の「レビュー観点（優先度順）」5 項目（正確性のバグ → 受入基準の未カバー →
    テスト不足 → セキュリティ退行 → 後方互換性の破壊）の順序・本文を **温存**。
  - 既存の出力契約（`## 概要` / `## 指摘事項` / `## 結論` / `VERDICT:` 単独行 /
    `[high|medium|low] <file>:<line> — <内容と根拠>` 形式 / 「指摘なし」記述 /
    `{BASE}` `{HEAD}` `{PR}` プレースホルダ未置換）は **完全に温存**。
- `local-watcher/test/pr_default_prompt_test.sh` （新規）
  - Req 1 / 2 / 3 / 4 の AC を網羅する 52 件のアサーション。
  - Section 1: 内蔵 default prompt 本文の内容契約（Req 1.1〜1.3, 2.1〜2.5, 3.1〜3.6）。
  - Section 2: `pr_build_prompt_file` の `PR_REVIEWER_PROMPT` override 優先動作
    （Req 1.4 / 1.5 / 4.5）と「override 時に新文言が流入しないこと」のネガティブ検証。
  - Section 3: 既定 `PR_REVIEWER_ITERATION_PATTERN` regex が新文言下でも
    `VERDICT: needs-iteration` のみにマッチし `VERDICT: approve` に誤発火しないこと
    （Req 3.2 / 4.4）。
- `README.md`
  - 「PR Reviewer Processor (#261)」セクション内の「`VERDICT:` token による決定論的な
    ラベル判定」直後に「内蔵 default prompt の網羅性要求と spec 文書間整合チェック（#399）」
    小節を追加。`PR_REVIEWER_PROMPT` override 経路では新文言が **流入しない** ことと、
    出力契約は不変であることを明記。

## 設計上の判断

- **コードフロー変更なし**: プロンプト本文（ヒアドキュメント）の追記のみで完結。
  プロンプト解決順序（`PR_REVIEWER_PROMPT` が非空なら優先、空なら内蔵 default）/
  置換ロジック / 一時ファイル経由の引き渡し / VERDICT 検出正規表現
  （`PR_REVIEWER_ITERATION_PATTERN`）は **すべて不変**（Req 4.4）。
- **オープン質問への回答**:
  - **濃淡付け（high / medium / low）の方針**（Open Question 1）: 「low を理由に列挙を
    省略しない」と明文化し、**完全網羅** を採用。これにより同一観点で複数箇所ある場合の
    drip-feed を抑止（Req 1.2 達成）しつつ、優先度の濃淡情報自体は保持して
    レビュワー人間の triage は容易に保つ。
  - **整合チェック観点の表現粒度**（Open Question 2）: 3 観点を **独立 bullet**（`-`）
    で記述し、各 bullet 先頭に対応関係（`requirements ⇄ design`, `design ⇄ tasks`,
    `tasks ⇄ requirements`）を明示した。可読性と AC 識別性を両立する選択。
  - **既定プロンプトの目標長**（Open Question 3）: 結果 49 行（変更前 26 行 → +23 行）。
    既存節を温存しつつ最小限の追記としており、過度な長文化は避けた。LLM の attention
    分散リスクは「網羅性要求」を **最優先節として冒頭直後に配置** したことで緩和。
- **spec 整合節を「最優先」ではなく「条件付き適用」として独立節にした理由**:
  Req 2.5 で「docs/specs 不在時に他観点の実施を阻害しない」ことが明示されていたため、
  「優先度順 5 観点」の構造に混ぜず独立節として配置し、節先頭で「差分に `docs/specs/`
  配下が含まれる場合に限り」と明示適用条件を宣言する形にした。これにより、
  spec 不在の通常コード PR では LLM が当該節を skip しやすい構造になる。
- **「最終行 VERDICT 単独」規約**: 既存の line-anchored 正規表現
  （`^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$`）を変更しないため、
  プロンプト末尾の `VERDICT: needs-iteration` / `VERDICT: approve` 行（インデント無し）
  はそのまま温存。Section 3 のテストでこれが既定 regex で正しく検出され、`VERDICT: approve`
  に誤発火しないことを確認。

## 検証コマンドと結果

- `shellcheck local-watcher/bin/modules/pr-reviewer.sh` → 警告ゼロ（PASS）
- `bash -n local-watcher/bin/modules/pr-reviewer.sh` → PASS
- `shellcheck local-watcher/test/pr_default_prompt_test.sh` → 警告ゼロ（PASS）
- `bash local-watcher/test/pr_default_prompt_test.sh` → **PASS=52 FAIL=0**
- 既存テスト 3 件の回帰確認:
  - `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh` → **PASS=52 FAIL=0**
  - `bash local-watcher/test/pr_publish_commit_status_test.sh` → **PASS=74 FAIL=0**
  - `bash local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh` → **PASS=5 FAIL=0**

## root ↔ repo-template 同期確認

- `repo-template/local-watcher/bin/modules/pr-reviewer.sh` は **存在しない**
  （consumer 配布は `install.sh` が root の `local-watcher/bin/modules/` から直接行うため
  二重管理対象外）。Req 5.1 の「片系統のみが存在する場合は当該系統のみを更新する」に該当。
- `repo-template/.claude/{agents,rules}/` には PR Reviewer プロンプトを直接持つファイルが
  存在しないため二重管理同期は不要。
- README.md は consumer repo に複製されない（CLAUDE.md / README は consumer 固有のため
  byte 一致対象外。CLAUDE.md「機能追加ガイドライン 4.」の規約と整合）。

## AC Traceability（requirement ID → テスト）

| AC ID | 担保テスト |
|---|---|
| 1.1 | `pr_default_prompt_test.sh` Section 1 / Req 1.1 系（2 件） |
| 1.2 | `pr_default_prompt_test.sh` Section 1 / Req 1.2 系（2 件） |
| 1.3 | `pr_default_prompt_test.sh` Section 1 / Req 1.3 系（7 件、順序検証含む） |
| 1.4 | `pr_default_prompt_test.sh` Section 2 / Req 1.4 系（6 件、unset/empty + 置換確認） |
| 1.5 | `pr_default_prompt_test.sh` Section 2 / Req 1.5 系（2 件、override 値採用 + 置換） |
| 2.1 | `pr_default_prompt_test.sh` Section 1 / Req 2.1 系（5 件） |
| 2.2 | `pr_default_prompt_test.sh` Section 1 / Req 2.2 系（3 件） |
| 2.3 | `pr_default_prompt_test.sh` Section 1 / Req 2.3 |
| 2.4 | `pr_default_prompt_test.sh` Section 1 / Req 2.4 系（2 件） |
| 2.5 | `pr_default_prompt_test.sh` Section 1 / Req 2.5 系（2 件） |
| 3.1 | `pr_default_prompt_test.sh` Section 1 / Req 3.1 系（3 件、3 セクション見出し） |
| 3.2 | `pr_default_prompt_test.sh` Section 1 + Section 3 / Req 3.2 系（5 件） |
| 3.3 | `pr_default_prompt_test.sh` Section 1 / Req 3.3 |
| 3.4 | `pr_default_prompt_test.sh` Section 1 / Req 3.4 |
| 3.5 | `pr_default_prompt_test.sh` Section 1 / Req 3.5 系（3 件） |
| 3.6 | `pr_default_prompt_test.sh` Section 1 / Req 3.6 系（3 件） |
| 4.1 | コードフロー無変更（env var 名・既定値・意味は不変。`pr-reviewer.sh` の diff 範囲が `pr_default_prompt` 関数本体のヒアドキュメントのみであることで担保。`shellcheck` PASS で構文的に確認） |
| 4.2 | コードフロー無変更（ラベル名 `needs-iteration` / `ready-for-review` / `claude-failed` 等の付与契約は不変。既存テスト `pr_publish_commit_status_test.sh` / `pr_publish_claude_status_from_branch_test.sh` が無回帰でパス） |
| 4.3 | コードフロー無変更（exit code・ログ出力先・ログ prefix 不変。既存テスト無回帰パス） |
| 4.4 | `pr_default_prompt_test.sh` Section 2 / 3（解決順序と置換ロジックの不変、ITERATION_PATTERN マッチ動作の不変） |
| 4.5 | `pr_default_prompt_test.sh` Section 2 / Req 4.5 系（3 件、override 時に新文言が流入しないネガティブ検証） |
| 5.1 | `repo-template/` に該当ファイルが存在しないため対象外（本ノート「root ↔ repo-template 同期確認」節） |
| 5.2 | 同上（片系統のみ） |
| 5.3 | README.md 「内蔵 default prompt の網羅性要求と spec 文書間整合チェック（#399）」小節追加で「`PR_REVIEWER_PROMPT` による override 経路」と「出力契約は不変」を明記 |
| NFR 1.1 | プロンプト改訂が反復ラウンド削減につながるかは運用観測指標（`pr-iteration:` ログ集計）で別途検証。本 PR ではプロンプト本文の改訂と既定動作の保証までを対象とする |
| NFR 1.2 | 1 パスあたりトークン量増は許容、トータル削減目標は別途運用観測で決定（要件本文のとおり）。本 PR では計測手段（既存 watcher ログ）の存在を確認したことを記録 |
| NFR 2.1 | コードフロー無変更（`pr_log` / `pr_warn` / `pr_error` の prefix・timestamp 書式は不変） |
| NFR 2.2 | 観測ログ行を新規追加していない（プロンプト本文の追記のみ。1 サイクル `pr-reviewer:` ログ行数は変化なし） |

## 確認事項

- **NFR 1.1 / NFR 1.2 の数値検証**: 「反復ラウンド数 4 回以上 → 1〜2 回」「累計トークン
  消費量が現状と同等以下」は本 PR スコープでは観測手段の確認に留め、具体数値は運用
  ローンチ後に `pr-iteration:` ログを `grep` 集計して別 Issue で報告予定（要件本文の
  Open Questions の方針通り）。
- **Open Question 4（NFR 1.2 トータルトークン量の目標値宣言）**: 別運用観測 Issue に
  委ねる方針で本 PR は完結（要件本文の Open Questions 4 と整合）。
- **既定プロンプトの長さ増加**: 26 行 → 49 行（+23 行）。LLM 1 パスあたりの prompt
  入力トークンが増えるため、`PR_REVIEWER_EXEC_TIMEOUT` 既定 600 秒で枯渇しないか
  運用観測で確認したい。

STATUS: complete
