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

### Task 3

- 採用方針: `build_per_task_implementer_prompt` の signature を
  `<task_id> [<redo_mode>]` に拡張し、関数冒頭で `case "$redo_mode" in
  initial|after-round1|after-debugger) ;; *) redo_mode=initial ;; esac` で安全側
  fallback。`redo_mode != initial` の場合のみ、heredoc 直前で 3 つのブロック変数
  （`findings_block_section` / `debugger_block_section` / `closure_matrix_section`）を
  事前に構築し、既存 `learnings_block` と同じパターンで heredoc 内に展開する。
  これにより `redo_mode=initial`（既定）時の出力は既存 1 引数呼び出しと **完全に同一**
  （手動 stdout diff 0 行で確認、NFR 1.1 を構造保証）。
- 重要な判断:
  - **`pt_log` の round 数を引数化しない**: design.md 行 528 は
    `redo_mode=<mode> inject=<comma-sep-files> round=<N>` を例示するが、`build_per_task_implementer_prompt`
    は round を引数で受け取らない設計を選択した（後方互換性の単純化のため。round の
    対応関係 after-round1 ≒ round=2 redo / after-debugger ≒ round=3 redo は
    `run_per_task_loop` 側で構造的に保証される）。pt_log 行は
    `task=<id> redo_mode=<mode> inject=<files>` の 3 フィールドのみで grep 可能 1 行を
    満たし、NFR 3.1 の「注入実施の事実を 1 行で出力」を実現する。
  - **Finding Closure Matrix 規約節を redo 経路 prompt 内に inline で運ぶ**: developer.md
    の規約節（task 7 で追加予定）を canonical source として参照しつつ、prompt 本文にも
    最小限の指示（4 列 / 5 列の使い分け、改変禁止規約への参照、Fix Commit 列の enum 値）
    を 1〜2 段落で運ぶ。Developer agent が prompt のみから本義務を理解できる粒度を確保。
    `after-debugger` の場合は「**5 列目「Fix Plan Step」も必ず追記**」と明示し、
    `after-round1` の場合は「4 項目（4 列）」と明示することで Req 2.5 の Debugger 経路
    限定の 5 列目要件を構造的に区別する。
  - **Finding Closure Matrix 節を「## 既存 commit の温存」の直後（heredoc 末尾近く）に配置**:
    Findings / Fix Plan / Matrix の 3 ブロックを 1 つの位置に集約し、heredoc 内で
    `${findings_block_section}${debugger_block_section}${closure_matrix_section}` を
    順番に展開する。`redo_mode=initial` 時は 3 変数が全て空文字のため、heredoc 末尾の
    展開位置に何も追加されず、既存 prompt と byte 一致を保つ。
  - **抽出失敗時の 1 行明示 + pt_log 構造**: review-notes.md / debugger-notes.md の
    いずれかが抽出失敗した場合でも Developer 起動を継続する best-effort 設計
    （design.md「Error Strategy」/ Req 1.5）。失敗時には prompt に「(... が見つかりません
    / 抽出失敗のため inline 注入を諦めました)」の括弧書き 1 行と spec ディレクトリ配下を
    直接読むよう促す案内文を残し、同時に `pt_log "task=... inject=skipped reason=..."`
    を `>> "$LOG"` 経由で出力する（呼び出し側 `run_per_task_implementer` と同じ既存
    log redirection 規約に準拠）。
- 手動スモーク確認（task 5/8 で正式な test スクリプトを追加するまでの暫定検証）:
  1. `build_per_task_implementer_prompt 1.2` と `build_per_task_implementer_prompt 1.2 initial`
     の stdout diff 0 行を確認（NFR 1.1 / Req 1.4 / 5.5）。
  2. unknown `redo_mode=garbage` が initial に fallback して既存 1 引数と diff 0 行であることを確認。
  3. `after-round1` で review-notes.md 不在時に「review-notes.md が見つかりません」1 行 +
     pt_log `inject=skipped reason=findings-extract-failed` が出力されることを確認（Req 1.5）。
  4. `after-round1` で review-notes.md fixture（normal-2-findings.md）を配置すると
     `### Finding 1` 本文が prompt に inline 埋め込みされ、pt_log
     `inject=review-notes` が出力されることを確認。
  5. `after-debugger` で両 fixture を配置すると Findings と Fix Plan の **両方**が
     inline 埋め込みされ、pt_log が `inject=review-notes,debugger-notes` を出力する
     ことを確認（Req 1.2 / NFR 4.2）。
  6. `after-debugger` で debugger-notes.md 不在時に Findings は注入されつつ
     `pt_log "inject=skipped reason=debugger-section-not-found"` と review-notes 単独
     注入の `inject=review-notes` の双方が独立した行で出力されることを確認。
  7. `after-debugger` prompt に「5 列目「Fix Plan Step」」指示が含まれ、`after-round1`
     prompt には含まれない（4 列指示のみ）ことを確認（Req 2.5）。
  8. `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを確認。
- 残存課題: 
  - task 5/8 で正式な test スクリプト（`pt_extract_findings_block_test.sh` 等の patten
    に倣う `build_per_task_implementer_prompt_test.sh` 相当）を追加するか、または
    integration test として `run_per_task_loop` 経由で end-to-end 検証する判断は未確定。
    本 task では手動スモークで NFR 1.1 / Req 1.5 / Req 2.5 を確認済み。
  - `run_per_task_implementer_redo` wrapper および `run_per_task_loop` の呼び出し点
    改修は task 4 で実装。本 task の signature 拡張は **既存 1 引数呼び出しを壊さない**
    ため、task 4 完了前の段階でも既存 watcher 経路は無改変で動作する。

## 確認事項

なし。
