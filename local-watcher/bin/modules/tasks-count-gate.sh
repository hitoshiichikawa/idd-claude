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
#   Phase 3（#509 / opt-in `TC_SPLIT_PROPOSAL_ENABLED`）: escalate 時の子 Issue 分割案
#   - tc_split_proposal_enabled                    : 分割案機能の opt-in gate
#   - tc_sanitize_text                             : 未信頼 tasks.md 断片の無害化（純粋）
#   - tc_truncate_title                            : タイトル案の文字数上限適用（純粋）
#   - tc_extract_top_level_tasks                   : 最上位・未完了タスクの抽出（純粋）
#   - tc_group_tasks                               : 相互依存併合によるグルーピング（純粋）
#   - tc_build_split_proposal_body                 : 分割案コメント本文の生成（純粋）
#   - tc_split_proposal_already_posted             : 分割案専用の冪等マーカー検知
#   - tc_post_split_proposal_comment               : 分割案コメント投稿（fail-open）
#
#   設計参照: docs/specs/147-feat-harness-tasks-md-task-auto-dev-issu/design.md
#            docs/specs/509-feat-watcher-tasks-count-gate-escalate-i/requirements.md
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

# =============================================================================
# Phase 3 (#509): escalate 時の子 Issue 分割案コメント
#
# escalate（既定 ≥ 11 件）と確定した Issue に対し、`tasks.md` の最上位・未完了
# タスクから **子 Issue 分割案** を機械生成してコメント投稿する（Req 2.1）。
# LLM 追加起動は行わず bash の文字列処理のみで生成する（NFR 3.1）。
#
# opt-in gate `TC_SPLIT_PROPOSAL_ENABLED`（既定 false / `true` 厳密一致のみ有効）
# の配下にあり、無効時は本機能に起因する GitHub API 呼び出しもログ出力も 0 件
# （Req 1.1〜1.4 / NFR 1.1 / NFR 3.3）。
#
# 既存 escalate 処理（escalation コメント投稿 + `needs-decisions` 付与）は
# **置き換えず追加**であり、本機能の失敗は WARN ログのみで既存処理を中断しない
# （Req 2.3 / 6.5 / 6.6）。
# =============================================================================

# ─── tc_split_proposal_enabled ───
#
# 分割案機能の opt-in gate（Req 1.1〜1.3 / 1.5）。
# `TC_SPLIT_PROPOSAL_ENABLED` がリテラル `true` に厳密一致するときのみ rc=0。
# 未設定 / 空 / `false` / `off` / `True` / `1` / typo はすべて安全側（無効）へ
# 正規化する。既存 gate 慣習（`MODEL_ROUTING_ENABLED` / `PATH_OVERLAP_CHECK` の
# `= "true"` 厳密一致）と同型で、`TC_ENABLED` / `MODEL_ROUTING_ENABLED` とは
# 独立した変数で制御する（Req 1.5）。
#
# 入力: 環境変数 TC_SPLIT_PROPOSAL_ENABLED
# 戻り値: 0 = 有効 / 1 = 無効
# 副作用: なし（無効時もログを出さない / Req 1.4）
tc_split_proposal_enabled() {
  [ "${TC_SPLIT_PROPOSAL_ENABLED:-false}" = "true" ]
}

# ─── tc_sanitize_text ───
#
# `tasks.md` 由来の未信頼テキスト断片を、コメント本文・起票コマンド雛形に
# 埋め込んでも安全な形へ無害化する純粋関数（NFR 4.1 / 4.2）。
#
#   - CR / TAB を半角スペースへ（レコード区切り TAB の混入防止）
#   - HTML コメント記法 `<!--` / `-->` を半角スペース挿入で分断（本機能の冪等
#     マーカーと同一文字列が混入しても marker 検知を誤らせない / NFR 4.2）。
#     置換後の文字列は `<` の直後が半角スペースになるため新たな `<!--` を
#     生成せず、bash の `${var//pat/rep}` が置換結果を再走査しない性質と併せて
#     多重入れ子（`<<!--!--` 等）でもマーカー再構成は起こらない。
#     実体参照（`&lt;`）は使わない（bash の置換文字列では `&` がマッチ全体に
#     展開されるため / 検証済み）
#   - シェル・markdown で解釈されうる文字（`` ` `` / `$` / `\` / `"` / `'`）を除去
#     （起票コマンド雛形は単一引用符で囲むため `'` の除去でクォート破壊を防ぐ）
#   - 連続スペースの圧縮と前後トリム
#
# 入力: 第 1 引数 = 生テキスト
# stdout: 無害化済みテキスト（改行なし）
# 戻り値: 常に 0 / 副作用: なし
tc_sanitize_text() {
  local s="$1"
  s="${s//$'\r'/ }"
  s="${s//$'\t'/ }"
  s="${s//<!--/< !--}"
  s="${s//-->/-- >}"
  s="${s//\`/}"
  s="${s//\$/}"
  s="${s//\\/}"
  s="${s//\"/}"
  s="${s//\'/}"
  while [ "${s}" != "${s//  / }" ]; do
    s="${s//  / }"
  done
  # 前後の空白をトリム（bash パラメータ展開のみで外部コマンドを起動しない）
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# ─── tc_truncate_title ───
#
# タイトル案を最大文字数（既定 120 / NFR 3.5）に収める純粋関数。
# 上限超過時は末尾 1 文字分を省略記号 `…` に置き換える。
#
# ロケール差の扱い: bash の `${s:0:N}` は UTF-8 ロケールでは文字単位、C / POSIX
# ロケールではバイト単位で切り出す。後者では日本語（3 バイト）の途中で切れた
# 壊れたバイト列が残りうるため、マルチバイト非対応ロケールと判定した場合のみ
# 末尾の非 ASCII バイトを巻き戻す（表示が数文字短くなるだけで、いずれのロケール
# でも「120 文字以内」を満たす）。
#
# 入力: 第 1 引数 = タイトル案 / 第 2 引数 = 最大文字数（既定 120）
# stdout: 上限内に収めたタイトル案
# 戻り値: 常に 0 / 副作用: なし
tc_truncate_title() {
  local s="$1"
  local max="${2:-120}"
  if ! [[ "$max" =~ ^[0-9]+$ ]] || [ "$max" -lt 2 ]; then
    max=120
  fi
  if [ "${#s}" -le "$max" ]; then
    printf '%s' "$s"
    return 0
  fi
  local cut="${s:0:$((max - 1))}"
  local probe='あ'
  if [ "${#probe}" -ne 1 ]; then
    # C / POSIX ロケール = バイト単位スライス。末尾の UTF-8 継続バイト（0x80〜0xBF）を
    # 落とし、先頭バイト（0xC0 以上）を 1 つ落とした時点で文字境界が確定する。
    # 失われるのは最大 1 文字分に留まる。
    local last code
    while [ -n "$cut" ]; do
      last="${cut: -1}"
      code=$(printf '%d' "'$last" 2>/dev/null || echo 0)
      code="${code:-0}"
      if [ "$code" -lt 0 ]; then
        code=$((code + 256))
      fi
      if [ "$code" -lt 128 ]; then
        break
      fi
      cut="${cut%?}"
      if [ "$code" -ge 192 ]; then
        break
      fi
    done
  fi
  printf '%s…' "$cut"
}

# ─── tc_extract_top_level_tasks ───
#
# `tasks.md` から **最上位・未完了タスク**を抽出する純粋関数（Req 3.1〜3.3, 3.5）。
#
# 抽出条件は tc_count_tasks の正準 regex `^- \[ \]\*? [0-9]+\. ` に厳密一致させる。
# したがって同一 `tasks.md` に対して escalate 判定の件数と抽出件数は一致し
# （Req 3.3）、子タスク（`1.1` 等）と完了済みタスク（`- [x]` / `- [x]*`）は
# 独立した抽出単位にならない（Req 3.2）。
#
# `_Depends:_` アノテーションは、直前に現れた最上位・未完了タスクの配下（その
# 子タスク行を含む）に属するものとして集約し、参照先 ID は先頭の整数部だけを
# 取り出して最上位タスク ID へ正規化する（Req 3.5。例: `_Depends: 2.1_` → `2`）。
# 自己参照と重複は除去する。完了済み最上位タスク配下のアノテーションは
# 直前タスクへ誤って帰属させないよう、対象タスクを解除して読み飛ばす。
#
# 入力: 第 1 引数 = tasks.md の絶対パス
# stdout: 1 行 1 タスクの TAB 区切りレコード
#         `<最上位 ID>\t<無害化済み要約>\t<正規化済み依存 ID（半角スペース区切り）>`
# 戻り値: 0 = 抽出成功（0 件でも 0）/ 1 = ファイル不在・読み取り不可
# 副作用: なし（pure read。tasks.md は書き換えない / Req 6.7）
tc_extract_top_level_tasks() {
  local tasks_path="$1"
  if [ ! -f "$tasks_path" ] || [ ! -r "$tasks_path" ]; then
    return 1
  fi
  local -a out_ids=() out_summaries=() out_deps=()
  local line cur_id="" cur_index=-1
  local summary raw tok top
  local -a toks=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    # 最上位・未完了タスク行（正準 regex と同一条件）
    if [[ "$line" =~ ^-\ \[\ \]\*?\ ([0-9]+)\.\ (.*)$ ]]; then
      cur_id="${BASH_REMATCH[1]}"
      summary=$(tc_sanitize_text "${BASH_REMATCH[2]}")
      # 並列マーカー `(P)` はタイトル案に持ち込まない（起票時のノイズになるため）
      summary="${summary% (P)}"
      out_ids+=("$cur_id")
      out_summaries+=("$summary")
      out_deps+=("")
      cur_index=$((${#out_ids[@]} - 1))
      continue
    fi
    # 完了済み最上位タスク行 → 以降のアノテーションは帰属先なしとして読み飛ばす
    if [[ "$line" =~ ^-\ \[x\]\*?\ [0-9]+\.\  ]]; then
      cur_id=""
      cur_index=-1
      continue
    fi
    # `_Depends: 1, 2.1_` 形式のアノテーション（帰属先が確定している場合のみ）
    if [ "$cur_index" -ge 0 ] && [[ "$line" =~ _Depends:[[:space:]]*([^_]*)_ ]]; then
      raw="${BASH_REMATCH[1]}"
      raw="${raw//,/ }"
      toks=()
      read -ra toks <<< "$raw"
      for tok in "${toks[@]}"; do
        [[ "$tok" =~ ^([0-9]+)(\.[0-9]+)*$ ]] || continue
        top="${BASH_REMATCH[1]}"
        [ "$top" != "$cur_id" ] || continue
        case " ${out_deps[$cur_index]} " in
          *" $top "*) continue ;;
        esac
        out_deps[cur_index]="${out_deps[$cur_index]}${out_deps[$cur_index]:+ }$top"
      done
    fi
  done < "$tasks_path"
  local i
  for ((i = 0; i < ${#out_ids[@]}; i++)); do
    printf '%s\t%s\t%s\n' "${out_ids[$i]}" "${out_summaries[$i]}" "${out_deps[$i]}"
  done
  return 0
}

# ─── tc_group_tasks ───
#
# 抽出済みタスクレコードを子 Issue 案の単位へグルーピングする純粋関数
# （Req 3.1, 3.4, 3.6, 3.7）。
#
# 既定は最上位タスク 1 件 = 子 Issue 案 1 件（Req 3.1）。ただし `_Depends:_` 由来の
# 依存関係が **循環する**（相互到達可能な）タスク群は 1 件の案へ統合する（Req 3.4）。
# 実装は依存辺の推移閉包（Floyd–Warshall 形式）を取り、`i → j` かつ `j → i` の
# 双方が成立するノードを同一グループへ併合する（強連結成分と等価）。
# 存在しない ID への依存辺は無視する。
#
# 出力順は `tasks.md` の出現順（グループ内も出現順）で、同一入力に対して常に
# 同一の結果を返す（Req 3.7）。すべての入力タスクはいずれか 1 グループへ
# 過不足なく 1 回だけ現れる（Req 3.6）。
#
# 入力: stdin = tc_extract_top_level_tasks 形式の TAB 区切りレコード
# stdout: 1 行 1 グループ。半角スペース区切りの最上位タスク ID 列
# 戻り値: 常に 0 / 副作用: なし
tc_group_tasks() {
  local -a ids=() deps=()
  local _id _sum _dep
  while IFS=$'\t' read -r _id _sum _dep; do
    [ -n "$_id" ] || continue
    ids+=("$_id")
    deps+=("$_dep")
  done
  local n=${#ids[@]}
  if [ "$n" -eq 0 ]; then
    return 0
  fi
  local i j k
  local -A idx_of=()
  for ((i = 0; i < n; i++)); do
    idx_of["${ids[$i]}"]=$i
  done
  # 直接依存辺（存在しない ID / 自己参照は除外）
  local -A reach=()
  local -a dep_toks=()
  local d di
  for ((i = 0; i < n; i++)); do
    dep_toks=()
    read -ra dep_toks <<< "${deps[$i]}"
    for d in "${dep_toks[@]:-}"; do
      [ -n "$d" ] || continue
      di="${idx_of[$d]:-}"
      [ -n "$di" ] || continue
      [ "$di" -ne "$i" ] || continue
      reach["$i,$di"]=1
    done
  done
  # 推移閉包（n は最上位タスク件数のみ = 実運用で数十件のため n^3 で十分）
  for ((k = 0; k < n; k++)); do
    for ((i = 0; i < n; i++)); do
      [ -n "${reach["$i,$k"]:-}" ] || continue
      for ((j = 0; j < n; j++)); do
        if [ -n "${reach["$k,$j"]:-}" ]; then
          reach["$i,$j"]=1
        fi
      done
    done
  done
  # 相互到達（循環依存）を同一グループへ併合
  local -a group_of=()
  for ((i = 0; i < n; i++)); do
    group_of[i]=-1
  done
  local g=0
  for ((i = 0; i < n; i++)); do
    [ "${group_of[$i]}" -eq -1 ] || continue
    group_of[i]=$g
    for ((j = i + 1; j < n; j++)); do
      [ "${group_of[$j]}" -eq -1 ] || continue
      if [ -n "${reach["$i,$j"]:-}" ] && [ -n "${reach["$j,$i"]:-}" ]; then
        group_of[j]=$g
      fi
    done
    g=$((g + 1))
  done
  local out
  for ((k = 0; k < g; k++)); do
    out=""
    for ((i = 0; i < n; i++)); do
      if [ "${group_of[$i]}" -eq "$k" ]; then
        out="${out}${out:+ }${ids[$i]}"
      fi
    done
    printf '%s\n' "$out"
  done
  return 0
}

# ─── tc_build_split_proposal_body ───
#
# 分割案コメントの本文を生成する純粋関数（Req 4.1〜4.11 / 5.1 / NFR 3.4）。
#
# 各子 Issue 案には以下を含める:
#   - タイトル案（Req 4.1 / NFR 3.5 で 120 文字以内）
#   - 含む最上位タスクの numeric ID 一覧（Req 4.2）
#   - `Split from: #<元 Issue>` / `Parent: #<元 Issue>`（Req 4.3 / 4.4）
#   - 案間依存がある場合の `Depends on: 案 <番号>`（Req 4.5 / 4.6）
# 関係種別のキーは canonical 記法の英語表記のみを使い、alias 表記と逆ブロッキング
# 表記 `Blocks:` は出力しない（Req 4.7 / 4.8。`.claude/rules/issue-dependency.md`）。
# 併せて検知件数・適用閾値（Req 4.11）、提案であり自動起票しない旨（Req 4.9）、
# 起票コマンドの雛形（Req 4.10 / NFR 4.4）、冪等マーカー（Req 5.1）を含める。
#
# 本文が NFR 3.4 の上限（60,000 文字）に接触する場合は、以降の案の詳細を省略した
# 旨を明記して打ち切る（決定論的に先頭から詰める）。
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 検知件数 / 第 3 引数 = tasks.md パス
# stdout: コメント本文
# 戻り値: 0 = 生成成功 / 1 = 生成失敗（引数不正・ファイル不在）/
#         2 = 入力となる最上位・未完了タスクが 0 件（Req 2.4）
# 副作用: なし（GitHub API 呼び出しなし / tasks.md は書き換えない）
tc_build_split_proposal_body() {
  local issue_number="$1"
  local count="$2"
  local tasks_path="$3"
  # Issue 番号は数値として検証してから `#N` 参照記法に用いる（NFR 4.3）
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    count=0
  fi
  local records
  records=$(tc_extract_top_level_tasks "$tasks_path") || return 1
  if [ -z "$records" ]; then
    return 2
  fi

  local -a ids=() summaries=() deps=()
  local _id _sum _dep
  while IFS=$'\t' read -r _id _sum _dep; do
    [ -n "$_id" ] || continue
    ids+=("$_id")
    summaries+=("$_sum")
    deps+=("$_dep")
  done <<< "$records"
  local n=${#ids[@]}
  if [ "$n" -eq 0 ]; then
    return 2
  fi

  local groups
  groups=$(printf '%s\n' "$records" | tc_group_tasks)
  local -a group_members=()
  local gline
  while IFS= read -r gline; do
    [ -n "$gline" ] || continue
    group_members+=("$gline")
  done <<< "$groups"
  local gn=${#group_members[@]}
  if [ "$gn" -eq 0 ]; then
    return 2
  fi

  local i g
  local -A summary_of=() deps_of=() group_no_of=()
  for ((i = 0; i < n; i++)); do
    summary_of["${ids[$i]}"]="${summaries[$i]}"
    deps_of["${ids[$i]}"]="${deps[$i]}"
  done
  local -a members=()
  local m
  for ((g = 0; g < gn; g++)); do
    members=()
    read -ra members <<< "${group_members[$g]}"
    for m in "${members[@]:-}"; do
      [ -n "$m" ] || continue
      group_no_of["$m"]=$((g + 1))
    done
  done

  # 案間依存は直接 `_Depends:_` 辺のみを採用する（推移閉包は表示ノイズになるため使わない）
  local -A group_dep_pairs=()
  local -a dep_toks=()
  local d from_no to_no
  for ((g = 0; g < gn; g++)); do
    members=()
    read -ra members <<< "${group_members[$g]}"
    from_no=$((g + 1))
    for m in "${members[@]:-}"; do
      [ -n "$m" ] || continue
      dep_toks=()
      read -ra dep_toks <<< "${deps_of[$m]:-}"
      for d in "${dep_toks[@]:-}"; do
        [ -n "$d" ] || continue
        to_no="${group_no_of[$d]:-}"
        [ -n "$to_no" ] || continue
        [ "$to_no" -ne "$from_no" ] || continue
        group_dep_pairs["$from_no,$to_no"]=1
      done
    done
  done

  local nl=$'\n'
  local -a titles=()
  local title parts
  for ((g = 0; g < gn; g++)); do
    members=()
    read -ra members <<< "${group_members[$g]}"
    parts=""
    for m in "${members[@]:-}"; do
      [ -n "$m" ] || continue
      parts="${parts}${parts:+ / }${summary_of[$m]:-タスク $m}"
    done
    [ -n "$parts" ] || parts="タスク分割案 $((g + 1))"
    title=$(tc_truncate_title "$parts" 120)
    titles+=("$title")
  done

  local header
  header="🧩 **Tasks Count Gate — 子 Issue 分割案 (harness, #509)**: escalate 判定に伴い、\`tasks.md\` の最上位・未完了タスクから機械生成した分割案を提示します${nl}${nl}"
  header="${header}- 検知件数: **${count} 件**（最上位 numeric ID の未完了タスクのみ。子タスク \`1.1\` / 完了済み \`- [x]\` は計数対象外）${nl}"
  header="${header}- 適用閾値: ${TC_ESCALATE_LOWER:-11} 件以上でエスカレーション（参考: ${TC_WARN_LOWER:-8}〜${TC_WARN_UPPER:-10} 件は警告のみ）${nl}"
  header="${header}- 生成した子 Issue 案: **${gn} 件**${nl}"
  header="${header}- ⚠️ 本コメントは **提案のみ** です。watcher は子 Issue を自動起票しません（起票・調整は人間が行います）${nl}"
  header="${header}- ⚠️ \`Depends on:\` の参照先は本コメント内の **案番号**（\`案 1\` 等）です。子 Issue 起票後に **実 Issue 番号 \`#<番号>\` へ置き換えてください**${nl}${nl}"

  local footer_marker
  footer_marker="${nl}<!-- idd-claude:tasks-count-split-proposal issue=${issue_number} count=${count} proposals=${gn} -->${nl}"

  # 本文長上限（NFR 3.4）。先頭から詰め、超過分は省略した旨を明記する
  local max_body=60000
  local blocks="" cmds="" omitted=0 truncated=0
  local block cmd id_list body_lines dep_line
  for ((g = 0; g < gn; g++)); do
    if [ "$truncated" -eq 1 ]; then
      omitted=$((omitted + 1))
      continue
    fi
    members=()
    read -ra members <<< "${group_members[$g]}"
    id_list=""
    body_lines=""
    for m in "${members[@]:-}"; do
      [ -n "$m" ] || continue
      id_list="${id_list}${id_list:+, }\`${m}\`"
      body_lines="${body_lines}- ${m}. ${summary_of[$m]:-}${nl}"
    done
    block="### 案 $((g + 1)): ${titles[$g]}${nl}${nl}"
    block="${block}- 含む最上位タスク: ${id_list}${nl}"
    block="${block}- Split from: #${issue_number}${nl}"
    block="${block}- Parent: #${issue_number}${nl}"
    dep_line=""
    for ((i = 1; i <= gn; i++)); do
      if [ -n "${group_dep_pairs["$((g + 1)),$i"]:-}" ]; then
        dep_line="${dep_line}${dep_line:+, }案 ${i}"
      fi
    done
    if [ -n "$dep_line" ]; then
      block="${block}- Depends on: ${dep_line}${nl}"
    fi
    block="${block}${nl}"
    cmd="gh issue create --repo <owner/repo> \\${nl}"
    cmd="${cmd}  --title '${titles[$g]}' \\${nl}"
    cmd="${cmd}  --body '## 関連${nl}${nl}- Split from: #${issue_number}${nl}- Parent: #${issue_number}${nl}${nl}## 対象タスク（元 Issue #${issue_number} の tasks.md 最上位タスク）${nl}${nl}${body_lines}'${nl}${nl}"
    if [ $((${#header} + ${#blocks} + ${#block} + ${#cmds} + ${#cmd} + ${#footer_marker} + 512)) -gt "$max_body" ]; then
      truncated=1
      omitted=$((omitted + 1))
      continue
    fi
    blocks="${blocks}${block}"
    cmds="${cmds}${cmd}"
  done

  local cmd_section
  cmd_section="### 起票コマンドの雛形${nl}${nl}"
  cmd_section="${cmd_section}> 内容を確認・調整したうえで **人間が実行** してください（watcher は実行しません）。起票後に \`auto-dev\` ラベルを付けると通常の自動フローに乗ります。${nl}${nl}"
  cmd_section="${cmd_section}\`\`\`bash${nl}${cmds%$'\n'}\`\`\`${nl}"

  local omit_note=""
  if [ "$omitted" -gt 0 ]; then
    omit_note="${nl}> **注**: コメント本文長の上限（${max_body} 文字）に達したため、残り ${omitted} 件の案は省略しました。省略分は \`tasks.md\` の残りの最上位タスクに対応します。${nl}"
  fi

  printf '%s' "${header}${blocks}${cmd_section}${omit_note}${footer_marker}"
  return 0
}

# ─── tc_split_proposal_already_posted ───
#
# Issue コメント履歴に **分割案専用**の冪等マーカーが既に存在するか検知する
# （Req 5.1〜5.4）。
#
# 固定マーカー: `<!-- idd-claude:tasks-count-split-proposal issue=<N> ... -->`
# 既存 escalation コメントのマーカー（`tasks-count-overflow`）とは独立しており、
# escalation コメントがマーカー検知で skip された場合でも本判定には影響しない
# （Req 5.3 / 5.4）。
#
# gh API 失敗時は marker 不在（return 1）として扱う。影響は重複コメント 1 件まで
# に留まる（Req 5.6）。
#
# 入力: 第 1 引数 = Issue 番号
# 戻り値: 0 = marker 検出済み（skip 推奨）/ 1 = 未検出（投稿可）
# 副作用: gh issue view 1 回（NFR 3.2）
tc_split_proposal_already_posted() {
  local issue_number="$1"
  local bodies
  if ! bodies=$(gh issue view "$issue_number" --repo "$REPO" \
      --json comments --jq '.comments[].body' 2>/dev/null); then
    return 1
  fi
  local marker_prefix="<!-- idd-claude:tasks-count-split-proposal issue=$issue_number"
  # 未信頼なコメント本文を pattern として解釈させないため -F、
  # `-` 始まりの pattern を option 解釈させないため -- で打ち切る
  if printf '%s' "$bodies" | grep -qF -- "$marker_prefix"; then
    return 0
  fi
  return 1
}

# ─── tc_post_split_proposal_comment ───
#
# escalate 時に子 Issue 分割案コメントを冪等・fail-open で投稿する
# （Req 2.1〜2.5 / 5.2 / 5.5 / 5.7 / 6.5 / 6.6 / NFR 2.1〜2.4 / 3.2 / 3.3）。
#
# 順序（GitHub API 呼び出しを 2 回以下に抑えるため本文生成を先に行う / NFR 3.2）:
#   1. gate 無効 → 何もせず return 0（ログ 0 行 / API 0 回 / Req 1.4 / NFR 3.3）
#   2. Issue 番号の数値検証（NFR 4.3）
#   3. 本文生成（ローカル処理のみ）。タスク 0 件なら skip ログ（Req 2.4）
#   4. 分割案専用マーカーの既投稿判定（gh issue view 1 回 / Req 5.2）
#   5. コメント投稿（gh issue comment 1 回）
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 件数 / 第 3 引数 = tasks.md パス
# 戻り値: 常に 0（fail-open。失敗は WARN ログのみで呼び出し元を中断しない）
tc_post_split_proposal_comment() {
  local issue_number="$1"
  local count="$2"
  local tasks_path="$3"
  if ! tc_split_proposal_enabled; then
    return 0
  fi
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    tc_warn "issue=#${issue_number} split-proposal 生成失敗 reason=invalid-issue-number（fail-open で続行）"
    return 0
  fi
  local body rc=0
  body=$(tc_build_split_proposal_body "$issue_number" "$count" "$tasks_path") || rc=$?
  if [ "$rc" -eq 2 ]; then
    tc_log "issue=#${issue_number} split-proposal skip reason=no-top-level-tasks"
    return 0
  fi
  if [ "$rc" -ne 0 ] || [ -z "$body" ]; then
    tc_warn "issue=#${issue_number} split-proposal 生成失敗 reason=build-failed rc=${rc}（fail-open で続行）"
    return 0
  fi
  if tc_split_proposal_already_posted "$issue_number"; then
    tc_log "issue=#${issue_number} split-proposal skip reason=already-posted"
    return 0
  fi
  local proposals
  proposals=$(printf '%s' "$body" | grep -cE '^### 案 [0-9]+:' || true)
  proposals="${proposals:-0}"
  if gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} posted split-proposal-comment count=${count} proposals=${proposals}"
  else
    tc_warn "issue=#${issue_number} gh issue comment 失敗（split-proposal 投稿、fail-open で続行）"
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
#                   （+ TC_SPLIT_PROPOSAL_ENABLED=true のとき
#                     tc_post_split_proposal_comment / #509 Req 2.1, 2.3）
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
      # 子 Issue 分割案（#509 / opt-in）。既存 escalate 処理を置き換えず追加し、
      # 失敗しても escalate 本体は完了済み（Req 2.3 / 6.5 / 6.6）
      tc_post_split_proposal_comment "$NUMBER" "$count" "$tasks_path" || true
      ;;
    *)
      tc_warn "issue=#${NUMBER:-?} unknown classification='$range' count=${count} (fail-open)"
      ;;
  esac
  return 0
}
