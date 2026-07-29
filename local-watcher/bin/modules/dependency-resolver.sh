#!/usr/bin/env bash
# dependency-resolver.sh — Dependency Resolver / Auto-Unblock Sweep モジュール（#146 / #346 / #465 切り出し）
#
# 用途:
#   PM phase（Triage 起動前）に Issue 本文の前提依存記法（canonical `Depends on:` / alias
#   `前提依存:` / alias `Blocked by:`）を機械抽出し、各依存先 Issue の merge 状態を GitHub
#   から確認して、未解決依存が 1 件でも残れば `blocked` ラベル付与 + エスカレーションコメント
#   投稿 + claim 系ラベル除去で人間判断へ委ねる Dependency Resolver ゲート（#146）と、
#   依存全解決時に `blocked` ラベルを自動解除する Dependency Auto-Unblock Sweep（#346）。
#
#   関数一覧（計 15 + 定数 2）:
#     - dr_log / dr_warn / dr_error                          : Dependency Resolver 専用ロガー（stdout 汚染防止のため stderr 固定）
#     - dr_extract_deps                                      : Issue 本文から依存先 Issue 番号集合を抽出（純粋関数）
#     - dr_format_unresolved_comment                         : エスカレーションコメント文面組み立て
#     - dr_gh_graphql_closed_by                               : GraphQL で closedByPullRequestsReferences を照会
#     - dr_resolve_one                                        : 1 依存先 Issue の解決状態を判定
#     - dr_apply_block                                        : blocked ラベル付与 + コメント投稿 + claim ラベル除去
#     - dr_check_dependencies                                 : Slot Runner から呼ばれる本体ゲート
#     - dr_unblock_gate_enabled                               : DEP_AUTO_UNBLOCK_ENABLED 判定（純粋関数）
#     - dr_unblock_has_orphan_marker                          : 空依存通知コメントの冪等性判定
#     - dr_unblock_post_unblocked_comment                     : 自動解除コメント投稿
#     - dr_unblock_post_orphan_marker_comment                 : 空依存通知コメント投稿
#     - dr_unblock_resolve_one_issue                          : 1 Issue の Auto-Unblock 判定 + 分岐
#     - dr_unblock_sweep                                      : main loop から呼ばれるスイープ entry point
#     - DR_UNBLOCK_MARKER_CLEARED / DR_UNBLOCK_MARKER_ORPHAN  : 通知マーカー定数（監査 / 冪等性判定用）
#
#   隣接していた `publish_claude_review_status`（本体側で dr_unblock_gate_enabled と
#   dr_unblock_has_orphan_marker の間に定義）は dr_ 系ではないため本 module には含まれず
#   issue-watcher.sh に残置（次 issue #466 で modules/slot-worker.sh へ移動予定）。
#
#   呼び出し元（Slot Runner 内の dr_check_dependencies 呼び出し / main loop 内の
#   dr_unblock_sweep 呼び出し）は実行順序温存のため本体側に残る。bash の遅延束縛のため
#   順序問題なし。
#
#   詳細: docs/specs/146-feat-harness-pm-phase-issue-issue-merge/design.md /
#         docs/specs/346-feat-watcher-blocked-unblock/design.md
#
# 配置先:
#   $HOME/bin/modules/dependency-resolver.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $LABEL_BLOCKED / $DEP_AUTO_UNBLOCK_ENABLED 等）は本体冒頭の
#     Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - 外部 CLI: gh（REST + GraphQL）/ jq。
#   - 依存記法の canonical 定義は `.claude/rules/issue-dependency.md`（dr_extract_deps 内コメント参照）。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

# ─── Dependency Resolver (Issue #146) ───
# PM phase（Triage 起動前）に Issue 本文の前提依存記法
# （canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:`）を機械抽出し、
# 各依存先 Issue の merge 状態を GitHub から確認して、未解決依存が 1 件でも残れば
# `blocked` ラベルを付与 + エスカレーションコメント 1 件投稿 + claim 系ラベル除去で
# 人間判断へ委ねるためのゲート関数群。
#
# 既存 `_slug_mismatch_escalate` / `mq_log` / `pi_log` 等と同書式のロガーを採用し、
# 構造化ログ prefix `dr:` で grep 集計できるようにする（Req 6.1〜6.3 / NFR 2.1〜2.2）。
# helper スクリプト化はせず watcher 単体で完結させる（install.sh の配布対象拡張を
# 避けるため）。
#
# Issue #392 (Req 1.1, 1.2 / NFR 3.1): `dr_log` / `dr_warn` は stderr に書き出す。
# 理由: `dr_resolve_one` は stdout を「機械可読な戻り値」（`resolved` / `open` /
# `closed unmerged` / `api error` のいずれか厳密 1 行）に予約しており、その実装中で
# `dr_log` を呼ぶ経路（OPEN + `staged-for-release` 解決パス）が存在する。`dr_log`
# が stdout に echo すると、`dr_unblock_resolve_one_issue` 側の
# `verdict=$(dr_resolve_one ...)` で **ログ行と戻り値の両方** が `$verdict` に
# 連結捕捉され、未知の verdict と判定されて `BASE_BRANCH != main` 環境の
# `DEP_AUTO_UNBLOCK` が完全停止する事象が実機再現した（#117 / #115）。`dr_warn` は
# 既に `>&2` だったが、本意は「stdout 汚染ゼロ」なので `dr_log` も `>&2` に揃える。
# cron 経由（`>>cron.log 2>&1`）では stderr も cron.log へ集約されるため、既存
# 集計 grep（`grep ' dr:'` / `grep 'verdict='` 等）は本修正で破壊しない（NFR 3.1）。
# `dr_error` は本修正前から `>&2`（Req 4.3）。
dr_log() {
  echo "[$(date '+%F %T')] dr: $*" >&2
}
dr_warn() {
  echo "[$(date '+%F %T')] dr: WARN: $*" >&2
}
dr_error() {
  echo "[$(date '+%F %T')] dr: ERROR: $*" >&2
}

# 引数 = Issue 本文（多行 string、改行入り）。
# stdout = 重複排除済の Issue 番号集合（改行区切り、各行は数字のみ）。
# 空入力・記法非存在では空 stdout を返す（return 0）。
# 副作用なし（純粋関数）。
#
# 検出する記法（`.claude/rules/issue-dependency.md` と整合 / Req 4.1, 4.4）:
#   - canonical: `Depends on: #N` （行頭の `- ` などの list prefix を許容）
#   - alias 日本語: `前提依存: #N`
#   - alias 英語慣習: `Blocked by: #N`
#
# 1 行に複数の Issue 番号がスペース区切り / カンマ区切りで列挙される場合も対応する
# （Req 4.4）。`grep -oE '#[0-9]+'` で行内の番号を全列挙し、`sort -u -n` で uniq 化
# （Req 4.4）。
#
# 誤検出防止（Req 4.2, 4.3 / #204）: markdown コードフェンス（``` または ~~~ で
# 開閉されるブロック）内および引用ブロック（行頭が任意個の空白に続く `>` で始まる行）
# 内の依存マーカーは実依存として抽出しない。例示目的でコード例・引用に依存記法を
# 書いた Issue が誤って false-block されるのを防ぐ。これらの行は markdown 前処理
# （awk）で除去してからマーカーマッチを行う。
dr_extract_deps() {
  local body="$1"

  # ── markdown 前処理: コードフェンス内・引用ブロック行を除去（Req 4.2, 4.3）──
  # awk でフェンス開閉をトグル管理し、フェンス内行と引用行（行頭空白 + `>`）を捨てる。
  # フェンスマーカーは行頭（任意個の空白を許容）の ``` または ~~~ で開始する行。
  # 言語タグ（```bash 等）や閉じフェンスも同じ判定で扱う（開→閉のトグル）。
  local filtered
  filtered=$(printf '%s\n' "$body" | awk '
    {
      line = $0
      # 行頭の空白を除いた先頭部分を取り出してフェンス / 引用を判定する。
      stripped = line
      sub(/^[ \t]+/, "", stripped)
      # コードフェンス開閉トグル（``` または ~~~ で始まる行）。
      if (stripped ~ /^(```|~~~)/) {
        in_fence = !in_fence
        next            # フェンスマーカー行自体も依存抽出の対象外
      }
      if (in_fence) {
        next            # フェンス内の本文行は除外（Req 4.2）
      }
      if (stripped ~ /^>/) {
        next            # 引用ブロック行は除外（Req 4.3）
      }
      print line
    }
  ')

  # 行抽出: canonical + alias の 3 パターン。
  # `-E` で ERE、`-i` は使わず大文字小文字を厳密にし誤検出を減らす（既存運用で
  # `Depends on:` / `Blocked by:` は大文字始まり前提）。`前提依存:` は UTF-8
  # バイト列として直接マッチ（grep -E で安全）。
  local matched_lines
  matched_lines=$(printf '%s\n' "$filtered" \
    | grep -E '(Depends on:|前提依存:|Blocked by:)' || true)

  if [ -z "$matched_lines" ]; then
    return 0
  fi

  # 行ごとに `#[0-9]+` を全列挙し、`#` を剥がして数字のみにし uniq 化。
  # `sort -u -n` で数値昇順 + uniq（出力決定性を確保 / Req 4.4）。
  printf '%s\n' "$matched_lines" \
    | grep -oE '#[0-9]+' \
    | sed -E 's/^#//' \
    | sort -u -n
}

# 引数 $1 = 未解決依存リスト（"#N|区分" の改行区切り、各行は `#N|<区分>` 形式）。
# stdout = 依存未解決専用 markdown 本文（多行）。
# 副作用なし（純粋関数）。
#
# design.md「Escalation Comment Template」と一致する文面を生成し、
# `needs-decisions` テンプレートと混在しない依存未解決専用語彙を使う（Req 3.2,
# 3.6, 8.4, 9.2）。
dr_format_unresolved_comment() {
  local unresolved="$1"

  # 未解決依存リストを markdown 箇条書きに整形（"#N|区分" → "- #N (区分)"）。
  local items
  items=$(printf '%s\n' "$unresolved" \
    | awk -F'|' 'NF==2 && $1 != "" {printf "- %s (%s)\n", $1, $2}')

  # #346: gate ON 時は「次回 tick で自動で外れます」相当の文面に分岐する（Req 8.1）。
  # gate OFF（既定 / 不正値含む）では従来文面（「手動で除去」案内）を維持する（Req 8.2）。
  local next_steps
  if dr_unblock_gate_enabled; then
    next_steps=$(cat <<'EOF_DR_NEXT_AUTO'
1. 上記依存 Issue の解消（merge / staged-for-release 付与など）を進めてください
2. すべて解決されると、次回 cron tick で本 Issue の `blocked` ラベルは **自動で外れます**（手動除去は不要 / DEP_AUTO_UNBLOCK_ENABLED=true）
3. 自動解除と同時に解除コメントが投稿され、通常の Triage / 実装フローに合流します
EOF_DR_NEXT_AUTO
)
  else
    next_steps=$(cat <<'EOF_DR_NEXT_MANUAL'
1. 上記依存 Issue の解消（merge）を進めてください
2. すべて merge 済みになったら、本 Issue から `blocked` ラベルを手動で除去してください
3. 次回 cron tick (`watcher 起動` 後) で依存チェックが再実行され、解消済みなら通常の Triage / 実装フローに合流します
EOF_DR_NEXT_MANUAL
)
  fi

  cat <<EOF_DR_COMMENT
🛑 依存 Issue 未 merge のため自動処理を中止しました。

### 未解決依存

${items}

### 次の手順

${next_steps}

### \`blocked\` と \`needs-decisions\` の使い分け

本ラベルは **依存 Issue 未 merge 専用** です。それ以外の人間判断要求（Triage の判断不能 /
スラグ衝突等）は従来通り \`needs-decisions\` が付与されます。両ラベルは独立した状態遷移を
持ちます（[README.md ラベル状態遷移まとめ](https://github.com/${REPO}#ラベル状態遷移まとめ) 参照）。
EOF_DR_COMMENT
}

# 引数:
#   $1 = owner（$REPO の owner 部）
#   $2 = repo 名（$REPO の repo 部）
#   $3 = 依存 Issue 番号（数字のみ）
# stdout = `gh api graphql` の生レスポンス（JSON 文字列）。失敗時は stderr 本文。
# return = gh api graphql の exit code をそのまま返す。
# 副作用 = なし（呼び出し元がエラーログを担当）。
#
# 本ラッパは dr_resolve_one から `gh api graphql` 呼び出しを切り出したもので、
# 回帰テストが GraphQL レスポンスを mock 注入できるよう薄い indirection を提供する
# （実 API を叩かずに dr_resolve_one の判定ロジックを検証するため / Req 5.x）。
# timeout は既存の DRR_GH_TIMEOUT（新規 env var を導入しない / Req 3.5, NFR 3.1）。
dr_gh_graphql_closed_by() {
  local owner="$1"
  local repo_name="$2"
  local dep_num="$3"

  # GraphQL クエリ: Issue 視点の `closedByPullRequestsReferences` で linked PR の
  # state を取得する（PR ノードに `state` フィールドは存在するが、`gh issue view
  # --json closedByPullRequestsReferences` の REST 経路では `merged` フィールドが
  # 返らないため誤判定していた / 本 bug の根因）。
  # `includeClosedPrs: true` で CLOSED/MERGED の PR も含めて返させる。
  # `first: 20` は check_existing_impl_pr と同じく十分なマージン。
  #
  # #316: 依存ゲートの base 相対化（staged-for-release 解決判定）のため、同一
  # クエリで Issue の labels も取得する。`labels(first: 20)` は Issue 1 件に付く
  # ラベル数として十分なマージン（実運用では 10 件未満が大半）。state + labels を
  # 1 回の問い合わせで取得することで API 呼び出し回数を本変更前と同数に保つ
  # （NFR 2.1）。
  # shellcheck disable=SC2016  # `$owner` / `$repo` / `$number` は GraphQL 変数記法であり bash 展開ではない（`-F` で値を渡す）
  local query='query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        state
        labels(first: 20) {
          nodes {
            name
          }
        }
        closedByPullRequestsReferences(first: 20, includeClosedPrs: true) {
          nodes {
            number
            state
          }
        }
      }
    }
  }'

  timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}" \
    gh api graphql \
      -f query="$query" \
      -F owner="$owner" \
      -F repo="$repo_name" \
      -F number="$dep_num" 2>&1
}

# 引数 $1 = 依存 Issue 番号（数字のみ）。
# stdout = 区分文字列 1 行: "resolved" | "open" | "closed unmerged" | "api error"。
# return = 常に 0（判定結果は stdout で返す）。
# 副作用 = API エラー / jq parse 失敗時のみ dr_warn でログ（Req 6.2）。
#
# `dr_gh_graphql_closed_by` で Issue の state / labels /
# `closedByPullRequestsReferences.nodes[].state` を取得し、以下を判定:
#   - issue.state == "OPEN" かつ BASE_BRANCH != main かつ labels に
#     `staged-for-release` を含む → "resolved"（#316 / Req 1.1 / NFR 3.1）
#   - issue.state == "OPEN"（上記以外）→ "open"（unresolved / Req 1.4 / 旧 2.3 /
#     #316 Req 1.2, 1.3 で BASE_BRANCH=main の従来挙動を維持）
#   - issue.state == "CLOSED" かつ PR ノードの state に "MERGED" が 1 件以上
#     → "resolved"（Req 1.1 / #316 Req 1.4 で従来挙動を維持）
#   - issue.state == "CLOSED" かつ "MERGED" が 0 件（空配列・全 CLOSED 含む）
#     → "closed unmerged"（Req 1.2, 1.3 / #316 Req 1.5 で従来挙動を維持）
#   - gh / jq 失敗 / GraphQL errors / 未知の state → "api error"
#     （Req 2.1, 2.2 / NFR 4.2 安全側 / #316 Req 2.2, 2.3）
#
# 旧実装は `gh issue view --json closedByPullRequestsReferences` の PR ノードに
# 存在しない `.merged` フィールドを参照していたため、merge 済み依存も常に
# `closed unmerged` と誤判定していた（#204 の根因 / Req 1.5）。
#
# #316: BASE_BRANCH != main（gitflow 等の multi-branch 運用 / develop dispatch）
# の場合、依存先が OPEN かつ `staged-for-release` ラベルを持つ状態は「develop
# には統合済みで main 到達待ち」を意味するため、当該依存を resolved として
# 扱う（base 相対化）。BASE_BRANCH=main の従来挙動は変更しない。labels 取得・
# parse に失敗した場合は安全側に倒し `staged-for-release` 付与を仮定しない
# （`api error` = 未解決 / #316 Req 2.3）。base 相対化の閾値は #221
# （promote-pipeline.sh `po_resolve_holder_labels`）の dispatch×multi-branch
# 判定（BASE_BRANCH != PROMOTION_TARGET_BRANCH）と整合させる発想だが、本関数の
# 文脈は dispatch 確定後の Triage 段階であり依存ゲートに promote コンテキストは
# 存在しないため、判定基準は単純な `BASE_BRANCH != main` で十分（Issue 本文の
# 仕様および requirements.md Req 1.1）。
#
# timeout は DRR_GH_TIMEOUT に従う（個別の新規 env var は導入しない / Req 3.5 /
# #316 NFR 1.2）。
dr_resolve_one() {
  local dep_num="$1"

  # $REPO は "owner/repo" 形式（既存 watcher 全体の前提）。GraphQL 引数に分解する。
  local owner repo_name
  owner="${REPO%%/*}"
  repo_name="${REPO##*/}"
  if [ -z "$owner" ] || [ -z "$repo_name" ] || [ "$owner" = "$REPO" ]; then
    dr_warn "issue=#${dep_num} REPO env が owner/repo 形式でない: ${REPO:-<empty>}"
    echo "api error"
    return 0
  fi

  local response gh_rc
  response=$(dr_gh_graphql_closed_by "$owner" "$repo_name" "$dep_num") && gh_rc=0 || gh_rc=$?

  if [ "$gh_rc" -ne 0 ]; then
    dr_warn "issue=#${dep_num} gh api graphql 失敗 (rc=${gh_rc}): ${response}"
    echo "api error"
    return 0
  fi

  # GraphQL は HTTP 200 でも errors を返すケースがあるため明示的に検査する（Req 2.1）。
  if printf '%s' "$response" | jq -e '.errors // empty | length > 0' >/dev/null 2>&1; then
    dr_warn "issue=#${dep_num} GraphQL errors を検出"
    echo "api error"
    return 0
  fi

  local state
  if ! state=$(printf '%s' "$response" \
        | jq -r '.data.repository.issue.state' 2>/dev/null); then
    dr_warn "issue=#${dep_num} jq parse 失敗（issue.state 取り出し）"
    echo "api error"
    return 0
  fi
  # state が null（issue ノードが取れていない等の想定外応答）→ 安全側で api error
  # （Req 2.2: 想定外構造で merge 状態を解釈できない場合）。
  if [ -z "$state" ] || [ "$state" = "null" ]; then
    dr_warn "issue=#${dep_num} issue.state が取得できない応答構造（state=${state:-<empty>}）"
    echo "api error"
    return 0
  fi

  case "$state" in
    OPEN)
      # #316: base 相対化（staged-for-release 依存の解決判定）。
      # BASE_BRANCH=main の場合は従来挙動を維持し、ラベルを参照せず unresolved
      # （Req 1.2 / NFR 1.1 後方互換）。BASE_BRANCH != main の場合のみ labels を
      # 読み出し、`staged-for-release` 付与時に resolved として返す（Req 1.1）。
      if [ "${BASE_BRANCH:-main}" = "main" ]; then
        echo "open"
        return 0
      fi
      # labels 一覧を取り出して `staged-for-release` の有無を判定。jq parse 失敗時は
      # 安全側に倒し api error（ラベル付与を仮定して resolved として扱う処理は行わ
      # ない / Req 2.3）。
      local has_staged_label
      if ! has_staged_label=$(printf '%s' "$response" \
            | jq -r --arg target "${LABEL_STAGED_FOR_RELEASE:-staged-for-release}" \
                '[.data.repository.issue.labels.nodes[]? | select(.name == $target)] | length > 0' \
            2>/dev/null); then
        dr_warn "issue=#${dep_num} jq parse 失敗（labels 取り出し）"
        echo "api error"
        return 0
      fi
      # 想定外応答（labels ノードが取れない等）で true/false 以外が返った場合も
      # 安全側で api error（Req 2.2, 2.3）。
      case "$has_staged_label" in
        true)
          dr_log "issue=#${dep_num} verdict=resolved reason=staged-for-release base=${BASE_BRANCH:-main}"
          echo "resolved"
          return 0
          ;;
        false)
          echo "open"
          return 0
          ;;
        *)
          dr_warn "issue=#${dep_num} labels 集計結果が想定外: ${has_staged_label}"
          echo "api error"
          return 0
          ;;
      esac
      ;;
    CLOSED)
      # closedByPullRequestsReferences.nodes[].state に "MERGED" が 1 件以上あれば
      # resolved。空配列 or 全て MERGED 以外（CLOSED 等）は closed unmerged
      # （Req 1.1, 1.2, 1.3）。
      local merged_count
      if ! merged_count=$(printf '%s' "$response" \
            | jq '[.data.repository.issue.closedByPullRequestsReferences.nodes[]? | select(.state == "MERGED")] | length' \
            2>/dev/null); then
        dr_warn "issue=#${dep_num} jq parse 失敗（closedByPullRequestsReferences 集計）"
        echo "api error"
        return 0
      fi
      # 想定外応答で集計結果が数値でない場合も安全側で api error（Req 2.2）。
      if ! [[ "$merged_count" =~ ^[0-9]+$ ]]; then
        dr_warn "issue=#${dep_num} closedByPullRequestsReferences 集計結果が数値でない: ${merged_count}"
        echo "api error"
        return 0
      fi
      if [ "$merged_count" -gt 0 ]; then
        echo "resolved"
      else
        echo "closed unmerged"
      fi
      return 0
      ;;
    *)
      # 未知の state（GitHub API 仕様変更 / 異常応答）→ 安全側で api error 扱い
      dr_warn "issue=#${dep_num} 未知の state: ${state}"
      echo "api error"
      return 0
      ;;
  esac
}

# 引数:
#   $1 = 対象 Issue 番号（数字のみ）
#   $2 = 未解決依存リスト（"#N|区分" 改行区切り、dr_format_unresolved_comment 用）
# 戻り値:
#   0 = ラベル付与 + コメント投稿が成功
#   1 = いずれかが失敗（呼び出し元は当該 Issue を skip して slot を return 0 する）
# 副作用:
#   - `blocked` ラベル付与 + `claude-claimed` 除去を単一 PATCH で原子的に発行
#   - エスカレーションコメント 1 件投稿（重複投稿は caller の冪等性ガードで防ぐ）
#
# `needs-decisions` ラベルには触れない（Req 9.1）。
# 既存 `_slug_mismatch_escalate` と同パターンで gh 副作用エラーは `dr_warn` で
# ログ + 非 0 return を返し、caller は安全側で slot を return 0 する。
dr_apply_block() {
  local issue_num="$1"
  local unresolved="$2"

  local body
  body=$(dr_format_unresolved_comment "$unresolved")

  # ラベル付け替えとコメント投稿を発射。失敗は dr_warn で記録、いずれかが
  # 失敗した場合は呼び出し元（dr_check_dependencies）に非 0 を返す。
  local label_rc=0 comment_rc=0
  if ! gh issue edit "$issue_num" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_BLOCKED" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} gh issue edit (blocked ラベル付与 / claim 除去) に失敗"
    label_rc=1
  fi
  if ! gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} エスカレーションコメント投稿に失敗"
    comment_rc=1
  fi

  if [ "$label_rc" -ne 0 ] || [ "$comment_rc" -ne 0 ]; then
    return 1
  fi
  return 0
}

# 引数:
#   $1 = 対象 Issue 番号
#   $2 = Issue 本文（多行 string）
#   $3 = 既存ラベル名一覧（改行区切り、`_slot_run_issue` の $LABELS と同じ形式）
# 戻り値:
#   0 = block しない（Triage 続行可 / 検出ゼロ or 全件 resolved）
#   1 = block 確定（caller は Triage skip して slot を return 0 する）
# 副作用:
#   - `dr_log` で構造化ログ 1 行を必ず出力（Req 6.1 / NFR 2.1）
#   - ブロック確定時のみ `dr_apply_block` を呼んで blocked 付与 + コメント投稿
#
# 冪等性ガード（Req 3.4 / NFR 3.1）: 入力 LABELS に `blocked` を含む場合は何もせず
# return 1 を返す（caller は skip、ラベル再付与・コメント再投稿なし）。N 回連続実行
# されてもラベル付与数 1 / コメント投稿数 1 に収束する。
#
# 検出ゼロ時の挙動（Req 1.6 / 5.1〜5.3 / NFR 1.1）: gh API 呼び出しゼロ・ラベル
# 変更ゼロ・コメント投稿ゼロで `verdict=skip_no_deps` の構造化ログ 1 行のみ出力。
# 本機能導入前と完全に同一の pickup 挙動を維持。
dr_check_dependencies() {
  local issue_num="$1"
  local body="$2"
  local labels="$3"

  # 冪等性ガード: 既に blocked が付与されている → 再付与せず caller 側 skip
  # （Req 3.4）。LABELS は改行区切りなので `grep -qx` で完全一致判定。
  if printf '%s\n' "$labels" | grep -qx "$LABEL_BLOCKED"; then
    dr_log "issue=#${issue_num} verdict=blocked (既に blocked 付与済 / 冪等 skip)"
    return 1
  fi

  # 依存抽出（gh 呼ばず、純粋関数）
  local extracted
  extracted=$(dr_extract_deps "$body")
  if [ -z "$extracted" ]; then
    # 検出ゼロ → 副作用ゼロで Triage 続行（Req 1.6 / 5.1〜5.3 / NFR 1.1）
    dr_log "issue=#${issue_num} extracted= verdict=skip_no_deps"
    return 0
  fi

  # 抽出件数分の依存先 Issue を解決。1 件以上 unresolved / api_error があれば
  # ブロック確定（Req 2.6）。
  local extracted_csv resolved_csv unresolved_csv api_errors_csv unresolved_lines
  extracted_csv=""
  resolved_csv=""
  unresolved_csv=""
  api_errors_csv=""
  unresolved_lines=""
  local dep verdict_for_dep
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    extracted_csv="${extracted_csv:+${extracted_csv},}#${dep}"
    verdict_for_dep=$(dr_resolve_one "$dep")
    case "$verdict_for_dep" in
      resolved)
        resolved_csv="${resolved_csv:+${resolved_csv},}#${dep}"
        ;;
      open)
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (open)"
        unresolved_lines="${unresolved_lines}#${dep}|open"$'\n'
        ;;
      "closed unmerged")
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (closed_unmerged)"
        unresolved_lines="${unresolved_lines}#${dep}|closed unmerged"$'\n'
        ;;
      "api error")
        api_errors_csv="${api_errors_csv:+${api_errors_csv},}#${dep}"
        unresolved_lines="${unresolved_lines}#${dep}|api error"$'\n'
        ;;
      *)
        # 想定外（dr_resolve_one が新区分を返した）→ 安全側で unresolved 扱い
        dr_warn "issue=#${issue_num} dep=#${dep} 未知の verdict: ${verdict_for_dep}"
        api_errors_csv="${api_errors_csv:+${api_errors_csv},}#${dep}"
        unresolved_lines="${unresolved_lines}#${dep}|api error"$'\n'
        ;;
    esac
  done <<< "$extracted"

  if [ -n "$unresolved_lines" ]; then
    # ブロック確定 → blocked 付与 + コメント投稿（Req 3.1〜3.3, 3.5, 9.1）
    dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved=${unresolved_csv} api_errors=${api_errors_csv} verdict=blocked"
    if ! dr_apply_block "$issue_num" "${unresolved_lines%$'\n'}"; then
      dr_warn "issue=#${issue_num} dr_apply_block 失敗 / caller は skip（NFR 4.2 安全側）"
    fi
    return 1
  fi

  # 全件 resolved → Triage 続行
  dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved= api_errors= verdict=all_resolved"
  return 0
}

# ─── Dependency Auto-Unblock Sweep (Issue #346) ───
# 依存全解決時に `blocked` ラベルを自動解除するスイープ関数群。`_dispatcher_run` の
# 候補クエリより前段で 1 度起動し、auto-dev AND blocked AND OPEN な Issue 集合を列挙して
# 以下のいずれかに分岐する:
#   (1) 全依存 resolved → `blocked` 除去 + 自動解除コメント投稿（Req 3.1, 3.2）
#   (2) 1 件以上 unresolved → 何もしない（Req 4.1, 6.2）
#   (3) 依存マーカー消失（dr_extract_deps が空）→ 通知コメント 1 回のみ投稿（Req 5.1, 5.2）
# 起動 gate: `DEP_AUTO_UNBLOCK_ENABLED=true` 厳密一致のみ ON。それ以外は OFF
# （Req 1.2, 1.3, NFR 1.1）。OFF 時は冒頭 1 行 if で即 return し gh API 呼び出しゼロ。
#
# 既存 `dr_*` 関数（`dr_extract_deps` / `dr_resolve_one` / `dr_apply_block` /
# `dr_check_dependencies`）の signature・戻り値契約は変更しない（NFR 1.2）。

# Issue #346 通知マーカー文字列。
# - DR_UNBLOCK_MARKER_CLEARED: 自動解除コメントに埋め込む監査識別子（NFR 4.2）
# - DR_UNBLOCK_MARKER_ORPHAN : 空依存通知コメントの冪等性判定キー（Req 5.4）
# どちらも HTML コメント形式で GitHub UI 上は不可視。grep / jq から検出可能。
# shellcheck disable=SC2034  # 抽出した個別関数の遅延束縛 / 既存 dr_* と同パターン
DR_UNBLOCK_MARKER_CLEARED='<!-- idd-claude:dep-unblock-cleared:v1 -->'
# shellcheck disable=SC2034  # 同上
DR_UNBLOCK_MARKER_ORPHAN='<!-- idd-claude:dep-unblock-orphan-marker:v1 -->'

# 引数: なし
# 戻り値: 0 = gate ON / 1 = gate OFF（既定 / 不正値 / typo）
# 副作用: なし（純粋関数）
#
# `DEP_AUTO_UNBLOCK_ENABLED` を `=true` 厳密一致で判定する（Req 1.2, 1.3）。
# 値正規化に失敗した状態（未設定 / 空 / `False` / `True` / `1` / `on` / typo）は
# すべて OFF として扱う（NFR 1.1 安全側）。本関数は `dr_unblock_sweep` の起動 gate
# 兼、`dr_format_unresolved_comment` の文面分岐スイッチを兼ねる（Req 8.1, 8.2）。
dr_unblock_gate_enabled() {
  case "${DEP_AUTO_UNBLOCK_ENABLED:-false}" in
    true) return 0 ;;
    *) return 1 ;;
  esac
}

# 引数 $1 = 対象 Issue 番号（数字のみ）
# stdout = なし（戻り値で表現）
# 戻り値:
#   0 = 既存コメント中に空依存通知マーカーが見つかった（投稿済 / Req 5.3）
#   1 = マーカー未投稿 or gh 取得失敗（NFR 3.1 安全側で「未投稿扱い」にすると重複投稿の
#       恐れがあるため、本実装では gh 取得失敗時は「投稿済 = 1」を返して再投稿を抑止する）
# 副作用: なし（read-only API のみ）
#
# `gh issue view --json comments` で対象 Issue のコメント本文を一括取得し、in-bash で
# マーカー文字列（`<!-- idd-claude:dep-unblock-orphan-marker:v1 -->`）を grep する。
# 過去コメントに 1 件でも該当があれば「投稿済」として `dr_unblock_sweep` から再投稿
# しないようにする（Req 5.3, 6.1, NFR 5.1 冪等性）。
dr_unblock_has_orphan_marker() {
  local issue_num="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_num" --repo "$REPO" \
        --json comments 2>/dev/null); then
    # 取得失敗 → 安全側で「投稿済扱い」にして再投稿しない（NFR 5.1）
    dr_warn "issue=#${issue_num} gh issue view --json comments 失敗（orphan marker 検出 skip / 投稿済扱い）"
    return 0
  fi
  if printf '%s' "$comments_json" \
      | jq -r '.comments[]?.body // ""' 2>/dev/null \
      | grep -qF -- "$DR_UNBLOCK_MARKER_ORPHAN"; then
    return 0
  fi
  return 1
}

# 引数:
#   $1 = 対象 Issue 番号
# 副作用:
#   - 自動解除コメント 1 件を投稿（マーカー識別子を含む / NFR 4.2）
# 戻り値:
#   0 = 投稿成功 / 1 = 投稿失敗（dr_warn は呼び出し元で出す方針）
#
# 本コメントは「watcher が依存全解決を検出し `blocked` を外した」旨を GitHub UI
# 履歴から読み取れる文面とマーカーを含む（Req 3.3, NFR 4.2）。
dr_unblock_post_unblocked_comment() {
  local issue_num="$1"
  local body
  body=$(cat <<EOF_DR_UNBLOCK_CLEARED
✅ 依存 Issue がすべて解決したため、\`blocked\` ラベルを自動解除しました。

依存解決時の自動スイープ（\`DEP_AUTO_UNBLOCK_ENABLED=true\`）が、本 Issue 本文の
依存記法（\`Depends on:\` / \`前提依存:\` / \`Blocked by:\`）から抽出した依存先を
すべて \`resolved\`（merge 済み / 又は \`staged-for-release\` 付与など base 相対）と
判定したため、本ラベルを自動で除去しました。次回 cron tick で通常の Triage / 実装
フローに合流します。

判定経緯は watcher の構造化ログ（\`dr: issue=#${issue_num} verdict=unblock_cleared\`）
から追跡できます。

${DR_UNBLOCK_MARKER_CLEARED}
EOF_DR_UNBLOCK_CLEARED
)
  gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1
}

# 引数:
#   $1 = 対象 Issue 番号
# 副作用:
#   - 空依存通知コメント 1 件を投稿（マーカー識別子を含む / Req 5.4）
# 戻り値:
#   0 = 投稿成功 / 1 = 投稿失敗
#
# 「依存マーカーが本文から消失したため自動解除されない」旨を通知し、人間が依存記法
# の誤削除に気づけるようにする（Req 5.2）。ラベルは維持され、人間判断で本ラベルを
# 手動除去するか、依存記法を本文に書き直す運用フローに委ねる。
dr_unblock_post_orphan_marker_comment() {
  local issue_num="$1"
  local body
  body=$(cat <<EOF_DR_UNBLOCK_ORPHAN
⚠️ 依存記法が本文から消失していますが、\`blocked\` ラベルは自動解除しませんでした。

本 Issue には \`blocked\` ラベルが付いていますが、現在の Issue 本文から依存記法
（\`Depends on:\` / \`前提依存:\` / \`Blocked by:\`）が検出できませんでした。
編集ミス・意図せぬ削除を疑い、安全側で自動解除を見送ります（\`DEP_AUTO_UNBLOCK_ENABLED=true\`）。

### 次の手順

- 依存先がまだ未解決なら、Issue 本文に \`Depends on: #N\` 形式で依存記法を**再記述**してください
- 既に依存が解決済 / 依存記法を撤回したい場合は、本 Issue から \`blocked\` ラベルを**手動除去**してください

本通知は重複投稿を避けるため 1 度だけ投稿されます（マーカー検出による冪等性）。

${DR_UNBLOCK_MARKER_ORPHAN}
EOF_DR_UNBLOCK_ORPHAN
)
  gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1
}

# 引数:
#   $1 = 対象 Issue 番号
#   $2 = Issue 本文（多行 string）
# 戻り値:
#   0 = 処理完了（解除 / 通知 / 維持いずれも 0）
#   非 0 は呼び出し元では使わない（fail-open）
# 副作用:
#   - 全依存 resolved → `gh issue edit --remove-label blocked` + 自動解除コメント投稿
#   - 空依存マーカー + 未通知 → 通知コメント投稿
#   - 1 件以上 unresolved → 何もしない
#   - 各分岐で `dr_log` 構造化ログ 1 行（Req 7.1〜7.3）
#
# 既存 `dr_extract_deps` / `dr_resolve_one` を流用するため、依存解析ロジックの
# 重複実装を避ける（NFR 1.2）。`gh issue edit` 失敗時は解除コメント未投稿で次へ
# 進み（NFR 3.2 / Req 3.4）、ラベル除去成功 + コメント投稿失敗時は警告ログ 1 行
# 残して次へ進む（既存 `dr_apply_block` の寛容方針と整合）。
dr_unblock_resolve_one_issue() {
  local issue_num="$1"
  local body="$2"

  # 依存抽出（純粋関数、gh 呼ばず）
  local extracted
  extracted=$(dr_extract_deps "$body")

  if [ -z "$extracted" ]; then
    # 空依存マーカー → 既通知判定 → 未通知ならコメント 1 件投稿（Req 5.1, 5.2, 5.3）
    if dr_unblock_has_orphan_marker "$issue_num"; then
      dr_log "issue=#${issue_num} verdict=unblock_orphan_notified (既通知 / 冪等 skip)"
      return 0
    fi
    if ! dr_unblock_post_orphan_marker_comment "$issue_num"; then
      dr_warn "issue=#${issue_num} 空依存通知コメント投稿に失敗"
      return 0
    fi
    dr_log "issue=#${issue_num} verdict=unblock_orphan_marker"
    return 0
  fi

  # 依存解決判定: 1 件でも unresolved があれば維持（Req 4.1, 4.2）
  local extracted_csv resolved_csv unresolved_csv
  extracted_csv=""
  resolved_csv=""
  unresolved_csv=""
  local dep verdict_for_dep
  while IFS= read -r dep; do
    [ -z "$dep" ] && continue
    extracted_csv="${extracted_csv:+${extracted_csv},}#${dep}"
    verdict_for_dep=$(dr_resolve_one "$dep")
    case "$verdict_for_dep" in
      resolved)
        resolved_csv="${resolved_csv:+${resolved_csv},}#${dep}"
        ;;
      open|"closed unmerged"|"api error")
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (${verdict_for_dep})"
        ;;
      *)
        # 想定外 verdict は安全側で unresolved 扱い（Req 4.2）
        dr_warn "issue=#${issue_num} dep=#${dep} 未知の verdict: ${verdict_for_dep} (unresolved 扱い)"
        unresolved_csv="${unresolved_csv:+${unresolved_csv},}#${dep} (unknown)"
        ;;
    esac
  done <<< "$extracted"

  if [ -n "$unresolved_csv" ]; then
    # 1 件以上 unresolved → 維持（Req 4.1, 4.3, 6.2）
    dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved=${unresolved_csv} verdict=unblock_keep"
    return 0
  fi

  # 全依存 resolved → blocked 除去 + 自動解除コメント投稿（Req 3.1, 3.2）
  if ! gh issue edit "$issue_num" --repo "$REPO" \
        --remove-label "$LABEL_BLOCKED" >/dev/null 2>&1; then
    # ラベル除去失敗 → コメント投稿せず skip（Req 3.4 / NFR 3.2 中途半端な状態を残さない）
    dr_warn "issue=#${issue_num} gh issue edit --remove-label ${LABEL_BLOCKED} 失敗 / コメント投稿せず skip"
    return 0
  fi
  if ! dr_unblock_post_unblocked_comment "$issue_num"; then
    # ラベル除去成功 + コメント投稿失敗 → 警告ログ 1 行 + 次 Issue へ
    # （既存 dr_apply_block と同じ寛容方針 / NFR 3.2）
    dr_warn "issue=#${issue_num} 自動解除コメント投稿に失敗（ラベルは除去済）"
  fi
  dr_log "issue=#${issue_num} extracted=${extracted_csv} resolved=${resolved_csv} unresolved= verdict=unblock_cleared"
  return 0
}

# 引数: なし
# 戻り値: 常に 0（個別 Issue の成否は内部ログで表現 / NFR 3.2 fail-open）
# 副作用:
#   - `DEP_AUTO_UNBLOCK_ENABLED=true` 時のみ `gh issue list` で対象 Issue を列挙し
#     `dr_unblock_resolve_one_issue` を順次適用
#   - OFF 時は gh API 呼び出しゼロで即 return（NFR 1.1, 2.1）
#
# `_dispatcher_run` のメイン候補クエリより前段で 1 度だけ呼ばれる前提（Req 2.3）。
# 解除された Issue は本 tick の `_dispatcher_run` 候補列挙（`-label:"$LABEL_BLOCKED"`
# 除外）で通常 pickup に合流できる（同 tick fall-through 動線。Req 2.3 を満たす）。
dr_unblock_sweep() {
  # Issue #348: full-auto kill switch（AND 二重 opt-in / Req 2.5）。
  # 個別 gate `DEP_AUTO_UNBLOCK_ENABLED` より先に kill switch を評価し、
  # OFF なら外部副作用ゼロで早期 return + 抑止原因を 1 行ログ出力する（Req 4.1）。
  # 既存個別 gate の挙動と独立に評価することで、運用者は kill switch 1 つで
  # 全 full-auto 系 processor を即時 no-op に倒せる（Req 2.5 / NFR 1.1）。
  if ! full_auto_enabled; then
    dr_log "dr_unblock_sweep: suppressed by FULL_AUTO_ENABLED kill switch (no-op)"
    return 0
  fi
  # 起動 gate（Req 1.1, 1.2, NFR 1.1, NFR 2.1）。OFF なら gh API ゼロ呼び出しで return。
  if ! dr_unblock_gate_enabled; then
    return 0
  fi

  # 対象 Issue 列挙: auto-dev AND blocked AND OPEN（Req 2.1）。
  # 終端ラベル（claude-failed / needs-decisions）が付いた Issue は sweep の対象から
  # 明示除外する（Req 2.2）。`mark_issue_failed` は claude-failed 付与時に auto-dev
  # ラベルを除去しないため、`auto-dev` + `blocked` + `claude-failed` の 3 ラベル組合せが
  # 実運用で発生し得る。AND クエリだけでは終端 Issue が pickup されるので、
  # `_dispatcher_run` のメイン候補クエリ（search_filter）と整合する `-label:"..."`
  # 除外を `--search` に追加する。
  # FIFO 順（Issue 番号昇順）を取りやすくするため `sort:created-asc` を採用。
  # #521 Req 2.3: サイクル内 Issue snapshot 共有。対象集合（open ∧ auto-dev ∧ blocked）は
  # (open ∧ auto-dev) の部分集合。snapshot active 時のみ超集合を client 絞り込み
  # （blocked 包含 + failed/needs-decisions 除外）し FIFO 相当（Issue 番号昇順 ≒ created-asc /
  # Issue 番号は作成順に単調増加）で整列する。それ以外（gate off / 非 active）は従来の
  # gh issue list（--label auto-dev --label blocked + sort:created-asc）を byte 等価に実行する
  # （NFR 1.1）。
  local issues_json
  if grl_snapshot_active; then
    if ! issues_json=$(grl_snapshot_issues | jq -c \
          --arg blocked "$LABEL_BLOCKED" --arg failed "$LABEL_FAILED" --arg nd "$LABEL_NEEDS_DECISIONS" \
          '[.[]
             | (.labels // [] | map(.name)) as $n
             | select(($n | index($blocked)) != null)
             | select(($n | index($failed)) == null)
             | select(($n | index($nd)) == null)
          ] | sort_by(.number)' 2>/dev/null); then
      dr_warn "dr_unblock_sweep: snapshot 絞り込み失敗 / スイープ skip"
      return 0
    fi
  elif ! issues_json=$(gh issue list \
        --repo "$REPO" \
        --label "$LABEL_TRIGGER" \
        --label "$LABEL_BLOCKED" \
        --state open \
        --search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" sort:created-asc" \
        --json number,body \
        --limit 50 2>/dev/null); then
    dr_warn "dr_unblock_sweep: gh issue list 失敗 / スイープ skip"
    return 0
  fi

  local count
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  if [ -z "$count" ] || [ "$count" = "0" ]; then
    # 対象ゼロ → 追加 API 呼び出しゼロで return（NFR 2.1）
    return 0
  fi

  dr_log "dr_unblock_sweep 起動 対象=${count} 件 gate=on"

  # Issue #368 / D-16: Dependency Cycle Detection をスイープ本処理の前段で 1 回実行。
  # auto-unblock と同じ取得済み $issues_json をそのまま渡すことで本文取得 API を
  # 二重呼び出ししない（NFR 2.2）。閉路メンバー集合は `_DC_CYCLE_MEMBERS`（空白区切り）
  # に export され、本ループ内で auto-unblock の対象から除外する（Req 4.4 / AT-j）。
  # fail-open（`|| true`）で cycle 検出の失敗が auto-unblock を壊さない（NFR 3.2）。
  dc_cycle_sweep "$issues_json" || true

  # 閉路メンバー判定用の grep -F 入力（改行区切り）に変換
  local cycle_members_lines=""
  if [ -n "${_DC_CYCLE_MEMBERS:-}" ]; then
    cycle_members_lines=$(printf '%s\n' "$_DC_CYCLE_MEMBERS" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
  fi

  local i issue_num issue_body
  for ((i=0; i<count; i++)); do
    issue_num=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
    issue_body=$(printf '%s' "$issues_json" | jq -r ".[$i].body // \"\"" 2>/dev/null)
    if [ -z "$issue_num" ] || ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
      dr_warn "dr_unblock_sweep: index=${i} の number 抽出に失敗 / skip"
      continue
    fi
    # Issue #368 / D-16: 閉路メンバーは auto-unblock の対象から除外（Req 4.4 / AT-j）。
    # cycle 検出側で needs-decisions 付与済みのため、ここで blocked を外すと矛盾する。
    if [ -n "$cycle_members_lines" ] \
        && printf '%s\n' "$cycle_members_lines" | grep -qxF -- "$issue_num"; then
      dr_log "issue=#${issue_num} verdict=unblock_skip_cycle_member"
      continue
    fi
    # 個別 Issue の処理失敗は fail-open（次 Issue に進む / NFR 3.2）
    dr_unblock_resolve_one_issue "$issue_num" "$issue_body" || true
  done
  return 0
}
