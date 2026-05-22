# Implementation Plan

> 全タスクは `local-watcher/bin/issue-watcher.sh` / `repo-template/.claude/agents/*.md` /
> `.claude/agents/debugger.md` / `repo-template/CLAUDE.md` / `README.md` を対象とする。
> `issue-watcher.sh` 内のヘルパー関数追加は **同一ファイル内の独立セクション**として実装するため、
> 原則として並列実行は行わない（直列消化を前提に組んでいる）。

- [x] 1. 環境変数の追加と正規化（後方互換性ゲート）
  - `local-watcher/bin/issue-watcher.sh` の config block（既存 Reviewer subagent 設定の直後、行 297 周辺）に
    `DEBUGGER_ENABLED="${DEBUGGER_ENABLED:-false}"` /
    `DEBUGGER_MODEL="${DEBUGGER_MODEL:-claude-opus-4-7}"` /
    `DEBUGGER_MAX_TURNS="${DEBUGGER_MAX_TURNS:-40}"` を追加
  - 値の正規化は使用箇所で `[ "$DEBUGGER_ENABLED" = "true" ]` 完全一致のみ true 扱い（`true` 以外は false 等価 / Req 1.3）
  - 既存 env normalization ループ（#112 のデフォルト有効化フラグ群）には **加えない**（既定 false の opt-in なので別ポリシー）
  - 既存 env var（`DEV_MODEL` / `REVIEWER_MODEL` / `DEV_MAX_TURNS` / `REVIEWER_MAX_TURNS` / `IMPL_RESUME_*` / `STAGE_CHECKPOINT_*` / `PER_TASK_LOOP_ENABLED` 等）の名前・既定値・意味を変更しないこと（Req 1.4, 7.5）
  - 既存ラベル名・契約を改変しないこと（Req 1.5）
  - _Requirements: 1.3, 1.4, 1.5, 7.1, 7.2, 7.3, 7.5_

- [x] 2. Debugger エージェント定義の追加（repo-template + self-hosting 同期）
  - `repo-template/.claude/agents/debugger.md` を新規作成（責務 / 入力 / 出力契約 / 禁止事項 / debugger-notes.md スキーマ）
    - frontmatter: `name: debugger` / `description: ...` / `tools: Read, Grep, Glob, Bash, Write, WebSearch, WebFetch` / `model: claude-opus-4-7`
    - 必読ファイル列挙、Bash 差分取得方法、出力スキーマ（h2 必須 4 セクション）、Phase 2 有効時の `## Task <id>` + h3 4 セクション構造
    - 禁止事項: コード書き換え / spec md 書き換え / ラベル付け替え / commit 作成 / PR 作成 / approve/reject 出力 / 他エージェント役割兼任
  - `.claude/agents/debugger.md`（idd-claude self-hosting 用）を **`repo-template` と同内容の明示的コピー**として配置（symlink ではない / Req 2.1）
  - 両ファイルの内容が同期していることを目視確認（行差分なし）
  - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 6.5, 7.4, NFR 5.1, NFR 5.2_

- [x] 3. watcher: Debugger ヘルパ関数群（検出 / 判定 / verify / ロガー）
- [x] 3.1 `dbg_log` ロガーの追加 (P)
  - 既存 `rv_log` / `pt_log` と同形式で `[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: $*` を stdout 出力
  - 呼び出し側で `>> "$LOG"` する規約（既存 rv_log / pt_log と同じ）
  - ログメッセージには `trigger=<round2-reject|blocked>` / `task=<id|none>` / `issue=#<NUMBER>` を含める
  - _Requirements: NFR 2.1, NFR 2.2, NFR 2.3_
  - _Boundary: dbg_log_
- [x] 3.2 `detect_blocked_marker <impl_notes_path>` の実装 (P)
  - 行頭固定 regex `^BLOCKED: (.+)$` で BLOCKED 行を検出（インデント / list marker `- ` / 引用 `> ` は **検出対象外**、誤検出抑止）
  - reason 部の `:` 文字を破壊しないよう grep + sed の組み合わせで `.+` を貪欲抽出
  - 検出時に stdout に reason 1 行目を出力、return 0。未検出時は return 1（stdout 空）
  - impl-notes.md 不在時も return 1
  - _Requirements: 4.1, 4.2_
  - _Boundary: detect_blocked_marker_
- [x] 3.3 `detect_debugger_already_invoked [<task_id>]` の実装 (P)
  - Issue 単位判定: `$REPO_DIR/$SPEC_DIR_REL/debugger-notes.md` が存在すれば「起動済み」（return 0）
  - task 単位判定: `debugger-notes.md` 内に `### Task <task_id>` セクションが存在すれば「起動済み」（grep で行頭マッチ）
  - 未起動時は return 1（呼び出し側が `run_debugger_stage` を起動可能）
  - _Requirements: 5.1, 5.2, 5.5, 6.3, 6.4_
  - _Boundary: detect_debugger_already_invoked_
- [x] 3.4 `validate_debugger_notes <debugger_notes_path> [<task_id>]` の実装 (P)
  - 必須セクション: `## 根本原因` / `## 修正手順` / `## 検証方法` / `## 関連参考資料`（Issue 単位）
  - Phase 2 有効時（task_id 指定）: `## Task <id>` + その配下 h3 `### 根本原因` / `### 修正手順` / `### 検証方法` / `### 関連参考資料`
  - すべて grep で行頭一致 verify。1 つでも欠落すれば return 1
  - ファイル不在時も return 1
  - _Requirements: 2.3, 3.6, 4.3_
  - _Boundary: validate_debugger_notes_

- [x] 4. watcher: Debugger prompt builder と launcher
- [x] 4.1 `build_debugger_prompt <trigger> [<task_id>] [<review_notes_path>]` の実装
  - 既存 `build_reviewer_prompt` の heredoc 形式を踏襲
  - prompt に含める内容: 対象 Issue 情報 / trigger 識別 / task_id（Phase 2 有効時）/ 必読ファイルパス / Bash 差分取得コマンド / web search 行使可能性 / 出力先パスと追記モード / 出力スキーマ / 禁止事項
  - BLOCKED 経路（trigger=`blocked`）: review-notes.md を必読対象から除外、impl-notes.md の `BLOCKED:` 行を重点参照
  - Round 2 reject 経路（trigger=`round2-reject`）: review-notes.md を必読対象に含める
  - Phase 2 有効時（task_id 指定）: 対象 task の tasks.md 該当行 + `_Requirements:_` 列挙 AC のみ verify 対象を明示
  - _Requirements: 2.2, 2.4, 2.5, 6.5_
- [x] 4.2 `run_debugger_stage <trigger> [<task_id>] [<review_notes_path>]` の実装
  - `qa_run_claude_stage "Debugger-<trigger>-<task|issue>" ...` 経由で `claude --print --model "$DEBUGGER_MODEL" --max-turns "$DEBUGGER_MAX_TURNS" --permission-mode bypassPermissions` を新規プロセス起動（NFR 5.1）
  - 戻り値 0 / 1 / 99（quota）を従来 Reviewer / Developer Stage と同形でマップ
  - 起動前後で `dbg_log "trigger=<...> issue=#<N> task=<id|none> start/end"` を出力（NFR 2.1〜2.3）
  - claude 成功（rc=0）後に `validate_debugger_notes` で形式 verify。verify 失敗時は `mark_issue_failed "debugger-notes-invalid"` で claude-failed
  - claude 非 0 exit 時は `mark_issue_failed "debugger-failed"` で claude-failed
  - quota 99 受領時は既存 `qa_handle_quota_exceeded` 経路に伝搬（needs-quota-wait 退避）
  - _Requirements: 2.6, 3.6, 7.4, NFR 2.1, NFR 2.2, NFR 2.3, NFR 5.1_

- [ ] 5. watcher: Fix Plan 注入版 Developer prompt builder
  - `build_dev_prompt_redo_with_fix_plan <review_notes_path> <debugger_notes_path>` を実装
  - 既存 `build_dev_prompt_redo` の heredoc 形式を踏襲（Issue / branch / spec dir 情報 / PR 作成禁止 / spec 改変禁止 / 既存テスト破壊禁止 / `${BASE_BRANCH}` 直 push 禁止）
  - `debugger-notes.md` の Fix Plan を inline markdown block で全文埋め込み
  - `review-notes.md` の Findings は **trigger=round2-reject 時のみ** 埋め込む（BLOCKED 経路では「(Reviewer 経由ではないため review-notes.md は無し)」と明示）
  - 指示: 「Debugger の Fix Plan に記載された `修正手順` を順に実施し、`検証方法` で挙動を確認する」
  - _Requirements: 3.2, 4.3_

- [ ] 6. watcher: Stage B' (Round 2) reject 経路への Debugger 組込
  - `run_impl_pipeline`（行 6921 周辺）の Round 2 reject 分岐（`case $rev_rc in 1)`）を以下で改修:
    1. 既存 verify_pushed_or_retry / parse_review_result を維持
    2. `[ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked` を判定
    3. true なら `run_debugger_stage "round2-reject" "" "$REPO_DIR/$SPEC_DIR_REL/review-notes.md"` を起動
       - 成功（rc=0）: Stage A''（Developer 再起動）を `build_dev_prompt_redo_with_fix_plan` で起動。既存 Stage A' 起動形式（`qa_run_claude_stage` + `verify_pushed_or_retry`）を踏襲
       - Stage A'' 成功後に `run_reviewer_stage 3`（Round 3）を起動
         - approve: Stage C に進む（既存経路と同形）
         - reject: `mark_issue_failed "reviewer-reject3" "..."` で claude-failed（Req 3.5）
         - error: `mark_issue_failed "reviewer-error" "..."` で claude-failed
       - 失敗（rc=1）: claude-failed（Stage A'' / Round 3 実行なし / Req 3.6）
    4. false（DEBUGGER_ENABLED != true もしくは sentinel 既起動）: 既存 `reviewer-reject2` 経路（claude-failed 直行）をそのまま流用
  - `DEBUGGER_ENABLED != "true"` 時に Stage D 分岐が **構造的に skip** されることを実装上保証（NFR 1.1）
  - _Requirements: 1.1, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 5.2, 5.3, 5.4_

- [ ] 7. watcher: Stage A 完了直後の BLOCKED 検出経路への Debugger 組込
  - `run_impl_pipeline` の Stage A 完了直後・**stage-a-verify gate 直前**（行 6805 周辺）に BLOCKED 検出ブロックを挿入:
    1. `[ "${DEBUGGER_ENABLED:-false}" = "true" ]` を判定（gate）
    2. `detect_blocked_marker "$REPO_DIR/$SPEC_DIR_REL/impl-notes.md"` で BLOCKED 行を検出
    3. 検出時に `detect_debugger_already_invoked` を判定
       - 既起動: `mark_issue_failed "debugger-blocked-but-invoked" "..."` で claude-failed（Req 5.2）
       - 未起動: `run_debugger_stage "blocked" "" ""` を起動
         - 成功（rc=0）: Stage A'（Developer 再起動）を `build_dev_prompt_redo_with_fix_plan` の `review_notes_path=""` 経路で起動。Stage A' 成功後に **通常の stage-a-verify → Stage B (Round 1)** サイクルに合流（Req 4.4）
         - 失敗（rc=1）: claude-failed（Req 3.6）
  - `DEBUGGER_ENABLED != "true"` 時は BLOCKED 行を判定材料に使わず stage-a-verify に直行（Req 1.2）
  - _Requirements: 1.1, 1.2, 4.1, 4.2, 4.3, 4.4, 5.2, 5.4_

- [ ] 8. watcher: Phase 2 (per-task loop) との統合
  - `run_per_task_loop`（Issue #21 で導入）の task 単位 Reviewer Round 2 reject 分岐と per-task Implementer 完了後の BLOCKED 検出ブロックに、上記タスク 6 / 7 と同等の Debugger 経路を追加
    - task 単位 Round 2 reject 経路: `run_debugger_stage "round2-reject" "$task_id" "..."` を起動、成功時に per-task Implementer + per-task Reviewer Round 3 を起動
    - task 単位 BLOCKED 経路: `detect_blocked_marker` + `detect_debugger_already_invoked "$task_id"` で判定、起動時に `run_debugger_stage "blocked" "$task_id" ""` 経由で per-task Implementer 再起動 → 通常 task サイクル合流
  - sentinel は **task scope**（`### Task <id>` セクション存在）で判定（Req 6.3）
  - `PER_TASK_LOOP_ENABLED != "true"` 時は本タスクの分岐は一切実行されず、タスク 6 / 7 の Issue 単位経路がそのまま動く（Req 6.4）
  - Phase 2 が未実装 / 環境で off の場合でも本タスクの実装はコンパイル可能であること（既存 #21 のヘルパ関数を呼ぶ部分は `command -v` 等での存在確認ではなく、`PER_TASK_LOOP_ENABLED=true` の gate 内でのみ呼ぶ構造的保証）
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_
  - _Depends: 6, 7_

- [ ] 9. ドキュメント整備（developer.md / CLAUDE.md / README.md）
- [ ] 9.1 `repo-template/.claude/agents/developer.md` への BLOCKED 宣言規約追記 (P)
  - 末尾に「BLOCKED 宣言の規約（DEBUGGER_ENABLED=true 適用時のみ意味を持つ）」節を追加
  - 内容: 最終手段の位置付け / reason 部の記載指針（試したこと / 不明点 / web search 疑問点）/ 行頭規約（`^BLOCKED: ` 厳密）/ DEBUGGER_ENABLED=false 環境での扱い
  - 既存節（実装フロー / opt-in 時の追加実装フロー / impl-resume 規約 / テスト規約 etc）は一切改変しない
  - _Requirements: 4.5, 4.6, 8.4_
  - _Boundary: developer.md_
- [ ] 9.2 `repo-template/CLAUDE.md` のエージェント連携ルール節に Debugger 項目追記 (P)
  - 「エージェント連携ルール」節に Debugger サブエージェントの責務を 1 項目追加
  - 内容: 「コード書き換えなし / 判定なし / Fix Plan 出力のみ / 1 Issue または 1 task あたり最大 1 回」「DEBUGGER_ENABLED=true の opt-in 環境で Round 2 reject 直前 / BLOCKED 宣言時に起動」
  - 既存節は改変しない
  - _Requirements: 8.3_
  - _Boundary: repo-template/CLAUDE.md_
- [ ] 9.3 `README.md` への opt-in 機能追加と専用解説節
  - 「opt-in（既定 OFF、明示的に有効化が必要）」表（行 1094 周辺）に `DEBUGGER_ENABLED` 行を追加（既存表組のフォーマットを踏襲）
  - 専用解説節「Debugger Subagent (Phase 3, #22)」を追加（既存「Stage Checkpoint (#68)」と同一構造）。含む内容:
    - 用途 / 既定値 / 有効化方法（`DEBUGGER_ENABLED=true` / `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` の説明）
    - opt-in 時の Stage 遷移（Round 2 reject 経路 / BLOCKED 経路 / Round 3 reject → claude-failed）を Mermaid または箇条書きで運用者視点で記述
    - Migration Note: 「既定では `DEBUGGER_ENABLED=false` で従来挙動が維持される」「opt-in 後も Round 2 reject / BLOCKED 宣言が発生しない Issue は挙動不変」
    - コスト記述: 「Debugger 1 回起動あたり web search 含む最大 `DEBUGGER_MAX_TURNS`（既定 40）ターンの Claude CLI 実行コストが追加される」「Debugger 1 回 + Stage A''（Debugger 経由 Developer 再起動）1 回 + Reviewer Round 3 1 回 が本機能で追加される最大コスト」
  - _Requirements: 8.1, 8.2, 8.5, NFR 3.1, NFR 3.2_

- [ ] 10. 静的解析と手動スモークによる検証（impl-notes.md への結果記録）
  - `shellcheck local-watcher/bin/issue-watcher.sh` を実行し新規警告 0 件を確認（NFR 4.1）
  - `actionlint .github/workflows/*.yml` 実行（YAML 変更なしのため自動的に達成）（NFR 4.2）
  - dry run #1: `DEBUGGER_ENABLED` 未設定で `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を空 Issue 状態で流し、`処理対象の Issue なし` で正常終了すること（既存挙動が不変であることの確認 / Req 1.1, 1.2 / NFR 1.1）
  - dry run #2: `DEBUGGER_ENABLED=false` を明示し dry run #1 と同様の結果を確認（typo / 大文字小文字違いの誤検出なし / Req 1.3）
  - dogfood smoke（Round 2 reject 経路）: 故意 reject Issue を立て、Stage D → Stage A'' → Stage B'' (Round 3) approve に至る経路を `$LOG` で確認（Req 3.1〜3.4）
  - dogfood smoke（Round 3 reject claude-failed）: Round 3 でも reject になるシナリオで claude-failed に escalate し、Debugger 再起動が **行われない**ことを確認（Req 3.5, 5.1, 5.2）
  - dogfood smoke（BLOCKED 経路）: Developer に意図的に `BLOCKED: <reason>` を出力させ、Stage A' → 通常 Round 1 サイクル合流を `$LOG` で確認（Req 4.1〜4.4）
  - 各 dogfood smoke で `$LOG` に Debugger 関連 4 イベント（起動 / 終了 / verify / Round 3 結果）が `[$REPO]` 付きで記録されることを確認（NFR 2.1〜2.3）
  - 結果と再現コマンドを `docs/specs/22-phase-3-debugger-subagent-blocked-2-reje/impl-notes.md` に記録
  - _Requirements: NFR 4.1, NFR 4.2, NFR 2.1, NFR 2.2, NFR 2.3, 1.1, 1.2, 1.3_

- [ ]* 10.1 Phase 2 統合 dogfooding（任意 / deferrable）
  - `DEBUGGER_ENABLED=true` + `PER_TASK_LOOP_ENABLED=true` で 2 task の test Issue を流し、task 1 で BLOCKED → Stage D → 再開 → task 2 で Round 2 reject → Stage D → 完走、を確認（Req 6.1, 6.2, 6.3）
  - Phase 2 無効 + Phase 3 有効で従来 Issue 単位 1 回起動が維持されること（Req 6.4）
  - _Requirements: 6.1, 6.2, 6.3, 6.4_
