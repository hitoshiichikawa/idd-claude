# 実装ノート — #237 gitignore 運用 repo 向け worktree reset 後 `.claude/` 注入

## 採用した注入方式と選定理由

**案 A（auto-detect）を採用。env gate は追加しない。**

- 注入条件は「worktree に `.claude/` が **無い** かつ 注入元 REPO_DIR に `.claude/` が **有る**」の
  ときのみ。
- tracked 運用 repo（idd-claude 自身 / feedman / altpocket 等）は `.claude/` が commit 済みのため
  `git reset --hard` 後の worktree に必ず `.claude/` が存在し、auto-detect により注入は走らず
  **NO-OP**（Req 2.1 / 2.3 を機械的に保証 / Req 2.4 の安全側デフォルトを構造的に満たす）。
- gitignore 運用 repo は worktree に `.claude/` が無いため注入が走る（Req 1.1）。consumer は
  `install.sh --repo` で REPO_DIR の `.claude/` を最新化しておけば zero-config で機能する。
- これは「新しい外部サービス呼び出し」ではなく **ローカルファイルコピー**であるため、CLAUDE.md の
  「opt-in gate なしで新しい外部サービス呼び出しを有効化」禁止事項には該当しない。auto-detect が
  既存挙動非変更を構造的に保証するため env gate は不要と判断した。

**env gate（案 B）を採らなかった理由**: env gate を追加すると「gitignore 運用 repo の運用者が
明示的に true を立てる」操作が必要になり zero-config 性が失われる。auto-detect は tracked 運用 repo を
NO-OP にしつつ gitignore 運用 repo を自動救済できるため、後方互換性と利便性を両立できる。

## 注入関数の責務・配置・呼び出し位置・注入元 REPO_DIR の捕捉

- **新規関数**: `_worktree_inject_claude`（`local-watcher/bin/modules/core_utils.sh`、
  `_worktree_reset` の直後に配置）。ファイル冒頭の責務コメントの worktree 管理関数列挙にも追記。
  - 引数 `$1` = 注入元 REPO_DIR、`$2` = 注入先 worktree 絶対パス。
  - NO-OP 1: `[ -e "$wt/.claude" ]` → tracked 運用 repo は即 return 0（Req 2.1）。
  - NO-OP 2: `[ ! -d "$src/.claude" ]` → 注入元無しは即 return 0（Req 2.2）。
  - コピー: `cp -a "$src/.claude" "$wt/"` で mode / timestamps / symlink を保持（Req 4 / R4.2: `.claude/`
    ディレクトリのみ・R4.4: `.github/scripts/idd-claude-labels.sh` を含めない）。成功時 `slot_log`。
- **呼び出し位置**: `local-watcher/bin/issue-watcher.sh` の `_slot_run_issue` 内、`_worktree_reset` 成功
  かつ `slot_log "worktree reset OK ..."` の直後（`_hook_invoke` / agent 起動の **前**）に
  `_worktree_inject_claude "$SRC_REPO_DIR" "$WT"` を追加（Req 1.3）。
- **注入元 REPO_DIR の捕捉**: `_slot_run_issue` は `REPO_DIR="$WT"`（issue-watcher.sh:6799 付近）で
  REPO_DIR を worktree path に上書きする。注入元となる「consumer のローカル `.claude/`」は
  **上書き前の元 REPO_DIR** にあるため、上書き行の直前で `local SRC_REPO_DIR="$REPO_DIR"` に捕捉して
  注入関数へ渡す。変数捕捉は既存パターン（サブシェル内の局所上書き）と整合し最も単純なため採用。

## fail-open の実装方法（`set -euo pipefail` 下での非致命化）

- `_worktree_inject_claude` は **常に return 0** を返す設計にした。コピー失敗時も `slot_warn` を出して
  return 0（Req 3.1 / 3.2 / 3.3）。これにより `set -euo pipefail` 下でも呼び出し側
  `_worktree_inject_claude "$SRC_REPO_DIR" "$WT"` が非ゼロで `_slot_run_issue` を倒すことがない。
- 呼び出し側は `_slot_mark_failed` を呼ばないため、注入失敗のみで `claude-failed` へ遷移しない（Req 3.3）。
- コピー失敗時は中途半端な `.claude/` が次サイクルの auto-detect を NO-OP 化して不完全状態を温存し
  うるため、`rm -rf "$wt/.claude" 2>/dev/null || true` でベストエフォート除去してから warn・継続する。

## テスト結果

### shellcheck

- `shellcheck local-watcher/bin/modules/core_utils.sh` → **警告ゼロ（exit 0）**。
- `shellcheck local-watcher/bin/issue-watcher.sh` → SC2317（info, 未到達誤判定）が **11 件**。これは
  本変更前後で件数同一（baseline 11 / after 11）で、すべて既存の indirect ロガー関数に対するもの。
  本変更が新規 SC2317 を導入していないことを `git stash` での before/after 比較で確認済み。
- `shellcheck docs/.../test-fixtures/test-inject-claude.sh` → **警告ゼロ（exit 0）**。間接呼び出しされる
  stub `slot_log` / `slot_warn` の SC2317 は `# shellcheck disable=SC2317` で抑制（既存スタイルに倣う）。

### スモークテスト（`test-fixtures/test-inject-claude.sh`）

`_worktree_inject_claude` を単体 source し、`slot_log` / `slot_warn` を stub して隔離検証。
**全 14 アサーション PASS（exit 0）**:

- Case (a): worktree に `.claude/` 無し + REPO_DIR に `.claude/` 有り → 注入され
  `.claude/agents` `.claude/rules` が worktree に出現 + 注入ログ出力（R1.1 / R1.2 / R1.4）。
- Case (b): worktree に `.claude/` 既存（tracked 運用相当）→ 上書きされず注入元 rules も混入しない
  完全 NO-OP + ログ無し（R2.1）。
- Case (c): REPO_DIR に `.claude/` 無し → `.claude` を作らず warn も出さない NO-OP・return 0（R2.2）。
- Case (d): `cp -a` で実行権限（`+x`）と symlink が保持される（R4）。
- Case (e): 2 回実行しても 2 回目は worktree 既存 `.claude/` を上書きしない冪等動作（R4.1）。

### dry-run 退行確認（reset 契約の順序）

`_worktree_reset` 本体（`reset --hard origin/<base>` → `clean -fdx` の順序、#180 / #198 の data-loss
防止方針）は **一切変更していない**。注入は `_worktree_reset` 成功後に追加で呼ぶだけで、reset の前段に
割り込んだり順序を変えたりしていない（NFR 1.2）。`REPO_DIR="$WT"` 上書きの直前に `SRC_REPO_DIR` 捕捉行を
追加しただけで、既存の REPO_DIR 上書きセマンティクス・後段の `git -C "$REPO_DIR"` 系参照は不変。

## README の更新箇所

`README.md` の `### SLOT_INIT_HOOK` 節の直後に
`### gitignore 運用 repo への .claude/ 注入（auto-detect / Issue #237）` を新設。
注入の起動タイミング・条件・注入元 / 手段 / 対象・commit 扱い・fail-open・env gate なし・consumer 前提
（`install.sh --repo` で `.claude/` 最新化）・後方互換（tracked 運用 repo は NO-OP）・ログ判別 grep 例を記載。

## 後方互換の根拠（tracked 運用 repo が NO-OP になること）

- tracked 運用 repo は `.claude/` を commit 済み → `git reset --hard origin/<base>` で worktree に
  `.claude/` が **必ず復元される** → `_worktree_inject_claude` 冒頭の `[ -e "$wt/.claude" ]` 判定が
  真になり即 return 0（注入スキップ）。よって tracked 運用 repo の worktree 内容・ログ・遷移は不変。
- 新規 env var を追加していないため env 契約は不変。ラベル遷移・exit code・ログ書式・worktree reset
  契約のいずれも変更していない（NFR 1.1 / 1.2）。

## 変更ファイル一覧

- `local-watcher/bin/modules/core_utils.sh` — `_worktree_inject_claude` 追加 + 冒頭責務コメント更新
- `local-watcher/bin/issue-watcher.sh` — `SRC_REPO_DIR` 捕捉 + reset 直後の注入呼び出し追加
- `README.md` — `.claude/` 注入挙動の節を追加
- `docs/specs/237-feat-watcher-gitignore-repo-worktree-res/test-fixtures/test-inject-claude.sh` — スモークテスト（新規）
- `docs/specs/237-feat-watcher-gitignore-repo-worktree-res/impl-notes.md` — 本ノート（新規）

## 受入基準ごとのテスト担保

| AC | 担保 |
|---|---|
| R1.1 注入実行 | smoke Case (a) |
| R1.2 agents/rules 参照可能化 | smoke Case (a)（`.claude/agents` `.claude/rules` 出現を assert） |
| R1.3 reset 後・agent 起動前に実施 | 呼び出し位置（issue-watcher.sh の reset 成功直後・`_hook_invoke` 前）＋コードレビュー |
| R1.4 注入ログ出力 | smoke Case (a)（`slot_log` 呼び出しを assert） |
| R2.1 既存 `.claude/` を上書きしない | smoke Case (b) |
| R2.2 注入元無しは NO-OP | smoke Case (c) |
| R2.3 tracked 運用 repo の外形不変 | smoke Case (b)（NO-OP）＋後方互換根拠 |
| R2.4 安全側デフォルト | auto-detect 構造（env gate 無し / 既存挙動側に倒れる）＋ smoke Case (b)/(c) |
| R3.1 失敗時 warn | コード（コピー失敗パスで `slot_warn`）。Case (c) で正常 NO-OP は warn を出さないことも確認 |
| R3.2 失敗時継続 | 関数が常に return 0（smoke 全 Case で return 0 を assert）＋呼び出し側が `_slot_mark_failed` 非呼出 |
| R3.3 失敗で claude-failed にしない | 呼び出し側で `_slot_mark_failed` を呼ばない（コードレビュー）＋関数 return 0 |
| R4.1 冪等 | smoke Case (e) |
| R4.2 `.claude/` 以外を巻き込まない | `cp -a "$src/.claude" "$wt/"` がディレクトリ単位（コードレビュー）＋ Case (b) で rules 非混入 |
| R4.3 commit しない | 呼び出し側で git add / commit を行わない（コードレビュー）。`.claude/` は gitignore 対象のまま |
| R4.4 idd-claude-labels.sh を含めない | コピー対象が `.claude/` のみ（`.github/scripts/` に触れない / コードレビュー） |
| NFR1.1 env / ラベル / exit / ログ書式不変 | 後方互換根拠＋ shellcheck SC2317 件数不変 |
| NFR1.2 reset 契約退行なし | `_worktree_reset` 未変更（dry-run 退行確認） |
| NFR1.3 後方互換破壊時の migration | 該当なし（後方互換を破っていない。env 追加なし） |
| NFR2.1 連続サイクル一貫性 | smoke Case (e)（冪等） |
| NFR2.2 並列 slot 非干渉 | 各 slot の worktree path・REPO_DIR はサブシェル局所で独立。注入は per-worktree なので干渉しない（コードレビュー） |
| NFR3.1 実行/スキップ/失敗をログ判別 | 注入時 `slot_log` / 失敗時 `slot_warn` / NO-OP は無ログ（Case a/b/c で確認）＋ README に grep 例 |

## 確認事項

なし

STATUS: complete
