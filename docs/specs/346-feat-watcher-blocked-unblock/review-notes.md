# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-06-16T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-346-impl-feat-watcher-blocked-unblock
- HEAD commit: 5cbf6671b5fdc652c96bb2b7bb718b6c54bb7719
- Compared to: main..HEAD
- Round: 2（round=1 で reject、本 round で再評価）
- Changed files（main..HEAD 全体）:
  - `local-watcher/bin/issue-watcher.sh`（`dr_unblock_*` 関数群追加 + `_dispatcher_run` 冒頭 sweep 起動 + `dr_format_unresolved_comment` の gate 別文面分岐 + round=2 で終端ラベル除外フィルタ追加）
  - `local-watcher/test/dr_unblock_sweep_test.sh`（新規 / AT-a〜AT-h + 補助 + round=2 で AT-i 追加）
  - `README.md`（オプション機能一覧表 + ラベル状態遷移図 + 専用節）
  - `docs/specs/346-feat-watcher-blocked-unblock/{requirements.md,impl-notes.md}`

## Round=1 Reject 指摘の解消確認

| Round=1 Finding | 解消状況 | 解消箇所 |
|---|---|---|
| Finding 1: Req 2.2 AC 未カバー（`claude-failed` などの終端ラベル除外なし） | **解消** | `local-watcher/bin/issue-watcher.sh` line 9598: `--search` 引数に `-label:"$LABEL_FAILED" -label:"$LABEL_NEEDS_DECISIONS" sort:created-asc` を追加。`LABEL_FAILED=claude-failed`, `LABEL_NEEDS_DECISIONS=needs-decisions` のため、`auto-dev` + `blocked` + `claude-failed` の 3 ラベル組合せ Issue は sweep の `gh issue list` クエリで除外される |
| Finding 2: Req 2.2 missing test | **解消** | `local-watcher/test/dr_unblock_sweep_test.sh` line 352-385 に AT-i（5 assertions）を新規追加: `-label:"claude-failed"` 除外、`-label:"needs-decisions"` 除外、`--label auto-dev` / `--label blocked` / `--state open` 維持を assert |

加えて impl-notes.md Req 2.2 トレース欄も「明示除外を追加」する記述に書き換え済み（line 71）、
`## Reviewer round=1 reject 是正` 節で経緯を明文化済み。

## Verified Requirements

| AC ID | 担保箇所 |
|---|---|
| 1.1 | `dr_unblock_sweep` 冒頭 `dr_unblock_gate_enabled` 判定 + 補助テスト「=true で gate ON」 |
| 1.2 | `dr_unblock_gate_enabled` の `case` 文（`true` 以外は OFF） + AT-c の未設定/false/typo 全パターン |
| 1.3 | `dr_unblock_gate_enabled` の strict 一致 + AT-c の `TRUE` / `1` / `on` / `True` / `tRuE` / `yes` 検証 |
| 1.4 | 既存 env var 名は不変。新規追加は `DEP_AUTO_UNBLOCK_ENABLED` のみ |
| 2.1 | `dr_unblock_sweep` の `gh issue list --label auto-dev --label blocked --state open` クエリ + AT-i regression 防止 assertion |
| 2.2 | **round=2 で解消**: `--search "-label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\" sort:created-asc"` + AT-i |
| 2.3 | `_dispatcher_run` 冒頭の `dr_unblock_sweep || true` 配置（line 10316） |
| 3.1 | `dr_unblock_resolve_one_issue` 全件 resolved 分岐 + AT-a |
| 3.2 | `dr_unblock_post_unblocked_comment` + AT-a |
| 3.3 | 自動解除コメント本文に「依存解決時の自動スイープが…自動で除去しました」相当の文面 |
| 3.4 | ラベル除去失敗時の早期 return + AT-g |
| 4.1 | `unresolved_csv` 集計 + AT-b |
| 4.2 | 未知 verdict の `*)` 分岐 → unresolved 扱い + AT-b |
| 4.3 | `dr_unblock_*` はエスカレーションコメントを投稿しない（領分分離） |
| 5.1 | `dr_extract_deps` 空時の早期 return + AT-d |
| 5.2 | `dr_unblock_post_orphan_marker_comment` + AT-d |
| 5.3 | `dr_unblock_has_orphan_marker` 既存マーカー grep + AT-e |
| 5.4 | `DR_UNBLOCK_MARKER_ORPHAN='<!-- idd-claude:dep-unblock-orphan-marker:v1 -->'` |
| 6.1 | `gh issue list` の AND クエリで unblock 後は次 tick の候補から自然と外れる + AT-f |
| 6.2 | 解除条件未充足分岐で write API を呼ばない + AT-b/AT-e |
| 6.3 | 評価分岐は read API のみ |
| 7.1 | `verdict=unblock_cleared` ログ 1 行 + AT-a |
| 7.2 | `verdict=unblock_orphan_marker` / `unblock_orphan_notified` ログ + AT-d/AT-e |
| 7.3 | `verdict=unblock_keep` ログ + AT-b |
| 7.4 | `dr_warn` を gh API 失敗時に出力 + AT-g |
| 8.1 | `dr_format_unresolved_comment` の gate ON 分岐 + AT-h |
| 8.2 | gate OFF 分岐 + AT-h |
| 9.1 | 変更ファイルは `local-watcher/bin/issue-watcher.sh` + 同階層 test + README + spec のみ。`repo-template/**` / `.claude/` 配下に変更なし（`diff -r` 空を確認） |
| 9.2 | README.md にラベル状態遷移表 / オプション機能一覧 / 専用節 `Dependency Auto-Unblock Sweep (#346)` を反映 |
| NFR 1.1 | gate OFF 時 sweep 冒頭 if で gh API ゼロ呼び出し + AT-c |
| NFR 1.2 | `dr_*` 既存関数群 signature 不変 |
| NFR 2.1 | gate OFF or 対象ゼロ件で追加 API ゼロ + 補助テスト |
| NFR 2.2 | 1 Issue あたり API 呼び出しを上限内に抑制 |
| NFR 3.1 | `dr_resolve_one` の `api error` → unresolved 扱い + AT-b |
| NFR 3.2 | ラベル除去失敗時はコメント投稿せず skip + AT-g |
| NFR 4.1 | 構造化ログ `dr: issue=#N ... verdict=...` 形式 |
| NFR 4.2 | 自動解除コメントに `DR_UNBLOCK_MARKER_CLEARED` + 「watcher による自動解除」相当の文面 |
| NFR 5.1 | 連続 2 回スイープでも累積なし + AT-f |

### テスト・静的解析結果（reviewer 再実行）

- `bash local-watcher/test/dr_unblock_sweep_test.sh` → **PASS: 56, FAIL: 0**（AT-i 追加で round=1 比 +5）
- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/dr_unblock_sweep_test.sh` → 警告ゼロ（exit 0）
- `diff -r .claude/agents repo-template/.claude/agents` → 差分なし（同期維持）
- `diff -r .claude/rules repo-template/.claude/rules` → 差分なし（同期維持）

## Findings

なし

## Summary

Round=1 で指摘した Req 2.2 関連の 2 件の Finding（AC 未カバー + missing test）はいずれも round=2 で解消済み。`dr_unblock_sweep` の `gh issue list --search` 引数に `-label:"$LABEL_FAILED" -label:"$LABEL_NEEDS_DECISIONS"` 除外が追加され、対応する AT-i テストケース（5 assertions、claude-failed / needs-decisions 除外と既存 AND クエリ regression 防止）も追加された。reviewer 再実行で 56/56 PASS、shellcheck 警告ゼロ、root↔repo-template 同期維持を確認。新規 finding なし。

RESULT: approve
