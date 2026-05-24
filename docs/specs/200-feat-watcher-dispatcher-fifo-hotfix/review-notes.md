# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-200-impl-feat-watcher-dispatcher-fifo-hotfix
- HEAD commit: 0151643（feat/docs 4 commit: da5398c / 48e3330 / 82df8c3 / 0151643）
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 解釈。
  flag 観点の細目は適用せず、通常の 3 カテゴリ判定のみ実施。

## Verified Requirements

- 1.1 — `_dispatcher_run` の `sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])`（issue-watcher.sh）/ test-order.sh Case A/C/D
- 1.2 — hotfix 不在時は全件 number 昇順。test-order.sh Case C `[3,7,9]`
- 1.3 — 両クエリ `--search "... sort:created-asc"` で母集団取得、最終 tier 内順序は `.number` 昇順で確定
- 1.4 — 投入ループ（issue-watcher.sh:6733〜、`echo "$issues" | jq -c '.[]'` feed:6826）以降の Pre-Claim Filter / Open Design PR Guard / Path Overlap Gate / slot 探索が無変更。diff hunk は LABEL 定義(95) と `_dispatcher_run`(6652) の 2 箇所のみ
- 2.1 — hotfix tier=0 を先頭に配置。test-order.sh Case A/B/D
- 2.2 — 同一 tier 内 number 昇順。test-order.sh Case A/C/D
- 2.3 — 複数 hotfix も number 昇順。test-order.sh Case D `[40,88,12]`
- 2.4 — `(.labels // []) | map(.name) | index($hotfix)` で null/欠落を非 hotfix 安全側へ。test-order.sh Case A/E（#202 labels キー欠落 / #203,#2 null）
- 2.5 — tier は `if hotfix then 0 else 1` の 2 値のみ。多段優先度なし（コードレビュー観点）
- 3.1 — 上限超過時も tier 優先 + number 昇順で先頭選択。test-order.sh Case A/B
- 3.2 — hotfix tier と全候補をそれぞれ `sort:created-asc` + `--limit 5` で取得し最古を母集団先頭に確保。境界シナリオ（hotfix が全候補より古い / hotfix が新しく非 hotfix が 6 件以上 / hotfix 不在で非 hotfix 6 件）を独立に検証し、最古 hotfix・最古非 hotfix のいずれも取りこぼさないことを確認
- 3.3 — `DISPATCH_LIMIT=5` を各クエリの `--limit` に固定。limit の意味（1 サイクルで評価する候補件数上限）を据え置き
- 4.1 — 両 labels スクリプトの `LABELS` 配列に `hotfix|d93f0b|...` を追加
- 4.2 — live（.github/scripts/idd-claude-labels.sh:80）と template（repo-template/.github/scripts/idd-claude-labels.sh:76）双方に追加
- 4.3 — 既存 `EXISTING_LABELS` 連想配列 lookup（live:116 / template:112）を流用、冪等性を保持
- 4.4 — labels diff は新規 1 行追加のみ。既存ラベルの name/color/description は無変更
- 5.1 — env var 名・exit code・ログ prefix 無変更（`LABEL_HOTFIX` 追加のみ、終端ログ・count==0 経路不変）
- 5.2 — 既存 `LABEL_*` 変数・labels 定義無変更
- 5.3 — 両クエリ空 → `issues=[]` → count==0 → `処理対象の Issue なし` + `return 0`（issue-watcher.sh:6715-6720）が無変更で維持
- 5.4 — README.md に「候補の処理順: FIFO + hotfix 優先（#200）」節 + migration note（新しい順 → 古い番号順）追記
- NFR 1.1 — shellcheck: labels 両スクリプト + test-order.sh は exit 0 警告ゼロ。issue-watcher.sh は既存 SC2317(info) 5 件のみ（行番号 987/1241/2651/5263/5777 = 本変更前から +4 シフト、新規警告ゼロ）
- NFR 1.2 — labels 追加のみ、削除・改名なし
- NFR 2.1 — 最終 tier 内順序を `.number` で確定し決定的。test-order.sh Case F（同一入力 → 同一出力）

## Findings

なし

## Summary

requirements.md の全 numeric ID（1.1〜1.4 / 2.1〜2.5 / 3.1〜3.3 / 4.1〜4.4 / 5.1〜5.4 / NFR 1.1〜1.2 / NFR 2.1）が実装・テストでカバーされている。本体 `_dispatcher_run` の jq 式と test-order.sh の jq 式は byte-identical でドリフトなし（複製検証の限界は impl-notes に明記）。test-order.sh は PASS=6 FAIL=0、shellcheck は新規警告ゼロ。Req 3.2 の limit 境界跨ぎは独立に複数シナリオで再検証し取りこぼしなしを確認。投入ループ以降は無変更で boundary 逸脱・後方互換性破壊なし。

RESULT: approve
