# Implementation Notes (#281)

## Implementation Notes

### Task 1

- 採用方針: LABELS 配列末尾（`hotfix` 行直後）に `needs-security-fix` を 1 行追加し、既存 16 行の name / color / description は一切変更しない（NFR 1.2）。color は既存 PR 用警告色との一貫性のため `d73a4a`（`st-failed` と同色）を採用、description は仕様文字列をそのまま使用し 83 chars（100 chars 上限内）であることを確認。
- 重要な判断:
  - `repo-template/.github/scripts/idd-claude-labels.sh` は design.md「Modified Files」の対象外（design.md line 257-262 で明示的に repo-template 側不変と宣言）かつ root とは既に系統的に乖離している（root のみ 【PR 用】/【Issue 用】prefix 運用）ため、本 task では編集しない。二重管理規約（CLAUDE.md）が対象とするのは `.claude/{agents,rules}` のみで `.github/scripts/` は対象外であることも確認済み。
  - shellcheck はラベル配列追加のみのため警告ゼロを維持。
- 残存課題: なし（task 2 以降は別 task として独立しており、本 task の判断が後続に伝播する事項はない）。

### Task 2

- 採用方針: 既存「`# ─── Security Review Processor 設定 (#279) ───`」節の末尾（`SECURITY_REVIEW_EXEC_TIMEOUT` 行直後）に新規節「`# ─── Security Review Processor strict モード設定 (#281) ───`」を追加し、`SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` / `SECURITY_REVIEW_BLOCK_LABEL` の 3 env を `${VAR:-default}` 形式で宣言。既定値はそれぞれ `advisory` / `high` / `needs-security-fix` で #279 動作と byte 等価（Req 1.5 / 2.2 / NFR 1.1）。
- 重要な判断:
  - tasks.md 原文では「既存節の末尾に 3 行追加」と指示されていたが、design.md「Modified Files」L250-255 では「strict 関連 env を Config ブロックに追加」までしか拘束しておらず、観測しやすさのため #281 専用サブ節（コメントヘッダ付き）として切り出す方が後続 task 3〜9 で env 群を一望できる。`SECURITY_REVIEW_EXEC_TIMEOUT` の直下にサブ節を作っても「Security Review Processor 設定 (#279) 節の末尾の延長」として読めるため tasks.md の Boundary（`issue-watcher.sh Config block`）に違反しない判断。
  - 各 env のコメントブロックに「既定値 / 許容値 / 不正値時の safe-fallback 挙動 / 厳密一致判定」を明記。これは design.md「環境変数」表（L548-556）の内容を inline 化したもので、運用者が `grep -B 10 SECURITY_REVIEW_MODE issue-watcher.sh` で挙動を即座に確認できる（NFR 3.1 観測可能性の一環）。
  - `SECURITY_REVIEW_BLOCK_LABEL` のコメントで「`needs-iteration` は本 env で制御せずハードコード」を明記。これは design.md L554 の「`needs-iteration` の同時付与は本 env で制御しない（必須付与のためハードコード）」を Config 側にも反映し、task 5 (`sec_apply_block_labels`) 実装時の境界誤認を予防する目的。
  - shellcheck 警告ゼロを確認（コメント + 既存パターン踏襲の `${VAR:-default}` 宣言のみで新規 lint 対象なし）。
- 残存課題: なし（task 3 以降はモジュール側 `modules/security-review.sh` の実装であり、本 task の Config 宣言形式が後続の env 読み出しパターンを拘束する点はない。`${SECURITY_REVIEW_MODE:-advisory}` で Config 側が既に既定値を解決するため、モジュール側関数は `$SECURITY_REVIEW_MODE` を直接参照すればよく fallback 不要）。

### Task 3

- 採用方針: 既存 `sec_check_strict_request` 直後（`sec_fetch_candidate_prs` の直前）に `sec_resolve_block_severity` / `sec_severity_at_or_above` / `sec_count_blocking_findings` の 3 関数を純粋関数として追加。既存 advisory 経路・既存関数群には一切手を入れず副作用なし（NFR 1.1）。配置位置は「severity / strict 関連ヘルパが集約される」目的で sec_check_strict_request の直下を選択（design.md「Service Interface」節の関数列挙順とも整合）。
- 重要な判断:
  - `sec_resolve_block_severity` の不正値判定はホワイトリスト完全一致のみ（design.md L612 のテスト戦略「大文字混在 → high + WARN」に従い、`HIGH` / `Critical` / 前後空白付き等もすべて不正値として WARN + `high` fallback）。これにより shell metacharacter / コマンドインジェクションも構造的に防御（design.md Security Considerations）。未設定 / 空文字列は WARN なしで既定 `high` を採用（Req 2.2、本機能導入前と byte 等価）。
  - `sec_severity_at_or_above` は 25 通り（5 severity × 5 threshold）全パターンを smoke で検証。入力が 5 値以外なら rc=2 を返す防御的設計を保持（呼び出し元は既に `sec_resolve_block_severity` 経由で正規化済みの値を渡す前提だが、purely defensive）。
  - `sec_count_blocking_findings` の sed 抽出パターンは既存 `sec_write_security_notes`（L525-529）で既に確立された `'s/.*<key>=\([0-9][0-9]*\).*/\1/p'` パターンを完全踏襲し、既存と一貫した数値抽出ロジックを採用。malformed input（空文字 / "garbage data" 等）でも安全側で "0" を返してラベル付与判定をスキップさせる（Req 5.3 安全側設計）。threshold 不正値でも "0" を返す防御層を入れた（呼び出し元が `sec_resolve_block_severity` を経由する前提でも到達しない想定だが、合成テストで動作確認済み）。
  - `for pair in "critical:$crit" "high:$high" ...` の collection 走査スタイルは bash 移植性の高い `${pair%%:*}` / `${pair##*:}` パラメータ展開で sev/count を分解する設計を採用。shellcheck 警告ゼロ。
  - smoke 検証（手動）: 12 種の `sec_resolve_block_severity` 入力 / 9 通りの `sec_severity_at_or_above` ordinal 比較 / 11 種の `sec_count_blocking_findings` 入力（design.md L612-616 の境界例「閾値 medium で critical=1 high=2 medium=3 → 6 件」を含む）すべて期待値一致。WARN は stderr のみに出力されることも確認（stdout 単一 token 契約を破壊しない）。
- 残存課題:
  - 本 task では `sec_run_review_for_pr` の改修・呼び出し挿入は実施しない（task 6 の責務）。本 3 関数は task 6 で `if [ "$mode" = "strict" ] && [ "$total_findings" -gt 0 ]; then threshold=$(sec_resolve_block_severity); blocking_count=$(sec_count_blocking_findings "$severity_summary" "$threshold"); ...` 形式で組み合わせて使用される予定（design.md L457-468）。
  - 本 task の純粋関数 3 つはすべて既存 advisory 経路から呼ばれないため、`SECURITY_REVIEW_MODE != strict` 環境では関数定義が読み込まれるだけで実行されず副作用ゼロ（NFR 1.1 byte 等価が構造的に保証される）。
