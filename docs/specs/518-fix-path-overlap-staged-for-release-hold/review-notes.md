# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.8 timestamp=2026-07-27T01:47:05Z -->

## Reviewed Scope

- Branch: claude/issue-518-impl-fix-path-overlap-staged-for-release-hold
- HEAD commit: 715e4fe71cbc788fcd6e329bb72da602030d7eec
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/path-overlap.sh` / `local-watcher/test/po_staged_holder_dropfilter_test.sh`（新規）/ `README.md` / spec 成果物（requirements.md, impl-notes.md）
- 本 Issue は design-less impl（`tasks.md` / `design.md` 不在）。`_Boundary:_` アノテーションは
  存在しないため、境界は requirements.md の scope（Path Overlap Checker = `path-overlap.sh`）で判定した。
- CLAUDE.md に `## Feature Flag Protocol` 節（`**採否**:` 行）は存在しない（rules テーブルの
  参照行のみ）。よって flag 観点は適用せず、通常の 3 カテゴリ判定のみを実施。

## Verified Requirements

- 1.1 — `po_resolve_staged_drop_label`（dispatch×multi-branch のみ `staged-for-release` を返す純粋関数）+ `po_collect_inflight_issues` の post-filter（`drop_staged_label` を持つ Issue を `continue` 除外）。テスト Case 1 + collector Case A（union=README.md のみ）
- 1.2 — collector Case A: staged+ready 併存 Issue 40 が holders[local-watcher/] に非計上、holders[README.md]=41 のみ
- 1.3 — dispatch gate 経路への配線（`po_check_dispatch_gate` L896-903 が drop ラベルを collector に注入）。除外により当該 Issue が union から脱落し、既存 overlap 判定で candidate が awaiting-slot に落ちない（Case A の union 除外がその前提を担保）
- 2.1 — single-branch（BASE=PROMOTION_TARGET）で drop ラベルが空 → filter 無効化 = holder 維持。Case 2/3（空文字返却）
- 2.2 — promote context では multi-branch でも空文字。Case 4
- 2.3 — drop なし経路の出力等価（NFR 1 ゼロ差分）。Case B（union に両 path 残置 / 除外ログなし）
- 3.1 — flock-skip 可視化経路 `po__visibility_evaluate_candidate` L991-997 が通常経路と同一の `po_resolve_staged_drop_label "dispatch"` + collector を呼ぶ配線。除外規則の実体は共有関数（テスト済み Case A）に一元化
- 3.2 — 両呼び出し元が同一引数 `po_resolve_staged_drop_label "dispatch"` を用い drop 計上有無を同一決定（コード配線 diff で確認）
- 4.1 — labels 取得不能 Issue は drop せず holder 維持（fail-safe）。Case D（labels キー欠落 Issue 42 が holders[docs/] に残留）
- 4.2 — context 判定不能（不明値 / 省略）で空文字 = holder 維持。Case 5/6
- NFR 1.1 — `PATH_OVERLAP_CHECK` gate 早期 return は本差分で不変（drop 解決は gate 有効後にのみ発生）
- NFR 1.2 — staged 未付与 Issue の holder 計上不変。Case E（staged 不在は drop_label 指定でも全 holder 維持）
- NFR 2.1 / 2.3 — `--json number` → `--json number,labels` の同一 API 拡張でラベル取得。Case A で `gh issue list` 呼び出しが 1 回のみを assert
- NFR 2.2 — `po_load_edit_paths` は非 drop Issue 各 1 回（既存ループ構造不変）
- NFR 3.1 — 除外を issue 単位でログ出力（`holder-set excluded staged issue=#N label=...`）。Case A で issue=#40 / label=staged-for-release を assert

## Findings

なし

## Summary

現行確定 requirements.md の全 AC（Req 1〜4）および NFR を、`path-overlap.sh` の post-filter 追加と
新規 22 assertion のテストで観測可能にカバー。新規テスト 22 pass / 既存 po 回帰（19 + 10）green、
`bash -n` / `shellcheck` 警告ゼロを reviewer 側でも再実行し確認。変更は Path Overlap Checker と
README 同期・spec 成果物に限定され境界逸脱なし。requirements.md Open Questions に記録された
`ready-for-review` 残置解消 / 遷移プロセッサは明示的に Out of Scope（別 Issue 候補）であり、当該
impl PR の reject 理由には含めない（設計レベルの還流は別経路の責務）。

RESULT: approve
