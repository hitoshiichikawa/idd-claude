# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-400-impl-fix-pr-iteration-self-filter-pr-reviewer
- HEAD commit: 5d92d5e6dc17e79052419d80641f3cb6e7c2b1a3
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/modules/pr-iteration.sh`
  - `local-watcher/test/pi_general_filter_self_test.sh`（新規）
  - `docs/specs/400-fix-pr-iteration-self-filter-pr-reviewer/{requirements.md,impl-notes.md}`

## Verified Requirements

- 1.1 — `pi_general_filter_self` の jq 式が `contains("idd-claude:")` → `contains("idd-claude:pr-iteration")`
  に限定範囲化（`pr-iteration.sh:248`）。テスト「Req 1.1 / 2.4: PR Reviewer kind=review コメントは
  self-filter で除外されず keep」PASS で観測可能（`pi_general_filter_self_test.sh`）。
- 1.2 — `pi_general_filter_self` 通過後 `pi_general_filter_resolved` を経由しても last-run TS
  より後の reviewer コメントが残ることをテスト「Req 3.2: last-run TS より後の reviewer コメントは
  最終入力に含める」で確認（PASS）。
- 1.3 — substring `idd-claude:pr-iteration` 判定は `kind` 属性値を一切参照しない構造保証。
  `kind=review` / `kind=reply` 等の値に依存せず PR Reviewer 投稿を keep する（混在ケース
  「Req 1.4 / 4.2」PASS で観測）。
- 1.4 — 混在入力（reviewer 2 件 + pr-iteration 系 2 件 + security 1 件）で `keep=3` 件残ることを
  テスト「Req 1.4 / 4.2: 混在入力で reviewer / security は keep、pr-iteration 系のみ除外」で
  確認（PASS）。final カウンタが 0 にならない経路を観測可能。
- 2.1 — `idd-claude:pr-iteration round=N last-run=... no-progress-streak=K` marker が除外される
  ことをテスト「Req 2.1」PASS で観測。
- 2.2 — `idd-claude:pr-iteration-processing round=N` marker（着手表明）が除外されることを
  テスト「Req 2.2」PASS で観測。
- 2.3 — `idd-claude:pr-iteration-529-warning round=N` marker（quota soft-fail）が除外されることを
  テスト「Req 2.3」PASS で観測。
- 2.4 — `idd-claude:security-review` / `idd-claude:quota-reset` / `idd-claude:auto-rebase` /
  `idd-claude:review` が keep されることをテスト 4 件 + 混在 1 件 PASS で観測。jq の `contains`
  は単純 substring のため `pr-iteration` が `pr-reviewer` 等を誤包含することは構造上ない。
- 2.5 — `idd-claude:pr-iteration-foo` 形式の前方互換性をテスト「Req 2.5」PASS で観測。substring
  判定により将来のサブ種別も自動的に self として扱われる。
- 3.1 — `pi_general_filter_resolved` 未改変（`pr-iteration.sh:263-267`、`$last_run == "" or
  (.created_at // "") > $last_run` 既存式そのまま）。同時刻 / より前の reviewer コメントが
  除外されることをテスト「Req 3.1（== 同時刻 / より前）」2 件 PASS で観測。
- 3.2 — 「Req 3.2: last-run TS より後の reviewer コメントは最終入力に含める」PASS（前述）。
- 3.3 — `last_run=""`（marker 不在 = 初回 round）で全件採用されることをテスト「Req 3.3」PASS
  で観測。
- 3.4 — `pi_general_filter_resolved` の jq 式（`==` を除外側に倒す既存挙動）が改変されていない
  ことをソース直接確認（`pr-iteration.sh:265-266`）。テスト「Req 3.1: 同時刻除外」で観測も確認。
- 4.1 — `pi_collect_general_comments`（`pr-iteration.sh:322-417`）のサマリログ書式
  `PR #${pr_number} general comments: fetched=..., filtered_self=..., filtered_resolved=...,
  filtered_event=..., truncated=... (limit=${limit})?, final=...` がそのまま温存。フィールド名・順序
  共に未改変。
- 4.2 — `filtered_self=$((fetched - count_self))` の計算式（`pr-iteration.sh:402`）が未改変。
  `count_self` の意味自体は限定範囲化に追従して「Req 2 が定める self-filter で除外された件数」
  に置き換わる（要件 4.2 の定義と整合）。
- 4.3 — degraded path（fetch 失敗 / jq 整形失敗等）はすべて `echo "[]"` で空配列返却となり、
  既存の各カウンタ 0 表現を保持する（`pr-iteration.sh:331-348` 系統を未改変）。
- 4.4 — サマリログの出力先が `pi_warn` / `pi_log ... >&2` で stderr に揃っている既存契約は未改変
  （`pr-iteration.sh:410-412`）。JSON 配列の stdout 出力（`pr-iteration.sh:415`）も未改変。
- 5.1 — line-comment 経路の projection（`pr-iteration.sh:890-893`）は `contains("idd-claude:pr-iteration")`
  ベースで限定範囲。「`idd-claude:` 一律除外」は新規導入されていない。
- 5.2 — line-comment 経路の `select((.body // "") | contains("idd-claude:pr-iteration") | not)` を
  確認（`pr-iteration.sh:893`）。テスト「Req 5.2: line-comment の idd-claude:pr-iteration marker
  は除外」PASS で観測。
- 5.3 — line-comment の他 prefix marker / marker 不在 keep をテスト 2 件 PASS で観測。
- NFR 1.1 — 変更箇所は `pi_general_filter_self` 関数の jq 式 1 行と line-comment projection の
  `select` 追加のみ。env var 名 / exit code / marker prefix `<!-- idd-claude:pr-iteration ` /
  PR body 内 marker キー名（`round=` / `last-run=` / `no-progress-streak=`）は未改変
  （`pr-iteration.sh:452-458` で確認）。
- NFR 1.2 — `pi_max_rounds_kind_test.sh` 24/24 PASS、`pi_detect_quota_soft_fail_test.sh` 13/13 PASS
  を reviewer 側でも再実行確認。退行ゼロ。
- NFR 1.3 — `repo-template/local-watcher/bin/modules/` ディレクトリが存在しないことを reviewer 側で
  確認（`ls` 結果 `DIR_NOT_FOUND`）。`install.sh:1359-1360` が `local-watcher/bin/modules/` から
  `$HOME/bin/modules/` へ直接配布する単一ソース構成のため、byte 一致同期対象なし。CLAUDE.md
  「機能追加ガイドライン § 4」の byte 一致対象（`.claude/{agents,rules}` / workflow / labels）にも
  抵触しない。
- NFR 2.1 / 2.2 — `filtered_self` カウンタは `pi_collect_general_comments` でそのまま出力され
  続け（書式・stderr 出力先未改変）、Req 4 系統で観測可能。
- NFR 3.1 — `pi_general_filter_self_test.sh` 17 ケース新規追加・全 PASS を reviewer 側で再実行
  確認。要求 4 ケース（PR Reviewer keep / 自身の `-processing` `-529-warning` 除外 / last-run 後
  reviewer 含む / last-run 以前 reviewer 除外）が全てカバー済み。

## Findings

なし。

## Summary

Issue #400 の修正方針（self-filter の対象を `idd-claude:pr-iteration` prefix のみに限定）は
`pi_general_filter_self` の jq 式 1 行差し替えと line-comment projection の `select` 追加で
最小範囲かつ後方互換に実装されている。Requirement 1〜5 / NFR 1〜3 のすべての AC に対して、
新規テスト 17 ケースおよびソース直接観測で実装の存在を確認した。既存テスト
（`pi_max_rounds_kind_test.sh` 24/24、`pi_detect_quota_soft_fail_test.sh` 13/13）も退行ゼロ、
`shellcheck` 警告ゼロ。`repo-template/local-watcher/bin/modules/` は単一ソース構成のため
byte 一致同期対象外（impl-notes.md の説明と reviewer 側 `ls` 結果が一致）。境界違反なし
（tasks.md は本 fix では生成されておらず `_Boundary:_` 制約なし、変更は対象モジュールと
近接テストに限定）。

RESULT: approve
