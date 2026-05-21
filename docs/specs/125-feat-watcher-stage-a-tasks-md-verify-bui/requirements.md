# Requirements Document

## Introduction

idd-claude の watcher は現状、Stage A（Developer 実装フェーズ）の完了判定を Developer 自身の
exit code 0 と commit push のみで行っており、`tasks.md` 末尾に配置された build/test/lint の
verify タスクが実際に成功したかを独立検証していない。このため、Developer が
「ローカルで build 失敗するが既存問題かつスコープ外」と impl-notes.md に自由記述するだけで
Stage A が完了扱いとなり、Reviewer の判定範囲（AC 未カバー・missing test・boundary 逸脱）にも
PjM の責務（PR 作成のみ）にも該当せず、build 不通のまま Stage B/C を通過して PR が出てしまう
事例が発生している（keynest_for_mimamowellness PR #4）。

本要件は、Stage A 完了直前に watcher 自身が `tasks.md` 末尾の verify タスクを REPO_DIR で
独立に再実行し、exit code を観測することで「自己申告のみで build 不通が通る」現象を解消する
ことを目的とする。既存 env 名・ラベル遷移・ログ prefix 規約（Issue #119）・PR iteration 上限
（Issue #122）との後方互換と整合を保つ。

## Goals

- Stage A 完了前に watcher が `tasks.md` 末尾の verify タスクを独立再実行し、exit code 0 で
  なければ Stage B に進ませない。
- 検出は文字列パターンによる言語非依存ヒューリスティクスで行い、未対応言語は env による
  override（escape hatch）で吸収する。
- 既存運用を壊さないため、env による opt-out（`STAGE_A_VERIFY_ENABLED=false`）で従来挙動に
  完全復帰する。
- 1 回目失敗は Developer に差し戻し、2 回目失敗は `claude-failed` ラベルで人間にエスカレート
  し、Issue #122 の pr-iteration 上限と整合する。

## Non-Goals

- Reviewer の判定カテゴリに build pass を追加すること（Reviewer の責務境界は変更しない）。
- PjM が PR 作成前に build を実行すること（PjM の責務は PR 作成のみのまま）。
- 言語固有の build tool wrapper（`gradlew` shim 等）を idd-claude 側で同梱すること。
- `impl-notes.md` の自由記述ガード（記述内容の検証は行わない）。
- 既存 PR（過去に Stage A を通過した PR）の遡及検証・修正。
- Stage B / Stage C への同等 build ガードの追加（本 Issue のスコープ外）。
- 外部 Feature Flag SaaS との連携、A/B テスト・段階リリース機能（本リポジトリは
  Feature Flag Protocol opt-out のため）。

## 用語定義

- **verify タスク**: `tasks.md` 末尾近傍に配置された build / test / lint 系コマンド行。
  例: `./gradlew assembleDebug`, `npm test`, `cargo build`, `go test ./...`, `pytest`,
  `mvn verify`, `pnpm run lint` 等。
- **Stage A**: watcher パイプラインのうち、Developer エージェントが `tasks.md` の各タスクを
  実装・commit する段階。`local-watcher/bin/issue-watcher.sh` の既存実装に準拠。
- **Stage A 完了判定**: 本要件導入後は「Developer の exit code 0 + commit push」に加えて
  「stage-a-verify 段の exit code 0（または SKIPPED）」を満たした時点を指す。
- **stage-a-verify**: watcher が Stage A の最終ステップとして、抽出した verify コマンドを
  REPO_DIR で再実行する独立検証フェーズ。本要件で新規に追加する。
- **verify 再実行**: stage-a-verify が `tasks.md` から抽出または env から取得したコマンドを
  REPO_DIR を cwd として実行する操作。
- **抽出キーワード集合**: verify タスクを認識するための文字列パターン群。
  `./gradlew`, `gradle`, `mvn`, `npm test`, `npm run`, `pnpm`, `yarn`, `cargo`,
  `go test`, `go build`, `pytest`, `python -m pytest`, `make test`, `make build`,
  `bundle exec`, `rake`, `dotnet test`, `dotnet build` 等を想定（具体集合は design.md で確定）。
- **escape hatch**: `STAGE_A_VERIFY_COMMAND` env により `tasks.md` 解析を bypass して
  運用者指定の任意コマンドを使う仕組み。未対応言語・特殊コマンド向け。

## Requirements

### Requirement 1: verify タスク抽出

**Objective:** As a watcher 運用者, I want watcher が `tasks.md` から verify タスクを
自動抽出すること, so that 言語ごとに手で設定しなくても build/test/lint の独立検証が走る。

#### Acceptance Criteria

1. When Stage A の Developer フェーズが exit code 0 で完了したとき, the Watcher Stage A
   Verify Module shall `tasks.md` を末尾から逆順に走査して抽出キーワード集合に一致する
   コマンド行を 1 行特定する。
2. When `tasks.md` 内に抽出キーワード集合に一致する行が複数存在するとき, the Watcher Stage A
   Verify Module shall 末尾（ファイル末尾に最も近いもの）に出現した 1 行を選択する。
3. When 抽出対象行が `./gradlew ... && ... && ...` のような複合コマンドであるとき, the
   Watcher Stage A Verify Module shall その行全体を 1 つの shell コマンドとして実行する
   （複合演算子を解釈せずに shell 解釈に委ねる）。
4. If `tasks.md` 中に抽出キーワード集合に一致する行が 1 つも存在しないとき, the Watcher
   Stage A Verify Module shall verify 再実行を行わず SKIPPED として処理を継続する。
5. The Watcher Stage A Verify Module shall 抽出キーワード集合を言語非依存な文字列パターン
   としてのみ保持し、言語固有のパーサや AST 解析を行わない。

### Requirement 2: verify 再実行と判定

**Objective:** As a watcher 運用者, I want 抽出した verify コマンドを REPO_DIR で独立再実行
して exit code を観測すること, so that Developer の自己申告のみで build 不通が通る現象を
排除できる。

#### Acceptance Criteria

1. When verify コマンドが特定されたとき, the Watcher Stage A Verify Module shall REPO_DIR を
   cwd として当該コマンドを再実行し、exit code とタイムアウト到達有無を観測する。
2. When 再実行の exit code が 0 であるとき, the Watcher Stage A Verify Module shall Stage A
   を完全完了と判定して Stage B に進む。
3. If 再実行の exit code が 0 以外であるとき, the Watcher Stage A Verify Module shall Stage B
   に進まず、Stage A 不完全完了として後続の差し戻し／エスカレート判定に委ねる。
4. If 再実行が `STAGE_A_VERIFY_TIMEOUT` を超過したとき, the Watcher Stage A Verify Module
   shall 当該プロセスを打ち切り、Stage A 不完全完了として扱う。
5. The Watcher Stage A Verify Module shall 再実行を REPO_DIR の範囲内で行い、REPO_DIR の外側
   への副作用を発生させない。

### Requirement 3: 差し戻し・エスカレート境界

**Objective:** As a 運用者, I want stage-a-verify の失敗回数に応じて Developer 差し戻しと
人間エスカレートを使い分けること, so that 既存の pr-iteration 上限（Issue #122）と整合し、
無限ループや沈黙落ちを防げる。

#### Acceptance Criteria

1. When stage-a-verify が当該 Issue で初めて失敗したとき, the Watcher Stage A Verify Module
   shall Developer 差し戻し（needs-iteration 相当の遷移）を行い、同一 Issue に対する
   2 回目の Stage A 試行を許可する。
2. If stage-a-verify が当該 Issue で 2 回連続して失敗したとき, the Watcher Stage A Verify
   Module shall `claude-failed` ラベルを付与して人間エスカレートとし、watcher は当該 Issue の
   処理を打ち切る。
3. The Watcher Stage A Verify Module shall 失敗回数のカウントを Issue #122 の pr-iteration
   round 上限（最大 1 回）と整合させ、独立に上限を増やさない。

### Requirement 4: env による機能制御と escape hatch

**Objective:** As a 運用者, I want env 変数で本機能を opt-out / 微調整できること, so that
既存運用を壊さず段階導入でき、未対応言語にも対応できる。

#### Acceptance Criteria

1. While `STAGE_A_VERIFY_ENABLED` が `false` に設定されているとき, the Watcher Stage A
   Verify Module shall stage-a-verify を実行せず、本機能導入前と同一の Stage A 完了判定
   （Developer の exit code 0 + commit push）を行う。
2. The Watcher Stage A Verify Module shall `STAGE_A_VERIFY_ENABLED` の既定値を `true` として
   扱う。
3. The Watcher Stage A Verify Module shall `STAGE_A_VERIFY_TIMEOUT` の既定値を `600`（秒）
   として扱い、env で上書きされた場合はその値（秒）をタイムアウトに用いる。
4. Where `STAGE_A_VERIFY_COMMAND` env が空でない値で設定されているとき, the Watcher Stage A
   Verify Module shall `tasks.md` 解析を bypass し、当該 env 値を最優先で実行コマンドとして
   用いる。
5. The Watcher Stage A Verify Module shall 既存 env 名（`REPO`, `REPO_DIR`, `LOG_DIR`,
   `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）の意味・既定値を変更しない。

### Requirement 5: 観測可能性とログ規約

**Objective:** As a 運用者, I want stage-a-verify の結果を cron.log から grep で抽出できる
こと, so that 失敗解析・運用監視・dogfooding が効率化される。

#### Acceptance Criteria

1. When stage-a-verify が実行されたとき, the Watcher Stage A Verify Module shall cron.log に
   `stage-a-verify:` で始まる結果行を 1 件以上出力する。
2. When 結果行を出力するとき, the Watcher Stage A Verify Module shall 当該行の先頭に
   Issue #119 の規約に従う `[$REPO]` prefix を付与する。
3. If verify コマンドが SKIPPED となるとき, the Watcher Stage A Verify Module shall ログに
   `stage-a-verify: SKIPPED reason=no-verify-task-in-tasks-md` の形式で理由を含めて記録する。
4. If `STAGE_A_VERIFY_ENABLED=false` により本機能が無効化されているとき, the Watcher Stage A
   Verify Module shall ログに `stage-a-verify: DISABLED` を含む結果行を 1 件記録する。
5. When 再実行が成功または失敗したとき, the Watcher Stage A Verify Module shall ログに
   exit code とタイムアウト到達有無を識別できる情報を含めて記録する。

### Requirement 6: 責務境界の維持

**Objective:** As a エージェント運用設計者, I want stage-a-verify を導入しても他エージェント
の責務境界が変わらないこと, so that 既存の Reviewer / PjM / Developer の役割定義と整合する。

#### Acceptance Criteria

1. The Watcher Stage A Verify Module shall build / test / lint の独立検証を watcher 自身に
   集約し、Reviewer の判定カテゴリ（AC 未カバー・missing test・boundary 逸脱）を変更しない。
2. The Watcher Stage A Verify Module shall PjM の責務（PR 作成のみ）を変更せず、PjM 段階で
   build 実行を要求しない。
3. The Watcher Stage A Verify Module shall Developer の責務（`tasks.md` のタスク実装と
   commit push）を変更せず、Developer に新たな verify 実行義務を追加しない。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `STAGE_A_VERIFY_ENABLED` が未設定または `false` に設定されているとき, the Watcher
   Stage A Verify Module shall 本機能導入前と user-observable に同一の Stage A 完了判定を
   行う。
2. The Watcher Stage A Verify Module shall 既存ラベル名（`auto-dev`, `claude-claimed`,
   `claude-failed`, `needs-iteration` 等）の意味と遷移契約を変更しない。
3. The Watcher Stage A Verify Module shall 既存 exit code の意味（成功 0 / 失敗非 0 の慣習）
   を維持する。

### NFR 2: 言語非依存性

1. The Watcher Stage A Verify Module shall 抽出キーワード集合のみで verify タスクを認識し、
   特定言語ランタイム（Node.js / Python / Go 等）の存在を実行前提としない。
2. Where 抽出キーワード集合が新言語に未対応であるとき, the Watcher Stage A Verify Module
   shall `STAGE_A_VERIFY_COMMAND` env を escape hatch として運用者に提供し、コード変更なしで
   対応可能とする。

### NFR 3: 性能と時間境界

1. The Watcher Stage A Verify Module shall `tasks.md` の抽出処理を当該ファイルの行数に対して
   線形時間（O(N) ※N は行数）で完了する。
2. The Watcher Stage A Verify Module shall verify 再実行の最大経過時間を
   `STAGE_A_VERIFY_TIMEOUT`（既定 600 秒）以下に制限する。
3. If 大規模リポジトリで既定タイムアウト 600 秒が不足する運用者がいるとき, the Watcher
   Stage A Verify Module shall `STAGE_A_VERIFY_TIMEOUT` env で秒単位の延長を許可する。

### NFR 4: 観測可能性

1. The Watcher Stage A Verify Module shall stage-a-verify の全結果（実行成功・失敗・
   タイムアウト・SKIPPED・DISABLED）を cron.log に `[$REPO] stage-a-verify:` prefix 付きで
   1 行以上記録する。
2. The Watcher Stage A Verify Module shall ログから `grep '\[.*\] stage-a-verify:'` で
   全件抽出可能な形式で記録する。

### NFR 5: 副作用安全性

1. The Watcher Stage A Verify Module shall verify 再実行を REPO_DIR の範囲内で行い、
   REPO_DIR の外側へファイル書き込み・ネットワーク遮断・グローバル設定変更等を発生させない。
2. The Watcher Stage A Verify Module shall verify 再実行プロセスがタイムアウトに到達した
   とき、当該プロセスとその子孫プロセスを停止する。

### NFR 6: テスト可能性

1. The Watcher Stage A Verify Module shall 抽出キーワード集合に対する fixture テストを
   保持し、追加・削除があったときに回帰検出できる形にする。
2. The Watcher Stage A Verify Module shall 既存の Stage A / Stage B / Stage C の
   success / fail / escalate パスのテストを通過させたうえで、本要件の Requirement 1〜5 を
   カバーする fixture テストを追加する。

## Out of Scope

- Reviewer の判定カテゴリ拡張（build pass を追加する変更）。
- PjM 段階での build 実行。
- 言語固有 build tool wrapper（`gradlew` shim 等）の同梱。
- `impl-notes.md` の自由記述内容の検証・ガード。
- 既存 PR の遡及検証・修正。
- Stage B / Stage C への同等 build ガードの追加。
- 外部 Feature Flag SaaS との連携や A/B テスト機能。
- `tasks.md` 内の verify 行を AST レベルで解析する高度ヒューリスティクス。

## Open Questions

特になし。

仕様確定済みの判断事項:

- 差し戻し境界: 1 回目 fail で Developer 差し戻し、2 回目 fail で `claude-failed`
  エスカレート（Issue #122 の pr-iteration max 1 と整合）。
- 複合コマンドの扱い: 抽出行を `bash -c` で shell に渡し、`&&` `||` `;` 等は shell に解釈
  させる。
- `STAGE_A_VERIFY_TIMEOUT` 既定値: 600 秒。大規模リポジトリは env で延長可能。
- `STAGE_A_VERIFY_COMMAND` env の位置づけ: `tasks.md` 解析を bypass する最優先 escape hatch。
- 抽出キーワード集合の保守方針: 言語追加のたびに集合を編集。未対応言語は
  `STAGE_A_VERIFY_COMMAND` env で逃げる前提。
