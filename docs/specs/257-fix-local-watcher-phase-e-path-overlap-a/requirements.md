# Requirements Document

## Introduction

Phase E（Path Overlap Checker）の Dispatch Gate は、競合する in-flight Issue を検出した
候補 Issue に対して `awaiting-slot` ラベルを付与すると同時に、現在のブロッカー一覧を
表示する sticky comment（マーカー `<!-- idd-claude:awaiting-slot:v1 -->` 付き）を投稿し、
以降のサイクルでブロッカー集合が変化した場合は同一コメントを最新情報で上書き更新（PATCH）
する設計となっている。しかし現状の Dispatch Gate は、候補 Issue に既に `awaiting-slot`
ラベルが付与されている場合にコメント更新ロジックを呼び出さない分岐となっており、結果と
して sticky comment が古いブロッカー情報のまま放置される。先行 Issue が merge され別 Issue
が新たに競合に加わった等のケースで、運用者が Issue ページ上から最新の本質的ブロッカーを
視認できなくなるため、本機能を修正する。

## Requirements

### Requirement 1: Awaiting-slot sticky comment の最新化

**Objective:** As an idd-claude 運用者, I want 競合する in-flight Issue が変化したときに candidate Issue 上の awaiting-slot sticky comment が最新ブロッカー情報へ更新されること, so that 現在のブロッカーを Issue ページから常に正しく把握できる

#### Acceptance Criteria

1. When Phase E Dispatch Gate が candidate Issue について overlap を検出したとき, the Path Overlap Checker shall candidate Issue の `awaiting-slot` ラベル付与状態に関わらず、現在の overlap path と保持中 Issue 一覧を含む sticky comment 更新処理を実行する
2. When candidate Issue に既に `awaiting-slot` ラベルが付与されており、かつ overlap の内容が前回サイクルから変化したとき, the Path Overlap Checker shall 既存の sticky comment 本文を最新の overlap path と保持中 Issue 一覧へ上書き更新する
3. When candidate Issue に既存の awaiting-slot sticky comment が存在するとき, the Path Overlap Checker shall 同一 Issue 上に sticky comment を新規追加せず、既存コメントを上書き更新する形で最新化する
4. While 同一サイクル内で overlap が検出されているとき, the Path Overlap Checker shall sticky comment の更新が成功したか失敗したかを後続サイクルで再評価可能な形でログに記録する

### Requirement 2: 既存挙動の後方互換性

**Objective:** As an idd-claude 運用者, I want awaiting-slot ラベルの新規付与経路と sticky comment の新規作成経路が本修正前と同一の結果を保つこと, so that 既に main で稼働している Path Overlap Checker の挙動退行を起こさない

#### Acceptance Criteria

1. When Phase E Dispatch Gate が overlap を検出し、candidate Issue にまだ `awaiting-slot` ラベルが付与されていないとき, the Path Overlap Checker shall `awaiting-slot` ラベルを付与し、awaiting-slot sticky comment を 1 件新規投稿する
2. When 同一サイクル内で `awaiting-slot` ラベル付与処理が複数回試行されたとき, the Path Overlap Checker shall ラベルが多重に付与された状態を作らず、結果として 1 件の `awaiting-slot` ラベル付与状態を維持する
3. When Phase E Dispatch Gate が overlap を検出したとき, the Path Overlap Checker shall dispatch を見送る判定（candidate Issue を本サイクルで claim しない）を従来通り維持する
4. When Phase E Dispatch Gate が overlap が空になったことを検出し、かつ candidate Issue に `awaiting-slot` ラベルが付与されているとき, the Path Overlap Checker shall `awaiting-slot` ラベルを除去し dispatch を続行可能な状態に戻す
5. If `PATH_OVERLAP_CHECK` が `true` 以外（未設定 / off / 不正値）であるとき, the Path Overlap Checker shall 本機能修正前と完全に同一の挙動（gate を素通し）を維持する

### Requirement 3: Sticky comment 更新失敗時の挙動

**Objective:** As an idd-claude 運用者, I want sticky comment の上書き更新に失敗してもサイクル全体が破壊されないこと, so that 一時的な GitHub API 失敗があっても次サイクルで自然回復できる

#### Acceptance Criteria

1. If 既存 sticky comment の上書き更新が失敗したとき, the Path Overlap Checker shall 警告ログを出力した上で本サイクルの後続処理（dispatch 見送り判定）を継続する
2. If 既存 sticky comment の上書き更新が失敗したとき, the Path Overlap Checker shall watcher プロセス全体を異常終了させず、次サイクルで再度更新を試みる
3. While sticky comment の上書き更新が失敗している間でも, the Path Overlap Checker shall candidate Issue の `awaiting-slot` ラベル状態と dispatch 見送り判定を従来通り維持する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PATH_OVERLAP_CHECK` が `true` 以外であるとき, the Path Overlap Checker shall 本修正前と差分ゼロの挙動を維持し、`gh` API 呼び出し回数を本修正前から増やさない

### NFR 2: 可観測性

1. When awaiting-slot sticky comment の上書き更新が試行されたとき, the Path Overlap Checker shall candidate Issue 番号と更新可否を 1 行で識別可能なログに記録する

### NFR 3: 冪等性

1. While 同一サイクル内で同一 candidate Issue に対する awaiting-slot 更新処理が複数回呼ばれても, the Path Overlap Checker shall sticky comment を Issue あたり 1 件に保ち、ラベルも 1 件付与状態を保つ

## Out of Scope

- `awaiting-slot` 以外の待機系 sticky comment（例: busy-wait marker `<!-- idd-claude:busy-wait:v1 -->` / edit-paths marker `<!-- idd-claude:edit-paths:v1 -->` など）の PATCH 制御
- sticky comment 本文フォーマット（表形式 / md リスト形式）の仕様変更
- `awaiting-slot` ラベル名・marker 文字列の変更
- flock skip 経路（`po__visibility_evaluate_candidate` 配下）における同種挙動の変更（本修正は Dispatch Gate 経路 `po_check_dispatch_gate` を対象とする。flock skip 経路に同じ問題があるか否かの判定および修正は別 Issue として扱う）
- `PATH_OVERLAP_CHECK` の opt-in / opt-out 設計の変更

## Open Questions

- なし（Issue 本文に既出の決定事項のみで AC を確定できた）
