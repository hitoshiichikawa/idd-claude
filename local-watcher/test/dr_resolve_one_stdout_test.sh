#!/usr/bin/env bash
#
# 用途: Issue #392 の回帰防止テスト。dr_resolve_one の全 5 経路で stdout が
#       「resolved / open / closed unmerged / api error の厳密 1 行のみ」で
#       あること、および dr_log 出力が stdout を汚染しないことを実 stdout 捕捉
#       で検証する。
#
#       既存 dr_unblock_sweep_test.sh は dr_resolve_one / dr_log を stub で
#       置き換えていたため、本 Issue の根因（dr_log の stdout echo）を見逃して
#       きた。本テストは実体 dr_resolve_one + 実体 dr_log を extract_function で
#       隔離抽出して読み込み、gh のみを stub することで実 stdout を観測する。
#
#       検証する AC（docs/specs/392-fix-dr-dr-log-stdout-staged-for-release/
#       requirements.md）:
#         - Req 1.1: dr_log 出力先が stderr で stdout に 1 文字も書かない
#         - Req 1.2: dr_warn 出力先が stderr で stdout に 1 文字も書かない
#         - Req 1.3: OPEN + staged-for-release → stdout が厳密に "resolved\n"
#         - Req 1.4: OPEN + ラベル無し → stdout が厳密に "open\n"
#         - Req 1.5: CLOSED + merged PR 1 件以上 → stdout が厳密に "resolved\n"
#         - Req 1.6: CLOSED + merged PR ゼロ件 → stdout が厳密に "closed unmerged\n"
#         - Req 1.7: GraphQL errors / jq parse 失敗 → stdout が厳密に "api error\n"
#         - Req 1.8: 呼び出し側で verdict=$(dr_resolve_one ...) を実行したとき
#                    捕捉文字列が 4 値のいずれかと完全一致（未知 verdict に落ちない）
#         - Req 5.1: 全 5 終端パスで stdout = verdict 文字列ちょうど 1 行のみ
#         - Req 7.2 / 7.3: staged-for-release 解決パスで verdict=resolved、
#                          dr_log 行は stderr 経由のみで観測される
#         - Req 7.4: 5 経路の stdout 厳密一致
#         - NFR 3.1: dr_log フォーマット `[YYYY-MM-DD HH:MM:SS] dr: <message>` 維持
#
# 配置先: local-watcher/test/dr_resolve_one_stdout_test.sh
# 依存:   bash 4+, awk, jq, grep
# 実行:   bash local-watcher/test/dr_resolve_one_stdout_test.sh

set -euo pipefail

# 本テストは抽出関数（dr_resolve_one / dr_log / dr_warn / dr_error /
# dr_gh_graphql_closed_by）と stub から indirect 参照される変数を多用するため、
# static 解析（shellcheck）からは未使用に見える。本ファイル全体で SC2034 を抑止する。
# shellcheck disable=SC2034

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHER_SH="$SCRIPT_DIR/../bin/issue-watcher.sh"

if [ ! -f "$WATCHER_SH" ]; then
  echo "ERROR: cannot find issue-watcher.sh at $WATCHER_SH" >&2
  exit 2
fi

# 既存テストと同じイディオム: 対象スクリプトから 1 関数だけを awk で切り出して
# eval で読み込む。トップレベル副作用は回避する。
extract_function() {
  local script="$1"
  local fn_name="$2"
  awk -v fn="${fn_name}() {" '
    $0 == fn { in_fn = 1 }
    in_fn { print }
    in_fn && $0 == "}" { in_fn = 0 }
  ' "$script"
}

# 対象関数群を読み込む。dr_resolve_one が dr_gh_graphql_closed_by / dr_log /
# dr_warn を呼ぶため、実体を抽出して読み込む（本 Issue の根因は dr_log 実体の
# stdout echo であり、stub に置き換えると見逃すため）。
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_log")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_warn")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_error")"
# shellcheck disable=SC1090,SC2086
eval "$(extract_function "$WATCHER_SH" "dr_resolve_one")"

# dr_gh_graphql_closed_by は stub で置き換える（実 GraphQL は叩かない）。
# このため本来の関数は読み込まず、後段でテスト stub として再定義する。

for fn in dr_log dr_warn dr_error dr_resolve_one; do
  if ! declare -F "$fn" >/dev/null; then
    echo "ERROR: $fn not loaded" >&2
    exit 2
  fi
done

# グローバル env（dr_resolve_one が遅延束縛で参照）
# shellcheck disable=SC2034
REPO="owner/test-repo"
# Req 1.3 では BASE_BRANCH != main で staged-for-release 解決パスを起こすため、
# デフォルトは develop に設定（個別ケースで override）。
# shellcheck disable=SC2034
BASE_BRANCH="develop"
# shellcheck disable=SC2034
LABEL_STAGED_FOR_RELEASE="staged-for-release"
# shellcheck disable=SC2034
DRR_GH_TIMEOUT="60"
# shellcheck disable=SC2034
MERGE_QUEUE_GIT_TIMEOUT="60"

PASS_COUNT=0
FAIL_COUNT=0

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

assert_empty() {
  local label="$1"
  local actual="$2"
  if [ -z "$actual" ]; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label (expected empty)"
    echo "  actual: $(printf '%q' "$actual")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# ── stub: dr_gh_graphql_closed_by ──
# DR_FIXTURE_RESPONSE 変数の内容を stdout にそのまま返し、DR_FIXTURE_RC で
# 終了コードを制御する。
# shellcheck disable=SC2317
dr_gh_graphql_closed_by() {
  printf '%s' "${DR_FIXTURE_RESPONSE:-}"
  return "${DR_FIXTURE_RC:-0}"
}

# ── timeout stub ──
# dr_resolve_one は dr_gh_graphql_closed_by を内部で `timeout ... gh api graphql`
# 形式で呼ばないため stub 不要だが、後方互換のためテスト中も timeout は不要。
# （dr_resolve_one は dr_gh_graphql_closed_by を `response=$(dr_gh_graphql_closed_by ...)`
# で呼ぶだけ。timeout は dr_gh_graphql_closed_by の **内部** にあり、本テストが
# それを stub する以上、timeout は起動されない）

# ============================================================
# Helper: stdout / stderr を別々に捕捉して dr_resolve_one を呼ぶ
# ============================================================
# 引数: $1 = 依存 Issue 番号（数字のみ）
# 戻り値（output vars）:
#   CAPTURED_STDOUT = dr_resolve_one の stdout
#   CAPTURED_STDERR = dr_resolve_one の stderr
capture_dr_resolve_one() {
  local issue_num="$1"
  local stderr_file
  stderr_file=$(mktemp)
  # dr_resolve_one の stdout を $() で捕捉、stderr は一時ファイルへ
  CAPTURED_STDOUT=$(dr_resolve_one "$issue_num" 2>"$stderr_file")
  CAPTURED_STDERR=$(cat "$stderr_file")
  rm -f "$stderr_file"
}

# ============================================================
# Case 1: OPEN + staged-for-release（BASE_BRANCH=develop / Req 1.3, 1.8, 7.2, 7.3）
# 本 Issue (#392) の根因経路。dr_log が stdout を汚染すれば $verdict が
# 「ログ行 + resolved」になり厳密一致 assert で失敗する。
# ============================================================
echo "--- Case 1: OPEN + staged-for-release (Req 1.3 / 1.8 / 7.2 / 7.3) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "OPEN",
        "labels": {
          "nodes": [
            {"name": "auto-dev"},
            {"name": "staged-for-release"}
          ]
        },
        "closedByPullRequestsReferences": {"nodes": []}
      }
    }
  }
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 117

# Req 1.3 / 7.2 / 7.4: stdout が厳密に "resolved" のみ（末尾改行を除き他文字を含まない）
assert_eq "Req 1.3 / 7.4: OPEN + staged-for-release stdout 厳密に 'resolved'" \
  "resolved" "$CAPTURED_STDOUT"
# Req 1.8: verdict=$(...) で捕捉した値が `unknown verdict` の 4 値以外に落ちない
case "$CAPTURED_STDOUT" in
  "resolved"|"open"|"closed unmerged"|"api error")
    echo "PASS: Req 1.8: verdict が 4 値集合と完全一致"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
  *)
    echo "FAIL: Req 1.8: verdict が 4 値集合外 → 未知 verdict 分岐に落ちる"
    echo "  captured: $(printf '%q' "$CAPTURED_STDOUT")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
esac
# Req 7.3: dr_log 行は stderr 経由のみで観測される
assert_contains "Req 7.3 / NFR 3.1: dr_log 行が stderr に出ている（フォーマット維持）" \
  "$CAPTURED_STDERR" "dr: issue=#117 verdict=resolved reason=staged-for-release base=develop"
# Req 1.1 / 7.2: dr_log 行が stdout に紛れ込まない（汚染ゼロの強い検証）
case "$CAPTURED_STDOUT" in
  *"dr:"*|*"reason=staged-for-release"*|*"verdict=resolved"*)
    echo "FAIL: Req 1.1 / 7.2: dr_log 行が stdout に紛れ込んでいる（汚染ゼロ違反）"
    echo "  stdout: $(printf '%q' "$CAPTURED_STDOUT")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: Req 1.1 / 7.2: dr_log 行が stdout に含まれない（stdout 汚染ゼロ）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac

# ============================================================
# Case 2: OPEN + staged-for-release ラベル無し（Req 1.4 / 7.4）
# ============================================================
echo ""
echo "--- Case 2: OPEN + ラベル無し (Req 1.4 / 7.4) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "OPEN",
        "labels": {
          "nodes": [
            {"name": "auto-dev"}
          ]
        },
        "closedByPullRequestsReferences": {"nodes": []}
      }
    }
  }
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 200

assert_eq "Req 1.4 / 7.4: OPEN + ラベル無し stdout 厳密に 'open'" \
  "open" "$CAPTURED_STDOUT"

# ============================================================
# Case 2b: OPEN + BASE_BRANCH=main（後方互換 / Req 3.2）
# BASE_BRANCH=main では staged-for-release ラベルがあっても open を返す（既存挙動維持）
# ============================================================
echo ""
echo "--- Case 2b: OPEN + BASE_BRANCH=main (Req 3.2 後方互換) ---"

BASE_BRANCH="main"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "OPEN",
        "labels": {
          "nodes": [
            {"name": "staged-for-release"}
          ]
        },
        "closedByPullRequestsReferences": {"nodes": []}
      }
    }
  }
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 300

assert_eq "Req 3.2: BASE_BRANCH=main では staged-for-release を読まず 'open'（既存挙動）" \
  "open" "$CAPTURED_STDOUT"

# ============================================================
# Case 3: CLOSED + merged PR 1 件以上（Req 1.5 / 7.4）
# ============================================================
echo ""
echo "--- Case 3: CLOSED + merged PR 1 件以上 (Req 1.5 / 7.4) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "CLOSED",
        "labels": {"nodes": []},
        "closedByPullRequestsReferences": {
          "nodes": [
            {"number": 1001, "state": "MERGED"}
          ]
        }
      }
    }
  }
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 400

assert_eq "Req 1.5 / 7.4: CLOSED + merged PR 1 件以上 stdout 厳密に 'resolved'" \
  "resolved" "$CAPTURED_STDOUT"

# ============================================================
# Case 4: CLOSED + merged PR ゼロ件（Req 1.6 / 7.4）
# ============================================================
echo ""
echo "--- Case 4: CLOSED + merged PR ゼロ件 (Req 1.6 / 7.4) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "CLOSED",
        "labels": {"nodes": []},
        "closedByPullRequestsReferences": {
          "nodes": [
            {"number": 1002, "state": "CLOSED"}
          ]
        }
      }
    }
  }
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 500

assert_eq "Req 1.6 / 7.4: CLOSED + merged PR ゼロ件 stdout 厳密に 'closed unmerged'" \
  "closed unmerged" "$CAPTURED_STDOUT"

# 空配列ケース
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "data": {
    "repository": {
      "issue": {
        "state": "CLOSED",
        "labels": {"nodes": []},
        "closedByPullRequestsReferences": {"nodes": []}
      }
    }
  }
}')
capture_dr_resolve_one 501
assert_eq "Req 1.6 / 7.4: CLOSED + 空配列 stdout 厳密に 'closed unmerged'" \
  "closed unmerged" "$CAPTURED_STDOUT"

# ============================================================
# Case 5: GraphQL errors 検知（Req 1.7 / 7.4）
# ============================================================
echo ""
echo "--- Case 5: GraphQL errors 検知 (Req 1.7 / 7.4) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=$(jq -cn '{
  "errors": [
    {"message": "Issue not found"}
  ]
}')
DR_FIXTURE_RC=0

capture_dr_resolve_one 600

assert_eq "Req 1.7 / 7.4: GraphQL errors 検知 stdout 厳密に 'api error'" \
  "api error" "$CAPTURED_STDOUT"

# ============================================================
# Case 6: jq parse 失敗（不正な JSON 応答 / Req 1.7 / 7.4）
# ============================================================
echo ""
echo "--- Case 6: jq parse 失敗 (Req 1.7 / 7.4) ---"

BASE_BRANCH="develop"
# 不正な JSON 文字列を返して jq parse 失敗を再現
DR_FIXTURE_RESPONSE="this is not valid json at all"
DR_FIXTURE_RC=0

capture_dr_resolve_one 700

assert_eq "Req 1.7 / 7.4: 不正 JSON 応答 stdout 厳密に 'api error'" \
  "api error" "$CAPTURED_STDOUT"

# state が null の想定外応答
DR_FIXTURE_RESPONSE=$(jq -cn '{"data": {"repository": {"issue": null}}}')
capture_dr_resolve_one 701
assert_eq "Req 1.7 / 7.4: issue=null の想定外応答 stdout 厳密に 'api error'" \
  "api error" "$CAPTURED_STDOUT"

# ============================================================
# Case 7: gh GraphQL 失敗（rc != 0 / Req 1.7）
# ============================================================
echo ""
echo "--- Case 7: gh GraphQL 失敗 rc!=0 (Req 1.7) ---"

BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE="gh: API rate limit exceeded"
DR_FIXTURE_RC=1

capture_dr_resolve_one 800

assert_eq "Req 1.7: gh GraphQL rc!=0 stdout 厳密に 'api error'" \
  "api error" "$CAPTURED_STDOUT"
# dr_warn が stderr に出ていることも確認（NFR 3.1 既存挙動）
assert_contains "Req 1.2 / NFR 3.1: gh rc!=0 で dr_warn が stderr に WARN: ... を出力" \
  "$CAPTURED_STDERR" "dr: WARN:"
# Req 1.2: dr_warn 行が stdout を汚染しない
case "$CAPTURED_STDOUT" in
  *"WARN:"*|*"gh api graphql"*)
    echo "FAIL: Req 1.2: dr_warn 行が stdout に紛れ込んでいる"
    echo "  stdout: $(printf '%q' "$CAPTURED_STDOUT")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    ;;
  *)
    echo "PASS: Req 1.2: dr_warn 行が stdout に含まれない（stdout 汚染ゼロ）"
    PASS_COUNT=$((PASS_COUNT + 1))
    ;;
esac

# ============================================================
# Case 8: dr_log / dr_warn 直接呼び出しの stdout 汚染ゼロ検証
# （Req 1.1 / 1.2 ロガー単体の出力先確認）
# ============================================================
echo ""
echo "--- Case 8: dr_log / dr_warn 単体の stdout 汚染ゼロ (Req 1.1 / 1.2) ---"

# dr_log の出力先を厳密に検証する
log_stderr_file=$(mktemp)
log_stdout=$(dr_log "test message 1.1" 2>"$log_stderr_file")
log_stderr=$(cat "$log_stderr_file")
rm -f "$log_stderr_file"

assert_empty "Req 1.1: dr_log の stdout は厳密に空" "$log_stdout"
assert_contains "Req 1.1 / NFR 3.1: dr_log の stderr に message が含まれフォーマット維持" \
  "$log_stderr" "dr: test message 1.1"

# dr_warn の出力先を厳密に検証する
warn_stderr_file=$(mktemp)
warn_stdout=$(dr_warn "test warn 1.2" 2>"$warn_stderr_file")
warn_stderr=$(cat "$warn_stderr_file")
rm -f "$warn_stderr_file"

assert_empty "Req 1.2: dr_warn の stdout は厳密に空" "$warn_stdout"
assert_contains "Req 1.2 / NFR 3.1: dr_warn の stderr に WARN: が含まれフォーマット維持" \
  "$warn_stderr" "dr: WARN: test warn 1.2"

# dr_error の出力先確認（Req 4.3 既存挙動維持）
err_stderr_file=$(mktemp)
err_stdout=$(dr_error "test error 4.3" 2>"$err_stderr_file")
err_stderr=$(cat "$err_stderr_file")
rm -f "$err_stderr_file"

assert_empty "Req 4.3: dr_error の stdout は厳密に空（既存挙動維持）" "$err_stdout"
assert_contains "Req 4.3: dr_error の stderr に ERROR: が含まれる（既存挙動維持）" \
  "$err_stderr" "dr: ERROR: test error 4.3"

# ============================================================
# Case 9: REPO env 不正で api error（Req 1.7 / 補助）
# ============================================================
echo ""
echo "--- Case 9: REPO env 不正 (Req 1.7) ---"

REPO="invalid-no-slash"
# shellcheck disable=SC2034
BASE_BRANCH="develop"
DR_FIXTURE_RESPONSE=""
DR_FIXTURE_RC=0

capture_dr_resolve_one 900

assert_eq "Req 1.7: REPO env 不正で stdout 厳密に 'api error'" \
  "api error" "$CAPTURED_STDOUT"

# REPO を元に戻す（テストはここで終了なので未使用になるが、対象 var が遅延束縛で
# 必要な場合に備えて明示的に復元する慣行を残す。shellcheck の SC2034 警告は抑止）
# shellcheck disable=SC2034
REPO="owner/test-repo"

echo ""
echo "==========================================="
echo "PASS: $PASS_COUNT, FAIL: $FAIL_COUNT"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
