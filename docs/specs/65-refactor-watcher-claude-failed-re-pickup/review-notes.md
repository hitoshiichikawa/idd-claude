# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-30T05:27:59Z -->

## Reviewed Scope

- Branch: claude/issue-65-impl-refactor-watcher-claude-failed-re-pickup
- HEAD commit: 25dff78c3470b3fde799e8a327a6f1063b33a810
- Compared to: main..HEAD

CLAUDE.md に `## Feature Flag Protocol` 節は存在しないため、本レビューは通常の
3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）のみで判定する。

## Verified Requirements

- 1.1 — `_dispatcher_run` per-issue ループの先頭（line 4647 周辺、`issue_number` 抽出直後・空き slot 探索の前）に `check_existing_impl_pr "$issue_number"` 呼び出しを挿入。claim ラベル付与より前に linked PR 確認が走る
- 1.2 — `check_existing_impl_pr` が OPEN を含む集合で `return 1`、Dispatcher が `continue` で次 Issue へ進むため `claude-claimed` を付与しない（line 3454 + line 4647 の if 分岐）
- 1.3 — 同関数が MERGED 集合で `return 1`、Dispatcher が `continue`（line 3458）
- 1.4 — `pclp_log` / `pclp_warn` / `pclp_error` の prefix `pre-claim-probe:` 固定、key=value 形式 `issue=#N pr=#P state=S reason=R`（line 3354-3361 + 各判定ログ）
- 1.5 — 採用 PR 集合空または CLOSED のみで `return 0`、Dispatcher は既存 claim → fork → wait に合流（line 3462 / 3466）
- 1.6 — head pattern `^claude/issue-${N}-design-` で design PR を warn 出して除外、それ以外は impl 扱い（line 3437-3443）。GraphQL `closedByPullRequestsReferences` 自体が auto-close キーワード（`Closes`）でのみ収集するため design PR は構造的に含まれず、二重ガードとして head pattern 確認も実装
- 1.7 — `gh api graphql` rc!=0 / `errors[]` / RATE_LIMITED / jq parse error をすべて `pclp_warn` + `return 1`（line 3413-3431）
- 2.1 — `.github/scripts/idd-claude-labels.sh` line 71 / `repo-template/.github/scripts/idd-claude-labels.sh` line 67 の `claude-failed` description に「復旧時は ready-for-review を先に付与してから外す」を追記
- 2.2 — local 側 52 文字 / template 側 42 文字（`wc -m` で確認、いずれも 100 文字制限内）
- 2.3 — 既存 `--force` 分岐（labels.sh の `gh label create ... --force`）を再利用、name|color|description 形式の description のみ更新で上書き挙動が維持される
- 2.4 — git diff で labels.sh 系の `-` 行は description フィールドのみ。`claude-failed|e74c3c|` の name|color 部分は不変
- 3.1 — `build_recovery_hint` の全分岐（yes / no / unknown）で「`ready-for-review`」「`claude-failed`」「先に付与」を含む（line 1493-1559）
- 3.2 — 全分岐で「`force-push`」「破壊」「再 pickup」「orphan 化」を含む
- 3.3 — `pr_present="no"` 分岐で「PR が無い場合は claude-failed 除去のみで再 pickup される」旨を出力（line 1531-1539）
- 3.4 — `mark_issue_failed`（line 3056）/ `_slot_mark_failed`（line 3898）/ `pi_escalate_to_failed`（line 1603）の 3 経路すべてで `build_recovery_hint` を append。`qa_build_escalation_comment` は claude-failed 経路でないため対象外（要件と整合）
- 4.1 — README.md line 531 に新節「`claude-failed` 状態の Issue から手動復旧する手順」を追加
- 4.2 — 新節内で「ケース 1: PR が既に作成済みの場合」「ケース 2: PR が無い場合」と明示的に分岐
- 4.3 — ケース 1 で「`ready-for-review` 先付与 → `claude-failed` 除去」の順序、PR #62 orphan 化事例への参照を含む
- 4.4 — ケース 2 で「`claude-failed` を除去すると watcher が次サイクルで再 pickup する」旨を記述
- 4.5 — README.md line 303（GitHub ラベル設定表）/ line 526-529（既存「失敗時」節末尾に⚠️ 段落で誘導）/ line 583（ラベル状態遷移まとめ表の `claude-failed` 行）の 3 箇所から `#claude-failed-状態の-issue-から手動復旧する手順` アンカーへ相互参照
- NFR 1.1 — 新規 env var を導入せず、`DRR_GH_TIMEOUT` / `MERGE_QUEUE_GIT_TIMEOUT` の既存 env を流用（line 3399）
- NFR 1.2 — env var 追加なし → cron / launchd 登録文字列の変更不要（git diff で `*/2 *` / `REPO=` 等の変更なし）
- NFR 1.3 — `check_existing_impl_pr` の skip は per-issue `continue` のみで script 全体 exit code に影響しない
- NFR 1.4 — labels.sh の `claude-failed|e74c3c|...` の name / color フィールド不変
- NFR 1.5 — PR 不在 / CLOSED のみ時は `return 0` で素通り、既存 claim → fork → wait フローに完全合流
- NFR 2.1 — 全ログに `pre-claim-probe:` prefix（line 3354-3361）
- NFR 2.2 — 固定 key=value 形式 `issue=#N pr=#P state=S reason=R`
- NFR 2.3 — per-issue ループ内で 1 件ごとに `pclp_log` を呼ぶため複数 skip も独立行
- NFR 3.1 — `shellcheck -S warning local-watcher/bin/issue-watcher.sh` 実行で warning 0 件確認（reviewer 再実行）
- NFR 3.2 — 同上で `.github/scripts/idd-claude-labels.sh` / `repo-template/.github/scripts/idd-claude-labels.sh` も warning 0 件
- NFR 3.3 — impl-notes.md の dogfood-A 手順節（line 214-251）に OPEN PR シナリオ手順を記述
- NFR 3.4 — 同 dogfood-B 手順節（line 253-271）に CLOSED PR シナリオ手順を記述
- NFR 4.1 — per cycle 最大 5 issue × 1 GraphQL call = 最大 5 calls/cycle、30 cycle/h で 150 calls/h（GraphQL primary 5000 points/h に対して 33 倍余裕）
- NFR 4.2 — `RATE_LIMITED` GraphQL error と HTTP 429 検出時に `reason=rate-limited` で warn + skip（line 3415-3419 / 3424-3427）

## Findings

なし。

## Summary

要件 1.1〜1.7 / 2.1〜2.4 / 3.1〜3.4 / 4.1〜4.5 / NFR 1.1〜1.5 / 2.1〜2.3 / 3.1〜3.4 /
4.1〜4.2 のすべてが、最新 commit の差分または既存コードのいずれかでカバーされている
ことを確認した。tasks.md `_Boundary:_` 違反なし。`shellcheck -S warning` クリーン。

RESULT: approve
