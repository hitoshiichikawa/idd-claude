# Implementation Plan

- [x] 1. logger 関数追加と env Config 拡張（前提整備）
  - `local-watcher/bin/modules/core_utils.sh` の既存 `pr_log` / `pi_log` 等と同形式で `adj_log` /
    `adj_warn` / `adj_error` を末尾追記する（時刻 + `[$REPO]` + `adjudicator:` prefix）
  - `local-watcher/bin/issue-watcher.sh` の Config ブロックに `# ─── PR Reviewer Adjudicator
    設定 (#404) ───` 節を追加し、以下 6 env を `${VAR:-default}` で解決:
    `PR_REVIEWER_ADJUDICATOR_ENABLED` / `PR_REVIEWER_ADJUDICATOR_MODEL` /
    `PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT` / `PR_REVIEWER_ADJUDICATOR_PROMPT` /
    `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` / `PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS`
  - `PR_REVIEWER_ADJUDICATOR_ENABLED` は `case` で安全側正規化（`true` 厳密以外を `false`）。
    `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` は既定 `passthrough` で `case` 正規化
    （`legitimate` / `passthrough` 以外を `passthrough` に倒す。SPOF 緩和 / Architecture
    Decision: claude-review publisher contention 参照）
  - shellcheck 警告ゼロ + 既存 env 名・既定値の変更なしを確認（diff レビュー）
  - _Requirements: 5.1, 5.3, 5.5, 4.4_
  - _Boundary: core_utils.sh, issue-watcher.sh_

- [x] 2. adjudicator-prompt.tmpl の作成と read-only 契約の明示
  - `local-watcher/bin/adjudicator-prompt.tmpl` を新規作成
  - プレースホルダ: `{PR}` / `{SHA}` / `{BASE}` / `{HEAD}` / `{REVIEW_TEXT}` / `{SPEC_DIR}` /
    `{REQUIREMENTS_MD}`（解決不能時は `(none)`）
  - 分類基準（legitimate: AC 直結 / design.md Components 直結 / 後方互換破壊 / security 退行 //
    excessive: AC 非紐付け / spec 外 / 重複 / 主観的）と「迷ったら legitimate」の保守的判定指示
  - JSON 出力契約（`decisions[]` / `summary`）を末尾で明示（design.md「Data Models」節と一致）
  - read-only 制約（Bash / Edit / Write を使わない / JSON 以外を末尾に付けない）を明記
  - install.sh は既存 `*.tmpl` glob で自動配布されるため変更不要であることを diff で確認
  - _Requirements: 1.2, 1.3, 1.4, 1.5_
  - _Boundary: adjudicator-prompt.tmpl_
  - _Depends: 1_

- [x] 3. adjudicator.sh モジュール骨格と gate / findings parse の実装＋テスト
  - `local-watcher/bin/modules/adjudicator.sh` を新規作成（先頭コメントに用途 / 配置先 / 依存
    を明記、トップレベル副作用なし、関数 prefix `adj_`）
  - 実装関数: `adj_gate_enabled` / `adj_extract_findings`
  - `adj_extract_findings` は codex 形式 `[high|medium|low] <file>:<line> — <内容>` を awk
    で parse し JSON 配列化（指摘ゼロでも `"[]"` 返却 / fail-safe）。**reconciliation check** を
    内蔵: codex 出力の `## 指摘事項` 見出し配下 bullet 行数と parse 件数を突合し、件数不一致
    検出時は戻り値 4 を返す（ae-mdm 設計レビュー #4 / 書式ドリフトによる silent 取りこぼし防止）
  - `local-watcher/bin/issue-watcher.sh` の `REQUIRED_MODULES` 配列に `"adjudicator.sh"` を
    追加（`"pr-reviewer.sh"` の隣）
  - 近接テスト追加: `local-watcher/test/adj_resolve_gate_test.sh`（`=true` 厳密 / `True` / 空 /
    typo 各ケースで安全側 OFF）、`local-watcher/test/adj_extract_findings_test.sh`（空 / 単一 /
    多重 / 不正行混在 / **reconciliation 不一致**ケースで rc=4）。`extract_function`
    イディオム踏襲
  - shellcheck 警告ゼロ + `bash -n` OK
  - _Requirements: 1.1, 5.1, 5.5_
  - _Boundary: adjudicator.sh, issue-watcher.sh_
  - _Depends: 1_

- [x] 4. classify / validate / fallback ロジックと近接テスト
  - `adjudicator.sh` に以下を追加: `adj_classify_findings`（Claude CLI 呼び出し / `--output-format
    json` / mktemp で prompt 一時ファイル）/ `adj_validate_decisions`（JSON schema 検証、不整合時
    は呼び出し元で全 legitimate に倒す sentinel を返す）
  - read-only invariant 検査（実行後 `git status --porcelain` で tracked 変更検出 → `git checkout
    -- .` で破棄、`workspace-modified` 報告）
  - claude exec 失敗 / timeout / JSON parse 失敗のいずれも fallback モード
    （`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL`）に従って復旧
  - 近接テスト追加: `local-watcher/test/adj_classify_test.sh`（stub claude で legitimate-only /
    excessive-only / mixed / JSON parse 失敗の 4 ケース、fallback モードが期待どおりに選択される
    こと）
  - _Requirements: 1.1, 1.4, 1.5_
  - _Boundary: adjudicator.sh_
  - _Depends: 2, 3_

- [x] 5. label / status publish 反映と Reviewer 先行優先 + 近接テスト
  - `adjudicator.sh` に以下を追加: `adj_apply_label_decision`（`gh pr edit --add-label` /
    `--remove-label` 冪等使用）/ `adj_read_reviewer_verdict`（head_ref から `review-notes.md` を
    `git show <head>:docs/specs/<N>-<slug>/review-notes.md` で読み、最終行 `RESULT: approve|reject`
    を抽出。不在 / RESULT 行不在は空文字列を返す / Architecture Decision: claude-review
    publisher contention の Reviewer 先行優先）/ `adj_apply_status_decision`（既存
    `pr_publish_claude_status` を流用。publish 直前に `adj_read_reviewer_verdict` を呼び、
    reject 検出時は legitimate 件数に依らず `claude-review = failure` を publish）/
    `adj_post_decision_comment`（hidden marker `kind=decision` + 重複防止判定は既存
    `pr_already_processed` 流用）
  - excessive と判定された finding ごとに hidden marker
    `<!-- idd-claude:pr-adjudicator-excessive id=<N> sha=<sha> -->` を含むコメントを投稿
    （pi 側 self-filter のキーとして使う）
  - 近接テスト追加: `local-watcher/test/adj_publish_decision_test.sh`（stub gh + stub git で
    needs-iteration add / remove + claude-review status publish の 5 ケース
    [legit ≥1 / legit ゼロ + Reviewer approve / legit ゼロ + Reviewer reject / codex 失敗 +
    Reviewer approve / claude 失敗] を検証）
  - _Requirements: 2.1, 2.2, 2.3, 3.2, 3.3, 3.4, 3.5, 4.1, 4.3, NFR 1.2_
  - _Boundary: adjudicator.sh_
  - _Depends: 4_

- [x] 6. adj_run_for_pr オーケストレーション + pr-reviewer.sh hook + catch-up suppression + no-op テスト
  - `adjudicator.sh` に `adj_run_for_pr` を追加（入力: pr_number / sha / review_text / pr_url /
    head_ref。gate OFF / review_text 空（codex 失敗）/ findings ゼロを早期処理し、
    `adj_extract_findings` → `adj_classify_findings` → `adj_validate_decisions` →
    `adj_apply_label_decision` + `adj_apply_status_decision` + `adj_post_decision_comment` を
    順に駆動 / `adj_log_summary` で 1 行サマリを出力 / NFR 1.1 観測ログ 10 行以内に収める）
  - `local-watcher/bin/modules/pr-reviewer.sh` の `pr_run_review_for_pr` 末尾
    （`pr_publish_codex_status` 直後）に `adj_run_for_pr ... || adj_warn ...` を 1 行追加。
    既存ラベル付与・status publish ロジックは残置（gate OFF 完全等価 / NFR 2.1）
  - **catch-up suppression**（Architecture Decision: claude-review publisher contention / ae-mdm
    設計レビュー #1 への対応）: `pr-reviewer.sh` 末尾に `pr_catchup_should_defer_for_adjudicator
    <pr_number> <sha>` helper を追加（gate ON + adjudicator marker `<!-- idd-claude:pr-adjudicator
    sha=<sha> -->` を `gh pr view --json comments` で fetch し sha 一致判定。gate OFF / marker
    不在 / sha 不一致なら false 返却）。`process_claude_review_status_catchup` のループ内、
    `pr_publish_claude_status_from_branch` 呼び出し直前に
    `pr_catchup_should_defer_for_adjudicator "$pr_number" "$sha" && continue` を 1 行挿入
  - 近接テスト追加:
    - `local-watcher/test/adj_integration_no_op_test.sh` — gate OFF 時に `adj_run_for_pr` を
      呼んでも gh / claude が 1 度も発火せず log 行ゼロであることを stub で確認（NFR 2.1）。
      stub gh / stub claude の呼び出し回数記録ファイルが空であることを assert
    - `local-watcher/test/pr_catchup_suppression_test.sh` — gate ON + marker 存在 sha 一致で
      `pr_catchup_should_defer_for_adjudicator` が 0（defer）/ gate OFF で 1（catch-up 続行）/
      gate ON + marker 不在で 1（passthrough 経路で catch-up 引き継ぎ）/ gate ON + marker 存在
      sha 不一致で 1 を返すことを assert
  - _Requirements: 2.6, 3.1, 3.2, 3.6, 4.2, 5.2, 5.4, NFR 1.1, NFR 2.1_
  - _Boundary: adjudicator.sh, pr-reviewer.sh_
  - _Depends: 5_

- [x] 7. pr-iteration.sh の excessive filter 拡張と近接テスト
  - `local-watcher/bin/modules/pr-iteration.sh` に `pi_general_filter_excessive` を新規追加
    （stdin: JSON 配列、stdout: フィルタ後。gate OFF 時は jq pass-through で no-op /
    NFR 1.1 既存件数挙動維持）
  - `<!-- idd-claude:pr-adjudicator-excessive ... -->` marker を含むコメントを除外
  - `pi_collect_general_comments` の filter chain に `pi_general_filter_resolved` の直後 /
    `pi_general_filter_event_style` の前に挿入し、サマリログに `filtered_excessive` 項目を追加
  - 近接テスト追加: `local-watcher/test/pi_general_filter_excessive_test.sh`（gate ON で
    excessive marker 除外 / gate OFF で pass-through / 既存 self-filter prefix `idd-claude:pr-iteration`
    との非衝突確認 / #400 規約整合）
  - 既存 pr-iteration テストの退行ゼロを確認（NFR 2.2）
  - _Requirements: 2.4, 2.5, 4.3, NFR 1.1, NFR 2.2_
  - _Boundary: pr-iteration.sh_
  - _Depends: 6_

- [x] 8. README 反映とドキュメント要件（Req 6.x）
  - README.md の「オプション機能一覧（opt-in、既定 OFF）」表に 1 行追加（gate 名 / 既定 OFF /
    詳細リンク / 関連 `#404`）
  - 新規 h2 節「PR Reviewer Adjudicator (#404)」を `## PR Reviewer Processor (#261)` の後に挿入。
    内容: 動作概要 / env var 一覧 / `claude-review` 必須化シフトの consumer 手順 / トレードオフ
    （独立性希薄化 = Req 6.1、誤 bypass 緩和策 = Req 6.2 で Req 1.4 / 4.1 を参照、100% 精度を
    目標としない = Req 6.3）/ 観測可能性 / FAQ
  - root ↔ repo-template 同期確認: `diff -r .claude/agents repo-template/.claude/agents` /
    `diff -r .claude/rules repo-template/.claude/rules` の差分ゼロ確認（本 Issue は agents/rules
    不変だが回帰確認 / Req 5.6）
  - _Requirements: 6.1, 6.2, 6.3, 5.6_
  - _Boundary: README.md_
  - _Depends: 7_

- [ ] 9. 静的解析・既存テスト退行確認・E2E スモーク
  - `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh
    .github/scripts/*.sh` 警告ゼロ確認
  - `actionlint .github/workflows/*.yml` クリーン確認
  - 既存テスト退行ゼロ確認:
    `bash local-watcher/test/pr_publish_commit_status_test.sh`
    `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh`
    `bash local-watcher/test/pr_default_prompt_test.sh`
  - 新規テスト一括実行: `for t in local-watcher/test/adj_*_test.sh
    local-watcher/test/pi_general_filter_excessive_test.sh; do bash "$t"; done`
  - cron-like 最小 PATH での起動確認: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v
    claude gh jq flock git'`
  - dry run: `PR_REVIEWER_ADJUDICATOR_ENABLED=false REPO=owner/test REPO_DIR=/tmp/scratch
    $HOME/bin/issue-watcher.sh` で完全 no-op を確認（NFR 2.1 観測ログ diff ゼロ）
  - _Requirements: NFR 2.1, NFR 2.2, NFR 3.1_
  - _Boundary: local-watcher/test, install.sh_
  - _Depends: 8_

## Verify

本 spec の実装後、watcher (stage-a-verify gate) が再実行すべき verify コマンドを以下の構造化
ブロックで宣言する。

設計上の注記: 構造化ブロックは `tasks.md` commit 時点で実在するパスのみを直接対象にし、
本 spec で **新規追加される** test ファイル群（`adj_*_test.sh` / `pi_general_filter_excessive_test.sh`）
は実装完了後に作成されるため、ループ + 存在ガード（`[ -f ]`）でラップして含める。`shellcheck` /
`actionlint` / 既存テスト / `diff -r` の各コマンドは tasks.md commit 時点で対象パスが実在する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  actionlint .github/workflows/*.yml && \
  bash local-watcher/test/pr_publish_commit_status_test.sh && \
  bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh && \
  bash local-watcher/test/pr_default_prompt_test.sh && \
  for t in local-watcher/test/adj_resolve_gate_test.sh local-watcher/test/adj_extract_findings_test.sh local-watcher/test/adj_classify_test.sh local-watcher/test/adj_publish_decision_test.sh local-watcher/test/adj_integration_no_op_test.sh local-watcher/test/pr_catchup_suppression_test.sh local-watcher/test/pi_general_filter_excessive_test.sh; do [ -f "$t" ] && bash "$t" || true; done && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
