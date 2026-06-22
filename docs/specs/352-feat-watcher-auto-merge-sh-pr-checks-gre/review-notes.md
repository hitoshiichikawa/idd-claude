# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-352-impl-feat-watcher-auto-merge-sh-pr-checks-gre
- HEAD commit: 2d6cbda27210405007156a979fa786fefd420e7d
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/auto-merge.sh` (新規 337 行) / `local-watcher/bin/issue-watcher.sh` (Config block / REQUIRED_MODULES / call site / startup ログに `auto-merge=` 追加) / `local-watcher/test/auto-merge_test.sh` (新規 630 行 / 56 ケース) / `README.md` (オプション機能一覧表に行追加 + 詳細セクション `Auto-Merge Processor (#352)` 追加) / spec ファイル 2 件
- Architect 起動なし（design.md / tasks.md は不在）の単純実装パス。判定は requirements.md と impl-notes.md の AC traceability に直接突き合わせて実施
- CLAUDE.md の `## Feature Flag Protocol` 採否宣言節は存在せず → opt-out 解釈で通常の 3 カテゴリ判定のみ適用

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` Config block で `AUTO_MERGE_ENABLED="${AUTO_MERGE_ENABLED:-false}"` を宣言
- 1.2 — `am_resolve_gate_enabled` が `=true` 厳密一致時のみ rc=0、`process_auto_merge` 入口で AND 二重 opt-in を判定
- 1.3 — `auto-merge_test.sh` Section 1 (15 ケース) で空文字 / `false` / `0` / `True` / `TRUE` / `1` / `on` / `yes` / `enable` / `tRue` / `  true  ` / `trues` がすべて OFF 正規化
- 1.4 — `process_auto_merge` 入口で `full_auto_enabled` を先評価し OFF なら早期 return / Section 4 Case B
- 1.5 — Case A/B/C/L で両 gate / どちらか OFF 時に gh API ゼロ呼び出しを確認
- 2.1 — head pattern client-side filter（jq の `select(.headRefName | test($pattern))`）+ `am_should_enable_for_pr` の `grep -qE` 検証 / Case H, I
- 2.2 — `gh pr list --search "label:\"$LABEL_READY\""` の server-side filter + `am_should_enable_for_pr` の jq label check / Case G
- 2.3 — `gh pr list --search "...-draft:true"` + `am_should_enable_for_pr` の `is_draft` check / Case F
- 2.4 — `am_should_enable_for_pr` で `mergeable != "MERGEABLE"` を rc=1 で skip / Section 2
- 2.5 — `mergeable=CONFLICTING` は skip / Case E
- 2.6 — `mergeable=UNKNOWN` は skip / Section 2 の PR_UNKNOWN ケース
- 3.1 — `gh pr merge --auto --squash --delete-branch -- "$pr_number"` を呼び出し / Section 3 の auto/squash/delete-branch 各フラグ verify + Case D
- 3.2 — コード上に `git merge` / `git push` / 直接 branch 操作なし（grep で確認）
- 3.3 — polling / sleep / backgrounding なし（NFR 3.2 と同根拠）
- 3.4 — `--delete-branch` フラグを enable 時に渡しているため GitHub 側で実 merge 後に削除される設計
- 4.1 — コード上に `needs-rebase` ラベルへの add/remove 操作なし（grep で確認）
- 4.2 — `LABEL_FAILED` を server-side `-label:` + client-side jq exclude / Section 2 の PR_FAILED ケース
- 4.3 — `LABEL_NEEDS_DECISIONS` を server-side + client-side exclude / Section 2 の PR_NEEDS_DEC ケース
- 4.4 — `gh pr review --dismiss` / API 呼び出しなし
- 4.5 — `autoMergeRequest` フィールド非 null 時 rc=2 で skip / Case J
- 5.1 — `gh pr merge` 失敗時に `am_warn` で `api-error` カテゴリの WARN ログ / Section 3, Case K
- 5.2 — stderr に `could not resolve host` / `network` / `timeout` / `connection` を含む場合 `transport-error` 分類 / Section 3
- 5.3 — call site `process_auto_merge || am_warn ...` で wrap、`am_enable_auto_merge_for_pr` rc=1 でも while ループは continue
- 5.4 — stderr 内容を WARN ログに含める設計で silent fail させない / Section 3
- 5.5 — `branch protection` / `not allowed` / `not permitted` / `auto merge ... disable` を `repo-config-rejected` 分類 / Section 3
- 6.1 — Case A で両 gate OFF 時 gh ゼロ呼び出しを verify
- 6.2 — call site 追加のみで他 processor の関数契約 / ラベル遷移 / exit code に変更なし
- 6.3 — head pattern client-side filter + 設計 PR 除外 / Case H, I
- 6.4 — merge-queue / auto-rebase / pr-iteration / pr-reviewer の関数契約に変更なし（既存関数の呼び出し / 改変なし）
- 7.1 — `am_log "PR #${pr_number}: auto-merge enabled (squash, delete-branch) head=... sha=... url=..."` を成功時に出力 / Section 3 で PR番号 / head sha / head branch 含有を verify
- 7.2 — `am_log "suppressed by AUTO_MERGE_ENABLED gate (no-op)"` を gate OFF 時 1 行出力 / Case C
- 7.3 — `full_auto_enabled` 経路では auto-merge 側ログを出さず #348 の既存 suppression ログに委譲 / Case B で 0 行を verify
- 7.4 — `issue-watcher.sh` の startup ログに `auto-merge=${AUTO_MERGE_ENABLED}` を追加
- NFR 1.1 — jq に `--arg l "$LABEL_..."` を渡し filter 文字列に inline 展開なし
- NFR 1.2 — `gh pr merge ... -- "$pr_number"` で `--` オプション打ち切り
- NFR 1.3 — `am_enable_auto_merge_for_pr` および `process_auto_merge` の while loop 内で `grep -qE '^[0-9]+$'` 検証
- NFR 1.4 — `am_should_enable_for_pr` で `grep -qE -- "$AUTO_MERGE_HEAD_PATTERN"` 検証
- NFR 2.1 — `AUTO_MERGE_ENABLED` 既定 false で導入前と等価（Case A 検証済み）
- NFR 2.2 — 既存 env var / ラベル名 / exit code / cron 文字列に変更なし
- NFR 2.3 — 他 processor 関数契約変更なし
- NFR 3.1 — 1 PR あたり最大 1 回（成功時のみ）または 0 回（skip 系）の `gh pr merge` 呼び出し
- NFR 3.2 — polling / sleep / background なし（コード上に該当なし）
- NFR 4.1 — README「オプション機能一覧」表に `AUTO_MERGE_ENABLED` 行追加（既定 false / AND セマンティクス / 等価性 note 含む）
- NFR 4.2 — README 詳細セクション「前提となる repo 設定」で Allow auto-merge / Required status checks の設定手順を記述
- NFR 4.3 — `.claude/{agents,rules}` 配下に変更なし（diff stat 上も不在）。`repo-template/` には CLAUDE.md のみで modules/labels/workflow のミラーは存在しないため二重管理対象外
- NFR 5.1 — `shellcheck local-watcher/bin/modules/auto-merge.sh local-watcher/bin/issue-watcher.sh` warning ゼロを確認
- NFR 5.2 — `bash local-watcher/test/auto-merge_test.sh` で 56/56 PASS、要求列挙ケース (a)〜(f) を網羅
- NFR 6.1 — `install.sh` は `local-watcher/bin/modules/*.sh` glob で配布するため新規ファイル追加で自動配布される
- NFR 6.2 — `REQUIRED_MODULES` 配列に `auto-merge.sh` を追加済み（auto-rebase.sh の後ろ、promote-pipeline.sh の前に挿入）

## Findings

なし。

### 観察事項（reject 理由ではない）

- `local-watcher/test/auto-merge_test.sh` 単体に shellcheck をかけると SC2034 (unused variable) 警告が 9 件出るが、これは `extract_function` イディオムで遅延束縛される env var 群に対する false-positive であり、既存テストファイル (`full_auto_enabled_test.sh` / `dr_unblock_sweep_test.sh` / `pi_max_rounds_kind_test.sh`) でも同型の警告が複数件存在する。CLAUDE.md「テスト・検証 / 静的解析」の shellcheck 対象は `local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` であり test ファイルは対象外。本プロジェクトの既存規範として受容されている運用パターンであり reject 対象外。
- 全 28 件の既存 `*_test.sh` を実行して regression なしを確認。

## Summary

すべての requirements.md numeric ID（Req 1.1〜7.4 + NFR 1〜6）に対応する実装またはテストが、新規 module / Config block 追加 / 56 ケースの単体テストに揃って存在する。AND 二重 opt-in（`AUTO_MERGE_ENABLED=true` AND `FULL_AUTO_ENABLED=true`）の安全側設計、CONFLICTING / UNKNOWN の既存経路委譲、冪等 skip、3 分類 WARN ログ、`--` 打ち切り / 数値検証 / `--arg` 等のセキュリティ規約遵守、README 同一 PR 反映、modules glob 経由の install.sh 自動配布も確認済み。境界逸脱 / missing test / AC 未カバーいずれも検出されず approve。

RESULT: approve
