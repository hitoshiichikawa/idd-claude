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
LABEL_NEEDS_REBASE="needs-rebase"
LABEL_NEEDS_ITERATION="needs-iteration"
LABEL_NEEDS_QUOTA_WAIT="needs-quota-wait"
LABEL_STAGED_FOR_RELEASE="staged-for-release"
# Phase B: ST failure 検知後 revert 済みを示すラベル（Req 4.1）。
LABEL_ST_FAILED="st-failed"
# Phase E: hot file 競合予防で同サイクル dispatch を見送り中（#18 Req 7.1）。
# Path Overlap Checker が付与・除去し、先行 Issue の PR merge で in-flight 集合から
# 外れた次サイクルで自動除去される（Req 6.1〜6.4）。
LABEL_AWAITING_SLOT="awaiting-slot"
# Issue #146: 依存 Issue 未 merge により auto-dev 進行不能であることを示すラベル。
# PM phase（Triage 起動前）の Dependency Resolver Gate が Issue 本文の依存記法
# （canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:`）を解析して、
# 未解決依存が 1 件でも残る場合に付与する。dispatcher pickup 除外条件に追加され、
# 人間が依存を解消後、本ラベルを手動除去すれば次サイクルで再評価される。
# 既存 `needs-decisions`（汎用人間判断要求）とは意味的に独立した運用シグナル
# （Req 9.1〜9.4）。
LABEL_BLOCKED="blocked"

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
if [ "${PR_ITERATION_MAX_ROUNDS+x}" = "x" ]; then
  PR_ITERATION_MAX_ROUNDS_LEGACY_SET="true"
else
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
# 前提ツールチェック
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
for cmd in gh jq claude git flock timeout; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "Error: $cmd が見つかりません。PATH を確認してください。" >&2
    exit 1
  }
done

[ -f "$TRIAGE_TEMPLATE" ] || {
  echo "Error: Triage テンプレートが見つかりません: $TRIAGE_TEMPLATE" >&2
  exit 1
}

# PR Iteration が有効化されている時のみ template の存在を必須化（opt-in gate）。
# 無効化（既定）時は template 未配置でも watcher 全体を起動できるよう、無条件チェックを避ける。
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
# Quota-Aware Watcher Helpers (#66)
#   Claude Max の 5 時間ローリング quota 超過を、Stage 実行中の claude CLI が出す
#   `rate_limit_event` (status=exceeded) JSON で検知する。検知時は当該 Issue を
#   `needs-quota-wait` 状態にし、reset 予定時刻を Issue body の hidden marker として
#   永続化。次サイクル以降の Quota Resume Processor が reset+grace 経過した Issue
#   からラベルを除去して通常 pickup ループに戻す。
#
#   QUOTA_AWARE_ENABLED=false（明示 opt-out）では本セクションの全関数は呼ばれるが、
#   gate 早期 return で副作用を一切起こさない。Stage Wrapper も `"$@"` 素通しで
#   本機能導入前と 100% 互換（Req 1.1, NFR 2.1）。#112 でデフォルトは true に反転。
#
#   設計参照: docs/specs/66-feat-watcher-claude-max-quota-rate-limit/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# quota-aware 専用ロガー（既存 mq_log / pi_log と同形式 / NFR 1.1, 1.2）
# Issue #119 Req 1.5 / 1.6 / NFR 2.2: 時刻 prefix と processor prefix の間に
# `[$REPO]` を 1 つだけ挿入し、複数リポ運用時に `grep "\[owner/name\]"` で
# 該当 repo のサイクル全行を抽出できるようにする。`[$REPO]` 以外のフォーマット
# は本要件導入前と完全に同一（Req 2.4）。
qa_log() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: $*"
}
qa_warn() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: WARN: $*" >&2
}
qa_error() {
  echo "[$(date '+%F %T')] [$REPO] quota-aware: ERROR: $*" >&2
}

# epoch 秒 → ISO 8601 (タイムゾーン付き) 文字列。GNU date / BSD date 両対応。
# 失敗時は epoch をそのまま返す（escalation コメントの整合性維持）。
# Args: $1 = epoch seconds (integer)
# Stdout: ISO 8601 string with TZ offset (e.g. "2026-04-29T15:00:00+09:00")
qa_format_iso8601() {
  local epoch="$1"
  local out=""
  # GNU date (Linux): -d @epoch -Iseconds
  if out=$(date -d "@${epoch}" -Iseconds 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # BSD date (macOS): -r epoch +format
  if out=$(date -r "${epoch}" "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null) && [ -n "$out" ]; then
    printf '%s' "$out"
    return 0
  fi
  # フォールバック: epoch をそのまま返す
  printf '%s' "$epoch"
}

# stdin の stream-json（1 行 1 JSON）を fold し、quota 枯渇イベントを検出して
# `<detection_path>\t<reset_epoch>` 形式の TSV を 1 検出 1 行で stdout に出力する
# （Req 1.1〜1.4, 2.1〜2.2, 3.1〜3.4, 5.1〜5.4 / Issue #66 Req 2.x との後方互換）。
#
# 検出経路（detection_path フィールド値）:
#   - `rate_limit_event_v2`  : 現行 Claude CLI スキーマ
#                              `type==rate_limit_event` かつ
#                              `rate_limit_info.status == "rejected"`
#                              （Issue #104 Bug 1 / Req 1.1）
#   - `rate_limit_event_v1`  : 旧スキーマ
#                              `type==rate_limit_event` かつ `status == "exceeded"`
#                              （Req 2.1 / Issue #66 互換維持）
#   - `synthetic_429_result` : quota 枯渇直撃時の synthetic result 行
#                              `type==result` かつ `is_error == true` かつ
#                              `api_error_status == 429`
#                              （Issue #104 Bug 2 / Req 3.1）
#
# Reset 時刻フィールド探索順（現行 / 旧スキーマ揺れと synthetic 429 同居を許容）:
#   1) .rate_limit_info.resetsAt / .resets_at / .reset_at  （現行スキーマ ネスト位置 / Req 1.3）
#   2) .resetsAt / .reset_at / .resets_at                  （旧スキーマ top-level / Req 2.2）
#   値の型が数値ならそのまま epoch、ISO 8601 文字列なら `fromdateiso8601` で epoch 化。
#   いずれも取得できなければ空（呼び出し側で reset 欠落 fallback / Req 1.4, 3.2）。
#
# 出力契約:
#   - 1 検出 1 行: `<detection_path>\t<epoch_or_empty>`
#   - 解析失敗（非 JSON / schema 違い）の行は無視して継続（Req 2.5 / Issue #66）
#   - allowed のみ / 通常 result（is_error:false）は無視（Req 3.4）
#   - 同一 stream に複数検出があっても全件出力（呼び出し側で `tail -1` 等を選択）
#
# 実装メモ: jq は default だと stdin を "concatenated JSON" として一括 parse する
# ため、無効な 1 行があると stream 全体が fatal で止まる。stream を停止させない
# 要件（Req 2.5）を満たすため、`-R`（raw input）で 1 行ずつ受け取り、各行を
# `try fromjson catch null` で個別 parse する。
qa_detect_rate_limit() {
  jq -R -r '
    # 入力 1 行を JSON object に折りたたむ。fromjson 失敗 / 非 object は捨てる。
    . as $line
    | (try ($line | fromjson) catch null)
    | select(type == "object") as $j

    # detection_path を 3 経路で識別（先頭で優先度を決定し、最初に match した
    # 経路を採用）。マッチしなければ empty で当該行を捨てる。
    | (
        if ($j.type? == "rate_limit_event")
           and (($j.rate_limit_info? // {}).status? == "rejected") then
          "rate_limit_event_v2"
        elif ($j.type? == "rate_limit_event")
             and ($j.status? == "exceeded") then
          "rate_limit_event_v1"
        elif ($j.type? == "result")
             and ($j.is_error? == true)
             and ($j.api_error_status? == 429) then
          "synthetic_429_result"
        else
          empty
        end
      ) as $path

    # reset epoch 候補値: 現行スキーマ ネスト → 旧スキーマ top-level の順で探索。
    # 値が無ければ null を bind（empty を bind すると jq 仕様により当該行が消える）。
    | (
        ($j.rate_limit_info? // {})
        | (.resetsAt // .resets_at // .reset_at // null)
      ) as $nested
    | (
        $j
        | (.resetsAt // .reset_at // .resets_at // null)
      ) as $top
    | (if $nested != null then $nested else $top end) as $raw

    # epoch 化: number はそのまま floor、string は ISO 8601 → epoch、それ以外は空。
    | (
        if $raw == null then ""
        elif ($raw | type) == "number" then ($raw | floor | tostring)
        elif ($raw | type) == "string" then
          (try ($raw | fromdateiso8601 | tostring)
            catch (try ($raw | tonumber | floor | tostring) catch ""))
        else "" end
      ) as $epoch_str

    # 出力: <detection_path>\t<epoch_or_empty>
    | "\($path)\t\($epoch_str)"
  ' 2>/dev/null
}

# 既存 6 stage の claude 呼び出しを横断ラップする Stage Wrapper（Req 1.1, 1.2,
# 2.1, NFR 2.1）。
#
# 引数: <stage_label> <reset_file> -- claude <claude args...>
# Returns:
#   0     : claude 正常終了 + quota 検出なし（既存挙動互換）
#   99    : quota 検出（reset epoch が $reset_file に書かれている）
#   N≠0,99: claude 自体の非ゼロ exit（quota 以外の失敗、既存フロー委譲）
#
# 副作用:
#   - $LOG（呼び出し側で設定済み）に stream 出力を追記
#   - $reset_file は空（quota 検出なし）または epoch 1 行
qa_run_claude_stage() {
  local stage_label="$1"
  local reset_file="$2"
  shift 2
  # 引数 separator '--' を skip
  if [ "${1:-}" = "--" ]; then
    shift
  fi

  # opt-out: 既存挙動の素通し実行。tee も解析も走らない（Req 1.1, NFR 2.1）。
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    "$@"
    return $?
  fi

  # opt-in: stream-json を tee で 2 系統に分岐
  #   系統 1: 既存 $LOG への append（観測ログを破壊しない）
  #   系統 2: qa_detect_rate_limit への pipe → 検出 TSV を中間ファイルに書き出し
  : > "$reset_file"
  local detect_file="${reset_file}.detect"
  : > "$detect_file"
  qa_log "stage start label=$stage_label"

  # set -e / pipefail 配下で個別の非 0 exit を握り潰すため、PIPESTATUS を即座に
  # 配列コピーしてから判断する。`|| true` は PIPESTATUS を 0 で上書きしてしまう
  # ため使えない（Issue #104 で発覚 / 既存 Issue #66 実装の latent bug 修正）。
  # set +e/-e で囲って pipefail 起因の即時 exit を一時的に抑止し、
  # PIPESTATUS[0] = claude 本体 exit code を確実に取り出す。
  local claude_rc=0
  set +e
  "$@" 2>&1 | tee -a "$LOG" | qa_detect_rate_limit > "$detect_file"
  local _qa_pipestatus=("${PIPESTATUS[@]}")
  set -e
  claude_rc="${_qa_pipestatus[0]:-0}"

  # 検出 TSV を解釈する。
  # 優先順位:
  #   1) epoch を持つ検出のうち最新行を採用 → exit 99 経路（reset 永続化に必要）
  #   2) 1 が無く epoch なし検出のみある場合 → 既存フロー fallback + warn
  #      （quota 枯渇は事実だが reset 不明では Resume Processor が機能しないため、
  #      claude_rc を透過。Stage C は別途 PR 実在 verify で虚偽成功を防ぐ /
  #      Req 1.4 / Req 3.2 / Issue #66 後方互換）
  #   3) 検出ゼロ → claude_rc 透過
  if [ -s "$detect_file" ]; then
    local _epoch_line _path _epoch
    _epoch_line=$(awk -F '\t' 'NF >= 2 && $2 ~ /^[0-9]+$/ { last = $0 } END { print last }' "$detect_file")
    if [ -n "$_epoch_line" ]; then
      _path="${_epoch_line%%$'\t'*}"
      _epoch="${_epoch_line#*$'\t'}"
      _epoch=$(printf '%s' "$_epoch" | tr -d '[:space:]')
      printf '%s\n' "$_epoch" > "$reset_file"
      qa_log "stage detected exceeded label=$stage_label path=${_path} reset_epoch=$_epoch"
      rm -f "$detect_file"
      return 99
    fi

    # epoch 付き検出ゼロだが、検出経路だけは観測できたケース
    local _last_line
    _last_line=$(tail -1 "$detect_file")
    _path="${_last_line%%$'\t'*}"
    qa_warn "stage detected without reset label=$stage_label path=${_path} (既存フローに委譲 / claude_rc=$claude_rc)"
    : > "$reset_file"
  fi
  rm -f "$detect_file"
  return "$claude_rc"
}

# Issue body の hidden marker として reset 予定時刻を 1 件のみ保持する形で
# 永続化する（Req 4.1, 4.3）。既存 marker 行があれば全削除してから新値を追記。
#
# Args: $1 = issue number, $2 = reset epoch (integer)
# Return: 0 = persisted, 1 = gh failure (warn only, do not fail caller)
qa_persist_reset_time() {
  local issue_number="$1"
  local epoch="$2"
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' 2>/dev/null); then
    return 1
  fi
  # 既存 marker 行を全削除（複数あったとしても落とす）
  local cleaned
  cleaned=$(printf '%s\n' "$body" | sed -E '/<!-- idd-claude:quota-reset:[0-9]+:v1 -->/d')
  # body 末尾を空行 1 つで区切って marker を 1 行追記
  local new_body
  new_body=$(printf '%s\n\n<!-- idd-claude:quota-reset:%s:v1 -->' "$cleaned" "$epoch")
  if ! gh issue edit "$issue_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Issue body から hidden marker を読み出して reset epoch を返す（Req 4.2, 4.4）。
# marker 不在 / 不正値 / API 失敗いずれの場合も数値以外を返さない。
#
# Args: $1 = issue number
# Stdout: epoch (integer) on success, empty on failure
# Return: 0 = found, 1 = absent or malformed (caller must skip removal)
qa_load_reset_time() {
  local issue_number="$1"
  local body
  if ! body=$(gh issue view "$issue_number" --repo "$REPO" --json body --jq '.body' 2>/dev/null); then
    return 1
  fi
  local epoch
  epoch=$(printf '%s' "$body" \
    | sed -nE 's/.*<!-- idd-claude:quota-reset:([0-9]+):v1 -->.*/\1/p' \
    | tail -1)
  if [[ "$epoch" =~ ^[0-9]+$ ]]; then
    printf '%s' "$epoch"
    return 0
  fi
  return 1
}

# escalation コメント本文を組み立てる（design.md 「Escalation Comment Template」を逐語使用）。
# Args: $1 = stage label, $2 = epoch, $3 = ISO 8601 string
# Stdout: コメント本文（markdown）
qa_build_escalation_comment() {
  local stage_label="$1" epoch="$2" iso8601="$3"
  cat <<EOF
## ⏸️ Claude Max quota exceeded（quota wait）

watcher が \`${stage_label}\` 実行中に Claude CLI から \`rate_limit_event (status=exceeded)\` を検知しました。
当該 Issue を一時的に **\`needs-quota-wait\`** 状態にしています。Claude Max の 5 時間ローリング quota
が reset された後、watcher が自動的に通常 pickup ループへ戻します。

### 検知情報

- 検知 Stage: \`${stage_label}\`
- reset 予定時刻 (UNIX epoch): \`${epoch}\`
- reset 予定時刻 (ISO 8601): \`${iso8601}\`
- 適用 grace 秒数: \`${QUOTA_RESUME_GRACE_SEC}\` 秒（reset 後この秒数を経過するまで pickup を抑止）

### 自動復帰の条件

- 次サイクルの Quota Resume Processor が、現在時刻が \`reset 予定時刻 + grace\` を超えていることを
  検知すると、\`needs-quota-wait\` ラベルを自動除去します
- ラベル除去後の cron tick で Dispatcher が通常 pickup 候補として再選定します
- \`claude-failed\` ラベルは付与していません（quota 起因と他失敗の混同を避けるため、Req 3.2）

### 手動介入したい場合

- 即時再開: \`needs-quota-wait\` ラベルを手動で外すと次サイクルで pickup されます
- quota 起因でないと判断する場合: 当該 Issue body の \`<!-- idd-claude:quota-reset:...:v1 -->\` 行を
  削除した上で \`needs-quota-wait\` を \`claude-failed\` に手動付け替えしてください

---

_本コメントは Quota-Aware Watcher（Issue #66）が自動投稿しました。_
EOF
}

# ─── build_partial_escalation_comment <status_code> <impl_notes_path> <tasks_md_path> <branch> ───
#
# Partial Status Gate (#148) のエスカレーションコメント本文を組み立てる純粋関数。
# 副作用なし。本関数は stdout に markdown 本文を出力するのみで、`gh issue comment` 呼出は
# 呼出側（handle_partial_status / mark_issue_needs_decisions）の責務。
#
# 入力:
#   $1 = status_code         ("partial_blocked" または "partial_overrun")
#   $2 = impl_notes_path     (Halt 理由抽出元 / impl-notes.md)
#   $3 = tasks_md_path       (残タスク fallback / tasks.md)
#   $4 = branch              (push 済み branch 名)
#
# 出力構造（Req 4.1〜4.5 / NFR 2.2 をすべてカバー）:
#   1. 識別 HTML コメント `<!-- idd-claude:partial-status:STATUS -->`（本文先頭 / NFR 2.2）
#   2. h2 タイトル（status code 別の固定文言）
#   3. ## 検知情報（status / branch / Issue 番号）
#   4. ## Halt 理由 — impl-notes.md `## Partial Halt Reason` セクションを引用
#   5. ## Push 済み commit 一覧 — git log --oneline ${BASE_BRANCH}..HEAD
#   6. ## 残タスク一覧 — impl-notes.md `## Pending Tasks` セクション優先、なければ tasks.md
#      の `- [ ]` 行を fallback 抽出
#   7. ## 推奨アクション — 固定リスト（依存 Issue 先行 / Issue 分割 / 手動続行）
#   8. ## 次の手順 — `needs-decisions` 除去で次サイクル自動 pickup される旨
#   9. footer — 本コメントが #148 由来である旨
#
# Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, NFR 2.2
build_partial_escalation_comment() {
  local status_code="$1"
  local impl_notes_path="$2"
  local tasks_md_path="$3"
  local branch="$4"

  # ── status 別のタイトル ──
  local title
  case "$status_code" in
    partial_blocked)
      title="⏸️ Developer が partial_blocked を報告しました（外部依存で進行不能）"
      ;;
    partial_overrun)
      title="⏸️ Developer が partial_overrun を報告しました（turn budget 残量不足）"
      ;;
    *)
      title="⏸️ Developer が partial 状態を報告しました（${status_code}）"
      ;;
  esac

  # ── Halt 理由抽出（impl-notes.md の `## Partial Halt Reason` セクション本文） ──
  # awk で「## Partial Halt Reason」見出しから次の `## ` 見出しまでを抽出
  # （見出し行自体は含めない / 末尾の空行も保持）。ファイル不在時は空文字。
  local halt_reason=""
  if [ -f "$impl_notes_path" ]; then
    halt_reason=$(awk '
      /^## Partial Halt Reason[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$impl_notes_path" 2>/dev/null || true)
  fi
  if [ -z "$halt_reason" ]; then
    halt_reason="(impl-notes.md に \`## Partial Halt Reason\` セクションが見つかりませんでした)"
  fi

  # ── push 済み commit 一覧（${BASE_BRANCH}..HEAD） ──
  # git log は REPO_DIR で実行する前提（呼出側の `cd` 不要設計のため明示）。失敗時は空文字。
  local commit_list=""
  if [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ]; then
    commit_list=$(git -C "$REPO_DIR" log --oneline "${BASE_BRANCH}..HEAD" 2>/dev/null || true)
  fi
  if [ -z "$commit_list" ]; then
    commit_list="(${BASE_BRANCH}..HEAD に commit がありません / または git log 取得に失敗しました)"
  fi

  # ── 残タスク一覧（impl-notes.md `## Pending Tasks` 優先、なければ tasks.md fallback） ──
  local pending=""
  if [ -f "$impl_notes_path" ]; then
    pending=$(awk '
      /^## Pending Tasks[[:space:]]*$/ { in_section=1; next }
      in_section && /^## / { exit }
      in_section { print }
    ' "$impl_notes_path" 2>/dev/null || true)
  fi
  if [ -z "$pending" ] && [ -f "$tasks_md_path" ]; then
    # fallback: tasks.md の `- [ ]` 未完了行を抽出（`- [ ]*` deferrable も含む）
    pending=$(grep -E '^- \[ \]\*? ' "$tasks_md_path" 2>/dev/null || true)
  fi
  if [ -z "$pending" ]; then
    pending="(残タスクが特定できませんでした。\`${SPEC_DIR_REL:-docs/specs/<N>-<slug>}/tasks.md\` を直接確認してください)"
  fi

  # ── 本文組立（heredoc） ──
  cat <<EOF
<!-- idd-claude:partial-status:${status_code} -->

## ${title}

watcher が Stage A 完了直後の Partial Status Gate (#148) で Developer の自己宣言を検出しました。
当該 Issue は \`needs-decisions\` 状態に切り替わり、人間判断（依存解消 / Issue 分割 / 手動続行）を
仰ぐフローに入ります。Reviewer は **起動されません**。

### 検知情報

- 報告された status code: \`${status_code}\`
- 対象 branch: \`${branch}\`
- 対象 Issue: #${NUMBER:-(unknown)}

## Halt 理由

${halt_reason}

## Push 済み commit 一覧

\`\`\`
${commit_list}
\`\`\`

## 残タスク一覧

\`\`\`
${pending}
\`\`\`

## 推奨アクション

partial の種別に応じて以下のいずれかを選択してください:

- **依存 Issue を先に進める**: \`partial_blocked\` で halt 理由が「未 merge の依存 Issue」の
  場合は、当該 Issue を先に解決後、本 Issue の \`needs-decisions\` を除去して再 pickup させる
- **Issue を分割する**: 残タスクが本 Issue の本来 scope を超えていると判断した場合、サブ Issue
  を起票して残タスクを移送し、本 Issue は close または scope を縮小して continue
- **手動で続行する**: \`partial_overrun\` で turn budget 不足だった場合、当該 branch を手動
  checkout して残タスクを実装し、commit + push 後に \`needs-decisions\` を除去する

## 次の手順

人間判断で対処方針を決めた後、Issue から \`needs-decisions\` ラベルを除去してください。
次の watcher サイクルで本 Issue は通常 pickup 候補として再評価され、自動進行が再開されます。

---

_本コメントは Partial Status Gate (#148) が自動投稿しました。_
EOF
}

# quota 検知時の副作用（永続化 → ラベル付け替え → escalation コメント → ログ）を
# 1 関数で原子的に実行する（Req 3.1, 3.2, 3.3, 3.4, 3.7, 4.1, NFR 1.1, 1.2）。
# `claude-failed` は **付与しない**（Req 3.2）。
#
# Args: $1 = issue number, $2 = stage label, $3 = reset epoch
# Return: 0 always（副作用失敗は warn でログ、呼び出し側はラベル付与済み前提で続行）
qa_handle_quota_exceeded() {
  local issue_number="$1" stage_label="$2" epoch="$3"
  local iso8601
  iso8601=$(qa_format_iso8601 "$epoch")

  # 1. 永続化（失敗してもラベル付与に進む。次 tick で再判定可能）
  if ! qa_persist_reset_time "$issue_number" "$epoch"; then
    qa_warn "issue=$issue_number stage=$stage_label reset 永続化に失敗（ラベル付与は継続）"
  fi

  # 2. ラベル付け替え（claude-claimed / claude-picked-up を除去 → needs-quota-wait 付与。
  #    claude-failed は付与しない / Req 3.2）
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" \
      --remove-label "$LABEL_PICKED" \
      --add-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label ラベル付け替えに失敗"
  fi

  # 3. escalation コメント
  local comment_body
  comment_body=$(qa_build_escalation_comment "$stage_label" "$epoch" "$iso8601")
  if ! gh issue comment "$issue_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    qa_warn "issue=$issue_number stage=$stage_label escalation コメント投稿に失敗"
  fi

  # 4. ログ（NFR 1.1, 1.2 / grep 可能形式）
  qa_log "exceeded issue=#$issue_number stage=$stage_label reset_epoch=$epoch reset_iso=$iso8601 grace_sec=$QUOTA_RESUME_GRACE_SEC"
  return 0
}

# Quota Resume Processor: cron tick 冒頭で `needs-quota-wait` 付き Issue を走査し、
# reset+grace 経過分のラベルを自動除去する（Req 5.1〜5.6, NFR 3.1〜3.3）。
#
# - opt-out 時は即時 return 0（NFR 2.1）
# - 0 件時は API 1 回で return 0（NFR 3.1）
# - 各 Issue で reset 取得失敗 / 不正値はラベル維持（Req 4.4）
# - API 失敗は warn 吸収して return 0 を保証（Req 5.6）
process_quota_resume() {
  if [ "$QUOTA_AWARE_ENABLED" != "true" ]; then
    return 0
  fi
  qa_log "Resume Processor 開始 (grace=${QUOTA_RESUME_GRACE_SEC}s)"

  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
        --label "$LABEL_NEEDS_QUOTA_WAIT" --state open \
        --json number --limit 50 2>/dev/null); then
    qa_warn "needs-quota-wait Issue 取得に失敗（後続 Processor 継続）"
    return 0
  fi

  local count
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  if [ "$count" -eq 0 ]; then
    qa_log "対象 Issue なし"
    return 0
  fi

  local now_epoch
  now_epoch=$(date -u +%s)

  local issue_number reset_epoch threshold
  while IFS= read -r issue_number; do
    [ -z "$issue_number" ] && continue
    if ! reset_epoch=$(qa_load_reset_time "$issue_number"); then
      qa_warn "issue=$issue_number reset 時刻読み出し失敗 → ラベル維持（Req 4.4）"
      continue
    fi
    threshold=$((reset_epoch + QUOTA_RESUME_GRACE_SEC))
    if [ "$now_epoch" -lt "$threshold" ]; then
      qa_log "issue=#$issue_number waiting reset_epoch=$reset_epoch now=$now_epoch wait_sec=$((threshold - now_epoch))"
      continue
    fi
    if gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_NEEDS_QUOTA_WAIT" >/dev/null 2>&1; then
      qa_log "resumed issue=#$issue_number reset_epoch=$reset_epoch reset_iso=$(qa_format_iso8601 "$reset_epoch") elapsed_sec=$((now_epoch - reset_epoch))"
    else
      qa_warn "issue=$issue_number ラベル除去に失敗（次サイクルで再評価）"
    fi
  done < <(printf '%s' "$issues_json" | jq -r '.[].number')

  return 0
}

# Quota Resume Processor を全 Processor の先頭で実行する（Req 5.1, 5.6 / NFR 3.2）。
# 失敗時も後続 Processor を阻害しないよう || qa_warn で吸収。
process_quota_resume || qa_warn "process_quota_resume が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Processor
#   approve 済み open PR の mergeability を能動的に検知し:
#     - CONFLICTING: needs-rebase ラベル + 状況コメント（人間判断に回す）
#     - MERGEABLE かつ base が古い: ローカルで自動 rebase + force-with-lease push
#   標準機能としてデフォルト有効（#112）。無効化は MERGE_QUEUE_ENABLED=false で明示。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #119 Req 1.2 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
mq_log() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: $*"
}
mq_warn() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: WARN: $*" >&2
}
mq_error() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue: ERROR: $*" >&2
}

# PR ラベル一覧に特定ラベルが含まれるかを判定（jq で labels 配列を走査）
mq_pr_has_label() {
  local pr_json="$1"
  local label="$2"
  echo "$pr_json" | jq -e --arg l "$label" '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# CONFLICTING PR にラベル + 状況コメントを投稿（重複抑止つき）
# 失敗しても次の PR に進むよう、戻り値ではなく内部で WARN を出す
mq_handle_conflict() {
  local pr_number="$1"
  local pr_json="$2"
  local pr_url
  pr_url=$(echo "$pr_json" | jq -r '.url')

  # AC 2.2: 既に needs-rebase が付いている場合はラベル付与/コメントとも skip
  if mq_pr_has_label "$pr_json" "$LABEL_NEEDS_REBASE"; then
    mq_log "PR #${pr_number}: CONFLICTING (already labeled, skip)"
    return 0
  fi

  # AC 2.4: conflict したファイル粒度を含めるため、PR の変更ファイル一覧を取得。
  # mergeable=CONFLICTING の段階では merge できないため、簡易的に PR の files
  # 一覧（最大 50 件）をコメントに含める。Phase B 以降で staging branch 経由の
  # 真の conflict ファイル特定に置き換える前提。
  local files_json
  if ! files_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json files 2>/dev/null); then
    files_json='{"files":[]}'
  fi
  local files_md
  files_md=$(echo "$files_json" | jq -r '
    (.files // []) | map("- `" + .path + "`") |
    if length == 0 then "_(変更ファイル一覧の取得に失敗しました)_"
    elif length > 50 then (.[0:50] | join("\n")) + "\n- _(他 " + ((length - 50) | tostring) + " 件)_"
    else join("\n") end
  ')

  local comment_body
  comment_body=$(cat <<EOF
## 🔀 自動マージ前 conflict 検知 (Phase A)

approve 済みの本 PR について、watcher が \`${MERGE_QUEUE_BASE_BRANCH}\` との merge 試行で **conflict** を検知しました。
\`needs-rebase\` ラベルを付与しています。

### 推奨アクション

- 手動で base を最新化してください（例: \`gh pr checkout ${pr_number} && git pull --rebase origin ${MERGE_QUEUE_BASE_BRANCH} && git push --force-with-lease\`）
- または semantic conflict の自動解消を待ちたい場合は Phase D（#17）の導入を検討してください

### 変更ファイル（参考）

実際の conflict 範囲は \`git merge-tree\` 等で確認してください。本 PR が触っているファイルの一覧:

${files_md}

---

_本コメントは Phase A Merge Queue Processor が自動投稿しました。conflict が解消し \`needs-rebase\` ラベルが手動で外されると、次回サイクルで再度判定されます。_
EOF
)

  # AC 2.1: needs-rebase 付与
  if ! gh pr edit "$pr_number" --repo "$REPO" --add-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
    # AC 2.5: ラベル付与失敗 → WARN、後続 PR は継続
    mq_warn "PR #${pr_number}: needs-rebase ラベル付与に失敗"
    return 1
  fi
  # AC 2.3: ステータスコメント 1 件投稿
  if ! gh pr comment "$pr_number" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1; then
    # AC 2.5: コメント投稿失敗 → WARN、後続 PR は継続（ラベルは残す）
    mq_warn "PR #${pr_number}: 状況コメント投稿に失敗（ラベルは付与済み）"
    return 1
  fi
  mq_log "PR #${pr_number}: CONFLICTING -> labeled+commented (${pr_url})"
  return 0
}

# MERGEABLE PR を最新の base に自動 rebase して force-with-lease push する。
# 失敗したら needs-rebase に格下げする。サブシェルで実行し、trap で必ず base branch に戻す。
# 戻り値: 0=rebase+push 成功, 1=conflict 経由 needs-rebase 化, 2=その他失敗（push 失敗等）
mq_try_rebase_pr() {
  local pr_number="$1"
  local head_ref="$2"
  local base_ref="$3"
  local pr_json="$4"

  (
    set +e
    # サブシェル終了時は必ず元の base branch checkout に戻す（NFR 2.2）
    # shellcheck disable=SC2064
    trap "git rebase --abort >/dev/null 2>&1; git checkout '${MERGE_QUEUE_BASE_BRANCH}' >/dev/null 2>&1" EXIT

    # AC 3.1 / 3.5: 既に祖先関係を満たしているなら rebase 不要
    if git merge-base --is-ancestor "origin/${base_ref}" "origin/${head_ref}" 2>/dev/null; then
      exit 10  # skip 用の特別 exit code
    fi

    # head ブランチを fresh に checkout（既存ローカルブランチがあれば force リセット）
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git checkout -B "$head_ref" "origin/${head_ref}" >/dev/null 2>&1; then
      mq_warn "PR #${pr_number}: head branch '${head_ref}' の checkout に失敗"
      exit 2
    fi

    # AC 3.1: rebase 試行
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" git rebase "origin/${base_ref}" >/dev/null 2>&1; then
      # AC 3.3: conflict なら abort して needs-rebase 化
      git rebase --abort >/dev/null 2>&1 || true
      exit 1
    fi

    # AC 3.2 / NFR 2.1: 安全な force push
    if ! timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$head_ref" >/dev/null 2>&1; then
      # AC 3.4: push 失敗（リモート先行等）→ WARN、当該 PR をスキップ
      mq_warn "PR #${pr_number}: force-with-lease push に失敗（リモートが進んだ可能性）"
      exit 2
    fi
    exit 0
  )
  local rc=$?
  # サブシェル外でも安全側に倒して base branch に戻す（AC 3.6 / NFR 2.2）
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true

  case $rc in
    0)
      mq_log "PR #${pr_number}: MERGEABLE stale -> rebase+push OK"
      return 0
      ;;
    1)
      # rebase conflict → needs-rebase 化
      mq_handle_conflict "$pr_number" "$pr_json"
      return 1
      ;;
    10)
      mq_log "PR #${pr_number}: MERGEABLE up-to-date (skip rebase)"
      return 10
      ;;
    *)
      return 2
      ;;
  esac
}

process_merge_queue() {
  # AC 5.1: opt-out gate
  if [ "$MERGE_QUEUE_ENABLED" != "true" ]; then
    return 0
  fi

  # NFR 2.3: 想定外の dirty working tree を検知したら ERROR を出してサイクル中止
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    mq_error "dirty working tree を検出しました。Merge Queue Processor をスキップします。"
    return 0
  fi

  mq_log "サイクル開始 (max=${MERGE_QUEUE_MAX_PRS}, base=${MERGE_QUEUE_BASE_BRANCH}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.2 / 1.3 / 1.4 / 1.6 / 1.7: approved かつ needs-rebase / claude-failed が付いていない
  # 非 draft の PR。さらに head branch が MERGE_QUEUE_HEAD_PATTERN に合致し、
  # head repo owner が base repo owner と同一（= fork PR を除外）のものに限定。
  # GitHub search 構文で server side フィルタ（API call 削減・NFR 1.2）
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved -label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,mergeStateStatus,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 50 2>/dev/null); then
    mq_warn "approved PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # クライアント側フィルタ:
  #   - isDraft / reviewDecision の再確認（server filter の保険）
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_MAX_PRS))
    # AC 4.3: 上限超過分は次回に持ち越し
    mq_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 6.1: サイクル開始時に件数をログ
    mq_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local rebased=0
  local conflicted=0
  local skipped=0
  local failed=0

  # 先頭 N 件のみ処理（後ろは持ち越し）
  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  # AC 4.3: target_count > 0 なので pr_iter は最低 1 行を持つ前提だが、念のため空ガード
  if [ -z "$pr_iter" ]; then
    mq_log "サマリ: rebase+push=0, conflict=0, skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable merge_state url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    merge_state=$(echo "$pr_json" | jq -r '.mergeStateStatus')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 1.5 / 6.2: 各 PR の mergeable 判定をログ
    mq_log "PR #${pr_number}: mergeable=${mergeable}, state=${merge_state}, head=${head_ref}, base=${base_ref}"

    case "$mergeable" in
      CONFLICTING)
        if mq_handle_conflict "$pr_number" "$pr_json"; then
          conflicted=$((conflicted + 1))
        else
          failed=$((failed + 1))
        fi
        ;;
      MERGEABLE)
        # PR の base ref が対象 base ブランチ以外なら自動 rebase の対象外（安全側）
        if [ "$base_ref" != "$MERGE_QUEUE_BASE_BRANCH" ]; then
          mq_log "PR #${pr_number}: base=${base_ref} は ${MERGE_QUEUE_BASE_BRANCH} 以外、自動 rebase スキップ"
          skipped=$((skipped + 1))
          continue
        fi
        local rc=0
        mq_try_rebase_pr "$pr_number" "$head_ref" "$base_ref" "$pr_json" || rc=$?
        case $rc in
          0)  rebased=$((rebased + 1)) ;;
          1)  conflicted=$((conflicted + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
        ;;
      UNKNOWN|"")
        # GitHub が mergeable を未計算の場合は次回サイクルに委ねる
        mq_log "PR #${pr_number}: mergeable 未確定 (${mergeable:-null})、次回サイクルに委ねます"
        skipped=$((skipped + 1))
        ;;
      *)
        mq_log "PR #${pr_number}: 未知の mergeable=${mergeable} (${url})、スキップ"
        skipped=$((skipped + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 6.3: サマリ行
  mq_log "サマリ: rebase+push=${rebased}, conflict=${conflicted}, skip=${skipped}, fail=${failed}, overflow=${skipped_overflow}"

  # AC 3.6 / NFR 2.2: 念のため最終確認で base branch checkout に戻す
  git checkout "$MERGE_QUEUE_BASE_BRANCH" >/dev/null 2>&1 || true
}

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

# auto-rebase 専用ロガー（Phase A `mq_log` と同一の `[$REPO]` 3 段 prefix）。
# Issue #119 Req 1.x: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
ar_log() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: $*"
}
ar_warn() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: WARN: $*" >&2
}
ar_error() {
  echo "[$(date '+%F %T')] [$REPO] auto-rebase: ERROR: $*" >&2
}

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
      --json number,headRefName,baseRefName,labels,url,isDraft,reviewDecision,headRepositoryOwner,title \
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
# ar_apply_semantic: semantic 判定時の副作用を実行。
#   1. ar_dismiss_all_approvals で approve を全件 dismiss
#   2. needs-rebase 除去
#   3. ready-for-review 付与
#   4. 説明コメント投稿（rebase 実施 / semantic 判定 / dismissal / 再レビュー誘導）
#
#   入力: $1=pr_number, $2=pr_url, $3=before_sha, $4=after_sha,
#         $5=first_unmatched_path（空可）
#   戻り値:
#     0 : 全成功
#     1 : dismissal 失敗（呼び出し側で escalate `dismissal-failed` 経路）
#     2 : label / comment 失敗（部分成功、WARN 後 semantic 扱いは継続）
#
#   Req 7.1, 7.2, 7.3, 7.4
# ─────────────────────────────────────────────────────────────────────────────
ar_apply_semantic() {
  local pr_number="$1"
  local pr_url="$2"
  local before_sha="$3"
  local after_sha="$4"
  local first_unmatched="${5:-}"

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

  local pr_number head_ref base_ref pr_url pr_title
  pr_number=$(echo "$pr_json" | jq -r '.number')
  head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
  base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
  pr_url=$(echo "$pr_json"    | jq -r '.url')
  pr_title=$(echo "$pr_json"  | jq -r '.title // ""')

  # 1. Claude rebase を試行
  local rebase_output rebase_rc=0
  rebase_output=$(ar_run_claude_rebase "$pr_number" "$pr_title" "$pr_url" "$head_ref" "$base_ref") || rebase_rc=$?

  case "$rebase_rc" in
    0)
      # 成功（rebase + push 完了）。後続で分類へ進む
      ;;
    5)
      # rebase 不要（既に base が head の祖先）。Re-check が拾うべきケースとして skip
      ar_log "PR #${pr_number}: rebase 不要（already up-to-date with base, skip）action=skip url=${pr_url}"
      return 10
      ;;
    1)
      ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
      ar_log "PR #${pr_number}: classification=failed reason=conflict-unresolved action=escalate url=${pr_url}"
      return 2
      ;;
    2)
      ar_escalate_to_failed "$pr_number" "timeout" || true
      ar_log "PR #${pr_number}: classification=failed reason=timeout action=escalate url=${pr_url}"
      return 2
      ;;
    3)
      ar_escalate_to_failed "$pr_number" "push-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=push-failed action=escalate url=${pr_url}"
      return 2
      ;;
    4)
      ar_escalate_to_failed "$pr_number" "fetch-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=fetch-failed action=escalate url=${pr_url}"
      return 2
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "conflict-unresolved" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown(rc=${rebase_rc}) action=escalate url=${pr_url}"
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
  ar_apply_semantic "$pr_number" "$pr_url" "$before_sha" "$after_sha" "$first_unmatched" || semantic_rc=$?
  case "$semantic_rc" in
    0)
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} unmatch=${first_unmatched:-(unknown)} action=dismissed+ready url=${pr_url}"
      return 1
      ;;
    1)
      # dismissal 失敗 → escalate
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=dismissal-failed before=${before_sha} after=${after_sha} action=escalate url=${pr_url}"
      return 2
      ;;
    2)
      # label / comment の部分失敗。dismissal は成功しているので semantic 扱いを維持
      ar_log "PR #${pr_number}: classification=semantic before=${before_sha} after=${after_sha} action=dismissed+partial-fail url=${pr_url}"
      return 1
      ;;
    *)
      ar_escalate_to_failed "$pr_number" "dismissal-failed" || true
      ar_log "PR #${pr_number}: classification=failed reason=unknown-semantic(rc=${semantic_rc}) action=escalate url=${pr_url}"
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
  ar_log "サイクル開始 (mode=${AUTO_REBASE_MODE}, paths=${MECHANICAL_PATHS:-(empty)}, max_prs=${AUTO_REBASE_MAX_PRS}, model=${AUTO_REBASE_MODEL}, max_turns=${AUTO_REBASE_MAX_TURNS}, timeout=${AUTO_REBASE_MAX_TURNS_SEC}s)"

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

  if [ "$target_count" -gt 0 ]; then
    local pr_iter
    pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

    if [ -n "$pr_iter" ]; then
      while IFS= read -r pr_json; do
        local rc=0
        ar_handle_pr "$pr_json" || rc=$?
        case "$rc" in
          0)  mechanical=$((mechanical + 1)) ;;
          1)  semantic=$((semantic + 1)) ;;
          2)  failed=$((failed + 1)) ;;
          10) skipped=$((skipped + 1)) ;;
          *)  failed=$((failed + 1)) ;;
        esac
      done <<< "$pr_iter"
    fi
  fi

  # Req 3.4 / NFR 2.2: サマリ行 1 件
  ar_log "サマリ: mechanical=${mechanical}, semantic=${semantic}, failed=${failed}, skip=${skipped}, overflow=${skipped_overflow}"

  # NFR 5.2 / Phase A pattern: 念のため最終確認で base branch に戻す
  git checkout "$BASE_BRANCH" >/dev/null 2>&1 || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Phase A: Merge Queue Re-check Processor (#27)
#   `needs-rebase` 付き approved PR を別レーンで再評価し、`mergeable=MERGEABLE` に
#   戻った PR のラベルを自動除去する。Phase A 本体（process_merge_queue）とは
#   独立に制御可能。標準機能としてデフォルト有効化（#112）。無効化したい場合は
#   MERGE_QUEUE_RECHECK_ENABLED=false を明示する。ラベル除去のみを副作用とし、
#   再 rebase / コメント投稿は Phase A 本体に委譲。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# merge-queue-recheck 専用ロガー（Phase A 本体の `merge-queue:` と区別する prefix）。
# AC 5.5 / 5.6 / NFR 3.2: `merge-queue-recheck:` prefix と既存 timestamp 書式に統一。
# Issue #119 Req 1.3 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
mqr_log() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: $*"
}
mqr_warn() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: WARN: $*" >&2
}
mqr_error() {
  echo "[$(date '+%F %T')] [$REPO] merge-queue-recheck: ERROR: $*" >&2
}

process_merge_queue_recheck() {
  # AC 1.2 / 1.3 / 3.1 / 3.3: opt-in gate（MERGE_QUEUE_ENABLED とは独立）
  if [ "$MERGE_QUEUE_RECHECK_ENABLED" != "true" ]; then
    return 0
  fi

  mqr_log "サイクル開始 (max=${MERGE_QUEUE_RECHECK_MAX_PRS}, timeout=${MERGE_QUEUE_GIT_TIMEOUT}s)"

  # AC 1.4 / 1.5 / 1.6: approved かつ needs-rebase ラベル付き、claude-failed 無し、非 draft。
  # AC 4.3 / 4.4: server-side フィルタで API call を最小化、Phase A と同一 timeout を適用。
  local repo_owner="${REPO%%/*}"
  local prs_json
  if ! prs_json=$(timeout "$MERGE_QUEUE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "review:approved label:\"$LABEL_NEEDS_REBASE\" -label:\"$LABEL_FAILED\" -draft:true" \
      --json number,headRefName,baseRefName,mergeable,labels,url,isDraft,reviewDecision,headRepositoryOwner \
      --limit 100 2>/dev/null); then
    # AC 4.5: タイムアウト / エラー時は WARN を出して以降スキップ（後続処理は継続）
    mqr_warn "対象 PR 一覧の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # AC 1.5 / 1.6 / 1.7 / 1.8: クライアント側フィルタ（server filter の保険）
  #   - isDraft / reviewDecision の再確認
  #   - head ref prefix (MERGE_QUEUE_HEAD_PATTERN): 人間の手書き PR を巻き込まない
  #   - head repo owner == base repo owner: fork PR を除外
  prs_json=$(echo "$prs_json" | jq \
    --arg pattern "$MERGE_QUEUE_HEAD_PATTERN" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
      | select(.reviewDecision == "APPROVED")
      | select(.headRefName | test($pattern))
      | select((.headRepositoryOwner.login // "") == $owner)
    ]')

  local total
  total=$(echo "$prs_json" | jq 'length')
  local target_count="$total"
  local skipped_overflow=0
  if [ "$total" -gt "$MERGE_QUEUE_RECHECK_MAX_PRS" ]; then
    target_count="$MERGE_QUEUE_RECHECK_MAX_PRS"
    skipped_overflow=$((total - MERGE_QUEUE_RECHECK_MAX_PRS))
    # AC 4.2 / 5.1: 上限超過分は次回に持ち越し
    mqr_log "対象候補 ${total} 件中、上限 ${MERGE_QUEUE_RECHECK_MAX_PRS} 件のみ処理（${skipped_overflow} 件は次回持ち越し）"
  else
    # AC 5.1: サイクル開始時に件数をログ
    mqr_log "対象候補 ${total} 件、処理対象 ${target_count} 件"
  fi

  if [ "$target_count" -eq 0 ]; then
    # AC 5.4: サマリ行（ゼロ件でも明示）
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  local removed=0
  local conflicting=0
  local unknown_skip=0
  local failed=0

  local pr_iter
  pr_iter=$(echo "$prs_json" | jq -c ".[0:${target_count}][]")

  if [ -z "$pr_iter" ]; then
    mqr_log "サマリ: label-removed=0, conflicting=0, unknown-skip=0, fail=0, overflow=${skipped_overflow}"
    return 0
  fi

  while IFS= read -r pr_json; do
    local pr_number head_ref base_ref mergeable url
    pr_number=$(echo "$pr_json" | jq -r '.number')
    head_ref=$(echo "$pr_json"  | jq -r '.headRefName')
    base_ref=$(echo "$pr_json"  | jq -r '.baseRefName')
    mergeable=$(echo "$pr_json" | jq -r '.mergeable')
    url=$(echo "$pr_json" | jq -r '.url')

    # AC 5.2: 各 PR の mergeable 判定をログ（PR 番号 / mergeable / アクション）
    case "$mergeable" in
      MERGEABLE)
        # AC 2.1 / NFR 2.1: ラベル除去（唯一の副作用）。Phase A と同一 timeout を適用。
        if timeout "$MERGE_QUEUE_GIT_TIMEOUT" \
            gh pr edit "$pr_number" --repo "$REPO" --remove-label "$LABEL_NEEDS_REBASE" >/dev/null 2>&1; then
          # AC 2.2 / 5.3: 成功 INFO ログ（要件文言を含める）
          mqr_log "PR #${pr_number}: mergeable=MERGEABLE -> label removed (conflict resolved, re-evaluating next cycle) (${url})"
          removed=$((removed + 1))
        else
          # AC 2.6: ラベル除去 API がエラーを返した場合は WARN、後続 PR は継続
          mqr_warn "PR #${pr_number}: needs-rebase ラベル除去に失敗（${url}）"
          failed=$((failed + 1))
        fi
        ;;
      CONFLICTING)
        # AC 2.3 / NFR 2.2: 状態変更なし（再ラベル / コメント追記なし）
        mqr_log "PR #${pr_number}: mergeable=CONFLICTING -> kept (head=${head_ref}, base=${base_ref})"
        conflicting=$((conflicting + 1))
        ;;
      UNKNOWN|null|"")
        # AC 2.4 / NFR 2.2: UNKNOWN / null は次回サイクルに委ねる
        mqr_log "PR #${pr_number}: mergeable=${mergeable:-null} -> skip (next cycle)"
        unknown_skip=$((unknown_skip + 1))
        ;;
      *)
        # NFR 2.2: 未知の値もラベル除去を行わずスキップ
        mqr_log "PR #${pr_number}: mergeable=${mergeable} (未知) -> skip"
        unknown_skip=$((unknown_skip + 1))
        ;;
    esac
  done <<< "$pr_iter"

  # AC 5.4: サマリ行
  mqr_log "サマリ: label-removed=${removed}, conflicting=${conflicting}, unknown-skip=${unknown_skip}, fail=${failed}, overflow=${skipped_overflow}"
}

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
# Phase B: Promote Pipeline Processor (#15)
#   Phase A により `BASE_BRANCH` に merge された変更について、ST check-run 結果を
#   ポーリングし:
#     - success: `staged-for-release` 除去 + `PROMOTION_TARGET_BRANCH` への
#       fast-forward 昇格（PROMOTE_MODE に応じて即時／cron 一致時／on-demand）
#     - failure: `git revert -m 1` + Issue reopen + `st-failed` 付与（fail-continue）
#   新規 opt-in 機能。`PROMOTE_PIPELINE_ENABLED=true` を明示したリポジトリでのみ
#   起動し、未設定 / `false` のリポジトリは導入前と完全に同一の挙動を維持する
#   （Req 1.1, NFR 1.1）。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# promote-pipeline 専用ロガー（Phase A `mq_log` と同一の書式：
# `[YYYY-MM-DD HH:MM:SS] [$REPO] promote-pipeline:` prefix。Req 5.1.1, 5.1.5）。
pp_log() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: $*"
}
pp_warn() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: WARN: $*" >&2
}
pp_error() {
  echo "[$(date '+%F %T')] [$REPO] promote-pipeline: ERROR: $*" >&2
}

# ─── Phase E: Path Overlap Checker 専用ロガー (#18) ───
# 既存 pp_log / mq_log / drr_log と同じ書式（時刻 prefix + [$REPO] + processor prefix）。
# Req 8.1〜8.4: overlap 検出 / awaiting-slot 付与 / 除去のログを cron.log 経路に流す。
# `PATH_OVERLAP_CHECK=off` の場合は呼ばれないため、後方互換性は呼び出し側 gate で保証。
po_log() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: $*"
}
po_warn() {
  echo "[$(date '+%F %T')] [$REPO] path-overlap: WARN: $*" >&2
}

# ─── Phase E: Triage Edit-Paths Parser (#18 Req 2.4 / 2.5) ───
# Triage 結果 JSON から edit_paths 配列を fail-safe に抽出する。
# - key 不在 / null / 非配列 / 要素に文字列以外混入はすべて空配列にフォールバック
# - 既存 5 keys 抽出（jq -r '.status' 等）は変更しない（Req 2.5）
#
# Args: $1 = Triage 結果 JSON ファイルパス
# Stdout: JSON 配列文字列（必ず `[...]` 形式、空でも `[]`）
# Return: 0 always（失敗時は `[]` を返す fail-safe）
po_parse_triage_edit_paths() {
  local triage_file="$1"
  if [ ! -f "$triage_file" ]; then
    echo '[]'
    return 0
  fi
  # `// []` で key 不在を吸収、`if type=="array" then ... else [] end` で型不正吸収、
  # `map(select(type=="string"))` で文字列以外を除外。jq 失敗時も `[]` を返す。
  jq -c '
    (.edit_paths // [])
    | if type == "array" then
        map(select(type == "string"))
      else
        []
      end
  ' "$triage_file" 2>/dev/null || echo '[]'
}

# ─── Phase E: Path Overlap Persister (#18 Req 3.1〜3.4 / 12.1) ───
# Triage で得た edit_paths を Issue 上に sticky comment として保存する。同じ marker
# (<!-- idd-claude:edit-paths:v1 -->) を持つ既存コメントがあれば PATCH で上書き、
# 無ければ新規 create する（Req 3.3 重複防止）。
#
# 本文形式（人間可読 md リスト + 機械可読 hidden JSON marker の 2 段構成）:
#
#   ## Triage edit_paths（Phase E）
#
#   本 Issue が編集見込みの top-level path:
#
#   - `local-watcher/`
#   - `README.md`
#
#   *(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*
#
#   <!-- idd-claude:edit-paths:v1 -->
#   <!-- idd-claude:edit-paths-json:["local-watcher/","README.md"] -->
#
# Args: $1 = issue number, $2 = edit_paths JSON 配列文字列
# Return: 0 = persist OK / 1 = persist 失敗（呼び出し側は warn のみで Triage 全体は成功扱い）
po_persist_edit_paths() {
  local issue_number="$1"
  local edit_paths_json="$2"

  # 本文 md リストを組み立てる（空配列なら "なし" 表示）
  local list_md
  list_md=$(echo "$edit_paths_json" | jq -r '
    if length == 0 then
      "_(Triage は確信のある edit_paths を推定できませんでした)_"
    else
      map("- `" + . + "`") | join("\n")
    end
  ' 2>/dev/null || echo '_(edit_paths 抽出失敗)_')

  local marker_v1="<!-- idd-claude:edit-paths:v1 -->"
  local json_marker
  # JSON marker を 1 行に整形（jq -c で改行なしの compact 形式）
  json_marker="<!-- idd-claude:edit-paths-json:${edit_paths_json} -->"

  local body
  body=$(cat <<EOF
## Triage edit_paths（Phase E）

本 Issue が編集見込みの top-level path:

${list_md}

*(自動生成: Path Overlap Checker。本機能の詳細は README の「Phase E」節を参照)*

${marker_v1}
${json_marker}
EOF
)

  # 既存 sticky comment を gh API で検索（URL 末尾の `#issuecomment-<numeric-id>` から
  # REST API id を抽出。`.comments[].id` は GraphQL の base64 id なので使えない）。
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    return 1
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-claude:edit-paths:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi

  if [ -n "$existing_comment_id" ]; then
    # 既存 sticky comment を PATCH で上書き（Req 3.3）
    if ! gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
        -f body="$body" >/dev/null 2>&1; then
      return 1
    fi
  else
    # 新規作成
    if ! gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
      return 1
    fi
  fi
  return 0
}

# ─── Phase E: Path Overlap Loader (#18 Req 12.1) ───
# Issue の sticky comment から edit_paths JSON を読み出す。marker 不在 / API 失敗 /
# 形式異常はすべて空配列 `[]` を返す fail-safe。
# 1 candidate あたり gh issue view --json comments を **1 回のみ** 呼ぶ（Req 12.1）。
#
# Args: $1 = issue number
# Stdout: edit_paths JSON 配列文字列（必ず `[...]` 形式、抽出失敗時は `[]`）
# Return: 0 always
po_load_edit_paths() {
  local issue_number="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    echo '[]'
    return 0
  fi
  # 全コメントから marker 行を抽出 → JSON 部を取り出して valid array かチェック
  local extracted
  extracted=$(echo "$comments_json" \
    | jq -r '.comments // [] | map(.body) | .[]' 2>/dev/null \
    | sed -nE 's/.*<!-- idd-claude:edit-paths-json:(.*) -->.*/\1/p' \
    | tail -1)
  if [ -z "$extracted" ]; then
    echo '[]'
    return 0
  fi
  # extracted が valid な JSON 配列であることを jq で再検証してから返す
  local validated
  validated=$(echo "$extracted" | jq -c '
    if type == "array" then
      map(select(type == "string"))
    else
      []
    end
  ' 2>/dev/null || echo '[]')
  echo "$validated"
}

# ─── Phase E: In-Flight Collector (#18 Req 4.1〜4.4 / 5.3 / 8.1) ───
# 現サイクルの in-flight Issue（候補自身を除く）を gh で 1 回列挙し、各 Issue の
# edit_paths を読み出して **union 配列**と **path → holder Issue 番号配列の map**
# の両方を含む JSON object を返す。
#
# 戻り値の JSON object schema:
#   {
#     "union":   ["local-watcher/", "README.md"],         # 正規化前の paths を union
#     "holders": {                                          # 正規化前の path → holders
#       "local-watcher/": [39, 40],
#       "README.md":      [40]
#     }
#   }
#
# Note: holders map のキーは **正規化前の生 path**（in-flight Issue が persist した
# まま）。`po_check_dispatch_gate` 側で overlap path（正規化済 top-level）と
# 突合する際は同じ `normalize` 関数を holders map のキーにも適用してから引く。
#
# Req 12.1 補足: API 呼び出し回数は本拡張で増えていない。各 in-flight Issue について
# `po_load_edit_paths` を 1 回呼ぶのは従来同様で、その戻り値から union と holders map
# を同時に構築するだけ。candidate 側の `po_load_edit_paths` も 1 回のまま。
#
# in-flight 判定ラベル（Req 4.1）:
#   claude-claimed, claude-picked-up, awaiting-design-review, ready-for-review,
#   needs-iteration, needs-rebase, staged-for-release
# 除外（Req 4.2）: st-failed, awaiting-slot
# 候補自身を除外（Req 4.3）、同 repo のみ（Req 4.4: --repo "$REPO" 固定）
#
# Args: $1 = candidate issue number
# Stdout: JSON object `{"union": [...], "holders": {path: [issue#, ...]}}`
# Return: 0 = 列挙 OK / 1 = gh API 失敗（caller は fail-open で empty 扱い + warn）
po_collect_inflight_issues() {
  local candidate="$1"

  # 7 ラベルのいずれかを持ち、`st-failed` / `awaiting-slot` を持たない open Issue を
  # OR 検索で抽出する。`gh issue list --label A --label B` は AND になるため、
  # `--search 'label:A OR label:B OR ...'` 形式を使う（既存 Phase B / Phase D が同形式
  # を採用済）。
  local search_query
  search_query=$(cat <<EOF
is:open is:issue (label:"claude-claimed" OR label:"claude-picked-up" OR label:"awaiting-design-review" OR label:"ready-for-review" OR label:"needs-iteration" OR label:"needs-rebase" OR label:"staged-for-release") -label:"st-failed" -label:"awaiting-slot"
EOF
)
  local issues_json
  if ! issues_json=$(gh issue list --repo "$REPO" \
      --search "$search_query" \
      --json number \
      --limit 50 2>/dev/null); then
    return 1
  fi

  # 候補自身を除外（Req 4.3）、各 Issue について po_load_edit_paths を呼んで
  # union（unique 済 path 配列）と holders map（path → [issue#, ...]）を併走更新する。
  local accum
  accum='{"union": [], "holders": {}}'
  local n
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    if [ "$n" = "$candidate" ]; then
      continue
    fi
    local paths
    paths=$(po_load_edit_paths "$n")
    # accum := accum + (paths を union に merge / 各 path に対し holders[path] に n を追記)
    # holders は array で持ち、重複 issue# は jq の unique で抑止する。
    accum=$(jq -nc \
      --argjson acc "$accum" \
      --argjson paths "$paths" \
      --argjson holder "$n" '
      .union as $_ |
      $acc
      | .union = (.union + $paths | unique)
      | reduce $paths[] as $p (
          .;
          .holders[$p] = ((.holders[$p] // []) + [$holder] | unique)
        )
    ')
  done < <(echo "$issues_json" | jq -r '.[].number')

  echo "$accum"
  return 0
}

# ─── Phase E: Holder Resolver (#18 Req 5.3 / 8.1) ───
# overlap path（正規化済 top-level）と holders map（正規化前 path → [issue#, ...]）
# から、各 overlap path に対応する holder Issue 番号配列を解決する。
#
# 既存 `po_compute_overlap` の `normalize` 規約（先頭 `./` 剥がし / 連続スラッシュ
# 圧縮 / top-level セグメント + `/`）を holders map の生キーにも適用してから
# 突合する。
#
# Args: $1 = overlap JSON 配列（正規化済 top-level path 文字列）
#       $2 = holders map JSON（正規化前 path → [issue#, ...]）
# Stdout: JSON object `{overlap_path: [issue#, ...], ...}`
#         （overlap path はすべてキーに登場。holder が見つからない場合は空配列）
# Return: 0 always
po_resolve_overlap_holders() {
  local overlap_json="$1"
  local holders_json="$2"
  jq -nc \
    --argjson overlap "$overlap_json" \
    --argjson holders "$holders_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    # holders の生キーを normalize して bucket 化（同一 top-level に複数 raw path が
    # 寄ってきた場合は holders を merge して unique）
    ($holders | to_entries
      | map(.key |= normalize)
      | group_by(.key)
      | map({ key: .[0].key, value: (map(.value) | add | unique) })
      | from_entries
    ) as $bucket
    | reduce $overlap[] as $p (
        {};
        .[$p] = ($bucket[$p] // [])
      )
  '
}

# ─── Phase E: Holders Log Formatter (#18 Req 8.1) ───
# overlap-holders map から overlap log line 用の holders フィールド文字列
# （例: "#39,#40"）を生成する。重複 Issue# は除去、ソートして並び順を安定化。
#
# Args: $1 = overlap-holders map JSON（po_resolve_overlap_holders 出力）
# Stdout: "#<N>,#<M>,..." or "" (holders が 1 件も無い場合)
# Return: 0 always
po_format_holders_for_log() {
  local map_json="$1"
  echo "$map_json" | jq -r '
    [.[] | .[]] | unique | sort | map("#" + tostring) | join(",")
  ' 2>/dev/null || echo ""
}

# ─── Phase E: Overlap Table Markdown Formatter (#18 Req 5.3) ───
# overlap-holders map を sticky comment 本文の表形式 markdown に整形する。
# design.md「Awaiting-Slot Sticky Comment Format」（design.md:855-863）参照。
#
# 出力例:
#   | 重複 path | 保持中の Issue |
#   |---|---|
#   | `local-watcher/` | #39, #40 |
#   | `README.md` | #40 |
#
# Args: $1 = overlap-holders map JSON
# Stdout: markdown 表（先頭の見出し 2 行 + 各 overlap path 1 行）
# Return: 0 always
po_format_holders_table_md() {
  local map_json="$1"
  {
    echo '| 重複 path | 保持中の Issue |'
    echo '|---|---|'
    echo "$map_json" | jq -r '
      to_entries
      | sort_by(.key)
      | map(
          "| `" + .key + "` | " +
          (
            if (.value | length) == 0 then
              "_(holder 不明)_"
            else
              (.value | unique | sort | map("#" + tostring) | join(", "))
            end
          ) + " |"
        )
      | .[]
    ' 2>/dev/null
  }
}

# ─── Phase E: Overlap Engine (#18 Req 5.1 / 5.5 / 5.6) ───
# candidate と in-flight の path 配列の積集合を top-level 粒度で計算する。
#
# 正規化規約:
#   - 先頭 `./` を剥がす
#   - 連続スラッシュ `/+` を `/` 1 つに圧縮
#   - スラッシュを含むなら先頭セグメント + `/` を返す（ディレクトリ扱い）
#   - スラッシュを含まないならそのまま（ルート直下ファイル扱い）
#
# 例:
#   `local-watcher/bin/foo.sh` → `local-watcher/`
#   `README.md`                → `README.md`
#   `./docs/specs/18-foo/req.md` → `docs/`
#
# candidate が空配列なら常に積集合は空（Req 5.5 候補不在は dispatch 阻止しない）。
#
# Args: $1 = candidate edit_paths JSON 配列, $2 = in-flight union JSON 配列
# Stdout: 交差 JSON 配列（正規化済 top-level key、重複排除済）
# Return: 0 always
po_compute_overlap() {
  local cand_json="$1"
  local inflight_json="$2"
  jq -nc \
    --argjson c "$cand_json" \
    --argjson f "$inflight_json" '
    def normalize:
      sub("^\\./"; "")
      | gsub("/+"; "/")
      | if test("/") then
          (split("/")[0] + "/")
        else
          .
        end;
    ($c | map(normalize) | unique) as $cn
    | ($f | map(normalize) | unique) as $fn
    | $cn | map(select(. as $p | $fn | index($p)))
  '
}

# ─── Phase E: Awaiting Slot State Machine — apply (#18 Req 5.2 / 5.3 / 8.2) ───
# `awaiting-slot` ラベルを付与（冪等）し、説明 sticky comment を post / update する。
#
# sticky comment marker: <!-- idd-claude:awaiting-slot:v1 -->
# 同一 Issue に 1 件のみ。既存 marker 付きコメントがあれば PATCH で上書き、無ければ
# 新規 create する（cron tick ごとのノイズ累積を抑制）。
#
# 本文には Req 5.3 が要求する「どの path がどの in-flight Issue に保持されているか」
# を表形式（design.md「Awaiting-Slot Sticky Comment Format」L855-863 準拠）で表示する。
#
# Args: $1 = candidate issue number
#       $2 = overlap JSON 配列（正規化済 top-level path 文字列、後方互換用）
#       $3 = overlap-holders map JSON（path → [issue#, ...]、Req 5.3 holder 情報）
# Return: 0 = apply OK / 1 = 致命的失敗（呼び出し側 warn）
po_apply_awaiting_slot() {
  local issue_number="$1"
  local overlap_json="$2"
  local holders_map_json="${3:-}"

  # ラベル付与（冪等。既付与でも error にならない）
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --add-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    return 1
  fi
  po_log "awaiting-slot added candidate=#${issue_number}"

  # sticky comment 本文の組み立て
  # holders_map_json が与えられた場合は表形式（| 重複 path | 保持中の Issue |）で
  # 表示する（Req 5.3 + design.md L855-863）。未指定 / 空 map の場合は path のみの
  # md リストにフォールバック（後方互換）。
  local overlap_section
  if [ -n "$holders_map_json" ] && \
      [ "$(echo "$holders_map_json" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ]; then
    overlap_section=$(po_format_holders_table_md "$holders_map_json")
  else
    overlap_section=$(echo "$overlap_json" | jq -r '
      if length == 0 then
        "_(overlap path が空ですが本コメントが呼ばれました。状態不整合の可能性あり)_"
      else
        map("- `" + . + "`") | join("\n")
      end
    ' 2>/dev/null || echo '_(overlap 抽出失敗)_')
  fi

  local marker="<!-- idd-claude:awaiting-slot:v1 -->"
  local body
  body=$(cat <<EOF
## ⏸️ Dispatch を見送り中（Phase E Path Overlap Checker）

本 Issue が編集見込みの top-level path のうち、以下が現在 in-flight 中の他 Issue と重複しています。

${overlap_section}

先行 Issue の PR が merge されて in-flight 集合から外れた次サイクルで \`awaiting-slot\`
ラベルが自動除去され、本 Issue は通常 dispatch に戻ります。手動介入は不要です。

詳細は README の「Path Overlap Checker (Phase E)」節を参照してください。

${marker}
EOF
)

  # sticky 化: 既存 marker 付きコメントを検索 → あれば PATCH、無ければ新規 create
  local comments_json
  if ! comments_json=$(gh issue view "$issue_number" --repo "$REPO" --json comments 2>/dev/null); then
    # コメント取得失敗時は新規 create を試みる（best-effort）
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
    return 0
  fi
  local existing_url
  existing_url=$(echo "$comments_json" | jq -r '
    (.comments // [])
    | map(select(.body | contains("<!-- idd-claude:awaiting-slot:v1 -->")))
    | .[0].url // ""
  ' 2>/dev/null || echo "")
  local existing_comment_id=""
  if [ -n "$existing_url" ]; then
    existing_comment_id=$(printf '%s' "$existing_url" \
      | sed -nE 's/.*#issuecomment-([0-9]+)$/\1/p')
  fi
  if [ -n "$existing_comment_id" ]; then
    gh api -X PATCH "/repos/${REPO}/issues/comments/${existing_comment_id}" \
      -f body="$body" >/dev/null 2>&1 || true
  else
    gh issue comment "$issue_number" --repo "$REPO" --body "$body" >/dev/null 2>&1 || true
  fi
  return 0
}

# ─── Phase E: Awaiting Slot State Machine — clear (#18 Req 6.2 / 6.4 / 8.3) ───
# `awaiting-slot` ラベルを除去する（冪等）。説明 sticky comment は事後監査用に残置する。
#
# Args: $1 = candidate issue number
# Return: 0 = clear OK / 1 = ラベル除去失敗（呼び出し側 warn → 次サイクルで再試行）
po_clear_awaiting_slot() {
  local issue_number="$1"
  if ! gh issue edit "$issue_number" --repo "$REPO" \
      --remove-label "$LABEL_AWAITING_SLOT" >/dev/null 2>&1; then
    return 1
  fi
  po_log "awaiting-slot cleared candidate=#${issue_number} (overlap empty)"
  return 0
}

# ─── Phase E: Dispatcher Integration Point (#18 Req 1.1〜1.4 / 5.x / 6.x / 12.2) ───
# _dispatcher_run の candidate ループ内、check_existing_impl_pr 通過直後・
# _dispatcher_find_free_slot 呼び出し前に挿入する gate 関数。
#
# 関数冒頭で `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0` で opt-in gate を成立
# させ、未設定 / off / 不正値（True / 1 / typo 等）は早期 return 0 = 従来挙動と
# 完全一致（Req 1.2 / 1.3 / NFR 1.1）。
#
# Args: $1 = candidate issue number, $2 = candidate labels JSON
#       （gh issue list の `.labels` フィールドを jq -c で取り出したもの）
# Return: 0 = claim を続行してよい / 1 = この cycle では dispatch skip（continue）
po_check_dispatch_gate() {
  local candidate="$1"
  local labels_json="$2"

  # Req 1.2 / 1.3 / 1.4: opt-in gate（厳密一致 "true" のみ通す）
  [ "$PATH_OVERLAP_CHECK" = "true" ] || return 0

  # 候補の edit_paths を sticky から読む（Req 5.5: marker 不在は空配列扱い）
  local cand_paths
  cand_paths=$(po_load_edit_paths "$candidate")

  # in-flight union + holders map を取得（Req 4.1〜4.4 / 5.3 / 8.1）。
  # 失敗時は fail-open で claim 続行
  local inflight_obj
  if ! inflight_obj=$(po_collect_inflight_issues "$candidate"); then
    po_warn "issue=#${candidate} in-flight 列挙に失敗、本サイクルは overlap 判定を skip して claim 続行"
    return 0
  fi
  local inflight_paths inflight_holders
  inflight_paths=$(echo "$inflight_obj" | jq -c '.union // []' 2>/dev/null || echo '[]')
  inflight_holders=$(echo "$inflight_obj" | jq -c '.holders // {}' 2>/dev/null || echo '{}')

  # overlap 計算（Req 5.1 / 5.6）
  local overlap overlap_count
  overlap=$(po_compute_overlap "$cand_paths" "$inflight_paths")
  overlap_count=$(echo "$overlap" | jq 'length' 2>/dev/null || echo 0)

  # 現状の awaiting-slot ラベル付与状態（既存 labels_json から抽出）
  local has_awaiting
  has_awaiting=$(echo "$labels_json" \
    | jq -r --arg lbl "$LABEL_AWAITING_SLOT" \
        '[.[].name] | index($lbl) // empty' 2>/dev/null || echo "")

  if [ "$overlap_count" -gt 0 ]; then
    # Req 5.2 / 5.3 / 8.1 / 8.2: overlap 検出ログ（holders を含める）→ awaiting-slot
    # 付与（未付与時のみ）。holders は overlap path（正規化済 top-level）ごとに
    # in-flight Issue 番号配列を解決し、log では unique sort で平坦化する。
    local overlap_holders_map holders_for_log paths_for_log
    overlap_holders_map=$(po_resolve_overlap_holders "$overlap" "$inflight_holders")
    holders_for_log=$(po_format_holders_for_log "$overlap_holders_map")
    paths_for_log=$(echo "$overlap" | jq -r 'join(",")')
    if [ -n "$holders_for_log" ]; then
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=${holders_for_log}"
    else
      # holders が空（in-flight が close 直後 / holder 不明等）でも paths は記録し、
      # holders=「-」で出力して欠落の事実をログに残す
      po_log "overlap detected candidate=#${candidate} paths=${paths_for_log} holders=-"
    fi
    if [ -z "$has_awaiting" ]; then
      if ! po_apply_awaiting_slot "$candidate" "$overlap" "$overlap_holders_map"; then
        po_warn "issue=#${candidate} awaiting-slot 付与 / コメント投稿に失敗（次サイクルで再評価）"
      fi
    fi
    return 1  # dispatch skip
  fi

  # overlap 空: Req 6.2 / 6.4 / 8.3 自然解消
  if [ -n "$has_awaiting" ]; then
    if ! po_clear_awaiting_slot "$candidate"; then
      po_warn "issue=#${candidate} awaiting-slot 除去に失敗（次サイクルで再試行のため本 cycle は claim 見送り）"
      return 1
    fi
  fi
  return 0  # claim 続行
}

# pp_resolve_target_branch: `PROMOTION_TARGET_BRANCH` のリモート存在を検証し、
# `BASE_BRANCH` と異なることを確認する（Req 1.1.3, 1.2.2）。
# 戻り値: 0 = 検証 OK / 1 = 中止すべき状態
pp_resolve_target_branch() {
  # AC 1.1.3: BASE_BRANCH == PROMOTION_TARGET_BRANCH なら no-op として終了
  if [ "$BASE_BRANCH" = "$PROMOTION_TARGET_BRANCH" ]; then
    pp_log "BASE_BRANCH と PROMOTION_TARGET_BRANCH が同一 ('$BASE_BRANCH')、Phase B は no-op"
    return 1
  fi
  # AC 1.2.2: リモートに存在するか検証
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      git ls-remote --exit-code --heads origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
    pp_error "PROMOTION_TARGET_BRANCH '$PROMOTION_TARGET_BRANCH' がリモートに存在しません。promote を中止します。"
    return 1
  fi
  return 0
}

# pp_issue_has_label: Issue が指定ラベルを持つか確認するヘルパー。
# 戻り値: 0 = 持つ / 1 = 持たない or 取得失敗
pp_issue_has_label() {
  local issue_number="$1"
  local label="$2"
  local labels_json
  if ! labels_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" --json labels 2>/dev/null); then
    return 1
  fi
  echo "$labels_json" | jq -e --arg l "$label" \
    '.labels // [] | map(.name) | index($l)' >/dev/null 2>&1
}

# pp_collect_merged_issues: Phase A 直後の状態で「`BASE_BRANCH` に merge 済みかつ
# `Closes #N` でリンクされている Issue」を抽出し、未付与の Issue には
# `staged-for-release` を自動付与する。fork PR は除外する（NFR 2.4）。
# 自動付与と人間付与の source 区別は行わない（Req 2.1.2、同一ラベル共有）。
#
# stdout: 現時点で `staged-for-release` を持つ全 open Issue の番号を 1 行 1 件で出力
#         （次のステップで ST 判定する対象集合になる）
# Requirements: 2.1, NFR 2.4, NFR 5.2
pp_collect_merged_issues() {
  local repo_owner="${REPO%%/*}"
  local recent_merged_prs_json
  # 1. is:merged base:$BASE_BRANCH の直近 PR を取得（最新 50 件、Req 5.2 範囲）
  if ! recent_merged_prs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state merged \
      --base "$BASE_BRANCH" \
      --json number,headRepositoryOwner,closingIssuesReferences \
      --limit 50 2>/dev/null); then
    pp_warn "merged PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    return 0
  fi

  # 2. fork PR を除外（NFR 2.4）し、closingIssuesReferences から Issue 番号を抽出
  local linked_issues
  linked_issues=$(echo "$recent_merged_prs_json" | jq -r \
    --arg owner "$repo_owner" \
    '[.[]
      | select((.headRepositoryOwner.login // "") == $owner)
      | (.closingIssuesReferences // [])[]
      | .number
    ] | unique | .[]')

  # 3. 各 Issue について `staged-for-release` ラベルの有無を確認し、
  #    未付与なら自動付与する（重複付与は抑止 / Req 2.1.1, 2.1.3）
  local added=0
  local skipped=0
  if [ -n "$linked_issues" ]; then
    while IFS= read -r issue_number; do
      [ -n "$issue_number" ] || continue
      if pp_issue_has_label "$issue_number" "$LABEL_STAGED_FOR_RELEASE"; then
        # AC 2.1.3: 既付与なら API 再送しない
        skipped=$((skipped + 1))
        continue
      fi
      # AC 2.1.1: 未付与に対して自動付与
      if timeout "$PROMOTE_GIT_TIMEOUT" \
          gh issue edit "$issue_number" --repo "$REPO" \
            --add-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
        pp_log "issue=#${issue_number} action=label-add label=${LABEL_STAGED_FOR_RELEASE} source=auto"
        added=$((added + 1))
      else
        pp_warn "issue=#${issue_number} staged-for-release 自動付与に失敗（後続 Issue は継続）"
      fi
    done <<< "$linked_issues"
  fi

  pp_log "auto-label サマリ: staged-for-release-added=${added}, already-labeled-skipped=${skipped}"

  # 4. 全 staged-for-release 付き open Issue の番号を stdout に出力（自動 + 人間
  #    付与の両方を含む / Req 2.1.2）。後続 ST 判定の対象集合になる。
  timeout "$PROMOTE_GIT_TIMEOUT" gh issue list --repo "$REPO" \
    --label "$LABEL_STAGED_FOR_RELEASE" --state open \
    --json number --limit 100 --jq '.[].number' 2>/dev/null \
    || pp_warn "staged-for-release 付き Issue 一覧の取得に失敗（per-Issue 処理を見送る）"
}

# pp_resolve_merge_sha: Issue にリンクされた直近の merge commit SHA を解決する。
# GitHub の `gh issue view --json closedByPullRequestsReferences` で Issue を閉じた
# PR を取得し、各 PR の mergeCommit.oid を最新（updatedAt 降順）から拾う。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: merge commit SHA（解決できた場合）
# 戻り値: 0 = 解決成功 / 1 = 失敗（Issue が PR 経由で閉じられていない・取得失敗等）
pp_resolve_merge_sha() {
  local issue_number="$1"
  local pr_list_json
  if ! pr_list_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue view "$issue_number" --repo "$REPO" \
        --json closedByPullRequestsReferences 2>/dev/null); then
    return 1
  fi
  # PR ごとに mergeCommit.oid を取得（必要に応じて gh pr view で補完）
  local pr_numbers
  pr_numbers=$(echo "$pr_list_json" | jq -r \
    '[.closedByPullRequestsReferences // [] | .[]
      | select(.state == "MERGED")
      | .number] | sort | reverse | .[]' 2>/dev/null) || return 1
  [ -n "$pr_numbers" ] || return 1
  local pr_number merge_sha
  while IFS= read -r pr_number; do
    [ -n "$pr_number" ] || continue
    merge_sha=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" \
        --json mergeCommit --jq '.mergeCommit.oid // ""' 2>/dev/null) || continue
    if [ -n "$merge_sha" ] && [ "$merge_sha" != "null" ]; then
      echo "$merge_sha"
      return 0
    fi
  done <<< "$pr_numbers"
  return 1
}

# pp_get_st_state: 1 つの Issue について、リンクされた最新の `BASE_BRANCH` 上
# merge commit に対する ST check-run の状態を取得する。
#
# 入力: $1 = Issue 番号
# 出力（stdout）: 内部状態 5 種のいずれか
#   "success"   ST check-run が完了 & conclusion=success
#   "failure"   ST check-run が完了 & conclusion=failure/cancelled/timed_out/action_required
#   "pending"   ST check-run が in_progress / queued / pending
#   "missing"   ST check-run が見つからない or conclusion 不一致
#   "skip-warn" ST_CHECK_RUN_NAME 未設定（Req 2.2.3）
# 戻り値: 常に 0（呼び出し元で文字列分岐）
# Requirements: 2.2
pp_get_st_state() {
  local issue_number="$1"
  # AC 2.2.3: ST_CHECK_RUN_NAME 未設定なら skip-warn（呼び出し元で WARN ログ）
  if [ -z "$ST_CHECK_RUN_NAME" ]; then
    echo "skip-warn"
    return 0
  fi
  # AC 2.2.5: Issue にリンクされた merge commit を解決できなければ missing
  local merge_sha
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    echo "missing"
    return 0
  fi
  [ -n "$merge_sha" ] || { echo "missing"; return 0; }
  # AC 2.2.1: check-runs API で対象 commit に対する check-run 一覧を取得
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo "missing"
    return 0
  fi
  # AC 2.2.2: ST_CHECK_RUN_NAME と完全一致する check-run を抽出し、最新採用
  local target
  target=$(echo "$check_runs_json" | jq -c --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last' 2>/dev/null) || target="null"
  if [ -z "$target" ] || [ "$target" = "null" ]; then
    echo "missing"
    return 0
  fi
  # AC 2.2.4: status + conclusion で結果判定
  local status conclusion
  status=$(echo "$target" | jq -r '.status // ""')
  conclusion=$(echo "$target" | jq -r '.conclusion // ""')
  case "$status" in
    completed)
      case "$conclusion" in
        success)
          echo "success"
          ;;
        failure|cancelled|timed_out|action_required)
          echo "failure"
          ;;
        *)
          # neutral / skipped / stale / unknown は missing 扱い
          echo "missing"
          ;;
      esac
      ;;
    queued|in_progress|pending|"")
      echo "pending"
      ;;
    *)
      echo "pending"
      ;;
  esac
}

# pp_resolve_st_log_url: ST check-run の details_url を解決する（取得失敗時は空文字列）。
# 入力: $1 = Issue 番号, $2 = merge commit SHA
# 出力（stdout）: details_url または空文字列
pp_resolve_st_log_url() {
  local merge_sha="$2"
  [ -n "$ST_CHECK_RUN_NAME" ] || { echo ""; return 0; }
  [ -n "$merge_sha" ] || { echo ""; return 0; }
  local check_runs_json
  if ! check_runs_json=$(timeout "$PROMOTE_GIT_TIMEOUT" \
      gh api "repos/$REPO/commits/$merge_sha/check-runs" \
        --jq '.check_runs' 2>/dev/null); then
    echo ""
    return 0
  fi
  echo "$check_runs_json" | jq -r --arg n "$ST_CHECK_RUN_NAME" \
    '[.[] | select(.name == $n)]
      | sort_by(.completed_at // .started_at // "")
      | last
      | (.details_url // .html_url // "")' 2>/dev/null \
    || echo ""
}

# pp_do_revert: `BASE_BRANCH` 上で merge commit を `git revert -m 1` して
# `--force-with-lease` で push する（NFR 2.1）。サブシェル内で `trap` を仕掛けて
# `BASE_BRANCH` checkout 状態への復帰を保証する（NFR 2.3）。
#
# 入力: $1 = revert 対象の merge commit SHA
# 戻り値:
#   0 = revert + push 成功
#   1 = push 失敗（リモート先行等）。呼び出し元で st-failed 付与を保留（Req 2.4.6）
#   2 = revert 自体が失敗 / checkout / pull 失敗
pp_do_revert() {
  local merge_sha="$1"
  (
    set +e
    # 復帰用 trap: revert を中断したら `git revert --abort` し、$BASE_BRANCH に戻る
    trap 'git revert --abort >/dev/null 2>&1; git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git checkout "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git pull --ff-only origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 2
    fi
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git revert -m 1 --no-edit "$merge_sha" >/dev/null 2>&1; then
      exit 2
    fi
    # NFR 2.1: --force-with-lease のみ。--force 単独は使用しない
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push --force-with-lease origin "$BASE_BRANCH" >/dev/null 2>&1; then
      exit 1
    fi
    exit 0
  )
}

# pp_handle_st_failure: ST failure と判定された Issue について、対応する merge
# commit を revert + push、Issue reopen、`st-failed` 付与、ST log URL を含む
# 1 件のコメント投稿を実施する（Req 2.4）。fail-continue を維持し、1 件失敗しても
# 他 Issue の処理は継続する（NFR 3.1）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 全操作成功 / 1 = いずれかが失敗（呼び出し元でカウンタにのみ反映）
pp_handle_st_failure() {
  local issue_number="$1"
  local merge_sha st_log_url
  if ! merge_sha=$(pp_resolve_merge_sha "$issue_number"); then
    pp_warn "issue=#${issue_number} merge SHA 解決失敗 → ST failure 処理を見送り action=skip"
    return 1
  fi
  # AC 2.4.2: revert commit を作成して push。push 失敗 → st-failed 付与を保留
  local revert_rc=0
  pp_do_revert "$merge_sha" || revert_rc=$?
  case "$revert_rc" in
    0)
      :
      ;;
    1)
      # AC 2.4.6: push 失敗（リモート先行等）→ st-failed 保留 + WARN
      pp_warn "issue=#${issue_number} revert push 失敗（リモート先行等）→ st-failed 付与を保留 action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
    *)
      pp_warn "issue=#${issue_number} revert 自体に失敗（既に revert 済み等）→ ST failure 処理を見送り action=skip merge_sha=${merge_sha:0:7}"
      return 1
      ;;
  esac
  # AC 2.4.1 + 2.4.4: st-failed 付与 + staged-for-release 除去を 1 call に集約
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --add-label "$LABEL_ST_FAILED" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ラベル付与/除去に失敗（revert は実施済み） action=label-fail"
    # ラベル操作の失敗は致命的でないため、reopen / comment は継続する
  fi
  # AC 2.4.3: Issue reopen
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue reopen "$issue_number" --repo "$REPO" >/dev/null 2>&1; then
    # 既に open の場合や API エラーでも次の comment を試みる
    pp_warn "issue=#${issue_number} Issue reopen に失敗（既に open の可能性あり、comment 投稿は継続）"
  fi
  # AC 2.4.3: ST log URL を含む 1 件のステータスコメントを投稿
  st_log_url=$(pp_resolve_st_log_url "$issue_number" "$merge_sha")
  local comment_body
  comment_body=$(cat <<EOF
## 🔁 ST failure 自動 revert (Phase B Promote Pipeline)

\`${BASE_BRANCH}\` に merge された変更について、ST check-run **\`${ST_CHECK_RUN_NAME}\`** が
**failure** と判定されたため、watcher が \`git revert -m 1\` で自動 revert しました。

### Revert 対象 merge commit

- SHA (short): \`${merge_sha:0:7}\`
- ST log URL: ${st_log_url:-_(取得失敗)_}

### 推奨アクション

- ST failure の原因を確認し、修正用 PR を本 Issue にリンクして作成してください
- 本 Issue は \`st-failed\` ラベル付きで自動 reopen されています

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue comment "$issue_number" --repo "$REPO" \
        --body "$comment_body" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ステータスコメント投稿に失敗（revert / label / reopen は実施済み）"
  fi
  pp_log "issue=#${issue_number} ST=failure action=revert+label-add+label-remove+reopen+comment merge_sha=${merge_sha:0:7} label=${LABEL_ST_FAILED}"
  return 0
}

# pp_handle_st_success: ST success と判定された Issue から `staged-for-release`
# ラベルを除去し、promote 候補集合（PROMOTE_CANDIDATES）に追加する。
# `PROMOTE_MODE=on-demand` の場合はラベル除去 / 集合追加とも行わず、人間トリガー
# を待つ（Req 3.2.5）。
#
# 入力: $1 = Issue 番号
# 戻り値: 0 = 成功 / 1 = 失敗（fail-continue で呼び出し側がカウントのみ実施）
# Requirements: 2.3, 3.2
pp_handle_st_success() {
  local issue_number="$1"
  # AC 3.2.5: on-demand モードはラベルを除去せず、PROMOTE_CANDIDATES にも入れない
  if [ "$PROMOTE_MODE" = "on-demand" ]; then
    pp_log "issue=#${issue_number} ST=success mode=on-demand action=hold-label-await-human-trigger"
    return 0
  fi
  # AC 2.3.1: staged-for-release ラベルを除去
  if ! timeout "$PROMOTE_GIT_TIMEOUT" \
      gh issue edit "$issue_number" --repo "$REPO" \
        --remove-label "$LABEL_STAGED_FOR_RELEASE" >/dev/null 2>&1; then
    pp_warn "issue=#${issue_number} ST=success staged-for-release 除去に失敗（後続 Issue は継続）"
    return 1
  fi
  # AC 2.3.2: promote 候補集合に追加
  PROMOTE_CANDIDATES+=("$issue_number")
  pp_log "issue=#${issue_number} ST=success action=label-remove+promote-queued label=${LABEL_STAGED_FOR_RELEASE}"
  return 0
}

# pp_process_one_issue: 1 件の Issue について ST 状態を取得し、状態別の
# アクション（success / failure / pending / missing / skip-warn）を実施する。
# 1 件の失敗が他 Issue 処理を止めないように戻り値で集計用カウンタにのみ反映
# する（NFR 3.1 fail-continue）。
#
# 入力: $1 = Issue 番号
# 副作用（成功時のみ加算する集計用変数、呼び出し側スコープで参照）:
#   PP_ST_SUCCESS_COUNT / PP_ST_FAILURE_COUNT / PP_ST_PENDING_COUNT /
#   PP_ST_MISSING_COUNT / PP_FAIL_COUNT
pp_process_one_issue() {
  local issue_number="$1"
  local st_state
  st_state=$(pp_get_st_state "$issue_number")
  case "$st_state" in
    success)
      if pp_handle_st_success "$issue_number"; then
        PP_ST_SUCCESS_COUNT=$((PP_ST_SUCCESS_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    failure)
      if pp_handle_st_failure "$issue_number"; then
        PP_ST_FAILURE_COUNT=$((PP_ST_FAILURE_COUNT + 1))
      else
        PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      fi
      ;;
    pending)
      # AC 2.2.4: 未完了は次サイクルに持ち越す（ラベル変更なし）
      pp_log "issue=#${issue_number} ST=pending action=skip-next-cycle"
      PP_ST_PENDING_COUNT=$((PP_ST_PENDING_COUNT + 1))
      ;;
    missing)
      # AC 2.2.5: ST check-run が存在しない → WARN + 状態変更なし
      pp_warn "issue=#${issue_number} ST=missing action=skip（check-run 不在 or merge SHA 未解決）"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    skip-warn)
      # AC 2.2.3: ST_CHECK_RUN_NAME 未設定 → WARN + 当該サイクル no-op
      pp_warn "issue=#${issue_number} ST_CHECK_RUN_NAME 未設定 → ST 連動停止 action=skip"
      PP_ST_MISSING_COUNT=$((PP_ST_MISSING_COUNT + 1))
      ;;
    *)
      pp_warn "issue=#${issue_number} 未知の ST 状態 '${st_state}' action=skip"
      PP_FAIL_COUNT=$((PP_FAIL_COUNT + 1))
      ;;
  esac
  return 0
}

# pp_match_cron_field: 1 つの cron フィールド（分 / 時 / 日 / 月 / 曜日）を
# 現在値とマッチングする。標準 cron のサブパターン:
#   *           （任意の値にマッチ）
#   */N         （N で割り切れる値にマッチ）
#   A-B         （A 以上 B 以下にマッチ）
#   A,B,C       （いずれかの値にマッチ）
#   <整数>      （厳密一致）
#
# 入力: $1 = cron フィールド文字列, $2 = 現在値（整数）
# 戻り値: 0 = match / 1 = no match or 不正
pp_match_cron_field() {
  local field="$1"
  local value="$2"
  [ -n "$field" ] || return 1
  # 数値以外の現在値はマッチ不能
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  # `*` は全てにマッチ
  if [ "$field" = "*" ]; then
    return 0
  fi
  # `*/N` ステップ
  if [[ "$field" =~ ^\*/([0-9]+)$ ]]; then
    local step="${BASH_REMATCH[1]}"
    [ "$step" -gt 0 ] || return 1
    if [ $((10#$value % step)) -eq 0 ]; then
      return 0
    fi
    return 1
  fi
  # カンマ区切りリスト
  if [[ "$field" == *,* ]]; then
    local subfield
    IFS=',' read -ra _PP_CRON_PARTS <<< "$field"
    for subfield in "${_PP_CRON_PARTS[@]}"; do
      if pp_match_cron_field "$subfield" "$value"; then
        return 0
      fi
    done
    return 1
  fi
  # `A-B` レンジ
  if [[ "$field" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    local lo="${BASH_REMATCH[1]}"
    local hi="${BASH_REMATCH[2]}"
    if [ "$((10#$value))" -ge "$lo" ] && [ "$((10#$value))" -le "$hi" ]; then
      return 0
    fi
    return 1
  fi
  # 単一整数
  if [[ "$field" =~ ^[0-9]+$ ]]; then
    if [ "$((10#$value))" -eq "$((10#$field))" ]; then
      return 0
    fi
    return 1
  fi
  return 1
}

# pp_match_cron: 標準 cron 5 フィールド式（分 時 日 月 曜日）を現在時刻と比較する。
# `date '+%M %H %d %m %u'` で取得した現在時刻と、cron 各フィールドを `pp_match_cron_field`
# でマッチング。全フィールド一致なら 0、いずれか不一致 / 不正な書式なら 1 を返す。
#
# 入力: $1 = cron 式（5 フィールドのみ。`@daily` 等の特殊文字列は非対応）
# 戻り値: 0 = 現在時刻が cron 式に一致 / 1 = 不一致 or 不正な書式
# Requirements: 3.2.4, 3.2.6
pp_match_cron() {
  local cron="$1"
  [ -n "$cron" ] || return 1
  # 5 フィールドに分解
  local -a fields
  # shellcheck disable=SC2206 # 意図的に IFS=space で分割
  fields=( $cron )
  if [ "${#fields[@]}" -ne 5 ]; then
    return 1
  fi
  local now_min now_hour now_day now_mon now_dow
  now_min=$(date '+%M')
  now_hour=$(date '+%H')
  now_day=$(date '+%d')
  now_mon=$(date '+%m')
  now_dow=$(date '+%u')   # 1=Mon, 7=Sun（cron では 0/7 が Sun のため両対応が望ましい）
  pp_match_cron_field "${fields[0]}" "$now_min"  || return 1
  pp_match_cron_field "${fields[1]}" "$now_hour" || return 1
  pp_match_cron_field "${fields[2]}" "$now_day"  || return 1
  pp_match_cron_field "${fields[3]}" "$now_mon"  || return 1
  # 曜日: cron では 0=Sun, 1=Mon..6=Sat。`date +%u` は 1=Mon..7=Sun のため、
  # まず %u で比較し、cron 0 表記は %u=7（日曜）に丸めて再比較する
  if ! pp_match_cron_field "${fields[4]}" "$now_dow"; then
    if [ "$now_dow" = "7" ] && pp_match_cron_field "${fields[4]}" "0"; then
      :
    else
      return 1
    fi
  fi
  return 0
}

# pp_do_promote_if_eligible: `PROMOTE_MODE` 3 モード（continuous / batched /
# on-demand）の dispatcher。実際の fast-forward push 本体 `pp_do_promote`
# は本関数から呼び出される（task 5.2 で実装）。
#
# Requirements: 3.2.2, 3.2.3, 3.2.4, 3.2.5, 3.2.6
pp_do_promote_if_eligible() {
  case "$PROMOTE_MODE" in
    continuous)
      # AC 3.2.3: 即時 promote。promote 候補が 0 件なら何もしない
      if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
        pp_do_promote
      else
        pp_log "mode=continuous promote 候補 0 件 → 本サイクルは promote なし"
      fi
      ;;
    batched)
      # AC 3.2.4 / 3.2.6: PROMOTE_CRON 一致時のみ実行
      if [ -z "$PROMOTE_CRON" ]; then
        pp_warn "mode=batched PROMOTE_CRON 未設定 → 本サイクルは promote なし"
        return 0
      fi
      if pp_match_cron "$PROMOTE_CRON"; then
        if [ "${#PROMOTE_CANDIDATES[@]}" -gt 0 ]; then
          pp_do_promote
        else
          pp_log "mode=batched cron 一致だが promote 候補 0 件 → 本サイクルは promote なし"
        fi
      else
        # AC 3.2.6: cron 不一致 / 不正な式は本サイクル no-op + WARN
        pp_log "mode=batched PROMOTE_CRON='${PROMOTE_CRON}' 現在時刻と不一致 → 本サイクルは promote なし"
      fi
      ;;
    on-demand)
      # AC 3.2.5: 人間トリガー待ち。何もしない + log
      pp_log "mode=on-demand 人間トリガーを待つ → promote は実行しない"
      ;;
    *)
      # AC 3.2.2: 不正値も on-demand にフォールバック
      pp_warn "mode='${PROMOTE_MODE}' は未知の値 → on-demand にフォールバック（promote 実行しない）"
      ;;
  esac
}

# pp_do_promote: `BASE_BRANCH` HEAD を `PROMOTION_TARGET_BRANCH` に fast-forward
# push する（NFR 2.1, NFR 2.2）。サブシェル内で `trap` を仕掛けて操作終了時に
# `BASE_BRANCH` checkout 状態へ復帰する（NFR 2.3 / Req 3.1.4）。
#
# fast-forward 不可（`PROMOTION_TARGET_BRANCH` 側が `BASE_BRANCH` の祖先でない）と
# 判定した場合は push を中止し、`promote-failed` 識別語を含む WARN を出す
# （Req 3.1.2, 3.1.3, NFR 4.1）。Issue 側のラベル状態は変更しない。
#
# 戻り値: 0 = promote 成功 / 1 = promote 失敗（呼び出し元は集計のみ）
pp_do_promote() {
  local rc=0
  (
    set +e
    trap 'git checkout "'"$BASE_BRANCH"'" >/dev/null 2>&1' EXIT
    # Req 3.1.1 準備: 最新の PROMOTION_TARGET_BRANCH を fetch
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git fetch origin "$PROMOTION_TARGET_BRANCH" >/dev/null 2>&1; then
      pp_warn "promote-failed: fetch '$PROMOTION_TARGET_BRANCH' に失敗"
      pp_notify_promote_failure "fetch failed"
      exit 1
    fi
    # AC 3.1.2: PROMOTION_TARGET_BRANCH が BASE_BRANCH の祖先か確認。
    # 祖先でない場合 fast-forward 不可 → 中止 + WARN（Req 3.1.3）
    if ! git merge-base --is-ancestor \
        "origin/$PROMOTION_TARGET_BRANCH" "origin/$BASE_BRANCH" 2>/dev/null; then
      pp_warn "promote-failed: '$PROMOTION_TARGET_BRANCH' が '$BASE_BRANCH' の祖先でないため fast-forward 不可"
      pp_notify_promote_failure "non-fast-forward"
      exit 1
    fi
    # NFR 2.1 / 2.2: fast-forward 限定 push（--force 系オプションを付けず
    # 自然な ff push）。non-fast-forward は git server が reject する
    if ! timeout "$PROMOTE_GIT_TIMEOUT" \
        git push origin \
          "refs/remotes/origin/${BASE_BRANCH}:refs/heads/${PROMOTION_TARGET_BRANCH}" \
          >/dev/null 2>&1; then
      pp_warn "promote-failed: fast-forward push に失敗"
      pp_notify_promote_failure "ff-push failed"
      exit 1
    fi
    pp_log "promote-success: '$BASE_BRANCH' -> '$PROMOTION_TARGET_BRANCH' fast-forward OK (candidates=${#PROMOTE_CANDIDATES[@]})"
    exit 0
  ) || rc=$?
  # 親シェル側カウンタを更新（サブシェル内で変更したカウンタは失われるため）
  if [ "$rc" -eq 0 ]; then
    PP_PROMOTE_SUCCESS_COUNT=$((PP_PROMOTE_SUCCESS_COUNT + 1))
  else
    PP_PROMOTE_FAILED_COUNT=$((PP_PROMOTE_FAILED_COUNT + 1))
  fi
  return "$rc"
}

# pp_notify_promote_failure: promote 失敗時の通知。`PROMOTE_FAIL_NOTIFY_ISSUE` が
# 数値で指定されていれば該当 Issue に 1 件コメント投稿、未設定 / 不正値なら log のみ
# （Req 3.3.2, 3.3.3）。
pp_notify_promote_failure() {
  local reason="$1"
  # AC 3.3.3: 未設定 / 不正値（数値以外）は log のみ
  if [ -z "$PROMOTE_FAIL_NOTIFY_ISSUE" ] \
     || ! [[ "$PROMOTE_FAIL_NOTIFY_ISSUE" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  # AC 3.3.2: 1 件のコメント投稿（失敗してもサイクルは継続）
  local body
  body=$(cat <<EOF
## ⚠️ Phase B Promote Pipeline: promote 失敗

\`${BASE_BRANCH}\` -> \`${PROMOTION_TARGET_BRANCH}\` への fast-forward 昇格に失敗しました。

- reason: \`${reason}\`
- base: \`${BASE_BRANCH}\`
- target: \`${PROMOTION_TARGET_BRANCH}\`

watcher サイクルは継続しています。手動確認をお願いします。

---

_本コメントは Phase B Promote Pipeline Processor が自動投稿しました。_
EOF
)
  timeout "$PROMOTE_GIT_TIMEOUT" \
    gh issue comment "$PROMOTE_FAIL_NOTIFY_ISSUE" --repo "$REPO" \
      --body "$body" >/dev/null 2>&1 \
    || pp_warn "PROMOTE_FAIL_NOTIFY_ISSUE=#${PROMOTE_FAIL_NOTIFY_ISSUE} へのコメント投稿に失敗"
}

# pp_summary: サイクル終了時のサマリログを 1 行で出力する。grep 集計用に
# `[$REPO] promote-pipeline: サマリ:` prefix と `key=value` 形式で出力する
# （Req 5.1.3, 5.1.5, NFR 4.1）。
pp_summary() {
  pp_log "サマリ: st-success-promoted=${PP_ST_SUCCESS_COUNT}, st-failure-reverted=${PP_ST_FAILURE_COUNT}, pending-skip=${PP_ST_PENDING_COUNT}, missing-skip=${PP_ST_MISSING_COUNT}, promote-success=${PP_PROMOTE_SUCCESS_COUNT}, promote-failed=${PP_PROMOTE_FAILED_COUNT}, fail=${PP_FAIL_COUNT}"
}

# process_promote_pipeline: Promote Pipeline Processor のエントリポイント。
#
# 引数: なし（env var で全制御）
# 戻り値: 常に 0（fail-continue を維持し、後続 Processor を止めない / NFR 3.1）
# 副作用:
#   - 対象 Issue へのラベル付与・除去（staged-for-release / st-failed）
#   - 対象 Issue の reopen + コメント投稿（ST failure 時）
#   - $BASE_BRANCH への revert commit + push（ST failure 時）
#   - $BASE_BRANCH → $PROMOTION_TARGET_BRANCH への fast-forward push（promote 成功時）
#   - $PROMOTE_FAIL_NOTIFY_ISSUE への 1 件コメント（promote 失敗時、env 設定時のみ）
process_promote_pipeline() {
  # AC 1.1.1, NFR 1.1: opt-in gate。`=true` 明示以外はすべて no-op で早期 return
  if [ "$PROMOTE_PIPELINE_ENABLED" != "true" ]; then
    return 0
  fi

  pp_log "サイクル開始 (base=${BASE_BRANCH}, target=${PROMOTION_TARGET_BRANCH}, mode=${PROMOTE_MODE}, timeout=${PROMOTE_GIT_TIMEOUT}s)"

  # AC 1.1.3, 1.2.2: 2-branch model gate + PROMOTION_TARGET_BRANCH のリモート存在検証
  if ! pp_resolve_target_branch; then
    return 0
  fi

  # NFR 2.3: dirty working tree gate。promote / revert は clean な作業ツリーが前提
  if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    pp_error "dirty working tree を検知。promote / revert を中止します。"
    return 0
  fi

  # AC 2.1: merge 済み PR からリンク Issue を抽出 → 未付与に staged-for-release を
  # 自動付与し、ST 判定対象（= 現在 staged-for-release を持つ全 open Issue）を取得。
  local target_issues
  target_issues=$(pp_collect_merged_issues || true)

  if [ -z "$target_issues" ]; then
    pp_log "サマリ: 対象 Issue なし（staged-for-release 付き Issue 0 件）"
    return 0
  fi

  # ST 判定対象 Issue 数を log に出力
  local target_count
  target_count=$(echo "$target_issues" | grep -c '^[0-9]' || true)
  pp_log "ST 判定対象: ${target_count} 件の Issue を検出"

  # 集計用カウンタと promote 候補集合を初期化（per-cycle 状態）
  PROMOTE_CANDIDATES=()
  PP_ST_SUCCESS_COUNT=0
  PP_ST_FAILURE_COUNT=0
  PP_ST_PENDING_COUNT=0
  PP_ST_MISSING_COUNT=0
  PP_FAIL_COUNT=0

  # AC 2.2〜2.4: 各 Issue について ST 状態取得 + アクション実施。
  # NFR 3.1: 1 件の失敗が他 Issue 処理を止めないよう `|| true` で吸収。
  local issue_number
  while IFS= read -r issue_number; do
    [ -n "$issue_number" ] || continue
    pp_process_one_issue "$issue_number" \
      || pp_warn "issue=#${issue_number} 想定外のエラー → 後続 Issue は継続"
  done <<< "$target_issues"

  # AC 3.1, 3.2: promote 候補集合を PROMOTE_MODE に応じて昇格実行。
  # 集計用カウンタは pp_do_promote / pp_do_promote_if_eligible 内部で更新する。
  PP_PROMOTE_SUCCESS_COUNT=0
  PP_PROMOTE_FAILED_COUNT=0
  # NFR 3.1: 失敗時も後続処理を止めないため `|| true` で吸収
  pp_do_promote_if_eligible || true

  # AC 5.1.3: サイクル終了時のサマリログを 1 行で出力
  pp_summary
}

# AC 1.1: Phase A 本体の直後に Promote Pipeline Processor を 1 回起動。
# fail-continue を維持するため `|| pp_warn ...` で例外を吸収（NFR 3.1）。
process_promote_pipeline \
  || pp_warn "process_promote_pipeline が想定外のエラーで終了しました（後続 Processor は継続）"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PR Iteration Processor (#26)
#   `needs-iteration` ラベルが付いた idd-claude 管理下 PR を fresh context の Claude で
#   反復対応する。Phase A と同じ flock 境界内で直列実行され、対象 PR 集合は
#   server-side label query で Phase A と直交させている（AC 8.4）。
#
#   標準機能としてデフォルト有効（#112）。無効化は PR_ITERATION_ENABLED=false で明示。
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# pr-iteration 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #119 Req 1.1 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
pi_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: $*"
}
pi_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: WARN: $*" >&2
}
pi_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-iteration: ERROR: $*" >&2
}

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
  if ! prs_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" gh pr list \
      --repo "$REPO" \
      --state open \
      --search "label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_REBASE\" -draft:true" \
      --json number,headRefName,baseRefName,isDraft,url,labels,headRepositoryOwner,body \
      --limit 50 2>/dev/null); then
    pi_warn "needs-iteration PR の取得に失敗しました（gh pr list タイムアウトまたはエラー）"
    echo "[]"
    return 0
  fi

  # AC 1.2 / 1.3 / 1.4: クライアント側フィルタ（server filter の保険 + head pattern + fork 除外）
  # #35 AC 4.4 / 5.1: design pattern は PR_ITERATION_DESIGN_ENABLED=true のときのみ OR 条件に
  # 含める。false（既定）なら impl pattern のみで絞り込み、設計 PR は candidate 段階で除外される
  # （= 本機能導入前と完全同一の挙動）。
  echo "$prs_json" | jq \
    --arg impl_pattern "$PR_ITERATION_HEAD_PATTERN" \
    --arg design_pattern "$PR_ITERATION_DESIGN_HEAD_PATTERN" \
    --arg design_enabled "$PR_ITERATION_DESIGN_ENABLED" \
    --arg owner "$repo_owner" \
    '[.[]
      | select(.isDraft == false)
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
# pi_read_round_counter: PR body から hidden marker の round 数を取得
#   入力: $1=pr_number
#   出力: stdout に round 数（marker 無しなら 0）
#   AC 7.1, 7.4
# ─────────────────────────────────────────────────────────────────────────────
pi_read_round_counter() {
  local pr_number="$1"
  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、round=0 として扱います"
    echo "0"
    return 0
  fi
  # marker 形式: <!-- idd-claude:pr-iteration round=N last-run=... -->
  # 複数検出時は最後（最新）の数値を採用 = fail-safe
  local round
  round=$(echo "$body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${round:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_no_progress_streak: PR body から hidden marker の no-progress 連続カウンタを取得
#   入力: $1=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に整数（key 不在 / marker 不在なら "0"）
#   返り値: 0 固定
#   Issue #122 Req 3.6 / 4.2 / 4.4 / 4.5
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=ISO8601 no-progress-streak=K -->
#   既存 marker（no-progress-streak キー無し）の場合は "0" を返す（Req 4.2 / 4.4 後方互換）。
#   複数 marker がある場合は末尾を採用（既存 pi_read_round_counter / pi_read_last_run と整合）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_no_progress_streak() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo "0"
    return 0
  fi
  local streak
  streak=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration [^>]*no-progress-streak=[0-9]+' \
    | grep -oE 'no-progress-streak=[0-9]+' \
    | grep -oE '[0-9]+$' \
    | tail -1)
  echo "${streak:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_read_last_run: PR body から hidden marker の last-run ISO8601 タイムスタンプを抽出
#   入力: $1=pr_body（gh pr view --json body --jq '.body // ""' で取得済みの文字列）
#   出力: stdout に last-run の ISO8601 文字列（例: "2026-04-25T12:34:56Z"）。
#         marker / last-run キーが無ければ空文字列を出力。
#   返り値: 0 固定（呼び出し元で空文字列を初回 round 扱いにする）
#   AC #55 Req 2.3, 2.4 / 4.1
#
#   marker 形式: <!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->
#   複数検出時は最後（最新）の値を採用（pi_read_round_counter の `tail -1` と整合）。
#   読み取り専用であり、書き込み側は pi_post_processing_marker のまま温存（後方互換性）。
# ─────────────────────────────────────────────────────────────────────────────
pi_read_last_run() {
  local pr_body="${1-}"
  if [ -z "$pr_body" ]; then
    echo ""
    return 0
  fi
  local last_run
  # 1. marker 行を抽出 → 2. `last-run=...` 部分のみを抽出 → 3. 末尾を採用
  #    値部分はスペース・`>` 以外を許容（pi_post_processing_marker は ISO8601 UTC を打刻するが、
  #    fail-safe としてスペース直前 / `>` 直前まで拾う）。
  last_run=$(echo "$pr_body" \
    | grep -oE 'idd-claude:pr-iteration round=[0-9]+ last-run=[^ >]+' \
    | sed -E 's|.*last-run=||' \
    | tail -1)
  echo "${last_run:-}"
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_self: watcher 自身の自動投稿コメントを除外（marker ベース）
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.1, 2.7
#
#   判定: comment.body 中に `idd-claude:` で始まる HTML hidden marker を含むなら
#   watcher 投稿として除外する。GitHub user 同一性に依存しない（cron 実行ホストが
#   異なる GitHub user で動いていても確実に除外できる）。`@claude` 文字列には
#   一切依存しない（Req 2.7）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_self() {
  jq '[.[] | select((.body // "") | contains("idd-claude:") | not)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_resolved: 過去 round で対応済みと判定できるコメントを除外
#   入力: $1=last_run (ISO8601 string, 空文字列 = 初回 round)
#         stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.2, 2.3, 2.4, 2.5, 2.7
#
#   判定: last_run が空文字列なら no-op（全件採用 = 初回 round, Req 2.4）。
#         last_run が指定されている場合は `created_at > last_run` のコメントのみ採用。
#         境界（`==`）は採用側に倒さず除外する（fail-safe、設計判断 Req 2.3 解釈）。
#         比較は ISO8601 lex compare（GitHub の created_at は UTC `Z` 終端で揃う）。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_resolved() {
  local last_run="${1-}"
  jq --arg last_run "$last_run" \
    '[.[] | select($last_run == "" or (.created_at // "") > $last_run)]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_filter_event_style: GitHub system 由来の event-style コメントを除外
#   入力: stdin に一般コメント JSON 配列
#   出力: stdout にフィルタ後の JSON 配列
#   AC #55 Req 2.6, 2.7
#
#   判定: user.type == "Bot" のコメント、および body が空のコメントを除外する。
#         /repos/.../issues/<n>/comments は基本的にユーザーコメントしか返さないため
#         保険的なフィルタだが、Req 2.6 を観測可能に保つために独立化する。
#         watcher 自身の投稿は marker で既に除外済みのため、ここで Bot を全体除外しても
#         二重除外にならず安全。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_filter_event_style() {
  jq '[.[] | select((.user.type // "") != "Bot" and (.body // "") != "")]'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_general_truncate: 件数上限超過時に古い順 drop で削減
#   入力: $1=limit (件数上限)
#         stdin に一般コメント JSON 配列
#   出力: stdout に削減後の JSON 配列
#   AC #55 Req 3.1, 3.4
#
#   アルゴリズム:
#     1. 入力配列 length が limit 以下 → no-op（Req 3.4）
#     2. length > limit → created_at 昇順ソート → 末尾 limit 件を採用（古い順 drop）
#       新しいコメントが残るため、レビュワーが直近に追加した指摘を優先できる。
# ─────────────────────────────────────────────────────────────────────────────
pi_general_truncate() {
  local limit="${1:-50}"
  jq --argjson limit "$limit" \
    'if length <= $limit then . else (sort_by(.created_at // "") | .[-$limit:]) end'
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_collect_general_comments: 一般コメント収集 + 3 段フィルタ + 削減のオーケストレーション
#   入力: $1=pr_number
#         $2=pr_body (gh pr view --json body --jq '.body // ""' で取得済みの文字列)
#   出力: stdout に JSON 配列文字列。要素スキーマ:
#         { id, user, body, url, created_at }
#         取得失敗時 / コメント 0 件時は "[]"。
#   返り値: 0 固定（エラーは degraded path = "[]" + WARN ログに倒す）
#   AC #55 Req 1.1, 1.2, 1.5, 2.5, 3.2, 4.2, 4.3, 4.4, 4.6, 6.2, NFR 1.1, NFR 1.2,
#         NFR 2.1, NFR 2.2
#
#   設計判断:
#     - kind（design/impl）に依存する分岐を持たない（impl/design PR で共通呼び出し、Req 6.2）
#     - @claude 文字列を判定式に使わない（Req 2.7、`@claude` mention 必須を opt-out で
#       復活させる新規 env var を追加しない、Req 4.4）
#     - 上限値は内部定数 PI_GENERAL_MAX_COMMENTS（既定 50、env override 可）
#       README には載せない（運用上 default で十分、Req 4.4 の対象外）
#     - サマリは 1 行で出力し、truncate 発動時のみ pi_warn、それ以外は pi_log（NFR 2.2）
# ─────────────────────────────────────────────────────────────────────────────
pi_collect_general_comments() {
  local pr_number="$1"
  local pr_body="${2-}"
  local limit="${PI_GENERAL_MAX_COMMENTS:-50}"

  # 1. GitHub API から raw 一般コメントを取得（既存と同じ timeout / fall-back 方式）
  local raw_general
  if ! raw_general=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/issues/${pr_number}/comments" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント取得に失敗、空配列で続行"
    echo "[]"
    return 0
  fi

  # 2. 射影: { id, user, body, url, created_at } のスキーマに整形（Req 6.2 / Data Model）
  local projected
  if ! projected=$(echo "$raw_general" | jq '[.[] | {
        id,
        user: (.user.login // ""),
        body: (.body // ""),
        url: .html_url,
        created_at: (.created_at // ""),
        "_meta_user_type": (.user.type // "")
      }]' 2>/dev/null); then
    pi_warn "PR #${pr_number}: 一般コメント JSON の整形に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local fetched
  fetched=$(echo "$projected" | jq 'length' 2>/dev/null || echo "0")

  # 3. last-run TS を抽出（marker 不在時は空文字列 = 初回 round）
  local last_run
  last_run=$(pi_read_last_run "$pr_body")

  # 4. フィルタを順次適用しながら各段の length を測定
  #    順序: self → resolved → event_style → truncate
  local after_self after_resolved after_event final
  local filter_event_input

  # event_style filter は射影段で残した _meta_user_type を user.type の代理として使う
  # （元 jq schema を {id,user,body,url,created_at} に保つ理由: prompt template 互換）
  if ! after_self=$(echo "$projected" | pi_general_filter_self 2>/dev/null); then
    pi_warn "PR #${pr_number}: 自己投稿フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_self
  count_self=$(echo "$after_self" | jq 'length' 2>/dev/null || echo "0")

  if ! after_resolved=$(echo "$after_self" | pi_general_filter_resolved "$last_run" 2>/dev/null); then
    pi_warn "PR #${pr_number}: 過去 round フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_resolved
  count_resolved=$(echo "$after_resolved" | jq 'length' 2>/dev/null || echo "0")

  # event_style フィルタは _meta_user_type を user.type 相当に詰め直してから判定する
  filter_event_input=$(echo "$after_resolved" | jq '[.[] | . + {user: {type: ._meta_user_type, login: (.user)}}]' 2>/dev/null || echo "[]")
  if ! after_event=$(echo "$filter_event_input" | pi_general_filter_event_style 2>/dev/null); then
    pi_warn "PR #${pr_number}: event-style フィルタに失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  # スキーマ復元: user は文字列 (login) のみに戻し、_meta_user_type も落とす
  after_event=$(echo "$after_event" | jq '[.[] | {id, user: (.user.login // ""), body, url, created_at}]' 2>/dev/null || echo "[]")
  local count_event
  count_event=$(echo "$after_event" | jq 'length' 2>/dev/null || echo "0")

  if ! final=$(echo "$after_event" | pi_general_truncate "$limit" 2>/dev/null); then
    pi_warn "PR #${pr_number}: truncate に失敗、空配列で続行"
    echo "[]"
    return 0
  fi
  local count_final
  count_final=$(echo "$final" | jq 'length' 2>/dev/null || echo "0")

  # 5. サマリ 1 行ログ
  local filtered_self filtered_resolved filtered_event truncated
  filtered_self=$((fetched - count_self))
  filtered_resolved=$((count_self - count_resolved))
  filtered_event=$((count_resolved - count_event))
  truncated=$((count_event - count_final))

  # サマリは stderr に出力する（本関数の stdout は JSON 配列に予約されているため）。
  # pi_warn は元々 stderr 直行、pi_log は stdout のため明示的に >&2 で逃がす。
  if [ "$truncated" -gt 0 ]; then
    pi_warn "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=${truncated} (limit=${limit}), final=${count_final}"
  else
    pi_log "PR #${pr_number} general comments: fetched=${fetched}, filtered_self=${filtered_self}, filtered_resolved=${filtered_resolved}, filtered_event=${filtered_event}, truncated=0, final=${count_final}" >&2
  fi

  echo "$final"
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   入力: $1=pr_number, $2=new_round
#   AC 6.1, 7.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# pi_write_marker: PR body の hidden marker を round + last-run + no-progress-streak
#   の 3 フィールド形式で書き換える（Issue #122 Req 4.1 / 4.3 / 4.5）。
#   入力: $1=pr_number, $2=round, $3=no_progress_streak
#   戻り値: 0=成功, 1=失敗（呼び出し元で WARN + 据え置き、Req 5.4）
#
#   設計判断:
#     - marker prefix `<!-- idd-claude:pr-iteration ` と既存キー名 `round` / `last-run`
#       は変更しない（Req 4.3 / NFR 1.2）。`no-progress-streak=K` を末尾に追加。
#     - 既存 marker の置換 sed は `last-run=[^>]*` で末尾 `-->` 直前まで全部食うため、
#       旧フォーマット（no-progress-streak 無し）も同じ正規表現で吸収できる（Req 4.4）。
#     - 副作用なし（PR body 書き込み 1 回のみ。コメント投稿は呼び出し元で別途実施）。
# ─────────────────────────────────────────────────────────────────────────────
pi_write_marker() {
  local pr_number="$1"
  local round="$2"
  local streak="$3"
  local now
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  local body
  if ! body=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr view "$pr_number" --repo "$REPO" --json body --jq '.body // ""' 2>/dev/null); then
    pi_warn "PR #${pr_number}: body 取得に失敗、marker 更新をスキップ"
    return 1
  fi

  local marker="<!-- idd-claude:pr-iteration round=${round} last-run=${now} no-progress-streak=${streak} -->"
  local new_body
  if echo "$body" | grep -qE 'idd-claude:pr-iteration round=[0-9]+'; then
    # 既存 marker を最新 marker で置換（複数あった場合も全部 1 つに集約）。
    # `last-run=[^>]*` は末尾 `-->` 直前まで貪欲に食うため、no-progress-streak 有無の
    # どちらの旧 marker も同じ regex で置換できる（Req 4.4）。
    new_body=$(echo "$body" | sed -E "s|<!-- idd-claude:pr-iteration round=[0-9]+ last-run=[^>]*-->|${marker}|g")
  else
    # 末尾に追記（前置の改行で見やすく）
    new_body="${body}

${marker}"
  fi

  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr edit "$pr_number" --repo "$REPO" --body "$new_body" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: PR body の hidden marker 更新に失敗"
    return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_comment: round 着手表明コメントを投稿する（marker 書き込みなし）
#   入力: $1=pr_number, $2=new_round, $3=max_rounds (表示用、`0`=無制限表記)
#   戻り値: 0 固定（コメント投稿失敗は WARN のみ。ラベル誤遷移リスクが無いため
#           round 全体を失敗扱いにはしない / NFR 1.1 既存挙動踏襲）
#   Issue #122 Req 1.6 / 2.4
#
#   設計判断:
#     - 既存 pi_post_processing_marker は「marker 書き込み + コメント投稿」の合成だったが、
#       #122 で「失敗 round では marker を据え置く」（Req 5）が必要になったため、
#       marker 書き込みは round 終了時に成功 path でのみ行うよう分離した。
#     - コメントは round 開始時の人間向け視認用なので、claude 実行前に投稿する
#       （既存挙動 NFR 1.1 と等価）。
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_comment() {
  local pr_number="$1"
  local new_round="$2"
  local max_rounds="${3:-$PR_ITERATION_MAX_ROUNDS}"

  local max_display
  if [ "$max_rounds" = "0" ]; then
    max_display="無制限"
  else
    max_display="$max_rounds"
  fi
  local processing_msg
  processing_msg=$(printf '%s\n%s' \
    ":robot: PR Iteration Processor が処理を開始しました (round ${new_round}/${max_display})。" \
    "<!-- idd-claude:pr-iteration-processing round=${new_round} -->")
  if ! timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh pr comment "$pr_number" --repo "$REPO" --body "$processing_msg" >/dev/null 2>&1; then
    pi_warn "PR #${pr_number}: 着手表明コメントの投稿に失敗"
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# pi_post_processing_marker: PR body に hidden marker を書き込み + 着手表明コメント投稿
#   （Issue #26 / #35 で導入された合成関数。互換性のため温存するが、Issue #122 以降の
#   pi_run_iteration は pi_write_marker / pi_post_processing_comment を直接呼ぶ。
#   外部から本関数を呼んでいる箇所が無いことを確認済み 2026-05 時点）
#   入力: $1=pr_number, $2=new_round, $3=streak (省略時 0 / 後方互換)
#         $4=max_rounds (表示用、省略時 PR_ITERATION_MAX_ROUNDS / 後方互換)
#   AC 6.1, 7.1 / Issue #122 Req 4.1 / 6.1
#   戻り値: 0=成功, 1=失敗（呼び出し元で iteration を中断）
# ─────────────────────────────────────────────────────────────────────────────
pi_post_processing_marker() {
  local pr_number="$1"
  local new_round="$2"
  local streak="${3:-0}"
  local max_rounds="${4:-$PR_ITERATION_MAX_ROUNDS}"

  if ! pi_write_marker "$pr_number" "$new_round" "$streak"; then
    return 1
  fi
  pi_post_processing_comment "$pr_number" "$new_round" "$max_rounds"
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
  local line_comments_json="[]"
  local reviews_json latest_review_id
  if reviews_json=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
      gh api "/repos/${REPO}/pulls/${pr_number}/reviews" 2>/dev/null); then
    latest_review_id=$(echo "$reviews_json" | jq -r 'if length > 0 then (.[length-1].id|tostring) else "" end')
    if [ -n "$latest_review_id" ]; then
      local raw_line
      if raw_line=$(timeout "$PR_ITERATION_GIT_TIMEOUT" \
          gh api "/repos/${REPO}/pulls/${pr_number}/reviews/${latest_review_id}/comments" 2>/dev/null); then
        line_comments_json=$(echo "$raw_line" | jq '[.[] | {id, path, line, user: (.user.login // ""), body}]')
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
  local pi_soft_fail_file pi_recover_file pi_sha_file
  pi_soft_fail_file=$(mktemp -t "pi-softfail-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  pi_recover_file=$(mktemp -t "pi-recover-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  pi_sha_file=$(mktemp -t "pi-sha-${pr_number}-XXXXXX" 2>/dev/null || mktemp)
  : > "$pi_soft_fail_file"
  : > "$pi_recover_file"
  : > "$pi_sha_file"

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
    else
      pi_log "PR #${pr_number}: kind=${kind} Claude 実行完了 (log: ${pi_log_file})"
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
  rm -f "$pi_soft_fail_file" "$pi_recover_file" "$pi_sha_file"

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
    # Issue #122 Req 3.1 / 3.2: SHA 比較で「新規 commit が push されたか」判定。
    # before_sha と after_sha が異なれば新規 commit あり（claude 自身による commit+push、
    # または pi_auto_commit_and_push 経由の auto-commit、いずれもカバー）。
    local commit_pushed=false
    if [ -n "$before_sha" ] && [ -n "$after_sha" ] && [ "$before_sha" != "$after_sha" ]; then
      commit_pushed=true
    fi
    # Issue #122 Req 3.1 / 3.2: no-progress 連続カウンタの更新
    local new_streak
    if [ "$commit_pushed" = "true" ]; then
      new_streak=0
    else
      new_streak=$((prev_streak + 1))
    fi

    # Issue #122 Req 6.2: round 終了時点で no-progress 連続カウンタが加算されたら
    # PR 番号 / kind / 加算後の連続カウンタ / 上限値を 1 行ログに記録
    if [ "$commit_pushed" = "false" ]; then
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} limit=${PR_ITERATION_NO_PROGRESS_LIMIT}"
    fi

    # Issue #122 Req 5.4 / Req 4.1: marker 書き込み。失敗は Req 5.4 の通り ERROR + 据え置き
    if ! pi_write_marker "$pr_number" "$next_round" "$new_streak"; then
      pi_error "PR #${pr_number}: kind=${kind} round=${next_round} marker 書き込みに失敗 (needs-iteration を残置)"
      return 1
    fi

    # Issue #122 Req 3.3 / 6.3: no-progress 連続カウンタが上限以上に達したら escalate
    if [ "$new_streak" -ge "$PR_ITERATION_NO_PROGRESS_LIMIT" ]; then
      pi_log "PR #${pr_number}: kind=${kind} round=${next_round} no-progress-streak=${new_streak} reason=no-progress escalate"
      pi_escalate_to_failed "$pr_number" "$next_round" "$max_rounds" "no-progress" "$new_streak" || true
      return 2
    fi

    # AC 6.2 (#26) / #35 AC 3.1 / 3.2: kind に応じたラベル遷移
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
  # AC 2.1: opt-in gate
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

# Issue #119 Req 1.4 / 1.6: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
drr_log() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: $*"
}
drr_warn() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: WARN: $*" >&2
}
drr_error() {
  echo "[$(date '+%F %T')] [$REPO] design-review-release: ERROR: $*" >&2
}

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
  # AC 1.1 / 1.4 / 7.5: opt-in gate（無効化時は完全スキップ）
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
# Stage A Verify Module (#125) — Stage A 完了直前の verify ゲート
#
# Stage A（Developer 実装）完了直前に `tasks.md` 末尾の build/test/lint コマンド
# （verify タスク）を watcher 自身が REPO_DIR で独立再実行することで、Developer
# の自己申告のみで build 不通が Stage A を通過するのを防ぐゲート。
#
# 関数群:
#   - sav_log / sav_warn / sav_error           : `stage-a-verify:` prefix logger
#                                                （Issue #119 規約に従い `[$REPO]` 付き）
#   - stage_a_verify_extract_command           : tasks.md 末尾走査 + keyword 一致抽出
#   - stage_a_verify_resolve_command           : STAGE_A_VERIFY_COMMAND escape hatch
#                                                + tasks.md 抽出の合成
#   - stage_a_verify_round_path / _read_round  : sidecar による round counter 永続化
#     / _bump_round / _reset_round
#   - _sav_handle_failure                      : round=1 差し戻し / round=2 escalate
#   - stage_a_verify_run                       : 統合ランナー（resolve → execute →
#                                                log → 戻り値）
#
# 設計参照: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# stage-a-verify 専用ロガー（既存 qa_log と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` の 3 段 prefix を維持し、
# `grep '\[.*\] stage-a-verify:'` で全件抽出可能（NFR 4.1, NFR 4.2）。
sav_log() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: $*"
}
sav_warn() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: WARN: $*" >&2
}
sav_error() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: ERROR: $*" >&2
}

# ─── stage_a_verify_extract_command ───
#
# `tasks.md` を 1 パスで走査し、抽出キーワード集合に一致した行のうち
# **末尾（ファイル末尾に最も近いもの）** 1 行を stdout に出力する（Req 1.1, 1.2）。
# 抽出は言語非依存な文字列パターンのみで行う（AST 解析しない、Req 1.5 / NFR 2.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 抽出成功 / 1 = 一致なし or tasks.md 不在
# stdout: 抽出した shell コマンド 1 行（成功時のみ）
#
# 抽出キーワード集合は design.md「Components and Interfaces /
# stage_a_verify_extract_command」で確定したもの。新言語追加時はここに 1 行追加する
# だけで対応可能。未対応言語は `STAGE_A_VERIFY_COMMAND` env で escape する。
stage_a_verify_extract_command() {
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  [ -f "$tasks_path" ] || return 1

  # 言語非依存 keyword 集合。1 行 1 keyword で空白区切り（awk 内で再分割）。
  # 各 keyword は「行に部分一致したら verify タスクとみなす」最小単位。
  #   - `./gradlew` / `gradle ` / `mvn ` : JVM 系 build tool
  #   - `npm test` / `npm run` / `npm ci` / `pnpm ` / `yarn ` : Node.js 系
  #     （`npm install` は依存解決なので含めない）
  #   - `cargo ` : Rust
  #   - `go test` / `go build` / `go vet` : Go
  #   - `pytest` / `python -m pytest` / `python -m unittest` : Python
  #   - `make test` / `make build` / `make check` / `make verify` : make（target 限定）
  #   - `bundle exec` / `rake ` : Ruby
  #   - `dotnet test` / `dotnet build` : .NET
  #   - `shellcheck` / `actionlint` : shell 系プロジェクト（idd-claude 自身を含む）
  #   - `tox ` : Python tox
  #   - `swift test` / `swift build` : Swift
  local _SAV_KEYWORDS
  _SAV_KEYWORDS=$'./gradlew\n'
  _SAV_KEYWORDS+=$'gradle \n'
  _SAV_KEYWORDS+=$'mvn \n'
  _SAV_KEYWORDS+=$'npm test\n'
  _SAV_KEYWORDS+=$'npm run\n'
  _SAV_KEYWORDS+=$'npm ci\n'
  _SAV_KEYWORDS+=$'pnpm \n'
  _SAV_KEYWORDS+=$'yarn \n'
  _SAV_KEYWORDS+=$'cargo \n'
  _SAV_KEYWORDS+=$'go test\n'
  _SAV_KEYWORDS+=$'go build\n'
  _SAV_KEYWORDS+=$'go vet\n'
  _SAV_KEYWORDS+=$'pytest\n'
  _SAV_KEYWORDS+=$'python -m pytest\n'
  _SAV_KEYWORDS+=$'python -m unittest\n'
  _SAV_KEYWORDS+=$'make test\n'
  _SAV_KEYWORDS+=$'make build\n'
  _SAV_KEYWORDS+=$'make check\n'
  _SAV_KEYWORDS+=$'make verify\n'
  _SAV_KEYWORDS+=$'bundle exec\n'
  _SAV_KEYWORDS+=$'rake \n'
  _SAV_KEYWORDS+=$'dotnet test\n'
  _SAV_KEYWORDS+=$'dotnet build\n'
  _SAV_KEYWORDS+=$'shellcheck\n'
  _SAV_KEYWORDS+=$'actionlint\n'
  _SAV_KEYWORDS+=$'tox \n'
  _SAV_KEYWORDS+=$'swift test\n'
  _SAV_KEYWORDS+=$'swift build'

  # awk 1 パス走査で「直近で keyword に一致した行」を変数 last に保持し、
  # ファイル末尾まで読んだら最後の保持値を出力する（= 末尾に最も近い 1 行、
  # Req 1.2 / #160 Req 1.3, 2.2, 2.3）。O(N) 線形時間（NFR 3.1 / #160 NFR 2.1）。
  #
  # #160 修正: backtick で囲まれたインラインコードスパン（`...`）が行内にあり、
  #   その中身が keyword に一致した場合、**スパン内の中身のみ** を抽出する
  #   （Req 1.1）。散文 + backtick で書かれた verify 行（例: `- lint 緑:
  #   \`./gradlew :app:lintDebug\` で新規 error なし`）が exit 127 を起こす
  #   regression（#125 で導入）を解消する。
  #   同一行に複数のインラインコードスパンが存在する場合は、最初に keyword に
  #   一致したスパンの中身を採用（Req 1.2）。
  #   行内に backtick がペアで存在せず、行全体が keyword に部分一致した場合は
  #   従来通り「装飾除去後の行全体」を採用する（Req 2.1 / 後方互換）。
  #   複数行 fenced code block（` ``` ` フェンスで囲まれた範囲）内の行は
  #   抽出対象から除外する（Req 3.1）。
  # 装飾 strip:
  #   - 行頭の "- " / "  - " / "  - [ ] " 等の markdown bullet と list checkbox
  #   - 行頭 / 行末の空白
  # 抽出結果は装飾を除いたコマンド本体のみ（後段の `bash -c` で実行可能な形）。
  local result
  result=$(awk -v kws="$_SAV_KEYWORDS" '
    BEGIN {
      n = split(kws, ARR, "\n")
      last = ""
      in_fence = 0
    }
    {
      raw = $0
      # 複数行 fenced code block の境界判定（行頭 ``` で開閉、言語タグ任意）。
      # in_fence 状態の行は keyword マッチ対象から除外する（#160 Req 3.1, 3.2）。
      if (raw ~ /^[[:space:]]*```/) {
        in_fence = (in_fence == 0) ? 1 : 0
        next
      }
      if (in_fence) { next }

      line = raw
      # markdown bullet / checkbox / アスタリスク（deferrable 印）の装飾除去
      sub(/^[[:space:]]+/, "", line)
      sub(/^-[[:space:]]+/, "", line)
      sub(/^\[[[:space:]xX]\]\*?[[:space:]]+/, "", line)
      sub(/^[0-9]+(\.[0-9]+)*[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)

      # インラインコードスパン抽出（#160 Req 1.1, 1.2）:
      #   バッククォートで囲まれた中身を順に走査し、最初に keyword 一致した
      #   スパンの中身を採用する。
      span_hit = 0
      span_content = ""
      tail = line
      while (1) {
        p1 = index(tail, "`")
        if (p1 == 0) { break }
        rest = substr(tail, p1 + 1)
        p2 = index(rest, "`")
        if (p2 == 0) { break }
        candidate = substr(rest, 1, p2 - 1)
        for (i = 1; i <= n; i++) {
          kw = ARR[i]
          if (kw == "") continue
          if (index(candidate, kw) > 0) {
            span_content = candidate
            span_hit = 1
            break
          }
        }
        if (span_hit) { break }
        tail = substr(rest, p2 + 1)
      }
      if (span_hit) {
        last = span_content
        next
      }

      # backtick 無し / backtick はあるが keyword 不一致の場合は、装飾除去後の
      # 行全体が keyword に部分一致するか従来ロジックで判定（#160 Req 2.1 後方互換）。
      # ただし line に backtick がペアで含まれる場合は「散文+backtick で keyword は
      # スパン外にしか出現しない」ケース（#160 の本丸 regression）なので行全体採用
      # は誤動作を起こす。よって backtick ペアが存在する場合は line fallback を
      # 行わず、当該行を抽出候補から除外する（Req 1.4 / Req 5.1）。
      bt_count = gsub(/`/, "`", line)
      if (bt_count >= 2) { next }

      for (i = 1; i <= n; i++) {
        kw = ARR[i]
        if (kw == "") continue
        if (index(line, kw) > 0) {
          last = line
          break
        }
      }
    }
    END {
      if (last != "") print last
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── stage_a_verify_resolve_command ───
#
# `STAGE_A_VERIFY_COMMAND` env が非空ならそれを最優先で採用し（escape hatch、
# Req 4.4 / NFR 2.2）、空ならば `stage_a_verify_extract_command` を呼ぶ。
#
# 入力: 環境変数 STAGE_A_VERIFY_COMMAND / REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 解決成功 / 1 = SKIPPED (env 空 + tasks.md 抽出不能)
# stdout: 解決した shell コマンド 1 行（成功時のみ）
stage_a_verify_resolve_command() {
  if [ -n "${STAGE_A_VERIFY_COMMAND:-}" ]; then
    printf '%s\n' "$STAGE_A_VERIFY_COMMAND"
    return 0
  fi
  local cmd
  cmd=$(stage_a_verify_extract_command) || return 1
  [ -n "$cmd" ] || return 1
  printf '%s\n' "$cmd"
}

# ─── stage_a_verify_round_path ───
#
# round counter sidecar の絶対パスを stdout に出す。Issue ごとに spec dir 配下に
# `.stage-a-verify-round` という dotfile を 1 つ置く設計（design.md「Components
# and Interfaces / stage_a_verify_round_path」採用案）。worktree slot ごとの
# `$REPO_DIR` が自然に slot 隔離を担保する。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 絶対パス（必ず 1 行）
stage_a_verify_round_path() {
  printf '%s\n' "$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-round"
}

# ─── stage_a_verify_read_round ───
#
# round counter を stdout に整数で出す。ファイル不在は "0"（未失敗）。
# 不正な内容（非数値）は安全側で "0" にフォールバック。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 整数 1 行 ("0" / "1" / "2" 等)
# 戻り値: 0（read は失敗しない設計）
stage_a_verify_read_round() {
  local path
  path=$(stage_a_verify_round_path)
  local val=""
  if [ -f "$path" ]; then
    val=$(head -n1 "$path" 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "0"
  fi
}

# ─── stage_a_verify_bump_round ───
#
# round counter を 1 増やして永続化する。不在からの初回呼び出しは "1" を書く。
# 書き込み失敗（disk full / permission denied 等）は sav_error で警告し、
# 呼び出し元（_sav_handle_failure）は read_round の結果が 0 のままになるので
# 差し戻し挙動（round=1）に倒れる安全側設計。
#
# 戻り値: 0 = 書き込み成功 / 1 = 書き込み失敗
stage_a_verify_bump_round() {
  local path cur next
  path=$(stage_a_verify_round_path)
  cur=$(stage_a_verify_read_round)
  next=$((cur + 1))
  # spec dir 自体が存在しない場合は SKIPPED 経路で呼ばれていないはずだが、念のため mkdir -p
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if ! printf '%d\n' "$next" > "$path" 2>/dev/null; then
    sav_error "round counter 書き込みに失敗 path=$path next=$next"
    return 1
  fi
  return 0
}

# ─── stage_a_verify_reset_round ───
#
# round counter sidecar を削除する。SUCCESS / claude-failed escalate 後に呼ぶ。
# 不在時は no-op（rm -f の挙動に従う）。
stage_a_verify_reset_round() {
  local path
  path=$(stage_a_verify_round_path)
  rm -f "$path" 2>/dev/null || true
}

# Stage Checkpoint Module は後続節で定義される（順序維持のため stage_a_verify_run /
# _sav_handle_failure は mark_issue_failed 等の本体 helper が定義された後の位置で実装する）。

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
# アルゴリズム（design.md「diff range 解決アルゴリズム」節）:
#   1. `$BASE_BRANCH..HEAD` 範囲の `docs(tasks): mark <id> as done` commit を時系列昇順で全列挙
#   2. 当該 task_id の mark commit SHA を特定（range_end）
#   3. 全 mark commit 列の中で range_end の直前要素を range_start とする
#   4. 直前要素が存在しない（初回 task）場合は range_start = `$BASE_BRANCH` の SHA
#   5. 当該 task の mark commit が見つからない場合は return 1
#
# Requirements: 3.2, 4.5, 5.4
pt_resolve_diff_range() {
  local task_id="$1"
  local base="${BASE_BRANCH:-main}"

  # 全 mark commit を時系列昇順で取得（--reverse で oldest 先頭）
  local all_marks
  all_marks=$(git log --grep="^docs(tasks): mark " --format=%H --reverse "${base}..HEAD" 2>/dev/null || true)
  if [ -z "$all_marks" ]; then
    return 1
  fi

  # 当該 task の mark commit を特定（範囲内で最後のマッチを採用）
  local current_mark
  current_mark=$(git log --grep="^docs(tasks): mark ${task_id} as done\$" --format=%H "${base}..HEAD" 2>/dev/null | head -1 || true)
  if [ -z "$current_mark" ]; then
    return 1
  fi

  # all_marks 内で current_mark の直前要素を探す
  local prev_mark="" line
  while IFS= read -r line; do
    if [ "$line" = "$current_mark" ]; then
      break
    fi
    prev_mark="$line"
  done <<<"$all_marks"

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

2. **進捗マーカー更新**（既存 #67 / #112 規約を流用）:
   - 対象 task の \`- [ ] ${task_id}\` 行を \`- [x] ${task_id}\` に書き換える
   - 子タスク（例: ${task_id}.1）を完了した場合、親 task（${task_id} の親、例: ${task_id%.*}）
     配下の全子タスクが \`- [x]\` になったタイミングで親も \`- [x]\` に昇格する
   - 進捗マーカー更新は **専用 commit**: \`docs(tasks): mark <id> as done\`
     - 当該 commit には \`tasks.md\` 以外のファイルを含めない
     - 親 task 昇格も同じ commit メッセージ形式（\`docs(tasks): mark <親 id> as done\`）
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
#   2  = 異常終了（claude crash / parse 失敗 / RESULT 行欠落 / diff range 解決失敗）
#   99 = quota 超過
#
# Requirements: 3.1, 3.2, 3.3, NFR 2.1, NFR 2.2, NFR 2.3
run_per_task_reviewer() {
  local task_id="$1"
  local round="$2"

  # diff range 解決
  local range_line range_start range_end
  if ! range_line=$(pt_resolve_diff_range "$task_id"); then
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-resolve-failed" >> "$LOG"
    return 2
  fi
  range_start=$(printf '%s' "$range_line" | cut -f1)
  range_end=$(printf '%s' "$range_line" | cut -f2)
  if [ -z "$range_start" ] || [ -z "$range_end" ]; then
    pt_log "task=$task_id reviewer start round=$round result=error reason=diff-range-empty" >> "$LOG"
    return 2
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

# ─── run_per_task_loop ───
#
# Stage A の代替実体。未完了 task を numeric ID 順に 1 件ずつ Implementer + Reviewer で
# 消化する dispatcher。
#
# 戻り値:
#   0  = 全 task 消化成功（Stage A 完了相当）または pending 0 件で no-op
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
  if [ ! -f "$tasks_md" ]; then
    pt_warn "tasks.md が存在しません: $tasks_md → 通常 Stage A にフォールバック相当として return 1"
    mark_issue_failed "per-task-tasks-missing" "per-task ループ起動に必要な \`tasks.md\` が見つかりません: \`$tasks_md\`。"
    return 1
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
          *)
            echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=2) 異常終了 → claude-failed" | tee -a "$LOG"
            mark_issue_failed "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=2) が異常終了しました（claude crash / parse 失敗）。\`$LOG\` を確認してください。"
            return 1
            ;;
        esac
        ;;
      *)
        # round=1 reviewer error → claude-failed
        echo "❌ #$NUMBER: per-task Reviewer (task=$task_id, round=1) 異常終了 → claude-failed" | tee -a "$LOG"
        mark_issue_failed "per-task-reviewer-error" "per-task ループの Reviewer (task=\`${task_id}\`, round=1) が異常終了しました（claude crash / parse 失敗 / diff range 解決失敗）。\`$LOG\` を確認してください。"
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

# ─── _sav_handle_failure ───
#
# stage_a_verify_run の失敗パス共通処理。round counter を bump し、
# round=1 なら Developer 差し戻し（Issue コメント投稿 + return 1）、
# round=2 以降なら mark_issue_failed 経由で claude-failed 化（return 2）。
# `needs-iteration` ラベルは Issue 側には付与しない既存契約（NFR 1.2）を維持。
#
# 入力:
#   $1 = kind ("timeout" | "exit")
#   $2 = detail (timeout 秒 | exit code)
# 戻り値:
#   1 = Developer 差し戻し（次 tick で stage-a-verify 再評価）
#   2 = claude-failed 付与済み（watcher 退出）
_sav_handle_failure() {
  local kind="$1"
  local detail="$2"
  stage_a_verify_bump_round || sav_error "round counter 書き込みに失敗（差し戻し挙動を強制）"
  local round
  round=$(stage_a_verify_read_round)
  case "$round" in
    1)
      sav_log "round=1 outcome=needs-iteration (Developer 差し戻し)"
      # round=1 差し戻しコメント。`needs-iteration` ラベルは PR 専用契約であり
      # Issue 側には付与しない（NFR 1.2 / 既存 L2860 / L5989 契約）。次 tick で
      # Stage Checkpoint が START_STAGE=B を返しても、Stage B 開始前の
      # stage-a-verify ゲートで再評価される（design.md「stage-a-verify と
      # Stage Checkpoint の協調」参照）。
      local comment_body
      comment_body="🔁 stage-a-verify が失敗しました（round=1 / ${kind}=${detail}）。

\`tasks.md\` 末尾の verify タスク（build/test/lint）を watcher が REPO_DIR で独立再実行したところ、exit code が 0 以外でした。

- 検出されたコマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- 次サイクルで Developer が再実装し、Stage B 開始前に stage-a-verify が再評価されます
- 修正後に \`./gradlew\` / \`npm test\` 等のローカル成功を確認してから commit/push してください

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1 || \
        sav_warn "gh issue comment 投稿に失敗（差し戻し挙動は継続）"
      return 1
      ;;
    *)
      sav_log "round=$round outcome=claude-failed (escalate to human)"
      stage_a_verify_reset_round
      local extra_body
      extra_body="stage-a-verify（\`tasks.md\` 末尾 verify タスクの独立再実行）が連続 ${round} 回失敗しました（${kind}=${detail}）。

- 検出コマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- \`tasks.md\` 末尾の build/test/lint コマンドをローカルで通してから \`claude-failed\` を外してください
- 一時的に gate を skip したい場合は cron / launchd 側で \`STAGE_A_VERIFY_ENABLED=false\` を渡してください（Req 4.1 / NFR 1.1）

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      mark_issue_failed "stageA-verify" "$extra_body"
      return 2
      ;;
  esac
}

# ─── stage_a_verify_run ───
#
# Stage A Verify Module の統合ランナー。`run_impl_pipeline` の Stage A 成功直後・
# Stage B 開始直前から 1 度だけ呼ばれる。
#
# 入力 (環境変数経由):
#   REPO / REPO_DIR / SPEC_DIR_REL / NUMBER / LOG
#   STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT / STAGE_A_VERIFY_COMMAND
# 戻り値:
#   0 = SUCCESS / SKIPPED / DISABLED → Stage A 完全完了として続行
#   1 = FAILED (round=1) → 差し戻し済、次 tick で再試行
#   2 = FAILED (round=2 以降) → mark_issue_failed 済（claude-failed 付与）、watcher 退出
# 副作用:
#   - cron.log / $LOG に 1 行以上の `[$REPO] stage-a-verify:` ログ（NFR 4.1）
#   - round counter sidecar の read/bump/reset
#   - 失敗時に gh issue comment（round=1 差し戻し / round=2 は mark_issue_failed が発火）
#
# 不変条件:
#   - 1 回の呼び出しで `stage-a-verify:` 行を必ず 1 行以上出力（NFR 4.1）
#   - 抽出した cmd は `bash -c` に **そのまま**渡し、watcher 側で `&&` / `||` / `;` を
#     解釈しない（Req 1.3）
stage_a_verify_run() {
  # ── Gate 1: DISABLED ──
  # `STAGE_A_VERIFY_ENABLED=false` 明示時のみ skip（`=false` 厳密一致、Req 4.1 /
  # NFR 1.1）。`:-true` で `unset` も既定有効として扱う。
  if [ "${STAGE_A_VERIFY_ENABLED:-true}" = "false" ]; then
    sav_log "DISABLED reason=env-opt-out"
    return 0
  fi

  # ── Gate 2: SKIPPED（解決できない / 一致なし）──
  local cmd
  if ! cmd=$(stage_a_verify_resolve_command); then
    sav_log "SKIPPED reason=no-verify-task-in-tasks-md"
    return 0
  fi

  # ── Execute ──
  local _timeout="${STAGE_A_VERIFY_TIMEOUT:-600}"
  # cmd の shell エスケープは printf %q で安全側に倒し、ログ復元性を確保する。
  sav_log "EXEC issue=#${NUMBER:-?} timeout=${_timeout}s cmd=$(printf '%q' "$cmd")"
  local rc=0
  # subshell `(cd && ...)` で cwd を REPO_DIR に隔離（NFR 5.1）。
  # `timeout --kill-after=10 "$_timeout"` で暴走を時間でも遮断し、タイムアウト到達時は
  # 子孫プロセスも SIGKILL する（NFR 5.2）。
  (cd "$REPO_DIR" && timeout --kill-after=10 "$_timeout" bash -c "$cmd") \
      >> "$LOG" 2>&1 || rc=$?

  # ── 結果分岐 ──
  case "$rc" in
    0)
      sav_log "SUCCESS exit=0"
      stage_a_verify_reset_round
      return 0
      ;;
    124)
      sav_warn "TIMEOUT timeout=${_timeout}s exit=124"
      _sav_handle_failure "timeout" "$_timeout"
      return $?
      ;;
    *)
      sav_warn "FAILED exit=$rc"
      _sav_handle_failure "exit" "$rc"
      return $?
      ;;
  esac
}

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
      if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then
        echo "--- Stage A 実行（$MODE / per-task loop / PER_TASK_LOOP_ENABLED=true）---" >> "$LOG"
        if ! run_per_task_loop; then
          # run_per_task_loop 内で claude-failed 付与済 / 既に Issue コメント済。
          return 1
        fi
        # per-task loop 内で逐次 commit + push される規約のため、loop 終了後の HEAD は
        # 通常 ahead=0。万一 push 漏れがあれば verify_pushed_or_retry が 1 回リトライする。
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

# ─── Phase C: Worktree Manager ───
#
# Per-slot 永続 worktree を $WORKTREE_BASE_DIR/<repo-slug>/slot-N/ に配置し、
# slot 同士の作業ツリー干渉を物理隔離する（Req 3.5）。
#
# 設計判断:
#   - slot worktree は `git worktree add --detach` で detached HEAD として作成する
#     （Slot Runner が `git checkout -B <branch> $BASE_BRANCH` で新規 branch に
#     切り替える際、他 slot の worktree が同じ local branch を保持していても
#     ブロックされないため）
#   - `git worktree list --porcelain` で冪等性を担保
#   - 破損検出時は <slot-N>.broken-<ts> に退避してから再作成
#   - PARALLEL_SLOTS=1 のときは slot-2 以降の worktree を作らない（呼び出し元で gate）

# slot 番号から worktree ディレクトリの絶対パスを返す。
# 引数: $1 = slot 番号
# Req 3.1, 3.7
_worktree_path() {
  local n="$1"
  echo "$WORKTREE_BASE_DIR/$REPO_SLUG/slot-$n"
}

# 指定 path が現在の repo の git worktree として登録済みかを判定。
# 0 = 登録済み / 非ゼロ = 未登録
_worktree_is_registered() {
  local wt_path="$1"
  # `git worktree list --porcelain` は `worktree <abs_path>` 形式で各 worktree を返す
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null \
    | grep -Fx "worktree $wt_path" >/dev/null 2>&1
}

# Per-slot worktree を冪等に確保する。
# 引数: $1 = slot 番号
# 戻り値: 0 = ok（worktree が存在し利用可能） / 1 = 失敗（呼び出し元で claude-failed 化）
# 副作用: $WORKTREE_BASE_DIR/<slug>/slot-N/ を作成または再利用
#
# Req 3.1, 3.2, 3.3, 3.6, 3.7
_worktree_ensure() {
  local n="$1"
  local wt_path
  wt_path="$(_worktree_path "$n")"
  local parent_dir
  parent_dir="$(dirname "$wt_path")"

  if ! mkdir -p "$parent_dir" 2>/dev/null; then
    dispatcher_warn "slot-${n}: worktree 親ディレクトリ作成に失敗: $parent_dir"
    return 1
  fi

  # ケース A: 既に worktree として登録済み → 再利用（Req 3.3）
  if _worktree_is_registered "$wt_path"; then
    if [ -d "$wt_path/.git" ] || [ -f "$wt_path/.git" ]; then
      return 0
    fi
    # 登録は残っているが実体が壊れている → prune してから再作成
    dispatcher_warn "slot-${n}: worktree 登録あり実体欠損、prune して再作成: $wt_path"
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース B: dir は存在するが worktree として登録されていない（未初期化 or 破損）
  if [ -e "$wt_path" ]; then
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local broken="${wt_path}.broken-${ts}"
    dispatcher_warn "slot-${n}: 既存ディレクトリを退避して worktree を再作成: $wt_path -> $broken"
    if ! mv "$wt_path" "$broken" 2>/dev/null; then
      dispatcher_warn "slot-${n}: 既存ディレクトリの退避に失敗: $wt_path"
      return 1
    fi
    git -C "$REPO_DIR" worktree prune >/dev/null 2>&1 || true
  fi

  # ケース C: 新規作成（origin/$BASE_BRANCH から detached HEAD として）
  # detached にする理由: 各 slot が `git checkout -B <branch> $BASE_BRANCH` で新規
  # branch に切り替える際、別 slot worktree が同じ local branch を持っていても
  # 弾かれないため。
  if ! git -C "$REPO_DIR" worktree add --detach "$wt_path" "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    dispatcher_warn "slot-${n}: git worktree add に失敗: $wt_path"
    return 1
  fi
  dispatcher_log "slot-${n}: worktree 作成: $wt_path (detached @ origin/${BASE_BRANCH})"
  return 0
}

# Per-slot worktree を origin/$BASE_BRANCH の最新状態に強制リセットする
# （Issue 投入時に毎回呼ぶ）。
# 引数: $1 = worktree 絶対パス
# 戻り値: 0 = ok / 1 = 失敗
# 副作用: 当該 worktree が origin/$BASE_BRANCH の最新コミットに head=detached、
#   tracked / untracked / ignored すべて消去される
#
# Req 3.4
_worktree_reset() {
  local wt="$1"
  if [ ! -d "$wt" ]; then
    return 1
  fi
  # 1. 最新の origin を取得
  if ! git -C "$wt" fetch origin --prune >/dev/null 2>&1; then
    return 1
  fi
  # 2. detached HEAD を origin/$BASE_BRANCH に強制移動
  if ! git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    return 1
  fi
  # 3. untracked + ignored を消去（前回 Issue の build artifact / node_modules を残さない）
  if ! git -C "$wt" clean -fdx >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# ─── Phase C: Slot Lock Manager ───
#
# Per-slot 非ブロッキング flock を提供する。slot 間のロックは別ファイルとし、
# ある slot の処理が他 slot の処理開始をブロックしない（Req 4.4）。
#
# fd 番号: 既存 LOCK_FILE が fd 200 を使うため、衝突回避で 210 + slot_number を使う。
# 従って bash の per-fd 上限以下になるよう、PARALLEL_SLOTS は事実上 ~ 数十程度を想定
# （CLAUDE.md には bash 4+ と記載済、bash の fd 上限は通常数百〜数千）。
#
# slot Worker はサブシェル `( ... ) &` で動くため、サブシェル終了で fd は自動解放され、
# 明示的な _slot_release 呼び出しは不要だが命名対称性のため定義する。

# slot 番号から lock file path を返す。
# 引数: $1 = slot 番号
# Req 4.1
_slot_lock_path() {
  local n="$1"
  echo "$SLOT_LOCK_DIR/${REPO_SLUG}-slot-${n}.lock"
}

# 指定 slot の per-slot 非ブロッキング flock を取得する（成功時 fd 210+N が open のまま残る）。
# 引数: $1 = slot 番号
# 戻り値: 0 = acquired / 1 = 既に他プロセスがロック中、または fd open 失敗
# 副作用: 成功時 fd (210+N) が open 状態（呼び出し側スコープで保持される）
#
# Req 4.2, 4.3, 4.4
_slot_acquire() {
  local n="$1"
  local lock_file
  lock_file="$(_slot_lock_path "$n")"
  # parent dir を冪等作成（SLOT_LOCK_DIR は通常 $HOME/.issue-watcher で既存）
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || return 1
  local fd=$((210 + n))
  # eval を使うのは bash 4.0 互換のため。入力 n は _parallel_validate_slots 通過済の
  # 正整数のみで、外部入力は流入しない（NFR 2.3 のシェル展開リスクなし）。
  # shellcheck disable=SC1083
  if ! eval "exec ${fd}>\"\$lock_file\"" 2>/dev/null; then
    return 1
  fi
  if ! flock -n "$fd" 2>/dev/null; then
    # 既に他プロセスがロック中。fd を閉じて return 1
    eval "exec ${fd}>&-" 2>/dev/null || true
    return 1
  fi
  return 0
}

# 指定 slot の per-slot lock を解放する。
# 引数: $1 = slot 番号
# 戻り値: 常に 0
# サブシェル終了で fd は自動解放されるため通常は呼ぶ必要なし。Dispatcher 側で
# claim 失敗時のロールバックに使う（Req 2.3: ラベル付与失敗で slot lock 解放）。
_slot_release() {
  local n="$1"
  local fd=$((210 + n))
  # shellcheck disable=SC1083
  eval "exec ${fd}>&-" 2>/dev/null || true
  return 0
}

# ─── Phase C: Hook Layer ───
#
# SLOT_INIT_HOOK 起動を担う薄い wrapper。
#
# 安全性（NFR 2.3 / Req 5.5）:
#   - SLOT_INIT_HOOK の値はシェル展開させない（eval / `bash -c` 不使用）
#   - 絶対パスをそのまま起動するのみ。引数文字列の空白分割を許容しない
#   - "/path/to/script.sh --flag" のような引数渡しはサポート外（README に明記、
#     ユーザーは wrapper script を書く）

# SLOT_INIT_HOOK を起動する。未設定なら no-op。
# 引数: $1 = slot 番号, $2 = worktree 絶対パス
# 戻り値: 0 = 起動成功 / 1 = 起動失敗（path 不在 / 非実行可能 / 非ゼロ exit）
# 副作用: hook 子プロセスの stdout / stderr は呼び出し元の標準出力 / エラー出力に流れる
#
# Req 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, NFR 2.3
_hook_invoke() {
  local n="$1"
  local wt="$2"
  if [ -z "${SLOT_INIT_HOOK:-}" ]; then
    return 0
  fi
  if [ ! -x "$SLOT_INIT_HOOK" ]; then
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が存在しないか実行可能ではありません: $SLOT_INIT_HOOK" >&2
    return 1
  fi

  # stderr を一時ファイルに捕捉して非ゼロ exit 時にログ転記する（Req 5.7）
  local stderr_tmp
  stderr_tmp="$(mktemp -t slot-init-hook-XXXXXX.err 2>/dev/null || echo "")"
  local rc=0

  # IDD_SLOT_NUMBER / IDD_SLOT_WORKTREE / PARALLEL_SLOTS / REPO / REPO_DIR を export
  # して子プロセスに引き継ぐ。直接 exec のみ（Req 5.5: shell 展開なし）。
  if [ -n "$stderr_tmp" ]; then
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" 2> >(tee -a "$stderr_tmp" >&2) || rc=$?
  else
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" || rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    local tail_text=""
    if [ -n "$stderr_tmp" ] && [ -f "$stderr_tmp" ]; then
      tail_text="$(tail -c 2000 "$stderr_tmp" 2>/dev/null || true)"
    fi
    echo "[$(date '+%F %T')] slot-${n}: ERROR: SLOT_INIT_HOOK が exit code ${rc} で失敗しました: $SLOT_INIT_HOOK" >&2
    if [ -n "$tail_text" ]; then
      echo "[$(date '+%F %T')] slot-${n}: hook stderr (tail):" >&2
      echo "$tail_text" >&2
    fi
  fi

  if [ -n "$stderr_tmp" ]; then
    rm -f "$stderr_tmp" 2>/dev/null || true
  fi

  if [ "$rc" -ne 0 ]; then
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

# 引数 $1 = 依存 Issue 番号（数字のみ）。
# stdout = 区分文字列 1 行: "resolved" | "open" | "closed unmerged" | "api error"。
# return = 常に 0（判定結果は stdout で返す）。
# 副作用 = API エラー / jq parse 失敗時のみ dr_warn でログ（Req 6.2）。
#
# `gh issue view <N> --repo "$REPO" --json state,closedByPullRequestsReferences` を
# 実行し、`jq` で以下を判定:
#   - state == "OPEN"  → "open"（unresolved / Req 2.3）
#   - state == "CLOSED" かつ closedByPullRequestsReferences[].merged のいずれかが
#     true → "resolved"（Req 2.2）
#   - state == "CLOSED" かつ上記が全て false / 空配列 → "closed unmerged"（Req 2.4）
#   - gh / jq 失敗 / 未知の state → "api error"（Req 2.5 / NFR 4.2 安全側）
#
# timeout は呼び出し元のサイクル全体タイムアウトに従う（個別 timeout は導入しない:
# 通常は数秒で帰る + watcher 全体 timeout で吸収）。
dr_resolve_one() {
  local dep_num="$1"
  local json
  if ! json=$(gh issue view "$dep_num" --repo "$REPO" \
        --json state,closedByPullRequestsReferences 2>&1); then
    dr_warn "issue=#${dep_num} gh issue view 失敗: ${json}"
    echo "api error"
    return 0
  fi

  local state
  if ! state=$(printf '%s' "$json" | jq -r '.state' 2>/dev/null); then
    dr_warn "issue=#${dep_num} jq parse 失敗（state 取り出し）"
    echo "api error"
    return 0
  fi

  case "$state" in
    OPEN)
      echo "open"
      return 0
      ;;
    CLOSED)
      # closedByPullRequestsReferences[].merged が true のものを 1 件以上検出すれば
      # resolved。空配列 or 全 false は closed unmerged（Req 2.2, 2.4）。
      local merged_count
      if ! merged_count=$(printf '%s' "$json" \
            | jq '[.closedByPullRequestsReferences[]? | select(.merged == true)] | length' \
            2>/dev/null); then
        dr_warn "issue=#${dep_num} jq parse 失敗（closedByPullRequestsReferences 集計）"
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
  local issues
  issues=$(gh issue list \
    --repo "$REPO" \
    --label "$LABEL_TRIGGER" \
    --state open \
    --search "-label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\" -label:\"$LABEL_CLAIMED\" -label:\"$LABEL_PICKED\" -label:\"$LABEL_READY\" -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_ITERATION\" -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"$LABEL_BLOCKED\"" \
    --json number,title,body,url,labels \
    --limit 5)

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

