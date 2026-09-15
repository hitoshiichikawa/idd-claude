# Requirements Document

## Introduction

GitHub API Rate Guard（#521）の縮退（degradation）とバケット可視化は、graphql バケットの残量を
REST `gh api rate_limit` の `.resources.graphql` から読み取っている。しかしこのサーバの OAuth
token 認証では REST 側 `.resources.graphql` が常に `used=0 / remaining=5000` を返し、実 GraphQL
消費を反映しない。その結果、`GH_API_DEGRADE_ENABLED=true` でも閾値割れを検知できず縮退が発火せず、
枯渇時には全プロセッサの一覧取得が失敗する。またバケット可視化ログの graphql 欄が常に `5000/5000`
となり枯渇の予兆にならない。core / search バケット（REST）は実態に沿った値のため問題はない。

本 Issue は graphql バケット残量の取得経路のみを是正し、実 GraphQL 消費を縮退判定・可視化ログへ
反映させる不具合修正である。取得経路と取得失敗時の分岐は運用者が確定済みであり（下記「確定事項」）、
本要件はその確定を受入基準として明記する。

> 確定事項（Issue コメントで運用者が確定。要件へ反映必須）:
> - **判断 1 → 仮案 A**: graphql バケット残量は GraphQL の `rateLimit` クエリ（実 GraphQL 消費を
>   反映する経路）で取得する。core / search は従来どおり REST `gh api rate_limit`（rate limit を
>   消費しない参照経路）から取得する。仮案 B（既存 GraphQL 呼び出しの応答ヘッダ流用）は不採用。
> - **判断 2 → 取得失敗時の分岐**: graphql 残量取得が rate limit 起因で失敗した場合は残量を 0 と
>   みなして縮退判定を行う。それ以外の失敗（タイムアウト・ネットワーク障害・パース失敗等）は従来
>   どおり安全側で全プロセッサを実行する。

> Migration note（#521 Requirement 3.2 の緩和）: #521 Req 3.2 は「`/rate_limit` 参照を rate limit
> 消費対象に含めない経路で行う」を規定していた。本 Issue はこれを **graphql バケットに限り** 緩和
> し、「graphql 残量取得は 1 サイクルあたり少量（目安 1〜2pt）の消費を許容する」とする。core /
> search バケットは従来どおり非消費経路を維持する。

## 用語定義

- **graphql 実残量**: GraphQL の `rateLimit` クエリが返す graphql バケットの残量。REST
  `.resources.graphql` が返す名目値（OAuth token では常に `5000/5000`）と区別する。
- **取得経路 (retrieval path)**: あるバケットの残量・上限を得るために参照する API 経路。graphql は
  GraphQL `rateLimit` クエリ、core / search は REST `gh api rate_limit`。
- **rate limit 起因の失敗**: 残量取得が rate limit 超過（429 / RATE_LIMITED / rate limit 文言等）に
  よって失敗すること。タイムアウト・ネットワーク障害・パース失敗はこれに含めない。
- **非必須プロセッサ (non-essential)**: 縮退時に skip される可視化系・レビュー系プロセッサ。分類は
  #521 で確定済みで本 Issue では変更しない（Out of Scope 参照）。

## Requirements

### Requirement 1: graphql バケット残量の取得経路是正

**Objective:** As a 運用者, I want graphql バケット残量が実 GraphQL 消費を反映する経路から取得される,
so that 縮退判定と可視化ログが枯渇の予兆として機能する

#### Acceptance Criteria

1. Where バケット可視化または縮退のいずれかが有効である, the Issue Watcher shall graphql バケットの
   残量・上限を GraphQL の `rateLimit` クエリ（実 GraphQL 消費を反映する経路）から取得する
2. The Issue Watcher shall core / search バケットの残量・上限を従来どおり REST `gh api rate_limit`
   （rate limit を消費しない参照経路）から取得する
3. When graphql 残量を取得したとき, the Issue Watcher shall 当該サイクルの実 GraphQL 消費が反映
   された残量値を縮退判定および可視化ログに用いる
4. The Issue Watcher shall graphql 残量取得において仮案 B（既存 GraphQL 呼び出しの応答ヘッダ流用）を
   採用しない

### Requirement 2: graphql 実残量が閾値割れのときの縮退発火

**Objective:** As a 運用者, I want graphql 実残量が閾値を下回ったら縮退が発火する, so that GraphQL
枯渇による全プロセッサ一覧取得失敗を未然に防げる

#### Acceptance Criteria

1. When graphql 実残量が `GH_API_DEGRADE_GRAPHQL_THRESHOLD` を下回るサイクルで縮退が有効であるとき,
   the Issue Watcher shall 非必須プロセッサの実行を当該サイクルで skip する
2. When 縮退により非必須プロセッサを skip したとき, the Issue Watcher shall skip したプロセッサ名・
   バケット名（graphql）・graphql 実残量・閾値を含む WARN をログに記録する
3. While graphql 実残量が閾値以上である間, the Issue Watcher shall 縮退による skip を行わない
4. While 縮退が無効である間, the Issue Watcher shall graphql 実残量にかかわらずプロセッサを skip
   しない

### Requirement 3: バケット可視化ログへの graphql 実残量反映

**Objective:** As a 運用者, I want バケット可視化ログの graphql 欄が実 GraphQL 残量を示す, so that
ログから枯渇の予兆を検知できる

#### Acceptance Criteria

1. Where バケット可視化が有効である, the Issue Watcher shall バケット可視化ログの graphql 欄に
   GraphQL `rateLimit` クエリから得た実残量・上限を出力する
2. Where バケット可視化が有効である, the Issue Watcher shall core / search 欄を従来どおり REST から
   得た残量・上限で出力する
3. The Issue Watcher shall バケット可視化ログを従来と同一の固定フォーマット（`gh-rate-limit:
   core=<r>/<l> graphql=<r>/<l> search=<r>/<l>`）およびログ prefix（`gh-rate-limit:`）で出力する

### Requirement 4: graphql 残量取得失敗時の分岐（fail-safe）

**Objective:** As a 運用者, I want graphql 残量取得が失敗しても失敗種別に応じて安全側に分岐する,
so that 枯渇時に縮退が効かなくなる事態を避けつつ必須処理の完遂性を守れる

#### Acceptance Criteria

1. If graphql 残量取得が rate limit 起因で失敗し、かつ縮退が有効であるとき, the Issue Watcher shall
   graphql 残量を 0 とみなして縮退判定を行い、非必須プロセッサを skip する
2. When rate limit 起因の取得失敗により非必須プロセッサを skip したとき, the Issue Watcher shall
   判定根拠（取得失敗理由・バケット名 graphql・閾値）を WARN に記録する
3. If graphql 残量取得が rate limit 以外の要因（タイムアウト・ネットワーク障害・パース失敗等）で
   失敗したとき, the Issue Watcher shall 従来どおり全プロセッサを実行する（安全側フォールバック）
4. When rate limit 以外の要因で graphql 残量取得が失敗したとき, the Issue Watcher shall 取得失敗を
   WARN に記録する
5. If graphql 残量取得が失敗したとき, the Issue Watcher shall 当該サイクルの後続処理を中断しない

### Requirement 5: 未有効化時の後方互換（新規 API 呼び出しゼロ）

**Objective:** As a 既存運用者, I want バケット可視化・縮退のいずれも無効なら本修正で挙動が一切
変わらない, so that 未有効化環境の cron / launchd 運用に無告知の変化が起きない

#### Acceptance Criteria

1. While バケット可視化・縮退のいずれの gate も無効である間, the Issue Watcher shall graphql 残量
   取得のための GraphQL `rateLimit` クエリを含む新規 API 呼び出しを行わない
2. The Issue Watcher shall env var 名（`GH_API_*`）・ログ prefix（`gh-rate-limit:`）・可視化ログの
   固定フォーマットを本修正によって変更しない
3. While バケット可視化・縮退のいずれの gate も無効である間, the Issue Watcher shall 本修正導入前と
   同一のプロセッサ実行順・ラベル遷移・ログ出力を保持する

### Requirement 6: 縮退テストの取得経路追随

**Objective:** As a maintainer, I want 縮退テストの stub と検証が新しい graphql 取得経路に追随する,
so that live GitHub API 呼び出しなしで本修正の判定を検証できる

#### Acceptance Criteria

1. The Test Suite shall `api_rate_guard_degrade_test.sh` の gh stub を GraphQL `rateLimit` クエリ
   経由の graphql 残量取得に対応させる
2. The Test Suite shall graphql 実残量が閾値を下回るケースで非必須プロセッサ skip と WARN 出力を
   live GitHub API 呼び出しなしで検証する
3. The Test Suite shall graphql 残量取得が rate limit 起因で失敗したときに縮退が発火することを検証
   する
4. The Test Suite shall graphql 残量取得が rate limit 以外の要因で失敗したときに全プロセッサ実行へ
   フォールバックすることを検証する

## Non-Functional Requirements

### NFR 1: API 消費上限（#521 Req 3.2 緩和の明示）

1. While バケット可視化または縮退が有効である間, the Issue Watcher shall graphql 残量取得のための
   GraphQL `rateLimit` クエリによる追加消費を 1 サイクルあたり 2pt 以下に抑える
2. The Issue Watcher shall core / search バケットの残量取得を従来どおり非消費経路で行い、追加消費を
   発生させない

### NFR 2: 後方互換性

1. The Issue Watcher shall 既存 env var 名 / ラベル名 / exit code の意味 / cron 登録文字列 / ログ
   出力先（`LOG_DIR` 配下）を本修正によって変更しない
2. The Issue Watcher shall graphql 残量取得の是正に伴って新規ラベルを導入しない

### NFR 3: 観測可能性

1. The Issue Watcher shall graphql 残量取得の失敗種別（rate limit 起因か否か）を WARN ログから判別
   可能な形で記録する
2. The Issue Watcher shall バケット可視化ログおよび縮退 skip の WARN ログを grep 可能な固定
   フォーマットで `LOG_DIR` 配下に出力する

### NFR 4: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck` 実行において新規警告を 0 件に保つ

## Out of Scope

- 縮退対象プロセッサの essential / non-essential 分類の見直し（#521 で確定済みの分類を維持する）
- 縮退閾値の既定値（`GH_API_DEGRADE_GRAPHQL_THRESHOLD` 既定 500）の見直し
- gh CLI のキャッシュ汚染対策（別途 Issue として扱う）
- Promote Pipeline の GraphQL 消費削減（#535 の領分）
- GitHub App installation token 化による rate limit 上限引き上げ（#524 の領分）
- core / search バケットの取得経路変更（従来 REST `gh api rate_limit` を維持する）
- 仮案 B（既存 GraphQL 応答ヘッダ流用）の採用（不採用と確定済み）

## Open Questions

- なし（判断 1 / 判断 2 は運用者が確定済み）。
- 補足（人間判断待ちではなく Architect / Developer 委任事項）: graphql 残量取得は縮退判定用（サイクル
  冒頭）と可視化用（サイクル終端）の 2 箇所から呼ばれ得るため、両 gate 有効時に GraphQL クエリが最大
  2 回発火しうる。1 サイクル 1 回へ集約（キャッシュ）するかは実装判断に委ねる。NFR 1.1 の「1 サイクル
  あたり 2pt 以下」の範囲に収まればよく、本要件でキャッシュ実装の是非は固定しない。
