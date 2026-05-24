# Requirements Document

## Introduction

per-task ループモード（`PER_TASK_LOOP_ENABLED=true`）では、#194/#195 で「tasks.md の必須 task が
全て完了するまで PR を `ready-for-review` へ遷移させない」全 task 完了ゲートが追加された。このゲートは
必須 task が未完了のまま per-task ループが終了したとき、`ready-for-review` 遷移を保留して resumable な
正常終了（`return 0`）で抜ける。しかし保留時に当該 Issue から `claude-picked-up` ラベルを除去しないため、
`claude-picked-up` を除外条件に持つ dispatcher の候補クエリから当該 Issue が常に外れ、後続 tick で
impl-resume が再開されず Issue が stuck になる（実例: #180 Part 2 で 6 件の必須 task 未完了のまま約 2 時間
無進捗、復旧には手動でのラベル除去が必要だった）。

本要件は「保留された Issue が後続 tick で自動的に再び impl-resume の処理対象になり、全必須 task を消化
するまで進む」ことを user/operator observable な振る舞いとして定義する。再 pickup を実現する内部機構
（ラベル除去 / 専用 resume ラベル + Processor / 候補クエリ条件付き包含のいずれか）の選択は design に委ね、
本要件は実装非依存に書く。冪等性（完了済み task の再実行禁止）・premature merge 防止（#195 ゲート自体）の
維持・quota 中断パスとの非干渉・後方互換性を併せて要求する。

## Requirements

### Requirement 1: 保留された Issue の自動再開

**Objective:** As a 運用者, I want per-task ループが必須 task 未完了で `ready-for-review` 保留した Issue が後続 tick で自動的に再び impl-resume の処理対象になること, so that 1 サイクル 1 task ごとの手動ナッジなしに全必須 task が自動消化される

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED=true` で必須 task 未完了のため `ready-for-review` 遷移が保留された Issue, when 後続の cron tick が実行されたとき, the Watcher shall 当該 Issue を impl-resume の処理対象（dispatcher 候補）として再び選択可能な状態にする
2. While 保留された Issue が後続 tick で再選択された状態, when impl-resume が起動したとき, the Watcher shall 残存する必須 task の消化を継続する
3. While 保留と再開を繰り返す過程, when 全ての必須 task が完了（`[x]`）した状態でループが終了したとき, the Watcher shall 既存の Stage A 完了後フロー（Reviewer 起動・PR 作成・`ready-for-review` 付与）へ進む
4. When 必須 task 未完了で `ready-for-review` 遷移を保留したとき, the Watcher shall 当該 Issue を運用者が追加の手動操作なしに後続 tick で再開できる状態へ遷移させる
5. The Watcher shall deferrable テストタスク（`- [ ]*` 表記）を未完了 task として扱わず、必須 task のみの充足で全 task 完了とみなす

### Requirement 2: 再開時の冪等性と premature merge 防止の維持

**Objective:** As a 運用者, I want 再開した impl-resume が完了済み task を再実行せず、かつ必須 task 未完了の中間状態で PR を ready-for-review 化しないこと, so that 既存の成果を破壊せず main がビルド/実行不能な中間状態で merge される事故も引き続き防げる

#### Acceptance Criteria

1. While 保留された Issue が後続 tick で再開した状態, when impl-resume が残 task を処理するとき, the Watcher shall 既に完了済み（`- [x]`）の task を再実行せず未完了 task のみを消化する
2. While 保留された Issue が後続 tick で再開した状態, when 再開後も必須 task に未完了が 1 件以上残ってループが終了したとき, the Watcher shall 当該 Issue の PR を `ready-for-review` ラベルへ遷移させず再び保留する
3. If 再開した処理が quota 超過等により必須 task を残したまま再び中断したとき, the Watcher shall 当該回を `ready-for-review` へ進めず後続 tick での再開対象として維持する
4. The Watcher shall 本修正の前後で #195 が定める「必須 task 全完了まで `ready-for-review` 遷移を保留する」ゲート判定の結果を変更しない

### Requirement 3: quota 中断パスとの非干渉

**Objective:** As a 運用者, I want ゲート保留による再開機構が quota 中断パス（`needs-quota-wait` + Quota Resume Processor）と干渉しないこと, so that quota 待ちと task 未完了保留が二重処理・競合を起こさず、それぞれの再開タイミングが正しく保たれる

#### Acceptance Criteria

1. While Issue が quota 超過により `needs-quota-wait` 状態で待機中, the Watcher shall ゲート保留の再開機構によって当該 Issue を quota reset 経過前に impl-resume 対象として再選択しない
2. When ゲート保留による再開と quota 中断による再開の両判定が同一 Issue に同一 tick で適用され得る状況が生じたとき, the Watcher shall 当該 Issue を同一 tick 内で二重に処理対象としない
3. The Watcher shall ゲート保留の再開機構導入後も、quota 中断パスにおける `needs-quota-wait` 付与・reset 経過後の自動除去・再 pickup の既存挙動を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `PER_TASK_LOOP_ENABLED` が未設定または `false`（既定）, the Watcher shall 本修正導入前と同一の通常 Developer 経路（Stage A → Reviewer → PR 作成 + `ready-for-review`）を実行する
2. The Watcher shall 本修正の前後で既存環境変数名（`PER_TASK_LOOP_ENABLED`, `PER_TASK_MAX_TASKS`, `QUOTA_AWARE_ENABLED`, `REPO`, `REPO_DIR`, `LOG_DIR` ほか）の名称と意味を変更しない
3. The Watcher shall 本修正の前後で既存ラベル（`claude-picked-up`, `ready-for-review`, `needs-quota-wait`, `claude-failed` ほか）の名称を変更しない
4. The Watcher shall 本修正の前後で既存 exit code の意味（成功 / 失敗 / quota 待ち等）を変更しない
5. While `PER_TASK_LOOP_ENABLED=true` かつ必須 task が全て完了している正常ケース, the Watcher shall 本修正導入前と同一の `ready-for-review` 付与挙動を保つ

### NFR 2: 可観測性

1. When 必須 task 未完了で `ready-for-review` 遷移を保留し再開可能状態へ遷移させたとき, the Watcher shall 保留理由（未完了 task 残存）・当該 Issue 番号・未完了 task 件数を運用ログ（`$LOG`）から grep 可能な形で記録する
2. When 後続 tick で保留された Issue が再開対象として再選択されたとき, the Watcher shall 再開が発生した事実と当該 Issue 番号を運用ログから判別可能な形で記録する

### NFR 3: 進捗保証

1. While `PER_TASK_LOOP_ENABLED=true` かつ quota 超過や Implementer 失敗等の中断要因が発生しない状態, when 必須 task 未完了で保留された Issue が後続 tick で再開され続けるとき, the Watcher shall 1 tick あたり最低 1 件の必須 task を消化し、全必須 task 完了まで運用者の手動介入なしに進行させる

## Out of Scope

- 再 pickup を実現する内部機構の選択（保留時のラベル除去 / 専用 resume ラベル + Processor / 候補クエリ条件付き包含の 3 案）。user/operator observable な「自動再開」の振る舞いのみを要件化し、機構選定・誤再開ガードの設計は `design.md`（Architect の領分）に委ねる（Open Questions の推奨を参照）。
- #195 ゲート自体の判定ロジック（必須 task 全完了判定・deferrable 判定境界）の変更。本 Issue は保留後の再開不能を修正するもので、ゲートの判定そのものは #194/#195 の既存規約に従う。
- per-task ループ無効時（既定）の通常フローへの新規機能追加。
- マージ側ガード（CI / ラベルによる incomplete task 残存時の merge 防止）の追加（#194 で Out of Scope 済み）。
- tasks.md の必須 task / deferrable task 表記規約自体の変更（`tasks-generation.md` の既存規約に従う）。
- PR #189 / #180 Part 2 で生じた個別 Issue の手動復旧（運用対応で実施済み）。

## Open Questions

- **推奨する修正方針**: PM としては Issue 提示の **案 1（保留時に `claude-picked-up` を除去し bare auto-dev candidate に戻す / 最小変更）** を推奨する。理由は (a) 既存の dispatcher 候補クエリ・impl-resume 経路をそのまま再利用でき後方互換性リスクが最小、(b) quota パスの `qa_handle_quota_exceeded`（ラベル除去 → 再 pickup 可能化）と同型の発想で実装者の認知負荷が低い、(c) 新ラベル・新 Processor の追加（案 2）に比べ技術債が小さい。ただし案 1 には「同一サイクル内での即時再 claim を抑止すべきか（次 tick まで待つべきか）」「`claude-picked-up` 除去により Issue が一時的に bare auto-dev 状態となることの人間可視性」「quota パスとの二重処理回避（Req 3.2）」という設計上の論点が残る。最終的な機構選定とこれらガードの設計判断は Architect に委ねたい。
- **誤再開ガードの厳密度**: 案 3（候補クエリへの条件付き包含）を採る場合、「`claude-picked-up` かつ `ready-for-review`/`claude-failed` 無し かつ impl ブランチ未完了」という再開対象判定の境界をどこまで厳密に定義するか（誤再開で進行中の処理を破壊しないためのガード）は design で確定する必要がある。要件レベルでは Req 3.2（同一 tick 二重処理の禁止）と Req 2.1（完了済み task 再実行禁止）でガードの目的のみを定義する。
- **「同一 tick での再開」可否**: Req 1.1 は「後続 tick で再選択可能」とし、保留が発生した同一 tick 内での即時再開は要件化していない（既存 quota パスも reset 経過まで待つ設計に倣う）。同一 tick 内即時再開を許容すべきかは運用判断であり、現時点では Open Question として人間判断を仰ぐ。
- 現状 Issue コメントには triage（edit_paths）と pickup 通知のみで、人間の決定コメントは無いことを確認済み。上記推奨方針の確定は人間/Architect の判断に委ねる。

## 関連

- Depends on: #194 #195
- Related: #180
