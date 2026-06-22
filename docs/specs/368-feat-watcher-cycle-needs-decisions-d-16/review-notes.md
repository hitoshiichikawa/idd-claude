# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T22:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-368-impl-feat-watcher-cycle-needs-decisions-d-16
- HEAD commit: cd8d99d2c64c53b01445e87edee1878c5e8edab0
- Compared to: main..HEAD
- 変更ファイル: README.md / docs/specs/368-*/{impl-notes.md, requirements.md} / local-watcher/bin/issue-watcher.sh / local-watcher/bin/modules/dep-cycle-detect.sh (新規) / local-watcher/test/dc_cycle_sweep_test.sh (新規) / local-watcher/test/dr_unblock_sweep_test.sh
- 備考: `tasks.md` / `design.md` は本 spec に存在しないため（Architect 経由していない直接 dev 経路と判断）、判定は `requirements.md` の numeric ID と実装/テストの突き合わせで実施した

## Verified Requirements

- 1.1 (gate ON で起動) — `dc_gate_enabled` が `dr_unblock_gate_enabled` を呼び、`dr_unblock_sweep` (issue-watcher.sh:10199) が gate ON 時に `dc_cycle_sweep` を呼び出す（issue-watcher.sh:10238）。テスト: `dc_gate_enabled: =true で gate ON`
- 1.2 (gate OFF で完全 no-op) — `dr_unblock_sweep` 内の `if ! dr_unblock_gate_enabled; then return 0` (issue-watcher.sh:10199-10201) により gate OFF 時は `dc_cycle_sweep` 呼び出し前に early return。テスト: `dc_gate_enabled: 未設定で OFF / =false は OFF`
- 1.3 (不正値正規化) — `dr_unblock_gate_enabled` の `case` で `=true` 厳密一致以外は OFF。テスト: `=True (typo) は OFF / =1 は OFF`
- 1.4 (既存 signature 不変) — `dr_*` 関数は不変、`dr_unblock_sweep` への変更は前処理呼び出し追加のみ。既存 56 テスト全 PASS
- 1.5 (FULL_AUTO_ENABLED kill switch) — `dr_unblock_sweep` 内で `full_auto_enabled` (issue-watcher.sh:10194-10197) を gate より前に評価し、OFF なら抑止ログ 1 行 + return
- 2.1 (auto-dev+blocked+OPEN 列挙) — `dr_unblock_sweep` の `gh issue list --label auto-dev --label blocked --state open` (issue-watcher.sh:10212-10219) で取得した `issues_json` を `dc_cycle_sweep` に渡す
- 2.2 (対象外エッジ除外) — `dc_extract_edges` が `targets_lines` フィルタで対象集合外を除外。テスト: `Req 2.2: 対象集合外 #999 は除外` / `dc_build_graph_lines: 対象集合外エッジ除外`
- 2.3 (auto-unblock 前段で起動) — issue-watcher.sh:10238 で auto-unblock ループ前に `dc_cycle_sweep` を呼び出す
- 2.4 (空集合で追加 API ゼロ) — `dr_unblock_sweep` の count=0 で early return (issue-watcher.sh:10226-10229) + `dc_cycle_sweep "[]"` でも API ゼロ。テスト: `Req 2.4: 空候補集合 → gh 呼び出しゼロ`
- 3.1 (自己ループ検出) — `dc_find_cycles` の Tarjan awk が `self_loop[src]` を記録し、SCC サイズ 1 + self_loop で閉路採用。テスト: `AT-b: 自己ループ #42→#42 → cycle {42}`
- 3.2 (任意長閉路) — SCC サイズ >= 2 は無条件で閉路。テスト: `AT-c (2N) / AT-d (3N) / Req 3.2: 長さ 4`
- 3.3 (複数閉路区別) — `scc_groups[root]` で SCC ごとに区別、出力は 1 行/閉路。テスト: `AT-f: 2 独立閉路`
- 3.4 (閉路 + DAG 混在) — DAG 部分は SCC サイズ 1 自己ループなしで閉路非採用。テスト: `Req 3.4: 非閉路 DAG 部分は除外`
- 3.5 (有限時間終了) — Tarjan iterative 実装 (O(V+E))、awk 関数ローカルスコープで完結。テスト: 空入力での終了確認
- 4.1 (needs-decisions 付与) — `dc_escalate_member` の `gh issue edit --add-label "$LABEL_NEEDS_DECISIONS"`。テスト: `Req 4.1: 未通知 → needs-decisions 付与 1 回`
- 4.2 (説明コメント投稿) — `dc_escalate_member` の `gh issue comment --body`。テスト: `Req 4.2: 未通知 → 説明コメント投稿 1 回`
- 4.3 (マーカー含む) — `dc_format_cycle_comment` の `${DC_CYCLE_MARKER}` 埋め込み。テスト: `Req 4.3 / NFR 4.2: 説明コメントに本機能由来マーカー含む`
- 4.4 (auto-unblock 除外) — `dr_unblock_sweep` 内に cycle-member skip 分岐 (issue-watcher.sh:10254-10260) + `_DC_CYCLE_MEMBERS` export。テスト: `AT-j: _DC_CYCLE_MEMBERS に member 含む`
- 4.5 (ラベル失敗時コメント skip) — `dc_escalate_member` の label `if !` ブロックで `return 0` 早期離脱。テスト: `Req 4.5: ラベル付与失敗 → コメント投稿せず skip`
- 4.6 (コメント失敗時 warn + 次へ) — `dc_escalate_member` の comment `if !` で `dr_warn` 出力後 `return 0`。テスト: `AT-i / Req 4.6: コメント投稿失敗 → 警告ログ 1 行`
- 5.1, 5.2, 5.3, 5.4 (冪等性) — `dc_has_cycle_marker` で HTML マーカー検出時に label/comment 両方 skip + `cycle_already_notified` ログ。テスト: `AT-g: 連続 2 回スイープ → 累積なし`
- 6.1 (閉路ごとログ) — `dr_log "dc_cycle_sweep: cycle=${cycle_count} members=${cycle_line}"`。テスト: `Req 6.1: 閉路ごとのログ 2 行`
- 6.2 (ゼロ件ログ) — `dr_log "dc_cycle_sweep: cycles=0 targets=..."`。テスト: `Req 6.2: cycles=0 サマリログ 1 行以上`
- 6.3 (エスカレーションログ) — `dr_log "issue=#${issue_num} verdict=cycle_escalated members=..."`。テスト: `Req 6.3: verdict=cycle_escalated ログ 1 行`
- 6.4 (冪等 skip ログ) — `dr_log "issue=#${issue_num} verdict=cycle_already_notified members=..."`。テスト: `Req 6.4: verdict=cycle_already_notified ログ 1 行`
- 6.5 (gh 失敗 warn) — `dr_warn "issue=#${issue_num} ... 失敗"`。テスト: `Req 4.5: ラベル付与失敗 → 警告ログ 1 行`
- 7.1 (local-watcher 限定) — 変更ファイル一覧で `repo-template/**` / `.claude/{agents,rules}/` 変更なしを確認（`diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` も空）
- 7.2 (README 更新) — `README.md` のラベル状態遷移まとめ / オプション機能一覧 / `Dependency Auto-Unblock Sweep` 節に cycle 検出を追記
- 7.3 (依存記法ガイド不変) — `.claude/rules/issue-dependency.md` への変更なしを確認
- NFR 1.1, 1.2 (後方互換性) — gate OFF で gh API 呼び出しゼロ、`dr_*` signature 不変。既存 56 テスト PASS
- NFR 2.1, 2.2, 2.3 (性能) — `dc_cycle_sweep` が `issues_json` を再利用、Tarjan O(V+E)。テスト: `NFR 2.2: 本文取得 API 呼び出しゼロ`
- NFR 3.1 (空依存安全) — `dr_extract_deps` 空出力で `dc_extract_edges` も空。テスト: `NFR 3.1: 空依存のみ → ラベル付与ゼロ`
- NFR 3.2 (gh 失敗 fail-open) — `dc_has_cycle_marker` の gh 失敗時は「投稿済扱い」、`dc_escalate_member` は label/comment 失敗時 `return 0`。テスト: `NFR 3.2: gh 失敗 → 安全側で投稿済扱い`
- NFR 3.3 (cycle 優先) — `_DC_CYCLE_MEMBERS` 経由で auto-unblock skip
- NFR 4.1, 4.2 (監査性) — `dr:` プレフィックス継承、HTML マーカー含む
- NFR 5.1 (未信頼入力安全) — `dc_normalize_targets` `^[0-9]+$` フィルタ、`dc_escalate_member` 数値検証、`jq --arg/--argjson` 使用
- NFR 5.2 (コメント安全展開) — `dc_format_cycle_comment` 内で数値検証済を `#N` 形式へ整形
- NFR 6.1 (冪等性) — 連続 2 回で 1 回収束（AT-g）

## Findings

なし

## Summary

要件定義 (Req 1〜7 + NFR 1〜6) に対する実装・テストカバレッジが全て確認できた。`dc_*` namespace
で新規モジュール `dep-cycle-detect.sh` を切り出し（CLAUDE.md §1, §2 準拠）、既存
`DEP_AUTO_UNBLOCK_ENABLED` 配下に同居して opt-in 制を維持（CLAUDE.md §3）。gate OFF / 未設定 /
不正値は外部副作用ゼロで導入前と等価。boundary は `local-watcher/` のみで `repo-template/**` /
`.claude/{agents,rules}/` は不変。新規 74 テスト + 既存 56 テスト全 PASS。AC 未カバー /
missing test / boundary 逸脱はいずれも検出されず。

RESULT: approve
