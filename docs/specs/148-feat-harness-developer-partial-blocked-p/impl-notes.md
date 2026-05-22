# Implementation Notes

## 実装サマリ

Issue #148「feat(harness): Developer の partial_blocked / partial_overrun を 1st-class
シグナルとして扱う」の実装が完了した。Developer 出力契約に `partial_blocked` /
`partial_overrun` の 2 新規 status code を追加し、orchestrator は Reviewer 起動を skip
して `needs-decisions` 自動付与 + エスカレーションコメント投稿で人間判断に委ねるフローを
確立した。

実装は Stage A 完了直後（既存 Stage A 完了 echo の直後・stage-a-verify gate の前）に
1 つの「Partial Status Gate」を挿入する形で、既存の Debugger Gate / Stage Checkpoint
Resume / stage-a-verify / Quota-Aware Watcher と完全に独立に動作する。status 行不在 /
`STATUS: complete` の場合は副作用なしで既存フローを継続し、構造的に NFR 1.1 / 1.4 を
保証する。

## 変更ファイル一覧

| ファイル | 変更種別 | 概要 |
|---|---|---|
| `local-watcher/bin/issue-watcher.sh` | 新規 helper 4 関数 + Stage A 完了直後 5 箇所への gate 挿入 | `detect_partial_status` / `build_partial_escalation_comment` / `mark_issue_needs_decisions` / `handle_partial_status` の 4 関数を追加。`run_impl_pipeline` の per-task loop / 通常 Developer / Stage A' BLOCKED / Stage A' Reviewer reject / Stage A'' Debugger 経由の 5 箇所に `handle_partial_status` 呼出を挿入 |
| `.claude/agents/developer.md` | 新規セクション追記 | 「# 出力契約（impl-notes.md 末尾の STATUS 行）」節を追加。STATUS 行規約 / partial 報告時の追加出力 / 自己判断条件 / 後方互換を明文化 |
| `repo-template/.claude/agents/developer.md` | 同上（完全同一） | consumer repo に install で配布される正本 |
| `.claude/agents/reviewer.md` | 1 段落追記 | 「## partial status との関係（informational）」段落を追加。Reviewer は partial 経路では起動されない旨を informational に明記 |
| `repo-template/.claude/agents/reviewer.md` | 同上（完全同一） | consumer repo 用正本 |
| `README.md` | 新規節 + 既存表追記 | 「## Developer Partial Status Codes (#148)」節を Debugger と Feature Flag Protocol の間に新設。「常時有効（opt-out 不可）」表にも本機能を追記 |
| `docs/specs/148-*/test-fixtures/*.md` | 新規 8 fixture | detect_partial_status の 8 種類入力検証（complete / partial_blocked / partial_overrun / absent / invalid / multiple / list-marker / tasks-pending-sample） |
| `docs/specs/148-*/test-detect.sh` | 新規スモークスクリプト | detect_partial_status 動作確認（8 fixture, 8 case） |
| `docs/specs/148-*/test-build-comment.sh` | 新規スモークスクリプト | build_partial_escalation_comment 動作確認（15 assertion） |
| `docs/specs/148-*/test-handle-partial.sh` | 新規スモークスクリプト | handle_partial_status 統合動作確認（gh CLI を PATH override で stub 化 / 16 assertion） |
| `docs/specs/148-*/impl-notes.md` | 本ファイル | 実装ノート |
| `docs/specs/148-*/tasks.md` | 進捗マーカー更新 | Task 1〜8 を `[x]` に更新（task 9 は deferrable のため `[ ]*` のまま） |

## 動作確認結果

### 静的解析

| チェック | 結果 |
|---|---|
| `shellcheck -S warning local-watcher/bin/issue-watcher.sh` | 警告 0 件（pass） |
| `bash -n local-watcher/bin/issue-watcher.sh` | 構文 OK |
| `actionlint .github/workflows/*.yml` | 本 Issue では Actions workflow を変更していないため対象外（NFR 1.1 を Actions 経路でも構造的に保証） |

### スモークテスト

| スクリプト | アサート件数 | 結果 |
|---|---|---|
| `docs/specs/148-*/test-detect.sh` | 8 | 全 pass |
| `docs/specs/148-*/test-build-comment.sh` | 15 | 全 pass |
| `docs/specs/148-*/test-handle-partial.sh` | 16 | 全 pass |

合計 **39 件のアサーションすべて pass**。

### 後方互換性の確認（NFR 1.1 / 1.4）

- `test-handle-partial.sh` Case 1（status 行不在）/ Case 2（`STATUS: complete`）でいずれも
  `return 0`（continue）かつ gh API 呼出ゼロを確認 → 既存挙動と外形完全等価
- `STAGE_CHECKPOINT_ENABLED=false` 経路で START_STAGE=B|C のときは Stage A 自体を skip
  するため、handle_partial_status は呼ばれない（既存 design.md「gate 起動条件」に従う）

## 受入基準の達成確認（テスト紐付け）

| Requirement ID | 担保方法 |
|---|---|
| 1.1 (`partial_blocked` 定義) | developer.md「# 出力契約」節 + detect_partial_status fixture 2（status-partial-blocked.md → return 0 / stdout=partial_blocked / test-detect.sh case 2） |
| 1.2 (`partial_overrun` 定義) | developer.md「# 出力契約」節 + detect_partial_status fixture 3（test-detect.sh case 3） |
| 1.3 (`complete` 互換) | developer.md「既存『complete』との後方互換」段落 + detect_partial_status fixture 1, 4（status 行不在 = complete fallback / test-detect.sh case 1, 4 / test-handle-partial.sh case 1, 2） |
| 1.4 (partial_blocked の halt 理由 + 残タスク出力) | developer.md「partial 報告時の追加出力」節（`## Partial Halt Reason` / `## Pending Tasks` 必須化） |
| 1.5 (partial_overrun の commit 範囲 + 残タスク出力) | 同上 + build_partial_escalation_comment が git log --oneline で commit 一覧を出力 |
| 2.1 (turn budget 残 10 未満で partial_overrun) | developer.md「自己判断による partial の報告条件」節（turn budget 残量 10 未満 + 直前安全 commit boundary 停止） |
| 2.2 (外部依存進行不能で partial_blocked) | 同上（未 merge Issue / 設計矛盾 / 環境不備の 3 ケース明示） |
| 2.3 (partial は failure ではない) | developer.md「partial は failure ではない（重要）」段落 |
| 2.4 (partial_overrun 時は安全 commit 可能範囲で停止) | 同上の自己判断条件節（「安全な commit boundary」定義） |
| 3.1 (`partial_blocked` 検出で Reviewer skip) | handle_partial_status return 10 → run_impl_pipeline 各 gate 呼出箇所で `return 0` → Reviewer 起動分岐に到達しない（test-handle-partial.sh case 3 / reviewer.md informational 追記） |
| 3.2 (`partial_overrun` 検出で Reviewer skip) | 同上（test-handle-partial.sh case 4） |
| 3.3 (`partial_blocked` で needs-decisions 付与) | mark_issue_needs_decisions の gh issue edit `--add-label needs-decisions`（test-handle-partial.sh case 3 で gh.log 検証） |
| 3.4 (`partial_overrun` で needs-decisions 付与) | 同上（test-handle-partial.sh case 4） |
| 3.5 (partial 検出時に local commit を破棄せず remote push) | gate 挿入位置は verify_pushed_or_retry の **後** に固定。partial 検出時点で既に push 済の commit はそのまま remote に残る。handle_partial_status は branch / commit を一切触らない |
| 3.6 (partial 検出時にエスカレーションコメント 1 件投稿) | mark_issue_needs_decisions の gh issue comment 1 回呼出（test-handle-partial.sh case 3, 4） |
| 4.1 (コメントに halt 理由) | build_partial_escalation_comment の `## Halt 理由` セクション抽出（test-build-comment.sh case 1 で fixture から「依存 Issue #999 が未 merge」を検証） |
| 4.2 (コメントに commit 一覧 + branch 名) | build_partial_escalation_comment の `## Push 済み commit 一覧` セクション（git log --oneline）+ `### 検知情報` の branch 行（test-build-comment.sh case 1） |
| 4.3 (コメントに残タスク一覧) | build_partial_escalation_comment の `## 残タスク一覧`（impl-notes.md `## Pending Tasks` 優先、なければ tasks.md fallback / test-build-comment.sh case 3） |
| 4.4 (コメントに推奨アクション選択肢) | build_partial_escalation_comment の `## 推奨アクション` 固定リスト 3 種（test-build-comment.sh case 1 で「依存 Issue を先に進める」「Issue を分割する」「手動で続行する」をすべて検証） |
| 4.5 (コメントに status code 識別固定文字列) | build_partial_escalation_comment の本文先頭 `<!-- idd-claude:partial-status:STATUS -->` HTML コメント（test-build-comment.sh case 1, 2 で先頭行検証） |
| 5.1 (needs-decisions 付与中は Developer 自動起動なし) | 既存 dispatcher の除外フィルタを再利用（新規変更なし）。reviewer.md / developer.md にも本機能由来の追加挙動なし |
| 5.2 (needs-decisions 付与中は Reviewer 自動起動なし) | 同上（Reviewer は Slot Runner 内で起動 = needs-decisions 付き Issue は Slot に入らない既存挙動を再利用） |
| 5.3 (needs-decisions 除去後は通常 pickup) | 同上の inverse（既存挙動再利用） |
| NFR 1.1 (`complete` の出力フォーマット破壊なし) | detect_partial_status の status 行不在 = return 1 → handle_partial_status return 0 → gate 構造で既存挙動完全保持（test-handle-partial.sh case 1, 2） |
| NFR 1.2 (既存 env var 名の意味改変なし) | 新規 env var ゼロ（README で明示）。`REPO` / `REPO_DIR` / `BASE_BRANCH` / `DEV_MODEL` 等の参照は read のみで意味不変 |
| NFR 1.3 (既存ラベル遷移契約の意味改変なし) | `LABEL_NEEDS_DECISIONS` 既存変数のみ使用。`LABEL_FAILED` (claude-failed) は付与しない（mark_issue_needs_decisions の規約 / test-handle-partial.sh case 3, 4 で claude-failed 未付与を間接 verify） |
| NFR 1.4 (`complete` 従来通り = 既存挙動と同一) | 既存 stage-a-verify gate / Stage B 起動経路は本機能で変更されない。partial gate が status 行不在 / complete で `return 0` を返すと既存挙動に到達 |
| NFR 2.1 (partial 検出を grep 可能なログ行で記録) | handle_partial_status の `[timestamp] [$REPO] partial-status: detected issue=#... status=... branch=...` ログ（test-handle-partial.sh case 6 で `partial-status: detected issue=#148 status=partial_blocked branch=` を検証） |
| NFR 2.2 (コメントに本機能由来識別固定文字列) | build_partial_escalation_comment 本文先頭の `<!-- idd-claude:partial-status:STATUS -->` HTML コメント（Req 4.5 と同一実装 / test-build-comment.sh） |
| NFR 3.1 (不正 status code は `claude-failed` + Reviewer skip) | handle_partial_status の `*` 分岐 → mark_issue_failed 実行 + return 1（test-handle-partial.sh case 5 で `--add-label claude-failed` 検証） |
| NFR 3.2 (parse 失敗は既存失敗時挙動と互換) | detect_partial_status のファイル不在 (rc=2) / 行不在 (rc=1) は handle_partial_status で continue（既存挙動と差分なし / test-detect.sh case 4, 5） |

## 実装上の判断

### gate 挿入位置の最終確認（design.md 案 A 採用）

設計書では「Stage A 完了 echo 直後に handle_partial_status を 1 行で挿入」を案 A として
採用しており、5 箇所すべてに同じパターンで挿入した。挿入位置は **stage-a-verify gate の
前**（partial 宣言時は verify を skip する semantics）。

5 箇所の挿入は **完全に同じ関数で機能集約** されており、コード重複なし。各箇所のローカル
変数名（`_partial_rc` / `_partial_rc_n` / `_partial_rc_bl` / `_partial_rc_aredo` /
`_partial_rc_app`）は同一スコープ内 local 再宣言警告を防ぐため分離した。

### return code 10 の選定

`handle_partial_status` の戻り値として 10 を採用した。既存の return code 0/1 と衝突しない
こと、quota 99 とも区別できることを根拠とする（design.md「Partial Status Coordinator」節
の invariants に従う）。

### shellcheck SC2317 info 警告

`shellcheck` の info-level 警告 SC2317（「unreachable / 関数が間接呼出のため到達不能と
誤検出」）が新規追加した 4 関数すべてに出るが、これは既存 `detect_blocked_marker` /
`mark_issue_failed` / `qa_handle_quota_exceeded` 等すべての helper に対しても同様に出る
**pre-existing な info-only warning** である。`-S warning` レベル（warning 以上のみ
報告）では 0 件で clean。

### Stage Checkpoint Resume との協調

`STAGE_CHECKPOINT_ENABLED=true`（既定）で START_STAGE が B / C にスキップされる場合、
Stage A 自体が skip されるため handle_partial_status は呼ばれない。これは既存挙動と
整合する仕様で、resume 経路で partial を検出する仕組みは本 Issue の Out of Scope
（design.md「複数 round 跨ぎの partial 蓄積と resume の整合」Open Question 2）。

### Actions 経路の扱い

`.github/workflows/issue-to-pr.yml` および `repo-template/.github/workflows/issue-to-pr.yml`
は **意図的に変更しない**。Actions 経路は prompt 1 発で全 stage を完了させる単純構造で
status code を parse する orchestrator が存在しないため、`IDD_CLAUDE_USE_ACTIONS=true`
opt-in 経路では本機能は **未実装** となる（README で明示）。これは NFR 1.1 を Actions
経路でも構造的に保証することと整合する。

## 確認事項（PR 本文で reviewer に提示する内容）

以下は本実装で発生した解釈論点と Open Question の備忘。Reviewer は本機能の判定基準には
含めない（Open Question は人間判断に委ねる範囲）。

1. **`needs-decisions` ラベルの意味多重化**（requirements.md Open Question 1）: 既存運用で
   `needs-decisions` は PM フェーズ情報不足 / Architect budget overflow (#131) /
   tasks.md 件数 overflow (#147) / 本機能由来 partial の 4 系統で付与される。本 Issue は
   識別 HTML コメントで由来区別する方針を採用したが、専用補助ラベル（例:
   `harness-partial-blocked`）併用の是非は人間判断論点として残置。

2. **複数 round 跨ぎの partial 蓄積と resume 整合**（requirements.md Open Question 2 /
   design.md Open Question）: 「partial 解消後の自動 resume」は Out of Scope。人間が
   手動で次サイクル起動する際の引き継ぎ手順（残タスク読み取り元・impl-notes.md 追記
   規約）は本機能着手後の運用知見蓄積後に別途仕様化したい。

3. **turn budget 閾値 10 turn の妥当性**（requirements.md Open Question 3）: 暫定値。
   Developer の `MAX_TURNS` 既定値や commit 1 件あたりの turn 消費量に対する余裕度の
   根拠が固まっていない。Issue #131 の budget overflow 事前検知運用知見と突き合わせて
   再評価する基準を設けるべきかを人間判断したい。

## 派生タスク候補（Out of Scope）

本実装ではカバーしないが、運用知見の蓄積後に切り出すべき派生 Issue 候補:

- **Actions 経路への partial status code 移植**（status code parse / 分岐ロジックを
  Actions ワークフロー版にも追加する）
- **partial 解消後の自動 resume 機構**（人間が依存解消後にラベルを外す現状運用を維持する
  代わりに、`needs-decisions` 解消時に自動 pickup される resume protocol 拡張）
- **専用補助ラベル `harness-partial-blocked` / `harness-partial-overrun` の新設検討**
  （複数経路の `needs-decisions` 由来を機械フィルタしやすくする補助手段）
- **per-task loop 内での partial 検出**（現状は loop 全体完了後の 1 回のみ。各 task
  完了直後で partial を出せるようにする拡張）

## skip した task の記載

- **Task 9 (`- [ ]* 9. dogfooding E2E スモークテスト`)**: deferrable マーカー `- [ ]*`
  付きの task のため、本 Issue では **実施せず** skip した。E2E 確認は本 PR 経由で
  watcher 実環境に本機能が反映された後、人間運用者が test Issue を立てて Developer に
  意図的に `STATUS: partial_blocked` を出力させる形で別途実施する想定。

## 関連ドキュメントへのリンク

- [requirements.md](./requirements.md)
- [design.md](./design.md)
- [tasks.md](./tasks.md)
- 新規 helper 4 関数: `local-watcher/bin/issue-watcher.sh`
  （`detect_partial_status` / `build_partial_escalation_comment` /
  `mark_issue_needs_decisions` / `handle_partial_status`）
- Developer prompt 規約: `.claude/agents/developer.md` / `repo-template/.claude/agents/developer.md`
  の「出力契約（impl-notes.md 末尾の STATUS 行）」節
- Reviewer 横断参照: `.claude/agents/reviewer.md` / `repo-template/.claude/agents/reviewer.md`
  の「partial status との関係（informational）」段落
- README 該当節: `README.md` 「## Developer Partial Status Codes (#148)」

STATUS: complete
