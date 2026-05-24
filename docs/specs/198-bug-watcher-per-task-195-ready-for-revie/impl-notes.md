# 実装ノート（Issue #198）

## 概要

per-task ループモード（`PER_TASK_LOOP_ENABLED=true`）の全 task 完了ゲート（#194/#195 で追加）が、
必須 task 未完了で `ready-for-review` 遷移を保留する際に `claude-picked-up`（`$LABEL_PICKED`）
ラベルを残したまま `return 0` していたため、dispatcher の候補クエリ
（`-label:"$LABEL_PICKED"` を除外条件に持つ）から当該 Issue が常に外れ、後続 tick で
impl-resume が再開されず stuck になっていたバグを修正した。

採用した修正方針は requirements.md Open Questions で PM が推奨した **案 1（最小変更）**:
ゲートが保留する際、`return 0` の直前に当該 Issue から `claude-picked-up`（および念のため
`claude-claimed`）を除去して bare auto-dev candidate に戻す。これにより次 tick の dispatcher が
当該 Issue を再選択 → mode 判定が既存 spec/branch を検出して impl-resume を起動 → 残 task を
消化する。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh` — `run_impl_pipeline()` 内 per-task 全 task 完了ゲートの
  保留分岐（`_pt_loop_enabled=true` 内）に、`return 0` 直前の `gh issue edit --remove-label`
  によるラベル除去を追加。
- `docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-relabel.sh` — 保留時の
  ラベル除去挙動を `gh` スタブで検証するスモークスクリプト（新規）。
- `README.md` — per-task 全 task 完了ゲートの説明に「保留 Issue の再 pickup 可能化 (#198)」の
  小節を追加し、ラベル除去機構・quota 非干渉・手動復旧手順を明記。

## 設計判断

- **ラベル除去対象**: quota 中断ハンドラ `qa_handle_quota_exceeded()` が
  `claude-claimed` / `claude-picked-up` の両方を除去している慣習に整合させ、本保留でも両方を
  除去対象にした。per-task 着手時点で `claude-claimed` は既に除去済みのはずだが、状態に依らず
  確実に bare candidate へ戻すため念のため両方を `--remove-label` に含める（GitHub API は
  存在しないラベルの remove を no-op として扱うため副作用なし）。
- **quota 非干渉（Req 3）**: 本保留は `needs-quota-wait` を一切付与しない。quota 中断は
  `qa_handle_quota_exceeded` → `process_quota_resume` という別経路（`needs-quota-wait` のみ走査）
  であり、本保留はラベル除去のみで `needs-quota-wait` を触らないため、quota processor の走査対象に
  乗らず二重処理は構造的に起きない。この点を実装コメントに明記した。
- **副作用失敗の扱い（Req 1.4）**: `gh issue edit` の失敗は warn 吸収して `return 0` を維持する
  （quota ハンドラと同じく副作用失敗で全体を落とさない方針）。`pt_warn` は stderr 出力のため、
  `$LOG` への grep 可能な記録は別途 `pt_log ... | tee -a "$LOG"` で残す（NFR 2.1）。失敗時は
  ラベルが残置され次 tick でも候補に上がらないが、ログに残るため人間が手動復旧できる。
- **冪等性（Req 2.1）**: 完了済み `- [x]` task の再実行防止は既存 impl-resume の skip 機構
  （`pt_extract_pending_tasks` / `IMPL_RESUME_PROGRESS_TRACKING`）に委ねる。本修正では追加コードを
  入れていない（既存挙動を変更しない）。
- **ゲート判定ロジックは不変（Req 2.2/2.4）**: `pt_extract_pending_tasks` による必須未完了判定・
  deferrable 除外・`return 0` で Stage B/C へ進ませない挙動はすべて維持。変更は「保留時に
  ラベルを除去する」一点のみ。
- **同一 tick 即時再開について**: dispatcher は tick 冒頭に候補スナップショットを取得するため、
  tick 途中のラベル除去は当該 tick のキューに影響しない（同一 tick 内即時再 claim は構造的に
  起きず、再開は後続 tick から）。Req 1.1 は「後続 tick で再選択可能」を要件化しており同一 tick
  即時再開は要件外。この点をコメントに補足した。

## Test plan

### 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh` — 追加コード周辺（約 9192-9226 行）に新規警告
  なし。main ベースラインと警告件数同一（39 件、いずれも本修正前から存在する既存 SC2317 等で
  責任範囲外）。
- `shellcheck docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-relabel.sh` —
  clean。

### スモークテスト

`docs/specs/198-bug-watcher-per-task-195-ready-for-revie/test-pt-hold-relabel.sh`（`gh` を関数
スタブ化し、保留分岐で発行される `gh issue edit` の引数列を記録して assert する方式）:

- Case 1: 必須未完了残存 → `hold-resumable` かつ `--remove-label claude-picked-up` /
  `--remove-label claude-claimed` が呼ばれ、`needs-quota-wait` は付与されない
- Case 2: 全 task 完了 → `ready-for-review` かつ `gh issue edit` が一切呼ばれない
- Case 3: deferrable（`- [ ]*`）のみ残 → `ready-for-review` かつラベル除去を呼ばない
- Case 4: `gh edit` が exit 1（副作用失敗）でも `hold-resumable` を維持

→ `SMOKE_RESULT: pass`

### 回帰確認

- `docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/test-pt-completion-gate.sh` を実行し
  `SMOKE_RESULT: pass`（#194 のゲート判定ロジックに回帰なし）。

## 受入基準とテストの対応

| Req | 内容 | 担保 |
|---|---|---|
| 1.1 | 保留 Issue を後続 tick で再選択可能な状態にする | 実装（`--remove-label claude-picked-up`）+ test Case 1（remove-label 呼び出し検証） |
| 1.2 | 再選択後 impl-resume が残 task を継続 | 既存 dispatcher/impl-resume 機構に委譲（bare candidate 化で再選択 → mode 判定）。設計判断に記載 |
| 1.3 | 全 task 完了時は既存 Stage A 完了後フローへ進む | test Case 2（全 task 完了 → ready-for-review、ラベル除去なし） |
| 1.4 | 追加の手動操作なしに後続 tick で再開できる状態へ遷移 | 実装（ラベル除去で bare candidate 化）+ test Case 1 / Case 4（副作用失敗時も hold 維持） |
| 1.5 | deferrable を未完了扱いしない | test Case 3 + #194 スモーク（ゲート判定不変） |
| 2.1 | 完了済み task の再実行禁止 | 既存 impl-resume の `- [x]` skip に委譲（本修正でゲート判定不変）。設計判断に記載 |
| 2.2 | 再開後も未完了残ならば再び保留 | ゲート判定不変（保留点を毎 tick 再評価）。#194 スモークの hold-resumable ケースで担保 |
| 2.3 | quota 等で再中断時も ready-for-review へ進めず維持 | ゲート判定不変 + quota 中断は別経路で `needs-quota-wait` を付与（本保留と独立） |
| 2.4 | #195 ゲート判定結果を変更しない | 変更は「保留時のラベル除去」一点のみ。#194 スモーク全 pass で担保 |
| 3.1 | quota 待機中の Issue を reset 前に再選択しない | 本保留は `needs-quota-wait` を付与しない / 触らない。quota Issue の再開は `process_quota_resume` 単独経路のまま |
| 3.2 | 同一 tick で二重処理対象としない | 本保留はラベル除去のみで `needs-quota-wait` を触らず、quota processor の走査対象（needs-quota-wait のみ）に乗らない → test Case 1（needs-quota-wait 不付与） |
| 3.3 | quota 中断パスの既存挙動を変更しない | `qa_handle_quota_exceeded` / `process_quota_resume` に変更なし。本保留は別分岐 |
| NFR 1.1 | PER_TASK_LOOP 無効時は導入前と同一経路 | 変更は `_pt_loop_enabled=true` 分岐内のみ。else ブランチ不変 |
| NFR 1.2 | 既存 env var 名・意味不変 | 変更箇所に env var の追加・改名なし |
| NFR 1.3 | 既存ラベル名不変 | `$LABEL_PICKED` / `$LABEL_CLAIMED` を参照するのみ。ラベル名の新設・改名なし |
| NFR 1.4 | 既存 exit code 意味不変 | `return 0`（resumable）を維持。exit code 変更なし |
| NFR 1.5 | 全 task 完了の正常ケースは導入前と同一の ready-for-review 付与 | test Case 2（全 task 完了時に保留分岐へ入らず gh edit を呼ばない） |
| NFR 2.1 | 保留理由・Issue 番号・未完了件数を grep 可能形式で記録 | 既存 `pt_log`/`echo ... tee` ログ（Issue 番号・件数含む）に「claude-picked-up を除去」行を追記 |
| NFR 2.2 | 再開発生の事実と Issue 番号を判別可能に記録 | 既存 dispatcher の pickup ログ（Issue 番号付き）で判別可能（impl-resume mode 判定ログ）。本修正で追加のラベル除去ログも残す |
| NFR 3.1 | 中断要因なしなら 1 tick 1 task 以上消化し全完了まで進行 | ラベル除去 → 再 pickup → impl-resume → 1 task 消化 → commit → 次 tick の循環で担保（既存 per-task ループ + 本修正のラベル除去の合成）。スモークは「再 pickup 可能化」のラベル除去を担保 |

## 確認事項（レビュワー判断ポイント）

- **NFR 3.1 / Req 1.2 のエンドツーエンド担保**: 「再 pickup → impl-resume 起動 → 1 task 消化」の
  full loop は dispatcher + mode 判定 + impl-resume の既存機構の合成であり、本スモークでは外部
  `gh` 呼び出しを伴うため「保留分岐でラベル除去が呼ばれる」点までを単体検証している。実際の
  full loop は本 repo への dogfooding E2E（auto-dev Issue を立てて watcher が複数 tick で全 task を
  消化するか）でのみ最終確認可能。本 PR スコープではスモーク + 既存機構への委譲で担保している。
- **`claude-claimed` の除去要否**: per-task 着手時点で `claude-claimed` は既に除去済みのはずだが、
  quota ハンドラとの整合のため念のため両方を remove 対象にした。状態に依らず安全（GitHub API は
  存在しないラベルの remove を no-op 扱い）と判断したが、`claude-picked-up` のみで十分という
  方針があれば縮約可能。

STATUS: complete
