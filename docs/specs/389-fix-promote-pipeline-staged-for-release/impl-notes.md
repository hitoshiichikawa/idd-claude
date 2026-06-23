# Implementation Notes (#389)

## 実装サマリ

`pp_collect_merged_issues` の Issue 番号導出ソースを `closingIssuesReferences` 単独から、
**「`closingIssuesReferences` + head ブランチ名 `^claude/issue-([0-9]+)-impl-` 経由」の和集合**
へ拡張した。これにより `BASE_BRANCH=develop` 等の gitflow 運用（GitHub が closing-issue
リンクを自動生成しない条件）でも、impl PR の merge 直後に対象 Issue へ `staged-for-release`
が自動付与される。

主な変更点:

- `local-watcher/bin/modules/promote-pipeline.sh`
  - 新規 helper `pp_extract_linked_issues` を追加（純関数 / jq で和集合 + unique 抽出）
  - `pp_collect_merged_issues` 内の `gh pr list --json` フィールドに `headRefName` を追加
    （gh API 呼び出し回数は変えない / Req 3.5）
  - linked issues 抽出を `pp_extract_linked_issues` 呼び出しに置換
  - issue 番号使用直前に `^[0-9]+$` 防御検証を追加（Req 1.5 / NFR 4.2）
- `local-watcher/test/pp_extract_linked_issues_test.sh` を新規追加（`extract_function`
  イディオム / 10 ケース）

## AC Traceability

| AC | カバーするテスト / 実装 |
|----|------------------------|
| Req 1.1 (head パターン導出) | Case 2, 4, 6, 8, 9 / `pp_extract_linked_issues` 内 jq `capture` |
| Req 1.2 (和集合 + 重複排除) | Case 3, 6 / jq `+ unique` |
| Req 1.3 (パターン不一致時の除外) | Case 4 (`feature/manual-fix`, `claude/issue-50-design-spec`) |
| Req 1.4 (BASE_BRANCH=develop 補完) | Case 2, 9 (`closingIssuesReferences=[]` でも #N 抽出) |
| Req 1.5 (`^[0-9]+$` 検証) | Case 8 (`abc`/`implfoo` 不一致) / `[[ =~ ^[0-9]+$ ]]` 防御層 |
| Req 2.1.1-2.1.5 (既存付与契約維持) | 既存 `pp_collect_merged_issues` 後段ループは未変更 |
| Req 2.3 (fork PR 除外) | Case 5 (fork user の `claude/issue-77-impl-fork` を除外) |
| Req 2.4 (source 区別なし) | `pp_log` フォーマット文字列を変更せず |
| Req 3.1 (opt-in gate 維持) | `pp_collect_merged_issues` 呼び出し条件は未変更 |
| Req 3.2 (main 既存運用の不変) | Case 1 (closing 単独で #42 抽出) / Case 3 (両経路同一 #N → 1 件) |
| Req 3.3 (env var / ラベル名不変) | diff 確認: `LABEL_STAGED_FOR_RELEASE` / `PROMOTE_GIT_TIMEOUT` 等参照のみ |
| Req 3.4 (limit 不変) | `--limit 50` / `--limit 100` を変更せず |
| Req 3.5 (gh API 呼び出し回数不変) | `gh pr list` の `--json` フィールドに `headRefName` を追加するのみ |
| Req 4.1-4.4 (スコープ外不可侵) | `pp_resolve_merge_sha` / `pp_get_st_state` / `pp_handle_st_*` / `po_*` は未変更 |
| Req 5.1 (4 ケース近接テスト) | Case 1-4 |
| Req 5.2 (fork PR 近接テスト) | Case 5 |
| Req 5.3 (単一スクリプトで起動可) | `bash local-watcher/test/pp_extract_linked_issues_test.sh` |
| Req 5.4 (develop 想定 fail-condition) | Case 9（fail 時に PR 番号 / head 名 / 期待 Issue を出力） |
| NFR 1.1-1.3 (後方互換) | Case 1 / diff: ラベル名・env var 名・ログ書式の改変なし |
| NFR 2.1-2.2 (静的検査) | `bash -n` OK / `shellcheck` warnings 0 |
| NFR 3.1-3.3 (可観測性) | `pp_log` / `pp_warn` のフォーマット文字列を一切変更せず |
| NFR 4.1 (jq `--arg` で未信頼入力) | `pp_extract_linked_issues` は `--arg owner`、`headRefName` は jq 内で完結 |
| NFR 4.2 (`^[0-9]+$` 検証) | bash 側で使用直前 `[[ =~ ^[0-9]+$ ]]` + jq の `capture` 二重防御 |

## テスト結果

- `bash -n local-watcher/bin/modules/promote-pipeline.sh` → OK
- `shellcheck local-watcher/bin/modules/promote-pipeline.sh local-watcher/bin/issue-watcher.sh` → warnings 0
- `shellcheck local-watcher/test/pp_extract_linked_issues_test.sh` → warnings 0
- `bash local-watcher/test/pp_extract_linked_issues_test.sh` → **PASS=10 FAIL=0**
- regression: `sn_callsite_promote_test.sh` (PASS=15) / `po_apply_awaiting_slot_test.sh`
  (PASS=19) / `po_sticky_comment_helpers_test.sh` (PASS=10) すべて PASS

## 設計上の判断

- **jq 1 pass 内処理**: head 経路導出を bash ループではなく jq 内で `capture` + 和集合 +
  unique 完結とした。理由: (1) PR JSON を 2 周しなくて済み Req 3.5 (gh API 呼び出し回数
  不変) と整合しやすい、(2) `headRefName` を `--arg` 経由ではなく jq 内で `capture`
  すれば値の bash 展開が発生せず NFR 4.1 (未信頼入力フラグ注入防止) 上安全、(3)
  既存 `closingIssuesReferences` 抽出も jq 内で完結している既存スタイルに合わせられる。
- **helper 切り出し**: `pp_extract_linked_issues` を独立した純関数として切り出した。
  理由: Req 5.1 が `extract_function` で隔離抽出可能な近接テストを要求しており、`gh`
  呼び出しを含む `pp_collect_merged_issues` 全体を抽出するより、JSON in → 番号 out の
  純関数として分離した方が gh stub 不要でテストが簡潔になる。
- **bash 側二重検証**: jq の `capture("^claude/issue-(?<n>[0-9]+)-impl-")` で数値 ID は
  保証されるが、closingIssuesReferences 側の異常値や jq エラー時の防御として
  `[[ "$issue_number" =~ ^[0-9]+$ ]]` を bash 側にも入れた。Req 1.5 / NFR 4.2 のテキスト
  「使用直前に検証」の要求にも合致する。
- **`AUTO_MERGE_HEAD_PATTERN` との関係**: 既存 `AUTO_MERGE_HEAD_PATTERN` は
  `^claude/issue-.*-impl`（Issue 番号キャプチャなし）で、本機能とは正規表現セマンティクス
  が異なる。本実装は専用パターン `^claude/issue-([0-9]+)-impl-` を `pp_extract_linked_issues`
  内に literal で持つ（要件で許容: 「同パターンの正規表現セマンティクスと整合させるのみ」
  / Out of Scope「既定値の変更はしない」）。

## 確認事項

なし。要件定義は明瞭で、人間レビュー判断が必要な未解決項目は識別されなかった。

## STATUS

STATUS: complete
