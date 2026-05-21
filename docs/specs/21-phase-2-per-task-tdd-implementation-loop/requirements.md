# Requirements Document

## Introduction

現行の impl / impl-resume モードでは、`tasks.md` の全タスクを単一の Developer Claude CLI session が
一括で実装する設計になっている。本機能ではこれを **task 単位の fresh context ループ**に分解し、
各タスクごとに「fresh な Implementer 起動 → 当該 task のみ実装 → fresh な Reviewer 起動 → 次 task へ」
というサイクルを回せるようにする。タスク間では `impl-notes.md` の `## Implementation Notes` 配下に
書き込まれる learnings を前方伝播することで、後続タスクが先行タスクの判断結果（採用ライブラリ・
命名規約・運用上の制約など）を継承できるようにする。

既に Issue #67 / #112 によって `tasks.md` の `- [ ] → - [x]` 進捗追跡・`docs(tasks): mark <id> as done`
commit・中断 resume・origin branch 既存 commit の温存が実装済みであり、Issue #20 によって
独立 context の Reviewer + 1 回差し戻しの規約も整備済みである。本 Issue のスコープは
これらの既実装規約を**流用したまま**、未実装である「per-task fresh Claude CLI context」
「per-task Reviewer（task 単位の diff range レビュー）」「learnings 前方伝播」の 3 点のみを
追加することにある。Phase 2 全体のフェールセーフとして、後方互換性は環境変数による opt-in
ゲート（既定 OFF）で担保し、既稼働の cron / launchd 登録および進行中 Issue の挙動は一切変えない。

## Requirements

### Requirement 1: opt-in による既存挙動の保全

**Objective:** As a 既存 install 済みリポジトリの運用者, I want 本機能を opt-in でのみ有効化したい, so that 既定では既存 cron / Issue / PR 挙動が一切変化せず移行コストを発生させない

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED` 環境変数が未設定または `false` である間, the Issue Watcher shall impl / impl-resume モードを本機能導入前と同一の単一 Developer 一括実装で動作させる
2. While `PER_TASK_LOOP_ENABLED=true` である間, the Issue Watcher shall 本要件群（Requirement 2 / 3 / 4 / 5）で定義する per-task ループ挙動を有効化する
3. The Issue Watcher shall `PER_TASK_LOOP_ENABLED` の受理値を `true` / `false` の 2 値とし、それ以外の値（空文字 / `1` / `True` / 不正値）は `false` と等価に扱う
4. The Issue Watcher shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `REVIEWER_MODEL`, `IMPL_RESUME_PRESERVE_COMMITS`, `IMPL_RESUME_PROGRESS_TRACKING` 等）の意味と受理形式を本変更で改変しない
5. The Issue Watcher shall 既存 cron / launchd 登録文字列を変更しなくても本機能（既定 OFF 状態）が動作する状態を維持する

### Requirement 2: task 単位の fresh Implementer 起動

**Objective:** As a 開発者, I want 各 task ごとに fresh な Claude CLI session で Implementer を起動したい, so that 先行タスクの context 残留に起因する誤誘導なしに、当該 task の `_Requirements:_` / `_Boundary:_` だけに集中して実装される

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true` であり、`tasks.md` に未完了 `- [ ]` 行が残っている間, the Issue Watcher shall `tasks.md` の numeric ID 番号順で未完了 task を 1 件ずつ取り出して処理する
2. When 1 件の task を取り出して処理する, the Issue Watcher shall 当該 task 1 件のみを実装対象として Implementer を fresh な Claude CLI session（独立 context）で起動する
3. The Issue Watcher shall task ID として numeric ID（`1`, `1.1`, `1.2` 等）のみを使用し、`T-NN` 形式の英字 ID を生成・受理しない
4. When task 1 件の Implementer が正常終了した, the Issue Watcher shall 当該 task の `- [ ] <id>` 行を `- [x] <id>` に書き換え、Issue #67 / #112 で規定された `docs(tasks): mark <id> as done` の commit 規約に従って 1 task ごとに別 commit として記録する
5. When 親タスクの全子タスク（`1.1`, `1.2` …）が `- [x]` になった, the Issue Watcher shall 親タスク（`1.` 行）も `- [x]` に書き換え、同じ commit 規約で記録する
6. If 単一 task 内の Implementer ステップが非 0 exit で終了した, the Issue Watcher shall 次 task の取り出しを行わず、既存の Developer 失敗時遷移（`claude-failed` 付与）をそのまま適用する
7. While `tasks.md` の全 task が `- [x]` 完了済みの状態で本ループに到達した, the Issue Watcher shall 追加の Implementer 起動を行わず、既存 PjM 起動経路に進む

### Requirement 3: task 単位の Reviewer 起動と差し戻し

**Objective:** As a 開発者, I want 各 task の commit 差分が独立 context の Reviewer で都度判定されること, so that 一括実装ではなく task 単位で AC 未カバー / missing test / boundary 逸脱を早期検出できる

#### Acceptance Criteria

1. When 1 件の task の Implementer が正常終了し `docs(tasks): mark <id> as done` の commit が記録された, the Issue Watcher shall 当該 task の commit 範囲のみを対象として Reviewer を fresh な Claude CLI session（独立 context）で起動する
2. The Issue Watcher shall Reviewer のレビュー対象を「直前の `mark <id> as done` commit から当該 task の `mark <id> as done` commit まで」の diff range（=当該 task で積まれた commit 群）に限定する
3. While task 単位 Reviewer ステップを実行中, the Reviewer Agent shall Issue #20 で規定された判定カテゴリ（AC 未カバー / missing test / boundary 逸脱）と出力契約（`approve` / `reject` および理由カテゴリ）をそのまま適用する
4. When task 単位 Reviewer が `reject` を出力した, the Issue Watcher shall Issue #20 で規定された差し戻しルール（同一 task に対して Implementer を最大 1 回再起動 → 再 reject 時は `claude-failed` 付与）をそのまま適用する
5. When 1 件の task で Reviewer が `approve` を出力した, the Issue Watcher shall 次 task の取り出しと Implementer 起動に進む
6. When 1 件の task で再 reject により `claude-failed` が付与された, the Issue Watcher shall 残りの未完了 task の処理を行わず、後続 PjM 起動も行わない
7. The Issue Watcher shall task 単位 Reviewer の起動回数を 1 task あたり最大 2 回（初回 + 再 reject 時の最終回）に固定し、それ以上の自動再起動を行わない

### Requirement 4: learnings 前方伝播

**Objective:** As a 開発者, I want 先行 task が判断した内容（採用したアプローチ・命名規約・運用上の発見事項）を後続 task の Implementer が参照できるようにしたい, so that fresh context によって失われがちな「直前の判断との一貫性」を保てる

#### Acceptance Criteria

1. When 1 件の task の Implementer が正常終了する, the Implementer Agent shall `impl-notes.md` の `## Implementation Notes` セクション配下に `### Task <id>` 見出しと当該 task の learning（採用方針 / 重要な判断 / 残存課題）を追記する
2. The Implementer Agent shall 先行 task に対応する既存の `### Task <id>` 見出し（前方の task の learnings）を改変・削除・並び替えしない
3. When 後続 task の Implementer を fresh 起動する, the Issue Watcher shall 当該 Implementer のプロンプトに `impl-notes.md` の `## Implementation Notes` セクション全体（これまで完了した task 群の learnings）を注入する
4. The Issue Watcher shall `## Implementation Notes` セクション外の `impl-notes.md` 既存記述（補足ノート・確認事項など）を本機能で改変しない
5. While task 数が 1 件の Issue を処理中, the Issue Watcher shall 単一の Implementer 起動と単一の Reviewer 起動で完結させ、前方伝播対象の learnings が空であることを許容する

### Requirement 5: resume 時の per-task ループ整合

**Objective:** As a 開発者, I want 中断・再 pickup された Issue で per-task ループが既完了 task をスキップして未完了の先頭から再開すること, so that quota 切れや claude-failed 解除後の再開で同一 task の二重実装が発生しない

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true` であり、`impl-resume` モードで再開された Issue の `tasks.md` に `- [x]` 済み task と `- [ ]` 未完了 task が混在しているとき, the Issue Watcher shall `- [x]` 済み task をスキップし `- [ ]` 未完了 task の先頭から Implementer を fresh 起動する
2. While `PER_TASK_LOOP_ENABLED=true` であり、`impl-resume` モードで再開された Issue の `tasks.md` に未完了 task が残っていないとき, the Issue Watcher shall 追加の Implementer / Reviewer を起動せず、既存の `impl-resume` 終端処理（PjM 起動）に進む
3. While `PER_TASK_LOOP_ENABLED=true` で `impl-resume` 再開を行う間, the Issue Watcher shall Issue #67 で規定された `IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING` の挙動契約（既存 origin branch 尊重 / `tasks.md` 進捗マーカー更新）に従う
4. The Issue Watcher shall `impl-resume` モードでの再開時に、既に `impl-notes.md` に存在する `### Task <id>` learnings を保持したまま、未完了 task の Implementer プロンプトへ注入する

### Requirement 6: ドキュメント整合と運用者向け説明

**Objective:** As a 既存 install 済みリポジトリの運用者, I want README およびエージェント定義から本機能の opt-in 手順・新挙動・既存 Issue への影響を確認したい, so that 適用判断と移行手順を 1 次情報源から完結できる

#### Acceptance Criteria

1. The Documentation shall README に `PER_TASK_LOOP_ENABLED` の用途・既定値・有効化方法・累積コストに関する運用ガイドを追記する
2. The Documentation shall README に opt-in 時の新挙動（task 単位 fresh Implementer 起動 / task 単位 Reviewer / learnings 前方伝播 / resume 時の挙動）を運用者視点で記述する
3. The Documentation shall `repo-template/.claude/agents/developer.md` に per-task ループ下での Implementer の責務（1 task のみ実装 / `### Task <id>` の learning 追記 / 既存 learnings を改変しない）を追記する
4. The Documentation shall `repo-template/.claude/agents/reviewer.md` に per-task ループ下での Reviewer の責務（task 単位 diff range のみを判定対象とする / 既存の判定カテゴリ・差し戻し規約を流用する）を追記する
5. The Documentation shall README に Migration Note として「既定では従来挙動が維持される」「opt-in 後も task 数 1 件の Issue は単一 Implementer + 単一 Reviewer で完結する」「task 単位 Claude CLI 起動の累積により API コストが現状の 3〜5 倍規模になり得る」旨を明記する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 既定値（`PER_TASK_LOOP_ENABLED=false`）下で、本機能導入前にピックアップ済みの Issue・既存 PR・既存 cron 設定が中断・誤遷移・誤完了・誤 fail を起こさない状態を維持する
2. The Issue Watcher shall 既存ラベル（`auto-dev` / `claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-decisions` / `skip-triage` / `needs-rebase` / `needs-iteration` / `staged-for-release`）の名称・付与契約・遷移意味を本機能で変更しない
3. The Issue Watcher shall 既存 exit code の意味と既存ログ出力先（`LOG_DIR` 配下）のフォーマット契約を本機能で変更しない
4. The Issue Watcher shall Issue #67（`IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING`）および Issue #20（Reviewer 差し戻しループ）で確立された挙動契約を本機能で変更しない

### NFR 2: 観測可能性

1. The Issue Watcher shall `PER_TASK_LOOP_ENABLED=true` 下で、各 task の「Implementer 起動」「Implementer 終了結果」「Reviewer 起動」「Reviewer 判定（`approve` / `reject` / 異常終了）」の 4 イベントを `LOG_DIR` 配下のログに事後判別可能な粒度で記録する
2. The Issue Watcher shall ログ各エントリに対象 task の numeric ID（例: `task=1.2`）を含めて記録する
3. The Issue Watcher shall task 単位 Reviewer の `reject` 発生時に、対象 task ID・理由カテゴリ・対応する requirement numeric ID をログに 1 行以上で記録する

### NFR 3: コスト上限の運用者可視性

1. The Documentation shall README に「per-task ループ有効化により Claude CLI 起動回数が task 件数に比例して増加する」旨と、参考値として「累積コストは現状の 3〜5 倍を想定」する旨を運用者が事前判断可能な形で記載する

### NFR 4: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck local-watcher/bin/issue-watcher.sh` 実行において新規警告を 0 件に保つ
2. The Workflow YAML（変更が及ぶ場合）shall `actionlint` 実行において新規警告を 0 件に保つ

## Out of Scope

- Debugger サブエージェントの起動（Phase 3 / Issue #22 の範疇）
- Feature Flag Protocol の per-task 統合（Phase 4 / Issue #23 規約済み）
- per-task の並列実行（Phase C / Issue #16 は Issue 単位の並列であり、本機能の task 単位並列化はスコープ外）
- 累積 turn 数による Opus → Sonnet 自動ダウングレード（運用検討事項として確認事項に列挙）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への per-task ループ移植
- `impl-notes.md` フォーマットの全面正規化（`### Task <id>` 見出しの追加のみを規定し、既存記述の構造変更は行わない）
- Issue #67 / #112 で既に実装済みの `tasks.md` 進捗追跡・`docs(tasks): mark <id> as done` commit・中断 resume・origin branch 既存 commit 温存（本機能ではこれらを流用するのみで再実装しない）
- Issue #20 で既に実装済みの独立 context Reviewer + 1 回差し戻し規約（本機能ではこれを流用するのみで再実装しない）
- `PER_TASK_LOOP_ENABLED=true` 既定化への移行スケジュールおよび deprecation 期間設計

## Open Questions

- コスト上限の制御方式: 累積 turn 数による Opus → Sonnet 自動ダウングレードの閾値設定の要否、および `PER_TASK_MAX_TASKS`（per-task ループで処理する task 件数上限）の要否について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- learnings 注入フォーマット: `### Task <id>` 段落形式 / YAML 表 / 行単位リストのいずれを採用するかについて Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- task 単位 diff range の特定方式: `git log --grep "mark <id> as done"` による commit 検索 vs commit trailers（`Task-Id: 1.2` 等）による明示メタデータ付与のいずれを採用するかについて Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- per-task Reviewer の判定 depth: 全 requirement の AC を毎回 verify するか、当該 task の `_Requirements:_` で参照されている AC のみを verify するかについて Issue 本文で明示されていないため、design フェーズで具体化する余地がある
- Implementer / Reviewer の env var 分離: `IMPLEMENTER_MODEL` を新設するか、既存の `DEV_MODEL` をそのまま流用するか（および `REVIEWER_MODEL` との関係）について Issue 本文で明示されていないため、design フェーズで具体化する余地がある
