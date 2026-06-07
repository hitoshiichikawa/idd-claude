# Design Document

## Overview

**Purpose**: idd-claude の watcher が起動する Claude Code エージェント（Triage / PM /
Architect / Developer / Reviewer / Iteration / Security Review 等）に対し、Claude Code の
`PreToolUse` フック機構を介して **base ブランチ宛 push** と **無条件 force push** と
**guard install dir の自己改変** を機械的に deny する初版（G0 + G1 + G2）を導入する。違反を
事後 Reviewer で検出するループ（1 違反 = Developer + Reviewer 1 サイクル分の turn 浪費）を
止め、規約違反を実行前点で潰す。

**Users**: idd-claude を self-hosting 運用している運用者（人間）と、その watcher 配下で
fresh session を起動するエージェント群が直接対象。consumer repo への配布は本 Issue では
扱わず、別 Issue で承認・起票する前提。

**Impact**: 既定 OFF の **opt-in（`IDD_CLAUDE_HOOKS_ENABLED=true`）**。未有効時は既存挙動と
完全同一（既存 cron 登録文字列・env var 名・ラベル名・exit code 意味は不変）。有効時のみ
watcher が `claude --print` 起動時に `--settings <絶対パス>` を付与し、Claude Code が
PreToolUse フックを呼び出して Bash / Edit / Write / NotebookEdit を検査する。

### Goals

- G0 / G1 / G2 を同一初版でリリース（人間 Decision 1: Option A）
- user-scope 専用配布（`~/.idd-claude/hooks/` 等。worktree 外。人間 Decision 2: Option A）
- **fail-closed**: opt-in 時に claude version 不足 / smoke test 失敗 → 黙って fallback せず
  非ゼロ exit
- **PoC で確認済みの 29 件テストマトリクスを fixture 化**して回帰検証可能にする
- `shellcheck` 警告ゼロ

### Non-Goals

- role/spec guard / secrets guard / `bypassPermissions` 廃止（後続 Issue）
- `repo-template/` 経由での consumer 配布（後続 Issue。本 Issue では起票責務は持たないが、
  Architect は別 Issue 起票が必要である旨を PR 本文 / README で明示）
- `sh -c "..."` / `$(...)` / wrapper script 内部の push 捕捉（literal 解析の原理的限界）
- guard hook 設定の動的書き換え / 実行時切り替え
- 既存 `bypassPermissions` 全 tool allowlist 化

## Architecture

### Existing Architecture Analysis

- `local-watcher/bin/issue-watcher.sh` は単一の bash 巨大スクリプトで、`set -euo pipefail`
  配下で動作する。モジュール分割は `local-watcher/bin/modules/*.sh` を `REQUIRED_MODULES`
  配列で `source` する形態（`core_utils.sh` / `quota-aware.sh` / `stage-a-verify.sh` 等）
- `claude --print "$prompt" --model ... --permission-mode bypassPermissions --max-turns ...`
  形式の起動が **15 箇所以上**散在する（Triage / Developer / 設計 PR / per-task / Reviewer /
  Security Review / Iteration 各 stage）。すべて `qa_run_claude_stage <label> <reset_file> --
  claude ...` 経由で起動される
- 既存 `qa_run_claude_stage`（`modules/quota-aware.sh`）は **引数列を `"$@"` でそのまま実行**
  する設計。よって「`claude` の前段に `--settings` を挿入する」のではなく「呼び出し側で
  `claude ... --settings <path>` のように引数列を組み立てる」アプローチが自然
- `install.sh` は user-scope 配置を前提（`$HOME/bin`, `$HOME/bin/modules`, `$HOME/.issue-watcher/logs`）。
  sudo は禁止。`local-watcher/bin/*.sh` / `*.tmpl` をワイルドカード一括配置する `copy_glob_to_homebin`
  を既備
- 二重管理規約: `.claude/agents` / `.claude/rules` は root と `repo-template/` の **byte 一致同期**
  が必須。本 Issue は agents/rules を変更しないため抵触しない

### Architecture Pattern & Boundary Map

採用パターン: **opt-in gate + per-call argument injection + 外部 settings.json 参照**

```mermaid
flowchart LR
  subgraph Watcher["issue-watcher.sh (cron)"]
    A[boot] --> B{IDD_CLAUDE_HOOKS_ENABLED=true?}
    B -- no --> C[既存挙動: claude ... をそのまま実行]
    B -- yes --> D[guard_hook_preflight<br/>version + smoke test]
    D -- fail --> E[stderr に理由出力<br/>非ゼロ exit]
    D -- ok --> F[CLAUDE_HOOK_ARGS=--settings $SETTINGS_ABS]
    F --> C2[claude ... ${CLAUDE_HOOK_ARGS[@]}]
  end
  C2 -.PreToolUse.-> H[~/.idd-claude/hooks/idd-guard.sh]
  H -->|deny JSON| C2
  H -.log.-> L[$IDD_HOOK_LOG]
```

**Architecture Integration**:
- 採用パターン: opt-in gate + 引数列拡張 + 外部 settings.json 参照（claude 標準の
  `--settings <path>` を利用）
- 機能境界: (a) `modules/guard-hook.sh`（preflight / argument 構築） / (b) `local-watcher/hooks/`
  配下の hook script + settings.json テンプレ / (c) `install.sh` による user-scope 配置 /
  (d) `issue-watcher.sh` 内の各 claude 起動箇所への `${CLAUDE_HOOK_ARGS[@]}` 注入
- 既存パターンの維持: `qa_run_claude_stage` の signature・呼び出し側の `claude --print ...
  --permission-mode bypassPermissions` 形態・REQUIRED_MODULES 配列・`set -euo pipefail`
- 新規コンポーネントの根拠:
  - guard-hook.sh モジュール: preflight ロジックを単一責任で分離（既存 module 分割パターン踏襲）
  - `local-watcher/hooks/`: source repo 内で hook script / settings テンプレを所有し、
    `install.sh` が user-scope (`~/.idd-claude/hooks/`) に配置する経路を新設

### Technology Stack

| Layer | Choice / Version | Role in Feature | Notes |
|-------|------------------|-----------------|-------|
| Frontend / CLI | — | — | バックエンド機能のみ |
| Backend / Services | bash 4+ | guard hook 本体 / watcher module | `set -euo pipefail` |
| Hook ランタイム | Claude Code `--settings` + `hooks.PreToolUse` | matcher = `Bash\|Edit\|Write\|NotebookEdit` | PoC 検証バージョン: claude 2.1.167 |
| Data / Storage | ローカルファイル（user-scope） | hook script / settings.json / log | `~/.idd-claude/hooks/` 既定 |
| Messaging / Events | stdin/stdout JSON（PreToolUse 契約） | hook ↔ Claude Code | hook は exit 0 + JSON で deny を表現 |
| Infrastructure / Runtime | cron / launchd | watcher 起動 | sudo 禁止 / user-scope |

## File Structure Plan

### New Files

```
local-watcher/
├── hooks/                                    # user-scope に配置される hook 一式の source
│   ├── idd-guard.sh                          # PreToolUse フック本体（Bash/Edit/Write/NotebookEdit 検査）
│   ├── idd-guard-settings.json               # settings.json テンプレ（hook command の placeholder を含む）
│   └── README.md                             # 配置先・env var 契約・既知の限界（短文）
└── bin/
    └── modules/
        └── guard-hook.sh                     # preflight / argument 構築モジュール
                                              #   gh_log / gh_warn / gh_error (gh prefix は guard-hook)
                                              #   gh_is_enabled  : opt-in 厳密判定
                                              #   gh_preflight   : version check + smoke test
                                              #   gh_build_args  : CLAUDE_HOOK_ARGS 配列を組み立て
                                              #   gh_resolve_dir : install dir 解決（env override）

docs/specs/294-feat-watcher-pretooluse-guard-hook-base/
└── test-fixtures/
    ├── run-tests.sh                          # 29 件マトリクスのドライバ（hook を直接起動）
    ├── cases/
    │   ├── g1-base-push-bare.json            # `git push origin main`
    │   ├── g1-base-push-srcdst.json          # `git push origin HEAD:main`
    │   ├── g1-base-push-delete.json          # `git push origin :main`
    │   ├── g1-base-push-plus-refspec.json    # `git push origin +main`
    │   ├── g1-base-push-with-C.json          # `git -C path push origin main`
    │   ├── g1-base-push-implicit-remote.json # `git push main`
    │   ├── g2-force-short.json               # `git push -f origin feature`
    │   ├── g2-force-long.json                # `git push --force origin feature`
    │   ├── g2-force-refspec-plus.json        # `git push origin +feature:feature`
    │   ├── g2-allow-lease.json               # `git push --force-with-lease origin feature`
    │   ├── g2-allow-lease-value.json         # `git push --force-with-lease=ref:sha ...`
    │   ├── g0-edit-self.json                 # Edit on ~/.idd-claude/hooks/idd-guard.sh
    │   ├── g0-write-self.json                # Write on ~/.idd-claude/hooks/idd-guard-settings.json
    │   ├── g0-bash-rm-self.json              # Bash `rm ~/.idd-claude/hooks/idd-guard.sh`
    │   ├── g0-bash-sed-i-self.json           # Bash `sed -i ... ~/.idd-claude/hooks/...`
    │   ├── allow-normal-push.json            # `git push origin feature` (allow)
    │   ├── allow-non-git-bash.json           # 通常 Bash (`ls -la`) (allow)
    │   └── ...                               # 計 29 件（G0:5 / G1:6 / G2:5 / allow:13 想定。run-tests.sh が期待値表を持つ）
    └── expected.tsv                          # ケース名 / 期待 verdict (deny|allow) / 期待 reason 部分文字列
```

### Modified Files

- `local-watcher/bin/issue-watcher.sh`
  - Config ブロックに guard hook 系 env var の default 宣言を追加（`IDD_CLAUDE_HOOKS_ENABLED`,
    `IDD_CLAUDE_HOOKS_DIR`, `IDD_CLAUDE_HOOKS_MIN_VERSION`, `IDD_HOOK_LOG`）
  - `REQUIRED_MODULES` 配列に `guard-hook.sh` を末尾追加
  - 起動初期化フェーズに `gh_preflight` 呼び出しを追加（opt-in 時のみ。失敗で exit）
  - 全 `claude --print ...` 起動行に `"${CLAUDE_HOOK_ARGS[@]}"` を付与（既存 15+ 箇所）。
    `CLAUDE_HOOK_ARGS` は配列で、opt-out 時は **空配列**、opt-in 時は `(--settings <abs>)`
- `install.sh`
  - `INSTALL_LOCAL` ブロックに `local-watcher/hooks/` 配下の user-scope 配置を追加
    （`~/.idd-claude/hooks/` 既定。`IDD_CLAUDE_HOOKS_DIR` env で override 可能）
  - `settings.json` テンプレ中の `__IDD_HOOK_PATH__` placeholder を絶対パスに sed 置換
  - 配置後の hint メッセージに opt-in 手順（`IDD_CLAUDE_HOOKS_ENABLED=true` の渡し方）を追記
- `README.md`
  - 新節「Guard Hook (PreToolUse) opt-in」を追加: opt-in 手順 / env var 一覧 / fail-closed
    挙動 / 既知の限界（NFR 3.1〜3.4 を網羅） / 後続 Issue で consumer 配布する旨

> **二重管理規約**: 本 Issue は `.claude/agents` / `.claude/rules` を変更しない。`diff -r`
> 検証は本 Issue では影響を受けない。`repo-template/` 配下にも追加しない（Req 6.2 / 6.3 /
> NFR 4.1）。

## Requirements Traceability

| Requirement | Summary | Components | Interfaces | Files |
|---|---|---|---|---|
| 1.1〜1.4 | 既定 OFF / opt-in gate / 既存 env var 不変 / sudo 不要 | `gh_is_enabled` / `gh_build_args` / `issue-watcher.sh` Config | `IDD_CLAUDE_HOOKS_ENABLED` 厳密一致 | `modules/guard-hook.sh`, `issue-watcher.sh` |
| 2.1〜2.7 | G1: base 宛 push 全形態 deny | `idd-guard.sh` push 解析 | PreToolUse JSON (in/out) | `hooks/idd-guard.sh`, `test-fixtures/cases/g1-*.json` |
| 3.1〜3.5 | G2: 無条件 force deny / `--force-with-lease` 通す | `idd-guard.sh` flag 解析 | PreToolUse JSON | `hooks/idd-guard.sh`, `test-fixtures/cases/g2-*.json` |
| 4.1〜4.4 | G0: install dir 自己保護 (Edit/Write robust, Bash best-effort) | `idd-guard.sh` path matcher | tool_name + tool_input 判定 | `hooks/idd-guard.sh`, `test-fixtures/cases/g0-*.json` |
| 5.1〜5.5 | fail-closed: version check + smoke test, fallback なし | `gh_preflight` | claude `--version` / dry-run hook invoke | `modules/guard-hook.sh`, `issue-watcher.sh` |
| 6.1〜6.4 | user-scope のみ配布 / repo-template 追加なし / 別 Issue 起票前提 | `install.sh` 配置 + PR 本文記載 | — | `install.sh`, `README.md` |
| NFR 1.1〜1.3 | 既存挙動互換 / sudo なし / env override 可 | `gh_resolve_dir` / Config default | — | `modules/guard-hook.sh`, `issue-watcher.sh` |
| NFR 2.1〜2.2 | shellcheck 警告ゼロ | 全新規/変更 .sh | — | 全 .sh |
| NFR 3.1〜3.4 | 既知の限界を README 明記 | — | — | `README.md` |
| NFR 4.1〜4.2 | 二重管理規約に新規追加なし | — | — | （`repo-template/` 配下に何も置かない） |

## Components and Interfaces

### Watcher Module: guard-hook.sh

#### gh_is_enabled

| Field | Detail |
|---|---|
| Intent | `IDD_CLAUDE_HOOKS_ENABLED` の **厳密 `true` 一致**判定（Req 1.1） |
| Requirements | 1.1, 1.2 |

**Contracts**: Service [x]

##### Service Interface

```bash
# 戻り値: 0 = opt-in 有効, 1 = それ以外（未設定 / 空 / true 以外）
gh_is_enabled() { [ "${IDD_CLAUDE_HOOKS_ENABLED:-}" = "true" ]; }
```

- Preconditions: なし
- Postconditions: 副作用なし
- Invariants: `True` / `1` / `yes` は **すべて false 扱い**（typo 安全側）

#### gh_resolve_dir

| Field | Detail |
|---|---|
| Intent | guard install dir の絶対パスを解決（既定 `$HOME/.idd-claude/hooks`、env で override 可） |
| Requirements | 1.4, 4.1, 6.1, NFR 1.3 |

##### Service Interface

```bash
# stdout: 絶対パス (e.g. /home/user/.idd-claude/hooks)
gh_resolve_dir() { printf '%s' "${IDD_CLAUDE_HOOKS_DIR:-$HOME/.idd-claude/hooks}"; }
```

- Postconditions: 末尾スラッシュなし。物理存在は問わない（呼び出し側が判定）

#### gh_preflight

| Field | Detail |
|---|---|
| Intent | opt-in 時の fail-closed ゲート（claude version 確認 + smoke test） |
| Requirements | 5.1, 5.2, 5.3, 5.4, 5.5 |

##### Service Interface

```bash
# 戻り値: 0 = pass, 非ゼロ = fail（呼び出し側で exit）
# stderr に失敗理由を出力する
gh_preflight() { ... }
```

- 内部処理（決定論順序）:
  1. `IDD_CLAUDE_HOOKS_MIN_VERSION` を読む（既定値は `2.1.167`。PoC 検証バージョン）
  2. `claude --version` の stdout を取得し、semver 比較（`2.1.167` 形式の整数 3 つを `.` で
     split → 辞書順ではなく **数値比較**）。`2.1.167` 未満なら stderr に
     「claude version X.Y.Z is below required <MIN>」を出して `return 11`
  3. install dir の存在確認: `idd-guard.sh` と `idd-guard-settings.json` の **両ファイル**が
     `$(gh_resolve_dir)` 配下に存在しなければ `return 12`
  4. smoke test: `idd-guard.sh` を **stdin に固定 fixture JSON**（`{"tool_name":"Bash",
     "tool_input":{"command":"echo idd-guard-smoke-ok"}}`）で起動し、exit 0 + stdout が
     有効 JSON で `decision != "deny"` であることを確認。失敗で `return 13`
  5. すべて通れば `return 0`
- Postconditions: 副作用は stderr 出力のみ

#### gh_build_args

| Field | Detail |
|---|---|
| Intent | claude 起動引数列に追加すべき配列を `CLAUDE_HOOK_ARGS` グローバル配列に組み立てる |
| Requirements | 1.1, 1.2 |

##### Service Interface

```bash
# 副作用: CLAUDE_HOOK_ARGS グローバル配列を設定する
#   opt-out 時: 空配列 ()
#   opt-in 時: (--settings <絶対パス>)
gh_build_args() { ... }
```

- Postconditions: 呼び出し側は `claude --print "$prompt" ... "${CLAUDE_HOOK_ARGS[@]}"` の形で
  展開する。**空配列は引数を一切追加しない**（Req 1.1, 1.2 の「一切付与しない」を満たす）
- 注: `set -u` 配下で空配列展開 `"${ARR[@]}"` は bash 4.4+ で安全。CLAUDE.md は bash 4+ 要求

### Hook Script: idd-guard.sh

| Field | Detail |
|---|---|
| Intent | PreToolUse 経由で呼び出され、Bash / Edit / Write / NotebookEdit を検査して deny/allow を返す |
| Requirements | 2.1〜2.7, 3.1〜3.5, 4.1〜4.4 |

**Responsibilities & Constraints**
- stdin から PreToolUse JSON を読み、stdout に decision JSON を出して exit 0
  （allow も deny も exit 0。non-zero は Claude Code 側でエラー扱いとなり別経路）
- `tool_name` で分岐:
  - `Bash` → command 文字列を抽出し G1 / G2 / G0(Bash) 解析
  - `Edit` / `Write` / `NotebookEdit` → file_path / notebook_path を抽出し G0 path 一致判定
  - その他 → allow（明示 allow JSON ではなく **decision フィールドを返さない** = Claude 側のデフォルト判定）
- 環境変数契約:
  - `IDD_HOOK_BASE_BRANCH`（必須。watcher が `$BASE_BRANCH` を渡す。未設定で
    `main` フォールバック）
  - `IDD_CLAUDE_HOOKS_DIR`（任意。G0 path 判定の install dir。未設定で
    `$HOME/.idd-claude/hooks`）
  - `IDD_HOOK_LOG`（任意。設定時は deny/allow 判定を 1 行 append。未設定で no-op）

**Dependencies**
- Inbound: Claude Code PreToolUse runtime（stdin JSON） — Critical
- Outbound: stdout JSON（deny / no-decision）, optional `$IDD_HOOK_LOG` への append
- External: jq（JSON パース） — Critical

**Contracts**: Service [x]

##### G1 解析ロジック（Req 2.1〜2.6）

1. command 文字列を bash の `read -ra` 相当で token 分割する（**top-level 文字列のみ**。
   `sh -c "..."` / `$(...)` の中身は解析しない。NFR 3.1 で限界明記）
2. 先頭 token が `git` でなければ G1 対象外
3. 続く token のうち先頭から **global options を skip**: `-C <path>` / `--git-dir=...` /
   `--work-tree=...` / `-c <key>=<value>` の繰り返し（Req 2.5）
4. 次の token が `push` でなければ G1 対象外
5. `push` 以降の token のうち non-flag token を順に取得。先頭 non-flag を remote 候補、
   その次以降を refspec 候補とする。**remote 引数省略の場合（先頭 non-flag がそのまま
   refspec 形）も判定対象**（Req 2.6）
6. refspec 一覧から dst を抽出:
   - `+<dst>` / `:<dst>` / `<src>:<dst>` の dst 部
   - 単独 token（`:` 含まず `+` 接頭辞なし）の場合は **dst = token**
   - `:<dst>` は削除形 → dst を取り出す（Req 2.3）
7. dst が `$IDD_HOOK_BASE_BRANCH` と一致する refspec が 1 件でもあれば **deny**
8. deny 理由: `"base branch push denied: ref=<ref-name>"` を decision JSON の `reason` に
   含める（Req 2.7）

##### G2 解析ロジック（Req 3.1〜3.5）

1. push token 列に `-f` または `--force` が含まれれば **deny**（Req 3.1, 3.2）
2. push 引数列に `--force-with-lease` または `--force-with-lease=...` が含まれる場合:
   - 同時に `--force` / `-f` が無く、かつ dst が `$IDD_HOOK_BASE_BRANCH` 以外 → **allow**
     （Req 3.4）
   - 同時に `--force` / `-f` がある場合は無条件 force と同等 → **deny**
3. refspec token が `+...` 接頭辞を持ち、dst が `$IDD_HOOK_BASE_BRANCH` 以外でも **deny**
   （Req 3.3。base 宛 `+<base>` は G1 でも deny されるが、Req 3.3 は base 以外でも対象）
4. deny 理由: `"unconditional force push denied: use --force-with-lease"` を含める（Req 3.5）

> G1 と G2 はどちらも deny 対象になり得る。**G1 を先に判定し**、base 宛なら G1 reason を
> 返す（運用者にとって base 違反であることが優先メッセージとして有用）。

##### G0 解析ロジック（Req 4.1〜4.4）

1. `tool_name` が `Edit` / `Write` / `NotebookEdit` の場合:
   - `tool_input.file_path` または `tool_input.notebook_path` を取得
   - 絶対パスに正規化（`$HOME` 展開）
   - `$IDD_CLAUDE_HOOKS_DIR` 配下にプレフィックス一致すれば **deny**（Req 4.1, 4.2）
2. `tool_name` が `Bash` の場合（best-effort, Req 4.3, 4.4）:
   - command 文字列に install dir の絶対パスもしくは `~/.idd-claude/hooks` リテラルが
     含まれ、かつ mutation 系コマンドキーワード（`rm` / `mv` / `cp` の dst 側 / `sed -i` /
     `chmod` / `>` / `>>` / `tee` / `cat >`）が同時に含まれれば **deny**
   - **literal 一致のみ。`sh -c "..."` / `$(...)` 内部は解析しない**
3. deny 理由: `"guard install dir self-mutation denied: path=<resolved-path>"`
4. Req 4.4 の「best-effort 明示」: README NFR 3.3 で記述

##### Decision JSON 出力契約

deny 時の例（Claude Code PreToolUse 契約に従う）:

```json
{
  "decision": "block",
  "reason": "base branch push denied: ref=main"
}
```

allow 時（decision フィールドを出さず、Claude 側のデフォルト判定に委ねる）:

```json
{}
```

> 正確なフィールド名（`decision` / `reason` / `permissionDecision` 等）は Claude Code 公式
> ドキュメントの PreToolUse hook 契約に従う。PoC スクリプト（Issue #294 本文の `<details>`）
> が 29/29 で green になっている事実から、PoC で採用された JSON 書式をそのまま採用する。
> 実装時に PoC 書式から外れる必要が生じた場合は Open Questions に記載のうえ確認する。

### Hook Settings: idd-guard-settings.json

| Field | Detail |
|---|---|
| Intent | claude `--settings` に渡す JSON。`hooks.PreToolUse` で `idd-guard.sh` を起動 |
| Requirements | 1.1, 1.2 |

**Contract**: State [x]（静的設定ファイル）

スキーマ（PoC 検証済みフォーマットを踏襲）:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Edit|Write|NotebookEdit",
        "hooks": [
          {
            "type": "command",
            "command": "__IDD_HOOK_PATH__"
          }
        ]
      }
    ]
  }
}
```

- `__IDD_HOOK_PATH__` は install.sh が **絶対パス**に sed 置換する（例:
  `/home/user/.idd-claude/hooks/idd-guard.sh`）
- 相対パス禁止（claude の cwd 依存を避ける）

### Install Path Mapping (install.sh 編集箇所)

| Source (source repo) | Destination (user-scope) | 配置タイミング |
|---|---|---|
| `local-watcher/hooks/idd-guard.sh` | `$IDD_CLAUDE_HOOKS_DIR/idd-guard.sh`（既定 `~/.idd-claude/hooks/idd-guard.sh`） | `--local` / `--all` |
| `local-watcher/hooks/idd-guard-settings.json` | `$IDD_CLAUDE_HOOKS_DIR/idd-guard-settings.json` | 同上（sed で `__IDD_HOOK_PATH__` 置換） |
| `local-watcher/hooks/README.md` | `$IDD_CLAUDE_HOOKS_DIR/README.md` | 同上 |
| `local-watcher/bin/modules/guard-hook.sh` | `$HOME/bin/modules/guard-hook.sh` | 既存 `copy_glob_to_homebin` で自動配置 |

- 配置は既存の `copy_template_file` / `copy_glob_to_homebin` を再利用（once-only safe-overwrite
  挙動を踏襲）
- 配置完了後の hint に opt-in 手順を 1 ブロックで提示（cron 行に `IDD_CLAUDE_HOOKS_ENABLED=true`
  を付ける例）

## Data Models

### Hook Invocation State

PreToolUse hook は **stateless**（毎回 fresh process）。永続状態は持たない。
副作用は optional `$IDD_HOOK_LOG` への 1 行 append のみ。

### Env Var Contract

| Var | Scope | Default | Override | Owner |
|---|---|---|---|---|
| `IDD_CLAUDE_HOOKS_ENABLED` | watcher 全体 | （未設定 = 無効） | env / cron / launchd | 運用者 |
| `IDD_CLAUDE_HOOKS_DIR` | watcher + install + hook | `$HOME/.idd-claude/hooks` | env | 運用者 |
| `IDD_CLAUDE_HOOKS_MIN_VERSION` | watcher（preflight） | `2.1.167`（PoC 検証バージョン） | env | 運用者 |
| `IDD_HOOK_BASE_BRANCH` | hook（内部用） | `$BASE_BRANCH` の値（watcher が export） | env | watcher |
| `IDD_HOOK_LOG` | hook（任意） | （未設定 = no-op） | env | 運用者 |

> watcher は preflight 通過後、`export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"` を 1 度だけ行う。
> claude プロセスは export 環境を継承し、PreToolUse hook プロセスにも継承される。

## Error Handling

### Error Strategy

- **opt-out 時**: 一切のエラー経路を追加しない（既存挙動と完全同一）
- **opt-in 時の preflight fail**: 黙って fallback せず **非ゼロ exit**（Req 5.5）。
  cron なら次サイクルで再評価、launchd なら再起動でリトライ
- **hook 自身の解析エラー**: 解析不能（JSON parse 失敗 / jq 不在）の場合は **fail-open**
  ではなく **fail-closed**（exit 0 + `decision=block` で `reason="guard hook internal error: ..."`
  を返す）。理由: NFR 1.1 の「黙って無効化される fallback を持たない」を hook レベルでも
  踏襲し、guard が壊れているのに通常実行が継続するリスクを排除

### Error Categories and Responses

- **User / Operator Errors**:
  - opt-in したが install dir が無い → preflight rc=12, stderr に「install.sh --local を
    再実行してください」を提示し exit
  - claude version 不足 → preflight rc=11, stderr に「Claude Code を <MIN> 以上に更新するか
    `IDD_CLAUDE_HOOKS_MIN_VERSION` を緩めてください」を提示し exit
- **System Errors**:
  - smoke test 失敗 → preflight rc=13, stderr に hook stdout/stderr 末尾 N 行を添えて exit
  - jq 不在 → hook 内で exit 0 + block JSON（fail-closed）
- **Business Logic Errors（deny 判定）**:
  - G1 / G2 / G0 のいずれも reason に **どの規約**で deny したかを含めて Claude 側に返す
    （Claude Code がエージェントにフィードバック）

### Exit Codes (新規)

| Code | Source | Meaning |
|---|---|---|
| 11 | watcher preflight | claude version unmet |
| 12 | watcher preflight | install dir incomplete |
| 13 | watcher preflight | smoke test failed |
| 0 + decision=block | hook | deny |
| 0 + 空 JSON | hook | allow |

> 既存 exit code（`run_per_task_implementer` の 0/1/99 等）の **意味は変更しない**（Req 1.3）。

## Testing Strategy

### Unit Tests (hook 単体, fixture-based)

`docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh` が
ドライバとなり、`cases/*.json` を stdin に流して hook を起動、stdout の decision JSON と
`expected.tsv` を突き合わせる。**29 件**を網羅:

- G0（自己保護, 5 件）: Edit / Write / NotebookEdit / Bash-rm / Bash-sed-i
- G1（base 宛 push, 6 件）: bare / `HEAD:base` / `:base` / `+base` / `-C path` / 暗黙 remote
- G2（force, 5 件）: `-f` / `--force` / `+<src>:<dst>` / `--force-with-lease` allow /
  `--force-with-lease=value` allow
- Allow 系（13 件）: 通常 push / 通常 Bash / Edit 非対象 path / コメント混入 / 別 base / 等

### Integration Tests

- `install.sh --dry-run --local` で配置予定が NEW/SKIP/OVERWRITE 行に現れる
- `install.sh --local` を新規 `$HOME` で実行 → 配置済みファイルが存在し、`idd-guard-settings.json`
  の `command` が絶対パスに sed 置換されている
- `IDD_CLAUDE_HOOKS_ENABLED=` (未設定) で watcher を起動 → 既存挙動と diff なし（既存
  smoke test の cron-like minimal PATH と組み合わせる）
- `IDD_CLAUDE_HOOKS_ENABLED=true` + claude version 不足を模擬 → 非ゼロ exit / stderr 出力

### Static Analysis

- `shellcheck local-watcher/hooks/idd-guard.sh local-watcher/bin/modules/guard-hook.sh
  install.sh local-watcher/bin/issue-watcher.sh` 警告ゼロ（NFR 2.1）
- jq の `--exit-status` を活用し parse 失敗を捕捉

### Performance/Load

- hook は PreToolUse ごとに新規プロセスで起動するため、**起動オーバーヘッド < 200ms 目安**
  （bash + jq 1 回起動）。性能要件は要件側に存在しないため目安のみ

## Security Considerations

- guard hook 自身は user-scope（権限要求なし）に閉じる。sudo 不要（Req 1.4 / NFR 1.2）
- `$IDD_CLAUDE_HOOKS_DIR` 配下を G0 で自己保護することで「guard を有効化したエージェントが
  guard を無効化する」自己改変ループを防ぐ（Req 4.*）
- hook script は `set -euo pipefail` を宣言し、jq 不在を fail-closed で扱う
- 既存 `bypassPermissions` は廃止しない（Out of Scope）。本機能は **追加レイヤー**として
  振る舞う（既存 model trust + 新規 mechanical deny）

## Migration Strategy

opt-in のため migration は不要だが、以下の運用順序を README に明記:

1. `install.sh --local` 再実行で hook 一式を user-scope に配置
2. `claude --version` で `2.1.167+` を確認（または `IDD_CLAUDE_HOOKS_MIN_VERSION` を緩める）
3. cron / launchd 行に `IDD_CLAUDE_HOOKS_ENABLED=true` を追加（既存 env var はそのまま）
4. 次サイクルから guard 有効。違反検知時は claude 側に block reason が返り、エージェントが
   別経路を取る

ロールバック: `IDD_CLAUDE_HOOKS_ENABLED` を外せば即座に opt-out（hook 関連ファイル削除は
不要）

## Supporting References

- Claude Code Hooks 公式: <https://docs.claude.com/en/docs/claude-code/hooks>（PreToolUse
  契約 / `matcher` / decision JSON 書式）
- Claude Code Settings 公式: <https://docs.claude.com/en/docs/claude-code/settings>
  （`--settings <path>` フラグの引数仕様）

> 上記 2 URL は本設計で参照すべき一次情報。実装時に PoC 書式と公式仕様で書式が異なる場合は
> PoC 書式（29/29 green）を優先しつつ、書式相違を impl-notes.md に記録する。

## Open Questions / 確認事項

1. **Claude Code の `--settings` の優先順位**: `~/.claude/settings.json`（既存ユーザー設定）
   と `--settings <path>`（本機能）の併用時、hooks がマージされるか上書きされるかは公式
   ドキュメントの確認が必要。本設計は **`--settings <path>` を渡せば hook が確実に起動する**
   ことを前提とする。実装時に hooks がユーザー側 settings.json で override される挙動が
   発覚した場合は impl-notes.md に記録のうえ、対処方針（合成 settings.json を `--settings`
   で渡す等）を再検討する
2. **decision JSON フィールド名**: 設計時点では PoC（Issue #294 本文）の書式
   （`{"decision":"block","reason":"..."}`）を採用。公式仕様で `permissionDecision` /
   `hookSpecificOutput` 等の別書式が canonical であれば実装時に PoC 形式と公式仕様の差分を
   確認し、PoC 書式が公式仕様の許容範囲に収まることを impl-notes.md に記録する
3. **`IDD_CLAUDE_HOOKS_MIN_VERSION` の既定値**: PoC 検証済みの `2.1.167` を採用するが、
   将来 Claude Code がより新しい minor で hook 契約を変更する場合に備え、運用者が env で
   緩める / 引き上げる手順を README に明記する
