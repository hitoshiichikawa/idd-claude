#!/usr/bin/env bash
# =============================================================================
# idd-claude local issue watcher
#
# GitHub Issue をポーリングし、auto-dev ラベルが付いた未処理 Issue を検出して
# Claude Code でローカル実行する。
#
# 3 つのモードを状態機械で管理:
#   - design        : PM → Architect → PjM（設計 PR 作成、awaiting-design-review 付与）
#   - impl          : PM → Developer → PjM（小〜中規模、Architect 不要）
#   - impl-resume   : Developer → PjM（設計 PR が merge 済みで docs/specs/<N>-*/ が main に存在）
#
# ラベルによる状態遷移:
#   auto-dev  → claude-claimed (Dispatcher claim) → Triage
#                              → (needs-decisions | awaiting-design-review | claude-picked-up)
#                              → ready-for-review / claude-failed
#
# 配置先: ~/bin/issue-watcher.sh
# 依存  : gh / jq / claude / flock / git
#
# セットアップ: このファイル冒頭の ━━━ Config ━━━ ブロックを編集し、
#   launchd (macOS) または cron (Linux) に登録する。README.md を参照。
# =============================================================================

set -euo pipefail

# cron / launchd は対話シェルの profile を読まないため PATH が最小限になり、
# ~/.local/bin や /usr/local/bin にインストールした claude / gh が見つからない。
# 一般的なインストール先を先頭に足しておき、どの起動経路でも同じ挙動にする。
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config（環境に合わせて書き換える）
#
# 複数リポジトリ運用:
#   REPO / REPO_DIR は環境変数で上書き可能。各 repo の cron / launchd エントリから
#   env var を渡せば、このスクリプト 1 ファイルを使い回せる。
#   LOCK_FILE / LOG_DIR / TRIAGE_FILE は REPO から自動派生するため衝突しない。
#
#   cron 例:
#     */2 * * * * REPO=owner/a REPO_DIR=$HOME/work/a $HOME/bin/issue-watcher.sh
#     */3 * * * * REPO=owner/b REPO_DIR=$HOME/work/b $HOME/bin/issue-watcher.sh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# env var で上書き可能（未設定なら下のデフォルトを使う）
REPO="${REPO:-owner/your-repo}"
REPO_DIR="${REPO_DIR:-$HOME/work/your-repo}"

# REPO から repo-unique な slug を導出（lock / log / 一時ファイルの隔離に使う）
REPO_SLUG="$(echo "$REPO" | tr '/' '-')"

LABEL_TRIGGER="auto-dev"
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_SKIP_TRIAGE="skip-triage"
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_NEEDS_ITERATION="needs-iteration"

# ─── Phase A: Merge Queue Processor 設定 ───
# 既存運用への影響を避けるため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で MERGE_QUEUE_ENABLED=true を渡す。
MERGE_QUEUE_ENABLED="${MERGE_QUEUE_ENABLED:-false}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_MAX_PRS="${MERGE_QUEUE_MAX_PRS:-5}"
# git 操作の個別タイムアウト（秒）。watcher の最短実行間隔（既定 2 分）の半分以内を目安。
MERGE_QUEUE_GIT_TIMEOUT="${MERGE_QUEUE_GIT_TIMEOUT:-60}"
# main ブランチ名（基本は "main"。レガシー repo で master の場合のみ上書き）。
MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-main}"
# head branch prefix: 自動 rebase を許可する head ref のプレフィックス。
# idd-claude が作成する PR は `claude/issue-N-*` パターン。人間が書いた PR を
# 巻き込まないよう、デフォルトで `claude/` 始まりだけを対象にする。
# 複数許可したい場合はパイプ区切り正規表現で上書き（例: '^(claude|bot)/'）。
MERGE_QUEUE_HEAD_PATTERN="${MERGE_QUEUE_HEAD_PATTERN:-^claude/}"

# ─── Merge Queue Re-check Processor 設定 (#27) ───
# `needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
# 戻った PR のラベルを自動除去する。Phase A 本体（MERGE_QUEUE_ENABLED）とは
# 独立に opt-in 制御するため、デフォルトは false。
MERGE_QUEUE_RECHECK_ENABLED="${MERGE_QUEUE_RECHECK_ENABLED:-false}"
# 1 サイクルで再評価する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_RECHECK_MAX_PRS="${MERGE_QUEUE_RECHECK_MAX_PRS:-20}"

# ─── PR Iteration Processor 設定 (#26) ───
# `needs-iteration` ラベル付き PR をレビューコメントに基づいて自動で iterate する。
# 既存運用への影響を避けるため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で PR_ITERATION_ENABLED=true を渡す。
PR_ITERATION_ENABLED="${PR_ITERATION_ENABLED:-false}"
# Iteration 専用モデル ID（既存 DEV_MODEL とは独立して上書き可能）。
PR_ITERATION_DEV_MODEL="${PR_ITERATION_DEV_MODEL:-claude-opus-4-7}"
# 1 iteration あたりの Claude 実行 turn 数上限（NFR 1.1）。
PR_ITERATION_MAX_TURNS="${PR_ITERATION_MAX_TURNS:-60}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し、AC 1.6 / NFR 1.2）。
PR_ITERATION_MAX_PRS="${PR_ITERATION_MAX_PRS:-3}"
# 1 PR あたりの累計 iteration 上限。到達時は claude-failed に昇格（AC 7.2）。
PR_ITERATION_MAX_ROUNDS="${PR_ITERATION_MAX_ROUNDS:-3}"
# 自動 iteration を許可する head ref のプレフィックス正規表現（impl PR 用）。
# 既定値は #35 で `^claude/` から `^claude/issue-[0-9]+-impl-` に厳格化された。
# 旧 `^claude/` 挙動に戻したい場合は cron / launchd 側で本変数を override すること
# （Migration Note は README 参照、AC 4.3 / 5.5 / NFR 4.2）。
PR_ITERATION_HEAD_PATTERN="${PR_ITERATION_HEAD_PATTERN:-^claude/issue-[0-9]+-impl-}"
# 各 git / gh 操作の個別タイムアウト（秒、NFR 1.3）。
PR_ITERATION_GIT_TIMEOUT="${PR_ITERATION_GIT_TIMEOUT:-60}"
# Iteration プロンプトテンプレートの配置先（install.sh --local が配置、impl PR 用）。
ITERATION_TEMPLATE="${ITERATION_TEMPLATE:-$HOME/bin/iteration-prompt.tmpl}"

# ─── PR Iteration Processor 設定: 設計 PR 拡張 (#35) ───
# 設計 PR (`claude/issue-<N>-design-<slug>`) にも `needs-iteration` で反復対応する
# opt-in フラグ。既定 false で本機能は無効、impl PR の挙動は #26 導入時と完全同一。
# 有効化するには cron / launchd 側で PR_ITERATION_DESIGN_ENABLED=true を渡す
# （AC 4.1 / 4.4 / 5.1）。
PR_ITERATION_DESIGN_ENABLED="${PR_ITERATION_DESIGN_ENABLED:-false}"
# 設計 PR の head branch pattern（jq の test() 互換 POSIX ERE）。
# idd-claude PjM テンプレートが作る設計 PR は `claude/issue-<N>-design-<slug>` 形式（AC 4.2）。
PR_ITERATION_DESIGN_HEAD_PATTERN="${PR_ITERATION_DESIGN_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
# 設計 PR 用 Iteration テンプレートの配置先（install.sh --local が配置）。
ITERATION_TEMPLATE_DESIGN="${ITERATION_TEMPLATE_DESIGN:-$HOME/bin/iteration-prompt-design.tmpl}"

# ─── Design Review Release Processor 設定 (#40) ───
# 設計 PR が merge された Issue から `awaiting-design-review` ラベルを自動除去し、
# ステータスコメントを 1 件投稿する。既存運用（人間が手動でラベルを外す運用）を
# 壊さないため、初回導入は opt-in（デフォルト false）。
# 有効化するには cron / launchd 側で DESIGN_REVIEW_RELEASE_ENABLED=true を渡す。
DESIGN_REVIEW_RELEASE_ENABLED="${DESIGN_REVIEW_RELEASE_ENABLED:-false}"
# 1 サイクルで処理する Issue 数の上限（残りは次回サイクルに持ち越し、AC 5.1 / 5.2）。
DESIGN_REVIEW_RELEASE_MAX_ISSUES="${DESIGN_REVIEW_RELEASE_MAX_ISSUES:-10}"
# 設計 PR の head branch 規約（jq の test() 互換 POSIX ERE）。
# idd-claude PjM テンプレートが作る設計 PR は `claude/issue-<N>-design-<slug>` 形式。
DESIGN_REVIEW_RELEASE_HEAD_PATTERN="${DESIGN_REVIEW_RELEASE_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
# 各 gh 操作の個別タイムアウト（秒、AC 5.4）。専用 env var は導入せず、
# Phase A の MERGE_QUEUE_GIT_TIMEOUT を流用してデフォルト 60 秒。
DRR_GH_TIMEOUT="${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"

# LOG_DIR と LOCK_FILE は REPO_SLUG を挟むことで repo ごとに分離。
# 環境変数で明示上書きもできる。
LOG_DIR="${LOG_DIR:-$HOME/.issue-watcher/logs/$REPO_SLUG}"
LOCK_FILE="${LOCK_FILE:-/tmp/issue-watcher-${REPO_SLUG}.lock}"

# モデル設定
TRIAGE_MODEL="${TRIAGE_MODEL:-claude-sonnet-4-6}"   # Triage は軽量モデルで十分
DEV_MODEL="${DEV_MODEL:-claude-opus-4-7}"           # 本実装は Opus 4.7 + 1M context
TRIAGE_MAX_TURNS="${TRIAGE_MAX_TURNS:-15}"
DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"

# ─── Reviewer subagent 設定 (#20 Phase 1) ───
# impl 系モード（impl / impl-resume）の Developer 完了後に独立 context で起動する
# Reviewer サブエージェント用の env。既存の TRIAGE_* / DEV_* と独立に扱う。
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-7}"
REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-30}"

# ─── Phase C: Issue 並列化 (worktree slot + dispatcher, #16) ───
# 入口（auto-dev Issue 処理）の並列度を制御する env var 群。
# 既存運用との後方互換のため、すべてデフォルトで本機能導入前と同一挙動になるよう配置:
#   - PARALLEL_SLOTS 未設定 → 直列（slot=1）動作。slot-2 以降の lock / worktree は作成しない
#   - SLOT_INIT_HOOK 未設定 → フック非起動（本機能導入前と同一）
#   - WORKTREE_BASE_DIR / SLOT_LOCK_DIR は通常上書き不要。テスト用に override 可能。
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"
SLOT_INIT_HOOK="${SLOT_INIT_HOOK:-}"
WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-$HOME/.issue-watcher/worktrees}"
SLOT_LOCK_DIR="${SLOT_LOCK_DIR:-$HOME/.issue-watcher}"

# Triage プロンプトテンプレート
TRIAGE_TEMPLATE="${TRIAGE_TEMPLATE:-$HOME/bin/triage-prompt.tmpl}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提ツールチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in gh jq claude git flock timeout; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd が見つかりません。PATH を確認してください。" >&2
    exit 1
  }
done

[ -f "$TRIAGE_TEMPLATE" ] || {
  echo "Error: Triage テンプレートが見つかりません: $TRIAGE_TEMPLATE" >&2
  exit 1
}

# PR Iteration が有効化されている時のみ template の存在を必須化（opt-in gate）。
# 無効化（既定）時は template 未配置でも watcher 全体を起動できるよう、無条件チェックを避ける。
if [ "$PR_ITERATION_ENABLED" = "true" ] && [ ! -f "$ITERATION_TEMPLATE" ]; then
  echo "Error: Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# 設計 PR Iteration が有効化されている時のみ design 用 template を必須化（#35 AC 2.2）。
if [ "$PR_ITERATION_ENABLED" = "true" ] \
   && [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ] \
   && [ ! -f "$ITERATION_TEMPLATE_DESIGN" ]; then
  echo "Error: 設計 PR 用 Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE_DESIGN" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 多重起動防止
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "[$(date '+%F %T')] 他のインスタンスが実行中のためスキップ"
  exit 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# リポジトリを最新化
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
cd "$REPO_DIR"
git fetch origin --prune
git checkout main
git pull --ff-only origin main

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor
#   approve 済み open PR の mergeability を能動的に検知し:
#     - CONFLICTING: needs-rebase ラベル + 状況コメント（人間判断に回す）
#     - MERGEABLE かつ base が古い: ローカルで自動 rebase + force-with-lease push
#   既存運用との後方互換のため MERGE_QUEUE_ENABLED=true で opt-in。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
mq_log() {
  echo "[$(date '+%F %T')] merge-queue: $*"
}
mq_warn() {
  echo "[$(date '+%F %T')] merge-queue: WARN: $*" >&2
}
mq_error() {
  echo "[$(date '+%F %T')] merge-queue: ERROR: $*" >&2
}

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
mq_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# CONFLICTING PR にラベル + 状況コメントを投稿（重複抑止つき）
# 失敗しても次の PR に進むよう、戻り値ではなく内部で WARN を出す
mq_handle_conflict() {
  local pr_number="$1"
  local pr_json="$2"
  local pr_url
  pr_url=$(echo "$pr_json" | jq -r '.url')

  # AC 2.2: 既に needs-rebase が付いている場合はラベル付与/コメントとも skip
  if mq_pr_has_label "$pr_json" "$LABEL_NEEDS_REBASE"; then
    mq_log "PR #${pr_number}: CONFLICTING (already labeled, skip)"
    return 0
  fi

  # AC 2.4: conflict したファイル粒度を含めるため、PR の変更ファイル一覧を取得。
  # mergeable=CONFLICTING の段階では merge できないため、簡易的に PR の files
  # 一覧（最大 50 件）をコメントに含める。Phase B 以降で staging branch 経由の
  # 真の conflict ファイル特定に置き換える前提。
  local files_json
  if ! files_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json files 2>/dev/null); then
    files_json='{"files":[]}'
  fi
  local files_md
  files_md=$(echo "$files_json" | jq -r '
    (.files // []) | map("- `" + .path + "`") |
    if length == 0 then "_(変更ファイル一覧の取得に失敗しました)_"
    elif length > 50 then (.[0:50] | join("\n")) + "\n- _(他 " + ((length - 50) | tostring) + " 件)_"
    else join("\n") end
  ')

  local comment_body
  comment_body=$(cat <<EOF
## 🔀 自動マージ前 conflict 検知 (Phase A)

approve 済みの本 PR について、watcher が main との merge 試行で **conflict** を検知しました。
\`needs-rebase\` ラベルを付与しています。

### 推奨アクション

- 手動で base を最新化してください（例: \`gh pr checkout ${pr_number} && git pull --rebase origin ${MERGE_QUEUE_BASE_BRANCH} && git push --force-with-lease\`）
- または semantic conflict の自動解消を待ちたい場合は Phase D（#17）の導入を検討してください

### 変更ファイル（参考）

実際の conflict 範囲は \`git merge-tree\` 等で確認してください。本 PR が触っているファイルの一覧:

${files_md}

---

_本コメントは Phase A Merge Queue Processor が自動投稿しました。conflict が解消し \`needs-rebase\` ラベルが手動で外されると、次回サイクルで再度判定されます。_
EOF
)

  # AC 2.1: needs-rebase 付与
  if ! gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    # AC 2.5: ラベル付与失敗 → WARN、後続 PR は継続
    mq_warn "PR #${pr_number}: needs-rebase ラベル付与に失敗"
    return 1
  fi
  # AC 2.3: ステータスコメント 1 件投稿
  if ! gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    # AC 2.5: コメント投稿失敗 → WARN、後続 PR は継続（ラベルは残す）
    mq_warn "PR #${pr_number}: 状況コメント投稿に失敗（ラベルは付与済み）"
    return 1
  fi
  mq_log "PR #${pr_number}: CONFLICTING -> labeled+commented (${pr_url})"
  return 0
}

# MERGEABLE PR を最新の base に自動 rebase して force-with-lease push する。
# 失敗したら needs-rebase に格下げする。サブシェルで実行し、trap で必ず main に戻す。
# 戻り値: 0=rebase+push 成功, 1=conflict 経由 needs-rebase 化, 2=その他失敗（push 失敗等）
mq_try_rebase_pr() {
  local pr_number="$1"
  local head_ref="$2"
  local base_ref="$3"
  local pr_json="$4"

  (
    set +e
    # サブシェル終了時は必ず元の main checkout に戻す（NFR 2.2）
    # shellcheck disable=SC2064
    trap "git rebase --abort >/dev/null 2>&1; git checkout '${MERGE_QUEUE_BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # AC 3.1 / 3.5: 既に祖先関係を満たしているなら rebase 不要
    if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
      exit 10  # skip 用の特別 exit code
    fi

    # head ブランチを fresh に checkout（既存ローカルブランチがあれば force リセット）
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      mq_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 2
    fi

    # AC 3.1: rebase 試行
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git rebase "origin/${base_ref}" >/dev/null 2>&1; then
      # AC 3.3: conflict なら abort して needs-rebase 化
      git rebase --abort >/dev/null 2>&1 || true
      exit 1
    fi

    # AC 3.2 / NFR 2.1: 安全な force push
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$head_ref" >/dev/null 2>&1; then
      # AC 3.4: push 失敗（リモート先行等）→ WARN、当該 PR をスキップ
      mq_warn "PR #${pr_number}: force-with-lease push に失敗（リモートが進んだ可能性）"
      exit 2
    fi
    exit 0
  )
  local rc=$?
  # サブシェル外でも安全側に倒して main に戻す（AC 3.6 / NFR 2.2）
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true

  case $rc in
    0)
      mq_log "PR #${pr_number}: MERGEABLE stale -> rebase+push OK"
      return 0
      ;;
    1)
      # rebase conflict → needs-rebase 化
      mq_handle_conflict "$pr_number" "$pr_json"
      return 1
      ;;
    10)
      mq_log "PR #${pr_number}: MERGEABLE up-to-date (skip rebase)"
      return 10
      ;;
    *)
      return 2
      ;;
  esac
}

process_merge_queue() {
  # AC 5.1: opt-out gate
  if [ "$MERGE_QUEUE_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3: 想定外の dirty working tree を検知したら ERROR を出してサイクル中止
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    mq_error "dirty working tree を検出しました。Merge Queue Processor をスキップします。"
    return 0
  fi

  mq_log "サイクル開始 (max=${MERGE_QUEUE_MAX_PRS}, base=${MERGE_QUEUE_BASE_BRANCH}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.2 / 1.3 / 1.4 / 1.6 / 1.7: approved かつ needs-rebase / claude-failed が付いていない
  # 非 draft の PR。さらに head branch が MERGE_QUEUE_HEAD_PATTERN に合致し、
  # head repo owner が base repo owner と同一（= fork PR を除外）のものに限定。
  # GitHub search 構文で server side フィルタ（API call 削減・NFR 1.2）
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved -label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,mergeStateStatus,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    mq_warn "approved PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # クライアント側フィルタ:
  #   - isDraft / reviewDecision の再確認（server filter の保険）
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_MAX_PRS))
    # AC 4.3: 上限超過分は次回に持ち越し
    mq_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 6.1: サイクル開始時に件数をログ
    mq_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local rebased=0
  local conflicted=0
  local skipped=0
  local failed=0

  # 先頭 N 件のみ処理（後ろは持ち越し）
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  # AC 4.3: target_count > 0 なので pr_iter は最低 1 行を持つ前提だが、念のため空ガード
  if [ -z "$pr_iter" ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable merge_state url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 1.5 / 6.2: 各 PR の mergeable 判定をログ
    mq_log "PR #${pr_number}: mergeable=${mergeable}, state=${merge_state}, head=${head_ref}, base=${base_ref}"

    case "$mergeable" in
      CONFLICTING)
        if mq_handle_conflict "$pr_number" "$pr_json"; then
          conflicted=$((conflicted + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      MERGEABLE)
        # base ブランチが対象 main 以外なら自動 rebase の対象外（安全側）
        if [ "$base_ref" != "$MERGE_QUEUE_BASE_BRANCH" ]; then
          mq_log "PR #${pr_number}: base=${base_ref} は ${MERGE_QUEUE_BASE_BRANCH} 以外、自動 rebase スキップ"
          skipped=$((skipped + 1))
          continue
        fi
        local rc=0
        mq_try_rebase_pr "$pr_number" "$head_ref" "$base_ref" "$pr_json" || rc=$?
        case $rc in
          0)  rebased=$((rebased + 1)) ;;
          1)  conflicted=$((conflicted + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
        ;;
      UNKNOWN|"")
        # GitHub が mergeable を未計算の場合は次回サイクルに委ねる
        mq_log "PR #${pr_number}: mergeable 未確定 (${mergeable:-null})、次回サイクルに委ねます"
        skipped=$((skipped + 1))
        ;;
      *)
        mq_log "PR #${pr_number}: 未知の mergeable=${mergeable} (${url})、スキップ"
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 6.3: サマリ行
  mq_log "サマリ: rebase+push=${rebased}, conflict=${conflicted}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"

  # AC 3.6 / NFR 2.2: 念のため最終確認で main checkout に戻す
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Re-check Processor (#27)
#   `needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
#   戻った PR のラベルを自動除去する。Phase A 本体（process_merge_queue）とは
#   独立に opt-in 制御するため、MERGE_QUEUE_RECHECK_ENABLED=true で起動。
#   ラベル除去のみを副作用とし、再 rebase / コメント投稿は Phase A 本体に委譲。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue-recheck 専用ロガー（Phase A 本体の `merge-queue:` と区別する prefix）。
# AC 5.5 / 5.6 / NFR 3.2: `merge-queue-recheck:` prefix と既存 timestamp 書式に統一。
mqr_log() {
  echo "[$(date '+%F %T')] merge-queue-recheck: $*"
}
mqr_warn() {
  echo "[$(date '+%F %T')] merge-queue-recheck: WARN: $*" >&2
}
mqr_error() {
  echo "[$(date '+%F %T')] merge-queue-recheck: ERROR: $*" >&2
}

process_merge_queue_recheck() {
  # AC 1.2 / 1.3 / 3.1 / 3.3: opt-in gate（MERGE_QUEUE_ENABLED とは独立）
  if [ "$MERGE_QUEUE_RECHECK_ENABLED" != "true" ]; then
    return 0
  fi

  mqr_log "サイクル開始 (max=${MERGE_QUEUE_RECHECK_MAX_PRS}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.4 / 1.5 / 1.6: approved かつ needs-rebase ラベル付き、claude-failed 無し、非 draft。
  # AC 4.3 / 4.4: server-side フィルタで API call を最小化、Phase A と同一 timeout を適用。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 100 2>/dev/null); then
    # AC 4.5: タイムアウト / エラー時は WARN を出して以降スキップ（後続処理は継続）
    mqr_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # AC 1.5 / 1.6 / 1.7 / 1.8: クライアント側フィルタ（server filter の保険）
  #   - isDraft / reviewDecision の再確認
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_RECHECK_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_RECHECK_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_RECHECK_MAX_PRS))
    # AC 4.2 / 5.1: 上限超過分は次回に持ち越し
    mqr_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_RECHECK_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 5.1: サイクル開始時に件数をログ
    mqr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    # AC 5.4: サマリ行（ゼロ件でも明示）
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local conflicting=0
  local unknown_skip=0
  local failed=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 5.2: 各 PR の mergeable 判定をログ（PR 番号 / mergeable / アクション）
    case "$mergeable" in
      MERGEABLE)
        # AC 2.1 / NFR 2.1: ラベル除去（唯一の副作用）。Phase A と同一 timeout を適用。
        if timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
            gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
          # AC 2.2 / 5.3: 成功 INFO ログ（要件文言を含める）
          mqr_log "PR #${pr_number}: mergeable=MERGEABLE -> label removed (conflict resolved, re-evaluating next cycle) (${url})"
          removed=$((removed + 1))
        else
          # AC 2.6: ラベル除去 API がエラーを返した場合は WARN、後続 PR は継続
          mqr_warn "PR #${pr_number}: needs-rebase ラベル除去に失敗（${url}）"
          failed=$((failed + 1))
        fi
        ;;
      CONFLICTING)
        # AC 2.3 / NFR 2.2: 状態変更なし（再ラベル / コメント追記なし）
        mqr_log "PR #${pr_number}: mergeable=CONFLICTING -> kept (head=${head_ref}, base=${base_ref})"
        conflicting=$((conflicting + 1))
        ;;
      UNKNOWN|null|"")
        # AC 2.4 / NFR 2.2: UNKNOWN / null は次回サイクルに委ねる
        mqr_log "PR #${pr_number}: mergeable=${mergeable:-null} -> skip (next cycle)"
        unknown_skip=$((unknown_skip + 1))
        ;;
      *)
        # NFR 2.2: 未知の値もラベル除去を行わずスキップ
        mqr_log "PR #${pr_number}: mergeable=${mergeable} (未知) -> skip"
        unknown_skip=$((unknown_skip + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 5.4: サマリ行
  mqr_log "サマリ: label-removed=${removed}, conflicting=${conflicting}, unknown-skip=${unknown_skip}, fail=${failed}, overflow=${skipped_overflow}"
}

# AC 1.1: Phase A 本体ループの直前に Re-check Processor を 1 回起動
process_merge_queue_recheck || mqr_warn "process_merge_queue_recheck が想定外のエラーで終了しました（後続処理は継続）"

# AC 1.1: ピックアップ済み Issue の処理ループに入る前に 1 回だけ起動
process_merge_queue || mq_warn "process_merge_queue が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PR Iteration Processor (#26)
#   `needs-iteration` ラベルが付いた idd-claude 管理下 PR を fresh context の Claude で
#   反復対応する。Phase A と同じ flock 境界内で直列実行され、対象 PR 集合は
#   server-side label query で Phase A と直交させている（AC 8.4）。
#
#   既存運用との後方互換のため PR_ITERATION_ENABLED=true で opt-in。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# pr-iteration 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
pi_log() {
  echo "[$(date '+%F %T')] pr-iteration: $*"
}
pi_warn() {
  echo "[$(date '+%F %T')] pr-iteration: WARN: $*" >&2
}
pi_error() {
  echo "[$(date '+%F %T')] pr-iteration: ERROR: $*" >&2
}

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
pi_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_fetch_candidate_prs: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   AC 1.1, 1.2, 1.3, 1.4, 1.5, 8.4
# ─────────────────────────────────────────────────────────────────────────────
pi_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # AC 1.1 / 1.4 / 1.5 / 8.4: needs-iteration 付き、claude-failed / needs-rebase 無し、非 draft
  if ! prs_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_REBASE\" -draft:true" \
      --json number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body \
      --limit 50 2>/dev/null); then
    pi_warn "needs-iteration PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # AC 1.2 / 1.3 / 1.4: クライアント側フィルタ（server filter の保険 + head pattern + fork 除外）
  # #35 AC 4.4 / 5.1: design pattern は PR_ITERATION_DESIGN_ENABLED=true のときのみ OR 条件に
  # 含める。false（既定）なら impl pattern のみで絞り込み、設計 PR は candidate 段階で除外される
  # （= 本機能導入前と完全同一の挙動）。
  echo "$prs_json" | jq \
    --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
    --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
    --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(
          (.headRefName | test($impl_pattern))
          or
          ($design_enabled == "true" and (.headRefName | test($design_pattern)))
        )
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_round_counter: PR body から hidden marker の round 数を取得
#   入力: $1=pr_number
#   出力: stdout に round 数（marker 無しなら 0）
#   AC 7.1, 7.4
# ─────────────────────────────────────────────────────────────────────────────
pi_read_round_counter() {
  local pr_number="$1"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、round=0 として扱います"
    echo "0"
    return 0
  fi
  # marker 形式: <!-- idd-claude:pr-iteration round=N last-run=... -->
  # 複数検出時は最後（最新）の数値を採用 = fail-safe
  local round
  round=$(echo "$body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${round:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_last_run: PR body から hidden marker の last-run ISO8601 タイムスタンプを抽出
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に last-run の ISO8601 文字列（例: "2026-04-25T12:34:56Z"）。
#         marker / last-run キーが無ければ空文字列を出力。
#   返り値: 0 固定（呼び出し元で空文字列を初回 round 扱いにする）
#   AC #55 Req 2.3, 2.4 / 4.1
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->
#   複数検出時は最後（最新）の値を採用（pi_read_round_counter の `tail -1` と整合）。
#   読み取り専用であり、書き込み側は pi_post_processing_marker のまま温存（後方互換性）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_last_run() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local last_run
  # 1. marker 行を抽出 → 2. `last-run=...` 部分のみを抽出 → 3. 末尾を採用
  #    値部分はスペース・`>` 以外を許容（pi_post_processing_marker は ISO8601 UTC を打刻するが、
  #    fail-safe としてスペース直前 / `>` 直前まで拾う）。
  last_run=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+ last-run=[^ >]+' \
    | sed -E 's|.*last-run=||' \
    | tail -1)
  echo "${last_run:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_self: watcher 自身の自動投稿コメントを除外（marker ベース）
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.1, 2.7
#
#   判定: comment.body 中に `idd-claude:` で始まる HTML hidden marker を含むなら
#   watcher 投稿として除外する。GitHub user 同一性に依存しない（cron 実行ホストが
#   異なる GitHub user で動いていても確実に除外できる）。`@claude` 文字列には
#   一切依存しない（Req 2.7）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_self() {
  jq '[.[] | select((.body // "") | contains("idd-claude:") | not)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_resolved: 過去 round で対応済みと判定できるコメントを除外
#   入力: $1=last_run (ISO8601 string, 空文字列 = 初回 round)
#         stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.2, 2.3, 2.4, 2.5, 2.7
#
#   判定: last_run が空文字列なら no-op（全件採用 = 初回 round, Req 2.4）。
#         last_run が指定されている場合は `created_at > last_run` のコメントのみ採用。
#         境界（`==`）は採用側に倒さず除外する（fail-safe、設計判断 Req 2.3 解釈）。
#         比較は ISO8601 lex compare（GitHub の created_at は UTC `Z` 終端で揃う）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_resolved() {
  local last_run="${1-}"
  jq --arg last_run "$last_run" \
    '[.[] | select($last_run == "" or (.created_at // "") > $last_run)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_event_style: GitHub system 由来の event-style コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.6, 2.7
#
#   判定: user.type == "Bot" のコメント、および body が空のコメントを除外する。
#         /repos/.../issues/<n>/comments は基本的にユーザーコメントしか返さないため
#         保険的なフィルタだが、Req 2.6 を観測可能に保つために独立化する。
#         watcher 自身の投稿は marker で既に除外済みのため、ここで Bot を全体除外しても
#         二重除外にならず安全。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_event_style() {
  jq '[.[] | select((.user.type // "") != "Bot" and (.body // "") != "")]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_truncate: 件数上限超過時に古い順 drop で削減
#   入力: $1=limit (件数上限)
#         stdin に一般コメント JSON 配列
#   出力: stdout に削減後の JSON 配列
#   AC #55 Req 3.1, 3.4
#
#   アルゴリズム:
#     1. 入力配列 length が limit 以下 → no-op（Req 3.4）
#     2. length > limit → created_at 昇順ソート → 末尾 limit 件を採用（古い順 drop）
#       新しいコメントが残るため、レビュワーが直近に追加した指摘を優先できる。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_truncate() {
  local limit="${1:-50}"
  jq --argjson limit "$limit" \
    'if length <= $limit then . else (sort_by(.created_at // "") | .[-$limit:]) end'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_collect_general_comments: 一般コメント収集 + 3 段フィルタ + 削減のオーケストレーション
#   入力: $1=pr_number
#         $2=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に JSON 配列文字列。要素スキーマ:
#         { id, user, body, url, created_at }
#         取得失敗時 / コメント 0 件時は "[]"。
#   返り値: 0 固定（エラーは degraded path = "[]" + WARN ログに倒す）
#   AC #55 Req 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2,
#         NFR 2.1, NFR 2.2
#
#   設計判断:
#     - kind（design/impl）に依存する分岐を持たない（impl/design PR で共通呼び出し、Req 6.2）
#     - @claude 文字列を判定式に使わない（Req 2.7、`@claude` mention 必須を opt-out で
#       復活させる新規 env var を追加しない、Req 4.4）
#     - 上限値は内部定数 PI_GENERAL_MAX_COMMENTS（既定 50、env override 可）
#       README には載せない（運用上 default で十分、Req 4.4 の対象外）
#     - サマリは 1 行で出力し、truncate 発動時のみ pi_warn、それ以外は pi_log（NFR 2.2）
# ─────────────────────────────────────────────────────────────────────────────
pi_collect_general_comments() {
  local pr_number="$1"
  local pr_body="${2-}"
  local limit="${PI_GENERAL_MAX_COMMENTS:-50}"

  # 1. GitHub API から raw 一般コメントを取得（既存と同じ timeout / fall-back 方式）
  local raw_general
  if ! raw_general=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント取得に失敗、空配列で続行"
    echo "[]"
    return 0
  fi

  # 2. 射影: { id, user, body, url, created_at } のスキーマに整形（Req 6.2 / Data Model）
  local projected
  if ! projected=$(echo "$raw_general" | jq '[.[] | {
        id,
        user: (.user.login // ""),
        body: (.body // ""),
        url: .html_url,
        created_at: (.created_at // ""),
        "_meta_user_type": (.user.type // "")
      }]' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント JSON の整形に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local fetched
  fetched=$(echo "$projected" | jq 'length' 2>/dev/null || echo "0")

  # 3. last-run TS を抽出（marker 不在時は空文字列 = 初回 round）
  local last_run
  last_run=$(pi_read_last_run "$pr_body")

  # 4. フィルタを順次適用しながら各段の length を測定
  #    順序: self → resolved → event_style → truncate
  local after_self after_resolved after_event final
  local filter_event_input

  # event_style filter は射影段で残した _meta_user_type を user.type の代理として使う
  # （元 jq schema を {id,user,body,url,created_at} に保つ理由: prompt template 互換）
  if ! after_self=$(echo "$projected" | pi_general_filter_self 2>/dev/null); then
    pi_warn "PR #${pr_number}: 自己投稿フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_self
  count_self=$(echo "$after_self" | jq 'length' 2>/dev/null || echo "0")

  if ! after_resolved=$(echo "$after_self" | pi_general_filter_resolved "$last_run" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 過去 round フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_resolved
  count_resolved=$(echo "$after_resolved" | jq 'length' 2>/dev/null || echo "0")

  # event_style フィルタは _meta_user_type を user.type 相当に詰め直してから判定する
  filter_event_input=$(echo "$after_resolved" | jq '[.[] | . + {user: {type: ._meta_user_type, login: (.user)}}]' 2>/dev/null || echo "[]")
  if ! after_event=$(echo "$filter_event_input" | pi_general_filter_event_style 2>/dev/null); then
    pi_warn "PR #${pr_number}: event-style フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  # スキーマ復元: user は文字列 (login) のみに戻し、_meta_user_type も落とす
  after_event=$(echo "$after_event" | jq '[.[] | {id, user: (.user.login // ""), body, url, created_at}]' 2>/dev/null || echo "[]")
  local count_event
  count_event=$(echo "$after_event" | jq 'length' 2>/dev/null || echo "0")

  if ! final=$(echo "$after_event" | pi_general_truncate "$limit" 2>/dev/null); then
    pi_warn "PR #${pr_number}: truncate に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_final
  count_final=$(echo "$final" | jq 'length' 2>/dev/null || echo "0")

  # 5. サマリ 1 行ログ
  local filtered_self filtered_resolved filtered_event truncated
  filtered_self=$((fetched - count_self))
  filtered_resolved=$((count_self - count_resolved))
  filtered_event=$((count_resolved - count_event))
  truncated=$((count_event - count_final))

  # サマリは stderr に出力する（本関数の stdout は JSON 配列に予約されているため）。
  # pi_warn は元々 stderr 直行、pi_log は stdout のため明示的に >&2 で逃がす。
  if [ "$truncated" -gt 0 ]; then
    pi_warn "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=${truncated} (limit=${limit}), final=${count_final}"
  else
    pi_log "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=0, final=${count_final}" >&2
  fi

  echo "$final"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   入力: $1=pr_number, $2=new_round
#   AC 6.1, 7.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_marker() {
  local pr_number="$1"
  local new_round="$2"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、marker 更新をスキップ"
    return 1
  fi

  local marker="<!-- idd-claude:pr-iteration round=${new_round} last-run=${now} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-claude:pr-iteration round=[0-9]+'; then
    # 既存 marker を最新 marker で置換（複数あった場合も全部 1 つに集約）
    new_body=$(echo "$body" | sed -E "s|<!-- idd-claude:pr-iteration round=[0-9]+ last-run=[^>]*-->|${marker}|g")
  else
    # 末尾に追記（前置の改行で見やすく）
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: PR body の hidden marker 更新に失敗"
    return 1
  fi

  # AC 6.1: 着手表明コメント
  local processing_msg
  processing_msg=$(printf '%s\n%s' \
    ":robot: PR Iteration Processor が処理を開始しました (round ${new_round}/${PR_ITERATION_MAX_ROUNDS})。" \
    "<!-- idd-claude:pr-iteration-processing round=${new_round} -->")
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$processing_msg" >/dev/null 2>&1; then
    # コメント投稿失敗はラベル誤遷移のリスクがないため WARN のみ（marker は付いた）
    pi_warn "PR #${pr_number}: 着手表明コメントの投稿に失敗（marker は更新済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels: 成功時のラベル遷移（AC 6.2 / 6.4）
#   --remove-label と --add-label を同一コマンドで指定し原子的に実行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_READY" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (needs-iteration -> ready-for-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels_design: 設計 PR 用のラベル遷移（#35 AC 3.1）
#   needs-iteration 除去 + awaiting-design-review 付与を 1 コマンドで原子的に発行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels_design() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (needs-iteration -> awaiting-design-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_classify_pr_kind: branch 名 + env vars から PR の iteration 種別を判定
#   入力: $1 = head_ref
#   出力: stdout に "design" / "impl" / "none" / "ambiguous" のいずれか
#   返り値: 0
#
#   優先順序（#35 AC 1.1〜1.4 / 4.4）:
#     1. impl pattern と design pattern の両方に合致 → ambiguous
#     2. design pattern のみ合致 + DESIGN_ENABLED=true → design
#     3. design pattern のみ合致 + DESIGN_ENABLED!=true → none（opt-out gate）
#     4. impl pattern のみ合致 → impl
#     5. どちらにも合致しない → none
#
#   副作用なし（純粋関数）。同一入力に対して同一結果。
# ─────────────────────────────────────────────────────────────────────────────
pi_classify_pr_kind() {
  local head_ref="$1"
  local matches_impl=false
  local matches_design=false

  if [[ "$head_ref" =~ $PR_ITERATION_HEAD_PATTERN ]]; then
    matches_impl=true
  fi
  if [[ "$head_ref" =~ $PR_ITERATION_DESIGN_HEAD_PATTERN ]]; then
    matches_design=true
  fi

  if [ "$matches_impl" = "true" ] && [ "$matches_design" = "true" ]; then
    echo "ambiguous"
    return 0
  fi
  if [ "$matches_design" = "true" ]; then
    if [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ]; then
      echo "design"
    else
      echo "none"
    fi
    return 0
  fi
  if [ "$matches_impl" = "true" ]; then
    echo "impl"
    return 0
  fi
  echo "none"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_select_template: kind から prompt template ファイルパスを返す（#35 AC 2.x）
#   入力: $1 = kind ("design" / "impl")
#   出力: stdout に template ファイルパス
#   返り値: 0=ok, 1=template 未配置（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_select_template() {
  local kind="$1"
  local path=""
  case "$kind" in
    design) path="$ITERATION_TEMPLATE_DESIGN" ;;
    impl)   path="$ITERATION_TEMPLATE" ;;
    *)
      pi_warn "pi_select_template: 未知の kind=${kind}"
      return 1
      ;;
  esac
  if [ ! -f "$path" ]; then
    pi_warn "pi_select_template: template not found for kind=${kind}: ${path}"
    return 1
  fi
  echo "$path"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_escalate_to_failed: 上限到達時の claude-failed 昇格 + エスカレコメント
#   入力: $1=pr_number, $2=round, $3=max_rounds
#   AC 7.2, 7.3
# ─────────────────────────────────────────────────────────────────────────────
pi_escalate_to_failed() {
  local pr_number="$1"
  local round="$2"
  local max_rounds="$3"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: claude-failed 昇格時のラベル遷移に失敗"
    return 1
  fi

  local escalation_body
  escalation_body=$(cat <<EOF
## :rotating_light: PR Iteration 上限到達 (#26 PR Iteration Processor)

本 PR の累計自動 iteration 回数が上限 (\`PR_ITERATION_MAX_ROUNDS=${max_rounds}\`) に達しました。
\`needs-iteration\` ラベルを除去し、\`claude-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- 上限値: ${max_rounds} round
- 上限到達のため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Claude の判断を確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-claude:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`claude-failed\` ラベルを除去
   - \`needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`claude-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#26) が自動投稿しました。_
EOF
)
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$escalation_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: エスカレコメントの投稿に失敗（ラベル遷移は完了済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_build_iteration_prompt: 指定 template に変数を注入
#   入力: $1=pr_number, $2=pr_json, $3=round, $4=template_path（省略時は impl 用既定）
#   出力: stdout に prompt 文字列
#   AC 3.1, 3.2, 3.3, 3.4, 3.5（#26）/ #35 で kind 引数の代わりに template path を受け取る
# ─────────────────────────────────────────────────────────────────────────────
pi_build_iteration_prompt() {
  local pr_number="$1"
  local pr_json="$2"
  local round="$3"
  # #35: template path を呼び出し元から渡す。省略時は impl 用 template を使う（後方互換）。
  local tmpl_path="${4:-$ITERATION_TEMPLATE}"

  local pr_title pr_url head_ref base_ref pr_body
  pr_title=$(echo "$pr_json" | jq -r '.title // ""')
  pr_url=$(echo "$pr_json"   | jq -r '.url // ""')
  head_ref=$(echo "$pr_json" | jq -r '.headRefName // ""')
  base_ref=$(echo "$pr_json" | jq -r '.baseRefName // ""')
  pr_body=$(echo "$pr_json"  | jq -r '.body // ""')

  # title が JSON で取れていない場合（pr_json は --json title を含まないかも）は gh で補完
  if [ -z "$pr_title" ]; then
    pr_title=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json title --jq '.title // ""' 2>/dev/null || echo "")
  fi

  # 関連 Issue 番号: head branch (`claude/issue-N-...`) → PR body の順で抽出
  local issue_number=""
  issue_number=$(echo "$head_ref" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$pr_body" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi

  local spec_dir=""
  local requirements_md="(関連 Issue が見つからないか、対応する requirements.md が存在しません)"
  if [ -n "$issue_number" ]; then
    local found
    found=$(ls -d "${REPO_DIR}/docs/specs/${issue_number}-"* 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -f "${found}/requirements.md" ]; then
      spec_dir="docs/specs/$(basename "$found")"
      requirements_md=$(cat "${found}/requirements.md")
    fi
  fi

  # PR diff（base..head）
  local pr_diff="(diff の取得に失敗)"
  pr_diff=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
    gh pr diff "$pr_number" --repo "$REPO" 2>/dev/null || echo "(diff の取得に失敗)")

  # AC 3.1: 最新 review の line コメントを取得（reviews 配列の最後の要素 = 時系列で最新）
  local line_comments_json="[]"
  local reviews_json latest_review_id
  if reviews_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    latest_review_id=$(echo "$reviews_json" | jq -r 'if length > 0 then (.[length-1].id|tostring) else "" end')
    if [ -n "$latest_review_id" ]; then
      local raw_line
      if raw_line=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh api "/repos/${REPO}/pulls/${pr_number}/reviews/${latest_review_id}/comments" 2>/dev/null); then
        line_comments_json=$(echo "$raw_line" | jq '[.[] | {id, path, line, user: (.user.login // ""), body}]')
      fi
    fi
  fi

  # #55: 一般コメント収集（mention 篩い分けを撤廃 + 自己投稿 / 過去 round / system 除外
  #     + 大量時 truncate）。kind に依存せず impl/design 共通で同一ロジックを通す（Req 6.2）。
  local general_comments_json
  general_comments_json=$(pi_collect_general_comments "$pr_number" "$pr_body")

  # template に変数を注入する。
  # 単一行値（PR 番号 / タイトル / URL 等）は awk -v で渡し、行内の {{KEY}} を文字列置換。
  # 複数行値（LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / PR_DIFF / REQUIREMENTS_MD）は
  # awk -v では改行を扱えないため、export 経由で ENVIRON[] から取得し、
  # 「行全体が {{KEY}} のみ」のテンプレ行をブロックごと置換する（template はその前提で書かれている）。
  if [ ! -f "$tmpl_path" ]; then
    pi_warn "template not found: $tmpl_path"
    return 1
  fi

  # 改行入り値を子プロセスに渡すため export
  export PI_LINE_JSON="$line_comments_json"
  export PI_GENERAL_JSON="$general_comments_json"
  export PI_PR_DIFF="$pr_diff"
  export PI_REQS_MD="$requirements_md"

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v round="$round" \
    -v max_rounds="$PR_ITERATION_MAX_ROUNDS" \
    -v issue_number="${issue_number:-(none)}" \
    -v spec_dir="${spec_dir:-(none)}" \
    '
    function repl(s, key, val,    out, idx) {
      out = ""
      while ((idx = index(s, key)) > 0) {
        out = out substr(s, 1, idx-1) val
        s = substr(s, idx + length(key))
      }
      return out s
    }
    {
      # 行全体が複数行プレースホルダの場合は ENVIRON 経由で展開
      if ($0 == "{{LINE_COMMENTS_JSON}}")    { print ENVIRON["PI_LINE_JSON"]; next }
      if ($0 == "{{GENERAL_COMMENTS_JSON}}") { print ENVIRON["PI_GENERAL_JSON"]; next }
      if ($0 == "{{PR_DIFF}}")               { print ENVIRON["PI_PR_DIFF"]; next }
      if ($0 == "{{REQUIREMENTS_MD}}")       { print ENVIRON["PI_REQS_MD"]; next }
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{ROUND}}", round)
      line = repl(line, "{{MAX_ROUNDS}}", max_rounds)
      line = repl(line, "{{ISSUE_NUMBER}}", issue_number)
      line = repl(line, "{{SPEC_DIR}}", spec_dir)
      print line
    }
    ' "$tmpl_path"
  local awk_rc=$?

  unset PI_LINE_JSON PI_GENERAL_JSON PI_PR_DIFF PI_REQS_MD
  return $awk_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_run_iteration: 1 PR 分の iteration を実行（fresh context Claude 起動）
#   入力: $1=pr_json
#   戻り値: 0=success(commit+push or reply-only), 1=failure, 2=escalated(round上限到達),
#           3=skip (kind=none/ambiguous, #35)
#   AC 3.6, 4.x, 5.x, 6.2, 6.3, 7.x, 8.3, 9.2, NFR 1.1, NFR 1.3 (#26)
#   #35: kind 判定で design / impl を分岐し、template と finalize 関数を切り替える
# ─────────────────────────────────────────────────────────────────────────────
pi_run_iteration() {
  local pr_json="$1"
  local pr_number head_ref base_ref pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  # #35 AC 1.1〜1.4 / 4.4: kind 判定（design / impl / none / ambiguous）
  local kind
  kind=$(pi_classify_pr_kind "$head_ref")

  case "$kind" in
    none)
      pi_log "PR #${pr_number}: kind=none head=${head_ref} (does not match design/impl pattern), skip"
      return 3
      ;;
    ambiguous)
      pi_warn "PR #${pr_number}: kind=ambiguous head=${head_ref} (matches both design and impl pattern), skip"
      return 3
      ;;
    design|impl) : ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} (unknown), skip"
      return 3
      ;;
  esac

  # #35 AC 2.x: kind に応じた template path を取得
  local tmpl_path
  if ! tmpl_path=$(pi_select_template "$kind"); then
    pi_warn "PR #${pr_number}: kind=${kind} 用 template が取得できず iteration 中止"
    return 1
  fi

  local round
  round=$(pi_read_round_counter "$pr_number")

  # AC 7.2 (#26): 上限到達なら escalate（kind 共通、#35 AC 3.4 / 6.5）
  if [ "$round" -ge "$PR_ITERATION_MAX_ROUNDS" ]; then
    pi_log "PR #${pr_number}: kind=${kind} round=${round} >= max=${PR_ITERATION_MAX_ROUNDS}, claude-failed に昇格"
    pi_escalate_to_failed "$pr_number" "$round" "$PR_ITERATION_MAX_ROUNDS" || true
    return 2
  fi

  local next_round=$((round + 1))

  # AC 6.1: 着手表明（marker 更新 + コメント、kind 非依存、#35 AC 6.1 / 6.5）
  if ! pi_post_processing_marker "$pr_number" "$next_round"; then
    pi_warn "PR #${pr_number}: kind=${kind} 着手表明に失敗、iteration 中止"
    return 1
  fi

  pi_log "PR #${pr_number}: kind=${kind} round=${next_round}/${PR_ITERATION_MAX_ROUNDS} 着手 (${pr_url})"

  # サブシェル + trap で必ず main に戻す（AC 8.3）
  local rc=0
  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout 'main' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin の最新状態に追従、AC 4.4）
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: git fetch origin ${head_ref} に失敗"
      exit 1
    fi
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 1
    fi

    # prompt を生成（#35: kind に応じた template path を渡す）
    local prompt
    if ! prompt=$(pi_build_iteration_prompt "$pr_number" "$pr_json" "$next_round" "$tmpl_path"); then
      pi_warn "PR #${pr_number}: prompt 組み立てに失敗"
      exit 1
    fi

    # AC 3.6: fresh context で起動（--resume / --continue は使わない）
    # NFR 1.1: --max-turns で turn 数上限
    local pi_log_file
    pi_log_file="$LOG_DIR/pr-iteration-${kind}-${pr_number}-round${next_round}-$(date +%Y%m%d-%H%M%S).log"
    if ! claude \
        --print "$prompt" \
        --model "$PR_ITERATION_DEV_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$PR_ITERATION_MAX_TURNS" \
        --output-format stream-json \
        --verbose \
        >> "$pi_log_file" 2>&1; then
      pi_warn "PR #${pr_number}: kind=${kind} Claude 実行が失敗 (log: ${pi_log_file})"
      exit 1
    fi
    pi_log "PR #${pr_number}: kind=${kind} Claude 実行完了 (log: ${pi_log_file})"
    exit 0
  )
  rc=$?
  # 保険: 呼び出し元でも main に戻す
  git checkout main >/dev/null 2>&1 || true

  if [ $rc -eq 0 ]; then
    # AC 6.2 (#26) / #35 AC 3.1 / 3.2: kind に応じたラベル遷移
    local finalize_ok=false
    case "$kind" in
      design)
        if pi_finalize_labels_design "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (needs-iteration -> awaiting-design-review)"
          finalize_ok=true
        fi
        ;;
      impl)
        if pi_finalize_labels "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (needs-iteration -> ready-for-review)"
          finalize_ok=true
        fi
        ;;
    esac
    if [ "$finalize_ok" = "true" ]; then
      return 0
    fi
    pi_warn "PR #${pr_number}: kind=${kind} ラベル遷移失敗、needs-iteration を残置"
    return 1
  else
    # AC 6.3 (#26) / #35 AC 3.3: 失敗 → needs-iteration を残し WARN
    pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=fail (needs-iteration を残置)"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_iteration: PR Iteration Processor のエントリ関数
#   AC 1.6, 2.1, 2.2, 8.5, 9.1, 9.3, NFR 1.2, NFR 2.3
# ─────────────────────────────────────────────────────────────────────────────
process_pr_iteration() {
  # AC 2.1: opt-in gate
  if [ "$PR_ITERATION_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3 / AC 8.5: dirty working tree 検知
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pi_error "dirty working tree を検出しました。PR Iteration Processor をスキップします。"
    return 0
  fi

  pi_log "サイクル開始 (max_prs=${PR_ITERATION_MAX_PRS}, max_rounds=${PR_ITERATION_MAX_ROUNDS}, model=${PR_ITERATION_DEV_MODEL}, design_enabled=${PR_ITERATION_DESIGN_ENABLED}, timeout=${PR_ITERATION_GIT_TIMEOUT}s)"

  local prs_json
  prs_json=$(pi_fetch_candidate_prs)
  local total
  total=$(echo "$prs_json" | jq 'length')

  # #35 NFR 3.2: 候補 PR の design / impl 内訳をログに記録（kind=ambiguous も含む）。
  # candidate 段階では impl pattern OR (DESIGN_ENABLED=true AND design pattern) で絞られる
  # ため、ここでは bash 側で同じ正規表現照合を行って breakdown を出す。
  local design_count=0
  local impl_count=0
  local ambiguous_count=0
  if [ "$total" -gt 0 ]; then
    local breakdown
    breakdown=$(echo "$prs_json" | jq -r \
      --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
      --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
      --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
      '[.[] | .headRefName] as $heads
       | reduce $heads[] as $h ({"design":0, "impl":0, "ambiguous":0};
           if ($h | test($impl_pattern)) and ($h | test($design_pattern))
             then .ambiguous += 1
           elif ($h | test($design_pattern)) and ($design_enabled == "true")
             then .design += 1
           elif ($h | test($impl_pattern))
             then .impl += 1
           else . end)
       | "\(.design) \(.impl) \(.ambiguous)"')
    # shellcheck disable=SC2086
    set -- $breakdown
    design_count="${1:-0}"
    impl_count="${2:-0}"
    ambiguous_count="${3:-0}"
  fi

  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$PR_ITERATION_MAX_PRS" ]; then
    target_count="$PR_ITERATION_MAX_PRS"
    skipped_overflow=$((total - PR_ITERATION_MAX_PRS))
    pi_log "対象候補 ${total} 件中、上限 ${PR_ITERATION_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し、内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  else
    pi_log "対象候補 ${total} 件、処理対象 ${target_count} 件（内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  fi

  if [ "$target_count" -eq 0 ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  local success=0
  local fail=0
  local skip=0
  local escalated=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  while IFS= read -r pr_json; do
    local rc=0
    pi_run_iteration "$pr_json" || rc=$?
    case $rc in
      0)  success=$((success + 1)) ;;
      2)  escalated=$((escalated + 1)) ;;
      3)  skip=$((skip + 1)) ;;       # #35: kind=none / ambiguous は skip としてカウント
      *)  fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で main に戻す
    git checkout main >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  # #35 NFR 3.1 / 3.2: サマリにも design / impl 内訳を出して grep 集計可能にする
  pi_log "サマリ: success=${success}, fail=${fail}, skip=${skip}, escalated=${escalated}, overflow=${skipped_overflow} (design=${design_count}, impl=${impl_count})"

  # 念のため最終確認で main に戻す
  git checkout main >/dev/null 2>&1 || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Design Review Release Processor (#40)
#
# `awaiting-design-review` ラベルが付いた Issue について、リンクされた設計 PR
# （head branch が `^claude/issue-<N>-design-` 規約）が merged 状態なら、
# Issue からラベルを除去してステータスコメントを 1 件投稿する。
#
# 既存運用（人間が手動でラベルを外す運用）を壊さないため opt-in
# （DESIGN_REVIEW_RELEASE_ENABLED=true で有効化、デフォルト false）。
# 既存 LOCK_FILE / LOG_DIR / exit code / cron 登録文字列は不変。
# Phase A / Re-check / PR Iteration と同じ flock 境界内で直列実行する。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

drr_log() {
  echo "[$(date '+%F %T')] design-review-release: $*"
}
drr_warn() {
  echo "[$(date '+%F %T')] design-review-release: WARN: $*" >&2
}
drr_error() {
  echo "[$(date '+%F %T')] design-review-release: ERROR: $*" >&2
}

# 与えられた Issue が、本機能が以前のサイクルで投稿したステータスコメントを既に
# 持っているかを判定する（hidden HTML marker による既処理判定）。
#   入力: $1 = issue_number
#   出力: stdout に "true" or "false"
#   返り値: 0 = 判定成功 / 1 = API エラー or タイムアウト（呼び出し元で WARN）
# AC 4.2 / 4.3 / 4.4 / 5.3 / 5.4
drr_already_processed() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$DRR_GH_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local marker_re="idd-claude:design-review-release issue=${issue_number}"
  if echo "$comments_json" | jq -e --arg re "$marker_re" \
      '.comments // [] | map(.body // "") | any(test($re))' >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# 与えられた Issue 番号にリンクされた、head branch が DESIGN_REVIEW_RELEASE_HEAD_PATTERN
# にマッチし、かつ body に `Refs #<issue_number>` を含む merged PR の番号を返す。
# 複数件マッチ時は最大番号 = 最新を採用する。
#   入力: $1 = issue_number
#   出力: stdout に PR 番号、該当無しなら空文字
#   返り値: 0 = 検出 or 該当無し（共に正常） / 1 = API エラー or タイムアウト
# AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 5.3 / 5.4 / NFR 2.2
drr_find_merged_design_pr() {
  local issue_number="$1"
  local prs_json
  # head pattern を server-side クエリで一次絞り込み（in:head + 規約 prefix）。
  # 複数件マッチを許容するため limit=20。
  if ! prs_json=$(timeout "$DRR_GH_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --search "is:pr is:merged claude/issue-${issue_number}-design- in:head" \
      --json number,headRefName,body,mergedAt \
      --limit 20 2>/dev/null); then
    return 1
  fi

  # 取得結果が空 / 不正な場合に jq エラーで落ちないよう fail-safe で `// []` を挟む。
  local pattern="$DESIGN_REVIEW_RELEASE_HEAD_PATTERN"
  local refs_pattern="(Refs|refs|Ref|ref) #${issue_number}([^0-9]|$)"
  local pr_number
  pr_number=$(echo "$prs_json" | jq -r \
    --arg pattern "$pattern" \
    --arg refs_re "$refs_pattern" \
    '[(. // [])[]
      | select(.headRefName | test($pattern))
      | select((.body // "") | test($refs_re))
      | .number
    ] | sort | last // ""' 2>/dev/null || echo "")
  echo "$pr_number"
  return 0
}

# 確定した除去対象 Issue に対し、`awaiting-design-review` ラベル除去 + ステータス
# コメント投稿を順次実行する。PR 側操作・push・close は一切行わない（NFR 2.1 / 2.3）。
#   入力: $1 = issue_number, $2 = merged_pr_number
#   返り値: 0 = ラベル除去 + コメント投稿 成功 / 1 = いずれかが失敗
# AC 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 3.6 / 5.3 / 5.4 / 6.7 / 7.6
drr_remove_label_and_comment() {
  local issue_number="$1"
  local merged_pr_number="$2"

  # AC 3.1 / 3.4: ラベル除去。失敗時はコメントを投稿しない。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue edit "$issue_number" \
      --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ラベル除去 API 失敗（タイムアウト or 4xx/5xx）。コメント投稿は skip し、次サイクルで再試行します。"
    return 1
  fi

  # AC 3.2 / 3.3 / 4.3: ステータスコメント本文（末尾に hidden marker を含む）。
  local body
  body=$(cat <<EOF
## 自動: 設計 PR merge を検出

設計 PR #${merged_pr_number} が merged されました。
本 Issue から \`awaiting-design-review\` ラベルを自動除去しました。

次回 cron tick で Developer が **impl-resume モード**で自動起動し、
\`docs/specs/<N>-<slug>/\` 配下の design.md / tasks.md に従って実装 PR を作成します。

---

_本コメントは \`local-watcher/bin/issue-watcher.sh\` の Design Review Release Processor が
投稿しました。\`DESIGN_REVIEW_RELEASE_ENABLED=true\` で有効化されています。_

<!-- idd-claude:design-review-release issue=${issue_number} pr=${merged_pr_number} -->
EOF
)

  # AC 3.5: コメント投稿失敗時もラベルは除去済み。次サイクルで Issue は impl-resume へ進める。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue comment "$issue_number" \
      --repo "$REPO" \
      --body "$body" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ステータスコメント投稿 API 失敗（ラベルは除去済み、後続 Issue 処理は継続）。"
    return 1
  fi

  return 0
}

# Design Review Release Processor のエントリ関数。
# 1 watcher サイクル内で `awaiting-design-review` 付き Issue を検出し、
# 設計 PR が merged なら ラベル除去 + コメント投稿を順次実行する。
# AC 1.1 / 1.4 / 2.1 / 2.7 / 4.1 / 4.4 / 4.5 / 5.2 / 5.5 / 6.1 / 6.2 / 6.3 / 7.5
process_design_review_release() {
  # AC 1.1 / 1.4 / 7.5: opt-in gate（無効化時は完全スキップ）
  if [ "$DESIGN_REVIEW_RELEASE_ENABLED" != "true" ]; then
    return 0
  fi

  drr_log "サイクル開始 (max_issues=${DESIGN_REVIEW_RELEASE_MAX_ISSUES}, head_pattern=${DESIGN_REVIEW_RELEASE_HEAD_PATTERN}, timeout=${DRR_GH_TIMEOUT}s)"

  # AC 2.1 / 2.7 / 4.1 / 4.5: server-side filter で `awaiting-design-review` を必須に、
  # `claude-failed` / `needs-decisions` を除外。人間が先に手動除去した Issue は候補に上がらない。
  # Issue #54 Req 1.1 / 5.1: PR 専用ラベル `needs-iteration` が Issue 側に誤付与された
  # ケースは Documentation Set 全体で「PR 適用」と一貫させるため、ここでも候補から除外する。
  local issues_json
  if ! issues_json=$(timeout "$DRR_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\"" \
      --json number,title,url,labels \
      --limit 100 2>/dev/null); then
    drr_warn "候補 Issue 取得 API 失敗（タイムアウト or 4xx/5xx）。本サイクルの Design Review Release Processor は skip。"
    return 0
  fi

  # client-side fail-safe filter: label 配列に `awaiting-design-review` あり、
  # `claude-failed` / `needs-decisions` なし（server-side filter の二重ガード）。
  local filtered_json
  filtered_json=$(echo "$issues_json" | jq -c \
    --arg awaiting "$LABEL_AWAITING_DESIGN" \
    --arg failed "$LABEL_FAILED" \
    --arg needs_decisions "$LABEL_NEEDS_DECISIONS" \
    '[(. // [])[]
      | select((.labels // []) | map(.name) | index($awaiting))
      | select(((.labels // []) | map(.name) | index($failed)) | not)
      | select(((.labels // []) | map(.name) | index($needs_decisions)) | not)
    ]' 2>/dev/null || echo "[]")

  local total
  total=$(echo "$filtered_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$DESIGN_REVIEW_RELEASE_MAX_ISSUES" ]; then
    target_count="$DESIGN_REVIEW_RELEASE_MAX_ISSUES"
    skipped_overflow=$((total - DESIGN_REVIEW_RELEASE_MAX_ISSUES))
    drr_log "対象候補 ${total} 件中、上限 ${DESIGN_REVIEW_RELEASE_MAX_ISSUES} 件のみ処理（${skipped_overflow} 件は次回持ち越し: overflow=${skipped_overflow}）"
  else
    drr_log "対象候補 ${total} 件、処理対象 ${target_count} 件、overflow=${skipped_overflow}"
  fi

  if [ "$target_count" -eq 0 ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local issue_iter
  issue_iter=$(echo "$filtered_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$issue_iter" ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local kept=0
  local skipped=0
  local failed=0
  # AC 4.4: 同一サイクル内での重複処理ガード（gh issue list の結果は一意のはずだが念のため）
  local processed_numbers=""

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local issue_number
    issue_number=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "")
    if [ -z "$issue_number" ] || [ "$issue_number" = "null" ]; then
      drr_warn "Issue 番号の解析に失敗: ${issue_json}"
      failed=$((failed + 1))
      continue
    fi

    # AC 4.4: 同一サイクル内で同一 Issue を 2 回処理しない
    case " $processed_numbers " in
      *" $issue_number "*)
        drr_log "Issue #${issue_number}: 同一サイクル内で既に処理済み、skip"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    processed_numbers="$processed_numbers $issue_number"

    # AC 4.2 / 4.3: 既処理判定（hidden marker チェック）
    local already
    if ! already=$(drr_already_processed "$issue_number"); then
      drr_warn "Issue #${issue_number}: 既処理判定 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ "$already" = "true" ]; then
      drr_log "Issue #${issue_number}: action=skip (already processed)"
      skipped=$((skipped + 1))
      continue
    fi

    # AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6: merged 設計 PR の検出
    local merged_pr_number
    if ! merged_pr_number=$(drr_find_merged_design_pr "$issue_number"); then
      drr_warn "Issue #${issue_number}: PR 検出 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ -z "$merged_pr_number" ]; then
      # AC 2.5 / 2.6: リンク PR 0 件 or merged 0 件 → kept
      drr_log "Issue #${issue_number}: merged-design-pr=none, action=kept"
      kept=$((kept + 1))
      continue
    fi

    # AC 3.1 / 3.2 / 3.3: ラベル除去 + ステータスコメント投稿
    if drr_remove_label_and_comment "$issue_number" "$merged_pr_number"; then
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=label removed + commented"
      removed=$((removed + 1))
    else
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=fail"
      failed=$((failed + 1))
    fi
  done <<< "$issue_iter"

  drr_log "サマリ: removed=${removed}, kept=${kept}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"
  return 0
}

# Phase A 直後に PR Iteration Processor を実行（AC 8.1 / 8.2: 同一 flock 内で直列実行）
process_pr_iteration || pi_warn "process_pr_iteration が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Design Review Release Processor を Issue 処理ループの直前に実行（#40 AC 1.3 / 1.5）
process_design_review_release || drr_warn "process_design_review_release が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) — impl 系モード stage 分割パイプライン
#
# 既存の impl / impl-resume モードは DEV_PROMPT 1 回で PM + Developer + PjM を
# 直列起動していたが、Reviewer サブエージェントを独立 context で挟むため、以下の
# stage に分割する:
#
#   Stage A  : PM + Developer（ただし impl-resume では PM をスキップ）
#   Stage B  : Reviewer (round=1)
#   Stage A' : Developer 再実行（reject 時のみ、最大 1 回）
#   Stage B' : Reviewer (round=2、reject 時のみ)
#   Stage C  : PjM（PR 作成）
#
# 各 stage は `claude --print` の独立プロセスで起動。stage 間の context 共有は
# しない（要件 2.2「独立 Claude セッション」）。Reviewer 判定は
# `docs/specs/<N>-<slug>/review-notes.md` の最終 RESULT 行で受け渡す。
#
# 設計参照: docs/specs/20-phase-1-reviewer-subagent-gate/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Reviewer / Pipeline 専用ロガー（既存 mq_log / pi_log と同形式）
rv_log() {
  echo "[$(date '+%F %T')] reviewer: $*"
}
rv_dev_log() {
  echo "[$(date '+%F %T')] developer: $*"
}

# ─── Prompt Builders（Stage A / A' / B / C 用 4 関数）───
#
# 既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲する。
# 入力は環境変数（NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL /
# MODE / ARCHITECT_REASON）と関数引数。stdout に prompt 文字列を出力する。

# Stage A: PM + Developer（impl では PM 起動、impl-resume では Developer のみ）
# 既存 DEV_PROMPT の STEPS から「PjM 起動」を除外したもの。
build_dev_prompt_a() {
  local mode="$1"
  local flow_label
  local steps

  case "$mode" in
    impl)
      flow_label="PM → Developer（Reviewer ゲート前）"
      steps=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\`
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
    impl-resume)
      flow_label="Developer（Reviewer ゲート前 / 設計 PR merge 済み）"
      steps=$(cat <<EOF
1. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は設計 PR で人間レビュー済み（main に merge 済み）。**書き換えないこと**
   - tasks.md の numeric ID 順にタスクを消化する
   - 矛盾や疑問があれば PR 本文「確認事項」に記載（書き換えはしない）
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
  esac

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を ${flow_label} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（main から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方
${steps}

## 制約
- main に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（次の Reviewer ステージで独立レビューを受けます）
EOF
}

# Stage A' (Developer 再実行用): Reviewer reject の Findings を inline で渡し、
# Developer に是正を依頼する。PM は再起動しない（要件は不変）。
build_dev_prompt_redo() {
  local review_notes_path="$1"
  local review_notes_content
  if [ -f "$review_notes_path" ]; then
    review_notes_content=$(cat "$review_notes_path")
  else
    review_notes_content="(review-notes.md が見つかりません)"
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
直前の Reviewer サブエージェントが reject を出したため、Developer の再実装を依頼します。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`

## 進め方

1. developer サブエージェントを起動し、上記 Findings の **Required Action** を順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後 \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記

## 制約
- main に直接 push しないこと
- product-manager / project-manager サブエージェントは起動しないこと
  （PM は不要、PjM は次の Reviewer round=2 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
EOF
}

# Stage B (Reviewer): reviewer サブエージェントを独立 context で起動し、
# review-notes.md を書かせる。git diff main..HEAD と round 情報を inline で渡す。
build_reviewer_prompt() {
  local round="$1"
  local prev_result="$2"   # round=2 のみ意味あり、round=1 は "(none)"
  local diff_content
  # diff が空でも壊れないよう || true で fallback
  diff_content=$(git diff main..HEAD 2>/dev/null || true)
  if [ -z "$diff_content" ]; then
    diff_content="(差分が取得できませんでした。Reviewer が Bash で git diff main..HEAD を再取得してください)"
  fi
  local head_sha
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
Developer の実装が一段落したため、reviewer サブエージェントによる **独立レビュー**
（round=${round} / 最大 2 round）を実施してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- HEAD commit  : ${head_sha}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 必読ファイル

reviewer サブエージェントは着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（\`_Requirements:_\` / \`_Boundary:_\` アノテーション）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 最新差分（main..HEAD）

\`\`\`diff
${diff_content}
\`\`\`

## 進め方

reviewer サブエージェントを起動し、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 つに限定
- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと（review-notes.md は次の
  Developer または PjM が commit します）
- スタイル / 命名 / lint / フォーマットの観点での reject はしないこと
EOF
}

# Stage C (PjM): 既存 DEV_PROMPT の PjM 起動部分のみを抜き出し。
# Reviewer の approve を受けた後、project-manager サブエージェントが PR を作成する。
# PR 本文の構造は本機能導入前と等価（要件 6.5）。
build_dev_prompt_c() {
  local mode="$1"
  local design_pr_note=""
  if [ "$mode" = "impl-resume" ]; then
    design_pr_note=$'   - PR 本文に対応する設計 PR 番号を記載（直近の main 上の merge commit から `git log --oneline --merges` で探す）'
  else
    design_pr_note='   - 設計 PR は走っていないため「関連 PR: なし」と明記すること'
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
Developer の実装と Reviewer の独立レビュー（approve）が完了しました。
project-manager サブエージェントを起動し、最終 PR を作成してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（実装 commit が積まれた状態。push 済み）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方

1. \`${SPEC_DIR_REL}/review-notes.md\` を **本ブランチに git add / git commit** してから push する
   - commit メッセージ: \`docs(review): add reviewer notes for #${NUMBER}\`
   - 既に commit 済みなら skip
2. project-manager サブエージェントを **implementation モード** で起動
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - PR 本文は project-manager.md の「実装 PR 本文テンプレート」に従う
${design_pr_note}
   - PR 本文の「確認事項」セクションに、必要なら review-notes.md の参照リンクを 1 行記載
   - Issue ラベル: claude-picked-up → ready-for-review に付け替え
   - Issue にコメントで実装 PR リンクを投稿

## 制約
- main に直接 push しないこと
- Reviewer の approve 判定を覆さないこと（PR 本文に判定結果を逐語転載しない。review-notes.md の
  参照に留める）
- 仕様変更や追加実装はしないこと（PjM はコードを変更しない）
EOF
}

# ─── parse_review_result <path> ───
#
# review-notes.md から「最後に出現する RESULT 行」と Findings の Category / Target を抽出する。
# stdout に TSV 1 行で出力: <result>\t<categories>\t<target_ids>
#
# - result      ∈ {approve, reject}
# - categories  = カンマ区切り（reject 時のみ。approve 時は空文字）
# - target_ids  = カンマ区切り requirement ID または `boundary:<component>` 形式
#
# 戻り値:
#   0 = 抽出成功
#   2 = ファイル無 / RESULT 行欠落 / 値不正
parse_review_result() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 2
  fi

  # 最後に出現する RESULT 行のみを採用（fail-safe）。
  # 行頭がそのまま `RESULT: approve` または `RESULT: reject` のもののみ受け付ける。
  local result_line
  result_line=$(grep -E '^RESULT: (approve|reject)$' "$path" | tail -1 || true)
  if [ -z "$result_line" ]; then
    return 2
  fi

  local result="${result_line#RESULT: }"
  case "$result" in
    approve|reject) ;;
    *) return 2 ;;
  esac

  local categories=""
  local target_ids=""
  if [ "$result" = "reject" ]; then
    # Findings ブロックの "**Category**: ..." 行と "**Target**: ..." 行を抽出。
    # Findings は markdown bullet なので、行頭の "- " も含めて許容する。
    categories=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Category\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Category\*\*:[[:space:]]*//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
    target_ids=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Target\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Target\*\*:[[:space:]]*//' \
                   | sed -E 's/（.*$//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
  fi

  printf '%s\t%s\t%s\n' "$result" "$categories" "$target_ids"
  return 0
}

# ─── run_reviewer_stage <round> ───
#
# Reviewer サブエージェントを 1 回起動し、review-notes.md の最終 RESULT 行を抽出して
# 戻り値で結果を呼び出し元に返す。
#
# 入力:
#   $1 = round (1 | 2)
#   環境変数: NUMBER, BRANCH, SPEC_DIR_REL, LOG, REPO_DIR
# 副作用:
#   - $LOG に Reviewer 起動ログ（model / max-turns / 結果）を append
#   - $REPO_DIR/$SPEC_DIR_REL/review-notes.md が Reviewer によって作成 / 上書き
# 戻り値:
#   0 = approve
#   1 = reject
#   2 = 異常終了（claude crash / parse 失敗 / RESULT 行欠落）
run_reviewer_stage() {
  local round="$1"
  local prev_result="(none)"

  # round=2 の場合、直前 review-notes.md の RESULT 行を Reviewer に伝える
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    prev_result=$(grep -E '^RESULT: (approve|reject)$' "$notes_path" | tail -1 || echo "(none)")
  fi

  rv_log "round=$round start (model=$REVIEWER_MODEL, max-turns=$REVIEWER_MAX_TURNS)" >> "$LOG"

  local prompt
  prompt=$(build_reviewer_prompt "$round" "$prev_result")

  echo "--- Reviewer 実行 (round=$round) ---" >> "$LOG"
  if ! claude \
      --print "$prompt" \
      --model "$REVIEWER_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$REVIEWER_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1; then
    rv_log "round=$round result=error reason=claude-exit-nonzero" >> "$LOG"
    return 2
  fi

  # review-notes.md を parse
  local parsed
  if ! parsed=$(parse_review_result "$notes_path"); then
    rv_log "round=$round result=error reason=parse-failed" >> "$LOG"
    return 2
  fi

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      rv_log "round=$round result=approve verified=$targets" >> "$LOG"
      return 0
      ;;
    reject)
      rv_log "round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      return 1
      ;;
    *)
      rv_log "round=$round result=error reason=unknown-result" >> "$LOG"
      return 2
      ;;
  esac
}

# ─── failure 共通遷移ヘルパー ───
#
# Stage 失敗時の claude-failed 遷移を一元化。引数で原因種別と Issue コメント追加情報を受け取る。
# - $1 = stage 識別子（"stageA" / "stageA-redo" / "stageB" / "stageC" / "reviewer-error" / "reviewer-reject2"）
# - $2 = Issue コメントに追加する補足（reject 理由など。空文字可）
mark_issue_failed() {
  local stage="$1"
  local extra_body="$2"

  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: ${stage}）。

ログ: \`$LOG\`"
  if [ -n "$extra_body" ]; then
    body="${body}

${extra_body}"
  fi
  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── run_impl_pipeline ───
#
# impl / impl-resume モードの Stage 状態機械を実装する。
#
#   START → Stage A → Stage B(round=1)
#                    ├─ approve → Stage C → TERMINAL_OK
#                    ├─ reject  → Stage A' → Stage B(round=2)
#                    │                       ├─ approve → Stage C → TERMINAL_OK
#                    │                       ├─ reject  → TERMINAL_FAILED (with Issue comment)
#                    │                       └─ error   → TERMINAL_FAILED (with $LOG path)
#                    └─ error   → TERMINAL_FAILED (with $LOG path)
#
#   Stage A / A' / C の非 0 exit は既存 Developer 失敗時遷移と同等メッセージ。
#
# 入力 (環境変数経由): NUMBER, TITLE, BODY, URL, BRANCH, MODE, SPEC_DIR_REL, LOG, REPO,
#                      DEV_MODEL, DEV_MAX_TURNS, REVIEWER_MODEL, REVIEWER_MAX_TURNS
# 戻り値:
#   0 = pipeline 成功（Stage C も成功 / PR 作成済み）
#   1 = Stage A / A' / B / B' / C いずれかで失敗 → claude-failed 既に付与済み
run_impl_pipeline() {
  local prompt_a prompt_redo prompt_c
  local rev_rc

  # ── Stage A: PM + Developer（impl-resume では PM スキップ）──
  echo "--- Stage A 実行（$MODE / PM + Developer）---" >> "$LOG"
  prompt_a=$(build_dev_prompt_a "$MODE")
  if ! claude \
      --print "$prompt_a" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1; then
    echo "❌ #$NUMBER: Stage A 失敗" | tee -a "$LOG"
    mark_issue_failed "stageA" ""
    return 1
  fi
  echo "✅ #$NUMBER: Stage A 完了" | tee -a "$LOG"

  # ── Stage B (round=1): Reviewer ──
  rev_rc=0
  run_reviewer_stage 1 || rev_rc=$?
  case $rev_rc in
    0)
      echo "✅ #$NUMBER: Reviewer round=1 approve" | tee -a "$LOG"
      ;;
    1)
      echo "🔁 #$NUMBER: Reviewer round=1 reject → Developer 再実行" | tee -a "$LOG"
      rv_dev_log "redo by reviewer reject (round=1)" >> "$LOG"

      # ── Stage A' (Developer 再実行) ──
      echo "--- Stage A' 実行（Developer 再実行 / Reviewer reject 差し戻し）---" >> "$LOG"
      prompt_redo=$(build_dev_prompt_redo "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")
      if ! claude \
          --print "$prompt_redo" \
          --model "$DEV_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$DEV_MAX_TURNS" \
          --output-format stream-json \
          --verbose \
          >> "$LOG" 2>&1; then
        echo "❌ #$NUMBER: Stage A' (Developer 再実行) 失敗" | tee -a "$LOG"
        mark_issue_failed "stageA-redo" ""
        return 1
      fi
      echo "✅ #$NUMBER: Stage A' 完了" | tee -a "$LOG"

      # ── Stage B (round=2): Reviewer 最終回 ──
      rev_rc=0
      run_reviewer_stage 2 || rev_rc=$?
      case $rev_rc in
        0)
          echo "✅ #$NUMBER: Reviewer round=2 approve" | tee -a "$LOG"
          ;;
        1)
          # 2 回目 reject → claude-failed + Issue コメントに reject 理由 / 対象 ID を含める
          echo "❌ #$NUMBER: Reviewer round=2 reject → claude-failed" | tee -a "$LOG"
          local parsed2 cat2 tgt2
          parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
          cat2=$(echo "$parsed2" | cut -f2)
          tgt2=$(echo "$parsed2" | cut -f3)
          local reject_body
          reject_body="Reviewer が 2 回連続で reject を出したため、自動 iteration を打ち切り、人間判断に委ねます。

- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
          mark_issue_failed "reviewer-reject2" "$reject_body"
          return 1
          ;;
        *)
          # round=2 reviewer error
          echo "❌ #$NUMBER: Reviewer round=2 異常終了 → claude-failed" | tee -a "$LOG"
          mark_issue_failed "reviewer-error" "Reviewer round=2 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    *)
      # round=1 reviewer error → claude-failed + Issue コメント (要件 4.8)
      echo "❌ #$NUMBER: Reviewer round=1 異常終了 → claude-failed" | tee -a "$LOG"
      mark_issue_failed "reviewer-error" "Reviewer round=1 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
      return 1
      ;;
  esac

  # ── Stage C: PjM (PR 作成) ──
  echo "--- Stage C 実行（PjM / PR 作成）---" >> "$LOG"
  prompt_c=$(build_dev_prompt_c "$MODE")
  if ! claude \
      --print "$prompt_c" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1; then
    echo "❌ #$NUMBER: Stage C (PjM) 失敗" | tee -a "$LOG"
    mark_issue_failed "stageC" ""
    return 1
  fi
  echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み" | tee -a "$LOG"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Issue 入口並列化 (worktree slot + dispatcher, #16)
#
# auto-dev Issue 処理ループを Dispatcher / Slot Worker パターンに置き換え、
# 複数 Issue を時間的に重ねて処理できるようにする。
#
# 構成:
#   - _parallel_validate_slots : PARALLEL_SLOTS 検証
#   - Worktree Manager  : per-slot 永続 worktree の初期化・最新化
#   - Slot Lock Manager : per-slot 非ブロッキング flock の取得・解放
#   - Hook Layer        : SLOT_INIT_HOOK の絶対パス起動（eval 不使用）
#   - Slot Runner       : 1 Issue を 1 worktree で処理する Worker
#   - Dispatcher        : Issue 候補取得 → claim → slot 投入 → 全 Worker wait
#
# PARALLEL_SLOTS=1（デフォルト）のとき、slot-2 以降の lock / worktree を作成せず、
# 本機能導入前と外形的に同一挙動になるよう実装する。
#
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Phase C: Logger ───
# Dispatcher / Slot Worker / Worktree / Hook 共通の timestamp 形式（既存 mq_log 等と同じ）
dispatcher_log() {
  echo "[$(date '+%F %T')] dispatcher: $*"
}
dispatcher_warn() {
  echo "[$(date '+%F %T')] dispatcher: WARN: $*" >&2
}
dispatcher_error() {
  echo "[$(date '+%F %T')] dispatcher: ERROR: $*" >&2
}

# ─── _parallel_validate_slots ───
#
# PARALLEL_SLOTS が正の整数として解釈できるかを検証する。
# - 0 / 負数 / 非数値 / 空文字 / 先頭ゼロ等の形式違反を拒否する
# - 不正なら ERROR ログを stderr に出力して return 1
# 戻り値: 0 = ok / 1 = invalid
#
# Req 1.3: 不正値時はサイクル中断（呼び出し元で exit 1）
# Req 6.5: timestamp 書式 [YYYY-MM-DD HH:MM:SS] を維持
_parallel_validate_slots() {
  if [[ ! "$PARALLEL_SLOTS" =~ ^[1-9][0-9]*$ ]]; then
    dispatcher_error "PARALLEL_SLOTS は正の整数を指定してください: '$PARALLEL_SLOTS'"
    return 1
  fi
  return 0
}

# ─── Phase C: Worktree Manager ───
#
# Per-slot 永続 worktree を $WORKTREE_BASE_DIR/<repo-slug>/slot-N/ に配置し、
# slot 同士の作業ツリー干渉を物理隔離する（Req 3.5）。
#
# 設計判断:
#   - slot worktree は `git worktree add --detach` で detached HEAD として作成する
#     （Slot Runner が `git checkout -B <branch> main` で新規 branch に切り替える際、
#     他 slot の worktree が同じ local branch を保持していてもブロックされないため）
#   - `git worktree list --porcelain` で冪等性を担保
#   - 破損検出時は <slot-N>.broken-<ts> に退避してから再作成
#   - PARALLEL_SLOTS=1 のときは slot-2 以降の worktree を作らない（呼び出し元で gate）

# slot 番号から worktree ディレクトリの絶対パスを返す。
# 引数: $1 = slot 番号
# Req 3.1, 3.7
_worktree_path() {
  local n="$1"
  echo "$WORKTREE_BASE_DIR/$REPO_SLUG/slot-$n"
}

# 指定 path が現在の repo の git worktree として登録済みかを判定。
# 0 = 登録済み / 非ゼロ = 未登録
_worktree_is_registered() {
  local wt_path="$1"
  # `git worktree list --porcelain` は `worktree <abs_path>` 形式で各 worktree を返す
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
    | grep -Fx "worktree $wt_path" >/dev/null 2>&1
}

# Per-slot worktree を冪等に確保する。
# 引数: $1 = slot 番号
# 戻り値: 0 = ok（worktree が存在し利用可能） / 1 = 失敗（呼び出し元で claude-failed 化）
# 副作用: $WORKTREE_BASE_DIR/<slug>/slot-N/ を作成または再利用
#
# Req 3.1, 3.2, 3.3, 3.6, 3.7
_worktree_ensure() {
  local n="$1"
  local wt_path
  wt_path="$(_worktree_path "$n")"
  local parent_dir
  parent_dir="$(dirname "$wt_path")"

  if ! mkdir -p "$parent_dir" 2>/dev/null; then
    dispatcher_warn "slot-${n}: worktree 親ディレクトリ作成に失敗: $parent_dir"
    return 1
  fi

  # ケース A: 既に worktree として登録済み → 再利用（Req 3.3）
  if _worktree_is_registered "$wt_path"; then
    if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
      return 0
    fi
    # 登録は残っているが実体が壊れている → prune してから再作成
    dispatcher_warn "slot-${n}: worktree 登録あり実体欠損、prune して再作成: $wt_path"
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース B: dir は存在するが worktree として登録されていない（未初期化 or 破損）
  if [ -e "$wt_path" ]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local broken="${wt_path}.broken-${ts}"
    dispatcher_warn "slot-${n}: 既存ディレクトリを退避して worktree を再作成: $wt_path -> $broken"
    if ! mv "$wt_path" "$broken" 2>/dev/null; then
      dispatcher_warn "slot-${n}: 既存ディレクトリの退避に失敗: $wt_path"
      return 1
    fi
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース C: 新規作成（origin/main から detached HEAD として）
  # detached にする理由: 各 slot が `git checkout -B <branch> main` で新規 branch に
  # 切り替える際、別 slot worktree が同じ local branch を持っていても弾かれないため。
  if ! git -C "$REPO_DIR" worktree add --detach "$wt_path" "origin/main" >/dev/null 2>&1; then
    dispatcher_warn "slot-${n}: git worktree add に失敗: $wt_path"
    return 1
  fi
  dispatcher_log "slot-${n}: worktree 作成: $wt_path (detached @ origin/main)"
  return 0
}

# Per-slot worktree を origin/main の最新状態に強制リセットする（Issue 投入時に毎回呼ぶ）。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = ok / 1 = 失敗
# 副作用: 当該 worktree が origin/main の最新コミットに head=detached、
#   tracked / untracked / ignored すべて消去される
#
# Req 3.4
_worktree_reset() {
  local wt="$1"
  if [ ! -d "$wt" ]; then
    return 1
  fi
  # 1. 最新の origin を取得
  if ! git -C "$wt" fetch origin --prune >/dev/null 2>&1; then
    return 1
  fi
  # 2. detached HEAD を origin/main に強制移動
  if ! git -C "$wt" reset --hard origin/main >/dev/null 2>&1; then
    return 1
  fi
  # 3. untracked + ignored を消去（前回 Issue の build artifact / node_modules を残さない）
  if ! git -C "$wt" clean -fdx >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Lock Manager ───
#
# Per-slot 非ブロッキング flock を提供する。slot 間のロックは別ファイルとし、
# ある slot の処理が他 slot の処理開始をブロックしない（Req 4.4）。
#
# fd 番号: 既存 LOCK_FILE が fd 200 を使うため、衝突回避で 210 + slot_number を使う。
# 従って bash の per-fd 上限以下になるよう、PARALLEL_SLOTS は事実上 ~ 数十程度を想定
# （CLAUDE.md には bash 4+ と記載済、bash の fd 上限は通常数百〜数千）。
#
# slot Worker はサブシェル `( ... ) &` で動くため、サブシェル終了で fd は自動解放され、
# 明示的な _slot_release 呼び出しは不要だが命名対称性のため定義する。

# slot 番号から lock file path を返す。
# 引数: $1 = slot 番号
# Req 4.1
_slot_lock_path() {
  local n="$1"
  echo "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-${n}.lock"
}

# 指定 slot の per-slot 非ブロッキング flock を取得する（成功時 fd 210+N が open のまま残る）。
# 引数: $1 = slot 番号
# 戻り値: 0 = acquired / 1 = 既に他プロセスがロック中、または fd open 失敗
# 副作用: 成功時 fd (210+N) が open 状態（呼び出し側スコープで保持される）
#
# Req 4.2, 4.3, 4.4
_slot_acquire() {
  local n="$1"
  local lock_file
  lock_file="$(_slot_lock_path "$n")"
  # parent dir を冪等作成（SLOT_LOCK_DIR は通常 $HOME/.issue-watcher で既存）
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
  local fd=$((210 + n))
  # eval を使うのは bash 4.0 互換のため。入力 n は _parallel_validate_slots 通過済の
  # 正整数のみで、外部入力は流入しない（NFR 2.3 のシェル展開リスクなし）。
  # shellcheck disable=SC1083
  if ! eval "exec ${fd}>\"\$lock_file\"" 2>/dev/null; then
    return 1
  fi
  if ! flock -n "$fd" 2>/dev/null; then
    # 既に他プロセスがロック中。fd を閉じて return 1
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  return 0
}

# 指定 slot の per-slot lock を解放する。
# 引数: $1 = slot 番号
# 戻り値: 常に 0
# サブシェル終了で fd は自動解放されるため通常は呼ぶ必要なし。Dispatcher 側で
# claim 失敗時のロールバックに使う（Req 2.3: ラベル付与失敗で slot lock 解放）。
_slot_release() {
  local n="$1"
  local fd=$((210 + n))
  # shellcheck disable=SC1083
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

# ─── Phase C: Hook Layer ───
#
# SLOT_INIT_HOOK 起動を担う薄い wrapper。
#
# 安全性（NFR 2.3 / Req 5.5）:
#   - SLOT_INIT_HOOK の値はシェル展開させない（eval / `bash -c` 不使用）
#   - 絶対パスをそのまま起動するのみ。引数文字列の空白分割を許容しない
#   - "/path/to/script.sh --flag" のような引数渡しはサポート外（README に明記、
#     ユーザーは wrapper script を書く）

# SLOT_INIT_HOOK を起動する。未設定なら no-op。
# 引数: $1 = slot 番号, $2 = worktree 絶対パス
# 戻り値: 0 = 起動成功 / 1 = 起動失敗（path 不在 / 非実行可能 / 非ゼロ exit）
# 副作用: hook 子プロセスの stdout / stderr は呼び出し元の標準出力 / エラー出力に流れる
#
# Req 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, NFR 2.3
_hook_invoke() {
  local n="$1"
  local wt="$2"
  if [ -z "${SLOT_INIT_HOOK:-}" ]; then
    return 0
  fi
  if [ ! -x "$SLOT_INIT_HOOK" ]; then
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が存在しないか実行可能ではありません: $SLOT_INIT_HOOK" >&2
    return 1
  fi

  # stderr を一時ファイルに捕捉して非ゼロ exit 時にログ転記する（Req 5.7）
  local stderr_tmp
  stderr_tmp="$(mktemp -t slot-init-hook-XXXXXX.err 2>/dev/null || echo "")"
  local rc=0

  # IDD_SLOT_NUMBER / IDD_SLOT_WORKTREE / PARALLEL_SLOTS / REPO / REPO_DIR を export
  # して子プロセスに引き継ぐ。直接 exec のみ（Req 5.5: shell 展開なし）。
  if [ -n "$stderr_tmp" ]; then
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" 2> >(tee -a "$stderr_tmp" >&2) || rc=$?
  else
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    local tail_text=""
    if [ -n "$stderr_tmp" ] && [ -f "$stderr_tmp" ]; then
      tail_text="$(tail -c 2000 "$stderr_tmp" 2>/dev/null || true)"
    fi
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が exit code ${rc} で失敗しました: $SLOT_INIT_HOOK" >&2
    if [ -n "$tail_text" ]; then
      echo "[$(date '+%F %T')] slot-${n}: hook stderr (tail):" >&2
      echo "$tail_text" >&2
    fi
  fi

  if [ -n "$stderr_tmp" ]; then
    rm -f "$stderr_tmp" 2>/dev/null || true
  fi

  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Runner ───
#
# 1 Issue を 1 つの slot worktree で処理する Worker。Dispatcher から
# `( _slot_run_issue $n $issue_json ) &` の形でバックグラウンド fork される。
#
# 設計上の重要点:
#   - サブシェルで動くため、内部の `cd` / 環境変数変更は親に伝播しない（Req 3.5 を構造的に保証）
#   - 入口で _slot_acquire 済を前提（Dispatcher が取得済の lock fd を継承）
#   - claim（claude-picked-up ラベル付与）は Dispatcher 側で完了済（Req 2.2）
#   - 処理シーケンス:
#       1. slot 専用ログファイル open
#       2. _worktree_ensure → 失敗時 claude-failed 化 + return
#       3. cd "$WT"
#       4. _worktree_reset → 失敗時 claude-failed 化 + return
#       5. _hook_invoke → 失敗時 claude-failed 化 + return
#       6. 既存 Issue 処理ロジック（Triage → mode 判定 → claude 起動）を実行
#   - すべての claude-failed 化は既存 mark_issue_failed パスを再利用（新ラベル不可）
#
# Req 2.7, 3.4, 3.5, 3.6, 5.3, 5.6, 5.7, 6.1, 6.2, 6.5, 7.3, 7.4, NFR 2.1, 2.2, 3.1, 3.2

# slot worker 用ロガー（slot 番号 + Issue 番号を必ず prefix に含める、Req 6.1, NFR 3.1）。
# サブシェル内で IDD_SLOT_NUMBER / NUMBER を読み取って prefix を組み立てる。
slot_log() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: $*"
}
slot_warn() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: WARN: $*" >&2
}
slot_error() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: ERROR: $*" >&2
}

# claude-picked-up を claude-failed に置き換える共通フロー（Worktree / Hook / その他
# サブシェル内エラー用）。run_impl_pipeline 内の mark_issue_failed と同じ操作を slot
# worker 文脈で再現する（mark_issue_failed は MODE / LOG 等を要求するため代用しない）。
# 引数: $1 = stage 識別子, $2 = Issue コメントに追加する補足
_slot_mark_failed() {
  local stage="$1"
  local extra="$2"
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" >/dev/null 2>&1 || true
  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / slot=${IDD_SLOT_NUMBER:-?} / 失敗 stage: ${stage}）。"
  if [ -n "$extra" ]; then
    body="${body}

${extra}"
  fi
  if [ -n "${LOG:-}" ]; then
    body="${body}

ログ: \`$LOG\`"
  fi
  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
}

# 1 Issue を 1 slot worktree で処理する Worker 本体。
# サブシェル `( _slot_run_issue n issue_json ) &` から呼び出される前提。
#
# 引数:
#   $1 = slot 番号
#   $2 = Issue JSON (gh issue list の 1 要素)
# 戻り値:
#   0 = 成功 / 非ゼロ = 失敗（既に claude-failed ラベルへ遷移済み）
#
# 副作用:
#   - サブシェル内で NUMBER / TITLE / BODY / URL / LABELS / TS / LOG / SLUG /
#     SPEC_DIR_REL / MODE / BRANCH などのグローバル変数を設定（親には伝播しない）
#   - $WT に cd（サブシェル内）
#   - claude / gh / git の副作用は Issue ラベル遷移として外部観測可能
_slot_run_issue() {
  # slot 識別子をサブシェル内で見えるよう export（slot_log / _hook_invoke が参照）
  export IDD_SLOT_NUMBER="$1"
  local issue="$2"

  # ── Issue メタデータ抽出 ──
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue"  | jq -r '.title')
  BODY=$(echo "$issue"   | jq -r '.body // ""')
  URL=$(echo "$issue"    | jq -r '.url')
  LABELS=$(echo "$issue" | jq -r '.labels[].name')
  TS=$(date +%Y%m%d-%H%M%S)
  LOG="$LOG_DIR/issue-${NUMBER}-${TS}.log"

  # slot 運用ログ（worktree 初期化・hook 結果など）。Issue ログとは別系統で残す（Req 6.2）。
  local SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"
  # 以降の slot_log 行は stdout (cron mailer) と SLOT_LOG の両方に書き出す
  exec > >(tee -a "$SLOT_LOG") 2>&1

  slot_log "Worker 起動 (LOG=$LOG SLOT_LOG=$SLOT_LOG)"

  # ── Worktree 初期化（per-slot 永続 worktree）──
  local WT
  WT="$(_worktree_path "$IDD_SLOT_NUMBER")"
  export IDD_SLOT_WORKTREE="$WT"

  if ! _worktree_ensure "$IDD_SLOT_NUMBER"; then
    slot_warn "worktree 初期化に失敗 (path=$WT)"
    _slot_mark_failed "worktree-ensure" "Slot ${IDD_SLOT_NUMBER} の worktree 初期化に失敗しました（path=\`$WT\`）。"
    return 1
  fi
  slot_log "worktree 確保 OK (path=$WT)"

  # サブシェル内で worktree に cd（親には伝播しない、Req 3.5）
  if ! cd "$WT"; then
    slot_warn "worktree への cd に失敗 (path=$WT)"
    _slot_mark_failed "worktree-cd" "worktree path への cd に失敗しました: \`$WT\`"
    return 1
  fi

  # ── Worktree を origin/main 最新へ強制リセット ──
  if ! _worktree_reset "$WT"; then
    slot_warn "worktree reset に失敗 (path=$WT)"
    _slot_mark_failed "worktree-reset" "Slot ${IDD_SLOT_NUMBER} の worktree を origin/main にリセットできませんでした。"
    return 1
  fi
  slot_log "worktree reset OK (origin/main 最新化 + clean -fdx)"

  # ── SLOT_INIT_HOOK 起動（reset 後・claude 起動前に 1 度だけ）──
  if ! _hook_invoke "$IDD_SLOT_NUMBER" "$WT"; then
    slot_warn "SLOT_INIT_HOOK の起動に失敗"
    _slot_mark_failed "slot-init-hook" "SLOT_INIT_HOOK が失敗しました（詳細はログ参照）。SLOT_INIT_HOOK=\`${SLOT_INIT_HOOK:-(unset)}\`"
    return 1
  fi
  if [ -n "${SLOT_INIT_HOOK:-}" ]; then
    slot_log "SLOT_INIT_HOOK 完了"
  fi

  # ── 既存 Issue 処理ロジックを実行 ──
  # ここから下は本機能導入前の Issue ループ本体と等価。サブシェル内で動くため
  # NUMBER / MODE / LOG 等のグローバル変数変更は親に伝播しない（Req 3.5 を構造的に保証）。
  echo "=== Processing #$NUMBER: $TITLE (slot-${IDD_SLOT_NUMBER}) ===" | tee -a "$LOG"

  # ── 既存 spec ディレクトリの検出（設計 PR merge 済みか）と slug 決定 ──
  local EXISTING_SPEC_DIR
  EXISTING_SPEC_DIR=$(ls -d "$WT/docs/specs/${NUMBER}-"* 2>/dev/null | head -1 || true)
  local HAS_EXISTING_SPEC=false
  if [ -n "$EXISTING_SPEC_DIR" ] && [ -f "$EXISTING_SPEC_DIR/requirements.md" ]; then
    HAS_EXISTING_SPEC=true
    SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
    echo "📂 既存 spec 検出: $EXISTING_SPEC_DIR (slug=$SLUG)" | tee -a "$LOG"
  else
    SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
  fi
  SPEC_DIR_REL="docs/specs/${NUMBER}-${SLUG}"

  # ── モード判定（design / impl / impl-resume）──
  NEEDS_ARCHITECT="false"
  ARCHITECT_REASON=""
  MODE=""

  if $HAS_EXISTING_SPEC; then
    echo "✅ #$NUMBER: 設計レビュー済み（spec dir あり） → impl-resume モード" | tee -a "$LOG"
    MODE="impl-resume"
  elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "skip-triage ラベルがあるため Triage をスキップ → impl モード" | tee -a "$LOG"
    ARCHITECT_REASON="Triage をスキップ（軽微な変更扱い）"
    MODE="impl"
  else
    # ── Triage フェーズ ──
    local TRIAGE_FILE="/tmp/triage-${REPO_SLUG}-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    local TITLE_SAFE="${TITLE//|/\\|}"
    local TRIAGE_PROMPT
    TRIAGE_PROMPT=$(sed \
      -e "s|{{NUMBER}}|${NUMBER}|g" \
      -e "s|{{TITLE}}|${TITLE_SAFE}|g" \
      -e "s|{{URL}}|${URL}|g" \
      -e "s|{{FILE}}|${TRIAGE_FILE}|g" \
      "$TRIAGE_TEMPLATE")

    echo "--- Triage 実行 ---" >> "$LOG"
    if ! claude \
        --print "$TRIAGE_PROMPT" \
        --model "$TRIAGE_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$TRIAGE_MAX_TURNS" \
        >> "$LOG" 2>&1; then
      echo "❌ Triage の実行に失敗" | tee -a "$LOG"
      # claude-picked-up は Dispatcher 側で付与済。Triage 失敗時は claude-failed に
      # 遷移して人間判断に委ねる（既存挙動: Triage 失敗時は continue だったが、
      # Phase C ではすでに claim 済のため、ラベルを残置せず claude-failed 化する）。
      _slot_mark_failed "triage" "Triage（Claude 実行）に失敗しました。"
      return 1
    fi

    if [ ! -f "$TRIAGE_FILE" ]; then
      echo "❌ Triage 結果 JSON が生成されませんでした" | tee -a "$LOG"
      _slot_mark_failed "triage-json" "Triage 結果 JSON が生成されませんでした。"
      return 1
    fi

    local STATUS DECISION_COUNT
    STATUS=$(jq -r '.status' "$TRIAGE_FILE")
    DECISION_COUNT=$(jq '.decisions | length' "$TRIAGE_FILE")
    NEEDS_ARCHITECT=$(jq -r '.needs_architect // false' "$TRIAGE_FILE")
    ARCHITECT_REASON=$(jq -r '.architect_reason // ""' "$TRIAGE_FILE")

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      local COMMENT
      COMMENT=$(jq -r '
        "## 🤔 実装着手前に確認が必要な事項\n\n" +
        "Issue 内容を Claude Code の Product Manager で精査した結果、" +
        "以下の判断は人間に委ねる必要があると判定しました。\n\n" +
        "> " + .rationale + "\n\n" +
        "---\n\n" +
        (.decisions | to_entries | map(
          "### " + ((.key + 1) | tostring) + ". " + .value.topic + "\n\n" +
          "**質問**: " + .value.question + "\n\n" +
          "**選択肢**:\n" +
          (.value.options | map("- " + .) | join("\n")) + "\n\n" +
          "**影響**: " + .value.impact + "\n\n" +
          "**推奨**: " + .value.recommendation + "\n"
        ) | join("\n---\n\n")) +
        "\n\n---\n\n" +
        "## 回答方法\n\n" +
        "1. 各項目についてこの Issue にコメントで回答してください。\n" +
        "2. すべての項目に結論が出たら、この Issue から **`needs-decisions` ラベルを外してください**。\n" +
        "3. ラベルが外れた時点で Claude Code が自動で再 Triage し、追加論点が無ければ開発に着手します。\n" +
        "4. Triage をスキップして強制着手したい場合は `skip-triage` ラベルを付与してください。"
      ' "$TRIAGE_FILE")

      gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT" >/dev/null 2>&1 || true
      # Phase C: claim を取り消す（claude-picked-up 除去）+ needs-decisions 付与。
      # 次サイクルで人間が needs-decisions を外したら再ピックアップされる必要があるため、
      # claude-picked-up を残してはいけない。本機能導入前は claude-picked-up は未付与
      # だったが、Phase C では Dispatcher が事前に付与しているためここで取り消す。
      gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_PICKED" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
      echo "🟡 #$NUMBER: $DECISION_COUNT 件の決定事項を起票しました" | tee -a "$LOG"
      slot_log "Triage 結果: needs-decisions（claude-picked-up 取り消し済）"
      return 0
    fi

    if [ "$NEEDS_ARCHITECT" = "true" ]; then
      MODE="design"
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      echo "✅ #$NUMBER: Triage 通過（Architect 不要） → impl モード" | tee -a "$LOG"
    fi
  fi

  # ── ピックアップ表明コメント（claim 表明ラベルは Dispatcher が事前に付与済）──
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Claude Code ($(hostname)) が処理を開始しました（slot=${IDD_SLOT_NUMBER} / モード: ${MODE}）。" >/dev/null 2>&1 || true

  # ── ブランチを切る（モードに応じて名前を変える）──
  case "$MODE" in
    design)
      BRANCH="claude/issue-${NUMBER}-design-${SLUG}"
      ;;
    impl|impl-resume)
      BRANCH="claude/issue-${NUMBER}-impl-${SLUG}"
      ;;
  esac
  # worktree は detached HEAD で起動するため -B で新規 branch 作成（local main を持たない）
  if ! git checkout -B "$BRANCH" "origin/main"; then
    slot_warn "branch 作成に失敗: $BRANCH"
    _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
    return 1
  fi
  if ! git push -u origin "$BRANCH" --force-with-lease; then
    slot_warn "branch push に失敗: $BRANCH"
    _slot_mark_failed "branch-push" "ブランチ \`$BRANCH\` の push に失敗しました。"
    return 1
  fi

  # ── モード別ディスパッチ ──
  if [ "$MODE" = "design" ]; then
    local FLOW_LABEL STEPS DEV_PROMPT
    FLOW_LABEL="PM → Architect → PjM（設計 PR 作成ゲート）"
    STEPS=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. architect サブエージェントで設計書とタスク分割を保存
   - Triage 判定理由: ${ARCHITECT_REASON}
   - \`${SPEC_DIR_REL}/design.md\`（モジュール構成・データモデル・公開 IF・処理フロー・リスク）
   - \`${SPEC_DIR_REL}/tasks.md\`（Developer 向けタスク分割、各タスクが独立コミット可能な粒度）
3. project-manager サブエージェントを **design-review モード** で起動
   - 成果物は ${SPEC_DIR_REL}/ 配下の requirements / design / tasks のみ（実装コードは含めない）
   - title: \`spec(#${NUMBER}): <1 行サマリ>\`
   - Issue ラベル: claude-picked-up → awaiting-design-review に付け替え
   - Issue にコメントで設計 PR リンクと案内を投稿

この設計 PR が merge されるまで、実装フェーズには進みません。人間が merge した後、
次回のポーリングで Developer が自動起動し、実装 PR が別途作成されます。
EOF
)

    DEV_PROMPT=$(cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を ${FLOW_LABEL} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（main から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方
${STEPS}

## 制約
- main に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、PR 本文の「確認事項」セクションに列挙すること
EOF
)

    echo "--- Development 実行（$MODE）---" >> "$LOG"
    if claude \
        --print "$DEV_PROMPT" \
        --model "$DEV_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$DEV_MAX_TURNS" \
        --output-format stream-json \
        --verbose \
        >> "$LOG" 2>&1; then
      echo "✅ #$NUMBER: $MODE 完了" | tee -a "$LOG"
      slot_log "$MODE 完了"
      return 0
    else
      echo "❌ #$NUMBER: $MODE 失敗" | tee -a "$LOG"
      _slot_mark_failed "$MODE" "design モードでの Claude 実行が失敗しました。"
      return 1
    fi
  else
    # impl / impl-resume → Reviewer ゲートを含む stage 分割パイプラインへ
    if run_impl_pipeline; then
      echo "✅ #$NUMBER: $MODE 完了（Reviewer ゲート通過 / PR 作成済み）" | tee -a "$LOG"
      slot_log "$MODE 完了（PR 作成済み）"
      return 0
    else
      echo "❌ #$NUMBER: $MODE 失敗（claude-failed 付与済み）" | tee -a "$LOG"
      slot_log "$MODE 失敗（claude-failed 付与済み）"
      return 1
    fi
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Dispatcher
#
# 1 サイクル中に 1 度起動される。Issue 候補をローカルキューに pop し、空き slot を
# 探索して claim（claude-picked-up ラベル付与）してから Slot Runner をバックグラウンド
# 起動する。サイクル終端で `wait` により全 Worker 完了を待ち合わせる。
#
# Req 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 6.3, 6.4, 6.5, 7.5, NFR 1.1, NFR 1.2
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Dispatcher が抱える slot_n -> PID マッピング（bash associative array, 4.0+）。
# サブシェル fork 後、_slot_release で fd を閉じてもこの map で「どの slot が誰の
# 子プロセスか」を後で再特定できる。
declare -A _DISPATCHER_SLOT_PIDS

# 完了した子プロセスを slot_pid map から prune する。
# `kill -0 <pid>` が失敗（プロセス不在）なら slot は空いたとみなす。
_dispatcher_reap_finished_slots() {
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -z "$pid" ]; then
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      continue
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      # 子プロセス終了済 → slot 解放
      wait "$pid" 2>/dev/null || true
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      dispatcher_log "slot-${n}: completed (pid=$pid)"
    fi
  done
}

# 空き slot を探す（reap → 1..PARALLEL_SLOTS で _slot_acquire）。
# 戻り値: 0 = 取得成功（slot 番号を stdout に echo） / 1 = 全 slot busy
_dispatcher_find_free_slot() {
  _dispatcher_reap_finished_slots
  local n
  for ((n=1; n<=PARALLEL_SLOTS; n++)); do
    # 既に PID マップに載っている slot は busy
    if [ -n "${_DISPATCHER_SLOT_PIDS[$n]:-}" ]; then
      continue
    fi
    if _slot_acquire "$n"; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

# 1 サイクル分の Dispatcher を実行する。
# 戻り値: 0 = 正常完了（個々の Worker の成否は Issue ラベル経由で表現）/ 非ゼロ = 致命的失敗
_dispatcher_run() {
  # Req 1.3: PARALLEL_SLOTS 検証 → 不正なら ERROR ログ + exit 1
  if ! _parallel_validate_slots; then
    return 1
  fi

  # Req 7.5: 既存の Issue 取得クエリ（フィルタ・limit 5）を据え置き
  # Issue #54 Req 1.1 / 1.3 / 5.2: PR 専用ラベル `needs-iteration` が誤って Issue 側に
  # 付与されているケースを除外する（人為ミスでの impl-resume 起動 → 既存 PR 破壊事故防止）。
  local issues
  issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --state open \
    --search "-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\"" \
    --json number,title,body,url,labels \
    --limit 5)

  local count
  count=$(echo "$issues" | jq 'length')
  if [ "$count" -eq 0 ]; then
    # Req 1.4 / 7.6: PARALLEL_SLOTS=1 + 対象なし時の挙動を本機能導入前と同等に保つ。
    # （prefix dispatcher: は付くが、メッセージ本体は既存と同じ）
    echo "[$(date '+%F %T')] 処理対象の Issue なし"
    return 0
  fi

  # Req 6.3: サイクル開始ログ（処理対象件数 + 利用可能 slot 数）
  dispatcher_log "対象 Issue ${count} 件 / 利用可能 slot ${PARALLEL_SLOTS} 件"

  # Req 1.4 互換のため、PARALLEL_SLOTS=1 のときも従来と同じ（prefix なし）件数 echo を出す。
  # 既存ユーザー / cron の grep 監視を破壊しない（"N 件の Issue を処理します" 行）。
  if [ "$PARALLEL_SLOTS" -eq 1 ]; then
    echo "[$(date '+%F %T')] $count 件の Issue を処理します"
  fi

  # Issue キューを 1 件ずつ pop して slot に投入
  local issue
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    local issue_number
    issue_number=$(echo "$issue" | jq -r '.number')

    # ── 空き slot 探索（busy なら 1 件完了するまで待機）──
    local slot=""
    while true; do
      if slot=$(_dispatcher_find_free_slot); then
        break
      fi
      # 全 slot busy → 1 件完了を待つ（bash 4.3+ の `wait -n`）
      if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -eq 0 ]; then
        # 子プロセス未起動かつ全 slot 取得失敗 → 取れる slot がない異常事態
        # （他 watcher プロセスが slot lock を握っているなど）
        dispatcher_warn "全 slot がロック中（_slot_acquire いずれも失敗）。Issue #${issue_number} は次サイクルへ持ち越し"
        slot=""
        break
      fi
      wait -n 2>/dev/null || true
      _dispatcher_reap_finished_slots
    done

    if [ -z "$slot" ]; then
      continue
    fi

    # ── claim（claude-picked-up ラベル付与）──
    if ! gh issue edit "$issue_number" --repo "$REPO" --add-label "$LABEL_PICKED" >/dev/null 2>&1; then
      # Req 2.3: ラベル付与失敗 → WARN + slot lock 解放 + 次 Issue へ
      dispatcher_warn "Issue #${issue_number}: claude-picked-up ラベル付与に失敗、slot-${slot} を解放して次 Issue へ"
      _slot_release "$slot"
      continue
    fi

    # Req 6.4: 投入時刻ログ
    dispatcher_log "dispatched #${issue_number} -> slot-${slot}"

    # ── Slot Runner をバックグラウンド起動 ──
    # サブシェル `( ... ) &` で fork。サブシェルは親の fd を継承するため
    # _slot_acquire で取得した lock fd は subshell が引き続き保持する。
    ( _slot_run_issue "$slot" "$issue" ) &
    local pid=$!
    _DISPATCHER_SLOT_PIDS[$slot]=$pid

    # 親 Dispatcher 側の fd を解放する。これにより、Dispatcher が同 slot を再
    # acquire しようとしたとき、subshell が lock を保持している間は flock -n が
    # 失敗するようになる（claim atomicity の構造的保証）。
    _slot_release "$slot"
  done <<< "$(echo "$issues" | jq -c '.[]')"

  # Req 2.6: サイクル終端で全 Worker を待ち合わせる
  # Slot Runner 内で claude-failed 化等は完結済のため exit code は無視
  if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -gt 0 ]; then
    dispatcher_log "全 Worker 完了を待機中 (${#_DISPATCHER_SLOT_PIDS[@]} 件 in flight)"
    wait
    _dispatcher_reap_finished_slots
  fi

  dispatcher_log "サイクル完了"
  return 0
}

# Dispatcher を起動（既存 Issue 処理ループの置換）。
_dispatcher_run
DISPATCHER_RC=$?
if [ "$DISPATCHER_RC" -ne 0 ]; then
  # Req 1.3: PARALLEL_SLOTS 不正値などで _dispatcher_run が non-zero を返した場合は
  # サイクル中断（既存の ERROR 終了規約 = exit 1 と整合）
  exit "$DISPATCHER_RC"
fi

echo "[$(date '+%F %T')] 完了"
exit 0

