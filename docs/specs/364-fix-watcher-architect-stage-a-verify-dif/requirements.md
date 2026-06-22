# Requirements Document

## Introduction

idd-claude の stage-a-verify gate (#125) は `tasks.md` の構造化 verify ブロックや
ヒューリスティック抽出から得た build/test/lint コマンドを REPO_DIR で独立再実行し、
exit code が 0 以外なら Stage A 不完全完了として扱う。この設計は Developer 自己申告のみで
build 不通が通る現象を防ぐ安全網だが、**`diff` コマンドがコマンドライン引数のパスを
解決できなかった場合（exit=2, `No such file or directory`）も exit≠0** として
verify 全体を fail させてしまう。

実害として Issue #362 の実装は 8 タスク完走・近接テスト 72 件 PASS・shellcheck クリーンの状態で
verify が `diff -r local-watcher/bin repo-template/local-watcher/bin` を含んで
いたため verify が exit=2 で false-fail し、コード品質に問題が無いにもかかわらず Stage A 差し戻し
／ escalate ループへ落ちた。idd-claude は **`local-watcher/` を `repo-template/` 配下に
ミラーしない**（`repo-template/local-watcher/` は存在しない / `install.sh` 経由で配布する）構造
であり、本来 Architect が生成すべき verify は `.claude/agents` と `.claude/rules` の 2 系統に
限定されるべきである。

本要件は (A) Architect 段階で「存在しないパスへの `diff` を verify に含めない」ことを
rule で明文化する root-cause fix と、(B) stage-a-verify 側で「パス不在に起因する `diff` 失敗を
コード品質失敗と区別する」defense-in-depth fix の双方を定義する。verify gate そのものは
維持し、real なテスト／lint／shellcheck 失敗（exit=1 等）は従来どおり `claude-failed` で
停止させる。

## Requirements

### Requirement 1: tasks-generation rule で存在しないパスの diff を抑止する

**Objective:** As an Architect, I want tasks.md の verify ブロック生成規約で「存在しないパスへの diff」を抑止できる規約を持つこと, so that Developer 実装が clean でも verify が false-fail する事故を Architect 段階で根絶できる

#### Acceptance Criteria

1. The tasks-generation rule shall verify ブロック内で `diff` コマンドを記述するときの「対象パスは tasks.md commit 時点の作業ツリーに存在すること」を必須要件として明文化する
2. The tasks-generation rule shall idd-claude では `local-watcher/` は `repo-template/` 配下にミラーされない（`repo-template/local-watcher/` は存在しない）旨と、それゆえ `diff -r local-watcher/* repo-template/local-watcher/*` 形のコマンドを verify に含めてはならない旨を明示する
3. The tasks-generation rule shall idd-claude における root↔repo-template 同期 diff の canonical 対象を `.claude/agents` と `.claude/rules` の 2 系統に限定する旨を明示する
4. Where verify ブロックがパス存在の不確定なディレクトリを参照する必要があるとき, the tasks-generation rule shall `[ -d <path> ] && diff -r <path> <path-mirror>` の形でパス存在ガードを置く書式を canonical として示す
5. The tasks-generation rule shall 本節の制約を構造化 verify ブロック (`<!-- stage-a-verify -->` + fence) とヒューリスティック抽出対象（行頭 keyword 一致）の双方に適用する旨を明示する

### Requirement 2: stage-a-verify が「パス不在」と「コード品質失敗」を区別する

**Objective:** As a watcher 運用者, I want stage-a-verify がパス不在による `diff` 失敗（exit=2）をコード品質失敗（exit=1 等）と区別すること, so that Architect が誤って verify に含めた存在しないパスが Developer 実装の false-fail を引き起こさない

#### Acceptance Criteria

1. When stage-a-verify が解決した verify コマンドを REPO_DIR で実行し、その失敗原因が `diff` の対象パス不在（`No such file or directory` を伴う exit=2）であるとき, the Watcher Stage A Verify Module shall 当該失敗を「コード品質失敗」として扱わず WARN 扱いに降格する
2. When 2.1 のパス不在を検出したとき, the Watcher Stage A Verify Module shall round counter を増やさず、Developer 差し戻し（`needs-iteration` 相当のコメント投稿）も `claude-failed` 付与も行わずに Stage A を続行する
3. When 2.1 のパス不在を検出したとき, the Watcher Stage A Verify Module shall ログに `stage-a-verify: WARN reason=verify-path-missing path=<検出パス>` の形で原因と当該パスを 1 行以上記録する
4. If verify コマンドの失敗原因が `diff` のパス不在ではない（real なテスト／lint／shellcheck 失敗の exit code、`diff` の content 差分 exit=1、`timeout` の exit=124 等）であるとき, the Watcher Stage A Verify Module shall 本要件導入前と同一の失敗判定（round=1 差し戻し → round=2 `claude-failed`）を維持する
5. While verify コマンドが `&&` / `||` / `;` で複数コマンドを連結しているとき, the Watcher Stage A Verify Module shall 連結コマンド中のいずれかのステップが「`diff` のパス不在」のみで終了した場合に限り 2.1〜2.3 を適用する（同じ連結内に real なテスト失敗が含まれる場合は 2.4 の従来挙動を優先する）

### Requirement 3: 既存 verify 経路の挙動を変えない（後方互換）

**Objective:** As a watcher 運用者, I want パス不在を含まない既存 verify が本変更前と同一挙動で動作すること, so that 本機能導入が既存運用に副作用を与えない

#### Acceptance Criteria

1. When verify ブロックが存在パスのみを参照する（`diff` のパス不在が発生しない）とき, the Watcher Stage A Verify Module shall 本要件導入前と user-observable に同一の Stage A 完了判定を行う
2. When `STAGE_A_VERIFY_ENABLED=false` が設定されているとき, the Watcher Stage A Verify Module shall stage-a-verify を実行せず本要件導入前と同一の挙動（DISABLED ログ + Stage A 続行）を行う
3. The Watcher Stage A Verify Module shall 既存 env 名（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` / `REPO` / `REPO_DIR` 等）の意味・既定値を変更しない
4. The Watcher Stage A Verify Module shall 既存ラベル名（`auto-dev` / `claude-claimed` / `claude-failed` / `needs-iteration` 等）の意味と遷移契約を変更しない
5. The Watcher Stage A Verify Module shall 構造化 verify ブロック由来 / `STAGE_A_VERIFY_COMMAND` env 由来 / ヒューリスティック抽出由来 の解決順序（#125 / #224）を変更しない

### Requirement 4: 観測可能性

**Objective:** As a watcher 運用者, I want パス不在による WARN 降格を cron.log から識別できること, so that false-fail を運用ログから事後追跡できる

#### Acceptance Criteria

1. When the Watcher Stage A Verify Module がパス不在 WARN 降格を行ったとき, the Watcher Stage A Verify Module shall ログに `stage-a-verify:` prefix 付きの WARN 行を 1 件以上出力する
2. The Watcher Stage A Verify Module shall パス不在 WARN 行に「実行した verify コマンド本体（または識別可能な断片）」と「パス不在と判定した根拠（`diff` の stderr 含む `No such file or directory` を含む断片）」の双方を含める
3. The Watcher Stage A Verify Module shall パス不在 WARN 行を `grep '\[.*\] stage-a-verify: WARN'` で全件抽出可能な形式で記録する
4. When the Watcher Stage A Verify Module がパス不在 WARN 降格で Stage A を続行したとき, the Watcher Stage A Verify Module shall 後段の run サマリに「verify 成功（success）」と区別可能な outcome（例: `warn-skipped` 等の機械可読な識別子）を記録する

### Requirement 5: 暫定運用解除の前提整備

**Objective:** As a watcher 運用者, I want 本 fix のリリース後に暫定的に設定していた `STAGE_A_VERIFY_ENABLED=false` を撤去できる状態にすること, so that stage-a-verify gate を本来の安全網として再有効化できる

#### Acceptance Criteria

1. The change shall README の Stage A Verify Gate 節に「パス不在 `diff` の WARN 降格」挙動と「Architect は verify に存在しないパスを含めない」旨を反映する
2. The change shall 本 fix リリース後に `STAGE_A_VERIFY_ENABLED=false` の暫定設定（Issue #362 false-fail 回避目的）を撤去可能であることを運用者向けドキュメント（`impl-notes.md` または README）に明示する
3. When 暫定設定撤去後に既定の `STAGE_A_VERIFY_ENABLED=true` で gate を再有効化したとき, the Watcher Stage A Verify Module shall パス不在 `diff` を含む新規 spec / 既存 spec に対しても false-fail を発生させない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While verify ブロックが存在パスのみを参照する既存 spec で動作するとき, the Watcher Stage A Verify Module shall 本要件導入前と byte-equivalent な external side effects（gh / git API 呼び出し / ラベル遷移 / commit / push）を生成する
2. The change shall 既存 exit code 意味（成功 0 / 失敗非 0 の慣習）を維持し、stage_a_verify_run の戻り値契約（0=success/skip/disabled, 1=round1 差し戻し, 2=round2 escalate）を変更しない
3. The tasks-generation rule の変更は既存 `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` / `- [ ]*` / `_Requirements_partial:_` / 構造化 verify ブロック (`<!-- stage-a-verify -->` + fence) の各規約を破壊的に変更しない

### NFR 2: 静的解析・テスト

1. The Watcher Stage A Verify Module の変更後コードは `shellcheck` と `bash -n` を pass する
2. The repository shall 近接 test (`local-watcher/test/`) として、少なくとも以下のケースを新規または拡張で含める: (a) verify コマンドが `diff -r <存在しないパス> <存在しないパス>` を含む場合に WARN 降格＋Stage A 続行となること, (b) verify コマンドが real な lint/test 失敗（shellcheck exit=1 等）を含む場合に従来どおり round=1 → round=2 で fail すること, (c) `diff` の exit=1（content 差分）が従来どおり fail として扱われること
3. The change shall root ↔ repo-template の `.claude/agents` / `.claude/rules` を byte 一致で同期し、`diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認できる手順を持つ

### NFR 3: ドキュメント

1. The README shall Stage A Verify Gate (#125) 節に「パス不在 `diff` の WARN 降格」挙動と「Architect は verify に存在しないパスを含めない」旨を反映する
2. The tasks-generation rule (`.claude/rules/tasks-generation.md`) の更新は repo-template (`repo-template/.claude/rules/tasks-generation.md`) と byte 一致で同期される

### NFR 4: 観測可能性

1. The Watcher Stage A Verify Module shall stage-a-verify の全結果（success / skip / disabled / round1 / round2 / WARN 降格）を cron.log に `[$REPO] stage-a-verify:` prefix 付きで 1 行以上記録する（NFR 4 of #125 を継承）
2. The Watcher Stage A Verify Module shall WARN 降格が連続発生する spec を運用者が `grep` で identification 可能にするため、4.1〜4.3 のログ形式を `grep` で機械抽出可能な固定 prefix（`stage-a-verify: WARN reason=verify-path-missing`）で出力する

## Out of Scope

- stage-a-verify gate そのものの廃止（Issue 本文「非スコープ」明記。gate は維持する）
- Architect / Developer の other rule 群（design-principles / ears-format / requirements-review-gate 等）の更新（本 fix は tasks-generation rule のみに閉じる）
- 過去に false-fail で `claude-failed` 化した Issue の遡及救済（本 fix は当該 fix 適用後の新規 spec から効果が出る）
- `diff` 以外のコマンドにおけるパス不在 false-fail 検出（`cat <存在しないファイル>` 等の汎用化は対象外。`diff` の `No such file or directory` パターンに限定）
- verify ブロックの厳密な lint / 事前検証ツール（Architect 自己レビュー時の Mechanical Check 強化）の追加（本 fix は rule 明文化 + runtime defense-in-depth のみで、自動 lint は別 Issue）
- `local-watcher/` を `repo-template/` 配下へミラーする方針変更（現行の install.sh 経由配布構造を維持する）

## Open Questions

- WARN 降格時の round counter リセット要否（同一 Issue で過去に real fail が round=1 まで進んでいた場合、その後 WARN 降格が発生したら round counter をリセットして「次の real fail を再び round=1 から評価する」べきか、それとも「過去の round 状態をそのまま維持する」べきか）— 本要件では Req 2.2 で「round counter を増やさない」のみを規定し、過去 round 状態の操作は design.md / Architect の判断に委ねる
- 連結コマンド中で「パス不在ステップ」と「real fail ステップ」が混在した場合の WARN 降格 vs fail の優先順位（Req 2.5 は「real fail を優先」と規定したが、複数 real fail と複数パス不在が混在する複雑ケースの境界判定は design.md で詳細化が必要）
- パス不在検出の実装手段（`diff` 実行前に awk で `diff -r <path>` を pre-scan して `[ -d <path> ]` で先回りチェックするか、`diff` 実行後の exit code 2 + stderr `No such file or directory` を事後判定するか）は Architect / Developer の領分

## 関連

- Depends on: なし（独立 fix）
- Parent: なし
- Related: #125 (stage-a-verify gate 元設計), #160 (verify 抽出キーワード厳格化), #224 (構造化 verify ブロック導入), #362 (false-fail 実害事例)
