# 実装ノート: #122 PR_ITERATION_MAX_ROUNDS の kind 別分離 + no-progress ループ検知

## 主要変更点

### 環境変数

`local-watcher/bin/issue-watcher.sh` 冒頭の env 解決ブロック（旧 line 120 周辺）を拡張:

- `PR_ITERATION_MAX_ROUNDS_IMPL`: kind=impl の round 上限（明示時のみ）
- `PR_ITERATION_MAX_ROUNDS_DESIGN`: kind=design の round 上限（明示時のみ）
- `PR_ITERATION_NO_PROGRESS_LIMIT`: 既定 `3`。no-progress 連続上限
- `PR_ITERATION_MAX_ROUNDS_LEGACY_SET`: 内部フラグ。旧 env が `${...:-3}` 展開前に明示
  設定されていたかを保持し、`pi_resolve_max_rounds` 内で「未設定」と「default 値」を
  区別する（Req 1.3 / 1.4）

旧 `PR_ITERATION_MAX_ROUNDS` は kind 別 env が未設定時の fallback として温存（NFR 1.1）。

### 新規 / 改修関数

| 関数 | 内容 | 行数 (おおよそ) |
|---|---|---|
| `pi_resolve_max_rounds <kind>` | 新規。env を AC 1.1〜1.4 の優先順位で解決 | bin/issue-watcher.sh 1281〜1326 |
| `pi_read_no_progress_streak <pr_body>` | 新規。hidden marker から streak 値抽出（key 不在は 0） | bin/issue-watcher.sh 1349〜1374 |
| `pi_write_marker <pr_number> <round> <streak>` | 新規。marker 書き込みのみを担う（コメント投稿は分離） | bin/issue-watcher.sh 1591〜1632 |
| `pi_post_processing_comment <pr_number> <round> <max>` | 新規。round 着手表明コメント投稿のみ | bin/issue-watcher.sh 1641〜1668 |
| `pi_post_processing_marker` | 改修。`pi_write_marker` + `pi_post_processing_comment` の合成版として温存（旧呼出元の後方互換、現状 caller は無し） | bin/issue-watcher.sh 1672〜1691 |
| `pi_escalate_to_failed` | reason 引数を追加（`max-rounds` / `no-progress`）。no-progress 用本文を分岐 | bin/issue-watcher.sh 1893〜1991 |
| `pi_build_iteration_prompt` | `max_rounds` パラメータを引数 5 で受ける（呼出元から kind 別解決値を渡す） | bin/issue-watcher.sh 2006 |
| `pi_run_iteration` | round + streak 抽出 → max_rounds 解決 → SHA 比較 → marker は成功 path のみ書き込み（失敗時は据え置き） | bin/issue-watcher.sh 2240〜2378 |
| `process_pr_iteration` | サイクル開始ログを `max_rounds_impl=N max_rounds_design=N no_progress_limit=N` 形式に拡張 | bin/issue-watcher.sh 2444〜2452 |

### hidden marker フォーマット

旧: `<!-- idd-claude:pr-iteration round=N last-run=ISO8601 -->`
新: `<!-- idd-claude:pr-iteration round=N last-run=ISO8601 no-progress-streak=K -->`

- prefix と既存 key 名は不変（Req 4.3）
- 旧 marker 読み込み時は streak=0 として解釈（Req 4.2 / 4.4）
- 置換 sed の regex `<!-- idd-claude:pr-iteration round=[0-9]+ last-run=[^>]*-->` は
  末尾 `-->` 直前まで貪欲に食うため、旧 / 新両形式を同一 regex で吸収（Req 4.4）

## AC ごとの実装対応表

| AC | 実装場所 | テスト |
|---|---|---|
| Req 1.1: `PR_ITERATION_MAX_ROUNDS_IMPL` 採用 | `pi_resolve_max_rounds` (impl 分岐) | `pi_max_rounds_kind_test.sh` 1.1 |
| Req 1.2: `PR_ITERATION_MAX_ROUNDS_DESIGN` 採用 | `pi_resolve_max_rounds` (design 分岐) | `pi_max_rounds_kind_test.sh` 1.2 |
| Req 1.3: 旧 env が fallback | `pi_resolve_max_rounds` + `PR_ITERATION_MAX_ROUNDS_LEGACY_SET` | `pi_max_rounds_kind_test.sh` 1.3 |
| Req 1.4: 既定 impl=3 / design=0 | `pi_resolve_max_rounds` 末尾 | `pi_max_rounds_kind_test.sh` 1.4 |
| Req 1.5: サイクル開始ログに kind 別表示 | `process_pr_iteration` の `pi_log "サイクル開始..."` | 手動確認（dry run / log grep） |
| Req 1.6: round 着手・escalate・log に max を反映 | `pi_post_processing_comment` / `pi_run_iteration` / `pi_escalate_to_failed` | 手動確認 |
| Req 2.1 / 2.3: max=0 は round 超過 escalate を行わない | `pi_run_iteration` の `if [ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]` | `pi_max_rounds_kind_test.sh` 2.1 / 2.3 |
| Req 2.2: max=0 でも no-progress は有効 | `pi_run_iteration` 末尾の no-progress 検知は max とは独立 | コード読解 + 1.4 default 0 ケースが該当 |
| Req 2.4: max=0 のログ表現 | `pi_post_processing_comment` の `max_display="無制限"` | コード読解 |
| Req 3.1: no-progress を `+1` | `pi_run_iteration` の `new_streak=$((prev_streak + 1))` | コード読解（subshell 内 SHA 比較ロジック） |
| Req 3.2: commit ありで `0` リセット | `pi_run_iteration` の `if [ "$commit_pushed" = "true" ]; then new_streak=0` | コード読解 |
| Req 3.3: 上限到達で escalate | `pi_run_iteration` の `if [ "$new_streak" -ge "$PR_ITERATION_NO_PROGRESS_LIMIT" ]` | コード読解 |
| Req 3.4: `PR_ITERATION_NO_PROGRESS_LIMIT` 既定 `3` | env 解決ブロックの `:-3` | コード読解 |
| Req 3.5: escalate コメント本文に reason / streak / limit | `pi_escalate_to_failed` の `if [ "$reason" = "no-progress" ]` ブロック | コード読解 |
| Req 3.6: hidden marker から streak 読み取り（kind 非依存） | `pi_read_no_progress_streak` | `pi_max_rounds_kind_test.sh` 3.6 |
| Req 4.1: marker 内に streak キー格納 | `pi_write_marker` の marker 構築 | `pi_max_rounds_kind_test.sh` 4.1 |
| Req 4.2: streak キー不在 → `0` | `pi_read_no_progress_streak` で `${streak:-0}` | `pi_max_rounds_kind_test.sh` 4.2 |
| Req 4.3: 既存 key prefix / key 名不変 | marker 文字列内の `round=`, `last-run=` は変更せず追記のみ | `pi_max_rounds_kind_test.sh` 4.3 |
| Req 4.4: 旧 marker しかない PR で ERROR なし | `pi_read_no_progress_streak` は空 streak を 0 にフォールバック、`pi_write_marker` の sed regex が旧 / 新両形式を吸収 | `pi_max_rounds_kind_test.sh` 4.4 |
| Req 4.5: 複数 marker は末尾を採用 | `grep -oE ... \| tail -1` | `pi_max_rounds_kind_test.sh` 4.5 |
| Req 5.1 / 5.2: quota soft-fail 時は round / streak 据え置き | `pi_run_iteration` の `case "$recover_status" in soft-fail-commit:ok/fail) ... return 1` 経路で `pi_write_marker` を呼ばない | コード読解（subshell の recover_status 分岐） |
| Req 5.3: claude crash 時も据え置き | rc != 0 の case で `pi_write_marker` を呼ばない経路 | コード読解 |
| Req 5.4: marker 書き込み失敗時 ERROR | `pi_write_marker` 失敗時に `pi_error` + `return 1` | コード読解 |
| Req 5.5: 失敗 round 後の次サイクルで据え置き値から再開 | 失敗 path で marker を更新しないため、次サイクルの `pi_read_round_counter` / `pi_read_no_progress_streak` が同じ値を返す | コード読解 |
| Req 6.1: サイクル開始ログ | `process_pr_iteration` の `pi_log "サイクル開始 ... max_rounds_impl=... max_rounds_design=... no_progress_limit=..."` | 手動確認 |
| Req 6.2: streak 加算時の 1 行ログ | `pi_run_iteration` の `pi_log "PR #... no-progress-streak=${new_streak} limit=..."` | コード読解 |
| Req 6.3: no-progress escalate 行 | `pi_run_iteration` の `pi_log "... reason=no-progress escalate"` | コード読解 |
| Req 6.4: round 超過 escalate 行 | `pi_run_iteration` の `pi_log "... reason=max-rounds escalate"` | コード読解 |
| Req 6.5: 既存 timestamp / prefix 不変 | 全ログを `pi_log` / `pi_warn` / `pi_error` で出力（変更なし） | コード読解 |
| Req 7.1〜7.3: README 整合 | `README.md` の env 表 / migration note / hidden marker 節を更新 | 手動確認 |

## 追加テスト

### `local-watcher/test/pi_max_rounds_kind_test.sh`（新規）

- `pi_resolve_max_rounds` の 11 ケース（Req 1.1〜1.4 + Req 2.1 / 2.3 の境界 / 異常系）
- `pi_read_no_progress_streak` の 7 ケース（Req 3.6 / 4.2 / 4.4 / 4.5 の正常 + 境界）
- `pi_read_round_counter` 後方互換性: 旧 / 新 marker 両方から round 抽出
- `pi_write_marker` 置換 regex の旧 marker 吸収性: 旧 → 新置換、新 → 新置換
- `pi_read_last_run` 後方互換性: streak 付き marker からも last-run のみ抽出

合計 24 ケース、全 PASS。

### 検証コマンド結果

```bash
$ shellcheck local-watcher/bin/issue-watcher.sh 2>&1 | grep -E "SC[0-9]+" \
  | grep -v "SC2317" | grep -v "SC2012" | grep -v "^In " | sort -u
# (empty — clean)

$ bash local-watcher/test/pi_max_rounds_kind_test.sh
# PASS: 24, FAIL: 0

$ for t in local-watcher/test/*.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL: $t"; done
# (clean — 全 11 既存テスト + 新規 1 テスト = 12 テスト全 PASS)
```

Note: `stagec_pr_verify_retry_test.sh` で 1 回 transient な FAIL（Test 4: `issue=#108` 期待値）が
観測されたが、再実行で安定して PASS。本実装と無関係（baseline でも稀に発生する可能性あり）。

### dry run

```bash
$ bash -n local-watcher/bin/issue-watcher.sh
# Syntax OK

$ REPO=owner/test REPO_DIR=/tmp/test-repo bash local-watcher/bin/issue-watcher.sh
# 「base-branch=main merge-queue-base=main」までは正常に進む（gh API 不通でその先 fatal、
# これは dry run 環境の制約であり本実装の問題ではない）
```

## 設計判断

### marker 書き込みタイミングの変更（Req 5 への対応）

旧実装では `pi_post_processing_marker` が round 開始時に marker + コメント両方を投稿していた。
Req 5「失敗 round の counter 据え置き」を満たすため、本実装では:

- round 開始時: `pi_post_processing_comment` で **コメントのみ投稿**（人間向け視認用）
- round 終了時の成功 path のみ: `pi_write_marker` で round / streak を更新

失敗 path（soft-fail-commit / post-round-commit:fail / claude rc != 0 / 想定外 branch dirty）では
marker を書き込まないため、自然に counter が据え置かれる（Req 5.1 / 5.2 / 5.3）。
旧 `pi_post_processing_marker` は呼び出し元なしになるが、外部互換のため温存。

### no-progress 検知における commit 観測方法

`git rev-parse HEAD` を round 開始時（`git checkout -B` 直後）と round 終了時（auto-commit /
push 完了後）で取得し、SHA 比較で「新規 commit が push されたか」を判定する。

- subshell <-> 親 shell 間は tmpfile (`$pi_sha_file`) で 1 行目=before_sha / 2 行目=after_sha
- subshell 内で `pi_auto_commit_and_push` が成功すれば HEAD が進む → 検知
- subshell 内で claude が自前 commit + push（reply-only ではない通常 round）した場合も
  HEAD が進む → 検知
- claude が「対応不要」を返して 1 commit も作らなかった場合は HEAD 不変 → no-progress 加算

`gh pr view` で commits を取らずに local `git rev-parse` で観測することで、API 呼び出しを
増やさない。

### 既定値: design=0（無制限）の妥当性

Issue 本文の推奨と PM の Req 1.4 / 2 に従い design 既定 `0` を採用。理由:

- design レビューは「派生論点が多いため round 数で機械的に打ち切ると不十分」という本機能の
  動機そのものに直結
- 旧運用との非互換を懸念する運用者は明示的に `PR_ITERATION_MAX_ROUNDS=N` を設定すれば fallback
  経路で従来通り両 kind に同値が適用される（Req 1.3）

## 確認事項

以下は実装中に判断したが、設計レビュー / 運用側で再確認したい点:

1. **kind 別 env が空文字列 `""` の扱い**: `PR_ITERATION_MAX_ROUNDS_IMPL=""` を明示した場合、
   `[ -n "$kind_specific" ]` 判定で「未設定相当」になり旧 env fallback に倒れる。これは bash の
   `${VAR:-}` の典型挙動だが、運用者が「明示的に 0 を設定して無制限化したい」と思って空文字を
   設定するケースが混入し得る。仕様としては「無制限化したいなら `=0`」を明文化（README 表）
   しているため、現状の挙動で問題ないと判断。

2. **`pi_resolve_max_rounds "$kind"` が `rc != 0` を返したときの呼び出し元挙動**: `pi_run_iteration`
   は `local max_rounds; max_rounds=$(pi_resolve_max_rounds "$kind")` としているため、エラー時
   `max_rounds` は空文字列になる。後続の数値比較 `[ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]`
   で `[: : integer expression expected` が出る可能性があるが、`pi_classify_pr_kind` が
   `design|impl` 以外を return する経路は subshell より前に return 3 されているため、実運用で
   ここに到達することは無い（防御的二重ガード）。

3. **`PR_ITERATION_MAX_ROUNDS_LEGACY_SET` の値の永続性**: `for _idd_flag in ...` の normalize
   ループの直後で参照されるため、`unset _idd_flag` の影響は受けない（別 prefix）。ただし、
   sub-process / function 内では parent scope の変数として参照可能なため問題なし。

4. **テストカバレッジ**: `pi_run_iteration` 自体のフロー（SHA 比較 / 失敗 path / escalate 分岐）は
   subshell + claude CLI + gh コマンドを伴うため、bash unit test では難易度が高い。本実装では
   「個別ヘルパ関数の正確性 + コード読解での組み合わせ確認」をテスト戦略とした（既存
   pi_detect_quota_soft_fail_test.sh / qa_run_claude_stage_test.sh も同方針）。本流の挙動確認は
   dogfooding（idd-claude 自身の Issue で運用検証）で行う前提。

5. **既存 marker（streak 無し）→ 新 marker への自動 migration**: 初回の round 終了時に新形式で
   書き換わるため migration スクリプトは不要。ただし「ある PR が `claude-failed` のまま放置されて
   いて、marker が旧形式のままで人間がリセット手順を実行する」シナリオでは、README に書かれた
   sed コマンドが旧 / 新両 marker を削除できることを確認済み（`<!-- idd-claude:pr-iteration round=[0-9]+ [^>]*-->` で両形式マッチ）。
