# Requirements Document

## Introduction

KeyNest #91 の失敗事例分析では、Developer エージェントが `tasks.md` とは独立に内部
TaskCreate / TaskUpdate ツールで進捗を二重 tracking しており、TaskCreate 11 回 + TaskUpdate
19 回 の合計 30 回が全 tool call の 29% を占めて turn budget を消費していた。原因は (a)
Developer エージェント定義に「内部 TODO ツールでの task tracking を抑制する明示的な指示」が
無いこと、(b) 「task tools haven't been used recently」という system reminder が defensive な
TaskCreate を誘発していること、(c) 進捗追跡の代替手段（tasks.md checkbox 編集）が現行の
`developer.md` では暗黙的にしか示されていないことにある。

サブ Issue #133 で `tasks.md` の checkbox 形式必須化と Developer エージェント定義への
「checkbox 編集で進捗を表現する規約」が既に提供されている。本 Issue では追加で、Developer
エージェント定義に **TaskCreate / TaskUpdate の使用を「tasks.md にない緊急対応のみ」に
明示的に制限する規約** を導入し、umbrella Issue #132 が掲げる「内部 task tracking 由来の
overhead を 29% から 10% 以下に削減する」目標の達成を狙う。harness 側 (Claude Code SDK)
での subagent-specific reminder 抑制は best effort 扱いとし、エージェント定義側の prompt
強化だけで成立する設計とする。

## Requirements

### Requirement 1: developer.md における TaskCreate / TaskUpdate 使用制限の明文化

**Objective:** As a Developer agent, I want エージェント定義に TaskCreate / TaskUpdate の許容ケースが明示されている, so that tasks.md の二重 tracking を回避し、tool call 予算を実装本体に集中させられる

#### Acceptance Criteria

1. The `developer.md` shall 「`tasks.md` は唯一のタスクリストであり、TaskCreate でタスクリストを複製してはならない」旨を明示する
2. The `developer.md` shall TaskCreate / TaskUpdate の使用が許容されるケースを限定列挙する
3. Where 許容ケースを列挙する場合, the `developer.md` shall 少なくとも「tasks.md に存在しない緊急の sub-step（failing test の調査など複数 turn にまたがる別軸の作業）」と「conversation 内で人間から追加依頼が入った場合」の 2 ケースを含む具体例を提示する
4. If `tasks.md` に既に対応するタスク行が存在する場合, the `developer.md` shall 当該タスクのために TaskCreate を呼び出すことを禁止する旨を明示する
5. The `developer.md` shall 進捗の正本は `tasks.md` の `- [ ]` → `- [x]` 編集であり、TaskCreate / TaskUpdate を進捗の正本として用いない旨を明示する

### Requirement 2: defensive 応答の抑止規約

**Objective:** As a Developer agent, I want system reminder への反射的な TaskCreate を抑止する明示的な指示を持つ, so that 「task tools haven't been used recently」reminder で意図せず内部 task list を作成しない

#### Acceptance Criteria

1. The `developer.md` shall 「task tools haven't been used recently」を含む system reminder に対して反射的に TaskCreate を呼ばないことを明示する
2. When 同種の reminder を受領したとき, the Developer agent shall 当該 reminder を進捗追跡手段の変更指示として扱わず、tasks.md checkbox 編集を維持する
3. If reminder を受領した上で TaskCreate を呼ぶ場合, the Developer agent shall Requirement 1 の許容ケース（緊急 sub-step / 人間からの追加依頼）に該当する場合のみに限定する

### Requirement 3: harness 側 reminder 抑制の取り扱い (best effort)

**Objective:** As a watcher operator, I want harness 側で subagent-specific reminder の抑制が可能かを判定し、可能ならば Developer subagent 起動時にのみ抑制を適用する, so that エージェント定義の prompt 強化に加えて二重防御が利き、それでも prompt 強化単独で要件が成立する状態を保つ

#### Acceptance Criteria

1. Where Claude Code SDK で subagent 別の system reminder 抑制が技術的に可能である場合, the harness shall Developer subagent 起動時に該当 reminder を off にする
2. If Claude Code SDK で subagent 別の reminder 抑制が技術的に不可能である場合, the harness shall 抑制を試行せず、Requirement 1 / 2 の prompt 強化のみで要件成立とする
3. The harness shall reminder 抑制機構の有無に関わらず、Developer エージェント定義 (Requirement 1 / 2) 単独で本要件の振る舞いが成立する状態を維持する
4. When 抑制機構が利用可能と判明したとき, the harness shall 抑制適用範囲を Developer subagent に限定し、他エージェント（PM / Architect / Reviewer / PjM）の挙動には影響を与えない

### Requirement 4: 計測と効果検証

**Objective:** As a watcher operator, I want 本 Issue merge 後に Developer 実行ログから TaskCreate / TaskUpdate の使用比率を計測する手段がある, so that umbrella #132 の目標（29% → 10% 以下）に対する達成度を可視化できる

#### Acceptance Criteria

1. After 本要件 merge 後の Developer 実行ログを取得した場合, the watcher operator shall TaskCreate と TaskUpdate の呼び出し回数および全 tool call 数を集計可能な状態を維持する
2. The 計測結果 shall TaskCreate + TaskUpdate の呼び出し回数が全 tool call の **10% 以下** となることを達成目標とする
3. If 計測結果が 10% を上回り続ける場合, the watcher operator shall 追加対策（developer.md の追加強化 / harness 側抑制の再検討等）を別 Issue として起票する
4. The 計測手段 shall 既存の Developer 実行ログ (`local-watcher/log/` 配下等) から手動集計で算出可能な粒度を要求し、自動ダッシュボードの実装は本要件のスコープに含めない

### Requirement 5: 受入確認シナリオ

**Objective:** As a repository maintainer, I want 本要件の振る舞いを確認するための受入シナリオが定義されている, so that PR レビュー時 / merge 後の効果確認時に同一基準で評価できる

#### Acceptance Criteria

1. When tasks.md に列挙された全タスクのみで完結する Developer 実行シナリオを実施したとき, the Developer agent shall TaskCreate を 0 回または極めて低頻度（全 tool call の 10% 以下）に抑える
2. When tasks.md に無い緊急 sub-step（例: 既存テスト failing の調査）が発生する Developer 実行シナリオを実施したとき, the Developer agent shall 当該 sub-step の tracking のために TaskCreate を呼んでも許容される
3. When conversation 内で人間から追加依頼（tasks.md に未記載）が入る Developer 実行シナリオを実施したとき, the Developer agent shall 当該追加依頼の tracking のために TaskCreate を呼んでも許容される
4. If 上記シナリオ 1 で TaskCreate 使用比率が 10% を超えた場合, the repository maintainer shall 結果を Issue / PR コメントに記録し、追加調整の要否を判断する

### Requirement 6: 後方互換性とテンプレ配布の整合

**Objective:** As a consumer repository maintainer, I want 本変更が既に install.sh で配置された他 repo の Developer エージェントに対して破壊的影響を与えない, so that 既存運用の Developer 振る舞いを壊さずに新規規約のみ追加できる

#### Acceptance Criteria

1. The `developer.md` 更新内容 shall 既存の「impl-resume / tasks.md 進捗追跡規約」節の振る舞いと矛盾しない
2. The `developer.md` 更新内容 shall 既存の Feature Flag Protocol 採否判定フロー（opt-in / opt-out）を改変しない
3. While `install.sh` 経由で `repo-template/.claude/agents/developer.md` が consumer repo に配布される状態, the 更新後の `developer.md` shall 既存の Developer エージェント tool 一覧（Read, Write, Edit, Bash, Grep, Glob）を変更しない
4. The 更新後の `developer.md` shall #133 で導入済みの「タスク完了は checkbox 編集で表現する」規約と矛盾せず、同規約への参照または再掲によって整合性を維持する
5. When 本要件 merge 後に consumer repo で `install.sh` を再実行したとき, the install.sh shall `developer.md` のハイブリッド safe-overwrite 配置（差分があれば `.bak` once-only 退避 + 上書き）の既存挙動で更新可能な状態を維持する

## Non-Functional Requirements

### NFR 1: ドキュメント整合性と言語非依存性

1. The 更新後の `developer.md` shall `tasks-generation.md` / `design-review-gate.md` / `feature-flag.md` / `ears-format.md` / `requirements-review-gate.md` のいずれとも矛盾する記述を含まない
2. The 更新後の `developer.md` shall 言語非依存（特定のアプリケーション実装言語に依存しない記述）であることを保つ
3. The 更新後の `developer.md` shall サブ Issue #133 で更新済みの「impl-resume / tasks.md 進捗追跡規約」節と物理的に重複しない（同一規約の二重記載を避け、参照または相互リンクで整合性を取る）

### NFR 2: 検証可能性

1. The 更新後の `developer.md` shall 「TaskCreate / TaskUpdate の使用制限」「許容ケースの限定列挙」「reminder への defensive 応答禁止」「進捗の正本は checkbox」の 4 つの規約が独立して grep 可能なキーワードで明示されている状態を保つ
2. The 計測結果 shall Developer 実行ログから第三者が手動集計で 30 分以内に算出できる粒度を持つ

### NFR 3: self-hosting (dogfooding) 整合

1. The 更新後の `developer.md` shall idd-claude 自身の Developer 実行（self-hosting）でも新規定義に従って動作する状態を保つ（本リポジトリ自身が次回 cron 実行で本ファイルを参照する）

## Out of Scope

- `tasks.md` checkbox 形式の必須化およびその Mechanical Check（#133 で別途実装済み）
- parallel tool call 規律の見直し（umbrella #132 のサブ Issue として別途扱う）
- 他エージェント定義（`product-manager.md` / `architect.md` / `reviewer.md` / `project-manager.md` / `debugger.md`）における TaskCreate / TaskUpdate 制限（本 Issue は Developer に限定）
- Claude Code SDK 自体への subagent-specific reminder 抑制機能の追加実装（SDK 側で既に提供されていない場合は best effort で見送る）
- Developer 実行ログから TaskCreate / TaskUpdate 比率を自動集計するダッシュボード / メトリクス基盤の構築
- 既に merge 済みの過去 Developer 実行（ログ / PR）への遡及的な計測・是正
- 「緊急 sub-step」の自動判定機構（人間 / Developer 自身による判断に委ねる）
- TaskCreate / TaskUpdate のハード制限（ツール無効化）— エージェント側 prompt と harness side reminder 抑制での soft enforcement に留める

## Open Questions

以下の論点は Issue 本文の「確認事項」として既に列挙されており、現時点で人間からの追加
コメントが付いていない。PM 判断としての暫定 stance を以下に示す（後段の Architect /
Developer の判断材料）:

1. **「緊急 sub-step」の判定基準と具体例の数**
   - **暫定 stance**: `developer.md` には「tasks.md に存在しない緊急の sub-step」「conversation 内での人間からの追加依頼」の **2 ケース** を最低限の具体例として提示する。さらに具体例を増やす（例: 別プロセスで発生した CI failure の追跡 / 一時的な調査 spike 等）かは Architect 判断に委任する
   - **判断委任先**: Architect（具体例の文言と件数は design.md で確定）

2. **Claude Code SDK での subagent-specific reminder 抑制の技術可否**
   - **暫定 stance**: 技術的に可能であれば Requirement 3.1 を適用、不可能であれば Requirement 3.2 に倒れる設計のため、現時点で SDK ドキュメント未確認のままでも要件は成立する。Architect / Developer の調査タイミングで判明した結果に応じて harness 側の対応有無を確定する
   - **判断委任先**: Architect / Developer（SDK 調査結果に応じて design.md または impl-notes.md に確定記載）

3. **#133 と本 Issue の merge 順**
   - **暫定 stance**: #133（checkbox enforce + 進捗の正本としての checkbox 規約）が **先に merge 済み**（本リポジトリの最新 main を参照）であるため、本 Issue は #133 の規約を前提として #133 の規約と矛盾しない形（NFR 1.3 / Req 6.4）で developer.md を追加更新する。merge 順の論点は実質的に解消済み
   - **判断委任先**: 人間（必要なら別 Issue で順序前提の再確認）

4. **計測手段の自動化レベル**
   - **暫定 stance**: 本要件では手動集計（Developer 実行ログを grep / 目視）で 10% ラインの達成判定が可能な粒度を要求するに留め、自動ダッシュボード化は別 Issue とする (Req 4.4 / Out of Scope)
   - **判断委任先**: 人間運用者（必要なら自動化を別 Issue として起票）

なお、これらの暫定 stance は requirements.md 自身の AC として束縛しない方針とし、AC では
スコープ境界（Out of Scope）と best effort 扱いの明示（Req 3.2）のみを束縛している。
