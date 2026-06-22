# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules/auto-merge.sh` (#352) を雛形にコピーし、`am_` → `amd_` /
  `AUTO_MERGE_` → `AUTO_MERGE_DESIGN_` / `auto-merge:` → `auto-merge-design:` の mechanical
  rename + design 用差分（ready-for-review 必須を削除、needs-iteration 除外を追加）で構築
- 重要な判断:
  - `amd_should_enable_for_pr` から `LABEL_READY` 必須チェックを削除（design PR に
    `ready-for-review` ラベルを付与しないため）
  - `LABEL_NEEDS_ITERATION` 除外を追加（Req 6.4 / 設計 PR iteration 中は merge 抑止）。
    server-side `gh pr list --search` 文字列にも `-label:"$LABEL_NEEDS_ITERATION"` を追加
  - head pattern による排他は `AUTO_MERGE_DESIGN_HEAD_PATTERN` (`^claude/issue-.*-design`)
    の client-side filter で impl PR と自然分離（Req 2.6, 6.7）。impl PR の
    `^claude/issue-.*-impl` head は本 pattern にマッチしないため二重防御として機能
  - tempfile prefix も `am-merge-stderr-` → `amd-merge-stderr-` に置換し、#352 との
    同時実行時にも一意性を保つ
- 残存課題: 本 task では module 単体の関数定義のみで、本体 Config / loader / call site への
  配線（task 2 / 3 / 4）が未完。`LABEL_NEEDS_ITERATION` は本体 `issue-watcher.sh` 側で
  既存定義済みであることを確認済み（line 73 で `LABEL_NEEDS_ITERATION="needs-iteration"`
  として定義されており、本 module 内では遅延束縛で参照可能）

### Task 2

- 採用方針: 既存 `─── Auto-Merge Processor 設定 (#352) ───` ブロック（line 232-250）の
  直後（PR Iteration ブロックの前）に `─── Design Auto-Merge Processor 設定 (#354) ───`
  ブロックを新規挿入。4 env (`AUTO_MERGE_DESIGN_ENABLED` / `_MAX_PRS` / `_GIT_TIMEOUT` /
  `_HEAD_PATTERN`) を `:-default` 形式で宣言し既定 OFF を保証
- 重要な判断:
  - `_HEAD_PATTERN` の既定値は `^claude/issue-.*-design`（#352 の `^claude/issue-.*-impl`
    と対称）。両者は env override 可能で互いに独立に倒せる
  - 既存 `AUTO_MERGE_*`（impl 用、line 232-250）の宣言を一切書き換えず append-only で配置
    （NFR 2.2 の env 名・既定値温存）
  - ブロック冒頭コメントに #352 と同形で「AND 二重 opt-in」「既定 OFF」「`=true` 厳密一致
    以外は OFF」「impl PR との非干渉」「`DESIGN_REVIEW_RELEASE_ENABLED` (#40) との独立共存」
    を明記。task 3 (cycle log 拡張) と task 4 (main loop 配線) が依存する文脈を Config
    ブロック側に集約することで grep 起点を一本化
- 残存課題: 本 task では Config 宣言のみで、`REQUIRED_MODULES` への
  `auto-merge-design.sh` 追加 (task 3) と cycle startup ログへの
  `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` 追加 (task 3) は未着手。
  main loop の `process_auto_merge_design` 呼び出し配線も task 4 で別途実施

### Task 3

- 採用方針: `REQUIRED_MODULES` 配列に `"auto-merge-design.sh"` を `"auto-merge.sh"`
  の直後に挿入し（#352 との対称配置 / NFR 6.2）、cycle startup ログ行に
  `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` を `auto-merge=` と `full-auto=`
  の間に append する 2 箇所の最小編集で task を完結（Req 9.4）
- 重要な判断:
  - REQUIRED_MODULES への挿入位置は `auto-merge.sh` 直後とした。loader 自身は遅延束縛で
    順序非依存だが、可読性 / 対称性 / #352 との grep 整合を優先（design.md の File
    Structure Plan 内 module 順序記述とも整合）
  - startup ログ位置は `auto-merge=...` と `full-auto=...` の間に挟む形を採用。impl 用 /
    design 用 / kill switch という機能順での並びを保ち、運用者の grep 観察を容易にする。
    既定値（unset 時）でも `auto-merge-design=false` が明示出力されることをスモークで確認
    （`env -u AUTO_MERGE_DESIGN_ENABLED ...` で `auto-merge-design=false` 出力を観測）
  - 本体の他 echo 文・他 env 既定値・他 loader entry は一切触らず diff を 4 行追加 / 2 行
    削除に局所化（NFR 2.1, 2.2, 2.3 / 後方互換）
- 残存課題: main loop への `process_auto_merge_design` 呼び出し配線が task 4 で未着手。
  REQUIRED_MODULES で関数定義の前方参照は解決済みのため、task 4 では本体 line 1014
  付近の `process_auto_merge || am_warn ...` 直後への 1 行追加で配線が完了する見込み

### Task 4

- 採用方針: `process_auto_merge || am_warn ...` (line 1024) の直後に
  `process_auto_merge_design || amd_warn ...` を 1 行追加し、impl Auto-Merge (#352) と
  対称配置で main loop に配線。順序は #352 直後 / Promote Pipeline 前を維持（Req 5.4 / 8.4）
- 重要な判断:
  - 配線箇所の直上 comment block (8 行) は #352 の comment block と並列構造で記述し、
    grep / 可読性を担保（AND 二重 opt-in 要件 / head pattern による非干渉 / #40 共存 /
    配置順序の根拠 を明示）
  - 既存 `process_auto_merge` 呼び出し行・他 processor 呼び出し順序は一切変更せず、
    diff を 10 行追加のみに局所化（NFR 2.3 後方互換）
  - shellcheck / bash -n / 既存 `auto-merge_test.sh` 56 件 PASS / dry-run smoke で
    `auto-merge-design=false` ログ出力到達 / `cd: /tmp/test-repo-354` で想定通り
    終了することを確認済み（task 3 で配線済の cycle startup ログが配線後も壊れない
    ことを兼ねて検証）
- 残存課題: 本 task で配線完了。task 5 で新規 fixture テスト
  (`auto-merge-design_test.sh`) を追加する際の参照点として、`process_auto_merge_design`
  が main loop の `process_auto_merge` 直後で確実に呼ばれることをスモークで確認済み
  （test fixture 設計上の前提として活用可能）
