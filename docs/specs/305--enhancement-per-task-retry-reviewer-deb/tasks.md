# Implementation Plan

- [x] 1. `pt_extract_findings_block` ヘルパー実装 + 単体テスト fixture 整備
  - `local-watcher/bin/issue-watcher.sh` の per-task ブロック末尾（既存 `pt_extract_learnings`
    関数の近傍 / 行 2606 付近）に `pt_extract_findings_block <review_notes_path>` を追加
  - awk で `^## Findings[[:space:]]*$` 〜 次の `^## ` 直前まで抽出。`pt_extract_learnings` の
    awk pattern を踏襲する
  - 戻り値: 0 = 抽出成功（stdout に Findings セクション本文） / 1 = ファイル不在 or `## Findings`
    見出し不在
  - `local-watcher/test/fixtures/pt_extract_findings_block/` 配下に 3 fixture を新規作成:
    - `normal-2-findings.md`（Finding 1 + Finding 2 + Summary + RESULT を含む完全な review-notes.md 模式）
    - `no-findings-section.md`（`## Findings` セクション自体が無いケース）
    - `findings-with-nested-headers.md`（Finding 配下に `**Target**:` 等の bold 行 + 補足箇条書きを含む）
  - 新規スモークスクリプト `local-watcher/test/pt_extract_findings_block_test.sh`:
    - 既存 `pi_max_rounds_kind_test.sh` の awk による関数抽出 + eval 読み込みパターンを踏襲
    - 3 fixture × 期待出力で assert
  - _Requirements: 1.1, 1.3, 1.5, 5.1, 5.5, NFR 4.1_
  - _Boundary: issue-watcher.sh (pt_* namespace), local-watcher/test/_

- [x] 2. `pt_extract_debugger_section` ヘルパー実装 + 単体テスト fixture 整備
  - 同 namespace に `pt_extract_debugger_section <debugger_notes_path> <task_id>` を追加
  - awk で `^## Task <escaped_task_id>$` 行頭マッチから次の `^## ` 直前まで抽出
  - task_id の `.` は awk の正規表現メタを避けるため shell 側で `[.]` にエスケープしてから awk に渡す
  - 戻り値: 0 = 抽出成功 / 1 = ファイル不在 or 当該 `## Task <id>` 見出し不在
  - `local-watcher/test/fixtures/pt_extract_debugger_section/` 配下に 3 fixture:
    - `task-1-2-present.md`（`## Task 1.2` セクションが存在し配下に Fix Plan h3 群を持つ）
    - `task-1-2-absent.md`（`## Task 2.1` のみで `## Task 1.2` 不在）
    - `multi-task-sections.md`（`## Task 1.1` と `## Task 1.2` が並ぶ。1.2 を抽出して 1.1 が混入しない）
  - 新規スモークスクリプト `local-watcher/test/pt_extract_debugger_section_test.sh`
  - _Requirements: 1.2, 1.5, 5.2, NFR 4.2_
  - _Boundary: issue-watcher.sh (pt_* namespace), local-watcher/test/_
  - _Depends: 1_

- [x] 3. `build_per_task_implementer_prompt` の signature 拡張 + 注入ブロック実装
  - 既存関数 `build_per_task_implementer_prompt` の signature を
    `build_per_task_implementer_prompt <task_id> [<redo_mode>]` に拡張（既定 `redo_mode=initial`）
  - 関数冒頭で `redo_mode` を local に取り、`case "$redo_mode" in initial|after-round1|after-debugger) ;;
    *) redo_mode=initial ;; esac` で安全側 fallback
  - `redo_mode != initial` の場合のみ:
    - `findings_block=$(pt_extract_findings_block "$REPO_DIR/$SPEC_DIR_REL/review-notes.md")` を取得
    - 抽出成功時は heredoc 内に `## 直前 round の Reviewer Findings\n\n${findings_block}` 相当の
      ブロックを追加。抽出失敗時は「(review-notes.md が見つかりません / 抽出失敗のため Findings の
      inline 注入を諦めました)」1 行 + `pt_log "task=... inject=skipped reason=..."` を残す（Req 1.5）
  - `redo_mode = after-debugger` の場合のみ追加で:
    - `debugger_block=$(pt_extract_debugger_section "$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md" "$task_id")`
    - 抽出成功時は heredoc 内に `## Debugger の Fix Plan（debugger-notes.md より）` ブロックを追加
    - 抽出失敗時は 1 行明示 + `pt_log`
  - `redo_mode != initial` の場合のみ heredoc 末尾近くに「## Finding Closure Matrix の記録義務」節を
    追加し、developer.md の規約節を参照する 1〜2 段落を埋める（Req 2.1, 2.5）。
    `redo_mode = after-debugger` の場合のみ 5 列目「Fix Plan Step」追記指示を含める
  - 注入実施時に `pt_log "task=$task_id redo_mode=$redo_mode inject=<files> round=<N>"` 相当を 1 行出力（NFR 3.1）
  - 既存制約節（PR 作成禁止 / spec 書き換え禁止 / `### Task <id>` 追記規約 / 進捗マーカー規約 /
    既存 commit 温存）は **全て温存**（Req 4.3）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 4.3, NFR 1.1, NFR 3.1, NFR 4.1, NFR 4.2_
  - _Boundary: issue-watcher.sh (build_per_task_implementer_prompt)_
  - _Depends: 1, 2_

- [x] 4. `run_per_task_implementer_redo` wrapper + `run_per_task_loop` 呼び出し点改修
  - 既存 `run_per_task_implementer <task_id>` は **無改変**（NFR 1.1 を構造保証）
  - 新規 wrapper `run_per_task_implementer_redo <task_id> <redo_mode>` を追加。内部処理は
    `run_per_task_implementer` をほぼコピーし、`build_per_task_implementer_prompt "$task_id"
    "$redo_mode"` を呼ぶ点と stage_label を `PerTask-Impl-Redo-${task_id}-${redo_mode}` にする点のみ差分
  - `run_per_task_loop` の round=2 redo 呼び出し（既存行 3717 `run_per_task_implementer "$task_id"`）を
    `run_per_task_implementer_redo "$task_id" "after-round1"` に置換
  - `run_per_task_loop` の BLOCKED 経路 Implementer 再起動（既存行 3665）は **無改変**（BLOCKED 経路は
    `redo_mode=initial` 相当で扱う。BLOCKED 経路は Reviewer reject ではないため Findings 注入対象外）
  - `run_per_task_loop` の Debugger 経由 round=3 redo 呼び出し（既存行 3776 `run_per_task_implementer
    "$task_id"`）を `run_per_task_implementer_redo "$task_id" "after-debugger"` に置換
  - `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを維持
  - _Requirements: 1.1, 1.2, 4.3, NFR 1.1, NFR 1.2_
  - _Boundary: issue-watcher.sh (run_per_task_loop, run_per_task_implementer_redo)_
  - _Depends: 3_

- [ ] 5. `pt_snapshot_review_notes` + `pt_check_fail_fast` + `pt_mark_fail_fast_failed` 実装 + 単体テスト
  - `pt_snapshot_review_notes <task_id> <round>` を追加:
    - 退避先 path `/tmp/idd-claude-${REPO_SLUG}-${NUMBER}-pt-snapshot-${task_id}-round${round}-${ts}.md`
      を組み立て、`cp` で退避。元ファイル不在なら退避せず stdout に空文字を返す
  - `pt_check_fail_fast <task_id> <prev_snapshot_path> <curr_review_notes_path> <sha_before> <sha_after>` を追加:
    - 両 review-notes.md から `### Finding <n>` ブロックを抽出し `(category, target)` tuple set を作る
    - 積集合が空なら return 1（不成立。stdout に `task=... fail-fast skip reason=no-shared-finding`）
    - 共有あり: `git diff --name-only "$sha_before".."$sha_after"` の出力を取得し、
      design.md「テストファイル判定基準」の 2 軸 OR でテストファイル該当を判定
    - テストファイル該当 0 件 → return 0（fail-fast 成立。stdout に grep 可能 1 行 `task=...
      fail-fast match category=<cat> target=<tgt> test-diff-empty range=<sha_before>..<sha_after>`）
    - テストファイル該当 1 件以上 → return 1（不成立。stdout に `task=... fail-fast skip
      reason=test-diff-present`）
  - `pt_mark_fail_fast_failed <task_id> <category> <target>` を追加:
    - `mark_issue_failed "per-task-implementer-fail-fast-loop" "<extra_body>"` 経由で `claude-failed` 化
    - extra_body には Req 3.3 / NFR 3.2 の項目（検出条件 / 対象 task ID / 連続 reject 対象 Finding /
      参照ファイルパス / 次の手順）を含める
  - `local-watcher/test/fixtures/pt_check_fail_fast/` 配下に fixture（2 つの review-notes.md ペア +
    期待される `git diff --name-only` 出力を模した tsv）を作成:
    - `same-category-same-target-no-test-diff/`（fail-fast 成立: 共有あり + テスト差分なし）
    - `same-category-different-target/`（不成立: 共有なし）
    - `different-category-with-test-diff/`（不成立: 共有なし + テスト差分あり）
  - 新規スモーク `local-watcher/test/pt_check_fail_fast_test.sh`:
    - `git diff --name-only` をスタブ化して 3 ケースで `pt_check_fail_fast` の return / stdout を assert
    - スタブは fake function `git()` を当該関数評価 scope に注入する形式（既存
      `stage_a_verify_round1_defer_test.sh` の gh fake 注入と同方針）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 5.3, NFR 1.3, NFR 3.2_
  - _Boundary: issue-watcher.sh (pt_* namespace), local-watcher/test/_
  - _Depends: 1_

- [ ] 6. `run_per_task_loop` の round=2 reject 直後に fail-fast 経路を組み込む
  - `run_per_task_loop` の round=2 redo の **直前** に
    `prev_snapshot=$(pt_snapshot_review_notes "$task_id" 1)` を呼び snapshot 取得
  - round=2 redo Implementer 起動 **直前**の HEAD SHA を `sha_before=$(git -C "$REPO_DIR" rev-parse HEAD)`
    で記録
  - round=2 Reviewer が reject を返した直後（既存行 3753 周辺、Debugger Gate 判定の **前**）に:
    - `sha_after=$(git -C "$REPO_DIR" rev-parse HEAD)` を取得
    - `if pt_check_fail_fast "$task_id" "$prev_snapshot" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md"
      "$sha_before" "$sha_after" >> "$LOG"; then` で fail-fast 判定
    - 成立時:
      - 共有 Finding の category / target を `pt_check_fail_fast` の stdout から再抽出（または
        `pt_check_fail_fast` の補助 stdout を `read` で受ける）
      - `pt_mark_fail_fast_failed "$task_id" "$cat" "$tgt"` を呼んで `claude-failed` 化
      - `return 1`
    - 不成立時:
      - 既存 Debugger Gate 経路（`DEBUGGER_ENABLED=true` 判定以降）にそのまま進む（Req 3.4）
  - snapshot ファイルは `/tmp` 配下 + REPO_SLUG / NUMBER / task_id / round / ts で隔離されるため、
    後続 sycle で残骸が残っても害はない（OS の `/tmp` cleanup に委ねる。明示的削除は task 完了時の
    冒頭で `rm -f /tmp/idd-claude-${REPO_SLUG}-${NUMBER}-pt-snapshot-${task_id}-*` を入れる）
  - `shellcheck` 警告ゼロ
  - _Requirements: 3.1, 3.2, 3.3, 3.4, NFR 1.3_
  - _Boundary: issue-watcher.sh (run_per_task_loop)_
  - _Depends: 5_

- [ ] 7. `developer.md` に「Finding Closure Matrix の記録義務」節を追加 + repo-template に byte 一致同期
  - `.claude/agents/developer.md` の既存「per-task ループ下での Implementer の責務」節 → 「learning
    追記の責務」節の **直後**に新規 h2 節「per-task retry 時の Finding Closure Matrix 記録義務」を追加
  - 節本文には以下を含める（design.md「Developer 規約ドメイン」節と整合）:
    - 適用範囲: prompt 本文に「## 直前 round の Reviewer Findings」ブロックが含まれる redo 経路のみ
      （初回起動 / `PER_TASK_LOOP_ENABLED=false` では適用しない）
    - Matrix 構造の規約テンプレ（4 列: Finding / Target / Fix Commit / Added/Updated Test / Verification）
    - 「未対応」「対応不可（理由）」「次 round へ持ち越し」の enum 値を Fix Commit 列で明示する規約（Req 2.3）
    - 先行 task / 先行 round の Matrix 改変・削除・並び替えの **禁止** 規約（Req 2.4）
    - Debugger Gate 経由 round=3 でのみ 5 列目「Fix Plan Step」を追記する規約（Req 2.5）
    - 配置: 既存 `### Task <id>` h3 セクション末尾に Matrix を追記（既存 learning 追記規約と並列）
  - 同一文字列を `repo-template/.claude/agents/developer.md` に **byte 一致**で同期（NFR 2.1, Req 4.4）
  - `diff -r .claude/agents repo-template/.claude/agents` 出力が空であることを確認
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 4.1, 4.4, NFR 2.1_
  - _Boundary: .claude/agents/developer.md, repo-template/.claude/agents/developer.md_

- [ ] 8. impl-notes.md 整備 + 既存挙動温存の手動スモーク確認
  - `docs/specs/305--enhancement-per-task-retry-reviewer-deb/impl-notes.md` に以下を記録:
    - 採用方針（注入ブロック構造 / fail-fast 判定基準）
    - 既存 `build_per_task_implementer_prompt` の 1 引数呼び出し後方互換性の検証結果
      （`build_per_task_implementer_prompt 1.2` と `build_per_task_implementer_prompt 1.2 initial` の
      stdout diff 0 行を手動で確認）
    - `PER_TASK_LOOP_ENABLED=false` 経路の prompt diff 0 行
    - 残存課題（Debugger Gate 経路で Reviewer round=2 reject snapshot を fail-fast 判定に流用するか否か /
      現状は Debugger Gate 前で fail-fast 判定するため、Debugger 経路後の round=3 reject を再 fail-fast
      評価する経路は未実装。次 spec で扱う候補）
  - `bash local-watcher/test/pt_extract_findings_block_test.sh` /
    `bash local-watcher/test/pt_extract_debugger_section_test.sh` /
    `bash local-watcher/test/pt_check_fail_fast_test.sh` を実行し全 pass を確認
  - `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh`
    で警告ゼロを確認
  - `diff -r .claude/agents repo-template/.claude/agents` および
    `diff -r .claude/rules repo-template/.claude/rules` で diff 出力が空を確認
  - _Requirements: 5.4, 5.5, NFR 1.1, NFR 1.2, NFR 2.1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules && \
  bash local-watcher/test/pt_extract_findings_block_test.sh && \
  bash local-watcher/test/pt_extract_debugger_section_test.sh && \
  bash local-watcher/test/pt_check_fail_fast_test.sh
```
