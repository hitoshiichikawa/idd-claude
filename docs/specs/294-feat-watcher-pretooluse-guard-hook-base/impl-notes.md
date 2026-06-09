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

### Task 4

- **採用方針**: design.md / tasks.md の指示通り、`local-watcher/bin/issue-watcher.sh` を
  以下の 4 点で編集して guard hook を配線:
  1. Config ブロック（Debugger 設定直後）に guard hook 系 env var 4 種の default 宣言を追加
     （`IDD_CLAUDE_HOOKS_ENABLED` 既定空 / `IDD_CLAUDE_HOOKS_DIR` 既定 `$HOME/.idd-claude/hooks`
     / `IDD_CLAUDE_HOOKS_MIN_VERSION` 既定 `2.1.167` / `IDD_HOOK_LOG` 既定空）。
     既存「デフォルト有効化フラグの値正規化」ループには **含めない**（opt-in 制 / 既定 false）
  2. `REQUIRED_MODULES` 配列末尾に `guard-hook.sh` を追加
  3. モジュール source 直後（TRIAGE_TEMPLATE 存在チェックの直前）に
     `gh_is_enabled && { gh_preflight || exit $?; export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"; }`
     相当の処理 + `gh_build_args` 呼び出しを追加
  4. 全 11 箇所の `qa_run_claude_stage ... -- claude --print ...` 起動箇所
     （PerTask-Impl / PerTask-Review / Debugger / Reviewer / StageA / StageA-prime-blocked /
     StageA-redo / StageA-pp / StageC / Triage / design）の末尾、`>> "$LOG" 2>&1` リダイレクトの
     直前に `"${CLAUDE_HOOK_ARGS[@]}" \` を 1 行挿入
- **重要判断**:
  - **env var 値正規化ループに加えない**: 既存ループは「`=false` 明示以外はすべて true 既定」の
    9 種（MERGE_QUEUE_ENABLED 等）が対象で、本機能は逆方向（既定空 = opt-out、`=true` 明示のみ
    opt-in）の opt-in 制。正規化に混ぜると `IDD_CLAUDE_HOOKS_ENABLED=` 未設定が `false` 文字列に
    強制され gh_is_enabled の厳密 `true` 一致判定との整合は取れるが、design.md Env Var Contract
    の「未設定 = 無効」表現と齟齬が出るため、Config 段階では `:-` 既定空のまま `gh_is_enabled` 側で
    厳密判定する形を採用（Task 3 で確認した typo 安全側設計と整合）。
  - **preflight + arg 構築の配置点**: TRIAGE_TEMPLATE 存在チェックの **直前**を採用した。
    理由は (a) 必須モジュール source 完了直後で `gh_*` 関数が利用可能 / (b) `BASE_BRANCH` は既に
    確定（108 行目で `:-main` 既定が適用済み）/ (c) `TRIAGE_TEMPLATE` 等の他テンプレ存在チェックが
    失敗するよりも前に preflight を fail-closed させた方が運用者に対する原因切り分けが容易
    （hook 設定不備と template 不備を別 exit code で分離可能）。
  - **CLAUDE_HOOK_ARGS の注入位置**: 各 claude 起動オプションの **末尾**（リダイレクト直前）に
    挿入。`--print` / `--model` / `--permission-mode` / `--max-turns` / `--output-format` /
    `--verbose` の後で `>> "$LOG" 2>&1` の前。これにより既存オプションの解釈順序に影響を
    与えず、Claude Code は `--settings <path>` を後勝ち優先で受け取る。10 箇所は `--verbose \`
    の後に挿入、Triage の 1 箇所のみ `--verbose` を持たないため `--max-turns ...` の後に挿入。
  - **Security Review (`SECURITY_REVIEW_CLAUDE_CMD`) は本 Task のスコープ外**: 同経路は
    `bash -c` 経由で env テンプレート文字列を expand する構造で、`"${CLAUDE_HOOK_ARGS[@]}"` の
    配列展開を直接埋め込めない。tasks.md 本文の「全 `claude --print "$prompt" ... --max-turns
    ...` 起動箇所」の対象には含まれず、配線対象外として扱った（後述「確認事項」参照）。
  - **opt-out 時の空配列展開 (`"${CLAUDE_HOOK_ARGS[@]}"`)**: `set -euo pipefail` 配下でも
    bash 4.4+ で安全（CLAUDE.md bash 4+ 要求）。本機能未配置の環境では `gh_build_args` が呼ばれず
    `CLAUDE_HOOK_ARGS` が undefined のままになる可能性を排除するため、`gh_is_enabled` が false
    でも `gh_build_args` を **無条件で呼ぶ**設計とし、opt-out 時は明示的に空配列を作る
    （design.md gh_build_args 契約と整合）。
- **検証**:
  - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ
  - `shellcheck local-watcher/bin/modules/guard-hook.sh` 警告ゼロ
  - `bash -n local-watcher/bin/issue-watcher.sh` 構文エラーなし
  - `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh`
    で 29/29 green（hook 本体に regression なし）
  - `grep -nE 'CLAUDE_HOOK_ARGS\[@\]' local-watcher/bin/issue-watcher.sh` で 11 件の注入を
    確認（コメント言及 2 件除く）。各サイトに対応する `qa_run_claude_stage` ラベル:
    PerTask-Impl / PerTask-Review / Debugger / Reviewer / StageA / StageA-prime-blocked /
    StageA-redo / StageA-pp / StageC / Triage / design
  - inline smoke で `gh_build_args` の opt-out / opt-in / typo (`True`) を確認: opt-out=空配列 /
    opt-in=`(--settings <abs>)` / typo=空配列（typo 安全側）
- **残存課題**:
  - **install.sh による hook 一式の user-scope 配置（Task 5）が未済**のため、本機能を
    `IDD_CLAUDE_HOOKS_ENABLED=true` で実際に有効化すると preflight が rc=12（install dir
    不完全）で fail-closed する。これは仕様通り（NFR 1.1 の silent fallback 禁止）。Task 5
    完了後に opt-in 起動可能となる
  - README 整備は Task 6 のスコープ
- **確認事項**:
  - `SECURITY_REVIEW_CLAUDE_CMD` 経路（`modules/security-review.sh:910` の
    `bash -c "$cmd_template"` 実行）は env テンプレートに `--settings` を埋め込まないため、
    本 Task の配線対象から外している。design.md 「Modified Files」節は「全 `claude --print
    ...` 起動行に `"${CLAUDE_HOOK_ARGS[@]}"` を付与（既存 15+ 箇所）」と記述しているが、
    実際の `qa_run_claude_stage ... -- claude` パターンは現状 11 箇所であり、Security Review
    は別レイヤ（Skill tool 経由 + env テンプレ）。本 Task では設計指示の本旨である
    「watcher が直接組み立てる `claude --print` 引数列」11 箇所を網羅した。Security Review
    経路を guard hook 配下に置く場合は env テンプレートを `claude -p ... --settings <abs>`
    に拡張する **別タスク**（Task 5 の install 時に `SECURITY_REVIEW_CLAUDE_CMD` の default
    値を opt-in 時のみ書き換える等）が必要。Architect / 人間の判断を仰ぐ

### Task 5

- **採用方針**: design.md「Install Path Mapping」節の指示通り、`INSTALL_LOCAL` ブロックの
  modules 配置直後に新規 helper `install_guard_hooks` を呼び出して `local-watcher/hooks/` 配下の
  3 ファイル（`idd-guard.sh` / `idd-guard-settings.json` / `README.md`）を user-scope に配置する。
  既定 dest は `$HOME/.idd-claude/hooks`、`IDD_CLAUDE_HOOKS_DIR` env で override 可能（hook 本体
  `idd-guard.sh` / watcher module `guard-hook.sh` と同名 env を共有することで preflight・hook
  起動時の dir 解決が一貫する）。配置後の hint メッセージは cron/launchd の platform 分岐外に
  置き、opt-in 手順・fail-closed 挙動・consumer 配布が別 Issue 予定である旨を 1 ブロックで提示。
- **重要判断**:
  - **`idd-guard-settings.json` の placeholder 置換は専用 helper を新設**: 既存
    `copy_template_file` は中身を書き換えない設計のため、`__IDD_HOOK_PATH__` 置換と冪等性を
    両立できない。`copy_hook_settings_with_substitution` を新設し、`mktemp` 上に sed で置換済み
    内容を書き出してから dest と cmp することで「既配置 dest は既に置換済み」状態でも正しく
    SKIP 判定する。これにより再 install 時に毎回 OVERWRITE が走る事故を防ぐ（手動テストで
    SKIP `(identical to substituted template)` を確認）。
  - **sed 区切り文字**: 置換対象が絶対パス（`/` を含む）のため `sed` 区切りは `#` を採用。
    `IDD_CLAUDE_HOOKS_DIR` が `#` を含む奇異な値で破綻するが、ファイルシステム実用上の制約
    から外れるため許容範囲とした。
  - **`resolve_hooks_install_dir` を install.sh 側にも持つ**: hook 本体 / watcher module と
    同じ「末尾スラッシュ除去 + env override」契約を install.sh 内に重複実装する形を採用した。
    install.sh はモジュール source の枠外で動くため、`source` で `modules/guard-hook.sh` を
    取り込む経路を作ると install 時の依存が複雑になる。3 行程度の重複なら明示重複の方が
    install.sh の自己完結性を保ちやすい。
  - **hint 配置位置**: cron / launchd の platform-specific HEREDOC の **直後**（共通の
    `if/else fi` 終端後）に 1 ブロックを置く形を採用。両 platform で同じ案内を出す方が
    運用者の認知負荷が低い。`local` は関数外では使えないため `hooks_dest_for_hint` 変数は
    script-level で代入する形にした。
  - **hint 文字列内の `$HOME` / `\$HOME` の扱い**: `HOOKS_HINT` は unquoted HEREDOC のため
    expand される。cron 行例で `\$HOME/work/...` のように展開させたくない箇所はバックスラッシュ
    エスケープし、`$hooks_dest_for_hint` のように expand させる箇所だけ素のまま記述した。
  - **shellcheck SC2034 等の抑止不要**: 全関数で適切に変数を使い切る形にしたため警告ゼロ。
    既存 `copy_template_file` パターンを踏襲したことで lint 上の特殊対応も不要だった。
- **検証**:
  - `shellcheck install.sh` 警告ゼロ
  - `bash -n install.sh` 構文エラーなし
  - dry-run smoke: tmp HOME で `install.sh --dry-run --local` → 3 件すべて `[DRY-RUN] NEW`
    で出現、`(substitute __IDD_HOOK_PATH__ → /abs/path)` note 付き
  - 実 install smoke: tmp HOME で `install.sh --local` → 3 件配置 + jq で
    `.hooks.PreToolUse[0].hooks[0].command` が絶対パスに置換されていることを確認
  - 冪等性: 同じ tmp HOME で 2 回目 `install.sh --local` → 3 件すべて `SKIP`
    （`identical to template` / `identical to substituted template`）
  - `IDD_CLAUDE_HOOKS_DIR=/tmp/.../custom-hooks` override smoke → override 先に配置され、
    settings.json の command も override 先の絶対パスに置換される
  - `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh`
    で 29/29 green（hook 本体に regression なし）
  - `repo-template/` に新規追加なし（`git diff --stat main..HEAD -- repo-template/` 空、
    `find repo-template -name '*guard*'` 0 件、Req 6.2 / 6.3 / NFR 4.1 を満たす）
- **残存課題**:
  - **README 整備は Task 6 のスコープ**: 本 Task の hint は install 直後の最小限案内であり、
    詳細（env var 一覧 / exit code 11/12/13 の意味 / 既知の限界 NFR 3.1〜3.4 / ロールバック手順）
    は README.md の新節「Guard Hook (PreToolUse) opt-in」で網羅する
  - **統合スモークは Task 7 のスコープ**: 本 Task の手動 smoke は dry-run / real install /
    re-run idempotency / IDD_CLAUDE_HOOKS_DIR override の 4 系統。`IDD_CLAUDE_HOOKS_ENABLED=`
    未設定で watcher 起動して既存挙動と diff なしを確認するのは Task 7 の責務
- **Requirements カバレッジ** (Task 5 _Requirements:_ より):
  - Req 1.4 (sudo 要求を追加しない): 既存 sudo 警告ロジックには触れず、新規 helper も
    `cp` / `mkdir -p` / `chmod +x` / `sed` のみで完結。sudo を一切要求しない
  - Req 6.1 (user-scope ディレクトリ配置): `$HOME/.idd-claude/hooks` 既定で配置、`install.sh
    --local` の `INSTALL_LOCAL` ブロック内のみで実行（`INSTALL_REPO` ブロックには配置しない）
  - Req 6.2 (`repo-template/` 配下に追加しない): `LOCAL_WATCHER_DIR/hooks/` のみを source とし、
    `REPO_TEMPLATE_DIR` 配下には一切触れない
  - Req 6.3 (consumer repo `.claude/` 配下に配布しない): `INSTALL_REPO` ブロックの
    `copy_template_file` / `copy_agents_rules` シーケンスには本 helper を呼び出さない
  - NFR 1.2 (sudo 要求なし): 上記 Req 1.4 と同じ実装で担保
  - NFR 2.1 (shellcheck 警告ゼロ): `shellcheck install.sh` 警告ゼロを確認
  - NFR 4.1 (二重管理規約に新規追加なし): `repo-template/.claude/` には一切ファイルを追加しない
  - NFR 4.2 (consumer repo `.claude/` 配下に新規配置なし): 同上

### Task 6

- **採用方針**: `README.md` の **Feature Flag Protocol 節直後** に新節「Guard Hook (PreToolUse)
  opt-in (#294)」を追加（既存「---」区切りで Feature Flag Protocol と「サブエージェント構成」
  の中間に挿入）。tasks.md L84-99 の指示通り、(a) opt-in 手順 3 step / (b) env var 5 種の
  一覧表 / (c) fail-closed 挙動 + exit code 11/12/13 表 / (d) 既知の限界（NFR 3.1〜3.4 全件）
  / (e) ロールバック手順 / (f) Migration Note（consumer 配布が後続 Issue で別途承認・起票
  必要 = Req 6.4 / 人間 Decision 2 Option A 承認条件）/ (g) 詳細ドキュメントへの相互参照 /
  (h) merge 後の `install.sh --local` 再実行案内 の 8 サブ節で構成。
- **重要判断**:
  - **配置位置**: 「オプション機能一覧」表（L1273〜 opt-in 表）への 1 行追加だけでは
    Req 6.4 / NFR 3.x の網羅文書化要件を満たせないため、独立した h2 節として配置。
    Feature Flag Protocol 直後を採用した理由は (1) 両方とも opt-in 制で対比理解が容易 /
    (2) その直後の「サブエージェント構成」が agent 詳細セクション群の始点で、運用機能
    セクション群（Merge Queue 〜 Feature Flag Protocol）の末尾に並べると一貫性が出る
  - **「オプション機能一覧」表への新規行は追加しない**: 既存表は env-var-based opt-in
    （`MERGE_QUEUE_ENABLED` 等）が中心で、本機能の制御変数 `IDD_CLAUDE_HOOKS_ENABLED` は
    同列に並ぶ性質を持つが、本 Task の指示範囲は「新節を追加」のみであり、表行追加は
    spec 範囲外。表への追加は consumer 配布 Issue で本機能が「user-scope only の限界」を
    解消した時点で改めて整理する方が混乱を避けられる（現状の表は user-scope only であることを
    表現する列を持たないため、誤解を招く可能性がある）。確認事項として後述
  - **env var 5 種の表**: design.md「Env Var Contract」表（`IDD_CLAUDE_HOOKS_ENABLED` /
    `IDD_CLAUDE_HOOKS_DIR` / `IDD_CLAUDE_HOOKS_MIN_VERSION` / `IDD_HOOK_BASE_BRANCH` /
    `IDD_HOOK_LOG`）と Owner / Default / Override 方法を 1:1 で対応させた。typo 安全側
    （`True` / `1` / `yes` は無効）と user-scope 既定値（`$HOME/.idd-claude/hooks`）を
    明示することで運用者が install.sh 再実行のタイミングを判断しやすくしている
  - **exit code 11/12/13 表**: design.md Error Handling 節の rc 表をそのまま流用しつつ、
    各 rc に対応する「復旧手順」列を運用者向けに 1 行で追加（11=Claude 更新 or env 緩める /
    12=`install.sh --local` 再実行 / 13=hook 改変を疑い再 install）。既存 exit code（0/1/99）
    との非干渉を明示する文も含めた（Req 1.3）
  - **既知の限界 4 件**: NFR 3.1〜3.4 を 1:1 で箇条書き化。特に NFR 3.4 の「role/spec /
    secrets guard / `bypassPermissions` 廃止は本初版に含まない」は、運用者が本機能を
    導入後も既存 review ループは必要である旨を理解させるために強調表現で記述
  - **Migration Note**: 「self-hosting 環境でのみ有効 / 他リポで idd-claude を install
    している運用者は本機能を有効化しても当該 consumer repo のエージェントには適用されない」
    旨を明確化（Req 6.4 / 6.2 / 6.3）。これにより consumer 配布 Issue が承認されるまでの
    暫定期間における誤解を未然に防ぐ
  - **言語方針**: 日本語ベース。env var 名 / コマンド名 / exit code 数値 / EARS keyword 等は
    英語固定（CLAUDE.md「言語方針」と整合）。絵文字は `⚠️` 1 件のみ使用（既存
    「⚠️ merge 後の再配置が必要」見出し慣習に倣う / Issue 趣旨に反しない）
- **検証**:
  - `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh`
    で **29/29 green**（hook 本体に regression なし。本 Task は README のみ変更）
  - 真の h1 が 1 件のみ（`^# [^!#]` grep で line 1 の `# idd-claude` 以降は全て fenced
    code block 内の bash comment）であること確認
  - コードフェンス balance: `^```` のカウントが 258（偶数）で fence 開閉ペアが揃っていること確認
  - 内部リンク健全性: 既存節を参照する `(#feature-flag-protocol-23-phase-4)` 形式の anchor
    は本 Task では新規追加せず、既存節への明示的アンカーリンクは控えた（README 末尾の節は
    位置変化なし）
- **AC カバレッジ** (Task 6 _Requirements:_ より):
  - Req 6.4 (consumer 配布の後続 Issue 必要性を明示): Migration Note 節で
    「consumer 配布は後続 Issue で別途承認・起票される前提」を明文化
  - NFR 1.3 (`IDD_CLAUDE_HOOKS_MIN_VERSION` を env で override 可能であることを明記):
    env var 表で「上書き方法 = env で semver 文字列指定」を明示
  - NFR 3.1 (top-level Bash 文字列のみ解析 / `sh -c` / `$(...)` / wrapper 内部は捕捉不能):
    「既知の限界」1 項目目
  - NFR 3.2 (bare `git push` で現ブランチが偶然 base と一致するケースは literal 解析不可):
    「既知の限界」2 項目目
  - NFR 3.3 (G0 の Bash 経由 mutation 検出は best-effort): 「既知の限界」3 項目目
  - NFR 3.4 (本初版は role/spec / secrets guard / `bypassPermissions` 廃止を含まない):
    「既知の限界」4 項目目
- **残存課題**:
  - **Task 7 (統合スモークテスト) は本 Task 外**: `install.sh --dry-run --local` の NEW 行確認、
    使い捨て `$HOME` での実 install 検証、`IDD_CLAUDE_HOOKS_ENABLED=` 未設定での既存挙動
    diff なし確認、`IDD_CLAUDE_HOOKS_ENABLED=true` + 偽 MIN_VERSION での exit 11 確認、
    cron-like minimal PATH 依存解決確認は Task 7 のスコープ。本 Task は README 文書化のみ
  - **consumer 配布 Issue の起票**: Req 6.4 の「人間 Decision 2 Option A 承認条件」として
    consumer 配布の別 Issue 起票が必要だが、起票責務は PM / 人間運用者にあり Developer の
    本 Task スコープ外（PR 本文の「確認事項」で別 Issue 起票が必要な旨を PjM が記載する想定）
- **確認事項**:
  - 「オプション機能一覧」表（L1273〜 opt-in 表）への新規行追加は本 Task では実施しなかった。
    理由は (a) tasks.md L84-99 の指示は「新節を追加」のみで表行追加を含まない /
    (b) 本機能は user-scope only の初版で、既存表は consumer repo 適用前提の env-var-based
    opt-in を一覧化する性質を持つため、本機能を同列に並べると「user-scope only」という
    限界が運用者に伝わりにくくなる可能性がある。consumer 配布 Issue が完了した時点で
    「opt-in」表に正規行として追加する方が運用者の認知負荷が低い。PR 本文「確認事項」で
    Architect / 人間判断を仰ぐことを推奨

### Task 7

- **採用方針**: 本 Task は新規コード変更を伴わず、Task 1〜6 の成果物に対する **6 系統の
  統合スモークテスト + 結果記録** のみで完結させた。tasks.md L101-115 の指示通り 6 件を
  順次実行し、いずれも期待通りの結果が得られたため、コード/ドキュメント側の追加修正は
  不要と判断した（既存 commit を温存）。
- **重要判断**:
  - **smoke 3 (opt-out diff なし) は「タイムスタンプ以外の content 一致」を判定基準とした**:
    watcher の通常ログ出力には ISO 8601 timestamp prefix が必ず付くため、`IDD_CLAUDE_HOOKS_ENABLED`
    未設定の場合と `=false` 明示の場合の 2 回連続実行では timestamp 差分が必ず diff に
    出る。本 spec の Req 1.1 / 1.2 / NFR 1.1 が要求するのは「guard hook を参照する設定が
    一切付与されないこと」「同一の引数列・同一の環境変数集合で claude CLI を起動すること」
    であり、timestamp 差分は本質的に regression ではない。両 run とも guard-hook 関連の
    log 行（`guard-hook:` prefix / preflight 関連メッセージ）が **一切出現していない**
    ことが対照確認の本質であり、それを確認できた。
  - **smoke 5 (cron-like minimal PATH) の評価範囲**: `env -i HOME=$HOME PATH=/usr/bin:/bin
    bash -c ...` の素 PATH では `gh / jq / flock / git` 4 件が `/usr/bin` 配下で解決され、
    `claude` は素 PATH 配下に存在しない（`~/.local/bin/claude`）。`local-watcher/bin/issue-watcher.sh`
    冒頭 L37 の `export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"`
    prepend を経由した時のみ `claude` が解決される設計を再確認した。watcher prepend を
    再現した検証では 5 CLI 全件が解決できる（cron / launchd 環境の依存解決契約を満たす）。
- **検証結果（6 smoke、すべて期待通り）**:
  1. **`install.sh --dry-run --local` の hook 配置確認**: 使い捨て `$HOME` で実行し、
     `[DRY-RUN] NEW       <tmp_home>/.idd-claude/hooks/idd-guard.sh (chmod +x)` /
     `[DRY-RUN] NEW       <tmp_home>/.idd-claude/hooks/idd-guard-settings.json (substitute __IDD_HOOK_PATH__ → ...)` /
     `[DRY-RUN] NEW       <tmp_home>/.idd-claude/hooks/README.md` の 3 行が出現することを確認。
     placeholder 置換予定が note 付きで明示されることも確認
  2. **使い捨て `$HOME` での実 `install.sh --local`**: tmp HOME で実行し、`<tmp>/.idd-claude/hooks/`
     配下に 3 ファイル配置（`idd-guard.sh` 実行ビット付き / `idd-guard-settings.json` /
     `README.md`）を確認。`jq -r '.hooks.PreToolUse[0].hooks[0].command'` で settings.json の
     command が `<tmp>/.idd-claude/hooks/idd-guard.sh` の絶対パスに置換されていることを確認。
     残存 `__IDD_HOOK_PATH__` placeholder 件数 `grep -c '__IDD_HOOK_PATH__'` は **0** を確認
  3. **`IDD_CLAUDE_HOOKS_ENABLED=` 未設定 vs `=false` の watcher 起動差分**: 偽 origin
     remote を持つ tmp repo で watcher を 2 回実行し、`diff -u` の結果が timestamp 行
     （行先頭の `[YYYY-MM-DD HH:MM:SS]`）以外で **content 完全一致**することを確認。両 run
     とも `guard-hook:` prefix の log 行が一切出現せず、preflight も実行されない（opt-in
     制が正しく gate されている）。exit code はいずれも 1（GraphQL 404 by `owner/test` 偽
     REPO 起因 / guard 由来ではない）で一致
  4. **`IDD_CLAUDE_HOOKS_ENABLED=true` + `IDD_CLAUDE_HOOKS_MIN_VERSION=99.0.0` で exit 11**:
     `exit=11` を観測。stderr に次の 2 行が出力されることを確認:
     - `guard-hook: ERROR: claude version 2.1.168 は最小要件 99.0.0 を満たしません`
     - `guard-hook: ERROR: Claude Code を 99.0.0 以上に更新するか、IDD_CLAUDE_HOOKS_MIN_VERSION を緩めてください`
     fail-closed が黙って fallback せず、運用者向け復旧ヒントも含まれることを確認
     （Req 5.1, 5.2, 5.5）
  5. **cron-like minimal PATH での依存解決**: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c
     'command -v claude gh jq flock git'` 直接実行では `gh / jq / flock / git` の 4 件が
     `/usr/bin` 配下で解決される。`claude` は素 PATH 配下に存在しないが、watcher 起動時
     L37 の PATH prepend を経由すれば `~/.local/bin/claude` で解決される設計を再確認。
     watcher prepend を再現した `export PATH="$HOME/.local/bin:$HOME/bin:$PATH"` 付き
     再実行では 5 CLI 全件が解決できることを確認
  6. **`run-tests.sh` で 29/29 green**: `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh`
     を再実行し、G0:5 / G1:6 / G2:5 / Allow:13 の合計 29 ケースすべて PASS、最終行
     `29/29 green` を確認（Task 6 の README 編集および本 Task のスモーク経由でも hook 本体に
     regression なし）
- **AC カバレッジ** (Task 7 _Requirements:_ より):
  - Req 1.1 / 1.2 (opt-out 時の完全互換): smoke 3 で unset / =false の content 一致を確認
  - Req 5.1 / 5.2 (claude version 比較 + 未満時 exit 11): smoke 4 で exit=11 と stderr 確認
  - Req 5.3 / 5.4 (smoke test + 失敗時 exit): smoke 4 で先に version 不足を捕捉したため
    smoke test 経路の検証は本 Task では未実行だが、Task 3 の inline smoke で rc=13 経路
    （`gh_preflight` smoke 失敗）は確認済み（先行 task の verification で吸収）
  - Req 5.5 (silent fallback なし): smoke 4 で exit 11 が確実に発生し fallback なしを確認
  - Req 6.1 (user-scope 配置): smoke 1, 2 で `<tmp_home>/.idd-claude/hooks/` 配下配置を確認
- **残存課題**: 本 Task で発見した bug / 修正対象は **なし**。Task 1〜6 の成果物が本初版
  spec を満たしていることを 6 系統 smoke で確認した
- **確認事項**: なし

STATUS: complete
