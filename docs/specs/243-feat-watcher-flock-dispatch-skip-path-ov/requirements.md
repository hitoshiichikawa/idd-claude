# Requirements Document

## Introduction

cron 起動された watcher は、repo 単位の単一実行ロック（`flock -n`）を取得できない場合に dispatch
ステージ全体を丸ごと skip して即時終了する。この skip 経路では auto-dev 候補に対する path-overlap
評価が一切走らないため、先行 Issue を別インスタンスが長サイクル処理している間、後続候補は
`awaiting-slot` ラベルも見送り理由コメントも付与されず「なぜ動かないのか」が GitHub 上から判別
できない状態になる。#228 / #229 の可視化はいずれも「dispatcher が起動して slot 枯渇に至った場合」を
前提とするため、flock を取得できず dispatcher 自体が起動しない本経路は依然として死角になっている。
本要件は、flock を取得できず dispatch を skip する場合でも、claim / dispatch を伴わない read＋label/comment
のみの path-overlap 可視化パスだけは実行し、待機中候補の見送り理由を Issue 上に残すことを定める。

## Requirements

### Requirement 1: flock skip 時の path-overlap 可視化パス実行

**Objective:** As a watcher 運用者, I want flock 取得失敗で dispatch を skip する場合でも auto-dev 候補に path-overlap 可視化パスが走ること, so that 別インスタンス稼働中に待機している候補の見送り理由を GitHub 上で確認できる

#### Acceptance Criteria

1. When cron 起動が flock 取得に失敗して dispatch を skip するとき, the watcher shall auto-dev 候補に対する path-overlap 可視化パスを実行する。
2. When 可視化パスが overlap を検出したとき, the watcher shall 当該候補へ `awaiting-slot` ラベルを付与する。
3. When 可視化パスが overlap を検出したとき, the watcher shall 当該候補へ見送り理由を含む sticky comment を post する。
4. When flock 取得に成功して dispatch を通常実行するとき, the watcher shall 本可視化パスを追加実行しない。

### Requirement 2: 可視化パスの非破壊性（read＋label/comment のみ）

**Objective:** As a watcher 運用者, I want 可視化パスが状態を変更する操作を行わないこと, so that flock skip 経路が並行する本サイクルの処理と競合しない

#### Acceptance Criteria

1. While 可視化パスが実行されているとき, the watcher shall claim および dispatch を行わない。
2. While 可視化パスが実行されているとき, the watcher shall worktree / slot / dispatch ロックを取得しない。
3. While 可視化パスが実行されているとき, the watcher shall in-flight 列挙と overlap 計算を read 専用で行う。
4. If 走行中の本サイクルが処理中（`claude-claimed` / `claude-picked-up`）の Issue があるとき, the watcher shall 当該 Issue のラベル・コメント・worktree を変更しない。

### Requirement 3: overlap 解消時の自己回復

**Objective:** As a watcher 運用者, I want overlap が解消した候補から可視化シグナルが自動的に取り除かれること, so that 解消済みの候補が `awaiting-slot` のまま放置されない

#### Acceptance Criteria

1. While 候補の overlap が解消した状態で次の本サイクルが当該候補を評価するとき, the watcher shall `awaiting-slot` ラベルを除去する。
2. The watcher shall flock skip 経路の可視化パスが付与した `awaiting-slot` を、通常 dispatch サイクルが除去できる状態に保つ。

### Requirement 4: 可視化パスの多重起動抑止

**Objective:** As a watcher 運用者, I want 可視化パスが同時に複数走らないこと, so that 同一 Issue へのラベル・コメント操作が衝突しない

#### Acceptance Criteria

1. If 可視化パスが多重に起動しうるとき, the watcher shall 同時に 1 実行のみを許容し、それ以外を skip する。
2. When 別の可視化パス実行が進行中で当該起動が抑止されるとき, the watcher shall 抑止された事実を識別可能なログとして出力する。

### Requirement 5: 可視化シグナルの冪等性

**Objective:** As a watcher 運用者, I want 同一の見送り状態に対して可視化シグナルが累積しないこと, so that cron tick ごとのコメント連投で Issue がノイズに埋もれない

#### Acceptance Criteria

1. When 同一候補の同一 overlap 状態が後続 cron tick で再評価されるとき, the watcher shall 既存 marker 付き sticky comment を更新し新規コメントを追加しない。
2. The watcher shall 1 つの見送り状態につき当該候補上の sticky comment を 1 件に保つ。
3. When 当該候補が既に `awaiting-slot` ラベルを保持しているとき, the watcher shall 同ラベルを重複付与しない。

### Requirement 6: opt-in gate と既存挙動の後方互換

**Objective:** As a watcher 運用者, I want 本機能が opt-in でのみ動作し既存運用を壊さないこと, so that self-hosting 環境で安全に段階導入できる

#### Acceptance Criteria

1. If path-overlap 機能が無効であるとき, the watcher shall flock skip 経路で可視化パスを一切実行しない。
2. While path-overlap 機能が無効であるとき, the watcher shall flock skip 時の挙動を本機能導入前と同一に保つ。
3. The watcher shall 既存の `awaiting-slot` ラベルの付与・除去契約を変更しない。
4. The watcher shall 既存 sticky comment の marker 方式と見送り理由コメントの投稿契約を変更しない。
5. The watcher shall 既存の env var 名・ラベル遷移契約・exit code の意味・既存ログ書式を変更しない。

### Requirement 7: 既存可視化機構の対象拡張に限定したスコープ

**Objective:** As a watcher 運用者, I want flock skip 経路の可視化が既存 path-overlap 評価を再利用する範囲に閉じること, so that 評価ロジックの分岐や精度差による予期しない挙動差が生じない

#### Acceptance Criteria

1. The watcher shall flock skip 経路の可視化パスで、通常 dispatch 経路と同一の overlap 判定規約を用いる。
2. The watcher shall flock skip 経路の可視化パスで、通常 dispatch 経路と同一の `awaiting-slot` ラベルおよび見送り理由 sticky comment の出力形式を用いる。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While path-overlap 機能が無効であるとき, the watcher shall flock skip 時の exit code を本機能導入前と同一の `0` に保つ。
2. The watcher shall flock 取得に成功した通常 cron 起動の全ステージ挙動を本可視化パス追加前と一切変更しない。

### NFR 2: gh API ノイズ・レート消費の抑制

1. The watcher shall flock skip 経路の可視化パスで発行する gh API 呼び出し回数を、見送り状態が変化しない候補について cron tick ごとに増加させない（既存 sticky comment 更新と冪等付与の範囲に抑える）。
2. While overlap 状態が前 tick から変化していない候補があるとき, the watcher shall 当該候補へ新規コメントを追加しない。

### NFR 3: 冪等性（self-hosting 前提）

1. When 可視化パスが同一状態で連続実行されるとき, the watcher shall Issue 上の可視化シグナル（ラベル・sticky comment）の集合を変化させない。
2. If 可視化パスの途中でラベル付与または in-flight 列挙が失敗するとき, the watcher shall watcher 全体を異常終了させず後続処理または正常終了を継続する。

### NFR 4: 可観測性

1. When 可視化パスが overlap を検出して `awaiting-slot` を付与するとき, the watcher shall 候補番号と検出 overlap を識別可能なログ行として出力する。
2. When flock skip 経路で可視化パスを起動するとき, the watcher shall 通常 dispatch 経路と区別可能な経路識別子をログに残す。

## Out of Scope

- 空き slot への随時投入によるスループット改善 / 再スキャン型スケジューラ（dispatch を伴う中核改修。別 Issue）
- 楽観的並行制御＋編集衝突の事後検出ラベル（別 Issue）
- Triage が推定する `edit_paths` の予測精度に依存する false-negative の改善（holder 相対化 #221 系）。本 Issue は「path-overlap 評価される機会を flock skip 経路にも与える」ことに限定し、評価精度そのものは扱わない
- flock skip 経路における claim / dispatch / worktree 操作の実行（本 Issue は read＋label/comment のみ）
- 多重起動抑止ロックの具体方式・評価頻度閾値・gh API 集約の具体設計値（Architect 領分。本要件では満たすべき観測可能な性質のみ規定）

## Open Questions

- なし（Issue 本文・関連コメントで決定済みの事項のみで要件化できた。多重起動抑止ロック方式・評価頻度閾値・既存 `po_*` 関数の新コンテキスト実行可否は Architect が確定する設計判断であり、本要件では観測可能な性質として記述した）
