# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules/promote-pipeline.sh` に `po_resolve_holder_labels`（`$1=context`）を `po_collect_inflight_issues` の直前に新設し、design.md D3 の真理値表どおり dispatch×multi-branch のみ `staged-for-release` を除外、それ以外（dispatch×single-branch / promote / 不明 context）は full 7 ラベル CSV を返す fail-safe を実装した。
- 重要な判断:
  - 6 基本ラベルおよび `staged-for-release` はすべて `$LABEL_*` 定数を参照して組み立て、ラベル文字列のハードコード重複を排除した（task 明記の `$LABEL_STAGED_FOR_RELEASE` を含む）。定数未束縛時にも安全側へ倒すため `${LABEL_X:-リテラル既定}` 形式で fallback を付与した（source 順序事故・SC2154 双方への保険）。
  - branch 比較は `${BASE_BRANCH:-main}` / `${PROMOTION_TARGET_BRANCH:-main}` の既定付き展開で行い、未束縛時は single-branch（== main）扱い → full 集合（安全側）になる。
  - 判定不能（不明 context / 空 context）は明示分岐を設けず、dispatch×multi-branch 以外を一律 full 集合とする実装で Req 4.1 を満たす（fail-safe full）。
- 検証: `shellcheck local-watcher/bin/modules/promote-pipeline.sh` は exit 0 / 警告ゼロ（本変更前後で増減なし）。関数単体のスモークで真理値表 5 ケース（dispatch×multi / dispatch×single / promote / 不明 / 空 context）全 PASS を確認。
- AC との対応（本 task が担保した範囲）:
  - Req 1.1 / NFR 1.2: dispatch×multi-branch で 6 ラベル CSV を返し、6 基本ラベルを常時含む invariant をスモークで確認。
  - NFR 1.1: dispatch×single-branch（main/main）で full 集合を返すことを確認（ゼロ差分）。
  - Req 2.1: promote で full 集合（staged-for-release 維持）を確認。
  - Req 4.1: 不明 / 空 context で full 集合（fail-safe）を確認。
  - Req 3.1 / 3.2 / 3.3: context ごとに集合を決定する単一関数として表現し、副作用なし（stdout のみ / グローバル変数は読み取りのみ）。
  - 注: 上記スモークは本 task の動作確認であり、tasks.md task 4 の正式なユニット/スモーク fixture（`test-holder-labels.sh`）は別 task で追加する。
- 残存課題（次 task=2 への影響）: なし。task 2 では `po_collect_inflight_issues` の第 2 引数 default を本関数の full 集合と文字列一致させる必要がある。本関数の full CSV は `claude-claimed,claude-picked-up,awaiting-design-review,ready-for-review,needs-iteration,needs-rebase,staged-for-release`（既存 `search_query` の OR 順序と同一）であり、task 2 の default 集合と整合させること。

## 確認事項

- design.md / requirements.md / tasks.md と本実装の間に矛盾は検出していない。本 task のスコープ（新規関数追加のみ）では既存呼び出し経路に影響を与えていない（`po_resolve_holder_labels` は task 3 で初めて `po_check_dispatch_gate` から呼ばれる）。
