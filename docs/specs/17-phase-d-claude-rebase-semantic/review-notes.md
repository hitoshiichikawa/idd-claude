# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-21T11:38:11Z -->

## Reviewed Scope

- Branch: claude/issue-17-impl-phase-d-claude-rebase-semantic
- HEAD commit: e7c604eaca03951b9c822890034d56b39199825d
- Compared to: main..HEAD
- Feature Flag Protocol 採否: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節は存在しない → opt-out として解釈。通常の 3 カテゴリ判定のみを適用。

## Verified Requirements

- 1.1 — `process_auto_rebase` 冒頭の `[ "$AUTO_REBASE_MODE" = "off" ] && return 0`（issue-watcher.sh:1870）。`AUTO_REBASE_MODE` 既定値 `off`（issue-watcher.sh:145）
- 1.2 — orchestration 配線 `process_auto_rebase || ar_warn ...`（issue-watcher.sh:2078）
- 1.3 — `case "$AUTO_REBASE_MODE" in claude) : ;; *) AUTO_REBASE_MODE="off" ;; esac` で `claude` 以外を `off` に正規化（issue-watcher.sh:147〜150）
- 1.4 — 起動時ログ `auto-rebase=${AUTO_REBASE_MODE}`（issue-watcher.sh:400）+ `ar_log "サイクル開始 (mode=..., ...)"`（issue-watcher.sh:1881）
- 2.1 — server filter `review:approved label:"$LABEL_NEEDS_REBASE"`（issue-watcher.sh:1198〜1201）
- 2.2 — server filter `-label:"$LABEL_FAILED"`（同上）
- 2.3 — server filter `-draft:true` + jq client filter `.isDraft == false`（issue-watcher.sh:1212）
- 2.4 — jq client filter `(.headRepositoryOwner.login // "") == $owner`（issue-watcher.sh:1215）
- 2.5 — jq client filter `.headRefName | test($pattern)`（issue-watcher.sh:1214）
- 3.1 — Re-check (2069) → Phase A (2072) → Phase D (2078) の直列順序で構造的に保証
- 3.2 — Re-check が先行して `needs-rebase` 除去するため Phase D の server filter で当該 PR が候補に出ない
- 3.3 — Phase D が後に走るため、同サイクル内で Re-check が触れ直さない
- 3.4 — `ar_log "サマリ: mechanical=N, semantic=N, failed=N, skip=N, overflow=N"`（issue-watcher.sh:1942）
- 4.1 — `ar_run_claude_rebase` の `claude --print "$prompt" --model --max-turns ...` 起動（issue-watcher.sh:1325〜1334）
- 4.2 — `before_sha=$(git rev-parse HEAD)` / `after_sha=$(git rev-parse HEAD)` を取得し log 記録（issue-watcher.sh:1296, 1351）
- 4.3 — `ar_classify_diff` の `git diff --name-only "origin/${base_ref}..origin/${head_ref}"`（issue-watcher.sh:1415, 1418）
- 4.4 — `ar_handle_pr` の rc=1 経路で `ar_escalate_to_failed conflict-unresolved` + コメント 1 件（issue-watcher.sh:1786〜1790）
- 4.5 — `timeout "$AUTO_REBASE_MAX_TURNS_SEC" claude ...`（issue-watcher.sh:1325）+ exit 124 を rc=2 で escalate
- 4.6 — `git push --force-with-lease`（issue-watcher.sh:1364）。実装に `--force` 単独は登場しない（grep 確認済）
- 5.1 — `ar_classify_diff` で `MECHANICAL_PATHS` のカンマ区切り pattern 配列と path を照合（issue-watcher.sh:1438〜1462）
- 5.2 — 全 path 一致 → `echo "mechanical"`（issue-watcher.sh:1473）
- 5.3 — 1 件 unmatch で break + `echo "semantic"` + unmatched path（issue-watcher.sh:1467〜1471）
- 5.4 — `[ -z "$MECHANICAL_PATHS" ]` で全件 `semantic` 早期 return（issue-watcher.sh:1408〜1412）
- 5.5 — `ar_log "PR #...: classification=mechanical paths=N"` / `... classification=semantic unmatch=..."`（issue-watcher.sh:1409, 1466, 1472）
- 6.1 — `ar_apply_mechanical` は dismissal API を呼ばない（issue-watcher.sh:1495〜1505）
- 6.2 — `gh pr edit --remove-label "$LABEL_NEEDS_REBASE"`（issue-watcher.sh:1501〜1502）
- 6.3 — `ar_apply_mechanical` はコメント API を呼ばない（実装に gh pr comment 呼出なし）
- 6.4 — `needs-rebase` 除去後、次サイクルで Re-check / Phase A が再評価可能（既存 server filter が機械的に当該 PR を除外）
- 7.1 — `ar_dismiss_all_approvals` が `gh api -X PUT .../reviews/{id}/dismissals` を全 APPROVED review に対し loop（issue-watcher.sh:1547〜1559）
- 7.2 — `ar_apply_semantic` 内の `gh pr edit --remove-label "$LABEL_NEEDS_REBASE"`（issue-watcher.sh:1587〜1589）
- 7.3 — `ar_apply_semantic` 内の `gh pr edit --add-label "$LABEL_READY"`（issue-watcher.sh:1593〜1595）
- 7.4 — `ar_apply_semantic` 内 heredoc コメント 1 件投稿（before/after sha・unmatch path・dismissal・再レビュー誘導の理由を含む。issue-watcher.sh:1602〜1632）
- 7.5 — dismissal は `gh api -X PUT ...` 経由のみ。`gh pr review --request-changes` の呼出は実装に存在しない（grep 確認済）
- 7.6 — `ar_dismiss_all_approvals` 戻り値 1 → `ar_handle_pr` semantic 経路で `ar_escalate_to_failed dismissal-failed`（issue-watcher.sh:1843〜1846）
- 8.1 — `ar_escalate_to_failed` は `needs-rebase` ラベルに触らない（remove-label 呼出なし）
- 8.2 — `ar_escalate_to_failed` の `gh pr edit --add-label "$LABEL_FAILED"`（issue-watcher.sh:1697〜1699）
- 8.3 — `case "$reason"` で `conflict-unresolved` / `timeout` / `push-failed` / `dismissal-failed` / `fetch-failed` ごとに heredoc コメント 1 件（issue-watcher.sh:1664〜1690, 1706〜1734）
- 8.4 — `ar_fetch_candidates` の server-side filter `-label:"$LABEL_FAILED"` で `claude-failed` 付き PR を機械的に除外
- 9.1 — README「オプション機能一覧」表に Phase D 行追加 + 新規節「Auto Rebase Processor (Phase D)」（README.md:1082, 1422〜1556）
- 9.2 — README「環境変数」表に `MECHANICAL_PATHS` 既定 空・空時挙動の記載あり
- 9.3 — README「言語別設定例」表に JavaScript / Python / Go / Rust + モノレポ向け `**/...` 例（README.md 内 表）
- 9.4 — dogfood 検証（tasks 7.3, deferrable `- [ ]*`）として人間運用フェーズに委ねる方針。impl-notes.md に明記。実装段階では shellcheck CLEAN と orchestration 配線で観測可能性を担保
- NFR 1.1 — `AUTO_REBASE_MODE=off` 既定 + 早期 return + template 存在チェックを `AUTO_REBASE_MODE != off` でのみ実行（issue-watcher.sh:388〜392）
- NFR 1.2 — 既存 env var 名はすべて維持（diff 上で既存変数の改名・既定値変更なし）
- NFR 1.3 — 既存ラベル名（`$LABEL_NEEDS_REBASE` / `$LABEL_FAILED` / `$LABEL_READY`）を再利用
- NFR 1.4 — cron / launchd 登録文字列は不変（env var 追加のみで起動コマンド変更なし）
- NFR 1.5 — `process_auto_rebase || ar_warn ...` で常に 0 を吸収（exit code 不変）
- NFR 2.1 — 1 PR 1 行サマリログ `PR #N: classification=... before=... after=... action=... url=...`（ar_handle_pr 内 ar_log 行）
- NFR 2.2 — 1 サイクル 1 行サマリ（issue-watcher.sh:1942）
- NFR 3.1 — bash / gh / jq / git / claude / timeout のみで構成（Node.js / Python 等の新規言語ランタイムなし）
- NFR 3.2 — `MECHANICAL_PATHS="${MECHANICAL_PATHS:-}"` で既定 空（特定言語の lockfile 名を内蔵しない）
- NFR 4.1 — `shellcheck --severity=warning local-watcher/bin/issue-watcher.sh` を実行し EXIT 0（reviewer 側でも再確認、warning ゼロ）
- NFR 5.1 — `timeout "$AUTO_REBASE_MAX_TURNS_SEC" claude ...`（既定 600 秒）
- NFR 5.2 — `(subshell + trap)` で `git rebase --abort` + `git checkout "$BASE_BRANCH"` を rollback として保証（issue-watcher.sh:1280〜1282）+ 関数末尾でも保険的に `git checkout` 戻し
- NFR 5.3 — `git push --force-with-lease` のみ使用（grep 確認済）

## Findings

なし

## Summary

Phase D Auto Rebase Processor の実装は requirements.md の全 numeric ID（Req 1.1〜9.4 / NFR 1.1〜5.3）と tasks.md の `_Boundary:_` アノテーションをすべて充足。実装は `local-watcher/bin/issue-watcher.sh` の新規関数群 + `auto-rebase-prompt.tmpl` 新規追加 + README / repo-template/CLAUDE.md / impl-notes.md / tasks.md の更新に限定され、Boundary 逸脱なし。reviewer 側で `shellcheck --severity=warning` と `bash -n` を再実行して両方 EXIT 0 を確認した。dogfood task 7.3 は impl-notes.md に明記の通り deferrable で、人間運用フェーズに委ねるのが妥当。

RESULT: approve
