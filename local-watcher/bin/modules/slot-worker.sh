#!/usr/bin/env bash
# slot-worker.sh — Phase C Slot Runner モジュール（family orchestrator）
#
# family: slot-worker / prefix: なし
#   #502 で本モジュールを責務単位の module family（2 ファイル）へ分割した。orchestrator
#   （本ファイル）と 1 つの sub-file が family を構成する（dispatcher_ / pclp_ / slot_ /
#   _resume_* / _slot_* 等が混在する非 prefix 統一系のため、単一の共有 prefix は持たない）。
#   分割マニフェスト（どの関数がどのファイルにあるか）:
#     - slot-worker.sh          … 本ファイル: Slot Runner 本体 + ロガー + slot 失敗処理（計 12）
#         dispatcher_log / dispatcher_warn / dispatcher_error : Dispatcher 共通ロガー
#         pclp_log / pclp_warn / pclp_error                   : pre-claim filter 共通ロガー
#         _parallel_validate_slots                            : PARALLEL_SLOTS 設定値検証
#         slot_log / slot_warn / slot_error                   : Slot Worker 共通ロガー
#         _slot_mark_failed                                   : slot 失敗時の claude-failed 遷移
#         _slot_run_issue                                     : Slot Runner 本体（モード別ディスパッチ / #467）
#     - slot-worker-resume.sh   … resume / slug 判定 / pre-claim / status publish（計 13）
#         check_existing_impl_pr / check_open_design_pr / _resume_normalize_flag /
#         _resume_detect_existing_branch / _resume_branch_init / _resume_push /
#         _resume_mark_nonff_failed / _normalize_slug / _slug_mismatch_escalate /
#         _stage_checkpoint_assert_slug_match / _stage_checkpoint_has_resumable_state /
#         _resume_branch_assert_slug_match / publish_claude_review_status
#
# 用途:
#   Phase C: Issue 入口並列化（worktree slot + dispatcher, #16）の Slot Runner 一式のうち、
#   中核 `_slot_run_issue` 本体（Triage 後の 1 Issue 実行: branch 準備 → design / impl 系の
#   モード別ディスパッチ → 結果処理を担う巨大単一関数 / #467 切り出し）と、Dispatcher /
#   pre-claim filter / Slot Worker の共通ロガー、slot 失敗処理（#466 切り出し）を持つ。
#   resume・slug 判定・pre-claim 判定・claude-review ステータス publish の各ヘルパーは
#   slot-worker-resume.sh 側（family 内 cross-file 呼び出しは遅延束縛で解決）。
#
#   `_slot_verify_design_pr_created` は #446 revert 済みのため本 module 移動時点で存在せず
#   対象外（grep で不在を確認済み）。
#
#   詳細: docs/specs/16-phase-c-worktree-slot-dispatcher/design.md
#
# 配置先:
#   $HOME/bin/modules/slot-worker.sh（install.sh が modules/*.sh を glob 配布するため、
#   family ファイル追加で installer 変更は不要）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $BASE_BRANCH / $PARALLEL_SLOTS / $SPEC_DIR_REL 等）は本体冒頭の
#     Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - `dispatcher_log` 等は本体最終盤の Dispatcher からも呼ばれる。loader が全 module を
#     main loop 実行前に source する現行構造のため、定義場所の移動による呼び出し順序への
#     影響はない。
#   - `_slot_run_issue` は Dispatcher からサブシェル `( _slot_run_issue ... ) &` で fork される。
#     親 shell で定義済みの関数はサブシェルへ継承されるため、family 分割（定義ファイルの分割）は
#     fork 挙動に影響しない（#502 確認事項）。
#   - `_slot_acquire` / `_slot_release`（per-slot flock fd 管理）は modules/core_utils.sh に
#     既存定義済み（本 module の移動対象外）。fd を open/close する関数の定義場所は bash の
#     実行 context に影響しないため、本移動による fd 継承の挙動変化はない（#466 確認事項）。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

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
  # run サマリ: 最終遷移を claude-failed として記録（Req 7.1, 7.2）。worktree / Hook / Triage
  # 失敗等の早期終端からも呼ばれるが、_slot_run_issue 冒頭で rs_init 済（task 2 配線）。変数
  # 代入のみで既存ラベル遷移 / exit code / 既存ログ行に影響しない（NFR 1.1, 1.2 / set -e 安全）。
  rs_set_result claude-failed
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

# ─── Slot Runner 本体: _slot_run_issue (Issue #16 / #467 で本体から移動) ───

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

  # ── per-run evidence サマリの初期化と終端 emit 配線（#239 / Req 1.1, 1.3, 1.5） ──
  # rs_init で per-slot 状態変数を既定値にし、Issue 番号を確定。EXIT trap は本サブシェル
  # スコープローカルであり、dispatcher トップレベルの INT/TERM trap とは別境界（trap は
  # サブシェルでリセットされる）。worktree-ensure 失敗等の早期 return / set -e 異常終了 /
  # 正常 return のいずれの終端でも 1 回だけ rs_emit が発火し run-summary 行を 1 行吐く。
  # fail-open（|| true）で emit 失敗がサブシェルの exit code を変えない（NFR 4.1）。
  rs_init
  rs_set_issue "$NUMBER"
  # #325: token usage の Issue 単位サマリも同じ EXIT trap に連結する（rs_emit の発火を
  # 妨げないよう各々 || true で fail-open。出力順は run-summary → token-usage）。
  trap 'rs_emit || true; tu_emit_issue_summary || true' EXIT

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

  # Issue #237: REPO_DIR を worktree へ上書きする「前」に、注入元となる元の
  # REPO_DIR（install.sh が `.claude/` を最新化したローカルクローン）を捕捉する。
  # _worktree_inject_claude はこの元 REPO_DIR の `.claude/` を worktree へコピーする。
  local SRC_REPO_DIR="$REPO_DIR"

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

  # ── gitignore 運用 repo 向け `.claude/` 注入（reset 完了後・hook / agent 起動前）──
  # Issue #237: worktree に `.claude/` が無い（= gitignore 運用 repo）場合のみ、
  # 元 REPO_DIR の `.claude/` を worktree へ注入して agent runtime を健全化する。
  # tracked 運用 repo は worktree に `.claude/` があるため NO-OP（既存挙動不変）。
  # fail-open のため _worktree_inject_claude は常に 0 を返し、注入失敗で
  # claude-failed へ遷移させない（Req 3.2, 3.3）。
  _worktree_inject_claude "$SRC_REPO_DIR" "$WT"

  # ── Scaffolding Health preflight gate（#238 / reset+注入後・agent stage 前）──
  # worktree 内の `.claude/agents` / `.claude/rules` 非空到達性を検査し、欠落時は loud WARN ＋
  # Issue コメント可視シグナルを残す（Req 1）。既定（SCAFFOLDING_HEALTH_HALT=off）は可視化のみで
  # 進行を止めず（Req 2.1）、`on` opt-in かつ missing のときだけ gate が非 0 を返す（Req 2.2）。
  # indeterminate（検査の I/O 異常）は fail-open で常に継続（gate が 0 / Req 3）。
  if ! sh_preflight_gate "$WT"; then
    # HALT opt-in かつ missing → agent stage を起動せず人間判断待ちへ遷移して当該 Issue を
    # 当該サイクル終了する。claude-failed は付けない（足場欠落は「失敗」ではなく「人間判断
    # 待ち」/ Req 2.2 / design Decision 3）。claim 系ラベル（claude-claimed / claude-picked-up）を
    # 除去して auto-dev へ戻し、dispatcher の in-flight 判定が誤らないようにする（次 tick の
    # 再 pickup は人間が足場を修復した後に full 判定で自然に進行する / `_slot_mark_failed` の
    # label 操作を参考にするが `claude-failed` は付けない / fail-open）。
    gh issue edit "$NUMBER" --repo "$REPO" \
      --remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED" >/dev/null 2>&1 || true
    slot_log "scaffolding-health: HALT により agent stage を起動せず人間判断待ち（claim 系ラベル除去 / Issue #${NUMBER}）"
    return 0
  fi

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
      # Issue #383 Req 1.2, 1.5: docs/specs/<N>-* は存在するが expected-slug と一致する
      # ものがないケースは、umbrella spec を sub-issue が共有する構成での fresh issue を
      # 誤 block しないため、resumable state が実在するときのみ slug guard を発火させる。
      # resumable state 不在（fresh issue）なら slug guard を skip して Stage A を新規実装
      # として継続する（SLUG は Issue タイトル由来の EXPECTED_SLUG を採用）。
      # 判定失敗（gh API エラー等）は NFR 2.1 の safe-side に倒して従来の発火経路を維持する。
      local _first="${SPEC_CANDIDATES[0]}"
      local _resumable_rc=0
      _stage_checkpoint_has_resumable_state "$_first" || _resumable_rc=$?
      case "$_resumable_rc" in
        1)
          # Req 1.2, 1.3, 1.4: resumable state 不在 → slug guard skip。`needs-decisions`
          # 付与なし / escalation コメント投稿なし / SLUG は Issue タイトル由来を採用。
          echo "stage-checkpoint: slug-guard-skipped issue=#${NUMBER:-?} expected=${EXPECTED_SLUG} found=$(basename "$_first" | sed "s/^${NUMBER}-//") reason=no-resumable-state" | tee -a "$LOG"
          SLUG="$EXPECTED_SLUG"
          ;;
        *)
          # Req 2.1, 2.3 / NFR 2.1: resumable state 実在（0）/ 判定失敗の safe-side（2）/
          # 想定外 rc は全て従来どおり slug guard を発火させる方に倒す（safe-side default）。
          if ! _stage_checkpoint_assert_slug_match "$EXPECTED_SLUG" "$_first"; then
            return 1
          fi
          # 防御: _stage_checkpoint_assert_slug_match が 0 を返した（一致した）場合の
          # フォールバック（実装上は到達しないが silent fail を作らないため）
          HAS_EXISTING_SPEC=true
          EXISTING_SPEC_DIR="$_first"
          SLUG=$(basename "$EXISTING_SPEC_DIR" | sed "s/^${NUMBER}-//")
          ;;
      esac
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
    rs_set_mode impl-resume
  elif echo "$LABELS" | grep -qx "$LABEL_SKIP_TRIAGE"; then
    echo "skip-triage ラベルがあるため Triage をスキップ → impl モード" | tee -a "$LOG"
    ARCHITECT_REASON="Triage をスキップ（軽微な変更扱い）"
    MODE="impl"
    rs_set_mode impl
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

    # sed 置換文字列で特別扱いされる文字を網羅エスケープする（未信頼の Issue タイトル由来）。
    # `\`（エスケープ導入）→ `&`（被マッチ展開）→ 区切り `|` の順で処理する
    # （`\` を先に処理しないと後続で挿入した `\&` / `\|` が二重エスケープされる）。
    # 末尾が `\` のタイトルで sed 式が malformed 化する事故、および `&` による
    # `{{TITLE}}` 逐語混入を防ぐ。
    local TITLE_SAFE="$TITLE"
    TITLE_SAFE="${TITLE_SAFE//\\/\\\\}"
    TITLE_SAFE="${TITLE_SAFE//&/\\&}"
    TITLE_SAFE="${TITLE_SAFE//|/\\|}"
    local TRIAGE_PROMPT
    TRIAGE_PROMPT=$(sed \
      -e "s|{{NUMBER}}|${NUMBER}|g" \
      -e "s|{{TITLE}}|${TITLE_SAFE}|g" \
      -e "s|{{URL}}|${URL}|g" \
      -e "s|{{FILE}}|${TRIAGE_FILE}|g" \
      "$TRIAGE_TEMPLATE")

    echo "--- Triage 実行 ---" >> "$LOG"
    # #332: TRIAGE_BARE=true（厳密一致）のとき --bare を付与し、CLAUDE.md / rules 等の
    # 自動ロードを排除する（Triage の判定基準は template 内で自己完結）。guard hook
    # （IDD_CLAUDE_HOOKS_ENABLED）opt-in 時は --settings 経由の hook 注入を --bare が
    # 無効化しうるため、安全側に倒して --bare を見送り WARN を残す（両立不可の明示）。
    # 空配列展開 "${arr[@]}" は bash 4.4+ で set -u 安全（guard-hook.sh の先例と同様）。
    local _triage_bare_args=()
    if [ "${TRIAGE_BARE:-false}" = "true" ]; then
      if declare -F gh_is_enabled >/dev/null 2>&1 && gh_is_enabled; then
        echo "[$(date '+%F %T')] [$REPO] triage: WARN: TRIAGE_BARE=true は IDD_CLAUDE_HOOKS_ENABLED（guard hook）と併用できないため --bare を見送ります（guard hook を優先）" >> "$LOG"
      else
        _triage_bare_args=(--bare)
      fi
    fi
    # Issue #66: Quota-Aware Watcher 経由で claude を起動。opt-out 時は素通し
    # （既存挙動互換）、opt-in 時は rate_limit_event 検知で exit 99 を返す。
    local _qa_reset_file_triage="/tmp/qa-reset-${REPO_SLUG}-${NUMBER}-triage-${TS}"
    local _qa_rc_triage=0
    qa_run_claude_stage "Triage" "$_qa_reset_file_triage" -- \
      claude \
        "${_triage_bare_args[@]}" \
        --print "$TRIAGE_PROMPT" \
        --model "$TRIAGE_MODEL" \
        --permission-mode bypassPermissions \
        --max-turns "$TRIAGE_MAX_TURNS" \
        "${CLAUDE_HOOK_ARGS[@]}" \
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

    # ── Model Routing Phase 1: size ラベル永続化 (#507 Req 4.1〜4.7 / 5.1〜5.6) ──
    # MODEL_ROUTING_ENABLED=true のときのみ、Triage が返した complexity を
    # `size:<complexity>` ラベルとして Issue に永続化し、Triage を再実行しない
    # サイクル（impl-resume / PR Iteration / Failed Recovery）でも参照できるようにする。
    # gate 無効時は本ブロック全体が no-op（ログ 0 行 / gh 0 回 / Req 3.4 / NFR 1.1）。
    #
    # 本ブロックは $STATUS / $NEEDS_ARCHITECT / $MODE を読み書きしないため、mode 判定と
    # needs-decisions 経路は構造的に不変（Req 2.5）。mr_persist_size_label の戻り値は
    # 吸収して後続へ伝播させず、Triage の成功／失敗判定を変えない（Req 2.4 / 5.3 fail-open。
    # rc ごとのログは関数側で完結して出力される）。
    #
    # 配置は Phase E ブロックの直後・`needs-decisions` 分岐より前とし、needs-decisions で
    # 早期 return する Issue にもラベルが残るようにする。`skip-triage` / `impl-resume`
    # 経路は Triage ブロックごと迂回されるため、追加のラベル判定を書かずに非付与が
    # 構造的に保証される（Req 4.5 / 4.6）。
    if mr_is_enabled; then
      local _mr_complexity
      _mr_complexity=$(mr_parse_triage_complexity "$TRIAGE_FILE")
      mr_persist_size_label "$NUMBER" "$_mr_complexity" || true
    fi

    if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then
      # ── Issue #362: needs-decisions 自動続行（D-08 / D-09） ──
      # AND 二重 opt-in（FULL_AUTO_ENABLED=true AND NEEDS_DECISIONS_MODE in (classified, all-auto)）
      # 配下で、Triage が `safe` 分類した decisions について PM 第一推奨で自動続行する。
      # rc=0 = auto-continue 実行済 → 既存 COMMENT 組み立て + gh issue comment + ラベル付け替え
      # （needs-decisions 付与）+ return 0 を **すべて skip** して即 return 0（Issue は
      # `needs-decisions` 不付与 + `claude-claimed` 除去済 → 次サイクルで dispatcher 再 pickup）。
      # rc=1 = halt → 既存処理（needs-decisions 付与 + コメント投稿）にそのまま流す
      # （本機能導入前と完全等価 / NFR 1.1, 1.3）。
      if nda_evaluate_auto_continue "$TRIAGE_FILE"; then
        slot_log "Triage 結果: needs-decisions → auto-continue（#362, claude-claimed 除去済・次サイクル再 pickup 待機）"
        return 0
      fi
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
      rs_set_mode design
      echo "🎨 #$NUMBER: Architect 必要 → design モード（理由: $ARCHITECT_REASON）" | tee -a "$LOG"
    else
      MODE="impl"
      rs_set_mode impl
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
    # Issue #390: impl 着手（claude-pickup）を Slack に 1 通通知（gate / URL preflight /
    # fail-open はすべて sn_notify 内に閉じている。`|| true` は既存 5 イベント callsite と
    # 同形の fail-open 防御）。
    sn_notify claude-pickup "$NUMBER" "https://github.com/$REPO/issues/$NUMBER" success "mode=${MODE} slot=${IDD_SLOT_NUMBER}" || true
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
        "${CLAUDE_HOOK_ARGS[@]}" \
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
    # impl / impl-resume → Reviewer ゲートを含む stage 分割パイプラインへ。
    # run_impl_pipeline の戻り値契約:
    #   0 = 完了 / 良性停止（quota → needs-quota-wait / partial / Stage Checkpoint TERMINAL_OK）
    #   3 = 再 pickup 可能な保留（stage-a-verify round=1 差し戻し / Issue #219）。
    #       claude-failed は未付与で claude-picked-up も除去済み → 次 tick で再評価される。
    #   その他非 0 = 失敗。各 stage 内で `mark_issue_failed` 発火済み（claude-failed 付与済み）。
    local _impl_rc=0
    run_impl_pipeline || _impl_rc=$?
    case "$_impl_rc" in
      0)
        echo "✅ #$NUMBER: $MODE 完了（Reviewer ゲート通過 / PR 作成済み）" | tee -a "$LOG"
        slot_log "$MODE 完了（PR 作成済み）"
        return 0
        ;;
      3)
        # stage-a-verify round=1 差し戻し。claude-failed は付与されておらず、
        # 虚偽の「claude-failed 付与済み」を出さない（Issue #219 fix）。
        echo "⏸️ #$NUMBER: $MODE 保留（stage-a-verify 差し戻し / claude-failed 未付与 / 次 tick で再評価）" | tee -a "$LOG"
        slot_log "$MODE 保留（stage-a-verify 差し戻し / 次 tick 再評価）"
        return 0
        ;;
      *)
        echo "❌ #$NUMBER: $MODE 失敗（claude-failed 付与済み）" | tee -a "$LOG"
        slot_log "$MODE 失敗（claude-failed 付与済み）"
        return 1
        ;;
    esac
  fi
}
