# Requirements Document

## Introduction

Claude API の一時的な過負荷（HTTP 529 Overloaded）が原因で自動開発フロー（Issue の Stage A〜C や PR の
needs-iteration 反復）が中断した場合、現状は watcher のサーバーログ（`cron.log` および
個別ステージログ）にしか手がかりが残らない。そのため運用者が GitHub の Issue / PR 画面だけを見ても
「なぜ自動開発が止まったのか」「なぜ Round 着手表明コメントだけが連投され成果が進まないのか」を
判別できず、本来であれば「時間をおいて自動再試行を待てばよい」一時障害を、人間が誤って恒常的な
失敗として深掘り対応してしまうリスクがある。本機能は、watcher が Claude 実行のエラーログから
Claude API 一時混雑エラー（529 Overloaded）を検知できた場合に、Issue / PR のコメントとして警告
メッセージを追記し、運用者がブラウザ上だけで一時障害と恒常的な失敗を区別できるようにする。

## Requirements

### Requirement 1: PR 反復処理における 529 一時エラーの可視化

**Objective:** As a 自動開発 watcher の運用者, I want PR の needs-iteration 反復処理で Claude が
失敗した際に Claude API 一時混雑エラー (529) を検出してその旨を PR コメントへ明記してほしい, so that
PR のタイムラインだけを見て一時障害と恒常的な失敗を区別でき、無駄な人間トリアージを発生させずに
次のポーリングサイクルでの自動再試行を待てる。

#### Acceptance Criteria

1. When PR 反復処理で Claude 実行が非ゼロ終了し、当該 round の Claude 実行ログから 529 一時混雑
   エラーの痕跡が検出されたとき, the PR Iteration Processor shall 当該 PR のコメントとして
   Claude API 一時混雑エラー (529 Overloaded) を検出した旨と次回ポーリングサイクルで自動再試行
   される旨の説明文を投稿する。
2. When PR 反復処理で Claude 実行が非ゼロ終了し、当該 round の Claude 実行ログから 529 一時混雑
   エラーの痕跡が検出されたとき, the PR Iteration Processor shall 当該 round に紐づく進捗
   メタデータ（round カウンタ・no-progress 連続カウンタ・needs-iteration ラベル状態）を据え置く。
3. If PR 反復処理で Claude 実行が非ゼロ終了したが 529 一時混雑エラーの痕跡が検出されないとき,
   the PR Iteration Processor shall 529 警告コメントを投稿しない。
4. If PR 反復処理で Claude 実行が正常終了したとき, the PR Iteration Processor shall 529 警告
   コメントを投稿しない。
5. If 529 検知の対象となる Claude 実行ログファイルが存在しない、または読み取り不能であるとき,
   the PR Iteration Processor shall 529 警告コメントの投稿を抑止し、既存の PR 反復処理の継続を
   妨げない。

### Requirement 2: 一般 Issue 自動開発における 529 一時エラーの可視化

**Objective:** As a 自動開発 watcher の運用者, I want Issue の自動開発フロー（Stage A〜C 等）が
claude-failed として中断した際に Claude API 一時混雑エラー (529) が原因の可能性があれば Issue の
失敗通知コメントへ警告を含めてほしい, so that 当該 Issue のコメント欄を読むだけで「時間をおいて
再試行すべき一時障害」と「設計やコード起因の恒常的な失敗」を区別でき、`claude-failed` ラベル
解除の判断を早く下せる。

#### Acceptance Criteria

1. When Issue の自動開発フローが失敗し claude-failed ラベル付与とともに失敗通知コメントを投稿する
   とき, the Issue Watcher shall 当該実行ログから 529 一時混雑エラーの痕跡を検出した場合に限り
   失敗通知コメント内に Claude API 一時混雑エラー (529 Overloaded) が検出された旨と一時的な混雑
   の可能性があるため時間をおいて再試行すべき旨の警告文を含める。
2. If Issue の自動開発フローが失敗した際に当該実行ログから 529 一時混雑エラーの痕跡が検出
   されなかったとき, the Issue Watcher shall 失敗通知コメント内に 529 警告文を含めない。
3. While Issue の自動開発フローが正常に進行している間、the Issue Watcher shall 529 警告文を
   投稿しない。
4. If 529 検知の対象となる実行ログファイルが存在しない、または読み取り不能であるとき,
   the Issue Watcher shall 529 警告文を含めない既存の失敗通知コメントを投稿し、claude-failed
   ラベル遷移とコメント投稿の本来の責務を完遂する。

### Requirement 3: 529 警告コメントの可読性と運用情報

**Objective:** As a 運用者, I want 529 警告コメントから状況と次に取るべきアクションを 1 目で
読み取りたい, so that 警告文を読んだ瞬間に「待つべきか」「対応すべきか」を判断できる。

#### Acceptance Criteria

1. The 529 警告コメント shall Claude API 一時混雑エラー (529 Overloaded) が検出された事実を
   日本語で明示する。
2. The 529 警告コメント shall 当該失敗が一時的な API 混雑に起因する可能性があり恒常的な失敗とは
   性質が異なることを運用者に伝える文言を含む。
3. Where 警告対象が PR 反復処理であるとき, the 529 警告コメント shall 次回ポーリングサイクルで
   自動再試行されることおよび進捗メタデータが据え置かれる旨を明示する。
4. Where 警告対象が一般 Issue 自動開発であるとき, the 529 警告コメント shall 時間をおいて
   再試行すべき旨を運用者に促す文言を含む。

### Requirement 4: スコープ境界と既存挙動への非干渉

**Objective:** As a watcher の運用者, I want 529 検知機能の導入により既存の正常系・異常系・待機系
ふるまいが書き換わらないことを保証してほしい, so that 本機能のロールアウト後も既存の Issue / PR
処理パイプラインに対する後方互換性が維持される。

#### Acceptance Criteria

1. The 529 検知機能 shall 既存の Claude API 呼び出し回数・ポーリング間隔・リトライ間隔を増加
   させない（即時の自動再呼び出しを行わない）。
2. The 529 検知機能 shall 既存のラベル遷移（`claude-failed` / `needs-iteration` /
   `claude-picked-up` 等）の付与・除去タイミングを変更しない。
3. The 529 検知機能 shall 既存の watcher ログ出力フォーマットを破壊せず、既存ログ消費者から
   見た出力契約を維持する。
4. If 529 検知処理自体が予期せず失敗したとき, the 529 検知機能 shall 既存の失敗通知コメントの
   投稿および claude-failed ラベル付与の責務を妨げない。

## Non-Functional Requirements

### NFR 1: 安全性と冪等性

1. The 529 検知機能 shall ログ走査・コメント本文組み立て・コメント投稿のいずれの段階で例外が
   発生した場合でも、watcher プロセスを異常終了させず既存処理を継続させる。
2. The 529 検知機能 shall 同一の失敗ログに対して同一実行内で重複する 529 警告コメントを投稿
   しない（1 回の失敗イベントに対して 1 件のコメント追記または 1 件の失敗通知コメント内包に
   とどめる）。

### NFR 2: 可観測性

1. When 529 検知ロジックが Claude 実行ログを走査したとき, the 529 検知機能 shall 検知結果
   （検知あり / 検知なし / ログ不在）を watcher のサーバーログ（`$LOG`）から運用者が事後に
   追跡できる粒度で記録する。

### NFR 3: 後方互換性

1. While 本機能を導入する PR が main にマージされた後も、the watcher shall 既存環境変数名
   （`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` 等）・既存ラベル名・cron 登録文字列の
   後方互換性を維持する。

## Out of Scope

- Claude API 一時障害発生時の即時自動リトライ（API サーバー過負荷を更に増幅させないため、
  既存ポリシー「次回ポーリングサイクルで自動再試行」を維持する）。
- Slack / Discord / メール等、GitHub の Issue / PR コメント以外への 529 障害通知連携。
- 429 Rate Limit / 401 Unauthorized 等、529 以外の Claude API エラー応答に対する新たな
  可視化機構の追加（既存の quota-aware / claude-failed 経路で扱う）。
- 529 検知パターン文字列の自動更新機構（検知パターンは実装側で定数として保守する）。
- 過去の Issue / PR に対する 529 警告の遡及付与（retrofit）。
- 529 発生頻度の集計・ダッシュボード化・SLO レポート機能。

## Open Questions

- なし（Issue 本文の「期待する挙動」「受入基準の候補」「スコープ外」が十分に具体的であり、
  実装着手前に確定が必要な業務判断は残っていない。529 検知の具体パターン文字列・走査対象
  ファイルパス等は実装詳細として `design.md` に委ねる）。

## 関連

- Parent: #259
