# Debugger Notes

<!-- idd-claude:debugger task_ids=1.1,1.2 model=claude-opus-4-7 timestamp=2026-06-10T00:00:00Z -->

## 概要

Debugger が round=2 reject 後に起動され、task 1.1 と 1.2 の Fix Plan を
1 ファイル内の隣接セクションとして記録する。`pt_extract_debugger_section` が
**task 1.2 のみ** を抽出し、隣接する task 1.1 セクションを混入させないことを
検証するためのフィクスチャ。

## Task 1.1

### 根本原因

task 1.1 固有の原因が記述されている。**この本文は task 1.2 抽出時に
混入してはならない**（NFR 4.2 を構造保証）。

### 修正手順

1. task 1.1 固有の手順 A
2. task 1.1 固有の手順 B

### 検証方法

- task 1.1 固有の検証コマンド

## Task 1.2

### 根本原因

task 1.2 固有の原因が記述されている。`pt_extract_debugger_section "$path" "1.2"`
の抽出範囲は **この見出しから次の `## ` まで** であること。

### 修正手順

1. task 1.2 固有の手順 X
2. task 1.2 固有の手順 Y

### 検証方法

- task 1.2 固有の検証コマンド

## References

- 共通参照セクションは task 1.2 抽出時には **含まれない**（次の `## ` で停止）
