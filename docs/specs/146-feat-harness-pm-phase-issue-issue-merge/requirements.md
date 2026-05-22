# Requirements Document

## Introduction

idd-claude の自動開発パイプラインでは、PM phase（Triage 直後の要件確定段階）で Issue 本文に
記載された前提依存（`Depends on: #N` 等）を機械的に検証していない。このため、依存先 Issue が
未 merge のまま auto-dev が pickup され、Developer が依存解決待ちで halt したり、Reviewer が
未完成成果物を reject したり、再実行コストが累積する事案が観測されている（過去の運用で
1 Issue 当たり数十ドル規模の再実行費用が発生）。

本機能は、PM phase で Issue 本文を canonical / alias 双方の依存記法でパースし、依存先 Issue の
merge 状態を判定して、未解決依存が 1 件でも残る場合は **新規追加ラベル `blocked`** を付与して
人間判断にエスカレートする。watcher dispatcher は `blocked` 付き Issue を pickup 候補から
除外する。検出パターン非存在時は依存チェックを skip して従来通り pickup する（後方互換）。

ラベル `blocked` は既存の `needs-decisions`（汎用の人間判断要求）とは意味的に分離し、
「依存先 Issue 未 merge」専用の運用シグナルとして導入する。`.github/scripts/idd-claude-labels.sh`
への追加と README.md の運用ドキュメント整備までを本 Issue のスコープとする。

依存記法の canonical / alias の定義は [`.claude/rules/issue-dependency.md`](../../../.claude/rules/issue-dependency.md)
に正式ルール化済みで、本機能はそのルールを検出ロジックの基礎として参照する。

## Requirements

### Requirement 1: 依存 Issue 番号の抽出

**Objective:** As a idd-claude harness 運用者, I want PM phase で Issue 本文から前提依存の
Issue 番号を機械抽出してほしい, so that 人間が依存を見落としたまま auto-dev が走り出すリスクを
低減できる。

#### Acceptance Criteria

1. When PM phase で対象 Issue 本文を解析する, the Dependency Extractor shall canonical 記法 `Depends on: #N` の行から Issue 番号集合を抽出する
2. When PM phase で対象 Issue 本文を解析する, the Dependency Extractor shall alias 記法 `前提依存: #N` の行から Issue 番号集合を抽出する
3. When PM phase で対象 Issue 本文を解析する, the Dependency Extractor shall alias 記法 `Blocked by: #N` の行から Issue 番号集合を抽出する
4. When 1 行に複数の Issue 番号がスペース区切りまたはカンマ区切りで列挙されている, the Dependency Extractor shall 各 Issue 番号を独立した依存先として抽出する
5. When 同一の Issue 番号が複数の記法・複数の行で検出される, the Dependency Extractor shall 重複を排除した一意な集合として扱う
6. If Issue 本文中に上記いずれの記法も検出されない, the Dependency Extractor shall 依存先集合を空集合として返し、後続の依存チェックを skip する
7. The Dependency Extractor shall canonical / alias の双方を [`.claude/rules/issue-dependency.md`](../../../.claude/rules/issue-dependency.md) の定義と整合する形で検出する

### Requirement 2: 依存 Issue の merge 状態判定

**Objective:** As a idd-claude harness 運用者, I want 抽出した各依存 Issue が merge 済みかどうかを
GitHub の状態から判定してほしい, so that close 済みだが未 merge（手動 close / `wontfix`）な
Issue を「解決済み」と誤認しない。

#### Acceptance Criteria

1. When 依存先 Issue 集合が空でない, the Dependency Resolver shall 各依存 Issue の `state` と「Issue を close した PR の merged 状態」を GitHub から取得する
2. When 依存 Issue の `state` が `closed` であり、かつ当該 Issue を close した PR の少なくとも 1 つが merged 済み, the Dependency Resolver shall 当該依存を「解決済み」と判定する
3. If 依存 Issue の `state` が `open`, the Dependency Resolver shall 当該依存を「未解決」と判定する
4. If 依存 Issue の `state` が `closed` だが、当該 Issue を close した PR がいずれも merged でない（または PR 紐付けが無い）, the Dependency Resolver shall 当該依存を「未解決」と判定する
5. If 依存 Issue の取得が GitHub API エラー・該当 Issue 不存在等により失敗する, the Dependency Resolver shall 当該依存を「未解決」として扱い、後続ステップへエスカレートする
6. While 複数の依存 Issue を判定中, the Dependency Resolver shall 1 件以上の「未解決」依存を検出した段階で全体結果を「ブロック状態」と確定する

### Requirement 3: ブロック検出時のラベル付与とエスカレーション

**Objective:** As a idd-claude harness 運用者, I want 未解決依存が検出された Issue を pickup
対象から外し、運用者に人間判断を促すコメントを残してほしい, so that 依存解消の意思決定が
Issue 上に集約され、auto-dev が無駄なリトライを繰り返さない。

#### Acceptance Criteria

1. When Dependency Resolver が「ブロック状態」と確定する, the PM Phase Orchestrator shall 対象 Issue に `blocked` ラベルを付与する
2. When Dependency Resolver が「ブロック状態」と確定する, the PM Phase Orchestrator shall 対象 Issue に、未解決依存の Issue 番号一覧と解消後の運用手順（`blocked` ラベルを手動除去すれば次サイクルで再評価される旨）を含むエスカレーションコメントを 1 件投稿する
3. When `blocked` ラベルを付与する, the PM Phase Orchestrator shall 既存の進行ラベル（`claude-claimed` / `claude-picked-up` 等、本サイクルで自動付与済みのもの）を除去して、Issue の状態が「ブロック中」として明確に読み取れるようにする
4. If 対象 Issue に既に `blocked` ラベルが付与されている, the PM Phase Orchestrator shall ラベル再付与を skip し、エスカレーションコメントの重複投稿を行わない
5. When `blocked` 検出が完了する, the PM Phase Orchestrator shall 後続の Developer / Architect 起動を実行せず、本サイクルでの当該 Issue 処理を打ち切る
6. The PM Phase Orchestrator shall エスカレーションコメント本文に、未解決依存 Issue へのリンク（`#N` 形式）と判定結果（`open` / `closed unmerged` 等の区分）を運用者が判別できる形で含める

### Requirement 4: Dispatcher による blocked Issue の pickup 除外

**Objective:** As a idd-claude watcher 運用者, I want `blocked` ラベルが付いた Issue を auto-dev
の pickup 候補から除外してほしい, so that ブロック中の Issue が次サイクルで再度 PM phase へ
進んで重複コメントや無駄な API 呼び出しを発生させない。

#### Acceptance Criteria

1. While Issue に `blocked` ラベルが付与されている, the Watcher Dispatcher shall 当該 Issue を auto-dev pickup の候補から除外する
2. When 運用者が `blocked` ラベルを Issue から手動除去する, the Watcher Dispatcher shall 次サイクル以降で当該 Issue を通常の pickup 候補として再評価する
3. The Watcher Dispatcher shall `blocked` を除外条件に加える際、既存の除外ラベル（`needs-decisions` / `needs-iteration` / `needs-quota-wait` / `staged-for-release` / `st-failed` 等）の意味・挙動を変更しない

### Requirement 5: 検出パターン非存在時の後方互換

**Objective:** As a idd-claude 既存利用リポジトリ運用者, I want 依存記法を本文に書いていない
既存 Issue が本機能導入によって挙動を変えないこと, so that retrofit 作業をせずに既存運用が
継続できる。

#### Acceptance Criteria

1. If 対象 Issue 本文に Requirement 1 で定義する検出パターンがいずれも検出されない, the PM Phase Orchestrator shall 依存チェックを skip し、本機能導入前と同一の pickup 挙動を維持する
2. While 依存記法非搭載の既存 Issue を処理中, the PM Phase Orchestrator shall `blocked` ラベルの付与・エスカレーションコメント投稿のいずれも実行しない
3. The PM Phase Orchestrator shall 依存記法非搭載の Issue に対する処理時間が、本機能導入前と比較して運用者から見て体感差のない範囲（追加で発生する処理は本文パース 1 回のみ）に収まる

### Requirement 6: 実行ログ記録

**Objective:** As a idd-claude 運用者, I want 依存チェックの実行結果がログから後追いできること,
so that ブロック誤判定や検出漏れが起きたときに、Issue 本文・依存先 Issue 状態・最終判定の
どこに原因があるかを切り分けられる。

#### Acceptance Criteria

1. When PM phase が依存チェックを実行する, the PM Phase Orchestrator shall 対象 Issue 番号・抽出された依存先 Issue 番号集合・各依存の merge 状態判定結果・最終判定（ブロック中 / 解決済み / skip）をログに記録する
2. When 依存 Issue の取得が失敗する, the PM Phase Orchestrator shall 失敗理由（API エラー内容・該当 Issue 不存在等）をログに記録する
3. The PM Phase Orchestrator shall ログ出力先・フォーマットを、既存 watcher ログ（`LOG_DIR` 配下）と同一規約に整合させる

### Requirement 7: `blocked` ラベル定義の配布

**Objective:** As a idd-claude 利用リポジトリ運用者, I want `blocked` ラベルが idd-claude の
一括ラベル作成スクリプトで作成されること, so that 各リポジトリで個別に `gh label create` を
打たずに、標準ラベルセットの一部として一括配布できる。

#### Acceptance Criteria

1. When 運用者が idd-claude の一括ラベル作成スクリプトを実行する, the Labels Setup Script shall `blocked` という名前のラベルを GitHub リポジトリに作成する
2. When `blocked` ラベルを作成する, the Labels Setup Script shall description に「依存 Issue 未 merge により auto-dev 進行不能」という意味が読み取れる文字列を設定する
3. The Labels Setup Script shall `blocked` を「Issue に適用するラベル」として扱い、既存の description 規約（適用先 prefix）に整合させる
4. While `blocked` ラベルが既に存在する状態で `--force` オプション無しで再実行された, the Labels Setup Script shall 当該ラベルを上書きせず skip 結果として報告する
5. While `blocked` ラベルが既に存在する状態で `--force` オプション付きで再実行された, the Labels Setup Script shall 当該ラベルの color と description を上書き更新する
6. The Labels Setup Script shall idd-claude 自身（self-hosting）用と consumer 配布用の両系統で、同一の名前・description で `blocked` を提供する

### Requirement 8: README.md ドキュメント整備

**Objective:** As a idd-claude 利用リポジトリ運用者, I want README.md に `blocked` ラベルの
位置付けと依存チェックの運用フローが書かれていること, so that ラベルを見ただけで意味が
判別でき、ブロック解消の手順が運用者に明確に伝わる。

#### Acceptance Criteria

1. The README.md ラベル一覧 shall `blocked` の行を含み、適用先（Issue）・付与主（PM Phase Orchestrator による自動付与）・意味（依存 Issue 未 merge により auto-dev 進行不能）を読み取れる形で記載する
2. The README.md ラベル状態遷移節 shall `blocked` が auto-dev の pickup 除外条件として作用することを記述する
3. The README.md shall 依存 Issue 記法（canonical `Depends on: #N` および alias `前提依存:` / `Blocked by:`）を使うと PM phase で依存チェックが走る旨を運用者向けに記述する
4. The README.md shall `blocked` 付与後の運用手順（依存先 Issue を merge する → `blocked` ラベルを手動除去する → 次 cron tick で再評価される）を運用者向けに記述する
5. The README.md shall `blocked` と `needs-decisions` の意味的差分（`blocked` = 依存 Issue 未 merge 専用、`needs-decisions` = それ以外の汎用人間判断要求）を 1〜2 行で明示する
6. If `QUICK-HOWTO.md` 等の補助ドキュメントが「作成されるラベル」一覧を持つ場合, the Documentation Set shall 当該箇所にも `blocked` を追記する

### Requirement 9: `needs-decisions` との意味的分離

**Objective:** As a idd-claude 運用者, I want `blocked` ラベルが既存 `needs-decisions` ラベルとは
独立した意味・運用フローを持つこと, so that 人間判断の理由（依存未 merge / それ以外）が
ラベルだけで判別でき、棚卸し時の優先度判断が容易になる。

#### Acceptance Criteria

1. The PM Phase Orchestrator shall ブロック検出時に `blocked` ラベルを付与し、`needs-decisions` ラベルは付与しない
2. The PM Phase Orchestrator shall `blocked` 付与時のエスカレーションコメントを `needs-decisions` 用テンプレートと混在させず、依存未解決専用の文面で投稿する
3. The Watcher Dispatcher shall `blocked` と `needs-decisions` のいずれか一方でも付与された Issue を pickup 対象外として扱うが、両ラベルの状態遷移・除去フローを独立に扱う
4. The README.md shall `blocked` と `needs-decisions` を別ラベルとして列挙し、いずれも将来統合しない方針であることを記述する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PM Phase Orchestrator shall 依存記法を含まない既存 Issue に対して、本機能導入前と完全に同一の pickup 挙動・ログ出力を維持する
2. The Labels Setup Script shall 既存ラベル（`auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` / `needs-quota-wait` / `staged-for-release` / `st-failed`）の名前・色・description を `blocked` 追加に伴って変更しない
3. The Watcher Dispatcher shall `blocked` を除外条件に追加することで、既存の除外ラベル群の解釈・挙動を変更しない
4. The PM Phase Orchestrator shall Issue 本文中の依存記法以外の本文表現（コードフェンス内の例示・引用ブロック内の `Depends on:` 文字列等）を、過去 Issue の既存記述で運用上問題が出ない範囲で誤検出しないよう扱う（誤検出時の影響は `blocked` 誤付与 → 運用者がラベル手動除去で復旧可能）

### NFR 2: 観測可能性

1. The PM Phase Orchestrator shall 依存チェックの判定結果（抽出件数・解決済み件数・未解決件数・最終判定）を 1 Issue 1 行の構造化ログとしてログ出力先に記録し、運用者が `grep` で集計できる粒度を満たす
2. The PM Phase Orchestrator shall `blocked` 付与イベントを既存の watcher ログと同一の `LOG_DIR` 配下に記録する

### NFR 3: 冪等性

1. The PM Phase Orchestrator shall 同一 Issue に対して N 回（N >= 2）連続実行されても、`blocked` ラベルの付与数が常に 1 個・エスカレーションコメントの投稿数が常に 1 件に収束する
2. The Labels Setup Script shall 再実行（`--force` の有無に関わらず）に対して冪等であり、`blocked` 追加によって複数回実行時のラベル状態が不整合にならない

### NFR 4: 運用継続性

1. The PM Phase Orchestrator shall 1 Issue あたりの依存チェック処理時間（依存先 Issue 取得を含む）が通常運用の Triage 処理時間に対して支配的にならず、cron tick 内で完了する範囲に収まる
2. If GitHub API レート制限に抵触した場合, the PM Phase Orchestrator shall 当該 Issue の依存チェックを skip ではなく「未解決として安全側に倒す」処理として `blocked` 扱いにする（API 不達時の誤 pickup 防止）

## Out of Scope

- 依存先 Issue が後に merge されたタイミングで `blocked` ラベルを **自動除去**して再 pickup する automation（auto-unblock）。本 Issue では手動除去のみを運用フローとする
- **循環依存検出**（A が B に依存し B が A に依存するケース）。本 Issue では未解決依存が 1 件でもあればブロック扱いとし、循環の有無は判定しない
- 既に in-flight（`claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` 等の進行中ラベルが付与済み）の Issue に対する遡及的な依存チェック（retrofit）
- `Parent: #N` / `Sibling: #N` / `Related: #N` / `Split from: #N` 等、依存以外の関係種別に対するブロッキング判定（[`.claude/rules/issue-dependency.md`](../../../.claude/rules/issue-dependency.md) のブロッキング性定義に従い、`Depends on:` 系のみが対象）
- 逆方向の `Blocks: #N` 記法に基づく被ブロッキング側の自動検出（canonical では非採用のため）
- 依存記法をクロスリポジトリ参照（`owner/repo#N` 形式）に対応させる挙動。本 Issue では同一リポジトリ内の `#N` 参照のみを対象とする
- 既存 `needs-decisions` ラベルの `blocked` への統合・移行・廃止
- 依存解決状況の可視化ダッシュボード・依存グラフ生成

## Open Questions

- なし（ラベル方針 = 新規 `blocked` ラベル追加 / README 編集の本 Issue スコープ含有 /
  検出パターン = canonical + alias は Issue 本文と人間コメントで確定済み）
