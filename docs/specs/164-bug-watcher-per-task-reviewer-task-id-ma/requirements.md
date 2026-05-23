<!-- Issue: #164 -->
<!-- URL: https://github.com/hitoshiichikawa/idd-claude/issues/164 -->
<!-- 採用方針: Option C（A: Developer prompt 厳格化 + B: watcher 側 marker 解決の許容拡大 + 追加: 明示的エラー文言と復旧手順） -->

# Requirements Document

## Introduction

`PER_TASK_LOOP_ENABLED=true` の per-task ループにおいて、per-task Reviewer の diff range
解決ロジックは「`docs(tasks): mark <id> as done`」という subject 行と task ID が厳密一致
する marker commit を前提としている。しかし Developer が親 task と子 task の完了を 1 つの
commit に集約し「`docs(tasks): mark 1 / 1.1 / 1.2 / 1.3 as done`」のような連記形式で
commit を作成すると、当該 task ID の marker commit が見つけられず Reviewer が
`diff-range-resolve-failed` として異常終了する。結果として `claude-failed` が付与され、
push 前の Developer commit が次サイクルの worktree reset で失われ、`git reflog` でしか
復旧できない（重大なデータ損失リスク）。

本 spec は Option C（Developer 側 prompt の厳格化と watcher 側 marker 解決の許容範囲拡大を
併用し、加えて失敗時の Issue コメントに具体的な復旧手順を明示する）に基づき、上記障害を
恒久的に回避することを目的とする。

## Requirements

### Requirement 1: Developer prompt の厳格化（1 commit = 1 task ID）

**Objective:** As a per-task Implementer 起動の責務記述, I want 進捗マーカー commit を 1 task ID 単位で分割するよう明示する prompt を発行できる, so that Developer が複数 task ID を 1 つの marker commit に集約することを未然に防止できる

#### Acceptance Criteria

1. When per-task Implementer 用 prompt が組み立てられたとき, the Per-Task Implementer Prompt Builder shall 「1 つの `docs(tasks): mark <id> as done` commit には 1 つの task ID のみを含める」旨を明示記載する
2. When per-task Implementer 用 prompt が組み立てられたとき, the Per-Task Implementer Prompt Builder shall 親 task の完了昇格も子 task と同じ 1 ID 単位で別 commit に分割する旨を明示記載する
3. If 当該 prompt 内で複数 task ID を 1 commit にまとめる例示やテンプレが残存している場合, the Per-Task Implementer Prompt Builder shall 該当箇所を 1 ID 単位の表記に修正する
4. The Per-Task Implementer Prompt Builder shall 上記厳格化を `PER_TASK_LOOP_ENABLED=true` の起動時のみ適用し、それ以外の起動経路には影響を与えないことを保証する

### Requirement 2: 連記 marker commit からの task ID 解決の許容

**Objective:** As a per-task Reviewer の diff range 解決ロジック, I want 複数 task ID 連記の marker commit からも当該 task ID を抽出できる, so that Developer が誤って ID を連記した場合でも Reviewer が異常終了せず push 済み commit を保護できる

#### Acceptance Criteria

1. When `docs(tasks): mark <id> as done` 形式の marker commit が存在するとき, the Per-Task Diff Range Resolver shall 当該 task ID に対応する commit SHA を解決する
2. When 1 つの marker commit subject に複数の task ID（例: `mark 1 / 1.1 / 1.2 as done`、`mark 1, 1.1 as done`）が連記されていてその中に当該 task ID が含まれるとき, the Per-Task Diff Range Resolver shall 当該 commit を当該 task ID の marker commit として解決する
3. When 連記 marker commit が解決対象になった場合, the Per-Task Diff Range Resolver shall 連記された各 task ID に対して同一の commit SHA を返す
4. If 当該 task ID が単記 marker commit と連記 marker commit の双方に出現する場合, the Per-Task Diff Range Resolver shall いずれか 1 つを一意に選択し、選択基準を観測ログで識別可能な形で出力する
5. If 連記 marker commit を解釈する際に task ID として誤検出を起こし得る文字列（例: 別の数字列・version 表記）が混在する場合, the Per-Task Diff Range Resolver shall 当該 task ID と完全一致するトークンのみを抽出して照合する

### Requirement 3: 既存単記 marker commit との後方互換性

**Objective:** As a per-task ループ全体, I want 従来通り 1 commit = 1 task ID の marker commit を引き続き正しく解決できる, so that 既存 spec / 既存ブランチ / 既存 git ログ列が本変更の影響を受けない

#### Acceptance Criteria

1. When 既存形式の単記 marker commit（`docs(tasks): mark 1.2 as done`）のみが存在するとき, the Per-Task Diff Range Resolver shall 本変更前と同一の解決結果（同一 SHA 列・同一 range_start / range_end）を返す
2. The Per-Task Diff Range Resolver shall 連記マーカ対応に伴う追加処理を、単記マーカのみで構成されるリポジトリ履歴に対して観測可能な副作用なく適用する
3. While `PER_TASK_LOOP_ENABLED=true` 以外の起動経路で動作しているとき, the watcher shall 本変更を経路上で参照しないことで本機能導入前と同一挙動を維持する

### Requirement 4: 失敗時の Issue コメントに具体的な原因と復旧手順を明示

**Objective:** As a per-task Reviewer の失敗ハンドリング, I want `diff-range-resolve-failed` で `claude-failed` を付与する際に Issue コメントに具体的な原因と復旧手順を残せる, so that 運用者が次サイクルでデータ損失を起こさずに復旧できる

#### Acceptance Criteria

1. When per-task Reviewer の diff range 解決が失敗して `claude-failed` ラベルを付与するとき, the Failure Notification shall Issue コメントに失敗カテゴリ（`diff-range-resolve-failed`）と当該 task ID を明示する
2. When 上記の Issue コメントを生成するとき, the Failure Notification shall 復旧手順として「push 前の未保存 Developer commit がある場合は `git reflog` から拾い直す」「次サイクル前に worktree が reset される可能性がある」旨を文章で明示する
3. When 上記の Issue コメントを生成するとき, the Failure Notification shall Developer に推奨される marker commit 分割の規約（1 commit = 1 task ID）を案内する
4. If 同じ Issue に対して同一カテゴリの失敗コメントが既に存在する場合, the Failure Notification shall 重複コメントの追加を抑制するか、追記である旨が読み取れる形でコメントを残す

### Requirement 5: 既存テンプレ・ドキュメント・既存 PR への副作用を生まない

**Objective:** As a installed consumer repo の運用者, I want 本変更が既存の `repo-template/` 配下や既存 PR / 既存ログに対して破壊的影響を与えない, so that `install.sh` 再実行や既存 PR の rebase 等で予期しないログ差分・挙動差分が出ない

#### Acceptance Criteria

1. The Per-Task Loop Implementation shall 既存の `docs(tasks): mark <id> as done` 規約および既存テンプレ表記を温存し、本変更を「追加の許容範囲を広げる」差分のみで構成する
2. The Per-Task Loop Implementation shall 既存 env var 名・ラベル名・cron 登録文字列・exit code 意味を保持する
3. If 本変更で `repo-template/.claude/agents/developer.md` の文言を変更する場合, the Per-Task Loop Implementation shall 既存記述の意味を反転させず、追記または明確化に留める
4. While `PER_TASK_LOOP_ENABLED` が未設定または `=true` 以外であるとき, the watcher shall 本変更経路に一切到達しないことで本機能導入前と完全に同一の外形挙動を維持する

## Non-Functional Requirements

### NFR 1: 後方互換性・冪等性

1. The Per-Task Loop Implementation shall 既存 1 commit = 1 task ID 形式の marker commit を持つ全リポジトリで本変更前と同一の Reviewer 判定結果（approve / reject 分布）を維持する
2. The Per-Task Loop Implementation shall 同一 watcher プロセスを複数回起動した場合に重複コメント・重複 commit を生成しない

### NFR 2: 観測可能性

1. When 連記 marker commit を経由して task ID が解決されたとき, the Per-Task Diff Range Resolver shall その旨を識別可能な形で stdout ログに残し、運用者が grep で連記経由の解決件数を把握できるようにする
2. When `diff-range-resolve-failed` で異常終了するとき, the Per-Task Diff Range Resolver shall ログに当該 task ID と「単記 / 連記いずれの候補も見つからなかった」旨を明示する

### NFR 3: 運用復旧性

1. The Failure Notification shall Issue コメントによる復旧手順案内で、運用者が 5 分以内に必要な対応（reflog 確認・marker commit 分割の周知）を判断できる粒度の情報を提供する

## Out of Scope

- per-task Reviewer のアルゴリズム本体（diff range 解決後の review depth / 判定基準 / RESULT 行のフォーマット）の変更
- `IMPL_RESUME_PRESERVE_COMMITS=true` モードの branch 初期化ロジックや既存 commit 温存規約自体の変更
- Developer agent への commit 集約禁止 git hook 等の新規 watcher 機能の導入（hook によるブロックは行わない）
- 連記 marker commit を canonical 表記として推奨する方向への規約変更（canonical は引き続き「1 commit = 1 task ID」、連記は「許容するが推奨しない」位置付け）
- 既に main にマージ済みの過去 commit / 過去 PR 履歴の遡及的書き換え（retrofit）
- per-task ループ以外の Reviewer Gate（`run_impl_pipeline` Stage B 既存経路）への変更

## Open Questions

なし
