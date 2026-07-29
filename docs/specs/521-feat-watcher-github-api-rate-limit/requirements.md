# Requirements Document

## Introduction

idd-claude の watcher は 1 回の cron tick（サイクル）で複数のプロセッサ（Merge Queue / PR
Iteration / PR Reviewer / Design Review Release / Issue Pickup / Dispatcher 等）を順に実行する。
各プロセッサが独立に PR 一覧・Issue 一覧を GitHub API から取得しているため、同一サイクル内で同じ
一覧取得が重複し、GitHub API rate limit（GraphQL は 5,000 point/h をアカウント内の全ツールで共有）
を急速に消費する。rate limit 枯渇時にはプロセッサが失敗し、特に resumable return 時の状態遷移系
ラベル操作（`claude-picked-up` 除去等）が失敗すると Issue が孤児化する。

本機能は (1) 一覧取得のサイクル内スナップショット共有、(2) バケット別残量の可視化、(3) 残量閾値
割れ時の WARN と縮退、(4) 状態遷移系ラベル操作の限定リトライ、(5) hot path の一部を REST（core
バケット）へ逃がす負荷分散、の 5 点を **すべて opt-in / 既定安全側** で導入し、GitHub API 消費を
削減しつつ rate limit 耐性を高める。self-hosting（dogfooding）前提のため、未設定環境で挙動が一切
変わらない後方互換性を最優先とする。

> Note: 本 Issue が対象とするのは **GitHub API rate limit**（core / graphql / search バケット）
> であり、Claude Max サブスクリプションの 5 時間 quota（Issue #66 / #104 が対象とする
> `rate_limit_event`）とは別物である。両者を混同しないよう用語を分離する。

## 用語定義

- **サイクル (cycle)**: watcher の 1 回の cron tick。起動から全プロセッサ実行完了・終了までの単位。
- **一覧系取得 (list fetch)**: PR 一覧 / Issue 一覧を GitHub API から取得する操作。
- **スナップショット (snapshot)**: サイクル冒頭で 1 回だけ取得し、当該サイクル内の複数プロセッサが
  共有参照する一覧系データのコピー。
- **バケット (bucket)**: GitHub API rate limit のリソース区分。本 Issue では core / graphql /
  search を対象とする。`/rate_limit` エンドポイントの参照自体は消費対象外。
- **縮退 (degradation)**: 残量が閾値を下回ったときに、非必須プロセッサを skip する等して API 消費を
  抑える動作。
- **状態遷移系ラベル操作 (state transition label operation)**: Issue / PR の処理状態を進める・
  巻き戻すためのラベル付け外し。例: resumable return 時の `claude-picked-up` 除去。
- **hot path**: 1 サイクル内で高頻度に呼ばれる GitHub API 参照経路。

## Requirements

### Requirement 1: Opt-in 切り替えと既定挙動の後方互換

**Objective:** As a 既存運用者, I want 本 Issue の 5 機能を明示的に有効化するまで watcher の挙動が
一切変わらないこと, so that 既存 cron / launchd 運用に無告知のダウンタイムや挙動変化が起きない

#### Acceptance Criteria

1. While 本機能群の opt-in env フラグがいずれも未設定または無効である間, the Issue Watcher shall
   スナップショット共有・バケット可視化・縮退・限定リトライ・負荷分散のいずれの新挙動も実行しない
2. The Issue Watcher shall 本機能群の各 env フラグの既定値を、有効化前と同一の挙動（no-op）となる
   安全側に固定する
3. If 本機能群の env フラグに不正値・typo が与えられたとき, the Issue Watcher shall 当該機能を
   無効（安全側）に正規化して扱う
4. The Issue Watcher shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` /
   `TRIAGE_MODEL` / `DEV_MODEL` 等）の名前・受理形式・意味を本機能の追加によって変更しない
5. The Issue Watcher shall 既存ラベル名・exit code の意味・cron 登録文字列・ログ出力先
   （`LOG_DIR` 配下）を本機能の追加によって変更しない
6. The Issue Watcher shall 本機能の追加によって新規ラベルを導入しない

### Requirement 2: サイクル内スナップショット共有

**Objective:** As a 運用者, I want 一覧系取得をサイクル冒頭 1 回に集約して各プロセッサが共有参照する,
so that 同一サイクル内の重複取得で GitHub API を無駄に消費しない

#### Acceptance Criteria

1. Where スナップショット共有が有効である, the Issue Watcher shall サイクル冒頭で PR 一覧および
   Issue 一覧を各 1 回取得し、当該サイクル内のプロセッサが参照するスナップショットとして保持する
2. While スナップショットが当該サイクル内で有効である間, the Issue Watcher shall 同一種別の一覧系
   取得を対象プロセッサごとに再実行しない
3. When 各プロセッサがスナップショットを参照して判定を行うとき, the Issue Watcher shall 従来の個別
   取得時と等価な判定結果を返す
4. Where 鮮度がクリティカルなチェック（claim 競合・merge 直前確認等）が含まれる, the Issue Watcher
   shall 当該チェックでスナップショットではなく個別取得を用いる
5. If サイクル冒頭のスナップショット取得が失敗したとき, the Issue Watcher shall 従来どおり各
   プロセッサの個別取得へフォールバックし、当該サイクルを中断しない
6. When スナップショット取得に失敗してフォールバックしたとき, the Issue Watcher shall その旨を
   warn ログに記録する

### Requirement 3: バケット別 rate limit の可視化

**Objective:** As a 運用者, I want core / graphql / search 各バケットの消費・残量をサイクルごとに
把握したい, so that rate limit 枯渇の予兆をログから検知できる

#### Acceptance Criteria

1. Where バケット可視化が有効である, the Issue Watcher shall 各サイクル終端に core / graphql /
   search バケットの残量・上限を 1 行のログとして出力する
2. The Issue Watcher shall バケット可視化のための `/rate_limit` 参照を rate limit 消費対象に
   含めない経路で行う
3. The Issue Watcher shall バケット可視化ログを grep で事後検索可能な固定フォーマット（バケット
   名・残量・上限を含む）で出力する
4. If バケット残量情報の取得が失敗したとき, the Issue Watcher shall 当該サイクルの後続処理を中断
   せず、取得失敗を warn ログに記録する

### Requirement 4: 残量閾値割れ時の WARN と縮退

**Objective:** As a 運用者, I want 残量が閾値を下回ったら警告と非必須処理の縮退が働くこと, so that
rate limit 枯渇による全面停止を避けて必須処理を守れる

#### Acceptance Criteria

1. Where 縮退が有効である, the Issue Watcher shall 対象バケットの残量が設定閾値を下回ったときに
   WARN ログを出力する
2. When 残量が縮退閾値を下回ったとき, the Issue Watcher shall 非必須プロセッサ（レビュー系・
   可視化系）の実行を当該サイクルで skip する
3. While 残量が縮退閾値を下回っている間, the Issue Watcher shall dispatch および状態遷移系処理を
   skip しない
4. The Issue Watcher shall 縮退閾値を env var で調整可能にし、既定値を必須処理を完遂できる余力を
   残す保守的な値に固定する
5. When 縮退によりプロセッサを skip したとき, the Issue Watcher shall skip したプロセッサ名と判定
   根拠（バケット名・残量・閾値）をログに記録する
6. While 縮退が無効である間, the Issue Watcher shall 残量にかかわらずプロセッサを skip しない

### Requirement 5: 状態遷移系ラベル操作の限定リトライ

**Objective:** As a 運用者, I want rate limit 起因で状態遷移系ラベル操作が失敗しても孤児化しない
こと, so that resumable return 後の Issue が `claude-picked-up` を保持したまま放置されない

#### Acceptance Criteria

1. Where 限定リトライが有効である, the Issue Watcher shall resumable return 時の状態遷移系ラベル
   操作を失敗時リトライの対象に含める
2. If 状態遷移系ラベル操作（`claude-picked-up` 除去等）が rate limit 起因で失敗したとき, the
   Issue Watcher shall 当該操作を設定された上限回数まで再試行する
3. The Issue Watcher shall 再試行回数上限を env var で調整可能にし、既定値を有限かつ安全側の値に
   固定する
4. If 上限回数までの再試行でも当該操作が完遂しなかったとき, the Issue Watcher shall 当該 Issue を
   次 tick で再試行される状態（孤児化しない状態）に保つ
5. The Issue Watcher shall リトライにおいて holder から誤ってラベルを外す等の安全側原則に反する
   遷移を発生させない
6. When 状態遷移系ラベル操作を再試行したとき, the Issue Watcher shall 対象 Issue 番号・操作種別・
   試行回数をログに記録する

### Requirement 6: GraphQL から REST への負荷分散

**Objective:** As a 運用者, I want 高頻度参照の一部を REST（core バケット）へ逃がしたい, so that
GraphQL バケットへの偏った消費を緩和して枯渇を遅らせる

#### Acceptance Criteria

1. Where 負荷分散が有効である, the Issue Watcher shall 指定された hot path の参照を GraphQL
   バケットではなく REST（core バケット）経由で行う
2. When 負荷分散経路で参照を行うとき, the Issue Watcher shall GraphQL 経路と等価な判定結果を返す
3. If 負荷分散経路（REST）での取得が失敗したとき, the Issue Watcher shall 従来経路へフォールバック
   し、当該サイクルを中断しない
4. While 負荷分散が無効である間, the Issue Watcher shall 従来どおり GraphQL 経路で参照する

### Requirement 7: ドキュメント整合

**Objective:** As a 新規 contributor, I want 本機能群の opt-in 手順・env・既定値が README に記載
されていること, so that 仕様書とコードの挙動の食い違いに惑わされない

#### Acceptance Criteria

1. The Documentation shall 本機能群の opt-in 手順・有効化時の挙動・既定安全側の方針を README に
   記載する
2. The Documentation shall 本機能群が導入する env var 一覧と既定値を README に記載する
3. The Documentation shall バケット可視化ログの読み方と縮退の優先順位（必須 vs 非必須）を README に
   記載する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 本機能群の env フラグが未設定の状態で、導入前と同一のプロセッサ実行順・
   一覧取得挙動・ラベル遷移・ログ出力を保持する
2. The Issue Watcher shall 既存 env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 /
   ログ出力先を本機能の追加によって変更しない

### NFR 2: fail-safe と冪等性

1. If スナップショット取得・バケット残量取得・負荷分散経路のいずれかが失敗したとき, the Issue
   Watcher shall 従来経路へフォールバックして当該サイクルを継続する
2. The Issue Watcher shall 縮退時も dispatch および状態遷移系処理を skip せず、必須処理の完遂性を
   保つ
3. The Issue Watcher shall 状態遷移系ラベル操作のリトライを有限回で打ち切り、無限リトライによる
   rate limit の二次枯渇を発生させない
4. The Issue Watcher shall スナップショット共有・縮退・リトライのいずれにおいても、holder から
   誤ってラベルを外す等の安全側判定原則を維持する

### NFR 3: 性能（API 消費削減）

1. While スナップショット共有が有効である間, the Issue Watcher shall 参加プロセッサ全体での
   PR 一覧取得および Issue 一覧取得をそれぞれ 1 サイクルあたり 1 回に集約する

### NFR 4: 観測可能性

1. The Issue Watcher shall バケット可視化ログ・WARN・縮退 skip・リトライの各ログ行を `LOG_DIR`
   配下に出力し、grep による事後検索を可能にする
2. The Issue Watcher shall WARN ログにバケット名・残量・閾値を含める

### NFR 5: セキュリティ（未信頼入力）

1. The Issue Watcher shall スナップショットに含まれる GitHub 由来の未信頼入力（Issue / PR 本文・
   ラベル・ブランチ名等）を、既存の quote / `--arg` / ID・SHA 検証等の取り扱い原則を崩さずに処理
   する

### NFR 6: 静的解析クリーンと検証コスト

1. The Issue Watcher script shall `shellcheck` 実行において新規警告を 0 件に保つ
2. The Test Suite shall スナップショット共有・縮退・限定リトライの判定を live GitHub API 呼び出し
   なしの fixture で検証できる

## Out of Scope

- GitHub App installation token 化（rate limit 5,000→15,000/h）による上限引き上げ（human が
  Option A を確定。本 Issue のスコープ外とし、`auto-dev` を付けない別 Issue として切り出す）
- stale-pickup-reaper の sess 判定修正（#520 で対応中）
- webhook / GitHub App イベント駆動への全面移行（ポーリング構造は維持する）
- idd-codex ハーネス側への同時展開
- Claude Max quota（`rate_limit_event`）の検知・resume（#66 / #104 の領分。本 Issue は GitHub
  API rate limit が対象）
- 新規ラベルの追加（本機能は既存ラベル体系のまま実装する）
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への同等導入

## Open Questions

- スナップショット共有の実現方式（env var 経由 / temp file 経由等）は Architect が design.md で
  決定する（本要件は「サイクル内で共有参照される」挙動契約のみを規定する）
- 縮退時に skip する「非必須プロセッサ」の具体的な分類と優先順位。仮案は「dispatch と状態遷移は
  最後まで守り、レビュー系・可視化系から止める」。全プロセッサの厳密な essential / non-essential
  分類と順序は Architect が確定する
- 縮退閾値・限定リトライ回数上限の具体的な既定数値（安全側であること・env で override 可能である
  ことは要件で確定済み。具体値は Architect が決定する）
- 負荷分散で REST（core バケット）へ逃がす hot path の具体的な参照箇所の選定（Architect が決定
  する）
- 本機能群の opt-in env フラグの具体名・粒度（単一マスタ gate か機能別 gate か）。repo の opt-in
  規約（`*_ENABLED=true` 既定 false / 不正値は安全側に正規化）に従うこと。具体名は Architect が
  確定する
