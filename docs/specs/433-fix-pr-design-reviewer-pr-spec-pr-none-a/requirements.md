# Requirements Document

## Introduction

Design PR Reviewer（`pr-design-reviewer.sh` / #407）は、設計 PR の spec 本文（`docs/specs/<N>-<slug>/{requirements,design,tasks}.md`）を `cat` でローカル作業ツリーから読む。しかし watcher の作業ツリーは base ブランチにチェックアウトされており、新規設計 PR の spec ファイルは head ブランチにしか存在しない。このため 3 観点の入力がすべて `(none)` となり、Reviewer は「ファイル不在 → 保守的 approve」で空虚な approve（ラバースタンプ）を返し、設計 PR が実レビューなしで auto-merge される。本要件は spec 本文を head ブランチの git ref から取得するよう正し、取得不能時に approve しない（fail-closed）方向へ反転することで、Design PR Reviewer を merge ゲートとして実効化する。本修正は #432（既定 ON 化）の前提となるバグ修正である。

## Requirements

### Requirement 1: spec 本文を head ブランチの git ref から取得する

**Objective:** As a 設計 PR Reviewer 運用者, I want spec 本文を head ブランチの git ref から取得すること, so that 新規設計 PR でも作業ツリーに未マージのまま正しい spec 本文をレビュー入力にできる

#### Acceptance Criteria

1. When Design PR Reviewer が 1 つの設計 PR を判定するために spec 本文を取得するとき, the Design PR Reviewer shall head ブランチの git ref（`origin/<head_ref>`）から `requirements.md` の本文を取得する
2. When Design PR Reviewer が 1 つの設計 PR を判定するために spec 本文を取得するとき, the Design PR Reviewer shall head ブランチの git ref（`origin/<head_ref>`）から `design.md` の本文を取得する
3. When Design PR Reviewer が 1 つの設計 PR を判定するために spec 本文を取得するとき, the Design PR Reviewer shall head ブランチの git ref（`origin/<head_ref>`）から `tasks.md` の本文を取得する
4. While spec ディレクトリが新規設計 PR の head ブランチにのみ存在し作業ツリー（base チェックアウト中）には存在しない状態であるとき, the Design PR Reviewer shall 当該 spec ファイル本文を取得して Reviewer プロンプトの対応プレースホルダに埋め込む
5. If 取得対象の spec ファイルが head ブランチの git ref に存在するとき, the Design PR Reviewer shall そのファイルの実本文をレビュー入力として用い `(none)` を埋め込まない

### Requirement 2: spec 本文取得不能時の fail-closed（approve しない）

**Objective:** As a 設計 PR の merge ゲート利用者, I want spec 本文を取得できない場合に approve しないこと, so that レビュー対象を読めていない設計 PR が無レビューで auto-merge されるのを防げる

#### Acceptance Criteria

1. If Design PR Reviewer が当該設計 PR の spec 本文を head ブランチの git ref から 1 つも取得できないとき, the Design PR Reviewer shall その PR に対して `approve`（`claude-review = success`）を publish しない
2. If spec ディレクトリパスが head ブランチから解決できなかった（解決結果が空）とき, the Design PR Reviewer shall その PR に対して `approve` を publish しない
3. If spec ディレクトリパスは解決できたが当該 ref から spec 本文を取得できなかったとき, the Design PR Reviewer shall その PR に対して `approve` を publish しない
4. When spec 本文取得不能により fail-closed 経路へ入ったとき, the Design PR Reviewer shall `claude-review` status を `pending` に据え置き、判定 marker / 判定コメントを投稿せず、次サイクルでの再試行に委ねる
5. When spec 本文取得不能により fail-closed 経路へ入ったとき, the Design PR Reviewer shall LLM 判定リクエストを発行せずに当該 PR の処理を打ち切る
6. While spec 本文取得不能で `pending` 据え置きとなっている状態のとき, the Design PR Reviewer shall 人間運用の `awaiting-design-review` ラベルゲートおよび既存 exec 失敗時 `pending` 据え置き経路と同一の status・ラベル契約を維持する

### Requirement 3: spec dir 解決済みかつ本文取得不能時の乖離 WARN

**Objective:** As a watcher ログ監査者, I want spec dir が解決できているのに本文を取得できないケースを WARN で可視化すること, so that ログが健全に見えたまま空虚 approve を見逃す罠を検知できる

#### Acceptance Criteria

1. If spec ディレクトリパスは解決できたが当該 ref から spec 本文を取得できなかったとき, the Design PR Reviewer shall WARN ログを 1 行出力し、解決済み spec dir パスと本文取得不能の事実を併記する
2. While spec dir 解決済みかつ本文取得不能で WARN を出力した状態のとき, the Design PR Reviewer shall 同一 PR の判定完了相当ログを `verdict=approve` の形では出力しない

### Requirement 4: 本 Issue スコープと既存保守的 approve 経路の境界明確化

**Objective:** As a 設計 PR Reviewer の保守的判定挙動に依存する運用者, I want fail-closed の適用範囲を「spec 本文取得不能」に限定すること, so that parse / validate 失敗時の保守的 approve（false-reject 回避）が意図せず変更されない

#### Acceptance Criteria

1. Where spec 本文の取得が成功している場合, the Design PR Reviewer shall 判定出力の parse 失敗 / schema validate 失敗時の保守的 approve 挙動を本 Issue 修正前と同一に維持する
2. When 判定出力の parse 失敗 / schema validate 失敗が発生したとき（spec 本文取得は成功している場合）, the Design PR Reviewer shall 既存の保守的 approve 経路を適用する
3. The Design PR Reviewer shall fail-closed（非 approve）を「spec 本文取得不能」ケースのみに適用し、それ以外の保守的 approve 経路には適用しない

### Requirement 5: prompt template / README の実態整合

**Objective:** As a Design PR Reviewer の prompt / ドキュメント参照者, I want prompt template と README を実装挙動と整合させること, so that 「spec dir / ファイル不在 → 保守的 approve」という記述が実態と矛盾しなくなる

#### Acceptance Criteria

1. When 本 Issue の fail-closed 修正を反映するとき, the Design Review Prompt Template shall 「spec dir 不在 / spec ファイル不在を理由とした `(none) → VERDICT: approve`」の指示を実装挙動（spec 本文取得不能は非 approve）と整合する記述へ更新する
2. When 本 Issue の fail-closed 修正を反映するとき, the README shall Design PR Reviewer 節の「spec 本文取得不能 / spec dir 不在 → 保守的 approve」に該当する記述を実装挙動（fail-closed = `pending` 据え置き）と整合する記述へ同一 PR で更新する
3. The Design Review Prompt Template shall spec 本文取得が成功している場合の 3 観点判定基準・reject 禁止事項・read-only 制約を本 Issue 修正前と同一に維持する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Design PR Reviewer shall `DESIGN_REVIEWER_ENABLED` の既定 OFF（未設定 / 不正値はすべて OFF に正規化）を本 Issue 修正前と同一に維持する
2. The Design PR Reviewer shall 既存 env var 名（`DESIGN_REVIEWER_*` / `PR_REVIEWER_GIT_TIMEOUT` 等）・ラベル名（`needs-iteration` / `awaiting-design-review`）・commit status 名（`claude-review`）・ログ出力先を本 Issue 修正で変更しない
3. The Design PR Reviewer shall 本 Issue 修正のために新規 env gate を追加せず、既存挙動の修正のみに留める
4. The Design PR Reviewer shall `pdr_run_review_for_pr` の exit code の意味（0 = 処理完了 / 1 = skip / 2 = pending 据え置き）を本 Issue 修正で変更しない

### NFR 2: root ↔ repo-template 同期

1. When prompt template / README 以外に root 配下の Design PR Reviewer 配布物（modules / prompt template）を変更したとき, the 成果物 shall root と `repo-template/` の双方を byte 一致で更新し `diff -r` 差分ゼロを維持する

### NFR 3: 可観測性

1. The Design PR Reviewer shall spec 本文取得不能で fail-closed 経路に入った PR について、`pending` 据え置きとなった旨を 1 行のログで観測可能にする

## Out of Scope

- **人間 escalation 素通しガード**: 判定本文に未解決の確認事項 / Architect の人間 escalation（例: コメント記載の PR#55 / ae-mdm #52、凍結済み Req 1.4 の実質変更）が含まれる設計 PR の approve を保留する機能。これは「spec 本文取得不能」というデータ供給バグの修正とは別レイヤー（Reviewer が spec 本文を読めた上での判定品質の問題）であり、本 Issue では扱わない（別 Issue 候補。確認事項を参照）。
- **#432（Design PR Reviewer の既定 ON 化）**: 本 Issue は #432 の前提となるバグ修正だが、既定値の反転自体は本 Issue のスコープ外。
- **3 観点の判定軸・reject 禁止事項の変更**: AC カバレッジ / design⇄tasks 整合 / Traceability の判定ロジックは #407 のまま不変。
- **spec 本文取得方式の実装手段の選択**（git ref からの直接取得か一時 worktree fetch か等）: これは Architect / Developer の設計判断。本要件は「head ブランチの git ref から取得する」という観測可能な性質のみを規定する。
- **PR diff やコード本体のレビュー**: 本 Reviewer は spec 3 ファイルのみを対象とし、コード差分のレビューは別経路（impl PR Reviewer #261 / adjudicator #404）の領分。

## Open Questions

- **fail-closed の非 approve 手段の確定**: 本要件は Req 2.4 で「`pending` 据え置き + 次サイクル再試行」（既存 exec 失敗時 rc=2 経路との整合）を第一候補として規定した。Issue 本文は「retry / fetch するか、非 approve（pending / skip / reject）を publish する」と幅を持たせている。`reject`（`needs-iteration` 付与による Architect 反復起動）を選ぶ運用上の利点（新規設計 PR の spec dir 解決不能は本来 PR 構成の異常であり反復で是正を促せる）があるかは人間判断が必要。第一候補（`pending` 据え置き）で確定してよいか確認したい。
- **人間 escalation 素通しガードのスコープ可否**: コメント（PR#55 / ae-mdm #52）で提示された「判定本文に未解決の確認事項 / 人間 escalation を含む設計 PR の approve 保留」ガードを、本 Issue に含めるか別 Issue とするか。本要件では Out of Scope（別 Issue 候補）と判断したが、優先度の観点で本 Issue に同梱すべきと運用者が判断する場合は要件追加が必要。推測で AC 化していないため人間判断を仰ぐ。
