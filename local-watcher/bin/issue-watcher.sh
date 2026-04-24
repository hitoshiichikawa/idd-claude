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
#   auto-dev  → Triage → (needs-decisions | awaiting-design-review | claude-picked-up)
#             → ready-for-review / claude-failed
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
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_SKIP_TRIAGE="skip-triage"
LABEL_NEEDS_REBASE="needs-rebase"

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

# LOG_DIR と LOCK_FILE は REPO_SLUG を挟むことで repo ごとに分離。
# 環境変数で明示上書きもできる。
LOG_DIR="${LOG_DIR:-$HOME/.issue-watcher/logs/$REPO_SLUG}"
LOCK_FILE="${LOCK_FILE:-/tmp/issue-watcher-${REPO_SLUG}.lock}"

# モデル設定
TRIAGE_MODEL="${TRIAGE_MODEL:-claude-sonnet-4-6}"   # Triage は軽量モデルで十分
DEV_MODEL="${DEV_MODEL:-claude-opus-4-7}"           # 本実装は Opus 4.7 + 1M context
TRIAGE_MAX_TURNS="${TRIAGE_MAX_TURNS:-15}"
DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"

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

  # AC 1.2 / 1.3 / 1.4: approved かつ needs-rebase / claude-failed が付いていない非 draft の PR
  # GitHub search 構文で server side フィルタ（API call 削減・NFR 1.2）
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved -label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,mergeStateStatus,labels,url,isDraft,reviewDecision \
      --limit 50 2>/dev/null); then
    mq_warn "approved PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # クライアント側でも draft / reviewDecision を再フィルタ（API gate のフォールバック）
  prs_json=$(echo "$prs_json" | jq '[.[] | select(.isDraft == false) | select(.reviewDecision == "APPROVED")]')

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

# AC 1.1: ピックアップ済み Issue の処理ループに入る前に 1 回だけ起動
process_merge_queue || mq_warn "process_merge_queue が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 未処理 Issue を取得
#   auto-dev ラベルがあり、かつ以下のラベルが付いていないもの:
#     needs-decisions / awaiting-design-review / claude-picked-up /
#     ready-for-review / claude-failed
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ISSUES=$(gh issue list \
  --repo "$REPO" \
  --label "$LABEL_TRIGGER" \
  --state open \
  --search "-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\"" \
  --json number,title,body,url,labels \
  --limit 5)

COUNT=$(echo "$ISSUES" | jq 'length')
[ "$COUNT" -eq 0 ] && {
  echo "[$(date '+%F %T')] 処理対象の Issue なし"
  exit 0
}

echo "[$(date '+%F %T')] $COUNT 件の Issue を処理します"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 各 Issue を処理
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
echo "$ISSUES" | jq -c '.[]' | while read -r issue; do
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue"  | jq -r '.title')
  BODY=$(echo "$issue"   | jq -r '.body // ""')
  URL=$(echo "$issue"    | jq -r '.url')
  LABELS=$(echo "$issue" | jq -r '.labels[].name')
  TS=$(date +%Y%m%d-%H%M%S)
  LOG="$LOG_DIR/issue-${NUMBER}-${TS}.log"

  echo "=== Processing #$NUMBER: $TITLE ===" | tee -a "$LOG"

  # ─────────────────────────────────────────────────────────────
  # 既存 spec ディレクトリの検出（設計 PR merge 済みか）と slug 決定
  # ─────────────────────────────────────────────────────────────
  EXISTING_SPEC_DIR=$(ls -d "$REPO_DIR/docs/specs/${NUMBER}-"* 2>/dev/null | head -1 || true)
  HAS_EXISTING_SPEC=false
  if [ -n "$EXISTING_SPEC_DIR" ] && [ -f "$EXISTING_SPEC_DIR/requirements.md" ]; then
    HAS_EXISTING_SPEC=true
    SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
    echo "📂 既存 spec 検出: $EXISTING_SPEC_DIR (slug=$SLUG)" | tee -a "$LOG"
  else
    SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' \
          | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
  fi
  SPEC_DIR_REL="docs/specs/${NUMBER}-${SLUG}"

  # ─────────────────────────────────────────────────────────────
  # モード判定（design / impl / impl-resume）
  # ─────────────────────────────────────────────────────────────
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
    # ─── Triage フェーズ ───
    TRIAGE_FILE="/tmp/triage-${REPO_SLUG}-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    TITLE_SAFE="${TITLE//|/\\|}"
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
      continue
    fi

    if [ ! -f "$TRIAGE_FILE" ]; then
      echo "❌ Triage 結果 JSON が生成されませんでした" | tee -a "$LOG"
      continue
    fi

    STATUS=$(jq -r '.status' "$TRIAGE_FILE")
    DECISION_COUNT=$(jq '.decisions | length' "$TRIAGE_FILE")
    NEEDS_ARCHITECT=$(jq -r '.needs_architect // false' "$TRIAGE_FILE")
    ARCHITECT_REASON=$(jq -r '.architect_reason // ""' "$TRIAGE_FILE")

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
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

      gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT"
      gh issue edit    "$NUMBER" --repo "$REPO" --add-label "$LABEL_NEEDS_DECISIONS"
      echo "🟡 #$NUMBER: $DECISION_COUNT 件の決定事項を起票しました" | tee -a "$LOG"
      continue
    fi

    if [ "$NEEDS_ARCHITECT" = "true" ]; then
      MODE="design"
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      echo "✅ #$NUMBER: Triage 通過（Architect 不要） → impl モード" | tee -a "$LOG"
    fi
  fi

  # ─────────────────────────────────────────────────────────────
  # ピックアップを即ラベルで表明（クラッシュ時も二重起動を防ぐ）
  # ─────────────────────────────────────────────────────────────
  gh issue edit "$NUMBER" --repo "$REPO" --add-label "$LABEL_PICKED"
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Claude Code ($(hostname)) が処理を開始しました（モード: ${MODE}）。"

  # ─────────────────────────────────────────────────────────────
  # ブランチを切る（モードに応じて名前を変える）
  # ─────────────────────────────────────────────────────────────
  case "$MODE" in
    design)
      BRANCH="claude/issue-${NUMBER}-design-${SLUG}"
      ;;
    impl|impl-resume)
      BRANCH="claude/issue-${NUMBER}-impl-${SLUG}"
      ;;
  esac
  git checkout -B "$BRANCH" main
  git push -u origin "$BRANCH" --force-with-lease

  # ─────────────────────────────────────────────────────────────
  # DEV_PROMPT 組み立て（モードごとに進め方を切り替え）
  # ─────────────────────────────────────────────────────────────
  case "$MODE" in
    design)
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
      ;;
    impl)
      FLOW_LABEL="PM → Developer → PjM（実装 PR 作成）"
      STEPS=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\`
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存
3. project-manager サブエージェントを **implementation モード** で起動
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - PR 本文に受入基準・テスト結果・確認事項を記載（関連 PR は「なし」と明記）
   - Issue ラベル: claude-picked-up → ready-for-review に付け替え
EOF
)
      ;;
    impl-resume)
      FLOW_LABEL="Developer → PjM（設計 merge 済みの実装フェーズ）"
      STEPS=$(cat <<EOF
1. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は設計 PR で人間レビュー済み（main に merge 済み）。**書き換えないこと**
   - tasks.md の T-NN の順にタスクを消化する
   - 矛盾や疑問があれば PR 本文「確認事項」に記載（書き換えはしない）
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存
2. project-manager サブエージェントを **implementation モード** で起動
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - PR 本文に対応する設計 PR 番号を記載（直近の main 上の merge commit から \`git log --oneline --merges\` で探す）
   - Issue ラベル: claude-picked-up → ready-for-review に付け替え
EOF
)
      ;;
  esac

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
  else
    echo "❌ #$NUMBER: $MODE 失敗" | tee -a "$LOG"
    gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true
    gh issue comment "$NUMBER" --repo "$REPO" \
      --body "⚠️ 自動開発が失敗しました（$(hostname) / モード: $MODE）。\n\nログ: \`$LOG\`\n\n問題を解決してから \`claude-failed\` ラベルを外してください。"
  fi

  # 次のループのため main に戻る
  git checkout main
done

echo "[$(date '+%F %T')] 完了"
