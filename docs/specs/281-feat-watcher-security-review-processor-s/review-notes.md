# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-04T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-281-impl-feat-watcher-security-review-processor-s
- HEAD commit: e7621632e1aa73237ad5a46581826da35d20f6e5
- Compared to: main..HEAD
- Changed files: `.github/scripts/idd-claude-labels.sh` / `local-watcher/bin/issue-watcher.sh` / `local-watcher/bin/modules/security-review.sh` / `README.md` / `docs/specs/281-.../impl-notes.md` / `docs/specs/281-.../tasks.md`
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 解釈、flag 観点の追加判定は行わない

## Verified Requirements

- 1.1 — `sec_check_strict_request` `case "$mode"` で `advisory|""` → `"advisory"`（modules/security-review.sh `case` block）
- 1.2 — `case strict)` → `"strict"`。`sec_run_review_for_pr` で `_sec_resolved_mode = "strict"` 厳密一致 + `total_findings > 0` のとき strict 判定枝に入る
- 1.3 — `process_security_review` cycle start ログ `sec_log "cycle start: mode=${mode} threshold=${threshold} ..."`
- 1.4 — `case *)` で `sec_warn "...許容値（strict/advisory）に一致しません..."` + `resolved="advisory"`
- 1.5 — Config `SECURITY_REVIEW_MODE="${SECURITY_REVIEW_MODE:-advisory}"`（issue-watcher.sh）、未設定で advisory 解釈
- 2.1 — `sec_resolve_block_severity` `case critical|high|medium|low|info)` ホワイトリスト照合
- 2.2 — Config `SECURITY_REVIEW_BLOCK_SEVERITY="${SECURITY_REVIEW_BLOCK_SEVERITY:-high}"`
- 2.3 — `sec_severity_at_or_above` ordinal map (critical=5, high=4, medium=3, low=2, info=1) + `[ "$sev_ord" -ge "$thr_ord" ]`
- 2.4 — `case *)` で `sec_warn "...許容値に一致しません..."` + `echo "high"`
- 2.5 — cycle start ログに `threshold=${threshold}` を含む
- 3.1 — `sec_apply_block_labels` `gh pr edit ... --add-label "${SECURITY_REVIEW_BLOCK_LABEL},needs-iteration"` で原子 2 枚付与
- 3.2 — strict + `_strict_blocking_count = 0` で `sec_log "...閾値以上検出なし、ラベル付与なし"`、`sec_apply_block_labels` 未実行
- 3.3 — `[ "${_sec_resolved_mode:-}" = "strict" ]` 厳密一致のみ strict 枝へ入るため advisory 経路ではラベル付与経路に到達しない
- 3.4 — `sec_post_review_comment`（既存）→ `sec_apply_block_labels` → `sec_write_security_notes` の順で全て実行
- 3.5 — `sec_apply_block_labels` 内 `sec_log "...strict ラベル付与成功 labels=... blocking=... threshold=... sha=..."` および `sec_run_review_for_pr` 内 `strict 判定 blocking=...` log
- 3.6 — `sec_already_processed "$pr_number" "$sha" "security-block"` で既存 marker 検出時に早期 return 0
- 4.1 — 付与する 2 枚は GitHub UI から手動剥がし可能。README strict サブ節に override 手順明記
- 4.2 — marker `kind=security-block` が SHA 単位で残存し再付与抑止
- 4.3 — marker は SHA 単位（既存 `sec_already_processed` 規約）。新 SHA で marker 不在 → 再判定が走る
- 4.4 — `needs-iteration` を 1 コマンドでハードコード同時付与（`--add-label "$LABEL,needs-iteration"`）。PR Iteration Processor 動線接続が成立
- 4.5 — `override_note` を `review_text` 末尾に append。README strict サブ節「override 手順」にも明記
- 5.1 — 既存 `sec_count_severities` を流用し severity_summary を取得（再利用、新規 parse なし）
- 5.2 — `sec_count_blocking_findings` で sed 抽出 + `sec_severity_at_or_above` フィルタによる合算
- 5.3 — 抽出失敗 / `kind=scan-failed` 経路は既存ロジックをそのまま使用、strict 経路に入らない（advisory 安全側）
- 5.4 — `sec_write_security_notes` に `## Threshold Decision` セクション追加（Mode / Threshold / Blocking Count / Decision）
- 6.1 — advisory 経路は `_sec_resolved_mode != strict` のとき strict 枝全体が dead code、`_notes_mode=advisory _notes_threshold=- _notes_decision=advisory-only` で既存 #279 と意味的に等価
- 6.2 — Reviewer agent の `.claude/agents/reviewer.md` / 3 カテゴリ判定は差分対象外
- 6.3 — `review-notes.md` / `RESULT:` 判定ロジックに介入なし
- 6.4 — `pr-reviewer.sh` / `pr-iteration.sh` / `merge-queue.sh` / `auto-rebase.sh` / `promote-pipeline.sh` のいずれも編集なし（diff stat で 6 ファイルのみ変更）
- NFR 1.1 — Config の `${VAR:-advisory}` 解決と strict 枝の no-op 構造（`${_sec_resolved_mode:-}` 安全参照）により mode 未指定環境は #279 と意味的に等価
- NFR 1.2 — 既存 env var 名・既定値は変更なし（issue-watcher.sh diff は新規 3 env の追加のみ、既存 9 env は不変）
- NFR 1.3 — cron / launchd 登録文字列に変更なし（README cron 例は追加のみ）
- NFR 2.1, 2.2 — bash + gh + jq + claude のみで実装、新規ランタイム / 新規 CLI なし
- NFR 3.1 — mode / threshold / blocking / skipped_blocked 全分岐で `sec_log` / `sec_warn` 記録
- NFR 4.1, 4.2 — marker `kind=security-block` + `sec_already_processed` で SHA 単位冪等性、手動剥がし後の同一 SHA 再付与抑止
- NFR 5.1 — impl-notes Task 10 で `shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` 警告ゼロ + `actionlint .github/workflows/*.yml` 警告ゼロを確認
- NFR 6.1 — README に env 名 / 既定値 / 有効化条件 / severity 閾値の意味 / ラベル付与挙動 / override 手順を明記（README 新規「strict モード（#281）」サブ節）
- NFR 6.2 — 同一 PR 内で README 更新済み（rule ファイル変更なし、CLAUDE.md は本機能で挙動変更なし）
- NFR 7.1, 7.2 — `.claude/agents` / `.claude/rules` 変更なし。impl-notes Task 10 で `diff -r` が空を確認

## Findings

なし

## Summary

要件 1.1〜6.4 および NFR 1〜7 のすべての numeric ID について、`modules/security-review.sh` / `issue-watcher.sh` / `idd-claude-labels.sh` / `README.md` の差分または既存コードとの組み合わせで観測可能な実装を確認。境界は tasks.md の `_Boundary:_` 宣言と完全に整合（modules/security-review.sh 内の追加 4 関数 + 既存 3 関数の挙動変更、issue-watcher.sh Config block、idd-claude-labels.sh LABELS 配列追加、README 追記のみ）。advisory 経路は `${_sec_resolved_mode:-}` の安全参照と Config `${VAR:-advisory}` により構造的に no-op で #279 byte 等価を維持。

RESULT: approve
