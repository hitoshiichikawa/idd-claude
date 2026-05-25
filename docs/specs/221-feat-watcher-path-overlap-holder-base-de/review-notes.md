# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-221-impl-feat-watcher-path-overlap-holder-base-de
- HEAD commit: b6df018（`git diff 151d17b..HEAD` を真の差分として評価）
- Compared to: 151d17b（merge-base）..HEAD
- 真の追加分（5 ファイル / +367 -20）:
  - `local-watcher/bin/modules/promote-pipeline.sh` +136 -20（`po_resolve_holder_labels` /
    `po_build_label_or_clause` 新設、`po_collect_inflight_issues` 引数化、`po_check_dispatch_gate`
    からの集合注入 + NFR3 ログ）
  - `docs/specs/.../test-fixtures/test-holder-labels.sh` +139（新規 fixture）
  - `README.md` +39（Phase E 節の base 相対化 + 観測ログ追記）
  - `docs/specs/.../impl-notes.md` +63（Round 2 是正メモ）
  - `docs/specs/.../tasks.md`（task 2〜5 を `[x]` に更新）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 扱い。
  flag 観点の確認は行わず通常の 3 カテゴリ判定を適用。
- impl-notes.md 末尾 `STATUS: complete` を確認。標準判定を適用。
- ROUND=1 の reject 理由（Finding 1〜5: task 2〜5 未実装）が解消されているかを重点確認した。

## Verified Requirements

- 1.1 — `po_check_dispatch_gate`（promote-pipeline.sh:645）が `po_resolve_holder_labels "dispatch"`
  を呼び、結果を `po_collect_inflight_issues "$candidate" "$holder_labels"`（同:658）へ第 2 引数で
  注入。dispatch×multi-branch で `staged-for-release` 除外の 6 ラベル集合が in-flight 列挙クエリに
  反映される（orphan 解消）。fixture Case 1（PASS）が `BASE_BRANCH=develop`/`PROMOTION_TARGET_BRANCH=main`
  で 6 ラベル CSV を確認。
- 1.2 — `po_collect_inflight_issues`（同:320-345）が holder_labels CSV から `po_build_label_or_clause`
  経由で動的 search_query を組み立て、6 ラベル CSV では `staged-for-release` を含まないクエリになる。
  fixture Case 5b（PASS）が SfR 非含有 query を確認。SfR 単独 Issue は列挙から脱落する。
- 1.3 — dispatch gate（multi-branch）が 6 ラベル集合を注入し、SfR 単独 Issue が in-flight union から
  外れ overlap=0 → claim 続行する経路が成立（promote-pipeline.sh:658-669 の既存 overlap ロジックを
  通る）。配線は task 3 で確立。
- 1.4 — OR query が併存ラベルでヒットする既存挙動を維持。6 基本ラベルは常時集合内（NFR 1.2 invariant）
  のため、`staged-for-release` + `claude-claimed` 併存 Issue は `claude-claimed` 句で列挙され holder 維持。
- 2.1 — `po_resolve_holder_labels "promote"`（同:233-244）が full 7 ラベル CSV（SfR 維持）を返す。
  fixture Case 3（PASS）で確認。
- 2.2 — promote 経路（`pp_collect_merged_issues`、promote-pipeline.sh:802 の `is:merged base:` PR 列挙）は
  holder ラベルクエリを共有しない別経路（design.md D2）。本変更は当該経路に触れず、default 集合固定で
  契約保全。挙動不変。
- 3.1 / 3.2 / 3.3 — `po_resolve_holder_labels` が単一契約として context ごとに集合を決定（真理値表
  fixture Case 1〜4b で網羅）。stdout 出力のみで副作用なし、引数注入で用途間の判定が相互に独立。
- 4.1 — 不明 context / 空 context が full 集合へ倒れる fail-safe（同:241-243 の if 非該当時 echo full）。
  fixture Case 4 / 4b（PASS）で確認。
- 4.2 — `po_collect_inflight_issues`（同:336-339）が label_clause 空時に full 7 ラベル集合へ fallback。
  fixture Case 5c（空 CSV）が full クエリへ fallback することを PASS で確認。
- NFR 1.1 — 第 2 引数省略時の search_query が変更前ヒアドキュメント固定クエリと文字列一致。fixture
  Case 5（PASS）が `EXPECTED_QUERY`（変更前固定文字列）と捕捉クエリの一致を検証。`po_build_label_or_clause`
  の OR 句生成順序が default CSV 順序と一致するため文字列等価が成立。
- NFR 1.2 — 6 基本ラベルを常時含み差分は `staged-for-release` の有無のみ（`po_resolve_holder_labels`
  の base_labels invariant、fixture Case 1 で SIX_CSV と FULL_CSV の差分が SfR のみであることを確認）。
- NFR 2.1 / 2.2 — `gh issue list`（同:340）1 回 / 候補ごと `po_load_edit_paths`（同:358）1 回の構造は
  未変更。変更は search_query 文字列の組み立てのみで API 回数に影響なし。
- NFR 3.1 — `po_check_dispatch_gate`（同:650-652）が解決集合 != full（= SfR 除外発生）時のみ
  `po_log "holder-set context=dispatch excluded=... base=..."` を出力。`po_log` は `path-overlap:`
  prefix を付与（同:45）するため実出力は `path-overlap: holder-set ...` となり README の grep 例 / 出力例と
  一致。full と一致する single-branch では出力せずゼロ差分を維持。

## Findings

なし（ROUND=1 の Finding 1〜5 はすべて解消済み）。

ROUND=1 で指摘した解消状況:
- Finding 1（1.1 orphan / 集合未注入）: `po_check_dispatch_gate` から `po_resolve_holder_labels "dispatch"`
  の結果を第 2 引数注入し、`po_collect_inflight_issues` を動的クエリ化（task 2/3）→ 解消。
- Finding 2（1.2 / 1.3）: 動的 search_query 化と集合注入により SfR 単独 Issue が列挙脱落 → 解消。
- Finding 3（4.2）: `po_collect_inflight_issues` に label_clause 空時の full 集合 fallback を実装 → 解消。
- Finding 4（NFR 3.1）: 除外発生時に `holder-set ...` ログを出力（full 一致時は非出力）→ 解消。
- Finding 5（missing test）: `test-holder-labels.sh` を新設し 8 ケース全 PASS（真理値表 4 ケース +
  空 context + search_query ゼロ差分 + 6 ラベル SfR 非含有 + 空 CSV fallback）→ 解消。

## 検証実施

- `bash docs/specs/221-feat-watcher-path-overlap-holder-base-de/test-fixtures/test-holder-labels.sh`
  → `PASS=8 FAIL=0` / exit 0。
- `shellcheck local-watcher/bin/modules/promote-pipeline.sh test-holder-labels.sh` → exit 0（警告ゼロ）。
- `git diff 151d17b..HEAD -- local-watcher/bin/issue-watcher.sh` → 差分なし（本体不変 / boundary 維持）。
- fixture のラベル定数名（LABEL_CLAIMED 等）が issue-watcher.sh:60-75 の実定数と同値であることを確認。
- `po_check_dispatch_gate` シグネチャ（`$1 candidate` / `$2 labels_json`）不変、opt-in gate
  （`PATH_OVERLAP_CHECK = "true"` 厳密一致）/ fail-open / overlap ロジックは未変更（boundary 逸脱なし）。

## Summary

ROUND=1 の reject 理由（task 2〜5 未実装による Req 1.1/1.2/1.3/4.2/NFR 3.1 の観測可能挙動不成立、
task 4 fixture 欠如）はすべて解消された。全 numeric ID（Req 1.1〜4.2 / NFR 1.1〜3.1）が実装または
テストで裏打ちされ、fixture 8 ケース全 PASS・shellcheck クリーン・issue-watcher.sh 本体不変・
シグネチャ不変を確認。boundary 逸脱なし。approve とする。

RESULT: approve
