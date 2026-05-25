# Requirements Document

## Introduction

impl / impl-resume の watcher サイクルでは `run_impl_pipeline` が冒頭で 1 回だけ既存 impl PR を観測し、その後 Stage A → Stage C を順に実行する。Stage A の worker が「PR 作成禁止」制約に違反して PjM まで越境起動し PR を作成しても、Stage C はサイクル開始後の状態を再評価せず同一 head ブランチから 2 本目の PR を作成してしまう（2026-05-25 の Cycle B で PR#210 に続き PR#211 が重複生成された実例あり）。本要件は、Stage C の PR 作成直前に同一 head ブランチの既存 impl PR を再確認する冪等ガードを定義し、二重 PR の発生を防ぐことを目的とする。直接原因（Stage A の越境）の是正は対象外で、本要件は構造的な多重防御（PR 作成段階での冪等性確保）に限定する。本ガードは Stage Checkpoint モジュールの観測ヘルパ（`stage_checkpoint_find_impl_pr`）を再利用するため、同モジュールと整合させ `STAGE_CHECKPOINT_ENABLED=true`（#112 以降の既定）時のみ有効化する。

## Requirements

### Requirement 1: Stage C PR 作成直前の既存 PR 再確認

**Objective:** As a watcher 運用者, I want Stage C が PR 作成に進む直前に同一 head ブランチの既存 impl PR を再確認すること, so that 同一サイクル内で Stage A が先行して PR を作成していても二重 PR を生まないようにできる

#### Acceptance Criteria

1. While `STAGE_CHECKPOINT_ENABLED=true`（既定）であるとき, when Stage C が PjM 起動による PR 作成処理へ進む直前に到達したとき, the Watcher shall 同一 head ブランチに紐づく既存 impl PR の有無と状態を観測する
2. While `STAGE_CHECKPOINT_ENABLED` が `true` 以外（明示 opt-out その他の任意の値）であるとき, the Watcher shall 本冪等ガードを実行せず本修正導入前と完全に同一の Stage C 挙動を保つ
3. When 既存 PR を観測する処理が実行されるとき, the Watcher shall OPEN / MERGED / CLOSED の状態を区別して判定する
4. The Watcher shall 既存 PR の観測をサイクル開始時の 1 回だけでなく Stage C の PR 作成直前にも実施する

### Requirement 2: 既存 OPEN PR 検出時の重複作成抑止

**Objective:** As a watcher 運用者, I want 同一 head ブランチに OPEN の impl PR が既に存在する場合は新規 PR を作成せず既存 PR を再利用すること, so that 不要な重複 PR の手動削除作業を発生させずに済む

#### Acceptance Criteria

1. When Stage C の PR 作成直前に同一 head ブランチの既存 impl PR が OPEN 状態で検出されたとき, the Watcher shall 新規 PR を作成しない
2. When 既存 OPEN PR を検出して新規作成を抑止したとき, the Watcher shall 自動進行を停止し成功扱い（既存 TERMINAL_OK と同一の return 0）で終了する
3. When 既存 OPEN PR を検出して自動進行を停止したとき, the Watcher shall 検出した PR 番号と状態を含む判定根拠を既存ログ書式でログへ出力する
4. When 既存 OPEN PR を検出して自動進行を停止したとき, the Watcher shall 当該 Issue へコメントを投稿しない

### Requirement 3: 既存 MERGED PR 検出時の着地済み停止

**Objective:** As a watcher 運用者, I want 同一 head ブランチの impl PR が既に MERGED 済みの場合は着地済みとみなして自動進行を停止すること, so that マージ済みブランチに重複 PR を起こさず冪等に終了できる

#### Acceptance Criteria

1. When Stage C の PR 作成直前に同一 head ブランチの既存 impl PR が MERGED 状態で検出されたとき, the Watcher shall 新規 PR を作成しない
2. When 既存 MERGED PR を検出したとき, the Watcher shall 着地済みとみなして自動進行を停止し成功扱い（既存 TERMINAL_OK と同一の return 0）で終了する
3. When 既存 MERGED PR を検出して自動進行を停止したとき, the Watcher shall 検出した PR 番号と状態を含む判定根拠を既存ログ書式でログへ出力する
4. When 既存 MERGED PR を検出して自動進行を停止したとき, the Watcher shall 当該 Issue へコメントを投稿しない

### Requirement 4: 既存 CLOSED PR 検出時の人間判断委譲

**Objective:** As a watcher 運用者, I want 同一 head ブランチの impl PR が CLOSED 済みの場合は自動で再作成せず人間判断に委ねること, so that 人間が意図的に close した PR を自動再生成して運用判断を上書きしないようにできる

#### Acceptance Criteria

1. When Stage C の PR 作成直前に同一 head ブランチの既存 impl PR が CLOSED 状態で検出されたとき, the Watcher shall 新規 PR を作成しない
2. When 既存 CLOSED PR を検出したとき, the Watcher shall 当該 Issue に `needs-decisions` ラベルを付与する
3. When 既存 CLOSED PR を検出したとき, the Watcher shall 検出した PR 番号と人間判断が必要である旨を含むコメントを当該 Issue に 1 件投稿する
4. When 既存 CLOSED PR を検出して人間判断に委ねたとき, the Watcher shall `claude-failed` ラベルを付与しない
5. When 既存 CLOSED PR を検出して人間判断に委ねたとき, the Watcher shall 自動進行を停止し成功扱い（return 0）で終了する

### Requirement 5: 既存 PR が無い通常ケースの挙動維持

**Objective:** As a watcher 運用者, I want 同一 head ブランチに既存 impl PR が無い通常ケースでは従来どおり PR を 1 本作成すること, so that 本修正導入による正常フローへの影響を排除できる

#### Acceptance Criteria

1. When Stage C の PR 作成直前に同一 head ブランチの既存 impl PR が検出されなかったとき, the Watcher shall 従来どおり PjM 起動による PR 作成処理を実行する
2. While 既存 PR が無い通常ケースであるとき, the Watcher shall 本修正導入前と user-observable な挙動（PR 作成本数・成功ログ・return 値）を変えない

### Requirement 6: gh API エラー時の安全側フォールバック

**Objective:** As a watcher 運用者, I want 既存 PR 観測が gh API エラーで失敗した場合に安全側の挙動を選ぶこと, so that 一時的な API 障害でガード自体が誤判定して運用を壊さないようにできる

#### Acceptance Criteria

1. If Stage C の PR 作成直前に既存 PR を観測する処理が gh API エラーで失敗したとき, the Watcher shall その旨を警告として既存ログ書式でログへ出力する
2. If 既存 PR 観測が gh API エラーで失敗したとき, the Watcher shall 既存 PR の有無を確定できないものとして扱い、新規 PR 作成へ進む（既存 `stage_checkpoint_resolve_resume_point` の API エラー fallback と同方針で、作成方向へフォールバックする）
3. If 既存 PR 観測が gh API エラーで失敗して新規 PR 作成へ進んだとき, the Watcher shall 二重 PR の可能性がある旨を警告として既存ログ書式でログへ出力する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 既存 impl PR が無い通常フローであるとき, the Watcher shall 本修正導入前と完全に同一の PR 作成本数（1 本）を生成する
2. While `STAGE_CHECKPOINT_ENABLED` が `true` 以外であるとき, the Watcher shall 本冪等ガードによる PR 作成本数・ログ・return 値の差分を一切生じさせない
3. The Watcher shall 既存の env var 名（`STAGE_CHECKPOINT_ENABLED` 等）の意味と既定値を変更しない
4. The Watcher shall 既存のラベル遷移契約（`claude-picked-up` / `claude-failed` / `needs-decisions` の付与・除去の意味）を変更しない
5. The Watcher shall Stage C 成功時の return 0 / 失敗時の return 1 という既存 exit code の意味を変更しない
6. The Watcher shall 既存ログ行（Stage C 成功ログ・TERMINAL_OK ログ）の書式を変更しない

### NFR 2: 冪等性

1. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when 同一 head ブランチに対して Stage C の PR 作成処理が 2 回以上到達したとき, the Watcher shall 最初の 1 本を超える impl PR を作成しない
2. While self-hosting 環境（idd-claude 自身を対象 repo として運用する状態）であるとき, the Watcher shall 同一サイクルの再実行で重複 PR を生成しない

### NFR 3: 可観測性

1. When 既存 PR の状態に応じて新規作成を抑止したとき, the Watcher shall 抑止理由（OPEN 再利用 / MERGED 着地済み / CLOSED 人間判断）を人間が grep で識別可能な粒度でログへ出力する
2. If gh API エラーで作成方向へフォールバックしたとき, the Watcher shall その判定根拠（API エラー発生・観測結果 unknown・作成方向フォールバック）を人間が grep で識別可能な粒度でログへ出力する

## Out of Scope

- Stage A の worker が boundary を越境して PjM を起動し PR を作成すること自体の防止（直接原因の是正）。本要件は PR 作成段階での冪等ガード（多重防御）に限定する。
- 既に作成されてしまった重複 PR（実例の PR#211 相当）の自動 close / 自動削除。
- Stage A 越境時に作られた PR の本文・タイトル・ラベルの正当性検証や補正。
- サイクル開始時の `resolve_resume_point` における既存 PR 観測ロジックの変更（既存挙動は維持）。
- gh API 以外（GitHub Webhook / Actions 連携等）を用いた重複検出手段の導入。
- `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）環境での二重 PR 防止。本ガードは Stage Checkpoint モジュールと整合させ opt-out 時は無効とするため、opt-out 環境での重複は対象外（NFR 1.2）。

## Resolved Decisions（オーケストレーター確定）

当初 draft の「確認事項」3 点は、idd-claude の後方互換最優先・既存挙動との一貫性の原則に基づき以下の通り確定し、各 Requirement 本文へ畳み込んだ。決定根拠を追跡可能とするため本セクションに残す。

- **冪等ガードの gate 範囲（Requirement 1.1 / 1.2 / NFR 1.2 / NFR 2.1 / Out of Scope に反映）**: `STAGE_CHECKPOINT_ENABLED=true` 時のみ gate する。本ガードが再利用する `stage_checkpoint_find_impl_pr` は Stage Checkpoint モジュールの一部であり同モジュールと整合させる。CLAUDE.md は `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）時に「本機能導入前と 1 行も挙動を変えない」ことを保証する。既定は true（#112 以降）のため実運用の観測事例（#204）は本ガードで解消される。
- **gh API エラー時の安全側フォールバック（Requirement 6.2 / 6.3 / NFR 3.2 に反映）**: PR 作成へ進む。既存 `stage_checkpoint_resolve_resume_point` は `gh pr list` 失敗時に判定を継続し Stage A 側（作成方向）へフォールバックする実装であり、一時的な GitHub API 障害で正常フローを止めない方針と一貫させる。二重 PR リスクは稀な越境時のみで、かつ警告ログを残す。
- **OPEN / MERGED 検出時の Issue 通知（Requirement 2.4 / 3.4 に反映）**: ログのみとし Issue コメントは残さない。既存 TERMINAL_OK 経路（resolve 段階での既存 PR 検出）がログのみで停止するのと一貫させ過剰通知を避ける。grep 可能な判定根拠ログ（NFR 3）は残す。CLOSED は従来どおりコメント必須（Requirement 4.3）のまま維持する。

## Open Questions

- なし（当初の確認事項 3 点はオーケストレーターが確定済み。上記「Resolved Decisions」を参照）
