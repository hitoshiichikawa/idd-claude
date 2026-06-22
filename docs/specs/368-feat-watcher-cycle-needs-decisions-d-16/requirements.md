# Requirements Document

## Introduction

idd-claude の Dependency Resolver Gate（#146）と Auto-Unblock スイープ（#346 / `DEP_AUTO_UNBLOCK_ENABLED`）により、`auto-dev` ラベル付き Issue の依存関係に応じた `blocked` ラベル付与・自動解除がライフサイクル化されている。一方、依存グラフが **循環（cycle）** している場合、auto-unblock は閉路内の Issue を永続的に「未解決」と判定し、依存ゲートと自動解除が拮抗してデッドロック状態に陥る。運用者が GitHub UI から気付かない限り Issue が滞留する。

本機能（D-16）は、auto-unblock の評価対象である `auto-dev` + `blocked` Issue 集合の依存エッジから有向グラフを構築し、**閉路検出 → 閉路メンバーに `needs-decisions` 付与 + 説明コメントを冪等に投稿** することで、人間判断にエスカレートする。既存挙動の後方互換性を最優先とし、env var による opt-in gate（既定 OFF）配下で導入する。依存記法（canonical / alias）の変更は行わない。

## Requirements

### Requirement 1: Opt-in Gate と後方互換性

**Objective:** As a idd-claude 運用者, I want cycle 検出・needs-decisions エスカレーションを env var の明示的な opt-in でのみ起動できる, so that 既存運用と #346 auto-unblock の挙動を壊さずに段階的に有効化できる

#### Acceptance Criteria

1. While 本機能の opt-in gate（既存 `DEP_AUTO_UNBLOCK_ENABLED` 配下、または Architect が確定する派生 env var）が `true` のとき, the watcher shall cycle 検出と needs-decisions エスカレーションを当該 tick 内で実行する
2. While 本機能の opt-in gate が未設定 / 空文字 / `true` 以外の任意の値（`false` / `0` / typo を含む）であるとき, the watcher shall cycle 検出・needs-decisions 付与・コメント投稿を一切実行せず、本機能導入前と完全に同一の挙動を保つ
3. If 本機能の opt-in gate が不正値（`true` 以外）であるとき, the watcher shall 当該値を安全側（無効）に正規化し、gh API への write 呼び出し（ラベル付与・コメント投稿）を行わない
4. The watcher shall 既存 env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 / 既存ログ出力先 / `dr_*` 関数群の signature・戻り値契約に対して破壊的変更を加えない
5. Where 全自動運転 kill switch（`FULL_AUTO_ENABLED=false` 等の既存上位 gate）が無効化されているとき, the watcher shall cycle 検出・エスカレーション処理を suppress し、構造化ログでその旨を 1 行記録する

### Requirement 2: Cycle 検出対象の列挙

**Objective:** As a watcher, I want cycle 検出の対象を auto-dev + blocked + OPEN Issue の依存エッジに限定したい, so that 終端状態の Issue や対象外 Issue を誤って閉路判定に巻き込まない

#### Acceptance Criteria

1. When cycle 検出が実行されるとき, the watcher shall `auto-dev` ラベルと `blocked` ラベルが付与された OPEN 状態の Issue 集合を取得し、それらの本文から `.claude/rules/issue-dependency.md` の canonical 記法（`Depends on:`）および互換 alias（`前提依存:` / `Blocked by:`）に基づき有向依存エッジを抽出する
2. While 対象 Issue 集合に含まれない番号（merge 済み / クローズ済み / `claude-failed` 等の終端ラベル付与 Issue）がエッジ先として参照されているとき, the watcher shall 当該エッジを cycle 判定の対象から除外する（既存 auto-unblock が解決判定する責務に委ねる）
3. When cycle 検出が実行されるとき, the watcher shall #346 auto-unblock スイープと協調可能なタイミング（dispatcher のメイン候補クエリより前段、auto-unblock スイープと同一の前処理フェーズ）で起動する
4. If 対象 Issue 集合が空（auto-dev + blocked + OPEN が 0 件）のとき, the watcher shall 追加の gh API write 呼び出しゼロで処理を終了する

### Requirement 3: 閉路検出アルゴリズムの可観測な性質

**Objective:** As a 運用者, I want 依存グラフ上のあらゆる閉路を検出し、メンバー Issue 番号を一意に特定したい, so that エスカレーション対象に漏れ・誤検出が発生しない

#### Acceptance Criteria

1. The watcher shall 構築した有向依存グラフに対し、自己ループ（A→A）を含むあらゆる長さの閉路を検出する
2. The watcher shall 長さ 2 以上の閉路（A→B→A、A→B→C→A、…、任意長 N の閉路）を検出する
3. When 同一グラフ内に複数の独立した閉路が存在するとき, the watcher shall それぞれを区別して列挙し、各閉路のメンバー Issue 集合を一意に特定する
4. When グラフが閉路と非閉路（DAG 部分）の混在で構成されているとき, the watcher shall 閉路メンバーのみをエスカレーション対象とし、非閉路 Issue は #346 auto-unblock の通常評価に委ねる
5. The watcher shall 閉路検出処理を有限時間で終了し、無限ループ・無限再帰を発生させない

### Requirement 4: 閉路メンバーへの needs-decisions エスカレーション

**Objective:** As a 運用者, I want 閉路を構成する Issue に needs-decisions を自動付与し、人間判断に委ねたい, so that デッドロックを GitHub UI から気付ける状態にできる

#### Acceptance Criteria

1. When 対象 Issue が 1 つ以上の閉路のメンバーとして検出されたとき, the watcher shall 当該 Issue に `needs-decisions` ラベルを付与する
2. When 閉路メンバー Issue に `needs-decisions` を付与したとき, the watcher shall 閉路構造を説明するコメント（閉路に含まれる Issue 番号の集合を明示）を当該 Issue に 1 件投稿する
3. The 説明コメント shall 本機能由来であることを判定可能な識別子（HTML コメント等、形式は実装裁量）を含み、後続 tick での冪等性判定に利用できる
4. While 閉路メンバー Issue が cycle 検出によりエスカレートされたとき, the watcher shall 当該 Issue に対して `blocked` ラベルの自動解除（#346 auto-unblock）を実行しない
5. If `needs-decisions` 付与（gh API write）が失敗したとき, the watcher shall 説明コメントを投稿せず、当該 Issue の状態を変更しないまま次の Issue へ進む
6. If 説明コメント投稿（gh API write）が失敗したとき, the watcher shall 警告ログを 1 行残し、当該 Issue の処理を中断して次の Issue へ進む

### Requirement 5: 冪等性

**Objective:** As a 運用者, I want cycle 検出を連続実行しても観測可能な副作用が累積しないことを保証したい, so that cron tick 頻度の変更・再実行で運用が壊れない

#### Acceptance Criteria

1. When cycle 検出が同一閉路に対して連続 N 回（N >= 2）実行されるとき, the watcher shall 閉路メンバー Issue への `needs-decisions` ラベル付与・説明コメント投稿を合計 1 回に収束させる
2. While 閉路メンバー Issue に本機能由来の説明コメントが既に投稿済みであるとき, the watcher shall 説明コメントを再投稿しない
3. While 閉路メンバー Issue に既に `needs-decisions` ラベルが付与されているとき, the watcher shall ラベル付与 API を再呼び出ししない（または冪等な形で no-op に倒す）
4. When 閉路構成が前回 tick から変化していないとき, the watcher shall gh API の write 呼び出しを発生させない

### Requirement 6: 監査ログ

**Objective:** As a 運用者, I want cycle 検出・エスカレーションの判定理由を構造化ログから追跡したい, so that 想定外挙動の調査やラベル状態の説明責任を果たせる

#### Acceptance Criteria

1. When cycle 検出が「閉路を 1 件以上検出した」とき, the watcher shall 既存 `dr_log` と同形式の構造化ログを閉路ごとに 1 行出力し、閉路メンバー Issue 番号集合を含める
2. When cycle 検出が「閉路ゼロ件」と判定したとき, the watcher shall 既存 `dr_log` と同形式の構造化ログを 1 行出力し、評価対象件数を含める
3. When cycle 検出が `needs-decisions` 付与・コメント投稿を実行したとき, the watcher shall 対象 Issue ごとに `dr_log` 同形式の構造化ログを 1 行出力する
4. When cycle 検出が冪等 skip（既に通知済み）と判定したとき, the watcher shall `dr_log` 同形式の構造化ログを 1 行出力し、skip 理由を含める
5. If gh API 呼び出しが失敗したとき, the watcher shall 既存 `dr_warn` と同形式の警告ログを 1 行出力する

### Requirement 7: 配布範囲とドキュメント

**Objective:** As a メンテナ, I want 本機能の変更範囲を local-watcher 単体に限定しつつ、README へ挙動変更を反映したい, so that consumer repo（template 配布対象）への影響を最小化し、運用者が機能を把握できる

#### Acceptance Criteria

1. The watcher 実装変更 shall `local-watcher/bin/issue-watcher.sh` および同階層 `modules/` 配下に限定し、`repo-template/**` および `.claude/{agents,rules}/` 配下の同期対象には変更を加えない
2. When 本機能が PR として提出されるとき, the maintainer shall README の該当節（オプション機能一覧 / ラベル状態遷移まとめ 等）を同一 PR で更新する
3. The maintainer shall 依存記法ガイド（`.claude/rules/issue-dependency.md`）に手を入れず、既存 canonical / alias 記法を前提として実装する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 本機能の opt-in gate が未設定 or `true` 以外のとき, the watcher shall 本機能導入前と完全に同一の cron tick 挙動を保つ（gh API 呼び出し回数・ログ出力・ラベル遷移すべて一致）
2. The watcher shall 既存の `LABEL_BLOCKED` / `LABEL_TRIGGER`（`auto-dev`）/ `LABEL_NEEDS_DECISIONS` / `dr_*` 関数群の signature・戻り値契約を変更しない

### NFR 2: 性能

1. While 対象 Issue 集合が空（auto-dev + blocked + OPEN が 0 件）のとき, the watcher shall 候補列挙の 1 クエリ以外に gh API 呼び出しを発生させない
2. When 対象 Issue 集合が N 件のとき, the watcher shall グラフ構築のための本文取得 API 呼び出しを 1 Issue あたり 1 回以下に抑える（auto-unblock スイープが取得済みの本文をキャッシュ・再利用してよい）
3. The watcher shall cycle 検出アルゴリズム自体は対象集合のサイズに対して多項式時間（最悪 O((V+E)) 程度のグラフ探索）で完了し、cron tick 内の他処理を阻害しない

### NFR 3: 安全性 / フェイルセーフ

1. If 依存マーカー解析（`dr_extract_deps`）が空または不正な値を返したとき, the watcher shall 当該 Issue を閉路グラフのノードとして登録するがエッジを追加せず、cycle 判定の対象から自然に除外する
2. If gh API の write 操作（ラベル付与 / コメント投稿）が失敗したとき, the watcher shall 当該 Issue の状態を破壊せず（ラベルのみ付与してコメント未投稿等の中途半端な状態を残しても次 tick で冪等に補正できる形に倒し）、警告ログを残して次の Issue へ進む
3. The watcher shall 検出した閉路が #346 auto-unblock の判定（依存全解決）と矛盾する場合でも、cycle 検出側のエスカレーション（`needs-decisions` 付与）を優先し、auto-unblock 側の `blocked` 解除を実行しない

### NFR 4: 監査性

1. The watcher shall 検出された各閉路のメンバー Issue 番号集合を構造化ログ 1 行で記録し、ログ grep で閉路履歴を再構成できる
2. The watcher shall `needs-decisions` 付与した Issue に対して、GitHub UI 上のコメント履歴から「watcher による cycle 検出由来のエスカレーションである」と判別できる証跡を残す

### NFR 5: セキュリティ（未信頼入力の取り扱い）

1. The watcher shall Issue 本文・ラベル・番号を gh / git / jq に渡す際、CLAUDE.md §5 に準拠し（変数クォート / jq `--arg` / gh `--` オプション終端 / 数値 ID は `^[0-9]+$` 検証）、引数注入・コマンドインジェクションを防止する
2. The watcher shall 閉路メンバー Issue 番号集合をコメント本文に埋め込む際、未信頼入力として扱い、説明コメントテンプレートへ安全に展開する

### NFR 6: 冪等性

1. When cycle 検出スイープが同一閉路に対して連続 2 回以上実行されるとき, the watcher shall 観測可能な副作用（ラベル変化 / コメント増分）を最初の 1 回に収束させる

## Out of Scope

- 依存記法（`Depends on:` / `前提依存:` / `Blocked by:` / `Parent:` / `Split from:` 等）の構文拡張・新規エイリアス追加（`.claude/rules/issue-dependency.md` は不変）
- #346 auto-unblock 本体の挙動変更（cycle 検出は同居の前処理として導入し、auto-unblock の判定ロジック・gate 名・コメント文面は変更しない）
- 閉路解消の自動提案（どのエッジを切断すれば閉路が解消するかのヒント生成、依存記法の自動書き換え）
- 閉路検出結果の外部通知連携（Slack / Discord webhook 等）
- 閉路を構成しない Issue の `needs-decisions` エスカレーション（cycle 検出由来以外の人間判断要求は別 Issue で扱う）
- `Parent:` / `Split from:` / `Sibling:` / `Related:` 等の非ブロッキング関係種別を cycle 判定に含めること（cycle は `Depends on:` 系のみを対象とする）
- `repo-template/**` / `.claude/{agents,rules}/` 同期（本機能は local-only モジュールで完結する）

## Acceptance Test Cases（受入テスト観点）

以下のテストケースを最低限カバーすること。各ケースの実装可否（unit test / 手動スモークテスト）の選択は Developer 裁量。

| ID | 状態 | gate | 期待挙動 | 検証手段の例 |
|---|---|---|---|---|
| AT-a | 非循環の DAG 依存（A→B→C、全 OPEN） | ON | cycle 検出ゼロ件、#346 auto-unblock の通常評価に委ねる | unit test（グラフ構築 + 閉路判定） |
| AT-b | 自己依存（A→A） | ON | A に `needs-decisions` + 説明コメント 1 件 | unit test（gh stub） |
| AT-c | 2 ノード閉路（A→B→A） | ON | A, B に `needs-decisions` + 説明コメント 1 件ずつ | unit test（gh stub） |
| AT-d | 多段閉路（A→B→C→A） | ON | A, B, C に `needs-decisions` + 説明コメント 1 件ずつ | unit test（gh stub） |
| AT-e | 閉路 + 非閉路の混在（A→B→A、D→E） | ON | A, B のみエスカレート、D, E は対象外 | unit test（混在グラフ） |
| AT-f | 複数の独立した閉路（A→B→A、C→D→C） | ON | 全 4 ノードにエスカレート、閉路ごとに区別してログ | unit test（複数閉路） |
| AT-g | 連続 2 回スイープ実行（同一閉路） | ON | 副作用が最初の 1 回に収束（ラベル・コメント増分なし） | unit test（gh stub の call count） |
| AT-h | gate OFF（未設定 / 不正値 / `false`） | OFF | cycle 検出自体走らない・gh API write 呼び出しゼロ | unit test（gate 正規化） |
| AT-i | `needs-decisions` 付与成功 + コメント投稿失敗 | ON | 警告ログ 1 行・次 Issue へ進む（中途半端な状態の冪等補正） | unit test（gh stub failure 注入） |
| AT-j | 閉路メンバーで `blocked` 解除が走らない | ON | 同 tick の #346 auto-unblock が閉路メンバーをスキップする | unit test（auto-unblock との協調検証） |

## 関連

- Depends on: #346
- Related: #146 #316

## Open Questions

- 本機能の opt-in gate を **新規 env var として独立** させるか（例: `DEP_CYCLE_DETECT_ENABLED`）、**既存 `DEP_AUTO_UNBLOCK_ENABLED` 配下に統合** するかは Architect 確定事項。本要件は「Architect が確定する opt-in env var」として参照する
- 閉路ごとに「代表 1 件にのみコメントして他は label のみ」とするか「閉路メンバー全員に同じ説明コメントを投稿する」かは Developer 実装裁量。ただし冪等性（Requirement 5）と監査性（NFR 4.2）を満たすこと
- 説明コメントに記載する閉路メンバー番号集合の表記順序（番号昇順 / トポロジカル順序 / 検出順）は Developer 実装裁量
- 説明コメントの「本機能由来判定マーカー」文字列（HTML コメント識別子等）の具体形は Developer 実装裁量。ただし本機能由来であることが判定できる識別子を必ず含めること
