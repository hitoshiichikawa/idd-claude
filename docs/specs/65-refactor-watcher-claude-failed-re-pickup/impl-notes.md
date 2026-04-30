# 実装ノート (Issue #65 / claude-failed 復旧時の re-pickup 事故防止)

## 概要

`claude-failed` ラベル復旧時に発生した PR #62 orphan 化事故 (2026-04-29) の
再発防止を、(a) ドキュメント / ラベル description / escalation コメント上での
復旧手順明文化と、(b) watcher 側の Issue pickup 直後における既存 impl PR 検出に
よる再 pickup 抑制の 2 層で実装した。

設計 PR (#82) で merge 済みの design.md / tasks.md に従い、すべての実装変更は
`addition only`（既存挙動を壊す削除なし）で完了。後方互換性 (NFR 1.1〜1.5) を
構造的に保証している。

## タスクごとの実装内容

### Task 1.1 / 1.2 (commit e6de274 / edabd43)

| ファイル | 変更内容 |
|---|---|
| `.github/scripts/idd-claude-labels.sh` | `claude-failed` description に「復旧時は ready-for-review を先に付与してから外す」を追記 (52 文字) |
| `repo-template/.github/scripts/idd-claude-labels.sh` | 同上、template 既存スタイル踏襲（`【Issue 用】` prefix なし、42 文字） |

Req 2.1 / 2.2 / 2.3 / 2.4 / NFR 1.4 / NFR 3.2 を充足。name と color は不変、
`--force` 再実行で description のみ上書き可能。

### Task 2.1 (commit 6b8be23): Pre-Claim Probe Logger

`local-watcher/bin/issue-watcher.sh` に以下 3 関数を追加（`dispatcher_error` の直後）:

- `pclp_log <msg>` → stdout, prefix `pre-claim-probe:`
- `pclp_warn <msg>` → stderr, prefix `pre-claim-probe: WARN:`
- `pclp_error <msg>` → stderr, prefix `pre-claim-probe: ERROR:`

既存 `mq_log` / `pi_log` / `drr_log` / `qa_log` / `sc_log` / `dispatcher_log`
と同形式 (`[$(date '+%F %T')] <prefix>: <msg>`) で揃え、grep 集計可能 (NFR 2.1)。

### Task 2.2 (commit 0421797): check_existing_impl_pr

`pclp_*` ロガーの直後に Pre-Claim Filter 本体関数 `check_existing_impl_pr` を実装。

- **入力**: `$1 = issue_number` (数値)
- **出力**: exit code (0 = continue, 1 = skip)
- **副作用**: 判定結果を `pclp_log/warn/error` で 1 行ログ出力

主要ロジック:

1. **入力検証**: 空文字 / 非数値 / `0` / 先頭ゼロ / 負数 → ERROR + exit 1
2. **REPO 形式検証**: `owner/repo` 形式でなければ ERROR + exit 1
3. **GraphQL クエリ**: `closedByPullRequestsReferences(first: 20) { nodes { number, state, headRefName } }`
   を `gh api graphql` で 1 回呼ぶ。`timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"`
   でラップ (新規 env var 導入なし / NFR 1.1)
4. **GraphQL エラー検査**: HTTP 失敗 / `errors[]` 含有 / `RATE_LIMITED` / jq parse error
   → すべて WARN + exit 1 (fail-safe / Req 1.7 / NFR 4.2)
5. **impl/design 判別**:
   - head が `^claude/issue-${N}-design-` → design として無視 (warn のみ)
   - その他すべて → impl として採用 (safe-side / 未知 pattern も skip 側に倒す)
6. **state 集約**:
   - OPEN あり → skip + log `state=OPEN reason=existing-impl-pr`
   - MERGED あり (OPEN なし) → 最大 PR 番号採用 + skip + log `state=MERGED`
   - CLOSED のみ → continue + log `reason=closed-only pr=#P`
   - 採用 PR 集合空 → continue + log `reason=no-linked-impl-pr`
   - 未知 state (DRAFT 等) → WARN + skip (fail-safe)

簡易 unit test を実施 (10 ケース、stub gh で fixture JSON を変えながら検証):

| ケース | fixture | expected rc | 結果 |
|---|---|---|---|
| OPEN-impl | OPEN PR 1 件 | 1 (skip) | PASS |
| MERGED-impl | MERGED PR 1 件 | 1 (skip) | PASS |
| CLOSED-only | CLOSED PR 1 件 | 0 (continue) | PASS |
| no-linked | 空 nodes | 0 (continue) | PASS |
| design-only | design head 1 件 | 0 (continue, design 無視) | PASS |
| OPEN-precedes-MERGED | OPEN + MERGED 混在 | 1 (skip, OPEN 優先) | PASS |
| MERGED-max | MERGED 2 件 | 1 (skip, 最大番号採用) | PASS |
| rate-limited-graphql | errors[].type=RATE_LIMITED | 1 (skip) | PASS |
| unknown-state-fail-safe | state=DRAFT | 1 (skip, fail-safe) | PASS |
| unknown-pattern-as-impl | 未知 head pattern | 1 (skip, safe-side で impl 扱い) | PASS |

### Task 3.1 (commit b416615): Dispatcher per-issue ループへの skip 分岐挿入

`_dispatcher_run` の per-issue ループ先頭（`issue_number=$(echo "$issue" | jq -r '.number')`
の直後、空き slot 探索の前）に以下 3 行を挿入:

```bash
if ! check_existing_impl_pr "$issue_number"; then
  continue
fi
```

skip 時は claim ラベル付与・slot 確保・worktree 操作を一切行わない。
PR 不在の通常運用では `check_existing_impl_pr` が exit 0 で素通り = 本機能導入前と
完全等価 (NFR 1.5 を構造的に保証)。

### Task 4.1 (commit 44884b5): build_recovery_hint

`pi_select_template` の直後（`pi_escalate_to_failed` より前）に純粋関数を実装。

- 引数: `pr_present` ∈ {`yes`, `no`, `unknown`}（既定 `unknown`、不正値も `unknown` に倒す）
- heredoc で markdown を stdout に出力
- 必ず含める: `ready-for-review` / `claude-failed` / 「先に付与」/ `force-push` /
  `orphan` / 「再 pickup」 (Req 3.1 / 3.2)
- `pr_present=no` 時は「PR 無しは `claude-failed` 除去のみで再 pickup される」旨
  (Req 3.3)

簡易 unit test で各 pr_present 値の必須キーワード含有を検証 (PASS)。

### Task 4.2 (commit 7b24119): 3 経路への組み込み

| 関数 | 対応箇所 | pr_present 引数 | 補足 |
|---|---|---|---|
| `mark_issue_failed` (line 2937 周辺) | body 末尾に `$(build_recovery_hint "unknown")` | unknown | run_impl_pipeline 各 stage 失敗 |
| `_slot_mark_failed` (line 3556 周辺) | body 末尾に `$(build_recovery_hint "unknown")` | unknown | worktree/Hook/Triage/branch 失敗 |
| `pi_escalate_to_failed` (line 1474 周辺) | escalation_body 末尾に `$(build_recovery_hint "yes")` | yes | PR 存在文脈 |

`qa_build_escalation_comment` は `needs-quota-wait` 経路で `claude-failed` を付与しない
ため Req 3.4 の対象外（design.md / requirements.md の整合通り）。

### Task 5.1 (commit 700daae): README 手動復旧節

`README.md` に以下を追加・更新:

1. **新節「`claude-failed` 状態の Issue から手動復旧する手順」** (line 531 周辺) を「失敗時」節
   (line 521-524) の直下に追加。ケース 1 (PR 既存) / ケース 2 (PR 不在) の手順、Pre-Claim
   Filter による自動ガード説明を含む (Req 4.1 / 4.2 / 4.3 / 4.4)
2. **3 箇所からの相互参照リンク** (Req 4.5):
   - line 303「GitHub ラベル設定」表の `claude-failed` 行
   - line 528 周辺「失敗時」節末尾
   - line 583「ラベル状態遷移まとめ」表の `claude-failed` 行
3. **副次変更** (labels.sh との整合性確保):
   - line 303: `claude-failed` 行の用途欄に新節リンク追記
   - line 318: `gh label create claude-failed` のコピペ例の description を新文言に更新

`repo-template/CLAUDE.md` には追加しない（design.md Migration Strategy 節の方針通り、
consumer repo の責務範囲外）。

### Task 6.1 (commit 6025585): shellcheck / 互換性検証

shellcheck `-S warning` 結果:

```
shellcheck -S warning local-watcher/bin/issue-watcher.sh \
  .github/scripts/idd-claude-labels.sh \
  repo-template/.github/scripts/idd-claude-labels.sh
# → ALL CLEAN at warning level
```

残る info レベル指摘 (SC2317 / SC2012) は既存パターンと同一で、本 PR で増分なし。
新規追加の SC2016 (GraphQL 変数記法を bash 展開と誤認) のみ `# shellcheck disable=SC2016`
コメントで意図を明示して suppress。

cron-like 最小 PATH での依存解決:

```
env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq flock git timeout'
# → /usr/bin/gh, /usr/bin/jq, /usr/bin/flock, /usr/bin/git, /usr/bin/timeout すべて解決
```

(`claude` は cron 環境で issue-watcher.sh 冒頭の PATH prepend を経由して解決される
既存仕様)

差分検証:

- `git diff main..HEAD -- local-watcher/bin/issue-watcher.sh` の `-` 行 → **0 件**
  （addition only / 既存挙動への破壊変更なし）
- README.md の `-` 行は 3 行のみ（labels.sh との文言整合のための行内編集）
- 新規 env var 名・ラベル name / color・cron 登録文字列・exit code 意味すべて不変

## 受入基準の達成確認

すべての requirement numeric ID をどこで担保したかを記録する。

| Req ID | 内容 | 検証 |
|---|---|---|
| 1.1 | claim 直前に linked PR 確認 | `_dispatcher_run` line 4326 直後の `check_existing_impl_pr` 呼び出し (commit b416615) |
| 1.2 | OPEN impl PR → skip + claim ラベル付与せず | 同上 + `check_existing_impl_pr` の OPEN 集約パス。unit test "OPEN-impl" PASS |
| 1.3 | MERGED impl PR → skip + claim ラベル付与せず | 同上 + MERGED 集約パス。unit test "MERGED-impl" / "MERGED-max" PASS |
| 1.4 | skip 理由を識別 prefix 付きでログ | `pclp_log/warn` の固定 key=value 形式 (`pre-claim-probe: skip issue=#N pr=#P state=S reason=R`) |
| 1.5 | 不在 / CLOSED のみは pickup 続行 | `check_existing_impl_pr` の continue path。unit test "CLOSED-only" / "no-linked" PASS |
| 1.6 | impl/design PR を区別、design は対象外 | head pattern `^claude/issue-${N}-design-` で除外。unit test "design-only" PASS |
| 1.7 | API 失敗時 skip + 識別 prefix ログ | `gh api graphql` non-zero / errors / jq parse error すべて WARN + exit 1。unit test "rate-limited-graphql" PASS |
| 2.1 | claude-failed description に復旧手順 | labels.sh × 2 (commit e6de274 / edabd43) |
| 2.2 | description 100 文字以内 | local 52 文字 / template 42 文字。手動 wc -m で確認 |
| 2.3 | --force で description 上書き | 既存 line 113 (`gh label create ... --force`) を再利用 |
| 2.4 | name / color 不変 | `claude-failed|e74c3c|...` の name / color フィールド不変。git diff で `-`行が description のみ |
| 3.1 | escalation に「ready-for-review 先付与」 | `build_recovery_hint` (commit 44884b5)。unit test PASS |
| 3.2 | 順序逆転リスクの注意書き | `build_recovery_hint` 全分岐で「force-push」「orphan」「再 pickup」を含む |
| 3.3 | PR 無しの補足手順 | `build_recovery_hint "no"` 分岐で「claude-failed 除去のみで再 pickup」を含む |
| 3.4 | 既存 escalation 経路すべてに含める | mark_issue_failed / _slot_mark_failed / pi_escalate_to_failed の 3 経路に組み込み (commit 7b24119) |
| 4.1 | README に手動復旧節 | README.md 新節 (line 531) (commit 700daae) |
| 4.2 | 操作分岐の明示 | 新節「ケース 1」「ケース 2」見出し |
| 4.3 | PR 既存時の手順とリスク | ケース 1 で順序ガイダンス + orphan 化リスク |
| 4.4 | PR 無時の手順 | ケース 2 で「claude-failed 除去で次サイクル再 pickup」 |
| 4.5 | 相互参照リンク | 3 箇所からの新節リンク (line 303 / 528 / 583) |
| NFR 1.1 | 既存 env var 名不変 | git diff で env var 名定義の変更なし |
| NFR 1.2 | cron / launchd 登録文字列不変 | git diff で `*/2` / `REPO=` / `LOG_DIR=` 等の変更なし |
| NFR 1.3 | 既存 exit code 意味不変 | `check_existing_impl_pr` の skip は per-issue continue であり exit せず（dispatcher は exit 0 を維持） |
| NFR 1.4 | 既存ラベル name / color 不変 | labels.sh 差分は description のみ |
| NFR 1.5 | linked PR 不在時は導入前と同一挙動 | check_existing_impl_pr exit 0 で素通り → 既存 claim → fork → wait の制御フローに完全合流 |
| NFR 2.1 | grep 可能な識別 prefix | `pre-claim-probe:` prefix を全ログに含める |
| NFR 2.2 | ログに issue / PR / state を含める | pclp_log の固定 key=value 形式 |
| NFR 2.3 | 複数 Issue skip は独立行 | per-issue ループ内で 1 件ごとに pclp_log を呼ぶ |
| NFR 3.1 | watcher shellcheck クリーン | warning レベル 0 件確認済み |
| NFR 3.2 | label script shellcheck クリーン | warning レベル 0 件確認済み |
| NFR 3.3 | dogfood 手順 (OPEN PR) | 後述「dogfood テスト手順」参照 |
| NFR 3.4 | dogfood 手順 (CLOSED PR) | 後述「dogfood テスト手順」参照 |
| NFR 4.1 | レート制限を超えない呼び出し制御 | per cycle 最大 5 query (gh issue list --limit 5)。GraphQL primary 5000 points/h に対して 33 倍余裕 |
| NFR 4.2 | レート制限時 skip + ログ | RATE_LIMITED 検出時 `reason=rate-limited` で WARN + skip |

## dogfood テスト手順 (Task 6.2 / NFR 3.3 / 3.4 / 1.5)

PR 本文の Test plan 用に以下を残す。実施は idd-claude 自身を対象 repo として、
PR merge 後に実 cron tick で観測する。

### dogfood-A: OPEN PR + claude-failed 復旧シナリオ (NFR 3.3)

```bash
# 1. test issue を立てて auto-dev を付与
ISSUE_TITLE="dogfood: pre-claim-filter test (OPEN PR)"
ISSUE_BODY="本 Issue は Issue #65 dogfood 専用テスト Issue です。impl 完了時に close してください。"
TEST_ISSUE=$(gh issue create --repo hitoshiichikawa/idd-claude \
  --title "$ISSUE_TITLE" --body "$ISSUE_BODY" --label auto-dev --json number -q .number)

# 2. 手動で OPEN impl PR を作成（空 commit、本文に Closes #N）
git fetch origin main
git checkout -b "claude/issue-${TEST_ISSUE}-impl-dogfood-test" origin/main
git commit --allow-empty -m "dogfood: empty commit for pre-claim-filter test"
git push -u origin "claude/issue-${TEST_ISSUE}-impl-dogfood-test"
gh pr create --base main \
  --title "dogfood: pre-claim-filter OPEN PR test" \
  --body "Closes #${TEST_ISSUE}"  # ← Closes キーワード必須

# 3. Issue に claude-failed を付け、ready-for-review を付けずに claude-failed のみ除去（誤操作シナリオ）
gh issue edit "$TEST_ISSUE" --add-label claude-failed
sleep 5
gh issue edit "$TEST_ISSUE" --remove-label claude-failed

# 4. watcher を 1 cycle 走らせる（cron 待ち or 手動実行）
~/bin/issue-watcher.sh

# 5. 期待: pre-claim-probe ログを確認
grep "pre-claim-probe.*issue=#${TEST_ISSUE}" $LOG_DIR/issue-watcher.log
# → "pre-claim-probe: skip issue=#N pr=#P state=OPEN reason=existing-impl-pr" が出ること

# 6. claude-claimed ラベルが付かないことを確認
gh issue view "$TEST_ISSUE" --json labels -q '.labels[].name'
# → claude-claimed が含まれないこと

# 7. 後始末
gh pr close "<PR>" --delete-branch
gh issue close "$TEST_ISSUE"
```

### dogfood-B: CLOSED (非 merge) PR + 復旧シナリオ (NFR 3.4)

```bash
# 1-2. dogfood-A と同じ手順で test Issue + PR 作成
# 3. PR を merge せず close
gh pr close <PR>  # --delete-branch は付けない（branch を残す）

# 4. Issue に claude-failed を付け、その後除去
gh issue edit "$TEST_ISSUE" --add-label claude-failed
gh issue edit "$TEST_ISSUE" --remove-label claude-failed

# 5. watcher 1 cycle
~/bin/issue-watcher.sh

# 6. 期待: pre-claim-probe continue ログ + 既存フローへ進む
grep "pre-claim-probe.*issue=#${TEST_ISSUE}" $LOG_DIR/issue-watcher.log
# → "pre-claim-probe: continue issue=#N reason=closed-only pr=#P" が出ること
# → その後 claude-claimed が付与され、Triage が起動することを確認
```

### dogfood-C: PR 不在の通常運用 (NFR 1.5 構造的検証)

```bash
# 既存の任意の auto-dev Issue（PR 未作成）で 1 cycle
~/bin/issue-watcher.sh

# 期待: pre-claim-probe continue ログ + 既存 Triage 起動
grep "pre-claim-probe.*reason=no-linked-impl-pr" $LOG_DIR/issue-watcher.log
```

### dogfood 共通の後始末

dogfood 実施後の test Issue / 手動 PR は **必ず close / 削除** してリポジトリを
クリーンにする。dangling test branch は `git push origin --delete` で除去する。

## ラベル description 反映確認 (Task 6.3 deferrable)

idd-claude 自身を対象に以下を実行することで `claude-failed` description が新文言に
更新される:

```bash
cd /path/to/idd-claude
bash .github/scripts/idd-claude-labels.sh --force

# 確認
gh label list --json name,description | jq '.[] | select(.name=="claude-failed")'
# → description が "【Issue 用】 自動実行が失敗（復旧時は ready-for-review を先に付与してから外す）" になること
# → 文字数 52 < 100 (Req 2.2)
```

consumer repo の波及は `install.sh --force` 再実行で行われる（既存運用パターン）。

## 確認事項（人間判断を仰ぐ点）

1. **dogfood test 実施タイミング**: 本 PR は dogfood test を **PR merge 後** に実施する
   設計（dogfood は idd-claude self-hosting cron 上で観測）。PR merge 前にプレ検証する
   場合は、dogfood-A / dogfood-B のために手動で test Issue + 手作り PR を作る必要があり、
   それ自体が現在 OPEN 中の Issue #65 と並行運用される懸念があるため、PjM / Reviewer の
   判断に委ねる。
2. **README の「失敗時」節既存文言の温存**: 既存の「Claude が連続で失敗した場合は
   `claude-failed` ラベルが付き、それ以降自動処理の対象外になる。問題を解決してから、
   このラベルを外して手動で再実行キューに戻す。」という記述は誤った復旧手順を誘発する
   表現（「ラベルを外して」のみ書かれており順序非言及）だが、本 PR では削除せず、直後
   に「⚠️ 復旧時のラベル操作順序に注意」段落と新節を追加する形で温存した。後方互換性
   配慮 + 移行期の参照しやすさを優先したが、もし「誤誘発を断ちたい」なら別 PR で書き
   換える判断もある。
3. **`build_recovery_hint` 関数のテストハーネス不在**: idd-claude には bash unit test
   フレームワークが無いため、本機能のロジック検証はインライン bash コマンドによる
   一過性の test に留まる。impl-notes.md に検証手順とケース一覧を記録したが、回帰
   テストとして CI 化する場合は別 Issue で検討。

## 後方互換性チェック

- [x] env var 名: 新規追加なし、改名なし (`REPO` / `DRR_GH_TIMEOUT` / `MERGE_QUEUE_GIT_TIMEOUT`
      の参照のみ)
- [x] ラベル name / color: 不変 (`claude-failed|e74c3c|...` の `name|color` 部分不変)
- [x] cron / launchd 登録文字列: 不変 (env var 追加なし → cron 行への追記不要)
- [x] exit code 意味: 不変 (`check_existing_impl_pr` の skip は per-issue continue
      であり script 全体の exit code には影響しない)
- [x] 既存処理フロー: PR 不在の通常運用では `check_existing_impl_pr` exit 0 で素通り
      → 既存 claim → fork → wait に完全合流（NFR 1.5 構造的保証）
- [x] consumer repo への波及: `repo-template/.github/scripts/idd-claude-labels.sh` の
      description 更新のみ。consumer は `install.sh --force` 再実行で取り込む既存運用
      パターン
