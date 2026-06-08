# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-07T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-295-impl-bug-watcher-worktree-reset-root-docker-c
- HEAD commit: 7bf57cada314233a2b14be687e65e7bc2cfa7e3c
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/core_utils.sh`、`docs/specs/295-bug-watcher-worktree-reset-root-docker-c/{impl-notes.md,test-fixtures/smoke-worktree-reset.sh}`
- design.md / tasks.md は存在せず（design-less impl）。境界判定は requirements.md の Out of Scope と impl-notes.md の「変更ファイル」を根拠に行った。
- CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため opt-out として扱い、通常の 3 カテゴリ判定のみを実施。

## Verified Requirements

- 1.1 — `core_utils.sh:333-336` `git reset --hard` で `2>/dev/null` を撤去し、失敗時に時刻 prefix 付きで `>&2` に echo（呼び出し元 `_slot_run_issue` の `tee -a "$SLOT_LOG"` 経路で SLOT_LOG に到達）
- 1.2 — `core_utils.sh:340-369` `git clean -fdx` の stderr を `mktemp` の tmp file に capture し、失敗時に `cat "$clean_stderr" >&2` で SLOT_LOG に転写
- 1.3 — `_worktree_reset` 本体から `2>/dev/null` を排除（既存 `2>/dev/null` は tmp 後始末 `rm -f` 等の補助呼び出しのみに残置されており、git 実行系の stderr は握り潰されない）
- 1.4 — `core_utils.sh:351-361` 成功パス（`clean_rc=0`）で stdout は `>/dev/null` 抑止、tmp file が空なら no-op、`git reset --hard` 成功時は stderr に書かない既存挙動を保持
- 2.1 — `core_utils.sh:394` `${WORKTREE_DOCKER_CLEANUP_ENABLED:-false}` で env を参照
- 2.2 — `:-false` で未設定時の既定を false 化
- 2.3 — `[ "...":-false}" = "true" ]` の厳密一致のため、未設定 / false / 不正値時に docker 経路に入らない（NFR 4.1 と同根拠）
- 2.4 — docker 分岐は `is_perm_fail=1` の判定後にのみ評価される（`core_utils.sh:383-394`）
- 2.5 — `core_utils.sh:395` `command -v docker` で実行ファイル不在を検知し、fallback ログを出して Req 4 の recreate に進む
- 3.1 — `core_utils.sh:375` `grep -qE 'EACCES|[Pp]ermission denied|Operation not permitted'` で permission 起因を判定
- 3.2 — `core_utils.sh:450-455` `docker run --rm --network=none -v "$wt":/wt ... find . -mindepth 1 -maxdepth 1 ! -name ".git" -exec rm -rf {} +`
- 3.3 — `core_utils.sh:395-413` docker 不在 / docker 失敗のいずれでも recreate fallback に進む
- 3.4 — `core_utils.sh:420-421` 全経路失敗時に時刻 prefix 付き `ERROR: escalated cleanup 全経路が失敗` を `>&2` に残し return 1
- 3.5 — `core_utils.sh:383-386` permission 起因でなければ escalated flow 開始ログを出さず即 return 1
- 4.1 — `core_utils.sh:416` docker 失敗/skip 後に必ず `_worktree_reset_recreate "$wt"` を呼ぶ
- 4.2 — `core_utils.sh:475-491` `git worktree remove --force` → `rm -rf $wt` → `git worktree add --detach "$wt" "origin/${BASE_BRANCH}"`
- 4.3 — `core_utils.sh:416-419` recreate 成功時に `_worktree_reset` も return 0
- 4.4 — `core_utils.sh:483-494` rm 失敗 / worktree add 失敗それぞれで `ERROR:` ログ + return 1
- 4.5 — `core_utils.sh:471, 495` 開始 / 完了双方の事実を SLOT_LOG に明示
- 5.1 — 通常ケース（clean 成功）で `core_utils.sh:351-361` で即 return 0、docker / recreate 経路に到達しない。smoke test (`test-fixtures/smoke-worktree-reset.sh`) で実機確認済み
- 5.2 — 戻り値は return 0 / return 1 のみ
- 5.3 — 既存 env var には触れていない（新規追加のみ: `WORKTREE_DOCKER_CLEANUP_ENABLED` / `WORKTREE_DOCKER_CLEANUP_IMAGE`）
- 5.4 — `_worktree_reset` の引数 / 戻り値契約は変更なし。呼び出し元 `issue-watcher.sh` は無変更
- NFR 1.1 — smoke test で `WORKTREE_DOCKER_CLEANUP_ENABLED` 未設定時に通常ケースで挙動非変化を確認
- NFR 1.2 — 通常パスで `docker` / `sudo` を一切呼ばない（permission failure 検出後の opt-in 経路でのみ docker 呼び出し）
- NFR 2.1 — 各段階（permission 検出 / docker skip 理由 / docker 成否 / recreate 開始・完了 / 最終失敗）に時刻 prefix 付きログ
- NFR 2.2 — 全ログに `(wt=$wt)` を付与し worktree パスで slot 識別可能
- NFR 3.1 — `shellcheck local-watcher/bin/modules/core_utils.sh docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh` を再実行し警告ゼロを確認
- NFR 3.2 — クォート徹底 / `command -v docker` 使用 / `set -euo pipefail` 配下で安全
- NFR 3.3 — 全 error メッセージは `>&2` 出力（標準出力は機械可読領域として温存）
- NFR 4.1 — `= "true"` の lowercase 厳密一致のみ true 扱い。smoke test の opt-in 判定ループで `True` / `TRUE` / `1` / `yes` / `opt-in` / `"true "`（末尾空白）が false に解釈されることを実地確認

## Boundary Check

- 変更は `local-watcher/bin/modules/core_utils.sh`（`_worktree_reset` および新規ヘルパ `_worktree_reset_docker_cleanup` / `_worktree_reset_recreate`）と spec ディレクトリ配下のみ。
- 呼び出し元 `local-watcher/bin/issue-watcher.sh` は無改変で関数シグネチャ契約を満たす。
- `repo-template/` / `.claude/{agents,rules}/` / README 等への破壊的変更は無し。Out of Scope（`sudo -n` 経路採用、運用 repo Dockerfile 改修、他フェーズの観測性、非 root UID 一般対応）にも踏み込んでいない。

## Verification Results

- `shellcheck local-watcher/bin/modules/core_utils.sh docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh` → 警告ゼロ
- `bash docs/specs/295-bug-watcher-worktree-reset-root-docker-c/test-fixtures/smoke-worktree-reset.sh` → `[smoke] ALL PASS`（通常パス + opt-in 判定境界）

## Findings

なし

## Summary

requirements.md の全 numeric ID（Req 1.1–5.4 および NFR 1.1–4.1）について、`core_utils.sh` 内の `_worktree_reset` 改修と新規ヘルパ 2 関数で網羅的に対応していることを確認。通常パスは smoke test で実機 green、opt-in / EACCES 経路は impl-notes と実装の対応が明示されている。境界違反・観測可能挙動の AC 未カバー・新規挙動に対するテスト欠落は検出されず。

RESULT: approve
