# 実装ノート（#219）

## Implementation Notes

### Task 1.1

- **採用方針**: `build_dev_prompt_a` の heredoc テキストのみを変更し、制御フロー・関数シグネチャ・戻り値は不変に保った（design.md Decision D1 / Boundary: build_dev_prompt_a）。
- **重要な判断**:
  - 後段提示表現の削除は impl / impl-resume 双方の heredoc（旧 L3242 / L3259）に同一の置換文を適用した。既存の前段制約文（「本ステージでは PR 作成（project-manager サブエージェント）を行わないこと。Developer 完了後、独立 context の Reviewer サブエージェント…」）は維持し、削除対象は最後の「Reviewer の approve 後に…PR を作成します。」の 1 文のみとした。
  - 主語の弱化は `build_dev_prompt_a` の cat heredoc 冒頭（旧 L3327）のみに限定し、`build_dev_prompt_redo` 等の他関数の主語には触れていない。これにより tasks.md 不在で Stage A へ fallback した design-less impl 経路でも同一の責務限定表現が適用される。
  - 制約節（`## 制約`）には既存の「PR は作成しないこと」を維持したまま「reviewer / project-manager サブエージェントを起動しないこと」を 1 行追加した（Req 1.2 / 1.3）。
  - NFR 1.1 への配慮: 変更はプロンプト本文の責務限定のみで、tasks.md ありの Developer 実装内容や呼び出し元の制御フローには一切影響しない。
- **残存課題**: なし（task 2 以降の越境観測・spec 完全性保証関数の追加は別 task。本 task のスコープ外）。

## 受入基準の達成確認（本 task 担保分）

idd-claude には unit test framework が無く、本 task はプロンプト heredoc のテキスト変更のため、検証は静的解析（`shellcheck` / `bash -n`）と heredoc 内容の目視確認で担保する。

| Req ID | 担保内容 |
|--------|----------|
| 1.1 | Stage A プロンプトの「PR は作成しないこと」制約を維持しつつ、PjM 起動による PR 作成を促す後段提示文を削除。impl PR 作成を促す表現の排除を `build_dev_prompt_a` heredoc で確認 |
| 1.2 | 制約節に「reviewer / project-manager サブエージェントを起動しないこと」を明記。Reviewer 起動表現の除去を確認 |
| 1.3 | 同上（project-manager サブエージェント起動の禁止を制約節に明記） |
| 1.4 | 主語を「サブオーケストレーター（PM + Developer 担当）」へ弱化し、後段フロー全体（Reviewer / PjM 起動・PR 作成）の完遂を促す表現を排除。design-less impl 経路（Stage A fallback）でも同一プロンプトが適用される |
| NFR 1.1 | heredoc テキスト変更のみで制御フロー・関数シグネチャ・戻り値・呼び出し元の分岐は不変。tasks.md あり経路の Developer 実装内容を変えないことを確認 |

## 検証ログ（本 task）

- `bash -n local-watcher/bin/issue-watcher.sh` → `syntax OK`
- `shellcheck local-watcher/bin/issue-watcher.sh` → 既存の SC2317 (info) 5 件のみ。いずれも logger 関数群（L987 / L1346 / L2778 / L5401 / L5915）に関するもので本 task の変更箇所外。本変更による新規警告ゼロを確認

## Implementation Notes（Reviewer round=1 reject 後の是正 / task 2〜6）

### 是正の背景

Reviewer round=1（review-notes.md Finding 1）は、本ブランチが task 1.1（プロンプト責務限定）
のみで Requirement 2 / 3 / 4 が未実装（関連関数・ログ・README 追記すべて 0 件）であることを
AC 未カバーとして reject した。本サイクルで tasks.md task 2〜6 を design.md の Components and
Interfaces / File Structure Plan / Decisions D2〜D4 に厳密に従って実装した。

### 実装した関数（すべて Stage Checkpoint Module 内 `stage_c_existing_pr_guard` 直後に配置）

| 関数 | task | 役割 |
|------|------|------|
| `stage_a_crossing_probe` | 2.1 | Stage A 完了直後の越境観測（read-only）。`stage_checkpoint_find_impl_pr` を再利用し rc=0/1/2 を分岐。検出時のみ `stage-a-crossing: detected pr=#<N> state=<S> branch=<BRANCH> issue=#<NUMBER>` をログ。グローバル変数 `STAGE_A_CROSSING_DETECTED`(yes/no) / `STAGE_A_CROSSING_PR` を set。常に return 0 |
| `_spec_missing_artifacts` | 3.1 | branch HEAD tracked で requirements.md / review-notes.md の欠落種別を stdout 列挙。design.md / tasks.md は補完対象外だが検査ログ（`missing-design=`）には記録。不足検出時のみ `spec-completeness: missing=... dir=...` をログ |
| `_spec_create_docs_pr` | 4.1 | head `claude/issue-<N>-docs-<SLUG>`、base `$BASE_BRANCH`（`--base` 明示）の docs-only 補完追従 PR を作成。作成前に `gh pr list --head <docs-branch> --state all` で既存 docs PR を再観測し冪等化。`ready-for-review` 非付与。失敗時 sc_warn + 非 0 return |
| `_spec_escalate_incomplete` | 4.2 | 補完不能時のみ `needs-decisions` 付与 + Issue コメント 1 件。`gh issue view --json labels` の既付与チェックでコメント冪等化。`gh issue edit/comment` は `\|\| true` で fail-open |
| `spec_artifacts_completeness_guard` | 5.1 | orchestrator。gate で即 return 0。`_spec_missing_artifacts` が空なら return 0（Req 3.5）。`stage_checkpoint_find_impl_pr` で state 取得し MERGED かつ req/review 欠落のときのみ `_spec_create_docs_pr` 起動、失敗時 `_spec_escalate_incomplete` フォールバック。MERGED 以外（OPEN/CLOSED/none）/ gh API エラーは補完を起動せず記録のみ。常に return 0 |

### 結線箇所（task 2.2 / 5.2）

- `stage_a_crossing_probe`: 通常 Developer 経路の `✅ Stage A 完了`（現 L4847）直後と per-task loop 経路の `✅ Stage A 完了（per-task loop）`（現 L4804）直後の 2 箇所
- `spec_artifacts_completeness_guard`: Stage C 冪等ガード停止経路（`stage_c_existing_pr_guard` 成功時の return 0 直前 / 現 L5311）と Stage C 成功経路（PR verify 成功時の return 0 直前 / 現 L5356）の 2 箇所
- グローバル変数 `STAGE_A_CROSSING_DETECTED` / `STAGE_A_CROSSING_PR` は `run_impl_pipeline` スコープで `local` 宣言（既存 `START_STAGE` と同パターン）。set/read が別関数間の dynamic scope 経由のため SC2034 を `# shellcheck disable=SC2034` で抑制（`START_STAGE` の既存先例に倣う）

### 重要な実装判断

- **`stage_c_existing_pr_guard` は一切変更していない**（Req 4.1 退行防止 / Decision D3）。`git diff main..HEAD` 上で当該関数本体・呼び出しに差分が無いことを確認済み（diff に現れるのは新規コメント中の関数名参照のみ）。完全性保証は同関数の **後段の独立経路**として呼ぶ
- **docs-only PR の head ブランチは impl ブランチと別系統**（`claude/issue-<N>-docs-<SLUG>`）。#213 の MERGED ガード（`--head $BRANCH` 判定）と head が異なるため衝突せず、新規 impl PR を構造的に二重作成しない（Req 4.2 / 4.3）
- **補完対象を requirements / review に限定**（Req 3.2）。design.md / tasks.md は設計 PR で別途 merge される成果物であり docs commit で機械再構築できないため `_spec_missing_artifacts` の補完対象から除外し、検査ログ（`missing-design=`）にのみ記録する（design.md Data Models）
- **補完 placeholder の内容**: 実値の機密情報を埋め込まず、自動補完された placeholder である旨と人間による正規内容への更新を促すコメントのみを記載（Security Considerations）
- **Req 2.4 引き継ぎの実消費**: `spec_artifacts_completeness_guard` が action ログに `crossing=<yes|no> crossing-pr=#<N>` を含め、`STAGE_A_CROSSING_DETECTED` / `STAGE_A_CROSSING_PR` を実際に read することで、越境起因の欠落補完を grep で識別可能にした
- **README**: 新規 env var を足さず `STAGE_CHECKPOINT_ENABLED` 相乗りのため migration note は不要。Stage Checkpoint (#68) 節に小節を追加し、`=false` で両ログが 1 行も出ず本修正導入前と完全同一である旨を明記。オプション機能一覧表の Stage Checkpoint Resume 行に #212 / #219 内包を追記

### 検証ログ（task 2〜6 / task 6.2）

- `bash -n local-watcher/bin/issue-watcher.sh` → `syntax OK`
- `shellcheck local-watcher/bin/issue-watcher.sh` → SC2317 (info) のみ 11 件（5 ユニーク logger 行 = sc_error L987 / tc_error L1700 / debugger warn L3132 / slot error L5785 / dr error L6299、いずれも本変更箇所外の logger を indirect 呼び出しと判定する既存 info）。本変更による新規警告ゼロ。当初発生した `STAGE_A_CROSSING_DETECTED` / `_PR` の SC2034 は dynamic scope read を実装し `# shellcheck disable=SC2034` を付与して解消済み
- fixture: `test-fixtures/spec-complete/`（requirements.md / review-notes.md / impl-notes.md）と `test-fixtures/spec-incomplete-merged/`（impl-notes.md のみ）を作成・commit（branch HEAD tracked 判定のため commit 必須）
- 関数単位スモーク（`/tmp/smoke-219*.sh`、実関数を awk 抽出し `stage_checkpoint_find_impl_pr` / 補助関数をモック化して実行）:
  - **T1（NFR 1.1 / Req 2.5）**: `STAGE_CHECKPOINT_ENABLED=false` で `stage_a_crossing_probe` + `spec_artifacts_completeness_guard` が `stage-a-crossing:` / `spec-completeness:` ログを **0 行** → PASS
  - **T2（Req 3.5）**: `spec-complete` fixture で `_spec_missing_artifacts` 空出力 → PASS
  - **T3（Req 3.4）**: `spec-incomplete-merged` fixture で `requirements review` 列挙 → PASS
  - **T4（Req 2.2 / 2.3）**: probe rc=0 で `STAGE_A_CROSSING_DETECTED=yes` + `stage-a-crossing: detected pr=#218 state=OPEN ...` ログ → PASS
  - **T5（Req 2.1）**: probe rc=1 で DETECTED=no + ログなし → PASS
  - **T6（Error Handling）**: probe rc=2 で sc_warn + DETECTED=no（安全側） → PASS
  - **T7（Data Models）**: design 系欠落が `missing-design=design tasks` で検査ログに記録（補完対象外） → PASS
  - **G1b（Req 3.5 / NFR 1.1）**: 充足 spec で補完アクション 0 + 早期 return 0 → PASS
  - **G2（Req 3.2）**: 欠落 + MERGED で `_spec_create_docs_pr` 起動（`trigger=merged` + `action=docs-pr`） → PASS
  - **G3（Req 3.3）**: 欠落 + MERGED + docs-pr 失敗で `_spec_escalate_incomplete` フォールバック → PASS
  - **G4b（Req 4.1）**: 欠落 + OPEN で補完起動せず `action=none reason=not-merged state=OPEN` → PASS
  - **G5b（Req 4.1）**: 欠落 + PR なし（none）で `action=none reason=not-merged state=(none)` → PASS
  - **G6b（Error Handling 安全側）**: 欠落 + gh API エラーで補完起動せず `action=none reason=gh-api-error` + return 0 → PASS

> 注: dry run（`REPO=owner/test ... issue-watcher.sh`）と cron-like 最小 PATH 依存解決は gh 認証 / ネットワーク前提のため本サンドボックスでは実行していない。スクリプトロード時の構文健全性は `bash -n` で担保し、新規関数の挙動は上記の関数単位スモーク（実関数 awk 抽出 + 外部 gh をモック化）で担保した。

## 受入基準の達成確認（task 2〜6 担保分）

| Req ID | 担保内容 |
|--------|----------|
| 2.1 | `stage_a_crossing_probe` が Stage A 完了直後（2 経路）で `stage_checkpoint_find_impl_pr` により先行 PR 有無を観測（スモーク T4/T5） |
| 2.2 | 検出時 `sc_log "stage-a-crossing: detected ..."` を既存ログ書式で出力（T4） |
| 2.3 | ログ行に `pr=#<N>` と `branch=<BRANCH>` を判定根拠として含む（T4） |
| 2.4 | グローバル変数 `STAGE_A_CROSSING_DETECTED` / `STAGE_A_CROSSING_PR` を set し `spec_artifacts_completeness_guard` が `crossing=` ログで read（T4 / G4b の `crossing=yes crossing-pr=#218`） |
| 2.5 | gate off で probe が 1 行も出力しない（T1） |
| 3.1 | `spec_artifacts_completeness_guard` を pipeline 末尾 2 経路に結線し最終状態の標準構成を保証（G1b/G2） |
| 3.2 | MERGED かつ req/review 欠落で `_spec_create_docs_pr`（docs-only 補完 PR）起動（G2） |
| 3.3 | docs-pr 失敗時に `_spec_escalate_incomplete`（needs-decisions + コメント）でエスカレーション（G3） |
| 3.4 | `_spec_missing_artifacts` が `spec-completeness: missing=... dir=...` を既存ログ書式で出力（T3/T7） |
| 3.5 | 標準構成充足時は補完アクション 0 + early return 0（G1b） |
| 4.1 | `stage_c_existing_pr_guard` 不変（main 差分なし）+ MERGED 以外で補完を起動しない（G4b/G5b） |
| 4.2 | MERGED の新規 impl PR 抑止を維持（impl PR を作らず docs-only PR のみ。head 別系統 / G2） |
| 4.3 | docs-only PR を impl ブランチと別 head `claude/issue-<N>-docs-<slug>` で作成（`_spec_create_docs_pr` 実装 / G2） |
| NFR 1.1 | gate off で `stage-a-crossing:` / `spec-completeness:` ログ 0 行（T1）。充足ケースで追加処理なし（G1b） |
| NFR 1.4 | probe / guard ともに常に return 0（T4〜T6 / G1b〜G6b の rc=0） |
| NFR 1.5 | 新規ログは `sc_log` で追加するのみ（既存行は不変） |
| NFR 2.1 | `_spec_create_docs_pr` が作成前に既存 docs PR を `gh pr list --head` で再観測し冪等化（実装） |
| NFR 2.2 | `_spec_escalate_incomplete` が `needs-decisions` 既付与チェックでコメント冪等化（実装） |
| NFR 3.1 | `stage-a-crossing:` prefix で grep 可能（T4） |
| NFR 3.2 | `spec-completeness:` prefix で grep 可能（T3/T7/G2） |

## 確認事項（task 2〜6）

- 現時点で design.md / tasks.md / requirements.md 間の矛盾は確認されなかった。
- `_spec_create_docs_pr` の補完内容は placeholder（自動補完である旨を明記）とした。requirements.md は
  本来 PM、review-notes.md は Reviewer の成果物であり docs commit で正規内容を機械再構築できないため、
  spec ディレクトリの **標準構成（ファイル存在）を満たす** ことを目的とし、正規内容への更新は人間に
  委ねる設計とした（design.md Data Models / Decision D2 の責務分掌に整合）。Reviewer が本判断の妥当性を
  確認されたい。
- dogfooding E2E（#216 相当の test issue で docs-only 補完 PR の 1 本生成・2 サイクル連続実行での重複なし）は
  本サイクルでは未実施（gh 認証 / 実 Issue 前提）。関数単位スモークで決定論的に分岐を担保した。

STATUS: complete
