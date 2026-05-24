# 実装ノート（Issue #194）

## 修正対象 defect

`PER_TASK_LOOP_ENABLED=true` の per-task ループにおいて、`run_per_task_loop()` の戻り値 0 が
「全 task 消化成功」と「quota 超過等による中間早期 return」の双方を含むため、呼び出し側
`run_impl_pipeline()` がこれを一律「Stage A 完了」とみなし、後続 task が `[ ]` のまま PR を
`ready-for-review` 化して merge してしまう（PR #189 で task 1 のみ完了・task 2-6 が未完のまま
merge され main の watcher が機能停止、復旧は #193）。

## 変更概要

すべて `local-watcher/bin/issue-watcher.sh`:

- `run_impl_pipeline()` の Stage A per-task 分岐（`_pt_loop_enabled=true` ブロック内）に
  **全 task 完了ゲート**を追加。`run_per_task_loop` が `return 0` した直後・`verify_pushed_or_retry`
  の前に、`tasks.md`（`$_pt_tasks_md`）を再読込して `pt_extract_pending_tasks` で必須未完了 task の
  numeric ID を抽出する。
  - 必須未完了 task が **1 件以上**残る場合: `pt_log`（`per-task:` prefix）と stdout `tee -a "$LOG"` で
    保留理由・Issue 番号・残件数・残 ID を運用ログに記録し、`return 0`（resumable）で抜ける。
    Stage B（Reviewer）/ Stage C（PR 作成 + `ready-for-review` 付与）へは進ませない。
    `mark_issue_failed` は呼ばない（失敗ではなく中断のため、quota 早期 return と同じ扱い）。
  - 必須未完了 task が **0 件**の場合: 従来どおり `verify_pushed_or_retry` →
    `✅ Stage A 完了（per-task loop）` → handle_partial_status → Stage B/C へ進む。

## 設計判断

- **ゲートの配置を呼び出し側（`run_impl_pipeline`）にした理由**: `run_per_task_loop` 内には
  quota 超過・Debugger quota・Reviewer quota など複数の `return 0` 早期離脱経路が存在する
  （行 7168-7169 / 7206-7207 / 7242-7243 ほか）。dispatcher 内の各 return 直前に判定を散らすと
  網羅漏れと保守性低下を招くため、すべての `return 0` 経路が合流する呼び出し側で tasks.md を
  「単一の真実」として再読込・再判定する方式を採用した。これにより quota 早期 return（未完了残
  → 保留 = resume）と全 task 完了（→ ready-for-review 進行）を確実に切り分けられる。
- **`pt_extract_pending_tasks` の再利用**: 既存ヘルパーは正規表現 `^- \[ \] [0-9]+...`（`\[ \]` の
  直後に空白を要求）により deferrable `- [ ]*` を構造的に除外する。これをそのまま再利用する
  ことで Req 1.3（deferrable を未完了扱いしない）を追加コードなしで満たせる。
- **後方互換性（Req 2 / NFR）**: ゲートは `_pt_loop_enabled=true` 分岐の内側にのみ配置。
  `PER_TASK_LOOP_ENABLED` 未設定 / `false` / `true` 厳密一致以外の通常 Developer 経路
  （else ブランチ）には一切手を入れていない。env var 名・exit code 意味・ラベル契約は不変。
- **ログ形式**: 既存の `pt_log` / `pt_warn`（`per-task:` prefix）を使用し、`$LOG` への
  追記形式を既存 per-task イベントログと整合させた（NFR 1.1）。

## Test plan

### 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh`: 追加コード（行 9148 付近）に **新規警告なし**。
  既存の SC2317（unreachable / 間接呼び出し helper）・SC2012（既存 `ls` 使用箇所）は本修正前から
  存在するもので、本修正の責任範囲外（追加分は警告ゼロ）。
- `shellcheck docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/test-pt-completion-gate.sh`: clean。

### スモークテスト

`docs/specs/194-bug-watcher-per-task-main-pr-ready-for-r/test-pt-completion-gate.sh` を新規作成
（既存 `docs/specs/166-.../test-pt-fallback.sh` の慣習に倣う）。`pt_extract_pending_tasks` と
完了ゲート判定の参照実装を impl 側と同一ロジックで持ち、4 fixture × 判定/件数で検証:

```
=== Issue #194 per-task ループ全 task 完了ゲート判定スモーク ===
[OK] Req1.2: 全 task 完了 → ready-for-review (gate=ready-for-review)
[OK] Req1.2: 全 task 完了時の必須未完了 count=0 (count=0)
[OK] Req1.1: 後続 task 未完了残存 → hold-resumable (gate=hold-resumable)
[OK] Req1.5: 後続 task 未完了残存時の件数記録 count=2 (count=2)
[OK] Req1.3: deferrable のみ残 → ready-for-review (gate=ready-for-review)
[OK] Req1.3: deferrable は必須未完了に数えない count=0 (count=0)
[OK] Req1.1: 子タスク未完了残 → hold-resumable (gate=hold-resumable)
[OK] Req1.1: 子タスク未完了の件数 count=1 (count=1)
---
SMOKE_RESULT: pass
```

- **Red 観測**: 誤った正規表現（`\[ \]\*?` で deferrable も拾う）を注入すると deferrable のみ
  fixture が誤って `hold-resumable` 判定になることを別途確認。本物の正規表現が `\[ \]` 直後に
  空白を要求して deferrable を構造的に除外していることを Red→Green で裏付けた。
- **PER_TASK_LOOP 無効経路の非干渉**: 変更は `_pt_loop_enabled=true` 分岐内のみで、else ブランチ
  （通常 Developer 経路）に diff はない（Req 2.1 / NFR 1.1）。

## 受入基準とテストの対応

| Req ID | 内容 | 担保 |
|---|---|---|
| 1.1 | 必須 task 未完了残存時は `ready-for-review` へ遷移させない | スモーク `hold-resumable` ケース（partial / 子タスク未完了）+ ゲート実装の `return 0` 早期離脱 |
| 1.2 | 全 task 完了時は既存 Stage A 後フローへ進む | スモーク `ready-for-review`（全完了）ケース + ゲート通過後の従来フロー |
| 1.3 | deferrable `- [ ]*` を未完了扱いしない | スモーク deferrable のみ fixture（count=0 / ready-for-review）+ Red 観測 |
| 1.4 | quota 超過等で必須 task を残し中断時は ready-for-review へ進めず後続 tick 再開対象 | ゲートを `run_per_task_loop` の全 `return 0` 経路の合流点に配置し未完了残を再判定（resumable return 0） |
| 1.5 / NFR 1.1 | 未完了残存の旨と件数・Issue 番号を運用ログに記録 | スモーク count ケース + 実装の `pt_log "issue=#${NUMBER} 必須未完了 task=${count} ..."` |
| 2.1 / 2.5 / NFR 1.1 | per-task 無効時 / 全完了正常時の後方互換 | ゲートを `_pt_loop_enabled=true` 分岐内のみに配置（else ブランチ無改変） |
| 2.2 / 2.3 / 2.4 | env var 名 / ラベル / exit code 意味の不変 | 新規 env var なし・ラベル契約不変・exit code（`return 0` = resumable / quota 待ちと同義）を流用 |
| NFR 2.1 | 冪等性（resume 時に完了済み task を再実行しない） | 既存 per-task resume 挙動（`pt_extract_pending_tasks` ベースの skip）を変更せず流用 |

## 確認事項（レビュワー判断ポイント）

- 本実装は requirements.md の中核（Req 1 + Req 2 後方互換）に限定した。requirements.md の
  `Out of Scope` および `Open Questions` に列挙された受入観点 #2（task 粒度の設計段階強制）/
  #3（Reviewer ゲート責務見直し）/ #4（マージ側ガード）は本 Issue では実装していない。これら
  3 点を Non-Goal 確定とするか別 Issue 起票とするかは人間判断を仰ぎたい（PM の Open Questions と同旨）。
- ゲートの保留時 `return 0`（resumable）は quota 早期 return と同一の戻り値・意味（後続 tick 再開）
  を流用しており、新たなラベル / exit code を導入していない。`needs-quota-wait` ラベルは
  quota 経路でのみ付与され、本ゲートでは付与しない（中断理由が quota とは異なるため）。後続 tick
  での再開は Resume Processor の既存 `impl-resume` 経路（`- [x]` skip）に委ねる設計で、追加ラベルは
  不要と判断したが、運用上「保留中」を可視化する専用ラベルが望ましいかはレビュー判断に委ねたい。

STATUS: complete
