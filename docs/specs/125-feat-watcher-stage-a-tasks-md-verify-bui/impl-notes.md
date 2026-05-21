# Implementation Notes: Stage A Verify Gate (#125)

## 変更概要

`local-watcher/bin/issue-watcher.sh` の `run_impl_pipeline` に
**stage-a-verify ゲート**を 1 段挿入し、Stage A 完了直前に watcher 自身が
`tasks.md` 末尾の build/test/lint コマンドを REPO_DIR で独立再実行する機能を
追加した。

- env 3 種（`STAGE_A_VERIFY_ENABLED=true` / `STAGE_A_VERIFY_TIMEOUT=600` /
  `STAGE_A_VERIFY_COMMAND`）を Config ブロックに追加
- `sav_log` / `sav_warn` / `sav_error` ロガー（Issue #119 規約に従い `[$REPO]`
  prefix 付き 3 段 prefix）
- `stage_a_verify_extract_command`（tasks.md 末尾走査 + keyword 一致抽出、
  awk 1 パス O(N)）
- `stage_a_verify_resolve_command`（escape hatch 優先 + tasks.md 抽出合成）
- round counter helpers（`_round_path` / `_read_round` / `_bump_round` /
  `_reset_round`、sidecar による永続化）
- `stage_a_verify_run` 統合ランナー（DISABLED / SKIPPED / SUCCESS / FAILED /
  TIMEOUT を 5 分岐で処理、round=1 差し戻し / round=2 escalate）
- `_sav_handle_failure` 失敗ハンドラ（mark_issue_failed 経由で claude-failed 化）
- `run_impl_pipeline` の Stage A 実行 case 直後・Stage B 開始直前に gate
  ブロックを 1 つ挿入（Stage A skipped path = START_STAGE=B|C でも通す）
- README.md の「オプション機能一覧」表に行追加 + 専用節「Stage A Verify Gate (#125)」
  を新設
- `tests/local-watcher/stage-a-verify/` 配下に 12 fixture + extract-driver.sh
  を新設

## ファイル一覧

### 追加

- `tests/local-watcher/stage-a-verify/extract-driver.sh` — 抽出関数の回帰 driver
- `tests/local-watcher/stage-a-verify/fixtures/tasks-{gradlew,npm,cargo,go,pytest,make,bundle,shellcheck,no-verify,deferrable,mixed,empty}.md` — 12 fixture
- `docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/impl-notes.md` — 本ファイル

### 変更

- `local-watcher/bin/issue-watcher.sh` — env 3 種追加、Stage A Verify Module
  helper 群追加（11 関数）、`run_impl_pipeline` 関数ヘッダコメント追記 + gate
  ブロック挿入
- `README.md` — オプション機能一覧表に 1 行追加、Stage A Verify Gate 専用節新設
- `docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/tasks.md` —
  進捗 checkbox 更新（実装 commit と別 commit）

## AC Traceability（requirements.md numeric ID → 担保）

| AC | 担保手段 | 検証ケース |
|---|---|---|
| 1.1 tasks.md 末尾逆順走査・keyword 一致 1 行特定 | `stage_a_verify_extract_command` awk 1 パス | fixture `tasks-gradlew.md` / driver pass |
| 1.2 複数候補時は末尾選択 | awk の「最後の一致を last に保持して END で出力」パターン | fixture `tasks-npm.md`（`npm run lint` と `npm test` の 2 候補、末尾 `npm test` 選択を確認） + `tasks-mixed.md`（`npm run build` と `./gradlew assembleDebug && ./gradlew test` の混在で末尾 gradlew 選択） |
| 1.3 複合コマンド (`&&` 等) は行全体を `bash -c` に渡す | `bash -c "$cmd"` 内で shell 解釈 | fixture `tasks-cargo.md`（`cargo build && cargo test`）/ driver pass + 手動スモーク Case 4 |
| 1.4 一致行なし → SKIPPED で継続 | `stage_a_verify_resolve_command` exit 1 → `stage_a_verify_run` SKIPPED 分岐 | fixture `tasks-no-verify.md` / `tasks-empty.md` + 手動スモーク Case 2/3 |
| 1.5 keyword 集合は言語非依存文字列パターンのみ | 関数内 `_SAV_KEYWORDS` 改行区切り文字列 + `index()` 部分一致 | 実装レビューで AST 解析・言語固有 parser を含まないことを確認 |
| 2.1 REPO_DIR を cwd として再実行・exit code / timeout 観測 | `(cd "$REPO_DIR" && timeout ... bash -c "$cmd")` | 手動スモーク Case 4-8 |
| 2.2 exit 0 → Stage A 完全完了 + Stage B 進行 | `case 0)` で `return 0` + `run_impl_pipeline` 続行 | 手動スモーク Case 4/8 |
| 2.3 exit ≠ 0 → Stage B に進まず | `case *)` で `_sav_handle_failure` 経由 return 1/2 + `run_impl_pipeline` 内 `return 1` | 手動スモーク Case 5/6 |
| 2.4 TIMEOUT 超過 → 打ち切り + 不完全扱い | `timeout --kill-after=10` + `case 124)` 分岐 | 手動スモーク Case 7 |
| 2.5 REPO_DIR 範囲内実行・副作用なし | subshell `(cd && ...)` で cwd 隔離、env を export しない | 実装レビュー |
| 3.1 1 回目失敗 → Developer 差し戻し + 2 回目試行許可 | `_sav_handle_failure` round=1 分岐: sidecar bump + gh issue comment + return 1 | 手動スモーク Case 5（sidecar=1 を確認） |
| 3.2 2 回目失敗 → claude-failed + 処理打ち切り | `_sav_handle_failure` round=2 分岐: `mark_issue_failed` + return 2 | 手動スモーク Case 6（STUB mark_issue_failed 呼び出しを確認） |
| 3.3 失敗回数を Issue #122 pr-iteration round 上限と整合（max 1 回差し戻し） | round=1 で差し戻し / round=2 で escalate 固定（独立 env を増やさない） | 設計判断、設計レビュー済 |
| 4.1 `STAGE_A_VERIFY_ENABLED=false` 時は導入前と同一の Stage A 完了判定 | Gate 1 で即 return 0、`run_impl_pipeline` 挿入ブロックも `case 0) :` で no-op | 手動スモーク Case 1/9 |
| 4.2 `STAGE_A_VERIFY_ENABLED` 既定 true | `STAGE_A_VERIFY_ENABLED="${STAGE_A_VERIFY_ENABLED:-true}"` | Config ブロック実装で確認 |
| 4.3 `STAGE_A_VERIFY_TIMEOUT` 既定 600、env で上書き可 | `STAGE_A_VERIFY_TIMEOUT="${STAGE_A_VERIFY_TIMEOUT:-600}"` + `timeout "$_timeout"` | 手動スモーク Case 7 (`STAGE_A_VERIFY_TIMEOUT=1` で 1 秒打ち切り) |
| 4.4 `STAGE_A_VERIFY_COMMAND` 非空時は tasks.md bypass | `stage_a_verify_resolve_command` 冒頭で env 優先 | 手動スモーク Case 4/5/6/7 |
| 4.5 既存 env 名 / 既定値を変更しない | Config ブロック既存行を改変せず、新 env のみ追加 | 実装 diff レビュー |
| 5.1 `stage-a-verify:` 始まり結果行を 1 件以上出力 | 全 5 分岐（DISABLED/SKIPPED/SUCCESS/FAILED/TIMEOUT）で `sav_log` 呼び出し | 手動スモーク全 Case で 1 行以上を確認 |
| 5.2 行頭 `[$REPO]` prefix 付与（Issue #119 規約） | `sav_log` 実装 `[$(date)] [$REPO] stage-a-verify:` 形式 | 手動スモーク全 Case 出力で `[test-owner/test-repo]` を確認 |
| 5.3 SKIPPED 時の reason 文字列 | `sav_log "SKIPPED reason=no-verify-task-in-tasks-md"` | 手動スモーク Case 2/3 |
| 5.4 DISABLED 時の結果行 | `sav_log "DISABLED reason=env-opt-out"` | 手動スモーク Case 1/9 |
| 5.5 成功 / 失敗 + exit code / timeout 識別 | `SUCCESS exit=0` / `FAILED exit=N` / `TIMEOUT timeout=Ss exit=124` | 手動スモーク Case 4-8 |
| 6.1 Reviewer 判定カテゴリ不変 | `.claude/agents/reviewer.md` を変更していない | git diff で確認 |
| 6.2 PjM の責務不変 | `.claude/agents/project-manager.md` を変更していない | git diff で確認 |
| 6.3 Developer の責務不変 | `.claude/agents/developer.md` を変更していない | git diff で確認 |
| NFR 1.1 opt-out 時の user-observable 同一性 | DISABLED 即 return + 挿入ブロック no-op | 手動スモーク Case 9（stage-a-verify ログ 1 行以外の干渉なし） |
| NFR 1.2 既存ラベル名 / 遷移契約不変 | `needs-iteration` を Issue 側に付与しない既存契約踏襲、`claude-failed` のみ既存 `mark_issue_failed` 経由 | 実装 diff レビュー |
| NFR 1.3 既存 exit code 意味維持 | `stage_a_verify_run` 内部の 0/1/2 は `run_impl_pipeline` 側で 0/1 にマップ | 実装 diff レビュー |
| NFR 2.1 抽出 keyword 集合のみで言語非依存 | `command -v node` 等を一切呼ばない | 実装レビュー |
| NFR 2.2 escape hatch `STAGE_A_VERIFY_COMMAND` | `stage_a_verify_resolve_command` 経路 | 手動スモーク Case 4-7 |
| NFR 3.1 抽出 O(N) | awk 1 パス | 実装レビュー |
| NFR 3.2 verify 再実行を `STAGE_A_VERIFY_TIMEOUT` 以下に制限 | `timeout "$_timeout"` | 手動スモーク Case 7 |
| NFR 3.3 env で秒単位延長可 | `STAGE_A_VERIFY_TIMEOUT` env 上書き | Case 7 で `STAGE_A_VERIFY_TIMEOUT=1` の override 動作確認 |
| NFR 4.1 全結果を 1 行以上記録 | 全 5 分岐で `sav_log` | 手動スモーク全 Case |
| NFR 4.2 `grep '\[.*\] stage-a-verify:'` で全件抽出可能 | 固定 prefix `[$(date)] [$REPO] stage-a-verify:` | 手動スモーク出力で確認 |
| NFR 5.1 REPO_DIR 範囲内実行・外側書き込みなし | subshell + `cd "$REPO_DIR"` | 実装レビュー |
| NFR 5.2 タイムアウト時の子孫プロセス停止 | `timeout --kill-after=10 "$_timeout"` | 手動スモーク Case 7（sleep 5 が 1 秒で打ち切り = SIGKILL 動作） |
| NFR 6.1 keyword 集合の fixture テスト | `tests/local-watcher/stage-a-verify/{fixtures,extract-driver.sh}` 全 12 fixture pass | `bash tests/local-watcher/stage-a-verify/extract-driver.sh` で確認 |
| NFR 6.2 既存テストパス + Req 1-5 カバー | 既存テストは存在しないため非該当。Req 1-5 カバーは extract-driver + smoke で担保 | extract-driver pass=12, smoke 全 9 Case pass |

## 手動スモークテスト結果

### Static analysis

- `shellcheck local-watcher/bin/issue-watcher.sh` — 警告ゼロ。SC2317 (info,
  unreachable code) と SC2012 (info, ls vs find) は既存 logger 関数群 / 既存
  `find` 使用箇所と同じ既存 info で、本機能で増えていない。
- `shellcheck install.sh setup.sh .github/scripts/*.sh
  tests/local-watcher/stage-a-verify/extract-driver.sh` — 警告ゼロ。
- `actionlint` — 環境未インストールのためスキップ。`.github/workflows/` は
  本機能で 1 byte も変更していないため影響なし。

### fixture テスト

```
$ bash tests/local-watcher/stage-a-verify/extract-driver.sh
  ok   tasks-bundle.md
  ok   tasks-cargo.md
  ok   tasks-deferrable.md
  ok   tasks-empty.md
  ok   tasks-go.md
  ok   tasks-gradlew.md
  ok   tasks-make.md
  ok   tasks-mixed.md
  ok   tasks-no-verify.md
  ok   tasks-npm.md
  ok   tasks-pytest.md
  ok   tasks-shellcheck.md

summary: pass=12 fail=0 total=12
```

### `stage_a_verify_run` 全 9 ケース手動検証

helpers + `stage_a_verify_run` + `_sav_handle_failure` を関数単位で
extract して source し、`mark_issue_failed` / `gh` をスタブ化した状態で
9 ケースを実行（出力は `/tmp/sav-disable-test.sh` から再現可能）:

| Case | env / 入力 | 期待 | 実測 |
|---|---|---|---|
| 1 | `STAGE_A_VERIFY_ENABLED=false` | DISABLED 1 行 + rc=0 | OK |
| 2 | tasks.md 不在 | SKIPPED 1 行 + rc=0 | OK |
| 3 | tasks.md あり / keyword 一致なし | SKIPPED 1 行 + rc=0 | OK |
| 4 | `STAGE_A_VERIFY_COMMAND=true` | EXEC + SUCCESS 2 行 + rc=0 | OK |
| 5 | `STAGE_A_VERIFY_COMMAND="exit 1"` (round 1 目) | EXEC + FAILED + round=1 + rc=1, sidecar="1" | OK |
| 6 | 同上 (round 2 目) | EXEC + FAILED + round=2 + mark_issue_failed + rc=2, sidecar 削除 | OK |
| 7 | `STAGE_A_VERIFY_COMMAND="sleep 5" STAGE_A_VERIFY_TIMEOUT=1` | EXEC + TIMEOUT(exit=124) + round=1 + rc=1 | OK（実測 ~1 秒で打ち切り） |
| 8 | tasks.md に `shellcheck --version` を末尾配置 / env 未指定 | tasks.md 抽出 → EXEC + SUCCESS + rc=0 | OK |
| 9 | `STAGE_A_VERIFY_ENABLED=false` で stdout 行数確認 | 1 行のみ（DISABLED ログ）/ 他干渉なし | OK |

### dry run（対象 Issue なし状態の watcher 起動）

```
REPO=hitoshiichikawa/idd-claude REPO_DIR=/tmp/sav-smoke \
  LOG_DIR=/tmp/sav-smoke-logs LOCK_FILE=/tmp/sav-smoke.lock \
  bash local-watcher/bin/issue-watcher.sh
```

`fatal: 'origin' does not appear to be a git repository` で exit 128
（リモート origin 未設定のため。本機能には起因しない既存挙動）。Issue
pickup フローは走らず、`stage-a-verify:` ログは出力されない（gate 自体
が pickup 後にしか呼ばれないため）。E2E 検証は dogfooding で別途実施
予定。

## 確認事項

以下、Reviewer / PjM レビュー時に確認してほしい設計判断・解釈点:

### 1. tasks.md L118「opt-out 時に stage-a-verify ログが 1 行も出ない」と Req 5.4 の整合

`tasks.md` L118 の手動スモーク項目は「opt-out 検証: cron.log に
`stage-a-verify:` 行が **1 行も出ないこと**（NFR 1.1）」と書いているが、
`requirements.md` Req 5.4 は「`STAGE_A_VERIFY_ENABLED=false` により本機能が
無効化されているとき、ログに `stage-a-verify: DISABLED` を含む結果行を 1 件
記録する」と明示している。

実装は **Req 5.4 を優先** し、DISABLED 時に `sav_log "DISABLED reason=env-opt-out"`
を 1 行出している。これは NFR 1.1 の「user-observable に同一の Stage A 完了
判定」を満たしながら、DISABLED の事実をログで観測できる利点があるため。

ただし、既存の Stage Checkpoint (#68) の opt-out 挙動は README L2693 で
「`stage-checkpoint:` prefix のログ行は 1 行も出ません」となっており、
本機能はこの方針と微妙にずれている。**Req 5.4 を厳格に従う**か、**Stage
Checkpoint と同じ「opt-out 時にログを 1 行も出さない」方針に倒す** かは
PM / Architect 判断の余地がある。

差し戻し方針が確定したら次回イテレーションで実装変更する。

### 2. tasks.md の verify コマンド表記揺れ（バックティック / コードフェンス）

実装は tasks.md の verify 行を「bullet 直下に裸でコマンド」が書かれる慣習
を前提としている（fixture もすべてそれに従って作成）。一方、実環境では
`` `npm test` `` のようにインラインコードフェンスで囲まれた表記や、
` ```bash ` 〜 ` ``` ` のコードブロック内の表記もあり得る。

現状の実装はインラインバックティックを strip しないので、`- ` `` `npm test` ``
のような書き方では `` `npm test` `` がそのまま抽出され、bash -c に渡された
ときに `` ` `` がコマンド置換と解釈されて意図しない動作になる可能性がある。

design.md / requirements.md にバックティック扱いの明示はなかったため、
**実装判断として「裸コマンド前提」とした**。dogfooding で誤検出を観測したら
fixture を追加して strip 規則を強化する方針。

→ idd-claude 自身の `tasks.md` 末尾（task 7）の verify は
   `shellcheck local-watcher/bin/issue-watcher.sh ...` の形式で書かれて
   おり、裸表記前提と整合している。

### 3. `npm test` を末尾選択する場合の precedence

fixture `tasks-npm.md` で `npm run lint` と `npm test` の両方が含まれる
ときに `npm test` が選ばれる挙動を確認したが、これは「タスクの**実行順**で
末尾」であり、「verify として優先度が高いほうを選ぶ」という意味ではない。
複数候補がある repo では運用者が末尾に最重要 verify を置く慣習が必要。
README にその旨を追記しなかったが、必要なら次回 PR で補強する。

### 4. round counter sidecar の commit 漏れリスク

`$REPO_DIR/<spec_dir>/.stage-a-verify-round` は dotfile かつ `docs/specs/<番号>-*/`
配下に置かれる。Developer が `git add docs/specs/*` で一括 add すると sidecar
も追跡対象になる可能性がある。

実装は `.gitignore` の自動追記を **しない**（運用者の `.gitignore` を勝手に
書き換えないポリシー、design.md L598-L602）。これは仕様通り。仮に sidecar が
誤 commit されても、次 SUCCESS 時に `_reset_round` で削除されるため最終状態は
等価。

### 5. tasks.md L107 の deferrable 6.2 を省略した判断

tasks.md L104-109 の 6.2 は deferrable で「実装段階で判断してよい」と明示
されている。判断結果として **省略** した。理由:

- `.claude/agents/reviewer.md` は既に「AC 未カバー / missing test /
  boundary 逸脱の 3 カテゴリに限定」と明文化されており、stage-a-verify が
  Reviewer の責務範囲を増やしていないことは構造的に明白
- `.claude/agents/developer.md` も `tasks.md` 実装と commit のみが責務
  であり、stage-a-verify は Developer に何も追加義務を課していない
- root `CLAUDE.md` 内に同等の補強を入れると、責務文の重複が冗長になる

差し戻しがあれば次回 PR で追記する。

## 次の Issue として切り出すべき派生タスク

- **派生タスク 1**: バックティック / コードフェンス装飾を含む verify 行の
  抽出強化（上記「確認事項 2」）。dogfooding で誤検出が観測されたら起票
- **派生タスク 2**: Stage B / Stage C への同等 verify gate 追加（本 Issue
  Non-Goal）。Stage B 後に Reviewer 成果物が test 通っているかの再 verify
  などが検討候補
- **派生タスク 3**: deferrable 5.3（smoke test driver）の実装。本実装の
  Case 1-9 が `/tmp/sav-disable-test.sh` として 1 回限りの手動 script で
  終わっているため、`tests/local-watcher/stage-a-verify/smoke.sh` として
  repo に取り込む価値あり

## Feature Flag Protocol

本 repo `CLAUDE.md` は `## Feature Flag Protocol` 節を持たず、規約上
**opt-out として解釈**される（feature-flag.md Req 1.3）。よって本実装は
flag 裏実装パターン（`if (flag) { 新挙動 } else { 旧挙動 }`）を採用せず、
通常の単一実装パスで提供する。代わりに env `STAGE_A_VERIFY_ENABLED=false`
（**default=true で初期配置**）によって本機能導入前と user-observable に同一
挙動への opt-out を担保する（README の「オプション機能一覧」既存パターンと
同形式）。
