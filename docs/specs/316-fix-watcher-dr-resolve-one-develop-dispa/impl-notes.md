# Implementation Notes — #316

## 概要

依存ゲート `dr_resolve_one` に base 相対化を導入し、`BASE_BRANCH != main` の multi-branch
（gitflow）運用で依存先 Issue が `OPEN` かつ `staged-for-release` ラベルを持つ場合に
解決済み (`resolved`) として分類するようにした。`BASE_BRANCH=main` の従来挙動は完全に
維持する（NFR 1.1）。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`
  - `dr_gh_graphql_closed_by` (:8870 付近) の GraphQL クエリに `labels(first: 20) { nodes { name } }`
    を追加。state / labels / closedByPullRequestsReferences を 1 回の問い合わせで取得（NFR 2.1）
  - `dr_resolve_one` (:8924 付近) の OPEN 分岐に base 相対化ロジックを追加:
    - `BASE_BRANCH=main` → ラベル参照せず `open`（従来挙動 / Req 1.2）
    - `BASE_BRANCH!=main` → labels を jq で集計し、`staged-for-release` 付与時のみ `resolved`
    - labels の jq parse 失敗 / 想定外応答 → `api error`（安全側 / Req 2.3）
  - `staged-for-release` による解決時には `dr_log` に `verdict=resolved reason=staged-for-release base=<BASE_BRANCH>`
    を出力し、運用者が分類根拠を log から判別できるようにした（NFR 3.1）
- `docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/test-dependency-resolver-base.sh`
  - shell-level の回帰テスト（#204 の test-dependency-resolver.sh と同パターン）
  - 21 ケースを網羅: Req 1.1〜1.5 / 2.1〜2.3 / NFR 1.1 をカバー

## 設計判断

### base 相対化の判定基準: `BASE_BRANCH != main` を採用

#221 の `po_resolve_holder_labels`（promote-pipeline.sh:240）では
`BASE_BRANCH != PROMOTION_TARGET_BRANCH` で multi-branch を判定している。
依存ゲートは Triage 段階で動作し promote コンテキストを持たないため、
Issue 本文の指示・requirements.md Req 1.1 に従い、より単純な
`BASE_BRANCH != main` を採用した（develop 以外の任意 branch 名でも main 以外なら
multi-branch 扱い、という Out of Scope 末尾の方針と整合）。

### ラベル定数のハードコード回避

`LABEL_STAGED_FOR_RELEASE` 定数を `jq --arg target` 経由で渡して比較する形にした
（promote-pipeline.sh と同じ `${LABEL_STAGED_FOR_RELEASE:-staged-for-release}` の
fallback パターン）。

### labels 取得失敗時の安全側挙動

`labels` ノードの jq parse に失敗した場合は **`api error` を返す**ことで、依存ゲートの
caller (`dr_check_dependencies`) が当該依存を未解決として扱い `blocked` を付与する経路に
合流する（Req 2.3 / Req 2.2 の挙動と整合）。「ラベル取得失敗 = `staged-for-release` 付与を
仮定して resolved にしてはならない」という要件を、より安全に倒して `open` ではなく
`api error` で返している（依存ゲート上は両者とも未解決として扱われるため挙動は等価）。

なお `labels` ノード自体が response 構造から欠落しているケース（旧クライアントが古い
クエリで叩いた応答が混入する等）は jq の `?` で空配列扱いとなり length=0 → false → `open`
を返す。これは「staged-for-release 付与を仮定して resolved にする処理は行わない」
（Req 2.3）の文意と整合する（`api error` ではなく `open` ではあるが、いずれも未解決として
扱われる安全側の挙動）。

### NFR 2.1 (API 呼び出し回数の維持)

`labels(first: 20)` を既存 GraphQL クエリに追加することで、依存先 Issue 1 件あたりの
`gh api graphql` 呼び出し回数は本変更前と同じ 1 回（dr_check_dependencies 全体で 2 回相当の
従来回数）に保たれている。

## テスト方法

```sh
# 新規テスト（21 cases）
bash docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/test-dependency-resolver-base.sh

# 既存 #204 回帰テスト
bash docs/specs/204-bug-watcher-dependency-resolver-146-merg/test-dependency-resolver.sh

# shellcheck（全 bash 成果物）
shellcheck local-watcher/bin/issue-watcher.sh \
           local-watcher/bin/modules/*.sh \
           install.sh setup.sh .github/scripts/*.sh \
           docs/specs/316-fix-watcher-dr-resolve-one-develop-dispa/test-dependency-resolver-base.sh
```

最終確認時の結果:

- 新規テスト 21/21 pass
- 既存 #204 テスト 21/21 pass（回帰なし）
- shellcheck 警告ゼロ

## 受入基準カバレッジ

| Req | 内容 | カバーするテストケース |
|---|---|---|
| 1.1 | `BASE_BRANCH != main` + OPEN + staged-for-release → resolved | `Req1.1 develop+OPEN+staged-for-release` / `Req1.1 任意 base != main + 他ラベル混在` |
| 1.2 | `BASE_BRANCH = main` + OPEN + staged-for-release → 従来通り未解決 | `Req1.2 main+OPEN+staged-for-release は open` |
| 1.3 | OPEN + staged-for-release なし → BASE_BRANCH 不問で未解決 | `Req1.3 develop+OPEN+ラベルなし` / `Req1.3 develop+OPEN+他ラベルのみ` / `Req1.3 main+OPEN+ラベルなし` |
| 1.4 | CLOSED + MERGED PR あり → 従来通り resolved | `Req1.4 develop+CLOSED+MERGED PR` / `Req1.4 main+CLOSED+MERGED PR` / `Req1.4 main+CLOSED+SfR+MERGED は resolved（ラベル無視）` |
| 1.5 | CLOSED + MERGED PR なし → 従来通り closed unmerged | `Req1.5 develop+CLOSED+CLOSED PR` / `Req1.5 main+CLOSED+PR 0 件` |
| 2.1 | state + labels を同一クエリで取得 | `Req2.1 単一 response に state + labels + PR 一覧が同梱` |
| 2.2 | state または labels の取得・解析失敗 → 安全側 (`api error`) | `Req2.2 gh 失敗時は base 値によらず api error` / `Req2.2 GraphQL errors は api error` / `Req2.2 壊れた JSON` |
| 2.3 | labels 取得・解析失敗時に staged-for-release 付与を仮定しない | `Req2.3 OPEN + labels ノード欠落は staged を仮定せず open`（実装側の jq エラー時は `api error` に倒す） |
| 3.1 | develop dispatch + OPEN + SfR で resolved となる回帰テスト | 上記 1.1 のテスト |
| 3.2 | develop dispatch + OPEN + SfR なしで unresolved となる回帰テスト | 上記 1.3 のテスト |
| 3.3 | main dispatch + OPEN + SfR で unresolved となる回帰テスト | 上記 1.2 のテスト |
| 3.4 | CLOSED + merged PR ありで resolved となる回帰テスト | 上記 1.4 のテスト |
| 3.5 | CLOSED + merged PR なしで closed unmerged となる回帰テスト | 上記 1.5 のテスト |
| NFR 1.1 | `BASE_BRANCH=main` の挙動が本変更導入前と完全同一 | `NFR1.1 main+OPEN+SfR は open（従来同一）` / `NFR1.1 main+OPEN+ラベルなしは open` / `NFR1.1 main+CLOSED+MERGED は resolved` / `NFR1.1 main+CLOSED+混在 は resolved` / `NFR1.1 main+CLOSED+CLOSED PR は closed unmerged` |
| NFR 1.2 | 既存 env のみで制御し新規 env var を導入しない | コードレビュー: 新規 env var 追加なし（`BASE_BRANCH` / `DRR_GH_TIMEOUT` / `LABEL_STAGED_FOR_RELEASE` の 3 つはいずれも既存） |
| NFR 1.3 | path-overlap holder 側 (#221) の base 相対化判定を変更しない | `local-watcher/bin/modules/promote-pipeline.sh` は本 PR で変更なし |
| NFR 2.1 | API 呼び出し回数を変更前と同数に維持 | コードレビュー: `gh api graphql` 呼び出しは 1 依存先あたり 1 回（旧と同じ）。labels は同じ呼び出しに追加フィールドで載せる |
| NFR 3.1 | resolved 分類時の理由を log に出力 | コードレビュー: `dr_log "issue=#${dep_num} verdict=resolved reason=staged-for-release base=${BASE_BRANCH:-main}"` を追加 |

## 確認事項

- なし。設計判断は requirements.md と #221 path-overlap holder の base 相対化規約から導出可能で、
  Issue 本文 / requirements.md / Out of Scope と整合している。
- 本変更は `BASE_BRANCH=main` の従来挙動を 1 切変えないため、既存 single-branch 運用への影響なし。
- 既稼働の self-hosting watcher に対しては、次サイクル以降の依存ゲート判定にのみ影響する
  （Triage 段階のラベル遷移のみ。dispatch 候補フィルタ・promote-pipeline 等への波及なし）。

STATUS: complete
