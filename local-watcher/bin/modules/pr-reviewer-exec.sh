#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer-exec.sh — PR Reviewer 外部ツール実行（codex / antigravity 起動・timeout・
#   出力取得）+ Issue #403 exec-fail-streak リトライ抑止
#
# family: pr-reviewer / prefix: pr_（#470 で pr-reviewer.sh から分割。family マニフェストは
#   pr-reviewer.sh 冒頭ヘッダを参照）
#
# 用途:
#   pr_run_review_for_pr（1 PR 分のレビューを統括する round driver）と、その実行系ヘルパー
#   群を集約する。
#   - 健全性チェック: pr_check_tool_installed / pr_check_tool_authenticated
#   - prompt 構築: pr_default_prompt / pr_build_prompt_file / pr_substitute_placeholders
#   - レビュー実行: pr_execute_review_command（subshell + trap で head checkout / BASE 復帰 /
#     read-only invariant 検査、eval 不使用）
#   - Issue #403（exec-failed リトライ抑止 / 診断性向上）: pr_extract_exec_fail_streak /
#     pr_read_exec_fail_streak / pr_write_exec_fail_streak / pr_reset_exec_fail_streak /
#     pr_increment_exec_fail_streak / pr_exec_fail_limit_reached / pr_truncate_stderr_tail /
#     pr_save_stderr_artifact / pr_post_exec_fail_escalation_comment
#
# 配置先:
#   $HOME/bin/modules/pr-reviewer-exec.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh。
#   - orchestrator（pr-reviewer.sh）の pr_already_processed / pr_build_marker、
#     publish（pr-reviewer-publish.sh）の pr_post_error_comment / pr_detect_iteration_keyword /
#     pr_add_iteration_label / pr_publish_codex_status、adjudicator.sh の adj_run_for_pr /
#     adj_warn を遅延束縛で呼ぶ（loader が main loop 前に全 module を source）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_REVIEWER_* 等）は watcher-config.sh。
#   - 外部 CLI: gh / git / jq / bash（レビューコマンド実行）。


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

  # Issue #404 / adjudicator hook: codex 結果確定直後に adjudicator を chain する。
  # gate OFF（PR_REVIEWER_ADJUDICATOR_ENABLED != true）時は adj_run_for_pr 内部で即 return 0
  # するため完全 no-op（NFR 2.1 / 既存ラベル付与・status publish ロジックは残置）。
  # gate ON 時は adjudicator が後発で同 (sha, claude-review) を上書き publish する（Req 3.2）。
  adj_run_for_pr "$pr_number" "$sha" "$review_text" "$pr_url" "$head_ref" \
    || adj_warn "adj_run_for_pr 想定外の失敗 (pr=#${pr_number} sha=${sha})"

  return 0
}
