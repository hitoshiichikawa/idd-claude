# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-27T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-420-impl--bug-pr-reviewer-pr-already-processed-co
- HEAD commit: c2abcac385a9fde29bd683c5c407d6daac11ac69
- Compared to: main..HEAD
- Changed files:
  - `local-watcher/bin/modules/pr-reviewer.sh`（`pr_already_processed` 修正）
  - `local-watcher/test/pr_already_processed_pagination_test.sh`（新規 / 15 assertions）
  - `docs/specs/420--bug-pr-reviewer-pr-already-processed-co/requirements.md`
  - `docs/specs/420--bug-pr-reviewer-pr-already-processed-co/impl-notes.md`

## Verified Requirements

- 1.1 — `pr-reviewer.sh:262-264` の `gh api --paginate --slurp .../comments?per_page=100` で全コメントを取得 / test Section 4 で `--paginate`・`--slurp`・comments エンドポイントの呼び出し検証
- 1.2 — `(add // [])` フラット化 + `any(.[]; ...)` で単ページ・複数ページが同一フィルタ / test Section 1 (Case A, B) 30 件で marker 有/無の双方 PASS、NFR 2.1 込みで gh 呼び出し回数=1 を確認
- 1.3 — test Section 2 Case A (105 件 / marker 最終ページ末尾) と Case C (205 件 / 3 ページ走査 / page2 中段) で page2 以降の marker 検出を確認
- 1.4 — test Section 1 Case C (0 件) / Section 2 Case B (105 件 marker 無) で rc=1 を確認
- 1.5 — jq filter は `sha=` と `kind=` の双方を `[^>]*` 連結で `test()`。tool 属性を判定に含めない既存セマンティクス維持。test Section 2 Case D で sha 一致・kind 不一致が rc=1
- 1.6 — `pr_build_marker`（line 223-228）と marker 検出 regex の文字列形式（`idd-claude:pr-reviewer sha=...kind=...`）を不変
- 2.1 — `pr-reviewer.sh:623` の `pr_post_exec_fail_escalation_comment` 内の `pr_already_processed "$pr_number" "$sha" "exec-fail-escalated"` 呼び出しで同一関数を経由
- 2.2 — `pr-reviewer.sh:961` の `pr_post_error_comment` 内の `pr_already_processed "$pr_number" "$sha" "$kind"` 呼び出しで同一関数を経由
- 2.3 — `pr-reviewer.sh:1434` の review 経路の `pr_already_processed "$pr_number" "$sha" "review"` 呼び出しで同一関数を経由
- 2.4 — 単一関数 `pr_already_processed` の修正により 3 経路すべてに同時適用（実装の自然な帰結）
- 3.1 — `pr-reviewer.sh:262-267` の `if ! comments_json=$(...)` で取得失敗時 rc=0 / test Section 3 Case A
- 3.2 — `gh api --paginate` は途中ページ失敗で非ゼロ終了 → 同一の `if !` 分岐で rc=0 既存扱い / test Section 3 Case B
- 3.3 — `pr_warn "PR #${pr_number}: コメント取得に失敗（marker 重複判定をスキップ＝安全側で既存扱い）"` / test Section 3 (A, B) で WARN ログ 1 行記録を確認
- 3.4 — 単一 fallback 経路を 3 呼び出し経路すべてが共有
- NFR 1.1 — 関数 signature `pr_already_processed(pr_number, sha, kind)` / 戻り値 0=既存・1=未存在 不変
- NFR 1.2 — `pr_build_marker` 未変更、marker 文字列形式・hidden HTML としての可視性不変
- NFR 1.3 — jq filter の `test("idd-claude:pr-reviewer sha=" + $sha + "[^>]*kind=" + $kind)` で (sha, kind) 単位を維持、tool 属性は照合外
- NFR 1.4 — 既存 `PR_REVIEWER_GIT_TIMEOUT` のみ参照、新規 env var 追加なし
- NFR 1.5 — 既存コメント本文への書き換えなし（投稿済み marker 不変）
- NFR 2.1 — `per_page=100` により 100 件以下は 1 ページで完結 / test Section 1 で gh 呼び出し回数=1 を assertion
- NFR 2.2 — 既存 `timeout "$PR_REVIEWER_GIT_TIMEOUT" gh api ...` wrapper を保持
- NFR 3.1 — `pr_warn` プレフィックスを維持、既存メッセージ流用
- NFR 3.2 — Req 3.3 と同上

## Findings

なし

## Summary

`pr_already_processed` を `gh api --paginate --slurp ... per_page=100` 経路に書き換える
最小変更で、(sha, kind) marker 重複判定のページネーション盲点を解消。jq filter `(add // [])`
平坦化により 0 ページ / 単ページ / 複数ページが同一経路で扱われ、既存の `if !` フォールバック
分岐が `--paginate` の途中失敗にもそのまま合流する。3 呼び出し経路（exec-fail-escalated /
pr_post_error_comment / review）はすべて単一関数を経由しており、修正が自然に伝播する。
新規テスト 15 件すべて PASS、impl-notes.md 記載の既存 PR テスト 13 本も回帰なし。marker 形式・
関数 signature・env var・(sha, kind) セマンティクスはすべて不変で NFR 1.1〜1.5 / 2.1〜2.2 /
3.1〜3.2 を満たす。

RESULT: approve
