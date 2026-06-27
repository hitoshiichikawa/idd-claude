# Requirements Document

## Introduction

idd-claude の Stage A Verify Gate（#125 で導入、`local-watcher/bin/modules/stage-a-verify.sh`）は、
tasks.md 末尾の build/test/lint コマンドを watcher が REPO_DIR で独立再実行することで、
Developer の自己申告だけで build 不通のまま Stage A を通過するのを防ぐゲートである。
現状の結果分岐は exit code を `0` / `124`（timeout） / `*`（その他失敗） / `2 + diff path-missing`（#364 で WARN 降格）の
4 系統に分類しているが、**`exit 127`（command not found / 実行ファイル未検出）を「その他失敗」と同列に扱い**、
round1 → round2 → `claude-failed` まで自動昇格してしまう。
これは「watcher ホストに lint ツール（例: golangci-lint）が未インストール」という環境要因に過ぎず、
コード自体は verify-clean であるため、人間を不要に escalate に巻き込む。
本要件は、構造化ブロック由来の verify コマンドが exit 127 で落ちた場合に、
実 verify 失敗（exit=1 等）・timeout（exit=124）・既存 path-missing diff（exit=2）と明確に区別し、
WARN 降格して Stage A を続行させる仕様を確定する。
「watcher は不確実な検証を `claude-failed` にしない」という #230（design-less impl SKIP）・
#364（path-missing WARN 降格）と整合する設計方針を踏襲する。

## Requirements

### Requirement 1: exit 127 を実 verify 失敗から区別する

**Objective:** As a watcher 運用者, I want verify コマンドの exit 127 を実 verify 失敗から切り出して扱いたい, so that 環境要因（ツール未インストール）でコード品質に問題のない Issue が `claude-failed` に escalate されるのを防げる

#### Acceptance Criteria

1. When verify コマンドの実行 exit code が 127 である場合, the Stage A Verify Module shall round counter を bump せずに WARN 降格して戻り値 0 を返す
2. When exit 127 で WARN 降格した場合, the Stage A Verify Module shall Stage A を完了状態として続行させる（既存の `SUCCESS` / `warn-skipped`（#364）と同じ「戻り値 0」契約に整合する）
3. When exit 127 で WARN 降格した場合, the Stage A Verify Module shall `gh issue comment` による Developer 差し戻しコメント投稿を行わない
4. The Stage A Verify Module shall exit 127 由来の WARN 降格を `_SAV_LAST_OUTCOME` に新規 outcome として露出させ、既存 outcome（`success` / `disabled` / `skip` / `warn-skipped` / `round1` / `round2`）と区別可能にする
5. If `STAGE_A_VERIFY_COMMAND` env が明示指定された経路で exit 127 が観測された場合, the Stage A Verify Module shall 構造化ブロック由来の場合と同一の WARN 降格挙動を取る

### Requirement 2: 連結コマンドの境界条件

**Objective:** As a watcher 運用者, I want `&&` / `||` / `;` で連結された verify コマンドにおける exit 127 の発生位置ごとの挙動を明確にしたい, so that 「実 verify 失敗と環境要因の混在」を取り違えない

#### Acceptance Criteria

1. When 連結コマンドの先頭コマンドが exit 127 で短絡停止し bash -c 全体の最終 exit code が 127 となった場合, the Stage A Verify Module shall Requirement 1 の WARN 降格挙動を取る
2. When 連結コマンドの途中コマンドが exit 127 で短絡停止し bash -c 全体の最終 exit code が 127 となった場合, the Stage A Verify Module shall Requirement 1 の WARN 降格挙動を取る
3. When 連結コマンド全体が exit 127 で終了した場合, the Stage A Verify Module shall Requirement 1 の WARN 降格挙動を取る
4. If 連結コマンドの実行で real fail（exit=1 等の非 127 / 非 0）と exit 127 の双方が発生し、bash -c の最終 exit code が real fail のもの（例: 1）となった場合, the Stage A Verify Module shall 従来の round1 → round2 → `claude-failed` 経路を維持する
5. If verify コマンド全体の exit code が 124（timeout）である場合, the Stage A Verify Module shall 従来の timeout 経路（#377）を維持し、本 Requirement 1 の WARN 降格対象としない

### Requirement 3: 既存の結果分岐挙動の維持

**Objective:** As a watcher 運用者, I want 既存の SUCCESS / timeout / path-missing / 実 verify 失敗の挙動を本変更で壊さないことを保証したい, so that 既存テスト・既存運用と後方互換が保たれる

#### Acceptance Criteria

1. When verify コマンドの exit code が 0 である場合, the Stage A Verify Module shall 既存の SUCCESS 挙動（round counter reset / 戻り値 0 / `_SAV_LAST_OUTCOME=success`）を維持する
2. When verify コマンドの exit code が 124 である場合, the Stage A Verify Module shall 既存の timeout 挙動（#377: WARN ログ → `_sav_handle_failure timeout`）を維持する
3. When verify コマンドの exit code が 2 で stderr が `diff:` 始まりかつ `No such file or directory` を含む場合, the Stage A Verify Module shall 既存の path-missing WARN 降格挙動（#364: `_SAV_LAST_OUTCOME=warn-skipped`）を維持する
4. When verify コマンドの exit code が 1 である場合, the Stage A Verify Module shall 既存の real fail 経路（round1 → round2 → `claude-failed`）を維持する
5. When verify コマンドの exit code が 127 でも 124 でも 2 でも 0 でも 1 でもない場合（例: 130 / 137 / 2 だが path-missing 条件を満たさない）, the Stage A Verify Module shall 既存の real fail 経路を維持する

### Requirement 4: 観測性 / ログ出力

**Objective:** As a watcher 運用者, I want exit 127 の WARN 降格が発生した事実をログから機械的に抽出したい, so that cron.log を grep して環境要因による降格件数を集計でき、未インストールツールの是正判断ができる

#### Acceptance Criteria

1. When exit 127 で WARN 降格が発生した場合, the Stage A Verify Module shall `grep '\[.*\] stage-a-verify: WARN'` で抽出可能な WARN 行を 1 行以上出力する
2. When exit 127 で WARN 降格が発生した場合, the Stage A Verify Module shall WARN 行に「exit 127 を tool-missing として降格した」事実が判別できる識別固定の reason 文字列（例: `reason=verify-tool-missing`）を含める
3. Where 検出した未導入ツール名を実行コマンドから推定可能な情報源がある場合, the Stage A Verify Module shall WARN 行に推定したツール名または該当コマンド断片を含める
4. When exit 127 で WARN 降格が発生した場合, the Stage A Verify Module shall `_SAV_LAST_OUTCOME` に WARN 降格を示す新規 outcome 値（例: `warn-tool-missing`）を露出させ、`warn-skipped`（#364 path-missing）と区別する
5. When exit 127 で WARN 降格が発生した場合, the Stage A Verify Module shall WARN 行に元の `exit=127` の数値とコマンド断片を含めて、事後解析でどの verify 実行が降格対象だったかを特定できる形式で記録する

## Non-Functional Requirements

### NFR 1: 後方互換 / opt-in

1. While `STAGE_A_VERIFY_ENABLED=false` が設定されている間, the Stage A Verify Module shall 本機能の導入前後で完全に同一の no-op 挙動（DISABLED 早期 return）を維持する
2. The Stage A Verify Module shall 既存の env var 名（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` / `STAGE_A_VERIFY_KILL_AFTER`）と既存の exit code 意味（0=続行 / 1=round1 差し戻し / 2=round2 escalate）の契約を本変更で壊さない
3. The Stage A Verify Module shall 既存 outcome 値（`success` / `disabled` / `skip` / `warn-skipped` / `round1` / `round2`）の発生条件と意味を本変更で変更しない

### NFR 2: 既存テストとの互換

1. The Stage A Verify Module shall `local-watcher/test/stage_a_verify_path_missing_test.sh`（#364）の全テストケースを本変更後も pass させる
2. The Stage A Verify Module shall `local-watcher/test/stage_a_verify_round1_defer_test.sh` の全テストケースを本変更後も pass させる
3. The Stage A Verify Module shall `local-watcher/test/stage_a_verify_timeout_pgkill_test.sh`（#377）の全テストケースを本変更後も pass させる

### NFR 3: 判定ヘルパの純粋関数性

1. The Stage A Verify Module shall exit 127 判定を担う新規ヘルパ関数を、副作用を持たない純粋関数（入力は exit code とコマンド文字列・stderr 等のみ、出力は戻り値と stdout のみ）として実装可能にする
2. The Stage A Verify Module shall 新規ヘルパを既存の `_sav_is_path_missing_diff_failure` / `_sav_extract_missing_path`（#364）と同様のテスト容易性（`extract_function` イディオムでの隔離抽出が可能）を満たす形で配置可能にする

### NFR 4: ログ書式の互換

1. The Stage A Verify Module shall 既存の `stage-a-verify:` prefix（`[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:`）を WARN 降格ログでも維持する
2. The Stage A Verify Module shall 新規 WARN 行を 1 行で記録し、複数行に分割しない（grep 抽出時の脱漏・ペアリングミスを防ぐ）

## Out of Scope

- watcher ホストへの lint / build ツール（golangci-lint, node, go, gradle 等）の自動インストール。環境構築は利用者責務として既存の方針を維持する
- Failed Recovery Processor（#411）の挙動変更、および pr-reviewer spam（#417 / #420 / #421）対応
- tasks.md verify ブロックの記述規約（センチネル / 構造化ブロックフォーマット）の変更
- 仮案 C（実行前 `command -v` による事前 SKIP）の単独採用判断。本 Requirement では「実行後 exit code による事後判定（仮案 A）」を主軸とし、案 C と案 A の併用可否や代替設計判断は `design.md` 側で再評価する余地を残す
- 構造化ブロック以外の経路（heuristic 抽出 / `STAGE_A_VERIFY_COMMAND` env 経路）における Gate 3（keyword 一致）判定の変更
- WARN 降格件数の集計・通知バッチ機能（運用者は cron.log を grep して集計する既存運用を維持）

## Open Questions / 確認事項

- Issue 本文の「期待する挙動」では「`claude-failed` へ escalate しない」とのみ書かれており、round1 の差し戻しコメントを出すか否かは明示されていない。本要件では仮案 A（WARN + SKIP / round counter 不変 / 差し戻しコメントなし）を採用し、Req 1.3 で「差し戻しコメント投稿を行わない」と確定したが、運用上 Developer に「環境要因で skip した」事実を Issue コメントで通知すべきかは design.md 側で再評価する余地がある（推奨は通知しない方向。理由: Developer に修正可能なものがなく、コメント数が無駄に増えるため）
- 「検出した未導入ツール名」の抽出方法は Req 4.3 で `Where 情報源がある場合` として条件付きにとどめた。実装上、watcher が知り得るのは bash -c 全体の最終 exit code と stderr だけであり、連結コマンドのどの位置のコマンドが exit 127 を返したかを stderr から推定可能か（例: `bash: line N: <tool>: command not found` を grep する）は design.md 側で実装容易性を再評価する
- 新規 outcome 値の文字列（仮: `warn-tool-missing`）は本要件では例示にとどめ、最終命名は design.md で確定する。`warn-skipped`（#364）との 1 対 1 区別が観測性として担保されることだけを Req 4.4 で必須化した
- Issue 本文の「影響範囲のヒント」には `_sav_exec_with_timeout`（L849〜）と round 判定箇所（L756〜）が挙げられているが、本要件は実装位置を指定しない（design.md の領分）。実装は新規ヘルパ関数 + `stage_a_verify_run` の rc 分岐への 127 ケース追加のいずれの形でもよい

## 関連

- Depends on: #125 #364 #377
- Related: #230 #417 #420 #421
