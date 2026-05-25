# Implementation Plan

- [ ] 1. holder ラベル集合決定関数 `po_resolve_holder_labels` を新設する
  - `promote-pipeline.sh` に `po_resolve_holder_labels` 関数を追加する（`$1=context`）
  - `dispatch` × multi-branch（`BASE_BRANCH != PROMOTION_TARGET_BRANCH`）→ `staged-for-release` を除いた 6 ラベル CSV
  - `dispatch` × single-branch（`BASE_BRANCH == PROMOTION_TARGET_BRANCH`）→ full 7 ラベル CSV（ゼロ差分）
  - `promote` → full 7 ラベル CSV（`staged-for-release` 維持）
  - 不明な context 値 / 判定不能 → full 7 ラベル CSV（fail-safe / 安全側）
  - 6 基本ラベル（claude-claimed / claude-picked-up / awaiting-design-review / ready-for-review / needs-iteration / needs-rebase）は常時含む invariant を保つ
  - `$LABEL_STAGED_FOR_RELEASE` 定数を参照し、ラベル文字列をハードコードで重複させない
  - 変数クォート徹底（shellcheck クリーン）
  - _Requirements: 1.1, 2.1, 3.1, 3.2, 3.3, 4.1, NFR 1.1_
  - _Boundary: po_resolve_holder_labels_

- [ ] 2. `po_collect_inflight_issues` を holder ラベル集合引数で動的クエリ化する
  - 第 2 引数 `holder_labels`（CSV）を追加し、default を現行 7 ラベル集合に固定する
  - `search_query` を holder_labels CSV から動的に `label:"X" OR ...` 形式で組み立てる
  - 引数省略時に組み立てるクエリが現行固定クエリと**文字列一致**することを保証する（後方互換ゼロ差分）
  - `st-failed` / `awaiting-slot` 除外は集合非依存で固定維持する
  - CSV が空 / 不正な場合は full 集合へ fallback する（fail-safe / Req 4.2）
  - `gh issue list` 1 回 / 候補ごと `po_load_edit_paths` 1 回の構造を変えない（NFR 2）
  - 変数クォート徹底（shellcheck クリーン）
  - _Requirements: 1.2, 1.4, 2.2, 3.2, 4.2, NFR 1.1, NFR 1.2, NFR 2.1, NFR 2.2_
  - _Boundary: po_collect_inflight_issues_
  - _Depends: 1_

- [ ] 3. `po_check_dispatch_gate` から dispatch 文脈の holder 集合を注入し NFR3 ログを出す
  - `po_resolve_holder_labels "dispatch"` で集合を解決し `po_collect_inflight_issues "$candidate" "$holder_labels"` に渡す
  - 解決集合が full と異なる（staged-for-release 除外）場合に `po_log` で除外を判別可能に出力（例: `holder-set context=dispatch excluded=staged-for-release base=<branch>`）
  - 関数シグネチャ（`$1 candidate`, `$2 labels_json`）は不変に保ち issue-watcher.sh L7025 を変更しない
  - 既存 opt-in gate / fail-open / overlap ロジックは変更しない
  - _Requirements: 1.1, 1.3, 3.1, NFR 3.1_
  - _Boundary: po_check_dispatch_gate_
  - _Depends: 1, 2_

- [ ] 4. holder ラベル集合決定のユニット/スモークテストを追加する
  - `docs/specs/221-feat-watcher-path-overlap-holder-base-de/test-fixtures/test-holder-labels.sh` を新設
  - `po_resolve_holder_labels` を dispatch×multi-branch / dispatch×single-branch / promote / 不明 context の 4 ケースで検証
  - `po_collect_inflight_issues` の引数省略時 search_query が現行固定クエリと文字列一致することを検証
  - shellcheck クリーンを確認する
  - _Requirements: 1.1, 2.1, 4.1, NFR 1.1_
  - _Boundary: po_resolve_holder_labels, po_collect_inflight_issues_
  - _Depends: 1, 2_

- [ ] 5. README に base 相対 holder と gitflow 運用ガイドを追記する
  - 「Path Overlap Checker (Phase E)」節「in-flight 集合の定義」に base 相対化の注記（dispatch base=develop では staged-for-release 除外 / promote target=main では維持）を追加
  - gitflow 運用ガイド（`staged-for-release` と Phase E holder の関係 / `BASE_BRANCH` 設定との連動）を追記
  - NFR3 の除外ログ（`holder-set context=dispatch excluded=staged-for-release`）の grep 例を観測ログ節に追記
  - single-branch 運用ではゼロ差分である旨を明記（後方互換）
  - _Requirements: 1.1, 2.1, NFR 1.1, NFR 3.1_
  - _Depends: 3_
