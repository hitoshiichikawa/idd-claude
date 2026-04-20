# idd-claude

**I**ssue-**D**riven **D**evelopment with **Claude** Code — GitHub Issue を起点に、
PM / 開発者 / PjM の 3 サブエージェント体制で自動開発を行うためのテンプレート一式。

Triage フェーズで人間判断が必要な論点を自動抽出し、Issue コメントで確認を取ってから
実装着手する、人間レビュー付き（Human-in-the-Loop）ワークフローを実現する。

---

## 特徴

- **Issue 駆動**: `auto-dev` ラベルが付いた Issue を検出すると、自動でブランチを切り、実装、テスト、PR 作成まで実施
- **人間レビュー内蔵**: 致命的な判断が必要な場合は Issue にコメントで質問を投稿し、人間の回答を待つ
- **ラベルによる状態機械**: 状態遷移はすべて GitHub ラベルで表現され、監査証跡がそのまま残る
- **Triage と実装の二段構え**: 軽量モデルで Triage、Opus 4.7（1M context）で本実装、とコストを最適化
- **2 つのデプロイ形態**:
  - **Local watcher**（推奨）: Claude Max サブスクリプションでローカル実行。Opus 4.7 の 1M context が利用可能
  - **GitHub Actions**: チーム・本番運用向け。API Key / Bedrock / Vertex AI で認証

---

## ディレクトリ構成

```
idd-claude/
├── README.md                        # 本ファイル
├── install.sh                       # セットアップ支援スクリプト
├── .gitignore
│
├── repo-template/                   # 開発対象リポジトリに配置するファイル
│   ├── CLAUDE.md                    # プロジェクト全体ガイド（全エージェント共通）
│   ├── .claude/
│   │   └── agents/
│   │       ├── product-manager.md   # PM サブエージェント
│   │       ├── developer.md         # Developer サブエージェント
│   │       └── project-manager.md   # PjM サブエージェント
│   └── .github/
│       ├── ISSUE_TEMPLATE/
│       │   └── feature.yml          # 自動開発用 Issue テンプレート
│       └── workflows/
│           └── issue-to-pr.yml      # GitHub Actions 版ワークフロー
│
└── local-watcher/                   # ローカル PC に配置するファイル
    ├── bin/
    │   ├── issue-watcher.sh         # Issue 監視＋Claude Code 起動シェル
    │   └── triage-prompt.tmpl       # Triage フェーズ用プロンプト
    └── LaunchAgents/
        └── com.local.issue-watcher.plist   # macOS launchd 設定
```

---

## 前提条件

### 共通

- GitHub リポジトリへの push 権限
- `gh` CLI（GitHub CLI）のインストールと `gh auth login` 済み
- `jq` のインストール
- Node.js 18 以上
- Claude Code CLI のインストール（`npm install -g @anthropic-ai/claude-code`）

### Local watcher 方式

- **Claude Max サブスクリプション**（Opus 4.7 の 1M context を利用するため）
- 常時稼働可能な macOS / Linux マシン
- ローカルで `claude /login` 済み
- `flock` コマンド（Linux では標準、macOS は `brew install util-linux` で `flock` を導入）

### GitHub Actions 方式

- 以下のいずれかの認証情報
  - `ANTHROPIC_API_KEY`（Console で発行）
  - `CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token` で発行、1 年有効、Opus 4.6 までの 200k context まで）
  - AWS Bedrock の OIDC 設定（エンタープライズ推奨）
  - Google Vertex AI の OIDC 設定（エンタープライズ推奨）

---

## セットアップ

### Step 1. 対象リポジトリへの配置

開発対象リポジトリに `repo-template/` の中身をコピーする。

```bash
cd /path/to/your-project
cp -r ~/github/idd-claude/repo-template/CLAUDE.md ./
cp -r ~/github/idd-claude/repo-template/.claude ./
cp -r ~/github/idd-claude/repo-template/.github ./

git add CLAUDE.md .claude .github
git commit -m "chore: introduce idd-claude workflow templates"
git push
```

### Step 2. GitHub 側の準備

リポジトリの Settings からラベルを作成する（GitHub CLI からでも可）。

```bash
gh label create auto-dev          --repo owner/repo --color 1f77b4 --description "自動開発対象"
gh label create needs-decisions   --repo owner/repo --color f1c40f --description "人間の判断が必要"
gh label create claude-picked-up  --repo owner/repo --color 9b59b6 --description "Claude Code 実行中"
gh label create ready-for-review  --repo owner/repo --color 2ecc71 --description "PR 作成完了"
gh label create claude-failed     --repo owner/repo --color e74c3c --description "自動実行が失敗"
gh label create skip-triage       --repo owner/repo --color 95a5a6 --description "Triage をスキップ"
```

Branch protection も設定しておく。

```bash
gh api -X PUT repos/owner/repo/branches/main/protection \
  -f required_pull_request_reviews.required_approving_review_count=1 \
  -F enforce_admins=false
```

### Step 3-A. Local watcher をセットアップ（推奨）

同梱の `install.sh` を使うか、手動で以下を実施する。

```bash
# 手動の場合
mkdir -p ~/bin ~/.issue-watcher/logs
cp ~/github/idd-claude/local-watcher/bin/issue-watcher.sh  ~/bin/
cp ~/github/idd-claude/local-watcher/bin/triage-prompt.tmpl ~/bin/
chmod +x ~/bin/issue-watcher.sh

# issue-watcher.sh の先頭の REPO / REPO_DIR / MODEL を環境に合わせて編集
$EDITOR ~/bin/issue-watcher.sh
```

#### macOS: launchd に登録

```bash
cp ~/github/idd-claude/local-watcher/LaunchAgents/com.local.issue-watcher.plist \
   ~/Library/LaunchAgents/

# plist 内のパス（$HOME/bin/issue-watcher.sh）が正しいことを確認
$EDITOR ~/Library/LaunchAgents/com.local.issue-watcher.plist

launchctl load  ~/Library/LaunchAgents/com.local.issue-watcher.plist
launchctl start com.local.issue-watcher

# 停止したいとき
# launchctl unload ~/Library/LaunchAgents/com.local.issue-watcher.plist
```

#### Linux / WSL: cron に登録

```bash
(crontab -l 2>/dev/null; echo "*/2 * * * * $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1") | crontab -
```

### Step 3-B. GitHub Actions をセットアップ（代替）

リポジトリの Settings → Secrets and variables → Actions で以下のいずれかを登録する。

- `ANTHROPIC_API_KEY`（Console で発行）
- または `CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token` で発行）

`.github/workflows/issue-to-pr.yml` は両方に対応する形でコメントアウトを切り替えるだけで使える。

---

## 使い方

### 基本フロー

1. リポジトリに Issue を起票する（`auto-dev` ラベルを付ける、または `feature.yml` テンプレートを使う）
2. 数分以内に Claude Code が Triage を実施する
3. 次のいずれかの結果になる
   - **要決定事項なし**: そのまま開発が走り、PR が作られる
   - **要決定事項あり**: Issue に決定事項コメントが投稿され、`needs-decisions` ラベルが付く
4. 決定事項コメントが付いた場合、人間が Issue コメントで回答する
5. すべての論点に結論が出たら **`needs-decisions` ラベルを外す**
6. 次のポーリングで自動的に再 Triage → 追加論点がなければ開発着手
7. PR が作成されたら人間がレビューして merge する

### 緊急時・強制着手

Triage をスキップしたい場合は Issue に `skip-triage` ラベルを付ける。

### 失敗時

Claude が連続で失敗した場合は `claude-failed` ラベルが付き、それ以降自動処理の対象外になる。
問題を解決してから、このラベルを外して手動で再実行キューに戻す。

---

## ラベル状態遷移まとめ

| ラベル | 意味 | 付与主 |
|---|---|---|
| `auto-dev` | 自動開発対象 | 人間（起票時） |
| `needs-decisions` | 人間判断が必要 | Claude（Triage 後） |
| `claude-picked-up` | Dev 実行中 | Claude |
| `ready-for-review` | PR 作成完了 | Claude（PjM 実行後） |
| `skip-triage` | Triage をスキップ | 人間（任意） |
| `claude-failed` | 自動実行停止中 | Claude（エラー連続時） |

ポーリングクエリ:
```
label:auto-dev
  -label:needs-decisions
  -label:claude-picked-up
  -label:ready-for-review
  -label:claude-failed
state:open
```

---

## サブエージェント構成

| 役割 | 目的 | 主なツール | 推奨モデル |
|---|---|---|---|
| **Product Manager** | Issue → 仕様書化 | Read / Grep / WebSearch / Write | Opus 4.7 |
| **Developer** | 仕様書 → 動くコード | Edit / Write / Bash / Grep | Opus 4.7 |
| **Project Manager** | ブランチ push / PR 作成 / ラベル管理 | Bash（`gh` CLI） | Sonnet 4.6 |

詳細は `repo-template/.claude/agents/*.md` を参照。

---

## トラブルシューティング

### `claude` コマンドが見つからない

cron / launchd は対話シェルのプロファイルを読み込まないため、`PATH` が通っていないことが多い。
`launchd` なら plist の `EnvironmentVariables` で `PATH` を明示する（同梱の plist では設定済み）。
cron なら `crontab -e` の先頭に `PATH=...` を書く。

### OAuth 認証が切れた

ローカルで `claude /login` を再実行する。1 年程度で切れることがある。

### Max 利用枠を使い切った

深夜に Issue が集中すると 5 時間ウィンドウを消費しきる場合がある。
`issue-watcher.sh` の `MAX_TURNS` を下げるか、Triage を Sonnet 4.6、本実装も Sonnet 4.6 に落とす。

### `/context` が 1M になっていない

`/logout` → `/login` で一度ログインし直す。それでも直らない場合は
Anthropic の既知バグの可能性（[#47019](https://github.com/anthropics/claude-code/issues/47019) 等）。

### 多重起動される

`issue-watcher.sh` は `flock` で単一インスタンス化しているが、
`/tmp` が消えている場合や別ユーザーで実行した場合は効かない。
常に同じユーザー・同じ `LOCK_FILE` パスで実行すること。

---

## 運用フェーズ移行戦略

| フェーズ | 認証方式 | 目的 |
|---|---|---|
| **Phase 1: 個人 PoC** | Local watcher + Claude Max | ワークフロー検証、Opus 4.7 の 1M context 活用 |
| **Phase 2: チーム検証** | GitHub Actions + `ANTHROPIC_API_KEY` | 複数人利用、実行可視化 |
| **Phase 3: 本番展開** | GitHub Actions + Bedrock / Vertex AI OIDC | データ所在地・監査要件・エンタープライズ統制 |

フェーズ間の移行は認証設定を差し替えるだけで、サブエージェント定義・CLAUDE.md・Issue テンプレートは不変で再利用できる。

---

## ライセンス

MIT License（社内利用を想定した雛形。必要に応じて変更してください）

---

## 参考資料

- [Claude Code 公式ドキュメント](https://docs.claude.com/en/docs/claude-code/overview)
- [anthropics/claude-code-action](https://github.com/anthropics/claude-code-action)
- [Claude Code Agent Teams](https://code.claude.com/docs/en/agent-teams)
- [Claude Code Authentication](https://code.claude.com/docs/en/authentication)
