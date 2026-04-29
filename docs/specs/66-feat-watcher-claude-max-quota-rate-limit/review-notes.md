# Review Notes — Quota-Aware Watcher (#66)

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-04-30T00:00:00Z -->

## Reviewed Scope

- Branch: `claude/issue-66-impl-feat-watcher-claude-max-quota-rate-limit`
- HEAD commit: `6b9cc278e4e66a2385a6ca7d9aa607fe357fa1f2`
- Compared to: `main..HEAD`（直接的な実装は branch base `4b465ed`〜HEAD の 6 commits、1890 insertions / 47 deletions）
- 判定カテゴリ: AC 未カバー / missing test / boundary 逸脱 の 3 種に限定（CLAUDE.md「禁止事項」および reviewer.md 規約準拠）
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 採否宣言節は **存在しない** → 通常の 3 カテゴリ判定のみ（flag 観点は適用しない）

### 改変ファイル（main..HEAD）

| File | Role |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | Config 節（L62）/ Quota-Aware Helpers セクション（L229〜L542）/ 6 stage 呼び出し点の wrap / Dispatcher exclusion query 追記（L3569） |
| `.github/scripts/idd-claude-labels.sh` | LABELS 配列に `needs-quota-wait` 1 行追加（L75） |
| `repo-template/.github/scripts/idd-claude-labels.sh` | 同上（L71） |
| `README.md` | ラベル表 / 状態遷移 / ポーリングクエリ / opt-in 一覧 / `## Quota-Aware Watcher (#66)` 新規節 |
| `docs/specs/66-feat-watcher-claude-max-quota-rate-limit/impl-notes.md` | Developer 補足ノート（traceability table, smoke test 結果, dogfood 手順, 確認事項） |

## Verified Requirements（numeric ID 全件）

### Requirement 1: Opt-in 切り替えと既定挙動

- 1.1 — `qa_run_claude_stage` 冒頭（issue-watcher.sh:340-343）と `process_quota_resume` 冒頭（issue-watcher.sh:494-496）の `[ "$QUOTA_AWARE_ENABLED" != "true" ]` 早期 return で opt-out 時の全コードパス skip
- 1.2 — opt-in 時に `qa_run_claude_stage` が tee 並走 → `qa_detect_rate_limit` → exit 99 を呼び出し側に伝搬（Req 2-5 全機能を有効化）
- 1.3 — `QUOTA_AWARE_ENABLED="${QUOTA_AWARE_ENABLED:-false}"` で既定 false 固定（issue-watcher.sh:161）
- 1.4 — 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）は git diff 上で変更なし（追加のみ）
- 1.5 — 既定 false で全コードパス skip かつ既存 cron 文字列は `QUOTA_AWARE_ENABLED` を渡さなくても従来通り起動可（impl-notes.md「採用したオプション」5 / README Migration Note）
- 1.6 — 既存 10 ラベル（auto-dev / claude-claimed / claude-picked-up / needs-decisions / awaiting-design-review / ready-for-review / claude-failed / needs-iteration / needs-rebase / skip-triage）の name / color / description は両 labels.sh で不変（diff で確認）

### Requirement 2: rate_limit_event の検知と quota 超過判定

- 2.1 — `qa_run_claude_stage` の tee で stream-json を分岐し、`qa_detect_rate_limit`（issue-watcher.sh:288-309）が jq fold で抽出
- 2.2 — `select(.status? == "exceeded")` フィルタ
- 2.3 — `(.resetsAt // .reset_at // .resets_at // empty)` で複数候補から reset epoch を取り出し、stdout に書き出し
- 2.4 — `tail -1` で同一 stream の最新（最後）の exceeded のみ採用
- 2.5 — `-R` raw 入力 + `try ($line | fromjson) catch null` で行単位個別 parse、`2>/dev/null` で jq エラー抑止 → stream を止めない（commit 23e2820 で修正済）
- 2.6 — `select(.status? == "exceeded")` で `allowed` を構造的に除外

### Requirement 3: needs-quota-wait 付与と escalation

- 3.1 — `qa_handle_quota_exceeded`（issue-watcher.sh:455-489）が `--add-label "$LABEL_NEEDS_QUOTA_WAIT"` を 1 PATCH atomic で発行
- 3.2 — `qa_handle_quota_exceeded` は `claude-failed` を一切呼ばず、各 stage の `case 99` 分岐は `_slot_mark_failed` / `mark_issue_failed` を踏まずに `return 0`（Triage L3275 / StageA L2622 / StageA-redo L2676 / Reviewer L2503 / StageC L2765 / design L3470）
- 3.3 — 同 PATCH 内で `--remove-label "$LABEL_CLAIMED" --remove-label "$LABEL_PICKED"`（issue-watcher.sh:468-471）
- 3.4 — `qa_build_escalation_comment` でテンプレ構築 → `gh issue comment` 投稿（Stage 種別 / reset epoch / ISO 8601 / grace 値を含む）
- 3.5 — Dispatcher の `gh issue list --search` に `-label:"$LABEL_NEEDS_QUOTA_WAIT"` 追加（issue-watcher.sh:3569）
- 3.6 — 既存 7 条件（needs-decisions / awaiting-design-review / claude-claimed / claude-picked-up / ready-for-review / claude-failed / needs-iteration）の意味・順序ともに不変（diff で確認）
- 3.7 — qa 経路は `mark_issue_failed` / `_slot_mark_failed` を呼ばないため、`needs-quota-wait` と `claude-failed` の同時付与は構造的に発生しない

### Requirement 4: reset 時刻の永続化

- 4.1 — `qa_persist_reset_time`（issue-watcher.sh:373-390）が Issue body 末尾に hidden marker `<!-- idd-claude:quota-reset:<epoch>:v1 -->` 1 行を追記
- 4.2 — `qa_load_reset_time`（issue-watcher.sh:397-410）が `gh issue view --json body` で読み出し、`process_quota_resume` から呼び出し
- 4.3 — 書き込み時に `sed -E '/<!-- idd-claude:quota-reset:[0-9]+:v1 -->/d'` で既存 marker 全削除 → 新値 1 行追記（最新値 1 件のみ保持）
- 4.4 — `qa_load_reset_time` は不正値（非数値）時に `return 1` + stdout 空、`process_quota_resume`（issue-watcher.sh:518-521）で skip + `qa_warn` でラベル維持

### Requirement 5: reset 経過後の自動 resume

- 5.1 — `process_quota_resume` を cron tick 冒頭（issue-watcher.sh:542、Phase A Merge Queue Processor L544 より前）で起動
- 5.2 — `now_epoch >= reset_epoch + QUOTA_RESUME_GRACE_SEC` のとき `gh issue edit --remove-label "$LABEL_NEEDS_QUOTA_WAIT"`（issue-watcher.sh:529-531）
- 5.3 — `[ "$now_epoch" -lt "$threshold" ]` で `qa_log` + continue（ラベル維持、issue-watcher.sh:523-526）
- 5.4 — `process_quota_resume` 内ではラベル除去のみ。claim や Stage 実行はトリガーしない
- 5.5 — `QUOTA_RESUME_GRACE_SEC="${QUOTA_RESUME_GRACE_SEC:-60}"` 既定 60 秒、env で上書き可（issue-watcher.sh:165）
- 5.6 — `gh issue list` 失敗時 `qa_warn "needs-quota-wait Issue 取得に失敗"` + `return 0`、各 Issue ラベル除去失敗時も `qa_warn` で吸収

### Requirement 6: ラベル定義スクリプトの冪等更新

- 6.1 — `repo-template/.github/scripts/idd-claude-labels.sh:71` および `.github/scripts/idd-claude-labels.sh:75` に `needs-quota-wait|c5def5|...` 行追加
- 6.2 — 既存 EXISTING_LABELS 機構（既存実装の `gh label list` 比較ロジック）が冪等性を担保（既存ロジック不変）
- 6.3 — 既存 `--force` 機構が上書きを担保（既存ロジック不変）
- 6.4 — LABELS 配列に行を追加するのみ。既存 10 行の name / color / description は変更なし（diff で確認）
- 6.5 — `.github/scripts/idd-claude-labels.sh:75` の description には `【Issue 用】` prefix 含む（root 版 / Issue #54 規約準拠）

### Requirement 7: ドキュメント整合

- 7.1 — README.md に `## Quota-Aware Watcher (#66)` 節を `## Reviewer Gate (#20 Phase 1)` 直前に挿入（diff で確認）
- 7.2 — README.md ラベル一覧表 / ラベル状態遷移まとめ表 / 手動作成コマンド例に `needs-quota-wait` を追加
- 7.3 — 新規節内に env 表（`QUOTA_AWARE_ENABLED` 既定 false / `QUOTA_RESUME_GRACE_SEC` 既定 60）を記載
- 7.4 — 状態遷移図に `claude-claimed → needs-quota-wait → auto-dev` および `claude-picked-up → needs-quota-wait → auto-dev` 経路を追記
- 7.5 — 新規節冒頭の引用ブロックで「`QUOTA_AWARE_ENABLED=false`（既定）では本機能の全コードパスが skip され、既存挙動と完全に互換」を明記

### Requirement 8: Dogfooding による動作検証

- 8.1 / 8.2 / 8.3 / 8.4 — impl-notes.md「dogfooding fixture テスト手順」Step 1〜7 で claude モック PATH 上書き / test issue 起票 / 1 cron tick 実行 / epoch 過去書き換えによる resume 確認 / opt-out 互換性検証 / PR Test plan への転記指針までの完全手順が記載されている。fixture-based 単体ロジック（4 種・全ケース PASS）も併記。AC 8.1〜8.3 の実機 dogfood は scratch repo + cron 反映を要するため Developer フェーズで完結せず、人間レビュアー / 運用者が PR マージ前に実行する想定（手順具体）

### NFR

- NFR 1.1 — `qa_log` が exceeded 検知 / 永続化失敗 warn / ラベル付け替え失敗 warn / resume / waiting / API 失敗 などのイベントを `$LOG`（`LOG_DIR` 配下）に追記
- NFR 1.2 — 各ログ行が `[<timestamp>] quota-aware: ... issue=#<N> stage=<S> reset_epoch=<E> reset_iso=<I>` 形式で grep 可能
- NFR 2.1 — wrapper opt-out 分岐で `"$@"` 素通し、`process_quota_resume` 早期 return、`mark_issue_failed` 経路不変
- NFR 2.2 — qa 経路は `mark_issue_failed` を一切呼ばないため `claude-failed` 関連 Issue / PR 経路は不変
- NFR 2.3 — ラベルスクリプトの既存冪等機構をそのまま利用、既存 10 ラベル不変
- NFR 3.1 — `process_quota_resume` の `gh issue list --json number --limit 50` 1 回 + 0 件時は `return 0`（issue-watcher.sh:507-512）
- NFR 3.2 — 1 Issue あたり最大 2 API call（`qa_load_reset_time` の `gh issue view` + `gh issue edit`）。`--limit 50` で上限抑止
- NFR 3.3 — grace 既定 60 秒で同一 cron tick 内の付与/除去往復を構造的に抑止
- NFR 4.1 — Reviewer 自身の `shellcheck local-watcher/bin/issue-watcher.sh` 実行で新規 error / warning（critical level）0 件を確認。残存する SC2317（unreachable command 誤検知）は既存 `mq_log` / `mqr_error` / `drr_error` / `slot_error` と同形式の info-level
- NFR 4.2 — `shellcheck .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` 実行で新規 warning 0 件を確認

## Boundary 逸脱チェック

tasks.md の `_Boundary:_` で示されるコンポーネント（Label Setup Script / Quota Stream Parser / Quota Persistence / Stage Wrapper / Quota Handler）以外への改変は確認されない。

- 6 stage（Triage / StageA / StageA-redo / Reviewer-r1 / Reviewer-r2 / StageC / design）以外の claude 呼び出し（特に `process_pr_iteration` 内）は wrap されていない（impl-notes.md 確認事項 2 / design.md Non-Goals と一致）
- Dispatcher exclusion query への 1 ラベル追加は Req 3.5 / 3.6 の指示どおり、既存 7 条件の意味・順序ともに変更なし
- 既存 env var / ラベル / cron 文字列 / `mark_issue_failed` 経路は不変

## Missing Test チェック

idd-claude には unit test framework がなく、検証は fixture-based smoke test + shellcheck + 手動 dogfood の組み合わせ（CLAUDE.md「テスト・検証」節）。

- `qa_detect_rate_limit` 8 ケース / `qa_format_iso8601` 1 ケース / hidden marker round-trip 7 ケース / `qa_run_claude_stage` 7 ケース、いずれも impl-notes.md「スモークテスト結果」セクションに PASS 記録あり
- AC 8.1〜8.3（実機 dogfood）は impl-notes.md「dogfooding fixture テスト手順」Step 1〜7 として再現可能な手順記載済（claude モック PATH 上書き + scratch repo + cron 反映が必要なため Developer フェーズで完結できないことが Req 8.4 でも明示）
- 静的解析は Reviewer 自身の `shellcheck` 実行で再確認済（NFR 4.1 / 4.2 達成）

不足テストはない。

## Findings

なし。

## Summary

requirements.md の全 numeric ID（1.1〜8.4 / NFR 1.1〜4.2）について、実装またはテスト手順による
カバレッジを確認できた。tasks.md の `_Boundary:_` 逸脱なし、missing test なし。`QUOTA_AWARE_ENABLED=false`
既定での opt-in gate と既存 6 stage 経路の case 99 分岐により後方互換性が構造的に担保されており、
既存 cron / launchd / 10 ラベル契約は不変。impl-notes.md の自己申告（traceability table / smoke test
結果 / dogfood 手順 / 確認事項）も独立 context での裏取り（git diff / shellcheck / bash -n / コード位置確認）
で齟齬がない。

RESULT: approve
