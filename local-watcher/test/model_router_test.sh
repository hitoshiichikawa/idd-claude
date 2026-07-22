#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/model-router.sh（#507 モデルルーティング Phase 1）の
#       近接テスト。Triage の complexity 解釈と size ラベル永続化を fixture / gh stub で
#       検証する。
#
#       対象関数:
#         - mr_is_enabled              (Req 3.1 / 3.2 / 3.3)
#         - mr_parse_triage_complexity (Req 2.3 / 2.4 / 5.1 / 5.2 / NFR 4.1)
#         - mr_has_size_label          (Req 4.2 / 4.3 / 5.4 / NFR 4.2)
#         - mr_persist_size_label      (Req 3.4 / 4.1〜4.4 / 4.7 / 5.1〜5.6 / NFR 2.1 / 2.2 / 3.1 / 3.2)
#
#       検証する AC（docs/specs/507-feat-watcher-triage-complexity-size-phas/requirements.md）:
#         Req 8.4 が要求する 5 ケース（許可値 3 種の正常付与 / complexity 欠落 / 不正値 /
#         既存 size:* ラベルあり / gate 無効）を Integration I1〜I5 で網羅し、
#         I6（labels 取得失敗 / 付与失敗）と I7（gh 呼び出し回数 2 回以下）を追加する。
#
#       既存テスト（po_apply_awaiting_slot_test.sh 等）と同じ awk extract_function
#       イディオムを踏襲し、gh / mr_log / mr_warn を stub して呼び出しトレースを観測する。
#
# 配置先: local-watcher/test/model_router_test.sh
# 依存:   bash 4+, awk, jq
# 実行:   bash local-watcher/test/model_router_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# extract_function / assert_eq / assert_contains / assert_rc を共有ライブラリから source（#474）。
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

MODEL_ROUTER_SH="$SCRIPT_DIR/../bin/modules/model-router.sh"
WATCHER_CONFIG_SH="$SCRIPT_DIR/../bin/watcher-config.sh"
ISSUE_WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"
SLOT_WORKER_SH="$SCRIPT_DIR/../bin/modules/slot-worker.sh"

if [ ! -f "$MODEL_ROUTER_SH" ]; then
  echo "ERROR: cannot find model-router.sh at $MODEL_ROUTER_SH" >&2
  exit 2
fi

# 対象関数を実物から隔離抽出する（トップレベル副作用は回避）。
# extract_function は単一関数のみを切り出すため、mr_persist_size_label が呼ぶ
# 依存関数（mr_is_enabled / mr_has_size_label）も明示的に読み込む。
for _fn in mr_is_enabled mr_parse_triage_complexity mr_has_size_label mr_persist_size_label; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODEL_ROUTER_SH" "$_fn")"
  if ! declare -F "$_fn" >/dev/null; then
    echo "ERROR: $_fn not loaded" >&2
    exit 2
  fi
done
unset _fn

# グローバル env（遅延束縛で抽出した関数本体から参照される）
# shellcheck disable=SC2034  # 抽出した mr_persist_size_label 本体が遅延束縛で参照
REPO="owner/test-repo"

PASS_COUNT=0
FAIL_COUNT=0

# ─── stub の状態 ───
#   GH_VIEW_RC          : `gh issue view --json labels` の終了コード
#   GH_VIEW_LABELS_JSON : `gh issue view --json labels` が返す JSON
#   GH_EDIT_RC          : `gh issue edit --add-label` の終了コード
# 記録ファイル:
#   $GH_CALL_LOG : gh の各呼び出しを 1 行ずつ記録
#   $LOG_LOG     : mr_log の出力を記録
#   $WARN_LOG    : mr_warn の出力を記録
reset_stub_state() {
  GH_VIEW_RC="${1:-0}"
  GH_VIEW_LABELS_JSON="${2:-'{"labels": []}'}"
  GH_EDIT_RC="${3:-0}"
  GH_CALL_LOG="$(mktemp)"
  LOG_LOG="$(mktemp)"
  WARN_LOG="$(mktemp)"
}

cleanup_stub_state() {
  rm -f "$GH_CALL_LOG" "$LOG_LOG" "$WARN_LOG"
}

# stub は extract_function で読み込んだ対象関数から間接的に呼ばれるため SC2317 を抑止する。
# shellcheck disable=SC2317
mr_log()  { echo "$*" >>"$LOG_LOG"; }
# shellcheck disable=SC2317
mr_warn() { echo "$*" >>"$WARN_LOG"; }

# `gh issue edit` の引数列を **cobra/pflag と同じ規則** で解釈し、解決後の
# `--add-label` 値と positional 引数の個数を記録する（#507 の実機不具合を再発防止する要）。
#
# pflag の規則（実機 gh 2.96.0 で確認）:
#   - 値を取るフラグ（`--repo` / `--add-label` 等）は **直後の引数を無条件に値として消費**する。
#     したがって `--add-label -- "size:small"` と書くと `--` が値として消費され、
#     `size:small` が 2 つ目の positional として残り `invalid issue format` で失敗する
#   - `--flag=value` の `=` 束縛形は値をフラグへ構文的に束縛する
#
# 生の引数文字列だけを突き合わせる旧アサーションでは上記を検出できなかったため、
# 「解決後のラベル値」と「positional 個数」を観測する方式に強化した。
# 記録形式: `GH-PARSED-EDIT add_label=<解決値> positionals=<個数>`
# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
_stub_parse_gh_issue_edit() {
  local add_label="" end_of_flags=0
  local -a positionals=()
  while [ "$#" -gt 0 ]; do
    if [ "$end_of_flags" -eq 0 ]; then
      case "$1" in
        --)
          end_of_flags=1
          shift
          continue
          ;;
        --add-label=*)
          add_label="${1#--add-label=}"
          shift
          continue
          ;;
        --repo=*|--remove-label=*)
          shift
          continue
          ;;
        --add-label)
          # pflag: 直後の引数を無条件に値として消費する（`--` であっても値になる）
          shift
          add_label="${1:-}"
          shift
          continue
          ;;
        --repo|--remove-label)
          shift
          shift
          continue
          ;;
        -*)
          shift
          continue
          ;;
      esac
    fi
    positionals+=("$1")
    shift
  done
  echo "GH-PARSED-EDIT add_label=${add_label} positionals=${#positionals[@]}"
}

# shellcheck disable=SC2317  # 対象関数から間接的に呼ばれる stub
gh() {
  local sub="${1:-}"
  local sub2="${2:-}"
  case "$sub" in
    issue)
      case "$sub2" in
        view)
          echo "gh issue view $*" >>"$GH_CALL_LOG"
          if [ "${GH_VIEW_RC:-0}" -ne 0 ]; then
            return "${GH_VIEW_RC}"
          fi
          printf '%s' "${GH_VIEW_LABELS_JSON}"
          return 0
          ;;
        edit)
          echo "gh issue edit $*" >>"$GH_CALL_LOG"
          shift 2
          _stub_parse_gh_issue_edit "$@" >>"$GH_CALL_LOG"
          return "${GH_EDIT_RC:-0}"
          ;;
        *)
          echo "gh issue $* (unhandled)" >>"$GH_CALL_LOG"
          return 0
          ;;
      esac
      ;;
    *)
      echo "gh $* (unhandled)" >>"$GH_CALL_LOG"
      return 0
      ;;
  esac
}

count_calls() {
  local pattern="$1"
  local n
  # grep -c は no-match 時に exit 1 を返し set -e / pipefail と衝突するため、
  # マッチ行を grep で取り出し（no-match でも true 化）wc -l で件数を数える。
  n=$( { grep "$pattern" "$GH_CALL_LOG" 2>/dev/null || true; } | wc -l)
  echo "$((n))"
}

# Triage 結果 JSON の fixture を一時ファイルへ書き出してパス名を返す。
write_triage_fixture() {
  local content="$1"
  local f
  f="$(mktemp)"
  printf '%s' "$content" >"$f"
  echo "$f"
}

# ════════════════════════════════════════════════════════════════════
# Unit 1〜4: mr_parse_triage_complexity（Req 2.3 / 2.4 / 5.1 / 5.2 / NFR 4.1）
# ════════════════════════════════════════════════════════════════════
echo "--- Unit: mr_parse_triage_complexity ---"

# Unit 1: 許可値 3 種がそのまま返る（Req 1.1 の 3 値を watcher 側が解釈できること）
for c in small medium large; do
  f=$(write_triage_fixture "{\"status\":\"ready\",\"complexity\":\"${c}\",\"complexity_reason\":\"根拠\"}")
  assert_eq "Unit 1: 許可値 '${c}' はそのまま返る" "$c" "$(mr_parse_triage_complexity "$f")"
  rm -f "$f"
done

# Unit 2: key 欠落 / null / 数値 / 配列 / object → 空文字（Req 2.3 / 5.1）
f=$(write_triage_fixture '{"status":"ready","needs_architect":false,"edit_paths":[]}')
assert_eq "Unit 2: complexity key 欠落（旧テンプレート由来）は空文字（Req 2.3）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":null}')
assert_eq "Unit 2: complexity=null は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":3}')
assert_eq "Unit 2: complexity=数値は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":["small"]}')
assert_eq "Unit 2: complexity=配列は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":{"value":"small"}}')
assert_eq "Unit 2: complexity=object は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":true}')
assert_eq "Unit 2: complexity=真偽値は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

# Unit 3: 不正値（許可値外 / 大文字 / 前後空白 / 注入狙い）→ 空文字（Req 5.2 / NFR 4.1）
f=$(write_triage_fixture '{"complexity":"huge"}')
assert_eq "Unit 3: 許可値外 'huge' は空文字（Req 5.2）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":"SMALL"}')
assert_eq "Unit 3: 大文字 'SMALL' は空文字（許可値と厳密一致しない / Req 5.2）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":" small "}')
assert_eq "Unit 3: 前後空白付き ' small ' は空文字（Req 5.2）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":""}')
assert_eq "Unit 3: 空文字列は空文字（Req 5.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

# 注入を狙った文字列（コマンド置換 / オプション偽装 / ラベル名偽装）はすべて弾く（NFR 4.1）
f=$(write_triage_fixture '{"complexity":"small; rm -rf /"}')
assert_eq "Unit 3: コマンド注入狙いの値は空文字（NFR 4.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":"--add-label"}')
assert_eq "Unit 3: オプション偽装の値は空文字（NFR 4.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '{"complexity":"large,claude-failed"}')
assert_eq "Unit 3: ラベル名偽装（カンマ区切り複数指定狙い）の値は空文字（NFR 4.1）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

# Unit 4: ファイル不在 / 不正 JSON → 空文字（fail-safe / Req 2.4）
assert_eq "Unit 4: Triage 結果ファイル不在は空文字（Req 2.4）" "" "$(mr_parse_triage_complexity "/tmp/no-such-triage-file-507.json")"

f=$(write_triage_fixture 'これは JSON ではありません')
assert_eq "Unit 4: 不正 JSON（parse 失敗）は空文字（Req 2.4）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

f=$(write_triage_fixture '')
assert_eq "Unit 4: 空ファイルは空文字（Req 2.4）" "" "$(mr_parse_triage_complexity "$f")"
rm -f "$f"

# ════════════════════════════════════════════════════════════════════
# Unit 5: mr_is_enabled（Req 3.1 / 3.2 / 3.3）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Unit: mr_is_enabled ---"

MODEL_ROUTING_ENABLED="true"
assert_rc "Unit 5: MODEL_ROUTING_ENABLED=true のみ rc=0（有効 / Req 3.2）" 0 mr_is_enabled

unset MODEL_ROUTING_ENABLED
assert_rc "Unit 5: 未設定は rc=1（既定無効 / Req 3.1）" 1 mr_is_enabled

for v in "" "false" "off" "True" "TRUE" "1" "0" "ture" "yes" "enabled"; do
  MODEL_ROUTING_ENABLED="$v"
  assert_rc "Unit 5: 不正値 '${v}' は rc=1（安全側へ正規化 / Req 3.3）" 1 mr_is_enabled
done

# ════════════════════════════════════════════════════════════════════
# Unit 6: mr_has_size_label（Req 4.2 / 4.3 / 5.4）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Unit: mr_has_size_label ---"

assert_rc "Unit 6: size:medium あり → rc=0（既存あり / Req 4.2）" 0 \
  mr_has_size_label '{"labels":[{"name":"auto-dev"},{"name":"size:medium"}]}'
assert_rc "Unit 6: 人間付与の size:large あり → rc=0（Triage 由来と区別しない / Req 4.3）" 0 \
  mr_has_size_label '{"labels":[{"name":"size:large"}]}'
assert_rc "Unit 6: 無関係ラベルのみ → rc=1（なし）" 1 \
  mr_has_size_label '{"labels":[{"name":"auto-dev"},{"name":"claude-claimed"}]}'
assert_rc "Unit 6: 空ラベル配列 → rc=1（なし）" 1 \
  mr_has_size_label '{"labels":[]}'
assert_rc "Unit 6: labels key 不在 → rc=1（なし）" 1 \
  mr_has_size_label '{}'
assert_rc "Unit 6: prefix 部分一致しない類似ラベル（sizes:small）→ rc=1" 1 \
  mr_has_size_label '{"labels":[{"name":"sizes:small"}]}'
assert_rc "Unit 6: 不正 JSON → rc=2（判定不能 / Req 5.4）" 2 \
  mr_has_size_label 'これは JSON ではありません'
assert_rc "Unit 6: 空文字入力 → rc=2（判定不能 / Req 5.4）" 2 \
  mr_has_size_label ''

# ════════════════════════════════════════════════════════════════════
# Integration I1〜I7: mr_persist_size_label + gh stub
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Integration: mr_persist_size_label ---"

# ── I1: 許可値 3 種の正常付与（Req 8.4「許可値 3 種の正常付与」/ Req 4.1 / NFR 2.1） ──
MODEL_ROUTING_ENABLED="true"
for c in small medium large; do
  reset_stub_state 0 '{"labels":[{"name":"auto-dev"}]}' 0
  rc=0
  mr_persist_size_label 42 "$c" || rc=$?
  assert_eq "I1(${c}): 正常付与の rc=0" "0" "$rc"
  add_count=$(count_calls "gh issue edit")
  assert_eq "I1(${c}): gh issue edit（--add-label）が 1 回" "1" "$add_count"
  # pflag 規則で解釈した「解決後のラベル値」を検証する（Req 4.1）。
  # 生の引数文字列マッチではなく解決値を見ることで、`--add-label -- <値>` のように
  # 値が `--` に化けて実機で `invalid issue format` になる形を検出できる。
  parsed="$(grep 'GH-PARSED-EDIT' "$GH_CALL_LOG" || true)"
  assert_contains "I1(${c}): --add-label の解決値が size:${c} である（Req 4.1 / 実機で付与が成立する形）" \
    "$parsed" "add_label=size:${c}"
  # NFR 4.2: 値がフラグへ正しく束縛され、余剰 positional（issue 番号以外）が残らないこと。
  # `--add-label -- size:X` 形では positionals=2 になりここで落ちる。
  assert_contains "I1(${c}): positional は issue 番号のみ（値がフラグへ束縛される / NFR 4.2）" \
    "$parsed" "positionals=1"
  # `=` 束縛形であること（値が `-` 始まりでもフラグ解釈される余地がない構文 / NFR 4.2）
  edit_call="$(grep 'gh issue edit' "$GH_CALL_LOG" || true)"
  assert_contains "I1(${c}): \`=\` 束縛形 --add-label=size:${c} で渡す（NFR 4.2）" \
    "$edit_call" "--add-label=size:${c}"
  log_out="$(cat "$LOG_LOG")"
  assert_contains "I1(${c}): ログに Issue 番号を含む（NFR 2.1）" "$log_out" "#42"
  assert_contains "I1(${c}): ログに確定した complexity 値を含む（NFR 2.1）" "$log_out" "complexity=${c}"
  warn_out="$(cat "$WARN_LOG")"
  assert_eq "I1(${c}): 正常付与時は WARN を出さない" "" "$warn_out"
  cleanup_stub_state
done

# ── I2: complexity 空文字（欠落相当）（Req 8.4「complexity 欠落」/ Req 5.1） ──
reset_stub_state 0 '{"labels":[]}' 0
rc=0
mr_persist_size_label 42 "" || rc=$?
assert_eq "I2: complexity 欠落は rc=2（Req 5.1）" "2" "$rc"
assert_eq "I2: complexity 欠落時は gh 呼び出し 0 回（Req 5.1）" "0" "$(count_calls 'gh ')"
warn_out="$(cat "$WARN_LOG")"
assert_contains "I2: WARN に Issue 番号を含む（NFR 2.2）" "$warn_out" "#42"
assert_eq "I2: WARN は 1 行（silent fail させない / Req 5.6）" "1" "$(wc -l <"$WARN_LOG")"
assert_eq "I2: 付与ログ（mr_log）は出さない" "" "$(cat "$LOG_LOG")"
cleanup_stub_state

# 引数自体を省略した呼び出しでも同様に rc=2（call site の変数未束縛に対する fail-safe）
reset_stub_state 0 '{"labels":[]}' 0
rc=0
mr_persist_size_label 42 || rc=$?
assert_eq "I2: 第 2 引数省略も rc=2（Req 5.1）" "2" "$rc"
assert_eq "I2: 第 2 引数省略時も gh 呼び出し 0 回" "0" "$(count_calls 'gh ')"
cleanup_stub_state

# ── I3: 不正値（Req 8.4「不正値」/ Req 5.2 / NFR 4.1） ──
for bad in "huge" "SMALL" " small " "small; rm -rf /" "--add-label" "large,claude-failed"; do
  reset_stub_state 0 '{"labels":[]}' 0
  rc=0
  mr_persist_size_label 42 "$bad" || rc=$?
  assert_eq "I3: 不正値 '${bad}' は rc=2（Req 5.2）" "2" "$rc"
  assert_eq "I3: 不正値 '${bad}' では gh 呼び出し 0 回（ラベル名構成に到達しない / NFR 4.1）" \
    "0" "$(count_calls 'gh ')"
  assert_eq "I3: 不正値 '${bad}' で WARN 1 行（Req 5.6）" "1" "$(wc -l <"$WARN_LOG")"
  cleanup_stub_state
done

# ── I4: 既存 size:* ラベルあり（Req 8.4「既存 size:* ラベルあり」/ Req 4.2 / 4.3 / 4.4 / 4.7） ──
reset_stub_state 0 '{"labels":[{"name":"auto-dev"},{"name":"size:large"}]}' 0
rc=0
mr_persist_size_label 42 "small" || rc=$?
assert_eq "I4: 既存 size:* ありは rc=3（Req 4.2）" "3" "$rc"
assert_eq "I4: 既存 size:* ありなら add-label は 0 回（付け替えない / Req 4.2 / 4.4）" \
  "0" "$(count_calls 'gh issue edit')"
assert_eq "I4: 既存 size:* ありでも labels 取得は 1 回のみ（NFR 3.1）" \
  "1" "$(count_calls 'gh issue view')"
log_out="$(cat "$LOG_LOG")"
assert_contains "I4: skip 理由を判別できるログを出す（Req 4.7）" "$log_out" "skip"
assert_contains "I4: skip ログに Issue 番号を含む（NFR 2.2）" "$log_out" "#42"
cleanup_stub_state

# 人間が事前に貼った size ラベルも同様に優先される（Req 4.3 / 再 Triage 冪等 / Req 4.4）
reset_stub_state 0 '{"labels":[{"name":"size:small"}]}' 0
rc=0
mr_persist_size_label 7 "large" || rc=$?
assert_eq "I4: 人間 override の size:small が優先され rc=3（Req 4.3）" "3" "$rc"
assert_eq "I4: 人間 override 時も add-label 0 回（重複・併存を生じさせない / Req 4.4）" \
  "0" "$(count_calls 'gh issue edit')"
cleanup_stub_state

# ── I5: gate 無効（Req 8.4「gate 無効」/ Req 3.4 / NFR 1.1 / NFR 3.2） ──
unset MODEL_ROUTING_ENABLED
reset_stub_state 0 '{"labels":[]}' 0
rc=0
mr_persist_size_label 42 "small" || rc=$?
assert_eq "I5: gate 未設定は rc=1（Req 3.1 / 3.4）" "1" "$rc"
assert_eq "I5: gate 未設定では gh 呼び出し 0 回（NFR 3.2）" "0" "$(count_calls 'gh ')"
assert_eq "I5: gate 未設定ではログ出力 0 行（導入前と同一 / NFR 1.1）" "" "$(cat "$LOG_LOG")"
assert_eq "I5: gate 未設定では WARN 出力 0 行（導入前と同一 / NFR 1.1）" "" "$(cat "$WARN_LOG")"
cleanup_stub_state

for v in "True" "1" "false" "off" ""; do
  MODEL_ROUTING_ENABLED="$v"
  reset_stub_state 0 '{"labels":[]}' 0
  rc=0
  mr_persist_size_label 42 "small" || rc=$?
  assert_eq "I5: gate 不正値 '${v}' は rc=1（安全側 / Req 3.3）" "1" "$rc"
  assert_eq "I5: gate 不正値 '${v}' では gh 呼び出し 0 回（Req 3.4 / NFR 3.2）" "0" "$(count_calls 'gh ')"
  assert_eq "I5: gate 不正値 '${v}' ではログ出力 0 行（NFR 1.1）" "" "$(cat "$LOG_LOG")$(cat "$WARN_LOG")"
  cleanup_stub_state
done

# ── I6: labels 取得失敗 / add-label 失敗（Req 5.3 / 5.4） ──
# gate を再度有効化する（I5 で unset / 不正値に切り替えているため）。
# extract_function で読み込んだ mr_is_enabled が遅延束縛で参照するため SC2034 を抑止。
# shellcheck disable=SC2034
MODEL_ROUTING_ENABLED="true"

reset_stub_state 1 '' 0
rc=0
mr_persist_size_label 42 "medium" || rc=$?
assert_eq "I6: labels 取得失敗は rc=4（安全側・付与しない / Req 5.4）" "4" "$rc"
assert_eq "I6: labels 取得失敗時は add-label を呼ばない（誤った上書き回避 / Req 5.4）" \
  "0" "$(count_calls 'gh issue edit')"
warn_out="$(cat "$WARN_LOG")"
assert_contains "I6: labels 取得失敗の WARN に Issue 番号を含む（NFR 2.2）" "$warn_out" "#42"
assert_eq "I6: labels 取得失敗で WARN 1 行（silent fail させない / Req 5.6）" "1" "$(wc -l <"$WARN_LOG")"
cleanup_stub_state

# labels 取得は成功するが JSON が壊れている（解析不能）→ rc=4（安全側 / Req 5.4）
reset_stub_state 0 'これは JSON ではありません' 0
rc=0
mr_persist_size_label 42 "medium" || rc=$?
assert_eq "I6: labels JSON 解析不能は rc=4（安全側 / Req 5.4）" "4" "$rc"
assert_eq "I6: labels JSON 解析不能時は add-label を呼ばない（Req 5.4）" \
  "0" "$(count_calls 'gh issue edit')"
assert_eq "I6: labels JSON 解析不能で WARN 1 行（Req 5.6）" "1" "$(wc -l <"$WARN_LOG")"
cleanup_stub_state

# add-label 失敗（API 不達 / rate limit / 権限不足 / 対象ラベル未定義）→ rc=5 + WARN（Req 5.3）
reset_stub_state 0 '{"labels":[{"name":"auto-dev"}]}' 1
rc=0
mr_persist_size_label 42 "large" || rc=$?
assert_eq "I6: add-label 失敗は rc=5（fail-open / Req 5.3）" "5" "$rc"
warn_out="$(cat "$WARN_LOG")"
assert_contains "I6: add-label 失敗の WARN に Issue 番号を含む（NFR 2.2）" "$warn_out" "#42"
assert_contains "I6: add-label 失敗の WARN に対象ラベル名を含む（NFR 2.2）" "$warn_out" "size:large"
assert_eq "I6: add-label 失敗で WARN 1 行（silent fail させない / Req 5.6）" "1" "$(wc -l <"$WARN_LOG")"
cleanup_stub_state

# ── I7: 正常経路の gh 呼び出し総数が 2 回以下（NFR 3.1） ──
reset_stub_state 0 '{"labels":[{"name":"auto-dev"}]}' 0
rc=0
mr_persist_size_label 42 "small" || rc=$?
total_calls=$(count_calls 'gh ')
assert_eq "I7: 正常経路の rc=0" "0" "$rc"
assert_eq "I7: 正常経路の gh 呼び出しは計 2 回（labels 取得 1 + 付与 1 / NFR 3.1）" "2" "$total_calls"
assert_eq "I7: 正常経路の labels 取得は 1 回" "1" "$(count_calls 'gh issue view')"
cleanup_stub_state

# ── 追加: `--remove-label` を一切使わない（既存ラベル遷移契約に触れない / Req 5.5） ──
# コメント行（規約の説明で `--remove-label` に言及する行）は除外し、実行行のみを対象にする。
remove_label_lines=$( { grep -v '^[[:space:]]*#' "$MODEL_ROUTER_SH" | grep -- '--remove-label' || true; } | wc -l)
assert_eq "Req 5.5: model-router.sh の実行行に --remove-label が無い（既存ラベル遷移契約不変）" \
  "0" "$((remove_label_lines))"

# ════════════════════════════════════════════════════════════════════
# Wiring（grep ベース / 実行なし）: gate 宣言と module ローダ登録（Req 3.1 / 3.6 / NFR 1.2）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Wiring: gate 宣言 / module ローダ登録 ---"

# W1: issue-watcher.sh の REQUIRED_MODULES に model-router.sh が含まれる
required_modules_line="$(grep -E '^REQUIRED_MODULES=\(' "$ISSUE_WATCHER_SH" || true)"
assert_contains "W1: REQUIRED_MODULES に model-router.sh が登録されている" \
  "$required_modules_line" '"model-router.sh"'
assert_contains "W1: model-router.sh は path-overlap.sh の直後に登録されている（design.md 指定位置）" \
  "$required_modules_line" '"path-overlap.sh" "model-router.sh"'

# W2: watcher-config.sh に MODEL_ROUTING_ENABLED の既定値宣言が存在し、既定は無効
config_decl="$(grep -E '^MODEL_ROUTING_ENABLED=' "$WATCHER_CONFIG_SH" || true)"
# 期待値は「宣言行そのもの」のリテラルなので単一引用符での展開抑止が意図的（SC2016 抑止）。
# shellcheck disable=SC2016
assert_eq "W2: watcher-config.sh に既定無効の gate 宣言が 1 行ある（Req 3.1）" \
  'MODEL_ROUTING_ENABLED="${MODEL_ROUTING_ENABLED:-false}"' "$config_decl"

# W3: #112 の「デフォルト有効化フラグの値正規化」ループ（既定 true 側）に含めない（新規 opt-in）
default_true_loop_hits=$( { grep -n 'MODEL_ROUTING_ENABLED' "$WATCHER_CONFIG_SH" \
  | grep -E 'for |_flag|正規化ループ' || true; } | wc -l)
assert_eq "W3: gate はデフォルト有効化フラグの正規化ループに含まれない（新規 opt-in / Req 3.1）" \
  "0" "$((default_true_loop_hits))"

# W4: Phase 別の追加 gate を設けていない（単一 gate / Req 3.6）
phase_gate_hits=$( { grep -rE '^[[:space:]]*MODEL_ROUTING_[A-Z_]*=' \
  "$WATCHER_CONFIG_SH" "$MODEL_ROUTER_SH" || true; } \
  | { grep -vc 'MODEL_ROUTING_ENABLED=' || true; } )
assert_eq "W4: MODEL_ROUTING_ENABLED 以外の Phase 別 gate を宣言していない（Req 3.6）" \
  "0" "$((phase_gate_hits))"

# ════════════════════════════════════════════════════════════════════
# Wiring（grep ベース / 実行なし）: slot-worker.sh の call site
#   Req 2.5 / 3.4 / 4.5 / 4.6 / NFR 1.1 / NFR 2.3
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Wiring: slot-worker.sh call site ---"

# 行番号を解決する（0 = 不在）。
line_of() {
  local pattern="$1" file="$2"
  local n
  n=$( { grep -nE -- "$pattern" "$file" || true; } | head -1 | cut -d: -f1)
  echo "$((${n:-0}))"
}

# grep へ渡す ERE リテラル中の `$` は展開させたくないため単一引用符が意図的（SC2016 抑止）。
# 行頭アンカー付きパターンでコメント行ではなく実行行のみを拾う。
# shellcheck disable=SC2016
phase_e_line=$(line_of '^[[:space:]]*if \[ "\$PATH_OVERLAP_CHECK" = "true" \]; then' "$SLOT_WORKER_SH")
gate_line=$(line_of '^[[:space:]]*if mr_is_enabled; then' "$SLOT_WORKER_SH")
# shellcheck disable=SC2016
needs_decisions_line=$(line_of '^[[:space:]]*if \[ "\$STATUS" = "needs-decisions" \]' "$SLOT_WORKER_SH")
persist_line=$(line_of '^[[:space:]]*mr_persist_size_label ' "$SLOT_WORKER_SH")

# W5: gate ブロックが存在し、Phase E ブロックの後・needs-decisions 分岐の前に置かれている
assert_rc "W5: slot-worker.sh に mr_is_enabled gate ブロックが存在する" 0 \
  test "$gate_line" -gt 0
assert_rc "W5: gate ブロックは Phase E edit_paths ブロックより後にある（design.md 指定位置）" 0 \
  test "$gate_line" -gt "$phase_e_line"
assert_rc "W5: gate ブロックは needs-decisions 分岐より前にある（早期 return 前に付与 / Req 4.5）" 0 \
  test "$gate_line" -lt "$needs_decisions_line"

# W6: gate 外に mr_persist_size_label 呼び出しが無い（呼び出しは gate ブロック内 1 箇所のみ）
persist_call_count=$( { grep -cE '^[[:space:]]*mr_persist_size_label ' "$SLOT_WORKER_SH" || true; } )
assert_eq "W6: mr_persist_size_label の呼び出しは 1 箇所のみ（Req 3.4）" "1" "$((persist_call_count))"
assert_rc "W6: mr_persist_size_label 呼び出しは gate 行より後（gate 内に閉じている / Req 3.4）" 0 \
  test "$persist_line" -gt "$gate_line"
assert_rc "W6: mr_persist_size_label 呼び出しは needs-decisions 分岐より前" 0 \
  test "$persist_line" -lt "$needs_decisions_line"

# W7: `skip-triage` / impl-resume（HAS_EXISTING_SPEC）分岐側に mr_* 呼び出しが無い
#     （call site の位置で非付与を構造的に保証する / Req 4.5 / 4.6）
skip_triage_line=$(line_of 'LABEL_SKIP_TRIAGE' "$SLOT_WORKER_SH")
# shellcheck disable=SC2016
has_existing_spec_line=$(line_of '^[[:space:]]*if \$HAS_EXISTING_SPEC; then' "$SLOT_WORKER_SH")
assert_rc "W7: gate ブロックは impl-resume 分岐（HAS_EXISTING_SPEC）より後 = else 枝の内側（Req 4.6）" 0 \
  test "$gate_line" -gt "$has_existing_spec_line"
assert_rc "W7: gate ブロックは skip-triage 分岐より後 = else 枝の内側（Req 4.5）" 0 \
  test "$gate_line" -gt "$skip_triage_line"

# W8: call site が $STATUS / $NEEDS_ARCHITECT / $MODE を読み書きしない（Req 2.5）
#     gate 行から呼び出し行の直後までを切り出して検査する。
gate_block=$(sed -n "${gate_line},$((persist_line + 1))p" "$SLOT_WORKER_SH")
for v in 'STATUS' 'NEEDS_ARCHITECT' 'MODE'; do
  hits=$( { printf '%s\n' "$gate_block" | grep -c "\$$v" || true; } )
  assert_eq "W8: call site は \$$v を読み書きしない（mode 判定・needs-decisions 経路不変 / Req 2.5）" \
    "0" "$((hits))"
done

# W9: 呼び出し側は rc を分岐に使わず吸収する（`|| true` / Req 5.3 fail-open / NFR 1.1）
persist_call_line="$(sed -n "${persist_line}p" "$SLOT_WORKER_SH")"
assert_contains "W9: mr_persist_size_label の戻り値を吸収して後続へ伝播させない（Req 2.4 / 5.3）" \
  "$persist_call_line" "|| true"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
