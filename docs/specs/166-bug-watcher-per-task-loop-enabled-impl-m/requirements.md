# Requirements Document

## Introduction

`PER_TASK_LOOP_ENABLED=true` を有効化した運用下では、impl 系モードの Issue は Stage A の実体が
per-task ループ dispatcher に置き換わる。しかし Architect 不要 triage を通過した Issue（設計フェーズ
を経ず `docs/specs/<番号>-<slug>/tasks.md` が生成されない Issue）が per-task ループ起動に到達すると、
`tasks.md` 不在を理由に無条件で `claude-failed` が付与され、Implementer が一度も起動しないまま停止する。
ログ上は「従来 Stage A にフォールバックする」と表示されるが、実際にはフォールバックが実装されておらず
Issue が失敗扱いになる挙動の不整合がある。本要件は、`tasks.md` 不在時に Issue を失敗扱いせず従来の
Stage A（single-shot Implementer + Reviewer round=1 + PR 作成）相当のフローへ正しくフォールバックさせ、
かつ `tasks.md` が存在する既存ケースの後方互換を完全に維持することを定義する。

## Requirements

### Requirement 1: tasks.md 不在時の Stage A フォールバック

**Objective:** As a idd-claude 運用者, I want `PER_TASK_LOOP_ENABLED=true` 下でも tasks.md を持たない Issue が失敗扱いされず実装に進むこと, so that Architect 不要 triage を通過した Issue が per-task ループ有効化だけを理由に停止しない

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true` であり Stage A 相当の処理に到達している状態, when 対象 Issue の `tasks.md` が存在しないことを検出したとき, the watcher は `claude-failed` ラベルを付与せず従来 Stage A フロー（single-shot Implementer + Reviewer round=1）へフォールバックする shall
2. When tasks.md 不在による Stage A フォールバックを開始したとき, the watcher は対象 Issue へ `claude-failed` 起因の失敗通知コメントを投稿しない shall
3. While tasks.md 不在による Stage A フォールバックを実行中, the watcher は Implementer 起動 → Reviewer round=1 → PR 作成の順で従来 Stage A と同等の成果物を生成する shall
4. If tasks.md 不在による Stage A フォールバック中に Implementer または Reviewer が失敗したとき, the watcher は従来 Stage A と同一の失敗ハンドリング（`claude-failed` 付与）に従う shall

### Requirement 2: tasks.md 存在時の後方互換

**Objective:** As a idd-claude 運用者, I want tasks.md が存在する既存 Issue の per-task ループ挙動が変わらないこと, so that 本修正導入前に成立していた Architect 経由フローの結果が完全に再現される

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true`, when 対象 Issue の `tasks.md` が存在し pending タスクが 1 件以上あるとき, the watcher は従来通り per-task ループで各タスクを逐次処理する shall
2. While `PER_TASK_LOOP_ENABLED=true`, when 対象 Issue の `tasks.md` が存在し pending タスクが 0 件のとき, the watcher は Stage A 完了相当として正常終了する shall
3. While `PER_TASK_LOOP_ENABLED` が未指定または `true` 以外, the watcher は per-task ループ分岐へ入らず従来の Stage A 経路をそのまま実行する shall

### Requirement 3: フォールバック経路の可観測性

**Objective:** As a idd-claude 運用者, I want tasks.md 不在による Stage A フォールバックが発生したことをログで判別できること, so that per-task ループ有効時に Issue がどの経路で処理されたか事後追跡できる

#### Acceptance Criteria

1. When tasks.md 不在による Stage A フォールバックを開始したとき, the watcher は slot ログへフォールバック発生を判別可能な行（例: `per-task: tasks.md 不在 → Stage A fallback`）を出力する shall

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PER_TASK_LOOP_ENABLED` が未指定または `true` 以外, the watcher は本修正導入前と同一の Stage A 外形挙動（ログ出力・ラベル遷移・exit code の意味）を維持する shall
2. While `PER_TASK_LOOP_ENABLED=true` かつ `tasks.md` が存在する状態, the watcher は本修正導入前と同一の per-task ループ結果（pending 件数に応じた処理またはno-op 正常終了）を維持する shall

### NFR 2: 責務境界の保全

1. The watcher は per-task ループ dispatcher の本体アルゴリズム（タスク逐次消化・round 制御・Debugger Gate）に変更を加えず、tasks.md 不在時のフォールバック判定のみを追加する shall

## Out of Scope

- per-task ループ本体のアルゴリズム変更（タスク逐次消化ロジック・round 制御・Debugger Gate の挙動変更）
- Architect 不要 triage の判定ロジック変更
- tasks.md を Implementer agent が自前生成する case の追加

## Open Questions

- フォールバックを per-task ループ内部で行うか、呼び出し階層の上位（Stage A 分岐）で「tasks.md 不在なら Stage A 直行」と判定するかは設計判断（design.md / Architect の領分）に委ねる。Issue 本文では Option A（fallback signal code を返し呼び出し側が Stage A 起動）/ Option B（`run_per_task_loop` 内で従来 Stage A を直接呼ぶ）/ Option C（上位層で事前分岐）の 3 案が提示されている。requirements としては「NFR 2.1 の責務境界を壊さないこと」のみを制約とし、いずれの実装でも AC が満たされれば許容する。
