#!/usr/bin/env bash
# slot-worker-resume.sh — Slot Runner の resume / slug 判定 / pre-claim / status publish
#
# family: slot-worker / prefix: なし（#502 で slot-worker.sh から分割。family マニフェストは
#   slot-worker.sh 冒頭ヘッダを参照）
#
# 用途:
#   Phase C Slot Runner（#16）のうち、resume 系（既存 branch 検出 / branch 初期化 / push /
#   non-fast-forward 失敗遷移）、slug 正規化・一致判定、pre-claim filter（既存 impl PR /
#   設計 PR の有無判定）、claude-review commit status publish（#349）を担う関数群。
#     - check_existing_impl_pr                              : 実装 PR の既存有無 pre-claim 判定
#     - check_open_design_pr                                : 設計 PR の既存有無 pre-claim 判定
#     - _resume_normalize_flag                              : resume フラグ正規化
#     - _resume_detect_existing_branch                      : 既存 branch 検出（resume 判定）
#     - _resume_branch_init                                 : resume 時の branch 初期化
#     - _resume_push                                        : resume 時の push 処理
#     - _resume_mark_nonff_failed                           : non-fast-forward 失敗時の遷移
#     - _normalize_slug                                     : slug 正規化（純粋関数）
#     - _slug_mismatch_escalate                             : slug 不一致時のエスカレーション
#     - _stage_checkpoint_assert_slug_match                 : stage checkpoint の slug 一致 assert
#     - _stage_checkpoint_has_resumable_state               : resumable な checkpoint 状態の判定
#     - _resume_branch_assert_slug_match                    : resume branch の slug 一致 assert
#     - publish_claude_review_status                        : claude-review commit status publish（#349）
#
#   `_stage_checkpoint_assert_slug_match` / `_stage_checkpoint_has_resumable_state` は
#   stage-checkpoint.sh の `sc_` 系とは別関数（Slot Runner 所属 / #466。CLAUDE.md prefix 表の
#   注記を参照）。
#
#   詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
#
# 配置先:
#   $HOME/bin/modules/slot-worker-resume.sh（install.sh が modules/*.sh を glob 配布するため、
#   family ファイル追加で installer 変更は不要）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $BASE_BRANCH / $SPEC_DIR_REL 等）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛により呼び出し時に解決される。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）
#
# SC2153 disable の背景（#466 で slot-worker.sh に導入 / #502 の family 分割で本ファイルへ移設。
# 実測 shellcheck で本ファイルのみ発火を確認 / orchestrator 側は _slot_run_issue が $BRANCH を
# 同一ファイル内で代入するため非発火）:
#   本ファイルの resume 系関数（_resume_branch_init / _resume_push / _resume_detect_existing_branch
#   等）は大文字グローバル環境変数 `$BRANCH`（本体 main loop / Slot Runner で代入される対象
#   branch 名）を参照する。同一ファイル内の別関数に小文字ローカル `branch`（引数 `$1` を
#   受ける resume 系ヘルパー複数）が存在するため、分割前の issue-watcher.sh 単体では大文字側の
#   実代入が同一ファイルに見えて非発火だった SC2153（「typo では」）が、module 単体では
#   cross-file 可視性の喪失で新規発火する。関数移動対象自体は無改変（#455 共通規約）。
# shellcheck disable=SC2153

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Dependency Resolver / Auto-Unblock Sweep (#146 / #346) — modules/dependency-resolver.sh へ切り出し済み（#465）
#   PM phase 依存解決ゲート + Auto-Unblock Sweep の全 15 関数（dr_log / dr_warn / dr_error /
#   dr_extract_deps / dr_format_unresolved_comment / dr_gh_graphql_closed_by / dr_resolve_one /
#   dr_apply_block / dr_check_dependencies / dr_unblock_gate_enabled / dr_unblock_has_orphan_marker /
#   dr_unblock_post_unblocked_comment / dr_unblock_post_orphan_marker_comment /
#   dr_unblock_resolve_one_issue / dr_unblock_sweep）+ 定数 2 個（DR_UNBLOCK_MARKER_CLEARED /
#   DR_UNBLOCK_MARKER_ORPHAN）は modules/dependency-resolver.sh が定義する。
#   隣接していた publish_claude_review_status（dr_ 系ではない）はここより下（旧 dr_unblock_gate_enabled
#   と dr_unblock_has_orphan_marker の間）に定義位置を保ったまま本体残置（次 issue #466 で
#   modules/slot-worker.sh へ移動予定）。
#   呼び出し元（Slot Runner の dr_check_dependencies 呼び出し / main loop の dr_unblock_sweep
#   呼び出し）は実行順序温存のため本体残置。bash の遅延束縛のため順序問題なし。
#   詳細: docs/specs/146-feat-harness-pm-phase-issue-issue-merge/design.md /
#         docs/specs/346-feat-watcher-blocked-unblock/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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
  # #521 Req 6: per-branch PR 存在確認を grl_rest_prs_for_head 経由にし、offload on 時は REST
  # （core バケット）へ逃がす。offload off / REST 失敗時は従来 gh pr list --head へ fallback
  # （number/state/headRefName/headRefOid/url の互換 JSON を返すため下流 jq 抽出は不変 / NFR 1.1）。
  local pr_json pr_number sha pr_url
  if ! pr_json=$(grl_rest_prs_for_head "$BRANCH" "all" "${PR_REVIEWER_GIT_TIMEOUT:-120}"); then
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
