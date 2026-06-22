# 実装ノート (Issue #352)

## 実装概要

Issue #352「feat(watcher): auto-merge.sh — 実装 PR を checks 全 green で squash auto-merge」の
実装一式です。AND 二重 opt-in (`AUTO_MERGE_ENABLED=true` AND `FULL_AUTO_ENABLED=true`) 配下で、
実装 PR に対し `gh pr merge --auto --squash --delete-branch` を発行する Auto-Merge Processor
を追加しました。実 merge は GitHub の auto-merge state machine に委ね、watcher 側は polling
しません。

### 追加・変更したファイル

| ファイル | 種別 | 説明 |
|---|---|---|
| `local-watcher/bin/modules/auto-merge.sh` | 新規 | Auto-Merge Processor モジュール本体（関数 prefix `am_`） |
| `local-watcher/bin/issue-watcher.sh` | 変更 | Config ブロック追加 / `REQUIRED_MODULES` 追加 / call site 追加 / startup ログに `auto-merge=` 追加 |
| `local-watcher/test/auto-merge_test.sh` | 新規 | gh stub による単体テスト（56 ケース） |
| `README.md` | 変更 | 「オプション機能一覧」表に `AUTO_MERGE_ENABLED` 行追加、詳細セクション `Auto-Merge Processor (#352)` 追加 |

### 追加した env var（既定値）

| env var | 既定値 | 用途 |
|---|---|---|
| `AUTO_MERGE_ENABLED` | `false` | Auto-Merge Processor の opt-in gate。`=true` 厳密一致のみ ON |
| `AUTO_MERGE_MAX_PRS` | `10` | 1 サイクルで処理する PR 数の上限（残りは次回サイクル持ち越し） |
| `AUTO_MERGE_GIT_TIMEOUT` | `60` | `gh` 操作の個別タイムアウト（秒） |
| `AUTO_MERGE_HEAD_PATTERN` | `^claude/issue-.*-impl` | 対象 head branch の ERE パターン |

### 有効化方法

```cron
*/2 * * * * REPO=owner/your-repo REPO_DIR=$HOME/work/your-repo \
  AUTO_MERGE_ENABLED=true \
  FULL_AUTO_ENABLED=true \
  $HOME/bin/issue-watcher.sh >> $HOME/.issue-watcher/cron.log 2>&1
```

## 設計判断

### モジュール独立性 / `am_` prefix の採用

CLAUDE.md「機能追加ガイドライン §1, §2」に従い、本体 inline ではなく
`local-watcher/bin/modules/auto-merge.sh` として切り出し、関数 prefix `am_` を割り当てました。
ロガー（`am_log` / `am_warn` / `am_error`）は `core_utils.sh` に集約せず module 内に同居させ
ました。`merge-queue.sh` の `mqr_*` が module 内ロガーを持つ実績に倣い、機能の独立性を優先
する判断です（後続 PR で必要に応じて `core_utils.sh` に移設可能）。

### AND 二重 opt-in と早期 return の順序

`process_auto_merge` の入口で:

1. `full_auto_enabled` を先に評価（kill switch）→ OFF なら何もログを出さず early return
   （#348 既存 suppression ログに委ねる / Req 7.3）
2. `am_resolve_gate_enabled` を次に評価 → OFF なら `suppressed by AUTO_MERGE_ENABLED gate (no-op)`
   ログを 1 行出力（Req 7.2）

の 2 段ゲートにしました。watcher 全体の cycle あたりログ量を増やさないため、
`FULL_AUTO_ENABLED` OFF 側は重複ログを抑止しています。

### 冪等性（Req 4.5）

`gh pr list --json autoMergeRequest` で auto-merge enabled 済み PR を識別し、`am_should_enable_for_pr`
が rc=2（既に enabled）を返したら API 呼び出しを skip して `already-enabled` カウントに加算
する形にしました。重複 enable の API 呼び出しは GitHub 側で冪等扱いされる可能性が高い
ものの、`watcher 側で防ぐ`方が NFR 3.1（1 PR 1 API 呼び出し）の保証として強固です。

### CONFLICTING / UNKNOWN PR の boundary 委譲（Req 2.5, 2.6, 6.4）

`mergeable=MERGEABLE` のみを通し、`CONFLICTING` は既存 merge-queue / auto-rebase 経路に
委譲、`UNKNOWN` は次サイクルで再評価するシンプルな実装にしました。`process_auto_merge` の
配置順は merge-queue → auto-rebase → auto-merge の直列なので、同一サイクル内で
needs-rebase ラベルが付与 / 除去されたあとに auto-merge が候補を絞れます。

### 失敗種別の 3 分類（Req 5.1, 5.2, 5.5）

`gh pr merge` の stderr 内容から best-effort で `transport-error` / `repo-config-rejected` /
`api-error` の 3 種に分類して WARN ログを書き分けました。stderr の grep パターンは
[GitHub の auto-merge エラーメッセージ](https://docs.github.com/en/rest/pulls/pulls#merge-a-pull-request)
に対する経験則（`could not resolve host` / `branch protection` / `auto merge ... disable`）
であり、誤分類しても WARN ログとして痕跡が残る安全側設計です（silent fail にはならない /
Req 5.4）。

### `gh pr merge` への `--` オプション打ち切り（NFR 1.2）

PR 番号は事前に `^[0-9]+$` で検証済み（NFR 1.3）ですが、シェル injection 予防の慣習として
`gh pr merge --auto --squash --delete-branch -- "$pr_number"` のように `--` でオプション
解釈を打ち切りました。

### head pattern の既定値選択

設計 PR（`claude/issue-<N>-design-<slug>`）は **対象外**（Out of Scope の Issue 04 範囲）
であり、実装 PR（`claude/issue-<N>-impl-<slug>`）のみが auto-merge 対象です。
`AUTO_MERGE_HEAD_PATTERN=^claude/issue-.*-impl` を既定値とし、`PR_ITERATION_HEAD_PATTERN`
（既定 `^claude/issue-[0-9]+-impl-`）と類似ですが、より緩い `.*` を採用しました。これは
要件 2.1 の文言（`^claude/issue-.*-impl`）に忠実に従う判断です。厳格化したい運用者は
`AUTO_MERGE_HEAD_PATTERN=^claude/issue-[0-9]+-impl-` を明示できます。

### 配置順序: Phase D（auto-rebase）の直後

Phase D の直後に process_auto_merge を直列配置しました。Phase A / Re-check / Phase D で
`needs-rebase` ラベル / `mergeable` 状態が確定したあとに auto-merge が評価する順序です。
これにより:

- merge-queue が CONFLICTING を `needs-rebase` 化したサイクルで auto-merge が当該 PR を
  奪わない（Req 4.1: needs-rebase に触らないが、そもそも mergeable=CONFLICTING で skip）
- auto-rebase が rebase + push に成功したサイクルでは mergeable が次サイクルまで UNKNOWN
  になる可能性があり、本サイクルでは skip（Req 2.6）して次サイクルで auto-merge を試行

の流れになります。

## テスト方針

### gh stub の組み方

既存 `pr_publish_commit_status_test.sh` / `full_auto_enabled_test.sh` のイディオムを踏襲:

- `extract_function` で対象関数を 1 つずつ awk 抽出して eval ロード
- `gh()` / `timeout()` / `am_log()` / `am_warn()` を bash 関数で stub
- `GH_CALL_LOG` / `LOG_OUT` / `WARN_OUT` に呼び出し履歴・出力をリダイレクト
- `count_calls` / `count_logs` で観測

### 検証観点と AC の対応表

| Test Section | 検証する AC | ケース数 |
|---|---|---|
| Section 1: `am_resolve_gate_enabled` | Req 1.2 / 1.3 / NFR 1.1（値正規化、安全側 OFF） | 15 |
| Section 2: `am_should_enable_for_pr` | Req 2.1〜2.6 / Req 4.2 / 4.3 / 4.5 | 10 |
| Section 3: `am_enable_auto_merge_for_pr` | Req 3.1 / 5.1 / 5.2 / 5.4 / 5.5 / 7.1 / NFR 1.3 | 11 |
| Section 4: `process_auto_merge` 統合 | Req 1.3 / 1.4 / 6.1 / 7.2 / 7.3 / 3.1 / 4.5 / 2.x（PR list → enable 経路） | 20 |
| **合計** | | **56 ケース** |

全ケース PASS を `bash local-watcher/test/auto-merge_test.sh` で確認済み（下記検証結果）。

## 検証結果

### shellcheck（warning ゼロ目標）

```bash
$ shellcheck local-watcher/bin/modules/auto-merge.sh \
             local-watcher/bin/issue-watcher.sh \
             install.sh setup.sh
$ echo $?
0
```

→ warning ゼロ（accepted baseline の SC2317 / SC2012 は `.shellcheckrc` で抑止済み）。

### bash 構文チェック

```bash
$ bash -n local-watcher/bin/modules/auto-merge.sh
$ bash -n local-watcher/bin/issue-watcher.sh
$ bash -n local-watcher/test/auto-merge_test.sh
```

すべて exit 0。

### auto-merge_test.sh

```bash
$ bash local-watcher/test/auto-merge_test.sh
...
==================================================
RESULT: PASS=56 FAIL=0
==================================================
```

### 既存テスト regression check

```bash
$ for t in local-watcher/test/*_test.sh; do bash "$t" >/dev/null 2>&1 || echo "FAIL: $t"; done
$ # PASS=28 FAIL=0
```

28 test files すべて PASS、regression なし。

### root ↔ repo-template 同期確認

```bash
$ diff -r .claude/agents repo-template/.claude/agents | wc -l
0
$ diff -r .claude/rules repo-template/.claude/rules | wc -l
0
```

byte 一致（変更なしのため当然の結果）。本 Issue では `.claude/{agents,rules}` 配下に変更は
入れていないため二重管理の同期は影響なし。

## AC Traceability

| 要件 ID | 担保 |
|---|---|
| Req 1.1 | `issue-watcher.sh` の Config ブロックで `AUTO_MERGE_ENABLED="${AUTO_MERGE_ENABLED:-false}"` を宣言 |
| Req 1.2 / 1.3 | `am_resolve_gate_enabled` / auto-merge_test.sh Section 1（15 ケース） |
| Req 1.4 | `process_auto_merge` 入口で `full_auto_enabled` を先評価 / Section 4 Case B |
| Req 1.5 / 6.1 | gate OFF で gh API 呼び出しゼロ / Section 4 Case A, C |
| Req 2.1 | head pattern client-side filter / Section 2 / 4 Case H |
| Req 2.2 | `LABEL_READY` ラベルチェック / Section 2 / 4 Case G |
| Req 2.3 | `isDraft == true` 除外 / Section 2 / 4 Case F |
| Req 2.4 | `mergeable == "MERGEABLE"` のみ通す / Section 2, 4 |
| Req 2.5 | CONFLICTING skip / Section 2, 4 Case E |
| Req 2.6 | UNKNOWN skip / Section 2 |
| Req 3.1 | `gh pr merge --auto --squash --delete-branch` / Section 3, 4 Case D |
| Req 3.2 / 3.3 / 3.4 | 直接 branch merge / push / `git merge` を行わない設計（コード上に該当呼び出しなし）。auto-merge state machine に委ねる |
| Req 4.1 | `needs-rebase` ラベルへの add/remove/rename 呼び出しゼロ（コード上 `LABEL_NEEDS_REBASE` 参照なし） |
| Req 4.2 / 4.3 | `claude-failed` / `needs-decisions` server-side + client-side 除外 / Section 2 |
| Req 4.4 | review dismissal API 呼び出しゼロ（コード上に該当呼び出しなし） |
| Req 4.5 | `autoMergeRequest` フィールド非 null 時の冪等 skip / Section 2 / Section 4 Case J |
| Req 5.1 / 5.2 / 5.5 | 3 種類の WARN ログ書き分け / Section 3 / Section 4 Case K |
| Req 5.3 | `am_enable_auto_merge_for_pr` の戻り値 1 でも process_auto_merge は while ループを継続（fail-continue） |
| Req 5.4 | silent fail させない（stderr 内容を WARN ログに残す） / Section 3 |
| Req 6.2 | gate OFF 経路で他 processor のログ / ラベル遷移 / exit code を変更しないことを、call site が `|| am_warn ...` で example wrap した既存パターンと同様の方法で担保 |
| Req 6.3 | head pattern client-side filter / Section 4 Case H, I |
| Req 6.4 | merge-queue / auto-rebase / pr-iteration / pr-reviewer の関数契約に手を入れず、新規 processor を直列追加するのみ |
| Req 7.1 | 成功ログ `auto-merge enabled (squash, delete-branch) head=... sha=... url=...` / Section 3 |
| Req 7.2 | `suppressed by AUTO_MERGE_ENABLED gate (no-op)` 1 行 / Section 4 Case C |
| Req 7.3 | FULL_AUTO_ENABLED OFF 起因では auto-merge 側ログを出さない（#348 既存ログに委譲）/ Section 4 Case B |
| Req 7.4 | cycle startup ログに `auto-merge=${AUTO_MERGE_ENABLED}` を含める |
| NFR 1.1 | `jq -e --arg l "$LABEL_..."` 経由のみ。filter 文字列に inline 展開なし |
| NFR 1.2 | `gh pr merge ... -- "$pr_number"` で `--` 打ち切り |
| NFR 1.3 | `am_enable_auto_merge_for_pr` / `process_auto_merge` で `^[0-9]+$` 検証 / Section 3 |
| NFR 1.4 | head branch を `AUTO_MERGE_HEAD_PATTERN` で grep -E 検証してから使用 |
| NFR 2.1 / 2.2 / 2.3 | 既存 env var / ラベル / 関数契約に変更を加えず、新規追加のみ |
| NFR 3.1 | 1 PR あたり最大 1 回の `gh pr merge --auto` 呼び出し（冪等 skip も含む）/ Section 4 Case J |
| NFR 3.2 | polling ループ / sleep / バックグラウンドプロセスなし（コード上に該当なし）|
| NFR 4.1 / 4.2 | README に詳細セクション追加（前提となる repo 設定 / required status checks 説明含む） |
| NFR 4.3 | `.claude/{agents,rules}` 配下に変更なし、`diff -r` 空 |
| NFR 5.1 | shellcheck / bash -n クリーン |
| NFR 5.2 | `local-watcher/test/auto-merge_test.sh` 56 ケース全 pass |
| NFR 6.1 | `install.sh` は `*.sh` glob で modules を配置するため新規ファイル追加で自動配布 |
| NFR 6.2 | `REQUIRED_MODULES` 配列に `auto-merge.sh` 追加済み |

## 確認事項

なし。要件 / 既存実装ともに矛盾は見つかりませんでした。`AUTO_MERGE_HEAD_PATTERN` の既定値
は要件 2.1 の文言通り `^claude/issue-.*-impl` を採用しましたが、`PR_ITERATION_HEAD_PATTERN`
の `^claude/issue-[0-9]+-impl-` のような厳格化を後続 Issue で検討する余地はあります
（本 Issue では Out of Scope）。

STATUS: complete
