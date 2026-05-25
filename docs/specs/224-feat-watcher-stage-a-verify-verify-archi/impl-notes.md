# Implementation Notes

本ファイルは Developer が per-task ループで追記する実装補足。各 task の採用方針・
重要判断・残存課題・確認事項を記録する。

## Implementation Notes

### Task 1

- **採用方針**: `local-watcher/bin/modules/stage-a-verify.sh` に純関数
  `stage_a_verify_extract_verify_block` を新設。センチネル `<!-- stage-a-verify -->`
  直後の fenced code block を awk 状態機械（state 0/1/2）で厳密パースし、well-formed
  なブロック中身を改行・インデント込みで stdout に出力する。

- **重要な判断**:
  - センチネル直後性は awk の `state==1` で表現。アンカー検出後、空行は任意個スキップし、
    最初の非空行が fence 開始（trim 後 ` ``` ` 始まり）でなければ `done_flag=1` で打ち切り
    （malformed → 中身を出さず END で return 1 相当）。fence 以外の非空行が先に来るケースを
    確実に malformed 化できる。
  - 中身保持は fence 内行を `raw`（trim 前）のまま `buf` に `\n` 区切りで蓄積し、END で
    `printf "%s\n", buf` 出力。`&&` 連結・行継続 `\`・インデントの意味を壊さない（Req 1.4）。
  - malformed 時の return 契約は「stdout 空 + return 1」で統一。well-formed 条件は
    `closed && nonblank`（fence が閉じ、かつ中身に trim 後非空行が 1 行以上）の AND で判定。
    未クローズ（EOF まで `closed=0`）・空ブロック（`nonblank=0`）はいずれも出力しない。
  - 決定論性は最初のブロック処理完了後 `done_flag=1` を立て以降の入力を無視することで担保
    （複数アンカー+fence は最初の 1 つのみ採用、NFR 3.1）。
  - 既存 `stage_a_verify_extract_command` の awk 流儀（`raw`/`line` 変数命名、`^[[:space:]]*```` の
    fence 判定、コメント密度）に合わせ、既存 awk を拡張せず独立関数として分離した
    （抽出基準が「行頭 keyword 一致」と「センチネル + fence 構造」で根本的に異なるため）。

- **検証結果**:
  - `shellcheck local-watcher/bin/modules/stage-a-verify.sh` 警告ゼロ。
  - アドホックスモークで 10 境界を確認（well-formed 単一行 / multiline+`&&` / ` ```sh ` 言語タグ /
    センチネル+fence 無し / 未クローズ / 空ブロック / 複数ブロック→先頭のみ / tasks.md 不在 /
    空行スキップ後 fence / センチネル前後空白+インデント保持）。すべて設計契約どおり
    （well-formed=rc 0・中身出力 / malformed・無し=rc 1・stdout 空）。
  - `git diff` で本変更が 109 行追加のみ・削除行ゼロであることを確認。`extract_command` /
    `resolve_command` / `_sav_cmd_starts_with_keyword` / `stage_a_verify_run` は無変更で既存挙動を温存。

- **残存課題（次 task に影響する事項）**:
  - resolve への組み込み（4 段連鎖の第 1 段化）は **task 2.1** の担当。本 task では
    `stage_a_verify_resolve_command` は無変更。
  - 構造化ブロック由来コマンドの Gate 3 bypass（`_SAV_RESOLVED_SOURCE` 共有）は **task 2.2** の担当。
  - 抽出ロジックの正式 fixture 群 + smoke script（`test-fixtures/`）は **task 6.1** の担当。
    本 task のスモークはアドホックで commit には含めていない。
