# Implementation Plan

- [x] 1. Config ブロックと logger を追加（gate / env 正規化 / 観測点）
  - `issue-watcher.sh` の Failed Recovery Config ブロック直後（行 609 付近）に
    Stale Pickup Reaper 設定節を新規追加し、以下 5 env を宣言:
    - `STALE_PICKUP_REAPER_ENABLED`（既定 `false`、`true` 厳密一致のみ ON、それ以外は
      `case` で `false` に正規化）
    - `STALE_PICKUP_REAPER_THRESHOLD_MINUTES`（既定 45、`*[!0-9]*` / `0 以下` を 45 に正規化）
    - `STALE_PICKUP_REAPER_STATE_DIR`（既定 `$HOME/.issue-watcher/stale-pickup/$REPO_SLUG`）
    - `STALE_PICKUP_REAPER_MAX_ISSUES`（既定 20、不正値で 20）
    - `STALE_PICKUP_REAPER_GH_TIMEOUT`（既定 60、不正値で 60）
  - 「デフォルト有効化フラグの値正規化」ループ（行 916 付近）には **含めない**
    （新規 opt-in / 既定 false のため。failed-recovery と同方針）
  - `core_utils.sh` の `fr_log` / `fr_warn` / `fr_error` 直後（行 159 付近）に
    `sr_log` / `sr_warn` / `sr_error` を追加し、prefix `stale-pickup` で
    `[YYYY-MM-DD HH:MM:SS] [$REPO] stale-pickup: ...` 形式を踏襲
  - 同タスク内テスト: `stale_pickup_reaper_test.sh` の Section 1（`sr_is_enabled` の
    二重 opt-in 判定）+ Section 0（Config 正規化の inline 検証 = `fr_state_test.sh`
    Section 11 と同パターン）を **同 task 内**で追加し、`true` / `false` / 未設定 /
    `True` / `1` / `on` / typo の 7 ケースについて return code と正規化値を assert
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 4.1, 4.3, 4.4, NFR 1.1, NFR 1.3_
  - _Boundary: stale-pickup-reaper.sh (Config + Gate), core_utils.sh (Logger)_

- [x] 2. 永続化レイヤ（marker JSON state）を実装
  - `local-watcher/bin/modules/stale-pickup-reaper.sh` を新規作成し、ファイル冒頭
    コメントで「用途 / 配置先 / 依存 / セットアップ参照先」を `failed-recovery.sh`
    と同パターンで明記
  - 関数 prefix `sr_` を namespace として宣言し、`set -euo pipefail` は本体側で
    宣言済みのため module 内では宣言しない
  - 以下 3 関数を実装:
    - `sr_marker_path "<issue>"` — stdout: `$STALE_PICKUP_REAPER_STATE_DIR/<issue>.json`
    - `sr_load_marker "<issue>"` — ファイル不在 / `jq -e` parse 失敗で `{}` を返す
      fail-open
    - `sr_save_marker "<issue>" "<first_seen_at>" "<last_seen_at>" "<labels_json>"
      "<status>" "<revert_at>"` — `mkdir -p` → mktemp → `mv -f` の atomic write、
      `jq --arg` / `--argjson` で全値 sanitize、失敗時は `sr_warn` + return 1
  - JSON schema は design.md「Marker State Model」節に準拠
  - 同タスク内テスト: `stale_pickup_reaper_test.sh` の Section 2（path 算出）/
    Section 3（save → load 往復で全 field）/ Section 4（atomic rename / 中間 tmp file
    残らない）/ Section 5（破損 JSON で fail-open）/ Section 6（jq 特殊文字 sanitize）
    を **同 task 内**で追加（`fr_state_test.sh` の同型 Section を base に書き起こす）
  - _Requirements: 5.5, NFR 2.2, NFR 2.3, NFR 3.1_
  - _Boundary: stale-pickup-reaper.sh (Persistence Layer)_
  - _Depends: 1_

- [x] 3. 候補選定レイヤ（gh API filter）を実装
  - `sr_fetch_candidates` を実装:
    - `gh issue list --search "label:\"$LABEL_PICKED\" -label:\"$LABEL_FAILED\"
      -label:\"$LABEL_NEEDS_DECISIONS\" -label:\"$LABEL_AWAITING_DESIGN\"
      -label:\"$LABEL_NEEDS_QUOTA_WAIT\" -label:\"$LABEL_BLOCKED\"
      -label:\"$LABEL_STAGED_FOR_RELEASE\" -label:\"hold\""` で claude-picked-up
      候補を取得
    - `gh issue list --search "label:\"$LABEL_CLAIMED\" -label:..."` で
      claude-claimed 候補を取得（除外条件は同じ）
    - 2 結果を `jq` で結合 + `unique_by(.number)` で dedup、
      `--limit "$STALE_PICKUP_REAPER_MAX_ISSUES"` で truncate
    - `timeout "$STALE_PICKUP_REAPER_GH_TIMEOUT"` で外部呼び出し保護
    - 取得失敗 / 非 JSON / 空文字は `[]` で fail-continue + `sr_warn` 1 行
  - 既存 `LABEL_*` 定数（`LABEL_PICKED` / `LABEL_CLAIMED` / `LABEL_FAILED` /
    `LABEL_NEEDS_DECISIONS` / `LABEL_AWAITING_DESIGN` / `LABEL_NEEDS_QUOTA_WAIT` /
    `LABEL_BLOCKED` / `LABEL_STAGED_FOR_RELEASE`）を参照する。新規ラベル定数は追加しない
  - 同タスク内テスト: `gh` を stub 関数として差し替え、search 文字列に必要な
    `label:"..."` / `-label:"..."` トークンが含まれていることを grep で assert。
    また、gh 失敗時に `[]` が返ること（fail-continue）を assert
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, NFR 1.2, NFR 3.1, NFR 5.2_
  - _Boundary: stale-pickup-reaper.sh (Candidate Selection Layer)_
  - _Depends: 2_

- [x] 4. アクティブ判定レイヤ（3 観点 AND）を実装
  - 以下 4 関数を実装:
    - `sr_check_marker_age "<marker_json>"` — `first_seen_at` を `date -d` (Linux) /
      `date -j -f` (macOS 互換) で epoch 化し、現在時刻との差を分換算で閾値判定。
      first_seen_at 不在 / date parse 失敗は「閾値未満」（return 1）として安全側
    - `sr_check_slot_lock "<marker_json>"` — `$SLOT_LOCK_DIR/${REPO_SLUG}-slot-*.lock`
      に対して `flock -n -x <lockfile> true` を試行。1 つでも取得失敗 = ロック保持
      slot 存在（return 1）。lock file 不在は return 0。`flock` 失敗（権限等）は
      return 2 として「保持の可能性あり」（Req 3.4）
    - `sr_check_session "<marker_json>"` — Linux `fuser` / macOS `lsof` で lock 保持
      pid を取得し `kill -0` で生存確認。pid 取得不能 / fuser & lsof 不在は return 1
      （安全側）
    - `sr_is_active "<marker_json>"` — 3 観点を AND 結合。**全観点が「非アクティブ
      寄り（rc=0）」のときのみ return 1（= 非アクティブ確定）**。それ以外は return 0
      （= active or unknown = revert しない）。判定根拠を `sr_log` で 1 行記録
      （`age=$age lock=$lock sess=$sess` 形式）
  - 全関数は読み取り専用、副作用なし（Req 3.3）。`gh` を呼ばない
  - 同タスク内テスト:
    - `sr_check_marker_age`: 閾値未満 / 閾値超 / first_seen_at 不在 / date parse
      失敗の 4 経路を fixture marker JSON で assert
    - `sr_check_slot_lock`: `mktemp` で一時 lock file を作り、別 fd で `flock` を
      握って sr_check_slot_lock の戻り値を assert。lock file 不在ケースも assert
    - `sr_check_session`: `kill -0` 用に存在 pid（自プロセス `$$`）と不在 pid
      （`99999` 等大値）で挙動を assert
    - `sr_is_active`: 3 観点関数を stub 化し、2^3=8 通りの組み合わせで return を
      assert（全 0 のときだけ return 1、他は return 0）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 4.2, 6.3, NFR 4.1, NFR 4.2_
  - _Boundary: stale-pickup-reaper.sh (Active Decision Layer)_
  - _Depends: 2_

- [ ] 5. 復旧アクションレイヤと orchestrator を実装
  - `sr_revert_to_auto_dev "<issue>" "<marker_json>"` を実装:
    - NFR 3.1: `issue` は `^[0-9]+$` で検証
    - `gh issue edit "$issue" --repo "$REPO" -- --remove-label "$LABEL_PICKED"
      --remove-label "$LABEL_CLAIMED"` を 1 PATCH で発行（既存 round=1 defer と同型）
    - rc=0 のあと `gh issue view --json labels` で再取得し `auto-dev` 不在のときのみ
      `--add-label "$LABEL_TRIGGER"` を 2 回目の PATCH で付与
    - `SR_PROCESSED_THIS_CYCLE` in-memory set に `"<issue>"` を idempotent に append
    - 成功時 1 行ログ:
      `sr_log "issue=#$issue reverted reason=stale-pickup orphan age=<分>m prev_labels=<csv>"`
    - gh 失敗時は `sr_warn` + return 1（marker は observing のまま温存し次サイクル
      再評価 / Req 5.6）
  - `process_stale_pickup_reaper` orchestrator を実装:
    - 二段ガード: `sr_is_enabled` で gate OFF なら即 return 0 / `SR_PROCESSED_THIS_CYCLE`
      で同サイクル重複起動防止
    - メインループ: `sr_fetch_candidates` → 各 Issue について `sr_load_marker` →
      first_seen_at / last_seen_at 更新 → `sr_save_marker(status=observing)` →
      `sr_is_active` 判定 → 非アクティブ確定なら `sr_revert_to_auto_dev` → 成功時
      `sr_save_marker(status=reverted, revert_at=now)`
    - 全例外は `sr_warn` + continue（fail-continue）
    - 戻り値は常に 0（watcher サイクルを絶対に落とさない）
  - 同タスク内テスト:
    - `sr_revert_to_auto_dev`: `gh` stub で呼び出し引数を trace ファイルに記録し、
      `--remove-label claude-picked-up` / `--remove-label claude-claimed` / auto-dev
      欠落時の `--add-label auto-dev` / `^[0-9]+$` 不正値 reject / 同サイクル 2 回目
      呼び出しが no-op（in-memory set）を assert
    - `process_stale_pickup_reaper`:
      - `STALE_PICKUP_REAPER_ENABLED=false` で全ての `gh` stub が **1 回も呼ばれない**
        ことを assert（NFR 1.1 の構造的検証）
      - active 経路（lock 保持 stub あり）で revert が呼ばれないこと
      - inactive 経路（lock 解放 + marker_age 超過 stub）で revert が呼ばれること
  - _Requirements: 3.1, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 6.2, NFR 1.1, NFR 1.2, NFR 2.1, NFR 3.1, NFR 3.2, NFR 5.2_
  - _Boundary: stale-pickup-reaper.sh (Recovery Action + Orchestrator)_
  - _Depends: 3, 4_

- [ ] 6. 本体配線（REQUIRED_MODULES と call site）
  - `issue-watcher.sh` の `REQUIRED_MODULES` 配列（行 990）に
    `"stale-pickup-reaper.sh"` を `"failed-recovery.sh"` の直後に追加
  - call site を `process_failed_recovery || fr_warn ...` の直後（行 1528 付近）に
    1 行追記:
    ```
    process_stale_pickup_reaper || sr_warn "process_stale_pickup_reaper が想定外のエラーで終了しました（後続 Issue 処理は継続）"
    ```
  - 同タスク内テスト:
    - `bash -n local-watcher/bin/issue-watcher.sh` で構文 OK
    - `REQUIRED_MODULES` 順 source 後に `declare -F sr_is_enabled
      process_stale_pickup_reaper` が両方定義済みを assert（integration smoke）
    - `STALE_PICKUP_REAPER_ENABLED` 未設定で `process_stale_pickup_reaper` を直接
      呼び `gh` stub が 0 回呼ばれることを smoke 検証
  - _Requirements: 1.1, 1.4, NFR 1.1, NFR 1.2, NFR 1.3_
  - _Boundary: issue-watcher.sh (REQUIRED_MODULES + call site)_
  - _Depends: 5_

- [ ] 7. README / CLAUDE.md 反映と最終検証
  - `README.md`:
    - 「オプション機能（標準有効 / 常時有効）一覧」表に `STALE_PICKUP_REAPER_ENABLED`
      行を追加（既定 OFF / opt-in / 二重 opt-in 不要を明記）
    - `## Failed Recovery Processor (#359)` の直後に新節
      `## Stale Pickup Reaper (#379)` を追加し、用途・既定 OFF・有効化方法
      （cron 行に `STALE_PICKUP_REAPER_ENABLED=true` 追加）・閾値 env・後方互換の
      ポリシーを記述
    - 関連 env table（`STALE_PICKUP_REAPER_*` 5 種）と「failed-recovery との領分差分」
      （claude-failed は #359 / claude-picked-up・claude-claimed は #379）を整理
  - `CLAUDE.md` の「機能追加ガイドライン §2」prefix 表に行を追加:
    `| sr_ | stale-pickup-reaper |`
  - 二重管理同期: `repo-template/.claude/{agents,rules}` への変更なし（本 spec は
    エージェント定義・rules ファイルを編集しない）。`diff -r .claude/agents
    repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules`
    が空であることを確認（本 spec では何も変えていないため初期状態が維持される）
  - 最終静的解析:
    - `shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh` 警告ゼロ
    - `shellcheck local-watcher/bin/modules/core_utils.sh` 警告ゼロ
    - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ
    - `bash -n local-watcher/bin/issue-watcher.sh` エラーなし
    - `bash local-watcher/test/stale_pickup_reaper_test.sh` 全 section PASS
  - _Requirements: 1.4, NFR 1.1, NFR 5.1, NFR 5.2, NFR 6.1_
  - _Boundary: README.md, CLAUDE.md_
  - _Depends: 6_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを
構造化ブロックで宣言する。SPR は新規 bash module + 本体 1 行追記 + README / CLAUDE.md
反映のため、静的解析 + 近接テスト + agents / rules ドリフト検査を verify 対象に含める。
（`repo-template/local-watcher/` は構造的に存在しないため diff 対象に含めない /
tasks-generation.md 「存在の不確定なディレクトリへの diff には存在ガード」節）

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh && \
  bash -n local-watcher/bin/issue-watcher.sh && \
  bash local-watcher/test/stale_pickup_reaper_test.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
