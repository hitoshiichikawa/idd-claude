# Requirements Document

## Overview

Phase D は、Phase A（#14）/ Re-check Processor（#27）が `needs-rebase` ラベルで
人間判断に回している approved PR を、Claude による rebase で機械的に救済する
新しい watcher 機能である。Claude による書き換え結果は人間レビューを通って
いないため、変更ファイルが運用者が宣言した「機械的に安全」な allowlist
（lockfile 等）に閉じている場合のみ approve を維持して auto-merge を可能にし、
allowlist 外の差分（= semantic 判断を含む）が出た場合は既存の approve を剥がし
`ready-for-review` に戻して再レビューを誘導する。本機能は明示的 opt-in 制で、
未設定時は本機能導入前と完全に同一の挙動を保つ。

## Goals / Non-Goals

### Goals

- approved + `needs-rebase` 状態で停滞する PR を、運用者が許可した範囲で自動解消する
- Claude による rebase が semantic 判断を含むかどうかを、運用者が宣言した
  allowlist（パスパターン集合）で判定する
- semantic と判定された rebase に対しては、人間レビュー gate を保護する
  （approve 剥がし + `ready-for-review` 復帰 + 説明コメント投稿）
- rebase そのものが失敗した PR は `claude-failed` ラベルで人間にエスカレートする
- 未設定 / `off` で挙動不変（後方互換性絶対）

### Non-Goals

- 予防的 overlap 検知（複数 PR が将来 conflict しそうな箇所を事前に検出する仕組み）
  は Phase E（#18）のスコープであり、本要件には含めない
- AST diff による意味的差分判定は言語依存度が高いため対象外。allowlist による
  パス単位判定で start する
- Claude 自身に「これは mechanical / semantic か」を自己申告させる方式は、
  本要件では採用しない（精度・再現性が allowlist より劣るため。Open Questions
  で再評価余地のみ残す）
- `needs-rebase` ラベルが付かない通常 PR への介入（Phase A の対象外）
- 外部 Feature Flag SaaS との連携（プロジェクト規約 Feature Flag Protocol とは別物）

## Glossary

- **mechanical rebase**: Claude が rebase した結果の差分が、すべて
  `MECHANICAL_PATHS` allowlist のパスパターンに一致するもの。人間レビュー不要と
  運用者が事前に宣言した範囲に閉じている rebase
- **semantic rebase**: 上記以外の rebase。allowlist 外のパスが 1 つでも変更
  された rebase はすべて semantic として扱う（保守的判定）
- **`MECHANICAL_PATHS` allowlist**: 機械的に安全な変更パスを宣言する環境変数。
  カンマ区切りのパス／glob を想定。具体的な区切り文字・glob 構文は design.md の領分
- **`AUTO_REBASE_MODE`**: Phase D の opt-in 制御環境変数。`off`（既定） /
  有効化値（具体値は design.md）。未設定 / `off` で本機能無効
- **approve dismissal**: 既存 approving review を無効化し PR を未承認状態に戻す操作。
  GitHub の review dismissal 機構（`gh api` 経由）を使用し、`request_changes` で
  別レビューを追加投稿する方式は採らない
- **Phase A / Re-check Processor**: それぞれ `needs-rebase` を付与する loop
  （#14）と、conflict 解消で自動的に剥がす loop（#27）。本機能はこれらと
  共存し、同じ PR を同サイクルで二重処理しない

## Requirements

### Requirement 1: opt-in 制御と既定挙動

**Objective:** As a watcher 運用者, I want Phase D を明示宣言時のみ起動する gate, so that 既存
運用に影響を与えずに段階的に導入できる

#### Acceptance Criteria

1. When `AUTO_REBASE_MODE` が未設定または `off` である, the watcher shall Phase D の
   rebase 処理を一切起動しない
2. When `AUTO_REBASE_MODE` が有効化値である, the watcher shall 各サイクルで Phase D の
   対象 PR を検出する処理を起動する
3. If `AUTO_REBASE_MODE` の値が `off` でも有効化値でもない不正値である, the watcher shall
   `off` と同等に扱い Phase D を起動しない
4. The watcher shall `AUTO_REBASE_MODE` の現在値（有効 / 無効）をサイクル開始時に
   ログへ出力する

### Requirement 2: 対象 PR の判定

**Objective:** As a watcher 運用者, I want Phase D が処理対象を明確な条件で絞ること, so that
人間レビュー対象の PR や fork PR を巻き込まない

#### Acceptance Criteria

1. While `AUTO_REBASE_MODE` が有効である, the Phase D Processor shall `needs-rebase`
   ラベルが付与され、かつ 1 件以上の approving review を持つ open PR のみを対象とする
2. While `AUTO_REBASE_MODE` が有効である, the Phase D Processor shall `claude-failed`
   ラベルが付いた PR を対象から除外する
3. While `AUTO_REBASE_MODE` が有効である, the Phase D Processor shall draft 状態の
   PR を対象から除外する
4. While `AUTO_REBASE_MODE` が有効である, the Phase D Processor shall head リポジトリ
   owner が base リポジトリ owner と異なる fork PR を対象から除外する
5. While `AUTO_REBASE_MODE` が有効である, the Phase D Processor shall 既存の
   Phase A 系列が許可する head branch パターンと整合した範囲のみを対象とする

### Requirement 3: 既存ループとの競合排除

**Objective:** As a watcher 運用者, I want Phase D が既存 Phase A / Re-check と同じ PR を
同サイクルで二重処理しないこと, so that ラベル遷移やレビュー状態が予測可能であること

#### Acceptance Criteria

1. While 同一サイクル中, the watcher shall 1 つの PR を Phase A 本体・Re-check
   Processor・Phase D のうち高々 1 つにのみ処理させる
2. When Re-check Processor が当該 PR の `needs-rebase` を除去できる状態
   （`mergeable=MERGEABLE`）にある, the Phase D Processor shall その PR の rebase を
   起動しない
3. When Phase D が当該 PR の rebase を起動した, the Re-check Processor shall 同一
   サイクル内で当該 PR のラベル除去操作を行わない
4. The watcher shall Phase D が処理した PR とその判定結果（mechanical / semantic /
   failed）をサマリログとして 1 行出力する

### Requirement 4: Claude による rebase 実行

**Objective:** As a watcher 運用者, I want conflict 解消を Claude が試行すること, so that 単純
な textual conflict と lockfile 系 conflict が人手を介さず解消される

#### Acceptance Criteria

1. When Phase D の対象 PR が確定した, the watcher shall 当該 PR の head ref を base ref
   へ rebase する処理を Claude 経由で 1 回試行する
2. The watcher shall rebase 試行の前後で当該 PR head ref の commit SHA を記録する
3. The watcher shall rebase 試行で生成された累積 diff（base ref 比較）を取得し、
   後段の mechanical / semantic 判定の入力とする
4. If Claude による rebase が conflict 解消できず終了した, the watcher shall その PR
   に `claude-failed` ラベルを付与し人間エスカレーション用コメントを 1 件投稿する
5. If Claude による rebase 試行が watcher 側のタイムアウトを超過した, the watcher shall
   rebase 操作を中断し当該 PR を `claude-failed` として扱う
6. The watcher shall rebase 成功時の push 操作で `--force-with-lease` 相当の安全な
   force push を使用する（`--force` 単独は使用しない）

### Requirement 5: Mechanical / Semantic 判定

**Objective:** As a watcher 運用者, I want Claude rebase 結果の安全性をパス単位で判定すること, so that
人間レビューを通っていない semantic 変更が自動 merge に流れないこと

#### Acceptance Criteria

1. When Phase D が rebase 後 diff の変更ファイル一覧を取得した, the Phase D Processor
   shall 各変更パスを `MECHANICAL_PATHS` allowlist と照合する
2. When すべての変更パスが `MECHANICAL_PATHS` allowlist に一致する, the Phase D
   Processor shall その rebase を `mechanical` と判定する
3. If 変更パスのうち 1 つ以上が `MECHANICAL_PATHS` allowlist のいずれにも一致しない,
   the Phase D Processor shall その rebase を `semantic` と判定する
4. If `MECHANICAL_PATHS` が未設定または空である, the Phase D Processor shall すべての
   rebase 結果を `semantic` として扱う（保守的判定）
5. The Phase D Processor shall 判定結果（`mechanical` / `semantic`）を当該 PR に
   対応するログ行に明示する

### Requirement 6: Mechanical 判定時の挙動

**Objective:** As a watcher 運用者, I want 安全と判定された rebase は既存 approve を維持して
auto-merge に到達できること, so that lockfile-only conflict の停滞が解消される

#### Acceptance Criteria

1. When 判定結果が `mechanical` である, the Phase D Processor shall 既存の approving
   review を剥がさない
2. When 判定結果が `mechanical` である, the Phase D Processor shall 当該 PR の
   `needs-rebase` ラベルを除去する
3. When 判定結果が `mechanical` である, the Phase D Processor shall その PR に追加の
   再レビュー誘導コメントを投稿しない
4. While `mechanical` 判定で push が成功している間, the watcher shall 既存の
   Merge Queue 系処理が当該 PR を通常通り扱える状態に戻す

### Requirement 7: Semantic 判定時の挙動（人間レビュー保護）

**Objective:** As a 人間レビュワー, I want Claude が semantic に書き換えた rebase は再レビュー
対象として戻されること, so that レビュー gate がバイパスされないこと

#### Acceptance Criteria

1. When 判定結果が `semantic` である, the Phase D Processor shall 当該 PR に付与
   されているすべての approving review を dismiss する
2. When 判定結果が `semantic` である, the Phase D Processor shall 当該 PR の
   `needs-rebase` ラベルを除去する
3. When 判定結果が `semantic` である, the Phase D Processor shall 当該 PR に
   `ready-for-review` ラベルを付与する
4. When 判定結果が `semantic` である, the Phase D Processor shall 当該 PR に
   人間レビュワー向け説明コメントを 1 件投稿する（rebase 実施・semantic 判定・
   approve dismissal・再レビュー要求の理由を含む）
5. The Phase D Processor shall approve dismissal を GitHub の review dismissal
   機構を通じて行い、`request_changes` 形式の別レビューを新規投稿する方式は使わない
6. If approve dismissal が API エラーで失敗した, the Phase D Processor shall その PR
   に `claude-failed` ラベルを付与し人間エスカレーション用コメントを 1 件投稿する

### Requirement 8: Rebase 失敗時のエスカレーション

**Objective:** As a watcher 運用者, I want Claude が rebase 自体に失敗した PR を即座に人間へ
渡すこと, so that 自動ループが暴走しないこと

#### Acceptance Criteria

1. When Claude rebase が成功しなかった, the watcher shall その PR の `needs-rebase`
   ラベルを除去しない（人間判断が必要であることを残す）
2. When Claude rebase が成功しなかった, the watcher shall その PR に `claude-failed`
   ラベルを付与する
3. When `claude-failed` を付与した, the watcher shall 失敗原因種別（conflict 解消失敗
   / タイムアウト / push 失敗 / dismissal 失敗 等）と手動復旧手順を含むコメントを
   1 件投稿する
4. While `claude-failed` ラベルが付いている間, the Phase D Processor shall 同一 PR
   への rebase 再試行を行わない

### Requirement 9: 設定の文書化と dogfood 検証

**Objective:** As a 新規導入者, I want 環境変数の意味と言語別の典型 allowlist 値を README から
即座に参照できること, so that 設定ミスなく opt-in できること

#### Acceptance Criteria

1. The README shall `AUTO_REBASE_MODE` の既定値・意味・有効化方法・無効化方法を
   「オプション機能一覧」相当の節に記載する
2. The README shall `MECHANICAL_PATHS` の既定値（空）・意味・空のときの挙動
   （すべて semantic 扱い）を記載する
3. The README shall `MECHANICAL_PATHS` の言語別設定例（JavaScript / Python / Go /
   Rust）を最低 1 例ずつ示す
4. When idd-claude 自身を Phase D の dogfood 対象として
   `MECHANICAL_PATHS=package-lock.json` 相当の設定で運用する, the watcher shall
   実装後の lockfile-only rebase が `mechanical` 判定で auto-merge へ到達することを
   観測可能なログとして残す

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When `AUTO_REBASE_MODE` を含む Phase D 関連の env var が一切設定されていない,
   the watcher shall 本機能導入前と完全に同一の挙動を保つ
2. The watcher shall 既存の env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` /
   `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `MERGE_QUEUE_*` / `BASE_BRANCH`
   等）の意味と既定値を変更しない
3. The watcher shall 既存ラベル名（`auto-dev` / `claude-claimed` / `needs-rebase` /
   `claude-failed` / `ready-for-review` 等）の名前と意味を変更しない
4. The watcher shall 既存 cron / launchd 登録文字列（実行コマンド・引数形式）を
   変更しない
5. The watcher shall 既存 exit code の意味を変更しない

### NFR 2: 観測可能性

1. The watcher shall Phase D の各 PR 処理について「PR 番号 / 判定結果（`mechanical` /
   `semantic` / `failed`）/ アクション要約」を 1 行ログとして出力する
2. The watcher shall Phase D サイクル終了時に「mechanical 件数 / semantic 件数 /
   failed 件数 / overflow 件数」のサマリ行を 1 件出力する

### NFR 3: 言語非依存性

1. The Phase D Processor shall 特定の言語ランタイム（Node.js / Python / Go / Rust 等）
   を導入依存に追加しない
2. The Phase D Processor shall `MECHANICAL_PATHS` の既定値を空とし、特定言語の
   lockfile 名を既定で内蔵しない

### NFR 4: 静的解析

1. The watcher スクリプト shall 変更後も `shellcheck` 警告ゼロを維持する

### NFR 5: タイムアウトと安全性

1. The Phase D Processor shall 1 PR あたりの Claude rebase 試行に観測可能な timeout
   を設ける（具体値は design.md）
2. The Phase D Processor shall 失敗・タイムアウト時に作業ディレクトリと base
   branch を Phase A 既存実装と同等の rollback パターン（`rebase --abort` 後の
   base branch 復帰）で原状復帰させる
3. The Phase D Processor shall force push 時に `--force-with-lease` 相当の安全な
   形式のみを使用する

## Definition of Done（Issue 本文との対応）

各項目は前述 Requirements / NFR への対応 ID を併記する。

1. lockfile-only conflict の PR が approve を維持して auto-merge に到達する
   → Req 5.1 / 5.2 / 6.1 / 6.2 / 6.4 / 9.4
2. コード conflict を Claude が解消した PR が approve を剥がされ `ready-for-review`
   に戻る → Req 5.3 / 7.1 / 7.2 / 7.3 / 7.4 / 7.5
3. `AUTO_REBASE_MODE` 環境変数で opt-in/opt-out を制御できる（既定 off）
   → Req 1.1 / 1.2 / 1.3 / NFR 1.1
4. rebase 失敗時は `claude-failed` ラベルが付き人間エスカレーションになる
   → Req 4.4 / 4.5 / 8.1 / 8.2 / 8.3
5. `MECHANICAL_PATHS` allowlist は既定空（言語非依存）
   → Req 5.4 / NFR 3.2
6. README に両 env var の説明と言語別設定例（JS / Python / Go / Rust）がある
   → Req 9.1 / 9.2 / 9.3
7. watcher スクリプトの `shellcheck` がクリーン → NFR 4.1
8. idd-claude 自身での dogfood 検証
   （`MECHANICAL_PATHS=package-lock.json` 設定下で観測可能） → Req 9.4 / NFR 2.1

## Out of Scope

- 予防的 overlap 検知（Phase E / #18）
- AST diff による semantic 判定（言語依存）
- Claude 自己判定方式（精度未検証、Open Questions に再評価余地のみ残す）
- `needs-rebase` ラベルが付かない PR への自動介入
- `MECHANICAL_PATHS` の既定値として特定言語の lockfile 名を内蔵すること
- Phase A 本体（#14）/ Re-check Processor（#27）の挙動変更
- 外部 Feature Flag SaaS との連携

## Open Questions

1. Phase D Processor のループ起動位置（Phase A 本体の前 / 後 / Re-check の前 / 後）
   は競合排除条件（Req 3.1〜3.3）を満たす限り design.md で確定すること。
   要件としては「同一サイクルで二重処理しない」までを規定し、具体的な実行順序は
   Architect の領分とする
2. Claude 自己判定方式（Issue 本文の方式 b）を将来 fallback として導入する余地を
   設計で残すか、または完全に Non-Goals として封じるかは design.md / Issue
   コメントで Architect が提案すること
3. `MECHANICAL_PATHS` の構文（カンマ区切り / 改行区切り / glob サポート範囲）は
   design.md の領分とする。要件としては「allowlist 照合ができること」までを規定
4. Branch protection で「Dismiss stale pull request approvals when new commits are
   pushed」が有効な repo では、Phase D の `mechanical` rebase 後の force push でも
   既存 approve が dismiss される。この場合の挙動（再 approve を待つ / 人間に
   通知する）は Issue 本文に明示されていない。README に注記として残すか、
   Phase D 側で検知して INFO ログのみとするかは Architect が判断する
