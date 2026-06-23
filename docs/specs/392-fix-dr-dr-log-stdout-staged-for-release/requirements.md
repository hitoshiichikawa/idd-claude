# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` の dependency-resolver (`dr_*`) 系において、`dr_log()`
が stdout に echo（`>&2` 無し）するため、`dr_resolve_one` の OPEN + `staged-for-release`
解決パスで `dr_log` を呼んだ直後に `echo "resolved"` で戻り値を返す並びが、呼び出し側
`dr_unblock_sweep` の `verdict=$(dr_resolve_one ...)` 捕捉に **ログ行と戻り値の両方** を
混入させる。結果、parser は捕捉文字列を `resolved` でも `open` でも `api error` でもない
「未知の verdict」と判断し、対象 Issue を `unblock_keep` のまま放置する。`#117` (OPEN +
`staged-for-release`) に依存する `#115` が `#117` 解決後も `blocked` のまま外れない事象
として実機再現済みであり、`BASE_BRANCH != main` 環境（2-branch / gitflow）で
`DEP_AUTO_UNBLOCK` の中核機能が完全に機能しない。CLAUDE.md「標準出力は機械可読な結果用に
予約・ログは `>&2`」規約とも整合させる必要がある。

本要件は、(1) `dr_log` / `dr_warn` の出力先を stderr に揃えて verdict 捕捉の汚染を解消し、
(2) dr 系で stdout を「機械可読な戻り値」に使う関数群（特に `dr_resolve_one`）で同一実行
パスにログを混入しないことを保証する棚卸しを行い、(3) 他モジュールの `*_log` についても
同型バグ（stdout ログ + 同関数 stdout 戻り値捕捉）が存在しないかを軽く確認する範囲を扱う。
既存の `BASE_BRANCH=main` 経路・CLOSED→`resolved`/`closed unmerged` 経路・`api error`
経路・cron.log への可視性を一切壊さないことを要件として明文化する。

## 関連

- Depends on: なし（独立した修正）
- Related: #346（`DEP_AUTO_UNBLOCK` / blocked 自動解除スイープ） / #316（`staged-for-release`
  依存の resolved 判定） / #117（実機再現の依存先） / #115（実機再現の被ブロッキング Issue）

## Requirements

### Requirement 1: dr 系ロガーの stderr 化と verdict 捕捉の非汚染

**Objective:** As an idd-claude 運用者, I want `dr_log` / `dr_warn` の出力が stdout を
汚染しないこと, so that `dr_resolve_one` の stdout を捕捉する呼び出し側
（`dr_unblock_resolve_one_issue` の `verdict=$(dr_resolve_one ...)`）が常に厳密な戻り値
だけを受け取れ、`staged-for-release` 解決パスでも対象 Issue が自動 unblock される。

#### Acceptance Criteria

1. The Dependency Resolver shall `dr_log` の出力先を stderr とし、stdout には 1 文字も
   書き出さない。
2. The Dependency Resolver shall `dr_warn` の出力先を stderr とし、stdout には 1 文字も
   書き出さない。
3. When `dr_resolve_one` が OPEN + `staged-for-release` を resolved として判定した,
   the Dependency Resolver shall stdout に厳密に `resolved` のみ（末尾改行を除き他文字を
   含まない）を出力する。
4. When `dr_resolve_one` が OPEN + `staged-for-release` なしを open として判定した,
   the Dependency Resolver shall stdout に厳密に `open` のみを出力する。
5. When `dr_resolve_one` が CLOSED + merged PR 1 件以上 を resolved として判定した,
   the Dependency Resolver shall stdout に厳密に `resolved` のみを出力する。
6. When `dr_resolve_one` が CLOSED + merged PR ゼロ件 を closed unmerged として判定した,
   the Dependency Resolver shall stdout に厳密に `closed unmerged` のみを出力する。
7. If `dr_resolve_one` が GraphQL 失敗・jq parse 失敗・想定外応答構造のいずれかを検知した,
   the Dependency Resolver shall stdout に厳密に `api error` のみを出力する。
8. When `dr_unblock_resolve_one_issue` が `dr_resolve_one` の stdout を `verdict=$(...)`
   で捕捉した, the Dependency Resolver shall 捕捉文字列が `resolved` / `open` /
   `closed unmerged` / `api error` のいずれかと完全一致し、`未知の verdict` 分岐に到達
   しない（OPEN + `staged-for-release` 解決パスを含む）。

### Requirement 2: DEP_AUTO_UNBLOCK の 2-branch 環境での復旧

**Objective:** As an idd-claude 運用者, I want `BASE_BRANCH != main` 環境で全依存が
`staged-for-release` 経由 resolved になった blocked Issue が自動的に `blocked` 除去
されること, so that gitflow 運用や 2-branch 運用でも依存チェーンが順送りで進む
full-auto が止まらない。

#### Acceptance Criteria

1. While `DEP_AUTO_UNBLOCK_ENABLED=true` かつ `FULL_AUTO_ENABLED=true` かつ
   `BASE_BRANCH != main`, when ある blocked Issue の全依存先が OPEN + `staged-for-release`
   付与済み状態にある, the Dependency Resolver shall 当該 Issue の `blocked` ラベルを
   除去し、自動解除コメント（`DR_UNBLOCK_MARKER_CLEARED` マーカー付き）を 1 件投稿する。
2. When 上記の自動解除が成功した, the Dependency Resolver shall 構造化ログ
   `issue=#<N> extracted=... resolved=... unresolved= verdict=unblock_cleared` を 1 行
   残し、`未知の verdict` を含むログを残さない。
3. While 上記の sweep 後に同一 tick の `_dispatcher_run` メイン候補列挙が走った,
   the Dependency Resolver shall `blocked` 除去済み Issue が `-label:"blocked"` 除外条件
   を満たし通常 pickup に合流できる（既存 fall-through 動線 / #346 Req 2.3 を維持）。

### Requirement 3: 後方互換と既存解決経路の温存

**Objective:** As an idd-claude 運用者, I want 本修正によって `BASE_BRANCH=main` 既存運用・
CLOSED→`resolved` / `closed unmerged` 経路・`api error` 経路・`DEP_AUTO_UNBLOCK_ENABLED`
未設定環境の外部観測挙動が一切変わらないこと, so that 既存 consumer repo の依存解決・
ラベル遷移・cron 実行コスト・log 出力の集約位置が無告知で変わらない。

#### Acceptance Criteria

1. While `DEP_AUTO_UNBLOCK_ENABLED` が `=true` 以外（既定 `false` を含む）, the Dependency
   Resolver shall `dr_unblock_sweep` の本体処理に到達せず、本修正による追加コードパスにも
   到達しない（既存 opt-in gate の挙動を維持する）。
2. While `BASE_BRANCH=main`, the Dependency Resolver shall 本修正前後で `dr_resolve_one`
   が返す verdict 集合・順序・各依存先について発火する gh GraphQL 呼び出し回数を一致させる。
3. When `dr_resolve_one` が CLOSED + merged PR 1 件以上 / CLOSED + merged PR ゼロ件 /
   GraphQL 失敗 / `api error` 経路 を辿った, the Dependency Resolver shall 本修正前後で
   stdout 戻り値・stderr 警告・呼び出し側の verdict 分岐到達結果を一致させる。
4. The Dependency Resolver shall 既存の env var 名（`DEP_AUTO_UNBLOCK_ENABLED` /
   `FULL_AUTO_ENABLED` / `BASE_BRANCH` / `LABEL_BLOCKED` / `LABEL_STAGED_FOR_RELEASE`
   等）・ラベル名・exit code 意味・cron 登録文字列を本修正で変更しない。
5. The Dependency Resolver shall `dr_unblock_sweep` 内の `gh issue list` 取得件数上限
   （`--limit 50`）・FIFO 順（`sort:created-asc`）・終端ラベル除外条件・cycle 検出
   （`dc_cycle_sweep`）連携を本修正で変更しない。

### Requirement 4: cron.log への可観測性の維持

**Objective:** As an idd-claude 運用者, I want `dr_log` / `dr_warn` を stderr 化しても
従来どおり cron.log で全行が観測できること, so that 既存の障害分析・grep 集計（`grep ' dr:'`
や `grep 'verdict='` 等）が引き続き機能する。

#### Acceptance Criteria

1. The Dependency Resolver shall 本修正後の `dr_log` / `dr_warn` 出力が cron 経由
   （cron が `>>cron.log 2>&1` で標準エラーを標準出力にマージする運用前提）で cron.log
   に従来と同じ 1 行フォーマット（`[YYYY-MM-DD HH:MM:SS] dr: ...` および
   `[YYYY-MM-DD HH:MM:SS] dr: WARN: ...`）で出現する。
2. The Dependency Resolver shall `dr_log` / `dr_warn` のメッセージ語彙（`verdict=...` /
   `extracted=...` / `unresolved=...` / `dep=#<N>` 等のキー）と prefix `dr:` を本修正で
   変更しない（既存 grep / 集計クエリを破壊しない）。
3. The Dependency Resolver shall `dr_error` の出力先（stderr）を本修正で変更しない
   （既存仕様維持）。

### Requirement 5: dr 系 stdout 戻り値関数の棚卸し

**Objective:** As an idd-claude メンテナ, I want dr 系で stdout を「機械可読な戻り値」に
使っている全関数について、同一実行パスにログを stdout 混入していない状態を確認したい,
so that 本 Issue と同型のバグ（戻り値捕捉に dr_log/dr_warn 行が紛れ込む）が他の経路で
潜在しないことを保証する。

#### Acceptance Criteria

1. The Dependency Resolver shall `dr_resolve_one` のすべての終端パス（OPEN+`staged-for-release`
   / OPEN+ラベル無し / CLOSED+merged 1 件以上 / CLOSED+merged ゼロ件 / `api error` 5 経路）
   について stdout が verdict 文字列ちょうど 1 行のみであることを満たす。
2. The Dependency Resolver shall `dr_extract_deps` の stdout が「Issue 番号の改行区切り
   集合（各行が `^[0-9]+$`）」のみで構成され、ログ文字列を混入しないことを満たす。
3. The Dependency Resolver shall `dr_format_unresolved_comment` の stdout が
   エスカレーション markdown 本文のみで構成され、ログ文字列を混入しないことを満たす。
4. The Dependency Resolver shall `dr_gh_graphql_closed_by` の stdout が GraphQL レスポンス
   JSON のみで構成され、ログ文字列を混入しないことを満たす。

### Requirement 6: 他モジュール `*_log` の同型バグ横展開チェック

**Objective:** As an idd-claude メンテナ, I want 他モジュール（`qa_` / `mq_` / `pi_` /
`pr_` / `ar_` / `pp_` / `sec_` / `cm_` / `sh_` / `sav_` / `gh_` / `sr_` / `fr_` / `sc_` /
`tc_` / `pt_` 等）の `*_log` についても、stdout 出力 + 同関数 stdout 戻り値捕捉という
同型バグが現存しないことを軽く確認したい, so that 本修正の知見を repo 全体に横展開する
最小コストの一巡が行われ、潜在バグの早期発見につながる。

#### Acceptance Criteria

1. The Maintainer Audit shall 各モジュールの `*_log` 関数について、呼び出し側が
   `result=$(<関数名> ...)` 形式で stdout を捕捉する関数を網羅的に列挙し、その関数本体
   内で `*_log` 系（stdout 出力ロガー）が呼ばれていないことを確認する。
2. When 横展開チェックで同型バグの候補が 1 件以上見つかった, the Maintainer Audit shall
   当該候補を本 Issue 内で修正対象に追加するか、別 Issue として切り出すかの判断を
   `impl-notes.md` または PR 本文に記録する。
3. When 横展開チェックで同型バグの候補が 0 件であった, the Maintainer Audit shall その旨を
   `impl-notes.md` または PR 本文に「`*_log` 横展開チェック: 同型バグ無し」として 1 行
   残し、確認したモジュール集合を明示する。
4. The Maintainer Audit shall 本 Issue のスコープにおいて他モジュールの `*_log` の
   stdout/stderr 出力先を一括書き換えしない（Out of Scope を尊重し、必要なら別 Issue に
   切り出す）。

### Requirement 7: 回帰防止テスト（dr_resolve_one stdout 純度）

**Objective:** As an idd-claude メンテナ, I want `dr_resolve_one` の `staged-for-release`
解決パスについて、**実際の stdout を厳密一致で検証する** 近接テストを追加したい,
so that 既存テスト（`dr_unblock_sweep_test.sh`）が `dr_log` / `dr_resolve_one` を stub
していて本 Issue の汚染を見逃してきた構造欠陥を、実 stdout 捕捉で再現するケースを足す
ことで補修できる。

#### Acceptance Criteria

1. The Test Suite shall `dr_resolve_one`（および間接的に `dr_log` 実体）を
   `extract_function` イディオムで隔離抽出し、`gh` のみを stub した状態で
   `verdict=$(dr_resolve_one <N>)` を実行する近接テストを `local-watcher/test/` 配下に
   追加する。
2. The Test Suite shall OPEN + `staged-for-release` 付与済み・`BASE_BRANCH != main` の
   fixture について、捕捉した `verdict` 変数の値が文字列 `resolved` と **完全一致**
   （末尾改行を除き他文字を含まない）することを確認する。
3. The Test Suite shall 上記ケースで `dr_log` の出力が stderr 経由のみで観測される
   （`{ verdict=$(dr_resolve_one <N>); } 2>captured_stderr` でリダイレクトしたとき、
   `captured_stderr` に `dr: ... verdict=resolved reason=staged-for-release` 行が含まれ、
   `verdict` 変数側には含まれない）ことを確認する。
4. The Test Suite shall OPEN + ラベル無し / CLOSED + merged 1 件以上 / CLOSED + merged
   ゼロ件 / GraphQL errors 検知 / jq parse 失敗 の 5 経路について、それぞれ stdout が
   厳密に `open` / `resolved` / `closed unmerged` / `api error` / `api error` のいずれかと
   完全一致することを確認する。
5. The Test Suite shall 既存 `dr_unblock_sweep_test.sh` の `dr_log` / `dr_warn` stub が
   本修正後も実害（戻り値捕捉汚染）を引き起こさない構成であることを、抽出 + 実 stdout
   捕捉テストの存在によって担保する（既存テストの stub 自体は維持してよい）。

### Requirement 8: root ↔ repo-template 同期と README 反映

**Objective:** As an idd-claude メンテナ, I want 本修正を root `.claude/` / repo-template
の二重管理規約に従って整合的に反映したい, so that consumer repo に配布される
`issue-watcher.sh` 系統で同じ修正が同時に有効化される。

#### Acceptance Criteria

1. The Maintainer shall 本修正が `local-watcher/bin/issue-watcher.sh` 単体で完結する場合
   （`.claude/agents` / `.claude/rules` の変更を伴わない場合）、`diff -r` 同期確認は対象外
   とする（CLAUDE.md の二重管理鉄則は agents/rules を対象とするため）。
2. When 修正が consumer 配布対象（`local-watcher/bin/issue-watcher.sh`）に閉じる場合,
   the Maintainer shall README の挙動説明文に「dr_log / dr_warn は stderr 出力」「cron 経由
   での集約位置は不変」を必要時のみ追記し、不要なら追記しない（既存挙動の説明を破壊しない
   範囲）。
3. While 本修正で `.claude/agents` / `.claude/rules` を変更しない, the Maintainer shall
   `diff -r .claude/agents repo-template/.claude/agents` および
   `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する
   （現状維持）。

## Non-Functional Requirements

### NFR 1: 静的検査と構文健全性

1. The Dependency Resolver shall 本修正後の `local-watcher/bin/issue-watcher.sh` が
   `bash -n` で構文エラー 0、`shellcheck` で `.shellcheckrc` を踏まえた baseline 上の
   警告増加 0 を満たす。
2. The Test Suite shall 追加した近接テストの bash スクリプトが `bash -n` / `shellcheck`
   クリーンであることを満たす。

### NFR 2: 後方互換性

1. The Dependency Resolver shall 既存ラベル名 `blocked` / `staged-for-release` /
   `claude-failed` / `needs-decisions` を本修正で改名・別名追加せず、定数経由の参照を
   破壊しない。
2. The Dependency Resolver shall 本修正前後で `DEP_AUTO_UNBLOCK_ENABLED` 未設定 / `false`
   環境の外部観測挙動（gh API 呼び出しゼロ・log 出力ゼロ・ラベル遷移ゼロ）を一致させる。
3. The Dependency Resolver shall 本修正前後で `dr_resolve_one` の戻り値語彙集合
   （`resolved` / `open` / `closed unmerged` / `api error`）を変更しない。

### NFR 3: 可観測性

1. The Dependency Resolver shall 本修正後の `dr_log` 1 行フォーマット
   `[YYYY-MM-DD HH:MM:SS] dr: <message>` および `dr_warn` 1 行フォーマット
   `[YYYY-MM-DD HH:MM:SS] dr: WARN: <message>` を変更しない。
2. The Dependency Resolver shall `staged-for-release` 解決時の構造化ログメッセージ
   `issue=#<N> verdict=resolved reason=staged-for-release base=<branch>` の語彙とキー順序
   を本修正で変更しない（既存 grep / 集計クエリを破壊しない）。

### NFR 4: 未信頼入力の取り扱い

1. The Dependency Resolver shall 本修正で新規導入する出力リダイレクト（`>&2`）について、
   GitHub API レスポンスや Issue 本文に含まれる未信頼文字列を `dr_log` / `dr_warn` 引数
   としてそのまま流す場合でも、stdout / stderr 区別が破壊されない記述で実装する
   （変数展開のクォート維持 / リダイレクト先の固定化）。

## Out of Scope

- 他モジュールの `*_log`（`qa_log` / `mq_log` / `pp_log` / `pi_log` / `pr_log` /
  `ar_log` / `sec_log` / `cm_log` / `sh_log` / `sav_log` / `gh_log` / `sr_log` /
  `fr_log` / `sc_log` / `tc_log` / `pt_log` 等）の stdout → stderr 一括書き換え
  （横展開チェックで同型バグが見つからなければ書き換えを行わない。仮に見つかった場合も
  本 Issue では扱わず別 Issue として切り出す方針）。
- `dr_resolve_one` の戻り値語彙集合の拡張（`resolved` / `open` / `closed unmerged` /
  `api error` の 4 種を維持する）。
- `dr_unblock_sweep` の対象 Issue 列挙クエリ・FIFO 順・上限値の変更。
- `dc_cycle_sweep` との連携（cycle 検出・除外）ロジックの変更。
- `DEP_AUTO_UNBLOCK_ENABLED` / `FULL_AUTO_ENABLED` の既定値・正規化ルールの変更。
- README の挙動説明文の大幅な再構成（必要な差分更新は別途 PR 内で行うが、本要件は外形
  契約に限定する）。
- `staged-for-release` ラベルの付与・除去動線そのものの変更（#100 / #389 系統）。
- cron 設定（`>>cron.log 2>&1` 等のリダイレクト指定）の変更・推奨手順の更新。

## Open Questions

- なし（Issue #392 本文に根本原因（`dr_log` の stdout echo）と修正方針（`>&2` 化 +
  棚卸し + 横展開チェック + 近接テスト追加）が明示済みで、AC・DoD・スコープ外も整理
  されている。実装上の選択肢（`dr_log` 本体の `>&2` 追加のみで完結するか、`dr_*` 系
  すべての出力先を一括正規化するか）は設計レイヤの裁量であり requirements では規定
  しない）。
