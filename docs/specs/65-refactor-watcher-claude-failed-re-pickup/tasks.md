# Implementation Plan

- [x] 1. ラベル description の更新（Req 2 系）
- [x] 1.1 `idd-claude-labels.sh` の `claude-failed` description を復旧手順入り文言に更新（local 側） (P)
  - `local-watcher` 側ではなく `.github/scripts/idd-claude-labels.sh` の LABELS 配列を更新
  - line 71 の `"claude-failed|e74c3c|【Issue 用】 自動実行が失敗"` を design.md 採用案 A の文言（`【Issue 用】 自動実行が失敗（復旧時は ready-for-review を先に付与してから外す）`、56 文字）に置換
  - **name と color は変更しない**（Req 2.4 / NFR 1.4）
  - `--force` 再実行で description 上書きが走ること（既存 line 113 の分岐）を `gh label list --json` で目視確認
  - shellcheck で warning 0 を維持（NFR 3.2）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, NFR 1.4, NFR 3.2_
  - _Boundary: Label Provisioning Update_
- [x] 1.2 `repo-template/.github/scripts/idd-claude-labels.sh` の同一更新（template 同期） (P)
  - line 67 の `"claude-failed|e74c3c|自動実行が失敗"` を `1.1` と同じ文言に更新（template 側は `【Issue 用】` prefix が付かない既存スタイルを踏襲しつつ、復旧手順の本文は同じ）
  - consumer repo への波及は `install.sh --force` 再実行が前提（README に migration note の追加は不要 / 既存運用パターン）
  - shellcheck で warning 0 を維持（NFR 3.2）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, NFR 1.4, NFR 3.2_
  - _Boundary: Label Provisioning Update_

- [x] 2. Pre-Claim Filter 関数 `check_existing_impl_pr` の実装（Req 1 系）
- [x] 2.1 logger 関数 `pclp_log` / `pclp_warn` / `pclp_error` の追加
  - prefix `pre-claim-probe:` 固定（NFR 2.1）
  - 既存 `mq_log` / `pi_log` / `drr_log` / `qa_log` / `sc_log` と同形式（`[$(date '+%F %T')] pre-claim-probe: $*`）
  - 配置位置: `_dispatcher_run` より前で、かつ logger を使う関数より前（design.md File Structure Plan 参照）
  - _Requirements: NFR 2.1_
- [x] 2.2 `check_existing_impl_pr <issue_number>` 関数本体の実装
  - GraphQL query は `closingIssuesReferences(first: 20) { nodes { number, state, headRefName } }`（design.md GraphQL Query 節）
  - `gh api graphql -f query=... -F owner=... -F repo=... -F number=...` を `timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"` でラップ（既存規律 / 新 env var 導入禁止）
  - 入力検証: 空文字 / 非数値で warn + exit 1
  - jq で `.data.repository.issue.closingIssuesReferences.nodes` 取得
  - impl / design 判別: `headRefName` を `^claude/issue-${N}-impl(-resume)?-` で照合、design pattern (`^claude/issue-${N}-design-`) は warn 出して無視、未知 pattern は **safe-side で impl 扱い**（design.md 判別ロジック節）
  - state 集約: `OPEN` あり → skip / `MERGED` のみ → skip / `CLOSED` のみ → continue / 該当無し → continue（design.md State 集約規則）
  - 出力ログ: design.md Log Format 節の固定 key=value 形式（`issue=#N pr=#P state=S reason=R`）
  - GraphQL / API 失敗 / RATE_LIMITED は **fail-safe で skip + warn**（Req 1.7 / NFR 4.2）
  - exit code: 0 = continue / 1 = skip
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, NFR 1.5, NFR 2.2, NFR 4.1, NFR 4.2_
  - _Boundary: Issue Linkage Probe_
  - _Depends: 2.1_

- [x] 3. Dispatcher per-issue ループへの skip 分岐挿入
- [x] 3.1 `_dispatcher_run` の per-issue 先頭に `check_existing_impl_pr` 呼び出しを挿入
  - 挿入位置: line 4326 直後（`issue_number=$(echo "$issue" | jq -r '.number')` の直後、空き slot 探索 line 4329 より前）
  - パターン:
    ```bash
    if ! check_existing_impl_pr "$issue_number"; then
      continue
    fi
    ```
  - **既存 `gh issue list` のフィルタ条件は変更しない**（Req 4.5 / NFR 1.5 / 後方互換性）
  - skip 時は claim ラベル（`claude-claimed`）を一切付与しないこと（Req 1.2 / 1.3 / 1.4 を構造的に保証 / continue で次 Issue へ）
  - dogfood-A シナリオ（OPEN PR 存在時）と dogfood-C シナリオ（PR 不在時）の挙動差を `pre-claim-probe:` ログで確認可能であること
  - shellcheck で warning 0 を維持（NFR 3.1）
  - _Requirements: 1.1, 1.2, 1.3, 1.5, 1.7, NFR 1.5, NFR 2.3, NFR 3.1_
  - _Depends: 2.2_

- [x] 4. escalation コメントへの手動復旧手順統合（Req 3 系）
- [x] 4.1 共通関数 `build_recovery_hint <pr_present>` の実装
  - 引数: `pr_present` ∈ {`yes`, `no`, `unknown`}（既定 `unknown`）
  - 出力: heredoc で markdown 文字列を stdout に
  - 必須キーワード: `ready-for-review` / `claude-failed` / 「先に付与」「外す」/ 「force-push」「orphan」「再 pickup」（Req 3.1 / 3.2）
  - `pr_present=no` 分岐で「PR が無い場合は claude-failed 除去のみで再 pickup される」旨を出力（Req 3.3）
  - `pr_present=unknown` は両ケースの手順を併記
  - 副作用なし（純粋関数）
  - 配置位置: `mark_issue_failed` / `_slot_mark_failed` / `pi_escalate_to_failed` のいずれよりも前
  - _Requirements: 3.1, 3.2, 3.3_
  - _Boundary: Recovery Documentation_
- [x] 4.2 既存 escalation コメント生成 3 経路への組み込み (P)
  - `mark_issue_failed` (line 2936) の body 末尾に `$(build_recovery_hint "unknown")` を append
  - `_slot_mark_failed` (line 3556) の body 末尾に `$(build_recovery_hint "unknown")` を append
  - `pi_escalate_to_failed` (line 1474) の body 末尾に `$(build_recovery_hint "yes")` を append（PR Iteration は必ず PR 存在文脈）
  - `qa_build_escalation_comment` (line 446) は **対象外**（needs-quota-wait であり claude-failed 経路でない / Req 3.4 で「`claude-failed` 遷移時の escalation」が対象）
  - 既存コメントの body 構造（`⚠️ 自動開発が失敗しました...` / `ログ: ...` / `問題を解決してから ... 外してください。`）を破壊せず、追記のみで実現すること
  - shellcheck で warning 0 を維持（NFR 3.1）
  - _Requirements: 3.4, NFR 3.1_
  - _Boundary: Recovery Documentation_
  - _Depends: 4.1_

- [ ] 5. README への手動復旧節の追加（Req 4 系）
- [ ] 5.1 README.md に手動復旧節を新規追加
  - 配置: 既存「失敗時」節（line 521-524）を拡充するか、その直下に新規 h3 / h4 として追加
  - 構成（design.md File Structure Plan 参照）:
    1. PR が既に作成済みの場合の手順: `ready-for-review` 先付与 → `claude-failed` 除去（Req 4.3）
    2. 順序逆転時のリスク: 既存 PR の orphan 化（過去事例 PR #62 への参照）
    3. PR が無い場合の手順: `claude-failed` 除去のみで再 pickup される旨（Req 4.4）
    4. watcher 側の自動ガード（Req 1）の説明（事故耐性が二重化されていることを明示）
  - 「ラベル状態遷移まとめ」節（line 528 以降）の `claude-failed` 行に新節へのリンクを追記（Req 4.5）
  - 既存「失敗時」節（line 521-524）/ ラベル説明表 / `claude-failed` 言及箇所すべてから新節への相互参照リンクを置く（Req 4.5）
  - **`repo-template/CLAUDE.md` には追記しない**（design.md Migration Strategy 節 / consumer repo の責務範囲外）
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

- [ ] 6. 静的解析と dogfood test（NFR 3 系）
- [ ] 6.1 shellcheck / 互換性検証
  - `shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` で warning 0
  - cron-like 最小 PATH での起動確認: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git timeout'`
  - 既存 dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で流し、`処理対象の Issue なし` で正常終了すること（NFR 1.5 / NFR 1.3 構造的検証）
  - 既存 cron 登録文字列（`*/2 * * * * REPO=... REPO_DIR=... $HOME/bin/issue-watcher.sh ...`）を 1 文字も変更していないこと
  - _Requirements: NFR 1.1, NFR 1.2, NFR 1.3, NFR 3.1, NFR 3.2_
- [ ] 6.2 dogfood test 手順記述（PR 本文 Test plan 用）
  - **dogfood-A (OPEN PR シナリオ)**: test Issue を立て `auto-dev` 付与 → 手動 impl PR を作成（branch `claude/issue-<N>-impl-test-<slug>`、本文に `Closes #<N>`、空 commit OK）→ Issue に `claude-failed` 付与 → `claude-failed` のみ除去（誤操作シナリオ）→ watcher を 1 cycle 走らせ、`pre-claim-probe: skip issue=#N pr=#P state=OPEN` ログが出ること、`claude-claimed` ラベルが付かないこと、worktree が触られないことを確認（NFR 3.3）
  - **dogfood-B (CLOSED PR シナリオ)**: 同様に PR を作って `gh pr close <PR>`（merge せず close）→ watcher 1 cycle で `pre-claim-probe: continue issue=#N reason=closed-only pr=#P` ログ → 既存フローに進むことを確認（NFR 3.4）
  - **dogfood-C (PR 不在の通常運用)**: 既存任意 auto-dev Issue で 1 cycle、`pre-claim-probe: continue issue=#N reason=no-linked-impl-pr` ログ → 本機能導入前と同一に Triage / impl が起動することを確認（NFR 1.5 構造的検証）
  - dogfood 実施後の test Issue / 手動 PR は **必ず close / 削除**してリポジトリをクリーンにすること
  - _Requirements: NFR 1.5, NFR 3.3, NFR 3.4_

- [ ]* 6.3 ラベル description 反映確認（任意 / 手動確認）
  - `bash .github/scripts/idd-claude-labels.sh --force` を本リポジトリで実行
  - `gh label list --json name,description | jq '.[] | select(.name=="claude-failed")'` で description が新文言になっていることを確認
  - description が GitHub の 100 文字制限を超えていないことを確認（Req 2.2）
  - _Requirements: 2.1, 2.2, 2.3_
