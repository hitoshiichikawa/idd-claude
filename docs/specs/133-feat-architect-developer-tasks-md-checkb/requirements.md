# Requirements Document

## Introduction

`local-watcher/bin/issue-watcher.sh` の Stage A prompt は、`IMPL_RESUME_PROGRESS_TRACKING=true`
（#67 / #112 以降の既定）の下で Developer エージェントに「`tasks.md` の `- [ ]` checkbox を
`- [x]` に書き換えることで進捗を表現する」という規約を要請している。一方、`.claude/rules/tasks-generation.md`
は checkbox を含む基本フォーマットを提示しているものの、Architect の自己レビューゲート
（`.claude/rules/design-review-gate.md`）には checkbox 有無の機械的検証が無く、Architect が
markdown header のみ（例: `## T-01: タスク名`）の `tasks.md` を出力するケースを排除できない。

実際に hitoshiichikawa/KeyNest#91 では `tasks.md` が checkbox 無しで生成されたため、Developer の
resume 機能が機能せず、Developer は内部の TaskCreate / TaskUpdate ツールで進捗を二重管理し
（全 tool call の 29%）、turn budget を浪費した。本要件では、`tasks.md` の checkbox 形式を
Architect 側で必須化し、Mechanical Check で enforce することで、Developer が markdown 上の
checkbox のみで進捗を表現できる前提を確実に成立させる。

## Requirements

### Requirement 1: tasks.md の checkbox 形式必須化（ルール側）

**Objective:** As an Architect agent, I want tasks.md の各タスク行が必ず checkbox を持つ規約として明文化された rule を参照できる, so that markdown header のみのタスク表現を生成せず、Developer の resume 機能が機能する前提を満たす

#### Acceptance Criteria

1. The `tasks-generation.md` shall すべての実装タスク行が `- [ ]` または `- [ ]*`（deferrable 印）の checkbox 形式で開始することを必須要件として明示する
2. The `tasks-generation.md` shall markdown header のみ（例: `## T-01:` / `### Task 1`）でタスクを表現することを禁止する旨を明文化する
3. The `tasks-generation.md` shall 親タスク行・子タスク行のいずれにも checkbox を付与することを規定する
4. Where deferrable テストタスクである場合, the `tasks-generation.md` shall checkbox を `- [ ]*`（アスタリスク付き）で記述する既存規約を維持する
5. The `tasks-generation.md` shall タスク ID は numeric 階層 ID（`1`, `1.1`, `2.1` 等）のみを使用し、`T-01` / `FR-01` 等の英字 ID は使用しない旨の既存規定を維持する

### Requirement 2: Architect 自己レビューでの checkbox enforcement（Mechanical Check）

**Objective:** As an Architect agent, I want tasks.md の checkbox 形式違反を Mechanical Check で機械的に検出できる, so that ドラフト確定前に違反を是正でき、Developer に checkbox 不在の tasks.md が渡らない

#### Acceptance Criteria

1. The `design-review-gate.md` shall Mechanical Checks セクションに「`tasks.md` のすべてのタスク行が checkbox 形式で開始すること」を確認する項目を追加する
2. When Architect が `tasks.md` ドラフトを自己レビューするとき, the Mechanical Check shall checkbox を持たないタスク行（markdown header のみで表現された行など）を 1 件でも検出した場合に違反として報告する
3. If Mechanical Check で checkbox 不在のタスク行が検出された場合, the Architect shall 該当行を `- [ ] <numeric ID>. <タスク名>` 形式に修正してから確定する
4. The `design-review-gate.md` shall checkbox 検出に使用する判定パターン（行頭が `- [ ]` または `- [ ]*` で始まる行をタスク行と認識する規約）を参照可能な形で記載する
5. The `design-review-gate.md` shall 本 Mechanical Check と既存の Budget overflow check（最上位タスク件数判定）が同一の checkbox 規約に依拠していることを明示する

### Requirement 3: Architect エージェント定義の整合更新

**Objective:** As an Architect agent, I want エージェント定義ファイル内のテンプレートと品質チェック項目が checkbox 必須規約と整合している, so that テンプレートからの逸脱で checkbox 不在の tasks.md を生成しない

#### Acceptance Criteria

1. The `architect.md` shall `tasks.md` テンプレート例の全タスク行が `- [ ]` または `- [ ]*` の checkbox 形式で始まることを保ち、markdown header のみのタスク例を含まない
2. The `architect.md` shall 自己レビューの品質チェックリストに「全タスク行が checkbox 形式である」項目を含める
3. The `architect.md` shall Developer が `- [ ]` → `- [x]` で進捗を表現する前提を維持するために checkbox 形式が必須である理由を 1 行以上で説明する

### Requirement 4: Developer エージェント定義の整合更新

**Objective:** As a Developer agent, I want エージェント定義が tasks.md の checkbox を編集することで進捗を表現する規約を明示している, so that 内部 TaskCreate / TaskUpdate での二重管理ではなく markdown checkbox 編集で進捗を表現できる

#### Acceptance Criteria

1. The `developer.md` shall タスク完了時に該当タスク行の `- [ ]` を `- [x]` に書き換えることでタスク完了を表現する規約を明示する
2. The `developer.md` shall タスク完了マーカーの更新は実装 commit とは別の独立した commit（既存規約: `docs(tasks): mark <task-id> as done`）で行う既存規約を維持する
3. While `IMPL_RESUME_PROGRESS_TRACKING=true` の状態, the `developer.md` shall 進捗表現の手段として markdown checkbox 編集を採用し、hidden marker や内部 TaskCreate / TaskUpdate を進捗の正本としては用いない旨を明示する
4. The `developer.md` shall checkbox 書き換えで許容される差分が「`- [ ]` ↔ `- [x]` の行内 4 文字差分のみ」である既存規約を維持する

### Requirement 5: 後方互換性と既存 spec 資産の扱い

**Objective:** As a repository maintainer, I want 既に merge 済みの spec（過去の tasks.md）に対して破壊的影響を与えない, so that 本ルール強化が既存 PR / ブランチ / Issue を遡及的に壊さない

#### Acceptance Criteria

1. The Mechanical Check shall 本機能の対象を「Architect が新規に生成・編集する `tasks.md`」に限定し、既存 merged spec の `tasks.md` に対する遡及的なルール違反検出は要求しない
2. The Mechanical Check shall 既存の deferrable テストタスク表記（`- [ ]*`）を有効な checkbox 形式として扱い、違反として報告しない
3. While 本機能のルール強化が main に取り込まれた後, the Mechanical Check shall ≤ 10 件の正常ケースを含む既存挙動を変化させない（Budget overflow check の判定境界には影響しない）
4. The repository maintainer shall 既存 merged spec の retrofit（過去の tasks.md への checkbox 後付け）を本要件のスコープに含めない

## Non-Functional Requirements

### NFR 1: 言語・基盤非依存性とドキュメント整合性

1. The `tasks-generation.md` / `design-review-gate.md` / `architect.md` / `developer.md` shall 既存の他ルール（EARS / requirements-review-gate / design-principles / feature-flag）と矛盾する記述を含まない
2. The 更新後のルール群 shall 言語非依存（特定の実装言語に依存しない記述）であることを保つ
3. The `design-review-gate.md` shall checkbox enforcement の Mechanical Check 項目を、既存 3 項目（Requirements traceability / File Structure Plan / orphan component）と Budget overflow check と並列に列挙可能な粒度で記述する

### NFR 2: 検証可能性

1. The Mechanical Check 規約 shall 第三者（人間レビュワーや別エージェント）が `tasks.md` を読んで checkbox 有無を 1 分以内に機械的に判定できる程度の明確さを持つ
2. The 判定パターン shall POSIX 互換 ERE で表現可能な regex（例: `^- \[[ x]\]\*? [0-9]+\.`）で機械検証できることを保つ

## Out of Scope

- Developer の内部 TaskCreate / TaskUpdate ツール呼び出しの **ハード制限**（#132 サブ #B として別 Issue で扱う）
- parallel tool call 規律の見直し（#132 サブ #C として別 Issue で扱う）
- batch commit（複数タスク完了マーカーを 1 commit にまとめる）の許容（本要件では既存規約「マーカー更新は実装 commit と分けて 1 タスク = 1 commit」を維持）
- 既存 merged spec の `tasks.md` への checkbox 後付け（retrofit）作業
- `IMPL_RESUME_PROGRESS_TRACKING` の値変更や env 名の改名
- watcher Stage A prompt 自体の改修（本要件は rule / agent 定義側の整合確保が主目的で、prompt 改修は不要）
- 外部 task tracker（GitHub Projects / Linear / Jira 等）との連携や自動 sync
- checkbox 以外の進捗表現手段の導入（hidden marker / 別ファイル進捗ログ等）

## Open Questions

Issue #133 本文の「確認事項」3 項目は、現時点で人間からの追加コメントが付いていない。PM
判断として暫定 stance を以下に示す（後段の Architect / Developer の判断材料）:

1. **checkbox 番号体系の統一**（numeric 階層 ID vs `T-01` 混在）
   - **暫定 stance**: 既存 `tasks-generation.md` の「numeric 階層 ID のみ使用、`T-01` / `FR-01` は不可」既定を維持し、混在を許容しない。Mechanical Check では「行頭 `- [ ]` の直後に numeric ID（`[0-9]+(\.[0-9]+)*\.`）が来ること」を必須化する方向で、Architect が design / tasks 整合性を確保しやすい統一表記を採る
   - **判断委任先**: Architect（具体的な regex / 検出パターンは design.md で確定）

2. **既存 merged spec の retro fit 要否**
   - **暫定 stance**: retrofit は **本要件のスコープ外**（Out of Scope に明記）。既存 merged spec の tasks.md は当時の合意済み成果物であり、遡及的な書き換えは git 履歴の追跡性を損ねる。新規生成・編集される tasks.md のみを Mechanical Check の対象とする
   - **判断委任先**: 人間運用者（必要なら別 Issue として retrofit を起票）

3. **per-task commit の負荷（batch commit 許容否）**
   - **暫定 stance**: 既存 `developer.md` の「マーカー更新は実装 commit と分けて `docs(tasks): mark <task-id> as done` で commit」を維持し、batch commit は許容しない。理由: (a) #67 / #112 で確立した resume 機能の挙動と整合させる必要がある、(b) 1 task = 1 marker commit の方が PR 上での進捗可視性が高い、(c) 本 Issue のスコープは checkbox 必須化であり、commit 粒度の変更は範囲外
   - **判断委任先**: Architect（commit メッセージテンプレートの細部は design.md で確定可能）

なお、これらの暫定 stance は requirements.md 自身の AC として束縛しない方針とし、AC 5.4 で
「retrofit はスコープ外」のみを明示している。Architect は上記 stance を踏まえつつ、必要に
応じて Issue コメントで人間判断を仰いで構わない。
