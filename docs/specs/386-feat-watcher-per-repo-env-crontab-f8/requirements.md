# Requirements Document

## Introduction

idd-claude watcher は cron / launchd から起動される際、feature flag（`*_ENABLED` 系の opt-in
gate など）を **crontab 行内に inline 環境変数として列挙する**運用が定着している。フラグ追加が
継続した結果、ae-mdm リポジトリ運用で 1 行が ~1024 文字の crontab 行長限界に達し、
`command too long` で `install.sh` が失敗する事象が複数回発生した。本機能（F8）は watcher 起動時
に **per-repo の env ファイル**を source して flag を供給する経路を追加し、crontab 行を
schedule / `REPO` / `REPO_DIR` / `BASE_BRANCH` といった repo 識別系の最小限に保てるようにする。
env ファイル不在時は導入前と完全に byte 等価な挙動を保ち（opt-in は「ファイルの存在」で判定し、
新規の gate env を必要としない）、inline cron env が env ファイルの値より優先される precedence を
保証することで、フラグ調整を crontab 編集ではなく単一ファイル編集へ移行できる状態にする。

## 用語定義

- **REPO_SLUG** — watcher が `REPO`（例 `owner/name`）の `/` を `-` に変換して得る repo 単位の
  識別子（例 `owner-name`）。既存 lock / log ファイル名と共通の slug 規約を流用する。
- **WATCHER_ENV_FILE** — env ファイルの場所を運用者が明示指定するための環境変数。値は絶対パス。
- **inline cron env** — crontab 行（または launchd plist の `EnvironmentVariables`、または
  watcher 起動シェルの環境）で watcher プロセスへ供給される環境変数。env ファイル source 前の
  時点で既に export 済みである値を指す。
- **env ファイル** — watcher が起動時に source する `KEY=VALUE` 形式のシェルスクリプト風
  テキストファイル。本機能で新規導入される。

## Requirements

### Requirement 1: env ファイルの探索順

**Objective:** As a idd-claude 運用者, I want watcher が per-repo の env ファイルを決定論的な順序で探索する, so that 複数 repo を 1 つの watcher スクリプトで運用する際に repo ごとの flag セットを明示パスまたは規約パスから取得できる

#### Acceptance Criteria

1. When watcher プロセスが起動した, the watcher shall env ファイル探索を flag 解決より前に実施する
2. Where `WATCHER_ENV_FILE` が絶対パスとして指定されており当該ファイルが読取可能である, the watcher shall そのファイルを env ファイルとして採用し、他の候補を探索しない
3. If `WATCHER_ENV_FILE` が未設定または空文字である, the watcher shall `$HOME/.issue-watcher/<REPO_SLUG>.env` を次候補として参照する（`<REPO_SLUG>` は `REPO` の `/` を `-` に変換した値）
4. When 次候補 `$HOME/.issue-watcher/<REPO_SLUG>.env` が読取可能である, the watcher shall そのファイルを env ファイルとして採用する
5. If 探索順のいずれの候補も読取可能でない, the watcher shall env ファイルを採用せず、後方互換の no-op 経路（本機能導入前と等価な起動シーケンス）を辿る

### Requirement 2: env ファイルの形式

**Objective:** As a idd-claude 運用者, I want env ファイルが運用しやすい単純な `KEY=VALUE` 形式である, so that crontab 1 行への詰込みを避け、フラグ追加・削除・コメントによる注釈を単一ファイル編集で完結できる

#### Acceptance Criteria

1. The env ファイル shall 1 行 1 件の `KEY=VALUE` 形式で記述される
2. Where 行頭文字が `#` である行が含まれる, the watcher shall 当該行をコメントとして無視し、副作用を発生させない
3. Where 行が空または空白のみで構成される, the watcher shall 当該行を読み飛ばし、副作用を発生させない
4. When env ファイル内の `KEY=VALUE` 行を採用した, the watcher shall 当該 `KEY` を後続処理（flag 解決・gate 評価）で参照可能な環境変数として供給する

### Requirement 3: 値評価（変数展開・コマンド置換）

**Objective:** As a idd-claude 運用者, I want env ファイル内の値で `$HOME` や `$(...)` を解決できる, so that webhook URL のような機密値を別ファイルから読み込んでフラグへ注入し、env ファイル自体に平文埋込みせずに済む

#### Acceptance Criteria

1. When env ファイル内の `KEY=VALUE` 行を採用した, the watcher shall 値文字列中の `$HOME` を起動シェルの `$HOME` 実値へ解決する
2. When env ファイル内の `KEY=VALUE` 行を採用した, the watcher shall 値文字列中の `$(...)` 形式のコマンド置換を起動時に実行し、その出力を `KEY` の値として採用する
3. If 値評価中にコマンド置換が失敗した（非 0 終了 / 実行不能）, the watcher shall 当該行のみ skip し、警告を `>&2` へ出力し、watcher プロセスを継続する
4. While env ファイル内の値が機密情報（webhook URL 等）を含む, the watcher shall 評価結果の値をログ・Issue コメントへ出力しない

### Requirement 4: precedence（inline cron env 優先）

**Objective:** As a idd-claude 運用者, I want crontab 行で明示した値が env ファイルの値より優先される, so that 一時的な override・実験的なフラグ調整・特定 repo の例外設定を crontab 1 行で完結できる

#### Acceptance Criteria

1. When 同一の `KEY` が inline cron env と env ファイルの両方に存在する, the watcher shall inline cron env の値を採用し、env ファイルの値で上書きしない
2. When `KEY` が env ファイルにのみ存在する, the watcher shall env ファイルの値を採用する
3. When `KEY` が inline cron env にのみ存在する, the watcher shall inline cron env の値を採用する（env ファイル不在時と同一の挙動）
4. The watcher shall precedence 規約を「inline cron env > env ファイル」の単一順序として全 `KEY` に一貫して適用する

### Requirement 5: 後方互換性（env ファイル不在時の byte 等価性）

**Objective:** As a idd-claude 運用者, I want env ファイルを置かない既存運用の挙動が変わらない, so that 本機能導入による回帰リスクなしに段階的に env ファイル運用へ移行できる

#### Acceptance Criteria

1. While env ファイル探索順のいずれの候補も読取可能でない, the watcher shall 本機能導入前と完全に同一の起動シーケンス・環境変数集合・ログ出力・exit code を保つ
2. The watcher shall env ファイル機能の有効化に新規 gate env（`*_ENABLED` 系）を要求せず、「ファイルの存在」のみを opt-in シグナルとして扱う
3. While 既存運用者が crontab 行に全 flag を inline 列挙している, the watcher shall 当該 inline 値を Requirement 4 の precedence 規約により従来どおりに反映する

### Requirement 6: 異常系（読取・構文エラーの扱い）

**Objective:** As a idd-claude 運用者, I want 壊れた env ファイルが watcher 全体を停止させない, so that 1 行のタイプミスや権限ミスで repo の cron が無音停止する事故を防げる

#### Acceptance Criteria

1. If 採用した env ファイルが読取不能（権限不足・I/O エラー等）, the watcher shall 警告を `>&2` へ出力し、env ファイルを採用しなかった経路（Requirement 5.1 と等価）で起動を継続する
2. If env ファイル内の特定行が `KEY=VALUE` 形式として解釈できない（`=` 欠落 / `KEY` が識別子として無効 等）, the watcher shall 当該行のみ skip し、警告を `>&2` へ出力し、残りの行の処理を継続する
3. If env ファイル内の値評価（Requirement 3）でコマンド置換が失敗した, the watcher shall 当該 `KEY` を未設定のまま残し、watcher プロセスを継続する
4. While 異常系で行 skip が発生している, the watcher shall 当該 `KEY` を inline cron env が定義していれば inline 値で補完する（precedence 規約は維持）
5. The watcher shall 異常系の警告メッセージに env ファイルパスと該当行番号を含める（行 skip の場合は行番号、ファイル全体の場合はパスのみ）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `BASE_BRANCH` / `TRIAGE_MODEL` / `DEV_MODEL` 等）の名前・意味を変更しない
2. The watcher shall 既存 cron / launchd 登録文字列を破壊せず、現行の inline env のみで運用している repo が `install.sh` を再実行しても挙動が変わらない
3. While env ファイル探索で候補が見つからない, the watcher shall 本機能導入前と完全に byte 等価な起動経路（環境変数集合・ログ・exit code）を辿る

### NFR 2: セキュリティ

1. The watcher shall env ファイルの読込で path traversal 防止のため、`WATCHER_ENV_FILE` の値および `$HOME/.issue-watcher/<REPO_SLUG>.env` のパスを使用前に「絶対パスかつ通常ファイルかつ読取権限あり」であることを確認する
2. The watcher shall env ファイル内の値評価結果を Issue 本文・Issue コメント・PR 本文・標準ログへ平文出力しない（機密情報のリーク防止）
3. The README / 運用ドキュメント shall env ファイルの推奨パーミッションを 600（owner 読書のみ）として明記する
4. The watcher shall env ファイルを運用者管理ファイル（信頼境界の内側）として扱い、未信頼入力サニタイズ（Issue 本文等に適用するもの）の対象とはしない

### NFR 3: 可観測性

1. When watcher が env ファイルを採用した, the watcher shall 採用したファイルパスを 1 行ログとしてログ出力先へ記録する（値は出力しない）
2. When watcher が env ファイル内の行を skip した, the watcher shall skip 理由（構文不正 / コマンド置換失敗等）と行番号を 1 行ログとして記録する
3. While env ファイル探索で候補が見つからない, the watcher shall 探索結果を debug レベル以上のログにのみ記録し、通常運用の標準ログを増やさない

### NFR 4: 静的解析と近接テスト

1. The watcher 配布物 shall `shellcheck` を警告ゼロ、`bash -n` をエラーなしでクリアする
2. The watcher shall 「env ファイル存在 + 値反映」「inline > env ファイル precedence」「`$(...)` 評価」「env ファイル不在時の byte 等価性」「構文不正行 skip + 警告」の 5 経路に対する近接テスト（`local-watcher/test/` 配下に stub ベースで配置）を備える

### NFR 5: テンプレート同期と README 連動

1. The watcher 配布物（`local-watcher/bin/issue-watcher.sh` および関連 module）shall 挙動変更を `repo-template/` 配下の対応物と byte 一致または機能等価で同期する
2. The README shall env ファイルの「探索順 / 形式 / precedence / 推奨パーミッション」を同一 PR で記述する
3. The README shall 既存運用者向けの移行ガイド（inline env を env ファイルへ移し替える手順と precedence による段階移行の方法）を同一 PR で記述する

## Out of Scope

- env ファイル機能を有効化する新規 gate env（`*_ENABLED` 系）の導入（opt-in は「ファイルの存在」のみで判定する）
- 既存運用者の crontab 行から inline env を自動的に env ファイルへ移行するスクリプト（移行は手動 / README の移行ガイド参照）
- env ファイルの自動生成・テンプレート展開（`install.sh` / `setup.sh` 内での scaffold は本機能の対象外）
- env ファイルの暗号化・KMS 連携・secrets manager 統合
- env ファイル変更の即時反映（hot reload / inotify 等。本機能は watcher プロセス起動時の 1 回限りの source とする）
- env ファイル内で他の env ファイルを再帰的に source する仕組み
- launchd plist 側の env ファイル取り扱い変更（plist の `EnvironmentVariables` は inline cron env と同じ precedence 階に置く）
- env ファイルローダの内部関数構成 / 公開 IF シグネチャ / module 切り出しの可否（Architect の責務）
- crontab 行長限界そのものを回避する別アプローチ（ラッパースクリプト経由起動・systemd timer 移行等）

## Open Questions

- なし（Issue 本文の探索順・形式・precedence・後方互換・異常系・セキュリティが要件確定に十分な記述を備えているため）

## 関連

- Parent: なし（F8 単独機能）
- Related: なし

## レビュー結果

- Mechanical Checks: 全要件見出しが numeric ID（1〜6 / NFR 1〜5）/ 各要件に EARS 形式 AC を 1 件以上含む / 実装語彙（特定の関数名・module 名・bash builtin 名指定）の混入なし
- 判断レビュー: 探索順（Req 1）・形式（Req 2）・値評価（Req 3）・precedence（Req 4）・後方互換（Req 5）・異常系（Req 6）の 6 軸で Issue 記載 AC を網羅、Out of Scope で Architect 責務（内部関数構成）と隣接機能（hot reload / 自動移行 / 暗号化）を明示的に切り出し、NFR でセキュリティ（600 / 機密ログ抑制 / path 検証）と同期義務（README / repo-template）を確定 — 1 パスで確定
