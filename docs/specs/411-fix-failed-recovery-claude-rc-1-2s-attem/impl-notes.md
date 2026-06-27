# Implementation Notes — #411 即時失敗除外 / 専用ログ / worktree 起動 / 独立エスカレーション

## サマリ

`local-watcher/bin/modules/failed-recovery.sh` に以下 4 系統を追加した（既定 OFF / 後方互換あり）:

1. **即時失敗 attempt 除外**: rc=98 sentinel + `immediate_failure_streak` カウンタ + attempt ロールバック
2. **専用ログ保存**: `$LOG_DIR/failed-recovery-<kind>-<number>-<TS>.log` を必ず生成し `LOG` 未設定でも `/dev/null` に逃さない
3. **対象 repo 作業ツリーでの起動**: `REPO_DIR` で claude branch / PR head branch / BASE_BRANCH を checkout
4. **独立エスカレーション**: `fr_terminate_immediate_failure_streak` + `immediate-failure-streak` 識別子

## 設計判断

### 閾値選定

- `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS` 既定 **10 秒**
  - altpocket-server #119 で観測された ~2 秒 rc=1 を確実に拾える保守値
  - 短すぎると正常な失敗を誤分類、長すぎると即時失敗を見逃すバランス
- `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK` 既定 **3 回**
  - 3 cycle（2 分 cron × 3 ≒ 6 分）連続で claude が起動できなければ手動レビューへ
  - 通算 attempt 4 回上限とは別カウンタ。quota 燃焼上界保証として有限の正の整数値
- 両方とも env で上書き可能。非整数 / `<=0` は既定値に正規化

### 即時失敗判定ロジック

`fr_classify_immediate_failure` を純粋関数として切り出した（テスト容易性 + Req 1.2 / 1.3 / 1.8）。
判定: `rc!=0 AND quota 未検出 AND tool_use 未観測 AND elapsed < threshold`。
すべてのガード条件は逆順優先で評価し、いずれか「通常扱い」に該当した時点で 1 を返す。

tool_use 観測は stream-json 出力に `"type":"tool_use"` 行が含まれるかを grep で観測。
2 段 tee 構成で `LOG`（cron.log 互換）と専用ログの両方に append し、専用ログ側を grep 対象にする。

### ログファイル命名

`failed-recovery-<kind>-<number>-<TS>.log` で固定（Req 2.3 識別語必須 + Req 2.2 kind/number/timestamp 必須）。

- `kind`: `issue` / `pr` のみ（`fr_resolve_dedicated_log_path` で sanitize）
- `<number>`: `^[0-9]+$` のみ
- `<TS>`: `+%Y%m%dT%H%M%SZ`（ASCII 安全 / Req 2.3 + NFR 3.1）

`LOG_DIR` 未設定時は `$HOME/.issue-watcher/logs/$REPO_SLUG` にフォールバック（Req 2.4 で `/dev/null` 行きを防ぐ）。
ファイル作成失敗時は警告ログを残しつつ `/dev/null` 行きで recovery 自体は継続（fail-continue / Req 2.6）。

### worktree checkout 戦略

`fr_prepare_repo_worktree` を新規追加（Req 3.1〜3.6）:

- **PR の場合**: `gh pr view --json headRefName` で取得 → `git -C $REPO_DIR checkout -B <ref> origin/<ref> --`
- **Issue の場合**: `git ls-remote --heads origin "claude/issue-<N>-*"` の先頭、無ければ `BASE_BRANCH`
- 失敗時は `fr_warn` で原因を残しつつ rc=1（Req 3.4 で即時失敗扱いへ倒す）
- `-- ` でオプション解釈打ち切り（NFR 3.1 / branch 名で `-` 始まりの誤注入防止）
- `^claude/` パターンで PR head branch を再検証（fork 巻き込み防止）

`fr_run_recovery_attempt` 内で `( cd "$REPO_DIR"; fr_invoke_claude ... )` の subshell に隔離して
caller の cwd を変更しない（NFR 1.1 後方互換）。

### attempt rollback と streak カウンタ

`fr_run_recovery_attempt` で:

1. 試行開始時に通常通り `total=prev_total+1` で `in-progress` save（既存挙動）
2. claude rc=98 を受けたら `total=prev_total`（ロールバック）+ `streak=prev_streak+1` で再 save
3. `streak >= max_streak` なら return 4（`_fr_dispatch_candidate` が `fr_terminate_immediate_failure_streak` を呼ぶ）
4. 通常失敗 / success path では `streak=0` リセット（Req 1.7）
5. prev_streak が既に max_streak >= の状態で再起動した場合は事前判定で return 4（attempt 加算なし）

これにより quota 燃焼上界保証（max-attempts 通算 4 回）は壊さずに、即時失敗の「決定論的な空消費」だけを除外できる。

### 識別子と既存終端の区別可能性

- 既存: `max-attempts` / `no-progress`
- 追加: `immediate-failure-streak`（Req 4.1）

3 つとも `fr_log` で `[YYYY-MM-DD HH:MM:SS] [$REPO] failed-recovery: <kind>=#<n> terminated reason=<id> ...` 形式（Req 4.2）。
`grep -E "terminated reason=immediate-failure-streak"` で抽出可能。
sn_notify の event_type は既存 3 種（recovered / max-attempts / no-progress）に `immediate-failure-streak` を追加（Req 4.6）。
signature 値は detail に含めない（NFR 3.2）。

## 変更ファイル一覧

| File | 変更内容 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | Config ブロックに `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS` / `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK` 2 つの env 正規化を追加 |
| `local-watcher/bin/modules/failed-recovery.sh` | `fr_resolve_dedicated_log_path` / `fr_classify_immediate_failure` / `fr_prepare_repo_worktree` / `fr_terminate_immediate_failure_streak` を新規追加。`fr_save_state` に 6 番目引数（immediate_failure_streak）を追加（後方互換 / 省略時継承）。`fr_invoke_claude` を rewrite（2 段 tee / tool_use 観測 / elapsed 計測 / rc=98 sentinel / dedicated_log_path 受け取り）。`fr_run_recovery_attempt` を rewrite（worktree prep → claude → rc=98 / 0 / 99 / 通常失敗の分岐 + streak ハンドリング）。`_fr_dispatch_candidate` に rc=4 case を追加 |
| `local-watcher/test/fr_immediate_fail_test.sh` | **新規追加**。Section A〜J で `fr_resolve_dedicated_log_path` / `fr_terminate_immediate_failure_streak` 単体と、`fr_run_recovery_attempt` 内 rc=98 / streak 上限 / worktree 失敗 / dedicated_log 受け渡し / repo_dir + ref ログ を検証 |
| `local-watcher/test/fr_invoke_test.sh` | Section 9 を tool_use 観測 fixture に書き換え（既存の「rc=7 透過」検証を維持しつつ即時失敗判定との干渉を分離）。Section 10〜14 を新規追加（rc=98 sentinel / tool_use 観測ありで透過 / success path / quota 経路除外 / `fr_classify_immediate_failure` 純粋関数の境界値テスト） |
| `local-watcher/test/fr_attempt_test.sh` | stub に `fr_prepare_repo_worktree` / `fr_resolve_dedicated_log_path` を追加。`fr_invoke_claude` stub を 3 引数版に更新。`REPO_DIR` / `BASE_BRANCH` / `LOG_DIR` env 追加。success path で fr_save_state 呼び出し回数が 2→3 になる（streak=0 reset save が増えた）ことに合わせ assertion 更新 |
| `local-watcher/test/fr_state_test.sh` | 末尾に Section #411 追加（streak 明示指定 save → load / 6 番目引数省略時の継承 / 既存 state（streak field 不在）の 0 fallback / 不正値正規化） |
| `local-watcher/test/fr_process_test.sh` | `TERMINATE_IMMEDIATE_TRACE` + `fr_terminate_immediate_failure_streak` stub 追加。Section 11 で rc=4 → `fr_terminate_immediate_failure_streak` が呼ばれることを検証（PR 経路 + 既存 rc=2/3 では呼ばれないことも） |
| `README.md` | Failed Recovery Processor の終端動作テーブルに #411 即時失敗 / streak 上限到達の 2 行追加。env 表に 2 行追加。state JSON フィールド説明に `immediate_failure_streak` / 拡張 `last_status` enum 追加。Migration Note の末尾に #411 専用節を追加（後方互換性の明示説明） |

## テスト方針 / 追加テストと通過結果

### テスト方針

- AC 起点（要件番号 → テストケース 1:1 マッピング）
- 既存テストを壊さず、新テストを追加（fr_immediate_fail_test.sh）+ 既存テストに #411 拡張 section を追加
- 純粋関数（`fr_classify_immediate_failure`）の境界値を `fr_invoke_test.sh` Section 14 でカバー
- 統合動作（`fr_run_recovery_attempt` の rc=98 ハンドリング）は `fr_immediate_fail_test.sh` で stub を使い検証
- dispatcher 配線（rc=4 → `fr_terminate_immediate_failure_streak`）は `fr_process_test.sh` Section 11 で検証

### 通過結果

すべて緑（FAIL=0）:

| Test | PASS |
|---|---|
| `fr_attempt_test.sh` | 60 |
| `fr_fetch_test.sh` | 42 |
| `fr_immediate_fail_test.sh` (new) | 42 |
| `fr_invoke_test.sh` | 56 |
| `fr_is_enabled_test.sh` | 40 |
| `fr_no_progress_test.sh` | 12 |
| `fr_process_test.sh` | 71 |
| `fr_state_test.sh` | 60 |
| `fr_terminate_test.sh` | 77 |

その他 `local-watcher/test/*_test.sh` 全件も FAIL=0 で通過確認済み（68 ファイル）。

### 静的解析

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` → 警告ゼロ
- `shellcheck local-watcher/test/fr_*_test.sh` → 警告ゼロ
- `bash -n local-watcher/bin/modules/failed-recovery.sh` / `local-watcher/bin/issue-watcher.sh` → OK
- `diff -r .claude/agents repo-template/.claude/agents` → 空（drift なし）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（drift なし）

## AC Traceability

| AC ID | 実装箇所 | テスト |
|---|---|---|
| Req 1.1（即時失敗の attempt 除外） | `failed-recovery.sh` `fr_run_recovery_attempt` rc=98 case（rollback save） | `fr_immediate_fail_test.sh` Section C, `fr_invoke_test.sh` Section 10 |
| Req 1.2（判定条件: rc非ゼロ+tool_use無+短時間） | `failed-recovery.sh` `fr_classify_immediate_failure`, `fr_invoke_claude` tool_use 観測 | `fr_invoke_test.sh` Section 14 (A〜G 全条件), Section 10 |
| Req 1.3（閾値 env 上書き / 既定 安全側） | `issue-watcher.sh` `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS` 正規化（既定 10） | `fr_invoke_test.sh` Section 14-F/14-G 境界値（9 < 10 < 10）|
| Req 1.4（streak の state 永続化） | `failed-recovery.sh` `fr_save_state` 6 番目引数 / JSON schema 拡張 | `fr_state_test.sh` Section #411, `fr_immediate_fail_test.sh` Section C/D |
| Req 1.5（streak 上限到達で停止 → terminate へ委譲） | `failed-recovery.sh` `fr_run_recovery_attempt` rc=4 return + `_fr_dispatch_candidate` case 4 | `fr_immediate_fail_test.sh` Section D/E, `fr_process_test.sh` Section 11 |
| Req 1.6（streak 上限 env 上書き / 既定 有限正） | `issue-watcher.sh` `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK` 正規化（既定 3） | `fr_immediate_fail_test.sh` Section D（max=3 動作確認） |
| Req 1.7（実質作業着手時 streak リセット） | `failed-recovery.sh` `fr_run_recovery_attempt` 成功 / 通常失敗 path で streak=0 save | `fr_immediate_fail_test.sh` Section F/G |
| Req 1.8（quota は判定対象外） | `failed-recovery.sh` `fr_classify_immediate_failure` quota 検出時に 1 を返す + `fr_invoke_claude` 内 quota 早期 return 99 | `fr_invoke_test.sh` Section 13, Section 14-A |
| Req 2.1（recovery claude の stdout/stderr を専用ログに保存） | `failed-recovery.sh` `fr_invoke_claude` 2 段 tee で `effective_dedicated_log` へ append | `fr_immediate_fail_test.sh` Section I |
| Req 2.2（$LOG_DIR 配下 / kind + number + timestamp 含む） | `failed-recovery.sh` `fr_resolve_dedicated_log_path` | `fr_immediate_fail_test.sh` Section A |
| Req 2.3（識別語 `failed-recovery` 必須） | 同上 | `fr_immediate_fail_test.sh` Section A |
| Req 2.4（LOG 未設定でも /dev/null fallback しない） | `failed-recovery.sh` `fr_resolve_dedicated_log_path` $HOME fallback | `fr_immediate_fail_test.sh` Section A（LOG_DIR unset テスト） |
| Req 2.5（一次運用ログにパス記録） | `failed-recovery.sh` `fr_invoke_claude` 内 `fr_log "... dedicated_log=$effective_dedicated_log"` | 専用テストなし（fr_log 観測で間接的に / fr_immediate_fail_test.sh Section J で重ねて検証） |
| Req 2.6（保存失敗時の fail-continue） | `failed-recovery.sh` `fr_invoke_claude` 内 mkdir / truncate 失敗時の warn + `/dev/null` fallback | 静的解析と shellcheck で確認（カバー困難な i/o エラー path） |
| Req 3.1（対象 repo の作業ツリーで claude 起動） | `failed-recovery.sh` `fr_prepare_repo_worktree` + `( cd $REPO_DIR; fr_invoke_claude )` | `fr_immediate_fail_test.sh` Section J（ref + repo_dir ログ） |
| Req 3.2（PR head branch を checkout） | `failed-recovery.sh` `fr_prepare_repo_worktree` kind=pr 分岐 | `fr_immediate_fail_test.sh`（PR_HEAD_REF stub）/ shellcheck |
| Req 3.3（Issue は claude/issue-N-* / 無ければ BASE_BRANCH） | `failed-recovery.sh` `fr_prepare_repo_worktree` kind=issue 分岐 | `fr_immediate_fail_test.sh` Section J（採用 ref を出力に観測） |
| Req 3.4（worktree 失敗 → 即時失敗扱い） | `failed-recovery.sh` `fr_run_recovery_attempt` worktree_ok=0 → claude_rc=98 | `fr_immediate_fail_test.sh` Section H |
| Req 3.5（REPO_DIR を起点に採用） | `failed-recovery.sh` `fr_prepare_repo_worktree` `repo_dir="${REPO_DIR:-}"` | `fr_immediate_fail_test.sh` Section J |
| Req 3.6（起点パスと ref をログ記録） | `failed-recovery.sh` `fr_log "... repo_dir=$REPO_DIR ref=$checkout_ref"` | `fr_immediate_fail_test.sh` Section J |
| Req 4.1（識別子 `immediate-failure-streak`） | `failed-recovery.sh` `fr_terminate_immediate_failure_streak` 本文 + fr_log + sn_notify | `fr_immediate_fail_test.sh` Section B |
| Req 4.2（一次運用ログで grep 抽出可能） | `failed-recovery.sh` `fr_log "${kind}=#${number} terminated reason=immediate-failure-streak ..."` | `fr_immediate_fail_test.sh` Section B |
| Req 4.3（Issue/PR にコメント 1 件 / 識別子 + 回数含む） | `failed-recovery.sh` `fr_terminate_immediate_failure_streak` 内の `fr_post_attempt_comment` 1 回 | `fr_immediate_fail_test.sh` Section B |
| Req 4.4（claude-failed ラベル据え置き） | `fr_terminate_immediate_failure_streak` で `--remove-label` を呼ばない | `fr_immediate_fail_test.sh` Section B |
| Req 4.5（rs_set_result claude-failed が 1 度だけ） | `fr_terminate_immediate_failure_streak` 内 `rs_set_result "claude-failed"` 1 回 | `fr_immediate_fail_test.sh` Section B |
| Req 4.6（Slack 通知に識別子 + 回数 / 機微値なし） | `fr_terminate_immediate_failure_streak` 内 `sn_notify failed-recovery ... immediate-failure-streak ...` | `fr_immediate_fail_test.sh` Section B（NFR 3.2 signature 含めないも検証） |
| NFR 1.1（既存 env / 既定値 不変） | `issue-watcher.sh` Config ブロック既存行は無変更（新規追加のみ） | 既存 `fr_state_test.sh` Section 7 等が通る（PASS=60） |
| NFR 1.2（新規 env は安全側既定） | `FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS=10` / `FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK=3` | env 表 + `fr_state_test.sh` normalize テスト相当のロジック |
| NFR 1.3（既存終端識別子と区別可能 / 既存文字列変更なし） | `max-attempts` / `no-progress` の文字列は無変更 | `fr_terminate_test.sh` PASS=77（既存挙動） |
| NFR 1.4（二重 opt-in 維持） | `fr_is_enabled` は無変更 | `fr_is_enabled_test.sh` PASS=40 |
| NFR 2.1（判定根拠を一次運用ログ） | `fr_invoke_claude` 内 `fr_log "... immediate-failure label=... rc=... tool_use=... elapsed=...s ..."` | `fr_invoke_test.sh` Section 10 |
| NFR 2.2（dedicated log path / 作業ツリー起点 / ref をログ） | `fr_invoke_claude` start log + `fr_run_recovery_attempt` worktree log | `fr_immediate_fail_test.sh` Section J |
| NFR 3.1（kind / number / timestamp 入力検証維持） | `fr_resolve_dedicated_log_path` / `fr_prepare_repo_worktree` / `fr_terminate_immediate_failure_streak` で `^[0-9]+$` 検証 + `issue/pr` のみ受理 | `fr_immediate_fail_test.sh` Section A / B 不正値ケース |
| NFR 3.2（secrets / signature を comment / Slack に含めない） | `fr_terminate_immediate_failure_streak` 本文 + sn_notify detail に signature を含めない | `fr_immediate_fail_test.sh` Section B `assert_not_grep "aaaa..."` |

## 確認事項（Reviewer / 人間判断で確定すべき項目）

- **`FAILED_RECOVERY_IMMEDIATE_FAIL_SECONDS` の既定値 10 秒**: altpocket-server #119 で観測された ~2 秒
  rc=1 + 安全マージンで設定したが、運用ログ蓄積後に再評価する余地あり。閾値を 5 秒程度に下げると
  「2 秒 rc=1」と「8 秒で API エラーで failed」をより厳密に区別できる
- **`FAILED_RECOVERY_IMMEDIATE_FAIL_MAX_STREAK` の既定値 3**: 2 分 cron で 6 分後にエスカレーション
  という想定。watcher が短い間隔（例: 30 秒）で動く環境では値を上げる必要があるかもしれない
- **stream-json `"type":"tool_use"` 検出パターン**: 現在の grep パターン
  `"type"[[:space:]]*:[[:space:]]*"tool_use"` は claude CLI の現行 stream 形式に依存する。
  CLI の出力形式が変わった場合（例: `"type":"tool_call"`）は検出ロジック更新が必要
- **専用ログのローテーション / 削除**: 現状は無制限に蓄積する。`$LOG_DIR` 配下なので既存 watcher
  ログのローテーション運用（手動 `find -mtime` 等）と同じ扱いで良いはずだが、failed-recovery 専用
  のローテーション方針が要件として明示されていない（Out of Scope に該当する可能性）
- **worktree checkout でのコンフリクト**: `git checkout -B` で local branch を強制リセットする。
  watcher 自身が他 processor で同じ branch を編集中の場合の挙動（cron は flock で逐次化されている
  が念のため）は未テスト。Out of Scope の「実装上の判断」として、既存 impl 系プロセッサと同じく
  「watcher 単一プロセスが flock で逐次化される」前提を踏襲している
- **`fr_resolve_dedicated_log_path` の `$HOME` fallback でディレクトリが無いケース**: `fr_invoke_claude`
  内で `mkdir -p` するため新規環境でも自動作成されるが、`$HOME/.issue-watcher/logs/` 配下の
  permission が異常な環境（例: cron ユーザーが書き込めない）では fail-continue で `/dev/null`
  fallback する設計。Req 2.6 と整合
- **claude exit code 99 と 98 の使い分け**: 既存の quota sentinel 99 と新規の即時失敗 sentinel 98 が
  別経路として `fr_invoke_claude` から返る。`_fr_dispatch_candidate` は rc=99 と rc=4 を別経路で
  扱うため衝突は無いが、将来追加する sentinel は 97 以下 / 100 以上の範囲で割り当てる必要がある
- **テストカバレッジの境界**: i/o エラー path（`mkdir -p` 失敗 / `tee` の disk full 等）は通常の
  unit test では再現困難。Req 2.6 の fail-continue 挙動は shellcheck + コードレビューで担保している

## 補足: 既存挙動との互換性検証

- gate OFF（既定）では `fr_is_enabled` が rc=1 を返し `process_failed_recovery` 冒頭で `return 0`
  → 本機能導入前と完全に等価（gh API 呼び出しゼロ・state 書き込みゼロ）
- gate ON で claude が tool_use 観測 + 閾値以上の時間継続して失敗するケース（既存挙動）→
  `fr_classify_immediate_failure` が 1 を返し、`fr_invoke_claude` は通常通り `claude_rc` を透過。
  既存の `fr_run_recovery_attempt` の通常失敗 path（rc=1 で再試行）と同一の挙動
- gate ON で claude が success（rc=0）するケース → 即時失敗判定経路を通らず既存 success path
  （fr_finalize_success）に直行。`streak=0` リセットを追加で 1 回 save するが結果は同等
- 既存 state ファイル（`immediate_failure_streak` フィールド不在）の load → `// 0` で 0 fallback。
  以降の save で field が追加されるが、既存 reader（読み出し側）は新フィールドを単に無視する

STATUS: complete
