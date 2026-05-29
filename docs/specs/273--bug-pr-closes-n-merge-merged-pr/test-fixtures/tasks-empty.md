# Implementation Plan (fixture: 空)

このファイルは Issue #273 の `sc_tasks_unchecked_count` 判定 regex
(`^- \[ \]\*? [0-9]+\. `) の回帰テスト用 fixture。

期待値: タスク行が一切存在しないため、判定 regex に **0 件** マッチする
（見出しのみ。Req 2.4 / 3.2 の縮退ケースに相当）。
