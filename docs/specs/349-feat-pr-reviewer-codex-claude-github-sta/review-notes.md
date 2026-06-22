# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T13:35:00Z -->

## Reviewed Scope

- Branch: claude/issue-349-impl-feat-pr-reviewer-codex-claude-github-sta
- HEAD commit: 90ab9b9fa8da3004b3237e1ca0d62ceec6ec59af
- Compared to: main..HEAD

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh` の Config ブロック (#349 節) で `PR_REVIEWER_STATUS_CHECK_ENABLED="${PR_REVIEWER_STATUS_CHECK_ENABLED:-false}"` を宣言（既定 `false`）
- 1.2 — `pr_status_check_enabled` が `PR_REVIEWER_STATUS_CHECK_ENABLED=="true" && FULL_AUTO_ENABLED=="true"` の AND 評価で rc=0 を返す。テスト Section 1「両 gate =true で enabled」
- 1.3 — issue-watcher.sh の `case` 正規化で `true` 厳密一致以外を `false` に固定。テスト Section 1「typo は OFF」（`True` / `TRUE` / `1` / `on` / 空 / 前後空白 7 種）
- 1.4 — `pr_status_check_enabled` 内 `FULL_AUTO_ENABLED!=true` で rc=1。テスト Section 1「PR gate ON + kill OFF は disabled」
- 1.5 — codex 経路は `pr_post_review_comment` の **後**で `pr_publish_codex_status` を呼ぶ配線（`pr_run_review_for_pr` 末尾）。gate OFF テスト全 case で gh 呼び出しゼロを確認
- 2.1 — `pr_publish_codex_status` で `match_count==0 → state=success`。テスト Section 3 Case A「VERDICT approve → state=success」
- 2.2 — `match_count>0 → state=failure`。テスト Section 3 Case B「needs-iteration → state=failure」
- 2.3 — `pr_publish_commit_status` で `description` を 72 文字に切り詰め（`${description:0:72}`）。テスト Section 2 Case G「description は 72 文字以内」
- 2.4 — `pr_run_review_for_pr` で `$pr_url` を渡し target_url とする。テスト Section 2 Case B「target_url=PR URL」 + Case C「空時は -f target_url= を渡さない」
- 2.5 — context 名は `"codex-review"` ハードコード。テスト Section 3 Case B「context=codex-review 共有」
- 3.1 — `publish_claude_review_status` が `parse_review_result` 経由で `approve` → `pr_publish_claude_status` → `state=success`。テスト Section 4 Case A
- 3.2 — `reject` → `state=failure`。テスト Section 4 Case B
- 3.3 — `description="claude: approve|reject"`。テスト Section 4 Case A / B
- 3.4 — `publish_claude_review_status` で `https://github.com/${REPO}/blob/${sha}/${SPEC_DIR_REL}/review-notes.md` を組立。`pr_url` fallback あり。テスト Section 4 Case A「target_url に review-notes.md blob URL」
- 3.5 — `publish_claude_review_status` で `parse_rc != 0` / 不正 result 時に WARN + return 1（publish せず）。テスト Section 4 Case C「不正 result は rc=4 + WARN」
- 4.1 — `publish_claude_review_status` が呼び出し時点で `gh pr list --head "$BRANCH" --state all --json headRefOid` を取得（最新 head sha を使用）
- 4.2 — 過去 sha を保持・参照する経路は無く、毎回最新 sha のみ参照
- 4.3 — Out of Scope 明記の通り「latest wins per (sha, context)」仕様に依存。明示削除 API は呼ばない
- 5.1 — `pr_publish_commit_status` の API 失敗分岐で `pr_warn "commit status publish FAILED: pr=#... sha=... context=... state=... rc=... stderr=..."`。テスト Section 2 Case F
- 5.2 — 同 WARN ペイロードに rc / stderr 抜粋（512 bytes）が含まれる
- 5.3 — call site の `|| true`（`pr_publish_codex_status ... || true` / `publish_claude_review_status N || true`）でパイプライン継続
- 5.4 — `pr_warn` で記録、`return 3` で silent fail にしない
- 5.5 — `pr_publish_codex_status` は `pr_post_review_comment` 完了**後**に呼ばれる配線
- 6.1 — gate OFF テスト全 case（Section 2 Case A / Section 3 Case C / Section 4 Case D）で gh 呼び出しゼロ
- 6.2 — gate OFF 時の挙動は #348 既存挙動 + 本機能未導入時と等価（`|| true` 配線で副作用ゼロ）
- 6.3 — 本変更は既存 `pr_run_review_for_pr` のレビューコメント投稿 / iteration ラベル付与経路を変更しない（diff で確認 — `pr_publish_codex_status` 呼び出し追加のみ）
- 7.1 — `pr_log "commit status published: pr=#... sha=... context=... state=..."` を成功時に 1 行。テスト Section 2 Case B「成功時 1 行 log」
- 7.2 — `PR_STATUS_GATE_SUPPRESS_LOGGED` フラグで cycle 内重複を抑止。テスト Section 2 Case A「cycle あたり最大 1 行」
- 7.3 — `pr_publish_commit_status` 内で `PR_REVIEWER_STATUS_CHECK_ENABLED!=true` 条件下のみ suppression log を出す（`FULL_AUTO_ENABLED` 単独 OFF 時はログを出さず #348 既存ログに委ねる）
- NFR 1.1 — gate OFF 全 case で gh 呼び出しゼロ
- NFR 1.2 — `gh api -f key=value` は内部で JSON 構築のため inline 展開なし。URL path 部の sha / repo owner は事前検証済
- NFR 1.3 — `[[ "$sha" =~ ^[0-9a-f]{40}$ ]]` で使用直前検証。テスト Section 2 Case D
- NFR 1.4 — `[[ "$pr_number" =~ ^[0-9]+$ ]]` で使用直前検証。テスト Section 2 Case E
- NFR 2.1 — 1 publish = 1 gh 呼び出し（call site で per-cycle 1 回）
- NFR 2.2 — 追加ポーリング・background process なし（既存処理パスから 1 回呼ばれる）
- NFR 3.1 — 既定 `false` で gh 呼び出しゼロ
- NFR 3.2 — 既存 env var 名・ラベル名・exit code・context 命名規約を変更していない（diff 確認）
- NFR 3.3 — `pr_post_review_comment` / `pr_detect_iteration_keyword` / `parse_review_result` の関数シグネチャ・契約は不変
- NFR 4.1 — `README.md` の「オプション機能一覧」表に `PR_REVIEWER_STATUS_CHECK_ENABLED` 行追加 + AND-semantics / context 名 / 既定値明記
- NFR 4.2 — `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` ともに空（差分なし）を確認
- NFR 4.3 — README 「PR Reviewer Commit Status Publishing (#349)」節に branch protection 設定手順を記載
- NFR 5.1 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh` で警告ゼロを reviewer 側で再確認
- NFR 5.2 — `bash local-watcher/test/pr_publish_commit_status_test.sh` で PASS=53 FAIL=0 を reviewer 側で再実行・確認（4 系統 codex/claude × success/failure/gate off/publish failure を網羅）

## Findings

なし

## Summary

全 Requirement（1.x〜7.x）および全 NFR（1.x〜5.x）について実装またはテストでの担保を確認。
shellcheck 警告ゼロ・新規テスト 53 assertion 全 PASS・dual-management 同期確認済。AND 二重
opt-in（既定 OFF）の後方互換設計が要件通り維持されている。

RESULT: approve
