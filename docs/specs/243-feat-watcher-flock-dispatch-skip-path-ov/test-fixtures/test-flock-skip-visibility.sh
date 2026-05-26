#!/usr/bin/env bash
# 用途: #243 flock skip 経路 path-overlap 可視化（po_run_flock_skip_visibility）の純ロジック
#       スモークテスト。mock gh 環境で opt-in gate / 専用ロック多重起動抑止 / 候補列挙クエリの
#       claim 除外句 / 候補列挙失敗時の fail-open / opt-in off の差分等価を検証する。
# 配置先: docs/specs/243-feat-watcher-flock-dispatch-skip-path-ov/test-fixtures/
# 依存: bash 4+, flock（Linux 標準 / macOS util-linux）, gh（本テストではスタブ化して実 API を
#       呼ばない）, jq（po_* が source 時に参照するが本テスト経路では使わない）
# セットアップ参照先: docs/specs/243-feat-watcher-flock-dispatch-skip-path-ov/design.md
#                     の Testing Strategy「Unit Tests（純ロジックスモーク）」節
#
# 実行: bash test-flock-skip-visibility.sh
#   全ケース PASS で exit 0、いずれか失敗で非ゼロ exit。
#
# shellcheck disable=SC2034  # LABEL_* / REPO / REPO_DIR 等は source した module 内の関数が参照する
# shellcheck disable=SC2317  # gh() スタブは module 内の関数から間接的に呼ばれる
set -euo pipefail

# ─── テスト対象モジュールの source ───
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE="${SCRIPT_DIR}/../../../../local-watcher/bin/modules/promote-pipeline.sh"

if [ ! -f "$MODULE" ]; then
  echo "FATAL: 対象モジュールが見つかりません: $MODULE" >&2
  exit 2
fi

# flock が解決できない環境では検証不能なので明示 skip（CI/cron 最小 PATH を想定）
if ! command -v flock >/dev/null 2>&1; then
  echo "SKIP: flock コマンドが見つからないため本スモークテストを skip します" >&2
  exit 0
fi

# ─── 自己完結な一時ディレクトリ（CI/cron を汚さない）───
TMP_DIR="$(mktemp -d)"
trap 'rm -f "$VISIBILITY_LOCK_FILE" 2>/dev/null || true; rm -rf "$TMP_DIR" 2>/dev/null || true' EXIT

# ─── 本体 Config ブロック相当の global 束縛（issue-watcher.sh と同値）───
LABEL_TRIGGER="auto-dev"
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
LABEL_AWAITING_SLOT="awaiting-slot"
LABEL_BLOCKED="blocked"
REPO="owner/test"
REPO_DIR="$TMP_DIR"
LOG_DIR="$TMP_DIR"
BASE_BRANCH="main"
PROMOTION_TARGET_BRANCH="main"
VISIBILITY_LOCK_FILE="${TMP_DIR}/flock-skip-visibility.lock"
PATH_OVERLAP_VISIBILITY_LOCK_FILE="$VISIBILITY_LOCK_FILE"

# module を source（関数定義のみ取り込む。本体側 set -euo pipefail 宣言は本ファイル冒頭で済）
# shellcheck source=/dev/null
. "$MODULE"

# ─── mock gh の呼び出し記録ファイル ───
# GH_CALL_LOG       : gh が受け取った全 argv を 1 行 1 呼び出しで記録（呼び出し有無/引数検証用）
# GH_SEARCH_CAPTURE : `gh issue list --search <query>` の query を捕捉
# GH_LIST_SHOULD_FAIL : "1" のとき `gh issue list` を非 0 exit させ fail-open を検証
GH_CALL_LOG="${TMP_DIR}/gh-calls.log"
GH_SEARCH_CAPTURE="${TMP_DIR}/gh-search.txt"
GH_LIST_SHOULD_FAIL="0"
: > "$GH_CALL_LOG"
: > "$GH_SEARCH_CAPTURE"

# mock gh: 実 API を呼ばず、呼び出し argv を記録しつつ最小限の JSON を返す。
gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  local sub="${1:-}" obj="${2:-}"
  local prev="" arg
  for arg in "$@"; do
    if [ "$prev" = "--search" ]; then
      printf '%s' "$arg" > "$GH_SEARCH_CAPTURE"
    fi
    prev="$arg"
  done
  if [ "$sub" = "issue" ] && [ "$obj" = "list" ]; then
    if [ "$GH_LIST_SHOULD_FAIL" = "1" ]; then
      return 1
    fi
    # 候補 0 件の空配列（候補ループには入らない = 評価コアを呼ばない）
    echo '[]'
    return 0
  fi
  if [ "$sub" = "issue" ] && [ "$obj" = "view" ]; then
    echo '{"comments":[]}'
    return 0
  fi
  # その他（edit / comment / api）は best-effort 成功扱い
  return 0
}

# ─── アサーションヘルパー ───
PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() {
  echo "FAIL: $1" >&2
  shift
  local line
  for line in "$@"; do echo "  $line" >&2; done
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

reset_mock() {
  : > "$GH_CALL_LOG"
  : > "$GH_SEARCH_CAPTURE"
  GH_LIST_SHOULD_FAIL="0"
}

# gh が一度も呼ばれていないこと
assert_no_gh_call() {
  local name="$1"
  if [ -s "$GH_CALL_LOG" ]; then
    fail "$name" "expected: gh 未呼び出し" "actual: gh が呼ばれた:" "$(cat "$GH_CALL_LOG")"
  else
    pass "$name"
  fi
}

# 状態変更系 gh 呼び出し（add-label / remove-label / comment / api PATCH）が無いこと
assert_no_mutating_gh_call() {
  local name="$1"
  if grep -Eq -- '--add-label|--remove-label|issue comment|api -X PATCH' "$GH_CALL_LOG" 2>/dev/null; then
    fail "$name" "expected: 状態変更系 gh 呼び出しなし" "actual:" "$(grep -E -- '--add-label|--remove-label|issue comment|api -X PATCH' "$GH_CALL_LOG")"
  else
    pass "$name"
  fi
}

# ─────────────────────────────────────────────────────────────────────────
# Case 1: opt-in gate — PATH_OVERLAP_CHECK が off/未設定/不正値で gh を呼ばず return 0
#         （Req 6.1 / 6.2 / NFR 1.1）
# ─────────────────────────────────────────────────────────────────────────
for gate_val in "off" "__UNSET__" "enabled" "True" "1"; do
  reset_mock
  if [ "$gate_val" = "__UNSET__" ]; then
    unset PATH_OVERLAP_CHECK
    label="未設定"
  else
    PATH_OVERLAP_CHECK="$gate_val"
    label="$gate_val"
  fi
  rc=0
  po_run_flock_skip_visibility >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "Req6.1 opt-in gate (${label}) は return 0" "expected rc=0" "actual rc=${rc}"
  else
    pass "Req6.1 opt-in gate (${label}) は return 0"
  fi
  assert_no_gh_call "Req6.1/NFR1.1 opt-in gate (${label}) は gh を 1 度も呼ばない"
  assert_no_mutating_gh_call "Req6.2 opt-in gate (${label}) は状態変更系 gh を呼ばない（差分等価）"
done

# ─────────────────────────────────────────────────────────────────────────
# Case 2: 専用ロックの多重起動抑止 — 同一 lock file を別 fd が保持中のとき flock -n 201 が
#         失敗し、抑止ログ（route=flock-skip visibility skipped）を出して return 0
#         （Req 4.1 / 4.2）
# ─────────────────────────────────────────────────────────────────────────
reset_mock
PATH_OVERLAP_CHECK="true"
# 別 fd（210）で lock file を保持し非ブロッキングロックを取得しておく
exec 210>"$VISIBILITY_LOCK_FILE"
if flock -n 210; then
  STDERR_CAP="${TMP_DIR}/case2-stderr.txt"
  STDOUT_CAP="${TMP_DIR}/case2-stdout.txt"
  rc=0
  po_run_flock_skip_visibility >"$STDOUT_CAP" 2>"$STDERR_CAP" || rc=$?
  # 抑止ログは po_log（stdout）に出る
  combined="$(cat "$STDOUT_CAP" "$STDERR_CAP")"
  if [ "$rc" -ne 0 ]; then
    fail "Req4.1 多重起動抑止時は return 0" "expected rc=0" "actual rc=${rc}"
  else
    pass "Req4.1 多重起動抑止時は return 0"
  fi
  if printf '%s' "$combined" | grep -q 'route=flock-skip visibility skipped'; then
    pass "Req4.2 多重起動抑止時に識別可能な抑止ログを出力する"
  else
    fail "Req4.2 多重起動抑止時に識別可能な抑止ログを出力する" "expected: 'route=flock-skip visibility skipped' を含む" "actual:" "$combined"
  fi
  assert_no_gh_call "Req4.1 多重起動抑止時は候補列挙（gh）に進まない"
  # 保持していた lock を解放
  exec 210>&- 2>/dev/null || true
else
  fail "Req4.1/4.2 テスト前提の lock 取得に失敗（環境問題）" "別 fd での flock -n 210 が取得できなかった"
  exec 210>&- 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────────────
# Case 3: 候補列挙クエリの claim 除外 — 構築する gh issue list --search 句に
#         claude-claimed / claude-picked-up の除外（-label:）が含まれる（Req 2.4）
# ─────────────────────────────────────────────────────────────────────────
reset_mock
PATH_OVERLAP_CHECK="true"
po_run_flock_skip_visibility >/dev/null 2>&1 || true
CAPTURED_SEARCH="$(cat "$GH_SEARCH_CAPTURE")"
if printf '%s' "$CAPTURED_SEARCH" | grep -q -- '-label:"claude-claimed"'; then
  pass "Req2.4 候補列挙クエリに claude-claimed 除外句が含まれる"
else
  fail "Req2.4 候補列挙クエリに claude-claimed 除外句が含まれる" "expected: '-label:\"claude-claimed\"' を含む" "actual:" "$CAPTURED_SEARCH"
fi
if printf '%s' "$CAPTURED_SEARCH" | grep -q -- '-label:"claude-picked-up"'; then
  pass "Req2.4 候補列挙クエリに claude-picked-up 除外句が含まれる"
else
  fail "Req2.4 候補列挙クエリに claude-picked-up 除外句が含まれる" "expected: '-label:\"claude-picked-up\"' を含む" "actual:" "$CAPTURED_SEARCH"
fi
# 候補列挙そのものは LABEL_TRIGGER（auto-dev）に対して open で行われること
if grep -q -- '--label auto-dev' "$GH_CALL_LOG" && grep -q -- '--state open' "$GH_CALL_LOG"; then
  pass "Req2.4 候補列挙は auto-dev ラベル × open で read-only に実行される"
else
  fail "Req2.4 候補列挙は auto-dev ラベル × open で read-only に実行される" "expected: '--label auto-dev' と '--state open' を含む" "actual:" "$(cat "$GH_CALL_LOG")"
fi

# ─────────────────────────────────────────────────────────────────────────
# Case 4: fail-open — 候補列挙 mock が失敗（非 0 exit）したとき return 0（NFR 3.2）
# ─────────────────────────────────────────────────────────────────────────
reset_mock
PATH_OVERLAP_CHECK="true"
GH_LIST_SHOULD_FAIL="1"
rc=0
po_run_flock_skip_visibility >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
  pass "NFR3.2 候補列挙失敗でも return 0（fail-open）"
else
  fail "NFR3.2 候補列挙失敗でも return 0（fail-open）" "expected rc=0" "actual rc=${rc}"
fi
assert_no_mutating_gh_call "NFR3.2 候補列挙失敗時は状態変更系 gh を呼ばない"

# ─────────────────────────────────────────────────────────────────────────
# Case 5: 差分等価 — opt-in off の flock skip 経路が exit 0 / 状態変更副作用なし
#         （Req 6.1 / 6.2 / NFR 1.1）。本体 flock skip ブロックの gate 相当を再現する。
# ─────────────────────────────────────────────────────────────────────────
reset_mock
# 本体 issue-watcher.sh:590-592 の gate を再現（off なら関数を呼ばない）
PATH_OVERLAP_CHECK="off"
rc=0
if [ "${PATH_OVERLAP_CHECK:-off}" = "true" ]; then
  po_run_flock_skip_visibility >/dev/null 2>&1 || true
fi
# gate を通らないため exit code 相当は 0、副作用なし
if [ "$rc" -eq 0 ] && [ ! -s "$GH_CALL_LOG" ]; then
  pass "NFR1.1 opt-in off では flock skip フックが関数を呼ばず副作用ゼロ（差分等価）"
else
  fail "NFR1.1 opt-in off では flock skip フックが関数を呼ばず副作用ゼロ（差分等価）" "expected: gh 未呼び出し" "actual:" "$(cat "$GH_CALL_LOG")"
fi

# ─── 結果サマリ ───
echo "----"
echo "PASS=${PASS_COUNT} FAIL=${FAIL_COUNT}"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
