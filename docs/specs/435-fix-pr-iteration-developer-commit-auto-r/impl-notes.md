# 実装ノート（Issue #435）

## ステップ 0: no-progress 判定の切り分け結論

**結論: 現行コードでは auto-recovery commit round は既に「進捗あり」として streak リセットされる（成立）。よって Requirement 2.5 を採用し、コード挙動は変更せず回帰テストで不変条件を固定する。**

根拠（`local-watcher/bin/modules/pr-iteration.sh` の `pi_run_iteration` round ループ）:

- `before_sha` は round 開始時（Claude 実行前）に採取される（採取行は `pi_sha_file` 1 行目、変更前 1286–1287 行付近）。
- `after_sha` は `pi_auto_commit_and_push`（auto-recovery commit）の **後** に採取される（変更前 1422–1424 行、subshell 内、`pi_sha_file` 2 行目）。コメントにも「自動回復まで含む round 終了時点の HEAD を記録」と明記。
- `commit_pushed=true` ⇔ `before_sha != after_sha`（変更前 1491 行）。auto-recovery commit が HEAD を進めれば `after_sha != before_sha` → `commit_pushed=true`。
- `commit_pushed=true → new_streak=0`（変更前 1496–1500 行）。

したがって、auto-recovery commit が発生した round では HEAD が前進し `commit_pushed=true` → `new_streak=0` にリセットされる。Developer 自身の commit と auto-recovery commit のどちらでも HEAD 前進という観測点は同一で、両者は同等に進捗ありとして扱われる（AC 2.3 の不変条件は現行コードで満たされている）。

不変条件（採用方針 R2.5）:
- HEAD 変化（before≠after） → 進捗あり → streak=0（AC 2.1）
- HEAD 不変（before==after） → 進捗なし → streak+1（AC 2.2）
- auto-recovery commit 経由でも before≠after → 進捗あり → streak=0（AC 2.3）

## 実装方針

- **R2.5 採用**: 挙動は変えず、inline されていた SHA 比較 / streak 更新ロジックを純粋関数 `pi_round_commit_pushed` / `pi_next_no_progress_streak` に切り出し（behavior-preserving refactor）、回帰テストで不変条件を固定。`prev_streak` は常に `pi_read_no_progress_streak`（`${streak:-0}` で必ず数値）由来のため、抽出後も全到達入力で挙動等価。
- **R1 / R3（docs 主軸）**: `.claude/agents/developer.md` に新節「PR Iteration / impl-resume round 内 self-commit 規律（Issue #435）」を impl-resume 節の直後に追記。既存節の意味は変更せず、`git reset` / `git rebase` 禁止規律と矛盾しない位置に配置。repo-template 側へ `cp` で byte 一致同期。

## 変更ファイルと AC 対応

| ファイル | 変更内容 | 対応 AC |
|---|---|---|
| `.claude/agents/developer.md` | round 内 self-commit 規律の新節を追記 | R1.1〜1.5 / R3.3 |
| `repo-template/.claude/agents/developer.md` | 上記を byte 一致で同期 | R3.1 / R3.2 |
| `local-watcher/bin/modules/pr-iteration.sh` | `pi_round_commit_pushed` / `pi_next_no_progress_streak` 純粋関数を追加し inline を置換（挙動不変） | R2.5 / NFR 2.1 |
| `local-watcher/test/pi_no_progress_invariant_test.sh` | 不変条件の回帰テスト（21 ケース） | R2.1 / R2.2 / R2.3 / NFR 2.1 |

## AC Traceability（テスト / 検証担保）

| AC | 担保手段 |
|---|---|
| R1.1〜1.5 | `developer.md` 新節「PR Iteration / impl-resume round 内 self-commit 規律」の各 bullet（self-commit 責務 / Conventional Commits / auto-recovery 常用禁止 / 既存 commit 温存規律との非矛盾） |
| R2.1 | `pi_no_progress_invariant_test.sh`: HEAD 変化あり → commit_pushed=true / streak=0 |
| R2.2 | 同: HEAD 不変 → commit_pushed=false / streak+1 |
| R2.3 | 同: auto-recovery commit 経由（before≠after）→ commit_pushed=true / streak=0 |
| R2.4 | 本 impl-notes ステップ 0 の切り分け記録（成立 + 根拠行番号） |
| R2.5 | コード挙動不変（純粋関数抽出のみ）+ 上記回帰テストで不変条件固定 |
| R2.6 | 不成立ではないため非適用（切り分けで AC 2.1〜2.3 充足を確認） |
| R3.1 / R3.2 | `diff -r .claude/agents repo-template/.claude/agents` が空 |
| R3.3 | 既存節（impl-resume / per-task / 出力契約等）は無改変、新節を追加のみ |
| NFR 1.1〜1.4 | env var 名 / hidden marker キー / auto-recovery commit 文字列 / exit code・ログ書式は無改変 |
| NFR 2.1 | `extract_function` 隔離抽出による回帰テスト提供 |
| NFR 2.2 | 既存 pi_* テスト 5 種全 pass を確認 |
| NFR 3.1 | no-progress ログ出力（`no-progress-streak=` 行）は無改変 |

## 実行した検証コマンドと結果

- `bash -n local-watcher/bin/modules/pr-iteration.sh` / 新規テスト → OK
- `shellcheck local-watcher/bin/modules/pr-iteration.sh local-watcher/test/pi_no_progress_invariant_test.sh` → 警告ゼロ
- `bash local-watcher/test/pi_no_progress_invariant_test.sh` → **PASS: 21, FAIL: 0**
- 既存 pi_* テスト（`pi_classify_round_outcome_test` / `pi_detect_quota_soft_fail_test` / `pi_general_filter_excessive_test` / `pi_general_filter_self_test` / `pi_max_rounds_kind_test`）→ 全 PASS（`pi_classify_round_outcome_test` は 24 ケース全 pass）
- `diff -r .claude/agents repo-template/.claude/agents` → 空（差分なし）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（差分なし）

## 確認事項

- なし（要件は条件付き AC で完結。切り分けで R2.5 経路が確定し、推測で埋めた箇所はない）。

STATUS: complete
