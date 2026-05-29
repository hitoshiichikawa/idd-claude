# Implementation Plan

- [x] 1. test-fixtures と判定マトリクス回帰スクリプトを追加する
  - `docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/tasks-with-unchecked.md` を
    新規作成（`- [ ] 1. ...` / `- [ ] 2. ...` を含む 2 件以上、子タスク `1.1` と完了済み
    `- [x] 3. ...` も混在させて regex の精度を担保）
  - `docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/tasks-all-checked.md` を
    新規作成（全 `- [x] N. ...`）
  - `docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/tasks-empty.md` を新規作成
    （0 byte または見出しのみ）
  - `docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/test-merged-guard.sh` を
    新規作成: regex `^- \[ \]\*? [0-9]+\. ` を 3 fixture で `grep -cE` し、期待値
    （unchecked 2 / all-checked 0 / empty 0）と一致するか assert
  - スクリプト先頭で `set -euo pipefail`、`SCRIPT_DIR` を起点に fixture 解決、`PASS` / `FAIL`
    カウンタと終了 code（`FAIL > 0 → exit 1`）を `265-*/test-find-impl-pr.sh` と同形式で実装
  - _Requirements: 2.4, 3.2, 3.3_

- [ ] 2. Stage Checkpoint Module に sc_issue_state ヘルパを追加する
  - `local-watcher/bin/issue-watcher.sh` の Stage Checkpoint Module セクション
    （`stage_checkpoint_has_impl_notes` の直後）に `sc_issue_state()` を新規追加
  - 実装: `gh issue view "$NUMBER" --repo "$REPO" --json state --jq '.state' 2>/dev/null` を
    呼び、stdout が `OPEN` / `CLOSED` の 1 トークンなら rc=0 で stdout 返却、それ以外なら rc=1
    で stdout 空
  - 関数冒頭コメントに「入力: 環境変数 NUMBER / REPO」「戻り値: 0/1」「副作用: なし
    （read-only）」を `stage_checkpoint_has_impl_notes` と同形式で記載
  - `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを維持
  - _Requirements: 2.3, 3.1, 4.3_
  - _Boundary: Stage Checkpoint Module_

- [ ] 3. Stage Checkpoint Module に sc_tasks_unchecked_count ヘルパを追加する (P)
  - `local-watcher/bin/issue-watcher.sh` の Stage Checkpoint Module セクション
    （task 2 の直後）に `sc_tasks_unchecked_count()` を新規追加
  - パス解決: `local rel="$SPEC_DIR_REL/tasks.md"`, `local path="$REPO_DIR/$rel"`
  - 判定 regex: `^- \[ \]\*? [0-9]+\. `（`.claude/rules/tasks-generation.md` の Budget overflow
    count 抽出 regex と完全一致）
  - 実装: `[ -f "$path" ]` false → `echo 0; return 2`（design-less 等価、Req 2.4）/
    `[ -r "$path" ]` false → `echo 0; return 1`（I/O 失敗、Req 3.2）/ 上記両方 OK →
    `count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$path" 2>/dev/null || echo 0)`,
    `echo "$count"; return 0`
  - 関数冒頭コメントに「正本 regex の参照先: `.claude/rules/tasks-generation.md`」を明記し、
    ドリフト防止の根拠を残す
  - `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを維持
  - _Requirements: 2.1, 2.4, 3.2, 3.3_
  - _Boundary: Stage Checkpoint Module_
  - _Depends: 1_

- [ ] 4. stage_checkpoint_find_impl_pr の MERGED 採用ブロックに再判定ガードを inject する
  - `local-watcher/bin/issue-watcher.sh` L1160-1195 付近の `stage_checkpoint_find_impl_pr()` の
    `elif [ -n "$merged_pr" ]; then found="$merged_pr"` 分岐を改修
  - 改修ロジック:
    1. `merged_pr` を採用候補として観測した時点で `merged_num=$(echo "$merged_pr" | jq -r
       '.number // "?"' 2>/dev/null || echo '?')` を取得
    2. `local issue_state="" tasks_unchecked=0 tasks_rc=0`
    3. `issue_state=$(sc_issue_state)` / `issue_rc=$?`
    4. `issue_rc != 0` → `reason=issue-api-failure`、`found="$merged_pr"` 採用
    5. `issue_state == "CLOSED"` → `reason=closed-issue`、`found="$merged_pr"` 採用
    6. `issue_state == "OPEN"` → `tasks_unchecked=$(sc_tasks_unchecked_count)` / `tasks_rc=$?`
       - `tasks_rc == 2` → `reason=no-tasks-file`、`found="$merged_pr"` 採用
       - `tasks_rc == 1` → `reason=tasks-io-failure`、`found="$merged_pr"` 採用
       - `tasks_rc == 0 && tasks_unchecked == 0` → `reason=all-checked`、`found="$merged_pr"`
         採用
       - `tasks_rc == 0 && tasks_unchecked >= 1` → `found=""` で非 terminal 化、`reason=
         open-issue-with-unchecked-tasks`
  - 判定根拠ログ:
    - 非 terminal（Req 4.1）: `sc_log "find-impl-pr: merged-non-terminal pr=#${merged_num}
      issue=#${NUMBER} issue_state=OPEN unchecked=${tasks_unchecked} reason=open-issue-with-
      unchecked-tasks branch=${BRANCH}" >> "$LOG"`
    - terminal（Req 4.2 / 既存 Decision Table 書式の延長）: `sc_log "find-impl-pr: merged-
      terminal pr=#${merged_num} issue=#${NUMBER} issue_state=${issue_state:-unknown}
      unchecked=${tasks_unchecked} reason=<上記 reason 値> branch=${BRANCH}" >> "$LOG"`
  - OPEN PR 優先採用（既存 `if [ -n "$open_pr" ]; then found="$open_pr"`）には 1 行も手を
    入れない（Req 2.5、追加 gh コール不発火）
  - CLOSED 除外ログ（既存 `find-impl-pr: excluded-closed ...`）は不変（Req 5.1）
  - 越境観測ヘルパ（Req 5.2）/ spec 完全性ガード（Req 5.3）/ `STAGE_CHECKPOINT_ENABLED=false`
    時の非発火（Req 5.4）は本関数経由でのみ作用するため、本タスクの inject 範囲を `elif [ -n
    "$merged_pr" ]` ブロック内に閉じることで自動的に維持される
  - `shellcheck local-watcher/bin/issue-watcher.sh` で警告ゼロを維持
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 4.1, 4.2, 4.3, 5.1, 5.2, 5.3, 5.4_
  - _Boundary: Stage Checkpoint Module_
  - _Depends: 2, 3_

- [ ] 5. PjM project-manager.md (root) に Refs/Closes 使い分け規約を追記する (P)
  - `.claude/agents/project-manager.md` の「モード 2: implementation」節（L204 付近）の
    「実装 PR 本文テンプレート」直前に新規サブ節「## 実装 PR 本文の `Refs` / `Closes`
    使い分け（auto-close 事故防止）」を追加
  - サブ節の内容:
    - 判定ロジック（疑似コード）: `tasks.md` の `- [ ] N. ...`（最上位）残存件数 - 当 PR で
      完了予定件数 > 0 なら `Refs #N`、それ以外（全完了 or design-less impl）なら `Closes #N`
    - 判定 regex の正本参照: `.claude/rules/tasks-generation.md` の Budget overflow count
      抽出 regex `^- \[ \]\*? [0-9]+\. `
    - 判定実行例 bash スニペット（`grep -cE '^- \[ \]\*? [0-9]+\. ' "$TASKS_MD"` で件数化）
    - 確認事項への 1 行記載例（Req 1.3）: `部分実装 PR: 残 X 件のため Refs を採用` /
      `最終 PR: tasks.md 全完了のため Closes を採用` / `design-less impl: 単一 PR で完了の
      ため Closes を採用`
  - 「実装 PR 本文テンプレート」の `Closes #<issue-number>` 行を `<Refs|Closes #<issue-
    number>>` のプレースホルダ + 上記サブ節への参照コメントに置換
  - design-review モードの既存「設計 PR 本文の遵守事項（auto-close 事故防止）」節（L106-145）
    との関係を明示: 「design-review モードは常に `Refs` 固定。implementation モードは本サブ節の
    判別ロジックで `Refs` / `Closes` を使い分ける」
  - PR 本文テンプレートのセクション順・必須項目は本サブ節追加以外は不変（NFR 1.4）
  - _Requirements: 1.1, 1.2, 1.3, 1.4_
  - _Boundary: PjM Agent (impl)_

- [ ] 6. PjM project-manager.md (repo-template) を root と byte 一致で更新する
  - `repo-template/.claude/agents/project-manager.md` を task 5 の root 版と **byte 一致**で
    更新する（CLAUDE.md「root と repo-template/ の二重管理」規約 NFR 4.1）
  - 更新後に `diff -r .claude/agents repo-template/.claude/agents` が空（無出力）になることを
    手元で確認
  - _Requirements: 1.4_
  - _Boundary: PjM Agent (impl), リポジトリ二重管理規約_
  - _Depends: 5_

- [ ] 7. README に Refs/Closes 使い分け規約と watcher ガードの概要を追記する (P)
  - `README.md` の「使い方 > 基本フロー」節（L877〜L889 付近）の 7 番目項目「実装 PR が作成
    されたら人間がレビューして merge する」の直後に新規ブロックを追加
  - 内容:
    - tasks.md を分割した複数タスクのうち一部のみを 1 PR で完了させる「部分実装 PR」では
      PjM が PR 本文に `Refs #N` を採用すること
    - 残タスクは追加 impl PR で進めること
    - 最終 PR では `Closes #N` を使い Issue を auto-close させること
    - 万一 `Closes` で部分 merge されてしまい Issue が auto-close された場合、人間が
      Issue を reopen すれば watcher が tasks.md の `- [ ]` 残存を検知して残タスク再開を
      継続すること（本 spec で実装した第 2 防御線）
    - 観測性: 判定根拠は `stage-checkpoint: find-impl-pr: merged-non-terminal ...` /
      `merged-terminal ...` で `cron.log` から grep 可能
  - _Requirements: 1.5_
  - _Boundary: README ワークフロー節_

- [ ]* 8. 統合スモーク手順を impl-notes.md として残す
  - 本タスクは deferrable。Developer が実装直後にスモークテスト結果を `docs/specs/273--bug-
    pr-closes-n-merge-merged-pr/impl-notes.md` に記録する
  - 記録項目: (a) `STAGE_CHECKPOINT_ENABLED=false` 環境で本変更が 1 行も発火しないことの
    grep 結果（Req 5.4 / NFR 1.1）、(b) OPEN PR があるケースで追加 `gh issue view` が発生
    しないことの確認（Req 2.5）、(c) reopen + 残タスクシナリオを fixture Issue で再現した
    cron 1 cycle のログ抜粋（Req 4.1）
  - _Requirements: 2.5, 4.1, 5.4_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで
宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules && \
  bash docs/specs/273--bug-pr-closes-n-merge-merged-pr/test-fixtures/test-merged-guard.sh
```
