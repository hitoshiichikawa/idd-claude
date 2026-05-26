# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-246-impl-bug-watcher-stage-a-verify-round-counter
- HEAD commit: ae79d9535c0af7fd42c68577abacce79cac69c07
- Compared to: main..HEAD

差分は 5 ファイル（README.md / impl-notes.md / requirements.md / 新規テスト fixture /
`local-watcher/bin/modules/stage-a-verify.sh`）。本 Issue は design-less impl（tasks.md 不在）
のため `_Boundary:_` アノテーションは存在せず、boundary 判定は requirements.md の Out of Scope
と変更ファイルの範囲整合で行った。CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため
opt-out 扱いとし、flag 観点の確認は行わない（通常の 3 カテゴリ判定）。

## Verified Requirements

- 1.1 — `_sav_handle_failure` の round>=2 → mark_issue_failed(return 2) 経路（stage-a-verify.sh:697-710 不変）。round=2 到達は test-round-counter-persistence.sh ケース2「worktree reset 後 bump → round=2」で回帰担保
- 1.2 — テスト「初回 bump → round=1」（ケース1）。`stage_a_verify_bump_round`（stage-a-verify.sh:626）が不在から 1 を書く
- 1.3 — `_sav_handle_failure` の `*)` ケース（round>=2）で mark_issue_failed + return 2、既存契約不変
- 1.4 — テスト「worktree reset 後 read=1 → bump=2（単調増加）」（ケース2）
- 2.1 — `stage_a_verify_round_path`（stage-a-verify.sh:587-594）が `_sav_state_dir`（worktree 外 `$HOME/.issue-watcher/state/<repo_slug>` 既定）配下を返す。テストで STATE_DIR 配下 / WORKTREE 配下でないこと / デフォルト `$HOME/.issue-watcher/` 配下を検証（ケース0・3b）
- 2.2 — テスト「worktree reset（WORKTREE rm -rf）後 read=1」（ケース2）
- 2.3 — `stage_a_verify_bump_round` の書き込み失敗 return 1（stage-a-verify.sh:633-636）。`_sav_handle_failure` は bump 失敗時も read=0 のままで差し戻し挙動へ倒れる。テスト「書き込み不能時 bump→return 1 / read→0」（ケース5）
- 3.1 — `_sav_round_key`（stage-a-verify.sh:573-580）が NUMBER + サニタイズ branch でキー生成。テスト「異なる NUMBER / 異なる BRANCH で round_path 相違」（ケース3）
- 3.2 — NUMBER/BRANCH によるファイル名一意化で path 分離（ケース3）。並行 Issue は独立ファイルを読み書き
- 3.3 — `_sav_state_dir` の REPO_SLUG 分離。テスト「異なる REPO_SLUG で round_path 相違」（ケース3b）
- 4.1 — `stage_a_verify_run` SUCCESS 経路の `stage_a_verify_reset_round`（stage-a-verify.sh:787 不変）。テスト「reset 後 read=0」（ケース4）
- 4.2 — `_sav_handle_failure` escalate 経路の `stage_a_verify_reset_round`（stage-a-verify.sh:699 不変）
- 4.3 — テスト「不在に対する 2 回目 reset でもエラーなし / read=0」（ケース4）。`rm -f` ベースで冪等
- NFR 1.1 — SUCCESS 通常ケースは counter を判定に使わず reset を呼ぶのみ。外形挙動不変
- NFR 1.2 — `STAGE_A_VERIFY_ENABLED=false` の DISABLED 経路は counter に触れず不変（stage-a-verify.sh:739-742）
- NFR 1.3 — 既存 env var 名変更なし（新規 `STAGE_A_VERIFY_STATE_DIR` 追加のみ・既定値付き）。戻り値(0/1/2)・ラベル遷移・ログ書式不変
- NFR 1.4 — `stage_a_verify_read_round` の不在→"0" 既定維持（stage-a-verify.sh:608-615）。テスト「初回 read（不在）→ round=0」（ケース1）
- NFR 2.1 — `stage_a_verify_read_round` は副作用なし。繰り返し read で値不変（テスト全体で複数回 read）
- NFR 2.2 — reset 冪等（ケース4）
- NFR 3.1 — `_sav_handle_failure` の `sav_log "round=... outcome=..."`（stage-a-verify.sh:677/698 不変）
- NFR 4.1 — README「Stage A Verify Gate (#125)」節・env var 表・オプション機能一覧・#246 migration note を同一コミットで更新（README.md diff 確認）

## Findings

なし

## Summary

design-less impl のため tasks.md は不在だが、変更は round counter の永続化先を worktree 外へ
移す単一責務に閉じており、Out of Scope（verify 抽出ロジック / コメント文面 / ラベル契約）を
侵していない。全 numeric requirement ID（1.1〜4.3）および NFR 1.1〜4.1 に対応する実装と新規
回帰テスト（test-round-counter-persistence.sh 全 15 ケース PASS / TEST_EXIT=0）を確認。
shellcheck も対象 2 ファイルでクリーン。AC 未カバー / missing test / boundary 逸脱はいずれも
検出されなかった。

RESULT: approve
