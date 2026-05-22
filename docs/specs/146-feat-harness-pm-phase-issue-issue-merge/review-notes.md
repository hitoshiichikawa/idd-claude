# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-146-impl-feat-harness-pm-phase-issue-issue-merge
- HEAD commit: bf20d9ddddf8cb6b4958eb6b6c978b1f14d9903f
- Compared to: main..HEAD
- 実装 commit: f7b4f91, 03b578a, f748c3e, d2889fb, 30fdc9c, f234b93, 607588e（+ 進捗マーカー 7 件）
- Feature Flag Protocol 採否: CLAUDE.md に `## Feature Flag Protocol` 節が存在しない → fallback opt-out → 通常 3 カテゴリ判定のみ適用（flag 観点の細目チェックは行わない）

## Verified Requirements

### Requirement 1: 依存 Issue 番号の抽出

- 1.1 — `dr_extract_deps`（`local-watcher/bin/issue-watcher.sh` line 10424-10445）の `grep -E '(Depends on:|前提依存:|Blocked by:)'` が canonical を検出。reviewer 独立再現テストで `Depends on: #12 #34` → `12\n34` を確認
- 1.2 — 同関数の `前提依存:` 行検出。独立再現テストで `前提依存: #100` → `100` を確認
- 1.3 — 同関数の `Blocked by:` 行検出。独立再現テストで `Blocked by: #200` → `200` を確認
- 1.4 — `grep -oE '#[0-9]+'`（line 10442）で行内番号を全列挙。独立再現テストでスペース区切り（Test 1）/ カンマ区切り（`Depends on: #1, #2, #3` → `1\n2\n3`）の双方を確認
- 1.5 — `sort -u -n`（line 10444）による uniq + 数値昇順。独立再現テストで `Depends on: #1\nBlocked by: #1 #2` → `1\n2`（重複排除済）
- 1.6 — `dr_check_dependencies` line 10620-10623 で空集合判定 → `verdict=skip_no_deps` ログ + return 0
- 1.7 — canonical `Depends on:` + alias `前提依存:` / `Blocked by:` の 3 種が `.claude/rules/issue-dependency.md` のキャノニカル + alias 表（`Depends on:` / `前提依存:` / `Blocked by:`）と完全一致

### Requirement 2: 依存 Issue の merge 状態判定

- 2.1 — `dr_resolve_one` line 10501-10502 が `gh issue view "$dep_num" --repo "$REPO" --json state,closedByPullRequestsReferences` を実行
- 2.2 — line 10525 の `jq '[.closedByPullRequestsReferences[]? | select(.merged == true)] | length'` で boolean true 比較を行い、結果 >0 → `resolved`（line 10531-10532）。design 指定どおりの boolean true 比較
- 2.3 — line 10516-10519: `state == OPEN` → `echo "open"`
- 2.4 — line 10531-10535: CLOSED かつ merged_count == 0 → `echo "closed unmerged"`
- 2.5 — line 10501-10506 / 10509-10513 / 10538-10543: gh 失敗 / jq parse 失敗 / 未知 state を `api error` にマップ。`dr_warn` でログ
- 2.6 — `dr_check_dependencies` line 10664-10670 の `if [ -n "$unresolved_lines" ]` で 1 件以上 unresolved/api_error 検出時に `dr_apply_block` + return 1 を確認

### Requirement 3: ブロック検出時のラベル付与とエスカレーション

- 3.1 — `dr_apply_block` line 10570-10572 `gh issue edit ... --add-label "$LABEL_BLOCKED"`
- 3.2 — line 10576 `gh issue comment ... --body "$body"` でコメント 1 件投稿。重複投稿は呼び出し元冪等性ガードで防止
- 3.3 — line 10570-10572 の単一 `gh issue edit --remove-label "$LABEL_CLAIMED" --add-label "$LABEL_BLOCKED"` で原子的に付け替え
- 3.4 — line 10612 `if printf '%s\n' "$labels" | grep -qx "$LABEL_BLOCKED"; then` で既付与時は再付与 skip + return 1
- 3.5 — `_slot_run_issue` line 10840-10843 で `if ! dr_check_dependencies ...; then slot_log ...; return 0; fi` により Triage 起動を skip
- 3.6 — `dr_format_unresolved_comment` line 10459-10460 が `- #N (区分)` 形式で列挙（open / closed unmerged / api error の 3 区分）

### Requirement 4: Dispatcher による blocked Issue の pickup 除外

- 4.1 — `_dispatcher_run` line 11243 の `gh issue list --search` 末尾に `-label:\"$LABEL_BLOCKED\"` を追加
- 4.2 — 除外クエリのみが pickup 判定の正本（追加 retrofit ロジックなし）→ `blocked` 手動除去で次サイクルに自動再合流
- 4.3 — 既存除外ラベル 9 件（needs-decisions / awaiting-design-review / claude-claimed / claude-picked-up / ready-for-review / claude-failed / needs-iteration / needs-quota-wait / staged-for-release）の順序・値はそのままで `BLOCKED` を末尾に append

### Requirement 5: 検出パターン非存在時の後方互換

- 5.1 — `dr_extract_deps` が空 stdout → `dr_check_dependencies` line 10620-10623 で `verdict=skip_no_deps` ログ後 return 0
- 5.2 — skip 経路では `dr_apply_block` を呼ばず副作用ゼロ（reviewer 独立再現で empty stdout を確認）
- 5.3 — `dr_extract_deps` は gh API 呼び出しゼロ・ローカル regex のみで完了

### Requirement 6: 実行ログ記録

- 6.1 — `dr_check_dependencies` 内で `dr_log "issue=#${issue_num} extracted=... resolved=... unresolved=... api_errors=... verdict=..."` を全ケースで 1 行出力（line 10613, 10622, 10666, 10674）。design.md「Log Schema」一致
- 6.2 — `dr_resolve_one` line 10503, 10510, 10527, 10540 で gh 失敗 / jq parse 失敗 / 未知 state 時に `dr_warn` 出力
- 6.3 — `dr_log` / `dr_warn` / `dr_error`（line 10397-10405）は既存 `mq_log` / `pi_log` 系と同書式（stdout / stderr 経路）で `LOG_DIR` 配下に乗る

### Requirement 7: `blocked` ラベル定義の配布

- 7.1 — `.github/scripts/idd-claude-labels.sh` line 78 に `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能"` を追加
- 7.2 — description に「依存 Issue 未 merge により auto-dev 進行不能」を含む
- 7.3 — self-hosting 用に `【Issue 用】` prefix を採用（既存規約整合）
- 7.4 / 7.5 — 既存 `gh label create ... 2>/dev/null || gh label edit ...` ロジックがそのまま発火（NFR 3.2）。本タスクではロジック非変更
- 7.6 — `repo-template/.github/scripts/idd-claude-labels.sh` line 75 にも同じ `"blocked|b60205|【Issue 用】 依存 Issue 未 merge により auto-dev 進行不能"` を追加（self-hosting / consumer で完全一致）

### Requirement 8: README.md ドキュメント整備

- 8.1 — README.md 行 461 「作成されるラベル」表に `blocked` 行追加（濃赤 b60205）
- 8.2 — 行 899 「ラベル状態遷移まとめ」表に `blocked` 行追加 + 行 913 ポーリングクエリに `-label:blocked` 追加
- 8.3 — 行 932 周辺で canonical / alias 3 種への参照と `.claude/rules/issue-dependency.md` リンクを記載
- 8.4 — 解消手順「依存先を merge → blocked 手動除去 → 次 cron tick で再評価」を明文化（行 935-936）
- 8.5 — `blocked` と `needs-decisions` の意味的差分（行 938-940）を明示
- 8.6 — QUICK-HOWTO.md 行 74 「作成されるラベル」インライン列挙に `blocked` を追記

### Requirement 9: `needs-decisions` との意味的分離

- 9.1 — `dr_apply_block` line 10570-10572 では `--add-label "$LABEL_BLOCKED"` のみで `needs-decisions` には触れない
- 9.2 — `dr_format_unresolved_comment` line 10462-10480 のテンプレが「判断を委ねる」「決定事項」等の needs-decisions 用語彙を含まず、依存未解決専用文面（`🛑 依存 Issue 未 merge のため自動処理を中止しました。`）
- 9.3 — `_dispatcher_run --search` line 11243 で `-label:"$LABEL_NEEDS_DECISIONS"` と `-label:"$LABEL_BLOCKED"` が並列指定され、状態遷移は独立
- 9.4 — README 行 938-940 で両ラベルを別ラベルとして列挙 + 将来統合しない方針を明示

### Non-Functional Requirements

- NFR 1.1 — 依存記法非搭載 Issue では `dr_log` 1 行のみ。gh API・ラベル変更・コメント投稿ゼロ（独立再現 Test 5 で空 stdout 確認）
- NFR 1.2 — 既存ラベル定義の name / color / description / 順序は不変（diff で +1 行のみ確認）
- NFR 1.3 — dispatcher 既存除外条件 9 件の順序・値不変 + `BLOCKED` 末尾追加
- NFR 1.4 — markdown コードフェンス内・引用ブロック内の誤検出は運用許容として明文化（design.md / line 10421-10423 コード comment）
- NFR 2.1 — 構造化ログ `dr: issue=#N extracted=... verdict=...` で grep 集計可能
- NFR 2.2 — 既存 stdout/tee 経路に乗る（dr_log line 10398 が既存 `mq_log` 系と同形式）
- NFR 3.1 — `dr_check_dependencies` line 10612 の冪等性ガードで N 回再実行に対し付与数 1 / コメント数 1 に収束
- NFR 3.2 — labels.sh の冪等性は既存ロジックがそのまま保持
- NFR 4.1 — 通常 1〜3 件の依存で `gh issue view` 数回 = 数秒、cron tick 内に収まる
- NFR 4.2 — rate limit / API 失敗 → `api error` → unresolved 集合に積む → `blocked` 確定（line 10651-10653, 10664-10670 で安全側集計）

### Out of Scope 遵守確認

- impl-resume 経路（`HAS_EXISTING_SPEC=true`）では `dr_check_dependencies` 未呼び出し（`_slot_run_issue` line 10824-10831 の if/elif 構造で `else` ブランチ line 10832-10843 にのみ Dependency Resolver Gate を配置）→ 既存 in-flight Issue への retrofit 回避
- skip-triage ラベル経路（line 10827 の elif）でも未呼び出し → 既存挙動完全維持
- auto-unblock（依存解消後の自動 blocked 除去）は実装に含まれず（README にも提供しない旨明示）
- 循環依存検出は実装されず（未解決 1 件以上で block 確定する設計）
- 逆方向 `Blocks:` 記法は検出対象に含まれず（line 10433 の grep パターンに含まれない）
- クロスリポジトリ参照（`owner/repo#N`）は対象外（`#[0-9]+` のみ抽出）

### 静的解析・スモーク（reviewer 独立実施）

- `shellcheck local-watcher/bin/issue-watcher.sh` — 新規警告ゼロ。新規追加 `dr_*` 関数群で残るのは line 10404 の SC2317 info（`dr_error` 未直接呼び出し、間接呼び出しの既存パターンと同等）のみで、reject 対象外（CLAUDE.md「スタイル / lint 観点では reject しない」）
- `shellcheck .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` — 警告ゼロ
- `dr_extract_deps` の独立再現スモーク 6 ケース（canonical / Blocked by / 前提依存 / 重複排除 / 検出なし / カンマ区切り）すべて期待出力どおりで通過

### boundary 確認（tasks.md `_Boundary:_` との突合）

- Task 1〜4: `local-watcher/bin/issue-watcher.sh` のみ → 適合
- Task 5 _Boundary:_ idd-claude-labels.sh (self-hosting), idd-claude-labels.sh (consumer) → `.github/scripts/idd-claude-labels.sh` + `repo-template/.github/scripts/idd-claude-labels.sh` のみ変更 → 適合
- Task 6: README.md のみ → 適合
- Task 7: QUICK-HOWTO.md + impl-notes.md + 進捗マーカー（tasks.md） → 適合
- 全体: 変更ファイル 8 個（spec docs 含む）すべてが tasks.md の宣言境界内

## Findings

なし

## Summary

Issue #146 の 7 タスク（impl 7 commit + 進捗マーカー 7 commit）はすべて Developer により完了済みで、
要件定義 9 件 + NFR 4 件のすべての numeric AC が実装またはコード読みでカバーされていることを確認した。
新規追加された `dr_*` 関数群（純粋関数 dr_extract_deps / dr_format_unresolved_comment、gh ラッパ
dr_resolve_one / dr_apply_block、orchestrator dr_check_dependencies）は design.md の Components and
Interfaces 節の契約とインターフェース仕様に整合し、`_slot_run_issue` の Triage 起動直前ゲート配置も
Out of Scope（impl-resume / skip-triage retrofit 回避）の境界を遵守している。dispatcher 除外クエリ
への `-label:"$LABEL_BLOCKED"` 追加は既存 9 ラベルの順序・値を保持したまま末尾追加で NFR 1.3 互換、
labels.sh self-hosting / consumer 両系統への `blocked|b60205|【Issue 用】 ...` 追加は Req 7.6 の
同名同 description 規約に整合、README / QUICK-HOWTO 更新も Req 8 全 AC をカバーしている。
shellcheck は新規 dr_error の SC2317 info 1 件のみで既存パターンと同等の info 扱い（reject 対象外）。
reviewer 側で独立に再現した dr_extract_deps の 6 ケース（canonical / Blocked by / 前提依存 / 重複
排除 / 検出なし / カンマ区切り）はすべて期待出力どおり通過。CLAUDE.md に Feature Flag Protocol 節が
存在しないため fallback opt-out として扱い、3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）
のいずれにも該当する問題は検出されなかった。

RESULT: approve
