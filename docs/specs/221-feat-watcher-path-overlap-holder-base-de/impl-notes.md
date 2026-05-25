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

### Round 2 是正（task 2〜5）

Reviewer round=1 の reject（task 2〜5 未実装で Req 1.1 / 1.2 / 1.3 / 4.2 / NFR 3.1 の観測可能挙動が不成立、task 4 fixture 欠如）に対し、tasks.md task 2〜5 を実装した。

- **task 2（Finding 1 / 2 / 3 / Req 1.2 / 1.4 / 2.2 / 3.2 / 4.2 / NFR 1.1 / 1.2 / 2）**: `po_collect_inflight_issues` に第 2 引数 `holder_labels`（CSV、default = 現行 7 ラベル集合）を追加し、`search_query` を CSV から動的に組み立てるよう変更した。ラベル → OR clause の組み立ては新設ヘルパー `po_build_label_or_clause`（CSV をカンマ分割し各要素を前後空白除去・空要素スキップして `label:"X" OR ...` を生成）に切り出した。第 2 引数省略時の query は変更前のヒアドキュメント固定 query と**文字列完全一致**する（test の Case 5 で検証）。CSV が空 / 不正で OR clause が空になる場合は full 7 ラベル集合へ fallback する（Req 4.2 / Case 5c）。`st-failed` / `awaiting-slot` 除外と `gh issue list` 1 回 / 候補ごと `po_load_edit_paths` 1 回の構造は変更していない（NFR 2）。
- **task 3（Finding 1 / 4 / Req 1.1 / 1.3 / 3.1 / NFR 3.1）**: `po_check_dispatch_gate` 内で `po_resolve_holder_labels "dispatch"` を呼び holder 集合を解決し、`po_collect_inflight_issues "$candidate" "$holder_labels"` へ注入した（orphan 解消）。NFR 3.1 ログは、解決集合が `po_resolve_holder_labels "promote"`（= full 集合）と**異なる**場合のみ `po_log "holder-set context=dispatch excluded=<staged-for-release> base=<BASE_BRANCH>"` を出力する実装とした。full と一致する single-branch / 判定不能では出力せずゼロ差分を保つ（NFR 1.1）。`po_check_dispatch_gate` のシグネチャ（`$1 candidate` / `$2 labels_json`）と opt-in gate / fail-open / overlap ロジックは不変で、issue-watcher.sh 本体は未変更。
  - 実装上の判断: full 集合の比較対象を別ハードコードせず `po_resolve_holder_labels "promote"` の戻り値で取得することで、full 集合定義の二重管理を避け、将来 full 集合のラベルが増減しても除外判定が自動追従するようにした。
- **task 4（Finding 5 / Req 1.1 / 2.1 / 4.1 / NFR 1.1）**: `test-fixtures/test-holder-labels.sh` を新設（ディレクトリごと作成、実行ビット付与、shebang `#!/usr/bin/env bash`）。`gh` をシェル関数でスタブ化し `--search` 引数を捕捉する方式で、実 API を呼ばずに query 構築を検証する。検証ケース: 真理値表 4 ケース + 空 context（Req 1.1 / NFR 1.1 / 2.1 / 4.1）、search_query ゼロ差分（NFR 1.1）、6 ラベル CSV 注入時の SfR 非含有（Req 1.2）、空 CSV fallback（Req 4.2）の計 8 ケース。全 PASS / 非ゼロ exit on fail。
- **task 5（Req 1.1 / 2.1 / NFR 1.1 / NFR 3.1）**: README の「Path Overlap Checker (Phase E)」節「in-flight 集合の定義」に base 相対化の表と gitflow 運用ガイドを追記し、観測ログ節に `holder-set` 除外ログの grep 例を追記した。single-branch ゼロ差分の後方互換を明記。

#### 検証結果（Round 2）

- `shellcheck local-watcher/bin/modules/promote-pipeline.sh docs/specs/221-feat-watcher-path-overlap-holder-base-de/test-fixtures/test-holder-labels.sh` → 警告ゼロ（promote-pipeline.sh は本変更前後で警告増減なし。test fixture は SC2034 / SC2317 を file-level disable コメントで抑止。これは source した module の関数が変数を間接参照する / gh スタブが間接呼び出しされる shellcheck の偽陽性であり、実コードに問題はない）。
- `bash test-holder-labels.sh` → `PASS=8 FAIL=0` / exit 0。
- search_query ゼロ差分: 変更前のヒアドキュメント固定文字列 `is:open is:issue (label:"claude-claimed" OR ... OR label:"staged-for-release") -label:"st-failed" -label:"awaiting-slot"` と、第 2 引数省略時に組み立てられる query が文字列一致することを test Case 5 で確証（最重要の後方互換ポイント）。
- module 単体 source smoke: `po_build_label_or_clause` の空 CSV → 空文字列（fallback トリガー）、空白混じり / 重複カンマ → 正しくトリム・スキップを確認。

#### Round 2 の AC 対応テスト一覧（追加・是正分）

| AC | 担保したテスト |
|---|---|
| Req 1.1 | test-holder-labels.sh Case 1（dispatch×multi-branch → 6 ラベル CSV）+ task 3 で gate へ注入 |
| Req 1.2 | test-holder-labels.sh Case 5b（6 ラベル CSV で SfR 非含有 query 構築） |
| Req 1.3 | dispatch gate が注入集合で overlap=0 → claim 続行する経路（task 3 wiring。観測は dogfood E2E で確認予定） |
| Req 1.4 | `po_collect_inflight_issues` の OR query が併存ラベル（claude-claimed 等）でヒットする既存挙動を維持（6 ラベルは常時集合内） |
| Req 2.1 | test-holder-labels.sh Case 3（promote → full 7 ラベル CSV） |
| Req 2.2 | promote 経路は別経路（`pp_collect_merged_issues`、holder ラベル query 不使用）で挙動不変。default 集合固定で契約保全 |
| Req 3.1 / 3.2 / 3.3 | `po_resolve_holder_labels` が単一契約として context ごとに集合を決定（Case 1〜4b）。引数注入で副作用なし |
| Req 4.1 | test-holder-labels.sh Case 4 / 4b（不明 / 空 context → full 集合 fail-safe） |
| Req 4.2 | test-holder-labels.sh Case 5c（空 CSV → full 集合 fallback） |
| NFR 1.1 | test-holder-labels.sh Case 2（single-branch → full）+ Case 5（search_query 文字列一致） |
| NFR 1.2 | 6 基本ラベルを常時含む invariant（Case 1 で SfR のみ差分であることを確認） |
| NFR 2.1 / 2.2 | `gh issue list` 1 回 / `po_load_edit_paths` 1 回の構造を変更していない（コードレビュー / 構造不変） |
| NFR 3.1 | task 3 の `holder-set ...` ログ（解決集合 != full 時のみ出力）。multi-branch で除外発生時に判別可能 |

## 確認事項

- design.md / requirements.md / tasks.md と本実装の間に矛盾は検出していない。本 task のスコープ（新規関数追加のみ）では既存呼び出し経路に影響を与えていない（`po_resolve_holder_labels` は task 3 で初めて `po_check_dispatch_gate` から呼ばれる）。
- Round 2 で task 2〜5 を実装した結果、`po_resolve_holder_labels` は `po_check_dispatch_gate` から呼ばれる接続済み関数となり、orphan 状態は解消した。
- design.md L160 等の行番号参照は task 1 commit 後にズレが生じているが、これは impl-notes の記述上の問題であり実装には影響しない（design.md は書き換えていない）。

STATUS: complete
