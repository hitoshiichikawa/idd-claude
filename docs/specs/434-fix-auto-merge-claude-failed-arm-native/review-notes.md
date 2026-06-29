# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.8 timestamp=2026-06-29T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-434-impl-fix-auto-merge-claude-failed-arm-native
- HEAD commit: b7213f33926e8db06c8a31c2326c3a8ce8730de6
- Compared to: main..HEAD
- 注記: HEAD == main（コミット未作成）のため `git diff main..HEAD` は空。Developer の成果物は
  working tree（変更 3 ファイル + 新規 4 ファイル）に存在するため、これを実体として読み判定した。
  本 Issue は単一実装パス（Architect 非経由）で tasks.md / design.md / impl-notes.md は非生成。
  `_Boundary:_` アノテーションが無いため、境界は requirements.md の Out of Scope と CLAUDE.md の
  module 配置規約に照らして評価した。

## Verified Requirements

- 1.1 — `amx_should_disarm_for_pr`（LABEL_FAILED 検査）+ `process_auto_merge_disarm` / test:
  auto-merge-disarm_test.sh Section2 Req1.1, Case C（disarm 1 回）
- 1.2 — `amx_should_disarm_for_pr`（LABEL_NEEDS_DECISIONS 検査）/ test: Section2 Req1.2, Case G（design PR）
- 1.3 — 両 terminal ラベル → disarm 対象 / test: Section2 Req1.3
- 1.4 — `process_auto_merge_disarm` が `gh pr list` で GitHub 直接クエリ（pending state dir 参照なし）/
  test: Case C（gh pr list 呼び出し検証）
- 1.5 — arm 済みだが terminal ラベル無し → return 1 / test: Section2 Req1.5, Case D
- 2.1 — `autoMergeRequest == null` → return 1（no-op）/ test: Section2 Req2.1, Case E
- 2.2 — `state != OPEN`（MERGED/CLOSED）→ 対象外 / test: Section2 Req2.2, Case I
- 2.3 — 対象 0 件 → 副作用なしサマリ 1 行で終了 / test: Case D
- 2.4 — `amx_disarm_pr` 失敗時 WARN 1 行 + rc=1（fail-open）/ test: Section3 Req2.4
- 2.5 — ループは 1 件失敗で中断せず継続（failed_count 加算）/ test: Case H（3 件中 1 件失敗で 3 件試行）
- 3.1 — `pr_publish_claude_status` の success ガード（claude-failed 検出で skip）/ test:
  pr_reviewer_claude_status_fail_closed_test.sh Section1 Req3.1
- 3.2 — needs-decisions 検出で skip / test: Section1 Req3.2
- 3.3 — adjudicator 経路 `adj_apply_status_decision` → `pr_publish_claude_status`
  （adjudicator.sh:790）。単一 publisher へのガード集約で自動 fail-closed 化。呼び出しグラフを確認
- 3.4 — catch-up 経路 `pr_publish_claude_status_from_branch` → `pr_publish_claude_status`
  （pr-reviewer.sh:1441）。同上、呼び出しグラフを確認
- 3.5 — terminal 無し → 従来どおり publish、reject(failure) は terminal でも publish / test:
  Section2 Req3.5
- 4.1 — `gh pr view --json labels` で現在ラベルを再取得して判定 / test: Section1
- 4.2 — 再取得失敗時は publish 継続（fail-open）/ test: Section3 Req4.2
- 4.3 — 再取得失敗時に WARN 1 行 / test: Section3 Req4.3
- NFR1.1/1.2 — gate OFF（kill switch / 両 arm 源 OFF）で gh ゼロ呼び出し no-op / test: Case A/B
- NFR1.3 — ガードは既存 publisher 内に集約、新規外部呼び出し gate を追加せず既存 claude-review
  publish gate の内側で動作
- NFR2.1 — PR 番号を `^[0-9]+$` で検証 / test: NFR2.1
- NFR2.2 — `gh pr merge ... -- "$pr_number"` でオプション解釈打ち切り / test: NFR2.2
- NFR2.3 — 未信頼値（pattern / owner / label）を `jq --arg` で渡す（inline 展開なし）
- NFR3.1 — disarm 実行時に PR 番号 + disarmed のログ行 / test: NFR3.1, サマリ行
- NFR3.2 — 対象 0 件はサマリ 1 行のみ / test: Case D
- NFR4.1 — modules は `local-watcher/` のみに存在し repo-template 側コピー無し（同期対象 vacuous）。
  `.claude/{agents,rules}` は無変更で drift 無し（`git diff --stat` 空を確認）
- NFR4.2 — README に Auto-Merge Disarm Processor 節 + オプション機能一覧を同一変更で追加

### 追加検証

- 静的解析: `shellcheck`（新規 module / pr-reviewer.sh / test 2 本）警告ゼロ、`bash -n issue-watcher.sh` OK
- テスト再実行: auto-merge-disarm_test.sh = PASS 40 / FAIL 0、
  pr_reviewer_claude_status_fail_closed_test.sh = PASS 11 / FAIL 0
- Out of Scope 遵守: `am_should_enable_for_pr`（arm 時点判定）を含む auto-merge.sh /
  auto-merge-design.sh は無変更。新規 terminal ラベル追加なし。Slack 通知文面変更なし
- module 配置: 新 processor を `modules/auto-merge-disarm.sh` に切り出し、専用 prefix `amx_` を
  割当、`REQUIRED_MODULES` ローダ + 本体 call site（arm 直後に直列配置）に登録（CLAUDE.md 機能追加
  ガイドライン準拠）

## Findings

なし

## Summary

全 AC（Req 1.1〜4.3 + NFR 1〜4）の観測可能な実装・テストを working tree 上で確認。disarm processor /
fail-closed ガードとも対応テストが green（40/0, 11/0）、shellcheck / bash -n クリーン、Out of Scope
逸脱なし。Req 3.3/3.4 は単一 publisher へのガード集約により adjudicator / catch-up 経路へ自動波及する
ことを呼び出しグラフで確認した。境界・AC・test の 3 観点で reject 事由なし。なお HEAD == main で
変更がコミット未確定（working tree）であり、impl-notes.md も非生成だが、いずれも本 reviewer の 3
カテゴリ外の事項であるため判定には影響させない（PR 作成前に commit が必要な点のみ情報として記す）。

RESULT: approve
