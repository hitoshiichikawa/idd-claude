#!/usr/bin/env bash
# shellcheck shell=bash
# pr-reviewer.sh — watcher の PR Reviewer Processor モジュール（family orchestrator）
#
# family: pr-reviewer / prefix: pr_
#   #470 で本モジュールを責務単位の module family へ分割した。orchestrator（本ファイル）と
#   2 つの sub-file が同一 prefix `pr_` を共有する（family 全体で 1 prefix）。分割マニフェスト
#   （どの関数がどのファイルにあるか）:
#     - pr-reviewer.sh         … 本ファイル: エントリ / 候補取得 / 冪等判定 / catch-up /
#                                 merge gate visibility（#412）
#         process_pr_reviewer（エントリ）/ pr_resolve_tool / pr_build_marker /
#         pr_already_processed / pr_fetch_candidate_prs / pr_broadcast_error_to_prs /
#         process_claude_review_status_catchup / pr_catchup_should_defer_for_adjudicator /
#         mgv_claude_review_required / mgv_pr_has_claude_review_status /
#         mgv_pr_has_adjudicator_marker / mgv_add_attention_label /
#         mgv_remove_attention_label / process_claude_review_merge_gate_visibility
#     - pr-reviewer-exec.sh    … 外部ツール実行（codex / antigravity 起動・timeout・出力取得）+
#                                 Issue #403 exec-fail-streak リトライ抑止
#         pr_check_tool_installed / pr_check_tool_authenticated / pr_default_prompt /
#         pr_build_prompt_file / pr_substitute_placeholders / pr_execute_review_command /
#         pr_run_review_for_pr（1 PR 分のレビュー統括）/ pr_extract_exec_fail_streak /
#         pr_read_exec_fail_streak / pr_write_exec_fail_streak / pr_reset_exec_fail_streak /
#         pr_increment_exec_fail_streak / pr_exec_fail_limit_reached / pr_truncate_stderr_tail /
#         pr_save_stderr_artifact / pr_post_exec_fail_escalation_comment
#     - pr-reviewer-publish.sh … 結果投稿（PR コメント / VERDICT 検出 / needs-iteration 連携 /
#                                 commit status publish #349）
#         pr_post_review_comment / pr_post_error_comment / pr_detect_iteration_keyword /
#         pr_add_iteration_label / pr_status_check_enabled / pr_publish_commit_status /
#         pr_publish_codex_status / pr_publish_claude_status /
#         pr_publish_claude_status_from_branch
#
#   process_* / mgv_*（Issue #412 Merge Gate Visibility）は pr_ 命名ではないが、本ファイルの
#   責務（cycle-level entry point / merge gate 可視化）に固有のため family 内に同居させる
#   （#469 の build_recovery_hint と同様の非 prefix 例外。cross-module 化は scope 外）。
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
#   - 健全性チェック: pr_check_tool_installed / pr_check_tool_authenticated（pr-reviewer-exec.sh）
#   - 重複防止 marker: pr_build_marker / pr_already_processed（gh api comments + jq）
#   - 候補 PR 列挙: pr_fetch_candidate_prs（open + 非 draft + head pattern + 非 fork）
#   - レビュー実行: pr_build_prompt_file / pr_substitute_placeholders /
#     pr_execute_review_command（subshell + trap で head checkout / BASE 復帰 /
#     read-only invariant 検査）（いずれも pr-reviewer-exec.sh）
#   - コメント投稿: pr_post_review_comment / pr_post_error_comment（hidden marker 付き、
#     pr-reviewer-publish.sh）
#   - VERDICT 検出 / ラベル付与: pr_detect_iteration_keyword / pr_add_iteration_label
#     （pr-reviewer-publish.sh）
#   - 1 PR 分のレビューを統括: pr_run_review_for_pr（pr-reviewer-exec.sh）
#
# 配置先:
#   $HOME/bin/modules/pr-reviewer*.sh（install.sh が local-watcher/bin/modules/ から *.sh を
#   glob 配布するため、family の全ファイルが同時に配布される）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - family の sub-file は REQUIRED_MODULES で orchestrator より前に登録する（bash の遅延束縛
#     により source 順は不問だが、規約に従い sub → orchestrator の順に並べる）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pr_log / pr_warn / pr_error は core_utils.sh に定義済み（#261 task 1 で追加）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_REVIEWER_ENABLED /
#     $PR_REVIEWER_TOOL / $PR_REVIEWER_CODEX_ENABLED / $PR_REVIEWER_ANTIGRAVITY_ENABLED /
#     $PR_REVIEWER_MAX_PRS / $PR_REVIEWER_EXEC_TIMEOUT 等）は本体冒頭の Config ブロックで
#     定義される（watcher-config.sh）。bash の遅延束縛により呼び出し時に解決される。
#   - family 内の cross-file 呼び出し（例: process_pr_reviewer → pr_run_review_for_pr /
#     pr_check_tool_installed 等）も遅延束縛で解決される（loader が main loop 前に全 module を source）。
#   - top-level orchestration 呼び出し配線（process_pr_reviewer || pr_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ）。
#   - 外部 CLI: gh / git / jq / codex / agy（健全性チェック・レビュー実行で使用）。
#
# セットアップ参照先:
#   - 設計: docs/specs/261-feat-pr-codex-antigravity/design.md
#   - README「PR Reviewer Processor (#261)」節

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
#   AC: 3.3, 6.2, 6.3, NFR 4.1, Issue #420 Req 1.1〜1.6 / 3.1〜3.4
#
#   - `gh api --paginate --slurp /repos/$REPO/issues/<n>/comments?per_page=100`
#     で全ページを 1 配列にまとめて取得し、jq で marker（sha と kind の双方一致）の
#     存在を test する（tool 属性は照合に使わない = Decision 6 の (sha, kind) 単位
#     重複判定）。
#   - `--paginate --slurp` は各ページ JSON 配列を outer JSON 配列 `[[page1...],
#     [page2...]]` にラップして返すため、jq 側で `add // []` により単一の配列に
#     平坦化して `any(...)` で走査する（0 ページ / 単ページ / 複数ページいずれも同じ
#     fold で扱える / Req 1.3, 1.4）。
#   - `per_page=100` は GitHub REST API の最大値（既定 30 件）。これによりコメント
#     100 件以下の PR は 1 ページのみで完結し、API 呼び出し回数は導入前と同一に保たれる
#     （NFR 2.1）。101 件以上のときのみ追加ページが発火する。
#   - sha は hex、kind は固定語彙のため正規表現メタ文字を含まず test() に安全。
#   - gh API 失敗（authentication / rate-limit / timeout / 途中ページ失敗）時は
#     **安全側（重複投稿回避）** に倒し「既存扱い (rc=0)」で skip。`gh api --paginate`
#     は途中ページ取得失敗時に非ゼロ終了するため、それまでに取得済みのページに
#     marker が無くても全体としてフォールバック経路に合流する（Req 3.1, 3.2）。
#     SHA が不変なら次サイクルで再評価されるため self-heal する（Req 3.3 / NFR 3.1 で
#     WARN 記録）。
# ─────────────────────────────────────────────────────────────────────────────
pr_already_processed() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local kind="${3:-}"

  local comments_json
  if ! comments_json=$(timeout "$PR_REVIEWER_GIT_TIMEOUT" \
      gh api --paginate --slurp \
      "/repos/${REPO}/issues/${pr_number}/comments?per_page=100" 2>/dev/null); then
    pr_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"
    return 0
  fi

  # --paginate --slurp の戻りは [[page1...], [page2...], ...] 形式。`add // []` で
  # 平坦化して any(...) で走査する。空配列・単ページ・複数ページの全パターンで同一
  # フィルタが機能する（Req 1.2, 1.3, 1.4）。
  if echo "$comments_json" | jq -e \
      --arg sha "$sha" \
      --arg kind "$kind" \
      '(add // []) | any(.[]; (.body // "") | test("idd-claude:pr-reviewer sha=" + $sha + "[^>]*kind=" + $kind))' \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
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

    # Issue #404 / adjudicator catch-up suppression: adjudicator 管轄 PR
    # （gate ON + marker `<!-- idd-claude:pr-adjudicator sha=<sha> -->` 存在）は
    # adjudicator が単独 publisher として claude-review を確定するため catch-up を defer
    # （Architecture Decision: claude-review publisher contention / Behavior contract 1）。
    # gate OFF / marker 不在 / sha 不一致は false 返却 → 既存 catch-up 経路を継続（NFR 1.1）。
    if pr_catchup_should_defer_for_adjudicator "$pr_number" "$sha"; then
      pr_log "claude-review catch-up: PR #${pr_number} を adjudicator 管轄として skip (sha=${sha})"
      continue
    fi

    pr_publish_claude_status_from_branch "$pr_number" "$sha" "$head_ref" "$pr_url" || true
    processed=$((processed + 1))
  done <<< "$pr_iter"

  pr_log "claude-review catch-up: サマリ processed=${processed} overflow=${overflow}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pr_catchup_should_defer_for_adjudicator (Issue #404)
#
# adjudicator 管轄 PR で catch-up を skip するかどうかを判定する read-only helper。
#   入力: $1 = pr_number, $2 = sha
#   出力: なし
#   戻り値: 0 = defer（catch-up を skip）/ 1 = catch-up 続行
#
# Req: 3.2 (adjudicator が claude-review を publish) / 4.3 (marker key の self-filter 非衝突)
#
# 挙動（Architecture Decision: claude-review publisher contention / Behavior contract 1, 4）:
#   - gate OFF（PR_REVIEWER_ADJUDICATOR_ENABLED != true）→ 即 return 1（既存 catch-up
#     挙動を維持 / NFR 1.1）。
#   - gate ON + adjudicator marker `<!-- idd-claude:pr-adjudicator sha=<sha> ... -->` が
#     PR コメントに 1 件以上ある場合 → return 0（defer）。
#   - gate ON + marker 不在（adjudicator が exec 失敗 / passthrough fallback で marker
#     未投稿）→ return 1（catch-up が引き継ぎ publish）。
#   - gate ON + marker 存在だが sha 不一致 → return 1（別 sha の marker は対象外）。
#   - gh API 失敗 → return 1（安全側で catch-up 続行 / adjudicator marker 不在として扱う /
#     passthrough 経路と整合）。
#
# 副作用なし（`gh pr view --json comments` の read-only fetch のみ）。
# 未信頼入力対策: pr_number は ^[0-9]+$、sha は ^[0-9a-f]{7,40}$ で strict 検証してから
# 使用（pr_publish_commit_status と同方針）。jq には --arg でリテラル渡し（filter inline
# 展開禁止 / CLAUDE.md §5）。
# ─────────────────────────────────────────────────────────────────────────────
pr_catchup_should_defer_for_adjudicator() {
  local pr_number="${1:-}"
  local sha="${2:-}"

  # gate OFF 早期 return（NFR 1.1 既存 catch-up 挙動を維持）
  if ! adj_gate_enabled; then
    return 1
  fi

  # 入力検証（未信頼入力 / 安全側）
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    return 1
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  # gh pr view --json comments で marker を fetch
  # --jq でクエリを実行し、結果は本文文字列のリスト（改行区切り）
  local comments_body
  if ! comments_body=$(timeout "$timeout_s" \
      gh pr view "$pr_number" --repo "$REPO" --json comments \
      --jq '.comments[].body' 2>/dev/null); then
    # gh 取得失敗 → 安全側で catch-up 続行（marker 不在として扱う）
    return 1
  fi

  if [ -z "$comments_body" ]; then
    return 1
  fi

  # marker `<!-- idd-claude:pr-adjudicator sha=<sha> ` の存在を厳密一致で判定
  # （sha 不一致の marker は別 sha 対象として無視 / Behavior contract）。
  # `--` でオプション解釈打ち切り（未信頼 sha 値の混入予防 / CLAUDE.md §5）。
  local needle="idd-claude:pr-adjudicator sha=${sha}"
  if printf '%s\n' "$comments_body" | grep -F -q -- "$needle"; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Issue #412: Merge Gate Visibility（mgv_*）
#
# `claude-review` を branch protection の required status に採用した repo で、
# adjudicator も Reviewer catch-up も発火せず `claude-review` が publish されず、
# merge gate を満たせないまま停滞している PR を検知して可視化する。
#
# 関数 prefix: `mgv_`（merge gate visibility）。
# 配置: pr-reviewer.sh に同居（CLAUDE.md「機能追加ガイドライン §1」既存責務同居方針）。
#
# 要件 (#412 Req 4.1〜4.5):
#   - While 監視対象 PR が `claude-review` を required status に持ち、当該 PR の head sha に
#     対して adjudicator marker と Reviewer catch-up publish のいずれも記録されていない
#     状態 → 停滞状態を運用者が事後に判別できる形でログに残す（Req 4.1）
#   - ラベル付与 / コメント投稿 / commit status publish のいずれか 1 つ以上の可視化（Req 4.2）
#   - 解消時（adjudicator 発火 / catch-up 発火 / required 設定変更）に冪等取り消し（Req 4.3）
#   - adjudicator が exec 失敗等で marker 未投稿の場合は `FALLBACK_ON_FAIL` 経路を優先し、
#     両経路とも publish に至らない場合のみ本可視化を発火（Req 4.4）
#
# 後方互換性（NFR 1.x）:
#   - `claude-review` が required でない repo（branch protection 未設定 / 別 context のみ
#     required）では `gh api` を 1 回呼ぶ以外の副作用ゼロ。即 return 0。
#   - 不正な permission（branch protection の admin 権限不足）で API 失敗時は WARN + skip。
# ─────────────────────────────────────────────────────────────────────────────

# mgv_log_prefix: 既存 pr_log / pr_warn を流用（独立ロガーを増やさない / 観測ログ粒度抑制）。

# mgv_label_name: 停滞 PR に付与するラベル名。idd-claude-labels.sh と整合。
MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION="needs-merge-gate-attention"

# ─────────────────────────────────────────────────────────────────────────────
# mgv_claude_review_required: 指定 base branch の branch protection で `claude-review` が
#   required status checks に含まれているかを判定する read-only ヘルパー。
#   入力: $1 = base_branch_name
#   出力: なし（stdout に副作用を出さない / `gh api` の結果は jq でフィルタ済み）
#   戻り値: 0 = required である / 1 = required ではない / 2 = API 取得失敗（fail-safe）
#
#   - `gh api repos/{owner}/{repo}/branches/{branch}/protection` を timeout 付きで呼ぶ。
#   - jq で `.required_status_checks.contexts[]` を列挙し `claude-review` の存在を確認。
#   - 失敗時（404 = protection 未設定 / 権限不足 / network error）は rc=2 を返し、
#     呼び出し元で fail-safe（required ではないとして扱う）に倒す。
#   - base_branch_name は GitHub branch 名の正規表現 `^[A-Za-z0-9._/-]+$` で軽く検証
#     してから URL path に展開する（CLAUDE.md §5 未信頼入力 / branch 名は半信頼）。
# ─────────────────────────────────────────────────────────────────────────────
mgv_claude_review_required() {
  # ローカル変数名は `base_branch_arg` とし、グローバル `$BASE_BRANCH` との混同
  # （shellcheck SC2153 info）を避ける。
  local base_branch_arg="${1:-}"
  if [ -z "$base_branch_arg" ]; then
    return 1
  fi
  # branch 名は server から fetch する値だが、念のため URL 展開前に正規表現で検証する
  # （オプション注入 / path traversal の予防 / CLAUDE.md §5）。
  # 先頭 `-` の branch 名は `gh api` の引数解釈で option として解釈される恐れがあるため reject。
  if ! [[ "$base_branch_arg" =~ ^[A-Za-z0-9._/][A-Za-z0-9._/-]*$ ]]; then
    return 1
  fi
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local contexts_json
  if ! contexts_json=$(timeout "$timeout_s" \
      gh api -X GET "repos/${REPO}/branches/${base_branch_arg}/protection" \
      --jq '.required_status_checks.contexts // []' 2>/dev/null); then
    # 404（protection 未設定）/ 403（権限不足）/ ネットワーク失敗 → fail-safe
    return 2
  fi
  if [ -z "$contexts_json" ]; then
    return 1
  fi
  # jq で `claude-review` が含まれているかを判定（--arg で安全に渡す / CLAUDE.md §5）。
  local has_claude_review
  has_claude_review=$(printf '%s\n' "$contexts_json" \
    | jq -r --arg ctx "claude-review" 'map(select(. == $ctx)) | length' 2>/dev/null || echo "0")
  if [ "$has_claude_review" = "0" ] || [ -z "$has_claude_review" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# mgv_pr_has_claude_review_status: 当該 PR の head sha 上に `claude-review` commit status が
#   既に publish されているかを判定する read-only ヘルパー。
#   入力: $1 = sha
#   戻り値: 0 = 既に publish 済（pending を除く確定 state がある）/ 1 = 未 publish / 2 = API 失敗
#
#   - GitHub Commit Status API の `state` は当該 sha について最新の publish を集約した
#     combined state を返す。本ヘルパは「`claude-review` context に対する個別 publish」が
#     1 件でもあるかを判定するため、`statuses` 配列を列挙して context 名で照合する。
#   - 失敗時は rc=2 で呼び出し元に伝播し、安全側で「未確定（= 可視化発火を抑止）」に倒す。
# ─────────────────────────────────────────────────────────────────────────────
mgv_pr_has_claude_review_status() {
  local sha="${1:-}"
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    return 1
  fi
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local statuses_json
  if ! statuses_json=$(timeout "$timeout_s" \
      gh api -X GET "repos/${REPO}/commits/${sha}/statuses" \
      --jq '[.[] | .context] // []' 2>/dev/null); then
    return 2
  fi
  if [ -z "$statuses_json" ]; then
    return 1
  fi
  local has_status
  has_status=$(printf '%s\n' "$statuses_json" \
    | jq -r --arg ctx "claude-review" 'map(select(. == $ctx)) | length' 2>/dev/null || echo "0")
  if [ "$has_status" = "0" ] || [ -z "$has_status" ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# mgv_pr_has_adjudicator_marker: 当該 PR コメントに adjudicator marker が存在するかを判定。
#   入力: $1 = pr_number, $2 = sha
#   戻り値: 0 = marker あり / 1 = marker なし / 2 = API 失敗
#
#   pr_catchup_should_defer_for_adjudicator と同じ marker 形式
#   `<!-- idd-claude:pr-adjudicator sha=<sha> -->` を grep する。
#   gate ON / OFF に依存せず marker の有無のみで判定する点が
#   pr_catchup_should_defer_for_adjudicator と異なる（本ヘルパは可視化判定用）。
# ─────────────────────────────────────────────────────────────────────────────
mgv_pr_has_adjudicator_marker() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    return 1
  fi
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local comments_body
  if ! comments_body=$(timeout "$timeout_s" \
      gh pr view "$pr_number" --repo "$REPO" --json comments \
      --jq '.comments[].body' 2>/dev/null); then
    return 2
  fi
  if [ -z "$comments_body" ]; then
    return 1
  fi
  local needle="idd-claude:pr-adjudicator sha=${sha}"
  if printf '%s\n' "$comments_body" | grep -F -q -- "$needle"; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# mgv_add_attention_label / mgv_remove_attention_label: ラベル付与・解消（冪等）。
# ─────────────────────────────────────────────────────────────────────────────
mgv_add_attention_label() {
  local pr_number="${1:-}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" \
      --add-label "$MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION" >/dev/null 2>&1; then
    pr_warn "merge-gate-visibility: PR #${pr_number}: ${MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION} ラベルの付与に失敗"
    return 1
  fi
  return 0
}

mgv_remove_attention_label() {
  local pr_number="${1:-}"
  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  # 未付与でも gh pr edit --remove-label は冪等 no-op（404 にはならない）。失敗時のみ WARN。
  if ! timeout "$timeout_s" \
      gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION" >/dev/null 2>&1; then
    pr_warn "merge-gate-visibility: PR #${pr_number}: ${MGV_LABEL_NEEDS_MERGE_GATE_ATTENTION} ラベルの解除に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_claude_review_merge_gate_visibility (Issue #412 Req 4)
#
# `claude-review` を required status に持つ repo で、adjudicator も Reviewer catch-up も
# 発火せず `claude-review` が publish されないまま停滞している PR を可視化する Processor。
#
# 起動条件:
#   - 既存 `pr_fetch_candidate_prs` で取得した open / 非 draft / head pattern 一致の PR を対象。
#   - 1 サイクル最初の PR について `mgv_claude_review_required` で `claude-review` が
#     required status checks に含まれているかを判定。required でなければ即 return 0
#     （`gh api` を 1 回呼ぶ以外の副作用ゼロ / NFR 1.1）。
#
# 可視化判定（PR 単位）:
#   1. PR の head sha 上に `claude-review` commit status が既に publish 済 → 解消とみなして
#      `needs-merge-gate-attention` を除去（Req 4.3 冪等取り消し）
#   2. adjudicator marker（`<!-- idd-claude:pr-adjudicator sha=<sha> -->`）が当該 sha に対して
#      投稿されている → 解消とみなして label 除去（Req 4.3）
#   3. それ以外（publish なし + marker なし） → `needs-merge-gate-attention` を付与し
#      `pr_log` で「停滞」を 1 行ログする（Req 4.1, 4.2）
#
# 配置順（issue-watcher.sh 側）:
#   process_claude_review_status_catchup の **直後** に呼ぶ。catch-up が同サイクル内で publish に
#   成功した場合は、次サイクル冒頭で当該 PR がケース 1 として解消され label が除去される
#   （冪等取り消し / Req 4.3）。
#
# 戻り値: 常に 0（後続 processor を阻害しない / NFR 1.1）。
# ─────────────────────────────────────────────────────────────────────────────
process_claude_review_merge_gate_visibility() {
  local prs_json total
  prs_json=$(pr_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$total" -eq 0 ]; then
    return 0
  fi

  # 1 サイクル冒頭で 1 回だけ branch protection を確認する。required でなければ全 PR を
  # 一括 skip（gh API 呼び出し総数を抑制 / NFR 2.1 観測ログ粒度）。
  # base branch は `BASE_BRANCH`（issue-watcher.sh で resolve 済み）。
  local req_rc=0
  mgv_claude_review_required "${BASE_BRANCH:-main}" || req_rc=$?
  if [ "$req_rc" -ne 0 ]; then
    # required ではない (rc=1) / API 失敗 (rc=2) はいずれも fail-safe で skip
    # （API 失敗は noisy なログを避けるため pr_log は出さない / 4xx は GitHub 仕様で
    # branch protection 未設定 repo では正常レスポンス）。
    return 0
  fi

  pr_log "merge-gate-visibility: claude-review が ${BASE_BRANCH:-main} の required status に含まれる → 停滞 PR scan 開始（候補 ${total} 件）"

  # 上限件数 (PR_REVIEWER_MAX_PRS) で truncate する点も process_claude_review_status_catchup と整合。
  local target_count="$total" overflow=0
  if [ -n "${PR_REVIEWER_MAX_PRS:-}" ] && [ "$total" -gt "$PR_REVIEWER_MAX_PRS" ]; then
    target_count="$PR_REVIEWER_MAX_PRS"
    overflow=$((total - PR_REVIEWER_MAX_PRS))
  fi

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    return 0
  fi

  local stalled=0 cleared=0
  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local pr_number sha
    pr_number=$(echo "$pr_json" | jq -r '.number')
    sha=$(echo "$pr_json"       | jq -r '.headRefOid')

    if ! [[ "$pr_number" =~ ^[0-9]+$ ]] || ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
      continue
    fi

    # ケース 1: `claude-review` が既に publish 済 → 冪等取り消し
    if mgv_pr_has_claude_review_status "$sha"; then
      mgv_remove_attention_label "$pr_number" >/dev/null 2>&1 || true
      cleared=$((cleared + 1))
      continue
    fi

    # ケース 2: adjudicator marker あり → adjudicator が当該 sha を管轄 → 冪等取り消し
    if mgv_pr_has_adjudicator_marker "$pr_number" "$sha"; then
      mgv_remove_attention_label "$pr_number" >/dev/null 2>&1 || true
      cleared=$((cleared + 1))
      continue
    fi

    # ケース 3: 停滞検知 → ラベル付与 + 観測ログ
    mgv_add_attention_label "$pr_number" >/dev/null 2>&1 || true
    pr_log "merge-gate-visibility: PR #${pr_number} sha=${sha} 停滞検知（required=claude-review / adjudicator marker 不在 / claude-review status 未 publish）"
    stalled=$((stalled + 1))
  done <<< "$pr_iter"

  pr_log "merge-gate-visibility: サマリ stalled=${stalled} cleared=${cleared} overflow=${overflow}"
  return 0
}
