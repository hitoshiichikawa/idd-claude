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
#   --force          .claude/agents/ / .claude/rules/ / CLAUDE.md について、
#                    内容差分があれば再 .bak 退避して強制上書き
#                    （既存 *.bak は once-only 規律で保護されたまま）
# =============================================================================

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

# 冪等性 / dry-run 制御フラグ（後段の引数パースで上書き可能）
DRY_RUN=false
FORCE=false

REPO_PATH=""
INSTALL_LOCAL=false
INSTALL_REPO=false

# 引数パース
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      # --repo の次がフラグ（- で始まる）または存在しない場合はカレントディレクトリを採用
      if [ $# -ge 2 ] && [[ ! "${2:-}" =~ ^- ]] && [ -n "${2:-}" ]; then
        REPO_PATH="$2"
        shift 2
      else
        REPO_PATH="."
        shift
      fi
      INSTALL_REPO=true
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
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      sed -n '3,21p' "$0"
      exit 0
      ;;
    *)
      echo "未知のオプション: $1" >&2
      exit 1
      ;;
  esac
done

# ─────────────────────────────────────────────────────────────
# ヘルパー関数群
#   引数パースの後に定義し、後段の setup_repo / setup_local_watcher 相当ブロックから
#   呼び出される。すべて DRY_RUN / FORCE をグローバル変数として参照する。
# ─────────────────────────────────────────────────────────────

# log_action <NEW|OVERWRITE|SKIP|BACKUP> <path> [<note>]
#   配置・上書き・スキップ・バックアップを統一フォーマットで stdout に記録する。
#   DRY_RUN=true の場合は "[DRY-RUN]" prefix、それ以外は "[INSTALL]" prefix を使う。
log_action() {
  local action="$1"
  local path="$2"
  local note="${3:-}"
  local prefix
  if [ "$DRY_RUN" = "true" ]; then
    prefix="[DRY-RUN]"
  else
    prefix="[INSTALL]"
  fi
  if [ -n "$note" ]; then
    printf '%s %-9s %s %s\n' "$prefix" "$action" "$path" "$note"
  else
    printf '%s %-9s %s\n' "$prefix" "$action" "$path"
  fi
}

# files_equal <path_a> <path_b>
#   2 ファイルの内容同一性判定。
#   return: 0=同一 / 1=差分あり / 2=どちらか不在 or 比較不能
files_equal() {
  local a="$1"
  local b="$2"
  if [ ! -f "$a" ] || [ ! -f "$b" ]; then
    return 2
  fi
  if cmp -s "$a" "$b"; then
    return 0
  else
    return 1
  fi
}

# classify_action <src> <dest>
#   stdout に "NEW" / "SKIP" / "OVERWRITE" を返す。
#   - dest 不在 → NEW
#   - dest 存在 + 内容同一 → SKIP
#   - dest 存在 + 内容差分 → OVERWRITE
classify_action() {
  local src="$1"
  local dest="$2"
  if [ ! -e "$dest" ]; then
    echo "NEW"
    return 0
  fi
  if files_equal "$src" "$dest"; then
    echo "SKIP"
  else
    echo "OVERWRITE"
  fi
}

# ensure_dir <path>
#   mkdir -p の dry-run 対応版。dry-run 時はディレクトリも作らない。
ensure_dir() {
  local path="$1"
  if [ "$DRY_RUN" = "true" ]; then
    return 0
  fi
  mkdir -p "$path"
}

# copy_template_file <src> <dest> [--executable]
#   単一ファイルの NEW / SKIP / OVERWRITE 配置（meta ファイル用、`.bak` は作らない）。
#   既存があっても内容差分があれば無条件で OVERWRITE する。
#   --executable 指定時は配置後に `chmod +x` を実行する。
copy_template_file() {
  local src="$1"
  local dest="$2"
  local executable=false
  if [ "${3:-}" = "--executable" ]; then
    executable=true
  fi

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  local action
  action="$(classify_action "$src" "$dest")"

  local note=""
  if [ "$executable" = "true" ]; then
    note="(chmod +x)"
  fi

  case "$action" in
    NEW)
      log_action "NEW" "$dest" "$note"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
        if [ "$executable" = "true" ]; then
          chmod +x "$dest"
        fi
      fi
      ;;
    SKIP)
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      log_action "OVERWRITE" "$dest" "$note"
      if [ "$DRY_RUN" = "false" ]; then
        cp "$src" "$dest"
        if [ "$executable" = "true" ]; then
          chmod +x "$dest"
        fi
      fi
      ;;
  esac
}

# copy_glob_to_homebin <src_dir> <pattern> <dest_dir> [--executable]
#   `<src_dir>/<pattern>` にマッチする全ファイルを <dest_dir> に配置する。
#   nullglob を一時的に有効化し、マッチ 0 件は SKIP ログを出して exit 0 で継続する。
copy_glob_to_homebin() {
  local src_dir="$1"
  local pattern="$2"
  local dest_dir="$3"
  local executable_flag=""
  if [ "${4:-}" = "--executable" ]; then
    executable_flag="--executable"
  fi

  ensure_dir "$dest_dir"

  # nullglob を一時的に有効化（マッチ 0 件で空配列扱いにする）
  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  # `$pattern` は意図的に glob 展開させたいためクォートしない
  # shellcheck disable=SC2206
  local files=( "$src_dir"/$pattern )
  local count=${#files[@]}

  if [ "$count" -eq 0 ]; then
    log_action "SKIP" "$src_dir/$pattern" "(no files matched)"
  else
    local src
    for src in "${files[@]}"; do
      local dest
      dest="$dest_dir/$(basename "$src")"
      if [ -n "$executable_flag" ]; then
        copy_template_file "$src" "$dest" --executable
      else
        copy_template_file "$src" "$dest"
      fi
    done
  fi

  # nullglob を呼び出し前の状態に戻す
  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi
}

# backup_claude_md_once <repo_path>
#   CLAUDE.md.bak を初回 1 回のみ作成し、再実行で内容を変えない once-only 規律を実装。
#   - CLAUDE.md 不在 → noop
#   - CLAUDE.md.bak 不在 → BACKUP（初回バックアップ）
#   - CLAUDE.md.bak 既存 → SKIP（既存 .bak を温存）
backup_claude_md_once() {
  local repo_path="$1"
  local src="$repo_path/CLAUDE.md"
  local bak="$repo_path/CLAUDE.md.bak"

  if [ ! -f "$src" ]; then
    return 0
  fi

  if [ ! -f "$bak" ]; then
    log_action "BACKUP" "$src" "→ CLAUDE.md.bak"
    if [ "$DRY_RUN" = "false" ]; then
      cp "$src" "$bak"
    fi
  else
    log_action "SKIP" "$bak" "(existing .bak preserved)"
  fi
}

# copy_with_hybrid_overwrite <src> <dest>
#   1 ファイル単位のハイブリッド safe-overwrite 処理（agents / rules / CLAUDE.md 共用）。
#   - dest 不在 → NEW（無条件配置、template 進化に追従）
#   - dest 存在 + 内容同一 → SKIP `(identical to template)`
#   - dest 存在 + 内容差分:
#     - <dest>.bak 不在 → BACKUP `<dest> → <name>.bak` + OVERWRITE
#     - <dest>.bak 既存 + FORCE=false → SKIP `(existing .bak found, use --force to overwrite)`
#     - <dest>.bak 既存 + FORCE=true  → SKIP の .bak（once-only 規律保護）+ OVERWRITE
copy_with_hybrid_overwrite() {
  local src="$1"
  local dest="$2"

  if [ ! -f "$src" ]; then
    echo "Error: source file not found: $src" >&2
    return 1
  fi

  local action
  action="$(classify_action "$src" "$dest")"

  case "$action" in
    NEW)
      log_action "NEW" "$dest"
      if [ "$DRY_RUN" = "false" ]; then
        ensure_dir "$(dirname "$dest")"
        cp "$src" "$dest"
      fi
      ;;
    SKIP)
      log_action "SKIP" "$dest" "(identical to template)"
      ;;
    OVERWRITE)
      local bak="$dest.bak"
      local bak_name
      bak_name="$(basename "$dest").bak"
      if [ ! -f "$bak" ]; then
        # .bak 不在 → 初回退避してから上書き（once-only）
        local backup_note
        if [ "$FORCE" = "true" ]; then
          backup_note="→ $bak_name (--force)"
        else
          backup_note="→ $bak_name (custom edits detected)"
        fi
        log_action "BACKUP" "$dest" "$backup_note"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$dest" "$bak"
        fi
        log_action "OVERWRITE" "$dest"
        if [ "$DRY_RUN" = "false" ]; then
          cp "$src" "$dest"
        fi
      else
        # .bak 既存 → once-only 規律で再退避しない
        if [ "$FORCE" = "true" ]; then
          log_action "SKIP" "$bak" "(existing .bak preserved even with --force)"
          log_action "OVERWRITE" "$dest"
          if [ "$DRY_RUN" = "false" ]; then
            cp "$src" "$dest"
          fi
        else
          log_action "SKIP" "$dest" "(existing .bak found, use --force to overwrite)"
        fi
      fi
      ;;
  esac
}

# copy_agents_rules <src_dir> <dest_dir>
#   `.claude/agents/*.md` および `.claude/rules/*.md` のハイブリッド safe-overwrite 配置。
#   各 .md ファイルに対して copy_with_hybrid_overwrite を適用する。
#   nullglob を一時的に有効化し、マッチ 0 件は SKIP ログを出して exit 0 で継続。
copy_agents_rules() {
  local src_dir="$1"
  local dest_dir="$2"

  ensure_dir "$dest_dir"

  local prev_nullglob
  if shopt -q nullglob; then
    prev_nullglob=on
  else
    prev_nullglob=off
  fi
  shopt -s nullglob

  local files=( "$src_dir"/*.md )
  local count=${#files[@]}

  if [ "$count" -eq 0 ]; then
    log_action "SKIP" "$src_dir/*.md" "(no files matched)"
  else
    local src
    for src in "${files[@]}"; do
      local dest
      dest="$dest_dir/$(basename "$src")"
      copy_with_hybrid_overwrite "$src" "$dest"
    done
  fi

  if [ "$prev_nullglob" = "off" ]; then
    shopt -u nullglob
  fi
}

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
  # --all などで --repo が明示されなかった場合はカレントディレクトリをデフォルトに
  REPO_PATH="${REPO_PATH:-.}"

  if [ ! -d "$REPO_PATH" ]; then
    echo "Error: リポジトリパスが存在しません: $REPO_PATH" >&2
    exit 1
  fi

  # 絶対パスに正規化（ログ表示とメッセージの一貫性のため）
  REPO_PATH_ABS="$(cd "$REPO_PATH" && pwd)"

  echo ""
  echo "📦 対象リポジトリにファイルを配置: $REPO_PATH_ABS"
  REPO_PATH="$REPO_PATH_ABS"

  # CLAUDE.md は既存があればバックアップ
  if [ -f "$REPO_PATH/CLAUDE.md" ]; then
    echo "  既存の CLAUDE.md を CLAUDE.md.bak にバックアップ"
    cp "$REPO_PATH/CLAUDE.md" "$REPO_PATH/CLAUDE.md.bak"
  fi

  cp -v "$REPO_TEMPLATE_DIR/CLAUDE.md" "$REPO_PATH/CLAUDE.md"

  mkdir -p "$REPO_PATH/.claude/agents"
  cp -v "$REPO_TEMPLATE_DIR/.claude/agents/"*.md "$REPO_PATH/.claude/agents/"

  mkdir -p "$REPO_PATH/.claude/rules"
  cp -v "$REPO_TEMPLATE_DIR/.claude/rules/"*.md "$REPO_PATH/.claude/rules/"

  mkdir -p "$REPO_PATH/.github/ISSUE_TEMPLATE"
  cp -v "$REPO_TEMPLATE_DIR/.github/ISSUE_TEMPLATE/feature.yml" \
        "$REPO_PATH/.github/ISSUE_TEMPLATE/feature.yml"

  mkdir -p "$REPO_PATH/.github/workflows"
  cp -v "$REPO_TEMPLATE_DIR/.github/workflows/issue-to-pr.yml" \
        "$REPO_PATH/.github/workflows/issue-to-pr.yml"

  mkdir -p "$REPO_PATH/.github/scripts"
  cp -v "$REPO_TEMPLATE_DIR/.github/scripts/idd-claude-labels.sh" \
        "$REPO_PATH/.github/scripts/idd-claude-labels.sh"
  chmod +x "$REPO_PATH/.github/scripts/idd-claude-labels.sh"

  cat <<REPO_HINT

  ✅ 配置完了。次の手順:

     1. CLAUDE.md をプロジェクト固有の内容に編集（技術スタック・規約など）
     2. git add / commit / push
     3. GitHub ラベルを一括作成:
          cd $REPO_PATH
          bash .github/scripts/idd-claude-labels.sh
        （repo 外から実行する場合は --repo owner/repo を付与）
     4. 実行基盤の選択:
        - **ローカル watcher のみ使う場合**: 何もしない（.github/workflows/issue-to-pr.yml は
          repository variable 未設定なので自動でスキップされます）
        - **GitHub Actions で回す場合**:
          a) Settings → Secrets and variables → Actions → **Variables** タブで
             \`IDD_CLAUDE_USE_ACTIONS=true\` を追加
          b) Secrets タブで \`ANTHROPIC_API_KEY\` もしくは \`CLAUDE_CODE_OAUTH_TOKEN\` を追加
          c) 必要に応じて .github/workflows/issue-to-pr.yml の認証方式行を切り替え
     5. Branch protection（任意）:
          gh api -X PUT repos/<owner>/<repo>/branches/main/protection \\
            -f required_pull_request_reviews.required_approving_review_count=1 \\
            -F enforce_admins=false
REPO_HINT
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
  # PR Iteration Processor (#26) 用テンプレート。既存 watcher で
  # PR_ITERATION_ENABLED=true にするまで参照されないが、配置のみ常時行う。
  if [ -f "$LOCAL_WATCHER_DIR/bin/iteration-prompt.tmpl" ]; then
    cp -v "$LOCAL_WATCHER_DIR/bin/iteration-prompt.tmpl" "$HOME/bin/"
  fi
  chmod +x "$HOME/bin/issue-watcher.sh"

  # macOS: launchd
  if [ "$(uname)" = "Darwin" ]; then
    mkdir -p "$HOME/Library/LaunchAgents"
    cp -v "$LOCAL_WATCHER_DIR/LaunchAgents/com.local.issue-watcher.plist" \
          "$HOME/Library/LaunchAgents/"

    cat <<'LAUNCHD_HINT'

  ✅ 配置完了。次の手順:

     1. plist の EnvironmentVariables を対象リポジトリに合わせて編集
        （$EDITOR ~/Library/LaunchAgents/com.local.issue-watcher.plist）
          - REPO      : owner/your-repo
          - REPO_DIR  : ローカルの git clone のパス

     2. launchd に登録（ユーザースコープ、sudo 不要）
          launchctl load   ~/Library/LaunchAgents/com.local.issue-watcher.plist
          launchctl start  com.local.issue-watcher

     3. ログ確認
          tail -f /tmp/issue-watcher.stderr.log

     4. 複数リポジトリを並行稼働させる場合は plist を repo ごとにコピーして
        Label / REPO / REPO_DIR / StandardOut/ErrorPath を書き換える
        （README.md 「複数リポジトリ運用」参照）

  ※ いずれも sudo 不要。ユーザー $HOME 配下に閉じた設定のため、
     sudo で実行するとファイル所有者が root になり逆に動作しなくなる可能性があります。
LAUNCHD_HINT
  else
    cat <<'CRON_HINT'

  ✅ 配置完了。次の手順:

     1. ~/bin/issue-watcher.sh の先頭 Config（TRIAGE_MODEL 等）を必要に応じて編集
        ※ REPO / REPO_DIR は cron 側で env var として渡すのでファイル編集は不要

     2. cron に登録（**ユーザー crontab**、sudo 不要）
          crontab -e

        以下の行を追記（単一 repo 例）:
          */2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1

        複数 repo を並行稼働させる場合（lock/log は REPO から自動分離されます）:
          */2 * * * * REPO=owner/repo-a REPO_DIR=$HOME/work/repo-a $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
          */3 * * * * REPO=owner/repo-b REPO_DIR=$HOME/work/repo-b $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1

     3. 動作確認
          tail -f $HOME/.issue-watcher/cron.log
          ls $HOME/.issue-watcher/logs/

  ※ システム全体の /etc/crontab ではなくユーザー crontab（crontab -e）を使ってください。
     sudo は不要、かつ sudo で install.sh を走らせると $HOME 配下のファイル所有者が
     root になり、通常ユーザーで更新・削除できなくなります。
CRON_HINT
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
