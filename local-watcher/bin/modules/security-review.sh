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
# sec_check_strict_request: ゲート挙動 mode を解決して stdout に返す（#281 task 4）
#   入力: 環境変数のみ
#     - SECURITY_REVIEW_MODE: 期待値 "advisory" または "strict" 厳密一致。未設定 / 空 /
#       "advisory" は advisory 解釈、"strict" は strict 解釈、それ以外は WARN + advisory
#       fallback。
#     - SECURITY_REVIEW_STRICT: #279 で導入された defensive env。本 spec では deprecated
#       alias として WARN のみ出力し、mode 解決には一切影響させない（後方互換 / sudden
#       break 回避）。
#   出力: stdout に "advisory" または "strict" を 1 行
#   戻り値: 0 固定
#   AC: 1.1, 1.2, 1.4, 1.5
#
#   解決順序:
#     1. SECURITY_REVIEW_MODE == "strict" 厳密一致 → "strict" を返す（Req 1.2）
#     2. SECURITY_REVIEW_MODE が "advisory" / 未設定 / 空 → "advisory" を返す（Req 1.1, 1.5、
#        #279 と byte 等価）
#     3. SECURITY_REVIEW_MODE が上記以外（typo / 大文字混在 / 空白混入等）→ sec_warn 1 行
#        + "advisory" fallback（Req 1.4）
#     4. SECURITY_REVIEW_STRICT が非空 → deprecated alias 警告 WARN 1 行のみ（mode は
#        変更しない / #279 と byte 等価）
#
#   後方互換ポイント:
#     - #279 では本関数は「strict 要求 env が来ても WARN + advisory 固定」の safe-fallback
#       実装だったが、#281 で実 mode 解決に切替（Req 1.2 で strict 解釈の AC が明示された
#       ため）。
#     - SECURITY_REVIEW_MODE 未設定 / "advisory" 環境では引き続き advisory を返すため、
#       既存運用に影響を与えない（NFR 1.1）。
#     - SECURITY_REVIEW_STRICT=anything 環境は引き続き mode 変更なし + WARN 1 行のまま
#       （#279 と byte 等価）。これにより #279 ユーザが誤って STRICT env を set した状態
#       が sudden break を起こさない。
#
#   stdout は単一 token 契約のため、観測ログは sec_warn（stderr）のみを使用する。
# ─────────────────────────────────────────────────────────────────────────────
sec_check_strict_request() {
  local mode="${SECURITY_REVIEW_MODE:-}"
  local strict="${SECURITY_REVIEW_STRICT:-}"
  local resolved

  case "$mode" in
    strict)
      resolved="strict"
      ;;
    advisory|"")
      resolved="advisory"
      ;;
    *)
      sec_warn "SECURITY_REVIEW_MODE='${mode}' は許容値（strict/advisory）に一致しません。既定 'advisory' で続行します"
      resolved="advisory"
      ;;
  esac

  # SECURITY_REVIEW_STRICT は deprecated alias。mode 解決には影響させず WARN のみ出す
  # （#279 と byte 等価で sudden break 回避）。
  if [ -n "$strict" ]; then
    sec_warn "SECURITY_REVIEW_STRICT='${strict}' は deprecated alias です。mode 切替には SECURITY_REVIEW_MODE=strict を使用してください（本 env は mode 解決に影響しません）"
  fi

  echo "$resolved"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_resolve_block_severity: severity 閾値 env を解決し許容値に正規化する（#281 task 3）
#   入力: 環境変数のみ
#     - SECURITY_REVIEW_BLOCK_SEVERITY: 期待値 critical/high/medium/low/info の小文字 5 値
#       のいずれか。未設定 / 空 / 不正値（typo / 大文字混在 / 空白混入等）は WARN + "high"
#       fallback。
#   出力: stdout に 5 値のいずれか 1 行（小文字 token）
#   戻り値: 0 固定
#   AC: 2.1, 2.2, 2.4
#   副作用: 不正値検出時に sec_warn 1 行を stderr に出す
#
#   - 未設定 / 空 → WARN なしで既定 "high" 採用（Req 2.2 既定値 / 既存 #279 と byte 等価）。
#   - 5 値以外（大文字混在 / typo / 空白混入等）→ sec_warn 1 行 + "high" fallback（Req 2.4）。
#   - shell metacharacter / コマンドインジェクション対策はホワイトリスト照合で構造的に防御
#     （design.md Security Considerations）。
#   - stdout 単一 token 契約のため、観測ログは sec_warn（stderr）のみ使用。
# ─────────────────────────────────────────────────────────────────────────────
sec_resolve_block_severity() {
  local raw="${SECURITY_REVIEW_BLOCK_SEVERITY:-}"

  # 未設定 / 空 → 既定 high（WARN なし、本機能導入前と byte 等価）
  if [ -z "$raw" ]; then
    echo "high"
    return 0
  fi

  case "$raw" in
    critical|high|medium|low|info)
      echo "$raw"
      ;;
    *)
      sec_warn "SECURITY_REVIEW_BLOCK_SEVERITY='${raw}' は許容値（critical/high/medium/low/info）に一致しません。既定 'high' で続行します"
      echo "high"
      ;;
  esac
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_severity_at_or_above: severity ordinal 比較ヘルパ（#281 task 3）
#   入力: $1 = severity1, $2 = threshold（どちらも小文字 5 値のいずれか）
#   出力: なし
#   戻り値: 0 = $1 >= $2 / 1 = $1 < $2 / 2 = 入力値不正
#   ordinal map: critical=5, high=4, medium=3, low=2, info=1
#   AC: 2.3
#
#   - ホワイトリスト照合で正規化された値のみを受理する純粋関数。呼び出し元
#     （sec_count_blocking_findings 等）が既に sec_resolve_block_severity 経由で
#     正規化済みの値を渡すことを前提とするが、防御的に入力検証する。
# ─────────────────────────────────────────────────────────────────────────────
sec_severity_at_or_above() {
  local sev="${1:-}"
  local thr="${2:-}"
  local sev_ord thr_ord

  case "$sev" in
    critical) sev_ord=5 ;;
    high)     sev_ord=4 ;;
    medium)   sev_ord=3 ;;
    low)      sev_ord=2 ;;
    info)     sev_ord=1 ;;
    *)        return 2 ;;
  esac

  case "$thr" in
    critical) thr_ord=5 ;;
    high)     thr_ord=4 ;;
    medium)   thr_ord=3 ;;
    low)      thr_ord=2 ;;
    info)     thr_ord=1 ;;
    *)        return 2 ;;
  esac

  if [ "$sev_ord" -ge "$thr_ord" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_count_blocking_findings: severity_summary から閾値以上件数を合算する（#281 task 3）
#   入力: $1 = severity_summary（"critical=N high=N medium=N low=N info=N total=N" 形式、
#         既存 sec_count_severities の出力フォーマット）
#         $2 = threshold（critical/high/medium/low/info の小文字 5 値のいずれか）
#   出力: stdout に整数 1 行（閾値以上件数の合算）
#   戻り値: 0 固定（合算失敗時は "0" を出力して安全側に倒す）
#   AC: 5.1, 5.2
#
#   - 既存 sec_count_severities の出力（"critical=N high=N medium=N low=N info=N total=N"）
#     を sed で各カウントに分解し、sec_severity_at_or_above で閾値以上判定された severity
#     のカウントのみを合算する。
#   - threshold が不正値（sec_severity_at_or_above が rc=2 を返す）の場合は "0" を返す
#     安全側設計（呼び出し元は通常 sec_resolve_block_severity 経由で正規化済みを渡すため
#     到達しない想定だが、防御的フォールバック）。
#   - severity_summary から数値抽出に失敗した severity は 0 として扱う（malformed input
#     でも "0" を返してラベル付与判定をスキップさせる / Req 5.3 安全側設計）。
# ─────────────────────────────────────────────────────────────────────────────
sec_count_blocking_findings() {
  local summary="${1:-}"
  local threshold="${2:-}"

  # threshold 妥当性チェック（無効なら 0 件返して安全側 advisory に倒す）
  case "$threshold" in
    critical|high|medium|low|info) ;;
    *) printf '0'; return 0 ;;
  esac

  local crit high med low info
  crit=$(printf '%s' "$summary" | sed -n 's/.*critical=\([0-9][0-9]*\).*/\1/p')
  high=$(printf '%s' "$summary" | sed -n 's/.*high=\([0-9][0-9]*\).*/\1/p')
  med=$(printf  '%s' "$summary" | sed -n 's/.*medium=\([0-9][0-9]*\).*/\1/p')
  low=$(printf  '%s' "$summary" | sed -n 's/.*low=\([0-9][0-9]*\).*/\1/p')
  info=$(printf '%s' "$summary" | sed -n 's/.*info=\([0-9][0-9]*\).*/\1/p')
  crit="${crit:-0}"; high="${high:-0}"; med="${med:-0}"; low="${low:-0}"; info="${info:-0}"

  local total=0
  local pair sev count
  for pair in "critical:$crit" "high:$high" "medium:$med" "low:$low" "info:$info"; do
    sev="${pair%%:*}"
    count="${pair##*:}"
    if sec_severity_at_or_above "$sev" "$threshold"; then
      total=$((total + count))
    fi
  done

  printf '%s' "$total"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_apply_block_labels: needs-security-fix + needs-iteration の 2 枚ペア付与（#281 task 5）
#   入力: $1 = pr_number, $2 = sha, $3 = blocking_count, $4 = threshold
#   出力: なし（観測ログのみ）
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 付与失敗 or marker 投稿失敗
#   AC: 3.1, 3.4, 3.5, 3.6, 4.4, NFR 4.1, NFR 4.2
#   副作用:
#     - 対象 PR に `${SECURITY_REVIEW_BLOCK_LABEL}` と `needs-iteration` をペア付与
#       （`gh pr edit --add-label "$A,$B"` で 1 コマンド原子付与 / Req 3.1, 4.4）
#     - 当該 PR に hidden marker (`kind=security-block`) を含むコメントを 1 件投稿
#       （SHA 単位の冪等性確立 / NFR 4.1, 4.2）
#     - sec_log で付与結果（blocking_count / threshold / 付与成否）を 1 行記録（Req 3.5）
#
#   内部処理:
#     1. sec_already_processed "$pr_number" "$sha" "security-block" で重複判定
#        → 既存なら sec_log で skip 通知して return 0（Req 3.6, NFR 4.1）
#     2. gh pr edit --add-label "$SECURITY_REVIEW_BLOCK_LABEL,needs-iteration" で 1 コマンド
#        原子付与（PR Iteration Processor 動線に流す / Req 3.1, 4.4）
#     3. 失敗時は sec_warn + return 1（既存 fail-continue 規約。コメント投稿側を阻害しない）
#     4. 成功時は hidden marker (kind=security-block) のコメントを 1 件投稿
#        （以降の重複防止 + 監査）
#     5. ラベル付与結果を sec_log で 1 行記録（Req 3.5 / NFR 3.1）
#
#   エラーハンドリング:
#     - ラベル付与失敗 → WARN + return 1（次サイクルで再試行可 / コメント投稿側を阻害しない）
#     - ラベル付与成功 + marker 投稿失敗 → WARN + return 1。次サイクルで marker 不在の
#       ため再判定されるが、`gh pr edit --add-label` は同一ラベルの重複付与に対して冪等
#       なため、再付与が走っても副作用は発生しない（design.md L589 のとおり）。
# ─────────────────────────────────────────────────────────────────────────────
sec_apply_block_labels() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local blocking_count="${3:-0}"
  local threshold="${4:-}"

  # AC 3.6 / NFR 4.1: 同一 (sha, kind=security-block) が既存なら再付与しない
  if sec_already_processed "$pr_number" "$sha" "security-block"; then
    sec_log "PR #${pr_number}: sha=${sha} は既に strict ラベル付与済み（kind=security-block marker 検出）。skip"
    return 0
  fi

  # ラベル 2 枚を 1 コマンドで原子付与（Req 3.1, 4.4）
  if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" \
      --add-label "${SECURITY_REVIEW_BLOCK_LABEL},needs-iteration" >/dev/null 2>&1; then
    sec_warn "PR #${pr_number}: strict ラベル付与に失敗 labels=${SECURITY_REVIEW_BLOCK_LABEL}+needs-iteration blocking=${blocking_count} threshold=${threshold} sha=${sha}"
    return 1
  fi

  # 重複防止 marker コメントを 1 件投稿（NFR 4.1, 4.2 / 監査用途）
  local marker body
  marker=$(sec_build_marker "$sha" "security-block")
  # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
  body=$(printf '<!-- security-block marker for SHA %s -->\nstrict モードによりマージ阻害ラベル `%s` / `needs-iteration` を付与しました（blocking=%s threshold=%s）。\n\n%s' \
    "$sha" "$SECURITY_REVIEW_BLOCK_LABEL" "$blocking_count" "$threshold" "$marker")

  if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    sec_warn "PR #${pr_number}: strict ラベル付与は成功したが kind=security-block marker コメント投稿に失敗 sha=${sha}（次サイクルで再付与＝gh pr edit --add-label の冪等性により副作用なし）"
    return 1
  fi

  sec_log "PR #${pr_number}: strict ラベル付与成功 labels=${SECURITY_REVIEW_BLOCK_LABEL}+needs-iteration blocking=${blocking_count} threshold=${threshold} sha=${sha}"
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

# ─────────────────────────────────────────────────────────────────────────────
# sec_build_prompt_file: スキャン prompt を解決し一時ファイルに書き出す（task 3.4）
#   入力: $1 = pr_number, $2 = base_ref, $3 = head_ref
#   出力: stdout に一時ファイルパス（呼び出し元が trap で削除）
#   戻り値: 0 = ok / 1 = mktemp 失敗
#   AC: 2.2
#
#   - 解決順序: SECURITY_REVIEW_PROMPT を採用（design.md「CLI 起動契約」節の既定値が
#     env で吸収される）。
#   - 解決済み prompt 中の {BASE} / {HEAD} / {PR} を bash パラメータ置換でリテラル置換。
#   - 一時ファイルは {PROMPT_FILE} 置換経路で argv へ渡される。design.md の既定
#     SECURITY_REVIEW_CLAUDE_CMD は `claude -p "$SECURITY_REVIEW_PROMPT" ...` の形で
#     env 展開を期待するため、呼び出し元 sec_run_review_for_pr は SECURITY_REVIEW_PROMPT
#     を bash -c のサブシェル env として上書きして渡す（後述 sec_run_review_for_pr 参照）。
#     SECURITY_REVIEW_CLAUDE_CMD を運用者が override して {PROMPT_FILE} 経路を使うことも可。
#   - stdout にファイルパスを返す契約のため、本関数内では sec_log を使わず
#     sec_warn（stderr）のみ使用する（stdout 汚染防止）。
# ─────────────────────────────────────────────────────────────────────────────
sec_build_prompt_file() {
  local pr_number="$1"
  local base_ref="$2"
  local head_ref="$3"

  local prompt="${SECURITY_REVIEW_PROMPT:-}"
  if [ -z "$prompt" ]; then
    sec_warn "PR #${pr_number}: SECURITY_REVIEW_PROMPT が空です（Config ブロック既定値が未配線の可能性）"
    return 1
  fi

  prompt="${prompt//\{BASE\}/$base_ref}"
  prompt="${prompt//\{HEAD\}/$head_ref}"
  prompt="${prompt//\{PR\}/$pr_number}"

  local tmpfile
  if ! tmpfile=$(mktemp -t idd-claude-security-review.XXXXXX 2>/dev/null); then
    sec_warn "PR #${pr_number}: prompt 一時ファイルの作成に失敗"
    return 1
  fi
  printf '%s\n' "$prompt" > "$tmpfile"
  printf '%s' "$tmpfile"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_substitute_placeholders: 実行コマンドのプレースホルダ置換（task 3.4）
#   入力: $1 = cmd_template, $2 = base_ref, $3 = head_ref, $4 = pr_number,
#         $5 = prompt_file_path
#   出力: stdout に置換済みコマンド文字列
#   戻り値: 0 = ok / 1 = metachar 検出（呼び出し元は当該 PR を skip）
#   AC: 2.2（Security Considerations: shell metacharacter 防御）
#
#   - 置換対象: {BASE} / {HEAD} / {PR} / {PROMPT_FILE}
#   - 注入値（GitHub 由来の branch 名 / PR 番号）に shell metacharacter
#     （`;` `|` `&` `` ` `` `$(`）が混入していないか検査し、検出時は WARN + skip
#     （GitHub branch 命名規約では発生しないが防御的設計 / Security Considerations）。
#   - prompt_file_path は mktemp 由来の自前パスのため検査対象外。cmd_template は
#     運用者入力（信頼境界内）かつ正当な `$VAR` 展開や `$(cat '...')` を含むため検査しない。
#   - stdout に結果を返す契約のため sec_log は使わず sec_warn（stderr）のみ使用。
# ─────────────────────────────────────────────────────────────────────────────
sec_substitute_placeholders() {
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
        sec_warn "placeholder 値に shell metacharacter を検出（base='${base_ref}' head='${head_ref}' pr='${pr_number}'）。当該 PR を skip します"
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
# sec_execute_security_review: head checkout + スキャン実行 + read-only 検査（task 3.1）
#   入力: $1 = head_ref, $2 = resolved_cmd, $3 = out_file, $4 = err_file, $5 = result_file
#   出力: out_file へ stdout、err_file へ stderr、result_file へ実行結果トークン
#   戻り値: 0 固定（結果判定は result_file 経由）
#   AC: 2.2, 2.6, NFR 4.1
#
#   result_file に書き出すトークン（呼び出し元が parse）:
#     - `fetch-fail`         : git fetch 失敗（一時的 / コメント投稿しない）
#     - `checkout-fail`      : git checkout 失敗（同上）
#     - `ran:<rc>:clean`     : 実行完了、ワークツリー変更なし（rc=コマンド終了コード）
#     - `ran:<rc>:modified`  : 実行完了したがワークツリーを変更（read-only 違反）
#
#   - サブシェル + EXIT trap で必ず BASE_BRANCH に戻す（副作用を残さない invariant）。
#   - `eval` は使わず `bash -c "$resolved_cmd"` で subshell に閉じ込める
#     （Security Considerations / pr_execute_review_command と同方針）。
#   - 実行直後に `git status --porcelain` でワークツリー変更を検査し、検出時は
#     `git checkout -- .` で tracked 変更を破棄し `modified` を報告
#     （design.md Security Considerations の read-only invariant）。
#   - 既存 pr_execute_review_command との差分: tool 引数を持たない（単一実行ツール
#     claude のみ）、SECURITY_REVIEW_* タイムアウト env を参照する点のみ。
#   - SECURITY_REVIEW_PROMPT は parent shell の env に解決済み（Config ブロックで
#     ${VAR:-default} 展開）であるため、bash -c "$resolved_cmd" の subshell から
#     `$SECURITY_REVIEW_PROMPT` として参照可能（design.md「CLI 起動契約」節）。
# ─────────────────────────────────────────────────────────────────────────────
sec_execute_security_review() {
  local head_ref="$1"
  local resolved_cmd="$2"
  local out_file="$3"
  local err_file="$4"
  local result_file="$5"

  : > "$out_file"
  : > "$err_file"
  : > "$result_file"

  (
    set +e
    # shellcheck disable=SC2064
    trap "git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # head branch を fresh に checkout（origin 最新へ追従、AC 2.2）
    if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" git fetch origin "$head_ref" >/dev/null 2>&1; then
      sec_warn "head '${head_ref}' の git fetch に失敗"
      printf 'fetch-fail\n' > "$result_file"
      exit 0
    fi
    if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      sec_warn "head '${head_ref}' の checkout に失敗"
      printf 'checkout-fail\n' > "$result_file"
      exit 0
    fi

    # スキャン実行（eval 不使用 / SECURITY_REVIEW_PROMPT は parent env から継承）
    local exec_rc=0
    timeout "$SECURITY_REVIEW_EXEC_TIMEOUT" bash -c "$resolved_cmd" >"$out_file" 2>"$err_file" || exec_rc=$?

    # read-only invariant 検査（design.md Security Considerations）。untracked は
    # `git clean` で消すと `.antigravitycli/` 等の運用ツール生成物を巻き込むため
    # tracked 変更のみ破棄する（pr_execute_review_command と同方針）。
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
# sec_post_review_comment: スキャン結果コメントを投稿（task 3.2）
#   入力: $1 = pr_number, $2 = sha, $3 = review_text
#   戻り値: 0 = ok / 1 = 投稿失敗
#   AC: 3.1, 3.2, 3.4, 6.1, 6.4
#
#   - 冒頭に `## セキュリティレビュー結果` 見出し + review_text 本文、末尾に
#     hidden marker（kind=security-review）を付与し gh pr comment で投稿。
#   - 投稿失敗時は WARN + rc=1（呼び出し元の集計対象）。
# ─────────────────────────────────────────────────────────────────────────────
sec_post_review_comment() {
  local pr_number="$1"
  local sha="$2"
  local review_text="$3"

  local marker body
  marker=$(sec_build_marker "$sha" "security-review")
  body=$(printf '## セキュリティレビュー結果\n\n%s\n\n%s' "$review_text" "$marker")

  if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    sec_warn "PR #${pr_number}: セキュリティレビュー結果コメントの投稿に失敗"
    return 1
  fi
  sec_log "PR #${pr_number}: セキュリティレビュー結果コメント投稿 kind=security-review sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_post_clean_comment: クリーンである旨のコメントを投稿（task 3.2）
#   入力: $1 = pr_number, $2 = sha
#   戻り値: 0 = ok / 1 = 投稿失敗
#   AC: 3.3, 3.4, 6.1, 6.4
#
#   - 冒頭に `## セキュリティレビュー結果: クリーン` 見出し + 検出 0 件である旨を
#     1〜2 行で記載し、末尾に hidden marker（kind=security-review-clean）を付与。
#   - モデル名 / skill 名を本文に含めて運用者が判断材料を得られるようにする（Req 3.3）。
# ─────────────────────────────────────────────────────────────────────────────
sec_post_clean_comment() {
  local pr_number="$1"
  local sha="$2"

  local marker body
  marker=$(sec_build_marker "$sha" "security-review-clean")
  body=$(printf '## セキュリティレビュー結果: クリーン\n\n検出項目はありません（0 件）。\n\n- Model: %s\n- Skill: /security-review\n\n%s' \
    "${SECURITY_REVIEW_MODEL:-unknown}" "$marker")

  if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    sec_warn "PR #${pr_number}: クリーン通知コメントの投稿に失敗"
    return 1
  fi
  sec_log "PR #${pr_number}: クリーン通知コメント投稿 kind=security-review-clean sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_post_error_comment: エラーコメントを投稿（task 3.2）
#   入力: $1 = pr_number, $2 = sha, $3 = kind, $4 = detail
#   戻り値: 0 = ok（重複 skip 含む）/ 1 = 投稿失敗
#   AC: 2.6, 6.1, 6.2, 6.4
#
#   - 本文冒頭に `## セキュリティレビュー結果（実行エラー）` 見出し（Req 3.2 と同方針）。
#   - 同一 (sha, kind) marker が既存なら再投稿しない（AC 6.2、冪等 NFR 4.1）。
#   - 本 spec で実際に使用する kind は `scan-failed` のみ（design.md State / Marker
#     Contract）だが、将来の拡張に備え kind 引数として渡せる形を保つ。
# ─────────────────────────────────────────────────────────────────────────────
sec_post_error_comment() {
  local pr_number="$1"
  local sha="$2"
  local kind="$3"
  local detail="$4"

  # AC 6.2 / NFR 4.1: 同一 (sha, kind) が既存なら再投稿しない
  if sec_already_processed "$pr_number" "$sha" "$kind"; then
    sec_log "PR #${pr_number}: kind=${kind} sha=${sha} のエラーコメントは既存のため再投稿しません（重複防止）"
    return 0
  fi

  local marker body
  marker=$(sec_build_marker "$sha" "$kind")
  body=$(printf '## セキュリティレビュー結果（実行エラー）\n\n%s\n\n%s' "$detail" "$marker")

  if ! timeout "$SECURITY_REVIEW_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    sec_warn "PR #${pr_number}: エラーコメント (kind=${kind}) の投稿に失敗"
    return 1
  fi
  sec_log "PR #${pr_number}: エラーコメント投稿 kind=${kind} sha=${sha}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_count_severities: review_text から severity 別件数を集計（内部 helper / task 3.3）
#   入力: $1 = review_text
#   出力: stdout に "critical=N high=N medium=N low=N info=N total=N" の 1 行
#
#   - 単純な行スキャンで severity トークン（critical/high/medium/low/info、
#     大文字小文字無視）を持つ行をカウントする近似実装（完全パースは不要 / 起動指示書に従う）。
#   - 0 件時は全 0、total は critical+high+medium+low+info の合算。
# ─────────────────────────────────────────────────────────────────────────────
sec_count_severities() {
  local review_text="$1"

  local crit high med low info
  crit=$(printf '%s' "$review_text" | grep -E -i -c '\bcritical\b' 2>/dev/null || true)
  high=$(printf '%s' "$review_text" | grep -E -i -c '\bhigh\b' 2>/dev/null || true)
  med=$(printf '%s'  "$review_text" | grep -E -i -c '\bmedium\b' 2>/dev/null || true)
  low=$(printf '%s'  "$review_text" | grep -E -i -c '\blow\b' 2>/dev/null || true)
  info=$(printf '%s' "$review_text" | grep -E -i -c '\binfo\b' 2>/dev/null || true)
  crit="${crit:-0}"; high="${high:-0}"; med="${med:-0}"; low="${low:-0}"; info="${info:-0}"
  local total=$((crit + high + med + low + info))
  printf 'critical=%s high=%s medium=%s low=%s info=%s total=%s' \
    "$crit" "$high" "$med" "$low" "$info" "$total"
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_write_security_notes: security-notes.md を spec ディレクトリ配下に書き出す（task 3.3）
#   入力: $1 = pr_number, $2 = sha, $3 = spec_dir, $4 = finding_count,
#         $5 = severity_summary (sec_count_severities の出力形式), $6 = review_text
#   戻り値: 0 = ok（spec_dir 不明時の skip 含む）/ 1 = 書き出し失敗
#   AC: 3.5, NFR 4.1
#
#   - spec_dir 空文字 / ディレクトリ不在 → WARN 1 行 + return 0（書き出し skip / 安全側）
#   - 既存ファイルの先頭付近に同一 `Last SHA: <sha>` 行があれば overwrite skip（idempotency）
#   - フォーマット: design.md「security-notes.md フォーマット」節のテンプレ厳守
# ─────────────────────────────────────────────────────────────────────────────
sec_write_security_notes() {
  local pr_number="$1"
  local sha="$2"
  local spec_dir="$3"
  local finding_count="$4"
  local severity_summary="$5"
  local review_text="$6"

  # AC 3.5 / Error handling: spec_dir 不明 → skip 安全側（PR コメント側は阻害しない）
  if [ -z "$spec_dir" ] || [ ! -d "$spec_dir" ]; then
    sec_warn "PR #${pr_number}: spec ディレクトリが特定できないため security-notes.md の書き出しを skip"
    return 0
  fi

  local notes_path="${spec_dir}/security-notes.md"

  # idempotency: 既存ファイルの先頭付近に同一 SHA があれば overwrite skip（NFR 4.1）
  if [ -f "$notes_path" ] && head -n 20 "$notes_path" 2>/dev/null | grep -qF "Last SHA: ${sha}"; then
    sec_log "PR #${pr_number}: security-notes.md は同一 SHA で既に書き出し済み（idempotent skip）path=${notes_path}"
    return 0
  fi

  # severity_summary から各カウントを抽出（"critical=N high=N ..." 形式）
  local crit high med low info
  crit=$(printf '%s' "$severity_summary"  | sed -n 's/.*critical=\([0-9][0-9]*\).*/\1/p')
  high=$(printf '%s' "$severity_summary"  | sed -n 's/.*high=\([0-9][0-9]*\).*/\1/p')
  med=$(printf '%s'  "$severity_summary"  | sed -n 's/.*medium=\([0-9][0-9]*\).*/\1/p')
  low=$(printf '%s'  "$severity_summary"  | sed -n 's/.*low=\([0-9][0-9]*\).*/\1/p')
  info=$(printf '%s' "$severity_summary"  | sed -n 's/.*info=\([0-9][0-9]*\).*/\1/p')
  crit="${crit:-0}"; high="${high:-0}"; med="${med:-0}"; low="${low:-0}"; info="${info:-0}"

  local last_run
  last_run=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

  local model="${SECURITY_REVIEW_MODEL:-unknown}"

  # 一時ファイル経由で原子的に置換（書き出し途中の状態を残さない）
  local tmp_notes
  if ! tmp_notes=$(mktemp -t idd-claude-security-notes.XXXXXX 2>/dev/null); then
    sec_warn "PR #${pr_number}: security-notes.md 一時ファイルの作成に失敗"
    return 1
  fi

  {
    printf '# Security Review Notes\n\n'
    printf '<!-- idd-claude:security-notes pr=%s sha=%s -->\n\n' "$pr_number" "$sha"
    printf -- '- Last SHA: %s\n' "$sha"
    printf -- '- Last Run: %s\n' "$last_run"
    printf -- '- Model: %s\n' "$model"
    printf -- '- Skill: /security-review\n'
    printf -- '- Finding Count: %s\n\n' "$finding_count"
    printf '## Severity Summary\n\n'
    printf '| Severity | Count |\n'
    printf '|---|---|\n'
    printf '| Critical | %s |\n' "$crit"
    printf '| High | %s |\n' "$high"
    printf '| Medium | %s |\n' "$med"
    printf '| Low | %s |\n' "$low"
    printf '| Info | %s |\n\n' "$info"
    printf '## Findings\n\n'
    if [ "$finding_count" = "0" ]; then
      printf 'クリーン: スキャンで検出項目はありませんでした。\n'
    else
      printf '%s\n' "$review_text"
    fi
  } > "$tmp_notes"

  if ! mv "$tmp_notes" "$notes_path" 2>/dev/null; then
    sec_warn "PR #${pr_number}: security-notes.md の書き出しに失敗 path=${notes_path}"
    rm -f "$tmp_notes" 2>/dev/null || true
    return 1
  fi

  sec_log "PR #${pr_number}: security-notes.md 書き出し成功 findings=${finding_count} path=${notes_path}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# sec_run_review_for_pr: 1 PR 分のスキャンを統括（task 3.4）
#   入力: $1 = pr_json（sec_fetch_candidate_prs の単一要素）
#   戻り値: 0 = success / 1 = failure（一時的・skip 相当）/ 2 = skip（重複検出）/
#           3 = scan-error（実行失敗 / workspace-modified / 空出力）
#   AC: 2.2, 2.4, 2.6, 3.1, 3.2, 3.3, 3.4, 3.5, 6.1〜6.4
#
#   フロー:
#     1. pr_json から各フィールド抽出
#     2. (sha, kind=security-review) / (sha, kind=security-review-clean) のいずれかの
#        marker が既存なら rc=2 skip（NFR 4.1 冪等性）
#     3. prompt tempfile 生成 + cmd template 置換（metachar 検査）
#     4. sec_execute_security_review 呼び出し
#     5. 結果トークン分岐:
#        - fetch-fail / checkout-fail → WARN + return 1（コメント投稿しない）
#        - ran:*:modified           → kind=scan-failed エラーコメント + rc=3
#        - ran:<rc!=0>:clean        → stderr 1KB 抜粋付きエラーコメント + rc=3
#        - ran:0:clean              → 出力解析へ
#     6. 出力末尾に SECURITY_REVIEW_CLEAN センチネル行
#        → sec_post_clean_comment + sec_write_security_notes（件数 0）
#     7. センチネル不在 + 出力非空
#        → sec_post_review_comment + sec_write_security_notes（実件数）
#     8. 出力空 → kind=scan-failed エラーコメント + rc=3
#     9. spec ディレクトリ解決は sec_resolve_spec_dir 経由（特定不可なら notes 書き出し
#        skip / PR コメントは通常投稿）
# ─────────────────────────────────────────────────────────────────────────────
sec_run_review_for_pr() {
  local pr_json="$1"

  local pr_number head_ref base_ref sha pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  sha=$(echo "$pr_json"       | jq -r '.headRefOid')
  pr_url=$(echo "$pr_json"    | jq -r '.url')

  if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
    base_ref="$BASE_BRANCH"
  fi

  # AC 2.4 / 6.2 / NFR 4.1: 同一 (sha, kind=security-review|security-review-clean) が
  # 既存なら重複スキャン / 重複コメントを行わない（kind 2 値どちらでも skip 扱い）
  if sec_already_processed "$pr_number" "$sha" "security-review"; then
    sec_log "PR #${pr_number}: sha=${sha} は既にスキャン済み（kind=security-review marker 検出）。skip"
    return 2
  fi
  if sec_already_processed "$pr_number" "$sha" "security-review-clean"; then
    sec_log "PR #${pr_number}: sha=${sha} は既にクリーン通知済み（kind=security-review-clean marker 検出）。skip"
    return 2
  fi

  sec_log "PR #${pr_number}: スキャン着手 head=${head_ref} base=${base_ref} sha=${sha} (${pr_url})"

  # prompt tempfile + 実行結果受け渡し tempfile を親で生成し、RETURN trap で確実に削除。
  local prompt_file out_file err_file result_file
  if ! prompt_file=$(sec_build_prompt_file "$pr_number" "$base_ref" "$head_ref"); then
    sec_warn "PR #${pr_number}: prompt 生成に失敗、skip"
    return 1
  fi
  out_file=$(mktemp -t idd-claude-security-review-out.XXXXXX 2>/dev/null || mktemp)
  err_file=$(mktemp -t idd-claude-security-review-err.XXXXXX 2>/dev/null || mktemp)
  result_file=$(mktemp -t idd-claude-security-review-res.XXXXXX 2>/dev/null || mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '${prompt_file}' '${out_file}' '${err_file}' '${result_file}'" RETURN

  # プレースホルダ置換（{BASE}/{HEAD}/{PR}/{PROMPT_FILE}）+ metachar 検査
  local cmd_template="${SECURITY_REVIEW_CLAUDE_CMD}"
  local resolved_cmd
  if ! resolved_cmd=$(sec_substitute_placeholders "$cmd_template" "$base_ref" "$head_ref" "$pr_number" "$prompt_file"); then
    return 1
  fi

  # スキャン実行（git checkout は subshell 内 / trap で BASE_BRANCH 復帰、AC 2.2）
  sec_execute_security_review "$head_ref" "$resolved_cmd" "$out_file" "$err_file" "$result_file"

  local result
  result=$(cat "$result_file" 2>/dev/null || echo "")

  case "$result" in
    fetch-fail|checkout-fail)
      sec_warn "PR #${pr_number}: head '${head_ref}' の取得に失敗 (${result})、当該 PR を skip"
      return 1
      ;;
  esac

  local exec_rc wsmod
  exec_rc=$(printf '%s' "$result" | awk -F: '{print $2}')
  wsmod=$(printf '%s'  "$result" | awk -F: '{print $3}')
  exec_rc="${exec_rc:-1}"

  # spec ディレクトリ解決（PR head ブランチ名から、特定不可なら空文字 = notes skip）
  local spec_dir
  spec_dir=$(sec_resolve_spec_dir "$head_ref")

  # read-only invariant 違反 → workspace-modified エラーコメント、scan-error
  if [ "$wsmod" = "modified" ]; then
    sec_error "PR #${pr_number}: スキャン実行がワークツリーを変更しました（read-only invariant 違反）。tracked 変更を破棄し scan-failed を報告"
    sec_post_error_comment "$pr_number" "$sha" "scan-failed" \
      "セキュリティレビュー実行がワークツリーを変更しました（read-only invariant 違反）。tracked 変更は破棄しました。\`SECURITY_REVIEW_CLAUDE_CMD\` の \`--permission-mode plan\` 指定および prompt を確認してください。"
    return 3
  fi

  # 実行失敗（非ゼロ終了）→ scan-failed エラーコメント（stderr 1KB 抜粋付き）
  if [ "$exec_rc" -ne 0 ]; then
    local err_excerpt detail
    err_excerpt=$(head -c 1024 "$err_file" 2>/dev/null || echo "")
    sec_error "PR #${pr_number}: スキャン実行コマンドが非ゼロ終了 (exit=${exec_rc})"
    # shellcheck disable=SC2016  # 単一引用符内のバッククォートは markdown コードフェンスのリテラル
    detail=$(printf 'セキュリティレビュー実行コマンドが非ゼロ終了しました（exit=%s）。\n\n```\n%s\n```' \
      "$exec_rc" "$err_excerpt")
    sec_post_error_comment "$pr_number" "$sha" "scan-failed" "$detail"
    return 3
  fi

  # 成功: stdout をスキャン結果として収集
  local review_text
  review_text=$(cat "$out_file" 2>/dev/null || echo "")

  if [ -z "$review_text" ]; then
    sec_warn "PR #${pr_number}: スキャン結果が空。scan-failed として扱う"
    sec_post_error_comment "$pr_number" "$sha" "scan-failed" \
      "セキュリティレビュー実行は成功しましたが出力が空でした。Skill tool 経由の \`/security-review\` 起動が失敗した可能性があります。\`claude\` バージョン / \`SECURITY_REVIEW_CLAUDE_CMD\` / \`SECURITY_REVIEW_PROMPT\` を確認してください。"
    return 3
  fi

  # SECURITY_REVIEW_CLEAN センチネル検出 → クリーン判定
  if printf '%s' "$review_text" | grep -qE '^[[:space:]]*SECURITY_REVIEW_CLEAN[[:space:]]*$'; then
    sec_log "PR #${pr_number}: SECURITY_REVIEW_CLEAN センチネル検出 → クリーン判定（検出 0 件）"
    if ! sec_post_clean_comment "$pr_number" "$sha"; then
      return 1
    fi
    local zero_summary
    zero_summary='critical=0 high=0 medium=0 low=0 info=0 total=0'
    sec_write_security_notes "$pr_number" "$sha" "$spec_dir" "0" "$zero_summary" "$review_text" || true
    return 0
  fi

  # 検出 ≥ 1 件と判定 → severity 集計 + コメント投稿 + notes 書き出し
  local severity_summary total_findings
  severity_summary=$(sec_count_severities "$review_text")
  total_findings=$(printf '%s' "$severity_summary" | sed -n 's/.*total=\([0-9][0-9]*\).*/\1/p')
  total_findings="${total_findings:-0}"

  sec_log "PR #${pr_number}: 検出 ${total_findings} 件 (${severity_summary})"

  if ! sec_post_review_comment "$pr_number" "$sha" "$review_text"; then
    return 1
  fi

  sec_write_security_notes "$pr_number" "$sha" "$spec_dir" "$total_findings" "$severity_summary" "$review_text" || true

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_security_review: dispatcher から呼ばれるエントリ関数（task 4.1）
#   入力: なし（env var 群を読む）
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しないため / dispatcher fail-continue 契約）
#   AC: 1.1, 1.2, 1.3, 1.4, 2.1, 2.5, 5.1, 5.2, 5.3, NFR 1.1, NFR 3.1
#
#   処理順:
#     ① opt-in gate（SECURITY_REVIEW_ENABLED=true 厳密一致のみ。それ以外は早期 return）
#        AC 1.1 / 1.4 / NFR 1.1
#     ② sec_check_strict_request を呼び advisory 固定値を取得（strict 要求検出時の WARN 含む）
#        AC 5.1 / 5.2 / 5.3
#     ③ サイクル開始の 1 行サマリログ（mode / max_prs / timeouts / head_pattern / model）
#        AC 5.2 / NFR 3.1
#     ④ 候補 PR 列挙（AC 2.1 / 2.3）
#     ⑤ 候補 0 件 → サマリログのみで return
#     ⑥ MAX_PRS で truncate（total / target / overflow をログ、AC 2.5 / NFR 3.1）
#     ⑦ レビュー loop（sec_run_review_for_pr）→ rc 集計 → サマリログ
#     ⑧ 最後に保険で BASE_BRANCH に戻して return 0（dispatcher fail-continue）
# ─────────────────────────────────────────────────────────────────────────────
process_security_review() {
  # ① AC 1.1 / 1.4 / NFR 1.1: opt-in gate（=true 厳密一致のみ有効。それ以外は全て OFF）
  if [ "${SECURITY_REVIEW_ENABLED:-false}" != "true" ]; then
    return 0
  fi

  # ② AC 5.1 / 5.2 / 5.3: strict 要求 env を検査（WARN 後 advisory 固定で続行）
  local mode
  mode=$(sec_check_strict_request)

  # ③ AC 5.2 / NFR 3.1: サイクル開始の 1 行サマリログ
  sec_log "cycle start: mode=${mode} strict=not-implemented (split to #281) max_prs=${SECURITY_REVIEW_MAX_PRS:-unset} git_timeout=${SECURITY_REVIEW_GIT_TIMEOUT:-unset}s exec_timeout=${SECURITY_REVIEW_EXEC_TIMEOUT:-unset}s head_pattern=${SECURITY_REVIEW_HEAD_PATTERN:-unset} model=${SECURITY_REVIEW_MODEL:-unset}"

  # ④ 候補 PR 列挙（AC 2.1 / 2.3）
  local prs_json total
  prs_json=$(sec_fetch_candidate_prs)
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)

  # ⑤ 候補 0 件 → サマリログのみで return
  if [ "$total" -eq 0 ]; then
    sec_log "サマリ: mode=${mode} reviewed=0 clean=0 skip=0 fail=0 errored=0 overflow=0 notes_written=0 notes_skipped=0（候補 PR なし）"
    return 0
  fi

  # ⑥ AC 2.5 / NFR 3.1: MAX_PRS で truncate（total / target / overflow をログ）
  local max_prs="${SECURITY_REVIEW_MAX_PRS:-5}"
  local target_count="$total" skipped_overflow=0
  if [ "$total" -gt "$max_prs" ]; then
    target_count="$max_prs"
    skipped_overflow=$((total - max_prs))
    sec_log "対象候補 ${total} 件中、上限 ${max_prs} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    sec_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  # ⑦ レビュー loop
  local reviewed=0 clean=0 skip=0 fail=0 errored=0
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$pr_iter" ]; then
    sec_log "サマリ: mode=${mode} reviewed=0 clean=0 skip=0 fail=0 errored=0 overflow=${skipped_overflow} notes_written=0 notes_skipped=0（iterate 対象なし）"
    return 0
  fi

  while IFS= read -r pr_json; do
    [ -z "$pr_json" ] && continue
    local rc=0
    sec_run_review_for_pr "$pr_json" || rc=$?
    # rc 値の意味:
    #   0 = success（検出件数で reviewed / clean を区別するが、本 entrypoint では
    #       run_review 関数の戻り値分解はせず合算で reviewed として扱う。clean の
    #       内訳は sec_post_clean_comment ログから事後集計可能）
    #   1 = failure（一時的・skip 相当）
    #   2 = skip（重複検出 marker）
    #   3 = scan-error（実行失敗 / workspace-modified / 空出力）
    case $rc in
      0) reviewed=$((reviewed + 1)) ;;
      2) skip=$((skip + 1)) ;;
      3) errored=$((errored + 1)) ;;
      *) fail=$((fail + 1)) ;;
    esac
    # 各 PR 処理後に保険で base branch に戻す（スキャンは subshell 内で完結するが念のため）
    git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  done <<< "$pr_iter"

  # 本 entrypoint では clean の内訳は集計しない（sec_run_review_for_pr は 0/1/2/3 を
  # 返すのみ。clean / non-clean の区別は marker kind = security-review-clean /
  # security-review のログ行で事後識別する）。notes_written / notes_skipped も
  # sec_write_security_notes のログ行で事後集計可能。本サマリは合算値のみを記録する。
  sec_log "サマリ: mode=${mode} reviewed=${reviewed} clean=${clean} skip=${skip} fail=${fail} errored=${errored} overflow=${skipped_overflow} notes_written=0 notes_skipped=0"

  # 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
  return 0
}
