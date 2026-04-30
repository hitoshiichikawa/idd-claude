# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-30T02:10:00Z -->

## Reviewed Scope

- Branch: claude/issue-63-impl-refactor-watcher-reviewer-parse-failed-c
- HEAD commit: d6e9b76662cfc08b9ed05c41350ba81c89687e38
- Compared to: origin/main..HEAD
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しないため opt-out 解釈（impl-notes.md と一致）。flag 観点の追加チェックは行わず、通常 3 カテゴリ判定のみ。
- tasks.md / design.md は本 spec に存在せず（Architect 不要規模の小〜中 refactor）。boundary は requirements.md の Out of Scope と impl-notes.md の変更ファイル一覧、および「Reviewer Result Parser コンポーネント + Reviewer agent definition + 関連ドキュメント」というスコープを基準に判定。

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh:2756` の `extract_review_result_token` で `grep -oE 'RESULT:[[:space:]]+(approve|reject)([^[:alnum:]_]|$)'` により全文 scan + 装飾許容。fixture `inline-approve-backticks.txt` / `decorated-bullet-approve.txt` で approve 抽出 PASS（19/19）
- 1.2 — 同関数で reject も装飾許容。fixture `inline-reject-backticks.txt` / `blockquote-reject.txt` で reject 抽出 PASS
- 1.3 — `tail -n 1` でファイル順最後のマッチを採用（`local-watcher/bin/issue-watcher.sh:2768`）。fixture `multi-last-wins-approve.txt`（reject→approve→approve 採用）/ `multi-last-wins-reject.txt`（approve→reject→reject 採用）で PASS
- 1.4 — 緩和パーサが末尾独立行も同じトークンとして検出。fixture `tail-approve.txt` / `tail-reject.txt`（Issue #20 由来の歴史的形式）で同決定 PASS（backward compat）
- 1.5 — `extract_review_result_token` 冒頭の `[ -f "$path" ] || return 1`（`local-watcher/bin/issue-watcher.sh:2757`）と `parse_review_result` 冒頭の `[ ! -f "$path" ]` ガードで rc=2 を維持。`__no_such_file__.txt` テストで extract rc=1 / parse rc=2 PASS
- 1.6 — `[ -n "$matches" ] || return 1`（`local-watcher/bin/issue-watcher.sh:2767`）で RESULT トークン皆無時 extract rc=1、parse は rc=2 に伝播。`no-result.txt` で PASS
- 1.7 — 正規表現が `(approve|reject)` lowercase 固定で `Approve` / `APPROVE` は構造的に不採用。`uppercase-no-match.txt` で extract rc=1 PASS
- 2.1 — `parse_review_result` の Findings Category / Target 抽出ロジックは無変更（diff は RESULT 抽出部分のみ）。`reject-with-findings.txt` で TSV `reject\tAC 未カバー,boundary 逸脱\t1.1,boundary:Watcher` PASS、`tail-reject.txt` でも同 TSV PASS
- 2.2 — approve 時の categories / targets 空（`if result == reject` 分岐外）。`tail-approve.txt` / `inline-approve-backticks.txt` で TSV `approve\t\t` PASS
- 3.1 — `.claude/agents/reviewer.md` の「RESULT 行の規律（Issue #63 強化）」節（追加 +60 行）で「最終行（standalone line）に 1 行だけ」を明文化
- 3.2 — 同節でバッククォート / bullet (`-` `*`) / blockquote (`>`) / 引用符 / 行末プローズの 5 個別禁止項目を列挙
- 3.3 — OK 例 2 件（all green / boundary 逸脱）+ NG 例 5 件（インライン+バッククォート（Issue #52 事故再現）/ bullet / blockquote / 行末プローズ / 大文字混入）を追加
- 3.4 — `.claude/agents/reviewer.md` と `repo-template/.claude/agents/reviewer.md` を `diff` で比較した結果 IDENTICAL（template 同期確認）
- 4.1 — diff 上で env var 追加なし（`extract_review_result_token` 内のローカル変数 `path` / `matches` / `last` のみ、`run_reviewer_stage` の局所変数 `_prev_token` のみ）
- 4.2 — ラベル遷移ロジック（`mark_issue_failed` 等）は無変更（`git diff origin/main..HEAD` の対象範囲外）
- 4.3 — `parse_review_result` の rc=0/2 セマンティクスを維持（`return 2` 経路は ファイル無 / token 欠落 / 値不正 のいずれも従来同様）。`rv_log "round=$round result=..."` の log 行も無変更（issue-watcher.sh:2911 / 2915 周辺）
- 4.4 — 既存形式 fixture（`tail-approve.txt` / `tail-reject.txt`）で同決定（approve / reject + Findings TSV）PASS
- 5.1 — `README.md:1783-1793` の「Reviewer の出力契約」節に緩和パーサの 5 項目（全文 scan / 装飾許容 / last wins / lowercase only / parse-failed 条件）を追記
- 5.2 — `README.md:1796-1798` 付近で「緩和パーサは安全網であり deviation を許可するものではない」「canonical 形式（最終行 standalone, 装飾なし）を引き続き守る」旨を明記
- 5.3 — README から `repo-template/.claude/agents/reviewer.md` の「RESULT 行の規律」節への相対リンクを追加（`README.md:1799`）
- NFR 1.1 — Issue #52 再現相当の `inline-approve-backticks.txt`（バッククォート付き approve をプローズ中にインライン記述）で approve 検証 PASS
- NFR 1.2 — `inline-reject-backticks.txt` で reject 検証 PASS
- NFR 1.3 — `tail-approve.txt` / `tail-reject.txt` で歴史的「最終行 standalone」形式の同決定検証 PASS
- NFR 1.4 — `no-result.txt` で parse-failure (rc=2) PASS
- NFR 2.1 — レビュワー側で `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/parse_review_result_test.sh` 実行: 既存の SC2317×8 / SC2012×2（info-level、本 PR 範囲外の `quota-aware`/`merge-queue-recheck`/`design-review-release`/`stage-checkpoint`/`slot-?` ロガー等）のみ。新規追加した `extract_review_result_token` および `parse_review_result_test.sh` は警告ゼロ。pre-change baseline 比で新規警告なし
- NFR 3.1 — `rv_log "round=$round result=approve|reject ..."` の呼び出しは diff 上で無変更
- NFR 3.2 — `rv_log "round=$round result=error reason=parse-failed"` の呼び出しも diff 上で無変更（`parse_review_result` rc=2 経路は従来どおり parse-failed log を発火）

## Boundary 検証

- 変更ファイル 18 件（`git diff --name-only origin/main..HEAD`）はすべて requirements.md の対象範囲内:
  - Reviewer Result Parser 本体: `local-watcher/bin/issue-watcher.sh`
  - Reviewer agent definition（root + template の 2 箇所、Req 3.4 で同期義務）: `.claude/agents/reviewer.md` / `repo-template/.claude/agents/reviewer.md`
  - ドキュメント: `README.md`
  - スペック: `docs/specs/63-*/{requirements,impl-notes}.md`
  - テスト fixture / runner: `local-watcher/test/fixtures/parse_review_result/*` / `local-watcher/test/parse_review_result_test.sh`
- Out of Scope（Reviewer Gate 起動条件 / Developer / PjM / Triage parser / 自動 retry / 新規ラベル / 過去 claude-failed の遡及対応 / Findings 構造変更）への変更は無し
- 既存ラベル契約・cron 登録文字列・env var 名はいずれも未改変（Req 4.1, 4.2 と整合）

## Findings

なし

## Summary

Issue #52 事故の根本原因に対する 2 層防御（parser 緩和 + Reviewer prompt 強化）が、要件定義の全 numeric AC（Req 1〜5、NFR 1〜3）を満たして実装されている。fixture スモーク 19/19 PASS、shellcheck 新規警告ゼロ、`parse_review_result` の API（TSV 出力 / rc 0/2 セマンティクス）と watcher のラベル / log 契約を完全に維持。AC 未カバー / missing test / boundary 逸脱のいずれも検出されない。

RESULT: approve
