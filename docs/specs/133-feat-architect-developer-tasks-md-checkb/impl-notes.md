# Implementation Notes — Issue #133

## 概要

`tasks.md` の checkbox 形式（`- [ ]` / `- [ ]*`）必須化に伴い、4 ファイルを更新:

1. `.claude/rules/tasks-generation.md` — Checkbox 形式の必須化節を追加
2. `.claude/rules/design-review-gate.md` — Mechanical Checks に `tasks.md checkbox enforcement check` を追加 + サブセクション展開
3. `.claude/agents/architect.md` — tasks.md テンプレに `- [ ]*` 例を追加、Checkbox 形式必須化節、品質チェックリストに項目追加
4. `.claude/agents/developer.md` — checkbox 編集で進捗を表現する規約 / TaskCreate / TaskUpdate を進捗の正本としない旨を明示

## 実装上の判断ポイント

### 1. 判定 regex の現実調整

要件 NFR 2.2 では例として `^- \[[ x]\]\*? [0-9]+\.` が提示されていたが、既存
`tasks-generation.md` の親子テンプレートを精査したところ:

- 最上位タスク: `- [ ] 1. <タスク>` （ID 末尾に `.` あり）
- 子タスク: `- [ ] 1.1 <子タスク>` （ID 末尾に `.` なし）

の表記差があるため、checkbox enforcement check の判定パターンは末尾の `.` をオプショナル化
した `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` を採用した。これにより最上位タスク・子タスク・
完了済みタスク (`- [x]`) の全てが検出される。

既存の Budget overflow check の regex `^- \[ \]\*? [0-9]+\. ` は変更せず（AC 5.3「正常ケース
挙動を変化させない」要件のため）、両 regex は同じ「タスク行 = リスト項目 + checkbox + numeric
ID」規約に依拠する。

### 2. `/goal` 完了条件テンプレへの組み込み見送り

`design-review-gate.md` の `/goal` 自動ループ運用節は、既存の `上記 3 つの Mechanical Checks`
表現で固定（Budget overflow check も追加されているが既存節は更新されていない）。本 Issue の
スコープは Mechanical Checks セクションへの項目追加までで、`/goal` テンプレ自体への
組み込みは要件 AC に明示されていない。スコープ拡大を避けるため見送り。

### 3. tasks-generation.md の deferrable 節への補足追加

「Checkbox 形式の必須化」節と deferrable 節が独立に存在すると、`- [ ]*` が必須要件で
報告されないかの誤読リスクがあるため、deferrable 節に「`- [ ]*` も checkbox 形式の一種として
扱われ、Mechanical Check の判定で違反として報告されません」と 1 行追記して整合性を明示した
（AC 1.4 / 5.2 のサポート）。

### 4. Developer 規約は既存「impl-resume / tasks.md 進捗追跡規約」節へ統合

Developer エージェントの規約は既存節 `## impl-resume / tasks.md 進捗追跡規約` に集約されて
おり、checkbox を進捗の正本とする規約は同節に統合した（独立節は作らない）。AC 4.1〜4.4 は
同節内の箇条書き 3 項目（「タスク完了は checkbox 編集で表現する」「進捗 commit は別
commit」「tasks.md は checkbox 形式である前提」）でカバー。

## 受入基準のテスト・検証マッピング

本 Issue は markdown ルール定義の変更が主体であるため、unit test ではなく **grep ベースの
キーワード存在確認** および **既存 fixture によるリグレッション検証** で AC を担保する。

| AC | 確認手段 | 担保箇所 |
|---|---|---|
| 1.1 | grep | `.claude/rules/tasks-generation.md` L33 「すべての実装タスク行...必須」 |
| 1.2 | grep | 同 L40 「markdown header のみ...禁止」 |
| 1.3 | grep | 同 L38 「親タスク行・子タスク行のいずれにも checkbox を付与」 |
| 1.4 | grep | 同 L75-77 deferrable 節の checkbox 形式扱い明示 |
| 1.5 | grep | 同 L70-71 既存「ID 規則」節維持 |
| 2.1 | grep | `.claude/rules/design-review-gate.md` L46-48 Mechanical Checks 箇条書きに項目追加 |
| 2.2 | 目視 | 同 L120-122 「checkbox を持たないタスク表現...違反として報告」 |
| 2.3 | 目視 | 同 L130-131 「該当行を `- [ ] <numeric ID>. <タスク名>` 形式に修正」 |
| 2.4 | grep | 同 L113-114 判定パターン (POSIX 互換 ERE) を記載 |
| 2.5 | grep | 同 L135-148 「Budget overflow check との関係」節で同一 checkbox 規約に依拠を明示 |
| 3.1 | 目視 | `.claude/agents/architect.md` L193-212 テンプレに `- [ ]*` 例追加、全タスク行が checkbox |
| 3.2 | grep | 同 L257-262 品質チェックリストに「tasks.md checkbox enforcement」項目追加 |
| 3.3 | grep | 同 L221-228 「Checkbox 形式の必須化」節（resume 機能との関連を 1 行以上で説明）|
| 4.1 | grep | `.claude/agents/developer.md` L110-111 「タスク完了は checkbox 編集で表現する」 |
| 4.2 | 目視 | 同 L116-118 既存 `docs(tasks): mark <task-id> as done` 規約維持 |
| 4.3 | grep | 同 L112-115 「TaskCreate / TaskUpdate ... を進捗の正本としては用いない」 |
| 4.4 | 目視 | 同 L105-106 既存「行内 4 文字差分」規約維持 |
| 5.1 | grep | `.claude/rules/design-review-gate.md` L151 「Architect が新規に生成・編集する `tasks.md` に限定」 |
| 5.2 | grep | 同 L154-155 「既存 deferrable テストタスク表記 `- [ ]*` は有効な checkbox 形式」 |
| 5.3 | fixture test | `bash docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh` で 4 件全 pass |
| 5.4 | grep | 同 L152-153 「retrofit は本 rule のスコープ外」 |
| NFR 1.1 | 目視 | 既存ルール（EARS / requirements-review-gate / design-principles / feature-flag）と矛盾なし |
| NFR 1.2 | 目視 | 言語非依存（markdown checkbox / numeric ID のみで構成、特定言語に依存しない） |
| NFR 1.3 | 目視 | `.claude/rules/design-review-gate.md` L38-48 Mechanical Checks 箇条書きで既存 4 項目と並列列挙 |
| NFR 2.1 | 目視 | 判定パターンが POSIX 互換 ERE で明示され、第三者が 1 分以内に確認可能 |
| NFR 2.2 | fixture test | 判定パターンが既存 fixture 4 件で 100% タスク行を検出（grep -cE 検証） |

## 検証結果

### 1. 必須キーワードの grep 確認

```
=== tasks-generation.md ===
31:## Checkbox 形式の必須化
33:`tasks.md` の **すべての実装タスク行**は、行頭が `- [ ]`（未完了）または `- [ ]*`（deferrable
38:- **親タスク行・子タスク行のいずれにも checkbox を付与すること**
40:- **markdown header のみ**（例: `## T-01: タスク名` / `### Task 1` / `#### 1.1 子タスク`）で

=== design-review-gate.md ===
46:- **tasks.md checkbox enforcement check**: tasks.md のすべてのタスク行が checkbox 形式
102:### tasks.md checkbox enforcement check
135:#### Budget overflow check との関係

=== architect.md ===
210:- [ ]* 2.2 <deferrable な追加テストタスク>
221:## Checkbox 形式の必須化
257:- [ ] **tasks.md checkbox enforcement**: tasks.md の全タスク行が checkbox 形式

=== developer.md ===
110-115:タスク完了は checkbox 編集で表現する / TaskCreate / TaskUpdate ツール ... 進捗の正本としては用いない
122-127:tasks.md は checkbox 形式である前提
```

### 2. 既存 fixture によるリグレッション検証（AC 5.3）

```
$ bash docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh
[OK]   tasks-10.md: count=10, class=pass
[OK]   tasks-11.md: count=11, class=consolidate
[OK]   tasks-13.md: count=13, class=consolidate
[OK]   tasks-14.md: count=14, class=forced_split

All 4 boundary fixtures match expected count and classification.
```

Budget overflow check の判定境界 (10/11/13/14) は本変更により **変化なし**。

### 3. checkbox enforcement の判定パターン検証（NFR 2.2）

新規追加した判定パターン `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` を既存 fixture に適用:

```
$ for f in docs/specs/131-feat-architect-tasks-md-budget-overflow/test-fixtures/*.md; do
    total=$(grep -cE '^- \[' "$f")
    detected=$(grep -cE '^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ' "$f")
    echo "$f: checkbox-lines=$total, detected-task-lines=$detected"
  done

tasks-10.md: checkbox-lines=12, detected-task-lines=12
tasks-11.md: checkbox-lines=13, detected-task-lines=13
tasks-13.md: checkbox-lines=15, detected-task-lines=15
tasks-14.md: checkbox-lines=16, detected-task-lines=16
```

既存 fixture の全 checkbox 行（最上位 + 子 + deferrable）が判定パターンで 100% 検出される。

## 確認事項（人間レビュワーへの問い）

1. **design-review-gate.md `/goal` 完了条件テンプレへの組み込み**: 本 PR では `/goal` 自動
   ループ運用節の完了条件テンプレに checkbox enforcement check を追加していない（要件 AC
   未明示のため）。Architect 自己レビューで `/goal` を使うフローで checkbox enforcement check
   も自動収束対象にする場合、別 Issue で追加する余地あり

2. **既存節 `/goal` テンプレの「上記 3 つの Mechanical Checks」表現**: 既存テンプレは
   Budget overflow check 追加後も `上記 3 つ` の表現で固定されている。本 PR でも更新して
   いないが、将来的に整合性確保（`上記 5 つ` への更新等）の小修正 Issue を切る価値あり

3. **既存 spec の retrofit を要望する声が出た場合**: AC 5.4 に従い本 Issue では対象外と
   しているが、将来的に必要になった場合は別 Issue として「過去 merged tasks.md の checkbox
   後付け」を起票することを想定（impl-notes として記録）

## 派生タスク候補（次の Issue に切り出すべき）

- 上記「確認事項 1, 2」を `/goal` テンプレ更新 Issue として切り出し
- watcher Stage A prompt（`local-watcher/bin/issue-watcher.sh`）の `tasks.md` 進捗追跡セクション
  でも checkbox 必須化前提を明示すると、resume 時の Developer 振る舞いがより明確になる
  （ただし本 Issue Out of Scope: watcher prompt 改修は対象外）

## Feature Flag Protocol

本リポジトリ `CLAUDE.md` には `## Feature Flag Protocol` 節がないため、**opt-out として
解釈**（Req 1.3, 3.4, NFR 1.1）。通常フローで実装し、flag 関連の追加実装は行わない。
