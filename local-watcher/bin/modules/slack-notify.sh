#!/usr/bin/env bash
# slack-notify.sh — watcher 重要イベントの Slack 通知 emitter モジュール（#370）
#
# 用途:
#   自動 merge / failed-recovery 終端 / needs-decisions 自動続行 / promote 完了といった
#   **人間が能動的に把握すべき重要イベント**を、Slack Incoming Webhook 経由で push 通知する
#   補助的な観測チャネル（D-18 / 低優先）。callsite 側は `sn_notify` を 1 行呼ぶだけで
#   gate 評価・payload 構築・HTTP POST・ログ出力・失敗ハンドリングを本 module 内に閉じて実行する。
#
#   主な関数:
#     - sn_log / sn_warn / sn_error : 3 段 prefix ロガー
#     - sn_is_enabled               : SLACK_NOTIFY_ENABLED 厳密一致 gate
#     - sn_scrub_secrets            : detail 文字列から secret 候補値を [REDACTED] に置換
#     - sn_build_payload            : event_type / repo / number / url / result から JSON 構築
#     - sn_post_webhook             : curl 経由で Slack Incoming Webhook へ POST
#     - sn_notify                   : callsite 側が呼ぶ唯一の public entry point
#
#   評価順序（sn_notify）:
#     1. sn_is_enabled rc=1 → silent return 0（gate OFF / Req 1.5 / 5.2 / NFR 2.1）
#     2. SLACK_WEBHOOK_URL 未設定 / 空 → sn_warn + return 0（Req 1.4 / 5.3）
#     3. number / event_type 引数検証 → 失敗で sn_warn + return 0（NFR 3.2）
#     4. sn_build_payload → rc=1 で sn_warn + return 0（Req 4.3）
#     5. sn_post_webhook → 失敗 (rc=1/2) で sn_warn + return 0（Req 4.1 / 4.2 / 5.4）
#     6. 成功時 sn_log で構造化 1 行（Req 5.1 / NFR 5.1）
#
# 配置先:
#   $HOME/bin/modules/slack-notify.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $SLACK_NOTIFY_ENABLED / $SLACK_WEBHOOK_URL / $SLACK_NOTIFY_TIMEOUT）
#     は本体冒頭の Config ブロックで定義済み。
#   - 外部 CLI: curl / jq（NFR 2.3 で新規 CLI 依存を増やさない）。
#
# セットアップ参照先:
#   README.md（「オプション機能一覧」節 / `SLACK_NOTIFY_ENABLED`）/ docs/specs/370-feat-watcher-slack-d-18/

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ロガー（既存 fr_log / am_log / sec_log と同形式の 3 段 prefix）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Req 5.5 / NFR 3.4: webhook URL 全体は引数として渡されない / 渡されても出力しない。
# 呼出側でホスト部のみまたはマスキング済み prefix を渡す契約。
sn_log() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: $*"
}
sn_warn() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: WARN: $*" >&2
}
sn_error() {
  echo "[$(date '+%F %T')] [$REPO] slack-notify: ERROR: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_is_enabled: SLACK_NOTIFY_ENABLED env 値を `=true` 厳密一致で判定（Req 1.1〜1.3）
#
#   `=true` の **lowercase 厳密一致**のみ rc=0、それ以外（未設定 / 空 / `True` / `TRUE` /
#   `1` / `on` / `yes` / typo / 前後空白）はすべて rc=1（安全側）。
#
#   戻り値: 0 = ON / 1 = OFF
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
sn_is_enabled() {
  case "${SLACK_NOTIFY_ENABLED:-false}" in
    true) return 0 ;;
    *)    return 1 ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_scrub_secrets: detail 文字列から secret 候補値を [REDACTED] に置換（NFR 3.3）
#
#   検出パターン:
#     - GitHub token prefix: `ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` 始まり 36 文字以上
#     - Slack webhook URL: `hooks.slack.com/services/` で始まる URL 様トークン
#     - 32 桁以上の連続英数字（best-effort、過剰検出は許容）
#
#   入力: $1 = 任意文字列（detail / extra context 等）
#   出力: stdout に置換後の文字列を 1 行
#   副作用: なし（純粋関数）
# ─────────────────────────────────────────────────────────────────────────────
sn_scrub_secrets() {
  local input="${1:-}"
  # 1) GitHub token prefix（lowercase, 5 種 × 36 文字以上）
  #    sed の ERE では `+` を使えるため `\{36,\}` を `{36,}` で表現。
  input=$(printf '%s' "$input" | sed -E 's/gh[pousr]_[A-Za-z0-9]{36,}/[REDACTED]/g')
  # 2) Slack webhook URL（host + services path 以降を一括 redact）
  input=$(printf '%s' "$input" | sed -E 's#https?://hooks\.slack\.com/services/[A-Za-z0-9/_-]+#[REDACTED]#g')
  # 3) 32 桁以上の連続英数字（best-effort。すでに置換済みの [REDACTED] は英字 8 + 記号で再マッチしない）
  input=$(printf '%s' "$input" | sed -E 's/[A-Za-z0-9]{32,}/[REDACTED]/g')
  printf '%s' "$input"
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_build_payload: Slack Incoming Webhook 用 JSON payload を構築（Req 3.1〜3.6 / NFR 3.2）
#
#   Args:
#     $1 event_type : "auto-merge" | "auto-merge-design" |
#                     "auto-merge-merged" | "auto-merge-design-merged" |
#                     "failed-recovery" | "needs-decisions-auto-continue" | "promote"
#     $2 number     : Issue / PR 番号（数値 / promote は sentinel "0" 許容）
#     $3 url        : GitHub URL（呼出側で組み立て済）
#     $4 result     : "armed" | "merged" | "recovered" | "max-attempts" |
#                     "no-progress" | "auto-continued" | "promote-success" |
#                     "success"（後方互換のため温存。新規 callsite は使わない）
#     $5 detail     : 任意の追加文脈（secret scrub 対象）
#
#   Issue #388 (本 PR):
#     - armed/merged を判別可能にするため event_type に `auto-merge-merged` /
#       `auto-merge-design-merged` を追加（Req 2.1, 2.2, 3.5）
#     - 旧 callsite（armed 通知）は result=success から result=armed に切り替えるが、
#       enum 上は `success` を温存し旧ログ・旧 callsite を破壊しない（Req 3.5 / NFR 1.1）
#
#   Stdout: JSON 1 行（rc=0 時のみ）
#   Returns: 0 = success / 1 = 引数 enum / 数値 / jq 失敗
# ─────────────────────────────────────────────────────────────────────────────
sn_build_payload() {
  local event_type="${1:-}"
  local number="${2:-}"
  local url="${3:-}"
  local result="${4:-}"
  local detail="${5:-}"

  # event_type の enum 検証
  # Issue #388: `auto-merge-merged` / `auto-merge-design-merged` を追加（Req 2.1, 2.2）
  case "$event_type" in
    auto-merge|auto-merge-design|auto-merge-merged|auto-merge-design-merged|failed-recovery|needs-decisions-auto-continue|promote) : ;;
    *)
      sn_warn "sn_build_payload: 不正な event_type=$(printf '%s' "$event_type" | tr -cd '[:alnum:]_-' | head -c 32)"
      return 1
      ;;
  esac

  # number の ^[0-9]+$ 検証（promote の sentinel `0` も許容される）
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    sn_warn "sn_build_payload: number が数値ではない number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # detail を secret scrub（NFR 3.3）
  local scrubbed_detail
  scrubbed_detail=$(sn_scrub_secrets "$detail")

  # payload 本文の section text（Slack Block Kit mrkdwn）
  # \n はリテラルではなく改行として埋め込む（jq --arg で sanitize されるため安全）
  local section_text
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートは Slack mrkdwn コードフェンスのリテラル
  section_text=$(printf '*[idd-claude]* `%s` on `%s`\n• Issue/PR: <%s|#%s>\n• Result: `%s`\n• Detail: `%s`' \
      "$event_type" "${REPO:-unknown}" "$url" "$number" "$result" "$scrubbed_detail")

  # text フィールド（通知本文 / フォールバック）
  local text
  text=$(printf '[idd-claude] %s on %s #%s: %s' \
      "$event_type" "${REPO:-unknown}" "$number" "$result")

  # jq --arg ですべての未信頼値を sanitize（NFR 3.2）
  local payload
  if ! payload=$(jq -n -c \
      --arg text "$text" \
      --arg section "$section_text" \
      '{
        text: $text,
        blocks: [
          {
            type: "section",
            text: { type: "mrkdwn", text: $section }
          }
        ]
      }' 2>/dev/null); then
    sn_warn "sn_build_payload: jq による payload 整形に失敗"
    return 1
  fi

  printf '%s\n' "$payload"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_post_webhook: curl 経由で Slack Incoming Webhook に POST（Req 4.1 / 4.2 / 4.5 / NFR 2.2）
#
#   Args:
#     $1 payload : JSON 1 行（sn_build_payload の出力）
#
#   Stdout: HTTP status code を 1 行（呼出側 sn_log で使う）
#   Returns:
#     0 = HTTP 2xx
#     1 = HTTP 4xx/5xx（curl は成功）
#     2 = curl 非ゼロ exit（タイムアウト / 接続失敗 等）
#
#   実装メモ:
#     - `-d @-` で payload を stdin から渡す（process listing からの漏洩防止 / NFR 3.3 副次）
#     - `--max-time` で有限 timeout を強制（Req 4.5 / NFR 2.2）。非数値 / 負数は呼出側で
#       既定 5 秒に正規化済みの前提
#     - URL は `--` 後の最後の引数として渡す（defense-in-depth / CLAUDE.md §5）
# ─────────────────────────────────────────────────────────────────────────────
sn_post_webhook() {
  local payload="$1"

  # timeout 値の正規化（非数値 / 負数 / 空 → 既定 5）。WARN は本体側で 1 度だけ出すため
  # ここでは黙って正規化する。
  local timeout="${SLACK_NOTIFY_TIMEOUT:-5}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
    timeout=5
  fi

  local http_status
  local curl_rc=0
  # `-w '%{http_code}'` で末尾に HTTP status code を出力させ、本体出力は破棄
  http_status=$(printf '%s' "$payload" \
    | curl --silent --show-error \
        --max-time "$timeout" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d @- \
        -o /dev/null \
        -w '%{http_code}' \
        -- "$SLACK_WEBHOOK_URL" 2>/dev/null) || curl_rc=$?

  if [ "$curl_rc" -ne 0 ]; then
    # network / transport error（タイムアウト / 接続失敗 等）
    sn_warn "sn_post_webhook: transport-error curl_exit=${curl_rc} host=hooks.slack.com"
    printf '%s' "${http_status:-000}"
    return 2
  fi

  # HTTP status 解釈
  case "$http_status" in
    2*)
      printf '%s' "$http_status"
      return 0
      ;;
    4*)
      sn_warn "sn_post_webhook: http-4xx status=${http_status} host=hooks.slack.com"
      printf '%s' "$http_status"
      return 1
      ;;
    5*)
      sn_warn "sn_post_webhook: http-5xx status=${http_status} host=hooks.slack.com"
      printf '%s' "$http_status"
      return 1
      ;;
    *)
      # curl=0 だが非数値 / 想定外 status
      sn_warn "sn_post_webhook: unexpected-status status=$(printf '%s' "$http_status" | tr -cd '[:alnum:]_-' | head -c 16) host=hooks.slack.com"
      printf '%s' "${http_status:-000}"
      return 1
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# sn_notify: callsite 側が呼ぶ唯一の public entry point（Req 1.4 / 2.1〜2.6 / 4.4）
#
#   Args:
#     $1 event_type : enum（sn_build_payload と同じ 5 値）
#     $2 number     : Issue / PR 番号
#     $3 url        : GitHub URL
#     $4 result     : enum
#     $5 detail     : 任意（head_ref / branch / attempts 等の短い既知メタデータ）
#
#   Returns: 常に 0（fail-open / Req 4.4）
#   副作用: sn_log / sn_warn 1 行 + curl 1 回（gate ON + URL 設定済 + 検証 pass 時のみ）
# ─────────────────────────────────────────────────────────────────────────────
sn_notify() {
  # 1. gate 評価（silent / Req 1.5 / 5.2 / NFR 2.1）
  if ! sn_is_enabled; then
    return 0
  fi

  # 2. URL preflight（Req 1.4 / 5.3）
  if [ -z "${SLACK_WEBHOOK_URL:-}" ]; then
    sn_warn "reason=url-unset SLACK_NOTIFY_ENABLED=true だが SLACK_WEBHOOK_URL 未設定のため通知を skip"
    return 0
  fi

  local event_type="${1:-}"
  local number="${2:-}"
  local url="${3:-}"
  local result="${4:-}"
  local detail="${5:-}"

  # 3. timeout 非数値 / 負数の WARN（実害は出ないが運用者に正規化を通知）
  local timeout="${SLACK_NOTIFY_TIMEOUT:-5}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
    sn_warn "reason=timeout-invalid SLACK_NOTIFY_TIMEOUT=$(printf '%s' "${SLACK_NOTIFY_TIMEOUT:-}" | tr -cd '[:alnum:]._-' | head -c 16) を既定 5 秒に正規化"
  fi

  # 4. payload 構築（jq 失敗 → fail-open）
  local payload
  if ! payload=$(sn_build_payload "$event_type" "$number" "$url" "$result" "$detail"); then
    # sn_build_payload 内で sn_warn 済（reason=invalid-args / payload-build-failed）
    return 0
  fi

  # 5. HTTP POST（失敗時 sn_post_webhook 内で sn_warn 済）
  local http_status
  local post_rc=0
  http_status=$(sn_post_webhook "$payload") || post_rc=$?

  if [ "$post_rc" -eq 0 ]; then
    # 6. 成功時 構造化 1 行（Req 5.1 / NFR 5.1）
    sn_log "event=${event_type} number=${number} result=${result} http_status=${http_status} host=hooks.slack.com"
  fi

  # fail-open: post 失敗でも常に rc=0（Req 4.4）
  return 0
}
