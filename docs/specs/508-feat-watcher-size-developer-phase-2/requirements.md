# Requirements Document

## Introduction

idd-claude の Developer 実行は現在すべての Issue で単一の `DEV_MODEL` を使うため、軽微な Issue でも
最上位モデルの quota / コストを消費する。Phase 1（#507）で Triage の変更規模判定が `size:small` /
`size:medium` / `size:large` ラベルとして Issue に永続化されたため、本 Phase 2 では **そのラベルを
読んで当該 Issue の Developer 実行モデルを決める**。既定挙動（`DEV_MODEL` 一本）は完全に温存し、
`MODEL_ROUTING_ENABLED=true` かつ size 別モデル設定の明示という **二重 opt-in** が揃ったときにのみ
モデルが変わる。判定結果を使った子 Issue 分割提案（Phase 3 / #509）は本書の対象外。

## 関連

- Depends on: #507
- Sibling: #509
- Related: #328

## 用語と subject の定義

本書の AC で用いる subject は以下の論理的な責務を指す。module 名・関数名・関数 prefix・
ファイル分割は `design.md` の領分であり、本書では規定しない。

| subject | 指すもの |
|---|---|
| the Model Router | size 値と設定値からモデル ID を決める **解決規則そのもの**（副作用を持たない） |
| the Slot Runner | 1 Issue を 1 slot（サブシェル）で処理する watcher の実行単位 |
| the watcher | 設定値の宣言・正規化を含む watcher 全体 |
| the README | 運用者向け主要ドキュメント |

## Requirements

### Requirement 1: size 値から Developer モデル ID を解決する規則

**Objective:** As a watcher 運用者, I want size 値に対する Developer モデル ID の解決規則が一意に定まること, so that どの Issue でどのモデルが使われるかを設定値だけから予測できる

#### Acceptance Criteria

1. When size 値が `small` であり `DEV_MODEL_SMALL` が非空であるとき, the Model Router shall `DEV_MODEL_SMALL` の値を解決結果として返す
2. When size 値が `medium` であり `DEV_MODEL_MEDIUM` が非空であるとき, the Model Router shall `DEV_MODEL_MEDIUM` の値を解決結果として返す
3. When size 値が `large` であるとき, the Model Router shall `DEV_MODEL` の値を解決結果として返す
4. If size 値が許可値（`small` / `medium` / `large`）以外・空文字・未指定のいずれかであるとき, the Model Router shall `DEV_MODEL` の値を解決結果として返す（fail-safe）
5. If size 値に対応する設定（`small` に対する `DEV_MODEL_SMALL` / `medium` に対する `DEV_MODEL_MEDIUM`）が未設定または空文字であるとき, the Model Router shall `DEV_MODEL` の値を解決結果として返す
6. The Model Router shall 設定された値を許可値リストとの照合・変換・補完のいずれも行わずそのまま解決結果として返す（モデル ID の許可値リストを持たない）
7. The Model Router shall 解決処理を副作用なし（GitHub API 呼び出し / ラベル変更 / ファイル書き込み / 呼び出し元の状態変更のいずれも伴わない）で行い、解決結果のみを出力する
8. The Model Router shall 同一の入力（size 値 + `DEV_MODEL` / `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` の値）に対して常に同一の解決結果を返す

### Requirement 2: size 別モデル設定の追加と既定値

**Objective:** As a watcher 運用者, I want size 別モデルを設定値で明示指定できること, so that gate を有効化しただけでモデルが黙って下がる事故を避けられる

#### Acceptance Criteria

1. The watcher shall `DEV_MODEL_SMALL` と `DEV_MODEL_MEDIUM` の 2 つの設定値を提供し、いずれも既定値を空文字とする
2. The watcher shall `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` の既定値として具体的なモデル ID を埋め込まない
3. Where `MODEL_ROUTING_ENABLED` が有効であり、かつ `DEV_MODEL_SMALL` と `DEV_MODEL_MEDIUM` がいずれも未設定または空文字であるとき, the Slot Runner shall すべての Issue で `DEV_MODEL` を適用する（gate 単独では挙動が変わらない二重 opt-in）
4. The watcher shall `DEV_MODEL` の既定値・意味・上書き方法のいずれも変更しない
5. The watcher shall 本要件で `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` 以外の新規設定値を追加しない
6. The watcher shall 既存の設定値名（`DEV_MODEL` / `TRIAGE_MODEL` / `REVIEWER_MODEL` / `PJM_MODEL` / `PR_ITERATION_DEV_MODEL` / `FAILED_RECOVERY_DEV_MODEL` / `MODEL_ROUTING_ENABLED` 等）の名称・既定値・解決順序のいずれも変更しない

### Requirement 3: slot での size ラベル読み取りとモデル適用

**Objective:** As a watcher 運用者, I want slot が当該 Issue の size ラベルに応じた Developer モデルで実装を進めること, so that 小規模 Issue の quota / コストを節約できる

#### Acceptance Criteria

1. While `MODEL_ROUTING_ENABLED` が有効であるとき, when slot が 1 件の Issue の処理を開始したとき, the Slot Runner shall 当該 slot が起動時点で取得済みの Issue ラベル集合から size 値を読み取り、解決結果を当該 Issue の Developer 実行に適用する
2. The Slot Runner shall ラベル名が `^size:(small|medium|large)$` に厳密一致する場合に限り、そのラベルから size 値を切り出して使用する
3. If `size:` prefix を持つラベルが 1 つも存在しないとき, the Slot Runner shall `DEV_MODEL` を適用する
4. If `size:` prefix を持つラベルが 2 つ以上存在するとき, the Slot Runner shall いずれの値も採用せず `DEV_MODEL` を適用する（fail-safe）
5. If `size:` prefix を持つラベルが 1 つ存在するが厳密一致に失敗する（`size:huge` / `size:Small` / 前後に空白を含む 等）とき, the Slot Runner shall `DEV_MODEL` を適用する（fail-safe）
6. When モデル解決を適用したとき, the Slot Runner shall 当該 slot 内の Developer 実行（design セッション / 実装 Stage 群 / per-task ループを含む）すべてに同一のモデル ID を一貫して適用する
7. The Slot Runner shall 解決結果を当該 slot のサブシェル境界内に閉じ、他 slot および親プロセスの Developer モデル設定へ伝播させない
8. The Slot Runner shall Triage / Reviewer / PjM / Architect 専用モデル設定に本機能起因の変更を与えない
9. The watcher shall 本機能に起因して slot 外プロセッサ（PR Iteration / Failed Recovery 等）が用いるモデル設定を変更しない

### Requirement 4: 適用タイミングと既知の制約

**Objective:** As a watcher 運用者, I want モデル解決がいつ効くかが明確に定義されていること, so that 「gate を有効にしたのにモデルが変わらない」ケースを不具合と誤認しない

#### Acceptance Criteria

1. The Slot Runner shall モデル解決を 1 Issue の 1 slot 実行につき 1 回だけ、当該 slot 起動時点のラベル集合に基づいて行う
2. While 同一 slot 実行内で Triage が size ラベルを新規付与する経路であるとき, the Slot Runner shall 当該実行では `DEV_MODEL` を適用する（slot 起動時点のラベル集合に当該ラベルが含まれないため）
3. The Slot Runner shall Triage 実行後にモデル解決を再実行しない
4. When 同一 Issue が次サイクル以降（impl-resume / 再 pickup）で slot 実行されたとき, the Slot Runner shall 既に付与済みの size ラベルに基づく解決結果を適用する
5. Where 人間が事前に size ラベルを付与した Issue が処理されるとき, the Slot Runner shall 初回の slot 実行からモデル解決を適用する
6. Where `skip-triage` ラベルにより Triage を実行しない経路で Issue が処理されるとき, the Slot Runner shall 既存の size ラベルに基づく解決結果を適用する

> **Note（AC 4.2 は意図された既知の制約）**: 新規 Issue が同一 slot 実行内で「Triage → size ラベル
> 付与 → 実装」と進む経路では、slot 起動時点のラベルスナップショットに `size:*` が含まれないため
> `DEV_MODEL` へ fallback する。本 Phase では **slot 起動時点の 1 回解決のみ**をスコープとし、
> Triage 後の再解決は行わない（Out of Scope）。したがって本機能が実際に効くのは (a) 人間が事前に
> size ラベルを貼った Issue、(b) `skip-triage` 経路、(c) impl-resume / 再 pickup サイクルである。
> この方針の妥当性は Open Questions に確認事項として残す。

### Requirement 5: opt-in gate と gate 無効時の完全 no-op

**Objective:** As a watcher 運用者, I want 未設定環境で本機能導入前と完全に同一の挙動が保たれること, so that 既存 consumer 環境へ無告知の影響が及ばない

#### Acceptance Criteria

1. The watcher shall モデルルーティング機能 family を単一の gate `MODEL_ROUTING_ENABLED` で制御し、本 Phase 用の追加 gate を設けない
2. While gate が無効であるとき, the Slot Runner shall size ラベルの読み取りとモデル解決のいずれも行わず `DEV_MODEL` をそのまま適用する
3. While gate が無効であるとき, the Slot Runner shall 本機能に起因するログを 1 行も出力しない
4. If `MODEL_ROUTING_ENABLED` に `true` 以外の値（未設定 / 空文字 / `false` / `off` / `True` / `1` / typo）が与えられたとき, the watcher shall 当該 gate を安全側（無効）へ正規化する
5. The watcher shall gate の有効・無効いずれの場合も、本機能に起因して既存のラベル遷移契約・exit code の意味・ログ出力先・cron 登録文字列を変更しない
6. If モデル解決処理が想定外の状態（設定値の読み取り不能等）に陥ったとき, the Slot Runner shall `DEV_MODEL` を適用して当該 Issue の処理を継続する（fail-open）

### Requirement 6: 解決結果の可観測性

**Objective:** As a watcher 運用者, I want どの Issue にどのモデルが適用されたかがログから追えること, so that コスト削減効果と誤適用を事後に検証できる

#### Acceptance Criteria

1. When gate 有効下でモデル解決を実行したとき, the Slot Runner shall Issue 番号・採用した size 値・適用した Developer モデル ID の 3 項目を含む 1 行のログを出力する
2. When size ラベル不在・複数付与・不正値のいずれかにより `DEV_MODEL` へ fallback したとき, the Slot Runner shall fallback したことを判別できる 1 行のログを出力する
3. The Slot Runner shall 上記ログを既存 processor 系ログと同一の出力先（cron ログ経路）へ書き出す
4. The Slot Runner shall 本機能に起因する分岐を silent fail させない（すべての分岐でログ 1 行を残す。ただし gate 無効時は AC 5.3 を優先し無出力とする）

### Requirement 7: 運用ドキュメントの更新

**Objective:** As a watcher 運用者, I want 新しい設定値と有効化条件が README から読み取れること, so that 実装を読まずに安全に導入判断できる

#### Acceptance Criteria

1. The README shall `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` の意味・既定値（空）・設定方法をオプション機能一覧に含める
2. The README shall gate 有効化と size 別モデル設定の両方が揃って初めてモデルが変わる二重 opt-in の挙動を記述する
3. The README shall モデル解決が slot 起動時点のラベルに基づく 1 回解決であること、および初回 Triage 経路では `DEV_MODEL` へ fallback する既知の制約（Requirement 4）を記述する
4. The README shall 本機能の適用対象外（Reviewer / PjM / Architect 専用モデル、slot 外プロセッサのモデル）を明記する
5. The README shall size 値ごとの解決結果（`small` / `medium` / `large` / ラベルなし / 不正値）を一覧で示す
6. The repository shall 上記ドキュメント更新を本機能の実装と同一 PR で行う

### Requirement 8: 検証可能性（受け入れ確認手段）

**Objective:** As a reviewer, I want 本機能の受け入れ確認手段が事前に定義されていること, so that PR レビュー時に AC 充足を機械的に確認できる

#### Acceptance Criteria

1. The 変更後の bash スクリプト shall `shellcheck` を警告ゼロで通過する
2. The 変更後の bash スクリプト shall `bash -n` の構文検査を通過する
3. The repository shall 本機能で追加された解決規則に対する近接テストを `local-watcher/test/` 配下の既存命名規約に沿って追加する
4. The 近接テスト shall 解決規則について「`small` / `medium` / `large` の 3 値 × 対応設定あり / なし」「許可値以外」「空文字」の各ケースを検証する
5. The 近接テスト shall slot 適用について「size ラベルなし」「`size:*` ラベル複数」「不正値ラベル」「gate 無効」の各ケースで `DEV_MODEL` が適用されることを検証する
6. The 近接テスト shall gate 無効時に本機能起因のログが 0 行であることを検証する
7. The 検証手順 shall 解決結果が当該 slot のサブシェル境界を越えて親プロセスへ伝播しないことの確認を含む

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While gate が無効であるとき, the watcher shall 本機能導入前と同一のログ出力・ラベル遷移・exit code の意味を保つ
2. The watcher shall 新規設定値を未設定のまま既存 consumer 環境が動作したときに、本機能導入前と同一の外部挙動を提供する
3. The watcher shall 本機能に起因して Developer 実行以外の Stage（Triage / Reviewer / PjM / design 以外の外部プロセッサ）のモデル選択契約を変更しない

### NFR 2: 性能・コスト

1. While gate が無効であるとき, the Slot Runner shall 本機能に起因する外部コマンド呼び出しを 0 回、ログ出力を 0 行とする
2. Where gate が有効であるとき, the Slot Runner shall 本機能に起因する GitHub API 呼び出しを 0 回とする（slot 起動時点で取得済みのラベル集合のみを用いる）
3. The Slot Runner shall 本機能のために追加の LLM 実行（Claude の追加起動）を発生させない
4. The Slot Runner shall 1 Issue の 1 slot 実行あたり本機能に起因する解決処理を 1 回以下に抑える

### NFR 3: セキュリティ（未信頼入力の取り扱い）

1. The Slot Runner shall 未信頼入力である Issue ラベル名を、許可パターン（`^size:(small|medium|large)$`）との厳密一致検証を通過する前に外部コマンド引数・パス・解決規則の入力として使用しない
2. When 未信頼値を外部コマンドへ渡すとき, the Slot Runner shall 変数展開をクォートし、オプション解釈の打ち切りを行う
3. The Slot Runner shall 解決したモデル ID をモデル指定とログ出力以外の用途（パス構成 / ラベル名構成 / コマンド組み立て）に用いない
4. The repository shall `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM` に具体的なモデル ID をハードコードせず、運用者の明示設定にのみ依存する

## Out of Scope

- **Triage 実行後のモデル再解決**（初回 Triage で size ラベルが付いた直後の同一 slot 実行内で解決をやり直すこと）。本 Phase は slot 起動時点の 1 回解決のみ（Requirement 4 / Note 参照）
- Reviewer / PjM / Architect 専用モデル（`REVIEWER_MODEL` / `PJM_MODEL` 等）の size 連動 routing — Reviewer は品質ゲートのため上位モデルを維持する
- slot 外プロセッサ（`PR_ITERATION_DEV_MODEL` / `FAILED_RECOVERY_DEV_MODEL`）への波及 — 必要になれば将来 Issue
- Developer モデルを参照している既存の個別実行箇所（10 箇所以上）の書き換え — 本 Phase では一切変更しない
- `size:large` 専用の設定値（`DEV_MODEL_LARGE` 等）の追加 — `large` は `DEV_MODEL` を用いる（Requirement 1.3）
- Phase 1（#507）が担う size ラベルの判定・付与・冪等性ロジックの変更（`complexity` の判定基準、ラベル命名、labels script のプロビジョニング）
- Phase 3（#509）: tasks 件数超過時の子 Issue 分割案コメント投稿
- gate の分割（Phase 1 用 / Phase 2 用に別 gate を設けること）
- 既存 Issue への size ラベル遡及付与（retrofit）、および人間が誤付与したラベルの自動訂正
- モデル解決結果の Issue 上への永続化（コメント / 本文編集）— 本 Phase ではログ出力に留める
- コスト実測・quota 消費量のレポーティング / ダッシュボード化
- GitHub Actions 版 workflow への反映（slot 実行経路が存在しないため対象外）
- module 名・関数名・関数 prefix・解決処理の差し込み位置の具体設計・設定値の正規化実装方式（`design.md` の領分）

## Open Questions

- **適用タイミングのギャップを本 Phase で受容してよいか（最重要 / 要人間判断）**: Issue 本文は
  「slot 冒頭に差し込み」と指示しており、本書は Requirement 4 でそれに忠実に従った。その結果、
  新規 Issue が同一 slot 実行内で Triage → size ラベル付与 → 実装と進む経路（= 最も一般的な経路）
  では routing が効かず `DEV_MODEL` に fallback する。routing が実際に効くのは (a) 人間が事前に
  size ラベルを貼った Issue、(b) `skip-triage` 経路、(c) impl-resume / 再 pickup サイクルに限られる。
  この「初回 Triage 経路では効かない」挙動を **意図された既知の制約として受容する**か、それとも
  Triage 直後（Phase 1 のラベル付与直後）での再解決を別 Issue として起票するかは人間判断に委ねる。
  本書では前者を暫定採用し、後者を Out of Scope に置いた。
- **design セッションへの適用可否**: 解決結果は同一 slot 内の design セッションにも及ぶ。Phase 1 の
  判定基準では `needs_architect: true` が `size:large` に倒れるため実運用上は `DEV_MODEL` のままに
  なる想定だが、人間が `size:small` を手で貼った Issue が design 経路に入ると設計セッションが下位
  モデルで実行される。これを許容するか（許容しない場合は Requirement 3.6 の適用範囲を design 除外へ
  縮退させる必要があり、最小 diff 方針とトレードオフになる）。
- **`DEV_MODEL_LARGE` を将来追加するか**: 本 Phase では `large` を `DEV_MODEL` に固定した
  （Requirement 1.3 / Out of Scope）。将来 `large` だけ別モデルに振りたくなった場合の追加は additive
  で済むが、その時点で `DEV_MODEL` の位置づけ（既定値なのか `large` 専用なのか）を再定義する必要がある。
- **既定値を空にする判断の是非**: Issue 本文の「確認事項」に挙がっているとおり、`DEV_MODEL_SMALL` に
  下位モデル ID を env default で置く選択もあり得る。本書は「gate 有効化だけで silent にモデルが
  下がる事故を避ける」ため二重 opt-in（既定空）を採用した（Requirement 2.1 / 2.3）。
- **誤付与ラベルによる意図しない下位モデル固定の運用手順**: 人間が誤って `size:small` を貼った
  Issue は、ラベルを剥がすまで下位モデルで実装され続ける。Phase 1 README に記載済みの訂正手順
  （ラベルを剥がす → 次回 Triage で再付与）で十分か、Phase 2 固有の注意喚起を README に追記するかは
  Requirement 7.3 の記述粒度に影響する。
- **fallback 時のログ粒度**: Requirement 6.2 は「fallback したことを判別できる 1 行」を要求するが、
  gate 有効かつ size ラベル不在の Issue が大半を占める運用ではログノイズになり得る。fallback 時の
  ログを DEBUG 相当に落とす / 出力しない選択肢もあるが、本書は可観測性を優先して 1 行出力を採用した。

---

## 自己レビュー結果（要件レビューゲート）

- **Mechanical Checks**: 全要件見出しが numeric ID（Requirement 1〜8 / NFR 1〜3）。各要件に EARS 形式
  AC（`When` / `If` / `While` / `Where` / `The <subject> shall`）が 1 件以上存在。AC 本文には
  設定値名・ラベル名・ラベル許可パターンという **外部契約** のみを含め、module 名・関数名・関数
  prefix・差し込み行位置等の実装語彙は混入させていない（subject は「用語と subject の定義」節で
  論理責務として定義）。
- **EARS・テスト可能性**: 全 AC が observable / testable。数値は具体化済み（GitHub API 呼び出し
  0 回、ログ 0 行、解決処理 1 回以下、追加設定値 2 個、ラベル許可パターンの厳密一致）。
- **スコープ・カバレッジ**: Issue 本文の AC 案 1.1〜1.4 / 2.1〜2.5 / 3.1 をすべて対応付けたうえで、
  PM として (a) 二重 opt-in の明示（Req 2.3）、(b) 適用タイミングのギャップの要件化（Req 4 / Note）、
  (c) 複数 / 不正ラベルの fail-safe 細分（Req 3.4 / 3.5）、(d) 境界 AC（Req 3.8 / 3.9 = Reviewer・
  PjM・slot 外プロセッサ不変）、(e) fallback ログ（Req 6.2）、(f) 検証手段（Req 8）、(g) 性能・
  セキュリティ NFR を補完した。
- **既存整合**: Phase 1（#507）の gate 単一化方針（Req 3.6）、`= "true"` 厳密一致の正規化慣習、
  fail-safe / fail-open パターン、slot がサブシェルで起動され slot 内の設定変更が親へ伝播しない
  既存構造、`PJM_MODEL`（#328）の役割別モデル env 先例と矛盾しないことを確認した。
- **2 パス目の補正**: 初稿では可観測性を機能要件と NFR の双方に書いていたため、機能要件
  （Requirement 6）へ一本化し NFR 側の重複を削除した。また初稿の「Triage 直後に再解決する」記述を
  Issue 本文の指示（slot 冒頭差し込み）に合わせて削除し、Requirement 4 + Note + Open Questions
  （最重要項目）へ移送してスコープ拡大を防いだ。
- 残存する曖昧性は Open Questions に暫定採用値付きで列挙。レビューは 2 パスで確定。
