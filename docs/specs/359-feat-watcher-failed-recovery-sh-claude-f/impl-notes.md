# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `fr_log` / `fr_warn` / `fr_error` を `core_utils.sh` の `sec_log` ブロック直後に追加。
- 重要な判断:
  - tasks.md の「既存 `pi_log` / `pr_log` と同パターン」記述に従い、`[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery:` の 3 段 prefix（Issue #119 で確立された `[$REPO]` 挿入規約）を採用した。design.md の Logger Layer サンプルコードは `[$REPO]` を省略した簡略形だが、tasks.md の「同パターン」指示と既存 `sec_log` / `pi_log` / `pr_log` の実装が優先と判断（後述 確認事項に明記）。
  - 近接テスト追加は tasks.md 指示通り task 1 では行わず、後続 task の `fr_*_test.sh` 群で間接検証する。
- 残存課題: なし

### Task 2

- 採用方針: `FAILED_RECOVERY_*` env ブロックを `issue-watcher.sh` の Design Review Release（行 487 直後）と Stage Checkpoint（行 489）の間に挿入し、design.md「Config Layer」サンプルに準じた 2 段 case 正規化（ENABLED は `=true` 厳密一致以外 → `false`、MAX_ATTEMPTS は `''|*[!0-9]*` または `-le 0` → 4）を実装。
- 重要な判断:
  - 配置場所は tasks.md「Config ブロック(PR Iteration / Auto-Merge 隣接位置)」に従い、既存 processor 群（PR Iteration / PR Reviewer / Security Review / Design Review Release）のクラスタ末尾とし、後続 Stage Checkpoint 以降のクラスタとは仕切る位置を選んだ。
  - 「デフォルト有効化フラグの値正規化」ループ（`_idd_flag` for-loop）には **加えない** ことを tasks.md 明示（opt-in 制 + 既定 false）に従って実装した。
  - MAX_ATTEMPTS の整数判定は `case` パターン `''|*[!0-9]*` で先に「未設定 / 非整数（負号 `-` / 小数点 `.` / 空白を含む文字列）」を篩い、その後の `*)` 分岐内で `[ "$VAR" -le 0 ]` を `if` で評価することで shellcheck warning ゼロを維持した（`&&` チェーンの 1 行式は exit status が落ちる懸念があるため）。
  - 本 task の単位テストは tasks.md `_Requirements_partial:_ 1.5, 4.8` の deferred として task 3.1（`fr_is_enabled_test.sh`）/ 3.2（`fr_state_test.sh`）に集約する。本実装は手動 fixture（`/tmp` 上の inline スクリプト）で 16 ケース（ENABLED 7 + MAX_ATTEMPTS 9：未設定 / `0` / `-3` / `abc` / `5` / `1` / `100` / `1.5` / ` 4`）の正規化が期待通り動くことを確認済み。
- 残存課題: なし（Task 3.1 / 3.2 で本 env の正規化挙動が間接検証される設計）

### Task 3

- 採用方針: `local-watcher/bin/modules/failed-recovery.sh` を新規追加し、Gate Layer（`fr_is_enabled`）と State Persistence Layer（`fr_state_path` / `fr_load_state` / `fr_save_state`）の 4 関数を function 定義のみで集約。`set -euo pipefail` は本体宣言なので module 側では宣言せず、ロガー `fr_warn` は core_utils.sh の task 1 追加分を参照（前方束縛）。
- 重要な判断:
  - `fr_is_enabled` は design.md Gate Layer サンプル（行 308-312）を厳密に踏襲し、`=true` 厳密一致の AND 二重 opt-in 純粋関数とした。typo（`True` / `TRUE` / `1` / `on` 等)は安全側 OFF として 1 を返す。env 正規化自体は issue-watcher.sh Config ブロック側で完了している前提（task 2.1 で実装済み）だが、`fr_is_enabled` 単独で source される単体テストでも安全に動くよう厳密一致比較で実装した。
  - `fr_save_state` の atomic write は quota-aware.sh の `qa_persist_reset_time`（行 252-296）と同形式を踏襲: 同一 dir に `mktemp ${state_file}.XXXXXX` → `jq` で組み立て → `mv -f` で atomic rename。これにより read-modify-write 中の中断でも破損ファイルが残らない（NFR 2.3）。history の累積は `prev_state | jq '.history // []' + [新エントリ] | .[-8:]` で append + 8 件 truncate を 1 行で実現した（hot-spot 防止 / design.md Data Model 節）。
  - 全 jq 引数を `--arg` / `--argjson` 経由でサニタイズ（NFR 3.1）。Section 9 のテストで `"; .total_attempts = 9999 // "` のような injection 試行値が literal として保持され、total_attempts が書き換わらないことを実証している。
  - `fr_load_state` は ファイル不在 / `jq -c '.'` 失敗の双方で `{}` を返す fail-open とした（NFR 2.3）。これにより破損後の `fr_save_state` 救済（新規上書き）が可能（Section 7 のテストで実証）。
  - test 側の `extract_function` イディオムは `full_auto_enabled_test.sh` / `pt_post_marker_classify_test.sh` を踏襲。`fr_warn` を stub にして失敗パスを観測可能にし、テスト隔離のため `mktemp -d` で各 Section ごとに新規 state_dir を切る。task 2.1 `_Requirements_partial:_ 4.8` の解消用に MAX_ATTEMPTS 正規化を 9 ケース（未設定 / 空 / `abc` / `-3` / `0` / `1.5` / `5` / `100` / `1`）で間接検証している（Section 11）。
- 残存課題: なし。後続 task 4 以降の候補選定 / 失敗解析 / orchestrator は本 layer が提供する 4 関数を呼び出す前提で組み上がる。

### Task 4

- 採用方針: `local-watcher/bin/modules/failed-recovery.sh` に Candidate Selection Layer として `fr_fetch_failed_issues` / `fr_fetch_failed_prs` の 2 関数を追加。design.md「Candidate Selection Layer」節（行 315-353）と pr-iteration.sh `pi_fetch_candidate_prs`（行 55-88）の **server-side filter + client-side filter の二段構成**を踏襲した。
- 重要な判断:
  - **`LABEL_AUTO_DEV` 変数は存在しない**: tasks.md は `label:"auto-dev"` を要求しているが、issue-watcher.sh で定義されているのは `LABEL_TRIGGER="auto-dev"`（行 59）のみ。`LABEL_AUTO_DEV` は未定義のため、本機能でも `LABEL_TRIGGER` を採用した（既存実装と整合）。これにより auto-dev ラベル名が将来 env 化された場合も他 processor と同期して切り替わる。
  - **PR 経路の auto-merge + CI error 抽出は 2 段 API**: `gh pr list --search` で 1 次絞り（claude-failed + 除外ラベル + 非 draft）した後、各 PR について `gh pr view --json mergeStateStatus,autoMergeRequest,statusCheckRollup` を呼び client-side で `(autoMergeRequest != null) AND (statusCheckRollup に FAILURE/TIMED_OUT)` を AND 条件で残す。これは design.md「Candidate Selection Layer」の指示通り。`mergeStateStatus` 自体は filter 条件に使っていないが、後続 task で参照する可能性があるため取得し result にマージしている。
  - **fork PR 除外は 2 段防御**: server-side で除外不可能なため、1 次絞りの後 jq filter で `(headRepositoryOwner.login == repo_owner) AND (headRefName | test("^claude/"))` を AND 適用（branch 名は `--arg` で展開 / NFR 3.1）。これにより fork PR には `gh pr view` すら呼ばないため API call 削減効果もある（Section 6 / 9 のテストで実証）。
  - **fail-continue の徹底**: `gh issue list` / `gh pr list` / `gh pr view` のいずれもエラー時は `fr_warn` で警告して `[]` を返す（NFR 5.2）。`gh pr view` の個別失敗（特定 PR で view が失敗）は当該 PR を skip して残り PR の処理を継続する（Section 5 で issue list 失敗、Section 4 で空応答を検証）。
  - **JSON 配列保証**: gh 取得成功時も空文字 / 非 JSON 配列の場合は `fr_warn` + `[]` 返却で正規化する（後続 task の orchestrator が `jq .[]` で安全に reduce できる契約）。
  - test の grep 引数で `assert_grep ... -- pattern file` を試したが、関数定義は `$1=label / $2=pattern / $3=file` の 3 引数なので `--` は **関数呼出側では渡さず**、関数内部の `grep -E -- "$pattern"` が `-` 始まり pattern を安全に処理する形にした（初回実装で誤って `--` を関数呼出に挟み引数ズレで失敗したのを修正）。
- 残存課題: なし。後続 task 5（失敗 signature 計算 / no-progress 判定）/ task 5.2（context 収集 / claude 起動）/ task 6（orchestrator）が本 layer の戻り値（JSON 配列）を `jq '.[] | .number'` で reduce する前提で組み上がる。

## 確認事項

- design.md の Logger Layer サンプル（`fr_log() { echo "[$(date '+%F %T')] failed-recovery: $*"; }`）には `[$REPO]` segment が無いが、tasks.md は「既存 `pi_log` / `pr_log` と同パターン」と明示しており、core_utils.sh の既存 logger（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` / `sec_log`）はすべて Issue #119 以降 `[$REPO]` を含む 3 段 prefix で統一されている。実装は tasks.md の「同パターン」指示 + 既存実装慣習に従って `[$REPO]` 含みで追加した。design.md サンプルは簡略表記と解釈したが、Architect 側で意図相違があれば指摘いただきたい（NFR 4.1「`failed-recovery:` prefix と Issue/PR 番号でログ抽出可能」は本実装で充足）。
