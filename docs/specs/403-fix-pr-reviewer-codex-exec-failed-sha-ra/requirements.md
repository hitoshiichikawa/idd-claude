# Requirements Document

## Introduction

`PR Reviewer Processor`（`modules/pr-reviewer.sh`）が `codex` / `antigravity` のレビュー実行で
非ゼロ終了（`kind=exec-failed`）したとき、watcher は同一 PR / 同一 head sha を次サイクル以降
（既定 2 分毎）も無条件に候補へ含めて再実行する。エラーコメントは重複防止で 1 回しか投稿されない
ものの、外部レビューツール側の呼び出し自体は止まらないため、rate-limit（429）等の一時障害が
発生すると無限リトライ自体が rate-limit を持続させ、複数 repo の PR merge が同時に停止する事故
が発生している（ae-mdm 162 件 / altpocket-server 59 件の `exit=1` ログを観測）。加えて
`exec-failed` コメントに載る stderr 抜粋は先頭 1KB のため、prompt echo に埋もれて 429 等の真因が
運用者に伝わらない。本機能では、同一 sha での連続失敗を state として記録し上限到達で打ち切り /
エスカレートする経路と、運用者が exec-failed の真因を確認できる診断性向上を、後方互換と安全側
デフォルトを満たす形で導入する。

## Requirements

### Requirement 1: 同一 sha での連続 exec-failed の検出と state 永続化

**Objective:** As a watcher 運用者, I want PR Reviewer Processor に同一 head sha の連続 exec-failed
回数を永続的に記録させる, so that 一時障害が継続中の PR を機械的に識別し、無限リトライから保護
できる

#### Acceptance Criteria

1. When PR Reviewer Processor が `kind=exec-failed`（非ゼロ終了 / 空出力 / workspace-modified を
   含む実行失敗扱い）の結果を確定したとき, the PR Reviewer Processor shall 当該 PR と head sha に
   紐づく連続失敗カウンタを 1 加算した値で永続化する
2. When 同一 PR の head sha が前サイクルから変化したとき, the PR Reviewer Processor shall
   連続失敗カウンタを 0 にリセットする
3. When 同一 PR の同一 head sha でレビューが成功（kind=review コメント投稿到達）したとき, the
   PR Reviewer Processor shall 連続失敗カウンタを 0 にリセットする
4. The PR Reviewer Processor shall 連続失敗カウンタを再起動・cron 再実行をまたいで参照できる
   形（PR コメントの hidden marker または `$HOME/.issue-watcher/` 配下の state file のいずれか）で
   永続化する
5. If 連続失敗カウンタの読み出し / 書き込みに失敗したとき, the PR Reviewer Processor shall
   WARN ログに失敗理由を残し、当該サイクルでは安全側（リトライ抑止側）に倒した上でパイプライン
   を継続する
6. The PR Reviewer Processor shall 連続失敗カウンタの現在値・head sha・PR 番号をサイクル毎の
   観測ログに 1 行で出力する

### Requirement 2: 連続 exec-failed 上限到達時のリトライ抑止とエスカレーション

**Objective:** As a watcher 運用者, I want 同一 sha で連続 exec-failed が一定回数に達した PR を
レビュー候補から除外しエスカレーションさせる, so that 一時障害の原因が解消されるまで毎 tick の
外部レビューツール呼び出しを止め、rate-limit を持続させない

#### Acceptance Criteria

1. While 同一 PR の同一 head sha に対する連続失敗カウンタが上限値（既定値 / 後述 NFR 2.1）未満で
   推移している間, the PR Reviewer Processor shall 通常のレビュー候補選定と実行を継続する
2. When 同一 PR の同一 head sha に対する連続失敗カウンタが上限値に達した状態でレビュー候補列挙が
   行われるとき, the PR Reviewer Processor shall 当該 PR を候補から除外して外部レビューツール
   （`codex` / `agy`）を実行しない
3. When 連続失敗カウンタが上限値に達したことを初めて検出したサイクルに限り, the PR Reviewer
   Processor shall 当該 PR にエスカレーション用のコメント（上限到達理由・連続失敗回数・運用者の
   復旧手順を含む）を 1 回だけ投稿する
4. The PR Reviewer Processor shall 上限到達後にエスカレーション扱いとなった PR への外部レビュー
   ツール呼び出しを、同一 head sha が継続している間は再開しない
5. When 同一 PR の head sha が新しい commit によって変化したとき, the PR Reviewer Processor
   shall Requirement 1.2 によりカウンタを 0 にリセットし、当該 PR をレビュー候補へ再投入する
6. If 連続失敗カウンタが上限値に達した PR が複数同時に存在するとき, the PR Reviewer Processor
   shall 各 PR を独立にエスカレートし、相互に影響を与えない
7. The PR Reviewer Processor shall 上限到達によるエスカレーションを行う際の遷移先（GitHub ラベル
   付与 / Issue コメントのみによる advisory 通知 / コメント本文に運用者向け復旧手順を埋め込む等）
   を **安全側のデフォルト 1 つ**で実装し、その選択（`claude-failed` ラベル付与 / `needs-quota-wait`
   ラベル付与 / ラベル付与なしの advisory コメントのみ、いずれか）と理由を Architect / Developer
   ステージで確定する

### Requirement 3: exec-failed の真因に到達できる診断性向上

**Objective:** As a watcher 運用者, I want exec-failed 時の stderr / 関連診断情報を運用者から
追跡可能な形で記録させる, so that 429 / rate-limit / timeout 等の真因を判別し、外部レビュー
ツールの設定や上位 API 側の対処へ繋げられる

#### Acceptance Criteria

1. When exec-failed が確定したとき, the PR Reviewer Processor shall 当該実行の stderr を 1KB 抜粋
   よりも大きい単位で参照可能にする（PR エラーコメントへの追加抜粋拡張、または `$HOME/.issue-watcher/`
   配下の artifact ファイルへの保存、のいずれかの形）
2. While exec-failed エラーコメントを投稿する間, the PR Reviewer Processor shall コメント本文に
   stderr 抜粋に加えて、artifact ファイル参照パス・実行コマンド種別（`codex` / `antigravity`）・
   非ゼロ終了コード・連続失敗カウンタ値・head sha のいずれも含めて記録する
3. The PR Reviewer Processor shall exec-failed の観測ログ 1 行に PR 番号・head sha・tool 名・
   exit code・連続失敗カウンタ・診断 artifact 参照（保存した場合）を出力する
4. If stderr 全体が 1MB を超えるとき, the PR Reviewer Processor shall 末尾を優先して保存し、
   保存上限と truncation 発生の旨を観測ログに記録する
5. Where artifact ファイル保存方式を採用するとき, the PR Reviewer Processor shall 保存先パスを
   予測可能名の `/tmp` 直下ではなく `$HOME/.issue-watcher/` 配下に置く（CLAUDE.md 機能追加
   ガイドライン 6 に準拠）

### Requirement 4: 既存正常系の挙動不変

**Objective:** As a watcher 運用者, I want 本変更が exec-failed していない PR のレビュー挙動に
影響を与えない, so that 通常運用中の codex / antigravity レビューの実行・コメント投稿・VERDICT
判定が従来通り動作する

#### Acceptance Criteria

1. When 同一 PR の同一 head sha に対する連続失敗カウンタが 0 のとき, the PR Reviewer Processor
   shall 候補選定・prompt 解決・外部レビューツール実行・コメント投稿・VERDICT 検出・ラベル付与
   の各挙動を本変更導入前と同等に保つ
2. When レビュー実行が成功し正常な VERDICT を含むコメントを投稿したとき, the PR Reviewer
   Processor shall Requirement 1.3 のリセットを行うことを除き、既存の VERDICT → `needs-iteration`
   ラベル付与経路・commit status publish 経路を変更しない
3. The PR Reviewer Processor shall 候補 PR 列挙時の head pattern 一致・fork 除外・draft 除外・
   MAX_PRS truncate の挙動を本変更導入前と同等に保つ
4. The PR Reviewer Processor shall 既存の `kind=conflict-tool` / `kind=not-installed` /
   `kind=not-authenticated` / `kind=workspace-modified` の各サイクルレベルエラーに対する
   broadcast 動作を変更しない

## Non-Functional Requirements

### NFR 1: 後方互換性と opt-in / 安全側デフォルト

1. The PR Reviewer Processor shall 連続失敗カウンタの記録機構を、`PR_REVIEWER_ENABLED=true`
   で従来運用されている消費者にとって既定挙動として有効化する（既定 ON）。ただし、上限値・
   エスカレーション遷移を含む全パラメータは env var で override 可能とする
2. The PR Reviewer Processor shall 新規導入する env var の不正値・空文字・typo を、起動時に
   安全側（リトライ抑止が過剰にも過小にもならない既定値）へ正規化する
3. The PR Reviewer Processor shall 既存 env var 名（`PR_REVIEWER_ENABLED` / `PR_REVIEWER_TOOL` /
   `PR_REVIEWER_CODEX_ENABLED` / `PR_REVIEWER_ANTIGRAVITY_ENABLED` / `PR_REVIEWER_MAX_PRS` /
   `PR_REVIEWER_EXEC_TIMEOUT` 等）の意味・既定値・受理する値域を本変更で変更しない
4. The PR Reviewer Processor shall 本変更で追加する env var 名を `PR_REVIEWER_` プレフィックスで
   統一し、関数 prefix は `pr_` を維持する（CLAUDE.md 機能追加ガイドライン 2）

### NFR 2: 上限値・閾値の数値仕様

1. The PR Reviewer Processor shall 連続失敗カウンタの上限既定値を 3 回とし、`PR_REVIEWER_EXEC_FAIL_LIMIT`
   等の env var で 1 以上の整数に override 可能とする（既定 3 は pr-iteration の no-progress-streak
   既定と整合させた仮値で、Architect / Developer ステージで最終確定する）
2. The PR Reviewer Processor shall 上限到達による候補除外を、新規 head sha が観測された時点で
   解除する（時間ベースの cool-down は本要件のスコープ外とする。Architect ステージで cool-down
   方式の必要性を再評価可能とする）

### NFR 3: 観測性 / 運用診断

1. The PR Reviewer Processor shall 既存のサイクル開始 / サマリログに、エスカレート済み件数
   （上限到達によりレビューを抑止した PR 数）を追加して出力する
2. The PR Reviewer Processor shall exec-failed 確定時の WARN ログに、PR 番号・head sha・tool 名・
   exit code・連続失敗カウンタ・artifact 参照（保存した場合）を 1 行で含める

### NFR 4: root ↔ repo-template の同期と冪等性

1. The PR Reviewer Processor の変更は、root `local-watcher/bin/modules/pr-reviewer.sh` と
   `repo-template/.claude/` / `repo-template/local-watcher/` 配下の対応物（およびテストハーネス）
   を同一 PR で byte 一致同期する（CLAUDE.md「機能追加ガイドライン」4 に準拠）
2. The PR Reviewer Processor shall 同一サイクル内で同一 PR を複数回スキャンしても外部副作用
   （コメント投稿・state 書き込み）を冪等に保つ（重複コメント投稿を起こさない）
3. When `PR_REVIEWER_ENABLED` が `=true` 厳密一致でないとき, the PR Reviewer Processor shall
   本変更で追加された経路を含めて外部 API 呼び出し・state 書き込みを行わず即 return する

## Out of Scope

- `codex` 側（OpenAI）の rate-limit 上限そのものの調整、および `codex` CLI への `--rate-limit`
  オプション等の追加要求
- merge ゲート（branch protection / required status checks）を `codex` 非依存に再設計する件
  （Issue 著者明記の別 Issue 領分）
- レビュー実行の指数バックオフ「待機時間」を tick 内で sleep する形での導入（本件は tick 単位
  での候補除外 / リトライ抑止を採用し、tick 内 sleep は導入しない）
- `antigravity` ツール固有の認証エラー検出強化（既存の `not-authenticated` 経路で十分）
- 連続失敗カウンタ・エスカレートの可視化 UI（Web ダッシュボード等）
- 過去サイクルで蓄積した `exec-failed` コメントの遡及的 cleanup
- `claude` / Claude Reviewer の reject 経路に対する同種の連続失敗保護（本件は外部レビュー
  ツール = codex / antigravity の exec-failed のみを対象とする）

## Open Questions

- 上限到達時の遷移先について、Issue 著者は (a) `claude-failed` ラベル付与で human エスカレート /
  (b) `needs-quota-wait` 相当の専用扱い / (c) advisory コメントのみで継続、の 3 案を「設計判断に
  委ねる」と明言している。Requirement 2.7 は本要件で 1 つ選択する旨を明示しているが、ラベル
  運用（`failed-recovery.sh` との重複動作リスク / `needs-quota-wait` の既存セマンティクス）への
  影響評価は Architect ステージで最終決定する
- artifact ファイル保存方式（Requirement 3.1 / 3.5）と PR コメント本文の抜粋拡張のどちらを正規
  実装とするかは、`PR_REVIEWER_STATUS_CHECK_ENABLED=true` 環境での GitHub Actions / cron 双方
  からのファイルアクセス可否を含めて Architect ステージで確定する
- `PR_REVIEWER_EXEC_FAIL_LIMIT` の既定値（NFR 2.1 で仮値 3）は、pr-iteration の no-progress-streak
  既定（3）と揃えることを推奨するが、実運用での「一時的な rate-limit が解消するまでの平均 tick 数」
  に基づく見直しを Developer ステージで行う
- 連続失敗カウンタを保持する媒体（hidden marker / state file）の選択は、`pr-iteration` の
  既存 hidden marker 方式（`<!-- idd-claude:pr-iteration ... no-progress-streak=K -->`）と整合
  させるかどうかを Architect ステージで判断する

## 関連

- Related: #399
- Related: #397
- Related: #261
