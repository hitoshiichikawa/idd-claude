# Requirements Document

## Introduction

idd-claude の watcher（`STAGE_CHECKPOINT_ENABLED=true` 既定）は、同一 head ブランチに
紐づく既存 impl PR を観測して resume 地点（Stage A/B/C）を決定する。現状この観測ロジックは
PR の state が `OPEN` / `MERGED` / `CLOSED` のいずれであっても「Stage C 完了相当（既存 impl
PR あり）」とみなし、`TERMINAL_OK` で自動進行を停止する。

しかし `CLOSED`（未マージで close された）状態の PR は、人間が「やり直したい」「途中で
打ち切った」等の理由で意図的に close した未完了状態であり、後続実装を進めるべき状況であって
着地済みの完了状態ではない。にもかかわらず watcher は CLOSED を MERGED と同列に「完了」と
解釈してしまうため、人間が `claude-failed` ラベルを外して再開を試みても自動進行が即座に
停止する事故が発生する（Issue #265 再現手順 1〜4）。本要件は、CLOSED PR を「完了」と
みなさず watcher が次のサイクルで開発を継続できる挙動を明確化する。

## Requirements

### Requirement 1: CLOSED 未マージ impl PR を「完了」とみなさない resume 地点判定

**Objective:** As an idd-claude 運用者, I want watcher が CLOSED（未マージ）の既存 impl PR を
自動進行を停止する根拠として扱わない挙動, so that 人間が close した未完了 PR を含む Issue で
`claude-failed` ラベル除去後の再開がブロックされない

#### Acceptance Criteria

1. When watcher が同一 head ブランチに紐づく既存 impl PR を観測し state が `CLOSED`
   （未マージ）のみであるとき, the Stage Checkpoint Module shall その PR を resume 地点
   判定の停止根拠として採用しない
2. When watcher が同一 head ブランチに紐づく既存 impl PR を観測し state が `OPEN` であるとき,
   the Stage Checkpoint Module shall 本要件導入前と同一の判定（自動進行を停止し既存 PR を
   再利用する方向）を行う
3. When watcher が同一 head ブランチに紐づく既存 impl PR を観測し state が `MERGED` で
   あるとき, the Stage Checkpoint Module shall 本要件導入前と同一の判定（着地済みとして
   自動進行を停止する方向）を行う
4. When 同一 head ブランチに `OPEN` / `MERGED` の impl PR が存在せず `CLOSED` 未マージ PR
   のみが存在する状態で watcher が起動したとき, the Stage Checkpoint Module shall resume
   地点判定を「既存 impl PR なし」と等価に扱い後段の checkpoint（impl-notes.md /
   review-notes.md）の評価へ進む
5. When `OPEN` または `MERGED` の impl PR と `CLOSED` 未マージ PR が同一 head ブランチに
   混在しているとき, the Stage Checkpoint Module shall `OPEN` または `MERGED` の PR を
   優先採用し CLOSED PR は判定から除外する

### Requirement 2: `claude-failed` ラベル除去後の自動再開継続

**Objective:** As an idd-claude 運用者, I want CLOSED 未マージ impl PR が残っている Issue で
`claude-failed` ラベルを外した後、次サイクル以降の watcher 実行で自動開発が継続する状態,
so that 失敗した PR を人間が close → 再試行する標準フローが機能する

#### Acceptance Criteria

1. When 当該 Issue 上に `claude-failed` / `needs-decisions` のいずれのラベルも存在せず、
   同一 head ブランチに `CLOSED` 未マージ impl PR のみが存在する状態で watcher が
   起動したとき, the Auto-Development Pipeline shall 当該 Issue を処理候補として継続し
   Stage A から再開する
2. When Requirement 2 AC 1 の状態で watcher が処理を継続したとき, the Auto-Development
   Pipeline shall 既存 CLOSED PR に対する追加コメント・ラベル付与・close 操作のいずれも
   発火させない
3. While watcher が CLOSED 未マージ PR を判定から除外した結果として Stage A から再開する
   とき, the Auto-Development Pipeline shall impl-notes.md / review-notes.md の checkpoint
   有無に基づく従来の Decision Table（Stage A / B / C / TERMINAL_FAILED 分岐）を本要件
   導入前と同一の規則で適用する

### Requirement 3: 既存挙動（OPEN / MERGED / Stage C ガード / 越境観測）の後方互換

**Objective:** As an idd-claude 運用者, I want OPEN / MERGED 既存 PR を扱う既存の冪等ガード
（Issue #212 / #213 / #216 / #219 由来）と Stage A 越境観測（Issue #219）の挙動が本要件
導入前と完全に同一であること, so that 既に main で稼働中の二重 PR 防止・spec 成果物完全性
保証・越境検出機構が regression しない

#### Acceptance Criteria

1. When 同一 head ブランチに `OPEN` 状態の impl PR が存在し watcher が Stage C 直前の
   冪等ガードを通過するとき, the Stage Checkpoint Module shall 本要件導入前と同一の挙動
   （新規 PR 作成抑止 + 判定根拠ログ出力 + Issue コメント非投稿）を維持する
2. When 同一 head ブランチに `MERGED` 状態の impl PR が存在し watcher が Stage C 直前の
   冪等ガードを通過するとき, the Stage Checkpoint Module shall 本要件導入前と同一の挙動
   （着地済みとして停止 + 判定根拠ログ出力 + Issue コメント非投稿）を維持する
3. When Stage A 完了直後の越境観測ヘルパが先行 impl PR の存在を観測するとき, the Stage
   Checkpoint Module shall `OPEN` および `MERGED` の PR を本要件導入前と同一の規則で越境
   として記録し、CLOSED 未マージ PR を越境根拠として記録しない
4. When spec 成果物完全性ガードが先行 impl PR の state を取得して補完起動条件を判定する
   とき, the Spec Completeness Guard shall `MERGED` PR を本要件導入前と同一の規則で
   docs-only 補完追従 PR 起動条件として扱い、`OPEN` / `CLOSED` / 既存 PR なしのいずれも
   起動条件外として扱う

### Requirement 4: 観測可能性と判定根拠ログ

**Objective:** As an idd-claude 運用者, I want CLOSED PR を判定から除外したケースが既存ログ
書式で grep 可能であること, so that watcher が再開を継続した理由を後追いで確認できる

#### Acceptance Criteria

1. When watcher が CLOSED 未マージ impl PR を判定から除外して resume 地点判定を継続した
   とき, the Stage Checkpoint Module shall 判定根拠ログを既存の `stage-checkpoint:`
   prefix で 1 行以上出力し、当該 PR 番号と除外理由が含まれる内容にする
2. When watcher が CLOSED 未マージ impl PR を判定から除外した結果として Stage A 再開を
   決定したとき, the Stage Checkpoint Module shall 既存 Decision Table のログ
   （`decision: START_STAGE=A reason=...`）を出力する
3. The Stage Checkpoint Module shall CLOSED PR を除外した判定ログを既存ログ書式と整合する
   `[YYYY-MM-DD HH:MM:SS] stage-checkpoint:` 形式で出力し、grep 抽出可能な状態を保つ

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Stage Checkpoint Module shall 既存環境変数名（`STAGE_CHECKPOINT_ENABLED`）と
   その既定値（未設定または `true` で有効）を本要件導入前と同一に保つ
2. The Stage Checkpoint Module shall `STAGE_CHECKPOINT_ENABLED=true` 以外の値（明示的な
   opt-out 含む）が設定されているとき本要件で追加する判定変更を含めて 1 行も実行せず、
   本機能導入前と完全に同一の挙動を保つ
3. The Auto-Development Pipeline shall 既存ラベル名（`claude-failed` / `needs-decisions`）
   と Issue 候補抽出のフィルタ規則を本要件導入前と同一に保つ
4. The Stage Checkpoint Module shall 同一 head ブランチに `OPEN` または `MERGED` の impl
   PR が 1 件以上存在する全ケースで本要件導入前と挙動を変えない

### NFR 2: 観測性

1. The Stage Checkpoint Module shall CLOSED PR 除外判定の根拠ログを既存の
   `stage-checkpoint:` prefix ログと同一の 3 段書式（`[YYYY-MM-DD HH:MM:SS]
   stage-checkpoint: ...`）で 1 サイクル 1 ブロック内に収め、複数サイクルで grep 抽出
   できる状態を保つ

### NFR 3: 冪等性

1. While 同一 Issue を複数サイクル連続で watcher が処理し、CLOSED 未マージ impl PR の
   状態が変化しないとき, the Auto-Development Pipeline shall 同一 CLOSED PR に対する
   コメント投稿・ラベル付与・close 操作のいずれも複数回発火させない
2. While 同一 Issue に対する watcher の再実行が CLOSED PR 除外判定を通過するとき, the
   Stage Checkpoint Module shall 当該 PR への副作用（コメント / ラベル / close）を持た
   ない read-only 観測のみを行う

## Out of Scope

- CLOSED 未マージ PR の自動再 open（人間が意図的に close した PR を watcher が再 open
  しない）
- CLOSED 未マージ PR の本文・コメント・差分の解析や引き継ぎ（次サイクルは Stage A から
  作業をやり直す前提）
- `needs-decisions` ラベル付与経路（Issue #212 の Stage C CLOSED ガード）の変更
  — 同一サイクル内で Stage A 越境後に CLOSED 状態の PR を新規検出するケースの扱いは
  Issue #212 / #213 の既存規約に従う
- spec 成果物完全性保証（Issue #219）の docs-only 補完起動条件の変更
- `STAGE_CHECKPOINT_ENABLED=true` 以外の opt-out 経路の挙動変更
- per-task ループ（Issue #21 / #251）の残必須タスク検出ロジック変更
- 環境変数による「CLOSED を完了とみなす旧挙動を選択する」opt-out gate の新規追加
  — 本変更は再現手順から推察できる単純なバグ修正であり、旧挙動を必要とする運用ケースが
  Issue 本文・コメント上で確認されていないため、新規 env var 追加はスコープ外とする

## Open Questions

なし
