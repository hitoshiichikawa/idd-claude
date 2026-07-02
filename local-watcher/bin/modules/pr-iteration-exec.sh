#!/usr/bin/env bash
# shellcheck shell=bash
# pr-iteration-exec.sh — PR Iteration 1 round 実行ヘルパー（prompt 構築 / escalation / quota 検出 / auto-commit）
#
# family: pr-iteration / prefix: pi_（#469 で pr-iteration.sh から分割。family マニフェストは
#   pr-iteration.sh 冒頭ヘッダを参照）
#
# 用途:
#   pi_run_iteration（pr-iteration.sh）が 1 round を実行する際に使うヘルパー群を集約する。
#   - prompt 構築: pi_build_iteration_prompt（pr-iteration-comments.sh の
#     pi_collect_general_comments を遅延束縛で呼ぶ）
#   - 上限到達 escalation: pi_escalate_to_failed（build_recovery_hint を呼ぶ）
#   - quota soft-fail 検出: pi_detect_quota_soft_fail
#   - auto-commit ガード / 実行: pi_branch_is_claude_pr_head / pi_auto_commit_and_push
#   build_recovery_hint は pi_ 命名ではないが、pi_escalate_to_failed に加え impl-pipeline.sh /
#   slot-worker.sh からも遅延束縛で呼ばれる共有ヘルパー（Issue #65）。#469 時点では cross-module
#   移設せず pr-iteration family に同居させたまま温存する（挙動不変 / 移設は scope 外。PR 確認事項参照）。
#
# 配置先:
#   $HOME/bin/modules/pr-iteration-exec.sh（install.sh が modules/*.sh を glob 配布）
#
# 依存:
#   - issue-watcher.sh 本体から source される（単体起動しない / 関数定義のみ / トップレベル副作用なし）。
#   - ロガー pi_log / pi_warn / pi_error は core_utils.sh。claude_log_detect_529 も遅延束縛で呼ぶ。
#     グローバル（$REPO / $PR_ITERATION_GIT_TIMEOUT / $PR_ITERATION_NO_PROGRESS_LIMIT /
#     $ITERATION_TEMPLATE / $LABEL_NEEDS_ITERATION / $LABEL_FAILED / $REPO_DIR 等）は watcher-config.sh。
#   - 外部 CLI: gh / git / jq / claude / awk / date。

# ─────────────────────────────────────────────────────────────────────────────
# build_recovery_hint (Issue #65 Req 3.1〜3.4)
#
# `claude-failed` ラベル付与時に escalation コメントへ含める「手動復旧手順」共通
# 文字列を組み立てる。
#
# 事故事例（2026-04-29 / Issue #52 復旧時 PR #62 orphan 化）の再発を防ぐため、
# 以下を必ず含める:
#   - ラベル操作の正しい順序: `ready-for-review` 先付与 → `claude-failed` 除去
#   - 順序逆転で再 pickup → 既存 PR が orphan 化するリスク注意
#   - PR 無し時は `claude-failed` 除去のみで再 pickup される旨
#
# 入力: $1 = pr_present ("yes"|"no"|"unknown"; 既定 "unknown")
# 出力: stdout に markdown 文字列（escalation コメント本文の末尾に append される想定）
# 副作用: なし（純粋関数）
#
# 呼び出し側: mark_issue_failed / _slot_mark_failed / pi_escalate_to_failed
# ─────────────────────────────────────────────────────────────────────────────
build_recovery_hint() {
  local pr_present="${1:-unknown}"
  case "$pr_present" in
    yes|no|unknown) ;;
    *) pr_present="unknown" ;;
  esac

  cat <<'EOF'

---

### 手動復旧の正しい手順 (Issue #65)

ラベル操作の順序を間違えると、watcher が次サイクルで再 pickup し、既存の
PR を `force-push` で破壊する事故が起こります（過去事例: PR #62 orphan 化）。

EOF

  case "$pr_present" in
    yes)
      cat <<'EOF'
**この Issue には既に PR が紐付いています**。復旧する場合は順序が重要です:

1. `ready-for-review` ラベルを **先に付与** する
2. その後で `claude-failed` ラベルを除去する

`claude-failed` を先に外すと、`auto-dev` のみが残った状態になり、watcher が次
サイクルで再 pickup → impl-resume が起動して既存 PR が `force-push` 破壊
される可能性があります。

なお watcher 側にも Pre-Claim Filter が組まれているため、linked impl PR が
OPEN/MERGED の場合は claim が抑止されますが、二重ガードのために順序は厳守
してください。

EOF
      ;;
    no)
      cat <<'EOF'
**この Issue には現時点で PR が紐付いていません**。復旧する場合:

- `claude-failed` を除去すると次サイクルで watcher が再 pickup します
  （PR が無ければ Pre-Claim Filter は素通りするため、impl/Triage が再起動
  されます）
- これ以上自動再実行したくない場合は `claude-failed` を残したまま
  `auto-dev` を外す方法もあります

EOF
      ;;
    *)
      cat <<'EOF'
**復旧手順は PR の有無で分岐します**:

- PR が既に作成済みの場合: `ready-for-review` を **先に付与** してから
  `claude-failed` を除去する。順序を逆にすると watcher が次サイクルで再
  pickup し、impl-resume が起動して既存 PR が `force-push` 破壊される
  可能性があります。
- PR が無い場合: `claude-failed` を除去すると次サイクルで再 pickup される
  ため、自動再実行を望まないときは `auto-dev` も外す。

watcher 側にも Pre-Claim Filter（linked impl PR が OPEN/MERGED なら claim
を抑止）が組まれていますが、二重ガードのため順序は厳守してください。

EOF
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_escalate_to_failed: 上限到達時の claude-failed 昇格 + エスカレコメント
#   入力: $1=pr_number, $2=round, $3=max_rounds, $4=reason (任意, 既定 "max-rounds")
#         $5=streak (任意, reason=no-progress のとき表示する連続カウンタ値)
#   AC 7.2, 7.3 / Issue #122 Req 3.5
#
#   reason: "max-rounds"（既定）または "no-progress"。コメント本文と理由表示を切り替える。
# ─────────────────────────────────────────────────────────────────────────────
pi_escalate_to_failed() {
  local pr_number="$1"
  local round="$2"
  local max_rounds="$3"
  local reason="${4:-max-rounds}"
  local streak="${5:-0}"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr edit "$pr_number" --repo "$REPO" \
      --remove-label "$LABEL_NEEDS_ITERATION" \
      --add-label "$LABEL_FAILED" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: claude-failed 昇格時のラベル遷移に失敗"
    return 1
  fi

  local escalation_body
  if [ "$reason" = "no-progress" ]; then
    # Issue #122 Req 3.5: no-progress 連続上限到達時の専用本文
    local no_progress_limit="${PR_ITERATION_NO_PROGRESS_LIMIT:-3}"
    escalation_body=$(cat <<EOF
## :rotating_light: PR Iteration no-progress 上限到達 (#122 no-progress loop guard)

本 PR は **no-progress 連続 ${streak} round** に達しました（上限
\`PR_ITERATION_NO_PROGRESS_LIMIT=${no_progress_limit}\`）。head branch への新規 commit が
${streak} round 連続で観測されなかったため、コスト暴走と無限ループを防ぐために
\`needs-iteration\` ラベルを除去し、\`claude-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- no-progress 連続: ${streak} round
- no-progress 上限値: ${no_progress_limit} round
- 進捗 commit が連続して無いため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Claude が「対応不要」と
   判断していたのか、対応に失敗していたのかを確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-claude:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`claude-failed\` ラベルを除去
   - \`needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`claude-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#122 no-progress loop guard) が自動投稿しました。_
EOF
)
  else
    escalation_body=$(cat <<EOF
## :rotating_light: PR Iteration 上限到達 (#26 PR Iteration Processor)

本 PR の累計自動 iteration 回数が上限 (\`max_rounds=${max_rounds}\`) に達しました。
\`needs-iteration\` ラベルを除去し、\`claude-failed\` ラベルに付け替えています。

### これまでの状況

- 累計 iteration: ${round} round
- 上限値: ${max_rounds} round
- 上限到達のため自動 iteration を停止

### 次に人間が取るべきアクション

1. これまでのレビューコメントと自動修正履歴を読み、Claude の判断を確認する
2. 必要に応じて手動で修正 commit を積む
3. 自動 iteration を再開したい場合:
   - PR 本文の \`<!-- idd-claude:pr-iteration round=N ... -->\` 行を **手動で削除**（カウンタリセット）
   - \`claude-failed\` ラベルを除去
   - \`needs-iteration\` ラベルを付け直す
4. これ以上自動 iteration を行わない場合は \`claude-failed\` を残したまま手動レビューに移行

---

_本コメントは PR Iteration Processor (#26) が自動投稿しました。_
EOF
)
  fi
  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # pi_escalate_to_failed は PR Iteration（needs-iteration ラベル付き PR）からの遷移
  # であり、文脈上 PR が必ず存在するため pr_present="yes" を渡す。
  escalation_body="${escalation_body}
$(build_recovery_hint "yes")"

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$escalation_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: エスカレコメントの投稿に失敗（ラベル遷移は完了済み）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_build_iteration_prompt: 指定 template に変数を注入
#   入力: $1=pr_number, $2=pr_json, $3=round, $4=template_path（省略時は impl 用既定）
#   出力: stdout に prompt 文字列
#   AC 3.1, 3.2, 3.3, 3.4, 3.5（#26）/ #35 で kind 引数の代わりに template path を受け取る
# ─────────────────────────────────────────────────────────────────────────────
pi_build_iteration_prompt() {
  local pr_number="$1"
  local pr_json="$2"
  local round="$3"
  # #35: template path を呼び出し元から渡す。省略時は impl 用 template を使う（後方互換）。
  local tmpl_path="${4:-$ITERATION_TEMPLATE}"
  # Issue #122 Req 1.6: kind 別に解決した round 上限を template の {{MAX_ROUNDS}} に
  # 反映する。省略時は旧 PR_ITERATION_MAX_ROUNDS を使う（後方互換）。`0` は無制限の
  # sentinel として template に文字列 `0` を渡す。template 側で表示時にどう翻訳するかは
  # template の責務（既存 template は `{{MAX_ROUNDS}}` をそのまま表示するため、`0` の
  # ときの「無制限」表記は本関数では行わず、prompt 上の数値として `0` を保持する。
  # 着手表明コメント側では `0`→`無制限` 表示に翻訳する: pi_post_processing_marker 参照）。
  local max_rounds_param="${5:-$PR_ITERATION_MAX_ROUNDS}"

  local pr_title pr_url head_ref base_ref pr_body
  pr_title=$(echo "$pr_json" | jq -r '.title // ""')
  pr_url=$(echo "$pr_json"   | jq -r '.url // ""')
  head_ref=$(echo "$pr_json" | jq -r '.headRefName // ""')
  base_ref=$(echo "$pr_json" | jq -r '.baseRefName // ""')
  pr_body=$(echo "$pr_json"  | jq -r '.body // ""')

  # title が JSON で取れていない場合（pr_json は --json title を含まないかも）は gh で補完
  if [ -z "$pr_title" ]; then
    pr_title=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json title --jq '.title // ""' 2>/dev/null || echo "")
  fi

  # 関連 Issue 番号: head branch (`claude/issue-N-...`) → PR body の順で抽出
  local issue_number=""
  issue_number=$(echo "$head_ref" | grep -oE 'issue-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  if [ -z "$issue_number" ]; then
    issue_number=$(echo "$pr_body" | grep -oE '#[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi

  local spec_dir=""
  local requirements_md="(関連 Issue が見つからないか、対応する requirements.md が存在しません)"
  if [ -n "$issue_number" ]; then
    local found
    found=$(ls -d "${REPO_DIR}/docs/specs/${issue_number}-"* 2>/dev/null | head -1 || true)
    if [ -n "$found" ] && [ -f "${found}/requirements.md" ]; then
      spec_dir="docs/specs/$(basename "$found")"
      requirements_md=$(cat "${found}/requirements.md")
    fi
  fi

  # PR diff は prompt に inline で埋め込まない（Issue #97: 大差分時の `Argument list
  # too long` 回避のため、`PI_PR_DIFF` 環境変数も廃止。Iteration サブエージェントが
  # template の指示に従い、自身で `gh pr diff <N> --repo <REPO>` および
  # `git diff <base>..<head> -- <path>` を Bash ツールで実行して取得する設計に切り替えた）

  # AC 3.1: 最新 review の line コメントを取得（reviews 配列の最後の要素 = 時系列で最新）
  #
  # Issue #400 Req 5.2 / 5.3: line-comment 経路にも一般コメント経路と同じ self-filter 規約
  # （`idd-claude:pr-iteration` 含むコメントを除外、他 prefix は keep）を適用する。Req 5.1
  # の通り「`idd-claude:` を含む文字列を一律除外する self-filter は新規導入しない」原則を守り、
  # PR Iteration Processor 自身の marker のみを限定除外する。
  local line_comments_json="[]"
  local reviews_json latest_review_id
  if reviews_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    latest_review_id=$(echo "$reviews_json" | jq -r 'if length > 0 then (.[length-1].id|tostring) else "" end')
    if [ -n "$latest_review_id" ]; then
      local raw_line
      if raw_line=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh api "/repos/${REPO}/pulls/${pr_number}/reviews/${latest_review_id}/comments" 2>/dev/null); then
        line_comments_json=$(echo "$raw_line" \
          | jq '[.[]
                | {id, path, line, user: (.user.login // ""), body}
                | select((.body // "") | contains("idd-claude:pr-iteration") | not)]')
      fi
    fi
  fi

  # #55: 一般コメント収集（mention 篩い分けを撤廃 + 自己投稿 / 過去 round / system 除外
  #     + 大量時 truncate）。kind に依存せず impl/design 共通で同一ロジックを通す（Req 6.2）。
  local general_comments_json
  general_comments_json=$(pi_collect_general_comments "$pr_number" "$pr_body")

  # template に変数を注入する。
  # 単一行値（PR 番号 / タイトル / URL 等）は awk -v で渡し、行内の {{KEY}} を文字列置換。
  # 複数行値（LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / REQUIREMENTS_MD）は awk -v で
  # 改行を扱えないため、export 経由で ENVIRON[] から取得し、「行全体が {{KEY}} のみ」の
  # テンプレ行をブロックごと置換する（template はその前提で書かれている）。
  # NOTE (#97): PR diff は MAX_ARG_STRLEN (131,072 B) 超過で execve() が E2BIG を返す
  # 事案を避けるため env 経由でも渡さない。Iteration サブエージェントが Bash で取得する。
  if [ ! -f "$tmpl_path" ]; then
    pi_warn "template not found: $tmpl_path"
    return 1
  fi

  # 改行入り値を子プロセスに渡すため export
  export PI_LINE_JSON="$line_comments_json"
  export PI_GENERAL_JSON="$general_comments_json"
  export PI_REQS_MD="$requirements_md"

  awk \
    -v repo="$REPO" \
    -v pr_number="$pr_number" \
    -v pr_title="$pr_title" \
    -v pr_url="$pr_url" \
    -v head_ref="$head_ref" \
    -v base_ref="$base_ref" \
    -v round="$round" \
    -v max_rounds="$max_rounds_param" \
    -v issue_number="${issue_number:-(none)}" \
    -v spec_dir="${spec_dir:-(none)}" \
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
      # 行全体が複数行プレースホルダの場合は ENVIRON 経由で展開
      if ($0 == "{{LINE_COMMENTS_JSON}}")    { print ENVIRON["PI_LINE_JSON"]; next }
      if ($0 == "{{GENERAL_COMMENTS_JSON}}") { print ENVIRON["PI_GENERAL_JSON"]; next }
      if ($0 == "{{REQUIREMENTS_MD}}")       { print ENVIRON["PI_REQS_MD"]; next }
      line = $0
      line = repl(line, "{{REPO}}", repo)
      line = repl(line, "{{PR_NUMBER}}", pr_number)
      line = repl(line, "{{PR_TITLE}}", pr_title)
      line = repl(line, "{{PR_URL}}", pr_url)
      line = repl(line, "{{HEAD_REF}}", head_ref)
      line = repl(line, "{{BASE_REF}}", base_ref)
      line = repl(line, "{{ROUND}}", round)
      line = repl(line, "{{MAX_ROUNDS}}", max_rounds)
      line = repl(line, "{{ISSUE_NUMBER}}", issue_number)
      line = repl(line, "{{SPEC_DIR}}", spec_dir)
      print line
    }
    ' "$tmpl_path"
  local awk_rc=$?

  unset PI_LINE_JSON PI_GENERAL_JSON PI_REQS_MD
  return $awk_rc
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_detect_quota_soft_fail: stream-json から Claude Max 5h quota の警告閾値到達を検知
#   入力: stdin に Claude `--output-format stream-json` の出力（1 行 1 JSON）
#   出力: stdout に検出 1 件 1 行（タブ区切り）。検出無しなら無出力。
#         形式: <detection_path>\t<surpassed_threshold>
#           detection_path: 現状 `rate_limit_warning` 固定
#           surpassed_threshold: 検出時の surpassedThreshold 値（小数文字列）
#   返り値: 0 固定（解析失敗行・非該当行は無視して継続。`qa_detect_rate_limit` と同じ
#           resilience 設計 / Req 5.4 互換）
#
#   検出条件 (#118 Req 1.1):
#     - `type == "rate_limit_event"` かつ
#     - `status == "allowed_warning"`（top-level）または
#       `rate_limit_info.status == "allowed_warning"`（ネスト位置）かつ
#     - `surpassedThreshold >= 0.9`（top-level の `surpassedThreshold` または
#       `rate_limit_info.surpassedThreshold` のどちらかが 0.9 以上）
#
#   この関数は `QUOTA_AWARE_ENABLED` 設定とは独立に呼ばれる（Req 5.1）。
#   `qa_detect_rate_limit` とは独立した関数として配置（Req 5.3: dispatcher 連携なし）。
# ─────────────────────────────────────────────────────────────────────────────
pi_detect_quota_soft_fail() {
  jq -R -r '
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j

    # status を top-level / ネスト位置の両方で探索
    | (
        ($j.status? // ($j.rate_limit_info? // {}).status? // "")
      ) as $status

    # surpassedThreshold を top-level / ネスト位置の両方で探索
    | (
        ($j.surpassedThreshold? // ($j.rate_limit_info? // {}).surpassedThreshold? // null)
      ) as $threshold

    # type == "rate_limit_event" かつ status == "allowed_warning" かつ
    # threshold が数値かつ >= 0.9 のときのみ出力
    | select(
        $j.type? == "rate_limit_event"
        and $status == "allowed_warning"
        and ($threshold | type) == "number"
        and $threshold >= 0.9
      )

    | "rate_limit_warning\t\($threshold)"
  ' 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_branch_is_claude_pr_head: branch 名が auto-commit 許可規約に一致するか判定
#   入力: $1 = branch 名
#   返り値: 0 = 一致（`claude/issue-<N>-<slug>` 形式）/ 1 = 不一致
#
#   人間の branch に対する誤 auto-commit 防止のガード（#118 Req 3.2 / 3.4）。
#   現状は `^claude/issue-[0-9]+-` で固定（Out of Scope: branch 命名規約拡張）。
# ─────────────────────────────────────────────────────────────────────────────
pi_branch_is_claude_pr_head() {
  local branch="${1:-}"
  [[ "$branch" =~ ^claude/issue-[0-9]+- ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_auto_commit_and_push: 指定 branch に対して未コミット差分を `git add -A` →
#   `git commit -m "$msg"` → `git push origin <branch>` で退避する
#   入力: $1 = commit message（1 行目）。本文 + Co-Authored-By を関数側で付与する。
#         $2 = branch 名（push 先 / safety 用に呼び出し時点の current branch と一致前提）
#   返り値: 0 = 成功 / 1 = 失敗（add / commit / push のいずれか）
#
#   設計判断:
#     - `git add -A` で削除も含む全変更を取り込む（中途終了時の意図不明差分を漏らさない）。
#     - commit には `Co-Authored-By: Claude <noreply@anthropic.com>` を含める
#       （#118 Req 1.3 / 2.3 / 3.3 で固定）。
#     - push は plain `git push origin <branch>`（force 系を使わない）。push 失敗は
#       上位で WARN 扱い（Req 1.5 / 2.4 / 3.5）。
#     - 呼び出し前に `pi_branch_is_claude_pr_head` でガードする責務は呼び出し元。
# ─────────────────────────────────────────────────────────────────────────────
pi_auto_commit_and_push() {
  local msg="$1"
  local branch="$2"
  local full_msg
  full_msg=$(printf '%s\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' "$msg")

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git add -A >/dev/null 2>&1; then
    pi_warn "auto-commit: git add -A に失敗 (branch=${branch})"
    return 1
  fi
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git commit -m "$full_msg" >/dev/null 2>&1; then
    pi_warn "auto-commit: git commit に失敗 (branch=${branch})"
    return 1
  fi
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" git push origin "$branch" >/dev/null 2>&1; then
    pi_warn "auto-commit: git push origin ${branch} に失敗"
    return 1
  fi
  return 0
}
