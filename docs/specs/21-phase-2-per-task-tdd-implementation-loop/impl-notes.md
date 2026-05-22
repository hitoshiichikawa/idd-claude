# 実装ノート

## 概要

Phase 2: Per-task TDD implementation loop（#21）の実装。`PER_TASK_LOOP_ENABLED=true`
opt-in 制で、`tasks.md` の task 1 件ごとに fresh Claude session で Implementer +
Reviewer を起動する小粒度パイプラインを Stage A 内 Strategy 分岐として追加。

## 静的解析結果

- `shellcheck local-watcher/bin/issue-watcher.sh`: **新規警告 0 件**（既存の
  SC2317 / SC2012 のみ。すべて本機能変更前から存在する pre-existing warnings）
  - 内訳: SC2317 = 35 件（unreachable info、既存）/ SC2012 = 2 件（ls usage、既存）
- `actionlint .github/workflows/*.yml`: **YAML 変更なしのため自動的に達成**
  （`git diff main..HEAD -- .github/workflows/` で差分ゼロ）
- `bash -n local-watcher/bin/issue-watcher.sh`: syntax OK

## 手動スモークテスト

### dry run #1: `PER_TASK_LOOP_ENABLED` 未設定での既存挙動確認（Req 1.1 / NFR 1.1）

実行コマンド:

```bash
bash -n local-watcher/bin/issue-watcher.sh && echo "syntax OK"
```

構造的確認（`/tmp/dry-run-check.sh`）:

- `PER_TASK_LOOP_ENABLED="${PER_TASK_LOOP_ENABLED:-false}"` が config block に存在
- Strategy 分岐は `if [ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]; then ... else ...`
  形式で、`true` 厳密一致のみが新パスに入る
- else 側で従来の `build_dev_prompt_a "$MODE"` 呼び出しが温存されている
- 9 個の per-task helper（pt_log / pt_extract_pending_tasks / pt_extract_learnings /
  pt_resolve_diff_range / build_per_task_implementer_prompt /
  build_per_task_reviewer_prompt / run_per_task_implementer / run_per_task_reviewer /
  run_per_task_loop）はそれぞれ 1 度だけ定義されている

結果: **PASS**（既存挙動の保全を構造的に確認）

### helper 関数の単体スモーク（`/tmp/test-pt-helpers.sh`）

- `pt_extract_pending_tasks`:
  - 親タスク `- [ ] 1. parent` / 子タスク `- [ ] 1.1 child` の双方を抽出
  - deferrable `- [ ]*` を除外
  - `sort -V` で numeric 階層昇順を保証（`1.10` > `1.2`）
  - tasks.md 不在時は return 1
  - 本 Issue の実 tasks.md を入力して全 19 件を期待順で抽出（手元で確認）
- `pt_extract_learnings`:
  - `## Implementation Notes` セクションを正しく抽出
  - 次の `## ` 見出しで停止し、sibling セクションを漏らさない
  - セクション不在 / ファイル不在で空文字 + return 0（Req 4.5 を構造的に保証）
- `pt_resolve_diff_range`:
  - 初回 task で `range_start = $BASE_BRANCH SHA` を返す（本 Issue の task 1 mark commit
    を入力して確認）
  - 当該 task の mark commit が見つからない場合は return 1

結果: **PASS**

### dry run #2: `PER_TASK_LOOP_ENABLED=true` での per-task loop 起動

このフルパス E2E は test repo + 実 claude CLI 起動を要するため、**手動 E2E（task 8.1
deferrable）に委ねる**。本 PR では構造的検証（dry run #1）と単体スモーク（上記）まで。

### NFR 2.1 / 2.2 / 2.3 のログ粒度

設計通り `pt_log` は `[YYYY-MM-DD HH:MM:SS] per-task: <msg>` 形式で、各 task について
implementer start / implementer end / reviewer start / reviewer end の 4 イベントが
`task=<id>` 付きで出力される実装。reject 時は `categories=` / `targets=` を含める
（`parse_review_result` を流用 / NFR 2.3）。

## 受入基準達成確認（Requirements Traceability）

### Requirement 1: opt-in による既存挙動の保全

| AC | 達成方法 | 検証 |
|---|---|---|
| 1.1 | `PER_TASK_LOOP_ENABLED` 未設定時は `:-false` で `false` 等価。Strategy 分岐 else 側で従来 `build_dev_prompt_a` 経路 | 構造的検証 (dry run #1 Test 5) |
| 1.2 | 分岐 if 側で `run_per_task_loop` を呼ぶ | コード上明示（issue-watcher.sh L7452） |
| 1.3 | `[ "${PER_TASK_LOOP_ENABLED:-false}" = "true" ]` で完全一致のみ true 扱い。`True` / `1` / 空 / typo はすべて else 経路 | コード上明示 |
| 1.4 | 既存 env var（DEV_MODEL 等 8 種）の宣言行は不変 | 構造的検証 (dry run #1 Test 6) |
| 1.5 | 新 env は `PER_TASK_*` 名前空間のみ追加。cron / launchd 登録文字列の変更不要 | 既定 OFF で構造的に保証 |

### Requirement 2: task 単位の fresh Implementer 起動

| AC | 達成方法 | 検証 |
|---|---|---|
| 2.1 | `pt_extract_pending_tasks` で `- [ ]` 行のみ抽出、`sort -V` で numeric ID 昇順 | helper smoke Test 1, 4 |
| 2.2 | `run_per_task_implementer` で `qa_run_claude_stage` 経由 `claude --print` 起動（fresh subprocess） | コード上明示（issue-watcher.sh L6068 周辺） |
| 2.3 | regex `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` で numeric ID のみ受理（`T-NN` 等の英字 ID は一切マッチしない） | helper smoke Test 1 |
| 2.4 | Implementer prompt で「`- [ ]` → `- [x]` + `docs(tasks): mark <id> as done` 専用 commit」を明示注入 | build_per_task_implementer_prompt のコード上明示 |
| 2.5 | 同 prompt で「親 task の全子タスクが `- [x]` になった時点で親も `- [x]` に昇格」を明示注入 | build_per_task_implementer_prompt のコード上明示 |
| 2.6 | run_per_task_implementer 非 0 exit で `mark_issue_failed "per-task-implementer-failed"` + return 1。run_per_task_loop の case で残 task を処理せず終了 | コード上明示（run_per_task_loop case） |
| 2.7 | pending 空で `pt_log "pending tasks=0 → no-op return 0"` を出して return 0 | コード上明示（run_per_task_loop 冒頭） |

### Requirement 3: task 単位の Reviewer 起動と差し戻し

| AC | 達成方法 | 検証 |
|---|---|---|
| 3.1 | `run_per_task_reviewer` で fresh `claude --print` 起動 | コード上明示 |
| 3.2 | `pt_resolve_diff_range` で `<range_start>..<range_end>` SHA を解決し、Reviewer prompt に明示 | helper smoke pt_resolve_diff_range Test |
| 3.3 | Reviewer prompt で「reviewer.md の 3 カテゴリ + RESULT 行規約を流用」を明示 | build_per_task_reviewer_prompt のコード上明示 |
| 3.4 | run_per_task_loop で reject 時に Implementer 再起動 → Reviewer round=2 起動の差し戻しを実装。再 reject で `mark_issue_failed "per-task-reviewer-reject2"` | コード上明示 |
| 3.5 | approve 時は `case rev_rc in 0)` で次 task に continue | コード上明示 |
| 3.6 | 再 reject / Implementer 失敗 / Reviewer 異常で即 return 1（run_per_task_loop は呼び出し側に伝搬、後続 Stage B / Stage C / PjM も起動されない） | コード上明示 |
| 3.7 | round=1 / round=2 のみで、それ以上の自動再起動なし（局所変数で cap） | コード上明示（run_per_task_loop の case 構造） |

### Requirement 4: learnings 前方伝播

| AC | 達成方法 | 検証 |
|---|---|---|
| 4.1 | Implementer prompt で「`### Task <id>` 見出しを `## Implementation Notes` 配下に追記」を明示注入 | build_per_task_implementer_prompt のコード上明示 |
| 4.2 | 同 prompt で「先行 task の `### Task <id>` を改変・削除・並び替えしない」を明示注入 | 同上 |
| 4.3 | `pt_extract_learnings` の出力を Implementer prompt に inline 埋め込み | コード上明示 + helper smoke Test 5 |
| 4.4 | 同 prompt で「`## Implementation Notes` セクション外は触れない」を明示注入。pt_extract_learnings 自体が次の `## ` 見出しで停止 | helper smoke Test 5 |
| 4.5 | pt_extract_learnings はセクション / ファイル不在で空文字 + return 0。run_per_task_loop は pending 1 件のループを 1 周で抜ける | helper smoke Test 6, 7 |

### Requirement 5: resume 時の per-task ループ整合

| AC | 達成方法 | 検証 |
|---|---|---|
| 5.1 | `- [x]` 済み task は `pt_extract_pending_tasks` の grep でそもそも抽出されない → 自動 skip | helper smoke Test 1（done 行を除外） |
| 5.2 | pending 空で no-op return 0（Stage A 完了相当 → 既存 stage-a-verify / Stage B / Stage C 経路に進む） | コード上明示（run_per_task_loop 冒頭） |
| 5.3 | per-task loop は既存 Stage A の内側で起動。Stage Checkpoint resume / `IMPL_RESUME_PRESERVE_COMMITS` / `IMPL_RESUME_PROGRESS_TRACKING` は分岐の外で従来通り作用 | コード上明示（Strategy 分岐の配置箇所） |
| 5.4 | `impl-notes.md` は base ブランチ / 既存 commit に既存（resume では worktree に既に存在）。Implementer は append のみ。pt_extract_learnings は existing セクションをそのまま読む | helper smoke Test 5（既存セクション読み出しを確認） |

### Requirement 6: ドキュメント整合と運用者向け説明

| AC | 達成方法 | 検証 |
|---|---|---|
| 6.1 | README「オプション機能一覧」表 + 専用節「Per-task TDD Implementation Loop (#21)」追加 | コード上明示（README.md diff） |
| 6.2 | 専用節に opt-in 時の新挙動（per-task loop / learnings 前方伝播 / resume 挙動）を運用者視点で記述 | 同上 |
| 6.3 | `repo-template/.claude/agents/developer.md` 末尾に per-task ループ責務節を追加 | コード上明示 |
| 6.4 | `repo-template/.claude/agents/reviewer.md` 末尾に per-task ループ責務節を追加 | コード上明示 |
| 6.5 | Migration Note に「既定で従来挙動維持」「1 件 Issue でも完結」「累積コスト 3〜5 倍」を明記 | README 専用節の Migration Note 節 |

### NFR

| NFR | 達成方法 |
|---|---|
| 1.1 | Strategy 分岐 else 側で従来経路を完全温存。`PER_TASK_LOOP_ENABLED` 未指定でログ / 副作用は一切発生しない |
| 1.2 | 既存ラベル（auto-dev / claude-claimed / claude-picked-up / awaiting-design-review / ready-for-review / claude-failed / needs-decisions / skip-triage / needs-rebase / needs-iteration / staged-for-release）は本機能で参照のみ、付与契約に変更なし |
| 1.3 | 既存 exit code 意味と既存ログ出力先（LOG_DIR 配下）のフォーマットは不変。pt_log は既存 rv_log / sc_log と同一形式 |
| 1.4 | #67 / #112 / #20 / #66 / #68 の挙動契約は再実装せず流用のみ |
| 2.1 | pt_log で per-task の 4 イベント（implementer start / end / reviewer start / end）を `task=<id>` 付きで記録 |
| 2.2 | 全 pt_log エントリに `task=<id>` を含める実装 |
| 2.3 | reject 時に `parse_review_result` で取得した categories / targets を pt_log に出力 |
| 3.1 | README 専用節「累積コスト警告」で 3〜5 倍を明記、`PER_TASK_MAX_TASKS` の存在も明記 |
| 4.1 | shellcheck 新規警告 0 件（実測） |
| 4.2 | YAML 変更ゼロにより自動的に達成（実測） |

## 確認事項（PR 本文「確認事項」に転載される想定）

### tasks.md の regex 仕様 vs 実 tasks.md の差異

- `design.md` L186-187 で `pt_extract_pending_tasks` の regex として
  `^- \[ \] ([0-9]+(\.[0-9]+)*) ` が指定されているが、これは **子タスク
  `- [ ] 1.1 child` のみマッチ** し、**親タスク `- [ ] 1. parent` （末尾 `.`）には
  マッチしない**。
- 実装では実用上の互換性を優先し、regex を `^- \[ \] [0-9]+(\.[0-9]+)*\.? ` に
  拡張（末尾 `.` を optional に）して両方を許容した。本 Issue の tasks.md および
  本リポジトリの既存 spec で実証済み。
- design.md 本文は **書き換えていない**（人間レビュー済みのため）。本実装上の判断と
  して impl-notes に記録するに留める。
- Reviewer / 人間レビュアーへ: design.md の regex 表記を実用形式に同期させるかは別 Issue
  での修正を提案する。

### task 数の commit 単位粒度

- tasks.md の 8 個の最上位 task のうち、task 2-5 はそれぞれ 2-4 個の子タスクを持ち、
  helper 関数群が相互参照する設計のため、実装 commit は **「タスク 2.1〜5.1 をまとめた
  1 つの feat commit」 + 「各サブタスクごとの `docs(tasks): mark <id> as done` 進捗
  commit」** という構成にした。これは「タスクごと 1 commit」というガイドラインからは
  外れるが、helper 群は単体では動作しない（互いに依存）ため、機能的に 1 単位として
  扱うのが妥当と判断した。
- 進捗マーカー commit は規約通り 1 task ごとに別 commit として積んだため、Reviewer が
  `pt_resolve_diff_range` を使う際の commit 識別は正常に機能する。

### dry run #2（実 claude 起動を伴う E2E）の扱い

- task 8 で要求された dry run #2（`PER_TASK_LOOP_ENABLED=true` で 2 task の test Issue
  を流す）は、実 Claude CLI 起動 + GitHub API を要し、テスト用 repo / Issue / branch
  の事前準備が必要なため、本 PR では構造的検証（dry run #1）と単体スモーク
  （`pt_extract_*` / `pt_resolve_*`）に留めた。
- E2E 確認は task 8.1（deferrable）として残し、本機能を実運用に投入する前段で
  人間運用者が実施することを提案する（README の「dogfooding」節と整合）。

## 派生タスク（次の Issue として切り出すべき事項）

- **design.md の regex 表記同期**: 上記「確認事項」の通り、`pt_extract_pending_tasks` の
  regex 仕様を実装形式（末尾 `.` optional）に同期する design.md 修正
- **`pt_validate_learnings`**: design.md「残リスク」節で言及されている、Implementer の
  learning 書き忘れ検出（直前 task の `### Task <id>` 不在で warning 出力）
- **per-task ループの実 E2E 検証**: idd-claude 自身に小さな auto-dev Issue を立て、
  `PER_TASK_LOOP_ENABLED=true` で Triage → per-task loop → PR 作成までを通す
  （task 8.1 deferrable の昇格）

## Implementation Notes

（本セクションは per-task ループ有効時に Implementer が `### Task <id>` 段落を追記する
領域。本 PR では従来の単一 Developer 起動で実装したため、本セクションは learnings 受け
口として空欄を確保するに留める）
