#!/usr/bin/env bash
# core_utils.sh — watcher の低レベル共通ユーティリティモジュール
#
# 用途:
#   issue-watcher.sh から切り出した低レベル共通ユーティリティを集約する。
#   - processor 系の低レベルロガー（qa_log / mq_log / ar_log / pp_log / pi_log / drr_log 系）
#   - 日付フォーマット取得（qa_format_iso8601）
#   - per-slot git worktree 管理（_worktree_path / _worktree_is_registered /
#     _worktree_ensure / _worktree_reset / _worktree_inject_claude）
#   - per-slot 非ブロッキング flock 管理（_slot_lock_path / _slot_acquire / _slot_release）
#   - SLOT_INIT_HOOK 起動 wrapper（_hook_invoke）
#
# 配置先:
#   $HOME/bin/modules/core_utils.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $BASE_BRANCH / $WORKTREE_BASE_DIR / $REPO_SLUG /
#     $SLOT_LOCK_DIR / $PARALLEL_SLOTS / $SLOT_INIT_HOOK）は本体冒頭で定義済み。
#   - worktree / slot ユーティリティ内の dispatcher_log / dispatcher_warn は本体に残る関数への
#     前方参照（bash の遅延評価により呼び出し時＝source 完了後に解決される）。
#   - 外部 CLI: date / git / flock / mktemp / tail。
#
# セットアップ参照先:
#   README.md（ディレクトリ構成・modules 化 migration note） / install.sh（配置ロジック）

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

# pr-reviewer 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #261 Req NFR 3.1: 時刻 prefix と processor prefix の間に `[$REPO]` を挿入。
pr_log() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: $*"
}
pr_warn() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: WARN: $*" >&2
}
pr_error() {
  echo "[$(date '+%F %T')] [$REPO] pr-reviewer: ERROR: $*" >&2
}

# security-review 専用ロガー（識別用 prefix と timestamp 形式を Issue Watcher と揃える）
# Issue #279: 既存 `pr_log` / `mq_log` と同形式の `[YYYY-MM-DD HH:MM:SS] [$REPO] security-review:`
# prefix を用いる。`sec_warn` / `sec_error` は `>&2` に出力。
sec_log() {
  echo "[$(date '+%F %T')] [$REPO] security-review: $*"
}
sec_warn() {
  echo "[$(date '+%F %T')] [$REPO] security-review: WARN: $*" >&2
}
sec_error() {
  echo "[$(date '+%F %T')] [$REPO] security-review: ERROR: $*" >&2
}

# ─── Issue #259: Claude API 529 Overloaded detector ───
#
# Claude API の一時的な過負荷 (HTTP 529 Overloaded) は claude CLI の stream-json
# 出力に Anthropic API のエラー JSON 断片として現れる。代表的なシグネチャ:
#   - `"api_error_status":529`
#   - `"error_status":529`
#   - `"status":529`（HTTP 5xx の直書き）
#   - `"type":"overloaded_error"`
#   - `"Overloaded"`（人間可読 message）
#
# 設計判断:
#   - false-positive を避けるため、`529` 単独の数値検出はせず、必ず `status[:.]?\s*529`
#     形式（JSON key の隣接）に限定する。
#   - `Overloaded` は anthropic API 文言と被るため、case-insensitive ではなく
#     大文字 O 始まりの単語境界一致で検出する。
#   - ファイル不在 / 読み取り不能 / 空ファイルは検出なし扱い（後段の警告コメント
#     投稿を抑止して既存挙動を妨げない / Req 1.5 / 2.4 / 4.4）。
#   - 副作用なし（純粋な検査関数）。失敗系含めて呼び出し元の既存処理を継続させる
#     ため、grep が失敗してもエラー伝播させない。
#
# 引数: $1 = 検査対象のログファイルパス
# 戻り値:
#   0 = 529 痕跡を検知（呼び出し元で警告メッセージを付加する）
#   1 = 検知なし（既存メッセージのみ）
#   2 = ファイル不在 / 読み取り不能（検知なし相当として扱うが grep スキップ。
#       呼び出し元はログ可観測性のため 1 と区別したい場合に参照可能）
# 出力: stdout には何も書かない。
#
# Requirements: 1.1, 1.5, 2.1, 2.4, 3.1, 3.2, 4.4, NFR 1.1
claude_log_detect_529() {
  local log_path="${1:-}"
  if [ -z "$log_path" ]; then
    return 2
  fi
  if [ ! -f "$log_path" ] || [ ! -r "$log_path" ]; then
    return 2
  fi
  # 検出パターン群:
  #   - `"api_error_status":529` / `"error_status":529` / `"status":529`
  #     （JSON key の直後 colon ＋ optional whitespace ＋ 529。`status: 529` の plain
  #     text 表記もカバーする）
  #   - `"type":"overloaded_error"` （Anthropic API の標準 error type 文字列）
  #   - 単独の "Overloaded" 単語境界（HTTP 529 の reason phrase）
  # grep 自体は終了コード 1（一致なし）で問題ないため `|| true` で吸収し、
  # set -euo pipefail 配下でも安全に動作するようにする。
  if grep -qE '"(api_error_status|error_status|status)"\s*:\s*529' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bstatus\s*:\s*529\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '"type"\s*:\s*"overloaded_error"' "$log_path" 2>/dev/null; then
    return 0
  fi
  if grep -qE '\bOverloaded\b' "$log_path" 2>/dev/null; then
    return 0
  fi
  return 1
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
  # NOTE (Issue #167): ここで以前行っていた per-slot の
  #   `git -C "$wt" fetch origin --prune`
  # は削除した。複数 slot worktree は同一 $REPO_DIR の .git オブジェクト DB / refs を
  # 共有するため、PARALLEL_SLOTS>1 で複数 slot がほぼ同時に fetch すると
  # refs/remotes/origin/<branch>.lock / packed-refs.lock の取得競争が起き、
  # 競合に負けた側の fetch が非 0 終了する。set -euo pipefail 下では本関数が失敗扱いと
  # なり、無実の Issue に偽陽性の claude-failed ラベルとエラーコメントが付いていた。
  # origin 参照の最新化は親プロセスがサイクル冒頭（本ファイル冒頭付近の
  # `cd "$REPO_DIR"; git fetch origin --prune`）で 1 回だけ実行済みであり、slot worktree は
  # その origin/$BASE_BRANCH 参照を共有して読むため、per-slot fetch なしでも reset 起点は
  # 確保できる（親 fetch から slot 起動までの遅延による ref stale は許容範囲）。
  # 1. detached HEAD を origin/$BASE_BRANCH に強制移動
  if ! git -C "$wt" reset --hard "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
    return 1
  fi
  # 2. untracked + ignored を消去（前回 Issue の build artifact / node_modules を残さない）
  if ! git -C "$wt" clean -fdx >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# gitignore 運用 repo 向けに、worktree reset 直後の slot worktree へ
# REPO_DIR のローカル `.claude/` を注入する（Issue #237）。
#
# 背景:
#   `.claude/` を gitignore して足場を public repo に出さない運用 repo では、
#   `.claude/` が commit されないため _worktree_reset の `git reset --hard` +
#   `git clean -fdx` 後の worktree に `.claude/agents` `.claude/rules` が現れず、
#   agent がルール・定義を読めない degraded 状態になる。本関数は reset 完了後・
#   agent 起動前のタイミングで REPO_DIR（install.sh が `.claude/` を最新化した
#   ローカルクローン）から worktree へ `.claude/` をコピーして健全化する。
#
# 採用方式: auto-detect（worktree に `.claude/` が無い場合のみ注入）。
#   - tracked 運用 repo は `.claude/` が commit 済み → reset 後 worktree に必ず
#     存在 → 注入は走らず NO-OP（Req 2.1 / 2.3）。env gate を持たないが、
#     auto-detect により tracked 運用 repo の挙動は外形的に不変（Req 2.4）。
#   - これはローカルファイルコピーであり外部サービス呼び出しではないため、
#     opt-in gate は不要（CLAUDE.md「opt-in gate なしで新しい外部サービス
#     呼び出しを有効化」禁止事項の対象外）。
#
# 引数:
#   $1 = 注入元 REPO_DIR（_slot_run_issue で REPO_DIR が worktree へ上書きされる
#        前に捕捉した元の REPO_DIR）
#   $2 = 注入先 worktree 絶対パス
# 戻り値: 常に 0（fail-open。注入失敗で _slot_run_issue を倒さない / Req 3.2, 3.3）
# 副作用: 条件成立時に $2/.claude を $1/.claude の内容で作成する（commit はしない）
#
# worktree の最終 scaffolding 状態を run サマリへ記録する薄いヘルパ（Issue #239）。
#
# `_worktree_inject_claude` の各 return パス直前で呼び、worktree に
# `.claude/agents` `.claude/rules` の両 dir が実体として揃っているかを判定して
# `rs_set_scaffolding ok|missing` を記録する。注入元 `.claude/` 不在 / cp 失敗の
# rm 後はどちらも両 dir 不在 → missing、tracked 運用 / cp 成功は実体を見て判定する。
#
# 引数:
#   $1 = 判定対象 worktree 絶対パス
# 戻り値: 常に 0（fail-open。記録失敗で _worktree_inject_claude / _slot_run_issue を
#         倒さない / NFR 4.1）
# 副作用: rs_set_scaffolding による run サマリ用状態変数代入のみ（標準出力に何も足さない）
#
# Req 5.1, 5.2, 5.3, NFR 1.2, NFR 4.1
_worktree_record_scaffolding() {
  local wt="$1"
  # run-summary.sh 未 source の文脈でも注入処理を倒さない fail-open ガード（NFR 4.1）。
  command -v rs_set_scaffolding >/dev/null 2>&1 || return 0
  if [ -d "$wt/.claude/agents" ] && [ -d "$wt/.claude/rules" ]; then
    rs_set_scaffolding ok || true
  else
    rs_set_scaffolding missing || true
  fi
  return 0
}

# Req 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 3.1, 3.2, 3.3, 4.1, 4.2, 4.3, 4.4, NFR 3.1
_worktree_inject_claude() {
  local src_repo_dir="$1"
  local wt="$2"

  # NO-OP 条件 1（Req 2.1）: worktree に既に `.claude/` がある = tracked 運用 repo。
  # 上書きせず即 return（auto-detect による既存挙動非変更 / 冪等性 Req 4.1 も担保）。
  if [ -e "$wt/.claude" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi
  # NO-OP 条件 2（Req 2.2）: 注入元 REPO_DIR に `.claude/` が無い → 何もしない。
  if [ ! -d "$src_repo_dir/.claude" ]; then
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # `.claude/` のみをコピーする（Req 4.2 / 4.4: 他 tracked / untracked ファイルや
  # `.github/scripts/idd-claude-labels.sh` を巻き込まない）。
  # `cp -a` で mode / timestamps / symlink を保持（Req 4 / rsync は依存 CLI 保証外）。
  if cp -a "$src_repo_dir/.claude" "$wt/" 2>/dev/null; then
    slot_log ".claude を REPO_DIR から worktree へ注入 (src=$src_repo_dir/.claude)"
    _worktree_record_scaffolding "$wt"
    return 0
  fi

  # fail-open（Req 3.1, 3.2, 3.3）: コピー失敗時は warn のみ出して継続する。
  # 中途半端にコピーされた `.claude/` が残ると次回 auto-detect が NO-OP 化して
  # 不完全状態を温存しうるため、ベストエフォートで除去してから継続する。
  rm -rf "$wt/.claude" 2>/dev/null || true
  slot_warn ".claude の注入に失敗しました（継続します / src=$src_repo_dir/.claude）"
  _worktree_record_scaffolding "$wt"
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
  #
  # Issue #170 Req 1.2: stderr 捕捉は同期リダイレクト `2>"$stderr_tmp"` で行う。
  # 旧実装の非同期プロセス置換 `2> >(tee -a "$stderr_tmp" >&2)` は、フック終了直後の
  # `tail -c 2000` 読み出しと tee の flush の間にレースを生じ、失敗ログ末尾が欠落
  # しうる。同期リダイレクトでフック終了時に一時ファイルが確定したのち、Req 1.4 を
  # 満たすため `cat "$stderr_tmp" >&2` で stderr を従来どおり運用者へ流す。
  if [ -n "$stderr_tmp" ]; then
    IDD_SLOT_NUMBER="$n" \
      IDD_SLOT_WORKTREE="$wt" \
      PARALLEL_SLOTS="$PARALLEL_SLOTS" \
      REPO="$REPO" \
      REPO_DIR="$REPO_DIR" \
      "$SLOT_INIT_HOOK" 2>"$stderr_tmp" || rc=$?
    # フック終了後（一時ファイル確定後）に同期で stderr へ転記する。
    # `set -euo pipefail` 下で cat 失敗が誤って _hook_invoke を致命化しないよう
    # `|| true` でガードする（Req 1.4: stderr 観測性維持 / NFR 3.1）。
    if [ -s "$stderr_tmp" ]; then
      cat "$stderr_tmp" >&2 || true
    fi
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
