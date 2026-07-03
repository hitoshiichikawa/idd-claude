#!/usr/bin/env bash
# =============================================================================
# idd-claude install helper
#
# このスクリプトは idd-claude の各ファイルを適切な場所にコピーします。
# 対象リポジトリへの配置・ローカル PC へのインストール・両方を選択可能。
#
# 使い方:
#   ./install.sh                             # 対話モードで聞きながら進める
#   ./install.sh --repo /path/to/your-project
#   ./install.sh --repo                      # カレントディレクトリ (./) に配置
#   ./install.sh --local                     # ローカル watcher のみインストール
#   ./install.sh --all                       # カレントディレクトリ + ローカル watcher
#   ./install.sh --all --repo /path/to/project
#
# オプション（既存フラグと組み合わせ可）:
#   --dry-run        実コピーせず、予定操作を [DRY-RUN] プレフィクスで列挙
#                    （ファイルシステムを変更しない。出力分類は実実行時と一致）
#   --force          .claude/agents/ / .claude/rules/ について、内容差分があれば
#                    .bak once-only 退避して強制上書き（既存 *.bak は保護）。
#                    CLAUDE.md は --force だけでは上書きしない（consumer 固有の
#                    記述を保護するため）。既存 CLAUDE.md は据え置き、template を
#                    CLAUDE.md.org として並置（差分時のみ）= --force なしと同一挙動。
#   --force-claude-md  CLAUDE.md を template で明示上書きする（.bak once-only 退避 +
#                    上書き）。CLAUDE.md.org は作らない。--force と併用すると
#                    agents/rules も CLAUDE.md も上書きされる。
#   --no-labels      対象リポジトリ配置時に走る GitHub ラベル自動セットアップを完全に skip
#                    （`IDD_CLAUDE_SKIP_LABELS=true` env でも同等の opt-out が可能）
# =============================================================================
#
# SC2034 file-wide 抑止の根拠（#473 install-lib.sh 分割の副作用 / watcher module 分割
# （#464 SC2153 / #469 SC2034 等）と同種の cross-file 可視性喪失）:
#   REPO_TEMPLATE_DIR / LOCAL_WATCHER_DIR / DRY_RUN / FORCE / FORCE_CLAUDE_MD /
#   SKIP_LABELS は本ファイルで定義するが、参照は install-lib.sh 側の関数（source される
#   ため実際には解決される）にあるため、単一ファイル静的解析では「未使用」に
#   見える。変数移動対象自体は無改変（#455 共通規約）のため file-wide で抑止する。
# shellcheck disable=SC2034

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# sudo で実行されていないか警告
#   idd-claude は $HOME 配下にユーザースコープで配置するため sudo は不要。
#   sudo で実行するとファイル所有者が root になり、後からユーザーで更新できなくなる。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "⚠️  sudo で実行されています。idd-claude はユーザースコープ（\$HOME 配下）に"
  echo "   インストールする前提のため、sudo は不要です。"
  echo "   このまま続行すると \$HOME 配下のファイルが root 所有になり、通常ユーザーで"
  echo "   更新・削除できなくなる可能性があります。"
  echo ""
  read -r -p "   このまま続行しますか？ [y/N]: " yn
  if [[ ! "$yn" =~ ^[Yy]$ ]]; then
    echo "   中断しました。sudo を外して再実行してください。"
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_TEMPLATE_DIR="$SCRIPT_DIR/repo-template"
LOCAL_WATCHER_DIR="$SCRIPT_DIR/local-watcher"

# install-lib.sh に切り出した配置ヘルパー / ラベル自動セットアップ / 履歴持ち込み検出関数群と
# main フロー関数（parse_install_args / run_repo_install / run_local_install）を source する（#473）。
# shellcheck source=/dev/null
source "$SCRIPT_DIR/install-lib.sh"

# 冪等性 / dry-run 制御フラグ（後段の引数パースで上書き可能）
DRY_RUN=false
FORCE=false
# CLAUDE.md を template で明示上書きするオプトインフラグ（Issue #208 / Req 2）。
#   false（既定）: --force の有無に関わらず CLAUDE.md は据え置き + 差分時 .org 並置。
#   true（--force-claude-md 指定時）: CLAUDE.md.bak once-only 退避 + template 上書き。
FORCE_CLAUDE_MD=false

# ラベル自動セットアップ opt-out 制御
#   true: ラベルセットアップを完全に skip（`--no-labels` または
#         `IDD_CLAUDE_SKIP_LABELS=true` env で有効化）
#   false: 既定（対象リポジトリ配置時にラベルセットアップを試行する）
SKIP_LABELS=false
case "${IDD_CLAUDE_SKIP_LABELS:-}" in
  true|TRUE|True|1|yes|YES) SKIP_LABELS=true ;;
esac

REPO_PATH=""
INSTALL_LOCAL=false
INSTALL_REPO=false

# 引数パース
parse_install_args "$@"

# 対話モード（引数なし）
if ! $INSTALL_LOCAL && ! $INSTALL_REPO; then
  echo "=== idd-claude install ==="
  echo ""
  read -r -p "対象リポジトリにテンプレートを配置しますか？ [y/N]: " yn
  if [[ "$yn" =~ ^[Yy]$ ]]; then
    read -r -p "  対象リポジトリのパス [Enter でカレント (./): " REPO_PATH
    REPO_PATH="${REPO_PATH:-./}"
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
  run_repo_install
fi

# ─────────────────────────────────────────────────────────────
# ローカル PC への watcher インストール
# ─────────────────────────────────────────────────────────────
if $INSTALL_LOCAL; then
  run_local_install
fi

echo ""
echo "🎉 idd-claude のインストールが完了しました。"
echo "   詳細は README.md を参照してください。"
