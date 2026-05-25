# Requirements Document

## Introduction

stage-a-verify gate (#125) は Stage A（Developer 実装）完了直前に、`tasks.md` 中の
build/test/lint コマンドを watcher が独立再実行し、Developer の自己申告のみで build 不通が
Stage A を通過するのを防ぐゲートである。現状はコマンド特定を「verify keyword を含む行＝
コマンド」とみなすヒューリスティック抽出（output 側の推測）で行っているため、ツール名で
始まる散文（例: `- shellcheck 警告ゼロを確認`）を誤ってコマンドとして実行する誤発火が
#160 / #219 / #221 で繰り返し発生している。本要件は、verify コマンドを Architect が
**構造化ブロックで明示宣言する input 契約**へ移行し、ヒューリスティック推測を後方互換の
fallback に格下げすることで、散文誤認を構造的に根絶することを目的とする。既存 spec・
既存 env 運用・ラベル遷移・exit code の後方互換を一切壊さないことを必須条件とする。

## Requirements

### Requirement 1: 構造化 verify ブロックの input 契約

**Objective:** As a Architect, I want verify コマンドをセンチネル付きの構造化ブロックで `tasks.md` に明示宣言できること, so that ヒューリスティック推測に依存せず実行対象が決定論的に確定する

#### Acceptance Criteria

1. When `tasks.md` にセンチネル付きの構造化 verify ブロックが存在する場合, the stage-a-verify gate shall そのブロック内に記述されたコマンドのみを実行対象として解決する
2. When 構造化 verify ブロックが解決された場合, the stage-a-verify gate shall ヒューリスティック抽出を実行しない
3. The Architect shall verify コマンドを実行可能なコマンドそのもの（散文ではない形式）として構造化ブロック内に記述する
4. Where 構造化ブロックに複数行のコマンドまたは `&&` 連結が含まれる場合, the stage-a-verify gate shall それらを既存の Stage A Verify 実行契約（コマンド本体をそのまま実行し watcher 側で連結記号を解釈しない）に従って実行する
5. The stage-a-verify gate shall 構造化 verify ブロックの内容を、散文（コメント・説明箇条書き・タスク記述）と構造的に分離して解決する

### Requirement 2: 解決順序（fallback 連鎖）と後方互換

**Objective:** As a 運用者, I want verify コマンドの解決順序が決定論的かつ後方互換であること, so that 既存 spec や escape hatch 運用を壊さずに新方式へ段階移行できる

#### Acceptance Criteria

1. When 構造化 verify ブロックが存在しない場合, the stage-a-verify gate shall `STAGE_A_VERIFY_COMMAND` の値を次の解決候補として参照する
2. When 構造化 verify ブロックが存在せず `STAGE_A_VERIFY_COMMAND` も空の場合, the stage-a-verify gate shall 既存のヒューリスティック抽出を次の解決候補として実行する
3. When 構造化ブロック・`STAGE_A_VERIFY_COMMAND`・ヒューリスティック抽出のいずれでもコマンドを解決できない場合, the stage-a-verify gate shall SKIPPED として Stage A を続行させる
4. If 構造化 verify ブロックと `STAGE_A_VERIFY_COMMAND` の双方が存在する場合, the stage-a-verify gate shall いずれを優先するかを単一の決定論的順序で解決する（「確認事項」参照）
5. While `tasks.md` が存在しない design-less impl（例: #204）の場合, the stage-a-verify gate shall `STAGE_A_VERIFY_COMMAND` を含む既存の解決順序に倒して動作する

### Requirement 3: 信頼モデル（Architect が定義・Developer は不可侵）

**Objective:** As a Reviewer, I want verify コマンドが設計フェーズで人間レビュー済みになること, so that Developer の自己採点によって検証内容が骨抜きにされない

#### Acceptance Criteria

1. The Architect shall 構造化 verify ブロックを設計成果物（`tasks.md`）として定義し、設計 PR の人間レビュー対象に含める
2. The Developer shall 構造化 verify ブロックを書き換えない
3. If Developer が構造化 verify ブロックの記述内容と矛盾する点を見つけた場合, the Developer shall それを PR 本文の「確認事項」で指摘し、ブロック自体は変更しない

### Requirement 4: 書式の決定論化（ルール・プロンプトへの明文化）

**Objective:** As a Architect, I want 構造化 verify ブロックの書式が一意に定義されていること, so that 異なる Architect 実行間で書式が揺れず機械パースが安定する

#### Acceptance Criteria

1. The tasks-generation ルール shall 構造化 verify ブロックのセンチネル記法と記述書式を明文化する
2. The Architect プロンプト shall 構造化 verify ブロックを宣言する手順を含む
3. Where プロジェクトに verify 対象が存在する場合, the tasks-generation ルール shall verify ステップを散文ではなく実行可能コマンドの構造化ブロックで記述するよう要求する
4. The tasks-generation ルール shall 構造化 verify ブロックの記法を既存の checkbox タスク行規約および numeric ID 階層規約と矛盾しない形で規定する

### Requirement 5: 早期検証（design-review-gate Mechanical Check）

**Objective:** As a Architect, I want 構造化 verify ブロックの不備を確定前に検出できること, so that malformed なブロックが Developer フェーズまで持ち越されない

#### Acceptance Criteria

1. While Architect が `design.md` / `tasks.md` ドラフトを確定する前の自己レビュー段階の場合, the design-review-gate Mechanical Check shall 構造化 verify ブロックが well-formed であるかを判定する
2. If 構造化 verify ブロックが malformed である場合, the design-review-gate Mechanical Check shall 違反として報告し確定前の修正を促す
3. Where verify 対象を持つプロジェクトで構造化 verify ブロックも `STAGE_A_VERIFY_COMMAND` も存在しない場合, the design-review-gate Mechanical Check shall その状態を検出可能とする（検出時の扱いは「確認事項」参照）
4. The design-review-gate Mechanical Check shall 構造化 verify ブロックを持たない既存 spec を遡及的な違反として報告しない

### Requirement 6: ドキュメント整合（README）

**Objective:** As a 運用者, I want `STAGE_A_VERIFY_COMMAND` の用途と構造化ブロックとの関係が文書化されていること, so that どの方式をいつ使うべきかを誤解なく判断できる

#### Acceptance Criteria

1. The README shall 構造化 verify ブロックを verify コマンド解決の第一手段として説明する
2. The README shall 構造化ブロック・`STAGE_A_VERIFY_COMMAND`・ヒューリスティック抽出・SKIPPED の解決順序（fallback 連鎖）を記載する
3. The README shall `STAGE_A_VERIFY_COMMAND` を散文誤認を避けるための固定用途 escape hatch として位置づける説明を含む

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The stage-a-verify gate shall 構造化 verify ブロックを持たない既存 spec に対して、本機能導入前と user-observable に同一のヒューリスティック抽出挙動を維持する
2. While `STAGE_A_VERIFY_ENABLED=false` が明示指定されている場合, the stage-a-verify gate shall 本機能導入前と同一の skip 挙動を行う
3. The stage-a-verify gate shall 既存 env var 名（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND`）の意味と既定値を変更しない
4. The stage-a-verify gate shall 既存のラベル遷移契約（`needs-iteration` を Issue 側に付与しない等）・exit code 意味・round counter 挙動を変更しない

### NFR 2: 可観測性

1. When verify コマンドが解決された場合, the stage-a-verify gate shall どの解決手段（構造化ブロック / `STAGE_A_VERIFY_COMMAND` / ヒューリスティック）で解決したかを 1 行以上のログに記録する
2. The stage-a-verify gate shall 既存の `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` 3 段 prefix ログ書式を維持する

### NFR 3: 冪等性

1. The stage-a-verify gate shall 同一 `tasks.md` に対する複数回の解決呼び出しで、同一の解決結果（同一コマンドまたは同一 SKIPPED 判定）を返す
2. The 構造化 verify ブロックの解決処理 shall 副作用として `tasks.md` を書き換えない

### NFR 4: 言語非依存性

1. The 構造化 verify ブロックの解決処理 shall 特定言語の build tool に依存せず、任意の実行可能コマンド文字列を解決対象とする

## Out of Scope

- ヒューリスティック抽出（keyword 集合・awk 走査ロジック）そのものの仕様変更・keyword 追加。本要件は当該経路を fallback として温存するのみで、抽出ロジックの改修は扱わない
- `STAGE_A_VERIFY_TIMEOUT` の既定値・タイムアウト機構の変更
- round counter（差し戻し / escalate）の段数・判定ロジックの変更
- 外部 Feature Flag SaaS 連携や verify コマンドの動的出し分け
- 構造化ブロックを採用しない既存 spec の遡及的な書き換え（retrofit）
- verify コマンドの具体的なパース正規表現・モジュール分割・関数設計（design.md / Architect の領分）

## Open Questions

- 構造化ブロックのセンチネル記法（Issue 例では `<!-- stage-a-verify -->` 直後の fenced code block）の最終確定形と、`## Verify` 見出しの要否。Issue 本文は例示であり canonical 書式の細部（センチネルコメント文言・許容するフェンス言語タグ・複数ブロック時の扱い）は Architect が `.claude/rules/tasks-generation.md` で確定する必要がある
- Requirement 2.4: 構造化 verify ブロックと `STAGE_A_VERIFY_COMMAND` が双方存在する場合の優先順位。Issue の fallback 連鎖は「①構造化ブロック → ②`STAGE_A_VERIFY_COMMAND` → …」と構造化ブロック優先を示唆するが、現状実装では `STAGE_A_VERIFY_COMMAND` が最優先 escape hatch である。運用上の escape hatch 性（構造化ブロックが誤りでも env で強制上書きできる）を保つべきか、Issue 記載どおり構造化ブロックを最優先とするかは人間の確認が必要
- Requirement 5.3: verify 対象を持つはずのプロジェクトで構造化ブロックも `STAGE_A_VERIFY_COMMAND` も存在しない場合に、Mechanical Check を warn 止まりにするか reject にするか。design-less impl や verify 不要 spec を誤って reject しないための閾値判断は人間の方針確認が必要

## 関連

- Related: #125 #160 #219 #221 #223
