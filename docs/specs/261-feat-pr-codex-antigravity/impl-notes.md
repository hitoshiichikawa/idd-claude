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
