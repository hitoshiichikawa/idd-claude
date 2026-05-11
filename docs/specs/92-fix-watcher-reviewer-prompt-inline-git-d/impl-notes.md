# Implementation Notes (Issue #92)

## 変更概要

`local-watcher/bin/issue-watcher.sh` の `build_reviewer_prompt` 関数から、
`git diff ${BASE_BRANCH}..HEAD` 全文を heredoc で埋め込んでいた `## 最新差分` セクションを
**撤廃** した。代わりに以下を実施:

- prompt 内に **差分取得手順** を明示（`git diff --stat ${BASE_BRANCH}..HEAD` で全体把握、
  `git diff ${BASE_BRANCH}..HEAD -- <path>` でファイル単位の詳細）。reviewer サブエージェントは
  着手直後に Bash ツールで自分で実行する
- prompt 内に `BASE_BRANCH` の identifier を 1 行追加（reviewer が git コマンドの引数に直接
  使えるように）。`HEAD commit` / `BRANCH` は従来どおり維持
- 不要になった `diff_content` 変数の取得・fallback テキスト分岐を削除（コードのデッドパス除去）
- `repo-template/.claude/agents/reviewer.md` および root の `.claude/agents/reviewer.md` の
  「入力契約」セクションを **2 行のみ** 補正し、prompt 内 inline diff が無くなる旨と、
  reviewer 自身が Bash で取得することを明示（Out of Scope の「1 行追記程度の補足」許容範囲）

これにより prompt 全長が **差分サイズに依存せず固定**（~3KB 程度）となり、Linux の
`MAX_ARG_STRLEN = 131,072 B` を超えて `execve()` が `E2BIG` を返す問題（KeyNest repo Issue #1
で発生した 327,886B prompt 事例）を構造的に解消した。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`（`build_reviewer_prompt` のみ）
- `repo-template/.claude/agents/reviewer.md`（2 行修正、構造変更なし）
- `.claude/agents/reviewer.md`（同上、root の dogfooding 用 mirror）
- `docs/specs/92-fix-watcher-reviewer-prompt-inline-git-d/impl-notes.md`（本ファイル、新規）

## 検証結果

### 1. `bash -n`（構文チェック）

```bash
$ bash -n local-watcher/bin/issue-watcher.sh && echo OK
OK
```

### 2. `shellcheck`（NFR 2.1）

```bash
$ shellcheck local-watcher/bin/issue-watcher.sh
（exit=0）
```

警告は SC2317 / SC2012 が既存箇所（行 1051, 1052, 1664, 2017, 2299, 3889, 4291）に残存するのみ
で、**本変更（行 2741 付近の `build_reviewer_prompt`）由来の新規警告は 0 件**。NFR 2.1 を満たす。

### 3. プロンプトサイズ測定（最重要 AC: AC 1.2 / NFR 1.1 / NFR 1.2）

`build_reviewer_prompt 1 "(none)"` を関数だけ抽出して source し、`wc -c` で測定:

| 条件 | diff サイズ | 修正前 prompt | 修正後 prompt |
|---|---|---|---|
| slot-1 worktree（main からの diff なし） | 0B | 2,231B | 2,976B |
| 一時 worktree（PR #91 マージコミット 2a4031a vs その親） | 87,743B | **89,636B** | **2,863B** |

修正後は差分サイズに依存せず、**131,072B 未満の固定サイズ（〜3KB）** に収まることを確認。
NFR 1.1（131,072B 未満）/ NFR 1.2（差分内容に依存せず数 KB）達成。

測定コマンド再現手順:

```bash
# function 単位で抽出
awk '/^build_reviewer_prompt\(\) \{/,/^}$/' local-watcher/bin/issue-watcher.sh > /tmp/brp.sh
NUMBER=92 TITLE=test URL=https://example/92 REPO=owner/test \
  BRANCH=claude/issue-92-impl-fix-watcher-reviewer-prompt-inline-git-d \
  SPEC_DIR_REL=docs/specs/92-fix-watcher-reviewer-prompt-inline-git-d \
  BASE_BRANCH=main \
  bash -c 'source /tmp/brp.sh; build_reviewer_prompt 1 "(none)" | wc -c'
# => 2976
```

大 diff の擬似環境（87KB 差分を持つ過去 merge commit を起点に検証）:

```bash
git worktree add --detach /tmp/idd-large-diff-test 2a4031a
cd /tmp/idd-large-diff-test
# 修正後の関数を slot-1 から取り出して source
awk '/^build_reviewer_prompt\(\) \{/,/^}$/' /tmp/issue-watcher-post.sh > /tmp/brp_post.sh
BASE_BRANCH=765f8c7cdd783d5fe9de571411a28e0ff894b688 \
  NUMBER=92 TITLE=test URL=https://example/92 REPO=owner/test \
  BRANCH=claude/issue-92-test SPEC_DIR_REL=docs/specs/92-test \
  bash -c 'source /tmp/brp_post.sh; build_reviewer_prompt 1 "(none)" | wc -c'
# => 2863
```

### 4. スモークテスト（NFR 3.1）

```bash
mkdir -p /tmp/dry-run-test && cd /tmp/dry-run-test && git init -q -b main && \
  git -c user.email=test@example.com -c user.name=test commit --allow-empty -q -m init
REPO=owner/nonexistent REPO_DIR=/tmp/dry-run-test \
  $HOME/bin/issue-watcher.sh
# => exit=0（既存挙動を変更していない）
```

### 5. 既存テスト

本リポジトリには unit test フレームワークが存在しないため、`bash -n` + `shellcheck` +
prompt サイズ測定 + dry-run スモークテストで代替。CLAUDE.md「テスト・検証」節の方針に従う。

## AC 対応マッピング

| AC | 担保方法 | 検証 |
|---|---|---|
| Req 1.1 (no inline diff full text) | `build_reviewer_prompt` から `## 最新差分（${BASE_BRANCH}..HEAD）` 節と diff コードブロックを削除 | prompt 内 ` ```diff ` の出現 0 件 / `## 最新差分` 出現 0 件を grep で確認 |
| Req 1.2 (prompt < 131,072B) | 差分本文を埋め込まず固定テキストのみ生成 | `wc -c` で 2,863B (large diff) / 2,976B (small diff) を確認 |
| Req 1.3 (空差分 fallback テキスト残置なし) | `diff_content` 変数と fallback 分岐そのものを削除 | prompt 内「差分が取得できませんでした」の出現 0 件を grep で確認 |
| Req 1.4 (identifier 維持) | `BASE_BRANCH` を 1 行追加、`HEAD commit` / `BRANCH` は維持 | prompt 内に `BRANCH:` / `HEAD commit:` / `BASE_BRANCH:` の 3 行が存在することを grep で確認 |
| Req 2.1 (`git diff --stat` 指示) | 「差分の取得」節に `git diff --stat ${BASE_BRANCH}..HEAD` を提示 | grep -c で 1 件 |
| Req 2.2 (ファイル単位 `git diff -- <path>` 指示) | 同節に `git diff ${BASE_BRANCH}..HEAD -- <path>` を提示 | grep -c で 1 件 |
| Req 2.3 (BASE_BRANCH 実値を埋め込み) | heredoc 展開で `${BASE_BRANCH}` が `main` 等に置換される | prompt 内に `git diff --stat main..HEAD` が文字列として出現することを確認 |
| Req 3.1 (RESULT contract) | 「最終行は `RESULT: approve` または `RESULT: reject`」の指示を維持 | grep -c で 1 件 |
| Req 3.2 (3 カテゴリ判定) | 「AC 未カバー / missing test / boundary 逸脱」記述を維持 | grep -c で 1 件 |
| Req 3.3 (round 上限) | `round=${round} / 最大 2 round` を冒頭に維持 | prompt 内に `ROUND : 1` 行存在を確認 |
| Req 3.4 (PREV_RESULT) | `PREV_RESULT : ${prev_result}` 行を維持 | prompt 内に `PREV_RESULT : (none)` 行を確認 |
| Req 3.5 (制約 3 種) | spec 書き換え禁止 / `git add/commit/push/gh` 禁止 / style reject 禁止の 3 行を維持 | grep -c でそれぞれ 1 件 |
| Req 4.1 (env var 名・既定値変更なし) | env var 参照箇所を一切変更していない | コードレビューで確認 |
| Req 4.2 (ラベル名・タイミング変更なし) | label 操作箇所には触れていない | コードレビューで確認 |
| Req 4.3 (exit code 変更なし) | exit code 関係には触れていない | dry-run で exit=0 を確認 |
| Req 4.4 (差し戻しループ上限変更なし) | round 制御ロジック・呼び出し側には触れていない | コードレビューで確認 |
| Req 4.5 (cron 登録文字列変更なし) | install/setup スクリプトには触れていない | git diff で対象範囲を確認 |
| NFR 1.1 (prompt < 131,072B) | Req 1.2 と同一 | 2,863B / 2,976B を測定 |
| NFR 1.2 (差分内容に依存しない数 KB) | 差分本文を埋め込まない設計 | 0B diff と 87KB diff の双方で 〜3KB |
| NFR 2.1 (shellcheck 新規警告 0) | 変更箇所のコード品質確認 | shellcheck で本変更由来の警告なしを確認 |
| NFR 3.1 (no-target 正常終了) | 既存挙動に手を入れていない | dry-run で exit=0 を確認 |
| NFR 3.2 (差分空でも reviewer 起動可) | reviewer 自身が `git diff` を取得する設計で、差分空でも prompt 生成・起動は可能 | prompt 生成が常に成功すること（fallback 不要）を確認 |
| NFR 4.1 (self-hosting 適合) | idd-claude 自身のテンプレートも同期更新（`repo-template/` / root の `.claude/agents/reviewer.md`） | reviewer.md の 2 行修正を実施 |

## 確認事項

- なし。

  ただし参考までに、`build_reviewer_prompt` 修正後の prompt は **reviewer サブエージェント側で
  `git diff` を Bash 経由で取得する責務になる** ため、reviewer の turn 数バジェット
  （`REVIEWER_MAX_TURNS`）に余裕があることが前提となる。現行の既定値で問題ないと判断したが、
  運用で turn 不足が観測されたら別 Issue で `REVIEWER_MAX_TURNS` 既定の増加を検討する余地が
  ある（本 PR の AC には含まれない）。
