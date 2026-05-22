# Implementation Plan

> 全タスクは `local-watcher/bin/issue-watcher.sh` と `repo-template/.claude/agents/*.md` /
> `README.md` を対象とする。タスク間の境界は `Boundary:` で明示するが、`issue-watcher.sh`
> 内のヘルパー関数追加は **同一ファイル内の独立セクション** として実装するため、原則として
> 並列実行は行わない（直列消化を前提に組んでいる）。

- [x] 1. 環境変数の追加と正規化（後方互換性ゲート）
  - `local-watcher/bin/issue-watcher.sh` の config block に
    `PER_TASK_LOOP_ENABLED="${PER_TASK_LOOP_ENABLED:-false}"` と
    `PER_TASK_MAX_TASKS="${PER_TASK_MAX_TASKS:-0}"` を追加
  - 値の正規化は使用箇所で `[ "$PER_TASK_LOOP_ENABLED" = "true" ]` 完全一致のみ true 扱い
    （`true` 以外は false 等価 / Req 1.3）
  - 既存 env normalization ループには **加えない**（既定 false の opt-in なので #112 とは
    別ポリシー）
  - 既存 env var（`DEV_MODEL` / `REVIEWER_MODEL` / `DEV_MAX_TURNS` / `REVIEWER_MAX_TURNS` /
    `IMPL_RESUME_*` 等）の名前・既定値・意味を変更しないこと（Req 1.4）
  - _Requirements: 1.3, 1.4, 1.5_

- [x] 2. per-task ヘルパー関数群（抽出 / 解決系）
- [x] 2.1 `pt_extract_pending_tasks <tasks_md_path>` の実装
  - tasks.md から `^- \[ \] ([0-9]+(\.[0-9]+)*) ` にマッチする行を抽出（deferrable `- [ ]*` は除外）
  - 抽出した numeric ID を `sort -V` で numeric 階層昇順に並べて stdout に出力
  - tasks.md 不在時は return 1
  - _Requirements: 2.1, 2.3, 5.1_
- [x] 2.2 `pt_extract_learnings <impl_notes_path>` の実装
  - `## Implementation Notes` 見出しから次の `## ` 見出し直前までを stdout に出力
  - セクション / ファイル不在時は空文字を返し常に return 0（Req 4.5 を構造的に保証）
  - _Requirements: 4.3, 4.4, 4.5, 5.4_
- [x] 2.3 `pt_resolve_diff_range <task_id>` の実装
  - `git log --grep="^docs(tasks): mark " --format=%H --reverse $BASE_BRANCH..HEAD` で時系列昇順 SHA 列を取得
  - 当該 task の mark commit SHA を特定し、その直前 SHA を range_start とする
  - 直前が存在しない（初回 task）場合は range_start に `$BASE_BRANCH` のコミット SHA を使う
  - stdout に `<range_start_sha>\t<range_end_sha>` を出力。mark commit 不在時は return 1
  - _Requirements: 3.2, 4.5, 5.4_
- [x] 2.4 `pt_log` ロガーの追加
  - 既存 `rv_log` / `pt_log` と同形式で `[YYYY-MM-DD HH:MM:SS] per-task: $*` を stdout 出力
  - 呼び出し側で `>> "$LOG"` する規約（既存 rv_log と同じ）
  - _Requirements: NFR 2.1, NFR 2.2_

- [x] 3. per-task Implementer prompt builder と launcher
- [x] 3.1 `build_per_task_implementer_prompt <task_id>` の実装
  - 既存 `build_dev_prompt_a` の heredoc 形式を踏襲し、「本 task 1 件のみ実装」「`### Task <id>`
    learning 追記」「先行 learnings 改変禁止」「`docs(tasks): mark <id> as done` commit 規約」
    「PR / requirements / design 改変禁止」を含む
  - `pt_extract_learnings` の出力を「## これまで完了した task の learnings」として inline 埋め込み
  - `RESUME_PRESERVE=true` 時の既存 commit 温存規約セクションも従来通り含める
  - _Requirements: 2.2, 2.3, 2.4, 2.5, 4.1, 4.2, 4.3, 4.4_
- [x] 3.2 `run_per_task_implementer <task_id>` の実装
  - `qa_run_claude_stage "PerTask-Impl-<id>" ...` 経由で `claude --print --model "$DEV_MODEL"
    --max-turns "$DEV_MAX_TURNS"` を起動
  - 戻り値 0 / 1 / 99（quota）を従来 Stage A と同形でマップ
  - 起動前後で `pt_log "task=<id> implementer start/end ..."` を出力（NFR 2.1, NFR 2.2）
  - _Requirements: 2.2, 2.6, NFR 1.3, NFR 2.1, NFR 2.2_

- [x] 4. per-task Reviewer prompt builder と launcher
- [x] 4.1 `build_per_task_reviewer_prompt <task_id> <range_start_sha> <range_end_sha> <round> <prev_result>` の実装
  - 既存 `build_reviewer_prompt` を踏襲。diff range は HEAD 全体ではなく
    `<range_start_sha>..<range_end_sha>` を Bash 実行ガイドに明示
  - 判定 depth 制約「当該 task の `_Requirements:_` AC のみ verify。それ以外の AC は reject 対象外」
    を明示
  - `_Boundary:_` 違反は depth に関わらず常に reject 対象であることを明示
  - 既存 reviewer.md の 3 カテゴリ / RESULT 行 / review-notes.md 出力契約を流用
  - _Requirements: 3.1, 3.2, 3.3_
- [x] 4.2 `run_per_task_reviewer <task_id> <round>` の実装
  - `pt_resolve_diff_range <task_id>` で SHA range を取得
  - `qa_run_claude_stage "PerTask-Rev-<id>-r<round>" ...` 経由で
    `claude --print --model "$REVIEWER_MODEL" --max-turns "$REVIEWER_MAX_TURNS"` を起動
  - `parse_review_result` で `approve` / `reject` / 異常 を抽出、戻り値 0 / 1 / 2 / 99 にマップ
  - reject 時は `pt_log "task=<id> reviewer end round=<r> result=reject categories=<...> targets=<...>"`
    で NFR 2.3 のログ粒度を担保
  - _Requirements: 3.1, 3.2, 3.3, NFR 2.1, NFR 2.2, NFR 2.3_

- [x] 5. per-task dispatcher と差し戻しハンドラ
- [x] 5.1 `run_per_task_loop` 本体の実装
  - `pt_extract_pending_tasks "$REPO_DIR/$SPEC_DIR_REL/tasks.md"` で pending 一覧を取得
  - 空なら即 return 0（Req 2.7, 5.2）
  - `PER_TASK_MAX_TASKS != 0` で件数超過チェック（暴走防止）
  - 各 task について `run_per_task_implementer` → `run_per_task_reviewer round=1` を実行
  - approve なら次 task へ、reject なら再 `run_per_task_implementer` →
    `run_per_task_reviewer round=2` を実行
  - 再 reject / Implementer 非 0 exit / Reviewer 異常 で `mark_issue_failed` を呼んで return 1
  - quota（99）受領時は呼び出し側に伝搬し、watcher 側で needs-quota-wait に遷移（既存 #66 経路）
  - _Requirements: 2.1, 2.6, 2.7, 3.4, 3.5, 3.6, 3.7, 5.1, 5.2_
- [x] 5.2 `run_impl_pipeline` への Strategy 分岐挿入
  - Stage A 実行直前（`case "$START_STAGE" in A)` 分岐内）で
    `[ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]` を判定
  - true なら `run_per_task_loop` を呼ぶ。完了後の `verify_pushed_or_retry` / stage-a-verify /
    Stage B / Stage C 経路は既存のまま流用（変更しない）
  - false 側は既存の `build_dev_prompt_a` → `qa_run_claude_stage` → 既存 verify 経路（変更なし）
  - START_STAGE=B|C のスキップ経路は変更しない（Stage Checkpoint resume と直交）
  - _Requirements: 1.1, 1.2, 5.3, NFR 1.1, NFR 1.4_

- [x] 6. Agent 定義への per-task 責務追記
- [x] 6.1 `repo-template/.claude/agents/developer.md` に「per-task ループ下での Implementer の責務」節を末尾追加
  - 「1 起動 = 1 task のみ」「`### Task <id>` learning 追記規約」「先行 learnings 改変禁止」
    「`## Implementation Notes` セクション外を触らない」「prompt の既存 learnings を参照して
    一貫性を維持」を含む
  - 既存節（実装フロー / opt-in 時の追加実装フロー / impl-resume 規約 / テスト規約 etc）は
    一切改変しない
  - _Requirements: 6.3, 2.4, 2.5, 4.1, 4.2, 4.4_
- [x] 6.2 `repo-template/.claude/agents/reviewer.md` に「per-task ループ下での Reviewer の責務」節を末尾追加
  - 「判定対象 diff range は `<range_start>..<range_end>` のみ」「判定 AC は当該 task の
    `_Requirements:_` 列挙分のみ」「`_Boundary:_` 違反は常に reject」「既存 3 カテゴリと
    RESULT 行規約を流用」を含む
  - 既存節（必読ファイル / 判定基準 / round 別判断 / 出力契約 etc）は一切改変しない
  - _Requirements: 6.4, 3.2, 3.3_

- [ ] 7. README ドキュメント整備
  - 「オプション機能（標準有効 / 常時有効）一覧」表の `opt-in（既定 OFF、明示的に有効化が必要）`
    サブセクションに `PER_TASK_LOOP_ENABLED` 行を追加（既存表組のフォーマットを踏襲）
  - 専用解説節「Per-task TDD Implementation Loop (#21)」を追加（既存「impl-resume Branch
    Protection (#67)」「Stage Checkpoint (#68)」と同一構造で、用途 / 既定値 / 有効化方法 /
    新挙動の説明 / 累積コスト警告（3〜5 倍）/ Migration Note / 既存 env var 不変の明記）
  - _Requirements: 6.1, 6.2, 6.5, NFR 3.1_

- [ ] 8. 静的解析と手動スモークによる検証（impl-notes.md への結果記録）
  - `shellcheck local-watcher/bin/issue-watcher.sh` を実行し新規警告 0 件を確認（NFR 4.1）
  - `actionlint .github/workflows/*.yml` 実行（YAML 変更なしのため自動的に達成）（NFR 4.2）
  - dry run #1: `PER_TASK_LOOP_ENABLED` 未設定で `REPO=owner/test REPO_DIR=/tmp/test-repo
    $HOME/bin/issue-watcher.sh` を空 Issue 状態で流し、`処理対象の Issue なし` で正常終了する
    こと（既存挙動が不変であることの確認 / Req 1.1 / NFR 1.1）
  - dry run #2: 任意の test repo に 2 task の test Issue を立て、`PER_TASK_LOOP_ENABLED=true`
    で watcher を起動。`$LOG` に per-task の 4 イベント（implementer start/end / reviewer
    start/end）×2 task が `task=<id>` 付きで出力されることを確認（NFR 2.1, 2.2）
  - 結果と再現コマンドを `docs/specs/21-phase-2-per-task-tdd-implementation-loop/impl-notes.md`
    に記録
  - _Requirements: NFR 4.1, NFR 4.2, NFR 2.1, NFR 2.2, NFR 2.3_

- [ ]* 8.1 E2E dogfooding（任意 / deferrable）
  - idd-claude 自身に小さな auto-dev Issue を立て、`PER_TASK_LOOP_ENABLED=true` で
    Triage → per-task loop → PR 作成までを通す
  - Reviewer reject 差し戻し / 再 reject claude-failed / resume 再開の 3 経路を意図的に発生させ、
    既存規約（#20 / #67 / #112 / #66）が壊れていないことを確認
  - _Requirements: 3.4, 3.6, 5.1, 5.4_
