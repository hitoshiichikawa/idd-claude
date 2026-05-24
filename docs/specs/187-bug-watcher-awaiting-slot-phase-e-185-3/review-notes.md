# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T13:02:03Z -->

## Reviewed Scope

- Branch: claude/issue-187-impl-bug-watcher-awaiting-slot-phase-e-185-3
- HEAD commit: 5f2cd824e17d17cfd449b5f1d097c5d527d1b83f
- Compared to: main..HEAD（実装本体は bbe3bc3、要件/ノートは 5f2cd82）

本 Issue は Architect 非経由のため tasks.md / design.md は存在しない。requirements.md の
AC を正本としてレビューした。境界の照合は requirements.md が編集対象に指定した
`local-watcher/bin/modules/promote-pipeline.sh` を正本とする。CLAUDE.md に
`## Feature Flag Protocol` 節は存在しないため opt-out 解釈（通常の 3 カテゴリ判定のみ。
flag 観点は適用しない）。

## Verified Requirements

- 1.1 — ラベル付与の成否に依存せず sticky comment 投稿/更新へ到達する構造へ組み替え（promote-pipeline.sh:440-507、early return 廃止）。テスト Case A/B/E（po_apply_awaiting_slot_test.sh）
- 1.2 — ラベル付与失敗（gh issue edit rc!=0）でも投稿/更新を継続（同 440-445 で else 分岐）。Case A（新規 create 1 回）/ Case E（コメント取得失敗でも best-effort で create 1 回）で検証
- 1.3 — 重複 top-level path と awaiting 状態を提示する本文（promote-pipeline.sh:467-481、overlap_section + 説明文）。本文フォーマットは無変更で踏襲（Out of Scope 準拠）
- 1.4 — 既存 marker `<!-- idd-claude:awaiting-slot:v1 -->` 検出時は新規投稿せず PATCH 更新（promote-pipeline.sh:491-505）。Case B（label fail）/ Case D（label success）で「新規 comment 0 回 / PATCH 1 回」、PATCH 対象 id (555111) を検証
- 2.1 — `PATH_OVERLAP_CHECK = "true"` 厳密一致 opt-in gate（promote-pipeline.sh:541）。本 diff 対象外で無変更
- 2.2 — overlap 検出時はラベル/コメント成否に関わらず dispatch skip。呼び出し側 po_check_dispatch_gate:589 の無条件 `return 1` が決定し、本 diff 対象外で無変更
- 2.3 — 失敗でもサイクルを異常終了させない。po_apply_awaiting_slot は致命 return 1 を廃止し常に 0 を返す。Case E（ラベル付与失敗 + コメント取得失敗でも rc=0）で検証
- 2.4 — env var 名 / ログ出力先 / ラベル名 / ラベル遷移契約は無変更。diff はラベル付与ブロック（435-445）に限定。`LABEL_AWAITING_SLOT` / marker / 本文は不変
- 3.1 — ラベル付与失敗時に候補 Issue 番号を含む WARN（promote-pipeline.sh:444、`po_warn ... #${issue_number}`）。Case A（#42）/ Case E（#99）で検証
- 3.2 — overlap 検出ログ（promote-pipeline.sh:578/582）は本 diff 対象外で形式不変
- NFR 1.1 — `PATH_OVERLAP_CHECK` 無効時は gate（541）で早期 return 0。本修正経路に到達せず導入前と完全同一
- NFR 1.2 — 戻り値の意味（dispatch skip）は呼び出し側 584-589 で確定。po_apply_awaiting_slot の戻り値が常に 0 へ変わっても skip 判定に影響しないことを確認
- NFR 2.1 — sticky comment 冪等性（既存 marker → PATCH、無ければ create）は無変更。Case B/D で 1 件維持を検証

## 検証実行

- `bash local-watcher/test/po_apply_awaiting_slot_test.sh` → PASS: 19, FAIL: 0（reviewer 再実行で確認）
- `shellcheck local-watcher/bin/modules/promote-pipeline.sh local-watcher/test/po_apply_awaiting_slot_test.sh` → exit 0（警告ゼロ）
- `git diff main..HEAD -- local-watcher/bin/modules/promote-pipeline.sh` で変更が 435-445 行のラベル付与ブロックに限定され、overlap 判定 / in-flight 列挙 / clear ロジック / 本文フォーマット / marker / 呼び出し側 dispatch skip が不変であることを確認

## Findings

なし

## Summary

全 AC（1.1〜1.4 / 2.1〜2.4 / 3.1〜3.2 / NFR 1.1〜1.2 / NFR 2.1）に対応する実装が存在し、
観測可能な挙動（ラベル付与失敗時もコメント投稿を試行 / 失敗時 WARN / 既存 marker の PATCH 冪等更新 /
ラベル成功時の回帰）に対応テストが揃っている。変更はラベル付与ブロックに限定され、戻り値の意味
（dispatch skip）・env var・ラベル名・marker・本文フォーマットは不変で後方互換性を維持している。
boundary 逸脱・AC 未カバー・missing test いずれも検出されなかった。

RESULT: approve
