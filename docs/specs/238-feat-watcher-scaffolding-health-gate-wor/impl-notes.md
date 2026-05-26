# Implementation Notes (#238)

## Implementation Notes

### Task 1

- **採用方針**: 新規モジュール `local-watcher/bin/modules/scaffolding-health.sh` を `stage-a-verify.sh` と同形式（冒頭コメント / 3 段 prefix logger / `set -euo pipefail` 非宣言・関数定義のみ）で作成し、logger 3 関数（`sh_log` / `sh_warn` / `sh_error`）と検査純関数 `sh_inspect_scaffolding` を実装した。
- **重要な判断**:
  - `sh_inspect_scaffolding` の非空判定は `find "$dir" -type f -size +0c -print -quit` で行い、`*.md` 限定にせず将来のファイル種別変更に頑健にした（design Decision 4 準拠）。
  - indeterminate（戻り値 2）へ倒すのは「`.claude` が通常ファイル等で存在するのに dir でない真の I/O 異常」と「検査対象パスが空文字列」の 2 ケースに限定。「`.claude`/agents が単に不在」は missing（戻り値 1 + サマリ `agents=missing rules=ok` 等）として扱い、fail-open を濫用しない（design L252 の設計意図）。
  - stdout は missing 時のみサマリを 1 行出力。full / indeterminate 時は無出力（design の stdout 契約）。
- **残存課題**: なし（次 task への影響なし）。本 task は関数定義のみで、本体結線（Config env / REQUIRED_MODULES / preflight gate call site / `--doctor` dispatch）は task 2・3、README 更新は task 4 が担当する。`sh_preflight_gate` / `_sh_emit_visibility_signal` / `sh_doctor_*` は本モジュールに後続 task で追加される（モジュール冒頭コメントにも明記済み）。
