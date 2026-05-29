# Implementation Notes (#261)

## Implementation Notes

### Task 1

- 採用方針: 既存 `drr_log` 群の直後に `pr_log` / `pr_warn` / `pr_error` を追加し、書式・配置順序を `qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` の前例と完全に揃えた。
- 重要な判断: prefix は design.md と tasks.md が指定する `pr-reviewer:` を採用（`pr-iteration` との視認性差を確保しつつ短縮）。`[$REPO]` 挿入は Issue #119 系の既存 NFR 3.1 規約を継承。新規関数のみ追加し既存関数・順序は触らず NFR 1.2 を満たした。
- 残存課題: なし。後続 task 2.x で `pr-reviewer.sh` モジュールから本ロガーを利用する。

### Task 2

- 採用方針: task 2.1 で skeleton（opt-in early-return + 1 行 summary log）を立て、task 2.2 で `pr_resolve_tool` を追加して `process_pr_reviewer` に組み込む 2-commit 構成。skeleton 段階で未定義参照のリスクを残さないため、task 2.1 commit では `pr_resolve_tool` を呼ばない最小実装に留めた（commit 単位で `bash -n` / `shellcheck` がパスする整合性を維持）。
- 重要な判断: (a) `pr_resolve_tool` の stdout 契約は「`codex` / `antigravity` / `none` / `conflict` の 1 語のみ」とし、観測ログ（`pr_log` / `pr_warn` / `pr_error`）はすべて `>&2` に出して呼び出し元 `out=$(pr_resolve_tool)` 構文を汚さない設計とした（none-case で `pr_log` 出力が `resolved_tool` 変数に混入する初期不具合を smoke test で発見し修正）。(b) `PR_REVIEWER_TOOL=Codex` や `=bogus` 等の typo は design.md Decision 1 step 6 に従い WARN + alias fallback とし、`PR_REVIEWER_ENABLED=True` のような typo は AC 1.1 に従い厳密 `=true` 一致のみ ON とする（同じ「typo」でも env 種別で振る舞いが異なる点に注意）。(c) conflict / none 時も `process_pr_reviewer` は `return 0` で dispatcher fail-continue 契約を維持し、conflict 時の PR コメント投稿（kind=conflict-tool）は task 3 / 5 の責務として明確に分離した。
- 残存課題: (a) conflict / not-installed / not-authenticated 等の `kind=*` エラーコメント投稿は task 3 / 5 で実装する（本 task では log での観測可能性のみ確保）。(b) task 7 で `issue-watcher.sh` 本体への env 配線（`PR_REVIEWER_ENABLED` / `PR_REVIEWER_TOOL` / `PR_REVIEWER_MAX_PRS` / `PR_REVIEWER_EXEC_TIMEOUT` の `${VAR:-default}` 解決）と REQUIRED_MODULES 追加・dispatcher call site が必要。本 task 完了時点では `pr-reviewer.sh` は単体 source で動作するが dispatcher からは呼ばれない。

### Task 3

- 採用方針: `pr_resolve_tool` の直後に `pr_check_tool_installed` / `pr_check_tool_authenticated` を pure check として追加。両関数とも tool 名 (`codex` / `antigravity`) を入力に取り戻り値で状態を返す契約とし、`process_pr_reviewer` への組み込みは task 4 以降の責務として残置（design.md File Structure Plan 整合）。
- 重要な判断: (a) antigravity の実バイナリ名は Decision 2 / 3 に従い `agy` を `command -v` 対象とする（tool 名 "antigravity" と bin "agy" を case で明示マッピング）。(b) auth コマンドは `bash -c "$cmd"` + `>/dev/null 2>&1` で実行し、`eval` を避けつつ stdout / stderr を完全破棄して auth token / 認証 URL の流出を防ぐ（Security Considerations / Decision 9）。(c) env 空文字 = check 機構無効 (rc=2) の契約は AC 3.2 既定（agy = `""`）と整合し、task 7 の env 既定値配線（codex = `codex login status`、agy = `""`）が watcher 本体から渡されるまで本 task 単独でも安全に skip 動作する。(d) tool 名が canonical 2 値以外の入力は内部矛盾なので `pr_error` で観測しつつ安全側 (installed: rc=1 / authenticated: rc=2 skip) に倒した。
- 残存課題: なし。task 4 以降で `process_pr_reviewer` に組み込み、`kind=not-installed` / `kind=not-authenticated` のエラーコメント投稿 (task 5 の `pr_post_error_comment`) に接続する。

### Task 4（marker / 重複判定 / 候補 PR 列挙）

- 採用方針: `pr_build_marker` / `pr_already_processed` / `pr_fetch_candidate_prs` を追加。重複判定は Decision 6 の `(sha, kind)` 単位とし、`gh api /repos/$REPO/issues/<n>/comments` + `jq test()` で marker の存在を確認。候補列挙は既存 `pi_fetch_candidate_prs`（PR Iteration）を踏襲し、server-side `--search "-draft:true"` + client-side `select(.isDraft==false)` の二重防御・head pattern 一致・fork 除外（`headRepositoryOwner.login == owner`）を適用した。
- 重要な判断（design からの逸脱）: **marker に `tool=` 属性を追加**（design.md の marker 例は `sha`/`kind` の 2 属性だが、Default Review Prompt 節と env catalog で tool 区別が前提化されているため `pr_build_marker <sha> <kind> [tool]` の 3 引数に拡張。第 3 引数省略時は `tool=none`）。**ただし重複判定では `tool` 属性を照合に使わない**（`jq` の test パターンは `sha=...[^>]*kind=...` のみ）。これにより「同一 SHA を codex でレビュー済みなら、後から antigravity に切替えても二重投稿しない」という Decision 6 の `(sha,kind)` 単位冪等性を保ちつつ、marker から実行 tool を運用者が追跡できる観測性を両立した。
- 重要な判断（fail-safe）: `pr_already_processed` は `gh api` 失敗時に **rc=0（既存扱い＝投稿しない）** に倒す（重複投稿という不可逆な副作用を避ける安全側）。SHA 不変なら次サイクルで self-heal するため取りこぼしは発生しない。`pr_fetch_candidate_prs` は失敗時に `"[]"` + WARN を返し、dispatcher fail-continue を阻害しない。
- 残存課題: なし。

### Task 5（prompt 構築 / レビュー実行 / コメント投稿）

- 採用方針: `pr_default_prompt`（内蔵 default、design.md「Default Review Prompt」と byte 一致・最終行 `VERDICT:` token）/ `pr_build_prompt_file`（`mktemp` で一時ファイル化）/ `pr_substitute_placeholders`（`{BASE}`/`{HEAD}`/`{PR}`/`{PROMPT_FILE}` 置換 + metachar 検査）/ `pr_execute_review_command`（subshell + EXIT trap で head checkout・BASE 復帰・read-only invariant 検査）/ `pr_post_review_comment` / `pr_post_error_comment` を追加。
- 重要な判断（design からの逸脱 a — 機能削減 YAGNI）: design.md env catalog では `PR_REVIEWER_PROMPT`（tool 共通）の単一プロンプト override のみを規定しており、**per-tool プロンプト override（`PR_REVIEWER_CODEX_PROMPT` 等）は導入しなかった**。tool ごとに観点を変える運用ニーズが現時点で存在せず、投機的抽象化を避けた（必要になれば後方互換に追加可能）。
- 重要な判断（design からの逸脱 b — 関数シグネチャ拡張）: design.md interface 表は `pr_execute_review_command(command_string, tool)` の 2 引数 + stdout 返却だが、実装は **6 引数 `(head_ref, resolved_cmd, tool, out_file, err_file, result_file)`** に拡張。理由は (1) head checkout を関数内で行う（AC 4.1）、(2) stdout / stderr / 実行結果トークンを分離して呼び出し元へ渡す必要がある（exec-failed コメントに stderr 先頭 1KB 抜粋を含めるため、AC 4.5）。subshell + `trap "git checkout '${BASE_BRANCH}'..." EXIT` で副作用を必ず巻き戻す invariant は維持。
- 重要な判断（design からの逸脱 c — comment 関数の tool 引数）: `pr_post_review_comment` / `pr_post_error_comment` は design 表の引数に加えて末尾に `tool`（省略時 `none`）を取る。marker の `tool=` 属性（逸脱 a）を埋めるため。
- 重要な判断（design からの逸脱 d — read-only 巻き戻し方法）: Decision 8 の read-only invariant 復元は `git checkout -- .`（tracked 変更の破棄）のみとし、**`git clean` は使わない**。`agy` が生成する untracked な `.antigravitycli/` 等のツール作業ディレクトリを巻き込んで削除しないため。tracked ファイルへの改変は破棄されるので read-only 契約（観測される副作用なし）は満たす。
- 重要な判断（注入対策）: `pr_substitute_placeholders` は GitHub 由来値（base/head/pr）に shell metacharacter（`;` `|` `&` `` ` `` `$(`）が混入していたら rc=1 で当該 PR を skip（Security Considerations）。実行は `eval` 不使用で `bash -c "$resolved_cmd"`、プロンプト本体は `{PROMPT_FILE}` 一時ファイル経由で argv に渡しコマンド文字列へ注入しない（Decision 9）。smoke test で 3 注入ベクタ（head/pr/base）すべての rejection を確認済み。
- 残存課題: なし。

### Task 6（VERDICT 検出 / ラベル付与 / 1 PR レビュー統括）

- 採用方針: `pr_detect_iteration_keyword`（`grep -E -i -c "$PR_REVIEWER_ITERATION_PATTERN"`）/ `pr_add_iteration_label`（`gh pr edit --add-label`、既付与なら冪等 no-op）/ `pr_run_review_for_pr`（1 PR 分の dedup→prompt→execute→parse→comment→VERDICT→label を統括）/ `pr_broadcast_error_to_prs`（cycle-level エラーを候補 PR 全件へ配る helper）を追加。
- 重要な判断（design からの逸脱 e — agy 出力 JSON のキー不確実性）: `agy -p ... --output-format json` の最終メッセージのキー名が公式に確定情報として得られなかったため、`jq -r '.message // .text // .response // empty'` の **fallback chain** で抽出し、いずれも空なら **raw 出力そのままを fallback** として採用する（空出力時のみ exec-failed コメント）。実運用で正しいキーが判明したら 1 箇所の jq フィルタ修正で対応可能なよう局所化した。
- 重要な判断（決定論ラベル判定）: `PR_REVIEWER_ITERATION_PATTERN` の既定を line-anchored `^[[:space:]]*VERDICT:[[:space:]]*needs-iteration[[:space:]]*$` とし、内蔵 prompt が最終行に出力する `VERDICT:` token のみで needs-iteration を判定（Decision 4）。レビュー本文中の偶発的な `needs-iteration` 文字列での誤発火を防ぐ。自由文 grep を希望する運用は env override 可能（後方互換）。
- 重要な判断（rc 契約）: `pr_run_review_for_pr` の rc は 0=success / 1=failure(transient/skip) / 2=skip(dup) / 3=exec-error とし、`process_pr_reviewer` の while ループで `reviewed`/`skip`/`fail`/`errored` に集計。`process_pr_reviewer` 自体は常に rc=0（dispatcher fail-continue 契約）。
- 残存課題: なし。

### Task 7（issue-watcher.sh への配線）

- 採用方針: 本体 Config ブロックに 14 個の env var を `"${VAR:-default}"`（self-referential default）形式で追加し、`REQUIRED_MODULES` に `pr-reviewer.sh` を追加、dispatcher に `process_pr_reviewer || pr_warn "..."` を `process_pr_iteration` の **直前**に配置した。
- 重要な判断（実行順序）: PR Reviewer を PR Iteration の直前に置くことで、PR Reviewer が付与した `needs-iteration` ラベルを**同一 flock サイクル内で直後の `process_pr_iteration` が引き継げる**（次サイクルを待たずに反復対応へ接続）。
- 重要な判断（SC2034 回避）: 14 env var はすべて `PR_REVIEWER_X="${PR_REVIEWER_X:-default}"` の自己参照 default 形式で記述。この形式は変数の「使用」とみなされるため、行 70-88 の素の代入（`LABEL_X="value"`）と異なり `# shellcheck disable=SC2034` を要しない（既存 idiom と整合）。
- 重要な判断（コマンド既定値のエスケープ）: `PR_REVIEWER_CODEX_CMD` 既定値内の `\"\$(cat '{PROMPT_FILE}')\"` は、config 読込時に command substitution が早期発火しないようにダブルクォート内で `\$` をリテラル `$` として保持する。exec 時に `pr_execute_review_command` 内の `bash -c "$resolved_cmd"` が `$(cat ...)` を展開し、プロンプト本体を単一 argv として渡す（scratch test で検証済み）。
- 残存課題: なし。

### Task 8（README）

- 採用方針: README root の「オプション機能一覧」表に opt-in 行を 1 行追加し、`## PR Reviewer Processor (#261)` h2 節を **PR Iteration Processor 節の直前**に挿入（実行順序と文書順序を一致させた）。`repo-template/README.md` は存在しない（README は root-only）ため二重管理対象外。
- 重要な判断（Migration Note）: 本機能は新規モジュール `modules/pr-reviewer.sh` を追加するため、既存 watcher 利用者には **merge 後の再配置（`cd ~/.idd-claude && git pull && ./install.sh --local`）が必須**である旨を ⚠️ 付きで明記した（未配置だと REQUIRED_MODULES ローダが起動時 exit 1 で停止するため）。既存 env var / ラベル / cron 文字列の後方互換は不変であることも併記。
- 残存課題: なし。

### Task 9（検証）

- 検証結果: `shellcheck local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh`（stage-a-verify コマンド）= 警告ゼロ（exit 0）。プロジェクト全体の `shellcheck`（`local-watcher/bin/*.sh modules/*.sh install.sh setup.sh .github/scripts/*.sh`）も exit 0。`bash -n` 3 ファイルすべて OK。
- 重要な判断（SC2016 inline disable）: pr-reviewer.sh の 2 箇所で info 級 SC2016 が誤検知された（(1) `pr_substitute_placeholders` の metachar 検査 case パターン内の単一引用符 `$(` はリテラル検出パターンであり展開を意図しない、(2) `pr_run_review_for_pr` の exec-failed 詳細 printf の単一引用符内バッククォートは markdown コードフェンス）。いずれも意図通りのリテラルのため `.shellcheckrc` のグローバル抑止ではなく**該当行直上の `# shellcheck disable=SC2016`** で局所抑止した（既存 baseline の SC2317/SC2012 のみグローバル抑止する方針を維持）。
- スモークテスト: 専用ハーネス（gh/git/timeout を mock）で 27 ケース green。内訳: opt-in gate（unset/garbage → OFF・副作用ゼロ、NFR 1.1）、`pr_resolve_tool` マトリクス 7 ケース（canonical / alias / conflict / none / garbage fallback）、marker 書式（Decision 6）、placeholder metachar rejection 3 ベクタ（Decision 9）、conflict-tool broadcast（AC 2.3/2.4）、not-installed broadcast（AC 3.1）、2 サイクル dedup 冪等性（Decision 6 / NFR 4.1）。加えて全 10 モジュールが宣言順で source でき `process_pr_reviewer` ほか pr-reviewer 関数が定義されること、cron-like 最小 PATH で gh/jq/flock/git が解決されることを確認。
- 残存課題: 実バイナリ（codex / agy）を用いた live E2E は watcher 実行環境（インストール・認証）が前提のため本 PR スコープ外（README にセットアップはスコープ外と明記）。`agy --output-format json` の最終メッセージキー名は実機判明後に jq フィルタ 1 箇所で追従する。
