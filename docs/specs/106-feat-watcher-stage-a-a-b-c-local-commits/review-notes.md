# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-15T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-106-impl-feat-watcher-stage-a-a-b-c-local-commits
- HEAD commit: 06a3846ff328cace01e6a33ac9d95b7d55ec0a60
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh`（+165 / -2 行：`verify_pushed_or_retry` ヘルパ追加と Stage A / A' / B 完了路への呼出注入）
  - `local-watcher/test/verify_pushed_or_retry_test.sh`（新規 +330 行：4 ケース 17 アサーション）
  - `docs/specs/106-.../requirements.md`（+155 行：PM 成果物）
  - `docs/specs/106-.../impl-notes.md`（+152 行：Developer 成果物）
- tasks.md / design.md は存在しない（Issue #106 は Architect 起動なしのフロー）。Boundary 判定は requirements.md の Out of Scope 節 / impl-notes.md の File Structure に照らして実施。
- CLAUDE.md の `## Feature Flag Protocol` 節は **存在しない** → opt-out として解釈し、flag 観点の追加判定は行わない（reviewer.md の Req 4.1, 4.2 / NFR 1.1 に従う）。

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` Stage A `case "$_qa_rc_a" in 0)` 分岐 (line 3413-3422) で `verify_pushed_or_retry "stageA-push-missing" "$BRANCH" "Stage A"` を成功メッセージ `echo "✅ #$NUMBER: Stage A 完了"` の前に呼び出している。
- 1.2 — `verify_pushed_or_retry` 内 `qa_warn "${stage_label} push-state verify: ahead=${ahead_count} ..."` で ahead 数値と stage 識別子を WARN レベルで `$LOG` に記録。test Case 2 (`$LOG` に "auto-push retry" 行) で担保。
- 1.3 — `verify_pushed_or_retry` の `if [ "$ahead_count" = "0" ]; then return 0; fi` で副作用なし即帰還。test Case 1（rc=0、`$LOG` 行数 0）で担保。
- 1.4 — `ahead_count` が数値でない（`git rev-list` の空文字 / 失敗）場合 `ahead_count="unknown"` とし、push リトライ経路（安全側）へ進む。impl-notes Case 4 で `unknown` 経由の log/動作も検証。
- 2.1 — Stage A' `case "$_qa_rc_aredo" in 0)` 分岐 (line 3493-3501) で `verify_pushed_or_retry "stageA-prime-push-missing" "$BRANCH" "Stage A'"` を成功メッセージ前に呼び出している。
- 2.2 — Stage A' label でも 1.2 と同じ `qa_warn` 行を出力（共通ヘルパで担保）。
- 2.3 — Stage A' でも ahead == 0 即帰還（共通ヘルパ。test Case 1 で担保）。
- 3.1 — Stage B Reviewer 各分岐に verify を挿入。round=1 approve (line 3452-3460) / round=1 reject (line 3467-3475) / round=2 approve (line 3522-3529) / round=2 reject (line 3536-3542) の 4 経路全てを網羅。round=2 reject のみ `|| true` で best-effort（reviewer-reject2 の情報量を優先する design judgment、impl-notes に明記）。
- 3.2 — Stage B label でも 1.2 と同じ `qa_warn` 行を出力（共通ヘルパ）。
- 3.3 — Stage B でも ahead == 0 即帰還（共通ヘルパ。test Case 1 で担保）。
- 3.4 — `stage_label` 引数として `"Stage B (round=1 approve)"` / `"Stage B (round=1 reject)"` / `"Stage B (round=2 approve)"` / `"Stage B (round=2 reject)"` を渡し、`qa_warn` と `echo` の両方の log 行で識別可能。test Case 4 で `$LOG` 内の "Stage B (round=1 approve)" 文字列の存在を検証。
- 4.1 — `verify_pushed_or_retry` 内に loop は無く、`git push origin "$branch"` を **1 回だけ** 実行。test Case 3 / Case 4 で push 失敗時の単発実行を確認。
- 4.2 — push 成功時 `qa_warn ... auto-push retry SUCCESS` + `echo ... 自動 push リトライ成功 → 継続` を `$LOG` に追記し `return 0`。test Case 2 で rc=0 と $LOG の "auto-push retry" 行を確認。
- 4.3 — push 成功時 `gh issue comment "${NUMBER}" --repo "$REPO" --body "$comment_body"` を呼び出し、`comment_body` に Issue 番号 / stage 識別子 / branch / 復旧 commit 数を含める。test Case 2 で gh args に "106" / body に "stageA-push-missing" / "復旧 commit 数: 2" を含むことを検証。
- 4.4 — push 失敗時 `mark_issue_failed "$stage_id" "$fail_body"` を呼び、stage 識別子は呼出側から `stageA-push-missing` / `stageA-prime-push-missing` / `stageB-push-missing` のいずれかが渡される。test Case 3 で `stageA-prime-push-missing`、Case 4 で `stageB-push-missing` の伝搬を検証。
- 4.5 — push 失敗時 `return 1` を返し、呼出側 (`if ! verify_pushed_or_retry ...; then return 1; fi`) が `echo "✅ ... 完了"` に到達せず即抜ける（round=2 reject 例外除く）。test Case 3 で `$LOG` に "Stage A' 完了" 文言が出ないことを検証。
- 4.6 — リトライ 1 回上限を loop 無しで担保。test Case 3 / Case 4 で `mark_issue_failed` が即発火し再試行が無いことを確認。
- 5.1 — ahead == 0 ケースで `verify_pushed_or_retry` は副作用なく `return 0`。test Case 1 で `$LOG` 行数 0 を検証。既存の `echo "✅ #$NUMBER: Stage X 完了"` / `tee -a "$LOG"` の挙動は不変。
- 5.2 — 既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `BRANCH` / `NUMBER` / `LOG` 等）は読み取りのみで変更なし。stage 終了コードの意味（0 / 99 / その他）も改変していない（verify 失敗は呼出側の `return 1` 経路で既存 `claude-failed` 経路に合流する）。
- 5.3 — 失敗時は既存 `mark_issue_failed` 経由で既存ラベル `claude-failed` を付与するのみ。新ラベル導入なし、既存ラベル削除なし。
- 6.1 — `local-watcher/test/verify_pushed_or_retry_test.sh` Case 2（ahead > 0 + push 成功 → return 0 / mark_issue_failed 未呼出 / bare 側に commit 到達）。
- 6.2 — 同テスト Case 3（ahead > 0 + push 失敗 → return 1 / mark_issue_failed 呼出 / 虚偽成功メッセージなし）。
- 6.3 — 同テスト Case 1（ahead == 0 → return 0 / 副作用なし）。
- 6.4 — テストは `mktemp -d` 配下のローカル bare repo を fake origin、`gh` / `mark_issue_failed` を bash 関数で stub。GitHub API / 実 origin 呼び出しなし。本 reviewer 環境で `bash local-watcher/test/verify_pushed_or_retry_test.sh` 実行 → PASS: 17 / FAIL: 0 を確認。
- 6.5 — 既存 4 テスト（`parse_review_result_test.sh` PASS 19 / `qa_detect_rate_limit_test.sh` PASS 10 / `qa_run_claude_stage_test.sh` PASS 23 / `stagec_pr_verify_test.sh` PASS 8）を本 reviewer 環境で再実行し全 PASS / FAIL 0 を確認。
- NFR 1.1 — ahead == 0 経路は単一 `git rev-list --count @{u}..HEAD` で完結。本環境での test Case 1 実行も 1 秒未満で完了（実測 sub-second）。
- NFR 1.2 — `command -v timeout >/dev/null 2>&1` で GNU coreutils `timeout` の有無を判定し、ある環境（Linux / cron 主流）では `timeout 30` を prepend。`git rev-list` と `git push` の双方に 30 秒上限を付与。
- NFR 2.1 — `qa_warn` 1 行 + `echo "[$(date '+%F %T')] ${stage_label} ahead=${ahead_count} detected → auto-push retry 1/1 ..."` 1 行で stage 識別子 / ahead 数 / リトライ結果を識別可能な複数行として記録。test Case 2 で `auto-push retry` 行存在を確認。
- NFR 2.2 — Issue コメント body に `Issue #${NUMBER}` / `対象 stage : \`${stage_id}\`` / `対象 branch: \`${branch}\`` / `復旧 commit 数: ${ahead_count}` を含める。test Case 2 で全項目検証。
- NFR 2.3 — 失敗時 `qa_warn` 行に `stage_id / branch / push_rc / stderr_tail` を出力し、`mark_issue_failed` body にも Issue 番号 / stage 識別子 / branch / 未 push commit 数 / push exit code / git push stderr tail を全て含める（`fail_body` の構成を確認）。test Case 3 で body 内容を検証。
- NFR 3.1 — 追加依存 CLI なし（`timeout` は optional、無くても fallback 動作）。`~/bin/issue-watcher.sh` 配置先・cron / launchd 登録文字列・既存依存（`gh` / `jq` / `flock` / `git`）の前提を変更していない。
- NFR 3.2 — self-hosting 経路（idd-claude 自身を対象 repo として運用）にも同等に適用される（差分は単一 watcher スクリプト変更のため）。

## Boundary 確認

- `local-watcher/bin/issue-watcher.sh` への変更 → impl-notes.md および requirements.md の Introduction が想定する scope と一致。
- `local-watcher/test/verify_pushed_or_retry_test.sh` の追加 → Req 6.x が明示的に要求する `local-watcher/test/` 配下のテスト追加。
- Out of Scope 違反なし:
  - Stage C 改修なし
  - Developer / Reviewer / PjM プロンプト本文の改修なし（`.claude/agents/*.md` 無変更）
  - `qa_run_claude_stage` 共通 hook へのリファクタなし（既存呼出経路の前後に verify を挿入のみ）
  - `_slot_run_issue` 終了直前 sanity check の追加なし
  - 自動リトライ 2 回以上拡張なし（loop 無しの 1 回上限）
  - GitHub Actions 経路への移植なし（`.github/workflows/issue-to-pr.yml` 無変更）
  - Stage Checkpoint Resume 経路への追加 verify なし
  - `git rev-list --count @{u}..HEAD` 以外の指標への拡大なし
  - 自動 push 失敗時の Issue コメント投稿なし（失敗時は claude-failed + log のみ）

## Findings

なし。

## Summary

requirements.md の全 numeric ID（Req 1.1〜6.5、NFR 1.1〜3.2）に対応する実装またはテストが、`verify_pushed_or_retry` ヘルパー / Stage A / A' / B(×4 分岐) 呼出 / `verify_pushed_or_retry_test.sh` の組み合わせで網羅されている。Boundary 逸脱なし、Out of Scope 違反なし、Feature Flag Protocol は idd-claude 自体が opt-out のため flag 観点判定対象外。本 reviewer 環境で新規 17 ケース＋既存 60 ケースの計 77 ケース全て PASS を再現確認した。

RESULT: approve
