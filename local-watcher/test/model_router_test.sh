#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/model-router.sh（#507 モデルルーティング Phase 1）の
#       近接テスト。Triage の complexity 解釈と size ラベル永続化を fixture / gh stub で
#       検証する。
#
#       対象関数（Phase 1 / #507）:
#         - mr_is_enabled              (Req 3.1 / 3.2 / 3.3)
#         - mr_parse_triage_complexity (Req 2.3 / 2.4 / 5.1 / 5.2 / NFR 4.1)
#         - mr_has_size_label          (Req 4.2 / 4.3 / 5.4 / NFR 4.2)
#         - mr_persist_size_label      (Req 3.4 / 4.1〜4.4 / 4.7 / 5.1〜5.6 / NFR 2.1 / 2.2 / 3.1 / 3.2)
#
#       対象関数（Phase 2 / #508）:
#         - mr_extract_size_label        (#508 Req 3.2〜3.5 / NFR 3.1 / 3.2)
#         - mr_resolve_dev_model         (#508 Req 1.1〜1.8)
#         - _slot_apply_dev_model_routing(#508 Req 3.1 / 3.6 / 3.7 / 5.2 / 5.3 / 5.6 / 6.1〜6.4)
#           （slot-worker.sh 側の適用ヘルパー。extract_function で隔離抽出する）
#
#       検証する AC（docs/specs/507-feat-watcher-triage-complexity-size-phas/requirements.md）:
#         Req 8.4 が要求する 5 ケース（許可値 3 種の正常付与 / complexity 欠落 / 不正値 /
#         既存 size:* ラベルあり / gate 無効）を Integration I1〜I5 で網羅し、
#         I6（labels 取得失敗 / 付与失敗）と I7（gh 呼び出し回数 2 回以下）を追加する。
#
#       検証する AC（docs/specs/508-feat-watcher-size-developer-phase-2/requirements.md）:
#         #508 Req 8.4（解決規則の 3 値 × 設定あり／なし・許可値以外・空文字）を Unit P1 / P2、
#         Req 8.5（size ラベルなし / 複数 / 不正値 / gate 無効で DEV_MODEL 適用）と
#         Req 8.6（gate 無効時のログ 0 行）を Integration P3、Req 8.7（サブシェル境界を
#         越えない）を P3 の最終ケース、設定値と call site の配線を Wiring P4 で検証する。
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
for _fn in mr_is_enabled mr_parse_triage_complexity mr_has_size_label mr_persist_size_label \
           mr_extract_size_label mr_resolve_dev_model; do
  # shellcheck disable=SC1090,SC2086
  eval "$(extract_function "$MODEL_ROUTER_SH" "$_fn")"
  if ! declare -F "$_fn" >/dev/null; then
    echo "ERROR: $_fn not loaded" >&2
    exit 2
  fi
done
unset _fn

# Phase 2 (#508): slot 側の適用ヘルパーも同じイディオムで隔離抽出する。
# 本関数は mr_is_enabled / mr_extract_size_label / mr_resolve_dev_model / mr_log / mr_warn を
# 遅延束縛で呼ぶため、上のループと後述の stub で依存が揃っている必要がある。
if [ ! -f "$SLOT_WORKER_SH" ]; then
  echo "ERROR: cannot find slot-worker.sh at $SLOT_WORKER_SH" >&2
  exit 2
fi
# shellcheck disable=SC1090
eval "$(extract_function "$SLOT_WORKER_SH" "_slot_apply_dev_model_routing")"
if ! declare -F _slot_apply_dev_model_routing >/dev/null; then
  echo "ERROR: _slot_apply_dev_model_routing not loaded" >&2
  exit 2
fi

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

# ════════════════════════════════════════════════════════════════════
# ここから Phase 2（#508: size ラベル → Developer モデル解決）
#   参照要件: docs/specs/508-feat-watcher-size-developer-phase-2/requirements.md
#   以下のコメント内 "Req x.y" はすべて #508 の requirements.md を指す。
# ════════════════════════════════════════════════════════════════════

# ════════════════════════════════════════════════════════════════════
# Unit P1: mr_extract_size_label（Req 3.2〜3.5 / 8.5 / NFR 3.1 / 3.2）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Unit P1: mr_extract_size_label (#508) ---"

# ラベル集合を渡し、stdout の size 値と rc の両方を検証する。
# rc: 0=確定 / 1=size: ラベル 0 件 / 2=2 件以上 / 3=厳密一致に失敗
assert_extract() {
  local label="$1" labels="$2" expected_out="$3" expected_rc="$4"
  local out="" rc=0
  out=$(mr_extract_size_label "$labels") || rc=$?
  assert_eq "${label}（値）" "$expected_out" "$out"
  assert_eq "${label}（rc）" "$expected_rc" "$rc"
}

# P1-1: 許可値 3 種の厳密一致（Req 3.2）
assert_extract "P1-1: size:small 単独 → small（Req 3.2）" "size:small" "small" "0"
assert_extract "P1-1: size:medium 単独 → medium（Req 3.2）" "size:medium" "medium" "0"
assert_extract "P1-1: size:large 単独 → large（Req 3.2）" "size:large" "large" "0"

# 無関係ラベルが混在しても size 値は切り出せる（実際の Issue ラベル集合を模す）
assert_extract "P1-1: 無関係ラベル混在でも size:medium を切り出す（Req 3.2）" \
  "auto-dev
claude-claimed
size:medium" "medium" "0"

# P1-2: size: prefix ラベル 0 件 → rc=1 / 値なし（Req 3.3）
assert_extract "P1-2: ラベルなし（空文字入力）→ 値なし・rc=1（Req 3.3）" "" "" "1"
assert_extract "P1-2: 無関係ラベルのみ → 値なし・rc=1（Req 3.3）" \
  "auto-dev
claude-claimed" "" "1"
assert_extract "P1-2: prefix が部分一致しない sizes:small → 値なし・rc=1（Req 3.3）" \
  "sizes:small" "" "1"
assert_extract "P1-2: 先頭に空白を含む ' size:small' は prefix 不一致 → 値なし・rc=1（Req 3.5 と同じ DEV_MODEL 適用）" \
  " size:small" "" "1"

# P1-3: size: prefix ラベルが 2 件以上 → 値なし・rc=2（Req 3.4 fail-safe）
assert_extract "P1-3: size:small + size:large の併存 → 値なし・rc=2（Req 3.4）" \
  "size:small
size:large" "" "2"
assert_extract "P1-3: 同一値の重複付与でも採用しない → 値なし・rc=2（Req 3.4）" \
  "size:small
size:small" "" "2"
assert_extract "P1-3: 有効値 + 不正値の併存も採用しない → 値なし・rc=2（Req 3.4）" \
  "size:small
size:huge" "" "2"

# P1-4: 1 件だが厳密一致に失敗 → 値なし・rc=3（Req 3.5 fail-safe / NFR 3.1）
for bad in "size:huge" "size:Small" "size:SMALL" "size:" "size:small " "size:small,size:large" "size:small; rm -rf /" "size:--add-label"; do
  assert_extract "P1-4: 不正ラベル '${bad}' → 値なし・rc=3（Req 3.5 / NFR 3.1）" "$bad" "" "3"
done

# P1-5: 副作用なし（外部コマンドを呼ばない / NFR 3.1 / 3.2）
reset_stub_state 0 '{"labels":[]}' 0
_ignored=$(mr_extract_size_label "size:small")
assert_eq "P1-5: 抽出は gh を呼ばない（未信頼値を外部コマンドへ渡さない / NFR 3.1）" \
  "0" "$(count_calls 'gh ')"
assert_eq "P1-5: 抽出はログを出さない（純粋関数 / Req 1.7 と同じ性質）" \
  "" "$(cat "$LOG_LOG")$(cat "$WARN_LOG")"
cleanup_stub_state

# ════════════════════════════════════════════════════════════════════
# Unit P2: mr_resolve_dev_model（Req 1.1〜1.8 / 8.4）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Unit P2: mr_resolve_dev_model (#508) ---"

# 抽出した関数本体が遅延束縛で参照するグローバル（SC2034 は誤検知）。
# shellcheck disable=SC2034
DEV_MODEL="dev-default"
# shellcheck disable=SC2034
DEV_MODEL_SMALL="small-model"
# shellcheck disable=SC2034
DEV_MODEL_MEDIUM="medium-model"

# P2-1: 3 値 × 対応設定あり（Req 1.1 / 1.2 / 1.3 / 8.4）
assert_eq "P2-1: small かつ DEV_MODEL_SMALL 設定あり → DEV_MODEL_SMALL（Req 1.1）" \
  "small-model" "$(mr_resolve_dev_model small)"
assert_eq "P2-1: medium かつ DEV_MODEL_MEDIUM 設定あり → DEV_MODEL_MEDIUM（Req 1.2）" \
  "medium-model" "$(mr_resolve_dev_model medium)"
assert_eq "P2-1: large は設定の有無に関わらず DEV_MODEL（Req 1.3 / DEV_MODEL_LARGE を持たない）" \
  "dev-default" "$(mr_resolve_dev_model large)"

# P2-2: 許可値以外 / 空文字 / 引数省略 → DEV_MODEL（fail-safe / Req 1.4 / 8.4）
for bad in "huge" "SMALL" "Small" "small medium" "--model" ""; do
  assert_eq "P2-2: 許可値以外 '${bad}' → DEV_MODEL（fail-safe / Req 1.4）" \
    "dev-default" "$(mr_resolve_dev_model "$bad")"
done
assert_eq "P2-2: 引数省略（未指定）→ DEV_MODEL（fail-safe / Req 1.4）" \
  "dev-default" "$(mr_resolve_dev_model)"

# P2-3: 3 値 × 対応設定なし（未設定 / 空文字）→ DEV_MODEL（Req 1.5 / 8.4）
DEV_MODEL_SMALL=""
DEV_MODEL_MEDIUM=""
assert_eq "P2-3: small かつ DEV_MODEL_SMALL 空 → DEV_MODEL（Req 1.5）" \
  "dev-default" "$(mr_resolve_dev_model small)"
assert_eq "P2-3: medium かつ DEV_MODEL_MEDIUM 空 → DEV_MODEL（Req 1.5）" \
  "dev-default" "$(mr_resolve_dev_model medium)"
assert_eq "P2-3: large かつ size 別設定なし → DEV_MODEL（Req 1.3 / 1.5）" \
  "dev-default" "$(mr_resolve_dev_model large)"

unset DEV_MODEL_SMALL DEV_MODEL_MEDIUM
assert_eq "P2-3: DEV_MODEL_SMALL 未設定（unset）→ DEV_MODEL（Req 1.5）" \
  "dev-default" "$(mr_resolve_dev_model small)"
assert_eq "P2-3: DEV_MODEL_MEDIUM 未設定（unset）→ DEV_MODEL（Req 1.5）" \
  "dev-default" "$(mr_resolve_dev_model medium)"

# P2-4: 片側だけ設定した場合の独立性（Req 1.1 / 1.2 / 1.5）
# shellcheck disable=SC2034
DEV_MODEL_SMALL="small-only"
assert_eq "P2-4: small だけ設定 → small は small-only（Req 1.1）" \
  "small-only" "$(mr_resolve_dev_model small)"
assert_eq "P2-4: small だけ設定 → medium は DEV_MODEL（Req 1.5）" \
  "dev-default" "$(mr_resolve_dev_model medium)"

# P2-5: 許可値リストを持たず設定値をそのまま返す（Req 1.6）
# shellcheck disable=SC2034
DEV_MODEL_SMALL="not-a-real-model-id-xyz"
assert_eq "P2-5: 未知のモデル ID も照合・変換・補完せずそのまま返す（Req 1.6）" \
  "not-a-real-model-id-xyz" "$(mr_resolve_dev_model small)"

# P2-6: 決定性（同一入力 → 同一出力 / Req 1.8）
# shellcheck disable=SC2034
DEV_MODEL_SMALL="small-model"
first="$(mr_resolve_dev_model small)"
second="$(mr_resolve_dev_model small)"
assert_eq "P2-6: 同一入力に対して常に同一結果（Req 1.8）" "$first" "$second"

# P2-7: 副作用なし（gh 呼び出し 0 回 / ログ 0 行 / 入力側変数を書き換えない / Req 1.7）
reset_stub_state 0 '{"labels":[]}' 0
_ignored="$(mr_resolve_dev_model small)"
assert_eq "P2-7: 解決は gh を呼ばない（Req 1.7 / NFR 2.2）" "0" "$(count_calls 'gh ')"
assert_eq "P2-7: 解決はログを出さない（Req 1.7）" "" "$(cat "$LOG_LOG")$(cat "$WARN_LOG")"
assert_eq "P2-7: 解決は DEV_MODEL を書き換えない（呼び出し元の状態を変更しない / Req 1.7）" \
  "dev-default" "$DEV_MODEL"
assert_eq "P2-7: 解決は DEV_MODEL_SMALL を書き換えない（Req 1.7）" "small-model" "$DEV_MODEL_SMALL"
cleanup_stub_state

# P2-8: gate を解決規則へ持ち込まない（gate 判定は呼び出し側 / Req 1.8 / 5.1）
MODEL_ROUTING_ENABLED="false"
assert_eq "P2-8: 解決規則は gate 値に依存しない（gate 判定は Slot Runner 側 / Req 1.8）" \
  "small-model" "$(mr_resolve_dev_model small)"

# ════════════════════════════════════════════════════════════════════
# Integration P3: _slot_apply_dev_model_routing
#   Req 3.1〜3.7 / 4.1 / 5.2 / 5.3 / 5.6 / 6.1〜6.4 / 8.5 / 8.6 / 8.7 / NFR 2.1 / 2.2
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Integration P3: _slot_apply_dev_model_routing (#508) ---"

# 1 ケース分の初期状態を作る（gate 値 / size 別モデル設定を引数で切り替える）。
# DEV_MODEL は常に "dev-default" から開始し、適用結果を観測する。
setup_routing_case() {
  MODEL_ROUTING_ENABLED="$1"
  DEV_MODEL="dev-default"
  DEV_MODEL_SMALL="$2"
  DEV_MODEL_MEDIUM="$3"
  reset_stub_state 0 '{"labels":[]}' 0
}

# ── P3-1: gate 無効の各表現で DEV_MODEL 据え置き・ログ 0 行（Req 5.2 / 5.3 / 8.5 / 8.6） ──
for gate in "" "false" "off" "True" "TRUE" "1" "yes" "ture"; do
  setup_routing_case "$gate" "small-model" "medium-model"
  _slot_apply_dev_model_routing 42 "size:small"
  assert_eq "P3-1: gate='${gate}' では DEV_MODEL を適用（Req 5.2 / 8.5）" "dev-default" "$DEV_MODEL"
  assert_eq "P3-1: gate='${gate}' では本機能起因のログが 0 行（Req 5.3 / 8.6 / NFR 2.1）" \
    "0" "$(( $(wc -l <"$LOG_LOG") + $(wc -l <"$WARN_LOG") ))"
  assert_eq "P3-1: gate='${gate}' では外部コマンド呼び出し 0 回（NFR 2.1）" "0" "$(count_calls 'gh ')"
  cleanup_stub_state
done

# gate 未設定（unset）も同様（既存 consumer 環境の既定状態 / NFR 1.2）
unset MODEL_ROUTING_ENABLED
DEV_MODEL="dev-default"
DEV_MODEL_SMALL="small-model"
DEV_MODEL_MEDIUM="medium-model"
reset_stub_state 0 '{"labels":[]}' 0
_slot_apply_dev_model_routing 42 "size:small"
assert_eq "P3-1: gate 未設定（unset）でも DEV_MODEL を適用（NFR 1.2 / 8.5）" "dev-default" "$DEV_MODEL"
assert_eq "P3-1: gate 未設定（unset）では本機能起因のログが 0 行（Req 5.3 / 8.6）" \
  "0" "$(( $(wc -l <"$LOG_LOG") + $(wc -l <"$WARN_LOG") ))"
cleanup_stub_state

# ── P3-2: gate 有効 + size 別モデル設定あり（二重 opt-in 成立 / Req 3.1 / 6.1） ──
setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 42 "auto-dev
size:small"
assert_eq "P3-2: size:small → DEV_MODEL_SMALL を適用（Req 3.1 / 1.1）" "small-model" "$DEV_MODEL"
log_out="$(cat "$LOG_LOG")"
assert_eq "P3-2: ログは 1 行（Req 6.1 / 6.4）" "1" "$(( $(wc -l <"$LOG_LOG") ))"
assert_contains "P3-2: ログに Issue 番号を含む（Req 6.1）" "$log_out" "#42"
assert_contains "P3-2: ログに採用した size 値を含む（Req 6.1）" "$log_out" "size=small"
assert_contains "P3-2: ログに適用したモデル ID を含む（Req 6.1）" "$log_out" "dev_model=small-model"
assert_eq "P3-2: 正常適用時は WARN を出さない" "" "$(cat "$WARN_LOG")"
assert_eq "P3-2: GitHub API 呼び出しは 0 回（slot 起動時のラベル集合のみ使用 / NFR 2.2）" \
  "0" "$(count_calls 'gh ')"
cleanup_stub_state

setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 7 "size:medium"
assert_eq "P3-2: size:medium → DEV_MODEL_MEDIUM を適用（Req 3.1 / 1.2）" "medium-model" "$DEV_MODEL"
assert_contains "P3-2: medium のログに size 値とモデル ID を含む（Req 6.1）" \
  "$(cat "$LOG_LOG")" "size=medium dev_model=medium-model"
cleanup_stub_state

setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 7 "size:large"
assert_eq "P3-2: size:large → DEV_MODEL を適用（Req 1.3）" "dev-default" "$DEV_MODEL"
log_out="$(cat "$LOG_LOG")"
assert_contains "P3-2: large も 1 行のログを残す（Req 6.4）" "$log_out" "size=large dev_model=dev-default"
assert_eq "P3-2: large は仕様どおりの解決であり fallback 表記を付けない（Req 1.3）" \
  "0" "$( { grep -c 'fallback' "$LOG_LOG" || true; } )"
cleanup_stub_state

# ── P3-3: 二重 opt-in（gate だけ有効で size 別モデル未設定）→ DEV_MODEL（Req 2.3 / 1.5） ──
for sz in small medium; do
  setup_routing_case "true" "" ""
  _slot_apply_dev_model_routing 42 "size:${sz}"
  assert_eq "P3-3: gate 有効でも size 別モデル未設定なら DEV_MODEL（二重 opt-in / Req 2.3）" \
    "dev-default" "$DEV_MODEL"
  assert_contains "P3-3: ${sz} の fallback 理由をログで判別できる（Req 6.2）" \
    "$(cat "$LOG_LOG")" "fallback=DEV_MODEL"
  assert_eq "P3-3: ${sz} でもログは 1 行（Req 6.4）" "1" "$(( $(wc -l <"$LOG_LOG") ))"
  cleanup_stub_state
done

# ── P3-4: size ラベルなし → DEV_MODEL（Req 3.3 / 6.2 / 8.5） ──
setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 42 "auto-dev
claude-claimed"
assert_eq "P3-4: size ラベルなし → DEV_MODEL（Req 3.3 / 8.5）" "dev-default" "$DEV_MODEL"
log_out="$(cat "$LOG_LOG")"
assert_contains "P3-4: fallback したことを判別できるログ（Req 6.2）" "$log_out" "fallback=DEV_MODEL"
assert_contains "P3-4: size 不在を表すトークンをログに含む（Req 6.2）" "$log_out" "size=none"
assert_eq "P3-4: ログは 1 行（Req 6.4）" "1" "$(( $(wc -l <"$LOG_LOG") ))"
cleanup_stub_state

# ── P3-5: size:* ラベル複数 → DEV_MODEL（Req 3.4 / 8.5） ──
setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 42 "size:small
size:large"
assert_eq "P3-5: size:* 複数付与 → DEV_MODEL（fail-safe / Req 3.4 / 8.5）" "dev-default" "$DEV_MODEL"
log_out="$(cat "$LOG_LOG")"
assert_contains "P3-5: 複数付与の fallback をログで判別できる（Req 6.2）" "$log_out" "size=multiple"
assert_contains "P3-5: 複数付与でも fallback 表記を含む（Req 6.2）" "$log_out" "fallback=DEV_MODEL"
cleanup_stub_state

# ── P3-6: 不正値ラベル → DEV_MODEL（Req 3.5 / 8.5 / NFR 3.1） ──
for bad in "size:huge" "size:Small" "size:small " "size:small; rm -rf /"; do
  setup_routing_case "true" "small-model" "medium-model"
  _slot_apply_dev_model_routing 42 "$bad"
  assert_eq "P3-6: 不正ラベル '${bad}' → DEV_MODEL（fail-safe / Req 3.5 / 8.5）" \
    "dev-default" "$DEV_MODEL"
  assert_contains "P3-6: 不正ラベル '${bad}' の fallback をログで判別できる（Req 6.2）" \
    "$(cat "$LOG_LOG")" "size=invalid"
  # 未信頼なラベル値そのものはログへ出さない（固定トークンのみ / NFR 3.3）
  assert_eq "P3-6: 不正ラベル '${bad}' の生値をログへ出さない（NFR 3.3）" \
    "0" "$( { grep -cF -- "$bad" "$LOG_LOG" || true; } )"
  assert_eq "P3-6: 不正ラベル '${bad}' でも gh 呼び出し 0 回（NFR 2.2 / 3.1）" "0" "$(count_calls 'gh ')"
  cleanup_stub_state
done

# ── P3-7: 想定外状態（DEV_MODEL 自体が空）は fail-open で据え置き（Req 5.6 / 6.4） ──
# 抽出した関数本体が遅延束縛で参照するグローバル（SC2034 は誤検知）。
# shellcheck disable=SC2034
MODEL_ROUTING_ENABLED="true"
DEV_MODEL=""
DEV_MODEL_SMALL=""
# shellcheck disable=SC2034
DEV_MODEL_MEDIUM=""
reset_stub_state 0 '{"labels":[]}' 0
rc=0
_slot_apply_dev_model_routing 42 "size:small" || rc=$?
assert_eq "P3-7: 想定外状態でも rc=0 で処理を継続（fail-open / Req 5.6）" "0" "$rc"
assert_eq "P3-7: 解決結果が空なら DEV_MODEL を書き換えない（Req 5.6）" "" "$DEV_MODEL"
assert_eq "P3-7: 想定外状態でも WARN 1 行を残す（silent fail させない / Req 6.4）" \
  "1" "$(( $(wc -l <"$WARN_LOG") ))"
cleanup_stub_state

# ── P3-8: サブシェル境界を越えない（Req 3.7 / 8.7） ──
# `_slot_run_issue` は Dispatcher からサブシェルで fork されるため、slot 内の DEV_MODEL
# 再代入は親プロセス・他 slot へ伝播しない。同じ境界をサブシェルで再現して検証する。
setup_routing_case "true" "small-model" "medium-model"
child_model="$( _slot_apply_dev_model_routing 42 "size:small" >/dev/null 2>&1; echo "$DEV_MODEL" )"
assert_eq "P3-8: サブシェル内では解決結果が適用される（Req 3.6 / 8.7）" "small-model" "$child_model"
assert_eq "P3-8: 親プロセスの DEV_MODEL は変化しない（Req 3.7 / 8.7）" "dev-default" "$DEV_MODEL"
cleanup_stub_state

# ── P3-9: 1 slot 実行あたり 1 回の解決で以降一貫（Req 3.6 / 4.1 / NFR 2.4） ──
# 同一 slot 内で 2 度呼ばれない前提だが、呼ばれても結果は同一（冪等）であることを確認する。
setup_routing_case "true" "small-model" "medium-model"
_slot_apply_dev_model_routing 42 "size:small"
applied_once="$DEV_MODEL"
_slot_apply_dev_model_routing 42 "size:small"
assert_eq "P3-9: 再適用しても解決結果は同一（冪等 / Req 1.8）" "$applied_once" "$DEV_MODEL"
cleanup_stub_state

# ════════════════════════════════════════════════════════════════════
# Wiring P4（grep ベース / 実行なし）: 設定値宣言と call site（Req 2.1 / 2.2 / 2.5 / 3.1 / 4.1 / 5.1）
# ════════════════════════════════════════════════════════════════════
echo ""
echo "--- Wiring P4: 設定値宣言 / slot-worker.sh call site (#508) ---"

# P4-1: DEV_MODEL_SMALL / DEV_MODEL_MEDIUM が既定空で宣言されている（Req 2.1 / 2.2 / NFR 3.4）
small_decl="$(grep -E '^DEV_MODEL_SMALL=' "$WATCHER_CONFIG_SH" || true)"
medium_decl="$(grep -E '^DEV_MODEL_MEDIUM=' "$WATCHER_CONFIG_SH" || true)"
# 期待値は「宣言行そのもの」のリテラルなので単一引用符での展開抑止が意図的（SC2016 抑止）。
# shellcheck disable=SC2016
assert_eq "P4-1: DEV_MODEL_SMALL は既定空で宣言される（Req 2.1 / 2.2）" \
  'DEV_MODEL_SMALL="${DEV_MODEL_SMALL:-}"' "$small_decl"
# shellcheck disable=SC2016
assert_eq "P4-1: DEV_MODEL_MEDIUM は既定空で宣言される（Req 2.1 / 2.2）" \
  'DEV_MODEL_MEDIUM="${DEV_MODEL_MEDIUM:-}"' "$medium_decl"

# P4-2: 具体的なモデル ID を既定値に埋め込まない（NFR 3.4）
model_id_hits=$( { grep -E '^DEV_MODEL_(SMALL|MEDIUM)=' "$WATCHER_CONFIG_SH" | grep -c 'claude-' || true; } )
assert_eq "P4-2: size 別モデルの既定値にモデル ID を埋め込まない（Req 2.2 / NFR 3.4）" \
  "0" "$((model_id_hits))"

# P4-3: 追加設定値は 2 個のみ（DEV_MODEL_LARGE 等を増やさない / Req 2.5 / Out of Scope）
large_decl_hits=$( { grep -cE '^DEV_MODEL_LARGE=' "$WATCHER_CONFIG_SH" || true; } )
assert_eq "P4-3: DEV_MODEL_LARGE は追加しない（large は DEV_MODEL / Req 1.3 / 2.5）" \
  "0" "$((large_decl_hits))"
new_decl_hits=$( { grep -cE '^DEV_MODEL_[A-Z]+=' "$WATCHER_CONFIG_SH" || true; } )
assert_eq "P4-3: 追加した DEV_MODEL_* 設定値は 2 個のみ（Req 2.5）" "2" "$((new_decl_hits))"

# P4-4: 既存 DEV_MODEL の宣言を変更していない（Req 2.4 / 2.6）
# shellcheck disable=SC2016
assert_contains "P4-4: DEV_MODEL の既定値・上書き方法は不変（Req 2.4）" \
  "$(grep -E '^DEV_MODEL=' "$WATCHER_CONFIG_SH" || true)" 'DEV_MODEL="${DEV_MODEL:-claude-opus-4-8}"'

# P4-5: Phase 2 用の追加 gate を設けていない（単一 gate / Req 5.1）
#       適用ヘルパーが参照する gate は mr_is_enabled（= MODEL_ROUTING_ENABLED）のみ。
apply_def_line=$(line_of '^_slot_apply_dev_model_routing\(\) \{' "$SLOT_WORKER_SH")
assert_rc "P4-5: slot-worker.sh に _slot_apply_dev_model_routing 定義がある" 0 \
  test "$apply_def_line" -gt 0
apply_body="$(extract_function "$SLOT_WORKER_SH" "_slot_apply_dev_model_routing")"
assert_contains "P4-5: 適用ヘルパーは family 共通 gate（mr_is_enabled）で制御される（Req 5.1）" \
  "$apply_body" "mr_is_enabled || return 0"
routing_gate_hits=$( { printf '%s\n' "$apply_body" | grep -cE '(MODEL_ROUTING|_ROUTING_ENABLED)' || true; } )
assert_eq "P4-5: 適用ヘルパー内で独自 gate 変数を参照しない（Req 5.1）" "0" "$((routing_gate_hits))"

# P4-6: 適用対象外（Reviewer / PjM / Triage / slot 外プロセッサ）に触れない（Req 3.8 / 3.9）
for v in REVIEWER_MODEL PJM_MODEL TRIAGE_MODEL PR_ITERATION_DEV_MODEL FAILED_RECOVERY_DEV_MODEL DEBUGGER_MODEL; do
  hits=$( { printf '%s\n' "$apply_body" | grep -c -- "$v" || true; } )
  assert_eq "P4-6: 適用ヘルパーは ${v} を参照しない（Req 3.8 / 3.9）" "0" "$((hits))"
  mr_hits=$( { grep -c -- "$v" "$MODEL_ROUTER_SH" || true; } )
  assert_eq "P4-6: model-router.sh は ${v} を参照しない（Req 3.8 / 3.9）" "0" "$((mr_hits))"
done

# P4-7: call site は 1 箇所のみ・LABELS 確定後・worktree 初期化前（Req 3.1 / 4.1 / NFR 2.4）
# grep へ渡す ERE リテラル中の `$` は展開させたくないため単一引用符が意図的（SC2016 抑止）。
# shellcheck disable=SC2016
apply_call_count=$( { grep -cE '^[[:space:]]*_slot_apply_dev_model_routing "\$NUMBER"' "$SLOT_WORKER_SH" || true; } )
assert_eq "P4-7: 適用ヘルパーの呼び出しは 1 箇所のみ（1 slot 実行 1 回 / Req 4.1 / NFR 2.4）" \
  "1" "$((apply_call_count))"
# shellcheck disable=SC2016
labels_line=$(line_of '^[[:space:]]*LABELS=\$\(echo "\$issue" \| jq -r' "$SLOT_WORKER_SH")
# shellcheck disable=SC2016
apply_call_line=$(line_of '^[[:space:]]*_slot_apply_dev_model_routing "\$NUMBER"' "$SLOT_WORKER_SH")
worktree_line=$(line_of '^[[:space:]]*if ! _worktree_ensure' "$SLOT_WORKER_SH")
assert_rc "P4-7: call site は LABELS 確定より後（起動時ラベル集合を入力にする / Req 3.1）" 0 \
  test "$apply_call_line" -gt "$labels_line"
assert_rc "P4-7: call site は worktree 初期化より前 = _slot_run_issue 冒頭（Req 3.1 / 3.6）" 0 \
  test "$apply_call_line" -lt "$worktree_line"

# P4-8: Triage 実行後の再解決を行わない（Req 4.3 / Out of Scope）
#       Triage 消費部（mr_persist_size_label 呼び出し）より前に 1 回だけ解決する。
assert_rc "P4-8: call site は Triage 消費部より前 = Triage 後の再解決をしない（Req 4.3）" 0 \
  test "$apply_call_line" -lt "$persist_line"

# P4-9: 既存の DEV_MODEL 個別 call site を書き換えていない（Out of Scope / NFR 1.3）
#       slot-worker.sh の `--model "$DEV_MODEL"` は従来どおり 1 箇所のまま。
# shellcheck disable=SC2016  # ERE リテラル中の `$` を展開させない意図
model_flag_hits=$( { grep -cE '^[[:space:]]*--model "\$DEV_MODEL" ' "$SLOT_WORKER_SH" || true; } )
assert_eq "P4-9: slot-worker.sh の --model \"\$DEV_MODEL\" は 1 箇所のまま（Out of Scope）" \
  "1" "$((model_flag_hits))"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
