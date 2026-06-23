# Implementation Notes — #385 fix(pr-reviewer): claude-review catch-up の parse_review_result load-order バグ

## 採用した実装アプローチ

**定義の前方移送（forward move）** を採用。理由:

- Issue 本文・要件 1.1 で「定義の前方移送を推奨」と明示されている
- 先行事例 #376（`full_auto_enabled` 前方移送）と同型の bug class であり、同一パターンで
  修正することで「Config ブロック直後に置くべき早期参照関数」という運用契約を一貫させる
- `parse_review_result` は他 9 件の caller（`stage_checkpoint_read_review_result` /
  `run_reviewer_stage` / per-task 経路の `parsed3pt` / `parsed2` 等 / `publish_claude_review_status`）
  からも参照される共通 helper であり、定義位置を最も早い call site より物理的に前へ置くことで
  すべての caller に対する load-order 保証を 1 箇所で構造的に与えられる
- 「呼び出し位置を後送」案は、catch-up call site（line 1684）が他 processor の直近に
  並んでおり順序契約（Req: catch-up は PR Reviewer 直後、Security Review 直前）が
  Issue #374 / 部分的に他 PR で確定済みなので動かしにくい

依存関数 `extract_review_result_token` も `parse_review_result` 本体内で呼ばれているため、
ペアで前方移送した（`parse_review_result` だけ前出ししても `extract_review_result_token`
未定義で動かないため必須）。元の関数本体ロジックは 1 文字も変更していない（Req 1.3 / NFR 1.3）。

## 変更ファイル一覧と主要差分の要約

- `local-watcher/bin/issue-watcher.sh`
  - `full_auto_enabled()` の直後（line 162 付近）に `extract_review_result_token()`
    （新 line 184〜204）と `parse_review_result()`（新 line 237〜272）を挿入
  - 元の定義位置（旧 line 6558〜6652）を削除し、5 行の参照コメント（`# Issue #349 / #374 / #385:
    ...` move 済み）に置換
  - 関数本体ロジックは無変更（`#385` のコメントヘッダのみ追加）
  - 配置メモコメントに `#385` の context（catch-up が `declare -F` で参照する点・silent
    skip 発生のメカニズム）を明記
- `local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh`（新規追加）
  - `parse_review_result` / `extract_review_result_token` の重複定義検出
  - 全 caller 行が定義行より後ろにあることの機械検証
  - `process_claude_review_status_catchup` の top-level call site（`^process_claude_review_status_catchup ||`）
    が定義行より後ろにあることの明示 assert
  - 参考として全 caller 棚卸し出力（Req 4.1）
  - fail 時に「定義行・caller 行・caller シンボル名」を出力（NFR 3.3）

`local-watcher/bin/modules/pr-reviewer.sh` は **無変更**。`declare -F parse_review_result`
保険ガード（line 949）と WARN ログ（line 950）は Req 3.3 に従って温存。

## 追加テストの観点と実行結果

新規テスト `pr_reviewer_parse_review_result_load_order_test.sh`:

- AC 1.1 / 1.2 / 1.5 / 5.1 を機械検証
- 参考表示として AC 4.1 の caller 棚卸し（PASS/FAIL カウントには非加算）
- regression シミュレーション（定義ブロックを catch-up call site の直後に移動）で
  `FAIL: Req 1.1: parse_review_result 定義行 (1649) が process_claude_review_status_catchup
  call site (1648) 以後` を検出することを確認（exit 1）。AC 5.2 / NFR 3.3 の出力契約を満たす。

実行結果:

```
bash local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh
PASS: 5, FAIL: 0
```

回帰確認（全テスト）:

```
TOTAL: 51, PASS: 51, FAIL: 0
```

既存 `parse_review_result_test.sh`（23 件）も含めて全 PASS。`extract_function` イディオムで
関数を抽出する既存テストは関数の物理位置に依存しないため、本 move による破壊なし。

## 静的検査結果

- `bash -n local-watcher/bin/issue-watcher.sh` → OK
- `bash -n local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh` → OK
- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh
  local-watcher/test/pr_reviewer_parse_review_result_load_order_test.sh` → 警告 0
  （`.shellcheckrc` の baseline 抑止下で増加 0 / NFR 2.1, 2.2）
- `diff -r .claude/agents repo-template/.claude/agents` → 空（同期維持）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（同期維持）

## root ↔ repo-template 同期の判断

`repo-template/` には `local-watcher/` 配下が存在しない（`ls repo-template/` の結果は
`CLAUDE.md` のみ）。`install.sh` は idd-claude clone 直下の `local-watcher/bin/` から
直接 `$HOME/bin/` へコピーする実装（`install.sh:53` `LOCAL_WATCHER_DIR="$SCRIPT_DIR/local-watcher"`）
のため、`repo-template/` 配下に watcher / 近接テストを置く慣習はなく、本修正で同期対象は
発生しない（Req 7.1 / NFR 1.1）。`.claude/{agents,rules}` も無変更のため byte 一致を維持。

## README 反映要否の判断と根拠

**反映不要**と判断。根拠:

- 本修正は内部 load-order bug の修正であり、外部 API（env var / ラベル / exit code / cron
  登録文字列 / ログ出力先 / commit status 名・state 解決）は一切変更していない（Req 6.3 / 6.4）
- 既定動作（AND 二重 opt-in 無効環境）の外部観測挙動は move 前後で完全一致（NFR 1.1）
- AND 二重 opt-in 有効環境では「永久 skip → catch-up が想定通り動く」という挙動の修正だが、
  これは「壊れていた機能が直る」修正であり、README に記載された前向き仕様の変更ではない
- 要件 7.2 「README の該当箇所と整合した状態」については、現状 README に
  `parse_review_result` の load order に関する記述は無く、本修正により記述追加が必要な
  項目は発生しない（catch-up 機能自体の README 説明は #374 / #380 で確立済み）

## 確認事項

なし。要件 / 既存実装 / 先行事例 #376 の修正パターンから判断が一意に決まり、独自解釈が
必要な箇所はなかった。

## AC Traceability

| AC | 検証方法 |
|----|----------|
| 1.1 | 新規テスト「定義行 ($PARSE_DEF_LINE=237) < catch-up call site ($CATCHUP_CALL_LINE=1684)」assert |
| 1.2 | 新規テスト「重複定義検出（count==1）」assert（旧位置の削除を機械検証） |
| 1.3 | 関数本体無変更 / 既存 `parse_review_result_test.sh` 全 23 件 PASS（rc 規約・TSV 形式維持） |
| 1.4 | catch-up 経路 `declare -F parse_review_result` が真評価となることを load-order assert で間接検証 |
| 1.5 | 新規テスト「全 9 caller が定義行より後ろ」assert |
| 2.1〜2.4 | `parse_review_result` を解決できるようになったことが前提条件。catch-up 本体の挙動は #374 / #380 で実装済みで本修正で無変更 |
| 3.1〜3.4 | `pr-reviewer.sh` 内の safe-skip ガード（`declare -F` / parse-failed / git-show-failed）を無変更で温存 |
| 4.1 | 新規テストの caller 棚卸し出力で全 caller を一覧化 |
| 4.2 | 本 PR スコープ外の前方参照は別 Issue 化（本修正では `parse_review_result` のみを移動） |
| 4.3 | `full_auto_enabled` の line 156 配置を破壊しないことを `bash -n` / 既存 `full_auto_enabled_load_order_test.sh` PASS で確認 |
| 5.1〜5.4 | `pr_reviewer_parse_review_result_load_order_test.sh` を新規追加（既存テストランナと同一イディオム） |
| 6.1〜6.4 | env var 名・kill switch 評価規則・関数シグネチャ・top-level 副作用すべて無変更 |
| 7.1〜7.3 | `install.sh` が `local-watcher/bin/issue-watcher.sh` を直接配布する既存挙動を維持 |
| NFR 1.1〜1.3 | 外部観測挙動・cron 最小 PATH 依存・他 caller 経路すべて無変更 |
| NFR 2.1, 2.2 | `bash -n` / `shellcheck` 警告 0 を確認 |
| NFR 3.1〜3.3 | catch-up publish 成功時の `pr_log`（#374）・skip WARN 経路（無変更）・回帰テスト出力に定義行＋call site 行を含む形式を確認 |

STATUS: complete
