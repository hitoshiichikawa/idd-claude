#!/usr/bin/env bash
# shellcheck shell=bash
# token-usage.sh — watcher の Token Usage Report モジュール (#325)
#
# 用途:
#   `qa_run_claude_stage` がラップする claude 実行（stream-json）の最終 `result`
#   イベントから usage（input / output / cache トークン数）・num_turns・total_cost_usd
#   を抽出し、stage 単位の `token-usage:` 1 行を $LOG へ追記する。Issue 処理の終端
#   （_slot_run_issue の EXIT trap、rs_emit と同経路）では $LOG 中の stage 行を集計した
#   Issue 単位サマリ 1 行を出力する。モデル選定・固定オーバーヘッド削減等の
#   トークン消費最適化を実測で比較するための observability 機能（run-summary #239 と同型）。
#
#   - tu_enabled                  : TOKEN_REPORT_ENABLED の正規化判定（false/0/no/off で無効）
#   - tu_mark_log_offset          : 実行前の $LOG 行数を記録（直前 stage の result 誤集計防止）
#   - tu_extract_last_result_json : $LOG の offset 以降から最後の有効な result イベントを抽出
#   - tu_format_usage_kv          : result JSON → `in=.. cache_read=.. ...` の k=v 列へ整形（純粋関数）
#   - tu_report_stage_usage       : stage 完了時に token-usage 行を 1 行 echo（fail-open）
#   - tu_emit_issue_summary       : $LOG の stage 行を集計しサマリ 1 行を echo（EXIT trap から呼ぶ）
#
# 設計方針:
#   - 出力は追記のみ。claude exit code / 99 sentinel / ラベル遷移 / 既存ログ行に影響しない
#     （fail-open。抽出・整形の失敗はすべて握り潰して return 0）。
#   - 値は ASCII・空白なし（grep / awk 抽出の robustness。run-summary と同方針）。
#   - 呼び出し側（quota-aware.sh）は `declare -F` ガード経由で呼ぶため、本モジュール未ロード
#     環境（extract_function 隔離抽出テスト等）でも Stage Wrapper は従来挙動で完走する。
#
# 配置先:
#   $HOME/bin/modules/token-usage.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - グローバル変数 $LOG / $REPO / $NUMBER は本体側で定義される前提（遅延束縛）。
#     未定義でも ${VAR:-default} で防御する。
#   - 外部 CLI: date / grep / tail / wc / awk / jq（既存依存のみ。新規外部サービス呼び出しなし）。
#   - 環境変数 TOKEN_REPORT_ENABLED（既定 true / lowercase の false・0・no・off のいずれかで
#     無効化）は各出力関数の呼び出し時に評価する（RUN_SUMMARY_ENABLED と同じ正規化規則）。
#
# セットアップ参照先:
#   - 要件: docs/specs/325-watcher-token-usage-report/requirements.md
#   - README: 「token-usage: 行（Token Usage Report, #325）」節

# ─── tu_enabled ───
#
# TOKEN_REPORT_ENABLED の正規化判定（Req 3.1, 3.2）。
# lowercase の false / 0 / no / off のみ無効。それ以外（未設定・空文字・typo）は有効。
# Return: 0 = 有効, 1 = 無効
tu_enabled() {
  case "${TOKEN_REPORT_ENABLED:-true}" in
    false|0|no|off) return 1 ;;
  esac
  return 0
}

# ─── tu_mark_log_offset ───
#
# 現在の $LOG 行数を stdout に返す（Req 1.4）。stage 実行前に呼び、実行後の抽出を
# この offset 以降に限定することで、直前 stage の result 行を誤集計しない。
# $LOG 未定義・不在時は 0。
# Stdout: 行数（integer） / Return: 0 always
tu_mark_log_offset() {
  if [ -n "${LOG:-}" ] && [ -f "${LOG:-}" ]; then
    wc -l < "$LOG" | tr -d '[:space:]'
  else
    echo 0
  fi
  return 0
}

# ─── tu_extract_last_result_json <logfile> [offset] ───
#
# logfile の offset 行目以降から、最後の有効な `result` イベント JSON（1 行）を抽出する
# （Req 1.3, 1.4）。非 JSON 行・`"type":"result"` を含むだけの偽陽性行は jq 側の
# `try fromjson` + `select` で除外する。該当なしは空出力。
# Stdout: result イベント JSON（compact 1 行）または空 / Return: 0 always
tu_extract_last_result_json() {
  local logfile="${1:-}"
  local offset="${2:-0}"
  [ -n "$logfile" ] && [ -f "$logfile" ] || return 0
  case "$offset" in
    ''|*[!0-9]*) offset=0 ;;
  esac
  {
    tail -n "+$((offset + 1))" "$logfile" 2>/dev/null \
      | grep -a '"type":"result"' 2>/dev/null \
      | jq -c -R 'try fromjson catch empty | select(type == "object" and .type? == "result")' 2>/dev/null \
      | tail -1
  } || true
  return 0
}

# ─── tu_format_usage_kv <result_json> ───
#
# result イベント JSON から k=v 列を整形する純粋関数（Req 1.1, 1.5）。
# 欠落フィールドは 0（models は "-"）で補完。不正 JSON は空出力（呼び出し側で skip）。
# Stdout: `in=<n> cache_read=<n> cache_write=<n> out=<n> turns=<n> cost_usd=<x> models=<ids>` または空
# Return: 0 always
tu_format_usage_kv() {
  local result_json="${1:-}"
  [ -n "$result_json" ] || return 0
  {
    printf '%s' "$result_json" | jq -r '
      [
        "in=\(.usage.input_tokens // 0)",
        "cache_read=\(.usage.cache_read_input_tokens // 0)",
        "cache_write=\(.usage.cache_creation_input_tokens // 0)",
        "out=\(.usage.output_tokens // 0)",
        "turns=\(.num_turns // 0)",
        "cost_usd=\(.total_cost_usd // 0)",
        "models=\((.modelUsage // {}) | keys | join(",") | if . == "" then "-" else . end)"
      ] | join(" ")
    ' 2>/dev/null
  } || true
  return 0
}

# ─── tu_report_stage_usage <stage_label> [offset] ───
#
# stage 完了時に token-usage 行を 1 行 stdout へ echo する（Req 1.1〜1.5 / NFR 1.2）。
# 呼び出し元（qa_run_claude_stage の call site）は stdout を $LOG へ redirect している
# 前提のため、本行は $LOG に追記される。result 行不在 / 抽出失敗 / 無効化時は何も出力しない。
# Args: $1 = stage label（空白なし）, $2 = 実行前の $LOG 行数 offset（省略時 0）
# Return: 0 always
tu_report_stage_usage() {
  tu_enabled || return 0
  local stage_label="${1:-unknown}"
  local offset="${2:-0}"
  [ -n "${LOG:-}" ] && [ -f "${LOG:-}" ] || return 0
  local result_json kv
  result_json=$(tu_extract_last_result_json "$LOG" "$offset")
  [ -n "$result_json" ] || return 0
  kv=$(tu_format_usage_kv "$result_json")
  [ -n "$kv" ] || return 0
  echo "[$(date '+%F %T')] [${REPO:-?}] token-usage: stage=${stage_label} ${kv}"
  return 0
}

# ─── tu_emit_issue_summary ───
#
# $LOG 中の全 `token-usage: stage=` 行を集計し、Issue 単位サマリ 1 行を stdout へ echo する
# （Req 2.1〜2.3）。_slot_run_issue の EXIT trap（rs_emit と同経路）から呼ばれる前提。
# trap 時点の stdout は slot tee（SLOT_LOG + cron stdout）に向いているため、サマリは
# cron.log からも grep できる。stage 行ゼロ / 無効化時は何も出力しない。
# Return: 0 always
tu_emit_issue_summary() {
  tu_enabled || return 0
  [ -n "${LOG:-}" ] && [ -f "${LOG:-}" ] || return 0
  local lines
  lines=$(grep -a "token-usage: stage=" "$LOG" 2>/dev/null || true)
  [ -n "$lines" ] || return 0
  local summary
  summary=$(printf '%s\n' "$lines" | awk '
    {
      for (i = 1; i <= NF; i++) {
        n = split($i, kv, "=")
        if (n < 2) continue
        if (kv[1] == "in") tin += kv[2]
        else if (kv[1] == "cache_read") tcr += kv[2]
        else if (kv[1] == "cache_write") tcw += kv[2]
        else if (kv[1] == "out") tout += kv[2]
        else if (kv[1] == "turns") tturns += kv[2]
        else if (kv[1] == "cost_usd") tcost += kv[2]
      }
      cnt++
    }
    END {
      printf "in=%d cache_read=%d cache_write=%d out=%d turns=%d cost_usd=%.4f stages=%d", tin, tcr, tcw, tout, tturns, tcost, cnt
    }
  ' 2>/dev/null) || true
  [ -n "$summary" ] || return 0
  echo "[$(date '+%F %T')] [${REPO:-?}] token-usage: issue=#${NUMBER:-?} total ${summary}"
  return 0
}
