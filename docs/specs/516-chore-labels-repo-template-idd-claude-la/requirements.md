# Requirements Document

## Introduction

`idd-claude` は `.github/scripts/idd-claude-labels.sh`（root）と
`repo-template/.github/scripts/idd-claude-labels.sh`（consumer 配布用テンプレート）の 2 系統で
ラベル定義スクリプトを二重管理している。#54 でラベル誤付与防止のため description に
`【Issue 用】` / `【PR 用】` prefix を導入した際、root 側にしか反映されず repo-template 側が
追随しないまま放置されていた（#507 の設計時に既存ドリフトとして発見・Out of Scope 化され、
別 Issue での是正が推奨されていた）。本 Issue はその積み残しを解消し、CLAUDE.md
「二重管理・同期の鉄則」の consumer 配布物同期に repo-template 側を追随させる。root 側を正
（source of truth）とし、repo-template 側のみを更新する単純な同期修正であり、新規の設計判断は
発生しない。

## Requirements

### Requirement 1: LABELS 定義コメントブロックの同期

**Objective:** As a idd-claude 保守者, I want repo-template 側の `LABELS=()` 配列直前のコメント
ブロックを root 側と一致させたい, so that 両ファイルを読む開発者が同じ設計意図（description
prefix 導入経緯・GitHub description 100 文字上限・name/color 不変方針）を参照できる

#### Acceptance Criteria

1. When `repo-template/.github/scripts/idd-claude-labels.sh` を更新するとき, the Developer shall root 側の `LABELS=()` 配列直前にある 4 行のコメントブロック（Issue #54 Req 2.1/2.2/2.3 の説明・description 100 文字上限の言及・name/color 不変の言及を含む）を repo-template 側の同一位置に同一文字列で追加する

### Requirement 2: Issue 用ラベルの description prefix 同期

**Objective:** As a idd-claude 運用者, I want Issue 専用ラベルの description に統一された
`【Issue 用】` prefix が repo-template 側にも付与されていること, so that consumer repo で
auto-dev ワークフローを利用する運用者が、ラベルの適用先（Issue 用か PR 用か）を誤認しない

#### Acceptance Criteria

1. When repo-template 側の `auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `hotfix` の各ラベル定義を更新するとき, the Developer shall 各ラベルの description 先頭に root 側と同一の `【Issue 用】` prefix を付与する
2. The 更新後の上記 9 ラベルの description shall root 側の対応する description と完全に同一の文字列になる

### Requirement 3: PR 用ラベルの description prefix 同期

**Objective:** As a idd-claude 運用者, I want PR 専用ラベルの description に統一された
`【PR 用】` prefix が repo-template 側にも付与されていること, so that consumer repo の運用者が
Issue 用ラベルと PR 用ラベルを取り違えて付与しない

#### Acceptance Criteria

1. When repo-template 側の `needs-rebase` / `needs-iteration` の各ラベル定義を更新するとき, the Developer shall 各ラベルの description 先頭に root 側と同一の `【PR 用】` prefix を付与する
2. The 更新後の上記 2 ラベルの description shall root 側の対応する description と完全に同一の文字列になる

### Requirement 4: root 側ファイルおよび既存一致箇所の不変性維持

**Objective:** As a idd-claude 保守者, I want 本修正が root 側ファイルおよび既に両ファイルで
一致している箇所に一切影響を与えないこと, so that 正（source of truth）である root の内容が
意図せず変化するリスクを避け、修正範囲を最小限に保てる

#### Acceptance Criteria

1. While 本 Issue の変更作業を行う間, the Developer shall root 側 `.github/scripts/idd-claude-labels.sh` に一切の変更を加えない
2. While 本 Issue の変更作業を行う間, the Developer shall 既に両ファイルで一致している `size:small` / `size:medium` / `size:large` の 3 行の内容（name / color / description）を変更しない
3. While 本 Issue の変更作業を行う間, the Developer shall LABELS 定義ブロック（コメント追加および対象 11 ラベルの description prefix 追加）以外の行（オプション解析・依存チェック・ラベル作成ロジック・結果集計・ヘルプ表示等）を変更しない
4. While 本 Issue の変更作業を行う間, the Developer shall 対象 11 ラベルおよび `size:*` 3 ラベル以外の既存ラベル（`needs-quota-wait` / `staged-for-release` / `st-failed` / `awaiting-slot` / `blocked` / `needs-security-fix` / `needs-merge-gate-attention`）の name / color / description を変更しない

### Requirement 5: 同期完了の検証

**Objective:** As a idd-claude 運用者, I want 修正後に両ファイルの byte 一致を機械的に確認
できること, so that ドリフト解消が客観的に検証され、再発時にも同じ手順で検出できる

#### Acceptance Criteria

1. When 修正完了後に `diff .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` を実行するとき, the Verification Process shall 空の出力（差分なし、exit code 0）を返す

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The repo-template 側ラベルスクリプト shall 既存の全ラベルの name および color を一切変更しない（変更を description の prefix 追加およびコメントブロック追加のみに限定する）
2. The repo-template 側ラベルスクリプト shall 本修正の前後で、`--force` オプションなしで実行した場合の動作（既存ラベルは skip、未存在ラベルのみ新規作成）を変更しない

## Out of Scope

- root 側 `.github/scripts/idd-claude-labels.sh` の内容変更（正はあくまで root）
- 実際の consumer repo・本 repo 上の GitHub ラベル（description の実データ）への反映作業（本 Issue はスクリプトファイルの同期のみが対象であり、`gh label create --force` 等でラベルを実際に更新する作業は含まない）
- ラベルの name / color 変更、新規ラベルの追加、既存ラベルの削除
- `size:*` 3 ラベルに関する変更（#511 で既に両ファイル一致済みであり対象外）
- `.claude/agents` / `.claude/rules` など他の root ↔ repo-template 二重管理対象の同期（本 Issue のスコープは labels script 1 ファイルに限定）
- README・CLAUDE.md 等ドキュメントの追加更新（本修正はスクリプト内コメント・description 文字列の同期に限定され、外部挙動・運用手順の変更を伴わないため）

## Open Questions

なし
