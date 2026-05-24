# 実装ノート（#180 feat(watcher): issue-watcher.sh モジュール化 Part 2）

## 概要

`local-watcher/bin/issue-watcher.sh`（約 11,697 行）から、クォータ待機制御・マージキュー・
自動 Rebase の 3 プロセッサを独立モジュール（hyphen 命名 `quota-aware.sh` / `merge-queue.sh` /
`auto-rebase.sh`）へ差分等価で切り出した。本体は 9,969 行に縮小し、移動した約 1,728 行は
modules/ 配下に再配置した。観測可能挙動（環境変数・exit code・ログ書式・ラベル遷移・cron
登録文字列・call site 実行順序）は一切変更していない。

Feature Flag Protocol: 対象 repo の `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しない
ため、**通常フロー（opt-out 相当）で実装**した。flag 裏実装は行わない。

## 実施タスク（tasks.md numeric ID 順）

| Task | 内容 | 状態 |
|---|---|---|
| 1 | Module Loader manifest に 3 モジュール追加 | 完了 |
| 2 | Quota-Aware Processor 抽出（8 関数） | 完了 |
| 3 | Merge-Queue Processor 抽出（8 関数） | 完了 |
| 4 | Auto-Rebase Processor 抽出（10 関数） | 完了 |
| 5 | install.sh モジュール配置（検証のみ。Part 1 既配線） | 完了 |
| 6 | 既存テスト抽出元追従修正 | 完了 |
| 7 | 静的解析・スモーク検証・README 更新 | 完了 |
| 7.1 | モジュール欠落 fail-fast 回帰テスト追加（deferrable） | 完了（余力あり実施） |

## コミット一覧（main..HEAD）

実装 commit と進捗マーカー commit を分離（IMPL_RESUME_PROGRESS_TRACKING=true 運用）。

- `feat(watcher): Module Loader manifest に 3 プロセッサモジュールを追加`（Task 1）
- `refactor(watcher): Quota-Aware Processor を modules/quota-aware.sh へ切り出し`（Task 2）
- `refactor(watcher): Merge-Queue Processor を modules/merge-queue.sh へ切り出し`（Task 3）
- `refactor(watcher): Auto-Rebase Processor を modules/auto-rebase.sh へ切り出し`（Task 4）
- `test(watcher): モジュール抽出に合わせて関数抽出元を追従修正`（Task 6）
- `docs(readme): modules/ ディレクトリ構成と分割 migration note を追記`（Task 7）
- `test(watcher): モジュール欠落 fail-fast の回帰テストを追加`（Task 7.1）
- 各タスク後に `docs(tasks): mark <id> as done` の専用マーカー commit

Task 5 は実装 commit なし（後述「確認事項」のとおり Part 1 で既配線のため検証のみ）。

## 差分等価の機械検証

全 26 プロセッサ関数について、`git show main:.../issue-watcher.sh` から抽出した関数定義と
モジュールへ移動した定義を `awk` で抽出し byte-identical であることを確認した（IDENTICAL）。
ロジック・引数・戻り値・exit code（quota sentinel 99 等）は不変。

`QUOTA_RESET_STATE_FILE="${QUOTA_RESET_STATE_FILE:-$LOG_DIR/quota-reset-times.json}"` は
元々本体 quota-aware セクションの **top-level 代入**（main L763）であり、quota-aware.sh へ
そのまま移動した。Loader は Config ブロック（`LOG_DIR` 定義は本体 L336）より後に走るため、
モジュール source 時点で `$LOG_DIR` は解決済みで `set -u` に触れない（差分等価）。

## 検証結果

### 静的解析（shellcheck）

- `shellcheck -S warning local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh
  install.sh` + 変更した 4 テスト → **rc=0（warning/error ゼロ）**
- default severity では `info` 級（SC2317 unreachable=34 / SC2012=1）のみ残存。これは main
  baseline（SC2317=36 / SC2012=1）と同性質で、新規 warning の混入はない。SC2317 は処理関数が
  間接呼び出しのため unreachable と誤判定されるもので、抽出前後で総数は実質変化なし。
- `pi_max_rounds_kind_test.sh` の SC2034 警告（6 件）は **main 既存**で本 Issue スコープ外
  （当該ファイルは変更していない）。

### テスト（local-watcher/test/ 全 13 本）

全 13 本 PASS（追加した `module_loader_missing_test.sh` 含む）。

- `qa_detect_rate_limit_test.sh` / `qa_run_claude_stage_test.sh` / `repo_prefix_log_test.sh`:
  抽出元追従修正後 PASS（修正前は Red を観測 → 修正後 Green を確認）
- `verify_pushed_or_retry_test.sh`: 既に core_utils.sh + 本体抽出で追従済み（変更不要）PASS
- `module_loader_missing_test.sh`（新規）: 欠落 fail-fast / cwd 非依存 / 全モジュール存在時の
  正常通過を 7 ケースで検証、PASS

### 統合スモーク

- **cron-like 最小 PATH（Req 4.2）**: `env -i HOME=$HOME PATH=/usr/bin:/bin bash issue-watcher.sh`
  で Loader が `SCRIPT_DIR/modules/` から 4 モジュールを解決し、`base-branch=...` 行（Loader
  通過後）まで到達。git fetch（origin 不在）で停止するがこれは Loader 非起因。
- **モジュール欠落 fail-fast（Req 4.4 / NFR 3.1）**: `quota-aware.sh` 退避で起動 → 欠落名を含む
  `Error: 必須モジュールが見つかりません: .../quota-aware.sh` を stderr に出し exit 1。退避戻し済み。
- **dry-run / 処理対象なし（Req 4.3 / NFR 1.7）**: 実 repo（gh 認証済）に対し全 optional processor
  を無効化・専用 LOCK_FILE で起動 → `処理対象の Issue なし` → `完了` で **exit 0**。
  `command not found` / `unbound variable` / 未定義参照は **0 件**。全 call site が runtime 解決される
  ことを確認。
- **install.sh モジュール配置（Req 5.1-5.5 / NFR 2.1）**: scratch HOME で
  - 初回 `--local`: 4 モジュールを `$HOME/bin/modules/` に `[INSTALL] NEW ... (chmod +x)` で配置
  - 2 回目: 全て `[INSTALL] SKIP ... (identical to template)`（冪等）
  - `--dry-run`: `[DRY-RUN] NEW` で予定操作列挙、modules dir は FS 未作成（未反映）
  - sudo 不要（HOME スコープ完結）

## 受入基準 → テスト/検証の対応

| Req | 担保 |
|---|---|
| 1.1 quota を 1 モジュールに集約 | `quota-aware.sh`（8 関数集約）/ 関数抽出 byte-identical |
| 1.2 メインサイクルから同一解決 | dry-run スモーク（call site L590 runtime 解決, 未定義 0 件） |
| 1.3 Resume 処理から同一解決 | `process_quota_resume` 抽出 byte-identical / dry-run 到達 |
| 1.4 quota sentinel exit / reset 永続化 | `qa_run_claude_stage_test.sh`（exit 99 + reset_file 検証, 全 PASS） |
| 2.1 マージキューを 1 モジュールに集約 | `merge-queue.sh`（mq_*/mqr_*/process_* 集約）/ byte-identical |
| 2.2 定期サイクルの同一マージ順序判定 | `process_merge_queue` 抽出 byte-identical |
| 2.3 再チェックの同一再検証ロジック | `process_merge_queue_recheck` 抽出 byte-identical |
| 3.1 自動 Rebase を 1 モジュールに集約 | `auto-rebase.sh`（10 関数集約）/ byte-identical |
| 3.2 allowlist パスベース判定 | `ar_classify_diff`/`ar_fetch_candidates` 抽出 byte-identical |
| 3.3 同一条件の approve 解除 | `ar_dismiss_all_approvals` 抽出 byte-identical |
| 3.4 解決不能時 escalation | `ar_escalate_to_failed` 抽出 byte-identical |
| 4.1 SCRIPT_DIR 基準で source | 最小 PATH スモーク / `module_loader_missing_test.sh` Case 3 |
| 4.2 最小 PATH / cwd 非依存解決 | 最小 PATH スモーク / `module_loader_missing_test.sh` Case 1（別 cwd 起動） |
| 4.3 3 プロセッサ全関数を未定義参照なく解決 | dry-run スモーク（未定義 0 件）/ 26 関数 runtime 解決確認 |
| 4.4 欠落時 stderr エラー + exit 1 | `module_loader_missing_test.sh` Case 1/2 / 手動退避スモーク |
| 5.1-5.5 install 配置 | install scratch スモーク（NEW/SKIP/DRY-RUN/chmod +x/HOME スコープ） |
| 6.1 既存テスト全通過 | local-watcher/test/ 全 13 本 PASS |
| 6.2 移動後定義から解決 | extract_function 抽出元追従（core_utils / quota-aware / merge-queue） |
| 6.3 FAIL 3 本を通過へ | 該当 3 本 + qa_detect_rate_limit_test.sh を Red→Green |
| NFR 1.1-1.6 後方互換 | env/exit/ログ/ラベル/cron 不変（関数 byte-identical, call site 温存） |
| NFR 1.7 切り出し関数の差分等価 | 26 関数 byte-identical 検証 |
| NFR 2.1 install 冪等 | 2 回目 SKIP 確認 |
| NFR 3.1 ロード/配置失敗を silent fail させない | 欠落 fail-fast テスト / install log_action |

## 確認事項（design.md は書き換えず、ここに列挙）

1. **【最重要】Part 1 基盤は main HEAD で既に配線済みだった**: requirements.md / design.md は
   「Part 1（#177）が Loader 配線・install.sh の modules 配置・テスト追従を**未配線のまま残し、
   テスト 3 本が現に FAIL している**」前提（方針 A）で書かれているが、本ブランチの分岐元 main
   HEAD では既に:
   - `issue-watcher.sh` に Module Loader（`IDD_MODULE_DIR` / `REQUIRED_MODULES=( "core_utils.sh" )`
     / 欠落時 exit 1）が**存在**（本体 L476-496）
   - `install.sh` に `modules/` 配置ブロックが**存在**（L1227-1234）
   - 3 テスト（qa_run_claude_stage / repo_prefix_log / verify_pushed_or_retry）は**いずれも PASS**
     （extract_function が `$CORE_UTILS_SH` を awk の追加ファイル引数として既にスキャンしていた）

   つまり design.md が想定した「壊れた main の回復」は不要で、Part 2 の実質作業は **3 プロセッサ
   抽出 + manifest 拡張 + テスト抽出元の module 追従**に収束した。Task 1 は「既存 Loader の
   `REQUIRED_MODULES` 配列に 3 モジュールを追加」する形で実施し、Task 5 は「既存 install.sh
   ブロックが新 3 モジュールも冪等配置すること」を検証する形で実施した（新規実装 commit なし）。
   **design.md/requirements.md の前提が stale だが、成果物（差分等価な module 分割）は要件を満たす**。
   方針自体（Part 2 で吸収）はオーケストレーター判断と一致しており、設計 PR レビューでの最終確認を
   想定。

2. **Task 6 に未記載のテスト 1 本も追従が必要だった**: tasks.md Task 6 は明示的に 3 本
   （qa_run_claude_stage / verify_pushed_or_retry / repo_prefix_log）のみ挙げるが、
   `qa_detect_rate_limit_test.sh` も `qa_detect_rate_limit` を抽出するため、当該関数の
   quota-aware.sh 移動で Red 化した。Req 6.1（既存テスト一式 1 件も失敗せず）を満たすため、
   同テストも quota-aware.sh を抽出元に追加して追従した（tasks.md は書き換えず本ノートに記録）。

3. **Req 5.3 の上書き保護ヘルパは design.md 記述と実コードで異なる**: design.md は
   modules 配置を `copy_with_hybrid_overwrite`（`.bak` once-only）経由と記述するが、実際の
   `copy_glob_to_homebin` は `copy_template_file`（**OVERWRITE no-backup**）を呼ぶ。これは本体
   `$HOME/bin/issue-watcher.sh` 等のツールスクリプト配置と**同一の経路・同一の挙動**であり、
   modules をツールスクリプトと同格に扱う点で一貫している（ユーザのローカル編集を温存する
   `.bak` 経路はメタファイル / repo-template 側の別経路）。挙動として SKIP（同一）/ OVERWRITE
   （差分）/ DRY-RUN 列挙 / chmod +x は担保されており Req 5.1/5.2/5.4/5.5/NFR 2.1 を満たす。
   Req 5.3 の「上書き保護」の解釈（ツールスクリプトは template 同期が正で OVERWRITE が正しい挙動か、
   それとも .bak 退避が必要か）はレビューでの確認が望ましい。

4. **モジュール内 top-level 代入の存在**: design.md は「各モジュールは関数定義のみ、top-level
   実行文を持たない」と記すが、`quota-aware.sh` には元々本体 top-level だった
   `QUOTA_RESET_STATE_FILE=...` 代入 1 行が含まれる（差分等価維持のため移動）。Loader が Config
   ブロック後に走るため `$LOG_DIR` は解決済みで問題ないが、設計記述との微差として記録する。

5. **モジュールファイル冒頭の section banner が module header と一部重複**: 各モジュール冒頭の
   独自ヘッダ（用途/配置先/依存）に加え、移動元の section banner コメント（例: `Quota-Aware
   Watcher Helpers (#66)`）もそのまま移動したため、ドキュメントコメントが二重気味になっている。
   関数本体の byte-identical 維持を優先した結果であり、挙動には無影響。

## 実装上の判断

- **manifest 配列名は既存 `REQUIRED_MODULES` を踏襲**（design 疑似コードの `WATCHER_MODULES` には
  リネームしない）。既存 Loader を活かし後方互換・差分最小化を優先。
- **source 順序**は core_utils → quota-aware → merge-queue → auto-rebase。bash 遅延束縛により
  機能的には任意だが可読性のため低レベル順に並べた（design.md「前方参照の論証」に整合）。
- 関数移動は `sed`/`awk` による行範囲 cut & paste で行い、編集ミスによるロジック改変を避けた。
  移動後に全関数の byte-identical を機械検証する手順を各タスクで実施した。

## 派生タスク候補（次 Issue 化を推奨）

- Part 3（#181）: 開発ループ・検証ステージ・昇格パイプライン系の切り出し（本 spec Out of Scope）。
- `pi_max_rounds_kind_test.sh` の SC2034 警告解消（main 既存・本 Issue スコープ外の軽微な lint 改善）。

STATUS: complete
