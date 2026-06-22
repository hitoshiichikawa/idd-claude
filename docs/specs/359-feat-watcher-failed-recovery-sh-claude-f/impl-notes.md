# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `fr_log` / `fr_warn` / `fr_error` を `core_utils.sh` の `sec_log` ブロック直後に追加。
- 重要な判断:
  - tasks.md の「既存 `pi_log` / `pr_log` と同パターン」記述に従い、`[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery:` の 3 段 prefix（Issue #119 で確立された `[$REPO]` 挿入規約）を採用した。design.md の Logger Layer サンプルコードは `[$REPO]` を省略した簡略形だが、tasks.md の「同パターン」指示と既存 `sec_log` / `pi_log` / `pr_log` の実装が優先と判断（後述 確認事項に明記）。
  - 近接テスト追加は tasks.md 指示通り task 1 では行わず、後続 task の `fr_*_test.sh` 群で間接検証する。
- 残存課題: なし

## 確認事項

- design.md の Logger Layer サンプル（`fr_log() { echo "[$(date '+%F %T')] failed-recovery: $*"; }`）には `[$REPO]` segment が無いが、tasks.md は「既存 `pi_log` / `pr_log` と同パターン」と明示しており、core_utils.sh の既存 logger（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` / `pr_log` / `sec_log`）はすべて Issue #119 以降 `[$REPO]` を含む 3 段 prefix で統一されている。実装は tasks.md の「同パターン」指示 + 既存実装慣習に従って `[$REPO]` 含みで追加した。design.md サンプルは簡略表記と解釈したが、Architect 側で意図相違があれば指摘いただきたい（NFR 4.1「`failed-recovery:` prefix と Issue/PR 番号でログ抽出可能」は本実装で充足）。
