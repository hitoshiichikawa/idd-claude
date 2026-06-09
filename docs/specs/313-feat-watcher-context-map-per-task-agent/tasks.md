# Implementation Plan

per-task Reviewer ループ運用（`PER_TASK_LOOP_ENABLED=true`）を前提に、各 task は独立コミット
単位で完了可能な粒度に分割しています。fixture ベースの behavioral regression test は dedicated
test task（Task 5）に集約しており、先行 task は `_Requirements_partial:_` で対応 AC のテスト
追加を Task 5 に deferred している旨を明示しています。Task 5 はこの partial 解消を担う
dedicated regression test task として位置付けます。

- [x] 1. `modules/context-map.sh` を新規追加し、`cm_enabled` / 内部 resolver / `cm_compose` /
       `cm_generate` / `cm_render_prompt_section` の関数定義を実装する
  - `local-watcher/bin/modules/context-map.sh` を新規作成し、冒頭コメントで用途 / 配置先 /
    依存 / セットアップ参照先を明示する（既存 `modules/stage-a-verify.sh` 等と同形式）
  - `set -euo pipefail` は本体側で宣言済みのため本モジュールでは宣言せず関数定義のみを持つ
  - `cm_log` / `cm_warn` / `cm_error` ロガーを `[YYYY-MM-DD HH:MM:SS] [$REPO] context-map:`
    形式で実装する（既存 logger 規約と整合）
  - `cm_enabled` は `CONTEXT_MAP_ENABLED` と `PER_TASK_LOOP_ENABLED` の両方が **lowercase の
    `true` 厳密一致** のときに rc=0、それ以外は rc=1 を返す
  - `cm_resolve_boundary` / `cm_resolve_candidate_files` / `cm_resolve_candidate_tests` /
    `cm_resolve_candidate_docs` / `cm_compose` / `cm_truncate_if_oversize` / `cm_generate` /
    `cm_render_prompt_section` を design.md「Components and Interfaces」節のシグネチャ通りに
    実装する
  - 上限値は 200 行 / 8 KB（NFR 4.1 の確定値）として `cm_truncate_if_oversize` 内に定数化
  - `cm_generate` 内のすべての失敗候補は `|| true` で短絡し、warn ログを残しつつ rc=0 で抜ける
    （NFR 2.3 / 「per-task ループを止めない」）
  - インライン smoke 確認として、bash で `source modules/context-map.sh` を実行し
    `cm_enabled` の戻り値が `CONTEXT_MAP_ENABLED` の値で変わることを 2〜3 ケース手動確認する
    （fixture ベースの behavioral regression は Task 5 で集約）
  - `shellcheck local-watcher/bin/modules/context-map.sh` 警告ゼロを確認する
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 2.9, 2.10, 3.5, NFR 2.1, NFR 2.2, NFR 2.3, NFR 3.1, NFR 3.2, NFR 4.1_
  - _Requirements_partial: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.9, 2.10, NFR 2.1, NFR 2.3_
  - _Boundary: context-map.sh_

- [x] 2. `local-watcher/bin/issue-watcher.sh` 本体に Config / `REQUIRED_MODULES` / call site の
       追記を行う
  - Config ブロック（行 460 付近、`PER_TASK_LOOP_ENABLED` 宣言の近傍）に
    `CONTEXT_MAP_ENABLED="${CONTEXT_MAP_ENABLED:-false}"` を追加し、コメントで「`=true`
    厳密一致 + `PER_TASK_LOOP_ENABLED=true` 同時必須」「未設定では差分等価」「設計参照先」を明記
  - 行 685 の `REQUIRED_MODULES` 配列末尾に `"context-map.sh"` を追加
  - `run_per_task_loop` 内の `while IFS= read -r task_id; do ... done` ループ冒頭（行 4163 付近、
    `[ -n "$task_id" ] || continue` の直後）で `cm_enabled` 通過時に `cm_generate "$task_id"`
    を呼ぶ。失敗は `cm_warn` で吸収し、per-task ループは継続させる
  - `build_per_task_implementer_prompt` の関数冒頭で `context_map_block_section=""` を初期化し、
    `cm_enabled` 通過時に `cm_render_prompt_section "$task_id"` の結果を代入。heredoc 末尾の
    `${findings_block_section}${debugger_block_section}${closure_matrix_section}` に続けて
    `${context_map_block_section}` を embed
  - `build_per_task_reviewer_prompt` の heredoc 末尾にも同様の `${context_map_block_section}`
    を embed
  - 既存 `dry run` パス（`REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を
    対象なし状態で実行）で `処理対象の Issue なし` が正常終了することを 1 回手動確認する
    （behavioral regression は Task 5 で集約）
  - `shellcheck local-watcher/bin/issue-watcher.sh` 警告ゼロを確認する
  - _Requirements: 1.1, 1.4, 2.1, 3.1, 3.2, 3.5, NFR 1.1, NFR 1.2, NFR 1.4, NFR 3.1, NFR 3.2_
  - _Requirements_partial: 2.1, 3.1, 3.2_
  - _Boundary: issue-watcher.sh_
  - _Depends: 1_

- [x] 3. `.claude/agents/developer.md` と `repo-template/.claude/agents/developer.md` の両系統に
       context map 参照ルールを byte 一致で追記する
  - root の `.claude/agents/developer.md` の「実装ルール」節
    `変更前に grep / glob で既存実装・影響範囲を必ず把握する` の直後に、design.md
    「Agent 仕様改訂」節で示した追記ブロックを挿入する
  - `repo-template/.claude/agents/developer.md` の同位置に **byte 一致**で同じ内容を反映する
  - `diff .claude/agents/developer.md repo-template/.claude/agents/developer.md` が空であることを
    確認する
  - _Requirements: 3.3, 4.1, 4.3_
  - _Boundary: developer.md_

- [x] 4. `.claude/agents/reviewer.md` と `repo-template/.claude/agents/reviewer.md` の両系統に
       context map 参照ルールを byte 一致で追記する
  - root の `.claude/agents/reviewer.md` の「必ず先に読むルール」節の必読ファイル一覧の末尾に、
    design.md「Agent 仕様改訂」節で示した追記項目（`docs/specs/<番号>-<slug>/context-map.md` を
    `CONTEXT_MAP_ENABLED=true` 環境下で auto-generated 一次情報として参照する旨）を追加する
  - `repo-template/.claude/agents/reviewer.md` の同位置に byte 一致で同じ内容を反映する
  - `diff .claude/agents/reviewer.md repo-template/.claude/agents/reviewer.md` が空であることを
    確認する
  - _Requirements: 3.4, 4.2, 4.3_
  - _Boundary: reviewer.md_

- [ ] 5. `docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/` 配下に
       fixture とスモークスクリプトを追加する（Task 1 / Task 2 で deferred された behavioral
       regression test を集約する dedicated regression test task）
  - 本 task は Task 1 の `_Requirements_partial: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.9, 2.10,
    NFR 2.1, NFR 2.3_` と Task 2 の `_Requirements_partial: 2.1, 3.1, 3.2_` に列挙された AC を
    fixture-based test で解消する
  - `tasks-sample.md` に `- [ ] 1. ...` / `_Requirements:_` / `_Boundary:_` を含む擬似 tasks.md を
    配置する
  - `design-sample.md` に File Structure Plan セクション（fenced code block 形式）を含む擬似
    design.md を配置する
  - `test-cm-generate.sh`: `CONTEXT_MAP_ENABLED=true PER_TASK_LOOP_ENABLED=true` 環境で
    `cm_generate` を呼び、生成された context-map.md が `## Task` / `## Boundary` /
    `## Candidate files` / `## Candidate tests` / `## Candidate docs` / `## Search constraints` の
    各セクションを含むことを `grep` で確認（Req 2.2〜2.7 のカバレッジ）。`_Boundary:_` 不在で
    「解決不能」明示が出力されることも 1 ケース確認（Req 2.9）。200 行 / 8 KB 上限超過時の
    truncate marker が末尾に追記されることを擬似巨大入力で確認（Req 2.10, NFR 4.1）。
    同一入力 2 回呼出で output が byte 一致することを確認（NFR 2.1）。生成失敗を仕込んでも
    rc=0 で抜けることを確認（NFR 2.3）
  - `test-cm-disabled.sh`: `CONTEXT_MAP_ENABLED` 未設定 / `=false` / `=True` / `=1` / `=yes` の
    各値で `cm_enabled` が rc=1 を返し、`cm_generate` 経路を通っても context-map.md が
    生成されないことを確認（Req 6.3, 1.2, 1.3）。`PER_TASK_LOOP_ENABLED` 未設定でも
    `cm_enabled` rc=1 となることを確認（Req 1.4）
  - `test-cm-inject.sh`: `build_per_task_implementer_prompt` / `build_per_task_reviewer_prompt` を
    `issue-watcher.sh` から source して呼び出し、flag on/off で stdout を diff し、on のときのみ
    `## Context Map` 見出しが含まれることを `grep` で確認（Req 6.2, 3.1, 3.2）。off では既存
    prompt と byte 一致であることを確認（Req 3.5, NFR 1.1）
  - 各テストは `bash` で実行可能で、exit code 0 = pass、非 0 = fail とする
  - `shellcheck docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/*.sh` 警告ゼロ
    を確認する
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.9, 2.10, 3.1, 3.2, 3.5, 6.1, 6.2, 6.3, NFR 1.1, NFR 2.1, NFR 2.3, NFR 3.1, NFR 4.1_
  - _Boundary: test-fixtures/_
  - _Depends: 1, 2_

- [ ] 6. `README.md` の「オプション機能一覧」節（または同等の節）に `CONTEXT_MAP_ENABLED` の
       説明を追記する
  - `CONTEXT_MAP_ENABLED` env var の意味と既定値（未設定＝無効）を記載する
  - 動作前提として `PER_TASK_LOOP_ENABLED=true` 環境のみで動作する旨を明記する
  - 生成パス `docs/specs/<番号>-<slug>/context-map.md` と生成タイミング（per-task 起動直前）を
    記載する
  - スコープ外項目（reasoning effort 変更 / 並列度変更 / LLM scout / repo-wide index）を明示する
  - 上限値（200 行 / 8 KB）と運用後に観測データで見直す予定である旨を補足する
  - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - _Boundary: README.md_

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。
`shellcheck` 警告ゼロ（NFR 3.1）と `.claude/agents` 両系統の byte 一致（Req 4.3）、および
fixture スモークスクリプト（Req 6.1〜6.3）を機械的に確認する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh && diff -r .claude/agents repo-template/.claude/agents && diff -r .claude/rules repo-template/.claude/rules && bash docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-generate.sh && bash docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-disabled.sh && bash docs/specs/313-feat-watcher-context-map-per-task-agent/test-fixtures/test-cm-inject.sh
```
