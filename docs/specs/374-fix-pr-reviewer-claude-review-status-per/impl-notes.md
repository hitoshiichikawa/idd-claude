# Implementation Notes — Issue #374

## 設計判断

修正方針スコープは PM 確定済みで「(A) PR 作成後に再 publish」「(B) pr-reviewer.sh 側で
claude-review も publish」のいずれか／両方が許容範囲。本実装では **(B) を独立 processor
として実装する** 方針を採用した。

### 採用方針: 独立 catch-up processor (B' 派生)

`pr-reviewer.sh` 内に新規 processor `process_claude_review_status_catchup` を追加し、
watcher 1 サイクルあたり 1 回、`pr_fetch_candidate_prs`（既存 / open PR scan）から候補 PR を
列挙して `claude-review` status の publish を試みる。

#### 採用理由

1. **PR 存在の構造的保証**: `pr_fetch_candidate_prs` は `gh pr list --state open` で
   open PR のみを返すため、catch-up 時点で **PR が GitHub 側に存在することが構造的に保証** される。
   per-task ループの Reviewer round 直後の publish が PR 作成より前に発火する問題
   （Issue #374 の根本原因）が構造的に発生しない時間軸で publish が走る。
2. **codex 経路との対称**: codex / antigravity の `codex-review` status は同じ `pr_run_review_for_pr`
   経路で同じ「PR が存在する状態」で publish されており、claude-review の catch-up も同じ
   入力（open PR scan）から駆動することで対称性が取れる。
3. **per-task / 非 per-task 両方をカバー**: catch-up は `PER_TASK_LOOP_ENABLED` の値に依存せず
   動作するため、非 per-task 経路（Stage B / B' / B''）でも latest-wins セマンティクスにより
   最終状態への収束を強化する（Req 4.5）。既存の `publish_claude_review_status` 直接呼び出し
   12 箇所は **一切変更していない**（Req 2.x 非 per-task 経路の挙動温存）。
4. **`PR_REVIEWER_ENABLED` 非依存**: README #349 の既存契約（claude-review 単独有効化が可能）
   を維持するため、catch-up は AND 二重 opt-in のみで gate する独立 processor とした。
   既存 `pr_run_review_for_pr` 内に embed する案も検討したが、それだと `PR_REVIEWER_ENABLED=true`
   が必須になり既存契約と矛盾するため不採用。

### 検討して採用しなかった案

- **(A) PR 作成完了後フック**: Stage C / PjM 完了時に publish を発火させる案も検討した
  が、PjM 完了から GitHub の PR 取得 eventual consistency までのウィンドウ（最大 73〜135 秒の
  edge cache lag が #108 / #110 で観測されている）を吸収する verify_stagec_pr_or_retry 経路に
  publish を組み込む必要があり、副作用範囲が広い。watcher サイクル毎の catch-up は次回サイクル
  （最短 2 分）で結果整合的に publish が完了するため、ラグ吸収は不要で実装が単純。
- **`pr_run_review_for_pr` 内に embed**: 上記 4 の理由で不採用。

## 変更ファイル一覧

- `local-watcher/bin/modules/pr-reviewer.sh`
  - 新規関数 `pr_publish_claude_status_from_branch(pr_number, sha, head_ref, pr_url)`
    （1 PR 分の catch-up publish）。`pr_` prefix 踏襲。AND 二重 opt-in / head pattern
    判定 / spec dir 解決 (`git ls-tree` + `git show`) / `parse_review_result` 呼び出し /
    `pr_publish_claude_status` 呼び出しを含む。すべての skip 条件で WARN + return 0
    （silent fail 禁止）。
  - 新規 processor `process_claude_review_status_catchup()`（サイクルあたり 1 回起動 /
    AND 二重 opt-in のみで gate / open PR scan→各 PR で `pr_publish_claude_status_from_branch`
    を呼ぶ）。
- `local-watcher/bin/issue-watcher.sh`
  - `process_pr_reviewer` 呼び出し直後に `process_claude_review_status_catchup` を呼ぶ
    1 行を追加（Phase A flock 内 / 後続 processor を阻害しない `|| pr_warn`）。
- `README.md`
  - 「PR Reviewer Commit Status Publishing (#349)」節の「Publish の発火タイミング」
    `claude-review` 項目に per-task catch-up 経路の説明を追記（既存 #349 セマンティクスの
    補完であることと、`PR_REVIEWER_ENABLED` 非依存であることを明記）。
- `local-watcher/test/pr_publish_claude_status_from_branch_test.sh`（新規 / 近接テスト）
  - 既存 `pr_publish_commit_status_test.sh` の `extract_function` イディオムを踏襲。

## 追加した近接テストの概要

`local-watcher/test/pr_publish_claude_status_from_branch_test.sh`（52 件のアサーション）:

- **Section 1: AND 二重 opt-in 早期 return**（Req 5.1 / 5.2 / NFR 1.1）
  - 両 gate 未設定 / 片方 ON / もう片方 ON の各ケースで gh / git 呼び出しがゼロであること。
- **Section 2: head_ref パターン外 → silent skip**
  - `feature/other` 等の非 claude/issue- 形式は WARN を残さず早期 return すること。
- **Section 3: approve → state=success**（Req 1.4 / 4.1）
  - gh api POST が 1 回 / payload に context=claude-review / description=claude: approve /
    target_url に PR head sha 指定の blob URL が含まれること。catch-up サマリログ 1 行。
- **Section 4: reject → state=failure**（Req 4.2）
  - state=failure / description=claude: reject。
- **Section 5: skip 経路の WARN ログ**（Req 3.1〜3.5）
  - spec-dir-not-found / file-not-found / parse-failed / ls-tree-failed / invalid-result の
    5 経路すべてで rc=0 + WARN ログに `branch=…` `pr=#…` `reason=…` 識別子を含むこと。
- **Section 6: publish 呼び出し位置の回帰防止**（NFR 4.3）
  - `process_claude_review_status_catchup` 内で `pr_publish_claude_status_from_branch` を呼ぶこと。
  - `pr_fetch_candidate_prs`（open PR scan）を入力に取ること（= PR 存在状態で呼ばれる構造的保証）。
  - `pr_status_check_enabled` で gate されること。
  - `PR_REVIEWER_ENABLED` を参照していないこと。
- **Section 7: processor orchestration**
  - gate OFF / 候補 0 件 / 候補 1 件 / 候補 2 件 / head pattern 外の各シナリオで
    publish 呼び出し回数とサマリログを検証。

NFR 4.3「publish 呼び出し位置が再び PR 作成より前に戻る回帰がコミットされた場合に該当
テストを fail させ、どの呼び出し位置が PR 未作成の時間軸に並んでいるかを 1 件以上特定可能
な形で出力する」については、Section 6 の text-grep アサーションが該当機能。具体的には:
- `process_claude_review_status_catchup` が `pr_fetch_candidate_prs` から入力を取らない
  リファクタが入ると Section 6 が fail し、catch-up の構造的保証が崩れたことを検出する。
- catch-up を `process_pr_reviewer` の embed に戻すリファクタが入っても Section 6 の
  「`pr_status_check_enabled` で gate される」アサーションが残るため、AND opt-in 以外の
  gate が混入したら fail する。

## 静的検査・テスト実行結果

### bash -n（構文チェック）

- `bash -n local-watcher/bin/issue-watcher.sh` → OK
- `bash -n local-watcher/bin/modules/pr-reviewer.sh` → OK
- `bash -n local-watcher/test/pr_publish_claude_status_from_branch_test.sh` → OK

### shellcheck（`.shellcheckrc` 反映 / 警告増加 0 が目標）

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh
  local-watcher/test/pr_publish_claude_status_from_branch_test.sh` → 警告ゼロ

### テスト

- `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh` → PASS=52 / FAIL=0
- 既存 `pr_publish_commit_status_test.sh` → PASS=74 / FAIL=0（回帰なし）
- `local-watcher/test/*_test.sh` 全件（49 ファイル） → 49 件すべて PASS

### root ↔ repo-template 同期確認

- `diff -r .claude/agents repo-template/.claude/agents` → diff なし
- `diff -r .claude/rules repo-template/.claude/rules` → diff なし
- `local-watcher/` は root 専用（`install.sh` 経由で `$HOME/bin/modules/` へ配布）
- `.github/workflows/` は本 PR では編集していない

## AC traceability（要件 ID → テスト / 実装の対応）

| AC ID | テストケース / 実装 |
|---|---|
| Req 1.1 | per-task Reviewer round=1 approve / AND opt-in / PR 存在状態の同時成立 — Section 7 Case 7.C で fixture により再現 |
| Req 1.2 | per-task Reviewer round reject → claude-review=failure — Section 4 + 関数仕様 |
| Req 1.3 | context 名・state 解決・description 長制限が非 per-task と一致 — `pr_publish_claude_status` を流用するため契約一致（既存 #349 テスト pr_publish_commit_status_test.sh が回帰固定） |
| Req 1.4 | PR 作成完了後の publish 1 回以上保証 — Section 7 Case 7.C / 7.D（catch-up が PR 作成後にサイクル毎に発火） |
| Req 1.5 | 同一 PR 内で複数 task の Reviewer round 完了 → 最新 RESULT に収束 — GitHub latest-wins セマンティクス + catch-up がサイクル毎に最新 review-notes.md を読むため自然成立。本 issue では implicit |
| Req 2.1 / 2.2 / 2.3 | 非 per-task 経路の挙動温存 — 既存 `publish_claude_review_status` 呼び出し 12 箇所は **一切変更していない** ことで保証 |
| Req 3.1 | PR 未解決時 WARN + skip — Section 7 Case 7.E（head pattern 外） + Section 5（spec-dir-not-found） |
| Req 3.2 | review-notes.md 不在時 WARN + skip — Section 5 Case 5.B |
| Req 3.3 | parse 失敗時 WARN + skip — Section 5 Case 5.C / 5.E |
| Req 3.4 | skip 時もパイプライン継続（rc=0） — Section 5 各 case の `rc=0` アサーション |
| Req 3.5 | WARN に Issue 番号 / branch 名 / 理由を含む — Section 5 各 case の `assert_contains` |
| Req 4.1 | per-task 最終 round approve + PR 作成完了 → success 観測可能 — Section 7 Case 7.C |
| Req 4.2 | per-task 最終 round reject + PR 作成完了 → failure 観測可能 — Section 4 + Section 7 setup（approve は 7.C / reject は組み合わせで同じ経路を通る） |
| Req 4.3 | latest-wins セマンティクス — `pr_publish_claude_status`（既存）を呼ぶため自然成立（既存 #349 動作） |
| Req 4.4 | PR 未存在で publish しない（副作用ゼロ） — Section 7 Case 7.E + Section 2 |
| Req 5.1 / 5.2 | AND 二重 opt-in OFF で API 呼び出しゼロ — Section 1 全 case / Section 7 Case 7.A |
| Req 5.3 / 5.4 / 5.5 | env var 名・正規化規則・PR コメント挙動を変更しない — 本実装は新規 catch-up processor 追加のみ。既存 `pr_status_check_enabled` / `pr_publish_claude_status` / `parse_review_result` を流用 |
| Req 6.1 / 6.2 / 6.3 | install.sh / README / E2E — `install.sh` の `copy_glob_to_homebin` が `modules/*.sh` を一括コピーするため `pr-reviewer.sh` の変更は自動配布される（既存挙動）。README は同一 PR で更新済み |
| NFR 1.1 / 1.2 / 1.3 | 既存挙動温存 / 既存正規化規則 / 既存関数シグネチャ非破壊 — 新規関数追加のみ、既存関数は無変更 |
| NFR 2.1 / 2.2 | 静的検査 — 上記「静的検査」セクション |
| NFR 3.1 / 3.2 / 3.3 | 観測ログ — `pr_log` 経由で `pr-reviewer:` prefix 統一、suppression は既存 cycle-1-line 制限に委ねる |
| NFR 4.1 / 4.2 / 4.3 | 回帰防止テスト — `pr_publish_claude_status_from_branch_test.sh` Section 6 / 7 |

## 確認事項

なし。要件は EARS 形式で十分に明確であり、実装方針スコープも PM 確定済みで Architect の
領分との曖昧性はなかった。本実装は方針 (B) を独立 processor として実装する派生を採用した
理由を本ファイル冒頭に明記している。

## STATUS

本 Issue の修正は完了し、Reviewer に渡してよい状態。

STATUS: complete
