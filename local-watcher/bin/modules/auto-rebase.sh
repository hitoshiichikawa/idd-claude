#!/usr/bin/env bash
# auto-rebase.sh — watcher の Auto Rebase 制御プロセッサモジュール
#
# 用途:
#   issue-watcher.sh から切り出した、コンフリクトした approved PR の自動 Rebase
#   プロセッサ（Phase D / #17）を集約する。
#   `needs-rebase` + approved な open PR を Claude 経由で rebase し、変更ファイルが
#   MECHANICAL_PATHS allowlist に閉じている場合は approve を維持して auto-merge に到達
#   させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving review を
#   review dismissal API で剥がし、`ready-for-review` に戻して再レビューを誘導する。
#   `AUTO_REBASE_MODE=claude` を明示したリポジトリでのみ起動し、未設定 / off / 不正値の
#   リポジトリは導入前と完全に同一の挙動を維持する（opt-in）。
#   - ar_fetch_candidates / ar_build_prompt / ar_run_claude_rebase / ar_classify_diff
#   - ar_apply_mechanical / ar_dismiss_all_approvals / ar_apply_semantic
#   - ar_escalate_to_failed / ar_handle_pr / process_auto_rebase
#
# 配置先:
#   $HOME/bin/modules/auto-rebase.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガー（ar_log / ar_warn / ar_error）は core_utils.sh にあるため再定義しない。
#   - グローバル変数（$AUTO_REBASE_MODE / $AUTO_REBASE_GIT_TIMEOUT / allowlist 設定 /
#     $LABEL_NEEDS_REBASE / $LABEL_FAILED / $BASE_BRANCH 等）は本体冒頭の Config ブロックで
#     定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh / git / claude / jq。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase D: Auto Rebase Processor (#17)
#   `needs-rebase` + approved な open PR を Claude 経由で rebase し、変更ファイルが
#   `MECHANICAL_PATHS` allowlist に閉じている場合は approve を維持して auto-merge
#   に到達させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving
#   review を review dismissal API で剥がし、`ready-for-review` に戻して再レビュー
#   を誘導する。新規 opt-in 機能。`AUTO_REBASE_MODE=claude` を明示したリポジトリ
#   でのみ起動し、未設定 / `off` / 不正値のリポジトリは導入前と完全に同一の挙動を
#   維持する（Req 1.1, 1.3, NFR 1.1）。
#
#   既存 Phase A 系列との競合排除（Req 3.1〜3.3）は、Re-check（先行）→ Phase A 本体
#   → Phase D の直列順序により構造的に保証される（design.md「順序根拠」参照）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─────────────────────────────────────────────────────────────────────────────
# ar_fetch_candidates: server-side + client-side の二段フィルタで候補 PR を返す
#   出力: stdout に jq 配列形式の JSON 1 行（候補なしなら "[]"）
#   戻り値: 0 = 正常（候補ゼロ件含む）、1 = API エラー（呼び出し側で WARN）
#
#   Req 2.1: needs-rebase + 1 件以上 approving review + open
#   Req 2.2: claude-failed 付き除外（同じ PR の再試行を抑止 / Req 8.4）
#   Req 2.3: draft 除外
#   Req 2.4: fork PR 除外（head repo owner == base repo owner）
#   Req 2.5: head branch pattern 整合（既存 MERGE_QUEUE_HEAD_PATTERN を再利用）
# ─────────────────────────────────────────────────────────────────────────────
ar_fetch_candidates() {
  local repo_owner="${REPO%%/*}"
  local prs_json
  # Server-side filter（Phase A Re-check と同パターン）。
  if ! prs_json=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,labels,url,isDraft,reviewDecision,headRepositoryOwner,title,headRefOid \
      --limit 100 2>/dev/null); then
    ar_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 1
  fi

  # Client-side filter（server filter の保険 + head pattern + fork 除外）。
  #   - isDraft / reviewDecision の再確認
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]'
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_build_prompt: auto-rebase-prompt.tmpl のプレースホルダ展開
#   入力: $1=pr_number, $2=pr_title, $3=pr_url, $4=head_ref, $5=base_ref
#   出力: stdout に展開後の prompt 本文
#   戻り値: 0=成功、1=template が無い
#
#   Req 4.1: Claude rebase 試行に必要な PR コンテキストを 1 round で渡す
#   既存 pi_build_iteration_prompt の awk 置換方式を踏襲（単一行値のみ扱う）。
#   複数行値は不要なため、ENVIRON 経由の特殊扱いはしない（template が小さい）。
# ─────────────────────────────────────────────────────────────────────────────
ar_build_prompt() {
  local pr_number="$1"
  local pr_title="$2"
  local pr_url="$3"
  local head_ref="$4"
  local base_ref="$5"

  if [ ! -f "$AUTO_REBASE_TEMPLATE" ]; then
    ar_warn "template not found: $AUTO_REBASE_TEMPLATE"
    return 1
  fi

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v base_branch="$BASE_BRANCH" \
    '
    function repl(s, key, val,    out, idx) {
      out = ""
      while ((idx = index(s, key)) > 0) {
        out = out substr(s, 1, idx-1) val
        s = substr(s, idx + length(key))
      }
      return out s
    }
    {
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{BASE_BRANCH}}", base_branch)
      print line
    }
    ' "$AUTO_REBASE_TEMPLATE"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_run_claude_rebase: Claude CLI を 1 回起動して conflict 解消 rebase を試行し、
#   成功すれば force-with-lease push する。Phase A の mq_try_rebase_pr の (subshell
#   + trap) パターンを踏襲しつつ、rebase 実行を Claude に委ねる。
#
#   入力: $1=pr_number, $2=pr_title, $3=pr_url, $4=head_ref, $5=base_ref
#   出力 (stdout 1 行): 成功時 "<before_sha> <after_sha>"、失敗時 空文字
#   戻り値:
#     0 : rebase + push 成功
#     1 : Claude が conflict を解消できず終了（dirty 残置 / clean だが before==after）
#     2 : timeout（exit 124）
#     3 : push 失敗
#     4 : fetch / checkout 失敗
#     5 : rebase 不要（既に base が祖先、skip 候補）
#
#   Req 4.1, 4.2, 4.3, 4.5, 4.6, NFR 5.1, NFR 5.2, NFR 5.3
# ─────────────────────────────────────────────────────────────────────────────
ar_run_claude_rebase() {
  local pr_number="$1"
  local pr_title="$2"
  local pr_url="$3"
  local head_ref="$4"
  local base_ref="$5"

  # ログファイルは 1 PR ごとに分ける（タイムスタンプで一意化）
  local log_file
  log_file="${LOG_DIR}/auto-rebase-${pr_number}-$(date +%Y%m%d-%H%M%S).log"

  local result_file
  result_file=$(mktemp 2>/dev/null || echo "/tmp/ar-result-$$")

  (
    set +e
    # サブシェル終了時は必ず元の base branch checkout に戻す（NFR 5.2）
    # shellcheck disable=SC2064
    trap "git rebase --abort >/dev/null 2>&1; git checkout '${BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # Req 4.3 前提: base/head 両方を最新化（API 状態と一致させる）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git fetch origin "$head_ref" "$base_ref" >/dev/null 2>&1; then
      exit 4
    fi

    # head branch を origin に同期して checkout（既存ローカルあれば force リセット）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      exit 4
    fi

    # Req 4.2 前段: rebase 前 SHA を記録
    local before_sha
    before_sha=$(git rev-parse HEAD 2>/dev/null) || exit 4
    echo "before=${before_sha}" >>"$log_file"

    # 既に base が head の祖先なら rebase 不要（skip 候補）。Phase A 本体が拾える
    # ケースを Phase D で重複処理しないための短絡。
    if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
      # skip 用 sentinel として before==after を出力して exit 5
      printf '%s %s\n' "$before_sha" "$before_sha" >"$result_file"
      exit 5
    fi

    # Claude prompt を組み立て
    local prompt
    if ! prompt=$(ar_build_prompt "$pr_number" "$pr_title" "$pr_url" "$head_ref" "$base_ref"); then
      exit 4
    fi

    # Req 4.1 / NFR 5.1: Claude CLI を timeout 付きで起動。`--print` でバッチ実行、
    # `--permission-mode bypassPermissions` で rebase 中の git 操作を許可。
    # `--output-format stream-json` + `--verbose` で進捗を log ファイルに残す。
    timeout "$AUTO_REBASE_MAX_TURNS_SEC" \
      claude --print "$prompt" \
             --model "$AUTO_REBASE_MODEL" \
             --permission-mode bypassPermissions \
             --max-turns "$AUTO_REBASE_MAX_TURNS" \
             --output-format stream-json \
             --verbose \
        >>"$log_file" 2>&1
    local claude_rc=$?

    # Req 4.5: timeout (exit 124) 検知
    if [ "$claude_rc" -eq 124 ]; then
      git rebase --abort >/dev/null 2>&1 || true
      exit 2
    fi

    # Claude 終了後の working tree が dirty なら conflict 未解消（半端な状態）
    if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
      git rebase --abort >/dev/null 2>&1 || true
      exit 1
    fi

    # Req 4.2 後段: rebase 後 SHA を記録
    local after_sha
    after_sha=$(git rev-parse HEAD 2>/dev/null) || exit 1
    echo "after=${after_sha}" >>"$log_file"

    # before == after で base が head の祖先のままなら、Claude が rebase 実行を
    # サボった可能性。skip 扱いにして次サイクルに委ねる（保守的）。
    if [ "$before_sha" = "$after_sha" ]; then
      if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
        printf '%s %s\n' "$before_sha" "$after_sha" >"$result_file"
        exit 5
      fi
      # before==after だが base が祖先でない = rebase が走らなかった conflict
      exit 1
    fi

    # Req 4.6 / NFR 5.3: 安全な force push のみ使用（`--force` 単独は使わない）
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$head_ref" >>"$log_file" 2>&1; then
      exit 3
    fi

    printf '%s %s\n' "$before_sha" "$after_sha" >"$result_file"
    exit 0
  )
  local rc=$?

  # サブシェル外でも安全側に倒して base branch に戻す（NFR 5.2）
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true

  # 成功 / skip 時のみ stdout に SHA を出力（呼び出し側が parse する）
  case $rc in
    0|5)
      if [ -f "$result_file" ]; then
        cat "$result_file"
      fi
      ;;
  esac
  rm -f "$result_file" 2>/dev/null || true

  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_classify_diff: rebase 後 head と base 間の累積 diff の path 集合を
#   `MECHANICAL_PATHS` allowlist と照合し `mechanical` / `semantic` を判定。
#
#   入力: $1=pr_number, $2=base_ref, $3=head_ref
#   出力 (stdout):
#     1 行目: `mechanical` or `semantic`
#     2 行目: semantic の場合は最初の unmatched path（取得できれば）。mechanical
#             では 2 行目を出さない
#   戻り値: 0=正常、1=`git diff` 失敗（呼び出し側は保守的に `semantic` 扱い）
#
#   Req 5.1, 5.2, 5.3, 5.4, 5.5
# ─────────────────────────────────────────────────────────────────────────────
ar_classify_diff() {
  local pr_number="$1"
  local base_ref="$2"
  local head_ref="$3"

  # Req 5.4: MECHANICAL_PATHS が空なら全件 semantic（保守的判定）
  if [ -z "$MECHANICAL_PATHS" ]; then
    ar_log "PR #${pr_number}: classification=semantic (MECHANICAL_PATHS 未設定)"
    echo "semantic"
    return 0
  fi

  # 変更 path 一覧を取得（base..head の累積 diff）
  local diff_range="origin/${base_ref}..origin/${head_ref}"
  local changed_paths
  if ! changed_paths=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      git diff --name-only "$diff_range" 2>/dev/null); then
    # 取得失敗時も保守的に semantic
    ar_log "PR #${pr_number}: classification=semantic (git diff 失敗)"
    echo "semantic"
    return 1
  fi

  if [ -z "$changed_paths" ]; then
    # 変更ファイルゼロは想定外（呼び出し側で skip 判定済みだが、念のため semantic に倒す）
    ar_log "PR #${pr_number}: classification=semantic (変更ファイルなし、保守的扱い)"
    echo "semantic"
    return 0
  fi

  # MECHANICAL_PATHS をカンマ区切りで配列展開
  local -a patterns=()
  local IFS=','
  read -ra patterns <<< "$MECHANICAL_PATHS"
  IFS=$' \t\n'

  # 各 path について「いずれかの pattern に一致」を確認
  local path matched pattern first_unmatched=""
  local match_count=0
  while IFS= read -r path; do
    [ -z "$path" ] && continue
    matched=false
    for pattern in "${patterns[@]}"; do
      # 前後空白除去
      pattern="${pattern# }"
      pattern="${pattern% }"
      [ -z "$pattern" ] && continue
      # POSIX bash の path matching (`==` + glob)。
      # 右辺の変数 glob 比較は意図的なので SC2053 を局所無効化。
      # shellcheck disable=SC2053
      if [[ "$path" == $pattern ]]; then
        matched=true
        break
      fi
    done
    if [ "$matched" = "false" ]; then
      # Req 5.3: 1 件でも一致しない → 即 semantic（保守的判定）
      first_unmatched="$path"
      break
    fi
    match_count=$((match_count + 1))
  done <<< "$changed_paths"

  if [ -n "$first_unmatched" ]; then
    # Req 5.5: 判定結果と最初の unmatched path をログに含める
    ar_log "PR #${pr_number}: classification=semantic unmatch=${first_unmatched}"
    echo "semantic"
    echo "$first_unmatched"
    return 0
  fi

  # Req 5.2: 全 path 一致 → mechanical
  ar_log "PR #${pr_number}: classification=mechanical paths=${match_count}"
  echo "mechanical"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_mechanical: mechanical 判定後の副作用（needs-rebase 除去のみ）を実行。
#   approve への副作用なし（Req 6.1）、追加コメント投稿なし（Req 6.3）。設計意図は
#   「lockfile-only 等の機械的 rebase は人間 noise を最小化する」。
#
#   入力: $1=pr_number
#   戻り値: 0=成功、1=label 除去 API 失敗（呼び出し側で WARN）
#
#   Req 6.1, 6.2, 6.3, 6.4
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_mechanical() {
  local pr_number="$1"

  # Req 6.2: needs-rebase ラベルを除去（唯一の副作用）。
  # Phase A と同 timeout を適用。GitHub の `--remove-label` は対象ラベルが
  # 既に無い場合も成功扱いとなるため、冪等性が保たれる。
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-rebase ラベル除去に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_dismiss_all_approvals: PR の approving review を全件 review dismissal API
#   (`gh api -X PUT .../reviews/{id}/dismissals`) で dismiss する。
#   `gh pr review --request-changes` 形式の別レビュー投稿方式は使わない（Req 7.5）。
#
#   入力: $1=pr_number
#   戻り値: 0=全 approving review の dismissal が成功（または対象なし）、
#           1=1 件でも失敗（呼び出し側で escalate に流す）
#
#   Error Handling: dismissal API が 422 を返す場合（既に dismissed 等）は当該
#   review を skip して次の review へ進む（business logic エラーとして個別 skip）。
#   それ以外の non-zero は全体失敗扱い。
# ─────────────────────────────────────────────────────────────────────────────
ar_dismiss_all_approvals() {
  local pr_number="$1"

  # 1. PR の review 一覧を取得
  local reviews_json
  if ! reviews_json=$(timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    ar_warn "PR #${pr_number}: review 一覧の取得に失敗"
    return 1
  fi

  # 2. state == APPROVED の review id を抽出
  local approved_ids
  approved_ids=$(echo "$reviews_json" | jq -r '[.[] | select(.state == "APPROVED") | .id] | .[]' 2>/dev/null || true)
  if [ -z "$approved_ids" ]; then
    # 対象なし（既に全部 dismissed / 状態が異なる）。冪等的に成功扱い。
    ar_log "PR #${pr_number}: dismissal 対象の approving review なし（既に dismissed の可能性）"
    return 0
  fi

  # 3. 各 review id について dismissal API を呼ぶ
  local id rc=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    local stderr_file
    stderr_file=$(mktemp 2>/dev/null || echo "/tmp/ar-dismiss-stderr-$$")
    if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
        gh api -X PUT "/repos/${REPO}/pulls/${pr_number}/reviews/${id}/dismissals" \
        -f message="Phase D semantic rebase: re-review required" >/dev/null 2>"$stderr_file"; then
      # 422 (Unprocessable Entity) は既に dismissed の可能性が高い。skip 扱い。
      if grep -q "HTTP 422" "$stderr_file" 2>/dev/null; then
        ar_log "PR #${pr_number}: review id=${id} は既に dismissed の可能性 (HTTP 422、skip)"
      else
        ar_warn "PR #${pr_number}: review id=${id} の dismissal に失敗"
        rc=1
      fi
    fi
    rm -f "$stderr_file" 2>/dev/null || true
  done <<< "$approved_ids"

  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_enabled: Issue #366 D-12 Claude semantic 解決の **dual opt-in** 判定。
#   `AUTO_REBASE_SEMANTIC=claude` AND `FULL_AUTO_ENABLED=true` の双方が「lowercase
#   厳密一致」の場合のみ 0 を返す純粋関数（副作用なし）。それ以外（未設定 / 空 /
#   `Claude` / `on` / `true` / typo 等）はすべて 1 を返し OFF として扱う。
#
#   Req 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.5 / NFR 1.1（安全側 fallback）
#
#   Returns:
#     0 = 両 gate が ON（Claude semantic 解決経路が起動可能）
#     1 = いずれかの gate が OFF（旧 semantic 経路にフォールバック）
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_enabled() {
  [ "${AUTO_REBASE_SEMANTIC:-off}" = "claude" ] || return 1
  [ "${FULL_AUTO_ENABLED:-false}" = "true" ] || return 1
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_state_path: PR 番号から状態ファイル絶対パスを返す純粋関数。
#   $AUTO_REBASE_SEMANTIC_STATE_DIR/pr-<number>.json の形式（NFR 4.1 /
#   CLAUDE.md「機能追加ガイドライン §6」と整合）。
#
#   Args:   $1 = PR number
#   Stdout: 絶対パス
#   Return: 0（常に）
#
#   Req 6.2
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_state_path() {
  local pr_number="$1"
  printf '%s/pr-%s.json' "$AUTO_REBASE_SEMANTIC_STATE_DIR" "$pr_number"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_load_state: 状態 JSON を stdout に出力する。ファイル不在 / JSON parse
#   失敗時は安全側 fallback として `{}` を返し、呼出側は既定値（total_attempts=0 等）
#   で初期化できる（fail-open）。
#
#   Args:   $1 = PR number
#   Stdout: JSON 全体（不在 / 破損時は `{}`）
#   Return: 0（常に）
#
#   Req 6.3（fail-open）/ NFR 4.1
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_load_state() {
  local pr_number="$1"
  local state_file
  state_file=$(ar_semantic_state_path "$pr_number")
  if [ ! -f "$state_file" ]; then
    printf '%s' "{}"
    return 0
  fi
  local content
  if ! content=$(jq -c '.' "$state_file" 2>/dev/null); then
    printf '%s' "{}"
    return 0
  fi
  printf '%s' "$content"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_save_state: 状態 JSON を atomic write で永続化する。mkdir -p で
#   state_dir を冪等確保し、同一 dir 上の `mktemp` で temp file を作成して
#   `mv -f` で atomic rename することで read-modify-write 中の中断でも破損
#   ファイルを残さない。すべての値を `jq --arg` / `--argjson` で sanitize する
#   （NFR 4.1）。
#
#   Args:
#     $1 = PR number (int)
#     $2 = total_attempts (int)
#     $3 = last_status (enum: "in-progress" | "succeeded" | "max-attempts" |
#          "skip-idempotent" | "failed")
#     $4 = last_head_sha (sha string、空可)
#
#   Return: 0 = persisted, 1 = failure (呼出側を落とさない / ar_warn で警告)
#
#   Req 6.2, 6.4 / NFR 4.1
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_save_state() {
  local pr_number="$1"
  local total_attempts="$2"
  local last_status="$3"
  local last_head_sha="$4"

  if ! mkdir -p "$AUTO_REBASE_SEMANTIC_STATE_DIR" 2>/dev/null; then
    ar_warn "ar_semantic_save_state: mkdir -p \"$AUTO_REBASE_SEMANTIC_STATE_DIR\" 失敗"
    return 1
  fi

  local state_file
  state_file=$(ar_semantic_state_path "$pr_number")

  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local new_state
  if ! new_state=$(jq -n \
      --argjson pr "$pr_number" \
      --argjson total_attempts "$total_attempts" \
      --arg last_status "$last_status" \
      --arg last_head_sha "$last_head_sha" \
      --arg last_attempt_at "$now_iso" \
      '{
        pr: $pr,
        total_attempts: $total_attempts,
        last_status: $last_status,
        last_head_sha: $last_head_sha,
        last_attempt_at: $last_attempt_at
      }' 2>/dev/null); then
    ar_warn "ar_semantic_save_state: state JSON 構築失敗 pr=$pr_number"
    return 1
  fi

  local tmp_file
  if ! tmp_file=$(mktemp "${state_file}.XXXXXX" 2>/dev/null); then
    ar_warn "ar_semantic_save_state: mktemp 失敗 pr=$pr_number"
    return 1
  fi

  if ! printf '%s\n' "$new_state" > "$tmp_file"; then
    rm -f "$tmp_file" 2>/dev/null || true
    ar_warn "ar_semantic_save_state: tmp file 書き込み失敗 pr=$pr_number"
    return 1
  fi

  if ! mv -f "$tmp_file" "$state_file" 2>/dev/null; then
    rm -f "$tmp_file" 2>/dev/null || true
    ar_warn "ar_semantic_save_state: atomic rename 失敗 pr=$pr_number"
    return 1
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_should_skip_idempotent: 同一 PR head SHA に対する Claude semantic
#   解決の二重実行を抑止する純粋判定関数。前回試行の last_head_sha が現在の head SHA
#   と一致すれば 0（= skip）、それ以外（state 不在 / 異なる SHA）は 1（= 試行可）。
#
#   Args:   $1 = PR number, $2 = current head SHA
#   Return: 0 = skip すべき（同一 SHA で attempt 済み）
#           1 = 試行可（新規 SHA / state 不在）
#
#   Req 6.1, 6.4, 6.5
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_should_skip_idempotent() {
  local pr_number="$1"
  local current_head_sha="$2"

  if [ -z "$current_head_sha" ]; then
    # head SHA 不明時は安全側 (試行可) に倒す（次サイクルで state が育つ）
    return 1
  fi

  local state last_head_sha
  state=$(ar_semantic_load_state "$pr_number")
  last_head_sha=$(printf '%s' "$state" | jq -r '.last_head_sha // ""' 2>/dev/null || echo "")

  if [ -n "$last_head_sha" ] && [ "$last_head_sha" = "$current_head_sha" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_get_attempts: 現在の通算 attempts 数を stdout に出力する。
#   state 不在 / parse 失敗時は 0。
#
#   Args:   $1 = PR number
#   Stdout: 整数（通算 attempts）
#   Return: 0（常に）
#
#   Req 7.1, 7.2
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_get_attempts() {
  local pr_number="$1"
  local state total
  state=$(ar_semantic_load_state "$pr_number")
  total=$(printf '%s' "$state" | jq -r '.total_attempts // 0' 2>/dev/null || echo 0)
  # 不正値（非数値）は 0 に丸める
  case "$total" in
    ''|*[!0-9]*) total=0 ;;
  esac
  printf '%s' "$total"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_budget_exhausted: 通算 attempts が上限 (`$AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS`)
#   に到達済みか判定する純粋関数。
#
#   Args:   $1 = total_attempts (int)
#   Return: 0 = 上限到達（escalate 要）/ 1 = まだ余裕あり
#
#   Req 7.2
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_budget_exhausted() {
  local total_attempts="$1"
  local budget="${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS:-3}"
  case "$total_attempts" in
    ''|*[!0-9]*) total_attempts=0 ;;
  esac
  case "$budget" in
    ''|*[!0-9]*) budget=3 ;;
  esac
  [ "$total_attempts" -ge "$budget" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_semantic_escalate_needs_decisions: 通算 attempts が上限到達した PR を
#   `needs-decisions` ラベルでエスカレーションする。`claude-failed` ラベルは
#   付与しない（Req 7.6 / NFR 1.3）。コメント本文には (a) 累積 attempt 数 /
#   (b) budget 値 / (c) 当該 head SHA / (d) 推奨手動復旧手順 を含める（Req 7.3）。
#
#   Args: $1=pr_number, $2=total_attempts, $3=current_head_sha
#   Return: 0=成功（label + comment）/ 1=label 付与失敗（WARN 出力 / Req 8.4）
# ─────────────────────────────────────────────────────────────────────────────
ar_semantic_escalate_needs_decisions() {
  local pr_number="$1"
  local total_attempts="$2"
  local current_head_sha="$3"
  local budget="${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS:-3}"

  local label_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-decisions ラベル付与に失敗（semantic budget 到達）"
    label_rc=1
  fi

  local comment_body
  comment_body=$(cat <<EOF
## Phase D-12: Claude semantic 解決の試行上限に到達しました（人間判断が必要）

watcher (Phase D-12 Claude semantic resolution) が本 PR の semantic conflict に対して
Claude による rebase 解決を **${total_attempts} 回** 試行しましたが、再レビュー
パイプラインを通過した状態に到達できませんでした。試行上限（\`AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS=${budget}\`）に
到達したため、**人間判断にエスカレーション**します。

### 状態

- 累積試行回数: \`${total_attempts}\`
- 試行上限値: \`${budget}\`
- 当該 PR head SHA: \`${current_head_sha}\`

### 推奨復旧手順

1. 当該 PR の差分を手動で確認し、semantic 解消が妥当か判断してください
2. 手動 rebase が必要な場合: \`gh pr checkout ${pr_number} && git rebase origin/${BASE_BRANCH}\`
   で解消した上で \`git push --force-with-lease\` してください
3. Issue 自体の方針変更が必要な場合は \`MECHANICAL_PATHS\` allowlist の見直しや、
   親 Issue の分割 / 設計差し戻しを検討してください
4. 復旧後、\`${LABEL_NEEDS_DECISIONS}\` ラベルを手動で外すと watcher が再試行可能になります

---

_本コメントは Phase D-12 Claude semantic resolution が自動投稿しました。本機能を
完全に無効化する場合は \`AUTO_REBASE_SEMANTIC\` を \`off\` に切り替えてください。_

<!-- idd-claude:auto-rebase-semantic pr=${pr_number} attempts=${total_attempts} status=max-attempts -->
EOF
)

  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-decisions エスカレーションコメント投稿に失敗"
  fi

  return "$label_rc"
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_semantic_claude: Claude semantic 解決経路の副作用を実行。
#   旧 `ar_apply_semantic`（人間レビュー誘導）と異なり、再レビュー（codex-review /
#   claude-review）の再発火に処理を委ねる点が中核。push そのものは既存
#   `ar_run_claude_rebase` が `--force-with-lease` で完了済みのため、本関数では:
#     1. ar_dismiss_all_approvals で approve を全件 dismiss（二重ゲートの維持 / Req 5.1）
#     2. needs-rebase 除去
#     3. ready-for-review 付与（既存と同じ / Req 5.2）
#     4. コメント本文を「再レビュー再発火」を明記した文面に置換（Req 4.4 (a)〜(d)）
#
#   入力: $1=pr_number, $2=pr_url, $3=before_sha, $4=after_sha,
#         $5=first_unmatched_path（空可）, $6=total_attempts（コメントに含める）
#   戻り値:
#     0 : 全成功
#     1 : dismissal 失敗（呼出側で escalate `dismissal-failed`）
#     2 : label / comment 失敗（部分成功）
#
#   Req 4.4, 5.1, 5.2, 5.3, 5.4, 8.3
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_semantic_claude() {
  local pr_number="$1"
  local pr_url="$2"
  local before_sha="$3"
  local after_sha="$4"
  local first_unmatched="${5:-}"
  local total_attempts="${6:-1}"

  # 1. approving review をすべて dismiss（Claude 解決後も二重ゲートを維持 / Req 5.1）
  if ! ar_dismiss_all_approvals "$pr_number"; then
    return 1
  fi

  local partial_fail=0

  # 2. needs-rebase 除去（既存挙動と整合 / Req 8.3）
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-rebase ラベル除去に失敗（semantic-claude 経路）"
    partial_fail=1
  fi

  # 3. ready-for-review 付与（Req 5.2）
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_READY" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: ready-for-review ラベル付与に失敗（semantic-claude 経路）"
    partial_fail=1
  fi

  # 4. 説明コメント投稿（Req 4.4 (a)〜(d)）
  local unmatched_line=""
  if [ -n "$first_unmatched" ]; then
    unmatched_line="- 最初に検出された allowlist 外パス: \`${first_unmatched}\`"
  fi

  local comment_body
  comment_body=$(cat <<EOF
## Phase D-12: Claude が semantic conflict を解消しました（再レビュー待ち）

watcher (Phase D-12 Claude semantic resolution) が本 PR の \`needs-rebase\` 状態に
対して Claude による rebase を実行し、semantic な書き換えを含む解決を **PR head
へ追加 commit として push** しました。本機能は LLM の解決結果を **無検証で merge
することは絶対に行わず**、既存 approving review を全件取り消した上で、再レビュー
パイプライン（\`codex-review\` / \`claude-review\` の自動レビュー）の再発火を待ちます。

### 実施内容（試行 ${total_attempts} 回目）

- (a) rebase 前 head SHA: \`${before_sha}\`
- (a) rebase 後 head SHA: \`${after_sha}\` （= Claude が push した新 head）
${unmatched_line}
- (b) 既存 approving review を **review dismissal API** で全件取り消しました
- \`needs-rebase\` を除去し \`ready-for-review\` を付与しました

### 次のアクション（再レビューパイプラインに委譲）

- (c) **\`codex-review\` / \`claude-review\` が新 head SHA \`${after_sha}\` に対して
  自動的に再発火します**（pr-reviewer.sh の既存挙動 / #261 / #349）。watcher が
  数サイクル以内に再レビュー結果を投稿します
- (d) **auto-merge の発火条件**: 再レビュー結果が \`needs-iteration\` でなく、かつ
  少なくとも 1 件の approving review が新 head SHA に対して付与された場合のみ
  auto-merge が許可されます（人間 / 自動 approve の復帰が必須）
- 再レビューが \`needs-iteration\` を返した場合は pr-iteration.sh の通常 3R ループに
  委譲されます。本 PR の Claude semantic 解決の通算試行上限は
  \`AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS\`（既定 3 回）で、上限到達時は
  \`needs-decisions\` ラベル付与で人間判断にエスカレーションされます

---

_本コメントは Phase D-12 Claude semantic resolution が自動投稿しました。本機能の
挙動を変更する場合は \`AUTO_REBASE_SEMANTIC\` を \`off\` に切り替えてください
（旧 semantic 経路 = 人間レビュー待ちにフォールバック）。_

<!-- idd-claude:auto-rebase-semantic pr=${pr_number} attempt=${total_attempts} before=${before_sha} after=${after_sha} -->
EOF
)

  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: semantic-claude 説明コメントの投稿に失敗（${pr_url}）"
    partial_fail=1
  fi

  if [ "$partial_fail" -eq 1 ]; then
    return 2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_apply_semantic: semantic 判定時の副作用を実行。
#   gate 評価により以下の 2 経路に分岐する（Req 1.4, 2.4, 3.1, NFR 1.1）:
#
#   - dual opt-in OFF（既定 / `AUTO_REBASE_SEMANTIC=off` または
#     `FULL_AUTO_ENABLED!=true`）: 旧経路（人間レビュー待ち）
#       1. ar_dismiss_all_approvals で approve を全件 dismiss
#       2. needs-rebase 除去
#       3. ready-for-review 付与
#       4. 「人間レビュー必須」コメント投稿
#
#   - dual opt-in ON（`AUTO_REBASE_SEMANTIC=claude` AND `FULL_AUTO_ENABLED=true`）:
#     新経路（再レビュー再発火に委譲）→ ar_apply_semantic_claude へ委譲
#
#   入力: $1=pr_number, $2=pr_url, $3=before_sha, $4=after_sha,
#         $5=first_unmatched_path（空可）, $6=total_attempts（新経路時のみ参照）
#   戻り値:
#     0 : 全成功
#     1 : dismissal 失敗
#     2 : label / comment 失敗（部分成功）
#
#   Req 1.4, 2.4, 3.1, 4.4, 5.1〜5.4, 7.1〜7.4, 8.3, NFR 1.1
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_semantic() {
  local pr_number="$1"
  local pr_url="$2"
  local before_sha="$3"
  local after_sha="$4"
  local first_unmatched="${5:-}"
  local total_attempts="${6:-1}"

  # dual opt-in ON → 新経路（Claude 解決 + 再レビュー再発火）へ委譲
  if ar_semantic_enabled; then
    ar_apply_semantic_claude \
      "$pr_number" "$pr_url" "$before_sha" "$after_sha" \
      "$first_unmatched" "$total_attempts"
    return $?
  fi

  # dual opt-in OFF → 旧経路（人間レビュー待ち / NFR 1.1）
  # 1. approving review をすべて dismiss
  if ! ar_dismiss_all_approvals "$pr_number"; then
    return 1
  fi

  local partial_fail=0

  # 2. needs-rebase 除去
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: needs-rebase ラベル除去に失敗（semantic 経路）"
    partial_fail=1
  fi

  # 3. ready-for-review 付与
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_READY" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: ready-for-review ラベル付与に失敗"
    partial_fail=1
  fi

  # 4. 説明コメント投稿（Req 7.4）
  local unmatched_line=""
  if [ -n "$first_unmatched" ]; then
    unmatched_line="- 最初に検出された allowlist 外パス: \`${first_unmatched}\`"
  fi

  local comment_body
  comment_body=$(cat <<EOF
## Phase D: semantic rebase により再レビューが必要です

watcher (Phase D Auto Rebase Processor) が本 PR の \`needs-rebase\` 状態に対して
Claude による rebase を実行しました。rebase 後の変更ファイルのうち \`MECHANICAL_PATHS\`
allowlist に含まれない path が検出されたため、**semantic な書き換えを含む rebase**と
判定しました。

### 実施内容

- rebase 前 head SHA: \`${before_sha}\`
- rebase 後 head SHA: \`${after_sha}\`
${unmatched_line}
- 既存 approving review を **review dismissal API** で全件取り消しました
- \`needs-rebase\` を除去し \`ready-for-review\` を付与しました

### 次のアクション（人間レビュワー向け）

Claude が rebase 過程で書き換えた内容は人間レビューを通っていません。差分を確認し、
妥当であれば **再度 approve** してください。allowlist の見直しが必要な場合は
\`MECHANICAL_PATHS\` 環境変数の設定値も併せて検討してください。

---

_本コメントは Phase D Auto Rebase Processor が自動投稿しました。本機能の挙動を変更する
場合は \`AUTO_REBASE_MODE\` を \`off\` に切り替えてください。_

<!-- idd-claude:auto-rebase pr=${pr_number} -->
EOF
)

  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: semantic 説明コメントの投稿に失敗（${pr_url}）"
    partial_fail=1
  fi

  if [ "$partial_fail" -eq 1 ]; then
    return 2
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_escalate_to_failed: `claude-failed` ラベルを付与し、原因種別と手動復旧手順を
#   含むコメントを 1 件投稿する。`needs-rebase` ラベルには触らない（Req 8.1）。
#
#   入力: $1=pr_number, $2=reason
#     reason ∈ { "conflict-unresolved", "timeout", "push-failed",
#                "dismissal-failed", "fetch-failed" }
#   戻り値: 0=成功、1=失敗（WARN）
#
#   Req 4.4, 4.5, 7.6, 8.1, 8.2, 8.3, 8.4
# ─────────────────────────────────────────────────────────────────────────────
ar_escalate_to_failed() {
  local pr_number="$1"
  local reason="$2"

  local reason_desc recovery
  case "$reason" in
    conflict-unresolved)
      reason_desc="Claude が conflict を解消できませんでした（working tree が dirty 残置、または rebase 自体が走らなかった可能性）"
      recovery="手動で \`gh pr checkout ${pr_number} && git rebase origin/${BASE_BRANCH}\` を実施し、conflict を解消してから force-with-lease push してください"
      ;;
    timeout)
      reason_desc="Claude rebase が \`${AUTO_REBASE_MAX_TURNS_SEC}\` 秒の timeout を超過しました"
      recovery="PR 規模が大きい場合は手動 rebase を推奨します。次回サイクルで再試行したい場合は \`claude-failed\` ラベルを手動で外してください"
      ;;
    push-failed)
      reason_desc="rebase は成功しましたが \`git push --force-with-lease\` に失敗しました（リモートが先行している可能性）"
      recovery="\`gh pr checkout ${pr_number} && git pull --rebase origin ${BASE_BRANCH}\` でリモートを取り込んでから手動 push してください"
      ;;
    dismissal-failed)
      reason_desc="semantic 判定後に approving review の dismissal API が失敗しました"
      recovery="GitHub の Reviews UI から手動で approve を取り消し、変更内容を再レビューしてください。watcher の token が PR review dismissal 権限を持っているか（admin / maintain ロール相当）も確認してください"
      ;;
    fetch-failed)
      reason_desc="rebase に到達する前に \`git fetch\` / \`git checkout\` が失敗しました"
      recovery="ネットワーク疎通とリモート ref の存在を確認してください。次回サイクルで自動再試行はしません（\`claude-failed\` 解除が必要）"
      ;;
    *)
      reason_desc="未知の失敗理由: ${reason}"
      recovery="watcher の log（\`auto-rebase:\` prefix）を確認し、手動で復旧してください"
      ;;
  esac

  local label_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: claude-failed ラベル付与に失敗（理由: ${reason}）"
    label_rc=1
  fi

  local comment_body
  comment_body=$(cat <<EOF
## Phase D: Claude rebase が失敗しました（人間エスカレーション）

watcher (Phase D Auto Rebase Processor) が本 PR の \`needs-rebase\` 状態に対して
Claude による rebase を実行しましたが、**失敗した**ためエスカレーションします。

### 失敗種別

\`${reason}\`

### 詳細

${reason_desc}

### 推奨復旧手順

${recovery}

---

_本コメントは Phase D Auto Rebase Processor が自動投稿しました。\`claude-failed\`
ラベルが付いている間、本機能は同一 PR への rebase 再試行を行いません（Req 8.4）。
復旧後は \`claude-failed\` ラベルを手動で外してください。_

<!-- idd-claude:auto-rebase pr=${pr_number} reason=${reason} -->
EOF
)

  local comment_rc=0
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: claude-failed エスカレーションコメント投稿に失敗"
    comment_rc=1
  fi

  if [ "$label_rc" -ne 0 ] || [ "$comment_rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# ar_handle_pr: 1 PR の Phase D 処理を実行
#   （rebase 試行 → 分類 → mechanical/semantic 後処理 / 失敗時 escalate）
#
#   入力: $1 = pr_json（gh pr list の 1 要素 JSON）
#   戻り値:
#     0  : mechanical 完了
#     1  : semantic 完了
#     2  : failed（claude-failed 付与済み）
#     10 : skip（rebase 不要 / push 待ち UNKNOWN 等、次サイクルに委ねる）
#
#   Req 3.4, 4.4, 4.5, 5.5, 7.6, NFR 2.1, NFR 5.2
# ─────────────────────────────────────────────────────────────────────────────
ar_handle_pr() {
  local pr_json="$1"

  local pr_number head_ref base_ref pr_url pr_title current_head_sha
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')
  pr_title=$(echo "$pr_json"  | jq -r '.title // ""')
  # Issue #366: idempotency / budget 判定に使う現在の head SHA（既存 query に headRefOid を追加）
  current_head_sha=$(echo "$pr_json" | jq -r '.headRefOid // ""')

  # Issue #366 Req 9.3: per-cycle summary 用の bucket 識別子（process_auto_rebase が読む
  # グローバル）。gate OFF / mechanical 経路では "" のままで semantic subtotal に加算
  # されない。本変数は ar_handle_pr 1 回呼び出しごとに必ずリセットする。
  _AR_SEMANTIC_BUCKET=""

  # Issue #366: dual opt-in が ON のときのみ、Claude 起動前に以下を判定する。
  # gate OFF（既定）では一切実行されず、本機能導入前と完全に等価（NFR 1.1）。
  if ar_semantic_enabled; then
    # 1a. needs-decisions ラベル付きの PR は skip（Req 7.4 / 8.1 と同型）
    local has_needs_decisions
    has_needs_decisions=$(echo "$pr_json" | jq -r \
      --arg L "$LABEL_NEEDS_DECISIONS" \
      '[.labels[]? | select(.name == $L)] | length' 2>/dev/null || echo 0)
    if [ "${has_needs_decisions:-0}" -gt 0 ]; then
      # Issue #366 Req 9.1: log に gate 解決値を含める
      ar_log "PR #${pr_number}: semantic action=skip-needs-decisions semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} head=${current_head_sha} url=${pr_url}"
      _AR_SEMANTIC_BUCKET="skipped"
      return 10
    fi

    # 1a'. claude-failed ラベル付きの PR は本来 server-side filter で除外済み（Req 4.7 /
    # 8.1）。万一通過した場合の防御的 skip。Req 9.1 の skip-claude-failed action ラベル
    # 出力もここで担う。
    local has_claude_failed
    has_claude_failed=$(echo "$pr_json" | jq -r \
      --arg L "$LABEL_FAILED" \
      '[.labels[]? | select(.name == $L)] | length' 2>/dev/null || echo 0)
    if [ "${has_claude_failed:-0}" -gt 0 ]; then
      ar_log "PR #${pr_number}: semantic action=skip-claude-failed semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} head=${current_head_sha} url=${pr_url}"
      _AR_SEMANTIC_BUCKET="skipped"
      return 10
    fi

    # 1b. budget 上限到達済みかチェック（Req 7.2）
    local prior_attempts
    prior_attempts=$(ar_semantic_get_attempts "$pr_number")
    if ar_semantic_budget_exhausted "$prior_attempts"; then
      ar_log "PR #${pr_number}: semantic action=escalate-needs-decisions semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} attempts=${prior_attempts} budget=${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS} head=${current_head_sha} url=${pr_url}"
      ar_semantic_escalate_needs_decisions "$pr_number" "$prior_attempts" "$current_head_sha" || true
      # state を `max-attempts` に更新（次サイクル以降の冪等性 / Req 7.4）
      ar_semantic_save_state "$pr_number" "$prior_attempts" "max-attempts" "$current_head_sha" || true
      _AR_SEMANTIC_BUCKET="escalated"
      return 10
    fi

    # 1c. 同一 head SHA への二重実行抑止（Req 6.1, 6.4, 6.5）
    if ar_semantic_should_skip_idempotent "$pr_number" "$current_head_sha"; then
      ar_log "PR #${pr_number}: semantic action=skip-idempotent semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} head=${current_head_sha} attempts=${prior_attempts} url=${pr_url}"
      _AR_SEMANTIC_BUCKET="skipped"
      return 10
    fi

    # 1d. attempt budget を試行開始時に加算（Req 7.5 / failed-recovery と同方針）。
    # この時点で state を「in-progress / current_head_sha」で保存し、Claude / push 失敗時も
    # 上限消費が確定するようにする。
    local new_attempts=$((prior_attempts + 1))
    ar_semantic_save_state "$pr_number" "$new_attempts" "in-progress" "$current_head_sha" || true
    ar_log "PR #${pr_number}: semantic action=attempt semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} attempts=${new_attempts} budget=${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS} head=${current_head_sha} url=${pr_url}"
  fi

  # 1. Claude rebase を試行
  local rebase_output rebase_rc=0
  rebase_output=$(ar_run_claude_rebase "$pr_number" "$pr_title" "$pr_url" "$head_ref" "$base_ref") || rebase_rc=$?

  # Issue #366 Req 9.2: 試行完了時の outcome 識別子（`resolved` / `timeout` / `dirty` /
  # `push-failed`）を ar_log に併記する。gate ON 時は attempts も含める。
  # gate OFF 時は `_AR_SEMANTIC_BUCKET` を空のまま残し、summary subtotal に加算しない。
  local _semantic_log_suffix=""
  if ar_semantic_enabled; then
    _semantic_log_suffix=" semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} attempts=${new_attempts:-1}"
  fi

  case "$rebase_rc" in
    0)
      # 成功（rebase + push 完了）。後続で分類へ進む
      ;;
    5)
      # rebase 不要（既に base が head の祖先）。Re-check が拾うべきケースとして skip
      ar_log "PR #${pr_number}: rebase 不要（already up-to-date with base, skip）action=skip url=${pr_url}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="skipped"
      fi
      return 10
      ;;
    1)
      ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
      ar_log "PR #${pr_number}: classification=failed reason=conflict-unresolved outcome=dirty action=escalate url=${pr_url}${_semantic_log_suffix}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
    2)
      ar_escalate_to_failed "$pr_number" "timeout" || true
      ar_log "PR #${pr_number}: classification=failed reason=timeout outcome=timeout action=escalate url=${pr_url}${_semantic_log_suffix}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
    3)
      ar_escalate_to_failed "$pr_number" "push-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=push-failed outcome=push-failed action=escalate url=${pr_url}${_semantic_log_suffix}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
    4)
      ar_escalate_to_failed "$pr_number" "fetch-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=fetch-failed outcome=fetch-failed action=escalate url=${pr_url}${_semantic_log_suffix}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown(rc=${rebase_rc}) outcome=dirty action=escalate url=${pr_url}${_semantic_log_suffix}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
  esac

  # 2. 成功した SHA を parse（"<before> <after>" の 1 行）
  local before_sha after_sha
  before_sha=$(echo "$rebase_output" | awk '{print $1}')
  after_sha=$(echo "$rebase_output"  | awk '{print $2}')
  if [ -z "$before_sha" ] || [ -z "$after_sha" ]; then
    ar_warn "PR #${pr_number}: rebase 成功だが SHA を parse できず、escalate"
    ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
    return 2
  fi

  # 3. push 後の head を origin から fetch して classify に使う
  if ! timeout "$AUTO_REBASE_GIT_TIMEOUT" git fetch origin "$head_ref" "$base_ref" >/dev/null 2>&1; then
    ar_warn "PR #${pr_number}: rebase 後の git fetch に失敗"
  fi

  # 4. mechanical / semantic を判定（Req 5.x）
  local classify_output classification first_unmatched=""
  classify_output=$(ar_classify_diff "$pr_number" "$base_ref" "$head_ref")
  classification=$(echo "$classify_output" | sed -n '1p')
  first_unmatched=$(echo "$classify_output" | sed -n '2p')

  # 5. 分類別の後処理
  if [ "$classification" = "mechanical" ]; then
    if ar_apply_mechanical "$pr_number"; then
      ar_log "PR #${pr_number}: classification=mechanical before=${before_sha} after=${after_sha} action=label-removed url=${pr_url}"
      return 0
    else
      ar_log "PR #${pr_number}: classification=mechanical before=${before_sha} after=${after_sha} action=label-remove-failed url=${pr_url}"
      # ラベル除去失敗は failed 扱いにしない（次サイクルで再試行可能 / Error Handling 節）
      return 0
    fi
  fi

  # semantic（または `git diff` 失敗時の保守的 semantic）
  local semantic_rc=0
  # Issue #366: 新経路は試行カウンタを comment に含めるため引数として渡す。gate OFF
  # 時は ar_apply_semantic 内部で旧経路に分岐し、6 番目の引数は使われない（無害）。
  local _semantic_attempts="${new_attempts:-1}"

  # Issue #366 Req 9.1: gate OFF + classification=semantic で skip-gate-off の log 行を
  # 1 件出力する。Req 9.2 の outcome 識別子は ar_apply_semantic の rc から後段で
  # マップするため、ここでは行を出すだけで bucket には加算しない（gate OFF 時 bucket は
  # ""のまま）。
  if ! ar_semantic_enabled; then
    ar_log "PR #${pr_number}: semantic action=skip-gate-off semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED} before=${before_sha} after=${after_sha} head=${current_head_sha} url=${pr_url}"
  fi

  ar_apply_semantic "$pr_number" "$pr_url" "$before_sha" "$after_sha" "$first_unmatched" "$_semantic_attempts" || semantic_rc=$?
  case "$semantic_rc" in
    0)
      # Issue #366: gate ON 時は after_sha を last_head_sha として記録し、
      # 次サイクル以降の同一 SHA への二重実行を抑止する（Req 6.4）。
      if ar_semantic_enabled; then
        ar_semantic_save_state "$pr_number" "$_semantic_attempts" "succeeded" "$after_sha" || true
        _AR_SEMANTIC_BUCKET="resolved"
      fi
      # Req 9.2: outcome=resolved + attempts を併記（既存 action=dismissed+ready は
      # 後方互換のため温存）
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} unmatch=${first_unmatched:-(unknown)} action=dismissed+ready outcome=resolved attempts=${_semantic_attempts} url=${pr_url}"
      return 1
      ;;
    1)
      # dismissal 失敗 → escalate
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=dismissal-failed outcome=push-failed before=${before_sha} after=${after_sha} action=escalate attempts=${_semantic_attempts} url=${pr_url}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
    2)
      # label / comment の部分失敗。dismissal は成功しているので semantic 扱いを維持
      if ar_semantic_enabled; then
        ar_semantic_save_state "$pr_number" "$_semantic_attempts" "succeeded" "$after_sha" || true
        _AR_SEMANTIC_BUCKET="resolved"
      fi
      # Req 9.2: dismissal は成功 = outcome=resolved 扱い（label/comment の部分失敗は
      # 二重ゲート上の安全性に影響しないため）
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} action=dismissed+partial-fail outcome=resolved attempts=${_semantic_attempts} url=${pr_url}"
      return 1
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown-semantic(rc=${semantic_rc}) outcome=push-failed action=escalate attempts=${_semantic_attempts} url=${pr_url}"
      if ar_semantic_enabled; then
        _AR_SEMANTIC_BUCKET="failed"
      fi
      return 2
      ;;
  esac
}

process_auto_rebase() {
  # Req 1.1: opt-in gate（未設定 / `off` / 不正値で起動しない）
  if [ "$AUTO_REBASE_MODE" = "off" ]; then
    return 0
  fi

  # NFR 5.2 / Phase A pattern: 想定外の dirty working tree を検知したら ERROR で
  # サイクル中止（後続 Processor を阻害しないよう 0 return）
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    ar_error "dirty working tree を検出しました。Phase D Auto Rebase Processor をスキップします。"
    return 0
  fi

  # Req 1.4: サイクル開始時に有効値をログ出力
  # Issue #366 Req 1.6: dual opt-in 状態（semantic-claude 経路の有効化条件）も併記。
  local _semantic_resolved_state="off"
  if ar_semantic_enabled; then
    _semantic_resolved_state="claude"
  fi
  ar_log "サイクル開始 (mode=${AUTO_REBASE_MODE}, paths=${MECHANICAL_PATHS:-(empty)}, max_prs=${AUTO_REBASE_MAX_PRS}, model=${AUTO_REBASE_MODEL}, max_turns=${AUTO_REBASE_MAX_TURNS}, timeout=${AUTO_REBASE_MAX_TURNS_SEC}s, semantic=${AUTO_REBASE_SEMANTIC}, semantic-resolved=${_semantic_resolved_state}, semantic-max-attempts=${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS}, additive=${AUTO_REBASE_ADDITIVE}, additive-paths=${AUTO_REBASE_ADDITIVE_PATHS:-(empty)})"

  # Req 2.1〜2.5 / Req 8.4: 候補 PR 取得（API エラー時は空配列を扱う）
  local prs_json
  prs_json=$(ar_fetch_candidates) || true
  if [ -z "$prs_json" ]; then
    prs_json="[]"
  fi

  local total
  total=$(echo "$prs_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$AUTO_REBASE_MAX_PRS" ]; then
    target_count="$AUTO_REBASE_MAX_PRS"
    skipped_overflow=$((total - AUTO_REBASE_MAX_PRS))
    ar_log "対象候補 ${total} 件中、上限 ${AUTO_REBASE_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    ar_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  local mechanical=0 semantic=0 failed=0 skipped=0
  # Issue #366 Req 9.3: semantic-claude 経路の subtotal カウンタ。gate ON 配下で
  # `ar_handle_pr` が `_AR_SEMANTIC_BUCKET` をセットしたときのみインクリメントする
  # （gate OFF 時は空のままで加算されない / NFR 1.1 互換）。
  local semantic_resolved=0 semantic_failed=0 semantic_escalated=0 semantic_skipped=0

  if [ "$target_count" -gt 0 ]; then
    local pr_iter
    pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

    if [ -n "$pr_iter" ]; then
      while IFS= read -r pr_json; do
        local rc=0
        # ar_handle_pr は呼び出し毎に _AR_SEMANTIC_BUCKET をリセットする契約。
        ar_handle_pr "$pr_json" || rc=$?
        case "$rc" in
          0)  mechanical=$((mechanical + 1)) ;;
          1)  semantic=$((semantic + 1)) ;;
          2)  failed=$((failed + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
        # Issue #366 Req 9.3: gate ON 配下のみ subtotal を加算
        case "${_AR_SEMANTIC_BUCKET:-}" in
          resolved)  semantic_resolved=$((semantic_resolved + 1)) ;;
          failed)    semantic_failed=$((semantic_failed + 1)) ;;
          escalated) semantic_escalated=$((semantic_escalated + 1)) ;;
          skipped)   semantic_skipped=$((semantic_skipped + 1)) ;;
          *) : ;;
        esac
      done <<< "$pr_iter"
    fi
  fi

  # Req 3.4 / NFR 2.2: サマリ行 1 件
  # Issue #366 Req 9.3: semantic-resolved / semantic-failed / semantic-escalated /
  # semantic-skipped の 4 subtotal を追記
  ar_log "サマリ: mechanical=${mechanical}, semantic=${semantic}, failed=${failed}, skip=${skipped}, overflow=${skipped_overflow}, semantic-resolved=${semantic_resolved}, semantic-failed=${semantic_failed}, semantic-escalated=${semantic_escalated}, semantic-skipped=${semantic_skipped}"

  # NFR 5.2 / Phase A pattern: 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}
