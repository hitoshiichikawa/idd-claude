# Requirements Document

## Introduction

独立 Reviewer（per-task ループの独立 Reviewer と、非 per-task の単発 Reviewer の 2 経路）は、claude
実行が `error_max_turns`（turn 切れ起因の非ゼロ exit）で終了した場合に即座に error 扱いとなり、
caller が `claude-failed` を付与する。既存の attempt=2 リトライは `review-notes.md` 不在（rc=3）専用で
あり、turn 切れはリトライ対象に含まれていない。既定の `REVIEWER_MAX_TURNS=30` は大規模 spec / diff
では verdict（`review-notes.md` の `RESULT:` 行）に到達できないことがある。実地観測（feedman #207,
2026-06-24）では Developer の Stage A 実装が tasks.md 7/7 完了・push 済みであったにもかかわらず、34KB の
spec を読むうちに 31 turn で turn 切れ → `claude-failed` となり 5 日間放置された。本要件は、この turn
切れに限定した「拡張 turn 予算での 1 回リトライ」と、リトライ後も verdict 未到達だった場合の区別された
escalation を恒久対策として定義する。

## 用語

- **独立 Reviewer**: Developer 完了後に独立 context で起動される Reviewer。本要件では以下 2 経路の総称。
  - **per-task 経路**: per-task ループ内で task 単位に起動される独立 Reviewer。
  - **単発経路**: 非 per-task の Reviewer（round 1 / 2 / 3）。
- **verdict**: `review-notes.md` の `RESULT: approve|reject` 行から抽出される最終判定。
- **`error_max_turns`**: claude CLI が turn 上限到達で終了したことを示す result event の subtype
  （`{"type":"result","subtype":"error_max_turns","is_error":true}`）。turn 切れ起因の非ゼロ exit。
- **拡張リトライ**: turn 予算を通常より拡張した上で、同一 round 内で 1 回だけ再実行する救済。
- **`REVIEWER_MAX_TURNS`**: Reviewer 1 起動あたりの claude 実行 turn 数上限を表す既存 env var（既定 30）。
- **claude crash**: `error_max_turns` 以外の理由による claude の非ゼロ exit（プロセス異常終了等）。

## Requirements

### Requirement 1: turn 切れ起因の拡張リトライ

**Objective:** As a watcher 運用者, I want 独立 Reviewer の turn 切れを拡張 turn 予算で 1 回リトライする, so that 大規模 spec で verdict 未到達のまま即 `claude-failed` になり Issue が長期放置されることを防げる

#### Acceptance Criteria

1. If 独立 Reviewer の claude が `error_max_turns` で終了した場合, the watcher shall 同一 round 内で 1 回だけ拡張 turn 予算で Reviewer を再実行する。
2. When 拡張リトライ後に verdict が取得できた場合, the watcher shall 既存の verdict 経路（approve は return 0、reject は return 1）に合流する。
3. The watcher shall 拡張リトライを同一 round 内で最大 1 回に制限する（拡張リトライ後の turn 切れに対して更なる拡張リトライを行わない）。
4. Where per-task 経路が対象である場合, the watcher shall Requirement 1.1〜1.3 と同一の拡張リトライ挙動を提供する。
5. Where 単発経路が対象である場合, the watcher shall Requirement 1.1〜1.3 と同一の拡張リトライ挙動を提供する。

### Requirement 2: 拡張リトライ対象の境界

**Objective:** As a watcher 運用者, I want 拡張リトライを turn 切れに限定する, so that claude crash や parse 失敗まで巻き込んでリトライ予算を浪費せず障害の切り分けが保てる

#### Acceptance Criteria

1. If 独立 Reviewer の claude が `error_max_turns` 以外の理由で非ゼロ exit した場合, the watcher shall 拡張リトライを行わず従来どおり即 error として扱う。
2. If 独立 Reviewer の claude が rc=0 で終了したが `review-notes.md` が不在の場合, the watcher shall 従来の `review-notes.md` 不在リトライ経路（attempt=2）で処理し、拡張リトライ経路を起動しない。
3. If 独立 Reviewer の claude が rc=0 で終了したが `review-notes.md` の装飾起因 parse 失敗が発生した場合, the watcher shall 従来どおりリトライせず error として扱う。
4. When claude の終了が `error_max_turns` か否かを判定する場合, the watcher shall claude の stream-json 出力から抽出した最後の result イベントの subtype を判定根拠とする。

### Requirement 3: 拡張リトライ後の verdict 未到達 escalation

**Objective:** As a watcher 運用者, I want 拡張リトライ後も verdict 未到達だった場合を区別された理由で escalation する, so that 「turn 不足」と「claude crash / ファイル不在 / code reject」を運用者が切り分けて対処できる

#### Acceptance Criteria

1. If 拡張リトライ後も独立 Reviewer が `error_max_turns` で verdict 未到達のままである場合, the watcher shall 既存の `reviewer-error` / `reviewer-missing-file` / code reject のいずれとも区別される理由カテゴリで escalation する。
2. When Requirement 3.1 の escalation を行う場合, the watcher shall その理由が turn 切れ枯渇に起因することを Issue コメントに記録する。
3. When Requirement 3.1 の escalation を行う場合, the watcher shall run-summary に Reviewer が verdict 未到達（degraded）で終了したことを記録する。
4. The watcher shall Requirement 3.1 の理由カテゴリを、ログ上で `reviewer-error`（claude crash / parse 失敗）と grep で区別可能な文字列で発行する。
5. Where per-task 経路が対象である場合, the watcher shall Requirement 3.1〜3.4 と同一の区別された escalation 挙動を提供する。
6. Where 単発経路が対象である場合, the watcher shall Requirement 3.1〜3.4 と同一の区別された escalation 挙動を提供する。

### Requirement 4: 拡張 turn 予算の設定と後方互換

**Objective:** As a watcher 運用者, I want 拡張 turn 予算を後方互換な形で設定できる, so that 既定挙動を壊さず既存 override も尊重したまま turn 予算を調整できる

#### Acceptance Criteria

1. The watcher shall 拡張 turn 予算を `REVIEWER_MAX_TURNS` から導出可能な決定的な値として算出する（固定倍率または専用 env var による設定）。
2. While 拡張 turn 予算の設定 env var が未設定である場合, the watcher shall 導入前と矛盾しない既定値を用いて拡張リトライを実行する。
3. If 拡張 turn 予算の設定 env var に数値として解釈できない値が与えられた場合, the watcher shall その値を破棄して既定値にフォールバックする。
4. The watcher shall 拡張 turn 予算を、通常リトライの turn 予算（`REVIEWER_MAX_TURNS`）以上の値に正規化する。
5. If 運用者が `REVIEWER_MAX_TURNS` を明示的に override している場合, the watcher shall その override 値を尊重し、本変更による既定値更新で上書きしない。
6. When 拡張リトライを起動する場合, the watcher shall 拡張 turn 予算で claude を再実行したことをログに記録する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 本変更で導入する env var および既定値変更がいずれも非適用（未設定・既定）な場合, the watcher shall turn 切れ以外の全経路（claude crash / ファイル不在 / 装飾起因 parse 失敗 / approve / reject / quota 超過）について導入前と同一の挙動を維持する。
2. The watcher shall 既存 env var 名（`REVIEWER_MAX_TURNS` / `REVIEWER_MODEL` 等）・exit code の意味・ラベル遷移契約・ログ出力先を本変更で破壊しない。
3. If `REVIEWER_MAX_TURNS` の既定値を 30 から引き上げる場合, the watcher shall その migration note を README に記載する（既定値変更の事実と影響範囲を明記する）。

### NFR 2: 可観測性

1. When 拡張リトライを起動・完了する場合, the watcher shall 当該 round / attempt / 拡張 turn 予算をログに 1 行で記録する。
2. The watcher shall 拡張リトライの起動と turn 切れ枯渇 escalation を、既存の `reviewer-error` / `reviewer-missing-file` ログ行と grep で識別可能な reason 文字列で出力する。

### NFR 3: ドキュメント整合

1. When 本変更で外部挙動（env var / 既定値 / escalation 理由カテゴリ）を追加・変更する場合, the maintainer shall README の該当箇所（`REVIEWER_MAX_TURNS` 説明・オプション env var 一覧・Reviewer 障害カテゴリ説明）を同一 PR で更新する。

### NFR 4: 検証可能性

1. The maintainer shall 拡張リトライ判定・拡張 turn 予算正規化・turn 切れ枯渇 escalation の各分岐に対し、近接テスト（`local-watcher/test/<name>_test.sh`、`extract_function` 隔離抽出イディオム）を追加する。

## 受入基準のトレーサビリティ

| 観点 | 対応 AC |
|---|---|
| turn 切れ → 拡張 turn で 1 回リトライ（単発リトライ） | 1.1, 1.2, 1.3 |
| 両経路の対称修正（per-task / 単発） | 1.4, 1.5, 3.5, 3.6 |
| `error_max_turns` に限定（その他非ゼロ exit / ファイル不在 / parse 失敗は対象外） | 2.1, 2.2, 2.3, 2.4 |
| 拡張リトライ後の区別された理由カテゴリ + run-summary + Issue コメント | 3.1, 3.2, 3.3, 3.4 |
| 後方互換 / opt-in / 不正値の安全側正規化 / 既定値引き上げの override 尊重 | 4.1, 4.2, 4.3, 4.4, 4.5, NFR 1.1, NFR 1.2, NFR 1.3 |
| 可観測性（ログ） | 4.6, NFR 2.1, NFR 2.2 |
| README 同期 | NFR 3.1 |
| 近接テスト | NFR 4.1 |

## Out of Scope

- 本変更は `local-watcher/bin/issue-watcher.sh` 本体（および必要なら既存 module）のロジック修正であり、
  root ↔ repo-template の `.claude/{agents,rules}` byte 一致同期の対象ではない（agents / rules を編集しない）。
- Reviewer subagent 自身のプロンプト最適化・spec 要約戦略による turn 消費削減は本要件のスコープ外。
- Developer（実装系）/ Architect（設計系）/ Triage の turn 上限（`DEV_MAX_TURNS` / `TRIAGE_MAX_TURNS` 等）の
  見直しは本要件のスコープ外。
- 拡張リトライ回数を 2 回以上に増やす運用は本要件のスコープ外（同一 round 内で 1 回限定）。
- quota 超過（rc=99）経路の挙動変更は本要件のスコープ外（従来どおり quota 待ち遷移）。
- 拡張 turn 予算の動的・適応的算出（spec サイズや diff 量に応じた自動調整）は本要件のスコープ外。
  本要件は決定的な固定倍率または env var 設定に限る（動的化は Open Questions の検討事項とする）。

## Open Questions

人間決定が必要な点（Issue #442 に人間の実質コメントが無いため、Developer が進められるよう推奨既定を併記）:

1. 拡張 turn 予算の設定方式: 「`REVIEWER_MAX_TURNS` の固定倍率」か「専用 env var（例 `REVIEWER_MAX_TURNS_EXTENDED`）」か。
   - 推奨既定: 専用 env var を新設しつつ、未設定時は `REVIEWER_MAX_TURNS` の固定倍率（例 2 倍）にフォールバックする（両立案）。最終決定は Architect / 人間に委ねる。
2. `REVIEWER_MAX_TURNS` の既定値を 30 から引き上げるか、引き上げる場合の値。
   - 推奨既定: 引き上げを行う場合は実地観測（feedman の暫定 50）に整合する値（例 50）。引き上げ可否と具体値は人間判断。
   - 注: 既定値を据え置き、拡張リトライ予算のみで救済する案も成立する（NFR 1.1 を最も保守的に満たす）。
3. turn 切れ枯渇 escalation の理由カテゴリ識別子の最終名称（Issue draft では `reviewer-max-turns-exhausted` を仮置き）。
   - 推奨既定: `reviewer-max-turns-exhausted`（既存 `reviewer-error` / `reviewer-missing-file` と grep 区別可能）。
4. 拡張 turn 予算の動的・適応的算出（spec サイズ連動）を将来導入する余地を残すか。
   - 推奨既定: 本要件では固定方式に限り、動的化は別 Issue として切り出す（Out of Scope に明記済み）。

---

## 自己レビュー結果サマリ（requirements-review-gate）

**Mechanical Checks**

- Numeric ID: 全要件見出しが numeric ID（Requirement 1〜4、NFR 1〜4、AC は 1.1 形式）。英字 ID 不使用。OK
- AC の存在: 全要件・全 NFR に EARS 形式 AC（When / If / While / Where / The <system> shall）が 1 件以上。OK
- 実装語彙の混入: DB 名・フレームワーク名・API パターンの混入なし。`REVIEWER_MAX_TURNS` 等は既存 env var 名・
  ファイルパス（識別子として英語固定）であり実装方針の指定ではない。OK

**判断レビュー**

- スコープ・カバレッジ: 両経路の対称修正 / turn 切れ限定の境界 / 区別された escalation / 後方互換 / 可観測性 /
  README 同期 / テストを網羅。Out of Scope で範囲を明示。
- EARS・テスト可能性: 各 AC は 1 挙動・observable。曖昧語は env var / 既定値 / round / 1 回限定で具体化。
- 構造: 関連挙動を Requirement 1〜4 + NFR にグルーピングし、トレーサビリティ表で重複なく対応付け。
- 既存実装との整合: `issue-watcher.sh` の per-task 経路（~5160-5283）/ 単発経路（~7201-7329）、
  `REVIEWER_MAX_TURNS` 既定 30（行 1285）、`rs_record_reviewer` の degraded 記録、`reviewer-error` /
  `reviewer-missing-file` の既存カテゴリと矛盾しないことを確認。

判定: 1 パスでゲート通過。残存する曖昧点は Open Questions（4 件）に集約し人間にエスカレーション。
