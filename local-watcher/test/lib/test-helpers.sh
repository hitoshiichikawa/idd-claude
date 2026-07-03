#!/usr/bin/env bash
# =============================================================================
# idd-claude test helpers（#474）
#
# local-watcher/test/*.sh の大多数が個別にコピーしていた extract_function /
# assert_eq / assert_contains / assert_rc を集約する共有ライブラリ。各テストは
# 先頭の SCRIPT_DIR 解決の直後に
#   . "$SCRIPT_DIR/lib/test-helpers.sh"
# として source する。トップレベル副作用なし（関数定義のみ）。PASS_COUNT /
# FAIL_COUNT の初期化・最終サマリ出力・exit は各テストに残置する（テストごとに
# サマリ表記が異なり、一律の共通化は表示文言を変えてしまうため対象外とした。
# 詳細は #474 PR 本文「確認事項」参照）。
#
# 配置先: local-watcher/test/lib/test-helpers.sh
# 依存: 呼び出し側テストが PASS_COUNT / FAIL_COUNT をグローバル変数として
#       事前初期化していること（`PASS_COUNT=0` / `FAIL_COUNT=0`）。
#
# 対象外（各テストにそのまま残置。無理に共通化しない）:
#   - 引数順序 / メッセージ文言 / カウンタ変数名が多数派と異なる assert_eq /
#     assert_contains / assert_rc（call site 変換すると出力文言が変わってしまうため）
#   - assert_contains / assert_rc 以外の assert_* ヘルパー（assert_not_contains /
#     assert_grep 等。単一テストにしか無い、または #474 issue 本文で明示されていない）
# =============================================================================

# extract_function <script> <fn_name> [<extra_script>...]
#   対象スクリプトから 1 関数だけを awk で切り出して stdout に返す（eval 用イディオム）。
#   fn_name が <script> 内に見つからない場合に備え、<extra_script> を追加で渡すと
#   同じ awk 呼び出しで追加検索する（#177 以降の module 分割で定義が別ファイルへ
#   移動したテスト向け。多数派の 2 引数呼び出しは shift 2 後の "$@" が空になるだけで
#   挙動は従来と完全に同一）。
extract_function() {
  local script="$1"
  local fn_name="$2"
  shift 2
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script" "$@"
}

# assert_eq <label> <expected> <actual>
#   $expected と $actual を文字列比較し、PASS/FAIL を stdout に記録して
#   PASS_COUNT / FAIL_COUNT を加算する。
assert_eq() {
  local label="$1"
  local expected="$2"
  local actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $(printf '%q' "$expected")"
    echo "  actual  : $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# assert_contains <label> <haystack> <needle>
#   $haystack に $needle が部分文字列として含まれるかを判定する。
assert_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  case "$haystack" in
    *"$needle"*)
      echo "PASS: $label"
      PASS_COUNT=$((PASS_COUNT + 1))
      ;;
    *)
      echo "FAIL: $label"
      echo "  expected to contain: $(printf '%q' "$needle")"
      echo "  actual             : $(printf '%q' "$haystack")"
      FAIL_COUNT=$((FAIL_COUNT + 1))
      ;;
  esac
}

# assert_rc <label> <expected_rc> <cmd...>
#   <cmd...> を実行し、その終了コードが <expected_rc> と一致するかを判定する。
assert_rc() {
  local label="$1"
  local expected_rc="$2"
  shift 2
  local actual_rc=0
  "$@" >/dev/null 2>&1 || actual_rc=$?
  if [ "$expected_rc" = "$actual_rc" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  expected rc: $expected_rc"
    echo "  actual rc  : $actual_rc"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}
