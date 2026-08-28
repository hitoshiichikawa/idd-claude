# Requirements Document

## Introduction

consumer repo で `needs-iteration` を付けた PR に対し、slot worker が実装完了後も worktree に
PR の head branch を checkout したまま残していると、PR Iteration Processor が同じ head branch を
checkout しようとして git の仕様（`fatal: '<branch>' is already used by worktree at ...`）で失敗する。
着手表明コメントは checkout より前に無条件投稿されるため、失敗が続くと同一 round のコメントが毎
サイクル再投稿されてスパム化し、round も no-progress 連続カウンタも進まないため escalate にも到達
せず無限リトライになる。design PR は round 無制限のため被害が特に大きい。本要件は、他 worktree が
head branch を保持していても iteration を進行させ、失敗時のコメントスパムを抑止し、着手前段の失敗を
上限で打ち切る挙動を定義する（impl / design 両 kind を対象）。

## Requirements

### Requirement 1: 着手前段での holding worktree 自動 detach

**Objective:** As a watcher 運用者, I want PR Iteration Processor が head branch を保持する他 worktree を checkout 前に自動で detach する, so that slot worker の worktree 残留があっても iteration が正常に進行する

対応: Issue 提案1（後者：pr-iteration 側で checkout 前に holding worktree を detach）/ コメント1（メンテナが提示した checkout 直前 detach パッチ）。

#### Acceptance Criteria

1. When round 着手のため head branch を checkout しようとするとき and 他 worktree が同一 head branch を保持しているとき, the PR Iteration Processor shall その worktree を detach してから checkout を実行する
2. When 他 worktree が head branch を保持している状態で round に着手するとき, the PR Iteration Processor shall checkout を成功させ round を継続する（従来の checkout 失敗による round 中断を起こさない）
3. Where kind が impl または design のいずれであるとき, the PR Iteration Processor shall 同一の holding worktree detach 処理を適用する
4. The PR Iteration Processor shall head branch を保持している worktree のみを detach 対象とし、他の branch を保持する worktree には影響を与えない
5. If holding worktree の detach に失敗したとき, the PR Iteration Processor shall round を異常終了させず既存の checkout フローを継続する（fail-safe）

### Requirement 2: 同一 round 着手表明コメントの再投稿抑止

**Objective:** As a PR レビュワー / 運用者, I want 同一 round で着手前段が繰り返し失敗しても「処理を開始しました」コメントが再投稿されない, so that PR コメント欄がスパムで埋まらない

対応: Issue 提案2（前半：着手表明コメントの dedupe）/ コメント1「round コメントの dedupe も併せて推奨」。

#### Acceptance Criteria

1. If 同一 PR・同一 round の着手表明コメントが既に投稿済みであるとき, the PR Iteration Processor shall そのコメントを再投稿しない
2. When round が新しい round 番号へ進むとき, the PR Iteration Processor shall 当該 round の着手表明コメントを 1 回だけ投稿する
3. If 着手表明コメントの投稿または重複判定に失敗したとき, the PR Iteration Processor shall round 処理を失敗扱いにせず継続する

### Requirement 3: 着手前段失敗の no-progress 計上と上限 escalate

**Objective:** As a watcher 運用者, I want checkout 等の「round に着手できなかった失敗」が無限リトライされず上限で escalate される, so that コスト暴走と無限ループを防げる

対応: Issue 提案2（後半：失敗も no-progress-streak 相当でカウントし上限で escalate）。

#### Acceptance Criteria

1. If round の着手前段（head branch の fetch または checkout 等）が失敗したとき, the PR Iteration Processor shall その round を no-progress として no-progress 連続カウンタに加算する
2. While no-progress 連続カウンタが `PR_ITERATION_NO_PROGRESS_LIMIT` 未満であるとき, the PR Iteration Processor shall `needs-iteration` を据え置き次サイクルでの再試行を許可する
3. When no-progress 連続カウンタが `PR_ITERATION_NO_PROGRESS_LIMIT` 以上に達したとき, the PR Iteration Processor shall `needs-iteration` を除去し `claude-failed` を付与して自動 iteration を停止する
4. When 着手前段失敗により escalate するとき, the PR Iteration Processor shall PR 番号 / kind / round / no-progress 連続カウンタ / 上限値を含む 1 行ログを出力する
5. Where kind が design（round 無制限）であるとき, the PR Iteration Processor shall 着手前段失敗の連続を no-progress として扱い上限到達で escalate する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 既存 env var（`PR_ITERATION_NO_PROGRESS_LIMIT` / `PR_ITERATION_GIT_TIMEOUT` 等）の名前と既定値を変更しない
2. While 他 worktree が head branch を保持していない正常系であるとき, the PR Iteration Processor shall 従来と同一の round 進行・ラベル遷移・コメント投稿挙動を保つ
3. The watcher shall 既存のラベル遷移契約（`needs-iteration` → `awaiting-design-review` / `ready-for-review` / `claude-failed`）を変更しない
4. The PR Iteration Processor shall 本 fix のために新しいラベル名を導入しない

### NFR 2: セキュリティ（未信頼入力の取り扱い）

1. The PR Iteration Processor shall head branch 名・worktree パス等の未信頼入力を、コマンドオプションやコマンドとして解釈させない形で git 操作へ渡す
2. If head branch 名が `-` で始まる値であるとき, the PR Iteration Processor shall その値を git コマンドのオプションとして解釈させずに扱う

### NFR 3: 堅牢性 / 性能

1. The PR Iteration Processor shall holding worktree の検出・detach 操作に既存の git 操作タイムアウト（既定 60 秒 / `PR_ITERATION_GIT_TIMEOUT`）相当の上限を適用し、無応答で 1 watcher サイクルをブロックしない

## トレーサビリティ

| 要件 | 対応する Issue 提案 / コメント決定事項 |
|---|---|
| Requirement 1 | 提案1（後者：pr-iteration 側の holding worktree detach）/ コメント1（メンテナ提示の checkout 直前 detach パッチ、impl / design 両 kind で再発） |
| Requirement 2 | 提案2（前半：着手表明コメント dedupe）/ コメント1「round コメントの dedupe も併せて推奨」 |
| Requirement 3 | 提案2（後半：失敗を no-progress-streak 相当でカウントし上限で escalate） |
| NFR 1〜3 | CLAUDE.md「禁止事項 / 機能追加ガイドライン」（後方互換・未信頼入力・opt-in gate 方針）に基づく横断制約 |

## Out of Scope

- slot worker 終了時（成功・失敗とも）に worktree を detach する実装（Issue 提案1の前者）。本 fix は
  pr-iteration 側の detach（提案1後者）を必須とし、slot worker 側の追加 detach は任意。採否は別 Issue の
  フォローアップに委ねる
- worktree 管理全体のリファクタ / slot 起動時の worktree reset 挙動の変更
- pr-iteration の round budget / `max_rounds`（kind 別上限）ロジックそのものの変更（#122 の既存挙動を維持）
- out-of-scope 還流（#437）機構の変更
- detach の具体的手法・worktree 列挙のパース方式・module 分割・関数命名（design.md / 実装の領分）

## Open Questions

- 本 fix を新しい opt-in gate で導入するか、常時有効（gate なし）にするかは設計判断とする。メンテナが
  コメント1 で提示したパッチは detach を無条件（常時有効）で適用しており、外部挙動を「壊れていた
  ケースだけ正す」バグ修正であるため常時有効が妥当と考えられるが、既存 no-progress streak 機構との
  整合を含め最終判断は Architect / Developer に委ねる
- 着手前段失敗を no-progress として計上する際に round 番号を進めるか据え置くか（PR 本文 hidden marker の
  round / streak フィールドの更新方針）は、既存の no-progress streak 永続化機構との整合を要する設計判断
- slot worker 側の終了時 detach を本 Issue のスコープに含めるか、別 Issue に分離するか（上記 Out of
  Scope の扱いに対する運用者の意向確認）
