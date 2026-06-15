# Requirements Document

## Introduction

idd-claude の Dependency Resolver Gate（#146）は、Issue 本文の依存マーカー（canonical `Depends on:` / alias `前提依存:` / `Blocked by:`）を解析して、未解決依存が 1 件以上ある Issue に `blocked` ラベルを自動付与する。一方、依存先がすべて merge / staged-for-release 等で解決した後の `blocked` ラベル除去は **完全に手動** であり、運用者が気づかない限り Issue が滞留し auto-dev pickup から除外され続ける（dispatcher 候補クエリで `-label:"blocked"` 除外がかかるため）。

本機能は、watcher の cron tick 内で **依存解決済み Issue の blocked ラベルを自動解除するスイープ** を追加することで、依存マーカー付与から解除までを 1 つのライフサイクルとして自動化する。既存挙動の後方互換性を最優先とし、env var による opt-in gate（既定 OFF）で導入する。空依存マーカー Issue は安全側で手動対応に倒し、人間に気づかせるための 1 回限りの通知コメントを投稿する。解除時には監査証跡として GitHub UI から経緯を追えるよう自動解除コメントを投稿する。

## Requirements

### Requirement 1: Opt-in Gate と後方互換性

**Objective:** As a idd-claude 運用者, I want unblock スイープを env var の明示的な opt-in でのみ起動できる, so that 既存運用への影響をゼロにしたまま段階的に有効化できる

#### Acceptance Criteria

1. When watcher cron tick が起動し、Architect が確定する opt-in env var の値が `true` のとき, the watcher shall unblock スイープを当該 tick 内で実行する
2. While opt-in env var が未設定 / 空文字 / `true` 以外の任意の値（`false` / `0` / typo を含む）であるとき, the watcher shall unblock スイープを実行せず、本機能導入前と完全に同一の挙動を保つ
3. If opt-in env var が不正値（`true` 以外）であるとき, the watcher shall 当該値を安全側（無効）に正規化し、`blocked` 解除に関する gh API 呼び出しを一切行わない
4. The watcher shall 既存 env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 / 既存ログ出力先に対して破壊的変更を加えない

### Requirement 2: スイープ対象 Issue の列挙

**Objective:** As a watcher, I want unblock 評価対象を auto-dev かつ blocked が付与された OPEN Issue に限定したい, so that 終端状態の Issue や対象外 Issue を誤って再評価しない

#### Acceptance Criteria

1. When スイープが実行されるとき, the watcher shall `auto-dev` ラベルと `blocked` ラベルが付与された OPEN 状態の Issue を対象として列挙する
2. While Issue に `claude-failed` などの終端ラベルが付与されているとき, the watcher shall 当該 Issue を対象から除外する
3. When スイープが対象 Issue を列挙するとき, the watcher shall dispatcher のメイン候補クエリより **前段** で実行し、解除された Issue が同一 tick または次 tick で通常 pickup に合流できるようにする

### Requirement 3: 依存全解決時の自動解除

**Objective:** As a 運用者, I want 依存先がすべて解決した Issue から blocked ラベルを自動的に外したい, so that 手動オペレーション無しで auto-dev フローが再開する

#### Acceptance Criteria

1. When 対象 Issue の本文から抽出した依存先がすべて `dr_resolve_one` で `resolved` と判定されたとき, the watcher shall 当該 Issue から `blocked` ラベルを除去する
2. When 当該 Issue から `blocked` ラベルが除去されたとき, the watcher shall 自動解除コメントを当該 Issue に 1 件投稿する
3. The 自動解除コメント shall 監査証跡として、解除の経緯（依存全解決による自動解除である旨）を GitHub UI から読み取れる文面を含む
4. If `blocked` 除去操作（gh API）が失敗したとき, the watcher shall 自動解除コメントを投稿せず、ラベル状態を変更しないまま当該 Issue を skip する

### Requirement 4: 依存未解決時の維持

**Objective:** As a watcher, I want 1 件でも依存が未解決の Issue は blocked のまま維持したい, so that 既存の依存ゲート契約と矛盾しない

#### Acceptance Criteria

1. If 対象 Issue の依存先のうち 1 件以上が `open` / `closed unmerged` / `api error` と判定されたとき, the watcher shall `blocked` ラベルを除去せず、自動解除コメントも投稿しない
2. If `dr_resolve_one` が未知の verdict を返したとき, the watcher shall 安全側で「未解決」とみなし、`blocked` ラベルを維持する
3. While 1 件以上の依存が未解決として残るとき, the watcher shall 当該 Issue に対して新たなエスカレーションコメントを再投稿しない

### Requirement 5: 空依存マーカーの取り扱い

**Objective:** As a 運用者, I want 依存マーカーが本文から消失した blocked Issue は自動解除せず通知だけ受け取りたい, so that 依存記法の意図せぬ削除や編集ミスによる自動解除を防止できる

#### Acceptance Criteria

1. If `dr_extract_deps` が対象 Issue 本文に対して空（依存マーカーゼロ）を返したとき, the watcher shall `blocked` ラベルを除去せず維持する
2. If 当該 Issue に本機能由来の通知マーカーが未投稿のとき, the watcher shall 「依存マーカー消失により自動解除されない」旨の通知コメントを 1 件だけ投稿する
3. While 当該 Issue に本機能由来の通知マーカーが既に投稿済みのとき, the watcher shall 通知コメントを再投稿しない
4. The 通知コメント shall 本機能由来であることを判定できる識別子（HTML コメント等、形式は実装裁量）を含み、後続 tick の冪等性判定に利用できる

### Requirement 6: 冪等性

**Objective:** As a 運用者, I want スイープを連続実行しても観測可能な副作用が累積しないことを保証したい, so that cron tick 頻度の変更や再実行で運用が壊れない

#### Acceptance Criteria

1. When スイープが同一 Issue に対して連続 N 回実行されるとき, the watcher shall 解除条件を満たす Issue に対するラベル除去・自動解除コメント投稿を合計 1 回に収束させる
2. When スイープが解除条件を満たさない（依存未解決 or 空依存マーカー通知済み）Issue を評価したとき, the watcher shall ラベル変更・コメント投稿を一切行わない
3. While スイープが評価のみを行うとき, the watcher shall gh API 呼び出しを read（依存状態確認）に限定し、write 系 API を呼び出さない

### Requirement 7: 監査ログ

**Objective:** As a 運用者, I want スイープ各分岐の判定理由を構造化ログから追跡したい, so that 想定外挙動の調査やラベル状態の説明責任を果たせる

#### Acceptance Criteria

1. When スイープが「依存全解決による解除」を実行したとき, the watcher shall 既存 `dr_log` と同形式の構造化ログを 1 行出力する
2. When スイープが「空依存マーカー通知」を実行したとき, the watcher shall 既存 `dr_log` と同形式の構造化ログを 1 行出力する
3. When スイープが「1 件以上の依存未解決により blocked 維持」と判定したとき, the watcher shall 既存 `dr_log` と同形式の構造化ログを 1 行出力する
4. When スイープが gh API 呼び出しに失敗したとき, the watcher shall 既存 `dr_warn` と同形式の警告ログを 1 行出力する

### Requirement 8: 既存エスカレーションコメント文面の整合

**Objective:** As a 運用者, I want gate 有効時に「blocked を手動で除去してください」案内が実態と乖離しないようにしたい, so that 利用者が誤って手動除去を試みず、自動解除に委ねられる

#### Acceptance Criteria

1. When opt-in env var が `true` のとき、Dependency Resolver Gate が新たに `blocked` を付与した Issue に投稿するエスカレーションコメント, the watcher shall 「依存解消後に自動で外れます」相当の文面分岐を採用する
2. While opt-in env var が未設定 / `true` 以外のとき, the watcher shall 既存のエスカレーションコメント文面（「手動で除去してください」案内）を維持する

### Requirement 9: 配布範囲とドキュメント

**Objective:** As a メンテナ, I want 本機能の変更範囲を local-watcher 単体に限定しつつ、README へ挙動変更を反映したい, so that consumer repo（template 配布対象）への影響を最小化し、運用者が機能を把握できる

#### Acceptance Criteria

1. The watcher 実装変更 shall `local-watcher/bin/issue-watcher.sh` および同階層 `modules/` 配下に限定し、`repo-template/**` および `.claude/` 配下の同期対象には変更を加えない
2. When 本機能が PR として提出されるとき, the maintainer shall README の該当節（オプション機能一覧 / ラベル状態遷移まとめ 等）を同一 PR で更新する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While opt-in env var が未設定 or `true` 以外のとき, the watcher shall 本機能導入前と完全に同一の cron tick 挙動を保つ（gh API 呼び出し回数・ログ出力・ラベル遷移すべて一致）
2. The watcher shall 既存の `LABEL_BLOCKED` / `LABEL_TRIGGER`（`auto-dev`）/ `dr_*` 関数群の signature・戻り値契約を変更しない

### NFR 2: 性能

1. While スイープが対象 Issue ゼロ件を確認したとき, the watcher shall 追加の gh API 呼び出しゼロで処理を完了する（候補列挙の 1 クエリのみ）
2. When スイープが N 件の対象 Issue を処理するとき, the watcher shall 1 Issue あたりの追加 gh API 呼び出しを「依存件数 + 解除時のラベル更新 1 + コメント投稿 1」の上限内に収める

### NFR 3: 安全性 / フェイルセーフ

1. If 依存解決 API（`dr_resolve_one`）が `api error` を返したとき, the watcher shall 当該 Issue を「未解決扱い」として `blocked` を維持する
2. If gh API の write 操作（ラベル除去 / コメント投稿）が失敗したとき, the watcher shall 当該 Issue の状態を破壊せず（ラベル除去のみ成功してコメント未投稿等の中途半端な状態を残さず）、警告ログを残して次の Issue へ進む

### NFR 4: 監査性

1. The watcher shall スイープ各 Issue の判定結果（解除 / 維持 / 空マーカー通知 / api error）を構造化ログ 1 行で記録し、ログ grep で経緯を再構成できる
2. The watcher shall 自動解除した Issue に対して、GitHub UI 上のコメント履歴から「watcher による自動解除である」と判別できる証跡を残す

### NFR 5: 冪等性

1. When スイープが同一 Issue に対して連続 2 回以上実行されるとき, the watcher shall 観測可能な副作用（ラベル変化 / コメント増分）を最初の 1 回に収束させる

## Out of Scope

- `blocked` 以外のラベル（`needs-decisions` / `claude-failed` / `needs-iteration` 等）の自動解除
- 依存記法（`Depends on:` / `前提依存:` / `Blocked by:`）の構文拡張・新規エイリアス追加
- 依存グラフの可視化・通知連携（Slack / Discord webhook 等）
- `needs-decisions` 由来のブロック解除（人間判断要求の自動解消）
- 依存先 Issue の状態変化を watcher tick 外でリアルタイム検知する仕組み（GitHub webhook 等）
- `repo-template/**` / `.claude/{agents,rules}/` 同期（本機能は local-only モジュールで完結する）

## Acceptance Test Cases（受入テスト観点）

以下のテストケースを最低限カバーすること。各ケースの実装可否（unit test / 手動スモークテスト）の選択は Developer 裁量。

| ID | 状態 | gate | 期待挙動 | 検証手段の例 |
|---|---|---|---|---|
| AT-a | 全依存 resolved | ON | `blocked` 除去 + 自動解除コメント 1 件投稿 | unit test（gh stub） |
| AT-b | 1 件以上 unresolved | ON | ラベル変化なし・コメント投稿なし | unit test（gh stub） |
| AT-c | gate OFF（未設定 / 不正値 / `false`） | OFF | スイープ自体走らない・gh API 呼び出しゼロ | unit test（gate 正規化） |
| AT-d | 空依存マーカー + 未通知 | ON | 通知コメント 1 件のみ投稿・`blocked` 維持 | unit test（gh stub） |
| AT-e | 空依存マーカー + 通知済み | ON | コメント投稿なし・`blocked` 維持（冪等） | unit test（通知マーカー検出） |
| AT-f | 連続 2 回スイープ実行 | ON | 副作用が最初の 1 回に収束（累積なし） | unit test（gh stub の call count） |
| AT-g | ラベル除去成功 + コメント投稿失敗 | ON | 警告ログ 1 行・次 Issue へ進む | unit test（gh stub failure 注入） |
| AT-h | エスカレーションコメント文面分岐 | ON / OFF | gate ON で「自動で外れます」、OFF で従来文面 | unit test（gate 別出力差分） |

## 関連

- Depends on: #146
- Related: #316

## Open Questions

- opt-in env var 名は **Architect 確定事項**（候補: `DEP_AUTO_UNBLOCK_ENABLED`）。本要件は env var 名そのものではなく「Architect が確定する opt-in env var」として参照する
- 空依存マーカー通知コメントの「通知済み」判定マーカー文字列（HTML コメント識別子等）の具体形は Developer 実装裁量。ただし本機能由来であることが判定できる識別子を必ず含めること
- 自動解除コメントの文面 tone、および解除サマリ（どの依存が `resolved` だったかを列挙するか / 単に「全依存解決」と要約するか）は Developer 実装裁量
