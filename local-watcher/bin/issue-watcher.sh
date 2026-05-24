#!/usr/bin/env bash
# =============================================================================
# idd-claude local issue watcher
#
# GitHub Issue をポーリングし、auto-dev ラベルが付いた未処理 Issue を検出して
# Claude Code でローカル実行する。
#
# 3 つのモードを状態機械で管理:
#   - design        : PM → Architect → PjM（設計 PR 作成、awaiting-design-review 付与）
#   - impl          : PM → Developer → PjM（小〜中規模、Architect 不要）
#   - impl-resume   : Developer → PjM（設計 PR が merge 済みで docs/specs/<N>-*/ が main に存在）
#
# ラベルによる状態遷移:
#   auto-dev  → claude-claimed (Dispatcher claim) → Triage
#                              → (needs-decisions | awaiting-design-review | claude-picked-up)
#                              → ready-for-review / claude-failed
#
# Stage Checkpoint Resume 経路 (#68, デフォルト有効 / #112):
#   STAGE_CHECKPOINT_ENABLED=true（既定）で impl / impl-resume の Stage A/B/C 失敗時に
#   完了済み Stage を成果物（impl-notes.md / review-notes.md / 既存 impl PR）の
#   存在で観測し、未完了 Stage 以降のみを再実行する。`=false` を明示すると本機能導入前と
#   同等の Stage A 起点固定挙動に戻る（NFR 1.1）。判定根拠は `stage-checkpoint:` prefix の
#   ログで観測可能。
#
# 配置先: ~/bin/issue-watcher.sh
# 依存  : gh / jq / claude / flock / git
#
# セットアップ: このファイル冒頭の ━━━ Config ━━━ ブロックを編集し、
#   launchd (macOS) または cron (Linux) に登録する。README.md を参照。
# =============================================================================

set -euo pipefail

# cron / launchd は対話シェルの profile を読まないため PATH が最小限になり、
# ~/.local/bin や /usr/local/bin にインストールした claude / gh が見つからない。
# 一般的なインストール先を先頭に足しておき、どの起動経路でも同じ挙動にする。
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Config（環境に合わせて書き換える）
#
# 複数リポジトリ運用:
#   REPO / REPO_DIR は環境変数で上書き可能。各 repo の cron / launchd エントリから
#   env var を渡せば、このスクリプト 1 ファイルを使い回せる。
#   LOCK_FILE / LOG_DIR / TRIAGE_FILE は REPO から自動派生するため衝突しない。
#
#   cron 例:
#     */2 * * * * REPO=owner/a REPO_DIR=$HOME/work/a $HOME/bin/issue-watcher.sh
#     */3 * * * * REPO=owner/b REPO_DIR=$HOME/work/b $HOME/bin/issue-watcher.sh
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# env var で上書き可能（未設定なら下のデフォルトを使う）
REPO="${REPO:-owner/your-repo}"
REPO_DIR="${REPO_DIR:-$HOME/work/your-repo}"

# REPO から repo-unique な slug を導出（lock / log / 一時ファイルの隔離に使う）
REPO_SLUG="$(echo "$REPO" | tr '/' '-')"

LABEL_TRIGGER="auto-dev"
LABEL_CLAIMED="claude-claimed"
LABEL_PICKED="claude-picked-up"
LABEL_NEEDS_DECISIONS="needs-decisions"
LABEL_AWAITING_DESIGN="awaiting-design-review"
LABEL_READY="ready-for-review"
LABEL_FAILED="claude-failed"
LABEL_SKIP_TRIAGE="skip-triage"
# #181 Part 3 で本体内の唯一の参照（pi_fetch_candidate_prs）が
# modules/pr-iteration.sh へ移動したため、本体内では参照箇所がなくなった
# （消費は pr-iteration.sh / merge-queue.sh 側）。source で同一プロセスに読み込まれる
# ため共有は維持される。SC2034（本体内未使用）を局所的に抑止する。
# shellcheck disable=SC2034
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
# Phase B: ST failure 検知後 revert 済みを示すラベル（Req 4.1）。
# #181 Part 3 で pp_* が modules/promote-pipeline.sh へ移動したため、本体内では
# 参照箇所がなくなった（消費は module 側）。source で同一プロセスに読み込まれるため
# 共有は維持される。SC2034（本体内未使用）を局所的に抑止する。
# shellcheck disable=SC2034
LABEL_ST_FAILED="st-failed"
# Phase E: hot file 競合予防で同サイクル dispatch を見送り中（#18 Req 7.1）。
# Path Overlap Checker が付与・除去し、先行 Issue の PR merge で in-flight 集合から
# 外れた次サイクルで自動除去される（Req 6.1〜6.4）。
# #181 Part 3 で po_* が modules/promote-pipeline.sh へ移動したため、本体内では
# 参照箇所がなくなった（消費は module 側）。source で同一プロセスに読み込まれるため
# 共有は維持される。SC2034（本体内未使用）を局所的に抑止する。
# shellcheck disable=SC2034
LABEL_AWAITING_SLOT="awaiting-slot"
# Issue #146: 依存 Issue 未 merge により auto-dev 進行不能であることを示すラベル。
# PM phase（Triage 起動前）の Dependency Resolver Gate が Issue 本文の依存記法
# （canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:`）を解析して、
# 未解決依存が 1 件でも残る場合に付与する。dispatcher pickup 除外条件に追加され、
# 人間が依存を解消後、本ラベルを手動除去すれば次サイクルで再評価される。
# 既存 `needs-decisions`（汎用人間判断要求）とは意味的に独立した運用シグナル
# （Req 9.1〜9.4）。
LABEL_BLOCKED="blocked"
# Issue #200: hotfix 優先ティアを示すラベル。Dispatcher の候補処理順を
# FIFO（Issue 番号昇順）にしたうえで、本ラベル付き Issue を非 hotfix Issue より
# 先に投入する 2 段優先のキー。人間が手動付与する運用前提（自動付与なし）。
LABEL_HOTFIX="hotfix"

# ─── Base branch 設定 (#89) ───
# watcher 経路（local cron）と Actions 経路の base branch を 1 つの env で切り替える
# ための単一の真実源。未設定時は "main" を採用し、本機能導入前と完全に等価な挙動を維持
# する（Req 1.2, 7.2, NFR 1.1）。gitflow 運用（develop 起点）には cron / launchd 側で
# `BASE_BRANCH=develop` を渡す。詳細は README の「ブランチ運用と BASE_BRANCH」節を参照。
BASE_BRANCH="${BASE_BRANCH:-main}"

# ─── Phase B: Promote Pipeline Processor 設定 (#15) ───
# 新規 opt-in 機能。既存運用を壊さないため、明示的に `=true` を指定したときだけ
# Phase B 機能が起動する（Req 1.1.1, NFR 1.1）。`=true` 以外（未設定 / 空 / `false` /
# `0` / typo 等）はすべて無効として扱う（opt-in 制）。本フラグは新規追加 = opt-in 制で
# あり、既定 false が要件のため、上記「デフォルト有効化フラグの値正規化」ループには
# 含めない。
PROMOTE_PIPELINE_ENABLED="${PROMOTE_PIPELINE_ENABLED:-false}"
# 昇格先ブランチ。未設定時は既定 `main`（Req 1.2.1）。
PROMOTION_TARGET_BRANCH="${PROMOTION_TARGET_BRANCH:-main}"
# ST check-run 名。単一文字列のみ（Req 2.2.2）。未設定時は ST 連動全体を停止 + WARN
# （Req 2.2.3）。
ST_CHECK_RUN_NAME="${ST_CHECK_RUN_NAME:-}"
# 昇格タイミング: continuous / batched / on-demand のいずれか（既定 on-demand /
# Req 3.2.2）。不正値（未列挙の文字列）は処理側で on-demand にフォールバック。
PROMOTE_MODE="${PROMOTE_MODE:-on-demand}"
# batched モードの cron 式（標準 cron 5 フィールド）。未設定 / 不正なら当該サイクル
# no-op + WARN（Req 3.2.6）。
PROMOTE_CRON="${PROMOTE_CRON:-}"
# 昇格失敗時の通知先 Issue 番号（数値）。未設定なら log のみ（Req 3.3.3）。
PROMOTE_FAIL_NOTIFY_ISSUE="${PROMOTE_FAIL_NOTIFY_ISSUE:-}"
# git / gh サブプロセスの個別 timeout（NFR 3.2）。Phase A の MERGE_QUEUE_GIT_TIMEOUT を
# 流用しても良いが、専用 env として分離して Phase B のみ調整できるようにする。
PROMOTE_GIT_TIMEOUT="${PROMOTE_GIT_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"

# ─── Phase A: Merge Queue Processor 設定 ───
# 標準機能としてデフォルト有効化（#112）。無効化したい場合は cron / launchd 側で
# MERGE_QUEUE_ENABLED=false を渡す。`=false` 以外（typo / 空 / `0` / `False` 等）は
# すべてデフォルト有効として扱われる（Req 2.10）。
MERGE_QUEUE_ENABLED="${MERGE_QUEUE_ENABLED:-true}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_MAX_PRS="${MERGE_QUEUE_MAX_PRS:-5}"
# git 操作の個別タイムアウト（秒）。watcher の最短実行間隔（既定 2 分）の半分以内を目安。
MERGE_QUEUE_GIT_TIMEOUT="${MERGE_QUEUE_GIT_TIMEOUT:-60}"
# Merge Queue が rebase / merge 試行する base branch 名。env var 名は後方互換のため
# 変更しない（NFR 1.2 / Req 2.4）。未設定時は BASE_BRANCH の連鎖 default を採用する
# （Req 2.1, 2.2, 2.3）。明示設定すれば BASE_BRANCH と異なる base を merge queue だけに
# 適用できる（基本は "main"。レガシー repo で master の場合等）。
MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}}"
# head branch prefix: 自動 rebase を許可する head ref のプレフィックス。
# idd-claude が作成する PR は `claude/issue-N-*` パターン。人間が書いた PR を
# 巻き込まないよう、デフォルトで `claude/` 始まりだけを対象にする。
# 複数許可したい場合はパイプ区切り正規表現で上書き（例: '^(claude|bot)/'）。
MERGE_QUEUE_HEAD_PATTERN="${MERGE_QUEUE_HEAD_PATTERN:-^claude/}"

# ─── Merge Queue Re-check Processor 設定 (#27) ───
# `needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
# 戻った PR のラベルを自動除去する。Phase A 本体（MERGE_QUEUE_ENABLED）とは
# 独立に制御可能。標準機能としてデフォルト有効化（#112）。無効化したい場合は
# MERGE_QUEUE_RECHECK_ENABLED=false を渡す。
MERGE_QUEUE_RECHECK_ENABLED="${MERGE_QUEUE_RECHECK_ENABLED:-true}"
# 1 サイクルで再評価する PR 数の上限（残りは次回サイクルに持ち越し）。
MERGE_QUEUE_RECHECK_MAX_PRS="${MERGE_QUEUE_RECHECK_MAX_PRS:-20}"

# ─── Phase D: Auto Rebase Processor 設定 (#17) ───
# `needs-rebase` 付き approved PR を Claude 経由で rebase し、変更ファイルが
# `MECHANICAL_PATHS` allowlist に閉じている場合のみ approve を維持して auto-merge
# に到達させる。allowlist 外の差分（= semantic 判断含む）が出た場合は approving
# review を dismissal API で剥がし、`ready-for-review` に戻して再レビューを誘導
# する。新規 opt-in 機能。`AUTO_REBASE_MODE=claude` を明示したリポジトリでのみ
# 起動し、未設定 / `off` / 不正値のリポジトリは導入前と完全に同一の挙動を維持
# する（Req 1.1, 1.3, NFR 1.1）。
# 既存「デフォルト有効化フラグの値正規化」ループには加えない（既定 OFF の opt-in
# 制のため、`=true` で有効化する 8 種とは別扱い）。
AUTO_REBASE_MODE="${AUTO_REBASE_MODE:-off}"
# 値正規化: `claude` のみ通し、それ以外（`off` / 未設定 / 空 / `on` / `true` /
# `CLAUDE` / typo 等）はすべて `off` に固定する（Req 1.3）。
case "$AUTO_REBASE_MODE" in
  claude) : ;;
  *)      AUTO_REBASE_MODE="off" ;;
esac
# mechanical と看做す path allowlist。カンマ区切り。各 pattern は bash glob
# 構文（`*` / `?` / `[abc]`）。空 / 未設定なら全件 semantic 扱い（Req 5.4 /
# NFR 3.2 保守的判定）。
MECHANICAL_PATHS="${MECHANICAL_PATHS:-}"
# Claude モデル ID。`PR_ITERATION_DEV_MODEL` と独立に上書き可能。
AUTO_REBASE_MODEL="${AUTO_REBASE_MODEL:-claude-opus-4-7}"
# Claude `--max-turns` 値。
AUTO_REBASE_MAX_TURNS="${AUTO_REBASE_MAX_TURNS:-30}"
# Claude rebase 試行の外側 timeout（秒）。NFR 5.1。
AUTO_REBASE_MAX_TURNS_SEC="${AUTO_REBASE_MAX_TURNS_SEC:-600}"
# git / gh の個別 timeout（秒）。既存 MERGE_QUEUE_GIT_TIMEOUT と同既定。
AUTO_REBASE_GIT_TIMEOUT="${AUTO_REBASE_GIT_TIMEOUT:-60}"
# 1 サイクルで処理する PR 数の上限。残りは次サイクル持ち越し。
AUTO_REBASE_MAX_PRS="${AUTO_REBASE_MAX_PRS:-3}"
# Prompt template の配置先（install.sh が `*.tmpl` glob で自動配置）。
AUTO_REBASE_TEMPLATE="${AUTO_REBASE_TEMPLATE:-$HOME/bin/auto-rebase-prompt.tmpl}"

# ─── PR Iteration Processor 設定 (#26) ───
# `needs-iteration` ラベル付き PR をレビューコメントに基づいて自動で iterate する。
# 標準機能としてデフォルト有効化（#112）。無効化したい場合は cron / launchd 側で
# PR_ITERATION_ENABLED=false を渡す。
PR_ITERATION_ENABLED="${PR_ITERATION_ENABLED:-true}"
# Iteration 専用モデル ID（既存 DEV_MODEL とは独立して上書き可能）。
PR_ITERATION_DEV_MODEL="${PR_ITERATION_DEV_MODEL:-claude-opus-4-7}"
# 1 iteration あたりの Claude 実行 turn 数上限（NFR 1.1）。
PR_ITERATION_MAX_TURNS="${PR_ITERATION_MAX_TURNS:-60}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し、AC 1.6 / NFR 1.2）。
PR_ITERATION_MAX_PRS="${PR_ITERATION_MAX_PRS:-3}"
# Issue #122: 旧 PR_ITERATION_MAX_ROUNDS が「明示的に設定されているか」を defaulting
# 前に確認しておき、後段の pi_resolve_max_rounds で「kind 固有 env も旧 env も全部
# 未設定」（Req 1.4）と「旧 env のみ設定」（Req 1.3）を区別できるようにする。
# `[ "${VAR+x}" = "x" ]` で「未設定 vs 空文字列」を識別する標準イディオム。
# #181 Part 3 で消費側 pi_resolve_max_rounds が modules/pr-iteration.sh へ移動したため、
# 本体内では参照箇所がなくなった（消費は module 側）。source で同一プロセスに読み込まれる
# ため共有は維持される。SC2034（本体内未使用）を局所的に抑止する。
if [ "${PR_ITERATION_MAX_ROUNDS+x}" = "x" ]; then
  # shellcheck disable=SC2034
  PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
else
  # shellcheck disable=SC2034
  PR_ITERATION_MAX_ROUNDS_LEGACY_SET="false"
fi
# 1 PR あたりの累計 iteration 上限。到達時は claude-failed に昇格（AC 7.2）。
# Issue #122 で kind 別の上限 env (PR_ITERATION_MAX_ROUNDS_IMPL /
# PR_ITERATION_MAX_ROUNDS_DESIGN) を導入したため、本変数は両 kind 共通の fallback
# として温存する（NFR 1.1）。kind 別の値が未設定の場合のみ参照される。
PR_ITERATION_MAX_ROUNDS="${PR_ITERATION_MAX_ROUNDS:-3}"
# Issue #122: kind 別の round 上限。値 `0` は「round 数超過のみによる escalate を
# 行わない」（無制限）を意味する sentinel（Req 2.1 / 2.3）。未設定なら旧
# PR_ITERATION_MAX_ROUNDS を fallback として使い、それも未設定なら impl=3 / design=0
# を適用する（Req 1.3 / 1.4）。解決は pi_resolve_max_rounds で行う。
PR_ITERATION_MAX_ROUNDS_IMPL="${PR_ITERATION_MAX_ROUNDS_IMPL:-}"
PR_ITERATION_MAX_ROUNDS_DESIGN="${PR_ITERATION_MAX_ROUNDS_DESIGN:-}"
# Issue #122: no-progress ループ検知の連続上限（Req 3.4）。round 終了時に head branch
# への新規 commit が観測されなかった round が連続して本値以上に達したら、kind に
# 依らず claude-failed に escalate する（Req 3.3 / 3.6）。
PR_ITERATION_NO_PROGRESS_LIMIT="${PR_ITERATION_NO_PROGRESS_LIMIT:-3}"
# 自動 iteration を許可する head ref のプレフィックス正規表現（impl PR 用）。
# 既定値は #35 で `^claude/` から `^claude/issue-[0-9]+-impl-` に厳格化された。
# 旧 `^claude/` 挙動に戻したい場合は cron / launchd 側で本変数を override すること
# （Migration Note は README 参照、AC 4.3 / 5.5 / NFR 4.2）。
PR_ITERATION_HEAD_PATTERN="${PR_ITERATION_HEAD_PATTERN:-^claude/issue-[0-9]+-impl-}"
# 各 git / gh 操作の個別タイムアウト（秒、NFR 1.3）。
PR_ITERATION_GIT_TIMEOUT="${PR_ITERATION_GIT_TIMEOUT:-60}"
# Iteration プロンプトテンプレートの配置先（install.sh --local が配置、impl PR 用）。
ITERATION_TEMPLATE="${ITERATION_TEMPLATE:-$HOME/bin/iteration-prompt.tmpl}"

# ─── PR Iteration Processor 設定: 設計 PR 拡張 (#35) ───
# 設計 PR (`claude/issue-<N>-design-<slug>`) にも `needs-iteration` で反復対応する
# フラグ。標準機能としてデフォルト有効化（#112）。無効化したい場合は cron / launchd
# 側で PR_ITERATION_DESIGN_ENABLED=false を渡す（AC 4.1 / 4.4 / 5.1）。
PR_ITERATION_DESIGN_ENABLED="${PR_ITERATION_DESIGN_ENABLED:-true}"
# 設計 PR の head branch pattern（jq の test() 互換 POSIX ERE）。
# idd-claude PjM テンプレートが作る設計 PR は `claude/issue-<N>-design-<slug>` 形式（AC 4.2）。
PR_ITERATION_DESIGN_HEAD_PATTERN="${PR_ITERATION_DESIGN_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
# 設計 PR 用 Iteration テンプレートの配置先（install.sh --local が配置）。
ITERATION_TEMPLATE_DESIGN="${ITERATION_TEMPLATE_DESIGN:-$HOME/bin/iteration-prompt-design.tmpl}"

# ─── Design Review Release Processor 設定 (#40) ───
# 設計 PR が merge された Issue から `awaiting-design-review` ラベルを自動除去し、
# ステータスコメントを 1 件投稿する。標準機能としてデフォルト有効化（#112）。
# 手動でラベルを外す運用に戻したい場合は cron / launchd 側で
# DESIGN_REVIEW_RELEASE_ENABLED=false を渡す。
DESIGN_REVIEW_RELEASE_ENABLED="${DESIGN_REVIEW_RELEASE_ENABLED:-true}"
# 1 サイクルで処理する Issue 数の上限（残りは次回サイクルに持ち越し、AC 5.1 / 5.2）。
DESIGN_REVIEW_RELEASE_MAX_ISSUES="${DESIGN_REVIEW_RELEASE_MAX_ISSUES:-10}"
# 設計 PR の head branch 規約（jq の test() 互換 POSIX ERE）。
# idd-claude PjM テンプレートが作る設計 PR は `claude/issue-<N>-design-<slug>` 形式。
DESIGN_REVIEW_RELEASE_HEAD_PATTERN="${DESIGN_REVIEW_RELEASE_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
# 各 gh 操作の個別タイムアウト（秒、AC 5.4）。専用 env var は導入せず、
# Phase A の MERGE_QUEUE_GIT_TIMEOUT を流用してデフォルト 60 秒。
DRR_GH_TIMEOUT="${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"

# ─── Stage Checkpoint 設定 (#68) ───
# impl / impl-resume の Stage A/B/C 単位で完了 checkpoint を成果物
# （impl-notes.md / review-notes.md / 既存 impl PR）の有無で観測し、失敗 Stage 以降
# のみを再実行する機能。標準機能としてデフォルト有効化（#112）。無効化したい場合は
# cron / launchd 側で STAGE_CHECKPOINT_ENABLED=false を渡す。`=false` 以外
# （空文字 / `0` / `False` / typo 等）はすべてデフォルト有効として扱われる（Req 2.10）。
STAGE_CHECKPOINT_ENABLED="${STAGE_CHECKPOINT_ENABLED:-true}"

# ─── Stage A Verify 設定 (#125) ───
# Stage A（Developer 実装）完了直前に、watcher が `tasks.md` 末尾の build/test/lint
# コマンド（verify タスク）を REPO_DIR で独立再実行することで、Developer の自己申告
# のみで build 不通が Stage A を通過するのを防ぐゲート（Req 1, 2 / Issue #125）。
#
#   - STAGE_A_VERIFY_ENABLED:  本機能の有効化。既定 true。`=false` 明示時のみ
#                              opt-out として stage-a-verify ゲートを skip し、本機能
#                              導入前と user-observable に同一の Stage A 完了判定を
#                              行う（Req 4.1 / NFR 1.1）。`=false` 以外は典型的な
#                              「true 既定」として扱う（後述: 既存 _idd_flag ループ
#                              には敢えて加えず、本機能は専用に `=false` 厳密一致
#                              でのみ opt-out 判定する。理由は tasks.md L9 の意図的
#                              切り出し）。
#   - STAGE_A_VERIFY_TIMEOUT:  verify 再実行の最大経過秒数。既定 600。大規模 repo は
#                              env で延長可能（NFR 3.3）。
#   - STAGE_A_VERIFY_COMMAND:  escape hatch。非空ならば tasks.md 解析を bypass して
#                              本 env 値を最優先で実行コマンドとする（Req 4.4 /
#                              NFR 2.2）。未対応言語向け。
STAGE_A_VERIFY_ENABLED="${STAGE_A_VERIFY_ENABLED:-true}"
STAGE_A_VERIFY_TIMEOUT="${STAGE_A_VERIFY_TIMEOUT:-600}"
STAGE_A_VERIFY_COMMAND="${STAGE_A_VERIFY_COMMAND:-}"

# ─── Tasks Count Gate 設定 (#147) ───
# Architect が `tasks.md` を確定した直後（design モードの Claude 実行 rc=0 直後）に
# watcher 側でタスク件数を機械的に再カウントし、件数レンジに応じて 3 段階の運用
# 判定（通常 / 警告 / Developer 抑止）を適用する harness ガード（Req 1, 2 / Issue #147）。
# 本機能は Issue #131 の Architect 側 budget overflow 検知（design.md `## Split
# Proposal`）を置き換えず、ハーネス側で独立かつ重畳に作用する追加レイヤとして導入する。
#
#   - TC_ENABLED:           本機能の有効化。既定 true。`=false` 明示時のみ opt-out
#                           として post-Architect の tasks-count 判定全体を skip し、
#                           本機能導入前と user-observable に同一の design 分岐挙動
#                           に戻る（Req 4.2 / NFR 2.1）。`=false` 以外は典型的な
#                           「true 既定」として扱う。
#   - TC_WARN_LOWER:        警告レンジの下限件数（既定 8、Req 2.2）。
#   - TC_WARN_UPPER:        警告レンジの上限件数（既定 10、Req 2.2）。
#   - TC_ESCALATE_LOWER:    エスカレーション（needs-decisions + Dev 抑止）の下限件数
#                           （既定 11、Req 2.3）。
#
# 件数 ≤ TC_WARN_LOWER-1（既定 ≤ 7）は通常進行（Req 2.1）。
# TC_WARN_LOWER ≤ 件数 ≤ TC_WARN_UPPER（既定 8〜10）は警告コメント 1 件投稿で進行（Req 2.2）。
# 件数 ≥ TC_ESCALATE_LOWER（既定 ≥ 11）は `needs-decisions` 付与 + エスカレーション
# コメント投稿で Developer 自動起動を抑止（Req 2.3 / 2.4）。
TC_ENABLED="${TC_ENABLED:-true}"
TC_WARN_LOWER="${TC_WARN_LOWER:-8}"
TC_WARN_UPPER="${TC_WARN_UPPER:-10}"
TC_ESCALATE_LOWER="${TC_ESCALATE_LOWER:-11}"

# ─── Phase E: Path Overlap Checker 設定 (#18) ───
# 新規 opt-in 機能。明示的に `=true` を指定したときだけ起動する（Req 1.1〜1.4）。
# `=true` 以外（未設定 / 空 / `false` / `0` / `True` / `1` / typo 等）はすべて off
# として扱う（Req 1.3）。本フラグは新規追加 = opt-in 制 + 既定 off が要件のため、
# 上記「デフォルト有効化フラグの値正規化」ループには **含めない**（#112 の 8 種
# 反転対象とは別扱い）。
# 詳細は docs/specs/18-phase-e-triage-path-overlap-hot-file/design.md を参照。
PATH_OVERLAP_CHECK="${PATH_OVERLAP_CHECK:-off}"

# ─── Phase 2: Per-task TDD Implementation Loop 設定 (#21) ───
# 新規 opt-in 機能。明示的に `=true` を指定したときだけ Stage A 内で per-task ループ
# （task 1 件ごとに fresh Implementer + fresh Reviewer を起動）に分岐する（Req 1.2）。
# `=true` 以外（未設定 / 空 / `false` / `0` / `True` / `1` / typo 等）はすべて off
# として扱い、本機能導入前と完全に同一の Stage A 挙動を維持する（Req 1.1, 1.3 /
# NFR 1.1）。本フラグは新規追加 = opt-in 制 + 既定 off が要件のため、上記
# 「デフォルト有効化フラグの値正規化」ループには **含めない**（#112 の 8 種反転対象
# とは別扱い）。詳細は docs/specs/21-phase-2-per-task-tdd-implementation-loop/design.md
# を参照。
#
# - PER_TASK_LOOP_ENABLED: 本機能の opt-in gate。`=true` 厳密一致のみ有効。
# - PER_TASK_MAX_TASKS:    安全装置（暴走防止）。1 ループで処理する task 件数上限。
#                          `0` / 空文字 / 未設定 で無制限（既定）。N > 0 が指定された
#                          場合、N 件目の Implementer 起動前に「上限到達」を
#                          claude-failed + Issue コメントで通知して停止する。
PER_TASK_LOOP_ENABLED="${PER_TASK_LOOP_ENABLED:-false}"
PER_TASK_MAX_TASKS="${PER_TASK_MAX_TASKS:-0}"

# LOG_DIR と LOCK_FILE は REPO_SLUG を挟むことで repo ごとに分離。
# 環境変数で明示上書きもできる。
LOG_DIR="${LOG_DIR:-$HOME/.issue-watcher/logs/$REPO_SLUG}"
LOCK_FILE="${LOCK_FILE:-/tmp/issue-watcher-${REPO_SLUG}.lock}"

# モデル設定
TRIAGE_MODEL="${TRIAGE_MODEL:-claude-sonnet-4-6}"   # Triage は軽量モデルで十分
DEV_MODEL="${DEV_MODEL:-claude-opus-4-7}"           # 本実装は Opus 4.7 + 1M context
TRIAGE_MAX_TURNS="${TRIAGE_MAX_TURNS:-15}"
DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"

# ─── Reviewer subagent 設定 (#20 Phase 1) ───
# impl 系モード（impl / impl-resume）の Developer 完了後に独立 context で起動する
# Reviewer サブエージェント用の env。既存の TRIAGE_* / DEV_* と独立に扱う。
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-7}"
REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-30}"

# ─── Debugger subagent 設定 (#22 Phase 3) ───
# 新規 opt-in 機能。明示的に `=true` を指定したときだけ Reviewer Round 2 reject 直前 /
# Developer BLOCKED 宣言時に Debugger サブエージェントを fresh Claude CLI セッションで
# 1 回起動して Fix Plan を `debugger-notes.md` に出力させ、後続 Developer 再起動 prompt
# に inline 注入する（Req 1.1, 1.2 / NFR 1.1）。`=true` 以外（未設定 / 空 / `false` / `0` /
# `True` / `1` / typo 等）はすべて off として扱い、本機能導入前と完全に同一の Reviewer
# Round 1/2 + `claude-failed` 経路を維持する（Req 1.3 / NFR 1.1）。本フラグは新規追加 =
# opt-in 制 + 既定 false が要件のため、上記「デフォルト有効化フラグの値正規化」ループには
# **含めない**（#112 の 8 種反転対象とは別扱い）。値判定は使用箇所で
# `[ "${DEBUGGER_ENABLED:-false}" = "true" ]` 完全一致のみ true 扱い。
# 詳細は docs/specs/22-phase-3-debugger-subagent-blocked-2-reje/design.md を参照。
#
# - DEBUGGER_ENABLED:    本機能の opt-in gate。`=true` 厳密一致のみ有効（既定 `false`）。
# - DEBUGGER_MODEL:      Debugger CLI に渡すモデル ID（既定 `claude-opus-4-7`）。
# - DEBUGGER_MAX_TURNS:  Debugger CLI の `--max-turns` 値（既定 `40`、web search 含む）。
DEBUGGER_ENABLED="${DEBUGGER_ENABLED:-false}"
DEBUGGER_MODEL="${DEBUGGER_MODEL:-claude-opus-4-7}"
DEBUGGER_MAX_TURNS="${DEBUGGER_MAX_TURNS:-40}"

# ─── Quota-Aware Watcher 設定 (#66) ───
# Claude Max の 5 時間ローリング quota を claude CLI の `rate_limit_event` JSON で
# 検知し、quota 起因の停止と他失敗を `needs-quota-wait` ラベルで分離する。
# reset 経過後に Quota Resume Processor が自動でラベル除去して通常 pickup に戻す。
# 標準機能としてデフォルト有効化（#112）。無効化したい場合は cron / launchd 側で
# QUOTA_AWARE_ENABLED=false を渡す（Req 1.3, 1.5 の opt-out 等価挙動を維持）。
QUOTA_AWARE_ENABLED="${QUOTA_AWARE_ENABLED:-true}"
# reset 予定時刻 + 本秒数を経過するまで `needs-quota-wait` を除去しない（NFR 3.3:
# 同 cron tick 内で付与/除去を往復させない構造的抑止）。
QUOTA_RESUME_GRACE_SEC="${QUOTA_RESUME_GRACE_SEC:-60}"

# ─── Phase C: Issue 並列化 (worktree slot + dispatcher, #16) ───
# 入口（auto-dev Issue 処理）の並列度を制御する env var 群。
# 既存運用との後方互換のため、すべてデフォルトで本機能導入前と同一挙動になるよう配置:
#   - PARALLEL_SLOTS 未設定 → 直列（slot=1）動作。slot-2 以降の lock / worktree は作成しない
#   - SLOT_INIT_HOOK 未設定 → フック非起動（本機能導入前と同一）
#   - WORKTREE_BASE_DIR / SLOT_LOCK_DIR は通常上書き不要。テスト用に override 可能。
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
PARALLEL_SLOTS="${PARALLEL_SLOTS:-1}"
SLOT_INIT_HOOK="${SLOT_INIT_HOOK:-}"
WORKTREE_BASE_DIR="${WORKTREE_BASE_DIR:-$HOME/.issue-watcher/worktrees}"
SLOT_LOCK_DIR="${SLOT_LOCK_DIR:-$HOME/.issue-watcher}"

# ─── impl-resume 保護 (Issue #67) ───
# `impl-resume` モードで対象ブランチが origin に既存する場合、当該ブランチの commit を
# 保持したまま resume する機能。標準機能としてデフォルト有効化（#112）。`=false` を
# 明示すると本機能導入前と完全に等価な挙動（origin/$BASE_BRANCH 起点での強制リセット +
# `git push --force-with-lease`）に戻る（Req 2.8, 3.4, 4.4, 5.3, 5.4 / NFR 1.1）。
# `=false` 以外（空文字 / `0` / `False` / typo 等）はすべてデフォルト有効として
# 扱われる（Req 2.10）。
IMPL_RESUME_PRESERVE_COMMITS="${IMPL_RESUME_PRESERVE_COMMITS:-true}"
# Developer がタスクを完了した時点で `tasks.md` の対応する未完了マーカー (`- [ ]`) を
# 完了マーカー (`- [x]`) に書き換え、`docs(tasks): mark <id> as done` で commit する
# 規約を有効化するフラグ。既定 `true`（#112 で既定維持）。
# `IMPL_RESUME_PRESERVE_COMMITS=false` （impl-resume 保護 OFF）の状態では Developer
# prompt 注入経路を通らないため、結果的に進捗追跡指示は注入されない（NFR 1.1 / Req 5.3
# を構造的に保証）。`IMPL_RESUME_PROGRESS_TRACKING=false` を明示すると
# `IMPL_RESUME_PRESERVE_COMMITS=true` の場合でも進捗マーカー更新指示を抑止できる
# （Req 2.9, 5.2）。
IMPL_RESUME_PROGRESS_TRACKING="${IMPL_RESUME_PROGRESS_TRACKING:-true}"

# ─── デフォルト有効化フラグの値正規化 (#112 Req 2.10) ───
# 上記 9 種の env var はすべて「`=false` を明示した場合のみ無効、それ以外
# （未設定 / 空文字 / `0` / `False` / `Yes` / typo 等）はすべてデフォルト有効」
# として扱う。後続コードの `[ "$VAR" = "true" ]` / `[ "$VAR" != "true" ]` /
# jq の `$design_enabled == "true"` 等の比較を変更せず正規化で吸収するため、
# 値を厳密な "true" / "false" の 2 値に正規化する。
for _idd_flag in \
    MERGE_QUEUE_ENABLED \
    MERGE_QUEUE_RECHECK_ENABLED \
    PR_ITERATION_ENABLED \
    PR_ITERATION_DESIGN_ENABLED \
    DESIGN_REVIEW_RELEASE_ENABLED \
    STAGE_CHECKPOINT_ENABLED \
    QUOTA_AWARE_ENABLED \
    IMPL_RESUME_PRESERVE_COMMITS \
    IMPL_RESUME_PROGRESS_TRACKING; do
  if [ "${!_idd_flag}" = "false" ]; then
    printf -v "$_idd_flag" '%s' "false"
  else
    printf -v "$_idd_flag" '%s' "true"
  fi
done
unset _idd_flag

# Triage プロンプトテンプレート
TRIAGE_TEMPLATE="${TRIAGE_TEMPLATE:-$HOME/bin/triage-prompt.tmpl}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# gtimeout 透過フォールバック（macOS coreutils 互換 / #168）
#
# macOS には GNU coreutils の `timeout` が標準搭載されておらず、`brew install coreutils`
# で導入しても通常 `gtimeout` という名前でインストールされる。`timeout` が PATH 上に
# 無く `gtimeout` がある環境では、`timeout` という呼び出しを `gtimeout` の実行に解決する
# シェル関数を定義し、以降のスクリプト内の `timeout ...` 呼び出し（コマンド置換 / サブ
# シェル / バックグラウンド fork / オプション付き呼び出し）を透過的に gtimeout へ委譲する。
# `export -f` で `bash -c` 経由の子 bash にも関数を継承させる（Req 2.3）。
#
# Linux など `timeout` が存在する環境ではこの関数を定義しないため、挙動は一切変わらない
# （NFR 1.1 / 1.2）。本フォールバックは下の前提ツールチェックより前に確立する（Req 1.3）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
if ! command -v timeout >/dev/null 2>&1 && command -v gtimeout >/dev/null 2>&1; then
  # shellcheck disable=SC2317  # 関数本体は後続の `timeout ...` 呼び出しから実行される
  timeout() { gtimeout "$@"; }
  export -f timeout
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 前提ツールチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in gh jq claude git flock; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd が見つかりません。PATH を確認してください。" >&2
    exit 1
  }
done

# timeout は gtimeout フォールバック（上記）込みで判定する。フォールバック関数が定義済み
# なら `command -v timeout` は function として true を返す。いずれも無い場合は macOS 向けの
# 解決手順を添えて明示エラーで停止する（Req 3.1 / 3.2 / 3.3）。
command -v timeout >/dev/null 2>&1 || {
  echo "Error: timeout コマンドが見つかりません。PATH を確認してください。" >&2
  echo "  macOS では 'brew install coreutils' で gtimeout を導入すると自動検出されます。" >&2
  exit 1
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# モジュール動的ロード基盤（#177 Part 1）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 本体と同階層の modules/ から必須モジュール（低レベル共通ユーティリティ等）を source する。
# install.sh が local-watcher/bin/modules/ → $HOME/bin/modules/ に配置する。
# 必須モジュールが欠落していたら、復旧手順を添えて exit 1 で安全停止する（silent fail を作らない）。
# 配置先解決は $HOME 直書きせず BASH_SOURCE 基準にし、開発 repo 直実行（local-watcher/bin/）と
# インストール後（$HOME/bin/）の双方で同一ロジックが効くようにする。
IDD_MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/modules"
# source 順序は機能的に任意（bash の遅延束縛で前方参照は呼び出し時に解決される）が、
# 可読性のため最も低レベルな core_utils.sh を先頭に置き、以降は #180 Part 2 で切り出した
# 3 プロセッサ（quota-aware / merge-queue / auto-rebase）、#181 Part 3 で切り出した
# 3 プロセッサ（promote-pipeline / pr-iteration / stage-a-verify）を並べる。
REQUIRED_MODULES=( "core_utils.sh" "quota-aware.sh" "merge-queue.sh" "auto-rebase.sh" "promote-pipeline.sh" "pr-iteration.sh" "stage-a-verify.sh" )
for _idd_mod in "${REQUIRED_MODULES[@]}"; do
  _idd_mod_path="$IDD_MODULE_DIR/$_idd_mod"
  if [ ! -f "$_idd_mod_path" ]; then
    echo "Error: 必須モジュールが見つかりません: $_idd_mod_path" >&2
    echo "  install.sh --local を再実行して modules/ を配置してください。" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$_idd_mod_path"
done
unset _idd_mod _idd_mod_path

[ -f "$TRIAGE_TEMPLATE" ] || {
  echo "Error: Triage テンプレートが見つかりません: $TRIAGE_TEMPLATE" >&2
  exit 1
}

# PR Iteration が有効化されている時のみ template の存在を必須化する（#112 以降デフォルト有効）。
# 明示的に無効化（PR_ITERATION_ENABLED=false）した場合は template 未配置でも watcher 全体を
# 起動できるよう、無条件チェックを避ける。
if [ "$PR_ITERATION_ENABLED" = "true" ] && [ ! -f "$ITERATION_TEMPLATE" ]; then
  echo "Error: Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# 設計 PR Iteration が有効化されている時のみ design 用 template を必須化（#35 AC 2.2）。
if [ "$PR_ITERATION_ENABLED" = "true" ] \
   && [ "$PR_ITERATION_DESIGN_ENABLED" = "true" ] \
   && [ ! -f "$ITERATION_TEMPLATE_DESIGN" ]; then
  echo "Error: 設計 PR 用 Iteration テンプレートが見つかりません: $ITERATION_TEMPLATE_DESIGN" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

# Phase D (Auto Rebase) が有効化されている時のみ template の存在を必須化（opt-in
# gate）。`AUTO_REBASE_MODE=off`（既定）時は template 未配置でも watcher 全体を
# 起動できるよう、無条件チェックを避ける（NFR 1.1）。
if [ "$AUTO_REBASE_MODE" != "off" ] && [ ! -f "$AUTO_REBASE_TEMPLATE" ]; then
  echo "Error: Auto Rebase テンプレートが見つかりません: $AUTO_REBASE_TEMPLATE" >&2
  echo "  install.sh --local 再実行で配置されます。" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"

# 解決済み base branch を起動時 log に出力（Req 1.7 / NFR 4.1）。
# 運用者が cron mailer / log で `base-branch=...` を grep できるよう、
# 既定値（main）でも明示的に出力する。
echo "[$(date '+%F %T')] base-branch=${BASE_BRANCH} merge-queue-base=${MERGE_QUEUE_BASE_BRANCH} auto-rebase=${AUTO_REBASE_MODE}"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 多重起動防止
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
exec 200>"$LOCK_FILE"
flock -n 200 || {
  echo "[$(date '+%F %T')] 他のインスタンスが実行中のためスキップ"
  exit 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# リポジトリを最新化
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
cd "$REPO_DIR"
git fetch origin --prune

# Issue #119 Req 3.1〜3.5: cycle 冒頭で working tree が dirty なまま
# `git checkout $BASE_BRANCH` に進むと「local changes would be overwritten」
# 等の git 純正 stderr が repo 識別子なしで cron.log に流れ、複数リポ運用時に
# 「processor ステージに到達しなかった silent failure」を grep で検知できない。
# `git status --porcelain` で先読みし、dirty なら以下 4 行を `watcher:` prefix で
# 1 イベント連続出力し、processor ステージを開始せずに exit 非 0 で抜ける。
# auto-recover は本要件 Out of Scope（別 Issue）。本実装は可視化のみを行う。
_dirty_status=$(git status --porcelain 2>/dev/null || true)
if [ -n "$_dirty_status" ]; then
  _current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  # dirty_files: 行数（CR/CRLF も 1 行扱いになるよう wc -l を使う）。空文字列は
  # 上の `-n "$_dirty_status"` で除外済み。
  _dirty_files=$(printf '%s\n' "$_dirty_status" | wc -l | tr -d ' ')
  _head_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  echo "[$(date '+%F %T')] watcher: [$REPO] dirty working tree blocks BASE_BRANCH checkout" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   current_branch=${_current_branch}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   dirty_files=${_dirty_files}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   head=${_head_sha}" >&2
  echo "[$(date '+%F %T')] watcher: [$REPO]   action=escalate" >&2
  exit 1
fi
unset _dirty_status

git checkout "$BASE_BRANCH"
git pull --ff-only origin "$BASE_BRANCH"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Quota-Aware Watcher Helpers (#66) — modules/quota-aware.sh へ切り出し済み（#180 Part 2）
#   qa_detect_rate_limit / qa_run_claude_stage / qa_persist_reset_time /
#   qa_load_reset_time / qa_build_escalation_comment / build_partial_escalation_comment /
#   qa_handle_quota_exceeded / process_quota_resume は modules/quota-aware.sh が定義する。
#   call site（process_quota_resume）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Quota Resume Processor を全 Processor の先頭で実行する（Req 5.1, 5.6 / NFR 3.2）。
# 失敗時も後続 Processor を阻害しないよう || qa_warn で吸収。
process_quota_resume || qa_warn "process_quota_resume が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor — modules/merge-queue.sh へ切り出し済み（#180 Part 2）
#   mq_pr_has_label / mq_handle_conflict / mq_try_rebase_pr / process_merge_queue は
#   modules/merge-queue.sh が定義する。Re-check（mqr_* / process_merge_queue_recheck）も
#   同モジュールに同居する。call site（process_merge_queue 等）は実行順序温存のため
#   本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase D: Auto Rebase Processor (#17) — modules/auto-rebase.sh へ切り出し済み（#180 Part 2）
#   ar_fetch_candidates / ar_build_prompt / ar_run_claude_rebase / ar_classify_diff /
#   ar_apply_mechanical / ar_dismiss_all_approvals / ar_apply_semantic /
#   ar_escalate_to_failed / ar_handle_pr / process_auto_rebase は modules/auto-rebase.sh が
#   定義する。call site（process_auto_rebase）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Re-check Processor (#27) — modules/merge-queue.sh へ切り出し済み（#180 Part 2）
#   mqr_log / mqr_warn / mqr_error / process_merge_queue_recheck は merge-queue.sh が定義する。
#   call site（process_merge_queue_recheck）は実行順序温存のため本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC 1.1: Phase A 本体ループの直前に Re-check Processor を 1 回起動
process_merge_queue_recheck || mqr_warn "process_merge_queue_recheck が想定外のエラーで終了しました（後続処理は継続）"

# AC 1.1: ピックアップ済み Issue の処理ループに入る前に 1 回だけ起動
process_merge_queue || mq_warn "process_merge_queue が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Phase D: Auto Rebase Processor (#17)
# Re-check → Phase A 本体 の直後に直列配置し、Req 3.1〜3.3 を構造的に保証する
# （design.md「順序根拠」参照）。`AUTO_REBASE_MODE=off`（既定）では関数冒頭で
# 早期 return するため、未設定環境では実質 no-op（NFR 1.1）。
process_auto_rebase || ar_warn "process_auto_rebase が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase B: Promote Pipeline Processor (#15) + Phase E: Path Overlap Checker (#18)
#   — modules/promote-pipeline.sh へ切り出し済み（#181 Part 3）
#   Promote 関数群（pp_resolve_target_branch / pp_collect_merged_issues / pp_get_st_state /
#   pp_handle_st_failure / pp_handle_st_success / pp_do_promote / pp_summary /
#   process_promote_pipeline ほか）と Path Overlap 関数群（po_log / po_warn /
#   po_parse_triage_edit_paths / po_compute_overlap / po_check_dispatch_gate /
#   po_apply_awaiting_slot / po_clear_awaiting_slot ほか）は modules/promote-pipeline.sh が
#   定義する（Path Overlap は独立せず Promote へ同居 / design.md decision 3）。
#   ロガー pp_log / pp_warn / pp_error は core_utils.sh に定義済み（#180 Part 2）。
#   call site（process_promote_pipeline / po_check_dispatch_gate）は実行順序温存のため
#   本体の従来位置に残す。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# AC 1.1: Phase A 本体の直後に Promote Pipeline Processor を 1 回起動。
# fail-continue を維持するため `|| pp_warn ...` で例外を吸収（NFR 3.1）。
process_promote_pipeline \
  || pp_warn "process_promote_pipeline が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PR Iteration Processor (#26) — modules/pr-iteration.sh へ切り出し済み（#181 Part 3）
#   `needs-iteration` ラベル付き PR を fresh context の Claude で反復対応する processor。
#   pi_pr_has_label / pi_fetch_candidate_prs / pi_resolve_max_rounds / pi_read_round_counter /
#   pi_read_no_progress_streak / pi_write_marker / pi_finalize_labels / pi_classify_pr_kind /
#   pi_select_template / build_recovery_hint / pi_escalate_to_failed / pi_build_iteration_prompt /
#   pi_detect_quota_soft_fail / pi_run_iteration / process_pr_iteration ほかは
#   modules/pr-iteration.sh が定義する。ロガー pi_log / pi_warn / pi_error は core_utils.sh
#   に定義済み（#180 Part 2）。call site（process_pr_iteration）は実行順序温存のため
#   本体の従来位置（Phase A 直後）に残す。標準機能としてデフォルト有効（#112）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Design Review Release Processor (#40)
#
# `awaiting-design-review` ラベルが付いた Issue について、リンクされた設計 PR
# （head branch が `^claude/issue-<N>-design-` 規約）が merged 状態なら、
# Issue からラベルを除去してステータスコメントを 1 件投稿する。
#
# 標準機能としてデフォルト有効（#112）。手動でラベルを外す運用に戻したい場合は
# DESIGN_REVIEW_RELEASE_ENABLED=false を明示する。
# 既存 LOCK_FILE / LOG_DIR / exit code / cron 登録文字列は不変。
# Phase A / Re-check / PR Iteration と同じ flock 境界内で直列実行する。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 与えられた Issue が、本機能が以前のサイクルで投稿したステータスコメントを既に
# 持っているかを判定する（hidden HTML marker による既処理判定）。
#   入力: $1 = issue_number
#   出力: stdout に "true" or "false"
#   返り値: 0 = 判定成功 / 1 = API エラー or タイムアウト（呼び出し元で WARN）
# AC 4.2 / 4.3 / 4.4 / 5.3 / 5.4
drr_already_processed() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(timeout "$DRR_GH_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local marker_re="idd-claude:design-review-release issue=${issue_number}"
  if echo "$comments_json" | jq -e --arg re "$marker_re" \
      '.comments // [] | map(.body // "") | any(test($re))' >/dev/null 2>&1; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# 与えられた Issue 番号にリンクされた、head branch が DESIGN_REVIEW_RELEASE_HEAD_PATTERN
# にマッチし、かつ body に `Refs #<issue_number>` を含む merged PR の番号を返す。
# 複数件マッチ時は最大番号 = 最新を採用する。
#   入力: $1 = issue_number
#   出力: stdout に PR 番号、該当無しなら空文字
#   返り値: 0 = 検出 or 該当無し（共に正常） / 1 = API エラー or タイムアウト
# AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6 / 5.3 / 5.4 / NFR 2.2
drr_find_merged_design_pr() {
  local issue_number="$1"
  local prs_json
  # head pattern を server-side クエリで一次絞り込み（in:head + 規約 prefix）。
  # 複数件マッチを許容するため limit=20。
  # 注意（Issue #80）: GitHub の text search はトークン分解（"claude" / "issue" / "${N}" /
  # "design" の各語）で他 Issue 用の merged 設計 PR もヒットさせるため、ここでは候補
  # 取得（noisy）に留め、最終一致判定は後段の jq で issue 番号 fix の strict prefix で行う。
  if ! prs_json=$(timeout "$DRR_GH_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --search "is:pr is:merged claude/issue-${issue_number}-design- in:head" \
      --json number,headRefName,mergedAt \
      --limit 20 2>/dev/null); then
    return 1
  fi

  # Issue #80: head 名を issue 番号で strict 比較する（旧 `^claude/issue-[0-9]+-design-`
  # では他 Issue 用 PR が通過していた）。body の `Refs #N` 検査は cross-reference
  # （Architect が design PR 本文で別 Issue を参照する）と衝突して誤検知の原因に
  # なっていたため drop。head が `claude/issue-${N}-design-<slug>` で始まることを
  # 唯一の同定条件とする。
  # 同 issue 番号の merged 設計 PR が複数ある場合（再 design 等）は、PR 番号最大
  # （= 最新と看做す）を採用。
  local strict_head_prefix="claude/issue-${issue_number}-design-"
  local pr_number
  pr_number=$(echo "$prs_json" | jq -r \
    --arg prefix "$strict_head_prefix" \
    '[(. // [])[]
      | select(.headRefName | startswith($prefix))
      | .number
    ] | sort | last // ""' 2>/dev/null || echo "")
  echo "$pr_number"
  return 0
}

# 確定した除去対象 Issue に対し、`awaiting-design-review` ラベル除去 + ステータス
# コメント投稿を順次実行する。PR 側操作・push・close は一切行わない（NFR 2.1 / 2.3）。
#   入力: $1 = issue_number, $2 = merged_pr_number
#   返り値: 0 = ラベル除去 + コメント投稿 成功 / 1 = いずれかが失敗
# AC 3.1 / 3.2 / 3.3 / 3.4 / 3.5 / 3.6 / 5.3 / 5.4 / 6.7 / 7.6
drr_remove_label_and_comment() {
  local issue_number="$1"
  local merged_pr_number="$2"

  # AC 3.1 / 3.4: ラベル除去。失敗時はコメントを投稿しない。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue edit "$issue_number" \
      --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_DESIGN" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ラベル除去 API 失敗（タイムアウト or 4xx/5xx）。コメント投稿は skip し、次サイクルで再試行します。"
    return 1
  fi

  # AC 3.2 / 3.3 / 4.3: ステータスコメント本文（末尾に hidden marker を含む）。
  local body
  body=$(cat <<EOF
## 自動: 設計 PR merge を検出

設計 PR #${merged_pr_number} が merged されました。
本 Issue から \`awaiting-design-review\` ラベルを自動除去しました。

次回 cron tick で Developer が **impl-resume モード**で自動起動し、
\`docs/specs/<N>-<slug>/\` 配下の design.md / tasks.md に従って実装 PR を作成します。

---

_本コメントは \`local-watcher/bin/issue-watcher.sh\` の Design Review Release Processor が
投稿しました（#112 以降デフォルト有効。\`DESIGN_REVIEW_RELEASE_ENABLED=false\` で無効化可）。_

<!-- idd-claude:design-review-release issue=${issue_number} pr=${merged_pr_number} -->
EOF
)

  # AC 3.5: コメント投稿失敗時もラベルは除去済み。次サイクルで Issue は impl-resume へ進める。
  if ! timeout "$DRR_GH_TIMEOUT" gh issue comment "$issue_number" \
      --repo "$REPO" \
      --body "$body" >/dev/null 2>&1; then
    drr_warn "Issue #${issue_number}: ステータスコメント投稿 API 失敗（ラベルは除去済み、後続 Issue 処理は継続）。"
    return 1
  fi

  return 0
}

# Design Review Release Processor のエントリ関数。
# 1 watcher サイクル内で `awaiting-design-review` 付き Issue を検出し、
# 設計 PR が merged なら ラベル除去 + コメント投稿を順次実行する。
# AC 1.1 / 1.4 / 2.1 / 2.7 / 4.1 / 4.4 / 4.5 / 5.2 / 5.5 / 6.1 / 6.2 / 6.3 / 7.5
process_design_review_release() {
  # AC 1.1 / 1.4 / 7.5: opt-out gate（#112 以降デフォルト有効。無効化時は完全スキップ）
  if [ "$DESIGN_REVIEW_RELEASE_ENABLED" != "true" ]; then
    return 0
  fi

  drr_log "サイクル開始 (max_issues=${DESIGN_REVIEW_RELEASE_MAX_ISSUES}, head_pattern=${DESIGN_REVIEW_RELEASE_HEAD_PATTERN}, timeout=${DRR_GH_TIMEOUT}s)"

  # AC 2.1 / 2.7 / 4.1 / 4.5: server-side filter で `awaiting-design-review` を必須に、
  # `claude-failed` / `needs-decisions` を除外。人間が先に手動除去した Issue は候補に上がらない。
  # Issue #54 Req 1.1 / 5.1: PR 専用ラベル `needs-iteration` が Issue 側に誤付与された
  # ケースは Documentation Set 全体で「PR 適用」と一貫させるため、ここでも候補から除外する。
  local issues_json
  if ! issues_json=$(timeout "$DRR_GH_TIMEOUT" gh issue list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_NEEDS_ITERATION\"" \
      --json number,title,url,labels \
      --limit 100 2>/dev/null); then
    drr_warn "候補 Issue 取得 API 失敗（タイムアウト or 4xx/5xx）。本サイクルの Design Review Release Processor は skip。"
    return 0
  fi

  # client-side fail-safe filter: label 配列に `awaiting-design-review` あり、
  # `claude-failed` / `needs-decisions` なし（server-side filter の二重ガード）。
  local filtered_json
  filtered_json=$(echo "$issues_json" | jq -c \
    --arg awaiting "$LABEL_AWAITING_DESIGN" \
    --arg failed "$LABEL_FAILED" \
    --arg needs_decisions "$LABEL_NEEDS_DECISIONS" \
    '[(. // [])[]
      | select((.labels // []) | map(.name) | index($awaiting))
      | select(((.labels // []) | map(.name) | index($failed)) | not)
      | select(((.labels // []) | map(.name) | index($needs_decisions)) | not)
    ]' 2>/dev/null || echo "[]")

  local total
  total=$(echo "$filtered_json" | jq 'length' 2>/dev/null || echo 0)
  local target_count="$total"
  local skipped_overflow=0

  if [ "$total" -gt "$DESIGN_REVIEW_RELEASE_MAX_ISSUES" ]; then
    target_count="$DESIGN_REVIEW_RELEASE_MAX_ISSUES"
    skipped_overflow=$((total - DESIGN_REVIEW_RELEASE_MAX_ISSUES))
    drr_log "対象候補 ${total} 件中、上限 ${DESIGN_REVIEW_RELEASE_MAX_ISSUES} 件のみ処理（${skipped_overflow} 件は次回持ち越し: overflow=${skipped_overflow}）"
  else
    drr_log "対象候補 ${total} 件、処理対象 ${target_count} 件、overflow=${skipped_overflow}"
  fi

  if [ "$target_count" -eq 0 ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local issue_iter
  issue_iter=$(echo "$filtered_json" | jq -c ".[0:${target_count}][]" 2>/dev/null || echo "")
  if [ -z "$issue_iter" ]; then
    drr_log "サマリ: removed=0, kept=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local kept=0
  local skipped=0
  local failed=0
  # AC 4.4: 同一サイクル内での重複処理ガード（gh issue list の結果は一意のはずだが念のため）
  local processed_numbers=""

  while IFS= read -r issue_json; do
    [ -z "$issue_json" ] && continue
    local issue_number
    issue_number=$(echo "$issue_json" | jq -r '.number' 2>/dev/null || echo "")
    if [ -z "$issue_number" ] || [ "$issue_number" = "null" ]; then
      drr_warn "Issue 番号の解析に失敗: ${issue_json}"
      failed=$((failed + 1))
      continue
    fi

    # AC 4.4: 同一サイクル内で同一 Issue を 2 回処理しない
    case " $processed_numbers " in
      *" $issue_number "*)
        drr_log "Issue #${issue_number}: 同一サイクル内で既に処理済み、skip"
        skipped=$((skipped + 1))
        continue
        ;;
    esac
    processed_numbers="$processed_numbers $issue_number"

    # AC 4.2 / 4.3: 既処理判定（hidden marker チェック）
    local already
    if ! already=$(drr_already_processed "$issue_number"); then
      drr_warn "Issue #${issue_number}: 既処理判定 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ "$already" = "true" ]; then
      drr_log "Issue #${issue_number}: action=skip (already processed)"
      skipped=$((skipped + 1))
      continue
    fi

    # AC 2.2 / 2.3 / 2.4 / 2.5 / 2.6: merged 設計 PR の検出
    local merged_pr_number
    if ! merged_pr_number=$(drr_find_merged_design_pr "$issue_number"); then
      drr_warn "Issue #${issue_number}: PR 検出 API 失敗、当該 Issue を skip し次 Issue へ"
      failed=$((failed + 1))
      continue
    fi
    if [ -z "$merged_pr_number" ]; then
      # AC 2.5 / 2.6: リンク PR 0 件 or merged 0 件 → kept
      drr_log "Issue #${issue_number}: merged-design-pr=none, action=kept"
      kept=$((kept + 1))
      continue
    fi

    # AC 3.1 / 3.2 / 3.3: ラベル除去 + ステータスコメント投稿
    if drr_remove_label_and_comment "$issue_number" "$merged_pr_number"; then
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=label removed + commented"
      removed=$((removed + 1))
    else
      drr_log "Issue #${issue_number}: merged-design-pr=#${merged_pr_number}, action=fail"
      failed=$((failed + 1))
    fi
  done <<< "$issue_iter"

  drr_log "サマリ: removed=${removed}, kept=${kept}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"
  return 0
}

# Phase A 直後に PR Iteration Processor を実行（AC 8.1 / 8.2: 同一 flock 内で直列実行）
process_pr_iteration || pi_warn "process_pr_iteration が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# Design Review Release Processor を Issue 処理ループの直前に実行（#40 AC 1.3 / 1.5）
process_design_review_release || drr_warn "process_design_review_release が想定外のエラーで終了しました（後続 Issue 処理は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stage A Verify Module (#125) — modules/stage-a-verify.sh へ切り出し済み（#181 Part 3）
#   Stage A 完了直前に tasks.md 末尾の build/test/lint コマンドを watcher 自身が独立再実行
#   する verify ゲート。sav_log / sav_warn / sav_error / _sav_cmd_starts_with_keyword /
#   stage_a_verify_extract_command / stage_a_verify_resolve_command / stage_a_verify_round_path /
#   stage_a_verify_read_round / stage_a_verify_bump_round / stage_a_verify_reset_round /
#   _sav_handle_failure / stage_a_verify_run は modules/stage-a-verify.sh が定義する。
#   Part 1 想定の impl-gates.sh 集約から独立分離（design.md decision 2）。sc_* / tc_* /
#   stage_checkpoint_* は本モジュールへ移さず本体に残す。call site（run_impl_pipeline 内の
#   stage_a_verify_run）は実行順序温存のため本体の従来位置に残す。
#   設計参照: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Stage Checkpoint Module (#68) — impl / impl-resume の Stage 単位 resume
#
# Stage A/B/C の完了 checkpoint を成果物（impl-notes.md / review-notes.md /
# 既存 impl PR）の存在で観測し、failed Stage 以降のみを再実行する機能。標準機能と
# してデフォルト有効（#112）。`STAGE_CHECKPOINT_ENABLED=true`（既定）のとき
# run_impl_pipeline 冒頭から呼び出される。`=false` 明示時は呼ばれない。
#
# 関数群:
#   - sc_log / sc_warn / sc_error               : `stage-checkpoint:` prefix logger
#   - stage_checkpoint_has_impl_notes           : Stage A 完了観測（branch HEAD tracked）
#   - stage_checkpoint_read_review_result       : Stage B 完了観測（review-notes.md）
#   - stage_checkpoint_find_impl_pr             : Stage C 完了観測（既存 impl PR）
#   - stage_checkpoint_resolve_resume_point     : decision table → START_STAGE 決定
#
# 設計参照: docs/specs/68-feat-watcher-stage-checkpoint-reviewer-p/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Stage Checkpoint 専用ロガー（既存 mq_log / pi_log / rv_log と同形式）。
# `stage-checkpoint:` prefix で grep 抽出可能（NFR 2.2）。warn / error は stderr へ。
sc_log() {
  echo "[$(date '+%F %T')] stage-checkpoint: $*"
}
sc_warn() {
  echo "[$(date '+%F %T')] stage-checkpoint: WARN: $*" >&2
}
sc_error() {
  echo "[$(date '+%F %T')] stage-checkpoint: ERROR: $*" >&2
}

# ─── stage_checkpoint_has_impl_notes ───
#
# Stage A 完了 checkpoint（impl-notes.md）の **当該 Issue branch HEAD 上での tracked**
# を判定する。working tree のみに存在し未 commit のファイルは不採用とする
# （Req 4.1, 4.2, 4.4 / 部分実行を許さない、Req 5.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL（呼び出し元 _slot_run_issue が設定済み）
# 戻り値: 0 = checkpoint 採用 / 1 = 不採用（不在 or untracked）
# 副作用: なし
stage_checkpoint_has_impl_notes() {
  local rel="$SPEC_DIR_REL/impl-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 1
  # branch HEAD で tracked であることを確認（main 由来 or 未 commit ファイルは不採用）。
  # `git ls-tree --name-only HEAD -- <path>` は tracked なら path をそのまま echo し、
  # untracked なら空出力。`>/dev/null` で出力を捨て、exit code のみで判定。
  local out
  out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$out" ]
}

# ─── stage_checkpoint_read_review_result ───
#
# Stage B 完了 checkpoint（review-notes.md）の RESULT 行を抽出する。
# 既存 parse_review_result を再利用し、契約は変更しない（Req 1.2, 4.3, 4.4）。
# branch HEAD tracked チェックを先行して、未 commit / main 由来の残骸は不採用とする。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = approve / 1 = reject / 2 = 不在 or RESULT 行欠落 or untracked
# stdout: parse_review_result と同形式の TSV `<result>\t<categories>\t<targets>`
#         （戻り値 2 のときは何も出力しない）
stage_checkpoint_read_review_result() {
  local rel="$SPEC_DIR_REL/review-notes.md"
  local path="$REPO_DIR/$rel"
  [ -f "$path" ] || return 2
  local tracked
  tracked=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$rel" 2>/dev/null || true)
  [ -n "$tracked" ] || return 2
  local parsed
  parsed=$(parse_review_result "$path") || return 2
  local result
  result=$(echo "$parsed" | cut -f1)
  echo "$parsed"
  case "$result" in
    approve) return 0 ;;
    reject)  return 1 ;;
    *)       return 2 ;;
  esac
}

# ─── stage_checkpoint_find_impl_pr ───
#
# Stage C 完了（impl PR の存在）を観測する。OPEN / MERGED / CLOSED いずれの状態でも
# 「Stage C 後の状態」とみなして自動進行を停止する（Req 1.3, 2.6）。CLOSED は人間判断に
# よる close と解釈し、自動再開はしない。
#
# 入力: 環境変数 REPO / BRANCH
# 戻り値: 0 = 既存 impl PR あり / 1 = なし / 2 = gh API エラー
# stdout: `<pr_number>,<state>`（複数の場合は最新 1 件のみ）
stage_checkpoint_find_impl_pr() {
  local prs
  prs=$(gh pr list --repo "$REPO" --head "$BRANCH" --state all \
        --json number,state --limit 5 2>/dev/null) || return 2
  local found
  found=$(echo "$prs" | jq -r '[.[] | select(.state == "OPEN" or .state == "MERGED" or .state == "CLOSED")] | .[0] // empty' 2>/dev/null || true)
  [ -n "$found" ] || return 1
  echo "$found" | jq -r '"\(.number),\(.state)"' 2>/dev/null || return 2
  return 0
}

# ─── stage_checkpoint_resolve_resume_point ───
#
# Stage A/B/C の checkpoint を観測し、START_STAGE を 1 つに決定する。
# 出力 domain: A / B / C / TERMINAL_OK / TERMINAL_FAILED。
#
# Decision Table（design.md と同期、設計参照: docs/specs/68-*/design.md）:
#   既存 PR あり                                      → TERMINAL_OK
#   impl-notes 無 / review-notes 有 (任意)            → A (INCONSISTENT, Req 5.1)
#   impl-notes 無 / review-notes 無                   → A (Req 2.2)
#   impl-notes 有 / review-notes 無                   → B (Req 2.3)
#   impl-notes 有 / review-notes parse 失敗            → B (Req 4.3)
#   impl-notes 有 / RESULT=approve                     → C (Req 2.4)
#   impl-notes 有 / RESULT=reject (round=2 と推定)     → TERMINAL_FAILED (Req 2.5)
#   impl-notes 有 / RESULT=reject (round=1 と推定)     → A (D-3, INCONSISTENT 扱い)
#
# round=1 / round=2 判別: review-notes.md 内 `<!-- idd-claude:review round=N -->`
# を grep。いずれも見つからなければ INCONSISTENT として Stage A から再実行する
# （safe fallback）。
#
# 入力: 環境変数 NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG
# 副作用:
#   - グローバル変数 START_STAGE に "A" / "B" / "C" / "TERMINAL_OK" / "TERMINAL_FAILED" を代入
#   - $LOG / stdout に 1 ブロックの判定根拠ログを sc_log で出力（NFR 2.1, NFR 2.2）
# 戻り値:
#   0 = 判定成功（START_STAGE 設定済）
#   1 = 内部エラー（START_STAGE="A" にフォールバック、Req 5.4）
stage_checkpoint_resolve_resume_point() {
  # 内部エラーの安全側フォールバックのため、エラーを補足できるよう || true で個別ガード。
  # START_STAGE は呼び出し元 run_impl_pipeline（task 4）が読み取る共有変数。
  # task 3 単独では read 側が無いため SC2034 を一括抑制（task 4 で消える）。
  # shellcheck disable=SC2034
  START_STAGE="A"

  sc_log "--- begin resolve (issue=#$NUMBER branch=$BRANCH) ---" >> "$LOG"
  sc_log "input: spec_dir=$SPEC_DIR_REL" >> "$LOG"

  # 1) 既存 impl PR を最優先で検出（Req 2.6: TERMINAL_OK）。
  local pr_info pr_rc
  pr_info=$(stage_checkpoint_find_impl_pr 2>/dev/null) && pr_rc=0 || pr_rc=$?
  case "$pr_rc" in
    0)
      sc_log "input: existing-impl-pr=$pr_info" >> "$LOG"
      START_STAGE="TERMINAL_OK"
      sc_log "decision: START_STAGE=TERMINAL_OK reason=existing-impl-pr" >> "$LOG"
      sc_log "--- end resolve ---" >> "$LOG"
      return 0
      ;;
    1)
      sc_log "input: existing-impl-pr=none" >> "$LOG"
      ;;
    *)
      sc_warn "gh pr list failed (rc=$pr_rc) → safe fallback: existing-impl-pr=unknown" >> "$LOG"
      sc_log "input: existing-impl-pr=unknown" >> "$LOG"
      # gh API エラーは判定継続（fallback="A"）。Stage A 再実行は安全（Req 5.4）
      ;;
  esac

  # 2) impl-notes.md tracked 判定（Stage A 完了 checkpoint）。
  local has_impl="no"
  if stage_checkpoint_has_impl_notes; then
    has_impl="yes"
  fi
  sc_log "input: impl-notes.md tracked=$has_impl" >> "$LOG"

  # 3) review-notes.md tracked + RESULT 行 parse（Stage B 完了 checkpoint）。
  # stdout 側の TSV は本箇所では未使用（result/round は別途 grep で取得）。
  local rev_rc=0
  stage_checkpoint_read_review_result >/dev/null 2>&1 || rev_rc=$?
  local rev_result="(none)"
  case "$rev_rc" in
    0) rev_result="approve" ;;
    1) rev_result="reject" ;;
    *) rev_result="(missing-or-unparsed)" ;;
  esac
  # tracked 判定（rev_rc から逆算するのではなく、ls-tree で実態を直接観測する）。
  local rev_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  local rev_tracked="no"
  if [ -f "$rev_path" ]; then
    local rev_ls_out
    rev_ls_out=$(git -C "$REPO_DIR" ls-tree --name-only HEAD -- "$SPEC_DIR_REL/review-notes.md" 2>/dev/null || true)
    [ -n "$rev_ls_out" ] && rev_tracked="yes"
  fi
  # round 判定: review-notes.md 内に round=N が無ければ "unknown"（INCONSISTENT 扱い）
  local rev_round="unknown"
  if [ "$has_impl" = "yes" ] && [ -f "$rev_path" ]; then
    if grep -q '^<!-- idd-claude:review round=2' "$rev_path" 2>/dev/null \
       || grep -q '^round=2$' "$rev_path" 2>/dev/null; then
      rev_round="2"
    elif grep -q '^<!-- idd-claude:review round=1' "$rev_path" 2>/dev/null \
       || grep -q '^round=1$' "$rev_path" 2>/dev/null; then
      rev_round="1"
    fi
  fi
  sc_log "input: review-notes.md tracked=$rev_tracked result=$rev_result round=$rev_round" >> "$LOG"

  # 4) Decision Table（評価順序: 矛盾検出 → 通常分岐）。
  if [ "$has_impl" = "no" ]; then
    if [ "$rev_rc" -eq 2 ]; then
      # impl-notes 無 / review-notes 無 → 通常の Stage A (Req 2.2)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=no-checkpoint" >> "$LOG"
    else
      # impl-notes 無 / review-notes 有 → INCONSISTENT (Req 5.1)
      START_STAGE="A"
      sc_log "decision: START_STAGE=A reason=inconsistent-review-notes-without-impl-notes" >> "$LOG"
    fi
    sc_log "--- end resolve ---" >> "$LOG"
    return 0
  fi

  # ここから has_impl=yes 系
  case "$rev_rc" in
    2)
      # review-notes 不在 or 解釈不能 → Stage B から再実行 (Req 2.3, 4.3)
      START_STAGE="B"
      sc_log "decision: START_STAGE=B reason=impl-notes-only-or-review-unparsed" >> "$LOG"
      ;;
    0)
      # approve → Stage C (Req 2.4)
      START_STAGE="C"
      sc_log "decision: START_STAGE=C reason=approve+no-pr" >> "$LOG"
      ;;
    1)
      # reject → round で分岐 (D-3, Req 2.5)
      case "$rev_round" in
        2)
          START_STAGE="TERMINAL_FAILED"
          sc_log "decision: START_STAGE=TERMINAL_FAILED reason=round2-reject-residual" >> "$LOG"
          ;;
        1)
          # round=1 reject の中断状態は同 tick 完結前提が破れた状況 → Stage A 再実行 (D-3)
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=round1-reject-mid-tick-fallback" >> "$LOG"
          ;;
        *)
          # round=N が読み取れない（手動編集 / 旧フォーマット）→ INCONSISTENT 扱い
          # shellcheck disable=SC2034
          START_STAGE="A"
          sc_log "decision: START_STAGE=A reason=reject-with-unknown-round" >> "$LOG"
          ;;
      esac
      ;;
  esac

  sc_log "--- end resolve ---" >> "$LOG"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tasks Count Gate Module (#147) — Architect 完了直後の tasks.md 件数ガード
#
# Architect が `tasks.md` を確定した直後（design モードの Claude 実行 rc=0 直後）に
# watcher 側で task 件数を機械的に再カウントし、件数レンジに応じて 3 段階の運用判定
# （通常 / 警告 / Developer 抑止）を適用する harness ガード（Req 1, 2 / Issue #147）。
#
# 関数群:
#   - tc_log / tc_warn / tc_error                  : `tasks-count:` prefix logger
#   - tc_count_tasks                               : tasks.md からタスク行件数を抽出
#   - tc_classify                                  : 件数を normal/warn/escalate に分類
#   - tc_should_run                                : gate（opt-out / 不在 / 重複検知）
#   - tc_already_posted_marker_present             : 冪等マーカー検知
#   - tc_post_warning_comment                      : 8〜10 件レンジの警告コメント投稿
#   - tc_post_escalation_comment                   : 11 件以上のエスカレーションコメント
#   - tc_add_needs_decisions_label                 : `needs-decisions` ラベル付与
#   - tc_run_post_architect_check                  : design rc=0 hook の orchestrator
#
# 設計参照: docs/specs/147-feat-harness-tasks-md-task-auto-dev-issu/design.md
# 関連    : Issue #131（Architect 側 budget overflow 検知）と独立かつ重畳に作用する
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# tasks-count 専用ロガー（既存 sav_log / sc_log と同形式）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] tasks-count:` の 3 段 prefix を維持し、
# `grep '\[.*\] tasks-count:'` で全件抽出可能（NFR 1.1）。
tc_log() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: $*"
}
tc_warn() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: WARN: $*" >&2
}
tc_error() {
  echo "[$(date '+%F %T')] [$REPO] tasks-count: ERROR: $*" >&2
}

# ─── tc_count_tasks ───
#
# `tasks.md` 1 ファイルからタスク行件数を整数で返す純粋関数（Req 1.1〜1.4 / NFR 3.1）。
#
# count 抽出 regex (POSIX 互換 ERE): `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? `
#   - 4 種 checkbox（未完了 `- [ ]` / 完了 `- [x]` / deferrable `- [ ]*` /
#     完了 deferrable `- [x]*`）を許容（Req 1.2）
#   - numeric 階層 ID（`1` / `1.1` / `2.1.3` 等）+ 半角スペースを必須
#   - 親タスク末尾 `.` を `\.?` でオプショナル化（`- [ ] 1. <名前>` /
#     `- [ ] 1.1 <名前>` 両対応）
#   - 既存 `design-review-gate.md` の checkbox enforcement 判定パターンと同一規約
#   - 子タスク（小数階層 ID）・`(P)` マーカーは regex から見て区別されないため、
#     それぞれ 1 件として数える（Req 1.3 / 1.4 を構造的に保証）
#
# 入力: 第 1 引数 = tasks.md の絶対パス
# 戻り値: 0 = 抽出成功（stdout に件数 0 以上の整数 1 行）/ 1 = ファイル不在
# 副作用: なし（pure read）
tc_count_tasks() {
  local tasks_path="$1"
  [ -f "$tasks_path" ] || return 1
  # grep -cE: マッチ行数（件数）を 1 行で stdout に書き出す。マッチ 0 件でも
  # `--count` モードは 0 を返して exit 1 になるため、`|| true` で吸収する。
  local count
  count=$(grep -cE '^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ' "$tasks_path" 2>/dev/null || true)
  # 空文字（読み取り失敗）の場合は安全側に 0 を返す
  echo "${count:-0}"
}

# ─── tc_classify ───
#
# 件数を 3 値レンジ（`normal` / `warn` / `escalate`）に分類して stdout に出力する
# 純粋関数（Req 2.1, 2.2, 2.3）。
#
#   - count < TC_WARN_LOWER         → normal    （既定で count ≤ 7）
#   - TC_WARN_LOWER ≤ count ≤ UPPER → warn      （既定で 8 ≤ count ≤ 10）
#   - count ≥ TC_ESCALATE_LOWER     → escalate  （既定で count ≥ 11）
#
# 閾値 env var が非整数の場合、tc_warn で警告ログを出したうえで既定値（8 / 10 / 11）に
# フォールバック（fail-safe / Req 4.2 系の安全側挙動）。
#
# 入力: 第 1 引数 = 件数（0 以上の整数）
# 戻り値: 常に 0（純粋関数、副作用は警告ログのみ）
# stdout: `normal` / `warn` / `escalate` のいずれか 1 つ
tc_classify() {
  local count="$1"
  # 閾値 env var の整数検証（非整数なら既定値にフォールバック）
  local lower="$TC_WARN_LOWER"
  local upper="$TC_WARN_UPPER"
  local escalate="$TC_ESCALATE_LOWER"
  if ! [[ "$lower" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_WARN_LOWER='$lower' は整数でないため既定値 8 にフォールバック"
    lower=8
  fi
  if ! [[ "$upper" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_WARN_UPPER='$upper' は整数でないため既定値 10 にフォールバック"
    upper=10
  fi
  if ! [[ "$escalate" =~ ^[0-9]+$ ]]; then
    tc_warn "TC_ESCALATE_LOWER='$escalate' は整数でないため既定値 11 にフォールバック"
    escalate=11
  fi
  # count 自体が整数でない場合は normal にフォールバック（fail-safe）
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    tc_warn "count='$count' は整数でないため normal にフォールバック"
    echo "normal"
    return 0
  fi
  if [ "$count" -ge "$escalate" ]; then
    echo "escalate"
  elif [ "$count" -ge "$lower" ] && [ "$count" -le "$upper" ]; then
    echo "warn"
  else
    echo "normal"
  fi
}

# ─── tc_should_run ───
#
# 本機能を実行すべきか判定する gate（Req 1.5, 2.6, 3.3, 4.2, 4.4）。
#
# 以下のいずれかが真の場合 return 1（skip）、いずれも偽なら return 0:
#   - TC_ENABLED != "true"                              → reason=opt-out（Req 4.2）
#   - tasks.md が存在しない / 読み取れない              → reason=tasks-md-missing（Req 1.5）
#   - Issue に既に `needs-decisions` ラベルが付与済み   → reason=already-needs-decisions
#                                                          （Req 2.6 / 4.4。#131 由来でも
#                                                          本機能由来でも区別せず skip）
#
# resume 経路（impl-resume / Stage Checkpoint Resume）の skip は、本機能の hook が
# **design 分岐内側にのみ配置される**ことで構造的に保証される（Req 3.1 / 3.2）。
# impl-resume / Stage Checkpoint Resume はそれぞれ MODE=impl-resume または
# START_STAGE=B|C で動き、design 分岐に到達しないため、本関数の判定対象にならない。
#
# 入力: 環境変数 NUMBER / REPO / REPO_DIR / SPEC_DIR_REL / TC_ENABLED /
#       LABEL_NEEDS_DECISIONS
# 戻り値: 0 = run / 1 = skip
# 副作用: skip 時に tc_log で reason を記録（NFR 1.1）
tc_should_run() {
  # 1. opt-out 判定（TC_ENABLED != "true"）
  if [ "${TC_ENABLED:-true}" != "true" ]; then
    tc_log "issue=#${NUMBER:-?} skip reason=opt-out TC_ENABLED=${TC_ENABLED:-(unset)}"
    return 1
  fi
  # 2. tasks.md 不在 / 読み取り不可
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  if [ ! -f "$tasks_path" ] || [ ! -r "$tasks_path" ]; then
    tc_log "issue=#${NUMBER:-?} skip reason=tasks-md-missing path=$tasks_path"
    return 1
  fi
  # 3. 既に needs-decisions ラベル付与済み（#131 由来でも本機能由来でも区別せず skip）
  #    gh issue view が失敗しても skip 判定は false-negative 側に倒す（最悪重複適用のみ）
  local label_json existing_label_match
  if label_json=$(gh issue view "$NUMBER" --repo "$REPO" --json labels 2>/dev/null); then
    existing_label_match=$(echo "$label_json" \
      | jq -r --arg L "$LABEL_NEEDS_DECISIONS" '.labels[]? | select(.name == $L) | .name' 2>/dev/null \
      || true)
    if [ -n "$existing_label_match" ]; then
      tc_log "issue=#${NUMBER:-?} skip reason=already-needs-decisions"
      return 1
    fi
  else
    tc_warn "issue=#${NUMBER:-?} gh issue view 失敗（label 確認 skip、本機能は続行）"
  fi
  return 0
}

# ─── tc_already_posted_marker_present ───
#
# Issue コメント履歴に本機能由来の冪等マーカーが既に存在するか検知する（Req 2.6）。
#
# 固定識別子: `<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> issue=<N> ... -->`
# （NFR 1.2 の本機能由来判別文字列を兼ねる）
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = kind（warning | escalation）
# 戻り値: 0 = marker 検出済み（skip 推奨）/ 1 = 未検出（投稿可）
# 副作用: なし
#
# gh API 失敗時は marker absent (return 1) として扱う（最悪重複コメント投稿のみ）。
tc_already_posted_marker_present() {
  local issue_number="$1"
  local kind="$2"
  local bodies
  if ! bodies=$(gh issue view "$issue_number" --repo "$REPO" \
      --json comments --jq '.comments[].body' 2>/dev/null); then
    return 1
  fi
  # 固定マーカー prefix で grep（issue=<N> 部分も付き合わせて誤検出を抑える）
  local marker_prefix="<!-- idd-claude:tasks-count-overflow kind=$kind issue=$issue_number"
  if echo "$bodies" | grep -qF "$marker_prefix"; then
    return 0
  fi
  return 1
}

# ─── tc_post_warning_comment ───
#
# 8〜10 件レンジの警告コメントを冪等に投稿する（Req 2.2 / 2.6 / NFR 1.2）。
#
# 本文には以下を含める:
#   - 検知件数と適用閾値（TC_WARN_LOWER〜TC_WARN_UPPER）
#   - 後続フェーズは抑止されず通常進行する旨
#   - 末尾に固定識別マーカー
#     `<!-- idd-claude:tasks-count-overflow kind=warning issue=<N> count=<C> -->`
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 件数
# 戻り値: 常に 0（fail-open。投稿失敗は tc_warn でログのみ、watcher 全体は止めない）
tc_post_warning_comment() {
  local issue_number="$1"
  local count="$2"
  if tc_already_posted_marker_present "$issue_number" "warning"; then
    tc_log "issue=#${issue_number} already-warned skip duplicate comment"
    return 0
  fi
  local body
  body=$(cat <<EOF
⚠️ **Tasks Count Gate (harness, #147)**: tasks.md のタスク件数が警告レンジに該当しています

- 検知件数: **${count} 件**
- 適用閾値: ${TC_WARN_LOWER} 件以上 ${TC_WARN_UPPER} 件以下で警告（参考: ≥ ${TC_ESCALATE_LOWER} 件で Developer 自動起動抑止）
- 本コメントは通知のみで、**後続フェーズ（Developer 自動起動）は通常通り進行します**

タスク件数が turn budget を圧迫する境界域です。Developer Round 1 で PR 作成まで完走しない可能性が高まるため、Issue 分割を検討してください（Issue #131 で Architect 側にも同種の自己レビュー gate が動いています）。

<!-- idd-claude:tasks-count-overflow kind=warning issue=${issue_number} count=${count} -->
EOF
)
  if gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} posted warning-comment count=${count}"
  else
    tc_warn "issue=#${issue_number} gh issue comment 失敗（warning 投稿、fail-open で続行）"
  fi
  return 0
}

# ─── tc_post_escalation_comment ───
#
# 11 件以上のエスカレーションコメントを冪等に投稿する
# （Req 2.3 / 2.5 / 2.6 / NFR 1.2）。
#
# 本文には以下を必ず含める:
#   - 検知件数と適用閾値（TC_ESCALATE_LOWER）
#   - 抑止された後続フェーズ名（Developer 自動起動 / impl-resume）
#   - 人間が取りうる回復手順:
#     - 推奨: Issue 分割の検討（PM / Architect に差し戻し）
#     - バイパス: `needs-decisions` ラベルを人間が外す（次サイクルで再評価。件数が
#       変わらなければ再付与される旨も注記）
#     - 完全 opt-out: `TC_ENABLED=false` で watcher を再起動
#   - 末尾に固定識別マーカー
#     `<!-- idd-claude:tasks-count-overflow kind=escalation issue=<N> count=<C> -->`
#     （NFR 1.2 の本機能由来判別文字列を兼ねる）
#
# 入力: 第 1 引数 = Issue 番号 / 第 2 引数 = 件数
# 戻り値: 常に 0（fail-open）
tc_post_escalation_comment() {
  local issue_number="$1"
  local count="$2"
  if tc_already_posted_marker_present "$issue_number" "escalation"; then
    tc_log "issue=#${issue_number} already-escalated skip duplicate comment"
    return 0
  fi
  local body
  body=$(cat <<EOF
🚫 **Tasks Count Gate (harness, #147)**: tasks.md のタスク件数が **エスカレーション閾値**を超えています

- 検知件数: **${count} 件**
- 適用閾値: ${TC_ESCALATE_LOWER} 件以上でエスカレーション（参考: ${TC_WARN_LOWER}〜${TC_WARN_UPPER} 件は警告のみ）
- **抑止された後続フェーズ**: Developer 自動起動 / impl-resume（\`needs-decisions\` ラベルにより watcher Issue 候補抽出から除外されます）
- 根拠: KeyNest 3 事例で 10 件超の tasks.md は Developer Round 1 で PR 作成まで完走しない確率が高く、turn budget 超過によるキャッシュトークン浪費が観測されています

### 人間が取りうる回復手順

1. **推奨: Issue 分割の検討** — PM / Architect に差し戻し、要件・設計を複数 Issue に分割してください
2. **バイパス: \`needs-decisions\` ラベルを人間が外す** — 次サイクルで watcher は再 pickup を試行しますが、件数が変わらなければ本機能が再付与します（恒久バイパスにはなりません）
3. **完全 opt-out: \`TC_ENABLED=false\`** — cron / launchd の env var に追加して watcher を再起動すると、本機能による全 Issue への評価が無効化されます

<!-- idd-claude:tasks-count-overflow kind=escalation issue=${issue_number} count=${count} -->
EOF
)
  if gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} posted escalation-comment count=${count}"
  else
    tc_warn "issue=#${issue_number} gh issue comment 失敗（escalation 投稿、fail-open で続行）"
  fi
  return 0
}

# ─── tc_add_needs_decisions_label ───
#
# `needs-decisions` ラベルを冪等に付与する（Req 2.3 / 2.4 / 4.4 / NFR 2.2）。
#
# `gh issue edit --add-label` は同名ラベルを多重付与しない仕様のため、構造的に冪等。
# 既存 `LABEL_NEEDS_DECISIONS` env var 値（既定 `needs-decisions`）を参照し、
# 新ラベル名は導入しない（NFR 2.2 既存ラベル名互換）。
#
# 入力: 第 1 引数 = Issue 番号
# 戻り値: 常に 0（fail-open。付与失敗は次サイクルで再判定して再付与トライ可能）
tc_add_needs_decisions_label() {
  local issue_number="$1"
  if gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    tc_log "issue=#${issue_number} added label=${LABEL_NEEDS_DECISIONS}"
  else
    tc_warn "issue=#${issue_number} gh issue edit --add-label 失敗（fail-open で続行）"
  fi
  return 0
}

# ─── tc_run_post_architect_check ───
#
# design 分岐 rc=0 直後に呼ばれる orchestrator。本機能の単一エントリポイント
# （Req 1.1, 1.6, 2.1, 2.2, 2.3, 3.3, 4.1）。
#
# 順序:
#   1. tc_should_run を呼び、skip 判定なら return 0（design 分岐の挙動を維持）
#   2. tc_count_tasks で件数取得
#   3. tc_classify でレンジを取得
#   4. レンジに応じて分岐:
#      - normal   → ログのみ
#      - warn     → tc_post_warning_comment
#      - escalate → tc_post_escalation_comment + tc_add_needs_decisions_label
#
# 戻り値: 常に 0（呼び出し元 design 分岐 rc=0 の挙動を変えない / fail-open）
# 副作用: ログ書き込み、gh issue edit/comment
tc_run_post_architect_check() {
  if ! tc_should_run; then
    return 0
  fi
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  local count
  count=$(tc_count_tasks "$tasks_path")
  # tc_count_tasks は空文字を返さないが、defensive に整数フォールバックを入れる
  if ! [[ "$count" =~ ^[0-9]+$ ]]; then
    tc_warn "issue=#${NUMBER:-?} count='$count' が整数でないため 0 にフォールバック"
    count=0
  fi
  local range
  range=$(tc_classify "$count")
  case "$range" in
    normal)
      tc_log "issue=#${NUMBER:-?} count=${count} range=normal action=none"
      ;;
    warn)
      tc_log "issue=#${NUMBER:-?} count=${count} range=warn action=warning-comment"
      tc_post_warning_comment "$NUMBER" "$count" || true
      ;;
    escalate)
      tc_log "issue=#${NUMBER:-?} count=${count} range=escalate action=needs-decisions+escalation-comment"
      tc_post_escalation_comment "$NUMBER" "$count" || true
      tc_add_needs_decisions_label "$NUMBER" || true
      ;;
    *)
      tc_warn "issue=#${NUMBER:-?} unknown classification='$range' count=${count} (fail-open)"
      ;;
  esac
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) — impl 系モード stage 分割パイプライン
#
# 既存の impl / impl-resume モードは DEV_PROMPT 1 回で PM + Developer + PjM を
# 直列起動していたが、Reviewer サブエージェントを独立 context で挟むため、以下の
# stage に分割する:
#
#   Stage A  : PM + Developer（ただし impl-resume では PM をスキップ）
#   Stage B  : Reviewer (round=1)
#   Stage A' : Developer 再実行（reject 時のみ、最大 1 回）
#   Stage B' : Reviewer (round=2、reject 時のみ)
#   Stage C  : PjM（PR 作成）
#
# 各 stage は `claude --print` の独立プロセスで起動。stage 間の context 共有は
# しない（要件 2.2「独立 Claude セッション」）。Reviewer 判定は
# `docs/specs/<N>-<slug>/review-notes.md` の最終 RESULT 行で受け渡す。
#
# 設計参照: docs/specs/20-phase-1-reviewer-subagent-gate/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Reviewer / Pipeline 専用ロガー（既存 mq_log / pi_log と同形式）
rv_log() {
  echo "[$(date '+%F %T')] reviewer: $*"
}
rv_dev_log() {
  echo "[$(date '+%F %T')] developer: $*"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase 2: Per-task TDD Implementation Loop (#21) — ヘルパー関数群
#
# `PER_TASK_LOOP_ENABLED=true` のときに `run_impl_pipeline` の Stage A 内で起動される
# per-task loop の補助関数を、既存 Reviewer Gate セクションの直前に独立セクションとして
# 配置する。`PER_TASK_LOOP_ENABLED` が未指定 / `=true` 以外の場合、これらの関数は
# どこからも呼ばれないため、本機能導入前と外形挙動は完全一致する（NFR 1.1 / Req 1.1）。
#
# 関数一覧:
#   - pt_log:                    per-task ロガー (rv_log と同形式 / NFR 2.1, 2.2)
#   - pt_extract_pending_tasks:  tasks.md から未完了 `- [ ]` を numeric ID 昇順抽出
#   - pt_extract_learnings:      impl-notes.md の `## Implementation Notes` 抽出
#   - pt_resolve_diff_range:     task 単位 diff range の開始/終了 SHA 解決
#   - build_per_task_implementer_prompt: per-task Implementer prompt 組み立て
#   - build_per_task_reviewer_prompt:    per-task Reviewer prompt 組み立て
#   - run_per_task_implementer:  fresh Claude session で Implementer 起動
#   - run_per_task_reviewer:     fresh Claude session で Reviewer 起動 + RESULT 抽出
#   - run_per_task_loop:         dispatcher (pending タスクをループ消化)
#
# 詳細: docs/specs/21-phase-2-per-task-tdd-implementation-loop/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── pt_log ───
# per-task ロガー。`[YYYY-MM-DD HH:MM:SS] per-task: <msg>` 形式で stdout に出力。
# 呼び出し側で `>> "$LOG"` する規約（既存 rv_log / sc_log と同じ）。
# NFR 2.1, NFR 2.2 を満たす。
pt_log() {
  echo "[$(date '+%F %T')] per-task: $*"
}
pt_warn() {
  echo "[$(date '+%F %T')] per-task: WARN: $*" >&2
}

# ─── pt_extract_pending_tasks <tasks_md_path> ───
#
# tasks.md から未完了 task の numeric 階層 ID を numeric 階層昇順で抽出して stdout に出力。
#
# - 抽出対象: 行頭が `- [ ] <numeric_id>(\.)? ` で始まる行（deferrable `- [ ]*` は除外）
#   - 親タスク慣習: `- [ ] 1. <title>`（ID の後ろに `.` + 空白）
#   - 子タスク慣習: `- [ ] 1.1 <title>`（ID の後ろに空白のみ、末尾 `.` なし）
#   - tasks-generation.md の規約と既存 tasks.md の実例（本リポジトリ含む）の双方を満たす
# - 抽出した ID は親タスク末尾の `.` を除去した numeric 階層 ID（例: `1`, `1.1`, `1.10`）
# - 出力順序は `sort -V`（version sort）で numeric 階層昇順を保証（`1.2` < `1.10`）
# - tasks.md 不在時は return 1
#
# Requirements: 2.1, 2.3, 5.1
pt_extract_pending_tasks() {
  local tasks_md="$1"
  if [ ! -f "$tasks_md" ]; then
    return 1
  fi
  # `- [ ] N. <title>` (親タスク) または `- [ ] N.M(.K...) <title>` (子タスク) を抽出。
  # `- [ ]*` (deferrable) は除外（`\[ \]` の直後に空白を要求するため自然に除外される）。
  # 親タスクの末尾 `.` は sed の置換で剥がして numeric 階層 ID のみ取り出す。
  grep -E '^- \[ \] [0-9]+(\.[0-9]+)*\.? ' "$tasks_md" \
    | sed -E 's/^- \[ \] ([0-9]+(\.[0-9]+)*)\.? .*/\1/' \
    | sort -V
  return 0
}

# ─── pt_extract_learnings <impl_notes_path> ───
#
# impl-notes.md の `## Implementation Notes` 見出しから「次の `## ` 見出しが現れる直前まで」
# を stdout に出力。learnings を後続 task の Implementer prompt に inline 注入するために
# 使用する。
#
# - セクション不在 / impl-notes.md 自体が無い場合は空文字を返し常に return 0
#   （Req 4.5: 単一 task の Issue で learnings 空を許容、を構造的に保証）
# - 出力には見出し `## Implementation Notes` 自体も含む（Implementer が prompt から
#   そのままセクションを参照できるようにするため）
# - `## Implementation Notes` 以外のセクションには触れない（Req 4.4）
#
# Requirements: 4.3, 4.4, 4.5, 5.4
pt_extract_learnings() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 0
  fi
  # awk で `## Implementation Notes` セクションを抽出。
  # - `## Implementation Notes` 行を見つけたら print 開始
  # - print 開始後に別の `## ` 見出しが来たら print 停止
  # - 末尾まで他の `## ` が来なければファイル末尾まで print
  awk '
    /^## Implementation Notes[[:space:]]*$/ { in_section = 1; print; next }
    in_section && /^## / { exit }
    in_section { print }
  ' "$impl_notes"
  return 0
}

# ─── pt_resolve_diff_range <task_id> ───
#
# per-task Reviewer に渡す diff range の開始 SHA / 終了 SHA を解決して
# `<range_start_sha>\t<range_end_sha>` を stdout に出力。
#
# アルゴリズム（design.md「diff range 解決アルゴリズム」節 + Issue #164 拡張）:
#   1. `$BASE_BRANCH..HEAD` 範囲の `docs(tasks): mark ... as done` commit を SHA+subject の
#      タブ区切り pair で時系列昇順に全列挙
#   2. 当該 task_id の marker commit を以下の優先順で特定（range_end）:
#      a. 単記 marker（subject が `docs(tasks): mark <task_id> as done` に完全一致）
#         複数マッチ時は最後（最新）のマッチを採用（既存挙動を維持 / Req 3.1）
#      b. 単記 marker が無ければ連記 marker（subject が `docs(tasks): mark <ids> as done` で
#         <ids> を `/` / `,` / 空白で token 化したときに task_id と完全一致する token を含む）
#         複数マッチ時は最後のマッチを採用（NFR 2.1: 連記経由解決時は stdout ログに
#         `via=multi-id-marker` を残す）
#   3. 全 mark commit 列の中で range_end の直前要素を range_start とする
#   4. 直前要素が存在しない（初回 task）場合は range_start = `$BASE_BRANCH` の SHA
#   5. 当該 task の marker commit が単記でも連記でも見つからない場合は return 1
#
# 後方互換性（Req 3.1 / NFR 1.1）:
#   - 単記 marker のみで構成されるリポジトリ履歴では、単記 marker が常に優先採用されるため
#     本変更前と完全に同一の SHA pair を返す
#   - 連記 marker は単記 marker が無い場合の fallback として動作するため、既存ログ列の
#     観測可能な副作用は発生しない
#
# False positive 防止（Req 2.5）:
#   - <ids> 部を `/` / `,` / 空白で正規化した後 word 単位で完全一致照合するため、task_id `1`
#     が `1.1` や `11` に誤マッチしない
#
# Requirements: 3.2, 4.5, 5.4, Issue #164 Req 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, NFR 2.1
pt_resolve_diff_range() {
  local task_id="$1"
  local base="${BASE_BRANCH:-main}"

  # 全 mark commit pair (SHA<TAB>subject) を時系列昇順で取得（--reverse で oldest 先頭）
  local all_pairs
  all_pairs=$(git log --grep="^docs(tasks): mark " --format='%H%x09%s' --reverse "${base}..HEAD" 2>/dev/null || true)
  if [ -z "$all_pairs" ]; then
    return 1
  fi

  # ─── (a) 単記 marker を優先検索（subject 完全一致 / Req 3.1 後方互換） ───
  local current_mark="" via="" sha subject id_list tok found
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$subject" = "docs(tasks): mark ${task_id} as done" ]; then
      current_mark="$sha"
      via="single-id-marker"
    fi
  done <<<"$all_pairs"

  # ─── (b) 単記 marker が無ければ連記 marker を fallback 検索（Req 2.2 / 2.5） ───
  if [ -z "$current_mark" ]; then
    while IFS=$'\t' read -r sha subject; do
      [ -n "$sha" ] || continue
      # subject から <ids> 部を抽出（`docs(tasks): mark <ids> as done`）。
      # 末尾アンカで「as done」以降にコメント等が付いた変則 subject は対象外とする。
      id_list=$(printf '%s' "$subject" | sed -nE 's/^docs\(tasks\): mark (.+) as done$/\1/p')
      [ -n "$id_list" ] || continue
      # `/` / `,` を空白に正規化し、word 単位で task_id と完全一致する token を探す。
      # word splitting は IFS のデフォルト（空白）で行われ、任意連続空白に対応する。
      found=false
      for tok in $(printf '%s' "$id_list" | tr '/,' '  '); do
        if [ "$tok" = "$task_id" ]; then
          found=true
          break
        fi
      done
      if [ "$found" = "true" ]; then
        current_mark="$sha"
        via="multi-id-marker"
      fi
    done <<<"$all_pairs"
  fi

  if [ -z "$current_mark" ]; then
    return 1
  fi

  # all_pairs 順序を再度走査して current_mark の直前要素を探す（既存挙動を踏襲）
  local prev_mark=""
  while IFS=$'\t' read -r sha subject; do
    [ -n "$sha" ] || continue
    if [ "$sha" = "$current_mark" ]; then
      break
    fi
    prev_mark="$sha"
  done <<<"$all_pairs"

  local range_start
  if [ -n "$prev_mark" ]; then
    range_start="$prev_mark"
  else
    # 初回 task: $BASE_BRANCH の SHA を使う
    range_start=$(git rev-parse "$base" 2>/dev/null || true)
    if [ -z "$range_start" ]; then
      return 1
    fi
  fi

  # NFR 2.1: 連記経由で解決した場合は stdout ログに識別可能な印を残す（運用者が
  # `grep via=multi-id-marker` で件数把握できる）。単記経由は出力しない（既存ログ量を
  # 増やさない後方互換）。stdout に出すことで呼び出し側 `pt_log` 経由のログ書式と
  # 揃える代わりに、関数の主出力（SHA pair）と区別するため独立行 + tag prefix で出す。
  if [ "$via" = "multi-id-marker" ]; then
    echo "[$(date '+%F %T')] per-task: diff-range resolved via=multi-id-marker task_id=${task_id} sha=${current_mark}" >&2
  fi

  printf '%s\t%s\n' "$range_start" "$current_mark"
  return 0
}

# ─── build_per_task_implementer_prompt <task_id> ───
#
# per-task Implementer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_dev_prompt_a` の形式を踏襲しつつ、以下を明示する:
#
#   - 本起動で実装する task は <task_id> 1 件のみ（他の未完了 task に着手しない / Req 2.2）
#   - `tasks.md` の進捗マーカー更新 `- [ ]` → `- [x]` と `docs(tasks): mark <id> as done`
#     commit 規約（既存 #67 / #112 規約を流用 / Req 2.4, 2.5）
#   - `impl-notes.md` の `## Implementation Notes` 配下に `### Task <id>` を追記し、
#     先行 task の learnings は **改変・削除・並び替え禁止**（Req 4.1, 4.2, 4.4）
#   - 既存 learnings の inline 埋め込み（Req 4.3）
#   - PR 作成禁止 / spec 書き換え禁止（既存 Stage A 制約と同等）
#
# Requirements: 2.2, 2.3, 2.4, 2.5, 4.1, 4.2, 4.3, 4.4
build_per_task_implementer_prompt() {
  local task_id="$1"
  local learnings
  learnings=$(pt_extract_learnings "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md")
  local learnings_block
  if [ -n "$learnings" ]; then
    learnings_block=$(cat <<EOF
## これまで完了した task の learnings（impl-notes.md より）

以下は先行 task の Implementer が記録した learning（採用方針 / 重要な判断 / 残存課題）です。
**本 task の実装で、命名規約・採用ライブラリ・運用判断との一貫性を維持するために必ず参照**
してください。各 \`### Task <id>\` セクションの本文を **改変・削除・並び替えしないこと**。

\`\`\`markdown
${learnings}
\`\`\`
EOF
)
  else
    learnings_block=$(cat <<'EOF'
## これまで完了した task の learnings（impl-notes.md より）

（先行 task の learnings はまだ存在しません。本 task が最初の per-task 実装です）
EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、\`tasks.md\` の
**1 件の task のみ** を fresh context で実装するために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 本起動で実装する task

- **対象 task ID**: \`${task_id}\`
- 本起動では \`tasks.md\` の **${task_id} 1 件のみ** を実装します。他の未完了 task には
  一切着手しないこと（次 task は別の fresh Implementer 起動で消化されます）

## 進め方

1. developer サブエージェントを起動し、対象 task \`${task_id}\` を実装＋テスト＋commit する
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は人間レビュー済みで **書き換え禁止**（矛盾は impl-notes.md の
     「確認事項」に記載するに留める）
   - tasks.md の対象 task の \`_Requirements:_\` / \`_Boundary:_\` に従う
   - 規約は CLAUDE.md に従う

2. **進捗マーカー更新**（既存 #67 / #112 規約 + Issue #164「1 commit = 1 task ID」厳格化）:
   - 対象 task の \`- [ ] ${task_id}\` 行を \`- [x] ${task_id}\` に書き換える
   - 子タスク（例: ${task_id}.1）を完了した場合、親 task（${task_id} の親、例: ${task_id%.*}）
     配下の全子タスクが \`- [x]\` になったタイミングで親も \`- [x]\` に昇格する
   - 進捗マーカー更新は **専用 commit**: \`docs(tasks): mark <id> as done\`
     - 当該 commit には \`tasks.md\` 以外のファイルを含めない
   - **【重要 / Issue #164】1 つの marker commit には 1 つの task ID のみを含めること**:
     - 1 つの \`docs(tasks): mark <id> as done\` commit には **必ず 1 つの task ID のみ**
       を含めること（per-task Reviewer の diff range 解決が task ID 単位で行われるため）
     - **親 task の完了昇格も別 commit に分割**する。例: 子 \`1.1\` 完了で親 \`1\` も
       全完了になる場合、まず \`docs(tasks): mark 1.1 as done\` を 1 commit で作成し、
       続けて \`docs(tasks): mark 1 as done\` を **別 commit** として続けて作成する
     - **連記禁止例（NG）**: \`docs(tasks): mark 1 / 1.1 as done\` /
       \`docs(tasks): mark 1, 1.1 as done\` のように複数 ID を 1 commit にまとめる
       subject 表記は禁止
     - 連記 marker commit を作成すると、per-task Reviewer の diff range 解決が単記 ID で
       一致しなくなり \`diff-range-resolve-failed\` を起こす可能性がある（watcher 側で
       fallback 解決は試行するが、canonical は単記分割のみ）
   - 書き換え禁止領域: タスク本文 / \`_Requirements:_\` / \`_Boundary:_\` / \`_Depends:_\` /
     タスク順序 / 親タスクのインデント / deferrable 印 \`- [ ]*\`

3. **learning 追記**（per-task ループの中核 / Req 4.1, 4.2, 4.4）:
   - \`${SPEC_DIR_REL}/impl-notes.md\` の \`## Implementation Notes\` セクション配下に
     \`### Task ${task_id}\` 見出しを **追加**（既存セクションが無ければ作成）し、本 task の
     learning を簡潔に記録する:
     - 採用方針（1 行）
     - 重要な判断（1〜3 行）
     - 残存課題（次 task に影響する事項。なければ「なし」）
   - **先行 task の \`### Task <id>\` 見出し（既存の learnings）は改変・削除・並び替えしない**
   - \`## Implementation Notes\` セクション **外** の既存記述（補足ノート / 確認事項など）
     には触れない

${learnings_block}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（Reviewer / PjM は別 stage で起動されます）
- **本 task 以外の未完了 task には一切着手しないこと**
- requirements.md / design.md / tasks.md 本文の書き換えは禁止（tasks.md の進捗マーカー
  \`- [ ]\` → \`- [x]\` のみ例外）

## 既存 commit の温存

本 worktree は既存 commit を温存した状態でチェックアウトされています。

- 作業前に \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積むか、
  impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ
EOF
}

# ─── build_per_task_reviewer_prompt <task_id> <range_start_sha> <range_end_sha> <round> <prev_result> ───
#
# per-task Reviewer 用の prompt を heredoc で組み立てて stdout に出力。
# 既存 `build_reviewer_prompt` の形式を踏襲しつつ、以下を明示する:
#
#   - 判定対象 diff range は `<range_start>..<range_end>` のみ（HEAD 全体ではない / Req 3.2）
#   - 判定 AC は当該 task の `_Requirements:_` 列挙分のみ（全 AC verify は Stage B / Req 3.3）
#   - `_Boundary:_` 違反は depth に関わらず常に reject 対象
#   - 既存 reviewer.md の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）と
#     RESULT 行 / review-notes.md 出力契約を流用
#
# Requirements: 3.1, 3.2, 3.3
build_per_task_reviewer_prompt() {
  local task_id="$1"
  local range_start="$2"
  local range_end="$3"
  local round="$4"
  local prev_result="$5"

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **per-task ループ**（PER_TASK_LOOP_ENABLED=true）の下で、直前の Implementer が
完了した **1 件の task の commit 範囲のみ** を独立 context でレビューするために起動されました。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 判定対象の task / diff range

- **対象 task ID**: \`${task_id}\`
- **range_start_sha**: \`${range_start}\` （= 直前の \`docs(tasks): mark\` commit、または初回時は \`${BASE_BRANCH}\` の SHA）
- **range_end_sha**:   \`${range_end}\`   （= 当該 task の \`docs(tasks): mark ${task_id} as done\` commit）

reviewer は **本 range のみ** を判定対象としてください。HEAD 全体は対象外（全体観点は
最終 Stage B Reviewer が別途担当します）。

## 必読ファイル

reviewer サブエージェントは着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（特に対象 task \`${task_id}\` の \`_Requirements:_\` / \`_Boundary:_\`）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer の補足。\`### Task ${task_id}\` の learning を含む）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

reviewer は **必ず自分で** Bash で以下を実行し、本 task の commit 範囲だけを取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${range_start}..${range_end}
   git log --oneline ${range_start}..${range_end}
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${range_start}..${range_end} -- <path>
   \`\`\`

## 判定基準（per-task ループの判定 depth 制約）

reviewer.md の **3 カテゴリ**（AC 未カバー / missing test / boundary 逸脱）のみで判定します。
per-task ループでは判定 depth が以下に絞り込まれます:

- **判定対象 AC**: 当該 task \`${task_id}\` の \`_Requirements:_\` で列挙された numeric ID **のみ**
  - それ以外の AC が当該 diff で未カバーであっても reject 理由にしないこと
  - 全 AC verify は最終 Stage B Reviewer が HEAD 全体で実施するため、本 Reviewer では
    範囲外 AC を理由とした reject を出さない
- **\`_Boundary:_\` 違反**: depth に関わらず **常に reject 対象**（task 単位境界の逸脱検出が
  本ループの主目的）

## 進め方

reviewer サブエージェントを起動し、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること（lowercase 完全一致）
- 装飾（バッククォート / bullet / blockquote / 行末プローズ）禁止

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと
- スタイル / 命名 / lint / フォーマット観点での reject はしないこと
EOF
}

# ─── run_per_task_implementer <task_id> ───
#
# 当該 task 1 件のみを対象に fresh Claude session で Implementer を起動。
#
# 戻り値:
#   0  = success（Implementer が正常終了 + `docs(tasks): mark <id> as done` commit が積まれた前提）
#   1  = claude 非 0 exit / 規約違反（claude-failed は呼び出し側で付与）
#   99 = quota 超過（既存 #66 規約に従い呼び出し側に伝搬）
#
# Requirements: 2.2, 2.6, NFR 1.3, NFR 2.1, NFR 2.2
run_per_task_implementer() {
  local task_id="$1"
  local prompt
  prompt=$(build_per_task_implementer_prompt "$task_id")

  pt_log "task=$task_id implementer start (model=$DEV_MODEL, max-turns=$DEV_MAX_TURNS)" >> "$LOG"
  echo "--- per-task Implementer 実行 (task=$task_id) ---" >> "$LOG"

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-pt-impl-${task_id}-${_qa_ts}"
  _qa_stage_label="PerTask-Impl-${task_id}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=0" >> "$LOG"
      return 0
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=99 result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id implementer end rc=$_qa_rc result=error" >> "$LOG"
      return 1
      ;;
  esac
}

# ─── run_per_task_reviewer <task_id> <round> ───
#
# 当該 task の diff range のみを対象に fresh Claude session で Reviewer を起動。
# `pt_resolve_diff_range` で range を解決し、`build_per_task_reviewer_prompt` で prompt を
# 組み立てて `claude --print` 起動 → `parse_review_result` で RESULT を抽出。
#
# 戻り値:
#   0  = approve
#   1  = reject
#   2  = 異常終了（claude crash / parse 失敗 / RESULT 行欠落）
#   3  = diff range 解決失敗（marker commit が単記でも連記でも見つからない / Issue #164）
#   99 = quota 超過
#
# 戻り値 2 と 3 の使い分け（Issue #164 Req 4）:
#   - rc=2: claude プロセスが起動した後の異常終了（呼び出し側は既存の
#     `per-task-reviewer-error` カテゴリで `claude-failed` 付与）
#   - rc=3: claude プロセス起動前に diff range が解決できなかった（marker 不在）。
#     呼び出し側は専用の復旧手順付き Issue コメントで `claude-failed` 付与する。
#     NFR 3.1 に従い「reflog で push 前 commit を回収」「1 commit = 1 task ID で分割」
#     旨を運用者向けに 5 分以内に判断できる粒度で出力する。
#
# Requirements: 3.1, 3.2, 3.3, NFR 2.1, NFR 2.2, NFR 2.3, Issue #164 Req 4.1, 4.2, 4.3, NFR 2.2
run_per_task_reviewer() {
  local task_id="$1"
  local round="$2"

  # diff range 解決
  local range_line range_start range_end
  if ! range_line=$(pt_resolve_diff_range "$task_id"); then
    # Issue #164 NFR 2.2: 単記 / 連記いずれの候補も見つからなかった旨を明示
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-resolve-failed detail=no-marker-commit-found(single-id-and-multi-id-both-missing)" >> "$LOG"
    return 3
  fi
  range_start=$(printf '%s' "$range_line" | cut -f1)
  range_end=$(printf '%s' "$range_line" | cut -f2)
  if [ -z "$range_start" ] || [ -z "$range_end" ]; then
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-empty detail=resolved-but-empty-pair" >> "$LOG"
    return 3
  fi

  # prev_result（round=2 のみ意味あり）
  local prev_result="(none)"
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  pt_log "task=$task_id reviewer start round=$round model=$REVIEWER_MODEL max-turns=$REVIEWER_MAX_TURNS range=${range_start:0:7}..${range_end:0:7}" >> "$LOG"
  echo "--- per-task Reviewer 実行 (task=$task_id, round=$round) ---" >> "$LOG"

  local prompt
  prompt=$(build_per_task_reviewer_prompt "$task_id" "$range_start" "$range_end" "$round" "$prev_result")

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-pt-rev-${task_id}-r${round}-${_qa_ts}"
  _qa_stage_label="PerTask-Rev-${task_id}-r${round}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$REVIEWER_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$REVIEWER_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id reviewer end round=$round result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      pt_log "task=$task_id reviewer end round=$round result=error reason=claude-exit-nonzero rc=$_qa_rc" >> "$LOG"
      return 2
      ;;
  esac

  # review-notes.md を parse
  local parsed
  if ! parsed=$(parse_review_result "$notes_path"); then
    pt_log "task=$task_id reviewer end round=$round result=error reason=parse-failed" >> "$LOG"
    return 2
  fi

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      pt_log "task=$task_id reviewer end round=$round result=approve verified=$targets" >> "$LOG"
      return 0
      ;;
    reject)
      # NFR 2.3: reject 時は task ID / カテゴリ / 対応 requirement ID をログに 1 行で記録
      pt_log "task=$task_id reviewer end round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      return 1
      ;;
    *)
      pt_log "task=$task_id reviewer end round=$round result=error reason=unknown-result" >> "$LOG"
      return 2
      ;;
  esac
}

# ─── pt_mark_diff_range_resolve_failed <task_id> <round> ───
#
# diff-range-resolve-failed カテゴリで `claude-failed` を付与し、復旧手順付き Issue
# コメントを投稿する専用ヘルパー（Issue #164 Req 4）。
#
# 通常の `per-task-reviewer-error` 経路（claude crash / parse 失敗等）との違い:
#   - claude プロセス起動 **前** の失敗（marker commit 単記 / 連記いずれも見つからない）
#   - 重大なデータ損失リスク（push 前の Developer commit が次サイクル worktree reset で
#     失われる）を回避するため、運用者向けに `git reflog` 復旧手順と marker commit 分割
#     規約（1 commit = 1 task ID）を明示する
#
# 重複コメント抑制（Req 4.4）:
#   - HTML コメント marker `<!-- idd-claude:per-task-diff-range-resolve-failed:#<issue>:<task> -->`
#     を本文末尾に埋め込み、当該 Issue に同一 marker のコメントが既存なら新規投稿を skip
#     して既存コメントに「追記」する形式の単発コメントのみ追加する
#
# Args:
#   $1 = task_id (例: `1.2`)
#   $2 = round (1 / 2 / 3 のいずれか / どの round で失敗したかを Issue に明示するため)
#
# 副作用:
#   1. claude-claimed / claude-picked-up を除去し claude-failed を付与
#   2. 復旧手順付き Issue コメントを 1 件投稿（既存があれば追記コメント）
#
# Requirements: Issue #164 Req 4.1, 4.2, 4.3, 4.4, NFR 1.2, NFR 3.1
pt_mark_diff_range_resolve_failed() {
  local task_id="$1"
  local round="$2"
  local hostname_val
  hostname_val=$(hostname)
  local marker="<!-- idd-claude:per-task-diff-range-resolve-failed:#${NUMBER}:${task_id} -->"

  # NFR 1.2: 重複コメント抑制のため既存 marker を gh API で検索
  local comments_json existing_count=0
  if comments_json=$(gh issue view "$NUMBER" --repo "$REPO" --json comments 2>/dev/null); then
    existing_count=$(echo "$comments_json" | jq -r --arg marker "$marker" '
      (.comments // []) | map(select(.body | contains($marker))) | length
    ' 2>/dev/null || echo "0")
    [ -n "$existing_count" ] || existing_count=0
  fi

  # ラベル付け替え（既存 mark_issue_failed と同方針 / 1 コマンド原子的に発行）
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local body_header
  if [ "$existing_count" -gt 0 ]; then
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-diff-range-resolve-failed / round=${round}）— **追記コメント**

本 Issue には同一カテゴリ (\`diff-range-resolve-failed\` / task=\`${task_id}\`) の失敗コメントが既に存在します。
本コメントは状況が再発生したことを示す追記です。詳細な復旧手順は既存コメントを参照してください。"
  else
    body_header="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: per-task-diff-range-resolve-failed / round=${round}）"
  fi

  local body
  body=$(cat <<EOF
${body_header}

## 失敗カテゴリ
- カテゴリ: \`diff-range-resolve-failed\`
- 対象 task ID: \`${task_id}\`
- 失敗 round: ${round}
- ログ: \`$LOG\`

## 原因
per-task Reviewer が当該 task の \`docs(tasks): mark ${task_id} as done\` marker commit を
\`${BASE_BRANCH}..HEAD\` 範囲で解決できませんでした（単記 marker / 連記 marker いずれも
不一致）。Developer が以下のいずれかに該当した可能性があります:

- 進捗 marker commit を作成せずに実装 commit のみで完了した
- marker commit subject が canonical 形式 \`docs(tasks): mark <id> as done\` から逸脱した
  （例: prefix 違い / suffix の追加 / typo）
- 連記 marker commit に task ID \`${task_id}\` と完全一致するトークンが含まれていない
  （Issue #164 で許容拡大した連記マッチ機構でも検出できなかった）

## 復旧手順（重要 / データ損失リスク回避）

**【重要】次サイクルで本ブランチの worktree が reset される可能性があります。**
push 前の Developer commit が残っていれば、次サイクル前に必ず以下を実施してください:

1. **push 前 commit の有無を確認**:
   \`\`\`bash
   cd <worktree-or-repo-dir>
   git reflog --date=iso | head -50
   git log --oneline ${BASE_BRANCH}..HEAD
   git status
   \`\`\`
2. **push 前 commit がある場合は手動で push して保護**:
   \`\`\`bash
   git push origin <current-branch>
   \`\`\`
   または、reflog から拾い直して別ブランチに退避:
   \`\`\`bash
   git branch <rescue-branch-name> <reflog-sha>
   git push origin <rescue-branch-name>
   \`\`\`
3. **marker commit の補完**: 不足している \`docs(tasks): mark ${task_id} as done\` commit を
   手動で作成（tasks.md の \`- [ ]\` → \`- [x]\` を 1 行編集して 1 commit）してから
   \`claude-failed\` ラベルを外す。これにより次サイクルで watcher が当該 task を resume できる

## 推奨される marker commit 分割の規約（1 commit = 1 task ID）

per-task Reviewer の diff range 解決は **task ID 単位**で行われます。Developer は以下を厳守すること:

- **1 つの \`docs(tasks): mark <id> as done\` commit には 1 つの task ID のみを含める**
- 親 task の完了昇格も **別 commit に分割**する（例: 子 \`1.1\` 完了で親 \`1\` も全完了に
  なる場合、\`docs(tasks): mark 1.1 as done\` と \`docs(tasks): mark 1 as done\` を別 commit
  にする）
- 連記表記（\`mark 1 / 1.1 as done\` / \`mark 1, 1.1 as done\`）は watcher が fallback 解決を
  試行するが、canonical ではない。発見次第、commit を分割し直すこと

詳細は \`repo-template/.claude/agents/developer.md\` の「per-task ループ下での Implementer の
責務」節を参照してください。

${marker}
EOF
)

  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# ─── run_per_task_loop ───
#
# Stage A の代替実体。未完了 task を numeric ID 順に 1 件ずつ Implementer + Reviewer で
# 消化する dispatcher。
#
# 戻り値:
#   0  = 全 task 消化成功（Stage A 完了相当）/ pending 0 件で no-op /
#        tasks.md 不在の防御ガード（呼び出し側で Stage A fallback 済みの想定 / #166）
#   1  = Implementer / Reviewer 失敗で claude-failed 付与済み（呼び出し側は伝搬 return 1）
#
# 副作用:
#   - 成功時: 全 task が `- [x]` 化 + `docs(tasks): mark <id> as done` commit が積まれる
#   - 失敗時: `mark_issue_failed` 経由で claude-failed 付与済
#   - quota 超過時: 呼び出し側に return 99 相当で伝搬する代わりに return 0（既存 Stage A
#     の quota パスと同じく watcher は正常終了し、Resume Processor が次 tick で再開）
#
# Requirements: 2.1, 2.6, 2.7, 3.4, 3.5, 3.6, 3.7, 5.1, 5.2
run_per_task_loop() {
  local tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  # tasks.md 不在の事前分岐は呼び出し側 run_impl_pipeline() の Stage A 分岐で実施済み
  # （#166: tasks.md 不在なら per-task ループへ入らず従来 Stage A へフォールバックする）。
  # 本ブロックは万一直接呼び出し等で到達した場合の防御ガード。Issue を失敗扱いせず
  # （claude-failed を付けず）no-op return 0 で抜け、メッセージと実装の乖離を作らない。
  if [ ! -f "$tasks_md" ]; then
    pt_warn "tasks.md が存在しません: $tasks_md → per-task ループを起動せず no-op return 0（呼び出し側で Stage A fallback 済みの想定）"
    return 0
  fi

  # pending タスク一覧
  local pending
  pending=$(pt_extract_pending_tasks "$tasks_md" || true)
  if [ -z "$pending" ]; then
    pt_log "pending tasks=0 → no-op return 0 (Stage A 完了相当)" >> "$LOG"
    return 0
  fi

  local pending_count
  pending_count=$(printf '%s\n' "$pending" | wc -l | tr -d '[:space:]')
  pt_log "pending tasks=$pending_count" >> "$LOG"

  # PER_TASK_MAX_TASKS 超過チェック（暴走防止）
  local max_tasks="${PER_TASK_MAX_TASKS:-0}"
  if [ -n "$max_tasks" ] && [ "$max_tasks" != "0" ] && [ "$pending_count" -gt "$max_tasks" ]; then
    pt_warn "pending tasks=$pending_count が PER_TASK_MAX_TASKS=$max_tasks を超過 → claude-failed"
    mark_issue_failed "per-task-max-tasks-exceeded" "per-task ループの安全装置: 未完了 task 件数（${pending_count}）が \`PER_TASK_MAX_TASKS=${max_tasks}\` を超過したため、暴走防止のためループ起動前に停止しました。tasks.md を縮小するか \`PER_TASK_MAX_TASKS\` を引き上げてください。"
    return 1
  fi

  # 各 task をループで消化
  local task_id
  while IFS= read -r task_id; do
    [ -n "$task_id" ] || continue

    # ── round=1: Implementer + Reviewer ──
    local impl_rc=0
    run_per_task_implementer "$task_id" || impl_rc=$?
    case "$impl_rc" in
      0) ;; # 続行
      99)
        # quota 超過: 既存 #66 規約に従い watcher は正常終了。Resume Processor が次 tick で再開
        echo "⏸️ #$NUMBER: per-task Implementer (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
        return 0
        ;;
      *)
        echo "❌ #$NUMBER: per-task Implementer (task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "per-task-implementer-failed" "per-task ループの Implementer が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。残りの未完了 task は処理しません。\`$LOG\` を確認してください。"
        return 1
        ;;
    esac

    # ── Phase 3 (#22) Debugger Gate: per-task Implementer 完了直後 BLOCKED 検出 ──
    # `DEBUGGER_ENABLED=true` 時のみ、当該 task の Implementer が impl-notes.md に
    # `BLOCKED: <reason>` を出力していたら task 単位で Debugger を 1 回起動して
    # Implementer 再起動 → 通常 Reviewer Round 1 サイクルに合流する（Req 6.2, 6.3）。
    # 既起動なら直行 claude-failed（Req 5.2）。OFF 時は本ブロックが構造的に skip。
    if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
      local _pt_blocked_reason=""
      if _pt_blocked_reason=$(detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"); then
        if detect_debugger_already_invoked "$task_id"; then
          dbg_log "trigger=blocked issue=#${NUMBER} task=${task_id} reason=\"${_pt_blocked_reason}\" result=skipped reason=debugger-already-invoked" >> "$LOG"
          echo "❌ #$NUMBER: per-task BLOCKED 宣言検出 (task=$task_id) だが Debugger 既起動 → claude-failed (Req 5.2)" | tee -a "$LOG"
          mark_issue_failed "per-task-debugger-blocked-but-invoked" "per-task ループの Developer が task=\`${task_id}\` で \`BLOCKED:\` 行を出力しましたが、本 task では既に Debugger が 1 回起動済みのため再起動を抑止し人間判断に委ねます（Req 5.1, 5.2, 6.3）。

- 対象 task ID: ${task_id}
- BLOCKED reason: ${_pt_blocked_reason}
- 既存 Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` の \`## Task ${task_id}\` セクション
- impl-notes.md: \`${SPEC_DIR_REL}/impl-notes.md\`

\`$LOG\` を確認し、Fix Plan の追加修正 / 別 Issue 切り出し等を判断してください。"
          return 1
        fi

        echo "🐛 #$NUMBER: per-task Developer BLOCKED 宣言検出 (task=$task_id) → Debugger Gate 起動" | tee -a "$LOG"
        dbg_log "trigger=blocked issue=#${NUMBER} task=${task_id} reason=\"${_pt_blocked_reason}\" start" >> "$LOG"
        local _pt_dbg_bl_rc=0
        run_debugger_stage "blocked" "$task_id" "" || _pt_dbg_bl_rc=$?
        case "$_pt_dbg_bl_rc" in
          99)
            echo "⏸️ #$NUMBER: Debugger (task=$task_id / BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          0)
            echo "✅ #$NUMBER: Debugger (task=$task_id / BLOCKED 経路) 完了 → per-task Implementer 再起動" | tee -a "$LOG"
            ;;
          *)
            return 1
            ;;
        esac

        # Implementer 再起動（task 単位 / Fix Plan は impl-notes.md / debugger-notes.md を Implementer が読む）
        local impl_bl_rc=0
        run_per_task_implementer "$task_id" || impl_bl_rc=$?
        case "$impl_bl_rc" in
          0) ;; # 続行: 通常の Reviewer Round 1 に合流（Req 6.2 / 4.4 相当）
          99)
            echo "⏸️ #$NUMBER: per-task Implementer (BLOCKED 経路再実行 / task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            echo "❌ #$NUMBER: per-task Implementer (BLOCKED 経路再実行 / task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-implementer-blocked-redo-failed" "per-task ループの BLOCKED 経路 Implementer 再実行が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac
      fi
    fi

    local rev_rc=0
    run_per_task_reviewer "$task_id" 1 || rev_rc=$?
    case "$rev_rc" in
      0)
        # approve → 次 task へ
        ;;
      99)
        echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=1) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
        return 0
        ;;
      1)
        # reject 1 回目 → Implementer 再起動 + Reviewer round=2
        echo "🔁 #$NUMBER: per-task Reviewer (task=$task_id, round=1) reject → Implementer 再実行" | tee -a "$LOG"

        local impl2_rc=0
        run_per_task_implementer "$task_id" || impl2_rc=$?
        case "$impl2_rc" in
          0) ;;
          99)
            echo "⏸️ #$NUMBER: per-task Implementer 再実行 (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            echo "❌ #$NUMBER: per-task Implementer 再実行 (task=$task_id) 失敗 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-implementer-redo-failed" "per-task ループの Implementer 再実行が task=\`${task_id}\` で失敗しました（Reviewer reject 後の再起動 / claude 非 0 exit）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac

        local rev2_rc=0
        run_per_task_reviewer "$task_id" 2 || rev2_rc=$?
        case "$rev2_rc" in
          0)
            # round=2 approve → 次 task へ
            ;;
          99)
            echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=2) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          1)
            # 再 reject → Phase 3 (#22) Debugger Gate に分岐 (Req 6.1, 6.3)、
            # 未対応なら claude-failed + Issue コメント
            if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked "$task_id"; then
              echo "🐛 #$NUMBER: per-task Reviewer (task=$task_id, round=2) reject → Debugger Gate 起動（task scope）" | tee -a "$LOG"
              local _pt_dbg_rc=0
              run_debugger_stage "round2-reject" "$task_id" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" || _pt_dbg_rc=$?
              case "$_pt_dbg_rc" in
                99)
                  echo "⏸️ #$NUMBER: Debugger (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                0)
                  echo "✅ #$NUMBER: Debugger (task=$task_id) 完了 → per-task Implementer 再起動 + Reviewer round=3" | tee -a "$LOG"
                  ;;
                *)
                  # Debugger 異常終了 → mark_issue_failed 既発射
                  return 1
                  ;;
              esac

              # Implementer 再起動（Fix Plan 注入は per-task Implementer の prompt builder には未対応のため、
              # debugger-notes.md の存在を Implementer が `### Task <id>` セクションで読むことに依拠する）
              local impl3_rc=0
              run_per_task_implementer "$task_id" || impl3_rc=$?
              case "$impl3_rc" in
                0) ;;
                99)
                  echo "⏸️ #$NUMBER: per-task Implementer 3 回目 (task=$task_id) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                *)
                  echo "❌ #$NUMBER: per-task Implementer 3 回目 (task=$task_id / Debugger 経由) 失敗 → claude-failed" | tee -a "$LOG"
                  mark_issue_failed "per-task-implementer-pp-failed" "per-task ループの Debugger 経由 Implementer 再実行が task=\`${task_id}\` で失敗しました（claude 非 0 exit）。\`$LOG\` を確認してください。"
                  return 1
                  ;;
              esac

              # Reviewer Round 3（task 単位）
              local rev3_rc=0
              run_per_task_reviewer "$task_id" 3 || rev3_rc=$?
              case "$rev3_rc" in
                0)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=approve" >> "$LOG"
                  # approve → 次 task へ
                  ;;
                99)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=quota-exceeded" >> "$LOG"
                  echo "⏸️ #$NUMBER: per-task Reviewer (task=$task_id, round=3) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                  return 0
                  ;;
                1)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=reject" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) reject → claude-failed (Req 3.5)" | tee -a "$LOG"
                  local parsed3pt cat3pt tgt3pt
                  parsed3pt=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                  cat3pt=$(echo "$parsed3pt" | cut -f2)
                  tgt3pt=$(echo "$parsed3pt" | cut -f3)
                  mark_issue_failed "per-task-reviewer-reject3" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) も reject を出したため、自動 iteration を打ち切り人間判断に委ねます（Debugger は 1 task あたり 1 回のみ起動するため再起動しません / Req 3.5, 6.3）。

- 対象 task ID: ${task_id}
- 対象 requirement ID: ${tgt3pt:-(unknown)}
- reject カテゴリ: ${cat3pt:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照
- Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` を参照

### 次の手順
1. review-notes.md / debugger-notes.md / watcher ログ \`$LOG\` を読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                  return 1
                  ;;
                3)
                  # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=diff-range-resolve-failed" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
                  pt_mark_diff_range_resolve_failed "$task_id" 3
                  return 1
                  ;;
                *)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} round3 result=error" >> "$LOG"
                  echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=3) 異常終了 → claude-failed" | tee -a "$LOG"
                  mark_issue_failed "per-task-reviewer-error" "per-task ループの Debugger 経由 Reviewer (task=\`${task_id}\`, round=3) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
                  return 1
                  ;;
              esac
            else
              # DEBUGGER_ENABLED != "true" もしくは task sentinel 既起動 → 既存 per-task-reviewer-reject2 経路
              if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
                dbg_log "trigger=round2-reject issue=#${NUMBER} task=${task_id} result=skipped reason=debugger-already-invoked" >> "$LOG"
              fi
              echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) reject → claude-failed" | tee -a "$LOG"
              local parsed2 cat2 tgt2
              parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
              cat2=$(echo "$parsed2" | cut -f2)
              tgt2=$(echo "$parsed2" | cut -f3)
              mark_issue_failed "per-task-reviewer-reject2" "per-task ループの Reviewer が task=\`${task_id}\` で 2 回連続 reject を出したため、残りの未完了 task の処理を停止し人間判断に委ねます。

- 対象 task ID: ${task_id}
- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログ \`$LOG\` を読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
              return 1
            fi
            ;;
          3)
            # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
            pt_mark_diff_range_resolve_failed "$task_id" 2
            return 1
            ;;
          *)
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) 異常終了 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=2) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac
        ;;
      3)
        # diff-range-resolve-failed (Issue #164) → 専用の復旧手順付き失敗ハンドラ
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) diff range 解決失敗 → claude-failed (diff-range-resolve-failed)" | tee -a "$LOG"
        pt_mark_diff_range_resolve_failed "$task_id" 1
        return 1
        ;;
      *)
        # round=1 reviewer error → claude-failed
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) 異常終了 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=1) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
        return 1
        ;;
    esac
  done <<<"$pending"

  pt_log "all pending tasks completed (count=$pending_count) → return 0" >> "$LOG"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Debugger Gate (#22 Phase 3) — ヘルパー関数群
#
# `DEBUGGER_ENABLED=true` のときに `run_impl_pipeline` の Stage B' (Round 2) reject 直前
# / Stage A 完了直後 BLOCKED 検出経路で起動される Debugger サブエージェントの補助関数を、
# Reviewer Gate セクションの直前に独立セクションとして配置する。`DEBUGGER_ENABLED` が
# 未指定 / `=true` 以外の場合、これらの関数はどこからも呼ばれないため、本機能導入前と
# 外形挙動は完全一致する（NFR 1.1 / Req 1.1, 1.2）。
#
# 関数一覧:
#   - dbg_log:                          Debugger 専用ロガー (rv_log / pt_log と同形式 / NFR 2.1, 2.2)
#   - detect_blocked_marker:            impl-notes.md の行頭 `BLOCKED: <reason>` を検出
#   - detect_debugger_already_invoked:  sentinel file ベースで再起動抑止判定
#   - validate_debugger_notes:          debugger-notes.md の必須 h2 セクション 4 つを verify
#   - build_debugger_prompt:            Debugger 起動用 prompt を組立
#   - run_debugger_stage:               claude --print で fresh Debugger 起動 + 結果 verify
#   - build_dev_prompt_redo_with_fix_plan: Fix Plan 注入版 Developer 再起動 prompt
#
# 詳細: docs/specs/22-phase-3-debugger-subagent-blocked-2-reje/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── dbg_log ───
# Debugger 専用ロガー。`[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: <msg>` 形式で stdout
# に出力。呼び出し側で `>> "$LOG"` する規約（既存 rv_log / pt_log / qa_log と同じ）。
# Issue #119 規約準拠で時刻 prefix と processor prefix の間に `[$REPO]` を 1 つだけ挿入。
# NFR 2.1 / NFR 2.2 を満たす。
dbg_log() {
  echo "[$(date '+%F %T')] [$REPO] debugger: $*"
}
dbg_warn() {
  echo "[$(date '+%F %T')] [$REPO] debugger: WARN: $*" >&2
}

# ─── detect_blocked_marker <impl_notes_path> ───
#
# impl-notes.md の **行頭固定** で `BLOCKED: <reason>` 行を検出し、reason 部を stdout に
# 出力する。検出時 return 0、未検出 / ファイル不在時 return 1。
#
# 規約（Req 4.2 / 誤検出抑止）:
#   - regex は `^BLOCKED: (.+)$`（行頭固定、半角コロン + 半角スペース + 任意 reason 文字列）
#   - インデント / list marker `- ` / 引用 `> ` の prefix は **検出対象外**
#   - reason 部の `:` 文字は破壊しない（grep -E で行マッチした上で sed で先頭 `BLOCKED: ` を剥がす）
#   - 複数マッチ時は **1 行目** のみ採用
#
# Requirements: 4.1, 4.2
detect_blocked_marker() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 1
  fi
  local line
  # grep -E で行頭固定マッチ。set -euo pipefail 配下では grep no-match で関数全体が止まるため
  # `|| true` で吸収。
  line=$(grep -E '^BLOCKED: .+$' "$impl_notes" 2>/dev/null | head -n 1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  # 先頭 `BLOCKED: `（10 文字）を剥がして reason のみ stdout に出す。
  # reason 部に `:` が含まれても破壊されないよう、置換ではなく substring 切り出しを行う。
  printf '%s\n' "${line#BLOCKED: }"
  return 0
}

# ─── detect_partial_status <impl_notes_path> ───
#
# impl-notes.md の **行頭固定** で `STATUS: <value>` 行を検出し、value 部を stdout に
# 出力する（Partial Status Gate / #148）。
#
# 戻り値:
#   0 = STATUS 行検出（stdout に値を出力。値の妥当性チェックは呼出側責務）
#   1 = STATUS 行不在（既存 complete fallback / NFR 1.1）
#   2 = ファイル不在
#
# 規約（design.md 「Service Interface」/ Req 1.1, 1.2, 1.3 / NFR 3.2）:
#   - regex は `^STATUS: (.+)$`（行頭固定、半角コロン + 半角スペース + 任意 value 文字列）
#   - インデント / list marker `- ` / 引用 `> ` / バッククォートの prefix は **検出対象外**
#   - 複数マッチ時は **最終行** を採用（Developer 再実行で上書きされた場合に新しい値を採用）
#   - 値は前後の空白を trim
#   - status 値の正規化（complete / partial_blocked / partial_overrun / 不正）は呼出側
#     （handle_partial_status）の責務（テスト容易性のため本関数では raw 値を返す）
#
# Requirements: 1.1, 1.2, 1.3, NFR 1.1, NFR 3.2
detect_partial_status() {
  local impl_notes="$1"
  if [ ! -f "$impl_notes" ]; then
    return 2
  fi
  local line
  # grep -E で行頭固定マッチ。`tail -n 1` で複数マッチ時は最終行採用（detect_blocked_marker
  # との違い: BLOCKED は 1 行目採用 / STATUS は最終行採用 = 再実行で上書きされた新しい値を優先）。
  # set -euo pipefail 配下では grep no-match で関数全体が止まるため `|| true` で吸収。
  line=$(grep -E '^STATUS: .+$' "$impl_notes" 2>/dev/null | tail -n 1 || true)
  if [ -z "$line" ]; then
    return 1
  fi
  # 先頭 `STATUS: `（8 文字）を剥がして value のみ取り出す。
  local value="${line#STATUS: }"
  # 前後の空白を trim（POSIX 互換: ${var#"..."} / ${var%"..."} で extglob 不要）。
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
  return 0
}

# ─── detect_debugger_already_invoked [<task_id>] ───
#
# sentinel file ベースで「当該 scope（Issue or task）で Debugger が既に 1 回起動済み」を
# 判定する。Issue 単位 / task 単位の両方に対応。
#
# 判定ロジック:
#   - Issue 単位（task_id 空 / 引数なし）: `$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md` が
#     存在すれば「起動済み」（return 0）
#   - task 単位（task_id 指定）: 上記ファイル内に `## Task <task_id>` セクション見出しが
#     存在すれば「起動済み」（grep で行頭マッチ）
#   - 未起動時は return 1（呼び出し側が run_debugger_stage を起動可能）
#
# 既存 commit に乗っている sentinel は impl-resume 経由の pickup 再開でも観測可能（Req 5.5）。
#
# Requirements: 5.1, 5.2, 5.5, 6.3, 6.4
# shellcheck disable=SC2120  # task_id は意図的に optional（Issue 単位起動時は引数なしで呼ぶ / Req 6.4）
detect_debugger_already_invoked() {
  local task_id="${1:-}"
  local sentinel="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
  if [ ! -f "$sentinel" ]; then
    return 1
  fi
  if [ -z "$task_id" ]; then
    # Issue 単位: ファイル存在で「起動済み」
    return 0
  fi
  # task 単位: `## Task <id>` 見出しの存在で判定（行頭固定マッチ）。
  if grep -qE "^## Task ${task_id}\$" "$sentinel" 2>/dev/null; then
    return 0
  fi
  return 1
}

# ─── validate_debugger_notes <debugger_notes_path> [<task_id>] ───
#
# Debugger 終了後、`debugger-notes.md` の必須セクション 4 つが存在するかを grep で verify する。
#
# 必須セクション:
#   - Issue 単位（task_id 空 / 引数なし）: `## 根本原因` / `## 修正手順` / `## 検証方法` / `## 関連参考資料`
#   - Phase 2 有効時（task_id 指定）: `## Task <id>` 配下に
#     `### 根本原因` / `### 修正手順` / `### 検証方法` / `### 関連参考資料`
#
# 1 つでも欠落していたら return 1（呼び出し側は claude-failed）。ファイル不在時も return 1。
#
# Requirements: 2.3, 3.6, 4.3
validate_debugger_notes() {
  local notes_path="$1"
  local task_id="${2:-}"
  if [ ! -f "$notes_path" ]; then
    return 1
  fi
  local prefix sec
  if [ -z "$task_id" ]; then
    prefix="## "
  else
    # task 単位は h2 `## Task <id>` の存在を前提に h3 4 つを verify
    if ! grep -qE "^## Task ${task_id}\$" "$notes_path" 2>/dev/null; then
      return 1
    fi
    prefix="### "
  fi
  for sec in "根本原因" "修正手順" "検証方法" "関連参考資料"; do
    if ! grep -qF "${prefix}${sec}" "$notes_path" 2>/dev/null; then
      return 1
    fi
  done
  return 0
}

# ─── build_debugger_prompt <trigger> [<task_id>] [<review_notes_path>] ───
#
# Debugger 起動用 prompt を組み立てて stdout に出力。trigger / task_id / review-notes 有無
# に応じて入力対象を切り替える。既存 `build_reviewer_prompt` の heredoc 形式を踏襲。
#
# 引数:
#   $1 = trigger ∈ {round2-reject | blocked}
#   $2 = task_id (空文字なら Issue 単位 / Phase 2 有効時のみ指定)
#   $3 = review_notes_path (trigger=round2-reject のみ、BLOCKED 時は空文字)
#
# Requirements: 2.2, 2.4, 2.5, 6.5
build_debugger_prompt() {
  local trigger="$1"
  local task_id="${2:-}"
  local review_notes_path="${3:-}"

  local trigger_label
  case "$trigger" in
    round2-reject) trigger_label="Reviewer Round 2 reject 直前" ;;
    blocked)       trigger_label="Developer BLOCKED 宣言経路" ;;
    *)             trigger_label="(unknown trigger: ${trigger})" ;;
  esac

  local task_block
  if [ -n "$task_id" ]; then
    task_block=$(cat <<EOF
## 対象 task（Phase 2 per-task loop 有効時）

- **対象 task ID**: \`${task_id}\`
- 本起動では \`tasks.md\` の **task ${task_id} 1 件の \`_Requirements:_\` で列挙された AC のみ** を verify 対象としてください
- 他 task の context は参照しないこと（task 単位の独立性 / Req 6.5）
- \`git diff\` / \`git log\` は当該 task の \`docs(tasks): mark ${task_id} as done\` commit 範囲のみを対象に絞り込むこと
- \`debugger-notes.md\` 出力時は **既存ファイルの末尾に append**: \`## Task ${task_id}\` 見出しを追加し、その配下に h3 4 セクション
EOF
)
  else
    task_block=$(cat <<EOF
## 対象 scope

- 本起動は **Issue 単位** で起動されています（Phase 2 per-task loop 無効）
- \`tasks.md\` 全体 / \`requirements.md\` の全 AC を verify 対象としてください
- \`debugger-notes.md\` は新規作成: h1 \`# Debugger Notes (Issue #${NUMBER})\` + h2 4 セクション
EOF
)
  fi

  local review_notes_block
  case "$trigger" in
    round2-reject)
      if [ -n "$review_notes_path" ] && [ -f "$review_notes_path" ]; then
        review_notes_block=$(cat <<EOF
## Reviewer の reject 理由（review-notes.md より）

Round 2 reject の経路です。以下の \`review-notes.md\` の Findings を **重点的に** 参照し、
Developer の差し戻し 1 回（Stage A'）でも解消できなかった根本原因を特定してください。

\`\`\`markdown
$(cat "$review_notes_path")
\`\`\`
EOF
)
      else
        review_notes_block="## Reviewer の reject 理由

（\`review-notes.md\` が見つかりませんでした: \`${review_notes_path}\`。\`gh issue view ${NUMBER}\`
や \`$LOG\` を Bash で参照して reject 理由を推定してください）"
      fi
      ;;
    blocked)
      review_notes_block=$(cat <<EOF
## Developer の BLOCKED 宣言

本起動は \`impl-notes.md\` の行頭 \`BLOCKED: <reason>\` 検出経路です。
Reviewer 経由ではないため \`review-notes.md\` は無し / 古い内容のままです（参照不要）。

\`impl-notes.md\` の \`BLOCKED:\` 行を **重点的に** 参照し、Developer が「自身の context では原因究明
不可能」と判断した具体的な疑問点（試したこと / 不明点 / 推奨される web search 観点）を起点に
root cause を分析してください。
EOF
)
      ;;
    *)
      review_notes_block="## トリガー識別不能

（trigger 値 \`${trigger}\` が想定外です。\`gh issue view ${NUMBER}\` で状況を確認してください）"
      ;;
  esac

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
本起動は **Debugger Gate**（DEBUGGER_ENABLED=true）の下で、${trigger_label}に
fresh な Claude CLI セッションで起動されました。

あなたの **唯一の責務** は、対象 Issue / task の **root cause 分析と Fix Plan markdown 出力** です。
コード / spec / ラベル / commit / PR の改変は一切行わないでください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- TRIGGER      : ${trigger}
- TASK_ID      : ${task_id:-(none / Issue 単位)}

${task_block}

${review_notes_block}

## 必読ファイル

debugger サブエージェントを起動し、以下を **必ず** Read してください:

- \`CLAUDE.md\`（プロジェクト憲章）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（特に対象 task の \`_Requirements:_\` / \`_Boundary:_\`）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
$( [ "$trigger" = "round2-reject" ] && echo "- \`${SPEC_DIR_REL}/review-notes.md\`（Reviewer の Findings）" )

## 差分の取得（Bash で実行）

prompt には差分本文を埋め込みません。Bash ツールで以下を実行して取得してください:

\`\`\`bash
git diff --stat ${BASE_BRANCH}..HEAD
git log --oneline ${BASE_BRANCH}..HEAD
git diff ${BASE_BRANCH}..HEAD -- <path>   # 必要に応じてファイル単位
\`\`\`

## web search の活用

外部知識が必要な原因分析には WebSearch / WebFetch を活用してください:

- 外部ライブラリの ABI / API 仕様 / breaking changes
- フレームワーク内部の挙動 / known issue / GitHub issues
- CI / 実行環境固有の制約（OS / runtime version）
- ベンダー公式ドキュメント / changelog

検索した URL とタイトル / 要約は \`## 関連参考資料\` セクションに \`[n]\` 形式で番号付け参照
してください。

## 出力先と必須セクション

出力先: \`${SPEC_DIR_REL}/debugger-notes.md\`（**追記モード**）

必須セクション（watcher が grep で verify します。1 つでも欠落すると claude-failed になります）:

$( if [ -z "$task_id" ]; then
cat <<INNER
- \`## 根本原因\`
- \`## 修正手順\`
- \`## 検証方法\`
- \`## 関連参考資料\`
INNER
else
cat <<INNER
- \`## Task ${task_id}\`（既存ファイル末尾に append、既存セクションは改変しない）
  - \`### 根本原因\`
  - \`### 修正手順\`
  - \`### 検証方法\`
  - \`### 関連参考資料\`
INNER
fi )

見出し文字列は **厳密に上記の 4 語**（日本語）です。\`## 原因\` や \`## Fix Plan\` 等の言い換え
は不可（watcher の verify が失敗します）。

## 禁止事項（やってはいけないこと）

- コードファイル（実装 / テスト）を Edit / Write しない
- spec md（\`requirements.md\` / \`design.md\` / \`tasks.md\` / \`review-notes.md\`）を Edit / Write しない
- ラベル付け替え（\`gh issue edit\` / \`gh pr edit\`）を行わない
- commit / push（\`git add\` / \`git commit\` / \`git push\`）を行わない
- PR 作成 / コメント投稿（\`gh pr create\` / \`gh issue comment\` 等）を行わない
- \`approve\` / \`reject\` 等の判定文字列を出力しない（Reviewer の責務）
- 他エージェント（PM / Architect / Developer / Reviewer / PjM）の役割を兼任しない
- \`debugger-notes.md\` 以外への Write
- 既存 \`### Task <id>\` セクションの改変 / 削除 / 並び替え（task 単位の append のみ許可）

## 進め方

1. 必読ファイルを順に Read
2. Bash で \`git diff\` / \`git log\` を実行して実装差分を全体把握
3. trigger に応じた手がかり（review-notes.md の Findings / impl-notes.md の BLOCKED 行）から問題箇所を特定
4. 必要に応じて WebSearch / WebFetch で外部知識を収集
5. 根本原因を 1 つに絞り込む
6. 具体的な修正手順を Developer が機械的に実施できる粒度で書く
7. 検証方法（テストコマンド / 期待挙動）を明示
8. \`debugger-notes.md\` を上記フォーマットで Write（追記モード）して終了
EOF
}

# ─── run_debugger_stage <trigger> [<task_id>] [<review_notes_path>] ───
#
# fresh Claude CLI セッションで Debugger を 1 回起動し、`debugger-notes.md` の存在 /
# 必須セクション形式を verify する。既存 `run_reviewer_stage` と同形（独立 context）。
#
# 引数:
#   $1 = trigger ∈ {round2-reject | blocked}
#   $2 = task_id (空文字なら Issue 単位)
#   $3 = review_notes_path (trigger=round2-reject のみ)
#
# 戻り値:
#   0   = Debugger 正常終了 + debugger-notes.md 形式 verify 成功（呼び出し側は Stage A''/A' を起動）
#   1   = claude 非 0 exit / debugger-notes.md 不在 / 必須セクション欠落
#         （呼び出し側で mark_issue_failed → return 1）
#   99  = quota 超過（呼び出し側で needs-quota-wait 退避）
#
# Requirements: 2.6, 3.6, 7.4, NFR 2.1, NFR 2.2, NFR 2.3, NFR 5.1
run_debugger_stage() {
  local trigger="$1"
  local task_id="${2:-}"
  local review_notes_path="${3:-}"

  local notes_path="$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md"
  local task_label="${task_id:-none}"

  dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} start (model=$DEBUGGER_MODEL, max-turns=$DEBUGGER_MAX_TURNS)" >> "$LOG"
  echo "--- Debugger 実行 (trigger=$trigger, task=${task_label}) ---" >> "$LOG"

  local prompt
  prompt=$(build_debugger_prompt "$trigger" "$task_id" "$review_notes_path")

  local _qa_reset_file _qa_rc=0 _qa_ts _qa_stage_label
  _qa_ts=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-debugger-${trigger}-${task_label}-${_qa_ts}"
  _qa_stage_label="Debugger-${trigger}-${task_label}"
  qa_run_claude_stage "$_qa_stage_label" "$_qa_reset_file" -- \
    claude \
      --print "$prompt" \
      --model "$DEBUGGER_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEBUGGER_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1 || _qa_rc=$?

  case "$_qa_rc" in
    0)
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=0" >> "$LOG"
      ;;
    99)
      local _qa_epoch
      _qa_epoch=$(cat "$_qa_reset_file")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label" "$_qa_epoch"
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=99 result=quota-exceeded" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file"
      dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} end rc=$_qa_rc result=error" >> "$LOG"
      mark_issue_failed "debugger-failed" "Debugger サブエージェント（trigger=\`${trigger}\`, task=\`${task_label}\`）が非 0 exit で異常終了しました（claude rc=${_qa_rc}）。Stage A'' / Stage A' / Stage B'' / Round 3 は実行されません。\`$LOG\` の Debugger 実行ログを確認してください。"
      return 1
      ;;
  esac

  # debugger-notes.md の必須セクション verify
  if ! validate_debugger_notes "$notes_path" "$task_id"; then
    dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} debugger-notes.md validation failed" >> "$LOG"
    mark_issue_failed "debugger-notes-invalid" "Debugger が \`${SPEC_DIR_REL}/debugger-notes.md\` を期待形式で出力しませんでした（必須 4 セクション \`根本原因\` / \`修正手順\` / \`検証方法\` / \`関連参考資料\` のいずれかが欠落、もしくはファイル自体が不在）。\`$LOG\` の Debugger 実行ログを確認してください。"
    return 1
  fi
  dbg_log "trigger=$trigger issue=#${NUMBER} task=${task_label} debugger-notes.md verified (sections=4)" >> "$LOG"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Reviewer Gate (#20 Phase 1) 既存セクション（per-task ループ helper / Debugger Gate helper はここまで）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Prompt Builders（Stage A / A' / B / C 用 4 関数）───
#
# 既存 DEV_PROMPT の組み立てパターン（heredoc + 変数展開）を踏襲する。
# 入力は環境変数（NUMBER / TITLE / URL / BODY / BRANCH / SPEC_DIR_REL /
# MODE / ARCHITECT_REASON）と関数引数。stdout に prompt 文字列を出力する。

# ─── _assert_base_branch_resolved ───
#
# Issue #96 Req 1.5: PR 作成系プロンプト（Stage C / design-review）を組み立てる直前に
# 解決済み `BASE_BRANCH` の実値が空文字でないことを検証する防御的ガード。
# 通常パスでは起動直後の `BASE_BRANCH="${BASE_BRANCH:-main}"` で必ず非空になるため
# 発火しないが、コード変更で誤って空文字を導入した場合に PR 作成段階で爆破するためのもの。
#
# 失敗時の挙動: stderr にエラー出力し、戻り値 1 を返す。呼び出し側（pipeline / design 分岐）が
# `_slot_mark_failed` で `claude-failed` ラベルを付与して人間にエスカレーションする。
_assert_base_branch_resolved() {
  if [ -z "${BASE_BRANCH:-}" ]; then
    echo "Error: BASE_BRANCH が空または未定義です。PR 作成プロンプトを組み立てられません（Issue #96 Req 1.5）" >&2
    return 1
  fi
  return 0
}

# Stage A: PM + Developer（impl では PM 起動、impl-resume では Developer のみ）
# 既存 DEV_PROMPT の STEPS から「PjM 起動」を除外したもの。
build_dev_prompt_a() {
  local mode="$1"
  local flow_label
  local steps

  case "$mode" in
    impl)
      flow_label="PM → Developer（Reviewer ゲート前）"
      steps=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\`
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
    impl-resume)
      flow_label="Developer（Reviewer ゲート前 / 設計 PR merge 済み）"
      steps=$(cat <<EOF
1. developer サブエージェントで実装＋テスト＋コミット
   - 入力: \`${SPEC_DIR_REL}/requirements.md\` / \`${SPEC_DIR_REL}/design.md\` / \`${SPEC_DIR_REL}/tasks.md\`
   - design.md / tasks.md は設計 PR で人間レビュー済み（${BASE_BRANCH} に merge 済み）。**書き換えないこと**
   - tasks.md の numeric ID 順にタスクを消化する
   - 矛盾や疑問があれば PR 本文「確認事項」に記載（書き換えはしない）
   - 規約は CLAUDE.md に従う
   - 実装ノートを \`${SPEC_DIR_REL}/impl-notes.md\` に保存

**重要**: 本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。
Developer 完了後、独立 context の Reviewer サブエージェントが起動して AC / test / boundary を
独立レビューします。Reviewer の approve 後にオーケストレーターが PjM を起動して PR を作成します。
EOF
)
      ;;
  esac

  # Issue #67: impl-resume + IMPL_RESUME_PRESERVE_COMMITS=true 時のみ追加注入する
  # 「resume 指示」セクションと、`IMPL_RESUME_PROGRESS_TRACKING` の値による
  # `tasks.md` 進捗マーカー更新指示の分岐。既存 prompt の Step 1 / 制約節は変更せず、
  # 末尾に節を追加するだけ（既存挙動と差分等価 / NFR 1.1）。
  #
  # `RESUME_PRESERVE` は `_resume_branch_init` が export している（Slot Runner 内）。
  # `IMPL_RESUME_PROGRESS_TRACKING` は cron / launchd 経由で渡される env 値。
  # `_resume_normalize_flag` で 2 値正規化（Req 3.6: "false" 完全一致のみ false、
  # それ以外は true）。
  local resume_section=""
  if [ "$mode" = "impl-resume" ] && [ "${RESUME_PRESERVE:-false}" = "true" ]; then
    local tracking
    tracking=$(_resume_normalize_flag tracking_default_on "${IMPL_RESUME_PROGRESS_TRACKING:-}")

    local progress_block
    if [ "$tracking" = "true" ]; then
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=true）

- 各タスクが完了した時点で `tasks.md` の対応する未完了マーカー行 `- [ ] N.M ...` を
  `- [x] N.M ...` に書き換えること
- 進捗マーカー更新は **専用 commit** として積む:
  - commit メッセージ: `docs(tasks): mark <task-id> as done`（例: `docs(tasks): mark 1.2 as done`）
  - 当該 commit には `tasks.md` 以外のファイルを含めない
- **書き換え禁止領域**: タスク本文 / `_Requirements:_` / `_Boundary:_` / `_Depends:_` /
  タスク順序 / 親タスクのインデント / deferrable 印 `- [ ]*`（アスタリスク付き）
- 親タスク（例: `- [ ] 1.`）は、その配下の全子タスクが `- [x]` になったタイミングで親側も
  `- [x]` に更新する（deferrable 子タスク `- [ ]*` は未完了のまま親完了を判定可能）
- すべてのタスクが完了済み（未完了マーカー `- [ ]` が残っていない）なら、追加実装を行わず
  impl-notes.md にその旨を記録すること
EOF
)
    else
      progress_block=$(cat <<'EOF'
### tasks.md 進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=false）

- 本サイクルでは `tasks.md` の進捗マーカー（`- [ ]` ↔ `- [x]`）を **書き換えない**
- 通常通り numeric ID 順にタスクを消化し、impl-notes.md に進捗の根拠を記録する
EOF
)
    fi

    resume_section=$(cat <<EOF

## 既存 commit からの resume（IMPL_RESUME_PRESERVE_COMMITS=true）

このサイクルは **既存の作業ブランチからの resume** で起動されました。
worktree は \`origin/${BASE_BRANCH}\` から fresh init されておらず、\`origin/${BRANCH}\` の先端から
checkout されています。**過去 Developer / 人間が積んだ commit を温存してください**。

- 作業前に必ず \`git log --oneline ${BASE_BRANCH}..HEAD\` で既存 commit を確認すること
- \`git reset\` / \`git rebase\` / branch の切り替えは **禁止**
- 未完了タスクの判定基準: \`tasks.md\` の \`- [ ]\` 行（未完了マーカー）の先頭から再開
- 既存 commit と矛盾する変更が必要な場合は、既存 commit を打ち消す追加 commit を積む
  か、impl-notes.md の「確認事項」に矛盾内容を記載して人間判断を仰ぐ

${progress_block}
EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を ${flow_label} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## 進め方
${steps}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- 既存のテストを壊さないこと
- 不明点は推測せず、impl-notes.md の「確認事項」セクションに列挙すること
- **PR は作成しないこと**（次の Reviewer ステージで独立レビューを受けます）
${resume_section}
EOF
}

# Stage A' (Developer 再実行用): Reviewer reject の Findings を inline で渡し、
# Developer に是正を依頼する。PM は再起動しない（要件は不変）。
build_dev_prompt_redo() {
  local review_notes_path="$1"
  local review_notes_content
  if [ -f "$review_notes_path" ]; then
    review_notes_content=$(cat "$review_notes_path")
  else
    review_notes_content="(review-notes.md が見つかりません)"
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
直前の Reviewer サブエージェントが reject を出したため、Developer の再実装を依頼します。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`

## 進め方

1. developer サブエージェントを起動し、上記 Findings の **Required Action** を順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後 \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- product-manager / project-manager サブエージェントは起動しないこと
  （PM は不要、PjM は次の Reviewer round=2 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
EOF
}

# Stage A' / A'' (Debugger 経由 Developer 再実行): Debugger Gate (#22 Phase 3) で
# 生成された `debugger-notes.md` の Fix Plan を inline 注入して Developer 再起動を依頼する。
# 既存 `build_dev_prompt_redo` の heredoc 形式を踏襲し、review-notes.md は trigger が
# `round2-reject` の場合のみ埋め込む（BLOCKED 経路では review-notes.md は無い / 古いため
# 「(Reviewer 経由ではないため review-notes.md は無し)」と明示）。
#
# Requirements: 3.2, 4.3
build_dev_prompt_redo_with_fix_plan() {
  local review_notes_path="$1"
  local debugger_notes_path="$2"

  local debugger_notes_content
  if [ -f "$debugger_notes_path" ]; then
    debugger_notes_content=$(cat "$debugger_notes_path")
  else
    debugger_notes_content="(debugger-notes.md が見つかりません: $debugger_notes_path)"
  fi

  local review_notes_block
  if [ -n "$review_notes_path" ] && [ -f "$review_notes_path" ]; then
    local review_notes_content
    review_notes_content=$(cat "$review_notes_path")
    review_notes_block=$(cat <<EOF
## Reviewer の reject 理由（review-notes.md より）

\`\`\`markdown
${review_notes_content}
\`\`\`
EOF
)
  else
    review_notes_block=$(cat <<'EOF'
## Reviewer の reject 理由

(Reviewer 経由ではないため review-notes.md は無し / 古い内容のままです。BLOCKED 経路で起動された
Debugger の Fix Plan を起点に是正を進めてください)
EOF
)
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
直前の Debugger サブエージェント（Phase 3 / #22）が \`debugger-notes.md\` に Fix Plan を
出力しました。本 Fix Plan を起点に Developer の再実装を依頼します。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（追加 commit を積んでください。reset / branch 切り替えは禁止）

## 作業ディレクトリ
${SPEC_DIR_REL}/

${review_notes_block}

## Debugger の Fix Plan（debugger-notes.md より）

\`\`\`markdown
${debugger_notes_content}
\`\`\`

## 進め方

1. developer サブエージェントを起動し、Debugger の Fix Plan に記載された **\`修正手順\`** を
   順に実施する
   - 要件（requirements.md）は変更しない（PM への差し戻し相当の事象があれば impl-notes.md の
     「確認事項」に記載するに留める）
   - 設計（design.md / tasks.md）が存在する場合も書き換えない
   - 是正に必要なテストの追加・修正と、対応する実装変更のみを commit する
2. 完了後に Fix Plan の **\`検証方法\`** に従って挙動確認を実行する（テストコマンド / 期待挙動）
3. \`${SPEC_DIR_REL}/impl-notes.md\` に是正内容を 1 セクション追記する（Debugger 経由再実行で
   実施したこと / 残課題があれば記載）

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- product-manager / project-manager サブエージェントは起動しないこと
  （PM は不要、PjM は次の Reviewer round=3 が approve した後にオーケストレーターが起動）
- **PR は作成しないこと**（再 Reviewer の判定を受けます）
- 既存テストを壊さないこと
- \`debugger-notes.md\` は **書き換えないこと**（Debugger の Fix Plan は記録として残す）
- requirements.md / design.md / tasks.md / review-notes.md は書き換えないこと（既存契約）
EOF
}

# Stage B (Reviewer): reviewer サブエージェントを独立 context で起動し、
# review-notes.md を書かせる。差分は reviewer 自身が Bash ツールで取得する設計
# （Issue #92: 大規模差分時の `Argument list too long` 回避のため、prompt から
# inline diff 全文を撤廃した）。prompt は差分サイズに依存せず固定サイズに収まる。
build_reviewer_prompt() {
  local round="$1"
  local prev_result="$2"   # round=2 のみ意味あり、round=1 は "(none)"
  local head_sha
  head_sha=$(git rev-parse HEAD 2>/dev/null || echo "(unknown)")

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
Developer の実装が一段落したため、reviewer サブエージェントによる **独立レビュー**
（round=${round} / 最大 2 round）を実施してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- REPO  : ${REPO}

## 作業ブランチ / spec ディレクトリ
- BRANCH       : ${BRANCH}
- HEAD commit  : ${head_sha}
- BASE_BRANCH  : ${BASE_BRANCH}
- SPEC_DIR_REL : ${SPEC_DIR_REL}
- ROUND        : ${round}
- PREV_RESULT  : ${prev_result}

## 必読ファイル

reviewer サブエージェントは着手前に以下を必ず Read してください:

- \`CLAUDE.md\`（特に「テスト規約」と「禁止事項」）
- \`${SPEC_DIR_REL}/requirements.md\`（EARS 形式の AC、numeric ID）
- \`${SPEC_DIR_REL}/tasks.md\`（\`_Requirements:_\` / \`_Boundary:_\` アノテーション）
- \`${SPEC_DIR_REL}/impl-notes.md\`（Developer のテスト結果含む補足）
- \`${SPEC_DIR_REL}/design.md\`（存在する場合）

## 差分の取得（reviewer が Bash で実行）

prompt には差分本文を埋め込みません（Issue #92: 大差分時の \`Argument list too long\`
回避のため）。reviewer サブエージェントは着手直後に **Bash ツールで** 以下を実行し、
全体把握 → 必要箇所のファイル単位詳細の順で差分を取得してください:

1. 全体把握（変更ファイル一覧と統計）:
   \`\`\`bash
   git diff --stat ${BASE_BRANCH}..HEAD
   git log --oneline ${BASE_BRANCH}..HEAD
   \`\`\`
2. ファイル単位の詳細差分（必要に応じて変更ファイルごとに実行）:
   \`\`\`bash
   git diff ${BASE_BRANCH}..HEAD -- <path>
   \`\`\`
3. 差分が空または取得できなかった場合は、その旨を review-notes.md の Summary に明記し、
   AC カバレッジ判定は requirements.md と既存コードの突き合わせで行ってください。

## 進め方

reviewer サブエージェントを起動し、以下を判定して \`${SPEC_DIR_REL}/review-notes.md\` に
書き出してください（reviewer.md の出力契約に従う）。

- 判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 つに限定
- 最終行は必ず \`RESULT: approve\` または \`RESULT: reject\` で終わること

## 制約
- requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと
- \`git add\` / \`git commit\` / \`git push\` / \`gh\` を実行しないこと（review-notes.md は次の
  Developer または PjM が commit します）
- スタイル / 命名 / lint / フォーマットの観点での reject はしないこと
EOF
}

# Stage C (PjM): 既存 DEV_PROMPT の PjM 起動部分のみを抜き出し。
# Reviewer の approve を受けた後、project-manager サブエージェントが PR を作成する。
# PR 本文の構造は本機能導入前と等価（要件 6.5）。
#
# Issue #96: PjM への PR 作成指示に、解決済み BASE_BRANCH の **実値** を `--base` 引数として
# 明示する肯定的な指示を含める（Req 1.1, 2.1, 2.2）。プレースホルダ `<BASE_BRANCH>` ではなく、
# 当該サイクルで watcher が解決した BASE_BRANCH 値そのもの（`${BASE_BRANCH}` を heredoc で
# 展開済みの文字列）を埋め込む。空値ガード（Req 1.5）は呼び出し元 `_assert_base_branch_resolved`
# で行う。
build_dev_prompt_c() {
  local mode="$1"
  local design_pr_note=""
  if [ "$mode" = "impl-resume" ]; then
    design_pr_note="   - PR 本文に対応する設計 PR 番号を記載（直近の ${BASE_BRANCH} 上の merge commit から \`git log --oneline --merges\` で探す）"
  else
    design_pr_note='   - 設計 PR は走っていないため「関連 PR: なし」と明記すること'
  fi

  cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
Developer の実装と Reviewer の独立レビュー（approve）が完了しました。
project-manager サブエージェントを起動し、最終 PR を作成してください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}

## 作業ブランチ
${BRANCH}（実装 commit が積まれた状態。push 済み）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

PjM サブエージェントは \`gh pr create\` 実行時に **必ず \`--base ${BASE_BRANCH}\`** を
明示してください（GitHub のデフォルト base に依存しないこと）。これは本サイクル開始時に
watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダではありません。
PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で取得した値が
\`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方

1. \`${SPEC_DIR_REL}/review-notes.md\` を **本ブランチに git add / git commit** してから push する
   - commit メッセージ: \`docs(review): add reviewer notes for #${NUMBER}\`
   - 既に commit 済みなら skip
2. project-manager サブエージェントを **implementation モード** で起動
   - title: \`feat(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を明示すること）
   - PR 本文は project-manager.md の「実装 PR 本文テンプレート」に従う
${design_pr_note}
   - PR 本文の「確認事項」セクションに、必要なら review-notes.md の参照リンクを 1 行記載
   - Issue ラベル: claude-picked-up → ready-for-review に付け替え
   - Issue にコメントで実装 PR リンクを投稿

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- Reviewer の approve 判定を覆さないこと（PR 本文に判定結果を逐語転載しない。review-notes.md の
  参照に留める）
- 仕様変更や追加実装はしないこと（PjM はコードを変更しない）
EOF
}

# ─── extract_review_result_token <path> ───
#
# review-notes.md 全文を scan し、`RESULT: approve` または `RESULT: reject` トークンの
# **最後のマッチ**を採用して `approve` / `reject` を stdout に echo する（Issue #63）。
#
# 抽出ルール（Issue #63 Req 1.x）:
#   - 全文 scan（行頭固定マッチではない）
#   - 行頭・行末のバッククォート / bullet (`-` `*`) / blockquote (`>`) / 引用符 / 空白等の
#     decoration を許容（前後の文字を問わない）
#   - 同一行内に末尾プローズが続いても許容（例: `RESULT: approve ...`）
#   - 複数マッチ時は **ファイル順で最後のマッチ** を採用
#   - lowercase の `approve` / `reject` のみ受理（`Approve` / `APPROVE` は不可、Req 1.7）
#   - "approve" / "reject" の前後は word boundary 相当（後続が単語文字なら不採用）
#
# 戻り値:
#   0 = マッチあり（stdout に approve / reject）
#   1 = マッチなし（stdout は空、ファイル無も含む）
extract_review_result_token() {
  local path="$1"
  [ -f "$path" ] || return 1

  # `RESULT:` の後に 1 個以上の空白、続いて `approve` または `reject`、
  # その直後が単語文字でない（または行末）場合のみマッチ。
  # grep -oE で全マッチを行ごとに抽出 → tail -1 で最後の 1 件を採用。
  # set -euo pipefail 下で grep no-match (rc=1) を呑み込むため `|| true` を付与。
  local matches last
  matches=$(grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)' "$path" 2>/dev/null || true)
  [ -n "$matches" ] || return 1
  last=$(printf '%s\n' "$matches" | tail -n 1)

  # 末尾の境界文字を取り除いて approve / reject だけを残す。
  case "$last" in
    *approve*) echo "approve"; return 0 ;;
    *reject*)  echo "reject";  return 0 ;;
  esac
  return 1
}

# ─── parse_review_result <path> ───
#
# review-notes.md から RESULT 行（最後に出現するもの）と Findings の Category / Target を
# 抽出する。RESULT 行抽出は `extract_review_result_token` に委譲し、装飾・インライン記述
# (Issue #63) に耐性を持つ。
# stdout に TSV 1 行で出力: <result>\t<categories>\t<target_ids>
#
# - result      ∈ {approve, reject}
# - categories  = カンマ区切り（reject 時のみ。approve 時は空文字）
# - target_ids  = カンマ区切り requirement ID または `boundary:<component>` 形式
#
# 戻り値:
#   0 = 抽出成功
#   2 = ファイル無 / RESULT トークン欠落 / 値不正
parse_review_result() {
  local path="$1"
  if [ ! -f "$path" ]; then
    return 2
  fi

  local result
  if ! result=$(extract_review_result_token "$path"); then
    return 2
  fi
  case "$result" in
    approve|reject) ;;
    *) return 2 ;;
  esac

  local categories=""
  local target_ids=""
  if [ "$result" = "reject" ]; then
    # Findings ブロックの "**Category**: ..." 行と "**Target**: ..." 行を抽出。
    # Findings は markdown bullet なので、行頭の "- " も含めて許容する。
    categories=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Category\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Category\*\*:[[:space:]]*//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
    target_ids=$(grep -E '^[[:space:]]*-[[:space:]]+\*\*Target\*\*:' "$path" \
                   | sed -E 's/^[[:space:]]*-[[:space:]]+\*\*Target\*\*:[[:space:]]*//' \
                   | sed -E 's/（.*$//' \
                   | sed -E 's/[[:space:]]+$//' \
                   | paste -sd, - || true)
  fi

  printf '%s\t%s\t%s\n' "$result" "$categories" "$target_ids"
  return 0
}

# ─── run_reviewer_stage <round> ───
#
# Reviewer サブエージェントを 1 回起動し、review-notes.md の最終 RESULT 行を抽出して
# 戻り値で結果を呼び出し元に返す。
#
# 入力:
#   $1 = round (1 | 2)
#   環境変数: NUMBER, BRANCH, SPEC_DIR_REL, LOG, REPO_DIR
# 副作用:
#   - $LOG に Reviewer 起動ログ（model / max-turns / 結果）を append
#   - $REPO_DIR/$SPEC_DIR_REL/review-notes.md が Reviewer によって作成 / 上書き
# 戻り値:
#   0 = approve
#   1 = reject
#   2 = 異常終了（claude crash / parse 失敗 / RESULT 行欠落）
run_reviewer_stage() {
  local round="$1"
  local prev_result="(none)"

  # round=2 の場合、直前 review-notes.md の RESULT 行を Reviewer に伝える。
  # Issue #63: 装飾・インライン記述に耐性のある extract_review_result_token に委譲。
  # トークンが見つからない場合は従来どおり "(none)" を維持して prompt 互換性を保つ。
  local notes_path="$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
  if [ "$round" = "2" ] && [ -f "$notes_path" ]; then
    local _prev_token
    if _prev_token=$(extract_review_result_token "$notes_path"); then
      prev_result="RESULT: $_prev_token"
    fi
  fi

  rv_log "round=$round start (model=$REVIEWER_MODEL, max-turns=$REVIEWER_MAX_TURNS)" >> "$LOG"

  local prompt
  prompt=$(build_reviewer_prompt "$round" "$prev_result")

  echo "--- Reviewer 実行 (round=$round) ---" >> "$LOG"
  # Issue #66: Quota-Aware Watcher 経由で claude を起動。99 を受領した場合は
  # quota 超過検出として呼び出し側（run_impl_pipeline）に伝搬する。
  local _qa_reset_file_rv _qa_rc_rv=0 _qa_ts_rv _qa_stage_label_rv
  _qa_ts_rv=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_rv="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-reviewer-r${round}-${_qa_ts_rv}"
  _qa_stage_label_rv="Reviewer-r${round}"
  qa_run_claude_stage "$_qa_stage_label_rv" "$_qa_reset_file_rv" -- \
    claude \
      --print "$prompt" \
      --model "$REVIEWER_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$REVIEWER_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1 || _qa_rc_rv=$?
  case "$_qa_rc_rv" in
    0)
      rm -f "$_qa_reset_file_rv"
      ;;
    99)
      local _qa_epoch_rv
      _qa_epoch_rv=$(cat "$_qa_reset_file_rv")
      qa_handle_quota_exceeded "$NUMBER" "$_qa_stage_label_rv" "$_qa_epoch_rv"
      rm -f "$_qa_reset_file_rv"
      rv_log "round=$round result=quota-exceeded → needs-quota-wait" >> "$LOG"
      return 99
      ;;
    *)
      rm -f "$_qa_reset_file_rv"
      rv_log "round=$round result=error reason=claude-exit-nonzero" >> "$LOG"
      return 2
      ;;
  esac

  # review-notes.md を parse
  local parsed
  if ! parsed=$(parse_review_result "$notes_path"); then
    rv_log "round=$round result=error reason=parse-failed" >> "$LOG"
    return 2
  fi

  local result categories targets
  result=$(echo "$parsed" | cut -f1)
  categories=$(echo "$parsed" | cut -f2)
  targets=$(echo "$parsed" | cut -f3)

  case "$result" in
    approve)
      rv_log "round=$round result=approve verified=$targets" >> "$LOG"
      return 0
      ;;
    reject)
      rv_log "round=$round result=reject categories=$categories targets=$targets" >> "$LOG"
      return 1
      ;;
    *)
      rv_log "round=$round result=error reason=unknown-result" >> "$LOG"
      return 2
      ;;
  esac
}

# ─── Stage 完了直後の push 状態 verify ヘルパー (Issue #106) ───
#
# Stage A / A' / B 完了直後に「ローカル commit が origin に到達しているか」を verify し、
# 未 push を検出したら自動 push を 1 回だけリトライする。リトライ成功時は WARN ログ +
# Issue コメントで観測可能性を維持し、リトライ失敗時は mark_issue_failed 経路で
# claude-failed 化する。
#
# 引数:
#   $1 = stage 識別子（mark_issue_failed に渡す identifier。例: stageA-push-missing
#        / stageA-prime-push-missing / stageB-push-missing。NFR 2.1 / Req 4.4 と整合）
#   $2 = 対象 branch（典型的には $BRANCH）
#   $3 = stage label（ログ可読性のための短い文字列。例: "Stage A" / "Stage A'" / "Stage B"）
#
# 戻り値:
#   0 = ahead == 0（通常成功 / Req 1.3, 2.3, 5.1）、または自動 push リトライ成功
#       （Req 4.2, 4.3）
#   1 = 自動 push リトライ失敗 → mark_issue_failed 既発射、呼び出し側は伝搬 return 1 する
#       （Req 4.4, 4.5）
#
# 副作用:
#   - $LOG に検出経路 / ahead 数 / リトライ結果を WARN 行で記録（NFR 2.1, Req 1.2, 2.2, 3.2）
#   - リトライ成功時に gh issue comment で復旧通知を投稿（Req 4.3, NFR 2.2）
#   - リトライ失敗時に mark_issue_failed "$stage_id" で claude-failed 化（Req 4.4, NFR 2.3）
#
# 設計判断:
#   - `git rev-list --count @{u}..HEAD` で ahead 数を測る。本関数は cwd が slot worktree
#     ($REPO_DIR が指す path) であることを前提とする（_slot_run_issue が cd 済）。
#   - timeout は 30 秒上限（NFR 1.2）。本体 git クエリと push リトライそれぞれに timeout を
#     かける。`command -v timeout` で GNU coreutils の有無を判定し、無い環境
#     （BSD / macOS 標準）では timeout なしで実行する（既存 cron 互換性のため）。
#   - 結果不確定（git rev-list が timeout / 失敗）は「未 push と同等扱い」で安全側に倒す
#     （Req 1.4）。リトライを試み、失敗なら claude-failed 化する。
#   - push オプションは plain `git push origin <branch>` の fast-forward のみ。
#     `--force-with-lease` 等の force 系は **使わない**（既稼働 cron 環境で意図せぬ
#     history 書き換えを防止するため。Open Question 3 の design 確定）。
#   - Stage B の review-notes.md 識別ログ粒度（Req 3.4）は呼び出し側で stage label を
#     "Stage B" と明示し、本関数のログ行に stage label を含めることで観測可能性を担保。
verify_pushed_or_retry() {
  local stage_id="$1"
  local branch="$2"
  local stage_label="$3"

  # ── ahead 数を測定（安全側ロジック付き）──
  # 結果が空 / 取得失敗時は ahead=unknown とし、安全側で push リトライへ進む（Req 1.4）。
  local ahead_count="" rev_rc=0
  local _git_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _git_timeout=(timeout 30)
  fi
  ahead_count=$("${_git_timeout[@]}" git rev-list --count "@{u}..HEAD" 2>/dev/null) || rev_rc=$?
  # 数値以外（空文字 / エラー）は unknown 扱い
  if ! [[ "$ahead_count" =~ ^[0-9]+$ ]]; then
    ahead_count="unknown"
  fi

  # ── 通常成功ケース: ahead == 0（Req 1.3 / 2.3 / 3.3 / 5.1）──
  if [ "$ahead_count" = "0" ]; then
    return 0
  fi

  # ── ahead > 0 または unknown: WARN ログ → 自動 push リトライ 1 回（Req 4.1, 4.6）──
  qa_warn "${stage_label} push-state verify: ahead=${ahead_count} (rev_rc=${rev_rc}) issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
  echo "[$(date '+%F %T')] ${stage_label} ahead=${ahead_count} detected → auto-push retry 1/1 (Req 4.1, Issue #106)" >> "$LOG"

  local push_rc=0
  local push_stderr_tmp
  push_stderr_tmp=$(mktemp -t verify-push-XXXXXX.err 2>/dev/null || echo "")
  if [ -n "$push_stderr_tmp" ]; then
    "${_git_timeout[@]}" git push origin "$branch" 2>"$push_stderr_tmp" || push_rc=$?
  else
    "${_git_timeout[@]}" git push origin "$branch" || push_rc=$?
  fi

  if [ "$push_rc" -eq 0 ]; then
    # ── リトライ成功（Req 4.2, 4.3）──
    qa_warn "${stage_label} auto-push retry SUCCESS: ahead=${ahead_count} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id}"
    echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ成功 ahead=${ahead_count} → 継続" >> "$LOG"

    # Issue コメント投稿（NFR 2.2: Issue 番号 / stage 識別子 / branch / commit 数を含める）
    local comment_body
    comment_body="⚠️ Issue #${NUMBER:-?} の ${stage_label} 完了直後に未 push commit を検出し、自動 push リトライで復旧しました。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 復旧 commit 数: ${ahead_count}

サブエージェント（Developer / Reviewer）の push 漏れ等が根本原因の可能性があります。詳細は watcher ログ \`${LOG}\` を確認してください。"
    gh issue comment "${NUMBER}" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1 || true

    if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi
    return 0
  fi

  # ── リトライ失敗（Req 4.4, 4.5, NFR 2.3）──
  local push_stderr_tail=""
  if [ -n "$push_stderr_tmp" ] && [ -f "$push_stderr_tmp" ]; then
    push_stderr_tail=$(tail -c 1500 "$push_stderr_tmp" 2>/dev/null || true)
  fi
  qa_warn "${stage_label} auto-push retry FAILED: ahead=${ahead_count} push_rc=${push_rc} issue=#${NUMBER:-?} branch=${branch} stage_id=${stage_id} stderr_tail='${push_stderr_tail//$'\n'/ }'"
  echo "[$(date '+%F %T')] ${stage_label} 自動 push リトライ失敗 push_rc=${push_rc} → claude-failed (stage_id=${stage_id})" >> "$LOG"

  local fail_body
  fail_body="${stage_label} 完了直後に未 push commit（ahead=${ahead_count}）を検出し、自動 push リトライを 1 回試みましたが失敗しました（push exit code: ${push_rc}）。

- 対象 stage : \`${stage_id}\`
- 対象 branch: \`${branch}\`
- 未 push commit 数: ${ahead_count}

### 次の手順

1. ローカルで \`git fetch origin\` 後、当該 worktree の HEAD と origin/${branch} の差分を確認
2. 必要に応じ手動で \`git push origin ${branch}\` を実行
3. 問題が解消したら \`claude-failed\` ラベルを外して再 pickup させる"
  if [ -n "$push_stderr_tail" ]; then
    fail_body="${fail_body}

### git push stderr (tail)

\`\`\`
${push_stderr_tail}
\`\`\`"
  fi

  if [ -n "$push_stderr_tmp" ]; then rm -f "$push_stderr_tmp" 2>/dev/null || true; fi

  mark_issue_failed "$stage_id" "$fail_body"
  return 1
}

# ─── Stage C 完了直後の PR 実在 verify ヘルパー (Issue #108 / #110) ───
#
# Stage C の Claude 実行が return code 0 で終了した直後に、対象 branch を head と
# する impl PR が GitHub 側で参照可能か `gh pr view --head` で verify する。GitHub の
# eventual consistency により PR 作成直後数十秒は当該クエリが空応答を返すケースが
# 観測されているため、主経路は最大 6 回までリトライ可能とし、整合性遅延に起因する
# false negative を吸収する。さらに主経路が全試行で空応答 / 失敗で終わった場合は、
# 主経路と独立な edge cache 経路である List Pulls API（`gh api repos/.../pulls?head=...`）
# に対して 1 度だけ fallback 探索を試みる（Issue #110: KeyNest #32 で観測された
# 73 秒経過後の主経路空応答に対する救済路）。
#
# 引数:
#   $1 = 対象 branch（典型的には $BRANCH）
#   $2 = Issue 番号（ログ識別用。典型的には $NUMBER）
#
# 戻り値:
#   0 = 主経路 / 代替経路のいずれかで PR URL が取得できた（PR URL を stdout に出力）
#   1 = 主経路全試行 + 代替経路の 1 ターンを全て使い切っても PR URL を取得できなかった
#
# 副作用:
#   - 各主経路試行の結果（成功 / 空応答 / 非 0 / タイムアウト）を `$LOG` に記録（NFR 2.1）
#   - 代替経路の呼び出し開始・結果を `$LOG` に記録（Req 3.3 / 3.4 / NFR 2.2）
#   - 1 回目即時成功時は追加ログを出さない（Req 4.1 / 4.6 / NFR 1.1: 通常成功ケースの
#     外形挙動を本変更前と同一に保つ）
#
# 設計判断:
#   - 主経路試行回数 6 / 待機 (0, 5, 10, 20, 40, 60) 秒 / 1 試行 timeout 15 秒
#     （Req 1.1 / 1.2 / 1.3 / 1.6 / NFR 1.2 / 1.3）。sleep 合計 135 秒で 73 秒の edge
#     cache lag を余裕を持って吸収できる。
#   - 待機は `${STAGEC_VERIFY_SLEEP_CMD:-sleep}` 経由で実行する。テストで `:` 等の
#     no-op コマンドを注入することで実時間待機なしに retry 系列を再現できる
#     （Req 5.8）。env var 名は Issue #108 の既存 fixture と互換。
#   - 主経路リトライ系列は `${STAGEC_VERIFY_DELAYS:-}` （スペース区切り秒数）と
#     `${STAGEC_VERIFY_MAX_ATTEMPTS:-}` で override 可能（Req 4.7 / NFR 3.4）。
#     未指定時のデフォルトで Req 1.1 / 1.2 / NFR 1.2 を満たす。既存 env var 名
#     （REPO / REPO_DIR / LOG / TRIAGE_MODEL / DEV_MODEL / STAGEC_VERIFY_SLEEP_CMD 等）
#     とは衝突しない新規 env var を採用している。
#   - `command -v timeout` で timeout コマンドの存在を確認し、無い環境では timeout
#     なしで gh を実行する（既存 verify_pushed_or_retry と同方針 / 既存 cron
#     互換性のため）。1 試行・代替経路ともに `${STAGEC_VERIFY_TIMEOUT_SECS:-15}` 秒
#     上限（Req 1.6 / 2.5 / NFR 1.3 / 1.4）。
#   - 代替経路は List Pulls API を直接叩く `gh api repos/{owner}/{repo}/pulls?head={owner}:BRANCH&state=open`
#     パターン。`{owner}` は `$REPO`（owner/repo 形式）から prefix を抽出。
#     edge cache の独立性を期待する経路設計のため、代替経路自体のリトライは
#     行わない（Req 2.6）。
#   - 主経路のいずれかで PR が見つかった場合、代替経路は呼び出さない（Req 2.7）。
#   - 成功時の "Stage C 完了 / PR 作成済み" 相当ログは呼び出し側に残し、本関数は
#     PR URL の取得と試行ログのみに責務を絞る。これにより Req 4.1 の「1 回目で
#     PR が確認できたとき本変更前と同じ成功ログ」を呼び出し側 echo で保証する。
verify_stagec_pr_or_retry() {
  local branch="$1"
  local issue_number="$2"

  # 試行間 sleep の注入点（テスト時に `:` 等で no-op 化できる / Req 5.8）
  local _sleep_cmd="${STAGEC_VERIFY_SLEEP_CMD:-sleep}"

  # 1 試行 / 代替経路あたりの timeout 上限秒数（Req 1.6 / 2.5 / NFR 1.3 / 1.4）
  local _timeout_secs="${STAGEC_VERIFY_TIMEOUT_SECS:-15}"

  # timeout コマンドの有無で gh 呼び出しを切り替える（既存 verify_pushed_or_retry と同方針）
  local _gh_timeout=()
  if command -v timeout >/dev/null 2>&1; then
    _gh_timeout=(timeout "$_timeout_secs")
  fi

  # 待機スケジュール（即時 / 5 / 10 / 20 / 40 / 60 秒。sleep 合計 135 秒 / Req 1.1 / NFR 1.2）
  # STAGEC_VERIFY_DELAYS env で override 可能（Req 4.7 / NFR 3.4）
  local _delays=()
  if [ -n "${STAGEC_VERIFY_DELAYS:-}" ]; then
    # shellcheck disable=SC2206  # 意図的に空白で word split する
    _delays=(${STAGEC_VERIFY_DELAYS})
  else
    _delays=(0 5 10 20 40 60)
  fi
  local _max_attempts="${STAGEC_VERIFY_MAX_ATTEMPTS:-${#_delays[@]}}"

  local attempt=1
  local pr_url="" rc=0
  local last_outcome="empty"
  while [ "$attempt" -le "$_max_attempts" ]; do
    local _delay="${_delays[$((attempt - 1))]:-0}"
    if [ "$_delay" -gt 0 ]; then
      "$_sleep_cmd" "$_delay"
    fi

    pr_url=""
    rc=0
    pr_url=$("${_gh_timeout[@]}" gh pr view --repo "$REPO" --head "$branch" \
              --json url --jq '.url' 2>/dev/null) || rc=$?

    if [ "$rc" -eq 0 ] && [ -n "$pr_url" ]; then
      # 1 回目以降の試行回数判定: N >= 2 の場合のみ「リトライで成功」ログを残す
      # （Req 3.2 / Req 4.1 / 4.6 / NFR 1.1 を満たすため 1 回目は無 log で本変更前と外形互換）
      if [ "$attempt" -gt 1 ]; then
        echo "[$(date '+%F %T')] stageC PR verify SUCCESS attempt=${attempt}/${_max_attempts} issue=#${issue_number} branch=${branch} pr_url=${pr_url}" >> "$LOG"
      fi
      printf '%s\n' "$pr_url"
      return 0
    fi

    # 失敗種別を分類してログに残す（NFR 2.1: 試行結果を事後識別可能にする）
    local outcome=""
    if [ "$rc" -eq 124 ]; then
      outcome="timeout"
    elif [ "$rc" -ne 0 ]; then
      outcome="exit=${rc}"
    else
      outcome="empty"
    fi
    last_outcome="$outcome"
    # Req 3.1: 2 回目以降の進捗を 1 行で残す。1 回目失敗も Req 3.5「全失敗時の原因
    # 特定」のため残しておく（最終失敗時にまとめて参照できるよう attempt=1 から記録）
    echo "[$(date '+%F %T')] stageC PR verify attempt=${attempt}/${_max_attempts} outcome=${outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

    attempt=$((attempt + 1))
  done

  # ─── 主経路全試行失敗 → 代替経路（List Pulls API）への 1 ターン fallback ───
  # Req 2.1 / 2.6: 代替経路は主経路と独立に 1 回だけ呼び出す（リトライしない）。
  # Req 2.5 / NFR 1.4: 代替経路にも timeout 上限を適用する。
  local _owner="${REPO%%/*}"
  echo "[$(date '+%F %T')] stageC PR verify fallback start (List Pulls API) issue=#${issue_number} branch=${branch} owner=${_owner}" >> "$LOG"
  local _fb_url="" _fb_rc=0 _fb_outcome=""
  _fb_url=$("${_gh_timeout[@]}" gh api "repos/${REPO}/pulls?head=${_owner}:${branch}&state=open" \
            --jq '.[0].html_url // empty' 2>/dev/null) || _fb_rc=$?
  if [ "$_fb_rc" -eq 0 ] && [ -n "$_fb_url" ]; then
    # Req 2.2 / 3.4: 代替経路で救済（主経路全失敗 / 代替経路で成功）
    echo "[$(date '+%F %T')] stageC PR verify fallback SUCCESS rescued issue=#${issue_number} branch=${branch} pr_url=${_fb_url} primary_attempts=${_max_attempts}" >> "$LOG"
    printf '%s\n' "$_fb_url"
    return 0
  fi
  # Req 2.3 / 2.4 / NFR 2.2: 代替経路の結果分類（empty / timeout / exit=N / 認証失敗等）を残す
  if [ "$_fb_rc" -eq 124 ]; then
    _fb_outcome="timeout"
  elif [ "$_fb_rc" -ne 0 ]; then
    _fb_outcome="exit=${_fb_rc}"
  else
    _fb_outcome="empty"
  fi
  echo "[$(date '+%F %T')] stageC PR verify fallback FAILED outcome=${_fb_outcome} issue=#${issue_number} branch=${branch}" >> "$LOG"

  # Req 3.5: 主経路試行回数 / 最終 primary 失敗要因 / 代替経路最終結果を 1 行で残す
  echo "[$(date '+%F %T')] stageC PR verify FAILED after ${_max_attempts} attempts + fallback issue=#${issue_number} branch=${branch} last_primary_outcome=${last_outcome} fallback_outcome=${_fb_outcome}" >> "$LOG"
  return 1
}

# ─── failure 共通遷移ヘルパー ───
#
# Stage 失敗時の claude-failed 遷移を一元化。引数で原因種別と Issue コメント追加情報を受け取る。
# - $1 = stage 識別子（"stageA" / "stageA-redo" / "stageB" / "stageC" / "reviewer-error" / "reviewer-reject2"）
# - $2 = Issue コメントに追加する補足（reject 理由など。空文字可）
mark_issue_failed() {
  local stage="$1"
  local extra_body="$2"

  # Issue #52: 通常経路では Stage A 開始時点で Issue は claude-picked-up のみ持つ
  # （Slot Runner が Triage 通過時に claude-claimed → claude-picked-up に付け替え済）。
  # 想定外シーケンス（design ルート Stage C 失敗で本ヘルパへ流入する等）でも残置を防ぐ
  # ため、両系統除去で安全側に倒す。gh CLI は未付与ラベルの除去を no-op として扱う。
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" || true

  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / モード: $MODE / 失敗 stage: ${stage}）。

ログ: \`$LOG\`"
  if [ -n "$extra_body" ]; then
    body="${body}

${extra_body}"
  fi
  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # mark_issue_failed は run_impl_pipeline 内の各 stage 失敗から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"

  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" || true
}

# Partial Status Gate (#148) のラベル付け替え + コメント投稿ヘルパー。
# `mark_issue_failed` の `claude-failed` 専用設計と分離し、`needs-decisions` 経路の責務を
# 1 関数に集約する。LABEL_FAILED は **付与しない**（NFR 1.3 / 既存ラベル併存禁止）。
#
# Args:
#   $1 = status_code   (NFR 2.1 / grep 可能ログ用。本関数は body 組立済前提のため値だけ受領)
#   $2 = comment_body  (build_partial_escalation_comment の出力)
# Return: 0 always（best-effort、既存 mark_issue_failed と同方針）
# 副作用:
#   1. claude-claimed / claude-picked-up を除去
#   2. needs-decisions を付与（1 コマンド原子的に発行）
#   3. escalation コメントを 1 件投稿
# Requirements: 3.3, 3.4, 3.6, NFR 1.3
mark_issue_needs_decisions() {
  local status_code="$1"
  local comment_body="$2"

  # ラベル付け替え（gh CLI は未付与ラベルの除去を no-op として扱う / 既存
  # qa_handle_quota_exceeded / mark_issue_failed と同方針で 1 コマンド原子的に発行）。
  # LABEL_FAILED (`claude-failed`) は **付与しない**（NFR 1.3 / Req 3.3, 3.4）。
  if ! gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    # best-effort: 失敗してもコメント投稿は試行（既存 quota / failed 経路と同方針）
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN ラベル付け替え失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi

  # escalation コメント投稿（best-effort）
  if ! gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] [$REPO] partial-status: WARN コメント投稿失敗 issue=#${NUMBER} status=${status_code}" >&2
  fi
  return 0
}

# Partial Status Gate (#148) の coordinator。Stage A 完了直後の各経路から
# 1 行 `handle_partial_status || _rc=$?; case ...` の形で呼ばれる。
#
# 入力 (環境変数経由):
#   NUMBER / BRANCH / REPO / REPO_DIR / SPEC_DIR_REL / LOG / BASE_BRANCH
# 出力:
#   stdout なし（log のみ）
# Return:
#   0  = continue（既存フロー継続。status 行不在 or `complete`）
#   10 = partial 検出済（呼出側は run_impl_pipeline から return 0 で抜けて Reviewer skip）
#   1  = 不正 status / parse 失敗（mark_issue_failed 実行済。呼出側は return 1）
#
# 副作用:
#   - partial 検出時: `mark_issue_needs_decisions` 経由でラベル付け替え + コメント投稿
#     + grep 可能ログ 1 行（NFR 2.1）
#   - 不正値時: `mark_issue_failed` 実行（NFR 3.1） + grep 可能ログ
#   - continue 時: 副作用なし（既存挙動と外形等価 / NFR 1.1, 1.4）
#
# 不変条件:
#   - 既存 `LABEL_NEEDS_DECISIONS` 以外のラベルを新規生成しない（Req 3.3, 3.4 / NFR 1.3）
#   - 戻り値 10 は run_impl_pipeline 既存 return code 0/1 と衝突しない（quota 99 とも区別）
#
# Requirements: 1.3, 3.1, 3.2, 3.5, NFR 1.1, NFR 1.4, NFR 2.1, NFR 3.1, NFR 3.2
handle_partial_status() {
  local impl_notes="$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"
  local status_code rc=0
  status_code=$(detect_partial_status "$impl_notes") || rc=$?
  case "$rc" in
    1|2)
      # STATUS 行不在 or ファイル不在 → continue（NFR 1.1 / NFR 3.2）
      # 既存挙動と外形完全等価（partial gate 導入前と同じ Stage B 起動経路へ）
      return 0
      ;;
    0)
      case "$status_code" in
        complete)
          # 明示的 complete = continue（NFR 1.4）
          return 0
          ;;
        partial_blocked|partial_overrun)
          # ── partial 検出: needs-decisions エスカレーション ──
          # 1. grep 可能ログ（NFR 2.1）
          echo "[$(date '+%F %T')] [$REPO] partial-status: detected issue=#${NUMBER} status=${status_code} branch=${BRANCH}" | tee -a "$LOG"
          # 2. コメント本文組立
          local body
          body=$(build_partial_escalation_comment \
            "$status_code" \
            "$impl_notes" \
            "$REPO_DIR/$SPEC_DIR_REL/tasks.md" \
            "$BRANCH")
          # 3. ラベル付け替え + コメント投稿（best-effort）
          mark_issue_needs_decisions "$status_code" "$body"
          # 4. partial 検出を呼出側に伝搬（return 10 = Reviewer skip + run_impl_pipeline 正常終了）
          return 10
          ;;
        *)
          # ── 不正 status code（NFR 3.1） ──
          echo "[$(date '+%F %T')] [$REPO] partial-status: invalid issue=#${NUMBER} status='${status_code}'" | tee -a "$LOG"
          mark_issue_failed "partial-status-invalid" \
            "Developer 出力の \`STATUS:\` 行が \`${status_code}\` で、契約 (\`complete\` / \`partial_blocked\` / \`partial_overrun\`) のいずれにも該当しません。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    *)
      # 想定外の rc（防御的）: detect_partial_status は 0/1/2 しか返さない契約だが、
      # 未来の規約変更に備えて safe-fallback で continue を選択（既存挙動を壊さない /
      # NFR 1.1）。
      echo "[$(date '+%F %T')] [$REPO] partial-status: WARN detect_partial_status unexpected rc=$rc → continue (safe-fallback)" >&2
      return 0
      ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage A Verify の失敗ハンドラ / 統合ランナー（_sav_handle_failure / stage_a_verify_run）
#   — modules/stage-a-verify.sh へ切り出し済み（#181 Part 3）。
#   元はここ（mark_issue_failed 定義後の位置）に置かれていたが、Region 1 と共に
#   stage-a-verify.sh へ統合した。call site（run_impl_pipeline 内の stage_a_verify_run）は
#   本体の従来位置に残す。cross-module 呼び出し（_sav_handle_failure → mark_issue_failed）は
#   全モジュールが run_impl_pipeline 実行前に source されるため挙動不変。
# ─────────────────────────────────────────────────────────────────────────────

# ─── run_impl_pipeline ───
#
# impl / impl-resume モードの Stage 状態機械を実装する。
#
#   START → Stage A → Stage B(round=1)
#                    ├─ approve → Stage C → TERMINAL_OK
#                    ├─ reject  → Stage A' → Stage B(round=2)
#                    │                       ├─ approve → Stage C → TERMINAL_OK
#                    │                       ├─ reject  → TERMINAL_FAILED (with Issue comment)
#                    │                       └─ error   → TERMINAL_FAILED (with $LOG path)
#                    └─ error   → TERMINAL_FAILED (with $LOG path)
#
#   Stage A / A' / C の非 0 exit は既存 Developer 失敗時遷移と同等メッセージ。
#
# Stage Checkpoint Resume (#68, デフォルト有効 / #112): `STAGE_CHECKPOINT_ENABLED=true`
#   （既定）のときに、関数冒頭で stage_checkpoint_resolve_resume_point を呼び
#   START_STAGE を取得する。START_STAGE ∈ {A, B, C, TERMINAL_OK, TERMINAL_FAILED}。
#     - TERMINAL_OK     → 既存 impl PR 検出。何もせず return 0（自動進行停止、ラベル不変）
#     - TERMINAL_FAILED → round=2 reject 残骸検出。claude-failed 化して return 1
#     - A               → 通常通り Stage A から実行（fallback / no-checkpoint / INCONSISTENT）
#     - B               → Stage A をスキップ（既存 impl-notes.md を再利用）
#     - C               → Stage A / Stage B をスキップ（既存 impl-notes / approve を再利用）
#   `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）では resolve は呼ばず、本関数は本機能
#   導入前と 1 行も挙動を変えない（NFR 1.1）。
#
# stage-a-verify gate (#125, デフォルト有効): `STAGE_A_VERIFY_ENABLED=true`（既定）の
#   ときに、Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク
#   （build/test/lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
#   （START_STAGE=B|C）でも本ブロックを通すため、Stage Checkpoint resume 経由のフロー
#   でも gate が機能する。`STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run
#   が即 return 0 して本機能導入前と user-observable に完全同一の挙動になる
#   （Req 4.1 / NFR 1.1）。失敗時は round=1 で Developer 差し戻し（return 1）、
#   round=2 で claude-failed escalate（return 1、内部で mark_issue_failed 済）。
#
# 入力 (環境変数経由): NUMBER, TITLE, BODY, URL, BRANCH, MODE, SPEC_DIR_REL, LOG, REPO,
#                      DEV_MODEL, DEV_MAX_TURNS, REVIEWER_MODEL, REVIEWER_MAX_TURNS,
#                      STAGE_CHECKPOINT_ENABLED (#68, default=true since #112),
#                      STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT /
#                      STAGE_A_VERIFY_COMMAND (#125)
# 戻り値:
#   0 = pipeline 成功（Stage C も成功 / PR 作成済み）または TERMINAL_OK 相当の停止
#   1 = Stage A / A' / B / B' / C / stage-a-verify いずれかで失敗 → claude-failed 既に付与済み
run_impl_pipeline() {
  local prompt_a prompt_redo prompt_c
  local rev_rc
  # START_STAGE: STAGE_CHECKPOINT_ENABLED=true（既定）時は resolve_resume_point が
  # 値を上書きする。`=false` 明示時は "A" 固定で本機能導入前と完全一致
  # （Req 3.2 / NFR 1.1）。
  local START_STAGE="A"

  # Stage Checkpoint Resume (#68): START_STAGE を resolve_resume_point で上書き。
  # `STAGE_CHECKPOINT_ENABLED=false` 明示時は本ブロックを skip し START_STAGE="A"
  # のままで、本機能導入前と完全等価な挙動になる（NFR 1.1）。
  # `:-true` で `unset` も既定有効として扱う（#112 でデフォルト反転）。
  if [ "${STAGE_CHECKPOINT_ENABLED:-true}" = "true" ]; then
    if ! stage_checkpoint_resolve_resume_point; then
      sc_warn "resolve 異常 → Stage A 起点で安全フォールバック" >> "$LOG"
      START_STAGE="A"
    fi
    case "$START_STAGE" in
      TERMINAL_OK)
        sc_log "既存 impl PR 検出 → Stage C 再実行を停止 (Req 2.6)" >> "$LOG"
        echo "✅ #$NUMBER: 既存 impl PR を検出（Stage Checkpoint）→ 自動進行を停止" | tee -a "$LOG"
        return 0
        ;;
      TERMINAL_FAILED)
        sc_log "round=2 reject 残骸検出 → claude-failed 化 (Req 2.5)" >> "$LOG"
        echo "❌ #$NUMBER: Reviewer round=2 reject の checkpoint 残骸検出 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "stage-checkpoint-terminal-failed" \
          "Reviewer round=2 reject の checkpoint が当該 branch に残っているため、自動進行を停止します。\`${SPEC_DIR_REL}/review-notes.md\` の RESULT 行を確認し、人間判断で対応してください。"
        return 1
        ;;
    esac
  fi

  # ── Stage A: PM + Developer（impl-resume では PM スキップ / Stage Checkpoint resume 時は skip 可）──
  #
  # Phase 2 (#21): `PER_TASK_LOOP_ENABLED=true` のときは Stage A の実体を
  # `run_per_task_loop`（task 単位 fresh Implementer + fresh Reviewer のループ）に
  # 置き換える Strategy 分岐を挿入する。`PER_TASK_LOOP_ENABLED` 未指定 / `=true` 以外
  # では従来の単一 Developer 起動経路に流れ、本機能導入前と外形挙動は完全一致する
  # （Req 1.1 / NFR 1.1）。loop 完了後の verify_pushed_or_retry / stage-a-verify /
  # Stage B / Stage C は分岐の外で従来通り実行される（NFR 1.4）。
  case "$START_STAGE" in
    A)
      # per-task loop は `tasks.md` が存在する場合にのみ起動する。`PER_TASK_LOOP_ENABLED=true`
      # でも tasks.md 不在（Architect 不要 triage を通過した Issue 等）の場合は、Issue を
      # 失敗扱いせず従来の単一 Developer 経路（else ブランチ）へフォールバックする（#166 /
      # Req 1.1, 1.2, 3.1）。判定を if 条件に畳むことで、従来 Stage A ブロックを重複させずに
      # 到達させる（NFR 2.1: per-task ループ dispatcher 本体は変更しない）。
      local _pt_tasks_md="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
      local _pt_loop_enabled=false
      if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then
        if [ -f "$_pt_tasks_md" ]; then
          _pt_loop_enabled=true
        else
          # AC5: フォールバック発生を判別可能なログ行を slot ログに出力（claude-failed は付けない）
          echo "--- per-task: tasks.md 不在 → Stage A fallback（$_pt_tasks_md）---" | tee -a "$LOG"
        fi
      fi
      if [ "$_pt_loop_enabled" = "true" ]; then
        echo "--- Stage A 実行（$MODE / per-task loop / PER_TASK_LOOP_ENABLED=true）---" >> "$LOG"
        if ! run_per_task_loop; then
          # run_per_task_loop 内で claude-failed 付与済 / 既に Issue コメント済。
          return 1
        fi
        # ── per-task 全 task 完了ゲート (#194) ──
        # `run_per_task_loop` の `return 0` は「全 task 消化成功」と「quota 超過等による
        # 中間早期 return」の双方を含むため、戻り値 0 だけでは全 task 完了を保証できない。
        # ここで tasks.md を再読込し、必須 task（deferrable `- [ ]*` を除く `- [ ]`）が
        # 1 件でも残っていれば Reviewer / PR / ready-for-review へ進めず、未完了状態として
        # `return 0`（resumable）で抜ける。後続 tick の Resume Processor が残り task を消化する。
        # mark_issue_failed は呼ばない（失敗ではなく中断のため。quota 早期 return と同じ扱い）。
        # 本ゲートは `_pt_loop_enabled=true` 分岐内にのみ存在し、PER_TASK_LOOP 無効時の
        # 通常 Developer 経路（else ブランチ）には一切影響しない（Req 1.1, 1.3, 1.4, 1.5, 2.1, NFR 1.1）。
        local _pt_remaining
        _pt_remaining=$(pt_extract_pending_tasks "$_pt_tasks_md" || true)
        if [ -n "$_pt_remaining" ]; then
          local _pt_remaining_count
          _pt_remaining_count=$(printf '%s\n' "$_pt_remaining" | wc -l | tr -d '[:space:]')
          pt_log "issue=#${NUMBER} 必須未完了 task=${_pt_remaining_count} 残存 → ready-for-review 遷移を保留し resumable return 0（残: $(printf '%s' "$_pt_remaining" | tr '\n' ' '))" | tee -a "$LOG"
          echo "⏸️ #$NUMBER: per-task ループ終了時に必須未完了 task が ${_pt_remaining_count} 件残存 → ready-for-review へ進めず後続 tick で再開" | tee -a "$LOG"
          # ── 保留前の完了済み task commit を origin に push (#198 欠陥②: push-skip) ──
          # per-task ループ内に逐次 push は無く、Implementer は commit のみを積む（push は
          # 本 Stage A 末尾の verify_pushed_or_retry に集約される設計）。従来この保留経路
          # （return 0）が後段の verify_pushed_or_retry（全完了経路 / 9228 付近）より手前に
          # あったため、必須未完了のまま保留すると **完了済み task の commit が origin に
          # push されないまま** 次サイクルの branch 再初期化（impl-resume の
          # `git checkout -B "$BRANCH" "origin/$BRANCH"`）で失われ、再 pickup されても
          # task 1 からやり直す無限空転になっていた（#180 Part 2 実測）。ここで保留する前に
          # verify_pushed_or_retry で完了済み commit を origin に確実に残すことで、次サイクルの
          # impl-resume が `- [x]` skip で task N+1 から継続でき、直後の再 pickup 可能化
          # （ラベル除去）とセットで初めて「中断 → 後続 tick で継続 → 完了」が成立する
          # （Req 1.2, 2.1, NFR 3.1）。
          #
          # push リトライにも失敗した場合は verify_pushed_or_retry が mark_issue_failed を
          # 既発射している（claude-failed 付与 + claude-picked-up / claude-claimed 除去）。
          # 未 push のまま再 pickup すると空転が再発するため、保留（return 0）ではなく失敗
          # （return 1）に倒して人間に委ねる。
          if ! verify_pushed_or_retry "stageA-pt-hold-push-missing" "$BRANCH" "Stage A (per-task loop hold)"; then
            return 1
          fi
          # ── 保留 Issue の再 pickup 可能化 (#198 / Req 1.1, 1.4, NFR 2.1) ──
          # dispatcher の候補クエリは `-label:"$LABEL_PICKED"`（claude-picked-up）を除外条件に
          # 持つため、保留時に `claude-picked-up` を残したままだと当該 Issue が二度と pickup
          # 候補に上がらず impl-resume が再開せず stuck になる（#180 Part 2 の事例）。ここで
          # `claude-picked-up`（および念のため `claude-claimed`）を除去して bare auto-dev
          # candidate に戻すことで、次 tick の dispatcher が当該 Issue を再選択 → mode 判定が
          # 既存 spec/branch を検出して impl-resume を起動 → 残 task を消化する（残 task の
          # `- [x]` skip による冪等性は既存 impl-resume 機構が担保 / Req 2.1）。
          #
          # quota パスとの非干渉 (Req 3.2/3.3): 本保留は `needs-quota-wait` を一切付与しない。
          # quota 中断は `qa_handle_quota_exceeded` が `needs-quota-wait` を付け
          # `process_quota_resume` が reset+grace 経過まで待つ別経路であり、本保留はラベル除去
          # のみで `needs-quota-wait` を触らないため、quota processor の走査対象（needs-quota-wait
          # のみ）に乗らず二重処理は構造的に発生しない。
          #
          # 副作用失敗の扱い (Req 1.4): `gh issue edit` の失敗は warn 吸収して `return 0` を
          # 維持する（quota ハンドラと同じく副作用失敗で全体を落とさない方針）。失敗時は
          # `claude-picked-up` が残り当該 Issue は次 tick でも候補に上がらないが、その旨を
          # ログに残し次 tick で再評価される（人間が手動でラベル除去する余地も残す）。
          #
          # 同一 tick 即時再開について (Req 1.1): dispatcher は tick 冒頭に候補スナップショットを
          # 取得するため、tick 途中の本ラベル除去は当該 tick のキューに影響しない（同一 tick 内
          # 即時再 claim は構造的に起きず、再開は後続 tick から）。
          if gh issue edit "$NUMBER" --repo "$REPO" \
              --remove-label "$LABEL_PICKED" \
              --remove-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
            pt_log "issue=#${NUMBER} claude-picked-up を除去し bare auto-dev candidate へ復帰 → 後続 tick で impl-resume 再開" | tee -a "$LOG"
          else
            # pt_warn は stderr 出力のため、$LOG への grep 可能な記録は別途 tee で残す（NFR 2.1）
            pt_warn "issue=#${NUMBER} claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）"
            pt_log "issue=#${NUMBER} WARN claude-picked-up 除去に失敗（ラベル残置 → 次 tick で再評価。手動除去で復旧可能）" | tee -a "$LOG"
          fi
          return 0
        fi
        # per-task loop 内では Implementer が commit のみを積み push しない（push は本 Stage A
        # に集約する設計）。全 task 完了経路では loop 終了後の HEAD が完了済み commit 分だけ
        # ahead になっているため、ここで verify_pushed_or_retry が origin へ push する。push
        # 漏れ時は 1 回リトライし、失敗時は claude-failed 化して return 1 する。
        if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A (per-task loop)"; then
          return 1
        fi
        echo "✅ #$NUMBER: Stage A 完了（per-task loop）" | tee -a "$LOG"
        # ── Partial Status Gate (#148) ──
        # Developer が impl-notes.md 末尾に `STATUS: partial_*` を出力した場合は
        # Reviewer 起動を skip して needs-decisions エスカレーションする。status 行不在
        # / `complete` の場合は副作用なしで既存フローへ続行（NFR 1.1, 1.4）。
        local _partial_rc=0
        handle_partial_status || _partial_rc=$?
        case "$_partial_rc" in
          0)  : ;;        # continue（既存フロー）
          10) return 0 ;; # partial 検出: Reviewer skip + 正常終了
          *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
        esac
      else
        echo "--- Stage A 実行（$MODE / PM + Developer）---" >> "$LOG"
        prompt_a=$(build_dev_prompt_a "$MODE")
        # Issue #66: Quota-Aware Watcher 経由で claude を起動（Req 1.1, 1.2, 2.1）
        local _qa_reset_file_a _qa_rc_a=0 _qa_ts_a
        _qa_ts_a=$(date +%Y%m%d-%H%M%S)
        _qa_reset_file_a="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-${_qa_ts_a}"
        qa_run_claude_stage "StageA" "$_qa_reset_file_a" -- \
          claude \
            --print "$prompt_a" \
            --model "$DEV_MODEL" \
            --permission-mode bypassPermissions \
            --max-turns "$DEV_MAX_TURNS" \
            --output-format stream-json \
            --verbose \
            >> "$LOG" 2>&1 || _qa_rc_a=$?
        case "$_qa_rc_a" in
          0)
            # Issue #106 Req 1: Stage A 成功宣言の前にローカル HEAD が origin に到達しているか
            # verify する。ahead == 0 なら従来どおり成功メッセージ（Req 1.3 / 5.1）、
            # ahead > 0 なら自動 push リトライ 1 回。リトライ失敗時は claude-failed 化済で
            # return 1 を伝搬する（Req 1.4, 4.4, 4.5）。
            rm -f "$_qa_reset_file_a"
            if ! verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A"; then
              return 1
            fi
            echo "✅ #$NUMBER: Stage A 完了" | tee -a "$LOG"
            # ── Partial Status Gate (#148) ──
            # 通常 Developer 経路 (PM + Developer / 単一 Implementer) の Stage A 完了直後
            # に impl-notes.md の `STATUS:` 行を検出し、partial を 1st-class に処理する。
            # status 行不在 / `complete` の場合は副作用なし（NFR 1.1, 1.4）。
            local _partial_rc_n=0
            handle_partial_status || _partial_rc_n=$?
            case "$_partial_rc_n" in
              0)  : ;;        # continue
              10) return 0 ;; # partial 検出: Reviewer skip
              *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
            esac
            ;;
          99)
            local _qa_epoch_a
            _qa_epoch_a=$(cat "$_qa_reset_file_a")
            qa_handle_quota_exceeded "$NUMBER" "StageA" "$_qa_epoch_a"
            rm -f "$_qa_reset_file_a"
            echo "⏸️ #$NUMBER: Stage A で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
            return 0
            ;;
          *)
            rm -f "$_qa_reset_file_a"
            echo "❌ #$NUMBER: Stage A 失敗" | tee -a "$LOG"
            mark_issue_failed "stageA" ""
            return 1
            ;;
        esac
      fi
      ;;
    B|C)
      sc_log "Stage A をスキップ（START_STAGE=$START_STAGE / 既存 impl-notes.md を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage A スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Debugger Gate (#22 Phase 3): Stage A 完了直後 BLOCKED 検出 ──
  # `DEBUGGER_ENABLED=true` 時のみ、Stage A 完了直後・stage-a-verify gate 直前で
  # `impl-notes.md` の行頭 `BLOCKED: <reason>` を検出し、Developer 自己宣言経路として
  # Debugger を 1 回起動する。BLOCKED 経路の Stage A' は通常の Round 1 サイクルに合流
  # するため、Stage B / B' で再度 Debugger 起動候補になっても sentinel が「起動済み」
  # を返すため再起動はされない（Req 5.1, 5.2）。
  # `DEBUGGER_ENABLED != "true"` の場合は本ブロックが構造的に skip され、BLOCKED 行は
  # 判定材料に使われず stage-a-verify に直行する（Req 1.2 / NFR 1.1）。
  if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
    local _blocked_reason=""
    if _blocked_reason=$(detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"); then
      if detect_debugger_already_invoked; then
        # 既起動状態での BLOCKED 再発生 → 直行 claude-failed (Req 5.2)
        dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" result=skipped reason=debugger-already-invoked" >> "$LOG"
        echo "❌ #$NUMBER: Developer BLOCKED 宣言を検出したが Debugger は既起動 → claude-failed (Req 5.2)" | tee -a "$LOG"
        mark_issue_failed "debugger-blocked-but-invoked" "Developer が \`impl-notes.md\` に \`BLOCKED:\` 行を出力しましたが、本 Issue では既に Debugger が 1 回起動済みのため再起動を抑止し人間判断に委ねます（Req 5.1, 5.2）。

- BLOCKED reason: ${_blocked_reason}
- 既存 Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\`
- impl-notes.md: \`${SPEC_DIR_REL}/impl-notes.md\`

\`$LOG\` を確認し、Fix Plan の追加修正 / 別 Issue 切り出し等を判断してください。"
        return 1
      fi

      # 未起動: Stage D (BLOCKED 経路) → Stage A' (通常差し戻し + Fix Plan 注入) → 通常 Round 1 サイクル
      echo "🐛 #$NUMBER: Developer BLOCKED 宣言検出 → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
      dbg_log "trigger=blocked issue=#${NUMBER} task=none reason=\"${_blocked_reason}\" start (detected at impl-notes.md)" >> "$LOG"
      local _dbg_rc=0
      run_debugger_stage "blocked" "" "" || _dbg_rc=$?
      case "$_dbg_rc" in
        99)
          echo "⏸️ #$NUMBER: Debugger (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        0)
          echo "✅ #$NUMBER: Debugger (BLOCKED 経路) 完了 → Stage A' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
          ;;
        *)
          # Debugger 異常終了 → mark_issue_failed 既発射、Stage A' 実行なし (Req 3.6)
          return 1
          ;;
      esac

      # ── Stage A' (Developer 再起動 + Fix Plan 注入 / BLOCKED 経路、review-notes.md なし) ──
      echo "--- Stage A' 実行（Developer 再起動 / BLOCKED 経路 Debugger Fix Plan 注入）---" >> "$LOG"
      local prompt_redo_bl
      # BLOCKED 経路では review-notes.md は無いため空文字を渡す（build_dev_prompt_redo_with_fix_plan
      # が「(Reviewer 経由ではないため review-notes.md は無し)」と明示する）
      prompt_redo_bl=$(build_dev_prompt_redo_with_fix_plan \
        "" \
        "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
      local _qa_reset_file_bl _qa_rc_bl=0 _qa_ts_bl
      _qa_ts_bl=$(date +%Y%m%d-%H%M%S)
      _qa_reset_file_bl="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-prime-blocked-${_qa_ts_bl}"
      qa_run_claude_stage "StageA-prime-blocked" "$_qa_reset_file_bl" -- \
        claude \
          --print "$prompt_redo_bl" \
          --model "$DEV_MODEL" \
          --permission-mode bypassPermissions \
          --max-turns "$DEV_MAX_TURNS" \
          --output-format stream-json \
          --verbose \
          >> "$LOG" 2>&1 || _qa_rc_bl=$?
      case "$_qa_rc_bl" in
        0)
          rm -f "$_qa_reset_file_bl"
          if ! verify_pushed_or_retry "stageA-prime-blocked-push-missing" "$BRANCH" "Stage A' (BLOCKED 経路)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Stage A' (BLOCKED 経路) 完了 → 通常 Round 1 サイクルに合流 (Req 4.4)" | tee -a "$LOG"
          # ── Partial Status Gate (#148) ──
          # BLOCKED 経路の Stage A' 完了直後でも partial 検出を有効化する（Debugger Fix Plan
          # 注入後の再実装で Developer が partial を宣言した場合に Reviewer 起動を skip）。
          local _partial_rc_bl=0
          handle_partial_status || _partial_rc_bl=$?
          case "$_partial_rc_bl" in
            0)  : ;;        # continue
            10) return 0 ;; # partial 検出: Reviewer skip
            *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
          esac
          ;;
        99)
          local _qa_epoch_bl
          _qa_epoch_bl=$(cat "$_qa_reset_file_bl")
          qa_handle_quota_exceeded "$NUMBER" "StageA-prime-blocked" "$_qa_epoch_bl"
          rm -f "$_qa_reset_file_bl"
          echo "⏸️ #$NUMBER: Stage A' (BLOCKED 経路) で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        *)
          rm -f "$_qa_reset_file_bl"
          echo "❌ #$NUMBER: Stage A' (BLOCKED 経路 Developer 再実行) 失敗" | tee -a "$LOG"
          mark_issue_failed "stageA-prime-blocked" "BLOCKED 経路の Debugger 経由 Developer 再実行（Stage A'）が claude 非 0 exit で失敗しました（rc=${_qa_rc_bl}）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      # 続行: stage-a-verify → Stage B (Round 1) に合流（Req 4.4）
    fi
  fi

  # ── stage-a-verify gate (#125) ──
  # Stage A 完了直後・Stage B 開始直前で `tasks.md` 末尾の verify タスク（build /
  # test / lint）を watcher が REPO_DIR で独立再実行する。Stage A skipped path
  # （START_STAGE=B|C）でも通すことで Stage Checkpoint resume 経由のフローでも
  # gate が機能する（design.md「stage-a-verify と Stage Checkpoint の協調」参照）。
  # `STAGE_A_VERIFY_ENABLED=false` 明示時は stage_a_verify_run が即 return 0 して
  # 本機能導入前と user-observable に完全同一の挙動になる（Req 4.1 / NFR 1.1）。
  # `stage_a_verify_run` の戻り値 0/1/2 を `run_impl_pipeline` の従来契約
  # （0 = 成功 / 1 = 失敗）にマップする（NFR 1.3）。round=2 escalate (戻り値 2)
  # 時は内部で `mark_issue_failed` が発火済みなので外部観測上は claude-failed。
  local _sav_rc=0
  stage_a_verify_run || _sav_rc=$?
  case "$_sav_rc" in
    0)
      : ;;  # SUCCESS / SKIPPED / DISABLED → 続行
    1)
      echo "🔁 #$NUMBER: stage-a-verify 失敗（round=1）→ Developer 差し戻し（次 tick で再試行）" | tee -a "$LOG"
      return 1
      ;;
    2)
      echo "❌ #$NUMBER: stage-a-verify 連続 2 回失敗 → claude-failed" | tee -a "$LOG"
      return 1
      ;;
  esac

  # ── Stage B (round=1): Reviewer / Stage A' / Stage B(round=2) ──
  case "$START_STAGE" in
    A|B)
      rev_rc=0
      run_reviewer_stage 1 || rev_rc=$?
      case $rev_rc in
        0)
          # Issue #106 Req 3: Stage B (Reviewer round=1 approve) 完了直後に push 状態 verify。
          # review-notes.md が Reviewer によって commit されているが未 push のケースを検出する
          # （Req 3.4 review-notes.md 識別ログ粒度は stage label "Stage B (round=1 approve)" で表現）。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 approve)"; then
            return 1
          fi
          echo "✅ #$NUMBER: Reviewer round=1 approve" | tee -a "$LOG"
          ;;
        99)
          # Issue #66: Reviewer round=1 で quota 超過検出。run_reviewer_stage 内で
          # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
          echo "⏸️ #$NUMBER: Reviewer round=1 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
          return 0
          ;;
        1)
          # Issue #106 Req 3: Stage B (Reviewer round=1 reject) 完了直後にも push 状態 verify。
          # 「reject だが review-notes.md 未 push」状態で Stage A' を起動すると Stage A' 側の
          # build_dev_prompt_redo が origin の古い review-notes.md を参照する事故を防ぐ。
          if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=1 reject)"; then
            return 1
          fi
          echo "🔁 #$NUMBER: Reviewer round=1 reject → Developer 再実行" | tee -a "$LOG"
          rv_dev_log "redo by reviewer reject (round=1)" >> "$LOG"

          # ── Stage A' (Developer 再実行) ──
          echo "--- Stage A' 実行（Developer 再実行 / Reviewer reject 差し戻し）---" >> "$LOG"
          prompt_redo=$(build_dev_prompt_redo "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")
          # Issue #66: Quota-Aware Watcher 経由で claude を起動
          local _qa_reset_file_aredo _qa_rc_aredo=0 _qa_ts_aredo
          _qa_ts_aredo=$(date +%Y%m%d-%H%M%S)
          _qa_reset_file_aredo="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-redo-${_qa_ts_aredo}"
          qa_run_claude_stage "StageA-redo" "$_qa_reset_file_aredo" -- \
            claude \
              --print "$prompt_redo" \
              --model "$DEV_MODEL" \
              --permission-mode bypassPermissions \
              --max-turns "$DEV_MAX_TURNS" \
              --output-format stream-json \
              --verbose \
              >> "$LOG" 2>&1 || _qa_rc_aredo=$?
          case "$_qa_rc_aredo" in
            0)
              # Issue #106 Req 2: Stage A' 成功宣言の前にローカル HEAD が origin に到達して
              # いるか verify する（Req 2.1〜2.3, 4.1〜4.5）。
              rm -f "$_qa_reset_file_aredo"
              if ! verify_pushed_or_retry "stageA-prime-push-missing" "$BRANCH" "Stage A'"; then
                return 1
              fi
              echo "✅ #$NUMBER: Stage A' 完了" | tee -a "$LOG"
              # ── Partial Status Gate (#148) ──
              # Reviewer reject 差し戻し経路の Stage A' 完了直後でも partial 検出を有効化
              # する（再実装中に Developer が partial を宣言した場合に Reviewer round=2
              # 起動を skip）。
              local _partial_rc_aredo=0
              handle_partial_status || _partial_rc_aredo=$?
              case "$_partial_rc_aredo" in
                0)  : ;;        # continue
                10) return 0 ;; # partial 検出: Reviewer skip
                *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
              esac
              ;;
            99)
              local _qa_epoch_aredo
              _qa_epoch_aredo=$(cat "$_qa_reset_file_aredo")
              qa_handle_quota_exceeded "$NUMBER" "StageA-redo" "$_qa_epoch_aredo"
              rm -f "$_qa_reset_file_aredo"
              echo "⏸️ #$NUMBER: Stage A' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            *)
              rm -f "$_qa_reset_file_aredo"
              echo "❌ #$NUMBER: Stage A' (Developer 再実行) 失敗" | tee -a "$LOG"
              mark_issue_failed "stageA-redo" ""
              return 1
              ;;
          esac

          # ── Stage B (round=2): Reviewer 最終回 ──
          rev_rc=0
          run_reviewer_stage 2 || rev_rc=$?
          case $rev_rc in
            0)
              # Issue #106 Req 3: Stage B (Reviewer round=2 approve) 完了直後の push 状態 verify。
              if ! verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 approve)"; then
                return 1
              fi
              echo "✅ #$NUMBER: Reviewer round=2 approve" | tee -a "$LOG"
              ;;
            99)
              # Issue #66: Reviewer round=2 で quota 超過検出。run_reviewer_stage 内で
              # qa_handle_quota_exceeded 済 / needs-quota-wait に遷移済 → 正常終了で抜ける。
              echo "⏸️ #$NUMBER: Reviewer round=2 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
              return 0
              ;;
            1)
              # Issue #106 Req 3.1: Stage B 完了は reject / approve いずれも verify 対象。
              # 本ケース（round=2 reject）は Debugger Gate 経路への分岐 / もしくは
              # reviewer-reject2 で claude-failed に確定するため、verify 自体は best-effort
              # で実行し失敗してもより情報量の多い後続経路を優先する。ahead > 0 検出時の
              # WARN ログ / 自動 push 復旧コメントは verify_pushed_or_retry 内で出力済
              # （観測可能性は維持）。
              verify_pushed_or_retry "stageB-push-missing" "$BRANCH" "Stage B (round=2 reject)" || true

              # Phase 3 (#22): DEBUGGER_ENABLED=true 時のみ Debugger Gate に分岐。
              # Debugger 未起動（sentinel 不在）なら Stage D (Round 2 reject) → Stage A''
              # (Developer 再起動 + Fix Plan 注入) → Stage B'' (Reviewer Round 3) を 1 回だけ
              # 試行する。`DEBUGGER_ENABLED != "true"` または sentinel 既起動の場合は
              # 既存 reviewer-reject2 経路（claude-failed 直行）にフォールバック。
              # 本分岐が構造的に skip されるため、DEBUGGER_ENABLED 未指定 / `=false` の
              # 既存挙動は完全に不変（NFR 1.1 / Req 1.1, 1.2）。
              if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked; then
                echo "🐛 #$NUMBER: Reviewer round=2 reject → Debugger Gate 起動（DEBUGGER_ENABLED=true）" | tee -a "$LOG"
                local _dbg_rc=0
                run_debugger_stage "round2-reject" "" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" || _dbg_rc=$?
                case "$_dbg_rc" in
                  99)
                    # quota 超過: 既存 #66 規約に従い watcher は正常終了。Resume Processor が次 tick で再開
                    echo "⏸️ #$NUMBER: Debugger で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  0)
                    # Debugger 正常終了 + debugger-notes.md verify 成功 → Stage A'' へ
                    echo "✅ #$NUMBER: Debugger 完了 → Stage A'' (Developer 再起動 + Fix Plan 注入)" | tee -a "$LOG"
                    ;;
                  *)
                    # Debugger 異常終了 / verify 失敗 → mark_issue_failed 既発射、Stage A''/B'' 実行なし (Req 3.6)
                    return 1
                    ;;
                esac

                # ── Stage A'' (Developer 再起動 + Fix Plan 注入) ──
                echo "--- Stage A'' 実行（Developer 再起動 / Debugger Fix Plan 注入）---" >> "$LOG"
                local prompt_redo_fp
                prompt_redo_fp=$(build_dev_prompt_redo_with_fix_plan \
                  "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" \
                  "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md")
                local _qa_reset_file_app _qa_rc_app=0 _qa_ts_app
                _qa_ts_app=$(date +%Y%m%d-%H%M%S)
                _qa_reset_file_app="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageA-pp-${_qa_ts_app}"
                qa_run_claude_stage "StageA-pp" "$_qa_reset_file_app" -- \
                  claude \
                    --print "$prompt_redo_fp" \
                    --model "$DEV_MODEL" \
                    --permission-mode bypassPermissions \
                    --max-turns "$DEV_MAX_TURNS" \
                    --output-format stream-json \
                    --verbose \
                    >> "$LOG" 2>&1 || _qa_rc_app=$?
                case "$_qa_rc_app" in
                  0)
                    rm -f "$_qa_reset_file_app"
                    if ! verify_pushed_or_retry "stageA-pp-push-missing" "$BRANCH" "Stage A''"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Stage A'' 完了" | tee -a "$LOG"
                    # ── Partial Status Gate (#148) ──
                    # Debugger 経由 Stage A'' 完了直後でも partial 検出を有効化する。
                    # Fix Plan を注入されてもなお Developer が partial を宣言した場合に
                    # Reviewer round=3 起動を skip。
                    local _partial_rc_app=0
                    handle_partial_status || _partial_rc_app=$?
                    case "$_partial_rc_app" in
                      0)  : ;;        # continue
                      10) return 0 ;; # partial 検出: Reviewer skip
                      *)  return 1 ;; # 不正 status: mark_issue_failed 実行済
                    esac
                    ;;
                  99)
                    local _qa_epoch_app
                    _qa_epoch_app=$(cat "$_qa_reset_file_app")
                    qa_handle_quota_exceeded "$NUMBER" "StageA-pp" "$_qa_epoch_app"
                    rm -f "$_qa_reset_file_app"
                    echo "⏸️ #$NUMBER: Stage A'' で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  *)
                    rm -f "$_qa_reset_file_app"
                    echo "❌ #$NUMBER: Stage A'' (Debugger 経由 Developer 再実行) 失敗" | tee -a "$LOG"
                    mark_issue_failed "stageA-pp" "Debugger 経由 Developer 再実行（Stage A''）が claude 非 0 exit で失敗しました（rc=${_qa_rc_app}）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac

                # ── Stage B'' (Reviewer Round 3): Debugger 経由の最終 Reviewer ──
                local rev_rc3=0
                run_reviewer_stage 3 || rev_rc3=$?
                # Round 3 結果をログに記録（NFR 2.1 の 4 イベント目）
                case "$rev_rc3" in
                  0)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=approve" >> "$LOG"
                    if ! verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 approve)"; then
                      return 1
                    fi
                    echo "✅ #$NUMBER: Reviewer round=3 approve（Debugger 経由）" | tee -a "$LOG"
                    # 既存 approve 後経路（Stage C）に合流するため case を抜ける
                    ;;
                  99)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=quota-exceeded" >> "$LOG"
                    echo "⏸️ #$NUMBER: Reviewer round=3 で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
                    return 0
                    ;;
                  1)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=reject" >> "$LOG"
                    verify_pushed_or_retry "stageB-pp-push-missing" "$BRANCH" "Stage B'' (round=3 reject)" || true
                    echo "❌ #$NUMBER: Reviewer round=3 reject → claude-failed（Debugger 再起動なし / Req 3.5）" | tee -a "$LOG"
                    local parsed3 cat3 tgt3
                    parsed3=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                    cat3=$(echo "$parsed3" | cut -f2)
                    tgt3=$(echo "$parsed3" | cut -f3)
                    local reject_body3
                    reject_body3="Debugger 経由の Reviewer round=3 でも reject となったため、自動 iteration を打ち切り人間判断に委ねます（Debugger は 1 Issue あたり 1 回のみ起動するため再起動しません / Req 3.5）。

- 対象 requirement ID: ${tgt3:-(unknown)}
- reject カテゴリ: ${cat3:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照
- Debugger Fix Plan: \`${SPEC_DIR_REL}/debugger-notes.md\` を参照

### 次の手順
1. review-notes.md / debugger-notes.md / watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                    mark_issue_failed "reviewer-reject3" "$reject_body3"
                    return 1
                    ;;
                  *)
                    dbg_log "trigger=round2-reject issue=#${NUMBER} task=none round3 result=error" >> "$LOG"
                    echo "❌ #$NUMBER: Reviewer round=3 異常終了 → claude-failed" | tee -a "$LOG"
                    mark_issue_failed "reviewer-error" "Debugger 経由の Reviewer round=3 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
                    return 1
                    ;;
                esac
              else
                # DEBUGGER_ENABLED != "true" もしくは sentinel 既起動 → 既存 reviewer-reject2 経路
                if [ "${DEBUGGER_ENABLED:-false}" = "true" ]; then
                  # Debugger 既起動状態での Round 2 reject 再発生 (Req 5.2)
                  dbg_log "trigger=round2-reject issue=#${NUMBER} task=none result=skipped reason=debugger-already-invoked" >> "$LOG"
                fi
                # 2 回目 reject → claude-failed + Issue コメントに reject 理由 / 対象 ID を含める
                echo "❌ #$NUMBER: Reviewer round=2 reject → claude-failed" | tee -a "$LOG"
                local parsed2 cat2 tgt2
                parsed2=$(parse_review_result "$REPO_DIR/$SPEC_DIR_REL/review-notes.md" 2>/dev/null || echo "")
                cat2=$(echo "$parsed2" | cut -f2)
                tgt2=$(echo "$parsed2" | cut -f3)
                local reject_body
                reject_body="Reviewer が 2 回連続で reject を出したため、自動 iteration を打ち切り、人間判断に委ねます。

- 対象 requirement ID: ${tgt2:-(unknown)}
- reject カテゴリ: ${cat2:-(unknown)}
- Reviewer 判定詳細: \`${SPEC_DIR_REL}/review-notes.md\` を参照

### 次の手順
1. review-notes.md と watcher ログを読み、Reviewer 判定が妥当か確認
2. 妥当なら手動で修正 commit を積み、\`claude-failed\` を外す
3. Reviewer 判定が誤りなら、Issue コメントで Architect 差し戻しを提案"
                mark_issue_failed "reviewer-reject2" "$reject_body"
                return 1
              fi
              ;;
            *)
              # round=2 reviewer error
              echo "❌ #$NUMBER: Reviewer round=2 異常終了 → claude-failed" | tee -a "$LOG"
              mark_issue_failed "reviewer-error" "Reviewer round=2 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
              return 1
              ;;
          esac
          ;;
        *)
          # round=1 reviewer error → claude-failed + Issue コメント (要件 4.8)
          echo "❌ #$NUMBER: Reviewer round=1 異常終了 → claude-failed" | tee -a "$LOG"
          mark_issue_failed "reviewer-error" "Reviewer round=1 が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
          return 1
          ;;
      esac
      ;;
    C)
      sc_log "Stage B をスキップ（START_STAGE=C / 既存 review-notes.md approve を再利用）" >> "$LOG"
      echo "⏭️  #$NUMBER: Stage B スキップ（Stage Checkpoint resume）" | tee -a "$LOG"
      ;;
  esac

  # ── Stage C: PjM (PR 作成) ──
  echo "--- Stage C 実行（PjM / PR 作成）---" >> "$LOG"
  # Issue #96 Req 1.5: PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
  if ! _assert_base_branch_resolved; then
    echo "❌ #$NUMBER: Stage C 中断（BASE_BRANCH 未解決）→ claude-failed" | tee -a "$LOG"
    mark_issue_failed "stageC-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため Stage C を中断しました（Issue #96 Req 1.5）。"
    return 1
  fi
  prompt_c=$(build_dev_prompt_c "$MODE")
  # Issue #66: Quota-Aware Watcher 経由で claude を起動
  local _qa_reset_file_c _qa_rc_c=0 _qa_ts_c
  _qa_ts_c=$(date +%Y%m%d-%H%M%S)
  _qa_reset_file_c="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-stageC-${_qa_ts_c}"
  qa_run_claude_stage "StageC" "$_qa_reset_file_c" -- \
    claude \
      --print "$prompt_c" \
      --model "$DEV_MODEL" \
      --permission-mode bypassPermissions \
      --max-turns "$DEV_MAX_TURNS" \
      --output-format stream-json \
      --verbose \
      >> "$LOG" 2>&1 || _qa_rc_c=$?
  case "$_qa_rc_c" in
    0)
      # Issue #104 Bug 3 / Req 4.1〜4.4: claude RC=0 + quota 検出なし時点では
      # 「PR が実際に作成されたか」が未確認。PjM サブエージェントが 1 turn で
      # 空転終了しても claude RC=0 を返すため、PR 実在を gh で verify する。
      # Issue #108: GitHub の eventual consistency による false negative を吸収する
      # ため、verify_stagec_pr_or_retry で主経路リトライを実施。
      # Issue #110: 73 秒以上の edge cache lag を観測した実例（KeyNest #32）への
      # 対応として主経路を 6 回 / 合計 135 秒に延長し、最終 attempt 後に List Pulls
      # API への独立 fallback を 1 ターン追加。1 回目で成功する通常ケースの外形
      # 挙動は本変更前と同一（Req 4.1 / 4.6 / NFR 1.1）。
      rm -f "$_qa_reset_file_c"
      local _stagec_pr_url _stagec_verify_rc=0
      _stagec_pr_url=$(verify_stagec_pr_or_retry "$BRANCH" "$NUMBER") || _stagec_verify_rc=$?
      if [ "$_stagec_verify_rc" -eq 0 ] && [ -n "$_stagec_pr_url" ]; then
        # Req 4.3 / Issue #108 Req 3.4 / Issue #110 Req 3.6: 主経路 1 回目即時成功
        # でも代替経路救済でも、呼び出し側の成功ログは共通（外形互換）
        echo "✅ #$NUMBER: Stage C 完了 / PR 作成済み (${_stagec_pr_url})" | tee -a "$LOG"
        return 0
      fi
      # Req 4.2 / 4.4 / Issue #108 Req 2.1 / Issue #110 Req 2.3 / 2.4:
      # 主経路リトライ + 代替経路 1 ターンを使い切っても PR 不在の場合は
      # 安全側に倒し claude-failed 化（NFR 2.2: 人間が原因を特定できる粒度のログを残す）
      echo "❌ #$NUMBER: Stage C 完了報告だが対応 PR 不在 → claude-failed (branch=$BRANCH verify_rc=$_stagec_verify_rc, 主経路リトライ + 代替 API 経路 fallback 後)" | tee -a "$LOG"
      qa_warn "stageC PR verify failed after retry+fallback issue=#$NUMBER branch=$BRANCH verify_rc=$_stagec_verify_rc pr_url='${_stagec_pr_url:-(empty)}'"
      mark_issue_failed "stageC-pr-missing" "Stage C の Claude 実行は return code 0 で終了しましたが、対応する impl PR が GitHub 側に検出できませんでした（branch=\`$BRANCH\`、主経路リトライ + 代替 API 経路 fallback 後）。PjM サブエージェントが 1 turn で空転終了した可能性 / GitHub API 一時障害の可能性のいずれかです。\`$LOG\` を確認してください。"
      return 1
      ;;
    99)
      local _qa_epoch_c
      _qa_epoch_c=$(cat "$_qa_reset_file_c")
      qa_handle_quota_exceeded "$NUMBER" "StageC" "$_qa_epoch_c"
      rm -f "$_qa_reset_file_c"
      echo "⏸️ #$NUMBER: Stage C で quota 超過検出 → needs-quota-wait" | tee -a "$LOG"
      return 0
      ;;
    *)
      rm -f "$_qa_reset_file_c"
      echo "❌ #$NUMBER: Stage C (PjM) 失敗" | tee -a "$LOG"
      mark_issue_failed "stageC" ""
      return 1
      ;;
  esac
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Issue 入口並列化 (worktree slot + dispatcher, #16)
#
# auto-dev Issue 処理ループを Dispatcher / Slot Worker パターンに置き換え、
# 複数 Issue を時間的に重ねて処理できるようにする。
#
# 構成:
#   - _parallel_validate_slots : PARALLEL_SLOTS 検証
#   - Worktree Manager  : per-slot 永続 worktree の初期化・最新化
#   - Slot Lock Manager : per-slot 非ブロッキング flock の取得・解放
#   - Hook Layer        : SLOT_INIT_HOOK の絶対パス起動（eval 不使用）
#   - Slot Runner       : 1 Issue を 1 worktree で処理する Worker
#   - Dispatcher        : Issue 候補取得 → claim → slot 投入 → 全 Worker wait
#
# PARALLEL_SLOTS=1（デフォルト）のとき、slot-2 以降の lock / worktree を作成せず、
# 本機能導入前と外形的に同一挙動になるよう実装する。
#
# 詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ─── Phase C: Logger ───
# Dispatcher / Slot Worker / Worktree / Hook 共通の timestamp 形式（既存 mq_log 等と同じ）
dispatcher_log() {
  echo "[$(date '+%F %T')] dispatcher: $*"
}
dispatcher_warn() {
  echo "[$(date '+%F %T')] dispatcher: WARN: $*" >&2
}
dispatcher_error() {
  echo "[$(date '+%F %T')] dispatcher: ERROR: $*" >&2
}

# ─── Pre-Claim Probe Logger (Issue #65) ───
# claim 直前に linked impl PR を検出する Pre-Claim Filter 用 logger。
# 既存 mq_log / pi_log / drr_log / qa_log / sc_log / dispatcher_log と同じ
# `[$(date '+%F %T')] <prefix>: ...` 形式に揃え、識別 prefix `pre-claim-probe:`
# で grep 集計できるようにする（Req NFR 2.1）。
pclp_log() {
  echo "[$(date '+%F %T')] pre-claim-probe: $*"
}
pclp_warn() {
  echo "[$(date '+%F %T')] pre-claim-probe: WARN: $*" >&2
}
pclp_error() {
  echo "[$(date '+%F %T')] pre-claim-probe: ERROR: $*" >&2
}

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

# ─── _parallel_validate_slots ───
#
# PARALLEL_SLOTS が正の整数として解釈できるかを検証する。
# - 0 / 負数 / 非数値 / 空文字 / 先頭ゼロ等の形式違反を拒否する
# - 不正なら ERROR ログを stderr に出力して return 1
# 戻り値: 0 = ok / 1 = invalid
#
# Req 1.3: 不正値時はサイクル中断（呼び出し元で exit 1）
# Req 6.5: timestamp 書式 [YYYY-MM-DD HH:MM:SS] を維持
_parallel_validate_slots() {
  if [[ ! "$PARALLEL_SLOTS" =~ ^[1-9][0-9]*$ ]]; then
    dispatcher_error "PARALLEL_SLOTS は正の整数を指定してください: '$PARALLEL_SLOTS'"
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Runner ───
#
# 1 Issue を 1 つの slot worktree で処理する Worker。Dispatcher から
# `( _slot_run_issue $n $issue_json ) &` の形でバックグラウンド fork される。
#
# 設計上の重要点:
#   - サブシェルで動くため、内部の `cd` / 環境変数変更は親に伝播しない（Req 3.5 を構造的に保証）
#   - 入口で _slot_acquire 済を前提（Dispatcher が取得済の lock fd を継承）
#   - claim（claude-picked-up ラベル付与）は Dispatcher 側で完了済（Req 2.2）
#   - 処理シーケンス:
#       1. slot 専用ログファイル open
#       2. _worktree_ensure → 失敗時 claude-failed 化 + return
#       3. cd "$WT"
#       4. _worktree_reset → 失敗時 claude-failed 化 + return
#       5. _hook_invoke → 失敗時 claude-failed 化 + return
#       6. 既存 Issue 処理ロジック（Triage → mode 判定 → claude 起動）を実行
#   - すべての claude-failed 化は既存 mark_issue_failed パスを再利用（新ラベル不可）
#
# Req 2.7, 3.4, 3.5, 3.6, 5.3, 5.6, 5.7, 6.1, 6.2, 6.5, 7.3, 7.4, NFR 2.1, 2.2, 3.1, 3.2

# slot worker 用ロガー（slot 番号 + Issue 番号を必ず prefix に含める、Req 6.1, NFR 3.1）。
# サブシェル内で IDD_SLOT_NUMBER / NUMBER を読み取って prefix を組み立てる。
slot_log() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: $*"
}
slot_warn() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: WARN: $*" >&2
}
slot_error() {
  echo "[$(date '+%F %T')] slot-${IDD_SLOT_NUMBER:-?}: #${NUMBER:-?}: ERROR: $*" >&2
}

# claim 系ラベル（claude-claimed / claude-picked-up）を claude-failed に置き換える
# 共通フロー（Worktree / Hook / その他サブシェル内エラー用）。run_impl_pipeline 内の
# mark_issue_failed と同じ操作を slot worker 文脈で再現する（mark_issue_failed は
# MODE / LOG 等を要求するため代用しない）。
#
# Issue #52: 両系統除去で post-Triage / pre-Triage どちらの失敗にも対応する。
# - pre-Triage 失敗時点では Issue は claude-claimed のみ持つ
# - post-Triage（impl 着手後）失敗時点では Issue は claude-picked-up のみ持つ
# - design ルートで Stage C 失敗等の想定外シーケンスでも残置を防ぐため両方除去する
# gh CLI は未付与ラベルの除去を no-op として扱うため安全（既存 || true で吸収）。
#
# 引数: $1 = stage 識別子, $2 = Issue コメントに追加する補足
_slot_mark_failed() {
  local stage="$1"
  local extra="$2"
  gh issue edit "$NUMBER" --repo "$REPO" \
    --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" --add-label "$LABEL_FAILED" >/dev/null 2>&1 || true
  local hostname_val
  hostname_val=$(hostname)
  local body="⚠️ 自動開発が失敗しました（${hostname_val} / slot=${IDD_SLOT_NUMBER:-?} / 失敗 stage: ${stage}）。"
  if [ -n "$extra" ]; then
    body="${body}

${extra}"
  fi
  if [ -n "${LOG:-}" ]; then
    body="${body}

ログ: \`$LOG\`"
  fi
  body="${body}

問題を解決してから \`claude-failed\` ラベルを外してください。"

  # Issue #65 Req 3.1/3.2/3.3/3.4: 手動復旧手順を末尾に append。
  # _slot_mark_failed は worktree / Hook / Triage 失敗等から呼ばれ、PR の有無が
  # 文脈で確定しないため pr_present="unknown" を渡す（両ケース併記）。
  body="${body}
$(build_recovery_hint "unknown")"
  gh issue comment "$NUMBER" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
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
  echo "$raw" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//'
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
dr_log() {
  echo "[$(date '+%F %T')] dr: $*"
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
# 検出する記法（`.claude/rules/issue-dependency.md` と整合 / Req 1.1〜1.5, 1.7）:
#   - canonical: `Depends on: #N` （行頭の `- ` などの list prefix を許容）
#   - alias 日本語: `前提依存: #N`
#   - alias 英語慣習: `Blocked by: #N`
#
# 1 行に複数の Issue 番号がスペース区切り / カンマ区切りで列挙される場合も対応する
# （Req 1.4）。`grep -oE '#[0-9]+'` で行内の番号を全列挙し、`sort -u` で uniq 化
# （Req 1.5）。
#
# 誤検出許容範囲（NFR 1.4）: markdown コードフェンス内・引用ブロック内の
# 同記法も検出してしまう可能性があるが、本機能のスコープ外（誤検出時は運用者が
# `blocked` ラベルを手動除去で復旧する設計）。
dr_extract_deps() {
  local body="$1"

  # 行抽出: canonical + alias の 3 パターン。
  # `-E` で ERE、`-i` は使わず大文字小文字を厳密にし誤検出を減らす（既存運用で
  # `Depends on:` / `Blocked by:` は大文字始まり前提）。`前提依存:` は UTF-8
  # バイト列として直接マッチ（grep -E で安全）。
  local matched_lines
  matched_lines=$(printf '%s\n' "$body" \
    | grep -E '(Depends on:|前提依存:|Blocked by:)' || true)

  if [ -z "$matched_lines" ]; then
    return 0
  fi

  # 行ごとに `#[0-9]+` を全列挙し、`#` を剥がして数字のみにし uniq 化。
  # `sort -u -n` で数値昇順 + uniq（出力決定性を確保）。
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

  cat <<EOF_DR_COMMENT
🛑 依存 Issue 未 merge のため自動処理を中止しました。

### 未解決依存

${items}

### 次の手順

1. 上記依存 Issue の解消（merge）を進めてください
2. すべて merge 済みになったら、本 Issue から \`blocked\` ラベルを手動で除去してください
3. 次回 cron tick (\`watcher 起動\` 後) で依存チェックが再実行され、解消済みなら通常の Triage / 実装フローに合流します

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
  # shellcheck disable=SC2016  # `$owner` / `$repo` / `$number` は GraphQL 変数記法であり bash 展開ではない（`-F` で値を渡す）
  local query='query($owner: String!, $repo: String!, $number: Int!) {
    repository(owner: $owner, name: $repo) {
      issue(number: $number) {
        state
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
# `dr_gh_graphql_closed_by` で Issue の state と
# `closedByPullRequestsReferences.nodes[].state` を取得し、以下を判定:
#   - issue.state == "OPEN"  → "open"（unresolved / Req 1.4 / 旧 2.3）
#   - issue.state == "CLOSED" かつ PR ノードの state に "MERGED" が 1 件以上
#     → "resolved"（Req 1.1）
#   - issue.state == "CLOSED" かつ "MERGED" が 0 件（空配列・全 CLOSED 含む）
#     → "closed unmerged"（Req 1.2, 1.3）
#   - gh / jq 失敗 / GraphQL errors / 未知の state → "api error"
#     （Req 2.1, 2.2 / NFR 4.2 安全側）
#
# 旧実装は `gh issue view --json closedByPullRequestsReferences` の PR ノードに
# 存在しない `.merged` フィールドを参照していたため、merge 済み依存も常に
# `closed unmerged` と誤判定していた（#204 の根因 / Req 1.5）。
#
# timeout は DRR_GH_TIMEOUT に従う（個別の新規 env var は導入しない / Req 3.5）。
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
      echo "open"
      return 0
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

# 1 Issue を 1 slot worktree で処理する Worker 本体。
# サブシェル `( _slot_run_issue n issue_json ) &` から呼び出される前提。
#
# 引数:
#   $1 = slot 番号
#   $2 = Issue JSON (gh issue list の 1 要素)
# 戻り値:
#   0 = 成功 / 非ゼロ = 失敗（既に claude-failed ラベルへ遷移済み）
#
# 副作用:
#   - サブシェル内で NUMBER / TITLE / BODY / URL / LABELS / TS / LOG / SLUG /
#     SPEC_DIR_REL / MODE / BRANCH などのグローバル変数を設定（親には伝播しない）
#   - $WT に cd（サブシェル内）
#   - claude / gh / git の副作用は Issue ラベル遷移として外部観測可能
_slot_run_issue() {
  # slot 識別子をサブシェル内で見えるよう export（slot_log / _hook_invoke が参照）
  export IDD_SLOT_NUMBER="$1"
  local issue="$2"

  # ── Issue メタデータ抽出 ──
  NUMBER=$(echo "$issue" | jq -r '.number')
  TITLE=$(echo "$issue"  | jq -r '.title')
  BODY=$(echo "$issue"   | jq -r '.body // ""')
  URL=$(echo "$issue"    | jq -r '.url')
  LABELS=$(echo "$issue" | jq -r '.labels[].name')
  TS=$(date +%Y%m%d-%H%M%S)
  LOG="$LOG_DIR/issue-${NUMBER}-${TS}.log"

  # slot 運用ログ（worktree 初期化・hook 結果など）。Issue ログとは別系統で残す（Req 6.2）。
  local SLOT_LOG="$LOG_DIR/slot-${IDD_SLOT_NUMBER}-${NUMBER}-${TS}.log"
  # 以降の slot_log 行は stdout (cron mailer) と SLOT_LOG の両方に書き出す
  exec > >(tee -a "$SLOT_LOG") 2>&1

  slot_log "Worker 起動 (LOG=$LOG SLOT_LOG=$SLOT_LOG)"

  # ── Worktree 初期化（per-slot 永続 worktree）──
  local WT
  WT="$(_worktree_path "$IDD_SLOT_NUMBER")"
  export IDD_SLOT_WORKTREE="$WT"

  if ! _worktree_ensure "$IDD_SLOT_NUMBER"; then
    slot_warn "worktree 初期化に失敗 (path=$WT)"
    _slot_mark_failed "worktree-ensure" "Slot ${IDD_SLOT_NUMBER} の worktree 初期化に失敗しました（path=\`$WT\`）。"
    return 1
  fi
  slot_log "worktree 確保 OK (path=$WT)"

  # サブシェル内で worktree に cd（親には伝播しない、Req 3.5）
  if ! cd "$WT"; then
    slot_warn "worktree への cd に失敗 (path=$WT)"
    _slot_mark_failed "worktree-cd" "worktree path への cd に失敗しました: \`$WT\`"
    return 1
  fi

  # Issue #76: slot worktree が REPO_DIR の意味を担う。サブシェル内で上書きするため
  # parent cron / launchd 側の REPO_DIR には伝播せず、後段の parse_review_result /
  # stage_checkpoint_* / `git -C "$REPO_DIR"` 系すべてが slot worktree を参照するようになる。
  # 既存 cron 起動文字列を変更する必要はない。
  REPO_DIR="$WT"

  # ── Worktree を origin/$BASE_BRANCH 最新へ強制リセット ──
  if ! _worktree_reset "$WT"; then
    slot_warn "worktree reset に失敗 (path=$WT)"
    _slot_mark_failed "worktree-reset" "Slot ${IDD_SLOT_NUMBER} の worktree を origin/${BASE_BRANCH} にリセットできませんでした。"
    return 1
  fi
  slot_log "worktree reset OK (origin/${BASE_BRANCH} 最新化 + clean -fdx)"

  # ── SLOT_INIT_HOOK 起動（reset 後・claude 起動前に 1 度だけ）──
  if ! _hook_invoke "$IDD_SLOT_NUMBER" "$WT"; then
    slot_warn "SLOT_INIT_HOOK の起動に失敗"
    _slot_mark_failed "slot-init-hook" "SLOT_INIT_HOOK が失敗しました（詳細はログ参照）。SLOT_INIT_HOOK=\`${SLOT_INIT_HOOK:-(unset)}\`"
    return 1
  fi
  if [ -n "${SLOT_INIT_HOOK:-}" ]; then
    slot_log "SLOT_INIT_HOOK 完了"
  fi

  # ── 既存 Issue 処理ロジックを実行 ──
  # ここから下は本機能導入前の Issue ループ本体と等価。サブシェル内で動くため
  # NUMBER / MODE / LOG 等のグローバル変数変更は親に伝播しない（Req 3.5 を構造的に保証）。
  echo "=== Processing #$NUMBER: $TITLE (slot-${IDD_SLOT_NUMBER}) ===" | tee -a "$LOG"

  # ── 既存 spec ディレクトリの検出（設計 PR merge 済みか）と slug 決定 ──
  # Issue #114: expected-slug を Issue タイトルから先に決定し、既存 `docs/specs/<N>-*/`
  # のスラグ部と照合する。不一致時は fork / mirror clone 由来の番号衝突と判断し、
  # 当該 Issue を skip して人間判断に委ねる（Req 1.1〜1.6, Req 3 一式）。
  local EXPECTED_SLUG
  EXPECTED_SLUG=$(_normalize_slug "$TITLE")

  # `docs/specs/<N>-*/` を全件列挙（Req 1.5: 複数存在ケースも全件チェック対象）
  local SPEC_CANDIDATES=()
  local _spec_glob
  for _spec_glob in "$WT/docs/specs/${NUMBER}-"*; do
    [ -d "$_spec_glob" ] || continue
    SPEC_CANDIDATES+=("$_spec_glob")
  done

  local EXISTING_SPEC_DIR=""
  local HAS_EXISTING_SPEC=false
  if [ "${#SPEC_CANDIDATES[@]}" -gt 0 ]; then
    # Req 1.2, 1.3: 各候補のスラグを expected と比較。一致しかつ requirements.md がある
    # ものを採用する。複数一致は通常起こらないが、起きた場合は先頭採用（後方互換）。
    local _cand _cand_slug _matched_dir=""
    for _cand in "${SPEC_CANDIDATES[@]}"; do
      _cand_slug=$(basename "$_cand" | sed "s/^${NUMBER}-//")
      if [ "$_cand_slug" = "$EXPECTED_SLUG" ] && [ -f "$_cand/requirements.md" ]; then
        _matched_dir="$_cand"
        break
      fi
    done

    if [ -n "$_matched_dir" ]; then
      # Req 1.3: 一致 → 従来どおり impl-resume を継続。LOG にスラグ照合 pass を記録（Req 4.1）
      HAS_EXISTING_SPEC=true
      EXISTING_SPEC_DIR="$_matched_dir"
      if ! _stage_checkpoint_assert_slug_match "$EXPECTED_SLUG" "$_matched_dir"; then
        return 1
      fi
      SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
      echo "📂 既存 spec 検出: $EXISTING_SPEC_DIR (slug=$SLUG)" | tee -a "$LOG"
    else
      # Req 1.4, 1.5: docs/specs/<N>-* は存在するが expected-slug と一致するものがない
      # → 先頭候補を mismatch 対象として LOG/escalate し、当該 Issue を skip する。
      local _first="${SPEC_CANDIDATES[0]}"
      if ! _stage_checkpoint_assert_slug_match "$EXPECTED_SLUG" "$_first"; then
        return 1
      fi
      # 防御: _stage_checkpoint_assert_slug_match が 0 を返した（一致した）場合の
      # フォールバック（実装上は到達しないが silent fail を作らないため）
      HAS_EXISTING_SPEC=true
      EXISTING_SPEC_DIR="$_first"
      SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
    fi
  else
    # Req 1.6: `docs/specs/<N>-*/` が存在しないとき → 本要件のスラグ照合は発火させず
    # 従来どおり Issue タイトル由来の新規スラグを採用する（NFR 1.3）
    SLUG="$EXPECTED_SLUG"
  fi
  SPEC_DIR_REL="docs/specs/${NUMBER}-${SLUG}"

  # ── モード判定（design / impl / impl-resume）──
  NEEDS_ARCHITECT="false"
  ARCHITECT_REASON=""
  MODE=""

  if $HAS_EXISTING_SPEC; then
    echo "✅ #$NUMBER: 設計レビュー済み（spec dir あり） → impl-resume モード" | tee -a "$LOG"
    MODE="impl-resume"
  elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "skip-triage ラベルがあるため Triage をスキップ → impl モード" | tee -a "$LOG"
    ARCHITECT_REASON="Triage をスキップ（軽微な変更扱い）"
    MODE="impl"
  else
    # ── Dependency Resolver Gate (Issue #146) ──
    # Triage 起動直前に Issue 本文の前提依存（canonical `Depends on:` /
    # alias `前提依存:` / alias `Blocked by:`）を機械検証し、依存先 Issue が
    # 未 merge のまま残る場合は `blocked` 付与 + コメント投稿 + claim 系ラベル
    # 除去で人間判断へ委ね、本サイクルの当該 Issue 処理を打ち切る（Req 3.5）。
    # `HAS_EXISTING_SPEC=true`（impl-resume 経路）および `skip-triage` 経路では
    # 呼び出さない（既に in-flight の Issue への retrofit を Out of Scope と
    # する設計判断 / Req NFR 1.1 後方互換）。
    if ! dr_check_dependencies "$NUMBER" "$BODY" "$LABELS"; then
      slot_log "依存未解決により blocked 付与（Issue #146）"
      return 0
    fi

    # ── Triage フェーズ ──
    local TRIAGE_FILE="/tmp/triage-${REPO_SLUG}-${NUMBER}-${TS}.json"
    rm -f "$TRIAGE_FILE"

    local TITLE_SAFE="${TITLE//|/\\|}"
    local TRIAGE_PROMPT
    TRIAGE_PROMPT=$(sed \
      -e "s|{{NUMBER}}|${NUMBER}|g" \
      -e "s|{{TITLE}}|${TITLE_SAFE}|g" \
      -e "s|{{URL}}|${URL}|g" \
      -e "s|{{FILE}}|${TRIAGE_FILE}|g" \
      "$TRIAGE_TEMPLATE")

    echo "--- Triage 実行 ---" >> "$LOG"
    # Issue #66: Quota-Aware Watcher 経由で claude を起動。opt-out 時は素通し
    # （既存挙動互換）、opt-in 時は rate_limit_event 検知で exit 99 を返す。
    local _qa_reset_file_triage="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-triage-${TS}"
    local _qa_rc_triage=0
    qa_run_claude_stage "Triage" "$_qa_reset_file_triage" -- \
      claude \
        --print "$TRIAGE_PROMPT" \
        --model "$TRIAGE_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$TRIAGE_MAX_TURNS" \
        >> "$LOG" 2>&1 || _qa_rc_triage=$?
    case "$_qa_rc_triage" in
      0)
        : # 正常終了 → 後続処理へ
        ;;
      99)
        # quota 超過検出（opt-in 時のみ発生）→ needs-quota-wait に遷移し、
        # _slot_mark_failed を踏まずに正常終了する（Req 3.1, 3.2）
        local _qa_epoch_triage
        _qa_epoch_triage=$(cat "$_qa_reset_file_triage")
        qa_handle_quota_exceeded "$NUMBER" "Triage" "$_qa_epoch_triage"
        rm -f "$_qa_reset_file_triage"
        slot_log "Triage で quota 超過検出 → needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_triage"
        echo "❌ Triage の実行に失敗" | tee -a "$LOG"
        # claude-picked-up は Dispatcher 側で付与済。Triage 失敗時は claude-failed に
        # 遷移して人間判断に委ねる（既存挙動: Triage 失敗時は continue だったが、
        # Phase C ではすでに claim 済のため、ラベルを残置せず claude-failed 化する）。
        _slot_mark_failed "triage" "Triage（Claude 実行）に失敗しました。"
        return 1
        ;;
    esac
    rm -f "$_qa_reset_file_triage"

    if [ ! -f "$TRIAGE_FILE" ]; then
      echo "❌ Triage 結果 JSON が生成されませんでした" | tee -a "$LOG"
      _slot_mark_failed "triage-json" "Triage 結果 JSON が生成されませんでした。"
      return 1
    fi

    local STATUS DECISION_COUNT
    STATUS=$(jq -r '.status' "$TRIAGE_FILE")
    DECISION_COUNT=$(jq '.decisions | length' "$TRIAGE_FILE")
    NEEDS_ARCHITECT=$(jq -r '.needs_architect // false' "$TRIAGE_FILE")
    ARCHITECT_REASON=$(jq -r '.architect_reason // ""' "$TRIAGE_FILE")

    # ── Phase E: edit_paths 永続化 (#18 Req 3.1〜3.4) ──
    # PATH_OVERLAP_CHECK=true のときのみ、Triage が返した edit_paths を sticky
    # comment として Issue に保存し、後続 cron tick で Path Overlap Checker が
    # 再読できるようにする。persist 失敗は warn のみで、Triage 全体は成功扱い
    # を維持する（Req 3.4 fail-open）。
    if [ "$PATH_OVERLAP_CHECK" = "true" ]; then
      local _po_paths_json
      _po_paths_json=$(po_parse_triage_edit_paths "$TRIAGE_FILE")
      if ! po_persist_edit_paths "$NUMBER" "$_po_paths_json"; then
        po_warn "issue=#${NUMBER} edit_paths sticky comment の保存に失敗（次サイクルで再評価 / Req 3.4 fail-open）"
      else
        po_log "issue=#${NUMBER} edit_paths persisted paths=$(echo "$_po_paths_json" | jq -r 'join(",")')"
      fi
    fi

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      local COMMENT
      COMMENT=$(jq -r '
        "## 🤔 実装着手前に確認が必要な事項\n\n" +
        "Issue 内容を Claude Code の Product Manager で精査した結果、" +
        "以下の判断は人間に委ねる必要があると判定しました。\n\n" +
        "> " + .rationale + "\n\n" +
        "---\n\n" +
        (.decisions | to_entries | map(
          "### " + ((.key + 1) | tostring) + ". " + .value.topic + "\n\n" +
          "**質問**: " + .value.question + "\n\n" +
          "**選択肢**:\n" +
          (.value.options | map("- " + .) | join("\n")) + "\n\n" +
          "**影響**: " + .value.impact + "\n\n" +
          "**推奨**: " + .value.recommendation + "\n"
        ) | join("\n---\n\n")) +
        "\n\n---\n\n" +
        "## 回答方法\n\n" +
        "1. 各項目についてこの Issue にコメントで回答してください。\n" +
        "2. すべての項目に結論が出たら、この Issue から **`needs-decisions` ラベルを外してください**。\n" +
        "3. ラベルが外れた時点で Claude Code が自動で再 Triage し、追加論点が無ければ開発に着手します。\n" +
        "4. Triage をスキップして強制着手したい場合は `skip-triage` ラベルを付与してください。"
      ' "$TRIAGE_FILE")

      gh issue comment "$NUMBER" --repo "$REPO" --body "$COMMENT" >/dev/null 2>&1 || true
      # Phase C / Issue #52: claim を取り消す（claude-claimed 除去）+ needs-decisions 付与。
      # 次サイクルで人間が needs-decisions を外したら再ピックアップされる必要があるため、
      # claim 系ラベルを残してはいけない。本機能導入前は claude-picked-up は未付与
      # だったが、Phase C 以降は Dispatcher が claim ラベル（Issue #52 で claude-claimed
      # に分離）を事前に付与しているためここで取り消す。
      gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1 || true
      echo "🟡 #$NUMBER: $DECISION_COUNT 件の決定事項を起票しました" | tee -a "$LOG"
      slot_log "Triage 結果: needs-decisions（claude-claimed 取り消し済）"
      return 0
    fi

    if [ "$NEEDS_ARCHITECT" = "true" ]; then
      MODE="design"
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      echo "✅ #$NUMBER: Triage 通過（Architect 不要） → impl モード" | tee -a "$LOG"
    fi
  fi

  # ── Issue #52: Triage 通過後のラベル付け替え（claude-claimed → claude-picked-up）──
  # impl / impl-resume モードでは、ここから先「実装フェーズ」に入るため Issue ラベルを
  # claude-picked-up に付け替える。design モードは PjM (design-review) が
  # claude-claimed → awaiting-design-review に直接付け替えるため、ここでは何もしない
  # （Req 8.3 / 設計論点 4 結論: design ルートは claude-picked-up を経由しない）。
  #
  # 単一の PATCH /issues/{n}（--remove-label A --add-label B）で原子的に行うことで
  # NFR 1.2（同時 2 ラベル状態が 5 秒以上続かない）を構造的に満たす。branch 作成より
  # 前に実行するため、後続の長時間操作中はラベル状態が常に正しい。
  if [ "$MODE" = "impl" ] || [ "$MODE" = "impl-resume" ]; then
    if ! gh issue edit "$NUMBER" --repo "$REPO" \
        --remove-label "$LABEL_CLAIMED" \
        --add-label "$LABEL_PICKED" >/dev/null 2>&1; then
      slot_warn "Triage 通過後のラベル付け替えに失敗（claude-claimed → claude-picked-up）"
      _slot_mark_failed "label-handover" "Triage 通過後のラベル付け替え (claude-claimed → claude-picked-up) に失敗しました。"
      return 1
    fi
    slot_log "ラベル付け替え: claude-claimed → claude-picked-up（impl 着手）"
  fi

  # ── ピックアップ表明コメント（claim 表明ラベルは Dispatcher が事前に付与済）──
  gh issue comment "$NUMBER" --repo "$REPO" \
    --body "🤖 ローカル Claude Code ($(hostname)) が処理を開始しました（slot=${IDD_SLOT_NUMBER} / モード: ${MODE}）。" >/dev/null 2>&1 || true

  # ── ブランチを切る（モードに応じて名前を変える）──
  case "$MODE" in
    design)
      BRANCH="claude/issue-${NUMBER}-design-${SLUG}"
      ;;
    impl|impl-resume)
      BRANCH="claude/issue-${NUMBER}-impl-${SLUG}"
      ;;
  esac
  # impl-resume モードのときだけ Strategy Pattern による branch 初期化に分岐させる
  # （Issue #67）。design / impl モードでは本機能導入前と完全に等価な挙動を維持する
  # （Req 1.1, 1.2, NFR 1.1, NFR 1.2）。`_resume_branch_init` は内部で
  # `IMPL_RESUME_PRESERVE_COMMITS` を見て legacy / preserve 戦略にディスパッチし、
  # 失敗時は `_slot_mark_failed` 既に発射済の状態で非 0 を返す。
  if [ "$MODE" = "impl-resume" ]; then
    # Issue #114 Req 2: origin の `claude/issue-<N>-impl-*` ブランチを resume 候補として
    # 検出するとき、ブランチ名のスラグ部と expected-slug を照合する。不一致時は
    # `_slug_mismatch_escalate` 経由で `needs-decisions` に倒し、本 Issue を skip する。
    # spec dir 経路で expected と一致した SLUG が確定済なので、ここで照合する expected は
    # `$SLUG` と同値（_normalize_slug の冪等性により）。
    if ! _resume_branch_assert_slug_match "$SLUG"; then
      return 1
    fi
    if ! _resume_branch_init; then
      return 1
    fi
  else
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
  fi

  # ── モード別ディスパッチ ──
  if [ "$MODE" = "design" ]; then
    # Issue #96 Req 1.5: 設計 PR 作成段階に進む前に BASE_BRANCH 実値が空でないことを検証する
    if ! _assert_base_branch_resolved; then
      echo "❌ #$NUMBER: design 中断（BASE_BRANCH 未解決）→ claude-failed" | tee -a "$LOG"
      _slot_mark_failed "design-base-branch" "解決済み BASE_BRANCH が空文字または未定義のため設計フェーズを中断しました（Issue #96 Req 1.5）。"
      return 1
    fi
    local FLOW_LABEL STEPS DEV_PROMPT
    FLOW_LABEL="PM → Architect → PjM（設計 PR 作成ゲート）"
    STEPS=$(cat <<EOF
1. product-manager サブエージェントで要件定義を \`${SPEC_DIR_REL}/requirements.md\` に保存
   - Issue 本文と既存コメント（\`gh issue view ${NUMBER} --comments\`）を必ず読む
   - 人間がコメントで回答済みの決定事項は requirements に反映する
2. architect サブエージェントで設計書とタスク分割を保存
   - Triage 判定理由: ${ARCHITECT_REASON}
   - \`${SPEC_DIR_REL}/design.md\`（モジュール構成・データモデル・公開 IF・処理フロー・リスク）
   - \`${SPEC_DIR_REL}/tasks.md\`（Developer 向けタスク分割、各タスクが独立コミット可能な粒度）
3. project-manager サブエージェントを **design-review モード** で起動
   - 成果物は ${SPEC_DIR_REL}/ 配下の requirements / design / tasks のみ（実装コードは含めない）
   - title: \`spec(#${NUMBER}): <1 行サマリ>\`
   - **base: \`${BASE_BRANCH}\`** （\`gh pr create --base ${BASE_BRANCH}\` を必ず明示すること。GitHub のデフォルト base に依存しない）
   - Issue ラベル: claude-claimed → awaiting-design-review に付け替え
   - Issue にコメントで設計 PR リンクと案内を投稿

この設計 PR が merge されるまで、実装フェーズには進みません。人間が merge した後、
次回のポーリングで Developer が自動起動し、実装 PR が別途作成されます。
EOF
)

    DEV_PROMPT=$(cat <<EOF
あなたはこのリポジトリの Claude Code オーケストレーターです。
以下の Issue を ${FLOW_LABEL} のフローで進めてください。

## 対象 Issue
- Number: #${NUMBER}
- Title : ${TITLE}
- URL   : ${URL}
- Body  : |
${BODY}

## 作業ブランチ
${BRANCH}（${BASE_BRANCH} から派生・push 済み・現在チェックアウト中）

## 作業ディレクトリ
${SPEC_DIR_REL}/

## PR の base ブランチ（必ず明示）
解決済み base ブランチ: \`${BASE_BRANCH}\`

PjM サブエージェント（design-review モード）は \`gh pr create\` 実行時に
**必ず \`--base ${BASE_BRANCH}\`** を明示してください（GitHub のデフォルト base に依存しないこと）。
これは本サイクル開始時に watcher が \`BASE_BRANCH\` env から解決した実値であり、プレースホルダ
ではありません。PR 作成後は \`gh pr view <PR> --json baseRefName --jq '.baseRefName'\` で
取得した値が \`${BASE_BRANCH}\` と一致することを検証し、結果（一致 / 不一致 / 修正実施の有無）を
PR 本文の「確認事項」または Issue コメントに 1 行記載してください。不一致時は
\`gh pr edit <PR> --base ${BASE_BRANCH}\` で修正するか、修正不能なら PR 作成失敗扱いとして
Issue に状況を報告してください。

## 進め方
${STEPS}

## 制約
- ${BASE_BRANCH} に直接 push しないこと
- **\`gh pr create\` の \`--base\` を省略しないこと**（GitHub default に依存すると本リポジトリの
  \`BASE_BRANCH\` 設定と乖離する事故が起きる。Issue #96）
- 既存のテストを壊さないこと
- 不明点は推測せず、PR 本文の「確認事項」セクションに列挙すること
EOF
)

    echo "--- Development 実行（$MODE）---" >> "$LOG"
    # Issue #66: Quota-Aware Watcher 経由で claude を起動
    local _qa_reset_file_design _qa_rc_design=0 _qa_ts_design
    _qa_ts_design=$(date +%Y%m%d-%H%M%S)
    _qa_reset_file_design="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-design-${_qa_ts_design}"
    qa_run_claude_stage "design" "$_qa_reset_file_design" -- \
      claude \
        --print "$DEV_PROMPT" \
        --model "$DEV_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$DEV_MAX_TURNS" \
        --output-format stream-json \
        --verbose \
        >> "$LOG" 2>&1 || _qa_rc_design=$?
    case "$_qa_rc_design" in
      0)
        echo "✅ #$NUMBER: $MODE 完了" | tee -a "$LOG"
        slot_log "$MODE 完了"
        # Issue #147: Tasks Count Gate — Architect 確定直後の tasks.md 件数を再評価し、
        # 8〜10 件で警告コメント、11 件以上で needs-decisions + Developer 抑止を適用。
        # 本機能は fail-open（戻り値は常に 0）かつ TC_ENABLED=false で完全 opt-out 可。
        # design 分岐 rc=0 case にのみ配置し、impl / impl-resume / Stage Checkpoint
        # Resume 経路には差し込まないことで Req 3.1 / 3.2 を構造的に保証する。
        tc_run_post_architect_check || true
        rm -f "$_qa_reset_file_design"
        return 0
        ;;
      99)
        local _qa_epoch_design
        _qa_epoch_design=$(cat "$_qa_reset_file_design")
        qa_handle_quota_exceeded "$NUMBER" "design" "$_qa_epoch_design"
        rm -f "$_qa_reset_file_design"
        slot_log "$MODE で quota 超過検出 → needs-quota-wait に遷移"
        return 0
        ;;
      *)
        rm -f "$_qa_reset_file_design"
        echo "❌ #$NUMBER: $MODE 失敗" | tee -a "$LOG"
        _slot_mark_failed "$MODE" "design モードでの Claude 実行が失敗しました。"
        return 1
        ;;
    esac
  else
    # impl / impl-resume → Reviewer ゲートを含む stage 分割パイプラインへ
    if run_impl_pipeline; then
      echo "✅ #$NUMBER: $MODE 完了（Reviewer ゲート通過 / PR 作成済み）" | tee -a "$LOG"
      slot_log "$MODE 完了（PR 作成済み）"
      return 0
    else
      echo "❌ #$NUMBER: $MODE 失敗（claude-failed 付与済み）" | tee -a "$LOG"
      slot_log "$MODE 失敗（claude-failed 付与済み）"
      return 1
    fi
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase C: Dispatcher
#
# 1 サイクル中に 1 度起動される。Issue 候補をローカルキューに pop し、空き slot を
# 探索して claim（claude-claimed ラベル付与）してから Slot Runner をバックグラウンド
# 起動する。サイクル終端で `wait` により全 Worker 完了を待ち合わせる。
# claim ラベルは Issue #52 で claude-picked-up → claude-claimed に変更した
# （claim/Triage 段階を実装中段階と区別するため）。Triage 通過後の Slot Runner で
# claude-claimed → claude-picked-up に付け替える。
#
# Req 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 6.3, 6.4, 6.5, 7.5, NFR 1.1, NFR 1.2
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Dispatcher が抱える slot_n -> PID マッピング（bash associative array, 4.0+）。
# サブシェル fork 後、_slot_release で fd を閉じてもこの map で「どの slot が誰の
# 子プロセスか」を後で再特定できる。
declare -A _DISPATCHER_SLOT_PIDS

# ── Issue #170 Req 3: Dispatcher のシグナル捕捉（SIGINT / SIGTERM）──
# cron/launchd からの中断や手動 Ctrl-C 時、fork 済み slot worker（サブシェル）が
# 孤立して `.broken-*` worktree が蓄積するのを防ぐための最小実装。
#
# 本 trap は Dispatcher トップレベル（メインスクリプト本体）に置く。サブシェル
# `( _slot_run_issue ... ) &` 内には伝播しない（trap はサブシェルでリセットされる）ため、
# 既存のサブシェル内ローカル EXIT trap（rebase/revert/checkout の base branch 復帰）の
# 挙動は一切変更しない（Req 3.4）。flock fd 200 は本プロセス終了時に OS が解放するため、
# 多重起動防止ロックの解放契約も従来どおり維持される（Req 3.3）。
#
# NFR 2.2: 同一シグナルが処理中に再送されても worktree prune を二重実行しないよう
# ガードフラグ _DISPATCHER_SIGNAL_HANDLED で 1 回に制限する。
_DISPATCHER_SIGNAL_HANDLED=0
# shellcheck disable=SC2317  # trap 経由で間接呼び出しされるため到達不能に見えるが正しく実行される
_dispatcher_on_signal() {
  local sig="$1"
  # 再入ガード（NFR 2.2）: 既に処理済みなら何もしない。
  if [ "$_DISPATCHER_SIGNAL_HANDLED" -ne 0 ]; then
    return 0
  fi
  _DISPATCHER_SIGNAL_HANDLED=1
  dispatcher_warn "シグナル ${sig} を受信。fork 済み slot worker を終了し worktree prune を実行します"

  # Req 3.1: fork 済みの slot worker 子プロセスへ終了シグナルを送る。
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done
  # 子プロセスの終了を回収（孤立防止）。reap 失敗は致命化させない。
  wait 2>/dev/null || true

  # Req 3.2 / NFR 2.2: worktree prune を 1 回だけ実行する。
  git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true

  # 中断由来の終了 exit code は 128+signal（bash 慣例）。SIGINT=130 / SIGTERM=143。
  local rc=143
  case "$sig" in
    INT) rc=130 ;;
    TERM) rc=143 ;;
  esac
  exit "$rc"
}
trap '_dispatcher_on_signal INT' INT
trap '_dispatcher_on_signal TERM' TERM

# 完了した子プロセスを slot_pid map から prune する。
# `kill -0 <pid>` が失敗（プロセス不在）なら slot は空いたとみなす。
_dispatcher_reap_finished_slots() {
  local n pid
  for n in "${!_DISPATCHER_SLOT_PIDS[@]}"; do
    pid="${_DISPATCHER_SLOT_PIDS[$n]}"
    if [ -z "$pid" ]; then
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      continue
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      # 子プロセス終了済 → slot 解放
      wait "$pid" 2>/dev/null || true
      unset '_DISPATCHER_SLOT_PIDS['"$n"']'
      dispatcher_log "slot-${n}: completed (pid=$pid)"
    fi
  done
}

# 空き slot を探す（reap → 1..PARALLEL_SLOTS で _slot_acquire）。
# 戻り値: 0 = 取得成功（slot 番号を stdout に echo） / 1 = 全 slot busy
_dispatcher_find_free_slot() {
  _dispatcher_reap_finished_slots
  local n
  for ((n=1; n<=PARALLEL_SLOTS; n++)); do
    # 既に PID マップに載っている slot は busy
    if [ -n "${_DISPATCHER_SLOT_PIDS[$n]:-}" ]; then
      continue
    fi
    if _slot_acquire "$n"; then
      echo "$n"
      return 0
    fi
  done
  return 1
}

# 1 サイクル分の Dispatcher を実行する。
# 戻り値: 0 = 正常完了（個々の Worker の成否は Issue ラベル経由で表現）/ 非ゼロ = 致命的失敗
_dispatcher_run() {
  # Req 1.3: PARALLEL_SLOTS 検証 → 不正なら ERROR ログ + exit 1
  if ! _parallel_validate_slots; then
    return 1
  fi

  # Req 7.5: 既存の Issue 取得クエリ（フィルタ・limit 5）を据え置き
  # Issue #54 Req 1.1 / 1.3 / 5.2: PR 専用ラベル `needs-iteration` が誤って Issue 側に
  # 付与されているケースを除外する（人為ミスでの impl-resume 起動 → 既存 PR 破壊事故防止）。
  # Issue #66 Req 3.5 / 3.6: quota wait 中の Issue は再 claim しないよう
  # `needs-quota-wait` を除外条件に追加。既存除外条件の意味・順序は変更しない。
  # Issue #100 Req 2.1: multi-branch 運用で develop に merge 済み・main 到達待ちの
  # Issue（`staged-for-release` 付与）を Triage / Dispatcher / PR Iteration が誤って
  # 再 pickup しないよう除外する。single-branch 運用では本ラベルは付与されない想定なので
  # 影響なし（NFR 1.2: 既存除外条件の意味・順序は変更しない）。
  # Issue #146: 依存 Issue 未 merge による blocked 状態を pickup 候補から除外する。
  # PM phase の Dependency Resolver Gate が付与し、人間が依存解消後に手動除去すると
  # 次サイクルで通常 pickup に再合流する（Req 4.1, 4.2）。既存除外ラベルとは独立した
  # 状態遷移を持ち、`needs-decisions` と並列指定する（Req 9.3 / NFR 1.3）。
  #
  # Issue #200: 候補処理順を FIFO（Issue 番号昇順 = 古いものから）にし、`hotfix`
  # ラベル付き Issue を非 hotfix より先に投入する 2 段優先を導入する。
  # `--limit 5`（= 1 サイクルで評価する候補件数上限）の意味は据え置く（Req 3.3）が、
  # 単純に「created-desc で 5 件切り出してから並べ替え」だと最も古い Issue や
  # 6 件目以降の hotfix を取りこぼす（Req 3.1 / 3.2）。これを避けるため:
  #   1) hotfix ティアを `sort:created-asc`（古いもの優先）で別クエリ取得し、
  #   2) 非 hotfix を含む全候補も `sort:created-asc` で取得する
  # 両クエリの除外フィルタ・取得フィールドは従来と完全同一。各クエリで `--limit` 件
  # ずつ取ることで、各ティアの「最も古い候補の先頭」が limit 切り出しから漏れない。
  # 取得後は jq で hotfix ティア優先 + 各ティア内 Issue 番号昇順に安定ソートし、
  # number で dedup したうえで先頭から $DISPATCH_LIMIT 件に切り詰める（NFR 2.1）。
  local search_filter="-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"$LABEL_BLOCKED\""
  # 1 サイクルで投入対象として評価する候補件数の上限（本機能導入前と同一の既定 5）。
  local DISPATCH_LIMIT=5

  local hotfix_issues all_issues
  # (1) hotfix ティア: created-asc で取得（最も古い hotfix を limit 切り出しで失わない）
  hotfix_issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --label "$LABEL_HOTFIX" \
    --state open \
    --search "$search_filter sort:created-asc" \
    --json number,title,body,url,labels \
    --limit "$DISPATCH_LIMIT")
  # (2) 全候補（hotfix / 非 hotfix 混在）: created-asc で取得（最も古い Issue を失わない）
  all_issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --state open \
    --search "$search_filter sort:created-asc" \
    --json number,title,body,url,labels \
    --limit "$DISPATCH_LIMIT")

  # 両クエリ結果を結合し、hotfix ティア優先 + 各ティア内 Issue 番号昇順で安定ソート、
  # number で dedup して先頭 $DISPATCH_LIMIT 件に切り詰める。
  # - `.labels` 欠落 / null や label 配列に hotfix 名が無い候補は安全側で非 hotfix 扱い（Req 2.4）。
  # - hotfix ティアを 0、非 hotfix を 1 とし、(tier, number) の昇順で並べることで
  #   Req 2.1 / 2.2 / 2.3（hotfix 先行・同一ティア内 number 昇順）を満たす。
  local issues
  issues=$(jq -c -n \
    --argjson limit "$DISPATCH_LIMIT" \
    --arg hotfix "$LABEL_HOTFIX" \
    --slurpfile hf <(printf '%s' "$hotfix_issues") \
    --slurpfile al <(printf '%s' "$all_issues") '
    ([ $hf[0][]?, $al[0][]? ])
    | map(. + { _is_hotfix: ((.labels // []) | map(.name) | index($hotfix) != null) })
    | unique_by(.number)
    | sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])
    | .[0:$limit]
    | map(del(._is_hotfix))
  ')

  local count
  count=$(echo "$issues" | jq 'length')
  if [ "$count" -eq 0 ]; then
    # Req 1.4 / 7.6: PARALLEL_SLOTS=1 + 対象なし時の挙動を本機能導入前と同等に保つ。
    # （prefix dispatcher: は付くが、メッセージ本体は既存と同じ）
    echo "[$(date '+%F %T')] 処理対象の Issue なし"
    return 0
  fi

  # Req 6.3: サイクル開始ログ（処理対象件数 + 利用可能 slot 数）
  dispatcher_log "対象 Issue ${count} 件 / 利用可能 slot ${PARALLEL_SLOTS} 件"

  # Req 1.4 互換のため、PARALLEL_SLOTS=1 のときも従来と同じ（prefix なし）件数 echo を出す。
  # 既存ユーザー / cron の grep 監視を破壊しない（"N 件の Issue を処理します" 行）。
  if [ "$PARALLEL_SLOTS" -eq 1 ]; then
    echo "[$(date '+%F %T')] $count 件の Issue を処理します"
  fi

  # Issue キューを 1 件ずつ pop して slot に投入
  local issue
  while IFS= read -r issue; do
    [ -z "$issue" ] && continue
    local issue_number
    issue_number=$(echo "$issue" | jq -r '.number')

    # ── Pre-Claim Filter (Issue #65 Req 1.1〜1.7) ──
    # claim 直前に linked impl PR を GraphQL で確認し、OPEN/MERGED が存在すれば
    # 当該サイクルを skip する。claim ラベル（claude-claimed）を一切付与しないため、
    # 次サイクル以降の `gh issue list` フィルタからも除外されず、人間が PR を解消
    # するか `auto-dev` を外すまで本 Issue を触らない（事故防止 / Req 1.2 / 1.3）。
    # check_existing_impl_pr 内で skip 判定行は pclp_log/warn で記録済み（NFR 2.1〜2.3）。
    # GraphQL 失敗 / レート制限も内部で skip 側に倒される（fail-safe / Req 1.7 / NFR 4.2）。
    # PR 不在の通常運用では exit 0 で素通り = 本機能導入前と完全等価（NFR 1.5）。
    if ! check_existing_impl_pr "$issue_number"; then
      continue
    fi

    # ── Open Design PR Guard (Issue #191 Req 1〜4) ──
    # claim 直前に、対象 Issue 番号に対応する head ブランチ
    # `claude/issue-<N>-design-*` の OPEN な PR が存在するかを確認し、存在すれば
    # 当該サイクルを skip する。check_existing_impl_pr が impl PR のみを対象とし
    # design PR を ignore するため（reason=design-pr-in-closing-refs）、保護ラベル
    # （awaiting-design-review / blocked）が外れた状態で open design PR を持つ Issue が
    # 再 pickup され、design モード再実行で PjM が人間レビュー済み design PR を
    # クローズして作り直す事故（#180 / PR #184）を構造的に防ぐ（二重防御 / Req 2）。
    # linked 非依存の head ref strict 一致で検出（Req 1.4 / 1.5）。検出失敗 / timeout /
    # レート制限は内部で skip 側に倒される（fail-safe / Req 3.1 / 3.2）。skip 判定行は
    # pclp_log/warn で記録済み（Req 4.1 / 4.2）。design PR を持たない通常 Issue では
    # open design PR 不在で exit 0 = 本機能導入前と完全等価（NFR 1.1）。本ガードは
    # Issue pickup 経路にのみ作用し、PR 駆動の design PR 反復経路には触れない（Req 5）。
    if ! check_open_design_pr "$issue_number"; then
      continue
    fi

    # ── Phase E: Path Overlap Gate (#18 Req 1.x / 5.x / 6.x) ──
    # PATH_OVERLAP_CHECK=true のときのみ有効。未設定 / off / 不正値では関数冒頭で
    # 早期 return 0 = 従来挙動と完全一致（NFR 1.1）。
    # `awaiting-slot` 付き Issue を candidate query から除外していないため、本 gate が
    # 後続 cron tick でも再評価され、overlap empty なら同サイクル内に
    # po_clear_awaiting_slot → claim 続行する（Req 6.1 / 6.2 / 6.4 を構造的に保証）。
    local labels_json
    labels_json=$(echo "$issue" | jq -c '.labels')
    if ! po_check_dispatch_gate "$issue_number" "$labels_json"; then
      continue
    fi

    # ── 空き slot 探索（busy なら 1 件完了するまで待機）──
    local slot=""
    while true; do
      if slot=$(_dispatcher_find_free_slot); then
        break
      fi
      # 全 slot busy → 1 件完了を待つ（bash 4.3+ の `wait -n`）
      if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -eq 0 ]; then
        # 子プロセス未起動かつ全 slot 取得失敗 → 取れる slot がない異常事態
        # （他 watcher プロセスが slot lock を握っているなど）
        dispatcher_warn "全 slot がロック中（_slot_acquire いずれも失敗）。Issue #${issue_number} は次サイクルへ持ち越し"
        slot=""
        break
      fi
      wait -n 2>/dev/null || true
      _dispatcher_reap_finished_slots
    done

    if [ -z "$slot" ]; then
      continue
    fi

    # ── claim（claude-claimed ラベル付与）──
    # Issue #52: claim/Triage 段階のラベルを claude-claimed に分離（claude-picked-up は
    # Triage 通過後に Slot Runner が付け替える）。これにより Issue activity 上で
    # claim 済 / Triage 中 / 実装中 が 1 ラベル単位で識別可能になる。
    if ! gh issue edit "$issue_number" --repo "$REPO" --add-label "$LABEL_CLAIMED" >/dev/null 2>&1; then
      # Req 2.3: ラベル付与失敗 → WARN + slot lock 解放 + 次 Issue へ
      dispatcher_warn "Issue #${issue_number}: claude-claimed ラベル付与に失敗、slot-${slot} を解放して次 Issue へ"
      _slot_release "$slot"
      continue
    fi

    # Req 6.4: 投入時刻ログ
    dispatcher_log "dispatched #${issue_number} -> slot-${slot}"

    # ── Slot Runner をバックグラウンド起動 ──
    # サブシェル `( ... ) &` で fork。サブシェルは親の fd を継承するため
    # _slot_acquire で取得した lock fd は subshell が引き続き保持する。
    ( _slot_run_issue "$slot" "$issue" ) &
    local pid=$!
    _DISPATCHER_SLOT_PIDS[$slot]=$pid

    # 親 Dispatcher 側の fd を解放する。これにより、Dispatcher が同 slot を再
    # acquire しようとしたとき、subshell が lock を保持している間は flock -n が
    # 失敗するようになる（claim atomicity の構造的保証）。
    _slot_release "$slot"
  done <<< "$(echo "$issues" | jq -c '.[]')"

  # Req 2.6: サイクル終端で全 Worker を待ち合わせる
  # Slot Runner 内で claude-failed 化等は完結済のため exit code は無視
  if [ "${#_DISPATCHER_SLOT_PIDS[@]}" -gt 0 ]; then
    dispatcher_log "全 Worker 完了を待機中 (${#_DISPATCHER_SLOT_PIDS[@]} 件 in flight)"
    wait
    _dispatcher_reap_finished_slots
  fi

  dispatcher_log "サイクル完了"
  return 0
}

# Dispatcher を起動（既存 Issue 処理ループの置換）。
_dispatcher_run
DISPATCHER_RC=$?
if [ "$DISPATCHER_RC" -ne 0 ]; then
  # Req 1.3: PARALLEL_SLOTS 不正値などで _dispatcher_run が non-zero を返した場合は
  # サイクル中断（既存の ERROR 終了規約 = exit 1 と整合）
  exit "$DISPATCHER_RC"
fi

echo "[$(date '+%F %T')] 完了"
exit 0

