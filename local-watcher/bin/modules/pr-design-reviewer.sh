#!/usr/bin/env bash
# shellcheck shell=bash
# pr-design-reviewer.sh — watcher の Design PR Reviewer モジュール (#407)
#
# 用途:
#   設計 PR (`claude/issue-<N>-design-<slug>`) に対する独立 Claude 設計レビュアの本体。
#   `DESIGN_REVIEWER_ENABLED=true` のとき open / non-draft の設計 PR を検出し、
#   `docs/specs/<N>-<slug>/{requirements.md, design.md, tasks.md}` の 3 観点
#   （AC カバレッジ / design⇄tasks 整合 / Traceability）で `approve` / `reject` を判定する。
#   判定結果は `claude-review` commit status の publish と `needs-iteration` ラベルの
#   付与・解消の根拠となり、人間運用の `awaiting-design-review` ラベルゲートと OR 条件で
#   merge 経路を成立させる（admin-merge への依存を解消）。
#
#   設計の詳細は docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/design.md を参照。
#
#   - opt-in gate 判定: pdr_gate_enabled
#     既に正規化済みの `DESIGN_REVIEWER_ENABLED`（issue-watcher.sh の Config で
#     `case true) ... *) false` に正規化済み）を厳密 `=true` で評価する。重複正規化は
#     行わない（既定値の責任は呼び出し側 / Req 6.1）。
#   - head pattern マッチング: pdr_classify_design_pr
#     `DESIGN_REVIEWER_HEAD_PATTERN`（既定 `^claude/issue-[0-9]+-design-`）と head_ref を
#     ERE で照合し、design / 非 design の 2 値判定を返す（Req 1.3, 7.4）。
#   - 候補 PR 取得: pdr_fetch_design_prs
#     `gh pr list --state open --search "-draft:true"` + jq filter で
#     `isDraft == false` / fork 除外 / head pattern 一致を厳格化する。既存
#     `pr_fetch_candidate_prs`（pr-reviewer.sh）の構造を踏襲（流用ではなく独立 fetch /
#     Req 7.2 経路独立）。
#   - per-sha dedup: pdr_already_processed
#     hidden marker `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->` の
#     存在を `gh pr view --json comments` で確認し、同一 (PR, sha) での重複起動を回避
#     （Req 1.4）。
#
#   後続関数（task 4-6）:
#   - pdr_invoke_reviewer / pdr_parse_verdict / pdr_validate_verdict
#     （Claude CLI 呼び出し + 出力 parse + schema 検証）
#   - pdr_apply_label_decision / pdr_apply_status_decision / pdr_post_decision_comment
#     （needs-iteration ラベル制御 + claude-review status publish + decision コメント投稿）
#   - pdr_run_review_for_pr / process_pr_design_reviewer
#     （1 PR オーケストレーション + dispatcher エントリ）
#
# 配置先:
#   $HOME/bin/modules/pr-design-reviewer.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - 関数 prefix `pdr_` で namespace する（CLAUDE.md「機能追加ガイドライン §2」登録済み）。
#   - ロガー pdr_log / pdr_warn / pdr_error は core_utils.sh に定義済み（#407 task 1 で追加）。
#     本モジュールは bash の遅延束縛で参照するのみで、再定義しない。
#   - グローバル変数（$REPO / $DESIGN_REVIEWER_ENABLED 他 6 env / $LABEL_NEEDS_ITERATION 等）は
#     本体冒頭の Config ブロックで定義済み（issue-watcher.sh / task 1 で追加）。本モジュールは
#     env を消費するのみで、再宣言・再正規化しない。
#   - 外部 CLI: gh / jq / git / claude（後続 task で使用）。
#   - 既存 helper の read-only 流用: `pr_publish_claude_status`（pr-reviewer.sh）を
#     `pdr_apply_status_decision` から呼び出す（同一 source プロセスに load 済み）。
#     pr-reviewer.sh / adjudicator.sh の関数本体は **変更しない**（Req 7.2, 7.3）。
#
# セットアップ参照先:
#   - 要件: docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/requirements.md
#   - 設計: docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/design.md
#   - README「Design PR Reviewer (#407)」節（task 8 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# pdr_gate_enabled: opt-in gate 評価（既に正規化済みの env を厳密一致で判定）
#   入力: なし（env のみ参照）
#   出力: なし
#   戻り値: 0 = ON / 1 = OFF
#
#   issue-watcher.sh の Config ブロックで `DESIGN_REVIEWER_ENABLED` は
#   `case true) ... *) false` で正規化されているため、本関数は厳密 `=true` 判定のみ行う
#   （既定 / 未設定 / typo / 大文字違い等はすべて OFF / Req 6.1 安全側 / 重複正規化はしない）。
# ─────────────────────────────────────────────────────────────────────────────
pdr_gate_enabled() {
  if [ "${DESIGN_REVIEWER_ENABLED:-false}" = "true" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_classify_design_pr: head_ref を DESIGN_REVIEWER_HEAD_PATTERN と照合
#   入力: $1 = head_ref（例: claude/issue-407-design-foo）
#   出力: なし
#   戻り値: 0 = design（pattern マッチ）/ 1 = 非 design（pattern 不一致 / 入力空）
#
#   Req: 1.3 / 7.4（impl PR / 非対応 head の除外）
#
#   - DESIGN_REVIEWER_HEAD_PATTERN は POSIX ERE で `^claude/issue-[0-9]+-design-` 既定。
#   - bash [[ =~ ]] で ERE 評価。head_ref が空 / pattern 不一致なら非 design (rc=1)。
#   - 副作用なし（純粋関数）。
# ─────────────────────────────────────────────────────────────────────────────
pdr_classify_design_pr() {
  local head_ref="${1:-}"
  if [ -z "$head_ref" ]; then
    return 1
  fi
  local pattern="${DESIGN_REVIEWER_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
  if [[ "$head_ref" =~ $pattern ]]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_fetch_design_prs: 設計 PR 候補を JSON 配列で stdout に返す
#   入力: なし
#   出力: stdout に jq 配列 JSON（候補なし / 失敗時は "[]"）
#   戻り値: 0 固定（失敗は degraded path = "[]" + WARN に倒す）
#
#   Req: 1.1 / 1.3 / 7.4（open + non-draft 設計 PR のみ）
#
#   - server-side: `--state open --search "-draft:true"`（既存 pr_fetch_candidate_prs 同方針）
#   - client-side fail-safe: `select(.isDraft == false)`（draft 二重防御）+
#     fork 除外（headRepositoryOwner.login == owner）+
#     head pattern 厳格化（`DESIGN_REVIEWER_HEAD_PATTERN` ERE 一致）
#   - 上限件数 truncate は呼び出し元 process_pr_design_reviewer で観測ログ付きで行う。
# ─────────────────────────────────────────────────────────────────────────────
pdr_fetch_design_prs() {
  local repo_owner="${REPO%%/*}"
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local prs_json
  if ! prs_json=$(timeout "$timeout_s" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "-draft:true" \
      --json number,headRefName,headRefOid,baseRefName,isDraft,url,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    pdr_warn "設計 PR 候補の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # 未信頼入力（head_ref / owner）は jq の --arg でリテラル渡し、filter 文字列に inline 展開しない
  # （CLAUDE.md §5 安全規約）。
  echo "$prs_json" | jq \
    --arg pattern "${DESIGN_REVIEWER_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(.headRefName | test($pattern))
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_already_processed: 同一 (PR, sha) で本 processor が既に判定済みかを hidden marker
#   scan で判定する
#   入力: $1 = pr_number, $2 = sha
#   出力: なし（log のみ）
#   戻り値: 0 = 処理済み（skip）/ 1 = 未処理（実行）
#
#   Req: 1.4（per-sha dedup / 同一 sha への重複起動回避）/ 5.3（marker prefix が
#        pi self-filter `idd-claude:pr-iteration` と非衝突）
#
#   - hidden marker 形式: `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->`
#   - prefix `pr-design-reviewer` は既存 `pr-reviewer` / `pr-iteration` / `pr-adjudicator`
#     のいずれとも前方一致しない（#400 self-filter 規約と非衝突 / Req 5.3）。
#   - 未信頼入力（sha）は jq の `--arg` でリテラル渡し、filter 文字列に inline 展開しない
#     （CLAUDE.md §5 / 既存 pr_already_processed / adj_post_decision_comment と同方針）。
#   - gh API 失敗時は **安全側（重複投稿回避）** に倒し「既存扱い (rc=0)」で skip
#     （adj_post_decision_comment と同方針 / fail-safe）。
# ─────────────────────────────────────────────────────────────────────────────
pdr_already_processed() {
  local pr_number="${1:-}"
  local sha="${2:-}"

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pdr_warn "pdr_already_processed: 無効な PR 番号 '${pr_number}'"
    return 0
  fi
  if [ -z "$sha" ]; then
    pdr_warn "pdr_already_processed: sha が空（pr=#${pr_number}）"
    return 0
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local comments_json
  if ! comments_json=$(timeout "$timeout_s" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pdr_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定を skip = 安全側で既存扱い）"
    return 0
  fi

  if echo "$comments_json" | jq -e \
      --arg sha "$sha" \
      'any(.[]; (.body // "") | test("idd-claude:pr-design-reviewer sha=" + $sha + "[^>]*kind=decision"))' \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
