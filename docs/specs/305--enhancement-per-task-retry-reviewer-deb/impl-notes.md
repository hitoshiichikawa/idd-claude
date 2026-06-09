# Implementation Notes

per-task ループ運用（Issue #305）の Developer 実装ログ。各 task ごとに `### Task <id>` 見出しで
learning を追記する。先行 task の見出しは改変・削除・並び替えしない。

## Implementation Notes

### Task 1

- 採用方針: `pt_extract_learnings` の awk pattern を踏襲して `pt_extract_findings_block` を実装。
  `## Findings` 見出し以降、次の `## ` 見出し直前までを stdout に出力する。RESULT 行や Summary
  セクションは抽出範囲に含まれない（次セクションで停止）構造により Req 1.3 / NFR 4.1 を保証。
- 重要な判断:
  - **ファイル不在と `## Findings` 見出し不在を同じ return 1 として扱う**: Req 1.5 が「ファイル
    不在 / 当該 round の Findings 抽出に失敗する」を 1 つの条件として括っているため、呼び出し側
    （task 3 で実装予定の `build_per_task_implementer_prompt`）は return 1 だけを見て「諦め 1 行
    明示 + pt_log」に進める。先に `grep -qE '^## Findings[[:space:]]*$'` で見出し存在を確認して
    から awk 抽出に進む 2 段階構造を採った（awk 単独だと「ファイル空 = 抽出 0 行 + return 0」と
    「見出し不在 = 抽出 0 行 + return 0」を区別できないため）。
  - **見出し判定パターン `^## Findings[[:space:]]*$`**: 末尾空白を許容（design.md / 既存
    `pt_extract_learnings` と同方針）。先頭の `## ` は厳密一致（`### Findings` の h3 や本文中の
    `## Findings は重要だ` 等を誤検知しない）。
  - **テスト fixture を 4 ケースに**: tasks.md の指示は 3 fixture（normal-2-findings /
    no-findings-section / findings-with-nested-headers）だが、Req 1.5 のファイル不在ケースを
    fixture を作らずに「存在しない path 文字列」をテスト内で渡すケースとして追加。fixture
    ファイルを増やすより意図が明確になる。
- 残存課題: なし（task 2 以降は別タスクで実装）。

## 確認事項

なし。
