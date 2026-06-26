# 実装ノート: Design PR Reviewer (#407)

## 実装サマリ

設計 PR (`claude/issue-<N>-design-<slug>`) に対する独立 Claude 設計レビュアを `opt-in gate`
配下（`DESIGN_REVIEWER_ENABLED=true` 厳密一致）で追加し、3 観点（AC カバレッジ /
design⇄tasks 整合 / Traceability）のみで approve/reject を判定して `claude-review` commit
status を publish + `needs-iteration` ラベル制御する Processor を実装した。impl PR 用
Reviewer / #404 adjudicator のコード・env・ラベル運用には一切触れず、両者は head pattern
により対象 PR が構造的に分離される（pr-reviewer.sh / adjudicator.sh は無変更）。

成果物:

- `local-watcher/bin/modules/pr-design-reviewer.sh`（新規 / 関数 prefix `pdr_`）
- `local-watcher/bin/design-review-prompt.tmpl`（新規 / 9 プレースホルダ）
- `local-watcher/bin/modules/core_utils.sh`（`pdr_log/warn/error` 末尾追記）
- `local-watcher/bin/issue-watcher.sh`（Config 7 env / REQUIRED_MODULES / dispatcher 配線 1 行）
- `.claude/agents/design-reviewer.md` + `repo-template/.claude/agents/design-reviewer.md`
  （byte 一致 sync）
- `README.md`（オプション機能表 1 行 + 新規 h2 節「Design PR Reviewer (#407)」）
- `local-watcher/test/pdr_*_test.sh`（6 ファイル / 計 124 PASS）

## AC Traceability（要件 ID → 担保テスト / 実装）

| Req ID | 担保 |
|---|---|
| 1.1 open + non-draft 設計 PR 起動 | `pdr_fetch_design_prs`（pr-design-reviewer.sh）/ `pdr_no_op_test.sh` Case 1〜3 |
| 1.2 spec 3 ファイルを独立 context で読む | `pdr_invoke_reviewer` / `.claude/agents/design-reviewer.md` Read 指示 |
| 1.3 impl PR / 非対応 head を除外 | `pdr_classify_design_pr` / `pdr_classify_design_pr_test.sh` 全 10 ケース |
| 1.4 同一 sha 重複起動回避 | `pdr_already_processed` / `pdr_already_processed_test.sh` Case 1〜3 |
| 1.5 spec 書き換えない | `pdr_invoke_reviewer` の `git status --porcelain` + `--permission-mode plan` / agent 禁止節 |
| 2.1 判定軸 3 観点限定 | `design-review-prompt.tmpl` 本文 / `.claude/agents/design-reviewer.md` 判定基準節 |
| 2.2 違反 → reject | `pdr_parse_verdict` T.2（reject 抽出）/ `design-reviewer.md` 出力契約 |
| 2.3 違反なし → approve | `pdr_parse_verdict` T.1 / `pdr_apply_decision_test.sh` B.1 |
| 2.4 確信なし → 保守的 approve | `pdr_run_review_for_pr` の fallback / `pdr_parse_verdict_test.sh` T.3, T.4, J.4 / prompt 本文「保守的判定」節 |
| 2.5 verdict + 3 観点 reason 1:1 | `pdr_validate_verdict` / `pdr_parse_verdict_test.sh` V.1〜V.4 |
| 2.6 style/typo は reject 不可 | prompt 本文 / `design-reviewer.md` 禁止節 |
| 3.1 approve → claude-review=success | `pdr_apply_status_decision` / `pdr_apply_decision_test.sh` B.1 |
| 3.2 reject → claude-review=failure | `pdr_apply_status_decision` / `pdr_apply_decision_test.sh` B.2 |
| 3.3 exec-failed → pending 据え置き | `pdr_run_review_for_pr` の早期 return (rc=2) / `pdr_invoke_reviewer` の rc 経路 |
| 3.4 context 名 claude-review 統一 | `pr_publish_claude_status` を read-only 流用 / `pdr_apply_decision_test.sh` B.1/B.2 |
| 3.5 awaiting-design-review と OR 併存 | `pdr_apply_status_decision` は status のみ操作 / `pdr_apply_decision_test.sh` Req 3.5 assertion |
| 4.1 reject → needs-iteration 付与 | `pdr_apply_label_decision` / `pdr_apply_decision_test.sh` A.1 |
| 4.2 approve → needs-iteration 解消 | `pdr_apply_label_decision` / `pdr_apply_decision_test.sh` A.2 |
| 4.3 needs-iteration → PR Iteration 駆動 | 既存 `process_pr_iteration` の design 経路を流用（無変更）/ 配線順序（本 processor は process_pr_iteration の **前**）|
| 4.4 既存 design iteration 経路を変えない | dispatcher 配線で `process_pr_iteration` 直前に挿入 / `pr-iteration.sh` 無変更 |
| 5.1 観測可能性 | `pdr_post_decision_comment` / `pdr_apply_decision_test.sh` C.1 (hidden marker + 本文) |
| 5.2 watcher ログ 1 行サマリ | `pdr_run_review_for_pr` 末尾の `pdr_log` 1 行サマリ |
| 5.3 marker prefix が PI self-filter 非衝突 | hidden marker `idd-claude:pr-design-reviewer` / `pdr_already_processed_test.sh` Case 7 + `pdr_apply_decision_test.sh` C.1 substring scan |
| 5.4 ログ規約整合 | `pdr_log` / `pdr_warn` / `pdr_error`（core_utils.sh 既存 adj_log と同形式） |
| 6.1 opt-in gate 既定 OFF / 安全側正規化 | `pdr_gate_enabled` + Config `case` / `pdr_resolve_gate_test.sh` 14 ケース |
| 6.2 gate OFF で no-op | `process_pr_design_reviewer` の早期 return / `pdr_no_op_test.sh` Case 1〜3 |
| 6.3 既存 env 不変 | `git diff main` で `PR_REVIEWER_ADJUDICATOR_*` 6 env declaration line 番号・既定値が一致 |
| 6.4 既存ラベル / context 名不変 | 流用のみ（`needs-iteration` / `claude-review` を共有）/ `pdr_apply_decision_test.sh` 全件 |
| 6.5 既存 exit code / cron 文字列不変 | dispatcher call site 1 行追加（rc=0 固定）/ `process_pr_design_reviewer \|\| pdr_warn ...` パターンで吸収 |
| 6.6 root ↔ repo-template byte 一致 | `diff -r .claude/agents repo-template/.claude/agents` 空 / `diff -r .claude/rules ...` 空 |
| 7.1 impl 用 reviewer.md と独立定義 | 新規 `design-reviewer.md`（`reviewer.md` 無変更、判定軸 `VERDICT:` vs `RESULT:` で分離）|
| 7.2 impl publish 経路と独立 | 新規 `process_pr_design_reviewer` / pr-reviewer.sh 無変更 |
| 7.3 #404 adjudicator 不変 | `git diff main -- adjudicator.sh adjudicator-prompt.tmpl reviewer.md` すべて空 / `PR_REVIEWER_ADJUDICATOR_*` env 6 declaration 不変 |
| 7.4 同時 open 時 impl 経路に介入しない | `pdr_classify_design_pr` で design pattern 厳格化 / `pdr_classify_design_pr_test.sh` impl PR ケース |
| NFR 1.1 ログ +10 行以内 | `process_pr_design_reviewer` 早期 return (gate OFF=0 行) / `pdr_no_op_test.sh` |
| NFR 1.2 marker key が PI self-filter 非衝突 | Req 5.3 と同 |
| NFR 2.1 gate OFF log diff ゼロ | `pdr_no_op_test.sh` Case 1〜3 |
| NFR 2.2 既存テスト退行禁止 | verify suite で `pr_publish_*` / `adj_*` / `pi_*` 既存 6 テストを再実行確認 |
| NFR 3.1 観測可能なテスト 5 ケース追加 | `pdr_*_test.sh` 6 ファイル 計 124 PASS（gate OFF / approve / reject / exec-failed / impl PR 除外を網羅）|
| NFR 4.1 判定時間 5 分以内 + env override | `DESIGN_REVIEWER_EXEC_TIMEOUT` 既定 300 / `timeout` コマンドで claude 起動を抑制 |

## 検証結果

### 静的解析

```text
shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh  → PASS（警告ゼロ）
actionlint .github/workflows/*.yml                                                                          → PASS
bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-design-reviewer.sh                  → PASS
```

### テスト

| テスト | 件数 |
|---|---|
| `pdr_resolve_gate_test.sh` | 14 PASS / 0 FAIL |
| `pdr_classify_design_pr_test.sh` | 10 PASS / 0 FAIL |
| `pdr_already_processed_test.sh` | 12 PASS / 0 FAIL |
| `pdr_parse_verdict_test.sh` | 34 PASS / 0 FAIL |
| `pdr_apply_decision_test.sh` | 38 PASS / 0 FAIL |
| `pdr_no_op_test.sh` | 16 PASS / 0 FAIL |
| **新規合計** | **124 PASS / 0 FAIL** |
| `pr_publish_commit_status_test.sh` (既存) | 74 PASS / 0 FAIL（退行なし） |
| `pr_publish_claude_status_from_branch_test.sh` (既存) | 52 PASS / 0 FAIL |
| `pr_default_prompt_test.sh` (既存) | 52 PASS / 0 FAIL |
| `adj_resolve_gate_test.sh` (既存) | 8 PASS / 0 FAIL |
| `adj_publish_decision_test.sh` (既存) | 51 PASS / 0 FAIL |
| `pi_general_filter_excessive_test.sh` (既存) | 14 PASS / 0 FAIL |

### 同期確認（Req 6.6）

```text
diff -r .claude/agents repo-template/.claude/agents  → 差分ゼロ
diff -r .claude/rules repo-template/.claude/rules    → 差分ゼロ
```

### 独立性検証（Req 7.3）

```text
git diff main -- local-watcher/bin/modules/adjudicator.sh       → 空
git diff main -- local-watcher/bin/modules/pr-reviewer.sh       → 空
git diff main -- .claude/agents/reviewer.md                     → 空
git diff main -- repo-template/.claude/agents/reviewer.md       → 空
git diff main -- local-watcher/bin/adjudicator-prompt.tmpl      → 空
PR_REVIEWER_ADJUDICATOR_* env 6 declaration line 番号・既定値:
  main = HEAD（685, 692, 698, 709, 714, 720 行 / 既定値 false / claude-sonnet-4-5 /
  300 / 空 / passthrough / 50 すべて一致）
```

`PR_REVIEWER_ADJUDICATOR_` 文字列の grep 件数は main=21 → HEAD=23 と 2 件増えるが、
これは新規 Design Reviewer Config ブロックのコメントで「既存 PR_REVIEWER_ADJUDICATOR_MODEL
命名規約踏襲」「既存 PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT と同じ case パターン」と
参照しているコメント 2 行による増加で、env declaration / default / case 正規化は完全に不変。

### 配線確認

```text
issue-watcher.sh:1860 process_pr_design_reviewer || pdr_warn ... (1 行追加)
issue-watcher.sh:1331 REQUIRED_MODULES に "pr-design-reviewer.sh" 追加（"adjudicator.sh" の隣）
```

dispatcher 配線位置: `process_claude_review_status_catchup` 直後 / `process_security_review` 直前 /
`process_pr_iteration` の前（impl 経路が一巡してから design 経路に入る配置 / design.md
「claude-review publisher contention」節と整合）。

### cron-like 最小 PATH 確認

```text
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq flock git'
 → gh / jq / flock / git すべて /usr/bin/ で解決可
（claude は issue-watcher.sh 冒頭の PATH prepend 経由で解決される既存契約）
```

## 設計判断・トレードオフ

### 1. 独立モジュール vs pr-reviewer.sh 拡張

design.md「Architecture Decision: 独立コンポーネントとしての配置」で案 B（新規 module
`pr-design-reviewer.sh`）を採用。impl 経路の触らない契約（Req 7.1〜7.4）を構造的に保証
するため案 A（pr-reviewer.sh 拡張）は不採用。`pr_publish_claude_status` は read-only で
流用するのみで pr-reviewer.sh のコードは変更しない。

### 2. 保守的判定（迷ったら approve）

Req 2.4 の `false-reject 永久 BLOCKED 回避` を最優先し、`pdr_parse_verdict` 失敗 /
`pdr_validate_verdict` 失敗 / spec dir 不在 / 3 ファイル不在のいずれも保守的に `approve`
に倒す（`pdr_run_review_for_pr` 内で fallback 処理）。トレードオフとして false-approve
リスクが残るが、人間運用の `awaiting-design-review` ラベルゲートと OR 条件併存することで
人間レビュアが補完できる構造。

### 3. RESULT: と VERDICT: の使い分け

impl 用 reviewer.md は `RESULT: approve|reject` を出力契約とする。本機能では parse 経路を
完全分離するため `VERDICT: approve|reject` を採用（`pdr_parse_verdict` が `VERDICT:` 固定で
grep）。これにより impl 用 reviewer.md（`review-notes.md` の RESULT 行を読む既存
`parse_review_result` / catch-up 経路）と本機能（PR コメント本文の VERDICT 行を読む
`pdr_parse_verdict`）が同一 parse helper を共有することなく、独立に動作する。

### 4. catch-up との衝突回避（設計 PR で silent skip）

`process_claude_review_status_catchup`（#374）は head から `docs/specs/<N>-<slug>/review-notes.md`
を読むが、設計 PR の head にはこのファイルが存在しない（Architect 成果物には含まれない）
ため、catch-up は `pr_warn` + return 0 で silent skip する（pr-reviewer.sh:1338 参照）。
本機能は catch-up の **後** に dispatcher で実行されるため、設計 PR の `claude-review` 確定権は
本機能が握る（latest-wins）。

### 5. `--permission-mode plan` による read-only 二重防御

`pdr_invoke_reviewer` は `claude --permission-mode plan` で起動し、Claude 側で Bash / Edit /
Write を構造的にブロックする（defense-in-depth）。さらに実行後 `git status --porcelain` で
workspace 変更を検出した場合は tracked 変更を破棄し rc=2 (workspace-modified) で skip する
（Req 1.5）。プロンプト本文でも read-only 制約を明示し、3 層で防御する。

### 6. hidden marker prefix の self-filter 非衝突

prefix `pr-design-reviewer` は既存 `pr-reviewer` / `pr-iteration` / `pr-adjudicator` の
いずれとも前方一致しない。具体的には:
- `pr-design-reviewer` ⊅ `pr-reviewer`（途中で `pr-design-` が割って入る）
- `pr-design-reviewer` ⊅ `pr-iteration`
- `pr-design-reviewer` ⊅ `pr-adjudicator`

`pi_general_filter_self`（#400 / `idd-claude:pr-iteration` prefix のみ除外）から filter
されないため、本機能の判定コメントは Architect 反復経路の入力に自然に含まれる
（`pdr_already_processed_test.sh` Case 7 + `pdr_apply_decision_test.sh` C.1 で文字列レベル
検証済み）。

## 確認事項（人間レビュー / 後続 Issue 検討事項）

特になし。tasks.md 9 タスクすべて完了。

## 派生タスク候補（本 Issue scope 外）

- **Architect 反復 prompt template 拡張**: 本機能の reject コメント本文（VERDICT + 3 観点
  reason）を Architect 反復経路（`iteration-prompt-design.tmpl`）で構造化された形で読める
  ように prompt を拡張する可能性。本 Issue scope では既存 prompt を温存し、コメントは
  hidden marker 経由で自然に含まれることを採用（design.md Open Question Q1 参照）。
- **判定キャッシュの永続化**: 現状は hidden marker による per-sha dedup のみで、watcher
  cron 跨ぎでも sha 一致なら skip される。判定本文を `$HOME/.issue-watcher/pr-design-reviewer/`
  等にキャッシュして claude 呼び出しを省略する選択肢があるが、本 Issue scope 外。
- **dogfooding E2E 検証**: 本 spec の self-hosting 環境で `DESIGN_REVIEWER_ENABLED=true` を
  実際に有効化し、設計 PR で `claude-review = success` 発火 → branch protection 充足 →
  merge 可能を観測する E2E 確認（design.md「E2E（dogfooding）」節）。dry-run（候補ゼロ）
  までは本 task で完了させた（gate ON でも候補なしなら 1 行サマリログのみ発火することを
  `process_pr_design_reviewer` のフローで保証 / NFR 1.1）。

STATUS: complete
