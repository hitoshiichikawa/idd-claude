# Requirements Document

## Introduction

idd-claude self-hosting および consumer repo（KeyNest 等）の実績では、設計フェーズで生成された
`tasks.md` のタスク件数が一定数を超えると Developer の turn budget が破綻し、Round 1 で
PR 作成に失敗してキャッシュトークンを浪費する事例が継続的に発生している（KeyNest 3 事例:
11 タスクで失敗 / 10 タスクで失敗 / 7 タスクで成功）。

Issue #131 では Architect 自身が `tasks.md` 確定直前に件数を機械的に検知する「設計フェーズ
内側」のガードを導入したが、Architect のレビューが緩く通過したり、人間レビュー前に
Developer に拾われたりするケースに対応するための「**設計フェーズ完了後・Developer pickup 前**」
のハーネス側ガードが未整備である。

本機能では、Architect が `tasks.md` を確定した直後に watcher（ハーネス）側で件数を再評価し、
件数レンジに応じて 3 段階の運用判定（通常 pickup / 警告付き pickup / pickup 抑止）を
適用することで、過大な Issue が Developer に流れて turn budget 超過事故を起こすのを
事前抑止する。本機能は #131 の Architect 側内部ガードを置き換えるものではなく、ハーネス側で
**独立かつ重畳**に作用する追加レイヤとして導入する。

## Requirements

### Requirement 1: tasks.md 件数の機械的カウント

**Objective:** As an idd-claude harness operator, I want 設計フェーズ完了直後に
`tasks.md` のタスク件数を機械的にカウントしたい, so that Developer 起動前に過大 Issue を
検知できる。

#### Acceptance Criteria

1. When Architect エージェントが `tasks.md` を確定したとき, the Issue Watcher shall 当該 Issue
   に対応する `tasks.md` のタスク行件数をカウントする。
2. The Issue Watcher shall タスク行のカウント対象を「checkbox 形式（未完了 `- [ ]` / 完了済み
   `- [x]` / deferrable 印 `- [ ]*` / `- [x]*`）で開始し、続けて numeric 階層 ID
   （`1`, `1.1`, `2.1.3` 等）を持つ行」と定義する。
3. The Issue Watcher shall 子タスク（`1.1`, `1.2` 等の小数階層 ID を持つ行）を最上位タスクと
   同列にフラット展開して 1 件として数える。
4. The Issue Watcher shall 並列実行可能マーカー `(P)` を持つタスク行も `(P)` を持たない
   タスク行と同じく 1 件として数える。
5. When `tasks.md` が存在しない、または読み取れないとき, the Issue Watcher shall 当該 Issue
   に対する本機能の判定を skip し、その旨をログに出力する。
6. When カウントが完了したとき, the Issue Watcher shall カウント結果（件数）と適用された
   閾値レンジを運用者が後から追跡できる形式でログに記録する。

### Requirement 2: 件数レンジに応じた pickup 判定

**Objective:** As an idd-claude harness operator, I want タスク件数のレンジに応じて
Developer pickup の挙動を 3 段階で切り替えたい, so that 過大 Issue の自動実装着手を
未然に抑止できる。

#### Acceptance Criteria

1. When カウント結果が 7 件以下のとき, the Issue Watcher shall 本機能に起因する追加アクション
   を行わず、後続のフェーズ遷移を通常通り進行させる。
2. When カウント結果が 8 件以上 10 件以下のとき, the Issue Watcher shall 当該 Issue に件数と
   閾値根拠を明示した警告コメントを 1 件投稿したうえで、後続のフェーズ遷移を通常通り
   進行させる。
3. When カウント結果が 11 件以上のとき, the Issue Watcher shall 当該 Issue に
   `needs-decisions` ラベルを付与し、人間判断を要請するエスカレーションコメントを 1 件投稿し、
   後続の Developer フェーズの自動起動を抑止する。
4. While `needs-decisions` ラベルが本機能に起因して付与されている間, the Issue Watcher shall
   当該 Issue に対して Developer フェーズを自動起動しない。
5. The escalation comment shall 検知件数・適用閾値・抑止された後続フェーズ名・人間が
   取りうる回復手順（Issue 分割の検討 / 閾値が妥当でない場合のバイパス手段）を含める。
6. If 当該 Issue に既に `needs-decisions` ラベルが付与済みのとき, the Issue Watcher shall
   重複してラベル付与・コメント投稿を行わない。

### Requirement 3: resume 経路での適用除外

**Objective:** As an idd-claude harness operator, I want 既に実装が進行中の Issue が
本機能によって誤って中断・再エスカレーションされないことを期待する, so that 進行中の
パイプラインを破壊せず後方互換性を保てる。

#### Acceptance Criteria

1. While Issue Watcher が impl-resume モード（設計 PR merge 済み・`docs/specs/<N>-*/` が
   既に base branch に存在する経路）で当該 Issue を処理しているとき, the Issue Watcher
   shall 本機能の件数カウントおよび pickup 判定を skip する。
2. While Stage Checkpoint Resume 経路で完了済み Stage を経て中断後の Stage 再開を行って
   いるとき, the Issue Watcher shall 本機能の件数カウントおよび pickup 判定を skip する。
3. When 本機能を skip したとき, the Issue Watcher shall skip した理由（resume 経路名）を
   ログに記録する。

### Requirement 4: 後方互換性とテンプレート二重管理

**Objective:** As an idd-claude maintainer, I want 本機能が既存の watcher 運用と
`repo-template/` 配下を経由した consumer repo の挙動を破壊しないことを期待する, so that
既存ユーザの cron / launchd 実行が無告知で挙動変更しない。

#### Acceptance Criteria

1. When カウント結果が 7 件以下の正常ケースのとき, the Issue Watcher shall 本機能導入前と
   user-observable に同一のフェーズ遷移を行う。
2. The Issue Watcher shall 本機能の有効・無効を運用者が明示的に切り替えられる手段を提供し、
   無効化時には本機能導入前と user-observable に同一の挙動に戻る。
3. When 本機能を含む変更を `.claude/rules/` または `repo-template/` に反映するとき, the
   idd-claude repository shall 既存利用者が次回 install 時に挙動変更を受ける旨を
   `README.md` の migration note に記載する。
4. The Issue Watcher shall 本機能の挙動を、既に Issue #131 の Architect 側 budget overflow
   検知が `needs-decisions` ラベルを付与済みの Issue に対して重複適用しない。

## Non-Functional Requirements

### NFR 1: 観測可能性

1. The Issue Watcher shall 本機能の判定結果を `tasks-count:` のような prefix 付きログ行と
   して標準出力または既定のログファイルに記録し、運用者が後から `grep` 等で全件抽出できる
   形式とする。
2. When `needs-decisions` ラベルを本機能に起因して付与したとき, the Issue Watcher shall
   ラベル付与の根拠が「tasks.md task count overflow」であることを Issue コメント本文で
   識別可能な固定文字列として含める。

### NFR 2: 後方互換性

1. The Issue Watcher shall 既存の env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`,
   `BASE_BRANCH` 等）の意味と互換を破壊しない。
2. The Issue Watcher shall 既存のラベル遷移契約（`auto-dev` → `claude-claimed` →
   `awaiting-design-review` / `claude-picked-up` / `needs-decisions` / `ready-for-review` /
   `claude-failed`）を本機能で改変しない。

### NFR 3: パフォーマンス

1. The Issue Watcher shall `tasks.md` 1 ファイルあたりのカウント処理を 1 秒以内に完了する
   （対象 `tasks.md` のサイズが 1MB 以下である前提）。

## Out of Scope

- 既に `auto-dev` を経由して main に merge 済みの過去 Issue / 過去 `tasks.md` への
  retroactive 適用（retrofit）
- 学習データやヒストリカル成功率に基づく **動的閾値**（タスク件数の閾値を repo 別・期間別に
  自動チューニングする機構）
- タスク件数以外の「内容ベース gating」（タスクの難易度推定・編集対象ファイル数推定・
  diff 規模予測・依存 Issue の有無等による事前判定）
- Developer 側の turn budget そのものの動的緩和（`MAX_TURNS` の自動調整）
- Triage / PM / Architect / Developer / Reviewer など、watcher 以外のエージェント本体の
  フロー変更
- Issue #131 で導入済みの Architect 側 budget overflow 検知ロジック（`design.md` の
  `## Split Proposal` セクション生成等）の置換・改修

## Open Questions

Issue 本文の「確認事項」のうち、Issue 著者が本 Issue 時点でデフォルト挙動を明示している
項目（parent/child の flat カウント / `(P)` の同等扱い）は Requirements 1.3 / 1.4 として
受入基準に取り込み済み。以下は引き続き人間判断が必要な論点として残置する。

1. **閾値 7 / 10 / 11 の妥当性**: 本要件は KeyNest 3 事例からの暫定値を採用しているが、
   他 repo（idd-claude 本体 / その他 consumer repo）で事例が蓄積された段階での見直し
   ポリシー（再評価する基準件数・期間・運用窓口）が未定。継続観測のフィードバック経路を
   どこに置くかを実装着手前または直後に確定したい。
2. **`needs-decisions` ラベルの意味多重化**: 既存運用で `needs-decisions` は PM フェーズで
   情報不足時にも、Issue #131 で Architect 側 budget overflow 検知時にも付与される。本機能
   由来かどうかを後段の運用で識別する必要がある場合、専用補助ラベル（例:
   `tasks-count-overflow`）を併用するか、コメント本文の識別文字列（NFR 1.2）のみで十分かを
   人間判断したい。
3. **警告コメント（8〜10 件）の false positive 救済経路**: 8〜10 件のレンジは pickup を
   継続する設計だが、警告コメントが繰り返し投稿されるとノイズになる可能性がある。同一 Issue
   への警告再投稿の抑止可否（1 回限りに留めるか、再カウントで件数が変化したら再投稿するか）
   を運用判断したい。
