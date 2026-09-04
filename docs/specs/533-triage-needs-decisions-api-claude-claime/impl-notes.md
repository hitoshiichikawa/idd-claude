# 実装ノート（#533）

## 変更点サマリ

Triage が needs-decisions を判定したときの「決定事項コメント投稿 + `claude-claimed →
needs-decisions` ラベル遷移」を、成否を握り潰さず検証する形に修正した。

- `local-watcher/bin/modules/slot-worker.sh`
  - 従来 `_slot_run_issue` 内に inline だった needs-decisions 分岐（COMMENT 組み立て +
    `gh issue comment ... || true` + `gh issue edit ... || true` + 無条件成功ログ）を、
    testable な専用ヘルパー **`_slot_publish_needs_decisions`** へ切り出し（`_slot_run_issue`
    からは呼び出しに置換）。CLAUDE.md §1（inline 肥大回避・隔離抽出前提）に整合。
  - コメント投稿は `>/dev/null 2>&1 || true` をやめ **rc を検証**。成功時のみ
    「決定事項を起票しました」ログを出す。失敗時は `slot_warn`（Issue 番号 + `operation=comment`）。
  - ラベル遷移を **`grl_retry_label_op` 経由**（`--remove-label claude-claimed --add-label
    needs-decisions`）に変更し rc を検証。成功時のみ「claude-claimed 取り消し済」ログ。
    失敗時は `slot_warn`（Issue 番号 + `operation=label-transition`）。gate
    `GH_API_STATE_RETRY_ENABLED`（既定 false）では 1 回実行＝従来 API 消費。rate-limit 起因は
    有限回リトライ、非 rate-limit は即返却（grl_retry_label_op の既存責務）。
  - **宙吊り防止フォールバック `_slot_reclaim_claimed_for_next_cycle`** を追加。コメント投稿 or
    ラベル遷移が失敗したら `claude-claimed` を単独除去（`grl_retry_label_op` 経由 best-effort）し、
    `auto-dev` 保持・claim 系ラベル非在の状態＝次サイクル再 pickup 対象へ戻す。除去自体が失敗
    しても #530 の EXIT trap 回収（`_slot_reclaim_stale_claim`）が最終防波堤。委譲は warn で明示。
  - sequencing: コメントを先に投稿し、成功時のみラベル遷移。コメント失敗時は
    `needs-decisions` を付けず（質問不可視での要回答ラベル付与＝誤誘導を回避）claude-claimed
    のみ除去して次サイクルへ委ねる（次サイクル再 Triage でコメント再投稿。重複許容＝PM 推奨）。
- `local-watcher/test/slot_worker_needs_decisions_publish_test.sh`（新規）
  - 両ヘルパーを `extract_function` で隔離抽出し、gh / grl_retry_label_op / slot_log /
    slot_warn / jq を stub して呼び出しトレースで検証（Case A〜E / 計 25 アサーション）。

## AC トレーサビリティ（1 要件 1 行）

| AC | 担保 |
|---|---|
| 1.1 comment 成功→起票ログ | 新テスト Case A |
| 1.2 comment 失敗→起票ログ非出力 | 新テスト Case C |
| 1.3 comment 失敗→warn | 新テスト Case C（`operation=comment`）|
| 2.1 遷移成功→取り消し済ログ | 新テスト Case A |
| 2.2 遷移失敗→取り消し済ログ非出力 | 新テスト Case B |
| 2.3 遷移失敗→warn | 新テスト Case B（`operation=label-transition`）|
| 3.1 claimed 残留+成功ログ+未到達 を発生させない | 構造（成功ログは A のみ / 失敗は B・C で claimed 除去）|
| 3.2 失敗時 claimed 非残留・次サイクル pickup へ | 新テスト Case B/C/D（フォールバック除去）|
| 3.3 委譲時 未達を warn 明示 | 新テスト Case B（「次サイクル再 pickup へ委譲」）|
| 4.1 rate-limit 有限回リトライ | 遷移を grl_retry_label_op 経由に（Case A/D で raw gh edit 不使用を検証）+ api-rate-guard 既存テスト |
| 4.2 上限到達→claimed 非残留・次サイクルへ | 新テスト Case D |
| 4.3 非 rate-limit→リトライせず失敗 | grl_retry_label_op 既存責務（api-rate-guard 既存テスト）|
| 5.1 成功ログ正確性は gate 非依存 | 構造（rc 検証は gate off/on 共通）+ Case A/B |
| 5.2 claim 非残留は gate 非依存 | 構造 + Case B/C/D |
| 5.3 gate off で各 1 回実行 | grl_retry_label_op gate-off 分岐（api-rate-guard 既存テスト）+ comment は単発 gh |
| 5.4 新規 gate 追加時は安全側 | 新規 gate 追加なし（既存 `GH_API_STATE_RETRY_ENABLED` 活用）→ 該当なし |
| 6.1 claimed+needs-decisions 同時付与を残さない | 遷移は単一 `gh issue edit` の atomic remove+add / 失敗時は claimed 除去（Case B）|
| 6.2 needs-decisions 保持 Issue を pickup 候補から除外 | 既存 server-side filter（`issue-watcher.sh:709`）不変（範囲外）|
| 6.3 最終的にコメント 1 件 + needs-decisions の一貫状態へ収束 | 新テスト Case A |
| NFR 1.1 env/label/exit/ログ出力先不変 | 変更なし（新 gate なし・ラベル名不変）|
| NFR 1.2 成功経路のログ/遷移/戻り値不変 | 新テスト Case A（同一ログ行・遷移・return 0）|
| NFR 2.1 silent fail 回避・各失敗を warn | 新テスト Case B/C/E |
| NFR 2.2 warn に Issue 番号 + 操作種別 | 新テスト Case B/C（`Issue #NUMBER` + `operation=...`）|

## 検証結果（実行コマンド + PASS/FAIL）

- `bash -n local-watcher/bin/modules/slot-worker.sh` → OK
- `shellcheck local-watcher/bin/modules/slot-worker.sh` → 警告ゼロ
- `shellcheck local-watcher/test/slot_worker_needs_decisions_publish_test.sh` → 警告ゼロ
- `bash local-watcher/test/slot_worker_needs_decisions_publish_test.sh` → PASS 25 / FAIL 0
- 既存関連: `slot_worker_reclaim_claim_test.sh`(20/0) / `needs_decisions_auto_test.sh`(77/0) /
  `slot_worker_set_u_guard_test.sh`(11/0) / `slot_worker_spec_html_hook_test.sh`(ok) → 全 PASS

## 同期確認

- 修正対象は `local-watcher/bin/modules/` 配下（install.sh 配布物）。repo-template 側に
  slot-worker.sh の別コピーは存在しない（`find` で確認済み）ため `diff -r` 同期対象外。
- `.claude/{agents,rules}` は不変。

## 確認事項

- なし（requirements.md の Open Question「コメント重複の扱い」は PM 推奨=許容を採用し、冪等
  marker は導入しなかった。次サイクル再 Triage での重複投稿は最終的な一貫状態収束を優先して許容）。

STATUS: complete
