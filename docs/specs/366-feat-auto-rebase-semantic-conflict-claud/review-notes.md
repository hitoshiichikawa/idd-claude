# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-06-22T13:40:00Z -->

## Reviewed Scope

- Branch: claude/issue-366-impl-feat-auto-rebase-semantic-conflict-claud
- HEAD commit: 40013eee98031673c4361b265fe4a66e0271955c
- Compared to: main..HEAD
- 対象 diff（commit 3 件）:
  - `2f09a9c feat(#366)` 本実装
  - `2121e11 docs(spec)` 要件定義
  - `40013ee fix(#366)` round=1 是正（observability 強化 + dismiss/escalate 近接テスト追加）
- 重点確認: round=1 Findings 1〜4（Req 9.1 / 9.2 / 9.3 / NFR 3.2）の解消可否

## Verified Requirements

（round=1 で verified 済みの 1.x〜8.x / NFR 1〜5 はすべて回帰なし。本 round=2 では
round=1 reject 4 件の解消確認を中心に再検証）

- **9.1 (Finding 1 解消確認)** — `ar_handle_pr` の semantic 関連 `ar_log` 行すべてに
  `semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED}` フィールドを追記
  （`local-watcher/bin/modules/auto-rebase.sh:1066,1080,1089,1100,1109`）。
  新規 `action=skip-claude-failed` 防御的 log 行を 1a' に追加（同 :1080）。
  新規 `action=skip-gate-off` log 行を `ar_apply_semantic` 直前に追加（同 :1222）。
  Req 9.1 enum（`attempt` / `skip-gate-off` / `skip-idempotent` / `skip-claude-failed`
  / `escalate-needs-decisions`）が全件出力経路を持つことを `grep` で確認
- **9.2 (Finding 2 解消確認)** — rebase 完了 `case` ブロック / semantic 完了 `case`
  ブロックすべての `ar_log` 行に `outcome=resolved|timeout|dirty|push-failed|fetch-failed`
  を併記（同 :1131,1139,1147,1155,1163,1234,1241,1250,1258）。`attempts=${_semantic_attempts}`
  を末尾に追加。gate ON 時のみ `_semantic_log_suffix` 経由で `attempts=${new_attempts:-1}`
  を rebase 完了 log にも併記
- **9.3 (Finding 3 解消確認)** — 新グローバル `_AR_SEMANTIC_BUCKET` を `ar_handle_pr` 内
  でセット（resolved / failed / escalated / skipped の 4 値）。`process_auto_rebase`
  ループ末尾でローカル counter `semantic_resolved` / `semantic_failed` /
  `semantic_escalated` / `semantic_skipped` をインクリメントし、サマリ行に
  `semantic-resolved=N, semantic-failed=N, semantic-escalated=N, semantic-skipped=N`
  を追記（同 :1346）。gate OFF 時は bucket が "" のままで 4 種すべて 0 → 旧サマリ
  形式と数値的に等価（NFR 1.1 互換）
- **NFR 3.2 (Finding 4 解消確認)** — `ar_semantic_test.sh` Section 7 / Section 8 を新規追加
  - Section 7（`ar_apply_semantic_claude`）: 10 ケース
    - (a) `ar_dismiss_all_approvals` 呼出
    - (b) `needs-rebase --remove-label` / `ready-for-review --add-label` 呼出
    - (c) コメント本文に before/after SHA + `<!-- idd-claude:auto-rebase-semantic`
      マーカー
    - 追加: `claude-failed` ラベル付与なし（Req 7.6 / 8.2 安全性核心）
    - 追加: dismissal 失敗時の rc=1 早期 return + 後段 label 変更なし
  - Section 8（`ar_semantic_escalate_needs_decisions`）: 8 ケース
    - `needs-decisions --add-label` 付与
    - `gh pr comment` 1 回呼出
    - `claude-failed` ラベル付与なし（Req 7.6 / 8.2 安全性核心）
    - コメント本文に累積 attempts(4) / budget env 名 / head SHA
    - needs-decisions 付与失敗時 rc=1（Req 8.4）
  - ヘルパ `grep_count` を追加して `grep -c` の rc=1 (0 マッチ) 問題を回避
- **テスト regression** — reviewer 側で `bash local-watcher/test/ar_semantic_test.sh` を
  再実行: `PASS=84 FAIL=0`。`bash -n` / `shellcheck` も警告ゼロ

## Findings

なし。round=1 で指摘した 4 件はすべて機械的に解消され、再 regression もクリーン。

## Summary

round=1 reject の 4 Findings（Req 9.1 log フィールド + skip-gate-off / Req 9.2 outcome +
attempts / Req 9.3 サマリ subtotal / NFR 3.2 dismiss・escalate 近接テスト）は、
`local-watcher/bin/modules/auto-rebase.sh` の observability 拡張と
`local-watcher/test/ar_semantic_test.sh` の Section 7 / 8 追加（計 18 新規アサーション）で
すべて解消。84 ケース全 PASS、shellcheck / bash -n クリーン、agents / rules の
root↔repo-template byte 一致を確認。AC 未カバー / missing test / boundary 逸脱 のいずれも
検出されず。

RESULT: approve
