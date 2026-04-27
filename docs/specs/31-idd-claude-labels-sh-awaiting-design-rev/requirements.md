# Requirements Document

## Introduction

`idd-claude-labels.sh` は idd-claude が利用する GitHub ラベル群を冪等に作成・更新するためのセットアップスクリプトである。本来は何度再実行しても、既存ラベルは「スキップ」、不足ラベルのみ「作成」と分類されるべきだが、現状では特定の既存ラベル（少なくとも `awaiting-design-review` と `ready-for-review` で再現）が「FAILED」と分類され、最終的に exit code 1 で異常終了する。これにより `install.sh` 経由のセットアップ再実行や、CI からの呼び出しが偽陽性で失敗扱いになる。本要件は、スクリプトの冪等性と終了コード契約を本来の仕様に揃え、後方互換性を保ったまま再現バグを解消することを目的とする。

## Requirements

### Requirement 1: 冪等な再実行とラベル分類

**Objective:** As an idd-claude のセットアップ実行者, I want スクリプトを何度再実行しても結果が一貫すること, so that 既存ラベルの有無に関わらず安心して install.sh / セットアップを反復できる

#### Acceptance Criteria

1. When 全ラベルが既に対象 repo に存在する状態でスクリプトが `--force` なしで再実行されたとき, the Label Setup Script shall すべてのラベルを「既存スキップ」として分類する
2. When 一部のラベルのみ既に存在する状態でスクリプトが `--force` なしで再実行されたとき, the Label Setup Script shall 既存ラベルを「既存スキップ」、不足ラベルを「新規作成」として分類する
3. When 同一 repo に対してスクリプトを `--force` なしで連続して実行したとき, the Label Setup Script shall 2 回目の実行で `新規作成` 件数と `失敗` 件数の両方を 0 にする
4. If GitHub 上に存在するラベルが、スクリプト内で定義されたラベル一覧と完全一致しているとき, the Label Setup Script shall `失敗` 件数を 0 として報告する
5. If あるラベルが GitHub 上に既に存在しているとき, the Label Setup Script shall そのラベルを「既存スキップ」として分類しサマリの `既存スキップ` 件数に計上する

### Requirement 2: 真の失敗のみを失敗として扱う終了コード契約

**Objective:** As an install.sh / CI から呼び出す自動化処理, I want 真の失敗（API 不達・認証エラー等）のときだけ非ゼロ終了すること, so that 既存ラベルの存在による偽陽性で後続処理を中断させない

#### Acceptance Criteria

1. When 全ラベルが既存スキップまたは新規作成または上書き更新で正常に処理されたとき, the Label Setup Script shall exit code 0 で終了する
2. If 真の失敗（GitHub API 不達・認証失敗・権限不足など、ラベル状態を確定できない事象）が 1 件以上発生したとき, the Label Setup Script shall exit code 1 で終了する
3. When 全ラベルが既に存在する状態で `--force` なしで再実行されたとき, the Label Setup Script shall exit code 0 で終了する
4. If `gh` CLI が未インストールまたは未認証であるとき, the Label Setup Script shall ラベル処理に進まずエラーメッセージを標準エラーに出力し非ゼロで終了する

### Requirement 3: `--force` 指定時の上書き更新

**Objective:** As an ラベル定義（color / description）を更新したい運用者, I want `--force` を付ければ既存ラベルも安全に上書きできること, so that ラベル仕様の変更を 1 コマンドで全 repo に反映できる

#### Acceptance Criteria

1. When `--force` 付きで再実行されたとき, the Label Setup Script shall 既存ラベルを「上書き更新」として分類しサマリの `上書き更新` 件数に計上する
2. When `--force` 付きで実行され、すべてのラベルが既に存在しているとき, the Label Setup Script shall `失敗` を 0 として報告し exit code 0 で終了する
3. If `--force` 付き実行中に真の失敗（API 不達等）が発生したとき, the Label Setup Script shall そのラベルのみを「FAILED」に計上し exit code 1 で終了する

### Requirement 4: 出力フォーマットの後方互換性

**Objective:** As an 既存の install.sh / 運用ドキュメント / 既稼働 CI の利用者, I want 出力フォーマットが既存の見え方を壊さないこと, so that ログ目視・スクレイピング・ドキュメント参照が引き続き機能する

#### Acceptance Criteria

1. The Label Setup Script shall 各ラベル行を「ラベル名 ... ステータス文字列」の形式で 1 行ずつ標準出力に出力する
2. The Label Setup Script shall 既存ラベルに対するステータス文字列として `already exists (skipped; use --force to update)` を使用する
3. The Label Setup Script shall サマリセクションに `新規作成` `既存スキップ` `上書き更新` `失敗` の 4 ラベルを、現行と同じ表示順・同じ日本語ラベル名で出力する
4. The Label Setup Script shall サマリ見出しを `== 結果 ==` のまま維持する
5. Where 既存スクリプトが先頭行に絵文字や ASCII 装飾（`📌` 等）を含む見出しを出力している場合, the Label Setup Script shall それらの装飾文字列を維持する

### Requirement 5: 引数・環境変数の後方互換性

**Objective:** As an 既存の呼び出し側（install.sh / 手動運用 / ドキュメント手順）, I want 既存の起動方法をそのまま使い続けられること, so that 修正による回帰（regression）を避けられる

#### Acceptance Criteria

1. The Label Setup Script shall 引数なしの呼び出しを受け付け、カレント repo を対象として動作する
2. The Label Setup Script shall `--repo owner/name` 形式の引数で対象 repo を明示できる
3. The Label Setup Script shall `--force` および `-f` の両エイリアスを既存ラベルの上書きフラグとして受け付ける
4. When `-h` または `--help` が渡されたとき, the Label Setup Script shall ヘルプを出力し exit code 0 で終了する
5. If 既知でない引数が渡されたとき, the Label Setup Script shall エラーメッセージを標準エラーに出力し非ゼロで終了する

### Requirement 6: 定義済みラベル集合と template 同期

**Objective:** As an idd-claude のテンプレート利用者, I want root 配置と template 配置のラベルスクリプトが同じ挙動であること, so that 既に install 済みの consumer repo にも同じ修正が反映される

#### Acceptance Criteria

1. The Label Setup Script shall `auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` の 9 ラベルすべてを処理対象に含む
2. When 本要件を満たす修正が行われたとき, the Label Setup Script shall リポジトリ root 配置版（`.github/scripts/idd-claude-labels.sh`）と template 配置版（`repo-template/.github/scripts/idd-claude-labels.sh`）の両方で同等の挙動になる
3. The Label Setup Script shall 既存ラベル定義（名前・色・説明文）を本 Issue の修正で改変しない

## Non-Functional Requirements

### NFR 1: 冪等性とログの観測性

1. The Label Setup Script shall 同一 repo・同一引数での 2 回目以降の実行で、`新規作成` および `失敗` の合計件数を 0 にする
2. The Label Setup Script shall 各ラベルの分類結果（作成 / 既存 / 更新 / 失敗）を 1 ラベルあたり 1 行で標準出力に出力する
3. The Label Setup Script shall サマリの 4 件数（新規作成 / 既存スキップ / 上書き更新 / 失敗）の合計を、対象ラベル総数（9 件）と一致させる
4. If ラベル処理中に GitHub API からのエラーが発生したとき, the Label Setup Script shall そのラベル名と「FAILED」を含む 1 行を出力する

### NFR 2: 後方互換性と運用安全性

1. The Label Setup Script shall 既存の引数名・環境変数名・exit code 意味を本 Issue の修正によって変更しない
2. The Label Setup Script shall 本 Issue の修正後も sudo を要求せず、ユーザー権限のみで動作する
3. While GitHub 側のラベル取得結果がページネーション境界をまたぐ場合でも, the Label Setup Script shall ラベルの存在判定を取得順や件数上限に依存させず安定して行う

## Out of Scope

- 新規ラベルの追加、既存ラベルの削除、ラベル名・色・説明文の変更
- スクリプト名・配置先・呼び出し方法の変更
- `gh` CLI 以外のクライアントへの差し替え
- `idd-claude-labels.sh` を呼び出していない他スクリプト（`install.sh` / `setup.sh` / `issue-watcher.sh` 等）の挙動変更
- ラベル運用ポリシーやワークフロー全体の見直し

## Open Questions

- なし（再現条件・期待挙動・後方互換性スコープは Issue 本文と既存スクリプトから決定可能）
