# Implementation Notes — Issue #270

## 概要

per-task ループ内の「親タスク完了マーク commit のみ（`tasks.md` 1 行 checkbox flip）」に対する
Reviewer 起動を `pt_should_skip_reviewer` 判定で抑止し、`parse-failed` → `claude-failed` を
回避する。LLM 呼び出し削減によるトークン節約と実行時間短縮も得られる。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`
  - 追加関数:
    - `pt_has_subtasks <tasks_md> <task_id>` — 子タスク存在判定（Req 2.1, 2.4, 2.5）
    - `pt_is_parent_checkbox_only_diff <task_id> <range_start> <range_end>` — diff range 内容判定（Req 3.1, 3.2, 3.4, 3.5）
    - `pt_should_skip_reviewer <task_id>` — dispatcher（Req 1.1〜1.4）
  - 修正箇所:
    - `run_per_task_loop` 内の round=1 Reviewer 起動直前で `pt_should_skip_reviewer` を呼び、
      スキップ成立時は `rev_rc=0` 設定で即時 approve 扱いとし `run_per_task_reviewer` を起動しない
- `docs/specs/270--bug-checkbox-flip-per-task-reviewer/test-fixtures/`
  - `tasks-parent-with-children.md` — 固定 fixture
  - `test-skip-logic.sh` — 判定ヘルパー 3 関数を bash subshell で直接呼ぶスモークテスト（23 ケース全 PASS）

## 設計判断

### スキップ適用範囲は round=1 のみ

要件本文の AC 1.1 が「per-task ループが次に処理する task が...」と表現していることから、
スキップの対象は初回 Reviewer 起動（round=1）のみと解釈した。round=2 / round=3 は
Reviewer による reject が発生した後の reviewer 再起動であり、本来「親タスクの checkbox flip
のみ」のシチュエーションには到達しない（一度 approve 扱いされた task は次 task へ進む）。
よって round=2 / round=3 経路は変更不要。

### dispatcher のシグナル化（return 0 = skip, return 1 = run）

`pt_should_skip_reviewer` は判定 dispatcher としてシンプルに「スキップしてよいか」だけを
return 値で表現する。これにより呼び出し側の `if pt_should_skip_reviewer ...; then rev_rc=0;
else run_per_task_reviewer ... || rev_rc=$?; fi` という 4 行で意図を明示できる。

### tasks.md only diff の判定アルゴリズム

`git diff --name-only <range>` で変更ファイル集合を取り、ちょうど 1 件 + 一致が
`SPEC_DIR_REL/tasks.md` であることを必要条件とした。続けて `git diff <range> -- <tasks_md>`
の hunk 内 `-`/`+` 行数をそれぞれ厳密に 1 件に限定した上で、当該 task_id の checkbox flip
パターン (`^-- \[ \] <id>(\.)? ` / `^\+- \[x\] <id>(\.)? `) との完全一致を求めることで、
他編集が混入する場合を全て不成立に倒せる（Req 3.4, 3.5）。

### diff header の除外

git diff の出力では、削除行の中身が markdown list `- [ ]` で始まる場合、行頭が `--` 2 文字に
なる（diff marker `-` + 内容 `-`）。当初は `^-[^-]` で diff file header `--- a/path` を除外
しようとしたが、これだと markdown 削除行も誤って除外されることが smoke test (B-1 / C-1) で
判明したため、`grep -E '^-' | grep -cvE '^--- '` のように 2 段階で file header のみを
明示除外する形に修正した。

### fail-safe 経路（NFR 1.3）

以下のいずれかで `pt_should_skip_reviewer` は 1（= skip しない）を返し、従来 Reviewer 起動
経路へ倒す:

- `pt_has_subtasks` が rc=1（子なし）または rc=2（tasks.md 不在 / 空 task_id）
- `pt_resolve_diff_range` が失敗（marker commit 不在）
- `pt_is_parent_checkbox_only_diff` が rc=1（任意の不一致条件）

これにより異常系では既存挙動（claude-failed まで含む）が温存される。

### ログ書式（NFR 2.1, NFR 2.3）

スキップ成立時のみ `pt_log "task=<id> reviewer skipped reason=parent-task-checkbox-only-diff
range=<short_sha>..<short_sha>"` を出力。`grep "reviewer skipped"` で件数把握可能。
スキップ不成立時は新規ログを増やさない（既存ログ量を増やさない後方互換）。

## テスト結果

### スモークテスト（自作）

```
$ bash docs/specs/270--bug-checkbox-flip-per-task-reviewer/test-fixtures/test-skip-logic.sh
Results: PASS=23 FAIL=0
```

検証ケース内訳:

- **A. pt_has_subtasks**（9 ケース）: 親 / 子 / 末端 / deferrable 子 / 完了済み親 /
  不在 task_id / file 不在 / 空 task_id / false positive（task_id `1` が `11.` を誤検出しない）
- **B. pt_is_parent_checkbox_only_diff**（7 ケース）: checkbox flip のみ成立 / 範囲不正 /
  別 task_id 誤マッチしない / 他ファイル混入 / tasks.md 内別 task の flip 混入 / 空 diff
- **C. pt_should_skip_reviewer (E2E)**（7 ケース）: 親 task の checkbox-only / 子 task /
  単独 task / 存在しない task_id / ログ出力検証（成立時に grep 可能）/ ログ抑止検証（不成立時に新規ログなし）

### shellcheck

```
$ shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh
（出力なし = 警告ゼロ）
$ shellcheck docs/specs/270--bug-checkbox-flip-per-task-reviewer/test-fixtures/test-skip-logic.sh
（出力なし = 警告ゼロ）
```

### 構文チェック

```
$ bash -n local-watcher/bin/issue-watcher.sh
syntax OK
```

## 受入基準とテストの紐付け

| Req ID | 担保テスト |
|---|---|
| 1.1 | C-1, C-2, C-3, C-4（親かつ checkbox-only のみ skip 成立） |
| 1.2 | C-1（dispatcher が rc=0 を返す = approve 扱い） |
| 1.3 | C-5（fail-safe 経路で skip しない / claude-failed 化を防ぐため通常経路へ） |
| 1.4 | C-6（スキップ成立時の単一行 grep 可能ログ） |
| 1.5 | dispatcher の戻り値 contract により後続 task 処理は通常通り継続（コード上明らか） |
| 1.6 | Stage A 完了後の遷移は本変更で触っていない（rev_rc=0 経路は既存の approve 経路と同一） |
| 2.1 | A-1, A-2, A-3, A-4（子タスク存在判定の挙動検証） |
| 2.2 | A-3, A-5（子なし / 存在しない task_id では rc=1） |
| 2.3 | A-4（子タスク自体は子を持たないので rc=1） |
| 2.4 | A-9（完了済み子タスクでも親判定成立） |
| 2.5 | A-2（deferrable `- [ ]*` 子タスクも判定成立） |
| 3.1 | B-1（成立条件のうち変更ファイル集合判定） |
| 3.2 | B-5（tasks.md 以外混入で不成立） |
| 3.3 | C-5（diff range 解決失敗時は skip 判定せず従来経路） |
| 3.4 | B-1（checkbox flip ペアで成立） |
| 3.5 | B-6（tasks.md 内に他 task の flip 混入で不成立） |
| 4.1 | C-2, C-3（子タスクは従来通り Reviewer 起動） |
| 4.2 | C-4（単独タスクは従来通り Reviewer 起動） |
| 4.3 | B-5（親タスクだが他ファイル変更ありで従来通り Reviewer 起動） |
| 4.4 | round=2 / round=3 経路を一切変更していないため等価性は構造的に保証 |
| 4.5 | 既存テスト範囲外（ベースライン挙動と等価。retrofit は本 spec のスコープ外） |
| NFR 1.1 | 既定で有効（追加 env var なし）= dispatcher 直接呼び出しで動作 |
| NFR 1.2 | 既存進捗（`- [x]` / 既存 marker commit）と互換（既存 marker commit を読み取るのみ） |
| NFR 1.3 | A-6, A-7, C-5（fail-safe 経路の検証） |
| NFR 2.1 | C-6（grep 可能ログ） |
| NFR 2.2 | C-6（task ID と判定経路識別子を含む） |
| NFR 2.3 | C-7（スキップ不成立時に新規ログ増えない） |
| NFR 3.1 | git diff / grep のみで構成された軽量判定。Reviewer 1 回（数十秒〜数分）と比べ無視可能 |
| NFR 3.2 | スキップ成立時は `claude --print` 起動を完全に bypass（コード上明らか） |

## 確認事項

- 本機能はランタイム判定のみで、tasks.md / requirements.md / design.md / 既存 spec の
  retrofit は行っていない（Out of Scope 規定どおり）
- round=2 / round=3 Reviewer 起動経路は本変更の対象外（要件 1.1 が「次に処理する task」と
  規定しているため round=1 のみが該当する）
- `pt_should_skip_reviewer` の戻り値 1（= skip しない）は「fail-safe / 通常タスク」両方を
  包含する。呼び出し側はこれを区別する必要がないため統合した
- スモークテストは bash subshell で関数定義のみを抽出して実行する方式を採った（issue-watcher.sh
  全体を source すると watcher の main 処理が走り副作用が大きいため）。CI 統合は本 PR の
  スコープ外（local-watcher 配下のテスト戦略は手動スモーク中心 / CLAUDE.md「テスト・検証」節）

STATUS: complete
