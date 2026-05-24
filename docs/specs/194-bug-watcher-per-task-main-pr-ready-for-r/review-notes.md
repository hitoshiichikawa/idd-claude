# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-194-impl-bug-watcher-per-task-main-pr-ready-for-r
- HEAD commit: 8a259514e9401e7aacf71239c92303ae9b74fa25
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh:9165-9171`（必須未完了 task 残存時に `return 0` resumable で抜け Stage B/C へ進ませない）/ スモーク `hold-resumable` ケース（partial・child-pending fixture）
- 1.2 — `issue-watcher.sh:9172-9177`（必須未完了 0 件時のみ `verify_pushed_or_retry` → `✅ Stage A 完了` へ進行）/ スモーク `ready-for-review`（all-done fixture）
- 1.3 — `pt_extract_pending_tasks`（`issue-watcher.sh:6437` の regex `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` が `\[ \]` 直後に空白を要求し deferrable `- [ ]*` を構造的に除外）/ スモーク deferrable-only fixture（count=0 / ready-for-review）
- 1.4 — ゲートを `run_per_task_loop` の全 `return 0` 経路の合流点（`issue-watcher.sh:9154` 以降）に配置し未完了残を再判定、quota 早期 return と同一の `return 0` resumable で後続 tick 再開対象とする
- 1.5 — `issue-watcher.sh:9168` の `pt_log "issue=#${NUMBER} 必須未完了 task=${_pt_remaining_count} 残存..."`（件数・Issue 番号を `$LOG` に記録）/ スモーク count ケース（count=2 / count=1）
- 2.1 / 2.5 — ゲートは `_pt_loop_enabled=true` 分岐内（`issue-watcher.sh:9148-9189`）にのみ存在し、通常 Developer 経路（else ブランチ `9189-`）に diff なし。全完了正常ケースは従来フローへ合流
- 2.2 — 新規 env var の追加なし（既存 `PER_TASK_LOOP_ENABLED` の値のみ参照）
- 2.3 — 新規ラベル付与なし。`ready-for-review` を含む既存ラベル遷移契約に変更なし
- 2.4 — exit code 意味を変更せず、quota 早期 return と同義の `return 0`（resumable）を流用
- NFR 1.1 — 保留理由（必須未完了 task 残存）と Issue 番号・件数・残 ID を `pt_log` + stdout `tee -a "$LOG"` で `$LOG` から判別可能に記録（`issue-watcher.sh:9168-9169`）
- NFR 2.1 — 既存 per-task resume 挙動（`pt_extract_pending_tasks` ベースの skip）を変更せず、判定読み取りのみ追加

## Findings

なし

## Summary

per-task ループの全 task 完了ゲートが `_pt_loop_enabled=true` 分岐内のみに追加され、必須未完了 task 残存時は resumable な `return 0` で `ready-for-review` 遷移を保留する。Req 1.1〜1.5 と後方互換 Req 2.1〜2.5 / NFR を実装と新規スモークテスト（`test-pt-completion-gate.sh`、実行結果 `SMOKE_RESULT: pass`）でカバー。impl 側 `pt_extract_pending_tasks` とテスト参照実装の regex が同一で deferrable を除外する点も確認。boundary 逸脱・missing test なし。

RESULT: approve
