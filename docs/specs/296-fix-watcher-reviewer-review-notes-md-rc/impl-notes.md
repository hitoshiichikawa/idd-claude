# Implementation Notes — Issue #296

## 採用方針

debugger 分析の **多層防御「案 D + 案 A」** を採用（案 C は本 Issue のスコープ外として
別 Issue 化を推奨）。

- **案 D（戻り値分離）**: `parse_review_result` の戻り値を細分化し、ファイル不在を
  装飾起因 parse 失敗 (rc=2) と区別する **rc=3** を新設した。
- **案 A（1 回限定リトライ）**: `run_reviewer_stage` / `run_per_task_reviewer` の内部で
  ファイル不在検出 (parse rc=3) 時に **同一 round 内で claude を 1 回だけ再起動**し、
  再起動後もファイル不在なら関数が **rc=4** を返す。呼び出し側 6 箇所で rc=4 を受けたら
  `reviewer-missing-file` / `per-task-reviewer-missing-file` カテゴリで `claude-failed` を
  付与する。装飾起因 parse 失敗 (rc=2) と grep で区別可能な reason・stage 識別子を出力する。
- **案 C は別 Issue へ**: `repo-template/.claude/agents/reviewer.md` の出力契約強化
  （Write 完了後の Read 再読込・最終行 verify・終了前 `ls` 出力）は、テンプレ配布の影響範囲が
  既 installed consumer repo まで及ぶため別 Issue に切ることを推奨。requirements.md
  「Out of Scope」と「Open Questions」にも明記済み。

### Open Questions の判断

- **リトライ回数 = 1 回限定** で確定（requirements 推奨どおり / NFR 3.1 と整合）
- **戻り値設計 = 新 rc 追加** （rc=3 / rc=4）で確定。reason 文字列のみで区別する案は
  呼び出し側に grep 抜き出しを要求する分かりにくさがあるため不採用。
- **リトライ時 `--max-turns` は同一値** で確定（`$REVIEWER_MAX_TURNS` をそのまま再利用）。
  初回 Write 漏れが Reviewer の context 不足によるものか subagent 内部の writeup 漏れかは
  事前判定不能なため、安全側に倒して同一値とした。

## 戻り値の対応表

| 関数 | rc=0 | rc=1 | rc=2 | rc=3 | rc=4 | rc=99 |
|---|---|---|---|---|---|---|
| `parse_review_result` | OK | — | ファイルあり RESULT 抽出失敗（装飾起因） | **ファイル不在（新規）** | — | — |
| `run_reviewer_stage` | approve | reject | claude crash / parse-failed (rc=2) | — | **missing-file-after-retry（新規）** | quota |
| `run_per_task_reviewer` | approve | reject | claude crash / parse-failed (rc=2) | diff-range-resolve-failed | **missing-file-after-retry（新規）** | quota |

per-task の rc=3 は既存 Issue #164 で diff-range 解決失敗に割り当て済みのため、本 Issue で
追加する missing-file は rc=4 を採用（rc 値の衝突回避）。単発 reviewer も統一して rc=4 とした。

## 変更ファイル一覧

- `local-watcher/bin/issue-watcher.sh` — Parser + Reviewer 起動関数 + 6 caller site の更新
  - `parse_review_result()`: ファイル不在で rc=3 を返す（旧 rc=2 から変更）
  - `run_reviewer_stage()`: attempt 1/2 のリトライループ導入 + rc=4 終了経路追加
  - `run_per_task_reviewer()`: 同上（rc 値は per-task の既存 rc=3 と衝突しない rc=4 を使用）
  - 単発 reviewer 呼び出し 3 箇所（round=1 / round=2 / round=3 Debugger 経由）に rc=4 case 追加
  - per-task reviewer 呼び出し 3 箇所（round=1 / round=2 / round=3 Debugger 経由）に rc=4 case 追加
- `local-watcher/test/parse_review_result_test.sh` — missing file の期待 rc を 2 → 3 に変更、
  装飾耐性パース (#63 リグレッション防止) のテストケース 4 件を追加
- `docs/specs/296-fix-watcher-reviewer-review-notes-md-rc/test-fixtures/test-retry-loop.sh` —
  retry loop 挙動の fixture-based スモークテスト（11 アサーション）

## AC 達成確認（requirement ID → テスト対応）

| Req ID | テスト / 検証手段 |
|---|---|
| 1.1 ファイル不在の専用シグナル | `parse_review_result_test.sh` "missing file: parse rc=3" |
| 1.2 装飾起因 parse 失敗の区別 | `parse_review_result_test.sh` "no-result: parse rc=2" |
| 1.3 ログ上の reason 区別 | `test-retry-loop.sh` Pattern B 検証 + 実装側の `reason=missing-file` / `reason=missing-file-after-retry` / `reason=parse-failed` を別文字列で出力 |
| 2.1 同一 round 内 1 回再起動 | `test-retry-loop.sh` Pattern A / B（claude 起動回数=2 を assert） |
| 2.2 再起動成功時の正常合流 | `test-retry-loop.sh` Pattern A（rc=0 を assert） |
| 2.3 再起動失敗時の `missing-file` reason `claude-failed` | `test-retry-loop.sh` Pattern B + 実装側 `mark_issue_failed "reviewer-missing-file"` / `"per-task-reviewer-missing-file"` |
| 2.4 / NFR 3.1 リトライ上限 1 回 | `test-retry-loop.sh` Pattern B（attempt count=2 を assert） |
| 2.5 / NFR 2.1 ログ識別子 | 実装側 `rv_log` / `pt_log` に round / attempt / reason を 1 行で記録 |
| 3.1 / 3.2 / 3.3 口頭申告を採用しない | 実装変更なし（既存挙動。`parse_review_result` は `notes_path` の RESULT トークンのみを見て判定し、orchestrator 最終メッセージ / トランスクリプト本文には触れていない） |
| 4.1 / 4.2 / 4.3 単発 / per-task / Debugger 経由対称 | `run_reviewer_stage`（単発・Debugger 経由 round=3 共用）と `run_per_task_reviewer`（per-task 全 round 共用）に対称実装 |
| 5.1 装飾耐性パース維持 | `parse_review_result_test.sh` 新規 4 ケース（inline-approve / reject backticks, multi-last-wins）で rc=0 維持を assert |
| 5.2 「最後マッチ採用」維持 | `parse_review_result_test.sh` multi-last-wins-{approve,reject} rc=0 維持 |
| 5.3 装飾起因はリトライしない | `test-retry-loop.sh` Pattern D（rc=2 → 起動回数=1 を assert） |
| NFR 1.1 / 1.2 既存挙動互換 | `parse_review_result_test.sh` 既存 19 ケース全て継続 PASS + `test-retry-loop.sh` Pattern C（即時 approve / 起動回数=1） |
| NFR 2.2 grep で区別可能 | `reason=missing-file-after-retry` / `reviewer-missing-file` stage 識別子（既存 `parse-failed` / `reviewer-error` と異なる文字列） |

## 実行したテストとその結果

```bash
$ bash local-watcher/test/parse_review_result_test.sh
PASS: 23, FAIL: 0

$ bash docs/specs/296-fix-watcher-reviewer-review-notes-md-rc/test-fixtures/test-retry-loop.sh
PASS: 11, FAIL: 0

$ for t in local-watcher/test/*.sh; do bash "$t"; done
(全 17 テストスイート PASS、FAIL=0)

$ shellcheck local-watcher/bin/issue-watcher.sh \
            local-watcher/test/parse_review_result_test.sh \
            docs/specs/296-fix-watcher-reviewer-review-notes-md-rc/test-fixtures/test-retry-loop.sh
(警告ゼロ)

$ bash -n local-watcher/bin/issue-watcher.sh
syntax OK

$ diff -r .claude/agents repo-template/.claude/agents
(差分なし — 本変更は agents 配下を触っていない)

$ diff -r .claude/rules repo-template/.claude/rules
(差分なし — 本変更は rules 配下を触っていない)
```

## 既存 fixture / consumer repo への影響

### 旧 rc=2 → 新 rc=3 への移行影響

- `parse_review_result` を **直接呼ぶ箇所は本 repo 内 5 箇所**（`grep -n "parse_review_result"` で
  確認済 / `run_reviewer_stage` 内 1 / `run_per_task_reviewer` 内 1 / per-task 呼び出し側 reject2
  メッセージ用 1 / 単発 reviewer-reject3 メッセージ用 1 / 単発 reviewer-reject2 メッセージ用 1）。
- リトライループ内の 2 呼び出しは新たに rc=3 を case 文で処理する（リトライ発火）。
- reject2 / reject3 メッセージ生成用の 3 呼び出しは `parse_review_result ... 2>/dev/null || echo ""`
  パターンで失敗時に空文字を返すため、rc=2 → rc=3 への変更で挙動が変わらない（いずれも非 0
  rc を `|| echo ""` で握り潰す）。
- consumer repo 側で本 watcher スクリプトを直接呼んでいる箇所は無い（watcher は本 repo の
  `local-watcher/bin/issue-watcher.sh` でのみ稼働）。
- **後方互換性**: 既存正常系（ファイルあり + RESULT 抽出成功）の挙動は同値（NFR 1.2）。
  既存異常系のうち「ファイルあり + RESULT 抽出失敗」は引き続き rc=2 経路で `reviewer-error`
  カテゴリ `claude-failed` 付与（既存挙動と同値）。新規分岐は「ファイル不在」のみ。

### Self-hosting (dogfooding) 影響

- 本変更は watcher 自身が次サイクルで稼働する。CLAUDE.md「self-hosting」規約どおり、
  既存 env var 名・exit code 意味・ラベル名・cron 文字列は一切変更していない（NFR 1.1）。
- 新規 `claude-failed` stage 識別子 `reviewer-missing-file` / `per-task-reviewer-missing-file`
  は既存 `reviewer-error` / `per-task-reviewer-error` とは別カテゴリ。grep ベース失敗集計
  をしている下流運用があれば追加対応が必要だが、idd-claude 本体には該当する集計コードはない
  （`mark_issue_failed` は引数識別子を Issue コメント本文に埋め込むのみで、内部分岐に使っていない）。

## 確認事項（人間判断を仰ぐ事項）

- **案 C を別 Issue 化する判断**: `repo-template/.claude/agents/reviewer.md` の Write 完了後
  Read 再読込 / `ls` 出力 / 最終行 verify は本 Issue 範囲外として未実装。Issue 本文「判断を
  委ねたい点」および requirements.md「Out of Scope」「Open Questions」と整合。テンプレ
  配布の影響範囲が広いため別 Issue として起票することを推奨。
- **リトライ時 max-turns の削減判断**: 本実装では同一値 (`$REVIEWER_MAX_TURNS`) を再利用した。
  将来的にリトライを高速化したい場合は別途 env var (`REVIEWER_RETRY_MAX_TURNS` 等) を導入する
  余地があるが、現時点では over-engineering を避けて固定値とした。
- **`reviewer-missing-file` を `reviewer-error` の sub-category として扱うか別カテゴリ化するか**:
  本実装では別カテゴリ（NFR 2.2 の「grep で区別可能」要件を直接満たすため）。下流の運用ログ
  集計コードがあれば移行が必要だが、idd-claude 本体には現状無い。

## まとめ

Issue #296 の AC 全 16 件（Req 1.1〜5.3 + NFR 1.1〜3.2）を満たす実装を完了。テスト総数は
`parse_review_result_test.sh` 23 件 + `test-retry-loop.sh` 11 件 + 既存全テスト 17 ファイル
継続 PASS。shellcheck 警告ゼロ。dual-management diff 空（本変更は agents / rules 配下を
触らない）。
