# Quick HowTo: 既存リポジトリに idd-claude を導入する

**所要時間: 約 15 分**。
GitHub にある既存のリポジトリに idd-claude のワークフローを追加し、最初の自動開発 Issue が
動くまでの最短手順をまとめたドキュメントです。

> 包括的な仕様・複数 repo 運用・GitHub Actions 版・カスタマイズは [README.md](./README.md) を参照してください。
> 本ドキュメントは「ローカル watcher 方式 + 単一リポジトリ」に絞っています（最も推奨の構成）。

---

## 0. 前提

- GitHub リポジトリへの push 権限と、既にローカルクローン済みのワーキングコピーがあること
- macOS / Linux / WSL のいずれかで、常時稼働可能な PC がある（自動開発 watcher を動かすため）
- 以下のコマンドがインストール済み:
  - `gh`（GitHub CLI、`gh auth login` 済み）
  - `jq`
  - `flock`（Linux 標準。macOS は `brew install util-linux`）
  - Node.js 18 以上
  - `claude`（Claude Code CLI、`npm install -g @anthropic-ai/claude-code` 後 `claude /login` 済み）
- **Claude Max サブスクリプション**（Opus 4.7 の 1M context を使うため）

未インストールのものがあれば、先に揃えてから進めてください。

---

## 1. テンプレートを既存 repo に配置する（ワンライナー）

対象リポジトリのルートに `cd` してから、以下を実行します。

```bash
cd /path/to/your-existing-repo

curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
  | bash -s -- --all
```

`--all` は **対象 repo へのテンプレート配置 + ローカル watcher のインストール**を一気に行います。
途中で対話プロンプトが出る場合は Enter で進めて構いません。

実行後の状態:

| 配置先 | 内容 |
|---|---|
| 対象 repo | `CLAUDE.md` / `.claude/agents/` / `.claude/rules/` / `.github/ISSUE_TEMPLATE/feature.yml` / `.github/workflows/issue-to-pr.yml` / `.github/scripts/idd-claude-labels.sh` |
| `$HOME/bin/` | `issue-watcher.sh` / `triage-prompt.tmpl` / `iteration-prompt.tmpl` |
| `$HOME/.idd-claude/` | upstream のクローン（更新時に再 pull する場所）|

> **既存の `CLAUDE.md` がある場合**: 自動的に `CLAUDE.md.bak` にバックアップされます。
> 後で必要な記述を統合してください（[Step 3](#3-claudemd-を自プロジェクト用にチューニング) 参照）。

> **`curl | bash` を信用したくない場合**: スクリプトを先に読んでから実行できます。
> ```bash
> curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh -o /tmp/setup.sh
> less /tmp/setup.sh    # 内容確認
> bash /tmp/setup.sh --all
> ```

---

## 2. GitHub ラベルを作成する

idd-claude が状態管理に使うラベルを repo に作成します。

```bash
cd /path/to/your-existing-repo
bash .github/scripts/idd-claude-labels.sh
```

冪等なので何度実行しても安全です（既存ラベルはスキップ）。
作成されるラベル: `auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-picked-up` /
`ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration`

---

## 3. CLAUDE.md を自プロジェクト用にチューニング

配置された `CLAUDE.md` には汎用テンプレート（Node.js + TypeScript の例）が入っています。
**このファイルが全エージェントの行動指針**になるので、自プロジェクトに合わせて書き換えてください。

最低限編集すべき箇所:

- **「技術スタック」節**: 自プロジェクトの言語 / フレームワーク / テストランナー / lint に書き換え
- **「コード規約」節**: TypeScript 例ブロックを自言語の慣習に置換（Python / Go / Rust 等）
- **「テスト規約」節**: 末尾の TS 例を自プロジェクトのフレームワーク慣習に置換
- **「機密情報の扱い」節**: 自プロジェクト固有の禁止情報を列挙

書き換えたら commit して push:

```bash
git add CLAUDE.md .claude .github
git commit -m "chore: introduce idd-claude workflow templates"
git push
```

> **既存 CLAUDE.md があった場合**: `CLAUDE.md.bak` を見ながら、必要な独自規約を追加します。
> 既存の規約と idd-claude の規約は基本的に共存可能です。

---

## 4. cron に watcher を登録する（Linux / WSL）

watcher を 2 分ごとに起動するように cron を登録します。

```bash
crontab -e
```

末尾に以下を追加（`owner/your-repo` と `$HOME/work/your-repo` を自分の値に）:

```cron
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
```

> **macOS の場合**: cron でも動きますが、再起動後の自動復帰のために launchd を推奨します。
> 設定方法は [README の launchd 節](./README.md#macos-launchd-に登録) を参照。

### 動作確認

cron が動いているかは以下で確認できます:

```bash
# 直近のログを追跡
tail -f $HOME/.issue-watcher/cron.log

# 手動で 1 サイクル実行（cron を待たずに動作確認できる）
REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/issue-watcher.sh
```

`[<時刻>] 処理対象の Issue なし` と出れば正常です。

---

## 5. 最初の Issue で動かしてみる

ブラウザで対象 repo の Issues タブを開き、**「New issue」 → 「機能要望・改善（idd-claude 自動開発）」**
テンプレートを選択します（ステップ 1 で配置した `feature.yml` テンプレート）。

簡単なお題で試すのがおすすめです。例:

- `README.md` の typo 修正
- 既存スクリプトに 1 つコメントを追加
- 新規ファイルに「Hello」と書く

Issue 作成時に `auto-dev` ラベルが自動で付きます。**最大 2 分後**（cron 起動後）に watcher が
Issue を検出し、以下の流れが自動進行します:

```
auto-dev (起票)
   ↓
claude-picked-up   ← Triage 開始
   ↓
ready-for-review   ← 実装 PR 作成完了 (10〜30 分)
```

進捗は Issue のラベル変化と `$HOME/.issue-watcher/cron.log` で観察できます。

PR が作成されたらレビューして merge してください。これで最初のサイクルが完了です 🎉

---

## 6. トラブルシューティング（最頻出 3 件）

### `claude が見つかりません` エラーが cron.log に出る

cron は対話シェルの profile を読まないため、`PATH` に `claude` のパスが入っていないことが
原因です。`$HOME/bin/issue-watcher.sh` 冒頭で `~/.local/bin` / `/usr/local/bin` /
`/opt/homebrew/bin` を PATH に追加していますが、それ以外の場所に `claude` がある場合は
`crontab -e` の先頭に明示的な PATH を書いてください:

```cron
PATH=/path/to/claude/bin:/usr/local/bin:/usr/bin:/bin
*/2 * * * * REPO=owner/your-repo ...
```

### Claude の OAuth が切れた

ローカルで再ログインします:

```bash
claude /login
```

1 年程度で切れることがあります。

### Issue に `claude-failed` ラベルが付いて止まった

watcher が連続失敗したことを示します。`$HOME/.issue-watcher/logs/<repo-slug>/issue-<番号>-*.log`
で原因を確認し、修正してから手動でラベルを外すと次回サイクルで再開されます:

```bash
gh issue edit <番号> --repo owner/your-repo --remove-label claude-failed
```

---

## 7. 次に読むもの

- **[README.md](./README.md)** — 包括的な仕様、複数 repo 運用、GitHub Actions 版、サブエージェント詳細
- **`CLAUDE.md`**（配置済み） — 自プロジェクト用に編集する全エージェント憲章
- **README の `## 使い方`「Issue の書き方（PM を誤解させないコツ）」節** — Issue 作成時に PM エージェントを誤解させないための 3 原則
- **README の `## Merge Queue Processor (Phase A)` 節** — approved PR の自動 rebase（opt-in 機能）
- **README の `## PR Iteration Processor (#26)` 節** — レビューコメント起点の反復開発（opt-in 機能）
