# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-147-impl-feat-harness-tasks-md-task-auto-dev-issu
- HEAD commit: 45a33a0cc899af87f7c795ddecd93d382c17cb35
- Compared to: main..HEAD
- 差分実態: `local-watcher/bin/issue-watcher.sh`（+383 行: Config 4 env var + tc_* 9 関数 + design 分岐 rc=0 hook 1 行）、`README.md`（+157 行: オプション機能表エントリ + Migration Note 節）、`tests/local-watcher/tasks-count/`（fixture 6 件 + extract-driver.sh + perf-driver.sh、すべて新規）、`docs/specs/147-*/`（impl-notes.md 追加 + tasks.md の checkbox 更新のみ）
- 補足: `docs/specs/148-*` の削除は merge base（4ee32ab）以後に main 側で追加された設計成果物（5017d21）に由来する差分ノイズで、本ブランチが #148 を破壊しているわけではない（HEAD ツリーは 147 ディレクトリのみを変更）

## Verified Requirements

- 1.1 — `tc_run_post_architect_check` を design 分岐 rc=0 case の hook（issue-watcher.sh L10471）から呼び、内部で `tc_count_tasks` をディスパッチ
- 1.2 — count regex `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` が 4 種 checkbox（`- [ ]` / `- [x]` / `- [ ]*` / `- [x]*`）+ numeric 階層 ID を網羅。`tasks-mixed-checkbox.md` fixture が 4 種混在で count=8 になることを extract-driver.sh が検証
- 1.3 — 同 regex が小数階層 ID 行（`1.1` / `2.1` 等）も最上位タスクと同列に 1 件として数える。mixed fixture は `1.` / `1.1` / `1.2` / `2.` / `2.1` / `3.` / `4.` / `5.` の 8 件
- 1.4 — `(P)` マーカー文字列は regex の評価対象外（マッチ後の任意末尾）。mixed fixture が `(P)` 含み行を 1 件として数えるのを確認
- 1.5 — `tc_should_run` が `[ ! -f "$tasks_path" ]` で skip + `reason=tasks-md-missing` をログ。`tc_count_tasks` も不在で return 1。driver が `tc_count_tasks(missing file) → return 1` を assert
- 1.6 — `tc_run_post_architect_check` の `tc_log "issue=#... count=$count range=$range action=..."` 出力、および `tc_log`/`tc_warn`/`tc_error` の `[YYYY-MM-DD HH:MM:SS] [$REPO] tasks-count:` 3 段 prefix
- 2.1 — count<TC_WARN_LOWER で `tc_classify` が `normal` を返し、orchestrator は `tc_log "... range=normal action=none"` のみ。driver で classify(0/7)=normal を検証
- 2.2 — TC_WARN_LOWER≤count≤TC_WARN_UPPER で `warn` を返し `tc_post_warning_comment` を 1 件呼ぶ。driver で classify(8/9/10)=warn と fixture tasks-8/10.md を検証
- 2.3 — count≥TC_ESCALATE_LOWER で `escalate` を返し `tc_post_escalation_comment` + `tc_add_needs_decisions_label` を呼ぶ。driver で classify(11/50)=escalate と fixture tasks-11.md を検証
- 2.4 — 既存 `_dispatcher_run` の watcher Issue 候補抽出 query（issue-watcher.sh L10581）が `-label:"$LABEL_NEEDS_DECISIONS"` を含むため、ラベル付与で構造的に Developer 自動起動を抑止
- 2.5 — `tc_post_escalation_comment` の body に検知件数・適用閾値・抑止された後続フェーズ名（Developer 自動起動 / impl-resume）・3 種の回復手順（Issue 分割 / `needs-decisions` 手動 off / `TC_ENABLED=false`）を全て明記
- 2.6 — `tc_should_run` の label 既存検知 + `tc_already_posted_marker_present` の 2 段冪等ガード。固定マーカー `<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> issue=<N> ... -->` を kind 別に grep
- 3.1 — hook が design 分岐 rc=0 case にのみ配置され、impl / impl-resume 経路（L10491–10501 の `run_impl_pipeline`）には差し込まれていない（構造的保証）
- 3.2 — 同上、Stage Checkpoint Resume（impl 系 START_STAGE=B|C）も design 分岐に到達しないため hook 不到達
- 3.3 — `tc_should_run` の 3 形式 skip log（`reason=opt-out` / `reason=tasks-md-missing` / `reason=already-needs-decisions`）
- 4.1 — `range=normal` 分岐は `tc_log` のみで副作用なし。本機能導入前と user-observable に同一の design 分岐挙動
- 4.2 — `TC_ENABLED="${TC_ENABLED:-true}"` の env var で `=false` 明示 opt-out 可能。`tc_should_run` 冒頭で skip。README の cron 例にも opt-out 形式を明記
- 4.3 — README.md L3206 以降に `## Tasks Count Gate (#147)` 節を追加し Migration Note を記載。「オプション機能（標準有効）」表（L1091）にも 1 行追加
- 4.4 — `tc_should_run` が `needs-decisions` ラベルの起源（#131 由来 / 本機能由来 / PM 由来）を区別せず存在のみで skip 判定
- NFR 1.1 — `tc_log` 出力行頭の `[YYYY-MM-DD HH:MM:SS] [$REPO] tasks-count:` で `grep '\[.*\] tasks-count:'` で全件抽出可能
- NFR 1.2 — 警告 / エスカレーション両コメント本文末尾に固定マーカー `<!-- idd-claude:tasks-count-overflow kind=<kind> issue=<N> count=<C> -->` を必ず付与
- NFR 2.1 — 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `BASE_BRANCH` 等）は不変。新規追加は `TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` のみ
- NFR 2.2 — 既存 `LABEL_NEEDS_DECISIONS`（`needs-decisions`）を流用し、新ラベル名は追加しない。`auto-dev` → `claude-claimed` 等の遷移契約も改変なし
- NFR 3.1 — perf-driver.sh で 1.3 MB / 20000 task lines を 2ms（≪ 1 秒）で完走することを実測

## 補足検証

- extract-driver.sh: 16/16 cases pass（fixture 6 件 + classify 境界 7 値 + env var fallback 1 + count 非整数 fallback 1 + missing file return 1）
- perf-driver.sh: pass（NFR 3.1 余裕）
- shellcheck -S warning: warning / error ゼロ（issue-watcher.sh / extract-driver.sh / perf-driver.sh）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため opt-out 扱い（通常 3 カテゴリのみで判定。flag-off path 差分等価チェックは適用しない）
- Boundary 違反: なし（tasks.md の `_Boundary:_` で許可された関数群と `_slot_run_issue (design branch)` 内 1 行のみ）

## Findings

なし

## Summary

要件 1〜4 / NFR 1〜3 の全 numeric ID に対し、実装またはテストの裏付けを確認した。fixture 駆動 16 ケース + perf 計測がすべて green、shellcheck も warning ゼロ。hook 配置が design 分岐 rc=0 case に限定されていることで Req 3.1 / 3.2 の resume 経路 skip を構造的に保証しており、fail-open + opt-out 設計で NFR 2.1 の後方互換性も担保されている。boundary 逸脱・AC 未カバー・missing test のいずれも検出されない。

RESULT: approve
