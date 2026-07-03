#!/usr/bin/env bash
# tasks-count-gate.sh — Tasks Count Gate モジュール（#147 / #457 切り出し）
#
# 用途:
#   Architect が `tasks.md` を確定した直後（design モードの Claude 実行 rc=0 直後）に
#   watcher 側で task 件数を機械的に再カウントし、件数レンジに応じて 3 段階の運用判定
#   （通常 / 警告 / Developer 抑止）を適用する harness ガード（Req 1, 2 / Issue #147）。
#
#   - tc_log / tc_warn / tc_error                  : `tasks-count:` prefix logger
#   - tc_count_tasks                               : tasks.md からタスク行件数を抽出
#   - tc_classify                                  : 件数を normal/warn/escalate に分類
#   - tc_should_run                                : gate（opt-out / 不在 / 重複検知）
#   - tc_already_posted_marker_present             : 冪等マーカー検知
#   - tc_post_warning_comment                      : 8〜10 件レンジの警告コメント投稿
#   - tc_post_escalation_comment                   : 11 件以上のエスカレーションコメント
#   - tc_add_needs_decisions_label                 : `needs-decisions` ラベル付与
#   - tc_run_post_architect_check                  : design rc=0 hook の orchestrator
#
#   設計参照: docs/specs/147-feat-harness-tasks-md-task-auto-dev-issu/design.md
#   関連    : Issue #131（Architect 側 budget overflow 検知）と独立かつ重畳に作用する
#
# 配置先:
#   $HOME/bin/modules/tasks-count-gate.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $NUMBER / $SPEC_DIR_REL / $TC_ENABLED /
#     $TC_WARN_LOWER / $TC_WARN_UPPER / $TC_ESCALATE_LOWER / $LABEL_NEEDS_DECISIONS）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - call site（design 分岐 rc=0 直後の `tc_run_post_architect_check || true`）は
#     実行順序温存のため本体側に残る。
#   - 外部 CLI: gh / jq / grep。
#
# 正準計数の所在（#216）:
#   tc_count_tasks の計数規約の正準は Architect 側の `.claude/rules/design-review-gate.md`
#   「Budget overflow check（tasks.md 件数）」節（count 抽出 regex
#   `^- \[ \]\*? [0-9]+\. `）である。正準を変更する場合は必ず design-review-gate.md を
#   先に更新し、本モジュールの regex を追従させること（rule 側が canonical）。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# tasks-count 専用ロガー（既存 sav_log / sc_log と同形式）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] tasks-count:` の 3 段 prefix を維持し、
# `grep '\[.*\] tasks-count:'` で全件抽出可能（NFR 1.1）。
tc_log() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: $*"
}
tc_warn() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: WARN: $*" >&2
}
tc_error() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: ERROR: $*" >&2
}

# ─── tc_count_tasks ───
#
# `tasks.md` 1 ファイルからタスク件数を整数で返す純粋関数
# （Req 1.1〜1.5 / #216 / NFR 2.1）。
#
# === 正準計数の所在（#216）===
# 本関数の計数規約の **正準** は Architect 側の `design-review-gate.md`
# 「Budget overflow check（tasks.md 件数）」節（count 抽出 regex
# `^- \[ \]\*? [0-9]+\. `）である。harness（本関数）はその正準 regex に
# **厳密一致**させ、同一 tasks.md に対し Architect の Budget overflow check と
# 同一件数を返す（Req 1.5）。両所は別実行基盤（bash / LLM ルール）のため共有
# コードを持てず、同一 regex を双方に明記して相互参照する形でドリフトを防ぐ
# （Req 3.1 / 3.2）。正準を変更する場合は **必ず `design-review-gate.md` を先に**
# 更新し、本コメント・regex を追従させること。
#
# count 抽出 regex (POSIX 互換 ERE): `^- \[ \]\*? [0-9]+\. `
#   - **最上位 numeric ID の未完了タスク行のみ**を計数する（Req 1.1）:
#       行頭 `- [ ]`（未完了）または `- [ ]*`（最上位 deferrable）で始まり、
#       整数 ID + `.` + 半角スペースが続く行（例: `- [ ] 1. <名前>` /
#       `- [ ]* 3. <名前>`）。
#   - **子タスク（小数階層 ID `1.1` 等）を除外**（Req 1.2）: `[0-9]+\. ` は整数 +
#     `.` + 空白を要求するため、`1.1` は `.` の直後が空白でなく不一致。
#   - **完了済みタスク（`- [x]` / `- [x]*`）を除外**（Req 1.3）: checkbox 部を
#     `\[ \]`（半角スペース 1 つ）に固定するため、`[x]` には一致しない。
#   - **最上位 deferrable `- [ ]*` は計数に含む**（Req 1.4）: `\]\*?` の `\*?` が
#     アスタリスクを許容する。正準 regex の一致挙動に厳密一致させる方針
#     （design-review-gate.md 散文との関係は impl-notes.md「確認事項」参照）。
#   - `(P)` 並列マーカーの有無は ID 直後の語以降に現れるため計数に影響しない。
#
# 旧実装（〜#147）は `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` で全 checkbox 行
# （子・完了・deferrable を含む）を計上していたが、#216 で上記正準 regex に整合
# させ、Architect が「budget 内（≤10 最上位）」と確定した設計を harness が
# 「≥11（全 checkbox）」と誤って escalate する二重計上を解消した。閾値
# （TC_WARN_LOWER / TC_WARN_UPPER / TC_ESCALATE_LOWER）は不変（Req 2.4）。
#
# 入力: 第 1 引数 = tasks.md の絶対パス
# 戻り値: 0 = 抽出成功（stdout に件数 0 以上の整数 1 行）/ 1 = ファイル不在
# 副作用: なし（pure read）
tc_count_tasks() {
  local tasks_path="$1"
  [ -f "$tasks_path" ] || return 1
  # grep -cE: マッチ行数（件数）を 1 行で stdout に書き出す。マッチ 0 件でも
  # `--count` モードは 0 を返して exit 1 になるため、`|| true` で吸収する。
  # regex は design-review-gate.md の Budget overflow check と同一（#216）。
  local count
  count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$tasks_path" 2>/dev/null || true)
  # 空文字（読み取り失敗）の場合は安全側に 0 を返す
  echo "${count:-0}"
}

# ─── tc_classify ───
#
# 件数を 3 値レンジ（`normal` / `warn` / `escalate`）に分類して stdout に出力する
# 純粋関数（Req 2.1, 2.2, 2.3）。
#
#   - count < TC_WARN_LOWER         → normal    （既定で count ≤ 7）
#   - TC_WARN_LOWER ≤ count ≤ UPPER → warn      （既定で 8 ≤ count ≤ 10）
#   - count ≥ TC_ESCALATE_LOWER     → escalate  （既定で count ≥ 11）
#
# 閾値 env var が非整数の場合、tc_warn で警告ログを出したうえで既定値（8 / 10 / 11）に
# フォールバック（fail-safe / Req 4.2 系の安全側挙動）。
#
# 入力: 第 1 引数 = 件数（0 以上の整数）
# 戻り値: 常に 0（純粋関数、副作用は警告ログのみ）
# stdout: `normal` / `warn` / `escalate` のいずれか 1 つ
tc_classify() {
  local count="$1"
  # 閾値 env var の整数検証（非整数なら既定値にフォールバック）
  local lower="$TC_WARN_LOWER"
  local upper="$TC_WARN_UPPER"
  local escalate="$TC_ESCALATE_LOWER"
  if ! [[ "$lower" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_WARN_LOWER='$lower' は整数でないため既定値 8 にフォールバック"
    lower=8
  fi
  if ! [[ "$upper" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_WARN_UPPER='$upper' は整数でないため既定値 10 にフォールバック"
    upper=10
  fi
  if ! [[ "$escalate" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_ESCALATE_LOWER='$escalate' は整数でないため既定値 11 にフォールバック"
    escalate=11
  fi
  # count 自体が整数でない場合は normal にフォールバック（fail-safe）
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    tc_warn "count='$count' は整数でないため normal にフォールバック"
    echo "normal"
    return 0
  fi
  if [ "$count" -ge "$escalate" ]; then
    echo "escalate"
  elif [ "$count" -ge "$lower" ] && [ "$count" -le "$upper" ]; then
    echo "warn"
  else
    echo "normal"
  fi
}

# ─── tc_should_run ───
#
# 本機能を実行すべきか判定する gate（Req 1.5, 2.6, 3.3, 4.2, 4.4）。
#
# 以下のいずれかが真の場合 return 1（skip）、いずれも偽なら return 0:
#   - TC_ENABLED != "true"                              → reason=opt-out（Req 4.2）
#   - tasks.md が存在しない / 読み取れない              → reason=tasks-md-missing（Req 1.5）
#   - Issue に既に `needs-decisions` ラベルが付与済み   → reason=already-needs-decisions
#                                                          （Req 2.6 / 4.4。#131 由来でも
#                                                          本機能由来でも区別せず skip）
#
# resume 経路（impl-resume / Stage Checkpoint Resume）の skip は、本機能の hook が
# **design 分岐内側にのみ配置される**ことで構造的に保証される（Req 3.1 / 3.2）。
# impl-resume / Stage Checkpoint Resume はそれぞれ MODE=impl-resume または
# START_STAGE=B|C で動き、design 分岐に到達しないため、本関数の判定対象にならない。
#
# 入力: 環境変数 NUMBER / REPO / REPO_DIR / SPEC_DIR_REL / TC_ENABLED /
#       LABEL_NEEDS_DECISIONS
# 戻り値: 0 = run / 1 = skip
# 副作用: skip 時に tc_log で reason を記録（NFR 1.1）
tc_should_run() {
  # 1. opt-out 判定（TC_ENABLED != "true"）
  if [ "${TC_ENABLED:-true}" != "true" ]; then
    tc_log "issue=#${NUMBER:-?} skip reason=opt-out TC_ENABLED=${TC_ENABLED:-(unset)}"
    return 1
  fi
  # 2. tasks.md 不在 / 読み取り不可
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  if [ ! -f "$tasks_path" ] || [ ! -r "$tasks_path" ]; then
    tc_log "issue=#${NUMBER:-?} skip reason=tasks-md-missing path=$tasks_path"
    return 1
  fi
  # 3. 既に needs-decisions ラベル付与済み（#131 由来でも本機能由来でも区別せず skip）
  #    gh issue view が失敗しても skip 判定は false-negative 側に倒す（最悪重複適用のみ）
  local label_json existing_label_match
  if label_json=$(gh issue view "$NUMBER" --repo "$REPO" --json labels 2>/dev/null); then
    existing_label_match=$(echo "$label_json" \
      | jq -r --arg L "$LABEL_NEEDS_DECISIONS" '.labels[]? | select(.name == $L) | .name' 2>/dev/null \
      || true)
    if [ -n "$existing_label_match" ]; then
      tc_log "issue=#${NUMBER:-?} skip reason=already-needs-decisions"
      return 1
    fi
  else
    tc_warn "issue=#${NUMBER:-?} gh issue view 失敗（label 確認 skip、本機能は続行）"
  fi
  return 0
}

# ─── tc_already_posted_marker_present ───
#
# Issue コメント履歴に本機能由来の冪等マーカーが既に存在するか検知する（Req 2.6）。
#
# 固定識別子: `<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> issue=<N> ... -->`
# （NFR 1.2 の本機能由来判別文字列を兼ねる）
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = kind（warning | escalation）
# 戻り値: 0 = marker 検出済み（skip 推奨）/ 1 = 未検出（投稿可）
# 副作用: なし
#
# gh API 失敗時は marker absent (return 1) として扱う（最悪重複コメント投稿のみ）。
tc_already_posted_marker_present() {
  local issue_number="$1"
  local kind="$2"
  local bodies
  if ! bodies=$(gh issue view "$issue_number" --repo "$REPO" \
      --json comments --jq '.comments[].body' 2>/dev/null); then
    return 1
  fi
  # 固定マーカー prefix で grep（issue=<N> 部分も付き合わせて誤検出を抑える）
  local marker_prefix="<!-- idd-claude:tasks-count-overflow kind=$kind issue=$issue_number"
  if echo "$bodies" | grep -qF "$marker_prefix"; then
    return 0
  fi
  return 1
}

# ─── tc_post_warning_comment ───
#
# 8〜10 件レンジの警告コメントを冪等に投稿する（Req 2.2 / 2.6 / NFR 1.2）。
#
# 本文には以下を含める:
#   - 検知件数と適用閾値（TC_WARN_LOWER〜TC_WARN_UPPER）
#   - 後続フェーズは抑止されず通常進行する旨
#   - 末尾に固定識別マーカー
#     `<!-- idd-claude:tasks-count-overflow kind=warning issue=<N> count=<C> -->`
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 件数
# 戻り値: 常に 0（fail-open。投稿失敗は tc_warn でログのみ、watcher 全体は止めない）
tc_post_warning_comment() {
  local issue_number="$1"
  local count="$2"
  if tc_already_posted_marker_present "$issue_number" "warning"; then
    tc_log "issue=#${issue_number} already-warned skip duplicate comment"
    return 0
  fi
  local body
  body=$(cat <<EOF
⚠️ **Tasks Count Gate (harness, #147)**: tasks.md の最上位・未完了タスク件数が警告レンジに該当しています

- 検知件数: **${count} 件**（最上位 numeric ID の未完了タスクのみ。子タスク \`1.1\` / 完了済み \`- [x]\` は計数対象外。#216 で Architect の Budget overflow check 計数と整合）
- 適用閾値: ${TC_WARN_LOWER} 件以上 ${TC_WARN_UPPER} 件以下で警告（参考: ≥ ${TC_ESCALATE_LOWER} 件で Developer 自動起動抑止）
- 本コメントは通知のみで、**後続フェーズ（Developer 自動起動）は通常通り進行します**

タスク件数が turn budget を圧迫する境界域です。Developer Round 1 で PR 作成まで完走しない可能性が高まるため、Issue 分割を検討してください（Issue #131 で Architect 側にも同種の自己レビュー gate が動いています）。

<!-- idd-claude:tasks-count-overflow kind=warning issue=${issue_number} count=${count} -->
EOF
)
  if gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} posted warning-comment count=${count}"
  else
    tc_warn "issue=#${issue_number} gh issue comment 失敗（warning 投稿、fail-open で続行）"
  fi
  return 0
}

# ─── tc_post_escalation_comment ───
#
# 11 件以上のエスカレーションコメントを冪等に投稿する
# （Req 2.3 / 2.5 / 2.6 / NFR 1.2）。
#
# 本文には以下を必ず含める:
#   - 検知件数と適用閾値（TC_ESCALATE_LOWER）
#   - 抑止された後続フェーズ名（Developer 自動起動 / impl-resume）
#   - 人間が取りうる回復手順:
#     - 推奨: Issue 分割の検討（PM / Architect に差し戻し）
#     - バイパス: `needs-decisions` ラベルを人間が外す（次サイクルで再評価。件数が
#       変わらなければ再付与される旨も注記）
#     - 完全 opt-out: `TC_ENABLED=false` で watcher を再起動
#   - 末尾に固定識別マーカー
#     `<!-- idd-claude:tasks-count-overflow kind=escalation issue=<N> count=<C> -->`
#     （NFR 1.2 の本機能由来判別文字列を兼ねる）
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 件数
# 戻り値: 常に 0（fail-open）
tc_post_escalation_comment() {
  local issue_number="$1"
  local count="$2"
  if tc_already_posted_marker_present "$issue_number" "escalation"; then
    tc_log "issue=#${issue_number} already-escalated skip duplicate comment"
    return 0
  fi
  local body
  body=$(cat <<EOF
🚫 **Tasks Count Gate (harness, #147)**: tasks.md の最上位・未完了タスク件数が **エスカレーション閾値**を超えています

- 検知件数: **${count} 件**（最上位 numeric ID の未完了タスクのみ。子タスク \`1.1\` / 完了済み \`- [x]\` は計数対象外。#216 で Architect の Budget overflow check 計数と整合）
- 適用閾値: ${TC_ESCALATE_LOWER} 件以上でエスカレーション（参考: ${TC_WARN_LOWER}〜${TC_WARN_UPPER} 件は警告のみ）
- **抑止された後続フェーズ**: Developer 自動起動 / impl-resume（\`needs-decisions\` ラベルにより watcher Issue 候補抽出から除外されます）
- 根拠: KeyNest 3 事例で 10 件超の tasks.md は Developer Round 1 で PR 作成まで完走しない確率が高く、turn budget 超過によるキャッシュトークン浪費が観測されています

### 人間が取りうる回復手順

1. **推奨: Issue 分割の検討** — PM / Architect に差し戻し、要件・設計を複数 Issue に分割してください
2. **バイパス: \`needs-decisions\` ラベルを人間が外す** — 次サイクルで watcher は再 pickup を試行しますが、件数が変わらなければ本機能が再付与します（恒久バイパスにはなりません）
3. **完全 opt-out: \`TC_ENABLED=false\`** — cron / launchd の env var に追加して watcher を再起動すると、本機能による全 Issue への評価が無効化されます

<!-- idd-claude:tasks-count-overflow kind=escalation issue=${issue_number} count=${count} -->
EOF
)
  if gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} posted escalation-comment count=${count}"
  else
    tc_warn "issue=#${issue_number} gh issue comment 失敗（escalation 投稿、fail-open で続行）"
  fi
  return 0
}

# ─── tc_add_needs_decisions_label ───
#
# `needs-decisions` ラベルを冪等に付与する（Req 2.3 / 2.4 / 4.4 / NFR 2.2）。
#
# `gh issue edit --add-label` は同名ラベルを多重付与しない仕様のため、構造的に冪等。
# 既存 `LABEL_NEEDS_DECISIONS` env var 値（既定 `needs-decisions`）を参照し、
# 新ラベル名は導入しない（NFR 2.2 既存ラベル名互換）。
#
# 入力: 第 1 引数 = Issue 番号
# 戻り値: 常に 0（fail-open。付与失敗は次サイクルで再判定して再付与トライ可能）
tc_add_needs_decisions_label() {
  local issue_number="$1"
  if gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} added label=${LABEL_NEEDS_DECISIONS}"
  else
    tc_warn "issue=#${issue_number} gh issue edit --add-label 失敗（fail-open で続行）"
  fi
  return 0
}

# ─── tc_run_post_architect_check ───
#
# design 分岐 rc=0 直後に呼ばれる orchestrator。本機能の単一エントリポイント
# （Req 1.1, 1.6, 2.1, 2.2, 2.3, 3.3, 4.1）。
#
# 順序:
#   1. tc_should_run を呼び、skip 判定なら return 0（design 分岐の挙動を維持）
#   2. tc_count_tasks で件数取得
#   3. tc_classify でレンジを取得
#   4. レンジに応じて分岐:
#      - normal   → ログのみ
#      - warn     → tc_post_warning_comment
#      - escalate → tc_post_escalation_comment + tc_add_needs_decisions_label
#
# 戻り値: 常に 0（呼び出し元 design 分岐 rc=0 の挙動を変えない / fail-open）
# 副作用: ログ書き込み、gh issue edit/comment
tc_run_post_architect_check() {
  if ! tc_should_run; then
    return 0
  fi
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  local count
  count=$(tc_count_tasks "$tasks_path")
  # tc_count_tasks は空文字を返さないが、defensive に整数フォールバックを入れる
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    tc_warn "issue=#${NUMBER:-?} count='$count' が整数でないため 0 にフォールバック"
    count=0
  fi
  local range
  range=$(tc_classify "$count")
  case "$range" in
    normal)
      tc_log "issue=#${NUMBER:-?} count=${count} range=normal action=none"
      ;;
    warn)
      tc_log "issue=#${NUMBER:-?} count=${count} range=warn action=warning-comment"
      tc_post_warning_comment "$NUMBER" "$count" || true
      ;;
    escalate)
      tc_log "issue=#${NUMBER:-?} count=${count} range=escalate action=needs-decisions+escalation-comment"
      tc_post_escalation_comment "$NUMBER" "$count" || true
      tc_add_needs_decisions_label "$NUMBER" || true
      ;;
    *)
      tc_warn "issue=#${NUMBER:-?} unknown classification='$range' count=${count} (fail-open)"
      ;;
  esac
  return 0
}
