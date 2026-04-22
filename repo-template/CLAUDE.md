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

## テスト規約

### 粒度の使い分け

- **単体テスト**: 純粋関数・個別クラスのロジック。最も数が多くなる層
- **結合テスト**: DB / 外部サービスを介したユースケース。モックより実物（テスト用 DB / テストサーバ）を優先
- **E2E**: 主要ユーザーストーリーのゴールデンパスに絞る。網羅を狙わない

### 命名と構造

- `describe('対象') > it('<条件>のとき<期待結果>')` 形式を徹底し、テスト名だけで検証内容が分かるようにする
- 各テストは **Arrange / Act / Assert** の 3 パートに明示的に分離する
- **1 テスト = 1 検証対象**。複数観点を 1 つの `it` にまとめない

### モック方針

- **モックしてよい**: HTTP / DB / 時刻 / ファイル / 外部 SDK など、外部副作用を伴うもの
- **モックしない**: 自分が書いた純粋ロジック、テスト対象と同一モジュール内の関数
- 認証・マイグレーションなどモックと本番挙動が乖離しやすい領域は、実物に近い fixture を優先する

### カバレッジ・観点

- 目標は **変更箇所の分岐をすべてカバー**。全体カバレッジ率は KPI にしない
- 各 AC に対して、正常系だけでなく **異常系・境界値・空入力を最低 1 ケース**用意する
- AC と 1 対 1 に紐付かないテストは spec に戻って AC を追加するか、テスト自体を削除する

### 運用

- **flaky テスト**は quarantine せず、原因を特定して修正するか削除する。一時的 skip を入れた場合は即時に Issue 化する
- **テストデータ fixture** は `__fixtures__/` または `test/fixtures/` に集約し、テスト間で共有する
- **Red → Green → Refactor**: 新規テストは一度失敗することを確認してから実装で通す（書いた瞬間に pass するテストは観点不備を疑う）

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
- テストを通すために実装ではなくテスト側を書き換えて弱めること（mock を過度に強める / assert を緩める / スナップショットを盲目的に更新する等）

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念する
- **Architect**（条件付き起動）は要件を変更しない。モジュール構成・データモデル・公開 IF・処理フロー・実装分割の設計に専念する
- **Developer** は仕様を追加・解釈しない。不明点があれば PM / Architect に差し戻す
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念する
- Architect は Triage の `needs_architect: true` 判定時のみ PM と Developer の間に挟まれる
- Architect が起動した Issue では **設計 PR ゲート**を経由する（設計 PR を merge してから実装 PR が別途作られる）
- Developer は `design.md` / `tasks.md` を書き換えない（設計 PR で人間レビュー済みのため）。矛盾は PR 本文「確認事項」で指摘する
- 各エージェントの成果物は `docs/specs/<番号>-<slug>/` 配下に保存する（Kiro / cc-sdd 互換）
  - `requirements.md`（PM）— EARS 形式の AC、numeric 階層 ID
  - `design.md`（Architect、条件付き）— File Structure Plan / Components and Interfaces / Traceability
  - `tasks.md`（Architect、条件付き）— `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` アノテーション
  - `impl-notes.md`（Developer、補足）
- `<slug>` は Issue タイトルを lowercase・ハイフン区切り・40 文字以内に正規化した値。既存ディレクトリがあれば流用する

## エージェントが参照する共通ルール（`.claude/rules/`）

各エージェントは作業前に以下のルールを `Read` で読み込みます。ルールの詳細は `repo-template/.claude/rules/*.md` を参照。

| ルールファイル | 参照エージェント | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC の EARS 記法（When / If / While / Where / shall） |
| `requirements-review-gate.md` | PM | requirements.md の自己レビュー（Mechanical + 判断、最大 2 パス） |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー（traceability / File Structure Plan 充填 / orphan 検出） |
| `tasks-generation.md` | Architect / Developer | tasks.md のアノテーション規約と numeric ID 階層 |

ルール群は [cc-sdd](https://github.com/gotalab/cc-sdd)（MIT License, Copyright gotalab）から
adapt したものです。

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
