#!/usr/bin/env bash
# shellcheck shell=bash
# security-review.sh — watcher の Security Review Processor モジュール (#279)
#
# 用途:
#   issue-watcher.sh から分離した Security Review Processor (#279) の関数定義を集約する。
#   `SECURITY_REVIEW_ENABLED=true` のとき Claude Code 公式 `/security-review` skill を
#   `claude` CLI headless 起動経由で呼び出し、open PR の diff に対するセキュリティレビューを
#   PR コメントとして投稿する。本 spec では **advisory 固定**動作（マージブロックなし）で、
#   strict 拡張は別 Issue #281 として段階導入する。
#   - 入口: process_security_review（dispatcher から呼ばれる / 本 task では未実装、次 task 4 で配線）
#   - 重複防止 marker: sec_build_marker / sec_already_processed（gh api comments + jq）
#   - 候補 PR 列挙: sec_fetch_candidate_prs（open + 非 draft + head pattern + 非 fork）
#   - strict 要求検出: sec_check_strict_request（advisory 固定 fallback、Req 5.3）
#   - spec ディレクトリ解決: sec_resolve_spec_dir（ブランチ名から issue 番号抽出 → glob 1 件マッチ）
#   - スキャン実行 / コメント投稿 / security-notes.md 書き出し: 次 task 3 以降で実装予定
#
# 配置先:
#   $HOME/bin/modules/security-review.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー sec_log / sec_warn / sec_error は core_utils.sh に定義済み（#279 task 1 で追加）。
#   - グローバル変数（$REPO / $REPO_DIR / $BASE_BRANCH / $SECURITY_REVIEW_ENABLED /
#     $SECURITY_REVIEW_HEAD_PATTERN / $SECURITY_REVIEW_GIT_TIMEOUT 等）は本体冒頭の
#     Config ブロックで定義される予定（task 4.2 で配線）。bash の遅延束縛により呼び出し時に解決される。
#   - top-level orchestration 呼び出し配線（process_security_review || sec_warn ...）は
#     本体 entry point に残置する（本モジュールは関数定義のみ / task 4.4 で配線）。
#   - 外部 CLI: gh / git / jq / claude（健全性チェック・レビュー実行で使用）。
#
# セットアップ参照先:
#   - 設計: docs/specs/279-feat-watcher-security-review-opt-in-pr-d/design.md
#   - README「Security Review Processor (#279)」節（task 5 で追加予定）

# ─────────────────────────────────────────────────────────────────────────────
# sec_build_marker: hidden HTML comment 形式の重複防止 marker を構築（task 2.2）
#   入力: $1 = sha (headRefOid), $2 = kind
#   出力: stdout に marker 文字列 1 個（末尾改行なし）
#   AC: 3.4, 6.1, 6.4
#
#   形式: <!-- idd-claude:security-review sha=<sha> kind=<kind> -->
#   design.md State / Marker Contract と byte 一致。GitHub 上では非表示。
#   pr-reviewer の marker と異なり tool= 属性は **持たない**（design.md「State /
#   Marker Contract」節 / Req 6.4）。Security Review は単一実行ツール（claude CLI）
#   のため tool 識別子を marker に焼き込まない。
# ─────────────────────────────────────────────────────────────────────────────
sec_build_marker() {
  local sha="${1:-}"
  local kind="${2:-}"
  printf '<!-- idd-claude:security-review sha=%s kind=%s -->' "$sha" "$kind"
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_check_strict_request: strict 要求 env の有無を確認し advisory 固定で続行（task 2.3）
#   入力: 環境変数のみ
#     - SECURITY_REVIEW_MODE: 期待値 "advisory"（未設定 / 空 / "advisory" 以外は WARN）
#     - SECURITY_REVIEW_STRICT: 期待値 未設定 / 空（非空なら WARN）
#   出力: stdout に常に "advisory" を 1 行
#   戻り値: 0 固定
#   AC: 5.1, 5.2, 5.3
#
#   本 spec では strict モード（severity 閾値ベースのマージ阻害ラベル付与）を実装しない。
#   strict 要求 env が来ても WARN 1 行で「strict は本 spec 未実装 / 別 Issue #281 待ち」を
#   記録した上で、stdout には常に advisory 固定値を返す（Req 5.3 確定）。
#   stdout は単一 token 契約のため、観測ログは sec_warn（stderr）のみを使用する。
# ─────────────────────────────────────────────────────────────────────────────
sec_check_strict_request() {
  local mode="${SECURITY_REVIEW_MODE:-}"
  local strict="${SECURITY_REVIEW_STRICT:-}"

  # SECURITY_REVIEW_MODE が advisory 以外の非空値 → WARN
  if [ -n "$mode" ] && [ "$mode" != "advisory" ]; then
    sec_warn "SECURITY_REVIEW_MODE='${mode}' を検出しましたが strict モードは本 spec 未実装です（別 Issue #281 待ち）。advisory 固定で続行します"
  fi

  # SECURITY_REVIEW_STRICT が非空 → WARN
  if [ -n "$strict" ]; then
    sec_warn "SECURITY_REVIEW_STRICT='${strict}' を検出しましたが strict モードは本 spec 未実装です（別 Issue #281 待ち）。advisory 固定で続行します"
  fi

  echo "advisory"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_fetch_candidate_prs: 候補 PR を JSON 配列で返す（task 2.4）
#   出力: stdout に jq 配列形式の JSON 1 行（候補なし / 失敗時は "[]"）
#   戻り値: 0 固定（失敗は degraded path = "[]" + WARN に倒す）
#   AC: 2.1, 2.3, NFR 3.1
#
#   - server-side: `--state open --search "-draft:true"`（open + draft 除外、AC 2.1/2.3）
#   - client-side fail-safe: `select(.isDraft == false)`（draft 二重防御、AC 2.3）+
#     head pattern 一致（SECURITY_REVIEW_HEAD_PATTERN、既定 `^claude/issue-`）+
#     fork 除外（headRepositoryOwner.login == owner）。既存 pr_fetch_candidate_prs 踏襲。
#   - 上限件数 (SECURITY_REVIEW_MAX_PRS) の truncate は呼び出し元 process_security_review で
#     total / target / overflow をログ出力しながら行う（NFR 3.1 観測性、pr 踏襲 / task 4.1）。
# ─────────────────────────────────────────────────────────────────────────────
sec_fetch_candidate_prs() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$SECURITY_REVIEW_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "-draft:true" \
      --json number,headRefName,headRefOid,baseRefName,isDraft,url,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    sec_warn "候補 PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  echo "$prs_json" | jq \
    --arg pattern "$SECURITY_REVIEW_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select((.headRepositoryOwner.login // "") == $owner)
      | select(.headRefName | test($pattern))
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_already_processed: 同一 (sha, kind) marker が既存コメントに在るか判定（task 2.5）
#   入力: $1 = pr_number, $2 = sha, $3 = kind
#   出力: なし
#   戻り値: 0 = 既存（skip すべき）/ 1 = 未存在（処理を続行してよい）
#   AC: 2.4, 6.2, 6.3, NFR 4.1
#
#   - `gh api /repos/$REPO/issues/<n>/comments` で全コメントを取得し、jq で
#     marker（sha と kind の双方一致）の存在を test する。kind 3 値（`security-review` /
#     `security-review-clean` / `scan-failed`）すべてで動作する。
#   - sha は hex、kind は固定語彙のため正規表現メタ文字を含まず test() に安全
#     （既存 pr_already_processed と同方針）。
#   - gh API 失敗時は **安全側（重複投稿回避）** に倒し「既存扱い (rc=0)」で skip。
#     SHA が不変なら次サイクルで再評価されるため self-heal する（NFR 3.1 で WARN 記録）。
# ─────────────────────────────────────────────────────────────────────────────
sec_already_processed() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local kind="${3:-}"

  local comments_json
  if ! comments_json=$(timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    sec_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"
    return 0
  fi

  if echo "$comments_json" | jq -e \
      --arg sha "$sha" \
      --arg kind "$kind" \
      'any(.[]; (.body // "") | test("idd-claude:security-review sha=" + $sha + "[^>]*kind=" + $kind))' \
      >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_resolve_spec_dir: PR ブランチ名から spec ディレクトリを解決（task 2.6）
#   入力: $1 = pr_branch（例: claude/issue-279-design-feat-watcher-security-review-opt-in-pr-d）
#   出力: stdout に spec ディレクトリ絶対パス、または空文字（特定不可時）
#   戻り値: 0 固定
#   AC: 3.5
#
#   解決順序:
#     1. ブランチ名から issue 番号を抽出（`^claude/issue-(\d+)-` の \1）
#     2. `$REPO_DIR/docs/specs/<番号>-*/` を bash glob し、配列展開して件数判定
#     3. 1 件マッチで採用（絶対パスで stdout 出力）、0 件 / 2 件以上で空文字
#
#   - stdout は spec ディレクトリパス契約のため、観測ログ（WARN を含む）は呼び出し元
#     （task 3.3 で実装予定の sec_write_security_notes）に委ねる。本関数は単純な解決のみ。
#   - bash の nullglob を一時的に有効化して、マッチ 0 件時の glob リテラル残留を防ぐ。
#     呼び出し元の shopt 状態を破壊しないよう、関数末尾で復元する。
# ─────────────────────────────────────────────────────────────────────────────
sec_resolve_spec_dir() {
  local pr_branch="${1:-}"

  # ブランチ名から issue 番号を抽出
  local issue_num=""
  if [[ "$pr_branch" =~ ^claude/issue-([0-9]+)- ]]; then
    issue_num="${BASH_REMATCH[1]}"
  fi

  if [ -z "$issue_num" ]; then
    printf ''
    return 0
  fi

  # 既存の nullglob 設定を退避してから有効化（呼び出し元の shopt 状態を保護）
  local nullglob_was_set=0
  if shopt -q nullglob; then
    nullglob_was_set=1
  fi
  shopt -s nullglob

  # glob 展開（REPO_DIR 相対）
  local matches=("${REPO_DIR}/docs/specs/${issue_num}-"*/)

  # nullglob 状態を復元
  if [ "$nullglob_was_set" -eq 0 ]; then
    shopt -u nullglob
  fi

  # 1 件マッチで採用、0 件 / 2 件以上で空文字
  if [ "${#matches[@]}" -eq 1 ]; then
    # 末尾スラッシュを除去して絶対パスとして出力
    local resolved="${matches[0]%/}"
    printf '%s' "$resolved"
  else
    printf ''
  fi
  return 0
}
