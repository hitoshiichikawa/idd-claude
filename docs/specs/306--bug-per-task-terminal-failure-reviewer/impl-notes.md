# Implementation Notes — Issue #306

## 採用方針

Issue 本文で提示された **案 3（commit を試み、失敗時はコメント埋め込み fallback）** を採用。

per-task ループの terminal failure 経路（`per-task-reviewer-reject2` /
`per-task-reviewer-reject3` / `per-task-reviewer-error` /
`per-task-reviewer-missing-file` / `debugger-notes-invalid`）で `mark_issue_failed` を
呼ぶ直前に経由する新規ヘルパー **`publish_terminal_failure_artifacts`** を導入した。
ヘルパーは `mark_issue_failed` を呼ぶ責務を内部で完遂し、call site は関数名差し替えのみで
artifact 保全と push state 可視化を得られる。

## 主要関数

### `publish_terminal_failure_artifacts <stage> <extra_body>`

`local-watcher/bin/issue-watcher.sh` の `verify_pushed_or_retry` の **直前** に追加。

責務:

1. **Push state 収集**（Req 2.1, 2.3, 2.4）:
   - `git rev-parse HEAD` で local HEAD SHA
   - `git ls-remote origin refs/heads/<branch>` で origin HEAD SHA。
     取得失敗時は「未 push」を埋める（Req 2.3）
   - ahead count = `git rev-list --count <origin_head>..HEAD`
     （初回 push 前は `${BASE_BRANCH:-main}..HEAD` から算出）
   - branch 名 / worktree path は環境変数 `BRANCH` / `REPO_DIR` から取得
2. **Artifact 単位の状態判定**（Req 1.2, 2.2）: `review-notes.md` /
   `debugger-notes.md` それぞれについて、内部関数 `_ptfa_artifact_status` が以下の
   status を返す:
   - `absent`（ファイルが存在しない）
   - `untracked`（ファイルはあるが `git ls-files` 未 track）
   - `modified`（tracked だが unstaged / staged な変更が残る）
   - `tracked-unpushed`（commit 済みだが当該ファイルが origin に未反映）
   - `tracked-pushed`（commit 済みかつ origin に反映済み）
3. **Diagnostic commit 試行**（Req 1.1, 1.3）: いずれかの artifact が
   `untracked` / `modified` / `tracked-unpushed` だった場合、
   `docs(spec): preserve terminal-failure diagnostics (#<num> / stage=<stage>)` で
   commit して `git push origin <branch>` を実行する。成功時は artifact_status を
   `committed` で上書きし、push 後の最新 local/origin HEAD で push state 欄を更新する
4. **Fallback 埋め込み**（Req 1.4, NFR 3.1）: commit / push が失敗した場合、
   artifact 本文を Issue コメント本文に埋め込む。本文長が **16384 文字** を超える場合は
   先頭 80 行 + 末尾 80 行 + `(中略 / 全文 N 文字)` の抜粋に切り替える
   （GitHub Issue コメント 65,536 文字制限の余裕保守値）
5. **`mark_issue_failed` を必ず呼ぶ**（Req 1.5, NFR 2.1）: 上記いずれの段階で例外が
   起きても、最後に必ず `mark_issue_failed` を呼んで `claude-failed` ラベル付与を完遂する

設計上の判断:

- **既存 `verify_pushed_or_retry` には触らない**（Req 4.3 / NFR 1.1）。同関数は ahead 数
  verify + 自動 push リトライに責務を絞っており、artifact の commit / 本文埋め込みまで
  扱わない。本機能は新規ヘルパーとして導入し、`verify_pushed_or_retry` の意味論は不変
- **`git reset` / `git rebase` / force push は使わない**（Req 3.4）。`git add` →
  `git commit` → `git push origin <branch>` のみ
- **Reviewer / Debugger サブエージェントへの git / gh 権限付与なし**（Req 3.1, 3.2, 3.3）。
  watcher の return 後に artifact 保全の責務を担う
- **`command -v timeout` で GNU coreutils の有無を判定**（既存
  `verify_pushed_or_retry` と同方針 / 既存 cron 互換性のため）

### 既存 helper との関係

- `mark_issue_failed`（既存）: そのまま残置し、内部から呼ばれる
- `verify_pushed_or_retry`（既存）: 触らず（Req 4.3 / NFR 1.1）
- `pt_mark_diff_range_resolve_failed`（既存）: 触らず（Issue #164 専用復旧手順を持つ
  別経路。本機能の対象 5 経路には含まれない）

## 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | `publish_terminal_failure_artifacts` 新規追加（約 250 行）。9 箇所の per-task terminal failure 経路（reject2 / reject3 / round=1,2,3 reviewer-error / round=1,2,3 reviewer-missing-file / debugger-notes-invalid）の `mark_issue_failed` 呼出を新ヘルパー呼出に差し替え |
| `local-watcher/test/publish_terminal_failure_artifacts_test.sh` | 新規回帰テスト（6 ケース / 29 アサーション）。ローカル bare repo を fake origin として、Req 1.1〜1.5 / 2.1〜2.4 / NFR 2.1 / NFR 3.1 を end-to-end 検証 |

## テスト戦略

- **既存 `verify_pushed_or_retry_test.sh` を踏襲**: bash の `awk` で関数定義のみを
  抽出して current shell に load する extract_function パターンを採用
- **mock 戦略**: `mark_issue_failed` を fake 関数で差し替え、call count / 引数を観測する
- **fake origin**: `git init --bare` で作る一時 bare repo を origin として `git push`
  を実行
- **push 失敗シナリオ**: `chmod -R 000 <bare>/refs` で書き込み権限を奪う既存パターン
- **長文シナリオ**: 600 行 + tail marker を含むファイルで `(中略` の存在と末尾 marker
  の埋め込みを確認

### 検証カバレッジ（Req → テストケース）

| Requirement | 担保するテストケース |
|---|---|
| Req 1.1（artifact 保全 / コメント埋め込み or diagnostic commit push） | Case 1（commit push）, Case 3（fallback 埋め込み） |
| Req 1.2（既に tracked + pushed なら重複保全しない） | Case 2 |
| Req 1.3（untracked / 未 commit を保全） | Case 1, Case 3 |
| Req 1.4（commit push 失敗時の fallback 埋め込み） | Case 3 |
| Req 1.5（保全失敗でも `claude-failed` 完遂） | Case 1〜6 全てで `mark_issue_failed` 呼出を assert |
| Req 2.1（branch / local HEAD / origin HEAD / ahead / worktree path） | Case 1 |
| Req 2.2（artifact 単位の状態明示） | Case 1, Case 2 |
| Req 2.3（origin branch 不在時の「未 push」固定表記） | Case 4 |
| Req 2.4（カテゴリ間の一貫フォーマット） | Case 1 / 2 / 3 / 4 / 5 / 6 で同じ block を確認 |
| Req 3.1〜3.4（Reviewer / Debugger 権限境界） | コード上で `git add` / `git commit` / `git push` が watcher 側のみで実行されることを実装で担保。`.claude/agents/*.md` には変更を加えない |
| Req 4.1〜4.3（既存経路との一貫性） | `verify_pushed_or_retry_test.sh`（既存）が引き続き pass することを確認 |
| Req 5.1〜5.3（回帰テストによる挙動固定） | `publish_terminal_failure_artifacts_test.sh` 全 6 ケース |
| NFR 1.1（後方互換） | `verify_pushed_or_retry_test.sh`（既存）を破壊しないことを確認 |
| NFR 1.2（既存必須項目を削除しない） | Case 1 で `per-task ループの Reviewer (task=...) reject` 既存 extra_body 文言の保持を assert |
| NFR 2.1（claude-failed 完遂） | Case 1〜6 |
| NFR 2.2（grep 可能な log） | Case 1 で `terminal-failure-artifacts` log 行を assert |
| NFR 3.1（コメントサイズ上限） | Case 5（長文 → 要約モード） |

## 動作確認手順

1. **shellcheck**:
   ```bash
   shellcheck local-watcher/bin/issue-watcher.sh
   ```
   → 警告ゼロ
2. **新規回帰テスト**:
   ```bash
   bash local-watcher/test/publish_terminal_failure_artifacts_test.sh
   ```
   → `PASS: 29, FAIL: 0`
3. **既存テスト**:
   ```bash
   for t in local-watcher/test/*.sh; do bash "$t" >/dev/null 2>&1 && echo "OK: $t" || echo "FAIL: $t"; done
   ```
   → 全て OK（破壊なし）

## 受入基準ごとのテスト対応表

| AC | 担保 |
|---|---|
| 1.1 | Case 1（diagnostic commit push 経路）, Case 3（埋め込み fallback 経路） |
| 1.2 | Case 2（重複保全なし） |
| 1.3 | Case 1（untracked → commit + push）, Case 3（untracked → 本文埋め込み） |
| 1.4 | Case 3（push 失敗 → 本文 fallback 埋め込み） |
| 1.5 | Case 1〜6 全てで `mark_issue_failed` の 1 回呼出を assert |
| 2.1 | Case 1（branch / local HEAD / origin HEAD / ahead / worktree path 全てコメント本文に含まれる） |
| 2.2 | Case 1（artifact 単位の status: untracked → committed） / Case 2（tracked-pushed） |
| 2.3 | Case 4（初回 push 前で「未 push」表記 + ahead local HEAD まで） |
| 2.4 | Case 1〜6 で同一フォーマット（`### 診断 artifact / push 状態（Issue #306）`）を append |
| 3.1, 3.2 | Reviewer / Debugger エージェント定義（`.claude/agents/reviewer.md` / `.claude/agents/debugger.md`）には触れていないことで担保 |
| 3.3 | watcher 側（`publish_terminal_failure_artifacts`）が commit / push 責務を担うことで担保 |
| 3.4 | コード grep で `git reset` / `git rebase` / `--force` を `publish_terminal_failure_artifacts` 内に含まないことを確認可能 |
| 4.1 | 既存 `verify_pushed_or_retry` を変更せず（diff レベルで非干渉）、`verify_pushed_or_retry_test.sh` が引き続き pass することで担保 |
| 4.2 | 本機能は `mark_issue_failed` を「呼ぶ前に extra_body を augment する」だけのラッパー設計のため、claude-failed ラベル付与経路は既存と同一（Case 1〜6 で `mark_issue_failed` の 1 回呼出を assert） |
| 4.3 | 非 per-task terminal failure 経路（Stage A / Stage B / Stage C / design / triage）は `mark_issue_failed` 直接呼出のままで本機能の影響を受けない（diff 上でこれら経路の `mark_issue_failed` 呼出が変更されていないことを差分で確認） |
| 5.1 | Case 1（review-notes.md / debugger-notes.md 両方を untracked にしてシナリオ再現） |
| 5.2 | Case 1（diagnostic commit push 成功を bare repo に commit 数 2 で確認）／ Case 3（本文 marker `EMBED-MARKER-CASE3-CONTENT-XYZ` の埋め込みを確認） |
| 5.3 | Case 1（branch / local HEAD ラベル / origin HEAD ラベル / ahead count ラベル / worktree path を全て assert） |

## 確認事項（PR 本文 / レビュワー判断ポイント）

1. **`pt_mark_diff_range_resolve_failed`（Issue #164）の per-task 失敗経路は今回の対象に
   含めなかった**（requirements の terminal failure 5 経路に列挙されていないため）。
   要件外の判断として確認していただきたい
2. **`per-task-implementer-failed` 系（claude 非 0 exit / no-progress / debugger-blocked-but-invoked
   / blocked-redo-failed / redo-failed / pp-failed / max-tasks-exceeded）も対象外**とした。
   これらは Reviewer / Debugger が `review-notes.md` / `debugger-notes.md` を書き出す **前**
   の段階での失敗であり、Req 1.1 の「Reviewer または Debugger が ... を書き出した後の
   terminal failure」に該当しないため。要件解釈の妥当性を確認していただきたい
3. **diagnostic commit のメッセージ規約**: `docs(spec): preserve terminal-failure
   diagnostics (#<num> / stage=<stage>)` という Conventional Commits 準拠の subject を
   採用したが、別 scope（例: `chore(watcher):` / `docs(watcher):`）が望ましい場合は
   レビューで指摘されたい
4. **要約モードの行数**: 先頭 80 行 + 末尾 80 行 + `(中略 / 全文 N 文字)` という固定で
   実装した。多くの review-notes.md / debugger-notes.md でこの行数で十分と判断したが、
   別の比率（例: 100 行 + 100 行 / 60 行 + 60 行）が好まれる場合は指摘されたい
5. **`origin HEAD: 未 push` の固定表記**: 日本語表記を採用したが、英語固定表記が
   望まれる場合は `origin HEAD: (not pushed yet)` 等に変更可能

## 確認した規約整合

- `.claude/agents/*.md` / `.claude/rules/*.md` は変更なし（Req 3.1, 3.2 の権限境界維持
  と CLAUDE.md「root と repo-template の二重管理」規約を両立）
- `diff -r .claude/agents repo-template/.claude/agents` および
  `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認済み
- bash 規約: `set -euo pipefail` / `"$var"` クォート / `command -v` / `$HOME` 不使用
  （本ヘルパーは `$HOME` を参照しない）/ silent fail を作らない（NFR 2.1, 2.2）

STATUS: complete
