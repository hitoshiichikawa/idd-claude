# Implementation Plan

- [x] 1. `tc_*` Config 追加とロガー実装
  - `local-watcher/bin/issue-watcher.sh` の Config ブロック（`STAGE_A_VERIFY_*` 群の近傍、行 269 付近）に
    新規 env var 4 件を追加: `TC_ENABLED="${TC_ENABLED:-true}"` / `TC_WARN_LOWER="${TC_WARN_LOWER:-8}"` /
    `TC_WARN_UPPER="${TC_WARN_UPPER:-10}"` / `TC_ESCALATE_LOWER="${TC_ESCALATE_LOWER:-11}"`
  - 既存 `sav_log` / `sc_log` の慣習に合わせて `tc_log` / `tc_warn` / `tc_error` を実装し、
    出力フォーマットを `[<timestamp>] [<REPO>] tasks-count: $*` 形式で固定する
  - shellcheck 警告ゼロを維持（`shellcheck local-watcher/bin/issue-watcher.sh`）
  - _Requirements: 1.6, 3.3, 4.2, NFR 1.1, NFR 2.1_
  - _Boundary: tc_log, tc_warn, tc_error_

- [x] 2. `tc_count_tasks` と `tc_classify` の純粋関数実装
- [x] 2.1 `tc_count_tasks` 実装 (P)
  - `grep -cE '^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? '` で件数を抽出する関数を実装
  - tasks.md パスを引数で受け取り、存在しなければ return 1、存在すれば stdout に件数（整数 1 行）
  - 4 種 checkbox（未完了 `- [ ]` / 完了 `- [x]` / deferrable `- [ ]*` / 完了 deferrable `- [x]*`）+
    親子フラット展開 + `(P)` マーカー無視（同列カウント）を構造的に保証
  - _Requirements: 1.1, 1.2, 1.3, 1.4, NFR 3.1_
  - _Boundary: tc_count_tasks_
- [x] 2.2 `tc_classify` 実装 (P)
  - 引数の整数を `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` と比較して
    `normal` / `warn` / `escalate` の 3 値のいずれかを stdout に出力
  - 閾値 env var が非整数の場合は `tc_warn` で警告ログを出し、既定値（8 / 10 / 11）にフォールバック
  - _Requirements: 2.1, 2.2, 2.3_
  - _Boundary: tc_classify_

- [x] 3. `tc_should_run` gate と冪等マーカー検知の実装
- [x] 3.1 `tc_should_run` 実装
  - 環境変数 `NUMBER` / `REPO` / `REPO_DIR` / `SPEC_DIR_REL` / `TC_ENABLED` を参照
  - TC_ENABLED ≠ true / tasks.md 不在 / Issue に既存 `needs-decisions` ラベルあり、のいずれかで
    return 1 し、`tc_log` で `reason=<opt-out|tasks-md-missing|already-needs-decisions>` を記録
  - resume 経路の skip は hook 配置（design 分岐内部のみ）で構造的に保証されることを冒頭コメントに明記
  - _Requirements: 1.5, 2.6, 3.3, 4.2, 4.4_
  - _Boundary: tc_should_run_
- [x] 3.2 `tc_already_posted_marker_present` 実装
  - `gh issue view <number> --json comments --jq '.comments[].body'` で全コメントを取得
  - 固定マーカー `<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> issue=<N> ... -->`
    を kind 別に grep し、検出時に return 0 / 未検出で return 1
  - gh API 失敗時は marker absent として扱う（最悪重複コメント投稿のみ）
  - _Requirements: 2.6_
  - _Boundary: tc_already_posted_marker_present_

- [x] 4. コメント投稿・ラベル付与関数の実装
- [x] 4.1 `tc_post_warning_comment` 実装 (P)
  - 8〜10 件レンジ用警告コメントを冪等投稿（事前に `tc_already_posted_marker_present` で重複検知）
  - コメント本文に件数・適用閾値・後続フェーズ通常進行の旨を含め、末尾に冪等マーカー
    `<!-- idd-claude:tasks-count-overflow kind=warning issue=<N> count=<C> -->` を必ず付与
  - 投稿失敗時は `tc_warn` を出すが戻り値 0 を返す（fail-open）
  - _Requirements: 2.2, 2.6, NFR 1.2_
  - _Boundary: tc_post_warning_comment_
- [x] 4.2 `tc_post_escalation_comment` 実装 (P)
  - 11 件以上用エスカレーションコメントを冪等投稿
  - 本文に件数・適用閾値・抑止された後続フェーズ名（Developer 自動起動 / impl-resume）・
    人間が取りうる回復手順（Issue 分割 / `needs-decisions` 外し / `TC_ENABLED=false` opt-out）を含め、
    末尾に冪等マーカー `<!-- idd-claude:tasks-count-overflow kind=escalation issue=<N> count=<C> -->`
    （NFR 1.2 識別文字列兼用）を必ず付与
  - _Requirements: 2.3, 2.5, 2.6, NFR 1.2_
  - _Boundary: tc_post_escalation_comment_
- [x] 4.3 `tc_add_needs_decisions_label` 実装 (P)
  - `gh issue edit <number> --add-label "$LABEL_NEEDS_DECISIONS"` で冪等に付与
  - 失敗時は `tc_warn` を出すが戻り値 0（fail-open）
  - 既存 `LABEL_NEEDS_DECISIONS` 変数（`needs-decisions`）を参照し新ラベル名は導入しない
  - _Requirements: 2.3, 2.4, 4.4, NFR 2.2_
  - _Boundary: tc_add_needs_decisions_label_

- [x] 5. Orchestrator `tc_run_post_architect_check` と design 分岐 hook 統合
- [x] 5.1 `tc_run_post_architect_check` 実装
  - 順序: `tc_should_run` → `tc_count_tasks` → `tc_classify` → range 分岐
  - range=normal はログのみ / range=warn は `tc_post_warning_comment` /
    range=escalate は `tc_post_escalation_comment` + `tc_add_needs_decisions_label`
  - 戻り値は常に 0（fail-open）、ログ行は `tc_log "count=$count range=<R> action=<A>"` 形式
  - _Requirements: 1.1, 1.6, 2.1, 2.2, 2.3, 3.3, 4.1_
  - _Boundary: tc_run_post_architect_check_
  - _Depends: 3.1, 4.1, 4.2, 4.3_
- [x] 5.2 `_slot_run_issue` design 分岐 rc=0 case への hook 差し込み
  - `local-watcher/bin/issue-watcher.sh` 行 10086–10091 相当の rc=0 case で、`slot_log "$MODE 完了"` と
    `rm -f "$_qa_reset_file_design"` の間に `tc_run_post_architect_check || true` を 1 行追加
  - rc=99 / non-zero ブランチおよび impl / impl-resume 分岐には差し込まない（Req 3.1 / 3.2 を構造的に保証）
  - 既存 design 分岐の他の挙動（return 0 / quota 処理 / claude-failed 遷移）を変更しないことを
    diff で確認
  - _Requirements: 1.1, 3.1, 3.2_
  - _Boundary: _slot_run_issue (design branch)_
  - _Depends: 5.1_

- [x] 6. 回帰テスト fixture と driver の追加
- [x] 6.1 fixture ファイル群の作成
  - `tests/local-watcher/tasks-count/fixtures/tasks-7.md`（normal レンジ最大、7 件）
  - `tests/local-watcher/tasks-count/fixtures/tasks-8.md`（warn レンジ最小、8 件）
  - `tests/local-watcher/tasks-count/fixtures/tasks-10.md`（warn レンジ最大、10 件）
  - `tests/local-watcher/tasks-count/fixtures/tasks-11.md`（escalate レンジ最小、11 件）
  - `tests/local-watcher/tasks-count/fixtures/tasks-mixed-checkbox.md`（4 種 checkbox + 子タスク +
    `(P)` 混在、混在件数は driver の期待値と整合）
  - `tests/local-watcher/tasks-count/fixtures/tasks-empty.md`（0 件、normal 扱い）
  - _Requirements: 1.2, 1.3, 1.4_
- [x] 6.2 `tests/local-watcher/tasks-count/extract-driver.sh` の実装
  - 既存 `tests/local-watcher/stage-a-verify/extract-driver.sh` と同形式で
    `tc_count_tasks` / `tc_classify` を `issue-watcher.sh` から awk 抽出して source する
  - 期待値テーブルに（fixture 名, expected_count, expected_classification）を持ち、
    全 fixture に対して走らせ、不一致時は exit 1
  - shellcheck 警告ゼロを維持
  - _Requirements: 1.2, 1.3, 1.4, 2.1, 2.2, 2.3_
  - _Depends: 2.1, 2.2, 6.1_

- [ ] 7. ドキュメント整備（README Migration Note）
  - `README.md` のオプション機能一覧近傍（行 1057 付近）に本機能を 1 項目追記
  - Migration Note 形式で「既定で有効 / 7 件以下では挙動変化なし / `TC_ENABLED=false` で opt-out
    可 / 既存 env var とラベル契約は不変」を明記
  - `CLAUDE.md` は既存内容で十分（破壊的変更ではないため新規追記不要）
  - _Requirements: 4.2, 4.3_

- [ ]* 8. パフォーマンス計測テスト追加
  - 1 MB の tasks.md fixture を生成し、`tc_count_tasks` の wall clock を `time` で計測
  - 1 秒以内に完了することを driver で assert（CI 化はしない、ローカル実行で十分）
  - _Requirements: NFR 3.1_
