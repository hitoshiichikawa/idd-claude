# Requirements Document

## Introduction

idd-claude の watcher（`STAGE_CHECKPOINT_ENABLED=true` 既定）は、同一 head ブランチに紐づく
既存 impl PR を観測して resume 地点（Stage A/B/C/TERMINAL_OK/TERMINAL_FAILED）を決定する。
現状の `stage_checkpoint_find_impl_pr` および resume 地点決定ロジックは、`MERGED` 状態の
impl PR が 1 件でも存在すると、対象 Issue がまだ OPEN（reopen 含む）でかつ `tasks.md` に
未チェックタスク（`- [ ]`）が残存していても、当該 Issue を `TERMINAL_OK` で停止させてしまう。

実際の事故（Issue #261 / PR #271）では、Architect が分割した複数タスクの一部のみを実装した
部分実装 PR が、PR 本文に `Closes #261` を含んだまま merge され、Issue が auto-close された
結果、人間が Issue を reopen して残タスクを進めようとしても watcher が「MERGED PR があるので
完了」と判定し、残タスクが永久に着手不能になった。Issue #265 では同じカテゴリの取りこぼし
（CLOSED 未マージ PR）が修正されているが、MERGED PR 経由の取りこぼしは未対応である。

本要件は、(1) 部分実装 PR を merge しても Issue が誤って auto-close されないようにする
運用規約の明文化と、(2) 万一 auto-close されて人間が reopen した場合でも、tasks.md に
未チェックタスクが残存しているなら watcher が resume を継続できるガード改善を扱う。

## Requirements

### Requirement 1: 部分実装 PR と最終 PR を Refs / Closes で区別する PR 本文規約

**Objective:** As an idd-claude 運用者, I want PjM が作成する impl PR の本文で「対応 Issue」
記法を「部分実装 PR は `Refs #N`」「最終 PR のみ `Closes #N`」と使い分けること, so that
GitHub の auto-close 機能で残タスクが残る Issue が誤って close されない

#### Acceptance Criteria

1. When PjM が implementation モードで impl PR の本文を生成し、対応する `tasks.md` に
   未チェック（`- [ ]` 形式）の最上位タスクが本 PR の変更後も残存しているとき, the
   Project Manager Agent shall PR 本文の「対応 Issue」セクションを `Refs #<issue-number>`
   形式で記述する
2. When PjM が implementation モードで impl PR の本文を生成し、対応する `tasks.md` の
   全最上位タスクが本 PR の変更で完了する（または `tasks.md` が存在せず Issue 全体を 1 PR
   で完了させる design-less impl である）とき, the Project Manager Agent shall PR 本文の
   「対応 Issue」セクションを `Closes #<issue-number>` 形式で記述する
3. While PjM が PR 本文を確定する直前, the Project Manager Agent shall 本要件 1.1 / 1.2
   の判定根拠（残タスク件数または design-less impl 判定）を PR 本文の「確認事項」または
   PR コメントに 1 行記載する
4. The Project Manager Agent 用エージェント定義は、root の `.claude/agents/project-manager.md`
   と `repo-template/.claude/agents/project-manager.md` の両系統で本規約を同一内容で
   明文化する
5. The `README.md` shall 部分実装 PR と最終 PR の `Refs` / `Closes` 使い分け規約を
   ワークフロー説明節に明文化する

### Requirement 2: OPEN かつ未チェックタスク残存時の MERGED PR 非 terminal 化

**Objective:** As an idd-claude 運用者, I want watcher が「対象 Issue が OPEN
（reopen 含む）かつ `tasks.md` に未チェックタスクが残存する」状態で MERGED 既存 impl PR を
観測したとき、その MERGED PR を resume 停止根拠として採用しない挙動, so that 部分実装 PR が
誤って `Closes` で merge され Issue が auto-close された場合でも、reopen 後に残タスクが
自動再開できる

#### Acceptance Criteria

1. When watcher が同一 head ブランチに紐づく既存 impl PR を観測し、state が `MERGED` の
   PR が 1 件以上存在し、対象 Issue の state が `OPEN` で、かつ対応する `tasks.md` に
   未チェックタスク（`- [ ]` で始まる最上位 numeric ID タスク行）が 1 件以上残存している
   とき, the Stage Checkpoint Module shall 当該 MERGED PR を resume 地点判定の停止根拠
   として採用しない
2. When 本要件 2.1 の条件が成立し watcher が MERGED PR を非 terminal 扱いとしたとき, the
   Stage Checkpoint Module shall resume 地点判定を「既存 impl PR なし」と等価に扱い後段の
   checkpoint（impl-notes.md / review-notes.md）の評価へ進む
3. When 対象 Issue の state が `CLOSED` であるとき, the Stage Checkpoint Module shall
   MERGED PR を本要件導入前と同一に terminal（`TERMINAL_OK`）として採用する
4. When 対応する `tasks.md` が存在しない（design-less impl）か、または `tasks.md` の全
   最上位タスクが完了済み（`- [x]`）であるとき, the Stage Checkpoint Module shall MERGED
   PR を本要件導入前と同一に terminal（`TERMINAL_OK`）として採用する
5. When 同一 head ブランチに `OPEN` の impl PR が存在するとき, the Stage Checkpoint Module
   shall 本要件導入前と同一に当該 OPEN PR を最優先で採用し MERGED PR / Issue state /
   tasks.md の状態評価を行わない

### Requirement 3: 判定入力の取得と失敗時の安全側フォールバック

**Objective:** As an idd-claude 運用者, I want 新しい判定で必要となる「Issue state」と
「tasks.md の未チェックタスク件数」の取得が失敗・不確定な場合でも watcher が安全側
（既存挙動と同等の TERMINAL_OK 採用）に倒れる挙動, so that 新規ガードによる regression
（取得失敗時の無限ループ・誤再開）が発生しない

#### Acceptance Criteria

1. When watcher が対象 Issue の state を取得する API 呼び出しに失敗したとき, the Stage
   Checkpoint Module shall MERGED PR を本要件導入前と同一に terminal（`TERMINAL_OK`）と
   して採用する
2. When watcher が対応する `tasks.md` を読み取れない（ファイル不在ではなく I/O 失敗等）
   とき, the Stage Checkpoint Module shall MERGED PR を本要件導入前と同一に terminal
   （`TERMINAL_OK`）として採用する
3. The Stage Checkpoint Module shall 対応する `tasks.md` の探索先を、対象 Issue 番号に
   一致する `docs/specs/<番号>-<slug>/tasks.md` ディレクトリ規約のもとで 1 件に解決し、
   解決不能（spec ディレクトリ不在）なら design-less impl と同等に扱う

### Requirement 4: 観測可能性と判定根拠ログ

**Objective:** As an idd-claude 運用者, I want MERGED PR を非 terminal として扱った場合と
従来どおり terminal として扱った場合の判定根拠が既存ログ書式で grep 可能であること, so that
事故再発時の原因追跡と新規ガードの動作確認が後追いで行える

#### Acceptance Criteria

1. When watcher が MERGED PR を Requirement 2 のもとで非 terminal 扱いとしたとき, the
   Stage Checkpoint Module shall 判定根拠ログを既存の `stage-checkpoint:` prefix で
   1 行以上出力し、当該 PR 番号 / Issue state / 残未チェックタスク件数 / 判定結果が
   識別可能な内容にする
2. When watcher が MERGED PR を本要件導入前と同一に terminal として扱ったとき, the Stage
   Checkpoint Module shall 既存 Decision Table のログ（`decision: START_STAGE=TERMINAL_OK
   reason=...`）を本要件導入前と同等の書式で出力する
3. The Stage Checkpoint Module shall 本要件で追加する判定根拠ログを既存ログ書式と整合する
   `[YYYY-MM-DD HH:MM:SS] stage-checkpoint:` 形式で出力し、grep 抽出可能な状態を保つ

### Requirement 5: 既存挙動の後方互換

**Objective:** As an idd-claude 運用者, I want Issue #265（CLOSED PR 非 terminal 化）/
#212（Stage C CLOSED ガード）/ #219（越境観測・spec 完全性ガード）由来の既存挙動と OPEN PR
優先採用ルールが本要件導入前と完全に同一であること, so that 既に main で稼働中の冪等ガードと
判定経路が regression しない

#### Acceptance Criteria

1. When 同一 head ブランチに `CLOSED` 未マージ impl PR のみが存在するとき, the Stage
   Checkpoint Module shall Issue #265 で導入された除外判定を本要件導入前と同一に適用する
2. When Stage A 完了直後の越境観測ヘルパが先行 impl PR の存在を観測するとき, the Stage
   Checkpoint Module shall `OPEN` および `MERGED` の PR を本要件導入前と同一の規則で越境
   として記録する
3. When spec 成果物完全性ガードが先行 impl PR の state を取得して補完起動条件を判定する
   とき, the Spec Completeness Guard shall `MERGED` PR を本要件導入前と同一の規則で
   docs-only 補完追従 PR 起動条件として扱う
4. While `STAGE_CHECKPOINT_ENABLED=true` 以外の値（明示的な opt-out 含む）が設定されている
   とき, the Stage Checkpoint Module shall 本要件で追加する判定変更を含めて 1 行も実行せず
   本機能導入前と完全に同一の挙動を保つ

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Stage Checkpoint Module shall 既存環境変数名（`STAGE_CHECKPOINT_ENABLED`）と既定値
   （未設定または `true` で有効）を本要件導入前と同一に保ち、新規 env var を追加しない
2. The Auto-Development Pipeline shall 既存ラベル名（`claude-failed` / `needs-decisions` /
   `claude-claimed` / `claude-picked-up`）と Issue 候補抽出のフィルタ規則を本要件導入前と
   同一に保つ
3. The Stage Checkpoint Module shall 対象 Issue が `CLOSED` 状態の全ケースで本要件導入前と
   挙動を変えない（auto-close 済みの完了 Issue を再開対象に変えない）
4. The Project Manager Agent shall 本要件 1 で追加する `Refs` / `Closes` 使い分け規約以外の
   既存 PR 本文テンプレート構造（セクション順・必須項目）を本要件導入前と同一に保つ

### NFR 2: 観測性

1. The Stage Checkpoint Module shall MERGED PR 非 terminal 判定の根拠ログを既存の
   `stage-checkpoint:` prefix ログと同一の 3 段書式（`[YYYY-MM-DD HH:MM:SS]
   stage-checkpoint: ...`）で 1 サイクル 1 ブロック内に収め、複数サイクルで grep 抽出
   できる状態を保つ

### NFR 3: 冪等性

1. While 同一 Issue を複数サイクル連続で watcher が処理し、MERGED 既存 impl PR / Issue
   state / `tasks.md` の未チェックタスク件数のいずれも変化しないとき, the Auto-Development
   Pipeline shall 同一 MERGED PR に対するコメント投稿・ラベル付与・再 open 操作・再 merge
   操作のいずれも複数回発火させない
2. While watcher が MERGED PR を非 terminal として扱った結果として Stage A から再開する
   とき, the Auto-Development Pipeline shall 既存 MERGED PR に対する副作用（コメント /
   ラベル / state 変更）を持たない read-only 観測のみを行う

### NFR 4: ドキュメント二重管理整合

1. The repository shall root の `.claude/agents/project-manager.md` と
   `repo-template/.claude/agents/project-manager.md` を本要件 1 の規約追記後も byte 一致で
   保ち、`diff -r .claude/agents repo-template/.claude/agents` が空である状態を維持する

## Out of Scope

- 既に main に merge 済みの過去 impl PR 本文を遡及的に書き換える retrofit
  （`Closes` → `Refs` への遡及訂正は本要件のスコープ外）
- 既に auto-close されてしまった過去 Issue の自動 reopen 機能
  （reopen は人間運用者の操作とし、watcher 側からの自動 reopen は行わない）
- MERGED PR の本文・差分・コメントの解析や引き継ぎ（次サイクルは Stage A から作業を
  やり直す前提で、既存 MERGED PR の内容を resume の入力として利用しない）
- 環境変数による「MERGED PR を常に terminal とみなす旧挙動を選択する」opt-out gate の
  新規追加（人間が方針 Option A を選択済みで、旧挙動が必要な運用ケースが Issue 上で
  確認されていないため）
- per-task ループ（Issue #21 / #251）の残必須タスク検出ロジックそのものの変更
  （本要件は `tasks.md` の `- [ ]` 残存有無を入力として使うのみで、per-task ループの
  進捗追跡規約自体は変更しない）
- design-less impl（`tasks.md` 不在）ケースで MERGED PR が観測された場合の判定変更
  （Requirement 2.4 のとおり design-less impl は本要件導入前と同一に terminal 扱いを
  維持する。stage-a-verify gate と同様、`tasks.md` を入力に持たない経路では追加判定を
  行わない）
- Issue #212 由来の Stage C CLOSED ガード経路（`needs-decisions` 付与経路）の変更
- spec 成果物完全性保証（Issue #219）の docs-only 補完起動条件の変更
- `repo-template/CLAUDE.md` および consumer repo 配布版 README の文言変更
  （本要件は idd-claude self-hosting の運用規約改善が主目的で、consumer repo への
  影響は project-manager.md 経由の規約配布で足りるため、`README.md` 更新は本 repo 内に
  限定する）

## Open Questions

なし
