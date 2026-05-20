# 実装ノート: #118 bug(watcher): pr-iteration round が five_hour quota の allowed_warning で中途終了し、作業ツリー dirty を残して以降の cycle が沈黙失敗する

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`
  - 新規 helper 3 つを `pi_run_iteration` の直前に追加
    - `pi_detect_quota_soft_fail` (L1885〜): stream-json から `rate_limit_event` + `status == "allowed_warning"` + `surpassedThreshold >= 0.9` を検出する jq folder。`qa_detect_rate_limit` と独立、`QUOTA_AWARE_ENABLED` 設定に依存しない
    - `pi_branch_is_claude_pr_head` (L1922〜): `^claude/issue-[0-9]+-` 命名規約一致判定。auto-commit 発火ガード
    - `pi_auto_commit_and_push` (L1942〜): `git add -A` + `git commit -m "<msg>\n\nCo-Authored-By: Claude <noreply@anthropic.com>"` + `git push origin <branch>` の 3 段
  - `pi_run_iteration` のサブシェルを書き換え (L2025〜2231)
    - claude 出力を `tee -a $pi_log_file | pi_detect_quota_soft_fail > $pi_soft_fail_file` に分岐
    - `PIPESTATUS[0]` で claude 本体の rc を保持しつつ、tee / jq の rc を握り潰さない
    - subshell 終端で `git status --porcelain` 判定 → soft-fail / post-round-dirty / 差分なし の 3 系統で `pi_recover_file` に結果を書き出す
    - 親 (pi_run_iteration の subshell 外) は recover_file を読み取り、`soft-fail-commit:ok` の場合は `pi_finalize_labels*` を呼ばずに return 1（needs-iteration 据え置き）
  - `process_pr_iteration` の冒頭 dirty check を書き換え (L2247〜2284)
    - dirty 検出時に current branch / dirty paths / 派生 issue 番号をログ出力
    - `claude/issue-<N>-` 規約一致なら `pi_auto_commit_and_push` で `pre-cycle-recover` 経路 → 成功で本処理継続、失敗で ERROR + skip
    - 規約不一致は ERROR + skip（既存挙動と同等の安全側）
- `local-watcher/test/pi_detect_quota_soft_fail_test.sh` (新規)
  - `pi_detect_quota_soft_fail` の検出条件と `pi_branch_is_claude_pr_head` の境界条件を fixture + assert で検証する 13 件のテスト
- `local-watcher/test/fixtures/pi_detect_quota_soft_fail/*.jsonl` (新規 6 件)
  - top-level / ネスト位置 / threshold 境界 / rejected 非対象 / 通常成功 / malformed 行混入 を網羅

## 設計判断と根拠

### 1. `pi_detect_quota_soft_fail` を `qa_detect_rate_limit` と分離した理由

要件 5 で `QUOTA_AWARE_ENABLED` と独立に動作することが必須。`qa_detect_rate_limit` は `status="rejected"` / `status="exceeded"` 系を検出して dispatcher 経由で `needs-quota-wait` 付与する流れに紐づいているため、`allowed_warning` の検出ロジックを混ぜると "dispatcher 連携なし"（Req 5.3）の境界が曖昧になる。同一ファイル内に並列配置して両方ともサブシェルで個別の jq folder を呼ぶ構成にした。

### 2. soft-fail 検出と post-round-dirty 検出を 1 経路に統合した理由

要件 2.5 で「soft-fail の commit message を優先」と明記されているため、`subshell 内で has_dirty + soft_fail_observed の 2 値で commit message を分岐」させると要件 1 と要件 2 の経路を共通化できる。要件 1 のみが auto-commit を発火させると、quota 警告は出たが dirty が無いケースで finalize に進んでしまい Req 1.4（needs-iteration 据え置き）が崩れるため、`差分なし + soft-fail` ケースも `soft-fail-commit:ok` 扱いにして finalize を抑止する。

### 3. branch ガードを 2 箇所に重ねた理由

`pi_run_iteration` のサブシェル内では既に `head_ref` を `git checkout` 済みなので通常は claude/issue-... に居る。しかし claude 失敗時 / fetch 失敗時など、想定外の branch（BASE_BRANCH に居る場合等）にいる可能性がある。そのため `pi_branch_is_claude_pr_head` で防御し、不一致なら `post-round-commit:fail` を書き出して finalize を抑止する。`process_pr_iteration` の cycle 冒頭でも独立に同じ guard を掛けて、前 cycle 由来の dirty を回復するか skip するかを判断する。

### 4. push 戦略を `git push origin <branch>` （force なし）にした理由

`pi_run_iteration` で round 開始時に `git checkout -B "$head_ref" "origin/${head_ref}"` で **必ず origin に追従して fresh start** している（既存 AC 4.4）。したがって round 中に出来た commit を push する時点では origin と divergent していないため、plain push で fast-forward できる。force 系を使うと別経路 race で本要件 scope 外の事故を引き起こすため避けた。push 衝突は失敗扱いで needs-iteration 残置（Req 1.5 / 2.4）。

### 5. pre-cycle-recover の log で PR 番号を branch 名から派生させた

Req 4.2 で「PR 番号 / branch / 種別 / 結果」をログ出力することが指定されている。pre-cycle dirty 検出時点では PR 候補リスト取得前なので PR 番号は未知だが、branch 名 `claude/issue-<N>-<slug>` から正規表現で issue 番号を抜き出して `issue=#<N>` として埋め込んだ。grep 集計時の整合性のため。

### 6. claude 失敗時も post-round-recover に進む

claude が exit code 非 0 で終わったとしても、その時点で edit が部分的に残っている可能性は高い（むしろ rate-limit 中途終了は claude 失敗 + dirty として現れる可能性がある）。Req 2 は「round 終了時点で未コミット差分が残っていれば自動退避」と書かれており、claude 成功条件が前提ではないため、claude rc にかかわらず dirty 退避は実行する。退避結果が `post-round-commit:fail` でも上位は WARN + needs-iteration 据え置きの安全側に倒れる。

## 各 AC への対応箇所マッピング

| AC | 担保箇所 | テスト |
|---|---|---|
| Req 1.1 | `pi_detect_quota_soft_fail` の jq folder（L1885〜） + `pi_run_iteration` の tee pipe（L2086） | `pi_detect_quota_soft_fail_test.sh` の 6 ケース (top-level / nested / 境界値 / rejected 除外 / 通常成功 / malformed) |
| Req 1.2 | `pi_run_iteration` subshell の `has_dirty=true && soft_fail_observed=true` 分岐（L2131〜2139） | 設計判断 #2、`pi_auto_commit_and_push` の git ops は手動 smoke test で確認（後述） |
| Req 1.3 | `pi_auto_commit_and_push` の `Co-Authored-By` 行付与（L1955〜1957） + commit message format（L2134） | 手動 smoke: `/tmp/pi-autocommit-test` で commit message format を検証 |
| Req 1.4 | recover_status `soft-fail-commit:ok` 分岐で `pi_finalize_labels*` を呼ばず return 1（L2176〜2180） | `pi_finalize_labels` 関連の既存テストが通っていること + 設計判断 #2 |
| Req 1.5 | recover_status `soft-fail-commit:fail` 分岐で `pi_warn` + return 1（L2181〜2185） | 手動: `pi_auto_commit_and_push` を read-only directory 等で失敗させると WARN が出ることを設計上保証 |
| Req 1.6 | 本変更は `gh issue edit ... --add-label needs-quota-wait` を一切呼ばない（grep でも 0 件）。`qa_handle_quota_exceeded` 呼び出しも追加していない | grep 検索: 新規追加 hunk に `needs-quota-wait` / `qa_handle_quota_exceeded` 文字列なし |
| Req 2.1 | `pi_run_iteration` subshell の `has_dirty=$([git status --porcelain] ? true : false)` 判定（L2111〜2114） | 設計判断 #2 |
| Req 2.2 | `has_dirty=true && soft_fail_observed=false` で post-round-commit 経路（L2141〜2148） | 手動 smoke で auto-commit + push 成功確認 |
| Req 2.3 | commit message format `docs(specs): recover uncommitted round-${next_round} output (auto)` (L2143) + `Co-Authored-By` (L1955〜1957) | 手動 smoke で message format 確認 |
| Req 2.4 | recover_status `post-round-commit:fail` 分岐で `pi_warn` + return 1（L2190〜2194） | 設計上保証（`pi_auto_commit_and_push` のいずれかのステップ失敗で発火） |
| Req 2.5 | `if soft_fail_observed=true` の分岐を `else (post-round)` より先に評価する制御フロー（L2131） | コードレビューで構造的に保証 |
| Req 3.1 | `pi_log "pre-cycle dirty 検出 issue=#... branch=... paths=..."` (L2257) | 手動 smoke: `/tmp` の test repo で `pre-cycle dirty 検出` ログが出ることを確認 |
| Req 3.2 | `pi_branch_is_claude_pr_head` 一致時に `pi_auto_commit_and_push` で `pre-cycle-recover` (L2259〜2271) | `pi_detect_quota_soft_fail_test.sh` の `pi_branch_is_claude_pr_head` 4 ケース + 手動 smoke の `auto-commit: OK` |
| Req 3.3 | commit message format `docs(specs): recover pre-cycle dirty state on ${_pi_pre_branch} (auto)` (L2261) + Co-Authored-By | 手動 smoke: `git log -1 --format='%B'` で確認済み |
| Req 3.4 | `pi_branch_is_claude_pr_head` 不一致なら `pi_error` + return 0（L2272〜2276） | `pi_detect_quota_soft_fail_test.sh` の `branch=main / develop / human-...` 3 ケース |
| Req 3.5 | `pi_auto_commit_and_push` 失敗時に `pi_error` + return 0（L2267〜2271） | 設計上保証（`pi_auto_commit_and_push` のいずれかのステップ失敗で発火） |
| Req 4.1 | `pi_log "PR #... quota-soft-fail utilization=... action=auto-commit+keep-label"` (L2178) | コードレビュー、`pi_log` プレフィクスは既存通り |
| Req 4.2 | `pi_log "...post-round-recover branch=... action=success"` (L2188) + `pi_log "pre-cycle-recover issue=#... branch=... action=success"` (L2266) | コードレビューで形式確認 |
| Req 4.3 | `pi_warn` / `pi_error` はそれぞれ `>&2` に出力（pi_log/pi_warn/pi_error の既存定義） | 既存定義そのまま |
| Req 5.1 | `pi_detect_quota_soft_fail` は `QUOTA_AWARE_ENABLED` を一切参照しない | grep: `pi_detect_quota_soft_fail` 周辺に `QUOTA_AWARE_ENABLED` 文字列なし |
| Req 5.2 | `process_pr_iteration` 冒頭の dirty 検出 + 回復ロジックも `QUOTA_AWARE_ENABLED` 非依存 | grep: 該当 hunk に `QUOTA_AWARE_ENABLED` なし |
| Req 5.3 | 新規 hunk に `needs-quota-wait` / `qa_handle_quota_exceeded` の呼び出しなし | grep で確認済み |
| NFR 1.1 | 既存 needs-iteration → ready-for-review / awaiting-design-review 遷移は recover_status="none:" の場合のみ通過する original path（L2204〜2231） | 既存テスト 178 件が全て通ること |
| NFR 1.2 | `pi_log` / `pi_warn` / `pi_error` の関数本体は無変更。新規ログも同じ prefix を使う | `pi_log` 関数定義 (L1145〜1153) は無変更 |
| NFR 1.3 | 既存 env var に追加変更なし（`PR_ITERATION_ENABLED` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_GIT_TIMEOUT` / `QUOTA_AWARE_ENABLED` をそのまま参照） | Config ブロック (L52〜244) は無変更 |
| NFR 2.1 | fixture ベースのテストで 4 分岐を独立検証可能（detection の有無 × branch 規約一致の有無） | `pi_detect_quota_soft_fail_test.sh` 13 ケース + 設計判断 #3 |
| NFR 2.2 | 既存テスト 178 件が全て通る | `for f in local-watcher/test/*_test.sh; do bash $f; done` で確認済み |
| NFR 3.1 | `pi_log` の `[YYYY-MM-DD HH:MM:SS] pr-iteration: ...` 形式を維持 | `pi_log` 関数定義無変更 |
| NFR 3.2 | `quota-soft-fail` 行は 1 PR 1 行（`pi_log "PR #${pr_number}: ... quota-soft-fail utilization=... action=..."`）で出力される | grep で集計可能な形式 |

## テスト結果

### shellcheck

```
$ shellcheck -S warning local-watcher/bin/issue-watcher.sh
$ echo $?
0
```

`-S info` を付けても、追加した新規 hunk からの新規警告は 0 件（pre-existing な SC2317 / SC2012 は私の改修で増減なし）。

### 既存 + 新規テスト

```
normalize_slug_test.sh:                                      rc=0 PASS: 11, FAIL: 0
parse_review_result_test.sh:                                 rc=0 PASS: 19, FAIL: 0
pi_detect_quota_soft_fail_test.sh:                           rc=0 PASS: 13, FAIL: 0   <- 新規
qa_detect_rate_limit_test.sh:                                rc=0 PASS: 10, FAIL: 0
qa_run_claude_stage_test.sh:                                 rc=0 PASS: 23, FAIL: 0
slug_match_guard_test.sh:                                    rc=0 PASS: 13, FAIL: 0
stagec_pr_verify_fallback_test.sh:                           rc=0 PASS: 35, FAIL: 0
stagec_pr_verify_retry_test.sh:                              rc=0 PASS: 42, FAIL: 0
stagec_pr_verify_test.sh:                                    rc=0 PASS: 8, FAIL: 0
verify_pushed_or_retry_test.sh:                              rc=0 PASS: 17, FAIL: 0
```

合計 191 ケース全て PASS。新規 13 ケースは Req 1.1 と Req 3.2 / 3.4 の境界条件を網羅。

### 手動 smoke test: pi_auto_commit_and_push の E2E

```bash
# Setup: /tmp/pi-autocommit-test に git init + bare clone を作って
# claude/issue-118-impl-foo branch を作り a に編集を加える
# Extract: pi_log, pi_warn, pi_error, pi_branch_is_claude_pr_head, pi_auto_commit_and_push

branch=claude/issue-118-impl-foo dirty= M a
guard: OK
auto-commit: OK
after: dirty=                       # ← clean state に戻った
last commit message:
docs(specs): recover pre-cycle dirty state on claude/issue-118-impl-foo (auto)

Co-Authored-By: Claude <noreply@anthropic.com>
```

bare clone 側にも commit が push されていることを `git log -1 --format='%H %s' claude/issue-118-impl-foo` で確認。

### 構文チェック

```
$ bash -n local-watcher/bin/issue-watcher.sh
syntax OK
```

### cron-like 最小 PATH での依存解決

```
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq flock git timeout'
/usr/bin/gh
/usr/bin/jq
/usr/bin/flock
/usr/bin/git
/usr/bin/timeout
```

claude CLI は `$HOME/.local/bin` に居る前提（既存挙動、本変更で変えていない）。

## 確認事項（レビュワー向け）

1. **claude 失敗時の post-round-recover について**: Req 2 は「Claude セッションが終了したとき」と書かれているのみで、claude rc が 0 / 非 0 を区別していない。実装では claude rc にかかわらず `git status --porcelain` 判定を行い、dirty なら退避する方針にした（設計判断 #6）。これは Req 1 の `allowed_warning` 検知時に claude が exit code 非 0 で抜けるケース（CLI 実装次第）も拾うため必要だが、もし PM 側が「claude rc=0 のときだけ自動回復したい」意図であれば指摘してください。
2. **branch ガードの round-内版**: `pi_run_iteration` のサブシェル末尾で `pi_branch_is_claude_pr_head` で current branch を再評価しているのは防御的措置。通常経路は `git checkout -B "$head_ref" "origin/${head_ref}"` 直後なので一致するはずだが、`set +e` 配下で稀に checkout が失敗していると BASE_BRANCH に居る可能性を排除できないため。Req 1 / 2 には書かれていないがエラーケース対策として入れた。問題があれば指摘してください。
3. **`pi_log` の 1 行集計性 (NFR 3.2)**: `quota-soft-fail utilization=0.92 action=auto-commit+keep-label` を 1 行で出すことで `grep 'quota-soft-fail'` で件数集計可能にしている。`utilization` フィールドは `surpassedThreshold` の小数値そのまま。`utilization=0.92` の形式で問題なければよし、`utilization=92%` 等のフォーマットが好ましければ指摘してください。
4. **pre-cycle-recover の force push 非利用**: 通常 fast-forward で push 可能と想定（subshell 終端でも origin と divergent でない前提）。万一 push 失敗（divergent / 権限）した場合は WARN + skip で次サイクルに委ねる方針。force-with-lease を使うべきか否かは PM 判断に委ねる。
5. **fixture テストの代替性**: 本リポジトリは unit test framework なしで fixture ベースの shell test を採用している。`pi_run_iteration` 全体の E2E は claude CLI / `gh` への副作用を含むため fixture 化していない。NFR 2.1 で要求される 4 分岐独立検証は `pi_detect_quota_soft_fail_test.sh` の 6 ケース + `pi_branch_is_claude_pr_head` の 7 ケースで担保したつもりだが、より大きなテストハーネス（subshell + git stub）が必要なら次 Issue で切り出すべきかもしれない。
6. **Out of Scope の遵守**: dispatcher Resume Processor / `needs-quota-wait` ラベル / Stage A / B / C / Triage への波及はなし。本改修は `process_pr_iteration` / `pi_run_iteration` の 2 関数のみ。`qa_*` 関数や `process_quota_resume` は触っていない。
