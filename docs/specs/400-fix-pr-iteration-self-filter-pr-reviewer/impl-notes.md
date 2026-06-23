# Implementation Notes — Issue #400

## 概要

`local-watcher/bin/modules/pr-iteration.sh` の self-filter（`pi_general_filter_self` および
line-comment 経路）を、`idd-claude:` を含む全コメント一律除外から
**`idd-claude:pr-iteration` を含むコメントのみ除外** に限定範囲化した。これにより
PR Reviewer (`idd-claude:pr-reviewer`) / security-review / quota-reset / auto-rebase 等
他系統の自動投稿が iteration agent の入力に正しく渡るようになる。

## 変更ファイル

- `local-watcher/bin/modules/pr-iteration.sh`
  - `pi_general_filter_self`: `contains("idd-claude:")` → `contains("idd-claude:pr-iteration")`
  - line-comment 経路（`pi_build_iteration_prompt` 内の reviews 取得直後 jq projection）:
    同じ `contains("idd-claude:pr-iteration")` ベースの `select(... | not)` を projection と
    同時に適用（Req 5.2）。Req 5.1 の通り「`idd-claude:` 含む文字列一律除外」は導入しない。
- `local-watcher/test/pi_general_filter_self_test.sh`（新規）
  - `extract_function` で `pi_general_filter_self` / `pi_general_filter_resolved` を抽出して
    fixture ベースで検証。17 ケース全 PASS。

## repo-template 同期について

`repo-template/local-watcher/bin/modules/` ディレクトリは **存在しない**（grep 結果で確認）。
CLAUDE.md の二重管理規約は `.claude/{agents,rules}/` のみが byte 一致対象であり、
`local-watcher/bin/modules/*.sh` は `install.sh` が `local-watcher/bin/modules/` から
直接 `$HOME/bin/modules/` に配布する単一ソース構成（issue-watcher.sh 行 1359-1360 のコメント
で明示）。よって本 Issue の修正に「repo-template 側同期」は適用外。

## AC Traceability

| Req | 検証手段 |
|---|---|
| 1.1 PR Reviewer marker を self-filter で除外しない | `pi_general_filter_self_test.sh` Req 1.1 / 2.4 / 1.4 ケース |
| 1.2 last-run TS より後の reviewer は agent 入力に含める | Req 3.2 ケース |
| 1.3 kind 属性値に依存せず PR Reviewer 投稿を含める | substring 判定で kind 不参照を構造的に保証、Req 1.1 / 1.4 ケースで観測 |
| 1.4 final カウンタ 0 にならない | Req 1.4 混在ケースで keep=3 件を観測 |
| 2.1 `idd-claude:pr-iteration` で始まる marker を除外 | Req 2.1 ケース |
| 2.2 `idd-claude:pr-iteration-processing` 除外 | Req 2.2 ケース |
| 2.3 `idd-claude:pr-iteration-529-warning` 除外 | Req 2.3 ケース |
| 2.4 他 prefix を除外しない（reviewer/security/quota-reset/auto-rebase/review 等） | Req 2.4 ケース 5 件（security-review / quota-reset / auto-rebase / review / 混在） |
| 2.5 `idd-claude:pr-iteration-<suffix>` 形式の前方互換 | Req 2.5 ケース（`-foo` サフィックス） |
| 3.1 last-run TS 以前（同時刻含む）は除外 | Req 3.1 ケース 2 件 |
| 3.2 last-run TS より後は agent 入力に含める | Req 3.2 ケース |
| 3.3 marker 不在（初回 round）は全件採用 | Req 3.3 ケース |
| 3.4 last-run 比較境界（`==` 除外側）を変更しない | `pi_general_filter_resolved` 未改変（`$last_run == "" or (.created_at // "") > $last_run`） |
| 4.1〜4.4 サマリログ後方互換 | `pi_collect_general_comments` のログ書式・カウンタ計算式・stderr 出力先を改変しない（修正は filter 1 関数のみ） |
| 5.1 line-comment に `idd-claude:` 一律除外は導入しない | 実装上 substring `idd-claude:pr-iteration` のみ判定、line_filter テストでも reviewer marker / 通常 line keep を確認 |
| 5.2 line-comment の `idd-claude:pr-iteration` marker は除外 | line-comment Req 5.2 ケース |
| 5.3 line-comment の他 prefix / marker 不在は keep | line-comment Req 5.3 ケース 2 件 |
| NFR 1.1 env / exit code / marker prefix キー名不変 | filter 内部の jq 式 1 行のみ変更、外部契約は同じ |
| NFR 1.2 既存テスト退行ゼロ | `pi_max_rounds_kind_test.sh` 24/24 PASS、`pi_detect_quota_soft_fail_test.sh` 13/13 PASS |
| NFR 2.1 / 2.2 filtered_self カウンタの観測性 | `pi_collect_general_comments` の `filtered_self=$((fetched - count_self))` は未変更、カウンタ意味は限定範囲化に追従して更新 |
| NFR 3.1 近接テスト追加 | `pi_general_filter_self_test.sh` 17 ケース |

## テスト結果サマリ

- `bash local-watcher/test/pi_general_filter_self_test.sh`: 17/17 PASS
- `bash local-watcher/test/pi_max_rounds_kind_test.sh`: 24/24 PASS (既存退行なし)
- `bash local-watcher/test/pi_detect_quota_soft_fail_test.sh`: 13/13 PASS (既存退行なし)
- `bash -n local-watcher/bin/modules/pr-iteration.sh`: OK
- `shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_general_filter_self_test.sh`: 警告ゼロ

## 設計判断

- **substring match vs 正規表現 prefix match**: `idd-claude:pr-iteration` の substring 判定で
  Req 2.1〜2.3（`<空白>` / `-processing` / `-529-warning`）と Req 2.5（`-<suffix>` 前方互換）を
  同時に満たせる。`pr-iteration` と他 prefix（`pr-reviewer`）は文字列としても包含関係に無いため
  `pr-iteration` substring が `pr-reviewer` を誤マッチすることはない（jq の `contains` は
  単純 substring）。シンプルさを優先して `test()` ベースの regex 前方一致は採用しなかった。
- **line-comment 経路の projection 同時適用**: line_comments_json は 1 箇所でしか作られない
  ため、projection 直後に `select(... | not)` を同じ jq 式内で繋いで二重パス（filter 関数化）
  を避けた。一般コメント経路は既に `pi_general_filter_self` 関数として分離されているため
  単独で扱える（テスト容易性も維持）。

## 確認事項

- なし。要件は Issue 本文と requirements.md で完結しており、design.md / tasks.md は本 Issue
  では生成されていない（軽量 fix のため triage で needs_architect=false 想定）。

STATUS: complete
