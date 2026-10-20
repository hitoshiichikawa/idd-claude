# Requirements Document

## Introduction

GitHub GraphQL API rate limit（5,000pt/h）はユーザー単位で、このサーバ上の idd-claude watcher 6 本が
共有し日中に枯渇している。最大の固定費は Promote Pipeline（`PROMOTE_PIPELINE_ENABLED=true`）で、毎
サイクル、直近 merged PR にリンクされた全 Issue に対し `staged-for-release` 有無と `ready-for-review`
有無の確認のためラベル状態を Issue ごとに 2 回、しかも毎サイクル取得している。ほぼ全件が付与済みで
結果は毎回「変更なし」であり、この状態不変 Issue の再確認が rate limit を恒常消費している。本要件は、
ラベル確認に使う GitHub API 呼び出し回数をリンク Issue 数 N に比例させず定数上界に収めつつ、毎サイクル
実ラベル状態から再導出する自己修復挙動（人間の手動ラベル操作が翌サイクルで戻る性質）と、ラベル遷移
結果の現行等価性を維持することを外形契約として規定する。

## 関連

- Depends on: なし（独立した rate limit 削減修正。#389 / #413 の既存契約上に積み増す）
- Related: #413（`ready-for-review` 除去経路） / #389（head ブランチ名経路） / #221（holder ラベル
  base 相対化） / #18（Phase E Path Overlap） / #100（`staged-for-release` 人間付与運用） /
  #521（open PR / open Issue スナップショット共有） / #536（graphql 残量取得の是正） /
  #524（GitHub App token 化）

## Requirements

### Requirement 1: リンク Issue ラベル確認 API の N 非依存化と自己修復維持

**Objective:** As an idd-claude 運用者, I want リンク Issue のラベル確認に使う GitHub API 呼び出しが
Issue 数 N に比例せず定数上界に収まり、かつ毎サイクル実ラベル状態から再導出されること, so that
GraphQL rate limit の恒常消費を抑えつつ人間の手動ラベル操作が翌サイクルで自己修復される。

#### Acceptance Criteria

1. When リンク Issue が N 件で全件が `staged-for-release` 付与済みのサイクルを処理するとき, the Promote Pipeline shall ラベル状態確認に用いる GitHub API 呼び出し回数を N に比例させず、N に依存しない定数上界に収める。
2. When 同一リンク Issue のラベル状態を 1 サイクル内で複数のラベル判定（`staged-for-release` 有無 / `ready-for-review` 有無）に用いるとき, the Promote Pipeline shall 当該 Issue のラベル状態を重複取得しない。
3. The Promote Pipeline shall `staged-for-release` 付与および `ready-for-review` 除去の判定に用いるラベル状態を、当該サイクル内で取得した実際の現在ラベル状態から毎サイクル再導出する（自己修復を維持する）。
4. While 人間が前サイクル以前に手動で `staged-for-release` を外した Issue が当該サイクルのリンク Issue 集合に含まれているとき, the Promote Pipeline shall 実ラベル状態を再取得して未付与と判定し、`staged-for-release` を再付与する。
5. The Promote Pipeline shall N によらず当該サイクルのリンク Issue 全件のラベル状態を欠落なく反映する（固定件数上限によるサイレントな取りこぼしを起こさない）。

### Requirement 2: `staged-for-release` 自動付与の結果・ログ等価性

**Objective:** As an idd-claude 運用者, I want どの Issue に `staged-for-release` が付くか・付与ログ書式が
本修正の前後で変わらないこと, so that Phase B の後続 ST 判定と監査ログが影響を受けない。

#### Acceptance Criteria

1. When リンク Issue が `staged-for-release` 未付与であると当該サイクルの実ラベル状態から判定されたとき, the Promote Pipeline shall 当該 Issue に `staged-for-release` を付与する。
2. When リンク Issue が `staged-for-release` 付与済みであると当該サイクルの実ラベル状態から判定されたとき, the Promote Pipeline shall 付与 API を再送しない。
3. When `staged-for-release` を新規付与したとき, the Promote Pipeline shall `issue=#<N> action=label-add label=staged-for-release source=auto` 形式のログを 1 行出力する。
4. If `staged-for-release` 付与 API が失敗したとき, the Promote Pipeline shall `issue=#<N> staged-for-release 自動付与に失敗（後続 Issue は継続）` 形式の WARN を 1 行残し、後続 Issue の処理を継続する。
5. The Promote Pipeline shall サイクル終了時に `auto-label サマリ: staged-for-release-added=<n>, already-labeled-skipped=<m>` 形式のサマリログを本修正前と同一書式で出力する。

### Requirement 3: `ready-for-review` 除去（#413 救済）の維持

**Objective:** As an idd-claude 運用者, I want merge 済リンク Issue から `ready-for-review` が除去される
#413 の救済挙動が維持されること, so that stale な `ready-for-review` が Path Overlap Checker の holder
集合に残って後続 Issue を無期限ブロックしない。

#### Acceptance Criteria

1. When リンク Issue が `ready-for-review` を持つと当該サイクルの実ラベル状態から判定されたとき, the Promote Pipeline shall 当該 Issue から `ready-for-review` を除去する（base ブランチが repo default かどうかに依存しない）。
2. When リンク Issue が `ready-for-review` を持たないと判定されたとき, the Promote Pipeline shall 除去 API を再送しない。
3. When `ready-for-review` を除去したとき, the Promote Pipeline shall `issue=#<N> action=label-remove label=ready-for-review source=auto` 形式のログを 1 行出力する。
4. If `ready-for-review` 除去 API が失敗したとき, the Promote Pipeline shall `issue=#<N> ready-for-review 除去に失敗（後続 Issue は継続）` 形式の WARN を 1 行残し、後続 Issue の処理を継続する。
5. While 人間が手動で `ready-for-review` を付け直した merge 済リンク Issue が当該サイクルのリンク Issue 集合に含まれているとき, the Promote Pipeline shall 実ラベル状態を再取得して付与ありと判定し、`ready-for-review` を再度除去する（自己修復を維持する）。

### Requirement 4: 異常系・安全側挙動・機能無効時 no-op

**Objective:** As an idd-claude 運用者, I want ラベル状態取得の失敗・不正な Issue 番号・機能無効時に
安全側で振る舞い pipeline 全体を止めないこと, so that 単発の API 失敗や異常入力が watcher サイクルを
破壊しない。

#### Acceptance Criteria

1. If リンク Issue のラベル状態取得が失敗（タイムアウト / non-zero exit / レート制限）したとき, the Promote Pipeline shall WARN を出力し、後続 Issue の処理および後続 processor を継続する。
2. If merged PR 一覧の取得（`gh pr list`）自体が失敗したとき, the Promote Pipeline shall 既存 WARN を 1 行残し、当該サイクルのラベル確認・付与・除去を行わず後続 processor を継続する。
3. The Promote Pipeline shall リンク Issue 番号を `gh issue edit` の引数や URL に展開する直前に `^[0-9]+$` で再検証し、不一致の値を展開しない。
4. While `PROMOTE_PIPELINE_ENABLED` が `=true` 以外（既定 `false` を含む）の環境にあるとき, the Promote Pipeline shall ラベル確認・付与・除去に関する GitHub API 呼び出しを一切発火させない。

### Requirement 5: 結果等価性と検証

**Objective:** As an idd-claude 運用者, I want ラベル遷移結果が本修正前後で等価であることと API 呼び出し
回数の N 非依存性がテストで担保されること, so that opt-in gate なしで既定挙動を差し替えられる根拠が
得られる。

#### Acceptance Criteria

1. The Promote Pipeline shall 任意のリンク Issue 集合について、本修正前後で「どの Issue に `staged-for-release` が付く／外れるか」および「どの Issue から `ready-for-review` が外れるか」の結果を一致させる。
2. Where ラベル確認 API 呼び出し回数を検証する近接テストが追加されるとき, the Test Suite shall リンク Issue 数 N を変化させたときに当該呼び出し回数が N に比例しないことを呼び出しトレースで観測する。
3. The Test Suite shall 既存テスト（`pp_remove_ready_for_review_test.sh` / `pp_extract_linked_issues_test.sh` / `sn_callsite_promote_test.sh`）を本修正後も通過させる。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Promote Pipeline shall 既存 env var 名（`PROMOTE_PIPELINE_ENABLED` / `BASE_BRANCH` / `LABEL_STAGED_FOR_RELEASE` / `LABEL_READY` / `PROMOTE_GIT_TIMEOUT` 等）・ラベル名・exit code 意味・cron 登録文字列・ログ出力先を本修正で変更しない。
2. While `PROMOTE_PIPELINE_ENABLED` が `=true` 以外の環境にあるとき, the Promote Pipeline shall 本修正前後で API 呼び出しゼロ・ログ出力ゼロ・ラベル遷移ゼロを一致させる。
3. The Promote Pipeline shall ラベル遷移結果を変えないため本機能を新規 opt-in gate の背後に置かず、結果等価性を Requirement 5.1 のテストで示す（付与・除去の結果が変わりうる方向は採らない）。

### NFR 2: rate limit 削減目標（定量）

1. The Promote Pipeline shall リンク Issue N 件・全件付与済みのサイクルにおけるラベル確認 API 呼び出し回数を、現行の 2×N 回から N に依存しない定数（目安として 1 サイクルあたり十数回未満、例: N=24 のとき現行 48 回 → 修正後は N に比例しない一定回数）に削減する。
2. The Promote Pipeline shall merged PR 取得件数の上限（現状 `--limit 50`）を本修正で変更しない。

### NFR 3: 未信頼入力の取り扱い

1. The Promote Pipeline shall PR の head ブランチ名（GitHub API から取得する未信頼文字列）を `jq` に渡す際は `--arg` で受け渡し、`grep` / `git` / `gh` に渡す際は `--` でオプション解釈を打ち切る等で `-` 始まりの値や正規表現メタ文字によるフラグ・コマンド注入を防ぐ。
2. The Promote Pipeline shall ラベル確認・付与・除去対象の Issue 番号を使用直前に `^[0-9]+$` で再検証する。

### NFR 4: 状態ファイル配置

1. Where ラベル確認結果を横断的に保持するファイルを導入する場合, the Promote Pipeline shall 当該ファイルを `$HOME/.issue-watcher/` 配下に配置し、`/tmp` の予測可能名を避ける（かつ Requirement 1.3 の毎サイクル再導出＝自己修復を損なわない範囲に限る）。

### NFR 5: 静的検査と近接テスト

1. The Promote Pipeline shall 本修正後の `local-watcher/bin/modules/promote-pipeline.sh` が `bash -n` で構文エラー 0、`shellcheck`（`.shellcheckrc` baseline）で警告増加 0 を満たす。

## Out of Scope

- ST 判定側（`pp_resolve_merge_sha` / `pp_get_st_state`）の per-Issue API 削減。
- promote / revert ロジックの変更。
- graphql 残量取得の是正（#536）。
- GitHub App token 化による rate limit バケット分離（#524）。
- #521 のスナップショット共有（open PR / open Issue 一覧）を closed Issue 参照経路へ拡張すること。
- `staged-for-release` 人間付与運用（#100）と自動付与の source 区別を新規に導入すること
  （現行どおり同一ラベルで共有する）。
- 状態ファイルで付与済み・除去済みを記録し次サイクル以降 API を呼ばない方向（仮案 D の非自己修復
  挙動）を既定挙動として採ること。Requirement 1.3 の自己修復維持と両立しないため既定では採らない。
- 他 processor（`pr-reviewer` / `auto-merge` / `merge-queue` / `auto-rebase` / `pr-iteration` /
  `security-review` / `stage-a-verify` 等）の挙動変更。
- 設計 PR（`claude/issue-<N>-design-*`）に対するラベル遷移（impl PR / head `^claude/issue-([0-9]+)-impl-`
  経路のみ対象という既存スコープ #389 / #413 と整合）。
- README の挙動説明文の大幅な再構成（必要な差分更新は同一 PR 内で実施するが、本要件は外形契約に
  限定する）。

## Open Questions

- N 非依存かつ自己修復を保つ具体的な実装機構（複数 Issue の labels を 1 回の GraphQL クエリで
  まとめ取得する仮案 B か、`staged-for-release` 付き / `ready-for-review` 付きの Issue 一覧を
  ラベル別に定数回取得してリンク Issue 集合と突き合わせる仮案 C か）は Architect / Developer の
  判断に委ねる。いずれも Requirement 1（N 非依存・自己修復・欠落なし）と Requirement 5.1（結果
  等価）を満たせる。仮案 C はラベル別一覧に closed Issue も含まれ得るため、Requirement 1.5 の
  「取りこぼしなし」を満たす件数上限・ページングの扱いに注意すること。
- NFR 2.1 の定数上界の厳密値（十数回未満の目安に対する具体値）は採用機構に応じて design で確定して
  よい。
- Issue の「判断を委ねたい点」（自己修復を維持すべきか）は、Issue のトーンおよび #413 救済挙動維持
  要求から本要件で「維持する」（Requirement 1.3 / 1.4 / 3.5）と確定済み。Issue コメントに人間の
  明示回答は無いが、この確定により追加の人間判断は不要と判断した。異論があれば design 前に
  Issue コメントで再提起可能。
