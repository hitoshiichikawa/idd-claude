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

### Task 5

- 採用方針: `modules/failed-recovery.sh` に Recovery Decision Layer（`fr_compute_failure_signature` / `fr_detect_no_progress`）と Context Collection / Recovery Execution Layer（`fr_collect_issue_context` / `fr_collect_pr_ci_context` / `fr_invoke_claude`）の 5 関数を追加。design.md 行 406-518 のサンプルに沿った形を踏襲しつつ、test 容易性と fail-continue 規約を優先した。
- 重要な判断:
  - **bash の `${var:-default}` 展開で `default` 内に `{}` を含めると壊れる**: `local prev_state_json="${3:-{}}"` のような書き方では引数あり時に末尾 `}` がリテラル残留する（再現: `bash -c 'foo() { local x="${1:-{}}"; printf "[%s]\n" "$x"; }; foo abc' → [abc}]`）。`fr_detect_no_progress` では引数省略時の `{}` 既定を明示的な空チェック分岐で実装した（task 5.1 のテスト Section 2 が一致比較失敗していたのを発見して修正）。本イディオムは bash の brace expansion / parameter expansion の境界曖昧さに由来する既知の罠で、jq 系の default 値を `${var:-{}}` で書く既存箇所があれば同様の修正が必要。
  - **`fr_invoke_claude` は quota-aware.sh の `qa_run_claude_stage` を使わず独自 wrapper**: 設計判断 (1) `qa_run_claude_stage` は `QUOTA_AWARE_ENABLED=false` 時に素通し実行する gate を持つが、Failed Recovery は claude-failed 復旧の核なので quota 検出のみは常時必要、(2) test 容易性（stub 配下で wrapper の挙動を直接観測できる）。共通化は `qa_detect_rate_limit` の再利用のみに留めた。tee + qa_detect_rate_limit + PIPESTATUS[0] による pipefail 起因の即時 exit 抑止は quota-aware の同型ロジックを忠実に踏襲（Issue #104 の latent bug 修正パターン）。
  - **fr_invoke_claude のテスト隔離 — subshell `( fn ) || rc=$?` パターン**: 当該 wrapper は内部で `set +e/-e` を行うため、caller test スクリプトの `set -euo pipefail` モードに干渉する（fr_invoke_claude が `return 99` した瞬間に caller の set -e で trap され test 全体が exit 99 で死ぬ）。test ファイル冒頭で `set +e; fn; rc=$?; set -e` の従来パターンは効かず、subshell `( fn ) || rc=$?` で隔離する必要がある（`||` の condition 内では set -e が抑止される bash 仕様を利用）。本パターンは fr_invoke_test.sh Section 7/8/9 で実証済み。後続 task でも `set -e` を内部 toggle する関数を test する場合は本パターンを参照。
  - **fr_collect_pr_ci_context の run id 抽出 — detailsUrl regex で AC 引き当て**: design.md は「detailsUrl から run-id を抽出」と明示しているが、具体的な regex は未指定。GitHub Actions の URL 形式 `https://github.com/owner/repo/actions/runs/<id>` から `actions/runs/([0-9]+)` で抽出し、抽出結果を `^[0-9]+$` で再検証する 2 段ガードを採用（NFR 3.1 の数値 ID 検証規約）。url 末尾の `/job/<job-id>` セグメントには対応せず、run 全体の `--log-failed` を取得する形にした（context 長は 200 行 cap で制御）。
  - **未信頼値の jq filter 内完結**: `fr_collect_issue_context` の context 組み立てで、`gh issue view` の戻り値 JSON に含まれる title / body / コメント本文をすべて jq filter 内（`(.title // "") + ...`）で完結させた。bash 側に `body=$(jq -r ...)` で受け取って `printf "Body: $body"` のように展開すると未信頼値が一旦 shell 変数を経由するため、本機能では一切 inline 展開せず jq filter 内で string concat する形にした（NFR 3.1 の徹底）。
  - **deferrable な spec dir 集約は省略**: task 5.2 詳細項目「`git show` 経由で spec dir 配下を集約」は best-effort 指示。Issue 番号から spec slug を推定するロジック（`docs/specs/<N>-*/` の glob 等）は実装が膨らむため本 task では省略し、後続 task 6（orchestrator）で prompt 組み立て時に必要なら追加実装する設計とした。本判断は impl-notes 確認事項に明記して Architect レビューを仰ぐ。
  - **test での `assert_grep` 引数渡し**: `assert_grep "label" -- "pattern" "$file"` で第 2 引数に `--` を渡すと、関数定義が `$1=label / $2=pattern / $3=file` の 3 引数のため引数ズレが発生する（既存 fr_fetch_test.sh の Task 4 learning と同じ罠）。`--max-turns 20` のような `-` 始まり pattern を grep で扱う場合は、`--` を関数呼出側で渡さず、関数内部の `grep -qE -- "$pattern" "$file"` が `-` 始まり pattern を安全に処理する既存実装を信頼する。本 task では pattern を `"max-turns 20"`（先頭 `-` を除去）に書き換えて回避した。
- 残存課題:
  - **spec dir 集約は未実装**: 上記の通り task 5.2 内の best-effort 指示を後続 task に deferred した（確認事項を参照）。orchestrator から呼ぶ際に `docs/specs/<N>-*/` glob で spec dir を特定して `git show HEAD:<spec>/requirements.md` 等を集約する流れが必要になる可能性がある。
  - 本 task の 5 関数は orchestrator（task 6）から呼ばれて初めて統合動作する。task 6 では `fr_should_recover` → `fr_compute_failure_signature` → `fr_detect_no_progress` → `fr_collect_*_context` → `fr_invoke_claude` のフロー組み立てが必要。

## 確認事項

- design.md の Logger Layer サンプル（`fr_log() { echo "[$(date '+%F %T')] failed-recovery: $*"; }`）には `[$REPO]` segment が無いが、tasks.md は「既存 `pi_log` / `pr_log` と同パターン」と明示しており、core_utils.sh の既存 logger（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` / `sec_log`）はすべて Issue #119 以降 `[$REPO]` を含む 3 段 prefix で統一されている。実装は tasks.md の「同パターン」指示 + 既存実装慣習に従って `[$REPO]` 含みで追加した。design.md サンプルは簡略表記と解釈したが、Architect 側で意図相違があれば指摘いただきたい（NFR 4.1「`failed-recovery:` prefix と Issue/PR 番号でログ抽出可能」は本実装で充足）。
- **Task 5.2: spec dir 配下集約の deferred**: design.md 行 485-487 / tasks.md 5.2 詳細項目に「`git show` 経由で spec dir 配下を集約」とあるが、Issue 番号から spec slug（`docs/specs/<N>-<slug>/`）を推定するロジック（git ls-tree で `^docs/specs/<N>-` プレフィックスの dir を探す等）が必要となり実装が膨らむ。本 task では `fr_collect_issue_context` で title / labels / body / 末尾 5 件コメント収集に留め、spec dir 集約は **後続 task 6（orchestrator）の prompt 組み立て時に追加実装する**設計とした。task 6 で必要に応じて `fr_collect_spec_dir <issue_number>` のような helper を追加するか、`fr_collect_issue_context` に統合するかは task 6 で判断する。本 deferred が AC（Req 3.1）の充足に影響する可能性があれば、Architect から指摘いただきたい（現状の Issue context 集約だけでも claude-failed の hint 抽出は十分機能する想定）。
