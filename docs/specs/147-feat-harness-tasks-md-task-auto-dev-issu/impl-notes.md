# Implementation Notes — #147 Tasks Count Gate

## 概要

Architect が `tasks.md` を確定した直後（design モードの Claude 実行 rc=0 直後）に watcher 側で
タスク件数を機械的に再カウントし、件数レンジに応じて 3 段階の運用判定（通常 / 警告 / Developer
抑止）を適用する harness 側ガードを `local-watcher/bin/issue-watcher.sh` に追加した。

実装は `tc_*` prefix の独立ドメインとして 9 関数 + 4 env var で構成し、`_slot_run_issue` の
design 分岐 rc=0 case に 1 行 hook を差し込むのみで本体ロジックは新規ドメインに閉じている。
fail-open かつ opt-out 可（`TC_ENABLED=false`）で、後方互換性を NFR 2.1 / NFR 2.2 で保証する。

## 主要な実装判断

### 1. count regex は #131 と共有せず独立に定義した

Issue #131（Architect 側 budget overflow check）と本機能（#147）は count 対象が異なる:

- #131: 最上位タスクのみ（regex: `^- \[ \]\*? [0-9]+\. ` — ID 末尾の `.` を必須化）
- #147: 親子フラット展開 + 4 種 checkbox（regex: `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` — ID
  末尾の `.` を `\.?` でオプショナル化、checkbox は `[ ]` / `[x]` / `[ ]*` / `[x]*` を許容）

両者は **同じ checkbox 規約**（`tasks-generation.md` の checkbox enforcement check）に依拠
しているが、Architect 段階（上位 task の budget 推定）と harness 段階（全 task の turn budget
推定）で count の意味が異なるため、関数を共有せず独立に実装した（design.md L52-54 と整合）。

### 2. fail-open 方針で watcher 全体を止めない

`tc_run_post_architect_check` および配下 9 関数すべての戻り値を 0 に固定（`|| true` 等で
吸収）。gh CLI 失敗・grep 失敗・閾値 env var 非整数・unknown classification 等のいずれでも
warning ログを残して続行する。本機能起因で `claude-failed` 等の障害状態に陥らないことを
構造的に保証する。

### 3. resume 経路の skip は hook 配置で構造保証

Req 3.1 / 3.2（impl-resume / Stage Checkpoint Resume 経路では skip）は、`tc_run_post_architect_check`
の hook を `_slot_run_issue` の **design 分岐 rc=0 case にのみ** 配置することで構造的に保証
した。`if [ "$MODE" = "design" ]` ブロックの外（impl / impl-resume / run_impl_pipeline）には
1 行も追加していないため、resume 経路から本機能が起動することはない。

これは「環境変数の動的判定 + 関数内 skip」よりもセルフ explanatory で、後の保守者が
「resume 経路では本当に呼ばれないか？」を grep で機械的に確認できる利点がある。

### 4. 冪等性は固定識別マーカーで実装

`gh issue view --json comments --jq` でコメント本文を取得し、`grep -qF` で固定マーカー
`<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> issue=<N> ... -->` を検知する。
これにより:

- 同一 Issue への重複コメント投稿を防ぐ（Req 2.6）
- マーカー本文は NFR 1.2 の「本機能由来判別文字列」を兼ねる（コメント本文の最後に必ず付与）
- `kind=warning` と `kind=escalation` を別マーカーで管理することで、warn → escalate の昇格
  時にも適切に追加コメントできる

gh API が失敗した場合は marker absent として扱う（最悪重複コメント投稿のみ。watcher 全体は
止めない）。

### 5. `needs-decisions` ラベルは既存運用と共有

新ラベルは追加せず、既存 `LABEL_NEEDS_DECISIONS`（`needs-decisions`）を流用した（NFR 2.2）。
これにより:

- 既存の Issue 候補抽出 query（`-label:"$LABEL_NEEDS_DECISIONS"`）が改変なしで本機能由来の
  抑止にも作用する（Req 2.4 を構造的に保証、design.md L186-188 と整合）
- PM / Architect (#131) / 本機能 (#147) の 3 起源が共有するが、コメント本文のマーカーで
  本機能由来かを後段運用で識別可能（NFR 1.2）
- ラベル名変更による cron / launchd 設定の改変を発生させない

副作用として、`needs-decisions` の意味が「人間判断要請」の傘下で多重化する。Open Questions
2（補助ラベル `tasks-count-overflow` の併用可否）が残るが、本実装ではコメント本文の識別
文字列のみで判別する設計を採用した。

### 6. 閾値 env var は `${VAR:-default}` で override 可能、非整数は fail-safe で既定値

`TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` は CLAUDE.md の bash
規約に従って `"${VAR:-default}"` で外部 override 可能にしつつ、`tc_classify` 関数内で
`[[ "$x" =~ ^[0-9]+$ ]]` による整数検証を行う。非整数値（typo / 空文字 / `abc` 等）は
`tc_warn` で警告を出して既定値（8 / 10 / 11）にフォールバックする（safety-net）。

## 実施した検証

### 静的解析

- `shellcheck -S warning local-watcher/bin/issue-watcher.sh`: warning / error ゼロ
- `shellcheck tests/local-watcher/tasks-count/extract-driver.sh`: warning / error ゼロ
- `shellcheck tests/local-watcher/tasks-count/perf-driver.sh`: warning / error ゼロ

### 単体テスト（extract-driver.sh）

`tests/local-watcher/tasks-count/extract-driver.sh` で全 16 ケース pass:

- fixture 6 件（tasks-7 / 8 / 10 / 11 / empty / mixed-checkbox）の count + classification
- classify 境界値 7 件（0 / 7 / 8 / 9 / 10 / 11 / 50）
- 閾値 env var 非整数 fallback（`TC_WARN_LOWER="abc"` で `classify(9) → warn`）
- count 非整数 fallback（`classify("not-an-int") → normal`）
- tc_count_tasks のファイル不在 return 1

### パフォーマンステスト（perf-driver.sh）

`tests/local-watcher/tasks-count/perf-driver.sh` で約 1.3 MB の tasks.md（20000 task lines）
に対する `tc_count_tasks` の wall clock を計測:

- 実測: 2ms（NFR 3.1 の 1 秒上限を大幅に下回る）
- `grep -cE` 単発実行が支配的で線形 O(N) 性能

### 回帰確認

- 既存 `tests/local-watcher/stage-a-verify/extract-driver.sh`: 12/12 pass（regression なし）
- design 分岐 rc=0 case 以外への hook 追加なし（`grep -n "tc_run_post_architect_check" .../issue-watcher.sh` で 4 件中、本体は 6056 行の関数定義と 10471 行の hook 1 箇所のみ）
- 既存 env var 名・ラベル名・cron 起動文字列は不変

## 確認事項（人間レビュアー向け）

### Issue 本文「確認事項」3 件への実装上の所感

1. **閾値 7 / 10 / 11 の妥当性**: KeyNest 3 事例由来の暫定値を採用。実装は env var で簡単に
   調整可能（`TC_WARN_UPPER=12 TC_ESCALATE_LOWER=13` 等）にしたため、観測フィードバックに
   基づく事後調整は cron 設定の env 追加だけで完結する。継続観測のフィードバック経路（どの
   ログを集計するか、どの Issue に再評価提案を投げるか）は本 PR のスコープ外。README の
   Migration Note に「閾値が repo の実情に合わないと感じた場合は個別調整可能」と注記済み

2. **`needs-decisions` ラベルの意味多重化**: 補助ラベル `tasks-count-overflow` の併用は本 PR
   では採用せず、コメント本文の固定識別文字列（`<!-- idd-claude:tasks-count-overflow ... -->`）
   のみで本機能由来を判別する設計とした（NFR 1.2 と整合）。後段運用で件数集計が必要に
   なった場合、`grep '\[.*\] tasks-count:' logs/` で `count=<N> range=escalate` 行を集計
   する方が `gh issue list --label` よりも詳細な情報（件数・時刻・issue 番号）が取れるため、
   現状はコメント識別子で十分と判断した。補助ラベルの追加判断は別 Issue で

3. **警告コメント（8〜10 件）の false positive 救済経路**: 同一 Issue への警告再投稿の抑止は
   コメント本文の固定マーカーで実装した（1 回投稿後は kind=warning マーカーが存在するため
   再投稿されない、Req 2.6）。「再カウントで件数が変化したら再投稿するか」については本機能
   では実装せず、件数が変動した場合も初回投稿の警告コメントが残るのみとする設計とした。
   理由: design モードは PjM 完了後に基本的に再走しないため再カウントの機会が稀で、再カウント
   時の件数差分提示の運用価値が低いと判断。必要なら別 Issue で対応

### tasks.md / design.md / requirements.md との整合

- Task 1〜8 を numeric ID 順に消化し、tasks.md の checkbox を `- [ ]` → `- [x]` に更新
- Task 6 親タスクは子タスク 6.1 / 6.2 完了時に親も `- [x]` に更新
- Task 8 は deferrable（`- [ ]*`）だが実施し `- [x]*` に更新
- design.md / requirements.md / tasks.md の本文は **書き換えていない**

### 既知の保留事項

- design.md L182-183（Requirements Traceability 表の Req 2.4 行）で「（既存 watcher Issue
  候補抽出 query）」と記載されているが、これは既存 `_dispatcher_run` の query が
  `-label:"$LABEL_NEEDS_DECISIONS"` を含むことで構造的に保証されており、本機能で追加変更は
  不要。実装の挙動として確認済み（grep で `LABEL_NEEDS_DECISIONS` の `-label:` 利用を確認）

- `tc_post_*_comment` の本文に絵文字（⚠️ / 🚫）を使用している。CLAUDE.md「絵文字はステータス
  表示に限定して節度を持つ」のガイドラインに沿った最小限の使用と判断したが、レビュー時に
  本文絵文字の有無について確認可能。なお、PR レビュー時の Reviewer エージェントは
  CLAUDE.md「絵文字を使用しない」既定方針に従うが、ここでの絵文字は **Issue コメントに
  投稿される運用者向けメッセージ** であり、Claude 出力ではないため整合する

## 受入基準カバレッジ

すべての requirement numeric ID と担保テスト・実装の対応:

| Req ID | カバレッジ | 場所 |
|---|---|---|
| 1.1 | `tc_run_post_architect_check` が design rc=0 hook で起動、`tc_count_tasks` を呼ぶ | issue-watcher.sh L6056 + L10471 hook |
| 1.2 | 4 種 checkbox + numeric ID 行の regex `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` | issue-watcher.sh L5876 / extract-driver.sh tasks-mixed-checkbox.md |
| 1.3 | 親子フラット展開（小数階層 ID） | extract-driver.sh tasks-mixed-checkbox.md（8 件で `1` / `1.1` / `1.2` / `2.1` 等を含む） |
| 1.4 | `(P)` マーカー同列 | extract-driver.sh tasks-mixed-checkbox.md（`1.2 (P)` 含むが count=8） |
| 1.5 | tasks.md 不在で skip + reason ログ | `tc_should_run` の `[ ! -f "$tasks_path" ]` 分岐 / extract-driver.sh missing-file ケース |
| 1.6 | 件数・閾値レンジ追跡可能ログ | `tc_run_post_architect_check` の `tc_log "count=$count range=$range action=..."` 形式 |
| 2.1 | 7 件以下で追加アクションなし | extract-driver.sh tasks-7.md (count=7 class=normal) / classify(0/7)=normal |
| 2.2 | 8〜10 件で警告コメント | extract-driver.sh tasks-8/10.md / classify(8/9/10)=warn / `tc_post_warning_comment` |
| 2.3 | 11 件以上で needs-decisions + escalation comment | extract-driver.sh tasks-11.md / classify(11/50)=escalate / `tc_post_escalation_comment` + `tc_add_needs_decisions_label` |
| 2.4 | needs-decisions 中の Dev 抑止 | 既存 `_dispatcher_run` の `-label:"$LABEL_NEEDS_DECISIONS"` query を流用（構造的） |
| 2.5 | エスカレーションコメント本文 | `tc_post_escalation_comment` 本文（件数 / 閾値 / 抑止フェーズ / 回復手順 3 種） |
| 2.6 | 既存 needs-decisions に重複適用しない | `tc_should_run` の label 既存検知 + `tc_already_posted_marker_present` 二重ガード |
| 3.1 | impl-resume で skip | hook 配置の構造保証（impl-resume 分岐に hook なし） |
| 3.2 | Stage Checkpoint Resume で skip | hook 配置の構造保証（design 分岐内側にのみ配置） |
| 3.3 | skip 理由ログ | `tc_should_run` 内の `tc_log "skip reason=..."` 3 形式 |
| 4.1 | 7 件以下で導入前と同一挙動 | classify=normal で tc_log のみ、副作用なし |
| 4.2 | 有効・無効切替手段 | `TC_ENABLED` env var + README cron 例 |
| 4.3 | README migration note | README.md L3206-3367 `## Tasks Count Gate (#147)` 節 |
| 4.4 | #131 由来 needs-decisions に重複適用しない | `tc_should_run` の label 既存検知（起源を区別せず skip） |
| NFR 1.1 | `tasks-count:` prefix で grep 可能 | `tc_log` の `[YYYY-MM-DD HH:MM:SS] [$REPO] tasks-count:` 3 段 prefix |
| NFR 1.2 | コメント本文に固定識別文字列 | `<!-- idd-claude:tasks-count-overflow kind=<warning|escalation> ... -->` |
| NFR 2.1 | 既存 env var 名互換 | 新規 `TC_*` のみ追加、既存名変更なし |
| NFR 2.2 | 既存ラベル遷移契約不改変 | 既存 `LABEL_NEEDS_DECISIONS` 流用、新ラベル追加なし |
| NFR 3.1 | カウント 1 秒以内 | perf-driver.sh: 1.3 MB / 20000 行で 2ms |

## 関連ファイル

- `local-watcher/bin/issue-watcher.sh` — Config block + tc_* 9 関数 + design 分岐 hook
- `tests/local-watcher/tasks-count/fixtures/tasks-7.md` 〜 `tasks-mixed-checkbox.md` — 6 fixture
- `tests/local-watcher/tasks-count/extract-driver.sh` — 16 ケースの回帰テスト
- `tests/local-watcher/tasks-count/perf-driver.sh` — NFR 3.1 計測 driver
- `README.md` — `## Tasks Count Gate (#147)` 節 + 標準有効一覧表エントリ
- `docs/specs/147-feat-harness-tasks-md-task-auto-dev-issu/tasks.md` — 全タスク `- [x]` 化済み
