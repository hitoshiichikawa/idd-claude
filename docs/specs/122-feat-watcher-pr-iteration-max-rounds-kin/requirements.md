# Requirements Document

## Introduction

PR Iteration Processor は現在、`PR_ITERATION_MAX_ROUNDS`（既定 `3`）を impl PR と
design PR の双方に同じ値で適用している。実装レビューでは差分の収束が早いため 3 round
で妥当に運用できる一方、設計レビューでは spec 読み込みの過程で派生する二次論点が多く、
3 round で打ち切られて `claude-failed` に昇格する事例が観測されている。一方で round
上限を無条件に外すと、Claude が空コミットや無進捗の reply のみを繰り返した場合の
コスト暴走リスクが残る。

本要件は、`PR_ITERATION_MAX_ROUNDS` を kind 別（impl / design）の env 変数に分離し、
design では既定で round 上限による自動 escalate を行わない一方、「連続して進捗 commit
が無い round」を検知して escalate する no-progress ループ検知を defense-in-depth として
追加することを定義する。あわせて、quota soft-fail や CLI クラッシュなど失敗扱いになった
round を round counter / no-progress counter から除外することで、ユーザー起因ではない
中断による意図しない escalate を抑止する。

## Requirements

### Requirement 1: kind 別 round 上限の分離

**Objective:** As a idd-claude 運用者, I want impl PR と design PR で round 上限を別々
に設定できるようにしたい, so that 実装レビューの収束速度と設計レビューの探索特性に応じた
escalate 戦略を取れる。

#### Acceptance Criteria

1. When `PR_ITERATION_MAX_ROUNDS_IMPL` が設定されているとき, the PR Iteration Processor shall kind=impl の round 上限としてその値を使用する
2. When `PR_ITERATION_MAX_ROUNDS_DESIGN` が設定されているとき, the PR Iteration Processor shall kind=design の round 上限としてその値を使用する
3. When `PR_ITERATION_MAX_ROUNDS_IMPL` と `PR_ITERATION_MAX_ROUNDS_DESIGN` の両方が未設定で旧 `PR_ITERATION_MAX_ROUNDS` のみが設定されているとき, the PR Iteration Processor shall 旧 `PR_ITERATION_MAX_ROUNDS` の値を impl / design 両方の round 上限の fallback として使用する
4. When kind 固有 env と旧 env の全てが未設定であるとき, the PR Iteration Processor shall kind=impl の round 上限を `3`、kind=design の round 上限を `0` として適用する
5. When kind=impl の round 上限が解決されたとき, the PR Iteration Processor shall その解決値をサイクル開始ログに impl / design 別々に出力する
6. The PR Iteration Processor shall 解決した round 上限の値を、対象 round の着手表明コメント・escalate コメント・ログにそれぞれ反映する

### Requirement 2: design の sentinel `0` による無制限化

**Objective:** As a idd-claude 運用者, I want kind=design の round 上限を `0` に設定する
ことで「round 上限による escalate を行わない」状態を表現したい, so that 二次論点が多い
設計レビューを round 数で機械的に打ち切らずに済む。

#### Acceptance Criteria

1. When kind=design の round 上限が `0` に解決されているとき, the PR Iteration Processor shall round 数の超過のみを根拠とした `claude-failed` への昇格を行わない
2. While kind=design の round 上限が `0` であるとき, the PR Iteration Processor shall Requirement 3 の no-progress ループ検知による escalate は引き続き有効のまま動作させる
3. When kind=impl の round 上限が `0` に解決されているとき, the PR Iteration Processor shall kind=impl についても round 数の超過のみを根拠とした escalate を行わない
4. The PR Iteration Processor shall round 上限が `0` の kind について、サイクル開始ログおよび round 着手ログに「無制限」であることが運用者に判別可能な表現でその状態を出力する

### Requirement 3: no-progress ループ検知による defense-in-depth escalate

**Objective:** As a idd-claude 運用者, I want round 上限を外したとき（または高い値に
した場合）でも、Claude が連続して進捗 commit を生み出さない状態が続いたら自動で
escalate してほしい, so that コスト暴走と無限ループを防げる。

#### Acceptance Criteria

1. When round 終了時に head branch への新規 commit が push されていないと判定されたとき, the PR Iteration Processor shall hidden marker の no-progress 連続カウンタを `1` 加算する
2. When round 終了時に head branch へ新規 commit が push されたと判定されたとき, the PR Iteration Processor shall hidden marker の no-progress 連続カウンタを `0` にリセットする
3. When 加算後の no-progress 連続カウンタが `PR_ITERATION_NO_PROGRESS_LIMIT` 以上に達したとき, the PR Iteration Processor shall 当該 PR を `claude-failed` に昇格させる
4. When `PR_ITERATION_NO_PROGRESS_LIMIT` が未設定であるとき, the PR Iteration Processor shall 既定値 `3` を適用する
5. When no-progress 連続カウンタ超過で escalate するとき, the PR Iteration Processor shall escalate コメントの本文に「no-progress 連続 N round による escalate」であること、現在の連続カウンタ値、`PR_ITERATION_NO_PROGRESS_LIMIT` の値を明示する
6. The PR Iteration Processor shall no-progress 連続カウンタの現在値を hidden marker から読み取り、kind に依存せず impl / design 両方の PR で同じ判定ロジックを適用する

### Requirement 4: hidden marker フォーマット拡張と後方互換性

**Objective:** As a idd-claude 運用者, I want no-progress 連続カウンタを既存 hidden marker
に追加しつつ、既存 marker しか持たない既稼働 PR が壊れないようにしたい, so that 本機能
導入と同時に進行中の PR が誤判定や ERROR で停止しない。

#### Acceptance Criteria

1. When PR body の hidden marker を書き込むとき, the PR Iteration Processor shall 既存の `round=N last-run=ISO8601` キーに加えて no-progress 連続カウンタを表すキーを同じ `<!-- idd-claude:pr-iteration ... -->` コメント内に格納する
2. When PR body の hidden marker から no-progress 連続カウンタを読み取ろうとしたときに該当キーが存在しないとき, the PR Iteration Processor shall 連続カウンタを `0` として解釈する
3. The PR Iteration Processor shall 既存 hidden marker のキー名（`round`, `last-run`）と marker コメント全体のプレフィクス（`<!-- idd-claude:pr-iteration `）を変更しない
4. When 既存の hidden marker しか持たない PR を本機能導入後に処理するとき, the PR Iteration Processor shall ERROR を発生させず、no-progress カウンタを `0` から開始した上で通常通り round を進める
5. The PR Iteration Processor shall PR body 内の hidden marker が複数存在する場合に最新（末尾）の値を採用する既存挙動を、no-progress 連続カウンタについても同じ規則で適用する

### Requirement 5: 失敗 round の counter 据え置き

**Objective:** As a idd-claude 運用者, I want quota soft-fail や Claude CLI のクラッシュ等で
round が「失敗扱い」になった場合に round counter と no-progress 連続カウンタを更新しない
でほしい, so that ユーザー起因ではない中断によって意図しない escalate が起きない。

#### Acceptance Criteria

1. When round が quota soft-fail として終了したとき, the PR Iteration Processor shall hidden marker の round 数値を加算前の値に保つ
2. When round が quota soft-fail として終了したとき, the PR Iteration Processor shall hidden marker の no-progress 連続カウンタを加算前の値に保つ
3. When round 内で Claude CLI が非 0 で終了したとき, the PR Iteration Processor shall hidden marker の round 数値と no-progress 連続カウンタの双方を加算前の値に保つ
4. If 失敗 round の処理中に hidden marker の書き込み自体に失敗したとき, the PR Iteration Processor shall ERROR ログに記録した上で当該 PR の `needs-iteration` ラベルを残置して終了する
5. When 失敗 round 扱いとなった round の直後に同 PR が次サイクルで再 pickup されたとき, the PR Iteration Processor shall 据え置かれた round 数値および no-progress 連続カウンタを起点として処理を再開する

### Requirement 6: ログとオブザーバビリティ

**Objective:** As a idd-claude 運用者, I want kind 別 round 上限の解決値・no-progress 連続
カウンタの推移・no-progress による escalate を cron ログから機械的に集計したい,
so that 設計レビューの実運用上の round 分布や escalate 原因の内訳を把握できる。

#### Acceptance Criteria

1. When PR Iteration Processor がサイクルを開始するとき, the PR Iteration Processor shall impl / design の round 上限解決値と `PR_ITERATION_NO_PROGRESS_LIMIT` の値を 1 行のサマリログとして出力する
2. When round の終了時点で no-progress 連続カウンタが加算されたとき, the PR Iteration Processor shall PR 番号 / kind / 加算後の連続カウンタ / `PR_ITERATION_NO_PROGRESS_LIMIT` を 1 行のログにまとめて出力する
3. When no-progress 連続カウンタ超過で escalate したとき, the PR Iteration Processor shall PR 番号 / kind / 連続カウンタ / escalate 原因（`no-progress`）を 1 行のログにまとめて出力する
4. When round 上限超過で escalate したとき, the PR Iteration Processor shall PR 番号 / kind / round / 解決された round 上限値 / escalate 原因（`max-rounds`）を 1 行のログにまとめて出力する
5. The PR Iteration Processor shall 上記ログ行を既存の `pi_log` / `pi_warn` / `pi_error` のタイムスタンプ形式に整合させる

### Requirement 7: ドキュメント整合

**Objective:** As a idd-claude 運用者, I want 本機能の env 変数・既定値・hidden marker
拡張・no-progress 検知の挙動を README と repo-template の CLAUDE.md から把握したい,
so that 既稼働 consumer repo の運用者が migration 内容を読み取れる。

#### Acceptance Criteria

1. When 本機能を導入するとき, the README shall `PR_ITERATION_MAX_ROUNDS_IMPL` / `PR_ITERATION_MAX_ROUNDS_DESIGN` / `PR_ITERATION_NO_PROGRESS_LIMIT` の env 名・既定値・優先順位・design 既定 `0`（無制限）の意味を記載する
2. When 本機能を導入するとき, the README shall 旧 `PR_ITERATION_MAX_ROUNDS` が両 kind の fallback として後方互換的に機能することを migration note として記載する
3. When 本機能を導入するとき, the README shall hidden marker 内の no-progress 連続カウンタの存在と、既存 marker しか持たない PR が自動で `0` 扱いとして開始されることを記載する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Iteration Processor shall 旧 `PR_ITERATION_MAX_ROUNDS` の env 名・既定値（`3`）の意味を、kind 固有 env が未設定の場合の fallback として温存する
2. The PR Iteration Processor shall 既存の hidden marker コメントプレフィクス `<!-- idd-claude:pr-iteration ` と `round` / `last-run` キー名を変更しない
3. The PR Iteration Processor shall 既存の `pi_log` / `pi_warn` / `pi_error` のタイムスタンプ書式とログ行プレフィクスを変更しない
4. The PR Iteration Processor shall 既存の env 変数（`PR_ITERATION_ENABLED` / `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_HEAD_PATTERN` / `PR_ITERATION_DESIGN_HEAD_PATTERN` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_MAX_PRS` / `PR_ITERATION_GIT_TIMEOUT` / `PR_ITERATION_DEV_MODEL`）の意味と既定値を変更しない

### NFR 2: テスト可能性

1. The PR Iteration Processor shall Requirement 1 の env 優先順位 4 通り（kind 固有設定 / kind 固有未設定 + 旧 env 設定 / 旧 env のみ設定 / 全未設定）をそれぞれ独立に検証できる fixture を提供する
2. The PR Iteration Processor shall Requirement 3 の no-progress 検知（カウンタ加算 / commit によるリセット / 上限到達 escalate）と Requirement 5 の失敗 round 据え置きをそれぞれ独立に検証できる fixture を提供する
3. The PR Iteration Processor shall 本要件導入後も既存テストスイートが成功する状態を維持する

### NFR 3: 観測性

1. The PR Iteration Processor shall サイクル開始ログ・round 着手ログ・escalate ログのいずれにおいても、kind と解決された round 上限値および no-progress 連続カウンタ値を grep で機械抽出できる形式で出力する

## Out of Scope

- 自動コメント生成による Architect 再起動や、design PR の round 上限超過時に Architect を再呼び出しする仕組み
- 設計品質メトリクス（design PR の round 数中央値・収束 round 分布など）の定量化
- kind=impl の round 上限の既定値変更（`3` のまま維持する）
- 旧 `PR_ITERATION_MAX_ROUNDS` の deprecation 警告出力（後方互換 fallback としてサイレントに動作させ続ける）
- `pr-iteration` 以外のステージ（Stage A / B / C / Reviewer / Triage）における round 上限の kind 別分離
- quota soft-fail / CLI クラッシュ以外の「失敗扱い」分類の拡張（既存の失敗判定経路に追従するのみで、新規の失敗カテゴリ定義は行わない）

## Open Questions

- なし（Issue 本文の「仮案・判断を委ねたい点」は以下の通り Issue 本文の推奨案を採用した:
  - `PR_ITERATION_NO_PROGRESS_LIMIT` の既定値は `3` を採用 → Requirement 3.4 に明記
  - design 既定上限は `0`（無制限）を採用、`30` 等の有限値は採らない → Requirement 1.4 / Requirement 2 に明記
  - hidden marker のキー名は no-progress 連続カウンタを表す名前として `no-progress-streak` を想定 → Requirement 4.1 / 4.2 / 4.4 では設計に委ねる粒度で「no-progress 連続カウンタを表すキー」と表現
  - F-4（失敗 round の counter 据え置き）は本要件のスコープに含め Requirement 5 として独立化、既存 Issue #118 の soft-fail 検知経路に対する counter 据え置き挙動の追加として整理。soft-fail の検知・auto-commit 自体は #118 既存実装を流用する想定で、本要件では「counter を加算しない」契約のみを規定）
