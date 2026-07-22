# Requirements Document

## Introduction

tasks-count-gate（#147 / #216）は Architect が `tasks.md` を確定した直後に最上位・未完了タスクを
機械的に再カウントし、11 件以上で `needs-decisions` を付与して Developer 自動起動を抑止する。
しかし現行のエスカレーションは「分割を検討してください」という警告コメントに留まり、実際の分割
作業（どのタスクをどの子 Issue に束ねるか、依存関係をどう表すか）はすべて人間が担っている。
本書は、escalate 時に **親タスク単位の子 Issue 分割案** をコメントとして機械生成・投稿し、人間の
作業を「案の承認・調整・起票」に軽減する Phase 3 の要件を定義する。子 Issue の自動起票は行わず
提案に留め、既定無効の opt-in gate により未設定環境では現行と完全に同一の挙動を保つ。

## 関連

- Depends on: #507
- Sibling: #508
- Related: #131 #147 #216

## Requirements

### Requirement 1: opt-in gate と既定無効

**Objective:** As a watcher 運用者, I want 分割案の投稿を環境変数で明示的に有効化できること, so that 未設定環境では本機能導入前と完全に同一の挙動が保たれる

#### Acceptance Criteria

1. The tasks-count gate shall `TC_SPLIT_PROPOSAL_ENABLED` の既定値を無効として扱い、当該変数が宣言されていない環境でも無効とする
2. Where `TC_SPLIT_PROPOSAL_ENABLED` がリテラル文字列 `true` に設定されているとき, the tasks-count gate shall 分割案コメントの生成と投稿を実行する
3. If `TC_SPLIT_PROPOSAL_ENABLED` に `true` 以外の値（空文字列 / `false` / `off` / `True` / `1` / typo）が与えられたとき, the tasks-count gate shall 当該 gate を安全側（無効）へ正規化する
4. While gate が無効であるとき, the tasks-count gate shall 本機能に起因する GitHub API 呼び出しとログ出力を一切行わない
5. The tasks-count gate shall 本機能の gate を既存の `TC_ENABLED` および `MODEL_ROUTING_ENABLED` とは独立した変数で制御する
6. While `TC_ENABLED` による opt-out で tasks-count gate 自体が実行されないとき, the tasks-count gate shall `TC_SPLIT_PROPOSAL_ENABLED` の値にかかわらず分割案コメントを投稿しない

### Requirement 2: 投稿トリガ条件

**Objective:** As a watcher 運用者, I want 分割案が escalate 時にのみ投稿されること, so that 正常・警告レンジの Issue にノイズコメントが増えない

#### Acceptance Criteria

1. While gate が有効であるとき, when 件数分類が escalate と確定したとき, the tasks-count gate shall 当該 Issue に子 Issue 分割案を含むコメントを投稿する
2. While gate が有効であるとき, when 件数分類が normal または warn であるとき, the tasks-count gate shall 分割案コメントを投稿しない
3. The tasks-count gate shall 分割案の投稿を既存 escalation コメント投稿および `needs-decisions` ラベル付与に **追加する形**で行い、それらを置き換えない
4. If 分割案の入力となる最上位・未完了タスクを 1 件も抽出できなかったとき, the tasks-count gate shall 分割案コメントを投稿せず理由をログに残す
5. The tasks-count gate shall 分割案の生成に、当該サイクルの escalate 判定で計数した `tasks.md` と同一のファイルを入力として用いる
6. While design フェーズを経由しない経路（impl-resume / Stage Checkpoint Resume 等、tasks-count gate 自体が起動しない経路）で Issue が処理されるとき, the tasks-count gate shall 分割案コメントを投稿しない

### Requirement 3: 分割案のグルーピング規則

**Objective:** As a Issue 分割を担当する人間, I want 分割案の粒度と依存の扱いが決定論的であること, so that 提示された案をそのまま検証・調整できる

#### Acceptance Criteria

1. The tasks-count gate shall 分割案の構成単位を `tasks.md` の最上位・未完了タスクとし、既定で最上位タスク 1 件につき子 Issue 案 1 件を生成する
2. The tasks-count gate shall 子タスク（小数階層 numeric ID）および完了済みタスク（`- [x]` / `- [x]*`）を独立した子 Issue 案として生成しない
3. The tasks-count gate shall 最上位タスクの抽出条件を tasks-count gate の既存計数規約（正準 regex を持つ最上位・未完了タスク行の判定）と一致させ、同一 `tasks.md` に対して escalate 判定の件数と抽出件数を一致させる
4. When 最上位タスク間に `_Depends:_` アノテーション由来の相互依存（依存関係が循環する関係）が存在するとき, the tasks-count gate shall 当該タスク群を 1 件の子 Issue 案に統合する
5. When `_Depends:_` の値が子タスクの numeric ID を参照しているとき, the tasks-count gate shall 当該参照を対応する最上位タスクの ID に正規化して扱う
6. The tasks-count gate shall 抽出したすべての最上位・未完了タスクを、いずれか 1 件の子 Issue 案へ欠落・重複なく 1 回だけ割り当てる
7. The tasks-count gate shall 子 Issue 案を `tasks.md` 上の最上位タスクの出現順で並べ、同一入力に対して常に同一の分割案を生成する

### Requirement 4: 分割案コメントの内容

**Objective:** As a Issue 分割を担当する人間, I want 各子 Issue 案が起票に必要な情報を備えること, so that 案を読んだだけで子 Issue を起票・調整できる

#### Acceptance Criteria

1. The tasks-count gate shall 各子 Issue 案にタイトル案を 1 件含める
2. The tasks-count gate shall 各子 Issue 案に、当該案が含む最上位タスクの numeric ID 一覧を含める
3. The tasks-count gate shall 各子 Issue 案に、分割元となった Issue を指す `Split from: #<元 Issue 番号>` を含める
4. The tasks-count gate shall 各子 Issue 案に、親を指す `Parent: #<元 Issue 番号>` を含める
5. When 子 Issue 案の間に依存関係が存在するとき, the tasks-count gate shall 依存する側の案に `Depends on:` 行を含める
6. While 子 Issue が未起票で Issue 番号が確定していないとき, the tasks-count gate shall `Depends on:` の参照先を分割案内の案番号で表し、起票後に実 Issue 番号へ置き換える必要がある旨をコメント本文に明記する
7. The tasks-count gate shall 関係種別のキー文字列を canonical 記法（`Depends on:` / `Parent:` / `Split from:`）の英語表記で出力し、alias 表記（`前提依存:` / `Blocked by:` / `親 Issue:` / `分割元:`）を用いない
8. The tasks-count gate shall 逆ブロッキング表記（`Blocks:`）を出力しない
9. The tasks-count gate shall 本コメントが提案であり子 Issue の自動起票を行わない旨をコメント本文に明記する
10. The tasks-count gate should 人間が次に取る操作（子 Issue 起票コマンドの雛形）をコメント本文に含める
11. The tasks-count gate shall 検知件数と適用閾値を分割案コメントから参照できる形で含める

### Requirement 5: 冪等性

**Objective:** As a watcher 運用者, I want 分割案コメントが同一 Issue に重複投稿されないこと, so that 再実行や次サイクルの評価でコメント欄が汚れない

#### Acceptance Criteria

1. The tasks-count gate shall 分割案コメントに、本機能由来であることを機械的に識別できる固定マーカーを含める
2. If 同一 Issue のコメント履歴に本機能のマーカーが既に存在するとき, the tasks-count gate shall 分割案コメントを再投稿しない
3. The tasks-count gate shall 分割案コメントの既投稿判定を、既存 escalation コメントのマーカーとは独立したマーカーで行う
4. When 既存 escalation コメントがマーカー検知によりスキップされたとき, the tasks-count gate shall 分割案コメントの投稿可否を本機能のマーカーのみで判定する
5. When 同一 Issue に対して本機能が複数サイクルにわたり評価されたとき, the tasks-count gate shall 分割案コメントを 1 件のみ存在させる
6. If コメント履歴の取得に失敗したとき, the tasks-count gate shall マーカー不在として扱い、影響を重複コメント 1 件までに留める
7. When 分割案コメントの投稿をスキップしたとき, the tasks-count gate shall スキップ理由を判別できるログを出力する

### Requirement 6: 既存挙動の不変性と fail-open

**Objective:** As a watcher 運用者, I want 本機能の失敗が既存の escalate 処理を止めないこと, so that 補助機能の不調で Developer 抑止という本来の保護が失われない

#### Acceptance Criteria

1. While gate が無効であるとき, the tasks-count gate shall 本機能導入前と同一の escalate 挙動（escalation コメント本文・`needs-decisions` ラベル付与・ログ行）を保つ
2. The tasks-count gate shall 既存 env var（`TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER`）の名前・既定値・意味のいずれも変更しない
3. The tasks-count gate shall 既存の判定レンジ境界（normal / warn 8〜10 件 / escalate 11 件以上）と分類結果を変更しない
4. The tasks-count gate shall 既存 escalation コメントの本文と識別マーカー文字列を変更しない
5. If 分割案の生成が失敗したとき, the tasks-count gate shall WARN ログを残したうえで escalate 本体の処理（escalation コメント投稿・`needs-decisions` ラベル付与）を完了させる
6. If 分割案コメントの投稿が失敗したとき, the tasks-count gate shall WARN ログを残し、呼び出し元の処理を中断せず継続する
7. The tasks-count gate shall 分割案の生成にあたり `tasks.md` を書き換えない
8. The tasks-count gate shall 本機能に起因して design 分岐の成功／失敗判定および exit code の意味を変更しない
9. The tasks-count gate shall 本機能に起因する失敗を silent fail させない

### Requirement 7: ドキュメント更新と配布物の同期

**Objective:** As a repository 管理者, I want 新 gate の説明と配布物の同期が同一 PR で完了すること, so that README と実挙動の乖離や consumer repo へのドリフトが発生しない

#### Acceptance Criteria

1. The README shall `TC_SPLIT_PROPOSAL_ENABLED` の既定値・正規化規則・有効化方法をオプション機能一覧の opt-in 節に含める
2. The README shall 分割案コメントに含まれる情報と、人間が取る次アクション（案の承認・調整・子 Issue 起票）を tasks-count gate の節に記述する
3. The README shall 本機能が追加するログ行の形式を tasks-count gate の観測方法の記述に含める
4. Where root と repo-template で二重管理される配布物を変更したとき, the repository shall 双方を同一 PR で同期する
5. The repository shall 上記ドキュメント更新を本機能の実装と同一 PR で行う

### Requirement 8: 検証可能性

**Objective:** As a reviewer, I want 本機能の受け入れ確認手段が事前に定義されていること, so that PR レビュー時に AC 充足を機械的に確認できる

#### Acceptance Criteria

1. The 変更後の bash スクリプト shall `shellcheck` を警告ゼロで通過する
2. The 変更後の bash スクリプト shall `bash -n` の構文検査を通過する
3. The repository shall 分割案生成の純粋関数に対する近接テストを `local-watcher/test/` 配下に既存命名規約で追加する
4. The 近接テスト shall fixture の `tasks.md` を入力として、期待される子 Issue 案の件数・対象タスク ID・依存表現を検証する
5. The 近接テスト shall 最上位 11 件のフラット構成 / 子タスクと完了済みタスクを含む構成 / `_Depends:_` による相互依存を含む構成 / 最上位タスク 0 件 / gate 無効 の 5 ケースを含む
6. The 検証手順 shall gate 無効時に既存 escalate 挙動が変化しないことの確認を含む

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While gate が無効であるとき, the watcher shall 本機能導入前と同一のログ出力・ラベル遷移・exit code の意味を保つ
2. The watcher shall 既存 env var 名・既存ラベル名・cron 登録文字列・ログ出力先のいずれも変更しない
3. The watcher shall 新規 env var を未設定のまま既存 consumer 環境が動作したときに、本機能導入前と同一の外部挙動を提供する

### NFR 2: 可観測性

1. When 分割案コメントを投稿したとき, the tasks-count gate shall 既存の `tasks-count:` prefix・Issue 番号・生成した子 Issue 案の件数を含む 1 行のログを出力する
2. When 分割案コメントの投稿をスキップしたとき, the tasks-count gate shall スキップ理由を含む 1 行のログを出力する
3. If 分割案の生成または投稿が失敗したとき, the tasks-count gate shall Issue 番号と失敗理由を含む WARN 行を標準エラー出力へ出す
4. The tasks-count gate shall 本機能のログを既存の一括抽出手段（`tasks-count:` prefix による grep）で取得できる形式で出力する

### NFR 3: 性能・コスト

1. The tasks-count gate shall 分割案の生成に追加の LLM 実行（Claude の追加起動）を発生させない
2. Where gate が有効であるとき, the tasks-count gate shall 1 Issue の escalate あたり本機能に起因する GitHub API 呼び出しを 2 回以下（既投稿確認 1 回 + コメント投稿 1 回）に抑える
3. Where gate が無効であるとき, the tasks-count gate shall 本機能に起因する GitHub API 呼び出しを 0 回とする
4. The 分割案コメント本文 shall GitHub のコメント本文長上限（65,536 文字）に対して 60,000 文字を超えない
5. The 各子 Issue 案のタイトル案 shall 120 文字以内に収まる
6. Where gate が有効であるとき, the tasks-count gate shall 分割案の生成による design 分岐の実行時間の増分を 1 秒以内に収める

### NFR 4: セキュリティ（未信頼入力の取り扱い）

1. The tasks-count gate shall ブランチ上の `tasks.md` の内容を未信頼入力として扱い、検証なしにコマンドとして解釈・実行しない
2. If タスク要約に HTML コメント記法または本機能のマーカーと同一の文字列が含まれるとき, the tasks-count gate shall 冪等判定を誤らせない形で当該文字列を無害化する
3. The tasks-count gate shall Issue 番号を数値として検証したうえで `#N` 参照記法の構成に用いる
4. The tasks-count gate shall コメント本文に含める起票コマンドの雛形を人間が確認して実行する提示に留め、watcher 自身が実行しない

## Out of Scope

- **子 Issue の自動起票**（`gh issue create` 相当の実行）。本 Issue は提案コメントの投稿までとし、起票は人間が行う
- **Triage 時点（`tasks.md` 確定前）の事前分割判定**。Issue 本文だけでは精度が低いため対象外
- **既存 tasks-count gate 挙動の変更**（escalate 閾値・レンジ境界・`needs-decisions` 付与・警告レンジ 8〜10 件の挙動・既存 escalation コメント本文とマーカー文字列）
- **LLM によるタイトル案生成**（将来の opt-in 拡張。本 Issue は bash による機械生成のみ）
- Architect 側の `design.md` `## Split Proposal` 生成ロジック（#131）の変更、および本機能との統合
- 本機能導入前に escalate 済みの Issue への遡及投稿（retrofit）
- 分割案の承認・却下・反映状況を追跡する状態管理（専用ラベル / sticky comment / 本文編集等）
- 分割案に基づく `tasks.md` の自動書き換え・分割反映
- GitHub Actions 版 workflow への反映（tasks-count gate 相当の hook を持たないため対象外）
- `size:*` ラベル（#507）や Developer モデル解決（#508）との連動・分割案への反映
- module 名・関数名・関数 prefix・コメント本文の具体テンプレート文字列・パース実装方式・データ構造（design.md の領分）

## Open Questions（確認事項）

- **タスク群を統合する条件の確定**: Issue 本文の実装メモは「`_Depends:_` で強結合なタスク群は同一案にまとめる」とするが「強結合」の定義が無い。本書は検証可能性のため Requirement 3.4 で **相互依存（依存が循環する関係）のみを統合対象**とする決定論的規則を暫定採用した。一方向の依存連鎖（1 → 2 → 3）も統合対象に含めるかは運用判断であり、含める場合は分割案の件数が大きく減るため要件更新が必要。
- **投稿するコメントの単位**: 既存 escalation コメントへの統合（1 コメント）か独立コメントかは Issue 本文で設計判断に委ねられている。本書は冪等マーカーの独立性（Requirement 5.3）のみを規定し、コメントの物理的な単位は規定していない。統合方式を採る場合、Requirement 6.4（既存 escalation コメント本文を変更しない）との整合を design 段階で確認する必要がある。
- **タイトル案の生成方式と長さ上限**: 本書は NFR 3.5 で 120 文字以内を暫定採用した。最上位タスク行の要約文をどこまで加工するか（記号除去 / 先頭 N 文字の切り詰め / 末尾省略記号）は未確定で、値が変わる場合は NFR 3.5 のみ差し替えれば他 AC は不変。
- **`_Requirements:_` numeric ID を子 Issue 案に含めるか**: Architect 側の `## Split Proposal` テンプレ（`architect.md`）は「対応 requirement」を含むが、Issue #509 本文の必須項目には含まれていない。含めると起票後のトレーサビリティが上がるため、Requirement 4 への AC 追加要否を人間判断に委ねる。
- **警告レンジ（8〜10 件）での分割案提示ニーズ**: 本書は Issue 本文に従い escalate のみを対象とした（Requirement 2.2）。warn レンジでも案が欲しいという運用要求が出た場合は gate 粒度を含めて再検討が必要。
- **gate 名称の最終確定**: 本書は Issue 本文の記載どおり `TC_SPLIT_PROPOSAL_ENABLED` を採用した。既存 tasks-count gate 系 env が `TC_` prefix で統一されているため整合するが、命名変更が入る場合は Requirement 1.1〜1.3 と Requirement 7.1 の文字列のみ差し替えれば他 AC は不変。
- **コメント長上限に達した場合の縮退挙動**: NFR 3.4 の 60,000 文字上限に接触するケース（極端に多い最上位タスク / 長大なタスク要約）で、案を省略するか本文を切り詰めるかは未確定。実運用では 11〜20 件程度が想定され接触可能性は低いと判断し、本書では規定していない。

---

## 自己レビュー結果（要件レビューゲート）

- **Mechanical Checks**: 全要件見出しが numeric ID（Requirement 1〜8 / NFR 1〜4）。各要件に EARS 形式 AC（`When` / `If` / `While` / `Where` / `The <subject> shall`）が 1 件以上存在。AC 本文には env var 名・canonical 記法キー・ラベル名という外部契約と、`tasks.md` のアノテーション記法（`_Depends:_` / checkbox 表記）という Architect 成果物の既存仕様のみを含め、module 名・関数名・関数 prefix・regex・jq 表現等の実装語彙は混入させていない。
- **EARS・テスト可能性**: 全 AC が observable / testable。曖昧語は具体化済み（「強結合」→ 依存が循環する関係、GitHub API 呼び出し 2 回以下 / 0 回、コメント本文 60,000 文字以内、タイトル案 120 文字以内、実行時間増分 1 秒以内、テスト 5 ケース）。
- **スコープ・カバレッジ**: Issue 本文の受入基準ドラフト 1.1〜3.2 を Requirement 1〜8 に対応付けた（1.1→Req 2.1 / 1.2→Req 4.1〜4.4 / 1.3→Req 4.5 / 1.4→Req 4.9 + Out of Scope / 1.5→Req 5 / 2.1→Req 1 + NFR 1 / 2.2→Req 6.2〜6.4 / 2.3→Req 6.5・6.6 / 3.1→Req 7 / 3.2→Req 8）。PM として (a) 投稿トリガの境界（warn / normal / タスク 0 件 / gate 従属関係）、(b) グルーピングの決定論性と網羅性（Req 3.6 / 3.7）、(c) 未起票子 Issue の `Depends on:` 参照表現（Req 4.6）、(d) コメント履歴取得失敗時の安全側（Req 5.6）、(e) 可観測性・性能・セキュリティ NFR を補完した。
- **既存整合**: 既存 tasks-count gate の 3 段階レンジ・冪等マーカー方式・fail-open 方針、`.claude/rules/issue-dependency.md` の canonical 記法と `Blocks:` 非採用方針、`.claude/rules/design-review-gate.md` を正準とする最上位タスク計数規約、`.claude/rules/tasks-generation.md` の `_Depends:_` アノテーション規約、README のオプション機能一覧（opt-in 節）の記載フォーマット、#507 で確立した「既定 false / `true` 厳密一致 / 不正値は安全側」という gate 正規化慣習と矛盾しないことを確認した。
- 残存する曖昧性は Open Questions に暫定採用値付きで列挙。レビューは 2 パスで確定。
