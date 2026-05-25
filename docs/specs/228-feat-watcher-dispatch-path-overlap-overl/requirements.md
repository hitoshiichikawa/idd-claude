# Requirements Document

## Introduction

watcher の dispatch 経路では、Issue が pickup されなかったときに「なぜ見送られたのか」が Issue 上に何も残らないことがある。#221 が長期間 unclaimed のまま放置された調査では、(A) path-overlap の false-negative（Triage 推定 edit_paths の prefix 欠落と正規化のズレで overlap が検出されず、結果として見送りコメントが投稿されなかった）と、(B) 多忙サイクル待ちの不可視（先行 Issue を slot が処理中／別 watcher インスタンス稼働で cron tick が繰り返し skip され、後続 Issue が「可視化マーカーゼロ」のまま停止して見える）という複合要因が判明した。本要件は、dispatch 見送りが発生したケースで運用者が読み取れる可視化シグナルを必ず Issue 上に残すことを保証する。なお path 正規化／holder 集合の堅牢化は #221 で main に merge 済みであるため、本 Issue では「false-negative が再発しても見送り判定と説明コメントが成立すること」を回帰検証として担保する点に重心を置く。

## Requirements

### Requirement 1: path-overlap 見送り時の可視化コメント

**Objective:** As a watcher 運用者, I want path-overlap で dispatch が見送られた Issue 上に見送り理由が必ず残ること, so that pickup されない理由を Issue を見るだけで判断できる

#### Acceptance Criteria

1. When path-overlap が dispatch を見送るとき, the Path Overlap Checker shall 見送り理由を含む sticky comment を当該 Issue へ投稿する。
2. When path-overlap が dispatch を見送るとき, the Path Overlap Checker shall 当該 Issue に `awaiting-slot` ラベルを付与する。
3. When path-overlap の見送り理由コメントを投稿するとき, the Path Overlap Checker shall 重複している top-level path と、それを保持している in-flight Issue 番号を本文に含める。
4. If `awaiting-slot` ラベルの付与に失敗したとき, the Path Overlap Checker shall 見送り理由 sticky comment の投稿を中止せず継続する。

### Requirement 2: Triage edit_paths の prefix 欠落に対する overlap 検出の頑健性（回帰検証）

**Objective:** As a watcher 運用者, I want Triage が推定した edit_paths に prefix 欠落があっても overlap が見逃されないこと, so that false-negative により見送りもコメントも発生しない事故が再発しない

#### Acceptance Criteria

1. If Triage の edit_paths が prefix を欠いた path を含み holder の正規化済み top-level と top-level 粒度で一致するとき, the Path Overlap Checker shall 当該 path を overlap として検出する。
2. When prefix 欠落由来の overlap を検出したとき, the Path Overlap Checker shall Requirement 1 の見送りコメント投稿と `awaiting-slot` 付与を成立させる。
3. The Path Overlap Checker shall candidate 側と holder 側の path を同一の正規化規約で突合する。
4. If candidate の edit_paths が空であるとき, the Path Overlap Checker shall overlap を検出せず dispatch を阻止しない。

### Requirement 3: 多忙サイクル待ちの可視化

**Objective:** As a watcher 運用者, I want 先行 Issue 処理中や別インスタンス稼働で pickup が繰り返し見送られている後続 Issue にも最小限のシグナルが残ること, so that 停止して見える Issue が実は待機中であることを運用者が判別できる

#### Acceptance Criteria

1. While 後続 Issue の pickup が空き slot 不足のため見送られている状態が可視化閾値を超えて継続するとき, the dispatcher shall 当該 Issue へ待機中であることを示す可視化シグナルを残す。
2. While 別 watcher インスタンス稼働により cron tick が pickup を見送る状態が可視化閾値を超えて継続するとき, the dispatcher shall 待機対象 Issue へ待機中であることを示す可視化シグナルを残す。
3. While 多忙サイクル待ちの可視化シグナルが残された Issue について見送り要因が解消したとき, the dispatcher shall 当該シグナルを除去または解消状態へ更新する。
4. While 多忙サイクル待ちの継続が可視化閾値に達していないとき, the dispatcher shall 可視化シグナルを残さない。

### Requirement 4: 見送りシグナルの冪等性（コメント連投の防止）

**Objective:** As a watcher 運用者, I want 同一の見送り状態に対して可視化シグナルが累積しないこと, so that cron tick ごとのコメント連投で Issue がノイズに埋もれない

#### Acceptance Criteria

1. When 同一 Issue の同一見送り状態が後続 cron tick で再評価されるとき, the dispatcher shall 既存マーカー（`<!-- idd-claude:... -->`）付き sticky comment を更新し新規コメントを追加しない。
2. The dispatcher shall 1 つの見送り状態につき当該 Issue 上の sticky comment を 1 件に保つ。
3. When 見送り状態が解消したとき, the dispatcher shall 対応するラベルを除去する。
4. While 既存の見送り理由コメントが残っている状態で見送りが解消したとき, the dispatcher shall 当該コメントを解消状態へ更新するか事後監査用に残置する。

### Requirement 5: 後方互換（opt-in gate と既存契約の維持）

**Objective:** As a watcher 運用者, I want 本機能が既存運用を一切壊さないこと, so that self-hosting 環境で安全に段階導入できる

#### Acceptance Criteria

1. If `PATH_OVERLAP_CHECK` が `true` 以外（未設定 / 空 / `false` / `0` / `True` / `1` / typo 等）であるとき, the dispatcher shall path-overlap 由来の見送り処理を一切実行しない。
2. While `PATH_OVERLAP_CHECK` が無効であるとき, the dispatcher shall 本機能導入前と同一の dispatch 挙動・ログ書式・exit code を維持する。
3. The dispatcher shall 既存の `awaiting-slot` ラベル名・sticky comment 方式・`idd-claude:` 系マーカーの契約を変更しない。
4. The dispatcher shall 既存の環境変数名・ラベル遷移契約を変更しない。
5. When 単一ブランチ運用（`staged-for-release` を使わない構成）で dispatch が行われるとき, the Path Overlap Checker shall 本機能導入前と同一の overlap 判定結果を生成する。

## Non-Functional Requirements

### NFR 1: ノイズ抑制（可視化閾値の保守的設定）

1. While 多忙サイクル待ちが一過性（transient）であるとき, the dispatcher shall 可視化閾値に達するまで Issue へコメントを残さない。
2. The dispatcher shall 同一 Issue・同一見送り状態に対して cron tick あたり 1 件を超える新規コメントを追加しない。

### NFR 2: 冪等性（self-hosting 前提）

1. When 同一の見送り状態で本機能を繰り返し実行するとき, the dispatcher shall 既存のラベル・sticky comment 状態を破壊せず同一の最終状態へ収束する。
2. If 見送りシグナルの投稿または更新が失敗したとき, the dispatcher shall 次 cron tick で再試行し重複コメントを生成しない。

### NFR 3: 可観測性

1. When path-overlap が見送りを行うとき, the dispatcher shall 重複 path と holder Issue 番号を含む 1 行のログを `stdout` に出力する。
2. If holder Issue 番号が解決できないとき, the dispatcher shall holder 欠落の事実をログに明示する（空欄で黙殺しない）。

### NFR 4: API 呼び出し回数

1. The Path Overlap Checker shall in-flight Issue の列挙を 1 cron tick あたり 1 回に保ち、本機能導入前から Issue 列挙 API 呼び出し回数を増やさない。
2. The Path Overlap Checker shall 各 candidate Issue あたりの edit_paths 読み出し API 呼び出し回数を本機能導入前と同じく 1 回に保つ。

## Out of Scope

- path 正規化規約および holder ラベル集合の base 相対化そのものの再実装（#221 で main に merge 済み。本 Issue は回帰検証 AC としてのみ扱う）。
- Triage が推定する edit_paths の精度向上（prefix を完全に埋めるための Triage プロンプト改善）。
- `awaiting-slot` 以外の既存ラベル遷移・状態機械の意味変更。
- multi-branch（gitflow）／promote-pipeline の holder 判定ロジックの変更（#221 の契約を踏襲）。
- 多忙サイクル待ちの根本解消（slot 数増加・並列度向上・スケジューラ変更などの能力改善）。本 Issue は可視化のみを対象とする。
- 可視化シグナルの自動エスカレーション（人間への通知・PR 自動生成・auto-unblock）。

## Open Questions

- Requirement 3 / NFR 1 の「可視化閾値」の具体値（Issue 本文では `N tick` / `M 分` を例示にとどめている）。閾値の単位（cron tick 数か経過時間か）と既定値、および env var による override 可否は未確定であり、design.md での決定または人間判断を要する。
- 多忙サイクル待ちの可視化シグナルの実現手段（既存 `awaiting-slot` 系 sticky comment の流用か、別マーカー／別ラベルの新設か）。Requirement 5.3 の「既存マーカー契約を変更しない」制約と整合する範囲で design.md にて決定する必要がある。
- 別 watcher インスタンス稼働による cron tick skip（flock レベルの skip）時に、待機対象 Issue を一意に特定して可視化シグナルを残す対象範囲（全 open candidate か、次サイクル先頭候補のみか）の確定。
