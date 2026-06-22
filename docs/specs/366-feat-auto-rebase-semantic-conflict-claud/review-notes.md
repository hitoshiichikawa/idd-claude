# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-22T12:50:00Z -->

## Reviewed Scope

- Branch: claude/issue-366-impl-feat-auto-rebase-semantic-conflict-claud
- HEAD commit: 2121e11e77f16d35bad33feaf4b6840fc00c6b48
- Compared to: main..HEAD
- 対象 diff（commit 2 件）: `feat(#366)` 実装 + `docs(spec)` 要件定義

## Verified Requirements

- 1.1 — `issue-watcher.sh` Config: `AUTO_REBASE_SEMANTIC="${AUTO_REBASE_SEMANTIC:-off}"` で既定 `off`
- 1.2 — `case` 文で `claude` のみ受理（`local-watcher/bin/issue-watcher.sh:259-263`）
- 1.3 — `off` のまま保持（同上 `case` ロジック）
- 1.4 — `claude` 以外（未設定 / 空 / `Claude` / `on` / typo）は `off` に正規化（テスト `ar_semantic_test.sh` Section 1.5 / 2.1〜2.9 で実証）
- 1.5 — Config ブロックは `process_auto_rebase` 起動前に評価される構造（issue-watcher.sh 冒頭）
- 1.6 — サイクル開始 echo 行に `auto-rebase-semantic=${AUTO_REBASE_SEMANTIC}` を追加（`issue-watcher.sh:1022`）
- 2.1 — `ar_semantic_enabled` が両 gate ON のみ rc=0（テスト Section 1.1）
- 2.2 — gate OFF で rc=1（テスト Section 1.2）
- 2.3 — kill switch OFF で rc=1（テスト Section 1.3）
- 2.4 — gate OFF 時は `ar_apply_semantic` 旧経路 fall-through（テスト Section 6）
- 2.5 — `FULL_AUTO_ENABLED` も厳密 `true` 一致のみ（テスト Section 1.6）
- 3.1 — gate OFF 時 `ar_apply_semantic` は旧コードパス（diff で確認）
- 3.2 — `process_auto_rebase` の早期 return / `AUTO_REBASE_MODE=off` チェック保持
- 3.3 — 二重実行は `ar_semantic_should_skip_idempotent` で抑止
- 3.4 / 3.5 — 既存 env var の rename / removal なし（diff 確認、Config の追加のみ）
- 4.1 — `ar_semantic_enabled` 配下の `ar_run_claude_rebase` 呼出（既存経路の再利用）
- 4.2 — 既存 `ar_run_claude_rebase` 内で `--force-with-lease` 使用（既存実装の流用）
- 4.3 — `ar_log` 行に `before=${before_sha} after=${after_sha}` を出力
- 4.4 — `ar_apply_semantic_claude` のコメント本文に (a)(b)(c)(d) 全項目を含む（diff で確認）
- 4.5 / 4.6 — 既存 `ar_run_claude_rebase` の rc=2/3 → `ar_escalate_to_failed` 経路を流用
- 4.7 — `ar_fetch_candidates` の server-side filter `-label:"$LABEL_FAILED"` で除外維持
- 5.1 — `ar_apply_semantic_claude` 内 `ar_dismiss_all_approvals` 呼出
- 5.2 — `ar_apply_semantic_claude` 内 `--add-label "$LABEL_READY"` 実行
- 5.3 — auto-merge を直接トリガしない（コメント投稿のみ）
- 5.4 — pr-reviewer.sh の既存挙動に依存（仕様上の前提）
- 5.5 — dismissal + approve 復帰前は auto-merge 発火条件を満たさない（既存 auto-merge processor 経路）
- 5.6 — branch protection 上書きなし（既存 ar_dismiss_all_approvals の挙動踏襲）
- 6.1 — `ar_semantic_should_skip_idempotent` で前回 SHA == 現 SHA → skip（テスト Section 4.2）
- 6.2 — `$HOME/.issue-watcher/auto-rebase-semantic/$REPO_SLUG/pr-<N>.json`、JSON schema 確認（テスト Section 3.1〜3.4）
- 6.3 — fail-open（不在 / 破損 JSON で `{}` 返却 → 0 attempts 扱い、テスト Section 3.2 / 3.5）
- 6.4 — 成功時 `after_sha` を `last_head_sha` として保存（`ar_handle_pr` の `case 0/2` 内、テスト Section 3.4）
- 6.5 — `ar_handle_pr` 内で同サイクル中の二重呼出は構造上不可（per-PR 単一呼出）
- 7.1 — `AUTO_REBASE_SEMANTIC_MAX_ATTEMPTS` 既定 `3`、非整数 / 0 以下を `3` に正規化（テスト Section 5.5）
- 7.2 — 上限到達で `ar_semantic_budget_exhausted` rc=0、`ar_semantic_escalate_needs_decisions` 呼出（テスト Section 5.3 / 5.4）
- 7.3 — エスカレーションコメント本文に (a)(b)(c)(d) 含む（diff で確認）
- 7.4 — `needs-decisions` ラベル付き PR は `skip-needs-decisions` で処理対象外（`ar_handle_pr` の 1a チェック）
- 7.5 — 試行開始時に `new_attempts=$((prior_attempts + 1))` で加算済み（`ar_handle_pr` の 1d）
- 7.6 — `ar_semantic_escalate_needs_decisions` は `claude-failed` 付与しない（diff で確認）
- 7.7 — state ファイルは PR ごとなので merge / close 時に GC 可能（NFR 5.3 で別途規定）
- 8.1 — `claude-failed` 付き PR は server-side filter で除外（Req 4.7 と同根拠）
- 8.2 — Req 7.6 と整合（escalation で `claude-failed` 付けない）
- 8.3 — `ar_apply_semantic_claude` 内 `--remove-label "$LABEL_NEEDS_REBASE"` 実行
- 8.4 — `needs-decisions` 付与失敗時に `ar_warn` 出力、`return 1`（次サイクルで再試行可能）
- NFR 1.1 — gate OFF 時の旧経路 fall-through を Section 6 で検証
- NFR 1.2 / 1.3 / 1.4 — 既存 env / label / exit code 変更なし
- NFR 2.1 / 2.4 — README に Phase D-12 サブセクション + オプション機能一覧追加
- NFR 2.2 / 2.3 — `.claude/{agents,rules}` の root↔repo-template 同期は本 PR で touch なし（diff に該当変更なし）/ `local-watcher/bin/modules/` は repo-template 配下に存在せず install.sh が root から配布する設計
- NFR 3.1 — shellcheck / bash -n クリーン（reviewer 側で再実行 → 警告ゼロ確認）
- NFR 4.1 — `jq --arg` / `--argjson` sanitize（テスト Section 3.7 で injection 防止確認）
- NFR 4.2 / 4.3 / 4.4 — 既存ガード（fork / `MERGE_QUEUE_HEAD_PATTERN` / head-only push）を変更なし
- NFR 5.1 / 5.2 — `AUTO_REBASE_MAX_PRS` / `AUTO_REBASE_MAX_TURNS_SEC` を流用

## Findings

### Finding 1
- **Target**: 9.1
- **Category**: AC 未カバー
- **Detail**: Req 9.1 は「semantic conflict 候補を評価するとき、log line に **(a) `AUTO_REBASE_SEMANTIC` の解決値 / (b) `FULL_AUTO_ENABLED` の解決値 / (c) PR 番号 / (d) head SHA / (e) 結果 action（`attempt` / `skip-gate-off` / `skip-idempotent` / `skip-claude-failed` / `escalate-needs-decisions`）** を含めること」を要求している。実装の per-PR action log（`ar_handle_pr` 内の `semantic action=attempt` / `skip-needs-decisions` / `escalate-needs-decisions` / `skip-idempotent`）は **(a) `AUTO_REBASE_SEMANTIC` と (b) `FULL_AUTO_ENABLED` の値を含まず**、また **`skip-gate-off`** action（gate OFF 時の semantic 候補に対する skip ログ）と **`skip-claude-failed`** action ラベルが一切出力されていない（`grep -n "skip-claude-failed\|skip-gate-off"` で 0 件確認）。NFR 1.1 は外部副作用（gh / git / label / commit / push / comment）のバイト等価を要求しているのみで log line は対象外のため、Req 9.1 を満たす形で log 行に gate 値と `skip-gate-off` 経路を含める必要がある。
- **Required Action**: `ar_handle_pr` の semantic 関連 `ar_log` 行に `semantic=${AUTO_REBASE_SEMANTIC} full-auto=${FULL_AUTO_ENABLED}` 等のフィールドを追加し、gate OFF で semantic 判定された PR に対しても `action=skip-gate-off` の log 行を 1 件出力する（既存の semantic 完了 log 行に追加するか、gate OFF 時に 1 行追加で対応可能）。

### Finding 2
- **Target**: 9.2
- **Category**: AC 未カバー
- **Detail**: Req 9.2 は「Claude semantic resolution 試行完了時に、log line に **(a) PR 番号 / (b) before / after head SHA / (c) outcome（`resolved` / `timeout` / `dirty` / `push-failed`） / (d) post-attempt 累積 attempt 数** を含めること」を要求している。実装の semantic 完了 log（`classification=semantic before=... after=... action=dismissed+ready url=...` / `action=dismissed+partial-fail`）は **(d) post-attempt 累積 attempt 数（`attempts=N`）を一切含めて**おらず、また failure 経路の outcome 識別子（`resolved` / `timeout` / `dirty` / `push-failed`）も既存の `dismissed+ready` / `dismissed+partial-fail` 等とマッピングされず観測不能。attempt counter は state ファイルから取得可能だが log を grep するだけで燃焼状況を追跡できる状態になっていない。
- **Required Action**: `ar_handle_pr` 内の `case "$semantic_rc" in 0)` / `2)` の `ar_log` 行末尾に `attempts=${_semantic_attempts}` を追加し、Req 9.2 で列挙された `resolved` / `timeout` / `dirty` / `push-failed` 等の outcome 識別子と既存 action ラベルの対応関係を明示する（例: 既存 `action=dismissed+ready` を `action=resolved` に rename するか、両方を併記する）。

### Finding 3
- **Target**: 9.3
- **Category**: AC 未カバー
- **Detail**: Req 9.3 は per-cycle summary line に **`semantic-resolved=N, semantic-failed=N, semantic-escalated=N, semantic-skipped=N`** の 4 つの subtotal を含めることを要求している。実装の summary line（`process_auto_rebase` 末尾の `ar_log "サマリ: mechanical=${mechanical}, semantic=${semantic}, failed=${failed}, skip=${skipped}, overflow=${skipped_overflow}"`）は **subtotal を一切持たない**（`semantic=N` は Claude 解決成功と通常 semantic dismiss を区別せず、`escalate-needs-decisions` は `skipped` に集約）。1 行で運用状況を把握できる状態になっていない。
- **Required Action**: `ar_handle_pr` の戻り値分類を拡張するか、`process_auto_rebase` ループ内で別の counter（`semantic_resolved` / `semantic_failed` / `semantic_escalated` / `semantic_skipped`）を ar_semantic_enabled 配下のみインクリメントするように改修し、summary line にこれらを追記する。NFR 1.1 はバイト等価対象外（gh / git / label / commit / push / comment のみ）なので summary 拡張は安全。

### Finding 4
- **Target**: `NFR 3.2`（missing test として整理）
- **Category**: missing test
- **Detail**: NFR 3.2 は近接テストで以下を **すべて** カバーすることを要求している:
  1. gate `off` で従来 semantic 挙動が保たれること
  2. dual opt-in 不成立で Claude 起動しないこと
  3. **Claude 解決成功時に approve dismissal + `ready-for-review` 付与が行われること**
  4. 同一 head SHA への二重試行が抑止されること
  5. **attempt budget 到達時に `needs-decisions` がつきコメントが投稿されること**

  `ar_semantic_test.sh` は 1 / 2 / 4 を `ar_semantic_enabled` および state IO レベルでカバーしているが、**3 と 5 は直接テストされていない**（`ar_apply_semantic_claude` および `ar_semantic_escalate_needs_decisions` の orchestration を `gh` stub で検証していない）。3 と 5 は本機能の安全性核心（dismissal 維持 + needs-decisions 経路）であり、要件側で明示列挙されているため近接テストの追加が必要。
- **Required Action**: `ar_semantic_test.sh` に以下のテストを追加する:
  - `ar_apply_semantic_claude` を `extract_function` で抽出し、`gh` / `ar_dismiss_all_approvals` を stub して、(a) dismissal が呼ばれる / (b) `needs-rebase` remove + `ready-for-review` add が呼ばれる / (c) コメント本文に before/after SHA と `<!-- idd-claude:auto-rebase-semantic ...` マーカーが含まれる ことを検証
  - `ar_semantic_escalate_needs_decisions` を抽出し、`gh pr edit --add-label needs-decisions` と `gh pr comment` が呼ばれ、`claude-failed` ラベルが **付与されない** ことを検証（Req 7.6 / 8.2 の安全性確認）

## Summary

実装の核心（dual opt-in / 値正規化 / state IO の fail-open / idempotency / attempt budget）は要件と整合し、66 ケースの近接テストが PASS、shellcheck もクリーン。一方で観測可能性に関する Req 9.1〜9.3 は log フィールド・summary subtotal の欠落により観測仕様を満たしておらず、NFR 3.2 の明示列挙テストのうち「dismissal + ready-for-review 付与」「needs-decisions エスカレーション + コメント投稿」の 2 ケースが近接テストでカバーされていない。3 ファイル（auto-rebase.sh の log/summary 拡張 + ar_semantic_test.sh の新規ケース追加）で機械的に修正可能。

RESULT: reject
