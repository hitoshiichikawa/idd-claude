# Implementation Plan

- [x] 1. `.github/scripts/idd-claude-labels.sh` に新規ラベル `needs-security-fix` を追加
  - LABELS 配列末尾に `"needs-security-fix|d73a4a|【PR 用】 Security Review strict モード（#281）で severity 閾値以上の検出により付与される。手動剥がしで override 可"` を追加
  - 既存ラベル定義（name / color / description）は一切変更しない（NFR 1.2）
  - description 100 文字制限に収まることを確認
  - shellcheck `.github/scripts/idd-claude-labels.sh` が警告ゼロ
  - _Requirements: 4.4, NFR 1.2, NFR 5.1_

- [x] 2. `issue-watcher.sh` Config ブロックに strict 関連 env を追加 (P)
  - 既存「`# ─── Security Review Processor 設定 (#279) ───`」節 **末尾**に以下 3 行を追加:
    - `SECURITY_REVIEW_MODE="${SECURITY_REVIEW_MODE:-advisory}"`（#279 で Config 未宣言だったため新規宣言、既定 `advisory` は #279 動作と byte 等価）
    - `SECURITY_REVIEW_BLOCK_SEVERITY="${SECURITY_REVIEW_BLOCK_SEVERITY:-high}"`
    - `SECURITY_REVIEW_BLOCK_LABEL="${SECURITY_REVIEW_BLOCK_LABEL:-needs-security-fix}"`
  - 既存 `SECURITY_REVIEW_*` env / 他 Config 節 / REQUIRED_MODULES / dispatcher call site は一切変更しない
  - 各 env にコメントブロックで意味・既定値・許容値（severity 5 値）を明記
  - shellcheck `local-watcher/bin/issue-watcher.sh` が警告ゼロ
  - _Requirements: 1.1, 1.5, 2.1, 2.2, NFR 1.1, NFR 1.2, NFR 5.1_
  - _Boundary: issue-watcher.sh Config block_

- [x] 3. `modules/security-review.sh` に severity 閾値 / ordinal / 合算ヘルパを追加 (P)
  - `sec_resolve_block_severity` を追加（env 未設定 / 不正値で WARN + `high` fallback / 出力は小文字 5 値のいずれか 1 行）
  - `sec_severity_at_or_above` を追加（ordinal map: critical=5 / high=4 / medium=3 / low=2 / info=1、戻り値 0 = 同等以上 / 1 = 未満 / 2 = 入力不正）
  - `sec_count_blocking_findings` を追加（`sec_count_severities` 出力形式と threshold から閾値以上件数を合算、stdout に整数 1 行）
  - 純粋関数として実装し既存関数とは独立（既存 advisory 経路に副作用なし）
  - shellcheck `local-watcher/bin/modules/security-review.sh` が警告ゼロ
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 5.1, 5.2, NFR 5.1_
  - _Boundary: modules/security-review.sh severity helpers_

- [ ] 4. `sec_check_strict_request` の挙動を mode 解決に変更
  - 既存実装（#279 advisory fallback + WARN）を以下に置換:
    - `SECURITY_REVIEW_MODE=strict` 厳密一致 → stdout に `strict` を出力（Req 1.2）
    - `SECURITY_REVIEW_MODE` 未設定 / 空 / `advisory` → stdout に `advisory`（Req 1.1, 1.5、#279 と byte 等価）
    - `SECURITY_REVIEW_MODE` が上記以外 → WARN 1 行 + `advisory` fallback（Req 1.4）
    - `SECURITY_REVIEW_STRICT` 非空 → deprecated alias 警告 WARN 1 行のみ（mode は変更しない、#279 と byte 等価で sudden break 回避）
  - 関数 docstring を更新し「#279 で advisory fallback 固定だったが #281 で実 mode 解決に切替」を明記
  - _Requirements: 1.1, 1.2, 1.4, 1.5, NFR 1.1_
  - _Boundary: modules/security-review.sh sec_check_strict_request_

- [ ] 5. `sec_apply_block_labels` を実装（2 枚ペア付与 + marker 投稿 + 重複防止）
  - 入力: `$1 = pr_number`, `$2 = sha`, `$3 = blocking_count`, `$4 = threshold`
  - 冒頭で `sec_already_processed "$pr_number" "$sha" "security-block"` 重複判定 → 既存なら sec_log で skip 通知して return 0（Req 3.6, NFR 4.1）
  - `gh pr edit "$pr_number" --repo "$REPO" --add-label "${SECURITY_REVIEW_BLOCK_LABEL},needs-iteration"` で 2 枚原子付与（Req 3.1, 4.4）
  - hidden marker コメント（`kind=security-block`）を 1 件投稿し以降の重複防止を確立
  - 付与結果（blocking_count / threshold / 付与成否）を sec_log で 1 行記録（Req 3.5）
  - `gh pr edit` 失敗時は WARN + return 1（コメント投稿側を阻害しない、既存 fail-continue 規約）
  - _Requirements: 3.1, 3.4, 3.5, 3.6, 4.4, NFR 4.1, NFR 4.2_
  - _Boundary: modules/security-review.sh sec_apply_block_labels_

- [ ] 6. `sec_run_review_for_pr` の strict 経路を統合
  - 既存「検出 ≥ 1 件と判定 → severity 集計 + コメント投稿 + notes 書き出し」分岐の `sec_post_review_comment` 呼び出し **直前**に strict 判定枝を挿入:
    - モジュール内グローバル `_sec_resolved_mode` を参照
    - `mode != strict` ならスキップ（既存 advisory 経路を温存 / NFR 1.1）
    - `mode = strict` かつ `total_findings > 0` なら `sec_resolve_block_severity` で threshold 取得 → `sec_count_blocking_findings` で閾値以上件数算出
    - blocking_count > 0 → strict 専用 override note（design.md「sec_post_review_comment の override note 追加」節のテンプレ）を review_text 末尾に append → `sec_apply_block_labels` 呼び出し
    - blocking_count = 0 → ラベル付与なし（Req 3.2）、sec_log で記録
  - `sec_write_security_notes` 呼び出しは既存どおり実施（Severity Summary 拡張は task 7）
  - 既存 advisory 経路（mode != strict）は 1 行も変更しない（NFR 1.1）
  - _Requirements: 1.2, 3.1, 3.2, 3.3, 3.4, 4.5, 6.1, NFR 1.1_
  - _Boundary: modules/security-review.sh sec_run_review_for_pr_

- [ ] 7. `sec_write_security_notes` に Threshold Decision セクションを追加
  - 既存「Severity Summary」表の **下**に新規セクション「## Threshold Decision」を追加（design.md「security-notes.md フォーマット拡張」節のテンプレに従う）
  - 出力項目: `Mode` / `Threshold` / `Blocking Count` / `Decision`（`label-applied` / `label-skipped` / `advisory-only` / `n/a`）
  - 関数シグネチャに `mode` / `threshold` / `blocking_count` / `decision` 引数を追加（既存呼び出し元は task 6 で更新）
  - 既存呼び出し元（advisory 経路）はデフォルト値 `mode=advisory threshold=- blocking_count=0 decision=advisory-only` を渡す（NFR 1.1 既存出力との互換性）
  - 既存 idempotency（Last SHA 一致時 overwrite skip）は変更しない
  - _Requirements: 5.4, NFR 1.1, NFR 4.1_
  - _Boundary: modules/security-review.sh sec_write_security_notes_

- [ ] 8. `process_security_review` のサマリログ拡張
  - cycle start ログから `strict=not-implemented (split to #281)` 表記を削除
  - 新規に `threshold=${threshold}` を追加し、`mode=${mode} threshold=${threshold}` を 1 行に含める（Req 1.3, 2.5, NFR 3.1）
  - 解決済み mode / threshold をモジュール内グローバル `_sec_resolved_mode` / `_sec_resolved_threshold` に退避（task 6 から参照）
  - cycle 終了サマリに新規カウンタ `blocked=N skipped_blocked=N` を追加（運用者が strict 結果をログから集計可能に / NFR 3.1）
  - 既存 advisory 経路の他ログは変更しない（NFR 1.1）
  - _Requirements: 1.3, 2.5, NFR 1.1, NFR 3.1_
  - _Boundary: modules/security-review.sh process_security_review_

- [ ] 9. README にドキュメント追記（同一 PR 内で実施 / NFR 6.2）
  - 「Security Review Processor (#279)」節内の「既知の制約 - strict 拡張は別 Issue として分割済み」表記を撤去
  - **既存「### 環境変数」表（`Security Review Processor (#279)` 節配下、`SECURITY_REVIEW_ENABLED` / `SECURITY_REVIEW_PROMPT` ... `SECURITY_REVIEW_EXEC_TIMEOUT` を列挙している既存 9 行の表）に以下 3 行を追記する**:
    - `SECURITY_REVIEW_MODE` / 既定 `advisory` / strict モード切替の opt-in gate（`=strict` 厳密一致のみ有効、それ以外は WARN + advisory fallback）
    - `SECURITY_REVIEW_BLOCK_SEVERITY` / 既定 `high` / ラベル付与判定の severity 閾値（許容値 `critical` / `high` / `medium` / `low` / `info`、不正値は WARN + `high` fallback）
    - `SECURITY_REVIEW_BLOCK_LABEL` / 既定 `needs-security-fix` / strict 検出時に PR へ付与するマージ阻害ラベル名（運用者が手動剥がしで override 可）
  - **既存「### 環境変数」表 **直下** の disclaimer 引用ブロック「> **strict 関連 env は本 spec では実装されない**: ...」（4 行）を撤去** し、「strict モード関連 env（`SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` / `SECURITY_REVIEW_BLOCK_LABEL`）の詳細は本節「strict モード（#281）」サブ節を参照」と 1 行で置換する
  - 新規サブ節「strict モード（#281）」を追加。含める内容:
    - 概要 / 既定 advisory / `SECURITY_REVIEW_MODE=strict` で有効化
    - severity 閾値の意味（critical > high > medium > low > info の ordinal、既定 high）
    - 付与されるラベル（`needs-security-fix` + `needs-iteration` のペア / PR Iteration Processor 動線連携）
    - override 手順（GitHub UI からラベル手動剥がし、同一 SHA への再付与なし）
    - Migration Note: `bash .github/scripts/idd-claude-labels.sh --force` で新規ラベル作成、既存 env / 既存ラベル / cron / exit code は不変
  - 「オプション機能一覧」§ の opt-in 表に `SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` 行を追加
  - 言語方針に従い日本語ベース、env var 名・ラベル名は英語固定
  - _Requirements: 4.1, 4.5, NFR 6.1, NFR 6.2_

- [ ] 10. 静的解析と手動スモークテスト
  - `shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` が警告ゼロ
  - `actionlint .github/workflows/*.yml` が警告ゼロ（本機能で workflow 変更なし、非回帰確認）
  - `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` が空（本機能で agents/rules を編集していないことの確認 / NFR 7.2）
  - `bash .github/scripts/idd-claude-labels.sh --repo <test-repo>` で新規ラベル `needs-security-fix` が作成されること（scratch repo で確認）
  - isolated smoke: `SECURITY_REVIEW_ENABLED=true SECURITY_REVIEW_MODE=strict` 時に `process_security_review` の cycle start ログに `mode=strict threshold=high` が記録される（候補 PR なし状態で確認）
  - isolated smoke: `SECURITY_REVIEW_ENABLED=true SECURITY_REVIEW_MODE` 未設定時に `mode=advisory threshold=high` で記録され #279 と byte 等価（NFR 1.1）
  - _Requirements: NFR 1.1, NFR 5.1, NFR 7.2_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の
構造化ブロックで宣言する。bash モジュール / 本体 / ラベルスクリプトへの shellcheck と
workflow YAML への actionlint、および root ↔ repo-template の二重管理ドリフト検査を併せる。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh && \
  actionlint .github/workflows/*.yml && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
