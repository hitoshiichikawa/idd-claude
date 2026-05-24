# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-24T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-200-impl-feat-watcher-dispatcher-fifo-hotfix
- HEAD commit: 86eca91989dd7030760b620ccc9dac06298a5b64
- Compared to: main..HEAD

CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため opt-out 扱い。flag 観点の
細目は適用せず、通常の 3 カテゴリ判定（AC 未カバー / missing test / boundary 逸脱）のみを
行った。本 Issue は `tasks.md` / `design.md` 不在（PM → Developer 直行）のため、boundary
判定は requirements.md の Introduction / Out of Scope に明示された境界制約に照らして行った。

## Verified Requirements

- 1.1 — `_dispatcher_run` の jq `sort_by([(if ._is_hotfix then 0 else 1 end), .number])` で番号昇順投入（issue-watcher.sh）。test-order.sh Case A/C/D
- 1.2 — hotfix 不在時は全件番号昇順。test-order.sh Case C `[3,7,9]`
- 1.3 — 母集団取得を両クエリ `sort:created-asc` で行い、最終 tier 内順序は `.number` 昇順で確定（番号昇順 ≒ created-asc の等価観測）
- 1.4 — pick 順序以外（Pre-Claim Filter / Open Design PR Guard / Path Overlap / claim / slot fork）は無変更。removed 行は元の単一クエリ構築のみで `count=` 以降の `while read` ループと要素 shape（number,title,body,url,labels）は不変（`map(del(._is_hotfix))` で内部キー除去）
- 2.1 — hotfix を tier 0、非 hotfix を tier 1 に写像し先行投入。test-order.sh Case A/B/D
- 2.2 — 同一ティア内は `.number` 昇順。test-order.sh Case A/C/D
- 2.3 — 複数 hotfix も番号昇順。test-order.sh Case D `[40,88,12]`
- 2.4 — `(.labels // [])` で欠落/null を空配列フォールバック → 非 hotfix 安全側。test-order.sh Case A(202/203)/E
- 2.5 — tier は `if hotfix then 0 else 1` の 2 値のみ。多段優先度なし
- 3.1 — hotfix ティア / 全候補を各々 created-asc + `--limit 5` で取得後 tier 優先 + 番号昇順評価。test-order.sh Case A/B
- 3.2 — 2 クエリ各々 created-asc 取得により最古 Issue / 最古 hotfix が母集団先頭に必ず入り limit 切り出しで漏れない。test-order.sh Case B `[120,305]`
- 3.3 — `DISPATCH_LIMIT=5` を両クエリ `--limit` に維持し件数上限の意味を据え置き
- 4.1 — 両 labels スクリプトの `LABELS` 配列に `hotfix` 追加（Reviewer が shellcheck exit 0 で実行確認）
- 4.2 — `.github/scripts/idd-claude-labels.sh`（live）と `repo-template/.github/scripts/idd-claude-labels.sh`（template）双方に追加済み
- 4.3 — 既存 `EXISTING_LABELS` チェック（`--force` 無しは skip）を流用し冪等性を担保（diff で機構無変更を確認）
- 4.4 — diff は `hotfix` 1 行の追加のみ。既存ラベルの name/color/description 無変更
- 5.1 — env var 名 / exit code / ログ prefix 不変（`LABEL_HOTFIX` 定数追加のみ、終端ログ・return 経路無変更）
- 5.2 — 既存ラベル名（claim 用 / 除外用）無変更
- 5.3 — 両クエリ空 → `issues=[]` → `count=0` → 既存「処理対象の Issue なし」+ return 0 経路を保持
- 5.4 — README に「候補の処理順: FIFO + hotfix 優先（#200）」節と migration note を追記
- NFR 1.1 — `shellcheck` を両 labels スクリプトで exit 0、issue-watcher.sh は warning 以上ゼロ（既存 SC2317 info のみ残置）で Reviewer 再実行確認
- NFR 1.2 — labels diff は追加のみ。削除/改名なし
- NFR 2.1 — 同一入力で同一順序（決定的安定ソート）。test-order.sh Case F

## Findings

なし

## Summary

全 numeric AC（Req 1.1〜5.4）と NFR（1.1/1.2/2.1）が実装または test-order.sh のスモーク
テスト（Reviewer 再実行で PASS=6 FAIL=0）でカバーされている。pick 順序以外の Dispatcher
挙動と後方互換契約（env / exit / log prefix / 既存ラベル）は不変で boundary 逸脱なし。
両 labels スクリプトと watcher の shellcheck も clean（新規警告ゼロ）。

RESULT: approve
