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

### Task 6

- 採用方針: `modules/failed-recovery.sh` に Orchestrator Layer として 4 関数（`fr_should_recover` / `fr_post_attempt_comment` / `fr_finalize_success` / `fr_run_recovery_attempt`）を追加。design.md 行 405-558（Recovery Decision / Recovery Execution / Termination の各 Layer の orchestrator 部）と requirements.md の Req 3.x / 4.2 / 4.3 / 4.4 / 6.1 / 6.2 を統合したフローを忠実に組み上げた。terminate 関数（task 7）は本 task では未追加のため、上限到達時は return 2 / no-progress 時は return 3 で stub し、caller が後続 task で terminate 経路に接続できるよう設計した。
- 重要な判断:
  - **試行開始時に attempt++ を確定（Req 4.2 / quota 燃焼上界保証）**: claude session 起動の **前** に `fr_save_state(new_total, "in-progress")` を呼ぶ実装を採用した。これにより claude が exit する前に cron が中断しても、次サイクルで `total_attempts=new_total` から resume できる（attempt の二重消費を防ぐ）。test Section 2 で `fr_save_state` が 2 件（開始時 in-progress + finalize 時 succeeded）呼ばれる順序を call trace で検証している。
  - **claude の返り値分岐は 3 通り（0/99/N!=0,99）**: design.md 行 526-538 と requirements.md Req 3.x を統合し、claude rc=0 → 結果コメント + `fr_finalize_success` → return 0、rc=99 → quota 結果コメント + state in-progress 維持 → return 99（caller は次サイクル待ち / quota-aware と同じ sentinel 契約）、rc!=0,99 → 失敗結果コメント + state in-progress 維持 → return 1（次サイクル再試行）とした。これにより quota 燃焼回避と attempt 加算済みの再開可能性を両立できる。
  - **D-19b の独立カウンタ規約を物理的に守る**: Reviewer の per-task review-notes.md や pr-iteration の PR body marker（`idd-claude:pr-iteration round=N`）を読まないことを契約として実装し、test Section 6 で trace 全体に `pr-iteration round=` / `review-notes` / `idd-claude:pr-iteration` / `--json body` の文字列が出現しないことを assertion で固定した。`gh pr view` の用途は `--json headRefOid` の head_sha 取得のみで、PR body 取得は一切行わない（marker 由来カウンタとの掛け算を構造的に不可能にする）。
  - **`FR_PROCESSED_THIS_CYCLE` の in-memory set 実装**: bash の連想配列ではなく space-separated 文字列 + case match で idempotent 化した（`case " $set " in *" $key "*) ;; *) set="$set $key" ;; esac` パターン）。連想配列は subshell に伝播しないが、本実装は trap 外の caller scope で `export` するため次の `fr_run_recovery_attempt` 呼び出し時にも見える。test Section 5 で 1 回目成功 → 2 回目重複起動が即 0 return し、gh / claude / fr_save_state / fr_load_state すべて呼ばれないことを実証している。
  - **`assert_count` ヘルパーの `grep -c` exit 1 吸収**: `grep -c` は match 0 件で exit 1 を返すため、`|| echo "0"` 経由で stdout に "0" を append すると、grep が match 件数を出力してから "0" が連結されて `"0\n0"` のような値になる（actual: 0 行のときも "0\n0" になり、`"0" = "0\n0"` が false で test 失敗）。本 test では `count_pattern` helper を追加し `|| true` で exit code のみ吸収して空文字を "0" に正規化する形にした。今後の bash test では `grep -c` の戻り値解釈に注意（fr_invoke_test.sh の wc -l 系も同じ罠を持つ）。
  - **`fr_invoke_claude` の subshell 隔離パターン**: orchestrator 本体内で `( fr_invoke_claude ... ) || claude_rc=$?` の subshell パターンを採用した（task 5 learning の fr_invoke_test.sh と同じイディオム）。fr_invoke_claude 内部の `set +e/-e` toggle が caller の `set -euo pipefail` を干渉するため、subshell で囲って rc を取り出す必要がある。test 用 stub では subshell を経由しないが、production code path で本パターンを採用することで cron 実行時の予期しない exit を回避できる。
  - **task 7 用 stub 化（return 2 / return 3）**: `fr_terminate_max_attempts` / `fr_terminate_no_progress` は task 7 で追加されるため、本 task では当該経路を **return 値の差別化** のみで stub した（return 2 = max-attempts / return 3 = no-progress）。これにより task 8 の `process_failed_recovery` 実装時に `case $rc in 2) fr_terminate_max_attempts ...; 3) fr_terminate_no_progress ...; esac` という caller 側で terminate 経路を接続できる設計とした。本判断は design.md の Termination Layer 節と整合する。
- 残存課題:
  - **terminate 関数は task 7 の責務**: 本 task では `fr_terminate_max_attempts` / `fr_terminate_no_progress` を実装していない。`fr_run_recovery_attempt` の return 2 / 3 を caller 側で受けて terminate 関数を呼ぶ配線は task 7 + task 8 の責務。本 task の test では return 2 / 3 が**着手コメントを投稿せず**（terminate 専用コメントを task 7 が投稿する）に early return することを Section 7 / 8 で確認している。
  - **`fr_collect_pr_ci_context` / `fr_collect_issue_context` の spec dir 集約は task 5 learning から継続して未実装**: 本 task の orchestrator 経路では `context=$(fr_collect_*_context "$number")` を呼ぶだけで spec dir 集約には踏み込んでいない。task 8 で `process_failed_recovery` を実装する段階で必要なら helper を追加するか、orchestrator 本体に集約コードを追加する。AC（Req 3.1）の充足は title / labels / body / 末尾 5 件コメントで claude-failed 復旧の hint としては機能する想定。
  - **`docs/impl-notes.md` の Task 5 learning にある「`${var:-{}}` の brace expansion 罠」は本 task では遭遇せず**（`fr_run_recovery_attempt` 内では明示的な空チェック分岐を採用したため）。後続 task でも同様の罠を避けるため、jq の default 値を bash 側で展開する際は必ず明示的な if/case ガードを使うこと。

### Task 7

- 採用方針: `modules/failed-recovery.sh` に Termination Layer として `fr_terminate_max_attempts` / `fr_terminate_no_progress` の 2 関数を追加。task 6 で stub 化した `fr_run_recovery_attempt` の return 2 / return 3 経路に呼応する終端処理を実装し、`claude-failed` ラベル据え置き + 終端理由コメント 1 件 + `rs_set_result claude-failed` + `fr_log` 出力を design.md「Termination Layer」節（行 560-587）通りに集約した。
- 重要な判断:
  - **終端コメント本文に signature を含めるか含めないか**: `fr_terminate_no_progress` の本文 / 引数 `signature` の hex 値は、運用者向けの可読性を優先して **本文には含めない** ことを選択した。代わりに `fr_log` 出力には signature の先頭 8 桁を `signature=aaaaaaaa` 形式で参考表示し、grep 抽出可能とした。design.md は「終端理由（no-progress + 直前 signature 一致）を含むコメント」と書いてあるが、本実装は「no-progress + 同原因再発（無進捗）」の自然言語表現でこれを充足しており、hex 値の生展示は手動レビュワーの read value が低いと判断（test Section 3 で `aaaaaaaa0000...bbbb` の full hex がコメント本文に出ないことを assertion で固定）。
  - **`rs_set_result` を 1 度だけ呼ぶ契約（NFR 4.2 / 多重発火しない）**: 両関数とも `rs_set_result "claude-failed" || true` を 1 行だけ持ち、複数経路から呼ばないように構造的に保証した。test Section 7 で「max_attempts / no_progress それぞれで `^rs_set_result ` 全体が 1 件のみ」を `assert_count` で固定し、将来のリファクタで誤って多重発火を生やしても検知できるようにした。rs_set_result 自体は副作用が `RUN_SUMMARY_RESULT` への変数代入のみで戻り値常に 0 だが、契約として「1 度だけ呼ぶ」ことを明示する意図で `|| true` を付与。
  - **`fr_log` の prefix 形式（NFR 4.1）**: core_utils.sh の `fr_log` が `[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: $*` の 3 段 prefix を付与するため、本関数からは `${kind}=#${number} terminated reason=max-attempts total=${total_attempts} max=${FAILED_RECOVERY_MAX_ATTEMPTS}` のように `kind=#N` 形式で出力する。これにより `grep -E 'failed-recovery: (issue|pr)=#[0-9]+ terminated'` で運用者が終端 Issue/PR を抽出可能（test Section 1-2 で `issue=#42` / `pr=#200` / `reason=max-attempts` / `total=4` / `max=4` の全部分一致を検証）。
  - **fail-continue の徹底**: 両関数とも `fr_post_attempt_comment ... || true` で gh comment 失敗を吸収し、`rs_set_result` / `fr_log` は確実に呼ばれる順序にした。test Section 6 で `GH_RC=1` (gh failure) 時にも rc=0 + rs_set_result 1 件 + fr_log 出力が保証されることを実証。これは「run-summary 連携の優先（NFR 4.2）」と「ログ抽出可能性（NFR 4.1）」を gh failure に対しても robust にする設計。
  - **markdown バッククォート と SC2016**: 終端コメント本文に `` `claude-failed` `` という markdown コードフェンス装飾を入れたが、これは shellcheck が SC2016 (info) で「単一引用符内の expression が展開されない」と警告する。本文中のバッククォートは literal 意図なので、既存 `security-review.sh` / `context-map.sh` の同方針に従い `# shellcheck disable=SC2016` 行コメントで個別 disable した（CLAUDE.md の「warning ゼロを目指す（info は許容）」に整合）。
  - **fr_post_attempt_comment は task 6 で実装済みなので再利用**: terminate 関数からも `fr_post_attempt_comment "$kind" "$number" "$body"` を呼んで `gh issue/pr comment` を 1 件投稿する。kind / number の不正値ガードは fr_post_attempt_comment 側にも入っているが、本関数でも同じガードを **二重に**入れた（NFR 3.1 の defense-in-depth）。これにより run_recovery_attempt 経由でない直接呼び出しでも安全に動く。
  - **test での fr_post_attempt_comment 抽出**: 本 test では fr_post_attempt_comment を stub せず、task 6 で実装済みの本物を `extract_function` で同 module から抽出して使った。これにより「gh comment 失敗時の fail-continue」「コメント本文の埋め込み確認」を本物の post 関数を経由して検証できる（test Section 6 で実証）。stub 化していたら fr_warn が呼ばれない可能性があり、defense-in-depth の検証強度が落ちていた。
- 残存課題:
  - **task 8 で配線が必要**: 本 task では terminate 関数を追加しただけで、`fr_run_recovery_attempt` の `return 2` / `return 3` を caller 側で受けて terminate 関数を呼ぶ配線は task 8（`process_failed_recovery` 実装）の責務。task 8 では `case $rc in 2) fr_terminate_max_attempts "$kind" "$number" "$total"; 3) fr_terminate_no_progress "$kind" "$number" "$total" "$signature"; esac` のような分岐を追加する想定（total / signature の値は state JSON から再読み出しする可能性あり）。
  - **README 追加も task 8 の責務**: 「Failed Recovery Processor (#359)」節への env var 一覧 / 終端動作（max-attempts / no-progress）の挙動説明追加は task 8 で実施。本 task は modules 側の関数追加のみで完結。

### Task 8

- 採用方針: `modules/failed-recovery.sh` 末尾に Orchestrator Entry Point として `process_failed_recovery` と private helper `_fr_dispatch_candidate` を追加し、`issue-watcher.sh` の `REQUIRED_MODULES` 配列末尾に `"failed-recovery.sh"` を、call site を `process_pr_iteration` の直後・`process_design_review_release` の直前に 1 行追加した（design.md L588-606 の Orchestrator Layer 通り）。README には opt-in 機能表への 1 行追加と専用節「Failed Recovery Processor (#359)」を PR Iteration と Design Review Release の間（watcher サイクル順）に追加。
- 重要な判断:
  - **terminate 経路の配線方針 — `_fr_dispatch_candidate` 内で state 再読み込み**: `fr_run_recovery_attempt` の rc=2 / rc=3 を受けた時点で state JSON は既に新 total_attempts で in-progress save 済みなので、terminate 関数に渡す total_attempts と signature は **state JSON から再読み込み**するパターンを採用した（design.md の Termination Layer 引数仕様と整合）。`fr_run_recovery_attempt` の局所変数を caller に戻り値以外で渡す方法はないため、`fr_load_state` を再呼び出しして `jq -r '.total_attempts // 0'` / `.last_failure_signature // ""` で抽出する形にした。本パターンは「rc → state 再読み込み → terminate 呼び出し」が caller スコープで完結するため、内部関数の責務境界を綺麗に保てる利点もある。
  - **`_fr_dispatch_candidate` を private helper として切り出す**: `process_failed_recovery` 本体内に inline 展開すると case 分岐 + state 再読み込み + fail-continue 防御が冗長になり可読性が落ちる。1 candidate を 1 関数で完結させる責務分離が test 容易性にも寄与する（Section 10 で _fr_dispatch_candidate を unit-ish に検証）。private 印として関数名先頭にアンダースコアを付けた（既存 `_idd_flag` / `_fr_pipestatus` 等の既存ローカル変数命名と整合）。
  - **重複起動防止は `fr_run_recovery_attempt` 内部 in-memory set に委譲**: `FR_PROCESSED_THIS_CYCLE` の管理は task 6 で実装済みの `fr_run_recovery_attempt` / `fr_finalize_success` が担当しており、`process_failed_recovery` 側で二重実装しない（NFR 2.1 の責務一元化）。test Section 5 (fr_attempt_test.sh) で重複起動防止が動作することは確認済み。
  - **fetch 失敗 / 空文字 / 不正 number の防御**: `fr_fetch_failed_*` は fail-continue で `[]` を返す契約だが、念のため caller 側でも `|| echo "[]"` で 2 重防御し、`jq -r 'length'` の結果が非整数なら 0 に正規化、各 candidate の `number` フィールドも `^[0-9]+$` で再検証してから dispatch する（NFR 3.1 / 5.2 の defense-in-depth）。
  - **README の配置場所**: 既存 README の「Security Review Processor (#279)」「PR Iteration Processor (#26)」「Design Review Release Processor (#40)」が watcher 実行順に並んでいるため、本機能も同順序に従い **PR Iteration の直後 / Design Review Release の直前** に挿入した。Migration Note / 環境変数表 / cron 例 / D-19b 独立性節 / ⚠️ merge 後の再配置 の構造を既存節と統一した。
- 残存課題: なし。task 8 は本 spec の最終 task で、全 AC（Req 1.1〜6.2 + NFR 1.1〜5.2）が実装 + 近接テストで充足された。後続作業として、idd-claude が GitHub Actions ワークフロー（`.github/workflows/issue-to-pr.yml`）に Failed Recovery Processor の env を opt-in 露出させるかは、本 spec の Out of Scope（local watcher 用途のみ）なので別 Issue で議論する想定。

## 確認事項

- design.md の Logger Layer サンプル（`fr_log() { echo "[$(date '+%F %T')] failed-recovery: $*"; }`）には `[$REPO]` segment が無いが、tasks.md は「既存 `pi_log` / `pr_log` と同パターン」と明示しており、core_utils.sh の既存 logger（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` / `sec_log`）はすべて Issue #119 以降 `[$REPO]` を含む 3 段 prefix で統一されている。実装は tasks.md の「同パターン」指示 + 既存実装慣習に従って `[$REPO]` 含みで追加した。design.md サンプルは簡略表記と解釈したが、Architect 側で意図相違があれば指摘いただきたい（NFR 4.1「`failed-recovery:` prefix と Issue/PR 番号でログ抽出可能」は本実装で充足）。
- **Task 5.2: spec dir 配下集約の deferred**: design.md 行 485-487 / tasks.md 5.2 詳細項目に「`git show` 経由で spec dir 配下を集約」とあるが、Issue 番号から spec slug（`docs/specs/<N>-<slug>/`）を推定するロジック（git ls-tree で `^docs/specs/<N>-` プレフィックスの dir を探す等）が必要となり実装が膨らむ。本 task では `fr_collect_issue_context` で title / labels / body / 末尾 5 件コメント収集に留め、spec dir 集約は **後続 task 6（orchestrator）の prompt 組み立て時に追加実装する**設計とした。task 6 で必要に応じて `fr_collect_spec_dir <issue_number>` のような helper を追加するか、`fr_collect_issue_context` に統合するかは task 6 で判断する。本 deferred が AC（Req 3.1）の充足に影響する可能性があれば、Architect から指摘いただきたい（現状の Issue context 集約だけでも claude-failed の hint 抽出は十分機能する想定）。
- **Task 8: spec dir 集約は最終的に未実装のまま完了**: 上記 Task 5.2 で deferred した spec dir 集約は、task 6 / 7 / 8 を通じて結局未実装のまま本 spec を完了した。Issue 番号から spec slug を一意に推定する確定的な手段がない（同番号で複数 slug が存在する可能性、`docs/specs/<N>-*` glob は filesystem 側に依拠して REPO_DIR との整合が必要）ため、現状の context 集約（title / labels / body / 直近 5 件コメント + PR 経路では CI log tail 200 行）で AC Req 3.1 の hint 抽出は充足する判断とした。spec dir 集約を厳密に必要とする運用パターンが顕在化した場合は別 Issue で改修する。

## AC Traceability

| Requirement ID | 充足 task | 充足箇所 |
|---|---|---|
| 1.1〜1.5 (gate 起動制御) | task 3.1 + task 8 | `fr_is_enabled` 厳密一致 + `process_failed_recovery` 冒頭 gate / `fr_is_enabled_test.sh` / `fr_process_test.sh` Section 1 |
| 2.1〜2.5 (候補選定) | task 4 + task 8 | `fr_fetch_failed_issues` / `fr_fetch_failed_prs` + orchestrator 配線 / `fr_fetch_test.sh` / `fr_process_test.sh` Section 2 |
| 3.1〜3.5 (失敗解析・修正) | task 5 + task 6 | `fr_collect_*_context` / `fr_invoke_claude` / `fr_run_recovery_attempt` / `fr_invoke_test.sh` / `fr_attempt_test.sh` Section 4 |
| 4.1〜4.8 (attempt budget) | task 2.1 + task 3.2 + task 6 + task 7 + task 8 | env 正規化 + state JSON + 試行開始時 attempt++ + terminate + dispatch 配線 / `fr_state_test.sh` / `fr_attempt_test.sh` Sections 1, 2, 7 / `fr_terminate_test.sh` / `fr_process_test.sh` Section 5 |
| 5.1〜5.5 (no-progress) | task 5.1 + task 6 + task 7 + task 8 | `fr_compute_failure_signature` / `fr_detect_no_progress` / terminate / dispatch / `fr_no_progress_test.sh` / `fr_attempt_test.sh` Section 8 / `fr_process_test.sh` Section 5-B |
| 6.1〜6.2 (成功時状態遷移) | task 6 | `fr_finalize_success` / `FR_PROCESSED_THIS_CYCLE` / `fr_attempt_test.sh` Section 5, 11 |
| NFR 1.1〜1.3 (後方互換) | task 8 | gate off 副作用ゼロ / `fr_process_test.sh` Section 1 |
| NFR 2.1〜2.3 (冪等性) | task 3.2 + task 6 + task 8 | atomic write / in-memory set / state 再読み込み |
| NFR 3.1〜3.2 (security) | 全 task | `--arg` / `--` / ID 検証 / secrets 非露出（全 module 内） |
| NFR 4.1〜4.2 (可観測性) | task 1 + task 7 | `fr_log` 3 段 prefix + `rs_set_result` |
| NFR 5.1〜5.2 (静的解析+test) | 全 task | shellcheck warning ゼロ + 8 件 fr_*_test.sh 全 pass |

## Verify 結果

```
$ shellcheck local-watcher/bin/modules/failed-recovery.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh
（出力なし / warning ゼロ）

$ bash local-watcher/test/fr_is_enabled_test.sh   # PASS
$ bash local-watcher/test/fr_state_test.sh        # PASS
$ bash local-watcher/test/fr_fetch_test.sh        # PASS
$ bash local-watcher/test/fr_no_progress_test.sh  # PASS
$ bash local-watcher/test/fr_invoke_test.sh       # PASS
$ bash local-watcher/test/fr_attempt_test.sh      # PASS
$ bash local-watcher/test/fr_terminate_test.sh    # PASS
$ bash local-watcher/test/fr_process_test.sh      # PASS=62 FAIL=0
```

全 8 件の近接テストが pass、shellcheck warning ゼロ（NFR 5.1, 5.2 充足）。

STATUS: complete
