# 実装ノート (#89: BASE_BRANCH env で gitflow 運用に対応)

## 各タスクで行った主要変更の要点

### Task 1.1 — Config block + chained default + 起動 log

- `local-watcher/bin/issue-watcher.sh` に `BASE_BRANCH="${BASE_BRANCH:-main}"` を導入（`MERGE_QUEUE_BASE_BRANCH` 行直前）
- `MERGE_QUEUE_BASE_BRANCH` を `"${MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}}"` に変更（連鎖 default、env var 名は不変）
- `mkdir -p "$LOG_DIR"` 直後に `base-branch=... merge-queue-base=...` の log 1 行を追加（NFR 4.1）
- 既定値 `main` で本機能導入前と完全に同じ Config 解決（NFR 1.1）

### Task 1.2 — git 操作 G1-G4 の `main` リテラル置換

- G1（repo update L261-262）: `git checkout/pull main` → `"$BASE_BRANCH"`
- G2（worktree add/reset L3666, L3691、log L3670/L4243/エラーメッセージ）: `origin/main` → `origin/${BASE_BRANCH}`
- G3（branch 派生 L4017, L4043, L4441）: `origin/main` → `origin/${BASE_BRANCH}`、L4048 `resume-mode=fresh-from-main` → `resume-mode=fresh-from-base branch=$BRANCH base=$BASE_BRANCH`
- G4（safety-net checkout L1811, L1850, L1972, L1979）: `git checkout main` → `git checkout "$BASE_BRANCH"`
- L686/L717/L869 の `${MERGE_QUEUE_BASE_BRANCH}` 参照箇所はコード変更不要（連鎖 default で同値解決）。ただし周辺コメント中の "main 以外" / "main に戻す" を「base ブランチ」表記に一般化
- Merge Queue の conflict status コメント本文中の `main との merge` を `${MERGE_QUEUE_BASE_BRANCH} との merge` に変更（PR コメント内容も merge queue base を反映する）

### Task 1.3 — Stage A/A'/B/C heredoc の `${BASE_BRANCH}` 展開

- Stage A（L2570 / L2657 / L2666）: 「`main` に merge 済み」/ 「`main` から派生」/ 「`main` に直接 push しない」を `${BASE_BRANCH}` 展開で動的化
- Stage A' redo（L2716）: 同上
- Stage B Reviewer build（L2731 / L2733 / L2766）: `git diff main..HEAD` → `git diff "${BASE_BRANCH}..HEAD"`、`Compared to: main..HEAD` → `Compared to: ${BASE_BRANCH}..HEAD`
- Stage C PjM build（L2795 / L2830）: `直近の main 上の merge commit` → `直近の ${BASE_BRANCH} 上の merge commit`、「`main` に直接 push しない」を `${BASE_BRANCH}` 展開
- Slot Runner design 経路の prompt（L4488 / L4497）: 同様に `${BASE_BRANCH}` 展開
- impl-resume の `resume_section` 内 (`origin/main` から fresh init / `git log --oneline main..HEAD`) も展開化
- `BASE_BRANCH=main`（既定）時には backtick / 修飾を加えずに、本機能導入前と **byte-equivalent** な prompt 文面が生成されることを `git diff` で確認（NFR 1.1）

### Task 2.1〜2.3 — Agent template (`repo-template/.claude/agents/*.md`) の C2 ハイブリッド一般化

- `project-manager.md`: `base: \`main\`` → `base: \`<BASE_BRANCH>\`` + 補足注記、「`main` への直接 push」→「base ブランチ（既定 `main`）への直接 push」
- `reviewer.md`: `git diff main..HEAD` / `git log --oneline main..HEAD` / `Compared to: main..HEAD` を `<BASE_BRANCH>..HEAD` 形式へ、入力契約節に `<BASE_BRANCH>` の解説を 1 段落追加。「flag 分岐なしで直接 main path に注入」→「実行パスに注入」（比喩用法の誤読回避）
- `developer.md`: 「main に載っている前提」→「base ブランチ（idd-claude が解決した `<BASE_BRANCH>`、既定 `main`）に merge 済み前提」、`git diff main..HEAD` / `git log --oneline main..HEAD` を `<BASE_BRANCH>..HEAD` 形式へ、禁止事項を「base ブランチ（既定 `main`）への直接 push」へ

### Task 3.1〜3.2 — Workflow YAML

- `repo-template/.github/workflows/issue-to-pr.yml` と `.github/workflows/issue-to-pr.yml`（root）の両方に同一変更:
  - `jobs.claude-team-dev.env.BASE_BRANCH: ${{ vars.IDD_CLAUDE_BASE_BRANCH || 'main' }}` を新設
  - `Checkout main`（`ref: main`）→ `Checkout base branch`（`ref: ${{ env.BASE_BRANCH }}`）
  - `Create working branch from main` → `Create working branch from base`（branch 作成は HEAD = base ブランチ先端から `-B` で派生するため、内部 git 操作は変更不要）
  - 2 つの prompt heredoc（impl-resume mode + initial mode）の `main から派生` / `main に直接 push しないこと` を `${{ env.BASE_BRANCH }}` 展開化
  - ファイル冒頭ヘッダコメントに「Base branch の切替」節を追加（README へリンク）
- `IDD_CLAUDE_USE_ACTIONS` opt-in gate は変更しない（Req 3.4）

### Task 4.1 — CLAUDE.md 文言一般化

- root + repo-template の両 CLAUDE.md で「`main` ブランチへの直接 push」を「base ブランチ（既定 `main`、`BASE_BRANCH` 設定によっては `develop` 等）への直接 push」に変更
- `repo-template/CLAUDE.md` L135 `origin/main 起点で fresh init + force-push` を `origin/<BASE_BRANCH>（未指定時は main）起点で fresh init + force-push` に変更
- Feature Flag Protocol 節の「main にマージ」（一般慣用語の用法）はそのまま温存

### Task 4.2 — README migration note

- `## ブランチ運用と BASE_BRANCH` 節を `## セットアップ` と `## 使い方` の間に新設
- 既存「Actions repository variables」表に `IDD_CLAUDE_BASE_BRANCH` 行追加
- 含めた項目: 役割 / 既定値 / 設定方法（cron / launchd / Actions） / 4 ステップ gitflow 移行手順 / 連鎖 default truth table（5 行） / dogfood 確認手順 / 訳語選定 / consumer repo 後方互換 guarantee
- self-hosting 用 `develop` ブランチの自動作成は本 PR では対象外、`setup.sh` 自動化は別 Issue 化候補と明記

## Static Analysis 結果

### shellcheck

```
$ shellcheck local-watcher/bin/issue-watcher.sh
（58 行の info-level 出力のみ。SC2012 / SC2317 のみで本変更導入前と同件数。新規 warning なし）
```

すべて pre-existing の info-level（`ls` 推奨 vs `find`、`unreachable command` 誤検知）。本 PR で
新規発生した warning はありません。

### actionlint

`actionlint v1.7.12` を `go install github.com/rhysd/actionlint/cmd/actionlint@latest` で取得し
両 workflow に対して実行:

```
$ ~/go/bin/actionlint repo-template/.github/workflows/issue-to-pr.yml
$ ~/go/bin/actionlint .github/workflows/issue-to-pr.yml
（ともに同じ 2 件の pre-existing warning が出る）
- shellcheck SC2012（`ls` 推奨 vs `find`）at "Detect mode and slug" step
- "github.event.issue.title" untrusted-expression at "Detect mode and slug" step
```

両 warning とも本 PR 導入前から存在した（`git stash` で baseline 比較済）。新規 warning なし。
SC2012 / untrusted-expression の解消は scope 外（本 Issue 範囲ではないので未対応）。

### bash syntax check

```
$ bash -n local-watcher/bin/issue-watcher.sh
（exit 0、構文 OK）
```

### grep `\bmain\b` の残存箇所と意図

| ファイル | 行 | 内容 | 残した理由 |
|---|---:|---|---|
| `issue-watcher.sh` | 11 | impl-resume モードの説明（docs/specs/<N>-*/ が main に存在） | docstring。読者向けの慣用語的説明 |
| `issue-watcher.sh` | 72 | コメント「未設定時は "main" を採用し」 | デフォルト値の説明 |
| `issue-watcher.sh` | 75 | `BASE_BRANCH="${BASE_BRANCH:-main}"` | デフォルト値定義（必須） |
| `issue-watcher.sh` | 88 | コメント「基本は "main"。レガシー repo で master の場合等」 | `MERGE_QUEUE_BASE_BRANCH` の説明 |
| `issue-watcher.sh` | 259 | コメント「既定値（main）でも明示的に出力する」 | log 設計意図の説明 |
| `issue-watcher.sh` | 2315/2327 | コメント「main 由来 or 未 commit ファイル」 | git の "branch HEAD tracked file" 概念を表す慣用語（branch 名としての main ではない） |
| `repo-template/.claude/agents/project-manager.md` | 26/165/246 | `<BASE_BRANCH>` 補足注記 / 禁止事項の既定値表記 | 補足注記の「未指定時の既定は `main`」 |
| `repo-template/.claude/agents/reviewer.md` | 97 | 入力契約の説明 | 既定値の説明 |
| `repo-template/.claude/agents/developer.md` | 18/83/148 | 同上（前提文 / セルフチェック / 禁止事項） | 既定値の説明 |
| `.github/workflows/issue-to-pr.yml`（root + repo-template） | 36/88/90 | `vars.IDD_CLAUDE_BASE_BRANCH || 'main'` のフォールバック値 + コメント | デフォルト値定義（必須） |
| `CLAUDE.md` (root) / `repo-template/CLAUDE.md` | 各禁止事項行 | 「base ブランチ（既定 `main`...）への直接 push」 | 既定値の表記 |
| `repo-template/CLAUDE.md` | 201/207/208/218 | Feature Flag Protocol 説明節の「main にマージ」 | 「統合 branch」を指す一般慣用語（task 4.1 で温存と決定） |
| `README.md` | 各所 | raw.githubusercontent URL / `git checkout main` 例 / 環境変数表 / 新節の説明 | github raw URL は branch 固定参照、CLI 例は実演用、新節内記述は意図的 |

## Manual Smoke Tests 結果

### 1. 後方互換確認（BASE_BRANCH 未設定 + dry-run）

`bash -n` で構文 OK。さらに prompt builder を抽出して `BASE_BRANCH=main`（既定）で実行:

```bash
BASE_BRANCH=main bash 経由で build_dev_prompt_a / build_reviewer_prompt /
build_dev_prompt_c / build_dev_prompt_redo を呼び出し、prompt 全文を取得。
出力 222 行に対し、`main` リテラルが含まれる箇所は 11 箇所 — すべて
本変更導入前の prompt と byte-equivalent な位置・表記:
  - `cb（main から派生・push 済み・現在チェックアウト中）` 2 箇所
  - `- main に直接 push しないこと` 4 箇所
  - `git diff main..HEAD` / `Compared to: main..HEAD` / 設計 PR ヒント
```

watcher 自体の dry-run は本 environment（slot worktree）では cron 実行
ではなく Developer subprocess として動いており、`REPO=owner/test
REPO_DIR=/tmp/scratch $HOME/bin/issue-watcher.sh` の起動は
スコープ外（次サイクルの cron で観測するのが正しい dogfood 手順）。

### 2. 新挙動確認（BASE_BRANCH=develop で prompt build）

`BASE_BRANCH=develop` を上記スクリプトに渡して再実行:

```
出力 222 行に対し、`develop` リテラルが含まれる箇所は 11 箇所
（main 出力時の対応箇所と完全一致）。`main` 残存箇所は次の 1 箇所のみ:
  - `2. developer サブエージェントで実装＋テスト＋コミット`（`developer` という単語の
    部分一致）  — branch 名としての main ではない（false positive）
```

`BASE_BRANCH=develop` で生成される `Compared to: develop..HEAD` /
`git diff develop..HEAD` が正しく展開されることを確認。

### 3. 連鎖 default 確認（BASE_BRANCH と MERGE_QUEUE_BASE_BRANCH の resolution）

設計 truth table の 5 ケースを bash 評価で確認:

```bash
$ BASE_BRANCH= MERGE_QUEUE_BASE_BRANCH= bash -c 'A="${BASE_BRANCH:-main}"; B="${MERGE_QUEUE_BASE_BRANCH:-${A}}"; echo "BASE=$A MQ=$B"'
BASE=main MQ=main         # row 1: 既定挙動
$ BASE_BRANCH=develop MERGE_QUEUE_BASE_BRANCH= bash -c '...'
BASE=develop MQ=develop   # row 2: BASE_BRANCH のみ → MQ も追従
$ BASE_BRANCH= MERGE_QUEUE_BASE_BRANCH=master bash -c '...'
BASE=main MQ=master       # row 3: MQ 明示で BASE は既定
$ BASE_BRANCH=develop MERGE_QUEUE_BASE_BRANCH=master bash -c '...'
BASE=develop MQ=master    # row 4: 双方明示で別 base
$ BASE_BRANCH=develop MERGE_QUEUE_BASE_BRANCH=develop bash -c '...'
BASE=develop MQ=develop   # row 5: 双方同値
```

すべて design.md の Resolution Truth Table と一致。

### 4. Actions 経路確認

`actionlint` で構文チェック → 既存 warnings のみ（既述）。

`vars.IDD_CLAUDE_BASE_BRANCH` 未設定時に `'main'` フォールバックされることを
YAML 上の `${{ vars.IDD_CLAUDE_BASE_BRANCH || 'main' }}` 式で確認。

### 5. install.sh 冪等性

本 PR は `install.sh` を変更しないため、影響なし（task 5.1 の確認項目どおり）。
`./install.sh --repo /tmp/scratch` の冪等性は既存挙動を維持。

## dogfood E2E (Phase 1)

本 PR を idd-claude 自身に merge した後の cron 継続性（NFR 3.1）は **merge 後の人間観測**
に委ねます。期待される観測ポイント:

- 次 cron tick で watcher 起動 log の 1 行目に `base-branch=main merge-queue-base=main` が
  出ること（NFR 4.1）
- auto-dev Issue が従来通り `main` 起点で進み、impl PR の base が `main` になること
- `BASE_BRANCH` 未設定で従来挙動と完全に同一であること

その後の Phase 2-4（develop ブランチ作成 → cron に env 追加 → test issue で観測）は README
の手順書に従って人間が実施します。

## 確認事項

特になし — design.md / tasks.md の指示通りに実装でき、矛盾や疑問は発生しませんでした。

## 受入基準カバレッジ

| Requirement | カバー方法 |
|---|---|
| 1.1 | task 1.1 + 1.2 + 1.3（Config 解決 + git 操作 + prompt 全展開）。dry-run smoke test #2 で develop 値を確認 |
| 1.2 | task 1.1（`${BASE_BRANCH:-main}` の bash 既定値展開）。smoke test #1 で main 既定確認 |
| 1.3 | task 1.2（G3: `git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"`） |
| 1.4 | task 1.2（G2: `git -C "$wt" reset --hard "origin/${BASE_BRANCH}"`） |
| 1.5 | task 1.3（Reviewer build_reviewer_prompt の `git diff "${BASE_BRANCH}..HEAD"`） |
| 1.6 | task 1.2（G4: safety-net `git checkout "$BASE_BRANCH"`） |
| 1.7 | task 1.1（起動時 log の `base-branch=...` 1 行追加） |
| 2.1 | task 1.1（`MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}` 連鎖 default）。smoke test #3 row 2 で確認 |
| 2.2 | task 1.1（明示優先のロジック）。smoke test #3 row 3/4 で確認 |
| 2.3 | task 1.1（双方未設定時 `main`）。smoke test #3 row 1 で確認 |
| 2.4 | task 1.1（env var 名 `MERGE_QUEUE_BASE_BRANCH` を変更しないことを確認） |
| 3.1 | task 3.1 + 3.2（root + repo-template workflow に `env.BASE_BRANCH` 追加） |
| 3.2 | task 3.1 + 3.2（`vars.IDD_CLAUDE_BASE_BRANCH \|\| 'main'` のフォールバック） |
| 3.3 | task 3.1 + 3.2（prompt heredoc 内の `${{ env.BASE_BRANCH }}` 展開） |
| 3.4 | task 3.1 + 3.2（`if: vars.IDD_CLAUDE_USE_ACTIONS == 'true'` を変更しない） |
| 4.1 | task 1.3 + 2.1 + 2.2 + 2.3（watcher heredoc + 3 agent templates 全更新） |
| 4.2 | task 2.1（PjM の `base: <BASE_BRANCH>`） + task 1.3（PjM build_dev_prompt_c） |
| 4.3 | task 1.3（Reviewer の diff 範囲 `${BASE_BRANCH}..HEAD`） + task 2.2 / 2.3 |
| 4.4 | task 2.1 + 2.2 + 2.3（一般語化 + 補足注記による任意 base での文意整合） |
| 5.1 | task 1.2（worktree が `origin/$BASE_BRANCH` 最新化済みなので、`EXISTING_SPEC_DIR` 検出は base 上の状態を見る — コード変更不要・structurally 担保） |
| 5.2 | task 1.2（`_resume_branch_init` L4017 / L4043 の `origin/${BASE_BRANCH}`） |
| 5.3 | env var 名 `IMPL_RESUME_PRESERVE_COMMITS` を変更していないことを確認 |
| 5.4 | task 1.2（resume-mode log の `fresh-from-main` → `fresh-from-base base=$BASE_BRANCH`） + task 1.3（resume_section heredoc） |
| 6.1 | task 4.2（README 新節の役割・既定値・設定方法） |
| 6.2 | task 4.2（README 新節の「gitflow 移行手順」4 ステップ） |
| 6.3 | task 4.2（README 新節の Resolution truth table） |
| 6.4 | task 4.1（root + repo-template CLAUDE.md の文言一般化） |
| 6.5 | task 4.2（README 新節の dogfood 確認手順） |
| 7.1 | template 配布物のデフォルトが `main` 相当であることを確認（`vars.IDD_CLAUDE_BASE_BRANCH \|\| 'main'`、コード変更なし） |
| 7.2 | task 1.1 + smoke test #1（`BASE_BRANCH` 未設定で従来挙動 byte-equivalent） |
| 7.3 | `install.sh` を変更していないことを確認 |
| NFR 1.1 | smoke test #1（既定 main で prompt 222 行 byte-equivalent） |
| NFR 1.2 | task 1.1（既存 env var 名すべて温存） |
| NFR 1.3 | cron / launchd 起動文字列を変更していないことを確認（env 追加のみ） |
| NFR 1.4 | exit code / ラベル / 遷移契約を変更していないことを確認（コード変更は引数のみ） |
| NFR 2.1 | `install.sh` / `setup.sh` を変更していないことを確認 |
| NFR 2.2 | sudo を要求する手順を追加していないことを確認 |
| NFR 3.1 | merge 後の人間観測に委ねる（上記「dogfood E2E」） |
| NFR 3.2 | `set -euo pipefail` + `_slot_mark_failed` の既存経路に乗せる（silent fail なし） |
| NFR 4.1 | task 1.1（起動時 log 1 行） |
| NFR 4.2 | task 1.2（worktree reset / branch init log の `origin/${BASE_BRANCH}` 表記） |
