# 実装ノート: #97 PR Iteration prompt の E2BIG 修正

- Issue: [#97](https://github.com/hitoshiichikawa/idd-claude/issues/97)
- 関連 Issue: [#92](https://github.com/hitoshiichikawa/idd-claude/issues/92)（Reviewer 側で先行修正、コミット `6e73820`）
- ブランチ: `claude/issue-97-impl-watcher-pi-build-iteration-prompt-fails`
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節なし → opt-out として通常フロー（単一実装パス）で実装

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`（`pi_build_iteration_prompt` 関数の本体修正）
- `local-watcher/bin/iteration-prompt.tmpl`（impl 用 template から `{{PR_DIFF}}` を撤廃し、Iteration サブエージェントが自身で差分取得する手順を提示）
- `local-watcher/bin/iteration-prompt-design.tmpl`（design 用 template も同じ方針で修正）

## 設計判断

- 先行修正（Issue #92 / コミット `6e73820`）の Reviewer prompt と方針を揃え、prompt に inline 差分を埋め込まないアプローチを採用。Iteration サブエージェントが `git diff --stat {{BASE_REF}}..{{HEAD_REF}}` 等を Bash ツールで実行する手順を template 内に明示
- watcher 側で `gh pr diff` を呼んで取得→`PI_PR_DIFF` 経由で `awk ENVIRON[]` に渡す経路を**完全削除**することで、差分サイズに依存せず prompt 全長が固定（~8 KB / ~11 KB）に収まることを担保
- Reviewer prompt は `BASE_REF` を header に追加していたが、Iteration prompt は元々 `Base  : {{BASE_REF}}` と `Head  : {{HEAD_REF}}` を header に持っていたため新規 identifier 追加は不要。差分取得手順では `{{BASE_REF}}` / `{{HEAD_REF}}` / `{{PR_NUMBER}}` / `{{REPO}}` の各実値を直接埋め込み、コピペで実行できる粒度にした
- impl 用 / design 用 template 両方に同じ「現在の diff の取得」節を追加（Req 1.5 / Req 2.4）。design 用は `{{SPEC_DIR}}` 配下を優先する旨を補足
- `pi_build_iteration_prompt` の awk 部分は `{{PR_DIFF}}` 行マッチ分岐を 1 行削除し、`PI_PR_DIFF` の export / unset を削除する最小差分（他の placeholder 展開ロジックは完全に保持）

## 受入基準（AC）トレーサビリティ

| AC ID | 実装で担保した箇所 | 検証手段 |
|---|---|---|
| 1.1 | `local-watcher/bin/issue-watcher.sh` の `pi_build_iteration_prompt` から `pr_diff` 取得（旧 1672-1674 行）と `awk` の `{{PR_DIFF}}` 分岐を削除 | smoke test: 出力に `{{PR_DIFF}}` が残らない & 出力サイズが diff サイズに非依存 |
| 1.2 | 同関数の `export PI_PR_DIFF="$pr_diff"` と `unset PI_PR_DIFF` を削除 | smoke test: 呼び出し後 `PI_PR_DIFF` が未定義 |
| 1.3 | `pr_diff` 取得処理自体を削除したことで `gh pr diff` を呼ばなくなり、後続 `claude --print` 起動経路は変わらない | コードレビュー（pi_build_iteration_prompt の戻り値経路を維持）+ smoke test の exit 0 確認 |
| 1.4 | `pr_diff` の fallback 文字列 `(diff の取得に失敗)` を含む処理を全削除 | template / 関数 grep で当該文言が残っていないことを確認 |
| 1.5 | `iteration-prompt.tmpl` と `iteration-prompt-design.tmpl` の両方から `{{PR_DIFF}}` 節を撤廃し、同等の「現在の diff の取得」節を追加 | template に対する目視 + grep で `{{PR_DIFF}}` 残置ゼロ |
| 2.1 | template の「現在の diff の取得」節に `git diff --stat {{BASE_REF}}..{{HEAD_REF}}` と `gh pr diff {{PR_NUMBER}} --repo {{REPO}}` を明示 | template diff |
| 2.2 | 同節に `git diff {{BASE_REF}}..{{HEAD_REF}} -- <path>` を明示 | template diff |
| 2.3 | `{{BASE_REF}}` / `{{HEAD_REF}}` / `{{PR_NUMBER}}` / `{{REPO}}` の placeholder を実値で埋め込んだ形でコマンド例を提示（コピペ可能） | smoke test: 例コマンドが実値展開後に `main..claude/issue-123-foo` / `gh pr diff 42 --repo owner/test` として現れる |
| 2.4 | impl / design 両 template に「現在の diff の取得」節を追加 | smoke test: 両 template について `{{PR_DIFF}}` 残置ゼロ、節タイトル「現在の diff の取得」が存在 |
| 3.1 | `pi_build_iteration_prompt` の awk `-v` 引数（repo / pr_number / pr_title / pr_url / head_ref / base_ref / round / max_rounds / issue_number / spec_dir）を変更せず保持 | smoke test: header に Repo / Number / Title / Head / Base / Iteration / Spec dir が展開済みで現れる |
| 3.2 | `{{LINE_COMMENTS_JSON}}` / `{{GENERAL_COMMENTS_JSON}}` / `{{REQUIREMENTS_MD}}` の awk ENVIRON[] 経由展開を保持 | コードレビュー（1735-1737 行に当該分岐が残っている）+ smoke test 出力で 3 つの placeholder が残っていないこと |
| 3.3 | `pi_classify_pr_kind` / `pi_select_template` / kind 分岐ロジックは未変更 | grep で確認 |
| 3.4 | `PR_ITERATION_MAX_ROUNDS` / `pi_escalate_to_failed` の参照箇所は未変更 | grep で確認 |
| 3.5 | `pi_post_processing_marker` / `pi_run_iteration` の checkout / claude 起動経路は未変更 | grep で確認 |
| 4.1 | env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_DEV_MODEL` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_GIT_TIMEOUT`）は未変更 | grep で確認 |
| 4.2 | ラベル名（`needs-iteration` / `claude-failed` 等）は未変更 | grep で確認 |
| 4.3 | exit code 戻り値（0 / 1 / 2 / 3）の意味は未変更 | コードレビュー |
| 4.4 | cron 登録文字列（README / install.sh）は touch せず | git diff で確認 |
| 4.5 | `PI_PR_DIFF` は内部実装専用だったため、削除しても外部 API 互換性に影響なし。今後外部から `PI_PR_DIFF` を設定しても挙動が変わらないことを smoke test で確認（big env を渡しても出力が変わらない） | smoke test の big env シナリオで `normal == big` |
| 5.1 | smoke test で `{{PR_DIFF}}` が出力に残らないことを確認 | smoke test 出力 |
| 5.2 | 他の placeholder（REPO / PR_NUMBER / PR_TITLE / PR_URL / HEAD_REF / BASE_REF / ROUND / MAX_ROUNDS / ISSUE_NUMBER / SPEC_DIR / LINE_COMMENTS_JSON / GENERAL_COMMENTS_JSON / REQUIREMENTS_MD）の展開を smoke test で確認 | smoke test |
| 5.3 | impl / design 両 template から `{{PR_DIFF}}` を一括撤廃 | template diff |
| NFR 1.1 | smoke test: impl prompt = 8027 B、design prompt = 11462 B（いずれも 131,072 B 未満） | smoke test |
| NFR 1.2 | `PI_PR_DIFF` を export しなくなったため、awk 子プロセスに渡す env var で diff 全文を保持するものは存在しない | コードレビュー（grep で `PI_PR_DIFF` がコメント以外に出現しないことを確認） |
| NFR 1.3 | 外部から `PI_PR_DIFF` に 200 KB のダミー値を設定しても出力バイト数が変わらない（normal == big） | smoke test |
| NFR 2.1 | `shellcheck local-watcher/bin/issue-watcher.sh` を実行し、本変更による新規警告ゼロ。既存の info-level 警告（SC2012 line 1664 / SC2317 等）は無関係 | shellcheck 出力 |
| NFR 3.1 | smoke test setup で `REPO=owner/test REPO_DIR=/tmp/iw97-test/repo` 状態の dry run 経路を確認（`pi_build_iteration_prompt` 単体は処理対象 0 件状態に到達する前段なのでスコープ外、watcher 全体の dry run は手動スモーク観点を阻害しないため省略） | コードレビュー |
| NFR 3.2 | `awk` の env var 値長が 131 KB 未満（最大値: line/general/requirements JSON のいずれも実運用で数十 KB 程度に収まる） | コードレビュー + smoke test |
| NFR 4.1 | self-hosting で本変更を idd-claude 自身に流しても prompt サイズは固定 | コードレビュー（差分サイズ非依存性は smoke test で実証） |

## 検証結果

### 静的解析

```bash
shellcheck local-watcher/bin/issue-watcher.sh
```

→ 新規警告ゼロ。既存の info-level 警告（line 302 / 904 / 1050 / 1051 / 1052 / 1664 / 2017 / 2299 / 3933 / 4335）はいずれも本 PR で触れていない箇所。

### スモークテスト

`/tmp/iw97-test/run.sh` を作成し、`pi_build_iteration_prompt` を bash 経由で抽出して呼び出すハーネスを用意。impl / design 両 template で以下を検証:

1. **prompt に `{{PR_DIFF}}` が残らない**: 両 template で OK
2. **呼び出し後 `PI_PR_DIFF` 環境変数が未定義**: impl 呼び出し後 `set` でも当該変数が現れず OK
3. **外部から `PI_PR_DIFF` に 200 KB の値を渡しても出力バイト数が変わらない**: normal=8027, big=8027 で完全一致 → 差分サイズ非依存性が成立
4. **他 placeholder が引き続き展開される**: `Repo  : owner/test` / `Number: #42` / `Title : test PR` / `Head  : claude/issue-123-foo` / `Base  : main` / `Iteration: round 1 / 5` / `docs/specs/123-test` / `main..claude/issue-123-foo` / `gh pr diff 42 --repo owner/test` がいずれも出力に現れる

```text
=== impl template ===
8027
OK: impl prompt rendered without {{PR_DIFF}} and PI_PR_DIFF not exported
=== design template ===
11462
OK: design prompt rendered without {{PR_DIFF}}
=== huge fake env to simulate previous E2BIG scenario (>200KB) ===
normal=8027 big=8027
OK: output size is independent of external PI_PR_DIFF value
=== check other placeholders are still expanded ===
OK: identifiers/refs preserved
=== ALL SMOKE TESTS PASSED ===
```

### 後方互換性チェック

- env var 名: `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_DEV_MODEL` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_GIT_TIMEOUT` いずれも未変更
- ラベル名: `needs-iteration` / `claude-failed` / `ready-for-review` / `awaiting-design-review` いずれも未変更
- cron 登録文字列: `install.sh` / `setup.sh` / `README.md` 触れず
- exit code: `pi_run_iteration` の 0/1/2/3 戻り値の意味は未変更
- `pi_build_iteration_prompt` の I/F（引数 4 個、stdout に prompt）は未変更
- `PI_PR_DIFF` は内部実装専用変数だったので削除しても外部影響なし（要件 4.5）。今後外部から設定しても挙動が変わらないことは smoke test で確認済み

### 観測されたプロンプトサイズ（参考）

| Template | Before（diff 0 KB） | Before（diff 715 KB 想定） | After |
|---|---|---|---|
| `iteration-prompt.tmpl` | 約 7-8 KB | **約 720+ KB（E2BIG）** | 8027 B（固定） |
| `iteration-prompt-design.tmpl` | 約 10-11 KB | **約 720+ KB（E2BIG）** | 11462 B（固定） |

## 確認事項

- なし。要件 5「テンプレート整合性」は smoke test で網羅できており、Reviewer 側修正（#92）との一貫性も確認済み。
- `repo-template/**` 配下には iteration-prompt template は存在しないため、consumer repo への配布物への影響はなし（`local-watcher/bin/*.tmpl` のみが影響範囲）。
