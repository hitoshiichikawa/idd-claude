# Implementation Notes — Phase 3: Debugger Subagent (#22)

## 概要

Issue #22「Phase 3: Debugger subagent の追加（BLOCKED / 2 連続 reject 時の root cause 分析）」の
実装結果を記録する。Developer 実装担当の作業ログ。

- **対象 Issue**: #22
- **作業ブランチ**: `claude/issue-22-impl-phase-3-debugger-subagent-blocked-2-reje`
- **入力**: `requirements.md` / `design.md` / `tasks.md`（人間レビュー済み、書き換えなし）
- **対象 spec dir**: `docs/specs/22-phase-3-debugger-subagent-blocked-2-reje/`

---

## 完了タスク

`tasks.md` の Task 1〜9 を numeric ID 順に消化（Task 10 は本ファイル含む静的解析 / 手動スモーク結果記録）。
Task 10.1（Phase 2 統合 dogfooding）は deferrable `- [ ]*` 印付きのため未着手。

| Task ID | 概要 | commit (実装) | commit (進捗マーカー) |
|---|---|---|---|
| 1 | env vars 追加（DEBUGGER_ENABLED / MODEL / MAX_TURNS） | `88a97a5` | `5bdb1a1` |
| 2 | Debugger エージェント定義（repo-template + self-hosting） | `bdfd648` | `2e9d4c9` |
| 3 (3.1-3.4) | watcher: ヘルパ関数群（dbg_log / detect_blocked / detect_invoked / validate） | `294505e` | `fb2ba74` |
| 4 (4.1-4.2) | watcher: build_debugger_prompt / run_debugger_stage | `cd9fb6c` | `720c4da` |
| 5 | watcher: build_dev_prompt_redo_with_fix_plan | `7d71ce1` | `873559c` |
| 6 | watcher: Stage B' (Round 2 reject) 経路への Debugger 組込 | `45e2a21` | `3e4b698` |
| 7 | watcher: BLOCKED 検出経路への Debugger 組込 | `bc2499f` | `87c160f` |
| 8 | watcher: Phase 2 (per-task loop) との統合 | `deca416` | `3911d66` |
| 9 (9.1-9.3) | docs: developer.md / CLAUDE.md / README.md 更新 | `9f13cfc` `2ca5d53` `28ff9dc` | `ba14a36` |
| 10 | 静的解析と手動スモーク結果記録 | （本ファイル） | （後続 commit） |

Task 10.1（deferrable）は未着手。

---

## 受入基準のテスト紐付け（Requirements Traceability）

`requirements.md` の全 numeric ID を以下で担保した。本リポジトリは bash スクリプト本体で
単体テストフレームワークを持たないため、手動スモーク + shellcheck + 既存コード読み合わせで verify。

### Requirement 1: opt-in による既存挙動の保全

| AC | 担保方法 |
|---|---|
| 1.1 | `[ "${DEBUGGER_ENABLED:-false}" = "true" ]` ゲートで Stage D 分岐を構造的 skip。dry run #1 / #2 で外形挙動が変わらないことを確認 |
| 1.2 | BLOCKED 検出ブロックも同ゲート内に配置。`DEBUGGER_ENABLED != "true"` で `detect_blocked_marker` を呼ばないため BLOCKED 行は判定材料にならない |
| 1.3 | 値判定 smoke で確認（`True` / `1` / `Yes` / unset / 空文字すべて false 扱い、`true` 厳密一致のみ有効） |
| 1.4 | 新規 env は `DEBUGGER_*` 名前空間のみ。既存 env var 名（`DEV_MODEL` 等）に触れていない（diff で確認可能） |
| 1.5 | 新規ラベル追加なし。`mark_issue_failed` 経路で既存 `claude-failed` ラベルのみ流用 |

### Requirement 2: Debugger サブエージェントの定義と入出力契約

| AC | 担保方法 |
|---|---|
| 2.1 | `repo-template/.claude/agents/debugger.md` と `.claude/agents/debugger.md` を `cp` で明示的に同一コピー配置（symlink ではない）。`diff` で内容一致確認 |
| 2.2 | `build_debugger_prompt` 内に必読ファイル列挙 / Bash 差分取得方法 / web search 行使可否を明記 |
| 2.3 | `validate_debugger_notes` で必須 4 セクション（`## 根本原因` / `## 修正手順` / `## 検証方法` / `## 関連参考資料`）の存在を grep verify。helper smoke Test 4/5/6/7 で確認 |
| 2.4 | debugger.md / prompt の禁止事項節で「コード書き換え / ラベル付け替え / commit 禁止」を明文化 |
| 2.5 | debugger.md / prompt の禁止事項節で「requirements / design / tasks / review-notes 書き換え禁止」を明文化 |
| 2.6 | `run_debugger_stage` 内で `qa_run_claude_stage ... claude --print` 経由で新規プロセス起動（既存 Reviewer / Developer と同形、`--resume` 不使用） |

### Requirement 3: Reviewer Round 2 reject 直前の Debugger 起動

| AC | 担保方法 |
|---|---|
| 3.1 | Stage B' (round=2) reject 分岐内に `if [ "${DEBUGGER_ENABLED:-false}" = "true" ] && ! detect_debugger_already_invoked` ゲートを挿入。run_debugger_stage を 1 回起動 |
| 3.2 | run_debugger_stage 成功時に `build_dev_prompt_redo_with_fix_plan` で Stage A'' 起動 |
| 3.3 | Stage A'' 成功時に `run_reviewer_stage 3` で Stage B'' (Round 3) 起動 |
| 3.4 | Round 3 approve 時に case を抜けて既存 Stage C 経路に合流 |
| 3.5 | Round 3 reject 時に `mark_issue_failed "reviewer-reject3"` で claude-failed。Debugger 再起動なし（コメントに明記） |
| 3.6 | Debugger 異常終了時 (case `*)` of `_dbg_rc`) に `return 1`。Stage A'' / B'' は実行されない |

### Requirement 4: Developer 自己宣言 BLOCKED 経路の Debugger 起動

| AC | 担保方法 |
|---|---|
| 4.1 | Stage A 完了直後・stage-a-verify gate 直前に BLOCKED 検出ブロックを挿入。`DEBUGGER_ENABLED=true` ゲート内で `detect_blocked_marker` → `run_debugger_stage "blocked"` |
| 4.2 | helper smoke Test 1/2/3 で行頭固定 regex `^BLOCKED: (.+)$` の挙動確認（list / quote / indent 付きを誤検出しない） |
| 4.3 | BLOCKED 経路の Debugger 成功時に `build_dev_prompt_redo_with_fix_plan "" "$debugger_notes_path"` で Stage A' 起動（review-notes.md は空文字を渡す） |
| 4.4 | BLOCKED 経路 Stage A' 成功後、case を抜けて通常の `stage_a_verify_run` → Stage B (Round 1) に合流 |
| 4.5 | `developer.md` の「BLOCKED 宣言の規約」節で「最終手段の位置付け」を明文化 |
| 4.6 | 同節で reason 部の記載指針（試したこと / 不明点 / web search 疑問点）を明文化 |

### Requirement 5: Debugger 起動回数上限と無限ループ防止

| AC | 担保方法 |
|---|---|
| 5.1 | `detect_debugger_already_invoked` で sentinel file（`debugger-notes.md`）の存在で判定。helper smoke Test 8/9 で確認 |
| 5.2 | 既起動状態での後続 Reviewer reject → `mark_issue_failed "reviewer-reject2"` 経路 / BLOCKED → `mark_issue_failed "debugger-blocked-but-invoked"` |
| 5.3 | Reviewer 起動は `run_reviewer_stage 1`, `run_reviewer_stage 2`, `run_reviewer_stage 3` の 3 回のみ呼び出し（構造的制限） |
| 5.4 | Developer 起動は Stage A / A' / A'' のいずれか 1 系統のみ実行（case 分岐で構造的制限） |
| 5.5 | sentinel は `debugger-notes.md` ファイル = branch commit に乗るため、impl-resume 再開時にも判定可能（既存 `IMPL_RESUME_PRESERVE_COMMITS=true` 規約と整合） |

### Requirement 6: Phase 2 per-task loop との統合

| AC | 担保方法 |
|---|---|
| 6.1 | `run_per_task_loop` の per-task Round 2 reject 経路（case `1)` of `rev2_rc`）に `run_debugger_stage "round2-reject" "$task_id"` 経路を追加 |
| 6.2 | per-task Implementer 完了直後（`impl_rc=0` の後）に `detect_blocked_marker` ブロックを挿入し、`run_debugger_stage "blocked" "$task_id"` 経路で task 単位起動 |
| 6.3 | `detect_debugger_already_invoked "$task_id"` で task scope sentinel（`## Task <id>` 見出し）を判定。helper smoke Test 10/11 で確認 |
| 6.4 | `PER_TASK_LOOP_ENABLED != "true"` 時は `run_per_task_loop` 自体が呼ばれないため、Issue 単位の Stage D 経路（Task 6/7 実装）のみ動作 |
| 6.5 | `build_debugger_prompt` の `task_block` で task_id 指定時に「対象 task の `_Requirements:_` で列挙された AC のみ verify 対象」を明示 |

### Requirement 7: env vars と運用者向け制御

| AC | 担保方法 |
|---|---|
| 7.1 | `DEBUGGER_ENABLED="${DEBUGGER_ENABLED:-false}"` で既定 false 設定済み |
| 7.2 | `DEBUGGER_MODEL="${DEBUGGER_MODEL:-claude-opus-4-7}"` で既定値 + override 可能 |
| 7.3 | `DEBUGGER_MAX_TURNS="${DEBUGGER_MAX_TURNS:-40}"` で既定値 + override 可能 |
| 7.4 | `run_debugger_stage` 内で `claude --permission-mode bypassPermissions` を指定（既存 Reviewer / Developer と同形、WebSearch / WebFetch 行使可） |
| 7.5 | `DEBUGGER_*` 名前空間に限定。既存 env var に触れていない（既存 normalization ループにも加えていない） |

### Requirement 8: ドキュメント整合と運用者向け説明

| AC | 担保方法 |
|---|---|
| 8.1 | README.md の opt-in 表に `DEBUGGER_ENABLED` 行を追加 + 専用節「Debugger Subagent (Phase 3, #22)」追加 |
| 8.2 | 専用節内に Stage 遷移を ASCII art で 2 経路（Round 2 reject / BLOCKED）図示 |
| 8.3 | `repo-template/CLAUDE.md` のエージェント連携ルール節に Debugger 項目を 1 行追加 |
| 8.4 | `repo-template/.claude/agents/developer.md` 末尾に「BLOCKED 宣言の規約」節を追加 |
| 8.5 | README 専用節に Migration Note（既定 false で従来挙動維持 / 起動条件未達 Issue は不変 / 追加コスト 0）を明記 |

### Non-Functional Requirements

| NFR | 担保方法 |
|---|---|
| 1.1 | `DEBUGGER_ENABLED != "true"` で全 Stage D 分岐が構造的 skip。dry run #1/#2 で確認 |
| 1.2 | 既存 exit code / mark_issue_failed / `$LOG` フォーマットを流用（新規ラベル / 新 exit code なし） |
| 1.3 | 既存 #20 / #21 のヘルパ関数（`run_reviewer_stage` / `run_per_task_implementer` 等）を流用、書き換えなし |
| 2.1 | `dbg_log` で 4 イベント（start / end / verify / round3 result）を `$LOG` に append |
| 2.2 | `dbg_log` のフォーマット `[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: ...` を helper smoke Test 12 で確認 |
| 2.3 | ログメッセージに `issue=#<NUMBER>` / `task=<id|none>` を含む |
| 3.1 | README 専用節「累積コスト警告」で `DEBUGGER_MAX_TURNS` 既定 40 ターン + web search 含むコストを明記 |
| 3.2 | 同節で Debugger 1 + Stage A'' 1 + Round 3 1 = 最大 +3 回の追加コストを明記 |
| 4.1 | `shellcheck -S warning local-watcher/bin/issue-watcher.sh` で 0 件確認（後述「静的解析結果」） |
| 4.2 | YAML 変更なしのため `actionlint` 自動的に達成 |
| 5.1 | `qa_run_claude_stage ... claude --print` で fresh プロセス起動（既存 Reviewer と同形、`--resume` 不使用） |
| 5.2 | debugger.md の責務節で「他エージェント役割の兼任禁止」を明記 |

---

## 静的解析結果

### shellcheck

```
$ shellcheck -S warning local-watcher/bin/issue-watcher.sh
（exit 0、warning 以上のメッセージは 0 件）
```

新規追加した関数群について info レベルの SC2317（unreachable）が出るが、既存
ヘルパ群（`per-task-*` / `qa_*` / `pclp_*` 等）と同パターンであり、`shellcheck` 自身が
動的呼び出しを追跡できないため出ているもの。実際は `run_impl_pipeline` / `run_per_task_loop`
から呼ばれる。

`detect_debugger_already_invoked` の SC2120（references arguments, but none are ever passed）
は意図設計（optional task_id）のため `# shellcheck disable=SC2120` directive で抑止。

### actionlint

YAML ワークフロー（`.github/workflows/*.yml`）への変更なしのため自動的に達成。

---

## 手動スモークテスト結果

### dry run #1: DEBUGGER_ENABLED 未設定

```
REPO=local/test-debugger REPO_DIR=/tmp/debugger-dry-test LOCK_FILE=... LOG_DIR=... \
  /home/hitoshi/.issue-watcher/.../local-watcher/bin/issue-watcher.sh
```

結果: exit 0。既存 base-branch / quota-aware / merge-queue / pr-iteration の各 Processor が
通常通り起動し、`debugger:` prefix のログは一切出力されない。Debugger Gate 分岐は構造的に
skip されている（Req 1.1, 1.2 / NFR 1.1）。

### dry run #2: DEBUGGER_ENABLED=false 明示

同上のコマンドに `DEBUGGER_ENABLED=false` を追加。結果は dry run #1 と完全に同一
（`debugger:` ログ 0 件 / exit 0 / 外形挙動の差異なし）。typo / 大文字小文字違いの
誤検出がないことを確認（Req 1.3）。

### dry run #3: typo 互換性テスト（bash 単独）

```bash
for v in True 1 Yes "" "true"; do
  [ "${v:-false}" = "true" ] && echo "$v: TRUE" || echo "$v: FALSE"
done
# True: FALSE / 1: FALSE / Yes: FALSE / "": FALSE / "true": TRUE
```

`true` 厳密一致のみが true 扱いとなり、それ以外（typo / 大文字小文字違い / 空文字）は
すべて false 等価で扱われることを確認（Req 1.3）。

### ヘルパ関数 smoke test（12 件すべて PASS）

`/tmp/dbg-smoke/test-helpers.sh` で以下を確認:

1. ✅ `detect_blocked_marker` 正常検出（`BLOCKED: vitest@1.6.0 ...` から reason 抽出）
2. ✅ `detect_blocked_marker` 誤検出抑止（list marker `- BLOCKED:` / 引用 `> BLOCKED:` /
   インデント `  BLOCKED:` をすべて不一致扱い）
3. ✅ `detect_blocked_marker` ファイル不在時 return 1
4. ✅ `validate_debugger_notes` Issue 単位 / 全 h2 4 セクション存在で return 0
5. ✅ `validate_debugger_notes` Issue 単位 / 部分欠落で return 1
6. ✅ `validate_debugger_notes` task 単位 / `## Task 1.2` + h3 4 セクション存在で return 0
7. ✅ `validate_debugger_notes` task 単位 / wrong task_id（`2.1` 指定時、存在しない）で return 1
8. ✅ `detect_debugger_already_invoked` Issue 単位 / sentinel ファイル存在で return 0
9. ✅ `detect_debugger_already_invoked` Issue 単位 / sentinel 不在で return 1
10. ✅ `detect_debugger_already_invoked` task 単位 / `## Task 1.2` 存在で return 0
11. ✅ `detect_debugger_already_invoked` task 単位 / 別 task ID（`3.1` 指定）で return 1
12. ✅ `dbg_log` 出力フォーマット（`[YYYY-MM-DD HH:MM:SS] [$REPO] debugger: <msg>`）

### `build_debugger_prompt` 出力 smoke test（6 件中 5 件 PASS、1 件は test-script 側の文字コード差）

`/tmp/dbg-smoke/test-prompt.sh` で以下を確認:

- ✅ Test A: trigger=round2-reject / Issue 単位の prompt 構造（必読 / Bash 差分 / 出力スキーマ /
  禁止事項のすべてのセクションを含む）
- ✅ Test B: trigger=blocked / Issue 単位（BLOCKED 経路の説明文を含む）
- ✅ Test C: trigger=round2-reject / task_id=1.2（Phase 2 経路 / `## Task 1.2` schema を明示）
- ✅ Test D: 必須 4 セクション名（根本原因 / 修正手順 / 検証方法 / 関連参考資料）が prompt に
  含まれる
- ✅ Test E: BLOCKED 経路で review-notes.md を必読扱いしない
- ⚠️ Test F: round2-reject 経路で review-notes.md を必読扱いする — 実際の prompt 出力には
  含まれているが、test-script の grep が fullwidth 括弧（`（` U+FF08）の照合に失敗した。
  目視確認では正しく含まれている（実装は正しい）

### dogfood smoke（idd-claude 実 Issue を立てた E2E）

本 worktree から実 Issue を立てて Debugger Gate を E2E で流すのは、本実装が `main` に
merge されていない時点では困難（cron が拾うのは main の `issue-watcher.sh`）。よって
E2E 検証は本 PR merge 後の dogfooding に委ねる。**impl-notes.md「確認事項」**を参照。

---

## 追加した依存

なし。既存の `gh` / `jq` / `claude` / `git` / `flock` / `timeout` のみで実装。

---

## 補足ノート

### 実装上の判断

- **task scope sentinel の文字列パターン**: design.md の指示通り `## Task <id>` を h2 で
  検出する形を採用（per-task では debugger-notes.md 全体が「Debugger Notes (Issue #N)」+
  各 task の `## Task <id>` セクションの集合になる）。Issue 単位は単に
  `debugger-notes.md` ファイル存在で判定（最初の起動時は h2 が 4 セクション形式、Phase 2
  時は h2 が Task <id>、その配下に h3 4 セクション、という 2 形態を 1 ファイルに同居させる）
- **per-task Round 3 の prev_result**: `run_per_task_reviewer` は round=2 のみ
  prev_result を読む既存実装。Round 3 は post-Debugger なので review-notes.md の round=2
  情報を読ませる方が情報量は多いが、構造を最小変更に留めるため round=3 では `(none)` のまま
  にした。Debugger Fix Plan が主たる手がかりなので影響は小さい。改善は将来課題
- **Stage A'' / Stage A'（BLOCKED 経路）の prompt builder の review_notes_path の扱い**:
  Stage A''（Round 2 経路）は review-notes.md path を渡し、Stage A'（BLOCKED 経路）は空文字を
  渡す。`build_dev_prompt_redo_with_fix_plan` が空文字を受けて「Reviewer 経由ではない」
  メッセージを出すため、Developer 側は明確に状況を区別できる
- **dbg_log の SC2120 (optional 引数) 抑止**: design.md でも optional 引数として明示
  されているので shellcheck disable directive で抑止。命名 / 戻り値 / 副作用は既存
  pt_log / rv_log と整合

### 確認事項（design / tasks との矛盾、人間判断保留事項）

- **per-task Implementer の Fix Plan 注入方式**: design.md 「Phase 2 統合」では Implementer
  再起動を `build_per_task_implementer_prompt` 経由で行うことが暗黙の前提だが、本 prompt builder
  は Fix Plan inline 注入機能を持たない。本実装では「Implementer が `impl-notes.md` /
  `debugger-notes.md` 内の `### Task <id>` セクションを `Read` で読む」ことに依拠している
  （debugger.md の責務節と prompt の必読ファイル列挙で誘導）。Phase 2 + Phase 3 統合の
  完全な E2E 動作は dogfooding で確認必要
- **per-task Reviewer Round 3 の prev_result**: 既存 `run_per_task_reviewer` は round=2 のみ
  prev_result を読む。Round 3 では `(none)` 扱いになるが、Debugger Fix Plan が主信号なので
  影響は限定的と判断（上記「実装上の判断」参照）。改善余地として将来別 Issue で扱う
- **dogfood E2E スモーク未実施**: 本 worktree からは実 Issue を立てて Debugger Gate を
  end-to-end で流すことが困難なため、ヘルパ関数の単体動作確認と prompt 出力確認で代替。
  本 PR merge 後の dogfooding で以下 3 経路を実機検証することを推奨:
  - Reviewer Round 2 reject 経路（故意 reject で Stage D → A'' → B'' → approve / reject）
  - BLOCKED 経路（Developer に `BLOCKED:` 行を意図的に出させる）
  - 既起動 sentinel での再起動抑止（`debugger-notes.md` が既存する状態で Round 2 reject 発生）
- **debugger-notes.md の commit 主体**: design.md では Debugger 自身が commit しない規約
  だが、Developer 再起動時に `debugger-notes.md` が staging に残っていると Developer が
  commit する可能性がある。本実装では Developer 側に「debugger-notes.md を書き換えない」
  と指示しているが、`git add` 自体を抑止していない。実運用で混ざる場合は将来 Issue で扱う

### 次の Issue として切り出すべき派生タスク

- **per-task Round 3 prev_result 注入**: round=3 で round=2 の RESULT 行を `run_per_task_reviewer`
  が読むよう拡張
- **per-task Implementer の Fix Plan 注入版 prompt builder**: `build_per_task_implementer_prompt`
  に Debugger Fix Plan inline 注入バリアントを追加
- **dogfood E2E スモークの実機検証**: 本 PR merge 後の最初の機会で Round 2 reject / BLOCKED / 既起動の 3 経路を回す
- **debugger-notes.md staging 隔離**: Debugger が書いたファイルを Developer が再起動時に
  誤 commit しないようにする git add 制御（または .gitattributes 等の規約）
- **`/.github/workflows/issue-to-pr.yml` への移植**: design.md の Non-Goals では本 Issue 範囲外。
  Actions 版での Debugger Gate サポートは別 Issue
