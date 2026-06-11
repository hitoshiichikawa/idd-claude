# 実装ノート — Issue #328 / Stage C (PjM) 用 PJM_MODEL env の追加

## 概要

モデル設定ブロックに `PJM_MODEL="${PJM_MODEL:-claude-sonnet-4-6}"` を追加し、
`run_impl_pipeline` の Stage C claude 起動の `--model` を `$DEV_MODEL` から `$PJM_MODEL` に
変更した。Stage C 以外の全 claude 呼び出し（12 call site 中 11）は不変。

## 変更ファイル

1. `local-watcher/bin/issue-watcher.sh`
   - モデル設定ブロックに `PJM_MODEL`（既定 `claude-sonnet-4-6`）を追加（経緯・戻し方コメント付き）
   - Stage C（`run_impl_pipeline` 内、唯一の StageC call site）の `--model "$DEV_MODEL"` →
     `--model "$PJM_MODEL"`
2. `README.md`
   - Step 3 設定節にステージ別モデル既定値の表 + Migration note（#328）を追加

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | config ブロック `PJM_MODEL="${PJM_MODEL:-claude-sonnet-4-6}"` | grep 確認 |
| Req 1.2 | Stage C call site の `--model "$PJM_MODEL"` | grep 確認（下記） |
| Req 1.3 | 他 11 call site 不変 | `grep -A3 qa_run_claude_stage` で全 call site の --model を棚卸し（StageA 系 / Per-Task Impl = DEV_MODEL、Reviewer 系 = REVIEWER_MODEL、Debugger = DEBUGGER_MODEL、Triage = TRIAGE_MODEL、design = DEV_MODEL のまま） |
| Req 1.4 | `${PJM_MODEL:-claude-sonnet-4-6}` の既定値 | bash パラメータ展開 |
| Req 2.1〜2.3 | README ステージ別モデル表 + Migration note | 文面確認 |
| NFR 1 | 既存 env 不変（追加のみ） | `git diff` |
| NFR 2 | shellcheck 新規警告ゼロ | 後述 |
| NFR 3 | 既存テスト全 PASS | 後述 |

## 検証結果

- `shellcheck local-watcher/bin/issue-watcher.sh` → 新規警告ゼロ（既存 SC2329 info 6 件のみ）
- テストスイート `local-watcher/test/*_test.sh` → 全 PASS
- `grep -n 'PJM_MODEL' local-watcher/bin/issue-watcher.sh` → 定義 1 + Stage C 使用 1 の計 2 箇所のみ

## 設計上の判断

- **既定値を Sonnet にする（opt-in にしない）理由**: PjM は「コードを変更しない」役割で、作業は
  機械的（commit / gh pr create / ラベル / コメント）。品質リスクが実質なく、CLAUDE.md の
  「モデル ID デフォルト更新は env default のみ更新」という許容パターンに該当する。README の
  Migration note で従来値への戻し方を明示
- **現時点での効果範囲**: Stage C オーケストレーターセッションが Sonnet 化。内部で起動される
  PjM サブエージェントは #326 で `model: sonnet` 固定のため、#326 / #328 の両方が merge されると
  Stage C 全体が Sonnet で動作する。#329（フラット化）merge 後はオーケストレーター層自体が消え、
  `PJM_MODEL` がそのまま唯一の Stage C モデルになる

## 確認事項（PR レビュワー向け）

- Stage C の品質劣化リスク評価: PjM プロンプトは base branch 検証など手順が明文化されており、
  Sonnet 4.6 で十分に遂行可能と判断。万一 PR 本文品質等で問題が観測されたら
  `PJM_MODEL=claude-opus-4-7` で即時ロールバック可能（env のみ・デプロイ不要）
- 効果の実測は #325（PR #334）の `token-usage: stage=StageC` 行で観測可能

## 派生タスク候補

- なし（#329 フラット化が本 env を前提に続く）
