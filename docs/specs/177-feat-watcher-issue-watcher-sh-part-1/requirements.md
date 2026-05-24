# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` は 11,899 行に達した単一 bash スクリプトであり、保守性・
レビュー容易性が限界に近づいている。本 spec は同スクリプトを段階的にモジュール分割する大規模
リファクタリングの **Part 1（インフラ基盤・共通ユーティリティの切り出し）** を対象とする。
Part 1 では (1) `install.sh` によるモジュールスクリプトの配置、(2) `issue-watcher.sh` 自身による
モジュール動的ロード基盤、(3) 低レベル共通ユーティリティの `core_utils.sh` への切り出しの 3 点に
限定する。このスクリプトは self-hosting（dogfooding）で本番稼働中であり、分割は外部から観測可能な
挙動を一切変えない差分等価リファクタリングであることが最優先制約となる。
クォータ・マージキュー・Rebase（Part 2 / #180）、開発ループ・検証・昇格（Part 3 / #181）は
本 spec のスコープ外とする。

## Related

- Parent: #177
- Sibling: #180 #181

## Requirements

### Requirement 1: モジュールスクリプトの配置（install.sh 拡張）

**Objective:** As a watcher の運用者, I want `install.sh` がモジュールスクリプトをローカルの実行
ディレクトリへ冪等に配置してくれること, so that 分割後の `issue-watcher.sh` がローカル環境で正しく
ロードできる

#### Acceptance Criteria

1. When 運用者が `install.sh --local`（または `--all`）を実行したとき, the install スクリプト shall `local-watcher/bin/modules/` 配下の全モジュールスクリプトを `$HOME/bin/modules/` へ配置する
2. While `local-watcher/bin/modules/` がサブディレクトリ階層を含むとき, the install スクリプト shall その階層構造を保持したまま `$HOME/bin/modules/` 配下へ再帰的に配置する
3. When 運用者が同一の `install.sh --local` を 2 回目以降に実行したとき, the install スクリプト shall 既に同一内容で配置済みのモジュールを SKIP として扱い再コピーしない
4. When 運用者が `--dry-run` を付けて実行したとき, the install スクリプト shall モジュール配置をファイルシステムに反映せず、実行時と同じ分類（NEW / SKIP / OVERWRITE）の予定操作を `[DRY-RUN]` プレフィクス付きで列挙する
5. If 配置先に内容差分のある既存モジュールが存在し `--force` が指定されていないとき, the install スクリプト shall 既存ファイルを上書きせず保護する
6. Where `--force` が指定されているとき, the install スクリプト shall 既存モジュールの安全退避（`.bak`）または上書きを既存テンプレート配置と整合する規律で行う
7. If `local-watcher/bin/modules/` にマッチするモジュールが 0 件のとき, the install スクリプト shall エラーで停止せず SKIP ログを出して install 全体を継続する

### Requirement 2: モジュール動的ロード基盤（issue-watcher.sh）

**Objective:** As a watcher 本体, I want 自分自身の配置ディレクトリから相対的にモジュールを動的に
`source` できること, so that ローカル配置・worktree・cron 等どの起動経路でも同一のロード結果になる

#### Acceptance Criteria

1. When `issue-watcher.sh` が起動したとき, the watcher shall 自身のスクリプトディレクトリ（`SCRIPT_DIR`）を基準とする相対パスで `modules/` 配下のモジュールを `source` する
2. While cron-like の最小 PATH 環境で起動されたとき, the watcher shall モジュールのロードを `SCRIPT_DIR` 基準で解決し、外部の作業ディレクトリ（cwd）に依存せず成功させる
3. If 必須モジュールが配置先に欠落しているとき, the watcher shall そのモジュール名を含むエラーメッセージを標準エラー出力へ出し、exit code 1 で安全に停止する
4. When 全モジュールが正常にロードされたとき, the watcher shall 分割前と同一の Triage から PR 作成までの状態遷移を継続して実行する
5. The watcher shall モジュールロードの成否を、運用者がログから判別可能な形で記録する

### Requirement 3: 共通ユーティリティの切り出し（core_utils.sh）

**Objective:** As a watcher の保守者, I want 低レベル共通ユーティリティが単一モジュールに集約されている
こと, so that 分割後も Dispatcher および各機能から従来と同一の呼び出しで再利用できる

#### Acceptance Criteria

1. The core_utils モジュール shall 低レベルロガー（`qa_log` / `mq_log` / `ar_log` / `pp_log` / `pi_log` / `drr_log` 等の echo ラッパー）を集約して提供する
2. When 各ロガー関数が呼び出されたとき, the core_utils モジュール shall 分割前と同一のログ出力先・プレフィクス・書式で出力する
3. The core_utils モジュール shall 日付フォーマット取得ユーティリティを提供し、分割前と同一の書式の文字列を返す
4. When `_worktree_ensure` が呼び出されたとき, the core_utils モジュール shall 分割前と同一仕様で Git worktree を確保する
5. When `_worktree_reset` が呼び出されたとき, the core_utils モジュール shall 分割前と同一仕様で Git worktree をリセットする
6. When `_slot_acquire` が呼び出されたとき, the core_utils モジュール shall 分割前と同一仕様で並行スロットを取得する
7. When `_slot_release` が呼び出されたとき, the core_utils モジュール shall 分割前と同一仕様で並行スロットを解放する
8. When `_hook_invoke` が呼び出されたとき, the core_utils モジュール shall 分割前と同一仕様でフックを実行する
9. The core_utils モジュール shall 上記の各関数を、Dispatcher から従来と同一のシグネチャ・戻り値・副作用で呼び出し可能な状態で公開する

### Requirement 4: 既存テストの継続通過

**Objective:** As a watcher の保守者, I want 既存スモークテストが分割後の構成でもクリーンに通過する
こと, so that 分割が差分等価であることを機械的に検証できる

#### Acceptance Criteria

1. When 既存スモークテスト（`local-watcher/test/` および `tests/` 配下）を分割後の構成で実行したとき, the test スイート shall 1 件も失敗せずに通過する
2. While 既存テストが `issue-watcher.sh` から関数定義を抽出して評価する方式を採るとき, the 分割後の構成 shall 対象関数がテストから到達可能であることを保ち、テストの抽出・評価を成功させる
3. If モジュール分割によって既存テストが参照する関数の定義位置が移動したとき, the 分割後の構成 shall 当該テストが移動後の定義を解決できるようにする

## Non-Functional Requirements

### NFR 1: 後方互換性（差分等価）

1. The watcher shall 既存環境変数名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）を分割前と同一の意味で受け付ける
2. The watcher shall 既存の exit code の意味を分割前と同一に保つ
3. The watcher shall ログ出力先（`LOG_DIR` 等から派生する出力経路）を分割前と同一に保つ
4. The watcher shall ラベル遷移契約（`auto-dev` → `claude-claimed` 等の状態遷移）を分割前と同一に保つ
5. The watcher shall 既存 cron / launchd の登録文字列（`$HOME/bin/issue-watcher.sh` を呼ぶ起動行）を変更不要なまま動作させる
6. While 切り出した関数が呼び出されるとき, the 分割後の構成 shall 分割前と差分等価な挙動（同一の入出力・副作用）を示す

### NFR 2: インストールの冪等性と非特権性

1. When `install.sh` を再実行したとき, the install スクリプト shall モジュール配置を含めて破壊的変更を起こさず冪等に完了する
2. The install スクリプト shall モジュール配置を `$HOME` 配下のユーザースコープで完結させ、sudo を必要としない

### NFR 3: 観測可能性

1. When モジュールのロードまたは配置で失敗が発生したとき, the watcher または install スクリプト shall その失敗を silent fail させず、exit code またはログで運用者に明示する

## Out of Scope

- クォータ管理・マージキュー・Rebase 系ロジックの切り出し（Part 2 / #180 の対象）
- 開発ループ・検証ステージ・昇格パイプライン系ロジックの切り出し（Part 3 / #181 の対象）
- `core_utils.sh` 以外の新規モジュール（機能別モジュール）の設計・切り出し
- モジュール分割の内部構造（どの関数をどう束ねるか、`source` 順序、ファイル間依存の解決方式）の決定 → `design.md` の領分
- 切り出した関数のリファクタを超えた挙動変更・新機能追加
- 新しい環境変数・ラベル・exit code 意味の導入
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への波及
- `setup.sh` のクローン挙動変更（install のモジュール配置に必要な範囲を超える変更）

## 確認事項

- Part 1 固有の人間決定事項は現時点で Issue 本文・コメントに未提示。既存コメントの大半は前回サイクル
  （全体設計・Tasks Count Gate 超過・slug 不一致）に関するものであり、Part 1 の新規決定ではない。
- 「必須モジュール」の集合（欠落時に `exit 1` すべきモジュール一覧）の確定は実装着手前に必要だが、
  Part 1 では `core_utils.sh` のみが切り出し対象であるため、必須集合は実質 `core_utils.sh` 単一と
  解釈してよいか。複数モジュールを必須扱いする将来拡張の余地を残すかは `design.md` で扱う想定。
- 上記以外の曖昧点はなし。
