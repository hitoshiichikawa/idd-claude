#!/usr/bin/env bash
# =============================================================================
# idd-claude install helper
#
# このスクリプトは idd-claude の各ファイルを適切な場所にコピーします。
# 対象リポジトリへの配置・ローカル PC へのインストール・両方を選択可能。
#
# 使い方:
#   ./install.sh            # 対話モードで聞きながら進める
#   ./install.sh --repo /path/to/your-project
#   ./install.sh --local
#   ./install.sh --all --repo /path/to/your-project
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TEMPLATE_DIR="$SCRIPT_DIR/repo-template"
LOCAL_WATCHER_DIR="$SCRIPT_DIR/local-watcher"

REPO_PATH=""
INSTALL_LOCAL=false
INSTALL_REPO=false

# 引数パース
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      REPO_PATH="$2"
      INSTALL_REPO=true
      shift 2
      ;;
    --local)
      INSTALL_LOCAL=true
      shift
      ;;
    --all)
      INSTALL_LOCAL=true
      INSTALL_REPO=true
      shift
      ;;
    -h|--help)
      sed -n '3,14p' "$0"
      exit 0
      ;;
    *)
      echo "未知のオプション: $1" >&2
      exit 1
      ;;
  esac
done

# 対話モード（引数なし）
if ! $INSTALL_LOCAL && ! $INSTALL_REPO; then
  echo "=== idd-claude install ==="
  echo ""
  read -r -p "対象リポジトリにテンプレートを配置しますか？ [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -r -p "  対象リポジトリのパス (例: ~/github/my-repo): " REPO_PATH
    REPO_PATH="${REPO_PATH/#\~/$HOME}"
    INSTALL_REPO=true
  fi
  read -r -p "ローカル PC に watcher をインストールしますか？ [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    INSTALL_LOCAL=true
  fi
fi

# ─────────────────────────────────────────────────────────────
# 対象リポジトリへの配置
# ─────────────────────────────────────────────────────────────
if $INSTALL_REPO; then
  if [ -z "$REPO_PATH" ] || [ ! -d "$REPO_PATH" ]; then
    echo "Error: リポジトリパスが不正です: $REPO_PATH" >&2
    exit 1
  fi

  echo ""
  echo "📦 対象リポジトリにファイルを配置: $REPO_PATH"

  # CLAUDE.md は既存があればバックアップ
  if [ -f "$REPO_PATH/CLAUDE.md" ]; then
    echo "  既存の CLAUDE.md を CLAUDE.md.bak にバックアップ"
    cp "$REPO_PATH/CLAUDE.md" "$REPO_PATH/CLAUDE.md.bak"
  fi

  cp -v "$REPO_TEMPLATE_DIR/CLAUDE.md" "$REPO_PATH/CLAUDE.md"

  mkdir -p "$REPO_PATH/.claude/agents"
  cp -v "$REPO_TEMPLATE_DIR/.claude/agents/"*.md "$REPO_PATH/.claude/agents/"

  mkdir -p "$REPO_PATH/.github/ISSUE_TEMPLATE"
  cp -v "$REPO_TEMPLATE_DIR/.github/ISSUE_TEMPLATE/feature.yml" \
        "$REPO_PATH/.github/ISSUE_TEMPLATE/feature.yml"

  mkdir -p "$REPO_PATH/.github/workflows"
  cp -v "$REPO_TEMPLATE_DIR/.github/workflows/issue-to-pr.yml" \
        "$REPO_PATH/.github/workflows/issue-to-pr.yml"

  echo ""
  echo "  ✅ 配置完了。次の手順:"
  echo "     1. CLAUDE.md をプロジェクト固有の内容に編集"
  echo "     2. .github/workflows/issue-to-pr.yml の認証方式を選択"
  echo "     3. git add / commit / push"
  echo "     4. GitHub で必要なラベルを作成（README 参照）"
fi

# ─────────────────────────────────────────────────────────────
# ローカル PC への watcher インストール
# ─────────────────────────────────────────────────────────────
if $INSTALL_LOCAL; then
  echo ""
  echo "📦 ローカル PC に watcher をインストール"

  mkdir -p "$HOME/bin" "$HOME/.issue-watcher/logs"
  cp -v "$LOCAL_WATCHER_DIR/bin/issue-watcher.sh"   "$HOME/bin/"
  cp -v "$LOCAL_WATCHER_DIR/bin/triage-prompt.tmpl" "$HOME/bin/"
  chmod +x "$HOME/bin/issue-watcher.sh"

  # macOS: launchd
  if [ "$(uname)" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cp -v "$LOCAL_WATCHER_DIR/LaunchAgents/com.local.issue-watcher.plist" \
          "$HOME/Library/LaunchAgents/"

    echo ""
    echo "  ✅ 配置完了。次の手順:"
    echo "     1. ~/bin/issue-watcher.sh の先頭 Config ブロックを編集"
    echo "        - REPO: owner/your-repo"
    echo "        - REPO_DIR: ローカルの git clone のパス"
    echo "     2. launchctl load ~/Library/LaunchAgents/com.local.issue-watcher.plist"
    echo "     3. launchctl start com.local.issue-watcher"
    echo "     4. ログ: tail -f /tmp/issue-watcher.stderr.log"
  else
    echo ""
    echo "  ✅ 配置完了。次の手順:"
    echo "     1. ~/bin/issue-watcher.sh の先頭 Config ブロックを編集"
    echo "     2. cron に登録:"
    echo "        (crontab -l; echo '*/2 * * * * \$HOME/bin/issue-watcher.sh >> \$HOME/.issue-watcher/cron.log 2>&1') | crontab -"
  fi

  # 前提ツールチェック
  echo ""
  echo "🔍 前提ツールをチェック:"
  MISSING=()
  for cmd in gh jq claude git flock; do
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "  ✅ $cmd: $(command -v "$cmd")"
    else
      echo "  ❌ $cmd が見つかりません"
      MISSING+=("$cmd")
    fi
  done

  if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo "  以下のコマンドをインストールしてください: ${MISSING[*]}"
    if [ "$(uname)" = "Darwin" ]; then
      echo "  macOS の場合: brew install gh jq util-linux"
      echo "  Claude Code:  npm install -g @anthropic-ai/claude-code"
    fi
  fi
fi

echo ""
echo "🎉 idd-claude のインストールが完了しました。"
echo "   詳細は README.md を参照してください。"
