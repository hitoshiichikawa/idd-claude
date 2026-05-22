# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-22-impl-phase-3-debugger-subagent-blocked-2-reje
- HEAD commit: fd391ce1a20881d98fca7975204f331bcfbba410
- Compared to: main..HEAD
- 差分規模: 8 files changed, 1783 insertions(+), 42 deletions(-)
- 主要変更ファイル:
  - `local-watcher/bin/issue-watcher.sh`(+914): env vars 追加 / Debugger Gate ヘルパ群 / Stage D 分岐 / per-task 統合
  - `repo-template/.claude/agents/debugger.md` + `.claude/agents/debugger.md`(+186 ea, diff=0): 新規エージェント定義（両ファイル内容一致確認済み）
  - `repo-template/.claude/agents/developer.md`(+58): BLOCKED 宣言規約節を末尾追記
  - `repo-template/CLAUDE.md`(+1): エージェント連携ルール節に Debugger 1 項目追記
  - `README.md`(+144): opt-in 表 1 行 + 専用解説節（用途 / opt-in 手順 / 環境変数 / Stage 遷移 / Phase 2 統合 / 観測可能性 / コスト警告 / Migration Note）
  - `docs/specs/22-.../impl-notes.md`(+298), `tasks.md`(+/-): 進捗マーカー + 実装ノート
- CLAUDE.md の Feature Flag Protocol 節は **未配置**のため opt-out 解釈で、通常の 3 カテゴリ判定のみ実施（flag 観点の細目は適用しない / Req 4.2 / NFR 1.1）

## Verified Requirements

### Requirement 1: opt-in による既存挙動の保全

- 1.1 — `issue-watcher.sh` の Stage D 分岐 2 箇所が `if [ "${DEBUGGER_ENABLED:-false}" = "true" ]` で囲まれ、未設定 / false 時は構造的 skip（diff で確認）
- 1.2 — BLOCKED 検出ブロックも同 gate 内に配置されており、`DEBUGGER_ENABLED != "true"` で `detect_blocked_marker` が呼ばれない
- 1.3 — `[ "${DEBUGGER_ENABLED:-false}" = "true" ]` 完全一致比較。impl-notes.md の dry run #3 で typo / 大文字小文字違いがすべて false 等価と確認
- 1.4 — 新規 env は `DEBUGGER_ENABLED` / `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` の 3 種に限定。既存 env var への変更なし（diff で確認）
- 1.5 — 新規ラベル追加なし。`mark_issue_failed` で既存 `claude-failed` のみ流用

### Requirement 2: Debugger サブエージェントの定義と入出力契約

- 2.1 — `repo-template/.claude/agents/debugger.md` + `.claude/agents/debugger.md` の両配置を確認、`diff` で内容一致確認（exit 0）
- 2.2 — `build_debugger_prompt` に必読ファイル列挙 / Bash 差分取得方法 / web search 行使可否を明記
- 2.3 — `validate_debugger_notes` で必須 4 セクションを grep verify、impl-notes.md の helper smoke Test 4-7 で挙動確認
- 2.4 — debugger.md / prompt 両方の禁止事項節で「コード書き換え / ラベル / commit / PR 禁止」を明文化
- 2.5 — debugger.md / prompt 禁止事項節で「requirements / design / tasks / review-notes 書き換え禁止」を明文化
- 2.6 — `run_debugger_stage` 内で `qa_run_claude_stage ... claude --print` 経由で新規プロセス起動（既存 Reviewer と同形、`--resume` 不使用）

### Requirement 3: Reviewer Round 2 reject 直前の Debugger 起動

- 3.1 — `run_impl_pipeline` の Round 2 reject 分岐内に `[ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked` ゲートと `run_debugger_stage "round2-reject"` 起動を確認
- 3.2 — Debugger 成功時に `build_dev_prompt_redo_with_fix_plan` で Stage A'' 起動（Fix Plan inline 注入を確認）
- 3.3 — Stage A'' 成功時に `run_reviewer_stage 3` で Stage B'' 起動
- 3.4 — Round 3 approve 時に case を抜けて既存 Stage C 経路に合流（既存 approve 後経路と同形）
- 3.5 — Round 3 reject 時に `mark_issue_failed "reviewer-reject3"`、コメントに「Debugger は 1 Issue あたり 1 回のみ起動するため再起動しません」を明記
- 3.6 — Debugger 異常終了時 (rc != 0,99) に `mark_issue_failed "debugger-failed"` + return 1。Stage A''/B'' は実行されない

### Requirement 4: Developer 自己宣言 BLOCKED 経路の Debugger 起動

- 4.1 — Stage A 完了直後・stage-a-verify gate 直前に BLOCKED 検出ブロックを挿入確認、`run_debugger_stage "blocked"` 起動
- 4.2 — `detect_blocked_marker` の regex `^BLOCKED: .+$` を確認、impl-notes.md の helper smoke Test 1-3 で list/quote/indent 誤検出抑止を verify
- 4.3 — BLOCKED 経路で `build_dev_prompt_redo_with_fix_plan "" "$debugger_notes_path"` を呼び出し、review_notes_path に空文字を渡す経路を確認
- 4.4 — BLOCKED 経路 Stage A' 成功時にコメント `合流 (Req 4.4)` と共に既存 `stage_a_verify_run` → Stage B (Round 1) に合流
- 4.5 — `developer.md` 追加節「適用範囲（最終手段の位置付け / Req 4.5）」を確認
- 4.6 — 同節「reason 部の記載指針（Req 4.6）」で「試したこと / 不明点 / web search 疑問点」を明記

### Requirement 5: Debugger 起動回数上限と無限ループ防止

- 5.1 — `detect_debugger_already_invoked` で sentinel file `debugger-notes.md` の存在判定。helper smoke Test 8-9 で確認
- 5.2 — 既起動状態での Round 2 reject → `reviewer-reject2` 経路 / BLOCKED → `debugger-blocked-but-invoked` 経路をそれぞれ確認
- 5.3 — Reviewer 起動が `run_reviewer_stage 1/2/3` の 3 回限定（構造的制限）
- 5.4 — Developer 起動が Stage A / A' / A'' の 1 系統のみ実行可能な分岐構造
- 5.5 — sentinel = branch commit に乗る `debugger-notes.md`、impl-resume 再開時にも観測可能

### Requirement 6: Phase 2 per-task loop との統合

- 6.1 — `run_per_task_loop` の per-task Round 2 reject 経路 (case `1)`) に `run_debugger_stage "round2-reject" "$task_id"` 経路を追加確認
- 6.2 — per-task Implementer 完了直後 (impl_rc=0 後) に `detect_blocked_marker` ブロックを挿入、`run_debugger_stage "blocked" "$task_id"` 起動
- 6.3 — `detect_debugger_already_invoked "$task_id"` で task scope sentinel (`## Task <id>` 見出し) を判定。helper smoke Test 10-11 で確認
- 6.4 — `PER_TASK_LOOP_ENABLED != "true"` 時は `run_per_task_loop` 自体が呼ばれず、Issue 単位経路のみ動作
- 6.5 — `build_debugger_prompt` の task_block で task_id 指定時に「対象 task の `_Requirements:_` で列挙された AC のみ verify 対象」を明示

### Requirement 7: env vars と運用者向け制御

- 7.1 — `DEBUGGER_ENABLED="${DEBUGGER_ENABLED:-false}"` 既定 false（diff で確認）
- 7.2 — `DEBUGGER_MODEL="${DEBUGGER_MODEL:-claude-opus-4-7}"` 既定値 + override 可能
- 7.3 — `DEBUGGER_MAX_TURNS="${DEBUGGER_MAX_TURNS:-40}"` 既定値 + override 可能
- 7.4 — `run_debugger_stage` で `claude --permission-mode bypassPermissions` 指定、debugger.md frontmatter で `WebSearch, WebFetch` 宣言
- 7.5 — `DEBUGGER_*` 名前空間限定、既存 env var に touch なし。既存 normalization ループにも加えていない

### Requirement 8: ドキュメント整合と運用者向け説明

- 8.1 — README opt-in 表に `DEBUGGER_ENABLED` 行を追加 + 専用節「Debugger Subagent (Phase 3, #22)」配置
- 8.2 — 専用節内に Stage 遷移を ASCII art で (a) Round 2 reject / (b) BLOCKED の 2 経路図示
- 8.3 — `repo-template/CLAUDE.md` のエージェント連携ルール節に Debugger 項目 1 行追加（diff で確認）
- 8.4 — `repo-template/.claude/agents/developer.md` 末尾に「BLOCKED 宣言の規約」節を追加
- 8.5 — README 専用節「Migration Note」に「既定 false で従来挙動維持」「opt-in 後も起動条件未達 Issue は不変」「追加コストの上限」を明記

### Non-Functional Requirements

- NFR 1.1 — Stage D 分岐 2 箇所が `DEBUGGER_ENABLED=true` ゲート内、dry run #1/#2 で外形挙動不変を確認
- NFR 1.2 — 既存 exit code / `mark_issue_failed` / `$LOG` フォーマットを流用、新規 exit code / ラベル追加なし
- NFR 1.3 — 既存 `run_reviewer_stage` / `run_per_task_implementer` / `run_per_task_reviewer` を流用、書き換えなし
- NFR 2.1 — `dbg_log` で start / end / verify / round3 result の 4 イベントを `$LOG` に append（diff で確認）
- NFR 2.2 — `dbg_log` フォーマット `[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: ...` を helper smoke Test 12 で確認
- NFR 2.3 — ログメッセージに `issue=#<NUMBER>` / `task=<id|none>` 含む（diff で確認）
- NFR 3.1 — README 専用節「累積コスト警告」で `DEBUGGER_MAX_TURNS` 既定 40 ターン + web search 含むコストを明記
- NFR 3.2 — 同節で Debugger 1 + Stage A'' 1 + Round 3 1 = 最大 +3 回の追加コストを明記
- NFR 4.1 — reviewer 側で `shellcheck -S warning local-watcher/bin/issue-watcher.sh` を再実行、`shellcheck: clean` 確認（0 件）
- NFR 4.2 — YAML 変更なしのため `actionlint` 自動的に達成
- NFR 5.1 — `qa_run_claude_stage ... claude --print` で fresh プロセス起動（`--resume` 不使用）
- NFR 5.2 — debugger.md「やらないこと」節で「他エージェントの役割の兼任」を明文禁止

## Boundary 検証

tasks.md の `_Boundary:_` および各タスクの修正範囲制約に照らし、差分 8 ファイルすべて許可境界内:

- `local-watcher/bin/issue-watcher.sh`: Task 1, 3-8 が対象
- `repo-template/.claude/agents/debugger.md` + `.claude/agents/debugger.md`: Task 2 が対象
- `repo-template/.claude/agents/developer.md`: Task 9.1 (_Boundary: developer.md) が対象、既存節改変なしを diff で確認
- `repo-template/CLAUDE.md`: Task 9.2 (_Boundary: repo-template/CLAUDE.md) が対象、+1 行のみで既存節改変なし
- `README.md`: Task 9.3 が対象
- `docs/specs/22-.../tasks.md`: 進捗マーカー `[x]` への変更のみ
- `docs/specs/22-.../impl-notes.md`: Task 10 で Developer が新規作成

requirements.md / design.md / review-notes.md（過去分）への変更なし。Boundary 逸脱なし。

## Findings

なし

## Summary

全 numeric AC（Req 1.1〜8.5 + NFR 1.1〜5.2）の実装裏付けが diff と impl-notes.md の Traceability 表で確認できた。
shellcheck warning レベル 0 件、debugger.md 両ファイル内容一致、boundary 逸脱なし、3 カテゴリでの reject 理由は無し。

RESULT: approve
