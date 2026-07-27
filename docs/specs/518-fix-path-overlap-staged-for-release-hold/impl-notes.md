# 実装ノート（#518）

## 概要

dispatch × multi-branch（`BASE_BRANCH != PROMOTION_TARGET_BRANCH`）文脈で、`staged-for-release`
を付与された Issue を **他 holder ラベル（例 `ready-for-review`）併存の有無に関わらず** holder
集合から除外する。#221 は holder ラベル集合の「クエリ側減算」のみで、併存ラベル経由でクエリに
マッチする staged 済み Issue が holder に残る根因があった。本 Issue は列挙結果への **post-filter**
で確実に除外する（#221 Req 1.4 を意図的に上書き）。

## 変更ファイル

- `local-watcher/bin/modules/path-overlap.sh`
  - `po_resolve_staged_drop_label`（新設 / 純粋関数）: dispatch×multi-branch のみ drop 対象
    `staged-for-release` を返し、それ以外（single-branch / promote / 判定不能）は空文字。判定条件は
    `po_resolve_holder_labels` の multi-branch 判定と完全一致。`${LABEL_STAGED_FOR_RELEASE:-...}` 参照。
  - `po_collect_inflight_issues`: 第 3 引数 `drop_staged_label`（`${3:-}` / 空=drop なし）追加。
    `--json number` → `--json number,labels`（同一 API に labels 追加のみ）。列挙ループを
    `jq -c '.[]'` のオブジェクト反復へ変更し `.number` 抽出。drop 対象ラベルを持つ Issue は
    `po_load_edit_paths` を呼ぶ前に `continue` で除外し、NFR 3 ログを 1 行出力。
  - `po_check_dispatch_gate` / `po__visibility_evaluate_candidate`（両経路）: `drop_label` を
    `po_resolve_staged_drop_label "dispatch"` で解決し第 3 引数で注入（Req 3 一貫性）。
- `local-watcher/test/po_staged_holder_dropfilter_test.sh`（新規 / 22 assertions）
- `README.md`「holder ラベル集合の base 相対化（#221）」節およびログ出力節に #518 の精緻化を追記。

## 設計判断（推奨方針からの逸脱）

- 推奨方針にほぼ準拠。ラベル判定は `jq -r --arg lbl '[.labels[].name] | index($lbl) // empty'`
  を採用（未信頼入力を `--arg` 経由の厳密一致で扱い、フィルタ文字列へ inline 展開しない / #318）。
- `.number` 抽出時に `[ -z "$n" ] && continue` を維持し、drop なし経路の出力等価性（NFR 1）を保全。
  数値バリデーション追加は行わず、旧挙動と byte 等価な列挙ロジックを維持した。
- fail-safe: `drop_staged_label` が空、または labels が null / 欠落で jq が失敗する場合は
  `2>/dev/null || echo ""` で has_staged を空にし、drop せず holder に残す（Req 4.1 安全側）。

## テスト観点（Red→Green 確認済み）

- 実行コマンド: `bash local-watcher/test/po_staged_holder_dropfilter_test.sh` → PASS 22 / FAIL 0
- Red 確認: post-filter 抜きの旧 collector を再現し、staged+ready 併存 Issue が holder に残る
  （union に `local-watcher/` を含む）ことを観測。本実装で union=`README.md` のみに除外される。
- 既存回帰: `po_apply_awaiting_slot_test.sh`(19) / `po_sticky_comment_helpers_test.sh`(10) /
  `repo_prefix_log_test.sh`(36) 全 pass。
- 静的解析: `bash -n` OK / `shellcheck`（module + test）警告ゼロ。

## AC Traceability（1 要件 1 行）

| AC | 担保テスト |
|---|---|
| 1.1 | `po_resolve_staged_drop_label` Case 1 + collector Case A（staged 併存除外→union=README.md） |
| 1.2 | collector Case A（holders[local-watcher/] 未計上 / holders[README.md]=41） |
| 1.3 | Case A で union から脱落 → 呼び出し側 overlap=0 経路（`po_check_dispatch_gate` 既存挙動）で担保 |
| 2.1 | `po_resolve_staged_drop_label` Case 2/3（single-branch → 空 = holder 維持） |
| 2.2 | `po_resolve_staged_drop_label` Case 4（promote → 空 = holder 維持） |
| 2.3 | collector Case B（drop なし = 従来どおり staged 併存 Issue を holder 計上 / ゼロ差分） |
| 3.1 / 3.2 | 両呼び出し元が `po_resolve_staged_drop_label "dispatch"` で同一 drop ラベルを解決・注入（コード配線 + Case A の除外規則） |
| 4.1 | collector Case D（labels 欠落 Issue は drop されず holder 維持） |
| 4.2 | `po_resolve_staged_drop_label` Case 5/6（不明 context / 省略 → 空 = holder 維持） |
| NFR 1.1 | collector Case B（drop なし union 等価）+ Red 確認（旧挙動一致） |
| NFR 1.2 | collector Case E（staged 不在 Issue は drop_label 指定でも全 holder 維持） |
| NFR 2.1 / 2.3 | collector Case A（`gh issue list` 1 回 / `--json number,labels` で追加 API なし） |
| NFR 2.2 | `po_load_edit_paths` は drop されなかった Issue 各 1 回（既存構造不変） |
| NFR 3.1 | collector Case A（`holder-set excluded staged issue=#40 label=staged-for-release` ログ出力） |

## 確認事項

- **requirements.md Open Questions（遷移プロセッサ）**: gitflow + promote 無効構成では、
  impl PR が develop merge 後も `ready-for-review` が Issue に残置し続ける（除去処理が
  promote-pipeline 側にしかない）。本 Issue は holder 除外で実害（新規 Issue の awaiting-slot
  恒久滞留）を解消するが、`ready-for-release`→`staged-for-release` の自動遷移や `ready-for-review`
  残置の解消は **Out of Scope**（別 Issue 候補）。ラベルライフサイクル上の残置問題は本 Issue
  完了後も残る旨を記録する。運用者は手動で `staged-for-release` を付与する既存運用を前提とする。
- **#221 Req 1.4 の上書き**: 本実装は #221 Req 1.4（併存時 holder 維持）を意図的に上書きする。
  #221 の当該挙動を検証する既存テスト fixture は存在しなかった（`po_collect_inflight_issues`
  を直接検証するテストは本 Issue で新設した `po_staged_holder_dropfilter_test.sh` が初）ため、
  既存 fixture の破壊的更新は発生していない。
- **repo-template 同期**: `path-overlap.sh` は `install.sh` 経由で `$HOME/bin/modules/` へ配布
  される構造で `repo-template/` 配下に複製が無いため、repo-template 同期は不要（確認済み）。
  `.claude/{agents,rules}` は未変更で byte 一致を確認済み。

## 検証サマリ

- `bash -n local-watcher/bin/modules/path-overlap.sh` — OK
- `shellcheck local-watcher/bin/modules/path-overlap.sh local-watcher/test/po_staged_holder_dropfilter_test.sh` — 警告ゼロ
- テスト: 新規 22 pass / 既存 po_* 系 65 pass、全 green

STATUS: complete
