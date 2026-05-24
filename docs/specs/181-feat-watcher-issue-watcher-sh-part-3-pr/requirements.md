# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は約 11,899 行（約 570KB）の単一 Bash スクリプトに肥大化しており、3 パートに分割したモジュール化リファクタリングが進行中である。本 Issue（#181）はその最終 Part（Part 3）で、Stage C の開発・レビュー反復ループ、同サイクル dispatch 競合予防・待機、Stage A 独立再実行ゲート、ST base 昇格パイプラインという 4 つの複雑な processor 群を、`issue-watcher.sh` 本体から専用モジュールへ切り出す。Part 1（#177）が確定したモジュール境界マップ（Entry-point + Sourced Library Modules パターン）と後方互換要件、および Part 2（#180）の前段切り出しを前提とする。idd-claude は self-hosting（dogfooding）で本スクリプト自身が次回 cron 実行で自分を動かすため、外部から観測される振る舞いを一切変えない差分等価リファクタリングであること、および既存運用（cron / launchd）との完全な後方互換性が最重要要件となる。本 Issue の本体タスクは設計フェーズ（requirements / design / tasks の作成）であり、実装は別途行う。

## Requirements

### Requirement 1: PR 反復開発ループ processor の切り出し

**Objective:** As a watcher を保守する開発者, I want Stage C の開発・レビュー反復ループ（`process_pr_iteration` / `pi_*` 関数群）が本体から専用モジュールへ切り出されること, so that 反復ロジックをモジュール単位で編集でき、編集時のトークンコストとデグレリスクを下げられる

#### Acceptance Criteria

1. When 切り出し後の watcher が PR 反復開発ループを実行したとき, the Issue Watcher shall 切り出し前と同一の処理結果（反復要否の判定・反復実行・終了）を生成する
2. While PR 反復が継続条件を満たすとき, the Issue Watcher shall 切り出し前と同一の反復継続挙動を行う
3. While 反復回数が上限に達したとき, the Issue Watcher shall 切り出し前と同一の上限到達時挙動（反復停止・後続遷移）を行う
4. The Issue Watcher shall `process_pr_iteration` および `pi_*` プレフィックスの関数群を、切り出し前と同一のシグネチャ・引数・exit code・標準出力／標準エラー出力契約で提供する

### Requirement 2: Path Overlap processor の切り出し

**Objective:** As a watcher を保守する開発者, I want 同サイクル dispatch 競合予防・待機（`po_*` 関数群）が本体から専用モジュールへ切り出されること, so that 競合検出ロジックを独立して保守できる

#### Acceptance Criteria

1. When 同一サイクル内で dispatch 対象のパスが他の処理対象と重複したとき, the Issue Watcher shall 切り出し前と同一の競合検出・待機挙動を行う
2. If dispatch 競合が検出されないとき, the Issue Watcher shall 切り出し前と同一の通常 dispatch 挙動を行う
3. The Issue Watcher shall `po_*` プレフィックスの関数群を、切り出し前と同一のシグネチャ・引数・exit code・標準出力／標準エラー出力契約で提供する

### Requirement 3: Stage A Verify ゲートの切り出し

**Objective:** As a watcher を保守する開発者, I want Stage A 独立再実行ゲート（`stage_a_verify_run` / `sav_*` 関数群）が本体から専用モジュールへ切り出されること, so that 検証ゲートをモジュール単位で保守でき、関連テストが安定して通る

#### Acceptance Criteria

1. When 切り出し後の watcher が Stage A 独立再実行ゲートを実行したとき, the Issue Watcher shall 切り出し前と同一の検証結果（pass / fail の判定とそれに伴う遷移）を生成する
2. If Stage A 検証が失敗したとき, the Issue Watcher shall 切り出し前と同一の失敗時挙動（エスカレーション・ラベル遷移・exit code）を行う
3. The Issue Watcher shall `stage_a_verify_run` および `sav_*` プレフィックスの関数群を、切り出し前と同一のシグネチャ・引数・exit code・標準出力／標準エラー出力契約で提供する

### Requirement 4: Promote Pipeline processor の切り出し

**Objective:** As a watcher を保守する開発者, I want ST base 昇格パイプライン（`process_promote_pipeline` / `pp_*` 関数群）が本体から専用モジュールへ切り出されること, so that 昇格制御ロジックを独立して保守できる

#### Acceptance Criteria

1. When 切り出し後の watcher が昇格パイプラインを実行したとき, the Issue Watcher shall 切り出し前と同一の昇格制御挙動（通常リリース処理を含む）を行う
2. While `PROMOTE_PIPELINE_ENABLED` が未設定または `false` であるとき, the Issue Watcher shall 切り出し前と同一に昇格パイプラインを起動せず、導入前と同一の挙動を保つ
3. The Issue Watcher shall `process_promote_pipeline` および `pp_*` プレフィックスの関数群を、切り出し前と同一のシグネチャ・引数・exit code・標準出力／標準エラー出力契約で提供する

### Requirement 5: 差分等価・後方互換性の維持

**Objective:** As a 運用者（cron / launchd で watcher を起動する人）, I want 本切り出し後も既存の環境変数・起動コマンド・ログ出力先・ラベル遷移・exit code の意味が切り出し前と完全に等価であること, so that self-hosting 環境を含む既稼働の cron / launchd が無告知の破壊を受けない

#### Acceptance Criteria

1. The Issue Watcher shall 本切り出しで触れる範囲について、既存の全環境変数（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PROMOTE_PIPELINE_ENABLED` 等）の名称・デフォルト値・override 挙動を切り出し前と等価に保つ
2. When 既存の cron / launchd 起動コマンド（`$HOME/bin/issue-watcher.sh` を env var 付きで直接起動）がそのまま実行されたとき, the Issue Watcher shall 切り出し前と同一の処理サイクルを実行する
3. The Issue Watcher shall 本切り出しで触れる範囲について、ログ出力先・ログ書式の契約・ラベル遷移契約・exit code の意味を切り出し前と等価に保つ
4. The Issue Watcher shall 本切り出しにおいて機能の追加・削除・バグ修正を行わず、関数の移動のみに留める
5. If 本切り出しに伴い後方互換性を破る変更が不可避であるとき, the Issue Watcher shall その変更を README の migration note として明文化したうえでのみ導入する

### Requirement 6: 既存テストの不破壊

**Objective:** As a watcher を保守する開発者, I want 切り出し対象関数を検証する既存テストが切り出し後も全て成功すること, so that リファクタリングがデグレを起こしていないことを観測可能に保証できる

#### Acceptance Criteria

1. When `local-watcher/test/` 配下の全テストが実行されたとき, the Test Suite shall 本切り出し後の構成のもとで全テストが成功する
2. When `tests/local-watcher/` 配下の全テストが実行されたとき, the Test Suite shall 本切り出し後の構成のもとで全テストが成功する
3. While 個別関数を抽出して検証する既存テストが切り出し対象関数を読み込むとき, the Test Suite shall 関数の移動先にかかわらず対象関数を解決して検証できる
4. If 本切り出しにより既存テストが対象関数を解決できなくなるとき, the Test Suite shall その不整合を成功扱いで隠さず、テスト失敗として観測可能にする

### Requirement 7: 静的解析クリーン

**Objective:** As a watcher を保守する開発者, I want 本切り出しで生成・編集したエントリポイントと全モジュールが静的解析で警告ゼロであること, so that モジュール化後もコード品質基準を維持できる

#### Acceptance Criteria

1. When `issue-watcher.sh` に対して `shellcheck` を実行したとき, the Static Analysis shall 警告ゼロを報告する
2. When 本切り出しで生成・編集したモジュールに対して `shellcheck` を実行したとき, the Static Analysis shall 各モジュールについて警告ゼロを報告する

### Requirement 8: メインスクリプトのサイズ集約

**Objective:** As a watcher を保守する開発者, I want Part 1〜3 完了時点でメインスクリプトが目標行数まで縮小されること, so that 単一ファイル肥大化のボトルネックが解消される

#### Acceptance Criteria

1. While Part 1（#177）・Part 2（#180）・Part 3（本 Issue）の切り出しがすべて完了した状態であるとき, the Issue Watcher のエントリポイント（`issue-watcher.sh`）shall 1,000 行以下（推奨 500 行以下）に集約される
2. When Part 3 単独の切り出しが完了したが Part 1 / Part 2 が未完了であるとき, the Issue Watcher のエントリポイント shall 本 Issue が切り出す 4 processor 群の関数定義を本体から除去している（1,000 行以下の達成は Part 1 / Part 2 完了を前提依存とする）

## Non-Functional Requirements

### NFR 1: 差分等価性

1. The Issue Watcher shall 本切り出し前後で、外部から観測される振る舞い（処理結果・ログ書式の契約・ラベル遷移・exit code）を差分等価に保つ
2. While self-hosting 環境（idd-claude 自身を対象 repo として cron 実行）で次回サイクルが動作するとき, the Issue Watcher shall 本切り出し前と同一の挙動でその回の処理を完走する

### NFR 2: モジュール解決の堅牢性

1. While cron / launchd の最小 PATH 環境で起動されたとき, the Issue Watcher shall 本切り出しで追加したモジュールを自身の配置位置基準で解決し、対話シェルの profile に依存せず動作する
2. The Issue Watcher shall 本切り出しで追加したモジュールの解決にユーザーのカレントディレクトリやシンボリックリンク先の差異を前提とせず、自身の配置位置から相対解決する

## Out of Scope

- 本 Issue が切り出す 4 processor 群以外の関数群（quota-aware / merge-queue / auto-rebase / design-review-release / impl-pipeline / dispatcher 等）のモジュール化（Part 1 / Part 2 および別タスクの領分）
- 切り出すモジュールのファイル名・ファイル分割粒度・source ロード順序の最終確定（Part 1 境界マップとの整合を含め `design.md` / Architect の領分。後述「確認事項」参照）
- 既存テストが対象関数を解決するための具体的な実装手段（本体に関数を残すか / テスト側の抽出元を変えるか / 共通ローダを介すか等の選択。Part 1 設計の「既存テスト互換戦略」を踏襲するかも含め `design.md` の領分）
- 機能挙動そのものの変更・新機能追加・バグ修正（本 Issue は純粋なリファクタリングであり振る舞いを変えない）
- 切り出し対象関数を跨いだロジックの再設計・共通化（移動のみ。リファクタは行わない）
- GitHub Actions 経路（`.github/workflows/issue-to-pr.yml`）のモジュール化
- `repo-template/` 配下テンプレートの分割
- ファイル分割によるパフォーマンス最適化目標（起動時間短縮等）の数値設定
- 本 Issue 本体は設計フェーズ（requirements / design / tasks の作成）であり、実装そのものは含まない

## Open Questions

### 確認事項（Architect / 人間に委ねる設計判断）

- **ファイル名のハイフン vs アンダースコアの食い違い**: Issue #181 はアンダースコア区切り（`pr_iteration.sh` / `path_overlap.sh` / `stage_a_verify.sh` / `promote_pipeline.sh`）を指定するが、Part 1（#177）の確定済み境界マップはハイフン区切り（`pr-iteration.sh` / `promote-pipeline.sh` 等）を採用している。どちらの命名規約を正本とするかは要件レベルで確定できない設計判断であり、Part 1 境界マップとの整合は design フェーズで解決する。
- **gates の分割粒度の食い違い**: Issue #181 は Stage A Verify ゲートを独立モジュール（`stage_a_verify.sh`）として分離するよう指定するが、Part 1 境界マップは Stage A Verify / Stage Checkpoint / Tasks Count を `impl-gates.sh` に集約している。ゲート系を 1 モジュールに consolidate するか個別分割するかは Part 1 整合の観点を含め design フェーズで解決する。
- **`path_overlap.sh` の独立性**: Issue #181 は Path Overlap（`po_*`）を独立モジュール（`path_overlap.sh`）として指定するが、Part 1 境界マップは `po_*` を `promote-pipeline.sh` に同居させている（`path_overlap.sh` は Part 1 マップに明示されていない）。独立モジュールにするか promote 系へ同居させるかは design フェーズで解決する。
- 上記いずれも Part 1 で確定したモジュール境界マップとの整合に関わるため、Architect / 人間が design フェーズで確定する。requirements 本文は「Part 1 の境界マップとの整合は design フェーズで解決」とする方針で記述している。
