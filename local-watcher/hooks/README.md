# idd-claude PreToolUse Guard Hook (opt-in 初版)

idd-claude の watcher が起動する Claude Code エージェントに対し、`PreToolUse` フック経由で
**base ブランチ宛 push**・**無条件 force push**・**guard install dir の自己改変**を機械的に
deny する初版（G0 + G1 + G2）。

## 配置先（user-scope）

| ファイル | 配置先（既定） |
|---|---|
| `idd-guard.sh` | `$HOME/.idd-claude/hooks/idd-guard.sh` |
| `idd-guard-settings.json` | `$HOME/.idd-claude/hooks/idd-guard-settings.json` |
| `README.md` | `$HOME/.idd-claude/hooks/README.md` |

`IDD_CLAUDE_HOOKS_DIR` 環境変数で配置先 override 可。sudo 不要（user-scope 専用）。

配置は `install.sh --local`（Task 5）が user-scope に行う。`repo-template/` には配布しない
（consumer repo への展開は後続 Issue）。

## 環境変数契約

| Var | 用途 | Default |
|---|---|---|
| `IDD_HOOK_BASE_BRANCH` | G1 で deny 対象とする base ブランチ名 | `main` |
| `IDD_CLAUDE_HOOKS_DIR` | G0 で保護する install dir | `$HOME/.idd-claude/hooks` |
| `IDD_HOOK_LOG` | 設定時は判定結果を 1 行 append（任意） | （未設定 = no-op） |

watcher は preflight 通過後に `export IDD_HOOK_BASE_BRANCH="$BASE_BRANCH"` を 1 度だけ行い、
claude プロセスから hook プロセスへ継承される。

## 検査範囲

- **G0**: `Edit` / `Write` / `NotebookEdit` で install dir 配下の path を変更しようとした場合
  に deny。`Bash` 経由は mutation キーワード（`rm` / `mv` / `sed -i` / `chmod` /
  リダイレクト / `tee`）と install dir リテラルの両方を含む場合のみ best-effort で deny
- **G1**: `git push <remote> <base>` / `HEAD:<base>` / `:<base>` / `+<base>` / `-C path push ...` /
  暗黙 remote / `--delete <base>` などの全形態を deny
- **G2**: `-f` / `--force` で deny。`--force-with-lease(=...)` は base 以外なら allow。
  refspec 先頭の `+` は base 以外でも deny

## 既知の限界（NFR 3.1〜3.3）

- top-level Bash 文字列のみ解析する。`sh -c "..."` / `$(...)` / wrapper script 内部の push は
  捕捉できない
- 引数なしの bare `git push` で現ブランチが偶然 base と一致するケースは literal 解析では
  判定不能（NFR 3.2）
- G0 の Bash 経由 mutation 検出は best-effort であり全件捕捉を保証しない（NFR 3.3）
- 本初版は role/spec guard / secrets guard / `bypassPermissions` 廃止を含まない（NFR 3.4）

## decision JSON 出力契約

- deny: `{"decision":"block","reason":"..."}`
- allow: `{}`（decision フィールドなし。Claude 側のデフォルト判定に委ねる）
- exit code は常に 0。jq 不在 / JSON parse 失敗は **fail-closed**（exit 0 + block JSON）

## opt-in 手順

watcher の cron / launchd 行に `IDD_CLAUDE_HOOKS_ENABLED=true` を加える（詳細は repo root の
`README.md` を参照。本ファイルは hook ローカル参照用の短文）。
