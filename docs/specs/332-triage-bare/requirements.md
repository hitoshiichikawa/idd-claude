# 要件定義: Triage への --bare オプション導入（TRIAGE_BARE, opt-in）

- Issue: [#332](https://github.com/hitoshiichikawa/idd-claude/issues/332)
- 対象ファイル想定: `local-watcher/bin/issue-watcher.sh`（config / Triage 起動）、`local-watcher/bin/triage-prompt.tmpl`、`README.md`

## Introduction

Triage の判定基準（status / needs_architect / edit_paths）は `triage-prompt.tmpl` 内で自己完結しているが、claude 起動時に CLAUDE.md + `.claude/rules`（推定 2〜3 万トークン）が自動ロードされている。Claude Code CLI の `--bare`（2.1.x で確認済み）は hooks / skills / plugins / MCP / CLAUDE.md / rules のロードをスキップする。本機能は opt-in env `TRIAGE_BARE` で Triage のみ `--bare` 実行を可能にする。`--bare` でのツール可用性差異に依存しないよう、テンプレートの結果書き込みを Write ツールから Bash heredoc に統一する。

## Requirements

### Requirement 1: TRIAGE_BARE opt-in

#### Acceptance Criteria

1. The watcher shall `TRIAGE_BARE`（既定 `false`、`true` 厳密一致のみ有効）を持つ
2. While `TRIAGE_BARE` が `true` であるとき, the watcher shall Triage の claude 起動に `--bare` を付与する
3. While `TRIAGE_BARE` が `true` 以外（未設定 / 空 / typo / 大文字）であるとき, the watcher shall 本機能導入前と完全に同一の引数で Triage を起動する
4. The watcher shall Triage 以外の claude 起動に `--bare` を付与しない

### Requirement 2: guard hook との衝突回避（安全側）

#### Acceptance Criteria

1. While `TRIAGE_BARE=true` かつ guard hook（`IDD_CLAUDE_HOOKS_ENABLED` opt-in）が有効であるとき, the watcher shall `--bare` を付与せず（guard hook を優先）、見送りの WARN を `$LOG` に 1 行記録する
2. The README shall 両機能が併用不可であることを明記する

### Requirement 3: テンプレートの書き込み経路統一

#### Acceptance Criteria

1. The triage-prompt.tmpl shall 結果 JSON の書き込み指示を「Bash ツールの heredoc」に変更する（`--bare` 時のツール可用性差異に依存しない経路。非 bare でも同様に動作するため単一テンプレートで両対応）
2. The triage-prompt.tmpl shall 判定ロジック・JSON スキーマ・edit_paths 指示を変更しない

## Non-Functional Requirements

1. The watcher shall 既存 env var / ラベル / exit code / cron 文字列を変更しない
2. When `shellcheck` を実行したとき, the build pipeline shall 新規警告 0 件にする
3. The build pipeline shall 既存テストスイートを全 PASS のまま維持する

## Out of Scope

- `TRIAGE_BARE` の既定 true 化（実環境での判定品質確認後に別途検討）
- Triage の stream-json 化（#325 の計測対象化。別課題）
- 他 stage への `--bare` 展開（Developer / Reviewer は CLAUDE.md / rules が判定の正本のため対象外）
