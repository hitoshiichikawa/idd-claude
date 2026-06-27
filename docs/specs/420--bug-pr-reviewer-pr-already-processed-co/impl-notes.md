# 実装メモ (#420)

## 採用方針

仮案 A（`gh api --paginate --slurp` + `per_page=100`）を採用。`pr_already_processed`
の単一関数を全ページ走査へ書き換えることで、3 つの呼び出し経路
（`pr_post_exec_fail_escalation_comment` / `pr_post_error_comment` /
`pr_run_review_for_pr` の review marker 判定）に同時にフィックスが行き渡る。

### 不採用案の弊害

- **仮案 B（Search API）**: 全文検索 API は eventual consistency があり、投稿直後の
  marker 検出が確実でない。レート制限も別系統で運用が読みづらい。
- **仮案 C（PR body marker への移行）**: marker 形式変更は NFR 1.2（既存 marker 文字列
  形式不変）と衝突する。既存投稿済み marker との互換性のため二重判定が必要になり、
  最小変更原則からも逸脱する。

### 仮案 A の優位性

- 既存の (sha, kind) 単位判定セマンティクス（NFR 1.3）と marker 形式（NFR 1.2）を完全
  維持。引数順 / 戻り値契約も不変（NFR 1.1）
- `pr_already_processed` という単一の集約点の修正で 3 経路すべてに同時適用される
  （Req 2.1, 2.2, 2.3, 2.4）
- `per_page=100`（GitHub REST 最大値）により、コメント 100 件以下の PR では 1 ページのみで
  完結 → 30 件以下では呼び出し回数を増やさない（NFR 2.1 既存挙動と等価）
- `--paginate` は途中ページ失敗で非ゼロ終了するため、既存の `if !` フォールバック分岐に
  自然に合流（Req 3.1, 3.2, 3.3, 3.4）

## 変更ファイル一覧

| File | 種別 | 概要 |
|------|-----|------|
| `local-watcher/bin/modules/pr-reviewer.sh` | 修正 | `pr_already_processed` を `gh api --paginate --slurp` + `per_page=100` + jq `(add // []) \| any(...)` 経路へ書き換え。ヘッダコメントに Issue #420 の経緯を追記 |
| `local-watcher/test/pr_already_processed_pagination_test.sh` | 新規 | ページネーション挙動 / 取得失敗 fallback / gh 呼び出し引数検証の 15 件アサーション。`extract_function` イディオム |

`pr-reviewer.sh` の関数 signature・marker 形式・env var 名・gh API path は不変。
GitHub Actions workflow / labels / `repo-template/` への変更は不要（root ↔
`repo-template/.claude/{agents,rules}` parity も保持。`diff -r` で空を確認済）。

## AC Traceability

| AC | 担保するコード / テスト |
|----|----------------------|
| Req 1.1 全コメント走査 | `pr-reviewer.sh:268-273`（`gh api --paginate --slurp ... per_page=100`） / test Section 4 |
| Req 1.2 30 件以下の従来挙動 | `pr-reviewer.sh:274-278`（jq `add // []` の平坦化が単ページでも同じ結果） / test Section 1 (A, B) |
| Req 1.3 31 件以上 / marker が page2 以降 | test Section 2 (A, C) — 105 件 / 205 件で page2・page3 末尾の marker 検出 |
| Req 1.4 31 件以上 / marker 不在 | test Section 1 (C 0 件) / Section 2 (B 105 件 marker 無) |
| Req 1.5 (sha, kind) 単位判定 | jq filter は `sha=` / `kind=` の両方を `[^>]*` 連結で test() / test Section 2 (D) sha 一致 kind 不一致 → rc=1 |
| Req 1.6 marker 形式不変 | `pr_build_marker` 未変更（line 223-228）。判定 regex も `idd-claude:pr-reviewer sha=...kind=...` の従来形式 |
| Req 2.1 exec-fail-escalated 経路 | `pr-reviewer.sh:607` の `pr_already_processed` 呼び出し（経路共有） |
| Req 2.2 pr_post_error_comment 経路 | `pr-reviewer.sh:945` の `pr_already_processed` 呼び出し（経路共有） |
| Req 2.3 review 経路 | `pr-reviewer.sh:1418` の `pr_already_processed` 呼び出し（経路共有） |
| Req 2.4 全経路で誤判定回避 | 単一関数の修正により 3 経路すべてに同時適用（実装の自然な帰結） |
| Req 3.1 取得失敗で安全側 rc=0 | `pr-reviewer.sh:269-272` の `if !` フォールバック / test Section 3 (A) |
| Req 3.2 途中ページ失敗で安全側 rc=0 | `gh api --paginate` は途中ページ rc≠0 で abort → 同一 fallback / test Section 3 (B) |
| Req 3.3 失敗時の WARN ログ | `pr-reviewer.sh:271` `pr_warn "コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"` / test Section 3 (A, B) |
| Req 3.4 全経路で fallback 一貫 | 単一関数で fallback 経路を実装、各経路は当該関数の rc=0 を「skip すべき」として扱う既存契約のまま |
| NFR 1.1 入出力契約不変 | 関数 signature `pr_already_processed(pr_number, sha, kind)` / 戻り値意味 0=既存 1=未存在 不変 |
| NFR 1.2 marker 形式不変 | `pr_build_marker` 不変 |
| NFR 1.3 (sha, kind) 単位 | jq filter の `test("idd-claude:pr-reviewer sha=" + $sha + "[^>]*kind=" + $kind)` 不変（tool= 属性は照合外） |
| NFR 1.4 env var 名・既定値不変 | `PR_REVIEWER_GIT_TIMEOUT` のみ参照、新規 env var 追加なし |
| NFR 1.5 投稿済み marker 不変 | 既存コメント本文への書き換えなし |
| NFR 2.1 ≤30 件で呼び出し増えない | `per_page=100` により 100 件以下は 1 ページで完結 / test Section 1 (gh 呼び出し回数=1) |
| NFR 2.2 timeout 範囲内 | 既存 `timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api ...` の wrapper 不変 |
| NFR 3.1 観測ログ粒度維持 | `pr_warn` の既存メッセージ「コメント取得に失敗」を流用、ログ出力契約不変 |
| NFR 3.2 取得失敗を pr_warn 記録 | 同上 |

## 静的解析・テスト実行結果

- `bash -n local-watcher/bin/modules/pr-reviewer.sh` → OK
- `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` → OK（警告ゼロ）
- `shellcheck local-watcher/test/pr_already_processed_pagination_test.sh` → OK
- `bash local-watcher/test/pr_already_processed_pagination_test.sh` → **PASS=15 FAIL=0**
- 既存 PR 関連テスト 13 本（`pr_*.sh` / `pdr_*.sh`）を subshell 実行 → 全 PASS（回帰なし）
- 退行検出テスト: 実装を一時 revert して同テスト実行 → 6 件 FAIL（pagination 不足を確実に検出）

## 確認事項

- `gh` の `--slurp` フラグは gh 2.x で導入済み（手元: 2.92.0 で動作確認）。サポート最小
  バージョンが明文化されていないが、`install.sh` / `setup.sh` で gh インストール手順が
  公式リポジトリ最新版を案内しているため運用上の制約はない見込み。古い gh 利用者がいる
  場合は別 issue でドキュメント補足を検討。
- 仮案 A は marker 数 100 件超のページネーション境界をテストで網羅したが、実環境では
  `auto-merge` 等で 200 件超のコメントを抱える PR も想定される（Section 2 Case C で
  3 ページ走査までは検証済み）。

STATUS: complete
