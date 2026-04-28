# Implementation Notes — #40 Design Review Release Processor

## 実装サマリ

Issue #40 / 設計 PR #43（Architect 設計）に基づく Developer 実装。tasks.md の番号順
（1.1〜1.7 → 2.1 → 2.2 → 3.1 → 3.2）で消化した。タスク 3.3（dogfooding E2E）は
人間判断に委ねるためスキップ。

### 追加・変更したコンポーネント

| ファイル | 追加 / 変更 | 概要 |
|---|---|---|
| `local-watcher/bin/issue-watcher.sh` | +280 行 / -0 行 | Config ブロックに env 4 個（`DESIGN_REVIEW_RELEASE_ENABLED` / `_MAX_ISSUES` / `_HEAD_PATTERN` / `DRR_GH_TIMEOUT`）追加。`drr_log` / `drr_warn` / `drr_error` ロガー、`drr_already_processed` / `drr_find_merged_design_pr` / `drr_remove_label_and_comment` ヘルパー、エントリ関数 `process_design_review_release` を追加。既存 `process_pr_iteration` 呼び出し直後に `process_design_review_release` 呼び出しを追加。 |
| `repo-template/.claude/agents/project-manager.md` | +2 行 / -0 行 | design-review モードの Issue コメントテンプレートに、watcher 自動除去時は手動除去不要である旨の注記を追加。既存の手動除去案内行は残す。 |
| `README.md` | +132 行 / -1 行 | Phase A / Re-check / PR Iteration 節と同構造で「Design Review Release Processor (#40)」節を追加。機能概要・対象 Issue 判定・挙動表・環境変数表・既存手動運用との並存・ステータスコメントテンプレート・Migration Note を網羅。既存「設計 PR ゲート（2 PR フロー）」節フェーズ 2 に自動除去案内を追記。 |

### コミット履歴

```
feat(watcher): add Design Review Release Processor (#40)
docs(claude): note auto-removal of awaiting-design-review in PjM template
docs(readme): add Design Review Release Processor section (#40)
fix(watcher): correct jq any() syntax in drr_already_processed (#40)
```

`fix(watcher):` は Task 3.2 の dry-run スモークテストで発見した jq filter のバグ
修正。詳細は「実装上の判断」を参照。

---

## 受入基準達成確認（Requirements Traceability）

requirements.md の全 numeric ID と、それを担保するコード箇所 / 検証手段の対応表。

| Req ID | 担保箇所 | 検証 |
|---|---|---|
| 1.1 | `process_design_review_release()` 先頭の opt-in gate（issue-watcher.sh:1257-1259） | smoke test 1（ENABLED=false で stdout/stderr ともに空） |
| 1.2 | Config ブロック `DESIGN_REVIEW_RELEASE_ENABLED="${DESIGN_REVIEW_RELEASE_ENABLED:-false}"`（issue-watcher.sh:111） | grep で確認 |
| 1.3 | 既存 `process_pr_iteration ||` 行直後に `process_design_review_release ||` を配置（issue-watcher.sh:1385）。Issue 処理ループは issue-watcher.sh:1665 付近で、その前にある | grep で位置を確認 |
| 1.4 | opt-in gate + 既存コードパス未改変（diff の +280/-0 で確認） | git diff で確認 |
| 1.5 | 既存 `flock -n 200` 取得後の Processor 直列ブロックに同居（追加 lock なし） | issue-watcher.sh のフロー目視 |
| 2.1 | `gh issue list --search "label:\"$LABEL_AWAITING_DESIGN\""` の server-side filter（issue-watcher.sh:1268-1273） | smoke test (issue list filter) Test 1 |
| 2.2 | `drr_find_merged_design_pr()` の `gh pr list --search "is:pr is:merged claude/issue-${issue_number}-design- in:head"` | smoke test (jq filter) Test A |
| 2.3 | jq `select(.headRefName | test($pattern))`（issue-watcher.sh:1191-1196） | smoke test Test B（pattern mismatch を除外） |
| 2.4 | `--state merged` + jq `[...] | sort | last`（複数件マッチ時の最大番号採用） | smoke test Test D |
| 2.5 | `gh pr list` が 0 件 → jq filter が空文字 → caller 側で `kept` 扱い（issue-watcher.sh:1357-1360） | smoke test Test E + コードレビュー |
| 2.6 | 同上（merged 0 件は server-side で除外、結果空配列なら kept） | 同上 |
| 2.7 | `gh issue list --search "... -label:\"$LABEL_FAILED\" -label:\"$LABEL_NEEDS_DECISIONS\""` + jq fail-safe | smoke test (issue list filter) Test 2, 3 |
| 3.1 | `drr_remove_label_and_comment()` の `gh issue edit --remove-label`（issue-watcher.sh:1213-1218） | コードレビュー |
| 3.2 | 同関数のラベル除去成功時のみ `gh issue comment` 呼び出し（issue-watcher.sh:1239-1244） | コードレビュー |
| 3.3 | コメント本文テンプレートに `設計 PR #${merged_pr_number} が merged` と `次回 cron tick で Developer が **impl-resume モード**で自動起動` を含む（issue-watcher.sh:1222-1235） | grep で本文確認 |
| 3.4 | ラベル除去失敗時は `drr_warn` + `return 1`、コメント投稿は呼ばない（issue-watcher.sh:1217-1219） | コードレビュー |
| 3.5 | コメント投稿失敗時は `drr_warn` + `return 1`（後続 Issue は continue で処理継続）（issue-watcher.sh:1245-1247） | コードレビュー |
| 3.6 | 関数定義に `git push` / `git commit` / `git checkout` / `gh pr edit` / `gh pr comment` / `gh pr close` / `gh issue close` が一切無い（grep で確認） | コードレビュー（grep で確認済み） |
| 4.1 | server-side filter `label:"awaiting-design-review"` 必須（手動除去後の Issue は候補に上がらない） | smoke test (issue list filter) Test 4 |
| 4.2 | `drr_already_processed()` で hidden marker 検出 → caller 側で skip（issue-watcher.sh:1330-1334） | smoke test (marker) Test 2, 4 |
| 4.3 | コメント本文末尾に `<!-- idd-claude:design-review-release issue=<N> pr=<P> -->` を埋め込み（issue-watcher.sh:1234） | grep で確認 |
| 4.4 | per-Issue ループ内で `processed_numbers` 配列で重複処理ガード（issue-watcher.sh:1313-1320） + `gh issue list` の結果は元々一意 | コードレビュー |
| 4.5 | server-side filter `label:"awaiting-design-review"` 必須（4.1 と同根） | smoke test (issue list filter) Test 4 |
| 5.1 | Config ブロック `DESIGN_REVIEW_RELEASE_MAX_ISSUES="${DESIGN_REVIEW_RELEASE_MAX_ISSUES:-10}"` | grep で確認 |
| 5.2 | `process_design_review_release()` の `target_count` truncate と `overflow` ログ（issue-watcher.sh:1290-1296） | smoke test (functional Test 2 のサマリログ確認) |
| 5.3 | per-Issue API call 数: `drr_already_processed` 1 + `drr_find_merged_design_pr` 1 + `gh issue edit` 1 + `gh issue comment` 1 = 計 4 call（5 以内） | コードレビュー（gh 呼び出し箇所のカウント） |
| 5.4 | 全 `gh` 呼び出しを `timeout "$DRR_GH_TIMEOUT"` でラップ（issue-watcher.sh:1151, 1177, 1213, 1241, 1268） | grep で確認 |
| 5.5 | timeout / API エラー時に `drr_warn` + `continue`（per-Issue ループ）/ `return 0`（候補列挙失敗時） | コードレビュー |
| 6.1 | サイクル開始時に対象候補 / 処理対象 / overflow をログ（issue-watcher.sh:1290-1296） | コードレビュー |
| 6.2 | 各 Issue ごとに `Issue #N: merged-design-pr=#P, action=...` をログ（issue-watcher.sh:1357, 1369, 1372） | コードレビュー |
| 6.3 | サイクル終了時に `サマリ: removed=N, kept=N, skip=N, fail=N, overflow=N`（issue-watcher.sh:1378） | コードレビュー |
| 6.4 | `drr_log` / `drr_warn` / `drr_error` の prefix が `design-review-release:` | grep で確認 |
| 6.5 | `[$(date '+%F %T')]` 書式（既存 mq_log と同形） | grep で確認 |
| 6.6 | mkdir 追加なし、stdout/stderr のみ（cron リダイレクトで `LOG_DIR` に流れる） | コードレビュー |
| 6.7 | `drr_warn` / `drr_error` は `>&2`、`drr_log` は stdout | grep で確認 |
| 7.1 | 既存 env var の意味とデフォルト未変更（diff +280/-0、Config ブロックは追加のみ） | git diff で確認 |
| 7.2 | 既存ラベル定数（`LABEL_AWAITING_DESIGN` / `LABEL_FAILED` / `LABEL_NEEDS_DECISIONS`）を再利用、新規ラベル無し | git diff で確認 |
| 7.3 | `LOCK_FILE` / `LOG_DIR` / `exit` 変更なし | git diff で確認 |
| 7.4 | cron 登録文字列（`$HOME/bin/issue-watcher.sh`）は不変、env 1 個追加のみで opt-in 可能 | コードレビュー（README にも記載） |
| 7.5 | `DESIGN_REVIEW_RELEASE_ENABLED=false` で完全に従来挙動（1.1 と同根） | smoke test 1 |
| 7.6 | `drr_remove_label_and_comment` で `--add-label` 系操作を一切呼ばない | コードレビュー |
| 8.1 | README.md 行 910〜 に新規節「Design Review Release Processor (#40)」を追加 | git diff で確認 |
| 8.2 | README.md 環境変数表に 3 行（ENABLED / MAX_ISSUES / HEAD_PATTERN） + DRR_GH_TIMEOUT 補足 | git diff で確認 |
| 8.3 | README.md「Migration Note」節に env / ラベル / lock / exit code 不変を明記 | git diff で確認 |
| 8.4 | `repo-template/.claude/agents/project-manager.md` design-review モードに自動除去注記行を追加 | git diff で確認 |
| 8.5 | README.md「設計 PR ゲート（2 PR フロー）」フェーズ 2 に自動除去案内を追記 | git diff で確認 |
| NFR 1.1 | per-Issue API 呼び出し ≤ 4 call、各 timeout 60s。候補 0〜3 件で 30 秒以内（実機未計測、設計判断） | 実機 dogfood で要確認（impl-notes 記載のみ） |
| NFR 1.2 | 上限 10 件 × 4 call = 40 call、API レイテンシ < 500ms 仮定で 20s ほど。60 秒以内に収まる設計（実機未計測） | 同上 |
| NFR 2.1 | `drr_remove_label_and_comment` のスコープに `git push` / `git commit` / `gh pr edit` / `gh pr close` / `gh issue close` 一切無し | grep で確認 |
| NFR 2.2 | `drr_find_merged_design_pr` API エラー時は `return 1` → caller 側で skip / 次回再試行 | コードレビュー |
| NFR 2.3 | drr_* 関数群に `git push` 一切無し | grep で確認 |
| NFR 3.1 | `design-review-release:` prefix で grep 集計可能 | grep で確認 |
| NFR 3.2 | `merge-queue:` / `merge-queue-recheck:` / `pr-iteration:` と被らない | grep で確認 |

---

## 静的解析結果

### shellcheck

```
$ shellcheck local-watcher/bin/issue-watcher.sh

In local-watcher/bin/issue-watcher.sh line 855:
    found=$(ls -d "${REPO_DIR}/docs/specs/${issue_number}-"* 2>/dev/null | head -1 || true)
            ^-- SC2012 (info): Use find instead of ls to better handle non-alphanumeric filenames.


In local-watcher/bin/issue-watcher.sh line 1978:
  EXISTING_SPEC_DIR=$(ls -d "$REPO_DIR/docs/specs/${NUMBER}-"* 2>/dev/null | head -1 || true)
                      ^-- SC2012 (info): Use find instead of ls to better handle non-alphanumeric filenames.

For more information:
  https://www.shellcheck.net/wiki/SC2012 -- Use find instead of ls to better ...
```

両方とも **本 PR 導入前から存在する pre-existing info 警告**であり、Design Review Release
Processor の追加コードは新規警告ゼロ（既存と同レベル）。

### bash -n

```
$ bash -n local-watcher/bin/issue-watcher.sh
$ echo $?
0
```

構文エラーなし。

---

## スモークテスト実行ログ

### Test 1: opt-in gate（DESIGN_REVIEW_RELEASE_ENABLED=false）

cron-like 最小 PATH で関数を呼び出し、stdout/stderr に何も出力されないことを確認。

```
--- Test 1: ENABLED=false (default) ---
PASS: no output, no drr_log emitted

--- Test 2: ENABLED=true (smoke, mocked) ---
PASS: drr_log prefix present in output
  output: [2026-04-28 10:36:35] design-review-release: サイクル開始 (max_issues=10)

ALL SMOKE TESTS PASSED
```

### Test 2: drr_find_merged_design_pr の jq filter dry-run（8 ケース）

```
Test A: matched PR (head pattern + Refs match)        → expected 42, got 42, PASS
Test B: head pattern mismatch                          → expected empty, got '', PASS
Test C: head pattern match but Refs different number   → expected empty, got '', PASS
Test D: multiple matched PRs, max number returned     → expected 99, got 99, PASS
Test E: empty array                                    → expected empty, got '', PASS
Test F: Refs case variations (Ref/ref/refs)            → all 3 variations match, PASS
Test G: Refs #40 followed by digits (e.g., #401)       → expected empty, got '', PASS (no false-positive)
Test H: body is null (jq // safe-default)             → expected empty, got '', PASS

ALL JQ FILTER TESTS PASSED
```

### Test 3: drr_already_processed の marker 検出 dry-run（7 ケース）

```
Test 1: no marker                                      → expected false, got false, PASS
Test 2: marker present (matching issue=40)             → expected true, got true, PASS
Test 3: marker for different issue                     → expected false, got false, PASS
Test 4: multiple comments, one has marker              → expected true, got true, PASS
Test 5: empty comments array                           → expected false, got false, PASS
Test 6: missing comments field                         → expected false, got false, PASS
Test 7: comment.body is null                           → expected true, got true, PASS

ALL MARKER TESTS PASSED
```

### Test 4: process_design_review_release の client-side filter dry-run（6 ケース）

```
Test 1: 1 candidate Issue                              → expected 1 issue, got 1, PASS
Test 2: candidate with claude-failed → excluded        → expected 0, got 0, PASS
Test 3: candidate with needs-decisions → excluded      → expected 0, got 0, PASS
Test 4: Issue without awaiting-design-review (defensive) → expected 0, got 0, PASS
Test 5: Mixed (2 valid, 1 failed, 1 missing labels)    → expected [40,42], got [40,42], PASS
Test 6: empty input                                    → expected 0, got 0, PASS

ALL ISSUE LIST FILTER TESTS PASSED
```

### Test 5: cron-like 最小 PATH での依存解決

```
$ env -i HOME=$HOME PATH=/usr/bin:/bin:/usr/local/bin:$HOME/.local/bin bash -c 'for cmd in gh jq claude git flock timeout; do which "$cmd" || echo "MISSING: $cmd"; done'
/usr/bin/gh
/usr/bin/jq
/home/hitoshi/.local/bin/claude
/usr/bin/git
/usr/bin/flock
/usr/bin/timeout
```

新規依存コマンドの追加なし（既存 `gh` / `jq` / `claude` / `git` / `flock` / `timeout`
のみで動作）。

### NFR 1.1 / 1.2 性能計測について

性能要件（候補 0〜3 件で 30 秒以内、上限 10 件で 60 秒以内）は実機 dogfood 環境で
GitHub API レスポンスを伴う計測が必要なため、本 PR では計測していない。
設計判断としては **per-Issue 4 API call × API レイテンシ < 500ms × 10 件 = 20 秒程度**
で要件を満たす想定。実機計測は dogfood 運用に委ねる。

---

## 実装上の判断

### 1. jq `any()` の文法ミス → fix commit で修正

設計フェーズの design.md（行 484）には pseudocode として:
```
any(. // ""; test($re))
```
と記載されていたが、実機テストすると `any` の **2 引数形式は最初に generator を取り、
condition を引数に取る**ため、`map(.body)` の結果（配列）を generator として展開し、
配列全体を文字列化しようとして「array cannot be matched」エラーが発生した。

修正: `map(.body // "") | any(test($re))` に変更（**1 引数形式の `any`** で各要素に対して
test() を直接適用）。これは design.md / pseudocode の意図（既処理判定）と等価で、
動作も意図通り。pseudocode の小さな写経ミスとして `fix(watcher):` で別 commit にした。

design.md / requirements.md の意図そのものに矛盾は無いため、設計の書き換えは行っていない
（Developer は design.md を書き換えない原則を遵守）。

### 2. `Refs` regex の境界条件

`(Refs|refs|Ref|ref) #${issue_number}([^0-9]|$)` で、`Refs #40` は match するが
`Refs #401` は match しない（`([^0-9]|$)` で末尾境界を強制）。これにより同一 repo の
別 Issue 番号への偽陽性を防ぐ。設計 PR が `Refs #40, #41` のように複数 Issue を
参照することは想定外（PjM テンプレートは 1 PR = 1 Issue）。

### 3. 既処理判定の per-Issue API call

`drr_already_processed` を `gh issue view --json comments` で 1 call 追加することで、
1 Issue あたりの API 呼び出しが PR 検出 1 + 既処理判定 1 + ラベル除去 1 + コメント投稿 1 =
**計 4 call**（Req 5.3 の 5 call 以内に収まる）。design.md の Testing Strategy に記載の
試算と一致。

### 4. 実機性能計測の保留

NFR 1.1 / 1.2 の wall clock 計測は dogfood 環境（self-hosting repo に test Issue を
立てて watcher を回す）で行う性質のため、本 PR の Developer フェーズではスキップ。
Reviewer / 人間レビュー時にこの判断を確認してもらう想定。tasks.md でも 3.3 が optional
（`- [ ]*`）になっている。

### 5. README cross-link の anchor

「設計 PR ゲート」フェーズ 2 から「Design Review Release Processor (#40)」節への
markdown リンク `[..](#design-review-release-processor-40)` を試したが、GitHub の
markdown anchor 生成は `(#40)` を含む見出しに対する慣習が一意に定まらない（テスト
未実施で確証が取れない）ため、安全策として **prose のみで参照**（plain text で
"Design Review Release Processor (#40)" と記載）に切り替えた。読者が文書内検索で
辿れる構造にしてある。

### 6. self-hosting (dogfooding) への影響

このリポジトリ自身も watcher の対象 repo として動作しているため、本 PR merge 後に
`install.sh --local` を再実行すると `~/bin/issue-watcher.sh` が更新される。
現状の cron に `DESIGN_REVIEW_RELEASE_ENABLED=true` を付け足すと、本リポジトリの
`awaiting-design-review` 付き既存 Issue（あれば）が次サイクルで自動処理される。
**運用判断**として、本 PR merge 直後は `DESIGN_REVIEW_RELEASE_ENABLED=true` を
opt-in しない（人間レビュー後に opt-in）と安全。

---

## 設計 / 要件との整合性メモ

- design.md / tasks.md / requirements.md は**書き換えていない**（PR 本文「確認事項」で
  言及するべき矛盾は無し）
- design.md の Testing Strategy（Unit Tests 3-5 項目）に挙がっていた dry-run harness
  は本 impl-notes に集約済み（Test 1〜5 が該当）
- design.md の Migration Strategy「opt-in 手順」に記載の cron 例と、README の cron 例は
  一致している（DESIGN_REVIEW_RELEASE_ENABLED=true の追加のみ）
- requirements.md の「Out of Scope」は本実装でもすべて遵守:
  - 設計 PR が close（merge せず却下）された場合の処理 → 実装していない
  - 設計 PR 以外の PR との連動 → head pattern で除外
  - リンクされた PR が複数ある場合の優先度 → 「最大番号 = 最新」を採用（要件範囲内）
  - ラベル除去後の Developer 即時起動 → 次回 cron tick の通常 pickup フローに委ねる
  - GitHub Actions 版（`.github/workflows/issue-to-pr.yml`）への組み込み → していない

---

## 確認事項（PR 本文に記載すべき項目）

1. **NFR 1.1 / 1.2 の実機計測は未実施**: 設計 / 試算ベースで「収まる想定」と判断。
   dogfood 運用で実測する場合は、`time` コマンドで `process_design_review_release`
   実行時間を計測する手順を README の Test plan セクションに追加可能。
2. **README から `Design Review Release Processor (#40)` 節への内部リンクは plain text**:
   markdown anchor の生成規則がテスト未確認のため、リンクを使わずに文書内検索で
   辿る構造にしてある。レビュワー判断で正しい anchor 形式に書き換えてもよい。
3. **design.md の jq pseudocode（行 484）の写経ミス**: 本 impl で実機検証して `fix(watcher):`
   コミットで補正した。Architect への差し戻しは不要（実装上の細部修正、設計の意図は変えていない）
   と判断したが、レビュワーがより厳密な扱いを希望する場合は別途相談。
4. **dogfood opt-in の安全策**: 本 PR merge 直後は `DESIGN_REVIEW_RELEASE_ENABLED=true` を
   付けず、Reviewer / 人間レビューを完了させてから opt-in する運用を README にも記載。
5. **design.md PR への内部 anchor リンクの不在**: 既存「PR Iteration Processor」節と
   同様に、各 Processor 節は parallel 構造で書かれているが cross-link はしていない
   慣習を踏襲。

以上、すべての受入基準に対応する実装と検証が完了している（NFR 1.1 / 1.2 の実機計測のみ
dogfood 運用に委ねる）。
