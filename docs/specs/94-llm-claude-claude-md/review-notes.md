# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-12T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-94-impl-llm-claude-claude-md
- HEAD commit: 608989d29348ebfe3d02d4dd5179d66d9aabbc47
- Compared to: main..HEAD
- 変更ファイル: `CLAUDE.md` (+38) / `repo-template/CLAUDE.md` (+38) /
  `docs/specs/94-llm-claude-claude-md/requirements.md` (+172) /
  `docs/specs/94-llm-claude-claude-md/impl-notes.md` (+152)
- Feature Flag Protocol 採否: 本リポジトリ root `CLAUDE.md` に `## Feature Flag Protocol`
  節が無いため **opt-out 扱い**（Req 4.2 / NFR 1.1）。flag 観点の細目チェックは行わず、
  通常の 3 カテゴリ判定のみ実施。

## Verified Requirements

- 1.1 — 内部思考 = 英語ベースを明示: `CLAUDE.md:34`（`### 基本原則` の 1 つ目 bullet）、
  および種別表の `LLM の内部 reasoning / scratchpad` 行（`CLAUDE.md:43`）
- 1.2 — ユーザー向けアウトプット = 日本語ベースを明示: `CLAUDE.md:36`（`### 基本原則` の
  2 つ目 bullet）、および種別表の `GitHub Issue / PR` 行（`CLAUDE.md:44`）
- 1.3 — 方針節を読むだけで言語選択が一意に決定: 種別表（`CLAUDE.md:41-53`）が 11 種別を
  網羅し、fallback も `### 基本原則` 3 つ目 bullet（`CLAUDE.md:37`）で規定
- 1.4 — h2 独立見出し: `## 言語方針（思考言語と出力言語）`（`CLAUDE.md:26`）が既存 11 個の
  h2 と衝突せず独立に配置
- 1.5 — プロジェクト憲章の強制力: ファイル冒頭の「すべてのエージェントは作業開始前に
  読み直す」スコープ内に配置（独立ファイル化していない）
- 2.1 — 日本語アウトプットの対象列挙: 表に Issue / PR / `docs/specs/*` markdown 全 5 種を列挙
  （`CLAUDE.md:44-45`）
- 2.2 — 英語固定要素の例外列挙: EARS トリガーキーワード / Conventional Commits prefix /
  ブランチ名 / 識別子・コマンド名・ファイルパス・env var 名・ラベル名を列挙
  （`CLAUDE.md:46-49`）
- 2.3 — グレーゾーンの分類: コミットメッセージ本文 = 日本語ベース（`CLAUDE.md:50`）、
  PR タイトル = 日本語ベース（`CLAUDE.md:51`）、bash ログ出力 = 混在許容
  （`CLAUDE.md:52`）を表で明示
- 2.4 — fallback ルール明記: `### 基本原則` 3 つ目 bullet（`CLAUDE.md:37`）
- 3.1 — `repo-template/CLAUDE.md` 既存 h2 構成を破壊しない: 既存 11 個（`技術スタック` /
  `コード規約` / `テスト規約` / `ブランチ・コミット規約` / `禁止事項` / `エージェント連携ルール` /
  `エージェントが参照する共通ルール` / `PR 品質チェック` / `機密情報の扱い` /
  `Feature Flag Protocol` / `参考資料`）の見出し名・順序・本文すべて保持。追記のみ
- 3.2 — root `CLAUDE.md` 既存 h2 構成・本文と矛盾なし: 既存 11 個の h2（`このリポジトリ
  について` / `技術スタック` / `コード規約` / `テスト・検証` / `ブランチ・コミット規約` /
  `禁止事項` / `エージェント連携ルール` / `エージェントが参照する共通ルール` /
  `PR 品質チェック` / `機密情報の扱い` / `参考資料`）すべて保持
- 3.3 — `install.sh` の冪等性に影響しない: `install.sh` 本体は未変更（diff 上に出現せず）
- 3.4 — 既存節書き換え時の migration note: 既存節は書き換えていない（追記のみ）ため
  conditional `If` のトリガーが発火せず該当なし
- 3.5 — root と `repo-template` を同一 PR 内で更新: コミット `0f4d4e9 docs(claude): add
  language policy section to root and repo-template CLAUDE.md` で両ファイル同時更新
- 4.1 — EARS 規約と矛盾しない: 種別表で EARS トリガーキーワード = 英語固定、
  `.claude/rules/ears-format.md` 参照を明記（`CLAUDE.md:46`）
- 4.2 — `.claude/agents/*.md` の日本語指示と矛盾しない: 種別表で「`.claude/agents/*.md` の
  エージェント定義本文 = 日本語、人間運用者向けの指示書き」と明示分類（`CLAUDE.md:53`）
- 4.3 — reasoning 中も英語固定要素を保持: `### 既存規約との整合` 1 つ目 bullet
  （`CLAUDE.md:57`）
- 4.4 — 矛盾時のエスカレーション: `### 既存規約との整合` 3 つ目 bullet（`CLAUDE.md:59-60`）
- 5.1 — ファイル冒頭スコープ内に含む: CLAUDE.md 本体の h2 節として配置、独立ファイル化なし
- 5.2 — 独立ファイル化時の参照: 条件節（`Where`）のトリガーが発火せず該当なし（vacuously
  true）
- 5.3 — 個別エージェント定義の書き換え不要: `.claude/agents/*.md` は無変更（diff 上に出現せず）
- NFR 1.1 — 60 行以内: 言語方針節は h2 から末尾 `---` 直前まで 37 行（root / repo-template
  双方）
- NFR 1.2 — 対比が一目で把握できる形式: 3 列マークダウンテーブル（種別 / 言語 / 補足）で提示
- NFR 2.1 — watcher 挙動不変: `local-watcher/bin/issue-watcher.sh` および bash スクリプトは
  未変更（env var / exit code / ラベル / ログ出力先すべて保持）
- NFR 2.2 — 次回 watcher 実行で自動適用: CLAUDE.md は cron 実行時に都度読まれるため追加
  デプロイ不要
- NFR 3.1 — PR diff が言語方針節追加に限定: CLAUDE.md / repo-template/CLAUDE.md それぞれ
  +38 行のみ、既存行への変更なし
- NFR 3.2 — shellcheck / actionlint の警告増加なし: 変更は markdown のみで trivially 充足

## Findings

なし

## Summary

要件定義書の全 numeric ID（1.1-1.5 / 2.1-2.4 / 3.1-3.5 / 4.1-4.4 / 5.1-5.3 / NFR 1.1-3.2）が
root `CLAUDE.md` および `repo-template/CLAUDE.md` の追記内容で網羅されており、既存 h2 構成
の破壊もなし。markdown のみの変更で boundary 逸脱なし、missing test は本変更の性質上
適用対象外。

RESULT: approve
