#!/usr/bin/env bash
# shellcheck shell=bash
# pr-design-reviewer.sh — watcher の Design PR Reviewer モジュール (#407)
#
# 用途:
#   設計 PR (`claude/issue-<N>-design-<slug>`) に対する独立 Claude 設計レビュアの本体。
#   `DESIGN_REVIEWER_ENABLED`（#432 で既定 ON / `=false` 厳密一致のみ OFF）が有効なとき
#   open / non-draft の設計 PR を検出し、
#   `docs/specs/<N>-<slug>/{requirements.md, design.md, tasks.md}` の 3 観点
#   （AC カバレッジ / design⇄tasks 整合 / Traceability）で `approve` / `reject` を判定する。
#   判定結果は `claude-review` commit status の publish と `needs-iteration` ラベルの
#   付与・解消の根拠となり、人間運用の `awaiting-design-review` ラベルゲートと OR 条件で
#   merge 経路を成立させる（admin-merge への依存を解消）。
#
#   設計の詳細は docs/specs/407-feat-pr-reviewer-pr-claude-review-claude/design.md を参照。
#
#   - opt-out gate 判定: pdr_gate_enabled（#432 で既定 ON 化）
#     既に正規化済みの `DESIGN_REVIEWER_ENABLED`（issue-watcher.sh の Config で
#     `case false) ... *) true` に正規化済み = `=false` 厳密一致のみ OFF・それ以外は ON）を
#     厳密 `=true` で評価する。重複正規化は行わない（既定値の責任は呼び出し側 / Req 1.1〜1.5）。
#   - runtime 資産不在時の graceful no-op: pdr_prompt_asset_resolvable（#432 Req 2）
#     既定 ON 化に伴い installer 未再実行の repo がプロンプトテンプレ不在経路に乗りやすくなる
#     ため、dispatcher entry（process_pr_design_reviewer 冒頭 / gate 通過後・候補取得前）で
#     必須プロンプト資産の解決可否を 1 回検査し、解決不能なら WARN 1 行 + return 0（no-op）。
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
# pdr_gate_enabled: opt-out gate 評価（既に正規化済みの env を厳密一致で判定 / #432 既定 ON）
#   入力: なし（env のみ参照）
#   出力: なし
#   戻り値: 0 = ON / 1 = OFF
#
#   issue-watcher.sh の Config ブロックで `DESIGN_REVIEWER_ENABLED` は
#   `case false) ... *) true` で正規化されている（#432 で既定 ON / `=false` 厳密一致のみ OFF・
#   未設定 / typo / 大文字違い等はすべて ON）。本関数は正規化済み値を厳密 `=true` 判定のみ
#   行う（重複正規化はしない）。Config が常に先に正規化するため、防御的 default も
#   既定 ON 意味論に揃えて `:-true` とする（挙動には影響しない / コメントとの一貫性 / Req 1.1）。
# ─────────────────────────────────────────────────────────────────────────────
pdr_gate_enabled() {
  if [ "${DESIGN_REVIEWER_ENABLED:-true}" = "true" ]; then
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_prompt_asset_resolvable: 設計 Reviewer の必須プロンプト資産が解決できるかを検査
#   入力: なし（env のみ参照）
#   出力: なし
#   戻り値: 0 = 解決可能 / 1 = 解決不能（呼び出し元で WARN 1 行 + no-op return）
#
#   Req: 2.1 / 2.2 / 2.3 / 2.4（runtime 資産不在時の graceful no-op / fail-closed で永久
#        BLOCKED を作らない）
#
#   解決順序は pdr_invoke_reviewer の prompt 解決ロジックと一致させる:
#     (a) `DESIGN_REVIEWER_PROMPT` env が非空 → その値を本文として使うため解決可能 (rc=0)
#     (b) 空なら `$HOME/bin/design-review-prompt.tmpl` が読めるファイルとして存在するか検査
#         - HOME 解決不能 / テンプレ不在 / 読めない → 解決不能 (rc=1)
#   - 副作用なし（read-only / claude / gh / git 不起動）。
#   - 既定 ON 化（#432）後、installer 未再実行の repo はテンプレ不在経路に乗りやすいため、
#     per-PR WARN（claude 失敗扱いで pending 据え置き）の連発を避け、processor 全体を 1 回の
#     WARN で no-op return させる安全弁の判定本体。
# ─────────────────────────────────────────────────────────────────────────────
pdr_prompt_asset_resolvable() {
  if [ -n "${DESIGN_REVIEWER_PROMPT:-}" ]; then
    return 0
  fi
  local home_dir="${HOME:-}"
  if [ -z "$home_dir" ]; then
    return 1
  fi
  local tmpl_path="${home_dir}/bin/design-review-prompt.tmpl"
  if [ -f "$tmpl_path" ] && [ -r "$tmpl_path" ]; then
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

# ─────────────────────────────────────────────────────────────────────────────
# pdr_invoke_reviewer: 設計 Reviewer agent を 1 回呼び出し、判定本文を stdout に返す
#   入力: $1 = pr_number
#         $2 = sha (head sha; 7〜40 桁 hex)
#         $3 = head_ref
#         $4 = base_ref
#         $5 = spec_dir_rel (docs/specs/<N>-<slug>/ パス。空 / 不在なら `(none)`)
#   出力: stdout に Claude の生応答本文（text または JSON envelope の `.result`）
#   戻り値: 0 = ok / 1 = claude exec 失敗（rc != 0 / timeout / prompt 解決失敗）
#           2 = workspace-modified 検出（read-only invariant 違反）
#           3 = spec 本文取得不能（fail-closed / claude 未起動 / Issue #433 Req 2.5）
#
#   Req: 1.2 / 1.5 / 3.3 / 5.4 / 6.5 / NFR 4.1
#        + Issue #433 Req 1.1〜1.5 / 2.1〜2.5 / 3.1 / 3.2 / 4.3
#
#   挙動:
#     1. PR 番号 / SHA / base_ref / head_ref の入力検証（pr_substitute_placeholders 流）
#        - PR 番号: ^[0-9]+$ 厳密
#        - SHA: ^[0-9a-f]{7,40}$ 厳密
#        - base_ref / head_ref: shell metacharacter（;|&`$(）混入検査
#     2. prompt 本文の解決順序:
#        a. `DESIGN_REVIEWER_PROMPT` env が非空 → その値を本文として直接使う
#        b. 空なら `$HOME/bin/design-review-prompt.tmpl` をファイルから読む（既定）
#        c. ファイル不在 / HOME 解決不能 → pdr_warn + rc=1
#     3. 9 プレースホルダ置換（bash パラメータ展開 / 既存 adj_classify_findings 流）:
#        {PR} / {SHA} / {BASE} / {HEAD} / {ISSUE_NUMBER} / {SPEC_DIR} /
#        {REQUIREMENTS_MD} / {DESIGN_MD} / {TASKS_MD}
#        - spec 本文は **head ブランチの git ref（`origin/<head_ref>`）** から取得する
#          （`git cat-file -e ... && git show ...` / adjudicator.sh L693-704 と同方式 /
#          Issue #433 Req 1.1〜1.5）。watcher 作業ツリーは base にチェックアウト中で新規
#          設計 PR の spec dir は存在しないため、作業ツリーの `[ -d ]`+`cat` では `(none)`
#          に倒れていた（#433 のバグ）。head ref から取得することで未マージの spec も読める。
#        - 取得できないファイルのみ `(none)` に倒す（取得できたものは実本文 / Req 1.5）
#     3'. fail-closed 判定（claude 起動 **前**に評価 / Issue #433 Req 2）:
#        - spec_dir_rel が空（head から解決不能）→ rc=3 で打ち切り（Req 2.2）
#        - 3 ファイルすべて取得不能（1 つも取得できない）→ rc=3 で打ち切り（Req 2.1, 2.3）
#          かつ spec_dir_rel は解決済みなら WARN を 1 行出す（Req 3.1）
#        - rc=3 は呼び出し元 pdr_run_review_for_pr が既存 pending 据え置き（rc=2 相当）へ
#          写像する。claude 判定リクエストは発行しない（Req 2.5）
#     4. mktemp で prompt 一時ファイル + stdout / stderr tempfile を作成、trap で削除
#     5. claude 起動:
#          timeout "$DESIGN_REVIEWER_EXEC_TIMEOUT" \
#            claude -p "$(cat prompt_file)" \
#                   --output-format "$DESIGN_REVIEWER_OUTPUT_FORMAT" \
#                   --permission-mode plan \
#                   --model "$DESIGN_REVIEWER_MODEL"
#        - `--permission-mode plan` で Claude 側で Bash / Edit / Write を構造的にブロック
#          （read-only invariant の defense-in-depth）
#     6. read-only invariant 検査: `git status --porcelain` でワークツリー変更を検出。
#        検出時は tracked 変更を破棄し rc=2 を返す（pr_execute_review_command Decision 8
#        / adj_classify_findings 同方針）
#     7. JSON envelope（`--output-format json` 時）なら `.result` を抽出。それ以外は
#        stdout をそのまま返す（呼び出し元 pdr_parse_verdict が text / JSON の両方をハンドル）
# ─────────────────────────────────────────────────────────────────────────────
pdr_invoke_reviewer() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local head_ref="${3:-}"
  local base_ref="${4:-}"
  local spec_dir_rel="${5:-}"

  # 入力検証
  case "$pr_number" in
    ''|*[!0-9]*)
      pdr_warn "pdr_invoke_reviewer: PR 番号が不正 (pr='${pr_number}')"
      return 1
      ;;
  esac
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    pdr_warn "pdr_invoke_reviewer: SHA が不正 (sha='${sha}')"
    return 1
  fi
  # shell metacharacter 検査（base_ref / head_ref / spec_dir_rel）
  local v
  for v in "$base_ref" "$head_ref" "$spec_dir_rel"; do
    # shellcheck disable=SC2016
    case "$v" in
      *';'* | *'|'* | *'&'* | *'`'* | *'$('* )
        pdr_warn "pdr_invoke_reviewer: shell metacharacter 検出 (pr=#${pr_number} base='${base_ref}' head='${head_ref}' spec='${spec_dir_rel}')"
        return 1
        ;;
    esac
  done

  # prompt 本文の解決
  local prompt_body=""
  if [ -n "${DESIGN_REVIEWER_PROMPT:-}" ]; then
    prompt_body="${DESIGN_REVIEWER_PROMPT}"
  else
    local home_dir="${HOME:-}"
    if [ -z "$home_dir" ]; then
      pdr_warn "pdr_invoke_reviewer: HOME 解決不能のため design-review-prompt.tmpl を読めません"
      return 1
    fi
    local tmpl_path="${home_dir}/bin/design-review-prompt.tmpl"
    if [ ! -f "$tmpl_path" ]; then
      pdr_warn "pdr_invoke_reviewer: ${tmpl_path} が存在しません"
      return 1
    fi
    if ! prompt_body=$(cat "$tmpl_path" 2>/dev/null); then
      pdr_warn "pdr_invoke_reviewer: ${tmpl_path} の読み込みに失敗"
      return 1
    fi
  fi

  # {ISSUE_NUMBER} は head_ref から抽出（claude/issue-<N>-...）
  local issue_number="(none)"
  if [[ "$head_ref" =~ ^claude/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi

  # {SPEC_DIR} / {REQUIREMENTS_MD} / {DESIGN_MD} / {TASKS_MD} 解決
  # spec 本文は **head ブランチの git ref**（`origin/<head_ref>`）から取得する。watcher の
  # 作業ツリーは base にチェックアウト中で新規設計 PR の spec dir は存在しないため、作業
  # ツリーの `[ -d ]`+`cat` では全部 `(none)` に倒れて空虚 approve になっていた（#433）。
  # adjudicator.sh `adj_read_reviewer_verdict`（L693-704）の確立済みパターン
  # （`git cat-file -e "origin/<ref>:<path>"` で存在確認 → `git show ...` で本文取得）を踏襲。
  local spec_dir_val="(none)"
  local requirements_md_val="(none)"
  local design_md_val="(none)"
  local tasks_md_val="(none)"
  local fetched_count=0
  local git_timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  if [ -n "$spec_dir_rel" ]; then
    spec_dir_val="$spec_dir_rel"
    # head_ref はここまでで shell metacharacter 検査済み。spec_dir_rel も同検査済みのため
    # `origin/<head_ref>:<path>` git revision に安全に埋め込める（Issue #318 / `--` でも
    # オプション解釈を打ち切る）。
    local _file _path _body
    for _file in requirements design tasks; do
      _path="${spec_dir_rel}/${_file}.md"
      if timeout "$git_timeout_s" git cat-file -e "origin/${head_ref}:${_path}" 2>/dev/null; then
        if _body=$(timeout "$git_timeout_s" git show "origin/${head_ref}:${_path}" 2>/dev/null) \
            && [ -n "$_body" ]; then
          case "$_file" in
            requirements) requirements_md_val="$_body" ;;
            design)       design_md_val="$_body" ;;
            tasks)        tasks_md_val="$_body" ;;
          esac
          fetched_count=$((fetched_count + 1))
        fi
      fi
    done
  fi

  # fail-closed 判定（claude 起動 **前**に評価 / Issue #433 Req 2）。
  # spec dir 解決不能（Req 2.2）または 3 ファイルすべて取得不能（Req 2.1, 2.3）の場合は、
  # LLM 判定リクエストを発行せず rc=3 で打ち切る（Req 2.5）。呼び出し元が既存 pending 据え
  # 置き（rc=2 相当）へ写像する。
  if [ -z "$spec_dir_rel" ]; then
    pdr_warn "pdr_invoke_reviewer: PR #${pr_number}: spec dir が head ブランチ（origin/${head_ref}）から解決不能 → fail-closed（approve を publish しない / Req 2.2）"
    return 3
  fi
  if [ "$fetched_count" -eq 0 ]; then
    # spec dir は解決済みなのに本文が 1 つも取れない = ログが健全に見えたまま空虚 approve に
    # なる罠。解決済みパスと取得不能の事実を併記して WARN を 1 行出す（Req 3.1）。verdict=approve
    # 形の完了ログはこの経路では出さない（Req 3.2 / 呼び出し元 rc=3 写像で担保）。
    pdr_warn "pdr_invoke_reviewer: PR #${pr_number}: spec dir 解決済み（${spec_dir_rel}）だが origin/${head_ref} から spec 本文を 1 つも取得できず → fail-closed（approve を publish しない / Req 2.3 / 3.1）"
    return 3
  fi

  # base / head の `(none)` 既定値
  local base_val="${base_ref:-(none)}"
  local head_val="${head_ref:-(none)}"
  [ -z "$base_val" ] && base_val="(none)"
  [ -z "$head_val" ] && head_val="(none)"

  # プレースホルダ置換（bash パラメータ展開）
  local rendered="$prompt_body"
  rendered="${rendered//\{PR\}/$pr_number}"
  rendered="${rendered//\{SHA\}/$sha}"
  rendered="${rendered//\{BASE\}/$base_val}"
  rendered="${rendered//\{HEAD\}/$head_val}"
  rendered="${rendered//\{ISSUE_NUMBER\}/$issue_number}"
  rendered="${rendered//\{SPEC_DIR\}/$spec_dir_val}"
  rendered="${rendered//\{REQUIREMENTS_MD\}/$requirements_md_val}"
  rendered="${rendered//\{DESIGN_MD\}/$design_md_val}"
  rendered="${rendered//\{TASKS_MD\}/$tasks_md_val}"

  # mktemp で一時ファイル作成 + trap で削除
  local prompt_file out_file err_file
  if ! prompt_file=$(mktemp -t idd-claude-design-reviewer-prompt.XXXXXX 2>/dev/null); then
    pdr_warn "pdr_invoke_reviewer: prompt 一時ファイル作成に失敗"
    return 1
  fi
  if ! out_file=$(mktemp -t idd-claude-design-reviewer-out.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" 2>/dev/null || true
    pdr_warn "pdr_invoke_reviewer: out tempfile 作成に失敗"
    return 1
  fi
  if ! err_file=$(mktemp -t idd-claude-design-reviewer-err.XXXXXX 2>/dev/null); then
    rm -f "$prompt_file" "$out_file" 2>/dev/null || true
    pdr_warn "pdr_invoke_reviewer: err tempfile 作成に失敗"
    return 1
  fi
  # shellcheck disable=SC2064
  trap "rm -f '$prompt_file' '$out_file' '$err_file' 2>/dev/null || true" RETURN

  printf '%s' "$rendered" > "$prompt_file"

  # claude CLI 起動
  local exec_rc=0
  local timeout_s="${DESIGN_REVIEWER_EXEC_TIMEOUT:-300}"
  local model="${DESIGN_REVIEWER_MODEL:-claude-sonnet-4-6}"
  local out_fmt="${DESIGN_REVIEWER_OUTPUT_FORMAT:-text}"

  timeout "$timeout_s" claude \
    -p "$(cat "$prompt_file")" \
    --output-format "$out_fmt" \
    --permission-mode plan \
    --model "$model" \
    >"$out_file" 2>"$err_file" || exec_rc=$?

  # read-only invariant 検査
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    git checkout -- . >/dev/null 2>&1 || true
    pdr_warn "pdr_invoke_reviewer: workspace-modified を検出（read-only 違反）"
    return 2
  fi

  if [ "$exec_rc" -ne 0 ]; then
    local err_excerpt
    err_excerpt=$(tail -c 512 "$err_file" 2>/dev/null || true)
    pdr_warn "pdr_invoke_reviewer: claude exec 失敗 (rc=${exec_rc}, err_tail='${err_excerpt//$'\n'/ }')"
    return 1
  fi

  # `--output-format json` 経路では `.result` フィールドに本文が埋め込まれる
  if [ "$out_fmt" = "json" ]; then
    local result_body
    if ! result_body=$(jq -r '.result // empty' "$out_file" 2>/dev/null); then
      # JSON envelope ではない（生 JSON / 生 text）→ そのまま流す
      cat "$out_file"
      return 0
    fi
    if [ -z "$result_body" ]; then
      cat "$out_file"
      return 0
    fi
    printf '%s' "$result_body"
    return 0
  fi

  cat "$out_file"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_parse_verdict: 判定本文から verdict と 3 観点 reason を TSV 1 行で stdout に返す
#   入力: stdin に raw 本文（text または JSON）
#         $1 = 形式ヒント（text | json）
#   出力: stdout に TSV 1 行
#          verdict\tac_reason\tdt_reason\ttr_reason
#         - verdict: approve | reject | "" (parse 失敗)
#         - 各 reason: 自然言語 1 行（タブ・改行は空白に正規化）
#   戻り値: 0 = ok（最終 VERDICT 行 + 3 観点抽出成功）
#           1 = parse 失敗（呼び出し元で保守的 approve に倒す / Req 2.4）
#
#   Req: 2.2 / 2.3 / 2.4 / 2.5
#
#   挙動:
#     - text 形式: 最終行から `VERDICT: approve|reject` を grep。3 観点見出し配下の
#       `- 根拠: ...` 行を抽出（順序: AC カバレッジ → design⇄tasks → Traceability）
#     - JSON 形式: jq で `.verdict` / `.ac_coverage.reason` / `.design_tasks_alignment.reason` /
#       `.traceability.reason` を抽出
#     - 抽出失敗時は呼び出し元（pdr_run_review_for_pr）が保守的 approve に倒す
# ─────────────────────────────────────────────────────────────────────────────
pdr_parse_verdict() {
  local fmt="${1:-text}"
  local body
  body=$(cat)

  if [ -z "$body" ]; then
    return 1
  fi

  local verdict="" ac_reason="" dt_reason="" tr_reason=""

  if [ "$fmt" = "json" ]; then
    # 前置き散文 / code fence を剥がしてから JSON parse を試行
    # `{` から `}` までを雑に切り出して valid JSON 検証
    local stripped
    stripped=$(printf '%s' "$body" | awk '
      BEGIN { started = 0; depth = 0 }
      {
        for (i = 1; i <= length($0); i++) {
          ch = substr($0, i, 1)
          if (!started) {
            if (ch == "{") { started = 1; depth = 1; printf "%s", ch }
          } else {
            printf "%s", ch
            if (ch == "{") depth++
            else if (ch == "}") {
              depth--
              if (depth == 0) { printf "\n"; exit }
            }
          }
        }
        if (started) printf "\n"
      }
    ')
    if printf '%s' "$stripped" | jq -e '.' >/dev/null 2>&1; then
      verdict=$(printf '%s' "$stripped" | jq -r '.verdict // empty' 2>/dev/null || true)
      ac_reason=$(printf '%s' "$stripped" | jq -r '.ac_coverage.reason // empty' 2>/dev/null || true)
      dt_reason=$(printf '%s' "$stripped" | jq -r '.design_tasks_alignment.reason // empty' 2>/dev/null || true)
      tr_reason=$(printf '%s' "$stripped" | jq -r '.traceability.reason // empty' 2>/dev/null || true)
    fi
  fi

  # text 形式 fallback（JSON parse 失敗時も含む）
  if [ -z "$verdict" ]; then
    # 最終行から VERDICT を抽出
    verdict=$(printf '%s' "$body" \
      | grep -oE '^VERDICT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' 2>/dev/null \
      | tail -n 1 \
      | sed -E 's/^VERDICT:[[:space:]]+(approve|reject).*$/\1/' || true)
  fi

  # text 形式の 3 観点 reason 抽出（見出し配下の最初の `- 根拠:` 行）
  if [ -z "$ac_reason" ]; then
    ac_reason=$(printf '%s' "$body" | awk '
      /^### AC カバレッジ/ { in_sec = 1; next }
      in_sec && /^### / && !/^### AC カバレッジ/ { in_sec = 0 }
      in_sec && /^- 根拠:[[:space:]]+/ {
        sub(/^- 根拠:[[:space:]]+/, "")
        gsub(/[\t\n]/, " ")
        print
        exit
      }
    ' || true)
  fi
  if [ -z "$dt_reason" ]; then
    dt_reason=$(printf '%s' "$body" | awk '
      /^### design⇄tasks 整合/ { in_sec = 1; next }
      in_sec && /^### / && !/^### design⇄tasks 整合/ { in_sec = 0 }
      in_sec && /^- 根拠:[[:space:]]+/ {
        sub(/^- 根拠:[[:space:]]+/, "")
        gsub(/[\t\n]/, " ")
        print
        exit
      }
    ' || true)
  fi
  if [ -z "$tr_reason" ]; then
    tr_reason=$(printf '%s' "$body" | awk '
      /^### Traceability/ { in_sec = 1; next }
      in_sec && /^### / && !/^### Traceability/ { in_sec = 0 }
      in_sec && /^- 根拠:[[:space:]]+/ {
        sub(/^- 根拠:[[:space:]]+/, "")
        gsub(/[\t\n]/, " ")
        print
        exit
      }
    ' || true)
  fi

  # verdict が "" の場合（VERDICT 行が不在 / 値が approve/reject 以外）→ parse 失敗
  case "$verdict" in
    approve|reject) : ;;
    *)
      return 1
      ;;
  esac

  # TSV 1 行で stdout に流す
  printf '%s\t%s\t%s\t%s\n' "$verdict" "$ac_reason" "$dt_reason" "$tr_reason"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_validate_verdict: verdict / reason の妥当性を schema 検証
#   入力: $1 = verdict
#         $2 = ac_reason
#         $3 = dt_reason
#         $4 = tr_reason
#   戻り値: 0 = valid / 1 = invalid（呼び出し元で fail-safe = approve に倒す）
#   出力: invalid 時のみ pdr_warn を 1 行 stderr に出す
#
#   Req: 2.4 / 2.5
#
#   検証項目:
#     1. verdict が `approve` または `reject` の lowercase 厳密一致
#     2. 3 観点 reason がいずれも非空（空 = parse 失敗の暗黙シグナル / Req 2.5）
# ─────────────────────────────────────────────────────────────────────────────
pdr_validate_verdict() {
  local verdict="${1:-}"
  local ac_reason="${2:-}"
  local dt_reason="${3:-}"
  local tr_reason="${4:-}"

  case "$verdict" in
    approve|reject) : ;;
    *)
      pdr_warn "pdr_validate_verdict: verdict が不正 ('${verdict}')"
      return 1
      ;;
  esac

  if [ -z "$ac_reason" ] || [ -z "$dt_reason" ] || [ -z "$tr_reason" ]; then
    pdr_warn "pdr_validate_verdict: 3 観点 reason に空が含まれる (ac='${ac_reason}' dt='${dt_reason}' tr='${tr_reason}')"
    return 1
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_apply_label_decision: 判定結果に基づき needs-iteration ラベルを add/remove
#   入力: $1 = pr_number, $2 = verdict (approve | reject)
#   出力: なし（log のみ）
#   戻り値: 0 = ok / 1 = ラベル操作失敗 / 2 = 入力検証失敗
#
#   Req: 4.1（reject → needs-iteration 付与）/ 4.2（approve → 解消）
#
#   挙動:
#     - verdict=reject → `gh pr edit --add-label needs-iteration`（既付与で冪等 no-op）
#     - verdict=approve → `gh pr edit --remove-label needs-iteration`（未付与で冪等 no-op）
#     - gh の add/remove-label は既存ラベル / 不在ラベルに対しても idempotent。
#       追加前 / 削除前の現状確認は行わず、`gh` の冪等性に委ねる
#       （adj_apply_label_decision と同方針 / NFR 1.1 観測ログ規約の最小化）。
#     - 既存ラベル名 `needs-iteration` を共有する（Req 6.4）。新規ラベルは追加しない。
# ─────────────────────────────────────────────────────────────────────────────
pdr_apply_label_decision() {
  local pr_number="${1:-}"
  local verdict="${2:-}"

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pdr_warn "pdr_apply_label_decision: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  case "$verdict" in
    approve|reject) : ;;
    *)
      pdr_warn "pdr_apply_label_decision: 無効な verdict '${verdict}'"
      return 2
      ;;
  esac

  local label="${LABEL_NEEDS_ITERATION:-needs-iteration}"
  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  if [ "$verdict" = "reject" ]; then
    if ! timeout "$timeout_s" \
        gh pr edit "$pr_number" --repo "$REPO" --add-label "$label" >/dev/null 2>&1; then
      pdr_warn "pdr_apply_label_decision: PR #${pr_number}: ${label} 付与失敗"
      return 1
    fi
    pdr_log "PR #${pr_number}: ${label} を付与（verdict=reject / 既付与で冪等 no-op）"
  else
    if ! timeout "$timeout_s" \
        gh pr edit "$pr_number" --repo "$REPO" --remove-label "$label" >/dev/null 2>&1; then
      pdr_warn "pdr_apply_label_decision: PR #${pr_number}: ${label} 解消失敗"
      return 1
    fi
    pdr_log "PR #${pr_number}: ${label} を解消（verdict=approve / 未付与で冪等 no-op）"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_apply_status_decision: 判定結果に基づき claude-review commit status を publish
#   入力: $1 = pr_number, $2 = sha, $3 = verdict, $4 = pr_url
#   出力: なし（log は pr_publish_claude_status / pr_publish_commit_status 側）
#   戻り値: pr_publish_claude_status の戻り値（0/1/2/3/4）
#
#   Req: 3.1（approve → success）/ 3.2（reject → failure）/ 3.4（context 名統一）/
#        3.5（OR 条件で awaiting-design-review と併存 = status のみ操作してラベル不干渉）/
#        7.2（既存 pr-reviewer.sh の publish 経路は read-only で流用 / 経路独立）
#
#   挙動:
#     - verdict=approve → `pr_publish_claude_status` を `result=approve` で呼ぶ → state=success
#     - verdict=reject  → `pr_publish_claude_status` を `result=reject` で呼ぶ → state=failure
#     - context 名は `claude-review`（既存 impl PR 経路と統一 / Req 3.4）
#     - awaiting-design-review ラベルには触れない（Req 3.5 OR 条件併存）
# ─────────────────────────────────────────────────────────────────────────────
pdr_apply_status_decision() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local verdict="${3:-}"
  local pr_url="${4:-}"

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pdr_warn "pdr_apply_status_decision: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    pdr_warn "pdr_apply_status_decision: 無効な sha '${sha}'"
    return 2
  fi
  case "$verdict" in
    approve|reject) : ;;
    *)
      pdr_warn "pdr_apply_status_decision: 無効な verdict '${verdict}'"
      return 2
      ;;
  esac

  pdr_log "PR #${pr_number}: claude-review status publish (design Reviewer / verdict=${verdict} sha=${sha})"
  pr_publish_claude_status "$pr_number" "$sha" "$verdict" "$pr_url"
  return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_post_decision_comment: 判定結果サマリを PR コメントに投稿
#   入力: $1 = pr_number, $2 = sha, $3 = verdict, $4 = ac_reason,
#         $5 = dt_reason, $6 = tr_reason
#   出力: なし（log のみ）
#   戻り値: 0 = ok / 1 = 投稿失敗 / 2 = 入力検証失敗
#
#   Req: 5.1（PR コメント or ログで観測可能）/ 5.3（hidden marker prefix が
#        pi self-filter `idd-claude:pr-iteration` と非衝突 / NFR 1.2）
#
#   挙動:
#     - hidden marker `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->` を
#       本文末尾に付与
#     - 本関数は重複判定を行わない（呼び出し元 pdr_run_review_for_pr が
#       `pdr_already_processed` で per-sha dedup を済ませている前提）
#     - 既存 needs-iteration ラベル / claude-review context との連携は本コメントには含めない
#       （コメントは観測用 / status 操作は pdr_apply_status_decision の責務）
# ─────────────────────────────────────────────────────────────────────────────
pdr_post_decision_comment() {
  local pr_number="${1:-}"
  local sha="${2:-}"
  local verdict="${3:-}"
  local ac_reason="${4:-}"
  local dt_reason="${5:-}"
  local tr_reason="${6:-}"

  if ! [[ "$pr_number" =~ ^[0-9]+$ ]]; then
    pdr_warn "pdr_post_decision_comment: 無効な PR 番号 '${pr_number}'"
    return 2
  fi
  if ! [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]]; then
    pdr_warn "pdr_post_decision_comment: 無効な sha '${sha}'"
    return 2
  fi
  case "$verdict" in
    approve|reject) : ;;
    *)
      pdr_warn "pdr_post_decision_comment: 無効な verdict '${verdict}'"
      return 2
      ;;
  esac

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"

  # コメント本文の組み立て。reason 値は未信頼入力（Claude 応答由来）のため printf 経由で
  # bash 展開させない（本文は gh CLI に --body で渡されるので shell metachar は問題ない
  # が、本文中の `%` を printf format に解釈させないため `%%` ではなく fixed string `%s` で
  # 流す）。
  local body
  body=$(printf '## 設計レビュー判定（自動）\n\n- **VERDICT**: %s\n\n### AC カバレッジ\n- %s\n\n### design⇄tasks 整合\n- %s\n\n### Traceability\n- %s\n\n<!-- idd-claude:pr-design-reviewer sha=%s kind=decision -->\n' \
    "$verdict" "$ac_reason" "$dt_reason" "$tr_reason" "$sha")

  if ! timeout "$timeout_s" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    pdr_warn "PR #${pr_number}: 判定コメント投稿失敗（sha=${sha} verdict=${verdict}）"
    return 1
  fi
  pdr_log "PR #${pr_number}: 判定コメント投稿（sha=${sha} verdict=${verdict}）"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_resolve_spec_dir_from_head_ref: head_ref から docs/specs/<N>-<slug>/ パスを解決
#   入力: $1 = head_ref（例: claude/issue-407-design-foo）
#   出力: stdout に相対パス（解決不能時は空文字列）
#   戻り値: 0 固定（fail-safe）
#
#   - head_ref から Issue 番号を抽出（claude/issue-<N>-...）
#   - `git ls-tree --name-only origin/<head_ref> -- docs/specs/` で <N>- 始まりの spec
#     ディレクトリを解決（pr_publish_claude_status_from_branch / adj_resolve_spec_dir_from_head_ref
#     と同方針 / read-only / 副作用なし）
# ─────────────────────────────────────────────────────────────────────────────
pdr_resolve_spec_dir_from_head_ref() {
  local head_ref="${1:-}"
  if [ -z "$head_ref" ]; then
    printf '%s\n' ""
    return 0
  fi

  local issue_number=""
  if [[ "$head_ref" =~ ^claude/issue-([0-9]+)- ]]; then
    issue_number="${BASH_REMATCH[1]}"
  fi
  if [ -z "$issue_number" ]; then
    printf '%s\n' ""
    return 0
  fi

  local timeout_s="${PR_REVIEWER_GIT_TIMEOUT:-120}"
  local tree_out spec_dir_rel=""
  if ! tree_out=$(timeout "$timeout_s" \
      git ls-tree --name-only "origin/${head_ref}" -- "docs/specs/" 2>/dev/null); then
    printf '%s\n' ""
    return 0
  fi
  spec_dir_rel=$(printf '%s\n' "$tree_out" \
    | awk -v n="${issue_number}-" -F/ '$3 != "" && index($3, n) == 1 { print "docs/specs/" $3; exit }')
  printf '%s\n' "$spec_dir_rel"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pdr_run_review_for_pr: 1 PR 分の判定をオーケストレートする
#   入力: $1 = pr_json（pdr_fetch_design_prs の単一要素）
#   出力: なし（log のみ）
#   戻り値: 0 = ok / 1 = skip（pattern 不一致 / dedup hit）/ 2 = claude 失敗（pending 据え置き）
#
#   Req: 1.1 / 1.2 / 1.5 / 2.4 / 3.1 / 3.2 / 3.3 / 4.1 / 4.2 / 5.1 / 5.2 / 5.4 /
#        NFR 1.1（観測ログ 10 行以内に収める） / NFR 4.1
#
#   フロー:
#     1. pr_json から pr_number / head_ref / base_ref / sha / pr_url を抽出
#     2. head pattern 不一致なら skip (rc=1)
#     3. per-sha dedup hit なら skip (rc=1) — pdr_log で 1 行サマリ
#     4. spec dir を head から解決（不在でも保守的 approve 経路に進める）
#     5. claude を 1 回呼び出し（pdr_invoke_reviewer）
#        - exec 失敗 / workspace-modified → publish せず pending 据え置き (rc=2 / Req 3.3)
#        - spec 本文取得不能（fail-closed / rc=3 / Issue #433 Req 2）→ claude 未起動で
#          publish せず pending 据え置き（rc=2 に写像 / NFR 1.4 で exit code 意味不変）
#     6. text/JSON を parse（pdr_parse_verdict）。失敗時は保守的 approve に倒す（Req 2.4）
#        （※ fail-closed は spec 本文取得成功時には適用しない / Issue #433 Req 4.3）
#     7. schema 検証（pdr_validate_verdict）。失敗時も保守的 approve に倒す（Req 2.4）
#     8. ラベル add/remove + status publish + コメント投稿（pdr_apply_label_decision /
#        pdr_apply_status_decision / pdr_post_decision_comment）
#     9. 1 行サマリログを pdr_log で出す（NFR 1.1: PR あたり ON 時のログ行数は約
#        サマリ 1 + 操作系 3〜4 = 5 行前後で 10 行以下を維持）
# ─────────────────────────────────────────────────────────────────────────────
pdr_run_review_for_pr() {
  local pr_json="${1:-}"
  if [ -z "$pr_json" ]; then
    return 1
  fi

  local pr_number head_ref base_ref sha pr_url
  pr_number=$(echo "$pr_json" | jq -r '.number // empty')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName // empty')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName // empty')
  sha=$(echo "$pr_json"       | jq -r '.headRefOid // empty')
  pr_url=$(echo "$pr_json"    | jq -r '.url // empty')

  if [ -z "$pr_number" ] || [ -z "$head_ref" ] || [ -z "$sha" ]; then
    pdr_warn "pdr_run_review_for_pr: pr_json から必須フィールドが欠落 (pr='${pr_number}' head='${head_ref}' sha='${sha}')"
    return 1
  fi

  # head pattern マッチング（Req 1.3, 7.4）
  if ! pdr_classify_design_pr "$head_ref"; then
    # 通常 process_pr_design_reviewer 側で既に filter されているが、防御的に確認
    return 1
  fi

  # per-sha dedup（Req 1.4）
  if pdr_already_processed "$pr_number" "$sha"; then
    pdr_log "PR #${pr_number}: sha=${sha} は既に判定済み（marker 検出）→ skip"
    return 1
  fi

  if [ -z "$base_ref" ] || [ "$base_ref" = "null" ]; then
    base_ref="${BASE_BRANCH:-main}"
  fi

  # spec dir 解決（不在でも保守的 approve 経路に進めるため fail-safe）
  local spec_dir_rel
  spec_dir_rel=$(pdr_resolve_spec_dir_from_head_ref "$head_ref")

  # claude 起動
  local raw_body=""
  local invoke_rc=0
  raw_body=$(pdr_invoke_reviewer "$pr_number" "$sha" "$head_ref" "$base_ref" "$spec_dir_rel") || invoke_rc=$?

  if [ "$invoke_rc" -ne 0 ]; then
    # rc=3（spec 本文取得不能 / fail-closed / Issue #433 Req 2）と
    # rc=1/2（exec-failed / timeout / workspace-modified）は、いずれも publish せず pending
    # 据え置き（Req 2.4 = 既存 exec 失敗時 rc=2 経路と同一の status / ラベル契約）に集約する。
    # marker / コメントも投稿しないため、次サイクルで自然に再試行される（Error Handling 共通動作）。
    # NFR 1.4: pdr_run_review_for_pr の exit code 意味（0/1/2）は変えず、fail-closed も rc=2 に写像。
    if [ "$invoke_rc" -eq 3 ]; then
      # Issue #433 NFR 3.1: fail-closed で pending 据え置きとなった旨を 1 行で観測可能にする。
      pdr_log "PR #${pr_number}: spec 本文取得不能で fail-closed → claude-review pending 据え置き / 次サイクルで再試行（Issue #433 Req 2 / NFR 3.1）"
    else
      pdr_log "PR #${pr_number}: claude exec 失敗 (rc=${invoke_rc}) → claude-review pending 据え置き / 次サイクルで再試行"
    fi
    return 2
  fi

  # text / JSON を parse
  local out_fmt="${DESIGN_REVIEWER_OUTPUT_FORMAT:-text}"
  local tsv=""
  local parse_rc=0
  tsv=$(printf '%s' "$raw_body" | pdr_parse_verdict "$out_fmt") || parse_rc=$?

  local verdict="" ac_reason="" dt_reason="" tr_reason=""
  if [ "$parse_rc" -eq 0 ] && [ -n "$tsv" ]; then
    verdict=$(printf '%s' "$tsv" | awk -F'\t' '{print $1}')
    ac_reason=$(printf '%s' "$tsv" | awk -F'\t' '{print $2}')
    dt_reason=$(printf '%s' "$tsv" | awk -F'\t' '{print $3}')
    tr_reason=$(printf '%s' "$tsv" | awk -F'\t' '{print $4}')
  fi

  # 保守的 approve fallback（Req 2.4）
  if ! pdr_validate_verdict "$verdict" "$ac_reason" "$dt_reason" "$tr_reason"; then
    pdr_warn "PR #${pr_number}: parse / validate 失敗 → 保守的に approve に倒す（false-reject 回避）"
    verdict="approve"
    [ -z "$ac_reason" ] && ac_reason="（自動判定不能のため保守的 approve / Req 2.4）"
    [ -z "$dt_reason" ] && dt_reason="（自動判定不能のため保守的 approve / Req 2.4）"
    [ -z "$tr_reason" ] && tr_reason="（自動判定不能のため保守的 approve / Req 2.4）"
  fi

  # ラベル / status / コメントの 3 系統を順に確定
  pdr_apply_label_decision "$pr_number" "$verdict" || true
  pdr_apply_status_decision "$pr_number" "$sha" "$verdict" "$pr_url" || true
  pdr_post_decision_comment "$pr_number" "$sha" "$verdict" "$ac_reason" "$dt_reason" "$tr_reason" || true

  # 1 行サマリ（NFR 1.1 / 5.2: サマリ集計を 1 行以上のログとして出力）
  pdr_log "PR #${pr_number}: design Reviewer 判定完了 sha=${sha} verdict=${verdict} spec=${spec_dir_rel:-(none)}"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# process_pr_design_reviewer: dispatcher エントリ
#   入力: なし
#   出力: なし（log のみ）
#   戻り値: 0 固定（後続 processor を阻害しない / dispatcher fail-continue 契約）
#
#   Req: 1.1 / 2.1 / 2.2 / 2.4 / 6.1 / 6.2 / NFR 1.1（gate OFF 時 log 行ゼロ）/ NFR 2.1
#
#   フロー:
#     1. gate OFF（`DESIGN_REVIEWER_ENABLED=false`）→ 即 return 0（外部副作用ゼロ・log 行ゼロ）
#     2. 必須プロンプト資産が解決不能（installer 未再実行等）→ WARN 1 行 + return 0（no-op）。
#        claude / gh / git を起動せず、claude-review=failure を publish せず needs-iteration も
#        付けない（#432 Req 2 / false-reject による永久 BLOCKED 回避 / 冪等再試行）。
#     3. 候補 PR を pdr_fetch_design_prs で取得
#     4. DESIGN_REVIEWER_MAX_PRS で truncate
#     5. 各 PR に対し pdr_run_review_for_pr を呼ぶ
# ─────────────────────────────────────────────────────────────────────────────
process_pr_design_reviewer() {
  if ! pdr_gate_enabled; then
    # gate OFF: 完全 no-op（log 行ゼロ / NFR 2.1）
    return 0
  fi

  # 必須プロンプト資産（DESIGN_REVIEWER_PROMPT or design-review-prompt.tmpl）が解決できない
  # 場合は、候補取得・claude 起動の前に processor 全体を no-op return する（#432 Req 2.1, 2.2,
  # 2.4）。per-PR で claude を起動して失敗させる経路に乗せず、gate レベルで 1 行 WARN に集約。
  # claude-review status / needs-iteration ラベル / 判定コメントは一切操作しないため、後続
  # サイクルで資産が配布されれば未処理 head sha に対して冪等に再試行される（Req 2.3）。
  if ! pdr_prompt_asset_resolvable; then
    pdr_warn "プロンプトテンプレート未解決のため Design PR Reviewer を skip（DESIGN_REVIEWER_PROMPT 未設定かつ \$HOME/bin/design-review-prompt.tmpl 不在 / installer 再実行で配布されると次サイクルで再試行 / claude 不起動・status 据え置き）"
    return 0
  fi

  local candidates_json
  candidates_json=$(pdr_fetch_design_prs) || true
  if [ -z "$candidates_json" ] || [ "$candidates_json" = "[]" ]; then
    pdr_log "対象設計 PR なし（候補ゼロ件 / sleep）"
    return 0
  fi

  local max_prs="${DESIGN_REVIEWER_MAX_PRS:-5}"
  local total
  total=$(printf '%s' "$candidates_json" | jq -r 'length' 2>/dev/null || echo "0")
  case "$total" in ''|*[!0-9]*) total=0 ;; esac

  local target="$total"
  if [ "$total" -gt "$max_prs" ] 2>/dev/null; then
    target="$max_prs"
    pdr_log "候補設計 PR 件数: total=${total} target=${target} overflow=$((total - max_prs))"
  fi

  if [ "$target" -le 0 ] 2>/dev/null; then
    return 0
  fi

  # 各 PR を順に処理
  local i=0
  while [ "$i" -lt "$target" ]; do
    local pr_json
    pr_json=$(printf '%s' "$candidates_json" | jq -c ".[${i}]" 2>/dev/null || true)
    if [ -n "$pr_json" ] && [ "$pr_json" != "null" ]; then
      pdr_run_review_for_pr "$pr_json" || true
    fi
    i=$((i + 1))
  done

  return 0
}
