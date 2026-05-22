# Implementation Plan

- [x] 1. `LABEL_BLOCKED` 定数追加と dispatcher pickup 除外フィルタ拡張
  - `local-watcher/bin/issue-watcher.sh` Config 節（`LABEL_AWAITING_SLOT` 近傍）に `LABEL_BLOCKED="blocked"` を追加
  - `_dispatcher_run` 内の `gh issue list --search` 文字列の既存除外リスト末尾に `-label:\"$LABEL_BLOCKED\"` を追加（既存除外 label の順序・値は変更しない）
  - 既存コメント（Issue #54 / #66 / #100 由来の経緯コメント）と整合する形で「Issue #146: 依存 Issue 未 merge による blocked 状態を pickup 候補から除外」の 1 行コメントを併記
  - `blocked` と既存 `needs-decisions` を独立した除外条件として並列指定する（双方の状態遷移・除去フローは別系統 / Req 9.3）
  - 手動除去で次サイクル pickup に再合流する挙動を構造的に保証（除外クエリにのみ依存し、追加の retrofit ロジックは入れない / Req 4.2）
  - shellcheck 警告ゼロを維持
  - _Requirements: 4.1, 4.2, 4.3, 9.3, NFR 1.3_

- [x] 2. Dependency Resolver 純粋関数群の追加
  - `local-watcher/bin/issue-watcher.sh` の `_slug_mismatch_escalate` 近傍（`_slot_run_issue` より上）に Dependency Resolver セクションを設ける
  - `dr_log` / `dr_warn` / `dr_error` を既存 `mq_log` / `pi_log` / `drr_log` と同書式で実装
  - `dr_extract_deps`（純粋関数）: 引数 = 本文文字列、stdout = 数字 1 行/件の重複排除済集合。canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:` を `grep -E` で行抽出し `grep -oE '#[0-9]+'` で番号列展開、`sort -u` で uniq 化
  - `dr_format_unresolved_comment`（純粋関数）: 引数 = `#N|区分` の改行区切り、stdout = 依存未解決専用 markdown 本文（design.md「Escalation Comment Template」と一致、`needs-decisions` テンプレ語彙を含めない）
  - shellcheck 警告ゼロを維持
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.7, 3.2, 3.6, 8.4, 9.2, NFR 1.4_

- [x] 3. gh API ラッパとブロック付与関数の追加
  - `dr_resolve_one`: 引数 = 依存 Issue 番号、stdout = `resolved` / `open` / `closed unmerged` / `api error` の 4 区分文字列 1 行。`gh issue view <N> --repo "$REPO" --json state,closedByPullRequestsReferences` を実行し、`jq` で `.state` と `.closedByPullRequestsReferences[].merged` を判定。gh / jq 失敗時は `api error` を返し `dr_warn` でログ
  - `dr_apply_block`: 引数 = Issue 番号 + 未解決依存リスト。単一 `gh issue edit --remove-label "$LABEL_CLAIMED" --add-label "$LABEL_BLOCKED"` で原子的に付け替え、`gh issue comment` で `dr_format_unresolved_comment` の出力を投稿。`needs-decisions` ラベルには触れない
  - 既存 `_slug_mismatch_escalate` のエラーハンドリングパターン（`|| true` / `dr_warn` の使い分け）を参考に、ラベル付与失敗は `dr_warn` + 非 0 return で caller に通知
  - shellcheck 警告ゼロを維持
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 3.1, 3.2, 3.3, 6.2, 9.1, NFR 4.2_

- [x] 4. Dependency Resolver orchestrator と `_slot_run_issue` 統合
  - `dr_check_dependencies`: 引数 = Issue 番号 + 本文 + LABELS（改行区切り）。冪等性ガード（LABELS に `blocked` を含めば早期 return 1）→ `dr_extract_deps` で集合取得 → 空なら `verdict=skip_no_deps` ログ + return 0 → 非空なら各番号で `dr_resolve_one` 集計 → 全件 resolved なら `verdict=all_resolved` ログ + return 0 → 1 件以上未解決なら `dr_apply_block` 実行 + `verdict=blocked` ログ + return 1
  - 構造化ログ 1 行（design.md「Log Schema」と一致）を `dr_log` 経由で出力
  - `_slot_run_issue` 内の Triage 起動直前（`local TRIAGE_FILE=...` の手前、`HAS_EXISTING_SPEC=false` の `else` 分岐に入った後）で `dr_check_dependencies "$NUMBER" "$BODY" "$LABELS"` を呼び、非 0 なら `slot_log "依存未解決により blocked 付与（Issue #146）"` を残して `return 0`
  - `HAS_EXISTING_SPEC=true`（impl-resume 経路）および `skip-triage` 経路では呼び出さない（既に in-flight の Issue への retrofit を避ける、Out of Scope に整合）
  - shellcheck 警告ゼロを維持
  - _Requirements: 1.6, 2.6, 3.4, 3.5, 5.1, 5.2, 5.3, 6.1, 6.3, NFR 1.1, NFR 2.1, NFR 2.2, NFR 3.1, NFR 4.1, NFR 4.2_

- [ ] 5. `idd-claude-labels.sh` 両系統に `blocked` 定義を追加 (P)
  - `.github/scripts/idd-claude-labels.sh` の `LABELS=( ... )` 配列末尾に `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能"` を追加
  - `repo-template/.github/scripts/idd-claude-labels.sh` の `LABELS=( ... )` 配列末尾にも同じ `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能"` を追加（Req 7.6 同名同 description）
  - 既存ラベル行（name / color / description / 順序）は一切変更しない（NFR 1.2）
  - shellcheck 警告ゼロを維持
  - 手動スモーク: `/tmp/scratch` repo で両スクリプトを実行し、`blocked` ラベルが新規作成・skip・`--force` 更新で冪等動作することを確認
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, NFR 1.2, NFR 3.2_
  - _Boundary: idd-claude-labels.sh (self-hosting), idd-claude-labels.sh (consumer)_

- [ ] 6. README.md のラベル一覧・状態遷移・運用フロー追記
  - 「Step 2 GitHub 側の準備 → 作成されるラベル」表（行 445 周辺）に `blocked` 行を追加（色 = 濃赤 / 用途 = 依存 Issue 未 merge により auto-dev 進行不能）
  - 同節「手動で作成する場合」（行 464 周辺）に `gh label create blocked --repo owner/repo --color b60205 --description "..."` を追加
  - 「ラベル状態遷移まとめ」表（行 881 周辺）に `blocked` 行を追加（適用先=Issue、付与主=Claude (PM Phase Orchestrator)、解除=人間が手動除去）
  - 状態遷移図テキスト（行 930 周辺）の `auto-dev (起票)` 配下に `Dependency Resolver Gate` 経路を追加し、blocked → 「人間が依存解消 + blocked 手動除去」→ 再 Triage への合流を図示
  - ポーリングクエリ説明文に `blocked` 注記（依存 Issue 未 merge による pickup 除外、PM Phase Orchestrator が付与）を追加
  - 依存記法（canonical `Depends on:` / alias `前提依存:` / alias `Blocked by:`）を使うと PM phase で依存チェックが走る旨を、`.claude/rules/issue-dependency.md` への内部リンク付きで運用者向けに記述
  - `blocked` と `needs-decisions` の意味的差分（blocked = 依存 Issue 未 merge 専用 / needs-decisions = それ以外の汎用人間判断要求、将来統合しない方針）を 1〜2 行で明示
  - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 9.4_

- [ ] 7. QUICK-HOWTO.md ラベル列挙への追記と shellcheck/E2E スモーク
  - `QUICK-HOWTO.md` の「作成されるラベル」インライン列挙（行 72-74 周辺）に `blocked` を追記
  - shellcheck: `shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` で警告ゼロを確認
  - 手動スモーク (a): 依存記法非搭載の test Issue で従来通り Triage に進むこと（NFR 1.1 後方互換）
  - 手動スモーク (b): `Depends on: #<open Issue>` を持つ test Issue で `blocked` 付与 + コメント 1 件 + Triage skip + 次サイクル pickup されないこと
  - 手動スモーク (c): test Issue から `blocked` を手動除去 → 次 cron tick で再評価され通常 pickup されること（冪等性 / Req 4.2 / NFR 3.1）
  - 手動スモーク結果を `impl-notes.md` に記録
  - _Requirements: 8.6, NFR 3.1_
