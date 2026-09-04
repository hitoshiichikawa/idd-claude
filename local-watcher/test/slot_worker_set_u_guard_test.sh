#!/usr/bin/env bash
# 本テストは grep の literal パターン（`${VAR:=default}` 等）と `bash -c` へ渡す literal
# スクリプトを意図的に single quote で保持する（展開させない）。SC2016 は意図どおりのため
# ファイル全体で抑止する。
# shellcheck disable=SC2016
# =============================================================================
# slot_worker_set_u_guard_test.sh — set -u 下での mode 判定変数クラッシュ防止
#   (#530 / Requirement 1)
#
# slot-worker.sh `_slot_run_issue` は `set -euo pipefail`（set -u）下で動く。design
# 再入 / resume / stage-checkpoint により後段の無条件初期化ブロックを通過しない経路で
# 実行されると、mode 判定変数（NEEDS_ARCHITECT / ARCHITECT_REASON / MODE）が未割り当ての
# まま参照されてサブシェルが即死し、Issue が再処理不能な停止状態に陥る。
#
# 本テストは 2 層で検証する:
#   (A) 構造検証（実 slot-worker.sh から）:
#       - メタデータ抽出直後の全経路初期化ブロック（`: "${VAR:=default}"`）が存在する
#         （Req 1.1〜1.5 の defense-in-depth 中核）
#       - 要件が名指しする読み取り箇所（686/689/781/837 相当）が `${VAR:-}` でガード
#         されている（belt-and-suspenders）
#   (B) 挙動検証（set -u 下のパターン再現 + 負のコントロール）:
#       - 全経路初期化（`:=`）適用後は未割り当てでも set -u 下でクラッシュしない
#       - ガード付き読み取り（`${VAR:-}`）は未割り当てでも set -u 下でクラッシュしない
#       - ガード無し素の読み取りは未割り当てで set -u 下クラッシュする（テストが
#         回帰を捕捉できることの証明 / Red コントロール）
#
# 配置先: local-watcher/test/slot_worker_set_u_guard_test.sh
# 実行:   bash local-watcher/test/slot_worker_set_u_guard_test.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/lib/test-helpers.sh"

SLOT="$SCRIPT_DIR/../bin/modules/slot-worker.sh"

PASS_COUNT=0
FAIL_COUNT=0

if [ ! -f "$SLOT" ]; then
  echo "FATAL: slot-worker.sh not found at $SLOT" >&2
  exit 1
fi

BASH_BIN="$(command -v bash)"

echo "=== (A) 構造検証: 実 slot-worker.sh の初期化ブロックとガード ==="

# 全経路初期化ブロック（`:=` で unset/empty のときのみ既定値へ倒す）
assert_rc "全経路初期化: NEEDS_ARCHITECT :=false" 0 \
  grep -qF ': "${NEEDS_ARCHITECT:=false}"' "$SLOT"
assert_rc "全経路初期化: ARCHITECT_REASON :=（空）" 0 \
  grep -qF ': "${ARCHITECT_REASON:=}"' "$SLOT"
assert_rc "全経路初期化: MODE :=（空）" 0 \
  grep -qF ': "${MODE:=}"' "$SLOT"

# 読み取り箇所のガード（要件 traceability 名指し 686/689/781/837 相当）
assert_rc "read guard: NEEDS_ARCHITECT の design 判定" 0 \
  grep -qF '[ "${NEEDS_ARCHITECT:-}" = "true" ]' "$SLOT"
assert_rc "read guard: ARCHITECT_REASON の理由出力" 0 \
  grep -qF '理由: ${ARCHITECT_REASON:-}' "$SLOT"
assert_rc "read guard: ARCHITECT_REASON の design prompt 内" 0 \
  grep -qF 'Triage 判定理由: ${ARCHITECT_REASON:-}' "$SLOT"
assert_rc "read guard: MODE の Development 実行ログ" 0 \
  grep -qF 'Development 実行（${MODE:-}）' "$SLOT"

echo "=== (B) 挙動検証: set -u 下のパターン再現 + 負のコントロール ==="

# 全経路初期化（`:=`）適用後は未割り当てでも set -u 下でクラッシュしない。
# 実 slot-worker.sh の初期化 + 名指し read パターンを最小再現する。
rc=0
"$BASH_BIN" -u -c '
  : "${NEEDS_ARCHITECT:=false}"
  : "${ARCHITECT_REASON:=}"
  : "${MODE:=}"
  # 名指し read（design 判定 / 理由出力 / mode ログ / mode 分岐）を再現
  [ "${NEEDS_ARCHITECT:-}" = "true" ] || true
  printf "reason=%s\n" "${ARCHITECT_REASON:-}"
  printf "mode=%s\n"   "${MODE:-}"
  case "${MODE:-}" in design) : ;; impl|impl-resume) : ;; *) : ;; esac
' >/dev/null 2>&1 || rc=$?
assert_eq "全経路初期化 + ガード適用時は set -u 下でクラッシュしない" "0" "$rc"

# ガード付き読み取り（`${VAR:-}`）単体でも未割り当てで安全（値代入まで含めて exit 0）
rc=0
"$BASH_BIN" -u -c 'v="${MODE:-}"; printf "%s" "$v"' >/dev/null 2>&1 || rc=$?
assert_eq "ガード付き read \${MODE:-} は unset でも set -u 下で安全" "0" "$rc"

# 負のコントロール: ガード無し素の read は unset で set -u 下クラッシュ（非ゼロ終了）。
# 本テストが「初期化/ガードを外す回帰」を捕捉できることを担保する。exit code は bash
# バージョン依存（例: bash 5.2 は 127）のため「非ゼロ」で判定する。
rc=0
"$BASH_BIN" -u -c 'v="$MODE"; printf "%s" "$v"' >/dev/null 2>&1 || rc=$?
crashed="no"; [ "$rc" -ne 0 ] && crashed="yes"
assert_eq "負のコントロール: 素の \$MODE read は unset で set -u 下クラッシュ" "yes" "$crashed"

rc=0
"$BASH_BIN" -u -c '[ "$NEEDS_ARCHITECT" = "true" ]' >/dev/null 2>&1 || rc=$?
crashed="no"; [ "$rc" -ne 0 ] && crashed="yes"
assert_eq "負のコントロール: 素の \$NEEDS_ARCHITECT read は unset で set -u 下クラッシュ" "yes" "$crashed"

echo ""
echo "PASS: $PASS_COUNT / FAIL: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
