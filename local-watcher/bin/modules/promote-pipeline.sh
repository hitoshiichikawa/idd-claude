#!/usr/bin/env bash
# shellcheck shell=bash
# promote-pipeline.sh — watcher の Promote Pipeline プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した Promote Pipeline Processor (#15) の関数定義を集約する。
#   Phase A により BASE_BRANCH に merge された変更について ST check-run 結果をポーリングし、
#   success なら PROMOTION_TARGET_BRANCH への fast-forward 昇格、failure なら git revert +
#   reopen + st-failed 付与を行う（PROMOTE_PIPELINE_ENABLED=true の opt-in 機能）。
#   pp_resolve_target_branch / pp_collect_merged_issues / pp_get_st_state /
#   pp_handle_st_failure / pp_handle_st_success / pp_do_promote / process_promote_pipeline ほか。
#
#   #472 で Path Overlap Checker（po_*）を path-overlap.sh へ分割した（#181 design.md
#   decision 3 の同居方針から独立モジュール化。REQUIRED_MODULES に path-overlap.sh を
#   sub として追加）。両ファイルの間に関数呼び出し依存は無い（process_promote_pipeline は
#   po_* を一切呼ばない。dispatcher が po_check_dispatch_gate を独立に呼ぶ既存構造は不変）。
#
# 配置先:
#   $HOME/bin/modules/promote-pipeline.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pp_log / pp_warn / pp_error は core_utils.sh に定義済み（#180 Part 2）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PROMOTION_TARGET_BRANCH / $PROMOTE_MODE /
#     $PROMOTE_PIPELINE_ENABLED / $LABEL_STAGED_FOR_RELEASE / $LABEL_ST_FAILED 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_promote_pipeline || pp_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ / #181 design.md）。
#   - revert / promote は `--force-with-lease` または fast-forward 限定の `--force`
#     （無条件 `--force` は使わない / CLAUDE.md Phase B 注意事項）。
#   - 外部 CLI: gh / git / jq。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md
#   - README「Phase B Promote Pipeline」節


# pp_resolve_target_branch: `PROMOTION_TARGET_BRANCH` のリモート存在を検証し、
# `BASE_BRANCH` と異なることを確認する（Req 1.1.3, 1.2.2）。
# 戻り値: 0 = 検証 OK / 1 = 中止すべき状態
pp_resolve_target_branch() {
  # AC 1.1.3: BASE_BRANCH == PROMOTION_TARGET_BRANCH なら no-op として終了
  if [ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]; then
    pp_log "BASE_BRANCH と PROMOTION_TARGET_BRANCH が同一 ('$BASE_BRANCH')、Phase B は no-op"
    return 1
  fi
  # AC 1.2.2: リモートに存在するか検証
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
    pp_error "PROMOTION_TARGET_BRANCH '$PROMOTION_TARGET_BRANCH' がリモートに存在しません。promote を中止します。"
    return 1
  fi
  return 0
}

# pp_issue_has_label: Issue が指定ラベルを持つか確認するヘルパー。
# 戻り値: 0 = 持つ / 1 = 持たない or 取得失敗
pp_issue_has_label() {
  local issue_number="$1"
  local label="$2"
  local labels_json
  if ! labels_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    return 1
  fi
  echo "$labels_json" | jq -e --arg l "$label" \
    '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# pp_remove_ready_for_review_if_present: Issue から `ready-for-review` ラベルを
# 除去する（#413）。`staged-for-release` 自動付与対象として確定した Issue 集合に
# 対して `pp_collect_merged_issues` 内のループから呼ばれる。
#
# 設計判断:
#   - 既に `ready-for-review` が付与されていない（人間が手動付与しなかった / 既に
#     除去済み）Issue では `gh issue edit` を再送しない（NFR 2.1 / Req 1.3）。
#     ラベル状態は `pp_issue_has_label` で事前確認する（`gh issue view --json labels`
#     を 1 回呼ぶ）。
#   - 数値 ID `^[0-9]+$` の再検証を行う（NFR 3.2 / 防御層）。jq capture 側で既に
#     担保されているが、`gh issue edit` 引数や URL に展開する直前の最終ゲート。
#   - 除去失敗（タイムアウト / non-zero exit / レート制限）時は WARN ログを 1 行
#     残し、戻り値 0 を返して呼び出し側の per-Issue ループを継続させる（Req 1.5 /
#     Req 4.3 / NFR 3.1 fail-continue）。
#   - 既未付与時の INFO ログは出力しない（Req 4.2: 既存 staged-for-release 重複付与
#     スキップ集計と区別可能な「個別 INFO ログを出さない」選択肢を採用）。
#
# 入力: $1 = Issue 番号
# 副作用:
#   - `ready-for-review` 付与済なら `gh issue edit --remove-label ready-for-review`
#   - 成功時 `issue=#N action=label-remove label=ready-for-review source=auto` ログ
#   - 失敗時 `issue=#N ready-for-review 除去に失敗（後続 Issue は継続）` WARN ログ
# 戻り値: 常に 0（fail-continue）
#
# Requirements: 1.1, 1.2, 1.3, 1.5, 1.6, 3.3, 4.1, 4.2, 4.3, NFR 2.1, NFR 3.2
pp_remove_ready_for_review_if_present() {
  local issue_number="$1"
  # NFR 3.2: `gh issue edit` 引数 / URL 展開直前の数値 ID 再検証。
  # 不正値（capture 漏れ / 異常な closingIssuesReferences 値）はサイレントに skip。
  if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  # NFR 2.1 / Req 1.3: 既未付与なら API 再送しない（pp_issue_has_label 内部で
  # `gh issue view --json labels` を 1 回呼ぶのみ。NFR 2.2 の追加 gh issue list /
  # gh pr list 抑制とは別軸で、per-Issue API 呼び出し回数を最小化する）。
  if ! pp_issue_has_label "$issue_number" "$LABEL_READY"; then
    return 0
  fi
  # Req 1.1 / 1.2: ready-for-review 除去。closingIssuesReferences 経路 / head ブランチ
  # 名経路の和集合から渡された Issue に対して、base ブランチが default かどうかに
  # 依存せず除去 API を発火させる。
  if timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_READY" >/dev/null 2>&1; then
    # Req 4.1: 一意判別可能なログ形式。
    pp_log "issue=#${issue_number} action=label-remove label=${LABEL_READY} source=auto"
  else
    # Req 1.5 / Req 4.3: WARN ログを 1 行残し、戻り値は 0 で後続 Issue 継続。
    pp_warn "issue=#${issue_number} ready-for-review 除去に失敗（後続 Issue は継続）"
  fi
  return 0
}

# pp_extract_linked_issues: `gh pr list --json number,headRefName,headRepositoryOwner,
# closingIssuesReferences` の JSON 出力を受け取り、`staged-for-release` 自動付与対象
# Issue 番号集合を抽出する純関数ヘルパー（#389）。
#
# 抽出ロジック:
#   - fork PR を除外（headRepositoryOwner.login != $owner の PR は対象外 / NFR 2.4）
#   - 各 PR について以下 2 経路で Issue 番号を導出し、和集合で重複排除する:
#     1. closingIssuesReferences[].number（GitHub 自動リンク。base=default branch のみ生成）
#     2. headRefName が `^claude/issue-([0-9]+)-impl-` に一致した場合のキャプチャ値
#        （#389: base=default branch でない gitflow 運用での補完経路）
#   - 抽出した数値 ID は jq の `capture` で `^[0-9]+$` を満たしているが、bash 側でも
#     使用直前に再検証する（NFR 4.2 / 防御層）
#
# 入力（$1）: gh pr list の JSON 文字列（配列）
# 入力（$2）: repo_owner（fork 判定用、headRepositoryOwner.login と完全一致比較）
# 出力（stdout）: 抽出された Issue 番号を 1 行 1 件、numeric 昇順で unique 出力
# 戻り値: 常に 0（jq エラーは空出力として扱う）
#
# Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.3, NFR 4.1, NFR 4.2
pp_extract_linked_issues() {
  local prs_json="$1"
  local repo_owner="$2"
  # jq 内で fork 除外 + 2 経路の和集合 + unique を一括処理する。head 経路は
  # `capture` で `^claude/issue-(?<n>[0-9]+)-impl-` に一致するもののみ採用し、不一致
  # （人間 PR / 設計 PR / 他フォーマット）は素通り（Req 1.3）。`headRefName` は未信頼
  # 文字列なので `--arg owner` 同様に jq 内で扱い、bash 展開を経由させない（NFR 4.1）。
  echo "$prs_json" | jq -r \
    --arg owner "$repo_owner" \
    '[.[]
      | select((.headRepositoryOwner.login // "") == $owner)
      | (
          ((.closingIssuesReferences // []) | map(.number))
          +
          ((.headRefName // "")
            | [capture("^claude/issue-(?<n>[0-9]+)-impl-") // empty | .n | tonumber])
        )
      | .[]
    ] | unique | .[]' 2>/dev/null
}

# pp_collect_merged_issues: Phase A 直後の状態で「`BASE_BRANCH` に merge 済みかつ
# `Closes #N` でリンクされている Issue」を抽出し、未付与の Issue には
# `staged-for-release` を自動付与する。fork PR は除外する（NFR 2.4）。
# 自動付与と人間付与の source 区別は行わない（Req 2.1.2、同一ラベル共有）。
#
# #389: `closingIssuesReferences` は GitHub 側で「PR の base がリポジトリの default
# branch」のときだけ自動生成されるため、gitflow 運用（`BASE_BRANCH=develop` 等）では
# 空になる。head ブランチ名 `^claude/issue-([0-9]+)-impl-` からの導出経路を併用して
# base ブランチが default かどうかに依存しない収集を行う（pp_extract_linked_issues 参照）。
#
# stdout: 現時点で `staged-for-release` を持つ全 open Issue の番号を 1 行 1 件で出力
#         （次のステップで ST 判定する対象集合になる）
# Requirements: 2.1, NFR 2.4, NFR 5.2, #389 Req 1.1-1.5
pp_collect_merged_issues() {
  local repo_owner="${REPO%%/*}"
  local recent_merged_prs_json
  # 1. is:merged base:$BASE_BRANCH の直近 PR を取得（最新 50 件、Req 5.2 範囲）
  #    #389: headRefName を取得フィールドに追加（head ブランチ名経路の導出ソース）。
  #    gh API 呼び出し回数は変えない（Req 3.5）。
  if ! recent_merged_prs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --base "$BASE_BRANCH" \
      --json number,headRefName,headRepositoryOwner,closingIssuesReferences \
      --limit 50 2>/dev/null); then
    pp_warn "merged PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # 2. fork PR を除外（NFR 2.4）し、closingIssuesReferences と headRefName 両経路から
  #    Issue 番号を抽出（#389 Req 1.1, 1.2, 1.4 / 和集合 + 重複排除）
  local linked_issues
  linked_issues=$(pp_extract_linked_issues "$recent_merged_prs_json" "$repo_owner")

  # 3. 各 Issue について `staged-for-release` ラベルの有無を確認し、
  #    未付与なら自動付与する（重複付与は抑止 / Req 2.1.1, 2.1.3）。
  #    #413: 同じ Issue 集合（closingIssuesReferences + head ブランチ名の和集合 /
  #    Req 1.6）に対して `ready-for-review` 除去も併走させる。base ブランチが
  #    default かどうかに依存せず除去経路が発火し、stale な ready-for-review が
  #    Path Overlap Checker の holder 集合に誤って残り続ける現象を防ぐ。
  local added=0
  local skipped=0
  if [ -n "$linked_issues" ]; then
    while IFS= read -r issue_number; do
      [ -n "$issue_number" ] || continue
      # #389 Req 1.5 / NFR 4.2: 数値 ID を使用直前に再検証する。jq の capture で
      # `^[0-9]+$` 一致は保証されているが、closingIssuesReferences 側の異常値も含めて
      # 防御層として bash 側でも `^[0-9]+$` を確認し、不正値は `gh issue edit` 引数や
      # URL に展開しない。
      if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
        continue
      fi
      # #413 Req 1.1 / 1.2 / 1.3 / 1.5: ready-for-review 除去（既付与時のみ API 発火、
      # 失敗時は WARN ログのみで後続 Issue 継続）。staged-for-release の付与有無に
      # 関わらず実行する（既に staged-for-release を持つ Issue でも、人間付与運用や
      # 過去サイクルの取りこぼしで ready-for-review が残っているケースを救済する）。
      pp_remove_ready_for_review_if_present "$issue_number"
      if pp_issue_has_label "$issue_number" "$LABEL_STAGED_FOR_RELEASE"; then
        # AC 2.1.3: 既付与なら API 再送しない
        skipped=$((skipped + 1))
        continue
      fi
      # AC 2.1.1: 未付与に対して自動付与
      if timeout "$PROMOTE_GIT_TIMEOUT" \
          gh issue edit "$issue_number" --repo "$REPO" \
            --add-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
        pp_log "issue=#${issue_number} action=label-add label=${LABEL_STAGED_FOR_RELEASE} source=auto"
        added=$((added + 1))
      else
        pp_warn "issue=#${issue_number} staged-for-release 自動付与に失敗（後続 Issue は継続）"
      fi
    done <<< "$linked_issues"
  fi

  pp_log "auto-label サマリ: staged-for-release-added=${added}, already-labeled-skipped=${skipped}"

  # 4. 全 staged-for-release 付き open Issue の番号を stdout に出力（自動 + 人間
  #    付与の両方を含む / Req 2.1.2）。後続 ST 判定の対象集合になる。
  timeout "$PROMOTE_GIT_TIMEOUT" gh issue list --repo "$REPO" \
    --label "$LABEL_STAGED_FOR_RELEASE" --state open \
    --json number --limit 100 --jq '.[].number' 2>/dev/null \
    || pp_warn "staged-for-release 付き Issue 一覧の取得に失敗（per-Issue 処理を見送る）"
}

# pp_resolve_merge_sha: Issue にリンクされた直近の merge commit SHA を解決する。
# GitHub の `gh issue view --json closedByPullRequestsReferences` で Issue を閉じた
# PR を取得し、各 PR の mergeCommit.oid を最新（updatedAt 降順）から拾う。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: merge commit SHA（解決できた場合）
# 戻り値: 0 = 解決成功 / 1 = 失敗（Issue が PR 経由で閉じられていない・取得失敗等）
pp_resolve_merge_sha() {
  local issue_number="$1"
  local pr_list_json
  if ! pr_list_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" \
        --json closedByPullRequestsReferences 2>/dev/null); then
    return 1
  fi
  # PR ごとに mergeCommit.oid を取得（必要に応じて gh pr view で補完）
  local pr_numbers
  pr_numbers=$(echo "$pr_list_json" | jq -r \
    '[.closedByPullRequestsReferences // [] | .[]
      | select(.state == "MERGED")
      | .number] | sort | reverse | .[]' 2>/dev/null) || return 1
  [ -n "$pr_numbers" ] || return 1
  local pr_number merge_sha
  while IFS= read -r pr_number; do
    [ -n "$pr_number" ] || continue
    merge_sha=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" \
        --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null) || continue
    # SHA40（git full object name）を厳格検証してから返す。下流の
    # `git revert "$merge_sha"`（先頭 `-` 引数注入）/ `gh api .../commits/$merge_sha/...`
    # （`../` path 横断）へ不正値が流れるのを防ぐ。不正値は未解決として次候補へ。
    if [[ "$merge_sha" =~ ^[0-9a-f]{40}$ ]]; then
      echo "$merge_sha"
      return 0
    fi
  done <<< "$pr_numbers"
  return 1
}

# pp_get_st_state: 1 つの Issue について、リンクされた最新の `BASE_BRANCH` 上
# merge commit に対する ST check-run の状態を取得する。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: 内部状態 5 種のいずれか
#   "success"   ST check-run が完了 & conclusion=success
#   "failure"   ST check-run が完了 & conclusion=failure/cancelled/timed_out/action_required
#   "pending"   ST check-run が in_progress / queued / pending
#   "missing"   ST check-run が見つからない or conclusion 不一致
#   "skip-warn" ST_CHECK_RUN_NAME 未設定（Req 2.2.3）
# 戻り値: 常に 0（呼び出し元で文字列分岐）
# Requirements: 2.2
pp_get_st_state() {
  local issue_number="$1"
  # AC 2.2.3: ST_CHECK_RUN_NAME 未設定なら skip-warn（呼び出し元で WARN ログ）
  if [ -z "$ST_CHECK_RUN_NAME" ]; then
    echo "skip-warn"
    return 0
  fi
  # AC 2.2.5: Issue にリンクされた merge commit を解決できなければ missing
  local merge_sha
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    echo "missing"
    return 0
  fi
  [ -n "$merge_sha" ] || { echo "missing"; return 0; }
  # AC 2.2.1: check-runs API で対象 commit に対する check-run 一覧を取得
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo "missing"
    return 0
  fi
  # AC 2.2.2: ST_CHECK_RUN_NAME と完全一致する check-run を抽出し、最新採用
  local target
  target=$(echo "$check_runs_json" | jq -c --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last' 2>/dev/null) || target="null"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    echo "missing"
    return 0
  fi
  # AC 2.2.4: status + conclusion で結果判定
  local status conclusion
  status=$(echo "$target" | jq -r '.status // ""')
  conclusion=$(echo "$target" | jq -r '.conclusion // ""')
  case "$status" in
    completed)
      case "$conclusion" in
        success)
          echo "success"
          ;;
        failure|cancelled|timed_out|action_required)
          echo "failure"
          ;;
        *)
          # neutral / skipped / stale / unknown は missing 扱い
          echo "missing"
          ;;
      esac
      ;;
    queued|in_progress|pending|"")
      echo "pending"
      ;;
    *)
      echo "pending"
      ;;
  esac
}

# pp_resolve_st_log_url: ST check-run の details_url を解決する（取得失敗時は空文字列）。
# 入力: $1 = Issue 番号, $2 = merge commit SHA
# 出力（stdout）: details_url または空文字列
pp_resolve_st_log_url() {
  local merge_sha="$2"
  [ -n "$ST_CHECK_RUN_NAME" ] || { echo ""; return 0; }
  [ -n "$merge_sha" ] || { echo ""; return 0; }
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo ""
    return 0
  fi
  echo "$check_runs_json" | jq -r --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last
      | (.details_url // .html_url // "")' 2>/dev/null \
    || echo ""
}

# pp_do_revert: `BASE_BRANCH` 上で merge commit を `git revert -m 1` して
# `--force-with-lease` で push する（NFR 2.1）。サブシェル内で `trap` を仕掛けて
# `BASE_BRANCH` checkout 状態への復帰を保証する（NFR 2.3）。
#
# 入力: $1 = revert 対象の merge commit SHA
# 戻り値:
#   0 = revert + push 成功
#   1 = push 失敗（リモート先行等）。呼び出し元で st-failed 付与を保留（Req 2.4.6）
#   2 = revert 自体が失敗 / checkout / pull 失敗
pp_do_revert() {
  local merge_sha="$1"
  (
    set +e
    # 復帰用 trap: revert を中断したら `git revert --abort` し、$BASE_BRANCH に戻る
    trap 'git revert --abort >/dev/null 2>&1; git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git revert -m 1 --no-edit "$merge_sha" >/dev/null 2>&1; then
      exit 2
    fi
    # NFR 2.1: --force-with-lease のみ。--force 単独は使用しない
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 1
    fi
    exit 0
  )
}

# pp_handle_st_failure: ST failure と判定された Issue について、対応する merge
# commit を revert + push、Issue reopen、`st-failed` 付与、ST log URL を含む
# 1 件のコメント投稿を実施する（Req 2.4）。fail-continue を維持し、1 件失敗しても
# 他 Issue の処理は継続する（NFR 3.1）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 全操作成功 / 1 = いずれかが失敗（呼び出し元でカウンタにのみ反映）
pp_handle_st_failure() {
  local issue_number="$1"
  local merge_sha st_log_url
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    pp_warn "issue=#${issue_number} merge SHA 解決失敗 → ST failure 処理を見送り action=skip"
    return 1
  fi
  # AC 2.4.2: revert commit を作成して push。push 失敗 → st-failed 付与を保留
  local revert_rc=0
  pp_do_revert "$merge_sha" || revert_rc=$?
  case "$revert_rc" in
    0)
      :
      ;;
    1)
      # AC 2.4.6: push 失敗（リモート先行等）→ st-failed 保留 + WARN
      pp_warn "issue=#${issue_number} revert push 失敗（リモート先行等）→ st-failed 付与を保留 action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
    *)
      pp_warn "issue=#${issue_number} revert 自体に失敗（既に revert 済み等）→ ST failure 処理を見送り action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
  esac
  # AC 2.4.1 + 2.4.4: st-failed 付与 + staged-for-release 除去を 1 call に集約
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --add-label "$LABEL_ST_FAILED" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ラベル付与/除去に失敗（revert は実施済み） action=label-fail"
    # ラベル操作の失敗は致命的でないため、reopen / comment は継続する
  fi
  # AC 2.4.3: Issue reopen
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue reopen "$issue_number" --repo "$REPO" >/dev/null 2>&1; then
    # 既に open の場合や API エラーでも次の comment を試みる
    pp_warn "issue=#${issue_number} Issue reopen に失敗（既に open の可能性あり、comment 投稿は継続）"
  fi
  # AC 2.4.3: ST log URL を含む 1 件のステータスコメントを投稿
  st_log_url=$(pp_resolve_st_log_url "$issue_number" "$merge_sha")
  local comment_body
  comment_body=$(cat <<EOF
## 🔁 ST failure 自動 revert (Phase B Promote Pipeline)

\`${BASE_BRANCH}\` に merge された変更について、ST check-run **\`${ST_CHECK_RUN_NAME}\`** が
**failure** と判定されたため、watcher が \`git revert -m 1\` で自動 revert しました。

### Revert 対象 merge commit

- SHA (short): \`${merge_sha:0:7}\`
- ST log URL: ${st_log_url:-_(取得失敗)_}

### 推奨アクション

- ST failure の原因を確認し、修正用 PR を本 Issue にリンクして作成してください
- 本 Issue は \`st-failed\` ラベル付きで自動 reopen されています

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue comment "$issue_number" --repo "$REPO" \
        --body "$comment_body" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ステータスコメント投稿に失敗（revert / label / reopen は実施済み）"
  fi
  pp_log "issue=#${issue_number} ST=failure action=revert+label-add+label-remove+reopen+comment merge_sha=${merge_sha:0:7} label=${LABEL_ST_FAILED}"
  return 0
}

# pp_handle_st_success: ST success と判定された Issue から `staged-for-release`
# ラベルを除去し、promote 候補集合（PROMOTE_CANDIDATES）に追加する。
# `PROMOTE_MODE=on-demand` の場合はラベル除去 / 集合追加とも行わず、人間トリガー
# を待つ（Req 3.2.5）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 成功 / 1 = 失敗（fail-continue で呼び出し側がカウントのみ実施）
# Requirements: 2.3, 3.2
pp_handle_st_success() {
  local issue_number="$1"
  # AC 3.2.5: on-demand モードはラベルを除去せず、PROMOTE_CANDIDATES にも入れない
  if [ "$PROMOTE_MODE" = "on-demand" ]; then
    pp_log "issue=#${issue_number} ST=success mode=on-demand action=hold-label-await-human-trigger"
    return 0
  fi
  # AC 2.3.1: staged-for-release ラベルを除去
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ST=success staged-for-release 除去に失敗（後続 Issue は継続）"
    return 1
  fi
  # AC 2.3.2: promote 候補集合に追加
  PROMOTE_CANDIDATES+=("$issue_number")
  pp_log "issue=#${issue_number} ST=success action=label-remove+promote-queued label=${LABEL_STAGED_FOR_RELEASE}"
  return 0
}

# pp_process_one_issue: 1 件の Issue について ST 状態を取得し、状態別の
# アクション（success / failure / pending / missing / skip-warn）を実施する。
# 1 件の失敗が他 Issue 処理を止めないように戻り値で集計用カウンタにのみ反映
# する（NFR 3.1 fail-continue）。
#
# 入力: $1 = Issue 番号
# 副作用（成功時のみ加算する集計用変数、呼び出し側スコープで参照）:
#   PP_ST_SUCCESS_COUNT / PP_ST_FAILURE_COUNT / PP_ST_PENDING_COUNT /
#   PP_ST_MISSING_COUNT / PP_FAIL_COUNT
pp_process_one_issue() {
  local issue_number="$1"
  local st_state
  st_state=$(pp_get_st_state "$issue_number")
  case "$st_state" in
    success)
      if pp_handle_st_success "$issue_number"; then
        PP_ST_SUCCESS_COUNT=$((PP_ST_SUCCESS_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    failure)
      if pp_handle_st_failure "$issue_number"; then
        PP_ST_FAILURE_COUNT=$((PP_ST_FAILURE_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    pending)
      # AC 2.2.4: 未完了は次サイクルに持ち越す（ラベル変更なし）
      pp_log "issue=#${issue_number} ST=pending action=skip-next-cycle"
      PP_ST_PENDING_COUNT=$((PP_ST_PENDING_COUNT + 1))
      ;;
    missing)
      # AC 2.2.5: ST check-run が存在しない → WARN + 状態変更なし
      pp_warn "issue=#${issue_number} ST=missing action=skip（check-run 不在 or merge SHA 未解決）"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    skip-warn)
      # AC 2.2.3: ST_CHECK_RUN_NAME 未設定 → WARN + 当該サイクル no-op
      pp_warn "issue=#${issue_number} ST_CHECK_RUN_NAME 未設定 → ST 連動停止 action=skip"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    *)
      pp_warn "issue=#${issue_number} 未知の ST 状態 '${st_state}' action=skip"
      PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      ;;
  esac
  return 0
}

# pp_match_cron_field: 1 つの cron フィールド（分 / 時 / 日 / 月 / 曜日）を
# 現在値とマッチングする。標準 cron のサブパターン:
#   *           （任意の値にマッチ）
#   */N         （N で割り切れる値にマッチ）
#   A-B         （A 以上 B 以下にマッチ）
#   A,B,C       （いずれかの値にマッチ）
#   <整数>      （厳密一致）
#
# 入力: $1 = cron フィールド文字列, $2 = 現在値（整数）
# 戻り値: 0 = match / 1 = no match or 不正
pp_match_cron_field() {
  local field="$1"
  local value="$2"
  [ -n "$field" ] || return 1
  # 数値以外の現在値はマッチ不能
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # `*` は全てにマッチ
  if [ "$field" = "*" ]; then
    return 0
  fi
  # `*/N` ステップ
  if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    [ "$step" -gt 0 ] || return 1
    if [ $((10#$value % step)) -eq 0 ]; then
      return 0
    fi
    return 1
  fi
  # カンマ区切りリスト
  if [[ "$field" == *,* ]]; then
    local subfield
    IFS=',' read -ra _PP_CRON_PARTS <<< "$field"
    for subfield in "${_PP_CRON_PARTS[@]}"; do
      if pp_match_cron_field "$subfield" "$value"; then
        return 0
      fi
    done
    return 1
  fi
  # `A-B` レンジ
  if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local lo="${BASH_REMATCH[1]}"
    local hi="${BASH_REMATCH[2]}"
    if [ "$((10#$value))" -ge "$lo" ] && [ "$((10#$value))" -le "$hi" ]; then
      return 0
    fi
    return 1
  fi
  # 単一整数
  if [[ "$field" =~ ^[0-9]+$ ]]; then
    if [ "$((10#$value))" -eq "$((10#$field))" ]; then
      return 0
    fi
    return 1
  fi
  return 1
}

# pp_match_cron: 標準 cron 5 フィールド式（分 時 日 月 曜日）を現在時刻と比較する。
# `date '+%M %H %d %m %u'` で取得した現在時刻と、cron 各フィールドを `pp_match_cron_field`
# でマッチング。全フィールド一致なら 0、いずれか不一致 / 不正な書式なら 1 を返す。
#
# 入力: $1 = cron 式（5 フィールドのみ。`@daily` 等の特殊文字列は非対応）
# 戻り値: 0 = 現在時刻が cron 式に一致 / 1 = 不一致 or 不正な書式
# Requirements: 3.2.4, 3.2.6
pp_match_cron() {
  local cron="$1"
  [ -n "$cron" ] || return 1
  # 5 フィールドに分解
  local -a fields
  # shellcheck disable=SC2206 # 意図的に IFS=space で分割
  fields=( $cron )
  if [ "${#fields[@]}" -ne 5 ]; then
    return 1
  fi
  local now_min now_hour now_day now_mon now_dow
  now_min=$(date '+%M')
  now_hour=$(date '+%H')
  now_day=$(date '+%d')
  now_mon=$(date '+%m')
  now_dow=$(date '+%u')   # 1=Mon, 7=Sun（cron では 0/7 が Sun のため両対応が望ましい）
  pp_match_cron_field "${fields[0]}" "$now_min"  || return 1
  pp_match_cron_field "${fields[1]}" "$now_hour" || return 1
  pp_match_cron_field "${fields[2]}" "$now_day"  || return 1
  pp_match_cron_field "${fields[3]}" "$now_mon"  || return 1
  # 曜日: cron では 0=Sun, 1=Mon..6=Sat。`date +%u` は 1=Mon..7=Sun のため、
  # まず %u で比較し、cron 0 表記は %u=7（日曜）に丸めて再比較する
  if ! pp_match_cron_field "${fields[4]}" "$now_dow"; then
    if [ "$now_dow" = "7" ] && pp_match_cron_field "${fields[4]}" "0"; then
      :
    else
      return 1
    fi
  fi
  return 0
}

# pp_do_promote_if_eligible: `PROMOTE_MODE` 3 モード（continuous / batched /
# on-demand）の dispatcher。実際の fast-forward push 本体 `pp_do_promote`
# は本関数から呼び出される（task 5.2 で実装）。
#
# Requirements: 3.2.2, 3.2.3, 3.2.4, 3.2.5, 3.2.6
pp_do_promote_if_eligible() {
  case "$PROMOTE_MODE" in
    continuous)
      # AC 3.2.3: 即時 promote。promote 候補が 0 件なら何もしない
      if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
        pp_do_promote
      else
        pp_log "mode=continuous promote 候補 0 件 → 本サイクルは promote なし"
      fi
      ;;
    batched)
      # AC 3.2.4 / 3.2.6: PROMOTE_CRON 一致時のみ実行
      if [ -z "$PROMOTE_CRON" ]; then
        pp_warn "mode=batched PROMOTE_CRON 未設定 → 本サイクルは promote なし"
        return 0
      fi
      if pp_match_cron "$PROMOTE_CRON"; then
        if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
          pp_do_promote
        else
          pp_log "mode=batched cron 一致だが promote 候補 0 件 → 本サイクルは promote なし"
        fi
      else
        # AC 3.2.6: cron 不一致 / 不正な式は本サイクル no-op + WARN
        pp_log "mode=batched PROMOTE_CRON='${PROMOTE_CRON}' 現在時刻と不一致 → 本サイクルは promote なし"
      fi
      ;;
    on-demand)
      # AC 3.2.5: 人間トリガー待ち。何もしない + log
      pp_log "mode=on-demand 人間トリガーを待つ → promote は実行しない"
      ;;
    *)
      # AC 3.2.2: 不正値も on-demand にフォールバック
      pp_warn "mode='${PROMOTE_MODE}' は未知の値 → on-demand にフォールバック（promote 実行しない）"
      ;;
  esac
}

# pp_do_promote: `BASE_BRANCH` HEAD を `PROMOTION_TARGET_BRANCH` に fast-forward
# push する（NFR 2.1, NFR 2.2）。サブシェル内で `trap` を仕掛けて操作終了時に
# `BASE_BRANCH` checkout 状態へ復帰する（NFR 2.3 / Req 3.1.4）。
#
# fast-forward 不可（`PROMOTION_TARGET_BRANCH` 側が `BASE_BRANCH` の祖先でない）と
# 判定した場合は push を中止し、`promote-failed` 識別語を含む WARN を出す
# （Req 3.1.2, 3.1.3, NFR 4.1）。Issue 側のラベル状態は変更しない。
#
# 戻り値: 0 = promote 成功 / 1 = promote 失敗（呼び出し元は集計のみ）
pp_do_promote() {
  local rc=0
  (
    set +e
    trap 'git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    # Req 3.1.1 準備: 最新の PROMOTION_TARGET_BRANCH を fetch
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git fetch origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
      pp_warn "promote-failed: fetch '$PROMOTION_TARGET_BRANCH' に失敗"
      pp_notify_promote_failure "fetch failed"
      exit 1
    fi
    # AC 3.1.2: PROMOTION_TARGET_BRANCH が BASE_BRANCH の祖先か確認。
    # 祖先でない場合 fast-forward 不可 → 中止 + WARN（Req 3.1.3）
    if ! git merge-base --is-ancestor \
        "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null; then
      pp_warn "promote-failed: '$PROMOTION_TARGET_BRANCH' が '$BASE_BRANCH' の祖先でないため fast-forward 不可"
      pp_notify_promote_failure "non-fast-forward"
      exit 1
    fi
    # NFR 2.1 / 2.2: fast-forward 限定 push（--force 系オプションを付けず
    # 自然な ff push）。non-fast-forward は git server が reject する
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push origin \
          "refs/remotes/origin/${BASE_BRANCH}:refs/heads/${PROMOTION_TARGET_BRANCH}" \
          >/dev/null 2>&1; then
      pp_warn "promote-failed: fast-forward push に失敗"
      pp_notify_promote_failure "ff-push failed"
      exit 1
    fi
    pp_log "promote-success: '$BASE_BRANCH' -> '$PROMOTION_TARGET_BRANCH' fast-forward OK (candidates=${#PROMOTE_CANDIDATES[@]})"
    exit 0
  ) || rc=$?
  # 親シェル側カウンタを更新（サブシェル内で変更したカウンタは失われるため）
  if [ "$rc" -eq 0 ]; then
    PP_PROMOTE_SUCCESS_COUNT=$((PP_PROMOTE_SUCCESS_COUNT + 1))
    # Issue #370 task 6: Slack 通知 emitter（fail-open / gate OFF 時は no-op）。
    # promote は branch 単位イベントのため Issue 番号がなく、payload 上は sentinel "0" を
    # 用いる。URL は repo top に固定（個別 PR ではなく branch promotion のため）。
    sn_notify promote "0" "https://github.com/$REPO" promote-success "base=${BASE_BRANCH} target=${PROMOTION_TARGET_BRANCH} candidates=${#PROMOTE_CANDIDATES[@]}" || true
  else
    PP_PROMOTE_FAILED_COUNT=$((PP_PROMOTE_FAILED_COUNT + 1))
  fi
  return "$rc"
}

# pp_notify_promote_failure: promote 失敗時の通知。`PROMOTE_FAIL_NOTIFY_ISSUE` が
# 数値で指定されていれば該当 Issue に 1 件コメント投稿、未設定 / 不正値なら log のみ
# （Req 3.3.2, 3.3.3）。
pp_notify_promote_failure() {
  local reason="$1"
  # AC 3.3.3: 未設定 / 不正値（数値以外）は log のみ
  if [ -z "$PROMOTE_FAIL_NOTIFY_ISSUE" ] \
     || ! [[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  # AC 3.3.2: 1 件のコメント投稿（失敗してもサイクルは継続）
  local body
  body=$(cat <<EOF
## ⚠️ Phase B Promote Pipeline: promote 失敗

\`${BASE_BRANCH}\` -> \`${PROMOTION_TARGET_BRANCH}\` への fast-forward 昇格に失敗しました。

- reason: \`${reason}\`
- base: \`${BASE_BRANCH}\`
- target: \`${PROMOTION_TARGET_BRANCH}\`

watcher サイクルは継続しています。手動確認をお願いします。

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  timeout "$PROMOTE_GIT_TIMEOUT" \
    gh issue comment "$PROMOTE_FAIL_NOTIFY_ISSUE" --repo "$REPO" \
      --body "$body" >/dev/null 2>&1 \
    || pp_warn "PROMOTE_FAIL_NOTIFY_ISSUE=#${PROMOTE_FAIL_NOTIFY_ISSUE} へのコメント投稿に失敗"
}

# pp_summary: サイクル終了時のサマリログを 1 行で出力する。grep 集計用に
# `[$REPO] promote-pipeline: サマリ:` prefix と `key=value` 形式で出力する
# （Req 5.1.3, 5.1.5, NFR 4.1）。
pp_summary() {
  pp_log "サマリ: st-success-promoted=${PP_ST_SUCCESS_COUNT}, st-failure-reverted=${PP_ST_FAILURE_COUNT}, pending-skip=${PP_ST_PENDING_COUNT}, missing-skip=${PP_ST_MISSING_COUNT}, promote-success=${PP_PROMOTE_SUCCESS_COUNT}, promote-failed=${PP_PROMOTE_FAILED_COUNT}, fail=${PP_FAIL_COUNT}"
}

# process_promote_pipeline: Promote Pipeline Processor のエントリポイント。
#
# 引数: なし（env var で全制御）
# 戻り値: 常に 0（fail-continue を維持し、後続 Processor を止めない / NFR 3.1）
# 副作用:
#   - 対象 Issue へのラベル付与・除去（staged-for-release / st-failed）
#   - 対象 Issue の reopen + コメント投稿（ST failure 時）
#   - $BASE_BRANCH への revert commit + push（ST failure 時）
#   - $BASE_BRANCH → $PROMOTION_TARGET_BRANCH への fast-forward push（promote 成功時）
#   - $PROMOTE_FAIL_NOTIFY_ISSUE への 1 件コメント（promote 失敗時、env 設定時のみ）
process_promote_pipeline() {
  # AC 1.1.1, NFR 1.1: opt-in gate。`=true` 明示以外はすべて no-op で早期 return
  if [ "$PROMOTE_PIPELINE_ENABLED" != "true" ]; then
    return 0
  fi

  pp_log "サイクル開始 (base=${BASE_BRANCH}, target=${PROMOTION_TARGET_BRANCH}, mode=${PROMOTE_MODE}, timeout=${PROMOTE_GIT_TIMEOUT}s)"

  # AC 1.1.3, 1.2.2: 2-branch model gate + PROMOTION_TARGET_BRANCH のリモート存在検証
  if ! pp_resolve_target_branch; then
    return 0
  fi

  # NFR 2.3: dirty working tree gate。promote / revert は clean な作業ツリーが前提
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pp_error "dirty working tree を検知。promote / revert を中止します。"
    return 0
  fi

  # AC 2.1: merge 済み PR からリンク Issue を抽出 → 未付与に staged-for-release を
  # 自動付与し、ST 判定対象（= 現在 staged-for-release を持つ全 open Issue）を取得。
  local target_issues
  target_issues=$(pp_collect_merged_issues || true)

  if [ -z "$target_issues" ]; then
    pp_log "サマリ: 対象 Issue なし（staged-for-release 付き Issue 0 件）"
    return 0
  fi

  # ST 判定対象 Issue 数を log に出力
  local target_count
  target_count=$(echo "$target_issues" | grep -c '^[0-9]' || true)
  pp_log "ST 判定対象: ${target_count} 件の Issue を検出"

  # 集計用カウンタと promote 候補集合を初期化（per-cycle 状態）
  PROMOTE_CANDIDATES=()
  PP_ST_SUCCESS_COUNT=0
  PP_ST_FAILURE_COUNT=0
  PP_ST_PENDING_COUNT=0
  PP_ST_MISSING_COUNT=0
  PP_FAIL_COUNT=0

  # AC 2.2〜2.4: 各 Issue について ST 状態取得 + アクション実施。
  # NFR 3.1: 1 件の失敗が他 Issue 処理を止めないよう `|| true` で吸収。
  local issue_number
  while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    pp_process_one_issue "$issue_number" \
      || pp_warn "issue=#${issue_number} 想定外のエラー → 後続 Issue は継続"
  done <<< "$target_issues"

  # AC 3.1, 3.2: promote 候補集合を PROMOTE_MODE に応じて昇格実行。
  # 集計用カウンタは pp_do_promote / pp_do_promote_if_eligible 内部で更新する。
  PP_PROMOTE_SUCCESS_COUNT=0
  PP_PROMOTE_FAILED_COUNT=0
  # NFR 3.1: 失敗時も後続処理を止めないため `|| true` で吸収
  pp_do_promote_if_eligible || true

  # AC 5.1.3: サイクル終了時のサマリログを 1 行で出力
  pp_summary
}
