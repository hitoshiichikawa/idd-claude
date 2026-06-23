# Requirements Document

## Introduction

Phase B Promote Pipeline の自動ラベル付与（`modules/promote-pipeline.sh` の
`pp_collect_merged_issues`）は、`is:merged base:$BASE_BRANCH` で取得した PR の
`closingIssuesReferences` のみを根拠に対象 Issue を特定し、`staged-for-release` を付与している。
GitHub の closing-issue リンクは **PR の base がリポジトリの default ブランチである場合のみ**
生成されるため、gitflow 運用（`BASE_BRANCH=develop` 等）では impl PR の本文に `Closes #N` を
書いていても `closingIssuesReferences` が空になり、`staged-for-release` が自動付与されない。
結果として `依存: #N` を持つ後続 Issue の `DEP_AUTO_UNBLOCK` が永久に発火せず、依存付き Issue
を順送りで処理する full-auto 運用が `BASE_BRANCH != main` 環境で停止する。

本要件は、`pp_collect_merged_issues` の Issue 番号導出ソースを `closingIssuesReferences` 単独から
**「head ブランチ名 `claude/issue-<N>-impl-<slug>` からの導出 + `closingIssuesReferences` の併用」**
へ拡張し、base ブランチが default かどうかに依存せずに `staged-for-release` を自動付与できる
ようにする。同時に `BASE_BRANCH=main` 既存運用の挙動・fork PR 除外・自動付与と人間付与の区別なし
ポリシー・opt-in gate などの既存契約を一切壊さないことを保証する。

## 関連

- Depends on: なし（独立した修正）
- Related: #15（Phase B Promote Pipeline 全体） / #100（`staged-for-release` 人間付与運用） /
  #346（`DEP_AUTO_UNBLOCK` / blocked 解除）

## Requirements

### Requirement 1: head ブランチ名からの Issue 番号導出（base ブランチ非依存化）

**Objective:** As an idd-claude 運用者, I want `pp_collect_merged_issues` が `closingIssuesReferences`
が空でも merged impl PR の head ブランチ名から Issue 番号を導出してくれることを期待する,
so that `BASE_BRANCH=develop` 等の gitflow 運用でも impl PR が merge された直後に対象 Issue へ
`staged-for-release` が自動付与され、依存チェーンが止まらない。

#### Acceptance Criteria

1. When `pp_collect_merged_issues` が `is:merged base:$BASE_BRANCH` の PR 集合を走査した,
   the Promote Pipeline shall 各 PR の head ブランチ名が `claude/issue-<N>-impl-<slug>` パターン
   （`AUTO_MERGE_HEAD_PATTERN` と整合する `^claude/issue-([0-9]+)-impl-` 形式）に一致する場合、
   キャプチャした `<N>` を当該 PR が紐付く Issue 番号として収集対象に加える。
2. When `closingIssuesReferences` から取得した Issue 番号集合と head ブランチ名から導出した
   Issue 番号集合の両方が同一 PR について得られた, the Promote Pipeline shall 両者の和集合を
   対象 Issue 集合とし、同一 Issue 番号の重複を排除する。
3. When head ブランチ名が `claude/issue-<N>-impl-<slug>` パターンに一致しない PR
   （人間が手書きした PR・設計 PR `claude/issue-<N>-design-*`・他フォーマットの head 等）が
   merged 集合に含まれた, the Promote Pipeline shall その PR から head 経由での Issue 番号
   導出を行わない（`closingIssuesReferences` 単独経路は従来どおり継続）。
4. While `BASE_BRANCH` がリポジトリの default ブランチでない（例: `develop`）状態で impl PR
   `claude/issue-<N>-impl-<slug>` が `$BASE_BRANCH` に merge された, the Promote Pipeline shall
   `closingIssuesReferences` が空であっても当該 `#N` を `staged-for-release` 自動付与の対象
   Issue として収集する。
5. The Promote Pipeline shall head ブランチ名からのキャプチャ値 `<N>` を Issue 番号として
   使用する前に `^[0-9]+$` で検証し、検証に失敗した場合は当該 PR の head 経路導出を行わない。

### Requirement 2: 既存 `staged-for-release` 自動付与契約の維持

**Objective:** As an idd-claude 運用者, I want head ブランチ経由で導出された Issue 番号に対しても
従来の自動付与契約（重複付与抑止・自動 / 人間付与の区別なし・fork PR 除外）が変わらず適用される
ことを期待する, so that 本修正によって既存 Issue 群へ意図しないラベル更新・PR コメント発火・
status 遷移の差異が生まれない。

#### Acceptance Criteria

1. When head ブランチ名導出により対象 Issue 集合が拡張された, the Promote Pipeline shall 各 Issue
   について `staged-for-release` ラベルの既存付与有無を確認し、既付与の Issue に対しては
   `gh issue edit --add-label` を再送しない（既存 AC 2.1.3 と整合）。
2. When head ブランチ名導出により新規に `staged-for-release` を付与した, the Promote Pipeline
   shall `issue=#${issue_number} action=label-add label=staged-for-release source=auto` 形式の
   ログを 1 行残す（既存 AC 2.1.1 / 2.1.2 と整合し、`source` 区別は行わない）。
3. The Promote Pipeline shall fork PR 除外条件（`headRepositoryOwner.login == "$repo_owner"`）を
   head ブランチ名経路でも適用し、fork PR の head ブランチ名から導出された Issue 番号を対象
   集合に加えない（既存 NFR 2.4 と整合）。
4. The Promote Pipeline shall 自動付与した `staged-for-release` と人間が手付与した
   `staged-for-release`（#100 系統）を同一ラベルで共有し、`source` 区別を行わない既存ポリシー
   を維持する。
5. While 自動付与に失敗した（`gh issue edit` がタイムアウト or non-zero）, the Promote Pipeline
   shall WARN ログを 1 行残し、後続 Issue の処理を継続する（既存挙動を維持する）。

### Requirement 3: 後方互換と既定挙動の温存

**Objective:** As an idd-claude 運用者, I want `BASE_BRANCH=main` 既存運用および
`PROMOTE_PIPELINE_ENABLED` 未設定 / `false` 環境で本修正による外部観測差異が一切発生しない
ことを期待する, so that 既存 consumer repo のラベル遷移・依存解決・cron 実行コスト・log 出力
形式が無告知で変わらない。

#### Acceptance Criteria

1. While `PROMOTE_PIPELINE_ENABLED` が `=true` 以外（既定 `false` を含む）, the Promote Pipeline
   shall `pp_collect_merged_issues` を起動させず、本修正による追加コードパスにも到達しない
   （既存 opt-in gate の挙動を維持する）。
2. While `BASE_BRANCH` がリポジトリの default ブランチ（典型的に `main`）で運用されている,
   the Promote Pipeline shall 本修正前後で `staged-for-release` 付与対象 Issue 集合・付与順序・
   per-Issue ログ・skip ログを観測上一致させる（`closingIssuesReferences` が常に充足する状況
   下では head 導出経路が和集合の追加要素を生まないことを担保する）。
3. The Promote Pipeline shall 既存の env var 名（`PROMOTE_PIPELINE_ENABLED` / `BASE_BRANCH` /
   `LABEL_STAGED_FOR_RELEASE` / `PROMOTE_GIT_TIMEOUT` 等）・ラベル名・exit code 意味・cron
   登録文字列・ログ出力先を本修正で変更しない。
4. The Promote Pipeline shall 1 サイクルで処理する merged PR 取得件数の上限（現状 `--limit 50`）
   と `staged-for-release` 付き open Issue の取得件数上限（現状 `--limit 100`）を本修正で変更
   しない。
5. The Promote Pipeline shall head ブランチ名導出経路を `pp_collect_merged_issues` の既存
   `gh pr list` 呼び出しで取得済みの PR 集合に対して追加 in-process 処理として実装する想定
   であり、`pp_collect_merged_issues` 内の gh API 呼び出し回数を本修正で増やさない（追加の
   gh API call を発火させない）。

### Requirement 4: スコープ外要素の不可侵

**Objective:** As an idd-claude メンテナ, I want 本修正が `pp_collect_merged_issues` の Issue 番号
導出ロジックに局所化され、後段の ST 判定・promote 実行・revert 系の挙動に副作用を与えないこと
を期待する, so that 修正範囲が局所化され、レビューと回帰テストが Phase B 全体に波及しない。

#### Acceptance Criteria

1. The Promote Pipeline shall `ST_CHECK_RUN_NAME` 未設定時の `skip-warn` 挙動（既存 AC 2.2.3）・
   `pp_resolve_merge_sha` の `closedByPullRequestsReferences` 経由 merge SHA 解決ロジック・
   `pp_get_st_state` の状態 5 種分類（`success` / `failure` / `pending` / `missing` / `skip-warn`）
   を本修正で変更しない。
2. The Promote Pipeline shall develop→main の promote トリガ（`ST_CHECK_RUN_NAME` / `pp_handle_st_success`
   経由の `staged-for-release` 除去動線）を本修正で変更せず、ST 連動部分は別レイヤとして扱う。
3. The Promote Pipeline shall `pp_collect_merged_issues` 以外の関数（`po_*` / `pp_get_st_state` /
   `pp_handle_st_success` / `pp_handle_st_failure` / `pp_resolve_merge_sha` / `pp_resolve_st_log_url`
   等）のシグネチャ・stdout 形式・戻り値規約を本修正で変更しない。
4. The Promote Pipeline shall `staged-for-release` 付き open Issue を後段に渡す `stdout` 形式
   （1 行 1 件の Issue 番号列）を本修正で変更しない。

### Requirement 5: 回帰防止テスト

**Objective:** As an idd-claude メンテナ, I want `pp_collect_merged_issues` の head ブランチ名
経由導出ロジックを `extract_function` イディオムで隔離抽出した近接テストでカバーしたい,
so that 次回以降の編集で head パターン正規表現・和集合ロジック・fork PR 除外条件が破壊された
場合に PR 段階で検出できる。

#### Acceptance Criteria

1. The Test Suite shall `pp_collect_merged_issues`（または抽出可能なら head 導出ヘルパ）を
   `extract_function` で隔離抽出し、`gh` コマンドを stub して以下 4 ケースを観測する近接
   テストを `local-watcher/test/` 配下に追加する:
   `closingIssuesReferences` 単独で導出できるケース /
   head ブランチ名単独で導出できるケース（`closingIssuesReferences=[]`） /
   両方から同一 `#N` が導出され和集合で重複排除されるケース /
   head ブランチ名が `claude/issue-<N>-impl-` パターンに一致しないため除外されるケース。
2. The Test Suite shall fork PR（`headRepositoryOwner.login != "$repo_owner"`）が head ブランチ名
   `claude/issue-<N>-impl-<slug>` を持つ場合でも対象集合に加わらないことを観測する近接テスト
   ケースを含める。
3. The Test Suite shall 上記近接テストを既存テストランナ（`local-watcher/test/` 配下の bash
   テストイディオム）から起動可能な単一スクリプトとして提供する。
4. If `BASE_BRANCH=develop` 想定の入力（`closingIssuesReferences=[]` かつ head=`claude/issue-1-impl-x`）
   に対して `#1` が対象集合に含まれない結果を観測した, the Test Suite shall 該当テストを fail
   させ、当該 PR 番号・head ブランチ名・期待される Issue 番号を出力する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Promote Pipeline shall 本修正前後で `BASE_BRANCH=main` 環境の外部観測挙動（付与対象
   Issue 集合・ラベル付与順序・per-Issue ログ・WARN ログ・stdout 行集合）を一致させる。
2. The Promote Pipeline shall 本修正前後で `PROMOTE_PIPELINE_ENABLED` 未設定 / `false` 環境の
   外部観測挙動（API 呼び出しゼロ・log 出力ゼロ・ラベル遷移ゼロ）を一致させる。
3. The Promote Pipeline shall 既存ラベル名 `staged-for-release` を本修正で改名・別名追加せず、
   `LABEL_STAGED_FOR_RELEASE` 定数経由の参照を破壊しない。

### NFR 2: 静的検査

1. The Promote Pipeline shall 本修正後の `local-watcher/bin/modules/promote-pipeline.sh` が
   `bash -n` で構文エラー 0、`shellcheck` で `.shellcheckrc` を踏まえた baseline 上の警告増加
   0 を満たす。
2. The Test Suite shall 追加した近接テストの bash スクリプトが `bash -n` / `shellcheck` クリーン
   であることを満たす。

### NFR 3: 可観測性

1. When head ブランチ名経由で `staged-for-release` を新規付与した, the Promote Pipeline shall
   既存 `pp_log` フォーマット（`issue=#${issue_number} action=label-add label=staged-for-release
   source=auto`）と同一形式で 1 行出力し、`closingIssuesReferences` 経由付与のログと区別しない。
2. When `pp_collect_merged_issues` が完了した, the Promote Pipeline shall 既存サマリログ
   （`auto-label サマリ: staged-for-release-added=<N>, already-labeled-skipped=<M>`）の形式・
   フィールド名を変更せず、`added` / `skipped` の集計に head 経路の付与結果を合算する。
3. While head ブランチ名から導出した Issue 番号に対する `gh issue edit` が失敗した,
   the Promote Pipeline shall 既存 WARN フォーマット（`issue=#${issue_number} staged-for-release
   自動付与に失敗（後続 Issue は継続）`）と同一形で 1 行残す。

### NFR 4: 未信頼入力の取り扱い

1. The Promote Pipeline shall PR の head ブランチ名（GitHub API から取得する未信頼文字列）を
   `jq` に渡す際は `--arg` で受け渡し、`grep` / `sed` / `bash -c` に渡す際は `--` でオプション
   解釈を打ち切る・クォートする等して、`-` 始まりの branch 名や正規表現メタ文字によるフラグ
   注入・コマンド注入を防ぐ（CLAUDE.md「未信頼 GitHub 入力の取り扱い」と整合）。
2. The Promote Pipeline shall head ブランチ名から抽出した数値 ID を Issue 番号として使用する
   前に `^[0-9]+$` で検証し、検証に失敗した値を `gh issue edit` の引数や URL に展開しない。

## Out of Scope

- develop→main の promote トリガ（`ST_CHECK_RUN_NAME` / `pp_handle_st_success` 系統）の設計
  変更（Issue 本文「スコープ外」と整合）。
- `closingIssuesReferences` を GitHub 側で非 default base PR に対して生成させるためのリポジトリ
  設定変更（GitHub 側仕様であり idd-claude のスコープ外）。
- `staged-for-release` ラベルの人間付与運用（#100）と自動付与の区別を新規に導入すること
  （現行どおり同一ラベルで共有する）。
- `AUTO_MERGE_HEAD_PATTERN` 既定値の変更（本要件は同パターンの正規表現セマンティクスと整合
  させるのみであり、env var の既定値・命名・正規化規則は触らない）。
- 設計 PR（`claude/issue-<N>-design-*`）や非 `impl-` 系 head ブランチを `staged-for-release`
  の対象に含めること（impl PR のみ対象という既存スコープを維持する）。
- 他 processor（`pr-reviewer` / `auto-merge` / `merge-queue` / `auto-rebase` / `pr-iteration` /
  `security-review` / `stage-a-verify` 等）の挙動変更。
- `pp_collect_merged_issues` 以外の Phase B 関数（ST 判定・revert・promote 実行）のロジック
  変更。
- README の挙動説明文の大幅な再構成（必要な差分更新は別途 PR 内で行うが、本要件は外形契約に
  限定する）。

## Open Questions

- なし（Issue #389 本文の AC / スコープ外 / 仮案・判断を委ねたい点・実装影響範囲のヒント
  （`modules/promote-pipeline.sh:1094` `pp_collect_merged_issues` L1097-1116 / `AUTO_MERGE_HEAD_PATTERN`
  `^claude/issue-[0-9]+-impl-`）が出揃っており、head ブランチ名からの Issue 番号導出を
  `closingIssuesReferences` と併用する方針が Issue 本文の「期待する挙動」「仮案」で明示
  済みのため、人間判断が必要な未解決項目は識別されなかった。実装上の選択肢（jq 内部処理 vs
  bash 内ループ処理）は設計レイヤの裁量であり requirements では規定しない）
