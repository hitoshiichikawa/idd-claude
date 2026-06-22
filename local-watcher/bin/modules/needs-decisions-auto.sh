#!/usr/bin/env bash
# needs-decisions-auto.sh — watcher の needs-decisions 自動続行プロセッサモジュール
#
# 用途:
#   `needs-decisions` 状態の Issue のうち、Triage / PM が「明確な推奨デフォルトを
#   持ち、機密・コンプラ・不可逆・外部影響のいずれにも該当しない」と分類した
#   `safe` ケースを、watcher が PM の第一推奨で自動続行できるようにする。
#   `human-only`（機密 / コンプラ / 不可逆 / 外部影響）はモードによらず絶対停止
#   する hard safety boundary を持ち、機密情報の自動続行リスクをゼロに保つ。
#   `FULL_AUTO_ENABLED`（#348）と `NEEDS_DECISIONS_MODE`（本機能）の AND 二重
#   opt-in 配下でのみ発火し、既定（mode=all-human）では gh API 呼び出しゼロで
#   本機能導入前と完全等価。
#
#   - nda_log / nda_warn / nda_error           : needs-decisions-auto 専用ロガー
#   - nda_resolve_mode_enabled                 : NEEDS_DECISIONS_MODE が classified / all-auto か判定
#   - nda_extract_classification               : Triage JSON の decisions[].classification を fail-safe で抽出
#   - nda_extract_first_recommendation         : Triage JSON の decisions[0].recommendation を抽出
#   - nda_auto_continue                        : 採用 recommendation コメント投稿 + claude-claimed 除去
#   - nda_evaluate_auto_continue               : 判定エントリ（AND 二重 opt-in / 判定順序）
#
# 配置先:
#   $HOME/bin/modules/needs-decisions-auto.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$NEEDS_DECISIONS_MODE / $FULL_AUTO_ENABLED / $REPO / $NUMBER /
#     $LABEL_CLAIMED / $LABEL_NEEDS_DECISIONS / $TRIAGE_FILE / $LOG）は本体冒頭の
#     Config ブロック・遅延束縛で解決される。
#   - `full_auto_enabled` 関数（#348）は本体に定義済み（AND 二重 opt-in の片側）。
#   - 外部 CLI: gh / jq。
#   - 関数 prefix `nda_` を namespace として採用する。
#
# セットアップ参照先:
#   README.md（「オプション機能（opt-in）」節 / `NEEDS_DECISIONS_MODE`） / install.sh（配置ロジック）
#   設計参照: docs/specs/362-feat-watcher-needs-decisions-needs-decis/design.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Logger Layer
#
# 既存 am_log / fr_log / mq_log と同じ `[YYYY-MM-DD HH:MM:SS] [$REPO] needs-decisions-auto:`
# 3 段 prefix。`nda_warn` / `nda_error` は `>&2` に出力（Req 6.1, 6.2, 6.3）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

nda_log() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: $*"
}

nda_warn() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: WARN: $*" >&2
}

nda_error() {
  echo "[$(date '+%F %T')] [$REPO] needs-decisions-auto: ERROR: $*" >&2
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Pure Function Layer
#
# 副作用なし（gh / git / file write を行わない）。本体 Config ブロックで
# `NEEDS_DECISIONS_MODE` は 3 値（all-human / classified / all-auto）に正規化済の
# 前提だが、`${NEEDS_DECISIONS_MODE:-all-human}` で fallback して外部から unset
# された状態でも安全側に倒す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# nda_resolve_mode_enabled: NEEDS_DECISIONS_MODE が `classified` / `all-auto` の場合 rc=0、
# `all-human` の場合 rc=1（本体 Config で正規化済前提 / Req 1.x）。
# 副作用なし（純粋関数）。
#
#   戻り値:
#     0 = mode in (classified, all-auto)（自動続行を評価可能）
#     1 = mode == all-human（自動続行しない / Req 5.1, 5.3）
nda_resolve_mode_enabled() {
  case "${NEEDS_DECISIONS_MODE:-all-human}" in
    classified|all-auto) return 0 ;;
    *)                   return 1 ;;
  esac
}

# nda_extract_classification: Triage JSON の decisions[].classification を fail-safe で抽出。
# `safe` 単独で全件揃った場合のみ "safe" を返し、それ以外（混在 / 欠落 / null /
# 空 / 空 decisions[] / jq 失敗 / file 不在 / 不明値）はすべて "human-only" を返す
# （Req 4.4 / 4.5 / NFR 4.2 hard safety boundary）。戻り値は常に 0、stdout で結果返却。
#
# jq logic:
#   1. decisions[].classification を rows として抽出
#   2. 1 件でも `human-only` が含まれる → "human-only"
#   3. 全件が `safe` で揃う → "safe"
#   4. 上記いずれにも該当しない（混在 / 欠落 / 不明値）→ "human-only"
#   5. jq 失敗 / file 不在 → "human-only"
#
#   入力: $1 = triage_json_path
#   stdout: "safe" | "human-only"
#   戻り値: 0（常）
nda_extract_classification() {
  local triage_json_path="$1"
  local result

  # file 不在は fail-safe に倒す
  if [ ! -f "$triage_json_path" ]; then
    echo "human-only"
    return 0
  fi

  # jq で classification 配列を抽出し、混在 / 欠落 / 不明値を "human-only" へ畳む。
  # decisions 配列が空 or null の場合は length=0 となり、`safe` 件数=0 / `human-only` 件数=0 で
  # else 分岐に落ちて "human-only" を返す（fail-safe）。
  result=$(jq -r '
    .decisions
    | if (. == null or (type != "array") or length == 0) then
        "human-only"
      else
        (map(.classification // "") ) as $tags
        | if ($tags | any(. == "human-only")) then
            "human-only"
          elif ($tags | all(. == "safe")) then
            "safe"
          else
            "human-only"
          end
      end
  ' "$triage_json_path" 2>/dev/null) || result=""

  case "$result" in
    safe)       echo "safe" ;;
    human-only) echo "human-only" ;;
    *)          echo "human-only" ;;
  esac
  return 0
}

# nda_extract_first_recommendation: Triage JSON の decisions[0].recommendation を抽出。
# 正常抽出時は stdout に本文を出力して rc=0、null / 空文字 / 抽出失敗 / file 不在は rc=1。
# Open Question (b) 解消: safe 判定の前提に recommendation 存在が含まれる
# （requirements.md Open Questions 節）。
#
#   入力: $1 = triage_json_path
#   stdout: decisions[0].recommendation 本文（rc=0 時のみ意味を持つ）
#   戻り値:
#     0 = 抽出成功（非空文字列）
#     1 = recommendation 欠落（null / 空文字 / decisions[] 空 / file 不在 / jq 失敗）
nda_extract_first_recommendation() {
  local triage_json_path="$1"
  local result

  if [ ! -f "$triage_json_path" ]; then
    return 1
  fi

  # jq で decisions[0].recommendation を抽出。decisions 不在 / 空 / null の場合は
  # `empty` で何も出力せず result が空となり、後段の空判定で rc=1 に倒す。
  result=$(jq -r '
    .decisions
    | if (. == null or (type != "array") or length == 0) then
        empty
      else
        (.[0].recommendation // empty)
      end
  ' "$triage_json_path" 2>/dev/null) || return 1

  # 抽出値が空文字列 / null 文字列の場合は rc=1
  if [ -z "$result" ] || [ "$result" = "null" ]; then
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Side-Effecting Layer
#
# gh CLI を介して Issue コメント投稿 / ラベル除去を行う。best-effort 方針
# （既存 mark_issue_needs_decisions / failed-recovery と同方針）で、失敗時は WARN
# ログ + return 1 を呼出側に伝える。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# nda_auto_continue: safe + AND 二重 opt-in pass 時の自動続行実行関数。
#
# 判定順序（Halt fallback 安全側 / design.md「Halt fallback の順序」節準拠）:
#   1. gh issue comment を **先に**実行（採用 recommendation + mode + classification +
#      監査用 fingerprint を含む本文）
#   2. **コメント投稿成功時のみ** gh issue edit --remove-label LABEL_CLAIMED を実行
#      （LABEL_NEEDS_DECISIONS は **付与しない**ことで「除去」を不要化 / Req 3.3）
#   3. コメント投稿失敗 → WARN + return 1（呼出側は既存 halt fallback に流す）
#   4. ラベル除去失敗 → WARN + return 1（best-effort fallback）
#   5. 全成功 → nda_log 1 行で action=auto-continue / mode / classification /
#      recommendation 先頭を記録、return 0
#
# これにより「コメント不在 + claude-claimed 除去済」というオーファン状態（次サイクルで
# 再 pickup されるが監査ログなし）を防ぐ。
#
#   入力:
#     $1 = triage_json_path（fingerprint 用に file basename を本文へ含める）
#     $2 = first_recommendation_body（本文用 / nda_extract_first_recommendation の出力）
#   戻り値:
#     0 = 自動続行成功（comment + label remove 双方 ok）
#     1 = best-effort 失敗（呼出側は halt fallback / Open Question (c)）
#   副作用:
#     - gh issue comment 1 件（採用 recommendation + mode + classification + fingerprint）
#     - gh issue edit --remove-label LABEL_CLAIMED（成功時のみ）
#     - nda_log / nda_warn 1 行
nda_auto_continue() {
  local triage_json_path="$1"
  local first_recommendation_body="$2"

  local mode="${NEEDS_DECISIONS_MODE:-all-human}"
  local classification="safe"
  local fingerprint
  fingerprint=$(basename -- "$triage_json_path")

  # 監査用 Issue コメント本文（運用者が事後追跡できるよう、採用根拠を機械可読+人間可読で記録）。
  # gh issue comment --body にはそのまま引数渡し（bash -c / eval には流さない / NFR 4.1）。
  local body
  body=$(cat <<EOF
## needs-decisions auto-continue

watcher が \`needs-decisions\` 状態の本 Issue を **PM の第一推奨**で自動続行しました。
本コメントは運用監査用の自動投稿です。

- **mode**: \`${mode}\`
- **classification**: \`${classification}\`
- **fingerprint (triage)**: \`${fingerprint}\`

### 採用 recommendation（PM 第一推奨）

${first_recommendation_body}

---

自動続行を停止したい場合は \`NEEDS_DECISIONS_MODE=all-human\` または
\`FULL_AUTO_ENABLED=false\` を watcher の env で設定してください
（cron 次サイクル以降に反映）。
EOF
)

  # 1. コメント投稿を **先に**試行（best-effort）
  if ! gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    nda_warn "issue=#${NUMBER} action=auto-continue gh-comment-failed; halt fallback"
    return 1
  fi

  # 2. コメント投稿成功時のみ claude-claimed を除去（best-effort）
  if ! gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
    nda_warn "issue=#${NUMBER} action=auto-continue gh-edit-failed; comment posted but label not removed"
    return 1
  fi

  # 3. 成功ログ（recommendation 本文は先頭 80 文字を観測用に含める / 長文 inline 展開回避）
  local recommendation_head
  recommendation_head=$(printf '%s' "$first_recommendation_body" | head -c 80 | tr '\n' ' ')
  nda_log "issue=#${NUMBER} mode=${mode} classification=${classification} action=auto-continue recommendation=\"${recommendation_head}\""

  # Issue #370 task 6: Slack 通知 emitter（fail-open / gate OFF 時は no-op）。
  # recommendation 本文は detail に含めない（NFR 3.3: secret 候補値を含む可能性 + 80 文字
  # 制限でも長すぎるため）。mode と classification の運用メタデータのみを detail に渡す。
  sn_notify needs-decisions-auto-continue "$NUMBER" "https://github.com/$REPO/issues/$NUMBER" auto-continued "mode=${mode} classification=${classification}" || true

  return 0
}

# nda_evaluate_auto_continue: 判定エントリ（AND 二重 opt-in / 判定順序）。
#
# 判定順序（design.md「Service Interface」節準拠 / Req 4.x / 5.x / NFR 4.2）:
#   1. full_auto_enabled が false → halt（log: suppressed by FULL_AUTO_ENABLED / Req 5.2, 6.2）
#   2. nda_resolve_mode_enabled が false（mode=all-human）→ halt（log: mode=all-human / Req 5.3, 6.1）
#   3. nda_extract_classification が "human-only" → halt（log: classification=human-only /
#      Req 4.1〜4.5 / 6.3）
#   4. nda_extract_first_recommendation が rc=1 → halt（log: recommendation=missing /
#      Open Question (b)）
#   5. 上記すべて pass → nda_auto_continue を call し、成功時 rc=0 を返す
#      （log: action=auto-continue / Req 3.1, 3.2, 6.1）
#
#   入力: $1 = triage_json_path（環境変数 NUMBER / REPO / LABEL_CLAIMED 経由で他コンテキスト取得）
#   戻り値:
#     0 = auto-continue 実行済（呼出側は既存 needs-decisions halt フロー全体を skip して return 0）
#     1 = halt（呼出側は既存 needs-decisions コメント投稿 + ラベル付け替えフローへ続行）
#   副作用:
#     - 0 を返す場合: nda_auto_continue 経由の gh comment + gh edit + nda_log 1 行
#     - 1 を返す場合: 副作用なし（呼出側既存フローに任せる） + nda_log 1 行（halt 原因明記）
nda_evaluate_auto_continue() {
  local triage_json_path="$1"
  local mode="${NEEDS_DECISIONS_MODE:-all-human}"
  local classification
  local recommendation

  # 1. kill switch 評価（Req 5.2 / 6.2）
  if ! full_auto_enabled; then
    nda_log "issue=#${NUMBER} action=halt cause=suppressed-by-FULL_AUTO_ENABLED"
    return 1
  fi

  # 2. mode 評価（Req 5.1 / 5.3 / 6.1）
  if ! nda_resolve_mode_enabled; then
    nda_log "issue=#${NUMBER} mode=${mode} action=halt cause=mode-all-human"
    return 1
  fi

  # 3. classification 評価（Req 4.1〜4.5 / 6.3 / NFR 4.2 hard safety boundary）
  classification=$(nda_extract_classification "$triage_json_path")
  if [ "$classification" = "human-only" ]; then
    nda_log "issue=#${NUMBER} mode=${mode} classification=human-only action=halt cause=classification-human-only"
    return 1
  fi

  # 4. recommendation 評価（Open Question (b) 解消）
  if ! recommendation=$(nda_extract_first_recommendation "$triage_json_path"); then
    nda_log "issue=#${NUMBER} mode=${mode} classification=${classification} action=halt cause=recommendation-missing"
    return 1
  fi

  # 5. 全 pass → 自動続行（成功時のみ rc=0、失敗時は nda_auto_continue 側で WARN 出力済）
  if nda_auto_continue "$triage_json_path" "$recommendation"; then
    return 0
  fi
  return 1
}
