# Requirements Document

## Introduction

idd-claude の watcher は、Issue 処理時に `docs/specs/<N>-*/` を「Issue 番号一致だけ」で
検出して Stage Checkpoint Resume の起点を決めている。このため fork / mirror clone された
リポジトリで番号衝突が起きた場合、無関係な過去 Issue の spec dir / ブランチを resume してしまい、
別の Issue の文脈で実装が進む実害が発生する（実例: `hitoshiichikawa/keynest_for_mimamowellness` で
別 Issue の `docs/specs/68-*/` を再利用してしまった事例）。

本要件は、Issue タイトル由来の正規化済みスラグと既存 spec dir / 既存ブランチ名のスラグ部を
照合し、不一致のとき Resume を中止して人間判断に委ねるための挙動を定義する。スラグ一致時の
従来挙動は保ったまま、誤判定経路だけを安全側に倒すことを目的とする。

## Requirements

### Requirement 1: スラグ照合に基づく Stage Checkpoint Resume の起点判定

**Objective:** As a watcher 運用者, I want 既存 spec dir を Issue 番号とスラグの両方で照合する挙動, so that fork / mirror clone リポジトリで他 Issue の成果物を誤って resume せずに済む

#### Acceptance Criteria

1. When watcher が Issue 処理を開始するとき, the Watcher shall Issue タイトルから正規化規則に従って期待スラグ（expected-slug）を導出する
2. When `docs/specs/<N>-*/` ディレクトリが検出されたとき, the Watcher shall そのディレクトリ名の `<N>-` 以降を `<found-slug>` として抽出し expected-slug と比較する
3. When expected-slug と `<found-slug>` が一致したとき, the Watcher shall 従来どおり Stage Checkpoint Resume を継続する
4. If expected-slug と `<found-slug>` が一致しないとき, the Watcher shall 当該 Issue の Stage Checkpoint Resume を中止する
5. If `docs/specs/<N>-*/` が複数存在しいずれも expected-slug と一致しないとき, the Watcher shall Stage Checkpoint Resume を中止する
6. Where `docs/specs/<N>-*/` が存在しないとき, the Watcher shall 本要件によるスラグ照合判定を発火させず従来どおり新規スラグを導出する

### Requirement 2: 既存ブランチからの Resume におけるスラグ照合

**Objective:** As a watcher 運用者, I want `claude/issue-<N>-impl-<slug>` ブランチを resume する判定にも同じスラグ照合を効かせること, so that ブランチ経路でも誤った Issue 文脈を継承しない

#### Acceptance Criteria

1. When watcher が `claude/issue-<N>-impl-*` 形式の既存リモートブランチを resume 候補として検出したとき, the Watcher shall ブランチ名の `impl-` 以降を `<branch-slug>` として抽出し expected-slug と比較する
2. When expected-slug と `<branch-slug>` が一致したとき, the Watcher shall 従来どおり当該ブランチからの resume を継続する
3. If expected-slug と `<branch-slug>` が一致しないとき, the Watcher shall 当該ブランチを resume 候補から除外し Stage Checkpoint Resume を中止する

### Requirement 3: 不一致検出時のエスカレーション

**Objective:** As a watcher 運用者, I want スラグ不一致を検出した Issue を自動処理せず人間判断に回すこと, so that 誤った文脈での実装が main に向かわない

#### Acceptance Criteria

1. If Requirement 1 または Requirement 2 でスラグ不一致を検出したとき, the Watcher shall 当該 Issue に `needs-decisions` ラベルを付与する
2. If スラグ不一致を検出したとき, the Watcher shall 当該 Issue に不一致の事実と人間判断を求める旨を述べたコメントを 1 件投稿する
3. When スラグ不一致による Resume 中止を完了したとき, the Watcher shall 当該 Issue の処理を skip して次の Issue へ進む
4. While スラグ不一致による Resume 中止が選択されているとき, the Watcher shall 当該 Issue に対して新規ブランチ作成・新規 spec dir 生成・既存 spec dir の自動削除のいずれも行わない

### Requirement 4: スラグ照合判定のログ可観測性

**Objective:** As a watcher 運用者, I want スラグ照合の結果がログから機械的に抽出できること, so that 障害発生時に grep で原因を辿れる

#### Acceptance Criteria

1. When Requirement 1 のスラグ照合が pass したとき, the Watcher shall ログに `stage-checkpoint:` prefix で 1 行のイベントを記録する
2. When Requirement 1 のスラグ照合が mismatch を検出したとき, the Watcher shall ログに `stage-checkpoint:` prefix で issue 番号・expected-slug・found-slug を含む 1 行のイベントを記録する
3. When Requirement 2 のブランチスラグ照合が発生したとき, the Watcher shall ログに `resume-branch:` prefix で pass / mismatch どちらの結果も 1 行のイベントとして記録する

### Requirement 5: スラグ正規化規則の単一定義

**Objective:** As a watcher 開発者, I want watcher 内のスラグ正規化規則を 1 か所で管理すること, so that 二重定義による不整合を将来にわたって防ぐ

#### Acceptance Criteria

1. The Watcher shall Issue タイトルを「lowercase 化 / `a-z0-9` 以外の連続文字をハイフン 1 個へ縮約 / 先頭 40 文字へ切り詰め / 末尾ハイフン除去」の順で適用してスラグを導出する
2. The Watcher shall 上記正規化規則を 1 つの共通関数として実装し expected-slug の導出・既存 spec dir 検出・既存ブランチ照合のすべてから当該関数を参照する
3. While watcher 内に正規化ロジックが存在しているとき, the Watcher shall 同一ファイル内に同等の正規化を行う重複コードを残さない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While Issue 番号もスラグも一致する既存 spec dir が存在するとき, the Watcher shall 本要件導入前と同一の Stage Checkpoint Resume 経路（resume-mode・ブランチ起点・push 戦略）を選択する
2. The Watcher shall 既存の環境変数名・既存ログ prefix（`stage-checkpoint:`）・既存ラベル名（`needs-decisions`）・cron 登録文字列を変更しない
3. While `docs/specs/<N>-*/` が存在しないとき, the Watcher shall 本要件導入前と同一の新規スラグ導出経路を選択する

### NFR 2: 異常系の安全側挙動

1. If スラグ照合の判定中に I/O エラーや想定外の入力を観測したとき, the Watcher shall Stage Checkpoint Resume を継続せず Requirement 3 の不一致時と同等のエスカレーション経路に倒す
2. The Watcher shall 既存 spec dir / 既存ブランチを自動削除・自動リネーム・自動上書きしない

### NFR 3: 可観測性の運用基準

1. The Watcher shall Requirement 4 のログ行を 1 イベント 1 行で出力し改行を含めない
2. The Watcher shall Requirement 4 のログ行に issue 番号と expected-slug と found-slug（または branch-slug）の 3 値をすべて含める

## Out of Scope

- fork / mirror clone そのものを watcher 側で検出・拒否する仕組み
- 番号一致・スラグ不一致の既存 spec dir を自動で削除・退避・リネームする処理
- Stage Checkpoint Resume の根本再設計（番号 + スラグ以外の照合キー、例えば Issue 作成者・タイトル全文・SHA 等の導入）
- watcher 外（agent 側プロンプト・テンプレート・README 等）にあるスラグ正規化規則のリファクタ（本要件は watcher 内の単一定義化までを対象とする）
- スラグ不一致時のエスカレーション先を `needs-decisions` 以外（例: `claude-failed`）に切り替える運用判断

## Open Questions

- なし（Issue 本文「仮案・判断を委ねたい点」のうち、不一致時のラベルは `needs-decisions` を採用し、スラグ正規化の共通関数化は本 Issue 内で完結させる方針で確定）
