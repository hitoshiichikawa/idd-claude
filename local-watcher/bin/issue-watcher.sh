#!/usr/bin/env bash
# =============================================================================
# idd-claude local issue watcher
#
# GitHub Issue をポーリングし、auto-dev ラベルが付いた未処理 Issue を検出して
# Claude Code でローカル実行する。
#
# 3 つのモードを状態機械で管理:
#   - design        : PM → Architect → PjM（設計 PR 作成、awaiting-design-review 付与）
#   - impl          : PM → Developer → PjM（小〜中規模、Architect 不要）
#   - impl-resume   : Developer → PjM（設計 PR が merge 済みで docs/specs/<N>-*/ が main に存在）
#
# ラベルによる状態遷移:
#   auto-dev  → claude-claimed (Dispatcher claim) → Triage
#                              → (needs-decisions | awaiting-design-review | claude-picked-up)
#                              → ready-for-review / claude-failed
#
# Stage Checkpoint Resume 経路 (#68, デフォルト有効 / #112):
#   STAGE_CHECKPOINT_ENABLED=true（既定）で impl / impl-resume の Stage A/B/C 失敗時に
#   完了済み Stage を成果物（impl-notes.md / review-notes.md / 既存 impl PR）の
#   存在で観測し、未完了 Stage 以降のみを再実行する。`=false` を明示すると本機能導入前と
#   同等の Stage A 起点固定挙動に戻る（NFR 1.1）。判定根拠は `stage-checkpoint:` prefix の
#   ログで観測可能。
#
# 本体（このファイル）の構成（#455 分割完了 / Phase 1 gate #468）:
#   config source（watcher-config.sh）→ Config 由来 helper（本体残置 3 関数 / load-order pin）
#   → bootstrap（gtimeout fallback / 前提ツールチェック / module loader / guard hook 配線 /
#   起動 config log / --doctor dispatch / flock / repo 最新化）→ main loop（各 processor の
#   top-level 呼び出し）→ Phase C Dispatcher（slot 並列化の入口）。processor / gate /
#   pipeline ヘルパーの実体はすべて modules/*.sh 側にあり、本体には call site のみが残る
#   （詳細は main loop 冒頭の「モジュール分割完了マニフェスト」コメント参照）。
#
# 配置先: ~/bin/issue-watcher.sh（同階層に watcher-config.sh と modules/*.sh を要配置）
# 依存  : gh / jq / claude / flock / git / timeout（macOS は gtimeout フォールバック）
#
# セットアップ: 環境ごとの設定は同階層 watcher-config.sh を編集する（#460 で本体冒頭の
#   Config ブロックから分離）。配置は install.sh --local、起動登録は launchd (macOS) /
#   cron (Linux)。README.md を参照。
# =============================================================================

set -euo pipefail

# cron / launchd は対話シェルの profile を読まないため PATH が最小限になり、
# ~/.local/bin や /usr/local/bin にインストールした claude / gh が見つからない。
# 一般的なインストール先を先頭に足しておき、どの起動経路でも同じ挙動にする。
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config（環境に合わせて書き換える）→ watcher-config.sh へ分離済み（#460）
#
# 従来この位置にあった Config ブロック（REPO / REPO_DIR / ラベル名 / *_ENABLED フラグ /
# per-repo env ファイルロード #386 / Reviewer・Security 等の各種プロンプト・モデル・
# タイムアウト定義とその正規化）は、本体行数削減のため同階層の watcher-config.sh へ
# 移動した。set -euo pipefail 下・module loader / --doctor dispatch より前の本位置で
# source するため、挙動は分離前と完全に等価。config 書き換え運用の編集対象は
# watcher-config.sh 側になる。
# 配置先解決は $HOME 直書きせず BASH_SOURCE 基準にし、開発 repo 直実行（local-watcher/bin/）と
# インストール後（$HOME/bin/）の双方で同一ロジックが効くようにする。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
IDD_CONFIG_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/watcher-config.sh"
[ -f "$IDD_CONFIG_FILE" ] || { echo "Error: watcher-config.sh が見つかりません: $IDD_CONFIG_FILE" >&2; echo "  install.sh --local を再実行してください。" >&2; exit 1; }
# shellcheck source=/dev/null
. "$IDD_CONFIG_FILE"

# ─── Config ブロック由来の helper 関数（本体残置 / #460）───
# 以下 3 関数（full_auto_enabled / extract_review_result_token / parse_review_result）は
# #348 / #375 / #385 で Config ブロック近傍に「前出し」された純粋 helper。load-order 近接
# テスト（full_auto_enabled_load_order / pr_reviewer_parse_review_result_load_order）が
# 「定義行 < caller 行」を issue-watcher.sh 単一ファイル内で検証するため、config 分離後も
# 本体に残置する。config source より後・全 caller より前の本位置に置くことで従来と同じ
# load-order を保つ（挙動不変）。
# Issue #348 / #375: full-auto 系 processor の単一 kill switch 判定関数。
# 引数: なし
# 戻り値: 0 = kill switch ON（= full-auto を許可） / 1 = OFF（= 全 full-auto 抑止）
# 副作用: なし（純粋関数）
#
# `FULL_AUTO_ENABLED` env を `=true` 厳密一致で判定する（Req 1.2, 1.3）。
# 値正規化に失敗した状態（未設定 / 空 / `False` / `True` / `1` / `on` / typo）は
# すべて OFF として扱う（NFR 1.1 安全側）。本関数は **すべての** full-auto 系
# processor の入口で AND 条件として参照される（Req 2.1〜2.5）。`full_auto_enabled`
# が 1 を返した場合、当該 processor は外部副作用なしで早期 return する（Req 2.1〜2.5）。
#
# 本体残置理由（load-order）: 全 caller（module 側の各 processor: process_auto_merge /
# process_auto_merge_design / dr_unblock_sweep / process_needs_decisions_auto 等）より前に
# 定義される必要がある。末尾に置くと前方参照となり `command not found` (rc=127) の silent
# no-op を招く（#348 → #375 で本位置へ move して修正）。回帰は
# full_auto_enabled_load_order_test.sh が「定義行 < caller 行」で機械検証する。
#
# Config ブロックで値正規化が完了している前提だが、外部から `FULL_AUTO_ENABLED` を
# unset した状態で本関数だけが evaluation される万が一の経路でも安全側に倒すため、
# `${FULL_AUTO_ENABLED:-false}` で fallback する。
full_auto_enabled() {
  case "${FULL_AUTO_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── extract_review_result_token <path> ───
#
# review-notes.md 全文を scan し、`RESULT: approve` または `RESULT: reject` トークンの
# **最後のマッチ**を採用して `approve` / `reject` を stdout に echo する（Issue #63）。
#
# 抽出ルール（Issue #63 Req 1.x）:
#   - 全文 scan（行頭固定マッチではない）
#   - 行頭・行末のバッククォート / bullet (`-` `*`) / blockquote (`>`) / 引用符 / 空白等の
#     decoration を許容（前後の文字を問わない）
#   - 同一行内に末尾プローズが続いても許容（例: `RESULT: approve ...`）
#   - 複数マッチ時は **ファイル順で最後のマッチ** を採用
#   - lowercase の `approve` / `reject` のみ受理（`Approve` / `APPROVE` は不可、Req 1.7）
#   - "approve" / "reject" の前後は word boundary 相当（後続が単語文字なら不採用）
#
# 戻り値:
#   0 = マッチあり（stdout に approve / reject）
#   1 = マッチなし（stdout は空、ファイル無も含む）
#
# 本体残置理由（load-order）: `parse_review_result` の依存関数として、同じく Config ブロック
# 直後に前出し配置する。詳細は `parse_review_result` 側コメント参照。
extract_review_result_token() {
  local path="$1"
  [ -f "$path" ] || return 1

  # `RESULT:` の後に 1 個以上の空白、続いて `approve` または `reject`、
  # その直後が単語文字でない（または行末）場合のみマッチ。
  # grep -oE で全マッチを行ごとに抽出 → tail -1 で最後の 1 件を採用。
  # set -euo pipefail 下で grep no-match (rc=1) を呑み込むため `|| true` を付与。
  local matches last
  matches=$(grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' "$path" 2>/dev/null || true)
  [ -n "$matches" ] || return 1
  last=$(printf '%s\n' "$matches" | tail -n 1)

  # 末尾の境界文字を取り除いて approve / reject だけを残す。
  case "$last" in
    *approve*) echo "approve"; return 0 ;;
    *reject*)  echo "reject";  return 0 ;;
  esac
  return 1
}

# ─── parse_review_result <path> ───
#
# review-notes.md から RESULT 行（最後に出現するもの）と Findings の Category / Target を
# 抽出する。RESULT 行抽出は `extract_review_result_token` に委譲し、装飾・インライン記述
# (Issue #63) に耐性を持つ。
# stdout に TSV 1 行で出力: <result>\t<categories>\t<target_ids>
#
# - result      ∈ {approve, reject}
# - categories  = カンマ区切り（reject 時のみ。approve 時は空文字）
# - target_ids  = カンマ区切り requirement ID または `boundary:<component>` 形式
#
# 戻り値:
#   0 = 抽出成功
#   2 = ファイル有だが RESULT トークン欠落 / 値不正（装飾起因の parse 失敗）
#   3 = ファイル不在（Reviewer subagent が Write 漏れ / Issue #296 で導入）
#
# rc=2 と rc=3 の使い分け（Issue #296 Req 1）:
#   - rc=2 は #63 で確立した装飾耐性パースを経た上でも RESULT 行が抽出できなかった
#     ケース（「装飾起因 parse 失敗」）。
#   - rc=3 は `review-notes.md` 自体が存在しないケース（Reviewer subagent の Write 漏れ）。
#     呼び出し側で 1 回限定リトライを試みる経路を発火させるためのシグナル。
#
# 本体残置理由（load-order）: catch-up 経路（process_claude_review_status_catchup）が
# `declare -F parse_review_result` で存在確認するため、定義が call site より後ろだと
# `reason=parse-helper-missing` で safe-skip し、二重 opt-in（`PR_REVIEWER_STATUS_CHECK_ENABLED=true`
# AND `FULL_AUTO_ENABLED=true`）環境で `claude-review` status が永久に publish されない silent
# bug になる（#349 / #374 → #385 で本位置へ move して修正）。回帰は
# pr_reviewer_parse_review_result_load_order_test.sh が機械検証する。catch-up 側の
# `declare -F` 保険ガードは温存する（Req 3.3）。
parse_review_result() {
  local path="$1"
  if [ ! -f "$path" ]; then
    # Issue #296 Req 1.1: ファイル不在は装飾起因 parse 失敗（rc=2）とは区別して rc=3 で返す。
    return 3
  fi

  local result
  if ! result=$(extract_review_result_token "$path"); then
    # Issue #296 Req 1.2: ファイル存在下での RESULT 抽出失敗は装飾起因 parse 失敗として rc=2。
    return 2
  fi
  case "$result" in
    approve|reject) ;;
    *) return 2 ;;
  esac

  local categories=""
  local target_ids=""
  if [ "$result" = "reject" ]; then
    # Findings ブロックの "**Category**: ..." 行と "**Target**: ..." 行を抽出。
    # Findings は markdown bullet なので、行頭の "- " も含めて許容する。
    categories=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Category\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Category\*\*:[[:space:]]*//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
    target_ids=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Target\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Target\*\*:[[:space:]]*//' \
                   | sed -E 's/（.*$//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
  fi

  printf '%s\t%s\t%s\n' "$result" "$categories" "$target_ids"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# gtimeout 透過フォールバック（macOS coreutils 互換 / #168）
#
# macOS には GNU coreutils の `timeout` が標準搭載されておらず、`brew install coreutils`
# で導入しても通常 `gtimeout` という名前でインストールされる。`timeout` が PATH 上に
# 無く `gtimeout` がある環境では、`timeout` という呼び出しを `gtimeout` の実行に解決する
# シェル関数を定義し、以降のスクリプト内の `timeout ...` 呼び出し（コマンド置換 / サブ
# シェル / バックグラウンド fork / オプション付き呼び出し）を透過的に gtimeout へ委譲する。
# `export -f` で `bash -c` 経由の子 bash にも関数を継承させる（Req 2.3）。
#
# Linux など `timeout` が存在する環境ではこの関数を定義しないため、挙動は一切変わらない
# （NFR 1.1 / 1.2）。本フォールバックは下の前提ツールチェックより前に確立する（Req 1.3）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
  # shellcheck disable=SC2317  # 関数本体は後続の `timeout ...` 呼び出しから実行される
  timeout() { gtimeout "$@"; }
  export -f timeout
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提ツールチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in gh jq claude git flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd が見つかりません。PATH を確認してください。" >&2
    exit 1
  }
done

# timeout は gtimeout フォールバック（上記）込みで判定する。フォールバック関数が定義済み
# なら `command -v timeout` は function として true を返す。いずれも無い場合は macOS 向けの
# 解決手順を添えて明示エラーで停止する（Req 3.1 / 3.2 / 3.3）。
command -v timeout >/dev/null 2>&1 || {
  echo "Error: timeout コマンドが見つかりません。PATH を確認してください。" >&2
  echo "  macOS では 'brew install coreutils' で gtimeout を導入すると自動検出されます。" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# モジュール動的ロード基盤（#177 Part 1）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 本体と同階層の modules/ から必須モジュール（低レベル共通ユーティリティ等）を source する。
# install.sh が local-watcher/bin/modules/ → $HOME/bin/modules/ に配置する。
# 必須モジュールが欠落していたら、復旧手順を添えて exit 1 で安全停止する（silent fail を作らない）。
# 配置先解決は $HOME 直書きせず BASH_SOURCE 基準にし、開発 repo 直実行（local-watcher/bin/）と
# インストール後（$HOME/bin/）の双方で同一ロジックが効くようにする。
IDD_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/modules"
# source 順序は機能的に任意（bash の遅延束縛で前方参照は呼び出し時に解決される）が、
# 可読性のため最も低レベルな core_utils.sh を先頭に置き、以降は #180 Part 2 で切り出した
# 3 プロセッサ（quota-aware / merge-queue / auto-rebase）、#181 Part 3 で切り出した
# 3 プロセッサ（promote-pipeline / pr-iteration / stage-a-verify）を並べ、末尾に
# #238 の scaffolding-health.sh と #239 の per-run evidence サマリ（run-summary.sh）、
# #325 の token usage 計測（token-usage.sh）を置く。
REQUIRED_MODULES=( "core_utils.sh" "env-loader.sh" "quota-aware.sh" "merge-queue.sh" "auto-rebase.sh" "auto-merge.sh" "auto-merge-design.sh" "auto-merge-disarm.sh" "path-overlap.sh" "promote-pipeline.sh" "pr-iteration-comments.sh" "pr-iteration-state.sh" "pr-iteration-oos.sh" "pr-iteration-exec.sh" "pr-iteration.sh" "pr-reviewer-exec.sh" "pr-reviewer-publish.sh" "pr-reviewer.sh" "adjudicator.sh" "pr-design-reviewer.sh" "stage-a-verify.sh" "scaffolding-health.sh" "run-summary.sh" "token-usage.sh" "security-review.sh" "guard-hook.sh" "context-map.sh" "failed-recovery-attempt.sh" "failed-recovery-invoke.sh" "failed-recovery.sh" "stale-pickup-reaper.sh" "needs-decisions-auto.sh" "dep-cycle-detect.sh" "slack-notify.sh" "auto-merge-merged.sh" "design-review-release.sh" "tasks-count-gate.sh" "debugger-gate.sh" "stage-checkpoint.sh" "per-task-loop.sh" "impl-pipeline.sh" "dependency-resolver.sh" "slot-worker.sh" )
for _idd_mod in "${REQUIRED_MODULES[@]}"; do
  _idd_mod_path="$IDD_MODULE_DIR/$_idd_mod"
  if [ ! -f "$_idd_mod_path" ]; then
    echo "Error: 必須モジュールが見つかりません: $_idd_mod_path" >&2
    echo "  install.sh --local を再実行して modules/ を配置してください。" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$_idd_mod_path"
done
unset _idd_mod _idd_mod_path

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PreToolUse Guard Hook 配線 (#294 / base 初版)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# guard-hook.sh モジュールの関数（gh_is_enabled / gh_preflight / gh_build_args）を呼び、
# opt-in 時のみ claude CLI 起動時に注入する `CLAUDE_HOOK_ARGS` グローバル配列を構築する。
# opt-out 時は空配列 `()` → 既存の各 claude 起動箇所で `"${CLAUDE_HOOK_ARGS[@]}"` を展開しても
# 引数が一切追加されず、本機能導入前と完全に同一の引数列で claude が起動される（NFR 1.1 /
# Req 1.1, 1.2）。
#
# opt-in 時は以下を順に行う（fail-closed / Req 5.1〜5.5）:
#   1. gh_preflight: claude version 確認 → install dir 完全性 → smoke test を fail-closed で
#      連鎖判定する。失敗 (rc=11/12/13) → 非ゼロ exit して watcher 全体を停止する
#      （黙って guard を無効化する fallback は持たない / Req 5.5）
#   2. IDD_HOOK_BASE_BRANCH を export: hook プロセスは claude プロセスから env 継承するため、
#      watcher が `BASE_BRANCH` を hook 側の判定基準として渡す唯一の経路（design.md Env Var
#      Contract）。
#   3. gh_build_args: `CLAUDE_HOOK_ARGS=(--settings <絶対パス>)` を構築。以降の `claude --print
#      ... "${CLAUDE_HOOK_ARGS[@]}"` 展開で settings.json を Claude Code に渡す。
if gh_is_enabled; then
  gh_preflight || exit $?
  export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"
fi
gh_build_args

[ -f "$TRIAGE_TEMPLATE" ] || {
  echo "Error: Triage テンプレートが見つかりません: $TRIAGE_TEMPLATE" >&2
  exit 1
}

# PR Iteration が有効化されている時のみ template の存在を必須化する（#112 以降デフォルト有効）。
# 明示的に無効化（PR_ITERATION_ENABLED=false）した場合は template 未配置でも watcher 全体を
# 起動できるよう、無条件チェックを避ける。
if [ "$PR_ITERATION_ENABLED" = "true" ] && [ ! -f "$ITERATION_TEMPLATE" ]; then
  echo "Error: Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# 設計 PR Iteration が有効化されている時のみ design 用 template を必須化（#35 AC 2.2）。
if [ "$PR_ITERATION_ENABLED" = "true" ] \
   && [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ] \
   && [ ! -f "$ITERATION_TEMPLATE_DESIGN" ]; then
  echo "Error: 設計 PR 用 Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE_DESIGN" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# Phase D (Auto Rebase) が有効化されている時のみ template の存在を必須化（opt-in
# gate）。`AUTO_REBASE_MODE=off`（既定）時は template 未配置でも watcher 全体を
# 起動できるよう、無条件チェックを避ける（NFR 1.1）。
if [ "$AUTO_REBASE_MODE" != "off" ] && [ ! -f "$AUTO_REBASE_TEMPLATE" ]; then
  echo "Error: Auto Rebase テンプレートが見つかりません: $AUTO_REBASE_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# 解決済みの起動 config を 1 行で log 出力（Req 1.7 / NFR 4.1）。base-branch / full-auto /
# auto-merge / auto-merge-design / needs-decisions-mode / auto-rebase-semantic / slack-notify /
# pr-reviewer-adjudicator / design-reviewer / oos-enabled 等の解決値を含め、運用者が
# `grep '<token>='` で各 gate の現在状態（既定反転後に `=false` を明示した opt-out 含む）を
# 事後判別できるようにする。既定値（main 等）でも明示出力する（#348 / #352 / #354 / #362 /
# #366 / #370 / #412 / #432 で順次トークン追加）。
# 注: `design-reviewer=` トークンが共有 config echo に載ることは #412 `pr-reviewer-adjudicator=`
# と同じ扱いで、「processor 専用観測ログ行ゼロ」invariant（Req 1.4 / NFR 2.1）には抵触しない。
_idd_sn_resolved="off"
if [ "${SLACK_NOTIFY_ENABLED:-false}" = "true" ]; then
  _idd_sn_resolved="on"
fi
echo "[$(date '+%F %T')] base-branch=${BASE_BRANCH} merge-queue-base=${MERGE_QUEUE_BASE_BRANCH} auto-rebase=${AUTO_REBASE_MODE} auto-rebase-semantic=${AUTO_REBASE_SEMANTIC} auto-merge=${AUTO_MERGE_ENABLED} auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED} full-auto=${FULL_AUTO_ENABLED} needs-decisions-mode=${NEEDS_DECISIONS_MODE} slack-notify=${_idd_sn_resolved} pr-reviewer-adjudicator=${PR_REVIEWER_ADJUDICATOR_ENABLED} design-reviewer=${DESIGN_REVIEWER_ENABLED} oos-enabled=${PR_ITERATION_OOS_ENABLED}"
unset _idd_sn_resolved

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# doctor サブコマンド dispatch (#238 / Decision 2)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# `issue-watcher.sh --doctor` は full watcher サイクルを回さず、現行 env（REPO / REPO_DIR /
# BASE_BRANCH）で解決された repo の装備状態を read-only で点検しレポートして終了する（Req 4）。
# module source 完了後・flock 取得の前に置くことで、稼働中の watcher が flock を握っていても
# doctor は即実行できる（doctor は read-only で多重起動防止の対象外 / Decision 2）。
case "${1:-}" in
  --doctor)
    sh_doctor_run
    exit $?
    ;;
esac

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 多重起動防止
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "[$(date '+%F %T')] 他のインスタンスが実行中のためスキップ"
  # ── #243: flock skip path-overlap 可視化フック ──
  # PATH_OVERLAP_CHECK=true のときのみ、dispatch を伴わない read+label/comment の
  # 可視化パスを 1 サイクル実行する。off/未設定/不正値では一切呼ばず従来と完全一致（Req 6.1/6.2 / NFR 1.1）。
  if [ "${PATH_OVERLAP_CHECK:-off}" = "true" ]; then
    po_run_flock_skip_visibility || true   # NFR 3.2: 失敗でも exit 0 を維持
  fi
  exit 0   # NFR 1.1: exit code 不変
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# リポジトリを最新化
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
cd "$REPO_DIR"
git fetch origin --prune

# Issue #119 Req 3.1〜3.5: cycle 冒頭で working tree が dirty なまま
# `git checkout $BASE_BRANCH` に進むと「local changes would be overwritten」
# 等の git 純正 stderr が repo 識別子なしで cron.log に流れ、複数リポ運用時に
# 「processor ステージに到達しなかった silent failure」を grep で検知できない。
# `git status --porcelain` で先読みし、dirty なら以下 4 行を `watcher:` prefix で
# 1 イベント連続出力し、processor ステージを開始せずに exit 非 0 で抜ける。
# auto-recover は本要件 Out of Scope（別 Issue）。本実装は可視化のみを行う。
_dirty_status=$(git status --porcelain 2>/dev/null || true)
if [ -n "$_dirty_status" ]; then
  _current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  # dirty_files: 行数（CR/CRLF も 1 行扱いになるよう wc -l を使う）。空文字列は
  # 上の `-n "$_dirty_status"` で除外済み。
  _dirty_files=$(printf '%s\n' "$_dirty_status" | wc -l | tr -d ' ')
  _head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  echo "[$(date '+%F %T')] watcher: [$REPO] dirty working tree blocks BASE_BRANCH checkout" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   current_branch=${_current_branch}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   dirty_files=${_dirty_files}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   head=${_head_sha}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   action=escalate" >&2
  exit 1
fi
unset _dirty_status

git checkout "$BASE_BRANCH"
git pull --ff-only origin "$BASE_BRANCH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# メインループ: Processor / Gate 実行順序（モジュール分割完了マニフェスト / #455 Phase 1・#468 gate）
#
# 旧 issue-watcher.sh にインライン定義されていた processor / gate / pipeline ヘルパー群は
# すべて modules/*.sh へ切り出し済み（#177 Part 1 〜 #467）。本体に残るのは以下の top-level
# 呼び出し（call site）のみで、実行順序は分割前と完全に不変。bash は遅延束縛のため、関数定義の
# 物理位置が module へ移っても、loader（上記 REQUIRED_MODULES）が main loop より前に全 module を
# source する限り、呼び出し順序・名前解決の結果は変わらない。
#
# 参照（本体では再掲せず二重管理を避ける / CLAUDE.md「機能追加ガイドライン §4」）:
#   - 各 module の関数一覧・設計参照 : modules/*.sh 冒頭ヘッダ
#   - prefix ⇄ module 対応          : CLAUDE.md「機能追加ガイドライン §2 命名」の prefix 表
#   - 配布ツリー                    : README「ディレクトリ構成」
#   - processor ロガー              : core_utils.sh に同居（qa_log / mq_log / pi_log / rv_log …）
#
# 主な設計ドキュメント（docs/specs/ 配下）: Merge Queue / Promote / Auto Rebase / Path Overlap
# （#15-18）/ Reviewer Gate（#20）/ Per-task TDD Loop（#21）/ Debugger Gate（#22）/
# Stage Checkpoint（#68）/ Stage A Verify（#125）/ Phase C Dispatcher（#16、本体末尾に残置）。
#
# 以降、各 call 直上のコメントは「その call をなぜこの順序に置くか」の根拠のみを述べる
# （切り出し済み関数の一覧は本マニフェストへ集約したため、call ごとには再掲しない）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Quota Resume Processor を全 Processor の先頭で実行する（Req 5.1, 5.6 / NFR 3.2）。
# 失敗時も後続 Processor を阻害しないよう || qa_warn で吸収。
process_quota_resume || qa_warn "process_quota_resume が想定外のエラーで終了しました（後続 Processor は継続）"

# AC 1.1: Phase A 本体ループの直前に Re-check Processor を 1 回起動
process_merge_queue_recheck || mqr_warn "process_merge_queue_recheck が想定外のエラーで終了しました（後続処理は継続）"

# AC 1.1: ピックアップ済み Issue の処理ループに入る前に 1 回だけ起動
process_merge_queue || mq_warn "process_merge_queue が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Phase D: Auto Rebase Processor (#17)
# Re-check → Phase A 本体 の直後に直列配置し、Req 3.1〜3.3 を構造的に保証する
# （design.md「順序根拠」参照）。`AUTO_REBASE_MODE=off`（既定）では関数冒頭で
# 早期 return するため、未設定環境では実質 no-op（NFR 1.1）。
process_auto_rebase || ar_warn "process_auto_rebase が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Auto-Merge Processor (#352) — modules/auto-merge.sh が定義
#   実装 PR（head が `^claude/issue-.*-impl` パターン、`ready-for-review` ラベル、draft でない、
#   `mergeable=MERGEABLE`）に対して `gh pr merge --auto --squash --delete-branch` で
#   GitHub ネイティブの auto-merge を有効化する。AND 二重 opt-in (`AUTO_MERGE_ENABLED=true`
#   AND `FULL_AUTO_ENABLED=true`) の双方 ON 時のみ発火し、それ以外は外部副作用ゼロで
#   早期 return する（Req 1.5, 6.1, NFR 1.1）。Phase D の直後（merge-queue / auto-rebase
#   の CONFLICTING 経路がラベル付与・rebase を試行した後）に直列配置し、CONFLICTING
#   PR を auto-merge が奪わないように順序を担保する（Req 4.1: needs-rebase を触らない）。
process_auto_merge || am_warn "process_auto_merge が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Design Auto-Merge Processor (#354) — modules/auto-merge-design.sh が定義
#   設計 PR（head が `^claude/issue-.*-design` パターン、draft でない、`mergeable=MERGEABLE`）
#   に対して `gh pr merge --auto --squash --delete-branch` で GitHub ネイティブの auto-merge を
#   有効化する。AND 二重 opt-in (`AUTO_MERGE_DESIGN_ENABLED=true` AND `FULL_AUTO_ENABLED=true`)
#   の双方 ON 時のみ発火。#352 Auto-Merge との非干渉は head pattern の server-side filter で
#   担保（Req 6.7）。Design Review Release Processor (#40) は merge 後のラベル後始末を担う
#   独立 processor として共存する（Req 5.2, 5.3）。配置順序は #352 直後（impl と対称）/
#   Promote Pipeline 前（Req 5.4 / 8.4）。
process_auto_merge_design || amd_warn "process_auto_merge_design が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Auto-Merge Disarm Processor (#434) — modules/auto-merge-disarm.sh が定義
#   arm 済み（`autoMergeRequest != null`）の open PR が `claude-failed` / `needs-decisions` といった
#   terminal ラベルへ遷移した時点で `gh pr merge --disable-auto` で native auto-merge を取り消す。
#   arm 時点判定（am_should_enable_for_pr）は arm 後の遷移を追えず、失敗確定済み PR が status checks
#   の green 到達で誤 merge される不具合（Defect A）を解消する。GitHub を直接クエリして対象を列挙し、
#   pending state dir には依存しない（Req 1.4）。opt-in gate は FULL_AUTO_ENABLED AND
#   (AUTO_MERGE_ENABLED OR AUTO_MERGE_DESIGN_ENABLED)。いずれの arm 源も OFF（既定）なら gh API
#   ゼロ呼び出しで本不具合修正導入前と等価（NFR 1.1）。arm 側（#352 / #354）の直後に直列配置し、
#   同一サイクルで arm された PR でも terminal ラベルが付いていれば即 disarm できるようにする。
process_auto_merge_disarm || amx_warn "process_auto_merge_disarm が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Auto-Merge Merged Notify Processor (#388) — modules/auto-merge-merged.sh が定義
#   `auto-merge` / `auto-merge-design` で armed された PR の実 merge 完了を pending
#   state file 突合 + `gh pr view` で観測し、event_type=auto-merge-merged /
#   auto-merge-design-merged の Slack 通知を 1 度だけ送信する。
#   `SLACK_NOTIFY_MERGED_ENABLED=true` 厳密一致以外は早期 return（gh API ゼロ呼び出し /
#   NFR 4.1）。armed 直後ではなく後続サイクルで観測するため、本 processor 単体では
#   armed 動作自体を遅らせない（auto-merge / auto-merge-design の直後に直列配置）。
process_auto_merge_merged || amm_warn "process_auto_merge_merged が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# AC 1.1: Phase A 本体の直後に Promote Pipeline Processor を 1 回起動。
# fail-continue を維持するため `|| pp_warn ...` で例外を吸収（NFR 3.1）。
process_promote_pipeline \
  || pp_warn "process_promote_pipeline が想定外のエラーで終了しました（後続 Processor は継続）"

# PR Reviewer Processor (#261) を PR Iteration の直前に実行。レビュー結果で付与した
# needs-iteration ラベルを同一 flock 内で直後の process_pr_iteration が引き継げる
# （PR_REVIEWER_ENABLED!=true なら即 return 0 で本機能導入前と等価、NFR 1.1）。
process_pr_reviewer || pr_warn "process_pr_reviewer が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Issue #374 claude-review Catch-up Processor を PR Reviewer の直後に実行。
# per-task ループ運用で `publish_claude_review_status` が PR 作成より前の時間軸で発火して
# WARN skip した分を、open PR scan で読み直して publish する catch-up 経路。
# AND 二重 opt-in（PR_REVIEWER_STATUS_CHECK_ENABLED=true AND FULL_AUTO_ENABLED=true）が
# 成立した場合のみ動作。OFF（既定）なら即 return 0 で本機能導入前と等価（NFR 1.1）。
# `PR_REVIEWER_ENABLED` の値には依存しない（claude-review 単独有効化を維持）。
process_claude_review_status_catchup || pr_warn "process_claude_review_status_catchup が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Issue #412 Merge Gate Visibility Processor を catch-up の直後に実行。
# `claude-review` を required status に採用した repo で、adjudicator も Reviewer catch-up も
# 発火せず `claude-review` が publish されない停滞 PR を検知して可視化する（label 付与 +
# 観測ログ）。`claude-review` が required でない repo では即 return 0（gh api 1 回のみ /
# NFR 1.1 ほぼ no-op）。adjudicator や catch-up が後発で publish に成功した場合は次サイクル
# 冒頭で当該 PR がケース 1 / ケース 2 として解消され、label が冪等に除去される（Req 4.3）。
process_claude_review_merge_gate_visibility || pr_warn "process_claude_review_merge_gate_visibility が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Issue #407: Design PR Reviewer Processor。設計 PR (`claude/issue-<N>-design-<slug>`) 専用の
# 独立 Claude レビュアを起動し、claude-review status と needs-iteration ラベルを確定する。
# #432 で既定 ON（opt-out）化: 既定では本 processor が起動し設計 PR を判定する。
# `DESIGN_REVIEWER_ENABLED=false` を明示した場合のみ即 return 0 で本変更前の opt-in 既定 OFF と
# 完全に等価（claude / gh / git 追加呼び出しゼロ / 観測ログ diff ゼロ / NFR 1.1, 2.1）。
# 配置順: impl 経路（process_pr_reviewer + process_claude_review_status_catchup）が一巡してから
# 本 design 経路に入ることで、設計 PR が万一 impl 経路から claude-review を書かれても
# 本 processor が後発で確定する（design.md「claude-review publisher contention」節）。
# impl 経路（pr-reviewer.sh / adjudicator.sh / catch-up）は不変（Req 7.2, 7.3）。
process_pr_design_reviewer || pdr_warn "process_pr_design_reviewer が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Security Review Processor (#279) を PR Reviewer の直後・PR Iteration の直前に実行。
# advisory 固定動作（ラベル操作なし）のため PR Reviewer の needs-iteration 付与とは
# 競合しない。PR タイムライン上で「外部 AI レビュー → セキュリティレビュー → iteration
# 反復」の時系列が運用者に提示される（SECURITY_REVIEW_ENABLED!=true なら即 return 0 で
# 本機能導入前と等価、NFR 1.1）。
process_security_review || sec_warn "process_security_review が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Phase A 直後に PR Iteration Processor を実行（AC 8.1 / 8.2: 同一 flock 内で直列実行）
process_pr_iteration || pi_warn "process_pr_iteration が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Failed Recovery Processor (#359) を PR Iteration の直後・Design Review Release の直前に実行。
# `claude-failed` Issue + auto-merge 待ち PR の CI error を fresh Claude session で
# 自動修正する。FAILED_RECOVERY_ENABLED=true AND FULL_AUTO_ENABLED=true の二重 opt-in
# が成立する場合のみ起動し、それ以外（既定）は即 return 0 で本機能導入前と等価（NFR 1.1, 1.3）。
# 通算 4 回上限（FAILED_RECOVERY_MAX_ATTEMPTS）と no-progress ガードで quota 燃焼を防ぐ。
process_failed_recovery || fr_warn "process_failed_recovery が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Stale Pickup Reaper (#379) を Failed Recovery の直後・Design Review Release の直前に実行。
# claude-picked-up / claude-claimed ラベルが残り continuance しないセッション喪失 Issue を
# 3 観点 AND（marker 経過時間 / slot ロック保持 / セッション存在）で「非アクティブ」確定した
# ものだけ auto-dev 状態へ戻す。STALE_PICKUP_REAPER_ENABLED=true 厳密一致のみ起動し、それ
# 以外（既定）は即 return 0 で本機能導入前と等価（NFR 1.1, 1.3）。claude-failed は #359
# の領分のため扱わない（領分分離）。
process_stale_pickup_reaper || sr_warn "process_stale_pickup_reaper が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Design Review Release Processor を Issue 処理ループの直前に実行（#40 AC 1.3 / 1.5）
process_design_review_release || drr_warn "process_design_review_release が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Dispatcher
#
# 1 サイクル中に 1 度起動される。Issue 候補をローカルキューに pop し、空き slot を
# 探索して claim（claude-claimed ラベル付与）してから Slot Runner をバックグラウンド
# 起動する。サイクル終端で `wait` により全 Worker 完了を待ち合わせる。
# claim ラベルは Issue #52 で claude-picked-up → claude-claimed に変更した
# （claim/Triage 段階を実装中段階と区別するため）。Triage 通過後の Slot Runner で
# claude-claimed → claude-picked-up に付け替える。
#
# Req 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 6.3, 6.4, 6.5, 7.5, NFR 1.1, NFR 1.2
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Dispatcher が抱える slot_n -> PID マッピング（bash associative array, 4.0+）。
# サブシェル fork 後、_slot_release で fd を閉じてもこの map で「どの slot が誰の
# 子プロセスか」を後で再特定できる。
declare -A _DISPATCHER_SLOT_PIDS

# ── Issue #170 Req 3: Dispatcher のシグナル捕捉（SIGINT / SIGTERM）──
# cron/launchd からの中断や手動 Ctrl-C 時、fork 済み slot worker（サブシェル）が
# 孤立して `.broken-*` worktree が蓄積するのを防ぐための最小実装。
#
# 本 trap は Dispatcher トップレベル（メインスクリプト本体）に置く。サブシェル
# `( _slot_run_issue ... ) &` 内には伝播しない（trap はサブシェルでリセットされる）ため、
# 既存のサブシェル内ローカル EXIT trap（rebase/revert/checkout の base branch 復帰）の
# 挙動は一切変更しない（Req 3.4）。flock fd 200 は本プロセス終了時に OS が解放するため、
# 多重起動防止ロックの解放契約も従来どおり維持される（Req 3.3）。
#
# NFR 2.2: 同一シグナルが処理中に再送されても worktree prune を二重実行しないよう
# ガードフラグ _DISPATCHER_SIGNAL_HANDLED で 1 回に制限する。
_DISPATCHER_SIGNAL_HANDLED=0
# shellcheck disable=SC2317  # trap 経由で間接呼び出しされるため到達不能に見えるが正しく実行される
_dispatcher_on_signal() {
  local sig="$1"
  # 再入ガード（NFR 2.2）: 既に処理済みなら何もしない。
  if [ "$_DISPATCHER_SIGNAL_HANDLED" -ne 0 ]; then
    return 0
  fi
  _DISPATCHER_SIGNAL_HANDLED=1
  dispatcher_warn "シグナル ${sig} を受信。fork 済み slot worker を終了し worktree prune を実行します"

  # Req 3.1: fork 済みの slot worker 子プロセスへ終了シグナルを送る。
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  # 子プロセスの終了を回収（孤立防止）。reap 失敗は致命化させない。
  wait 2>/dev/null || true

  # Req 3.2 / NFR 2.2: worktree prune を 1 回だけ実行する。
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true

  # 中断由来の終了 exit code は 128+signal（bash 慣例）。SIGINT=130 / SIGTERM=143。
  local rc=143
  case "$sig" in
    INT) rc=130 ;;
    TERM) rc=143 ;;
  esac
  exit "$rc"
}
trap '_dispatcher_on_signal INT' INT
trap '_dispatcher_on_signal TERM' TERM

# 完了した子プロセスを slot_pid map から prune する。
# `kill -0 <pid>` が失敗（プロセス不在）なら slot は空いたとみなす。
_dispatcher_reap_finished_slots() {
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -z "$pid" ]; then
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      continue
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      # 子プロセス終了済 → slot 解放
      wait "$pid" 2>/dev/null || true
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      dispatcher_log "slot-${n}: completed (pid=$pid)"
    fi
  done
}

# 空き slot を探す（reap → 1..PARALLEL_SLOTS で _slot_acquire）。
# 戻り値: 0 = 取得成功（slot 番号を stdout に echo） / 1 = 全 slot busy
_dispatcher_find_free_slot() {
  _dispatcher_reap_finished_slots
  local n
  for ((n=1; n<=PARALLEL_SLOTS; n++)); do
    # 既に PID マップに載っている slot は busy
    if [ -n "${_DISPATCHER_SLOT_PIDS[$n]:-}" ]; then
      continue
    fi
    if _slot_acquire "$n"; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

# 1 サイクル分の Dispatcher を実行する。
# 戻り値: 0 = 正常完了（個々の Worker の成否は Issue ラベル経由で表現）/ 非ゼロ = 致命的失敗
_dispatcher_run() {
  # Req 1.3: PARALLEL_SLOTS 検証 → 不正なら ERROR ログ + exit 1
  if ! _parallel_validate_slots; then
    return 1
  fi

  # Issue #346: Dependency Auto-Unblock Sweep をメイン候補クエリより前段で 1 回実行
  # （Req 2.3）。`DEP_AUTO_UNBLOCK_ENABLED=true` のときのみ起動し、OFF / 未設定 /
  # 不正値では gh API ゼロ呼び出しで即 return する（NFR 1.1, 2.1）。本機能導入前と
  # 完全に同一の `_dispatcher_run` 挙動を保つため、fail-open（`|| true`）で sweep の
  # 失敗が dispatcher サイクルを壊さない（NFR 3.2）。
  dr_unblock_sweep || true

  # Req 7.5: 既存の Issue 取得クエリ（フィルタ・limit 5）を据え置き
  # Issue #54 Req 1.1 / 1.3 / 5.2: PR 専用ラベル `needs-iteration` が誤って Issue 側に
  # 付与されているケースを除外する（人為ミスでの impl-resume 起動 → 既存 PR 破壊事故防止）。
  # Issue #66 Req 3.5 / 3.6: quota wait 中の Issue は再 claim しないよう
  # `needs-quota-wait` を除外条件に追加。既存除外条件の意味・順序は変更しない。
  # Issue #100 Req 2.1: multi-branch 運用で develop に merge 済み・main 到達待ちの
  # Issue（`staged-for-release` 付与）を Triage / Dispatcher / PR Iteration が誤って
  # 再 pickup しないよう除外する。single-branch 運用では本ラベルは付与されない想定なので
  # 影響なし（NFR 1.2: 既存除外条件の意味・順序は変更しない）。
  # Issue #146: 依存 Issue 未 merge による blocked 状態を pickup 候補から除外する。
  # PM phase の Dependency Resolver Gate が付与し、人間が依存解消後に手動除去すると
  # 次サイクルで通常 pickup に再合流する（Req 4.1, 4.2）。既存除外ラベルとは独立した
  # 状態遷移を持ち、`needs-decisions` と並列指定する（Req 9.3 / NFR 1.3）。
  #
  # Issue #200: 候補処理順を FIFO（Issue 番号昇順 = 古いものから）にし、`hotfix`
  # ラベル付き Issue を非 hotfix より先に投入する 2 段優先を導入する。
  # `--limit 5`（= 1 サイクルで評価する候補件数上限）の意味は据え置く（Req 3.3）が、
  # 単純に「created-desc で 5 件切り出してから並べ替え」だと最も古い Issue や
  # 6 件目以降の hotfix を取りこぼす（Req 3.1 / 3.2）。これを避けるため:
  #   1) hotfix ティアを `sort:created-asc`（古いもの優先）で別クエリ取得し、
  #   2) 非 hotfix を含む全候補も `sort:created-asc` で取得する
  # 両クエリの除外フィルタ・取得フィールドは従来と完全同一。各クエリで `--limit` 件
  # ずつ取ることで、各ティアの「最も古い候補の先頭」が limit 切り出しから漏れない。
  # 取得後は jq で hotfix ティア優先 + 各ティア内 Issue 番号昇順に安定ソートし、
  # number で dedup したうえで先頭から $DISPATCH_LIMIT 件に切り詰める（NFR 2.1）。
  local search_filter="-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"$LABEL_BLOCKED\""
  # 1 サイクルで投入対象として評価する候補件数の上限（本機能導入前と同一の既定 5）。
  local DISPATCH_LIMIT=5

  local hotfix_issues all_issues
  # (1) hotfix ティア: created-asc で取得（最も古い hotfix を limit 切り出しで失わない）
  hotfix_issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --label "$LABEL_HOTFIX" \
    --state open \
    --search "$search_filter sort:created-asc" \
    --json number,title,body,url,labels \
    --limit "$DISPATCH_LIMIT")
  # (2) 全候補（hotfix / 非 hotfix 混在）: created-asc で取得（最も古い Issue を失わない）
  all_issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --state open \
    --search "$search_filter sort:created-asc" \
    --json number,title,body,url,labels \
    --limit "$DISPATCH_LIMIT")

  # 両クエリ結果を結合し、hotfix ティア優先 + 各ティア内 Issue 番号昇順で安定ソート、
  # number で dedup して先頭 $DISPATCH_LIMIT 件に切り詰める。
  # - `.labels` 欠落 / null や label 配列に hotfix 名が無い候補は安全側で非 hotfix 扱い（Req 2.4）。
  # - hotfix ティアを 0、非 hotfix を 1 とし、(tier, number) の昇順で並べることで
  #   Req 2.1 / 2.2 / 2.3（hotfix 先行・同一ティア内 number 昇順）を満たす。
  local issues
  issues=$(jq -c -n \
    --argjson limit "$DISPATCH_LIMIT" \
    --arg hotfix "$LABEL_HOTFIX" \
    --slurpfile hf <(printf '%s' "$hotfix_issues") \
    --slurpfile al <(printf '%s' "$all_issues") '
    ([ $hf[0][]?, $al[0][]? ])
    | map(. + { _is_hotfix: ((.labels // []) | map(.name) | index($hotfix) != null) })
    | unique_by(.number)
    | sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])
    | .[0:$limit]
    | map(del(._is_hotfix))
  ')

  local count
  count=$(echo "$issues" | jq 'length')
  if [ "$count" -eq 0 ]; then
    # Req 1.4 / 7.6: PARALLEL_SLOTS=1 + 対象なし時の挙動を本機能導入前と同等に保つ。
    # （prefix dispatcher: は付くが、メッセージ本体は既存と同じ）
    echo "[$(date '+%F %T')] 処理対象の Issue なし"
    return 0
  fi

  # Req 6.3: サイクル開始ログ（処理対象件数 + 利用可能 slot 数）
  dispatcher_log "対象 Issue ${count} 件 / 利用可能 slot ${PARALLEL_SLOTS} 件"

  # Req 1.4 互換のため、PARALLEL_SLOTS=1 のときも従来と同じ（prefix なし）件数 echo を出す。
  # 既存ユーザー / cron の grep 監視を破壊しない（"N 件の Issue を処理します" 行）。
  if [ "$PARALLEL_SLOTS" -eq 1 ]; then
    echo "[$(date '+%F %T')] $count 件の Issue を処理します"
  fi

  # Issue キューを 1 件ずつ pop して slot に投入
  local issue
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    local issue_number
    issue_number=$(echo "$issue" | jq -r '.number')

    # ── Pre-Claim Filter (Issue #65 Req 1.1〜1.7) ──
    # claim 直前に linked impl PR を GraphQL で確認し、OPEN/MERGED が存在すれば
    # 当該サイクルを skip する。claim ラベル（claude-claimed）を一切付与しないため、
    # 次サイクル以降の `gh issue list` フィルタからも除外されず、人間が PR を解消
    # するか `auto-dev` を外すまで本 Issue を触らない（事故防止 / Req 1.2 / 1.3）。
    # check_existing_impl_pr 内で skip 判定行は pclp_log/warn で記録済み（NFR 2.1〜2.3）。
    # GraphQL 失敗 / レート制限も内部で skip 側に倒される（fail-safe / Req 1.7 / NFR 4.2）。
    # PR 不在の通常運用では exit 0 で素通り = 本機能導入前と完全等価（NFR 1.5）。
    if ! check_existing_impl_pr "$issue_number"; then
      continue
    fi

    # ── Open Design PR Guard (Issue #191 Req 1〜4) ──
    # claim 直前に、対象 Issue 番号に対応する head ブランチ
    # `claude/issue-<N>-design-*` の OPEN な PR が存在するかを確認し、存在すれば
    # 当該サイクルを skip する。check_existing_impl_pr が impl PR のみを対象とし
    # design PR を ignore するため（reason=design-pr-in-closing-refs）、保護ラベル
    # （awaiting-design-review / blocked）が外れた状態で open design PR を持つ Issue が
    # 再 pickup され、design モード再実行で PjM が人間レビュー済み design PR を
    # クローズして作り直す事故（#180 / PR #184）を構造的に防ぐ（二重防御 / Req 2）。
    # linked 非依存の head ref strict 一致で検出（Req 1.4 / 1.5）。検出失敗 / timeout /
    # レート制限は内部で skip 側に倒される（fail-safe / Req 3.1 / 3.2）。skip 判定行は
    # pclp_log/warn で記録済み（Req 4.1 / 4.2）。design PR を持たない通常 Issue では
    # open design PR 不在で exit 0 = 本機能導入前と完全等価（NFR 1.1）。本ガードは
    # Issue pickup 経路にのみ作用し、PR 駆動の design PR 反復経路には触れない（Req 5）。
    if ! check_open_design_pr "$issue_number"; then
      continue
    fi

    # ── Phase E: Path Overlap Gate (#18 Req 1.x / 5.x / 6.x) ──
    # PATH_OVERLAP_CHECK=true のときのみ有効。未設定 / off / 不正値では関数冒頭で
    # 早期 return 0 = 従来挙動と完全一致（NFR 1.1）。
    # `awaiting-slot` 付き Issue を candidate query から除外していないため、本 gate が
    # 後続 cron tick でも再評価され、overlap empty なら同サイクル内に
    # po_clear_awaiting_slot → claim 続行する（Req 6.1 / 6.2 / 6.4 を構造的に保証）。
    local labels_json
    labels_json=$(echo "$issue" | jq -c '.labels')
    if ! po_check_dispatch_gate "$issue_number" "$labels_json"; then
      continue
    fi

    # ── 空き slot 探索（busy なら 1 件完了するまで待機）──
    local slot=""
    while true; do
      if slot=$(_dispatcher_find_free_slot); then
        break
      fi
      # 全 slot busy → 1 件完了を待つ（bash 4.3+ の `wait -n`）
      if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -eq 0 ]; then
        # 子プロセス未起動かつ全 slot 取得失敗 → 取れる slot がない異常事態
        # （他 watcher プロセスが slot lock を握っているなど）
        dispatcher_warn "全 slot がロック中（_slot_acquire いずれも失敗）。Issue #${issue_number} は次サイクルへ持ち越し"
        slot=""
        break
      fi
      wait -n 2>/dev/null || true
      _dispatcher_reap_finished_slots
    done

    if [ -z "$slot" ]; then
      # ── Phase E: 多忙サイクル待ちの可視化 (#228 Req 3.1〜3.2 / 3.4 / 5.1 / 5.2) ──
      # 候補が全 gate を通過したが空き slot を確保できず当該サイクルの dispatch を
      # 見送った（自インスタンス全 slot busy / 別インスタンス稼働で全 slot lock 中）。
      # PATH_OVERLAP_CHECK=true のときのみ連続見送り tick を数え、可視化閾値を超えたら
      # 待機中シグナル（awaiting-slot + 専用 sticky comment）を残す。off / 不正値では
      # po_check_busy_wait が即 return 0 = 本機能導入前と完全に同一挙動（ローカル
      # state も GitHub 状態も変更しない / NFR 1.1）。dispatch 経路は阻害しない。
      po_check_busy_wait "$issue_number" "空き slot 不足（先行 Issue 処理中 / 別インスタンス稼働）" || true
      continue
    fi

    # dispatch に成功する見込み（空き slot を確保）。多忙サイクル待ちの連続見送り
    # tick state をリセットし、次に再び見送られたときは 1 から数え直す（#228 Req 3.3）。
    # off 時は state ファイル自体が存在しないため no-op（冪等）。
    if [ "${PATH_OVERLAP_CHECK:-off}" = "true" ]; then
      po_busy_wait_reset "$issue_number"
    fi

    # ── claim（claude-claimed ラベル付与）──
    # Issue #52: claim/Triage 段階のラベルを claude-claimed に分離（claude-picked-up は
    # Triage 通過後に Slot Runner が付け替える）。これにより Issue activity 上で
    # claim 済 / Triage 中 / 実装中 が 1 ラベル単位で識別可能になる。
    if ! gh issue edit "$issue_number" --repo "$REPO" --add-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
      # Req 2.3: ラベル付与失敗 → WARN + slot lock 解放 + 次 Issue へ
      dispatcher_warn "Issue #${issue_number}: claude-claimed ラベル付与に失敗、slot-${slot} を解放して次 Issue へ"
      _slot_release "$slot"
      continue
    fi

    # Req 6.4: 投入時刻ログ
    dispatcher_log "dispatched #${issue_number} -> slot-${slot}"

    # ── Slot Runner をバックグラウンド起動 ──
    # サブシェル `( ... ) &` で fork。サブシェルは親の fd を継承するため
    # _slot_acquire で取得した lock fd は subshell が引き続き保持する。
    ( _slot_run_issue "$slot" "$issue" ) &
    local pid=$!
    _DISPATCHER_SLOT_PIDS[$slot]=$pid

    # 親 Dispatcher 側の fd を解放する。これにより、Dispatcher が同 slot を再
    # acquire しようとしたとき、subshell が lock を保持している間は flock -n が
    # 失敗するようになる（claim atomicity の構造的保証）。
    _slot_release "$slot"
  done <<< "$(echo "$issues" | jq -c '.[]')"

  # Req 2.6: サイクル終端で全 Worker を待ち合わせる
  # Slot Runner 内で claude-failed 化等は完結済のため exit code は無視
  if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -gt 0 ]; then
    dispatcher_log "全 Worker 完了を待機中 (${#_DISPATCHER_SLOT_PIDS[@]} 件 in flight)"
    wait
    _dispatcher_reap_finished_slots
  fi

  dispatcher_log "サイクル完了"
  return 0
}

# Dispatcher を起動（既存 Issue 処理ループの置換）。
_dispatcher_run
DISPATCHER_RC=$?
if [ "$DISPATCHER_RC" -ne 0 ]; then
  # Req 1.3: PARALLEL_SLOTS 不正値などで _dispatcher_run が non-zero を返した場合は
  # サイクル中断（既存の ERROR 終了規約 = exit 1 と整合）
  exit "$DISPATCHER_RC"
fi

echo "[$(date '+%F %T')] 完了"
exit 0

