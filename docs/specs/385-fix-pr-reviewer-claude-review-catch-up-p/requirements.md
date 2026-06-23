# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は top-level コードを順次実行する bash スクリプトであり、
`parse_review_result()` の関数定義（line 6617 付近）が `process_claude_review_status_catchup`
の呼び出し位置（line 1573 付近）より後ろにあるため、catch-up processor が起動した時点で
`parse_review_result` が未定義となる。catch-up 内の `declare -F parse_review_result` ガードが
false 評価となり、`pr-reviewer: WARN: claude-review status publish (catch-up): parse_review_result
未ロード ... reason=parse-helper-missing` を残して safe-skip する。結果として AND 二重 opt-in
（`PR_REVIEWER_STATUS_CHECK_ENABLED=true` AND `FULL_AUTO_ENABLED=true`）が有効な環境で
`claude-review` commit status が **永久に publish されない**（`codex-review` は publish されるが
`claude-review` は none に留まる）状態が継続する。本 bug は #376（F4）で修正した
`full_auto_enabled` 前方参照と完全に同一のバグ class（top-level 逐次実行下での load-order
forward reference）であり、catch-up 側が安全側に skip する実装だったため silent に機能不全と
なり気づきにくかった。

本要件は `parse_review_result()` の定義位置を catch-up 呼び出しより前へ前出しする move 修正と、
同種の前方参照を再発させない回帰防止策（定義行 < 呼び出し行の機械チェック、または catch-up
実行到達テスト）を定義する。修正対象は関数定義の物理的な配置のみであり、関数本体ロジック・
catch-up 側の safe-skip 契約・他 processor の挙動は変更しない。既存の safe-skip ガード
（`declare -F parse_review_result` 検査と WARN ログ）は保険として残す。

## 関連

- Depends on: なし（独立した修正）
- Related: #380（F3 catch-up 導入 PR） / #376（F4 `full_auto_enabled` 同種 load-order 修正） /
  #374（claude-review status per-task publish 契約）

## Requirements

### Requirement 1: load-order bug の解消（`parse_review_result` 定義の前出し）

**Objective:** As an idd-claude 運用者, I want `parse_review_result()` を `issue-watcher.sh` の
`process_claude_review_status_catchup` 呼び出しより前に定義しておきたい, so that AND 二重
opt-in 環境で catch-up が `parse_review_result` を解決して `claude-review` commit status を
PR head sha に対して publish できるようになる（`parse-helper-missing` で永続 skip しない）。

#### Acceptance Criteria

1. The Issue Watcher shall `parse_review_result()` の関数定義を、`process_claude_review_status_catchup`
   の call site（現状 line 1573 相当）より前の位置に 1 箇所だけ配置する。
2. The Issue Watcher shall `parse_review_result()` の関数定義をスクリプト全体で 1 箇所のみ持ち、
   重複定義を作らない。
3. The Issue Watcher shall `parse_review_result()` の関数本体（戻り値・stdout TSV 形式・rc 規約
   など #349 / #374 で確定済みの既存セマンティクス）を本修正で変更しない。
4. When AND 二重 opt-in（`PR_REVIEWER_STATUS_CHECK_ENABLED=true` AND `FULL_AUTO_ENABLED=true`）
   が成立した状態で `process_claude_review_status_catchup` が起動した, the PR Reviewer Processor
   shall `declare -F parse_review_result` 検査が真と評価され、`reason=parse-helper-missing` の
   WARN ログを出力しない。
5. If `parse_review_result()` の caller（本体内 / `modules/*.sh` を含む）が今後増減・移動した,
   the Issue Watcher shall すべての caller 位置が `parse_review_result` 定義位置より後ろにある
   ことを変更後も維持する。

### Requirement 2: catch-up 経路での `claude-review` status publish の発火

**Objective:** As an idd-claude 運用者, I want open PR の review-notes.md（最終 `RESULT:` 行）を
catch-up が読み直して `claude-review` commit status を publish できるようにしたい, so that
per-task ループ運用で `publish_claude_review_status` が PR 作成より前に WARN skip した分も
最終的に PR head sha 上で観測可能な state に収束する。

#### Acceptance Criteria

1. When open / 非 draft / `PR_REVIEWER_HEAD_PATTERN` に一致する PR があり、対応する
   `docs/specs/<番号>-*/review-notes.md` が PR head 上に存在し、最終 `RESULT: approve` 行を
   含み、AND 二重 opt-in が成立した状態で catch-up が 1 サイクル動作した, the PR Reviewer
   Processor shall context `claude-review` / state `success` の commit status を PR head sha
   に対して publish する。
2. When 同条件下で `review-notes.md` の最終 `RESULT: reject` 行が読み取られた, the PR Reviewer
   Processor shall context `claude-review` / state `failure` の commit status を PR head sha に
   対して publish する。
3. The PR Reviewer Processor shall catch-up 経由で publish する `claude-review` status の context
   名・state 解決規則（approve→success / reject→failure）を非 catch-up 経路（#349 / #374 Req
   3.x）と一致させる。
4. When 同一 PR head sha に対して同一 context `claude-review` で複数回 publish が行われた,
   the PR Reviewer Processor shall GitHub Commit Status API の "latest wins per (sha, context)"
   セマンティクスにより最新の `RESULT:` を反映した state が表示される状態に収束させる
   （#374 Req 4.3 と整合）。

### Requirement 3: 異常系の safe-skip 契約の温存

**Objective:** As an idd-claude 運用者, I want `review-notes.md` 不在・parse 失敗・PR 未解決
などの異常系で catch-up が watcher パイプラインを停止させずに safe-skip する既存契約を本修正
で壊さないようにしたい, so that 想定外の状態が原因で claude-failed に倒れる事故が発生せず、
保険としての WARN + 継続挙動が維持される。

#### Acceptance Criteria

1. If catch-up 起動時点で対応する PR head から `review-notes.md` を取得できない, the PR Reviewer
   Processor shall WARN レベルのログを 1 行残し commit status の publish を行わずに当該 PR の
   試行を skip する（#374 Req 3.2 と整合）。
2. If `review-notes.md` を `parse_review_result` で解釈できない（最終 `RESULT:` 行不在・不正値・
   rc≠0）, the PR Reviewer Processor shall WARN レベルのログを 1 行残し commit status の publish
   を行わずに当該 PR の試行を skip する（#374 Req 3.3 と整合）。
3. If 万一 `parse_review_result` が依然として未定義の状態で catch-up が呼ばれた, the PR Reviewer
   Processor shall `reason=parse-helper-missing` の WARN ログを 1 行残し commit status の publish
   を行わずに当該 PR の試行を skip する（保険ガードの撤去を行わない）。
4. When catch-up 試行が PR 未解決・file 不在・parse 失敗・helper 未定義のいずれかで skip された,
   the PR Reviewer Processor shall watcher パイプライン（後続 processor / per-task ループ継続 /
   PjM PR 作成 / claude-failed 判定）を停止させずに後続処理を続行する（戻り値 0 固定）。

### Requirement 4: 前方参照の棚卸し（同種バグの再発防止対象範囲の明示）

**Objective:** As an idd-claude メンテナ, I want 本修正の影響範囲が `parse_review_result` の
load order に限定されることを明示しつつ、同種の前方参照が他関数で残っていないかを 1 回棚卸し
したい, so that 今回の修正で取りこぼされた load-order bug が後続サイクルで再露呈しないように
する。

#### Acceptance Criteria

1. The Issue Watcher shall `parse_review_result` を参照する全 caller（本体内 / `modules/*.sh`
   を含む）を一覧として確定し、定義位置より前に呼ばれる caller が存在しないことを修正後に確認
   する。
2. When `parse_review_result` 以外の関数で「定義行 > 最初の呼び出し行」の前方参照パターンが
   検出された, the Issue Watcher shall その関数を本 Issue のスコープ外として扱い、別 Issue へ
   切り出して記録する（本 PR では `parse_review_result` のみを移動する）。
3. The Issue Watcher shall `parse_review_result()` の定義位置移動に伴う他関数のロジック書き
   換え・挙動変更を行わない（#376 で line 156 付近に移送済みの `full_auto_enabled` を含む
   既存配置を破壊しない）。

### Requirement 5: 回帰防止テスト（load order の機械チェック）

**Objective:** As an idd-claude メンテナ, I want `extract_function` を用いた既存ユニットテスト
（関数を隔離抽出して stub する方式）では再現できなかった load-order 系の統合バグを、近接
テストで継続検出できるようにしたい, so that 次回以降の編集で `parse_review_result` や
catch-up 呼び出しが再び前方参照の位置に動いてもテストが赤になり PR 段階で気付ける。

#### Acceptance Criteria

1. The Test Suite shall `issue-watcher.sh` 内の `parse_review_result` 関数定義行と
   `process_claude_review_status_catchup` 呼び出し行を機械抽出し、「定義行 < 呼び出し行」が
   成り立つことを検証する近接テストを `local-watcher/test/` 配下に追加する。
2. If 定義行 ≥ 呼び出し行 になる回帰がコミットされた, the Test Suite shall 該当テストを fail
   させ、定義行番号と呼び出し行番号を 1 件以上特定可能な形で出力する。
3. The Test Suite shall 上記近接テストを既存テストランナ（`local-watcher/test/` 配下の bash
   テストイディオム）から起動可能な単一スクリプトとして提供する。
4. The Test Suite shall 上記近接テスト相当の検証として、実行到達テスト（catch-up 関数を
   呼び出した時点で `declare -F parse_review_result` が真を返す）を採用することも許容する
   （定義行 < 呼び出し行の機械チェックと等価な観測ができる場合に限る）。

### Requirement 6: 後方互換と既定動作の温存

**Objective:** As an idd-claude 運用者, I want AND 二重 opt-in が無効な既定環境
（`PR_REVIEWER_STATUS_CHECK_ENABLED` 未設定 or `false`）の挙動を本修正で一切変更しない
ようにしたい, so that 本修正をデプロイした既存 consumer repo が無告知の API 呼び出し追加・
追加ログ出力・追加ラベル遷移に巻き込まれない。

#### Acceptance Criteria

1. While `PR_REVIEWER_STATUS_CHECK_ENABLED` が `=true` 以外（既定 `false`） or
   `FULL_AUTO_ENABLED` が `=true` 以外（既定 `false`）, the PR Reviewer Processor shall
   `process_claude_review_status_catchup` の関連 API 呼び出し（`gh api /repos/.../statuses/<sha>`
   / `gh pr list` / `git cat-file` 等）を一切発火させない（catch-up 内 AND 二重 opt-in 早期
   判定の挙動を維持する）。
2. The Issue Watcher shall `parse_review_result` 関数シグネチャ（引数・戻り値・stdout TSV
   形式・rc 規約）を本修正で変更しない（#349 / #374 で確立済みの既存契約を保持する）。
3. The Issue Watcher shall 既存の env var 名（`PR_REVIEWER_STATUS_CHECK_ENABLED` /
   `FULL_AUTO_ENABLED` / `PR_REVIEWER_HEAD_PATTERN` / `PR_REVIEWER_MAX_PRS` 等）・ラベル名・
   exit code 意味・cron 登録文字列・ログ出力先を本修正で変更しない。
4. The Issue Watcher shall 本修正によって追加・削除されるトップレベル副作用（実行時に走る
   コード）を発生させない（move は関数定義ブロックの位置変更のみであり、新たな実行コードを
   注入しない）。

### Requirement 7: 同期と配布の整合性

**Objective:** As an idd-claude メンテナ, I want 本修正が root 配下の watcher と installed
consumer 配下（`$HOME/bin/issue-watcher.sh`）の双方で同一挙動になることを保証したい, so that
`install.sh` 経由で配布される watcher にも修正が確実に反映され、本 Issue が「修正したのに
動かない」と再発しないようにする。

#### Acceptance Criteria

1. The Installer shall `install.sh` が `local-watcher/bin/issue-watcher.sh` を
   `$HOME/bin/issue-watcher.sh` へ冪等にコピーする既存挙動を維持し、本修正後のファイルが
   そのまま配布される。
2. The Issue Watcher shall README の該当箇所（`PR_REVIEWER_STATUS_CHECK_ENABLED` /
   `claude-review` catch-up の動作説明や既知の制約に関する記述があれば）と整合した状態で
   本修正を反映する。
3. When 本修正をデプロイ済みの環境で `PR_REVIEWER_STATUS_CHECK_ENABLED=true AND
   FULL_AUTO_ENABLED=true` の AND 二重 opt-in 環境に対し、`review-notes.md` を含む eligible
   open PR を投入した, the PR Reviewer Processor shall catch-up 1 サイクル経由で当該 PR head
   sha に対して `claude-review` commit status が観測される状態に到達する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 本修正前後で AND 二重 opt-in 無効環境の外部観測挙動（exit code /
   stderr 出力 / ラベル遷移 / 外部副作用の有無 / PR コメント投稿）を一致させる。
2. The Issue Watcher shall 本修正後も `cron` 最小 PATH（`PATH=/usr/bin:/bin`）下で
   `command -v claude gh jq flock git` の依存解決が変わらないことを維持する。
3. The Issue Watcher shall 本修正後も既存の `parse_review_result` を呼び出している他経路
   （`pr_run_review_for_pr` / `publish_claude_review_status` / per-task Reviewer round 等）の
   観測挙動を一致させる。

### NFR 2: 静的検査

1. The Issue Watcher shall 本修正後の `local-watcher/bin/issue-watcher.sh` および
   `local-watcher/bin/modules/pr-reviewer.sh` が `bash -n` で構文エラー 0、`shellcheck` で
   `.shellcheckrc` を踏まえた baseline 上の警告増加 0 を満たす。
2. The Test Suite shall 追加した近接テスト（または実行到達テスト）の bash スクリプトが
   `bash -n` / `shellcheck` クリーンであることを満たす。

### NFR 3: 可観測性

1. When catch-up 経由で publish が成功した, the PR Reviewer Processor shall PR 番号・head
   sha・context・state を含む 1 行のログを既存ロガー粒度（`pr_log`）と同形式で stdout に
   出力する（#374 NFR 3.1 と整合）。
2. When catch-up 経由で publish が PR 未解決・file 不在・parse 失敗・helper 未定義のいずれか
   で skip された, the PR Reviewer Processor shall skip 理由を識別可能な WARN ログを 1 行
   残し silent fail にしない（#374 Req 3.5 と整合）。
3. The Test Suite shall load-order 回帰テストの fail 出力に「`parse_review_result` 定義行
   番号」「`process_claude_review_status_catchup` 呼び出し行番号」を含めて、原因特定が grep
   1 回で完了する形にする。

## Out of Scope

- `parse_review_result()` 関数本体のロジック変更（戻り値・stdout TSV 形式・rc 規約 / #349 /
  #374 で確定済みのセマンティクス）
- `process_claude_review_status_catchup` 内部処理ロジックの変更（候補 PR 列挙基準・
  `pr_publish_claude_status` の呼び出し方・target_url 組み立てルール・上限 truncation 等 /
  #374 で確定済み）
- `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` env var 名・正規化規則・kill switch
  概念の再設計（#348 / #349 で確定済み）
- `pr_publish_claude_status` / `pr_publish_commit_status` の API call レイヤ・state 解決
  ロジック・description 長制限の変更（#349 で確立済み）
- 非 catch-up 経路（`publish_claude_review_status` 直接呼び）の publish タイミング・呼び出し
  位置の変更（#374 で確定済み）
- `full_auto_enabled` 以外の関数で前方参照が見つかった場合の修正（本 PR ではスコープ外として
  別 Issue 化し、本 PR では `parse_review_result` の move のみを行う）
- `extract_function` で関数を stub する既存ユニットテスト方式の見直し全般（load-order 検出に
  特化した近接テスト追加のみを行う）
- branch protection / required status checks 側の設定（GitHub 側設定 / consumer 運用責務）
- `codex-review` 経路の挙動変更（本 Issue は `claude-review` catch-up 経路の load-order
  修正に限定）
- Phase B Promote Pipeline / merge-queue / auto-rebase 等、本 bug の影響外の processor の
  挙動変更

## Open Questions

- なし（Issue #385 本文の AC / DoD と既存コード（`parse_review_result` 定義位置 line 6617・
  `process_claude_review_status_catchup` 呼び出し位置 line 1573・catch-up 内 `declare -F`
  ガード）の突き合わせで修正方針・受入観点が確定しているため、人間判断が必要な未解決項目は
  識別されなかった。Architect の介在を要する設計選択（定義の前出し vs 呼び出し位置の後送）は
  Issue 本文で「定義の前方移送を推奨」と明示済みであり、本要件は両方を許容する形で外形契約
  に限定して記述した）
