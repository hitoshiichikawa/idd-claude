# Requirements Document

## Introduction

下流リポジトリ（ab-extweb #38）で、Developer は正常完了し Reviewer も approve 判定の意図を
口頭申告していたにもかかわらず、Reviewer subagent が `review-notes.md` を Write しないまま
rc=0 で終了したため、watcher が `review-notes.md` の不在を「装飾起因の RESULT 抽出失敗」と
同一視して `claude-failed` を付与する事故が発生した。本事故は #63（Reviewer 出力 parse-failed
緩和）が「ファイルは存在するが RESULT 行が装飾されている」ケースのみを対象とし、
**ファイルそのものが生成されない経路を意図的に parse-failed 扱いで維持**していたために残った
未カバー領域である。本要件は、ファイル不在のシグナルを装飾起因 parse 失敗と区別し、
1 回限定の Reviewer 再起動による復旧機会を持たせることで、Reviewer subagent の出力契約違反
に対する watcher の堅牢性を底上げする。同時に、LLM の口頭申告（orchestrator 最終メッセージや
トランスクリプト中の `RESULT:` 文字列）を判定の正本に採用しない方針を明文化する。

## Requirements

### Requirement 1: ファイル不在と装飾起因 parse 失敗の区別

**Objective:** As a watcher 運用者, I want Reviewer 結果パーサがファイル不在と装飾起因
RESULT 抽出失敗を区別してシグナルすること, so that リトライ可否と障害分類をログ・後段ロジック
の双方で明示的に判断できる。

#### Acceptance Criteria

1. When Reviewer の orchestrator プロセスが rc=0 で終了し、かつ `review-notes.md` が
   ファイルとして存在しないとき, the Reviewer Result Parser shall ファイル不在を表す専用
   シグナル（装飾起因の parse 失敗と区別可能な戻り値または reason 文字列）を返す。
2. When `review-notes.md` がファイルとして存在し、かつ RESULT トークンの抽出に失敗したとき,
   the Reviewer Result Parser shall #63 で確立した装飾耐性パースを経た上で、装飾起因の
   parse 失敗を表すシグナルを返す。
3. The Watcher shall ファイル不在シグナルを受けた場合と装飾起因 parse 失敗シグナルを受けた
   場合とで、運用ログ上の reason 文言を区別できる形で記録する。

### Requirement 2: ファイル不在時の 1 回限定リトライ

**Objective:** As a watcher 運用者, I want ファイル不在を検出したとき同一 round 内で
Reviewer を 1 回だけ再起動すること, so that Reviewer subagent の Write 漏れによる一過性の
取りこぼしを `claude-failed` 付与の前に救済できる。

#### Acceptance Criteria

1. When `review-notes.md` がファイル不在で Reviewer が rc=0 終了したとき, the Watcher shall
   同一 round 内で Reviewer を 1 回だけ再起動する。
2. When 再起動後の Reviewer 実行で `review-notes.md` が生成されたとき, the Watcher shall
   通常の判定経路（approve / reject）にそのまま進む。
3. If 再起動後も `review-notes.md` が生成されないとき, the Watcher shall `missing-file` を
   示す reason をログに記録した上で `claude-failed` を付与する。
4. The Watcher shall 同一 round 内におけるファイル不在起因の Reviewer 再起動回数を 1 回までに
   制限する。
5. The Watcher shall ファイル不在起因の再起動を実施したことが運用ログから判別できる形で
   記録する。

### Requirement 3: 口頭申告を判定の正本にしない

**Objective:** As a watcher 運用者, I want Reviewer 判定の正本を `review-notes.md` ファイル
内の `RESULT:` トークンのみに限定すること, so that orchestrator 最終メッセージや
トランスクリプト中に混入した `RESULT:` 文字列による誤判定を排除できる。

#### Acceptance Criteria

1. The Watcher shall Reviewer の approve / reject 判定を `review-notes.md` ファイル内の
   `RESULT:` トークンのみから決定する。
2. The Watcher shall orchestrator 最終メッセージ本文中の `RESULT:` 文字列を Reviewer 判定の
   正本として採用しない。
3. The Watcher shall Claude トランスクリプト（ルールファイル参照・書式例由来の文字列を含む）
   中の `RESULT:` 文字列を Reviewer 判定の正本として採用しない。

### Requirement 4: 単発・per-task 両経路への対称適用

**Objective:** As a watcher 運用者, I want ファイル不在検出・1 回限定リトライ・口頭申告の
非採用が単発 Reviewer と per-task Reviewer の双方に対称的に適用されること, so that 実行経路
ごとの挙動差による運用上の取りこぼしを発生させない。

#### Acceptance Criteria

1. The Watcher shall 単発 Reviewer 経路において Requirement 1〜3 で定義された挙動を満たす。
2. The Watcher shall per-task Reviewer 経路において Requirement 1〜3 で定義された挙動を満たす。
3. The Watcher shall Debugger 経由で再起動される Reviewer 経路においても Requirement 1〜3 で
   定義された挙動を満たす。

### Requirement 5: 既存装飾耐性パースの維持

**Objective:** As a watcher 運用者, I want #63 で確立した装飾耐性パース挙動が本変更で
リグレッションしないこと, so that 「ファイルが存在し RESULT 行が装飾されている」既存ケースが
引き続き approve / reject へ正しく到達する。

#### Acceptance Criteria

1. While `review-notes.md` がファイルとして存在し、RESULT 行がバッククォート・bullet・
   blockquote・インライン装飾のいずれかで包まれているとき, the Reviewer Result Parser shall
   #63 で確立した装飾耐性パース挙動を維持し、装飾を剥がして approve / reject を抽出する。
2. While `review-notes.md` がファイルとして存在し、RESULT 行が複数現れるとき, the Reviewer
   Result Parser shall #63 で確立した「最後のマッチを採用」挙動を維持する。
3. The Watcher shall 既存の装飾耐性パースを通過した結果に対して、本要件で追加するファイル
   不在シグナル経路を発火させない。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher shall 既存 env var 名・ラベル名・cron 登録文字列・watcher の exit code 意味を
   本変更で変更しない。
2. The Watcher shall 「ファイルが存在し RESULT トークンが装飾なし／装飾ありで抽出できる」
   既存の正常系ケースを本変更導入前と挙動同値で処理する。

### NFR 2: 観測可能性

1. The Watcher shall ファイル不在シグナル検出時に、対象 Issue 番号・round 番号・経路種別
   （単発 / per-task / Debugger 経由）・再起動実施有無・最終判定（approve / reject /
   missing-file claude-failed）を運用ログから一意に追跡できる形で記録する。
2. The Watcher shall `missing-file` reason を持つ `claude-failed` 付与イベントを、装飾起因
   `parse-failed` を持つ `claude-failed` 付与イベントと grep で区別できる文字列で出力する。

### NFR 3: 無限ループ防止

1. The Watcher shall ファイル不在起因の Reviewer 再起動回数を同一 round 内で 1 回までに
   制限し、これを上回る再起動を発生させない。
2. The Watcher shall ファイル不在起因の再起動が `claude-failed` に至った後、当該 round の
   範囲を超えてさらなる自動再起動を発生させない（既存 reject ループや Debugger 経路の上限
   と整合する）。

## Out of Scope

- orchestrator 最終メッセージやトランスクリプト中の `RESULT:` 文字列を fallback として
  Reviewer 判定に採用する案（Issue 本文の「案 B」相当）。LLM の Write 忘れの口頭申告を
  権威化するリスクが高く、トランスクリプトに `RESULT:` が多数混入する実情と相容れないため
  採用しない。
- #63 で確立した「ファイルがある場合の装飾耐性パース」自体の再設計（本要件は維持のみを
  扱い、パース仕様自体には踏み込まない）。
- quota / overloaded（HTTP 529）起因の Reviewer 失敗ハンドリング（別系統で既に処理済み）。
- `repo-template/.claude/agents/reviewer.md` の出力契約強化（Write 完了後の Read 再読込・
  最終行 verify・終了前 `ls` 出力など。Issue 本文「案 C」相当）。本変更を本 Issue に同梱
  するか別 Issue に切るかは「Open Questions」に記載した未決事項であり、人間判断を経て
  本 Issue から分離する場合は本要件のスコープから除外される。
- リトライ実施時の Reviewer subagent に与える `--max-turns` の同一 / 削減判断（Open Questions
  参照）。

## Open Questions

- ファイル不在起因のリトライを 1 回限定とする方針は Issue 本文の「推奨」として提示されている
  が、最終決定として確定するか（本要件は推奨どおり 1 回限定で記述したが、人間判断で 0 回
  または 2 回以上に変更する余地がある）。
- 案 D の戻り値設計（新規 rc コードを追加するか、reason 文字列のみで区別するか）は Issue
  本文で人間判断に委ねられている。本要件は observable な「区別可能性」のみ AC 化し、
  具体的な rc コード値や reason 文字列のリテラルは design.md / impl-notes.md の領分とした。
- 案 C（`reviewer.md` の出力契約強化）を本 Issue に同梱するか別 Issue に切るかは未確定。
  テンプレ配布の影響範囲が広い（root と repo-template の双方 + 既 installed consumer repo）
  ため、人間判断で別 Issue 化することを推奨する。
- リトライ時の Reviewer subagent に渡す `--max-turns` を初回と同一にするか、削減するか
  （Issue 本文で人間判断に委ねられている）。

## 関連

- Related: #63 #52 #76 #20
