# Requirements Document

## Introduction

#289 で per-task Implementer ループの `error_max_turns` に対する Troubleshooting と
tasks 生成の turn 予算ガイドラインを **ドキュメント** として整備したが、それは「設計済みの
tasks に対する事後の運用対処」と「Architect / 人間設計者向けの一般的な粒度指針」までで、
**Architect が自己レビューを締めるタイミング**で「過大 task の可能性」を観点として明示的に
点検する手順は規約に含まれていない。実例として、frontend 層を「API クライアント lib(+test) +
複数 component(+test)」のように層対称分割でひと固まりにした task が `error_max_turns` を
踏み抜く事象が観測されている（ab-extweb #8 task 5 等）。本 spec では、Architect の
**設計書 / tasks 自己レビューゲート**に「Task turn 予算 sanity check（過大 task 検出）」を
**観点（指針レベル）**として追加し、tasks 生成段階で過大 task を発見しやすくする。検出は
ドメイン非依存の定性ヒューリスティック寄りで構成し、CI による機械強制や数値閾値の reject
判定は導入しない。既存の Mechanical Checks / traceability / 「最大 2 パス」自己レビュー
ループの挙動は変更しない。

## Requirements

### Requirement 1: Architect 自己レビューへの観点追加（配置）

**Objective:** As a Architect エージェントおよび人間設計者, I want tasks.md 確定直前の
自己レビューで「Task turn 予算 sanity check（過大 task 検出）」を一貫した観点として参照
したい, so that 過大 task を運用前（設計段階）に発見し、`error_max_turns` の発生確率を
下げられる

#### Acceptance Criteria

1. The `design-review-gate.md` shall 「Task turn 予算 sanity check（過大 task 検出）」を
   観点とした節または箇条書きを 1 つ以上含む
2. The `tasks-generation.md` の既存「turn 予算ガイドライン」節 shall 上記 sanity check の
   観点と相互参照されるリンクまたは記述を持つ
3. The `design-review-gate.md` への追記 shall 既存 Mechanical Checks（Requirements
   traceability / File Structure Plan 充填 / orphan component / Budget overflow check /
   checkbox enforcement check / verify block well-formed check）を **削除・改変しない**
   形で行われる
4. The `design-review-gate.md` への追記 shall 既存「レビュー・ループ」節の「最大 2 パスで
   確定」規約および `/goal` 自動ループ運用節を変更しない
5. The 追記された観点 shall Architect が判断レビューの一環として参照することを想定した
   配置（「アーキテクチャ準備レビュー」「実行可能性レビュー」などの判断レビュー側、
   または独立した節）に置かれる

### Requirement 2: 検出シグナル（観点）の明示

**Objective:** As a Architect エージェントおよび人間設計者, I want 過大 task を疑うべき
具体的な観測シグナルを観点として持ちたい, so that 「層対称で分割した」だけで安心せず、
turn コスト密度の観点で再点検できる

#### Acceptance Criteria

1. The 追記された観点 shall 「1 タスクに API クライアント lib(+test) と複数 component(+test)
   等の異種責務が混在しているか」を検出シグナルの 1 つとして列挙する
2. The 追記された観点 shall 「同階層の兄弟タスクと比較して、当該タスクの詳細項目数または
   想定新規ファイル数が突出していないか」を検出シグナルの 1 つとして列挙する
3. The 追記された観点 shall 「1 タスクで新規追加するファイル数が多い場合（目安として 3 件
   以上）に分割を検討する」旨を検出シグナルの 1 つとして列挙する
4. The 追記された観点 shall 「重い子タスクが同一親に複数同居していないか。同居していれば
   最上位 task への昇格を検討する」旨を検出シグナルの 1 つとして列挙する
5. The 追記された観点 shall frontend / UI / テストが重い責務は backend より turn コスト密度
   が高いため、層対称分割ではなく turn コスト密度を意識した分割が望ましい旨を明示する

### Requirement 3: 強度（推奨どまり / 機械 reject しない）

**Objective:** As a idd-claude の保守者, I want 本観点追加が機械強制（CI / Mechanical Check
の reject 条件）に昇格しないことを保証してほしい, so that ドメイン依存性の高い判定で
auto-dev パイプラインを誤 reject させない

#### Acceptance Criteria

1. The 追記された観点 shall 強度を「推奨（指針）」レベルとして明示し、reject 条件として
   宣言しない
2. The 追記された観点 shall `design-review-gate.md` の Mechanical Checks 節には **追加しない**
   （Mechanical Checks は機械的に判定可能な項目に限定するため）
3. The 追記された観点 shall 数値閾値（例: 「ファイル数 3 以上で必ず分割」「兄弟比 N 倍で必ず
   分割」等）を **強制条件としては定義しない**。数値が登場する場合は「目安」と明示する
4. If 観点に該当する task が発見された場合, the Architect shall 当該 task の分割または最上位
   昇格を **検討** し、判断結果（分割するか据え置くか）を design.md / tasks.md に反映する
5. The 追記された観点 shall watcher / agent 実装コード（`local-watcher/bin/issue-watcher.sh` /
   `.claude/agents/*.md`）の挙動変更を伴わない

### Requirement 4: 二重管理規約への準拠（root と repo-template の byte 一致）

**Objective:** As a idd-claude の保守者, I want 本 spec の成果物が root の `.claude/rules/`
と `repo-template/.claude/rules/` の両系統に byte 一致で反映されることを保証してほしい,
so that idd-claude self-hosting と consumer repo の双方で同じ規約が稼働する

#### Acceptance Criteria

1. The 本 spec の成果物 shall `.claude/rules/design-review-gate.md` と
   `repo-template/.claude/rules/design-review-gate.md` の双方に **byte 一致**で反映される
2. The 本 spec の成果物 shall `.claude/rules/tasks-generation.md` と
   `repo-template/.claude/rules/tasks-generation.md` の双方への相互参照追加が必要な場合、
   双方に **byte 一致**で反映される
3. The 本 spec の成果物 shall `diff -r .claude/rules repo-template/.claude/rules` が
   空（exit 0）になることを完了条件に含める
4. The 本 spec の成果物 shall CLAUDE.md「二重管理」節および既存規約に従い、いずれか片系統
   だけの更新を許容しない
5. The 本 spec の成果物 shall `repo-template/CLAUDE.md` のエージェント参照ルール一覧（PM /
   Architect / Developer が参照するルール）を変更しない

### Requirement 5: 既存挙動の非回帰

**Objective:** As a 既に idd-claude を導入しているリポジトリの運用者, I want 本 spec の
適用が既存ルールの判定境界 / トレーサビリティ / 自己レビューループの挙動を変えないことを
保証してほしい, so that ルール追加だけで既存 spec / 既存 PR が壊れる事故を避けられる

#### Acceptance Criteria

1. The 本 spec の成果物 shall 既存 Mechanical Checks（Budget overflow check の 10 / 11 / 13 /
   14 件境界、checkbox enforcement check の判定パターン、verify block well-formed check の
   well-formed 条件）の判定基準を変更しない
2. The 本 spec の成果物 shall 既存 traceability（requirements.md numeric ID → design.md 参照
   → tasks.md `_Requirements:_` の鎖）の規約を変更しない
3. The 本 spec の成果物 shall 既存「最大 2 パス」自己レビューループおよび `/goal` 自動ループ
   運用節の手順を変更しない
4. The 本 spec の成果物 shall 既に main に merge 済みの spec の `design.md` / `tasks.md` に
   対する **遡及的な違反検出を要求しない**（retrofit は本 spec のスコープ外）
5. The 本 spec の成果物 shall 既存 env 変数名（`DEV_MAX_TURNS` 等）・ラベル名
   （`claude-failed` / `per-task-implementer-failed` 等）・既定値の意味を変更しない

### Requirement 6: #289 成果物との役割分担

**Objective:** As a Architect エージェントおよび人間設計者, I want 本 spec の追記内容が
#289 で導入された `tasks-generation.md` 「turn 予算ガイドライン」節と役割を分担して
重複しないことを期待する, so that 同じ規約が 2 箇所に重複してドリフトする事故を避けられる

#### Acceptance Criteria

1. The 本 spec の追記 shall #289 で `tasks-generation.md` に追加された「turn 予算ガイド
   ライン」節（fresh session 仕様 / 粒度指針 / 強度の項）を **削除・改変しない**
2. The 本 spec の追記 shall #289 の「粒度指針（推奨）」と差別化して、Architect 自己レビュー
   時に **どのシグナルで点検するか**（検出観点）を補う形で記述する
3. The 本 spec の追記 shall #289 の `tasks-generation.md` 節と `design-review-gate.md` 追記
   の間で相互リンクを設け、運用者がいずれの起点からも他方に到達できるようにする
4. The 本 spec の追記 shall README / QUICK-HOWTO の `error_max_turns` Troubleshooting 節
   （#289 で追加）を変更しない

## Non-Functional Requirements

### NFR 1: 既存ドキュメント構造との整合性

1. The 追記内容 shall `design-review-gate.md` および `tasks-generation.md` の既存 h2 / h3
   階層構造を破壊せず、既存節の一意性を保つ
2. The 追記内容 shall CLAUDE.md「言語方針」に従い、日本語ベースで記述する（識別子・env 変数名・
   ラベル名・EARS トリガーキーワード等の英語固定語彙は除く）
3. The 追記内容 shall 既存 Mechanical Checks 節と語彙・記述スタイルを揃え、Architect が
   同等の粒度で参照できるようにする

### NFR 2: 発見容易性

1. The 追記された観点 shall `design-review-gate.md` の目次（h2 / h3 の見出し階層）から
   2 ホップ以内で到達できる位置に配置される
2. The 追記された観点 shall `tasks-generation.md` 「turn 予算ガイドライン」節からの相互
   リンクを持ち、tasks 生成時の起点からも 1 ホップで参照できる
3. The 追記された観点 shall 検索キーワード（`turn 予算` / `過大 task` / `sanity check`）の
   いずれかを見出しまたは本文に含み、運用者がテキスト検索で発見できるようにする

### NFR 3: ドキュメント変更のみで完結（実装挙動の非変更）

1. The 本 spec の成果物 shall watcher / agent / install スクリプト / GitHub Actions
   workflow の挙動を変更せず、ルール markdown への追記のみで完結する
2. The 本 spec の成果物 shall idd-claude が稼働する Claude Code バージョン（v2.1.139 未満
   含む）に依存した必須機能を追加しない（既存後方互換規約を踏襲）

## Out of Scope

- 過大 task 検出の **CI / Mechanical Check による reject 強制**（数値閾値強制を含む）
- watcher / agent 実装コード（`local-watcher/bin/issue-watcher.sh` および
  `.claude/agents/*.md`）の挙動変更
- 過大 task の **自動分割ロジック**、自動 `DEV_MAX_TURNS` 引き上げ、累積 turn 制御
- `DEV_MAX_TURNS` のデフォルト値変更（60 を維持）
- 既に main に merge 済みの spec / tasks.md への遡及適用（retrofit）
- README / QUICK-HOWTO の Troubleshooting 節への追記（#289 の役割であり本 spec のスコープ外）
- 特定リポジトリ（ab-extweb 等）に固有の事例記述を **規約本文の必須要素として要求すること**
  （事例引用の可否は Open Questions で扱う）
- Triage / Reviewer / Debugger 等 Architect 以外のエージェントの自己レビューゲート変更

## Open Questions

- **配置先の選択（Issue 委ね事項 a）**: 本観点を (i) `design-review-gate.md` のみに配置し
  `tasks-generation.md` から相互参照、(ii) `tasks-generation.md` のみに観点として置き
  `design-review-gate.md` から相互参照、(iii) 両方に本体を二重掲載、のいずれにするか。
  本要件では **(i) を暫定方針**として採用する（Architect 自己レビュー時点が一次トリガー
  であり、`design-review-gate.md` を本体にして `tasks-generation.md` から相互参照する形で
  ドリフトを最小化する）。Architect / 人間レビュアーの判断で (ii) / (iii) への切り替えを
  許容する（Req 1.1 / 1.2 の相互参照保証を満たす限り）
- **数値例の踏み込み度（Issue 委ね事項 b）**: 「ファイル数 3 以上」「兄弟比 N 倍」等の数値を
  観点本文に **目安として明記**するか、定性表現（「突出していないか」）に留めるか。本要件
  では Req 2.3 で「目安として 3 件以上」を採用し、Req 3.3 で「強制条件としては定義しない」
  と緩めている。design / 実装フェーズで再評価する余地を残す（#289 と同様、将来
  `DEV_MAX_TURNS` 既定が変わった際の追従コストとのバランスを考慮）
- **ab-extweb #8 task 5 事例引用の可否（Issue 委ね事項 c）**: 規約本文に specific repo
  （ab-extweb）の事例を引用するか否か。本要件では Out of Scope に列挙したとおり、
  **特定 repo の事例を規約本文の必須要素としては要求しない**ことを暫定方針とする
  （OSS テンプレートとしての汎用性を優先）。Architect / 人間レビュアーの判断で「設計判断の
  motivating example」として匿名化または一般化した形で言及する余地は残す
- **`design-review-gate.md` 配下の節タイトル**: 暫定的に「Task turn 予算 sanity check
  （過大 task 検出）」を Issue タイトルから踏襲しているが、最終的な節名は Architect の
  裁量で調整可能（NFR 2.3 の検索キーワード保有を満たす限り）

## 関連

- Parent: #289
- Related: #289
