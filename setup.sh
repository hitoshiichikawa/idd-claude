#!/usr/bin/env bash
# =============================================================================
# idd-claude bootstrap installer (curl | bash 対応)
#
# このスクリプトは idd-claude を `$HOME/.idd-claude` にクローン（既にあれば更新）し、
# そのうえで同梱の `install.sh` を起動します。
#
# 使い方（すべて推奨順）:
#
# 1) 対話モード（ターミナル直実行）:
#      bash <(curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh)
#
# 2) curl パイプ + 引数指定（非対話）:
#      curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh \
#        | bash -s -- --repo /path/to/your-project --local
#
# 3) curl パイプ（対話、対応可能なシェル限定）:
#      curl -fsSL https://raw.githubusercontent.com/hitoshiichikawa/idd-claude/main/setup.sh | bash
#      → stdin を /dev/tty に再接続して install.sh の対話プロンプトに入る
#
# オプション（install.sh に転送される）:
#   --repo /path/to/your-project   対象リポジトリにテンプレートを配置
#   --local                        ローカル PC に watcher をインストール
#   --all --repo /path             両方
#   -h | --help                    install.sh のヘルプを表示
#
# 環境変数で挙動を上書き:
#   IDD_CLAUDE_REPO_URL   クローン元 URL（デフォルト: upstream の main）
#   IDD_CLAUDE_BRANCH     チェックアウトするブランチ／タグ（デフォルト: main）
#   IDD_CLAUDE_DIR        クローン先パス（デフォルト: $HOME/.idd-claude）
#
# セキュリティ注意:
#   `curl | bash` はスクリプトが実行前に任意コードを走らせるため、接続先を十分信頼できる
#   場合のみ利用してください。監査したい場合は `curl -fsSL <URL> -o setup.sh` で一度
#   ダウンロードして中身を確認してから `bash setup.sh` を実行するのが安全です。
# =============================================================================

set -euo pipefail

IDD_CLAUDE_REPO_URL="${IDD_CLAUDE_REPO_URL:-https://github.com/hitoshiichikawa/idd-claude.git}"
IDD_CLAUDE_BRANCH="${IDD_CLAUDE_BRANCH:-main}"
IDD_CLAUDE_DIR="${IDD_CLAUDE_DIR:-$HOME/.idd-claude}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# sudo 実行の検知と警告
#   idd-claude は $HOME 配下にユーザースコープで配置するため sudo は不要。
#   sudo で実行するとファイル所有者が root になり、後からユーザーで更新できなくなる。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "⚠️  sudo で実行されています。idd-claude はユーザースコープ（\$HOME 配下）に" >&2
  echo "   インストールする前提のため sudo は不要です。続行するとファイル所有者が" >&2
  echo "   root になり、通常ユーザーで更新できなくなる可能性があります。" >&2
  echo "   sudo を外して再実行してください。" >&2
  exit 1
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提コマンドチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in git bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' が見つかりません。先にインストールしてください。" >&2
    exit 1
  fi
done

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# クローン（未取得） or 更新（既存）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ -d "$IDD_CLAUDE_DIR/.git" ]; then
  echo "📦 既存のクローンを更新: $IDD_CLAUDE_DIR (branch=$IDD_CLAUDE_BRANCH)"
  git -C "$IDD_CLAUDE_DIR" fetch --quiet --depth 1 origin "$IDD_CLAUDE_BRANCH"
  git -C "$IDD_CLAUDE_DIR" checkout --quiet "$IDD_CLAUDE_BRANCH" 2>/dev/null || true
  git -C "$IDD_CLAUDE_DIR" reset --hard --quiet "origin/$IDD_CLAUDE_BRANCH"
else
  echo "📦 idd-claude をクローン: $IDD_CLAUDE_DIR (branch=$IDD_CLAUDE_BRANCH)"
  # 既存の非 git ディレクトリがある場合は安全のため停止
  if [ -e "$IDD_CLAUDE_DIR" ]; then
    echo "Error: '$IDD_CLAUDE_DIR' は git リポジトリではありません。移動または削除してから再実行してください。" >&2
    exit 1
  fi
  git clone --quiet --depth 1 --branch "$IDD_CLAUDE_BRANCH" \
    "$IDD_CLAUDE_REPO_URL" "$IDD_CLAUDE_DIR"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# curl パイプ経由の場合は stdin を /dev/tty に再接続
#   （install.sh の対話プロンプト `read -r -p` を動作させるため）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ ! -t 0 ] && ( : </dev/tty ) 2>/dev/null; then
  exec </dev/tty
fi

echo ""
echo "🚀 install.sh を起動します"
echo ""
exec bash "$IDD_CLAUDE_DIR/install.sh" "$@"
