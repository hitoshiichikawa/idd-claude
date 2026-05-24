# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-204-impl-bug-watcher-dependency-resolver-146-merg
- HEAD commit: d28e146d4f4d20677c204291605bd4489f38ed88
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しない → opt-out 解釈。flag 観点の細目は適用せず、通常の 3 カテゴリ判定のみ実施。

## Verified Requirements

- 1.1 — `dr_resolve_one` CLOSED 分岐で `nodes[].state == "MERGED"` を 1 件以上検出すれば `resolved`（issue-watcher.sh:6000-6018）。テスト `Req1.1 CLOSED+MERGED PR` / `Req1.1 CLOSED+(CLOSED,MERGED) 混在` で pass
- 1.2 — MERGED 0 件（PR が CLOSED のみ）で `closed unmerged`。テスト `Req1.2 CLOSED+CLOSED PR(未merge)` で pass
- 1.3 — 紐づく PR 0 件（空配列）で `closed unmerged`（`nodes[]?` + length 0 経路）。テスト `Req1.3 CLOSED+PR 0件` で pass
- 1.4 — `issue.state == "OPEN"` → `open`（case OPEN 分岐 issue-watcher.sh:5995 付近）。テスト `Req1.4 OPEN issue` で pass
- 1.5 — 取得経路を `gh issue view --json`（`.merged` 不在）から GraphQL `closedByPullRequestsReferences(first:20, includeClosedPrs:true){nodes{state}}` に是正（`dr_gh_graphql_closed_by` issue-watcher.sh:5896-5948）。観測可能経路 `state == "MERGED"` で判定
- 2.1 — gh rc!=0 / GraphQL HTTP200 errors を検査し `api error`（issue-watcher.sh で `gh_rc` 判定 + `.errors` 検査）。テスト `Req2.1 gh 失敗 rc!=0` / `Req2.1 GraphQL errors` で pass
- 2.2 — issue.state null/空・jq parse 失敗・集計が非数値 → `api error`（state null ガード + `[[ =~ ^[0-9]+$ ]]` ガード）。テスト `Req2.2 issue=null 想定外構造` / `Req2.2 壊れた JSON` / `未知の issue state` で pass
- 2.3 — caller `dr_check_dependencies`（issue-watcher.sh:6150-6157）で unresolved_lines が空でなければ block 確定。本修正で未変更（diff なし）、verdict 語彙整合で担保
- 2.4 — 全件 resolved で `return 0`（後続続行、issue-watcher.sh:6159-6161）。本修正で未変更
- 3.1 — verdict 語彙は `resolved` / `open` / `closed unmerged` / `api error` の 4 種に限定。caller の case 文（issue-watcher.sh:6125-6147）も同 4 語彙を消費しており新規語彙なし
- 3.2 — block 時の `blocked` 付与 + `claude-claimed` 除去は `dr_apply_block`（未変更、diff なし）で担保
- 3.3 — 既存 `blocked` 付与時の冪等 skip は `dr_check_dependencies` 冒頭ガード（issue-watcher.sh:6098-6101、未変更）で担保
- 3.4 — `dr_log` / `dr_warn` 関数本体は diff に含まれず書式不変
- 3.5 — 新規必須 env var なし。timeout は既存 `DRR_GH_TIMEOUT`（`MERGE_QUEUE_GIT_TIMEOUT` フォールバック）を流用。env var 名の変更・削除なし
- 4.1 — 実依存宣言行から `#N` を抽出（`Depends on:` / `前提依存:` / `Blocked by:`）。テスト `Req4.1 実依存行から抽出` で pass
- 4.2 — awk でコードフェンス（``` / ~~~）開閉トグルし内部行とマーカー行を除外。テスト `Req4.2 コードフェンス内は除外` / `フェンスのみ→空` / `チルダフェンス除外` で pass
- 4.3 — awk で行頭（空白許容）`>` の引用行を除外。テスト `Req4.3 引用ブロック除外` / `インデント引用除外` で pass
- 4.4 — `sort -u -n` で重複排除 + 数値昇順。テスト `Req4.4 重複排除+昇順` で pass
- 4.5 — 抽出対象行に記法なしで空 stdout + 副作用なし。テスト `Req4.5 依存なし→空` / `空入力→空` で pass
- 5.1 — 検証スイートに `Req1.1 CLOSED+MERGED PR` → resolved ケースあり
- 5.2 — `Req1.2 CLOSED+CLOSED PR(未merge)` → closed unmerged ケースあり
- 5.3 — `Req1.4 OPEN issue` → open ケースあり
- 5.4 — 同一 fixture（CLOSED+MERGED）で旧式 `.merged==true` が 0 件・新式 `.state=="MERGED"` が 1 件であることを assert する Red→Green ガードあり（test-dependency-resolver.sh:157-169）
- NFR 1.1 — 依存記法 0 件で `dr_extract_deps` が空 → `dr_check_dependencies` 早期 return（gh 呼び出し 0 回）。早期 return 経路は未変更
- NFR 1.2 — `needs-decisions` 状態は `dr_apply_block`（未変更）で変更されない
- NFR 2.1 / 2.2 — 構造化ログ（`dr_log`）と警告ログ（`dr_warn` を stderr へ）の書式不変
- NFR 3.1 — `dr_resolve_one` は依存 1 件あたり `gh api graphql` を 1 回のみ呼ぶ（state + PR nodes を 1 リクエストで取得）。依存件数に対し線形

## 独立検証ログ

- `git diff --stat main..HEAD`: 変更は impl-notes.md / test-dependency-resolver.sh / issue-watcher.sh の 3 ファイルのみ。`requirements.md` 等の仕様書き換えなし
- `git diff main..HEAD -- local-watcher/bin/issue-watcher.sh`: 変更 hunk は `dr_extract_deps` / 新規 `dr_gh_graphql_closed_by` / `dr_resolve_one` に限定。`dr_check_dependencies` / `dr_apply_block` への変更なし（boundary 内）
- `bash docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh` → `All 21 cases passed.` exit 0 を確認（reviewer 自身で再実行）
- Out of Scope（既存 Issue retrofit / Actions workflow / 逆ブロッキング `Blocks:` / 非ブロッキング関係種別 / watcher 全体の path 管理）への侵食は差分に存在しない

## Findings

なし

## Summary

requirements.md の全 numeric AC（Req 1.1〜5.4 / NFR 1〜3）に対応する実装が確認でき、回帰テスト 21 ケースが全 pass。verdict 語彙・ラベル契約・ログ書式・env var の後方互換が保たれ、boundary 逸脱・missing test・AC 未カバーはいずれも検出されなかった。

RESULT: approve
