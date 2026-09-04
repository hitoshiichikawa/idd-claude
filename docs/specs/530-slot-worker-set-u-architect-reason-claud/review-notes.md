# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.8 timestamp=2026-08-28T04:05:15Z -->

## Reviewed Scope

- Branch: claude/issue-530-impl-slot-worker-set-u-architect-reason-claud
- HEAD commit: ad14abe008c6d5f740c56ccde7e1b39d3b9e6328
- Compared to: main..HEAD
- 注記: `git diff main..HEAD` は **空**（HEAD == main）。Developer の変更は作業ツリー上に
  存在するが commit 未実施（`M local-watcher/bin/modules/slot-worker.sh` +
  untracked `local-watcher/test/slot_worker_set_u_guard_test.sh` /
  `local-watcher/test/slot_worker_reclaim_claim_test.sh` + spec dir）。prompt の
  「差分が空の場合は requirements.md と既存コードの突き合わせで判定する」指示に従い、
  ディスク上（作業ツリー）の実装・テストを AC カバレッジの判定対象とした。

## Verified Requirements

- 1.1 — `slot-worker.sh:374` `: "${ARCHITECT_REASON:=}"`（全経路初期化）+ 読み取りガード
  `:779` / `:871` `${ARCHITECT_REASON:-}` / `slot_worker_set_u_guard_test.sh`（構造検証 A + set -u 挙動検証 B）
- 1.2 — `slot-worker.sh:373` `: "${NEEDS_ARCHITECT:=false}"` + 読み取りガード `:776`
  `${NEEDS_ARCHITECT:-}` / 同テスト（負のコントロールで素の read クラッシュも捕捉）
- 1.3 — `slot-worker.sh:375` `: "${MODE:=}"` + 読み取りガード `:927` `${MODE:-}` / 同テスト
- 1.4 — `:=` 初期化ブロックをメタデータ抽出直後・EXIT trap 設置前（`_slot_run_issue` 冒頭付近）に
  配置し、design 再入 / resume / stage-checkpoint いずれの経路でも未割り当て参照を防ぐ
  defense-in-depth / 同テスト（B）挙動再現で set -u 下非クラッシュを確認
- 1.5 — opt-in gate なしの常時適用。fresh 経路の無条件初期化（`:577-579`）を温存し、
  同既定値へ上書きするため後方互換 no-op のバグ修正
- 2.1 — `_slot_reclaim_stale_claim` を EXIT trap（`:413`）に連結し、異常終了時に
  `claude-claimed` を除去して `auto-dev` を確保 / `slot_worker_reclaim_claim_test.sh` Case A
- 2.2 — ground-truth 判定（実ラベルに `claude-claimed` が残る場合のみ回収）で正常完了時は
  no-op / Case B
- 2.3 — EXIT trap は成功終端でも発火するが `claude-claimed` 不在で除去せず / Case B
- 2.4 — 除去対象を `claude-claimed` に限定し `claude-picked-up` / 無関係ラベルに触れない / Case C
- 2.5 — `_slot_mark_failed` 到達後は `claude-claimed` 不在のため追加操作せず `claude-failed` を
  打ち消さない / Case B・E（claimed 不在で no-op）
- 2.6 — Stale Pickup Reaper の領分（`claude-picked-up` の liveness 判定）に触れず役割分担で
  非干渉 / Case C
- 2.7 — 回収は trap 内で無条件実行し `STALE_PICKUP_REAPER_ENABLED` の有効・無効に依存しない /
  Case A（既定環境で回収）
- NFR 1 — env var 名 / ラベル名 / exit code / cron 文字列 / ログ出力先を変更せず。ガードは
  fresh 経路で no-op、既存の無条件初期化を温存。shellcheck clean（rc=0）
- NFR 2 — 回収実行時のみ `slot_log "claim 残留回収…（Issue #530）"` を 1 行出力（silent fail 無し）/ Case A
- NFR 3 — EXIT trap 連結により異常終了直後（次 watcher tick 以内）に再 pickup 可能へ復帰

## Findings

なし

## Summary

Requirement 1（set -u クラッシュ防止）/ Requirement 2（claim 残留回収）および NFR 1〜3 の全 AC が
観測可能な実装 + テストでカバーされている。新規テスト 2 本は全通過（set_u_guard 11/11、
reclaim_claim 20/20。負のコントロール・injection 防御・fail-open 含む）、shellcheck clean、
boundary は requirements.md 記載の対象（`slot-worker.sh` + テスト）内で逸脱なし。3 カテゴリ
（AC 未カバー / missing test / boundary 逸脱）いずれにも該当しない。
なお `git diff main..HEAD` は空で、変更は作業ツリー上に未 commit のまま存在する。これは
reject 3 カテゴリ外の process 事項のため判定には含めないが、後続 Stage で当該作業ツリー変更
（`slot-worker.sh` + 新規テスト 2 本 + spec）が確実に commit される必要がある旨を申し送る。

RESULT: approve
