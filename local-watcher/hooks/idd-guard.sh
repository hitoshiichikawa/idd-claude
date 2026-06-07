#!/usr/bin/env bash
# idd-guard.sh
#
# 用途: Claude Code の PreToolUse フックとして起動され、Bash / Edit / Write /
#       NotebookEdit ツール呼び出しを検査して以下のいずれかに該当すれば deny する。
#       - G1: base ブランチ (`$IDD_HOOK_BASE_BRANCH`) 宛の push（bare / `HEAD:base` /
#             `:base` / `+base` / `-C path` / 暗黙 remote / `--delete` を含む全形態）
#       - G2: 無条件 force push（`-f` / `--force` / refspec 先頭 `+`）。
#             `--force-with-lease(=...)` は base 以外なら allow。
#       - G0: guard install dir (`$IDD_CLAUDE_HOOKS_DIR`、既定 `$HOME/.idd-claude/hooks`)
#             配下のファイルへの Edit / Write / NotebookEdit、および Bash 経由の
#             mutation コマンド（`rm` / `mv` / `sed -i` / `chmod` / リダイレクト / `tee`）。
#             Bash 経由は best-effort（NFR 3.3）。
#
# 配置先: $IDD_CLAUDE_HOOKS_DIR/idd-guard.sh
#          （install.sh が user-scope `$HOME/.idd-claude/hooks/` 既定で配置）
#
# 依存: bash 4+, jq
#
# 環境変数契約:
#   IDD_HOOK_BASE_BRANCH  base ブランチ名。未設定で `main` フォールバック
#   IDD_CLAUDE_HOOKS_DIR  guard install dir。未設定で `$HOME/.idd-claude/hooks`
#   IDD_HOOK_LOG          設定時は 1 行 append（任意）
#
# stdin / stdout:
#   stdin  : Claude Code PreToolUse JSON（`tool_name` / `tool_input` を含む）
#   stdout : decision JSON
#            - deny: {"decision":"block","reason":"..."}
#            - allow: {}
#   exit code: 常に 0（allow も deny も exit 0。エラーは fail-closed で block JSON）
#
# セットアップ参照先: README.md（同ディレクトリ）

set -euo pipefail

#
# Logging (optional)
#
hook_log() {
  local log_path="${IDD_HOOK_LOG:-}"
  [ -z "$log_path" ] && return 0
  printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" "$2" >>"$log_path" 2>/dev/null || true
}

#
# Output helpers
#
emit_allow() {
  printf '{}\n'
  hook_log "allow" "${1:-}"
  exit 0
}

emit_deny() {
  local reason="$1"
  # jq -n でエスケープ安全な JSON を構築
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg reason "$reason" '{decision: "block", reason: $reason}'
  else
    # jq 不在時は手書き（quote 最小エスケープ）
    local escaped="${reason//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    printf '{"decision":"block","reason":"%s"}\n' "$escaped"
  fi
  hook_log "deny" "$reason"
  exit 0
}

emit_deny_fail_closed() {
  emit_deny "guard hook internal error: $1"
}

#
# Path normalization
#
resolve_hooks_dir() {
  local dir="${IDD_CLAUDE_HOOKS_DIR:-$HOME/.idd-claude/hooks}"
  # 末尾スラッシュ除去
  while [ "${dir: -1}" = "/" ] && [ ${#dir} -gt 1 ]; do
    dir="${dir%/}"
  done
  printf '%s' "$dir"
}

# `~` / `$HOME` プレフィックスを展開し、`./` を除去した簡易絶対パス化
normalize_path() {
  local p="$1"
  # leading `~` を $HOME に展開（リテラル `~` を `$HOME` 展開対象として扱うため、
  # tilde の literal 比較を明示する。SC2088 は意図的な literal 比較）
  # shellcheck disable=SC2088
  local tilde_slash='~/'
  # shellcheck disable=SC2088
  local tilde='~'
  if [ "${p:0:2}" = "$tilde_slash" ]; then
    p="$HOME/${p:2}"
  elif [ "$p" = "$tilde" ]; then
    p="$HOME"
  fi
  printf '%s' "$p"
}

#
# G0: install dir self-mutation check
#
# Edit / Write / NotebookEdit の対象パスが install dir 配下なら deny
check_g0_path() {
  local target_path="$1"
  local hooks_dir
  hooks_dir="$(resolve_hooks_dir)"
  local normalized
  normalized="$(normalize_path "$target_path")"
  # プレフィックス一致（末尾区切りも含めて判定。`/dir` vs `/dir2` の誤一致を避ける）
  case "$normalized" in
    "$hooks_dir"|"$hooks_dir"/*)
      emit_deny "guard install dir self-mutation denied: path=$normalized"
      ;;
  esac
}

# Bash command 文字列に install dir のリテラル + mutation キーワードが両方含まれるか
check_g0_bash() {
  local cmd="$1"
  local hooks_dir
  hooks_dir="$(resolve_hooks_dir)"
  local literal_match=0

  # install dir 絶対パスか `~/.idd-claude/hooks` / `$HOME/.idd-claude/hooks` リテラル
  # が cmd に含まれるかを判定する。tilde / $HOME 展開はしたくない（substring 検出が目的）
  # ため意図的に literal を保持する。
  # shellcheck disable=SC2088
  local tilde_literal='~/.idd-claude/hooks'
  # shellcheck disable=SC2016
  local home_literal='$HOME/.idd-claude/hooks'
  if [[ "$cmd" == *"$hooks_dir"* ]] || [[ "$cmd" == *"$tilde_literal"* ]] \
       || [[ "$cmd" == *"$home_literal"* ]]; then
    literal_match=1
  fi
  [ "$literal_match" -eq 0 ] && return 0

  # mutation キーワード（best-effort）
  # `rm` / `mv` / `sed -i` / `chmod` / `>` / `>>` / `tee` / `cat >`
  if [[ "$cmd" =~ (^|[[:space:];&|])(rm|mv|chmod|tee)([[:space:]]|$) ]] \
       || [[ "$cmd" =~ sed[[:space:]]+-i ]] \
       || [[ "$cmd" =~ [[:space:]]\>\>?[[:space:]] ]] \
       || [[ "$cmd" =~ [[:space:]]\>\>?$ ]] \
       || [[ "$cmd" =~ cat[[:space:]]+\> ]]; then
    emit_deny "guard install dir self-mutation denied: path=$hooks_dir (bash best-effort)"
  fi
}

#
# Git push parsing for G1 / G2
#
# tokens 配列を引数で受け取り、git global options を skip して "push" 以降の
# token を抽出する。先頭 token は "git" 前提（呼び出し側で確認）。
#
# 出力: グローバル配列 PUSH_TOKENS を設定。git push でなければ空配列。
extract_push_tokens() {
  PUSH_TOKENS=()
  local -a in=("$@")
  local n=${#in[@]}
  [ "$n" -lt 2 ] && return 0
  [ "${in[0]}" != "git" ] && return 0

  local i=1
  while [ "$i" -lt "$n" ]; do
    local tok="${in[$i]}"
    case "$tok" in
      -C)
        # -C <path> をペアで skip
        i=$((i + 2))
        ;;
      --git-dir=*|--work-tree=*|--namespace=*)
        i=$((i + 1))
        ;;
      --git-dir|--work-tree|--namespace)
        i=$((i + 2))
        ;;
      -c)
        # -c key=value
        i=$((i + 2))
        ;;
      -c=*|--config-env=*)
        i=$((i + 1))
        ;;
      --exec-path=*|--exec-path)
        i=$((i + 1))
        ;;
      --*|-*)
        # その他の global option は単独 token として skip（保守的）
        i=$((i + 1))
        ;;
      push)
        # push 以降を PUSH_TOKENS に格納
        local j=$((i + 1))
        while [ "$j" -lt "$n" ]; do
          PUSH_TOKENS+=("${in[$j]}")
          j=$((j + 1))
        done
        return 0
        ;;
      *)
        # push 以外のサブコマンド
        return 0
        ;;
    esac
  done
}

# refspec から dst 部を抽出
# 入力: refspec 文字列（例: `main`, `HEAD:main`, `:main`, `+main`, `+HEAD:main`,
#       `+src:dst`）
# 出力: stdout に dst 名
extract_dst_from_refspec() {
  local rs="$1"
  # 先頭の `+` を除去
  [ "${rs:0:1}" = "+" ] && rs="${rs:1}"
  if [[ "$rs" == *:* ]]; then
    printf '%s' "${rs#*:}"
  else
    printf '%s' "$rs"
  fi
}

# refspec が `+` 接頭辞を持つか
refspec_has_plus_prefix() {
  [ "${1:0:1}" = "+" ]
}

# tokens 配列を引数で受け取り、push 用 G1/G2 判定を行う。
analyze_push() {
  local base_branch="${IDD_HOOK_BASE_BRANCH:-main}"
  local -a tokens=("$@")
  local n=${#tokens[@]}
  [ "$n" -eq 0 ] && return 0

  # flag 検出（G2 判定用）
  local has_force=0
  local has_lease=0
  local has_delete=0
  local i=0
  while [ "$i" -lt "$n" ]; do
    case "${tokens[$i]}" in
      -f|--force)
        has_force=1
        ;;
      --force-with-lease|--force-with-lease=*)
        has_lease=1
        ;;
      -d|--delete)
        has_delete=1
        ;;
    esac
    i=$((i + 1))
  done

  # non-flag token を順に抽出（remote / refspec 群）
  local -a positional=()
  i=0
  while [ "$i" -lt "$n" ]; do
    local t="${tokens[$i]}"
    case "$t" in
      -*)
        # `-o key=value` / `--receive-pack=...` 等のオプションを保守的に skip
        case "$t" in
          --*=*) ;;
          --*) ;;
          -*) ;;
        esac
        ;;
      *)
        positional+=("$t")
        ;;
    esac
    i=$((i + 1))
  done

  # positional[0] = remote 候補（暗黙 remote の場合は refspec の可能性）
  # positional[1..] = refspec 候補
  #
  # 暗黙 remote 判定: positional[0] が `<remote>` らしくない（`:` を含む / `+` 始まり）か、
  # またはそもそも positional が 1 件で base 名と一致するケースは refspec として扱う
  local -a refspecs=()
  local p_count=${#positional[@]}
  if [ "$p_count" -eq 0 ]; then
    # bare push（引数なし）。literal 解析では判定不能（NFR 3.2）。
    # G2 だけは判定可能
    :
  elif [ "$p_count" -eq 1 ]; then
    # 1 件のみ: remote 単独か暗黙 remote refspec か曖昧
    # `:`含み / `+`始まり なら refspec 扱い、それ以外は両方の可能性を考慮し
    # base 名と一致する場合は refspec として扱う（Req 2.6 暗黙 remote 対応）
    local p0="${positional[0]}"
    if [[ "$p0" == *:* ]] || [ "${p0:0:1}" = "+" ]; then
      refspecs+=("$p0")
    elif [ "$p0" = "$base_branch" ]; then
      # `git push main` 形式（暗黙 remote の base 宛 push）
      refspecs+=("$p0")
    elif [ "$has_delete" -eq 1 ]; then
      # `git push --delete main` 相当（remote 省略）も refspec 扱い
      refspecs+=("$p0")
    fi
    # それ以外は remote 名と解釈し refspec 不明（現ブランチ依存。literal 解析不能）
  else
    # 2 件以上: positional[0] が remote、残りが refspec
    # ただし positional[0] が `:` 含みなら remote 名ではないので全部 refspec 扱い
    local p0="${positional[0]}"
    if [[ "$p0" == *:* ]] || [ "${p0:0:1}" = "+" ]; then
      refspecs=("${positional[@]}")
    else
      refspecs=("${positional[@]:1}")
    fi
  fi

  # G1: base 宛判定（refspec の dst が base 一致 / delete の対象が base 一致）
  local rs
  for rs in "${refspecs[@]:-}"; do
    [ -z "$rs" ] && continue
    local dst
    dst="$(extract_dst_from_refspec "$rs")"
    if [ "$dst" = "$base_branch" ]; then
      emit_deny "base branch push denied: ref=$rs (base=$base_branch)"
    fi
  done

  # `--delete <ref>` 形式（refspec ではなく flag + positional）
  if [ "$has_delete" -eq 1 ]; then
    local pp
    for pp in "${positional[@]:-}"; do
      [ -z "$pp" ] && continue
      if [ "$pp" = "$base_branch" ]; then
        emit_deny "base branch push denied: --delete $pp (base=$base_branch)"
      fi
    done
  fi

  # G2: 無条件 force（-f / --force）
  if [ "$has_force" -eq 1 ]; then
    emit_deny "unconditional force push denied: use --force-with-lease"
  fi

  # G2: refspec 先頭 `+`（base 以外でも deny。base 宛は既に G1 で deny されている）
  for rs in "${refspecs[@]:-}"; do
    [ -z "$rs" ] && continue
    if refspec_has_plus_prefix "$rs"; then
      emit_deny "unconditional force push denied: refspec '+' prefix in '$rs' (use --force-with-lease)"
    fi
  done

  # G2: --force-with-lease は base 以外なら allow（明示的に何もしない）
  # （base 宛は既に G1 で deny されている）
  : "$has_lease"
}

#
# Bash command parser
#
# top-level command 文字列を token 配列に分割する（簡易 shell lexer）。
# - 単純な空白区切り
# - シングル / ダブルクォート対応（中身はそのまま 1 token）
# - エスケープ `\<char>` 対応
# - `;` / `&&` / `||` / `|` / `\n` の手前で打ち切り（先頭コマンド句のみ抽出）
#   理由: `git push origin main && do_other` の先頭句だけ評価対象とすればよい。
#   `sh -c "..."` / `$(...)` 内部は解析しない（NFR 3.1）
parse_top_level_tokens() {
  local cmd="$1"
  TOKENS=()
  local i=0
  local n=${#cmd}
  local cur=""
  local in_single=0
  local in_double=0

  while [ "$i" -lt "$n" ]; do
    local c="${cmd:$i:1}"

    if [ "$in_single" -eq 1 ]; then
      if [ "$c" = "'" ]; then
        in_single=0
      else
        cur+="$c"
      fi
      i=$((i + 1))
      continue
    fi

    if [ "$in_double" -eq 1 ]; then
      if [ "$c" = '"' ]; then
        in_double=0
      elif [ "$c" = "\\" ] && [ $((i + 1)) -lt "$n" ]; then
        local nx="${cmd:$((i + 1)):1}"
        cur+="$nx"
        i=$((i + 2))
        continue
      else
        cur+="$c"
      fi
      i=$((i + 1))
      continue
    fi

    case "$c" in
      "'")
        in_single=1
        ;;
      '"')
        in_double=1
        ;;
      "\\")
        if [ $((i + 1)) -lt "$n" ]; then
          cur+="${cmd:$((i + 1)):1}"
          i=$((i + 1))
        fi
        ;;
      " "|$'\t')
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        ;;
      $'\n'|";")
        # 先頭句で打ち切り
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        return 0
        ;;
      "&"|"|")
        # `&&` / `||` / `|` で打ち切り（次の文字も同じなら 2 文字、違っても 1 文字で打ち切り）
        if [ -n "$cur" ]; then
          TOKENS+=("$cur")
          cur=""
        fi
        return 0
        ;;
      *)
        cur+="$c"
        ;;
    esac
    i=$((i + 1))
  done

  if [ -n "$cur" ]; then
    TOKENS+=("$cur")
  fi
}

#
# Main dispatch
#
main() {
  # jq 不在は fail-closed
  if ! command -v jq >/dev/null 2>&1; then
    emit_deny_fail_closed "jq not found in PATH"
  fi

  local input
  input="$(cat || true)"
  [ -z "$input" ] && emit_allow "empty input"

  # JSON parse
  local tool_name
  if ! tool_name="$(printf '%s' "$input" | jq -er '.tool_name // empty')"; then
    emit_deny_fail_closed "failed to parse PreToolUse JSON (tool_name)"
  fi
  [ -z "$tool_name" ] && emit_allow "no tool_name"

  case "$tool_name" in
    Edit|Write)
      local file_path
      file_path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
      [ -n "$file_path" ] && check_g0_path "$file_path"
      emit_allow "$tool_name file_path ok"
      ;;
    NotebookEdit)
      local notebook_path
      notebook_path="$(printf '%s' "$input" | jq -r '.tool_input.notebook_path // .tool_input.file_path // empty')"
      [ -n "$notebook_path" ] && check_g0_path "$notebook_path"
      emit_allow "NotebookEdit path ok"
      ;;
    Bash)
      local command_str
      command_str="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
      [ -z "$command_str" ] && emit_allow "Bash empty command"

      # G0 (Bash best-effort)
      check_g0_bash "$command_str"

      # token 分割
      TOKENS=()
      parse_top_level_tokens "$command_str"

      # `git push` 解析
      if [ "${#TOKENS[@]}" -ge 1 ] && [ "${TOKENS[0]}" = "git" ]; then
        PUSH_TOKENS=()
        extract_push_tokens "${TOKENS[@]}"
        if [ "${#PUSH_TOKENS[@]}" -ge 0 ] && [ -n "${PUSH_TOKENS[*]:-}" ]; then
          analyze_push "${PUSH_TOKENS[@]}"
        fi
      fi

      emit_allow "Bash ok"
      ;;
    *)
      emit_allow "tool_name=$tool_name not in scope"
      ;;
  esac
}

main "$@"
