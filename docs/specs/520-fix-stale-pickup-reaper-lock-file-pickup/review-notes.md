# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-29T03:02:08Z -->

## Reviewed Scope

- Branch: claude/issue-520-impl-fix-stale-pickup-reaper-lock-file-pickup
- HEAD commit: 178d25cf7e2eebe51191541b15c523a37f9ee551
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `sr_check_session`: 空 `pids` 時に旧 `return 1` を撤去し `continue`→`no-holder`→`return 0`（`stale-pickup-reaper.sh:516-521,537-540`）。テスト 10d（空 fuser 出力 → rc=0）
- 1.2 — 取得 pid が全て非生存時に kill -0 ループ通過後 `no-holder`→`return 0`（`stale-pickup-reaper.sh:524-540`。#520 前から保存された挙動）。テスト 10c（99999 不在 pid → rc=0 / pid_max 依存 skip は既存挙動）
- 1.3 — lock file 不在で `no-lockfile`→`return 0`（`stale-pickup-reaper.sh:472-483`）。テスト 10a（rc=0 + reason=no-lockfile）
- 2.1 — 生存 pid 検出で `holder-alive`→`return 1`（`stale-pickup-reaper.sh:529-532`）。テスト 10b（自プロセス pid → rc=1 + holder-alive）
- 2.2 — 複数 lock file を累積走査し他 slot 無保持でも生存保持者検出で `return 1`（`stale-pickup-reaper.sh:502-535`）。テスト 10f（slot-1 無保持 + slot-2 生存 → rc=1）
- 3.1 — fuser/lsof 双方不在時のみ `tool-absent`→`return 1`（`stale-pickup-reaper.sh:491-496`）。テスト 10g（PATH 空で決定論的に rc=1 + tool-absent）+ 10e（binary 実在時 skip）
- 3.2 — `no-holder`（手段あり保持者なし / rc=0）と `tool-absent`（手段不在 / rc=1）を別トークンで区別（`stale-pickup-reaper.sh:459-463`）。テスト 10d（no-holder → rc=0）+ 10g（tool-absent → rc=1）
- 4.1 — `age=$age lock=$lock sess=$sess` フィールド形式を維持し末尾に別フィールド追記（`stale-pickup-reaper.sh:580,583`）。テスト Section 11（`age=N lock=N sess=N` 形式維持）
- 4.2 — holder-alive を `sess_reason` としてログ追記。テスト 10b + 10h（`sess_reason=holder-alive`）
- 4.3 — no-holder を `sess_reason` としてログ追記。テスト 10d + 10h（`sess_reason=no-holder`）
- 4.4 — tool-absent を `sess_reason` としてログ追記。テスト 10g + 10h（`sess_reason=tool-absent`）
- 5.1 — 3 観点 AND 判定（`sr_is_active`）は不変で全 0 時 inactive 確定（`stale-pickup-reaper.sh:579-584`）。テスト Section 11（全 0 → inactive）+ `sr_recovery_action_test` Section 13
- 5.2 — 無保持 lock file を no-holder(sess=0) 化し回収固定を解消。テスト 10d/10f
- 6.1 — 無保持残存 lock file fixture → sess=0。テスト 10d
- 6.2 — 実プロセス保持中 fixture → sess=1。テスト 10b
- 6.3 — Section 10d の期待値を rc=1→rc=0 へ反転し #520 意図をコメント明示（`sr_activity_check_test.sh:292-303`。旧期待値もコメント保存）
- NFR 3.1〜3.3 — env var / label / prefix(`stale-pickup:`) / `age`/`lock`/`sess` フィールド名を不変（diff で確認）。`sess=N` を機械パースする外部コードは bin/ 内に存在せず（grep 確認）末尾追記が非破壊
- NFR 4.1 — `bash -n` エラーなし / `shellcheck` 警告ゼロ（reviewer 再実行で確認）
- NFR 4.2 — README「アクティブセッション判定」節を safe-side 限定の語義へ更新（`README.md:4971-4985`）

## Findings

なし

## Summary

`sr_check_session` の safe-side fallback を「観測手段（fuser/lsof）不在時のみ」に限定し、
「手段はあるが保持者なし」を no-holder(sess=0) と判定する修正。requirements.md の全 numeric AC
（Req 1〜6 / NFR 1〜4）に対応する実装とテストを確認。reviewer 再実行で `sr_activity_check_test`
PASS=40/FAIL=0、関連 3 テストも全 PASS、`shellcheck`/`bash -n` クリーン。design-less bug fix で
tasks.md 不在のため `_Boundary:_` 制約は無く、変更は対象 module + 対応テスト + README doc 同期に
限定され boundary 逸脱なし。

RESULT: approve
