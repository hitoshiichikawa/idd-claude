# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: Config ブロックの `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` 宣言を `export VAR="${VAR:-default}"` 形式に変更し、`bash -c` 子シェルへの env 継承を確立した。
- 重要な判断: 既定値の文字列リテラル（`claude -p "$SECURITY_REVIEW_PROMPT" ...` 形式）は変更せず、Req 4.3 / NFR 1.2 の意味的内容温存を守った。他の `SECURITY_REVIEW_*` env（`_ENABLED` / `_MODEL` / `_MAX_TURNS` 等）は子シェル内で `$VAR` として参照されないため export しない方針を踏襲（design.md「補強範囲を 2 変数に限定する理由」節準拠）。L323-L328 の既存コメント「既定値中の `\$SECURITY_REVIEW_PROMPT` はリテラル保持し、bash -c subshell が env から展開する」は温存し、export が必要な理由を 2〜3 行のコメントで補強した。
- 残存課題: なし（task 2 以降の前提としての export 化は本 commit で完了。shellcheck 警告ゼロ確認済み）。
