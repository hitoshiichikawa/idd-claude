# 要件定義: Stage C (PjM) 用 PJM_MODEL env の追加（既定 Sonnet）

- Issue: [#328](https://github.com/hitoshiichikawa/idd-claude/issues/328) "watcher: Stage C (PjM) 用 PJM_MODEL env を追加し既定を Sonnet にする"
- 対象ファイル想定: `local-watcher/bin/issue-watcher.sh`（モデル設定ブロック / `run_impl_pipeline` Stage C）、`README.md`

## Introduction

Stage C（PjM / 実装 PR 作成）は review-notes.md の commit・`gh pr create`・ラベル付け替え・Issue コメントという機械的作業のみを行うが、watcher は `--model "$DEV_MODEL"`（既定 `claude-opus-4-7`）でオーケストレーターセッションを起動している。PjM の作業品質はモデル能力に敏感でなく、Sonnet で十分である（PjM サブエージェント定義は元々 Sonnet 固定だった経緯がある）。本機能は Stage C 専用の `PJM_MODEL` env（既定 `claude-sonnet-4-6`）を導入し、Stage C のトークン単価を下げる（入力 -40% / 出力 -40%、後続 #329 のフラット化でセッション全体が本モデルに統一される前提も整える）。

## Requirements

### Requirement 1: PJM_MODEL の導入

**Objective:** As a watcher 運用者, I want Stage C のモデルを他 stage と独立に制御したい, so that 機械的な PR 作成作業に Opus を使う固定費を削減できる

#### Acceptance Criteria

1. The watcher shall モデル設定として `PJM_MODEL`（既定値 `claude-sonnet-4-6`、env で上書き可能）を持つ
2. When `run_impl_pipeline` が Stage C（PjM / PR 作成）の claude を起動するとき, the watcher shall `--model "$PJM_MODEL"` を渡す
3. The watcher shall Stage C 以外の claude 呼び出し（Stage A 系 / Reviewer / Debugger / Per-Task 系 / Triage / design）のモデル指定を変更しない
4. While `PJM_MODEL` が未設定であるとき, the watcher shall 既定値 `claude-sonnet-4-6` を採用する

### Requirement 2: 運用ドキュメント

#### Acceptance Criteria

1. The README shall `PJM_MODEL` の存在・既定値・用途を記載する
2. The README shall migration note として「#328 以前の Stage C は `DEV_MODEL`（既定 Opus）で起動されていた。従来挙動に戻すには `PJM_MODEL=claude-opus-4-7`（または `$DEV_MODEL` と同値）を設定する」旨を記載する
3. The README shall design モード（PM → Architect → PjM を 1 セッションで実行する経路）は本 env の対象外であることを記載する

## Non-Functional Requirements

1. The watcher shall 既存 env var（`DEV_MODEL` / `REVIEWER_MODEL` / `TRIAGE_MODEL` 等）の名前・意味・既定値を変更しない
2. When `shellcheck local-watcher/bin/issue-watcher.sh` を実行したとき, the build pipeline shall 本変更による新規警告を 0 件にする
3. The build pipeline shall 既存テストスイートを全 PASS のまま維持する

## Out of Scope

- design モードのモデル分離（単一セッションに PM / Architect / PjM が同居するため CLI レベルで分離不可。PjM サブエージェントは frontmatter `model: sonnet`（#326）で軽量化済み）
- Stage C のオーケストレーター層フラット化（#329。本 env はその前提）
- `DEV_MODEL` / `REVIEWER_MODEL` の既定値変更
