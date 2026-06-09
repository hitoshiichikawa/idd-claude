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

### Task 4

- 採用方針: 既存 `run_per_task_implementer` を **無改変**で温存しつつ、新規 wrapper
  `run_per_task_implementer_redo <task_id> <redo_mode>` を直後に追加。内部 claude 起動部
  （qa_run_claude_stage / quota 検出 / pt_log）はほぼ同形だが、prompt 組み立てを
  `build_per_task_implementer_prompt "$task_id" "$redo_mode"` に置換し、stage_label を
  `PerTask-Impl-Redo-${task_id}-${redo_mode}` にする 2 点のみ差分。これにより quota
  ledger / log grep で初回 (`PerTask-Impl-${task_id}`) と redo (`PerTask-Impl-Redo-...`)
  を構造区別できる（NFR 3.1 補強）。
- 重要な判断:
  - **wrapper 内では redo_mode の妥当性検証を行わない**: `build_per_task_implementer_prompt`
    側で `initial|after-round1|after-debugger` 以外は `initial` に fallback する安全側設計
    （task 3 で実装済み）になっているため、wrapper で重複検証すると分岐が二箇所に散る。
    wrapper は受け取った値をそのまま prompt 組み立てと stage_label に渡し、値域保証は
    build 関数に一本化した。stage_label 用 ASCII 制約は redo_mode 値域 (`initial` /
    `after-round1` / `after-debugger`) が事前定義された ASCII セットのため別途検証不要。
  - **`_qa_reset_file` の path セグメントを `pt-impl-redo-${task_id}-${redo_mode}-${_qa_ts}`
    に拡張**: 既存 `pt-impl-${task_id}-${_qa_ts}` と衝突しない一意 path にすることで、
    round=2 redo / round=3 redo / 初回 round=1 が同一 task で同時刻に並走しても
    quota_reset_file が混ざらない（tick 内逐次実行のため実害は無いが防御的）。
  - **3 箇所の呼び出し点のうち 2 箇所のみ置換**: tasks.md task 4 の指示通り、`run_per_task_loop`
    の 4 つの Implementer 呼び出しのうち以下のみ置換した:
    - 行 3904 (round=1 initial): **無改変**（初回起動は Findings 注入対象外）
    - 行 3973 (BLOCKED redo): **無改変**（BLOCKED は Reviewer reject ではないため Findings
      注入対象外。Fix Plan は Implementer が `### Task <id>` セクションを自発参照する従来契約を維持）
    - 行 4025 (round=2 redo): `run_per_task_implementer_redo "$task_id" "after-round1"` に置換
    - 行 4087 (Debugger 経由 round=3 redo): `run_per_task_implementer_redo "$task_id"
      "after-debugger"` に置換。従来の「Fix Plan 注入は per-task Implementer の prompt
      builder には未対応のため、debugger-notes.md の存在を Implementer が `### Task <id>`
      セクションで読むことに依拠する」コメントを更新し、inline 注入経路への切替を明記
  - **BLOCKED 経路で `run_per_task_implementer_redo` を呼ばない判断**: BLOCKED 経路は
    Implementer が `BLOCKED: <reason>` を impl-notes.md に書き出し → Debugger Gate が起動
    → Implementer 再起動という流れで、ここで起動される Implementer は「Debugger Fix Plan
    に従って実装をやり直す」役割を持つ。一見 `after-debugger` 相当に思えるが、本経路は
    Reviewer reject 経由ではないため `review-notes.md` の Findings が存在しない（あるいは
    別 task / 別 round の Findings で意味的に無関係）。Findings inline 注入は false-signal
    になるため、BLOCKED 経路は `redo_mode=initial` 相当（= 既存 `run_per_task_implementer`
    無改変）を維持する設計が正しい（tasks.md task 4 の明示指示と一致）。
- 手動スモーク確認:
  1. `bash -n local-watcher/bin/issue-watcher.sh` で syntax OK を確認
  2. `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを確認
  3. `grep -nE 'run_per_task_implementer(_redo)? "\$task_id"' local-watcher/bin/issue-watcher.sh`
     で 4 箇所の使い分けを確認（initial 2 箇所 / redo 2 箇所）
  4. 既存スモークテスト `pt_extract_findings_block_test.sh` / `pt_extract_debugger_section_test.sh`
     が引き続き全 PASS を確認（task 4 は wrapper 追加のみで pt_* helper を改変していない
     ため当然 PASS だが、回帰確認として実行）
- 残存課題:
  - task 5 で fail-fast 経路 (`pt_snapshot_review_notes` / `pt_check_fail_fast` /
    `pt_mark_fail_fast_failed`) を実装し、task 6 で `run_per_task_loop` の round=2 reject
    直後に組み込む。本 task 4 の wrapper 化は task 6 の fail-fast 経路と非干渉
    （fail-fast 判定は Debugger Gate 前に走るため、`run_per_task_implementer_redo` 起動
    前段で fail-fast 成立 → claude-failed 経路で短絡される）。

### Task 5

- 採用方針: `pt_extract_findings_block` / `pt_extract_debugger_section` の直後
  （issue-watcher.sh 行 2688 付近）に 3 つの新規 helper を順に追加する。既存
  `pt_extract_*` ヘルパー群と同じ `pt_*` namespace に集約することで、namespace
  境界（design.md「Architecture Pattern & Boundary Map」節）を維持。fixture は
  design.md「File Structure Plan」節の指示通り 3 ケース構造（fixture
  ディレクトリ配下に `prev-round1.md` / `curr-round2.md` / `git-diff.txt` の
  triple）を採用したが、design.md の File Structure Plan 例示にあった
  `.tsv` 拡張子（1 fixture = 1 tsv）ではなく、`tasks.md` task 5 詳細の
  「2 つの review-notes.md ペア + tsv 出力」記述に従い **3 ファイル構造**を
  選択した（review-notes.md 形式を fixture に持つことで `pt_extract_findings_block`
  系の awk 抽出と pattern を共有でき、テストの読み手にとっても意図が透明）。
- 重要な判断:
  - **`_pt_ff_extract_tuples` を pt_check_fail_fast 内部の nested function に**:
    `(category, target)` tuple 抽出は本機能専用の独自抽出ロジック（design.md
    「Components and Interfaces」節）であり、他経路から再利用される予定がない。
    関数として外出しにすると pt_* namespace の API 表面が広がり、`extract_function`
    awk による単体テスト関数抽出の責務境界も曖昧になるため、nested function 化
    して隠蔽した。これにより `extract_function "$WATCHER_SH" "pt_check_fail_fast"`
    の 1 関数抽出 + eval だけでスモークが動く構造を維持できた。
  - **awk pattern で `### Finding` 遷移時の確定出力ロジックを修正**: 初版では
    `^### Finding[[:space:]]/` を最優先 rule にしていたが、`### Finding 2` 行で
    `cur_target` / `cur_category` を **確定出力する前に** 0 リセットしていたため
    Finding 1 が消失する bug が発生した（awk のルールは独立評価ではなく順序
    評価のため、最初のルールで `next` する前に reset するとデータ消失する）。
    修正後は `^### /` を統一 rule にして「`### ` 見出しに遷移したら直前の
    Finding を確定出力 → reset → in_finding を Finding 種別で更新」の順に
    変更し、Finding 1 + Finding 2 の双方が出力されることを fixture テストで
    確認した。
  - **テストファイル判定の case 分岐を 4 段階に分割**:
    (1) 拡張子マッチ（`_test.sh` / `.test.ts` 系 / `_test.go` / `_test.py` を
    bash の `case` パターンで 1 ブロック）
    (2) `test_*.py` パターン（先頭が `test_` で `.py` 拡張子。ファイル名先頭 +
    ディレクトリ末尾の双方を `*/test_*.py|test_*.py` で受ける）
    (3) ディレクトリマッチ（`/test/` / `/tests/` / `/__tests__/` / `/spec/`）
    (4) `local-watcher/test/fixtures/**` の特例（idd-claude self-hosting で
    本 spec fixture 自体が `local-watcher/test/fixtures/` 配下にあり、本判定基準
    で「テスト関連差分」として確実にマッチさせるための明示分岐）
    design.md「テストファイル判定基準」節の OR 結合と完全に整合する。
  - **fail-fast 不成立時の reason 分類を 5 種類に拡張**: design.md の
    Physical Data Model 例示は `no-shared-finding` / `test-diff-present` /
    `prev-snapshot-missing` の 3 種だが、防御的に `curr-review-notes-missing`
    （round=2 review-notes.md 不在 / 想定外だが安全側に倒すため）と
    `git-diff-failed`（`git diff --name-only` 自体が失敗した場合に
    `claude-failed` を発火させない / Req 3.4 安全側）も追加した。いずれも
    return 1 で既存 Debugger Gate 経路に進む形となり、誤検出を抑止する。
  - **fake git 関数の最小実装**: stage_a_verify_round1_defer_test.sh の
    fake gh 注入パターンを踏襲しつつ、本テストでは `git diff --name-only` の
    1 サブコマンドのみを fixture の git-diff.txt の中身で差し替える形にした。
    他の git サブコマンド（rev-parse / log 等）は本関数から呼ばれないため
    127 を返す stub にして「想定外呼び出しを検出可能」にしている。
- 手動スモーク確認:
  1. `bash local-watcher/test/pt_check_fail_fast_test.sh` で 5 ケース × 18 assert
     すべて PASS（成立 / 共有なし / カテゴリ違い + テスト差分あり / snapshot 不在 /
     共有あり + テスト差分あり）
  2. `bash local-watcher/test/pt_extract_findings_block_test.sh` PASS（regression）
  3. `bash local-watcher/test/pt_extract_debugger_section_test.sh` PASS（regression）
  4. `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロ
  5. `bash -n local-watcher/bin/issue-watcher.sh` syntax OK
- 残存課題:
  - task 6 で `run_per_task_loop` の round=2 reject 直後に本 3 関数を組み込む
    （snapshot 取得 → sha_before/after 記録 → pt_check_fail_fast 呼び出し →
    成立時 pt_mark_fail_fast_failed → return 1 / 不成立時 Debugger Gate 経路継続）。
    本 task 5 の関数群は **すべて pure functional**（副作用は `pt_mark_fail_fast_failed`
    の gh API のみで、それも mark_issue_failed への委譲）なため、task 6 の
    呼び出し側改修と非干渉。
  - design.md 行 528 の Physical Data Model に列挙された reason enum 値
    （`no-shared-finding` / `test-diff-present` / `prev-snapshot-missing`）に対し、
    本実装では防御的に `curr-review-notes-missing` / `git-diff-failed` を追加した。
    design.md 側を更新する判断もあり得るが、本 task の範囲は「実装」であり design
    書き換え禁止規約に従って **本 task では design.md に手を入れない**。必要なら
    PM / Architect に差し戻して design.md を補強する。

### Task 6

- 採用方針: `run_per_task_loop` 既存改変は以下 3 箇所のみ:
  (1) `while IFS= read -r task_id; do` 直後（行 4166 周辺）に当該 task の前 cycle
  残骸 snapshot を `rm -f` する防御的 cleanup を追加
  (2) round=1 reject ブランチ `1)` の冒頭、`run_per_task_implementer_redo
  "$task_id" "after-round1"` 呼び出しの **直前**（行 4294 周辺）で
  `pt_snapshot_review_notes "$task_id" 1` で snapshot を退避し
  `git rev-parse HEAD` で sha_before を記録
  (3) round=2 reject ブランチ `1)` の冒頭、Debugger Gate `if [ "${DEBUGGER_ENABLED:-false}"
  = "true" ] && ! detect_debugger_already_invoked "$task_id" ];` の **直前**
  （行 4341 周辺）に fail-fast 判定ブロックを挿入。`pt_check_fail_fast` rc=0
  なら `pt_mark_fail_fast_failed` + `return 1`、rc!=0 なら既存 Debugger Gate
  / per-task-reviewer-reject2 経路にそのまま進む（Req 3.4 安全側）
- 重要な判断:
  - **stdout 解析を `sed -n 's/.*category=\([^ ]*\).*/\1/p'` で実施**:
    `pt_check_fail_fast` の成立時 stdout 1 行は `task=<id> fail-fast match
    category=<cat> target=<tgt> test-diff-empty range=<a>..<b>` で、
    `category=` と `target=` の値部分を 1 関数の sed で抽出する形にした。
    `awk` で field 解析する案も検討したが、出力が空文字 / 部分一致のときの
    fallback を「変数空 → `${_pt_ff_cat:-unknown}`」で処理できる sed 方式の
    方が簡潔だった（grep 可能 1 行という Physical Data Model 設計とも整合）。
  - **`2>&1` で stderr 取り込み**: `pt_check_fail_fast` 自身は通常 stderr に
    出力しないが、内部の awk / git diff 等で予期せぬ警告が stderr に出る
    可能性を考慮して `2>&1` で stdout に統合し、LOG に確実に転記する。
    stderr が漏れて `$_pt_ff_out` が空になり category/target 抽出が空にな
    る事故を防ぐ。
  - **`git rev-parse HEAD` の `|| echo ""` fallback**: REPO_DIR の git 操作が
    一時的に失敗した場合（直前 commit 競合 / lock 残骸等）でも空文字に倒
    し、後段 `pt_check_fail_fast` 内で `git diff --name-only "..".."" `
    が失敗 → `git-diff-failed` reason で return 1 → 既存 Debugger Gate 経路
    に進む構造で安全側に倒す（NFR 1.3）。直接 `|| return 1` で停止する案
    もあるが、fail-fast 判定の失敗で `claude-failed` を発火させない設計と
    整合させた。
  - **LOG 転記行のフォーマット**: 既存の `pt_log` 関数ではなく
    `printf '[%s] [%s] per-task: %s\n' "$(date '+%F %T')" "$REPO" "..."` で
    既存 watcher の LOG プレフィックス（タイムスタンプ + repo 名）と統一。
    `pt_log` は `pt:` プレフィックスを付ける別形式のため、grep 可能 1 行を
    既存 LOG エントリと同列に並べたい本ケースでは直接 printf を選択した。
  - **fail-fast 判定ブロックの配置順序**: round=2 reject ブランチ `1)` の **冒頭**
    に置くことで、Debugger Gate の有無や sentinel 状態に関わらず必ず先に
    fail-fast を評価する。`DEBUGGER_ENABLED=false` でも fail-fast が動く
    （Req 3.4 の「fail-fast 不成立 → 既存経路」と整合）構造を保証する。
- 手動スモーク確認（コード読みベース）:
  1. **round=1 approve**: round=1 reject ブランチ `1)` に入らないため、
     snapshot / sha_before / fail-fast 判定はすべて no-op（既存挙動と完全等価
     / NFR 1.1 / 1.2）
  2. **DEBUGGER_ENABLED=true / round=1 reject + round=2 reject + fail-fast 成立**:
     snapshot 取得 → round=2 redo 実行 → round=2 reject → fail-fast rc=0 →
     `per-task-implementer-fail-fast-loop` ラベル化 → return 1。Debugger Gate
     には進まない（Req 3.2 / 3.3）
  3. **DEBUGGER_ENABLED=true / round=1 reject + round=2 reject + fail-fast 不成立**:
     fail-fast rc!=0 で if ブロック skip → 既存の
     `if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked
     "$task_id" ];` 経路に進み Debugger Gate 起動 → round=3 redo（Req 3.4）
  4. **DEBUGGER_ENABLED=false / round=1 reject + round=2 reject + fail-fast 不成立**:
     fail-fast rc!=0 で if ブロック skip → 既存 `else` ブランチ（行 4434-4456）
     の `per-task-reviewer-reject2` 経路に進む（Req 3.4 / 既存挙動温存）
  5. **`shellcheck local-watcher/bin/issue-watcher.sh`** で警告ゼロを確認
  6. **`bash -n local-watcher/bin/issue-watcher.sh`** syntax OK を確認
  7. **既存スモーク `pt_extract_findings_block_test.sh` / `pt_extract_debugger_section_test.sh`
     / `pt_check_fail_fast_test.sh`** 全 PASS（task 1-5 の helper 関数は本 task
     で改変されていないため当然 PASS だが、回帰確認として実行）
- 残存課題:
  - task 7（developer.md に Finding Closure Matrix 規約節を追加）と task 8
    （impl-notes.md 整備 + 既存挙動温存の手動スモーク）が残っている。本 task 6
    で fail-fast 経路自体は完成しており、turn 予算消費を抑える機能としての
    最低限の構造は揃った。残 task 7/8 は規約反映 + 検証で、watcher 経路は
    無改変の予定。
  - 本 task で fail-fast 経路は Debugger Gate の **前** に配置したため、
    Debugger Gate 経路後の round=3 reject に対する再 fail-fast 評価は未実装
    （tasks.md task 8 残存課題に挙げられている / 次 spec で扱う候補）。
  - per-task ループの round=2 reject 後の 1 回しか fail-fast を評価しない
    構造のため、round=1 → round=3 で同じ Finding が連続することを直接捕捉
    する経路はない（Debugger Gate 経路が間に挟まる分、round=3 reject 自体
    は既存 `per-task-reviewer-reject3` 経路で停止する）。

## 確認事項

なし。
