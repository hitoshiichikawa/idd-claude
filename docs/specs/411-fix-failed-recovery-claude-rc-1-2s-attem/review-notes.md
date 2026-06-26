# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-26T22:15:00Z -->

## Reviewed Scope

- Branch: claude/issue-411-impl-fix-failed-recovery-claude-rc-1-2s-attem
- HEAD commit: 7eb054c6de8ebdac01526b1508e52bad518483da
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh`, `local-watcher/bin/modules/failed-recovery.sh`,
  `local-watcher/test/fr_attempt_test.sh`, `local-watcher/test/fr_immediate_fail_test.sh` (new),
  `local-watcher/test/fr_invoke_test.sh`, `local-watcher/test/fr_process_test.sh`,
  `local-watcher/test/fr_state_test.sh`, `README.md`, `docs/specs/411-.../requirements.md`,
  `docs/specs/411-.../impl-notes.md`

## Verified Requirements

- 1.1 — `fr_run_recovery_attempt` rc=98 case で `fr_save_state` を prev_total へロールバック。
  `fr_immediate_fail_test.sh` Section C で `^fr_save_state 42 1 in-progress .* 1$` を検証
- 1.2 — `fr_classify_immediate_failure` 純粋関数で `rc!=0 AND quota 未検出 AND tool_use 未観測
  AND elapsed < threshold` を判定 + `fr_invoke_claude` が tool_use を `"type":"tool_use"` grep
  で観測。`fr_invoke_test.sh` Section 14 (A〜G) と Section 10/11/12 でカバー
- 1.3 — `issue-watcher.sh` で `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS` を既定 10 秒に正規化、
  非整数/0 以下を既定値に丸める。境界値テスト `fr_invoke_test.sh` Section 14-F (elapsed=9) /
  14-G (elapsed=10)
- 1.4 — `fr_save_state` 6 番目引数 `immediate_failure_streak` + JSON schema 拡張。
  `fr_state_test.sh` Section #411 で明示指定 save、継承、legacy state 0 fallback、不正値正規化
  を検証
- 1.5 — `fr_run_recovery_attempt` rc=98 時 streak ++ 後 `streak >= max_streak` で return 4 +
  事前判定で `prev_streak >= max_streak` も return 4。`fr_immediate_fail_test.sh` Section D/E、
  `fr_process_test.sh` Section 11 で dispatch 配線（rc=4 → `fr_terminate_immediate_failure_streak`）
  を検証
- 1.6 — `issue-watcher.sh` で `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK` 既定 3 / 非整数・0 以下
  を既定値に丸める。`fr_immediate_fail_test.sh` Section D で max=3 動作確認
- 1.7 — success path で `fr_save_state ... 0` を追加保存、通常失敗 path でも streak=0 reset save。
  `fr_immediate_fail_test.sh` Section F/G で検証
- 1.8 — `fr_classify_immediate_failure` 内 quota_detected==1 で `return 1`（通常扱い）+
  `fr_invoke_claude` の quota 早期 return 99 path は判定経路を通らない。
  `fr_invoke_test.sh` Section 13、Section 14-A
- 2.1 — `fr_invoke_claude` 2 段 tee (`primary_log` + `secondary_log`) で stdout/stderr を必ず
  専用ログに append。`fr_immediate_fail_test.sh` Section I で fr_invoke_claude に dedicated
  log path が渡されることを検証
- 2.2 — `fr_resolve_dedicated_log_path` が `$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log`
  を返す。`fr_immediate_fail_test.sh` Section A で `failed-recovery` / `issue` / `42` / `$LOG_DIR`
  を含むことを検証 + pr/100 ケース
- 2.3 — `failed-recovery-` プレフィックスを必ず含めることを Section A で検証
- 2.4 — `LOG_DIR` 未設定時 `$HOME/.issue-watcher/logs/$REPO_SLUG` フォールバック実装 +
  Section A で `LOG_DIR` unset 時に `/.issue-watcher/logs/` を含み `/dev/null` を含まないことを検証
- 2.5 — `fr_invoke_claude` start log に `dedicated_log=$effective_dedicated_log` を含めて
  fr_log 出力（impl-notes Section J で `repo_dir=` / `ref=` を併せて記録経路として検証）
- 2.6 — `fr_invoke_claude` 内 mkdir / truncate 失敗時 `fr_warn` + `effective_dedicated_log=""`
  fallback で /dev/null 行きにして recovery 自体は継続する fail-continue 実装（i/o エラー path
  は impl-notes 通り unit test 困難で shellcheck + 静的解析で担保）
- 3.1 — `fr_run_recovery_attempt` で `( cd "$REPO_DIR"; fr_invoke_claude ... )` の subshell
  isolation 経由で対象 repo の作業ツリー上で claude 起動。`fr_immediate_fail_test.sh` Section J
- 3.2 — `gh pr view --json headRefName` で head branch 解決 → `fr_prepare_repo_worktree` kind=pr
  分岐で `^claude/` 検証付き checkout
- 3.3 — `fr_prepare_repo_worktree` kind=issue 分岐: `git ls-remote --heads origin
  "claude/issue-<N>-*"` 先頭、無ければ `BASE_BRANCH` fallback。Section J で採用 ref を観測
- 3.4 — `fr_run_recovery_attempt` で worktree_ok=0 → `claude_rc=98` に倒し、即時失敗扱い経路へ。
  `fr_immediate_fail_test.sh` Section H で `fr_invoke_claude` 不呼出 + rollback save 検証
- 3.5 — `fr_prepare_repo_worktree` 冒頭 `repo_dir="${REPO_DIR:-}"` + `.git` 存在確認
- 3.6 — `fr_run_recovery_attempt` で `fr_log "... repo_dir=$REPO_DIR ref=$checkout_ref"`。
  Section J で `repo_dir=/tmp/fr-imm-test-stub-repo` / `ref=claude/issue-42-impl-test` 観測
- 4.1 — 新規 `fr_terminate_immediate_failure_streak` + 識別子 `immediate-failure-streak`。
  `fr_immediate_fail_test.sh` Section B で識別子を含むコメントと fr_log を検証
- 4.2 — `fr_log "${kind}=#${number} terminated reason=immediate-failure-streak ..."` で
  `grep` 抽出可能。Section B で `terminated reason=immediate-failure-streak` を検証
- 4.3 — `fr_post_attempt_comment` 1 回呼出 + body に streak_count（連続 3 回）と識別子を含む。
  Section B
- 4.4 — `fr_terminate_immediate_failure_streak` で `--remove-label` を呼ばない。Section B で
  `assert_not_grep "--remove-label"` 検証
- 4.5 — `rs_set_result "claude-failed"` 1 回呼出。Section B で `rs_set_result` が 1 回のみ呼ばれ
  内容が `claude-failed` であることを検証
- 4.6 — `sn_notify failed-recovery <num> <url> immediate-failure-streak "kind=... streak=..."`
  + signature 値を detail に含めない。Section B で `streak=3` 含む + `aaaa...` 不含を検証
- NFR 1.1 — 既存 env var / 既定値・ラベル名・終端識別子 (`max-attempts` / `no-progress`) は無変更。
  `fr_save_state` の 6 番目引数も省略時継承で既存呼出側互換。`fr_state_test.sh` Section #411
  「6 番目引数省略 → 既存 state から streak 継承」「legacy state (streak field 不在) を 0 fallback」
  で検証 + `fr_process_test.sh` Section 11-C で rc=2/3 経路に影響なし
- NFR 1.2 — `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10` / `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3`
  既定値 + 不正値 fallback
- NFR 1.3 — `max-attempts` / `no-progress` 文字列無変更（`fr_terminate_test.sh` PASS=77 既存挙動維持）
- NFR 1.4 — `fr_is_enabled` 無変更（二重 opt-in gate 維持）
- NFR 2.1 — `fr_log "claude session immediate-failure label=... rc=... tool_use=... elapsed=...s
  threshold=...s"` で判定根拠を一次運用ログに記録。`fr_invoke_test.sh` Section 10 で
  `immediate-failure` / `rc=1` / `tool_use=0` 観測を検証
- NFR 2.2 — dedicated_log path / repo_dir / checkout ref を一次運用ログに出力（Section J）
- NFR 3.1 — `fr_resolve_dedicated_log_path` / `fr_prepare_repo_worktree` /
  `fr_terminate_immediate_failure_streak` で kind は `issue|pr` のみ、number は `^[0-9]+$`、
  git checkout は `--` でオプション解釈打ち切り、`^claude/` 再検証。Section A / B で不正値ケース
- NFR 3.2 — `fr_terminate_immediate_failure_streak` のコメント本文 / sn_notify detail に signature
  を含めない。Section B で `assert_not_grep "aaaa..."` 検証

## Findings

なし

## Summary

`requirements.md` の全 numeric AC（Req 1.1〜1.8 / 2.1〜2.6 / 3.1〜3.6 / 4.1〜4.6 / NFR 1.1〜1.4 /
NFR 2.1〜2.2 / NFR 3.1〜3.2）について、`local-watcher/bin/modules/failed-recovery.sh` と
`local-watcher/bin/issue-watcher.sh` に対応実装が確認でき、`fr_immediate_fail_test.sh` (new) /
`fr_invoke_test.sh` Section 9〜14 / `fr_attempt_test.sh` / `fr_state_test.sh` Section #411 /
`fr_process_test.sh` Section 11 で各 AC に対応するテストが追加・通過している（PASS=42/56/60/60/71、
FAIL=0）。Req 2.5（dedicated_log= 文字列の専用テスト）と Req 2.6（i/o エラー fail-continue path）
については impl-notes に直接 unit test 困難な i/o path であり間接的に観測している旨明記された
上で実装は揃っており、missing test として reject するには弱い。境界面では failed-recovery
module / Config ブロック / 関連 test / README / spec 文書に限定され、他 processor / 既存
env / 既存終端識別子・ラベルへの影響なし。shellcheck / root↔repo-template の drift も clean。

RESULT: approve
