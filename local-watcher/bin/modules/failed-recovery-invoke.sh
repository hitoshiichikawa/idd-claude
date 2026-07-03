#!/usr/bin/env bash
# failed-recovery-invoke.sh — Failed Recovery context 収集・claude 起動・作業ツリー準備
#
# family: failed-recovery / prefix: fr_（#471 で failed-recovery.sh から分割。family
#   マニフェストは failed-recovery.sh 冒頭ヘッダを参照）
#
# 用途:
#   fr_run_recovery_attempt（failed-recovery-attempt.sh）が 1 試行を実行する際に使う
#   context 収集・作業ツリー準備・claude 起動ヘルパー群を集約する。
#   - context 収集: fr_collect_issue_context / fr_collect_pr_ci_context
#   - 専用ログパス解決: fr_resolve_dedicated_log_path
#   - 即時失敗判定: fr_classify_immediate_failure（#411）
#   - 作業ツリー準備: fr_prepare_repo_worktree
#   - claude 起動 wrapper: fr_invoke_claude（quota-aware.sh の qa_detect_rate_limit を
#     再利用。stream-json の tool_use 観測 + 経過時間計測で fr_classify_immediate_failure
#     に渡す入力を作る）
#
# 配置先:
#   $HOME/bin/modules/failed-recovery-invoke.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー fr_log / fr_warn / fr_error は core_utils.sh。
#   - quota-aware.sh の qa_detect_rate_limit を fr_invoke_claude から呼ぶ。
#   - グローバル変数（$FAILED_RECOVERY_* / $REPO_DIR / $BASE_BRANCH / $LOG 等）は
#     watcher-config.sh。
#   - 外部 CLI: gh / git / claude / jq。


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Context Collection Layer
#
# claude session に渡す context 文字列を `gh issue view` / `gh pr checks` /
# `gh run view` で組み立てる。すべて fail-continue（API エラー時は警告 + 部分結果
# を返し caller を落とさない / NFR 5.2）。未信頼入力（Issue 本文・PR 本文・branch
# 名・コメント）は jq --arg / --argjson 経由で sanitize（NFR 3.1）。
#
# 関連 AC:
#   - Req 3.1: Issue コメントおよび関連ログから失敗原因 hint を抽出
#   - Req 3.2: auto-merge 待ち PR の CI ログを解析
#   - Req 3.5: 未信頼入力の quote / sanitize / ID 検証
#   - NFR 3.1: jq --arg / --argjson、gh -- / git --、ID `^[0-9]+$` / SHA `^[0-9a-f]{40}$`
#   - NFR 5.2: 取得失敗時も非破壊（fr_warn + 部分結果 / fail-continue）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_collect_issue_context: claude-failed Issue の context（title + labels + body +
# 直近 5 件コメント本文）を 1 つの平文に集約する。
#
# Args:
#   $1 = issue_number（^[0-9]+$ で使用前検証）
#
# Stdout: 集約済みの context 文字列（取得失敗時は警告 + 空文字）
# Returns:
#   0 = 成功（部分結果含む。API 失敗時も fail-continue で 0 を返し warn のみ）
#   1 = issue_number の形式不正（NFR 3.1 ガード）
fr_collect_issue_context() {
  local issue_number="$1"

  # NFR 3.1: Issue 番号の形式検証（^[0-9]+$）
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_issue_context: 不正な Issue 番号 issue=$(printf '%s' "$issue_number" | tr -cd '[:alnum:]_-' | head -c 32) を skip"
    return 1
  fi

  # gh issue view を呼び出す。失敗時は warn + 空 JSON で続行（fail-continue）
  local view_json
  if ! view_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh issue view "$issue_number" \
      --repo "$REPO" \
      --json comments,body,title,labels 2>/dev/null); then
    fr_warn "fr_collect_issue_context: gh issue view 失敗 issue=#${issue_number}"
    view_json="{}"
  fi
  if [ -z "$view_json" ]; then
    view_json="{}"
  fi

  # 直近 5 件のコメントを抽出する。jq parse 失敗時は空配列に正規化（fail-open）。
  # すべて jq filter 内で完結（未信頼値の inline 展開は無し / NFR 3.1）。
  local context
  if ! context=$(printf '%s' "$view_json" | jq -r '
    "## Title\n" + ((.title // "") | tostring) + "\n\n" +
    "## Labels\n" + (((.labels // []) | map(.name) | join(", "))) + "\n\n" +
    "## Body\n" + ((.body // "") | tostring) + "\n\n" +
    "## Recent Comments (last 5)\n" +
    (((.comments // [])[-5:]) | map("--- comment by " + ((.author.login // "unknown") | tostring) + " ---\n" + ((.body // "") | tostring)) | join("\n\n"))
  ' 2>/dev/null); then
    fr_warn "fr_collect_issue_context: jq による context 組み立て失敗 issue=#${issue_number}"
    printf '%s' ""
    return 0
  fi

  printf '%s' "$context"
  return 0
}

# fr_collect_pr_ci_context: auto-merge 待ち PR の failing checks ログ tail を集約する。
#
# Args:
#   $1 = pr_number（^[0-9]+$ で使用前検証）
#
# Stdout: 集約済みの context（failing check 一覧 + 各 check の log tail 200 行）
# Returns:
#   0 = 成功（部分結果含む。API 失敗時も fail-continue で 0 を返し warn のみ）
#   1 = pr_number の形式不正（NFR 3.1 ガード）
#
# 仕様:
#   - `gh pr checks <pr_number> --json name,state,conclusion,detailsUrl` で
#     failing check 列を取得（state=FAILURE または conclusion=FAILURE/TIMED_OUT）
#   - 各 failing check の detailsUrl から regex `actions/runs/([0-9]+)` で run id を
#     抽出。`^[0-9]+$` で再検証してから `gh run view <run_id> --log-failed` を呼ぶ
#   - 出力ログは tail で 200 行に cap（context 長制御）
#   - すべての API 失敗を fr_warn で吸収し残り check の処理を継続（fail-continue）
fr_collect_pr_ci_context() {
  local pr_number="$1"

  # NFR 3.1: PR 番号の形式検証（^[0-9]+$）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_collect_pr_ci_context: 不正な PR 番号 pr=$(printf '%s' "$pr_number" | tr -cd '[:alnum:]_-' | head -c 32) を skip"
    return 1
  fi

  # failing checks を取得（gh pr checks --json）
  local checks_json
  if ! checks_json=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh pr checks "$pr_number" \
      --repo "$REPO" \
      --json name,state,conclusion,detailsUrl 2>/dev/null); then
    fr_warn "fr_collect_pr_ci_context: gh pr checks 失敗 pr=#${pr_number}"
    printf '%s' ""
    return 0
  fi
  if [ -z "$checks_json" ]; then
    printf '%s' ""
    return 0
  fi

  # failing check のみ filter（state=FAILURE または conclusion=FAILURE/TIMED_OUT）
  local failing_checks
  if ! failing_checks=$(printf '%s' "$checks_json" | jq -c '
    [.[] | select(
      ((.state // "") == "FAILURE")
      or ((.conclusion // "") == "FAILURE")
      or ((.conclusion // "") == "TIMED_OUT")
    )]
  ' 2>/dev/null); then
    fr_warn "fr_collect_pr_ci_context: failing checks の jq filter 失敗 pr=#${pr_number}"
    printf '%s' ""
    return 0
  fi

  # failing check の概要 header を組み立てる
  local header
  header=$(printf '%s' "$failing_checks" | jq -r '
    "## Failing Checks (count: " + ((. | length) | tostring) + ")\n" +
    (map("- " + ((.name // "unknown") | tostring) + " [state=" + ((.state // "") | tostring) + " conclusion=" + ((.conclusion // "") | tostring) + "]") | join("\n"))
  ' 2>/dev/null || echo "## Failing Checks")

  # 各 failing check の log tail を取得して append する
  local count
  count=$(printf '%s' "$failing_checks" | jq -r 'length' 2>/dev/null || echo "0")
  if [ -z "$count" ]; then
    count="0"
  fi

  local logs_section=""
  local idx=0
  while [ "$idx" -lt "$count" ]; do
    local check_meta details_url check_name run_id
    check_meta=$(printf '%s' "$failing_checks" | jq -c --argjson i "$idx" '.[$i]')
    details_url=$(printf '%s' "$check_meta" | jq -r '.detailsUrl // ""')
    check_name=$(printf '%s' "$check_meta" | jq -r '.name // "unknown"')

    # detailsUrl から run id を抽出（actions/runs/<id> の形式）
    run_id=""
    if [[ "$details_url" =~ actions/runs/([0-9]+) ]]; then
      run_id="${BASH_REMATCH[1]}"
    fi

    # NFR 3.1: run id の再検証（^[0-9]+$）
    if [ -n "$run_id" ] && [[ "$run_id" =~ ^[0-9]+$ ]]; then
      local log_tail
      if log_tail=$(timeout "$FAILED_RECOVERY_GIT_TIMEOUT" gh run view "$run_id" \
          --repo "$REPO" \
          --log-failed 2>/dev/null | tail -n 200); then
        logs_section="${logs_section}"$'\n\n'"### Log for check: ${check_name} (run #${run_id})"$'\n'"${log_tail}"
      else
        fr_warn "fr_collect_pr_ci_context: gh run view 失敗 pr=#${pr_number} run=${run_id}（skip）"
      fi
    else
      fr_warn "fr_collect_pr_ci_context: detailsUrl から run id を抽出できず check=${check_name}（skip）"
    fi
    idx=$((idx + 1))
  done

  printf '%s\n%s' "$header" "$logs_section"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Recovery Execution Layer
#
# fresh Claude session を起動して context を解析・修正させる wrapper。quota-aware
# モジュールの qa_detect_rate_limit を再利用し、quota 検出時は exit 99 sentinel を
# caller に伝播する（呼出側で qa_handle_quota_exceeded 経路へ流す）。
#
# 関連 AC:
#   - Req 3.1: 修正試行を伴う再開を実行する
#   - Req 3.2: PR の CI 修正コミット投入
#   - Req 3.5: 未信頼入力の sanitize
#   - NFR 3.1: prompt は printf '%s' で値埋め込み、claude には引数として個別に渡す
#   - NFR 3.2: secrets を prompt 本文に埋め込まない（GH_TOKEN 等を直接展開しない）
#   - NFR 5.2: claude 実行失敗を fail-continue で扱う（quota 検出は別経路 exit 99）
#
# #411 拡張:
#   - 専用ログファイル（`$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log`）への保存を
#     必ず行う（Req 2.1〜2.5）。LOG が未設定でも /dev/null に捨てず自前で確定する
#   - stream-json 中の tool_use イベントを観測し、セッション継続時間と合わせて即時失敗
#     を判定する（Req 1.2）。即時失敗時は exit 98 sentinel を返す（Req 1.1）
#   - 対象 repo の作業ツリーで claude を起動する（Req 3.1〜3.3 / `fr_prepare_repo_worktree`）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# fr_resolve_dedicated_log_path: failed-recovery 専用ログファイルのパスを返す純粋関数。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$ で使用前検証)
#
# Stdout: 絶対パス（`$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log`）
# Returns:
#   0 = 成功
#   1 = kind / number が不正（caller は /dev/null fallback または fail）
#
# 仕様:
#   - 識別語 `failed-recovery` を必ず含める（Req 2.3 / NFR 2.2）
#   - kind は `issue` / `pr` のみ受理、number は `^[0-9]+$` のみ受理（NFR 3.1）
#   - timestamp は ASCII 安全文字（`+%Y%m%dT%H%M%SZ` 互換 UTC）のみで構成
#   - $LOG_DIR が未設定なら $HOME/.issue-watcher/logs/$REPO_SLUG にフォールバック
#     （issue-watcher.sh Config ブロックの default と同じ規約 / Req 2.4）
fr_resolve_dedicated_log_path() {
  local kind="$1"
  local number="$2"

  # kind / number の sanitize（NFR 3.1）
  case "$kind" in
    issue|pr) : ;;
    *) return 1 ;;
  esac
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    return 1
  fi

  # LOG_DIR fallback: 未設定なら $HOME/.issue-watcher/logs/$REPO_SLUG（NFR 1.1 / Req 2.4）
  local log_dir="${LOG_DIR:-}"
  if [ -z "$log_dir" ]; then
    local repo_slug="${REPO_SLUG:-${REPO//\//-}}"
    log_dir="${HOME}/.issue-watcher/logs/${repo_slug}"
  fi

  # ASCII 安全な UTC タイムスタンプ（`date -u` 失敗時は epoch を fallback として使用）
  local ts
  ts=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date -u +%s 2>/dev/null || echo "unknown")
  # timestamp が想定外形式（ASCII 安全文字以外）を含まないよう保険で sanitize
  ts=$(printf '%s' "$ts" | tr -cd '[:alnum:]')

  printf '%s/failed-recovery-%s-%s-%s.log' "$log_dir" "$kind" "$number" "$ts"
  return 0
}

# fr_classify_immediate_failure: claude session の終了情報から即時失敗を判定する純粋関数。
#
# Args:
#   $1 = claude_rc (int / claude 本体の exit code)
#   $2 = quota_detected ("1" = quota 検出済 / "0" = 検出なし)
#   $3 = tool_use_observed ("1" = tool_use 観測済 / "0" = 未観測)
#   $4 = elapsed_seconds (int / セッション継続時間)
#   $5 = threshold_seconds (int / 即時失敗判定の継続時間閾値)
#
# Returns:
#   0 = 即時失敗（attempt budget から除外すべき）
#   1 = 通常の試行（attempt budget に加算する）
#
# 判定ロジック（Req 1.2 / 1.8）:
#   - quota 検出（exit 99 sentinel）は本判定経路を適用しない → 1 (通常扱い)
#   - claude_rc == 0（success） → 1 (通常扱い)
#   - tool_use_observed == 1（実質作業に着手） → 1 (通常扱い)
#   - elapsed_seconds >= threshold（一定時間経過） → 1 (通常扱い)
#   - 上記いずれにも該当しない（rc != 0 かつ quota 以外 かつ tool_use 無し かつ短時間）
#     → 0 (即時失敗)
fr_classify_immediate_failure() {
  local claude_rc="$1"
  local quota_detected="$2"
  local tool_use_observed="$3"
  local elapsed_seconds="$4"
  local threshold_seconds="$5"

  # quota 検出経路は適用しない（Req 1.8）
  if [ "$quota_detected" = "1" ]; then
    return 1
  fi
  # claude が正常終了した場合は即時失敗ではない（Req 1.7）
  if [ "$claude_rc" = "0" ]; then
    return 1
  fi
  # tool_use を観測した場合は実質作業に着手しているため通算 attempt に加算（Req 1.7）
  if [ "$tool_use_observed" = "1" ]; then
    return 1
  fi
  # 閾値以上の時間継続していたら通常の試行として扱う（Req 1.7）
  if ! [[ "$elapsed_seconds" =~ ^[0-9]+$ ]]; then
    elapsed_seconds=0
  fi
  if ! [[ "$threshold_seconds" =~ ^[0-9]+$ ]]; then
    threshold_seconds=10
  fi
  if [ "$elapsed_seconds" -ge "$threshold_seconds" ]; then
    return 1
  fi
  # rc != 0 かつ quota 以外 かつ tool_use 無し かつ短時間 = 即時失敗
  return 0
}

# fr_prepare_repo_worktree: 対象 repo の作業ツリーを recovery claude 起動可能な状態に
# checkout する（Req 3.1〜3.3 / 3.5）。
#
# Args:
#   $1 = kind ("issue" | "pr")
#   $2 = number (^[0-9]+$)
#   $3 = pr_head_ref (PR の headRefName / kind=pr の時のみ使用、空文字可)
#
# Stdout: 採用した checkout 参照名（Req 3.6 のログ記録に使う）
# Returns:
#   0 = checkout 成功
#   1 = checkout 失敗（caller は即時失敗扱いに倒す / Req 3.4）
#
# 仕様:
#   - $REPO_DIR を作業ツリー起点として採用（Req 3.5 / 既存 impl 系プロセッサと同一起点）
#   - kind=pr の場合: pr_head_ref を `origin/<ref>` から checkout
#   - kind=issue の場合:
#       既存 `claude/issue-<number>-*` branch があればその先頭を、無ければ
#       `origin/$BASE_BRANCH` を checkout
#   - すべての git 操作は `timeout` + `git -C` で REPO_DIR に対して実行（NFR 3.1）
#   - 失敗時は fr_warn で原因を残しつつ rc=1 で caller に通知（fail-continue / Req 3.4）
fr_prepare_repo_worktree() {
  local kind="$1"
  local number="$2"
  local pr_head_ref="${3-}"

  # kind / number の sanitize（NFR 3.1）
  case "$kind" in
    issue|pr) : ;;
    *)
      fr_warn "fr_prepare_repo_worktree: 不正な kind=$(printf '%s' "$kind" | tr -cd '[:alnum:]_-' | head -c 16)"
      return 1
      ;;
  esac
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    fr_warn "fr_prepare_repo_worktree: 不正な ${kind} 番号 number=$(printf '%s' "$number" | tr -cd '[:alnum:]_-' | head -c 32)"
    return 1
  fi

  # REPO_DIR の存在確認（Req 3.5 / NFR 3.1）
  local repo_dir="${REPO_DIR:-}"
  if [ -z "$repo_dir" ] || [ ! -d "$repo_dir/.git" ]; then
    fr_warn "fr_prepare_repo_worktree: REPO_DIR が未設定または git repo ではない repo_dir=${repo_dir:-<unset>}"
    return 1
  fi

  # base branch（fetch / fallback 用）
  local base_branch="${BASE_BRANCH:-main}"
  local git_timeout="${FAILED_RECOVERY_GIT_TIMEOUT:-60}"

  # まず origin の最新を取得（fetch 失敗時は既存 cache で続行 / Req 3.4 の fail-continue）
  timeout "$git_timeout" git -C "$repo_dir" fetch --prune origin >/dev/null 2>&1 || \
    fr_warn "fr_prepare_repo_worktree: git fetch origin 失敗（既存 cache で続行）"

  local target_ref=""
  if [ "$kind" = "pr" ]; then
    # PR head branch を checkout（Req 3.2 / NFR 3.1: head_ref は -- でオプション解釈打ち切り）
    if [ -z "$pr_head_ref" ]; then
      fr_warn "fr_prepare_repo_worktree: pr=#${number} の headRefName が空"
      return 1
    fi
    # head_ref を `^claude/` で再検証（既存 fetch 結果との整合性確認）
    if ! [[ "$pr_head_ref" =~ ^claude/ ]]; then
      fr_warn "fr_prepare_repo_worktree: pr=#${number} の headRefName が ^claude/ パターン外 head_ref=$(printf '%s' "$pr_head_ref" | tr -cd '[:alnum:]/_.-' | head -c 64)"
      return 1
    fi
    target_ref="$pr_head_ref"
  else
    # kind=issue: `claude/issue-<number>-*` 既存 branch を origin から検索（Req 3.3）
    local found_ref=""
    found_ref=$(timeout "$git_timeout" git -C "$repo_dir" ls-remote --heads origin "claude/issue-${number}-*" 2>/dev/null | head -n 1 | awk '{print $2}' | sed 's|^refs/heads/||')
    if [ -n "$found_ref" ]; then
      target_ref="$found_ref"
    else
      # 既存 claude branch 無し → base branch を採用（Req 3.3）
      target_ref="$base_branch"
    fi
  fi

  # `--` でオプション解釈打ち切り（NFR 3.1）
  if ! timeout "$git_timeout" git -C "$repo_dir" checkout -B "$target_ref" "origin/$target_ref" -- >/dev/null 2>&1; then
    # origin/$target_ref が無い場合は target_ref そのものを試す（local-only branch / fallback）
    if ! timeout "$git_timeout" git -C "$repo_dir" checkout "$target_ref" -- >/dev/null 2>&1; then
      fr_warn "fr_prepare_repo_worktree: git checkout 失敗 ${kind}=#${number} target_ref=$(printf '%s' "$target_ref" | tr -cd '[:alnum:]/_.-' | head -c 64)"
      return 1
    fi
  fi

  printf '%s' "$target_ref"
  return 0
}

# fr_invoke_claude: fresh claude session を起動し stream-json を qa_detect_rate_limit
# で fold + tool_use 観測 + 経過時間計測する。
#
# Args:
#   $1 = prompt（claude へ -p で渡す本文。secrets を含めないこと / NFR 3.2）
#   $2 = stage_label（ログ識別用ラベル。例: "failed-recovery-issue-42"）
#   $3 = dedicated_log_path（専用ログ保存先パス / 空文字なら $LOG fallback）
#
# Returns:
#   0     = claude 正常終了 + quota 検出なし
#   98    = 即時失敗判定（attempt budget から除外すべき / #411 Req 1.1）
#   99    = quota 検出（caller は qa_handle_quota_exceeded 経路に流す / Req 3.x）
#   N≠0,98,99 = claude 自体の非ゼロ exit（quota 以外 / 即時失敗以外の失敗、fail-continue）
#
# 副作用:
#   - dedicated_log_path（または $LOG fallback）に stream-json を tee で append
#   - $LOG（caller 側で設定済みの実行ログ）にも tee で append（cron.log 観測の互換維持）
#   - prompt 本文を bash 引数として claude に渡す（環境変数経由ではなく引数）
#   - 専用ログファイル作成失敗時は fr_warn で警告しつつセッション自体は継続（Req 2.6）
#
# 実装メモ:
#   quota-aware.sh の qa_run_claude_stage と同じ tee + qa_detect_rate_limit 構成を
#   採用するが、本機能は QUOTA_AWARE_ENABLED gate を**経由しない**（Failed Recovery
#   は claude-failed 復旧の核となる処理なので、quota 検出のみは常時必要）。
#   そのため qa_run_claude_stage を呼ばず独自 wrapper として実装する。
#
#   #411 で stream-json の tool_use 検出 + セッション継続時間計測を追加。tool_use 検出は
#   stream-json 1 行に `"type":"tool_use"` を含む grep で観測する（grep -q で stream を
#   早期短絡せず最後まで読む必要があるため、tee 出力先 file を後段で 1 度だけ grep する）。
fr_invoke_claude() {
  local prompt="$1"
  local stage_label="$2"
  local dedicated_log_path="${3-}"

  # quota 検出用の中間 TSV ファイル（同一 cycle 内の他 stage と衝突しないよう mktemp）
  local detect_file
  if ! detect_file=$(mktemp 2>/dev/null); then
    fr_warn "fr_invoke_claude: mktemp 失敗 stage=$stage_label"
    return 1
  fi
  : > "$detect_file"

  # 専用ログファイルの確保（Req 2.1 / 2.4 / 2.6）。
  # 親ディレクトリ作成 + touch を試行し、失敗したら警告して /dev/null fallback で続行
  # （fail-continue / Req 2.6）。dedicated_log_path が空文字なら最初から fallback。
  local effective_dedicated_log="${dedicated_log_path:-}"
  if [ -n "$effective_dedicated_log" ]; then
    local _ded_dir
    _ded_dir=$(dirname "$effective_dedicated_log")
    if ! mkdir -p "$_ded_dir" 2>/dev/null; then
      fr_warn "fr_invoke_claude: 専用ログ親 dir 作成失敗 path=$_ded_dir（/dev/null fallback）"
      effective_dedicated_log=""
    elif ! : > "$effective_dedicated_log" 2>/dev/null; then
      fr_warn "fr_invoke_claude: 専用ログファイル truncate 失敗 path=$effective_dedicated_log（/dev/null fallback）"
      effective_dedicated_log=""
    fi
  fi

  # $LOG（呼出側 cron.log への観測互換）と dedicated_log の両方に append するため、
  # tee 1 段だけでは賄えない場合は 2 段 tee する。effective_dedicated_log が空文字なら
  # $LOG のみへ append（既存挙動互換）、$LOG も空文字なら /dev/null へ捨てる。
  local primary_log="${LOG:-/dev/null}"
  local secondary_log="${effective_dedicated_log:-/dev/null}"

  # NFR 2.2 / Req 2.5: 専用ログ名と保存先を一次運用ログ（cron.log）にも記録
  if [ -n "$effective_dedicated_log" ]; then
    fr_log "claude session start label=$stage_label model=${FAILED_RECOVERY_DEV_MODEL} max_turns=${FAILED_RECOVERY_MAX_TURNS} dedicated_log=$effective_dedicated_log"
  else
    fr_log "claude session start label=$stage_label model=${FAILED_RECOVERY_DEV_MODEL} max_turns=${FAILED_RECOVERY_MAX_TURNS}"
  fi

  # セッション継続時間計測（#411 Req 1.2）
  local session_start_epoch
  session_start_epoch=$(date +%s 2>/dev/null || echo "0")

  # 2 段 tee: claude → tee primary_log → tee secondary_log → qa_detect_rate_limit
  # set +e/-e で囲って pipefail 起因の即時 exit を一時抑止し、PIPESTATUS[0] で
  # claude 本体の exit code を取り出す（quota-aware の同型ロジックを踏襲）。
  local claude_rc=0
  set +e
  claude -p "$prompt" \
    --model "$FAILED_RECOVERY_DEV_MODEL" \
    --max-turns "$FAILED_RECOVERY_MAX_TURNS" \
    --permission-mode bypassPermissions \
    --output-format stream-json 2>&1 \
    | tee -a "$primary_log" \
    | tee -a "$secondary_log" \
    | qa_detect_rate_limit > "$detect_file"
  local _fr_pipestatus=("${PIPESTATUS[@]}")
  set -e
  claude_rc="${_fr_pipestatus[0]:-0}"

  # セッション継続時間（end - start）
  local session_end_epoch
  session_end_epoch=$(date +%s 2>/dev/null || echo "$session_start_epoch")
  local elapsed_seconds=$((session_end_epoch - session_start_epoch))
  if [ "$elapsed_seconds" -lt 0 ]; then
    elapsed_seconds=0
  fi

  # quota 検出（epoch 付き行が 1 行でもあれば exit 99 sentinel）
  local quota_detected=0
  if [ -s "$detect_file" ]; then
    local epoch_line
    epoch_line=$(awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ { last = $0 } END { print last }' "$detect_file")
    if [ -n "$epoch_line" ]; then
      quota_detected=1
      local path_field
      path_field="${epoch_line%%$'\t'*}"
      fr_log "claude session quota detected label=$stage_label path=$path_field"
      rm -f "$detect_file"
      return 99
    fi
  fi
  rm -f "$detect_file"

  # #411 Req 1.2: stream-json 中の tool_use イベント観測。
  # primary_log / secondary_log 双方の末尾を grep する（どちらか可読な方で十分）。
  # claude --output-format stream-json は tool_use を `"type":"tool_use"` JSON 行で出力する。
  local tool_use_observed=0
  local _grep_source=""
  if [ -n "$effective_dedicated_log" ] && [ -r "$effective_dedicated_log" ]; then
    _grep_source="$effective_dedicated_log"
  elif [ -n "${LOG:-}" ] && [ -r "${LOG:-}" ]; then
    _grep_source="$LOG"
  fi
  if [ -n "$_grep_source" ]; then
    if grep -qE '"type"[[:space:]]*:[[:space:]]*"tool_use"' "$_grep_source" 2>/dev/null; then
      tool_use_observed=1
    fi
  fi

  # 即時失敗判定（#411 Req 1.2 / 1.7）
  local threshold_seconds="${FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS:-10}"
  if fr_classify_immediate_failure "$claude_rc" "$quota_detected" "$tool_use_observed" "$elapsed_seconds" "$threshold_seconds"; then
    # NFR 2.1: 判定根拠を一次運用ログに残す（exit code / tool_use 観測有無 / 経過秒）
    fr_log "claude session immediate-failure label=$stage_label rc=$claude_rc tool_use=$tool_use_observed elapsed=${elapsed_seconds}s threshold=${threshold_seconds}s"
    return 98
  fi

  fr_log "claude session end label=$stage_label rc=$claude_rc tool_use=$tool_use_observed elapsed=${elapsed_seconds}s"
  return "$claude_rc"
}
