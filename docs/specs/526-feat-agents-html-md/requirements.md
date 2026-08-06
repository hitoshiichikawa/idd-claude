# Requirements Document

## Introduction

idd-claude の人間レビュー用成果物（`docs/specs/<番号>-<slug>/` 配下の requirements.md /
design.md / tasks.md 等）は markdown で保守されるが、生ソースはレンダリング済み HTML より
人間の認知負荷が高い。一方で agent パイプライン（PM → Architect → Developer → Reviewer）と
watcher の機械ゲートは markdown を契約フォーマットとして厳格に依存している。本機能は markdown を
正準（source of truth）に据えたまま、opt-in 有効化時に **並行して .html を派生生成**することで、
人間レビュワーの可読性のみを底上げする。2026-06-02 に検討された「.md → .html 置換案」は棚上げ済み
であり（GitHub PR が任意 .html を描画しない / tasks.md 等が機械ゲートの regex・awk 契約入力である /
メタデータ解釈は既存の型付きアノテーション DSL で取得済み、の 3 点が理由）、本 spec は「置換」では
なく「並行生成」に限定して当該懸念を構造的に回避する。

## Requirements

### Requirement 1: opt-in 有効化と既定 OFF（no-op 後方互換）

**Objective:** As an idd-claude operator, I want HTML 並行生成を env var による opt-in で有効化したい,
so that 未有効化リポジトリには一切影響を与えず段階的に導入できる

#### Acceptance Criteria

1. While 本機能の opt-in gate 用 env var（本 spec では仮称 `SPEC_HTML_ENABLED` と表記し、正式名は
   design で確定）が `true` と完全一致しない（未設定 / 空文字 / `false` / `0` / `True` 等の typo を
   含む）状態である間, the HTML 並行生成機能 shall .html を一切生成せず、本機能導入前と観測可能挙動が
   等価な経路へ進む
2. While 上記 env var が `true` と完全一致している状態である間, the HTML 並行生成機能 shall
   Requirement 2 以降で定める .html 並行生成を実行する
3. If 上記 env var に `true` 以外の任意値が設定された状態で起動した場合, the HTML 並行生成機能 shall
   値を安全側（無効）に正規化し、スキップ理由を 1 行ログに記録する
4. When 本機能が無効（既定）で watcher / 各エージェントが動作する場合, the HTML 並行生成機能 shall
   既存の処理順序・生成成果物・ログ出力先に副作用を与えない

### Requirement 2: 対象成果物への .html 並行生成

**Objective:** As a 人間レビュワー, I want 人間レビュー用 markdown 成果物に対応する HTML を並行生成して
ほしい, so that 生タグではなくレンダリング済みの形で認知負荷を下げて確認できる

#### Acceptance Criteria

1. While 本機能が有効化されている状態である間, when 対象成果物の .md が新規生成された場合, the HTML
   並行生成機能 shall 当該 .md に対応する .html を生成する
2. The HTML 並行生成機能 shall 並行生成の必須対象を、対象 spec ディレクトリ
   `docs/specs/<番号>-<slug>/` 配下の `requirements.md` / `design.md` / `tasks.md` とする
3. While 本機能が有効化されている状態である間, the HTML 並行生成機能 should 追加対象として同一 spec
   ディレクトリ配下の `impl-notes.md` / `review-notes.md` の .html も生成する（対象集合の最終確定は
   Open Questions に従う）
4. The HTML 並行生成機能 shall 生成した .html を対応する .md と同一ディレクトリに、人間が対応関係を
   識別できる命名で配置する
5. The HTML 並行生成機能 shall 生成する .html を、対応 .md の内容（見出し / リスト / コードブロック /
   テーブル等）を反映した人間可読なレンダリング結果とする

### Requirement 3: .md 正準維持と機械契約の .html 非依存

**Objective:** As an idd-claude operator, I want すべての機械ゲートとエージェント連携が .md のみを契約
入力とすることを保証したい, so that HTML 導入で既存パイプラインの契約が壊れない

#### Acceptance Criteria

1. The HTML 並行生成機能 shall 対象 .md を正準（source of truth）として維持し、.md を .html で
   置換しない
2. The watcher 機械ゲート shall .html の有無・内容に依存せず、契約入力を .md に限定する（tasks.md の
   checkbox 判定 / Tasks Count Gate / stage-a-verify センチネル / Reviewer の `RESULT:` 行解析 /
   per-task checkbox 判定を含む）
3. The エージェント連携（PM / Architect / Developer / Reviewer の入出力および各自己レビューゲート）
   shall .md を正準入力とし、.html を契約入力にしない
4. If 対象 .html が欠落または破損している場合, the 既存パイプライン shall 影響を受けず、本機能導入前と
   同一の判定結果で継続する

### Requirement 4: .md 更新への .html 追随（ドリフト対策）

**Objective:** As a 人間レビュワー, I want .md が更新された際に .html が追随再生成されることを期待する,
so that レビュー時に古い HTML を参照しない

#### Acceptance Criteria

1. While 本機能が有効化されている状態である間, when 対象 .md が更新（iteration による再生成を含む）
   された場合, the HTML 並行生成機能 shall 対応する .html を追随再生成する
2. The HTML 並行生成機能 shall .html を派生物（生成物）として扱い、.html への手編集を正準として
   維持しない

### Requirement 5: 生成失敗の分離とログ（silent fail 禁止）

**Objective:** As an idd-claude operator, I want HTML 生成の失敗が既存パイプラインを阻害しないことを
保証したい, so that 派生物生成の失敗で本流が停止しない

#### Acceptance Criteria

1. If .html の生成または追随再生成が失敗した場合, the HTML 並行生成機能 shall 対象 .md の生成 / 更新
   自体を完了させ、既存パイプライン（ラベル遷移 / PR 作成 / ゲート判定）を継続する
2. If .html の生成または追随再生成が失敗した場合, the HTML 並行生成機能 shall 失敗の事実と対象
   ファイルを 1 行以上ログに記録する（silent fail を作らない）
3. The HTML 並行生成機能 shall .html 生成の成否を既存の watcher exit code へ反映せず、exit code の
   意味を変更しない

### Requirement 6: 閲覧経路と外部送信の制限

**Objective:** As an idd-claude operator, I want HTML の閲覧手段が明示され、外部サービス送信が既定で
発生しないことを保証したい, so that 情報漏えいや意図しない外部依存を避けられる

#### Acceptance Criteria

1. The HTML 並行生成機能 shall 生成した .html を追加の外部サービスへ送信・アップロードすることなく
   ローカルに生成する（既定の閲覧経路はローカル checkout での参照）
2. Where .html を外部サービス（静的ホスティング等）へアップロードする経路を採用する場合, the 当該経路
   shall 本機能とは別の opt-in gate 配下でのみ有効化され、既定では外部送信しない
3. The 本機能のドキュメント shall 人間が .html を開く手段（例: ローカル checkout での参照方法）を案内
   する

### Requirement 7: PR diff ノイズの抑制

**Objective:** As a 人間レビュワー, I want .html を版管理する場合でも PR diff がノイズにならないことを
望む, so that レビュー対象の .md 変更に集中できる

#### Acceptance Criteria

1. Where 生成した .html をリポジトリにコミットする方針を採用する場合, the リポジトリ設定 shall 当該
   .html を生成物（generated）として扱い、PR diff で既定折りたたみ対象になるよう設定する
2. Where 生成した .html をコミットしない方針を採用する場合, the リポジトリ設定 shall 当該 .html を
   版管理対象から除外し、PR diff に現れないようにする

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 本機能の opt-in gate が無効な状態である間, the watcher / 各エージェント shall 本機能導入前と
   完全に同一の観測可能挙動（既存ラベル遷移 / コメント投稿 / 処理順序 / exit code 意味 / ログ出力先）を
   維持する
2. The 本機能 shall 既存 env var（`REPO` / `REPO_DIR` / `LOG_DIR` / `BASE_BRANCH` 等）の名前・意味・
   既定値を変更しない
3. The 本機能 shall 既存 cron / launchd 登録文字列およびラベル名を変更しない

### NFR 2: ランタイム / 依存の非追加（選好）

1. The 本機能 should 新規ランタイム（Node.js / Python / Ruby 等）の追加を伴わずに動作する（ランタイム
   非依存原則）
2. Where 新規依存 CLI（例: pandoc）の導入が生成手段として必要と判断される場合, the 導入 shall design で
   明示的に是非を判断し、導入時は README にセットアップ要件を明記する

### NFR 3: 観測可能性

1. The 本機能 shall 主要な分岐点（opt-in スキップ理由 / 対象ファイル / 生成成功 / 追随再生成 / 生成
   失敗）を運用者がログから判定できる形で記録する

### NFR 4: 二重管理整合（agents / rules / consumer 配布物を編集する場合）

1. Where 本機能の実装が `.claude/agents/*.md` または `.claude/rules/*.md` の変更を伴う場合, the
   implementation shall 同一 PR 内で root `.claude/{agents,rules}/` と
   `repo-template/.claude/{agents,rules}/` の双方を byte 一致で更新する
2. While 上記更新が同一 PR に含まれた状態である間, the verification step shall
   `diff -r .claude/agents repo-template/.claude/agents` および
   `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する
3. Where 本機能が consumer 配布物（workflow / labels / installer 配布ファイル / `.gitattributes` /
   `.gitignore` 等）に影響する場合, the implementation shall repo-template 側にも同期反映する

### NFR 5: 未信頼 GitHub 入力の取り扱い

1. Where 本機能が Issue / PR 由来の値（番号 / slug / ブランチ名 / ファイルパス）を扱う場合, the 実装
   shall 変数展開をクォートし、数値 ID を `^[0-9]+$`・path 構成要素を安全な文字集合で使用直前に検証
   してからファイル入出力に用いる

### NFR 6: 静的解析品質

1. While 本機能の新規 / 変更ファイル群に対し `shellcheck`（該当する場合 `actionlint`）を実行した状態で
   ある間, the static analysis result shall 既存の抑止方針（root `.shellcheckrc` 等）下で警告ゼロで
   完了する

### NFR 7: ドキュメント整合性

1. The 本機能 shall README の「オプション機能一覧」相当の節に、新規 env var 名・既定値・opt-in である旨・
   既定の閲覧経路を明記する
2. While 本機能の追加または挙動変更を含む PR が作成された状態である間, the documentation shall 同一 PR
   内で README / CLAUDE.md / 該当 rule ファイルの該当箇所を同時更新する

## Out of Scope

- .md を .html で置換する案（2026-06-02 に棚上げ済み。本 spec は「並行生成」に限定し、置換は扱わない）
- 機械ゲート入力としての .md の内容 / 形式の変更（tasks.md の checkbox 記法 / stage-a-verify セン
  チネル / Reviewer の `RESULT:` 行 / 型付きアノテーション DSL などの契約フォーマット変更）
- PR 本文の HTML 化（GitHub が既にレンダリングするファイル外成果物のため対象外）
- spec ディレクトリ外の任意 markdown（README / CLAUDE.md / rules 等）の HTML 化
- .html の見た目 / CSS テーマ / ブランディングの作り込み
- .md ↔ .html の内容乖離の自動検出・整合強制（本 spec は best-effort な追随再生成に留める）
- 外部静的ホスティング / GitHub Pages 等への自動アップロード機構の実装（採用時は別 opt-in gate 前提。
  本 spec では実装しない）
- 生成手段（pandoc / エージェント自身生成 / bash 完結）の最終確定（design の領分。本 spec は制約と
  選好のみ定義する）
- opt-in gate 用 env var の正式名の確定（本 spec は仮称 `SPEC_HTML_ENABLED` を用い、正式名は design で
  確定する）

## Open Questions

> 本節は人間レビュー向けの確認事項。設計寄りの判断は Architect（design.md）へ委ねるが、方針を要する
> 決定は人間承認が必要。

- 生成手段の選択: 新規依存 CLI（pandoc 等）の追加を許容するか / エージェント自身に生成させるか / bash で
  完結させるか。PM 選好は「ランタイム・新規 CLI 依存の非追加」。最終決定は Architect と人間承認に委ねる
- 対象成果物の最終集合: `impl-notes.md` / `review-notes.md` を並行生成対象に含めるか（PM 推奨: 含める）。
  含める場合の生成タイミング（impl PR 段階）を確定するか
- 閲覧経路の具体策: ローカル checkout での参照で十分か / PR 本文に「開き方案内」を追記するか / 外部静的
  ホスティングを別 opt-in で用意する需要があるか
- .html の版管理方針: リポジトリへコミットする（閲覧容易・diff ノイズは generated 扱いで抑制）か、
  コミットせずローカル生成のみ（`.gitignore` 除外）か。Requirement 7 は両案に対応するが、既定方針の
  確定が必要
- opt-in gate 用 env var の正式名（本 spec の仮称 `SPEC_HTML_ENABLED`）を確定する
- ドリフト自動検出の要否: .md 更新に対し .html が古くなった場合の検出 / 警告を将来必要とするか。本 spec
  では追随 best-effort のみとし、乖離検出は Out of Scope

## 関連

- Related: なし（本 spec 単独。2026-06-02 の「.md → .html 置換案」棚上げ判断は Introduction /
  Out of Scope に反映済みで、対応する Issue 番号は本文で参照していない）
