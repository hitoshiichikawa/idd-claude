# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-06-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-433-impl-fix-pr-design-reviewer-pr-spec-pr-none-a
- HEAD commit: d23b1ef9f80daf85d07353d7aa7a00faa6de8690
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol`（採否: opt-in）節なし → 通常の 3 カテゴリ判定のみ（flag 観点は適用せず）
- 単一実装パス（Architect 不在 / `tasks.md`・`design.md` なし）のため `_Boundary:_` アノテーション照合は対象外。変更ファイルはすべて本バグ修正スコープ内（`pr-design-reviewer.sh` / `design-review-prompt.tmpl` / `README.md` / 新規テスト 2 本）

## Verified Requirements

- 1.1 — `pdr_invoke_reviewer` が `git show "origin/${head_ref}:.../requirements.md"` で取得（pr-design-reviewer.sh ループ）/ spec_fetch ケース1（REQ_BODY_TOKEN 埋め込み確認）
- 1.2 — 同ループ design.md 取得 / spec_fetch ケース1（DESIGN_BODY_TOKEN）
- 1.3 — 同ループ tasks.md 取得 / spec_fetch ケース1（TASKS_BODY_TOKEN）
- 1.4 — 作業ツリー `[ -d ]`+`cat` を git ref 取得へ置換し、未マージ spec も読める / spec_fetch ケース4（取得不能分のみ `(none)`）
- 1.5 — 取得成功ファイルは実本文を使用し `(none)` を埋めない / spec_fetch ケース1（`(none)` 不在）・ケース4（REQ_ONLY_TOKEN）
- 2.1 — `fetched_count == 0` で rc=3 → approve 非 publish / spec_fetch ケース2・fail_closed ケース1（status/label/comment 副作用ゼロ）
- 2.2 — `[ -z "$spec_dir_rel" ]` で rc=3 / spec_fetch ケース3
- 2.3 — spec dir 解決済みでも全取得不能なら rc=3 / spec_fetch ケース2
- 2.4 — rc=3 を `pdr_run_review_for_pr` で既存 rc=2（pending 据え置き）へ写像、marker/コメント/status 不投稿 / fail_closed ケース1（rc=2 / 副作用ゼロ）
- 2.5 — fail-closed は claude 起動前に評価し LLM リクエスト未発行 / spec_fetch ケース2・3（claude_call_count==0）
- 2.6 — 既存 exec 失敗時 rc=2 経路と同一の status/ラベル契約を共有 / 既存 pdr_no_op テスト非回帰で間接担保
- 3.1 — 解決済み dir + 取得不能の事実を併記した WARN 1 行 / spec_fetch ケース2（WARN に SPEC_DIR と「取得できず」）
- 3.2 — fail-closed 経路で verdict=approve 完了ログを出さない / fail_closed ケース1（pending 据え置きログ・status publish なし）
- 4.1 — parse/validate 失敗時の保守的 approve を不変維持（コードは parse/validate パス未改変）/ fail_closed ケース4 非回帰
- 4.2 — spec 取得成功時の parse/validate 失敗→既存保守的 approve 経路維持 / 既存 parse_verdict テスト + fail_closed ケース4
- 4.3 — fail-closed を「spec 本文取得不能」のみに限定 / fail_closed ケース4（rc=0 で approve 3 系統が発火）
- 5.1 — design-review-prompt.tmpl の「spec dir/ファイル不在→(none)→approve」記述を fail-closed と整合する記述へ更新（diff 確認）
- 5.2 — README Design PR Reviewer 節（カタログ/動作概要/典型運用/トレードオフ）を同一 PR で fail-closed と整合（diff 確認）
- 5.3 — テンプレートの 3 観点判定基準・reject 禁止・read-only 制約を不変維持（diff 確認）
- NFR 1.1 — `DESIGN_REVIEWER_ENABLED` 既定 OFF 不変（gate 未改変）
- NFR 1.2 — 既存 env（`PR_REVIEWER_GIT_TIMEOUT` 等）/ラベル/status 名/ログ出力先 不変
- NFR 1.3 — 新規 env gate 追加なし（既存 `PR_REVIEWER_GIT_TIMEOUT` 流用）
- NFR 1.4 — `pdr_run_review_for_pr` の exit code 意味（0/1/2）不変（rc=3→rc=2 写像）/ fail_closed ケース1
- NFR 2.1 — module/template は repo-template に未配布、`diff -r` agents/rules 空（同期対象差分ゼロ）
- NFR 3.1 — fail-closed pending 据え置きの観測ログ 1 行 / fail_closed ケース1

## Findings

なし

## Summary

全 numeric ID（Req 1〜5 / NFR 1〜3）に観測可能な実装と対応テストを確認。新規挙動（git ref 取得・fail-closed rc=3→rc=2 写像・WARN）はテストで担保され、既存 pdr テスト 6 本は非回帰（FAIL: 0）。未信頼 head_ref は spec fetch 前に shell metacharacter 検証済み。AC 未カバー / missing test / boundary 逸脱いずれも検出せず。

RESULT: approve
