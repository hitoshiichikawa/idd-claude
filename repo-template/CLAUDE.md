# プロジェクトガイド（Claude Code 全エージェント共通）

このファイルは Claude Code 本体および全サブエージェントが毎回参照するプロジェクト憲章です。
**すべてのエージェントは、作業開始前にこのファイルを読み直してください。**

---

## 技術スタック

> このセクションは各プロジェクトで書き換えてください。以下は例です。

- Backend: Node.js 20 + TypeScript
- Frontend: React 19 + Vite
- テスト: Vitest / Playwright
- Lint / Format: ESLint + Prettier
- CI: GitHub Actions
- パッケージマネージャ: pnpm

---

## コード規約

- 関数は単一責務・40 行以内を目安とする
- 公開 API には JSDoc / TSDoc を必ず付与する
- エラーは独自 Error クラスで wrap し、呼び出し側でログ出力する
- マジックナンバーは定数化する
- 非同期処理は async/await を優先し、Promise チェーンは避ける
- テストは対象コードの近傍に配置する（`__tests__/` または同一ディレクトリの `*.test.ts`）

---

## ブランチ・コミット規約

- ブランチ名: `claude/issue-<番号>-<slug>` を原則とする
- コミット: [Conventional Commits](https://www.conventionalcommits.org/) に準拠する
  - `feat(scope): ...` / `fix(scope): ...` / `test(scope): ...` / `docs(scope): ...` / `refactor(scope): ...` / `chore(scope): ...`
- 1 PR = 1 Issue を原則とする（スコープが膨らむ場合は PM が Issue を分割提案する）

---

## 禁止事項

- `main` ブランチへの直接 push
- `.env` や実値を含む Secrets のコミット
- 外部サービス呼び出し時に API Key を埋め込むこと（環境変数化を徹底）
- 公開リポジトリ上の第三者コードを、ライセンス確認なしにコピペすること
- テストをコメントアウトして PR を出すこと（scope 外に分離する場合は Issue を切る）

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念する
- **Developer** は仕様を追加・解釈しない。不明点があれば PM に差し戻す
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念する
- 各エージェントの成果物は `docs/issues/<番号>-<種別>.md` に保存する
  - 例: `docs/issues/42-spec.md`（PM 成果物）, `docs/issues/42-impl-notes.md`（Developer 補足）

---

## PR 品質チェック（PjM が PR 作成時に確認する項目）

- [ ] すべての受入基準に対応する実装がある
- [ ] 単体テストが追加・通過している
- [ ] lint / format が通っている
- [ ] 既存テストが壊れていない
- [ ] ドキュメントが更新されている（必要な場合）
- [ ] PR 本文に「確認事項」セクションがある（レビュワー判断ポイントを明示）

---

## 機密情報の扱い

- 本リポジトリでは以下の情報を扱わない
  - 顧客個人情報（氏名・契約番号・保険証券番号など）
  - 本番環境の認証情報
  - 社内機密情報（M&A・人事情報など）
- もし Issue 本文に機密情報が含まれていた場合、PM エージェントは実装を進めず
  `needs-decisions` で人間にエスカレーションすること

---

## 参考資料

- 各サブエージェントの詳細定義: `.claude/agents/*.md`
- Triage プロンプト: `~/bin/triage-prompt.tmpl`
- ワークフロー全体像: `README.md`（または idd-claude テンプレート）
