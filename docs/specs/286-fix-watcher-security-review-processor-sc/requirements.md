# Requirements Document

## Introduction

Spec #279 で導入された Security Review Processor は、`SECURITY_REVIEW_ENABLED=true` で
opt-in した運用環境において、`/security-review` skill 起動用のプロンプト文字列を `claude`
CLI へ伝達できておらず、結果として **全 PR で空プロンプトが渡って scan-failed エラー
コメントが投稿される** 状態にある。原因は `issue-watcher.sh` の Config ブロックで
`SECURITY_REVIEW_PROMPT` および `SECURITY_REVIEW_CLAUDE_CMD` を非 export のシェル変数として
定義しており、Security Review Processor が `bash -c` 経由で起動する子シェルにこれらの
変数が継承されない点にある。本 spec は、default 構成のままで Security Review Processor が
非空プロンプトを `claude` CLI に渡せる状態へ復旧することを目的とする。修正にあたっては
spec #279 で確定済みの opt-out 既定・read-only invariant・SHA marker 冪等性・Reviewer 独立性
など、観測可能挙動の不変条件を一切壊さないこととする。

## Requirements

### Requirement 1: CLI 起動契約（非空プロンプトの伝達保証）

**Objective:** As an idd-claude operator, I want Security Review Processor の default 構成
そのままで `claude` CLI に非空のスキャン指示プロンプトが渡るようにしたい, so that opt-in
有効化したリポジトリで scan-failed が常時発生する現状から回復し、本来の
`/security-review` スキャン結果を PR 上で確認できる

#### Acceptance Criteria

1. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致し、かつ運用者が
   `SECURITY_REVIEW_PROMPT` および `SECURITY_REVIEW_CLAUDE_CMD` を明示的に override して
   いない default 構成である状態である間, the Security Review Processor shall 対象 PR の
   スキャン実行時点で `claude` CLI に渡されるプロンプト引数が非空文字列となることを保証する
2. When 対象 PR に対して Security Review Processor がスキャン実行コマンドを起動した場合,
   the Security Review Processor shall watcher プロセス本体が解決した
   `SECURITY_REVIEW_PROMPT` の文字列内容と、子プロセスで実際にスキャン指示として `claude`
   CLI に到達した文字列内容を同一にする
3. If 対象 PR のスキャン実行時点で `claude` CLI に渡されるプロンプト引数が空文字列に解決
   される事象が watcher プロセス内で検知された場合, the Security Review Processor shall
   `claude` CLI を起動せず、scan-failed 相当の理由として「空プロンプト解決」を識別できる
   形で対象 PR にエラーコメントを 1 件投稿する
4. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致しない状態である間, the Security
   Review Processor shall 本 Requirement の処理を一切実行しない

### Requirement 2: スキャン成立時の結果コメント挙動の復旧

**Objective:** As an idd-claude operator, I want default 構成で実際に
`/security-review` skill が起動・完了し、検出有無に応じた既定のコメント挙動が PR 上で
観測可能になってほしい, so that opt-in 直後の運用者が本機能の動作を実機で確認できる

#### Acceptance Criteria

1. When スキャンが正常終了し、スキャン結果に 1 件以上の検出項目が含まれていた場合,
   the Security Review Processor shall 対象 PR にスキャン結果を含むコメントを 1 回投稿する
2. When スキャンが正常終了し、スキャン結果に検出項目が 1 件も含まれていなかった場合,
   the Security Review Processor shall 「クリーンである旨」を明示するコメントを対象 PR に
   1 回投稿する
3. The Security Review Processor shall スキャン完了時に投稿するコメント本文を、scan-failed
   エラーコメントとは別種別の本文として区別できる形で出力する

### Requirement 3: 既存不変条件の保全

**Objective:** As an idd-claude operator, I want 本修正が spec #279 で確定済みの不変条件
（opt-out 既定 / read-only invariant / 重複防止マーカー / Reviewer 独立性 / advisory 固定）
を壊さないことを保証してほしい, so that 既に main で稼働している既存挙動を退行させずに
修正を受け入れられる

#### Acceptance Criteria

1. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致しない状態である間, the watcher
   shall 本修正導入前と完全に同一の観測可能挙動を維持する（既存ラベル遷移・コメント投稿・
   他プロセッサ起動順序・exit code 意味を含む）
2. The Security Review Processor shall 修正後もスキャン実行がワークツリーの tracked ファイル
   を変更しない（read-only invariant の維持）
3. The Security Review Processor shall 修正後も対象 PR の head コミット SHA を含む非表示
   HTML マーカーによる重複コメント防止挙動を維持し、同一 SHA に対する重複コメント投稿を
   行わない
4. When 対象 PR の head コミットが前回スキャン時点から変化していない場合, the Security
   Review Processor shall 重複スキャンを行わず、当該 PR の処理を冪等にスキップする
5. The Security Review Processor shall 修正後も Reviewer エージェントの 3 カテゴリ判定
   （missing AC / missing test / boundary 逸脱）および `review-notes.md` /
   `RESULT: approve|reject` 判定論理に介入しない
6. The Security Review Processor shall 修正後もゲート挙動を advisory 固定として保ち、検出
   結果の severity に関わらず対象 PR のマージを阻害するラベル付与およびマージブロック操作
   を行わない

### Requirement 4: 運用者 override 経路の維持

**Objective:** As an idd-claude operator, I want spec #279 design.md「CLI 起動契約」節で
規定された `SECURITY_REVIEW_PROMPT` および `SECURITY_REVIEW_CLAUDE_CMD` の運用者 override
経路を、本修正後も引き続き利用できるようにしたい, so that 実機の `claude` バージョン差や
カスタム prompt 文字列が必要な現場で本機能を引き続き調整できる

#### Acceptance Criteria

1. While 運用者が watcher 起動 env で `SECURITY_REVIEW_PROMPT` を非空文字列に明示設定した
   状態である間, the Security Review Processor shall 当該文字列をスキャン指示プロンプトと
   して `claude` CLI に渡す
2. While 運用者が watcher 起動 env で `SECURITY_REVIEW_CLAUDE_CMD` を明示設定した状態で
   ある間, the Security Review Processor shall 当該コマンドテンプレートを起動コマンドとして
   採用する
3. The Security Review Processor shall `SECURITY_REVIEW_PROMPT` および
   `SECURITY_REVIEW_CLAUDE_CMD` の env var 名・既定値の意味的内容（既定プロンプトが
   `/security-review` skill 起動を指示する文字列であり、既定コマンドが `claude -p` 経路で
   advisory スキャンを実行する形であること）を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `SECURITY_REVIEW_ENABLED` が `true` と完全一致しない状態である間, the watcher
   shall 本修正導入前と完全に同一の挙動を維持する
2. The watcher shall 本修正において既存 env var 名（`SECURITY_REVIEW_ENABLED` /
   `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` / `SECURITY_REVIEW_MODEL` /
   `SECURITY_REVIEW_MAX_TURNS` / `SECURITY_REVIEW_MAX_PRS` / `BASE_BRANCH` / `REPO` /
   `REPO_DIR` 等）の名前・既定値・意味を変更しない
3. The watcher shall 本修正において既存 cron / launchd 登録文字列の変更を要求しない

### NFR 2: 観測可能性

1. The Security Review Processor shall 本修正後も spec #279 NFR 3.1 で規定された主要分岐点
   （opt-in スキップ理由 / 対象 PR 件数 / draft 除外 / 重複 SHA 検出 / スキャン実行 /
   スキャン失敗 / コメント投稿 / ゲート厳格度判定）を運用者がログから判定できる形で記録
   し続ける
2. If 空プロンプト解決を検知して scan-failed 相当へフェイルセーフした場合, the Security
   Review Processor shall 当該事象を他のスキャン失敗原因（コマンド非ゼロ終了 / 空出力 /
   read-only invariant 違反 等）と運用者が区別可能な形でログに 1 行記録する

### NFR 3: 静的解析品質

1. While 本修正の新規／変更ファイル群に対して `shellcheck`（および該当する場合
   `actionlint`）を実行した状態である間, the static analysis result shall 警告ゼロで完了
   する（既存リポジトリ運用と同じ `.shellcheckrc` / `actionlint` 抑止方針に従う）

### NFR 4: ドキュメント整合性

1. While 本修正が `SECURITY_REVIEW_PROMPT` または `SECURITY_REVIEW_CLAUDE_CMD` の解決経路
   に観測可能な変更を含む状態である間, the documentation shall 同一 PR 内で README の
   「オプション機能一覧」相当節および spec #279 の関連記述との整合を確認した上で、必要な
   箇所を更新する

## Out of Scope

- strict モード（severity 閾値に基づくマージ阻害ラベル付与）の実装（spec #281 で扱う）
- `/security-review` skill の検出品質・検出ルール改変
- スキャン実行モデル（`SECURITY_REVIEW_MODEL`）既定値の見直し
- `claude` CLI 起動経路の根本的差し替え（公式 GitHub Action 経路への切替 等）
- 既存リポジトリの過去 PR への遡及スキャン
- スキャン失敗時の自動リトライ・指数バックオフ機構の追加
- 検出脆弱性の auto-fix コミット生成
- セキュリティ検出結果に基づくテレメトリの自動収集・外部送信
- 既存 Reviewer の判定対象カテゴリ拡張
- 修正方針の選択（env 変数を export する経路 / プロンプトをファイル経由で渡す経路 等の
  実装手段の選定）— 本 spec は CLI 起動契約レベルの AC のみを規定し、実装手段の選択は
  Architect の領分とする

## Open Questions

- なし

## 関連

- Parent: #279
- Sibling: #281
- Related: #261
