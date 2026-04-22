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
for cmd in gh jq claude git flock; do
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
