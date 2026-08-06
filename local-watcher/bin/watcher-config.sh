#!/usr/bin/env bash
# =============================================================================
# idd-claude watcher config（環境に合わせて書き換える設定ブロック）
#
# 用途  : issue-watcher.sh 本体から分離した Config ブロック（#460）。
#         REPO / REPO_DIR / ラベル名 / *_ENABLED フラグ群 / per-repo env ファイル
#         ロード（#386）/ 各種プロンプト・モデル・タイムアウト定義とその正規化を担う。
#         「config を書き換える運用」（TRIAGE_MODEL / DEV_MODEL / BASE_BRANCH 等）の
#         編集対象は本ファイル。
# 配置先: ~/bin/watcher-config.sh（issue-watcher.sh と同階層。install.sh の
#         `local-watcher/bin/*.sh` glob 配布で issue-watcher.sh と同経路で配置される）
# 依存  : issue-watcher.sh から `.`（source）される前提で、単体実行はしない。
#         `set -euo pipefail` は本体側で宣言済みで、本ファイルは source 後にその効力下で
#         走る。内部で modules/env-loader.sh を BASH_SOURCE 基準に単独 source する（#386）。
#
# なぜ modules/ ではなく本体同階層か:
#   modules/*.sh は「関数定義のみ・トップレベル副作用なし」を規約とする（loader が
#   main loop 前に全 source する前提）。本ファイルは source 時に代入・正規化・export・
#   前提値評価という **トップレベルの副作用** を実行するため modules/ 規約に適合せず、
#   本体と同じディレクトリに置いて本体から明示 source する。BASH_SOURCE 基準で
#   modules/env-loader.sh を解決する都合上も、本体と同階層である必要がある。
#
# 本体残置分（#460）:
#   Config ブロック近傍に #348/#375/#385 で「前出し」された純粋 helper 3 関数
#   （full_auto_enabled / extract_review_result_token / parse_review_result）は、
#   load-order 近接テストが「定義行 < caller 行」を issue-watcher.sh 単一ファイル内で
#   検証する制約上、本ファイルへ移さず issue-watcher.sh 本体に残置している。
#   一方 reviewer_normalize_extended_max_turns は config 行（REVIEWER_MAX_TURNS_EXTENDED）
#   から source 時に呼ばれるため本ファイルへ移動した（reviewer_is_error_max_turns も同伴）。
#
# 静的解析ノート:
#   本ファイルは config 変数（LABEL_* / *_ENABLED / *_MODEL / *_PROMPT 等）を多数定義するが、
#   その消費側は source 元の issue-watcher.sh 本体および modules/*.sh 側にある。shellcheck が
#   watcher-config.sh 単体を解析する際は cross-file の使用が見えず、全 config 変数に SC2034
#   （unused variable）を誤検知する（分割前は同一ファイル内に使用が見えていたため非発火だった）。
#   ファイル分割に伴う可視性の副作用で、変数自体は本体側で使用済み。file-level で抑止する
#   （#459 stage-checkpoint.sh がヘッダで SC2153 を抑止したのと同種の対処）。
# shellcheck disable=SC2034
# =============================================================================

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

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# per-repo env ファイル ロード（Issue #386 / F8）
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# crontab 行長限界（~1024 文字）で `command too long` を回避するため、watcher 起動時に
# per-repo env ファイル（`WATCHER_ENV_FILE` 明示パス または `$HOME/.issue-watcher/<REPO_SLUG>.env`）
# を source して `*_ENABLED` 系フラグを供給する。inline cron env が env ファイル値より優先される
# 単一順序 precedence（Req 4.1〜4.4）を保証するため、ロード時点は本体内の **すべての**
# `*_ENABLED` 系 `${VAR:-default}` 評価より前 = REPO_SLUG 算出直後の本位置に置く。
# 候補ファイル不在時は何もせず（Req 5.1 / NFR 1.1）、本機能導入前と完全に byte 等価な
# 起動経路を辿る。
#
# 配置順序の制約上、`REQUIRED_MODULES` ローダ（line 1052 付近）より前の本位置で
# `env-loader.sh` のみ単独 source する必要がある（env ファイル経由で供給される値は
# 後続の Config 行の `${VAR:-default}` で参照されるため、Config 行より前に確定させる
# 必要がある）。本 module は他 module に依存しない自己完結関数群（el_log / el_warn /
# el_resolve_env_file / el_apply_env_file / el_load）のみを定義するため、単独 source
# しても他 module の前方参照を踏まない。
IDD_ENV_LOADER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/modules/env-loader.sh"
if [ -f "$IDD_ENV_LOADER_PATH" ]; then
  # shellcheck source=/dev/null
  . "$IDD_ENV_LOADER_PATH"
  el_load
fi
unset IDD_ENV_LOADER_PATH

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
# Issue #346: 依存全解決時の `blocked` 自動解除スイープ opt-in gate。
# `=true` 厳密一致のときのみ `dr_unblock_sweep` を `_dispatcher_run` 冒頭で起動し、
# (1) 全依存 resolved の Issue から `blocked` ラベルを除去 + 自動解除コメント投稿、
# (2) 依存マーカーが本文から消失した Issue には通知コメントを 1 回だけ投稿（ラベル維持）、
# (3) 1 件でも依存未解決なら何もしない、を 1 tick で実施する（Req 1.1, 3.1, 5.2, 6.1）。
# 未設定 / 空 / `false` / `True` / `1` / typo 等は OFF に正規化し、本機能導入前と完全に
# 等価な挙動を保つ（Req 1.2, 1.3, NFR 1.1）。gate ON 時のみ `dr_apply_block` の新規
# エスカレーションコメント文面が「依存解消後に自動で外れます」相当に分岐する（Req 8.1, 8.2）。
DEP_AUTO_UNBLOCK_ENABLED="${DEP_AUTO_UNBLOCK_ENABLED:-false}"
# Issue #348: full-auto 系 processor の単一 kill switch。
# `=true` 厳密一致のときのみ ON。それ以外（未設定 / 空 / `false` / `0` / `True` /
# `TRUE` / `1` / typo 等）はすべて OFF に正規化し、本機能導入前と完全に等価な挙動を
# 保つ（Req 1.1〜1.3, NFR 1.1）。本フラグは個別 gate と **AND** 関係で動作し、
# `FULL_AUTO_ENABLED=true` かつ個別 gate=true の場合のみ full-auto 系 processor が
# 発火する（二重 opt-in / Req 2.1〜2.7）。
#
# 本フラグの配下に置く processor は「実装済みの full-auto 系」のみとする。本 Issue 時点で
# 実装済みのものは Dependency Auto-Unblock Sweep (`dr_unblock_sweep`, #346) の 1 件のみ。
# 要件で言及された auto-merge / failed-recovery / needs-decisions auto / semantic conflict
# は本 Issue 時点では未実装のため配線対象外（将来追加時に同じ kill switch を参照する設計）。
#
# 本フラグは Out of Scope に明記された既存 opt-in 機能（merge-queue / auto-rebase /
# promote-pipeline / pr-iteration / pr-reviewer / security-review / design-review-release /
# stage-checkpoint / stage-a-verify / quota-aware / debugger / hooks / dep-auto-unblock の
# 個別 gate 自体）の解釈は変更しない（Req 3.3 / 3.4）。
FULL_AUTO_ENABLED="${FULL_AUTO_ENABLED:-false}"
# 値正規化: `true` 厳密一致のみ通し、それ以外（未設定 / 空 / `false` / `0` / `True` /
# `TRUE` / `1` / typo 等）はすべて `false` に固定する（Req 1.2, 1.3）。
# 正規化は full-auto 系 processor の入口評価より **前** に完了させる（Req 1.4）。
# 既存「デフォルト有効化フラグの値正規化」ループには加えない（既定 OFF の opt-in 制のため、
# `=true` 厳密一致で有効化する仕様。`=false` 既定の opt-out 系 8 種とは別扱い）。
case "$FULL_AUTO_ENABLED" in
  true) : ;;
  *)    FULL_AUTO_ENABLED="false" ;;
esac

# Issue #362: needs-decisions 自動続行のモード切替。`safe` 分類かつ `FULL_AUTO_ENABLED=true`
# のときのみ PM 第一推奨で自動続行する。値は 3 値（`all-human` / `classified` / `all-auto`）
# のいずれかに正規化し、未設定 / 空 / 不正値・typo はすべて安全側 `all-human` に倒す
# （Req 1.1〜1.6, NFR 1.1）。正規化は needs-decisions 判定の入口評価より **前** に完了させる
# （Req 1.6）。kill switch `FULL_AUTO_ENABLED` との AND 二重 opt-in で発火し、既定値
# `all-human` では本機能導入前と完全に等価な挙動を保つ（Req 5.1, 5.3, NFR 1.1）。
NEEDS_DECISIONS_MODE="${NEEDS_DECISIONS_MODE:-all-human}"
case "$NEEDS_DECISIONS_MODE" in
  all-human|classified|all-auto) : ;;
  *)                              NEEDS_DECISIONS_MODE="all-human" ;;
esac
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
AUTO_REBASE_MODEL="${AUTO_REBASE_MODEL:-claude-opus-4-8}"
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
# 加算的衝突緩和の opt-in gate (#438)。bootstrap path（`cmd/api/main.go` の DI 配線 /
# Mount スロット等）に閉じた「両 side 追加のみ・削除/変更なし」の衝突を、`MECHANICAL_PATHS`
# allowlist 照合で semantic に落ちる手前で二次判定し mechanical へ昇格させる。`claude` で
# 有効化、それ以外（未設定 / 空 / `on` / `true` / `CLAUDE` / typo 等）はすべて `off` に
# 正規化する（既定 OFF の opt-in / Req 1.1, 1.3, NFR 1.1）。
AUTO_REBASE_ADDITIVE="${AUTO_REBASE_ADDITIVE:-off}"
case "$AUTO_REBASE_ADDITIVE" in
  claude) : ;;
  *)      AUTO_REBASE_ADDITIVE="off" ;;
esac
# 加算的判定を許す bootstrap path allowlist。カンマ区切り bash glob（`MECHANICAL_PATHS` と
# 同構文）。空 / 未設定なら二次判定を一切起動せず従来判定へフォールバックする（Req 1.4）。
# `MECHANICAL_PATHS`（中身不問の無条件 mechanical）とは意味が異なる（こちらは「追加のみ」
# という条件付き）ため専用 env として分離する。
AUTO_REBASE_ADDITIVE_PATHS="${AUTO_REBASE_ADDITIVE_PATHS:-}"

# ─── Phase D-12: Claude Semantic Resolution 設定 (#366) ───
# Phase D の semantic 経路（変更ファイルが `MECHANICAL_PATHS` allowlist 外を含む rebase）に
# 限り、Claude による conflict 解消を opt-in で追加し、Claude が生成した解決 commit を
# PR head に積んだうえで既存の `codex-review` / `claude-review`（pr-reviewer.sh / #261 /
# #349）を **再発火** させて二重ゲートを通った場合のみ auto-merge が可能となるよう拡張する。
# Claude の解決結果は **無検証で merge することは絶対に行わない**：Claude 解決後も approve
# は dismissal され続け、PR Reviewer の再レビューと人間 / 自動 approve 復帰を経て初めて
# auto-merge に到達する（Req 4.x / 5.x の二重ゲート）。
#
# **AND 二重 opt-in**: `AUTO_REBASE_SEMANTIC=claude` AND `FULL_AUTO_ENABLED=true`
# （#348 kill switch）が双方 ON のときのみ動作する。いずれかが OFF（既定）なら本機能
# 導入前と完全に等価で旧 semantic 経路（approve dismiss → 人間レビュー待ち）にフォールバック
# する（Req 1.4, 2.2, 2.3, 2.4 / NFR 1.1）。`AUTO_REBASE_SEMANTIC` は `claude` / `off` の
# 2 値厳密一致のみ受理し、それ以外（未設定 / 空 / `Claude` / `on` / `true` / typo）は
# すべて `off` に正規化（Req 1.3, 1.4）。
#
# 本フラグは新規追加 = opt-in 制 + 既定 off が要件のため、上記「デフォルト有効化フラグの
# 値正規化」ループには **含めない**。
AUTO_REBASE_SEMANTIC="${AUTO_REBASE_SEMANTIC:-off}"
case "$AUTO_REBASE_SEMANTIC" in
  claude) : ;;
  *)      AUTO_REBASE_SEMANTIC="off" ;;
esac
# 同一 PR に対する Claude semantic 解決試行の通算上限（Req 7.1）。
# failed-recovery の 4 回より厳しめに 3 回。未設定 / 非整数 / 0 以下は既定 3 に正規化。
AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS="${AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS:-3}"
case "$AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS" in
  ''|*[!0-9]*) AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS=3 ;;
  *)
    if [ "$AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS" -le 0 ]; then
      AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS=3
    fi
    ;;
esac
# 状態ファイル（通算 attempt + 直前試行 head SHA の JSON）の配置先。既定
# `$HOME/.issue-watcher/auto-rebase-semantic/$REPO_SLUG`（LOG_DIR / FAILED_RECOVERY_STATE_DIR
# と同じ repo-slug 分離方針 / NFR 4.1 / CLAUDE.md「機能追加ガイドライン §6」）。
AUTO_REBASE_SEMANTIC_STATE_DIR="${AUTO_REBASE_SEMANTIC_STATE_DIR:-$HOME/.issue-watcher/auto-rebase-semantic/$REPO_SLUG}"

# ─── Auto-Merge Processor 設定 (#352) ───
# 実装 PR（head が `^claude/issue-.*-impl` パターン、`ready-for-review` ラベル、draft でない、
# `mergeable=MERGEABLE`）に対して **GitHub ネイティブの auto-merge** を `gh pr merge --auto
# --squash --delete-branch` で有効化する opt-in 機能。必須 status checks（CI +
# `codex-review` + `claude-review`）が全 green に到達したら GitHub 側が squash merge + branch
# 削除を実行する。watcher 自体は直接 branch を merge しない（Req 3.2）。
#
# AND 二重 opt-in: `AUTO_MERGE_ENABLED=true` AND `FULL_AUTO_ENABLED=true`（#348 kill switch）
# が双方 ON のときのみ動作する。いずれかが OFF（既定）なら gh API 呼び出しゼロで本機能
# 導入前と完全に等価（Req 1.5, NFR 1.1）。`=true` 厳密一致以外（未設定 / 空 / `false` /
# `0` / `True` / `TRUE` / `1` / `on` / `yes` / typo 等）はすべて OFF に正規化（Req 1.3）。
AUTO_MERGE_ENABLED="${AUTO_MERGE_ENABLED:-false}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し / NFR 3.1）。
AUTO_MERGE_MAX_PRS="${AUTO_MERGE_MAX_PRS:-10}"
# gh / git 操作の個別タイムアウト（秒）。既存 MERGE_QUEUE_GIT_TIMEOUT と同既定。
AUTO_MERGE_GIT_TIMEOUT="${AUTO_MERGE_GIT_TIMEOUT:-60}"
# head branch pattern: 実装 PR のみを対象にする（人間が手書きした PR / 設計 PR を除外 /
# Req 2.1, 6.3）。idd-claude の実装 PR は `claude/issue-<N>-impl-<slug>` 形式。
AUTO_MERGE_HEAD_PATTERN="${AUTO_MERGE_HEAD_PATTERN:-^claude/issue-.*-impl}"

# ─── Design Auto-Merge Processor 設定 (#354) ───
# 設計 PR（head が `^claude/issue-.*-design` パターン、`ready-for-review` ラベル、draft でない、
# `mergeable=MERGEABLE`）に対して **GitHub ネイティブの auto-merge** を `gh pr merge --auto
# --squash --delete-branch` で有効化する opt-in 機能。必須 status checks（CI +
# `codex-review` + `claude-review`）が全 green に到達したら GitHub 側が squash merge + branch
# 削除を実行する。watcher 自体は直接 branch を merge しない。実装 PR は #352
# (Auto-Merge Processor) が担当し、本機能とは head pattern で分離（Req 2.6, 6.7）。
#
# AND 二重 opt-in: `AUTO_MERGE_DESIGN_ENABLED=true` AND `FULL_AUTO_ENABLED=true`（#348 kill
# switch）が双方 ON のときのみ動作する。いずれかが OFF（既定）なら gh API 呼び出しゼロで
# 本機能導入前と完全に等価（NFR 1.1）。`=true` 厳密一致以外（未設定 / 空 / `false` / `0` /
# `True` / `TRUE` / `1` / `on` / `yes` / typo 等）はすべて OFF に正規化（Req 1.3）。
# auto-merge 完了後の `awaiting-design-review` ラベル除去は Design Review Release Processor
# (#40, `DESIGN_REVIEW_RELEASE_ENABLED`) が引き続き担当し、本機能とは独立共存する（NFR 4.3）。
AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"
# 1 サイクルで処理する PR 数の上限（残りは次回サイクルに持ち越し）。
AUTO_MERGE_DESIGN_MAX_PRS="${AUTO_MERGE_DESIGN_MAX_PRS:-10}"
# gh / git 操作の個別タイムアウト（秒）。既存 AUTO_MERGE_GIT_TIMEOUT と同既定。
AUTO_MERGE_DESIGN_GIT_TIMEOUT="${AUTO_MERGE_DESIGN_GIT_TIMEOUT:-60}"
# head branch pattern: 設計 PR のみを対象にする（実装 PR / 手書き PR を除外 / Req 2.6, 6.7）。
# idd-claude の設計 PR は `claude/issue-<N>-design-<slug>` 形式。
AUTO_MERGE_DESIGN_HEAD_PATTERN="${AUTO_MERGE_DESIGN_HEAD_PATTERN:-^claude/issue-.*-design}"

# ─── Auto-Merge Disarm Processor 設定 (#434) ───
# arm 済み（`autoMergeRequest != null`）の open PR が `claude-failed` / `needs-decisions` といった
# terminal ラベルへ遷移した時点で、`gh pr merge --disable-auto` で native auto-merge を取り消す
# 機能。arm 時点判定（am_should_enable_for_pr）は arm 後の遷移を追えないため、毎サイクル GitHub を
# 直接クエリして「arm 済み かつ terminal ラベル付き かつ open」な PR を disarm する（Req 1.x）。
#
# opt-in gate: `FULL_AUTO_ENABLED=true` AND (`AUTO_MERGE_ENABLED=true` OR
# `AUTO_MERGE_DESIGN_ENABLED=true`)。arm が起きるのは AUTO_MERGE_ENABLED / AUTO_MERGE_DESIGN_ENABLED
# のいずれかが ON のときだけなので、disarm gate を arm 源に相乗りさせることで、arm が起きない環境
# では disarm も完全 no-op になり、新規 env gate を増やさずに後方互換を満たす（NFR 1.1, 1.2）。
# どちらの arm 源も無効なら gh API 呼び出しゼロで本不具合修正導入前と等価。
#
# 1 サイクルで disarm する PR 数の上限（残りは次回サイクルに持ち越し / NFR 3.x）。`=数値` 以外は
# 既定 10 に正規化。timeout は既存 AUTO_MERGE_GIT_TIMEOUT を流用（新規 env を増やさない）。
AUTO_MERGE_DISARM_MAX_PRS="${AUTO_MERGE_DISARM_MAX_PRS:-10}"

# ─── PR Iteration Processor 設定 (#26) ───
# `needs-iteration` ラベル付き PR をレビューコメントに基づいて自動で iterate する。
# 標準機能としてデフォルト有効化（#112）。無効化したい場合は cron / launchd 側で
# PR_ITERATION_ENABLED=false を渡す。
PR_ITERATION_ENABLED="${PR_ITERATION_ENABLED:-true}"
# Iteration 専用モデル ID（既存 DEV_MODEL とは独立して上書き可能）。
PR_ITERATION_DEV_MODEL="${PR_ITERATION_DEV_MODEL:-claude-opus-4-8}"
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

# ─── PR Reviewer Processor 設定 (#261) ───
# 外部 AI レビューツール（codex / antigravity (バイナリ名 agy)）に open PR を
# 自動レビューさせ、結果を PR コメントとして残し、修正要求の VERDICT を検出したら
# needs-iteration ラベルを付与して既存 PR Iteration Processor (#26) へ接続する。
# **完全な opt-in**（NFR 1.1）。PR_REVIEWER_ENABLED=true 厳密一致以外は env を読みもせず
# process_pr_reviewer が早期 return するため、未設定環境では本機能導入前と挙動が等価。
# 関数本体は modules/pr-reviewer.sh、ロガー pr_log / pr_warn / pr_error は core_utils.sh。
PR_REVIEWER_ENABLED="${PR_REVIEWER_ENABLED:-false}"
# 使用ツール選択（canonical 単一値）。codex / antigravity のいずれか。空なら下の
# *_ENABLED alias で解決する（Decision 1 の解決順序）。
PR_REVIEWER_TOOL="${PR_REVIEWER_TOOL:-}"
# 代替指定（alias）。=true 厳密一致のみ有効。両方 true は排他エラー（AC 2.3）。
PR_REVIEWER_CODEX_ENABLED="${PR_REVIEWER_CODEX_ENABLED:-false}"
PR_REVIEWER_ANTIGRAVITY_ENABLED="${PR_REVIEWER_ANTIGRAVITY_ENABLED:-false}"
# 実行コマンドテンプレート。プレースホルダ {BASE}/{HEAD}/{PR}/{PROMPT_FILE} を置換後に
# bash -c で実行（eval 不使用、Decision 9）。codex には review サブコマンドが存在しない
# ため `codex exec` を使用し `--sandbox read-only` を焼き込む（Decision 2 / 8）。
# 既定値中の \$(cat '...') はリテラル保持し、実行時に inner bash -c が prompt を展開する。
PR_REVIEWER_CODEX_CMD="${PR_REVIEWER_CODEX_CMD:-codex exec --sandbox read-only \"\$(cat '{PROMPT_FILE}')\"}"
# antigravity の実バイナリは agy。-p（=--print）で非対話、--output-format json で
# 最終 message を JSON 出力（pr_run_review_for_pr が jq で抽出、Decision 3）。
PR_REVIEWER_ANTIGRAVITY_CMD="${PR_REVIEWER_ANTIGRAVITY_CMD:-agy -p \"\$(cat '{PROMPT_FILE}')\" --output-format json}"
# レビュー指示プロンプト本体（tool 共通）。空なら modules/pr-reviewer.sh の内蔵 default を
# 使用（{BASE}/{HEAD}/{PR} を置換）。
PR_REVIEWER_PROMPT="${PR_REVIEWER_PROMPT:-}"
# 認証チェックコマンド（終了コード 0 で認証 OK、空文字なら check skip）。codex は
# `codex login status`（`codex auth status` は存在しない）。agy は auth status 相当が
# 存在しないため既定 skip（Decision 3）。
PR_REVIEWER_CODEX_AUTH_CMD="${PR_REVIEWER_CODEX_AUTH_CMD:-codex login status}"
PR_REVIEWER_ANTIGRAVITY_AUTH_CMD="${PR_REVIEWER_ANTIGRAVITY_AUTH_CMD:-}"
# needs-iteration 付与トリガ。内蔵 prompt が最終行に出力する構造化 VERDICT token を
# line-anchored で検出する ERE（grep -E -i）。自由文 grep を希望する場合は override 可
# （Decision 4）。
PR_REVIEWER_ITERATION_PATTERN="${PR_REVIEWER_ITERATION_PATTERN:-^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$}"
# 対象 head ブランチ pattern（jq の test() 互換 POSIX ERE）。既定は MERGE_QUEUE の慣習に倣う。
PR_REVIEWER_HEAD_PATTERN="${PR_REVIEWER_HEAD_PATTERN:-^claude/}"
# 1 サイクルあたりの処理上限（残りは次回サイクルへ持ち越し）。
PR_REVIEWER_MAX_PRS="${PR_REVIEWER_MAX_PRS:-5}"
# git / gh 各操作の個別タイムアウト（秒）。レビュー実行自体は下の EXEC_TIMEOUT が支配。
PR_REVIEWER_GIT_TIMEOUT="${PR_REVIEWER_GIT_TIMEOUT:-120}"
# レビュー実行コマンドの最大経過秒数。
PR_REVIEWER_EXEC_TIMEOUT="${PR_REVIEWER_EXEC_TIMEOUT:-600}"

# ─── PR Reviewer exec-failed リトライ抑止 / 診断性向上設定 (#403) ───
# 同一 head sha での連続 `kind=exec-failed`（codex / antigravity の非ゼロ終了 / 空出力 /
# workspace-modified 含む実行失敗扱い）を hidden marker で永続カウントし、上限到達 PR を
# 候補から除外することで rate-limit 持続事故を防ぐ（Issue #403）。
# 既定 ON だが、運用上は `PR_REVIEWER_ENABLED=true` の opt-in 経路の中で動作するため、
# 本機能による外部副作用は本機能導入前と同等の安全側拡張に留まる（Req 4.x / NFR 1.1）。
#
# 上限既定値 3（pr-iteration の no-progress-streak 既定と整合 / NFR 2.1）。1 以上の整数のみ
# 受理し、不正値（非数値 / 0 以下 / 空）は既定 3 に正規化する（NFR 1.2 安全側）。
PR_REVIEWER_EXEC_FAIL_LIMIT="${PR_REVIEWER_EXEC_FAIL_LIMIT:-3}"
case "$PR_REVIEWER_EXEC_FAIL_LIMIT" in
  ''|*[!0-9]*) PR_REVIEWER_EXEC_FAIL_LIMIT="3" ;;
  *)
    if [ "$PR_REVIEWER_EXEC_FAIL_LIMIT" -lt 1 ] 2>/dev/null; then
      PR_REVIEWER_EXEC_FAIL_LIMIT="3"
    fi
    ;;
esac
# stderr 抜粋サイズ（コメント本文に埋める末尾優先抜粋のバイト数）。既定 8KB（旧 1KB から拡張）。
# 不正値（非数値 / 0 以下 / 空）は既定 8192 に正規化（NFR 1.2 / Req 3.1）。
PR_REVIEWER_STDERR_EXCERPT_BYTES="${PR_REVIEWER_STDERR_EXCERPT_BYTES:-8192}"
case "$PR_REVIEWER_STDERR_EXCERPT_BYTES" in
  ''|*[!0-9]*) PR_REVIEWER_STDERR_EXCERPT_BYTES="8192" ;;
  *)
    if [ "$PR_REVIEWER_STDERR_EXCERPT_BYTES" -lt 1 ] 2>/dev/null; then
      PR_REVIEWER_STDERR_EXCERPT_BYTES="8192"
    fi
    ;;
esac
# stderr artifact 保存先ディレクトリ。`$HOME/.issue-watcher/` 配下（CLAUDE.md 機能追加
# ガイドライン 6 / Req 3.5）。空文字に正規化された場合は artifact 保存を skip する fail-safe。
PR_REVIEWER_STDERR_ARTIFACT_DIR="${PR_REVIEWER_STDERR_ARTIFACT_DIR:-$HOME/.issue-watcher/pr-reviewer-artifacts}"
# stderr artifact 保存上限（1MB 既定）。これを超える stderr は末尾を優先して保存し、
# truncation 発生の旨を観測ログに記録する（Req 3.4）。
PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="${PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES:-1048576}"
case "$PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES" in
  ''|*[!0-9]*) PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="1048576" ;;
  *)
    if [ "$PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES" -lt 1 ] 2>/dev/null; then
      PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES="1048576"
    fi
    ;;
esac

# ─── PR Reviewer Commit Status Publishing 設定 (#349) ───
# codex / antigravity Reviewer の VERDICT および Claude Reviewer の RESULT を、
# GitHub Commit Status API (`POST /repos/{owner}/{repo}/statuses/{sha}`) 経由で
# 安定 context 名（`codex-review` / `claude-review`）の commit status として publish し、
# branch protection の required status checks による auto-merge ゲートを成立させるための
# opt-in 機能（Issue #349 / NFR 1.1）。
#
# **AND 二重 opt-in**: 本 gate は `FULL_AUTO_ENABLED=true`（#348 kill switch）と AND
# で評価される。`PR_REVIEWER_STATUS_CHECK_ENABLED=true` かつ `FULL_AUTO_ENABLED=true`
# の双方が成立した場合のみ commit status を publish する（Req 1.2, 1.4）。
#
# 既定 `false`。`=true` 厳密一致以外（未設定 / 空 / `True` / `TRUE` / `1` / typo 等）は
# すべて `false` に正規化し、本機能導入前と完全に等価な挙動を保つ（Req 1.1, 1.3 / NFR 1.1）。
# gate OFF 時はコメント投稿等の既存 PR Reviewer / Claude Reviewer 挙動には影響を与えない
# （Req 6.1, 6.2, 6.3）。
PR_REVIEWER_STATUS_CHECK_ENABLED="${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}"
# 値正規化: `true` 厳密一致のみ通し、それ以外はすべて `false` に固定する（Req 1.3）。
# 既定 OFF の opt-in 制のため、上記「デフォルト有効化フラグの値正規化」ループには加えない。
case "$PR_REVIEWER_STATUS_CHECK_ENABLED" in
  true) : ;;
  *)    PR_REVIEWER_STATUS_CHECK_ENABLED="false" ;;
esac

# ─── PR Reviewer Adjudicator 設定 (#404 / #412) ───
# codex Reviewer の指摘を Claude adjudicator が「legitimate（実害）」と「excessive
# （過剰指摘）」に分類し、(1) `needs-iteration` 反復を legitimate のみで駆動し、
# (2) merge ゲートを `codex-review`（advisory）から `claude-review`（必須相当）へシフトする
# 機能（Issue #404）。codex の過剰指摘 / nitpick / exec-failed が merge を永久 block
# する事象（ae-mdm / altpocket-server #139 で観測）を解消する。
#
# **既定 ON / opt-out（#412 で既定反転）**: `PR_REVIEWER_ADJUDICATOR_ENABLED=false` を
# 明示した場合のみ無効化し、それ以外（未設定 / 空 / `True` / `TRUE` / `1` / `0` / typo 等）は
# すべて安全側＝有効として `true` に正規化する（#412 Req 1.1〜1.5 / 5.1）。値の最終正規化は
# 後段の「デフォルト有効化フラグの値正規化」ループでも適用される（#412 で本フラグを追加）。
# `=false` を既存 cron / launchd で明示している環境は、本変更導入前の opt-in 既定 OFF と
# 完全に等価な挙動を維持する（#412 Req 5.1 / NFR 1.1）。
#
# 後方互換性（#412 Req 5.3 / 5.4 / 5.5 / 5.6 / NFR 1.3）:
#   - `PR_REVIEWER_ADJUDICATOR_ENABLED` 以外の `PR_REVIEWER_ADJUDICATOR_*` env / ラベル名 /
#     commit status 名 / exit code / log prefix は不変。
#   - 既定反転は本 1 フラグのみ（fallback 既定や他 5 env の挙動・正規化規則は変更しない）。
#
# **fallback 既定 `passthrough` の根拠**（Architecture Decision: claude-review publisher
# contention 参照 / SPOF 緩和。#412 既定 ON 化後も維持）: adjudicator 自身が claude exec
# 失敗 / rate-limit / timeout 等で publish できなかった場合、`passthrough` は adjudicator
# 自体を実行しなかったかのように扱い、既存独立 Reviewer サブエージェント（catch-up 経路）の
# verdict を尊重する。これにより「codex の SPOF を Claude の SPOF に付け替えただけ」の事態を
# 避け、impl PR では Reviewer の verdict が SPOF 影響を受けずに維持される。default ON 化に
# よって adjudicator は全 consumer repo で常時起動するが、`passthrough` 既定は catch-up
# 経路へのフォールバックを残すことで claude-review publisher の SPOF を回避する（#412 Req 2.1,
# 2.4, 2.5）。`legitimate` は claude 失敗を即 block 扱いしたい運用向け明示 opt-in 値
# （adjudicator 失敗時に全件 legitimate に倒し needs-iteration 維持 + `claude-review = failure`
# を publish する）。
#
# 関数本体は modules/adjudicator.sh、ロガー adj_log / adj_warn / adj_error は
# core_utils.sh 配置済み。REQUIRED_MODULES には adjudicator.sh が登録済み。
PR_REVIEWER_ADJUDICATOR_ENABLED="${PR_REVIEWER_ADJUDICATOR_ENABLED:-true}"
# 値正規化: `false` 厳密一致のみ OFF とし、それ以外（未設定 / 空 / `True` / `TRUE` / `1` /
# typo 等）はすべて `true` に固定する（#412 Req 1.1〜1.5 安全側）。
# 最終正規化は後段の「デフォルト有効化フラグの値正規化」ループでも同様に適用される。
case "$PR_REVIEWER_ADJUDICATOR_ENABLED" in
  false) : ;;
  *)     PR_REVIEWER_ADJUDICATOR_ENABLED="true" ;;
esac
# adjudicator 呼び出しモデル（既存 TRIAGE_MODEL 命名規約踏襲）。空文字なら既定。
PR_REVIEWER_ADJUDICATOR_MODEL="${PR_REVIEWER_ADJUDICATOR_MODEL:-claude-sonnet-4-6}"
if [ -z "$PR_REVIEWER_ADJUDICATOR_MODEL" ]; then
  PR_REVIEWER_ADJUDICATOR_MODEL="claude-sonnet-4-6"
fi
# claude 実行 timeout 秒。既存 PR_REVIEWER_EXEC_FAIL_LIMIT と同じ case パターンで非数値 /
# 0 以下を既定 300 に正規化（Req 5.5 既存規約整合）。
PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT="${PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT:-300}"
case "$PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT" in
  ''|*[!0-9]*) PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT="300" ;;
  *)
    if [ "$PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT" -lt 1 ] 2>/dev/null; then
      PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT="300"
    fi
    ;;
esac
# プロンプトテンプレ override（空なら adjudicator.sh が内蔵 default = adjudicator-prompt.tmpl
# を解決。本 task では空文字を保持するのみ。template 本体は task 2 で追加）。
PR_REVIEWER_ADJUDICATOR_PROMPT="${PR_REVIEWER_ADJUDICATOR_PROMPT:-}"
# claude 失敗時 fallback verdict。既定 `passthrough`（adjudicator skip + catch-up へ委譲 /
# SPOF 緩和）。`legitimate` / `passthrough` 以外（未設定 / 空 / typo / 大文字違い等）は
# すべて `passthrough` に正規化する（Req 5.1 安全側 / Architecture Decision: claude-review
# publisher contention 参照）。
PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL="${PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL:-passthrough}"
case "$PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL" in
  legitimate|passthrough) : ;;
  *) PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL="passthrough" ;;
esac
# 1 PR あたり処理する指摘数上限（コスト抑制）。非数値 / 0 以下は既定 50 に正規化。
PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS="${PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS:-50}"
case "$PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS" in
  ''|*[!0-9]*) PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS="50" ;;
  *)
    if [ "$PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS" -lt 1 ] 2>/dev/null; then
      PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS="50"
    fi
    ;;
esac

# ─── PR Iteration out-of-scope（第 3 判定）設定 (#437) ───
# adjudicator が「正当だが当該 impl PR スコープ外（design.md / requirements.md / tasks.md の
# 確定事項変更を要し、impl PR は規約上それらを書き換えられない）」という第 3 の指摘類型を
# `out-of-scope` として独立分類し、round を消費させる legitimate 件数から除外して
# `needs-decisions` へ還流させ、Developer 構造化マーカー検出と内容ベースの早期打ち切りで
# max_rounds 到達前に停止する機能。ae-mdm PR #51 で観測された「head SHA が毎 round 変化して
# no-progress-streak がリセットされ続け、収束しないまま max_rounds を消尽して claude-failed に
# 倒れる」事象を解消する。
#
# **完全な opt-in（既定 OFF / #437 NFR 1.1, 1.2 / Req 1.x, 4.x, 5.x）**: `PR_ITERATION_OOS_ENABLED=true`
# 厳密一致以外（未設定 / 空 / `True` / `TRUE` / `1` / `0` / typo 等）はすべて安全側＝無効として
# `false` に正規化し、本機能導入前と完全に等価な挙動を保つ。gate OFF 時、adjudicator は
# `out-of-scope` を一切出さず受け取らず（既存 2 値 schema と `legitimate + excessive == total`
# 不変条件を完全保持）、pr-iteration の oos フィルタ / Developer marker 検出 / 内容ベース早期
# 打ち切りは発火せず（既存 SHA ベース streak のみ）、prompt template の out-of-scope 指示は
# 注入されない。既存 `PR_REVIEWER_ADJUDICATOR_ENABLED`（#412 で既定 ON）/ `PR_ITERATION_ENABLED`
# （#112 で既定 ON）には相乗りせず**新規 env を新設**して no-op 既定を保証する（相乗りは ON
# 既定のため no-op を保証できない）。本 gate は既存 gate を override しない（後方互換優先 /
# design.md「確認事項 1」）。
#
# 後方互換性（#437 NFR 1.3, 1.4）:
#   - 既存 env var 名 / ラベル名（`needs-decisions` 再利用 = 新ラベル新設なし）/ exit code /
#     cron 文字列 / ログ書式 / 既存 marker フォーマットの round / last-run / no-progress-streak
#     キーは不変。本機能は新 env / 新 marker キー（`oos-no-progress-streak` / `oos-fingerprint`）の
#     追加のみ。
#
# 関数本体は modules/adjudicator.sh（adj_ prefix）/ modules/pr-iteration.sh（pi_ prefix）。
PR_ITERATION_OOS_ENABLED="${PR_ITERATION_OOS_ENABLED:-false}"
# 値正規化: `true` 厳密一致のみ通し、それ以外はすべて `false` に固定する（NFR 1.2 安全側）。
# 既定 OFF の opt-in 制のため、上記「デフォルト有効化フラグの値正規化」ループには加えない。
case "$PR_ITERATION_OOS_ENABLED" in
  true) : ;;
  *)    PR_ITERATION_OOS_ENABLED="false" ;;
esac
# out-of-scope 還流ルート（#437 Req 3.1, 3.2）。許容値は `needs-decisions`（推奨既定）/
# `design-reflow` / `spawn-issue` の 3 値。本 spec では `design-reflow` / `spawn-issue` も
# 実処理は `needs-decisions` に丸める（env 値だけ予約 / design.md「確認事項 2」/ Non-Goal）。
# 未知値 / 空 / typo は安全側として `needs-decisions` に正規化する（NFR 1.2）。
PR_ITERATION_OOS_ROUTE="${PR_ITERATION_OOS_ROUTE:-needs-decisions}"
case "$PR_ITERATION_OOS_ROUTE" in
  needs-decisions|design-reflow|spawn-issue) : ;;
  *) PR_ITERATION_OOS_ROUTE="needs-decisions" ;;
esac
# 内容ベース早期打ち切りの上限 N（#437 Req 5.2）。out-of-scope は確定的に収束不能なため、
# 既存 SHA ベース no-progress 上限（既定 3）とは別軸で既定 2 と短く設定する。非数値 / 0 以下は
# 安全側として既定 2 に正規化する。gate OFF 時は本値を参照しない（早期打ち切り自体が no-op）。
PR_ITERATION_OOS_NO_PROGRESS_LIMIT="${PR_ITERATION_OOS_NO_PROGRESS_LIMIT:-2}"
case "$PR_ITERATION_OOS_NO_PROGRESS_LIMIT" in
  ''|*[!0-9]*) PR_ITERATION_OOS_NO_PROGRESS_LIMIT="2" ;;
  *)
    if [ "$PR_ITERATION_OOS_NO_PROGRESS_LIMIT" -lt 1 ] 2>/dev/null; then
      PR_ITERATION_OOS_NO_PROGRESS_LIMIT="2"
    fi
    ;;
esac

# ─── Design PR Reviewer 設定 (#407) ───
# 設計 PR (`claude/issue-<N>-design-<slug>`) に対する独立 Claude 設計レビュアを起動し、
# `claude-review` commit status を publish する Processor。impl PR 用 Reviewer / #404
# adjudicator とは別コンポーネント（Req 7.1〜7.4）。
#
# **opt-out / 既定 ON（#432 で既定反転 / Req 1.1〜1.5, 4.5 / NFR 1.1, 2.1）**: 既定値を `true`
# とし、`DESIGN_REVIEWER_ENABLED=false` 厳密一致のみ無効化する。それ以外（未設定 / 空文字 /
# `True` / `TRUE` / `1` / `0` / `on` / typo 等）はすべて安全側＝有効に正規化する。`=false` を
# 明示した既存 cron / launchd 環境は本変更前の opt-in 既定 OFF と完全に等価な挙動を保ち、
# gate OFF 時は claude / gh / git の呼び出しゼロで状態ファイル不生成（NFR 2.1 観測ログ diff ゼロ）。
#
# 既定反転の背景（#432）: codex の PR Reviewer Processor が設計 PR をスキップするため、本機能が
# OFF だと設計 PR のレビュー担い手が不在になり、`claude-review` を必須 status check に採用済の
# repo で設計 PR が永久 BLOCKED 化する（レビュー空白）。既定 ON でこの空白を解消する。
#
# `claude-review` は本機能導入後、impl 系（adjudicator #404 + catch-up #374）と design 系
# （本機能）の独立した publisher を持つが、catch-up は `review-notes.md` 不在の設計 PR で
# silent skip し、本機能は header pattern を design に厳格化することで両者の対象 PR が
# 構造的に分離される（design.md「`claude-review` publisher contention」節）。
#
# 関数本体は modules/pr-design-reviewer.sh、ロガー pdr_log / pdr_warn / pdr_error は
# core_utils.sh 配置済み。最終正規化は後段の「デフォルト有効化フラグの値正規化」ループでも
# 同様に適用される（#412 PR_REVIEWER_ADJUDICATOR_ENABLED と同型）。
DESIGN_REVIEWER_ENABLED="${DESIGN_REVIEWER_ENABLED:-true}"
# 値正規化: `false` 厳密一致のみ OFF とし、それ以外（未設定 / 空 / `True` / `TRUE` / `1` /
# typo 等）はすべて `true` に固定する（#432 Req 1.1〜1.5 安全側）。
case "$DESIGN_REVIEWER_ENABLED" in
  false) : ;;
  *)     DESIGN_REVIEWER_ENABLED="true" ;;
esac
# 設計 Reviewer 呼び出しモデル（既存 PR_REVIEWER_ADJUDICATOR_MODEL 命名規約踏襲）。
# 空文字なら既定にフォールバック。
DESIGN_REVIEWER_MODEL="${DESIGN_REVIEWER_MODEL:-claude-sonnet-4-6}"
if [ -z "$DESIGN_REVIEWER_MODEL" ]; then
  DESIGN_REVIEWER_MODEL="claude-sonnet-4-6"
fi
# claude 実行 timeout 秒。既存 PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT と同じ case パターン
# で非数値 / 0 以下を既定 300 に正規化（NFR 4.1 既定 5 分以内）。
DESIGN_REVIEWER_EXEC_TIMEOUT="${DESIGN_REVIEWER_EXEC_TIMEOUT:-300}"
case "$DESIGN_REVIEWER_EXEC_TIMEOUT" in
  ''|*[!0-9]*) DESIGN_REVIEWER_EXEC_TIMEOUT="300" ;;
  *)
    if [ "$DESIGN_REVIEWER_EXEC_TIMEOUT" -lt 1 ] 2>/dev/null; then
      DESIGN_REVIEWER_EXEC_TIMEOUT="300"
    fi
    ;;
esac
# プロンプトテンプレ override（空なら pr-design-reviewer.sh が内蔵 default =
# design-review-prompt.tmpl を解決）。
DESIGN_REVIEWER_PROMPT="${DESIGN_REVIEWER_PROMPT:-}"
# 候補 head 判定 ERE。既存 `PR_ITERATION_DESIGN_HEAD_PATTERN` と既定値を共有することで、
# 本 processor で判定された設計 PR は確実に process_pr_iteration の design 経路でも処理される
# 対称性を担保する（Req 4.3 / design.md「env var 仕様」節）。本 env は独立 env のため、
# 本 processor の env を変更しても `pi_*` は影響を受けない（Req 6.3 の env 名不変原則と整合）。
DESIGN_REVIEWER_HEAD_PATTERN="${DESIGN_REVIEWER_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
# 1 サイクルあたり処理する設計 PR 数上限（コスト抑制）。非数値 / 0 以下は既定 5 に正規化
# （既存 PR_REVIEWER_MAX_PRS / SECURITY_REVIEW_MAX_PRS 既定踏襲）。
DESIGN_REVIEWER_MAX_PRS="${DESIGN_REVIEWER_MAX_PRS:-5}"
case "$DESIGN_REVIEWER_MAX_PRS" in
  ''|*[!0-9]*) DESIGN_REVIEWER_MAX_PRS="5" ;;
  *)
    if [ "$DESIGN_REVIEWER_MAX_PRS" -lt 1 ] 2>/dev/null; then
      DESIGN_REVIEWER_MAX_PRS="5"
    fi
    ;;
esac
# 期待出力形式（`text` または `json`）。`text` / `json` 以外（未設定 / typo / 大文字違い等）は
# 安全側で `text` に正規化（design.md「Data Models」節「parse 失敗時の fallback」と整合）。
DESIGN_REVIEWER_OUTPUT_FORMAT="${DESIGN_REVIEWER_OUTPUT_FORMAT:-text}"
case "$DESIGN_REVIEWER_OUTPUT_FORMAT" in
  text|json) : ;;
  *) DESIGN_REVIEWER_OUTPUT_FORMAT="text" ;;
esac

# ─── Security Review Processor 設定 (#279) ───
# Claude Code 公式 `/security-review` skill を `claude` CLI headless 起動経由で呼び出し、
# open PR の diff に対するセキュリティレビューを PR コメントとして投稿する。本 spec では
# **advisory 固定**動作（マージブロックなし）で、strict 拡張は別 Issue #281 として段階導入。
# **完全な opt-in**（NFR 1.1）。SECURITY_REVIEW_ENABLED=true 厳密一致以外は env を読みもせず
# process_security_review が早期 return するため、未設定環境では本機能導入前と挙動が等価。
# 関数本体は modules/security-review.sh、ロガー sec_log / sec_warn / sec_error は core_utils.sh。
# strict 関連 env（SECURITY_REVIEW_MODE / SECURITY_REVIEW_BLOCK_SEVERITY 等）は本 spec で
# 導入せず（別 Issue #281 で確定）、sec_check_strict_request が WARN + advisory fallback する。
SECURITY_REVIEW_ENABLED="${SECURITY_REVIEW_ENABLED:-false}"
# スキャン指示プロンプト本文（Skill tool 経由 `/security-review` 起動を誘発する文字列）。
# `Use the /security-review skill` を含めることで Claude Code 内部の Skill tool による
# built-in slash command 起動が誘発される（design.md「CLI 起動契約」節）。検出 0 件時に
# `SECURITY_REVIEW_CLEAN` センチネル行を出力させる prompt 規約を組み込み、
# sec_run_review_for_pr がこの行の有無で clean / non-clean を分岐判定する。
# export 必須: sec_execute_security_review が `bash -c "$resolved_cmd"` で起動する子シェルは
# 完全新規プロセスのため、parent shell の **非 export 変数を継承しない**。既定
# SECURITY_REVIEW_CLAUDE_CMD のリテラル `"\$SECURITY_REVIEW_PROMPT"` を子シェル env から
# 展開させるため、本変数は export して env 継承を確立する必要がある（#286 / Req 1.1, 1.2）。
export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-Use the /security-review skill to analyze the PR diff between origin/${BASE_BRANCH:-main} and HEAD for security vulnerabilities (injection / secret leak / auth bypass / XSS / dependency CVE 等). Report findings as markdown with severity (critical/high/medium/low/info) and concrete remediation. If no issues are found, output exactly the line: SECURITY_REVIEW_CLEAN.}"
# `claude` CLI に渡すモデル（既定 claude-opus-4-8）。セキュリティ判断は false positive /
# false negative 境界が微妙で reasoning 能力が検出品質に直結するため Opus 系を採用。
# コスト最適化したい場合は SECURITY_REVIEW_MODEL=claude-sonnet-4-6 等への override 可。
SECURITY_REVIEW_MODEL="${SECURITY_REVIEW_MODEL:-claude-opus-4-8}"
# `claude` CLI に渡す --max-turns 値（Skill tool 経由起動 + 解析往復を吸収）。
SECURITY_REVIEW_MAX_TURNS="${SECURITY_REVIEW_MAX_TURNS:-30}"
# 実行コマンドテンプレート。プレースホルダ {BASE}/{HEAD}/{PR}/{PROMPT_FILE} を置換後に
# bash -c で実行（eval 不使用、design.md Security Considerations）。`-p` モードでは
# slash command 直接実行は無効のため、プロンプト本文で Skill tool 起動を依頼する経路を採る。
# --permission-mode plan で write 系ツールの実行を Claude 側でブロックし、実行後の
# `git status --porcelain` 検査と二重防御（read-only invariant）。
# 既定値中の \$SECURITY_REVIEW_PROMPT はリテラル保持し、bash -c subshell が env から展開する。
# export 補強: 運用者が独自モジュールから直接参照する将来性 / 一貫性のため export 化に揃える
# （NFR 1.1 観測挙動に変化なし。parent shell で $resolved_cmd に展開済みのため CLI 起動経路
# 自体は export 不要だが、Config ブロック全体の env 継承契約を明確化する / #286 / Req 4.2）。
export SECURITY_REVIEW_CLAUDE_CMD="${SECURITY_REVIEW_CLAUDE_CMD:-claude -p \"\$SECURITY_REVIEW_PROMPT\" --output-format text --max-turns ${SECURITY_REVIEW_MAX_TURNS} --model ${SECURITY_REVIEW_MODEL} --permission-mode plan}"
# 対象 head ブランチ pattern（jq の test() 互換 POSIX ERE）。idd-claude 生成ブランチに限定。
SECURITY_REVIEW_HEAD_PATTERN="${SECURITY_REVIEW_HEAD_PATTERN:-^claude/issue-}"
# 1 サイクルあたりの処理上限（残りは次回サイクルへ持ち越し、AC 2.5）。
SECURITY_REVIEW_MAX_PRS="${SECURITY_REVIEW_MAX_PRS:-5}"
# git / gh 各操作の個別タイムアウト（秒）。スキャン実行自体は下の EXEC_TIMEOUT が支配。
SECURITY_REVIEW_GIT_TIMEOUT="${SECURITY_REVIEW_GIT_TIMEOUT:-120}"
# スキャン実行コマンドの最大経過秒数（既存 PR_REVIEWER_EXEC_TIMEOUT と同値）。
SECURITY_REVIEW_EXEC_TIMEOUT="${SECURITY_REVIEW_EXEC_TIMEOUT:-600}"
# ─── Security Review Processor strict モード設定 (#281) ───
# 上記 #279 advisory 動作の上に重ねる strict モード切替。本 3 env はすべて未設定 / 空 /
# 不正値で advisory（#279）動作と byte 等価に倒れる完全 opt-in（Req 1.1 / 1.5 / NFR 1.1）。
# 関数本体（mode 解決 / 閾値解決 / ラベル付与）は modules/security-review.sh 側で実装する。
#
# SECURITY_REVIEW_MODE: Security Review の挙動モード切替。
#   - 既定値: advisory（#279 動作と byte 等価。未設定環境では本機能導入前と等価）
#   - 許容値: advisory（advisory 固定）/ strict（severity 閾値以上検出時にラベル付与）
#   - その他の値（typo / 大文字混在 / 空白混入等）は sec_check_strict_request が WARN を
#     出した上で advisory に倒す（Req 1.4 safe-fallback、#279 と同等の防御挙動）
#   - 厳密一致判定。`=strict` のみが strict 解釈となり、`=Strict` / `=STRICT` 等は不正値扱い
#   - #279 では Config 未宣言で関数内 ${VAR:-} 直接参照だったため、本 spec で観測しやすさの
#     ために明示宣言する（既定 advisory のため #279 動作と完全に byte 等価）
SECURITY_REVIEW_MODE="${SECURITY_REVIEW_MODE:-advisory}"
# SECURITY_REVIEW_BLOCK_SEVERITY: strict モード時のラベル付与判定 severity 閾値。
#   - 既定値: high（critical / high の 2 段階を「閾値以上」として扱う / Req 2.2）
#   - 許容値: critical / high / medium / low / info の 5 段階小文字 token に限定（Req 2.1）
#   - ordinal: critical > high > medium > low > info（critical=5 ... info=1）
#   - その他の値（typo / 大文字混在 / 空白混入等）は sec_resolve_block_severity が WARN を
#     出した上で既定 high に倒す（Req 2.4 safe-fallback）
SECURITY_REVIEW_BLOCK_SEVERITY="${SECURITY_REVIEW_BLOCK_SEVERITY:-high}"
# SECURITY_REVIEW_BLOCK_LABEL: strict 検出時に対象 PR へ付与するマージ阻害ラベル名。
#   - 既定値: needs-security-fix（.github/scripts/idd-claude-labels.sh で task 1 にて追加済み）
#   - 運用者が既存ラベルへ振り替えたい場合の override 経路として env 化
#   - `needs-iteration` は PR Iteration Processor (#26) 動線連携のため常時セットで付与され、
#     本 env では制御しない（ハードコード）
SECURITY_REVIEW_BLOCK_LABEL="${SECURITY_REVIEW_BLOCK_LABEL:-needs-security-fix}"

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

# ─── Failed Recovery Processor 設定 (#359) ───
# `claude-failed` ラベル付き Issue（reviewer-reject 由来も含む）と auto-merge 待ち PR の
# CI 失敗を、fresh Claude session で自動解析・修正して開発を再開させる opt-in 機能。
# Issue 単位の **通算 attempt budget**（既定 4 / `FAILED_RECOVERY_MAX_ATTEMPTS`）を唯一の
# カウンタとして扱い、Reviewer 内部 2/2 試行・pr-iteration 3R と掛け算しない（D-19b）。
# 同原因再発 + 無進捗の no-progress ガードで早期終端する。
#
# **AND 二重 opt-in**: `FAILED_RECOVERY_ENABLED=true` AND `FULL_AUTO_ENABLED=true`
# （#348 kill switch）が双方 ON のときのみ動作する。いずれかが OFF（既定）なら gh API
# 呼び出しゼロ・状態ファイル不生成・コメント不投稿で本機能導入前と完全に等価（Req 1.1
# 〜 1.5, NFR 1.3）。`=true` 厳密一致以外（未設定 / 空 / `false` / `0` / `True` /
# `TRUE` / `1` / `on` / `yes` / typo 等）はすべて OFF に正規化（Req 1.5）。本フラグは
# 新規追加 = opt-in 制 + 既定 false が要件のため、上記「デフォルト有効化フラグの値正規化」
# ループには **含めない**。
#
# 関数本体は modules/failed-recovery.sh、ロガー fr_log / fr_warn / fr_error は core_utils.sh。
FAILED_RECOVERY_ENABLED="${FAILED_RECOVERY_ENABLED:-false}"
case "$FAILED_RECOVERY_ENABLED" in
  true) : ;;
  *)    FAILED_RECOVERY_ENABLED="false" ;;
esac
# Issue 単位の通算 attempt 上限。未設定 / 非整数 / 0 以下は既定 4 に正規化（Req 4.8）。
FAILED_RECOVERY_MAX_ATTEMPTS="${FAILED_RECOVERY_MAX_ATTEMPTS:-4}"
case "$FAILED_RECOVERY_MAX_ATTEMPTS" in
  ''|*[!0-9]*) FAILED_RECOVERY_MAX_ATTEMPTS=4 ;;
  *)
    if [ "$FAILED_RECOVERY_MAX_ATTEMPTS" -le 0 ]; then
      FAILED_RECOVERY_MAX_ATTEMPTS=4
    fi
    ;;
esac
# 1 試行あたりの Claude 実行 turn 数上限（既存 PR_ITERATION_MAX_TURNS と同既定）。
FAILED_RECOVERY_MAX_TURNS="${FAILED_RECOVERY_MAX_TURNS:-60}"
# Failed Recovery 専用モデル ID（既存 DEV_MODEL 連鎖で fallback）。
FAILED_RECOVERY_DEV_MODEL="${FAILED_RECOVERY_DEV_MODEL:-${DEV_MODEL:-claude-opus-4-8}}"
# gh / git 操作の個別タイムアウト（秒）。既存 AUTO_MERGE_GIT_TIMEOUT 等と同既定。
FAILED_RECOVERY_GIT_TIMEOUT="${FAILED_RECOVERY_GIT_TIMEOUT:-60}"
# 1 サイクルで処理する Issue / PR 数の上限（残りは次回サイクルに持ち越し）。
FAILED_RECOVERY_MAX_PRS="${FAILED_RECOVERY_MAX_PRS:-3}"
# 状態ファイル（通算カウンタ + 直前試行情報の JSON）の配置先。既定 $HOME/.issue-watcher/
# failed-recovery/$REPO_SLUG。LOG_DIR と同じ repo-slug 分離方針（NFR 2.2, NFR 2.3）。
FAILED_RECOVERY_STATE_DIR="${FAILED_RECOVERY_STATE_DIR:-$HOME/.issue-watcher/failed-recovery/$REPO_SLUG}"
# ─── Failed Recovery 即時失敗判定の閾値 (#411) ───
# recovery claude session が「実質作業前に即時失敗した試行」を attempt budget から
# 除外するための判定閾値（Req 1.2 / 1.3）。判定条件は:
#   (a) claude exit code が非ゼロ かつ quota sentinel 99 ではない
#   (b) stream-json 中に tool use イベントが 1 件も観測されていない
#   (c) セッション継続時間（end - start 秒）が即時失敗閾値未満
# 既定 10 秒は altpocket-server #119 で観測された ~2 秒 rc=1 を確実に拾える保守値。
# 上書き可能（未設定 / 非整数 / 0 以下 / 負値は既定 10 に正規化、安全側 = リトライ過剰
# 除外による無限ループにならない側 / NFR 1.2）。
FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS="${FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS:-10}"
case "$FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS" in
  ''|*[!0-9]*) FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10 ;;
  *)
    if [ "$FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS" -le 0 ]; then
      FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10
    fi
    ;;
esac
# 同一 Issue / PR の即時失敗連続上限（Req 1.5 / 1.6）。通算 attempt budget とは独立した
# カウンタで、上限到達時は `claude-failed` を据え置いたまま `immediate-failure-streak`
# 終端理由で 1 度だけ運用者にエスカレーションする（quota 燃焼上界保証 / 無限リトライ防止）。
# 既定 3 = 「3 cycle 連続で claude が起動できなければ手動レビュー」運用前提。上書き可能。
FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK="${FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK:-3}"
case "$FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK" in
  ''|*[!0-9]*) FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3 ;;
  *)
    if [ "$FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK" -le 0 ]; then
      FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3
    fi
    ;;
esac

# ─── Stale Pickup Reaper 設定 (#379) ───
# セッション喪失で `claude-picked-up` / `claude-claimed` ラベルが取り残された Issue を
# 検出し、3 観点（marker 経過時間 / slot ロック保持 / セッション存在）AND 判定で
# 非アクティブと確定したものだけを `auto-dev` 状態へ戻す opt-in processor。
# `claude-failed` は failed-recovery (#359) の領分なので扱わない。
#
# **単独 opt-in**: `STALE_PICKUP_REAPER_ENABLED=true` 厳密一致のみ ON（failed-recovery
# のような二重 opt-in は不要 / design.md "FULL_AUTO_ENABLED 配下に置くか単独 gate か"
# 節）。`=true` 以外（未設定 / 空 / `false` / `0` / `True` / `TRUE` / `1` / `on` /
# `yes` / 前後空白 / typo 等）は安全側 `false` に正規化する（Req 1.3 / NFR 1.1）。
# 本フラグは新規追加 = opt-in 制 + 既定 false が要件のため、上記
# 「デフォルト有効化フラグの値正規化」ループには **含めない**（failed-recovery と同方針）。
#
# 関数本体は modules/stale-pickup-reaper.sh に集約する（task 2 で本体から移送済み /
# Persistence Layer 含む）。ロガー sr_log / sr_warn / sr_error は core_utils.sh に集約。
# REQUIRED_MODULES への登録と call site 配線は task 6 で実施済み。
STALE_PICKUP_REAPER_ENABLED="${STALE_PICKUP_REAPER_ENABLED:-false}"
case "$STALE_PICKUP_REAPER_ENABLED" in
  true) : ;;
  *)    STALE_PICKUP_REAPER_ENABLED="false" ;;
esac
# pickup 系ラベル滞留の許容時間（分）。未設定 / 非整数 / 0 以下は既定 45 に正規化（Req 4.3）。
# 既定 45 分は典型的 impl 時間 + 30 分マージンの保守側目安（design.md Risk Register 参照）。
STALE_PICKUP_REAPER_THRESHOLD_MINUTES="${STALE_PICKUP_REAPER_THRESHOLD_MINUTES:-45}"
case "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" in
  ''|*[!0-9]*) STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45 ;;
  *)
    if [ "$STALE_PICKUP_REAPER_THRESHOLD_MINUTES" -le 0 ]; then
      STALE_PICKUP_REAPER_THRESHOLD_MINUTES=45
    fi
    ;;
esac
# marker JSON の配置先。failed-recovery と同じ $HOME/.issue-watcher/ 配下 repo-slug
# 分離方針（NFR 2.3）。`/tmp` 配下の予測可能名は使用しない。
STALE_PICKUP_REAPER_STATE_DIR="${STALE_PICKUP_REAPER_STATE_DIR:-$HOME/.issue-watcher/stale-pickup/$REPO_SLUG}"
# 1 サイクルで処理する候補 Issue 数の上限。未設定 / 非整数 / 0 以下は既定 20 に正規化。
STALE_PICKUP_REAPER_MAX_ISSUES="${STALE_PICKUP_REAPER_MAX_ISSUES:-20}"
case "$STALE_PICKUP_REAPER_MAX_ISSUES" in
  ''|*[!0-9]*) STALE_PICKUP_REAPER_MAX_ISSUES=20 ;;
  *)
    if [ "$STALE_PICKUP_REAPER_MAX_ISSUES" -le 0 ]; then
      STALE_PICKUP_REAPER_MAX_ISSUES=20
    fi
    ;;
esac
# 個別 gh 操作のタイムアウト（秒）。未設定 / 非整数 / 0 以下は既定 60 に正規化。
STALE_PICKUP_REAPER_GH_TIMEOUT="${STALE_PICKUP_REAPER_GH_TIMEOUT:-60}"
case "$STALE_PICKUP_REAPER_GH_TIMEOUT" in
  ''|*[!0-9]*) STALE_PICKUP_REAPER_GH_TIMEOUT=60 ;;
  *)
    if [ "$STALE_PICKUP_REAPER_GH_TIMEOUT" -le 0 ]; then
      STALE_PICKUP_REAPER_GH_TIMEOUT=60
    fi
    ;;
esac

# Stale Pickup Reaper の `sr_is_enabled` ゲート関数および永続化レイヤ（sr_marker_path /
# sr_load_marker / sr_save_marker）は modules/stale-pickup-reaper.sh に集約されている
# （task 2 で本体から module 側へ移送）。`REQUIRED_MODULES` への登録と call site
# 配線は task 6 で実施済み（行 1051 の配列追加 + 行 1589 直後の
# process_stale_pickup_reaper 呼び出し）。

# ─── Slack 通知 emitter 設定 (#370) ───
# 自動 merge / failed-recovery 終端 / needs-decisions 自動続行 / promote 完了といった
# 人間が能動的に把握すべき重要イベントを Slack Incoming Webhook 経由で push 通知する
# 補助的な観測チャネル（D-18 / 低優先）。**完全な opt-in**（Req 1.1 / NFR 1.1）。
# `SLACK_NOTIFY_ENABLED=true` 厳密一致以外は env を読みもせず sn_notify が早期 return する
# ため、未設定環境では本機能導入前と挙動が等価（gh / git API 呼び出し回数・ラベル遷移・
# コミット・push に対する影響ゼロ）。webhook URL は env 経由のみで受け取り、コードベース・
# ログ・テストフィクスチャに実値を残さない（Req 6.3 / NFR 3.1）。
#
#   - SLACK_NOTIFY_ENABLED: gate。`=true` 厳密一致のみ ON。それ以外（未設定 / 空文字 /
#                           `True` / `1` / `on` / `yes` / 典型的 typo / 前後空白）は安全側
#                           OFF として正規化する（sn_is_enabled 内で case 判定 / Req 1.3）。
#   - SLACK_WEBHOOK_URL:    Slack Incoming Webhook URL。secret 値。`SLACK_NOTIFY_ENABLED=true`
#                           かつ本 env が未設定 / 空のときは sn_warn を 1 行出して no-op
#                           （Req 1.4 / 5.3）。
#   - SLACK_NOTIFY_TIMEOUT: HTTP POST の最大経過秒数（curl --max-time）。既定 5 秒
#                           （Req 4.5 / NFR 2.2）。非数値 / 負数 / 空文字は sn_post_webhook
#                           内で既定 5 に正規化される。
SLACK_NOTIFY_ENABLED="${SLACK_NOTIFY_ENABLED:-false}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_NOTIFY_TIMEOUT="${SLACK_NOTIFY_TIMEOUT:-5}"

# ─── Auto-Merge Merged Notify Processor 設定 (#388) ───
# `auto-merge` / `auto-merge-design` で armed された PR の実 merge 完了を後続サイクルで
# 観測し、「merge 完了」を表す Slack 通知（event_type=auto-merge-merged /
# auto-merge-design-merged）を 1 度だけ送るための補助 processor。armed と merged を
# Slack 上で分離して受信者が判別可能にする（Req 1.x / 2.x）。
#
# **完全な opt-in**（Req 3.4 / NFR 4.1）。`SLACK_NOTIFY_MERGED_ENABLED=true` 厳密一致
# 以外は state file も書かれず、本 processor は gh API ゼロ呼び出しで早期 return する
# （本機能導入前 = #388 修正前と完全に等価）。`SLACK_NOTIFY_ENABLED=true` だけが有効な
# ユーザには「armed 通知の文面と result 値が変わる」修正のみ反映され、新規 merged 通知
# は発火しない（README migration note 参照）。
#
#   - SLACK_NOTIFY_MERGED_ENABLED: 本 processor の gate。`=true` 厳密一致のみ ON。
#                                  それ以外（未設定 / 空 / `True` / `1` / `on` / typo /
#                                  前後空白）はすべて安全側 OFF として正規化する
#                                  （amm_resolve_gate_enabled / Req 3.5 / NFR 4.1）。
#   - AUTO_MERGE_MERGED_STATE_DIR: pending state ファイルの配置先。既定は
#                                  `$HOME/.issue-watcher/auto-merge-pending/<repo-slug>`
#                                  （CLAUDE.md §6 準拠 / NFR 4.4 / 通常変更不要）。
#   - AUTO_MERGE_MERGED_MAX_CHECKS: 1 サイクルあたりの `gh pr view` 呼び出し上限件数。
#                                  既定 50。state file 数で自然制約されるが、保険として
#                                  上限を持つ（NFR 3.2）。
#   - AUTO_MERGE_MERGED_GH_TIMEOUT: 1 件あたりの `gh pr view` タイムアウト（秒）。既定 60。
SLACK_NOTIFY_MERGED_ENABLED="${SLACK_NOTIFY_MERGED_ENABLED:-false}"
AUTO_MERGE_MERGED_STATE_DIR="${AUTO_MERGE_MERGED_STATE_DIR:-$HOME/.issue-watcher/auto-merge-pending/$REPO_SLUG}"
AUTO_MERGE_MERGED_MAX_CHECKS="${AUTO_MERGE_MERGED_MAX_CHECKS:-50}"
AUTO_MERGE_MERGED_GH_TIMEOUT="${AUTO_MERGE_MERGED_GH_TIMEOUT:-60}"

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

# ─── Scaffolding Health Gate 設定 (#238) ───
# worktree reset ＋ `.claude` 注入（#237）完了直後・最初の agent stage 起動前に、worktree 内の
# `.claude/agents` / `.claude/rules` 足場の非空到達性を検査する preflight gate（Req 1）。
# 欠落検出時は loud WARN ＋ Issue コメント可視シグナルを残す。検査ロジックは
# modules/scaffolding-health.sh に集約し、本体は call site と `--doctor` dispatch のみを持つ。
#
#   - SCAFFOLDING_HEALTH_HALT:  足場欠落検出時の挙動切替。既定 `off`（= 可視化のみ・進行継続）。
#                               `on` 厳密一致のときのみ HALT（agent stage を起動せず claim 系
#                               ラベルを除去して人間判断待ちへ遷移）。`on` 以外（off / 未設定 /
#                               空 / true / On / typo すべて）は既定の可視化のみとして解釈する
#                               （Req 2.1, 2.3）。既定挙動（可視化のみ・進行継続）は本機能導入
#                               前の自動進行フローと user-observable に同一（後方互換 / NFR 1.1）。
SCAFFOLDING_HEALTH_HALT="${SCAFFOLDING_HEALTH_HALT:-off}"

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

# ─── Tasks Count Gate: 子 Issue 分割案コメント (#509, モデルルーティング Phase 3) ───
# 新規 opt-in 機能。明示的に `=true`（リテラル文字列 / 厳密一致）を指定したときだけ、
# escalate 判定（既定 ≥ 11 件）に伴って `tasks.md` の最上位・未完了タスクから
# 機械生成した **子 Issue 分割案** をコメント投稿する（Req 1.2 / 2.1）。
# `=true` 以外（未設定 / 空 / `false` / `off` / `True` / `1` / typo 等）はすべて
# 安全側（無効）へ正規化する（Req 1.1 / 1.3）。無効時は本機能に起因する
# GitHub API 呼び出しもログ出力も 0 件で、本機能導入前と完全に同一の escalate
# 挙動になる（Req 1.4 / 6.1 / NFR 1.1）。
#
# 本 gate は `TC_ENABLED`（tasks-count gate 自体の opt-out）および
# `MODEL_ROUTING_ENABLED`（#507）とは **独立した変数** で制御する（Req 1.5）。
# ただし `TC_ENABLED=false` で tasks-count gate 自体が走らない場合、本機能も
# 構造的に起動しない（Req 1.6）。
# 子 Issue の自動起票は行わず提案コメントの投稿までに留める（Out of Scope）。
# 本フラグは新規追加 = opt-in 制 + 既定無効が要件のため、上記「デフォルト有効化
# フラグの値正規化」ループには **含めない**（#112 の 8 種反転対象とは別扱い）。
# 詳細は docs/specs/509-feat-watcher-tasks-count-gate-escalate-i/requirements.md を参照。
TC_SPLIT_PROPOSAL_ENABLED="${TC_SPLIT_PROPOSAL_ENABLED:-false}"

# ─── Phase E: Path Overlap Checker 設定 (#18) ───
# 新規 opt-in 機能。明示的に `=true` を指定したときだけ起動する（Req 1.1〜1.4）。
# `=true` 以外（未設定 / 空 / `false` / `0` / `True` / `1` / typo 等）はすべて off
# として扱う（Req 1.3）。本フラグは新規追加 = opt-in 制 + 既定 off が要件のため、
# 上記「デフォルト有効化フラグの値正規化」ループには **含めない**（#112 の 8 種
# 反転対象とは別扱い）。
# 詳細は docs/specs/18-phase-e-triage-path-overlap-hot-file/design.md を参照。
PATH_OVERLAP_CHECK="${PATH_OVERLAP_CHECK:-off}"

# ─── Phase E: 多忙サイクル待ちの可視化閾値 (#228 Req 3 / NFR 1) ───
# 後続 Issue が空き slot 不足（自インスタンスの全 slot busy / 別インスタンス稼働で
# 全 slot lock 中）により dispatch を見送られた状態が「連続 N cron tick」継続したら、
# 待機中である旨の可視化シグナル（awaiting-slot ラベル + 専用 sticky comment）を残す。
# 一過性（transient / 数 tick で解消）な待機ではコメントを残さずノイズを抑制する
# （Req 3.4 / NFR 1.1）。本機能は PATH_OVERLAP_CHECK=true のときのみ有効で、未設定 /
# off / 不正値では一切動かない（Req 5.1 / 5.2）。
# 単位は cron tick 数（経過時間ではなく「見送りが観測された連続サイクル数」）。閾値は
# ノイズ抑制側に倒した保守的な既定値。cron 間隔 */2 分なら 5 tick ≒ 10 分相当。
# 0 / 空 / 非数値は安全側で既定値 5 へフォールバックする（誤設定で連投しない）。
PATH_OVERLAP_BUSY_WAIT_THRESHOLD="${PATH_OVERLAP_BUSY_WAIT_THRESHOLD:-5}"

# ─── Model Routing: Triage complexity → size ラベル永続化 (#507, Phase 1) ───
# 新規 opt-in 機能。明示的に `=true`（リテラル文字列 / 厳密一致）を指定したときだけ
# size ラベルの永続化を行う（Req 3.2）。`=true` 以外（未設定 / 空 / `false` / `off` /
# `True` / `1` / typo 等）はすべて安全側（無効）へ正規化する（Req 3.1 / 3.3）。
# 無効時は本機能に起因するラベル読み書き・GitHub API 呼び出しを一切行わず、
# ログ出力も 0 行 = 本機能導入前と完全に同一の挙動になる（Req 3.4 / NFR 1.1）。
# 本フラグは新規追加 = opt-in 制 + 既定無効が要件のため、上記「デフォルト有効化
# フラグの値正規化」ループには **含めない**（#112 の 8 種反転対象とは別扱い）。
#
# gate 粒度: モデルルーティング機能 family（Phase 1 のラベル永続化および後続 Phase の
# モデル解決）を **単一の gate** で制御し、Phase 別の追加 gate は設けない（Req 3.6）。
# なお Triage 側の `complexity` / `complexity_reason` 出力は gate に依らず常時行われる
# （gate は watcher 側の永続化のみを制御する / Req 3.5）。
# 詳細は docs/specs/507-feat-watcher-triage-complexity-size-phas/design.md を参照。
MODEL_ROUTING_ENABLED="${MODEL_ROUTING_ENABLED:-false}"

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

# ─── #313: Context Map for per-task agents（標準機能 / 常時有効） ───
# per-task Implementer / Reviewer ループ（`PER_TASK_LOOP_ENABLED=true`）配下では
# 各 task 起動直前に `docs/specs/<番号>-<slug>/context-map.md` を決定論的に生成し、
# prompt 末尾に inline embed する（広域 grep / glob を抑止して turn 効率を改善する
# 補助情報）。当初の opt-in gate だった `CONTEXT_MAP_ENABLED` は削除し、per-task
# ループの内在機能として常時有効化した（旧 env を cron 等に残しても無害な no-op）。
# 単一実装パス（`PER_TASK_LOOP_ENABLED` 未設定）では従来どおり未注入。詳細は
# docs/specs/313-feat-watcher-context-map-per-task-agent/design.md を参照。

# ─── #304: per-task post-marker commit recovery mode ───
# per-task Reviewer 起動前の `pt_detect_post_marker_commits` で marker 後の未レビュー commit
# が検出されたときの復旧モードを切り替える env（Req 2.2, 2.3）。idd-codex #14 と同型の
# silent range truncation（修正 commit が古い marker 後ろに積まれ Reviewer から漏れる）を
# 防ぐ safety net の挙動を運用者が制御できる。
#
# - POST_MARKER_RECOVERY_MODE: 既定 `fail-with-diagnostic`。明示的 `extend-range` で opt-in
#   切替。不正値・未設定はすべて default の `fail-with-diagnostic` にフォールバックする
#   （安全側に倒す / Req 2.2 abort 経路の決定論性）。
POST_MARKER_RECOVERY_MODE="${POST_MARKER_RECOVERY_MODE:-fail-with-diagnostic}"

# ─── #356: per-task post-marker commit の docs-only auto-refresh allowlist ───
# `pt_classify_post_marker_paths` が「docs-only」と判定するための変更ファイルパスの
# allowlist（カンマ区切り glob パターン）。post-marker commit 群の全変更ファイルが
# このいずれかにマッチした場合、`pt_handle_post_marker_commits` は
# `POST_MARKER_RECOVERY_MODE=fail-with-diagnostic`（default）であっても safety net を
# 発火せず、marker を HEAD まで auto-refresh して per-task Reviewer を続行する
# （Req 1.1, 1.5）。
#
# - 既定値は `impl-notes.md` / `docs/specs/**/*.md` の 2 パターン。`docs(impl-notes):
#   learning 追記` のような「Developer agent の Marker contract に従っているが手順順序の
#   都合で marker 後ろに積まれてしまった文書 commit」のみを救済し、コード / テスト /
#   設定ファイルが 1 件でも混在すれば safety net 発火に倒す（Req 2.2）。
# - パターンマッチングは `ar_classify_diff` と同じ POSIX bash `[[ "$path" == $pattern ]]`
#   イディオムで行うため、glob ワイルドカード `*` / `**` / `?` が利用可能。
# - `POST_MARKER_RECOVERY_MODE=extend-range` 設定時はこの auto-refresh 判定は
#   オーバーライドされない（Req 3.3 / 既存 extend-range 挙動を温存）。
POST_MARKER_DOCS_ALLOWLIST="${POST_MARKER_DOCS_ALLOWLIST:-**/impl-notes.md,docs/specs/**/*.md}"

# LOG_DIR と LOCK_FILE は REPO_SLUG を挟むことで repo ごとに分離。
# 環境変数で明示上書きもできる。
LOG_DIR="${LOG_DIR:-$HOME/.issue-watcher/logs/$REPO_SLUG}"
LOCK_FILE="${LOCK_FILE:-/tmp/issue-watcher-${REPO_SLUG}.lock}"

# ─── #243: flock skip 経路 path-overlap 可視化パスの専用ロック ───
# 可視化パスの多重起動を抑止する短命 flock 用ファイル。本サイクルの $LOCK_FILE（fd 200）とは
# 別ファイル・別 fd（201）で取得する（Req 2.2 / 4.1）。LOG_DIR は repo ごとに分離済みのため
# repo 間で衝突しない。env で override 可能・既定無害値（PATH_OVERLAP_CHECK=off 環境では未参照）。
PATH_OVERLAP_VISIBILITY_LOCK_FILE="${PATH_OVERLAP_VISIBILITY_LOCK_FILE:-${LOG_DIR}/flock-skip-visibility.lock}"

# モデル設定
TRIAGE_MODEL="${TRIAGE_MODEL:-claude-sonnet-4-6}"   # Triage は軽量モデルで十分
DEV_MODEL="${DEV_MODEL:-claude-opus-4-8}"           # 本実装は Opus 4.8 + 1M context
TRIAGE_MAX_TURNS="${TRIAGE_MAX_TURNS:-15}"
DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"
# Stage C（PjM / 実装 PR 作成）専用モデル (#328)。PjM は review-notes の commit /
# gh pr create / ラベル付け替えという機械的作業のみのため軽量モデルを既定とする。
# #328 以前は DEV_MODEL が適用されていた（従来挙動に戻すには PJM_MODEL=claude-opus-4-8）。
# design モード（PM → Architect → PjM の単一セッション）は対象外（DEV_MODEL のまま）。
PJM_MODEL="${PJM_MODEL:-claude-sonnet-4-6}"

# ─── Model Routing Phase 2: size 別 Developer モデル (#508) ───
# `size:small` / `size:medium` ラベルが付いた Issue の Developer 実行に用いるモデル ID。
# **既定はいずれも空文字**（Req 2.1）。`MODEL_ROUTING_ENABLED=true` にしただけではモデルは
# 変わらず、ここに値を明示したときに初めて当該 size の Issue へ適用される（gate 有効化だけで
# silent にモデルが下がる事故を避ける二重 opt-in / Req 2.3）。
#
# - 具体的なモデル ID を既定値として埋め込まない（運用者の明示設定にのみ依存 / Req 2.2 /
#   NFR 3.4）。設定例: `DEV_MODEL_SMALL=claude-sonnet-4-6`
# - `size:large` 専用の設定値は設けない。`large` は `DEV_MODEL` を用いる（Req 1.3）。
# - size ラベル不在 / `size:*` 複数付与 / 許可値外はすべて `DEV_MODEL` へ fail-safe。
# - 適用先は **slot 内の Developer 実行のみ**（design セッション / 実装 Stage 群 /
#   per-task ループ）。Triage / Reviewer / PjM / slot 外プロセッサ
#   （`PR_ITERATION_DEV_MODEL` / `FAILED_RECOVERY_DEV_MODEL`）は対象外（Req 3.8 / 3.9）。
# - 解決は slot 起動時点のラベル集合に基づく 1 回のみ。初回 Triage で size ラベルが付いた
#   同一 slot 実行内では `DEV_MODEL` に倒れる（既知の制約 / Req 4.2。詳細は README
#   「Model Routing Phase 2: size ラベル → Developer モデル (#508)」節）。
# - `DEV_MODEL` の既定値・意味・上書き方法は変更していない（Req 2.4）。
DEV_MODEL_SMALL="${DEV_MODEL_SMALL:-}"
DEV_MODEL_MEDIUM="${DEV_MODEL_MEDIUM:-}"

# Triage の --bare 実行 (#332, opt-in)。`true` 厳密一致のみ有効（それ以外はすべて OFF）。
# --bare は CLAUDE.md / .claude/rules / hooks / skills / MCP の自動ロードをスキップし、
# Triage の固定 context を排除する（Triage の判定基準は triage-prompt.tmpl 内で自己完結。
# issue-dependency.md はテンプレートがパス明示しており必要時に Read で到達可能）。
# guard hook（IDD_CLAUDE_HOOKS_ENABLED）opt-in 時は --settings 経由の hook 注入と衝突
# しうるため --bare を見送り WARN を出す（call site 参照 / 安全側）。
TRIAGE_BARE="${TRIAGE_BARE:-false}"

# ─── Issue #442: Reviewer turn 切れ拡張リトライ用の純粋ヘルパー ───
#
# 以下 2 関数は他 module に依存しない純粋関数で、Config ブロック（REVIEWER_MAX_TURNS_EXTENDED
# 正規化）より前方参照されるため、ここ（REQUIRED_MODULES ローダより前 / Reviewer Config 直前）
# に定義する。近接テスト（extract_function 隔離抽出）で単体検証する。

# ─── reviewer_normalize_extended_max_turns <base_max_turns> <raw_extended> ───
#
# 拡張 turn 予算（REVIEWER_MAX_TURNS_EXTENDED）を決定的に正規化して stdout に出力する
# （Req 4.1〜4.4）。
#   - $2 が未設定 / 空 / 数値非解釈（非 `^[0-9]+$`）: base の 2 倍にフォールバック（Req 4.2, 4.3）
#   - $2 が正常な整数だが base 未満: base に引き上げ（Req 4.4。拡張予算は通常予算以上に正規化）
#   - $2 が base 以上の整数: そのまま採用
# base 自体が数値非解釈の場合は安全側に 50（Reviewer 既定）へ丸めてから 2 倍する。
# Stdout: 正規化済み整数 / Return: 0 always
reviewer_normalize_extended_max_turns() {
  local base="${1:-}"
  local raw="${2:-}"
  # base の健全性チェック（通常は REVIEWER_MAX_TURNS = 整数。防御的に丸める）
  case "$base" in
    ''|*[!0-9]*) base=50 ;;
  esac
  # base=0 は意味を成さないため安全側に既定 50 へ
  [ "$base" -gt 0 ] 2>/dev/null || base=50
  local default_ext=$((base * 2))
  # raw が数値非解釈なら既定（2 倍）にフォールバック
  case "$raw" in
    ''|*[!0-9]*)
      echo "$default_ext"
      return 0
      ;;
  esac
  # raw は整数。base 未満なら base に引き上げ（Req 4.4）
  if [ "$raw" -lt "$base" ]; then
    echo "$base"
  else
    echo "$raw"
  fi
  return 0
}

# ─── reviewer_is_error_max_turns <logfile> [offset] ───
#
# claude の stream-json 出力（$LOG に tee 済み）の offset 以降の最後の result イベントが
# `error_max_turns`（turn 上限到達）か判定する（Req 2.4）。turn 切れ起因の非ゼロ exit と、
# それ以外（claude crash 等）を区別するための純粋判定関数。
#   - 最後の result イベントの `.subtype` が `error_max_turns` → return 0（= turn 切れ）
#   - それ以外（success / 別 subtype / result 行なし / 抽出失敗） → return 1（= 非該当）
# token-usage.sh の `tu_extract_last_result_json` を再利用するが、未ロード環境（隔離抽出
# テスト / token-usage.sh 不在）でも完走するよう `declare -F` でガードし、未ロード時は
# 安全側（非検出 = 従来どおり即 error）に倒す。
# Return: 0 = error_max_turns 検出 / 1 = 非該当
reviewer_is_error_max_turns() {
  local logfile="${1:-}"
  local offset="${2:-0}"
  [ -n "$logfile" ] && [ -f "$logfile" ] || return 1
  declare -F tu_extract_last_result_json >/dev/null 2>&1 || return 1
  local result_json subtype
  result_json=$(tu_extract_last_result_json "$logfile" "$offset")
  [ -n "$result_json" ] || return 1
  subtype=$(printf '%s' "$result_json" | jq -r '.subtype // empty' 2>/dev/null || true)
  [ "$subtype" = "error_max_turns" ]
}

# ─── Reviewer subagent 設定 (#20 Phase 1) ───
# impl 系モード（impl / impl-resume）の Developer 完了後に独立 context で起動する
# Reviewer サブエージェント用の env。既存の TRIAGE_* / DEV_* と独立に扱う。
REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-8}"
# Issue #442 OQ2: Reviewer 1 起動あたりの claude turn 上限の既定を 30→50 に引き上げる。
# max-turns は上限（ceiling）であり固定消費ではないため、小規模 spec は早期終了し
# common case の実コストはほぼ不変。大規模 spec での verdict 未到達（turn 切れ即
# claude-failed）の root cause を直接緩和する。既存ユーザの明示 override は壊さない
# （env default のみ変更）。migration note は README「オプション機能一覧」参照（NFR 1.3）。
REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-50}"
# Issue #442 Req 4: turn 切れ（error_max_turns）起因の拡張リトライで使う「拡張 turn 予算」。
# 既定（未設定）は `REVIEWER_MAX_TURNS` の 2 倍（Req 4.1, 4.2）。数値非解釈の不正値は
# 既定（2 倍）にフォールバック（Req 4.3）。明示値が `REVIEWER_MAX_TURNS` 未満なら
# `REVIEWER_MAX_TURNS` に引き上げて正規化する（Req 4.4）。正規化は純粋ヘルパー
# `reviewer_normalize_extended_max_turns` に集約し、起動時にここで丸める（AUTO_REBASE_MODE
# の起動時正規化イディオムに倣う / 安全側へ）。値は operator 設定であり未信頼入力ではない。
REVIEWER_MAX_TURNS_EXTENDED="$(reviewer_normalize_extended_max_turns "$REVIEWER_MAX_TURNS" "${REVIEWER_MAX_TURNS_EXTENDED:-}")"
# Reviewer ステージの条件スキップ (#333, opt-in)。POSIX ERE。空（既定）で無効。
# 全変更ファイルが本パターンに一致する場合のみ Stage B（独立 Reviewer）をスキップし、
# 自動 approve の review-notes.md（hidden marker 付き）を生成する。1 ファイルでも不一致 /
# diff 空 / git 失敗時はスキップせず通常どおり Reviewer を起動する（fail-safe）。
# アプリ系 consumer repo の docs-only 変更向け（例: REVIEWER_SKIP_PATTERN='^docs/'）。
# idd-claude 自身は markdown が成果物本体のため有効化しないこと（README 参照）。
# 値は operator 設定（cron / launchd）であり未信頼入力ではない。
REVIEWER_SKIP_PATTERN="${REVIEWER_SKIP_PATTERN:-}"

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
# - DEBUGGER_MODEL:      Debugger CLI に渡すモデル ID（既定 `claude-opus-4-8`）。
# - DEBUGGER_MAX_TURNS:  Debugger CLI の `--max-turns` 値（既定 `40`、web search 含む）。
DEBUGGER_ENABLED="${DEBUGGER_ENABLED:-false}"
DEBUGGER_MODEL="${DEBUGGER_MODEL:-claude-opus-4-8}"
DEBUGGER_MAX_TURNS="${DEBUGGER_MAX_TURNS:-40}"

# ─── Spec HTML 並行生成 設定 (#526) ───
# 新規 opt-in 機能。明示的に `=true` を指定したときだけ、design / impl 完了直後の
# fail-open hook（slot-worker.sh `_slot_run_issue`）が spec 配下の人間レビュー用 .md
# 成果物に対応する .html を並行生成する（Req 1.1, 1.2）。`.md` は正準（source of
# truth）として不変で、機械ゲート / エージェント連携は .html に一切依存しない
# （Req 3.x）。`=true` 以外（未設定 / 空 / `false` / `0` / `True` / `1` / typo 等）は
# すべて `false` に正規化し、本機能導入前と完全に同一の観測可能挙動を維持する
# （Req 1.1, 1.3 / NFR 1.1）。本フラグは新規追加 = opt-in 制 + 既定 false が要件のため、
# ファイル末尾の「デフォルト有効化フラグの値正規化」ループには **含めない**
# （#112 の 8 種反転対象とは別扱い / `AUTO_REBASE_MODE` と同扱い）。
# 詳細は docs/specs/526-feat-agents-html-md/design.md を参照。
#
# - SPEC_HTML_ENABLED:     本機能の opt-in gate。`true` 厳密一致のみ有効（既定 `false`）。
# - SPEC_HTML_RENDER_BIN:  可用性判定（command -v）対象の md→html CLI（既定 `pandoc`）。
# - SPEC_HTML_RENDER_CMD:  変換コマンドテンプレ。`{IN}` / `{OUT}` を対象 .md / .html
#                          の絶対パスへ置換して実行する（既定は pandoc gfm→html5）。
# - SPEC_HTML_TIMEOUT:     1 ファイル変換の timeout 秒。非整数 / ≤0 は既定 60 に正規化。
# - SPEC_HTML_TARGETS:     並行生成対象の basename allowlist（space 区切り）。
SPEC_HTML_ENABLED="${SPEC_HTML_ENABLED:-false}"
# 値正規化: `true` のみ ON。未設定 / 明示 `false` は既定 OFF として **ログ副作用ゼロ**
# で通す（NFR 1.1）。それ以外（`0` / `True` / `1` / typo 等）は **不正値**として安全側
# `false` に正規化し、スキップ理由を 1 行ログに記録する（Req 1.3）。default（未設定 →
# `false`）と明示 `false` は本 log 分岐に来ないため、既定 OFF 環境ではログ出力先に
# 一切の副作用を与えない（NFR 1.1）。
case "$SPEC_HTML_ENABLED" in
  true|false) : ;;
  *)
    echo "[$(date '+%F %T')] [$REPO] spec-html: WARN: SPEC_HTML_ENABLED='$SPEC_HTML_ENABLED' は不正値のため安全側で無効化（false）します（Req 1.3）" >&2
    SPEC_HTML_ENABLED="false"
    ;;
esac
SPEC_HTML_RENDER_BIN="${SPEC_HTML_RENDER_BIN:-pandoc}"
# 既定コマンドは `{OUT}` / `{IN}` の `}` を含むため、`${VAR:-default}` の default に
# 直書きすると bash が最初の `}` を展開終端と誤認して壊れる。brace を含まない中間変数
# に既定を置いてから `:-` の default として参照する（未設定 / 空文字とも既定を採用）。
_spec_html_render_cmd_default='pandoc -f gfm -t html5 -s -o {OUT} {IN}'
SPEC_HTML_RENDER_CMD="${SPEC_HTML_RENDER_CMD:-$_spec_html_render_cmd_default}"
unset _spec_html_render_cmd_default
SPEC_HTML_TIMEOUT="${SPEC_HTML_TIMEOUT:-60}"
# 非整数 / ≤0 は既定 60 に正規化（timeout に渡す前の安全側フォールバック / Req 1.3）。
case "$SPEC_HTML_TIMEOUT" in
  ''|*[!0-9]*) SPEC_HTML_TIMEOUT=60 ;;
  *)
    if [ "$SPEC_HTML_TIMEOUT" -le 0 ]; then
      SPEC_HTML_TIMEOUT=60
    fi
    ;;
esac
SPEC_HTML_TARGETS="${SPEC_HTML_TARGETS:-requirements.md design.md tasks.md impl-notes.md review-notes.md}"

# ─── PreToolUse Guard Hook 設定 (#294 / base 初版) ───
# Claude Code の PreToolUse フック機構を利用し、watcher が起動する全 claude CLI 実行に
# 対して `--settings <絶対パス>` を opt-in で注入する。hook 本体（idd-guard.sh）と
# settings テンプレ（idd-guard-settings.json）は install.sh が user-scope
# `$IDD_CLAUDE_HOOKS_DIR`（既定 `$HOME/.idd-claude/hooks`）に配置する前提。
#
# 既定 OFF（opt-in 専用）であり、`IDD_CLAUDE_HOOKS_ENABLED=true` の **厳密一致**時にのみ
# 有効化される（typo は安全側で opt-out 扱い / Req 1.1）。未設定 / 空 / `false` /
# `True` / `1` 等はすべて opt-out として扱い、本機能導入前と完全に同一の引数列・環境変数
# 集合で claude を起動する（NFR 1.1 / Req 1.1, 1.2）。値正規化（`true`/`false` への
# 2 値強制）はしない — 上記「デフォルト有効化フラグの値正規化」ループは既定 true の
# フラグ向けであり、本機能は既定 false の opt-in 制のため対象外。
#
# - IDD_CLAUDE_HOOKS_ENABLED:     本機能の opt-in gate（既定空＝opt-out / Req 1.1）
# - IDD_CLAUDE_HOOKS_DIR:         hook 本体の install dir 絶対パス（既定
#                                 `$HOME/.idd-claude/hooks` / NFR 1.3）
# - IDD_CLAUDE_HOOKS_MIN_VERSION: preflight の claude version 最小要求（既定 `2.1.167`
#                                 / PoC 検証バージョン / NFR 1.3）
# - IDD_HOOK_LOG:                 hook 本体が optional に append する 1 行ログのパス
#                                 （未設定で no-op / 運用者が任意に有効化）
# 詳細は docs/specs/294-feat-watcher-pretooluse-guard-hook-base/design.md を参照。
IDD_CLAUDE_HOOKS_ENABLED="${IDD_CLAUDE_HOOKS_ENABLED:-}"
IDD_CLAUDE_HOOKS_DIR="${IDD_CLAUDE_HOOKS_DIR:-$HOME/.idd-claude/hooks}"
IDD_CLAUDE_HOOKS_MIN_VERSION="${IDD_CLAUDE_HOOKS_MIN_VERSION:-2.1.167}"
IDD_HOOK_LOG="${IDD_HOOK_LOG:-}"

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

# ─── GitHub API Rate Guard 設定 (#521) ───
# watcher の 1 サイクル内 GitHub API rate limit（core / graphql / search バケット）消費削減・
# 枯渇耐性のための 5 機能を制御する env 群。関数本体は modules/api-rate-guard.sh（prefix
# grl_）、ロガー grl_log / grl_warn / grl_error は core_utils.sh。すべて opt-in（既定 false /
# `=true` 厳密一致のみ ON）で、未設定・不正値・typo はすべて安全側（無効）へ正規化し、未設定
# 環境は本機能導入前と完全に等価な no-op を保つ（Req 1.1〜1.3, NFR 1.1）。Claude Max quota
# （rate_limit_event / quota-aware.sh の領分）とは別物のため env prefix を GH_API_ に分離。
# 既定 OFF の opt-in 制のため、後段「デフォルト有効化フラグの値正規化」ループには含めない。
#
# Req 2: サイクル内スナップショット共有。`=true` 厳密一致のみ ON（Req 1.2, 1.3）。
GH_API_SNAPSHOT_ENABLED="${GH_API_SNAPSHOT_ENABLED:-false}"
case "$GH_API_SNAPSHOT_ENABLED" in
  true) : ;;
  *)    GH_API_SNAPSHOT_ENABLED="false" ;;
esac
# PR 超集合取得の --limit（非整数 / ≤0 は既定 100 へ正規化）。
GH_API_SNAPSHOT_PR_LIMIT="${GH_API_SNAPSHOT_PR_LIMIT:-100}"
case "$GH_API_SNAPSHOT_PR_LIMIT" in
  ''|*[!0-9]*) GH_API_SNAPSHOT_PR_LIMIT="100" ;;
  *) if [ "$GH_API_SNAPSHOT_PR_LIMIT" -le 0 ]; then GH_API_SNAPSHOT_PR_LIMIT="100"; fi ;;
esac
# Issue 超集合取得の --limit（非整数 / ≤0 は既定 100 へ正規化）。
GH_API_SNAPSHOT_ISSUE_LIMIT="${GH_API_SNAPSHOT_ISSUE_LIMIT:-100}"
case "$GH_API_SNAPSHOT_ISSUE_LIMIT" in
  ''|*[!0-9]*) GH_API_SNAPSHOT_ISSUE_LIMIT="100" ;;
  *) if [ "$GH_API_SNAPSHOT_ISSUE_LIMIT" -le 0 ]; then GH_API_SNAPSHOT_ISSUE_LIMIT="100"; fi ;;
esac
# スナップショット JSON ファイル（prs.json / issues.json）の配置先。$HOME/.issue-watcher/
# 配下（user-owned・単一 writer・flock 保護）で symlink TOCTOU を回避（CLAUDE.md §6）。
GH_API_SNAPSHOT_DIR="${GH_API_SNAPSHOT_DIR:-$HOME/.issue-watcher/api-snapshot/$REPO_SLUG}"
# 超集合取得の gh timeout 秒（非整数 / ≤0 は既定 60 へ正規化）。
GH_API_SNAPSHOT_GH_TIMEOUT="${GH_API_SNAPSHOT_GH_TIMEOUT:-60}"
case "$GH_API_SNAPSHOT_GH_TIMEOUT" in
  ''|*[!0-9]*) GH_API_SNAPSHOT_GH_TIMEOUT="60" ;;
  *) if [ "$GH_API_SNAPSHOT_GH_TIMEOUT" -le 0 ]; then GH_API_SNAPSHOT_GH_TIMEOUT="60"; fi ;;
esac
# Req 3: バケット別 rate limit の可視化（cycle 終端 1 行ログ）。`=true` 厳密一致のみ ON。
GH_API_BUCKET_LOG_ENABLED="${GH_API_BUCKET_LOG_ENABLED:-false}"
case "$GH_API_BUCKET_LOG_ENABLED" in
  true) : ;;
  *)    GH_API_BUCKET_LOG_ENABLED="false" ;;
esac
# Req 4: 残量閾値割れ時の WARN と非必須プロセッサ縮退。`=true` 厳密一致のみ ON。
GH_API_DEGRADE_ENABLED="${GH_API_DEGRADE_ENABLED:-false}"
case "$GH_API_DEGRADE_ENABLED" in
  true) : ;;
  *)    GH_API_DEGRADE_ENABLED="false" ;;
esac
# graphql バケット残量の縮退閾値（保守的既定 500 / 必須処理を完遂できる余力を残す）。
# 非整数 / <0 は既定 500 へ正規化（0 は許容 = 実質縮退無効化したい運用向け / Req 4.4）。
GH_API_DEGRADE_GRAPHQL_THRESHOLD="${GH_API_DEGRADE_GRAPHQL_THRESHOLD:-500}"
case "$GH_API_DEGRADE_GRAPHQL_THRESHOLD" in
  ''|*[!0-9]*) GH_API_DEGRADE_GRAPHQL_THRESHOLD="500" ;;
esac
# Req 5: 状態遷移系ラベル操作の限定リトライ。`=true` 厳密一致のみ ON。
GH_API_STATE_RETRY_ENABLED="${GH_API_STATE_RETRY_ENABLED:-false}"
case "$GH_API_STATE_RETRY_ENABLED" in
  true) : ;;
  *)    GH_API_STATE_RETRY_ENABLED="false" ;;
esac
# 再試行回数上限（有限 / 安全側既定 3 / 非整数・≤0 は既定へ / NFR 2.3）。
GH_API_STATE_RETRY_MAX_ATTEMPTS="${GH_API_STATE_RETRY_MAX_ATTEMPTS:-3}"
case "$GH_API_STATE_RETRY_MAX_ATTEMPTS" in
  ''|*[!0-9]*) GH_API_STATE_RETRY_MAX_ATTEMPTS="3" ;;
  *) if [ "$GH_API_STATE_RETRY_MAX_ATTEMPTS" -le 0 ]; then GH_API_STATE_RETRY_MAX_ATTEMPTS="3"; fi ;;
esac
# 試行間 backoff 秒（既定 2 / 非整数・<0 は既定へ）。
GH_API_STATE_RETRY_SLEEP="${GH_API_STATE_RETRY_SLEEP:-2}"
case "$GH_API_STATE_RETRY_SLEEP" in
  ''|*[!0-9]*) GH_API_STATE_RETRY_SLEEP="2" ;;
esac
# Req 6: per-branch PR 存在確認を GraphQL search から REST（core バケット）へ逃がす負荷分散。
# `=true` 厳密一致のみ ON。
GH_API_REST_OFFLOAD_ENABLED="${GH_API_REST_OFFLOAD_ENABLED:-false}"
case "$GH_API_REST_OFFLOAD_ENABLED" in
  true) : ;;
  *)    GH_API_REST_OFFLOAD_ENABLED="false" ;;
esac

# ─── デフォルト有効化フラグの値正規化 (#112 Req 2.10 / #412 で本フラグを追加) ───
# 下記 10 種の env var はすべて「`=false` を明示した場合のみ無効、それ以外
# （未設定 / 空文字 / `0` / `False` / `Yes` / typo 等）はすべてデフォルト有効」
# として扱う。後続コードの `[ "$VAR" = "true" ]` / `[ "$VAR" != "true" ]` /
# jq の `$design_enabled == "true"` 等の比較を変更せず正規化で吸収するため、
# 値を厳密な "true" / "false" の 2 値に正規化する。
# #412: `PR_REVIEWER_ADJUDICATOR_ENABLED` を本ループに追加（既定 ON / `=false` で opt-out）。
# #432: `DESIGN_REVIEWER_ENABLED` を本ループに追加（既定 ON / `=false` で opt-out）。Config
#       ブロックの `case false) :;; *) true` で既に正規化済みだが、2 段正規化の整合のため列挙。
for _idd_flag in \
    MERGE_QUEUE_ENABLED \
    MERGE_QUEUE_RECHECK_ENABLED \
    PR_ITERATION_ENABLED \
    PR_ITERATION_DESIGN_ENABLED \
    DESIGN_REVIEW_RELEASE_ENABLED \
    STAGE_CHECKPOINT_ENABLED \
    QUOTA_AWARE_ENABLED \
    IMPL_RESUME_PRESERVE_COMMITS \
    IMPL_RESUME_PROGRESS_TRACKING \
    PR_REVIEWER_ADJUDICATOR_ENABLED \
    DESIGN_REVIEWER_ENABLED; do
  if [ "${!_idd_flag}" = "false" ]; then
    printf -v "$_idd_flag" '%s' "false"
  else
    printf -v "$_idd_flag" '%s' "true"
  fi
done
unset _idd_flag

# Triage プロンプトテンプレート
TRIAGE_TEMPLATE="${TRIAGE_TEMPLATE:-$HOME/bin/triage-prompt.tmpl}"
