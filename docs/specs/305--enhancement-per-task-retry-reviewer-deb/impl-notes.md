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

### Task 2

- 採用方針: `pt_extract_findings_block`（task 1）と同じ「ファイル存在チェック →
  該当見出し存在チェック → awk セクション抽出」の 3 段階構造を踏襲。`pt_extract_findings_block`
  の直後に `pt_extract_debugger_section` を配置し、namespace と awk pattern を pt_*
  family 内で揃えた。`detect_debugger_already_invoked`（行 4049 周辺）の
  `^## Task <id>$` 行頭マッチ regex と整合させ、Debugger 書き出しセクション規約を共有する
  （design.md Req 1.2 節）。
- 重要な判断:
  - **`.` のエスケープを shell 側で実施**: task_id（例: `1.2`）の `.` は awk 正規表現で
    任意 1 文字メタになる。shell の bash パラメータ展開 `${task_id//./[.]}` で `1.2` を
    `1[.]2` に変換してから awk -v pat で受け渡す。awk 内でエスケープを処理する案
    （`gsub(/\./, "[.]", task_id)` 等）も検討したが、shell 側で完結させた方が awk pattern が
    読みやすく、`grep -qE` での存在チェックと awk pattern を **同一文字列** で再利用できる
    （`heading_pattern` 変数を grep / awk 両方に渡す）ため、メンテナンス面で優位と判断した。
  - **存在チェックを `grep -qE` で先に実施**: ファイル不在 / 該当見出し不在を **同じ
    return 1** として扱う設計（Req 1.5 と整合）。awk 単独だと「見出し不在 = 抽出 0 行 +
    return 0」と「正常抽出 = 本文 + return 0」を区別できないため、task 1 と同じ 2 段階
    構造を採用した。
  - **テストケースを 5 ケースに**: tasks.md の指示は 3 fixture（task-1-2-present /
    task-1-2-absent / multi-task-sections）だが、(a) ファイル不在ケース（fixture を作らず
    存在しない path 文字列を渡す）と (b) multi-task-sections fixture で task_id=1.1 を
    渡したケース（`.` エスケープが逆方向でも事故を起こさないことを assert）を追加。
    fixture を増やすより既存 fixture を再利用した方が意図が明確で、`.` エスケープの双方向
    テストが 1 fixture で済む。
  - **`## References` セクションを fixture に含める**: 「次の `## ` 見出しで停止する」境界を
    明示的に assert するため、task-1-2-present.md と multi-task-sections.md の双方で
    抽出対象セクション後に `## References` を配置。NFR 4.2 の「他 task セクション混入なし」を
    `## Task 1.1` と `## References` の双方向で検証する構造。
- 残存課題: なし（task 3 以降は別タスクで実装）。Task 3 では本 helper を
  `build_per_task_implementer_prompt` から呼び出して `redo_mode=after-debugger` 時の
  inline 注入を実装する予定。

## 確認事項

なし。
