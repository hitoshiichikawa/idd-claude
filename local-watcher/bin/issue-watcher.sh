#!/usr/bin/env bash
# =============================================================================
# idd-claude local issue watcher
#
# GitHub Issue をポーリングし、auto-dev ラベルが付いた未処理 Issue を検出して
# Claude Code でローカル実行する。Triage → needs-decisions → 再 Triage → Dev
# の状態機械をラベルで管理。
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
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REPO="owner/your-repo"
REPO_DIR="$HOME/work/your-repo"

LABEL_TRIGGER="auto-dev"
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_SKIP_TRIAGE="skip-triage"

LOG_DIR="$HOME/.issue-watcher/logs"
LOCK_FILE="/tmp/issue-watcher.lock"

# モデル設定
TRIAGE_MODEL="claude-sonnet-4-6"      # Triage は軽量モデルで十分
DEV_MODEL="claude-opus-4-7"            # 本実装は Opus 4.7 + 1M context
TRIAGE_MAX_TURNS=15
DEV_MAX_TURNS=60

# Triage プロンプトテンプレート
TRIAGE_TEMPLATE="$HOME/bin/triage-prompt.tmpl"

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
#     - needs-decisions / claude-picked-up / ready-for-review / claude-failed
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
ISSUES=$(gh issue list \
  --repo "$REPO" \
  --label "$LABEL_TRIGGER" \
  --state open \
  --search "-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\"" \
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
  # Triage フェーズ（skip-triage ラベルがなければ実施）
  # ─────────────────────────────────────────────────────────────
  if echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "skip-triage ラベルがあるため Triage をスキップ" | tee -a "$LOG"
  else
    TRIAGE_FILE="/tmp/triage-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    # プロンプトのプレースホルダを置換
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

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      # 決定事項コメントを Markdown に整形
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
      continue   # 次の Issue へ。開発は次回ラベル除去後に実施
    fi

    echo "✅ #$NUMBER: Triage 通過（決定事項なし）" | tee -a "$LOG"
  fi

  # ─────────────────────────────────────────────────────────────
  # Development フェーズ
  # ─────────────────────────────────────────────────────────────

  # ピックアップを即ラベルで表明（クラッシュ時も二重起動を防ぐ）
  gh issue edit "$NUMBER" --repo "$REPO" --add-label "$LABEL_PICKED"
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Claude Code ($(hostname)) が処理を開始しました。"

  # ブランチを切る（既に同名があれば上書きで OK）
  SLUG=$(echo "$TITLE" | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
  BRANCH="claude/issue-${NUMBER}-${SLUG}"
  git checkout -B "$BRANCH" main
  git push -u origin "$BRANCH" --force-with-lease

  # 本実装プロンプト
  DEV_PROMPT=$(cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を、PM → Developer → PjM の 3 サブエージェント体制で解決してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（main から派生・push 済み・現在チェックアウト中）

## 進め方
1. product-manager サブエージェントで仕様書を \`docs/issues/${NUMBER}-spec.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は spec に反映する
2. developer サブエージェントで実装＋テスト＋コミット
   - 規約は CLAUDE.md に従う
3. project-manager サブエージェントで push と \`gh pr create\` まで実施
   - PR 本文テンプレートに従い、受入基準・テスト結果・確認事項を記載
   - Issue のラベルを claude-picked-up → ready-for-review に付け替え

## 制約
- main に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、PR 本文の「確認事項」セクションに列挙すること
EOF
)

  echo "--- Development 実行 ---" >> "$LOG"
  if claude \
      --print "$DEV_PROMPT" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1; then
    echo "✅ #$NUMBER: Development 完了" | tee -a "$LOG"
  else
    echo "❌ #$NUMBER: Development 失敗" | tee -a "$LOG"
    gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true
    gh issue comment "$NUMBER" --repo "$REPO" \
      --body "⚠️ 自動開発が失敗しました（$(hostname)）。\n\nログ: \`$LOG\`\n\n問題を解決してから \`claude-failed\` ラベルを外してください。"
  fi

  # 次のループのため main に戻る
  git checkout main
done

echo "[$(date '+%F %T')] 完了"
