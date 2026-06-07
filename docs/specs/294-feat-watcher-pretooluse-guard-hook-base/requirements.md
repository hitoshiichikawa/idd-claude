# Requirements Document

## Introduction

idd-claude では現在、すべてのエージェント実行を `--permission-mode bypassPermissions`（god-mode）
で走らせており、「base ブランチへの直接 push 禁止」「無条件 force push 禁止」といった重要規約は
散文ドキュメントでしか宣言されていない。違反は事後の Reviewer 検出ループでしか拾えず、
1 違反あたり Developer + Reviewer の 1 サイクル分の turn を浪費する構造的問題がある。

本 Issue（[#294](https://github.com/hitoshiichikawa/idd-claude/issues/294)）は、Claude Code の
`PreToolUse` フック機構（claude 2.1.167 で PoC 検証済み、G0/G1/G2 合計 29/29 テスト green）を
利用し、外部 `settings.json` 経由で機械的に違反を deny する初版を導入する。初版は **opt-in
（`IDD_CLAUDE_HOOKS_ENABLED=true` で有効化、未設定時は導入前と完全同一挙動）** であり、
watcher 自身の self-hosting 運用での fail-closed 動作を含む。

配布スコープは **user-scope 専用**（worktree 外の `~/.idd-claude/hooks/` 等）に限定する。
`repo-template/` 経由で consumer repo に配布する適用は本 Issue では扱わず、**後続の別 Issue
として起票が必要**（人間による承認条件として明示）。

## Requirements

### Requirement 1: 後方互換性（既定 OFF / opt-in gate）

**Objective:** As an idd-claude 運用者, I want guard hook が未有効時に従来の挙動を一切変えないことを保証したい, so that 既存の cron / launchd 登録および全 consumer repo の動作に regression を起こさず段階的に導入できる

#### Acceptance Criteria

1. While 環境変数 `IDD_CLAUDE_HOOKS_ENABLED` の値が文字列 `true` と完全一致しない（未設定 / 空文字 / `false` / `True` / `1` 等を含む）状態, the watcher shall claude CLI 起動時に guard hook を参照する設定（`--settings` 相当）を一切付与しない
2. While `IDD_CLAUDE_HOOKS_ENABLED` が `true` と完全一致しない状態, the watcher shall guard hook 導入前と同一の引数列・同一の環境変数集合で claude CLI を起動する
3. The watcher shall 既存の環境変数名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `BASE_BRANCH` 等）の意味と既存ラベル名と既存 exit code 意味を本機能導入によって変更しない
4. The watcher shall 本機能のために sudo / root 権限を必要とする手順を追加しない

### Requirement 2: G1 — base ブランチ宛 push の機械 deny

**Objective:** As an idd-claude 運用者, I want エージェントが `$BASE_BRANCH` 宛に push しようとした全ての形を実行前に deny したい, so that base ブランチへの直接 push 規約違反を Reviewer 事後検出ループに頼らず防げる

#### Acceptance Criteria

1. When エージェントが `git push <remote> <BASE_BRANCH>` 形式で base ブランチへ push しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
2. When エージェントが `git push <remote> HEAD:<BASE_BRANCH>` 形式（src:dst 構文）で base ブランチへ push しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
3. When エージェントが `git push <remote> :<BASE_BRANCH>` 形式（remote 側 base ブランチの削除）を実行しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
4. When エージェントが `git push <remote> +<BASE_BRANCH>` 形式（先頭 `+` による force refspec）で base ブランチへ push しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
5. When エージェントが `git -C <path> push ...` や `git --git-dir=... push ...` のような global オプション付き形式で base ブランチへ push しようとしたとき, the PreToolUse guard hook shall global オプションを除去した後の push 引数列を解析して deny する
6. When エージェントが remote 引数を省略した `git push <BASE_BRANCH>` または `git push HEAD:<BASE_BRANCH>` 形式（暗黙 remote）で base ブランチへ push しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
7. If guard hook が deny した場合, the PreToolUse guard hook shall 標準エラーまたは deny 理由メッセージに「base ブランチ宛 push が deny された」旨と当該 ref 名を含めて出力する

### Requirement 3: G2 — 無条件 force push の機械 deny

**Objective:** As an idd-claude 運用者, I want `--force-with-lease` ではない無条件 force push の全形を実行前に deny したい, so that 共有ブランチ上の他者コミットを暗黙に上書きする事故を防げる

#### Acceptance Criteria

1. When エージェントが `git push -f ...` 形式の push を実行しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
2. When エージェントが `git push --force ...` 形式の push を実行しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
3. When エージェントが refspec の先頭に `+` を付けた `git push <remote> +<src>:<dst>` 形式（base ブランチ以外への force refspec を含む）を実行しようとしたとき, the PreToolUse guard hook shall 当該 Bash 実行を deny する
4. Where push 引数列に `--force-with-lease` または `--force-with-lease=<value>` が含まれ, and dst が `$BASE_BRANCH` 以外, the PreToolUse guard hook shall 当該 push を許容する
5. If guard hook が無条件 force を理由に deny した場合, the PreToolUse guard hook shall deny 理由メッセージに「無条件 force push が deny された（`--force-with-lease` を使用すること）」旨を含めて出力する

### Requirement 4: G0 — guard install dir の自己保護

**Objective:** As an idd-claude 運用者, I want guard hook 自身の設定ファイルとスクリプト群がエージェントから改変されないように保護したい, so that guard を有効化したエージェント自身が guard を無効化する自己改変ループを防げる

#### Acceptance Criteria

1. When エージェントが guard install dir（`~/.idd-claude/hooks/` 配下、env var で override 可）配下のファイルを Edit ツールで変更しようとしたとき, the PreToolUse guard hook shall 当該 Edit 実行を deny する
2. When エージェントが guard install dir 配下のファイルを Write ツールで作成または上書きしようとしたとき, the PreToolUse guard hook shall 当該 Write 実行を deny する
3. When エージェントが Bash ツールで guard install dir 配下のファイルを変更する明示的なコマンド（`rm` / `mv` / リダイレクト書き込み / `sed -i` / `chmod` 等のキーワードを含み、対象パスが guard install dir 配下にマッチするもの）を実行しようとしたとき, the PreToolUse guard hook shall best-effort で当該 Bash 実行を deny する
4. The PreToolUse guard hook shall Edit / Write 経由の自己改変を robust に検出し、Bash 経由の検出は best-effort であって全件捕捉を保証しないことを deny 理由または README に明示する

### Requirement 5: fail-closed 起動ゲート

**Objective:** As an idd-claude 運用者, I want hooks を有効化したのに前提条件（claude version / smoke test）が満たされない場合は静かに fallback せず明示的に停止してほしい, so that guard が黙って無効化された状態で長時間運用が継続するリスクを排除できる

#### Acceptance Criteria

1. When `IDD_CLAUDE_HOOKS_ENABLED=true` の状態で watcher が claude CLI 起動を準備するとき, the watcher shall claude CLI の version を取得して `IDD_CLAUDE_HOOKS_MIN_VERSION`（env で override 可）と比較する
2. If claude CLI の version が `IDD_CLAUDE_HOOKS_MIN_VERSION` 未満, the watcher shall claude CLI 起動を中止して標準エラーに version 不足の理由を出力した上で非ゼロ exit する
3. When `IDD_CLAUDE_HOOKS_ENABLED=true` の状態で watcher が起動準備するとき, the watcher shall guard hook の smoke test（hook 設定の syntax 確認 / 必要ファイル存在確認 等の最小検証）を実行する
4. If smoke test が失敗, the watcher shall claude CLI 起動を中止して標準エラーに smoke test 失敗の理由を出力した上で非ゼロ exit する
5. The watcher shall fail-closed 停止時に guard を黙って無効化して claude CLI を起動する fallback 経路を持たない

### Requirement 6: 配布スコープの限定とフォローアップ Issue 起票

**Objective:** As an idd-claude 運用者, I want 初版の配布範囲を user-scope 単独に限定し、consumer repo への展開は別 Issue として独立に承認したい, so that idd-claude self-hosting だけで先行検証してから consumer 影響範囲を判断できる

#### Acceptance Criteria

1. The guard hook 一式（settings.json / hook script）shall worktree 外の user-scope ディレクトリ（既定 `~/.idd-claude/hooks/`）に配置される
2. The 本 Issue の成果物 shall `repo-template/` 配下に guard hook 関連ファイルを追加しない
3. The 本 Issue の成果物 shall consumer repo の `.claude/` 配下に guard hook 関連ファイルを配布しない
4. The 本 Issue 完了時 shall consumer repo への guard hook 適用を扱う別 Issue が起票されている（人間による Option A 承認条件として明示された前提）

## Non-Functional Requirements

### NFR 1: 後方互換性と運用安全性

1. While `IDD_CLAUDE_HOOKS_ENABLED` が `true` 以外, the watcher shall 本機能導入前と完全に同一の cron 登録文字列 / 環境変数 default / ラベル名 / exit code 意味で動作する
2. The 本機能 shall root 権限を要求する手順を含まない（user-scope 前提を維持）
3. The watcher shall `IDD_CLAUDE_HOOKS_MIN_VERSION` を環境変数で override 可能にし、既定値をハードコードせず env default で上書きできる

### NFR 2: 静的解析と品質

1. The 本機能で追加または変更される bash スクリプト shall `shellcheck` を警告ゼロで通過する
2. The 本機能で追加または変更される `.github/workflows/*.yml` shall（該当する場合）`actionlint` を警告ゼロで通過する

### NFR 3: 既知の限界の文書化

1. The README または同等のユーザー可視ドキュメント shall「top-level Bash 文字列のみを解析するため `sh -c "..."` / `$(...)` / wrapper script 内部の push は捕捉できない」旨を明記する
2. The README または同等のユーザー可視ドキュメント shall「bare `git push`（引数なし）かつ現ブランチが偶然 base と一致するケースは literal 解析では判定不能」旨を明記する
3. The README または同等のユーザー可視ドキュメント shall「G0 の Bash 経由 mutation 検出は best-effort であり全件捕捉を保証しない」旨を明記する
4. The README または同等のユーザー可視ドキュメント shall「本初版は role/spec guard / secrets guard / `bypassPermissions` 廃止を含まない」旨を明記する

### NFR 4: 二重管理規約への影響最小化

1. The 本機能 shall guard hook 一式を user-scope 配置とすることで、root `.claude/` と `repo-template/.claude/` の byte 一致同期規約に新規ファイルを追加しない
2. While 採用形態として外部参照設計を採るとき, the consumer repo の `.claude/` 配下 shall 本機能による新規ファイル配置を受けない

## Out of Scope

- role/spec guard（Reviewer の read-only 強制等）— 後続 Issue
- secrets guard（`.env` / `*.pem` 等の staged path ブロック）— 後続 Issue
- Bash 経由の任意書き換えの全面ブロック（`sh -c "..."` / `$(...)` / wrapper script 内部処理は原理的に literal からは捕捉不能であり、初版では限界として README に明記するに留める）
- `bypassPermissions` の廃止 / 全 tool allowlist 化
- `repo-template/` 経由での consumer repo への guard hook 配布（**後続 Issue として別途起票が必要**。本 Issue では起票責務を持たないが、Option A 承認条件として「consumer 適用 Issue を起票する」前提が明示されている）
- guard hook 設定の動的書き換え / 実行時切り替え（env による静的 opt-in のみ）

## Open Questions

- `IDD_CLAUDE_HOOKS_MIN_VERSION` の初期値（PoC 検証済みの `2.1.167` をそのまま既定とするか、より緩めるか）は Architect / 人間判断に委ねる。要件としては「env で override 可能であること」のみを規定し、既定値の具体値は design.md 側で確定する
- guard install dir のパスを env var で override する場合の env var 名（例 `IDD_CLAUDE_HOOKS_DIR`）は実装命名の領分のため design.md に委ねる
