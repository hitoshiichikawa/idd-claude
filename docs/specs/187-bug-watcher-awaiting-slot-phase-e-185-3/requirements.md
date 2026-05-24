# Requirements Document

## Introduction

Phase E Path Overlap Checker（`PATH_OVERLAP_CHECK=true` 時）は、in-flight Issue と編集 path が重複する候補 Issue の dispatch を見送り、その理由を `awaiting-slot` ラベルと説明用 sticky comment（marker `<!-- idd-claude:awaiting-slot:v1 -->`）で運用者に提示する。現状の `po_apply_awaiting_slot`（`local-watcher/bin/modules/promote-pipeline.sh`）は冒頭でラベル付与を試み、失敗すると即座に終了するため、sticky comment 投稿コードに到達しない。結果として、ラベル付与に失敗したケースでは「なぜ Issue が止まっているか」が Issue 上から一切読み取れず、dispatch 見送りが運用者に不可視となる。本要件は、コメント投稿の到達性をラベル付与の成否から切り離し、見送り理由の可視性を確保するバグ修正を定義する。実害（誤 dispatch）は発生しないため、スコープは可視性の回復に限定する。

## Requirements

### Requirement 1: dispatch 見送り理由の可視性確保

**Objective:** As a idd-claude 運用者, I want awaiting-slot 付与に失敗したときでも見送り理由が Issue 上に提示されること, so that 止まっている Issue の原因を Issue 画面から把握できる

#### Acceptance Criteria

1. When overlap が検出され awaiting-slot 付与のために sticky comment 投稿処理が呼ばれたとき, the Path Overlap Checker shall ラベル付与の成否に依存せず sticky comment の投稿または更新を試行する
2. If awaiting-slot ラベルの付与に失敗したとき, the Path Overlap Checker shall sticky comment の投稿または更新を引き続き試行する
3. When sticky comment を投稿するとき, the Path Overlap Checker shall 重複した top-level path と現状の awaiting 状態を運用者が判読できる本文を提示する
4. While 同一 Issue に marker 付き sticky comment が既に存在するとき, the Path Overlap Checker shall 新規コメントを追加投稿せず既存コメントを更新する

### Requirement 2: 見送り判定と後方互換性の維持

**Objective:** As a idd-claude 運用者, I want 本修正が既存の dispatch 見送り判定と運用契約を変えないこと, so that 既に稼働中の cron / watcher 挙動が壊れない

#### Acceptance Criteria

1. While `PATH_OVERLAP_CHECK` が `true` 以外（未設定 / off / 不正値）のとき, the Path Overlap Checker shall overlap 判定を行わず本修正導入前と同一の挙動を保つ
2. When overlap が検出されたとき, the Path Overlap Checker shall ラベル付与およびコメント投稿の成否に関わらず当該サイクルで該当候補の dispatch を見送る
3. If awaiting-slot 付与またはコメント投稿に失敗したとき, the Path Overlap Checker shall 当該サイクルを失敗で異常終了させず次サイクルでの再評価に委ねる
4. The Path Overlap Checker shall 既存の環境変数名・ログ出力先・ラベル名・ラベル遷移契約を変更せず維持する

### Requirement 3: 失敗時の運用者向けログ可視性

**Objective:** As a idd-claude 運用者, I want awaiting-slot 付与やコメント投稿が失敗したことがログに残ること, so that Issue 上のコメントとログの双方から見送り経緯を追跡できる

#### Acceptance Criteria

1. If awaiting-slot 付与またはコメント投稿に失敗したとき, the Path Overlap Checker shall 当該候補 Issue 番号を含む警告を運用者向けログに出力する
2. When overlap が検出されたとき, the Path Overlap Checker shall 重複 path を含む検出ログを既存と同一の形式で出力する

## Non-Functional Requirements

### NFR 1: 後方互換性（観測可能な不変性）

1. While `PATH_OVERLAP_CHECK` が無効のとき, the Path Overlap Checker shall 本修正導入前と完全に同一のログ出力・ラベル操作・dispatch 判定を行う
2. The Path Overlap Checker shall dispatch 見送りを示す呼び出し側への戻り値の意味（見送り = skip）を本修正前と同一に保つ

### NFR 2: 冪等性

1. When 同一候補に対し連続サイクルで sticky comment 投稿が試行されたとき, the Path Overlap Checker shall Issue に対し sticky comment を 1 件に保ち重複投稿しない

## Out of Scope

- 受入観点 (2) の軽量フォールバック（欠落ラベル検出 → 1 度だけ WARN する仕組み、自動ラベル作成等）の実装。これは #185 のコメントで「2.B につき別 issue を起票」と人間が判断済みであり、別 Issue で扱う。本 Issue では過剰修正（自動ラベル作成の常時実行など）を行わない
- 編集 path の重複判定ロジック（`po_compute_overlap` 等）の変更
- in-flight Issue 列挙ロジック（`po_collect_inflight_issues` 等）の変更
- awaiting-slot ラベルの除去ロジック（`po_clear_awaiting_slot`）の挙動変更
- sticky comment 本文フォーマットの仕様変更（表示内容は既存仕様を踏襲する。本修正は投稿到達性の回復に限定）
- リファクタリング・新機能追加（本 Issue はバグ修正であり、スコープを広げない）

## Open Questions

- なし（編集対象ファイルが `local-watcher/bin/modules/promote-pipeline.sh` であること、受入観点 (2) を別 Issue に分離することは #185 / #187 のコメントで人間が確定済み。本要件はその決定を反映している）
