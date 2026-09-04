# Requirements Document

## Introduction

consumer repo の Issue 処理で slot worker（`_slot_run_issue`）が起動直後にクラッシュし、
Issue が再処理不能な停止状態に陥る不具合への対処である。`set -euo pipefail`（`set -u`）下で
mode 判定に用いる変数（`ARCHITECT_REASON` / `NEEDS_ARCHITECT` / `MODE`）が未割り当てのまま
参照される経路が存在し、subshell が即死する。さらにクラッシュは失敗処理関数
`_slot_mark_failed`（`claude-claimed` を除去して `claude-failed` を付与する）に到達する前に
起こるため、`claude-claimed` ラベルが Issue に残留し、以後のサイクルで dispatcher が「処理中」
とみなして永久に pick しなくなる（手動でラベルを外すまで復旧しない）。本要件はこの 2 点
（クラッシュ防止 / claim 残留の回収）を規定する。

_対象: `local-watcher/bin/modules/slot-worker.sh`（`_slot_run_issue` / `_slot_mark_failed` /
EXIT trap）、`local-watcher/bin/modules/slot-worker-resume.sh`（resume 経路）。関連既存機能:
Stale Pickup Reaper（#379 / `local-watcher/bin/modules/stale-pickup-reaper.sh`）。_

## Requirements

### Requirement 1: set -u 下でのクラッシュ防止（mode 判定変数の未割り当て防御）

**Objective:** As a watcher 運用者, I want `_slot_run_issue` が mode 判定関連変数の未割り当てで
異常終了しないこと, so that Issue 処理が起動直後にクラッシュして再処理不能になる事態を防げる

_影響箇所（traceability ヒント / 行番号は将来ずれ得る）: 686/689 行（design モード判定と理由
出力での `NEEDS_ARCHITECT` / `ARCHITECT_REASON`）、781 行（design prompt 内の
`ARCHITECT_REASON`）、837 行（Development 実行ログの `MODE`）。_

#### Acceptance Criteria

1. If `ARCHITECT_REASON` が未割り当ての状態で参照される, the Slot Runner shall `set -u` 下でも異常終了せず空値相当として扱い処理を継続する
2. If `NEEDS_ARCHITECT` が未割り当ての状態で参照される, the Slot Runner shall `set -u` 下でも異常終了せず処理を継続する
3. If `MODE` が未割り当ての状態で参照される, the Slot Runner shall `set -u` 下でも異常終了せず処理を継続する
4. Where design 再入 / resume / stage-checkpoint により `_slot_run_issue` が mode 判定初期化ブロックを通過しない経路で実行される場合, the Slot Runner shall mode 判定関連変数が未割り当てでも異常終了せず、当該 Issue を正常系または失敗系のいずれかの終端へ進める
5. The Slot Runner shall 本クラッシュ防止を opt-in gate なしで常時適用する（既定挙動として後方互換な no-op のバグ修正）

### Requirement 2: 異常終了時の claim ラベル残留の回収

**Objective:** As a watcher 運用者, I want slot worker が `_slot_mark_failed` 到達前に異常終了しても
`claude-claimed` が Issue に恒久残留しないこと, so that 該当 Issue が後続サイクルで再 pickup
されなくなる停止状態を防げる

_影響箇所（traceability ヒント）: `_slot_run_issue` の EXIT trap（326 行 / 現状は `rs_emit` /
`tu_emit_issue_summary` のみでラベルに触れない）、`_slot_mark_failed`（147 行）、正常系の付け替え
（design→`awaiting-design-review` / impl→`claude-picked-up`）。実装手段（in-slot trap か watcher
側 sweep か）は Architect / Developer の裁量。_

#### Acceptance Criteria

1. If `_slot_run_issue` が `_slot_mark_failed` に到達する前に異常終了する（`set -u` クラッシュ・想定外の非ゼロ終了を含む）, the Slot Runner shall 当該 slot が処理中だった Issue の claim 系ラベル残留を回収し、後続の watcher サイクルで再 pickup 可能な状態へ戻す
2. When `_slot_run_issue` が Issue を正常完了する（impl / impl-resume → `claude-picked-up` 付け替え済み / design → `awaiting-design-review` 付け替え済み）, the Slot Runner shall 正常完了時のラベル状態を保持し、hand-over 済みラベルを除去しない
3. While `_slot_run_issue` の EXIT trap が成功終端でも発火する, when 終端が正常完了である, the claim 回収機構 shall claim ラベルの除去を行わない
4. When claim 回収が行われる, the claim 回収機構 shall 除去対象を claim 系ラベル（`claude-claimed` / `claude-picked-up`）に限定し、無関係なラベルを除去しない
5. If `_slot_mark_failed` が既に claim 系ラベルを除去して `claude-failed` を付与済みである, the claim 回収機構 shall 追加のラベル操作で `claude-failed` 状態を打ち消さない
6. Where Stale Pickup Reaper（`STALE_PICKUP_REAPER_ENABLED=true`）が有効である, the claim 回収機構 shall 同一 Issue のラベルを Stale Pickup Reaper と二重に競合操作せず、役割分担して非干渉に動作する
7. The claim 回収機構 shall `STALE_PICKUP_REAPER_ENABLED` の有効・無効に依存せず機能し、既定（未設定 / `false`）環境でも claim 残留を回収する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Slot Runner shall 既存の env var 名 / ラベル名（`claude-claimed` / `claude-picked-up` / `claude-failed` / `awaiting-design-review` 等）/ exit code 意味 / cron 登録文字列 / ログ出力先を変更しない
2. When design / impl / impl-resume の正常系（成功・失敗）遷移を処理する, the Slot Runner shall 本修正導入前と同一のラベル遷移・exit code・既存ログ行を維持する
3. The 修正 shall 既存の近接テスト（`local-watcher/test/**`）を pass させたまま維持する（新規テスト追加は可）

### NFR 2: 観測性

1. When claim 回収が発火する, the claim 回収機構 shall 回収の事実（Issue 番号・回収理由）をログに 1 行以上出力し、silent fail を作らない

### NFR 3: 回収の適時性

1. If `_slot_run_issue` が異常終了して claim が残留する, the claim 回収機構 shall 遅くとも次の watcher ポーリングサイクル（1 tick）以内に当該 Issue を再 pickup 可能な状態へ復帰させる

## Out of Scope

- **根本の初期化スキップ経路の厳密な特定・再現テスト**: resume / stage-checkpoint のどの分岐が
  無条件初期化ブロック（現状 487-489 行）をスキップして途中段階から実行されるかは、human も未特定で
  ある。本 Issue は defense-in-depth（未割り当てでも安全）を採用し、経路特定を AC の必須条件にしない。
  root-cause が別途特定された場合は follow-up で「初期化保証」を追加してよい。
- **main と同一コミットの空 design ブランチの自動掃除**: クラッシュ修正（Requirement 1）で新規発生は
  止まるが、既に push 済みの空 design ブランチを掃除する機構は別スコープ。
- **Stale Pickup Reaper のデフォルト有効化（`STALE_PICKUP_REAPER_ENABLED` の既定反転）**: opt-in gate の
  既定変更は別の運用ポリシー判断。本 Issue は reaper 無効環境でも claim が回収される baseline を要件化
  する（Requirement 2.7）ため、既定反転は不要。
- **README への「macOS では bash 4+ 必須」明記**: Issue 末尾の「あると親切」提案であり、クラッシュ修正 +
  claim 回収という本 Issue の主眼と別トピック。CLAUDE.md 技術スタック節には既に bash 4+ 記載がある。
  README 追記は follow-up Issue を推奨（Open Questions 参照）。
- **`run-summary.sh:247` の `wait_for: プロセス … の記録がありません` 警告**: subshell 即死に伴う下流
  症状であり、クラッシュ防止（Requirement 1）で自然に解消する。個別修正は行わない。

## Open Questions

- README「macOS では bash 4+ 必須」明記を本 Issue に含めず、別 Issue（`Related: #530`）として起票する
  方針で問題ないか。含める場合はスコープを拡張するため人間の判断を仰ぐ（既定では Out of Scope のまま
  据え置く）。
