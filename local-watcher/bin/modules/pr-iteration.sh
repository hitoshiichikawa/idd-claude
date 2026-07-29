#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration.sh — watcher の PR Iteration Processor モジュール（family orchestrator）
#
# family: pr-iteration / prefix: pi_
#   #469 で本モジュールを責務単位の module family へ分割した。orchestrator（本ファイル）と
#   4 つの sub-file が同一 prefix `pi_` を共有する（family 全体で 1 prefix）。分割マニフェスト
#   （どの関数がどのファイルにあるか）:
#     - pr-iteration.sh          … 本ファイル: エントリ / 候補取得 / kind・round 解決 /
#                                   round driver / 成功時ラベル確定
#         process_pr_iteration（エントリ）/ pi_run_iteration（1 PR 分の round driver）/
#         pi_pr_has_label / pi_fetch_candidate_prs / pi_resolve_max_rounds /
#         pi_classify_pr_kind / pi_select_template / pi_finalize_labels /
#         pi_finalize_labels_design
#     - pr-iteration-comments.sh … 一般コメント収集 + filter chain
#         pi_collect_general_comments / pi_general_filter_self / _resolved / _excessive /
#         _oos / _event_style / pi_general_truncate
#     - pr-iteration-state.sh    … PR body hidden marker の read/write + round outcome / streak
#         pi_read_round_counter / pi_read_no_progress_streak / pi_read_last_run /
#         pi_write_marker / pi_post_processing_comment / pi_post_processing_marker /
#         pi_classify_round_outcome / pi_round_commit_pushed / pi_next_no_progress_streak
#     - pr-iteration-oos.sh      … out-of-scope 還流 / 検出 / 内容ベース no-progress（#437）
#         pi_route_out_of_scope_escalate / pi_detect_developer_oos_marker /
#         pi_oos_fingerprint / pi_read_oos_no_progress_streak / pi_read_oos_fingerprint /
#         pi_next_oos_no_progress_streak
#     - pr-iteration-exec.sh     … 1 round 実行ヘルパー（prompt 構築 / escalation / quota 検出 / auto-commit）
#         build_recovery_hint / pi_escalate_to_failed / pi_build_iteration_prompt /
#         pi_detect_quota_soft_fail / pi_branch_is_claude_pr_head / pi_auto_commit_and_push
#
# 用途:
#   `needs-iteration` ラベルが付いた idd-claude 管理下 PR を fresh context の Claude で
#   反復対応する（#26）。Phase A と同じ flock 境界内で直列実行され、対象 PR 集合は
#   server-side label query で Phase A と直交させている。標準機能としてデフォルト有効（#112）。
#   無効化は PR_ITERATION_ENABLED=false で明示する。
#
# 配置先:
#   $HOME/bin/modules/pr-iteration*.sh（install.sh が local-watcher/bin/modules/ から *.sh を
#   glob 配布するため、family の全ファイルが同時に配布される）
#
# 依存:
#   - issue-watcher.sh 本体から REQUIRED_MODULES ローダ経由で `source` される（単体起動しない）。
#     family の sub-file は REQUIRED_MODULES で orchestrator より前に登録する（bash の遅延束縛
#     により source 順は不問だが、規約に従い sub → orchestrator の順に並べる）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー pi_log / pi_warn / pi_error は core_utils.sh に定義済み（#180 Part 2）。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PR_ITERATION_ENABLED / $PR_ITERATION_MAX_ROUNDS* /
#     $PR_ITERATION_GIT_TIMEOUT / $ITERATION_TEMPLATE* / $LABEL_NEEDS_ITERATION / $LABEL_FAILED 等）は
#     本体冒頭の Config ブロック（watcher-config.sh）で定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - family 内の cross-file 呼び出し（例: pi_run_iteration → pi_collect_general_comments /
#     pi_route_out_of_scope_escalate 等）も遅延束縛で解決される（loader が main loop 前に全 module を source）。
#   - top-level orchestration 呼び出し配線（process_pr_iteration || pi_warn ...）は本体 entry
#     point に残置する（本モジュールは関数定義のみ / #181 design.md）。
#   - 外部 CLI: gh / git / jq / claude。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md
#   - README「PR Iteration Processor」節
#
# SC2034 file-wide 抑止の根拠（#469 分割の副作用 / #464 の SC2153 と同種の cross-file 可視性喪失）:
#   pi_run_iteration は base_ref を宣言・代入するが本関数内では未使用（消費側の
#   pi_build_iteration_prompt が pr-iteration-exec.sh へ分離したため、単一ファイル時に同名
#   使用でマスクされていた未使用代入が module 単体で顕在化した）。関数移動対象自体は無改変
#   （#455 共通規約）のため dead assignment を削除せず file-wide で抑止する。
# shellcheck disable=SC2034

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
pi_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_fetch_candidate_prs: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   AC 1.1, 1.2, 1.3, 1.4, 1.5, 8.4
# ─────────────────────────────────────────────────────────────────────────────
pi_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # AC 1.1 / 1.4 / 1.5 / 8.4: needs-iteration 付き、claude-failed / needs-rebase 無し、非 draft
  # #521 Req 2.3: サイクル内 PR snapshot 経由取得（gate off / 取得失敗時は従来 gh pr list）。
  if ! prs_json=$(grl_pr_snapshot_or_live "$PR_ITERATION_GIT_TIMEOUT" \
      "label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_REBASE\" -draft:true" \
      "number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body" \
      50); then
    pi_warn "needs-iteration PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # AC 1.2 / 1.3 / 1.4: クライアント側フィルタ（server filter の保険 + head pattern + fork 除外）
  # #35 AC 4.4 / 5.1: design pattern は PR_ITERATION_DESIGN_ENABLED=true のときのみ OR 条件に
  # 含める。#112 以降デフォルトは true。明示的に false を渡した場合のみ impl pattern だけで
  # 絞り込み、設計 PR は candidate 段階で除外される（= 設計 PR 拡張 #35 導入前と同一の挙動）。
  # #521 Req 2.3: snapshot 参照時に server search の `label:needs-iteration`（包含）/
  #   `-label:failed` / `-label:needs-rebase`（除外）/ `-draft:true`（isDraft==false）を
  #   client jq で再現（等価性ルール表）。live 経路では冪等（byte 等価を保つ）。
  echo "$prs_json" | jq \
    --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
    --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
    --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
    --arg owner "$repo_owner" \
    --arg needs_iteration "$LABEL_NEEDS_ITERATION" \
    --arg failed "$LABEL_FAILED" \
    --arg needs_rebase "$LABEL_NEEDS_REBASE" \
    '[.[]
      | select(.isDraft == false)
      | select((.labels // [] | map(.name) | index($needs_iteration)) != null)
      | select((.labels // [] | map(.name) | index($failed)) == null)
      | select((.labels // [] | map(.name) | index($needs_rebase)) == null)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(
          (.headRefName | test($impl_pattern))
          or
          ($design_enabled == "true" and (.headRefName | test($design_pattern)))
        )
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_resolve_max_rounds: kind に対応する round 上限を解決する（Issue #122 Req 1）
#   入力: $1 = kind ("impl" / "design")
#   出力: stdout に 0 以上の整数（`0` は無制限の sentinel / Req 2）
#   返り値: 0=成功 / 1=未知 kind
#
#   優先順序（Req 1.1〜1.4）:
#     1. kind 固有 env（PR_ITERATION_MAX_ROUNDS_IMPL / PR_ITERATION_MAX_ROUNDS_DESIGN）が
#        非空ならその値を採用
#     2. 旧 PR_ITERATION_MAX_ROUNDS が設定されていれば両 kind の fallback として採用
#     3. いずれも未設定なら impl=3, design=0 を適用
#
#   設計判断:
#     - 値の妥当性（非負整数）は呼び出し元で `[ "$v" -ge "..." ]` 形式の比較に
#       入ってくる時点で bash の算術評価で検出されるため、ここでは defensive に
#       数値化のみ実施し、不正値（負・非数値）は受信時点で 0 にフォールバックさせない
#       （運用者の typo を握り潰さない方針 / 設計判断）。代わりに呼び出し元で
#       通常通り比較が落ちる挙動に任せる。
# ─────────────────────────────────────────────────────────────────────────────
pi_resolve_max_rounds() {
  local kind="$1"
  local kind_specific=""
  local default_value=""
  case "$kind" in
    impl)
      kind_specific="${PR_ITERATION_MAX_ROUNDS_IMPL:-}"
      default_value="3"
      ;;
    design)
      kind_specific="${PR_ITERATION_MAX_ROUNDS_DESIGN:-}"
      default_value="0"
      ;;
    *)
      pi_warn "pi_resolve_max_rounds: 未知の kind=${kind}"
      return 1
      ;;
  esac

  # Req 1.1 / 1.2: kind 固有 env が非空ならその値を採用
  if [ -n "$kind_specific" ]; then
    echo "$kind_specific"
    return 0
  fi
  # Req 1.3: 旧 PR_ITERATION_MAX_ROUNDS が「明示設定されている」場合は fallback として
  # 採用。冒頭で "${...:-3}" 展開されるため変数自体には常に値が入るが、設定有無は
  # PR_ITERATION_MAX_ROUNDS_LEGACY_SET フラグで判別する。明示設定されていれば旧運用
  # （impl/design 共通 3 round 制限）と互換になるよう、design 側にも同値を適用する。
  if [ "${PR_ITERATION_MAX_ROUNDS_LEGACY_SET:-false}" = "true" ]; then
    echo "${PR_ITERATION_MAX_ROUNDS}"
    return 0
  fi
  # Req 1.4: 全未設定なら kind ごとの default を返す（impl=3, design=0）
  echo "$default_value"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels: 成功時のラベル遷移（AC 6.2 / 6.4）
#   --remove-label と --add-label を同一コマンドで指定し原子的に実行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_READY" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (needs-iteration -> ready-for-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_finalize_labels_design: 設計 PR 用のラベル遷移（#35 AC 3.1）
#   needs-iteration 除去 + awaiting-design-review 付与を 1 コマンドで原子的に発行
# ─────────────────────────────────────────────────────────────────────────────
pi_finalize_labels_design() {
  local pr_number="$1"
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: ラベル遷移 (needs-iteration -> awaiting-design-review) に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_classify_pr_kind: branch 名 + env vars から PR の iteration 種別を判定
#   入力: $1 = head_ref
#   出力: stdout に "design" / "impl" / "none" / "ambiguous" のいずれか
#   返り値: 0
#
#   優先順序（#35 AC 1.1〜1.4 / 4.4）:
#     1. impl pattern と design pattern の両方に合致 → ambiguous
#     2. design pattern のみ合致 + DESIGN_ENABLED=true → design
#     3. design pattern のみ合致 + DESIGN_ENABLED!=true → none（opt-out gate）
#     4. impl pattern のみ合致 → impl
#     5. どちらにも合致しない → none
#
#   副作用なし（純粋関数）。同一入力に対して同一結果。
# ─────────────────────────────────────────────────────────────────────────────
pi_classify_pr_kind() {
  local head_ref="$1"
  local matches_impl=false
  local matches_design=false

  if [[ "$head_ref" =~ $PR_ITERATION_HEAD_PATTERN ]]; then
    matches_impl=true
  fi
  if [[ "$head_ref" =~ $PR_ITERATION_DESIGN_HEAD_PATTERN ]]; then
    matches_design=true
  fi

  if [ "$matches_impl" = "true" ] && [ "$matches_design" = "true" ]; then
    echo "ambiguous"
    return 0
  fi
  if [ "$matches_design" = "true" ]; then
    if [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ]; then
      echo "design"
    else
      echo "none"
    fi
    return 0
  fi
  if [ "$matches_impl" = "true" ]; then
    echo "impl"
    return 0
  fi
  echo "none"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_select_template: kind から prompt template ファイルパスを返す（#35 AC 2.x）
#   入力: $1 = kind ("design" / "impl")
#   出力: stdout に template ファイルパス
#   返り値: 0=ok, 1=template 未配置（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_select_template() {
  local kind="$1"
  local path=""
  case "$kind" in
    design) path="$ITERATION_TEMPLATE_DESIGN" ;;
    impl)   path="$ITERATION_TEMPLATE" ;;
    *)
      pi_warn "pi_select_template: 未知の kind=${kind}"
      return 1
      ;;
  esac
  if [ ! -f "$path" ]; then
    pi_warn "pi_select_template: template not found for kind=${kind}: ${path}"
    return 1
  fi
  echo "$path"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_run_iteration: 1 PR 分の iteration を実行（fresh context Claude 起動）
#   入力: $1=pr_json
#   戻り値: 0=success(commit+push or reply-only), 1=failure, 2=escalated(round上限到達),
#           3=skip (kind=none/ambiguous, #35)
#   AC 3.6, 4.x, 5.x, 6.2, 6.3, 7.x, 8.3, 9.2, NFR 1.1, NFR 1.3 (#26)
#   #35: kind 判定で design / impl を分岐し、template と finalize 関数を切り替える
# ─────────────────────────────────────────────────────────────────────────────
pi_run_iteration() {
  local pr_json="$1"
  local pr_number head_ref base_ref pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  # #35 AC 1.1〜1.4 / 4.4: kind 判定（design / impl / none / ambiguous）
  local kind
  kind=$(pi_classify_pr_kind "$head_ref")

  case "$kind" in
    none)
      pi_log "PR #${pr_number}: kind=none head=${head_ref} (does not match design/impl pattern), skip"
      return 3
      ;;
    ambiguous)
      pi_warn "PR #${pr_number}: kind=ambiguous head=${head_ref} (matches both design and impl pattern), skip"
      return 3
      ;;
    design|impl) : ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} (unknown), skip"
      return 3
      ;;
  esac

  # #35 AC 2.x: kind に応じた template path を取得
  local tmpl_path
  if ! tmpl_path=$(pi_select_template "$kind"); then
    pi_warn "PR #${pr_number}: kind=${kind} 用 template が取得できず iteration 中止"
    return 1
  fi

  # Issue #122 Req 1: kind に応じて round 上限を解決（旧 PR_ITERATION_MAX_ROUNDS は
  # 両 kind 共通の fallback）。`0` は無制限の sentinel（Req 2.1〜2.4）。
  local max_rounds
  max_rounds=$(pi_resolve_max_rounds "$kind")
  local max_display
  if [ "$max_rounds" = "0" ]; then
    max_display="無制限"
  else
    max_display="$max_rounds"
  fi

  # Issue #122 Req 3 / 4: PR body から round と no-progress 連続カウンタの両方を抽出。
  # body 取得は pi_read_round_counter で 1 回、pi_read_no_progress_streak は同じ
  # body をローカル抽出するため二重 fetch を避けて pr_body を共有取得する。
  local pr_body_for_marker
  pr_body_for_marker=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
    gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null || echo "")
  local round
  round=$(echo "$pr_body_for_marker" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  round="${round:-0}"
  local prev_streak
  prev_streak=$(pi_read_no_progress_streak "$pr_body_for_marker")

  # Issue #437 Req 5: gate ON のとき内容ベース no-progress 連続カウンタ + 直前 fingerprint を
  # 同じ pr_body から抽出する（既存 SHA ベース streak とは独立 / Non-Goal: 既存不変）。
  # gate OFF では本変数を参照しない（早期打ち切り自体が no-op / NFR 1.1）。
  local prev_oos_streak="0" prev_oos_fingerprint=""
  if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
    prev_oos_streak=$(pi_read_oos_no_progress_streak "$pr_body_for_marker")
    prev_oos_fingerprint=$(pi_read_oos_fingerprint "$pr_body_for_marker")
  fi
  # Issue #437 Req 5: 閾値未満で round が継続するとき marker へ永続化する内容ベース
  # no-progress streak / fingerprint。gate OFF / out-of-scope 経路を通らなかった場合は空のまま
  # （pi_write_marker は空引数を受けて従来 3 フィールド marker を書く / NFR 1.3）。
  local _pi_oos_marker_streak="" _pi_oos_marker_fingerprint=""

  # Issue #122 Req 2.1 / 2.3: max_rounds=0 は「round 数超過のみによる escalate を行わない」
  # （AC 2.1: design / AC 2.3: impl）。max_rounds>0 のときは round >= max で escalate。
  if [ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]; then
    # Issue #122 Req 6.4: PR 番号 / kind / round / max / 原因を 1 行に整形
    pi_log "PR #${pr_number}: kind=${kind} round=${round} max=${max_rounds} reason=max-rounds escalate"
    pi_escalate_to_failed "$pr_number" "$round" "$max_rounds" "max-rounds" || true
    return 2
  fi

  local next_round=$((round + 1))

  # Issue #122 Req 4 / 5: marker は round 終了時の成功 path でのみ書き込む。
  # 着手表明コメントは round 開始時に投稿（人間向け視認用、既存挙動 NFR 1.1）。
  pi_post_processing_comment "$pr_number" "$next_round" "$max_rounds"

  pi_log "PR #${pr_number}: kind=${kind} round=${next_round}/${max_display} 着手 (${pr_url})"

  # #118 Req 1.1 / 2.1: soft-fail 検知用 / 自動回復結果のサブシェル <-> 親 通信用に
  # tmpfile を 2 つ用意する。
  #   - $pi_soft_fail_file : 検出 1 件 1 行（`pi_detect_quota_soft_fail` の出力）
  #   - $pi_recover_file   : サブシェル終端で書き出す自動回復結果の 1 行。
  #                          書式: `<kind>:<result>` 例: `soft-fail-commit:ok`,
  #                                `post-round-commit:ok`, `post-round-commit:fail`,
  #                                `none:` （回復不要 / dirty なし）
  # Issue #122 Req 3: subshell <-> 親 で SHA 比較用に before/after の 2 行も tmpfile に書き出す。
  #   - $pi_sha_file : 1 行目=before_sha, 2 行目=after_sha
  # Issue #437 Req 4.2 / 4.3: subshell <-> 親 で Developer 構造化マーカーの検出種別を渡すための
  #   tmpfile（1 行: "design" | "spec-stale" | ""）。gate OFF では書かない（空のまま）。
  local pi_soft_fail_file pi_recover_file pi_sha_file pi_oos_marker_file
  pi_soft_fail_file=$(mktemp -t "pi-softfail-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  pi_recover_file=$(mktemp -t "pi-recover-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  pi_sha_file=$(mktemp -t "pi-sha-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  pi_oos_marker_file=$(mktemp -t "pi-oosmark-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  : > "$pi_soft_fail_file"
  : > "$pi_recover_file"
  : > "$pi_sha_file"
  : > "$pi_oos_marker_file"

  # サブシェル + trap で必ず base branch に戻す（AC 8.3）
  local rc=0
  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin の最新状態に追従、AC 4.4）
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: git fetch origin ${head_ref} に失敗"
      exit 1
    fi
    if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      pi_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 1
    fi

    # Issue #122 Req 3.1 / 3.2: round 開始時の HEAD を記録。round 終了時に同じ branch の
    # HEAD と比較して「新規 commit が push されたか」を判定する。
    local before_sha
    before_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    printf '%s\n' "$before_sha" > "$pi_sha_file"

    # prompt を生成（#35: kind に応じた template path を渡す / #122: kind 別 max_rounds を渡す）
    local prompt
    if ! prompt=$(pi_build_iteration_prompt "$pr_number" "$pr_json" "$next_round" "$tmpl_path" "$max_rounds"); then
      pi_warn "PR #${pr_number}: prompt 組み立てに失敗"
      exit 1
    fi

    # AC 3.6: fresh context で起動（--resume / --continue は使わない）
    # NFR 1.1: --max-turns で turn 数上限
    local pi_log_file
    pi_log_file="$LOG_DIR/pr-iteration-${kind}-${pr_number}-round${next_round}-$(date +%Y%m%d-%H%M%S).log"

    # #118 Req 1.1 / 5.1: claude の stream-json 出力を tee で 2 系統に分岐。
    #   - 系統 1: 既存通り $pi_log_file へ append（観測ログを壊さない / NFR 1.2）。
    #   - 系統 2: pi_detect_quota_soft_fail で `allowed_warning` イベントを検出し
    #            $pi_soft_fail_file に書き出す。QUOTA_AWARE_ENABLED とは独立に動作する
    #            （Req 5.1）。
    # set -e / pipefail 配下で `tee` や `jq` の非 0 exit を握り潰さないよう、
    # PIPESTATUS を即座にコピーしてから claude 本体の exit code を取り出す。
    local claude_rc=0
    set +e
    claude \
        --print "$prompt" \
        --model "$PR_ITERATION_DEV_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$PR_ITERATION_MAX_TURNS" \
        --output-format stream-json \
        --verbose \
        2>&1 \
      | tee -a "$pi_log_file" \
      | pi_detect_quota_soft_fail \
      > "$pi_soft_fail_file"
    local _pi_pipestatus=("${PIPESTATUS[@]}")
    set -e
    claude_rc="${_pi_pipestatus[0]:-0}"

    if [ "$claude_rc" -ne 0 ]; then
      pi_warn "PR #${pr_number}: kind=${kind} Claude 実行が失敗 (log: ${pi_log_file})"
      # claude 失敗時も round 中に部分編集が残っている可能性があるため、後段の自動回復に
      # 続ける。検出 file の有無にかかわらず post-round-recover 経路で dirty を退避する。
      #
      # Issue #259: 失敗ログから Claude API 一時混雑エラー (529 Overloaded) の痕跡を検出
      # した場合、PR コメントとして一時障害である旨と次回ポーリングサイクルで自動再試行
      # される旨を投稿する。検知ロジックが失敗・例外を起こしても既存の needs-iteration
      # 据え置き / claude-failed 遷移 / post-round-recover 経路を妨げないよう、すべての
      # 副作用は `|| true` で握り、grep の失敗（一致なし）と区別する。
      #   - 検知あり (rc=0) → PR コメント投稿 + INFO ログ
      #   - 検知なし (rc=1) → INFO ログのみ
      #   - ログ不在 (rc=2) → WARN ログのみ（既存処理は継続 / Req 1.5）
      local _pi_529_rc=0
      claude_log_detect_529 "$pi_log_file" || _pi_529_rc=$?
      case "$_pi_529_rc" in
        0)
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} 529-overloaded detected (log: ${pi_log_file})"
          local _pi_529_body
          _pi_529_body=":warning: **Claude API 一時混雑エラー (529 Overloaded)**: 混雑のため一時処理を中断しました。進捗（Round数等）は据え置かれ、次のポーリングサイクルで自動再試行します。

<!-- idd-claude:pr-iteration-529-warning round=${next_round} -->"
          if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
              gh pr comment "$pr_number" --repo "$REPO" --body "$_pi_529_body" >/dev/null 2>&1; then
            pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 529 警告コメントの投稿に失敗 (既存処理は継続)"
          fi
          ;;
        2)
          pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 529 検知用ログファイルが不在または読み取り不能のためスキップ (log: ${pi_log_file})"
          ;;
        *)
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} 529-overloaded not detected"
          ;;
      esac
    else
      pi_log "PR #${pr_number}: kind=${kind} Claude 実行完了 (log: ${pi_log_file})"
    fi

    # Issue #437 Req 4.2: gate ON のとき Developer 応答ログから out-of-scope 構造化マーカーを
    # 検出し、種別（design / spec-stale / 不在は空）を tmpfile 経由で親へ渡す。検出は読み取り
    # 専用・fail-safe（pi_detect_developer_oos_marker はログ不在でも空返し）。gate OFF では
    # 本ブロックを skip し空のまま（既存フロー byte 互換 / NFR 1.1）。
    if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
      local _pi_dev_oos_marker
      _pi_dev_oos_marker=$(pi_detect_developer_oos_marker "$pi_log_file")
      printf '%s' "$_pi_dev_oos_marker" > "$pi_oos_marker_file"
    fi

    # #118 Req 1.2 / 2.1 / 2.2: round 終了時点の dirty 判定と自動回復。
    # 設計判断:
    #   - 「soft-fail を検出 かつ 差分あり」「soft-fail なし かつ 差分あり」「差分なし」の 3 系統。
    #   - soft-fail 検出が優先（Req 2.5）。
    #   - branch ガードは pi_branch_is_claude_pr_head で実施（人間 branch には auto-commit しない）。
    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    local soft_fail_observed=false
    if [ -s "$pi_soft_fail_file" ]; then
      soft_fail_observed=true
    fi
    local has_dirty=false
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      has_dirty=true
    fi

    # branch ガード（Req 3.2 / 3.4 の round-内版）: 想定外 branch に居る場合は
    # auto-commit せず WARN（claude 失敗時の subshell 早期 exit や fetch/checkout 失敗で
    # current_branch が head_ref と乖離するシナリオを安全側に倒す）。
    if [ "$has_dirty" = "true" ] && ! pi_branch_is_claude_pr_head "$current_branch"; then
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} 想定外 branch '${current_branch}' に dirty 検出 (auto-commit 抑止)"
      printf '%s' "post-round-commit:fail" > "$pi_recover_file"
      if [ "$claude_rc" -ne 0 ]; then
        exit 1
      fi
      # claude 成功なのに branch 不一致は構造上ほぼ起きない（防御的）。後続で finalize しないよう fail を返す。
      exit 1
    fi

    local recover_status="none:"
    if [ "$has_dirty" = "true" ]; then
      if [ "$soft_fail_observed" = "true" ]; then
        # Req 1.2 / 1.3 / 2.5: soft-fail 時の commit message
        if pi_auto_commit_and_push \
            "docs(specs): partial round-${next_round} output before quota cutoff (auto-recovered)" \
            "$current_branch"; then
          recover_status="soft-fail-commit:ok"
        else
          recover_status="soft-fail-commit:fail"
        fi
      else
        # Req 2.2 / 2.3: 通常 dirty 時の commit message
        if pi_auto_commit_and_push \
            "docs(specs): recover uncommitted round-${next_round} output (auto)" \
            "$current_branch"; then
          recover_status="post-round-commit:ok"
        else
          recover_status="post-round-commit:fail"
        fi
      fi
    elif [ "$soft_fail_observed" = "true" ]; then
      # 差分は無いが soft-fail を観測した（差分前に round が打ち切られた稀ケース）
      recover_status="soft-fail-commit:ok"
    fi
    printf '%s' "$recover_status" > "$pi_recover_file"

    # Issue #122 Req 3.1 / 3.2: 自動回復まで含む round 終了時点の HEAD を記録。
    # before_sha と異なれば新規 commit が push された（reply-only 経路で claude 自身が
    # commit+push した場合、または pi_auto_commit_and_push で auto-commit した場合の両方をカバー）。
    local after_sha
    after_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    printf '%s\n%s\n' "$before_sha" "$after_sha" > "$pi_sha_file"

    # claude 自体の rc を引き継ぐ（失敗は呼び出し元で WARN + needs-iteration 残置に倒れる）
    exit "$claude_rc"
  )
  rc=$?
  # 保険: 呼び出し元でも base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true

  # #118 Req 1.1 / 4.1 / 4.2: 自動回復結果を読み取ってログ + 後続挙動を分岐
  local recover_status="none:"
  if [ -s "$pi_recover_file" ]; then
    recover_status=$(cat "$pi_recover_file")
  fi
  local soft_fail_summary=""
  if [ -s "$pi_soft_fail_file" ]; then
    # 検出が複数行ある場合は最後の値を採用（最新 utilization）。tab 区切り 2 列目。
    soft_fail_summary=$(awk -F '\t' 'NF >= 2 { last = $2 } END { print last }' "$pi_soft_fail_file")
  fi
  # Issue #122 Req 3.1 / 3.2: SHA 比較で「新規 commit が push されたか」判定
  local before_sha="" after_sha=""
  if [ -s "$pi_sha_file" ]; then
    before_sha=$(sed -n '1p' "$pi_sha_file")
    after_sha=$(sed -n '2p' "$pi_sha_file")
  fi
  # Issue #437 Req 4.2: Developer 構造化マーカー検出種別（gate OFF / 不在は空）を読み取る。
  local dev_oos_marker=""
  if [ -s "$pi_oos_marker_file" ]; then
    dev_oos_marker=$(cat "$pi_oos_marker_file")
  fi
  rm -f "$pi_soft_fail_file" "$pi_recover_file" "$pi_sha_file" "$pi_oos_marker_file"

  # Issue #122 Req 5: 失敗扱い（quota soft-fail / claude crash / post-round-commit fail）の
  # round では marker を据え置く（round counter / no-progress streak いずれも増減させない）。
  # 成功 path（recover_status=post-round-commit:ok or none:）のみ marker を更新する。
  case "$recover_status" in
    soft-fail-commit:ok)
      # Req 1.1 / 1.2 / 1.4 / 4.1 (#118): soft-fail 検出 + auto-commit 成功 → needs-iteration 据え置き
      # Issue #122 Req 5.1 / 5.2: marker 更新せず prev_round / prev_streak のまま温存
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} quota-soft-fail utilization=${soft_fail_summary} action=auto-commit+keep-label"
      return 1
      ;;
    soft-fail-commit:fail)
      # Req 1.5 (#118): auto-commit / push 失敗 → WARN + needs-iteration 据え置き
      # Issue #122 Req 5.1 / 5.2: 同上、marker 据え置き
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} quota-soft-fail utilization=${soft_fail_summary} action=auto-commit-failed (needs-iteration を残置)"
      return 1
      ;;
    post-round-commit:ok)
      # Req 2.1 / 2.2 / 4.2 (#118): 通常 dirty + auto-commit 成功 → 通常 finalize に進む
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} post-round-recover branch=${head_ref} action=success"
      ;;
    post-round-commit:fail)
      # Req 2.4 / 4.3 (#118): auto-commit / push 失敗 → WARN + 終了
      # Issue #122 Req 5.3: marker 据え置き（counter / streak を加算しない）
      pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} post-round-recover branch=${head_ref} action=fail"
      return 1
      ;;
    none:|"")
      : # 回復不要（dirty なし）
      ;;
    *)
      pi_warn "PR #${pr_number}: kind=${kind} 未知の recover_status='${recover_status}' (needs-iteration を残置)"
      return 1
      ;;
  esac

  if [ $rc -eq 0 ]; then
    # Issue #437 Req 4.3 / 5.2 / 5.4: gate ON のとき、通常 finalize / no-progress 判定の前に
    # out-of-scope 経路を評価する。gate OFF（既定）では本ブロックを完全 skip し既存フローへ進む
    # （byte 互換 / NFR 1.1）。
    if [ "${PR_ITERATION_OOS_ENABLED:-false}" = "true" ]; then
      # adjudicator が投稿した out-of-scope marker コメントを収集し、内容ベース fingerprint を
      # 算出するための decisions-like JSON を組み立てる（severity / file / message を保持）。
      # marker `<!-- idd-claude:pr-adjudicator-out-of-scope id=<N> sha=<sha> -->` を持つコメント
      # 本文から id / severity / file / line / reason を抽出する。取得失敗は空 JSON（fail-safe）。
      local oos_decisions_json="{}"
      local _pi_oos_comments
      _pi_oos_comments=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
        gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null \
        | jq -c '[.[] | select((.body // "") | contains("idd-claude:pr-adjudicator-out-of-scope")) | {body}]' 2>/dev/null) \
        || _pi_oos_comments="[]"
      if [ -n "$_pi_oos_comments" ] && [ "$_pi_oos_comments" != "[]" ]; then
        # コメント本文から `- id:` / `- severity:` / `- file:` / `- 理由（...）:` の行を拾って
        # decisions[] を再構成する（adj_post_decision_comment の投稿書式に対応）。未信頼値は
        # jq --arg でリテラル処理する。fingerprint は severity/file/message のみ使用するため
        # message には理由行を充てる。
        oos_decisions_json=$(printf '%s' "$_pi_oos_comments" | jq -c '
          { decisions: [ .[]
            | .body as $b
            | { verdict: "out-of-scope",
                severity: (($b | capture("(?m)^- severity: (?<v>.*)$").v) // ""),
                file:     (($b | capture("(?m)^- file: (?<v>.*)$").v) // ""),
                message:  (($b | capture("(?m)^- 理由（[^）]*）: (?<v>.*)$").v) // "") }
          ] }
        ' 2>/dev/null) || oos_decisions_json="{}"
      fi

      local current_oos_fingerprint
      current_oos_fingerprint=$(pi_oos_fingerprint "$oos_decisions_json")

      # (a) Req 4.3: Developer が out-of-scope 構造化マーカーを宣言した round は finalize せず
      #     即ルーティングへ引き渡す（in-scope 実害が残っていない前提を Developer 判断で確定）。
      if [ -n "$dev_oos_marker" ]; then
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} reason=developer-oos-marker marker=${dev_oos_marker} action=route-out-of-scope"
        pi_route_out_of_scope_escalate "$pr_number" "$after_sha" "$oos_decisions_json" "developer-marker:${dev_oos_marker}" "?" || true
        return 2
      fi

      # (b) Req 5.1 / 5.2 / 5.3 / 5.4 / 5.5: 内容ベース no-progress 早期打ち切り。
      #     fingerprint 同一（SHA 変化に依存しない）で連続したら streak を加算し、閾値到達で
      #     max_rounds 到達前に打ち切ってルーティングする。fingerprint 変化でリセット（Req 5.5）。
      local next_oos_streak
      next_oos_streak=$(pi_next_oos_no_progress_streak "$prev_oos_fingerprint" "$current_oos_fingerprint" "$prev_oos_streak")
      if [[ "$next_oos_streak" =~ ^[0-9]+$ ]] && [ "$next_oos_streak" -ge "$PR_ITERATION_OOS_NO_PROGRESS_LIMIT" ]; then
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} reason=oos-content-no-progress oos-no-progress-streak=${next_oos_streak} limit=${PR_ITERATION_OOS_NO_PROGRESS_LIMIT} action=route-out-of-scope"
        pi_route_out_of_scope_escalate "$pr_number" "$after_sha" "$oos_decisions_json" "content-no-progress" "?" || true
        return 2
      fi
      # 閾値未満: oos streak / fingerprint を marker に永続化して次 round で比較する。
      # 通常 SHA ベース streak と round counter の更新は下流の pi_write_marker に委ねるため、
      # ここでは値だけ控えて pi_write_marker 呼び出し時に渡す（下記 _pi_oos_marker_* で受け渡し）。
      _pi_oos_marker_streak="$next_oos_streak"
      _pi_oos_marker_fingerprint="$current_oos_fingerprint"
    fi

    # Issue #122 Req 3.1 / 3.2 / Issue #435 Req 2: SHA 比較で「新規 commit が push されたか」
    # 判定。before_sha と after_sha が異なれば新規 commit あり（claude 自身による commit+push、
    # または pi_auto_commit_and_push 経由の auto-commit、いずれもカバー）。
    # 判定ロジックは pi_round_commit_pushed に純粋関数として切り出し、回帰テストで不変条件
    # （HEAD 変化 → 進捗あり / auto-recovery 経由でも進捗あり）を固定する。
    local commit_pushed
    commit_pushed=$(pi_round_commit_pushed "$before_sha" "$after_sha")
    # Issue #122 Req 3.1 / 3.2 / Issue #435 Req 2: no-progress 連続カウンタの更新。
    # commit_pushed=true（auto-recovery 経由を含む）でリセット、false で +1（pi_next_no_progress_streak）。
    local new_streak
    new_streak=$(pi_next_no_progress_streak "$commit_pushed" "$prev_streak")

    # Issue #122 Req 6.2: round 終了時点で no-progress 連続カウンタが加算されたら
    # PR 番号 / kind / 加算後の連続カウンタ / 上限値を 1 行ログに記録
    # Issue #397 Req 5.1: design / impl 両 kind で同一フォーマットで出力する。
    if [ "$commit_pushed" = "false" ]; then
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"
    fi

    # Issue #122 Req 5.4 / Req 4.1: marker 書き込み。失敗は Req 5.4 の通り ERROR + 据え置き
    # Issue #437 Req 5: gate ON で out-of-scope 経路を通過した round は oos streak / fingerprint も
    # 併せて永続化する（第 4/5 引数）。gate OFF / 経路未通過では空のまま渡し、pi_write_marker が
    # 従来 3 フィールド marker を書く（NFR 1.3 byte 互換）。
    if ! pi_write_marker "$pr_number" "$next_round" "$new_streak" "$_pi_oos_marker_streak" "$_pi_oos_marker_fingerprint"; then
      pi_error "PR #${pr_number}: kind=${kind} round=${next_round} marker 書き込みに失敗 (needs-iteration を残置)"
      return 1
    fi

    # Issue #397: round 終了時の outcome を 3 way に分類（success / escalate / no-progress）。
    # 旧実装は commit 無しでも streak < limit なら finalize 成功扱いに倒れていた
    # （`needs-iteration` を外して `awaiting-design-review` / `ready-for-review` に遷移）。
    # その結果 PR が候補プールから外れて no-progress streak が永久に加算されず escalation
    # に到達しない silent deadlock が発生していた。本分岐で no-progress を独立扱いにする。
    local outcome
    outcome=$(pi_classify_round_outcome "$commit_pushed" "$new_streak" "$PR_ITERATION_NO_PROGRESS_LIMIT")
    case "$outcome" in
      escalate)
        # Issue #122 Req 3.3 / 6.3 / Issue #397 Req 2.3 / 2.4 / 5.3:
        # no-progress 連続カウンタが上限以上 → claude-failed 昇格。
        # ログには PR 番号 / kind / round / reason / streak / limit を含める（Req 5.3）。
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT} reason=no-progress escalate"
        pi_escalate_to_failed "$pr_number" "$next_round" "$max_rounds" "no-progress" "$new_streak" || true
        return 2
        ;;
      no-progress)
        # Issue #397 Req 1.1〜1.3 / 2.1 / 2.2 / 4.1 / 4.2 / 5.2:
        # commit が無かった round では finalize（needs-iteration 除去）に進まず、
        # `needs-iteration` を据え置いて return する。`action=success` ログは出さない。
        # streak は marker 上で既に加算済み（次サイクルで pi_read_no_progress_streak が拾う）。
        pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=no-progress (needs-iteration を残置, streak=${new_streak}/${PR_ITERATION_NO_PROGRESS_LIMIT})"
        return 1
        ;;
      success)
        : # 通常 finalize に進む
        ;;
      *)
        # 想定外: 安全側に倒して needs-iteration 据え置き
        pi_warn "PR #${pr_number}: kind=${kind} round=${next_round} unknown round outcome='${outcome}' (needs-iteration を残置)"
        return 1
        ;;
    esac

    # AC 6.2 (#26) / #35 AC 3.1 / 3.2 / Issue #397 Req 3.1〜3.3 / 4.3:
    # commit_pushed=true（outcome=success）のみここに到達する。kind に応じたラベル遷移を実施。
    local finalize_ok=false
    case "$kind" in
      design)
        if pi_finalize_labels_design "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (needs-iteration -> awaiting-design-review)"
          finalize_ok=true
        fi
        ;;
      impl)
        if pi_finalize_labels "$pr_number"; then
          pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=success (needs-iteration -> ready-for-review)"
          finalize_ok=true
        fi
        ;;
    esac
    if [ "$finalize_ok" = "true" ]; then
      return 0
    fi
    pi_warn "PR #${pr_number}: kind=${kind} ラベル遷移失敗、needs-iteration を残置"
    return 1
  else
    # AC 6.3 (#26) / #35 AC 3.3: 失敗 → needs-iteration を残し WARN
    # Issue #122 Req 5.3: claude CLI が非 0 終了した round では marker 据え置き
    # （上記 case で recover_status が none: / post-round-commit:ok のときのみここに来るが、
    # rc != 0 の場合は claude が失敗しているので marker は触らない）
    pi_log "PR #${pr_number}: kind=${kind} round=${next_round} action=fail (needs-iteration を残置)"
    return 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_iteration: PR Iteration Processor のエントリ関数
#   AC 1.6, 2.1, 2.2, 8.5, 9.1, 9.3, NFR 1.2, NFR 2.3
# ─────────────────────────────────────────────────────────────────────────────
process_pr_iteration() {
  # AC 2.1: opt-out gate（#112 以降デフォルト有効。PR_ITERATION_ENABLED=false で無効化）
  if [ "$PR_ITERATION_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3 / AC 8.5: dirty working tree 検知
  # #118 Req 3.1〜3.5: 前 cycle で round が途中終了して dirty を残した場合、
  # current branch が `claude/issue-<N>-<slug>` 命名規約に合致するときは auto-commit /
  # push で clean state に戻し、Processor の本処理を継続する。合致しない branch では
  # ERROR + skip（既存挙動と同じ安全側）。QUOTA_AWARE_ENABLED とは独立（Req 5.2）。
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    local _pi_pre_branch _pi_dirty_paths _pi_pre_issue
    _pi_pre_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    # dirty 一覧は `git status --porcelain` の `XY path` 列を末尾だけ取り出し、コンマ区切り化
    _pi_dirty_paths=$(git status --porcelain 2>/dev/null | awk '{
      $1=""; sub(/^ /, ""); printf "%s%s", (NR>1?",":""), $0
    }')
    # branch 名から PR 番号を派生（Req 4.2: PR 番号 / branch / 種別 / 結果 を出力）
    _pi_pre_issue=$(echo "$_pi_pre_branch" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
    # Req 3.1: branch 名と dirty パス一覧をログに記録（recover/skip 双方の経路で出力）
    pi_log "pre-cycle dirty 検出 issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} paths=${_pi_dirty_paths}"

    if pi_branch_is_claude_pr_head "$_pi_pre_branch"; then
      # Req 3.2 / 3.3: 規約一致 branch に対して auto-commit / push して継続
      if pi_auto_commit_and_push \
          "docs(specs): recover pre-cycle dirty state on ${_pi_pre_branch} (auto)" \
          "$_pi_pre_branch"; then
        # 本処理は BASE_BRANCH で動かすため、回復後に BASE_BRANCH に戻す。
        # `set -e` 配下なので checkout 失敗時は次の git ops で検出され ERROR に倒れる。
        git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
        # Req 4.2: PR 番号 / branch / 種別 / 結果 を 1 行で出力
        pi_log "pre-cycle-recover issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} action=success"
      else
        # Req 3.5: 自動回復失敗は ERROR + skip（次サイクルで再評価）
        pi_error "pre-cycle-recover issue=#${_pi_pre_issue:-?} branch=${_pi_pre_branch} action=fail (PR Iteration Processor をスキップします)"
        return 0
      fi
    else
      # Req 3.4: claude/issue-<N>-<slug> 規約外の branch では auto-commit せず skip
      pi_error "dirty working tree を検出しました（branch=${_pi_pre_branch} は claude/issue-<N>-<slug> 規約外）。PR Iteration Processor をスキップします。"
      return 0
    fi
  fi

  # Issue #122 Req 6.1 / NFR 3.1: kind 別 round 上限の解決値と no-progress 上限を
  # 1 行サマリログで出力（grep 'max_rounds_impl=' で機械抽出可能）。
  local _resolved_max_impl _resolved_max_design
  _resolved_max_impl=$(pi_resolve_max_rounds "impl")
  _resolved_max_design=$(pi_resolve_max_rounds "design")
  pi_log "サイクル開始 (max_prs=${PR_ITERATION_MAX_PRS}, max_rounds_impl=${_resolved_max_impl}, max_rounds_design=${_resolved_max_design}, no_progress_limit=${PR_ITERATION_NO_PROGRESS_LIMIT}, model=${PR_ITERATION_DEV_MODEL}, design_enabled=${PR_ITERATION_DESIGN_ENABLED}, timeout=${PR_ITERATION_GIT_TIMEOUT}s)"

  local prs_json
  prs_json=$(pi_fetch_candidate_prs)
  local total
  total=$(echo "$prs_json" | jq 'length')

  # #35 NFR 3.2: 候補 PR の design / impl 内訳をログに記録（kind=ambiguous も含む）。
  # candidate 段階では impl pattern OR (DESIGN_ENABLED=true AND design pattern) で絞られる
  # ため、ここでは bash 側で同じ正規表現照合を行って breakdown を出す。
  local design_count=0
  local impl_count=0
  local ambiguous_count=0
  if [ "$total" -gt 0 ]; then
    local breakdown
    breakdown=$(echo "$prs_json" | jq -r \
      --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
      --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
      --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
      '[.[] | .headRefName] as $heads
       | reduce $heads[] as $h ({"design":0, "impl":0, "ambiguous":0};
           if ($h | test($impl_pattern)) and ($h | test($design_pattern))
             then .ambiguous += 1
           elif ($h | test($design_pattern)) and ($design_enabled == "true")
             then .design += 1
           elif ($h | test($impl_pattern))
             then .impl += 1
           else . end)
       | "\(.design) \(.impl) \(.ambiguous)"')
    # shellcheck disable=SC2086
    set -- $breakdown
    design_count="${1:-0}"
    impl_count="${2:-0}"
    ambiguous_count="${3:-0}"
  fi

  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$PR_ITERATION_MAX_PRS" ]; then
    target_count="$PR_ITERATION_MAX_PRS"
    skipped_overflow=$((total - PR_ITERATION_MAX_PRS))
    pi_log "対象候補 ${total} 件中、上限 ${PR_ITERATION_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し、内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  else
    pi_log "対象候補 ${total} 件、処理対象 ${target_count} 件（内訳: design=${design_count}, impl=${impl_count}, ambiguous=${ambiguous_count}）"
  fi

  if [ "$target_count" -eq 0 ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  local success=0
  local fail=0
  local skip=0
  local escalated=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    pi_log "サマリ: success=0, fail=0, skip=0, escalated=0, overflow=${skipped_overflow} (design=0, impl=0)"
    return 0
  fi

  while IFS= read -r pr_json; do
    local rc=0
    pi_run_iteration "$pr_json" || rc=$?
    case $rc in
      0)  success=$((success + 1)) ;;
      2)  escalated=$((escalated + 1)) ;;
      3)  skip=$((skip + 1)) ;;       # #35: kind=none / ambiguous は skip としてカウント
      *)  fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  # #35 NFR 3.1 / 3.2: サマリにも design / impl 内訳を出して grep 集計可能にする
  pi_log "サマリ: success=${success}, fail=${fail}, skip=${skip}, escalated=${escalated}, overflow=${skipped_overflow} (design=${design_count}, impl=${impl_count})"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}
