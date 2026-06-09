# Requirements Document

## Introduction

per-task ループの terminal failure 経路（`per-task-reviewer-reject2` / `per-task-reviewer-reject3`
/ `per-task-reviewer-error` / `per-task-reviewer-missing-file` / `debugger-notes-invalid` 等）では、
Issue に投稿される失敗コメントが実装 branch と `review-notes.md` / `debugger-notes.md` を参照する
にもかかわらず、watcher が push state を verify せず artifact 保全も行わないため、operator が
remote branch を確認しても reviewer / debugger の診断成果物が見つからず、復旧起点を特定できない
状況が発生している。本機能は、Reviewer / Debugger サブエージェントへの git 権限付与を禁じた
まま、watcher 側が terminal failure 直前に push 状態を verify し、未追跡 / 未 push の診断
artifact を Issue コメントまたは diagnostic commit として operator-visible に保全することで、
失敗復旧の混乱を解消する。

## Requirements

### Requirement 1: per-task terminal failure 時の診断 artifact 保全

**Objective:** As a 自動開発の運用者, I want per-task terminal failure 直後に reviewer / debugger
の診断成果物に Issue コメントだけからアクセスできること, so that 失敗の根本原因調査と復旧判断を
unpushed worktree に依存せず行える

#### Acceptance Criteria

1. When per-task ループが Reviewer または Debugger が `review-notes.md` / `debugger-notes.md` を
   書き出した後の terminal failure（`per-task-reviewer-reject2` / `per-task-reviewer-reject3` /
   `per-task-reviewer-error` / `per-task-reviewer-missing-file` / `debugger-notes-invalid` を含む）
   で停止する場合, the watcher shall 同一 Issue に投稿する失敗コメントに `review-notes.md` /
   `debugger-notes.md` の本文または要約を埋め込むか、もしくはそれらを含む diagnostic commit を
   origin branch に push してから claude-failed ラベルを付与する
2. If terminal failure 発生時点で `review-notes.md` または `debugger-notes.md` が worktree 上に
   存在し、かつ tracked かつ pushed 済み（local HEAD と origin branch HEAD が一致）である,
   the watcher shall artifact の重複保全（コメント埋め込みおよび diagnostic commit）を行わず
   既存挙動と同じ失敗コメントを投稿する
3. If terminal failure 発生時点で `review-notes.md` または `debugger-notes.md` が untracked
   または未 commit である, the watcher shall それらの本文（または長文時は要約）を Issue コメント
   に埋め込むか、watcher 自身が diagnostic commit を作成して origin に push する
4. If watcher が diagnostic commit の push に失敗する, the watcher shall fallback として
   `review-notes.md` / `debugger-notes.md` の本文または要約を Issue コメントに埋め込んで
   claude-failed ラベルを付与する
5. The watcher shall artifact 保全処理の失敗を理由に claude-failed ラベル付与と失敗コメント
   投稿の責務を放棄しない

### Requirement 2: terminal failure 時の push state 情報の可視化

**Objective:** As a 自動開発の運用者, I want terminal failure 失敗コメントから現在の git push 状態
を一目で把握できること, so that 復旧時に確認すべき branch / worktree / SHA をローカル調査せず
特定できる

#### Acceptance Criteria

1. When per-task terminal failure が発生する, the watcher shall 失敗コメントに以下の項目を
   すべて明記する: 実装 branch 名 / local HEAD SHA / origin branch HEAD SHA / ahead count
   （local が origin より進んでいる commit 数）/ worktree 絶対パス
2. When `review-notes.md` または `debugger-notes.md` を失敗コメント内で参照する, the watcher
   shall それぞれの artifact が tracked か untracked か、pushed か unpushed か（ahead 状態を
   含む）を artifact 単位で明示する
3. If origin branch がまだ存在しない（初回 push 前である）, the watcher shall origin branch
   HEAD SHA の欄を「未 push」相当の固定表記で埋め、ahead count を local HEAD までの commit 数
   として算出する
4. The watcher shall 上記 push state 情報を per-task terminal failure 全カテゴリで一貫した
   フォーマットで出力する

### Requirement 3: Reviewer / Debugger サブエージェントの git 権限境界の維持

**Objective:** As a idd-claude メンテナ, I want Reviewer / Debugger サブエージェントが破壊的な
git / gh 操作を行わない状態を維持できること, so that 役割逸脱と worktree の破壊リスクを増やさず
本機能を導入できる

#### Acceptance Criteria

1. The Reviewer subagent shall `git add` / `git commit` / `git push` / `gh` を実行する権限を
   付与されない
2. The Debugger subagent shall `git add` / `git commit` / `git push` / `gh` を実行する権限を
   付与されない
3. When 診断 artifact の commit / push が必要になる, the watcher shall サブエージェントの
   return 後に watcher / orchestrator プロセスがその責務を担う
4. The watcher shall 診断 artifact 保全のために `git reset` / `git rebase` / force push を
   実行しない

### Requirement 4: terminal failure 経路間の push state verify 一貫性

**Objective:** As a idd-claude メンテナ, I want per-task と非 per-task の terminal failure 経路で
push state verify の意味論が乖離しないこと, so that 失敗時の挙動が経路に依らず予測可能になる

#### Acceptance Criteria

1. When per-task ループが terminal failure 分岐に入る, the watcher shall 既存の Stage A /
   Stage B 経路で利用されている push リトライ機構と意味論的に整合する形で push state を
   verify する（claude-failed ラベル付与の前に push state を確認する）
2. If push リトライ機構の自動 push が失敗する, the watcher shall 既存 Stage A / Stage B の
   失敗ハンドリングと同じく claude-failed ラベルを付与し失敗コメントを投稿する
3. The watcher shall 既存の非 per-task terminal failure 経路の挙動を本機能導入前と同一に保つ

### Requirement 5: 回帰テストによる挙動の固定

**Objective:** As a idd-claude メンテナ, I want per-task terminal failure 時の artifact 保全挙動
を回帰テストで固定できること, so that 将来のリファクタで silent regression が発生しても検知できる

#### Acceptance Criteria

1. The Test suite shall `per-task-reviewer-reject3` 形状の terminal failure を再現するシナリオを
   含み、`review-notes.md` および `debugger-notes.md` が untracked な状態を入力として用意する
2. The Test suite shall 上記シナリオで失敗コメントに artifact 本文／要約が埋め込まれること、
   または diagnostic commit が push されたことのいずれかが成立することを assert する
3. The Test suite shall 上記シナリオで失敗コメントに branch 名 / local HEAD SHA / origin
   branch HEAD SHA / ahead count / worktree path が含まれることを assert する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The watcher shall 既に claude-failed 経路を通過した既存 Issue / 既存 cron 登録 / 既存 env var
   名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` 等）の意味を変更しない
2. The watcher shall 本機能導入前に terminal failure コメントを生成していた経路の出力フォーマット
   に対し、Requirement 2 で定める追加情報の append のみを行い、既存の必須項目（ログパス /
   復旧ヒント / 手動復旧手順）を削除しない

### NFR 2: 失敗時の堅牢性

1. If artifact 保全処理（本文読み込み / 要約生成 / commit / push / コメント投稿）の途中で
   想定外のエラーが発生する, the watcher shall claude-failed ラベルを付与する責務を最後まで
   完遂する（silent fail を作らない）
2. The watcher shall artifact 保全処理のエラーを `$LOG` に grep 可能な形で記録する

### NFR 3: コメントサイズ上限

1. When `review-notes.md` または `debugger-notes.md` の本文が GitHub Issue コメント本文の
   実用上限（65,536 文字）を超える可能性がある, the watcher shall 本文をそのまま埋め込まず
   要約または抜粋（先頭・末尾の固定行数）に切り替えて埋め込む

## Out of Scope

- Reviewer / Debugger サブエージェントへの `git add` / `git commit` / `git push` / `gh` 権限の付与
- `git reset` / `git rebase` / force push の追加
- 失敗コメントへの watcher 実行ログ全文の貼り付け
- terminal failure の retry policy 変更（リトライ回数の増減 / 自動再起動の追加）
- per-task 以外の terminal failure 経路（Stage A / Stage B / design / triage 等）の挙動変更
- Reviewer / Debugger 起動回数制限の変更

## Open Questions

- 推奨方針（選択肢 1: コメント埋め込み / 選択肢 2: watcher diagnostic commit / 選択肢 3:
  両方）のうちどれを採用するかは `design.md` で決定する。Requirement 1.1 はいずれの選択肢でも
  満たせるよう「埋め込みまたは diagnostic commit」の OR で AC を記述しているため、設計段階で
  選択肢 3（commit を試み失敗時にコメント fallback）を採る場合も追加要件は発生しない
- artifact 本文の「要約」モードに切り替える閾値（NFR 3.1 の実用上限手前のどこで切るか）は
  design 段階で決定する
- 既存の `verify_pushed_or_retry` を per-task terminal failure 経路にも流用するか、新規ヘルパ
  （Issue 本文の `publish_terminal_failure_artifacts` 風）を導入するかは design の責務
