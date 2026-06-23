# Requirements Document

## 概要

`auto-merge` / `auto-merge-design` の Slack 通知は、現状 GitHub の auto-merge を **有効化（armed）** した時点で `result=success` として発火し、Slack 上で「merge 完了」と誤読される。実際には必須 status checks が green になるまで merge は実行されず、`codex-review` の `needs-iteration` 連発などで未 merge のまま放置されるケースがある。本要件では (a) **armed と merged を Slack 上で運用者が判別可能にする**、(b) **実 merge 完了を別イベントとして Slack 通知する**、の 2 点に修正範囲を限定する。既存 opt-in / fail-open / secret scrub の規約は継承する。

## In Scope / Out of Scope

### In Scope

- `auto-merge` / `auto-merge-design` の有効化（armed）通知について、Slack 受信者が「merge 完了ではない」と判別可能になるよう event 種別または文面を修正する
- 実 merge 完了を Slack に通知する新規イベントの追加（impl PR / design PR 双方）
- 同一 PR に対する merge 完了通知の重複抑止（idempotency）
- `SLACK_NOTIFY_ENABLED=false` の既存ユーザに対する後方互換維持
- README の Slack 通知 emitter 節と migration note の更新

### Out of Scope

- codex の連続 `needs-iteration` 自体の解消（別事象）
- `claude-pickup` 等の新規通知イベント追加（#390 で別 issue）
- promote-pipeline `staged-for-release` バグ（#389 で別 issue）
- Slack 以外の通知チャネル（メール / Discord / Teams 等）
- `failed-recovery` / `needs-decisions-auto-continue` / `promote` 通知の文面変更
- GitHub auto-merge の status checks 構成変更、branch protection 設定変更
- merge 完了検知タイミング・state 保持方式の決定（Developer 設計判断に委ねる）

## Requirements

### Requirement 1: armed 通知の誤読防止

**Objective:** As a watcher 運用者, I want auto-merge 有効化時の Slack 通知を「merge 完了」と読み間違えない表現にしたい, so that 必須 status checks が pending の PR を merged と勘違いせずに済む

#### Acceptance Criteria

1. When auto-merge processor が impl PR に対し `gh pr merge --auto` の有効化に成功した時点, the Slack Notify Emitter shall **「merge 有効化（armed）」であって「merge 完了」ではない**ことを Slack 受信者が判別可能な形式（event 種別 / 文面 / その併用のいずれか）で通知する
2. When auto-merge-design processor が design PR に対し `gh pr merge --auto` の有効化に成功した時点, the Slack Notify Emitter shall impl PR と同等に「merge 有効化（armed）」と「merge 完了」を判別可能な形式で通知する
3. The Slack Notify Emitter shall armed 通知本文において、必須 status checks が green に到達した後で初めて GitHub 側が merge を実行する旨を運用者が読み取れる表現にする
4. If 既存 callsite が `auto-merge` / `auto-merge-design` の armed イベントを発火する経路を変更する場合, the Slack Notify Emitter shall 引数検証（event_type enum / 数値 PR 番号 / fail-open）を従来同等水準で維持する

### Requirement 2: 実 merge 完了通知の追加

**Objective:** As a watcher 運用者, I want PR が実際に merge された時点で Slack 通知を受け取りたい, so that armed のまま停滞している PR と本当に完了した PR を Slack だけで区別できる

#### Acceptance Criteria

1. When watcher が auto-merge 経路で merge された impl PR の merge 完了を観測した時点, the Slack Notify Emitter shall 当該 PR について実 merge 完了を表す Slack 通知を 1 度送信する
2. When watcher が auto-merge-design 経路で merge された design PR の merge 完了を観測した時点, the Slack Notify Emitter shall 当該 PR について実 merge 完了を表す Slack 通知を 1 度送信する
3. The Slack Notify Emitter shall 同一 PR 番号の merge 完了通知を**運用ライフサイクルで 1 回のみ**送信し、後続サイクルでの再観測時に重複通知を出さない
4. If PR が auto-merge / auto-merge-design 経路を経ずに merge された場合（人間による直接 merge 等）, the Slack Notify Emitter shall 当該 PR の merge 完了 Slack 通知を発火しない
5. If merge 完了検知時に SLACK_NOTIFY_ENABLED が false / 未設定 / true 以外, the Slack Notify Emitter shall 外部副作用なしに silent return する
6. If SLACK_NOTIFY_ENABLED=true かつ SLACK_WEBHOOK_URL が未設定 / 空, the Slack Notify Emitter shall WARN ログ 1 行のみ残し fail-open で return する

### Requirement 3: 後方互換性と opt-in 戦略

**Objective:** As 既存 watcher ユーザ, I want 本修正導入前と運用挙動が壊れないことを保証されたい, so that watcher / Slack 受信者 / 監査ログを破壊的変更なしに継続運用できる

#### Acceptance Criteria

1. While SLACK_NOTIFY_ENABLED が false / 未設定 / true 以外（既定）, the Slack Notify Emitter shall 本修正の有無に関わらず外部副作用ゼロ（curl ゼロ・ログ 1 行追加なし）を維持する
2. The Slack Notify Emitter shall 既存 env var 名（`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT`）の意味と既定値を変更しない
3. The Slack Notify Emitter shall 既存 4 イベント（`failed-recovery` / `needs-decisions-auto-continue` / `promote` / `auto-merge-design` の design merge 文脈は本要件で armed/merged 区別の対象）の通知文面のうち、本要件で対象外のものは現状維持する
4. Where 本修正で armed 通知の文面または event_type が変更される場合, the Project documentation shall README の Slack 通知 emitter 節（`SLACK_NOTIFY_ENABLED` 行および解説）に、`SLACK_NOTIFY_ENABLED=true` 既存ユーザ向け migration note（armed 文面の変化 / merged 通知の新規発火）を同一 PR で追記する
5. If 本修正で新たな event_type を追加する場合, the Slack Notify Emitter shall 既存 event_type enum 検証ロジック（不正値 → WARN 1 行 + fail-open）と同形で扱う

### Requirement 4: 観測性と silent fail 禁止の継承

**Objective:** As watcher 運用者, I want Slack 通知周りのログと失敗時挙動が既存規約（fail-open / WARN 1 行 / secret scrub）に準拠していることを保証したい, so that 通知失敗が watcher 本体パイプラインを止めない・secret 漏洩しない

#### Acceptance Criteria

1. When merged 通知 / 修正後 armed 通知が成功した時点, the Slack Notify Emitter shall event 種別・PR 番号・result・http_status・host を含む構造化ログを 1 行出力する
2. If merged 通知 / 修正後 armed 通知の curl 呼び出しが HTTP 4xx/5xx / 非ゼロ exit / payload 整形失敗で失敗した場合, the Slack Notify Emitter shall WARN ログ 1 行のみ残し watcher 本体パイプラインに失敗を伝播させない
3. The Slack Notify Emitter shall payload 構築時に detail 文字列へ既存 `sn_scrub_secrets` 等価の secret scrub（GitHub token prefix / Slack webhook URL / 長尺英数字）を適用する
4. The Slack Notify Emitter shall Slack Incoming Webhook URL 実値をログ・コメント・テストフィクスチャに残さない

## Non-Functional Requirements

### NFR 1: Idempotency と重複抑止

1. The Slack Notify Emitter shall 同一 PR 番号に対する merge 完了 Slack 通知を、watcher の通常運用ライフサイクル内で 1 回のみ発火させる（state 保持方式は Developer 判断）
2. While watcher が cron 等で繰り返し起動する状況下, the Slack Notify Emitter shall 既に merged 通知済みの PR を再観測しても curl POST を再発火しない

### NFR 2: 観測性

1. The Slack Notify Emitter shall 成功通知 1 件あたり構造化ログを 1 行のみ出力し、stdout / stderr に冗長な debug 出力を残さない
2. If 通知失敗 / 不正引数 / preflight 失敗が発生した場合, the Slack Notify Emitter shall WARN ログ 1 行を `>&2` に出力する

### NFR 3: 外部依存とリソース上限

1. The Slack Notify Emitter shall 新規の外部 CLI 依存（curl / jq 以外）を追加しない
2. The Slack Notify Emitter shall 1 watcher サイクルあたりの merge 完了検知に伴う gh API 呼び出し回数に運用者が予測可能な上限を設ける（無制限ポーリング禁止 / 既定上限値は Developer 設計判断、ただし上限が**存在する**ことを要件で固定）
3. The Slack Notify Emitter shall curl の HTTP POST に `SLACK_NOTIFY_TIMEOUT`（既定 5 秒 / 非数値・負数は既定にフォールバック）を適用し、無制限待機しない

### NFR 4: 安全側 default

1. The Slack Notify Emitter shall 本要件で追加する判定ロジック（armed/merged 区別・重複抑止・新 event_type enum）のすべてで、`SLACK_NOTIFY_ENABLED` 未設定 / 不正値時に外部副作用ゼロで return する
2. If merge 完了の判定根拠（GitHub API の merged 状態など）が観測不能だった場合, the Slack Notify Emitter shall 偽陽性で merged 通知を発火させず、次サイクル以降に判定を委ねる

## Out of Scope（再掲・補足）

- merge 完了検知の具体的実装方式（cycle 内 `gh pr list --state merged --search` か state file 突合か）は Developer 判断
- 具体的な新 event_type 文字列・payload キー名・関数名は Developer 判断
- 人間が手動で `gh pr merge` した PR の通知方針は本要件で「auto-merge 経路外は通知しない」と固定（Requirement 2.4）
- design PR と impl PR で merged 通知の文面・event_type を共通化するか分離するかは Developer 判断（armed/merged 区別という user 価値が成立すればどちらでも可）

## 確認事項 / Open Questions

1. **merge 完了検知タイミング**: watcher の各サイクルで `gh pr list --state merged --search "merged:>...""` 相当を実行して直近 N 分以内の merged PR を検出する方式と、auto-merge enable 時に PR 番号を state file へ積み次サイクル以降で merged 化されたものだけを通知する方式のどちらを採るか。Developer 設計判断に委ねるが、本要件では「同一 PR に対する重複抑止」と「auto-merge 経路を経た PR のみ通知」を満たす必要がある
2. **state 保持の永続パス**: NFR 1.1 を満たす state ファイル配置は `$HOME/.issue-watcher/` 配下を推奨（CLAUDE.md §6 に準拠）するが、具体パス・命名は Developer 判断
3. **既存 armed 通知のスタンス**: armed 通知を「event_type を新名に分離する（破壊的変更）」「文面のみ修正して event_type は維持」「両方併用」のどれを採るかは Developer 判断。いずれの場合も Requirement 3.4 の migration note 更新は必須
4. **`auto-merge-design` の merged 通知発火条件**: design PR は merged 後に既存 [Design Review Release Processor (#40)](https://github.com/hitoshiichikawa/idd-claude/issues/40) で `awaiting-design-review` 除去等の後処理が走る。本要件では design PR の merged 通知を impl PR と同等に発火する（Requirement 2.2）方針だが、運用者が「design PR の merged 通知は不要」と判断するなら別途 issue で取り下げ可能
5. **`failed-recovery` 等の他イベントへの波及**: 本要件は `auto-merge` / `auto-merge-design` の armed/merged 区別に限定する。`failed-recovery` の `success` / `recovered` 等の result 文字列に同種の誤読リスクがあるかは未調査（必要なら別 issue）

## 関連

- Depends on: なし
- Related: #370（Slack 通知 emitter 本体 / D-18）, #352（Auto-Merge Processor）, #354（Design Auto-Merge Processor）, #40（Design Review Release Processor）
- Sibling: #389（promote-pipeline staged-for-release バグ）, #390（`claude-pickup` 通知追加）
