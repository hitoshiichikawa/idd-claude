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
# 配置先: ~/bin/issue-watcher.sh
# 依存  : gh / jq / claude / flock / git
#
# セットアップ: このファイル冒頭の ━━━ Config ━━━ ブロックを編集し、
#   launchd (macOS) または cron (Linux) に登録する。README.md を参照。
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
# 配置メモ (#375): bash は top-level コードを順次実行するため、関数定義は最初の
# 呼び出し（`process_auto_merge` / `process_auto_merge_design` の call site /
# line 1168 / 1178 相当、および `dr_unblock_sweep` / `process_needs_decisions_auto` /
# `dep-cycle-detect` 等）より物理的に前に配置する必要がある。元 #348 で本関数を
# スクリプト末尾近く（line 9926 相当）に置いた結果、call site から見て前方参照と
# なり `command not found` (rc=127) を返す load-order bug を発生させた。#375 では
# 本関数を `FULL_AUTO_ENABLED` 正規化処理の直後（Config ブロック内）に move し、
# 全 caller が定義位置より後ろに来ることを構造的に保証する。
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
# 配置メモ (#385): `parse_review_result` の依存関数として、`parse_review_result` と
# 同じく Config ブロック直後に前出ししている。元位置（line 6558 相当）からの move 理由は
# `parse_review_result` 側コメント参照。
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
# 配置メモ (#385): bash は top-level コードを順次実行するため、関数定義は最初の
# 呼び出し（`process_claude_review_status_catchup` の call site / line 1573 相当）
# より物理的に前に配置する必要がある。元 #349 / #374 で本関数をスクリプト中盤
# （line 6617 相当）に置いた結果、catch-up 経路から見て前方参照となり catch-up の
# `declare -F parse_review_result` ガードが false 評価となって `reason=parse-helper-missing`
# の WARN を残して safe-skip し、AND 二重 opt-in（`PR_REVIEWER_STATUS_CHECK_ENABLED=true`
# AND `FULL_AUTO_ENABLED=true`）環境で `claude-review` commit status が永久に publish
# されない silent load-order bug を発生させた。#385 では本関数を `full_auto_enabled` の
# 直後（Config ブロック内）に move し、全 caller が定義位置より後ろに来ることを構造的に
# 保証する。catch-up 側の `declare -F` 保険ガードは温存する（Req 3.3）。
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
REQUIRED_MODULES=( "core_utils.sh" "env-loader.sh" "quota-aware.sh" "merge-queue.sh" "auto-rebase.sh" "auto-merge.sh" "auto-merge-design.sh" "auto-merge-disarm.sh" "promote-pipeline.sh" "pr-iteration.sh" "pr-reviewer.sh" "adjudicator.sh" "pr-design-reviewer.sh" "stage-a-verify.sh" "scaffolding-health.sh" "run-summary.sh" "token-usage.sh" "security-review.sh" "guard-hook.sh" "context-map.sh" "failed-recovery.sh" "stale-pickup-reaper.sh" "needs-decisions-auto.sh" "dep-cycle-detect.sh" "slack-notify.sh" "auto-merge-merged.sh" "design-review-release.sh" "tasks-count-gate.sh" "debugger-gate.sh" "stage-checkpoint.sh" "per-task-loop.sh" "impl-pipeline.sh" )
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

# 解決済み base branch を起動時 log に出力（Req 1.7 / NFR 4.1）。
# 運用者が cron mailer / log で `base-branch=...` を grep できるよう、
# 既定値（main）でも明示的に出力する。
# Issue #348: cycle startup ログに `full-auto=` の解決値も含める（Req 4.2）。
# 運用者は `grep full-auto=` で現在の kill switch 状態を確認できる。
# Issue #352: cycle startup ログに `auto-merge=` の解決値も含める（Req 7.4）。
# Issue #354: cycle startup ログに `auto-merge-design=` の解決値も含める（Req 9.4）。
# 運用者は `grep auto-merge-design=` で現在の design auto-merge 有効状態を確認できる。
# Issue #362: cycle startup ログに `needs-decisions-mode=` の解決値も含める（Req 6.4）。
# 運用者は `grep needs-decisions-mode=` で現在の needs-decisions 自動続行モードを確認できる。
# Issue #366: cycle startup ログに `auto-rebase-semantic=` の解決値も含める（Req 1.6）。
# 運用者は `grep auto-rebase-semantic=` で Claude semantic 解決 gate の有効状態を確認できる。
# Issue #370: cycle startup ログに `slack-notify=` の解決値も含める（Req 1.2 / NFR 5.1）。
# 運用者は `grep slack-notify=` で現在の Slack 通知 emitter 有効状態を確認できる。
# Issue #412: cycle startup ログに `pr-reviewer-adjudicator=` の解決値も含める（Req 1.6 / NFR 2.2）。
# 運用者は `grep pr-reviewer-adjudicator=` で adjudicator 経路の有効 / 無効状態を事後に判別できる。
# 既定反転（OFF → ON）後、`=false` を明示した opt-out 環境を grep で識別する目的を兼ねる。
# Issue #432: cycle startup ログに `design-reviewer=` の解決値も含める（Req 1.6 / NFR 2.1）。
# 運用者は `grep design-reviewer=` で Design PR Reviewer 経路の有効 / 無効状態を事後に判別できる。
# 既定反転（OFF → ON）後、`=false` を明示した opt-out 環境を grep で識別する目的を兼ねる。共有
# 起動 config echo に `design-reviewer=` トークンが載ることは #412 の `pr-reviewer-adjudicator=`
# と同じ扱いであり、Req 1.4 / NFR 2.1 の「観測ログ行ゼロ」invariant（= processor 自身の
# `[pr-design-reviewer]` 専用ログ行がゼロ）には抵触しない。
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
# Quota-Aware Watcher Helpers (#66) — modules/quota-aware.sh へ切り出し済み（#180 Part 2）
#   qa_detect_rate_limit / qa_run_claude_stage / qa_persist_reset_time /
#   qa_load_reset_time / qa_build_escalation_comment / build_partial_escalation_comment /
#   qa_handle_quota_exceeded / process_quota_resume は modules/quota-aware.sh が定義する。
#   call site（process_quota_resume）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Quota Resume Processor を全 Processor の先頭で実行する（Req 5.1, 5.6 / NFR 3.2）。
# 失敗時も後続 Processor を阻害しないよう || qa_warn で吸収。
process_quota_resume || qa_warn "process_quota_resume が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor — modules/merge-queue.sh へ切り出し済み（#180 Part 2）
#   mq_pr_has_label / mq_handle_conflict / mq_try_rebase_pr / process_merge_queue は
#   modules/merge-queue.sh が定義する。Re-check（mqr_* / process_merge_queue_recheck）も
#   同モジュールに同居する。call site（process_merge_queue 等）は実行順序温存のため
#   本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase D: Auto Rebase Processor (#17) — modules/auto-rebase.sh へ切り出し済み（#180 Part 2）
#   ar_fetch_candidates / ar_build_prompt / ar_run_claude_rebase / ar_classify_diff /
#   ar_apply_mechanical / ar_dismiss_all_approvals / ar_apply_semantic /
#   ar_escalate_to_failed / ar_handle_pr / process_auto_rebase は modules/auto-rebase.sh が
#   定義する。call site（process_auto_rebase）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Re-check Processor (#27) — modules/merge-queue.sh へ切り出し済み（#180 Part 2）
#   mqr_log / mqr_warn / mqr_error / process_merge_queue_recheck は merge-queue.sh が定義する。
#   call site（process_merge_queue_recheck）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase B: Promote Pipeline Processor (#15) + Phase E: Path Overlap Checker (#18)
#   — modules/promote-pipeline.sh へ切り出し済み（#181 Part 3）
#   Promote 関数群（pp_resolve_target_branch / pp_collect_merged_issues / pp_get_st_state /
#   pp_handle_st_failure / pp_handle_st_success / pp_do_promote / pp_summary /
#   process_promote_pipeline ほか）と Path Overlap 関数群（po_log / po_warn /
#   po_parse_triage_edit_paths / po_compute_overlap / po_check_dispatch_gate /
#   po_apply_awaiting_slot / po_clear_awaiting_slot ほか）は modules/promote-pipeline.sh が
#   定義する（Path Overlap は独立せず Promote へ同居 / design.md decision 3）。
#   ロガー pp_log / pp_warn / pp_error は core_utils.sh に定義済み（#180 Part 2）。
#   call site（process_promote_pipeline / po_check_dispatch_gate）は実行順序温存のため
#   本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC 1.1: Phase A 本体の直後に Promote Pipeline Processor を 1 回起動。
# fail-continue を維持するため `|| pp_warn ...` で例外を吸収（NFR 3.1）。
process_promote_pipeline \
  || pp_warn "process_promote_pipeline が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PR Iteration Processor (#26) — modules/pr-iteration.sh へ切り出し済み（#181 Part 3）
#   `needs-iteration` ラベル付き PR を fresh context の Claude で反復対応する processor。
#   pi_pr_has_label / pi_fetch_candidate_prs / pi_resolve_max_rounds / pi_read_round_counter /
#   pi_read_no_progress_streak / pi_write_marker / pi_finalize_labels / pi_classify_pr_kind /
#   pi_select_template / build_recovery_hint / pi_escalate_to_failed / pi_build_iteration_prompt /
#   pi_detect_quota_soft_fail / pi_run_iteration / process_pr_iteration ほかは
#   modules/pr-iteration.sh が定義する。ロガー pi_log / pi_warn / pi_error は core_utils.sh
#   に定義済み（#180 Part 2）。call site（process_pr_iteration）は実行順序温存のため
#   本体の従来位置（Phase A 直後）に残す。標準機能としてデフォルト有効（#112）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Design Review Release Processor (#40) — modules/design-review-release.sh へ切り出し済み（#456）
#   `awaiting-design-review` ラベルが付いた Issue について、リンクされた設計 PR（head branch
#   が `^claude/issue-<N>-design-` 規約）が merged 状態なら、Issue からラベルを除去して
#   ステータスコメントを 1 件投稿する processor。drr_already_processed /
#   drr_find_merged_design_pr / drr_remove_label_and_comment / process_design_review_release は
#   modules/design-review-release.sh が定義する。ロガー drr_log / drr_warn / drr_error は
#   core_utils.sh に定義済み（#177 Part 1）。call site（process_design_review_release）は
#   実行順序温存のため本体の従来位置（Issue 処理ループの直前）に残す。標準機能として
#   デフォルト有効（#112）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
# Stage A Verify Module (#125) — modules/stage-a-verify.sh へ切り出し済み（#181 Part 3）
#   Stage A 完了直前に tasks.md 末尾の build/test/lint コマンドを watcher 自身が独立再実行
#   する verify ゲート。sav_log / sav_warn / sav_error / _sav_cmd_starts_with_keyword /
#   stage_a_verify_extract_command / stage_a_verify_resolve_command / stage_a_verify_round_path /
#   stage_a_verify_read_round / stage_a_verify_bump_round / stage_a_verify_reset_round /
#   _sav_handle_failure / stage_a_verify_run は modules/stage-a-verify.sh が定義する。
#   Part 1 想定の impl-gates.sh 集約から独立分離（design.md decision 2）。sc_* / tc_* /
#   stage_checkpoint_* は本モジュールへ移さず本体に残す。call site（run_impl_pipeline 内の
#   stage_a_verify_run）は実行順序温存のため本体の従来位置に残す。
#   設計参照: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stage Checkpoint Module (#68) — modules/stage-checkpoint.sh へ切り出し済み（#459）
#   impl / impl-resume の Stage A/B/C 完了 checkpoint を成果物（impl-notes.md /
#   review-notes.md / 既存 impl PR）の存在で観測し、failed Stage 以降のみを再実行する
#   機能。sc_log / sc_warn / sc_error / stage_checkpoint_has_impl_notes / sc_issue_state /
#   sc_tasks_unchecked_count / stage_checkpoint_read_review_result /
#   stage_checkpoint_find_impl_pr / stage_checkpoint_resolve_resume_point /
#   stage_c_existing_pr_guard / stage_a_crossing_probe / _spec_missing_artifacts /
#   _spec_create_docs_pr / _spec_escalate_incomplete / spec_artifacts_completeness_guard は
#   modules/stage-checkpoint.sh が定義する。Slot Runner 内の類似名別関数
#   （`_stage_checkpoint_assert_slug_match` / `_stage_checkpoint_has_resumable_state`）は
#   対象外で本体に残る（取り違え注意）。呼び出し元（run_impl_pipeline 冒頭 / pipeline
#   最終フック等）は実行順序温存のため本体側に残る。
#   設計参照: docs/specs/68-feat-watcher-stage-checkpoint-reviewer-p/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tasks Count Gate Module (#147) — modules/tasks-count-gate.sh へ切り出し済み（#457）
#   Architect が `tasks.md` を確定した直後（design モードの Claude 実行 rc=0 直後）に
#   watcher 側で task 件数を機械的に再カウントし、件数レンジに応じて 3 段階の運用判定
#   （通常 / 警告 / Developer 抑止）を適用する harness ガード。tc_log / tc_warn / tc_error /
#   tc_count_tasks / tc_classify / tc_should_run / tc_already_posted_marker_present /
#   tc_post_warning_comment / tc_post_escalation_comment / tc_add_needs_decisions_label /
#   tc_run_post_architect_check は modules/tasks-count-gate.sh が定義する。call site
#   （design 分岐 rc=0 直後の `tc_run_post_architect_check || true`）は実行順序温存の
#   ため本体側に残る。設定ブロック（TC_ENABLED 等）も Config 分離回（#460）待ちのため
#   本体側に残る。設計参照: docs/specs/147-feat-harness-tasks-md-task-auto-dev-issu/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) — impl 系モード stage 分割パイプライン
#
# 既存の impl / impl-resume モードは DEV_PROMPT 1 回で PM + Developer + PjM を
# 直列起動していたが、Reviewer サブエージェントを独立 context で挟むため、以下の
# stage に分割する:
#
#   Stage A  : PM + Developer（ただし impl-resume では PM をスキップ）
#   Stage B  : Reviewer (round=1)
#   Stage A' : Developer 再実行（reject 時のみ、最大 1 回）
#   Stage B' : Reviewer (round=2、reject 時のみ)
#   Stage C  : PjM（PR 作成）
#
# 各 stage は `claude --print` の独立プロセスで起動。stage 間の context 共有は
# しない（要件 2.2「独立 Claude セッション」）。Reviewer 判定は
# `docs/specs/<N>-<slug>/review-notes.md` の最終 RESULT 行で受け渡す。
#
# 設計参照: docs/specs/20-phase-1-reviewer-subagent-gate/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Reviewer / Pipeline 専用ロガー（既存 mq_log / pi_log と同形式）
rv_log() {
  echo "[$(date '+%F %T')] reviewer: $*"
}
rv_dev_log() {
  echo "[$(date '+%F %T')] developer: $*"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Per-task TDD Implementation Loop (#21 Phase 2) — modules/per-task-loop.sh へ切り出し済み（#461-462）
#   `PER_TASK_LOOP_ENABLED=true` のときに `run_impl_pipeline` の Stage A 内で起動される
#   per-task loop の全補助関数（ヘルパー + prompt builder + runner + escalation / 計 27）:
#   pt_log / pt_warn / pt_extract_pending_tasks / pt_check_task_completed / pt_extract_learnings /
#   pt_extract_findings_block / pt_extract_debugger_section / pt_snapshot_review_notes /
#   pt_check_fail_fast / pt_mark_fail_fast_failed / pt_resolve_diff_range /
#   pt_detect_post_marker_commits / pt_classify_post_marker_paths / pt_handle_post_marker_commits /
#   pt_has_subtasks / pt_is_parent_checkbox_only_diff / pt_should_skip_reviewer /
#   build_per_task_implementer_prompt / build_per_task_reviewer_prompt / run_per_task_implementer /
#   run_per_task_implementer_redo / run_per_task_reviewer / pt_mark_diff_range_resolve_failed /
#   pt_mark_post_marker_commits_detected / pt_post_docs_only_auto_refresh_comment /
#   pt_mark_no_progress_failed / run_per_task_loop は modules/per-task-loop.sh が定義する。
#   呼び出し元（run_impl_pipeline の Stage A dispatcher からの run_per_task_loop 起動）は
#   実行順序温存のため本体側に残る（後続 issue で impl-pipeline.sh へ移動予定）。
#   bash の遅延束縛のため順序問題なし。
#   詳細: docs/specs/21-phase-2-per-task-tdd-implementation-loop/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Debugger Gate (#22 Phase 3) — modules/debugger-gate.sh へ切り出し済み（#458）
#   `DEBUGGER_ENABLED=true` のときに Stage B' (Round 2) reject 直前 / Stage A 完了直後
#   BLOCKED 検出経路で起動される Debugger サブエージェントの補助関数群。dbg_log / dbg_warn /
#   detect_blocked_marker / detect_partial_status / detect_debugger_already_invoked /
#   validate_debugger_notes / build_debugger_prompt / run_debugger_stage は
#   modules/debugger-gate.sh が定義する。呼び出し元（per-task loop / impl pipeline。
#   Reviewer Round 2 直前・BLOCKED 検出）は実行順序温存のため本体側に残る（後続 issue で
#   移動予定）。bash の遅延束縛のため順序問題なし。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) 既存セクション（per-task ループ helper / Debugger Gate helper はここまで）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Prompt Builders（Stage A / A' / B / C 用 4 関数）───
#
# 既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲する。
# 入力は環境変数（NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL /
# MODE / ARCHITECT_REASON）と関数引数。stdout に prompt 文字列を出力する。

# ─── _assert_base_branch_resolved ───
#
# Issue #96 Req 1.5: PR 作成系プロンプト（Stage C / design-review）を組み立てる直前に
# 解決済み `BASE_BRANCH` の実値が空文字でないことを検証する防御的ガード。
# 通常パスでは起動直後の `BASE_BRANCH="${BASE_BRANCH:-main}"` で必ず非空になるため
# 発火しないが、コード変更で誤って空文字を導入した場合に PR 作成段階で爆破するためのもの。
#
# 失敗時の挙動: stderr にエラー出力し、戻り値 1 を返す。呼び出し側（pipeline / design 分岐）が
# `_slot_mark_failed` で `claude-failed` ラベルを付与して人間にエスカレーションする。
_assert_base_branch_resolved() {
  if [ -z "${BASE_BRANCH:-}" ]; then
    echo "Error: BASE_BRANCH が空または未定義です。PR 作成プロンプトを組み立てられません（Issue #96 Req 1.5）" >&2
    return 1
  fi
  return 0
}

# ─── Stage prompt builders（前半）— modules/impl-pipeline.sh へ切り出し済み（#463）───
#   build_dev_prompt_a / build_dev_prompt_redo / build_dev_prompt_redo_with_fix_plan /
#   build_reviewer_prompt / build_dev_prompt_c は modules/impl-pipeline.sh が定義する。
#   後半（stage runner + escalation: run_dev_stage / run_reviewer_stage / run_impl_pipeline 等）は
#   実行順序温存のため本体に残置（#464 で移動予定）。`_assert_base_branch_resolved` 等の
#   ヘルパーと呼び出し元も本体残置。bash の遅延束縛のため順序問題なし。

# Issue #349 / #374 / #385: `extract_review_result_token()` / `parse_review_result()` の定義は
# Config ブロック直後（line 184 / line 237 付近）に move 済み。bash の top-level 逐次実行下で
# `process_claude_review_status_catchup`（line 1573 付近）から前方参照されないことを構造的に
# 保証するため。詳細は move 先の関数ヘッダコメント参照。

# ─── reviewer_skip_files_match <pattern> ───
#
# stdin の変更ファイル一覧（1 行 1 path）が「1 件以上あり、かつ全行が pattern（POSIX ERE）に
# 一致する」かを判定する純粋関数（#333）。`--` でパターン以降をオプション解釈から切り離す
# （`-` 始まりの path / pattern によるフラグ注入防止。#318 hardening と同方針）。
#
# 戻り値:
#   0 = スキップ適用可（非空リスト + 全行一致）
#   1 = それ以外（pattern 空 / リスト空 / 1 行でも不一致）
reviewer_skip_files_match() {
  local pattern="$1"
  [ -n "$pattern" ] || return 1
  local line
  local seen=1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    seen=0
    if ! printf '%s\n' "$line" | grep -Eq -- "$pattern"; then
      return 1
    fi
  done
  [ "$seen" -eq 0 ]
}

# ─── _reviewer_skip_check ───
#
# REVIEWER_SKIP_PATTERN（opt-in）の評価本体（#333）。スキップ適用時のみ 0 を返し、副作用として
# 自動 approve の review-notes.md（hidden marker `idd-claude:reviewer-skip:v1` 付き）生成と
# rv_log 出力を行う。以下はすべて「スキップしない」（fail-safe / 戻り値 1）:
#   - REVIEWER_SKIP_PATTERN 未設定・空（既定）
#   - git diff 失敗 / 変更ファイル 0 件
#   - 1 ファイルでもパターン不一致
#
# 入力 (環境変数経由): REVIEWER_SKIP_PATTERN, BASE_BRANCH, BRANCH, NUMBER, REPO_DIR,
#                      SPEC_DIR_REL, LOG
# 副作用: $REPO_DIR/$SPEC_DIR_REL/review-notes.md の生成（commit は Stage C の責務 / 既存契約）
_reviewer_skip_check() {
  [ -n "${REVIEWER_SKIP_PATTERN:-}" ] || return 1

  local files
  if ! files=$(git diff --name-only "origin/${BASE_BRANCH}..HEAD" 2>/dev/null); then
    rv_log "skip-pattern: git diff 失敗 → 通常 Reviewer 起動（fail-safe）" >> "$LOG"
    return 1
  fi
  if [ -z "$files" ]; then
    rv_log "skip-pattern: 変更ファイル 0 件 → 通常 Reviewer 起動（fail-safe）" >> "$LOG"
    return 1
  fi
  if ! reviewer_skip_files_match "$REVIEWER_SKIP_PATTERN" <<< "$files"; then
    return 1
  fi

  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  local head_sha file_count
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")
  file_count=$(printf '%s\n' "$files" | grep -c . || true)
  mkdir -p "$REPO_DIR/$SPEC_DIR_REL"
  cat > "$notes_path" <<EOF
# Review Notes

<!-- idd-claude:reviewer-skip:v1 pattern=${REVIEWER_SKIP_PATTERN} files=${file_count} -->

## Reviewed Scope

- Branch: ${BRANCH}
- HEAD commit: ${head_sha}
- Compared to: ${BASE_BRANCH}..HEAD

## Verified Requirements

（独立 Reviewer はスキップされました: 変更ファイル ${file_count} 件すべてが
REVIEWER_SKIP_PATTERN（\`${REVIEWER_SKIP_PATTERN}\`）に一致 / #333 opt-in）

## Findings

なし（自動 approve。内容レビューは PR 上の人間レビューで実施してください）

## Summary

REVIEWER_SKIP_PATTERN による Stage B スキップ（自動 approve / #333）。

RESULT: approve
EOF
  rv_log "round=1 result=approve reason=skip-pattern pattern='${REVIEWER_SKIP_PATTERN}' files=${file_count}" >> "$LOG"
  echo "⏭️  #$NUMBER: Reviewer スキップ（REVIEWER_SKIP_PATTERN 全一致 → 自動 approve）" | tee -a "$LOG"
  return 0
}

# ─── run_reviewer_stage <round> ───
#
# Reviewer サブエージェントを 1 回起動し、review-notes.md の最終 RESULT 行を抽出して
# 戻り値で結果を呼び出し元に返す。
#
# 入力:
#   $1 = round (1 | 2)
#   環境変数: NUMBER, BRANCH, SPEC_DIR_REL, LOG, REPO_DIR
# 副作用:
#   - $LOG に Reviewer 起動ログ（model / max-turns / 結果）を append
#   - $REPO_DIR/$SPEC_DIR_REL/review-notes.md が Reviewer によって作成 / 上書き
# 戻り値:
#   0 = approve
#   1 = reject
#   2 = 異常終了（claude crash / parse 失敗 / RESULT 行欠落 = 装飾起因 parse 失敗）
#   4 = ファイル不在で 1 回限定リトライ後も生成されず（Issue #296 Req 2 で導入）
#   99 = quota 超過
#
# Issue #296（ファイル不在検出 + 1 回限定リトライ）:
#   - 初回起動後 `parse_review_result` が rc=3（ファイル不在）を返した場合、同一 round 内で
#     Reviewer を 1 回だけ再起動して救済を試みる（Req 2.1, 2.4, NFR 3.1）。
#   - 再起動でファイルが生成されれば通常経路（approve / reject）に合流する（Req 2.2）。
#   - 再起動後も rc=3 のままなら本関数は rc=4 を返し、呼び出し側で `reviewer-missing-file`
#     カテゴリの `claude-failed` 付与に分岐する（Req 2.3, NFR 2.2 で reason 区別が必須）。
#   - rc=2（装飾起因 parse 失敗 = ファイルあり）経路はリトライ対象としない（Req 5.3）。
run_reviewer_stage() {
  local round="$1"
  local prev_result="(none)"

  # round=2 の場合、直前 review-notes.md の RESULT 行を Reviewer に伝える。
  # Issue #63: 装飾・インライン記述に耐性のある extract_review_result_token に委譲。
  # トークンが見つからない場合は従来どおり "(none)" を維持して prompt 互換性を保つ。
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  rv_log "round=$round start (model=$REVIEWER_MODEL, max-turns=$REVIEWER_MAX_TURNS)" >> "$LOG"

  local prompt
  prompt=$(build_reviewer_prompt "$round" "$prev_result")

  # Issue #296 Req 2.4 / NFR 3.1: ファイル不在起因の再起動は同一 round 内で最大 1 回まで。
  # ループ展開はせず attempt=1（初回）/ attempt=2（リトライ）の 2 段固定で実装する。
  # Issue #442 Req 1: 上記 missing-file リトライとは直交する形で、turn 切れ（error_max_turns）
  # 起因の拡張リトライを同一 round 内で最大 1 回だけ追加する。`_current_max_turns_rv`（初期
  # REVIEWER_MAX_TURNS）を可変化し、`_max_turns_retry_used_rv` で 1 回限定を担保する（Req 1.3）。
  # turn 切れ以外の非ゼロ exit は従来どおり即 return 2（Req 2.1）。
  local attempt
  local parsed=""
  local parse_rc
  local _current_max_turns_rv="$REVIEWER_MAX_TURNS"
  local _max_turns_retry_used_rv="false"
  for attempt in 1 2; do
    if [ "$attempt" = "2" ]; then
      # 再起動前のログ（NFR 2.1: 単発経路でのファイル不在起因リトライを観測可能にする）
      rv_log "round=$round attempt=2 retry reason=missing-file" >> "$LOG"
      echo "--- Reviewer 実行 (round=$round, retry attempt=2 / missing-file) ---" >> "$LOG"
    else
      echo "--- Reviewer 実行 (round=$round) ---" >> "$LOG"
    fi

    # Issue #66: Quota-Aware Watcher 経由で claude を起動。99 を受領した場合は
    # quota 超過検出として呼び出し側（run_impl_pipeline）に伝搬する。
    # Issue #442: 同一 attempt 内で turn 切れ拡張リトライを最大 1 回まで回す内側ループ。
    # 反復上限を 2（初回 + 拡張リトライ 1 回）に固定し無限ループを防ぐ（Req 1.3）。
    local _qa_reset_file_rv _qa_rc_rv=0 _qa_ts_rv _qa_stage_label_rv _rev_log_offset_rv _mt_inner_rv
    for _mt_inner_rv in 1 2; do
      _qa_ts_rv=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_rv="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-reviewer-r${round}-a${attempt}-m${_mt_inner_rv}-${_qa_ts_rv}"
      _qa_stage_label_rv="Reviewer-r${round}-a${attempt}-m${_mt_inner_rv}"
      # claude 実行前の $LOG 行数を記録（直前 stage の result 行誤検出を避ける / Req 2.4）。
      if declare -F tu_mark_log_offset >/dev/null 2>&1; then
        _rev_log_offset_rv=$(tu_mark_log_offset)
      else
        _rev_log_offset_rv=0
      fi
      _qa_rc_rv=0
      # #329: --agent reviewer で agent 定義をトップレベル実行（オーケストレーター層なし）。
      # agent 解決失敗時は claude が非ゼロ exit → 既存の reviewer-error 遷移 + run-summary の
      # degraded パターン（"Agent type .* not found"）で外形検知される。
      qa_run_claude_stage "$_qa_stage_label_rv" "$_qa_reset_file_rv" -- \
        claude \
          --agent reviewer \
          --print "$prompt" \
          --model "$REVIEWER_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$_current_max_turns_rv" \
          --output-format stream-json \
          --verbose \
          "${CLAUDE_HOOK_ARGS[@]}" \
          >> "$LOG" 2>&1 || _qa_rc_rv=$?

      # turn 切れ起因の非ゼロ exit のみ、同一 round 内で 1 回だけ拡張 turn 予算で再実行する。
      if [ "$_qa_rc_rv" != "0" ] && [ "$_qa_rc_rv" != "99" ] \
         && [ "$_max_turns_retry_used_rv" = "false" ] \
         && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset_rv"; then
        rm -f "$_qa_reset_file_rv"
        _max_turns_retry_used_rv="true"
        _current_max_turns_rv="$REVIEWER_MAX_TURNS_EXTENDED"
        # NFR 2.1 / Req 4.6: round / attempt / 拡張 turn 予算 / reason を 1 行で記録
        rv_log "round=$round attempt=$attempt retry reason=max-turns-extended extended-max-turns=$_current_max_turns_rv" >> "$LOG"
        echo "--- Reviewer 実行 (round=$round, retry / max-turns-extended=$_current_max_turns_rv) ---" >> "$LOG"
        continue
      fi
      break
    done
    case "$_qa_rc_rv" in
      0)
        rm -f "$_qa_reset_file_rv"
        ;;
      99)
        local _qa_epoch_rv
        _qa_epoch_rv=$(cat "$_qa_reset_file_rv")
        qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label_rv" "$_qa_epoch_rv"
        rm -f "$_qa_reset_file_rv"
        rv_log "round=$round attempt=$attempt result=quota-exceeded → needs-quota-wait" >> "$LOG"
        # run サマリ: Reviewer quota（独立 context で起動したが quota 超過 / Req 3.1, 3.3）
        rs_record_reviewer independent quota "$round"
        return 99
        ;;
      *)
        rm -f "$_qa_reset_file_rv"
        # Issue #442 Req 3.1, 3.3, 3.4: 拡張リトライ後も turn 切れ枯渇なら区別された
        # return code 6（reviewer-max-turns-exhausted）で escalation。run-summary は
        # degraded で記録（reviewer-error / missing-file と同じ degraded 系 / Req 3.3）。
        # それ以外の非ゼロ exit は従来どおり即 return 2（claude crash / Req 2.1）。
        if [ "$_max_turns_retry_used_rv" = "true" ] && reviewer_is_error_max_turns "$LOG" "$_rev_log_offset_rv"; then
          rv_log "round=$round attempt=$attempt result=error reason=max-turns-exhausted extended-max-turns=$_current_max_turns_rv" >> "$LOG"
          rs_record_reviewer degraded "" "$round"
          return 6
        fi
        rv_log "round=$round attempt=$attempt result=error reason=claude-exit-nonzero" >> "$LOG"
        # run サマリ: Reviewer degraded（claude 異常終了で verdict 取得不能 / Req 3.4）
        rs_record_reviewer degraded "" "$round"
        return 2
        ;;
    esac

    # review-notes.md を parse
    parse_rc=0
    parsed=$(parse_review_result "$notes_path") || parse_rc=$?
    case "$parse_rc" in
      0) break ;;  # 抽出成功 → ループを抜けて通常経路へ
      3)
        # ファイル不在 → 1 回だけリトライ。リトライ後も rc=3 なら rc=4 で抜ける。
        if [ "$attempt" = "1" ]; then
          rv_log "round=$round attempt=1 result=missing-file" >> "$LOG"
          continue
        fi
        rv_log "round=$round attempt=2 result=missing-file-after-retry" >> "$LOG"
        # run サマリ: Reviewer degraded（ファイル不在で verdict 取得不能）
        rs_record_reviewer degraded "" "$round"
        return 4
        ;;
      *)
        # rc=2: 装飾起因の parse 失敗（ファイルあり）。リトライしない（Req 5.3）。
        rv_log "round=$round attempt=$attempt result=error reason=parse-failed" >> "$LOG"
        # run サマリ: Reviewer degraded（parse 失敗で verdict 取得不能 / Req 3.4）
        rs_record_reviewer degraded "" "$round"
        return 2
        ;;
    esac
  done

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      rv_log "round=$round result=approve verified=$targets" >> "$LOG"
      # run サマリ: Reviewer approve（独立 context で起動し verdict 取得 / Req 3.1, 3.2, 3.3）
      rs_record_reviewer independent approve "$round"
      return 0
      ;;
    reject)
      rv_log "round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      # run サマリ: Reviewer reject（独立 context で起動し verdict 取得 / Req 3.1, 3.2, 3.3）
      rs_record_reviewer independent reject "$round"
      return 1
      ;;
    *)
      rv_log "round=$round result=error reason=unknown-result" >> "$LOG"
      # run サマリ: Reviewer degraded（RESULT 欠落で verdict 取得不能 / Req 3.4）
      rs_record_reviewer degraded "" "$round"
      return 2
      ;;
  esac
}

# ─── per-task terminal failure 時の診断 artifact 保全ヘルパー (Issue #306) ───
#
# per-task ループの terminal failure 経路（`per-task-reviewer-reject2` /
# `per-task-reviewer-reject3` / `per-task-reviewer-error` /
# `per-task-reviewer-missing-file` / `debugger-notes-invalid` 等）で
# `mark_issue_failed` を呼び出す **直前** に経由するラッパー。Reviewer / Debugger
# サブエージェントには git / gh 権限を付与しない設計（Req 3.1, 3.2, 3.3）のため、
# watcher 側が以下を担う:
#
#   1. push state（branch / local HEAD / origin HEAD / ahead / worktree path）を
#      失敗コメントに常時埋め込む（Req 2.1, 2.4 / NFR 1.2）
#   2. `review-notes.md` / `debugger-notes.md` が untracked または未 commit / 未 push なら
#      diagnostic commit を 1 件作成し origin branch に push する（Req 1.1, 1.3）
#   3. diagnostic commit の commit / push が失敗したら artifact 本文（または長文時は
#      先頭・末尾要約）を Issue コメント本文に埋め込んで fallback する（Req 1.4, NFR 3.1）
#   4. 既に tracked かつ pushed 済みの artifact は重複保全しない（Req 1.2）
#   5. 保全処理が失敗しても `mark_issue_failed` を必ず呼ぶ（Req 1.5, NFR 2.1）
#
# 本ヘルパーは `mark_issue_failed` の **ラッパー** として動作し、
# 呼び出し側は `mark_issue_failed` の代わりに本関数を呼ぶだけで artifact 保全と
# push state 可視化を行える（call site 変更最小化）。
#
# 引数:
#   $1 = stage 識別子（既存 mark_issue_failed と同じ。例: per-task-reviewer-reject2）
#   $2 = 既存 extra_body（call site が組み立てる失敗コメント追加情報）
#
# 戻り値: 0 always（best-effort、既存 mark_issue_failed と同方針）
#
# 副作用:
#   - cwd が `$REPO_DIR`（slot worktree）であることを前提とする（_slot_run_issue が cd 済）
#   - push state 情報と artifact 状態を $2 (extra_body) に append してから
#     `mark_issue_failed` を呼び出す
#   - diagnostic commit 作成 / push を試行する（必要時のみ）
#   - 保全処理の各段階を `$LOG` に grep 可能な形で 1 行記録する（NFR 2.2）
#   - `git reset` / `git rebase` / force push は **使わない**（Req 3.4）
#
# 設計判断:
#   - 既存 `verify_pushed_or_retry` は ahead 数の verify と自動 push リトライに責務を
#     絞っており、artifact の commit / 本文埋め込みまでは扱わない。本関数は
#     **新規ヘルパー**として導入し、`verify_pushed_or_retry` の意味論は変更しない
#     （Req 4.3 / NFR 1.1）
#   - artifact 本文の埋め込み閾値は 16384 文字（NFR 3.1: GitHub Issue コメント 65,536
#     文字制限の余裕を取った保守的しきい値）。超過時は先頭 80 行 + 末尾 80 行の抜粋に
#     切り替える（Open Question の design 確定）
#   - 既存 `verify_pushed_or_retry` 風の `timeout` 既存検出ロジックを踏襲し、
#     `command -v timeout` で GNU coreutils の有無を判定（NFR 1.2）
publish_terminal_failure_artifacts() {
  local stage="$1"
  local extra_body="$2"

  # 防御: BRANCH / REPO_DIR / SPEC_DIR_REL が未設定でも処理を完遂する（Req 1.5 / NFR 2.1）
  local branch="${BRANCH:-}"
  local spec_dir_rel="${SPEC_DIR_REL:-}"
  local repo_dir="${REPO_DIR:-}"

  local _git_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _git_timeout=(timeout 30)
  fi

  # ── push state 収集（Req 2.1, 2.3, 2.4）──
  # ahead 数 / origin HEAD SHA を取得。エラー時は安全側で "(unknown)" 等を埋める
  local local_head="(unknown)" origin_head="未 push" ahead_count="(unknown)"
  local worktree_path="${repo_dir:-(unknown)}"

  local _lh
  _lh=$("${_git_timeout[@]}" git rev-parse HEAD 2>/dev/null || true)
  if [ -n "$_lh" ]; then
    local_head="$_lh"
  fi

  # origin branch HEAD を取得する。fetch せず ls-remote で軽量に確認する（NFR 2.1）
  local _origin_out _origin_rc=0
  if [ -n "$branch" ]; then
    _origin_out=$("${_git_timeout[@]}" git ls-remote origin "refs/heads/$branch" 2>/dev/null) || _origin_rc=$?
    if [ "$_origin_rc" -eq 0 ] && [ -n "$_origin_out" ]; then
      origin_head=$(echo "$_origin_out" | awk '{print $1}' | head -n 1)
      if [ -z "$origin_head" ]; then
        origin_head="未 push"
      fi
    fi
  fi

  # ahead count を算出
  if [ "$origin_head" = "未 push" ]; then
    # 初回 push 前: BASE_BRANCH..HEAD の commit 数を使う（Req 2.3）
    local _base_ahead
    _base_ahead=$("${_git_timeout[@]}" git rev-list --count "${BASE_BRANCH:-main}..HEAD" 2>/dev/null || true)
    if [[ "$_base_ahead" =~ ^[0-9]+$ ]]; then
      ahead_count="$_base_ahead"
    fi
  else
    local _ah
    _ah=$("${_git_timeout[@]}" git rev-list --count "${origin_head}..HEAD" 2>/dev/null || true)
    if [[ "$_ah" =~ ^[0-9]+$ ]]; then
      ahead_count="$_ah"
    fi
  fi

  echo "[$(date '+%F %T')] terminal-failure-artifacts: stage=${stage} issue=#${NUMBER:-?} branch=${branch} local_head=${local_head} origin_head=${origin_head} ahead=${ahead_count}" >> "$LOG" 2>/dev/null || true

  # ── artifact 単位の保全処理（Req 1.1, 1.2, 1.3）──
  # artifact ごとに status を判定し、必要なら commit / push を試みる。失敗時は
  # 本文を extra_body に埋め込んで fallback。各 artifact ごとに以下を保存:
  #   <name> <status_token> <content_or_summary_or_empty>
  # status_token: tracked-pushed | tracked-unpushed | untracked | absent | embedded | committed
  local artifact_lines=""
  local artifact_embed=""
  local _need_commit=0

  _ptfa_artifact_status() {
    # echo "<status_token>" — file 状態を判定して返す
    local rel_path="$1"
    local abs_path="${repo_dir}/${rel_path}"
    if [ ! -f "$abs_path" ]; then
      echo "absent"
      return 0
    fi
    # tracked check: ls-files で確認
    local _tracked
    _tracked=$("${_git_timeout[@]}" git ls-files --error-unmatch -- "$rel_path" 2>/dev/null || true)
    if [ -z "$_tracked" ]; then
      echo "untracked"
      return 0
    fi
    # 変更が staged / unstaged に残っているか
    local _status_out
    _status_out=$("${_git_timeout[@]}" git status --porcelain -- "$rel_path" 2>/dev/null || true)
    if [ -n "$_status_out" ]; then
      echo "modified"
      return 0
    fi
    # commit 済み: origin に到達しているか
    if [ "$origin_head" = "未 push" ]; then
      echo "tracked-unpushed"
      return 0
    fi
    # 当該ファイルの最新 commit が origin に到達しているか:
    # log <origin_head>..HEAD で当該ファイルを変更した commit が出れば unpushed
    local _unpushed
    _unpushed=$("${_git_timeout[@]}" git log --oneline "${origin_head}..HEAD" -- "$rel_path" 2>/dev/null || true)
    if [ -n "$_unpushed" ]; then
      echo "tracked-unpushed"
      return 0
    fi
    echo "tracked-pushed"
    return 0
  }

  # artifact 一覧（順序保証）
  local _artifacts=("review-notes.md" "debugger-notes.md")
  local artifact_rel artifact_status artifact_rel_full
  local _need_save_list=()
  for artifact_rel in "${_artifacts[@]}"; do
    artifact_rel_full="${spec_dir_rel}/${artifact_rel}"
    artifact_status=$(_ptfa_artifact_status "$artifact_rel_full")
    artifact_lines="${artifact_lines}- \`${artifact_rel_full}\`: ${artifact_status}"$'\n'
    echo "[$(date '+%F %T')] terminal-failure-artifacts: artifact=${artifact_rel_full} status=${artifact_status} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
    case "$artifact_status" in
      untracked|modified|tracked-unpushed)
        _need_commit=1
        _need_save_list+=("$artifact_rel_full")
        ;;
      *) ;;
    esac
  done

  # ── 保全が必要なら diagnostic commit を試みる（Req 1.1, 1.3）──
  local _commit_pushed=0
  if [ "$_need_commit" = "1" ] && [ -n "$branch" ] && [ -n "$spec_dir_rel" ]; then
    local _add_rc=0 _commit_rc=0 _push_rc=0
    local _commit_msg="docs(spec): preserve terminal-failure diagnostics (#${NUMBER:-?} / stage=${stage})"

    # add: 対象 artifact のみ stage する
    local _save_path
    for _save_path in "${_need_save_list[@]}"; do
      "${_git_timeout[@]}" git add -- "$_save_path" 2>/dev/null || _add_rc=$?
    done

    if [ "$_add_rc" -eq 0 ]; then
      # commit を作成（user.email / user.name は cron 環境で global 設定済み前提）
      "${_git_timeout[@]}" git -c commit.gpgsign=false commit -m "$_commit_msg" -- \
        "${_need_save_list[@]}" >/dev/null 2>&1 || _commit_rc=$?
      if [ "$_commit_rc" -eq 0 ]; then
        "${_git_timeout[@]}" git push origin "$branch" >/dev/null 2>&1 || _push_rc=$?
        if [ "$_push_rc" -eq 0 ]; then
          _commit_pushed=1
          echo "[$(date '+%F %T')] terminal-failure-artifacts: diagnostic-commit pushed branch=${branch} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
          # push 成功後の origin_head / ahead を更新（コメント上の情報を最新化）
          local _new_origin
          _new_origin=$("${_git_timeout[@]}" git ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{print $1}' | head -n 1)
          if [ -n "$_new_origin" ]; then
            origin_head="$_new_origin"
          fi
          local _new_local
          _new_local=$("${_git_timeout[@]}" git rev-parse HEAD 2>/dev/null || true)
          if [ -n "$_new_local" ]; then
            local_head="$_new_local"
          fi
          ahead_count="0"
          # artifact_lines を再生成（status を更新）
          artifact_lines=""
          for artifact_rel in "${_artifacts[@]}"; do
            artifact_rel_full="${spec_dir_rel}/${artifact_rel}"
            local _newst
            _newst=$(_ptfa_artifact_status "$artifact_rel_full")
            # commit/push 成功直後は committed として明示
            case "$_newst" in
              tracked-pushed) _newst="committed" ;;
              *) ;;
            esac
            artifact_lines="${artifact_lines}- \`${artifact_rel_full}\`: ${_newst}"$'\n'
          done
        else
          echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit push 失敗 push_rc=${_push_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
        fi
      else
        echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit commit 失敗 commit_rc=${_commit_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
      fi
    else
      echo "[$(date '+%F %T')] terminal-failure-artifacts: WARN diagnostic-commit add 失敗 add_rc=${_add_rc} stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
    fi
  fi

  # ── push / commit が失敗（または skip）した場合の fallback 埋め込み（Req 1.3, 1.4, NFR 3.1）──
  if [ "$_need_commit" = "1" ] && [ "$_commit_pushed" != "1" ]; then
    local _save_path _abs _content _content_len
    local _max_chars=16384  # 約 16KB 上限（GitHub Issue コメント 65,536 文字制限の余裕保守値）
    for _save_path in "${_need_save_list[@]}"; do
      _abs="${repo_dir}/${_save_path}"
      if [ ! -f "$_abs" ]; then
        continue
      fi
      _content=$(cat "$_abs" 2>/dev/null || true)
      _content_len=${#_content}
      if [ "$_content_len" -gt "$_max_chars" ]; then
        # 長文時: 先頭 80 行 + 末尾 80 行に切り替える（NFR 3.1）
        local _head_part _tail_part
        _head_part=$(echo "$_content" | head -n 80)
        _tail_part=$(echo "$_content" | tail -n 80)
        artifact_embed="${artifact_embed}

#### \`${_save_path}\` の内容（要約 / 長文のため先頭 80 行 + 末尾 80 行）

\`\`\`
${_head_part}

… (中略 / 全文 ${_content_len} 文字) …

${_tail_part}
\`\`\`"
      else
        artifact_embed="${artifact_embed}

#### \`${_save_path}\` の内容（全文）

\`\`\`
${_content}
\`\`\`"
      fi
    done
    echo "[$(date '+%F %T')] terminal-failure-artifacts: artifact 本文を Issue コメントに fallback 埋め込み stage=${stage} issue=#${NUMBER:-?}" >> "$LOG" 2>/dev/null || true
  fi

  # ── extra_body に append する情報ブロックを組み立て ──
  local push_state_block
  push_state_block="### 診断 artifact / push 状態（Issue #306）

- 実装 branch: \`${branch:-(unknown)}\`
- local HEAD : \`${local_head}\`
- origin HEAD: \`${origin_head}\`
- ahead count: ${ahead_count}
- worktree  : \`${worktree_path}\`

#### artifact 状態

${artifact_lines}"

  if [ "$_commit_pushed" = "1" ]; then
    push_state_block="${push_state_block}
> ℹ️ watcher が未 push の診断 artifact を検出し、diagnostic commit を作成して origin に push しました。
> 上記 SHA / ahead 数は push 後の状態を反映しています。"
  elif [ "$_need_commit" = "1" ]; then
    push_state_block="${push_state_block}
> ⚠️ watcher が未 push の診断 artifact を検出しましたが、diagnostic commit / push に失敗しました。
> 下記の artifact 本文（または抜粋）が fallback として埋め込まれています。"
  fi

  local merged_body="$extra_body"
  if [ -n "$merged_body" ]; then
    merged_body="${merged_body}

${push_state_block}"
  else
    merged_body="$push_state_block"
  fi
  if [ -n "$artifact_embed" ]; then
    merged_body="${merged_body}${artifact_embed}"
  fi

  # ── 必ず claude-failed ラベルを付与する（Req 1.5, NFR 2.1）──
  mark_issue_failed "$stage" "$merged_body"
  return 0
}

# ─── Stage 完了直後の push 状態 verify ヘルパー (Issue #106) ───
#
# Stage A / A' / B 完了直後に「ローカル commit が origin に到達しているか」を verify し、
# 未 push を検出したら自動 push を 1 回だけリトライする。リトライ成功時は WARN ログ +
# Issue コメントで観測可能性を維持し、リトライ失敗時は mark_issue_failed 経路で
# claude-failed 化する。
#
# 引数:
#   $1 = stage 識別子（mark_issue_failed に渡す identifier。例: stageA-push-missing
#        / stageA-prime-push-missing / stageB-push-missing。NFR 2.1 / Req 4.4 と整合）
#   $2 = 対象 branch（典型的には $BRANCH）
#   $3 = stage label（ログ可読性のための短い文字列。例: "Stage A" / "Stage A'" / "Stage B"）
#
# 戻り値:
#   0 = ahead == 0（通常成功 / Req 1.3, 2.3, 5.1）、または自動 push リトライ成功
#       （Req 4.2, 4.3）
#   1 = 自動 push リトライ失敗 → mark_issue_failed 既発射、呼び出し側は伝搬 return 1 する
#       （Req 4.4, 4.5）
#
# 副作用:
#   - $LOG に検出経路 / ahead 数 / リトライ結果を WARN 行で記録（NFR 2.1, Req 1.2, 2.2, 3.2）
#   - リトライ成功時に gh issue comment で復旧通知を投稿（Req 4.3, NFR 2.2）
#   - リトライ失敗時に mark_issue_failed "$stage_id" で claude-failed 化（Req 4.4, NFR 2.3）
#
# 設計判断:
#   - `git rev-list --count @{u}..HEAD` で ahead 数を測る。本関数は cwd が slot worktree
#     ($REPO_DIR が指す path) であることを前提とする（_slot_run_issue が cd 済）。
#   - timeout は 30 秒上限（NFR 1.2）。本体 git クエリと push リトライそれぞれに timeout を
#     かける。`command -v timeout` で GNU coreutils の有無を判定し、無い環境
#     （BSD / macOS 標準）では timeout なしで実行する（既存 cron 互換性のため）。
#   - 結果不確定（git rev-list が timeout / 失敗）は「未 push と同等扱い」で安全側に倒す
#     （Req 1.4）。リトライを試み、失敗なら claude-failed 化する。
#   - push オプションは plain `git push origin <branch>` の fast-forward のみ。
#     `--force-with-lease` 等の force 系は **使わない**（既稼働 cron 環境で意図せぬ
#     history 書き換えを防止するため。Open Question 3 の design 確定）。
#   - Stage B の review-notes.md 識別ログ粒度（Req 3.4）は呼び出し側で stage label を
#     "Stage B" と明示し、本関数のログ行に stage label を含めることで観測可能性を担保。
verify_pushed_or_retry() {
  local stage_id="$1"
  local branch="$2"
  local stage_label="$3"

  # ── ahead 数を測定（安全側ロジック付き）──
  # 結果が空 / 取得失敗時は ahead=unknown とし、安全側で push リトライへ進む（Req 1.4）。
  local ahead_count="" rev_rc=0
  local _git_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _git_timeout=(timeout 30)
  fi
  ahead_count=$("${_git_timeout[@]}" git rev-list --count "@{u}..HEAD" 2>/dev/null) || rev_rc=$?
  # 数値以外（空文字 / エラー）は unknown 扱い
  if ! [[ "$ahead_count" =~ ^[0-9]+$ ]]; then
    ahead_count="unknown"
  fi

  # ── 通常成功ケース: ahead == 0（Req 1.3 / 2.3 / 3.3 / 5.1）──
  if [ "$ahead_count" = "0" ]; then
    return 0
  fi

  # ── ahead > 0 または unknown: WARN ログ → 自動 push リトライ 1 回（Req 4.1, 4.6）──
  qa_warn "${stage_label} push-state verify: ahead=${ahead_count} (rev_rc=${rev_rc}) issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
  echo "[$(date '+%F %T')] ${stage_label} ahead=${ahead_count} detected → auto-push retry 1/1 (Req 4.1, Issue #106)" >> "$LOG"

  local push_rc=0
  local push_stderr_tmp
  push_stderr_tmp=$(mktemp -t verify-push-XXXXXX.err 2>/dev/null || echo "")
  if [ -n "$push_stderr_tmp" ]; then
    "${_git_timeout[@]}" git push origin "$branch" 2>"$push_stderr_tmp" || push_rc=$?
  else
    "${_git_timeout[@]}" git push origin "$branch" || push_rc=$?
  fi

  if [ "$push_rc" -eq 0 ]; then
    # ── リトライ成功（Req 1.1, 1.2, 1.3, 1.4）──
    # #248: 成功時の Issue コメント投稿は誤検知ノイズ（ahead>0 は commit-only 設計の
    # 正常状態）となるため抑止する。監査トレーサビリティは $LOG の単一 info 行に
    # Issue 番号 / stage 識別子 / branch / 復旧 commit 数を機械可読フィールドとして
    # 含めて担保する（Req 2.1〜2.4 / NFR 3.1）。「push 漏れ」原因示唆文言は出さない。
    qa_warn "${stage_label} auto-push retry SUCCESS: ahead=${ahead_count} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
    echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ成功 → 継続 issue=#${NUMBER:-?} stage_id=${stage_id} branch=${branch} recovered_commits=${ahead_count}" >> "$LOG"

    if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi
    return 0
  fi

  # ── リトライ失敗（Req 4.4, 4.5, NFR 2.3）──
  local push_stderr_tail=""
  if [ -n "$push_stderr_tmp" ] && [ -f "$push_stderr_tmp" ]; then
    push_stderr_tail=$(tail -c 1500 "$push_stderr_tmp" 2>/dev/null || true)
  fi
  qa_warn "${stage_label} auto-push retry FAILED: ahead=${ahead_count} push_rc=${push_rc} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id} stderr_tail='${push_stderr_tail//$'\n'/ }'"
  echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ失敗 push_rc=${push_rc} → claude-failed (stage_id=${stage_id})" >> "$LOG"

  local fail_body
  fail_body="${stage_label} 完了直後に未 push commit（ahead=${ahead_count}）を検出し、自動 push リトライを 1 回試みましたが失敗しました（push exit code: ${push_rc}）。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 未 push commit 数: ${ahead_count}

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 worktree の HEAD と origin/${branch} の差分を確認
2. 必要に応じ手動で \`git push origin ${branch}\` を実行
3. 問題が解消したら \`claude-failed\` ラベルを外して再 pickup させる"
  if [ -n "$push_stderr_tail" ]; then
    fail_body="${fail_body}

### git push stderr (tail)

\`\`\`
${push_stderr_tail}
\`\`\`"
  fi

  if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi

  mark_issue_failed "$stage_id" "$fail_body"
  return 1
}

# ─── Stage C 完了直後の PR 実在 verify ヘルパー (Issue #108 / #110) ───
#
# Stage C の Claude 実行が return code 0 で終了した直後に、対象 branch を head と
# する impl PR が GitHub 側で参照可能か `gh pr list --head <branch> --state all` で verify する
# （`gh pr view` は `--head` 非対応で常に失敗し、かつ open のみ探索だと高速 merge 済み PR を
#  取りこぼすため、list + `--state all` で open/merged 双方を検出する）。GitHub の
# eventual consistency により PR 作成直後数十秒は当該クエリが空応答を返すケースが
# 観測されているため、主経路は最大 6 回までリトライ可能とし、整合性遅延に起因する
# false negative を吸収する。さらに主経路が全試行で空応答 / 失敗で終わった場合は、
# 主経路と独立な edge cache 経路である List Pulls API（`gh api repos/.../pulls?head=...`）
# に対して 1 度だけ fallback 探索を試みる（Issue #110: KeyNest #32 で観測された
# 73 秒経過後の主経路空応答に対する救済路）。
#
# 引数:
#   $1 = 対象 branch（典型的には $BRANCH）
#   $2 = Issue 番号（ログ識別用。典型的には $NUMBER）
#
# 戻り値:
#   0 = 主経路 / 代替経路のいずれかで PR URL が取得できた（PR URL を stdout に出力）
#   1 = 主経路全試行 + 代替経路の 1 ターンを全て使い切っても PR URL を取得できなかった
#
# 副作用:
#   - 各主経路試行の結果（成功 / 空応答 / 非 0 / タイムアウト）を `$LOG` に記録（NFR 2.1）
#   - 代替経路の呼び出し開始・結果を `$LOG` に記録（Req 3.3 / 3.4 / NFR 2.2）
#   - 1 回目即時成功時は追加ログを出さない（Req 4.1 / 4.6 / NFR 1.1: 通常成功ケースの
#     外形挙動を本変更前と同一に保つ）
#
# 設計判断:
#   - 主経路試行回数 6 / 待機 (0, 5, 10, 20, 40, 60) 秒 / 1 試行 timeout 15 秒
#     （Req 1.1 / 1.2 / 1.3 / 1.6 / NFR 1.2 / 1.3）。sleep 合計 135 秒で 73 秒の edge
#     cache lag を余裕を持って吸収できる。
#   - 待機は `${STAGEC_VERIFY_SLEEP_CMD:-sleep}` 経由で実行する。テストで `:` 等の
#     no-op コマンドを注入することで実時間待機なしに retry 系列を再現できる
#     （Req 5.8）。env var 名は Issue #108 の既存 fixture と互換。
#   - 主経路リトライ系列は `${STAGEC_VERIFY_DELAYS:-}` （スペース区切り秒数）と
#     `${STAGEC_VERIFY_MAX_ATTEMPTS:-}` で override 可能（Req 4.7 / NFR 3.4）。
#     未指定時のデフォルトで Req 1.1 / 1.2 / NFR 1.2 を満たす。既存 env var 名
#     （REPO / REPO_DIR / LOG / TRIAGE_MODEL / DEV_MODEL / STAGEC_VERIFY_SLEEP_CMD 等）
#     とは衝突しない新規 env var を採用している。
#   - `command -v timeout` で timeout コマンドの存在を確認し、無い環境では timeout
#     なしで gh を実行する（既存 verify_pushed_or_retry と同方針 / 既存 cron
#     互換性のため）。1 試行・代替経路ともに `${STAGEC_VERIFY_TIMEOUT_SECS:-15}` 秒
#     上限（Req 1.6 / 2.5 / NFR 1.3 / 1.4）。
#   - 代替経路は List Pulls API を直接叩く `gh api repos/{owner}/{repo}/pulls?head={owner}:BRANCH&state=all`
#     パターン。`{owner}` は `$REPO`（owner/repo 形式）から prefix を抽出。
#     edge cache の独立性を期待する経路設計のため、代替経路自体のリトライは
#     行わない（Req 2.6）。
#   - 主経路のいずれかで PR が見つかった場合、代替経路は呼び出さない（Req 2.7）。
#   - 成功時の "Stage C 完了 / PR 作成済み" 相当ログは呼び出し側に残し、本関数は
#     PR URL の取得と試行ログのみに責務を絞る。これにより Req 4.1 の「1 回目で
#     PR が確認できたとき本変更前と同じ成功ログ」を呼び出し側 echo で保証する。
verify_stagec_pr_or_retry() {
  local branch="$1"
  local issue_number="$2"

  # 試行間 sleep の注入点（テスト時に `:` 等で no-op 化できる / Req 5.8）
  local _sleep_cmd="${STAGEC_VERIFY_SLEEP_CMD:-sleep}"

  # 1 試行 / 代替経路あたりの timeout 上限秒数（Req 1.6 / 2.5 / NFR 1.3 / 1.4）
  local _timeout_secs="${STAGEC_VERIFY_TIMEOUT_SECS:-15}"

  # timeout コマンドの有無で gh 呼び出しを切り替える（既存 verify_pushed_or_retry と同方針）
  local _gh_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _gh_timeout=(timeout "$_timeout_secs")
  fi

  # 待機スケジュール（即時 / 5 / 10 / 20 / 40 / 60 秒。sleep 合計 135 秒 / Req 1.1 / NFR 1.2）
  # STAGEC_VERIFY_DELAYS env で override 可能（Req 4.7 / NFR 3.4）
  local _delays=()
  if [ -n "${STAGEC_VERIFY_DELAYS:-}" ]; then
    # shellcheck disable=SC2206  # 意図的に空白で word split する
    _delays=(${STAGEC_VERIFY_DELAYS})
  else
    _delays=(0 5 10 20 40 60)
  fi
  local _max_attempts="${STAGEC_VERIFY_MAX_ATTEMPTS:-${#_delays[@]}}"

  local attempt=1
  local pr_url="" rc=0
  local last_outcome="empty"
  while [ "$attempt" -le "$_max_attempts" ]; do
    local _delay="${_delays[$((attempt - 1))]:-0}"
    if [ "$_delay" -gt 0 ]; then
      "$_sleep_cmd" "$_delay"
    fi

    pr_url=""
    rc=0
    pr_url=$("${_gh_timeout[@]}" gh pr list --repo "$REPO" --head "$branch" --state all \
              --json url --jq '.[0].url // empty' 2>/dev/null) || rc=$?

    if [ "$rc" -eq 0 ] && [ -n "$pr_url" ]; then
      # 1 回目以降の試行回数判定: N >= 2 の場合のみ「リトライで成功」ログを残す
      # （Req 3.2 / Req 4.1 / 4.6 / NFR 1.1 を満たすため 1 回目は無 log で本変更前と外形互換）
      if [ "$attempt" -gt 1 ]; then
        echo "[$(date '+%F %T')] stageC PR verify SUCCESS attempt=${attempt}/${_max_attempts} issue=#${issue_number} branch=${branch} pr_url=${pr_url}" >> "$LOG"
      fi
      printf '%s\n' "$pr_url"
      return 0
    fi

    # 失敗種別を分類してログに残す（NFR 2.1: 試行結果を事後識別可能にする）
    local outcome=""
    if [ "$rc" -eq 124 ]; then
      outcome="timeout"
    elif [ "$rc" -ne 0 ]; then
      outcome="exit=${rc}"
    else
      outcome="empty"
    fi
    last_outcome="$outcome"
    # Req 3.1: 2 回目以降の進捗を 1 行で残す。1 回目失敗も Req 3.5「全失敗時の原因
    # 特定」のため残しておく（最終失敗時にまとめて参照できるよう attempt=1 から記録）
    echo "[$(date '+%F %T')] stageC PR verify attempt=${attempt}/${_max_attempts} outcome=${outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

    attempt=$((attempt + 1))
  done

  # ─── 主経路全試行失敗 → 代替経路（List Pulls API）への 1 ターン fallback ───
  # Req 2.1 / 2.6: 代替経路は主経路と独立に 1 回だけ呼び出す（リトライしない）。
  # Req 2.5 / NFR 1.4: 代替経路にも timeout 上限を適用する。
  local _owner="${REPO%%/*}"
  echo "[$(date '+%F %T')] stageC PR verify fallback start (List Pulls API) issue=#${issue_number} branch=${branch} owner=${_owner}" >> "$LOG"
  local _fb_url="" _fb_rc=0 _fb_outcome=""
  _fb_url=$("${_gh_timeout[@]}" gh api "repos/${REPO}/pulls?head=${_owner}:${branch}&state=all" \
            --jq '.[0].html_url // empty' 2>/dev/null) || _fb_rc=$?
  if [ "$_fb_rc" -eq 0 ] && [ -n "$_fb_url" ]; then
    # Req 2.2 / 3.4: 代替経路で救済（主経路全失敗 / 代替経路で成功）
    echo "[$(date '+%F %T')] stageC PR verify fallback SUCCESS rescued issue=#${issue_number} branch=${branch} pr_url=${_fb_url} primary_attempts=${_max_attempts}" >> "$LOG"
    printf '%s\n' "$_fb_url"
    return 0
  fi
  # Req 2.3 / 2.4 / NFR 2.2: 代替経路の結果分類（empty / timeout / exit=N / 認証失敗等）を残す
  if [ "$_fb_rc" -eq 124 ]; then
    _fb_outcome="timeout"
  elif [ "$_fb_rc" -ne 0 ]; then
    _fb_outcome="exit=${_fb_rc}"
  else
    _fb_outcome="empty"
  fi
  echo "[$(date '+%F %T')] stageC PR verify fallback FAILED outcome=${_fb_outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

  # Req 3.5: 主経路試行回数 / 最終 primary 失敗要因 / 代替経路最終結果を 1 行で残す
  echo "[$(date '+%F %T')] stageC PR verify FAILED after ${_max_attempts} attempts + fallback issue=#${issue_number} branch=${branch} last_primary_outcome=${last_outcome} fallback_outcome=${_fb_outcome}" >> "$LOG"
  return 1
}

# ─── failure 共通遷移ヘルパー ───
#
# Stage 失敗時の claude-failed 遷移を一元化。引数で原因種別と Issue コメント追加情報を受け取る。
# - $1 = stage 識別子（"stageA" / "stageA-redo" / "stageB" / "stageC" / "reviewer-error" / "reviewer-reject2"）
# - $2 = Issue コメントに追加する補足（reject 理由など。空文字可）
mark_issue_failed() {
  local stage="$1"
  local extra_body="$2"

  # run サマリ: 最終遷移を claude-failed として記録（Req 7.1, 7.2）。変数代入のみの副作用で
  # ラベル遷移 / exit code / 既存ログ行に影響しない（NFR 1.1, 1.2）。REQUIRED_MODULES で
  # run-summary.sh が source 済みのため bare 呼び出し（task 5 learning 準拠 / set -e 安全）。
  rs_set_result claude-failed

  # Issue #52: 通常経路では Stage A 開始時点で Issue は claude-picked-up のみ持つ
  # （Slot Runner が Triage 通過時に claude-claimed → claude-picked-up に付け替え済）。
  # 想定外シーケンス（design ルート Stage C 失敗で本ヘルパへ流入する等）でも残置を防ぐ
  # ため、両系統除去で安全側に倒す。gh CLI は未付与ラベルの除去を no-op として扱う。
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: ${stage}）。

ログ: \`$LOG\`"
  if [ -n "$extra_body" ]; then
    body="${body}

${extra_body}"
  fi

  # Issue #259: 現在の実行ログから Claude API 一時混雑エラー (529 Overloaded) の痕跡を
  # 検出した場合、失敗通知コメント本文に警告ブロックを差し込む。検知ロジックが失敗・
  # 例外を起こしても既存の `claude-failed` ラベル付与・失敗コメント投稿の責務を妨げない
  # よう、すべて defensive に握り、検知なし / 検知失敗時は本機能導入前と完全に同一の
  # コメントを投稿する（Req 2.4 / 4.4 / NFR 1.1）。
  local _mif_529_rc=0
  claude_log_detect_529 "$LOG" || _mif_529_rc=$?
  case "$_mif_529_rc" in
    0)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529-overloaded detected issue=#${NUMBER} stage=${stage} log=${LOG}" >> "$LOG" 2>/dev/null || true
      body="${body}

---

:warning: **Claude API 一時混雑エラー (529 Overloaded) が検出されました**: 開発中に Claude API が高負荷（529 Overloaded）となったため、処理が中断された可能性があります。一時的な混雑によるエラーの可能性があるため、時間をおいて再試行してください。"
      ;;
    2)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529 検知用ログファイルが不在または読み取り不能のためスキップ issue=#${NUMBER} stage=${stage} log=${LOG}" >> "$LOG" 2>/dev/null || true
      ;;
    *)
      echo "[$(date '+%F %T')] [$REPO] mark_issue_failed: 529-overloaded not detected issue=#${NUMBER} stage=${stage}" >> "$LOG" 2>/dev/null || true
      ;;
  esac

  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # mark_issue_failed は run_impl_pipeline 内の各 stage 失敗から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# Partial Status Gate (#148) のラベル付け替え + コメント投稿ヘルパー。
# `mark_issue_failed` の `claude-failed` 専用設計と分離し、`needs-decisions` 経路の責務を
# 1 関数に集約する。LABEL_FAILED は **付与しない**（NFR 1.3 / 既存ラベル併存禁止）。
#
# Args:
#   $1 = status_code   (NFR 2.1 / grep 可能ログ用。本関数は body 組立済前提のため値だけ受領)
#   $2 = comment_body  (build_partial_escalation_comment の出力)
# Return: 0 always（best-effort、既存 mark_issue_failed と同方針）
# 副作用:
#   1. claude-claimed / claude-picked-up を除去
#   2. needs-decisions を付与（1 コマンド原子的に発行）
#   3. escalation コメントを 1 件投稿
# Requirements: 3.3, 3.4, 3.6, NFR 1.3
mark_issue_needs_decisions() {
  local status_code="$1"
  local comment_body="$2"

  # ラベル付け替え（gh CLI は未付与ラベルの除去を no-op として扱う / 既存
  # qa_handle_quota_exceeded / mark_issue_failed と同方針で 1 コマンド原子的に発行）。
  # LABEL_FAILED (`claude-failed`) は **付与しない**（NFR 1.3 / Req 3.3, 3.4）。
  if ! gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    # best-effort: 失敗してもコメント投稿は試行（既存 quota / failed 経路と同方針）
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN ラベル付け替え失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi

  # escalation コメント投稿（best-effort）
  if ! gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN コメント投稿失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi
  return 0
}

# Partial Status Gate (#148) の coordinator。Stage A 完了直後の各経路から
# 1 行 `handle_partial_status || _rc=$?; case ...` の形で呼ばれる。
#
# 入力 (環境変数経由):
#   NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG / BASE_BRANCH
# 出力:
#   stdout なし（log のみ）
# Return:
#   0  = continue（既存フロー継続。status 行不在 or `complete`）
#   10 = partial 検出済（呼出側は run_impl_pipeline から return 0 で抜けて Reviewer skip）
#   1  = 不正 status / parse 失敗（mark_issue_failed 実行済。呼出側は return 1）
#
# 副作用:
#   - partial 検出時: `mark_issue_needs_decisions` 経由でラベル付け替え + コメント投稿
#     + grep 可能ログ 1 行（NFR 2.1）
#   - 不正値時: `mark_issue_failed` 実行（NFR 3.1） + grep 可能ログ
#   - continue 時: 副作用なし（既存挙動と外形等価 / NFR 1.1, 1.4）
#
# 不変条件:
#   - 既存 `LABEL_NEEDS_DECISIONS` 以外のラベルを新規生成しない（Req 3.3, 3.4 / NFR 1.3）
#   - 戻り値 10 は run_impl_pipeline 既存 return code 0/1 と衝突しない（quota 99 とも区別）
#
# Requirements: 1.3, 3.1, 3.2, 3.5, NFR 1.1, NFR 1.4, NFR 2.1, NFR 3.1, NFR 3.2
handle_partial_status() {
  local impl_notes="$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"
  local status_code rc=0
  status_code=$(detect_partial_status "$impl_notes") || rc=$?
  case "$rc" in
    1|2)
      # STATUS 行不在 or ファイル不在 → continue（NFR 1.1 / NFR 3.2）
      # 既存挙動と外形完全等価（partial gate 導入前と同じ Stage B 起動経路へ）
      return 0
      ;;
    0)
      case "$status_code" in
        complete)
          # 明示的 complete = continue（NFR 1.4）
          return 0
          ;;
        partial_blocked|partial_overrun)
          # ── partial 検出: needs-decisions エスカレーション ──
          # 1. grep 可能ログ（NFR 2.1）
          echo "[$(date '+%F %T')] [$REPO] partial-status: detected issue=#${NUMBER} status=${status_code} branch=${BRANCH}" | tee -a "$LOG"
          # 2. コメント本文組立
          local body
          body=$(build_partial_escalation_comment \
            "$status_code" \
            "$impl_notes" \
            "$REPO_DIR/$SPEC_DIR_REL/tasks.md" \
            "$BRANCH")
          # 3. ラベル付け替え + コメント投稿（best-effort）
          mark_issue_needs_decisions "$status_code" "$body"
          # 4. partial 検出を呼出側に伝搬（return 10 = Reviewer skip + run_impl_pipeline 正常終了）
          return 10
          ;;
        *)
          # ── 不正 status code（NFR 3.1） ──
          echo "[$(date '+%F %T')] [$REPO] partial-status: invalid issue=#${NUMBER} status='${status_code}'" | tee -a "$LOG"
          mark_issue_failed "partial-status-invalid" \
            "Developer 出力の \`STATUS:\` 行が \`${status_code}\` で、契約 (\`complete\` / \`partial_blocked\` / \`partial_overrun\`) のいずれにも該当しません。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    *)
      # 想定外の rc（防御的）: detect_partial_status は 0/1/2 しか返さない契約だが、
      # 未来の規約変更に備えて safe-fallback で continue を選択（既存挙動を壊さない /
      # NFR 1.1）。
      echo "[$(date '+%F %T')] [$REPO] partial-status: WARN detect_partial_status unexpected rc=$rc → continue (safe-fallback)" >&2
      return 0
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage A Verify の失敗ハンドラ / 統合ランナー（_sav_handle_failure / stage_a_verify_run）
#   — modules/stage-a-verify.sh へ切り出し済み（#181 Part 3）。
#   元はここ（mark_issue_failed 定義後の位置）に置かれていたが、Region 1 と共に
#   stage-a-verify.sh へ統合した。call site（run_impl_pipeline 内の stage_a_verify_run）は
#   本体の従来位置に残す。cross-module 呼び出し（_sav_handle_failure → mark_issue_failed）は
#   全モジュールが run_impl_pipeline 実行前に source されるため挙動不変。
# ─────────────────────────────────────────────────────────────────────────────

# ─── stage_a_verify_round1_defer ───
#
# stage-a-verify round=1 差し戻し時に、当該 Issue を再 pickup 可能な bare auto-dev
# candidate へ戻すためのラベル除去を行う（Issue #219）。`claude-picked-up` を残すと
# dispatcher の候補クエリ（`-label:"$LABEL_PICKED"`）から除外され二度と再 pickup されず
# stuck になるため、per-task hold (#198) と同様に claude-picked-up / claude-claimed を
# 除去して次 tick の再 pickup → Stage Checkpoint resume → stage-a-verify 再評価
# （round=2 escalate への前進）を成立させる。round counter sidecar は呼び出し側で
# 温存されるため、次回失敗で round=2 → claude-failed に進む。
#
# 入力 (環境変数経由): NUMBER / REPO / LOG / LABEL_PICKED / LABEL_CLAIMED
# 副作用: gh issue edit（ラベル除去） / $LOG への grep 可能なログ 1 行
# 戻り値: 0 = ラベル除去成功 / 1 = gh 失敗（fail-open。呼び出し側は return 3 を維持し、
#         ラベル残置の旨を警告ログに残す。手動除去で復旧可能）
stage_a_verify_round1_defer() {
  if gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_PICKED" \
      --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] stage-a-verify: round=1 差し戻し: claude-picked-up 除去 → bare auto-dev candidate へ復帰（次 tick 再 pickup / issue=#$NUMBER）" >> "$LOG"
    return 0
  fi
  echo "[$(date '+%F %T')] stage-a-verify: WARN: round=1 差し戻しで claude-picked-up 除去に失敗（ラベル残置 → 次 tick で候補に上がらない恐れ / 手動除去で復旧可能 / issue=#$NUMBER）" >> "$LOG"
  return 1
}

# ─── run_impl_pipeline ───
#
# impl / impl-resume モードの Stage 状態機械を実装する。
#
#   START → Stage A → Stage B(round=1)
#                    ├─ approve → Stage C → TERMINAL_OK
#                    ├─ reject  → Stage A' → Stage B(round=2)
#                    │                       ├─ approve → Stage C → TERMINAL_OK
#                    │                       ├─ reject  → TERMINAL_FAILED (with Issue comment)
#                    │                       └─ error   → TERMINAL_FAILED (with $LOG path)
#                    └─ error   → TERMINAL_FAILED (with $LOG path)
#
#   Stage A / A' / C の非 0 exit は既存 Developer 失敗時遷移と同等メッセージ。
#
# Stage Checkpoint Resume (#68, デフォルト有効 / #112): `STAGE_CHECKPOINT_ENABLED=true`
#   （既定）のときに、関数冒頭で stage_checkpoint_resolve_resume_point を呼び
#   START_STAGE を取得する。START_STAGE ∈ {A, B, C, TERMINAL_OK, TERMINAL_FAILED}。
#     - TERMINAL_OK     → 既存 impl PR 検出。何もせず return 0（自動進行停止、ラベル不変）
#     - TERMINAL_FAILED → round=2 reject 残骸検出。claude-failed 化して return 1
#     - A               → 通常通り Stage A から実行（fallback / no-checkpoint / INCONSISTENT）
#     - B               → Stage A をスキップ（既存 impl-notes.md を再利用）
#     - C               → Stage A / Stage B をスキップ（既存 impl-notes / approve を再利用）
#   `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）では resolve は呼ばず、本関数は本機能
#   導入前と 1 行も挙動を変えない（NFR 1.1）。
#
# stage-a-verify gate (#125, デフォルト有効): `STAGE_A_VERIFY_ENABLED=true`（既定）の
#   ときに、Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク
#   （build/test/lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
#   （START_STAGE=B|C）でも本ブロックを通すため、Stage Checkpoint resume 経由のフロー
#   でも gate が機能する。`STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run
#   が即 return 0 して本機能導入前と user-observable に完全同一の挙動になる
#   （Req 4.1 / NFR 1.1）。失敗時は round=1 で Developer 差し戻し（**return 3 / 再 pickup
#   可能な保留・claude-failed 未付与**, Issue #219）、round=2 で claude-failed escalate
#   （return 1、内部で mark_issue_failed 済）。
#
# 入力 (環境変数経由): NUMBER, TITLE, BODY, URL, BRANCH, MODE, SPEC_DIR_REL, LOG, REPO,
#                      DEV_MODEL, DEV_MAX_TURNS, REVIEWER_MODEL, REVIEWER_MAX_TURNS,
#                      STAGE_CHECKPOINT_ENABLED (#68, default=true since #112),
#                      STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT /
#                      STAGE_A_VERIFY_COMMAND (#125)
# 戻り値:
#   0 = pipeline 成功（Stage C も成功 / PR 作成済み）または TERMINAL_OK 相当の停止
#   3 = 再 pickup 可能な保留（stage-a-verify round=1 差し戻し / Issue #219）。claude-failed
#       未付与・claude-picked-up 除去済みで次 tick に再評価される
#   1 = Stage A / A' / B / B' / C / stage-a-verify round=2 いずれかで失敗 → claude-failed 既に付与済み
run_impl_pipeline() {
  local prompt_a prompt_redo prompt_c
  local rev_rc
  # START_STAGE: STAGE_CHECKPOINT_ENABLED=true（既定）時は resolve_resume_point が
  # 値を上書きする。`=false` 明示時は "A" 固定で本機能導入前と完全一致
  # （Req 3.2 / NFR 1.1）。
  local START_STAGE="A"
  # Issue #219 Req 2.4: Stage A 完了直後の越境観測（stage_a_crossing_probe）が set し、
  # pipeline 末尾の spec_artifacts_completeness_guard へ引き継ぐ越境検出フラグ。既存
  # START_STAGE と同じく run_impl_pipeline スコープで保持する（Data Models）。set/read は
  # 別途定義された関数間の dynamic scope 経由のため SC2034 を抑制する（START_STAGE と同様）。
  # shellcheck disable=SC2034
  local STAGE_A_CROSSING_DETECTED="no"
  # shellcheck disable=SC2034
  local STAGE_A_CROSSING_PR=""

  # Stage Checkpoint Resume (#68): START_STAGE を resolve_resume_point で上書き。
  # `STAGE_CHECKPOINT_ENABLED=false` 明示時は本ブロックを skip し START_STAGE="A"
  # のままで、本機能導入前と完全等価な挙動になる（NFR 1.1）。
  # `:-true` で `unset` も既定有効として扱う（#112 でデフォルト反転）。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" = "true" ]; then
    if ! stage_checkpoint_resolve_resume_point; then
      sc_warn "resolve 異常 → Stage A 起点で安全フォールバック" >> "$LOG"
      START_STAGE="A"
    fi
    case "$START_STAGE" in
      TERMINAL_OK)
        sc_log "既存 impl PR 検出 → Stage C 再実行を停止 (Req 2.6)" >> "$LOG"
        echo "✅ #$NUMBER: 既存 impl PR を検出（Stage Checkpoint）→ 自動進行を停止" | tee -a "$LOG"
        return 0
        ;;
      TERMINAL_FAILED)
        sc_log "round=2 reject 残骸検出 → claude-failed 化 (Req 2.5)" >> "$LOG"
        echo "❌ #$NUMBER: Reviewer round=2 reject の checkpoint 残骸検出 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "stage-checkpoint-terminal-failed" \
          "Reviewer round=2 reject の checkpoint が当該 branch に残っているため、自動進行を停止します。\`${SPEC_DIR_REL}/review-notes.md\` の RESULT 行を確認し、人間判断で対応してください。"
        return 1
        ;;
    esac
  fi

  # ── Stage A: PM + Developer（impl-resume では PM スキップ / Stage Checkpoint resume 時は skip 可）──
  #
  # Phase 2 (#21): `PER_TASK_LOOP_ENABLED=true` のときは Stage A の実体を
  # `run_per_task_loop`（task 単位 fresh Implementer + fresh Reviewer のループ）に
  # 置き換える Strategy 分岐を挿入する。`PER_TASK_LOOP_ENABLED` 未指定 / `=true` 以外
  # では従来の単一 Developer 起動経路に流れ、本機能導入前と外形挙動は完全一致する
  # （Req 1.1 / NFR 1.1）。loop 完了後の verify_pushed_or_retry / stage-a-verify /
  # Stage B / Stage C は分岐の外で従来通り実行される（NFR 1.4）。
  case "$START_STAGE" in
    A)
      # per-task loop は `tasks.md` が存在する場合にのみ起動する。`PER_TASK_LOOP_ENABLED=true`
      # でも tasks.md 不在（Architect 不要 triage を通過した Issue 等）の場合は、Issue を
      # 失敗扱いせず従来の単一 Developer 経路（else ブランチ）へフォールバックする（#166 /
      # Req 1.1, 1.2, 3.1）。判定を if 条件に畳むことで、従来 Stage A ブロックを重複させずに
      # 到達させる（NFR 2.1: per-task ループ dispatcher 本体は変更しない）。
      local _pt_tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
      local _pt_loop_enabled=false
      if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then
        if [ -f "$_pt_tasks_md" ]; then
          _pt_loop_enabled=true
        else
          # AC5: フォールバック発生を判別可能なログ行を slot ログに出力（claude-failed は付けない）
          echo "--- per-task: tasks.md 不在 → Stage A fallback（$_pt_tasks_md）---" | tee -a "$LOG"
        fi
      fi
      if [ "$_pt_loop_enabled" = "true" ]; then
        echo "--- Stage A 実行（$MODE / per-task loop / PER_TASK_LOOP_ENABLED=true）---" >> "$LOG"
        if ! run_per_task_loop; then
          # run サマリ: Stage A は実行された（claude-failed 終端でも stage は走った / Req 2.1）。
          rs_record_stage A
          rs_scan_degraded_log "$LOG"
          # run_per_task_loop 内で claude-failed 付与済 / 既に Issue コメント済。
          return 1
        fi
        # run サマリ: Stage A（per-task loop）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
        rs_record_stage A
        rs_scan_degraded_log "$LOG"
        # ── per-task 全 task 完了ゲート (#194) ──
        # `run_per_task_loop` の `return 0` は「全 task 消化成功」と「quota 超過等による
        # 中間早期 return」の双方を含むため、戻り値 0 だけでは全 task 完了を保証できない。
        # ここで tasks.md を再読込し、必須 task（deferrable `- [ ]*` を除く `- [ ]`）が
        # 1 件でも残っていれば Reviewer / PR / ready-for-review へ進めず、未完了状態として
        # `return 0`（resumable）で抜ける。後続 tick の Resume Processor が残り task を消化する。
        # mark_issue_failed は呼ばない（失敗ではなく中断のため。quota 早期 return と同じ扱い）。
        # 本ゲートは `_pt_loop_enabled=true` 分岐内にのみ存在し、PER_TASK_LOOP 無効時の
        # 通常 Developer 経路（else ブランチ）には一切影響しない（Req 1.1, 1.3, 1.4, 1.5, 2.1, NFR 1.1）。
        local _pt_remaining
        _pt_remaining=$(pt_extract_pending_tasks "$_pt_tasks_md" || true)
        if [ -n "$_pt_remaining" ]; then
          local _pt_remaining_count
          _pt_remaining_count=$(printf '%s\n' "$_pt_remaining" | wc -l | tr -d '[:space:]')
          pt_log "issue=#${NUMBER} 必須未完了 task=${_pt_remaining_count} 残存 → ready-for-review 遷移を保留し resumable return 0（残: $(printf '%s' "$_pt_remaining" | tr '\n' ' '))" | tee -a "$LOG"
          echo "⏸️ #$NUMBER: per-task ループ終了時に必須未完了 task が ${_pt_remaining_count} 件残存 → ready-for-review へ進めず後続 tick で再開" | tee -a "$LOG"
          # ── 保留前の完了済み task commit を origin に push (#198 欠陥②: push-skip) ──
          # per-task ループ内に逐次 push は無く、Implementer は commit のみを積む（push は
          # 本 Stage A 末尾の verify_pushed_or_retry に集約される設計）。従来この保留経路
          # （return 0）が後段の verify_pushed_or_retry（全完了経路 / 9228 付近）より手前に
          # あったため、必須未完了のまま保留すると **完了済み task の commit が origin に
          # push されないまま** 次サイクルの branch 再初期化（impl-resume の
          # `git checkout -B "$BRANCH" "origin/$BRANCH"`）で失われ、再 pickup されても
          # task 1 からやり直す無限空転になっていた（#180 Part 2 実測）。ここで保留する前に
          # verify_pushed_or_retry で完了済み commit を origin に確実に残すことで、次サイクルの
          # impl-resume が `- [x]` skip で task N+1 から継続でき、直後の再 pickup 可能化
          # （ラベル除去）とセットで初めて「中断 → 後続 tick で継続 → 完了」が成立する
          # （Req 1.2, 2.1, NFR 3.1）。
          #
          # push リトライにも失敗した場合は verify_pushed_or_retry が mark_issue_failed を
          # 既発射している（claude-failed 付与 + claude-picked-up / claude-claimed 除去）。
          # 未 push のまま再 pickup すると空転が再発するため、保留（return 0）ではなく失敗
          # （return 1）に倒して人間に委ねる。
          if ! verify_pushed_or_retry "stageA-pt-hold-push-missing" "$BRANCH" "Stage A (per-task loop hold)"; then
            return 1
          fi
          # ── 保留 Issue の再 pickup 可能化 (#198 / Req 1.1, 1.4, NFR 2.1) ──
          # dispatcher の候補クエリは `-label:"$LABEL_PICKED"`（claude-picked-up）を除外条件に
          # 持つため、保留時に `claude-picked-up` を残したままだと当該 Issue が二度と pickup
          # 候補に上がらず impl-resume が再開せず stuck になる（#180 Part 2 の事例）。ここで
          # `claude-picked-up`（および念のため `claude-claimed`）を除去して bare auto-dev
          # candidate に戻すことで、次 tick の dispatcher が当該 Issue を再選択 → mode 判定が
          # 既存 spec/branch を検出して impl-resume を起動 → 残 task を消化する（残 task の
          # `- [x]` skip による冪等性は既存 impl-resume 機構が担保 / Req 2.1）。
          #
          # quota パスとの非干渉 (Req 3.2/3.3): 本保留は `needs-quota-wait` を一切付与しない。
          # quota 中断は `qa_handle_quota_exceeded` が `needs-quota-wait` を付け
          # `process_quota_resume` が reset+grace 経過まで待つ別経路であり、本保留はラベル除去
          # のみで `needs-quota-wait` を触らないため、quota processor の走査対象（needs-quota-wait
          # のみ）に乗らず二重処理は構造的に発生しない。
          #
          # 副作用失敗の扱い (Req 1.4): `gh issue edit` の失敗は warn 吸収して `return 0` を
          # 維持する（quota ハンドラと同じく副作用失敗で全体を落とさない方針）。失敗時は
          # `claude-picked-up` が残り当該 Issue は次 tick でも候補に上がらないが、その旨を
          # ログに残し次 tick で再評価される（人間が手動でラベル除去する余地も残す）。
          #
          # 同一 tick 即時再開について (Req 1.1): dispatcher は tick 冒頭に候補スナップショットを
          # 取得するため、tick 途中の本ラベル除去は当該 tick のキューに影響しない（同一 tick 内
          # 即時再 claim は構造的に起きず、再開は後続 tick から）。
          if gh issue edit "$NUMBER" --repo "$REPO" \
              --remove-label "$LABEL_PICKED" \
              --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
            pt_log "issue=#${NUMBER} claude-picked-up を除去し bare auto-dev candidate へ復帰 → 後続 tick で impl-resume 再開" | tee -a "$LOG"
          else
            # pt_warn は stderr 出力のため、$LOG への grep 可能な記録は別途 tee で残す（NFR 2.1）
            pt_warn "issue=#${NUMBER} claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）"
            pt_log "issue=#${NUMBER} WARN claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）" | tee -a "$LOG"
          fi
          return 0
        fi
        # per-task loop 内では Implementer が commit のみを積み push しない（push は本 Stage A
        # に集約する設計）。全 task 完了経路では loop 終了後の HEAD が完了済み commit 分だけ
        # ahead になっているため、ここで verify_pushed_or_retry が origin へ push する。push
        # 漏れ時は 1 回リトライし、失敗時は claude-failed 化して return 1 する。
        if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A (per-task loop)"; then
          return 1
        fi
        echo "✅ #$NUMBER: Stage A 完了（per-task loop）" | tee -a "$LOG"
        # ── Stage A 越境観測 (#219 Req 2) ──
        # Stage A 完了直後に当該 head ブランチの先行 impl PR を観測し、越境を検出・記録して
        # 後段の spec_artifacts_completeness_guard へグローバル変数で引き継ぐ。read-only 観測
        # で常に return 0（pipeline を止めない / NFR 1.4）。`STAGE_CHECKPOINT_ENABLED != true`
        # では 1 行も実行されず本修正導入前と完全等価（Req 2.5 / NFR 1.1）。
        stage_a_crossing_probe
        # ── Partial Status Gate (#148) ──
        # Developer が impl-notes.md 末尾に `STATUS: partial_*` を出力した場合は
        # Reviewer 起動を skip して needs-decisions エスカレーションする。status 行不在
        # / `complete` の場合は副作用なしで既存フローへ続行（NFR 1.1, 1.4）。
        local _partial_rc=0
        handle_partial_status || _partial_rc=$?
        case "$_partial_rc" in
          0)  : ;;        # continue（既存フロー）
          10) return 0 ;; # partial 検出: Reviewer skip + 正常終了
          *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
        esac
      else
        echo "--- Stage A 実行（$MODE / PM + Developer）---" >> "$LOG"
        prompt_a=$(build_dev_prompt_a "$MODE")
        # Issue #66: Quota-Aware Watcher 経由で claude を起動（Req 1.1, 1.2, 2.1）
        local _qa_reset_file_a _qa_rc_a=0 _qa_ts_a
        _qa_ts_a=$(date +%Y%m%d-%H%M%S)
        _qa_reset_file_a="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-${_qa_ts_a}"
        qa_run_claude_stage "StageA" "$_qa_reset_file_a" -- \
          claude \
            --print "$prompt_a" \
            --model "$DEV_MODEL" \
            --permission-mode bypassPermissions \
            --max-turns "$DEV_MAX_TURNS" \
            --output-format stream-json \
            --verbose \
            "${CLAUDE_HOOK_ARGS[@]}" \
            >> "$LOG" 2>&1 || _qa_rc_a=$?
        # run サマリ: Stage A（通常 Developer 経路）実行を記録し degraded 兆候を反映
        # （quota 99 / 失敗 * でも claude 起動は試みられたため stage は走った / Req 2.1, 6.x）。
        rs_record_stage A
        rs_scan_degraded_log "$LOG"
        case "$_qa_rc_a" in
          0)
            # Issue #106 Req 1: Stage A 成功宣言の前にローカル HEAD が origin に到達しているか
            # verify する。ahead == 0 なら従来どおり成功メッセージ（Req 1.3 / 5.1）、
            # ahead > 0 なら自動 push リトライ 1 回。リトライ失敗時は claude-failed 化済で
            # return 1 を伝搬する（Req 1.4, 4.4, 4.5）。
            rm -f "$_qa_reset_file_a"
            if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A"; then
              return 1
            fi
            echo "✅ #$NUMBER: Stage A 完了" | tee -a "$LOG"
            # ── Stage A 越境観測 (#219 Req 2) ──
            # 通常 Developer 経路の Stage A 完了直後に先行 impl PR を観測し、越境を検出・記録
            # して後段の spec_artifacts_completeness_guard へ引き継ぐ。read-only / 常に return 0
            # （NFR 1.4）。gate off では 1 行も実行されない（Req 2.5 / NFR 1.1）。
            stage_a_crossing_probe
            # ── Partial Status Gate (#148) ──
            # 通常 Developer 経路 (PM + Developer / 単一 Implementer) の Stage A 完了直後
            # に impl-notes.md の `STATUS:` 行を検出し、partial を 1st-class に処理する。
            # status 行不在 / `complete` の場合は副作用なし（NFR 1.1, 1.4）。
            local _partial_rc_n=0
            handle_partial_status || _partial_rc_n=$?
            case "$_partial_rc_n" in
              0)  : ;;        # continue
              10) return 0 ;; # partial 検出: Reviewer skip
              *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
            esac
            ;;
          99)
            local _qa_epoch_a
            _qa_epoch_a=$(cat "$_qa_reset_file_a")
            qa_handle_quota_exceeded "$NUMBER" "StageA" "$_qa_epoch_a"
            rm -f "$_qa_reset_file_a"
            echo "⏸️ #$NUMBER: Stage A で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            rm -f "$_qa_reset_file_a"
            echo "❌ #$NUMBER: Stage A 失敗" | tee -a "$LOG"
            mark_issue_failed "stageA" ""
            return 1
            ;;
        esac
      fi
      ;;
    B|C)
      sc_log "Stage A をスキップ（START_STAGE=$START_STAGE / 既存 impl-notes.md を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage A スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Debugger Gate (#22 Phase 3): Stage A 完了直後 BLOCKED 検出 ──
  # `DEBUGGER_ENABLED=true` 時のみ、Stage A 完了直後・stage-a-verify gate 直前で
  # `impl-notes.md` の行頭 `BLOCKED: <reason>` を検出し、Developer 自己宣言経路として
  # Debugger を 1 回起動する。BLOCKED 経路の Stage A' は通常の Round 1 サイクルに合流
  # するため、Stage B / B' で再度 Debugger 起動候補になっても sentinel が「起動済み」
  # を返すため再起動はされない（Req 5.1, 5.2）。
  # `DEBUGGER_ENABLED != "true"` の場合は本ブロックが構造的に skip され、BLOCKED 行は
  # 判定材料に使われず stage-a-verify に直行する（Req 1.2 / NFR 1.1）。
  if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
    local _blocked_reason=""
    if _blocked_reason=$(detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"); then
      if detect_debugger_already_invoked; then
        # 既起動状態での BLOCKED 再発生 → 直行 claude-failed (Req 5.2)
        dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" result=skipped reason=debugger-already-invoked" >> "$LOG"
        echo "❌ #$NUMBER: Developer BLOCKED 宣言を検出したが Debugger は既起動 → claude-failed (Req 5.2)" | tee -a "$LOG"
        mark_issue_failed "debugger-blocked-but-invoked" "Developer が \`impl-notes.md\` に \`BLOCKED:\` 行を出力しましたが、本 Issue では既に Debugger が 1 回起動済みのため再起動を抑止し人間判断に委ねます（Req 5.1, 5.2）。

- BLOCKED reason: ${_blocked_reason}
- 既存 Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\`
- impl-notes.md: \`${SPEC_DIR_REL}/impl-notes.md\`

\`$LOG\` を確認し、Fix Plan の追加修正 / 別 Issue 切り出し等を判断してください。"
        return 1
      fi

      # 未起動: Stage D (BLOCKED 経路) → Stage A' (通常差し戻し + Fix Plan 注入) → 通常 Round 1 サイクル
      echo "🐛 #$NUMBER: Developer BLOCKED 宣言検出 → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
      dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" start (detected at impl-notes.md)" >> "$LOG"
      local _dbg_rc=0
      run_debugger_stage "blocked" "" "" || _dbg_rc=$?
      case "$_dbg_rc" in
        99)
          echo "⏸️ #$NUMBER: Debugger (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        0)
          echo "✅ #$NUMBER: Debugger (BLOCKED 経路) 完了 → Stage A' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
          ;;
        *)
          # Debugger 異常終了 → mark_issue_failed 既発射、Stage A' 実行なし (Req 3.6)
          return 1
          ;;
      esac

      # ── Stage A' (Developer 再起動 + Fix Plan 注入 / BLOCKED 経路、review-notes.md なし) ──
      echo "--- Stage A' 実行（Developer 再起動 / BLOCKED 経路 Debugger Fix Plan 注入）---" >> "$LOG"
      local prompt_redo_bl
      # BLOCKED 経路では review-notes.md は無いため空文字を渡す（build_dev_prompt_redo_with_fix_plan
      # が「(Reviewer 経由ではないため review-notes.md は無し)」と明示する）
      prompt_redo_bl=$(build_dev_prompt_redo_with_fix_plan \
        "" \
        "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
      local _qa_reset_file_bl _qa_rc_bl=0 _qa_ts_bl
      _qa_ts_bl=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_bl="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-prime-blocked-${_qa_ts_bl}"
      qa_run_claude_stage "StageA-prime-blocked" "$_qa_reset_file_bl" -- \
        claude \
          --print "$prompt_redo_bl" \
          --model "$DEV_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$DEV_MAX_TURNS" \
          --output-format stream-json \
          --verbose \
          "${CLAUDE_HOOK_ARGS[@]}" \
          >> "$LOG" 2>&1 || _qa_rc_bl=$?
      # run サマリ: Stage A'（BLOCKED 経路 Developer 再起動）実行を記録（Req 2.1, 6.x）。
      rs_record_stage "A'"
      rs_scan_degraded_log "$LOG"
      case "$_qa_rc_bl" in
        0)
          rm -f "$_qa_reset_file_bl"
          if ! verify_pushed_or_retry "stageA-prime-blocked-push-missing" "$BRANCH" "Stage A' (BLOCKED 経路)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Stage A' (BLOCKED 経路) 完了 → 通常 Round 1 サイクルに合流 (Req 4.4)" | tee -a "$LOG"
          # ── Partial Status Gate (#148) ──
          # BLOCKED 経路の Stage A' 完了直後でも partial 検出を有効化する（Debugger Fix Plan
          # 注入後の再実装で Developer が partial を宣言した場合に Reviewer 起動を skip）。
          local _partial_rc_bl=0
          handle_partial_status || _partial_rc_bl=$?
          case "$_partial_rc_bl" in
            0)  : ;;        # continue
            10) return 0 ;; # partial 検出: Reviewer skip
            *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
          esac
          ;;
        99)
          local _qa_epoch_bl
          _qa_epoch_bl=$(cat "$_qa_reset_file_bl")
          qa_handle_quota_exceeded "$NUMBER" "StageA-prime-blocked" "$_qa_epoch_bl"
          rm -f "$_qa_reset_file_bl"
          echo "⏸️ #$NUMBER: Stage A' (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        *)
          rm -f "$_qa_reset_file_bl"
          echo "❌ #$NUMBER: Stage A' (BLOCKED 経路 Developer 再実行) 失敗" | tee -a "$LOG"
          mark_issue_failed "stageA-prime-blocked" "BLOCKED 経路の Debugger 経由 Developer 再実行（Stage A'）が claude 非 0 exit で失敗しました（rc=${_qa_rc_bl}）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      # 続行: stage-a-verify → Stage B (Round 1) に合流（Req 4.4）
    fi
  fi

  # ── stage-a-verify gate (#125) ──
  # Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク（build /
  # test / lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
  # （START_STAGE=B|C）でも通すことで Stage Checkpoint resume 経由のフローでも
  # gate が機能する（design.md「stage-a-verify と Stage Checkpoint の協調」参照）。
  # `STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run が即 return 0 して
  # 本機能導入前と user-observable に完全同一の挙動になる（Req 4.1 / NFR 1.1）。
  # `stage_a_verify_run` の戻り値 0/1/2 を `run_impl_pipeline` の戻り値契約にマップする
  # （NFR 1.3）:
  #   - 0 = SUCCESS / SKIPPED / DISABLED → 続行
  #   - 1 = round=1 差し戻し → run_impl_pipeline は **3（再 pickup 可能な保留）** を返す。
  #         claude-failed は付与されておらず、ここで claude-picked-up / claude-claimed を
  #         除去して次 tick の再 pickup を成立させる（Issue #219）。
  #   - 2 = round=2 escalate → 内部で `mark_issue_failed` 発火済み（claude-failed）。
  #         run_impl_pipeline は従来どおり 1（失敗）を返す。
  local _sav_rc=0
  stage_a_verify_run || _sav_rc=$?
  # ── run サマリ: stage-a-verify 結果記録（#239 task 5 / Req 4.1, 4.2, 4.3） ──
  # `stage_a_verify_run` が露出する `_SAV_LAST_OUTCOME`（success / skip / disabled /
  # round1 / round2）を `rs_record_sav` に渡し run サマリの `stage-a-verify=` を確定する。
  # 戻り値 0 は SUCCESS / SKIPPED / DISABLED を区別できないため outcome 変数を使う。
  # 変数代入のみの副作用（戻り値常に 0）で `_sav_rc` の case 分岐・ラベル遷移・exit code に
  # 影響しない（NFR 1.1, 1.2）。run-summary.sh は本体 REQUIRED_MODULES で source 済みのため
  # task 3 の rs_set_mode と同じく bare 呼び出し（空入力時は no-op で既定 n/a を維持）。
  rs_record_sav "${_SAV_LAST_OUTCOME:-}"
  case "$_sav_rc" in
    0)
      : ;;  # SUCCESS / SKIPPED / DISABLED → 続行
    1)
      # stage-a-verify round=1 差し戻し（次 tick で再評価）。`claude-picked-up` を残すと
      # dispatcher の候補クエリ（`-label:"$LABEL_PICKED"`）から除外され二度と再 pickup
      # されず stuck になる（per-task hold #198 と同根 / Issue #219）。ここで
      # claude-picked-up / claude-claimed を除去して bare auto-dev candidate へ復帰させ、
      # 次 tick の再 pickup → Stage Checkpoint resume → stage-a-verify 再評価
      # （round=2 escalate への前進）を成立させる。round counter sidecar は温存するため、
      # 次回失敗で round=2 → claude-failed に進む。戻り値 3 は呼び出し側で「再 pickup 可能な
      # 保留」として扱われ、虚偽の「claude-failed 付与済み」ログを出さない。
      echo "🔁 #$NUMBER: stage-a-verify 失敗（round=1）→ Developer 差し戻し（claude-picked-up 除去 / 次 tick で再評価）" | tee -a "$LOG"
      # run サマリ: 最終遷移を hold（保留 = claude-failed を付けず次 tick で再 pickup する
      # round=1 defer）として記録（design.md L59-60「round=1 defer（保留）」/ Req 7.1）。
      # 変数代入のみで return 3 の保留契約・ラベル除去・exit code に影響しない（NFR 1.1, 1.2）。
      rs_set_result hold
      # claude-picked-up を除去して再 pickup 可能化（fail-open: 除去失敗でも保留は維持）。
      stage_a_verify_round1_defer || true
      return 3
      ;;
    2)
      echo "❌ #$NUMBER: stage-a-verify 連続 2 回失敗 → claude-failed" | tee -a "$LOG"
      return 1
      ;;
  esac

  # ── Stage B (round=1): Reviewer / Stage A' / Stage B(round=2) ──
  case "$START_STAGE" in
    A|B)
      rev_rc=0
      # #333: REVIEWER_SKIP_PATTERN（opt-in）— 全変更ファイルがパターンに一致する場合のみ
      # Stage B をスキップして自動 approve に倒す（_reviewer_skip_check が自動 approve の
      # review-notes.md 生成とログ出力まで実施済み）。スキップ時は Reviewer が実行されて
      # いないため rs_record_stage B は記録しない（run-summary の実行実態と一致させる）。
      if _reviewer_skip_check; then
        rev_rc=0
      else
        run_reviewer_stage 1 || rev_rc=$?
        # run サマリ: Stage B（Reviewer round=1）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
        # Reviewer verdict / round の記録は task 6 の責務。ここは stage 記録のみ。
        rs_record_stage B
        rs_scan_degraded_log "$LOG"
      fi
      case $rev_rc in
        0)
          # Issue #106 Req 3: Stage B (Reviewer round=1 approve) 完了直後に push 状態 verify。
          # review-notes.md が Reviewer によって commit されているが未 push のケースを検出する
          # （Req 3.4 review-notes.md 識別ログ粒度は stage label "Stage B (round=1 approve)" で表現）。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 approve)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Reviewer round=1 approve" | tee -a "$LOG"
          # Issue #349 Req 3.1: review-notes.md 確定 + push 済の状態で claude-review status を publish。
          # AND 二重 opt-in (PR_REVIEWER_STATUS_CHECK_ENABLED && FULL_AUTO_ENABLED) が成立した場合のみ動く。
          publish_claude_review_status 1 || true
          ;;
        99)
          # Issue #66: Reviewer round=1 で quota 超過検出。run_reviewer_stage 内で
          # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
          echo "⏸️ #$NUMBER: Reviewer round=1 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        1)
          # Issue #106 Req 3: Stage B (Reviewer round=1 reject) 完了直後にも push 状態 verify。
          # 「reject だが review-notes.md 未 push」状態で Stage A' を起動すると Stage A' 側の
          # build_dev_prompt_redo が origin の古い review-notes.md を参照する事故を防ぐ。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 reject)"; then
            return 1
          fi
          # Issue #349 Req 3.2: round=1 reject 段階の review-notes.md からも claude-review=failure
          # を publish しておく（後続 round=2 で再 publish して上書き / Req 4.3 latest-wins）。
          publish_claude_review_status 1 || true
          echo "🔁 #$NUMBER: Reviewer round=1 reject → Developer 再実行" | tee -a "$LOG"
          rv_dev_log "redo by reviewer reject (round=1)" >> "$LOG"

          # ── Stage A' (Developer 再実行) ──
          echo "--- Stage A' 実行（Developer 再実行 / Reviewer reject 差し戻し）---" >> "$LOG"
          prompt_redo=$(build_dev_prompt_redo "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")
          # Issue #66: Quota-Aware Watcher 経由で claude を起動
          local _qa_reset_file_aredo _qa_rc_aredo=0 _qa_ts_aredo
          _qa_ts_aredo=$(date +%Y%m%d-%H%M%S)
          _qa_reset_file_aredo="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-redo-${_qa_ts_aredo}"
          qa_run_claude_stage "StageA-redo" "$_qa_reset_file_aredo" -- \
            claude \
              --print "$prompt_redo" \
              --model "$DEV_MODEL" \
              --permission-mode bypassPermissions \
              --max-turns "$DEV_MAX_TURNS" \
              --output-format stream-json \
              --verbose \
              "${CLAUDE_HOOK_ARGS[@]}" \
              >> "$LOG" 2>&1 || _qa_rc_aredo=$?
          # run サマリ: Stage A'（Reviewer reject 差し戻し Developer 再実行）実行を記録
          # （Req 2.1, 6.x）。
          rs_record_stage "A'"
          rs_scan_degraded_log "$LOG"
          case "$_qa_rc_aredo" in
            0)
              # Issue #106 Req 2: Stage A' 成功宣言の前にローカル HEAD が origin に到達して
              # いるか verify する（Req 2.1〜2.3, 4.1〜4.5）。
              rm -f "$_qa_reset_file_aredo"
              if ! verify_pushed_or_retry "stageA-prime-push-missing" "$BRANCH" "Stage A'"; then
                return 1
              fi
              echo "✅ #$NUMBER: Stage A' 完了" | tee -a "$LOG"
              # ── Partial Status Gate (#148) ──
              # Reviewer reject 差し戻し経路の Stage A' 完了直後でも partial 検出を有効化
              # する（再実装中に Developer が partial を宣言した場合に Reviewer round=2
              # 起動を skip）。
              local _partial_rc_aredo=0
              handle_partial_status || _partial_rc_aredo=$?
              case "$_partial_rc_aredo" in
                0)  : ;;        # continue
                10) return 0 ;; # partial 検出: Reviewer skip
                *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
              esac
              ;;
            99)
              local _qa_epoch_aredo
              _qa_epoch_aredo=$(cat "$_qa_reset_file_aredo")
              qa_handle_quota_exceeded "$NUMBER" "StageA-redo" "$_qa_epoch_aredo"
              rm -f "$_qa_reset_file_aredo"
              echo "⏸️ #$NUMBER: Stage A' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            *)
              rm -f "$_qa_reset_file_aredo"
              echo "❌ #$NUMBER: Stage A' (Developer 再実行) 失敗" | tee -a "$LOG"
              mark_issue_failed "stageA-redo" ""
              return 1
              ;;
          esac

          # ── Stage B (round=2): Reviewer 最終回 ──
          rev_rc=0
          run_reviewer_stage 2 || rev_rc=$?
          # run サマリ: Stage B'（Reviewer round=2 最終回）実行を記録し degraded 兆候を反映
          # （Req 2.1, 6.x）。Reviewer verdict / round の記録は task 6 の責務。
          rs_record_stage "B'"
          rs_scan_degraded_log "$LOG"
          case $rev_rc in
            0)
              # Issue #106 Req 3: Stage B (Reviewer round=2 approve) 完了直後の push 状態 verify。
              if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 approve)"; then
                return 1
              fi
              echo "✅ #$NUMBER: Reviewer round=2 approve" | tee -a "$LOG"
              # Issue #349 Req 3.1: round=2 approve → claude-review=success を publish
              publish_claude_review_status 2 || true
              ;;
            99)
              # Issue #66: Reviewer round=2 で quota 超過検出。run_reviewer_stage 内で
              # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
              echo "⏸️ #$NUMBER: Reviewer round=2 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            1)
              # Issue #106 Req 3.1: Stage B 完了は reject / approve いずれも verify 対象。
              # 本ケース（round=2 reject）は Debugger Gate 経路への分岐 / もしくは
              # reviewer-reject2 で claude-failed に確定するため、verify 自体は best-effort
              # で実行し失敗してもより情報量の多い後続経路を優先する。ahead > 0 検出時の
              # WARN ログ / 自動 push 復旧コメントは verify_pushed_or_retry 内で出力済
              # （観測可能性は維持）。
              verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 reject)" || true
              # Issue #349 Req 3.2: round=2 reject → claude-review=failure を publish（Debugger
              # 経路 / reject2 経路いずれに進む場合でも、現時点の RESULT を反映する）。
              publish_claude_review_status 2 || true

              # Phase 3 (#22): DEBUGGER_ENABLED=true 時のみ Debugger Gate に分岐。
              # Debugger 未起動（sentinel 不在）なら Stage D (Round 2 reject) → Stage A''
              # (Developer 再起動 + Fix Plan 注入) → Stage B'' (Reviewer Round 3) を 1 回だけ
              # 試行する。`DEBUGGER_ENABLED != "true"` または sentinel 既起動の場合は
              # 既存 reviewer-reject2 経路（claude-failed 直行）にフォールバック。
              # 本分岐が構造的に skip されるため、DEBUGGER_ENABLED 未指定 / `=false` の
              # 既存挙動は完全に不変（NFR 1.1 / Req 1.1, 1.2）。
              if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked; then
                echo "🐛 #$NUMBER: Reviewer round=2 reject → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
                local _dbg_rc=0
                run_debugger_stage "round2-reject" "" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" || _dbg_rc=$?
                case "$_dbg_rc" in
                  99)
                    # quota 超過: 既存 #66 規約に従い watcher は正常終了。Resume Processor が次 tick で再開
                    echo "⏸️ #$NUMBER: Debugger で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  0)
                    # Debugger 正常終了 + debugger-notes.md verify 成功 → Stage A'' へ
                    echo "✅ #$NUMBER: Debugger 完了 → Stage A'' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
                    ;;
                  *)
                    # Debugger 異常終了 / verify 失敗 → mark_issue_failed 既発射、Stage A''/B'' 実行なし (Req 3.6)
                    return 1
                    ;;
                esac

                # ── Stage A'' (Developer 再起動 + Fix Plan 注入) ──
                echo "--- Stage A'' 実行（Developer 再起動 / Debugger Fix Plan 注入）---" >> "$LOG"
                local prompt_redo_fp
                prompt_redo_fp=$(build_dev_prompt_redo_with_fix_plan \
                  "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" \
                  "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
                local _qa_reset_file_app _qa_rc_app=0 _qa_ts_app
                _qa_ts_app=$(date +%Y%m%d-%H%M%S)
                _qa_reset_file_app="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-pp-${_qa_ts_app}"
                qa_run_claude_stage "StageA-pp" "$_qa_reset_file_app" -- \
                  claude \
                    --print "$prompt_redo_fp" \
                    --model "$DEV_MODEL" \
                    --permission-mode bypassPermissions \
                    --max-turns "$DEV_MAX_TURNS" \
                    --output-format stream-json \
                    --verbose \
                    "${CLAUDE_HOOK_ARGS[@]}" \
                    >> "$LOG" 2>&1 || _qa_rc_app=$?
                case "$_qa_rc_app" in
                  0)
                    rm -f "$_qa_reset_file_app"
                    if ! verify_pushed_or_retry "stageA-pp-push-missing" "$BRANCH" "Stage A''"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Stage A'' 完了" | tee -a "$LOG"
                    # ── Partial Status Gate (#148) ──
                    # Debugger 経由 Stage A'' 完了直後でも partial 検出を有効化する。
                    # Fix Plan を注入されてもなお Developer が partial を宣言した場合に
                    # Reviewer round=3 起動を skip。
                    local _partial_rc_app=0
                    handle_partial_status || _partial_rc_app=$?
                    case "$_partial_rc_app" in
                      0)  : ;;        # continue
                      10) return 0 ;; # partial 検出: Reviewer skip
                      *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
                    esac
                    ;;
                  99)
                    local _qa_epoch_app
                    _qa_epoch_app=$(cat "$_qa_reset_file_app")
                    qa_handle_quota_exceeded "$NUMBER" "StageA-pp" "$_qa_epoch_app"
                    rm -f "$_qa_reset_file_app"
                    echo "⏸️ #$NUMBER: Stage A'' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  *)
                    rm -f "$_qa_reset_file_app"
                    echo "❌ #$NUMBER: Stage A'' (Debugger 経由 Developer 再実行) 失敗" | tee -a "$LOG"
                    mark_issue_failed "stageA-pp" "Debugger 経由 Developer 再実行（Stage A''）が claude 非 0 exit で失敗しました（rc=${_qa_rc_app}）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac

                # ── Stage B'' (Reviewer Round 3): Debugger 経由の最終 Reviewer ──
                local rev_rc3=0
                run_reviewer_stage 3 || rev_rc3=$?
                # Round 3 結果をログに記録（NFR 2.1 の 4 イベント目）
                case "$rev_rc3" in
                  0)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=approve" >> "$LOG"
                    if ! verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 approve)"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Reviewer round=3 approve（Debugger 経由）" | tee -a "$LOG"
                    # Issue #349 Req 3.1: round=3 approve → claude-review=success
                    publish_claude_review_status 3 || true
                    # 既存 approve 後経路（Stage C）に合流するため case を抜ける
                    ;;
                  99)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=quota-exceeded" >> "$LOG"
                    echo "⏸️ #$NUMBER: Reviewer round=3 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  1)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=reject" >> "$LOG"
                    verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 reject)" || true
                    # Issue #349 Req 3.2: round=3 reject → claude-review=failure
                    publish_claude_review_status 3 || true
                    echo "❌ #$NUMBER: Reviewer round=3 reject → claude-failed（Debugger 再起動なし / Req 3.5）" | tee -a "$LOG"
                    local parsed3 cat3 tgt3
                    parsed3=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                    cat3=$(echo "$parsed3" | cut -f2)
                    tgt3=$(echo "$parsed3" | cut -f3)
                    local reject_body3
                    reject_body3="Debugger 経由の Reviewer round=3 でも reject となったため、自動 iteration を打ち切り人間判断に委ねます（Debugger は 1 Issue あたり 1 回のみ起動するため再起動しません / Req 3.5）。

- 対象 requirement ID: ${tgt3:-(unknown)}
- reject カテゴリ: ${cat3:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照
- Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` を参照

### 次の手順
1. review-notes.md / debugger-notes.md / watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                    mark_issue_failed "reviewer-reject3" "$reject_body3"
                    # run サマリ: Reviewer reject による差し戻しループ打ち切り終端を
                    # needs-iteration として記録（Req 7.1）。mark_issue_failed が記録した
                    # claude-failed を、Reviewer 判定起因の終端として needs-iteration に
                    # 上書きする（design.md result enum / tasks.md task 6 を正本とする）。
                    # 変数代入のみで claude-failed ラベル遷移・exit code は不変（NFR 1.1, 1.2）。
                    rs_set_result needs-iteration
                    return 1
                    ;;
                  4)
                    # Issue #296 Req 2.3 / Req 4.3 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
                    # → `reviewer-missing-file` カテゴリで `claude-failed`。装飾起因 parse 失敗
                    # （reviewer-error）と grep で区別可能な reason を発行する。
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=missing-file-after-retry" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
                    mark_issue_failed "reviewer-missing-file" "Debugger 経由の Reviewer round=3 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                  6)
                    # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇 → `reviewer-max-turns-exhausted`
                    # カテゴリで `claude-failed`（Debugger 経由 round=3）。run-summary degraded は記録済み。
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=max-turns-exhausted" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
                    mark_issue_failed "reviewer-max-turns-exhausted" "Debugger 経由の Reviewer round=3 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                  *)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=error" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 異常終了 → claude-failed" | tee -a "$LOG"
                    mark_issue_failed "reviewer-error" "Debugger 経由の Reviewer round=3 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac
              else
                # DEBUGGER_ENABLED != "true" もしくは sentinel 既起動 → 既存 reviewer-reject2 経路
                if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
                  # Debugger 既起動状態での Round 2 reject 再発生 (Req 5.2)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=none result=skipped reason=debugger-already-invoked" >> "$LOG"
                fi
                # 2 回目 reject → claude-failed + Issue コメントに reject 理由 / 対象 ID を含める
                echo "❌ #$NUMBER: Reviewer round=2 reject → claude-failed" | tee -a "$LOG"
                local parsed2 cat2 tgt2
                parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                cat2=$(echo "$parsed2" | cut -f2)
                tgt2=$(echo "$parsed2" | cut -f3)
                local reject_body
                reject_body="Reviewer が 2 回連続で reject を出したため、自動 iteration を打ち切り、人間判断に委ねます。

- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                mark_issue_failed "reviewer-reject2" "$reject_body"
                # run サマリ: Reviewer 2 回連続 reject による差し戻しループ打ち切り終端を
                # needs-iteration として記録（Req 7.1）。mark_issue_failed が記録した
                # claude-failed を、Reviewer 判定起因の終端として needs-iteration に
                # 上書きする（design.md result enum / tasks.md task 6 を正本とする）。
                # 変数代入のみで claude-failed ラベル遷移・exit code は不変（NFR 1.1, 1.2）。
                rs_set_result needs-iteration
                return 1
              fi
              ;;
            4)
              # Issue #296 Req 2.3 / Req 4.1 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
              # → `reviewer-missing-file` カテゴリで `claude-failed`（round=2）。
              echo "❌ #$NUMBER: Reviewer round=2 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
              mark_issue_failed "reviewer-missing-file" "Reviewer round=2 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
              return 1
              ;;
            6)
              # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇 → `reviewer-max-turns-exhausted`
              # カテゴリで `claude-failed`（round=2）。run-summary degraded は run_reviewer_stage 内で記録済み。
              echo "❌ #$NUMBER: Reviewer round=2 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
              mark_issue_failed "reviewer-max-turns-exhausted" "Reviewer round=2 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
              return 1
              ;;
            *)
              # round=2 reviewer error
              echo "❌ #$NUMBER: Reviewer round=2 異常終了 → claude-failed" | tee -a "$LOG"
              mark_issue_failed "reviewer-error" "Reviewer round=2 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
              return 1
              ;;
          esac
          ;;
        4)
          # Issue #296 Req 2.3 / Req 4.1 / NFR 2.2: ファイル不在 + 1 回限定リトライ後も生成されず
          # → `reviewer-missing-file` カテゴリで `claude-failed`（round=1）。
          echo "❌ #$NUMBER: Reviewer round=1 ファイル不在（リトライ後も未生成）→ claude-failed (reviewer-missing-file)" | tee -a "$LOG"
          mark_issue_failed "reviewer-missing-file" "Reviewer round=1 が rc=0 で終了しましたが、\`${SPEC_DIR_REL}/review-notes.md\` が同一 round 内の 1 回限定リトライ後も生成されませんでした（Issue #296 ファイル不在経路）。Reviewer subagent の Write 漏れが疑われます。\`$LOG\` を確認してください。"
          return 1
          ;;
        6)
          # Issue #442 Req 3.1, 3.2, 3.4: 拡張リトライ後も turn 切れ枯渇（error_max_turns）で
          # verdict 未到達 → `reviewer-max-turns-exhausted` カテゴリで `claude-failed`（round=1）。
          # reviewer-error（claude crash）/ reviewer-missing-file（ファイル不在）/ code reject の
          # いずれとも grep 区別可能な reason を発行する。run-summary degraded は run_reviewer_stage
          # 内で記録済み（Req 3.3）。
          echo "❌ #$NUMBER: Reviewer round=1 turn 切れ枯渇（拡張リトライ後も未到達）→ claude-failed (reviewer-max-turns-exhausted)" | tee -a "$LOG"
          mark_issue_failed "reviewer-max-turns-exhausted" "Reviewer round=1 が turn 上限到達（\`error_max_turns\`）で終了し、拡張 turn 予算（\`REVIEWER_MAX_TURNS_EXTENDED\`=${REVIEWER_MAX_TURNS_EXTENDED}）での 1 回再実行後もなお turn 切れで verdict（\`RESULT:\` 行）に到達できませんでした（Issue #442）。claude crash / ファイル不在 / code reject とは異なり、turn 不足が原因です。大規模 spec / diff の場合は \`REVIEWER_MAX_TURNS\` / \`REVIEWER_MAX_TURNS_EXTENDED\` の引き上げを検討してください。\`$LOG\` を確認してください。"
          return 1
          ;;
        *)
          # round=1 reviewer error → claude-failed + Issue コメント (要件 4.8)
          echo "❌ #$NUMBER: Reviewer round=1 異常終了 → claude-failed" | tee -a "$LOG"
          mark_issue_failed "reviewer-error" "Reviewer round=1 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    C)
      sc_log "Stage B をスキップ（START_STAGE=C / 既存 review-notes.md approve を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage B スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Stage C: PjM (PR 作成) ──
  echo "--- Stage C 実行（PjM / PR 作成）---" >> "$LOG"
  # Issue #212: PR 作成処理へ進む直前に同一 head ブランチの既存 impl PR を再確認する
  # 冪等ガード。サイクル開始時の resolve_resume_point とは別に、同一サイクル内で Stage A
  # が越境して PR を作成したケースを検出して二重 PR を防ぐ（Req 1.4 / NFR 2.1）。
  # `STAGE_CHECKPOINT_ENABLED=true`（既定）時のみ実行（Req 1.2 / NFR 1.2）。
  # return 0（既存 PR 検出で作成抑止）の場合のみ pipeline を成功停止する。OPEN/MERGED は
  # 既存 TERMINAL_OK と同一の return 0、CLOSED はガード内で needs-decisions 付与済み。
  if stage_c_existing_pr_guard; then
    echo "✅ #$NUMBER: 既存 impl PR を検出（Stage C 冪等ガード）→ 新規 PR 作成を抑止して停止" | tee -a "$LOG"
    # ── spec 成果物完全性保証 (#219 Req 3 / 4) ──
    # #213 ガードが OPEN/MERGED/CLOSED で停止したケースを後段の独立経路として捕捉し、
    # MERGED 先行 PR + req/review 欠落のときだけ docs-only 補完追従 PR を起動する。
    # stage_c_existing_pr_guard は一切変更せず、その後段で呼ぶことで Req 4.1 退行を防ぐ。
    # 常に return 0（pipeline 最終結果を変えない / NFR 1.4）。gate off では無効（Req 3.5 / NFR 1.1）。
    spec_artifacts_completeness_guard
    return 0
  fi
  # Issue #96 Req 1.5: PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
  if ! _assert_base_branch_resolved; then
    echo "❌ #$NUMBER: Stage C 中断（BASE_BRANCH 未解決）→ claude-failed" | tee -a "$LOG"
    mark_issue_failed "stageC-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため Stage C を中断しました（Issue #96 Req 1.5）。"
    return 1
  fi
  prompt_c=$(build_dev_prompt_c "$MODE")
  # Issue #66: Quota-Aware Watcher 経由で claude を起動
  local _qa_reset_file_c _qa_rc_c=0 _qa_ts_c
  _qa_ts_c=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_c="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageC-${_qa_ts_c}"
  # #329: --agent project-manager で agent 定義をトップレベル実行（オーケストレーター層なし）。
  # agent 解決失敗時は claude 非ゼロ exit → 既存 stageC 失敗遷移 + run-summary degraded 検知。
  qa_run_claude_stage "StageC" "$_qa_reset_file_c" -- \
    claude \
      --agent project-manager \
      --print "$prompt_c" \
      --model "$PJM_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      "${CLAUDE_HOOK_ARGS[@]}" \
      >> "$LOG" 2>&1 || _qa_rc_c=$?
  # run サマリ: Stage C（PjM / PR 作成）実行を記録し degraded 兆候を反映（Req 2.1, 6.x）。
  # 既存 PR ガード（stage_c_existing_pr_guard）で PjM 起動前に early return したケースでは
  # PjM が走らないため本行に到達せず Stage C は記録されない（実際に走った stage のみ / Req 2.1）。
  rs_record_stage C
  rs_scan_degraded_log "$LOG"
  case "$_qa_rc_c" in
    0)
      # Issue #104 Bug 3 / Req 4.1〜4.4: claude RC=0 + quota 検出なし時点では
      # 「PR が実際に作成されたか」が未確認。PjM サブエージェントが 1 turn で
      # 空転終了しても claude RC=0 を返すため、PR 実在を gh で verify する。
      # Issue #108: GitHub の eventual consistency による false negative を吸収する
      # ため、verify_stagec_pr_or_retry で主経路リトライを実施。
      # Issue #110: 73 秒以上の edge cache lag を観測した実例（KeyNest #32）への
      # 対応として主経路を 6 回 / 合計 135 秒に延長し、最終 attempt 後に List Pulls
      # API への独立 fallback を 1 ターン追加。1 回目で成功する通常ケースの外形
      # 挙動は本変更前と同一（Req 4.1 / 4.6 / NFR 1.1）。
      rm -f "$_qa_reset_file_c"
      local _stagec_pr_url _stagec_verify_rc=0
      _stagec_pr_url=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || _stagec_verify_rc=$?
      if [ "$_stagec_verify_rc" -eq 0 ] && [ -n "$_stagec_pr_url" ]; then
        # Req 4.3 / Issue #108 Req 3.4 / Issue #110 Req 3.6: 主経路 1 回目即時成功
        # でも代替経路救済でも、呼び出し側の成功ログは共通（外形互換）
        echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み (${_stagec_pr_url})" | tee -a "$LOG"
        # run サマリ: Stage C 成功（impl PR 作成 → ready-for-review へ向かう終端 / Req 7.1）。
        # 変数代入のみで PR 作成 / ラベル遷移 / exit code に影響しない（NFR 1.1, 1.2）。
        rs_set_result ready-for-review
        # ── spec 成果物完全性保証 (#219 Req 3 / 4) ──
        # Stage C で新規 impl PR を作った通常成功ケースも通過点として完全性を最終確認する。
        # 標準構成を満たしていれば追加処理なしで return 0（design-full impl の通常成功は
        # ここで早期 return 相当 / Req 3.5 / NFR 1.1）。常に return 0（NFR 1.4）。
        spec_artifacts_completeness_guard
        return 0
      fi
      # Req 4.2 / 4.4 / Issue #108 Req 2.1 / Issue #110 Req 2.3 / 2.4:
      # 主経路リトライ + 代替経路 1 ターンを使い切っても PR 不在の場合は
      # 安全側に倒し claude-failed 化（NFR 2.2: 人間が原因を特定できる粒度のログを残す）
      echo "❌ #$NUMBER: Stage C 完了報告だが対応 PR 不在 → claude-failed (branch=$BRANCH verify_rc=$_stagec_verify_rc, 主経路リトライ + 代替 API 経路 fallback 後)" | tee -a "$LOG"
      qa_warn "stageC PR verify failed after retry+fallback issue=#$NUMBER branch=$BRANCH verify_rc=$_stagec_verify_rc pr_url='${_stagec_pr_url:-(empty)}'"
      mark_issue_failed "stageC-pr-missing" "Stage C の Claude 実行は return code 0 で終了しましたが、対応する impl PR が GitHub 側に検出できませんでした（branch=\`$BRANCH\`、主経路リトライ + 代替 API 経路 fallback 後）。PjM サブエージェントが 1 turn で空転終了した可能性 / GitHub API 一時障害の可能性のいずれかです。\`$LOG\` を確認してください。"
      return 1
      ;;
    99)
      local _qa_epoch_c
      _qa_epoch_c=$(cat "$_qa_reset_file_c")
      qa_handle_quota_exceeded "$NUMBER" "StageC" "$_qa_epoch_c"
      rm -f "$_qa_reset_file_c"
      echo "⏸️ #$NUMBER: Stage C で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
      return 0
      ;;
    *)
      rm -f "$_qa_reset_file_c"
      echo "❌ #$NUMBER: Stage C (PjM) 失敗" | tee -a "$LOG"
      mark_issue_failed "stageC" ""
      return 1
      ;;
  esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Issue 入口並列化 (worktree slot + dispatcher, #16)
#
# auto-dev Issue 処理ループを Dispatcher / Slot Worker パターンに置き換え、
# 複数 Issue を時間的に重ねて処理できるようにする。
#
# 構成:
#   - _parallel_validate_slots : PARALLEL_SLOTS 検証
#   - Worktree Manager  : per-slot 永続 worktree の初期化・最新化
#   - Slot Lock Manager : per-slot 非ブロッキング flock の取得・解放
#   - Hook Layer        : SLOT_INIT_HOOK の絶対パス起動（eval 不使用）
#   - Slot Runner       : 1 Issue を 1 worktree で処理する Worker
#   - Dispatcher        : Issue 候補取得 → claim → slot 投入 → 全 Worker wait
#
# PARALLEL_SLOTS=1（デフォルト）のとき、slot-2 以降の lock / worktree を作成せず、
# 本機能導入前と外形的に同一挙動になるよう実装する。
#
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Phase C: Logger ───
# Dispatcher / Slot Worker / Worktree / Hook 共通の timestamp 形式（既存 mq_log 等と同じ）
dispatcher_log() {
  echo "[$(date '+%F %T')] dispatcher: $*"
}
dispatcher_warn() {
  echo "[$(date '+%F %T')] dispatcher: WARN: $*" >&2
}
dispatcher_error() {
  echo "[$(date '+%F %T')] dispatcher: ERROR: $*" >&2
}

# ─── Pre-Claim Probe Logger (Issue #65) ───
# claim 直前に linked impl PR を検出する Pre-Claim Filter 用 logger。
# 既存 mq_log / pi_log / drr_log / qa_log / sc_log / dispatcher_log と同じ
# `[$(date '+%F %T')] <prefix>: ...` 形式に揃え、識別 prefix `pre-claim-probe:`
# で grep 集計できるようにする（Req NFR 2.1）。
pclp_log() {
  echo "[$(date '+%F %T')] pre-claim-probe: $*"
}
pclp_warn() {
  echo "[$(date '+%F %T')] pre-claim-probe: WARN: $*" >&2
}
pclp_error() {
  echo "[$(date '+%F %T')] pre-claim-probe: ERROR: $*" >&2
}

# ─── check_existing_impl_pr (Issue #65 / Pre-Claim Filter) ───
#
# 与えられた Issue 番号にリンクされた impl PR の有無と state を GraphQL で取得し、
# Dispatcher が当該 Issue を **claim する前** に skip すべきかを判定する。
#
# 事故起点の整理（Issue #65 / 2026-04-29 PR #62 orphan 化）:
#   `claude-failed` 復旧で `claude-failed` のみが除去された Issue は、`auto-dev` が
#   残っているため次 cron tick で再 pickup されてしまう。`_dispatcher_run` は claim
#   直前に linked PR の存在を一切確認していなかったため、impl-resume が起動して
#   既存 PR を `force-push` で破壊する事故が発生する。本関数はその claim 直前の
#   ガードとして機能する。
#
# 入力:  $1 = issue_number（数値）
# 出力:  exit code で判定結果を返す
#        - 0 = pickup 続行 OK（linked impl PR なし or CLOSED のみ）
#        - 1 = skip すべき（OPEN or MERGED の impl PR が存在 / API 失敗 / レート制限）
# 副作用:
#        - 判定結果を pclp_log / pclp_warn で 1 行ログ出力
#          （fixed key=value 形式: `issue=#N pr=#P state=S reason=R` / NFR 2.1〜2.3）
#        - GitHub GraphQL を `timeout "$DRR_GH_TIMEOUT"` で 1 回呼ぶ（NFR 4.1）
#
# Fail-safe: GraphQL 失敗 / timeout / 4xx / 5xx / RATE_LIMITED / 不正レスポンスは
#            **すべて skip 扱い**（exit 1）に倒す。誤って claim して既存 PR を破壊する
#            リスクを最小化するため（Req 1.7 / NFR 4.2）。
#
# 判別ロジック:
#   linked_prs = closedByPullRequestsReferences.nodes（Issue 視点の逆引き field、
#                GitHub は auto-close キーワード
#                `Closes` / `Fixes` / `Resolves` でのみ収集 → impl PR 専用に集約される）
#   for pr in linked_prs:
#     if headRefName が `^claude/issue-${N}-impl(-resume)?-` → impl 採用
#     elif headRefName が `^claude/issue-${N}-design-`     → design として無視 (warn)
#     else                                                  → 未知 pattern → safe-side で
#                                                            impl 扱い (false positive
#                                                            許容、false negative=
#                                                            既存 PR 破壊 を回避)
#   states 集約:
#     OPEN 含む                        → skip (Req 1.2)
#     MERGED 含み OPEN なし            → skip (Req 1.3)
#     CLOSED のみ                      → continue (Req 1.5 / Out of Scope と整合)
#     採用 PR 集合が空                 → continue (Req 1.5 / 通常運用)
#
# Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, NFR 1.5, NFR 2.1, NFR 2.2,
#               NFR 4.1, NFR 4.2
check_existing_impl_pr() {
  local issue_number="$1"

  # 入力検証: 空 / 非数値は呼び出し側のミス。fail-safe で skip + error ログ。
  if [[ ! "$issue_number" =~ ^[1-9][0-9]*$ ]]; then
    pclp_error "skip issue=#${issue_number:-<empty>} reason=invalid-issue-number"
    return 1
  fi

  # $REPO は "owner/repo" 形式（既存 watcher 全体の前提）。GraphQL の引数として分解する。
  local owner repo_name
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  if [ -z "$owner" ] || [ -z "$repo_name" ] || [ "$owner" = "$REPO" ]; then
    pclp_error "skip issue=#${issue_number} reason=invalid-repo-env repo=${REPO:-<empty>}"
    return 1
  fi

  # GraphQL クエリ: Issue 視点の `closedByPullRequestsReferences` で linked PR を取得。
  # （PullRequest 側 `closingIssuesReferences` の Issue 側 reciprocal field。
  # `Issue.closingIssuesReferences` は schema 上存在しないので使えない。）
  # `includeClosedPrs: true` を明示して CLOSED PR も含めて返させる（CLOSED のみなら
  # continue する判定ロジックを正しく機能させるため / Req 1.5）。
  # `first: 20` は idd-claude の typical（impl + impl-resume を数回繰り返しても数件レベル）
  # に対して十分なマージン。
  # shellcheck disable=SC2016  # `$owner` / `$repo` / `$number` は GraphQL 変数記法であり bash 展開ではない（`-F` で値を渡す）
  local query='query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
          nodes {
            number
            state
            headRefName
          }
        }
      }
    }
  }'

  # `gh api graphql` を timeout でラップ（既存 DRR / Phase A と同じ規律 / NFR 1.1 で
  # 新規 env var を導入しない）。stderr を捕捉してエラー本文をログに残せるようにする。
  local response gh_rc
  response=$(timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}" \
    gh api graphql \
      -f query="$query" \
      -F owner="$owner" \
      -F repo="$repo_name" \
      -F number="$issue_number" 2>&1) && gh_rc=0 || gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    # レート制限の場合は専用 reason で記録（NFR 4.2）。それ以外は generic な失敗として記録。
    if echo "$response" | grep -qiE 'rate.?limit|RATE_LIMITED|HTTP 429|too many requests'; then
      pclp_warn "skip issue=#${issue_number} reason=rate-limited rc=${gh_rc}"
    else
      pclp_warn "skip issue=#${issue_number} reason=graphql-failed rc=${gh_rc}"
    fi
    return 1
  fi

  # GraphQL は HTTP 200 でも errors を返すケースがあるため明示的に検査する。
  if echo "$response" | jq -e '.errors // empty | length > 0' >/dev/null 2>&1; then
    if echo "$response" | jq -e '.errors // [] | map(.type // "") | any(. == "RATE_LIMITED")' >/dev/null 2>&1; then
      pclp_warn "skip issue=#${issue_number} reason=rate-limited"
    else
      pclp_warn "skip issue=#${issue_number} reason=graphql-errors"
    fi
    return 1
  fi

  # nodes 取得（schema mismatch / null は防衛的に空配列扱い）。
  local nodes_json
  if ! nodes_json=$(echo "$response" | jq -c '.data.repository.issue.closedByPullRequestsReferences.nodes // []' 2>/dev/null); then
    pclp_warn "skip issue=#${issue_number} reason=jq-parse-error"
    return 1
  fi

  # impl PR と判別された PR の (number, state) ペアを抽出する。
  # head pattern マッチング:
  #   - `claude/issue-${N}-design-...`  → design として無視（warn）
  #   - その他すべて                     → impl として採用（safe-side / 未知 pattern も
  #                                       含めて skip 側に倒す）
  # 安全側に倒すことで未知の branch pattern が原因で既存 PR を壊すリスクを排除する。
  # 明示的な impl pattern マッチ判定はせず、design 以外を一括で impl 扱いにする。
  local design_pattern="^claude/issue-${issue_number}-design-"

  # nodes を 1 件ずつ評価して採用/不採用を確定する。
  # bash の連想配列で state ごとに「最初に見つけた PR 番号」を保持する。
  declare -A first_pr_by_state=()
  declare -A best_pr_by_state=()  # MERGED は最大番号 = 最新を採用
  local node total_nodes
  total_nodes=$(echo "$nodes_json" | jq 'length')
  if [ "$total_nodes" -eq 0 ]; then
    pclp_log "continue issue=#${issue_number} reason=no-linked-impl-pr"
    return 0
  fi

  local i=0
  while [ "$i" -lt "$total_nodes" ]; do
    node=$(echo "$nodes_json" | jq -c ".[$i]")
    local pr_num pr_state pr_head
    pr_num=$(echo "$node" | jq -r '.number // empty')
    pr_state=$(echo "$node" | jq -r '.state // empty')
    pr_head=$(echo "$node" | jq -r '.headRefName // empty')
    i=$((i+1))

    # 必須フィールド欠落は防衛的に skip（GraphQL schema は GA 済み API だが念のため）
    if [ -z "$pr_num" ] || [ -z "$pr_state" ]; then
      continue
    fi

    # impl/design 判別
    if [[ "$pr_head" =~ $design_pattern ]]; then
      # design PR が closedByPullRequestsReferences に含まれるのは設計上の異常
      # （PjM template は `Refs #N` を使うため）。warn だけ出して採用しない。
      pclp_warn "ignore issue=#${issue_number} pr=#${pr_num} head=${pr_head} reason=design-pr-in-closing-refs"
      continue
    fi

    # impl pattern に厳密マッチ または unknown pattern は impl として採用する（safe-side）
    # 採用された PR の state を集約する。OPEN は最初に見つけた番号を、MERGED は最大番号を、
    # CLOSED は最初に見つけた番号を採用する。
    case "$pr_state" in
      OPEN)
        if [ -z "${first_pr_by_state[OPEN]:-}" ]; then
          first_pr_by_state[OPEN]="$pr_num"
        fi
        ;;
      MERGED)
        if [ -z "${best_pr_by_state[MERGED]:-}" ] || [ "$pr_num" -gt "${best_pr_by_state[MERGED]}" ]; then
          best_pr_by_state[MERGED]="$pr_num"
        fi
        ;;
      CLOSED)
        if [ -z "${first_pr_by_state[CLOSED]:-}" ]; then
          first_pr_by_state[CLOSED]="$pr_num"
        fi
        ;;
      *)
        # 未知 state（GraphQL schema 拡張等）は防衛的に skip 側に倒す
        pclp_warn "skip issue=#${issue_number} pr=#${pr_num} reason=unknown-pr-state state=${pr_state}"
        return 1
        ;;
    esac
  done

  # state 集約結果から判定（OPEN > MERGED > CLOSED の包含関係 / Req 1.2 / 1.3 / 1.5）
  if [ -n "${first_pr_by_state[OPEN]:-}" ]; then
    pclp_log "skip issue=#${issue_number} pr=#${first_pr_by_state[OPEN]} state=OPEN reason=existing-impl-pr"
    return 1
  fi
  if [ -n "${best_pr_by_state[MERGED]:-}" ]; then
    pclp_log "skip issue=#${issue_number} pr=#${best_pr_by_state[MERGED]} state=MERGED reason=existing-impl-pr"
    return 1
  fi
  if [ -n "${first_pr_by_state[CLOSED]:-}" ]; then
    pclp_log "continue issue=#${issue_number} pr=#${first_pr_by_state[CLOSED]} reason=closed-only"
    return 0
  fi

  # 採用 PR 集合が空（すべての node が design として無視 / フィールド欠落 等）
  pclp_log "continue issue=#${issue_number} reason=no-linked-impl-pr"
  return 0
}

# ─── check_open_design_pr (Issue #191 / open design PR ガード) ───
#
# 与えられた Issue 番号に対応する head ブランチ `claude/issue-<N>-design-*` の
# **OPEN な PR** が存在するかを検出し、Dispatcher が当該 Issue を **claim する前**
# に skip すべきかを判定する。
#
# 事故起点の整理（Issue #191 / #180 / PR #184 で実観測）:
#   design フェーズの Issue が open な design PR を持っているのに保護ラベル
#   （`awaiting-design-review` / `blocked`）が外れると、watcher が当該 Issue を
#   再 pickup して design モードを再実行し、PjM が人間レビュー済みの design PR を
#   クローズして作り直す事故が起きる。既存の check_existing_impl_pr は
#   `closedByPullRequestsReferences`（impl PR 専用に集約される逆引き field）から
#   design PR を明示的に ignore する（reason=design-pr-in-closing-refs）ため、
#   open design PR の存在は再 dispatch を抑止しない。本関数はラベル保護とは独立した
#   「最後の砦」ガードとして機能する（二重防御 / Req 2）。
#
# 入力:  $1 = issue_number（数値）
# 出力:  exit code で判定結果を返す
#        - 0 = pickup 続行 OK（open design PR なし）
#        - 1 = skip すべき（open design PR が存在 / API 失敗 / レート制限 / timeout）
# 副作用:
#        - 判定結果を pclp_log / pclp_warn で 1 行ログ出力
#          （fixed key=value 形式: `issue=#N pr=#P reason=R` / Req 4.1 / 4.2）
#        - `gh pr list --state open` を `timeout "$DRR_GH_TIMEOUT"` で 1 回呼ぶ
#          （既定 60 秒 / 既存 DRR と同じ規律 / NFR 1.3）
#
# 検出方式（linked 非依存 / Req 1.4）:
#   既存 drr_find_merged_design_pr (#40 / #80) と同じく head ref で server-side
#   一次絞り込み → jq の strict prefix で同定。linked か否かに依存しないため、
#   PjM が `Refs #N`（auto-close キーワードではない）で design PR を作っていても
#   検出できる。GitHub の text search はトークン分解（"claude" / "issue" / "N" /
#   "design"）で他 Issue 用 design PR もヒットするため、server-side は候補取得
#   （noisy）に留め、最終一致は issue 番号 fix の strict prefix
#   `^claude/issue-<N>-design-` で行う（#19 が #191 を誤検出しない / Req 1.5）。
#
# Fail-safe（Req 3.1 / 3.2）: gh pr list 失敗 / timeout / レート制限 / jq parse 失敗は
#   **すべて skip 扱い**（exit 1）に倒す。検出系の不調を理由にレビュー済み design PR を
#   破壊するリスクを最小化するため。既存 check_existing_impl_pr の fail-safe 方針と整合。
#
# Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.2, 3.1, 3.2, 4.1, 4.2, NFR 1.1, NFR 1.3
check_open_design_pr() {
  local issue_number="$1"

  # 入力検証: 空 / 非数値は呼び出し側のミス。fail-safe で skip + error ログ。
  if [[ ! "$issue_number" =~ ^[1-9][0-9]*$ ]]; then
    pclp_error "skip issue=#${issue_number:-<empty>} reason=invalid-issue-number-design-guard"
    return 1
  fi

  # head pattern を server-side クエリで一次絞り込み（in:head + 規約 prefix）。
  # noisy な候補取得に留め、最終一致判定は後段の jq の strict prefix で行う。
  # 複数件マッチを許容するため limit=20（再 design 等で複数 open はまれだが念のため）。
  local prs_json gh_rc
  prs_json=$(timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}" \
    gh pr list \
      --repo "$REPO" \
      --state open \
      --search "is:pr is:open claude/issue-${issue_number}-design- in:head" \
      --json number,headRefName \
      --limit 20 2>&1) && gh_rc=0 || gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    # レート制限の場合は専用 reason で記録（Req 3.2）。それ以外は generic な失敗。
    if echo "$prs_json" | grep -qiE 'rate.?limit|RATE_LIMITED|HTTP 429|too many requests'; then
      pclp_warn "skip issue=#${issue_number} reason=design-pr-probe-rate-limited rc=${gh_rc}"
    else
      pclp_warn "skip issue=#${issue_number} reason=design-pr-probe-failed rc=${gh_rc}"
    fi
    return 1
  fi

  # Issue #191: head 名を issue 番号で strict 比較する（server-side の text search は
  # トークン分解で #19 用 PR が #191 検索にヒットしうるため）。head が
  # `claude/issue-${N}-design-<slug>` で **厳密に** 始まる open PR のみを同定する
  # （Req 1.5）。複数件マッチ時は PR 番号最大（= 最新と看做す）を採用。
  local strict_head_prefix="claude/issue-${issue_number}-design-"
  local open_pr_number
  if ! open_pr_number=$(echo "$prs_json" | jq -r \
      --arg prefix "$strict_head_prefix" \
      '[(. // [])[]
        | select((.headRefName // "") | startswith($prefix))
        | .number
      ] | sort | last // ""' 2>/dev/null); then
    # jq parse 失敗も fail-safe で skip 側に倒す（Req 3.1）。
    pclp_warn "skip issue=#${issue_number} reason=design-pr-probe-jq-parse-error"
    return 1
  fi

  if [ -n "$open_pr_number" ]; then
    # open design PR が存在 → claim せず当該サイクルを skip（Req 1.1 / 1.2 / 2.2）
    pclp_log "skip issue=#${issue_number} pr=#${open_pr_number} reason=open-design-pr-exists"
    return 1
  fi

  # open design PR なし → 後続処理へ進む（Req 1.3 / NFR 1.1）
  pclp_log "continue issue=#${issue_number} reason=no-open-design-pr"
  return 0
}

# ─── _parallel_validate_slots ───
#
# PARALLEL_SLOTS が正の整数として解釈できるかを検証する。
# - 0 / 負数 / 非数値 / 空文字 / 先頭ゼロ等の形式違反を拒否する
# - 不正なら ERROR ログを stderr に出力して return 1
# 戻り値: 0 = ok / 1 = invalid
#
# Req 1.3: 不正値時はサイクル中断（呼び出し元で exit 1）
# Req 6.5: timestamp 書式 [YYYY-MM-DD HH:MM:SS] を維持
_parallel_validate_slots() {
  if [[ ! "$PARALLEL_SLOTS" =~ ^[1-9][0-9]*$ ]]; then
    dispatcher_error "PARALLEL_SLOTS は正の整数を指定してください: '$PARALLEL_SLOTS'"
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Runner ───
#
# 1 Issue を 1 つの slot worktree で処理する Worker。Dispatcher から
# `( _slot_run_issue $n $issue_json ) &` の形でバックグラウンド fork される。
#
# 設計上の重要点:
#   - サブシェルで動くため、内部の `cd` / 環境変数変更は親に伝播しない（Req 3.5 を構造的に保証）
#   - 入口で _slot_acquire 済を前提（Dispatcher が取得済の lock fd を継承）
#   - claim（claude-picked-up ラベル付与）は Dispatcher 側で完了済（Req 2.2）
#   - 処理シーケンス:
#       1. slot 専用ログファイル open
#       2. _worktree_ensure → 失敗時 claude-failed 化 + return
#       3. cd "$WT"
#       4. _worktree_reset → 失敗時 claude-failed 化 + return
#       5. _hook_invoke → 失敗時 claude-failed 化 + return
#       6. 既存 Issue 処理ロジック（Triage → mode 判定 → claude 起動）を実行
#   - すべての claude-failed 化は既存 mark_issue_failed パスを再利用（新ラベル不可）
#
# Req 2.7, 3.4, 3.5, 3.6, 5.3, 5.6, 5.7, 6.1, 6.2, 6.5, 7.3, 7.4, NFR 2.1, 2.2, 3.1, 3.2

# slot worker 用ロガー（slot 番号 + Issue 番号を必ず prefix に含める、Req 6.1, NFR 3.1）。
# サブシェル内で IDD_SLOT_NUMBER / NUMBER を読み取って prefix を組み立てる。
slot_log() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: $*"
}
slot_warn() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: WARN: $*" >&2
}
slot_error() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: ERROR: $*" >&2
}

# claim 系ラベル（claude-claimed / claude-picked-up）を claude-failed に置き換える
# 共通フロー（Worktree / Hook / その他サブシェル内エラー用）。run_impl_pipeline 内の
# mark_issue_failed と同じ操作を slot worker 文脈で再現する（mark_issue_failed は
# MODE / LOG 等を要求するため代用しない）。
#
# Issue #52: 両系統除去で post-Triage / pre-Triage どちらの失敗にも対応する。
# - pre-Triage 失敗時点では Issue は claude-claimed のみ持つ
# - post-Triage（impl 着手後）失敗時点では Issue は claude-picked-up のみ持つ
# - design ルートで Stage C 失敗等の想定外シーケンスでも残置を防ぐため両方除去する
# gh CLI は未付与ラベルの除去を no-op として扱うため安全（既存 || true で吸収）。
#
# 引数: $1 = stage 識別子, $2 = Issue コメントに追加する補足
_slot_mark_failed() {
  local stage="$1"
  local extra="$2"
  # run サマリ: 最終遷移を claude-failed として記録（Req 7.1, 7.2）。worktree / Hook / Triage
  # 失敗等の早期終端からも呼ばれるが、_slot_run_issue 冒頭で rs_init 済（task 2 配線）。変数
  # 代入のみで既存ラベル遷移 / exit code / 既存ログ行に影響しない（NFR 1.1, 1.2 / set -e 安全）。
  rs_set_result claude-failed
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" >/dev/null 2>&1 || true
  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / slot=${IDD_SLOT_NUMBER:-?} / 失敗 stage: ${stage}）。"
  if [ -n "$extra" ]; then
    body="${body}

${extra}"
  fi
  if [ -n "${LOG:-}" ]; then
    body="${body}

ログ: \`$LOG\`"
  fi
  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # _slot_mark_failed は worktree / Hook / Triage 失敗等から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
}

# ─── impl-resume 保護ヘルパ群 (Issue #67) ───
#
# `IMPL_RESUME_PRESERVE_COMMITS=true` 配下で:
#   - `_resume_normalize_flag`            : env 値の strict 正規化（純粋関数）
#   - `_resume_detect_existing_branch`    : origin に branch があるかを ls-remote で判定
#   - `_resume_branch_init`               : impl-resume 用 branch 初期化の Strategy 分岐
#   - `_resume_push`                      : fast-forward 制約 push と non-ff 検出
#   - `_resume_mark_nonff_failed`         : non-ff 専用 claude-failed 遷移ヘルパ
#
# `_slot_mark_failed` / `slot_log` / `slot_warn` を再利用するため、それらの定義より
# 後ろ、`_slot_run_issue` より前に配置する（forward reference を避ける）。
# 設計詳細: docs/specs/67-feat-watcher-impl-resume-branch-commit-f/design.md

# env var の生値を厳密に "true" / "false" に正規化する純粋関数（副作用なし）。
# 引数:
#   $1 = mode（"preserve_default_off" | "tracking_default_on"）
#   $2 = 生 env 値（unset を許容 = 空文字として渡す）
# stdout: "true" または "false"
# 戻り値: 常に 0
#
# #67 当時は受理値を完全一致 "true" / "false" のみとし、それ以外（空 / "True" /
# "1" / "yes" 等の typo）を安全側に倒す設計:
#   - preserve_default_off: "true" 完全一致のみ true、それ以外は false
#   - tracking_default_on : "false" 完全一致のみ false、それ以外（空文字含む）は true
# #112 でデフォルトを反転し、Config ブロック上部の正規化ループで全 9 種を厳密 2 値
# （"true" / "false"）に整形した上で本関数に渡す。本関数の semantics 自体は変えない
# （pre-normalized "true" → "true", "false" → "false" のいずれもそのまま透過する
# 表になっており、後方互換性を維持する）。
_resume_normalize_flag() {
  local mode="$1"
  local raw="${2:-}"
  case "$mode" in
    preserve_default_off)
      if [ "$raw" = "true" ]; then
        echo "true"
      else
        echo "false"
      fi
      ;;
    tracking_default_on)
      if [ "$raw" = "false" ]; then
        echo "false"
      else
        echo "true"
      fi
      ;;
    *)
      # 不明な mode は安全側に倒して false を返す（呼び出し元の bug を表面化させる）
      echo "false"
      ;;
  esac
}

# 対象 branch が origin に存在するかを `git ls-remote --exit-code` で検出する。
# 引数: $1 = branch name（例: "claude/issue-67-impl-..."）
# 戻り値:
#   0 = origin に存在
#   1 = 不在 / 検出失敗（ネットワーク失敗・タイムアウトを含めて呼び出し元では同等扱い）
# 副作用: なし（git ls-remote は read-only）
#
# Req 2.1, 2.2: PR の有無とは独立に branch 存在の真実値を取得する。`gh pr list` には
# 依存しない（設計論点 1: PR が close 済 / 未作成のケースで false negative を避ける）。
# 失敗時は安全側に倒して fresh-init 経路に倒す（NFR 2.1: WARN ログ）。
# timeout 30 秒は既存 MERGE_QUEUE_GIT_TIMEOUT より短め。watcher 全体の cron 周期
# （最短 2 分）を圧迫しないため。
_resume_detect_existing_branch() {
  local branch="$1"
  if [ -z "$branch" ]; then
    return 1
  fi
  # `git ls-remote --exit-code` は ref 不在で exit code 2 を返す。timeout は 30 秒。
  # ネットワーク失敗等の予期せぬ exit code はすべて「不在」として fail-safe。
  if timeout 30 git ls-remote --exit-code --heads origin "refs/heads/$branch" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# `impl-resume` モードの branch 初期化を `IMPL_RESUME_PRESERVE_COMMITS` flag によって
# 2 戦略のいずれかにディスパッチする。既存の `git checkout -B "$BRANCH" "origin/$BASE_BRANCH"`
# + `git push -u origin "$BRANCH" --force-with-lease` シーケンスを内包する。
#
# 入力（環境変数経由）:
#   BRANCH                          : claude/issue-N-impl-<slug> 形式
#   IMPL_RESUME_PRESERVE_COMMITS    : "true" / "false"（#112 以降デフォルト "true"。
#                                     Config ブロック冒頭で厳密 2 値に正規化済み）
#   MODE                            : "impl-resume" 前提（呼び出し元で gate 済み）
# 戻り値:
#   0 = init 成功（HEAD = $BRANCH、push 済み）
#   非 0 = 失敗（呼び出し元で _slot_mark_failed 既に発射済み）
# 副作用:
#   - git checkout -B（local branch 作成）
#   - git push -u origin（fast-forward または force-with-lease。flag 値で分岐）
#   - SLOT_LOG / 標準出力にイベントログ追記
#   - 失敗時は _slot_mark_failed が gh issue edit + comment を発射
#   - 呼び出し後 RESUME_PRESERVE 変数を export（後段 prompt builder が参照）
#
# Req 1.1, 1.2, 2.1, 2.2, 2.3, 2.5, 4.4, NFR 1.3, NFR 2.1 (#67)
# Req 1.8, 2.8, 3.4, 5.3, 5.4 (#112)
#
# 戦略:
#   PRESERVE=true（既定）+ branch 存在 → checkout -B BRANCH origin/BRANCH + fast-forward push
#   PRESERVE=true（既定）+ branch 不在 → checkout -B BRANCH origin/$BASE_BRANCH + fast-forward push
#   PRESERVE=false（明示 opt-out） → 本機能導入前と等価: checkout -B BRANCH origin/$BASE_BRANCH + force-with-lease push
#
# 注意: opt-in パスの fast-forward push と non-ff 検出ロジックは
# `_resume_push` / `_resume_mark_nonff_failed` 関数に切り出されている。
_resume_branch_init() {
  local preserve
  preserve=$(_resume_normalize_flag preserve_default_off "${IMPL_RESUME_PRESERVE_COMMITS:-}")
  export RESUME_PRESERVE="$preserve"

  if [ "$preserve" != "true" ]; then
    # ── 明示 opt-out パス (IMPL_RESUME_PRESERVE_COMMITS=false): 本機能導入前と等価 ──
    # worktree は detached HEAD で起動するため -B で新規 branch 作成
    # （local $BASE_BRANCH を持たない）
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    if ! git push -u origin "$BRANCH" --force-with-lease; then
      slot_warn "branch push に失敗: $BRANCH"
      _slot_mark_failed "branch-push" "ブランチ \`$BRANCH\` の push に失敗しました。"
      return 1
    fi
    slot_log "resume-mode=legacy-force-push branch=$BRANCH"
    return 0
  fi

  # ── デフォルト保護パス (#112 以降の既定): PRESERVE=true ──
  # origin に branch が存在するか判定。存在すればそこから resume、不在なら
  # origin/$BASE_BRANCH 起点。
  local origin_sha=""
  if _resume_detect_existing_branch "$BRANCH"; then
    if ! git checkout -B "$BRANCH" "origin/$BRANCH"; then
      slot_warn "既存 branch resume に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "既存 origin branch \`$BRANCH\` からの resume に失敗しました。"
      return 1
    fi
    origin_sha=$(git rev-parse --short=7 "origin/$BRANCH" 2>/dev/null || echo "unknown")
    slot_log "resume-mode=existing-branch branch=$BRANCH origin_sha=$origin_sha"
  else
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    slot_log "resume-mode=fresh-from-base branch=$BRANCH base=$BASE_BRANCH"
  fi

  # デフォルト保護パスの push は fast-forward 制約付き（_resume_push に委譲）。
  # _resume_push が non-ff を検出した場合は内部で claude-failed 付与済み。
  if ! _resume_push "$BRANCH"; then
    return 1
  fi
  return 0
}

# fast-forward 制約付き push を実行し、stderr から非 fast-forward 検出時は
# 専用 stage `branch-nonff` で claude-failed に遷移する。
# 引数: $1 = branch
# 戻り値:
#   0 = push 成功
#   1 = non-ff reject または push 失敗（claude-failed 付与済み）
# 副作用:
#   - git push -u origin <branch>（force 系オプションを一切付けない）
#   - non-ff 検出時 / 失敗時は _slot_mark_failed が gh issue edit + comment 発射
#
# Req 4.1, 4.2, 4.5: 失敗してもリトライしない / reset / rebase / merge を行わない。
# stderr 解析で "non-fast-forward" / "rejected.*non-fast" / "Updates were rejected"
# パターンを ERE で判定。non-ff 以外の push 失敗（ネットワーク等）は既存 branch-push
# 失敗パスに合流させる。
#
# 注意: non-ff 専用 Issue コメント本文の組み立ては task 3.2 で `_resume_mark_nonff_failed`
# として切り出し予定。本 commit では inline body で _slot_mark_failed "branch-nonff" を呼ぶ。
_resume_push() {
  local branch="$1"
  local stderr_tmp
  stderr_tmp=$(mktemp -t resume-push-XXXXXX.err 2>/dev/null || echo "")

  local rc=0
  if [ -n "$stderr_tmp" ]; then
    git push -u origin "$branch" 2>"$stderr_tmp" || rc=$?
  else
    # mktemp 失敗時のフォールバック（stderr 捕捉できないが push は試みる）
    git push -u origin "$branch" || rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    if [ -n "$stderr_tmp" ]; then
      rm -f "$stderr_tmp" 2>/dev/null || true
    fi
    return 0
  fi

  # 失敗。stderr の内容で non-ff か否かを判別
  local stderr_content=""
  if [ -n "$stderr_tmp" ] && [ -f "$stderr_tmp" ]; then
    stderr_content=$(cat "$stderr_tmp" 2>/dev/null || true)
  fi

  local stderr_tail=""
  if [ -n "$stderr_content" ]; then
    # コメント本文に過剰な行を入れないよう末尾 1500 文字程度に制限
    stderr_tail=$(echo "$stderr_content" | tail -c 1500)
  fi

  # POSIX ERE で non-fast-forward / rejected パターンを検出
  if echo "$stderr_content" | grep -Eq '(non-fast-forward|rejected.*non-fast|Updates were rejected because the (tip|remote))'; then
    slot_warn "non-ff push detected; aborting (branch=$branch)"
    slot_log "resume-failure=non-ff issue=#${NUMBER:-?} branch=$branch"
    _resume_mark_nonff_failed "$branch" "$stderr_tail"
  else
    # non-ff 以外の push 失敗（ネットワーク等）。既存 branch-push 失敗パスに合流。
    slot_warn "push に失敗（non-ff ではない）: $branch"
    slot_log "resume-failure=push-error issue=#${NUMBER:-?} branch=$branch"
    local body="ブランチ \`$branch\` の push に失敗しました（fast-forward 制約付き push）。"
    if [ -n "$stderr_tail" ]; then
      body="$body

\`\`\`
$stderr_tail
\`\`\`"
    fi
    _slot_mark_failed "branch-push" "$body"
  fi

  if [ -n "$stderr_tmp" ]; then
    rm -f "$stderr_tmp" 2>/dev/null || true
  fi
  return 1
}

# non-ff 専用の `claude-failed` 遷移ヘルパ。
# 既存 `_slot_mark_failed` の薄い wrapper として、Issue コメントに「force-push 抑制で
# 停止した」旨と人間操作手順を記載する。
# 引数:
#   $1 = branch
#   $2 = stderr の tail（任意。診断情報として Issue コメントに含める）
# 戻り値: 常に 0
#
# Req 4.2, 4.3, NFR 2.2: 運用者がログ単独で原因と Issue 番号を特定できる粒度で記録。
# 既存 stage 識別子セット（branch-checkout / branch-push 等）に branch-nonff を追加。
_resume_mark_nonff_failed() {
  local branch="$1"
  local stderr_tail="${2:-}"
  local body="自動 force-push を抑制したため停止しました（impl-resume 保護機能）。

- 対象 branch: \`$branch\`
- 対象 Issue : #${NUMBER:-?}
- 検出理由 : non-fast-forward push（既存 origin branch に対し remote がローカル HEAD の祖先ではない）

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 branch の差分を確認
2. 必要なら手動で merge / rebase / cherry-pick で衝突解消
3. 解消できたら本 Issue から \`claude-failed\` ラベルを除去すると次サイクルで再 pickup されます

> 注意: 本機能は \`IMPL_RESUME_PRESERVE_COMMITS=true\` でのみ動作します。
> 強制 fresh が必要なら \`IMPL_RESUME_PRESERVE_COMMITS=false\` に戻すか、
> \`git push origin :$branch\` で origin branch を削除してから再 pickup してください。"

  if [ -n "$stderr_tail" ]; then
    body="$body

### git stderr (tail)

\`\`\`
$stderr_tail
\`\`\`"
  fi

  _slot_mark_failed "branch-nonff" "$body"
  return 0
}

# ─── スラグ正規化と Stage Checkpoint Resume スラグ照合ガード (Issue #114) ───
#
# fork / mirror clone で Issue 番号が衝突したとき、無関係な過去 Issue の
# `docs/specs/<N>-*/` や `claude/issue-<N>-impl-*` ブランチを誤って resume しないよう、
# Issue タイトル由来の expected-slug と既存成果物の found-slug を照合する。
#
# 共通関数:
#   - `_normalize_slug`                       : Issue タイトル → 正規化済みスラグ（Req 5.1, 5.2）
#   - `_stage_checkpoint_assert_slug_match`   : spec dir 検出時のスラグ照合（Req 1, 3）
#   - `_resume_branch_assert_slug_match`      : origin impl ブランチ resume 時の照合（Req 2, 3）
#
# いずれも mismatch 検出時は `claude-claimed` を取り除き `needs-decisions` を付与し、
# Issue コメントを 1 件投稿してから非 0 を返す（呼び出し元は skip して次 Issue へ進む）。

# Issue タイトルを「lowercase 化 / `a-z0-9` 以外をハイフン 1 個へ縮約 /
# 先頭 40 文字へ切り詰め / 末尾ハイフン除去」の順で正規化する純粋関数（Req 5.1）。
# 引数: $1 = タイトル（または任意の文字列）
# stdout: 正規化済みスラグ。空入力なら空文字。
# 戻り値: 常に 0
#
# 既存 spec dir 不在パスでの SLUG 導出と同じ規則を共通化する（Req 5.2, 5.3）。
# 既存挙動と等価: `echo "$TITLE" | tr '[:upper:]' '[:lower:]' \
#                  | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//'`
_normalize_slug() {
  local raw="${1:-}"
  if [ -z "$raw" ]; then
    echo ""
    return 0
  fi
  local res
  res=$(echo "$raw" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//')
  if [ -z "$res" ]; then
    echo "issue"
  else
    echo "$res"
  fi
}

# スラグ不一致を検出したとき、`claude-claimed` を除去して `needs-decisions` を付与し、
# Issue コメントを 1 件投稿する共通エスカレーション。Req 3.1, 3.2, 3.3, 3.4。
# 引数:
#   $1 = 種別ラベル（"spec-dir" | "resume-branch"）
#   $2 = expected-slug
#   $3 = found-slug
#   $4 = 検出された対象（spec dir path or branch name）
# 戻り値: 常に 0
# 副作用:
#   - gh issue edit / gh issue comment（失敗時は || true で吸収。skip 経路を阻まない）
#   - slot_log にイベント記録
_slug_mismatch_escalate() {
  local kind="$1"
  local expected="$2"
  local found="$3"
  local target="$4"

  local body
  body="🛑 自動処理を中止しました（スラグ照合不一致）。

- 種別: ${kind}
- 対象 Issue: #${NUMBER:-?}
- expected-slug（Issue タイトル由来）: \`${expected}\`
- found-slug（既存成果物由来）: \`${found}\`
- 検出対象: \`${target}\`

fork / mirror clone 由来の Issue 番号衝突により、無関係な過去 Issue の
\`docs/specs/<N>-*/\` または \`claude/issue-<N>-impl-*\` ブランチを誤って resume
する事故を避けるため、当該 Issue の Stage Checkpoint Resume を中止しました。

### 次の手順

1. 検出対象 \`${target}\` が本 Issue (#${NUMBER:-?}) の成果物か確認してください
2. 無関係なら退避（rename / 削除）、対象なら手動で命名を揃えてください
3. 確認後、本 Issue から \`needs-decisions\` ラベルを外してください（次サイクルで再 pickup）"

  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" \
    --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  slot_log "slug-mismatch escalated: kind=$kind issue=#${NUMBER:-?} expected=$expected found=$found target=$target"
  return 0
}

# `docs/specs/<N>-*/` 検出時のスラグ照合（Req 1.2, 1.3, 1.4, 1.5）。
# 引数:
#   $1 = expected_slug（_normalize_slug の結果）
#   $2 = 検出された spec dir のパス（basename を見て slug を抽出）
# 戻り値:
#   0 = match（呼び出し元は従来どおり resume を継続）
#   1 = mismatch（呼び出し元はその Issue を skip する。escalate 済）
# 副作用:
#   - LOG に `stage-checkpoint: slug-match|slug-mismatch ...` を 1 行記録（Req 4.1, 4.2, NFR 3.1, 3.2）
#   - mismatch 時は `_slug_mismatch_escalate` が gh issue edit + comment を発射
_stage_checkpoint_assert_slug_match() {
  local expected="$1"
  local spec_dir="$2"
  local base found
  base=$(basename "$spec_dir")
  # `<N>-` プレフィックスを剥がして found-slug を取り出す。NUMBER が空のときは
  # NFR 2.1（異常系の安全側挙動）に従い mismatch 扱いに倒す。
  if [ -z "${NUMBER:-}" ]; then
    found=""
  else
    found="${base#"${NUMBER}-"}"
    # `<N>-` で始まらなかった場合は basename 全体を found とみなす（防御的）
    if [ "$found" = "$base" ]; then
      found=""
    fi
  fi

  if [ -n "$expected" ] && [ "$expected" = "$found" ]; then
    echo "stage-checkpoint: slug-match issue=#${NUMBER:-?} expected=${expected} found=${found}" | tee -a "$LOG"
    return 0
  fi

  echo "stage-checkpoint: slug-mismatch issue=#${NUMBER:-?} expected=${expected} found=${found}" | tee -a "$LOG"
  _slug_mismatch_escalate "spec-dir" "$expected" "$found" "$spec_dir"
  return 1
}

# spec-dir 経路の slug guard を発火させる前に「resumable state が実在するか」を判定する
# read-only ヘルパ（Issue #383 Req 1, 3）。Issue #114 が守る fork/mirror 番号衝突誤 resume
# 防止は resumable state が実在する Issue では従来どおり発火し、resumable state が一切
# 不在の fresh issue については slug guard を skip して Stage A を新規実装として継続させる。
#
# resumable state の定義（Req 3.1, OR 条件 / 4 観点いずれか 1 つでも真なら実在）:
#   (a) `stage_checkpoint_find_impl_pr` が OPEN または MERGED 状態の impl PR を 1 件以上検出
#   (b) origin 上に `refs/heads/claude/issue-<N>-impl-*` 形式の branch が 1 本以上存在
#   (c) 検出対象 spec dir 配下で `impl-notes.md` が branch HEAD 上で tracked
#   (d) 検出対象 spec dir 配下で `review-notes.md` が branch HEAD 上で tracked
#
# 引数:
#   $1 = 検出対象の spec dir 絶対パス（`$WT/docs/specs/<N>-<slug>` 形式）
# 戻り値:
#   0 = resumable state 実在（呼び出し元は従来どおり slug guard を発火）
#   1 = resumable state 不在（呼び出し元は slug guard を skip して Stage A 継続）
#   2 = 判定失敗（gh API エラー・git エラー等。NFR 2.1 の safe-side により呼び出し元は
#       0 と同等に扱い slug guard を発火させる）
# 副作用:
#   - LOG に `stage-checkpoint:` prefix で 1 行の判定結果ログを出力（Req 4.1, 4.3）
#   - 検出失敗時は `stage-checkpoint: WARN` 形式で観測失敗の事実を 1 行出力（Req 4.3）
#
# `BRANCH` 変数はこの時点では未確定なので、(b) の branch 判定は
# `_resume_branch_assert_slug_match` と同様に slug 不問の prefix マッチ
# （`refs/heads/claude/issue-<N>-impl-*`）で行う（確認事項参照）。
_stage_checkpoint_has_resumable_state() {
  local spec_dir="$1"
  local issue_num="${NUMBER:-}"

  # 入力検証: Issue 番号が numeric でない場合は判定不能 → safe-side（実在扱い）
  case "$issue_num" in
    ''|*[!0-9]*)
      echo "stage-checkpoint: WARN resumable-state-detection issue=#${issue_num:-?} reason=invalid-issue-number" >&2
      return 2
      ;;
  esac

  local detection_failed="false"

  # (a) 既存 impl PR を gh から観測。stage_checkpoint_find_impl_pr の戻り値:
  #     0 = OPEN/MERGED の impl PR あり / 1 = なし / 2 = gh API エラー
  local pr_info pr_rc=0
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) || pr_rc=$?
  case "$pr_rc" in
    0)
      echo "stage-checkpoint: resumable-state-found issue=#${issue_num} observation=impl-pr detail=${pr_info}" | tee -a "$LOG"
      return 0
      ;;
    1)
      : # 不在。後続観点へ
      ;;
    *)
      echo "stage-checkpoint: WARN resumable-state-detection issue=#${issue_num} observation=impl-pr reason=gh-api-failure rc=${pr_rc}" >&2
      detection_failed="true"
      ;;
  esac

  # (b) origin 上に `claude/issue-<N>-impl-*` ブランチが 1 本でも存在するか。
  # `_resume_branch_assert_slug_match` と同じ prefix マッチを使う（slug 不問）。
  local prefix="claude/issue-${issue_num}-impl-"
  local remote_refs ls_rc=0
  remote_refs=$(timeout 30 git ls-remote --heads origin -- "refs/heads/${prefix}*" 2>/dev/null) || ls_rc=$?
  if [ "$ls_rc" -eq 0 ]; then
    if [ -n "$remote_refs" ]; then
      echo "stage-checkpoint: resumable-state-found issue=#${issue_num} observation=impl-branch detail=${prefix}*" | tee -a "$LOG"
      return 0
    fi
  else
    echo "stage-checkpoint: WARN resumable-state-detection issue=#${issue_num} observation=impl-branch reason=ls-remote-failure rc=${ls_rc}" >&2
    detection_failed="true"
  fi

  # (c) / (d) 検出対象 spec dir 配下の impl-notes.md / review-notes.md を branch HEAD 上で
  # tracked 判定する。worktree の HEAD は base ブランチ（spec-dir 検出時点）なので、
  # umbrella spec が main に merge 済みでも impl-notes.md / review-notes.md は通常
  # impl PR ブランチ側にのみ存在するため、ここで tracked = resumable state ありとみなす。
  #
  # REPO_DIR は worktree path に上書き済（呼び出し元 _slot_run_issue が REPO_DIR=$WT に
  # 設定する）ため、`git -C "$REPO_DIR"` と spec_dir は同一 worktree を指す。
  local rel
  rel="docs/specs/$(basename "$spec_dir")"

  local impl_tracked review_tracked
  if impl_tracked=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel/impl-notes.md" 2>/dev/null); then
    if [ -n "$impl_tracked" ]; then
      echo "stage-checkpoint: resumable-state-found issue=#${issue_num} observation=impl-notes detail=${rel}/impl-notes.md" | tee -a "$LOG"
      return 0
    fi
  else
    echo "stage-checkpoint: WARN resumable-state-detection issue=#${issue_num} observation=impl-notes reason=git-ls-tree-failure" >&2
    detection_failed="true"
  fi

  if review_tracked=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel/review-notes.md" 2>/dev/null); then
    if [ -n "$review_tracked" ]; then
      echo "stage-checkpoint: resumable-state-found issue=#${issue_num} observation=review-notes detail=${rel}/review-notes.md" | tee -a "$LOG"
      return 0
    fi
  else
    echo "stage-checkpoint: WARN resumable-state-detection issue=#${issue_num} observation=review-notes reason=git-ls-tree-failure" >&2
    detection_failed="true"
  fi

  # 全 4 観点で「不在」または「観測失敗」。安全側挙動として、観測失敗が 1 件でも
  # あれば 2（実在不明）を返し、呼び出し元は slug guard 発火経路に倒す（NFR 2.1）。
  if [ "$detection_failed" = "true" ]; then
    return 2
  fi

  # 全 4 観点が確定的に「不在」だった場合のみ slug guard を skip する。
  return 1
}

# origin の `claude/issue-<N>-impl-*` ブランチを resume 候補として検出した際に
# 行うスラグ照合（Req 2.1, 2.2, 2.3）。origin の全 impl-* ブランチを ls-remote で
# 列挙し、expected-slug と一致するブランチが 1 つでも見つかれば match、見つからず
# かつ何らかの impl-* ブランチが存在すれば mismatch として escalate する。
# 引数:
#   $1 = expected_slug
# 戻り値:
#   0 = match もしくは候補ブランチ自体が origin に存在しない（resume 対象外）
#   1 = mismatch（呼び出し元は impl-resume を中止して非 0 を返す）
# 副作用:
#   - LOG に `resume-branch: slug-match|slug-mismatch ...` を 1 行記録（Req 4.3）
#   - mismatch 時は `_slug_mismatch_escalate` が gh issue edit + comment を発射
#
# 失敗時の安全側挙動（NFR 2.1）: ls-remote 自体が失敗（ネットワーク不調・タイムアウト）
# したときは「候補なし」として呼び出し元へ 0 を返す。後続の `_resume_detect_existing_branch`
# も同様にネットワーク失敗を不在扱いするため整合する。
_resume_branch_assert_slug_match() {
  local expected="$1"
  if [ -z "${NUMBER:-}" ]; then
    # NFR 2.1: 異常系。expected が決まらない場合は match 扱いで呼び出し元へ委ねる
    return 0
  fi

  local prefix="claude/issue-${NUMBER}-impl-"
  local remote_refs
  if ! remote_refs=$(timeout 30 git ls-remote --heads origin "refs/heads/${prefix}*" 2>/dev/null); then
    # ネットワーク失敗等は不在扱い（既存 _resume_detect_existing_branch と同じ姿勢）
    return 0
  fi
  if [ -z "$remote_refs" ]; then
    return 0
  fi

  local found_slug match_found="false"
  local first_found=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # 形式: "<sha>\trefs/heads/claude/issue-<N>-impl-<slug>"
    local ref="${line##*$'\t'}"
    local branch="${ref#refs/heads/}"
    found_slug="${branch#"${prefix}"}"
    if [ -z "$first_found" ]; then
      first_found="$found_slug"
    fi
    if [ "$found_slug" = "$expected" ]; then
      match_found="true"
      break
    fi
  done <<< "$remote_refs"

  if [ "$match_found" = "true" ]; then
    echo "resume-branch: slug-match issue=#${NUMBER:-?} expected=${expected} found=${expected}" | tee -a "$LOG"
    return 0
  fi

  echo "resume-branch: slug-mismatch issue=#${NUMBER:-?} expected=${expected} found=${first_found}" | tee -a "$LOG"
  _slug_mismatch_escalate "resume-branch" "$expected" "$first_found" "${prefix}${first_found}"
  return 1
}

# ─── Dependency Resolver (Issue #146) ───
# PM phase（Triage 起動前）に Issue 本文の前提依存記法
# （canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:`）を機械抽出し、
# 各依存先 Issue の merge 状態を GitHub から確認して、未解決依存が 1 件でも残れば
# `blocked` ラベルを付与 + エスカレーションコメント 1 件投稿 + claim 系ラベル除去で
# 人間判断へ委ねるためのゲート関数群。
#
# 既存 `_slug_mismatch_escalate` / `mq_log` / `pi_log` 等と同書式のロガーを採用し、
# 構造化ログ prefix `dr:` で grep 集計できるようにする（Req 6.1〜6.3 / NFR 2.1〜2.2）。
# helper スクリプト化はせず watcher 単体で完結させる（install.sh の配布対象拡張を
# 避けるため）。
#
# Issue #392 (Req 1.1, 1.2 / NFR 3.1): `dr_log` / `dr_warn` は stderr に書き出す。
# 理由: `dr_resolve_one` は stdout を「機械可読な戻り値」（`resolved` / `open` /
# `closed unmerged` / `api error` のいずれか厳密 1 行）に予約しており、その実装中で
# `dr_log` を呼ぶ経路（OPEN + `staged-for-release` 解決パス）が存在する。`dr_log`
# が stdout に echo すると、`dr_unblock_resolve_one_issue` 側の
# `verdict=$(dr_resolve_one ...)` で **ログ行と戻り値の両方** が `$verdict` に
# 連結捕捉され、未知の verdict と判定されて `BASE_BRANCH != main` 環境の
# `DEP_AUTO_UNBLOCK` が完全停止する事象が実機再現した（#117 / #115）。`dr_warn` は
# 既に `>&2` だったが、本意は「stdout 汚染ゼロ」なので `dr_log` も `>&2` に揃える。
# cron 経由（`>>cron.log 2>&1`）では stderr も cron.log へ集約されるため、既存
# 集計 grep（`grep ' dr:'` / `grep 'verdict='` 等）は本修正で破壊しない（NFR 3.1）。
# `dr_error` は本修正前から `>&2`（Req 4.3）。
dr_log() {
  echo "[$(date '+%F %T')] dr: $*" >&2
}
dr_warn() {
  echo "[$(date '+%F %T')] dr: WARN: $*" >&2
}
dr_error() {
  echo "[$(date '+%F %T')] dr: ERROR: $*" >&2
}

# 引数 = Issue 本文（多行 string、改行入り）。
# stdout = 重複排除済の Issue 番号集合（改行区切り、各行は数字のみ）。
# 空入力・記法非存在では空 stdout を返す（return 0）。
# 副作用なし（純粋関数）。
#
# 検出する記法（`.claude/rules/issue-dependency.md` と整合 / Req 4.1, 4.4）:
#   - canonical: `Depends on: #N` （行頭の `- ` などの list prefix を許容）
#   - alias 日本語: `前提依存: #N`
#   - alias 英語慣習: `Blocked by: #N`
#
# 1 行に複数の Issue 番号がスペース区切り / カンマ区切りで列挙される場合も対応する
# （Req 4.4）。`grep -oE '#[0-9]+'` で行内の番号を全列挙し、`sort -u -n` で uniq 化
# （Req 4.4）。
#
# 誤検出防止（Req 4.2, 4.3 / #204）: markdown コードフェンス（``` または ~~~ で
# 開閉されるブロック）内および引用ブロック（行頭が任意個の空白に続く `>` で始まる行）
# 内の依存マーカーは実依存として抽出しない。例示目的でコード例・引用に依存記法を
# 書いた Issue が誤って false-block されるのを防ぐ。これらの行は markdown 前処理
# （awk）で除去してからマーカーマッチを行う。
dr_extract_deps() {
  local body="$1"

  # ── markdown 前処理: コードフェンス内・引用ブロック行を除去（Req 4.2, 4.3）──
  # awk でフェンス開閉をトグル管理し、フェンス内行と引用行（行頭空白 + `>`）を捨てる。
  # フェンスマーカーは行頭（任意個の空白を許容）の ``` または ~~~ で開始する行。
  # 言語タグ（```bash 等）や閉じフェンスも同じ判定で扱う（開→閉のトグル）。
  local filtered
  filtered=$(printf '%s\n' "$body" | awk '
    {
      line = $0
      # 行頭の空白を除いた先頭部分を取り出してフェンス / 引用を判定する。
      stripped = line
      sub(/^[ \t]+/, "", stripped)
      # コードフェンス開閉トグル（``` または ~~~ で始まる行）。
      if (stripped ~ /^(```|~~~)/) {
        in_fence = !in_fence
        next            # フェンスマーカー行自体も依存抽出の対象外
      }
      if (in_fence) {
        next            # フェンス内の本文行は除外（Req 4.2）
      }
      if (stripped ~ /^>/) {
        next            # 引用ブロック行は除外（Req 4.3）
      }
      print line
    }
  ')

  # 行抽出: canonical + alias の 3 パターン。
  # `-E` で ERE、`-i` は使わず大文字小文字を厳密にし誤検出を減らす（既存運用で
  # `Depends on:` / `Blocked by:` は大文字始まり前提）。`前提依存:` は UTF-8
  # バイト列として直接マッチ（grep -E で安全）。
  local matched_lines
  matched_lines=$(printf '%s\n' "$filtered" \
    | grep -E '(Depends on:|前提依存:|Blocked by:)' || true)

  if [ -z "$matched_lines" ]; then
    return 0
  fi

  # 行ごとに `#[0-9]+` を全列挙し、`#` を剥がして数字のみにし uniq 化。
  # `sort -u -n` で数値昇順 + uniq（出力決定性を確保 / Req 4.4）。
  printf '%s\n' "$matched_lines" \
    | grep -oE '#[0-9]+' \
    | sed -E 's/^#//' \
    | sort -u -n
}

# 引数 $1 = 未解決依存リスト（"#N|区分" の改行区切り、各行は `#N|<区分>` 形式）。
# stdout = 依存未解決専用 markdown 本文（多行）。
# 副作用なし（純粋関数）。
#
# design.md「Escalation Comment Template」と一致する文面を生成し、
# `needs-decisions` テンプレートと混在しない依存未解決専用語彙を使う（Req 3.2,
# 3.6, 8.4, 9.2）。
dr_format_unresolved_comment() {
  local unresolved="$1"

  # 未解決依存リストを markdown 箇条書きに整形（"#N|区分" → "- #N (区分)"）。
  local items
  items=$(printf '%s\n' "$unresolved" \
    | awk -F'|' 'NF==2 && $1 != "" {printf "- %s (%s)\n", $1, $2}')

  # #346: gate ON 時は「次回 tick で自動で外れます」相当の文面に分岐する（Req 8.1）。
  # gate OFF（既定 / 不正値含む）では従来文面（「手動で除去」案内）を維持する（Req 8.2）。
  local next_steps
  if dr_unblock_gate_enabled; then
    next_steps=$(cat <<'EOF_DR_NEXT_AUTO'
1. 上記依存 Issue の解消（merge / staged-for-release 付与など）を進めてください
2. すべて解決されると、次回 cron tick で本 Issue の `blocked` ラベルは **自動で外れます**（手動除去は不要 / DEP_AUTO_UNBLOCK_ENABLED=true）
3. 自動解除と同時に解除コメントが投稿され、通常の Triage / 実装フローに合流します
EOF_DR_NEXT_AUTO
)
  else
    next_steps=$(cat <<'EOF_DR_NEXT_MANUAL'
1. 上記依存 Issue の解消（merge）を進めてください
2. すべて merge 済みになったら、本 Issue から `blocked` ラベルを手動で除去してください
3. 次回 cron tick (`watcher 起動` 後) で依存チェックが再実行され、解消済みなら通常の Triage / 実装フローに合流します
EOF_DR_NEXT_MANUAL
)
  fi

  cat <<EOF_DR_COMMENT
🛑 依存 Issue 未 merge のため自動処理を中止しました。

### 未解決依存

${items}

### 次の手順

${next_steps}

### \`blocked\` と \`needs-decisions\` の使い分け

本ラベルは **依存 Issue 未 merge 専用** です。それ以外の人間判断要求（Triage の判断不能 /
スラグ衝突等）は従来通り \`needs-decisions\` が付与されます。両ラベルは独立した状態遷移を
持ちます（[README.md ラベル状態遷移まとめ](https://github.com/${REPO}#ラベル状態遷移まとめ) 参照）。
EOF_DR_COMMENT
}

# 引数:
#   $1 = owner（$REPO の owner 部）
#   $2 = repo 名（$REPO の repo 部）
#   $3 = 依存 Issue 番号（数字のみ）
# stdout = `gh api graphql` の生レスポンス（JSON 文字列）。失敗時は stderr 本文。
# return = gh api graphql の exit code をそのまま返す。
# 副作用 = なし（呼び出し元がエラーログを担当）。
#
# 本ラッパは dr_resolve_one から `gh api graphql` 呼び出しを切り出したもので、
# 回帰テストが GraphQL レスポンスを mock 注入できるよう薄い indirection を提供する
# （実 API を叩かずに dr_resolve_one の判定ロジックを検証するため / Req 5.x）。
# timeout は既存の DRR_GH_TIMEOUT（新規 env var を導入しない / Req 3.5, NFR 3.1）。
dr_gh_graphql_closed_by() {
  local owner="$1"
  local repo_name="$2"
  local dep_num="$3"

  # GraphQL クエリ: Issue 視点の `closedByPullRequestsReferences` で linked PR の
  # state を取得する（PR ノードに `state` フィールドは存在するが、`gh issue view
  # --json closedByPullRequestsReferences` の REST 経路では `merged` フィールドが
  # 返らないため誤判定していた / 本 bug の根因）。
  # `includeClosedPrs: true` で CLOSED/MERGED の PR も含めて返させる。
  # `first: 20` は check_existing_impl_pr と同じく十分なマージン。
  #
  # #316: 依存ゲートの base 相対化（staged-for-release 解決判定）のため、同一
  # クエリで Issue の labels も取得する。`labels(first: 20)` は Issue 1 件に付く
  # ラベル数として十分なマージン（実運用では 10 件未満が大半）。state + labels を
  # 1 回の問い合わせで取得することで API 呼び出し回数を本変更前と同数に保つ
  # （NFR 2.1）。
  # shellcheck disable=SC2016  # `$owner` / `$repo` / `$number` は GraphQL 変数記法であり bash 展開ではない（`-F` で値を渡す）
  local query='query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        state
        labels(first: 20) {
          nodes {
            name
          }
        }
        closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
          nodes {
            number
            state
          }
        }
      }
    }
  }'

  timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}" \
    gh api graphql \
      -f query="$query" \
      -F owner="$owner" \
      -F repo="$repo_name" \
      -F number="$dep_num" 2>&1
}

# 引数 $1 = 依存 Issue 番号（数字のみ）。
# stdout = 区分文字列 1 行: "resolved" | "open" | "closed unmerged" | "api error"。
# return = 常に 0（判定結果は stdout で返す）。
# 副作用 = API エラー / jq parse 失敗時のみ dr_warn でログ（Req 6.2）。
#
# `dr_gh_graphql_closed_by` で Issue の state / labels /
# `closedByPullRequestsReferences.nodes[].state` を取得し、以下を判定:
#   - issue.state == "OPEN" かつ BASE_BRANCH != main かつ labels に
#     `staged-for-release` を含む → "resolved"（#316 / Req 1.1 / NFR 3.1）
#   - issue.state == "OPEN"（上記以外）→ "open"（unresolved / Req 1.4 / 旧 2.3 /
#     #316 Req 1.2, 1.3 で BASE_BRANCH=main の従来挙動を維持）
#   - issue.state == "CLOSED" かつ PR ノードの state に "MERGED" が 1 件以上
#     → "resolved"（Req 1.1 / #316 Req 1.4 で従来挙動を維持）
#   - issue.state == "CLOSED" かつ "MERGED" が 0 件（空配列・全 CLOSED 含む）
#     → "closed unmerged"（Req 1.2, 1.3 / #316 Req 1.5 で従来挙動を維持）
#   - gh / jq 失敗 / GraphQL errors / 未知の state → "api error"
#     （Req 2.1, 2.2 / NFR 4.2 安全側 / #316 Req 2.2, 2.3）
#
# 旧実装は `gh issue view --json closedByPullRequestsReferences` の PR ノードに
# 存在しない `.merged` フィールドを参照していたため、merge 済み依存も常に
# `closed unmerged` と誤判定していた（#204 の根因 / Req 1.5）。
#
# #316: BASE_BRANCH != main（gitflow 等の multi-branch 運用 / develop dispatch）
# の場合、依存先が OPEN かつ `staged-for-release` ラベルを持つ状態は「develop
# には統合済みで main 到達待ち」を意味するため、当該依存を resolved として
# 扱う（base 相対化）。BASE_BRANCH=main の従来挙動は変更しない。labels 取得・
# parse に失敗した場合は安全側に倒し `staged-for-release` 付与を仮定しない
# （`api error` = 未解決 / #316 Req 2.3）。base 相対化の閾値は #221
# （promote-pipeline.sh `po_resolve_holder_labels`）の dispatch×multi-branch
# 判定（BASE_BRANCH != PROMOTION_TARGET_BRANCH）と整合させる発想だが、本関数の
# 文脈は dispatch 確定後の Triage 段階であり依存ゲートに promote コンテキストは
# 存在しないため、判定基準は単純な `BASE_BRANCH != main` で十分（Issue 本文の
# 仕様および requirements.md Req 1.1）。
#
# timeout は DRR_GH_TIMEOUT に従う（個別の新規 env var は導入しない / Req 3.5 /
# #316 NFR 1.2）。
dr_resolve_one() {
  local dep_num="$1"

  # $REPO は "owner/repo" 形式（既存 watcher 全体の前提）。GraphQL 引数に分解する。
  local owner repo_name
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  if [ -z "$owner" ] || [ -z "$repo_name" ] || [ "$owner" = "$REPO" ]; then
    dr_warn "issue=#${dep_num} REPO env が owner/repo 形式でない: ${REPO:-<empty>}"
    echo "api error"
    return 0
  fi

  local response gh_rc
  response=$(dr_gh_graphql_closed_by "$owner" "$repo_name" "$dep_num") && gh_rc=0 || gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    dr_warn "issue=#${dep_num} gh api graphql 失敗 (rc=${gh_rc}): ${response}"
    echo "api error"
    return 0
  fi

  # GraphQL は HTTP 200 でも errors を返すケースがあるため明示的に検査する（Req 2.1）。
  if printf '%s' "$response" | jq -e '.errors // empty | length > 0' >/dev/null 2>&1; then
    dr_warn "issue=#${dep_num} GraphQL errors を検出"
    echo "api error"
    return 0
  fi

  local state
  if ! state=$(printf '%s' "$response" \
        | jq -r '.data.repository.issue.state' 2>/dev/null); then
    dr_warn "issue=#${dep_num} jq parse 失敗（issue.state 取り出し）"
    echo "api error"
    return 0
  fi
  # state が null（issue ノードが取れていない等の想定外応答）→ 安全側で api error
  # （Req 2.2: 想定外構造で merge 状態を解釈できない場合）。
  if [ -z "$state" ] || [ "$state" = "null" ]; then
    dr_warn "issue=#${dep_num} issue.state が取得できない応答構造（state=${state:-<empty>}）"
    echo "api error"
    return 0
  fi

  case "$state" in
    OPEN)
      # #316: base 相対化（staged-for-release 依存の解決判定）。
      # BASE_BRANCH=main の場合は従来挙動を維持し、ラベルを参照せず unresolved
      # （Req 1.2 / NFR 1.1 後方互換）。BASE_BRANCH != main の場合のみ labels を
      # 読み出し、`staged-for-release` 付与時に resolved として返す（Req 1.1）。
      if [ "${BASE_BRANCH:-main}" = "main" ]; then
        echo "open"
        return 0
      fi
      # labels 一覧を取り出して `staged-for-release` の有無を判定。jq parse 失敗時は
      # 安全側に倒し api error（ラベル付与を仮定して resolved として扱う処理は行わ
      # ない / Req 2.3）。
      local has_staged_label
      if ! has_staged_label=$(printf '%s' "$response" \
            | jq -r --arg target "${LABEL_STAGED_FOR_RELEASE:-staged-for-release}" \
                '[.data.repository.issue.labels.nodes[]? | select(.name == $target)] | length > 0' \
            2>/dev/null); then
        dr_warn "issue=#${dep_num} jq parse 失敗（labels 取り出し）"
        echo "api error"
        return 0
      fi
      # 想定外応答（labels ノードが取れない等）で true/false 以外が返った場合も
      # 安全側で api error（Req 2.2, 2.3）。
      case "$has_staged_label" in
        true)
          dr_log "issue=#${dep_num} verdict=resolved reason=staged-for-release base=${BASE_BRANCH:-main}"
          echo "resolved"
          return 0
          ;;
        false)
          echo "open"
          return 0
          ;;
        *)
          dr_warn "issue=#${dep_num} labels 集計結果が想定外: ${has_staged_label}"
          echo "api error"
          return 0
          ;;
      esac
      ;;
    CLOSED)
      # closedByPullRequestsReferences.nodes[].state に "MERGED" が 1 件以上あれば
      # resolved。空配列 or 全て MERGED 以外（CLOSED 等）は closed unmerged
      # （Req 1.1, 1.2, 1.3）。
      local merged_count
      if ! merged_count=$(printf '%s' "$response" \
            | jq '[.data.repository.issue.closedByPullRequestsReferences.nodes[]? | select(.state == "MERGED")] | length' \
            2>/dev/null); then
        dr_warn "issue=#${dep_num} jq parse 失敗（closedByPullRequestsReferences 集計）"
        echo "api error"
        return 0
      fi
      # 想定外応答で集計結果が数値でない場合も安全側で api error（Req 2.2）。
      if ! [[ "$merged_count" =~ ^[0-9]+$ ]]; then
        dr_warn "issue=#${dep_num} closedByPullRequestsReferences 集計結果が数値でない: ${merged_count}"
        echo "api error"
        return 0
      fi
      if [ "$merged_count" -gt 0 ]; then
        echo "resolved"
      else
        echo "closed unmerged"
      fi
      return 0
      ;;
    *)
      # 未知の state（GitHub API 仕様変更 / 異常応答）→ 安全側で api error 扱い
      dr_warn "issue=#${dep_num} 未知の state: ${state}"
      echo "api error"
      return 0
      ;;
  esac
}

# 引数:
#   $1 = 対象 Issue 番号（数字のみ）
#   $2 = 未解決依存リスト（"#N|区分" 改行区切り、dr_format_unresolved_comment 用）
# 戻り値:
#   0 = ラベル付与 + コメント投稿が成功
#   1 = いずれかが失敗（呼び出し元は当該 Issue を skip して slot を return 0 する）
# 副作用:
#   - `blocked` ラベル付与 + `claude-claimed` 除去を単一 PATCH で原子的に発行
#   - エスカレーションコメント 1 件投稿（重複投稿は caller の冪等性ガードで防ぐ）
#
# `needs-decisions` ラベルには触れない（Req 9.1）。
# 既存 `_slug_mismatch_escalate` と同パターンで gh 副作用エラーは `dr_warn` で
# ログ + 非 0 return を返し、caller は安全側で slot を return 0 する。
dr_apply_block() {
  local issue_num="$1"
  local unresolved="$2"

  local body
  body=$(dr_format_unresolved_comment "$unresolved")

  # ラベル付け替えとコメント投稿を発射。失敗は dr_warn で記録、いずれかが
  # 失敗した場合は呼び出し元（dr_check_dependencies）に非 0 を返す。
  local label_rc=0 comment_rc=0
  if ! gh issue edit "$issue_num" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_BLOCKED" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} gh issue edit (blocked ラベル付与 / claim 除去) に失敗"
    label_rc=1
  fi
  if ! gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} エスカレーションコメント投稿に失敗"
    comment_rc=1
  fi

  if [ "$label_rc" -ne 0 ] || [ "$comment_rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# 引数:
#   $1 = 対象 Issue 番号
#   $2 = Issue 本文（多行 string）
#   $3 = 既存ラベル名一覧（改行区切り、`_slot_run_issue` の $LABELS と同じ形式）
# 戻り値:
#   0 = block しない（Triage 続行可 / 検出ゼロ or 全件 resolved）
#   1 = block 確定（caller は Triage skip して slot を return 0 する）
# 副作用:
#   - `dr_log` で構造化ログ 1 行を必ず出力（Req 6.1 / NFR 2.1）
#   - ブロック確定時のみ `dr_apply_block` を呼んで blocked 付与 + コメント投稿
#
# 冪等性ガード（Req 3.4 / NFR 3.1）: 入力 LABELS に `blocked` を含む場合は何もせず
# return 1 を返す（caller は skip、ラベル再付与・コメント再投稿なし）。N 回連続実行
# されてもラベル付与数 1 / コメント投稿数 1 に収束する。
#
# 検出ゼロ時の挙動（Req 1.6 / 5.1〜5.3 / NFR 1.1）: gh API 呼び出しゼロ・ラベル
# 変更ゼロ・コメント投稿ゼロで `verdict=skip_no_deps` の構造化ログ 1 行のみ出力。
# 本機能導入前と完全に同一の pickup 挙動を維持。
dr_check_dependencies() {
  local issue_num="$1"
  local body="$2"
  local labels="$3"

  # 冪等性ガード: 既に blocked が付与されている → 再付与せず caller 側 skip
  # （Req 3.4）。LABELS は改行区切りなので `grep -qx` で完全一致判定。
  if printf '%s\n' "$labels" | grep -qx "$LABEL_BLOCKED"; then
    dr_log "issue=#${issue_num} verdict=blocked (既に blocked 付与済 / 冪等 skip)"
    return 1
  fi

  # 依存抽出（gh 呼ばず、純粋関数）
  local extracted
  extracted=$(dr_extract_deps "$body")
  if [ -z "$extracted" ]; then
    # 検出ゼロ → 副作用ゼロで Triage 続行（Req 1.6 / 5.1〜5.3 / NFR 1.1）
    dr_log "issue=#${issue_num} extracted= verdict=skip_no_deps"
    return 0
  fi

  # 抽出件数分の依存先 Issue を解決。1 件以上 unresolved / api_error があれば
  # ブロック確定（Req 2.6）。
  local extracted_csv resolved_csv unresolved_csv api_errors_csv unresolved_lines
  extracted_csv=""
  resolved_csv=""
  unresolved_csv=""
  api_errors_csv=""
  unresolved_lines=""
  local dep verdict_for_dep
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    extracted_csv="${extracted_csv:+${extracted_csv},}#${dep}"
    verdict_for_dep=$(dr_resolve_one "$dep")
    case "$verdict_for_dep" in
      resolved)
        resolved_csv="${resolved_csv:+${resolved_csv},}#${dep}"
        ;;
      open)
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (open)"
        unresolved_lines="${unresolved_lines}#${dep}|open"$'\n'
        ;;
      "closed unmerged")
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (closed_unmerged)"
        unresolved_lines="${unresolved_lines}#${dep}|closed unmerged"$'\n'
        ;;
      "api error")
        api_errors_csv="${api_errors_csv:+${api_errors_csv},}#${dep}"
        unresolved_lines="${unresolved_lines}#${dep}|api error"$'\n'
        ;;
      *)
        # 想定外（dr_resolve_one が新区分を返した）→ 安全側で unresolved 扱い
        dr_warn "issue=#${issue_num} dep=#${dep} 未知の verdict: ${verdict_for_dep}"
        api_errors_csv="${api_errors_csv:+${api_errors_csv},}#${dep}"
        unresolved_lines="${unresolved_lines}#${dep}|api error"$'\n'
        ;;
    esac
  done <<< "$extracted"

  if [ -n "$unresolved_lines" ]; then
    # ブロック確定 → blocked 付与 + コメント投稿（Req 3.1〜3.3, 3.5, 9.1）
    dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved=${unresolved_csv} api_errors=${api_errors_csv} verdict=blocked"
    if ! dr_apply_block "$issue_num" "${unresolved_lines%$'\n'}"; then
      dr_warn "issue=#${issue_num} dr_apply_block 失敗 / caller は skip（NFR 4.2 安全側）"
    fi
    return 1
  fi

  # 全件 resolved → Triage 続行
  dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved= api_errors= verdict=all_resolved"
  return 0
}

# ─── Dependency Auto-Unblock Sweep (Issue #346) ───
# 依存全解決時に `blocked` ラベルを自動解除するスイープ関数群。`_dispatcher_run` の
# 候補クエリより前段で 1 度起動し、auto-dev AND blocked AND OPEN な Issue 集合を列挙して
# 以下のいずれかに分岐する:
#   (1) 全依存 resolved → `blocked` 除去 + 自動解除コメント投稿（Req 3.1, 3.2）
#   (2) 1 件以上 unresolved → 何もしない（Req 4.1, 6.2）
#   (3) 依存マーカー消失（dr_extract_deps が空）→ 通知コメント 1 回のみ投稿（Req 5.1, 5.2）
# 起動 gate: `DEP_AUTO_UNBLOCK_ENABLED=true` 厳密一致のみ ON。それ以外は OFF
# （Req 1.2, 1.3, NFR 1.1）。OFF 時は冒頭 1 行 if で即 return し gh API 呼び出しゼロ。
#
# 既存 `dr_*` 関数（`dr_extract_deps` / `dr_resolve_one` / `dr_apply_block` /
# `dr_check_dependencies`）の signature・戻り値契約は変更しない（NFR 1.2）。

# Issue #346 通知マーカー文字列。
# - DR_UNBLOCK_MARKER_CLEARED: 自動解除コメントに埋め込む監査識別子（NFR 4.2）
# - DR_UNBLOCK_MARKER_ORPHAN : 空依存通知コメントの冪等性判定キー（Req 5.4）
# どちらも HTML コメント形式で GitHub UI 上は不可視。grep / jq から検出可能。
# shellcheck disable=SC2034  # 抽出した個別関数の遅延束縛 / 既存 dr_* と同パターン
DR_UNBLOCK_MARKER_CLEARED='<!-- idd-claude:dep-unblock-cleared:v1 -->'
# shellcheck disable=SC2034  # 同上
DR_UNBLOCK_MARKER_ORPHAN='<!-- idd-claude:dep-unblock-orphan-marker:v1 -->'

# 引数: なし
# 戻り値: 0 = gate ON / 1 = gate OFF（既定 / 不正値 / typo）
# 副作用: なし（純粋関数）
#
# `DEP_AUTO_UNBLOCK_ENABLED` を `=true` 厳密一致で判定する（Req 1.2, 1.3）。
# 値正規化に失敗した状態（未設定 / 空 / `False` / `True` / `1` / `on` / typo）は
# すべて OFF として扱う（NFR 1.1 安全側）。本関数は `dr_unblock_sweep` の起動 gate
# 兼、`dr_format_unresolved_comment` の文面分岐スイッチを兼ねる（Req 8.1, 8.2）。
dr_unblock_gate_enabled() {
  case "${DEP_AUTO_UNBLOCK_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# Issue #348 / #375: `full_auto_enabled()` の定義は Config ブロック直後（line 133 付近）に
# 移動済み。bash の top-level 実行順序上、関数定義は最初の呼び出し（process_auto_merge /
# process_auto_merge_design 等）より前に置く必要があるため、本箇所には残さない。

# ─── publish_claude_review_status <round> ─────────────────────────────────────
#
# Claude Reviewer ステージ完了直後（review-notes.md commit / push 済み）に呼ばれ、
# 当該 PR の head sha に対して `claude-review` 安定 context 名で commit status を
# publish する。Issue #349 Req 3.x / Req 4.x / Req 7.x / NFR 1.x。
#
# 入力: $1 = round（観測ログ用。1 / 2 / 3 のいずれか）
# 戻り値: 0 = 成功 or gate OFF（no-op）/ 1 = best-effort 失敗（呼び出し側はパイプライン
#         継続 / Req 5.3）
# 副作用: gh api -X POST /repos/.../statuses/<sha>（gate ON 時のみ）。 + LOG
#
# 入口で `pr_status_check_enabled` を呼んで AND 二重 opt-in を確認するため、gate OFF
# 状態（既定）では外部副作用ゼロで return する（NFR 1.1）。
#
# 設計判断:
#   - PR 番号と head sha は `gh pr list --head "$BRANCH" --state all` で 1 回引く
#     （review-notes.md commit / push 後の最新 head が返る）。`gh pr view` の `--head`
#     非対応事情は既存 `pp_resolve_pr_head_sha` 等と同方針（既存コメント参照）。
#   - `parse_review_result` で result を抽出。rc=0（approve / reject）以外（rc=2 装飾起因
#     parse 失敗 / rc=3 ファイル不在）は **publish しない**（AC 3.5 / Req 5.x）。
#   - target_url は review-notes.md の GitHub blob URL（HEAD sha 指定）に倒す。
#     blob URL が組み立てられない場合は PR の HTML URL に fallback（AC 3.4）。
#   - gate OFF / parse 失敗 / publish 失敗いずれもパイプラインを止めない（Req 5.3）。
publish_claude_review_status() {
  local round="${1:-?}"
  # AND 二重 opt-in 早期判定（gh / git 呼び出しを skip するため）
  if ! pr_status_check_enabled; then
    # pr_publish_commit_status と整合する suppression ログを cycle あたり 1 行に制限。
    # FULL_AUTO_ENABLED OFF 起因は #348 既存ログに委ね、本関数では本 gate OFF のみ記録。
    if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ] \
        && [ "${PR_STATUS_GATE_SUPPRESS_LOGGED:-0}" != "1" ]; then
      pr_log "claude-review status publish suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED gate (round=${round} no-op)"
      PR_STATUS_GATE_SUPPRESS_LOGGED=1
    fi
    return 0
  fi

  local notes_path="${REPO_DIR}/${SPEC_DIR_REL}/review-notes.md"
  if [ ! -f "$notes_path" ]; then
    pr_warn "claude-review status publish: review-notes.md not found at '${notes_path}' (round=${round} issue=#${NUMBER:-?})"
    return 1
  fi

  # AC 3.5: parse 失敗時は publish せず WARN
  local parsed parse_rc=0
  parsed=$(parse_review_result "$notes_path") || parse_rc=$?
  if [ "$parse_rc" -ne 0 ] || [ -z "$parsed" ]; then
    pr_warn "claude-review status publish: parse_review_result 失敗 rc=${parse_rc} (round=${round} issue=#${NUMBER:-?})"
    return 1
  fi
  local result
  result=$(echo "$parsed" | cut -f1)
  case "$result" in
    approve|reject) ;;
    *)
      pr_warn "claude-review status publish: 不正な RESULT '${result}' (round=${round} issue=#${NUMBER:-?})"
      return 1
      ;;
  esac

  # PR 番号 / head sha を取得（BRANCH 経由）
  local pr_json pr_number sha pr_url
  if ! pr_json=$(timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr list --repo "$REPO" --head "$BRANCH" --state all \
        --json number,headRefOid,url --limit 1 2>/dev/null); then
    pr_warn "claude-review status publish: gh pr list 失敗 (branch=${BRANCH} issue=#${NUMBER:-?})"
    return 1
  fi
  pr_number=$(echo "$pr_json" | jq -r '.[0].number // empty' 2>/dev/null || echo "")
  sha=$(echo "$pr_json" | jq -r '.[0].headRefOid // empty' 2>/dev/null || echo "")
  pr_url=$(echo "$pr_json" | jq -r '.[0].url // empty' 2>/dev/null || echo "")

  if [ -z "$pr_number" ] || [ -z "$sha" ]; then
    pr_warn "claude-review status publish: PR not found for branch=${BRANCH} (issue=#${NUMBER:-?})"
    return 1
  fi

  # AC 3.4: target_url は review-notes.md の blob URL（HEAD sha 指定）に倒す。
  # blob URL は `https://github.com/<owner>/<repo>/blob/<sha>/<path>` 形式。
  local target_url=""
  if [ -n "$sha" ] && [ -n "$SPEC_DIR_REL" ]; then
    target_url="https://github.com/${REPO}/blob/${sha}/${SPEC_DIR_REL}/review-notes.md"
  elif [ -n "$pr_url" ]; then
    target_url="$pr_url"
  fi

  # publish
  local pub_rc=0
  pr_publish_claude_status "$pr_number" "$sha" "$result" "$target_url" || pub_rc=$?
  if [ "$pub_rc" -ne 0 ] && [ "$pub_rc" -ne 1 ]; then
    # rc=1 は gate OFF（既に上で弾いているはずだが念のため）。それ以外は WARN を残す。
    pr_warn "claude-review status publish: pr_publish_claude_status rc=${pub_rc} (round=${round} pr=#${pr_number} sha=${sha} issue=#${NUMBER:-?})"
    return 1
  fi
  return 0
}

# 引数 $1 = 対象 Issue 番号（数字のみ）
# stdout = なし（戻り値で表現）
# 戻り値:
#   0 = 既存コメント中に空依存通知マーカーが見つかった（投稿済 / Req 5.3）
#   1 = マーカー未投稿 or gh 取得失敗（NFR 3.1 安全側で「未投稿扱い」にすると重複投稿の
#       恐れがあるため、本実装では gh 取得失敗時は「投稿済 = 1」を返して再投稿を抑止する）
# 副作用: なし（read-only API のみ）
#
# `gh issue view --json comments` で対象 Issue のコメント本文を一括取得し、in-bash で
# マーカー文字列（`<!-- idd-claude:dep-unblock-orphan-marker:v1 -->`）を grep する。
# 過去コメントに 1 件でも該当があれば「投稿済」として `dr_unblock_sweep` から再投稿
# しないようにする（Req 5.3, 6.1, NFR 5.1 冪等性）。
dr_unblock_has_orphan_marker() {
  local issue_num="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_num" --repo "$REPO" \
        --json comments 2>/dev/null); then
    # 取得失敗 → 安全側で「投稿済扱い」にして再投稿しない（NFR 5.1）
    dr_warn "issue=#${issue_num} gh issue view --json comments 失敗（orphan marker 検出 skip / 投稿済扱い）"
    return 0
  fi
  if printf '%s' "$comments_json" \
      | jq -r '.comments[]?.body // ""' 2>/dev/null \
      | grep -qF -- "$DR_UNBLOCK_MARKER_ORPHAN"; then
    return 0
  fi
  return 1
}

# 引数:
#   $1 = 対象 Issue 番号
# 副作用:
#   - 自動解除コメント 1 件を投稿（マーカー識別子を含む / NFR 4.2）
# 戻り値:
#   0 = 投稿成功 / 1 = 投稿失敗（dr_warn は呼び出し元で出す方針）
#
# 本コメントは「watcher が依存全解決を検出し `blocked` を外した」旨を GitHub UI
# 履歴から読み取れる文面とマーカーを含む（Req 3.3, NFR 4.2）。
dr_unblock_post_unblocked_comment() {
  local issue_num="$1"
  local body
  body=$(cat <<EOF_DR_UNBLOCK_CLEARED
✅ 依存 Issue がすべて解決したため、\`blocked\` ラベルを自動解除しました。

依存解決時の自動スイープ（\`DEP_AUTO_UNBLOCK_ENABLED=true\`）が、本 Issue 本文の
依存記法（\`Depends on:\` / \`前提依存:\` / \`Blocked by:\`）から抽出した依存先を
すべて \`resolved\`（merge 済み / 又は \`staged-for-release\` 付与など base 相対）と
判定したため、本ラベルを自動で除去しました。次回 cron tick で通常の Triage / 実装
フローに合流します。

判定経緯は watcher の構造化ログ（\`dr: issue=#${issue_num} verdict=unblock_cleared\`）
から追跡できます。

${DR_UNBLOCK_MARKER_CLEARED}
EOF_DR_UNBLOCK_CLEARED
)
  gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1
}

# 引数:
#   $1 = 対象 Issue 番号
# 副作用:
#   - 空依存通知コメント 1 件を投稿（マーカー識別子を含む / Req 5.4）
# 戻り値:
#   0 = 投稿成功 / 1 = 投稿失敗
#
# 「依存マーカーが本文から消失したため自動解除されない」旨を通知し、人間が依存記法
# の誤削除に気づけるようにする（Req 5.2）。ラベルは維持され、人間判断で本ラベルを
# 手動除去するか、依存記法を本文に書き直す運用フローに委ねる。
dr_unblock_post_orphan_marker_comment() {
  local issue_num="$1"
  local body
  body=$(cat <<EOF_DR_UNBLOCK_ORPHAN
⚠️ 依存記法が本文から消失していますが、\`blocked\` ラベルは自動解除しませんでした。

本 Issue には \`blocked\` ラベルが付いていますが、現在の Issue 本文から依存記法
（\`Depends on:\` / \`前提依存:\` / \`Blocked by:\`）が検出できませんでした。
編集ミス・意図せぬ削除を疑い、安全側で自動解除を見送ります（\`DEP_AUTO_UNBLOCK_ENABLED=true\`）。

### 次の手順

- 依存先がまだ未解決なら、Issue 本文に \`Depends on: #N\` 形式で依存記法を**再記述**してください
- 既に依存が解決済 / 依存記法を撤回したい場合は、本 Issue から \`blocked\` ラベルを**手動除去**してください

本通知は重複投稿を避けるため 1 度だけ投稿されます（マーカー検出による冪等性）。

${DR_UNBLOCK_MARKER_ORPHAN}
EOF_DR_UNBLOCK_ORPHAN
)
  gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1
}

# 引数:
#   $1 = 対象 Issue 番号
#   $2 = Issue 本文（多行 string）
# 戻り値:
#   0 = 処理完了（解除 / 通知 / 維持いずれも 0）
#   非 0 は呼び出し元では使わない（fail-open）
# 副作用:
#   - 全依存 resolved → `gh issue edit --remove-label blocked` + 自動解除コメント投稿
#   - 空依存マーカー + 未通知 → 通知コメント投稿
#   - 1 件以上 unresolved → 何もしない
#   - 各分岐で `dr_log` 構造化ログ 1 行（Req 7.1〜7.3）
#
# 既存 `dr_extract_deps` / `dr_resolve_one` を流用するため、依存解析ロジックの
# 重複実装を避ける（NFR 1.2）。`gh issue edit` 失敗時は解除コメント未投稿で次へ
# 進み（NFR 3.2 / Req 3.4）、ラベル除去成功 + コメント投稿失敗時は警告ログ 1 行
# 残して次へ進む（既存 `dr_apply_block` の寛容方針と整合）。
dr_unblock_resolve_one_issue() {
  local issue_num="$1"
  local body="$2"

  # 依存抽出（純粋関数、gh 呼ばず）
  local extracted
  extracted=$(dr_extract_deps "$body")

  if [ -z "$extracted" ]; then
    # 空依存マーカー → 既通知判定 → 未通知ならコメント 1 件投稿（Req 5.1, 5.2, 5.3）
    if dr_unblock_has_orphan_marker "$issue_num"; then
      dr_log "issue=#${issue_num} verdict=unblock_orphan_notified (既通知 / 冪等 skip)"
      return 0
    fi
    if ! dr_unblock_post_orphan_marker_comment "$issue_num"; then
      dr_warn "issue=#${issue_num} 空依存通知コメント投稿に失敗"
      return 0
    fi
    dr_log "issue=#${issue_num} verdict=unblock_orphan_marker"
    return 0
  fi

  # 依存解決判定: 1 件でも unresolved があれば維持（Req 4.1, 4.2）
  local extracted_csv resolved_csv unresolved_csv
  extracted_csv=""
  resolved_csv=""
  unresolved_csv=""
  local dep verdict_for_dep
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    extracted_csv="${extracted_csv:+${extracted_csv},}#${dep}"
    verdict_for_dep=$(dr_resolve_one "$dep")
    case "$verdict_for_dep" in
      resolved)
        resolved_csv="${resolved_csv:+${resolved_csv},}#${dep}"
        ;;
      open|"closed unmerged"|"api error")
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (${verdict_for_dep})"
        ;;
      *)
        # 想定外 verdict は安全側で unresolved 扱い（Req 4.2）
        dr_warn "issue=#${issue_num} dep=#${dep} 未知の verdict: ${verdict_for_dep} (unresolved 扱い)"
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (unknown)"
        ;;
    esac
  done <<< "$extracted"

  if [ -n "$unresolved_csv" ]; then
    # 1 件以上 unresolved → 維持（Req 4.1, 4.3, 6.2）
    dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved=${unresolved_csv} verdict=unblock_keep"
    return 0
  fi

  # 全依存 resolved → blocked 除去 + 自動解除コメント投稿（Req 3.1, 3.2）
  if ! gh issue edit "$issue_num" --repo "$REPO" \
        --remove-label "$LABEL_BLOCKED" >/dev/null 2>&1; then
    # ラベル除去失敗 → コメント投稿せず skip（Req 3.4 / NFR 3.2 中途半端な状態を残さない）
    dr_warn "issue=#${issue_num} gh issue edit --remove-label ${LABEL_BLOCKED} 失敗 / コメント投稿せず skip"
    return 0
  fi
  if ! dr_unblock_post_unblocked_comment "$issue_num"; then
    # ラベル除去成功 + コメント投稿失敗 → 警告ログ 1 行 + 次 Issue へ
    # （既存 dr_apply_block と同じ寛容方針 / NFR 3.2）
    dr_warn "issue=#${issue_num} 自動解除コメント投稿に失敗（ラベルは除去済）"
  fi
  dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved= verdict=unblock_cleared"
  return 0
}

# 引数: なし
# 戻り値: 常に 0（個別 Issue の成否は内部ログで表現 / NFR 3.2 fail-open）
# 副作用:
#   - `DEP_AUTO_UNBLOCK_ENABLED=true` 時のみ `gh issue list` で対象 Issue を列挙し
#     `dr_unblock_resolve_one_issue` を順次適用
#   - OFF 時は gh API 呼び出しゼロで即 return（NFR 1.1, 2.1）
#
# `_dispatcher_run` のメイン候補クエリより前段で 1 度だけ呼ばれる前提（Req 2.3）。
# 解除された Issue は本 tick の `_dispatcher_run` 候補列挙（`-label:"$LABEL_BLOCKED"`
# 除外）で通常 pickup に合流できる（同 tick fall-through 動線。Req 2.3 を満たす）。
dr_unblock_sweep() {
  # Issue #348: full-auto kill switch（AND 二重 opt-in / Req 2.5）。
  # 個別 gate `DEP_AUTO_UNBLOCK_ENABLED` より先に kill switch を評価し、
  # OFF なら外部副作用ゼロで早期 return + 抑止原因を 1 行ログ出力する（Req 4.1）。
  # 既存個別 gate の挙動と独立に評価することで、運用者は kill switch 1 つで
  # 全 full-auto 系 processor を即時 no-op に倒せる（Req 2.5 / NFR 1.1）。
  if ! full_auto_enabled; then
    dr_log "dr_unblock_sweep: suppressed by FULL_AUTO_ENABLED kill switch (no-op)"
    return 0
  fi
  # 起動 gate（Req 1.1, 1.2, NFR 1.1, NFR 2.1）。OFF なら gh API ゼロ呼び出しで return。
  if ! dr_unblock_gate_enabled; then
    return 0
  fi

  # 対象 Issue 列挙: auto-dev AND blocked AND OPEN（Req 2.1）。
  # 終端ラベル（claude-failed / needs-decisions）が付いた Issue は sweep の対象から
  # 明示除外する（Req 2.2）。`mark_issue_failed` は claude-failed 付与時に auto-dev
  # ラベルを除去しないため、`auto-dev` + `blocked` + `claude-failed` の 3 ラベル組合せが
  # 実運用で発生し得る。AND クエリだけでは終端 Issue が pickup されるので、
  # `_dispatcher_run` のメイン候補クエリ（search_filter）と整合する `-label:"..."`
  # 除外を `--search` に追加する。
  # FIFO 順（Issue 番号昇順）を取りやすくするため `sort:created-asc` を採用。
  local issues_json
  if ! issues_json=$(gh issue list \
        --repo "$REPO" \
        --label "$LABEL_TRIGGER" \
        --label "$LABEL_BLOCKED" \
        --state open \
        --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" sort:created-asc" \
        --json number,body \
        --limit 50 2>/dev/null); then
    dr_warn "dr_unblock_sweep: gh issue list 失敗 / スイープ skip"
    return 0
  fi

  local count
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  if [ -z "$count" ] || [ "$count" = "0" ]; then
    # 対象ゼロ → 追加 API 呼び出しゼロで return（NFR 2.1）
    return 0
  fi

  dr_log "dr_unblock_sweep 起動 対象=${count} 件 gate=on"

  # Issue #368 / D-16: Dependency Cycle Detection をスイープ本処理の前段で 1 回実行。
  # auto-unblock と同じ取得済み $issues_json をそのまま渡すことで本文取得 API を
  # 二重呼び出ししない（NFR 2.2）。閉路メンバー集合は `_DC_CYCLE_MEMBERS`（空白区切り）
  # に export され、本ループ内で auto-unblock の対象から除外する（Req 4.4 / AT-j）。
  # fail-open（`|| true`）で cycle 検出の失敗が auto-unblock を壊さない（NFR 3.2）。
  dc_cycle_sweep "$issues_json" || true

  # 閉路メンバー判定用の grep -F 入力（改行区切り）に変換
  local cycle_members_lines=""
  if [ -n "${_DC_CYCLE_MEMBERS:-}" ]; then
    cycle_members_lines=$(printf '%s\n' "$_DC_CYCLE_MEMBERS" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
  fi

  local i issue_num issue_body
  for ((i=0; i<count; i++)); do
    issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
    issue_body=$(printf '%s' "$issues_json" | jq -r ".[$i].body // \"\"" 2>/dev/null)
    if [ -z "$issue_num" ] || ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
      dr_warn "dr_unblock_sweep: index=${i} の number 抽出に失敗 / skip"
      continue
    fi
    # Issue #368 / D-16: 閉路メンバーは auto-unblock の対象から除外（Req 4.4 / AT-j）。
    # cycle 検出側で needs-decisions 付与済みのため、ここで blocked を外すと矛盾する。
    if [ -n "$cycle_members_lines" ] \
        && printf '%s\n' "$cycle_members_lines" | grep -qxF -- "$issue_num"; then
      dr_log "issue=#${issue_num} verdict=unblock_skip_cycle_member"
      continue
    fi
    # 個別 Issue の処理失敗は fail-open（次 Issue に進む / NFR 3.2）
    dr_unblock_resolve_one_issue "$issue_num" "$issue_body" || true
  done
  return 0
}

# 1 Issue を 1 slot worktree で処理する Worker 本体。
# サブシェル `( _slot_run_issue n issue_json ) &` から呼び出される前提。
#
# 引数:
#   $1 = slot 番号
#   $2 = Issue JSON (gh issue list の 1 要素)
# 戻り値:
#   0 = 成功 / 非ゼロ = 失敗（既に claude-failed ラベルへ遷移済み）
#
# 副作用:
#   - サブシェル内で NUMBER / TITLE / BODY / URL / LABELS / TS / LOG / SLUG /
#     SPEC_DIR_REL / MODE / BRANCH などのグローバル変数を設定（親には伝播しない）
#   - $WT に cd（サブシェル内）
#   - claude / gh / git の副作用は Issue ラベル遷移として外部観測可能
_slot_run_issue() {
  # slot 識別子をサブシェル内で見えるよう export（slot_log / _hook_invoke が参照）
  export IDD_SLOT_NUMBER="$1"
  local issue="$2"

  # ── Issue メタデータ抽出 ──
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue"  | jq -r '.title')
  BODY=$(echo "$issue"   | jq -r '.body // ""')
  URL=$(echo "$issue"    | jq -r '.url')
  LABELS=$(echo "$issue" | jq -r '.labels[].name')
  TS=$(date +%Y%m%d-%H%M%S)
  LOG="$LOG_DIR/issue-${NUMBER}-${TS}.log"

  # slot 運用ログ（worktree 初期化・hook 結果など）。Issue ログとは別系統で残す（Req 6.2）。
  local SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"
  # 以降の slot_log 行は stdout (cron mailer) と SLOT_LOG の両方に書き出す
  exec > >(tee -a "$SLOT_LOG") 2>&1

  slot_log "Worker 起動 (LOG=$LOG SLOT_LOG=$SLOT_LOG)"

  # ── per-run evidence サマリの初期化と終端 emit 配線（#239 / Req 1.1, 1.3, 1.5） ──
  # rs_init で per-slot 状態変数を既定値にし、Issue 番号を確定。EXIT trap は本サブシェル
  # スコープローカルであり、dispatcher トップレベルの INT/TERM trap とは別境界（trap は
  # サブシェルでリセットされる）。worktree-ensure 失敗等の早期 return / set -e 異常終了 /
  # 正常 return のいずれの終端でも 1 回だけ rs_emit が発火し run-summary 行を 1 行吐く。
  # fail-open（|| true）で emit 失敗がサブシェルの exit code を変えない（NFR 4.1）。
  rs_init
  rs_set_issue "$NUMBER"
  # #325: token usage の Issue 単位サマリも同じ EXIT trap に連結する（rs_emit の発火を
  # 妨げないよう各々 || true で fail-open。出力順は run-summary → token-usage）。
  trap 'rs_emit || true; tu_emit_issue_summary || true' EXIT

  # ── Worktree 初期化（per-slot 永続 worktree）──
  local WT
  WT="$(_worktree_path "$IDD_SLOT_NUMBER")"
  export IDD_SLOT_WORKTREE="$WT"

  if ! _worktree_ensure "$IDD_SLOT_NUMBER"; then
    slot_warn "worktree 初期化に失敗 (path=$WT)"
    _slot_mark_failed "worktree-ensure" "Slot ${IDD_SLOT_NUMBER} の worktree 初期化に失敗しました（path=\`$WT\`）。"
    return 1
  fi
  slot_log "worktree 確保 OK (path=$WT)"

  # サブシェル内で worktree に cd（親には伝播しない、Req 3.5）
  if ! cd "$WT"; then
    slot_warn "worktree への cd に失敗 (path=$WT)"
    _slot_mark_failed "worktree-cd" "worktree path への cd に失敗しました: \`$WT\`"
    return 1
  fi

  # Issue #237: REPO_DIR を worktree へ上書きする「前」に、注入元となる元の
  # REPO_DIR（install.sh が `.claude/` を最新化したローカルクローン）を捕捉する。
  # _worktree_inject_claude はこの元 REPO_DIR の `.claude/` を worktree へコピーする。
  local SRC_REPO_DIR="$REPO_DIR"

  # Issue #76: slot worktree が REPO_DIR の意味を担う。サブシェル内で上書きするため
  # parent cron / launchd 側の REPO_DIR には伝播せず、後段の parse_review_result /
  # stage_checkpoint_* / `git -C "$REPO_DIR"` 系すべてが slot worktree を参照するようになる。
  # 既存 cron 起動文字列を変更する必要はない。
  REPO_DIR="$WT"

  # ── Worktree を origin/$BASE_BRANCH 最新へ強制リセット ──
  if ! _worktree_reset "$WT"; then
    slot_warn "worktree reset に失敗 (path=$WT)"
    _slot_mark_failed "worktree-reset" "Slot ${IDD_SLOT_NUMBER} の worktree を origin/${BASE_BRANCH} にリセットできませんでした。"
    return 1
  fi
  slot_log "worktree reset OK (origin/${BASE_BRANCH} 最新化 + clean -fdx)"

  # ── gitignore 運用 repo 向け `.claude/` 注入（reset 完了後・hook / agent 起動前）──
  # Issue #237: worktree に `.claude/` が無い（= gitignore 運用 repo）場合のみ、
  # 元 REPO_DIR の `.claude/` を worktree へ注入して agent runtime を健全化する。
  # tracked 運用 repo は worktree に `.claude/` があるため NO-OP（既存挙動不変）。
  # fail-open のため _worktree_inject_claude は常に 0 を返し、注入失敗で
  # claude-failed へ遷移させない（Req 3.2, 3.3）。
  _worktree_inject_claude "$SRC_REPO_DIR" "$WT"

  # ── Scaffolding Health preflight gate（#238 / reset+注入後・agent stage 前）──
  # worktree 内の `.claude/agents` / `.claude/rules` 非空到達性を検査し、欠落時は loud WARN ＋
  # Issue コメント可視シグナルを残す（Req 1）。既定（SCAFFOLDING_HEALTH_HALT=off）は可視化のみで
  # 進行を止めず（Req 2.1）、`on` opt-in かつ missing のときだけ gate が非 0 を返す（Req 2.2）。
  # indeterminate（検査の I/O 異常）は fail-open で常に継続（gate が 0 / Req 3）。
  if ! sh_preflight_gate "$WT"; then
    # HALT opt-in かつ missing → agent stage を起動せず人間判断待ちへ遷移して当該 Issue を
    # 当該サイクル終了する。claude-failed は付けない（足場欠落は「失敗」ではなく「人間判断
    # 待ち」/ Req 2.2 / design Decision 3）。claim 系ラベル（claude-claimed / claude-picked-up）を
    # 除去して auto-dev へ戻し、dispatcher の in-flight 判定が誤らないようにする（次 tick の
    # 再 pickup は人間が足場を修復した後に full 判定で自然に進行する / `_slot_mark_failed` の
    # label 操作を参考にするが `claude-failed` は付けない / fail-open）。
    gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" >/dev/null 2>&1 || true
    slot_log "scaffolding-health: HALT により agent stage を起動せず人間判断待ち（claim 系ラベル除去 / Issue #${NUMBER}）"
    return 0
  fi

  # ── SLOT_INIT_HOOK 起動（reset 後・claude 起動前に 1 度だけ）──
  if ! _hook_invoke "$IDD_SLOT_NUMBER" "$WT"; then
    slot_warn "SLOT_INIT_HOOK の起動に失敗"
    _slot_mark_failed "slot-init-hook" "SLOT_INIT_HOOK が失敗しました（詳細はログ参照）。SLOT_INIT_HOOK=\`${SLOT_INIT_HOOK:-(unset)}\`"
    return 1
  fi
  if [ -n "${SLOT_INIT_HOOK:-}" ]; then
    slot_log "SLOT_INIT_HOOK 完了"
  fi

  # ── 既存 Issue 処理ロジックを実行 ──
  # ここから下は本機能導入前の Issue ループ本体と等価。サブシェル内で動くため
  # NUMBER / MODE / LOG 等のグローバル変数変更は親に伝播しない（Req 3.5 を構造的に保証）。
  echo "=== Processing #$NUMBER: $TITLE (slot-${IDD_SLOT_NUMBER}) ===" | tee -a "$LOG"

  # ── 既存 spec ディレクトリの検出（設計 PR merge 済みか）と slug 決定 ──
  # Issue #114: expected-slug を Issue タイトルから先に決定し、既存 `docs/specs/<N>-*/`
  # のスラグ部と照合する。不一致時は fork / mirror clone 由来の番号衝突と判断し、
  # 当該 Issue を skip して人間判断に委ねる（Req 1.1〜1.6, Req 3 一式）。
  local EXPECTED_SLUG
  EXPECTED_SLUG=$(_normalize_slug "$TITLE")

  # `docs/specs/<N>-*/` を全件列挙（Req 1.5: 複数存在ケースも全件チェック対象）
  local SPEC_CANDIDATES=()
  local _spec_glob
  for _spec_glob in "$WT/docs/specs/${NUMBER}-"*; do
    [ -d "$_spec_glob" ] || continue
    SPEC_CANDIDATES+=("$_spec_glob")
  done

  local EXISTING_SPEC_DIR=""
  local HAS_EXISTING_SPEC=false
  if [ "${#SPEC_CANDIDATES[@]}" -gt 0 ]; then
    # Req 1.2, 1.3: 各候補のスラグを expected と比較。一致しかつ requirements.md がある
    # ものを採用する。複数一致は通常起こらないが、起きた場合は先頭採用（後方互換）。
    local _cand _cand_slug _matched_dir=""
    for _cand in "${SPEC_CANDIDATES[@]}"; do
      _cand_slug=$(basename "$_cand" | sed "s/^${NUMBER}-//")
      if [ "$_cand_slug" = "$EXPECTED_SLUG" ] && [ -f "$_cand/requirements.md" ]; then
        _matched_dir="$_cand"
        break
      fi
    done

    if [ -n "$_matched_dir" ]; then
      # Req 1.3: 一致 → 従来どおり impl-resume を継続。LOG にスラグ照合 pass を記録（Req 4.1）
      HAS_EXISTING_SPEC=true
      EXISTING_SPEC_DIR="$_matched_dir"
      if ! _stage_checkpoint_assert_slug_match "$EXPECTED_SLUG" "$_matched_dir"; then
        return 1
      fi
      SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
      echo "📂 既存 spec 検出: $EXISTING_SPEC_DIR (slug=$SLUG)" | tee -a "$LOG"
    else
      # Issue #383 Req 1.2, 1.5: docs/specs/<N>-* は存在するが expected-slug と一致する
      # ものがないケースは、umbrella spec を sub-issue が共有する構成での fresh issue を
      # 誤 block しないため、resumable state が実在するときのみ slug guard を発火させる。
      # resumable state 不在（fresh issue）なら slug guard を skip して Stage A を新規実装
      # として継続する（SLUG は Issue タイトル由来の EXPECTED_SLUG を採用）。
      # 判定失敗（gh API エラー等）は NFR 2.1 の safe-side に倒して従来の発火経路を維持する。
      local _first="${SPEC_CANDIDATES[0]}"
      local _resumable_rc=0
      _stage_checkpoint_has_resumable_state "$_first" || _resumable_rc=$?
      case "$_resumable_rc" in
        1)
          # Req 1.2, 1.3, 1.4: resumable state 不在 → slug guard skip。`needs-decisions`
          # 付与なし / escalation コメント投稿なし / SLUG は Issue タイトル由来を採用。
          echo "stage-checkpoint: slug-guard-skipped issue=#${NUMBER:-?} expected=${EXPECTED_SLUG} found=$(basename "$_first" | sed "s/^${NUMBER}-//") reason=no-resumable-state" | tee -a "$LOG"
          SLUG="$EXPECTED_SLUG"
          ;;
        *)
          # Req 2.1, 2.3 / NFR 2.1: resumable state 実在（0）/ 判定失敗の safe-side（2）/
          # 想定外 rc は全て従来どおり slug guard を発火させる方に倒す（safe-side default）。
          if ! _stage_checkpoint_assert_slug_match "$EXPECTED_SLUG" "$_first"; then
            return 1
          fi
          # 防御: _stage_checkpoint_assert_slug_match が 0 を返した（一致した）場合の
          # フォールバック（実装上は到達しないが silent fail を作らないため）
          HAS_EXISTING_SPEC=true
          EXISTING_SPEC_DIR="$_first"
          SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
          ;;
      esac
    fi
  else
    # Req 1.6: `docs/specs/<N>-*/` が存在しないとき → 本要件のスラグ照合は発火させず
    # 従来どおり Issue タイトル由来の新規スラグを採用する（NFR 1.3）
    SLUG="$EXPECTED_SLUG"
  fi
  SPEC_DIR_REL="docs/specs/${NUMBER}-${SLUG}"

  # ── モード判定（design / impl / impl-resume）──
  NEEDS_ARCHITECT="false"
  ARCHITECT_REASON=""
  MODE=""

  if $HAS_EXISTING_SPEC; then
    echo "✅ #$NUMBER: 設計レビュー済み（spec dir あり） → impl-resume モード" | tee -a "$LOG"
    MODE="impl-resume"
    rs_set_mode impl-resume
  elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "skip-triage ラベルがあるため Triage をスキップ → impl モード" | tee -a "$LOG"
    ARCHITECT_REASON="Triage をスキップ（軽微な変更扱い）"
    MODE="impl"
    rs_set_mode impl
  else
    # ── Dependency Resolver Gate (Issue #146) ──
    # Triage 起動直前に Issue 本文の前提依存（canonical `Depends on:` /
    # alias `前提依存:` / alias `Blocked by:`）を機械検証し、依存先 Issue が
    # 未 merge のまま残る場合は `blocked` 付与 + コメント投稿 + claim 系ラベル
    # 除去で人間判断へ委ね、本サイクルの当該 Issue 処理を打ち切る（Req 3.5）。
    # `HAS_EXISTING_SPEC=true`（impl-resume 経路）および `skip-triage` 経路では
    # 呼び出さない（既に in-flight の Issue への retrofit を Out of Scope と
    # する設計判断 / Req NFR 1.1 後方互換）。
    if ! dr_check_dependencies "$NUMBER" "$BODY" "$LABELS"; then
      slot_log "依存未解決により blocked 付与（Issue #146）"
      return 0
    fi

    # ── Triage フェーズ ──
    local TRIAGE_FILE="/tmp/triage-${REPO_SLUG}-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    # sed 置換文字列で特別扱いされる文字を網羅エスケープする（未信頼の Issue タイトル由来）。
    # `\`（エスケープ導入）→ `&`（被マッチ展開）→ 区切り `|` の順で処理する
    # （`\` を先に処理しないと後続で挿入した `\&` / `\|` が二重エスケープされる）。
    # 末尾が `\` のタイトルで sed 式が malformed 化する事故、および `&` による
    # `{{TITLE}}` 逐語混入を防ぐ。
    local TITLE_SAFE="$TITLE"
    TITLE_SAFE="${TITLE_SAFE//\\/\\\\}"
    TITLE_SAFE="${TITLE_SAFE//&/\\&}"
    TITLE_SAFE="${TITLE_SAFE//|/\\|}"
    local TRIAGE_PROMPT
    TRIAGE_PROMPT=$(sed \
      -e "s|{{NUMBER}}|${NUMBER}|g" \
      -e "s|{{TITLE}}|${TITLE_SAFE}|g" \
      -e "s|{{URL}}|${URL}|g" \
      -e "s|{{FILE}}|${TRIAGE_FILE}|g" \
      "$TRIAGE_TEMPLATE")

    echo "--- Triage 実行 ---" >> "$LOG"
    # #332: TRIAGE_BARE=true（厳密一致）のとき --bare を付与し、CLAUDE.md / rules 等の
    # 自動ロードを排除する（Triage の判定基準は template 内で自己完結）。guard hook
    # （IDD_CLAUDE_HOOKS_ENABLED）opt-in 時は --settings 経由の hook 注入を --bare が
    # 無効化しうるため、安全側に倒して --bare を見送り WARN を残す（両立不可の明示）。
    # 空配列展開 "${arr[@]}" は bash 4.4+ で set -u 安全（guard-hook.sh の先例と同様）。
    local _triage_bare_args=()
    if [ "${TRIAGE_BARE:-false}" = "true" ]; then
      if declare -F gh_is_enabled >/dev/null 2>&1 && gh_is_enabled; then
        echo "[$(date '+%F %T')] [$REPO] triage: WARN: TRIAGE_BARE=true は IDD_CLAUDE_HOOKS_ENABLED（guard hook）と併用できないため --bare を見送ります（guard hook を優先）" >> "$LOG"
      else
        _triage_bare_args=(--bare)
      fi
    fi
    # Issue #66: Quota-Aware Watcher 経由で claude を起動。opt-out 時は素通し
    # （既存挙動互換）、opt-in 時は rate_limit_event 検知で exit 99 を返す。
    local _qa_reset_file_triage="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-triage-${TS}"
    local _qa_rc_triage=0
    qa_run_claude_stage "Triage" "$_qa_reset_file_triage" -- \
      claude \
        "${_triage_bare_args[@]}" \
        --print "$TRIAGE_PROMPT" \
        --model "$TRIAGE_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$TRIAGE_MAX_TURNS" \
        "${CLAUDE_HOOK_ARGS[@]}" \
        >> "$LOG" 2>&1 || _qa_rc_triage=$?
    case "$_qa_rc_triage" in
      0)
        : # 正常終了 → 後続処理へ
        ;;
      99)
        # quota 超過検出（opt-in 時のみ発生）→ needs-quota-wait に遷移し、
        # _slot_mark_failed を踏まずに正常終了する（Req 3.1, 3.2）
        local _qa_epoch_triage
        _qa_epoch_triage=$(cat "$_qa_reset_file_triage")
        qa_handle_quota_exceeded "$NUMBER" "Triage" "$_qa_epoch_triage"
        rm -f "$_qa_reset_file_triage"
        slot_log "Triage で quota 超過検出 → needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_triage"
        echo "❌ Triage の実行に失敗" | tee -a "$LOG"
        # claude-picked-up は Dispatcher 側で付与済。Triage 失敗時は claude-failed に
        # 遷移して人間判断に委ねる（既存挙動: Triage 失敗時は continue だったが、
        # Phase C ではすでに claim 済のため、ラベルを残置せず claude-failed 化する）。
        _slot_mark_failed "triage" "Triage（Claude 実行）に失敗しました。"
        return 1
        ;;
    esac
    rm -f "$_qa_reset_file_triage"

    if [ ! -f "$TRIAGE_FILE" ]; then
      echo "❌ Triage 結果 JSON が生成されませんでした" | tee -a "$LOG"
      _slot_mark_failed "triage-json" "Triage 結果 JSON が生成されませんでした。"
      return 1
    fi

    local STATUS DECISION_COUNT
    STATUS=$(jq -r '.status' "$TRIAGE_FILE")
    DECISION_COUNT=$(jq '.decisions | length' "$TRIAGE_FILE")
    NEEDS_ARCHITECT=$(jq -r '.needs_architect // false' "$TRIAGE_FILE")
    ARCHITECT_REASON=$(jq -r '.architect_reason // ""' "$TRIAGE_FILE")

    # ── Phase E: edit_paths 永続化 (#18 Req 3.1〜3.4) ──
    # PATH_OVERLAP_CHECK=true のときのみ、Triage が返した edit_paths を sticky
    # comment として Issue に保存し、後続 cron tick で Path Overlap Checker が
    # 再読できるようにする。persist 失敗は warn のみで、Triage 全体は成功扱い
    # を維持する（Req 3.4 fail-open）。
    if [ "$PATH_OVERLAP_CHECK" = "true" ]; then
      local _po_paths_json
      _po_paths_json=$(po_parse_triage_edit_paths "$TRIAGE_FILE")
      if ! po_persist_edit_paths "$NUMBER" "$_po_paths_json"; then
        po_warn "issue=#${NUMBER} edit_paths sticky comment の保存に失敗（次サイクルで再評価 / Req 3.4 fail-open）"
      else
        po_log "issue=#${NUMBER} edit_paths persisted paths=$(echo "$_po_paths_json" | jq -r 'join(",")')"
      fi
    fi

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      # ── Issue #362: needs-decisions 自動続行（D-08 / D-09） ──
      # AND 二重 opt-in（FULL_AUTO_ENABLED=true AND NEEDS_DECISIONS_MODE in (classified, all-auto)）
      # 配下で、Triage が `safe` 分類した decisions について PM 第一推奨で自動続行する。
      # rc=0 = auto-continue 実行済 → 既存 COMMENT 組み立て + gh issue comment + ラベル付け替え
      # （needs-decisions 付与）+ return 0 を **すべて skip** して即 return 0（Issue は
      # `needs-decisions` 不付与 + `claude-claimed` 除去済 → 次サイクルで dispatcher 再 pickup）。
      # rc=1 = halt → 既存処理（needs-decisions 付与 + コメント投稿）にそのまま流す
      # （本機能導入前と完全等価 / NFR 1.1, 1.3）。
      if nda_evaluate_auto_continue "$TRIAGE_FILE"; then
        slot_log "Triage 結果: needs-decisions → auto-continue（#362, claude-claimed 除去済・次サイクル再 pickup 待機）"
        return 0
      fi
      local COMMENT
      COMMENT=$(jq -r '
        "## 🤔 実装着手前に確認が必要な事項\n\n" +
        "Issue 内容を Claude Code の Product Manager で精査した結果、" +
        "以下の判断は人間に委ねる必要があると判定しました。\n\n" +
        "> " + .rationale + "\n\n" +
        "---\n\n" +
        (.decisions | to_entries | map(
          "### " + ((.key + 1) | tostring) + ". " + .value.topic + "\n\n" +
          "**質問**: " + .value.question + "\n\n" +
          "**選択肢**:\n" +
          (.value.options | map("- " + .) | join("\n")) + "\n\n" +
          "**影響**: " + .value.impact + "\n\n" +
          "**推奨**: " + .value.recommendation + "\n"
        ) | join("\n---\n\n")) +
        "\n\n---\n\n" +
        "## 回答方法\n\n" +
        "1. 各項目についてこの Issue にコメントで回答してください。\n" +
        "2. すべての項目に結論が出たら、この Issue から **`needs-decisions` ラベルを外してください**。\n" +
        "3. ラベルが外れた時点で Claude Code が自動で再 Triage し、追加論点が無ければ開発に着手します。\n" +
        "4. Triage をスキップして強制着手したい場合は `skip-triage` ラベルを付与してください。"
      ' "$TRIAGE_FILE")

      gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT" >/dev/null 2>&1 || true
      # Phase C / Issue #52: claim を取り消す（claude-claimed 除去）+ needs-decisions 付与。
      # 次サイクルで人間が needs-decisions を外したら再ピックアップされる必要があるため、
      # claim 系ラベルを残してはいけない。本機能導入前は claude-picked-up は未付与
      # だったが、Phase C 以降は Dispatcher が claim ラベル（Issue #52 で claude-claimed
      # に分離）を事前に付与しているためここで取り消す。
      gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
      echo "🟡 #$NUMBER: $DECISION_COUNT 件の決定事項を起票しました" | tee -a "$LOG"
      slot_log "Triage 結果: needs-decisions（claude-claimed 取り消し済）"
      return 0
    fi

    if [ "$NEEDS_ARCHITECT" = "true" ]; then
      MODE="design"
      rs_set_mode design
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      rs_set_mode impl
      echo "✅ #$NUMBER: Triage 通過（Architect 不要） → impl モード" | tee -a "$LOG"
    fi
  fi

  # ── Issue #52: Triage 通過後のラベル付け替え（claude-claimed → claude-picked-up）──
  # impl / impl-resume モードでは、ここから先「実装フェーズ」に入るため Issue ラベルを
  # claude-picked-up に付け替える。design モードは PjM (design-review) が
  # claude-claimed → awaiting-design-review に直接付け替えるため、ここでは何もしない
  # （Req 8.3 / 設計論点 4 結論: design ルートは claude-picked-up を経由しない）。
  #
  # 単一の PATCH /issues/{n}（--remove-label A --add-label B）で原子的に行うことで
  # NFR 1.2（同時 2 ラベル状態が 5 秒以上続かない）を構造的に満たす。branch 作成より
  # 前に実行するため、後続の長時間操作中はラベル状態が常に正しい。
  if [ "$MODE" = "impl" ] || [ "$MODE" = "impl-resume" ]; then
    if ! gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_PICKED" >/dev/null 2>&1; then
      slot_warn "Triage 通過後のラベル付け替えに失敗（claude-claimed → claude-picked-up）"
      _slot_mark_failed "label-handover" "Triage 通過後のラベル付け替え (claude-claimed → claude-picked-up) に失敗しました。"
      return 1
    fi
    slot_log "ラベル付け替え: claude-claimed → claude-picked-up（impl 着手）"
    # Issue #390: impl 着手（claude-pickup）を Slack に 1 通通知（gate / URL preflight /
    # fail-open はすべて sn_notify 内に閉じている。`|| true` は既存 5 イベント callsite と
    # 同形の fail-open 防御）。
    sn_notify claude-pickup "$NUMBER" "https://github.com/$REPO/issues/$NUMBER" success "mode=${MODE} slot=${IDD_SLOT_NUMBER}" || true
  fi

  # ── ピックアップ表明コメント（claim 表明ラベルは Dispatcher が事前に付与済）──
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Claude Code ($(hostname)) が処理を開始しました（slot=${IDD_SLOT_NUMBER} / モード: ${MODE}）。" >/dev/null 2>&1 || true

  # ── ブランチを切る（モードに応じて名前を変える）──
  case "$MODE" in
    design)
      BRANCH="claude/issue-${NUMBER}-design-${SLUG}"
      ;;
    impl|impl-resume)
      BRANCH="claude/issue-${NUMBER}-impl-${SLUG}"
      ;;
  esac
  # impl-resume モードのときだけ Strategy Pattern による branch 初期化に分岐させる
  # （Issue #67）。design / impl モードでは本機能導入前と完全に等価な挙動を維持する
  # （Req 1.1, 1.2, NFR 1.1, NFR 1.2）。`_resume_branch_init` は内部で
  # `IMPL_RESUME_PRESERVE_COMMITS` を見て legacy / preserve 戦略にディスパッチし、
  # 失敗時は `_slot_mark_failed` 既に発射済の状態で非 0 を返す。
  if [ "$MODE" = "impl-resume" ]; then
    # Issue #114 Req 2: origin の `claude/issue-<N>-impl-*` ブランチを resume 候補として
    # 検出するとき、ブランチ名のスラグ部と expected-slug を照合する。不一致時は
    # `_slug_mismatch_escalate` 経由で `needs-decisions` に倒し、本 Issue を skip する。
    # spec dir 経路で expected と一致した SLUG が確定済なので、ここで照合する expected は
    # `$SLUG` と同値（_normalize_slug の冪等性により）。
    if ! _resume_branch_assert_slug_match "$SLUG"; then
      return 1
    fi
    if ! _resume_branch_init; then
      return 1
    fi
  else
    # worktree は detached HEAD で起動するため -B で新規 branch 作成
    # （local $BASE_BRANCH を持たない）
    if ! git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"; then
      slot_warn "branch 作成に失敗: $BRANCH"
      _slot_mark_failed "branch-checkout" "ブランチ \`$BRANCH\` の作成に失敗しました。"
      return 1
    fi
    if ! git push -u origin "$BRANCH" --force-with-lease; then
      slot_warn "branch push に失敗: $BRANCH"
      _slot_mark_failed "branch-push" "ブランチ \`$BRANCH\` の push に失敗しました。"
      return 1
    fi
  fi

  # ── モード別ディスパッチ ──
  if [ "$MODE" = "design" ]; then
    # Issue #96 Req 1.5: 設計 PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
    if ! _assert_base_branch_resolved; then
      echo "❌ #$NUMBER: design 中断（BASE_BRANCH 未解決）→ claude-failed" | tee -a "$LOG"
      _slot_mark_failed "design-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため設計フェーズを中断しました（Issue #96 Req 1.5）。"
      return 1
    fi
    local FLOW_LABEL STEPS DEV_PROMPT
    FLOW_LABEL="PM → Architect → PjM（設計 PR 作成ゲート）"
    STEPS=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. architect サブエージェントで設計書とタスク分割を保存
   - Triage 判定理由: ${ARCHITECT_REASON}
   - \`${SPEC_DIR_REL}/design.md\`（モジュール構成・データモデル・公開 IF・処理フロー・リスク）
   - \`${SPEC_DIR_REL}/tasks.md\`（Developer 向けタスク分割、各タスクが独立コミット可能な粒度）
3. project-manager サブエージェントを **design-review モード** で起動
   - 成果物は ${SPEC_DIR_REL}/ 配下の requirements / design / tasks のみ（実装コードは含めない）
   - title: \`spec(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を必ず明示すること。GitHub のデフォルト base に依存しない）
   - Issue ラベル: claude-claimed → awaiting-design-review に付け替え
   - Issue にコメントで設計 PR リンクと案内を投稿

この設計 PR が merge されるまで、実装フェーズには進みません。人間が merge した後、
次回のポーリングで Developer が自動起動し、実装 PR が別途作成されます。
EOF
)

    DEV_PROMPT=$(cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を ${FLOW_LABEL} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

PjM サブエージェント（design-review モード）は \`gh pr create\` 実行時に
**必ず \`--base ${BASE_BRANCH}\`** を明示してください（GitHub のデフォルト base に依存しないこと）。
これは本サイクル開始時に watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダ
ではありません。PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で
取得した値が \`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方
${STEPS}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- 既存のテストを壊さないこと
- 不明点は推測せず、PR 本文の「確認事項」セクションに列挙すること
EOF
)

    echo "--- Development 実行（$MODE）---" >> "$LOG"
    # Issue #66: Quota-Aware Watcher 経由で claude を起動
    local _qa_reset_file_design _qa_rc_design=0 _qa_ts_design
    _qa_ts_design=$(date +%Y%m%d-%H%M%S)
    _qa_reset_file_design="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-design-${_qa_ts_design}"
    qa_run_claude_stage "design" "$_qa_reset_file_design" -- \
      claude \
        --print "$DEV_PROMPT" \
        --model "$DEV_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$DEV_MAX_TURNS" \
        --output-format stream-json \
        --verbose \
        "${CLAUDE_HOOK_ARGS[@]}" \
        >> "$LOG" 2>&1 || _qa_rc_design=$?
    case "$_qa_rc_design" in
      0)
        echo "✅ #$NUMBER: $MODE 完了" | tee -a "$LOG"
        slot_log "$MODE 完了"
        # Issue #147: Tasks Count Gate — Architect 確定直後の tasks.md 件数を再評価し、
        # 8〜10 件で警告コメント、11 件以上で needs-decisions + Developer 抑止を適用。
        # 本機能は fail-open（戻り値は常に 0）かつ TC_ENABLED=false で完全 opt-out 可。
        # design 分岐 rc=0 case にのみ配置し、impl / impl-resume / Stage Checkpoint
        # Resume 経路には差し込まないことで Req 3.1 / 3.2 を構造的に保証する。
        tc_run_post_architect_check || true
        rm -f "$_qa_reset_file_design"
        return 0
        ;;
      99)
        local _qa_epoch_design
        _qa_epoch_design=$(cat "$_qa_reset_file_design")
        qa_handle_quota_exceeded "$NUMBER" "design" "$_qa_epoch_design"
        rm -f "$_qa_reset_file_design"
        slot_log "$MODE で quota 超過検出 → needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_design"
        echo "❌ #$NUMBER: $MODE 失敗" | tee -a "$LOG"
        _slot_mark_failed "$MODE" "design モードでの Claude 実行が失敗しました。"
        return 1
        ;;
    esac
  else
    # impl / impl-resume → Reviewer ゲートを含む stage 分割パイプラインへ。
    # run_impl_pipeline の戻り値契約:
    #   0 = 完了 / 良性停止（quota → needs-quota-wait / partial / Stage Checkpoint TERMINAL_OK）
    #   3 = 再 pickup 可能な保留（stage-a-verify round=1 差し戻し / Issue #219）。
    #       claude-failed は未付与で claude-picked-up も除去済み → 次 tick で再評価される。
    #   その他非 0 = 失敗。各 stage 内で `mark_issue_failed` 発火済み（claude-failed 付与済み）。
    local _impl_rc=0
    run_impl_pipeline || _impl_rc=$?
    case "$_impl_rc" in
      0)
        echo "✅ #$NUMBER: $MODE 完了（Reviewer ゲート通過 / PR 作成済み）" | tee -a "$LOG"
        slot_log "$MODE 完了（PR 作成済み）"
        return 0
        ;;
      3)
        # stage-a-verify round=1 差し戻し。claude-failed は付与されておらず、
        # 虚偽の「claude-failed 付与済み」を出さない（Issue #219 fix）。
        echo "⏸️ #$NUMBER: $MODE 保留（stage-a-verify 差し戻し / claude-failed 未付与 / 次 tick で再評価）" | tee -a "$LOG"
        slot_log "$MODE 保留（stage-a-verify 差し戻し / 次 tick 再評価）"
        return 0
        ;;
      *)
        echo "❌ #$NUMBER: $MODE 失敗（claude-failed 付与済み）" | tee -a "$LOG"
        slot_log "$MODE 失敗（claude-failed 付与済み）"
        return 1
        ;;
    esac
  fi
}

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

