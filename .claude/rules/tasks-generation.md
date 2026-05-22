<!-- SPDX-License-Identifier: MIT -->
<!-- Adapted from cc-sdd (https://github.com/gotalab/cc-sdd), MIT License, Copyright (c) gotalab -->

# tasks.md 生成ルール

Architect が出力する `tasks.md` は、Developer が迷わず実装を進められる粒度と、
トレーサビリティを持つアノテーションを持たせます。

## 基本フォーマット

### 単純タスクのみの場合

```markdown
- [ ] 1. <タスクの要約>
  - <詳細項目（必要な場合のみ）>
  - _Requirements: 1.1, 2.3_
```

### 親タスクと子タスクの構造を取る場合

```markdown
- [ ] 1. <親タスクの要約>
- [ ] 1.1 <子タスクの記述> (P)
  - <詳細項目 1>
  - <詳細項目 2>
  - _Requirements: 1.1, 1.2_
  - _Boundary: UserService, AuthController_
  - _Depends: 2.1_
```

## Checkbox 形式の必須化

`tasks.md` の **すべての実装タスク行**は、行頭が `- [ ]`（未完了）または `- [ ]*`（deferrable
印、後述）の checkbox 形式で開始することを **必須** とします。これは Developer の resume
機能（`IMPL_RESUME_PROGRESS_TRACKING=true`、Issue #67 / #112 以降の既定）が `- [ ]` → `- [x]`
の markdown checkbox 編集を進捗の **正本** として読む前提を確実に成立させるためです。

- **親タスク行・子タスク行のいずれにも checkbox を付与すること**
  （例: `- [ ] 1. ...` / `- [ ] 1.1 ...` のように親も子もリスト項目 + checkbox で書く）
- **markdown header のみ**（例: `## T-01: タスク名` / `### Task 1` / `#### 1.1 子タスク`）で
  タスクを表現することは **禁止**。タスク行は必ずリスト項目 (`- [ ]`) で書くこと
- 詳細項目（`_Requirements:_` 等のアノテーション行や説明箇条書き）は checkbox を持たない
  通常のリスト項目で構わない（タスクそのものを表現する行のみが checkbox 必須）
- 判定パターン（POSIX 互換 ERE）: `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` — 行頭が `- [ ]`
  / `- [ ]*` / `- [x]` / `- [x]*` のいずれかで、続けて numeric 階層 ID（`1` / `1.1` /
  `2.1.3` 等）+ 半角スペースで始まる行をタスク行と認識する（最上位タスクは ID 末尾の
  `.` あり [`- [ ] 1. <名前>`]、子タスクは末尾の `.` なし [`- [ ] 1.1 <名前>`] が既存表記）

> **Mechanical Check との対応**: 上記必須化は Architect の自己レビュー時に
> [`design-review-gate.md`](./design-review-gate.md) の **tasks.md checkbox enforcement check**
> Mechanical Check が機械的に検証します（checkbox 不在のタスク行を 1 件でも検出した場合は
> 違反として報告し、Architect が `- [ ] <numeric ID>. <タスク名>` 形式に修正してから確定する）。

## アノテーション

| キー | 必須? | 用途 |
|---|---|---|
| `_Requirements:_` | **必須** | 対応する requirement ID を列挙（numeric のみ、例: `1.1, 2.3`）。説明や括弧書きは付けない |
| `_Boundary:_` | 並列可タスク `(P)` でのみ必須 | 担当するコンポーネント名を列挙（design.md の Components 名と一致） |
| `_Depends:_` | 非自明な cross-boundary 依存のみ | 先行するタスク ID を列挙。自明な順序依存は省略 |

## 並列マーカー `(P)`

- **並列実行可能**なタスクのみ末尾に ` (P)` を付ける
- 並列実行できないタスク（順序依存のあるタスク）には付けない（デフォルト=直列）
- `(P)` を付けるなら `_Boundary:_` を必須とする（並列時の競合境界を明示するため）

## ID 規則

- **numeric 階層 ID** のみ使用: `1`, `1.1`, `1.2`, `2`, `2.1` ...
- `T-01` や `FR-01` 形式の英字 ID は使わない（requirements.md の numeric ID と揃えるため）

## Optional なテストタスク

deferrable なテスト追加タスクは checkbox を `- [ ]*`（アスタリスク付き）と記述し、詳細項目で
対応する AC を説明します。**`- [ ]*` も checkbox 形式の一種**として扱われ、上記
「Checkbox 形式の必須化」節および Mechanical Check の判定で違反として報告されません:

```markdown
- [ ]* 1.3 統合テスト追加
  - 対応する受入基準のうち、現時点でカバレッジが不足する項目を補完
  - _Requirements: 1.1, 1.2_
```

## ガイドライン

- 各タスクは **1 commit 単位**で独立に完了可能な粒度にする
- 合計タスク数は **3〜10 件を目安**（多すぎる場合は design の File Structure Plan が大きすぎる可能性）
- 対応する `_Requirements:_` を必ず明示（トレーサビリティ確保）
- 親タスクに対する子タスクは、実装順序に沿って並べる

> **件数 enforcement との関係**: 上記「3〜10 件目安」は設計指針として有効ですが、Architect の
> 自己レビュー時に [`design-review-gate.md`](./design-review-gate.md) の **Budget overflow check**
> Mechanical Check が同じ件数を機械的に判定します（≤10 件 pass / 11〜13 件 consolidate→split /
> ≥14 件 forced split）。10 件以下の正常ケースで挙動は変化しません。カウントは **最上位
> numeric ID タスク**（`- [ ] 1.` / `- [ ] 2.` …）のみが対象で、子タスク（`1.1` 等）や deferrable
> テストタスク（`- [ ]*`）は数えません。

## 参考

- [cc-sdd `tasks.md` テンプレート](https://github.com/gotalab/cc-sdd/blob/main/.kiro/settings/templates/specs/tasks.md)
