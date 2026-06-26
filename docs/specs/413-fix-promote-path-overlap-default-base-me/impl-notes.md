# Implementation Notes — Issue #413

## 概要

`BASE_BRANCH` がリポジトリの default branch（典型的に `main`）以外で運用される
multi-branch（gitflow）設定において、impl PR が `BASE_BRANCH` に merge された後も対応
Issue から `ready-for-review` ラベルが除去されない問題を修正する。Path Overlap Checker
が当該 stale な `ready-for-review` を holder として誤計上し、後続 Issue を
`awaiting-slot` で無期限ブロックする実害を解消する。

## 採用方針

- 要件 Decisions と Open Questions の検討結果に従い「方針 A（post-merge で `ready-for-review`
  除去）」のみを実装する。方針 B（Path Overlap 側での holder 除外）は #221 で既に
  実装済みのため、本 PR では新規実装を行わず多重防御として既存契約が機能し続ける
  ことを宣言する位置付け
- 入力経路は `pp_collect_merged_issues` 内で `pp_extract_linked_issues` が確定する
  「`closingIssuesReferences` + head ブランチ名」の和集合（Req 1.6 既定。Open
  Question で言及された「`gh issue list --label staged-for-release --state open` を
  入力に取り直す」案は採用しなかった。理由は impl-notes 末尾「確認事項」参照）

## 変更ファイル一覧

- `local-watcher/bin/modules/promote-pipeline.sh`
  - 新規関数 `pp_remove_ready_for_review_if_present` を追加（`pp_issue_has_label` の
    直後、`pp_extract_linked_issues` の直前）
  - 既存 `pp_collect_merged_issues` の per-Issue ループに 1 行追加
    （`pp_remove_ready_for_review_if_present "$issue_number"` の呼び出し）
- `local-watcher/test/pp_remove_ready_for_review_test.sh`（新規）
  - extract_function イディオムで対象関数 + 依存ヘルパー（`pp_issue_has_label`）を
    隔離抽出し、gh / pp_log / pp_warn / timeout を stub して呼び出しトレース・ログ
    出力を観測する 23 ケースの近接テスト
- `README.md`
  - 「Phase B Promote Pipeline」節「目的」に `ready-for-review` 除去を追記
  - 「ログ識別語」表に成功時 / 失敗時の 2 行を追加

## 設計判断（なぜそこに追加したか）

### 関数配置: `promote-pipeline.sh` 内の `pp_issue_has_label` 直後

- `pp_remove_ready_for_review_if_present` は `pp_issue_has_label` を直接呼ぶため、
  既存 helper 群の物理的近接位置に置くことで読みやすさを保つ
- prefix は `pp_` namespace（promote-pipeline 既存規約）。新規 module は作らない
  （Req 1.6 で入力経路を `pp_collect_merged_issues` の per-Issue ループに固定し、
  promote-pipeline 内で完結する小機能のため / CLAUDE.md「機能追加ガイドライン」1）

### 統合点: `pp_collect_merged_issues` の per-Issue ループ

- 既存ループは `linked_issues`（`pp_extract_linked_issues` の出力 = 和集合 + 重複排除済
  Issue 番号配列）を行ごとに処理する。本 PR では当該ループの先頭、数値 ID 再検証
  直後・`pp_issue_has_label "$LABEL_STAGED_FOR_RELEASE"` 判定の前に
  `pp_remove_ready_for_review_if_present "$issue_number"` 呼び出しを追加した
- `staged-for-release` が既付与で `continue` されるパスでも `ready-for-review` 除去を
  発火させる必要があるため、`continue` 前に呼び出す配置にした（既に
  `staged-for-release` が立っている Issue でも、人間運用や過去サイクル取りこぼしで
  `ready-for-review` が残っているケースを救済する）

### 副作用の最小化（NFR 2.1 / NFR 2.2）

- 既未付与 Issue では `gh issue edit` を再送しないために `pp_issue_has_label` で
  事前確認する（`gh issue view --json labels` を 1 回呼ぶ）。
- NFR 2.2 は「追加の `gh issue list` / `gh pr list` を発火させない」ことを要求して
  おり、本実装は `gh issue list` / `gh pr list` を新規に呼ばない（既存
  `pp_collect_merged_issues` が呼ぶ既存 2 経路を共有するだけ）
- per-Issue で `gh issue view --json labels` が（既存の staged-for-release 判定とは
  別に）1 回増える。これは正当な API コスト（label 状態確認の前提）であり、NFR 2.2
  は明示禁止していない

### 未信頼入力の取り扱い（NFR 3.1 / 3.2）

- `pp_remove_ready_for_review_if_present` 冒頭で `^[0-9]+$` の再検証を行い、不一致
  なら早期 `return 0`。`gh issue edit` 引数や URL に展開する直前の最終ゲート
- 既存 `pp_collect_merged_issues` のループ側でも同じ正規表現で再検証しているため
  防御層は二重化されている（`pp_extract_linked_issues` の jq capture 段階含めて
  三重）

### 失敗時の挙動（Req 1.5 / 4.3）

- `gh issue edit` 失敗時は `pp_warn` で 1 行 WARN ログを出し、戻り値 0 を返す
  （`set -e` 下でも fail-continue が壊れない）。WARN 文字列は要件 4.3 の例
  `issue=#<N> ready-for-review 除去に失敗（後続 Issue は継続）` に厳密一致

### 設計 PR / 他フォーマット PR / fork PR の除外（Req 3.1 / 3.2）

- 入力経路を `pp_extract_linked_issues` の和集合に固定したことで、`^claude/issue-([0-9]+)-impl-`
  に一致しない head（設計 PR `claude/issue-<N>-design-*` / 人間 PR / 他フォーマット）
  は head 経路から落ち、fork PR も `headRepositoryOwner.login` 比較で落ちる。本関数
  はそれらが落ちた後の Issue 番号集合のみを入力にするため、追加の除外ロジックは
  不要

### 対象範囲外の opt-out 動作（Req 3.4 / NFR 1.2）

- 本変更は `pp_collect_merged_issues` 内のループに 1 行追加するだけ。
  `pp_collect_merged_issues` は `process_promote_pipeline` から呼ばれ、当該関数は
  `PROMOTE_PIPELINE_ENABLED != "true"` で早期 return する。よって gate OFF 時には
  本変更コードパスに到達しない（外形契約 ゼロ差分）

## 追加テストケースの観点（7 ケース / 23 assertions）

NFR 4.2 が要求する 5 ケースは Case 1, 2, 3, 4, 5 で網羅。境界（NFR 3.2 / fail-continue
連続呼び出し）の補強として 2 ケース（Case 6, 7）を追加した。

| Case | 観点 | 該当 AC |
|---|---|---|
| 1 | closingIssuesReferences 経路で除去が発火 | Req 1.1, 4.1 |
| 2 | head ブランチ名経路で除去が発火（base != default 想定） | Req 1.2 |
| 3 | 同一 Issue を 2 回呼んでも 1 回のみ edit（冪等性） | Req 1.3, 1.6 |
| 4 | 既未付与 Issue は edit を呼ばずスキップ + INFO/WARN ログなし | Req 1.3, 4.2, NFR 2.1 |
| 5 | edit 失敗時の WARN ログ 1 行 + 戻り値 0 | Req 1.5, 4.3 |
| 6 | 数値 ID 不正（`-1` / 空文字）は view / edit を呼ばない | NFR 3.2 |
| 7 | 連続呼び出しで 1 件失敗しても 2 件目が成功（fail-continue） | Req 1.5 |

## AC Traceability（requirements.md ↔ テスト）

| Requirement ID | テストケース | 備考 |
|---|---|---|
| Req 1.1 | Case 1 | closingIssuesReferences 経路 |
| Req 1.2 | Case 2 | head ブランチ名経路 |
| Req 1.3 | Case 3, 4 | 既未付与は API 再送しない |
| Req 1.4 | 観測不要（外部観測ゼロ差分） | gate OFF / `BASE_BRANCH == default branch` で auto-close が ready-for-review を先に消すケースは、API 観測上同等。実装 diff 範囲で構造的に保証 |
| Req 1.5 | Case 5, 7 | WARN + 後続 Issue 継続 |
| Req 1.6 | 統合点（impl コード）+ Case 3 | `pp_collect_merged_issues` のループ統合 |
| Req 2.1, 2.2, 2.3, 2.4 | 新規実装なし（#221 既存契約） | 多重防御の宣言のみ |
| Req 3.1, 3.2, 3.3 | `pp_extract_linked_issues_test.sh`（既存）が境界を担保 | head パターン不一致 / fork PR / 数値 ID 検証は既存 9 ケースでカバー |
| Req 3.4 | 統合点（impl コード）で構造的に保証 | `process_promote_pipeline` が gate OFF で早期 return |
| Req 3.5 | 既存ふるまい維持 | `pp_collect_merged_issues` 自身の `gh pr list` 失敗時の早期 return は変更していない |
| Req 4.1 | Case 1, 2, 7 | 成功時ログ形式 |
| Req 4.2 | Case 4 | 既未付与のスキップ INFO ログなし選択 |
| Req 4.3 | Case 5, 7 | WARN ログ形式 |
| NFR 1.1 | 統合点（impl コード）で構造的に保証 | base = default branch では auto-close が先に ready-for-review を消すため、本実装の追加除去経路は no-op |
| NFR 1.2 | 統合点（impl コード）で構造的に保証 | gate OFF で関数到達しない |
| NFR 1.3 | 既存 env / ラベル / exit code 不変 | 新規 env var 追加なし |
| NFR 1.4 | 既存契約宣言（#221） | path-overlap 側の holder 計上不変 |
| NFR 2.1 | 統合点（impl コード）で構造的に保証 | merged PR 取得 50 件・SfR open 100 件の上限を維持 |
| NFR 2.2 | 統合点（impl コード）で構造的に保証 | 追加 `gh issue list` / `gh pr list` なし |
| NFR 3.1 | 統合点（impl コード）で構造的に保証 | `gh issue edit` 引数は `$REPO` / `$LABEL_READY` 定数 + 検証済 ID のみ |
| NFR 3.2 | Case 6 | `^[0-9]+$` 再検証 |
| NFR 4.1 | 静的検査結果（下記） | bash -n / shellcheck 警告増加 0 |
| NFR 4.2 | Case 1〜5 + 補強 Case 6, 7 | 5 必須ケースを Case 1〜5 で網羅 |

## 静的検査結果

実行コマンド:

```bash
bash -n local-watcher/bin/modules/promote-pipeline.sh
shellcheck local-watcher/bin/modules/promote-pipeline.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh
shellcheck local-watcher/test/pp_remove_ready_for_review_test.sh
bash local-watcher/test/pp_remove_ready_for_review_test.sh
bash local-watcher/test/pp_extract_linked_issues_test.sh
bash local-watcher/test/po_apply_awaiting_slot_test.sh
bash local-watcher/test/po_sticky_comment_helpers_test.sh
diff -r .claude/agents repo-template/.claude/agents
diff -r .claude/rules repo-template/.claude/rules
```

結果:

- `bash -n`: 構文エラー 0
- `shellcheck`（promote-pipeline.sh / issue-watcher.sh / install.sh / setup.sh /
  `.github/scripts/*.sh`）: 警告ゼロ（baseline 維持）
- `shellcheck` 新規テスト `pp_remove_ready_for_review_test.sh`: 警告ゼロ
- 新規テスト: PASS=23 FAIL=0
- 既存 `pp_extract_linked_issues_test.sh`: PASS=10 FAIL=0
- 既存 `po_apply_awaiting_slot_test.sh`: PASS=19 FAIL=0
- 既存 `po_sticky_comment_helpers_test.sh`: PASS=10 FAIL=0
- agents / rules sync: 差分 0（byte 一致維持）

## 補足

### `repo-template/local-watcher/` への同期

`repo-template/` 配下には `local-watcher/` が存在しない（`.claude` と `.github` のみ）。
watcher 本体は consumer repo に配置されず、運用者ホームの `~/bin/issue-watcher.sh` に
`install.sh` 経由でインストールされる設計のため、root のみが正本。本 PR では
`repo-template/local-watcher/` への複製は不要（dogfooding self-host の文脈で次回 cron
が新コードを自動的に拾う）。

## 確認事項

以下は Reviewer / 人間レビューで判断を仰ぎたい点:

1. **Open Question への解答（Req 1.6 の入力経路選択）**
   要件 Open Questions では「`gh issue list --label staged-for-release --state open` を
   入力に取り直すべきか」が問われていたが、本実装では既定どおり「`pp_extract_linked_issues`
   の和集合」を採用した。理由:
   - NFR 2.2 が追加 `gh issue list` / `gh pr list` を明示禁止しているため、追加 API
     呼び出しを避ける既定経路の方が NFR と整合する
   - 人間付与運用（#100）で `staged-for-release` を後から付与した Issue から
     `ready-for-review` を除去する必要があるかは別問題。本 Issue の原因（base !=
     default で merge 直後 ready-for-review が残る）は和集合経路で十分解消できる
   - 後から「人間付与運用での `ready-for-review` 除去も拾いたい」要求が出た場合は、
     `pp_collect_merged_issues` 末尾の `gh issue list --label staged-for-release` の
     出力に対して同じ `pp_remove_ready_for_review_if_present` を呼び増す形で拡張可能
     （既存実装を壊さない追加変更で済む）

2. **設計 PR `claude/issue-<N>-design-*` の境界（Req 3.1）**
   要件 Open Questions で「設計 PR の `ready-for-review` 除去は対象外」とした判断は
   本実装でもそのまま採用（`pp_extract_linked_issues` の head 経路が `-impl-` パターン
   限定のため構造的に除外される）。設計 PR の Issue 状態管理が別経路（design reviewer
   ゲート）にあるため、impl PR 経路のみで除去する境界が現運用と整合するかは人間
   レビューで確認したい

3. **README の `### ⚠️ merge 後の再配置が必要` 節**
   `install.sh --local` 再実行で watcher 本体を更新する手順は既存通り。本 PR の変更
   は `promote-pipeline.sh` module 1 ファイルのみで、追加ラベル / 追加 env var なし
   のため、追記は不要と判断した（既存節がそのまま該当する）

## 派生タスク候補（次 Issue 化を検討）

- 人間付与運用（#100）で `staged-for-release` を後から付与した Issue から
  `ready-for-review` を除去する必要があるかの運用判断。必要であれば確認事項 1 の
  拡張経路を別 Issue で実装する
- 設計 PR の Issue 状態管理経路（design reviewer ゲート）と impl PR 経路の責務分界
  ドキュメント整理（現在は requirements / README で個別に言及されているが、両者を
  一覧化した節は無い）

STATUS: complete
