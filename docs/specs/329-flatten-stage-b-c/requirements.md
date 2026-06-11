# 要件定義: Stage B / Stage C のオーケストレーター層フラット化（claude --agent）

- Issue: [#329](https://github.com/hitoshiichikawa/idd-claude/issues/329) "watcher: Stage B/C のオーケストレーター層を claude --agent でフラット化する"
- 依存: #328（`PJM_MODEL`。本ブランチは #328 の上に積む。merge 順: #337 → 本 PR）
- 対象ファイル想定: `local-watcher/bin/issue-watcher.sh`（`build_reviewer_prompt` / `build_dev_prompt_c` / `run_reviewer_stage` / Stage C 起動）、`README.md`

## Introduction

Stage B（Reviewer）と Stage C（PjM）は「サブエージェントを 1 つ起動するだけ」のオーケストレーターセッションとして実装されており、各 stage で CLAUDE.md + rules の固定 context（推定 2〜3 万トークン）と数ターンを余分に消費している。Claude Code CLI の `--agent <name>` フラグ（2.1.x で確認済み）は agent 定義（`.claude/agents/<name>.md`）をトップレベルセッションのシステムプロンプトとして直接実行でき、この中間層を除去できる。PR Iteration モード（#26/#97）は既にフラット構成で稼働している社内前例である。

ステージ間の独立性（fresh context での独立レビュー）は **プロセス分離**で担保されており、ステージ内の Task 層は独立性に寄与していないため、フラット化は品質契約を変えない。

## Requirements

### Requirement 1: Stage B（Reviewer）のフラット化

**Objective:** As a watcher 運用者, I want Reviewer を `--agent reviewer` で直接実行したい, so that stage ごとのオーケストレーター層 1 枚分の固定トークン費を削減できる

#### Acceptance Criteria

1. When `run_reviewer_stage` が claude を起動するとき, the watcher shall `--agent reviewer` を付与する（システムプロンプト = `.claude/agents/reviewer.md` 本文）
2. The Reviewer 起動プロンプト shall 「reviewer サブエージェントを起動し」等のオーケストレーター文体を、reviewer 本人への直接指示に書き換える
3. The Reviewer 起動プロンプト shall 既存の入力契約（NUMBER / TITLE / URL / REPO / BRANCH / HEAD commit / BASE_BRANCH / SPEC_DIR_REL / ROUND / PREV_RESULT）、必読ファイル一覧、差分自己取得手順（#92）、判定 3 カテゴリ、`RESULT:` 行契約、制約（書き換え禁止 / git・gh 禁止 / スタイル reject 禁止）を維持する
4. The watcher shall `run_reviewer_stage` の戻り値契約（0/1/2/4/99）、ファイル不在リトライ（#296）、`rs_record_reviewer` 記録、`parse_review_result` 連携を変更しない

### Requirement 2: Stage C（PjM）のフラット化

**Objective:** As a watcher 運用者, I want PjM を `--agent project-manager` で直接実行したい, so that Stage C のセッション全体が `PJM_MODEL` のみで動作する

#### Acceptance Criteria

1. When `run_impl_pipeline` が Stage C の claude を起動するとき, the watcher shall `--agent project-manager` を付与する
2. The Stage C 起動プロンプト shall 「project-manager サブエージェントを起動し」等のオーケストレーター文体を、PjM 本人への直接指示（implementation モード）に書き換える
3. The Stage C 起動プロンプト shall 既存の作業内容（review-notes.md の commit + push / PR タイトル規約 / `--base` 実値明示と検証手順（#96）/ PR 本文テンプレート参照 / ラベル付け替え / Issue コメント / 制約）を維持する
4. The watcher shall Stage C の後続処理（PR 実在 verify（#108）/ rs_record_stage / 失敗時遷移）を変更しない

## Non-Functional Requirements

1. The watcher shall Stage A 系（PM + Developer の直列制御）/ design モード（PM → Architect → PjM）/ Per-Task 系 / Debugger / Triage の起動方式を変更しない
2. When `shellcheck local-watcher/bin/issue-watcher.sh` を実行したとき, the build pipeline shall 本変更による新規警告を 0 件にする
3. The build pipeline shall 既存テストスイートを全 PASS のまま維持する
4. The watcher shall `claude --agent <name> --print` の動作（agent 解決 + 応答）をスモークテストで確認した上で導入する

## Out of Scope

- Per-Task Reviewer（`PerTask-Rev-*`）/ Debugger / stage-a-verify のフラット化（同型だが別経路。効果実測後に別 Issue で検討）
- agent 定義（reviewer.md / project-manager.md）本文の変更
- `--agent` モードにおける frontmatter `model:` と `--model` フラグの優先順位の作り込み（#326 の frontmatter 削除 merge 後は論点自体が消滅する。merge 順の推奨を PR に記載）
