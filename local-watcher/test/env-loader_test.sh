#!/usr/bin/env bash
#
# 用途: local-watcher/bin/modules/env-loader.sh の Issue #386（per-repo env ファイル ローダ）の
#       探索順 / 値評価 / precedence / 構文不正 skip / 後方互換性を fixture で検証する近接テスト。
#
#       対象関数:
#         - el_resolve_env_file  (Req 1.1〜1.5 / NFR 2.1)
#         - el_apply_env_file    (Req 2.1〜2.4 / 3.1〜3.3 / 4.1〜4.4 / 6.1〜6.5)
#         - el_load              (Req 1.1 / 5.1 / NFR 3.1 / 3.3 entry point)
#
#       検証する AC（docs/specs/386-feat-watcher-per-repo-env-crontab-f8/requirements.md）:
#         - Req 1.2: WATCHER_ENV_FILE 指定優先 / 他候補無視
#         - Req 1.3 / 1.4: per-repo パス `$HOME/.issue-watcher/<REPO_SLUG>.env` を採用
#         - Req 1.5 / Req 5.1 / NFR 1.1: 候補不在で no-op（warn なし）
#         - Req 2.2 / 2.3: コメント行 / 空行 skip
#         - Req 2.4: KEY を環境変数として export
#         - Req 3.1: 値中の $HOME 展開
#         - Req 3.2: 値中の $(...) コマンド置換評価
#         - Req 3.3 / 6.3: コマンド置換失敗で当該行 skip + 継続
#         - Req 4.1 / 4.4: inline cron env > env ファイル precedence
#         - Req 4.2 / 4.3: env ファイルのみ存在の KEY は env ファイル値採用
#         - Req 6.2: 構文不正行（`=` なし / KEY 無効）は当該行 skip + warn + 継続
#
# 配置先: local-watcher/test/env-loader_test.sh
# 依存:   bash 4+, mktemp
# 実行:   bash local-watcher/test/env-loader_test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_SH="$SCRIPT_DIR/../bin/modules/env-loader.sh"

if [ ! -f "$MODULE_SH" ]; then
  echo "ERROR: cannot find env-loader.sh at $MODULE_SH" >&2
  exit 2
fi

# テストごとに変数汚染を起こさないため、サブシェル経由で実行する。
# 各テストはサブシェルで `. "$MODULE_SH"` してから実装関数を呼ぶ。

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1"; if [ -n "${2:-}" ]; then echo "  detail: $2"; fi; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# テスト用に共通の REPO / REPO_SLUG / HOME を上書きできる fixture root を作る。
FIX_ROOT="$(mktemp -d -t env-loader-test-XXXXXX)"
trap 'rm -rf "$FIX_ROOT"' EXIT

# ============================================================
# Section 1: el_resolve_env_file の探索順（Req 1.1〜1.5 / NFR 2.1）
# ============================================================
echo "--- Section 1: el_resolve_env_file の探索順 ---"

# Sub 1.1: WATCHER_ENV_FILE 指定（絶対パス + 読取可能）→ それを採用（Req 1.2）
out_sub1=$(mktemp -p "$FIX_ROOT" sub1-XXXX)
explicit_env="$out_sub1"
echo "FOO=1" > "$explicit_env"
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  WATCHER_ENV_FILE="$explicit_env" HOME="$FIX_ROOT/should-not-be-used" REPO_SLUG="x" \
    el_resolve_env_file 2>/dev/null || true
)
if [ "$got" = "$explicit_env" ]; then
  pass "Req 1.2: WATCHER_ENV_FILE 絶対パス指定で当該パス採用"
else
  fail "Req 1.2: WATCHER_ENV_FILE 絶対パス指定で当該パス採用" "expected=$explicit_env actual=$got"
fi

# Sub 1.2: WATCHER_ENV_FILE 指定済みで他候補無視（per-repo パスにファイルがあっても採用しない）
mkdir -p "$FIX_ROOT/home1/.issue-watcher"
echo "BAR=should-be-ignored" > "$FIX_ROOT/home1/.issue-watcher/owner-repo.env"
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  WATCHER_ENV_FILE="$explicit_env" HOME="$FIX_ROOT/home1" REPO_SLUG="owner-repo" \
    el_resolve_env_file 2>/dev/null || true
)
if [ "$got" = "$explicit_env" ]; then
  pass "Req 1.2: WATCHER_ENV_FILE 採用時に per-repo パスを参照しない"
else
  fail "Req 1.2: WATCHER_ENV_FILE 採用時に per-repo パスを参照しない" "actual=$got"
fi

# Sub 1.3: WATCHER_ENV_FILE 未設定 → per-repo パス採用（Req 1.3 / 1.4）
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset WATCHER_ENV_FILE
  HOME="$FIX_ROOT/home1" REPO_SLUG="owner-repo" \
    el_resolve_env_file 2>/dev/null || true
)
expected="$FIX_ROOT/home1/.issue-watcher/owner-repo.env"
if [ "$got" = "$expected" ]; then
  pass "Req 1.3 / 1.4: WATCHER_ENV_FILE 未設定で per-repo パス採用"
else
  fail "Req 1.3 / 1.4: WATCHER_ENV_FILE 未設定で per-repo パス採用" "expected=$expected actual=$got"
fi

# Sub 1.4: WATCHER_ENV_FILE 空文字でも per-repo パス採用（NFR 2.1 安全側）
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  WATCHER_ENV_FILE="" HOME="$FIX_ROOT/home1" REPO_SLUG="owner-repo" \
    el_resolve_env_file 2>/dev/null || true
)
if [ "$got" = "$expected" ]; then
  pass "Req 1.3: WATCHER_ENV_FILE 空文字で per-repo パス採用"
else
  fail "Req 1.3: WATCHER_ENV_FILE 空文字で per-repo パス採用" "actual=$got"
fi

# Sub 1.5: WATCHER_ENV_FILE が相対パスは無視（NFR 2.1 path traversal 予防）
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  WATCHER_ENV_FILE="relative/path.env" HOME="$FIX_ROOT/home1" REPO_SLUG="owner-repo" \
    el_resolve_env_file 2>/dev/null || true
)
if [ "$got" = "$expected" ]; then
  pass "NFR 2.1: WATCHER_ENV_FILE 相対パス無視で per-repo パスに fallback"
else
  fail "NFR 2.1: WATCHER_ENV_FILE 相対パス無視で per-repo パスに fallback" "actual=$got"
fi

# Sub 1.6: 候補ファイル不在 → rc=1 / stdout 空（Req 1.5）
out_rc=0
got=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset WATCHER_ENV_FILE
  HOME="$FIX_ROOT/none" REPO_SLUG="nonexistent" \
    el_resolve_env_file 2>/dev/null
) || out_rc=$?
if [ "$out_rc" = 1 ] && [ -z "$got" ]; then
  pass "Req 1.5: 候補不在で rc=1 / stdout 空"
else
  fail "Req 1.5: 候補不在で rc=1 / stdout 空" "rc=$out_rc stdout=$got"
fi

# Sub 1.7: WATCHER_ENV_FILE 指定が読取不能 → per-repo に fallback（Req 1.2 失敗時）
unreadable="$FIX_ROOT/unreadable.env"
echo "X=1" > "$unreadable"
chmod 0 "$unreadable" 2>/dev/null || true
# root では `chmod 0` でも読めるため、root 環境はスキップ。
if [ ! -r "$unreadable" ]; then
  got=$(
    # shellcheck disable=SC1090
    . "$MODULE_SH"
    WATCHER_ENV_FILE="$unreadable" HOME="$FIX_ROOT/home1" REPO_SLUG="owner-repo" \
      el_resolve_env_file 2>/dev/null || true
  )
  if [ "$got" = "$expected" ]; then
    pass "Req 1.2 失敗時: WATCHER_ENV_FILE 読取不能で per-repo パスに fallback"
  else
    fail "Req 1.2 失敗時: WATCHER_ENV_FILE 読取不能で per-repo パスに fallback" "actual=$got"
  fi
else
  echo "SKIP: chmod 0 が効かない環境（root 等）のため Req 1.2 読取不能ケースはスキップ"
fi
chmod 644 "$unreadable" 2>/dev/null || true

# ============================================================
# Section 2: el_apply_env_file の値反映 / 形式（Req 2.2〜2.4）
# ============================================================
echo ""
echo "--- Section 2: el_apply_env_file の値反映 / 形式 ---"

# Sub 2.1: 単純な KEY=VALUE で export される（Req 2.4）
env2="$FIX_ROOT/section2.env"
cat >"$env2" <<'EOF'
SIMPLE_KEY=hello
EOF
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset SIMPLE_KEY
  el_apply_env_file "$env2" 2>/dev/null
  echo "got=${SIMPLE_KEY:-UNSET}"
)
if echo "$result" | grep -q "got=hello"; then
  pass "Req 2.4: 単純 KEY=VALUE が export される"
else
  fail "Req 2.4: 単純 KEY=VALUE が export される" "$result"
fi

# Sub 2.2: # コメント行 / 空行 / 空白のみ行 skip（Req 2.2 / 2.3）
env2b="$FIX_ROOT/section2b.env"
cat >"$env2b" <<'EOF'
# comment line should be skipped
   # indented comment skipped


KEEP_THIS=ok
EOF
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset KEEP_THIS
  el_apply_env_file "$env2b" 2>&1
  echo "got=${KEEP_THIS:-UNSET}"
)
if echo "$result" | grep -q "got=ok" && ! echo "$result" | grep -q "WARN"; then
  pass "Req 2.2 / 2.3: コメント・空行 skip + 後続 KEY 反映 + WARN なし"
else
  fail "Req 2.2 / 2.3: コメント・空行 skip + 後続 KEY 反映 + WARN なし" "$result"
fi

# ============================================================
# Section 3: 値評価（$HOME / $(...) 展開）（Req 3.1 / 3.2 / 3.3）
# ============================================================
echo ""
echo '--- Section 3: 値評価（$HOME / $(...) 展開） ---'

# Sub 3.1: $HOME 展開（Req 3.1）
env3="$FIX_ROOT/section3.env"
echo 'HOME_VAL=$HOME/foo' > "$env3"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset HOME_VAL
  HOME="/test/home" el_apply_env_file "$env3" 2>/dev/null
  echo "got=${HOME_VAL:-UNSET}"
)
if echo "$result" | grep -q "got=/test/home/foo"; then
  pass "Req 3.1: 値中の \$HOME が展開される"
else
  fail "Req 3.1: 値中の \$HOME が展開される" "$result"
fi

# Sub 3.2: $(...) コマンド置換評価（Req 3.2）
env3b="$FIX_ROOT/section3b.env"
secret_file="$FIX_ROOT/secret.txt"
echo "s3cret-value" > "$secret_file"
echo "SECRET=\$(cat $secret_file)" > "$env3b"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset SECRET
  el_apply_env_file "$env3b" 2>/dev/null
  echo "got=${SECRET:-UNSET}"
)
if echo "$result" | grep -q "got=s3cret-value"; then
  pass "Req 3.2: 値中の \$(...) コマンド置換が評価される"
else
  fail "Req 3.2: 値中の \$(...) コマンド置換が評価される" "$result"
fi

# Sub 3.3: $(...) コマンド置換失敗で当該行 skip + 後続行は処理継続（Req 3.3 / 6.3）
env3c="$FIX_ROOT/section3c.env"
cat >"$env3c" <<EOF
FAIL_KEY=\$(/nonexistent/command-that-fails)
NEXT_KEY=after-fail
EOF
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset FAIL_KEY NEXT_KEY
  el_apply_env_file "$env3c" 2>&1
  echo "fail=${FAIL_KEY:-UNSET}|next=${NEXT_KEY:-UNSET}"
)
# FAIL_KEY は未設定 or 空、NEXT_KEY は反映、WARN メッセージが出ること
if echo "$result" | grep -qE "fail=(UNSET\|next=after-fail|\|next=after-fail)" \
   && echo "$result" | grep -q "WARN"; then
  pass "Req 3.3 / 6.3: コマンド置換失敗で当該行 skip + 後続継続 + WARN 出力"
else
  fail "Req 3.3 / 6.3: コマンド置換失敗で当該行 skip + 後続継続 + WARN 出力" "$result"
fi

# ============================================================
# Section 4: precedence（inline cron env > env ファイル）（Req 4.1〜4.4）
# ============================================================
echo ""
echo "--- Section 4: precedence ---"

# Sub 4.1: inline 設定済みの KEY は env ファイル値で上書きされない（Req 4.1）
env4="$FIX_ROOT/section4.env"
echo "INLINE_KEY=from-file" > "$env4"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  INLINE_KEY="from-inline"
  el_apply_env_file "$env4" 2>/dev/null
  echo "got=${INLINE_KEY:-UNSET}"
)
if echo "$result" | grep -q "got=from-inline"; then
  pass "Req 4.1: inline cron env > env ファイル（inline 値温存）"
else
  fail "Req 4.1: inline cron env > env ファイル（inline 値温存）" "$result"
fi

# Sub 4.2: env ファイルにのみ存在の KEY は env ファイル値採用（Req 4.2）
env4b="$FIX_ROOT/section4b.env"
echo "FILE_ONLY=from-file" > "$env4b"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset FILE_ONLY
  el_apply_env_file "$env4b" 2>/dev/null
  echo "got=${FILE_ONLY:-UNSET}"
)
if echo "$result" | grep -q "got=from-file"; then
  pass "Req 4.2: env ファイルのみの KEY は env ファイル値採用"
else
  fail "Req 4.2: env ファイルのみの KEY は env ファイル値採用" "$result"
fi

# Sub 4.3: inline 設定済み（空文字）も「定義済み」扱いで上書きされない（Req 4.4）
env4c="$FIX_ROOT/section4c.env"
echo "INLINE_EMPTY=from-file" > "$env4c"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  INLINE_EMPTY=""
  el_apply_env_file "$env4c" 2>/dev/null
  # `${VAR-default}` でも空文字を「定義済み」と区別する
  if [ -n "${INLINE_EMPTY+x}" ]; then
    echo "got=defined:${INLINE_EMPTY}"
  else
    echo "got=undefined"
  fi
)
if echo "$result" | grep -q "got=defined:$"; then
  pass "Req 4.4: inline 空文字も「定義済み」として温存される"
else
  fail "Req 4.4: inline 空文字も「定義済み」として温存される" "$result"
fi

# ============================================================
# Section 5: 異常系（構文不正行 skip + warn）（Req 6.1 / 6.2 / 6.5）
# ============================================================
echo ""
echo "--- Section 5: 異常系 ---"

# Sub 5.1: `=` なしの構文不正行 → skip + warn、後続行は処理継続（Req 6.2 / 6.5）
env5="$FIX_ROOT/section5.env"
cat >"$env5" <<'EOF'
INVALID LINE NO EQUAL
VALID_KEY=valid
EOF
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset VALID_KEY
  el_apply_env_file "$env5" 2>&1
  echo "got=${VALID_KEY:-UNSET}"
)
if echo "$result" | grep -q "got=valid" \
   && echo "$result" | grep -q "WARN" \
   && echo "$result" | grep -q "section5.env:1"; then
  pass "Req 6.2 / 6.5: 構文不正行 skip + warn（行番号 + パス） + 後続継続"
else
  fail "Req 6.2 / 6.5: 構文不正行 skip + warn（行番号 + パス） + 後続継続" "$result"
fi

# Sub 5.2: KEY が無効識別子（数字始まり）→ skip + warn（Req 6.2）
env5b="$FIX_ROOT/section5b.env"
cat >"$env5b" <<'EOF'
9BAD_KEY=oops
GOOD=ok
EOF
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset GOOD
  el_apply_env_file "$env5b" 2>&1
  echo "got=${GOOD:-UNSET}"
)
if echo "$result" | grep -q "got=ok" && echo "$result" | grep -q "WARN"; then
  pass "Req 6.2: 数字始まり KEY は無効識別子として skip + warn"
else
  fail "Req 6.2: 数字始まり KEY は無効識別子として skip + warn" "$result"
fi

# Sub 5.3: 読取不能ファイル → warn + rc=1（Req 6.1）
# root では chmod 0 が効かないためスキップロジックを入れる
env5c="$FIX_ROOT/section5c.env"
echo "X=1" > "$env5c"
chmod 0 "$env5c" 2>/dev/null || true
if [ ! -r "$env5c" ]; then
  rc=0
  out=$(
    # shellcheck disable=SC1090
    . "$MODULE_SH"
    el_apply_env_file "$env5c" 2>&1
  ) || rc=$?
  if [ "$rc" = 1 ] && echo "$out" | grep -q "WARN"; then
    pass "Req 6.1: 読取不能ファイルで warn + rc=1"
  else
    fail "Req 6.1: 読取不能ファイルで warn + rc=1" "rc=$rc out=$out"
  fi
else
  echo "SKIP: chmod 0 が効かない環境（root 等）のため Req 6.1 はスキップ"
fi
chmod 644 "$env5c" 2>/dev/null || true

# ============================================================
# Section 6: el_load entry point（候補不在で no-op / NFR 1.1 / 3.3）
# ============================================================
echo ""
echo "--- Section 6: el_load entry point ---"

# Sub 6.1: 候補不在で stdout / stderr いずれも空、rc=0（Req 5.1 / NFR 1.1 / 3.3）
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  unset WATCHER_ENV_FILE
  HOME="$FIX_ROOT/empty-home" REPO_SLUG="no-such-repo" REPO="owner/no-such-repo" \
    el_load 2>&1
)
rc=$?
if [ "$rc" = 0 ] && [ -z "$result" ]; then
  pass "Req 5.1 / NFR 1.1 / NFR 3.3: 候補不在で no-op（出力なし / rc=0）"
else
  fail "Req 5.1 / NFR 1.1 / NFR 3.3: 候補不在で no-op（出力なし / rc=0）" "rc=$rc out=$result"
fi

# Sub 6.2: 採用時に 1 行 stdout ログ（NFR 3.1）、値そのものは出さない
env6="$FIX_ROOT/section6.env"
echo "SECRET_VAL=should-not-be-logged" > "$env6"
result=$(
  # shellcheck disable=SC1090
  . "$MODULE_SH"
  WATCHER_ENV_FILE="$env6" REPO="owner/test" el_load 2>&1
)
if echo "$result" | grep -q "env ファイル採用" \
   && echo "$result" | grep -q "$env6" \
   && ! echo "$result" | grep -q "should-not-be-logged"; then
  pass "NFR 3.1 / NFR 2.2: 採用時 1 行ログにパスのみ含む / 値は含まない"
else
  fail "NFR 3.1 / NFR 2.2: 採用時 1 行ログにパスのみ含む / 値は含まない" "$result"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================="
echo "RESULT: PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
echo "=================================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
