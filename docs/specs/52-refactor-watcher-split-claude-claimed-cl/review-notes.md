# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-29T04:49:18Z -->

## Reviewed Scope

- Branch: claude/issue-52-impl-refactor-watcher-split-claude-claimed-cl
- HEAD commit: 6e83afd21cc8e24260ae33ca6cda6d08de5007d6
- Compared to: main..HEAD
- Feature Flag Protocol 採否: opt-out（CLAUDE.md に専用節なし → 通常の 3 カテゴリ判定のみ。flag 観点は適用しない）

## Verified Requirements

- 1.1 — Dispatcher claim 時に `claude-claimed` 付与: `local-watcher/bin/issue-watcher.sh` L3162 `--add-label "$LABEL_CLAIMED"`
- 1.2 — claim 時に `claude-picked-up` を付与しない: 同 L3162（claim API は `LABEL_CLAIMED` のみ）
- 1.3 — `claude-claimed` 付与中＝claim/Triage 状態: README L298-302 ラベル定義表 / L529-540 適用先表 / 状態遷移図で文書化
- 1.4 — 付与失敗で slot 解放: L3162-3167 `_slot_release "$slot"; continue`（既存経路継承）
- 2.1 — Triage 通過 → impl 着手で `claude-claimed → claude-picked-up` 付け替え: L2919-2928 `_slot_run_issue` の atomic gh issue edit
- 2.2 — impl 進行中は `claude-picked-up` のみ: L2919-2928 で除去 + 付与を 1 コール、以降 `mark_issue_failed` まで触らない
- 2.3 — 同時 2 ラベル状態を継続させない: 単一 `gh issue edit --remove-label A --add-label B` の atomic API call に依拠（L2893-2895 / L2920-2922）
- 3.1 — Triage 結果 `needs-decisions` で `claude-claimed` 除去 + `needs-decisions` 付与: L2893-2895
- 3.2 — Triage = needs_architect で `claude-claimed → awaiting-design-review`: Slot Runner で design 経路は L2919 `if [ "$MODE" = "impl" ] || [ "$MODE" = "impl-resume" ]` を skip し、design prompt L2970 で PjM に `claude-claimed → awaiting-design-review` を指示。`.claude/agents/project-manager.md` L30 / `repo-template/.claude/agents/project-manager.md` L30 でも `削除: claude-claimed` に更新
- 3.3 — Triage 失敗で `claude-claimed` 除去 + `claude-failed` 付与: `_slot_mark_failed` L2698-2700 両系統除去
- 3.4 — `claude-claimed` を Triage 終了経路で残置しない: needs-decisions（L2893）/ design 経路（L2970 prompt + PjM agent）/ impl 着手（L2919-2928）/ Triage 失敗（`_slot_mark_failed`）/ impl pipeline 失敗（`mark_issue_failed` L2206-2207）の 5 経路すべてで除去
- 4.1 — `claude-claimed` 付き Issue を新規 pickup から除外: Dispatcher exclusion query L3107 `-label:"$LABEL_CLAIMED"` 追加
- 4.2 — exclusion query が全終端を排除: L3107 で `NEEDS_DECISIONS` / `AWAITING_DESIGN` / `CLAIMED` / `PICKED` / `READY` / `FAILED` / `NEEDS_ITERATION` をすべて含む
- 4.3 — 同一サイクル多 slot で同 Issue 二重 claim 不可: `_dispatcher_find_free_slot` の単一プロセス逐次実行（PR #51 Phase C 由来、本変更で破壊せず）
- 5.1 — 旧 `claude-picked-up` のみの進行中 Issue を中断・再 claim せず完走: exclusion query L3107 が `LABEL_PICKED` も継続除外（追加であって置換ではない）
- 5.2 — 既存 env var 不変: `LABEL_CLAIMED` 追加のみ。`REPO`/`REPO_DIR`/`LOG_DIR`/`LOCK_FILE`/`TRIAGE_MODEL`/`DEV_MODEL` 等は git diff で未変更
- 5.3 — cron / launchd 登録文字列不変: watcher 起動行は変更なし
- 5.4 — 既存ラベル名・意味不変: `idd-claude-labels.sh` LABELS 配列に 1 行追加のみ、既存 9 行は touch していない
- 5.5 — `claude-claimed` 未存在時に slot 解放扱い: L3162-3167 の `--add-label` 失敗 → `_slot_release` + `continue`（Req 1.4 と同経路）
- 6.1 — `idd-claude-labels.sh` で `claude-claimed` 追加: `.github/scripts/idd-claude-labels.sh` L68 `claude-claimed|c39bd3|【Issue 用】 ...`
- 6.2 — 既存時は冪等スキップ: 配列追加のみで既存 EXISTS 分岐ロジックがそのまま適用
- 6.3 — `--force` で上書き更新: 同上、UPDATED 分岐流用
- 6.4 — 既存ラベル群の name / color / description 不変: diff 確認済み（追加 1 行のみ）
- 6.5 — description に【Issue 用】prefix（Issue #54 規約）: `.github/scripts/idd-claude-labels.sh` L68 で確認
- 7.1 — README 状態遷移セクションが両ルートを図示: README L562-585 で `auto-dev → claude-claimed → (impl 系 / design 系 / needs-decisions)` を明示
- 7.2 — README ラベル一覧に `claude-claimed` 追加: L300 ラベル定義表 / L536 適用先表（付与/除去タイミング記載あり）/ L549 ポーリングクエリ例
- 7.3 — README に Migration Note: README L1505-1511 に Issue #52 専用 Migration Note 追加（再実行手順 / 在進行中 Issue の扱い / env var 不変 / 既存 9 ラベル不変 / label-handover 失敗時の手当）
- 7.4 — PjM impl 系では `claude-picked-up` のみ指定: `.claude/agents/project-manager.md` の implementation モード「実施事項」3 番は不変（diff で確認）
- 8.1 — dogfood: impl ルート遷移成立: 全変更により遷移経路が成立。E2E 検証は Task 6.3 として deferrable（impl-notes.md「検証結果」末尾で merge 後 dogfooding する旨を明示）
- 8.2 — dogfood: needs-decisions ルート: 同上
- 8.3 — dogfood: awaiting-design-review ルート: design 経路で `claude-picked-up` 付け替えを skip（L2919 if 条件）+ PjM design-review が `claude-claimed → awaiting-design-review` 直行（agent template 更新 + prompt L2970 更新）。dogfood 検証は deferrable
- NFR 1.1 — ラベル付与/除去をログ出力: `dispatcher_log` / `dispatcher_warn` / `slot_log` / `slot_warn` で各遷移点を記録（L2897 / L2923 / L2927 / L3164 等）
- NFR 1.2 — 同時 2 ラベル状態 5 秒以上継続させない: 単一 `gh issue edit --remove-label X --add-label Y` API call の atomicity に依拠（L2893-2895 / L2920-2922）。branch 作成より前に挿入し、後続長時間操作中はラベル状態が常に正しい
- NFR 2.1 — `idd-claude-labels.sh` 再実行のみで導入完了: LABELS 配列追加のみ
- NFR 2.2 — 旧 watcher 由来の進行中 Issue で誤遷移なし: exclusion query が `LABEL_PICKED` 継続除外
- NFR 3.1 — shellcheck 警告 0 件: reviewer 側で `shellcheck local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` を再実行し、SC2317 / SC2012 等の **既存** info 警告のみ（本 PR 変更箇所と無関係）。新規警告 0 件を確認
- NFR 3.2 — actionlint 警告 0 件: YAML 不変（`git diff main..HEAD --name-only` に `.yml` / `.yaml` なし）。構造的に新規警告は発生しない

## Findings

なし

## Summary

要件定義の 8 Requirement / 23 AC + 6 NFR すべてに対応する実装または文書化を確認した。Dispatcher / Slot Runner / `_slot_mark_failed` / `mark_issue_failed` / PjM design-review prompt の各遷移点が一貫して `claude-claimed` を付与・除去するように更新され、後方互換性（既存 env var / cron / 既存 9 ラベル / 旧進行中 Issue の自然消化）も exclusion query への `LABEL_CLAIMED` 追加（既存 `LABEL_PICKED` も維持）と LABELS 配列への 1 行追加のみで担保されている。shellcheck 新規警告 0 件、YAML 不変による actionlint 新規警告 0 件も再現確認済み。dogfooding E2E（Req 8.1〜8.3）は impl-notes.md に「merge 後実施」の運用方針が明記されており、Testing Strategy が dogfooding を主体としている設計と整合する。3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）いずれにも該当する欠落なし。

RESULT: approve
