#!/usr/bin/env bash
# env-loader.sh — watcher の per-repo env ファイル ローダモジュール（Issue #386 / F8）
#
# 用途:
#   watcher 起動時に per-repo env ファイルを source して `*_ENABLED` 系フラグを供給し、
#   crontab 行を `REPO` / `REPO_DIR` / `BASE_BRANCH` といった repo 識別系の最小限に保てる
#   ようにする。crontab 行長限界（~1024 文字）で `command too long` が発生する事態を解消する。
#
#   - el_log / el_warn               : ロガー（既存 *_log / *_warn と同形式の `[$REPO]` 3 段 prefix）
#   - el_resolve_env_file            : `WATCHER_ENV_FILE` → `$HOME/.issue-watcher/<REPO_SLUG>.env`
#                                       の探索順で読取可能な絶対パスを 1 つ解決（純粋関数）
#   - el_apply_env_file              : 解決済み env ファイルを 1 行ずつ解釈し、未設定 KEY のみ
#                                       環境変数として export する
#   - el_load                        : 上記 2 つを束ねる public entry point。本体から 1 回だけ呼ぶ
#
#   評価順序（el_load）:
#     1. el_resolve_env_file rc=1（候補なし）→ silent return 0（NFR 1.1 / Req 5.1）
#     2. 解決済みパスを el_log で 1 行記録（NFR 3.1）
#     3. el_apply_env_file が 1 行ずつパース → 値評価 → precedence 判定 → export
#
#   precedence:
#     - inline cron env > env ファイル（Req 4.1〜4.4）。
#     - 「inline cron env」とは el_apply_env_file 呼出時点で既にプロセス env に存在する変数。
#     - 同一 KEY が env ファイルに含まれていても、`${KEY+x}` が定義済みなら skip する。
#     - watcher 本体側の `KEY="${KEY:-default}"` 形式の後方で、本 module 経由で export された
#       KEY も「inline cron env と同様に既存値」として扱われ、ハードコードされた default で
#       上書きされない（Req 4.2 / NFR 1.3）。
#
#   値評価:
#     - 値文字列に `$HOME` / `$VAR` / `$(...)` を含められる（Req 3.1, 3.2）。
#     - `eval "export $KEY=\"$VALUE\""` で起動シェルの展開を借りる。env ファイルは運用者管理
#       ファイル（信頼境界の内側 / NFR 2.4）として扱い、サニタイズは行わない。
#     - コマンド置換が非 0 終了した場合は当該 KEY を未設定のまま残し、warn + 次行へ継続
#       （Req 3.3 / Req 6.3）。
#
#   異常系:
#     - 構文不正行（`=` 欠落 / `KEY` が識別子として無効）は当該行のみ skip + warn（Req 6.2）。
#     - ファイル読取不能（権限不足等）は warn + 何もせず継続（Req 6.1）。
#     - 警告メッセージにはパスと行番号を含める（Req 6.5）。
#
# 配置先:
#   $HOME/bin/modules/env-loader.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_SLUG / $HOME）は本体側 Config ブロックで定義済みである前提。
#   - 外部 CLI: date のみ（ロガー用）。
#   - 関数 prefix `el_` を namespace として採用する（新規未使用 prefix / CLAUDE.md §2）。
#
# セットアップ参照先:
#   README.md（オプション機能一覧 / per-repo env ファイル節）
#   docs/specs/386-feat-watcher-per-repo-env-crontab-f8/requirements.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ロガー（既存 fr_log / sn_log と同形式の 3 段 prefix）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NFR 2.2 / 3.4: env ファイル内の値（webhook URL 等の機密候補）は warn 出力にも載せない。
# 呼び出し側は KEY 名 / パス / 行番号 / 失敗種別のみを渡す契約。
el_log() {
  echo "[$(date '+%F %T')] [${REPO:-?}] env-loader: $*"
}
el_warn() {
  echo "[$(date '+%F %T')] [${REPO:-?}] env-loader: WARN: $*" >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# el_resolve_env_file: env ファイルの絶対パスを探索順で解決する（Req 1.1〜1.5）
#
#   探索順:
#     1. `WATCHER_ENV_FILE` が絶対パス + 通常ファイル + 読取可能 → 採用（Req 1.2）
#     2. `$HOME/.issue-watcher/<REPO_SLUG>.env` が同条件を満たす → 採用（Req 1.3 / 1.4）
#     3. いずれも該当しなければ rc=1（候補なし / Req 1.5）
#
#   引数: なし（env から `WATCHER_ENV_FILE` / `HOME` / `REPO_SLUG` を読む）
#   stdout: 採用した env ファイルの絶対パス（成功時）
#   戻り値: 0 = 採用 / 1 = 候補なし
#   副作用: なし（純粋関数 / NFR 2.1: 絶対パス + 通常ファイル + 読取権限あり の使用前検証）
# ─────────────────────────────────────────────────────────────────────────────
el_resolve_env_file() {
  local candidate=""

  # 候補 1: WATCHER_ENV_FILE（運用者明示指定 / Req 1.2）
  # 絶対パスのみ受理（path traversal 予防 / NFR 2.1）。空文字 / 未設定 / 相対パスは次候補へ。
  if [ -n "${WATCHER_ENV_FILE:-}" ]; then
    case "$WATCHER_ENV_FILE" in
      /*)
        if [ -f "$WATCHER_ENV_FILE" ] && [ -r "$WATCHER_ENV_FILE" ]; then
          printf '%s\n' "$WATCHER_ENV_FILE"
          return 0
        fi
        ;;
    esac
  fi

  # 候補 2: $HOME/.issue-watcher/<REPO_SLUG>.env（規約パス / Req 1.3 / 1.4）
  # REPO_SLUG / HOME が空のときは候補生成不能として次へ（NFR 2.1 安全側）。
  if [ -n "${HOME:-}" ] && [ -n "${REPO_SLUG:-}" ]; then
    candidate="${HOME}/.issue-watcher/${REPO_SLUG}.env"
    if [ -f "$candidate" ] && [ -r "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# el_apply_env_file: 解決済み env ファイルを 1 行ずつ解釈して環境変数を export する
#
#   引数: $1 = 採用済み env ファイルの絶対パス
#   戻り値: 0 = 通常終了（行 skip 含む） / 1 = ファイル読取不能（Req 6.1）
#   副作用: 各 KEY を export（既に env に存在する KEY はスキップ / Req 4.1）
#
#   1 行のパース仕様:
#     - 空行 / 先頭文字が `#` の行 → skip（Req 2.2 / 2.3）
#     - 行頭の空白は除去（leading whitespace のみ）
#     - `KEY=VALUE` 形式: `^[A-Za-z_][A-Za-z0-9_]*=` を正規表現で検査
#     - KEY が識別子として無効 / `=` なし → warn + skip（Req 6.2）
#     - VALUE は KEY= 以降の残り全文字（trailing newline は read -r が消化済み）
#     - VALUE 評価: `eval "export $KEY=\"$VALUE\""` で `$HOME` / `$VAR` / `$(...)` を展開
#     - eval rc != 0（コマンド置換失敗等）→ warn + skip（Req 3.3 / 6.3）
#
#   precedence（Req 4.1 / NFR 1.3）:
#     - `${KEY+x}` で「env に既に定義済み」を判定し、定義済みなら skip。
#     - inline cron env で既に export された KEY が env ファイルで上書きされない。
#
#   NFR 2.2 / 3.4: warn 出力に KEY 名 / パス / 行番号は含めるが、VALUE 本体は含めない。
# ─────────────────────────────────────────────────────────────────────────────
el_apply_env_file() {
  local env_file="$1"

  if [ ! -r "$env_file" ]; then
    el_warn "env ファイルが読取不能: $env_file"
    return 1
  fi

  local lineno=0
  local raw key value
  # `read -r` で改行までを 1 行として読む。最終行に改行がない場合に取りこぼさないよう
  # `|| [ -n "$raw" ]` で while ループを抜けずに最後の 1 行を処理する。
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # 行頭の空白を除去（行末はそのまま：VALUE に意図的な trailing space を残す可能性）。
    local stripped="${raw#"${raw%%[![:space:]]*}"}"

    # 空行 / コメント行 skip（Req 2.2 / 2.3）。
    case "$stripped" in
      ''|'#'*) continue ;;
    esac

    # `KEY=VALUE` 形式を正規表現で検査（Req 6.2）。
    # KEY は `[A-Za-z_][A-Za-z0-9_]*` の bash 識別子規約に従う。
    if ! [[ "$stripped" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      el_warn "構文不正行 skip: $env_file:$lineno"
      continue
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    # precedence: inline cron env > env ファイル（Req 4.1）。
    # `${KEY+x}` は KEY が定義済みなら "x"、未定義なら空文字を返す。空文字値を持つ KEY も
    # 「定義済み」として扱い、env ファイルでは上書きしない（inline 側の明示 unset 同義扱い）。
    if [ -n "${!key+x}" ]; then
      continue
    fi

    # 値評価: `eval` で `$HOME` / `$VAR` / `$(...)` を展開（Req 3.1 / 3.2）。
    # env ファイルは運用者管理ファイル（信頼境界の内側 / NFR 2.4）として扱う。
    #
    # `export VAR=$(cmd)` は POSIX 仕様上 export の rc を返すため、内部の command 置換が
    # 失敗（非 0 終了 / 実行不能）しても rc=0 で「成功した」ように見えてしまう。これを避ける
    # ため、(1) 単純代入だけを eval してその rc で置換失敗を検出（Req 3.3 / 6.3）し、
    # (2) 代入が成功した KEY を改めて `export` する 2 段構成にする。
    # `2>/dev/null` で stderr を握り潰してから自前 warn を出すことで、コマンド置換の
    # `command not found` 等のシステム由来メッセージで運用者のログを汚さない（NFR 3.4）。
    # NFR 2.2: 評価成功した値は warn / log に出力しない。
    if eval "$key=\"$value\"" 2>/dev/null; then
      # 代入成功 → export する。`export` 自体は失敗しない（既に代入済みの変数を flag するのみ）。
      # shellcheck disable=SC2163  # 動的 KEY を export するため間接 export を使う
      export "$key"
    else
      el_warn "値評価に失敗（コマンド置換不可 / 構文エラー等） skip: $env_file:$lineno KEY=$key"
      # 部分的に export された痕跡が残らないよう unset（保守的に状態を安定化）。
      unset "$key" 2>/dev/null || true
    fi
  done < "$env_file"

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# el_load: env-loader の public entry point。本体 Config ブロックから 1 回だけ呼ぶ。
#
#   引数: なし
#   戻り値: 常に 0（NFR 1.1 安全側 / 候補なしは silent / 異常系も警告のみで継続）
#   副作用: 採用した env ファイル経由で KEY を export（precedence は el_apply_env_file 参照）。
#           NFR 3.1: 採用時に 1 行 stdout ログを出す（値は出さない）。
#           NFR 3.3: 候補なし時はログを出さない（通常運用の標準ログを増やさない）。
# ─────────────────────────────────────────────────────────────────────────────
el_load() {
  local env_file=""
  if ! env_file="$(el_resolve_env_file)"; then
    # 候補なし → silent return（Req 5.1 / NFR 3.3）。
    return 0
  fi
  # NFR 3.1: 採用したファイルパスを 1 行ログ（値は出さない）。
  el_log "env ファイル採用: $env_file"
  el_apply_env_file "$env_file" || true
  return 0
}
