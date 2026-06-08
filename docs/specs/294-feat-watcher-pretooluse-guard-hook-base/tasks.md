# Implementation Plan

実装は **G0 + G1 + G2 を同一初版**で完了させる（人間 Decision 1: Option A）。配布は
**user-scope のみ**（人間 Decision 2: Option A）。`repo-template/` への追加は本 Issue では
**禁止**（Req 6.2 / 6.3 / NFR 4.1）。

- [x] 1. guard hook script (`idd-guard.sh`) と settings テンプレを新規作成
  - `local-watcher/hooks/idd-guard.sh` を新規作成。`set -euo pipefail` 宣言。stdin から
    PreToolUse JSON を `jq` で読み、`tool_name` で分岐
  - G1 push 解析: `git` global options (`-C` / `--git-dir=` / `--work-tree=` / `-c k=v`) を
    skip → `push` 検出 → refspec から dst 抽出 → `$IDD_HOOK_BASE_BRANCH` 一致で deny
    （bare / `HEAD:base` / `:base` / `+base` / `-C path` / 暗黙 remote すべて対応）
  - G2 force 解析: `-f` / `--force` 検出で deny、`--force-with-lease(=...)` で base 以外なら
    allow、`+<src>:<dst>` の `+` 接頭辞で base 以外でも deny
  - G0 自己保護: `Edit` / `Write` / `NotebookEdit` の file_path/notebook_path が
    `$IDD_CLAUDE_HOOKS_DIR` 配下なら deny、`Bash` は mutation キーワード（`rm` / `mv` /
    `sed -i` / `chmod` / `>` / `>>` / `tee`）+ install dir リテラルの両方を含む場合のみ
    best-effort deny
  - decision JSON は `{"decision":"block","reason":"..."}` 書式（PoC 採用）。allow は `{}`
  - jq 不在 / JSON parse 失敗は **fail-closed**（exit 0 + block JSON）
  - `$IDD_HOOK_LOG` 設定時は 1 行 append（任意）
  - `local-watcher/hooks/idd-guard-settings.json` を新規作成。`matcher: "Bash|Edit|Write|NotebookEdit"` /
    `command: "__IDD_HOOK_PATH__"` placeholder を含む
  - `local-watcher/hooks/README.md` を新規作成（配置先・env var 契約・既知の限界の短文）
  - shellcheck 警告ゼロ
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 3.1, 3.2, 3.3, 3.4, 3.5, 4.1, 4.2, 4.3, 4.4, NFR 2.1_

- [x] 2. test fixtures（29 件マトリクス）と driver スクリプトを作成
  - `docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/cases/*.json` を
    29 件作成（G0:5 / G1:6 / G2:5 / Allow:13）。Issue #294 本文の PoC 29 件マトリクスに準拠
  - `expected.tsv` で各ケースの期待 verdict（deny|allow）と reason 部分一致文字列を宣言
  - `run-tests.sh` を新規作成（fixture を順次 stdin に流して hook を起動し、verdict と
    reason を expected.tsv と突合。1 件でも mismatch なら非ゼロ exit）
  - `IDD_HOOK_BASE_BRANCH=main` / `IDD_CLAUDE_HOOKS_DIR=$HOME/.idd-claude/hooks` を export
    した状態で実行
  - 29/29 green を確認
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3_
  - _Depends: 1_

- [x] 3. watcher module (`guard-hook.sh`) を新規作成
  - `local-watcher/bin/modules/guard-hook.sh` を新規作成（既存 module 分割パターン踏襲）
  - `gh_log` / `gh_warn` / `gh_error` ロガー（`guard-hook:` prefix、`[$REPO]` 3 段書式）
  - `gh_is_enabled`: `IDD_CLAUDE_HOOKS_ENABLED` の **厳密 `true` 一致**判定（typo 安全側）
  - `gh_resolve_dir`: install dir 絶対パス解決（既定 `$HOME/.idd-claude/hooks`、env override）
  - `gh_preflight`: claude version 比較 → install dir 完全性 → smoke test の順で fail-closed
    判定（rc 11/12/13）。stderr に運用者向け復旧ヒントを出力
  - `gh_build_args`: グローバル配列 `CLAUDE_HOOK_ARGS` を opt-out 時 `()` / opt-in 時
    `(--settings <絶対パス>)` で構築
  - shellcheck 警告ゼロ
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 5.1, 5.2, 5.3, 5.4, 5.5, NFR 1.1, NFR 1.3, NFR 2.1_

- [x] 4. `issue-watcher.sh` を guard hook 対応に編集
  - Config ブロックに env var の default 宣言を追加（`IDD_CLAUDE_HOOKS_ENABLED` /
    `IDD_CLAUDE_HOOKS_DIR` / `IDD_CLAUDE_HOOKS_MIN_VERSION=2.1.167` / `IDD_HOOK_LOG`）。
    **既存 env var 名・既定値は一切変更しない**
  - `REQUIRED_MODULES` 配列末尾に `guard-hook.sh` を追加
  - 起動初期化フェーズ（モジュール source 直後、TRIAGE_TEMPLATE 存在チェック付近）で
    `gh_is_enabled && { gh_preflight || exit $?; export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"; }`
    相当の処理を追加し、その後 `gh_build_args` を呼んで `CLAUDE_HOOK_ARGS` を構築
  - 全 `claude --print "$prompt" ... --max-turns ...` 起動箇所（Triage / Developer /
    Reviewer / Architect / per-task Implementer / per-task Reviewer / Iteration / Security
    Review 等、grep `claude \\\\$` 相当で網羅される 15+ 箇所）の末尾に
    `"${CLAUDE_HOOK_ARGS[@]}"` を追加
  - opt-out 時は配列が空 → 既存挙動と diff なし（NFR 1.1 / Req 1.1, 1.2 を担保）
  - shellcheck 警告ゼロ
  - _Requirements: 1.1, 1.2, 1.3, 5.1, 5.2, 5.3, 5.4, 5.5, NFR 1.1, NFR 2.1_
  - _Depends: 3_

- [ ] 5. `install.sh` に hook 一式の user-scope 配置を追加
  - `INSTALL_LOCAL` ブロックに `local-watcher/hooks/*` を `$IDD_CLAUDE_HOOKS_DIR`（既定
    `$HOME/.idd-claude/hooks`）に配置する処理を追加（既存 `copy_template_file` 再利用）
  - `idd-guard.sh` は `--executable` 付与
  - `idd-guard-settings.json` 配置時に `__IDD_HOOK_PATH__` placeholder を絶対パスに sed
    置換（dry-run 時は置換予定だけログに出す）
  - 配置完了後の hint メッセージに opt-in 手順 1 ブロックを追記（cron 行に
    `IDD_CLAUDE_HOOKS_ENABLED=true` を加える例 / fail-closed の挙動 / 別 Issue で consumer
    配布される旨）
  - sudo 要求を追加しない（既存規約維持）
  - `repo-template/` 配下には何も追加しない（Req 6.2, 6.3 / NFR 4.1 / 4.2）
  - shellcheck 警告ゼロ
  - _Requirements: 1.4, 6.1, 6.2, 6.3, NFR 1.2, NFR 2.1, NFR 4.1, NFR 4.2_
  - _Depends: 1_

- [ ] 6. `README.md` に「Guard Hook (PreToolUse) opt-in」節を追加
  - opt-in 手順（`install.sh --local` 再実行 → `claude --version` 確認 → cron に
    `IDD_CLAUDE_HOOKS_ENABLED=true` を追加）
  - env var 一覧（`IDD_CLAUDE_HOOKS_ENABLED` / `IDD_CLAUDE_HOOKS_DIR` /
    `IDD_CLAUDE_HOOKS_MIN_VERSION` / `IDD_HOOK_BASE_BRANCH` / `IDD_HOOK_LOG`、それぞれの
    既定値と上書き方法）
  - fail-closed 挙動と exit code 11/12/13 の意味
  - 既知の限界（NFR 3.1〜3.4 全て）:
    - top-level Bash 文字列のみ解析、`sh -c "..."` / `$(...)` / wrapper 内部は捕捉不能
    - 引数なし `git push` で現ブランチが偶然 base と一致するケースは literal 解析不可
    - G0 の Bash 経由 mutation 検出は best-effort
    - 本初版は role/spec / secrets guard / `bypassPermissions` 廃止を含まない
  - 後続 Issue（consumer 配布）が別途必要である旨を migration note として明記（Req 6.4 /
    人間 Decision 2 の承認条件）
  - ロールバック（env を外せば即 opt-out）
  - _Requirements: 6.4, NFR 1.3, NFR 3.1, NFR 3.2, NFR 3.3, NFR 3.4_

- [ ] 7. 統合スモークテスト・手動検証
  - `install.sh --dry-run --local` で hook 配置が NEW/SKIP/OVERWRITE 行に現れる
  - 使い捨て `$HOME` で `install.sh --local` 実行 → 配置済みファイル存在 + settings.json の
    placeholder 置換確認
  - `IDD_CLAUDE_HOOKS_ENABLED=` 未設定で watcher を `REPO=owner/test REPO_DIR=/tmp/test`
    として起動 → 既存 dry-run（処理対象なし）と diff なし
  - `IDD_CLAUDE_HOOKS_ENABLED=true` + 偽の `IDD_CLAUDE_HOOKS_MIN_VERSION=99.0.0` で起動 →
    exit code 11 で停止、stderr に version 不足理由
  - cron-like minimal PATH (`env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...`) で依存 CLI
    が解決される
  - `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh`
    で 29/29 green
  - 結果を PR 本文の Test Plan に記載
  - _Requirements: 1.1, 1.2, 5.1, 5.2, 5.3, 5.4, 5.5, 6.1_
  - _Depends: 2, 4, 5_

## Verify

本 spec の実装後、stage-a-verify gate watcher が独立再実行する verify コマンドを以下の
構造化ブロックで宣言する。`shellcheck` は新規/編集対象の全 bash スクリプトを対象とし、
fixture driver で hook の 29 件マトリクスを実行する。

<!-- stage-a-verify -->
```sh
shellcheck install.sh local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/guard-hook.sh local-watcher/hooks/idd-guard.sh && bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh
```
