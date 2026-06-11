# 実装ノート — Issue #329 / Stage B / Stage C のオーケストレーター層フラット化

## 概要

Stage B（Reviewer）と Stage C（PjM）の claude 起動に `--agent reviewer` / `--agent project-manager`
を付与し、agent 定義（`.claude/agents/*.md`）をシステムプロンプトとするトップレベルセッションで
直接実行する構成に変更した。従来の「オーケストレーターセッションが Task ツールでサブエージェントを
1 つ起動する」2 層構成を廃止し、stage あたり固定 context（CLAUDE.md + rules + オーケストレーター
ターン）1 枚分を削減する。プロンプトはオーケストレーター文体（「〜サブエージェントを起動し」）から
本人への直接指示に書き換えたが、入力契約・出力契約・制約・後続 parse は一切変えていない。

## 変更ファイル

1. `local-watcher/bin/issue-watcher.sh`
   - `build_reviewer_prompt`: 冒頭を「あなたは reviewer（独立レビューゲート）として起動されています」
     へ変更。「reviewer サブエージェントは〜」の 3 箇所を直接指示形に。入力契約 / 必読ファイル /
     差分自己取得手順（#92）/ 判定 3 カテゴリ / RESULT 行契約 / 制約は不変
   - `run_reviewer_stage`: claude 引数に `--agent reviewer` を追加（rc 契約 0/1/2/4/99、
     ファイル不在リトライ #296、rs_record_reviewer は不変）
   - `build_dev_prompt_c`: 冒頭を「あなたは project-manager（implementation モード）として
     起動されています」へ変更。base 明示・検証手順（#96）/ 進め方 / 制約は不変
   - Stage C 起動: claude 引数に `--agent project-manager` を追加
   - 両ビルダーのヘッダコメントをフラット構成の説明に更新

2. `README.md` — Reviewer「機能概要」に #329 のフラット実行を 1 項目追記

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | `run_reviewer_stage` の `--agent reviewer` | grep 確認 |
| Req 1.2 | build_reviewer_prompt の文体書き換え（3 箇所） | 差分確認（per-task 用ビルダーは不変） |
| Req 1.3 | 入力契約・必読・差分手順・カテゴリ・RESULT・制約の各節は文字レベルで温存 | 差分確認 |
| Req 1.4 | rc 契約 / リトライ / rs 記録のコードパス不変 | `git diff` が claude 引数 + prompt 文言のみ |
| Req 2.1 | Stage C の `--agent project-manager` | grep 確認 |
| Req 2.2 / 2.3 | build_dev_prompt_c の文体書き換え（3 箇所）、#96 手順温存 | 差分確認 |
| Req 2.4 | Stage C 後続（PR verify #108 / rs_record_stage / 失敗遷移）不変 | `git diff` |
| NFR 1 | Stage A 系 / design / Per-Task / Debugger / Triage の起動は不変 | 全 12 call site の棚卸し（--agent 追加は 2 箇所のみ） |
| NFR 2 | shellcheck 新規警告ゼロ | 後述 |
| NFR 3 | 既存テスト全 PASS | 後述 |
| NFR 4 | `--agent` の実機スモーク | **本環境では CLI 非対話認証が無く実行不可**（後述「確認事項」） |

## 検証結果

- `bash -n`（bash 5.3）→ syntax OK（macOS 標準 bash 3.2 の `-n` は main でも同位置で誤検出する
  既存事象のため bash 5.3 で検証）
- `shellcheck local-watcher/bin/issue-watcher.sh` → 新規警告ゼロ（既存 SC2329 info 6 件のみ）
- テストスイート → 既定 bash + flock 環境で **全 PASS**
  - 補足: bash 5.3 では `qa_run_claude_stage` / `stage_a_verify_round1_defer` /
    `stage_c_existing_pr_guard` / `stage_checkpoint_pending_tasks` の 4 件が **clean main でも**
    失敗する（bash 5.3 非互換の既存事象。本 PR と無関係、別 Issue 候補）

## 設計上の判断

- **独立性の担保**: Reviewer の独立性要件（Developer context を引き継がない）は「別プロセスの
  fresh context」で担保されており、ステージ内の Task 層は寄与していなかった。フラット化は
  この要件に影響しない（README 機能概要の記述とも整合）
- **失敗モードの安全性**: `--agent` の解決失敗（agent 定義欠落等）は claude の非ゼロ exit となり、
  既存の reviewer-error / stageC 失敗遷移（claude-failed + 人間エスカレーション）に吸収される。
  さらに run-summary（#239）の degraded パターンに `Agent type .* not found` が**既登録**のため
  外形検知可能
- **per-task 経路を温存した理由**: `PerTask-Rev-*` 等は同型だが別経路で、ロール文言・round 管理が
  独自。単発経路での効果実測（#325 の token-usage 行）を見てから別 Issue で展開する

## 確認事項（PR レビュワー向け）

- **実機スモーク未実施**: 本実装環境の claude CLI は非対話認証が構成されておらず、
  `claude --agent reviewer --print ...` の実行確認ができていない。フラグの存在は
  `claude --help`（2.1.170）と公式 docs（cli-reference / sub-agents: agent の system prompt が
  デフォルトを置換、`--print` と併用可）で確認済み。**merge 後の最初の dogfooding Issue で
  Stage B/C の挙動（review-notes.md 生成 / PR 作成 / `token-usage:` 行のモデル）を確認すること**
- `--agent` モードでの frontmatter `model:` と `--model` フラグの優先順位は docs に明記がない。
  本ブランチ時点の reviewer.md は `model: claude-opus-4-7` 固定のため、万一 frontmatter が
  優先されても従来と同じ Opus で動作する（安全側）。#326（PR #335）merge 後は frontmatter が
  消え、論点自体が消滅する。**推奨 merge 順: #335 → #337 → 本 PR**
- prompt 内の「最大 2 round」表記は round=3（Debugger 経由再実行）導入後も残る既存文言で、
  本 PR では触れていない（既存どおり）

## 派生タスク候補

- Per-Task Reviewer / Debugger / stage-a-verify の同型フラット化（効果実測後）
- テストスイートの bash 5.3 非互換 4 件の修正（main 由来の既存事象）
