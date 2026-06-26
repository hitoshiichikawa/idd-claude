# Requirements Document

## Introduction

impl-resume モードの自律 Developer が、自分の `tasks.md` のチェックボックスを全て `[x]` にした
ことを「完了」の根拠とし、自分が追加した新規公開 IF（テンプレート変数・型フィールド・関数
シグネチャ等）によって壊れた他 Issue 由来の既存テストの fixture を追従させず、同一の
stage-A-verify 失敗を 5 回反復した運用事故（altpocket-server #119）が発生した。本要件は、この
盲点を埋めるため `.claude/agents/developer.md` の責務記述を明文化することを目的とする。具体
的には、(1) 新規公開 IF 追加で壊れた既存テストの fixture 追従は Developer の責務である、
(2) stage-A-verify が green になるまで Developer の責務は継続する、(3) アサーション弱体化
（mock 強化 / assert 緩和 / snapshot 盲目更新）と fixture データ追従の線引きを明確化する、の
三点を Developer prompt に組み込む。改修対象は prompt 本文（root と `repo-template/` の二重
管理）であり、コード変更は伴わない。

## Requirements

### Requirement 1: 新規公開 IF による既存テスト破壊時の fixture 追従責務

**Objective:** As an idd-claude 運用者, I want Developer prompt が「新規公開 IF を追加した
影響で既存テストが失敗した場合、当該テストの fixture を契約に追従させる」責務を Developer に
明示的に負わせること, so that 自分の tasks.md が全て [x] であることを理由に既存テストの
fixture 更新を見送り、stage-A-verify 失敗を反復する事故が再発しない

#### Acceptance Criteria

1. When Developer が impl / impl-resume モードで新規公開 IF（テンプレート変数・型フィールド・
   関数シグネチャ・公開関数のパラメータ追加等）を追加し、その結果として **自分以外の Issue
   由来の既存テスト**が失敗するに至った場合, the Developer prompt shall 当該テストの fixture
   を新しい契約に追従させて全テストを green にすることを Developer の責務として明示する
2. When Developer が新規公開 IF を追加した結果として既存テストが失敗した場合, the Developer
   prompt shall 「該当タスクが自分の `tasks.md` の `_Boundary:_` 外であっても」fixture 追従
   を行う責務があることを明示する
3. The Developer prompt shall fixture 追従が許容される範囲を「テストデータ（fixture
   構造体・map・テーブル駆動エントリ等）に新規契約フィールドの値を追加する」「テストデータの
   既存フィールドを新契約に合わせて型変換・改名する」の 2 種類に限定して例示する
4. If Developer が新規公開 IF を追加せず、既存テストが他要因（依存ライブラリ更新・無関係な
   挙動変更等）で失敗している場合, the Developer prompt shall 当該失敗を「実装側の問題」と
   して扱い、fixture 追従責務節を適用しないことを明示する
5. The Developer prompt shall 本責務が impl モード（初回実装）と impl-resume モード（resume
   実装）の **両方** に適用されることを明示する（impl-resume は本責務が特に強く要求される文脈
   として併記してよい）

### Requirement 2: stage-A-verify green までの責務継続規約

**Objective:** As an idd-claude 運用者, I want Developer prompt が「tasks.md 全 [x]」より
「stage-A-verify が green」を優先的な完了根拠として扱うこと, so that Developer が自分のタスク
完了を理由に verify 失敗を放置して STATUS: complete を出力する事故を防ぐ

#### Acceptance Criteria

1. When Developer が impl / impl-resume モードで stage-A-verify（`go test` / `npm test` 等の
   verify コマンド）が失敗している状態を観測した場合, the Developer prompt shall 「自分の
   `tasks.md` が全て `[x]` であること」を STATUS: complete の根拠としては不十分であることを
   明示する
2. While stage-A-verify が失敗している間, the Developer prompt shall verify が green になる
   まで Developer の責務を継続することを明示する
3. The Developer prompt shall 完了根拠の優先順位を「stage-A-verify が green」>「tasks.md
   全 [x]」の順で明文化する
4. If Developer が stage-A-verify を green にすることが当該 Issue の boundary では不可能と
   判断した場合, the Developer prompt shall `STATUS: partial_blocked` を選択し halt 理由を
   `impl-notes.md` に記録するエスカレーション経路（既存規約）を引き続き利用できることを明示
   する
5. The Developer prompt shall 「verify 失敗状態のまま `STATUS: complete` を出力する」ことを
   禁止することを明示する

### Requirement 3: アサーション弱体化禁止と fixture データ追従許容の線引き

**Objective:** As an idd-claude 運用者, I want Developer prompt が「既存テストを書き換えて
通してはいけない」既存規約と「fixture データを契約に追従させる」新規責務の線引きを Developer
が誤読しない形で明文化すること, so that fixture 追従責務を理由にアサーション緩和・mock 過剰
強化・snapshot 盲目更新が横行する逆効果を防ぐ

#### Acceptance Criteria

1. The Developer prompt shall 既存規約「失敗した既存テストを書き換えて通してはいけない（実装
   側の問題として調査する）」を維持することを明示する
2. The Developer prompt shall 既存規約に対する **例外** として、新規公開 IF 追加によって fixture
   データが契約から外れた場合に限り fixture データを契約に追従させてよいことを明示する
3. The Developer prompt shall 例外として **許容されない** 行為を以下のように列挙する:
   (a) アサーション（`expect` / `assert` / `require` 等）の比較対象を緩める
   (b) アサーションを skip / コメントアウト / 削除する
   (c) mock を新規追加・強化して実装の問題を隠す
   (d) snapshot を内容確認せず `-u` 等で盲目更新する
4. The Developer prompt shall fixture 追従と禁止行為の判別基準として「テスト対象の **入力データ**
   を新契約に追従させる修正は許容、テスト対象の **期待結果（出力 / 副作用）** を緩める修正は
   禁止」という判定軸を明文化する
5. If Developer が fixture 追従だけでは green にできないと判断した場合, the Developer prompt
   shall アサーション緩和を行わず PR 本文「確認事項」または `impl-notes.md` で PM / Architect
   への差し戻しを提案する経路を選択することを明示する

### Requirement 4: prompt の二重管理（root ↔ repo-template）の同期

**Objective:** As an idd-claude 運用者, I want 本要件で `.claude/agents/developer.md` に追加
する責務記述が root と `repo-template/` の両方で byte 一致した状態で配布されること, so that
consumer repo が `install.sh` 経由で同等の Developer 規約を受け取り、root だけ更新して
template が drift する事態を防ぐ

#### Acceptance Criteria

1. The Developer prompt 改修 shall `.claude/agents/developer.md`（root）と
   `repo-template/.claude/agents/developer.md` の **両方** に同一内容で反映される
2. When Developer prompt 改修が完了した場合, the implementation shall
   `diff -r .claude/agents repo-template/.claude/agents` の出力が空であることを確認する
3. The Developer prompt 改修 shall 既存節（「テスト作成ルール」「やらないこと（領分違い）」
   「impl-resume / tasks.md 進捗追跡規約」「出力契約（impl-notes.md 末尾の STATUS 行）」）と
   矛盾しない位置・文言で追記される
4. If 既存節と新規追記の間に重複または矛盾が生じる場合, the implementation shall 既存節を温存
   したまま新規節からの **参照リンク**（`# テスト作成ルール` 等の見出し内リンク）で整合させる
   ことで重複記述を避ける

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Developer prompt 改修 shall 既存の `STATUS: complete` / `STATUS: partial_blocked` /
   `STATUS: partial_overrun` の出力契約・行頭規約・regex（`^STATUS: (.+)$`）を変更しない
2. The Developer prompt 改修 shall 既存の env var（`IMPL_RESUME_PRESERVE_COMMITS` /
   `IMPL_RESUME_PROGRESS_TRACKING` / `PER_TASK_LOOP_ENABLED` / `DEBUGGER_ENABLED` 等）の意味と
   既定値を変更しない
3. The Developer prompt 改修 shall 既存節「impl-resume / tasks.md 進捗追跡規約」「per-task
   ループ下での Implementer の責務」「BLOCKED 宣言の規約」の規約内容を変更しない

### NFR 2: prompt 可読性

1. The Developer prompt 改修 shall 新規追記分の分量を Developer の context 圧迫を最小化する
   観点から **40 行以内**を目安とする（既存節への参照リンクで重複を避ける）
2. The Developer prompt 改修 shall 例示（許容される fixture 追従 / 禁止されるアサーション緩和）
   を具体的な擬似コード片または短い箇条書きで示し、判定軸が Developer から一義に読み取れる
   形にする

## Out of Scope

- `local-watcher/bin/issue-watcher.sh` や `modules/*.sh` のコード変更（本 Issue は prompt の
  明文化のみが対象。watcher 側の挙動変更は別 Issue とする）
- `stage-A-verify` の検出ロジック・regex・タイムアウト等の変更
- `FAILED_RECOVERY` の修正（Issue 本文「確認事項」で言及されているが、別 Issue で扱う旨が
  明記されている）
- Reviewer / Architect / PM の prompt 改修（本 Issue は Developer prompt の責務記述に閉じる）
- 既存テスト fixture そのものの修正（個別の consumer repo 側の対応であり、idd-claude 本体の
  scope ではない）
- prompt 改修内容の単体テスト追加（prompt は markdown のため自動テストでの担保が困難。文言
  レビュー＋ dogfooding での E2E 観察で担保する旨を `impl-notes.md` で言及する）

## Open Questions

- なし（Issue 本文と既存 developer.md 規約から確定可能。実装方針（追記節の配置・既存節への
  参照リンクの張り方）は Developer / Architect の判断に委ねる）
