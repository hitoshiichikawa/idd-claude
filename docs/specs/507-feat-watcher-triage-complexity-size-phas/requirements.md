# Requirements Document

## Introduction

idd-claude の Developer stage は現在すべての Issue に対して単一の `DEV_MODEL` を使うため、軽微な
修正でも大型モデルを消費し、逆に過大な Issue でも分割誘導が働かない。Issue サイズに応じて
Developer モデルを選択・分割誘導するモデルルーティング構想のうち、本書は **Phase 1（サイズ判定と
永続化）のみ** を定義する。Triage は既に軽量モデルで Issue 全文を読み `status` / `needs_architect` /
`edit_paths` を JSON で返しているため、ここに additive フィールドを 1 つ足すだけでサイズ判定を得られる。
判定結果をラベルとして Issue に永続化する理由は 2 つで、(a) impl-resume / iteration など Triage を
再実行しないサイクルでも sticky に参照できる置き場が必要なこと、(b) 人間が事前にラベルを貼ることで
Triage 判定を override できる運用ゲートになること（`auto-dev` ラベル運用と同型）である。判定結果を
使ったモデル解決（Phase 2 / #508）と分割提案（Phase 3 / #509）は本書の対象外。

## 関連

- Sibling: #508 #509
- Related: #18 #147 #216

## Requirements

### Requirement 1: Triage による Issue サイズ判定

**Objective:** As a watcher 運用者, I want Triage が Issue の変更規模を 3 段階で判定して出力すること, so that 後続フェーズが Issue 規模に応じた処理を機械的に選択できる

#### Acceptance Criteria

1. When Triage が実行されたとき, the Triage Agent shall 出力 JSON に `complexity` フィールドを含め、その値を `small` / `medium` / `large` のいずれか 1 つとする
2. When Triage が `complexity` を出力するとき, the Triage Agent shall 判定根拠を 1〜2 行の `complexity_reason` として同じ出力に含める
3. When 対象 Issue が単一〜少数ファイルの軽微な変更（既存関数内のロジック改善 / 文言変更 / テスト・ドキュメント追加のみ）に留まるとき, the Triage Agent shall `complexity` を `small` と判定する
4. When 対象 Issue が数ファイルにまたがるが設計判断が自明な変更（新規ヘルパー追加程度）であるとき, the Triage Agent shall `complexity` を `medium` と判定する
5. When 対象 Issue が複数モジュール横断・新規外部連携・永続構造やスキーマの変更のいずれかを含むとき, the Triage Agent shall `complexity` を `large` と判定する
6. Where Triage が `needs_architect` を `true` と判定したとき, the Triage Agent shall `complexity` を `large` と判定する
7. If `complexity` の判定が 2 段階の境界にあり確信を持てないとき, the Triage Agent shall より大きい側の値を選択する
8. The Triage Agent shall `complexity` を「変更規模」の観点で判定し、`needs_architect` の判定基準・値・意味を変更しない

### Requirement 2: Triage 出力スキーマの additive 拡張と後方互換

**Objective:** As a watcher 運用者, I want Triage 出力スキーマの拡張が additive に留まること, so that 既存の Triage 消費経路と旧スキーマで生成された結果が影響を受けない

#### Acceptance Criteria

1. The Triage 出力スキーマ変更は additive のみとし、既存 6 keys（`status` / `needs_architect` / `architect_reason` / `rationale` / `decisions` / `edit_paths`）の位置・型・意味のいずれも変更しない
2. The Triage Agent shall 本要件で `complexity` / `complexity_reason` 以外の新規フィールドを追加しない
3. If Triage 結果に `complexity` が存在しないとき（旧テンプレートで生成された結果等）, the watcher shall 当該値を「値なし」として扱い、エラーを発生させずに既存処理を継続する
4. If Triage 結果 JSON の読み取り・解析に失敗したとき, the watcher shall 本機能に起因して Triage 全体の成功／失敗判定を変更しない
5. The watcher shall `complexity` の有無・値によって Triage 後のモード判定（design / impl / impl-resume）および needs-decisions 経路の分岐を変更しない

### Requirement 3: opt-in gate と既定無効

**Objective:** As a watcher 運用者, I want 本機能を環境変数で明示的に有効化できること, so that 未設定環境では本機能導入前と完全に同一の挙動が保たれる

#### Acceptance Criteria

1. The watcher shall `MODEL_ROUTING_ENABLED` の既定値を無効として扱い、当該変数が宣言されていない環境でも無効とする
2. Where `MODEL_ROUTING_ENABLED` がリテラル文字列 `true` に設定されているとき, the watcher shall size ラベルの永続化を実行する
3. If `MODEL_ROUTING_ENABLED` に `true` 以外の値（空文字列 / `false` / `off` / `True` / `1` / typo）が与えられたとき, the watcher shall 当該 gate を安全側（無効）へ正規化する
4. While gate が無効であるとき, the watcher shall ラベルの読み取り・付与および本機能に起因する GitHub API 呼び出しを一切行わない
5. While gate が無効であるとき, the Triage Agent shall `complexity` / `complexity_reason` の出力を継続する（gate は watcher 側の永続化のみを制御する）
6. The watcher shall モデルルーティング機能 family（本 Phase のラベル永続化および後続 Phase のモデル解決）を単一の gate で制御し、Phase 別の追加 gate を設けない

### Requirement 4: size ラベルによる永続化

**Objective:** As a watcher 運用者, I want Triage の判定結果が Issue のラベルとして永続化されること, so that Triage を再実行しないサイクルでも判定結果を参照でき、人間が override できる

#### Acceptance Criteria

1. While `MODEL_ROUTING_ENABLED` が有効であり, when Triage が許可値の `complexity` を返したとき, the watcher shall 対応する `size:<complexity>` ラベルを当該 Issue に付与する
2. If 当該 Issue に `size:` prefix を持つラベルが既に 1 つ以上付与されているとき, the watcher shall ラベルの追加・付け替え・削除のいずれも行わない
3. The watcher shall 人間が付与した size ラベルと過去の Triage が付与した size ラベルを区別せず、先に存在するラベルを優先する
4. When 同一 Issue に対して Triage が再実行されたとき, the watcher shall size ラベルが重複する状態も複数の `size:*` ラベルが併存する状態も新たに生じさせない
5. Where `skip-triage` ラベルにより Triage が実行されない経路で Issue が処理されるとき, the watcher shall size ラベルを付与しない
6. Where 既存 spec ディレクトリを持つ Issue（Triage を再実行しない resume 経路）が処理されるとき, the watcher shall 既存の size ラベルを変更しない
7. When size ラベルの付与をスキップしたとき, the watcher shall スキップ理由を判別できるログを出力する

### Requirement 5: 不正値・失敗時の fail-safe / fail-open

**Objective:** As a watcher 運用者, I want 判定値の不正や GitHub 操作の失敗が既存パイプラインを止めないこと, so that 補助機能の失敗で Issue 処理全体が失敗しない

#### Acceptance Criteria

1. If `complexity` が欠落・`null`・文字列以外・許可値（`small` / `medium` / `large`）以外のいずれかであるとき, the watcher shall ラベルを付与せず WARN ログのみを出力して処理を継続する
2. The watcher shall `complexity` の値を使用直前に許可値集合との厳密一致で検証したうえでラベル名の構成に用いる
3. If size ラベル付与の GitHub 操作が失敗したとき（API 不達 / レート制限 / 権限不足 / 対象ラベル未定義等）, the watcher shall WARN ログを残し、当該サイクルの処理を中断せず後続処理を継続する
4. If 既存ラベル一覧の取得に失敗したとき, the watcher shall size ラベルを付与せず WARN ログを出力する（誤った上書きを避ける安全側）
5. The watcher shall 本機能に起因するいかなる失敗でも既存のラベル遷移契約（`claude-claimed` / `claude-picked-up` / `needs-decisions` / `claude-failed` 等）を変更しない
6. The watcher shall 本機能に起因する失敗を silent fail させない

### Requirement 6: ラベル定義のプロビジョニング

**Objective:** As a repository 管理者, I want size ラベルが標準ラベル定義に含まれること, so that consumer repo でも同じ手順でラベルを揃えられる

#### Acceptance Criteria

1. The label provisioning script shall `size:small` / `size:medium` / `size:large` の 3 ラベルを定義に含める
2. The label provisioning script shall 既存ラベルの name / color / description のいずれも変更せず、既存ラベルの削除・改名も行わない
3. When 当該 3 ラベルが既に存在する repository でスクリプトが再実行されたとき, the label provisioning script shall 失敗せず既存ラベルを破壊的に変更しない
4. The 追加ラベルの description shall 適用先 prefix `【Issue 用】` を持ち、100 文字以内である
5. The 追加ラベルの color shall 既存エントリと同じ 6 桁 hex 表記の規約に従う

> **Note（AC 6.4 の適用範囲 / 既存ドリフト前提）**: root 側のラベル定義スクリプトは #54 により
> 全エントリの description が `【Issue 用】` / `【PR 用】` prefix を持つが、repo-template 側には
> #54 が反映されておらず旧エントリ 11 件に prefix が無い（#18 以降に追加された新しいエントリ群
> には prefix がある）。本 Issue では **両系統で追加 3 行の文字列を完全に一致させること（parity）
> を優先**し、repo-template 側でも prefix ありで追加する方針を採る。その結果 repo-template 内で
> 「旧エントリのみ prefix なし」という内部不整合が残るが、これは本 Issue が持ち込んだものでは
> なく #54 の積み残しであり、是正には既存 description の書き換えが必要で AC 6.2 と矛盾するため
> 本 Issue では扱わない（Out of Scope）。

### Requirement 7: 二重管理の同期とドキュメント更新

**Objective:** As a repository 管理者, I want 追加分の配布物同期とドキュメント更新が同一 PR で完了すること, so that consumer repo も新ラベルを取得でき、README との乖離も発生しない

#### Acceptance Criteria

1. The repository shall 本 Issue で追加する `size:small` / `size:medium` / `size:large` の 3 エントリを、root と repo-template のラベル定義スクリプト双方へ同一文字列・同一相対位置で追加する（additive parity）
2. The repository shall 上記 3 エントリ以外の既存行の差分（#54 由来の既存ドリフト）を本 Issue では変更しない
3. The README shall `MODEL_ROUTING_ENABLED` の既定値・有効化方法・無効時の挙動をオプション機能一覧に含める
4. The README shall `size:small` / `size:medium` / `size:large` の意味と、既存ラベルが優先される人間 override 運用を記述する
5. The README shall 本機能で追加された module をディレクトリ構成の一覧に含める
6. The CLAUDE.md shall 本機能で追加された module の関数 prefix を prefix 表に含める
7. The repository shall 上記ドキュメント更新を本機能の実装と同一 PR で行う

> **Note（AC 7.1 が whole-file byte 一致ではない理由）**: 本 Issue 着手時点で root と
> repo-template のラベル定義スクリプトは既に byte 一致していない（#54 由来の既存ドリフト。
> 詳細は Requirement 6 の Note を参照）。whole-file 一致を AC にすると達成に既存 11 行の書き換えが
> 必要となり AC 6.2 と正面衝突し、1 PR = 1 Issue 原則にも反する。さらに、その AC が検証コマンド
> として実装されると正しい実装でも非 0 exit を返して false-fail する事故（#364 と同根）を招く。
> したがって本 Issue の同期義務は **追加 3 エントリの parity** に限定する。`.claude/agents` /
> `.claude/rules` の 2 系統は byte 一致が維持されており、本 Issue はそれらを変更しない。

### Requirement 8: 検証可能性（受け入れ確認手段）

**Objective:** As a reviewer, I want 本機能の受け入れ確認手段が事前に定義されていること, so that PR レビュー時に AC 充足を機械的に確認できる

#### Acceptance Criteria

1. The 変更後の bash スクリプト shall `shellcheck` を警告ゼロで通過する
2. The 変更後の bash スクリプト shall `bash -n` の構文検査を通過する
3. The repository shall 本機能で追加された関数に対する近接テストを `local-watcher/test/` 配下に既存命名規約で追加する
4. The 近接テスト shall 許可値 3 種の正常付与・`complexity` 欠落・不正値・既存 `size:*` ラベルあり・gate 無効の 5 ケースを検証する
5. When root と repo-template のラベル定義スクリプトから `size:` を含む行のみを抽出して比較したとき, the 抽出結果 shall 双方で同一の 3 行（`size:small` / `size:medium` / `size:large`）となる（既存行を含む whole-file 比較は検証条件としない）
6. The 検証手順 shall gate 有効かつ対象ラベル未作成の repository で「ラベル付与失敗 → WARN 出力 → 処理継続」となることの確認を含む

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While gate が無効であるとき, the watcher shall 本機能導入前と同一のログ出力・ラベル遷移・exit code の意味を保つ
2. The watcher shall 既存 env var 名・既存ラベル名・cron 登録文字列・ログ出力先のいずれも変更しない
3. The watcher shall 新規 env var を未設定のまま既存 consumer 環境が動作したときに、本機能導入前と同一の外部挙動を提供する

### NFR 2: 可観測性

1. When size ラベルを付与したとき, the watcher shall `[$REPO]` prefix・Issue 番号・確定した `complexity` 値を含む 1 行のログを出力する
2. When ラベル付与をスキップまたは失敗したとき, the watcher shall `[$REPO]` prefix・Issue 番号・理由を含む WARN 行を出力する
3. The watcher shall 上記ログを既存 processor 系ログと同一の出力先（cron ログ経路）へ書き出す

### NFR 3: 性能・コスト

1. Where gate が有効であるとき, the watcher shall 1 Issue の Triage あたり本機能に起因する GitHub API 呼び出しを 2 回以下（既存ラベル確認 1 回 + ラベル付与 1 回）に抑える
2. Where gate が無効であるとき, the watcher shall 本機能に起因する GitHub API 呼び出しを 0 回とする
3. The watcher shall 本機能のために追加の LLM 実行（Claude の追加起動）を発生させない
4. The Triage Agent shall `complexity` / `complexity_reason` の追加により Triage の turn 数上限（既定 15）を超過させない

### NFR 4: セキュリティ（未信頼入力の取り扱い）

1. The watcher shall LLM 出力である `complexity` を検証なしにラベル名・コマンド引数として使用しない
2. When 未信頼値を外部コマンドへ渡すとき, the watcher shall 変数展開をクォートし、オプション解釈の打ち切りを行う
3. The watcher shall `complexity_reason` をラベル名の構成に用いない

## Out of Scope

- Phase 2（#508）: size ラベルに基づく Developer モデル ID の解決と slot 実行経路への差し込み
- Phase 3（#509）: tasks-count-gate escalate 時の子 Issue 分割案コメント投稿
- slot 外プロセッサ（PR Iteration / Failed Recovery など）のモデル選択への波及
- **#54 由来の labels script 既存ドリフト（repo-template 側で旧エントリ 11 件の description に `【Issue 用】` / `【PR 用】` prefix が欠落している件、および root 側にのみ存在する #54 由来のコメント行）の是正 — 別 Issue で対応する**。本 Issue とは無関係の既存差分であり、是正には既存 description の書き換えが必要で Requirement 6.2 と矛盾する
- `complexity_reason` の Issue 上への永続化（sticky comment / Issue 本文編集等）。本 Phase ではログ出力に留める
- 既存 Issue（本機能導入前に処理済み）への size ラベル遡及付与（retrofit）
- 人間が size ラベルを付け替えた際の再判定・自動付け替え（Requirement 4.2 / 4.3 の裏返しとして行わない）
- Triage 出力スキーマの明示的バージョニング（additive 拡張と key 存在チェックによる graceful degrade で代替）
- GitHub Actions 版 workflow への反映（Triage 相当の処理が存在しないため対象外）
- module 名・関数名・関数 prefix・env 正規化の実装方式・ラベル読み取り経路の具体設計（design.md の領分）
- `size:*` 以外の新規ラベル追加、および既存ラベルの改名・削除
- サイズ判定の精度改善（過去 PR の diff 実績を用いた学習・キャリブレーション等）

## Open Questions

- **ラベル命名の最終確定**: 本書は Issue 本文の記載に従い `size:small` / `size:medium` / `size:large`（コロン namespace）を暫定採用した。既存ラベルはすべて kebab-case で、コロン namespace の先例が repo 内に無い点が論点。`size-small` 系に揃えても機能差はなく（prefix 一致判定はどちらでも可能）、決定が変わる場合は Requirement 4.1 / 6.1 / 7.1 / 8.5 のラベル文字列のみ差し替えれば他 AC は不変。人間 / レビュワー判断に委ねる。
- **gate 粒度の最終確定**: 本書は Phase 1 / Phase 2 共通の単一 gate（Requirement 3.6）を暫定採用した。「ラベルだけ運用してモデル解決は行わない」ニーズが実在するかは Phase 2 の fallback 設計（未設定時に既定モデルへ落ちる挙動）と併せて確定する必要がある。
- **repo-template 側ラベル定義スクリプトのドリフト是正 Issue を別途起票するか**: #54 の適用漏れにより repo-template の旧エントリ 11 件に description prefix が無い（Requirement 6 / 7 の Note 参照）。本 Issue では Out of Scope としたため、是正 Issue を起票するか当面放置するかは人間判断に委ねる（起票そのものは本 Issue の作業に含めない）。
- **境界判定の丸め方向**: Requirement 1.7 の「境界では大きい側へ倒す」は PM による補完（Issue 本文に明示なし）。過小評価による実装失敗コストと過大評価によるモデルコスト増のどちらを重く見るかは Phase 2 のコスト方針に依存し、逆転しうる。
- **`needs_architect: true` → `large` 固定の強度**: Issue 本文は「原則 large」と記載しているが、本書は検証可能性のため Requirement 1.6 で固定ルールとした。運用データで例外が観測された場合は要件を更新する。
- **誤付与時の運用手順**: 人間が誤った size ラベルを貼った場合の訂正手順（ラベルを剥がして次回 Triage で再付与させる）を README に明記するかは未確定。Requirement 7.4 の記述粒度に影響する。

---

## 自己レビュー結果（要件レビューゲート）

- **Mechanical Checks**: 全要件見出しが numeric ID（Requirement 1〜8 / NFR 1〜4）。各要件に EARS 形式 AC（`When` / `If` / `While` / `Where` / `The <subject> shall`）が 1 件以上存在。AC 本文には env var 名・ラベル名・Triage 出力フィールド名という外部契約のみを含め、module 名・関数名・関数 prefix・jq 表現等の実装語彙は混入させていない（Requirement 7.5 / 7.6 は「本機能で追加された module」と一般化）。
- **EARS・テスト可能性**: 全 AC が observable / testable。数値は具体化済み（GitHub API 呼び出し 2 回以下 / 0 回、description 100 文字以内、検証 5 ケース、turn 上限 15）。
- **スコープ・カバレッジ**: Issue 本文の受入基準 1.1〜4.3 を Requirement 1〜7 に対応付けたうえで、PM として (a) 旧スキーマ・parse 失敗時の graceful degrade（Req 2.3 / 2.4）、(b) gate 不正値の安全側正規化（Req 3.3）、(c) 再 Triage 時の冪等性（Req 4.4）、(d) `skip-triage` / resume 経路の非付与（Req 4.5 / 4.6）、(e) ラベル取得失敗時の安全側（Req 5.4）、(f) 検証手段（Req 8）、(g) 可観測性・性能・セキュリティ NFR を補完した。
- **既存整合**: #18（Phase E）の additive 拡張・sticky 永続化・fail-open パターン、`PATH_OVERLAP_CHECK` の既定 off / `true` 厳密一致という正規化慣習、ラベル定義スクリプトの冪等プロビジョニング、`skip-triage` / impl-resume で Triage を実行しない既存分岐と矛盾しないことを確認した。
- **同期要件の実測補正（レビュー 2 パス目）**: 当初 Requirement 7.1 / 8.5 を「ラベル定義スクリプトの whole-file byte 一致」と記述していたが、root と repo-template の実測比較により #54 由来の既存ドリフト（旧エントリ 11 件の description prefix 欠落 + root 側コメント 4 行）が判明した。whole-file 一致は Requirement 6.2（既存 description を変更しない）と矛盾し、1 PR = 1 Issue 原則にも反し、さらに検証コマンドとして実装された場合に正しい実装でも非 0 exit で false-fail する危険があるため、**追加 3 エントリの additive parity** へ縮退させた（Requirement 7.1 / 7.2 / 8.5 + Requirement 6・7 の Note）。既存ドリフトは Out of Scope と Open Questions に移送した。
- 残存する曖昧性は Open Questions に暫定採用値付きで列挙。レビューは 2 パスで確定。
