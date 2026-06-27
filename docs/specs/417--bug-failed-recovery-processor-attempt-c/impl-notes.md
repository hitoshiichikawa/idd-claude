# Implementation Notes — #417 Failed Recovery Processor terminate cross-cycle べき等化

## 設計判断

**採用方針: 仮案 C（state JSON 永続化 + ガード両刀）**

人間コメントの選択肢（A=state 管理 / B=列挙除外 / C=両刀）に対し、Developer が**両刀**を採用した。
理由は以下のとおり:

- **terminate 関数のべき等ガード単独（仮案 A）では不十分**: `fr_run_recovery_attempt` 内で
  着手コメント → 試行開始時 attempt++ → claude session 起動が走ってから `return 2` で
  terminate に到達する経路がある。AC は 2 サイクル目以降に「着手コメントも attempt 加算も
  claude session 起動もしない」(Req 2.1〜2.6) と明示しているため、**fetch 段階で物理的に
  除外する必要がある**。
- **列挙除外単独（仮案 B）では不十分**: 状態を読まない実装では候補列挙時の race condition
  （別 worker が同時に state を読み書き）で取りこぼしが発生しうる。terminate 関数側でも
  ガードしておく方が二重防御として安全であり、コード量も小さい。
- **両刀の追加コスト**: `fr_is_terminated` という純粋関数を 1 つ追加し、両方から呼ぶだけ
  なので技術的負債にならない。

### 既存 schema を変更しない（NFR 1.1）

state JSON の `last_status` enum はすでに `"max-attempts"` / `"no-progress"` を許容して
おり、`fr_save_state` 第 3 引数で書き込み済みである（既存 design.md Data Model 節）。
新フィールド追加は不要で、**既存 enum 値を terminate 時に永続化する経路を追加するだけ** で
要件を満たせる。

### state 不在 / 破損で fail-open（Req 5.1〜5.3）

`fr_load_state` は元から「不在 / parse 失敗で `{}` を返す」契約。本実装の `fr_is_terminated`
も `{}` を受け取ったら未終端として rc=1 を返すため、自然と fail-open になる。これにより
**state 破損が原因で動作不能になるリスクはない**（最悪、本変更導入前と同等の「毎サイクル
コメント再投稿」に退行するだけ / Req 5.3 fail-continue 維持）。

## 変更ファイル一覧

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/modules/failed-recovery.sh` | `fr_is_terminated` 純粋関数追加 / `fr_filter_terminated_candidates` 追加 / `fr_fetch_failed_issues` / `fr_fetch_failed_prs` の最終出力にフィルタ適用 / `fr_terminate_max_attempts` / `fr_terminate_no_progress` 冒頭にべき等ガード + 末尾に state 永続化を追加 |
| `local-watcher/test/fr_fetch_test.sh` | 新 helper `fr_filter_terminated_candidates` が未抽出で壊れたため、Issue #410「新規公開 IF 追加で壊れた既存テストの fixture 追従責務」に基づき pass-through stub を追加（テスト意図維持） |
| `local-watcher/test/fr_terminate_idempotent_test.sh` | 新規 regression test（64 ケース） |

`failed-recovery.sh` は `repo-template/` 配下にないため root 単独管理。同期作業なし
（grep / find で確認済み）。

## AC Traceability

| Req | カバー方法 |
|---|---|
| Req 1.1（2 サイクル目 max-attempts コメント非投稿） | `fr_terminate_max_attempts` 冒頭の `fr_is_terminated` ガード / `fr_terminate_idempotent_test.sh` Section 3 |
| Req 1.2（2 サイクル目 no-progress コメント非投稿） | `fr_terminate_no_progress` 冒頭の `fr_is_terminated` ガード / 同 Section 4 |
| Req 1.3（max-attempts 生涯 1 件） | cross-status ガードで担保 / 同 Section 5 |
| Req 1.4（no-progress 生涯 1 件） | 同上 / 同 Section 5 |
| Req 1.5（max-attempts 終端永続化） | `fr_terminate_max_attempts` 末尾の `fr_save_state` / 同 Section 2 |
| Req 1.6（no-progress 終端永続化） | `fr_terminate_no_progress` 末尾の `fr_save_state` / 同 Section 9 |
| Req 2.1（claude session 起動しない max-attempts） | `fr_filter_terminated_candidates` で fetch 段階除外 / 同 Section 7 |
| Req 2.2（claude session 起動しない no-progress） | 同上 / 同 Section 7 |
| Req 2.3（着手 / 結果コメント不投稿） | fetch 除外で `fr_run_recovery_attempt` 自体が呼ばれない / 同 Section 3-4 + 7 |
| Req 2.4（Slack 通知 emitter 再発火なし） | terminate ガード + fetch 除外 / 同 Section 3-4 |
| Req 2.5（attempt カウンタ加算なし） | fetch 除外で `fr_save_state` 呼び出し自体なし / 同 Section 7 |
| Req 2.6（run-summary 確定なし） | terminate ガード + fetch 除外 / 同 Section 3-4 + 7 |
| Req 3.1（max/no-progress/未終端の 3 状態判定） | `fr_is_terminated` 純粋関数 / 同 Section 1 |
| Req 3.2（プロセス再起動・再ログイン跨ぎで保持） | `fr_save_state` が `$HOME/.issue-watcher/` 配下 JSON ファイルに永続化（既存実装 / NFR 2.2 / NFR 2.3）。fr_state_test.sh で間接検証 |
| Req 3.3（terminate と同一サイクル内永続化） | terminate 関数末尾で `fr_save_state` を呼ぶ実装 / 同 Section 2, 9 |
| Req 4.1〜4.3（claude-failed ラベル据え置き） | `--remove-label` を呼ぶコードを追加していない / 既存 fr_terminate_test.sh + 新 Section 8 |
| Req 4.4（人間が手動でラベル除去した場合の挙動） | 人間がラベルを除去すれば既存 `fr_fetch_failed_*` の server-side filter `label:"claude-failed"` から外れる（既存挙動）。本変更は影響しない |
| Req 5.1（state 破損で fail-open） | `fr_load_state` が `{}` を返し `fr_is_terminated` が rc=1（未終端扱い）/ 同 Section 6-B + 7-F |
| Req 5.2（state 欠落で fail-open） | 同上 / 同 Section 6-A |
| Req 5.3（fail-continue 維持） | terminate 関数の return は元から 0 / `fr_save_state` 失敗時は `fr_warn` で記録のみ |
| Req 6.1（gate OFF で state 書き込みなし） | gate チェックは `process_failed_recovery` 冒頭で行われ early return する。本変更で gate 外の経路は追加していない / 既存 fr_process_test.sh Section 1（gate off） / fr_is_enabled_test.sh で間接担保 |
| Req 6.2（FULL_AUTO_ENABLED gate） | 同上 |
| Req 6.3（gate OFF で全副作用ゼロ） | 同上 |
| NFR 1.1（既存 schema フィールド維持） | `fr_save_state` の既存呼び出し規約に従い、新フィールド追加なし。既存 immediate_failure_streak / last_failure_signature / last_head_sha は前回値継承 / 同 Section 10 |
| NFR 1.2（既存識別子文字列維持） | terminate コメント本文・log message 共に `max-attempts` / `no-progress` 識別子を据え置く / 既存 fr_terminate_test.sh |
| NFR 1.3（旧 schema state を未終端として扱う） | last_status 不在の旧 state JSON で `fr_is_terminated` が rc=1 を返す / 同 Section 6-C |
| NFR 1.4（既存 env var 名・既定値維持） | 新 env var を追加していない。本変更は既存 `FAILED_RECOVERY_ENABLED` / `FAILED_RECOVERY_STATE_DIR` のみ参照 |
| NFR 1.5（終端コメント本文の既存文言維持） | コメント本文を変更していない（既存 fr_terminate_test.sh が継続 green） |
| NFR 2.1（抑止ログ 1 行記録） | `fr_log "${kind}=#${number} terminated reason=<status> suppressed=<...>"` / 同 Section 3-4, 7 |
| NFR 2.2（grep 可能粒度） | 抑止ログに `failed-recovery:` prefix + Issue/PR 番号 + reason 識別子 / 同 Section 3-4, 7 |
| NFR 3.1（`$HOME/.issue-watcher/` 配下配置） | 既存 `$FAILED_RECOVERY_STATE_DIR` を使う（追加配置先なし） |
| NFR 3.2（secrets を含めない） | terminate ログ / コメント / Slack detail に secrets / signature 全文を含めない（既存実装維持） |
| NFR 3.3（未信頼入力 `^[0-9]+$` 検証） | 既存 terminate 関数の number 検証を継続。`fr_filter_terminated_candidates` も number 検証を実装（同 Section 7-E） |

## 確認事項（人間に判断を委ねたい点）

特になし。要件・運用者コメントの両方とも明確で、Open Questions も「なし」と PM が宣言済み。
1 点のみ補足:

- **Req 3.2 の「watcher プロセス再起動・cron 実行ユーザー再ログインを跨いでも保持」**: 既存
  `fr_save_state` の atomic write 実装（mktemp → mv -f）と `$FAILED_RECOVERY_STATE_DIR`
  既定値 `$HOME/.issue-watcher/failed-recovery/<repo-slug>` の永続性で担保されている。本
  変更で追加の永続性確保は行っていない。直接の単体テストは `fr_state_test.sh` Section 4
  「save → load の往復」で間接担保されているが、Req 3.2 をより厳密に検証したい場合は
  「state ファイル書き込み後にプロセス kill → 再起動 → 同一値を read」する e2e test を
  追加することも考えうる（本 PR スコープ外）。

## テスト結果サマリ

```
=== fr_attempt_test.sh ===           PASS=60 FAIL=0
=== fr_fetch_test.sh ===              PASS=42 FAIL=0
=== fr_immediate_fail_test.sh ===     PASS=42 FAIL=0
=== fr_invoke_test.sh ===             PASS=56 FAIL=0
=== fr_is_enabled_test.sh ===         PASS=40 FAIL=0
=== fr_no_progress_test.sh ===        PASS=12 FAIL=0
=== fr_process_test.sh ===            PASS=71 FAIL=0
=== fr_state_test.sh ===              PASS=60 FAIL=0
=== fr_terminate_idempotent_test.sh ===  PASS=64 FAIL=0  (新規)
=== fr_terminate_test.sh ===          PASS=77 FAIL=0
```

合計: 524 tests PASS / 0 FAIL。

- `bash -n local-watcher/bin/modules/failed-recovery.sh` → 構文 OK
- `shellcheck local-watcher/bin/modules/failed-recovery.sh
   local-watcher/test/fr_terminate_idempotent_test.sh
   local-watcher/test/fr_fetch_test.sh` → 警告ゼロ

STATUS: complete
