# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-383-impl-fix-watcher-stage-checkpoint-resumable-s
- HEAD commit: 8f51e41de5083fd2d9bfc30f75221ba6f304b517
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh` (+141 / -10) — 新規ヘルパ
    `_stage_checkpoint_has_resumable_state` 追加 + spec-dir 経路 slug guard 呼び出し元
    （`_slot_run_issue` 内、`_matched_dir` 空の fallback ブロック）の case 分岐挿入
  - `local-watcher/test/stage_checkpoint_resumable_state_test.sh` (+359, new) —
    12 ケース・18 アサーションの近接テスト
  - `docs/specs/383-*/{requirements,impl-notes}.md` — spec 成果物
- tasks.md は本 Issue では未生成（Triage 経路で Architect が起動されなかったため。
  小規模な watcher 単一関数修正であり Boundary 判断は requirements.md の Out of Scope と
  既存ファイル境界で十分に決まる）

## Verified Requirements

- **1.1** — spec dir 検出時に判定が走る: `_slot_run_issue` 内の SPEC_CANDIDATES 非空 +
  `_matched_dir` 空ブロック（`local-watcher/bin/issue-watcher.sh:10670-10672`）で
  `_stage_checkpoint_has_resumable_state` を call
- **1.2** — 4 観点不在 → skip: 新関数 return 1 → caller `case 1)` 分岐で
  `SLUG="$EXPECTED_SLUG"` 採用（test Case 1, 12 + caller code 10674-10679）
- **1.3** — skip 時に needs-decisions 付与なし: `case 1)` 分岐は
  `_slug_mismatch_escalate` を call しないため `_slug_mismatch_escalate` 内の
  `gh issue edit ... --add-label needs-decisions` 経路に入らない（caller code 10674-10679）
- **1.4** — skip 時に escalate コメント投稿なし: 同上（`_slug_mismatch_escalate` 不呼び出し）
- **1.5** — 複数候補 + expected 不一致 → 同 skip 経路: `_matched_dir` ループで
  match が見つからなければ `_first="${SPEC_CANDIDATES[0]}"` から `_stage_checkpoint_has_resumable_state`
  を call し、return 1 なら同じ `case 1)` 分岐へ落ちる（caller code 10670）
- **2.1** — 4 観点いずれか実在 → fire: 新関数 return 0 → caller `case *)` 分岐で
  `_stage_checkpoint_assert_slug_match` を call（test Cases 2, 3, 4, 5, 6, 3b +
  caller code 10680-10691）
- **2.2** — match 時の resume 継続: `_matched_dir` 非空経路（10654-10662）は無変更で
  既存 `_stage_checkpoint_assert_slug_match` 経路を維持
- **2.3** — mismatch + resumable state 実在 → escalate: caller `case *)` 分岐内で
  `_stage_checkpoint_assert_slug_match` が rc=1 を返した時に `return 1`（既存挙動を維持）
- **2.4** — spec dir 不在時の新規スラグ導出: 10694-10698 の else 経路は無変更
- **3.1** — OR 4 観点判定: `_stage_checkpoint_has_resumable_state` 内で (a) impl PR
  (b) origin impl-* branch (c) impl-notes.md tracked (d) review-notes.md tracked を
  順次評価、最初に hit したら return 0（test Cases 2, 3, 3b, 4, 5, 6）
- **3.2** — 観測失敗時 safe-side: 各観点で gh API rc≠0/1 や `git ls-remote` rc≠0、
  `git ls-tree` 失敗を `detection_failed=true` に集約し、全観点が hit せず failure が
  1 件でもあれば return 2（test Cases 7, 8, 10, 11）
- **3.3** — `stage_checkpoint_resolve_resume_point` から独立観測: 新関数は
  `stage_checkpoint_resolve_resume_point` を call せず、`stage_checkpoint_find_impl_pr` /
  `git ls-remote` / `git ls-tree` のみを直接呼ぶ（code review）
- **4.1** — skip 経路のログ: caller の `case 1)` で
  `stage-checkpoint: slug-guard-skipped issue=#<N> expected=<exp> found=<found>
  reason=no-resumable-state` を 1 行 LOG 出力（issue/expected/found を含む。NFR 3.2 充足）
- **4.2** — slug-match / slug-mismatch ログ: `_stage_checkpoint_assert_slug_match` は
  無変更で既存 `slug_match_guard_test.sh` 13 ケース全 PASS（回帰なし）
- **4.3** — WARN ログ: gh API / git failure 時に `stage-checkpoint: WARN
  resumable-state-detection ...` を stderr へ 1 行出力（code review）
- **NFR 1.1** — env var / label / cron / exit code 不変: 新規 env var なし、
  既存ラベル `needs-decisions` `claude-claimed` は無変更（code review）
- **NFR 1.2** — resumable state 実在 + slug 一致時の挙動維持: `_matched_dir` 非空経路は
  無変更（10654-10662）
- **NFR 1.3** — spec dir 不在時の新規スラグ導出: 10694-10698 は無変更
- **NFR 1.4** — opt-in gate なしで導入: 新規 env var を追加していない。CLAUDE.md
  「opt-in gate と後方互換」原則の「既定挙動の no-op 維持」と整合（fork/mirror 誤
  resume 防止は resumable state 実在経路で完全維持されるため、緩和の方向の挙動変更
  であり gate 不要）
- **NFR 2.1** — 安全側挙動: 観測失敗は return 2 → caller の `*)` 分岐で従来の
  `_stage_checkpoint_assert_slug_match` 経路を call（fork/mirror 誤 resume 防止維持）
- **NFR 2.2** — 既存 spec dir 無変更: 新関数は `git ls-tree` / `git ls-remote` /
  `gh pr list` の read-only ops のみ
- **NFR 2.3** — 新規 docs/specs/ 作成や umbrella 書き換えを含めない: 新関数は読み取り
  のみ、caller は `SLUG="$EXPECTED_SLUG"` 設定のみで `mkdir` 等を行わない
- **NFR 3.1** — 1 イベント 1 行: 全 echo 行が改行を含まない単一行（code review）
- **NFR 3.2** — issue 番号・expected・found 3 値の含有: caller `slug-guard-skipped`
  ログに 3 値すべて含まれる（10677）
- **NFR 4.1** — extract_function + stub イディオム: 新規 test は
  `extract_function "$WATCHER_SH" "_stage_checkpoint_has_resumable_state"` で関数定義
  のみ抽出し、`stage_checkpoint_find_impl_pr` / `git` / `timeout` を test 内で stub
- **NFR 4.2** — 既存 `slug_match_guard_test.sh` 全 13 ケース PASS（実行確認済）
- **NFR 4.3** — skip 経路 + 発火経路を最低 1 件ずつ: Case 1（skip）+ Cases 2-5（発火）

## Boundary Check

- 修正対象は `local-watcher/bin/issue-watcher.sh` の Stage Checkpoint 関連関数 +
  近接テストの追加のみ。CLAUDE.md「機能追加ガイドライン」の「本体 inline ではなく
  module へ切り出す」原則からは inline 追加に該当するが、`_stage_checkpoint_assert_slug_match`
  と同居領域への近接配置であり、Stage Checkpoint module（`stage-checkpoint.sh` 等）が
  独立 module として存在しない現状（同関数群が本体 inline）に整合する
- `repo-template/` 配下に `issue-watcher.sh` の mirror は存在しない（`repo-template/`
  には `CLAUDE.md` のみ。impl-notes.md の主張と一致）。二重管理同期の対象外
- Out of Scope（requirements.md 97-115）の boundary は遵守（二次的所見の解消・
  Triage プロンプト変更・`_resume_branch_assert_slug_match` 変更・`_normalize_slug`
  変更・新規 escalation 先追加は本 PR に含まれていない）

## Test Execution Verification

- `bash local-watcher/test/stage_checkpoint_resumable_state_test.sh` → PASS 18 / FAIL 0
- `bash local-watcher/test/slug_match_guard_test.sh` → PASS 13 / FAIL 0（回帰なし）
- `shellcheck local-watcher/bin/issue-watcher.sh
  local-watcher/test/stage_checkpoint_resumable_state_test.sh` → 警告ゼロ

## Findings

なし

## Summary

requirements.md の全 numeric ID（Req 1.1〜1.5 / 2.1〜2.4 / 3.1〜3.3 / 4.1〜4.3 /
NFR 1.1〜1.4 / 2.1〜2.3 / 3.1〜3.2 / 4.1〜4.3）が実装または近接テストでカバーされており、
新規ヘルパ `_stage_checkpoint_has_resumable_state` の発火経路・skip 経路・safe-side
経路がいずれも fixture テストで検証されている。既存 `slug_match_guard_test.sh` も
13 ケース全 PASS で回帰なし。境界も requirements.md の Out of Scope を逸脱していない。

RESULT: approve
