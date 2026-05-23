# 実装ノート: Issue #164 per-task Reviewer の diff range 解決を連記 marker 許容に拡張

## 採用方針

Option C（Developer prompt 厳格化 + watcher 側 marker 解決の許容拡大 + 明示的エラー文言 +
復旧手順）を実装した。要件 1（prompt 厳格化）と要件 2（連記 marker 許容）を **両方** 適用
することで、Developer に「1 commit = 1 task ID」を明示的に伝えつつ、それでも誤って連記
marker を作った場合の **fallback 解決** を watcher 側で行い、`diff-range-resolve-failed` で
データ損失リスクが発生する経路を最小化する。

万が一 fallback でも解決できなかった場合は、専用ヘルパ `pt_mark_diff_range_resolve_failed`
が `git reflog` 復旧手順と 1 commit = 1 task ID の規約を Issue コメントに明示し、運用者が
5 分以内に復旧判断できる粒度で情報提供する（NFR 3.1）。

## 変更箇所

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | `pt_resolve_diff_range` の単記マッチを優先採用 + 連記 marker fallback 追加 |
| `local-watcher/bin/issue-watcher.sh` | `build_per_task_implementer_prompt` に「1 commit = 1 task ID」厳格化を明示 |
| `local-watcher/bin/issue-watcher.sh` | `pt_mark_diff_range_resolve_failed` 新規追加（復旧手順付き Issue コメント + claude-failed 付与） |
| `local-watcher/bin/issue-watcher.sh` | `run_per_task_reviewer` の diff-range-resolve-failed 経路を rc=3 に分離 |
| `local-watcher/bin/issue-watcher.sh` | `run_per_task_loop` の各 reviewer 呼び出しで rc=3 を新ヘルパに dispatch |
| `repo-template/.claude/agents/developer.md` | per-task ループ節に「1 commit = 1 task ID」厳格化を追記（installed consumer 用） |
| `docs/specs/164-.../test-pt-resolve.sh` | `pt_resolve_diff_range` 単記 / 連記 / 誤マッチ抑止の fixture テスト |

`run_per_task_reviewer` の return code は以下のように再整理した:

| rc | 意味 | 呼び出し側の処理 |
|---|---|---|
| 0 | approve | 次 task へ |
| 1 | reject | Implementer 再起動（既存挙動） |
| 2 | claude crash / parse 失敗 | `mark_issue_failed "per-task-reviewer-error"` |
| **3** | **diff-range-resolve-failed (新規 / Issue #164)** | **`pt_mark_diff_range_resolve_failed`（復旧手順付き専用ハンドラ）** |
| 99 | quota 超過 | `needs-quota-wait` |

## 要件 → テスト対応表

| Req ID | 要件概要 | 検証方法 |
|---|---|---|
| Req 1.1 | per-task Implementer prompt に「1 commit = 1 task ID」明示 | `build_per_task_implementer_prompt` 内で **【重要 / Issue #164】1 つの marker commit には 1 つの task ID のみを含めること** セクションを追加し、`local-watcher/bin/issue-watcher.sh` の prompt 組立 heredoc で出力されることを目視確認 |
| Req 1.2 | 親 task 昇格も子と同じ 1 ID 単位で別 commit | 上記 prompt セクション中の例示「子 `1.1` 完了で親 `1` も全完了になる場合、まず `docs(tasks): mark 1.1 as done` を 1 commit で作成し、続けて `docs(tasks): mark 1 as done` を **別 commit** として続けて作成する」で明示 |
| Req 1.3 | 既存 prompt 内の連記例示があれば 1 ID 単位に修正 | 既存 prompt には連記例示は存在せず、修正対象なし。新規追加の NG 例示が「連記禁止」明示の役割を果たす |
| Req 1.4 | `PER_TASK_LOOP_ENABLED=true` の起動経路にのみ適用 | `build_per_task_implementer_prompt` は `run_per_task_loop`（`PER_TASK_LOOP_ENABLED=true` gate 内のみ呼ばれる）の中の `run_per_task_implementer` から呼ばれる。他経路から呼ばれない（grep 確認済） |
| Req 2.1 | 単記 marker の解決 | smoke test case1 全件 (4 件) |
| Req 2.2 | 連記 marker（`/` / `,` 区切り）からの解決 | smoke test case2（slash 3 件）+ case3（comma 2 件） |
| Req 2.3 | 連記 marker 内の各 task ID が同一 SHA を返す | smoke test case2（task=1 / 1.1 / 1.2 が同一 `C2_MULTI` を返す）+ case3（task=1 / 1.1 が同一 `C3_MULTI` を返す） |
| Req 2.4 | 単記＋連記の両方に出現する場合の一意選択 | smoke test case6（task=1 が単記 marker を返す = single-id-prefer 規則） |
| Req 2.5 | task_id `1` が `1.1` / `11` に誤マッチしない | smoke test case2（`task=11` で rc=1）+ case2（`task=2` で rc=1）+ case3（`task=1.2` で rc=1） |
| Req 3.1 | 単記 marker のみのリポジトリで本変更前と同一 SHA 列を返す | smoke test case1 全件（既存挙動踏襲を fixture で確認） |
| Req 3.2 | 単記 marker のみで観測可能な副作用なし | 単記マッチが優先採用されるため `via=multi-id-marker` ログは出ない（smoke test case1 / case4 task=1, 1.1 / case6 task=1 で stderr に該当ログが出ないことを確認） |
| Req 3.3 | `PER_TASK_LOOP_ENABLED != true` の経路に副作用なし | `pt_resolve_diff_range` / `pt_mark_diff_range_resolve_failed` は `run_per_task_loop` 内のみ呼ばれ、同関数は `PER_TASK_LOOP_ENABLED=true` でのみ起動される（grep + dispatcher gate 確認済） |
| Req 4.1 | Issue コメントに失敗カテゴリ + task ID を明示 | `pt_mark_diff_range_resolve_failed` の本文に `カテゴリ: \`diff-range-resolve-failed\`` / `対象 task ID: \`${task_id}\`` を明示 |
| Req 4.2 | `git reflog` 復旧手順を明示 | `pt_mark_diff_range_resolve_failed` の「復旧手順（重要 / データ損失リスク回避）」節に `git reflog --date=iso` / `git push origin <current-branch>` / `git branch <rescue-branch-name> <reflog-sha>` を bash code block で明示 |
| Req 4.3 | marker commit 分割規約（1 commit = 1 task ID）を案内 | `pt_mark_diff_range_resolve_failed` の「推奨される marker commit 分割の規約」節で明示 |
| Req 4.4 | 重複コメント抑制 / 追記であることを明示 | `pt_mark_diff_range_resolve_failed` 冒頭で `gh issue view --json comments` から HTML marker `<!-- idd-claude:per-task-diff-range-resolve-failed:#<N>:<task> -->` を検索し、既存があれば header を「**追記コメント** / 詳細な復旧手順は既存コメントを参照」に切り替える |
| Req 5.1 | 既存 `docs(tasks): mark <id> as done` 規約を温存 / 追加の許容範囲のみ | 単記マッチを優先採用するロジックで既存挙動を完全に温存（smoke test case1 / case4 / case6 で確認） |
| Req 5.2 | 既存 env var / ラベル / cron / exit code 意味を保持 | 既存 env var（`PER_TASK_LOOP_ENABLED` / `BASE_BRANCH` 等）は追加・変更なし。`run_per_task_loop` の return 値は既存通り 0 / 1。`run_per_task_reviewer` の return rc=3 を新規追加（rc=2 を破壊せず追加） |
| Req 5.3 | repo-template/.claude/agents/developer.md 変更は追記または明確化に留める | per-task ループ節「適用範囲」に **追加** の bullet として 1 commit = 1 task ID 規約を追記。既存記述の意味反転なし |
| Req 5.4 | `PER_TASK_LOOP_ENABLED != true` で本変更経路に一切到達しない | dispatcher gate `case "$START_STAGE" in A) if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then run_per_task_loop` で gate されており、他経路から `pt_resolve_diff_range` / `pt_mark_diff_range_resolve_failed` は呼ばれない |
| NFR 1.1 | 単記 marker のみのリポジトリで Reviewer 判定結果を維持 | smoke test case1 で同一 SHA 解決 + 既存 rc=0/1/2 分布を維持 |
| NFR 1.2 | 同一 watcher プロセスを複数回起動した場合の重複コメント抑制 | `pt_mark_diff_range_resolve_failed` の marker dedup ロジック（gh API + jq で marker contains 検索） |
| NFR 2.1 | 連記経由解決時に stdout ログに識別印 | `pt_resolve_diff_range` の末尾で `via=multi-id-marker` ログを stderr に出力（smoke test case2 / case3 / case4 / case6 で `[smoke] diff-range resolved via=multi-id-marker task_id=...` ログを観測） |
| NFR 2.2 | `diff-range-resolve-failed` 時のログに task ID と「単記/連記いずれも見つからなかった」旨を明示 | `run_per_task_reviewer` の `pt_log` に `reason=diff-range-resolve-failed detail=no-marker-commit-found(single-id-and-multi-id-both-missing)` を明示 |
| NFR 3.1 | Issue コメント復旧手順案内で 5 分以内に判断可能な粒度 | `pt_mark_diff_range_resolve_failed` 本文に「失敗カテゴリ」「原因」「復旧手順（git reflog / push / rescue branch / marker commit 補完）」「推奨される marker commit 分割の規約」の 4 節を構造化して提示。bash code block で具体的なコマンドを示し、reflog confirm → push 保護 → marker 補完 → claude-failed 外し、の 4 ステップで完結 |

## 検証結果

### Smoke test (`test-pt-resolve.sh`)

```
=============================================
 PASSED: 19
 FAILED: 0
=============================================
SMOKE_RESULT: pass
```

内訳:
- case1（単記 marker のみ、後方互換）: 4 件すべて pass
- case2（`/` 区切り連記）: 5 件すべて pass（false positive 抑止 task=11 / task=2 含む）
- case3（`,` 区切り連記）: 3 件すべて pass（false positive task=1.2 含む）
- case4（単記＋連記混在、単記優先）: 4 件すべて pass
- case5（marker 全く無し）: 1 件 pass
- case6（単記＋連記で同一 ID 重複時、単記優先）: 2 件 pass

### Shellcheck

```bash
shellcheck -S warning local-watcher/bin/issue-watcher.sh
```

→ warning 以上 0 件。`SC2317`（unreachable）は既存の info-level のみ（本変更による新規発生なし）。

```bash
shellcheck docs/specs/164-.../test-pt-resolve.sh
```

→ 警告ゼロ。

### Bash syntax check

```bash
bash -n local-watcher/bin/issue-watcher.sh
```

→ syntax OK。

## 確認事項

なし（要件は明確、設計は requirements.md と Issue 本文の指示通りに実装した）。

### 補足 — design.md / tasks.md 不在

本 Issue は Triage が `needs_architect: false` 相当で起票したと推測される（requirements.md のみ
配備、design.md / tasks.md なし）。Issue 本文の Option C 採用方針が極めて具体的（線形パッチで
4 箇所明示）であり、PM が指示通りに requirements.md を構造化したため、本実装も requirements.md
+ Issue 本文の Option C 指示に従い線形に対応した。

仮に design.md / tasks.md 必要であれば、Reviewer のレビュー時に確認事項として戻すことを提案
（本 PR では発生しない見込み）。

## 派生タスク候補

なし（本変更で要件は閉じる）。
