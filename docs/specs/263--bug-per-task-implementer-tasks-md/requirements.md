# Requirements Document

## Introduction

`PER_TASK_LOOP_ENABLED=true` のとき、per-task Implementer が編集失敗（置換競合・コンパイル
エラー等）を解消できないまま **rc=0（正常終了扱い）で終了**することがある。現状の per-task
ループは `impl_rc=0` を「続行 OK」として無条件に Reviewer フェーズへ流す設計のため、対象 task
の checkbox（`tasks.md` 上の `- [ ] <task_id>`）が `- [x]` に更新されたかを **実行直後に検証
していない**。

進捗ゼロのまま rc=0 で抜けた場合、後段の Stage A 完了ゲート（必須未完了 task が残ったら
resumable return 0 で抜ける経路）が「中断扱い」で `claude-picked-up` を除去して Issue を
再 pickup 可能状態に戻すため、次 tick の dispatcher が同じ Issue を再選択 → impl-resume が
同じ task を再開 → 同じ失敗を rc=0 で返す、という **無限リトライループ** が成立する。本ループは
API quota とログ容量を浪費し続けるため、運用上 high severity の不具合である（Issue #263）。

本要件は、per-task Implementer が rc=0 を返した直後に「今回の task_id 実行で当該 task が
`- [ ] → - [x]` に遷移したか」を検証し、進捗ゼロを検出したら無限ループに入る前に
`claude-failed` で停止させることをスコープとする。影響範囲は per-task ループ内の Implementer
rc=0 分岐のみで、Implementer 自身の編集失敗対策・Debugger Gate の挙動変更・通常 Stage A 経路
（PER_TASK_LOOP_ENABLED 無効時）の変更は本要件のスコープ外とする。

## Requirements

### Requirement 1: 進捗検証の発火条件

**Objective:** As an idd-claude harness operator, I want per-task Implementer が rc=0 を返した
直後に対象 task の進捗を機械検証する仕組みを導入したい, so that 編集失敗のまま正常終了した
Implementer によって無限リトライループに陥ることを防げる。

#### Acceptance Criteria

1. When `PER_TASK_LOOP_ENABLED=true` かつ per-task Implementer が rc=0 で終了したとき, the Issue
   Watcher shall 当該 task_id について `tasks.md` 上の checkbox が実行前に `- [ ]` であった行を
   実行後に `- [x]` へ遷移させたかを検証する。
2. While `PER_TASK_LOOP_ENABLED` が未設定または `true` 以外であるとき, the Issue Watcher shall
   本検証ロジックを 1 行も実行せず、本機能導入前と完全に同一の挙動を維持する。
3. The Issue Watcher shall 本検証を per-task ループ内のすべての Implementer 呼出（round=1 初回
   実行・Reviewer reject 後の round=2 用再実行・Debugger 経由 round=3 用再実行・BLOCKED 経路
   再実行）の rc=0 分岐に適用する。
4. If per-task Implementer が rc=99（quota 超過）または rc=非 0（claude 非 0 exit）で終了した
   とき, the Issue Watcher shall 本検証ロジックをスキップし、既存の quota 早期 return 経路 /
   既存の Implementer 失敗経路をそのまま実行する。

### Requirement 2: 進捗ゼロ検出時の処理

**Objective:** As an idd-claude harness operator, I want 進捗ゼロが検出された Issue を即座に
`claude-failed` 状態にして自動リトライを停止させたい, so that 同じ task で同じ失敗を繰り返す
無限ループによる API 浪費・ログ汚染を未然に止められる。

#### Acceptance Criteria

1. If per-task Implementer rc=0 終了後に対象 task_id の checkbox が `- [ ]` のまま遷移していな
   いことを検出したとき, the Issue Watcher shall 当該 Issue を `claude-failed` 化する失敗
   ハンドラを起動する。
2. When 進捗ゼロが検出されたとき, the Issue Watcher shall 当該 Issue から `claude-picked-up` /
   `claude-claimed` ラベルを除去し `claude-failed` ラベルを付与する（既存失敗ハンドラの挙動と
   等価）。
3. When 進捗ゼロが検出されたとき, the Issue Watcher shall per-task ループを直ちに打ち切り、
   残りの未完了 task を処理しない。
4. When 進捗ゼロが検出されたとき, the Issue Watcher shall 後続の Reviewer 起動・PR 作成・
   ready-for-review 遷移・Stage A 完了ゲートをいずれも実行しない。
5. The Issue Watcher shall 進捗ゼロ検出 1 回ごとに `claude-failed` 化処理を高々 1 回だけ実行し
   （同一 task の同一実行に対して二重発火しない）、Issue コメントを高々 1 件投稿する。

### Requirement 3: 正常系（進捗ありの場合）の非干渉

**Objective:** As an idd-claude harness operator, I want 進捗ありの正常系では本機能導入前と
完全に同一の挙動を維持したい, so that 既存 per-task ループの安定動作と後段（Reviewer / Debugger
Gate / Stage A 完了ゲート）に対する副作用を一切持ち込まない。

#### Acceptance Criteria

1. When per-task Implementer rc=0 終了後に対象 task_id の checkbox が `- [x]` に遷移している
   ことが確認できたとき, the Issue Watcher shall 本機能導入前と同一の続行経路（Debugger Gate
   判定 → Reviewer round=1 起動）へ流れる。
2. The Issue Watcher shall 本検証によって既存の Reviewer 起動条件・Debugger Gate 起動条件・
   Stage A 完了ゲート（必須未完了 task 残存時の resumable return 0 経路）の発火タイミングを
   変更しない。
3. While 対象 task が `- [ ]*`（deferrable テストタスク）として記述されているとき, the Issue
   Watcher shall 本検証の対象外として扱い、既存挙動と同一に動作する（既存 pending 判定パターン
   が `- [ ]*` を除外していることと整合する）。
4. The Issue Watcher shall 進捗検証の判定単位を「当該 round で実行した task_id 1 件」に限定し、
   同一 Issue 内の他 task の checkbox 状態に依存しない判定を行う。

### Requirement 4: Issue コメントとログ出力

**Objective:** As an idd-claude operator, I want 進捗ゼロで停止した Issue を確認したときに、
どの task で何が起きて自動再開が停止されたのかをコメントとログから即座に把握したい, so that
人間が手動で原因を調査し復旧操作（編集失敗の修正 → `claude-failed` 除去）を判断できる。

#### Acceptance Criteria

1. When 進捗ゼロ検出により `claude-failed` 化されるとき, the Issue Watcher shall Issue コメント
   本文に対象 task_id を識別可能な固定文字列として含める。
2. When 進捗ゼロ検出により `claude-failed` 化されるとき, the Issue Watcher shall Issue コメント
   本文に「per-task Implementer が rc=0 で終了したが対象 task の `- [ ]` → `- [x]` 遷移が確認
   できなかった」旨の説明文を含める。
3. When 進捗ゼロ検出により `claude-failed` 化されるとき, the Issue Watcher shall Issue コメント
   本文に無限リトライループ防止のため自動再開を停止した旨と、人間が確認すべき watcher
   ログファイルパスへの参照を含める。
4. When 進捗ゼロ検出により `claude-failed` 化されるとき, the Issue Watcher shall watcher ログ
   に対象 task_id・検出時刻・判定根拠（実行前後の checkbox 状態または進捗ゼロ判定）が grep
   可能な形で記録される 1 行以上のログ行を出力する。
5. The Issue Watcher shall Issue コメントに人間向け復旧手順（修正 commit を積んで `claude-failed`
   を外す）を含める（既存失敗ハンドラの末尾セクション流用で満たしてよい）。
6. The Issue Watcher shall 進捗ゼロ検出による `claude-failed` 化を、watcher ログ・Issue コメント
   上で `per-task-implementer-no-progress` という新規 stage 識別子により、既存の per-task
   失敗種別（claude 非 0 exit / Reviewer reject 由来）と区別可能にする。

### Requirement 5: 冪等性と再起動耐性

**Objective:** As an idd-claude harness operator, I want 同じ Issue が複数 tick にまたがって
評価される場合でも進捗検証が冪等に動作することを保証したい, so that 部分的なネットワーク
断・watcher 再起動・slot 切り替えによって不整合（二重 `claude-failed` 化、コメント重複等）が
発生しない。

#### Acceptance Criteria

1. The Issue Watcher shall 進捗検証を「1 回の per-task Implementer 呼出に対して 1 回」実行し、
   同一呼出に対する再評価を行わない。
2. When 進捗ゼロが検出された Issue が `claude-failed` ラベル付与済の状態で次 tick に持ち越された
   とき, the Issue Watcher shall 既存の `claude-failed` 除外条件により当該 Issue を再 pickup
   しない。
3. If 進捗検証の実行中に `tasks.md` の読み取りに失敗したとき, the Issue Watcher shall 無限
   ループ防止を優先し、`claude-failed` 化して停止する（silent fail で resumable return 0 に
   倒してはならない）。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PER_TASK_LOOP_ENABLED` 環境変数が未設定または `true` 以外であるとき, the Issue
   Watcher shall 本機能を構造的に skip し、既存の単一 Developer 経路（Stage A 通常パス）の
   外形挙動を 1 行も変更しない。
2. The Issue Watcher shall 既存の失敗ハンドラ（ラベル付け替え順序・Issue コメント本文の末尾
   復旧手順セクション）の振る舞いを変更せず、流用のみで本機能を実装できる形を保つ。
3. The Issue Watcher shall 既存の per-task Reviewer reject 経路・Debugger Gate 起動経路・
   Stage A 完了ゲート（必須未完了 task 残存時 resumable return 0）の判定ロジックを変更しない。

### NFR 2: 観測性

1. The Issue Watcher shall 本機能による `claude-failed` 化を `per-task-implementer-no-progress`
   という新規 stage 識別子で記録し、既存の `per-task-implementer-failed` /
   `per-task-implementer-redo-failed` / `per-task-implementer-blocked-redo-failed` /
   `per-task-implementer-pp-failed` とログ・コメント上で区別可能にする。
2. The Issue Watcher shall watcher ログに per-task ロガーの既存書式（`task=<id> implementer
   end ...` と整合する形式）で進捗ゼロ判定結果を記録する。

### NFR 3: 性能

1. The Issue Watcher shall 進捗検証の実行コストを「1 回の per-task Implementer 呼出に対して
   `tasks.md` の grep / read を高々 2 回（実行前 + 実行後）」に抑える。

## Out of Scope

- Implementer 自身が編集失敗（置換競合・コンパイルエラー等）を起こさないようにする改善
  （Implementer prompt の改修・編集リトライ機構の導入等）は本要件のスコープ外。本要件は
  「Implementer が編集失敗から復旧できなかった事実を検知して自動停止する」ことに限定する。
- Debugger Gate の動作変更（BLOCKED 経路・round=3 経路の流れの変更）は対象外。本要件は
  Debugger Gate の前後に位置する Implementer rc=0 分岐に検証を挿入することのみを範囲とする。
- 通常 Stage A 経路（`PER_TASK_LOOP_ENABLED` 未設定・`false` 時の単一 Developer 経路）の進捗
  検証は対象外。当該経路は task ごとの粒度を持たないため別設計が必要。
- Reviewer の reject 判定ロジック・Stage B（PR 作成）・Stage C（PR 確認）の挙動変更は対象外。
- 既存 `partial_blocked` / `partial_overrun` 経路（#148）との統合は対象外。本要件は Developer
  が status 出力をしない「進捗ゼロのまま rc=0」ケースを扱う。
- 進捗ゼロ検出後の自動リトライ・自動 fallback・自動 Architect 差し戻しは対象外
  （`claude-failed` で人間判断に委ねる）。

## Open Questions

- なし（Issue #263 本文と既存実装（per-task ループ / pending task 抽出 / 失敗ハンドラ /
  Stage A 完了ゲート）から要件を確定可能と判断した）。

## 関連

- Related: #263
