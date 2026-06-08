# Implementation Notes — #294 PreToolUse Guard Hook (base 初版)

## Implementation Notes

### Task 1

- **採用方針**: design.md の指示通り、`idd-guard.sh` は jq で stdin JSON を読み `tool_name`
  で分岐し、Bash の token 分割（top-level のみ）→ git global option skip → push 引数解析の
  順で G1/G2 を判定する純 bash 実装。G0 は Edit/Write/NotebookEdit を path prefix 一致で
  robust に、Bash を mutation keyword + install dir literal の両方一致で best-effort に deny。
- **重要判断**:
  - decision JSON は PoC 準拠の `{"decision":"block","reason":"..."}` を採用。`reason` は
    `jq -n --arg` でエスケープ安全に組み立て、jq 不在時のみ手書きフォールバック。
  - shellcheck SC2088/SC2016 は意図的な `~` / `$HOME` literal substring 検出のため、行単位の
    `# shellcheck disable=` 注釈で抑止（プロジェクト `.shellcheckrc` を汚さない方針）。
  - `--force-with-lease` と `-f` が同時指定された場合は無条件 force と同等扱いで deny
    （design G2 ロジック 2 項）。fixture/driver は Task 2 で形式化するが、24 件の手動
    smoke ですべて期待通りの decision/reason を確認。
- **残存課題**: fixture 29 件と run-tests.sh の整備は Task 2 のスコープ。Task 3 以降の watcher
  module 統合と install.sh 配置は本 commit 範囲外。

### Task 2

- **採用方針**: `test-fixtures/cases/*.json` に 29 件の PreToolUse JSON 入力を 1 ケース 1 ファイル
  で配置（G0:5 / G1:6 / G2:5 / Allow:13）。`expected.tsv` を tab 区切り 3 列
  (`case_file` / `verdict` / `reason_substring`) で宣言し、`run-tests.sh` が SCRIPT_DIR 起点で
  相対解決して repo root の `local-watcher/hooks/idd-guard.sh` を `bash` 経由で起動する純 bash
  ドライバ。
- **重要判断**:
  - hook の decision JSON は jq で `.decision` / `.reason` を抽出して verdict を再構成。
    allow は空 stdout を `actual_verdict=allow` に正規化することで「decision フィールド不在 =
    allow」契約と整合させた。
  - deny ケースの reason は **substring 一致** で突合（hook 側のメッセージ書式変更に
    耐性を持たせるため、`base branch push denied` / `unconditional force push denied` /
    `guard install dir self-mutation denied` の 3 つの安定 prefix のみを宣言）。
  - 環境変数 `IDD_HOOK_BASE_BRANCH=main` / `IDD_CLAUDE_HOOKS_DIR=$HOME/.idd-claude/hooks` は
    driver 内で既定値として export し、外部からの override も受け付ける（既存契約と整合）。
  - G0 fixture の `file_path` / `notebook_path` には `~/.idd-claude/hooks/...` リテラルを
    使用。hook 側の `normalize_path` が `~/` → `$HOME/` 展開して install dir prefix と一致する
    ため、`HOME` 環境差異に依存せず portable に動作する。
  - run-tests.sh は exit code を 0/1/2 で分離（0=29/29 green / 1=mismatch / 2=前提不一致）。
    1 件でも mismatch なら非ゼロ exit する設計で tasks.md 要求を満たす。
- **AC カバレッジ** (Task 2 _Requirements:_ より):
  - Req 2.1〜2.6 (G1 全形態): `g1-base-push-bare` (2.1) / `g1-base-push-srcdst` (2.2) /
    `g1-base-push-delete-colon` (2.3) / `g1-base-push-plus-refspec` (2.4) /
    `g1-base-push-with-C` (2.5) / `g1-base-push-implicit-remote` (2.6) で 1:1 対応
  - Req 3.1〜3.4 (G2): `g2-force-short` (3.1) / `g2-force-long` (3.2) /
    `g2-force-refspec-plus` (3.3) / `g2-allow-lease` + `g2-allow-lease-value` (3.4)
  - Req 4.1〜4.3 (G0): `g0-edit-self` (4.1) / `g0-write-self` (4.2) /
    `g0-bash-rm-self` + `g0-bash-sed-i-self` (4.3) / `g0-notebookedit-self` は 4.1 の派生
  - Allow 13 件は誤発火防止のネガティブテスト（特に `allow-commit-with-push-msg` で
    quoted msg の誤検出回避、`allow-push-then-checkout` で `&&` 後の base checkout が
    pre-split で評価対象外であることを確認）
- **残存課題**: 本 fixture は hook の単体テストであり、watcher の `--settings` 注入経路や
  install.sh の placeholder 置換などは Task 4/5 で別途検証する。本 driver は Task 7 の統合
  smoke でも `bash docs/specs/.../run-tests.sh` として再利用される前提。

### Task 3

- **採用方針**: design.md 「Watcher Module: guard-hook.sh」節の関数 4 + ロガー 3 件 を、
  既存 `stage-a-verify.sh` / `scaffolding-health.sh` と同形式の 3 段 prefix ロガー
  （`[YYYY-MM-DD HH:MM:SS] [$REPO] guard-hook:`）と共に `local-watcher/bin/modules/guard-hook.sh`
  に集約。本体への `source` 経由で読み込まれる前提（単体起動しない / `set -euo pipefail` は
  本体側宣言を流用）。本モジュールは preflight と引数構築のみを責務とし、hook の評価ロジック
  は `local-watcher/hooks/idd-guard.sh`（Task 1 で導入済み）に閉じる単一責任構造。
- **重要判断**:
  - **semver 比較は数値ベース**で実装（辞書順だと `2.1.167` < `2.1.99` になるため）。
    `gh_compare_semver` は `.` で 3 セグメント split し、各セグメント先頭の整数だけ取り出して
    数値比較する（`2.1.167-beta` 等の suffix 付きにも保守的に対応）。戻り値 0/1/2 で
    `pass / fail / parse 失敗` を分離。
  - **claude --version の出力 parse は awk で先頭の `<num>.<num>` を抽出**する設計。`claude
    2.1.167` / `2.1.167 (Claude Code)` 等の代表的書式をどちらも吸収できることを smoke で
    確認した。抽出失敗は rc=11 で fail-closed（運用者向けヒント付き）。
  - **smoke test は jq に依存しない**設計を選択。hook 本体側 (idd-guard.sh) が jq 必須で
    fail-closed する独立レイヤを持つため、watcher 側は `grep '"decision"'` リテラル検査のみで
    十分（allow 期待 = decision フィールド不在 = grep 不一致）。これにより watcher の preflight
    が jq 不在環境でも正しく動作する（hook 起動時は hook 本体が独立に fail-closed）。
  - **CLAUDE_HOOK_ARGS の SC2034 抑止**: 同変数は Task 4 で `issue-watcher.sh` の全 claude 起動箇所
    から `"${CLAUDE_HOOK_ARGS[@]}"` として展開される。本モジュール単体では消費側が無いため
    shellcheck が unused 警告を出す。これは設計上の必然なので、行単位の `# shellcheck disable=SC2034`
    で抑止（`.shellcheckrc` への追加はしない方針＝既存 hook 側 SC2088/SC2016 抑止と同じ哲学）。
  - **install dir の executable 検査も rc=12 配下に含める**。設計の rc=12（install dir 不完全）
    は「ファイル不在」と「ファイル存在するが実行できない」の双方を含む実装にした。後者は
    install.sh のバグや手動権限変更で発生し得、smoke test が exec 失敗で rc=13 に化ける前に
    rc=12 で fail-fast する方が運用者にとって recovery hint が明確になる。
- **検証**:
  - `shellcheck local-watcher/bin/modules/guard-hook.sh` 警告ゼロ
  - 関数別の inline smoke で `gh_is_enabled` typo 安全 / `gh_resolve_dir` 末尾 slash 除去 /
    `gh_compare_semver` の境界 6 ケース（equal / patch ±1 / minor ±1 / major ±1）/
    `gh_build_args` の opt-in/out 配列構築をすべて pass 確認
  - `gh_preflight` の rc 経路を 4 系統で確認: pass / rc=11 (version unmet) / rc=12
    (install dir or exec missing) / rc=13 (smoke test deny)。stderr 出力にも復旧ヒント
    （`install.sh --local 再実行` / `Claude Code を更新` 等）が含まれることを目視確認
  - Task 2 の `run-tests.sh` を再実行し 29/29 green（hook 側 regression なし）
- **残存課題**:
  - 本モジュールは Task 4 (`issue-watcher.sh` への配線) で初めて生きる。`REQUIRED_MODULES`
    末尾追加 + 起動初期化フェーズでの `gh_is_enabled && gh_preflight || exit $?` 連鎖 +
    `export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"` + `gh_build_args` 呼び出しが Task 4 のスコープ
  - install.sh への hook 配置（Task 5）が未済の環境では preflight が rc=12 で fail-closed する。
    これは仕様通り（NFR 1.1 の silent fallback 禁止）だが、Task 5 完了までは watcher を
    `IDD_CLAUDE_HOOKS_ENABLED=true` で起動できない点を運用者に明示する必要がある（README は
    Task 6 で整備）
