# Requirements Document

## Introduction

stage-a-verify gate (#125) は Stage A 完了直前に `tasks.md` の verify コマンドを独立再実行し、
連続失敗を検知して 1 回目は Developer 差し戻し、2 回目で `claude-failed` へエスカレーションする
ゲートである。この連続失敗判定を支える round counter が worktree 内（毎サイクル冒頭の worktree
reset で untracked/ignored が消去される領域）に置かれているため、verify が失敗し続けても counter
が毎サイクル消失して round が常に 1 にリセットされ、round=2 へ到達せずエスカレーションしない。
結果として、真に失敗する verify がサイクルを churn し続け、並行する他 Issue を starve し、同一の
差し戻しコメントを繰り返し投稿する無限ループが発生する（実例: 2026-05-26 の #238 / #239 / #243）。
本要件は、round counter を worktree reset で消えない場所へ永続化し、Issue 番号と branch で一意化
することで、連続失敗が確実にエスカレーションへ収束するようにすることを目的とする。

## Requirements

### Requirement 1: 連続失敗時のエスカレーション収束

**Objective:** As a watcher の運用者, I want verify が連続失敗したとき確実に round=2 でエスカレーションされること, so that 真に失敗する verify が無限ループにならず人間判断へ委ねられる

#### Acceptance Criteria

1. When stage-a-verify が失敗し、その後 worktree reset を挟んで同一 Issue / 同一 branch で再度失敗したとき, the watcher shall round を 2 として扱い当該 Issue をエスカレーション状態へ遷移させる
2. When stage-a-verify が初回失敗したとき, the watcher shall round を 1 として扱い Developer 差し戻し挙動を行う
3. If 同一 Issue / 同一 branch で stage-a-verify が round=2 以降に達したとき, the watcher shall 当該 Issue の自動処理を打ち切り人間にエスカレーションする
4. The watcher shall worktree reset を挟んだ連続失敗において round を 1 にリセットせず、失敗回数に応じて単調に進める

### Requirement 2: round counter の永続化

**Objective:** As a watcher の運用者, I want round counter が worktree reset で消えないこと, so that 連続失敗の回数が正しく蓄積されエスカレーション判定が成立する

#### Acceptance Criteria

1. The round counter shall worktree reset（worktree 配下の untracked/ignored 一括削除）で消えない場所に永続化される
2. While verify が連続失敗している間, the watcher shall worktree reset を跨いで直前までの round 値を読み出せる
3. If round counter の永続化（書き込み）に失敗したとき, the watcher shall 安全側として Developer 差し戻し挙動（round=1 相当）へ倒れ、無告知でエスカレーションを抑止しない

### Requirement 3: Issue / slot 間の一意化

**Objective:** As a 複数 Issue / 複数 slot / 複数 repo を並行稼働させる運用者, I want round counter が他 Issue / 他 slot と衝突しないこと, so that ある Issue の失敗回数が別 Issue の判定を汚染しない

#### Acceptance Criteria

1. The round counter shall Issue 番号と branch（または spec slug）の組で一意に識別される
2. While 複数 Issue が並行して stage-a-verify を実行している間, the watcher shall それぞれの round counter を独立に読み書きする
3. While 複数 slot または複数 repo が並行稼働している間, the watcher shall slot / repo をまたいで round counter を共有しない

### Requirement 4: 成功時・完了時のリセット

**Objective:** As a watcher の運用者, I want verify 成功時やエスカレーション後に round counter がリセットされること, so that 次回以降の判定が過去の失敗履歴に汚染されない

#### Acceptance Criteria

1. When stage-a-verify が成功したとき, the watcher shall 当該 Issue / 当該 branch の round counter をリセットする
2. When 当該 Issue が round=2 以降でエスカレーション状態へ遷移したとき, the watcher shall 当該 round counter をリセットする
3. The round counter のリセット操作 shall 対象が存在しない場合でもエラーにならず冪等に完了する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While verify が成功する通常ケースの場合, the watcher shall 本変更導入前と同一の外形挙動を示し round counter を判定に使用しない
2. While stage-a-verify が明示的に無効化されている場合, the watcher shall 本変更導入前と同一の挙動を示す
3. The watcher shall 既存の環境変数名・ラベル遷移契約・exit code の意味・ログ書式を本変更導入前と同一に維持する
4. Where round counter を持たない既存 Issue が次サイクルで処理される場合, the watcher shall 永続化先不在を未失敗（round=0 相当）として安全に解釈する

### NFR 2: 冪等性

1. While 同一 Issue / 同一 branch / 同一失敗状況の場合, the watcher shall round counter の読み出しを副作用なく繰り返し実行できる
2. The watcher shall round counter のリセットを再実行しても永続化先を破壊せず同一結果に収束する

### NFR 3: 可観測性

1. When stage-a-verify が差し戻しまたはエスカレーションへ遷移したとき, the watcher shall 現在の round 値と遷移結果をログへ出力する

### NFR 4: ドキュメント整合

1. Where 永続化先またはリセット契約が変更される場合, the watcher の運用ドキュメント（README の Stage A Verify Gate 節）shall 同一変更内で更新され実挙動と一致する

## Out of Scope

- stage-a-verify gate の verify コマンド抽出ロジック（構造化ブロック / ヒューリスティック / env fallback の解決順序）の変更
- 「誤って失敗する」verify（false-positive）の抑止（#245 / `.shellcheckrc` で別途対処済み）
- round=1 差し戻しコメント / round=2 エスカレーションコメントの文面・ラベル契約の変更
- design-less impl（tasks.md 不在）での SKIP 挙動の変更（#230 の意図された仕様を維持）
- 既存 Issue の round counter 永続化先のマイグレーション（retrofit。次サイクル以降は新永続化先で自然収束する）
- 永続化先の具体的なパス文字列・ディレクトリ構造・ファイル形式の決定（design.md の領分）

## Open Questions

- なし（Issue 本文の受入観点ヒントと既存契約で要件は確定できる。永続化先の具体的な配置・命名・ファイル形式は実装/設計判断として design.md に委ねる）
