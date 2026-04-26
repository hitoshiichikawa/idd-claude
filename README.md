# idd-claude

**I**ssue-**D**riven **D**evelopment with **Claude** Code — GitHub Issue を起点に、
PM / Architect / 開発者 / PjM の 4 サブエージェント体制で自動開発を行うためのテンプレート一式。
Architect は Triage フェーズで「影響範囲が広い／設計判断が必要」と判定された Issue でのみ
自動起動し、軽微な修正ではスキップされる。

Architect が発動した Issue は **設計 PR ゲート**を経由する 2 PR フローで進行する
（`docs/specs/<N>-<slug>/` に要件・設計・タスクをまとめた設計 PR → 人間が merge → 実装 PR）。
Triage フェーズで人間判断が必要な論点を自動抽出し、Issue コメントで確認を取ってから
実装着手する、人間レビュー付き（Human-in-the-Loop）ワークフローを実現する。

---

## 特徴

- **Issue 駆動**: `auto-dev` ラベルが付いた Issue を検出すると、自動でブランチを切り、実装、テスト、PR 作成まで実施
- **人間レビュー内蔵**: 致命的な判断が必要な場合は Issue にコメントで質問を投稿し、人間の回答を待つ
- **ラベルによる状態機械**: 状態遷移はすべて GitHub ラベルで表現され、監査証跡がそのまま残る
- **Triage と実装の二段構え**: 軽量モデルで Triage、Opus 4.7（1M context）で本実装、とコストを最適化
- **規模連動の設計フェーズ**: Triage 時に「新規 API / スキーマ変更 / 複数モジュール影響」などを検出すると Architect が自動で起動し、`docs/specs/<N>-<slug>/{requirements,design,tasks}.md` を生成。軽微な修正ではスキップしてコストと時間を抑える
- **設計 PR ゲート（cc-sdd 風）**: Architect 発動 Issue は、まず spec ディレクトリ（requirements / design / tasks のみ）だけの **設計 PR** を作成して人間レビューを通し、merge されてから初めて実装 PR が別途作られる。GitHub PR レビュー機能（line コメント / suggest-edit）で設計段階の修正が可能
- **Kiro / cc-sdd 互換の記法**: 受入基準は **EARS** 形式（`When [event], the [system] shall ...`）、要件 ID は numeric 階層（`1`, `1.1`, `2.3`）、tasks.md は `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` アノテーション付き。エージェントは `.claude/rules/` のルールを参照して一貫した記法で生成する
- **テスト規約による品質ガードレール**: Developer は AC 起点の Red → Green → Refactor を遵守。異常系・境界値の必須化、モック方針、カバレッジ観点を `CLAUDE.md` で全エージェントに強制し、「テストは通るが受入基準を検証していない」落とし穴を防ぐ
- **2 つのデプロイ形態**:
  - **Local watcher**（推奨）: Claude Max サブスクリプションでローカル実行。Opus 4.7 の 1M context が利用可能
  - **GitHub Actions**: チーム・本番運用向け。API Key / Bedrock / Vertex AI で認証

---

## ディレクトリ構成

```
idd-claude/
├── README.md                        # 本ファイル
├── setup.sh                         # `curl | bash` 対応の bootstrap インストーラ
├── install.sh                       # セットアップ支援スクリプト（clone 後に使う）
├── .gitignore
│
├── repo-template/                   # 開発対象リポジトリに配置するファイル
│   ├── CLAUDE.md                    # プロジェクト全体ガイド（全エージェント共通）
│   ├── .claude/
│   │   ├── agents/
│   │   │   ├── product-manager.md       # PM サブエージェント
│   │   │   ├── architect.md             # Architect サブエージェント（条件付き起動）
│   │   │   ├── developer.md             # Developer サブエージェント
│   │   │   ├── project-manager.md       # PjM サブエージェント
│   │   │   └── qa.md                    # QA サブエージェント（定義のみ・ワークフロー未統合）
│   │   └── rules/                       # エージェントが参照する共通ルール（cc-sdd adapt）
│   │       ├── ears-format.md           # AC の EARS 記法
│   │       ├── requirements-review-gate.md  # PM 自己レビューゲート
│   │       ├── design-principles.md     # design.md 記述原則
│   │       ├── design-review-gate.md    # Architect 自己レビューゲート
│   │       └── tasks-generation.md      # tasks.md アノテーション規約
│   └── .github/
│       ├── ISSUE_TEMPLATE/
│       │   └── feature.yml          # 自動開発用 Issue テンプレート
│       ├── scripts/
│       │   └── idd-claude-labels.sh # ラベル一括作成スクリプト（冪等）
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

### クイックインストール（curl ワンライナー）

`setup.sh` が idd-claude を `$HOME/.idd-claude` にクローンし、同梱の `install.sh` を起動します。
非対話・対話のどちらでも使えます。

**対話モード**（推奨、ターミナル直実行）:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh)
```

**非対話モード**（引数で一気に配置）:

```bash
# 対象ディレクトリに cd してからワンライナー実行（--repo 省略時はカレント = ./）
cd /path/to/your-project
curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
  | bash -s -- --all

# あるいはパス明示
curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
  | bash -s -- --all --repo /path/to/your-project

# 対象リポジトリへの配置のみ（カレントディレクトリ）
curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
  | bash -s -- --repo

# ローカル watcher のみ
curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
  | bash -s -- --local
```

`--repo` に値を渡さなかった場合や `--all` を `--repo` なしで使った場合は、
**カレントディレクトリ (`./`)** にテンプレートを配置します。対話モードでも
プロンプトで Enter のみ入力すると同じくカレントがデフォルトです。

環境変数で挙動を調整できます（特定タグの検証や fork からのインストール向け）:

| 変数 | デフォルト | 用途 |
|---|---|---|
| `IDD_CLAUDE_REPO_URL` | `https://github.com/hitoshiichikawa/idd-claude.git` | クローン元。fork を使う場合に上書き |
| `IDD_CLAUDE_BRANCH` | `main` | チェックアウトするブランチ／タグ |
| `IDD_CLAUDE_DIR` | `$HOME/.idd-claude` | クローン先 |

> **セキュリティ**: `curl \| bash` は実行前の監査が難しいため、信頼できる接続先でのみ利用してください。
> 内容を確認したい場合は `curl -fsSL <URL> -o setup.sh` でダウンロードし、`bash setup.sh` で実行してください。
>
> **sudo は不要**: idd-claude は `$HOME` 配下（`~/.idd-claude` / `~/bin` / `~/Library/LaunchAgents` 等）
> にユーザースコープで配置します。`sudo` で実行するとファイル所有者が root になり、
> 通常ユーザーで更新・削除できなくなるため、setup.sh / install.sh とも root 実行を検知したら
> 警告または停止します。cron 登録もユーザー crontab（`crontab -e`）で行うため sudo 不要です。

手動セットアップ（Git clone 経由）の手順は以下のとおりです。

### Step 1. 対象リポジトリへの配置

開発対象リポジトリに `repo-template/` の中身をコピーする。

```bash
cd /path/to/your-project
cp -r ~/.idd-claude/repo-template/CLAUDE.md ./
cp -r ~/.idd-claude/repo-template/.claude ./
cp -r ~/.idd-claude/repo-template/.github ./

git add CLAUDE.md .claude .github
git commit -m "chore: introduce idd-claude workflow templates"
git push
```

### Step 2. GitHub 側の準備

#### ラベル一括作成（推奨）

Step 1 で同梱される `.github/scripts/idd-claude-labels.sh` を実行すると、必要なラベルを
冪等に作成できます（既存ラベルはスキップ、`--force` で color / description を上書き）。

```bash
cd /path/to/your-project
bash .github/scripts/idd-claude-labels.sh

# 既存ラベルの color / description を更新したい場合
bash .github/scripts/idd-claude-labels.sh --force

# repo 外から実行する場合
bash .github/scripts/idd-claude-labels.sh --repo owner/repo
```

作成されるラベル:

| 名前 | 色 | 用途 |
|---|---|---|
| `auto-dev` | 青 | 自動開発対象 |
| `needs-decisions` | 黄 | 人間の判断が必要 |
| `awaiting-design-review` | 橙 | 設計 PR レビュー待ち（Architect 発動時） |
| `claude-picked-up` | 紫 | Claude Code 実行中 |
| `ready-for-review` | 緑 | 実装 PR 作成完了 |
| `claude-failed` | 赤 | 自動実行が停止 |
| `skip-triage` | 灰 | Triage をスキップ |
| `needs-rebase` | 黄 | approved PR で base 古い／conflict 発生済（Phase A Merge Queue Processor が付与） |
| `needs-iteration` | 紫 | PR レビューコメントの反復対応待ち（PR Iteration Processor #26 が処理） |

#### 手動で作成する場合

```bash
gh label create auto-dev                --repo owner/repo --color 1f77b4 --description "自動開発対象"
gh label create needs-decisions         --repo owner/repo --color f1c40f --description "人間の判断が必要"
gh label create awaiting-design-review  --repo owner/repo --color e67e22 --description "設計 PR レビュー待ち（Architect 発動時）"
gh label create claude-picked-up        --repo owner/repo --color 9b59b6 --description "Claude Code 実行中"
gh label create ready-for-review        --repo owner/repo --color 2ecc71 --description "PR 作成完了"
gh label create claude-failed           --repo owner/repo --color e74c3c --description "自動実行が失敗"
gh label create skip-triage             --repo owner/repo --color 95a5a6 --description "Triage をスキップ"
gh label create needs-rebase            --repo owner/repo --color fbca04 --description "approved PR で base が古い／conflict 発生済（Phase A: Merge Queue Processor が付与）"
gh label create needs-iteration         --repo owner/repo --color d4c5f9 --description "PR レビューコメントの反復対応待ち（#26 PR Iteration Processor が処理）"
```

#### Branch protection（任意）

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
cp ~/.idd-claude/local-watcher/bin/issue-watcher.sh  ~/bin/
cp ~/.idd-claude/local-watcher/bin/triage-prompt.tmpl ~/bin/
chmod +x ~/bin/issue-watcher.sh
```

スクリプト自体は編集不要。`REPO` / `REPO_DIR` は **環境変数で上書きできる** ため、
cron / launchd 側でリポジトリを指定する運用にします（単一 repo でも複数 repo でも同じ手順）。
必要に応じて `$EDITOR ~/bin/issue-watcher.sh` で `TRIAGE_MODEL` / `DEV_MODEL` / `MAX_TURNS`
のデフォルトを調整してください。

#### macOS: launchd に登録

```bash
cp ~/.idd-claude/local-watcher/LaunchAgents/com.local.issue-watcher.plist \
   ~/Library/LaunchAgents/

# plist 内の EnvironmentVariables の REPO / REPO_DIR を自分のリポジトリに書き換える
$EDITOR ~/Library/LaunchAgents/com.local.issue-watcher.plist

launchctl load  ~/Library/LaunchAgents/com.local.issue-watcher.plist
launchctl start com.local.issue-watcher

# 停止したいとき
# launchctl unload ~/Library/LaunchAgents/com.local.issue-watcher.plist
```

#### Linux / WSL: cron に登録

単一リポジトリの場合:

```bash
(crontab -l 2>/dev/null; cat <<'CRON'
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
CRON
) | crontab -
```

複数リポジトリの場合は [複数リポジトリ運用](#複数リポジトリ運用) を参照。

#### 複数リポジトリ運用

`issue-watcher.sh` は **`REPO` / `REPO_DIR` 環境変数で対象を切り替えられる**ため、スクリプトを
コピーせずに 1 ファイルで複数リポジトリを面倒見られます。衝突しやすい下記要素は `REPO`
から自動派生するため、env var を分けるだけで分離されます:

| 項目 | 派生先 |
|---|---|
| `LOCK_FILE` | `/tmp/issue-watcher-<owner>-<repo>.lock`（repo ごとに独立した `flock`） |
| `LOG_DIR` | `$HOME/.issue-watcher/logs/<owner>-<repo>/` |
| Triage 一時 JSON | `/tmp/triage-<owner>-<repo>-<N>-<TS>.json` |

##### cron で複数 repo を回す例

```bash
(crontab -l 2>/dev/null; cat <<'CRON'
# 2 分ごと：repo-a
*/2 * * * * REPO=owner/repo-a REPO_DIR=$HOME/work/repo-a $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
# 3 分ごと：repo-b（時刻をずらすと Claude Max のクォータスパイクを平準化できる）
*/3 * * * * REPO=owner/repo-b REPO_DIR=$HOME/work/repo-b $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
CRON
) | crontab -
```

##### macOS launchd で複数 repo を回す例

plist は **repo ごとに 1 ファイル**用意します（`Label` と `EnvironmentVariables` を
書き換えるだけ）。

```bash
# repo-a 用
cp ~/Library/LaunchAgents/com.local.issue-watcher.plist \
   ~/Library/LaunchAgents/com.local.issue-watcher-repo-a.plist

# repo-b 用（同様にコピーして編集）
cp ~/Library/LaunchAgents/com.local.issue-watcher.plist \
   ~/Library/LaunchAgents/com.local.issue-watcher-repo-b.plist
```

各 plist の編集ポイント:

- `<key>Label</key>` の `<string>` を `com.local.issue-watcher-<repo-slug>` に変更
- `<key>EnvironmentVariables</key>` の dict に下記を追加:
  ```xml
  <key>REPO</key>
  <string>owner/repo-a</string>
  <key>REPO_DIR</key>
  <string>/Users/you/work/repo-a</string>
  ```
- `<key>StandardOutPath</key>` / `<key>StandardErrorPath</key>` も repo ごとに別パスに

すべて編集したら:

```bash
launchctl load  ~/Library/LaunchAgents/com.local.issue-watcher-repo-a.plist
launchctl load  ~/Library/LaunchAgents/com.local.issue-watcher-repo-b.plist
```

##### 運用上の注意

- **Claude Max クォータはアカウント単位で共有**: 複数 repo を同時に回すと 5 時間ウィンドウを
  早く使い切る可能性。`StartInterval` / cron 時刻を repo ごとにずらすとスパイクを抑えられる
- **GitHub API のレート制限も共有**（`gh auth` のトークン単位）: 通常は Issue ポーリング程度では問題ないが、repo が 10+ になるなら別トークン検討
- **個別停止**: launchd は `launchctl unload <plist>` で、cron は該当行をコメントアウトするだけで個別に止められる

### Step 3-B. GitHub Actions をセットアップ（代替）

ワークフローファイル `.github/workflows/issue-to-pr.yml` は **デフォルトで無効**です。
repo 配置直後は何もしないので、ローカル watcher のみで運用する場合は **この Step 全体をスキップしてください**
（ファイルが repo に残っていても問題ありません）。

Actions 経由で自動開発を動かしたい場合のみ、以下を設定します。

#### 1. Repository variable で opt-in

Settings → Secrets and variables → Actions → **Variables** タブ → "New repository variable"

| 名前 | 値 | 意味 |
|---|---|---|
| `IDD_CLAUDE_USE_ACTIONS` | `true` | ワークフロー発火を許可 |

この変数が未設定（または `true` 以外）だと、Issue イベントでワークフローの job が `if:`
条件でスキップされるため何も走りません。ローカル watcher と Actions の二重起動を防ぐ保険にも
なっています。

#### 2. Secrets に認証情報を追加

Settings → Secrets and variables → Actions → **Secrets** タブ

- `ANTHROPIC_API_KEY`（Console で発行）
- または `CLAUDE_CODE_OAUTH_TOKEN`（`claude setup-token` で発行）

`.github/workflows/issue-to-pr.yml` は両方に対応する形でコメントアウトを切り替えるだけで使えます。

---

## 使い方

### 基本フロー

1. リポジトリに Issue を起票する（`.github/ISSUE_TEMPLATE/feature.yml` テンプレートを使うと `auto-dev` ラベルが自動で付く。既存 Issue にあとから付けても良い）
2. 数分以内に Claude Code が Triage を実施する
3. 次のいずれかの結果になる
   - **要決定事項あり**: Issue に決定事項コメントが投稿され、`needs-decisions` ラベルが付く
   - **要決定事項なし・Architect 不要**: PM → Developer → PjM が走り、実装 PR が作成される（1 PR 直行）
   - **要決定事項なし・Architect 必要**: PM → Architect → PjM が走り、**設計 PR** が作成される。Issue に `awaiting-design-review` ラベルが付く
4. 決定事項コメントが付いた場合、人間が Issue コメントで回答し、すべて結論が出たら **`needs-decisions` を外す** → 次回ポーリングで再 Triage
5. 設計 PR が作成された場合、人間が PR をレビュー（必要なら line コメント / suggest-edit / 直接編集）して **merge** する
6. merge 後、Issue から **`awaiting-design-review` ラベルを外す** → 次回ポーリングで Developer が自動起動し、実装 PR が別途作成される
7. 実装 PR が作成されたら人間がレビューして merge する

### Issue の書き方（PM を誤解させないコツ）

`.github/ISSUE_TEMPLATE/feature.yml` は、PM エージェントが誤解なくキャッチできる順序でフィールドを並べています。
自由記述欄でも以下の原則に沿って書くと Triage 精度が上がります。

**書き方の 3 原則**:

- **問題（WHY）を先に書く**: 「何を実装したいか」ではなく「何が困っているか」を先に。PM は問題を起点に最善の解を探します。解決策先行で書くと書かれた案に PM が引きずられがち（別のより良い解を検討しなくなる）
- **観察可能な結果で書く**: 「〜を実装する」ではなく「この操作でこう返る / こう見える」と**ユーザや呼び出し側の視点**で書く。受入基準（EARS 形式）に変換しやすく、粒度も揃います
- **迷ったら "判断を委ねたい点" に書く**: 作成者が決めきれない選択肢は、PM に推測させず「どう迷っているか」を書く。PM が `needs-decisions` ラベルを付けて、人間と合意を取ってから実装に入ります（推測で進めるより安全で速い）

**テンプレートのフィールド**:

| フィールド | 必須 | 目的 |
|---|---|---|
| 種別 | ✓ | 機能追加 / 不具合修正 / リファクタ等。PM のアプローチを切り替える |
| 背景・課題 | ✓ | 解決したい問題（WHY） |
| 現状の挙動 | 不具合/変更時は必須 | 今の動き・再現手順・ログ |
| 期待する挙動・ゴール | ✓ | 観察可能な完了状態 |
| 受入基準の候補 | ✓ | EARS 変換前の原案（PM が整形） |
| スコープ外 | 任意 | 今回含めたくない事項（scope creep 予防） |
| 影響範囲のヒント | 任意 | 触りそうなファイル・モジュール |
| 制約・非機能要件 | 任意 | 後方互換性・性能・セキュリティ等 |
| 参考資料 | 任意 | 関連 Issue/PR/外部 URL |
| 仮案・判断を委ねたい点 | 任意 | 作成者の案（参考）と迷い |
| 優先度 | ✓ | 参考値（実際の着手順は PjM 判断） |

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
| `awaiting-design-review` | 設計 PR レビュー待ち（Architect 発動時） | Claude（Architect 後） |
| `claude-picked-up` | Claude Code 実行中 | Claude |
| `ready-for-review` | 実装 PR 作成完了 | Claude（PjM implementation モード後） |
| `skip-triage` | Triage をスキップ | 人間（任意） |
| `claude-failed` | 自動実行停止中 | Claude（エラー連続時） |
| `needs-rebase` | approved PR で base 古い／conflict 発生済 | Claude（Phase A Merge Queue Processor）／解除は人間が conflict 解消後に手動で除去 |
| `needs-iteration` | PR レビューコメントの反復対応待ち | 人間（レビュワー）が付与／解除は PR Iteration Processor (#26) が成功時 `ready-for-review` に、上限到達時 `claude-failed` に切り替え |

ポーリングクエリ:
```
label:auto-dev
  -label:needs-decisions
  -label:awaiting-design-review
  -label:claude-picked-up
  -label:ready-for-review
  -label:claude-failed
state:open
```

状態遷移図:

```
auto-dev (起票)
   ↓ Triage
   ├─ needs-decisions  ─(人間がラベル除去)─→ 再 Triage
   ├─ awaiting-design-review  ─(人間が設計 PR merge & ラベル除去)─→ impl-resume → ready-for-review
   └─ claude-picked-up  ─→ impl PR 作成 → ready-for-review
```

---

## Merge Queue Processor (Phase A)

local watcher は各サイクルの冒頭（Issue 処理ループに入る前）で **approved 済み open PR の
mergeability を能動的にチェック**し、機械的に解消可能な stale base はその場で rebase + 安全な
force push し、conflict が発生するものには `needs-rebase` ラベルと状況コメントを付けて人間判断に
回します。これにより、approve 後に「base が古いだけ」で待たされたり、merge 直前に conflict が
発覚して再レビューが必要になるケースを早期に検知できます。

> **注**: 親 Issue [#13](https://github.com/hitoshiichikawa/idd-claude/issues/13) の Phase A 実装
> （[#14](https://github.com/hitoshiichikawa/idd-claude/issues/14)）。staging branch（Phase B）や
> Claude Code を起動した semantic conflict 解決（Phase D）はスコープ外です。

> ⚠️ **Branch protection で approve を dismiss する repo では opt-out 推奨**:
> GitHub の Branch protection で「Dismiss stale pull request approvals when new commits are pushed」を
> 有効にしている場合、Phase A の自動 rebase + force push が既存の approve を飛ばします
> （=「approve 後の merge 待ち短縮」という目的と逆行します）。
> 当該設定がある repo では `MERGE_QUEUE_ENABLED=false` のまま運用するか、設定を解除してから
> opt-in してください。Phase D（semantic conflict 解決、[#17](https://github.com/hitoshiichikawa/idd-claude/issues/17)）の
> 導入後は、この挙動を前提とした再レビュー誘導が入る予定です。

### 対象 PR の判定

- 1 件以上の approving review が付いている open PR
- `needs-rebase` / `claude-failed` ラベルが付いていない
- draft 状態ではない
- **head branch が `MERGE_QUEUE_HEAD_PATTERN` に合致**（デフォルト `^claude/`、自動生成 PR のみ）
- **head repo owner が base repo owner と同一**（fork PR を除外）

### 挙動

| `mergeable` 判定 | base 状態 | アクション |
|---|---|---|
| `MERGEABLE` | base が main HEAD の祖先 | スキップ（ログのみ） |
| `MERGEABLE` | base が古い | ローカルで rebase → `git push --force-with-lease`（成功時） |
| `MERGEABLE` | rebase 中 conflict 発生 | `git rebase --abort` → `needs-rebase` ラベル + 状況コメント |
| `CONFLICTING` | — | `needs-rebase` ラベル + 状況コメント（既に付与済なら重複抑止） |
| `UNKNOWN` / 未確定 | — | スキップ（次回サイクルで再判定） |

サイクル終了時に `merge-queue: サマリ: rebase+push=N, conflict=N, skip=N, fail=N, overflow=N`
が watcher ログに出力されます（`grep 'merge-queue:' $HOME/.issue-watcher/logs/...`）。

### 環境変数

| 変数 | デフォルト | 推奨 | 用途 |
|---|---|---|---|
| `MERGE_QUEUE_ENABLED` | `false` | 段階導入時は `false` のまま、検証後 `true` | Merge Queue Processor の有効化 / 無効化（**opt-in**） |
| `MERGE_QUEUE_MAX_PRS` | `5` | watcher 実行間隔と PR 平均量に応じて調整 | 1 サイクルで処理する PR 数の上限。超過分は次回に持ち越し |
| `MERGE_QUEUE_GIT_TIMEOUT` | `60`（秒） | watcher 最短実行間隔の半分以内 | 各 git / gh 操作の個別タイムアウト |
| `MERGE_QUEUE_BASE_BRANCH` | `main` | レガシー repo で `master` の場合のみ上書き | 自動 rebase の対象とする base ブランチ名 |
| `MERGE_QUEUE_HEAD_PATTERN` | `^claude/` | 既存のブランチ命名規則に合わせる | 自動 rebase 対象とする head branch の正規表現。人間が手書きした PR を巻き込まないためのフィルタ（jq `test()` 互換） |

cron 例（opt-in する場合）:

```bash
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo MERGE_QUEUE_ENABLED=true $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
```

`MERGE_QUEUE_ENABLED=true` を渡さない限り、Phase A 機能は完全に無効化されており、Issue 処理
フローは Phase A 導入前と完全に一致します。

### `needs-rebase` ラベル

| 項目 | 内容 |
|---|---|
| 意味 | approved PR で base が古い／conflict が発生済（自動 rebase で解消できなかった） |
| 付与主体 | Phase A Merge Queue Processor（自動）。手動付与も可 |
| 付与契機 | (1) `mergeable=CONFLICTING` を検知時、(2) `MERGEABLE` だが自動 rebase 中に conflict 発生時 |
| 解除主体 | **人間**（手動 rebase / Phase D 自動解消後） |
| 解除タイミング | conflict が解消し PR が再度 mergeable になった後、ラベルを手動で除去 → 次回サイクルで再判定 |
| 重複抑止 | 既にラベルが付いている PR には再付与・重複コメントを行わない（API call と通知ノイズの抑制） |

ラベル一括作成スクリプト（`.github/scripts/idd-claude-labels.sh`）には Phase A で `needs-rebase`
ラベルが追加されています。既存 repo に対しては再実行で冪等に追加されます:

```bash
bash .github/scripts/idd-claude-labels.sh
```

#### 既知の制限: `needs-rebase` ラベルの自動解除は Phase A のスコープ外

Phase A の Merge Queue Processor は対象 PR 検索クエリに `-label:"needs-rebase"` を含めて除外する
ため、**一度 `needs-rebase` が付いた PR は自動では再評価されません**。以下のようなケースで
ラベルが取り残されます:

- 人間が手動で conflict 解消した後、ラベルを外し忘れた → PR は永久に Phase A の対象外
- base branch が revert されて transient な conflict が自然解消した → ラベルが残り続ける

**現状の対処**: conflict 解消後は **人間が手動でラベルを外す**。外せば次回 watcher サイクルで
自動的に再評価されます:

```bash
# ラベル除去（GitHub UI からも可）
gh pr edit <PR番号> --repo owner/your-repo --remove-label needs-rebase
```

**将来対応**: [#27](https://github.com/hitoshiichikawa/idd-claude/issues/27) で「`needs-rebase` 付き PR を別ループで定期再評価し、`mergeable=MERGEABLE` に戻った PR のラベルを自動除去」する機能を追跡中（`MERGE_QUEUE_RECHECK_ENABLED` で opt-in 予定）。

### Migration Note（既存ユーザー向け）

Phase A 導入による後方互換性は以下のとおり保証されます:

- **既存環境変数は不変**: `REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`,
  `DEV_MODEL`, `TRIAGE_MAX_TURNS`, `DEV_MAX_TURNS`, `TRIAGE_TEMPLATE` の名前・意味・デフォルトは変更なし
- **既存ラベルは不変**: `auto-dev` / `claude-picked-up` / `awaiting-design-review` /
  `ready-for-review` / `claude-failed` / `needs-decisions` / `skip-triage` の名前・意味・付与契約は変更なし
- **lock ファイル / ログ出力先 / exit code の意味は不変**: `LOCK_FILE` パス、`LOG_DIR` 配下への
  ログ出力先、watcher の exit code は Phase A 導入前と同一
- **Phase A 機能はデフォルト無効**: `MERGE_QUEUE_ENABLED` のデフォルトは `false`（**opt-in**）。
  既存環境を壊すことなく段階的に有効化できる
- **新規追加コマンド**: Phase A は `timeout` コマンドに依存します（Linux 標準 / macOS は `coreutils`）。
  既存環境で利用可能か確認してください
- **新規ラベル `needs-rebase` は冪等追加**: `idd-claude-labels.sh` を再実行すれば既存環境にも追加されます
- **head branch / fork PR フィルタを追加**: `MERGE_QUEUE_HEAD_PATTERN`（デフォルト `^claude/`）に合致する
  head branch かつ、head repo owner が base repo owner と同一の PR のみが対象。既存の自動生成 PR 命名
  （`claude/issue-<N>-...`）はそのままマッチするので、追加設定不要。自作 PR に適用したい場合のみ上書き

依存追加・既存挙動への影響は上記のみで、`MERGE_QUEUE_ENABLED=false`（デフォルト）の状態では
Phase A コードパスは完全に skip されます。

### ⚠️ merge 後の再配置が必要

`local-watcher/bin/issue-watcher.sh` を変更する PR を merge しただけでは、**cron / launchd が実行する
`$HOME/bin/issue-watcher.sh` は古いまま**です。反映するには以下のどちらかを実施してください:

```bash
# 方法1: install.sh の --local を再実行（推奨、triage-prompt.tmpl も同期される）
cd ~/.idd-claude && git pull && ./install.sh --local

# 方法2: 手動コピー（idd-claude clone がある場合）
cp /path/to/idd-claude/local-watcher/bin/issue-watcher.sh $HOME/bin/issue-watcher.sh
```

この手順は **Phase A に限らず watcher を変更するすべての PR 共通**です。

---

## PR Iteration Processor (#26)

local watcher は Phase A の Merge Queue Processor 直後に **`needs-iteration` ラベルが付いた
idd-claude 管理下 PR を fresh context の Claude で反復対応する Processor** を実行します。
人間レビュワーは PR の line コメント / `@claude` mention 付き general コメントを残して
`needs-iteration` ラベルを 1 つ付けるだけで、watcher が次サイクルで:

1. 最新 review の line コメントと `@claude` mention general コメントを Claude に渡し
2. 必要なら修正 commit を head branch に **通常 push（force push 禁止）** で積み
3. 各 review thread に「何をどう修正したか / なぜ対応しないか」を 1:1 で返信し
4. ラベルを `needs-iteration` → `ready-for-review` に切り替える

までを 1 round で実施します。Phase A の merge queue 処理と同じ flock 境界内で **直列実行**
されるため、同一ローカル working copy への競合は発生しません。

> **注**: 親 Issue [#26](https://github.com/hitoshiichikawa/idd-claude/issues/26)。
> 各 round は前回の会話履歴を引き継がない fresh context で起動されます（`--resume` / `--continue`
> は使いません）。`PR_ITERATION_MAX_ROUNDS`（既定 3）を超えた PR は `claude-failed` に昇格して
> 自動 iteration を停止し、人間に明示的にエスカレーションします。

> ⚠️ **本機能は private / 信頼できる collaborator のみがレビューする repo で使うこと**:
> 反復対応は line コメント本文をそのまま Claude に prompt として渡します。レビュー権限を
> 持つアカウントが信頼境界内にあることを前提とし、不特定多数からの prompt injection リスクが
> 残らない運用環境（自己ホスト / 社内 repo / 信頼できる contributor のみ）で利用してください。
> 公開 OSS の external contributor PR には適用しません（fork PR は head owner 比較で除外、
> 後述）。

### 対象 PR の判定

- `needs-iteration` ラベルが付いている open PR
- `claude-failed` / `needs-rebase` ラベルが付いていない（Phase A と排他）
- draft 状態ではない
- **head branch が `PR_ITERATION_HEAD_PATTERN` に合致**（デフォルト `^claude/`、自動生成 PR のみ）
- **head repo owner が base repo owner と同一**（fork PR を除外）

### 挙動

| 状況 | アクション |
|---|---|
| 候補 PR を検出 → round < MAX | hidden marker 更新 + 着手表明コメント → fresh context で Claude 起動 |
| Claude 成功（commit+push or reply-only） | `needs-iteration` 除去 + `ready-for-review` 付与 |
| Claude 失敗（exit 非 0、turn 上限、push 失敗等） | `needs-iteration` を残置 + WARN ログ、次サイクルで再試行 |
| 累計 round が `MAX_ROUNDS` に到達 | `needs-iteration` 除去 + `claude-failed` 付与 + エスカレコメント |
| `needs-rebase` 併存 | 本機能は skip（Phase A に処理を委ねる） |
| dirty working tree 検知 | サイクル全体で本機能を skip（ERROR ログ）、後続 Issue 処理は継続 |

サイクル終了時に `pr-iteration: サマリ: success=N, fail=N, skip=N, escalated=N, overflow=N`
が watcher ログに出力されます（`grep 'pr-iteration:' $HOME/.issue-watcher/logs/...`）。

### 環境変数

| 変数 | デフォルト | 推奨 | 用途 |
|---|---|---|---|
| `PR_ITERATION_ENABLED` | `false` | 段階導入時は `false` のまま、検証後 `true` | PR Iteration Processor の有効化 / 無効化（**opt-in**） |
| `PR_ITERATION_DEV_MODEL` | `claude-opus-4-7` | 既存の `DEV_MODEL` と同じ運用方針 | iteration 用の Claude モデル ID |
| `PR_ITERATION_MAX_TURNS` | `60` | 通常レビュー対応で十分。多い場合は対象 PR が大きすぎる兆候 | 1 iteration の Claude 実行 turn 数上限 |
| `PR_ITERATION_MAX_PRS` | `3` | watcher 実行間隔と PR 平均量に応じて調整 | 1 サイクルで処理する PR 数の上限。超過分は次回に持ち越し |
| `PR_ITERATION_MAX_ROUNDS` | `3` | 試行回数を抑えて自動エスカレを早めに | 1 PR あたりの累計 iteration 上限。超過時は `claude-failed` 昇格 |
| `PR_ITERATION_HEAD_PATTERN` | `^claude/` | 既存ブランチ命名規則に合わせる（Phase A と同値推奨） | 自動 iteration 対象とする head branch の正規表現（jq `test()` 互換） |
| `PR_ITERATION_GIT_TIMEOUT` | `60`（秒） | watcher 最短実行間隔の半分以内 | 各 git / gh 操作の個別タイムアウト |

cron 例（opt-in する場合）:

```bash
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo MERGE_QUEUE_ENABLED=true PR_ITERATION_ENABLED=true $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
```

`PR_ITERATION_ENABLED=true` を渡さない限り、本機能は完全に無効化されており、Issue 処理
フローは導入前と完全に一致します（Phase A も独立した env で opt-in）。

### `needs-iteration` ラベル

| 項目 | 内容 |
|---|---|
| 意味 | PR レビューコメントへの自動反復対応待ち |
| 付与主体 | **人間レビュワー**（review コメントを残してから付与）。手動付与のみ |
| 付与契機 | 人間が line コメント / `@claude` mention general コメントを残し、Claude に取り込んでほしいタイミング |
| 解除主体 | **PR Iteration Processor**（成功時）／**人間**（自動 iteration を止めたい時） |
| 解除タイミング | (1) iteration 成功 → 自動で `ready-for-review` に付け替え、(2) 上限到達 → 自動で `claude-failed` に付け替え |
| 重複抑止 | 着手中の hidden marker（PR body 末尾）でラウンド数を観測。複数 watcher プロセス間は flock で排他 |

#### iteration カウンタの仕組み（hidden marker）

PR body の末尾に `<!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->` 形式の
HTML コメントを書き込み、累計 round を永続化します。`gh pr view --json body` で読み取り可能、
かつ人間が PR body から手動削除すれば counter が 0 にリセットされる設計です。

#### counter リセット手順（上限到達後の再開）

`PR_ITERATION_MAX_ROUNDS` に到達して `claude-failed` ラベルが付いた PR について、
人間が修正の上で自動 iteration を再開したい場合の手順:

```bash
# 1. PR body から marker 行を削除（GitHub UI でも可）
gh pr view <PR番号> --repo owner/your-repo --json body --jq '.body' \
  | sed -E 's/<!-- idd-claude:pr-iteration round=[0-9]+ [^>]*-->//g' \
  | gh pr edit <PR番号> --repo owner/your-repo --body-file -

# 2. claude-failed ラベルを除去
gh pr edit <PR番号> --repo owner/your-repo --remove-label claude-failed

# 3. needs-iteration を再付与
gh pr edit <PR番号> --repo owner/your-repo --add-label needs-iteration
```

次回 watcher サイクルで round=0 から再開されます。

### Phase A との住み分け

| 状況 | Phase A | PR Iteration Processor |
|---|---|---|
| `needs-rebase` 単独 | 対象（rebase または手動依頼コメント） | 対象外（除外フィルタ） |
| `needs-iteration` 単独 | 対象外（approved 必須） | 対象 |
| `needs-iteration` + `needs-rebase` 併存 | Phase A は通常通り処理を試行 | 本機能は skip（Phase A に委譲） |
| `needs-iteration` + `claude-failed` 併存 | 対象外 | 対象外（自動処理停止） |

両者は **対象 PR 集合が直交** するため、同一 watcher プロセス内の直列実行で安全に共存します。
追加の lock は導入していません。

### Migration Note（既存ユーザー向け）

PR Iteration Processor 導入による後方互換性は以下のとおり保証されます:

- **既存環境変数は不変**: `REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`,
  `DEV_MODEL`, `TRIAGE_MAX_TURNS`, `DEV_MAX_TURNS`, `TRIAGE_TEMPLATE`, `MERGE_QUEUE_*`
  の名前・意味・デフォルトは変更なし
- **既存ラベルは不変**: `auto-dev` / `claude-picked-up` / `awaiting-design-review` /
  `ready-for-review` / `claude-failed` / `needs-decisions` / `skip-triage` / `needs-rebase`
  の名前・意味・付与契約は変更なし
- **lock ファイル / ログ出力先 / exit code の意味は不変**: `LOCK_FILE` パス、`LOG_DIR` 配下への
  ログ出力先、watcher の exit code は導入前と同一
- **本機能はデフォルト無効**: `PR_ITERATION_ENABLED` のデフォルトは `false`（**opt-in**）。
  既存環境を壊すことなく段階的に有効化できる
- **依存コマンドの追加なし**: 既存の `gh` / `jq` / `git` / `flock` / `timeout` / `claude` のみ
  で動作（Phase A で `timeout` は既に依存）
- **新規ラベル `needs-iteration` は冪等追加**: `idd-claude-labels.sh` を再実行すれば既存環境にも
  追加されます

`PR_ITERATION_ENABLED=false`（デフォルト）の状態では PR Iteration コードパスは完全に skip
されるため、既存運用への影響はありません。

### ⚠️ merge 後の再配置が必要

Phase A と同様、watcher 関連ファイルを変更する PR を merge しただけでは
`$HOME/bin/issue-watcher.sh` および `$HOME/bin/iteration-prompt.tmpl` は古いままです。
反映するには:

```bash
# 推奨: install.sh の --local 再実行（iteration-prompt.tmpl も同期される）
cd ~/.idd-claude && git pull && ./install.sh --local
```

その後、ラベル一括作成スクリプトを再実行して `needs-iteration` ラベルを冪等追加します:

```bash
cd /path/to/your-project
bash .github/scripts/idd-claude-labels.sh
```

最後に cron / launchd 設定に `PR_ITERATION_ENABLED=true` を追加して opt-in します。

---

## サブエージェント構成

| 役割 | 目的 | 主なツール | 推奨モデル | 起動条件 |
|---|---|---|---|---|
| **Product Manager** | Issue → 仕様書化 | Read / Grep / WebSearch / Write | Opus 4.7 | 毎回 |
| **Architect** | 仕様書 → 設計書 | Read / Grep / Glob / Write | Opus 4.7 | Triage で `needs_architect: true` のとき |
| **Developer** | 仕様書（＋設計書） → 動くコード | Edit / Write / Bash / Grep | Opus 4.7 | 毎回 |
| **Project Manager** | ブランチ push / PR 作成 / ラベル管理 | Bash（`gh` CLI） | Sonnet 4.6 | 毎回 |
| **QA**（未適用） | 実装・テストの独立レビュー | Read / Grep / Glob / Bash / Write | Opus 4.7 | 定義のみ保持・手動起動用（自動ワークフロー未統合） |

### Architect の自動起動判定

Triage フェーズで出力される JSON の `needs_architect` フィールドにより決まります。
以下のいずれかに該当する Issue で `true` となり、設計 PR ゲートを経由する 2 PR フローで進行します。

- 新規 API エンドポイント／公開インターフェースの追加
- データベーススキーマ・永続データ構造の変更
- 3 モジュール以上にまたがる変更
- 新規の外部サービス・ライブラリ連携の追加
- 既存アーキテクチャ（レイヤ構成・認証方式・通信プロトコル等）の変更

軽微な修正（バグ修正・文言変更・既存関数内のロジック改善・テスト追加のみなど）では `false` となり、
`PM → Developer → PjM` の 1 PR 直行で進みます。`skip-triage` ラベルが付いた Issue は判定を
スキップし `false` 扱い（＝ Architect なし）になります。

GitHub Actions 版では Triage ステップを持たないため、PM が requirements.md を書いた直後に
オーケストレーター自身が同じ基準で Architect の要否を自己判定します
（`.github/workflows/issue-to-pr.yml` 参照）。

### 設計 PR ゲート（2 PR フロー）

Architect が発動した Issue は、**設計 PR** と **実装 PR** の 2 つに分けて進行します。

#### フェーズ 1: 設計 PR 作成

1. PM が `docs/specs/<N>-<slug>/requirements.md` を生成
2. Architect が `docs/specs/<N>-<slug>/design.md` と `tasks.md` を生成
3. PjM が **design-review モード**で設計 PR を作成
   - title: `spec(#<N>): <要約>`
   - 含まれるのは spec ディレクトリの 3 ファイルのみ（実装コードなし）
   - Issue ラベル: `claude-picked-up` → `awaiting-design-review`

#### フェーズ 2: 人間による設計レビュー

- **問題なし**: PR を merge する → `awaiting-design-review` ラベルを Issue から外す
- **要修正**: PR に直接 commit / suggest-edit / line comment で指摘 → 修正後 merge
- **やり直し**: PR を close し、Issue から `awaiting-design-review` を外すと再 Triage

#### フェーズ 3: 実装 PR 作成（impl-resume モード）

- watcher / Actions が次回発火時、`docs/specs/<N>-*/` が main に存在することを検出し `impl-resume` モードに入る
- Developer が design.md / tasks.md を入力として実装を行う（これらは **書き換えない**）
- PjM が **implementation モード**で実装 PR を作成
   - title: `feat(#<N>): <要約>`
   - PR 本文に関連 PR として設計 PR 番号を記載
   - Issue ラベル: `claude-picked-up` → `ready-for-review`

#### ディレクトリ構造

```
docs/specs/<N>-<slug>/
├── requirements.md   # PM 成果物（設計 PR に含まれる）
├── design.md         # Architect 成果物（設計 PR に含まれる）
├── tasks.md          # Architect 成果物（設計 PR に含まれる）
└── impl-notes.md     # Developer 成果物（実装 PR に含まれる）
```

`<slug>` は Issue タイトルを lowercase / ハイフン区切り / 40 文字以内に正規化した値。
設計 PR merge 後に既存ディレクトリが検出された場合、slug はそのまま再利用されます。

### QA エージェントについて（現時点では未適用）

`qa.md` は、実装コードとテストを spec の受入基準に照らして独立レビューする観点で定義しています。
ただし **現時点では自動ワークフロー（Triage / ローカル watcher / GitHub Actions）には
組み込まれていません**。定義ファイルだけ同梱しているため、認証・決済・スキーマ変更・
外部 API 連携など高リスクな Issue に対して、対話セッションから `qa` サブエージェントを
手動で呼び出してレビューを依頼する運用が可能です。将来的に Triage 判定と連動させて
自動起動する拡張を検討しています。

詳細は `repo-template/.claude/agents/*.md` を参照。

### 共通ルール（`.claude/rules/`）

エージェント横断で参照される記法・レビューゲートのルール群。[cc-sdd](https://github.com/gotalab/cc-sdd)
（MIT License, Copyright gotalab）から adapt しています。

| ルール | 参照元 | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC を EARS 5 パターン（Event / State / Unwanted / Optional / Ubiquitous）で記述 |
| `requirements-review-gate.md` | PM | requirements.md ドラフトの自己レビュー（Mechanical + 判断、最大 2 パス） |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー（Requirements Traceability / File Structure Plan 充填 / orphan 検出） |
| `tasks-generation.md` | Architect / Developer | tasks.md の numeric 階層 ID とアノテーション（`_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)`） |

### cc-sdd との関係

idd-claude は [cc-sdd](https://github.com/gotalab/cc-sdd) の仕様記法・レビューゲート・テンプレートを
取り込んでいます（Issue 駆動ワークフロー・ラベル状態機械・設計 PR ゲート等は idd-claude 固有）。
以下は **取り込んでいない**／**将来検討**の要素:

- `/kiro-discovery` / `/kiro-spec-init` 等のスラッシュコマンド体系 → idd-claude は Issue 駆動のため不採用
- steering docs 3 分割（product / tech / structure）→ 現状は `CLAUDE.md` 一本で足りる
- **`/kiro-impl` 相当の per-task TDD 自走ループ**（Implementer / Reviewer / Debugger trio）
  → 別 Issue として分離済。[#3](https://github.com/hitoshiichikawa/idd-claude/issues/3) を参照

---

## 品質ガードレール

自動開発で陥りがちな「テストは通るが受入基準を検証していない」「モックが過剰で本番挙動と乖離する」
といった落とし穴を、エージェント共通ルールとして明示的に防ぎます。
詳細は [`repo-template/CLAUDE.md`](repo-template/CLAUDE.md) と
[`repo-template/.claude/agents/developer.md`](repo-template/.claude/agents/developer.md) を参照してください。

### テスト規約（CLAUDE.md で全エージェントに強制）

- **粒度の使い分け**: 単体 / 結合 / E2E をそれぞれの責務で分離（過剰に E2E で網羅しない）
- **命名と構造**: `describe('対象') > it('<条件>のとき<期待結果>')` 形式、AAA（Arrange / Act / Assert）に分離
- **1 テスト 1 検証**: 1 つの `it` で複数観点をまとめない
- **モック方針**: HTTP / DB / 時刻 / ファイル等の外部副作用のみモック。内部ロジックはモックしない
- **カバレッジ**: 変更箇所の分岐を全カバーを目標（全体カバレッジ率は KPI にしない）
- **異常系の必須化**: 各 AC に対し異常系・境界値・空入力を最低 1 ケース追加
- **flaky テスト**: quarantine せず、修正 or 削除。一時 skip は即 Issue 化

### Developer の実装フロー（developer.md で規定）

1. 対応する AC からテストケース一覧を**先に**書き出す（正常系・異常系・境界値を含める）
2. テストを書き、**いったん失敗することを確認**してから実装で通す（Red → Green → Refactor）
3. 失敗した既存テストを書き換えて通さない → 実装側の問題として調査
4. Snapshot は差分が実装変更の意図と一致するか確認してから更新（盲目的な `-u` 禁止）

### 禁止行為

- テストをコメントアウトして PR を出すこと
- テストを通すために実装ではなくテスト側を弱めること（過剰モック / assert 緩め / snapshot 盲目更新）
- `main` ブランチへの直接 push
- `.env` や Secrets の実値コミット

---

## トラブルシューティング

### `claude` コマンドが見つからない

cron / launchd は対話シェルのプロファイルを読み込まないため、`PATH` が通っていないことが多い。
`issue-watcher.sh` 側で `~/.local/bin` / `/usr/local/bin` / `/opt/homebrew/bin` を冒頭で `PATH` に
追加しているため、標準的なインストール先であれば追加設定は不要。
それ以外の場所に `claude` / `gh` がある場合は、launchd なら plist の `EnvironmentVariables`、
cron なら `crontab -e` の先頭で `PATH=...` を明示する。

### OAuth 認証が切れた

ローカルで `claude /login` を再実行する。1 年程度で切れることがある。

### Max 利用枠を使い切った

深夜に Issue が集中すると 5 時間ウィンドウを消費しきる場合がある。
`issue-watcher.sh` の `MAX_TURNS` を下げるか、Triage を Sonnet 4.6、本実装も Sonnet 4.6 に落とす。

### `/context` が 1M になっていない

`/logout` → `/login` で一度ログインし直す。それでも直らない場合は
Anthropic の既知バグの可能性（[#47019](https://github.com/anthropics/claude-code/issues/47019) 等）。

### 多重起動される（同一 repo）

`issue-watcher.sh` は `flock` で単一インスタンス化している。`LOCK_FILE` は `REPO` から
`/tmp/issue-watcher-<owner>-<repo>.lock` として自動派生するため、**同一 repo での多重起動は
自動で防がれる**。複数 repo を並行稼働させるときは repo ごとに別 lock になるため並列実行される。

効かなくなるケース:
- `/tmp` が消えている（再起動直後のレース）
- 別ユーザーで実行している（lock ファイルの所有者が違う）
- `REPO` env var を渡さずスクリプト内蔵のデフォルト値で走っている（全 repo が同じ lock を取り合う）

常に同じユーザー・一貫した `REPO` env var で実行すること。

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
- [cc-sdd](https://github.com/gotalab/cc-sdd) — spec-driven development harness（本リポジトリの rules 群の adapt 元）
- [Kiro IDE](https://kiro.dev) / [Kiro's Spec Methodology](https://kiro.dev/docs/specs/) — 設計 PR ゲート・EARS・traceability の出どころ
- [Zenn: cc-sdd の全体フロー](https://zenn.dev/tmasuyama1114/articles/cc_sdd_whole_flow)

## ライセンス・謝辞

- 本リポジトリは MIT License
- `repo-template/.claude/rules/*.md` は [cc-sdd](https://github.com/gotalab/cc-sdd)
  （MIT License, Copyright gotalab）の rules / templates から adapt したもの。
  各ファイル冒頭に SPDX ヘッダと出典を明記
