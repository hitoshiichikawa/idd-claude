#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer.sh — watcher の PR Reviewer Processor モジュール (#261)
#
# 用途:
#   issue-watcher.sh から分離した PR Reviewer Processor (#261) の関数定義を集約する。
#   `PR_REVIEWER_ENABLED=true` のとき外部 AI レビューツール（`codex` または
#   `antigravity` (バイナリ名 `agy`)）を呼び出し、open PR に対するレビュー結果を
#   PR コメントとして投稿し、修正要求の VERDICT を検出した場合に `needs-iteration`
#   ラベルを付与して既存 PR Iteration Processor (#26) のループへ接続する。
#   - 入口: process_pr_reviewer（dispatcher から呼ばれる）
#   - tool 解決と排他検証: pr_resolve_tool（出力: `codex` / `antigravity` /
#     `none` / `conflict`、戻り値 0 = ok / 1 = conflict / 2 = none）
#   - 健全性チェック: pr_check_tool_installed / pr_check_tool_authenticated
#   - 重複防止 marker: pr_build_marker / pr_already_processed（gh api comments + jq）
#   - 候補 PR 列挙: pr_fetch_candidate_prs（open + 非 draft + head pattern + 非 fork）
#   - レビュー実行: pr_build_prompt_file / pr_substitute_placeholders /
#     pr_execute_review_command（subshell + trap で head checkout / BASE 復帰 /
#     read-only invariant 検査）
#   - コメント投稿: pr_post_review_comment / pr_post_error_comment（hidden marker 付き）
#   - VERDICT 検出 / ラベル付与: pr_detect_iteration_keyword / pr_add_iteration_label
#   - 1 PR 分のレビューを統括: pr_run_review_for_pr
#
# 配置先:
#   $HOME/bin/modules/pr-reviewer.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh に定義済み（#261 task 1 で追加）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_REVIEWER_ENABLED /
#     $PR_REVIEWER_TOOL / $PR_REVIEWER_CODEX_ENABLED / $PR_REVIEWER_ANTIGRAVITY_ENABLED /
#     $PR_REVIEWER_MAX_PRS / $PR_REVIEWER_EXEC_TIMEOUT 等）は本体冒頭の Config ブロックで
#     定義される予定（task 7 で配線）。bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_pr_reviewer || pr_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ）。
#   - 外部 CLI: gh / git / jq / codex / agy（健全性チェック・レビュー実行で使用）。
#
# セットアップ参照先:
#   - 設計: docs/specs/261-feat-pr-codex-antigravity/design.md
#   - README「PR Reviewer Processor (#261)」節（task 8 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# pr_resolve_tool: PR_REVIEWER_TOOL / *_CODEX_ENABLED / *_ANTIGRAVITY_ENABLED から
#   使用ツールを解決する（design.md Decision 1 の解決順序）
#
#   入力: 環境変数のみ
#     - PR_REVIEWER_TOOL: canonical な単一値（"codex" / "antigravity" / それ以外）
#     - PR_REVIEWER_CODEX_ENABLED: alias（"=true" 厳密一致のみ有効）
#     - PR_REVIEWER_ANTIGRAVITY_ENABLED: alias（"=true" 厳密一致のみ有効）
#   出力: stdout に "codex" / "antigravity" / "none" / "conflict" のいずれか 1 語
#   戻り値: 0 = ok（codex / antigravity）
#           1 = conflict（両方有効化、排他エラー）
#           2 = none（どちらも有効化されていない）
#   AC: 2.1, 2.2, 2.3, 2.5, NFR 3.1
#
#   解決順序（design.md Decision 1）:
#     1. PR_REVIEWER_TOOL が "codex" / "antigravity" に厳密一致 → 当該値を採用
#     2. PR_REVIEWER_TOOL が 上記 2 値以外で非空 → WARN + alias fallback
#     3. alias を独立評価:
#        - codex_on  = (PR_REVIEWER_CODEX_ENABLED == "true")
#        - agy_on    = (PR_REVIEWER_ANTIGRAVITY_ENABLED == "true")
#     4. 片方のみ true → 採用、両方 true → conflict、両方 false → none
# ─────────────────────────────────────────────────────────────────────────────
pr_resolve_tool() {
  local tool_canonical="${PR_REVIEWER_TOOL:-}"
  local codex_on="${PR_REVIEWER_CODEX_ENABLED:-false}"
  local agy_on="${PR_REVIEWER_ANTIGRAVITY_ENABLED:-false}"

  # Step 1: PR_REVIEWER_TOOL が canonical 2 値に厳密一致 → 即採用
  case "$tool_canonical" in
    codex)
      echo "codex"
      return 0
      ;;
    antigravity)
      echo "antigravity"
      return 0
      ;;
    "")
      # 未設定 → alias 評価へフォールスルー
      ;;
    *)
      # canonical 2 値以外の非空値 → WARN + alias 評価へフォールバック（Decision 1 step 6）
      # pr_warn は stderr に出すため stdout の "tool 名" 契約を汚さない
      pr_warn "PR_REVIEWER_TOOL='${tool_canonical}' は canonical 値 (codex|antigravity) ではありません。PR_REVIEWER_CODEX_ENABLED / PR_REVIEWER_ANTIGRAVITY_ENABLED で alias 解決します"
      ;;
  esac

  # Step 2: alias 独立評価（厳密 =true のみ有効。それ以外（"True" / "1" / typo）は false 扱い）
  if [ "$codex_on" = "true" ] && [ "$agy_on" = "true" ]; then
    # AC 2.3: 排他エラー
    pr_error "PR_REVIEWER_CODEX_ENABLED と PR_REVIEWER_ANTIGRAVITY_ENABLED の両方が有効化されています（排他エラー）"
    echo "conflict"
    return 1
  fi

  if [ "$codex_on" = "true" ]; then
    # AC 2.1
    echo "codex"
    return 0
  fi

  if [ "$agy_on" = "true" ]; then
    # AC 2.2
    echo "antigravity"
    return 0
  fi

  # AC 2.5: どちらも無効
  # stdout は "none" の単一 token のみを返す契約のため、観測ログは >&2 へ。
  # 呼び出し元 process_pr_reviewer は command substitution で stdout を捕捉する。
  pr_log "tool 未指定（PR_REVIEWER_TOOL 未設定 かつ PR_REVIEWER_{CODEX,ANTIGRAVITY}_ENABLED いずれも true ではない）。サイクルを skip します" >&2
  echo "none"
  return 2
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_installed: 指定ツールの実行ファイルが PATH 上に存在するか確認
#
#   入力: $1 = "codex" | "antigravity"
#         （Decision 2 / 3: antigravity の実バイナリ名は `agy`）
#   出力: なし（観測ログは pr_log のみ）
#   戻り値: 0 = ok (installed) / 1 = not-installed
#   AC: 3.1
#
#   - `command -v "$bin"` で PATH 上の実行ファイル存在を確認する pure check。
#     stdout は捨てて戻り値のみを契約とする（呼び出し元は rc で分岐）。
#   - "codex" / "antigravity" 以外の入力は内部矛盾（pr_resolve_tool が canonical
#     2 値以外を返すことは無い設計）。安全側に倒し、観測ログを残して
#     not-installed (rc=1) 相当を返す。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_installed() {
  local tool="${1:-}"
  local bin=""

  case "$tool" in
    codex)
      bin="codex"
      ;;
    antigravity)
      bin="agy"
      ;;
    *)
      pr_error "pr_check_tool_installed: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。not-installed として扱います"
      return 1
      ;;
  esac

  if command -v "$bin" >/dev/null 2>&1; then
    pr_log "tool installed check: tool=${tool} bin=${bin} result=ok"
    return 0
  fi

  pr_log "tool installed check: tool=${tool} bin=${bin} result=not-installed"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_check_tool_authenticated: 指定ツールが認証済みか確認
#
#   入力: $1 = "codex" | "antigravity"
#   出力: なし（観測ログは pr_log のみ。auth コマンドの stdout/stderr は破棄）
#   戻り値: 0 = ok (authenticated)
#           1 = not-authenticated
#           2 = check 機構が無効（env 未設定 / 空文字 = 既定 skip）
#   AC: 3.2
#
#   - `PR_REVIEWER_<TOOL>_AUTH_CMD` env を解決し、空文字なら skip (rc=2)。
#     既定値は task 7 で issue-watcher.sh 本体側に焼き込まれる:
#       - codex: `codex login status`
#       - agy:   `""`（既定 skip。Decision 3）
#     本 task 範囲では env 未設定 = 空文字扱い = skip で OK。
#   - 非空なら `bash -c "$auth_cmd"` を `>/dev/null 2>&1` で stdout/stderr を完全
#     破棄して実行（Security Considerations: auth token / 認証 URL 等の流出防止）。
#   - 終了コード 0 → ok (rc=0)、非ゼロ → not-authenticated (rc=1)。
#   - `eval` は使わない（Decision 9）。`bash -c` で subshell に閉じ込める。
# ─────────────────────────────────────────────────────────────────────────────
pr_check_tool_authenticated() {
  local tool="${1:-}"
  local auth_cmd=""

  case "$tool" in
    codex)
      auth_cmd="${PR_REVIEWER_CODEX_AUTH_CMD:-}"
      ;;
    antigravity)
      auth_cmd="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD:-}"
      ;;
    *)
      pr_error "pr_check_tool_authenticated: 未知の tool 名 '${tool}'（'codex' / 'antigravity' のいずれか）。skip として扱います"
      return 2
      ;;
  esac

  if [ -z "$auth_cmd" ]; then
    # AC 3.2 既定: 空文字 = check 機構が無効（skip）
    pr_log "tool authenticated check: tool=${tool} result=skipped (auth cmd unset)"
    return 2
  fi

  # auth コマンド実行: stdout / stderr を完全破棄（Security Considerations）
  if bash -c "$auth_cmd" >/dev/null 2>&1; then
    pr_log "tool authenticated check: tool=${tool} result=ok"
    return 0
  fi

  pr_log "tool authenticated check: tool=${tool} result=not-authenticated"
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_marker: hidden HTML comment 形式の重複防止 marker を構築（task 4.1）
#   入力: $1 = sha (headRefOid), $2 = kind, $3 = tool (省略時 none)
#   出力: stdout に marker 文字列 1 個（末尾改行なし）
#   AC: 6.1, 6.4
#
#   形式: <!-- idd-claude:pr-reviewer sha=<sha> kind=<kind> tool=<tool> -->
#   design.md State / Marker Contract と byte 一致。GitHub 上では非表示。
#   design.md の interface 表は ($1=sha, $2=kind) の 2 引数表記だが、marker 契約は
#   tool= 属性を含むため第 3 引数 tool を追加している（impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_build_marker() {
  local sha="${1:-}"
  local kind="${2:-}"
  local tool="${3:-none}"
  printf '<!-- idd-claude:pr-reviewer sha=%s kind=%s tool=%s -->' "$sha" "$kind" "$tool"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_already_processed: 同一 (sha, kind) marker が既存コメントに在るか判定（task 4.1）
#   入力: $1 = pr_number, $2 = sha, $3 = kind
#   出力: なし
#   戻り値: 0 = 既存（skip すべき）/ 1 = 未存在（処理を続行してよい）
#   AC: 3.3, 6.2, 6.3, NFR 4.1
#
#   - `gh api /repos/$REPO/issues/<n>/comments` で全コメントを取得し、jq で
#     marker（sha と kind の双方一致）の存在を test する（tool 属性は照合に使わない
#     = Decision 6 の (sha, kind) 単位重複判定）。
#   - sha は hex、kind は固定語彙のため正規表現メタ文字を含まず test() に安全。
#   - gh API 失敗時は **安全側（重複投稿回避）** に倒し「既存扱い (rc=0)」で skip。
#     SHA が不変なら次サイクルで再評価されるため self-heal する（NFR 3.1 で WARN 記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_already_processed() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local kind="${3:-}"

  local comments_json
  if ! comments_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pr_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"
    return 0
  fi

  if echo "$comments_json" | jq -e \
      --arg sha "$sha" \
      --arg kind "$kind" \
      'any(.[]; (.body // "") | test("idd-claude:pr-reviewer sha=" + $sha + "[^>]*kind=" + $kind))' \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Issue #403: exec-failed リトライ抑止 / 診断性向上 ─────────────────────────────
#
# 同一 head sha で連続 exec-failed が `PR_REVIEWER_EXEC_FAIL_LIMIT` に達した PR を
# 候補から除外することで、外部レビューツール（codex / antigravity）の rate-limit
# 持続事故を防ぐ。連続失敗カウンタは PR body の hidden marker に永続化する
# （pr-iteration の no-progress-streak 方式と整合 / Req 1.4）。
#
# marker 形式（GitHub UI 上では非表示）:
#   <!-- idd-claude:pr-reviewer-exec-fail-streak sha=<sha> streak=<N> tool=<tool> last-updated=<ISO8601> -->
#
# 主要関数:
#   - pr_extract_exec_fail_streak  : marker から (streak, sha) を抽出（純粋関数）
#   - pr_read_exec_fail_streak     : PR body を取得 → marker から streak を返す
#   - pr_write_exec_fail_streak    : PR body を更新 → marker を新しい値に書き換え
#   - pr_reset_exec_fail_streak    : streak=0 で marker を書き戻し（sha 変化 / 成功時）
#   - pr_increment_exec_fail_streak: exec-failed 確定時の streak+1 永続化
#   - pr_save_stderr_artifact      : stderr 全文を `$HOME/.issue-watcher/...` に保存
#   - pr_truncate_stderr_tail      : stderr の末尾優先抜粋（excerpt 用）
#   - pr_post_exec_fail_escalation_comment: 上限到達時の advisory コメント 1 回投稿
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# pr_extract_exec_fail_streak: marker 文字列から streak と sha を抽出（純粋関数）
#   入力: $1 = pr_body 文字列
#   出力: stdout に `<sha>\t<streak>` の TSV 1 行（marker 不在時は `\t0`）
#   戻り値: 0 固定
#   Req: 1.1, 1.4 / NFR 1.2
#
#   - marker 形式: `<!-- idd-claude:pr-reviewer-exec-fail-streak sha=<sha> streak=<N> ... -->`
#   - 複数 marker が混在する場合は末尾（最新）を採用（pr-iteration と整合）。
# ─────────────────────────────────────────────────────────────────────────────
pr_extract_exec_fail_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    printf '\t0\n'
    return 0
  fi
  local marker_line sha streak
  marker_line=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-reviewer-exec-fail-streak [^>]+' \
    | tail -1)
  if [ -z "$marker_line" ]; then
    printf '\t0\n'
    return 0
  fi
  sha=$(printf '%s' "$marker_line" \
    | grep -oE 'sha=[0-9a-f]+' \
    | head -1 \
    | sed -E 's|sha=||')
  streak=$(printf '%s' "$marker_line" \
    | grep -oE 'streak=[0-9]+' \
    | head -1 \
    | sed -E 's|streak=||')
  printf '%s\t%s\n' "${sha:-}" "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_read_exec_fail_streak: PR body から (recorded_sha, streak) を取得
#   入力: $1 = pr_number
#   出力: stdout に `<recorded_sha>\t<streak>` の TSV 1 行
#   戻り値: 0 固定（取得失敗時は安全側で `\t0` を返す = リトライ抑止寄り）
#   Req: 1.1, 1.4, 1.5 / NFR 1.2
#
#   - gh pr view 失敗時は WARN + `\t0` 返却で安全側に倒す（Req 1.5）。
#   - 観測ログは pr_log で記録するが、stdout は TSV を保つため >&2 へ送る。
# ─────────────────────────────────────────────────────────────────────────────
pr_read_exec_fail_streak() {
  local pr_number="${1:-}"
  local body
  if ! body=$(timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pr_warn "PR #${pr_number}: body 取得に失敗、exec-fail-streak は 0 として扱います"
    printf '\t0\n'
    return 0
  fi
  pr_extract_exec_fail_streak "$body"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_write_exec_fail_streak: PR body の hidden marker を新しい (sha, streak) で書き換え
#   入力: $1 = pr_number, $2 = sha, $3 = streak
#   戻り値: 0 = ok / 1 = body 取得 or 書き込み失敗
#   Req: 1.1, 1.2, 1.3, 1.4, 1.5 / NFR 1.2
#
#   - 既存 marker（同 prefix）は sed で 1 つに集約。無ければ末尾に追記。
#   - 副作用は PR body 書き込み 1 回のみ。冪等性は GitHub 側の latest-wins に委ねる。
#   - 失敗時は WARN を残して 1 を返す（呼び出し側は安全側に倒す）。
# ─────────────────────────────────────────────────────────────────────────────
pr_write_exec_fail_streak() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local streak="${3:-0}"
  local tool="${4:-none}"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pr_warn "PR #${pr_number}: body 取得に失敗、exec-fail-streak の永続化を skip"
    return 1
  fi

  local marker="<!-- idd-claude:pr-reviewer-exec-fail-streak sha=${sha} streak=${streak} tool=${tool} last-updated=${now} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-claude:pr-reviewer-exec-fail-streak '; then
    # 既存 marker を 1 つに集約（複数あった場合も全部置換）
    new_body=$(echo "$body" | sed -E "s|<!-- idd-claude:pr-reviewer-exec-fail-streak [^>]*-->|${marker}|g")
  else
    new_body="${body}

${marker}"
  fi

  if ! timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: PR body への exec-fail-streak marker 書き込みに失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_reset_exec_fail_streak: 連続失敗カウンタをリセット（sha 変化 / 成功到達時）
#   入力: $1 = pr_number, $2 = sha（現在の head sha）, $3 = tool
#   戻り値: 0 固定（書き込み失敗時も呼び出し側の流れを止めない）
#   Req: 1.2, 1.3 / NFR 1.2
#
#   - 旧 streak が既に 0 かつ sha が同一なら no-op（gh 呼び出し回避 / 冪等性）。
#   - それ以外は marker を (sha, 0) で書き戻し、次サイクル以降の起点を更新する。
# ─────────────────────────────────────────────────────────────────────────────
pr_reset_exec_fail_streak() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local tool="${3:-none}"

  local tsv recorded_sha prev_streak
  tsv=$(pr_read_exec_fail_streak "$pr_number")
  recorded_sha=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
  prev_streak=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
  prev_streak="${prev_streak:-0}"

  # 既に 0 かつ sha 一致なら no-op（外部呼び出し回避 / NFR 4.2 冪等性）
  if [ "$prev_streak" = "0" ] && [ "$recorded_sha" = "$sha" ]; then
    return 0
  fi

  pr_write_exec_fail_streak "$pr_number" "$sha" "0" "$tool" || true
  pr_log "PR #${pr_number}: exec-fail-streak reset sha=${sha} tool=${tool} prev_streak=${prev_streak} prev_sha=${recorded_sha:-<none>}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_increment_exec_fail_streak: 連続失敗カウンタを +1 して永続化
#   入力: $1 = pr_number, $2 = sha, $3 = tool
#   出力: stdout に新しい streak 値（整数 1 行）
#   戻り値: 0 = ok / 1 = 永続化失敗（戻り値の streak は呼び出し元で参照可能）
#   Req: 1.1, 1.2 / NFR 1.2
#
#   - 既存 marker の sha が現在 sha と異なる場合は「sha 変化扱い」で 1 から始める
#     （Req 1.2 リセットを増分書き込み側でも fail-safe に保証）。
#   - 永続化失敗時は WARN を残しつつ「streak を加算した値」を stdout に返す
#     （上限到達判定は呼び出し側で行う / Req 1.5 安全側）。
# ─────────────────────────────────────────────────────────────────────────────
pr_increment_exec_fail_streak() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local tool="${3:-none}"

  local tsv recorded_sha prev_streak
  tsv=$(pr_read_exec_fail_streak "$pr_number")
  recorded_sha=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
  prev_streak=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
  prev_streak="${prev_streak:-0}"

  local new_streak
  if [ -n "$recorded_sha" ] && [ "$recorded_sha" != "$sha" ]; then
    # sha が変化していたので 1 から始める（Req 1.2 fail-safe）
    new_streak=1
  else
    new_streak=$((prev_streak + 1))
  fi

  local write_rc=0
  pr_write_exec_fail_streak "$pr_number" "$sha" "$new_streak" "$tool" || write_rc=1
  printf '%s\n' "$new_streak"
  return "$write_rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_exec_fail_limit_reached: 上限到達判定（候補除外 / エスカレーション用）
#   入力: $1 = pr_number, $2 = sha
#   戻り値: 0 = 上限到達（候補から除外） / 1 = 未到達
#   出力: なし
#   Req: 2.1, 2.2, 2.4, 2.5 / NFR 2.1
#
#   - 同一 sha の連続失敗カウンタが `PR_REVIEWER_EXEC_FAIL_LIMIT` 以上なら除外。
#   - 異なる sha が marker に記録されていた場合は除外しない（新 sha では新たにスタート）。
#   - 上限 env 値は本体 Config ブロックで正規化済み（不正値 → 3 / NFR 1.2）。
# ─────────────────────────────────────────────────────────────────────────────
pr_exec_fail_limit_reached() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local limit="${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"

  local tsv recorded_sha streak
  tsv=$(pr_read_exec_fail_streak "$pr_number")
  recorded_sha=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
  streak=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
  streak="${streak:-0}"

  # 記録された sha と現在の sha が異なる → 新 sha では未到達
  if [ -n "$recorded_sha" ] && [ "$recorded_sha" != "$sha" ]; then
    return 1
  fi

  if [ "$streak" -ge "$limit" ] 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_truncate_stderr_tail: stderr ファイル / 文字列を末尾優先で `N` バイトに切り出す
#   入力: $1 = err_file（ファイルパス）, $2 = max_bytes（既定 8192）
#   出力: stdout に末尾優先の抜粋
#   戻り値: 0 固定
#   Req: 3.1, 3.4
#
#   - `tail -c "$max_bytes"` で末尾優先（先頭の prompt echo に埋もれない / Req 3.4）。
#   - ファイル不在 / 読み出し失敗時は空文字列を返す。
# ─────────────────────────────────────────────────────────────────────────────
pr_truncate_stderr_tail() {
  local err_file="${1:-}"
  local max_bytes="${2:-8192}"
  [ -f "$err_file" ] || return 0
  tail -c "$max_bytes" "$err_file" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_save_stderr_artifact: stderr 全文を `$HOME/.issue-watcher/...` に保存
#   入力: $1 = pr_number, $2 = sha, $3 = tool, $4 = err_file
#   出力: stdout に保存先 absolute パス（保存失敗 / 空 stderr / artifact dir 不在時は空）
#   戻り値: 0 固定
#   Req: 3.1, 3.4, 3.5 / NFR 3.2
#
#   - 保存先: `$PR_REVIEWER_STDERR_ARTIFACT_DIR/<sanitized_repo>/pr-<N>-<sha8>-<tool>-<ts>.log`
#   - `PR_REVIEWER_STDERR_ARTIFACT_DIR` が空文字に正規化されていれば skip（fail-safe / Req 3.1 fallback）。
#   - stderr 全体が `PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES` 超なら末尾優先で保存し、
#     観測ログに truncation の旨を記録する（Req 3.4）。
#   - 予測可能名の `/tmp` 直下は使わず `$HOME/.issue-watcher/` 配下に置く（Req 3.5）。
#   - sha は ^[0-9a-f]+$ で事前検証して path 由来のフラグ注入予防（CLAUDE.md 5 番）。
# ─────────────────────────────────────────────────────────────────────────────
pr_save_stderr_artifact() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local tool="${3:-none}"
  local err_file="${4:-}"
  local dir="${PR_REVIEWER_STDERR_ARTIFACT_DIR:-}"
  local max_bytes="${PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES:-1048576}"

  # 保存先未設定 / fail-safe skip
  if [ -z "$dir" ]; then
    return 0
  fi
  # 空 stderr は保存しない（artifact のノイズを抑える）
  if [ ! -s "$err_file" ]; then
    return 0
  fi
  # 入力検証（未信頼値 / CLAUDE.md 5 番）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]+$ ]]; then
    return 0
  fi
  # tool 名を a-z0-9_- に sanitize（marker 由来だが防御的）
  local safe_tool
  safe_tool=$(printf '%s' "$tool" | tr -c 'a-z0-9_-' '_' | head -c 32)
  [ -z "$safe_tool" ] && safe_tool="none"

  # REPO は `owner/name` 形式 → ファイル名向けに `_` 区切りへ変換
  local repo_slug
  repo_slug=$(printf '%s' "${REPO:-unknown}" | tr '/' '_' | tr -c 'A-Za-z0-9_-' '_' | head -c 80)
  [ -z "$repo_slug" ] && repo_slug="unknown"

  local repo_dir="${dir%/}/${repo_slug}"
  if ! mkdir -p "$repo_dir" 2>/dev/null; then
    pr_warn "PR #${pr_number}: artifact dir '${repo_dir}' の作成に失敗、保存を skip"
    return 0
  fi

  local sha8="${sha:0:8}"
  local ts
  ts=$(date -u '+%Y%m%dT%H%M%SZ')
  local artifact_path="${repo_dir}/pr-${pr_number}-${sha8}-${safe_tool}-${ts}.log"

  local total_bytes truncated="false"
  total_bytes=$(wc -c < "$err_file" 2>/dev/null | tr -d ' ')
  total_bytes="${total_bytes:-0}"

  if [ "$total_bytes" -gt "$max_bytes" ] 2>/dev/null; then
    # 1MB 超は末尾優先で保存し、truncation の旨をログ記録（Req 3.4）
    tail -c "$max_bytes" "$err_file" >"$artifact_path" 2>/dev/null || {
      pr_warn "PR #${pr_number}: artifact 末尾抜粋保存に失敗 path='${artifact_path}'"
      return 0
    }
    truncated="true"
    pr_log "PR #${pr_number}: stderr artifact truncated total=${total_bytes}B saved=${max_bytes}B (末尾優先) path='${artifact_path}'"
  else
    if ! cp -f "$err_file" "$artifact_path" 2>/dev/null; then
      pr_warn "PR #${pr_number}: artifact 保存に失敗 path='${artifact_path}'"
      return 0
    fi
    pr_log "PR #${pr_number}: stderr artifact saved bytes=${total_bytes} path='${artifact_path}' truncated=${truncated}"
  fi

  printf '%s' "$artifact_path"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_exec_fail_escalation_comment: 上限到達時の advisory コメントを 1 回投稿
#   入力: $1 = pr_number, $2 = sha, $3 = tool, $4 = streak（記録された連続失敗回数）
#   戻り値: 0 = ok（重複 skip 含む） / 1 = 投稿失敗
#   Req: 2.3, 2.7
#
#   - 同一 (sha, kind=exec-fail-escalated) marker が既存なら再投稿しない（重複防止 / Req 2.3）。
#   - ラベル付与は行わない（`claude-failed` / `needs-quota-wait` との重複セマンティクスを
#     避ける / 要件 Open Questions の安全側デフォルト / Req 2.7）。
#   - 本文に運用者向け復旧手順（rate-limit 解消待ち / 新 commit push / 連続失敗回数）を含める。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_exec_fail_escalation_comment() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local tool="${3:-none}"
  local streak="${4:-0}"
  local limit="${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"

  # 重複防止: (sha, kind=exec-fail-escalated) marker を流用（pr_already_processed と整合）
  if pr_already_processed "$pr_number" "$sha" "exec-fail-escalated"; then
    pr_log "PR #${pr_number}: kind=exec-fail-escalated sha=${sha} の advisory コメントは既存のため再投稿しません"
    return 0
  fi

  local marker body detail
  marker=$(pr_build_marker "$sha" "exec-fail-escalated" "$tool")
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートはマークダウン記法のリテラル
  detail=$(cat <<__ESCALATION_EOF__
レビューツール \`${tool}\` の実行失敗（\`kind=exec-failed\`）が同一 head sha (\`${sha}\`) で **${streak} 回連続** したため、本 PR への自動レビュー実行を一時停止しました（上限値: ${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}）。

**主な原因（推定）**:
- 外部レビューツール側の rate-limit（HTTP 429）/ API quota 到達
- timeout / network 一時障害
- ツール側の bug / 設定不備

**自動再開条件**:
- 新しい commit を本 PR に push して **head sha を変化** させる → 連続失敗カウンタは自動リセットされ、次サイクルから通常通りレビュー実行が再開されます

**運用者対応**:
1. 直近の \`exec-failed\` コメントに記載された stderr 抜粋 / artifact ファイルを確認し、原因を特定してください
2. rate-limit / quota が原因の場合は、外部ツールの quota 復旧を待ってから新 commit を push してください
3. ツール側の不具合が疑われる場合は \`PR_REVIEWER_CODEX_CMD\` / \`PR_REVIEWER_ANTIGRAVITY_CMD\` の設定を見直してください

> 本通知は **advisory** であり、ラベル付与・auto-merge ブロック等は行いません。
__ESCALATION_EOF__
)
  body=$(printf '## 自動レビュー: 連続失敗による一時停止\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "${PR_REVIEWER_GIT_TIMEOUT:-120}" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: exec-fail-escalated advisory コメントの投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: exec-fail-escalated advisory コメント投稿 sha=${sha} tool=${tool} streak=${streak} limit=${limit}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_fetch_candidate_prs: 候補 PR を JSON 配列で返す（task 4.2）
#   出力: stdout に jq 配列形式の JSON 1 行（候補なし / 失敗時は "[]"）
#   戻り値: 0 固定（失敗は degraded path = "[]" + WARN に倒す）
#   AC: 7.1, 7.2, 7.3
#
#   - server-side: `--state open --search "-draft:true"`（open + draft 除外、AC 7.1/7.2）
#   - client-side fail-safe: `select(.isDraft == false)`（draft 二重防御、AC 7.2）+
#     head pattern 一致（PR_REVIEWER_HEAD_PATTERN、既定 `^claude/`）+
#     fork 除外（headRepositoryOwner.login == owner）。既存 pi_fetch_candidate_prs 踏襲。
#   - PR を伴わない Issue は gh pr list の対象外のため自然に除外される（AC 7.3）。
#   - 上限件数 (PR_REVIEWER_MAX_PRS) の truncate は呼び出し元 process_pr_reviewer で
#     total / target / overflow をログ出力しながら行う（NFR 3.1 観測性、pi 踏襲）。
# ─────────────────────────────────────────────────────────────────────────────
pr_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "-draft:true" \
      --json number,headRefName,headRefOid,baseRefName,isDraft,url,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    pr_warn "候補 PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  echo "$prs_json" | jq \
    --arg pattern "$PR_REVIEWER_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(.headRefName | test($pattern))
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_default_prompt: 内蔵 default レビュープロンプトを stdout に出力（task 5.1）
#   入力: なし
#   出力: stdout に prompt 本文（{BASE} / {HEAD} / {PR} は未置換のまま）
#
#   design.md「Default Review Prompt」節の本文と **byte 一致**させること。
#   quoted heredoc（'EOF'）なので {BASE} 等・`$(...)` は展開されずリテラル保持される。
# ─────────────────────────────────────────────────────────────────────────────
pr_default_prompt() {
  cat <<'PR_REVIEWER_DEFAULT_PROMPT_EOF'
あなたは熟練のソフトウェアレビュアーです。base ブランチ {BASE} と head ブランチ {HEAD}
の差分（git diff {BASE}...{HEAD}）を対象に PR #{PR} をレビューしてください。

# 網羅性要求（最優先）
- 差分全体を 1 パスで網羅的に走査し、検出した指摘は **列挙漏れなく一度に** 出力すること。
- 同一観点で複数箇所に同種の問題がある場合は **drip-feed（小出し）せず**、最初のパスで
  該当箇所をすべて列挙すること。「他にも同様の箇所がある」等の曖昧な要約で済ませない。
- 1 パスで全件出すことを優先し、レビュー往復回数を最小化する（収束遅延を避ける）。
- 重要度の濃淡付け（high / medium / low）は付与するが、low を理由に列挙を省略しないこと。

# レビュー観点（優先度順）
1. 正確性のバグ: ロジック誤り・境界条件・null/空入力・競合・例外未処理
2. 受入基準の未カバー: docs/specs/ に requirements.md があれば AC と差分を突き合わせる
3. テスト不足: 変更された分岐に対応するテストの欠落
4. セキュリティ退行: 入力検証・認証・機密情報露出・コマンドインジェクション
5. 後方互換性の破壊: 既存 env var / 出力契約の変更

# spec 文書間整合チェック（条件付き適用）
差分に `docs/specs/<番号>-<slug>/` 配下のファイル変更（`requirements.md` / `design.md` /
`tasks.md` のいずれか）が含まれる **場合に限り**、以下の整合性を 1 パス目で突き合わせて
検査すること。差分に `docs/specs/` 配下のファイルが含まれない PR では本節をスキップし、
上記「レビュー観点」の実施を阻害しないこと。

- requirements ⇄ design: `requirements.md` の各 AC（numeric ID）が `design.md` で
  カバーされているか（Components / Interfaces / Traceability 等で対応関係が追えるか）。
- design ⇄ tasks: `design.md` の Components / Interfaces が `tasks.md` のタスクで
  実装手順化されているか（実装漏れ・タスク分割の不足が無いか）。
- tasks ⇄ requirements: `tasks.md` の各タスクの `_Requirements:_` アノテーションが
  `requirements.md` に実在する AC ID を参照しているか（存在しない ID への参照や
  欠落が無いか）。

不整合は通常のレビュー指摘と同じ `[high|medium|low] <file>:<line> — <内容と根拠>` 形式で
「指摘事項」セクションに **列挙漏れなく** 一括で出力すること。

# 制約
- ファイルを編集しないこと。所見の報告のみ（read-only）。
- 差分に実在する file:line を根拠として必ず引用する。推測で書かない。
- スタイル / lint レベルの指摘は対象外。

# 出力（日本語・Markdown、この構造を厳守）
## 概要
<2〜3 文の総評>
## 指摘事項
- [high|medium|low] <file>:<line> — <内容と根拠>
（指摘が無ければ「指摘なし」）
## 結論
（本文の最終行に、次のいずれか 1 行だけを単独で出力すること）
VERDICT: needs-iteration
VERDICT: approve
PR_REVIEWER_DEFAULT_PROMPT_EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_build_prompt_file: レビュー prompt を解決し一時ファイルに書き出す（task 5.1）
#   入力: $1 = pr_number, $2 = base_ref, $3 = head_ref
#   出力: stdout に一時ファイルパス（呼び出し元が trap で削除）
#   戻り値: 0 = ok / 1 = mktemp 失敗
#   AC: 4.3
#
#   - 解決順序: PR_REVIEWER_PROMPT が非空 → それ。空なら内蔵 default（Decision 9 で
#     PR_REVIEWER_<TOOL>_PROMPT は YAGNI として不採用 / design 確認事項 4）。
#   - 解決済み prompt 中の {BASE} / {HEAD} / {PR} を bash パラメータ置換でリテラル置換。
#   - 一時ファイル経由で argv に渡すことで prompt 本文を cmd 文字列に注入しない
#     （Security Considerations / Decision 9）。
#   - stdout にファイルパスを返す契約のため、本関数内では pr_log を使わず
#     pr_warn（stderr）のみ使用する（stdout 汚染防止）。
# ─────────────────────────────────────────────────────────────────────────────
pr_build_prompt_file() {
  local pr_number="$1"
  local base_ref="$2"
  local head_ref="$3"

  local prompt="${PR_REVIEWER_PROMPT:-}"
  if [ -z "$prompt" ]; then
    prompt="$(pr_default_prompt)"
  fi

  prompt="${prompt//\{BASE\}/$base_ref}"
  prompt="${prompt//\{HEAD\}/$head_ref}"
  prompt="${prompt//\{PR\}/$pr_number}"

  local tmpfile
  if ! tmpfile=$(mktemp -t idd-claude-pr-reviewer.XXXXXX 2>/dev/null); then
    pr_warn "PR #${pr_number}: prompt 一時ファイルの作成に失敗"
    return 1
  fi
  printf '%s\n' "$prompt" > "$tmpfile"
  printf '%s' "$tmpfile"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_substitute_placeholders: 実行コマンドのプレースホルダ置換（task 5.1）
#   入力: $1 = cmd_template, $2 = base_ref, $3 = head_ref, $4 = pr_number,
#         $5 = prompt_file_path
#   出力: stdout に置換済みコマンド文字列
#   戻り値: 0 = ok / 1 = metachar 検出（呼び出し元は当該 PR を skip）
#   AC: 4.3
#
#   - 置換対象: {BASE} / {HEAD} / {PR} / {PROMPT_FILE}
#   - 注入値（GitHub 由来の branch 名 / PR 番号）に shell metacharacter
#     （`;` `|` `&` `` ` `` `$(`）が混入していないか検査し、検出時は WARN + skip
#     （GitHub branch 命名規約では発生しないが防御的設計 / Security Considerations）。
#   - prompt_file_path は mktemp 由来の自前パスのため検査対象外。cmd_template は
#     運用者入力（信頼境界内）かつ正当な `$(cat '...')` を含むため検査しない。
#   - stdout に結果を返す契約のため pr_log は使わず pr_warn（stderr）のみ使用。
# ─────────────────────────────────────────────────────────────────────────────
pr_substitute_placeholders() {
  local cmd_template="$1"
  local base_ref="$2"
  local head_ref="$3"
  local pr_number="$4"
  local prompt_file="$5"

  local v
  for v in "$base_ref" "$head_ref" "$pr_number"; do
    # shellcheck disable=SC2016  # 単一引用符内の $( は意図した「リテラル文字列の検出パターン」
    case "$v" in
      *';'* | *'|'* | *'&'* | *'`'* | *'$('* )
        pr_warn "placeholder 値に shell metacharacter を検出（base='${base_ref}' head='${head_ref}' pr='${pr_number}'）。当該 PR を skip します"
        return 1
        ;;
    esac
  done

  local out="$cmd_template"
  out="${out//\{BASE\}/$base_ref}"
  out="${out//\{HEAD\}/$head_ref}"
  out="${out//\{PR\}/$pr_number}"
  out="${out//\{PROMPT_FILE\}/$prompt_file}"
  printf '%s' "$out"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_execute_review_command: head checkout + レビュー実行 + read-only 検査（task 5.2）
#   入力: $1 = head_ref, $2 = resolved_cmd, $3 = tool,
#         $4 = out_file, $5 = err_file, $6 = result_file
#   出力: out_file へ stdout、err_file へ stderr、result_file へ実行結果トークン
#   戻り値: 0 固定（結果判定は result_file 経由）
#   AC: 4.1, 4.2, 4.5（read-only invariant: Decision 8 / eval 不使用: Decision 9）
#
#   result_file に書き出すトークン（呼び出し元が parse）:
#     - `fetch-fail`         : git fetch 失敗（一時的 / コメント投稿しない）
#     - `checkout-fail`      : git checkout 失敗（同上）
#     - `ran:<rc>:clean`     : 実行完了、ワークツリー変更なし（rc=コマンド終了コード）
#     - `ran:<rc>:modified`  : 実行完了したがワークツリーを変更（read-only 違反）
#
#   - design.md interface 表は ($1=command_string, $2=tool) の 2 引数 + stdout 返却
#     表記だが、(a) head checkout を本関数内で行う（AC 4.1）/ (b) stdout・stderr・
#     実行結果を分離して呼び出し元へ渡す必要がある（exec-failed コメントへ stderr
#     1KB 抜粋を含めるため / AC 4.5）ため、tempfile 渡しに拡張している
#     （impl-notes.md に記録）。
#   - サブシェル + EXIT trap で必ず BASE_BRANCH に戻す（副作用を残さない invariant）。
#   - `eval` は使わず `bash -c "$resolved_cmd"` で subshell に閉じ込める（Decision 9）。
#   - 実行直後に `git status --porcelain` でワークツリー変更を検査し、検出時は
#     `git checkout -- .` で tracked 変更を破棄し `modified` を報告（Decision 8）。
# ─────────────────────────────────────────────────────────────────────────────
pr_execute_review_command() {
  local head_ref="$1"
  local resolved_cmd="$2"
  local tool="$3"
  local out_file="$4"
  local err_file="$5"
  local result_file="$6"

  : > "$out_file"
  : > "$err_file"
  : > "$result_file"

  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin 最新へ追従、AC 4.1）
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の git fetch に失敗"
      printf 'fetch-fail\n' > "$result_file"
      exit 0
    fi
    if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pr_warn "head '${head_ref}' の checkout に失敗"
      printf 'checkout-fail\n' > "$result_file"
      exit 0
    fi

    # レビュー実行（AC 4.2、eval 不使用 / Decision 9。stdout / stderr を分離保存）
    local exec_rc=0
    timeout "$PR_REVIEWER_EXEC_TIMEOUT" bash -c "$resolved_cmd" >"$out_file" 2>"$err_file" || exec_rc=$?

    # read-only invariant 検査（Decision 8）。untracked は `git clean` で消すと
    # `.antigravitycli/` 等の運用ツール生成物を巻き込むため tracked 変更のみ破棄する。
    local wsmod="clean"
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git checkout -- . >/dev/null 2>&1 || true
      wsmod="modified"
    fi
    printf 'ran:%s:%s\n' "$exec_rc" "$wsmod" > "$result_file"
    exit 0
  )
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_review_comment: レビュー結果コメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = tool (省略時 none)
#   戻り値: 0 = ok / 1 = 投稿失敗
#   AC: 4.4, 6.1, 6.4
#
#   - review_text 末尾に hidden marker（kind=review）を付与し gh pr comment で投稿。
#   - design.md interface 表は ($1,$2,$3) の 3 引数表記だが marker の tool= 属性
#     のため第 4 引数 tool を追加（pr_build_marker と同様 / impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_review_comment() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local tool="${4:-none}"

  local marker body
  marker=$(pr_build_marker "$sha" "review" "$tool")
  body=$(printf '%s\n\n%s' "$review_text" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: レビュー結果コメントの投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: レビュー結果コメント投稿 kind=review tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_post_error_comment: エラーコメントを投稿（task 5.3）
#   入力: $1 = pr_number, $2 = sha, $3 = kind, $4 = detail, $5 = tool (省略時 none)
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗
#   AC: 2.4, 3.1, 3.2, 3.3, 3.4, 4.5, 6.1, 6.4
#
#   - 本文冒頭に運用者が人間判断で識別できる見出し `## 自動レビューエラー`（AC 3.4）。
#   - 同一 (sha, kind) marker が既存なら再投稿しない（AC 3.3 / 6.2、冪等 NFR 4.1）。
#   - design.md interface 表は ($1〜$4) の 4 引数表記だが marker の tool= 属性のため
#     第 5 引数 tool を追加（impl-notes.md に記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_post_error_comment() {
  local pr_number="$1"
  local sha="$2"
  local kind="$3"
  local detail="$4"
  local tool="${5:-none}"

  # AC 3.3 / 6.2: 同一 (sha, kind) が既存なら再投稿しない
  if pr_already_processed "$pr_number" "$sha" "$kind"; then
    pr_log "PR #${pr_number}: kind=${kind} sha=${sha} のエラーコメントは既存のため再投稿しません（重複防止）"
    return 0
  fi

  local marker body
  marker=$(pr_build_marker "$sha" "$kind" "$tool")
  body=$(printf '## 自動レビューエラー\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: エラーコメント (kind=${kind}) の投稿に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: エラーコメント投稿 kind=${kind} tool=${tool} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_detect_iteration_keyword: レビュー結果から VERDICT token を検出（task 6）
#   入力: $1 = pr_number（ログ用）, $2 = review_text
#   出力: stdout にマッチ件数（整数。0 のとき "0"）
#   戻り値: 0 固定
#   AC: 5.1, 5.3, 5.4
#
#   - PR_REVIEWER_ITERATION_PATTERN（既定は line-anchored の
#     `^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$`、Decision 4）を
#     `grep -E -i -c` で照合し、マッチ行数を返す。
#   - 件数とパターンを観測ログに記録（AC 5.4 / NFR 3.1）。stdout に件数を返す契約の
#     ため、ログは pr_log を stderr へリダイレクトして出力する（stdout 汚染防止）。
#   - ラベル付与は呼び出し元（件数 > 0 のとき pr_add_iteration_label）が行う。
# ─────────────────────────────────────────────────────────────────────────────
pr_detect_iteration_keyword() {
  local pr_number="$1"
  local review_text="$2"
  local pattern="${PR_REVIEWER_ITERATION_PATTERN}"

  local count
  # `--` でパターン以降をオプション解釈から切り離し、`-f...` 等によるフラグ注入を防ぐ
  # （`PR_REVIEWER_ITERATION_PATTERN` は operator 設定だが安価な hardening）。
  count=$(printf '%s' "$review_text" | grep -E -i -c -- "$pattern" 2>/dev/null || true)
  count="${count:-0}"

  pr_log "PR #${pr_number}: iteration keyword 検出 matches=${count} pattern='${pattern}'" >&2
  printf '%s' "$count"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_add_iteration_label: needs-iteration ラベルを付与（task 6）
#   入力: $1 = pr_number
#   戻り値: 0 = ok / 1 = 付与失敗
#   AC: 5.1, 5.2
#
#   - `gh pr edit --add-label` は既付与で冪等（再付与は no-op、AC 5.2）。
#   - 既存 PR Iteration Processor (#26) は本ラベルを起動条件とするため、付与により
#     次サイクルで iteration ループへ自動接続される。
# ─────────────────────────────────────────────────────────────────────────────
pr_add_iteration_label() {
  local pr_number="$1"
  if ! timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_ITERATION" >/dev/null 2>&1; then
    pr_warn "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルの付与に失敗"
    return 1
  fi
  pr_log "PR #${pr_number}: ${LABEL_NEEDS_ITERATION} ラベルを付与（既付与なら冪等 no-op）"
  return 0
}

# ─── Issue #349: Commit Status Publishing ─────────────────────────────────────
#
# codex / antigravity の VERDICT と Claude Reviewer の RESULT を GitHub Commit Status
# API (`POST /repos/{owner}/{repo}/statuses/{sha}`) 経由で `codex-review` /
# `claude-review` context 名の commit status として publish するためのヘルパー群。
# auto-merge ゲートを required status checks で成立させるための前提整備（D-03 / D-04）。
#
# AND 二重 opt-in:
#   - `PR_REVIEWER_STATUS_CHECK_ENABLED=true` 厳密一致（issue-watcher.sh 本体で正規化済）
#   - `FULL_AUTO_ENABLED=true` 厳密一致（#348 kill switch / 同様に正規化済）
#   どちらか一方でも `=true` 以外なら publish を行わず即 return（Req 1.2, 1.4 / 6.1）。
#
# gate OFF 時の suppression ログは「サイクルあたり最大 1 行」に制限する（Req 7.2）。
# 単一サイクル内で複数の publish 試行（codex 用 + claude 用、複数 PR）が同一 gate OFF
# 状態で suppress される場合でも、`PR_STATUS_GATE_SUPPRESS_LOGGED` フラグで重複出力を抑止
# する。`FULL_AUTO_ENABLED` 側の suppression は #348 既存ログに委ね（重複させない / Req 7.3）。

# ─────────────────────────────────────────────────────────────────────────────
# pr_status_check_enabled: AND 二重 opt-in gate の評価（Req 1.2, 1.4）
#   入力: 環境変数のみ
#   出力: なし
#   戻り値: 0 = 両 gate 有効（publish 許可）/ 1 = いずれかの gate が OFF（publish 抑止）
#
#   - `PR_REVIEWER_STATUS_CHECK_ENABLED` と `FULL_AUTO_ENABLED` を独立に評価し、
#     **双方** が `=true` 厳密一致の場合のみ rc=0 を返す。
#   - 値正規化（unset / 空 / `True` / `TRUE` / `1` / typo の安全側 OFF 化）は
#     issue-watcher.sh 本体の Config ブロックで完了している前提だが、本関数は遅延
#     束縛のため `${VAR:-false}` で fallback して NFR 1.1 安全側に倒す。
# ─────────────────────────────────────────────────────────────────────────────
pr_status_check_enabled() {
  if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  if [ "${FULL_AUTO_ENABLED:-false}" != "true" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_commit_status: GitHub Commit Status API 呼び出しの低レベルヘルパー
#   入力: $1 = pr_number, $2 = sha, $3 = context, $4 = state,
#         $5 = description, $6 = target_url
#   出力: なし（observe 用 log は pr_log / pr_warn）
#   戻り値: 0 = publish 成功 / 1 = gate OFF（no-op）/ 2 = 入力検証失敗 /
#           3 = API 呼び出し失敗
#   AC: 1.2, 1.4, 2.1, 2.2, 3.1, 3.2, 4.1, 5.1, 5.2, 5.3, 5.4, 7.1
#   NFR: 1.1, 1.2, 1.3, 1.4, 2.1
#
#   - AND 二重 opt-in の gate を先頭で評価し、OFF なら外部副作用ゼロで 1 を返す
#     （Req 6.1 / 1.4）。suppression 観測は cycle あたり 1 行に制限（Req 7.2）。
#   - 未信頼入力（sha / PR 番号）の使用前検証を厳格に行い、不正値時は publish せず
#     2 を返す（NFR 1.3, 1.4）。
#   - description は GitHub 仕様の 140 文字制限内かつ運用要件の 72 文字以内に短縮。
#   - state は GitHub Commit Status API の許容値 `success` / `failure` / `pending` /
#     `error` のいずれかに正規化（本仕様では `success` / `failure` のみ使用 / AC 2.1, 2.2）。
#   - 失敗時は HTTP status / stderr を含めて pr_warn し、silent fail にしない（AC 5.1, 5.4）。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_commit_status() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local context="${3:-}"
  local state="${4:-}"
  local description="${5:-}"
  local target_url="${6:-}"

  # AND 二重 opt-in gate（Req 1.2, 1.4, 6.1）
  if ! pr_status_check_enabled; then
    # cycle あたり 1 行に制限（Req 7.2）。`FULL_AUTO_ENABLED` OFF 起因は #348 既存ログに
    # 委ね、本関数では `PR_REVIEWER_STATUS_CHECK_ENABLED` OFF 起因のみログする（Req 7.3）。
    if [ "${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}" != "true" ] \
        && [ "${PR_STATUS_GATE_SUPPRESS_LOGGED:-0}" != "1" ]; then
      pr_log "commit status publish suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED gate (cycle no-op)"
      PR_STATUS_GATE_SUPPRESS_LOGGED=1
    fi
    return 1
  fi

  # ── 未信頼入力の検証（NFR 1.3, 1.4）─────────────────────────────────────────
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pr_warn "commit status publish: 無効な PR 番号 '${pr_number}' を検出（context=${context} state=${state}）"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    pr_warn "commit status publish: 無効な sha '${sha}' を検出（pr=#${pr_number} context=${context} state=${state}）"
    return 2
  fi
  case "$state" in
    success|failure|pending|error) ;;
    *)
      pr_warn "commit status publish: 無効な state '${state}'（pr=#${pr_number} sha=${sha} context=${context}）"
      return 2
      ;;
  esac
  case "$context" in
    "")
      pr_warn "commit status publish: context が空（pr=#${pr_number} sha=${sha} state=${state}）"
      return 2
      ;;
  esac

  # description は 72 文字以内に短縮（AC 2.3, 3.3）。空入力時は context+state から既定値を生成。
  if [ -z "$description" ]; then
    description="${context}: ${state}"
  fi
  if [ "${#description}" -gt 72 ]; then
    description="${description:0:72}"
  fi

  # target_url は空でも GitHub API は受け付けるが、空文字は `-f target_url=` で渡すと
  # 不正な空 URL とみなされる可能性があるため、空時は引数自体を渡さない分岐を取る。
  # ── API call: gh api -X POST ────────────────────────────────────────────────
  # gh は `-f key=value` で POST body を application/json として構築するため、
  # 未信頼値の inline 展開リスクは低い。URL path 部の sha / repo owner は事前検証済。
  local api_path="repos/${REPO}/statuses/${sha}"
  local api_stderr_tmp
  api_stderr_tmp=$(mktemp -t idd-claude-pr-status.XXXXXX 2>/dev/null || echo "")

  local api_rc=0
  if [ -n "$target_url" ]; then
    if [ -n "$api_stderr_tmp" ]; then
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          -f target_url="$target_url" \
          >/dev/null 2>"$api_stderr_tmp" || api_rc=$?
    else
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          -f target_url="$target_url" \
          >/dev/null 2>&1 || api_rc=$?
    fi
  else
    if [ -n "$api_stderr_tmp" ]; then
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          >/dev/null 2>"$api_stderr_tmp" || api_rc=$?
    else
      timeout "$PR_REVIEWER_GIT_TIMEOUT" \
        gh api -X POST "$api_path" \
          -f state="$state" \
          -f context="$context" \
          -f description="$description" \
          >/dev/null 2>&1 || api_rc=$?
    fi
  fi

  if [ "$api_rc" -ne 0 ]; then
    # AC 5.1, 5.2, 5.4: 失敗時は WARN ログに PR / sha / context / state / 終了コード /
    # stderr 抜粋を残す。silent fail にしない。パイプライン継続は呼び出し側の責務。
    local err_tail=""
    if [ -n "$api_stderr_tmp" ] && [ -f "$api_stderr_tmp" ]; then
      err_tail=$(tail -c 512 "$api_stderr_tmp" 2>/dev/null || true)
      rm -f "$api_stderr_tmp" 2>/dev/null || true
    fi
    pr_warn "commit status publish FAILED: pr=#${pr_number} sha=${sha} context=${context} state=${state} rc=${api_rc} stderr='${err_tail//$'\n'/ }'"
    return 3
  fi

  if [ -n "$api_stderr_tmp" ]; then
    rm -f "$api_stderr_tmp" 2>/dev/null || true
  fi
  # AC 7.1: 成功時 1 行 log（PR / sha / context / state）
  pr_log "commit status published: pr=#${pr_number} sha=${sha} context=${context} state=${state}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_codex_status: codex / antigravity の VERDICT から commit status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = review_text, $4 = pr_url
#   出力: なし（log のみ）
#   戻り値: pr_publish_commit_status の戻り値をそのまま返す（0/1/2/3）
#   AC: 2.1, 2.2, 2.3, 2.4, 2.5
#
#   - review_text の最終行 `VERDICT: approve` / `VERDICT: needs-iteration` から
#     state を解決する（approve → success、needs-iteration → failure）。
#   - antigravity 利用時も同じ `codex-review` context を共有する（AC 2.5）。
#   - target_url はコメント permalink を取得できないため PR URL に倒す（AC 2.4 fallback）。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_codex_status() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"
  local pr_url="$4"

  # VERDICT 検出: pr_detect_iteration_keyword が >0 を返せば needs-iteration（=failure）。
  # pr_detect_iteration_keyword は PR_REVIEWER_ITERATION_PATTERN を用いるため挙動が一貫する。
  local match_count
  match_count=$(pr_detect_iteration_keyword "$pr_number" "$review_text")
  match_count="${match_count:-0}"

  local state description
  if [ "$match_count" -gt 0 ] 2>/dev/null; then
    state="failure"
    description="codex: needs-iteration"
  else
    state="success"
    description="codex: approve"
  fi

  pr_publish_commit_status "$pr_number" "$sha" "codex-review" "$state" "$description" "$pr_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_claude_status: Claude Reviewer の RESULT から commit status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = result (approve|reject), $4 = target_url
#   出力: なし（log のみ）
#   戻り値: pr_publish_commit_status の戻り値（0/1/2/3）/ 4 = 不正な result
#   AC: 3.1, 3.2, 3.3, 3.4, 3.5
#
#   - 呼び出し元（issue-watcher.sh 本体 / run_reviewer_stage 直後）が
#     `parse_review_result` で result を抽出してから本関数を呼ぶ前提。
#   - approve → success / reject → failure。`parse_review_result` の戻り値 0 を伴う
#     場合のみ呼ばれる前提のため、本関数では result の値検証のみ行う。
#   - target_url は review-notes.md の blob URL（呼び出し側で組み立て）を期待するが、
#     空文字なら pr_publish_commit_status 側で省略される。
# ─────────────────────────────────────────────────────────────────────────────
pr_publish_claude_status() {
  local pr_number="$1"
  local sha="$2"
  local result="$3"
  local target_url="${4:-}"

  local state description
  case "$result" in
    approve)
      state="success"
      description="claude: approve"
      ;;
    reject)
      state="failure"
      description="claude: reject"
      ;;
    *)
      pr_warn "claude-review status publish: 不正な result '${result}'（pr=#${pr_number} sha=${sha}）"
      return 4
      ;;
  esac

  pr_publish_commit_status "$pr_number" "$sha" "claude-review" "$state" "$description" "$target_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_publish_claude_status_from_branch: PR が存在する状態で claude-review status を
#   publish する catch-up 経路（Issue #374）。
#   入力: $1 = pr_number, $2 = sha, $3 = head_ref（例: claude/issue-123-impl-foo）,
#         $4 = pr_url（target_url fallback 用）
#   出力: なし（log のみ）
#   戻り値: 0 固定（best-effort / skip / publish 失敗いずれもパイプライン継続）
#
#   背景（Issue #374）:
#     per-task ループ運用（PER_TASK_LOOP_ENABLED=true）では `publish_claude_review_status`
#     が Reviewer round=1〜3 直後に呼ばれる時系列が PjM の impl PR 作成より前になるため、
#     `gh pr list --head <branch>` で PR が解決できず WARN skip で終わってしまう。
#     本関数は `process_pr_reviewer` の review loop（open PR を scan する経路）から
#     呼ばれることで「PR が GitHub 側に存在する状態」を構造的に保証し、AND 二重 opt-in
#     成立時の claude-review status を確実に publish する catch-up 経路を提供する。
#
#   設計判断:
#     - AND 二重 opt-in（`pr_status_check_enabled`）成立時のみ動作。OFF は外部副作用ゼロで
#       即 return（Req 5.1, 5.2 / NFR 1.1）。
#     - head_ref から issue 番号を抽出（`claude/issue-<N>-...`）。一致しなければ silent skip
#       （他 head pattern は本機能対象外）。
#     - workspace は呼び出し元 pr_run_review_for_pr 完了時点で BASE_BRANCH に復帰している
#       前提のため、head 側の `docs/specs/<N>-*/review-notes.md` を `git ls-tree` + `git show`
#       で読み出す（checkout 不要 / 副作用ゼロ）。
#     - 既存 `parse_review_result` を呼び出して RESULT を抽出する（contract 流用 / NFR 1.3）。
#     - 既存 `pr_publish_claude_status` をそのまま呼ぶ（codex 経路と対称 / API 経路は #349 完成形を維持）。
#     - PR 未解決 / file 不在 / parse 失敗いずれも WARN を 1 行残して return 0
#       （silent fail 禁止 / Req 3.1〜3.5）。
pr_publish_claude_status_from_branch() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local head_ref="${3:-}"
  local pr_url="${4:-}"

  # AND 二重 opt-in 早期判定（Req 5.1, 5.2 / NFR 1.1）
  if ! pr_status_check_enabled; then
    # suppression ログは pr_publish_commit_status 側の cycle あたり 1 行制限に委ねる
    # （本関数で重複ログを出さない / Req 5.5 / NFR 3.3）。
    return 0
  fi

  # head_ref から issue 番号を抽出（claude/issue-<N>-...）
  local issue_number=""
  if [[ "$head_ref" =~ ^claude/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    # 本関数対象外 head（design / 他 prefix 等）→ silent skip
    return 0
  fi

  # spec dir を origin/$head_ref の tree から解決（cwd は呼び出し元で REPO_DIR / NFR 1.1）。
  # `git ls-tree --name-only` で `docs/specs/<N>-<slug>/` の直下エントリ群を列挙し、
  # `<N>-` で始まる最初のディレクトリを採用する。
  # `--` でオプション解釈を打ち切り（path 由来のフラグ注入予防 / 既存 hardening 同方針）。
  local tree_out spec_dir_rel=""
  if ! tree_out=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      git ls-tree --name-only "origin/${head_ref}" -- "docs/specs/" 2>/dev/null); then
    pr_warn "claude-review status publish (catch-up): docs/specs 列挙失敗 branch=${head_ref} pr=#${pr_number} reason=ls-tree-failed"
    return 0
  fi
  # `docs/specs/<N>-...` 形式の path から `<N>-` で始まるディレクトリを抽出
  spec_dir_rel=$(echo "$tree_out" \
    | awk -v n="${issue_number}-" -F/ '$3 != "" && index($3, n) == 1 { print "docs/specs/" $3; exit }')
  if [ -z "$spec_dir_rel" ]; then
    pr_warn "claude-review status publish (catch-up): docs/specs/${issue_number}-* 不在 branch=${head_ref} pr=#${pr_number} reason=spec-dir-not-found"
    return 0
  fi

  local notes_rel="${spec_dir_rel}/review-notes.md"
  # review-notes.md を head から取得（cat-file -e で存在確認 → show で内容取得）
  if ! git cat-file -e "origin/${head_ref}:${notes_rel}" 2>/dev/null; then
    pr_warn "claude-review status publish (catch-up): review-notes.md 不在 branch=${head_ref} pr=#${pr_number} path='${notes_rel}' reason=file-not-found"
    return 0
  fi

  local notes_tmp
  notes_tmp=$(mktemp -t idd-claude-pr-claude-notes.XXXXXX 2>/dev/null || mktemp)
  if ! git show "origin/${head_ref}:${notes_rel}" >"$notes_tmp" 2>/dev/null; then
    pr_warn "claude-review status publish (catch-up): review-notes.md 取得失敗 branch=${head_ref} pr=#${pr_number} path='${notes_rel}' reason=git-show-failed"
    rm -f "$notes_tmp" 2>/dev/null || true
    return 0
  fi

  # parse_review_result は issue-watcher.sh 本体で定義（モジュール load 後）。
  # 万一未ロード状態で呼ばれた場合は silent skip（NFR 1.1 安全側）。
  if ! declare -F parse_review_result >/dev/null 2>&1; then
    pr_warn "claude-review status publish (catch-up): parse_review_result 未ロード branch=${head_ref} pr=#${pr_number} reason=parse-helper-missing"
    rm -f "$notes_tmp" 2>/dev/null || true
    return 0
  fi

  local parsed parse_rc=0
  parsed=$(parse_review_result "$notes_tmp") || parse_rc=$?
  rm -f "$notes_tmp" 2>/dev/null || true

  if [ "$parse_rc" -ne 0 ] || [ -z "$parsed" ]; then
    pr_warn "claude-review status publish (catch-up): parse_review_result 失敗 branch=${head_ref} pr=#${pr_number} rc=${parse_rc} reason=parse-failed"
    return 0
  fi

  local result
  result=$(echo "$parsed" | cut -f1)
  case "$result" in
    approve|reject) ;;
    *)
      pr_warn "claude-review status publish (catch-up): 不正な RESULT '${result}' branch=${head_ref} pr=#${pr_number} reason=invalid-result"
      return 0
      ;;
  esac

  # target_url: review-notes.md の blob URL（PR head sha 指定）。組み立て不能時は PR URL に fallback。
  local target_url=""
  if [ -n "$sha" ] && [ -n "$spec_dir_rel" ]; then
    target_url="https://github.com/${REPO}/blob/${sha}/${spec_dir_rel}/review-notes.md"
  elif [ -n "$pr_url" ]; then
    target_url="$pr_url"
  fi

  pr_log "claude-review status publish (catch-up): branch=${head_ref} pr=#${pr_number} sha=${sha} result=${result} spec=${spec_dir_rel}"
  # publish 失敗時も pr_publish_claude_status / pr_publish_commit_status 側で WARN 出力済み。
  pr_publish_claude_status "$pr_number" "$sha" "$result" "$target_url" || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_run_review_for_pr: 1 PR 分のレビューを統括する（task 4〜6 の orchestration）
#   入力: $1 = pr_json（pr_fetch_candidate_prs の単一要素）, $2 = tool
#   戻り値: 0 = success / 1 = failure（一時的・skip 相当）/ 2 = skip（重複検出）/
#           3 = exec-error（実行失敗 / workspace-modified / 空出力）
#   AC: 4.1, 4.2, 4.3, 4.4, 4.5, 5.1〜5.4, 6.1〜6.4
#
#   フロー: 重複判定(kind=review) → prompt 生成 → cmd 置換 → レビュー実行 →
#           結果判定（fetch/checkout-fail / workspace-modified / exec-failed /
#           空出力 / 成功）→ 成功時はコメント投稿 + VERDICT 検出 + ラベル付与。
# ─────────────────────────────────────────────────────────────────────────────
pr_run_review_for_pr() {
  local pr_json="$1"
  local tool="$2"

  local pr_number head_ref base_ref sha pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  sha=$(echo "$pr_json"       | jq -r '.headRefOid')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
    base_ref="$BASE_BRANCH"
  fi

  # AC 6.2 / NFR 4.1: 同一 (sha, kind=review) が既存なら重複レビューを行わない
  if pr_already_processed "$pr_number" "$sha" "review"; then
    pr_log "PR #${pr_number}: sha=${sha} は既にレビュー済み（kind=review marker 検出）。skip"
    return 2
  fi

  # Issue #403 Req 1.6: 連続失敗カウンタの現在値をサイクル毎の観測ログに 1 行で出力
  local _streak_tsv _streak_sha _streak_val
  _streak_tsv=$(pr_read_exec_fail_streak "$pr_number")
  _streak_sha=$(printf '%s' "$_streak_tsv" | awk -F'\t' '{print $1}')
  _streak_val=$(printf '%s' "$_streak_tsv" | awk -F'\t' '{print $2}')
  _streak_val="${_streak_val:-0}"
  pr_log "PR #${pr_number}: exec-fail-streak observe pr=#${pr_number} sha=${sha} recorded_sha=${_streak_sha:-<none>} streak=${_streak_val} limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"

  # Issue #403 Req 2.2, 2.3, 2.4: 上限到達 PR は外部レビューツール呼び出しを抑止
  if pr_exec_fail_limit_reached "$pr_number" "$sha"; then
    # 初回検出サイクルのみ advisory コメント投稿（重複は marker で抑止 / Req 2.3）
    pr_post_exec_fail_escalation_comment "$pr_number" "$sha" "$tool" "$_streak_val"
    pr_log "PR #${pr_number}: exec-fail-streak が上限に達したため外部レビューツール呼び出しを抑止 sha=${sha} streak=${_streak_val} limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"
    return 2
  fi

  pr_log "PR #${pr_number}: レビュー着手 tool=${tool} head=${head_ref} base=${base_ref} sha=${sha} (${pr_url})"

  # cmd template を tool 別に解決
  local cmd_template
  case "$tool" in
    codex)       cmd_template="${PR_REVIEWER_CODEX_CMD}" ;;
    antigravity) cmd_template="${PR_REVIEWER_ANTIGRAVITY_CMD}" ;;
    *)
      pr_warn "PR #${pr_number}: 未知の tool '${tool}'、skip"
      return 1
      ;;
  esac

  # prompt tempfile + 実行結果受け渡し tempfile を親で生成し、RETURN trap で確実に削除。
  local prompt_file out_file err_file result_file
  if ! prompt_file=$(pr_build_prompt_file "$pr_number" "$base_ref" "$head_ref"); then
    pr_warn "PR #${pr_number}: prompt 生成に失敗、skip"
    return 1
  fi
  out_file=$(mktemp -t idd-claude-pr-reviewer-out.XXXXXX 2>/dev/null || mktemp)
  err_file=$(mktemp -t idd-claude-pr-reviewer-err.XXXXXX 2>/dev/null || mktemp)
  result_file=$(mktemp -t idd-claude-pr-reviewer-res.XXXXXX 2>/dev/null || mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${prompt_file}' '${out_file}' '${err_file}' '${result_file}'" RETURN

  # プレースホルダ置換（{BASE}/{HEAD}/{PR}/{PROMPT_FILE}）+ metachar 検査（AC 4.3）
  local resolved_cmd
  if ! resolved_cmd=$(pr_substitute_placeholders "$cmd_template" "$base_ref" "$head_ref" "$pr_number" "$prompt_file"); then
    return 1
  fi

  # レビュー実行（git checkout は subshell 内 / trap で BASE_BRANCH 復帰、AC 4.1/4.2）
  pr_execute_review_command "$head_ref" "$resolved_cmd" "$tool" "$out_file" "$err_file" "$result_file"

  local result
  result=$(cat "$result_file" 2>/dev/null || echo "")

  case "$result" in
    fetch-fail|checkout-fail)
      # 一時的な git/gh 失敗 → WARN + skip（コメント投稿しない / Error 戦略 3 層目）
      pr_warn "PR #${pr_number}: head '${head_ref}' の取得に失敗 (${result})、当該 PR を skip"
      return 1
      ;;
  esac

  local exec_rc wsmod
  exec_rc=$(printf '%s' "$result" | awk -F: '{print $2}')
  wsmod=$(printf '%s' "$result" | awk -F: '{print $3}')
  exec_rc="${exec_rc:-1}"

  # read-only invariant 違反（Decision 8）→ workspace-modified エラーコメント、exec-error
  if [ "$wsmod" = "modified" ]; then
    pr_error "PR #${pr_number}: レビュー実行がワークツリーを変更しました（read-only invariant 違反）。tracked 変更を破棄し workspace-modified を報告"
    # Issue #403 Req 1.1: workspace-modified も実行失敗扱いで streak +1（NFR 2.1 / Req 2.x）
    local _ws_streak
    _ws_streak=$(pr_increment_exec_fail_streak "$pr_number" "$sha" "$tool" 2>/dev/null || echo "0")
    pr_warn "PR #${pr_number}: exec-fail-streak inc (workspace-modified) pr=#${pr_number} sha=${sha} tool=${tool} exit_code=0 streak=${_ws_streak} limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"
    pr_post_error_comment "$pr_number" "$sha" "workspace-modified" \
      "レビューツール \`${tool}\` の実行がワークツリーを変更しました。read-only 制約に違反するため tracked 変更を破棄しました。ツールの sandbox / read-only 設定（codex は \`--sandbox read-only\`）と \`PR_REVIEWER_*_CMD\` を確認してください。\n\n連続失敗カウンタ: ${_ws_streak}/${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}（同一 head sha）" \
      "$tool"
    return 3
  fi

  # 実行失敗（非ゼロ終了）→ exec-failed エラーコメント（stderr 末尾優先抜粋 + artifact 保存、Issue #403）
  if [ "$exec_rc" -ne 0 ]; then
    local err_excerpt artifact_path detail
    # Req 3.1, 3.4: 末尾優先抜粋（既定 8KB / 旧 1KB から拡張、prompt echo に埋もれない）
    err_excerpt=$(pr_truncate_stderr_tail "$err_file" "${PR_REVIEWER_STDERR_EXCERPT_BYTES:-8192}")
    # Req 3.1, 3.4, 3.5: artifact ファイル保存（$HOME/.issue-watcher/... 配下、1MB 超は末尾優先）
    artifact_path=$(pr_save_stderr_artifact "$pr_number" "$sha" "$tool" "$err_file")
    # Req 1.1: 連続失敗カウンタを +1 して永続化（戻り値の streak を取得）
    local _ef_streak
    _ef_streak=$(pr_increment_exec_fail_streak "$pr_number" "$sha" "$tool" 2>/dev/null || echo "0")
    # Req 3.3 / NFR 3.2: WARN ログに PR / sha / tool / exit / streak / artifact を 1 行で含める
    pr_warn "PR #${pr_number}: exec-failed pr=#${pr_number} sha=${sha} tool=${tool} exit=${exec_rc} streak=${_ef_streak} limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3} artifact='${artifact_path:-<none>}'"
    pr_error "PR #${pr_number}: レビュー実行コマンドが非ゼロ終了 (exit=${exec_rc}, tool=${tool})"
    # Req 3.2: コメント本文に exit code / tool / streak / sha / artifact パス / stderr 抜粋を含める
    local artifact_line=""
    if [ -n "$artifact_path" ]; then
      # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コード記号のリテラル
      artifact_line=$(printf '\nstderr artifact (watcher host のみ参照可): `%s`\n' "$artifact_path")
    fi
    # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
    detail=$(printf 'レビュー実行コマンドが非ゼロ終了しました（exit=%s, tool=%s, head sha=%s）。\n\n連続失敗カウンタ: %s/%s（同一 head sha）\n%s\nstderr 末尾抜粋（最大 %s バイト）:\n```\n%s\n```' \
      "$exec_rc" "$tool" "$sha" "${_ef_streak}" "${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}" "$artifact_line" "${PR_REVIEWER_STDERR_EXCERPT_BYTES:-8192}" "$err_excerpt")
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" "$detail" "$tool"
    return 3
  fi

  # 成功: stdout をレビュー結果として収集（AC 4.2）
  local review_text
  review_text=$(cat "$out_file" 2>/dev/null || echo "")

  # antigravity (agy) は --output-format json のため最終 message を jq 抽出。
  # 実機の JSON schema は未確定のため複数キーを試し、失敗時は raw stdout に fail-safe
  # （実装時に `agy --help` 出力で確定し impl-notes.md に記録 / design 確認事項 1）。
  if [ "$tool" = "antigravity" ]; then
    local extracted
    extracted=$(printf '%s' "$review_text" | jq -r '.message // .text // .response // empty' 2>/dev/null || echo "")
    if [ -n "$extracted" ]; then
      review_text="$extracted"
    fi
  fi

  if [ -z "$review_text" ]; then
    # Issue #403 Req 1.1: 空出力も exec-failed 扱いで streak +1
    local _empty_streak
    _empty_streak=$(pr_increment_exec_fail_streak "$pr_number" "$sha" "$tool" 2>/dev/null || echo "0")
    pr_warn "PR #${pr_number}: exec-failed pr=#${pr_number} sha=${sha} tool=${tool} exit=0 reason=empty-output streak=${_empty_streak} limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"
    pr_post_error_comment "$pr_number" "$sha" "exec-failed" \
      "レビュー実行は成功しましたが出力が空でした（tool=${tool}, head sha=${sha}）。\`PR_REVIEWER_*_CMD\` / prompt を確認してください。\n\n連続失敗カウンタ: ${_empty_streak}/${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}（同一 head sha）" \
      "$tool"
    return 3
  fi

  # AC 4.4: レビュー結果コメント投稿（marker kind=review）
  if ! pr_post_review_comment "$pr_number" "$sha" "$review_text" "$tool"; then
    return 1
  fi

  # Issue #403 Req 1.3: 同一 head sha でレビュー成功（コメント投稿到達）したら streak をリセット
  pr_reset_exec_fail_streak "$pr_number" "$sha" "$tool" || true

  # AC 5.1〜5.4: VERDICT 検出 → 件数 > 0 で needs-iteration ラベル付与
  local match_count
  match_count=$(pr_detect_iteration_keyword "$pr_number" "$review_text")
  match_count="${match_count:-0}"
  if [ "$match_count" -gt 0 ] 2>/dev/null; then
    pr_add_iteration_label "$pr_number"
  fi

  # Issue #349 / Req 2.1〜2.5: codex / antigravity の VERDICT を commit status に publish。
  # AND 二重 opt-in（PR_REVIEWER_STATUS_CHECK_ENABLED && FULL_AUTO_ENABLED）が成立した
  # 場合のみ実行。gate OFF / publish 失敗いずれもパイプラインを止めない（Req 5.3, 5.5）。
  pr_publish_codex_status "$pr_number" "$sha" "$review_text" "$pr_url" || true

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_broadcast_error_to_prs: 候補 PR 全件に同種エラーコメントを投稿（内部 helper）
#   入力: $1 = prs_json（jq 配列）, $2 = kind, $3 = tool, $4 = detail
#   戻り値: 0 固定
#   AC: 2.4, 3.1, 3.2（cycle-level エラーを対象 PR へ broadcast。重複防止は
#       pr_post_error_comment 内の (sha, kind) marker 判定に委譲）
#
#   - conflict-tool / not-installed / not-authenticated は「サイクル単位で確定するが
#     通知先は個々の対象 PR」という性質のため、健全性チェックを 1 回だけ実施し、
#     その結果を候補 PR 全件へ配る（各 PR で sha=headRefOid を marker に使う）。
# ─────────────────────────────────────────────────────────────────────────────
pr_broadcast_error_to_prs() {
  local prs_json="$1"
  local kind="$2"
  local tool="$3"
  local detail="$4"

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c '.[]' 2>/dev/null || echo "")
  [ -z "$pr_iter" ] && return 0

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number sha
    pr_number=$(echo "$pr_json" | jq -r '.number')
    sha=$(echo "$pr_json" | jq -r '.headRefOid')
    pr_post_error_comment "$pr_number" "$sha" "$kind" "$detail" "$tool" || true
  done <<< "$pr_iter"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_reviewer: dispatcher から呼ばれるエントリ関数
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しないため / dispatcher fail-continue 契約）
#   AC 1.1, 1.2, 1.3, 2.x, 3.x, 7.x, NFR 1.1, NFR 3.1, NFR 4.1
#
#   処理順:
#     ① opt-in gate（PR_REVIEWER_ENABLED=true 厳密一致のみ。それ以外は早期 return）
#     ② tool 解決（pr_resolve_tool: codex/antigravity/none/conflict）
#     ③ サイクル開始の 1 行サマリログ（NFR 3.1）
#     ④ none（rc=2）→ 静かに skip（PR 列挙もコメントも行わない、AC 2.5）
#     ⑤ 候補 PR 列挙（conflict broadcast / review loop の双方で必要）
#     ⑥ conflict（rc=1）→ 候補 PR へ kind=conflict-tool を broadcast して中止（AC 2.3/2.4）
#     ⑦ 候補 0 件 → サマリログのみで return
#     ⑧ 未インストール（AC 3.1）→ kind=not-installed を broadcast して中止
#     ⑨ 未認証（AC 3.2）→ kind=not-authenticated を broadcast して中止
#     ⑩ MAX_PRS で truncate（total / target / overflow をログ、NFR 3.1）
#     ⑪ レビュー loop（pr_run_review_for_pr）→ rc 集計 → サマリログ
# ─────────────────────────────────────────────────────────────────────────────
process_pr_reviewer() {
  # ① AC 1.1 / NFR 1.1: opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${PR_REVIEWER_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # ② AC 2.x: tool 解決（stdout に tool 名 / 戻り値で状態を返す）
  local resolved_tool resolve_rc=0
  resolved_tool=$(pr_resolve_tool) || resolve_rc=$?

  # ③ AC 1.2 / NFR 3.1: サイクル開始の 1 行サマリログ（#403 で exec_fail_limit / stderr_excerpt_bytes を追加）
  pr_log "cycle start: tool=${resolved_tool} max_prs=${PR_REVIEWER_MAX_PRS:-unset} git_timeout=${PR_REVIEWER_GIT_TIMEOUT:-unset}s exec_timeout=${PR_REVIEWER_EXEC_TIMEOUT:-unset}s head_pattern=${PR_REVIEWER_HEAD_PATTERN:-unset} exec_fail_limit=${PR_REVIEWER_EXEC_FAIL_LIMIT:-3} stderr_excerpt_bytes=${PR_REVIEWER_STDERR_EXCERPT_BYTES:-8192}"

  # ④ AC 2.5: none（rc=2）は PR 列挙もコメントも行わず静かに skip
  if [ "$resolve_rc" -eq 2 ]; then
    return 0
  fi

  # ⑤ 候補 PR 列挙（AC 7.x）
  local prs_json total
  prs_json=$(pr_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  # ⑥ AC 2.3 / 2.4: conflict（rc=1）は候補 PR へ排他エラーを broadcast して中止
  if [ "$resolve_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "conflict-tool" "none" \
      "\`codex\` と \`antigravity\` の両方が有効化されています（排他エラー）。\`PR_REVIEWER_TOOL\` もしくは \`PR_REVIEWER_CODEX_ENABLED\` / \`PR_REVIEWER_ANTIGRAVITY_ENABLED\` のいずれか一方のみを有効化してください。"
    pr_log "サマリ: tool=conflict reviewed=0 skip=0 fail=0 errored=${total}（conflict-tool broadcast）"
    return 0
  fi

  # 以降 resolved_tool は codex / antigravity（resolve_rc==0）

  # ⑦ 候補 0 件 → サマリのみ
  if [ "$total" -eq 0 ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0（候補 PR なし）"
    return 0
  fi

  # ⑧ AC 3.1: 未インストール → 候補 PR へ broadcast して中止（健全性チェックは 1 回）
  if ! pr_check_tool_installed "$resolved_tool"; then
    pr_broadcast_error_to_prs "$prs_json" "not-installed" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` の実行ファイルが PATH 上に見つかりません。watcher 実行環境にインストールし、認証を済ませてください。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}（not-installed broadcast）"
    return 0
  fi

  # ⑨ AC 3.2: 未認証 → 候補 PR へ broadcast して中止（rc=2 は check 無効 = skip 扱い）
  local auth_rc=0
  pr_check_tool_authenticated "$resolved_tool" || auth_rc=$?
  if [ "$auth_rc" -eq 1 ]; then
    pr_broadcast_error_to_prs "$prs_json" "not-authenticated" "$resolved_tool" \
      "レビューツール \`${resolved_tool}\` が未認証です。watcher 実行環境で認証を済ませてください。"
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=${total}（not-authenticated broadcast）"
    return 0
  fi

  # ⑩ MAX_PRS で truncate（total / target / overflow をログ、NFR 3.1）
  local target_count="$total" skipped_overflow=0
  if [ "$total" -gt "$PR_REVIEWER_MAX_PRS" ]; then
    target_count="$PR_REVIEWER_MAX_PRS"
    skipped_overflow=$((total - PR_REVIEWER_MAX_PRS))
    pr_log "対象候補 ${total} 件中、上限 ${PR_REVIEWER_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    pr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  # ⑪ レビュー loop
  local reviewed=0 skip=0 fail=0 errored=0 escalated=0
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    pr_log "サマリ: tool=${resolved_tool} reviewed=0 skip=0 fail=0 errored=0 escalated=0（iterate 対象なし）"
    return 0
  fi

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local rc=0
    # Issue #403 NFR 3.1: 上限到達 PR を escalated 件数で観測する。
    # pr_run_review_for_pr は上限到達時 rc=2 を返すため、呼び出し前に判定して
    # escalated 件数を独立にカウントする（rc=2 自体は重複検出と上限到達の双方を含む）。
    local _pr_number_obs _pr_sha_obs
    _pr_number_obs=$(echo "$pr_json" | jq -r '.number' 2>/dev/null || echo "")
    _pr_sha_obs=$(echo "$pr_json" | jq -r '.headRefOid' 2>/dev/null || echo "")
    if [ -n "$_pr_number_obs" ] && [ -n "$_pr_sha_obs" ] \
        && pr_exec_fail_limit_reached "$_pr_number_obs" "$_pr_sha_obs"; then
      escalated=$((escalated + 1))
    fi

    pr_run_review_for_pr "$pr_json" "$resolved_tool" || rc=$?
    case $rc in
      0) reviewed=$((reviewed + 1)) ;;
      2) skip=$((skip + 1)) ;;
      3) errored=$((errored + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す（レビューは subshell 内で完結するが念のため）
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  pr_log "サマリ: tool=${resolved_tool} reviewed=${reviewed} skip=${skip} fail=${fail} errored=${errored} escalated=${escalated} overflow=${skipped_overflow}"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_claude_review_status_catchup (Issue #374)
#
# `claude-review` commit status の catch-up publish processor。per-task ループ運用で
# `publish_claude_review_status` が PR 作成より前の時間軸で発火して WARN skip した
# 分を、サイクル毎に open PR を scan して読み直し publish する（Req 1.4 / 4.1 / 4.2）。
#
# 起動条件:
#   - AND 二重 opt-in（PR_REVIEWER_STATUS_CHECK_ENABLED=true AND FULL_AUTO_ENABLED=true）。
#     OFF（既定）なら gh / git 呼び出しを一切発火させずに即 return（Req 5.1 / 5.2 / NFR 1.1）。
#   - `PR_REVIEWER_ENABLED` の値には依存しない（README #349 設計どおり、claude-review 単独
#     有効化を維持）。
#
# 処理:
#   - 候補 PR は `pr_fetch_candidate_prs`（既存）を再利用し、open / 非 draft /
#     PR_REVIEWER_HEAD_PATTERN（既定 `^claude/`）に一致 / 非 fork のもの。
#   - 各 PR について `pr_publish_claude_status_from_branch` を呼ぶ（PR 未解決 /
#     review-notes.md 不在 / parse 失敗いずれも WARN + skip / Req 3.x）。
#   - 戻り値は 0 固定（後続 processor を阻害しない / NFR 1.1）。
#
# 設計上の判断:
#   - 既存 `process_pr_reviewer` 内の `pr_run_review_for_pr` 経路に embed する案も検討したが、
#     その経路は `PR_REVIEWER_ENABLED=true` のときのみ発火するため、claude-review 単独有効化
#     を README で約束している契約と矛盾する。本 processor は AND 二重 opt-in のみで gate する
#     独立経路として実装し、PR_REVIEWER_ENABLED の値に依存しない（Req 5.x / 既存契約 #349 維持）。
#   - 同一 (sha, context) への重複 publish は GitHub の latest-wins 仕様で吸収される（Req 4.3）。
#     非 per-task 経路の `publish_claude_review_status` 直接呼びと併走しても、最終的に
#     最新の RESULT が反映された state に収束する（Req 4.5）。
# ─────────────────────────────────────────────────────────────────────────────
process_claude_review_status_catchup() {
  # AND 二重 opt-in 早期判定（Req 5.1 / 5.2 / NFR 1.1）
  if ! pr_status_check_enabled; then
    return 0
  fi

  # 候補 PR 列挙（既存 process_pr_reviewer と同じ helper を使う / fail-safe で "[]" を返す）
  local prs_json total
  prs_json=$(pr_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    return 0
  fi

  # 上限件数（PR_REVIEWER_MAX_PRS）で truncate する点も process_pr_reviewer と整合させる。
  local target_count="$total" overflow=0
  if [ -n "${PR_REVIEWER_MAX_PRS:-}" ] && [ "$total" -gt "$PR_REVIEWER_MAX_PRS" ]; then
    target_count="$PR_REVIEWER_MAX_PRS"
    overflow=$((total - PR_REVIEWER_MAX_PRS))
  fi

  pr_log "claude-review catch-up: 対象候補 ${total} 件、処理対象 ${target_count} 件（overflow=${overflow}）"

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    return 0
  fi

  local processed=0
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number head_ref sha pr_url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    sha=$(echo "$pr_json"       | jq -r '.headRefOid')
    pr_url=$(echo "$pr_json"    | jq -r '.url')

    pr_publish_claude_status_from_branch "$pr_number" "$sha" "$head_ref" "$pr_url" || true
    processed=$((processed + 1))
  done <<< "$pr_iter"

  pr_log "claude-review catch-up: サマリ processed=${processed} overflow=${overflow}"
  return 0
}
