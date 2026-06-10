# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-10T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-316-impl-fix-watcher-dr-resolve-one-develop-dispa
- HEAD commit: 53f433c3b7d3513feb6c9b9cd088a4bf7db74599
- Compared to: main..HEAD

差分構成:
- `local-watcher/bin/issue-watcher.sh` — `dr_gh_graphql_closed_by` の GraphQL クエリに
  `labels(first: 20) { nodes { name } }` を追加。`dr_resolve_one` の OPEN 分岐に
  base 相対化（`BASE_BRANCH=main` は従来パスを early-out、`!= main` で
  `staged-for-release` ラベル時のみ `resolved`）と log 出力を追加
- `docs/specs/316-.../test-dependency-resolver-base.sh` — 新規 21 ケースの shell-level 回帰テスト
- `docs/specs/316-.../requirements.md`, `impl-notes.md` — spec 成果物

注:
- `design.md` / `tasks.md` は存在せず、本 Issue は design-less impl（bug fix）として
  扱われる。tasks.md の `_Boundary:_` 制約は適用対象外
- CLAUDE.md に `## Feature Flag Protocol` 節は存在せず、opt-out 既定として通常 3 カテゴリ判定のみを実施

## Verified Requirements

- 1.1 — `BASE_BRANCH != main` + OPEN + `staged-for-release` → `resolved`：
  `dr_resolve_one` の OPEN 分岐に jq `--arg target` で `staged-for-release` を集計し
  `true` → `resolved` を返す実装あり。テスト `Req1.1 develop+OPEN+staged-for-release`
  と `Req1.1 任意 base != main + 他ラベル混在` で検証
- 1.2 — `BASE_BRANCH = main` + OPEN + `staged-for-release` → 未解決（open）：
  `if [ "${BASE_BRANCH:-main}" = "main" ]; then echo "open"; return 0; fi` で早期 return。
  テスト `Req1.2 main+OPEN+staged-for-release は open`
- 1.3 — OPEN で `staged-for-release` なし → 任意 base で未解決：
  jq 集計結果 `false` → `echo "open"`。テスト 3 ケース（develop ラベルなし / develop 他ラベルのみ / main ラベルなし）
- 1.4 — CLOSED + MERGED PR → 従来通り `resolved`：既存 CLOSED 分岐温存。
  テスト 3 ケース（develop / main / main+SfR ラベル混在）
- 1.5 — CLOSED + MERGED なし → 従来通り `closed unmerged`：既存ロジック温存。
  テスト 2 ケース（develop CLOSED PR / main 0 件）
- 2.1 — state とラベル一覧を同一問い合わせで取得：`labels(first: 20) { nodes { name } }` を
  既存 GraphQL クエリに同梱。テスト `Req2.1 単一 response に state + labels + PR 一覧が同梱`
  で構造を直接検証
- 2.2 — state/labels の取得・解析失敗時 → `api error`（安全側）：
  `dr_resolve_one` 既存 state 取得失敗パス温存 + 新規 labels jq 失敗時に
  `dr_warn`+`echo "api error"`。テスト 3 ケース（gh 失敗 / GraphQL errors / 壊れた JSON）
- 2.3 — labels 取得失敗時に staged-for-release 付与を仮定しない：
  jq parse 失敗時は `api error` を返し `resolved` には倒さない。
  labels ノード欠落時も `jq ... .nodes[]?` で空配列扱い → length=0 → false → `open` に
  倒れることをテスト `Req2.3 OPEN + labels ノード欠落は staged を仮定せず open` で検証
- 3.1 — develop dispatch + OPEN + SfR → resolved の回帰テスト：Req 1.1 のケースで担保
- 3.2 — develop dispatch + OPEN + SfR なし → unresolved の回帰テスト：Req 1.3 のケースで担保
- 3.3 — main dispatch + OPEN + SfR → unresolved の回帰テスト：Req 1.2 のケースで担保
- 3.4 — CLOSED + merged PR → resolved の回帰テスト：Req 1.4 のケースで担保
- 3.5 — CLOSED + merged PR なし → closed unmerged の回帰テスト：Req 1.5 のケースで担保
- NFR 1.1 — `BASE_BRANCH=main` の挙動が本変更前と完全同一：`main` 早期 return + CLOSED
  分岐温存。テスト 5 ケース（NFR1.1 main+OPEN+SfR / main+OPEN+ラベルなし / main+CLOSED+MERGED /
  main+CLOSED+混在 / main+CLOSED+CLOSED PR）
- NFR 1.2 — 既存 env のみで制御し新規 env を導入しない：diff 上 `BASE_BRANCH` /
  `DRR_GH_TIMEOUT` / `LABEL_STAGED_FOR_RELEASE` のみ参照、新規 env var の追加なし
- NFR 1.3 — path-overlap holder 側 (#221) の base 相対化を変更しない：
  `git diff --stat` 上 `local-watcher/bin/modules/promote-pipeline.sh` の変更なし
- NFR 2.1 — API 呼び出し回数を変更前と同数に保つ：既存 `dr_gh_graphql_closed_by` の
  1 回の `gh api graphql` 呼び出しに `labels(first: 20)` を追加フィールドで載せただけで、
  呼び出し回数は不変
- NFR 3.1 — staged-for-release で解決した場合の理由 log 出力：
  `dr_log "issue=#${dep_num} verdict=resolved reason=staged-for-release base=${BASE_BRANCH:-main}"`
  を resolved 経路に追加

## Findings

なし

## Summary

新規 21 ケースのテストはすべて pass（reviewer も `bash test-dependency-resolver-base.sh` を
再実行して確認）。Req 1.1〜1.5 / 2.1〜2.3 / 3.1〜3.5 / NFR 1.1〜1.3 / 2.1 / 3.1 すべてが
実装またはテストにより観測可能で、`BASE_BRANCH=main` 経路の従来挙動が明示的な early-out で
温存されているため後方互換性も担保されている。design-less impl のため `_Boundary:_` 制約は
適用対象外、CLAUDE.md の Feature Flag Protocol も opt-out のため flag 観点の検査は対象外。

RESULT: approve
