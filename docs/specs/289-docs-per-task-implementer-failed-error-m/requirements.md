# Requirements Document

## Introduction

per-task Implementer ループ運用が広く使われるようになった結果、Implementer が
`error_max_turns`（既定 60 turn）に到達して exit し、`per-task-implementer-failed`
→ `claude-failed` へ遷移する事例が頻発している。これは特定リポジトリ固有ではなく、
frontend / UI / テスト重めの責務を 1 タスクに束ねた利用者全般に起こる現象である。
per-task ループは各タスク開始時に fresh Claude session で起動するため、一度
turn を使い切ったタスクは再試行時もゼロからやり直しになり、turn 消費とコスト
損失が両方発生する。現在の README / QUICK-HOWTO / repo-template の tasks 生成
ルールには、(1) 症状と原因の切り分け、(2) 対応の優先順位、(3) 安全な復旧手順、
(4) tasks の粒度ガイドライン、が体系的に整理されていない。本 spec ではこれらの
ドキュメントを整備し、運用者が独力で原因切り分け・対応選択・復旧操作を完遂
できる状態を実現する。実装ロジック（per-task ループの自動分割・自動引き上げ等）
の変更は本 spec のスコープ外とする。

## Requirements

### Requirement 1: Troubleshooting 節の整備

**Objective:** As a idd-claude の運用者, I want `per-task-implementer-failed` /
`error_max_turns` に遭遇したときに参照できる Troubleshooting 節を README から
見つけたい, so that ログと Issue ラベル状態から原因を独力で切り分け、対応方針を
選択できる

#### Acceptance Criteria

1. The README shall `per-task-implementer-failed` および `error_max_turns` を含む
   Troubleshooting 節を 1 つ以上含む
2. The Troubleshooting 節 shall 「症状」「原因」「診断手順」「対応（優先順）」
   「復旧手順」の 5 つの観点をいずれも記述する
3. When 運用者が watcher ログまたは Issue コメント上で `error_max_turns` を観測
   したとき, the Troubleshooting 節 shall 「Implementer が許容 turn 上限に到達して
   exit した状態」であり、必ずしも実テスト失敗を意味しないことを明示する
4. The Troubleshooting 節 shall 該当 Issue / PR に付与される `claude-failed` および
   `per-task-implementer-failed` ラベルの意味と、それぞれの状態で運用者が次に
   取るべき次アクションを記述する
5. Where QUICK-HOWTO.md がトラブル時の最初の参照先として位置付けられている場合,
   the QUICK-HOWTO.md shall 最頻出ケース（`per-task-implementer-failed` /
   `error_max_turns`）の簡潔な要約と、README の Troubleshooting 節への相互リンクを
   持つ

### Requirement 2: 原因切り分け（529 過負荷・実テスト失敗との区別）

**Objective:** As a idd-claude の運用者, I want `error_max_turns` を、過負荷
（529 / overloaded）や実テスト失敗による Implementer 終了と区別できる手順を持ちたい,
so that 誤った対応（粒度是正が必要な事象に対して再 pickup を繰り返す等）を防げる

#### Acceptance Criteria

1. The Troubleshooting 節 shall `error_max_turns` と 529 過負荷起因の Implementer
   失敗を区別する診断観点（ログ上の文字列・終了理由・ラベル遷移など、運用者が
   観測可能なシグナル）を列挙する
2. The Troubleshooting 節 shall `error_max_turns` と Developer 実行内の実テスト失敗
   （実装に起因する fail）を区別する診断観点を列挙する
3. When 運用者が観測したシグナルが 529 過負荷に該当するとき, the Troubleshooting 節
   shall 「再 pickup によるリトライで回復し得る」旨と、その手順を案内する
4. When 運用者が観測したシグナルが実テスト失敗に該当するとき, the Troubleshooting 節
   shall 「Reviewer / Debugger 経路または手動修正を選ぶべき」旨と、その判断基準を
   案内する
5. When 運用者が観測したシグナルが `error_max_turns` に該当するとき, the
   Troubleshooting 節 shall Requirement 3 の対応優先順に沿った次アクションを案内する

### Requirement 3: 対応の優先順位

**Objective:** As a idd-claude の運用者, I want `error_max_turns` 発生時の対応を
明確な優先順位で示してほしい, so that 安易な恒久引き上げを避け、根本原因（タスク
粒度の不適合）に向き合った対応を選べる

#### Acceptance Criteria

1. The Troubleshooting 節 shall 対応の優先順を「(1) タスク粒度の是正 → (2) 一時的な
   `DEV_MAX_TURNS` 引き上げ → (3) 手動仕上げ」の 3 段階で明示する
2. The Troubleshooting 節 shall タスク粒度の是正手段として、親タスクの細分化および
   「UI = 1 component + 1 test = 1 task」のような分割指針を含む
3. The Troubleshooting 節 shall `DEV_MAX_TURNS` の引き上げを「一時的・その場限り」
   の措置と位置付け、恒久値の変更を推奨しないことを明示する
4. The Troubleshooting 節 shall 手動仕上げを「自動経路で詰まった場合の最終手段」と
   位置付け、いつ手動仕上げに切り替えるかの判断基準（例: 同一タスクで自動経路が
   N 回連続失敗した場合 等、観測可能な閾値）を示す
5. The Troubleshooting 節 shall 各優先順位の選択が後続の挙動に与える影響（例:
   `DEV_MAX_TURNS` 一時引き上げは次回 watcher 実行のみに有効、等）を運用者目線で
   記述する

### Requirement 4: 復旧手順（impl PR の有無別）

**Objective:** As a idd-claude の運用者, I want 「impl PR がまだ存在しないケース」
と「impl PR が既にあるケース」で異なる安全な復旧手順を示してほしい, so that ラベル
操作順序の誤りで進行中の PR を破壊するリスクを避けられる

#### Acceptance Criteria

1. When impl PR が存在しない状態で `claude-failed` が付与されているとき, the
   Troubleshooting 節 shall `claude-failed` ラベルを除去することで watcher が再
   pickup する手順を示す
2. When impl PR が既に存在する状態で `claude-failed` が付与されているとき, the
   Troubleshooting 節 shall 「`ready-for-review` を **先に** 付与してから
   `claude-failed` を除去する」順序を明示する
3. If 運用者が impl PR 存在下で `claude-failed` を先に除去した場合に発生し得る
   破壊事象（進行中の PR / ブランチへの影響）がある場合, the Troubleshooting 節
   shall その破壊事象の概要と回避策を警告として記述する
4. The Troubleshooting 節 shall 復旧後の期待状態（どのラベルが残り、次に watcher
   または人間レビュアーが取るアクションは何か）を、impl PR の有無別に明示する
5. The Troubleshooting 節 shall 復旧手順を運用者が実行する操作（ラベル付与・除去
   の順序）として記述し、内部実装の関数名やコードパスには踏み込まない

### Requirement 5: `DEV_MAX_TURNS` の README ドキュメント拡充

**Objective:** As a idd-claude の運用者, I want README の env 一覧で
`DEV_MAX_TURNS` の意味とチューニング指針を理解したい, so that 値の選択が「予算
管理の旋回ねじ」ではなく「タスク粒度の健全性指標」であることを認識できる

#### Acceptance Criteria

1. The README env 一覧 shall `DEV_MAX_TURNS` の項目を持ち、既定値（60）、意味、
   推奨レンジ感を記載する
2. The README env 一覧 shall `DEV_MAX_TURNS` の指針として「多い＝タスクが大き
   すぎる兆候。恒久引き上げより粒度是正を優先」と同等の文面を含める
3. The README env 一覧 shall `DEV_MAX_TURNS` の説明形式・項目構成を、既存の
   `PR_ITERATION_MAX_TURNS` の記載と整合させる
4. The README shall `DEV_MAX_TURNS` の値変更が次回 watcher 起動時から有効になる
   こと、および per-task ループ 1 タスクあたりの上限であって Issue 全体ではない
   ことを明示する
5. The `DEV_MAX_TURNS` の既定値 shall 本 spec 適用後も 60 のままとする（デフォルト
   変更は本 spec のスコープ外）

### Requirement 6: per-task fresh session 仕様の明文化

**Objective:** As a idd-claude の運用者, I want per-task Implementer が
タスクごとに fresh Claude session で起動し、turn 消費がタスク間で累積しない
ことを理解したい, so that 「前のタスクで余った turn を次のタスクに繰り越せる」
という誤解に基づいた粒度設計を避けられる

#### Acceptance Criteria

1. The repo-template の `tasks-generation.md` shall per-task Implementer が
   各タスクで fresh session として起動し、turn 数は各タスクで独立に消費される
   ことを明示する
2. The repo-template の `tasks-generation.md` shall 一度 `error_max_turns` で
   失敗したタスクは、再試行時も同一タスク内で再び 0 turn から開始することを
   明示する
3. The README Troubleshooting 節（または相互リンクで参照可能な箇所）shall
   fresh session 仕様の要約を含み、`error_max_turns` 発生時に「Issue 全体の
   turn 枠を増やす」発想が無効であることを運用者が認識できるようにする

### Requirement 7: tasks 生成の turn 予算ガイドライン

**Objective:** As a Architect エージェントおよび人間設計者, I want tasks.md
を生成する段階で「turn 予算に収まる粒度」を狙えるガイドラインを持ちたい,
so that `error_max_turns` の発生確率を設計段階で抑制できる

#### Acceptance Criteria

1. The repo-template の `tasks-generation.md` shall 「1 つのタスクは
   `DEV_MAX_TURNS`（既定 60）以内に収まる粒度を目安とする」という指針を含む
2. The repo-template の `tasks-generation.md` shall frontend / UI / テスト
   重めのタスクは細かく切るべき旨と、具体的な分割例（例: UI = 1 component +
   1 test = 1 task）を含む
3. The repo-template の `tasks-generation.md` shall 既存のタスク件数ガイド
   ライン（3〜10 件目安）および checkbox 規約と矛盾しない形で追記される
4. The repo-template の `tasks-generation.md` 追記 shall ガイドラインの強度を
   「推奨（指針）」レベルで記述し、機械的な enforcement（reject 条件）として
   は宣言しない
5. The `tasks-generation.md` ガイドライン shall 設計時に turn 予算を意識する
   ことが、運用時の `error_max_turns` 発生確率を下げる旨を、根拠とともに記述する

### Requirement 8: 後方互換の保持

**Objective:** As a 既に idd-claude を導入しているリポジトリの運用者, I want
本 spec の適用が既存の env / ラベル / デフォルト値の意味を変えないことを
保証してほしい, so that ドキュメント変更だけで挙動が壊れる事故を避けられる

#### Acceptance Criteria

1. The 本 spec の成果物 shall 既存の env 変数名（`DEV_MAX_TURNS`,
   `PR_ITERATION_MAX_TURNS`, `DEV_MODEL` 等）の名称・意味・既定値を変更しない
2. The 本 spec の成果物 shall 既存ラベル（`claude-failed`,
   `per-task-implementer-failed`, `ready-for-review` 等）の名称・付与契約・
   遷移の意味を変更しない
3. The 本 spec の成果物 shall 既存の watcher / agent の挙動を変更せず、
   ドキュメント追加・追記のみで完結する
4. The 本 spec の成果物 shall 既存の `repo-template/.claude/rules/tasks-generation.md`
   に記載済みの規約（checkbox 必須化・Budget overflow check・構造化 verify
   ブロック等）を削除・改変しない形で追記される
5. The 本 spec の成果物 shall root の `.claude/rules/tasks-generation.md` と
   `repo-template/.claude/rules/tasks-generation.md` の byte 一致規約
   （CLAUDE.md「二重管理」節）を維持する

## Non-Functional Requirements

### NFR 1: 既存ドキュメントとの整合性

1. The Troubleshooting 節および env 一覧追記 shall README の既存 h2 / h3 階層
   構造を破壊せず、既存セクションの一意性を保つ
2. The 本 spec の成果物 shall 言語方針（CLAUDE.md「言語方針」節）に従い、
   日本語ベースで記述する（識別子・env 変数名・ラベル名等の英語固定語彙は除く）
3. The 本 spec の成果物 shall 既存の Troubleshooting 系記述や `PR_ITERATION_*`
   の説明と語彙・記述スタイルを揃え、運用者が同等の粒度で参照できるようにする

### NFR 2: 発見容易性

1. The Troubleshooting 節 shall README 目次から 2 ホップ以内に到達できる位置に
   配置される
2. The QUICK-HOWTO.md および README shall 双方向の相互リンクを持ち、一方から
   他方へ運用者が 1 クリックで遷移できる
3. The Troubleshooting 節 shall 検索キーワード（`per-task-implementer-failed`,
   `error_max_turns`, `claude-failed`）を見出しまたは本文に含み、運用者が
   ラベル名 / 終了理由文字列でテキスト検索したときに発見できるようにする

### NFR 3: 安全性（破壊操作の回避）

1. The 復旧手順記述 shall ラベル操作の順序（`ready-for-review` を先に付与 →
   `claude-failed` を除去）を実行手順の中で必ず明示する
2. The 復旧手順記述 shall 順序を誤った場合のリスクを警告ブロック（例:
   blockquote / 注意書き）として、手順本文と視覚的に区別できる形で記載する

## Out of Scope

- per-task Implementer ループのロジック変更（自動的なタスク分割、自動的な
  `DEV_MAX_TURNS` 引き上げ、turn 消費の動的調整、累積 turn 制御 等）
- `DEV_MAX_TURNS` のデフォルト値変更（60 を維持）
- watcher / agent 実装コード（`local-watcher/bin/issue-watcher.sh` および
  `.claude/agents/*.md` の挙動）の変更
- 特定リポジトリ（ab-extweb 等）固有の対処手順
- `error_max_turns` 以外の Implementer 失敗モード（panic / OOM 等）に対する
  Troubleshooting 節の追加（必要なら別 Issue で扱う）
- 外部 Feature Flag SaaS / 動的フラグ等の Feature Flag Protocol 拡張
- Triage / Reviewer / Debugger の turn 予算（`TRIAGE_MAX_TURNS` /
  `REVIEWER_MAX_TURNS` / `PR_ITERATION_MAX_TURNS` 等）に関するドキュメント
  改定（DEV_MAX_TURNS 説明の参照整合は保つが、他 env の説明拡充は対象外）

## Open Questions

- **配置先の選択**: Troubleshooting 本体を README 本体に厚めに置くか、
  QUICK-HOWTO.md に簡潔版を主体として置き README を補助とするか。
  本要件では README を一次配置とし、QUICK-HOWTO.md に要約 + 相互リンクを
  置く構成を前提としているが、Architect / 人間レビュアーの判断で簡潔版主体
  への入れ替えが許容される（NFR 2.2 の相互リンク保証を満たす限り）
- **tasks-generation での数値表現の踏み込み度**: 「`DEV_MAX_TURNS`（既定 60）
  以内に収まる粒度」と数値を明示するか、「turn 予算に収まる粒度」と定性表現
  に留めるか。本要件 7.1 では数値明示を採用しているが、将来 `DEV_MAX_TURNS`
  デフォルトが変わると追従コストが生じる懸念があり、design / 実装フェーズで
  再評価する余地を残す
- **将来ロジック改善の派生 Issue**: per-task 自動分割・累積 turn 制御等の
  ロジック改善を、本 Issue から `Split from:` 派生として別 Issue 化するか。
  本 spec のスコープ外であるため要件には含めないが、PjM / 人間が判断する
  事項として残す

## 関連

- Parent: #289
