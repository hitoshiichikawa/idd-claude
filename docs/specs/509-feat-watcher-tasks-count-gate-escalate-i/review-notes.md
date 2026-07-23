# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-23T09:20:00Z -->

## Reviewed Scope

- Branch: claude/issue-509-impl-feat-watcher-tasks-count-gate-escalate-i
- HEAD commit: b13d98a4aba1819c90e8a14352293e644bb2990a
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/modules/tasks-count-gate.sh`（+573）/ `local-watcher/bin/watcher-config.sh`（+19）/ `local-watcher/test/tasks_count_gate_split_proposal_test.sh`（新規 +458）/ `README.md`（+76/-1）/ spec 配下 2 件
- 備考: 本 Issue は design フェーズを経由しない実装経路のため `design.md` / `tasks.md` は不在。`_Boundary:_` アノテーションが存在しないため、boundary 判定は requirements.md の Out of Scope（既存 tasks-count gate 挙動 / Architect 側 #131 / GitHub Actions 版 / 自動起票）を境界として評価した。
- CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため、flag 観点の細目判定は行わず通常の 3 カテゴリ判定のみを適用。

## Verified Requirements

- 1.1 — `tc_split_proposal_enabled`（`[ "${TC_SPLIT_PROPOSAL_ENABLED:-false}" = "true" ]`）+ `watcher-config.sh` の `TC_SPLIT_PROPOSAL_ENABLED="${TC_SPLIT_PROPOSAL_ENABLED:-false}"` / テスト E2（未設定は無効）
- 1.2 — リテラル `true` 厳密一致でのみ rc=0 / テスト E3, E7
- 1.3 — 無効値 7 種（空 / `false` / `off` / `True` / `TRUE` / `1` / `ture`）を安全側へ正規化 / テスト E1
- 1.4 — gate 無効時は `tc_post_split_proposal_comment` が最初に早期 return（ログ・API なし）/ テスト E4（API 0 回）, E5（ログ 0 行）
- 1.5 — `TC_ENABLED` / `MODEL_ROUTING_ENABLED` と独立の新規変数（config diff / gate 関数は他 gate を参照しない）
- 1.6 — 呼び出し点が `tc_run_post_architect_check` の escalate 分岐内で、先頭の `tc_should_run`（`TC_ENABLED != true` で return 1）を通過しない限り到達しない構造
- 2.1 — escalate 分岐末尾で `tc_post_split_proposal_comment "$NUMBER" "$count" "$tasks_path"` を呼ぶ / テスト E7
- 2.2 — warn / normal 分岐に呼び出しなし / テスト E8, E9
- 2.3 — 既存 `tc_post_escalation_comment` + `tc_add_needs_decisions_label` の**後に追加**（既存 2 行は無改変）/ テスト E6, E7
- 2.4 — `tc_build_split_proposal_body` rc=2 → `split-proposal skip reason=no-top-level-tasks` ログのみ / テスト D1〜D3
- 2.5 — orchestrator が `tc_count_tasks` と同一の `$tasks_path` を引数で渡す（tasks-count-gate.sh:935, 959）/ テスト E7
- 2.6 — hook は design 分岐 rc=0 の orchestrator 内のみ（呼び出し点追加以外に call site なし。既存構造を変更していない）
- 3.1 — `tc_group_tasks` の既定は 1 タスク = 1 グループ / テスト A3
- 3.2 — 抽出 regex が `- [ ]` / `- [ ]*` の最上位のみに一致、`- [x]` 行は対象外 / テスト B1, B5, B6
- 3.3 — 抽出 regex `^- \[ \]\*? [0-9]+\. ` が `tc_count_tasks` の正準 regex と同一 / テスト A2, B2（`tc_count_tasks` 実物との件数一致）
- 3.4 — 推移閉包後の相互到達ノードを併合（強連結成分相当）/ テスト C3, C4
- 3.5 — `_Depends:_` の値から先頭整数部を取り出し最上位 ID へ正規化、子タスク行の注釈は親へ集約 / テスト C1, C2
- 3.6 — `group_of[]` により全ノードが 1 グループへ 1 回だけ割り当て / テスト A19
- 3.7 — 出現順で走査・出力し決定論的 / テスト A4, C7（同一入力で本文完全一致）
- 4.1 — 案ごとに `### 案 N: <タイトル案>` / テスト A5
- 4.2 — `- 含む最上位タスク: \`id\`, ...` / テスト A6, C5
- 4.3 — `- Split from: #<N>` / テスト A7
- 4.4 — `- Parent: #<N>` / テスト A8
- 4.5 — 直接依存辺から `- Depends on: 案 N` を生成 / テスト C6
- 4.6 — header に「案番号であり起票後に実 Issue 番号へ置き換える」旨を明記 / テスト A17
- 4.7 — canonical 記法のみ出力（alias 非出力）/ テスト A10
- 4.8 — `Blocks:` を出力しない / テスト A9
- 4.9 — 「watcher は子 Issue を自動起票しません」を header に明記 / テスト A11
- 4.10 — `gh issue create` 雛形セクション / テスト A12
- 4.11 — 検知件数と適用閾値（`TC_ESCALATE_LOWER`）を header に出力 / テスト A13, A14
- 5.1 — `<!-- idd-claude:tasks-count-split-proposal issue=N count=C proposals=G -->` を末尾に付与 / テスト A15
- 5.2 — `tc_split_proposal_already_posted` 検出時は投稿せず skip / テスト F1
- 5.3 — 既存 `tasks-count-overflow` マーカーとは別文字列（本文にも非出力）/ テスト A16
- 5.4 — 判定は自機能マーカー prefix のみを `grep -qF --` / テスト F3
- 5.5 — 冪等 skip により 1 件のみ存在 / テスト F1
- 5.6 — `gh issue view` 失敗時は return 1（marker 不在扱い）/ テスト F4
- 5.7 — skip 時に `reason=already-posted` / `reason=no-top-level-tasks` ログ / テスト F2, D3
- 6.1 — gate 無効時の escalate は既存 2 アクションのみ / テスト E6
- 6.2 — `TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` の定義行は diff 上無改変
- 6.3 — `tc_classify` / 閾値ロジックは diff 上無改変
- 6.4 — `tc_post_escalation_comment` 本文・マーカーは diff 上無改変 / テスト A16
- 6.5 — 生成失敗は `tc_warn` + rc=0（escalate 本体は呼び出し前に完了済み）/ テスト G5, G6, G7
- 6.6 — 投稿失敗は `tc_warn` + rc=0 / テスト G3, G4
- 6.7 — 読み取りのみ（`tasks.md` への書き込みなし）/ テスト J1（cksum 一致）
- 6.8 — 呼び出しは `|| true`、関数は常に rc=0（design 分岐 rc に非干渉）
- 6.9 — 失敗経路はすべて `tc_warn`（stderr）ないし `tc_log` を残す / テスト D3, F2, G4, G6
- 7.1 — README「オプション機能一覧」opt-in 表に `TC_SPLIT_PROPOSAL_ENABLED`（既定 `false` / `=true` 厳密一致 / 正規化規則）を追加
- 7.2 — README tasks-count gate 節に「子 Issue 分割案コメント（#509 / opt-in）」を追加（含まれる情報 + 人間が取る次アクション 4 項目）
- 7.3 — README のログ形式一覧に成功 / skip 2 種 / WARN 2 種の 5 行を追加
- 7.4 — 二重管理配布物（`.claude/agents` / `.claude/rules` / workflow / labels）に変更なし。`diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules` を実行し差分なしを確認。`local-watcher/` は `repo-template/` にミラーされない系統（install.sh の `modules/*.sh` glob 配布で追従）
- 7.5 — README 更新は同一 PR（commit 0f9b1e6）に含まれる
- 8.1 — `shellcheck local-watcher/bin/modules/tasks-count-gate.sh local-watcher/bin/watcher-config.sh local-watcher/test/tasks_count_gate_split_proposal_test.sh` を再実行し rc=0 / 警告ゼロを確認
- 8.2 — `bash -n`（module / config）を再実行し OK を確認
- 8.3 — `local-watcher/test/tasks_count_gate_split_proposal_test.sh` を既存命名規約で追加、`lib/test-helpers.sh` + `extract_function` イディオムを踏襲
- 8.4 — fixture `tasks.md` 5 種を `mktemp -d` 配下に生成し、案件数・対象タスク ID・依存表現を検証
- 8.5 — Case A（フラット 11 件）/ B（子タスク・完了済み混在）/ C（相互依存）/ D（0 件）/ E（gate 無効）の 5 ケースを網羅
- 8.6 — Case E6 が gate 無効時の escalate 挙動（既存 2 アクションのみ）を検証
- NFR 1.1〜1.3 — gate OFF で API 0 回 / ログ 0 行 / 既存 escalate 挙動同一（テスト E4, E5, E6）。既存 env var 名・ラベル名・ログ出力先の変更なし
- NFR 2.1〜2.4 — `tc_log` の `tasks-count:` prefix を経由し、投稿成功ログに Issue 番号・件数・案件数を含む（テスト G2）。skip / 失敗は 1 行ログ（D3, F2, G4, G6）
- NFR 3.1〜3.6 — Claude 追加起動なし（bash 文字列処理のみ）/ 投稿時 API 呼び出し 2 回（テスト G1）/ gate OFF で 0 回（E4）/ 本文長 60,000 以内（A18 + `max_body` 打ち切り実装）/ タイトル 120 文字（I1〜I4）
- NFR 4.1〜4.4 — `tc_sanitize_text` による HTML コメント記法分断・クォート除去（H1〜H4, H6, H7）/ Issue 番号 `^[0-9]+$` 検証（G8〜G10）/ `grep -qF --` によるパターン注入防止 / 起票コマンドは提示のみ（H5）

## Findings

なし

## Summary

差分は tasks-count-gate module + config + README + 新規近接テストに限定され、requirements.md の
Requirement 1〜8 / NFR 1〜4 のすべてに実装またはテストの対応が確認できた。reviewer 側で
`tasks_count_gate_split_proposal_test.sh`（PASS 76 / FAIL 0）、`shellcheck`（rc=0）、`bash -n`、
`diff -r .claude/{agents,rules}`（差分なし）を再実行し green を確認。gate OFF 時は API 0 回・
ログ 0 行で既存 escalate 挙動が保たれており、Out of Scope（自動起票 / 既存閾値・マーカー変更 /
Actions 版）への侵食も無い。

補足（reject 理由には含めない / 設計 iteration・別 Issue 還流の候補）: (a) Req 1.6（`TC_ENABLED`
opt-out 時の非投稿）は `tc_should_run` の既存ガードによる構造的保証で、専用テストは無い
（Req 8.5 が要求する 5 ケースには含まれておらず現行確定 spec は充足）。(b) NFR 3.4 の本文長
打ち切り分岐は自動テスト未到達で impl-notes の手動計測（300 件 / 59,418 文字）に依拠している。
(c) impl-notes の「確認事項」に挙がる `_Requirements:_` 同梱可否・サニタイズ方式は requirements.md
の Open Questions に属し、AC 追加を要するため本 impl PR の範囲外。

RESULT: approve
