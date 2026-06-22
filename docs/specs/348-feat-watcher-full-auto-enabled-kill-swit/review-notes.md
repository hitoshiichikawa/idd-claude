# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-348-impl-feat-watcher-full-auto-enabled-kill-swit
- HEAD commit: a0c40163e20617fb66b3b665534fb8addf903891
- Compared to: main..HEAD

差分対象ファイル（`git diff --stat main..HEAD`）:

- `README.md` (+1)
- `docs/specs/348-feat-watcher-full-auto-enabled-kill-swit/impl-notes.md` (+156)
- `docs/specs/348-feat-watcher-full-auto-enabled-kill-swit/requirements.md` (+98)
- `local-watcher/bin/issue-watcher.sh` (+58 / -2)
- `local-watcher/bin/modules/scaffolding-health.sh` (+27)
- `local-watcher/test/dr_unblock_sweep_test.sh` (+11 / -1)
- `local-watcher/test/full_auto_enabled_test.sh` (+306, 新規)

Note: 本 spec には `tasks.md` / `design.md` が存在しない（単一実装パスでの直接実装。
本 review では `_Boundary:_` アノテーションは存在しないため、差分は要件・既存リポジトリ
規約・impl-notes の boundary に照らして判定した）。

## Verified Requirements

- **1.1** — Config block で `FULL_AUTO_ENABLED="${FULL_AUTO_ENABLED:-false}"` を宣言
  （`issue-watcher.sh` L123）。テスト: `full_auto_enabled_test.sh` Section 1
  「未設定なら disabled（rc=1）」
- **1.2** — `case` で `true` 厳密一致のみ通過（L129-132）。テスト: Section 1
  「=true 厳密一致で enabled（rc=0）」
- **1.3** — `case` 第 2 アーム `*)` で未設定 / 空 / `false` / `0` / `True` / `TRUE` /
  `1` / typo を `false` に正規化（L129-132）。テスト: Section 1 で 15 ケース網羅
  （空 / false / 0 / True / TRUE / 1 / on / yes / enable / enabled / Yes / tRue /
  前後空白付き / trues 等）
- **1.4** — Config ブロック（L100 番台）で正規化完了。full-auto processor 入口
  （`dr_unblock_sweep` L9627、`_dispatcher_run` 経由）より前に評価される
- **2.1〜2.4** — auto-merge / failed-recovery / needs-decisions auto / semantic conflict
  各 processor は impl-notes Phase 1 調査により**本 Issue 時点で未実装**と確認済み
  （`grep -rnE 'auto[_-]?merge|gh pr merge|failed[_-]?recovery|semantic[_-]?conflict'`）。
  要件 Open Questions が「実装済みのみ配線し、未実装のものは将来追加時に同じ kill
  switch を参照する設計とする」を明示的に許容しているため、配線対象外であることは
  要件範囲内（`full_auto_enabled()` ヘルパーが将来配線の pattern として提供されている）
- **2.5** — `dr_unblock_sweep` 冒頭 L9633-9636 で `full_auto_enabled` を AND 評価し、
  OFF なら外部副作用ゼロで早期 return。テスト: Section 2 Case A / A' / A''
  （kill OFF / 未設定 / typo `True` の全パターンで `gh` ゼロ呼び出し検証）
- **2.6** — kill ON 時は L9638 で個別 gate `dr_unblock_gate_enabled` を引き続き評価
  し、OFF なら no-op。テスト: Section 2 Case B / B'
- **2.7** — kill ON + 個別 gate ON で `gh issue list` が呼ばれ通常フロー進入。
  テスト: Section 2 Case C
- **3.1** — kill switch 未設定時は (a) Config 正規化（純粋関数 / 副作用なし）、(b)
  startup log への `full-auto=false` 追記、(c) `dr_unblock_sweep` 内 suppression log
  追記のみが差分。外部副作用（gh / git / ラベル / commit / push）は不変。
  テスト: Section 3 + 既存 `dr_unblock_sweep_test.sh` 全 56 ケース pass（retrofit 後）
- **3.2** — `sh_doctor_check_full_auto` は常に rc=0 で degraded 算入なし
  （`scaffolding-health.sh` L350-361）。`--doctor` は破壊されない
- **3.3** — `grep -n full_auto_enabled local-watcher/bin/modules/*.sh` 想定で、
  merge-queue / auto-rebase / promote-pipeline / pr-iteration / pr-reviewer /
  security-review / stage-checkpoint / stage-a-verify / quota-aware の各 module には
  `full_auto_enabled` 呼び出しを追加していない（diff 内に該当ファイル変更なし）
- **3.4** — 上記 3.3 と表裏一体。非 full-auto processor は個別 gate のまま
- **4.1** — `dr_log "dr_unblock_sweep: suppressed by FULL_AUTO_ENABLED kill switch (no-op)"`
  を kill OFF 時に出力（L9634）。テスト: Section 2 Case A「suppression ログ 1 行出力」
  + Section 3「未設定状態でも suppression ログを 1 行出力」
- **4.2** — `issue-watcher.sh` L836 で startup ログに `full-auto=${FULL_AUTO_ENABLED}`
  を追加（`base-branch=... merge-queue-base=... auto-rebase=... full-auto=...`）。
  運用者は `grep full-auto=` で kill switch 状態を確認可能
- **NFR 1.1** — kill switch 未設定時、追加されるのは「Config 正規化（純粋関数）」
  「startup ログトークン追加」「`dr_unblock_sweep` 内 suppression ログ追加」のみ。
  gh / git API 呼び出し / ラベル遷移 / commit / push の挙動は不変。impl-notes 記載の
  全テスト pass（既存 56 件 + 新規 28 件）が裏付け
- **NFR 1.2** — 新規 env `FULL_AUTO_ENABLED` のみ追加。既存 env / label / exit code /
  cron 文字列の変更なし（diff 確認）
- **NFR 2.1** — README L1363 にオプション機能一覧表へ Full-Auto Kill Switch 行を追加。
  既定値 `false` / `=true` 厳密一致 / pre-introduction 等価保証を明記
- **NFR 2.2** — impl-notes に `diff -r .claude/agents repo-template/.claude/agents` と
  `diff -r .claude/rules repo-template/.claude/rules` が clean と記録。
  `repo-template/local-watcher/` は repo に存在せず（idd-claude では local-watcher は
  repo-template 配布対象外）、対象外
- **NFR 3.1** — impl-notes に `shellcheck` rc=0 / `bash -n` rc=0 を記録

## Findings

なし

## Summary

要件定義の全 numeric ID（Req 1.1〜4.2 + NFR 1.1〜3.1）について、実装または既存コード /
テストでカバーを確認した。未実装 processor（Req 2.1〜2.4）は要件 Open Questions が
明示的に「実装済みのみ配線」を許容しており、`full_auto_enabled()` ヘルパーで将来配線の
pattern を提供しているため要件範囲内。boundary 逸脱 / missing test なし。

RESULT: approve
