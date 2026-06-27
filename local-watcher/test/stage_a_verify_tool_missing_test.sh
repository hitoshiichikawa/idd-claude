#!/usr/bin/env bash
#
# 本テストの fake 依存（gh / mark_issue_failed）は eval / source で読み込んだ
# stage_a_verify_run や _sav_handle_failure から間接的にのみ呼ばれるため
# 静的解析からは unreachable 扱いになる。env var（NUMBER, REPO, LOG,
# REPO_DIR, SPEC_DIR_REL 等）も同関数から参照されるため unused 扱いになる。
# いずれも false positive のためファイル全体で抑止する（既存
# stage_a_verify_path_missing_test.sh と同じ扱い）。
# shellcheck disable=SC2317,SC2034
#
# 用途: local-watcher/bin/modules/stage-a-verify.sh の Issue #422（verify コマンドの
#       exit 127 (tool-missing) を WARN 降格して claude-failed 昇格を抑止する挙動）を
#       検証するスモークテスト。
#
#       対象関数:
#         - _sav_is_tool_missing_failure  (#422 Req 1.1 / NFR 3.1 / NFR 3.2)
#         - _sav_extract_tool_name_from_cmd (#422 Req 4.3)
#         - stage_a_verify_run            (#422 Req 1.1〜1.5 / 2.1〜2.5 / 3.1〜3.5 / 4.1〜4.5)
#
#       検証する AC（docs/specs/422--bug-stage-a-verify-verify-exit-127-veri/
#                    requirements.md）:
#         - Req 1.1: exit 127 → round counter bump せず WARN 降格、戻り値 0
#         - Req 1.2: WARN 降格時に Stage A を完了状態として続行（戻り値 0 契約）
#         - Req 1.3: WARN 降格時に gh issue comment による差し戻し投稿なし
#         - Req 1.4: _SAV_LAST_OUTCOME=warn-tool-missing で新規 outcome 露出
#         - Req 1.5: STAGE_A_VERIFY_COMMAND env 経路の exit 127 も同一 WARN 降格
#         - Req 2.1: 連結先頭で exit 127 → 全体 127 → WARN 降格
#         - Req 2.2: 連結途中で exit 127 → 全体 127 → WARN 降格
#         - Req 2.3: 連結全体 exit 127 → WARN 降格
#         - Req 2.4: real fail (exit=1) と 127 混在 → 最終 exit=1 → 従来 round1
#         - Req 2.5: timeout (exit=124) → 既存 timeout 経路維持
#         - Req 3.1: exit 0 → SUCCESS 既存挙動維持
#         - Req 3.2: exit 124 → timeout 既存挙動維持（Req 2.5 と重複）
#         - Req 3.3: exit 2 + diff path-missing → warn-skipped 既存挙動維持
#         - Req 3.4: exit 1 → real fail 既存挙動維持（round1）
#         - Req 3.5: その他 (exit=130 等) → real fail 既存挙動維持
#         - Req 4.1: WARN 行を `grep '\[.*\] stage-a-verify: WARN'` で抽出可能
#         - Req 4.2: reason=verify-tool-missing 文字列を含む
#         - Req 4.3: 推定ツール名または cmd 断片を含む（情報源あり時）
#         - Req 4.4: outcome=warn-tool-missing を warn-skipped と区別
#         - Req 4.5: WARN 行に exit=127 とコマンド断片を含む
#         - NFR 1.1〜1.3: 既存契約・後方互換維持（DISABLED / 既存 outcome / exit code）
#         - NFR 2.1〜2.3: 既存テスト 3 本の pass 維持（本テスト単独では確認しないが、
#                        実装方針として共存を意識）
#         - NFR 3.1, 3.2: 純粋関数性（extract_function 隔離抽出と同等）
#         - NFR 4.1, 4.2: `stage-a-verify:` prefix 維持 / 1 行記録
#
# 配置先: local-watcher/test/stage_a_verify_tool_missing_test.sh
# 依存:   bash 4+, awk, sed, grep
# 実行:   bash local-watcher/test/stage_a_verify_tool_missing_test.sh
# 前提:   stage-a-verify.sh は関数定義のみでトップレベル副作用を持たないため source する。
#         _sav_handle_failure → mark_issue_failed の cross-module 呼び出しは本テスト内で
#         stub する（gh も同様）。round counter の state dir / source sidecar は mktemp
#         で隔離する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/stage-a-verify.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find stage-a-verify.sh at $MODULE_SH" >&2
  exit 2
fi

# モジュールを source（関数定義のみのファイル）。set -euo pipefail はテスト側で既に宣言済み。
# shellcheck disable=SC1090
source "$MODULE_SH"

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
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label"
    echo "  needle  : $(printf '%q' "$needle")"
    echo "  haystack: $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

assert_not_contains() {
  local label="$1"
  local needle="$2"
  local haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    echo "FAIL: $label"
    echo "  needle (should NOT contain): $(printf '%q' "$needle")"
    echo "  haystack                  : $(printf '%q' "$haystack")"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "PASS: $label"
    PASS_COUNT=$((PASS_COUNT + 1))
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: _sav_is_tool_missing_failure 単体テスト（純粋関数 / Req 1.1 / NFR 3.1）
# ─────────────────────────────────────────────────────────────────────────────

echo "================================================================"
echo "Section 1: _sav_is_tool_missing_failure 単体テスト"
echo "================================================================"

# Case 1.1: exit=127 → rc=0（tool-missing として WARN 対象）
rc=0
_sav_is_tool_missing_failure 127 || rc=$?
assert_eq "Req 1.1: exit=127 → rc=0（WARN 対象）" "0" "$rc"

# Case 1.2: exit=127 + stderr 情報あり → rc=0（stderr の追加情報は判定に影響しない）
rc=0
_sav_is_tool_missing_failure 127 "bash: line 1: golangci-lint: command not found" || rc=$?
assert_eq "Req 1.1: exit=127 + stderr → rc=0" "0" "$rc"

# Case 1.3: exit=1（real fail）→ rc=1（従来 fail）
rc=0
_sav_is_tool_missing_failure 1 "" || rc=$?
assert_eq "Req 3.4: exit=1 → rc=1（real fail）" "1" "$rc"

# Case 1.4: exit=124（timeout）→ rc=1（既存 timeout 経路に倒す）
rc=0
_sav_is_tool_missing_failure 124 "" || rc=$?
assert_eq "Req 2.5: exit=124 → rc=1（既存 timeout 経路）" "1" "$rc"

# Case 1.5: exit=2（path-missing diff の可能性 / 別経路）→ rc=1（tool-missing ではない）
rc=0
_sav_is_tool_missing_failure 2 "diff: x: No such file or directory" || rc=$?
assert_eq "Req 3.3: exit=2 → rc=1（path-missing 経路に倒す）" "1" "$rc"

# Case 1.6: exit=130（SIGINT 由来）→ rc=1（real fail）
rc=0
_sav_is_tool_missing_failure 130 "" || rc=$?
assert_eq "Req 3.5: exit=130 → rc=1（その他 real fail）" "1" "$rc"

# Case 1.7: exit=0（SUCCESS）→ rc=1（tool-missing ではない）
rc=0
_sav_is_tool_missing_failure 0 "" || rc=$?
assert_eq "Req 3.1: exit=0 → rc=1（success 経路）" "1" "$rc"

# Case 1.8: 非整数 rc → rc=1（防御的検証 / 安全側）
rc=0
_sav_is_tool_missing_failure "garbage" "" || rc=$?
assert_eq "NFR 3.1: 非整数 rc → rc=1（安全側）" "1" "$rc"

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: _sav_extract_tool_name_from_cmd 単体テスト（純粋関数 / Req 4.3）
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Section 2: _sav_extract_tool_name_from_cmd 単体テスト"
echo "================================================================"

# Case 2.1: stderr から bash: line N: <tool>: command not found を抽出
out=$(_sav_extract_tool_name_from_cmd "golangci-lint run" "bash: line 1: golangci-lint: command not found")
assert_eq "Req 4.3: stderr の line N pattern からツール名抽出" "golangci-lint" "$out"

# Case 2.2: stderr に line N が無い variant
out=$(_sav_extract_tool_name_from_cmd "golangci-lint run" "bash: golangci-lint: command not found")
assert_eq "Req 4.3: stderr の line N なし variant からも抽出" "golangci-lint" "$out"

# Case 2.3: stderr 空 → cmd 先頭 token に fallback
out=$(_sav_extract_tool_name_from_cmd "golangci-lint run" "")
assert_eq "Req 4.3: stderr 空 → cmd 先頭 token" "golangci-lint" "$out"

# Case 2.4: cmd 先頭が cd（bash builtin）→ 次の token を採用（簡易判定）
# 注: 厳密に `golangci-lint` を取るには `&&` を更にスキップする実装が必要だが、本判定は
# あくまで「情報源があれば」の条件付きヒントなので、`cd` だけスキップして次の token
# （`app`）を採用する素直な簡略化で実用十分（Req 4.3 は `Where 情報源がある場合`）。
out=$(_sav_extract_tool_name_from_cmd "cd app && golangci-lint run" "")
assert_eq "Req 4.3: cd skip → 次の非 builtin token" "app" "$out"

# Case 2.5: 両方とも空 → 空文字
out=$(_sav_extract_tool_name_from_cmd "" "")
assert_eq "Req 4.3: 入力なし → 空文字" "" "$out"

# Case 2.6: cmd が複数行 → 1 行目から抽出
out=$(_sav_extract_tool_name_from_cmd "$(printf 'shellcheck local-watcher/bin/*.sh\nactionlint .github/workflows/*.yml\n')" "")
assert_eq "Req 4.3: 複数行 cmd → 1 行目の先頭 token" "shellcheck" "$out"

# Case 2.7: stderr 優先（cmd と異なるツール名）
out=$(_sav_extract_tool_name_from_cmd "make build" "bash: line 3: ninja: command not found")
assert_eq "Req 4.3: stderr 検出を cmd よりも優先" "ninja" "$out"

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: stage_a_verify_run 統合テスト（WARN 降格 / real fail / 既存挙動）
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "================================================================"
echo "Section 3: stage_a_verify_run 統合テスト"
echo "================================================================"

# ── 共通 setup: テスト用 worktree / spec dir / round state dir を mktemp で隔離 ──
TEST_ROOT=$(mktemp -d)
REPO_DIR="$TEST_ROOT/work"
SPEC_DIR_REL="docs/specs/422-test"
mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
# round counter は state dir env で隔離（worktree 外）
STAGE_A_VERIFY_STATE_DIR="$TEST_ROOT/state"
mkdir -p "$STAGE_A_VERIFY_STATE_DIR"

# env: stage-a-verify モジュールが参照する変数
REPO="owner/test"
REPO_SLUG="owner-test"
NUMBER=422
BRANCH="claude/issue-422-test"
SLUG="test"
LOG="$TEST_ROOT/cron.log"
: > "$LOG"
LABEL_PICKED="claude-picked-up"
LABEL_CLAIMED="claude-claimed"
# `set -u` 配下で空文字でも参照可能なように明示初期化
STAGE_A_VERIFY_COMMAND=""
STAGE_A_VERIFY_TIMEOUT=30
STAGE_A_VERIFY_ENABLED="true"

# fake gh: ラベル除去 / Issue コメント投稿の副作用は stub で無視。引数を log に記録して
# 「gh issue comment 呼ばれない」AC（Req 1.3）を検証できるようにする。
GH_ARGS_FILE="$TEST_ROOT/gh-args.log"
: > "$GH_ARGS_FILE"
gh() {
  printf '%s\n' "$*" >> "$GH_ARGS_FILE"
  return 0
}

# fake mark_issue_failed: round=2 escalate 経路で呼ばれる。実体は impl-pipeline 系に
# あり本モジュールから cross-module 呼び出しされるので、テストでは呼び出し有無のみ記録する。
MIF_CALLED=0
mark_issue_failed() {
  MIF_CALLED=1
  echo "[stub-mark_issue_failed] reason=$1 extra=$2" >> "$LOG"
  return 0
}

# 構造化 verify ブロックを書き込んで tasks.md を生成するヘルパー
write_tasks_with_verify() {
  local cmd_body="$1"
  cat > "$REPO_DIR/$SPEC_DIR_REL/tasks.md" <<EOF
# Tasks

- [ ] 1. dummy task
  - _Requirements: 1.1_

<!-- stage-a-verify -->
\`\`\`sh
$cmd_body
\`\`\`
EOF
}

# round counter の値を読むヘルパー
read_round() {
  local rp
  rp=$(stage_a_verify_round_path)
  if [ -f "$rp" ]; then
    cat "$rp"
  else
    echo "0"
  fi
}

# 各 case で実行前に round counter / log / outcome を初期化するヘルパー
reset_state() {
  stage_a_verify_reset_round
  : > "$LOG"
  : > "$GH_ARGS_FILE"
  MIF_CALLED=0
  _SAV_LAST_OUTCOME=""
}

# stage_a_verify_run を実 watcher 環境（cron）と同じく stdout/stderr を $LOG へ集約して
# 実行するラッパー。実 watcher の cron 行は `>> cron.log 2>&1` で全出力を LOG に redirect
# しており、sav_log（stdout）/ sav_warn（stderr）/ EXEC 中の stdout/stderr もすべて LOG に
# 入る前提でログ grep の AC を組んでいる。テストでも同じ前提を再現することで AC が実 watcher
# 環境と同等に検証できる。
run_with_log() {
  # stage_a_verify_run の戻り値は global RUN_RC へ格納する（command substitution の
  # サブシェル境界を避け、_SAV_LAST_OUTCOME 等の global を呼び出し側で観測可能にする）。
  RUN_RC=0
  { stage_a_verify_run || RUN_RC=$?; } >> "$LOG" 2>&1
  return 0
}

# ─── Case 3.1: 単独 exit 127 → WARN 降格 / rc=0 / Stage A 続行 ───
echo "--- Case 3.1: 単独 exit 127 → WARN 降格（Req 1.1〜1.4） ---"
reset_state
write_tasks_with_verify "exit 127"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
round_val=$(read_round)
assert_eq "Req 1.1 / 1.2: WARN 降格 → rc=0" "0" "$rc"
assert_eq "Req 1.4 / 4.4: _SAV_LAST_OUTCOME=warn-tool-missing" "warn-tool-missing" "$_SAV_LAST_OUTCOME"
assert_eq "Req 1.1: round counter 不変（0 のまま）" "0" "$round_val"
assert_contains "Req 4.1: WARN log 1 行以上" "stage-a-verify: WARN" "$log_body"
assert_contains "Req 4.2: reason=verify-tool-missing を含む" "reason=verify-tool-missing" "$log_body"
assert_contains "Req 4.5: WARN 行に exit=127 を含む" "exit=127" "$log_body"
# `printf '%q' "exit 127"` は `exit\ 127`（backslash-escaped）で記録されるため、
# cmd= prefix が WARN 行に含まれ、かつ exit のトークンが見えていることを確認する
# （printf %q は shell-quoted の標準書式で、復元可能性 / 監査性のために選択）。
assert_contains "Req 4.5: WARN 行に cmd= prefix を含む（断片）" "cmd=exit" "$log_body"
# Req 4.1: grep 抽出可能性
warn_lines=$(grep '\[.*\] stage-a-verify: WARN' "$LOG" || true)
assert_contains "Req 4.1: grep '\\[.*\\] stage-a-verify: WARN' で抽出可能" "reason=verify-tool-missing" "$warn_lines"
# mark_issue_failed は呼ばれない（escalate 防止 / Req 1.1）
assert_eq "Req 1.1: WARN 降格時に mark_issue_failed 呼ばれない" "0" "$MIF_CALLED"
# gh issue comment も呼ばれない（差し戻し防止 / Req 1.3）
gh_body=$(cat "$GH_ARGS_FILE")
assert_not_contains "Req 1.3: gh issue comment 呼ばれない" "issue comment" "$gh_body"

# ─── Case 3.2: 存在しないコマンドを直接実行（command_not_found_xyz）→ exit 127 → WARN 降格 ───
echo "--- Case 3.2: 存在しないコマンドを直接実行 → WARN 降格 ---"
reset_state
# 注: ここで使うコマンド名は keyword 集合と衝突しないため Gate 3 で SKIPPED に倒れる可能性が
# ある。構造化ブロック由来は Gate 3 bypass されるため、構造化フェンス経由なら exit 127 まで
# 到達する。`shellcheck` は keyword 集合に含まれるため Gate 3 通過可能だが、存在しないコマンド
# としてはダミーが必要。よって `shellcheck` で始まり実態は存在しないコマンドを叩く方針にする。
# 結果として stderr に "command not found" が出るかは bash の version 依存。
# 構造化ブロック由来は Gate 3 を bypass するため、任意のコマンド名で 127 を観測できる。
write_tasks_with_verify "command_not_found_xyz_$$"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 1.1: 存在しないコマンド → rc=0（WARN 降格）" "0" "$rc"
assert_eq "Req 1.4: outcome=warn-tool-missing" "warn-tool-missing" "$_SAV_LAST_OUTCOME"
assert_contains "Req 4.2: reason=verify-tool-missing" "reason=verify-tool-missing" "$log_body"
assert_contains "Req 4.5: exit=127" "exit=127" "$log_body"

# ─── Case 3.3: 連結 `true && exit 127` → 全体 127 → WARN 降格（Req 2.2 末尾位置） ───
echo "--- Case 3.3: 連結 true && exit 127 → 全体 127 → WARN 降格（Req 2.2） ---"
reset_state
write_tasks_with_verify "true && exit 127"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 2.2: 連結末尾 127 → rc=0（WARN 降格）" "0" "$rc"
assert_eq "Req 1.4: outcome=warn-tool-missing" "warn-tool-missing" "$_SAV_LAST_OUTCOME"
assert_contains "Req 4.2: reason=verify-tool-missing" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.4: 連結 `exit 127 && true` → 全体 127（先頭で短絡）→ WARN 降格（Req 2.1） ───
echo "--- Case 3.4: 連結 exit 127 && true → 全体 127 → WARN 降格（Req 2.1） ---"
reset_state
write_tasks_with_verify "exit 127 && true"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 2.1: 連結先頭 127 短絡 → rc=0（WARN 降格）" "0" "$rc"
assert_eq "Req 1.4: outcome=warn-tool-missing" "warn-tool-missing" "$_SAV_LAST_OUTCOME"
assert_contains "Req 4.2: reason=verify-tool-missing" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.5: 連結 `exit 1 && exit 127` → 全体 1（先頭 real fail で短絡）→ round1 ───
echo "--- Case 3.5: 連結 exit 1 && exit 127 → 全体 1 → round1（Req 2.4） ---"
reset_state
write_tasks_with_verify "exit 1 && exit 127"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
round_val=$(read_round)
assert_eq "Req 2.4: 連結 real fail 優先 → rc=1（round1）" "1" "$rc"
assert_eq "Req 2.4 / 3.4: outcome=round1" "round1" "$_SAV_LAST_OUTCOME"
assert_eq "Req 2.4: round counter=1" "1" "$round_val"
assert_contains "Req 2.4: FAILED log（real fail）" "FAILED exit=1" "$log_body"
assert_not_contains "Req 2.4: real fail で WARN 降格しない" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.6: exit 1 単独 → 従来 round1（既存挙動 / Req 3.4） ───
echo "--- Case 3.6: exit 1 単独 → 従来 round1（Req 3.4） ---"
reset_state
write_tasks_with_verify "exit 1"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
round_val=$(read_round)
assert_eq "Req 3.4: real fail → rc=1（round1）" "1" "$rc"
assert_eq "Req 3.4: outcome=round1" "round1" "$_SAV_LAST_OUTCOME"
assert_eq "Req 3.4: round counter=1" "1" "$round_val"
assert_contains "Req 3.4: FAILED log（real fail）" "FAILED exit=1" "$log_body"
assert_not_contains "Req 3.4: real fail で WARN 降格しない（tool-missing）" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.7: true 単独 → SUCCESS（既存挙動 / Req 3.1） ───
echo "--- Case 3.7: true 単独 → SUCCESS（Req 3.1） ---"
reset_state
write_tasks_with_verify "true"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 3.1: success → rc=0" "0" "$rc"
assert_eq "Req 3.1: outcome=success" "success" "$_SAV_LAST_OUTCOME"
assert_contains "Req 3.1: SUCCESS log" "SUCCESS exit=0" "$log_body"
assert_not_contains "Req 3.1: success で WARN 降格しない（tool-missing）" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.8: 既存 path-missing diff (exit=2) → warn-skipped（既存 / Req 3.3） ───
echo "--- Case 3.8: 既存 path-missing diff → warn-skipped 既存挙動（Req 3.3） ---"
reset_state
# 存在しない path を 2 つ指定して diff -r が exit=2 + ENOENT を返す状態にする。
write_tasks_with_verify "diff -r '$REPO_DIR/nonexistent_a' '$REPO_DIR/nonexistent_b'"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 3.3: path-missing → rc=0（WARN 降格 既存）" "0" "$rc"
assert_eq "Req 3.3: outcome=warn-skipped（path-missing と区別）" "warn-skipped" "$_SAV_LAST_OUTCOME"
assert_contains "Req 3.3: reason=verify-path-missing 既存" "reason=verify-path-missing" "$log_body"
assert_not_contains "Req 4.4: tool-missing と区別（混在しない）" "reason=verify-tool-missing" "$log_body"

# ─── Case 3.9: STAGE_A_VERIFY_COMMAND env 経路の exit 127 → WARN 降格（Req 1.5） ───
echo "--- Case 3.9: STAGE_A_VERIFY_COMMAND env 経路の exit 127 → WARN 降格（Req 1.5） ---"
reset_state
# tasks.md には構造化ブロックを置かず、env で escape-hatch コマンドを指定する経路。
# 構造化ブロック不在を作るため、tasks.md の構造化フェンスを書かない。
cat > "$REPO_DIR/$SPEC_DIR_REL/tasks.md" <<'EOF'
# Tasks

- [ ] 1. dummy task
  - _Requirements: 1.1_
EOF
STAGE_A_VERIFY_COMMAND="exit 127"
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "Req 1.5: env 経路の exit 127 → rc=0（WARN 降格）" "0" "$rc"
assert_eq "Req 1.5: outcome=warn-tool-missing" "warn-tool-missing" "$_SAV_LAST_OUTCOME"
assert_contains "Req 1.5: reason=verify-tool-missing" "reason=verify-tool-missing" "$log_body"
STAGE_A_VERIFY_COMMAND=""  # 後続テストのため復元

# ─── Case 3.10: STAGE_A_VERIFY_ENABLED=false（既存 opt-out 維持 / NFR 1.1） ───
echo "--- Case 3.10: STAGE_A_VERIFY_ENABLED=false（NFR 1.1） ---"
reset_state
STAGE_A_VERIFY_ENABLED="false"
write_tasks_with_verify "exit 127"  # 実行されるべきでない
run_with_log
rc=$RUN_RC
log_body=$(cat "$LOG")
assert_eq "NFR 1.1: disabled → rc=0" "0" "$rc"
assert_eq "NFR 1.1: outcome=disabled" "disabled" "$_SAV_LAST_OUTCOME"
assert_contains "NFR 1.1: DISABLED log" "DISABLED reason=env-opt-out" "$log_body"
assert_not_contains "NFR 1.1: disabled で tool-missing WARN なし" "reason=verify-tool-missing" "$log_body"
STAGE_A_VERIFY_ENABLED="true"  # 後続テストのため復元

# ─────────────────────────────────────────────────────────────────────────────
# cleanup
# ─────────────────────────────────────────────────────────────────────────────

rm -rf "$TEST_ROOT" 2>/dev/null || true

echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
