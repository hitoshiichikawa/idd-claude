# Implementation Plan

> 各タスクは 1 commit 単位で独立完了可能な粒度。`(P)` 付きタスクは並列実行可能（境界を `_Boundary:_` で明示）。
> design.md の File Structure Plan / Components and Interfaces を必ず参照のこと。

- [x] 1. Watcher core: `BASE_BRANCH` 解決と全 git 操作の抽象化
- [x] 1.1 Config ブロックに `BASE_BRANCH` を導入し、`MERGE_QUEUE_BASE_BRANCH` を連鎖 default 化、起動時に解決値を log 出力
  - `local-watcher/bin/issue-watcher.sh` L78 直前に `BASE_BRANCH="${BASE_BRANCH:-main}"` を新設
  - 既存 `MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-main}"` を `MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}}"` に変更
  - `mkdir -p "$LOG_DIR"` 直後（L246 付近）に解決値 log（`base-branch=${BASE_BRANCH} merge-queue-base=${MERGE_QUEUE_BASE_BRANCH}`）を 1 行追加
  - `MERGE_QUEUE_BASE_BRANCH` の env var 名は変更しないこと（NFR 1.2）
  - design.md の Resolution Truth Table の 5 ケースが解決値で再現されることを mental check
  - _Requirements: 1.2, 1.7, 2.1, 2.2, 2.3, 2.4, 5.3, 7.2, NFR 1.2, NFR 4.1_

- [x] 1.2 git 操作（G1-G4）の `main` リテラルを `$BASE_BRANCH` 参照化
  - L261-262 の `git checkout main` / `git pull --ff-only origin main` を `"$BASE_BRANCH"` に置換（G1）
  - L3666 worktree add の `origin/main`、L3691 worktree reset の `origin/main`、関連 log 文面 L3670 / L4243 を `origin/$BASE_BRANCH` に置換（G2）
  - L4017 / L4043 / L4441 の `git checkout -B "$BRANCH" "origin/main"` を `origin/$BASE_BRANCH` に置換（G3）
  - L4048 の log メッセージ `resume-mode=fresh-from-main` を `resume-mode=fresh-from-base` に変更（Req 5.4）
  - L1811 / L1850 / L1972 / L1979 の safety-net `git checkout main` を `"$BASE_BRANCH"` に置換（G4）
  - L686 / L717 / L869 の `${MERGE_QUEUE_BASE_BRANCH}` 参照箇所はコード変更不要（連鎖 default で同値解決）。ただし L838 のコメント内 "対象 main 以外なら" を「対象 base ブランチ以外なら」に文言修正
  - 各 commit 後に `shellcheck` を流して警告ゼロを維持
  - _Requirements: 1.1, 1.3, 1.4, 1.6, 5.2, 5.4, NFR 1.1, NFR 4.2_

- [x] 1.3 Stage A/A'/B/C prompt heredoc の `main` リテラルを `${BASE_BRANCH}` 展開化（G5/G6/G7）
  - L2570 / L2631 / L2634 / L2657 / L2666 / L2716 / L2731 / L2733 / L2766 / L2795 / L2830 / L4488 / L4497 の `main` を `${BASE_BRANCH}` または `${BASE_BRANCH}..HEAD` に置換
  - quoted heredoc（`<<'EOF'`）が混じっている箇所が無いか grep で再確認、混入していたら通常 heredoc に変更してから変数展開する（既存コードでは `'EOF'` 使用箇所が限定的なので原則そのまま展開可）
  - PjM への注入文 L2795 `直近の main 上の merge commit から git log --oneline --merges で探す` を `直近の ${BASE_BRANCH} 上の…` に変更
  - Reviewer prompt の `Compared to: main..HEAD` 表記を `Compared to: ${BASE_BRANCH}..HEAD` に変更
  - 各 commit 後に `BASE_BRANCH=develop` で dry-run（対象なし）を流して prompt 組み立てパスにエラーが出ないことを確認
  - _Requirements: 1.5, 4.1, 4.3, 5.4, NFR 1.1_
  - _Depends: 1.1_

- [x] 2. Agent prompt template 一般化（C2 採用方式: heredoc=変数展開、template=一般語化 + 補足注記）
- [x] 2.1 `repo-template/.claude/agents/project-manager.md` の base 指定文言を更新 (P)
  - L26 / L165 の `- base: \`main\`` → `- base: \`<BASE_BRANCH>\`（idd-claude が解決した base ブランチ。watcher / Actions のいずれの経路でもオーケストレーターが env から渡す。未指定時の既定は \`main\`）`
  - L246 の `- \`main\` への直接 push` → `- base ブランチ（既定 \`main\`）への直接 push`
  - 文意が任意の base branch（main / develop / その他）で整合することを目視確認（Req 4.4）
  - _Requirements: 4.1, 4.2, 4.4_
  - _Boundary: project-manager.md_

- [x] 2.2 `repo-template/.claude/agents/reviewer.md` の diff/log 参照を更新 (P)
  - L40 / L63 / L68 / L98 / L99 / L121 / L235 の `git diff main..HEAD` / `git log --oneline main..HEAD` / `Compared to: main..HEAD` / 「main path に注入」表現を `<BASE_BRANCH>..HEAD` 形式に変更
  - 「`<BASE_BRANCH>` は idd-claude が解決した base ブランチ。未指定時の既定は `main`」の補足注記を冒頭付近の入力契約節（L82-94 周辺）に 1 か所追加
  - 「flag 分岐なしで直接 main path に注入」のような **比喩的な main**（base branch を指していない）は「直接 base path に注入」または「直接実行パスに注入」と一般化（誤読回避）
  - _Requirements: 4.1, 4.3, 4.4_
  - _Boundary: reviewer.md_

- [x] 2.3 `repo-template/.claude/agents/developer.md` の base 参照と禁止事項を更新 (P)
  - L17-18 の「main に載っている前提」→「base ブランチ（idd-claude が解決した `<BASE_BRANCH>`、既定 `main`）に merge 済み前提」に一般化
  - L80 の `git diff main..HEAD -- <変更ファイル>` → `git diff <BASE_BRANCH>..HEAD -- <変更ファイル>`、補足注記で `<BASE_BRANCH>` が env 解決値であることを 1 行追加
  - L98 の `git log --oneline main..HEAD` → `git log --oneline <BASE_BRANCH>..HEAD`
  - L146 の `- \`main\` への直接 push` → `- base ブランチ（既定 \`main\`）への直接 push`
  - _Requirements: 4.1, 4.3, 4.4, 5.4_
  - _Boundary: developer.md_

- [ ] 3. Workflow YAML（C3 採用方式: `vars.IDD_CLAUDE_BASE_BRANCH || 'main'`）
- [x] 3.1 `repo-template/.github/workflows/issue-to-pr.yml` に `env.BASE_BRANCH` を導入し全 step を動的化
  - `jobs.claude-team-dev` 直下に `env: BASE_BRANCH: ${{ vars.IDD_CLAUDE_BASE_BRANCH || 'main' }}` を新設
  - `Checkout main` step の `ref: main` を `ref: ${{ env.BASE_BRANCH }}` に変更（step 名も `Checkout base branch` 等に変更）
  - `Create working branch from main` step は内部で `git checkout -B "$BRANCH"` を行うが、現状 `main` から派生していないため変更不要 → ただし step 名を `Create working branch from base` に変更
  - 2 つの prompt heredoc 内の `main から派生・push 済み` を `${{ env.BASE_BRANCH }} から派生・push 済み` に、`main に直接 push しないこと` を `${{ env.BASE_BRANCH }} に直接 push しないこと` に変更
  - `IDD_CLAUDE_USE_ACTIONS == 'true'` の opt-in gate は変更しないこと（Req 3.4）
  - 変更後 `actionlint` でクリーン
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 4.1, NFR 1.1_

- [ ] 3.2 root `.github/workflows/issue-to-pr.yml` を 3.1 と同じ内容で更新
  - 内容は repo-template 版と完全一致（self-hosting 用と consumer 配布用は同じ workflow を保つ）
  - `actionlint` でクリーン
  - _Requirements: 3.1, 3.2, 3.3, 3.4, NFR 1.1_
  - _Depends: 3.1_

- [ ] 4. ドキュメント整備（C4 - migration note + 文言一般化）
- [ ] 4.1 `repo-template/CLAUDE.md` と root `CLAUDE.md` の特定 branch 名依存文言を一般化 (P)
  - root `CLAUDE.md` L111: `- \`main\` への直接 push` → `- base ブランチ（既定 \`main\`、`BASE_BRANCH` 設定によっては \`develop\` 等）への直接 push`
  - `repo-template/CLAUDE.md` L112: 同上の文言で更新
  - `repo-template/CLAUDE.md` L135 の `origin/main 起点で fresh init + force-push` を `origin/<BASE_BRANCH>（既定 main）起点で fresh init + force-push` に変更
  - 「main にマージ」等の Feature Flag Protocol の説明文（一般的な main の用例）はそのまま温存（読者にとって「main」=「統合 branch」の慣用語的記述として通じるため）
  - _Requirements: 6.4_
  - _Boundary: root-CLAUDE.md, repo-template-CLAUDE.md_

- [ ] 4.2 `README.md` に「ブランチ運用と `BASE_BRANCH`」節を新設し、migration note / 環境変数表追記 / dogfood 手順を追加
  - 既存 `## セットアップ` 節と既存 `## 環境変数` 系セクションの間に新節を挿入
  - 含める項目（design.md の C4 README Migration Note 節を参照）:
    - `BASE_BRANCH` の役割（base branch の単一切替点）と既定値（`main`）
    - 設定方法（cron 例: `*/2 * * * * REPO=... REPO_DIR=... BASE_BRANCH=develop $HOME/bin/issue-watcher.sh`、launchd 例、Actions repository variable `IDD_CLAUDE_BASE_BRANCH=develop` の設定手順）
    - gitflow 移行手順（develop ブランチ作成 → cron に `BASE_BRANCH=develop` 追加 → 次 tick で適用される旨）
    - `BASE_BRANCH` と `MERGE_QUEUE_BASE_BRANCH` の関係表（design.md Resolution Truth Table を簡略化して転記）
    - self-hosting で `BASE_BRANCH=develop` 運用を開始した後の dogfood 確認手順（test issue を立てて develop 起点 PR が作られることを観測する）
    - 訳語選定の補足: 「base ブランチ / base branch / `<BASE_BRANCH>`」が同義であること、prompt 文面の一般化方針
  - 既存「環境変数」表（Phase A の `MERGE_QUEUE_BASE_BRANCH` 行を含む表）の上または相当箇所に `BASE_BRANCH` 行を追加（既定 `main`、用途「watcher 経路 + Actions 経路の base branch を切り替える」）
  - self-hosting 用 `develop` ブランチの自動作成は **本 PR では対象外**（README 手順書記載のみ）。`setup.sh` 自動化は別 Issue 化候補と明記（Open Question 4 への結論）
  - _Requirements: 6.1, 6.2, 6.3, 6.5_
  - _Boundary: README.md_
  - _Depends: 1.1_

- [ ] 5. dogfood 検証手順の記載と self-review
- [ ] 5.1 PR 本文「Test plan」に手動スモークテスト結果を記録、impl-notes.md に env 一覧を残す
  - design.md「Testing Strategy」の Static Analysis（shellcheck / actionlint / grep）の実行結果を impl-notes.md に列挙
  - Manual Smoke Tests の 4 項目（後方互換 / 新挙動 / 連鎖 default / Actions 経路）の実行結果を impl-notes.md に列挙
  - dogfood E2E の Phase 1（merge 直後の cron 継続性）は merge 後の人間観測に委ねる旨を impl-notes.md に明記
  - 残存 `\bmain\b` リテラルの grep 結果と「これは意図的に残した（コメント・既定値定義・比喩用法）」の根拠を 1 行ずつ列挙
  - 本タスクはコード変更を含まない（impl-notes.md への記述のみ）
  - _Requirements: NFR 3.1, NFR 3.2, NFR 4.1_
  - _Depends: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 3.1, 3.2, 4.1, 4.2_
