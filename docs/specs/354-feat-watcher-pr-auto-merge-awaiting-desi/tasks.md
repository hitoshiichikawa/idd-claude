# Implementation Plan

本実装は **#352 (Auto-Merge Processor) の対称拡張**として、設計 PR 用 auto-merge processor を
`modules/auto-merge-design.sh` に新規追加し、AND 二重 opt-in （`AUTO_MERGE_DESIGN_ENABLED=true`
かつ `FULL_AUTO_ENABLED=true`）配下で発火させる。設計レビュー結果の commit status 化
（`codex-review` / `claude-review`）は既存 #349 実装をそのまま流用し、コード変更は行わず
テスト追加とドキュメント明示で覆う。

実装順序は **基盤先行**（module 新規追加 → 本体 Config / loader / call site 配線 →
テスト → README 同期）。並列化は同一 `issue-watcher.sh` 本体を編集するタスクが多いため
基本的に直列で進める。

- [ ] 1. 新規 module `modules/auto-merge-design.sh` を追加
  - `local-watcher/bin/modules/auto-merge-design.sh` を新規作成（#352 `auto-merge.sh` を雛形にコピーし `am_` → `amd_` / `AUTO_MERGE_` → `AUTO_MERGE_DESIGN_` で命名置換）
  - 関数 prefix `amd_`（未使用 prefix）で namespace 分離（CLAUDE.md §2）
  - 定義する関数群:
    - `amd_log` / `amd_warn` / `amd_error`（`auto-merge-design:` プレフィックス）
    - `amd_resolve_gate_enabled`（`=true` 厳密一致以外は OFF 正規化）
    - `amd_should_enable_for_pr`（head pattern / draft / mergeable / label / autoMergeRequest 判定）
    - `amd_enable_auto_merge_for_pr`（`gh pr merge --auto --squash --delete-branch -- <N>` 実行 + 失敗 3 分類）
    - `process_auto_merge_design`（entry point。AND gate → 候補列挙 → 各 PR 判定・enable → サマリ）
  - 関数定義のみとし、トップレベル副作用を持たせない（module loader 規約 / CLAUDE.md §1）
  - ファイル冒頭コメントに「用途 / 配置先 / 依存 / セットアップ参照先」を明記（既存 `auto-merge.sh` の慣習）
  - NFR 1.x に従い `gh` 呼び出しは `--` でオプション解釈打ち切り、PR 番号は `^[0-9]+$` で検証、jq には `--arg` で展開
  - head pattern による client-side filter で impl PR (`^claude/issue-.*-impl`) を排他（Req 2.6, 6.7）
  - 失敗時 stderr 内容で 3 分類（`transport-error` / `repo-config-rejected` / `api-error`）
  - _Requirements: 1.2, 1.3, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.1, 3.2, 3.3, 3.4, 5.1, 5.2, 6.1, 6.2, 6.3, 6.4, 6.5, 6.6, 6.7, 7.1, 7.2, 7.3, 7.4, 7.5, 8.1, 8.2, 8.3, 9.1, 9.2, NFR 1.1, NFR 1.2, NFR 1.3, NFR 1.4_
  - _Boundary: modules/auto-merge-design.sh_

- [ ] 2. `issue-watcher.sh` Config ブロック拡張
  - `local-watcher/bin/issue-watcher.sh` の `─── Auto-Merge Processor 設定 (#352) ───` ブロック直後に `─── Design Auto-Merge Processor 設定 (#354) ───` を追加
  - 新規 env 宣言（既定 OFF / unset 時の挙動不変を満たすこと）:
    - `AUTO_MERGE_DESIGN_ENABLED="${AUTO_MERGE_DESIGN_ENABLED:-false}"`
    - `AUTO_MERGE_DESIGN_MAX_PRS="${AUTO_MERGE_DESIGN_MAX_PRS:-10}"`
    - `AUTO_MERGE_DESIGN_GIT_TIMEOUT="${AUTO_MERGE_DESIGN_GIT_TIMEOUT:-60}"`
    - `AUTO_MERGE_DESIGN_HEAD_PATTERN="${AUTO_MERGE_DESIGN_HEAD_PATTERN:-^claude/issue-.*-design}"`
  - 既存 env var 名・既定値を変更しないこと（NFR 2.2）
  - コメントに「AND 二重 opt-in」「既定 OFF」「`=true` 厳密一致以外は OFF」「実装 PR との非干渉」「`DESIGN_REVIEW_RELEASE_ENABLED` との独立共存」を明記（既存 #352 注記と同形）
  - _Requirements: 1.1, 5.4, 8.4, NFR 2.1, NFR 2.2_
  - _Boundary: issue-watcher.sh:Config_
  - _Depends: 1_

- [ ] 3. `REQUIRED_MODULES` ローダと cycle startup ログ拡張
  - `local-watcher/bin/issue-watcher.sh` の `REQUIRED_MODULES` 配列に `"auto-merge-design.sh"` を **`"auto-merge.sh"` の直後**に追加（NFR 6.2）
  - cycle startup ログ（line 882 付近の `echo "[$(date '+%F %T')] base-branch=..."` 行）に `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` を `auto-merge=...` と `full-auto=...` の間に追加（Req 9.4）
  - module 配置漏れ時は既存 module loader が起動時 exit 1 する既存挙動を維持（破壊しない）
  - _Requirements: 9.4, NFR 6.2_
  - _Boundary: issue-watcher.sh:Config, issue-watcher.sh:Loader_
  - _Depends: 1, 2_

- [ ] 4. Main loop に `process_auto_merge_design` 呼び出しを配線
  - `local-watcher/bin/issue-watcher.sh` の `process_auto_merge || am_warn ...` 行（line 999 付近）の **直後**に `process_auto_merge_design || amd_warn "process_auto_merge_design が想定外のエラーで終了しました（後続 Issue 処理は継続）"` を追加
  - Phase D auto-rebase の後・promote-pipeline の前に配置する順序を維持（既存 design.md「順序根拠」節準拠）
  - `process_auto_merge_design` は戻り値 0 固定（パイプライン継続 / Req 7.3）。失敗時の `amd_warn` は防衛的セーフティ
  - Design Review Release Processor (#40) の `process_design_review_release` 呼び出し位置（line 1308 付近）は変更しない（Req 5.4 / 8.4）
  - 他 processor のラベル遷移・コメント投稿・exit code・ログ行に影響を与えないこと（Req 8.2 / 8.4 / NFR 2.3）
  - _Requirements: 1.4, 3.3, 5.2, 5.3, 5.4, 6.7, 7.3, 8.2, 8.4, NFR 2.3, NFR 3.1, NFR 3.2_
  - _Boundary: issue-watcher.sh:MainLoop_
  - _Depends: 1, 3_

- [ ] 5. 新規 fixture テスト `auto-merge-design_test.sh` を追加
  - `local-watcher/test/auto-merge-design_test.sh` を新規作成（既存 `auto-merge_test.sh` を雛形に複製）
  - `extract_function` イディオムで `amd_log` / `amd_warn` / `amd_error` / `amd_resolve_gate_enabled` / `amd_should_enable_for_pr` / `amd_enable_auto_merge_for_pr` / `process_auto_merge_design` を切り出して評価
  - `full_auto_enabled` も `issue-watcher.sh` 本体から切り出して評価（AND gate テスト用）
  - 検証ケース（design.md「Testing Strategy / Unit Tests」表に 1:1 対応）:
    - (1) `amd_resolve_gate_enabled` 値正規化: `true` 厳密一致のみ rc=0、他（未設定 / 空 / `True` / `1` / `on` / typo）は rc=1
    - (2) `amd_should_enable_for_pr`: head pattern 不一致（impl PR / 手書き PR）→ rc=1
    - (3) draft 除外 / `claude-failed` / `needs-decisions` / `needs-iteration` 各除外 → rc=1
    - (4) `mergeable=MERGEABLE` → rc=0 / `CONFLICTING` → rc=1 / `UNKNOWN` → rc=1
    - (5) `autoMergeRequest` 既存（冪等 skip）→ rc=2
    - (6) gh stub で `gh pr merge --auto --squash --delete-branch -- <N>` が exactly once 呼ばれる
    - (7) gh stub 失敗時に stderr 内容から 3 分類が正しく warn log に反映される
    - (8) AND gate OFF (`AUTO_MERGE_DESIGN_ENABLED=false`) → gh stub 呼び出し回数 0 + suppression log 1 行
    - (9) `FULL_AUTO_ENABLED=false` → gh stub 呼び出し回数 0 + suppression log なし（#348 ログに委譲）
    - (10) gh stub 失敗時にも `process_auto_merge_design` が rc=0（パイプライン継続）
  - 観測ログ assert で PR 番号 / head sha / head branch / action / category が含まれることを確認（Req 7.1, 7.4, 9.1）
  - _Requirements: 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.1, 3.4, 6.2, 6.3, 6.4, 6.6, 6.7, 7.1, 7.2, 7.3, 7.4, 7.5, 8.1, 9.1, 9.2, 9.3, NFR 5.2_
  - _Boundary: test/auto-merge-design_test.sh, modules/auto-merge-design.sh_
  - _Depends: 1_

- [ ] 6. 既存 `pr_publish_commit_status_test.sh` に design head fixture を追加
  - `local-watcher/test/pr_publish_commit_status_test.sh` を編集し、既存テストに以下 3 ケースを追加（既存ケースは温存）:
    - (1) head `claude/issue-N-design-foo` + AND gate ON → `pr_publish_codex_status` が `codex-review` context で gh stub を 1 回呼ぶ（state=success または failure を VERDICT で分岐）
    - (2) 同上 + AND gate OFF（`PR_REVIEWER_STATUS_CHECK_ENABLED=false` または `FULL_AUTO_ENABLED=false`）→ gh stub 呼び出し回数 0 + suppression log 1 行
    - (3) design PR head sha 入力 + AND gate ON → `pr_publish_claude_status` が `claude-review` context で gh stub を 1 回呼ぶ（`approve` → success / `reject` → failure）
  - 既存 impl PR 向けケースの挙動を変更しないこと（NFR 2.3 / Req 8.4）
  - design PR head pattern の含意（`pr_publish_*` が head pattern を区別しない既存設計）が明確になるようコメントで明記
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, NFR 2.3, NFR 5.3_
  - _Boundary: test/pr_publish_commit_status_test.sh, modules/pr-reviewer.sh_

- [ ] 7. README に Design Auto-Merge Processor 節と一覧表行を追加
  - `README.md` の「オプション機能一覧（opt-in）」表（line 1346 付近）に `AUTO_MERGE_DESIGN_ENABLED` 行を追加（既定 false / 正規化規則 / 追加 env / 詳細リンク / 関連 #354）
  - 「Auto-Merge Processor (#352)」節（line 2217 付近）の **直後**に「Design Auto-Merge Processor (#354)」節を新設し、以下を記述:
    - 概要（設計 PR head pattern + AND 二重 opt-in + GitHub auto-merge state machine 委譲）
    - 対象 PR の条件（head `^claude/issue-.*-design` / 非 draft / `mergeable=MERGEABLE` / 除外ラベル / 既 enabled 冪等 skip）
    - 前提となる repo 設定（Allow auto-merge / Required status checks に `codex-review` / `claude-review` + CI を追加）
    - 有効化方法（cron スニペット例）
    - 観測ログ例（成功 / 既 enabled / 非対象 / サマリ / gate OFF suppression / FULL_AUTO OFF）
    - 異常系（`api-error` / `transport-error` / `repo-config-rejected` の 3 分類）
    - 後方互換 / 不具合時の停止（`AUTO_MERGE_DESIGN_ENABLED=false` または `FULL_AUTO_ENABLED=false` で全停止）
    - **`DESIGN_REVIEW_RELEASE_ENABLED` (#40) との共存**（auto-merge 完了後の `awaiting-design-review` 除去は Design Review Release Processor が引き続き担当 / NFR 4.3）
    - **merge 後の再配置注記**: 既存 watcher を使っている場合、`cd ~/.idd-claude && git pull && ./install.sh --local` 再実行で `$HOME/bin/modules/auto-merge-design.sh` を配置する必要があることを明記（既存 #261 / #352 注記と同形）
  - 既存 #352 / #349 / #40 / #348 各節への相互リンクを張る
  - _Requirements: NFR 4.1, NFR 4.2, NFR 4.3_
  - _Boundary: README.md_

- [ ] 8. 全体 verify（shellcheck / actionlint / bash -n / 既存テスト + 新規テスト + diff -r）
  - `shellcheck local-watcher/bin/modules/auto-merge-design.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` で警告ゼロ（`.shellcheckrc` の SC2317 / SC2012 accepted baseline は反映済 / NFR 5.1）
  - `actionlint .github/workflows/*.yml` クリーン（本 spec で workflow は変更しないが回帰確認）
  - `bash -n local-watcher/bin/modules/auto-merge-design.sh local-watcher/bin/issue-watcher.sh` で構文 OK
  - 新規テスト実行: `bash local-watcher/test/auto-merge-design_test.sh`（全 PASS）
  - 既存テスト実行: `bash local-watcher/test/auto-merge_test.sh` / `bash local-watcher/test/pr_publish_commit_status_test.sh` / `bash local-watcher/test/full_auto_enabled_test.sh`（既存挙動の回帰確認 / NFR 2.3）
  - `diff -r .claude/agents repo-template/.claude/agents` 空 / `diff -r .claude/rules repo-template/.claude/rules` 空（NFR 4.4。本 spec では `.claude/{agents,rules}` を編集しないため差分ゼロが期待される）
  - dry run スモークテスト: `REPO=owner/test REPO_DIR=/tmp/test-repo bash local-watcher/bin/issue-watcher.sh` を対象なし状態で実行し、cycle 開始ログに `auto-merge-design=false` が含まれ正常終了することを確認（Req 9.4 / NFR 2.1）
  - install scratch test（任意）: 使い捨て scratch repo で `./install.sh --repo /tmp/scratch` を実行し `$HOME/bin/modules/auto-merge-design.sh` が実行ビット付きで配置されることを確認（NFR 6.1）
  - _Requirements: NFR 4.4, NFR 5.1, NFR 5.2, NFR 5.3, NFR 6.1, NFR 6.2_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを
構造化ブロックで宣言する。本 spec は bash スクリプトの追加と既存 markdown 編集のみで、
unit test フレームワークは持たない（CLAUDE.md「テスト・検証」節準拠）。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/auto-merge-design.sh local-watcher/bin/modules/auto-merge.sh local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh && \
  actionlint .github/workflows/*.yml && \
  bash -n local-watcher/bin/modules/auto-merge-design.sh && \
  bash -n local-watcher/bin/issue-watcher.sh && \
  bash local-watcher/test/auto-merge-design_test.sh && \
  bash local-watcher/test/auto-merge_test.sh && \
  bash local-watcher/test/pr_publish_commit_status_test.sh && \
  bash local-watcher/test/full_auto_enabled_test.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
