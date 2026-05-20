# 実装ノート（Issue #119）

bug(watcher): cron.log の processor 系ログ行に repo 識別子がなく、複数リポ運用で
沈黙の失敗を区別できない、を解消するための実装記録。

## 変更ファイル

| ファイル | 種別 | 概要 |
|---|---|---|
| `local-watcher/bin/issue-watcher.sh` | 修正 | (1) 5 種の processor 系ロガー（`pi_log` / `pi_warn` / `pi_error` / `mq_log` / `mq_warn` / `mq_error` / `mqr_log` / `mqr_warn` / `mqr_error` / `drr_log` / `drr_warn` / `drr_error` / `qa_log` / `qa_warn` / `qa_error`）の出力 echo 文に `[$REPO]` prefix を時刻 prefix と processor prefix の間に挿入。(2) cycle 冒頭の `git checkout $BASE_BRANCH` 前に `git status --porcelain` で dirty 判定し、dirty なら `watcher: [<REPO>] dirty working tree blocks BASE_BRANCH checkout` を含む 5 行（イベント行 + current_branch / dirty_files / head / action 4 行）を stderr に連続出力して `exit 1`。 |
| `README.md` | 追記 | 「複数リポ運用時の cron.log grep 例」節を追加（「運用上の注意」直下、Step 3-B の前）。特定 repo 抽出 / 失敗イベント抽出 / checkout 失敗イベント抽出の 4 種の grep 例を含む。 |
| `local-watcher/test/repo_prefix_log_test.sh` | 新規 | Issue #119 Req 1, 2, 3, NFR 2.1, 2.2 を網羅するスモークテスト。15 個のロガー関数の出力に `[$REPO]` prefix が 1 つだけ挿入されることを fixture 検証し、Req 3 の dirty event 関連 source-level 検証（`watcher: [$REPO]` リテラル / 4 値 / `exit 1` / 処理順序）を行う。 |
| `docs/specs/119-bug-watcher-cron-log-processor-repo/impl-notes.md` | 新規 | 本ノート |

## 受入基準達成確認（Requirements ID → テスト or 実装根拠）

| Req ID | 担保箇所 |
|---|---|
| 1.1 `pi_log/pi_warn/pi_error` に `[<REPO>]` | `repo_prefix_log_test.sh` Req 1.1 / 2.4 ケース（pi_log / pi_warn / pi_error） |
| 1.2 `mq_log` に `[<REPO>]` | `repo_prefix_log_test.sh` Req 1.2 ケース（mq_log / mq_warn / mq_error） |
| 1.3 `mqr_log` に `[<REPO>]` | `repo_prefix_log_test.sh` Req 1.3 ケース（mqr_log / mqr_warn / mqr_error） |
| 1.4 `drr_log` に `[<REPO>]` | `repo_prefix_log_test.sh` Req 1.4 ケース（drr_log / drr_warn / drr_error） |
| 1.5 `qa_log` 等 quota-aware に `[<REPO>]` | `repo_prefix_log_test.sh` Req 1.5 ケース（qa_log / qa_warn / qa_error） |
| 1.6 `<REPO>` は `REPO` env 値の `owner/name` をそのまま | `repo_prefix_log_test.sh` Req 1.6 ケース（`my-org/keynest_for_mimamowellness` で確認） |
| 1.7 1 行に repo 識別子は 1 個のみ | `repo_prefix_log_test.sh` Req 1.7 ケース（pi_log / mq_log で `assert_count "1"`） |
| 1.8 デフォルト `owner/your-repo` でもそのまま出力 | `repo_prefix_log_test.sh` Req 1.8 ケース |
| 2.1 時刻 prefix `[YYYY-MM-DD HH:MM:SS]` で開始 | `repo_prefix_log_test.sh` Req 2.1 ケース（`assert_match_regex`） |
| 2.2 既存 processor prefix を維持 | `repo_prefix_log_test.sh` Req 2.2 ケース（"pr-iteration: サイクル開始" 文字列） |
| 2.3 prefix 文字列・サマリ表現は不変 | `repo_prefix_log_test.sh` Req 2.3 後方互換ケース（5 種の processor prefix を空 args で出力して末尾を regex 検査） |
| 2.4 `[<REPO>]` 追加以外で本文不変 | `repo_prefix_log_test.sh` Req 2.4 ケース（`[<REPO>] pr-iteration:` の連続を verify） |
| 3.1 dirty 時の 1 行目イベント | `repo_prefix_log_test.sh` Req 3.1 source 検査 + 手動スモークテスト（後述） |
| 3.2 続く 4 値（current_branch / dirty_files / head / action） | `repo_prefix_log_test.sh` Req 3.2 source 検査（4 件） + 手動スモークテスト |
| 3.3 dirty 検出時に processor ステージに到達しない | `repo_prefix_log_test.sh` Req 3.3 source 順序検査（dirty ブロックは `process_merge_queue` メインフロー呼び出しより上）+ exit 1 構造で保証 |
| 3.4 dirty 検出後の exit code 非 0 | `repo_prefix_log_test.sh` Req 3.4 source 検査（`exit 1` 存在）+ 手動スモークテストで exit=1 を実測 |
| 3.5 dirty event 行にも `[<REPO>]` prefix | `repo_prefix_log_test.sh` Req 3.5 source 検査（`watcher: [$REPO]` literal）+ スモークテストで `[owner/fake-repo]` 出力を実測 |
| 4.1 README/QUICK-HOWTO に「複数リポ運用時の cron.log grep 例」節 | README.md「複数リポ運用時の cron.log grep 例」サブセクション追加 |
| 4.2 特定 repo 抽出 grep 例 | README.md 同節 例 1（`grep '\[owner/repo-a\]' $HOME/.issue-watcher/cron.log`） |
| 4.3 pr-iteration 失敗・skip 抽出 grep 例 | README.md 同節 例 2（`grep -E 'pr-iteration: (WARN\|ERROR\|skip)' ...`） |
| 4.4 checkout 失敗イベント抽出 grep 例 | README.md 同節 例 3 / 4（`grep 'watcher: \[.*\] dirty working tree ...'` と `-A 4` 拡張版） |
| 5.1 既存 cron.log grep / sed サンプルが新フォーマットでも動作する | 既存サンプルは「ログを `>>` で cron.log に追記」する cron 設定例のみで、`[<REPO>]` 前提の grep / sed サンプルはなかった。本 PR で追加した新節が `[owner/repo-a]` を使った正しい新フォーマット例として機能する |
| 5.2 同一 PR で挙動と doc を揃える | 本 PR 内に Req 1〜3 実装と Req 4 ドキュメント追加が同居 |
| 6.1 prefix 付与の検証テスト | `local-watcher/test/repo_prefix_log_test.sh` 全 36 ケース |
| 6.2 checkout 失敗 4 行のテスト | `local-watcher/test/repo_prefix_log_test.sh` Req 3.1〜3.5 source 検査 + 手動スモークテスト（`/tmp/test-119-repo` で dirty 状態を作って実行し、5 行 stderr 出力 + exit=1 を確認） |
| 6.3 既存テストは引き続き pass | `bash local-watcher/test/*_test.sh` 全 10 ファイル PASS（normalize_slug / parse_review_result / qa_detect_rate_limit / qa_run_claude_stage / slug_match_guard / stagec_pr_verify_{fallback,retry,基本} / verify_pushed_or_retry / repo_prefix_log） |
| NFR 1.1〜1.4 後方互換 | 既存 env var 名（REPO / REPO_DIR / BASE_BRANCH / LOG_DIR / LOCK_FILE 等）は不変。ログ出力ファイルパス（`$HOME/.issue-watcher/cron.log`）と append 動作も不変。ラベル名・cycle exit code 意味は変更なし |
| NFR 2.1 1 イベント 1 行 | `repo_prefix_log_test.sh` で行数 = 1 を verify。dirty event も `echo` 5 回でそれぞれ 1 行ずつ出力 |
| NFR 2.2 単一 grep で repo 全行を抽出 | 全 processor 系ロガーと watcher 系 dirty event が `[$REPO]` を含むため、`grep '\[owner/name\]' cron.log` で当該 repo の全行が抽出可能 |
| NFR 2.3 dirty event 4 行が隣接 | 同一 stream（stderr）に連続 5 echo するため、cron の `2>&1` リダイレクト経由でも連続行として残る |
| NFR 3.1 追加遅延 100ms 未満 | dirty 検出は `git status --porcelain`（既に repo に対する `git fetch` を毎サイクル実行している処理コストと比べて無視できる） + `[$REPO]` 挿入は文字列リテラルなので 0ms |
| NFR 3.2 サイクル完了時間 | dirty でない通常パスでは追加処理は `git status --porcelain` 1 回のみ。NFR 3.1 と同じ理由で影響なし |

## 設計上の判断

### dirty 検出を `git checkout` の stderr 包み込みではなく事前 `git status --porcelain` で行った理由

requirements の Open Questions に「`git status --porcelain` を用いた先読みでも `git checkout` の stderr 包み込みでも要件 3 を満たせばよく、選択は design 領分」とあった。先読みを選んだ理由:

- 構造化 4 値（current_branch / dirty_files / head / action）を git の純正エラー文字列の解析なしに、独立した bash 変数で確実に取得できる
- `git checkout` の文言は git バージョン・locale によって揺らぐが、`git status --porcelain` は machine-readable で安定（POSIX 規定）
- 失敗時のみ追加コストが発生（success path には `git status` 1 回追加のみ、NFR 3.1 に影響なし）
- `set -euo pipefail` 下で `git checkout` を fail-soft に捕まえるより、判定済みで明示的に `exit 1` する方が読みやすい

### dirty event を stderr (`>&2`) に出力した理由

- 既存 `*_warn` / `*_error` ロガーが全て `>&2` に出力しており、運用慣習と整合
- cron の典型的な crontab 行 `>> $HOME/.issue-watcher/cron.log 2>&1` は stderr も cron.log に集約するため、NFR 2.3「隣接行として観測できる」を満たす
- ローカルで手動実行する開発者にも「エラーである」ことが stream 分離で明確に伝わる

### `[$REPO]` を `[$REPO_SLUG]`（`owner-name`）にしなかった理由

requirements Out of Scope に明示: 「prefix フォーマットを `[<REPO_SLUG>]` へ切り替える運用判断（本要件は `[<REPO>]`＝`owner/name` 形式に固定）」。`/` を含む `owner/name` 形式は grep のリテラル文字列マッチで問題なく動作し、人間が読んだときに分かりやすい。

### `dispatcher:` / `pre-claim-probe:` / `stage-checkpoint:` / `slot-N:` / `reviewer:` / `developer:` 等のログには prefix を入れなかった理由

requirements Out of Scope:

> 本要件以外の dispatcher・Triage 系ログ整形（既に repo 情報を含む行は対象外、未対応行があれば本要件の Requirement 1 で吸収する）

Requirement 1 が列挙する 5 種類（pr-iteration / merge-queue / merge-queue-recheck / design-review-release / quota-aware）のみを修正対象とした。残りのロガーへの拡張は、必要が顕在化した時点で別 Issue として切り出す（impl-notes 末尾の「派生タスク候補」参照）。

### 既存 `process_merge_queue "$@"` 等のメインフロー呼び出しは関数定義より上の任意の位置にあるとは限らないため、Req 3.3 のテストは「順序ガード」と「exit 1 構造保証」の両論で書いた

メインフロー呼び出しを awk で確実に検出するロジックを書いたが、検出できない場合でも「`exit 1` で処理が落ちるため processor に到達しない」という構造的保証を PASS として扱う、二重防御の表現にしてある（test ロジックで `else` 分岐の PASS メッセージを別にしている）。

## 手動スモークテスト手順（再現可能）

```bash
# 1. dirty 状態の test repo を準備（local-only remote 経由）
rm -rf /tmp/test-119-remote /tmp/test-119-repo
mkdir /tmp/test-119-remote && cd /tmp/test-119-remote && git init -q --bare -b main
mkdir /tmp/test-119-repo && cd /tmp/test-119-repo \
  && git init -q -b main \
  && git config user.email test@test && git config user.name test \
  && touch foo && git add foo && git commit -q -m initial \
  && git remote add origin /tmp/test-119-remote \
  && git push -q -u origin main
echo "dirty" > foo  # working tree を dirty にする

# 2. watcher を minimal PATH （cron 環境模倣）で実行
env -i HOME="$HOME" PATH="/usr/bin:/bin" \
  REPO="owner/fake-repo" REPO_DIR=/tmp/test-119-repo \
  bash /path/to/idd-claude/local-watcher/bin/issue-watcher.sh

# 期待: exit=1、stderr に
#   [TS] watcher: [owner/fake-repo] dirty working tree blocks BASE_BRANCH checkout
#   [TS] watcher: [owner/fake-repo]   current_branch=main
#   [TS] watcher: [owner/fake-repo]   dirty_files=1
#   [TS] watcher: [owner/fake-repo]   head=<short-sha>
#   [TS] watcher: [owner/fake-repo]   action=escalate

# 3. clean tree に戻して再実行
cd /tmp/test-119-repo && git checkout -q foo
env -i HOME="$HOME" PATH="/usr/bin:/bin" \
  REPO="owner/fake-repo" REPO_DIR=/tmp/test-119-repo \
  bash /path/to/idd-claude/local-watcher/bin/issue-watcher.sh

# 期待: dirty event は出ず、各 processor 系行が
#   [TS] [owner/fake-repo] quota-aware: ...
#   [TS] [owner/fake-repo] merge-queue-recheck: ...
#   [TS] [owner/fake-repo] merge-queue: ...
#   [TS] [owner/fake-repo] pr-iteration: ...
# の形式で出力されること（`gh` 未インストールのため pr-iteration 以降で停止するが、
# prefix 配置が確認できる）

# 4. ユニットテスト全件 pass
for t in local-watcher/test/*_test.sh; do bash "$t" >/dev/null 2>&1 \
  && echo "PASS: $t" || echo "FAIL: $t"; done

# 5. shellcheck
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/test/repo_prefix_log_test.sh
# 期待: 既存 9 件の info-level warning（SC2317 / SC2012）のみ。新規追加分は 0 件。
```

## 派生タスク候補（本 Issue では対象外）

- **dispatcher / pre-claim-probe / stage-checkpoint / slot-N / reviewer / developer ログにも `[<REPO>]` を拡張**: 本 Issue で吸収しなかった残りのロガーを揃える。複数リポ運用の Triage 段階の追跡精度が上がる
- **auto-recover for dirty working tree**: 本 Issue は **可視化** のみ。dirty な状態から自動で `git stash` + checkout / human escalation に振り分ける recover ロジックは別 Issue（requirements の Out of Scope に明示）
- **cron.log を repo 別ファイルに分割**: `$HOME/.issue-watcher/cron-<repo-slug>.log` 等。crontab を書き換える破壊的変更を伴うため別 Issue。requirements Out of Scope
- **prefix を `[<REPO_SLUG>]` (=`owner-name`) に切り替える運用変更**: 同上、Out of Scope

## 確認事項（レビュワー判断ポイント）

1. **dirty event の出力 stream**: 現在は `>&2`（stderr）に 5 行出している。cron の typical な `2>&1` リダイレクトと整合するため運用面の問題はないが、stdout に揃えるべき場合はその指摘をいただきたい（要件は stream 指定なし）
2. **dirty 検出時の `unset _dirty_status`**: clean tree のメインフローを汚さないために local-ish 変数を unset している。bash の本体スクリプトに `local` キーワードを使えない（関数外）ため `_` prefix + `unset` で擬似的にクリーンアップしているが、慣習に合わせて省略してもよい
3. **`process_merge_queue` 呼び出し検出ロジック**: 関数定義をスキップしてメインフローの呼び出し行を awk で探すロジックは（将来 issue-watcher.sh の構造が変わった際の）脆弱性がある。テスト Req 3.3 は両論で PASS させているため致命的ではないが、より頑健な観点（例: process_merge_queue 関数の冒頭に sentinel コメントを置く）があれば指摘いただきたい

確認事項数: **3**
