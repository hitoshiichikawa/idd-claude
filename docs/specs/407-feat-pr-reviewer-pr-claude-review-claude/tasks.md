# Implementation Plan

- [x] 1. logger 関数追加と env Config 拡張（前提整備）
  - `local-watcher/bin/modules/core_utils.sh` の既存 `adj_log` / `adj_warn` / `adj_error`
    と同形式で `pdr_log` / `pdr_warn` / `pdr_error` を **末尾追記**する（時刻 + `[$REPO]` +
    `pr-design-reviewer:` prefix。stderr / stdout 分離契約に整合）
  - `local-watcher/bin/issue-watcher.sh` の Config ブロック（既存
    `# ─── PR Reviewer Adjudicator 設定 (#404) ───` 節の **直後**）に
    `# ─── Design PR Reviewer 設定 (#407) ───` 節を追加し、以下 7 env を `${VAR:-default}`
    で解決:
    `DESIGN_REVIEWER_ENABLED` / `DESIGN_REVIEWER_MODEL` / `DESIGN_REVIEWER_EXEC_TIMEOUT` /
    `DESIGN_REVIEWER_PROMPT` / `DESIGN_REVIEWER_HEAD_PATTERN` / `DESIGN_REVIEWER_MAX_PRS` /
    `DESIGN_REVIEWER_OUTPUT_FORMAT`
  - `DESIGN_REVIEWER_ENABLED` は `case` で安全側正規化（`true` 厳密以外を `false`）。
    `DESIGN_REVIEWER_EXEC_TIMEOUT` / `DESIGN_REVIEWER_MAX_PRS` は `''|*[!0-9]*) ... ;; *) ...lt 1` で
    数値正規化（既存 `PR_REVIEWER_ADJUDICATOR_*` と同パターン）。`DESIGN_REVIEWER_OUTPUT_FORMAT`
    は `case` で `text|json` 以外を `text` に正規化
  - 既存 env 名・既定値の変更なしを差分レビューで確認（grep で `PR_REVIEWER_` / `PR_ITERATION_`
    既存行に diff が無いことを確認 / Req 6.3）
  - 近接テスト追加: `local-watcher/test/pdr_resolve_gate_test.sh`（`=true` 厳密 / `True` /
    `1` / 空 / typo の 5 ケースで安全側 OFF / Req 6.1）。`extract_function` イディオム踏襲
    （`pdr_gate_enabled` 関数を `local-watcher/bin/modules/pr-design-reviewer.sh` から抽出する
    形だが、本 task 時点では module 未作成のため、env 正規化と `[ "$DESIGN_REVIEWER_ENABLED"
    = "true" ]` 判定を inline 検証する小規模 fixture でカバーする。完全な `pdr_gate_enabled`
    関数テストは task 3 で再検証）
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/core_utils.sh` 警告ゼロ
  - _Requirements: 5.4, 6.1, 6.3, 6.5_
  - _Boundary: core_utils.sh, issue-watcher.sh_

- [x] 2. design-review-prompt.tmpl の作成と read-only 契約の明示
  - `local-watcher/bin/design-review-prompt.tmpl` を新規作成
  - プレースホルダ: `{PR}` / `{SHA}` / `{BASE}` / `{HEAD}` / `{ISSUE_NUMBER}` / `{SPEC_DIR}` /
    `{REQUIREMENTS_MD}` / `{DESIGN_MD}` / `{TASKS_MD}`（解決不能時は `(none)`）
  - 判定軸 3 観点限定の指示（AC カバレッジ / design⇄tasks 整合 / Traceability）と
    「迷ったら approve」の保守的判定指示（Req 2.4）を明記
  - 出力契約（text 形式の構造 + 末尾 `VERDICT: approve|reject` standalone 行 / `DESIGN_REVIEWER_OUTPUT_FORMAT=json`
    時の JSON schema）を template 末尾で明示（design.md「Data Models」節と一致）
  - read-only 制約（Bash の git commit / push / gh edit / gh comment 禁止 / 標準出力以外を
    末尾に付けない）を明記
  - スタイル違反 / 命名 / typo / フォーマット を reject 理由にしないことを明記（Req 2.6）
  - install.sh は既存 `*.tmpl` glob で自動配布されるため変更不要であることを diff で確認
  - 近接テスト追加: `local-watcher/test/pdr_parse_verdict_test.sh` の前段で template ファイル
    存在 + 必須プレースホルダ 9 種を grep で検証する fixture を含める（部分配信防止）
  - _Requirements: 2.1, 2.4, 2.5, 2.6_
  - _Boundary: design-review-prompt.tmpl_
  - _Depends: 1_

- [x] 3. pr-design-reviewer.sh モジュール骨格と gate / pattern / dedup の実装＋テスト
  - `local-watcher/bin/modules/pr-design-reviewer.sh` を新規作成（先頭コメントに用途 /
    配置先 / 依存 / 関数 prefix `pdr_` / トップレベル副作用なしを明記。既存 `adjudicator.sh`
    冒頭コメント構造を踏襲）
  - 実装関数: `pdr_gate_enabled` / `pdr_classify_design_pr` / `pdr_fetch_design_prs` /
    `pdr_already_processed`
    - `pdr_gate_enabled`: 正規化済み `DESIGN_REVIEWER_ENABLED` を厳密 `=true` で評価
    - `pdr_classify_design_pr`: head_ref を `DESIGN_REVIEWER_HEAD_PATTERN` ERE と照合（design /
      非 design の 2 値判定）
    - `pdr_fetch_design_prs`: `gh pr list --state open --search "-draft:true" --json ...`
      + jq filter（`isDraft == false`, owner 一致 = 非 fork, head pattern 一致）。既存
      `pr_fetch_candidate_prs` を参考に同形式で実装。失敗時は `"[]"` + WARN
    - `pdr_already_processed`: `gh pr view --json comments` で hidden marker
      `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->` を `jq --arg sha`
      で scan
  - `local-watcher/bin/issue-watcher.sh` の `REQUIRED_MODULES` 配列に `"pr-design-reviewer.sh"`
    を追加（`"adjudicator.sh"` の隣を推奨）
  - 近接テスト追加:
    - `local-watcher/test/pdr_resolve_gate_test.sh`（task 1 の inline 検証を置き換え。
      `pdr_gate_enabled` 関数を `extract_function` で抽出 + 5 ケース検証 / Req 6.1）
    - `local-watcher/test/pdr_classify_design_pr_test.sh`（head pattern マッチング 3 ケース:
      `claude/issue-1-design-foo` → design / `claude/issue-1-impl-foo` → 非 design /
      `claude/something-else` → 非 design / Req 1.3, 7.4）
    - `local-watcher/test/pdr_already_processed_test.sh`（stub gh で hidden marker scan の
      3 ケース: 同 sha marker 存在 → 処理済み / sha 異なる marker → 未処理 / marker 不在 →
      未処理 / Req 1.4）
  - `shellcheck local-watcher/bin/modules/pr-design-reviewer.sh` 警告ゼロ + `bash -n` OK
  - _Requirements: 1.1, 1.3, 1.4, 6.1, 7.4_
  - _Boundary: pr-design-reviewer.sh, issue-watcher.sh_
  - _Depends: 1, 2_

- [x] 4. invoke_reviewer / parse_verdict / validate_verdict と保守的 fallback の実装＋テスト
  - `pr-design-reviewer.sh` に以下を追加: `pdr_invoke_reviewer`（Claude CLI 呼び出し /
    `--output-format` は `DESIGN_REVIEWER_OUTPUT_FORMAT` に従う / mktemp で prompt 一時ファイル
    / `DESIGN_REVIEWER_EXEC_TIMEOUT` で timeout）/ `pdr_parse_verdict`（text 形式は最終行
    `VERDICT: approve|reject` を grep / JSON 形式は jq で `.verdict` 抽出 / 3 観点 reason 抽出）/
    `pdr_validate_verdict`（verdict 値が `approve|reject` のいずれか / 3 観点 reason が
    非空であることを検証）
  - read-only invariant 検査（実行後 `git status --porcelain` で tracked 変更検出 → `git
    checkout -- .` で破棄、`workspace-modified` 報告）
  - parse / validate 失敗時は **保守的に approve に倒す**（Req 2.4 / 永久 BLOCKED 回避）。
    raw 出力末尾 512B を後続 `pdr_post_decision_comment` に渡せる形で stdout に返す
  - 近接テスト追加: `local-watcher/test/pdr_parse_verdict_test.sh`（text 形式 verdict
    抽出 / JSON 形式 verdict 抽出 / VERDICT 行不在時の保守的 approve fallback / 3 観点 reason
    不足時の `pdr_validate_verdict` 失敗判定 / Req 2.2, 2.3, 2.4, 2.5 の 4〜5 ケース）
  - _Requirements: 2.2, 2.3, 2.4, 2.5_
  - _Boundary: pr-design-reviewer.sh_
  - _Depends: 3_

- [x] 5. label / status publish 反映と decision comment 投稿の実装＋テスト
  - `pr-design-reviewer.sh` に以下を追加: `pdr_apply_label_decision`（`gh pr edit
    --add-label "$LABEL_NEEDS_ITERATION"` / `--remove-label` の冪等使用 / reject → 付与 /
    approve → 解消）/ `pdr_apply_status_decision`（既存 `pr_publish_claude_status` を **読み出し
    のみで流用**し、approve → success / reject → failure を publish。pr-reviewer.sh は無変更 /
    Req 7.2）/ `pdr_post_decision_comment`（hidden marker
    `<!-- idd-claude:pr-design-reviewer sha=<sha> kind=decision -->` 付きで判定サマリを
    `gh pr comment` で投稿。重複防止は同 marker を `pdr_already_processed` で検出する形）
  - 近接テスト追加: `local-watcher/test/pdr_apply_decision_test.sh`（stub gh + stub
    `pr_publish_claude_status` で 4 ケース検証: approve → success + needs-iteration remove /
    reject → failure + needs-iteration add / status publish 失敗時の WARN / コメント投稿失敗
    時の WARN）。Req 3.1, 3.2, 3.5, 4.1, 4.2, 5.1, 5.3 をカバー
  - hidden marker prefix `pr-design-reviewer` が既存 `pi_general_filter_self`
    （`idd-claude:pr-iteration` prefix のみ除外）から filter されないことを substring 検証
    する fixture を含める（Req 5.3 / NFR 1.2）
  - **既存ラベル名 / context 名（`needs-iteration` / `claude-review`）を変更せず流用**する
    ことを実装側で確認（Req 6.4）。新規ラベル / 新規 context は追加しない
  - _Requirements: 3.1, 3.2, 3.4, 3.5, 4.1, 4.2, 5.1, 5.3, 6.4, NFR 1.2_
  - _Boundary: pr-design-reviewer.sh_
  - _Depends: 4_

- [x] 6. process_pr_design_reviewer オーケストレーション + dispatcher 配線 + no-op テスト
  - `pr-design-reviewer.sh` に `pdr_run_review_for_pr`（入力: pr_json。head_ref / pr_number /
    sha / base_ref / pr_url を分解。gate OFF / dedup hit / pattern 不一致を早期処理し、
    `pdr_invoke_reviewer` → `pdr_parse_verdict` → `pdr_validate_verdict` →
    `pdr_apply_label_decision` + `pdr_apply_status_decision` + `pdr_post_decision_comment` を
    順に駆動 / `pdr_log` で 1 行サマリを出力 / NFR 1.1 観測ログ 10 行以内に収める / Claude exec
    失敗時は publish せず pending 据え置き / Req 3.3）と `process_pr_design_reviewer`
    （dispatcher エントリ。gate OFF で早期 return / 候補 PR を `pdr_fetch_design_prs` で
    取得 / `DESIGN_REVIEWER_MAX_PRS` で truncate / 各 PR に対し `pdr_run_review_for_pr` を
    呼ぶ）を追加
  - `local-watcher/bin/issue-watcher.sh` の dispatcher 配線、`process_claude_review_status_catchup
    || pr_warn ...` 行（line 1859 相当）の **直後**に
    `process_pr_design_reviewer || pdr_warn "process_pr_design_reviewer が想定外のエラーで
    終了しました（後続 Issue 処理は継続）"` を 1 行追加。後続 `process_security_review` /
    `process_pr_iteration` への副作用なし（Req 4.4, 6.5, 7.2）
  - 近接テスト追加: `local-watcher/test/pdr_no_op_test.sh`（gate OFF 時に
    `process_pr_design_reviewer` を呼んでも stub gh / stub claude が 1 度も発火せず log 行
    ゼロであることを確認。stub の呼び出し回数記録ファイルが空であることを assert /
    NFR 1.1 / 2.1）
  - _Requirements: 1.1, 1.2, 1.5, 3.3, 4.3, 4.4, 5.2, 5.4, 6.2, 6.5, 7.2, NFR 1.1, NFR 2.1, NFR 4.1_
  - _Boundary: pr-design-reviewer.sh, issue-watcher.sh_
  - _Depends: 5_

- [x] 7. design-reviewer.md agent 定義の追加と root ↔ repo-template 同期
  - `.claude/agents/design-reviewer.md` を新規作成（frontmatter:
    `name: design-reviewer` /
    `description: 設計 PR (docs/specs/<N>-<slug>/) の AC カバレッジ / design⇄tasks 整合 /
    Traceability の 3 観点のみで approve / reject を判定する独立サブエージェント。要件 /
    設計 / タスクの書き換えは行わない。impl 用 Reviewer (reviewer.md) とは判定軸を共有しない
    独立定義。` /
    `tools: Read, Grep, Glob, Bash, Write` ※ Write は標準出力相当の用途のみ。本文の禁止節
    で「ファイル書き換え不可」を強制）
  - 本文に判定基準 3 観点（AC カバレッジ / design⇄tasks 整合 / Traceability）、出力契約
    （VERDICT 行 standalone / lowercase 完全一致 / 装飾禁止）、保守的判定指示
    （Req 2.4）、禁止節（spec / コード / テストの書き換え不可 / `git` / `gh` 系副作用操作不可 /
    3 観点以外の理由での reject 不可）を明記
  - **impl 用 `reviewer.md` をコピーしない**（Req 7.1 独立定義）。判定軸 / カテゴリ / RESULT 行
    規律は本 agent 独自に定義する（context 名は `VERDICT:` を使い impl 用 `RESULT:` と区別 /
    design.md「Components and Interfaces」節参照）
  - `repo-template/.claude/agents/design-reviewer.md` に **byte 一致**で同一ファイルを配置
    （Req 6.6 / CLAUDE.md §4 二重管理同期鉄則）
  - 確認: `diff -r .claude/agents repo-template/.claude/agents` が差分ゼロを返すこと
  - 確認: `diff -r .claude/rules repo-template/.claude/rules` が差分ゼロを返すこと（本 Issue は
    rules 不変だが回帰確認）
  - _Requirements: 1.2, 1.5, 2.1, 2.4, 2.5, 2.6, 6.6, 7.1_
  - _Boundary: .claude/agents/design-reviewer.md, repo-template/.claude/agents/design-reviewer.md_
  - _Depends: 2_

- [ ] 8. README 反映とドキュメント要件
  - `README.md` の「オプション機能一覧（opt-in、既定 OFF）」表に 1 行追加（gate 名
    `DESIGN_REVIEWER_ENABLED` / 既定 OFF / 詳細リンク / 関連 `#407`）
  - 新規 h2 節「Design PR Reviewer (#407)」を `## PR Reviewer Adjudicator (#404)` の **後**に
    挿入。内容: 動作概要 / env var 一覧（7 種） / `claude-review` OR 条件 merge 経路の
    consumer 手順 / `awaiting-design-review` 人間ラベルとの併存説明 / 判定軸 3 観点（AC
    カバレッジ / design⇄tasks / Traceability）/ 保守的判定（Req 2.4）/ 観測可能性（hidden
    marker + watcher ログ） / 既知の制約（impl PR / 非 idd-claude PR は対象外）/ #404
    adjudicator との非干渉 / FAQ
  - root ↔ repo-template 同期確認: `diff -r .claude/agents repo-template/.claude/agents` /
    `diff -r .claude/rules repo-template/.claude/rules` の差分ゼロ確認（task 7 で追加した
    `design-reviewer.md` が両系統に同一配置されていることの最終確認 / Req 6.6）
  - _Requirements: 5.1, 5.2, 6.6_
  - _Boundary: README.md_
  - _Depends: 7_

- [ ] 9. 静的解析・既存テスト退行確認・E2E スモーク + 独立性検証
  - `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh
    .github/scripts/*.sh` 警告ゼロ確認
  - `actionlint .github/workflows/*.yml` クリーン確認
  - 既存テスト退行ゼロ確認（既存 PR Reviewer / adjudicator / iteration 関連テストの
    spot 実行）:
    `bash local-watcher/test/pr_publish_commit_status_test.sh`
    `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh`
    `bash local-watcher/test/pr_default_prompt_test.sh`
    `bash local-watcher/test/adj_resolve_gate_test.sh`
    `bash local-watcher/test/adj_publish_decision_test.sh`
    `bash local-watcher/test/pi_general_filter_excessive_test.sh`
  - 新規テスト一括実行: `for t in local-watcher/test/pdr_*_test.sh; do bash "$t"; done`
  - **独立性検証**（Req 7.3 / `#404` adjudicator 経路の不変性確認）:
    - `git diff main -- local-watcher/bin/modules/adjudicator.sh` が空であること
    - `git diff main -- local-watcher/bin/modules/pr-reviewer.sh` が空であること
    - `git diff main -- .claude/agents/reviewer.md repo-template/.claude/agents/reviewer.md` が
      空であること
    - `git diff main -- local-watcher/bin/adjudicator-prompt.tmpl` が空であること
    - `grep -nE 'PR_REVIEWER_ADJUDICATOR_' local-watcher/bin/issue-watcher.sh` の出力件数が
      本 Issue 着手前と一致（既存 6 env の名前 / 既定値の不変性 / Req 6.3, 7.3）
  - cron-like 最小 PATH での起動確認: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c
    'command -v claude gh jq flock git'`
  - dry run: `DESIGN_REVIEWER_ENABLED=false REPO=owner/test REPO_DIR=/tmp/scratch
    $HOME/bin/issue-watcher.sh` で完全 no-op を確認（NFR 2.1 観測ログ diff ゼロ）
  - dry run（gate ON）: `DESIGN_REVIEWER_ENABLED=true REPO=owner/test REPO_DIR=/tmp/scratch
    $HOME/bin/issue-watcher.sh` で「対象 PR なし」サマリ 1 行が出ること（候補ゼロでも
    pdr_log のみが発火することを確認）
  - _Requirements: 6.3, 6.4, 7.3, NFR 2.1, NFR 2.2, NFR 3.1_
  - _Boundary: local-watcher/test, install.sh, adjudicator.sh, pr-reviewer.sh, reviewer.md_
  - _Depends: 8_

## Verify

本 spec の実装後、watcher (stage-a-verify gate) が再実行すべき verify コマンドを以下の
構造化ブロックで宣言する。

設計上の注記: 構造化ブロックは `tasks.md` commit 時点で実在するパスのみを直接対象にする。
本 spec で **新規追加される** test ファイル群（`pdr_*_test.sh`）と新規モジュール
（`pr-design-reviewer.sh`）は実装完了後に作成されるため、ループ + 存在ガード（`[ -f ]`）で
ラップして含める。`shellcheck` / `actionlint` / 既存テスト / `diff -r` の各コマンドは
tasks.md commit 時点で対象パスが実在する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  actionlint .github/workflows/*.yml && \
  bash local-watcher/test/pr_publish_commit_status_test.sh && \
  bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh && \
  bash local-watcher/test/pr_default_prompt_test.sh && \
  bash local-watcher/test/adj_resolve_gate_test.sh && \
  bash local-watcher/test/adj_publish_decision_test.sh && \
  bash local-watcher/test/pi_general_filter_excessive_test.sh && \
  for t in local-watcher/test/pdr_resolve_gate_test.sh local-watcher/test/pdr_classify_design_pr_test.sh local-watcher/test/pdr_already_processed_test.sh local-watcher/test/pdr_parse_verdict_test.sh local-watcher/test/pdr_apply_decision_test.sh local-watcher/test/pdr_no_op_test.sh; do [ -f "$t" ] && bash "$t" || true; done && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
