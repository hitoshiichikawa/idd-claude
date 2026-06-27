# Implementation Notes — Issue #422

## 設計判断

### 採用案 A（実行後 exit code による事後判定）の根拠

- 仮案 C（実行前 `command -v` による事前 SKIP）は **採用しない**:
  - watcher 側で connector / verify cmd を pre-parse する必要があり、連結（`&&` /
    `||` / `;`）や複合構文（`if cond; then ...`）を網羅的に検査する実装複雑度が高い
  - 連結中の **どの位置のコマンドが未導入か**は事前判定では分からず、結局は実行を要する
  - 既存挙動（structured block を `bash -c` にそのまま流す Req 1.3 規約）と整合させやすい
- 仮案 A（実行後 exit code 127 を観察して降格判定）を採用:
  - 既存の `case "$rc"` 結果分岐に **1 ケース追加**するだけで実装可能
  - 連結コマンドの先頭・途中・末尾どこで未検出が起きても、bash -c の最終 exit code
    が 127 になるケースは「未検出のみ」と同型に判定できる（POSIX `sh(1)` "Exit Status"
    規定: コマンドが見つからない場合は 127）
  - real fail（exit=1 等）が混在し最終 exit code が real fail のものになるケースは
    既存 default 分岐へ落ちる → Req 2.4 を自然に満たす

### 判定方法（rc=127 単独 vs `command not found` 文字列併用）

- **rc=127 のみで判定**を採用:
  - bash の `command not found` メッセージは locale（LANG=ja_JP.UTF-8 等）で日本語化
    されるため、文字列照合だけに依存すると環境差で取りこぼしが出る
  - 偽装（`exit 127` builtin で意図的に 127 を返す）は理論上可能だが、verify ブロックは
    tasks.md の構造化フェンスで人間レビューを経て確定する入力であり、意図的偽装は
    運用前提に含めない（既存 path-missing 判定 `exit=2 + diff:` 前置きと同じ信頼境界）
- `_sav_extract_tool_name_from_cmd` での **ツール名抽出には stderr を併用**:
  - 判定（127 → WARN 降格）には stderr 不要だが、**WARN ログの観測性向上**（Req 4.3）の
    ためツール名抽出には stderr の `bash: line N: <tool>: command not found` を活用
  - 抽出失敗時は cmd 先頭 token に fallback、それも空なら `(unknown)` をログに残す

### 配置順序（path-missing → tool-missing → real fail）

- `case "$rc"` の分岐順序: `0` → `124` → `127`（新規）→ `*`（default で path-missing 判定 →
  real fail）
- exit=2（path-missing）と exit=127（tool-missing）は **数値が重ならない**ため、分岐の
  前後関係に functional な意味はないが、コード可読性の観点で「専用 exit code →
  default」の順を維持
- 既存 `_sav_is_path_missing_diff_failure` は `*` 分岐内で先頭に残置（NFR 1.1 既存挙動温存）

### 既存ヘルパとの一貫性

- 新規ヘルパは既存 `_sav_is_path_missing_diff_failure` / `_sav_extract_missing_path` と
  **同じスタイル**で実装:
  - 純粋関数（副作用なし、入力 = 引数のみ）
  - 防御的検証（非整数 rc を安全側 = real fail に倒す）
  - `set -e` 環境で `grep` 無マッチが exit=1 で巻き込まれないよう `|| true` で吸収
- ファイル冒頭の `_SAV_LAST_OUTCOME` 値域コメントに `warn-tool-missing` を追加し、
  `warn-skipped`（#364）との 1 対 1 区別を明記（Req 4.4）

## 変更ファイル一覧

- `local-watcher/bin/modules/stage-a-verify.sh`（編集）
  - `_sav_is_tool_missing_failure` 関数追加（`_sav_extract_missing_path` 直後）
  - `_sav_extract_tool_name_from_cmd` 関数追加（同位置）
  - `case "$rc"` ブロックに `127)` 分岐を新規追加（`124)` と `*)` の間）
  - `_SAV_LAST_OUTCOME` 値域コメントに `warn-tool-missing` を追記
- `local-watcher/test/stage_a_verify_tool_missing_test.sh`（新規）
  - Section 1: `_sav_is_tool_missing_failure` 単体 8 ケース
  - Section 2: `_sav_extract_tool_name_from_cmd` 単体 7 ケース
  - Section 3: `stage_a_verify_run` 統合 10 ケース（合計 60 個の assert）
- `README.md`（編集）
  - 「Stage A Verify Gate (#125)」節 / 失敗・異常系に **WARN 降格（tool-missing / #422）**
    の段落を追加
  - ログ grep 例リストに `WARN: reason=verify-tool-missing tool=<tool> exit=127 cmd=...` を追加
  - WARN grep 案内に `reason=verify-tool-missing` フィルタを追記
  - run-summary 表の `stage-a-verify` outcome に `warn-tool-missing` を追加
  - opt-in 機能一覧表の Stage A Verify Gate 行の関連 Issue に `#422` を追加
- `repo-template/local-watcher/bin/modules/stage-a-verify.sh`: **存在せず**（`install.sh` が
  `local-watcher/bin/modules/` から直接配布する構成のため同期不要）

## 検証結果

| 検証項目 | コマンド | 結果 |
|---|---|---|
| 新規テスト | `bash local-watcher/test/stage_a_verify_tool_missing_test.sh` | PASS=60 FAIL=0 |
| 既存 path-missing テスト | `bash local-watcher/test/stage_a_verify_path_missing_test.sh` | PASS=43 FAIL=0 |
| 既存 round1 defer テスト | `bash local-watcher/test/stage_a_verify_round1_defer_test.sh` | PASS=8 FAIL=0 |
| 既存 timeout pgkill テスト | `bash local-watcher/test/stage_a_verify_timeout_pgkill_test.sh` | PASS=23 FAIL=0 |
| shellcheck（モジュール + 全テスト） | `shellcheck local-watcher/bin/modules/stage-a-verify.sh local-watcher/test/stage_a_verify_*.sh` | clean |
| shellcheck（broader） | `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` | clean |
| 構文チェック | `bash -n local-watcher/bin/modules/stage-a-verify.sh` | OK |
| 二重管理 diff | `diff -r .claude/agents repo-template/.claude/agents` / rules | 空（差分なし） |

## AC Traceability

| AC | 実装 | 検証テスト |
|---|---|---|
| Req 1.1 | `stage-a-verify.sh` `127)` 分岐 / round counter 不変 | tool-missing Case 1.1, 3.1 (mark_issue_failed 呼ばれない検証) |
| Req 1.2 | `127)` 分岐の `return 0` / `_SAV_LAST_OUTCOME="warn-tool-missing"` | tool-missing Case 3.1 (rc=0 検証) |
| Req 1.3 | `127)` 分岐は `gh issue comment` を呼ばない | tool-missing Case 3.1 (gh issue comment 不在検証) |
| Req 1.4 | `_SAV_LAST_OUTCOME="warn-tool-missing"` 露出 | tool-missing Case 3.1 (outcome 検証) |
| Req 1.5 | `STAGE_A_VERIFY_COMMAND` env 経路でも結果分岐に到達 | tool-missing Case 3.9 |
| Req 2.1 | bash の短絡評価で先頭 exit 127 → 全体 127 | tool-missing Case 3.4 |
| Req 2.2 | bash の連結末尾 exit 127 → 全体 127 | tool-missing Case 3.3 |
| Req 2.3 | 単独 exit 127 = 連結全体 exit 127 と同一処理 | tool-missing Case 3.1 |
| Req 2.4 | real fail と混在で最終 exit が real fail → default 分岐 | tool-missing Case 3.5 |
| Req 2.5 | `124)` 分岐が `127)` より前で既存挙動温存 | timeout_pgkill 全 23 ケース継続 PASS |
| Req 3.1 | `0)` 分岐は未変更 | tool-missing Case 3.7 / round1 / timeout_pgkill |
| Req 3.2 | `124)` 分岐は未変更 | timeout_pgkill 全 23 ケース |
| Req 3.3 | `*)` 分岐内の path-missing 判定は未変更 | path_missing Case 3.1 / tool-missing Case 3.8 |
| Req 3.4 | `*)` 分岐の real fail 経路は未変更 | tool-missing Case 3.6 / path_missing Case 3.2 |
| Req 3.5 | rc=130 等は `*)` 分岐へ落ちる（既存挙動） | tool-missing 単体 Case 1.6 |
| Req 4.1 | `sav_warn` で `stage-a-verify: WARN:` prefix 維持 | tool-missing Case 3.1 (grep 抽出検証) |
| Req 4.2 | WARN log に `reason=verify-tool-missing` 固定文字列 | tool-missing Case 3.1, 3.3, 3.4, 3.9 |
| Req 4.3 | `_sav_extract_tool_name_from_cmd` でツール名抽出 → `tool=<name>` | tool-missing 単体 Section 2 全 7 ケース |
| Req 4.4 | `_SAV_LAST_OUTCOME="warn-tool-missing"` で `warn-skipped` と区別 | tool-missing Case 3.1 + Case 3.8（warn-skipped が混在しない検証） |
| Req 4.5 | WARN log に `exit=127` と `cmd=<shell-quoted>` を含む | tool-missing Case 3.1 |
| NFR 1.1 | `STAGE_A_VERIFY_ENABLED=false` の挙動完全温存 | tool-missing Case 3.10 |
| NFR 1.2 | 既存 env var 名 / exit code 意味（0/1/2）を不変 | tool-missing Case 3.5 / 3.6 / 3.7（rc=0/1 維持） |
| NFR 1.3 | 既存 outcome 値（success/disabled/skip/warn-skipped/round1/round2）を不変 | path_missing 全 43 / timeout_pgkill 全 23 |
| NFR 2.1〜2.3 | 既存 3 テスト pass 維持 | path_missing 43 / round1_defer 8 / timeout_pgkill 23 PASS |
| NFR 3.1 | `_sav_is_tool_missing_failure` は副作用なし純粋関数 | tool-missing 単体 Case 1.1〜1.8 |
| NFR 3.2 | `_sav_extract_tool_name_from_cmd` も同様 / extract_function イディオム可能 | tool-missing 単体 Case 2.1〜2.7 |
| NFR 4.1 | `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` prefix を WARN でも維持 | tool-missing Case 3.1 (grep 抽出検証で prefix 込み確認) |
| NFR 4.2 | WARN 行を 1 行で記録 | `sav_warn` 1 回呼び出し / Case 3.1 grep 抽出で複数行分割なし確認 |

## 確認事項

- **後段ステージへの引き継ぎ事項**: 本変更は env gate なしで挙動が変わるが、変更対象は
  「従来 `claude-failed` 化される exit 127 を WARN 降格する」方向の **救済** のみで、
  既存 SUCCESS / path-missing WARN / round1 / round2 / disabled の挙動は不変。後方互換は
  `STAGE_A_VERIFY_ENABLED=false` 明示時の no-op を含めて維持される（NFR 1.1）。
  既存 spec の retroactive 適用は不要で、次サイクル以降で `exit 127` 観測時のみ自然に
  新分岐へ流れる
- **locale 依存**: `_sav_extract_tool_name_from_cmd` の stderr 戦略 1（`bash: line N:
  <tool>: command not found` regex）は **LANG=C / en 前提**。LANG=ja_JP.UTF-8 等で
  `… コマンドが見つかりません` 表記になる場合は戦略 2（cmd 先頭 token）に fallback
  する設計のため、判定不能による誤動作は起きない（`tool=(unknown)` 相当が出るのみ）。
  運用上 cron は `LANG=C` でセットされているケースが多いと想定して問題ない
- **PM / Architect への差し戻し提案**: なし。Issue #422 の要件は本 PR で完全に充足
- **派生 Issue 候補**: 仮案 C（事前 `command -v` SKIP）を併用する設計改善は本 spec の
  Out of Scope（design.md 余地として明示）。現状の事後判定で運用上問題ないため、
  別 spec で再評価予定なし

STATUS: complete
