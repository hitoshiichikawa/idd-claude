# Requirements Document

## Introduction

GitHub ネイティブの auto-merge を arm（`gh pr merge --auto`）した実装 PR が、その後 `claude-failed` /
`needs-decisions` といった terminal ラベルへ遷移しても disarm されず、必須 status checks が全 green に
到達した瞬間に「失敗確定済み PR」が merge されてしまう不具合を解消する。本不具合は 2 つの欠陥の複合で
発生する。Defect A（主因）は `claude-failed` / `needs-decisions` の除外判定が arm 時点のワンショットに
留まり、arm 後の遷移を取り消す経路（disarm）が watcher に存在しないこと。Defect B（誘発因）は terminal
ラベル確定後でも in-flight だった Reviewer が `claude-review=success` を publish してしまい、merge gate が
失敗済み PR に対して緑になることである。本要件は「arm 後の terminal 遷移を disarm する振る舞い」と
「terminal PR に対し claude-review=success を緑にしない fail-closed 修正」を、既存 auto-merge の opt-in
gate と後方互換性を壊さない形で規定する。

## Requirements

### Requirement 1: arm 後の terminal 遷移に対する disarm

**Objective:** As a watcher 運用者, I want arm 済みの auto-merge を PR が terminal ラベルへ遷移した時点で取り消したい, so that 失敗確定済みの PR が status checks の green 到達で誤って merge されるのを防げる

#### Acceptance Criteria

1. When arm 済み（`autoMergeRequest != null`）の open PR が `claude-failed` ラベルを持つ状態を watcher が観測したとき, the Auto-Merge Disarm Process shall その PR の native auto-merge を取り消す（`autoMergeRequest` を null へ戻す）
2. When arm 済みの open PR が `needs-decisions` ラベルを持つ状態を watcher が観測したとき, the Auto-Merge Disarm Process shall その PR の native auto-merge を取り消す
3. When arm 済みの open PR が `claude-failed` と `needs-decisions` の双方を持つ状態を watcher が観測したとき, the Auto-Merge Disarm Process shall その PR の native auto-merge を取り消す
4. While disarm 対象 PR を判定するとき, the Auto-Merge Disarm Process shall GitHub を直接クエリして対象を列挙し、`SLACK_NOTIFY_MERGED_ENABLED` に依存する pending state dir の有無に振る舞いを左右されない
5. When PR が `claude-failed` も `needs-decisions` も持たない arm 済みの状態であるとき, the Auto-Merge Disarm Process shall その PR の auto-merge を取り消さない

### Requirement 2: disarm の冪等性と異常系

**Objective:** As a watcher 運用者, I want disarm を毎サイクル安全に再実行できる状態にしたい, so that 既に解除済み・merge 済み・未 arm の PR を壊さず、API 失敗でパイプラインが止まらない

#### Acceptance Criteria

1. When 対象 PR が既に disarm 済み（`autoMergeRequest == null`）であるとき, the Auto-Merge Disarm Process shall 追加の disarm 副作用を行わず no-op とする
2. When 対象 PR が既に merge 済み（open でない）であるとき, the Auto-Merge Disarm Process shall その PR を disarm 対象から除外する
3. When disarm 対象に該当する PR が同一サイクル内に存在しないとき, the Auto-Merge Disarm Process shall 外部副作用なしでサイクルを終える
4. If disarm の取り消し呼び出しが失敗したとき, the Auto-Merge Disarm Process shall WARN ログを 1 行残してパイプラインを継続する（fail-open）
5. While 複数の disarm 対象を処理するとき, the Auto-Merge Disarm Process shall 1 件の失敗で残りの対象処理を中断しない

### Requirement 3: terminal PR に対する claude-review publish の fail-closed 化

**Objective:** As a watcher 運用者, I want terminal ラベルが付いた PR には claude-review=success を publish しないようにしたい, so that 失敗確定後に in-flight の Reviewer が merge gate を誤って緑へ戻すのを防げる

#### Acceptance Criteria

1. When PR が `claude-failed` ラベルを持つ状態で claude-review=success の publish が試みられたとき, the Claude Review Publisher shall その success を merge gate 上で緑にしない（fail-closed）
2. When PR が `needs-decisions` ラベルを持つ状態で claude-review=success の publish が試みられたとき, the Claude Review Publisher shall その success を merge gate 上で緑にしない
3. When 裁定経路（adjudicator の status decision 適用）から terminal ラベル付き PR への claude-review=success publish が導出されたとき, the Adjudicator Status Decision shall その success を merge gate 上で緑にしない
4. When catch-up 経路（branch 上の review-notes.md から claude-review status を publish する経路）から terminal ラベル付き PR への claude-review=success publish が試みられたとき, the Claude Review Catch-up Publisher shall その success を merge gate 上で緑にしない
5. When PR が terminal ラベルを持たない通常状態で claude-review status の publish が試みられたとき, the Claude Review Publisher shall 従来どおり approve/reject に応じた status を publish する

### Requirement 4: claude-failed / needs-decisions の terminal ラベル判定取得

**Objective:** As a watcher 運用者, I want publish 直前の terminal 判定がラベル取得失敗時にも安全側で振る舞ってほしい, so that gh 取得失敗で既存挙動が壊れたり可用性が落ちたりしない

#### Acceptance Criteria

1. When claude-review=success の publish 直前に PR の terminal ラベル有無を判定するとき, the Claude Review Publisher shall 当該 PR の現在のラベル集合を再取得して判定する
2. If terminal ラベルの再取得が失敗したとき, the Claude Review Publisher shall 従来どおり publish を継続する（fail-open / 可用性優先）
3. If terminal ラベルの再取得が失敗したとき, the Claude Review Publisher shall その旨を WARN ログで 1 行残す

## Non-Functional Requirements

### NFR 1: 後方互換性と opt-in gate

1. While auto-merge の opt-in gate（`AUTO_MERGE_ENABLED=true` AND `FULL_AUTO_ENABLED=true`）が成立していないとき, the Auto-Merge Disarm Process shall `gh pr merge --disable-auto` を含む一切の外部副作用を発生させない
2. While auto-merge の opt-in gate が成立していないとき, the watcher shall 本不具合修正の導入前と完全に同一の挙動（no-op）を保つ
3. The Claude Review Publisher fail-closed 修正 shall 既存の claude-review publish opt-in gate（`PR_REVIEWER_STATUS_CHECK_ENABLED` 系）の内側で動作し、新たな外部サービス呼び出し用 gate を追加しない

### NFR 2: 未信頼入力ハードニング

1. When PR 番号を URL・git revision・gh 引数として使用する直前, the watcher shall その値を `^[0-9]+$` で検証してから使用する
2. When 未信頼値を `gh` コマンドへ渡すとき, the watcher shall `--` でオプション解釈を打ち切ってフラグ注入を防ぐ
3. When 未信頼値を `jq` フィルタへ渡すとき, the watcher shall `--arg` / `--argjson` で渡しフィルタ文字列へ inline 展開しない

### NFR 3: 可観測性

1. When disarm を実行したとき, the Auto-Merge Disarm Process shall 対象 PR 番号と動作（disarmed）を含むログ行を 1 件出力する
2. While disarm 対象が 0 件のとき, the Auto-Merge Disarm Process shall サイクルあたり過剰なログを出さず最大 1 行のサマリに留める

### NFR 4: 配布物同期とドキュメント

1. Where 本不具合修正が consumer 配布物（modules / workflow / labels）に変更を及ぼす場合, the Delivery Process shall root と repo-template の両系統へ byte 一致で反映し `diff -r` が空である状態を保つ
2. When 本不具合修正で外部から観測可能な挙動が変わったとき, the Delivery Process shall 同一 PR 内で README の該当箇所を更新する

## Out of Scope

- arm 時点判定（`am_should_enable_for_pr`）の強化（iteration サイクル中の arm 抑止など）。本修正は arm 後の disarm と publish 側の fail-closed に限定する
- `claude-failed` / `needs-decisions` 以外の terminal 状態の追加（既存 terminal ラベル集合を変更しない）
- disarm の実装手段の確定（専用 processor 配置か既存処理への inline か、専用 env gate の新設か既存 `AUTO_MERGE_ENABLED` 相乗りか）。これらは design / Developer の領分であり、本要件は外部から観測可能な振る舞い（disarm されること / 冪等であること / Slack gate 非依存であること / gate OFF で副作用ゼロであること）のみを規定する
- Defect B の修正方式（success を skip するか `failure` を明示 publish するか）の確定。本要件は「terminal PR に対し claude-review=success を merge gate 上で緑にしない（fail-closed）」を AC とし、具体的手段は design / Developer に委ねる
- 既に merge 済み（過去に誤 merge された）PR の事後 revert / 復旧
- Slack 通知文面の変更（armed/merged 通知の挙動は #388 の現行仕様を維持）

## Open Questions

- なし（Issue 本文の「確認事項」3 点は、本要件で次のとおり決定として落とした: disarm 発火主体は GitHub 直接クエリ方式の振る舞いを AC 化し実装手段は Out of Scope へ退避、Defect B は fail-closed を AC 化し skip/failure の選択は Out of Scope へ退避、`needs-decisions` も disarm 対象に含める。Issue コメントに人間の確定コメントは無いことを確認済み）

## 関連

- Related: #352 #388 #404 #407 #349
