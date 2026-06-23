# Impl Notes — Issue #388 (Slack auto-merge armed/merged 誤読バグ修正)

## 採用した設計判断

### 1. armed event_type のスタンス（Open Question #3 / Req 1.x）

**採用**: 既存 `auto-merge` / `auto-merge-design` の event_type 名は **温存**し、`result` 値だけを `success` → `armed` に切り替え、detail に `armed (squash on green checks) head=<ref> sha=<sha>` を明示する。

**根拠**:
- 機械パーサ調査: `result=success` を期待する consumer は OSS テンプレ / README / コードベース内に存在せず（`grep -rn "result=success"` 結果は本 spec ファイル + テストのみ）
- event_type 名（`auto-merge` / `auto-merge-design`）の互換維持で既存 Slack ダッシュボード / ログ集約フィルタが壊れない
- `result` 値の変化は payload 内容の変化であり、Slack の **表示文面に直接反映**される（人間が「armed」と読める）
- 旧 `result` 値 enum (`success` 等) は `sn_build_payload` で温存（後方互換 / Req 3.5）

### 2. merge 完了検知方式（Open Question #1 / Req 2.x）

**採用**: 推奨案どおり **「auto-merge enable 成功時に PR 番号を state file へ積み、後続サイクルで `gh pr view <N>` で `state=MERGED` を観測した PR のみ通知 → state から除去」** 方式。

**根拠**:
- `gh pr list --search merged:>` 走査は**他人/手動 merge した無関係 PR**も結果に含めるリスクがあり、Req 2.4（auto-merge 経路外は通知しない）と整合させにくい
- state file 方式は「auto-merge enable で armed した PR のみを pending として観測」する単純規約で、人間 merge は state に積まれず自然に除外される（Req 2.4 を構造的に担保）
- NFR 1.1（idempotency）は **state file 削除を 1 度限り通知のフラグ**として扱うことで簡潔に実装

**state file 配置**: `$HOME/.issue-watcher/auto-merge-pending/<repo-slug>/pr-<N>.json`（CLAUDE.md §6 / NFR 4.4 準拠）。同 dir 上 `mktemp` → `mv -f` で atomic write（既存 `failed-recovery.sh` の `fr_save_state` と同パターン）。

**JSON schema**: `{ pr, event_type, head_ref, head_sha, url, armed_at }`。armed 時点の URL を保存することで、merge 完了通知時に同 URL（PR ページ）を再利用する。

### 3. opt-in gate 戦略（Open Question #3 / Req 3.4）

**採用**: **2 段 opt-in を採る**:

| Gate | 制御対象 | 既定値 |
|---|---|---|
| `SLACK_NOTIFY_ENABLED=true` | armed 文面修正（既存通知の `result` 値変更）と Slack 通知全体 | `false` |
| `SLACK_NOTIFY_MERGED_ENABLED=true` | merged 通知 + pending state file 書込 + pending poller | `false`（**完全 opt-in / Req 3.4 / NFR 4.1**） |

**根拠**:
- armed 文面の修正は **本 issue の主目的**（誤読バグ解消）であり、`SLACK_NOTIFY_ENABLED=true` 配下で常時適用するのが運用者にとって自然
- 一方で merged 通知の **新規発火**は外部副作用（curl 増加）であり、既存ユーザに無断で発火させると CLAUDE.md「禁止事項」の「opt-in gate なしで新しい外部サービス呼び出しを有効化」に抵触する恐れがある
- したがって新規 merged 通知は別 env `SLACK_NOTIFY_MERGED_ENABLED` で opt-in 化（既定 false で本機能導入前と完全に等価 / NFR 4.1）
- `SLACK_NOTIFY_MERGED_ENABLED=true` 単体では何も起こらない（emitter 全体の gate である `SLACK_NOTIFY_ENABLED=true` が AND で必要）

### 4. design PR の扱い（Open Question #4 / Req 1.2, 2.2）

**採用**: impl PR と完全に対称。`auto-merge-design` armed callsite も `result=armed` + 同 detail を渡し、`auto-merge-design-merged` event_type で実 merge 完了を通知。`amm_save_pending` を `auto-merge-design.sh` の rc=0 path にも追加。

### 5. 新モジュール切り出し

**採用**: `modules/auto-merge-merged.sh`（prefix namespace `amm_`）に切り出し。`amm_save_pending` を `auto-merge.sh` / `auto-merge-design.sh` の rc=0 path から `declare -F amm_save_pending >/dev/null` ガード越しに呼ぶ。

**根拠**:
- state 管理ロジック（mkdir / atomic write / jq schema / list / check）が 1 module 分の独立した責務を持つ
- 既存 `auto-merge.sh` / `auto-merge-design.sh` には **1 行 hook**（`amm_save_pending` 呼び出し）だけ追加することで責務を分離（CLAUDE.md §1, §2「機能追加ガイドライン」準拠）
- prefix `amm_` は未使用の 2 文字（既存 `am_`, `amd_` と区別可能）

## 後方互換性メモ（既存ユーザへの影響）

### `SLACK_NOTIFY_ENABLED=false` / 未設定の既存ユーザ
- **影響なし**。本修正の有無に関わらず外部副作用ゼロ（NFR 4.1 を test で担保: `auto-merge-merged_test.sh` Section 11 Case A）
- `amm_save_pending` も `amm_resolve_gate_enabled` が rc=1 を返すため state file を書かない（test で担保: `auto-merge-merged_test.sh` Section 3）

### `SLACK_NOTIFY_ENABLED=true` の既存ユーザ
- **影響あり / migration**: armed 通知の `result` 値が `success` → `armed` に変わる（Slack ダッシュボードや手動 grep フィルタで `result=success` を頼っていた場合は `result=armed` に更新が必要）
- detail に `armed (squash on green checks) head=<ref> sha=<sha>` が含まれるため、Slack 上で「これは merge 完了ではない」と読める
- 新 merged 通知は **発火しない**（`SLACK_NOTIFY_MERGED_ENABLED` が未設定なので）

### `SLACK_NOTIFY_ENABLED=true` + `SLACK_NOTIFY_MERGED_ENABLED=true` のオプトインユーザ
- pending state file が `$HOME/.issue-watcher/auto-merge-pending/<repo-slug>/pr-<N>.json` に積まれる（disk usage は PR 数 × ~256 byte 程度）
- 後続サイクルで `gh pr view <N>` 呼び出しが pending 件数分発生（1 サイクルあたり既定上限 `AUTO_MERGE_MERGED_MAX_CHECKS=50` / NFR 3.2）
- merge 完了が観測されると Slack に 1 通の `auto-merge-merged` / `auto-merge-design-merged` 通知が送信される

### Migration note 所在
- README.md「オプション機能一覧」の Slack 通知 emitter 行（line 1371）に Migration Note 段落で記載
- README.md Auto-Merge Processor (#352) 節（line 2363 直後）に「用語整理 (#388)」段落で armed / merge 完了の区別を説明

### `repo-template/` への波及
- `repo-template/local-watcher/` は存在しない（`ls` で確認済み）
- `repo-template/.claude/{agents,rules}` は本 issue 対象外（指示通り）
- `repo-template/.github/workflows/issue-to-pr.yml` には影響なし（gh pr view は local-watcher 側のみで使う）

## AC Traceability

### Requirement 1: armed 通知の誤読防止

| AC | 実装場所 | 対応テスト |
|---|---|---|
| 1.1 | `local-watcher/bin/modules/auto-merge.sh` L184-189（armed callsite に result=armed + detail "armed (squash on green checks)"） | `auto-merge_test.sh` Section 3「#388 Req 1.1: armed callsite は result=armed を渡す」/「#388 Req 2.1: armed 成功時に amm_save_pending」`sn_build_payload_388_test.sh` Section 4 |
| 1.2 | `local-watcher/bin/modules/auto-merge-design.sh` L196-201（同上 design 版） | `auto-merge-design_test.sh` Section 3「#388 Req 1.2: design armed callsite は result=armed」 |
| 1.3 | armed detail 文言 `armed (squash on green checks) head=<ref> sha=<sha>` を `auto-merge.sh` / `auto-merge-design.sh` の sn_notify 呼び出しで明示 | `auto-merge_test.sh` Section 3 / `auto-merge-design_test.sh` Section 3「#388 Req 1.3: detail に armed 明示文言」/ `sn_build_payload_388_test.sh` Section 4「Req 1.3: armed blocks[0].text に「armed (squash on green checks)」」 |
| 1.4 | `slack-notify.sh` `sn_build_payload` の enum 検証は変更せず `auto-merge-merged` / `auto-merge-design-merged` を追加（`sn_build_payload` L117-122 / Req 3.5 と同形） | `sn_build_payload_388_test.sh` Section 1-3（新 enum 受理 / 既存 enum 受理 / 不正値 rejection） |

### Requirement 2: 実 merge 完了通知の追加

| AC | 実装場所 | 対応テスト |
|---|---|---|
| 2.1 | `auto-merge-merged.sh` `amm_check_one_pending` L221-263（MERGED 観測時に sn_notify 1 回 + amm_remove_pending）/ `auto-merge.sh` L189-191（armed 成功時 amm_save_pending hook） | `auto-merge-merged_test.sh` Section 6「Req 2.1: MERGED 観測で sn_notify 1 回発火」/ Section 4「Req 2.1: state file が atomic に書かれる」/ `auto-merge_test.sh`「#388 Req 2.1: amm_save_pending が auto-merge-merged event_type で呼ばれる」 |
| 2.2 | 同上 design 版: `auto-merge-design.sh` L199-201 / `amm_check_one_pending` は event_type 別 enum を読んで通知 | `auto-merge-merged_test.sh` Section 6「Req 2.2: design merged 観測 event_type=auto-merge-design-merged」/ `auto-merge-design_test.sh`「#388 Req 2.2: amm_save_pending が auto-merge-design-merged event_type で呼ばれる」 |
| 2.3 | `amm_check_one_pending` は通知発火後に `amm_remove_pending` を呼んで state file を削除（state 削除＝重複抑止の証跡） | `auto-merge-merged_test.sh` Section 6「Req 2.3: merged 通知発火後に state file 削除」/「NFR 1.2: 同一 PR の 2 回目観測で sn_notify 呼ばれない」 |
| 2.4 | state file は `amm_save_pending` でしか書かれない（auto-merge.sh / auto-merge-design.sh の armed 成功 path のみで呼ばれる）。人間が `gh pr merge` で手動 merge した PR は state に積まれていないため `process_auto_merge_merged` は何も発火しない | `auto-merge-merged_test.sh` Section 8「Req 2.4 同等: CLOSED（unmerged）観測で通知なし」/ Section 11 のテストは pending を最初から積まないと通知が出ないことを統合検証 |
| 2.5 | `amm_resolve_gate_enabled` が rc=1 を返す path で `amm_save_pending` も `amm_check_one_pending` も `process_auto_merge_merged` も外部副作用ゼロで return | `auto-merge-merged_test.sh` Section 3「NFR 4.1: gate OFF で state file は作られない」/ Section 11 Case A「merged gate OFF で gh ゼロ呼び出し」 |
| 2.6 | `amm_resolve_gate_enabled` は emitter 全体の URL preflight に到達する前段で gate OFF 判定するが、`sn_notify` 呼び出し時にも `sn_notify` 側の既存 URL preflight が走るため WARN 1 行 + fail-open（Req 4.1, 4.2 規約継承） | `sn_notify_test.sh` Section 2「Req 1.4: URL 未設定で curl 不呼出 + WARN」（既存テスト / 本 issue で追加変更なし） |

### Requirement 3: 後方互換性と opt-in 戦略

| AC | 実装場所 | 対応テスト |
|---|---|---|
| 3.1 | `amm_resolve_gate_enabled` `case "${SLACK_NOTIFY_ENABLED:-false}"` の二重判定 | `auto-merge-merged_test.sh` Section 1「両 env 未設定で disabled」/「SLACK_NOTIFY_MERGED_ENABLED 未設定で disabled」 |
| 3.2 | `slack-notify.sh` の env 名 (`SLACK_NOTIFY_ENABLED` / `SLACK_WEBHOOK_URL` / `SLACK_NOTIFY_TIMEOUT`) と既定値は無変更（grep 確認済み） | 既存 `sn_notify_test.sh` / `sn_is_enabled_test.sh` がそのまま通る |
| 3.3 | `failed-recovery` / `needs-decisions-auto-continue` / `promote` の event_type / result は無変更。`sn_build_payload` の enum に新値を追加するだけ | 既存 `sn_callsite_promote_test.sh` がそのまま通る / `sn_build_payload_388_test.sh` Section 2「既存 event_type 後方互換」 |
| 3.4 | README.md「オプション機能一覧」Slack 通知 emitter 行 + Auto-Merge Processor (#352) 節に migration note 追記（同一 PR） | README diff（本 commit に含まれる）で確認 |
| 3.5 | `sn_build_payload` の enum 検証は `case ... in ... ;; *) sn_warn + return 1 ;; esac` のまま。新 event_type を 1 行追加するのみ | `sn_build_payload_388_test.sh` Section 1（受理）/ Section 3（不正値 rejection） |

### Requirement 4: 観測性と silent fail 禁止の継承

| AC | 実装場所 | 対応テスト |
|---|---|---|
| 4.1 | `amm_log` で MERGED 観測時に構造化 1 行を出力。`sn_notify` 側の既存 `sn_log` で event/number/result/http_status/host が出る（既存規約継承） | `auto-merge-merged_test.sh` Section 6 で MERGED 観測時の amm_log を観測 / 既存 `sn_notify_test.sh` Section 3 が構造化ログを担保 |
| 4.2 | `amm_check_one_pending` の `gh pr view` 失敗時は `amm_warn` 1 行 + return 0（state file 維持で次サイクル再試行）。`sn_notify` 失敗は既存 fail-open 規約に従う | `auto-merge-merged_test.sh` Section 9「NFR 4.2: gh 失敗で sn_notify 呼ばれない / state file 維持」 |
| 4.3 | `sn_build_payload` の既存 `sn_scrub_secrets` を新 event_type でも通る（共通 payload 経路） | `sn_build_payload_388_test.sh` Section 6「Req 4.3: 新 event_type でも detail 内の ghp_ token が [REDACTED] に置換」 |
| 4.4 | `amm_save_pending` / `amm_check_one_pending` のログには webhook URL 自体を渡さない（sn_notify が host のみログに出す既存規約継承） | 既存 `sn_notify_test.sh` Section 8 が webhook URL の secret token 非露出を担保 |

### NFR

| NFR | 実装場所 | 対応テスト |
|---|---|---|
| NFR 1.1 | `amm_check_one_pending` は MERGED 観測 → `sn_notify` 1 回 → `amm_remove_pending` の順。state file 削除で重複抑止 | `auto-merge-merged_test.sh` Section 6「NFR 1.2: 同一 PR の 2 回目観測で sn_notify 呼ばれない」 |
| NFR 1.2 | 同上 | 同上 |
| NFR 2.1 | `amm_log` の構造化 1 行（既存 `sn_log` と整合） | `auto-merge-merged_test.sh` Section 6 で `amm_log` 出力を観測 |
| NFR 2.2 | `amm_warn` は `>&2` に出力（既存 `sn_warn` と整合） | `auto-merge-merged_test.sh` Section 9 で gh 失敗時の `amm_warn` を観測 |
| NFR 3.1 | 新規 CLI 依存ゼロ（gh / jq / mktemp / mv / ls / rm のみ。すべて既存 module で使用済） | shellcheck / 既存依存 set 不変 |
| NFR 3.2 | `AUTO_MERGE_MERGED_MAX_CHECKS`（既定 50）で 1 サイクルあたりの `gh pr view` 上限を設定 | `auto-merge-merged_test.sh` Section 11 Case C「AUTO_MERGE_MERGED_MAX_CHECKS=2 で gh pr view は 2 回まで」 |
| NFR 3.3 | `SLACK_NOTIFY_TIMEOUT` は既存 sn_post_webhook で適用（変更なし） | 既存 `sn_notify_test.sh` Section 10 が timeout 正規化を担保 |
| NFR 4.1 | `SLACK_NOTIFY_MERGED_ENABLED` 未設定 / `=true` 以外で `amm_save_pending` / `process_auto_merge_merged` が外部副作用ゼロで return | `auto-merge-merged_test.sh` Section 3, Section 11 Case A |
| NFR 4.2 | `gh pr view` 失敗時 / MERGED but mergedAt 空 → 偽陽性禁止で次サイクル再試行（state file 維持） | `auto-merge-merged_test.sh` Section 9 の 2 ケース |

## 確認事項 / Open Questions

なし。

PM 要件で Developer 判断とされた箇所（merge 完了検知方式 / state 配置 / armed event_type 戦略 / opt-in 追加 gate の有無）はすべて「採用した設計判断」節で明記し、実装に反映した。

## 補足

### コミット内訳
1. `7e89818` — fix(slack-notify): armed/merged を区別し誤読を解消（実装本体）
2. `8450e39` — test(slack-notify): armed/merged 区別と新 event_type の単体テスト追加
3. `d1586ae` — docs(readme): Slack 通知 emitter 行に #388 armed/merged 区別の migration note を追記

### テスト集計
- 既存テスト: 4 件（`sn_notify_test.sh` 23, `sn_build_payload_test.sh` 44, `sn_callsite_promote_test.sh` 15, `sn_is_enabled_test.sh` 25, `auto-merge_test.sh` 60→65, `auto-merge-design_test.sh` 65→70）
- 新規テスト: 2 件（`sn_build_payload_388_test.sh` 23, `auto-merge-merged_test.sh` 54）
- 合計: PASS 319 / FAIL 0

### 静的解析
- `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh`: warning ゼロ
- `actionlint .github/workflows/*.yml`: warning ゼロ
- `bash -n` 全体: syntax error ゼロ

### 派生タスク候補（次の Issue として切り出す）
- `failed-recovery` / `needs-decisions-auto-continue` の `result` 文字列に同種の誤読リスクがあるかは未調査（PM 確認事項 #5）。必要なら別 issue で取り上げる
- `auto-merge-pending` state file の TTL（armed されたまま長期 OPEN の PR で state file が永続化される）は今回 implementation しなかった。`gh pr view` で CLOSED を観測すれば state 削除されるため、PR が close されない限り state が残るのは仕様。clean up 必要性が出れば別 issue で

STATUS: complete
