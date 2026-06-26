# Requirements Document

## Introduction

`BASE_BRANCH` がリポジトリの default ブランチ（典型的に `main`）以外（例: `develop`）に設定された
multi-branch 運用では、impl PR が `BASE_BRANCH` に merge されたとき GitHub の
`closingIssuesReferences` が空になり、対象 Issue は auto-close されない（#389 参照）。Phase B
Promote Pipeline が `staged-for-release` を付与するルートは #389 で head ブランチ名経由の補完が
入った一方、**Issue 側の `ready-for-review` ラベルを除去する経路が存在しない**ため、merge 済 Issue が
`[ready-for-review, staged-for-release]` の両ラベルを保持したまま open で残る。

Phase E Path Overlap Checker（#18 / #221）は、dispatch×multi-branch 文脈では holder 集合から
`staged-for-release` を除外するが `ready-for-review` は holder に含めるため、上記の stale な
`ready-for-review` を握る merge 済 Issue が「編集中」と誤認され、同じ top-level path を編集する
後続 Issue を `awaiting-slot` で無期限ブロックする実害が出ている。

本要件は、(A) merge 済 Issue から `ready-for-review` を確実に除去する label 遷移を `BASE_BRANCH` の
default 性に依存せず実施し、(B) 仮に label 遷移が間に合わなくても Path Overlap Checker 側で多重防御
として「`staged-for-release` を持つ Issue は dispatch 文脈で holder から外す」既存契約（#221 Req 1.1）
が機能し続けることを宣言する。default base = repo default branch の運用は本修正の前後で外部観測差異が
生じない（後方互換）。

## 関連

- Depends on: なし（独立した修正。#389 / #221 の既存契約上に積み増す）
- Related: #18（Phase E Path Overlap） / #100（`staged-for-release` 人間付与運用） /
  #221（holder ラベル base 相対化） / #389（promote-pipeline の `closingIssuesReferences` 空対応）

## Requirements

### Requirement 1: merge 済 Issue からの `ready-for-review` 除去（base ブランチ非依存）

**Objective:** As an idd-claude 運用者, I want impl PR が merge されたら対応 Issue から
`ready-for-review` ラベルが除去されることを期待する, so that `BASE_BRANCH != default` の運用で
merge 済 Issue が stale な `ready-for-review` を握り続けて Path Overlap Checker の holder 集合に
誤って残り続けることを防げる。

#### Acceptance Criteria

1. When impl PR が `BASE_BRANCH` に merge されて Promote Pipeline が当該 PR の対応 Issue を `staged-for-release` 自動付与対象として確定したとき, the Promote Pipeline shall 当該 Issue から `ready-for-review` ラベルを除去する。
2. When `closingIssuesReferences` が空である merged impl PR について head ブランチ名 `^claude/issue-([0-9]+)-impl-` から Issue 番号を導出したとき, the Promote Pipeline shall 当該 Issue から `ready-for-review` ラベルを除去する（base ブランチが repo default かどうかに依存しない）。
3. When 対象 Issue が `ready-for-review` を持たない（既に除去済み、または最初から付与されていない）とき, the Promote Pipeline shall 除去 API 呼び出しを再送せず、後続処理を継続する。
4. While `BASE_BRANCH` がリポジトリの default ブランチ（典型的に `main`）で運用されているとき, the Promote Pipeline shall 本要件の追加経路によって外部観測差異（付与対象 Issue 集合・per-Issue ログ件数・ラベル遷移結果）を発生させない。
5. If `ready-for-review` 除去 API が失敗（タイムアウト / non-zero exit / レート制限）したとき, the Promote Pipeline shall WARN ログを 1 行残し、後続 Issue の処理および `staged-for-release` 付与経路を継続する。
6. The Promote Pipeline shall `ready-for-review` 除去対象 Issue を確定する経路として、`staged-for-release` 自動付与対象として収集した Issue 集合（#389 で拡張された head ブランチ名経由を含む和集合）を使用する。

### Requirement 2: Path Overlap Checker による多重防御（dispatch 文脈）

**Objective:** As an idd-claude 運用者, I want Requirement 1 の label 遷移が一時的に失敗した場合でも、
Path Overlap Checker が dispatch 文脈で `staged-for-release` を保持する Issue を holder から除外する
既存契約を引き続き満たすことを期待する, so that 単発の API 失敗・cron 周期のタイミング差で
merge 済 Issue が holder として残った場合でも後続 Issue が無期限ブロックされない。

#### Acceptance Criteria

1. While Path Overlap Checker が dispatch 文脈（`BASE_BRANCH != PROMOTION_TARGET_BRANCH` の multi-branch 運用）で in-flight holder を収集しているとき, the Path Overlap Checker shall `staged-for-release` のみを判定除外ラベルとして扱う既存契約（#221 Req 1.1）を維持する。
2. While 対象 Issue が `[ready-for-review, staged-for-release]` の両ラベルを併せ持つ stale 状態にあるとき, the Path Overlap Checker shall 当該 Issue を dispatch 文脈で holder 集合から除外する。
3. When 対象 Issue が `staged-for-release` を持たず `ready-for-review` のみを持つとき, the Path Overlap Checker shall 当該 Issue を従来通り holder 集合に維持する（PR 未 merge の通常 in-flight 状態を holder から外さない）。
4. While `BASE_BRANCH == PROMOTION_TARGET_BRANCH`（single-branch 運用 / 既定 default）で dispatch しているとき, the Path Overlap Checker shall 本要件導入前と同一の holder 集合を生成する（後方互換）。

### Requirement 3: 安全側挙動と境界条件

**Objective:** As an idd-claude 運用者, I want 入力（PR / Issue 番号 / head ブランチ名）が異常な
ケースで `ready-for-review` を誤って除去しないことを期待する, so that 本修正によって人間運用 PR や
他フォーマット PR の Issue 状態を破壊しない。

#### Acceptance Criteria

1. If `staged-for-release` 自動付与対象 Issue 集合の決定経路（`closingIssuesReferences` / head ブランチ名 `^claude/issue-([0-9]+)-impl-`）に該当しない PR（人間が手書きした PR / 設計 PR `claude/issue-<N>-design-*` / 他フォーマット head 等）が merged 集合に含まれていたとき, the Promote Pipeline shall 当該 PR を経路として Issue を確定せず、結果として `ready-for-review` 除去対象にも含めない。
2. If fork PR（`headRepositoryOwner.login != "$repo_owner"`）が merged 集合に含まれていたとき, the Promote Pipeline shall fork PR 除外条件を `ready-for-review` 除去経路にも適用し、当該 PR の head ブランチ名から導出した Issue 番号を対象集合に加えない。
3. If head ブランチ名から抽出した数値 ID が `^[0-9]+$` 正規表現に一致しないとき, the Promote Pipeline shall 当該値を `gh issue edit` の引数や URL に展開せず、当該 PR からの `ready-for-review` 除去経路を行わない。
4. While `PROMOTE_PIPELINE_ENABLED` が `=true` 以外（既定 `false` を含む）の環境にあるとき, the Promote Pipeline shall 本要件の追加コードパスに到達せず、`ready-for-review` 除去 API を一切発火させない。
5. If `pp_collect_merged_issues` 自体が `gh pr list` のタイムアウト / エラーで失敗したとき, the Promote Pipeline shall `ready-for-review` 除去経路も実行せず、既存 WARN ログを 1 行残して当該 cron tick を継続する。

### Requirement 4: 観測可能性

**Objective:** As an idd-claude 運用者, I want `ready-for-review` 除去アクションがログから個別に判別
可能であることを期待する, so that stale 状態の再発・人間運用との干渉を後追いで監査できる。

#### Acceptance Criteria

1. When Promote Pipeline が Issue から `ready-for-review` を新規に除去したとき, the Promote Pipeline shall `issue=#<N> action=label-remove label=ready-for-review source=auto` 形式と一意に判別可能なログを 1 行出力する。
2. When Promote Pipeline が `ready-for-review` 既未付与の Issue をスキップしたとき, the Promote Pipeline shall 当該 Issue について既存 `staged-for-release` 重複付与スキップ集計と区別可能な形でスキップを記録するか、または個別 INFO ログを出力しないことを選択できる（既存 Phase B のログ粒度方針と整合）。
3. When Promote Pipeline が `ready-for-review` 除去 API 失敗を検出したとき, the Promote Pipeline shall `issue=#<N> ready-for-review 除去に失敗（後続 Issue は継続）` 形式と一意に判別可能な WARN ログを 1 行残す。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `BASE_BRANCH` がリポジトリの default ブランチ（典型的に `main`）で運用されているとき, the Promote Pipeline shall 本修正前後で外部観測挙動（`ready-for-review` 除去対象 Issue 集合・ラベル遷移結果・per-Issue ログ・WARN ログ）を一致させる（GitHub auto-close 経路で `ready-for-review` が既に除去される状況下では、本修正の追加除去経路が観測差異を生まない）。
2. While `PROMOTE_PIPELINE_ENABLED` が `=true` 以外の環境で運用されているとき, the Promote Pipeline shall 本修正前後で API 呼び出しゼロ・log 出力ゼロ・ラベル遷移ゼロを一致させる。
3. The Promote Pipeline shall 既存 env var 名（`PROMOTE_PIPELINE_ENABLED` / `BASE_BRANCH` / `LABEL_STAGED_FOR_RELEASE` / `LABEL_READY` / `PROMOTE_GIT_TIMEOUT` 等）・ラベル名・exit code 意味・cron 登録文字列・ログ出力先を本修正で変更しない。
4. The Path Overlap Checker shall `staged-for-release` 以外の in-flight ラベル（`claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `needs-iteration` / `needs-rebase`）の holder 計上挙動を本修正前後で一致させる（#221 NFR 1.2 と整合）。

### NFR 2: API 呼び出し回数の不変性

1. The Promote Pipeline shall 1 サイクルで処理する merged PR 取得件数の上限（現状 `--limit 50`）と `staged-for-release` 付き open Issue の取得件数上限（現状 `--limit 100`）を本修正で変更しない。
2. The Promote Pipeline shall `ready-for-review` 除去のための追加 `gh issue list` / `gh pr list` 呼び出しを発火させず、`staged-for-release` 自動付与対象として既に決定された Issue 集合を入力として使用する。

### NFR 3: 未信頼入力の取り扱い

1. The Promote Pipeline shall PR の head ブランチ名（GitHub API から取得する未信頼文字列）を `jq` に渡す際は `--arg` で受け渡し、`grep` / `sed` / `bash -c` に渡す際は `--` でオプション解釈を打ち切る・クォートする等して、`-` 始まりの branch 名や正規表現メタ文字によるフラグ注入・コマンド注入を防ぐ。
2. The Promote Pipeline shall `ready-for-review` 除去対象として確定した Issue 番号を `gh issue edit` 引数に渡す前に `^[0-9]+$` で再検証し、検証に失敗した値を引数や URL に展開しない。

### NFR 4: 静的検査と近接テスト

1. The Promote Pipeline shall 本修正後の `local-watcher/bin/modules/promote-pipeline.sh` が `bash -n` で構文エラー 0、`shellcheck` で `.shellcheckrc` を踏まえた baseline 上の警告増加 0 を満たす。
2. The Test Suite shall `ready-for-review` 除去経路を `extract_function` イディオムで隔離抽出した近接テストでカバーし、以下 5 ケースを観測する: `closingIssuesReferences` 単独経路 / head ブランチ名単独経路 / 両方からの和集合 / `ready-for-review` 未付与 Issue のスキップ / `gh issue edit` 失敗時の WARN ログ。

## 確定事項（Decisions）

Issue 本文「修正方針 A（post-merge で `ready-for-review` 除去）と B（path-overlap で
`staged-for-release` 保有 Issue を holder 除外）のどちらが筋か。両方入れてもよい」について、
本要件では以下を確定する:

- **方針 A を採用（Requirement 1）**: 根本原因（label 状態の不整合）を正すため、Promote Pipeline の
  `staged-for-release` 自動付与経路に `ready-for-review` 除去を併走させる。
- **方針 B は既存契約として維持（Requirement 2）**: #221 で既に `dispatch×multi-branch` 文脈での
  `staged-for-release` 除外が実装済みのため、本要件では新規実装を要求しない。多重防御として
  既存契約が機能し続けることを宣言する位置づけ。
- **責務分界**: 「label 遷移を正す」のは Promote Pipeline（#389 で head ブランチ名経路を確立済み）、
  「holder 集合を base 相対で決定する」のは Path Overlap Checker（#221）。両者の責務を混ぜない。

## Out of Scope

- #389 が対象とした `closingIssuesReferences` 空時の auto-close 自体（Issue の close は release
  promote 時または人間運用に委ねる）。本要件は「label 遷移漏れによる Path Overlap 誤ブロック」の
  解消に限定する。
- `staged-for-release` 自動付与契約（#389 で確立済み）の変更。
- Phase E Path Overlap Checker の holder ラベル集合定義（#221）の再設計。本要件は #221 Req 1.1 を
  「多重防御として機能する前提条件」として参照するのみで、新規変更は加えない。
- develop→main の promote トリガ（`ST_CHECK_RUN_NAME` / `pp_handle_st_success` 経由の
  `staged-for-release` 除去動線）の設計変更。
- `staged-for-release` ラベルの人間付与運用（#100）と自動付与の区別を新規に導入すること
  （現行どおり同一ラベルで共有する）。
- 他 processor（`pr-reviewer` / `auto-merge` / `merge-queue` / `auto-rebase` / `pr-iteration` /
  `security-review` / `stage-a-verify` 等）の挙動変更。
- 設計 PR（`claude/issue-<N>-design-*`）に対する `ready-for-review` 除去（impl PR のみ対象という
  既存スコープ #389 と整合）。
- README の挙動説明文の大幅な再構成（必要な差分更新は別途 PR 内で実施するが、本要件は外形契約に
  限定する）。

## Open Questions

- Requirement 1.6 で「`staged-for-release` 自動付与対象として収集した Issue 集合」を `ready-for-review`
  除去経路の入力とする方針を採用しているが、`staged-for-release` 付与済 Issue 集合（`gh issue list
  --label staged-for-release --state open` の結果）を入力に取り直すべきかは設計上の選択。前者は
  最小限の API 呼び出しで完結し、後者は人間付与運用（#100）も拾える網羅性がある。本要件は前者を
  既定として記述しているが、design フェーズで後者を採用しても外形契約は満たせる。
- 設計 PR（`claude/issue-<N>-design-*`）が PR 経路で merge された場合の `ready-for-review` 除去
  スコープは Requirement 3.1 で「対象外」としているが、現運用で設計 PR の Issue 状態管理が別経路に
  ある（design reviewer ゲート経由）ため、本要件は impl PR merge 経路に限定する判断とした。
  この境界で問題ないかは人間レビューで確認したい。
