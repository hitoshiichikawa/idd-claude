#!/usr/bin/env bash
# shellcheck shell=bash
# guard-hook.sh — watcher の PreToolUse Guard Hook 注入モジュール (#294)
#
# 用途:
#   Claude Code の PreToolUse フック機構を利用して base ブランチ宛 push / 無条件 force
#   push / guard install dir の自己改変を機械 deny する初版（G0 + G1 + G2）を、watcher
#   の claude CLI 起動時に opt-in で配線するためのヘルパ関数を集約する。本モジュールは
#   hook 本体（local-watcher/hooks/idd-guard.sh）と settings.json を user-scope の
#   $IDD_CLAUDE_HOOKS_DIR（既定 $HOME/.idd-claude/hooks）に install.sh が配置している
#   前提のもとで、watcher 側の preflight ゲートと `--settings` 引数構築を担う。
#   - gh_log / gh_warn / gh_error : `guard-hook:` 3 段 prefix logger
#   - gh_is_enabled               : IDD_CLAUDE_HOOKS_ENABLED の厳密 `true` 一致判定
#   - gh_resolve_dir              : install dir 絶対パス解決（末尾スラッシュ除去）
#   - gh_compare_semver           : 数値ベース semver 比較（`a -ge b` の bash 戻り値）
#   - gh_preflight                : claude version → install dir 完全性 → smoke test の
#                                   fail-closed 連鎖（戻り値 0=pass / 11/12/13=fail）
#   - gh_build_args               : CLAUDE_HOOK_ARGS グローバル配列を opt-in/out で構築
#
# 配置先:
#   $HOME/bin/modules/guard-hook.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $IDD_CLAUDE_HOOKS_ENABLED / $IDD_CLAUDE_HOOKS_DIR /
#     $IDD_CLAUDE_HOOKS_MIN_VERSION）は本体冒頭の Config ブロックで定義済み。bash の遅延束縛
#     により呼び出し時に解決される。$REPO 未定義時は ${REPO:-?} で防御する。
#   - 外部 CLI: claude（version 取得）/ bash（smoke test 起動）。jq は hook 本体側が要求し、
#     本モジュールは smoke test の stdout 検査では `decision` リテラル grep のみで判定する
#     ことで jq 依存を持たない（fail-closed は hook 本体側でも独立に成立する）。
#
# セットアップ参照先:
#   - 要件: docs/specs/294-feat-watcher-pretooluse-guard-hook-base/requirements.md
#   - 設計: docs/specs/294-feat-watcher-pretooluse-guard-hook-base/design.md

# guard-hook 専用ロガー（既存 sav_log / sh_log と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] guard-hook:` の 3 段 prefix を維持し、
# `grep '\[.*\] guard-hook:'` で全件抽出可能。$REPO は本体側グローバルの遅延束縛。
gh_log() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: $*"
}
gh_warn() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: WARN: $*" >&2
}
gh_error() {
  echo "[$(date '+%F %T')] [${REPO:-?}] guard-hook: ERROR: $*" >&2
}

# ─── gh_is_enabled ───
#
# IDD_CLAUDE_HOOKS_ENABLED の値が文字列 `true` と **完全一致** する場合のみ opt-in 有効と判定する。
# Req 1.1 の typo 安全側設計（`True` / `1` / `yes` 等はすべて opt-out 扱い）。
# 戻り値: 0 = opt-in 有効 / 1 = opt-out（既定）
gh_is_enabled() {
  [ "${IDD_CLAUDE_HOOKS_ENABLED:-}" = "true" ]
}

# ─── gh_resolve_dir ───
#
# guard hook の install dir を絶対パスで stdout に返す（末尾スラッシュ除去）。
# 既定 `$HOME/.idd-claude/hooks`、IDD_CLAUDE_HOOKS_DIR env で override 可（Req 1.4 / NFR 1.3）。
# 物理存在は問わない（呼び出し側 gh_preflight で判定する）。
gh_resolve_dir() {
  local dir="${IDD_CLAUDE_HOOKS_DIR:-$HOME/.idd-claude/hooks}"
  while [ ${#dir} -gt 1 ] && [ "${dir: -1}" = "/" ]; do
    dir="${dir%/}"
  done
  printf '%s' "$dir"
}

# ─── gh_compare_semver ───
#
# 数値ベースの semver 比較（`major.minor.patch` 3 セグメント前提）。辞書順比較を避けるため
# `.` で split して数値比較する。比較対象に prefix（`v` 等）や suffix（`-beta` 等）が
# 紛れている場合はセグメントごとに leading int を読む（保守的）。
#
# 入力: $1 = 比較される version / $2 = 最小要求 version
# 戻り値: 0 = $1 >= $2 / 1 = $1 < $2 / 2 = parse 失敗（呼び出し側で fail-closed 扱い）
gh_compare_semver() {
  local a="$1"
  local b="$2"
  local a_major a_minor a_patch
  local b_major b_minor b_patch
  local IFS='.'
  # shellcheck disable=SC2206
  local -a aa=($a)
  # shellcheck disable=SC2206
  local -a bb=($b)
  IFS=' '

  # セグメントごとに先頭の整数だけ取り出す（例: `2.1.167-beta` → `2` / `1` / `167`）
  _gh_seg() {
    local s="${1:-0}"
    # 先頭の整数部だけ残す（非数字以降は捨てる）
    local out=""
    local i=0
    while [ "$i" -lt "${#s}" ]; do
      local c="${s:$i:1}"
      case "$c" in
        [0-9]) out+="$c" ;;
        *) break ;;
      esac
      i=$((i + 1))
    done
    [ -z "$out" ] && out=0
    printf '%s' "$out"
  }

  a_major="$(_gh_seg "${aa[0]:-0}")"
  a_minor="$(_gh_seg "${aa[1]:-0}")"
  a_patch="$(_gh_seg "${aa[2]:-0}")"
  b_major="$(_gh_seg "${bb[0]:-0}")"
  b_minor="$(_gh_seg "${bb[1]:-0}")"
  b_patch="$(_gh_seg "${bb[2]:-0}")"

  # 一切数値が拾えなければ parse 失敗（保守的に rc=2）
  case "$a_major$a_minor$a_patch$b_major$b_minor$b_patch" in
    *[!0-9]*) return 2 ;;
  esac

  if [ "$a_major" -gt "$b_major" ]; then return 0; fi
  if [ "$a_major" -lt "$b_major" ]; then return 1; fi
  if [ "$a_minor" -gt "$b_minor" ]; then return 0; fi
  if [ "$a_minor" -lt "$b_minor" ]; then return 1; fi
  if [ "$a_patch" -ge "$b_patch" ]; then return 0; fi
  return 1
}

# ─── gh_preflight ───
#
# opt-in 時の fail-closed ゲート。決定論的に以下の順で評価する（Req 5.1〜5.5）:
#   1. claude --version を取得し、IDD_CLAUDE_HOOKS_MIN_VERSION（既定 `2.1.167`）と比較
#      → 不足なら stderr に理由を出して return 11
#   2. install dir 配下に idd-guard.sh / idd-guard-settings.json の両方が存在するかを確認
#      → 不在なら return 12
#   3. smoke test: 固定 fixture JSON を stdin に流して idd-guard.sh を起動し、exit 0 かつ
#      stdout に `"decision"` リテラルが含まれない（= allow 動作）ことを確認 → 失敗で
#      return 13
# すべて通れば return 0。副作用は stderr 出力のみ。
gh_preflight() {
  local hooks_dir
  hooks_dir="$(gh_resolve_dir)"
  local min_version="${IDD_CLAUDE_HOOKS_MIN_VERSION:-2.1.167}"

  # 1. claude version check
  if ! command -v claude >/dev/null 2>&1; then
    gh_error "claude CLI が PATH 上に見つかりません（IDD_CLAUDE_HOOKS_ENABLED=true 時は必須）"
    gh_error "Claude Code を install するか、PATH を見直してください"
    return 11
  fi
  local raw_version
  raw_version="$(claude --version 2>/dev/null || true)"
  # `claude --version` の出力例: `2.1.167 (Claude Code)` / `claude 2.1.167` 等を許容
  # 先頭の数値部を空白 / 括弧前で抽出する
  local detected
  detected="$(printf '%s' "$raw_version" | awk '{ for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+\.[0-9]+/) { print $i; exit } }')"
  if [ -z "$detected" ]; then
    gh_error "claude --version の出力から version を抽出できませんでした（raw='$raw_version'）"
    gh_error "claude CLI が正常か確認し、IDD_CLAUDE_HOOKS_MIN_VERSION の前提を見直してください"
    return 11
  fi
  if ! gh_compare_semver "$detected" "$min_version"; then
    gh_error "claude version $detected は最小要件 $min_version を満たしません"
    gh_error "Claude Code を $min_version 以上に更新するか、IDD_CLAUDE_HOOKS_MIN_VERSION を緩めてください"
    return 11
  fi
  gh_log "preflight version ok detected=$detected min=$min_version"

  # 2. install dir completeness
  local hook_script="$hooks_dir/idd-guard.sh"
  local hook_settings="$hooks_dir/idd-guard-settings.json"
  if [ ! -f "$hook_script" ] || [ ! -f "$hook_settings" ]; then
    gh_error "guard hook install dir が不完全です: dir=$hooks_dir"
    [ ! -f "$hook_script" ] && gh_error "  missing: $hook_script"
    [ ! -f "$hook_settings" ] && gh_error "  missing: $hook_settings"
    gh_error "install.sh --local を再実行して hook 一式を配置してください"
    return 12
  fi
  if [ ! -x "$hook_script" ]; then
    gh_error "guard hook script に実行権限がありません: $hook_script"
    gh_error "install.sh --local を再実行するか chmod +x で実行権限を付与してください"
    return 12
  fi
  gh_log "preflight install dir ok dir=$hooks_dir"

  # 3. smoke test
  local smoke_input='{"tool_name":"Bash","tool_input":{"command":"echo idd-guard-smoke-ok"}}'
  local smoke_stdout smoke_rc
  smoke_stdout="$(printf '%s' "$smoke_input" | bash "$hook_script" 2>&1)" && smoke_rc=0 || smoke_rc=$?
  if [ "$smoke_rc" -ne 0 ]; then
    gh_error "guard hook smoke test が非ゼロ exit しました（rc=$smoke_rc）"
    gh_error "  hook stdout/stderr 末尾: $(printf '%s' "$smoke_stdout" | tail -n 3)"
    return 13
  fi
  # allow 期待: decision フィールドが含まれてはならない
  if printf '%s' "$smoke_stdout" | grep -q '"decision"'; then
    gh_error "guard hook smoke test が想定外に deny を返しました"
    gh_error "  hook stdout: $smoke_stdout"
    gh_error "  IDD_HOOK_BASE_BRANCH / IDD_CLAUDE_HOOKS_DIR の設定を確認してください"
    return 13
  fi
  gh_log "preflight smoke test ok"

  return 0
}

# ─── gh_build_args ───
#
# claude CLI 起動時に追加すべき引数列を CLAUDE_HOOK_ARGS グローバル配列に構築する（Req 1.1, 1.2）。
#   opt-out 時: ()                                  → claude 起動引数列に何も追加されない
#   opt-in 時 : (--settings <install_dir/idd-guard-settings.json 絶対パス>)
#
# 呼び出し側は `claude --print "$prompt" ... "${CLAUDE_HOOK_ARGS[@]}"` の形で展開する。
# bash の `set -u` 配下で空配列展開は bash 4.4+ で安全（CLAUDE.md bash 4+ 要求）。
gh_build_args() {
  # shellcheck disable=SC2034  # CLAUDE_HOOK_ARGS is consumed by issue-watcher.sh call sites
  CLAUDE_HOOK_ARGS=()
  if ! gh_is_enabled; then
    return 0
  fi
  local hooks_dir
  hooks_dir="$(gh_resolve_dir)"
  # shellcheck disable=SC2034  # CLAUDE_HOOK_ARGS is consumed by issue-watcher.sh call sites
  CLAUDE_HOOK_ARGS=(--settings "$hooks_dir/idd-guard-settings.json")
}
