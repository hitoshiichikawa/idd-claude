# 実装ノート: Issue #104

## 概要

Issue #104 の 3 つの bug（quota 枯渇時の虚偽成功）を修正した。実装の詳細・
テスト・後方互換性に関する所見を記載する。

## 実装したタスク

### Bug 1: 現行スキーマの quota 検出（Req 1.1〜1.4, 2.1〜2.2）

`local-watcher/bin/issue-watcher.sh` の `qa_detect_rate_limit()` を書き換え、
3 種の検出経路を 1 つの jq filter に統合した:

| detection_path | スキーマ判定式 |
|---|---|
| `rate_limit_event_v2` | `type=="rate_limit_event"` かつ `rate_limit_info.status=="rejected"` |
| `rate_limit_event_v1` | `type=="rate_limit_event"` かつ `status=="exceeded"`（旧スキーマ） |
| `synthetic_429_result` | `type=="result"` かつ `is_error==true` かつ `api_error_status==429` |

reset 時刻フィールド探索順:

1. ネスト位置: `.rate_limit_info.resetsAt / .resets_at / .reset_at`（現行スキーマ / Req 1.3）
2. top-level: `.resetsAt / .reset_at / .resets_at`（旧スキーマ / Req 2.2）

出力フォーマットを `<detection_path>\t<epoch_or_empty>` の TSV 1 検出 1 行に変更。
これによって NFR 2.1（どの検出経路で発火したか識別可能）を満たす。

### Bug 2: synthetic 429 result 行の検出（Req 3.1〜3.4）

Bug 1 と同じ jq filter で同居検出する。`qa_run_claude_stage()` 側のロジックを
更新し、検出 TSV から「epoch を持つ最新検出」を優先採用する形に変更:

- epoch あり検出が 1 件以上 → exit 99 + reset_file 永続化（既存契約と等価）
- 検出はあるが epoch ゼロ → claude_rc 透過 + warn ログ（Req 1.4 / Req 3.2 の fallback）
- 検出ゼロ → claude_rc 透過

### Bug 3: Stage C の PR 実在 verify（Req 4.1〜4.4）

`run_impl_pipeline()` の Stage C 完了処理 (`case 0)`) に `gh pr view --head "$BRANCH"`
verify を追加。PR URL が空 / gh が非 0 のいずれの場合も
`mark_issue_failed "stageC-pr-missing" ...` で claude-failed 化する。

### 副次修正: PIPESTATUS preservation（latent bug 修正）

`qa_run_claude_stage()` の pipeline `... | tee | qa_detect_rate_limit ... || true`
において `|| true` が PIPESTATUS を 0 で上書きしてしまう挙動が判明。
`set +e/-e` で囲って PIPESTATUS を即座に配列コピーする形に修正した。

これは Issue #66 由来の latent bug であり、quota-aware 経路で claude が非 0 終了
した場合に常に rc=0 として扱われていた。Issue #104 のスコープ拡張として併せて修正。
影響: Issue #66 の opt-in 経路 (QUOTA_AWARE_ENABLED=true) でのみ発現する欠陥。

## 受入基準カバレッジ

| Req ID | 担保テスト | テストファイル |
|---|---|---|
| 1.1 | `v2-rate-limit-event-rejected (all)` / `v2-numeric-epoch` / wrapper 経由 `v2-rate-limit-event-rejected` | `qa_detect_rate_limit_test.sh` / `qa_run_claude_stage_test.sh` |
| 1.2 | wrapper 経由 `v2-rate-limit-event-rejected (rc=99 + reset_file=epoch)` | `qa_run_claude_stage_test.sh` |
| 1.3 | `v2-rate-limit-event-rejected` / `v2-numeric-epoch`（ネスト位置 reset 抽出） | `qa_detect_rate_limit_test.sh` |
| 1.4 | `v2-no-reset` / wrapper 経由 `v2-no-reset (claude_rc 透過 / reset_file 空)` | 両方 |
| 2.1 | `v1-rate-limit-event-exceeded` / wrapper 経由 同じ | 両方 |
| 2.2 | `v1-reset-at-snake`（旧スキーマ snake_case 受理） | 両方 |
| 3.1 | `synthetic-429-result` (path + epoch) / wrapper 経由 (rc=99) | 両方 |
| 3.2 | `synthetic-429-no-reset` (path のみ epoch 空) / wrapper 経由 (claude_rc 透過 + warn) | 両方 |
| 3.3 | wrapper の `qa_warn "stage detected without reset ... path=..."` ログ出力（実装 / テストでは warn 文字列出力経路を確認） | 実装 review |
| 3.4 | `normal-success`（is_error:false / allowed のみ）→ 検出ゼロ + rc=0 | 両方 |
| 4.1 | `PR 実在あり: rc=0` | `stagec_pr_verify_test.sh` |
| 4.2 | `PR 不在 (空 URL): mark_issue_failed=stageC-pr-missing` | `stagec_pr_verify_test.sh` |
| 4.3 | `PR 実在あり: mark_issue_failed 未呼出` + 成功 echo | `stagec_pr_verify_test.sh` + 実装 review |
| 4.4 | `gh 失敗 (rc=1)` / `gh timeout (rc=124)` 両ケース | `stagec_pr_verify_test.sh` |
| 5.1 | fixture `v2-rate-limit-event-rejected.jsonl` 配置済 | `local-watcher/test/fixtures/qa_detect_rate_limit/` |
| 5.2 | fixture `v1-rate-limit-event-exceeded.jsonl` 配置済 | 同上 |
| 5.3 | fixture `synthetic-429-result.jsonl` 配置済 | 同上 |
| 5.4 | 上記 3 fixture ＋ wrapper 経由 (rc=99) すべて緑 | `qa_detect_rate_limit_test.sh` / `qa_run_claude_stage_test.sh` |
| 5.5 | 既存 `parse_review_result_test.sh` (19 PASS) | `parse_review_result_test.sh` |
| NFR 1.1 | `opt-out v2 input rc=0` / `opt-out reset_file untouched` / `opt-out preserves claude rc=7` | `qa_run_claude_stage_test.sh` |
| NFR 1.2 | `normal-success with claude rc=2` (NFR 1.2 既存 rc 透過) + opt-out 透過 | `qa_run_claude_stage_test.sh` |
| NFR 2.1 | 実装の `qa_log "... path=${_path} reset_epoch=..."` で経路 + stage label を grep 可能 | 実装 review |
| NFR 2.2 | Stage C 失敗時 `qa_warn "stageC PR verify failed issue=#... branch=... verify_rc=..."` + Issue コメントで原因情報 | 実装 review |
| NFR 3.1 | 全テストはローカル `bash + jq` のみで完結（Claude API / GitHub API 不要、fake gh / fake claude を使用） | `*_test.sh` |

## 追加した fixture（local-watcher/test/fixtures/qa_detect_rate_limit/）

| ファイル | 用途 / 対応 Req |
|---|---|
| `v2-rate-limit-event-rejected.jsonl` | 現行 rate_limit_event + 後続 synthetic 429（rate_limit_info なし）の代表ケース / Req 5.1 |
| `v2-numeric-epoch.jsonl` | 現行 rate_limit_event + 数値型 epoch / Req 1.1, 1.3 |
| `v2-no-reset.jsonl` | 現行 rate_limit_event だが reset 欠落 / Req 1.4 |
| `v1-rate-limit-event-exceeded.jsonl` | 旧スキーマ単独ケース / Req 5.2 |
| `v1-reset-at-snake.jsonl` | 旧スキーマ snake_case reset_at / Req 2.2 |
| `synthetic-429-result.jsonl` | synthetic 429 + 同居 rate_limit_info / Req 5.3 |
| `synthetic-429-no-reset.jsonl` | synthetic 429 のみで reset 不在 / Req 3.2 |
| `normal-success.jsonl` | 通常成功 + allowed の rate_limit_event / Req 3.4 |
| `v2-rate-limit-malformed-line.jsonl` | malformed 1 行混入でも以後の検出を継続 / Req 5.4 / NFR resilience |

## 実行したテストコマンドと結果

```bash
$ bash local-watcher/test/qa_detect_rate_limit_test.sh
PASS: 10, FAIL: 0

$ bash local-watcher/test/qa_run_claude_stage_test.sh
PASS: 23, FAIL: 0

$ bash local-watcher/test/stagec_pr_verify_test.sh
PASS: 8, FAIL: 0

$ bash local-watcher/test/parse_review_result_test.sh
PASS: 19, FAIL: 0

$ shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh
（warning なし。info-level SC2012 / SC2317 のみ。すべて pre-existing で
 本 PR の変更行には新規発生なし）
```

## 後方互換性に関する所見

- `QUOTA_AWARE_ENABLED != "true"`（既定）では `qa_run_claude_stage` の opt-out 早期 return
  経路を保持。test 側で opt-out reset_file untouched / claude rc=7 透過を確認済（NFR 1.1）
- 旧スキーマ（top-level `status=="exceeded"`）も `rate_limit_event_v1` 経路で引き続き検出。
  reset フィールド名 `resetsAt` / `reset_at` / `resets_at` のいずれも従来どおり受理する
  （Req 2.2）
- exit code 契約（0 / 99 / その他）は変更なし。reset_file の中身も「empty または epoch 1 行」の
  契約を維持（呼び出し側の `cat "$_qa_reset_file_X"` は変更不要）
- `qa_detect_rate_limit` の出力フォーマットは TSV に変更したが、本関数は `qa_run_claude_stage`
  の内部からのみ呼ばれているため外部影響なし。reset_file 自体は引き続き epoch 1 行
- 環境変数名（`QUOTA_AWARE_ENABLED`, `REPO`, `BRANCH`, `LOG`, `NUMBER` 等）は不変
- ラベル名（`needs-quota-wait`, `claude-failed`）も不変

## 確認事項（Reviewer / 人間レビュー向け）

1. **PIPESTATUS preservation 修正のスコープ**: 本来は別 Issue 切り出しが妥当な
   latent bug 修正だが、Issue #104 のテストで露見したため併せて修正した。
   既存運用への影響は「quota-aware opt-in 時に claude 非 0 終了が正しく検出されるようになる」
   方向のみで、副作用なし
2. **Req 3.1 と Req 3.2 の解釈**: Req 3.1 は「synthetic 429 検出 → 終了コード 99」、
   Req 3.2 は「synthetic 429 検出 + reset 欠落 → 既存 fallback」。両者は「reset 時刻が
   取得できた時のみ exit 99、取れなければ既存フロー透過」と解釈し実装した。Stage C は
   PR verify が後段で false-success を捕捉するので、reset 欠落 synthetic 429 でも
   最終的に虚偽成功は出ない設計
3. **Bug 3 の PR 実在 verify は Stage C のみ**: 要件 Out of Scope のとおり Stage A/B には
   verify を入れていない。PIPESTATUS 修正により Stage A/B の claude 非 0 終了は通常の
   失敗パスに乗るため、Stage A/B の false-success リスクは（既存空成果物を除いて）解消した
4. **fixture の epoch 値**: `2026-05-15T05:00:00Z` → `1778821200`（GNU date で確認）。
   テスト assertion 値はこれにハードコード

## 派生タスク候補

- Stage A / Stage B の return code 0 + 空成果物パターンの verify 強化（要件 Out of Scope。
  本 Issue で PIPESTATUS bug を直したため、空成果物パターン以外は捕捉される）
- `qa_detect_rate_limit` のさらなるスキーマ追加（CLI バージョン更新時のリグレッション
  予防のため、定期的に fixture と filter を peer review する運用を README に追記する案）
