# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は top-level コードを順次実行する bash スクリプトであり、
`full_auto_enabled()` の関数定義（line 9926 付近）が `process_auto_merge`（line 1168）/
`process_auto_merge_design`（line 1178）の呼び出し位置より後ろにあるため、これらの processor が
呼び出された時点では `full_auto_enabled` が未定義となる。bash は "command not found" (rc=127) を
返し、各 processor 冒頭の `if ! full_auto_enabled; then return 0; fi` ガードが真と評価されて
無言で早期 return するため、`FULL_AUTO_ENABLED=true AUTO_MERGE_ENABLED=true` が宣言されていても
auto-merge が完全に no-op となる（キーストーンバグ）。本要件は `full_auto_enabled()` の定義位置を
最も早い呼び出し（line 1168）より前へ前出しする move 修正と、同種の前方参照を再発させない
回帰防止策（呼び出し位置と定義位置の機械チェック・スモークテスト）を定義する。修正対象は
関数定義の物理的な配置のみであり、関数本体ロジック・gate 判定セマンティクス・他 processor の
ロジックは変更しない。

関連 Issue: `Depends on:` 関係はない（独立した修正）。`Related:` として `#348`（`FULL_AUTO_ENABLED`
kill switch 導入元）/ `#352`（auto-merge 実装）/ `#354`（auto-merge-design 実装）。

## Requirements

### Requirement 1: load-order bug の解消（`full_auto_enabled` 定義の前出し）

**Objective:** As an idd-claude 運用者, I want `full_auto_enabled()` を `issue-watcher.sh` の全
呼び出し位置より前に定義しておきたい, so that `FULL_AUTO_ENABLED=true` 環境で auto-merge 系
processor が "command not found" エラーで no-op に倒れず、所期の AND 二重 opt-in 判定が成立して
キーストーン機能が発火するようになる。

#### Acceptance Criteria

1. The Issue Watcher shall `full_auto_enabled()` の関数定義を、Config ブロックでの
   `FULL_AUTO_ENABLED` 正規化処理より後・かつ最も早い呼び出し（`process_auto_merge` の call site、
   現状 line 1168 相当）より前の位置に 1 箇所だけ配置する。
2. The Issue Watcher shall `full_auto_enabled()` の関数定義をスクリプト全体で 1 箇所のみ持ち、
   重複定義を作らない。
3. The Issue Watcher shall `full_auto_enabled()` の関数本体（`FULL_AUTO_ENABLED` を `=true`
   厳密一致で評価し、それ以外を OFF として扱う既存セマンティクス）を変更しない。
4. When `FULL_AUTO_ENABLED=true` かつ `AUTO_MERGE_ENABLED=true` で watcher が 1 サイクル実行される,
   the Issue Watcher shall `process_auto_merge` から `full_auto_enabled: command not found` を
   stderr に出力せずに gate 判定を完了する。
5. When `FULL_AUTO_ENABLED=true` かつ `AUTO_MERGE_DESIGN_ENABLED=true` で watcher が 1 サイクル
   実行される, the Issue Watcher shall `process_auto_merge_design` から
   `full_auto_enabled: command not found` を stderr に出力せずに gate 判定を完了する。
6. If `full_auto_enabled()` の呼び出し元（`process_auto_merge` / `process_auto_merge_design` /
   `process_needs_decisions_auto` / `dr_unblock_sweep` / dep-cycle-detect 等）がスクリプト
   ファイル横断で増減・移動した, the Issue Watcher shall すべての呼び出し位置が定義位置より
   後ろにあることを変更後も維持する。

### Requirement 2: 前方参照の棚卸し（同種バグの再発防止対象範囲の明示）

**Objective:** As an idd-claude メンテナ, I want 本修正の影響範囲が `full_auto_enabled` の load order に
限定されることを明示しつつ、同種の前方参照が他関数で残っていないかを 1 回棚卸ししたい, so that
今回のキーストーン修正で取りこぼされた load-order bug が後続サイクルで再露呈しないようにする。

#### Acceptance Criteria

1. The Issue Watcher shall `full_auto_enabled` を参照する全 caller（本体内 / `modules/*.sh` を
   含む）を一覧として確定し、定義位置より前に呼ばれる caller が存在しないことを修正後に確認する。
2. When `full_auto_enabled` 以外の関数で「定義行 > 最初の呼び出し行」の前方参照パターンが
   検出された, the Issue Watcher shall その関数を本 Issue のスコープ外として扱い、別 Issue へ
   切り出して記録する（本 PR では `full_auto_enabled` のみを移動する）。
3. The Issue Watcher shall `full_auto_enabled()` の定義位置移動に伴う他関数のロジック書き換え・
   挙動変更を行わない。

### Requirement 3: 回帰防止テスト（load order の機械チェック）

**Objective:** As an idd-claude メンテナ, I want `extract_function` を用いた既存ユニットテスト
（関数を隔離抽出して stub する方式）では再現できなかった load-order 系の統合バグを、近接テストで
継続検出できるようにしたい, so that 次回以降の編集で `full_auto_enabled` や他の関数が再び
前方参照の位置に動いてもテストが赤になり PR 段階で気付ける。

#### Acceptance Criteria

1. The Test Suite shall `issue-watcher.sh` 内の `full_auto_enabled` 関数定義行と全 caller の
   出現行を機械抽出し、「定義行 < すべての caller 行」が成り立つことを検証する近接テストを
   `local-watcher/test/` 配下に追加する。
2. If 定義行 ≥ いずれかの caller 行 になる回帰がコミットされた, the Test Suite shall 該当
   テストを fail させ、どの caller が前方参照になっているかを 1 件以上特定可能な形で出力する。
3. The Test Suite shall 上記近接テストを既存テストランナ（`local-watcher/test/` 配下の
   bash テストイディオム）から起動可能な単一スクリプトとして提供する。
4. When watcher を `FULL_AUTO_ENABLED=true` の最小入力（処理対象 Issue なし）で 1 サイクル
   起動した, the Smoke Test shall stderr に `full_auto_enabled: command not found` を含まない
   ことを検証する（`bash -c` レベルの統合スモーク。stub 隔離では再現不可だったケースを
   カバーする）。
5. The Smoke Test shall 既存 cron 環境を破壊しないよう、テスト実行を `/tmp` 等の使い捨て
   `REPO_DIR` で完結させ、テスト終了時に状態を残さない。

### Requirement 4: 後方互換と既定動作の温存

**Objective:** As an idd-claude 運用者, I want 既定環境（`FULL_AUTO_ENABLED` 未設定 / `false`）の
挙動が本修正で一切変わらないようにしたい, so that 本修正をデプロイした既存 consumer repo が
無告知のラベル遷移・auto-merge 発火・余分なログ出力に巻き込まれない。

#### Acceptance Criteria

1. While `FULL_AUTO_ENABLED` が未設定 or `false` or 不正値（既存正規化で `false` に丸められる
   ケース）, the Issue Watcher shall `process_auto_merge` / `process_auto_merge_design` が
   外部副作用（`gh pr merge --auto` 発火・ラベル変更・PR コメント投稿）を一切起こさないことを
   維持する。
2. The Issue Watcher shall `FULL_AUTO_ENABLED` env var 名・正規化規則・kill switch
   セマンティクスを本修正で変更しない（#348 で確定した既定動作を保持する）。
3. The Issue Watcher shall 既存の env var 名（`AUTO_MERGE_ENABLED` / `AUTO_MERGE_DESIGN_ENABLED`
   / `FULL_AUTO_ENABLED` 等）・ラベル名・exit code 意味・cron 登録文字列・ログ出力先を本修正で
   変更しない。
4. The Issue Watcher shall 本修正によって追加・削除されるトップレベル副作用（実行時に走る
   コード）を発生させない（move は関数定義ブロックの位置変更のみであり、新たな実行コードを
   注入しない）。

### Requirement 5: 同期と配布の整合性

**Objective:** As an idd-claude メンテナ, I want 本修正が root 配下の watcher と installed
consumer 配下（`$HOME/bin/issue-watcher.sh`）の双方で同一挙動になることを保証したい, so that
`install.sh` 経由で配布される watcher にも修正が確実に反映され、本 Issue が「修正したのに動かない」
と再発しないようにする。

#### Acceptance Criteria

1. The Installer shall `install.sh` が `local-watcher/bin/issue-watcher.sh` を
   `$HOME/bin/issue-watcher.sh` へ冪等にコピーする既存挙動を維持し、本修正後のファイルが
   そのまま配布される。
2. The Issue Watcher shall README の該当箇所（`FULL_AUTO_ENABLED` / auto-merge の動作説明や
   既知の制約に関する記述があれば）と整合した状態で本修正を反映する。
3. When 本修正をデプロイ済みの環境で altpocket-server 等の consumer から
   `FULL_AUTO_ENABLED=true AUTO_MERGE_ENABLED=true` でラベル `ready-for-review` の eligible PR を
   投入した, the Issue Watcher shall `process_auto_merge` の "サイクル開始" 相当ログを出し、
   eligible PR に対して `gh pr merge --auto` を実行する（auto-merge が実際に発火する）。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 本修正前後で `FULL_AUTO_ENABLED` 未設定環境の外部観測挙動
   （exit code、stderr の "command not found" 以外の出力、ラベル遷移、外部副作用の有無）を
   一致させる。
2. The Issue Watcher shall 本修正後も `cron` 最小 PATH（`PATH=/usr/bin:/bin`）下で
   `command -v claude gh jq flock git` の依存解決が変わらないことを維持する。

### NFR 2: 静的検査

1. The Issue Watcher shall 本修正後の `local-watcher/bin/issue-watcher.sh` が `bash -n` で
   構文エラー 0、`shellcheck` で `.shellcheckrc` を踏まえた baseline 上の警告増加 0 を満たす。
2. The Test Suite shall 追加した近接テスト・スモークテストの bash スクリプトが `bash -n` /
   `shellcheck` クリーンであることを満たす。

### NFR 3: 可観測性

1. When 本修正後に再び `full_auto_enabled` が未定義状態で呼ばれる事態が発生した, the Issue
   Watcher shall stderr の "command not found" 出力を抑止しない（メッセージを握り潰さず、
   観測者が cron.log から検知できる状態を維持する）。
2. The Test Suite shall load-order 回帰テストの fail 出力に「定義行番号」「最も早い caller の
   行番号」「caller のシンボル名」を含めて、原因特定が grep 1 回で完了する形にする。

## Out of Scope

- `full_auto_enabled()` 関数本体のロジック変更（`=true` 厳密一致の評価、未設定時の `false`
  fallback 等の既存セマンティクス）
- `FULL_AUTO_ENABLED` env var 名・正規化規則・kill switch 概念そのものの再設計
- `process_auto_merge` / `process_auto_merge_design` の発火条件・対象 PR 抽出ロジック・
  `gh pr merge` オプションの変更
- `full_auto_enabled` 以外の関数で前方参照が見つかった場合の修正（本 PR ではスコープ外として
  別 Issue 化し、本 PR では `full_auto_enabled` の move のみを行う）
- `extract_function` で関数を stub する既存ユニットテスト方式の見直し全般（load-order 検出に
  特化した近接テスト追加のみを行う）
- altpocket-server 等 consumer repo 側での auto-merge ラベル運用・PR テンプレートの調整
- Phase B Promote Pipeline / merge-queue / auto-rebase 等、本 bug の影響外の processor の
  挙動変更

## Open Questions

- なし（Issue #375 本文と既存コードの突き合わせで修正方針・受入観点が確定しているため、
  人間判断が必要な未解決項目は識別されなかった）
