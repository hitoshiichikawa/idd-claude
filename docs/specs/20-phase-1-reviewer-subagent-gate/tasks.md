# Implementation Plan

## Notes

- ID は numeric 階層。`(P)` 付きタスクは並列実行可能（境界が衝突しない）
- 各タスクは 1 commit 単位を原則とする
- design.md の Components 名（`Reviewer Agent Definition` / `Watcher Config` / `run_impl_pipeline` /
  `run_reviewer_stage` / `parse_review_result` / `Prompt Builders` / `README Documentation` / `Installer Path`）
  と `_Boundary:_` を一致させること

---

- [ ] 1. Reviewer サブエージェント定義の追加
- [ ] 1.1 reviewer.md を repo-template と self-host 両方に追加 (P)
  - フロントマター: `name: reviewer`, `description`, `tools: Read, Grep, Glob, Bash, Write`, `model: claude-opus-4-7`
    （既存 `developer.md` / `architect.md` と同スキーマ）
  - 本文構成（design.md「Reviewer Agent Definition」節に従う）:
    - 役割（Developer 完了後の独立レビュー、書き換えない）
    - 必ず先に読むルール（CLAUDE.md / requirements.md / tasks.md / impl-notes.md）
    - 入力契約（プロンプト経由で受け取る変数 + 参照ファイルパス + round 情報）
    - 判定基準 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）と reject しない条件（スタイル / lint）
    - 出力契約（review-notes.md フォーマット、最終行 `RESULT: approve` / `RESULT: reject`）
    - やらないこと（requirements / design / tasks / 実装の書き換え禁止、commit / push / gh 禁止）
  - 配置: `repo-template/.claude/agents/reviewer.md` + `.claude/agents/reviewer.md`（同内容）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 7.5_
  - _Boundary: Reviewer Agent Definition_

- [ ] 1.2 install.sh / installer 経路の検証
  - 既存 `cp -v "$REPO_TEMPLATE_DIR/.claude/agents/"*.md` が reviewer.md を自動配置することを確認
  - 必要であれば README の「対象 repo へのインストール」節に reviewer.md を含める旨を 1 行追記
  - `install.sh --repo /tmp/scratch` で冪等性を smoke
  - _Requirements: 1.6, 6.6_
  - _Boundary: Installer Path_
  - _Depends: 1.1_

- [ ] 2. Watcher の Stage 分割実装（reject ループの中核）

- [ ] 2.1 Config ブロックに REVIEWER_MODEL / REVIEWER_MAX_TURNS を追加
  - `local-watcher/bin/issue-watcher.sh` の Config セクションに以下を追加:
    - `REVIEWER_MODEL="${REVIEWER_MODEL:-claude-opus-4-7}"`
    - `REVIEWER_MAX_TURNS="${REVIEWER_MAX_TURNS:-30}"`
  - 既存 `TRIAGE_MODEL` / `DEV_MODEL` 行の直後に並べる
  - 既存 env var の名前・既定値は変更しない（後方互換性確認）
  - _Requirements: 5.1, 5.2, 5.5, 6.1_
  - _Boundary: Watcher Config_

- [ ] 2.2 prompt builder 関数群を追加
  - `build_dev_prompt_a` (Stage A): 既存 `DEV_PROMPT` の STEPS から PjM 起動を除いた版
  - `build_dev_prompt_redo` (Stage A'): Developer のみ起動 + 直前 review-notes.md の Findings を inline
  - `build_reviewer_prompt` (Stage B): Reviewer 起動 + git diff / 関連ファイル / round 情報を埋める
  - `build_dev_prompt_c` (Stage C): 既存 `DEV_PROMPT` の PjM 起動部分のみ。PR 作成挙動・本文契約を維持
  - すべて bash 関数として `issue-watcher.sh` 内に追加。テンプレートファイルは作らない
  - 既存 `DEV_PROMPT` の組み立てパターン（heredoc + 変数展開）を踏襲
  - _Requirements: 2.3, 4.1, 6.5_
  - _Boundary: Prompt Builders_

- [ ] 2.3 run_reviewer_stage / parse_review_result を実装 (P)
  - `parse_review_result <path>`: review-notes.md から最終 `RESULT:` 行を grep し
    `<result>\t<categories>\t<target_ids>` を stdout に出す。失敗時 exit 2
  - `run_reviewer_stage <round>`: REVIEWER_PROMPT を build → claude --print 実行 → parse →
    ログに `reviewer: round=N start (model=..., max-turns=...)` と
    `reviewer: round=N result=... ...` を出す
  - 戻り値: 0=approve / 1=reject / 2=異常（claude crash / parse 失敗 / RESULT 欠落）
  - claude オプションは既存 Stage A と同一（`--print --model --permission-mode --max-turns
    --output-format stream-json --verbose`）
  - _Requirements: 2.2, 4.8, 5.3, 5.4, NFR 1.1, NFR 2.1, NFR 2.2_
  - _Boundary: run_reviewer_stage, parse_review_result_
  - _Depends: 2.1, 2.2_

- [ ] 2.4 run_impl_pipeline 状態機械を実装
  - design.md「状態遷移表」を実装:
    - START → Stage A → (success → Stage B round=1) | (fail → TERMINAL_FAILED 既存メッセージ)
    - Stage B round=1 → (approve → Stage C) | (reject → Stage A' / log: "redo by reviewer reject") |
      (error → TERMINAL_FAILED + Issue コメント with $LOG パス)
    - Stage A' → (success → Stage B round=2) | (fail → TERMINAL_FAILED 既存メッセージ)
    - Stage B round=2 → (approve → Stage C) | (reject → TERMINAL_FAILED + Issue コメント with
      対象 ID / カテゴリ / review-notes.md パス / $LOG パス) | (error → TERMINAL_FAILED 同上)
    - Stage C → (success → TERMINAL_OK) | (fail → TERMINAL_FAILED)
  - Reviewer 起動回数 / Developer 再実行回数を bash カウンタで上限 2 に固定（NFR 1.2, NFR 1.3）
  - design モードからは呼ばれないことを保証（既存 MODE 分岐の impl / impl-resume 経路のみで呼ぶ）
  - _Requirements: 2.1, 2.4, 2.5, 2.6, 2.7, 4.1, 4.2, 4.3, 4.4, 4.5, 4.6, 4.7, 6.2, 6.3, 6.5, NFR 1.2, NFR 1.3, NFR 2.3_
  - _Boundary: run_impl_pipeline_
  - _Depends: 2.2, 2.3_

- [ ] 2.5 既存 Issue 処理ループを run_impl_pipeline 呼び出しに置換
  - `issue-watcher.sh:1262-1363` の impl / impl-resume 系の `DEV_PROMPT` 単一実行を
    `run_impl_pipeline` 呼び出しに置き換える
  - design モードのパスは無変更（要件 2.6）
  - 既存の「失敗時 claude-picked-up 削除 + claude-failed 付与 + Issue コメント」処理は
    run_impl_pipeline 内に移譲（重複させない）
  - 既存ラベル定数（LABEL_PICKED / LABEL_FAILED / LABEL_READY）を流用
  - cron / launchd 登録文字列が変わらないことを確認（要件 6.4）
  - _Requirements: 2.4, 2.5, 6.2, 6.3, 6.4_
  - _Boundary: run_impl_pipeline_
  - _Depends: 2.4_

- [ ] 3. ドキュメント更新

- [ ] 3.1 CLAUDE.md / repo-template/CLAUDE.md にエージェント連携ルールを追記 (P)
  - 「エージェント連携ルール」節に Reviewer 行を追加:
    - Reviewer は Developer 完了後の独立レビューのみを担当
    - 要件 / 設計 / 実装の追加・書き換えを行わない
    - 判定の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）以外で reject しない
  - self-host (`./CLAUDE.md`) と consumer 向け (`repo-template/CLAUDE.md`) の両方を更新（同期）
  - _Requirements: 7.4_
  - _Boundary: README Documentation_

- [ ] 3.2 README.md に Reviewer ゲートのセクションを追加 (P)
  - 「サブエージェント構成」表に Reviewer 行を追加（責務 / 主なツール / 推奨モデル / 起動条件）
  - 新セクション「impl 系モードでの Reviewer ゲート」を追加:
    - 機能概要（独立 context での AC / test / boundary レビュー）
    - 起動条件（impl / impl-resume / skip-triage 経由 impl の全パス、design モードは対象外）
    - 差し戻しループ図（Reviewer 最大 2 回 / Developer 最大 2 回）
    - `REVIEWER_MODEL` / `REVIEWER_MAX_TURNS` の既定値と override 例
  - 「ラベル状態遷移まとめ」に Reviewer 経由の `claude-picked-up` 持続と `ready-for-review` 遷移
    タイミングを追記
  - GitHub Actions 版には組み込まれない旨を 1 行明記
  - _Requirements: 7.1, 7.2, 7.3_
  - _Boundary: README Documentation_

- [ ] 4. 検証とスモークテスト

- [ ] 4.1 静的解析を通す
  - `shellcheck local-watcher/bin/issue-watcher.sh` で警告 0 を確認
  - 警告が出る場合は `# shellcheck disable=` を安易に使わず、原則として修正で対応
  - _Requirements: NFR 3.1_
  - _Boundary: Watcher Config, run_impl_pipeline, run_reviewer_stage, parse_review_result, Prompt Builders_
  - _Depends: 2.5_

- [ ] 4.2 dogfooding スモークテスト（正常パス + reject 経路 + 異常終了）
  - **Smoke 1（正常パス）**: 自リポジトリに軽微な auto-dev Issue を立て、Stage A → B (approve) → C
    で PR が `ready-for-review` に到達することを確認。PR に `review-notes.md` が含まれること
  - **Smoke 2（reject 1 ラウンド）**: 意図的に AC 未カバー実装を Developer が出すケースを再現し、
    Stage B round=1 で reject → Stage A' → Stage B round=2 のループが動くことを確認
  - **Smoke 3（Reviewer 異常終了）**: `REVIEWER_MAX_TURNS=1` 一時設定で Reviewer が RESULT を
    書き終える前に止まる挙動を確認。`claude-failed` + Issue コメントに `$LOG` パスが含まれること
  - **Smoke 4（design モード非影響）**: `needs_architect: true` 判定される Issue で
    Reviewer が起動しないこと（既存 design PR ゲートのみ動作）を確認
  - 結果は PR 本文の Test plan に記録
  - _Requirements: NFR 3.2, NFR 3.3, 2.6, 4.5, 4.8_
  - _Depends: 2.5, 3.2_

- [ ]* 4.3 idd-claude 自身を E2E ターゲットにした実行記録
  - 上記 Smoke を本リポジトリで実施した結果を `docs/specs/20-phase-1-reviewer-subagent-gate/impl-notes.md` に記録
  - PR 本文「Test plan」と相互参照
  - _Requirements: NFR 3.2, NFR 3.3_
