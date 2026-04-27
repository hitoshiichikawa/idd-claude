# プロジェクトガイド（Claude Code 全エージェント共通）

このファイルは Claude Code 本体および全サブエージェントが毎回参照するプロジェクト憲章です。
**すべてのエージェントは、作業開始前にこのファイルを読み直してください。**

---

## このリポジトリについて

**idd-claude はツール / テンプレートリポジトリ** です。他の repo に配置する開発ワークフローテンプレートと、ローカル watcher スクリプト一式を提供します。

**重要: self-hosting (dogfooding)**: idd-claude 自身も idd-claude のワークフロー対象 repo として運用しています（`repo-template/` 一式を root にも配置）。**あなたが編集している watcher スクリプトやテンプレートそのものが、次回 cron 実行であなた自身を動かす**ことを意識してください。後方互換性と冪等性が極めて重要です。

**構成要素**:

- `local-watcher/` — ローカル実行用 bash スクリプト (`issue-watcher.sh`, Triage prompt template)
- `repo-template/` — 他 repo に配置するテンプレート (CLAUDE.md, agents, rules, ISSUE_TEMPLATE, workflows, labels script)
- `install.sh` / `setup.sh` — インストーラ（ユーザースコープ、sudo 不要）
- `README.md` — 設計思想とセットアップ手順の主要ドキュメント
- `.github/workflows/issue-to-pr.yml` — GitHub Actions 版ワークフロー（`IDD_CLAUDE_USE_ACTIONS=true` で opt-in）

アプリケーションコード（JS/TS/Python バックエンド等）はありません。本体は **bash + markdown + GitHub Actions YAML**。

---

## 技術スタック

- **スクリプト**: bash 4+ (Linux / macOS / WSL)
- **依存 CLI**: `gh`, `jq`, `flock`（Linux 標準、macOS は `brew install util-linux`）, `git`
- **GitHub Actions**: `actions/checkout`, `anthropics/claude-code-action` 等
- **モデル**: Triage は Sonnet 4.6、本実装は Opus 4.7 (1M context) をデフォルト
- **ランタイム追加なし**: Node.js / Python 等は依存しない

---

## コード規約

### bash スクリプト（本リポジトリのコア成果物）

- 冒頭で `set -euo pipefail` を必ず宣言
- 変数展開は常にクォート (`"$var"`, 配列は `"${arr[@]}"`)
- `which` ではなく `command -v` でコマンドの存在確認
- `~` ではなく `$HOME` を使う（cron は `~` を展開しない事故が起きる）
- ファイル冒頭のコメントで「用途 / 配置先 / 依存 / セットアップ参照先」を明記する（現行 `issue-watcher.sh` / `install.sh` 参照）
- 環境変数は `"${VAR:-default}"` で override 可能にし、**既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）は後方互換性のため壊さない**
- 破壊的操作（`git checkout`, `rm -rf`, `git push --force*`）の前に前提条件を check
- エラーメッセージは `>&2` に出す。標準出力は機械可読な結果用に予約する

### markdown（テンプレート類）

- h1 はファイル先頭 1 つのみ、以降は階層を一貫させる
- コードフェンスには言語タグを付ける（` ```bash ` / ` ```yaml ` 等）
- 内部リンクは相対パス、コード箇所は `file_path:line_number` 形式
- 絵文字はステータス表示に限定して節度を持つ

### yaml (GitHub Actions workflow)

- `actionlint` をクリアすること
- `permissions:` は最小権限に絞る
- secrets は `${{ secrets.NAME }}` で参照、echo しない

### 全体共通

- 単一責務の関数・セクションに分割する
- 設定値（URL、path prefix、default 値）はファイル冒頭の config ブロックにまとめる
- silent fail を作らない（失敗は exit code / log で明示）

---

## テスト・検証

**本リポジトリには unit test フレームワークはありません**。検証は以下の組み合わせ:

### 静的解析

- `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` — 警告ゼロを目指す
- `actionlint .github/workflows/*.yml` — workflow YAML の検査

### 手動スモークテスト（変更した成果物ごとに実施）

- **`install.sh` 変更時**: 使い捨て scratch repo を `/tmp` に作り、`./install.sh --repo /tmp/scratch` を実行して冪等性とファイル配置を確認
- **`setup.sh` 変更時**: `IDD_CLAUDE_DIR=/tmp/setup-test bash setup.sh` で新規クローン / 既存ディレクトリ双方で動くこと
- **`issue-watcher.sh` 変更時**:
  - cron-like 最小 PATH での依存解決: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git'`（`local-watcher/bin/issue-watcher.sh` 冒頭の PATH prepend を経由して解決されること）
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で流し、`処理対象の Issue なし` で正常終了すること
  - E2E: 本リポジトリに test issue を立てて watcher が Triage → PR 作成までできるか

### 冪等性

- `install.sh` / `setup.sh` / `.github/scripts/idd-claude-labels.sh` は再実行で破壊しない
- 既存ファイルがある場合は `.bak` バックアップまたは `--force` で opt-in 上書き

### dogfooding (E2E)

- 大きい機能変更は、本 repo 自身に対して `auto-dev` Issue を立てて watcher が正しく拾えるかで最終確認する

---

## ブランチ・コミット規約

- ブランチ名: `claude/issue-<番号>-<slug>` を原則とする
- コミット: [Conventional Commits](https://www.conventionalcommits.org/) に準拠
  - `feat(scope): ...` / `fix(scope): ...` / `docs(scope): ...` / `refactor(scope): ...` / `chore(scope): ...` / `test(scope): ...`
  - 典型的な scope: `watcher` / `install` / `setup` / `workflow` / `claude`（`repo-template/CLAUDE.md`）/ `readme` / `labels`
- 1 PR = 1 Issue を原則とする（スコープが膨らむ場合は PM が分割提案）

---

## 禁止事項

- `main` への直接 push
- `.env` / Secrets 実値のコミット、スクリプト内 API Key ハードコード
- **後方互換性を壊す変更を無告知で入れる**（既存 env var 名変更 / cron 登録文字列の変更 / ラベル名変更 / exit code 意味変更）。破る場合は README に migration note を書き、必要なら deprecation 期間を設ける
- **sudo を必要とする手順の追加**（idd-claude はユーザースコープ前提。`install.sh` / `setup.sh` の root 実行検知を外さない）
- モデル ID のハードコード（env default で override 可能にする。`TRIAGE_MODEL` / `DEV_MODEL` 参照）
- **opt-in gate なしで新しい外部サービス呼び出しを有効化**（`.github/workflows/issue-to-pr.yml` が `IDD_CLAUDE_USE_ACTIONS=true` で opt-in になっている設計を踏襲）
- `repo-template/**` の破壊的変更を、既 installed の consumer repo への影響評価なしに入れる
- テストをコメントアウトして PR を出す（scope 外に分離する場合は Issue を切る）

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念
- **Architect**（条件付き起動）は要件を変更しない。モジュール構成 / シェルスクリプト分割 / env var 設計 / 後方互換性方針 / ラベル体系 / template 互換性等の設計に専念
- **Developer** は仕様を追加・解釈しない。不明点は PM / Architect に差し戻す
- **Reviewer**（impl 系モードで自動起動）は Developer 完了後の独立レビューのみを担当し、要件・設計・実装・テストの追加や書き換えを行わない。判定は AC 未カバー / missing test / boundary 逸脱 の 3 カテゴリに限定する（スタイル / lint 観点では reject しない）
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念
- Architect は Triage の `needs_architect: true` 時のみ PM と Developer の間に挟まれる
- Architect が起動した Issue では **設計 PR ゲート**を経由する
- Reviewer は impl / impl-resume の Developer 完了直後に **独立 context** で起動され、reject 時は Developer に最大 1 回だけ自動差し戻し、再 reject では `claude-failed` で人間に委ねる（差し戻しループは Reviewer 最大 2 回 / Developer 最大 2 回で打ち切り）
- Developer は `design.md` / `tasks.md` を書き換えない（人間レビュー済みのため）。矛盾は PR 本文「確認事項」で指摘する
- 成果物は `docs/specs/<番号>-<slug>/` 配下に保存する
  - `requirements.md`（PM）— EARS 形式の AC、numeric 階層 ID
  - `design.md`（Architect）— File Structure Plan / Components and Interfaces / Traceability
  - `tasks.md`（Architect）— `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` アノテーション
  - `impl-notes.md`（Developer、補足）
  - `review-notes.md`（Reviewer、impl 系モードのみ）— 判定結果と Findings / 最終行 `RESULT: approve|reject`

### idd-claude 特有の設計上の注意

- **`local-watcher/bin/issue-watcher.sh` の変更**: 既稼働の cron / launchd を壊さない（env var 名、exit code 意味、ログ出力先、ラベル遷移契約を保つ）
- **`repo-template/**` の変更**: 既に installed の consumer repo にも影響する（`install.sh` 再実行で上書きされる）。破壊的変更は migration note 必須
- **`idd-claude-labels.sh` のラベルセット**: ラベル追加は OK、既存ラベル削除 / 名前変更は deprecation 期間を経てから
- **モデル ID デフォルト更新**: 既存ユーザが明示 override している前提で、env default のみ更新
- **README との二重管理**: 挙動を変えたら必ず README の該当箇所も同じ PR で更新する

---

## エージェントが参照する共通ルール（`.claude/rules/`）

各エージェントは作業前に以下のルールを `Read` で読み込む:

| ルールファイル | 参照エージェント | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC の EARS 記法（When / If / While / Where / shall） |
| `requirements-review-gate.md` | PM | requirements.md の自己レビュー（Mechanical + 判断、最大 2 パス） |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー（traceability / File Structure Plan 充填 / orphan 検出） |
| `tasks-generation.md` | Architect / Developer | tasks.md のアノテーション規約と numeric ID 階層 |

ルール群は [cc-sdd](https://github.com/gotalab/cc-sdd)（MIT License, Copyright gotalab）から adapt したものです。

---

## PR 品質チェック（PjM が PR 作成時に確認する項目）

- [ ] すべての受入基準に対応する実装がある
- [ ] `shellcheck` / `actionlint` がクリーン（該当ファイルを変更した場合）
- [ ] 手動スモークテストの結果を PR 本文の「Test plan」に記載
- [ ] 既存 env var 名 / ラベル / cron 登録文字列の後方互換性を確認
- [ ] README / CLAUDE.md / 該当 rule ファイルが更新されている（挙動変更時）
- [ ] 破壊的変更がある場合は README に migration note を追加
- [ ] PR 本文に「確認事項」セクションがある（レビュワー判断ポイントを明示）

---

## 機密情報の扱い

本リポジトリは OSS として公開されるツール / テンプレートです。扱わないもの:

- API keys / OAuth tokens の実値
- 作者個人名義の非公開 path / URL を例示用以外の形でハードコード
- 本番環境の認証情報

Issue 本文に実値が含まれた場合、PM エージェントは実装を進めず `needs-decisions` で人間にエスカレーションする。

---

## 参考資料

- サブエージェント定義: `.claude/agents/*.md`
- Triage プロンプト: `local-watcher/bin/triage-prompt.tmpl`（配置先: `~/bin/triage-prompt.tmpl`）
- Watcher 実装: `local-watcher/bin/issue-watcher.sh`（配置先: `~/bin/issue-watcher.sh`）
- ワークフロー全体像・セットアップ手順: `README.md`
- パイプライン全体設計: Issue #13（フェーズ別実装: #14〜#18）
