# Implementation Plan — Phase E: Triage path overlap 検知（hot file 競合予防）

> **方針**: 4 つの独立境界（Triage prompt template / `issue-watcher.sh` の関数群 / `idd-claude-labels.sh` /
> README）を **境界が重ならないタスク列**として並べる。`(P)` 並列可タスクは `_Boundary:_` で
> 担当ファイルを明示する。`issue-watcher.sh` 内では複数関数を追加するが同一ファイル編集の
> ため直列で配置する。Developer は impl-resume 時は task ID 順に着手し、完了ごとに
> `- [x]` 化する（`IMPL_RESUME_PROGRESS_TRACKING` 既定 ON 規約）。

- [x] 1. Triage Prompt Template に `edit_paths` 出力指示を追加
  - `local-watcher/bin/triage-prompt.tmpl` の末尾「## 出力形式」節に additive 拡張として
    `edit_paths` フィールドの出力指示文を追加（既存 5 keys の指示は一切変更しない）
  - JSON schema 例示ブロックに `"edit_paths": [ ... ]` を追記
  - 確信が低い場合は空配列 `[]` を返す旨を明記（omit や null は不可）
  - top-level（1 段目）粒度のみ。サブパスや行番号は不要を明記
  - _Requirements: 2.1, 2.2, 2.3, 2.5_
  - _Boundary: Triage Prompt Template_

- [x] 2. `awaiting-slot` ラベルを `idd-claude-labels.sh` に追加 (P)
  - `repo-template/.github/scripts/idd-claude-labels.sh` の `LABELS=( ... )` 配列末尾に
    `"awaiting-slot|c5def5|【Issue 用】 hot file 競合予防で同サイクル dispatch を見送り中（Phase E Path Overlap Checker が付与・除去）"` を 1 行追加
  - 既存ラベル 13 行の名前 / 色 / 説明文は変更しない（Req 7.3）
  - 冪等性は既存 `EXISTING_LABELS_JSON` チェックで自動的に保証される（追加実装不要）
  - 手動スモーク: `bash repo-template/.github/scripts/idd-claude-labels.sh --repo owner/test-scratch` を 2 回実行し、初回 created / 2 回目 skipped になることを確認
  - _Requirements: 7.1, 7.2, 7.3_
  - _Boundary: Label Provisioning Script Edit_

- [x] 3. `issue-watcher.sh` に env 定数とログ関数群を追加
  - `local-watcher/bin/issue-watcher.sh` の `LABEL_*` 定数ブロック末尾に `LABEL_AWAITING_SLOT="awaiting-slot"` を追加
  - env var ブロック（既存 `STAGE_A_VERIFY_*` 周辺）の後に新規セクション `# ─── Phase E: Path Overlap Checker 設定 (#18) ───` を追加し、`PATH_OVERLAP_CHECK="${PATH_OVERLAP_CHECK:-off}"` を配置
  - `#112` の「デフォルト有効化フラグの値正規化」ループには **追加しない**（opt-in default off のため）
  - `po_log` / `po_warn` 関数を既存 `pp_log` / `pp_warn` の近傍に追加（`[$REPO] path-overlap:` prefix で stdout + `$LOG` に tee）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 8.4_
  - _Boundary: Path Overlap Env Resolver, Path Overlap Logger_

- [x] 4. Triage Parser + Path Overlap Persister 関数群を実装
  - `issue-watcher.sh` に下記関数を追加（既存 `qa_persist_reset_time` / `qa_load_reset_time` の近傍、既存命名規約 `po_*` prefix）:
    - `po_parse_triage_edit_paths $triage_file` — `jq '.edit_paths // [] | if type == "array" then map(select(type == "string")) else [] end'` で fail-safe 抽出
    - `po_persist_edit_paths $issue_number $edit_paths_json` — sticky comment（marker `<!-- idd-claude:edit-paths:v1 -->` + 機械可読 `<!-- idd-claude:edit-paths-json:[...] -->`）の create / update
    - `po_load_edit_paths $issue_number` — `gh issue view --json comments` 1 回呼び、機械可読 marker 行を `sed -nE` で抽出 → jq に渡す
  - `_slot_run_issue` の Triage parse 直後（`jq -r '.status'` 等の後）で `PATH_OVERLAP_CHECK=true` のときのみ `po_parse_triage_edit_paths` → `po_persist_edit_paths` を呼ぶ
  - persist 失敗は `po_warn` で記録するのみで Triage 全体は成功扱い（Req 3.4 fail-open）
  - _Requirements: 2.4, 2.5, 3.1, 3.2, 3.3, 3.4, 12.1_
  - _Boundary: Triage Edit-Paths Parser, Path Overlap Persister_
  - _Depends: 1, 3_

- [ ] 5. In-Flight Collector + Overlap Engine + Awaiting Slot State Machine を実装
  - `issue-watcher.sh` に下記関数を追加:
    - `po_collect_inflight_issues $candidate` — `gh issue list --repo "$REPO" --search '...'` で Req 4.1 の 7 ラベルのいずれかを持ち、`st-failed` / `awaiting-slot` を持たない open Issue を列挙。候補自身を除外（Req 4.3）。各 Issue について `po_load_edit_paths` を呼んで union（jq `add | unique`）
    - `po_compute_overlap $candidate_paths_json $inflight_paths_json` — 正規化（先頭 `./` 剥がし / 連続スラッシュ圧縮 / top-level セグメント抽出）後に集合積を計算（jq def `normalize` 内蔵）。candidate 空配列は常に空（Req 5.5）
    - `po_apply_awaiting_slot $issue_number $overlap_json $holders_json` — ラベル付与 + sticky comment（marker `<!-- idd-claude:awaiting-slot:v1 -->`）の create / update
    - `po_clear_awaiting_slot $issue_number` — ラベル除去のみ（コメントは事後監査用に残置）
  - in-flight 列挙時の OR ラベル検索は `--search 'label:A OR label:B OR ...'` で記述（`--label A --label B` は AND になるため避ける）
  - 失敗時の fail-open 規約（design.md「Error Strategy」表通り）に従う
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 5.1, 5.2, 5.3, 5.5, 5.6, 6.2, 6.3, 8.1, 8.2, 8.3_
  - _Boundary: In-Flight Collector, Overlap Engine, Awaiting Slot State Machine_
  - _Depends: 3, 4_

- [ ] 6. Dispatcher 統合点 `po_check_dispatch_gate` を実装し `_dispatcher_run` に挿入
  - `issue-watcher.sh` に `po_check_dispatch_gate $issue_number $labels_json` を追加（戻り値 0 = claim 続行 / 1 = dispatch skip）
  - 関数冒頭で `[ "$PATH_OVERLAP_CHECK" = "true" ] || return 0` の早期 return で opt-in gate を成立（Req 1.2 / 1.3）
  - `_dispatcher_run` の candidate ループ内、`check_existing_impl_pr "$issue_number"` 通過直後・`_dispatcher_find_free_slot` 呼び出し前に挿入。skip 時は `continue` でループ次へ
  - `gh issue list` の candidate query には **`awaiting-slot` を追加しない**（Req 6.1 「awaiting-slot 付きを次サイクルでも candidate として再評価」を構造的に保証）
  - overlap empty かつ `awaiting-slot` 持ちのとき `po_clear_awaiting_slot` を呼んでから `return 0`（Req 6.2 同サイクル内自然解消）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 6.1, 6.2, 6.3, 6.4, 12.2_
  - _Boundary: Dispatcher Integration Point, Awaiting Slot Re-evaluator_
  - _Depends: 5_

- [ ] 7. README に Phase E 節を追加 (P)
  - `README.md` の Phase D 節（`## Auto Rebase Processor (Phase D)`）の **後** に新規節
    `## Path Overlap Checker (Phase E)` を追加。サブセクション: 概要 / 環境変数 / in-flight ラベル定義 / 自然解消の流れ / 観測ログ / dogfood 確認手順 / Migration Note（後方互換性）
  - 「オプション機能（標準有効 / 常時有効）一覧」表（既存 Phase B / C / D 行の近傍）に
    Phase E 行を追加（`PATH_OVERLAP_CHECK` / 既定 `off` / 該当節へのリンク / Issue #18）
  - 「ラベル状態遷移まとめ」表（既存 `staged-for-release` / `st-failed` 行の近傍）に
    `awaiting-slot` 1 行追加（付与主体 = Phase E Path Overlap Checker / 解除主体 = 同左の自動除去 or 人間手動）
  - Step 2 のラベル一括作成例（`gh label create` 連結ブロック）に `awaiting-slot` 行を追加
  - Migration Note: `PATH_OVERLAP_CHECK` 未設定時は本機能導入前と完全一致（NFR 1.1）、opt-out 戻し手順、`awaiting-slot` ラベル付き Issue の手動解放手順を記述
  - _Requirements: 9.1, 9.2, 9.3, 9.4_
  - _Boundary: README Section_

- [ ] 8. 静的検査・スモークテスト・dogfood 手順を実施
  - `shellcheck local-watcher/bin/issue-watcher.sh` を実行し warnings ゼロを確認（Req 11.1）
  - `shellcheck repo-template/.github/scripts/idd-claude-labels.sh` を実行し warnings ゼロを確認
  - design.md「Testing Strategy」節の Unit-level Manual Smoke 4 ケース（`po_parse_triage_edit_paths` / `po_compute_overlap` / env normalize / sticky idempotency）を bash `source` で関数を直接呼んで入出力テーブルを検証
  - Integration Smoke: `PATH_OVERLAP_CHECK=off` での dry run（cron-like 最小 PATH）で従来と同じ「処理対象の Issue なし」終了になり `path-overlap:` ログが 0 行であることを確認（NFR 1.1 後方互換性）
  - `PATH_OVERLAP_CHECK=true` での dry run（candidate 0 件）でも path-overlap 系ログが 0 行で正常終了することを確認
  - dogfood E2E 手順を `docs/specs/18-phase-e-triage-path-overlap-hot-file/impl-notes.md` に記載（Req 10.1〜10.4 の AC 文言を再録）。実機実行は人間運用者に委ねる
  - _Requirements: 10.1, 10.2, 10.3, 10.4, 11.1_
  - _Boundary: Static Check Procedure, Dogfood Test Procedure_
  - _Depends: 1, 2, 3, 4, 5, 6, 7_
