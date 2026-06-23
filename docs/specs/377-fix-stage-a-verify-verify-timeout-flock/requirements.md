# requirements: fix(stage-a-verify) verify コマンドの timeout 不発によるデッドロック修正（#377）

## Introduction

idd-claude の watcher で `stage-a-verify` が verify コマンド（shellcheck 連結等）の実行中に
約 1 時間 21 分にわたりフリーズし、`STAGE_A_VERIFY_TIMEOUT=600s` 構成の `timeout` が機能しな
かった事象が #374 で観測された。watcher 親プロセスは子プロセスの終了待ちで固着し、fd 200 が
`/tmp/issue-watcher-...-idd-claude.lock` への flock を保持し続けたため、以後の cron 実行が
すべて flock-skip となり idd-claude 全体がデッドロック状態に陥った。最終的に `kill -9` で
プロセスツリーを削除して初めて flock が解放された。

根本原因（仮説）は (A) `bash -c "$cmd"` が孫プロセスを spawn した際に `timeout` が pgid 全体
に SIGTERM/SIGKILL を broadcast しないこと、および (B) 出力経路の `> >(tee ...)` /
`2> >(tee ...)` の process substitution が孫の write-end 保持により EOF を受け取れず
親 subshell が `wait` で永久ブロックする構造的問題である。本 Issue では verify 実行ブロック
における (1) プロセスグループ単位の確実な強制終了、(2) 出力経路のパイプデッドロック回避、
(3) timeout 到達時の flock 解放保証、を達成しつつ既存 outcome 契約を破壊しない修正を行う。

## Glossary（用語定義）

- **verify cmd** — `stage-a-verify` モジュールが `bash -c` で実行する検証コマンド文字列
  （`STAGE_A_VERIFY_COMMAND` env または heuristic 抽出由来）
- **pgid** — process group ID。`setsid` 等で新規 session/process group を確立すると、当該
  グループ配下の全プロセスへ signal を一括送出可能になる
- **process substitution** — bash の `> >(...)` / `2> >(...)` 構文。サブシェルを別プロセスと
  して起動し pipe で接続する。孫プロセスが pipe write-end を握ったまま残ると read 側の
  サブシェルが EOF を受け取れずハングする
- **flock** — `local-watcher/bin/issue-watcher.sh` が fd 200 で取得するファイルロック
  （`/tmp/issue-watcher-...-idd-claude.lock`）。watcher 終了時 / fd close 時に解放される

## Requirements

### Requirement 1: 通常系の verify 動作維持

**Objective:** As an idd-claude 運用者, I want stage-a-verify の正常系挙動を従来通り維持する, so that 既存 cron / consumer repo の動作を破壊せずに本修正を deploy できる

#### Acceptance Criteria

1. When 通常の verify コマンドが指定され有限時間で終了する場合, the stage-a-verify module shall 従来通り exit code に基づき success / skip / warn-skipped / round1 / round2 のいずれかの outcome を確定する
2. When verify コマンドが exit 0 で完了した場合, the stage-a-verify module shall `_SAV_LAST_OUTCOME=success` を設定し round counter をリセットする
3. When verify コマンドが exit 124 以外の非ゼロ exit で完了した場合, the stage-a-verify module shall 従来の `_sav_handle_failure` 経路（round1/round2 escalate を含む）を維持する
4. Where `STAGE_A_VERIFY_ENABLED=false` の場合（既定値）, the stage-a-verify module shall no-op として復帰し、既存挙動を完全に保持する

### Requirement 2: timeout 不発の修正（核心）

**Objective:** As an idd-claude 運用者, I want verify コマンドが孫プロセスを spawn してハングしても wall-clock 上限内に必ず強制終了されるようにする, so that watcher が flock を握ったままデッドロックする事故を防ぐ

#### Acceptance Criteria

1. When verify コマンドが孫プロセス（子の子）を spawn し当該孫が無限待機状態に入った場合, the stage-a-verify module shall `STAGE_A_VERIFY_TIMEOUT` 値と grace 値の合計を上限とする wall-clock 時間以内に当該プロセスグループ配下の全プロセスを強制終了する
2. When verify コマンドが timeout により強制終了された場合, the stage-a-verify module shall 呼び出し元（issue-watcher.sh）へ有限時間内に制御を返却し、fd 200 の flock が watcher プロセス終了時に解放可能な状態を維持する
3. When timeout による強制終了が発生した場合, the stage-a-verify module shall exit code 124 として扱い、既存の `_sav_handle_failure "timeout" "$_timeout"` 経路に従って `_SAV_LAST_OUTCOME` を round1 または round2 に設定する
4. If verify コマンドが SIGTERM 受信後も grace 期間内に終了しなかった場合, the stage-a-verify module shall プロセスグループ配下の残存プロセスへ SIGKILL を送出する
5. When timeout 強制終了完了後に verify コマンドの子孫プロセスが残存していないかを確認可能にするため, the stage-a-verify module shall 呼び出し元復帰時点で当該プロセスグループ配下の全プロセスが終了している状態を保証する

### Requirement 3: 出力経路のパイプデッドロック回避

**Objective:** As an idd-claude 運用者, I want verify コマンドが大量出力や長時間ハングしても出力経路がデッドロックの原因にならないようにする, so that timeout signal が確実に伝播し flock 解放が阻害されない

#### Acceptance Criteria

1. When verify コマンドが stdout または stderr に大量出力を行い pipe buffer を満たした場合, the stage-a-verify module shall write block により timeout signal の伝播を阻害しない出力捕捉経路を採用する
2. When verify コマンドの孫プロセスが pipe の write-end を保持したまま残存し得る状況において, the stage-a-verify module shall 出力捕捉用 subshell が EOF を待ち続けて永久ブロックする構造を採用しない
3. The stage-a-verify module shall verify コマンドの stdout / stderr を $LOG に append し、既存の grep 経路（`grep '\[.*\] stage-a-verify:'` / FAILED / TIMEOUT / WARN 行抽出）の観測性を維持する
4. The stage-a-verify module shall stderr を独立して捕捉し、既存の #364 パス不在 WARN 降格判定（`_sav_is_path_missing_diff_failure` / `_sav_extract_missing_path`）の入力として利用可能な状態を維持する

### Requirement 4: 観測性（診断ログ）

**Objective:** As an idd-claude 運用者, I want timeout 強制終了時に十分な診断情報を $LOG に出力する, so that 事後解析で原因 verify cmd と経過秒を即座に特定できる

#### Acceptance Criteria

1. When timeout による強制終了が発生した場合, the stage-a-verify module shall issue 番号 / 実行 cmd / 設定 timeout 値 / kill-after grace 値を含む 1 行の診断ログを $LOG へ出力する
2. The stage-a-verify module shall 当該診断ログ行に既存ログ prefix `[HH:MM:SS] stage-a-verify:` を維持し、`TIMEOUT` キーワードを含めて grep 抽出可能にする
3. When verify cmd 文字列を診断ログへ書き出す場合, the stage-a-verify module shall `printf '%q'` 等によりシェルエスケープしてログ復元性を確保する

### Requirement 5: 後方互換

**Objective:** As an idd-claude 運用者, I want 既存の env var / outcome 契約 / ログ prefix を完全に維持する, so that 既稼働 cron および consumer repo に migration が不要となる

#### Acceptance Criteria

1. The stage-a-verify module shall 既存 env var `STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` の名称・既定値・解釈を破壊しない
2. Where 新規 env var を追加する場合, the stage-a-verify module shall 当該 env var の未設定時に従来挙動を再現する既定値を採用する
3. The stage-a-verify module shall 既存 outcome 値域 `success` / `skip` / `disabled` / `round1` / `round2` / `warn-skipped` および `_SAV_LAST_OUTCOME` の値・意味を破壊しない
4. The stage-a-verify module shall `stage_a_verify_run` 関数の return code 契約（0 / 1=round1 / 2=round2）を破壊しない
5. The stage-a-verify module shall 既存ログ prefix `[HH:MM:SS] stage-a-verify:` を破壊しない

## Non-Functional Requirements

### NFR 1: 静的解析・構文検証

1. The stage-a-verify module shall `shellcheck local-watcher/bin/modules/stage-a-verify.sh` を警告ゼロで通過する（accepted info 級は `.shellcheckrc` で制御）
2. The stage-a-verify module shall `bash -n` による構文検証を通過する

### NFR 2: 二重管理同期

1. The stage-a-verify module shall root `.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` の byte 一致を維持する（本 Issue で当該ディレクトリを変更する場合のみ）
2. The README shall 同一 PR で stage-a-verify 挙動説明箇所および環境変数表を本修正に整合させて更新する

### NFR 3: 近接テスト追加

1. The local-watcher/test/stage_a_verify_*_test.sh 系列 shall ハングする合成 verify cmd（例: `sleep infinity` を含む連結コマンド）を入力として、有限時間内に `stage_a_verify_run` が復帰し pgid 配下のプロセスが残存しないことを検証するテストケースを 1 件以上含む
2. The local-watcher/test/stage_a_verify_*_test.sh 系列 shall 大量出力 + ハングを伴う合成 verify cmd に対しても有限時間内に復帰することを検証するテストケースを 1 件以上含む（パイプデッドロック回避の回帰検出）
3. The local-watcher/test/stage_a_verify_*_test.sh 系列 shall 既存の `extract_function` 隔離抽出イディオムを踏襲し、`gh` / `git` 等の副作用は stub する

### NFR 4: セキュリティ（未信頼入力の取り扱い）

1. The stage-a-verify module shall verify cmd 文字列（Issue 由来の未信頼入力を含み得る）を扱う際に既存規約（quote / `printf '%q'` / `--` によるオプション解釈打ち切り）を維持する
2. The stage-a-verify module shall 一時ファイルを `mktemp` で作成し、予測可能名による symlink TOCTOU を回避する既存方針を維持する

### NFR 5: 運用復帰（deploy 後）

1. The impl-notes shall 本修正の merge & deploy 後、idd-claude cron の暫定 `STAGE_A_VERIFY_ENABLED=false` を `true` に戻して stage A verify を再有効化する手順を明記する

## Out of Scope

- Stage A 全体の round counter ロジック（`_sav_handle_failure` / `stage_a_verify_reset_round`）の挙動変更
- `issue-watcher.sh` 本体の flock 取得経路の変更（fd 200 取得タイミング / lock path / 解放契約）
- Reviewer ゲート / Architect ゲート / PR レビュー経路の挙動変更
- `STAGE_A_VERIFY_COMMAND` 抽出 heuristic（`stage_a_verify_extract_command` / `_sav_cmd_starts_with_keyword`）の判定ロジック変更
- #364 で実装済みのパス不在 WARN 降格判定（`_sav_is_path_missing_diff_failure` / `_sav_extract_missing_path`）の挙動変更
- consumer repo 側の `STAGE_A_VERIFY_TIMEOUT` 既定値（600s）の見直し
- timeout grace 値（既存 10 秒）の見直し（変更不要なら既定維持。変更が必要と Architect / Developer が判断した場合は当該 PR の確認事項として提起）

## Open Questions

- 出力経路の具体実装（一時ファイル経由方式 vs パイプ完全消費方式）は Developer 判断に委ねる（Triage で `needs_architect:false` 判定済の前提。Issue 本文「修正スコープ」で方針は確定済だが、実装手段の選定は Developer 領域）
- `setsid` 等プロセスグループ確立手段の具体的 invocation 形式（`setsid bash -c ...` か `bash -c "exec setsid ..."` か等）は Developer 判断
- timeout grace 値（既存 `--kill-after=10`）を据え置くか拡張するかは Developer 判断（変更する場合は impl-notes に根拠を明記）

## 関連

- Depends on: なし（#364 path-guard fix は既に main マージ済み）
- Parent: #125
- Related: #364 #374
