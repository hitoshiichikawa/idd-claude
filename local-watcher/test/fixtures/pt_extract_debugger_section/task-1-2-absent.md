# Debugger Notes

<!-- idd-claude:debugger task_id=2.1 model=claude-opus-4-7 timestamp=2026-06-10T00:00:00Z -->

## 概要

Debugger が round=2 reject 後に起動され、task 2.1 の Fix Plan を以下に記録する。
task 1.2 のセクションは本ファイルには **存在しない**（task_id mismatch 時の
return 1 を検証するためのフィクスチャ）。

## Task 2.1

### 根本原因

`pt_extract_debugger_section` の呼び出し側が task_id を未エスケープで awk に
渡しており、`.` が任意 1 文字にマッチしてしまっていた。

### 修正手順

1. shell 側で task_id の `.` を `[.]` にエスケープしてから awk に渡す
2. multi-task fixture で他 task が混入しないことを assert する

### 検証方法

- `bash local-watcher/test/pt_extract_debugger_section_test.sh` を実行し PASS のみであること

## References

- review-notes.md round=2: Finding 1
