# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-28T17:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-257-impl-fix-local-watcher-phase-e-path-overlap-a
- HEAD commit: 9481f5386c82114733e06957f6d272b88e0be450
- Compared to: main..HEAD

差分対象ファイル（`git diff --stat main..HEAD`）:

- `local-watcher/bin/modules/promote-pipeline.sh` (+14/-6)
- `docs/specs/257-.../requirements.md` (new)
- `docs/specs/257-.../impl-notes.md` (new)
- `docs/specs/257-.../test-fixtures/test-awaiting-slot-update.sh` (new, 358 lines, 31 ケース全 PASS)

design-less impl ルート（`tasks.md` / `design.md` 不在）のため stage-a-verify gate は対象外。
CLAUDE.md には `## Feature Flag Protocol` 節が無く、Feature Flag Protocol は opt-out
として解釈。flag 観点の追加細目チェックは行わない。

## Verified Requirements

- 1.1 — `po_check_dispatch_gate` の `if [ -z "$has_awaiting" ]` ガードを除去
  （`local-watcher/bin/modules/promote-pipeline.sh:863-875`）し、ラベル付与状態に
  関わらず `po_apply_awaiting_slot` を呼ぶ。テスト
  "Req1.1 awaiting-slot 既付与でも po_apply_awaiting_slot が 1 回呼ばれる（バグ修正の本丸）" PASS
- 1.2 — `po_apply_awaiting_slot` 呼び出しに最新の `$overlap` / `$overlap_holders_map` を渡し、
  関数内部の `gh api -X PATCH /repos/${REPO}/issues/comments/${existing_comment_id}` 経路で
  上書き更新（`promote-pipeline.sh:595-597`）。テスト
  "Req1.2 apply 呼び出しに最新の overlap=[local-watcher/] と holders={local-watcher/:[42]} が渡される" PASS
- 1.3 — `po_apply_awaiting_slot` は既存 marker (`<!-- idd-claude:awaiting-slot:v1 -->`) 付き
  コメント検索 → ヒット時 PATCH / 無ければ create の分岐を保持
  （`promote-pipeline.sh:577-600`）。テスト
  "Req1.3 既存 marker 付き comment あり → gh api -X PATCH が 1 回呼ばれる" PASS /
  "Req1.3 / NFR3.1 ...gh issue comment（新規 create）は呼ばれない" PASS
- 1.4 — `po_log "overlap detected candidate=#${candidate} paths=... holders=..."`
  （`promote-pipeline.sh:857-861`）と apply 失敗時 `po_warn "issue=#${candidate}
  awaiting-slot 付与 / コメント更新に失敗..."`（L874）の 1 行ログで後続サイクル評価可能
- 2.1 — 未付与時の新規付与経路は `po_apply_awaiting_slot` 内の `gh issue comment` 分岐
  （`promote-pipeline.sh:599`）が引き続き走る。テスト
  "Req2.1 既存 marker なし → gh issue comment（新規 create）が 1 回呼ばれる" PASS
- 2.2 — `gh issue edit --add-label` の冪等性に依拠（多重付与にならない）。テスト
  "Req2.2 / NFR3.1 連続呼び出しでも add-label は決定論的に毎回呼ばれる（gh 側冪等）" PASS
- 2.3 — overlap 検出時 `return 1`（dispatch skip）は L876 で従来通り維持。テスト
  "Req2.3 overlap 検出時 dispatch skip（return 1）が維持される（既付与/未付与の両ケース）" PASS
- 2.4 — overlap 空 + `has_awaiting` 非空での `po_clear_awaiting_slot` 経路は L880-885 で
  完全に温存。テスト "Req2.4 overlap 空 + awaiting-slot 既付与 → po_clear_awaiting_slot
  が呼ばれる" / "Req2.4 overlap 空 + clear 成功 → dispatch 続行（return 0）" /
  "Req2.4 overlap 空 + 未付与 → clear は呼ばれない" 全 PASS
- 2.5 — `PATH_OVERLAP_CHECK != "true"` の早期 return 0 は L806 で完全に温存。テスト
  "Req2.5 PATH_OVERLAP_CHECK='off/空/false/0/True/1/enabled' で gate 早期 return 0" 7 PASS +
  "NFR1.1 apply / clear いずれも呼ばれない（差分ゼロ）" 7 PASS
- 3.1 — `if ! po_apply_awaiting_slot ...; then po_warn ...; fi`（L873-875）で失敗時に
  warn を出した上で後続の `return 1` まで実行継続。テスト "Req3.1 apply 失敗時も
  po_apply_awaiting_slot は呼ばれる（試行はする）" PASS
- 3.2 — `if ! ...; then ... fi` でキャッチされ `set -e` 下でも process 異常終了しない。
  テスト "Req3.2 apply 失敗でも process は異常終了せず後続評価が継続できる" PASS
- 3.3 — apply 失敗時も `return 1`（L876）と awaiting-slot ラベル状態（既付与なら保持）
  を維持。テスト "Req3.1 / 3.3 apply 失敗でも dispatch skip 判定（return 1）が維持される" PASS
- NFR 1.1 — 上記 2.5 の 14 ケースで `PATH_OVERLAP_CHECK != "true"` 系全パターンで
  apply/clear/gh のいずれも呼ばれず差分ゼロを実測
- NFR 2.1 — `po_warn "issue=#${candidate} awaiting-slot 付与 / コメント更新に失敗..."` の
  1 行ログで candidate 番号と更新可否を識別可能
- NFR 3.1 — `po_apply_awaiting_slot` 内の「既存 marker 1 件検索 → PATCH / 無ければ create」
  ロジックにより comment は Issue あたり 1 件、ラベルは `gh issue edit --add-label` の冪等性
  により 1 件付与状態を維持。連続呼び出しテストで確認

### Boundary 確認

- 修正対象は Dispatch Gate 経路 `po_check_dispatch_gate` のみ（requirements.md Out of Scope
  通り、flock skip 経路 `po__visibility_evaluate_candidate` には触れていない）
- `po_apply_awaiting_slot` 本体は変更なし（既存 PATCH/create 分岐が要件を既に満たしていた）
- ラベル名 / marker 文字列の変更なし
- `PATH_OVERLAP_CHECK` opt-in gate の設計変更なし
- 既存 env var 名 / cron 登録文字列 / exit code 意味への影響なし

### 静的解析・テスト実行確認（reviewer 自身で再実行）

- `shellcheck local-watcher/bin/modules/promote-pipeline.sh` → EXIT 0
- `shellcheck docs/specs/257-.../test-fixtures/test-awaiting-slot-update.sh` → EXIT 0
- `bash docs/specs/257-.../test-fixtures/test-awaiting-slot-update.sh` → PASS=31 FAIL=0 EXIT 0

## Findings

なし

## Summary

`po_check_dispatch_gate` の `if [ -z "$has_awaiting" ]` ガード除去という最小差分で、
requirements.md の全 AC（Req 1.1〜1.4 / 2.1〜2.5 / 3.1〜3.3 / NFR 1.1 / 2.1 / 3.1）を
満たす実装と 31 ケースの回帰テストが揃っている。Out of Scope（flock skip 経路 / marker 名 /
opt-in gate 設計）も尊重されており、boundary 逸脱も missing test も AC 未カバーも検出されない。

RESULT: approve
