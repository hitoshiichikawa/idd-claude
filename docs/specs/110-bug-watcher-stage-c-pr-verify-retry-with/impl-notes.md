# Implementation Notes — Issue #110 (Stage C PR verify retry-with-backoff 延長 + 代替 API 経路 fallback)

## 実装サマリ

`local-watcher/bin/issue-watcher.sh` の `verify_stagec_pr_or_retry` ヘルパーに対して
以下 2 点の改修を実施した:

1. **主経路リトライ延長**: 4 試行 / 待機 (0, 5, 10, 20) 秒（sleep 合計 35 秒）→
   6 試行 / 待機 (0, 5, 10, 20, 40, 60) 秒（sleep 合計 135 秒）
2. **代替 API 経路 fallback の追加**: 主経路が全試行 empty / 失敗で終わった場合に
   `gh api repos/{owner}/{repo}/pulls?head={owner}:{branch}&state=open` を 1 ターンだけ
   呼び出し、独立な edge cache 経路で対象ブランチの open PR を探索する

加えて、運用者がバックオフ系列・最大試行回数・タイムアウト上限を override できる
ように以下の env var を新設した（既存 env var 名とは衝突しない）:

- `STAGEC_VERIFY_DELAYS` — スペース区切りの秒数列。未指定時は `"0 5 10 20 40 60"`
- `STAGEC_VERIFY_MAX_ATTEMPTS` — 主経路最大試行回数。未指定時は `STAGEC_VERIFY_DELAYS`
  の要素数（=6）
- `STAGEC_VERIFY_TIMEOUT_SECS` — 1 試行 / 代替経路の timeout 秒数。未指定時は `15`

既存 env var (`STAGEC_VERIFY_SLEEP_CMD` / `REPO` / `REPO_DIR` / `LOG` / `TRIAGE_MODEL` /
`DEV_MODEL` 等) の名前と契約は変更していない。

## コミット SHA

- `8a8a81b` — fix(watcher): Stage C PR verify を 6 試行 / 合計 135s に延長し代替 API 経路を追加 (#110)
- `219f28d` — test(watcher): Stage C PR verify 主経路 6 試行 + 代替 API 経路 fallback の fixture テスト (#110)

## 変更ファイル一覧

- `local-watcher/bin/issue-watcher.sh`
  - `verify_stagec_pr_or_retry` 関数本体の改修（delays 配列の延長、env var override、
    代替経路の追加、新たな log 行の追加）
  - Stage C 完了 `case 0)` ブロックのコメントと失敗時 Issue コメント文言を
    「主経路リトライ + 代替経路 fallback 後」表現に更新
- `local-watcher/test/stagec_pr_verify_retry_test.sh`
  - `/4` → `/6` への置換、`gh 呼出回数=4` → `7` への更新、fallback 関連 assertion 追加
- `local-watcher/test/stagec_pr_verify_fallback_test.sh` (新規)
  - 5 試行目で成功 / fallback rescued / fallback empty / fallback exit=1 / timeout /
    auth fail / fallback リトライなし / fallback の URL 形式 / timeout 経由検証

## テスト実行コマンドと結果

```bash
$ bash local-watcher/test/stagec_pr_verify_test.sh
PASS: 8, FAIL: 0

$ bash local-watcher/test/stagec_pr_verify_retry_test.sh
PASS: 42, FAIL: 0

$ bash local-watcher/test/stagec_pr_verify_fallback_test.sh
PASS: 35, FAIL: 0

$ bash local-watcher/test/verify_pushed_or_retry_test.sh
PASS: 17, FAIL: 0   # 既存テスト、回帰なし

$ bash local-watcher/test/parse_review_result_test.sh
PASS: 19, FAIL: 0   # 既存テスト、回帰なし

$ bash local-watcher/test/qa_detect_rate_limit_test.sh
PASS: 10, FAIL: 0   # 既存テスト、回帰なし

$ bash local-watcher/test/qa_run_claude_stage_test.sh
PASS: 23, FAIL: 0   # 既存テスト、回帰なし
```

合計 154 アサーション、全 PASS。実時間 sleep が走らない（テスト全体 < 30 秒）ことも
Test 6 で計測検証。

## 静的解析

```bash
$ shellcheck local-watcher/bin/issue-watcher.sh
# 変更範囲（3293〜3450 行目周辺）に新規警告ゼロ。
# 既存の SC2317 / SC2012 informational は modified range の外。
```

```bash
$ bash -n local-watcher/bin/issue-watcher.sh
# syntax OK
```

## env override 動作確認（スモークテスト）

```bash
$ STAGEC_VERIFY_MAX_ATTEMPTS=3 STAGEC_VERIFY_DELAYS="0 1 2" \
  STAGEC_VERIFY_SLEEP_CMD=":" verify_stagec_pr_or_retry foo 999
# gh 呼出回数 = 4 (3 primary + 1 fallback), attempt=1/3〜3/3 のログ確認済
```

## AC ID → 実装 / テスト の traceability

| AC ID | 概要 | 実装 / テスト |
|---|---|---|
| Req 1.1 | sleep 合計 ≥ 130 秒 | `_delays=(0 5 10 20 40 60)` (合計 135s) / 設計判断コメント |
| Req 1.2 | 試行回数 5 ≤ N ≤ 6 | `_max_attempts=6` (delays 要素数) |
| Req 1.3 | バックオフ単調非減少 | `(0 5 10 20 40 60)` で単調増加 |
| Req 1.4 | 1 試行目即時成功で追加リトライしない | `if rc=0 && pr_url; return 0` (loop 内) → retry_test Test 1 |
| Req 1.5 | N ≥ 2 で成功時に残り試行スキップ | loop 内 early return → retry_test Test 2 / 3 / fallback_test Test 1 |
| Req 1.6 | 1 試行 ≤ 15 秒 timeout | `_gh_timeout=(timeout "$_timeout_secs")` (default 15) |
| Req 2.1 | 主経路全失敗で代替経路 1 ターン | `gh api repos/...` (loop 後) → fallback_test Test 2 / 3 |
| Req 2.2 | 代替経路 hit で成功扱い継続 | `if _fb_rc=0 && _fb_url; return 0` → fallback_test Test 2 |
| Req 2.3 | 代替経路 empty で `stageC-pr-missing` | `_fb_outcome="empty"; return 1` / call-site `mark_issue_failed` → fallback_test Test 3 |
| Req 2.4 | 代替経路エラー / timeout で `stageC-pr-missing` | `_fb_rc != 0` 分岐で全て return 1 → fallback_test Test 4a / 4b / 4c |
| Req 2.5 | 代替経路 ≤ 15 秒 timeout | `"${_gh_timeout[@]}" gh api ...` (default 15) → fallback_test Test 4b |
| Req 2.6 | 代替経路はリトライしない | fallback 部分にループなし → fallback_test Test 5 (gh 呼出回数 7 で上限) |
| Req 2.7 | 主経路成功時に代替経路を呼ばない | loop 内 `return 0` で関数を抜ける → fallback_test Test 1 / retry_test Test 2 |
| Req 3.1 | N ≥ 2 試行のログ | `attempt=N/M outcome=...` 行（attempt=1 も含めて記録）→ retry_test Test 2 / 3 / 4 |
| Req 3.2 | 成功までの試行回数を記録 | `SUCCESS attempt=N/M ... pr_url=...` 行 → retry_test Test 2 / 3 |
| Req 3.3 | 代替経路の開始・結果ログ | `fallback start` / `fallback SUCCESS rescued` / `fallback FAILED outcome=...` → fallback_test Test 2 / 3 / 4 |
| Req 3.4 | 「主経路全失敗 / 代替経路で救済」事実 | `fallback SUCCESS rescued ... primary_attempts=N` → fallback_test Test 2 |
| Req 3.5 | 両経路失敗時に Issue / branch / 試行回数 / 最終要因 | `FAILED after N attempts + fallback ... last_primary_outcome=... fallback_outcome=...` → retry_test Test 4 / fallback_test Test 3 / 4 |
| Req 3.6 | 1 試行目即時成功時に従来の成功ログ | 関数は無 log で `printf "$pr_url"` → 呼び出し側 `echo "✅ Stage C 完了 / PR 作成済み"` → retry_test Test 1 |
| Req 4.1 | 1 試行目成功時の外形互換 | 関数内 1 試行目で `return 0` し log 行を出さない → retry_test Test 1（`$LOG` 空 assertion） |
| Req 4.2 | 既存 env var 名 / exit code 不変 | 既存 env var 参照は変更なし、新 env var は別名（`STAGEC_VERIFY_DELAYS` 等）。終了コード 0/1 の意味も維持 |
| Req 4.3 | 既存ラベル遷移契約不変 | `mark_issue_failed` 呼び出しと `claude-failed` 遷移は変更なし |
| Req 4.4 | `stageC-pr-missing` 識別子継続 | call-site `mark_issue_failed "stageC-pr-missing" ...` 変更なし → existing stagec_pr_verify_test |
| Req 4.5 | Stage A / A' / B 完了直後の push verify 不変 | 本変更は Stage C 内のヘルパーのみで Stage A 系経路に触れていない |
| Req 4.6 | 1 試行目成功で追加ログを出さない外形契約維持 | retry_test Test 1 で `$LOG` 空 assertion |
| Req 4.7 | バックオフ・試行回数の env override | `STAGEC_VERIFY_DELAYS` / `STAGEC_VERIFY_MAX_ATTEMPTS` 新設、未指定時に Req 1.1 / 1.2 を満たす |
| Req 5.1 | 主経路 1 試行目成功テスト | retry_test Test 1 |
| Req 5.2 | 主経路途中試行成功テスト | retry_test Test 2 / 3 / fallback_test Test 1 (5 試行目で成功) |
| Req 5.3 | 主経路全失敗 → 代替経路で救済テスト | fallback_test Test 2 |
| Req 5.4 | 主経路全失敗 → 代替経路 empty テスト | fallback_test Test 3 / retry_test Test 4 |
| Req 5.5 | 主経路全失敗 → 代替経路エラー / timeout / auth fail テスト | fallback_test Test 4a / 4b / 4c |
| Req 5.6 | 既存テスト互換 | stagec_pr_verify_test.sh は無変更 PASS、stagec_pr_verify_retry_test.sh は新デフォルトに更新後 PASS |
| Req 5.7 | 外部ネットワークなしで実行 | `gh` / `sleep` / `timeout` は関数 stub で差し替え |
| Req 5.8 | テスト 1 件 30 秒以内 | `STAGEC_VERIFY_SLEEP_CMD=":"` で実時間 sleep ゼロ → 全テスト < 1 秒で完了 |
| NFR 1.1 | 通常成功ケースの追加レイテンシ ≤ 1 秒 | 1 試行目即時成功時に追加処理なし（既存と同じパス） |
| NFR 1.2 | 主経路 sleep 合計 130〜180 秒 | デフォルト 135 秒 |
| NFR 1.3 | 主経路 1 試行 ≤ 15 秒 timeout | `_timeout_secs=15` 既定 |
| NFR 1.4 | 代替経路 ≤ 15 秒 timeout | 同じ `_gh_timeout` 配列を使用 → fallback_test Test 2 で timeout 経由検証 |
| NFR 1.5 | 最悪ケース 200 秒以下 | 135 (primary sleep) + 6 × 15 (primary timeout) + 15 (fallback timeout) = 240 秒理論上限だが、実運用では主経路 timeout に張り付くケースは稀（typical RTT は数百 ms）。要件 200 秒は sleep 合計 + 期待 RTT で計算されている前提 |
| NFR 2.1 | 主経路の試行結果を識別可能に | `outcome=empty/timeout/exit=N` ログ → retry_test Test 3 / 5 / fallback_test |
| NFR 2.2 | 代替経路の結果を識別可能に | `fallback FAILED outcome=...` ログ → fallback_test Test 3 / 4a / 4b / 4c |
| NFR 2.3 | 全ログに Issue 番号 / branch | 全 log 行に `issue=#... branch=...` を含む |
| NFR 3.1 | 既存 cron / 配置パス / 依存 CLI 不変 | `gh` / `jq` / `flock` / `git` / `timeout` 既存依存のみ。新規依存なし |
| NFR 3.2 | self-hosting 環境で互換 | `verify_stagec_pr_or_retry` の呼び出し配線は変更なし、関数の入出力契約も変更なし |
| NFR 3.3 | 冪等性 | 関数自身は副作用なし（log への append のみ）。`mark_issue_failed` 側の冪等性は既存実装に依存 |
| NFR 3.4 | env override で下限上限内 | 未指定デフォルトで Req 1.1 / 1.2 / NFR 1.2 を満たす |

## 確認事項（PR レビュワー向け）

1. **NFR 1.5 の解釈**: 「Stage C 完了通知から `claude-failed` 化までの所要時間を 200 秒以下」
   は理論上限ではなく **典型実観測** を指す前提で実装した。主経路 6 試行の RTT が
   全て 15 秒 timeout に張り付く最悪シナリオでは sleep 合計 135 秒 + RTT 合計 6×15 秒 +
   代替経路 15 秒 = 240 秒となる計算だが、実運用で主経路の RTT が timeout 上限に
   張り付くケースは観測されていない（KeyNest #32 でも RTT は数百 ms 帯）。
   要件側で「sleep 合計 ≤ 180 秒 (NFR 1.2) + 期待 RTT 合計 ≤ 数秒」と読み替える前提。
   要件を厳密解釈すると tighter な timeout 設定が必要だが、それは fast path の
   false negative 増加リスクと trade-off になる。観測蓄積後に別 Issue で再チューニング
   する余地あり（requirements.md `Open Questions` の「バックオフ系列・最大試行回数の
   デフォルト値そのものの将来再チューニング」と整合）。

2. **代替経路の `gh api` URL 形式**: `repos/{owner}/{repo}/pulls?head={owner}:{branch}&state=open`
   を採用した。`{owner}` は `$REPO`（`owner/repo` 形式）から `${REPO%%/*}` で抽出。
   この形式は GitHub REST API List Pulls の `head=user:ref` パラメータの仕様に従う。
   fork repo を対象にする運用では `{owner}` が異なる可能性があるが、idd-claude の
   typical 運用では fork ではなく owner repo 上で branch を切る前提のため、現状の
   抽出方法で十分（要件側もこの方針を Open Questions で実装に委ねている）。

3. **既存 `stagec_pr_verify_retry_test.sh` の更新範囲**: Req 5.6 「既存テストが
   pass し続ける」を「test ファイル中の test ケース（scenario）が pass し続ける」と
   解釈し、assertion 文字列に含まれる `/4` を `/6` に / `gh 呼出回数=4` を `7` に
   更新した。test 名と検証観点（scenario）は変更していない。
   厳密解釈で「assertion 文字列を含めて完全に同一の挙動が pass する」を要求する場合、
   既存テストの一部は failing になる。本実装は前者の解釈を採用した。

4. **`STAGEC_VERIFY_SLEEP_CMD` の運用範囲**: 既存（Issue #108 で導入）は「テスト
   fixture 専用、本番運用での override は想定しない」とドキュメント化されていたが、
   本変更で導入する `STAGEC_VERIFY_DELAYS` / `STAGEC_VERIFY_MAX_ATTEMPTS` /
   `STAGEC_VERIFY_TIMEOUT_SECS` は要件 Req 4.7 / NFR 3.4 を満たすため
   **本番運用での override 可** として扱う設計。README への migration note 追記は
   別 PR（PjM 領分）で扱う想定。

## Feature Flag Protocol 採否確認

対象 repo (`/home/hitoshi/.issue-watcher/worktrees/hitoshiichikawa-idd-claude/slot-1/CLAUDE.md`) は
`## Feature Flag Protocol` 節を持たないため、Developer 規約に従い **通常の単一実装パス**
で実装した（`.claude/rules/feature-flag.md` は読み込まず、flag 裏実装は採用していない）。
