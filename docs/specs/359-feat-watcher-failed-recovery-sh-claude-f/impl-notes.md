# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `fr_log` / `fr_warn` / `fr_error` を `core_utils.sh` の `sec_log` ブロック直後に追加。
- 重要な判断:
  - tasks.md の「既存 `pi_log` / `pr_log` と同パターン」記述に従い、`[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery:` の 3 段 prefix（Issue #119 で確立された `[$REPO]` 挿入規約）を採用した。design.md の Logger Layer サンプルコードは `[$REPO]` を省略した簡略形だが、tasks.md の「同パターン」指示と既存 `sec_log` / `pi_log` / `pr_log` の実装が優先と判断（後述 確認事項に明記）。
  - 近接テスト追加は tasks.md 指示通り task 1 では行わず、後続 task の `fr_*_test.sh` 群で間接検証する。
- 残存課題: なし

### Task 2

- 採用方針: `FAILED_RECOVERY_*` env ブロックを `issue-watcher.sh` の Design Review Release（行 487 直後）と Stage Checkpoint（行 489）の間に挿入し、design.md「Config Layer」サンプルに準じた 2 段 case 正規化（ENABLED は `=true` 厳密一致以外 → `false`、MAX_ATTEMPTS は `''|*[!0-9]*` または `-le 0` → 4）を実装。
- 重要な判断:
  - 配置場所は tasks.md「Config ブロック（PR Iteration / Auto-Merge 隣接位置）」に従い、既存 processor 群（PR Iteration / PR Reviewer / Security Review / Design Review Release）のクラスタ末尾とし、後続 Stage Checkpoint 以降のクラスタとは仕切る位置を選んだ。
  - 「デフォルト有効化フラグの値正規化」ループ（`_idd_flag` for-loop）には **加えない** ことを tasks.md 明示（opt-in 制 + 既定 false）に従って実装した。
  - MAX_ATTEMPTS の整数判定は `case` パターン `''|*[!0-9]*` で先に「未設定 / 非整数（負号 `-` / 小数点 `.` / 空白を含む文字列）」を篩い、その後の `*)` 分岐内で `[ "$VAR" -le 0 ]` を `if` で評価することで shellcheck warning ゼロを維持した（`&&` チェーンの 1 行式は exit status が落ちる懸念があるため）。
  - 本 task の単位テストは tasks.md `_Requirements_partial:_ 1.5, 4.8` の deferred として task 3.1（`fr_is_enabled_test.sh`）/ 3.2（`fr_state_test.sh`）に集約する。本実装は手動 fixture（`/tmp` 上の inline スクリプト）で 16 ケース（ENABLED 7 + MAX_ATTEMPTS 9：未設定 / `0` / `-3` / `abc` / `5` / `1` / `100` / `1.5` / ` 4`）の正規化が期待通り動くことを確認済み。
- 残存課題: なし（Task 3.1 / 3.2 で本 env の正規化挙動が間接検証される設計）

## 確認事項

- design.md の Logger Layer サンプル（`fr_log() { echo "[$(date '+%F %T')] failed-recovery: $*"; }`）には `[$REPO]` segment が無いが、tasks.md は「既存 `pi_log` / `pr_log` と同パターン」と明示しており、core_utils.sh の既存 logger（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` / `sec_log`）はすべて Issue #119 以降 `[$REPO]` を含む 3 段 prefix で統一されている。実装は tasks.md の「同パターン」指示 + 既存実装慣習に従って `[$REPO]` 含みで追加した。design.md サンプルは簡略表記と解釈したが、Architect 側で意図相違があれば指摘いただきたい（NFR 4.1「`failed-recovery:` prefix と Issue/PR 番号でログ抽出可能」は本実装で充足）。
