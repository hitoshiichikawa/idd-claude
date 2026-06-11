# 実装ノート — Issue #331 / 設計成果物の分量バジェット導入

## 概要

`design-principles.md` の「1000 行警告」節を「分量バジェット」節に拡張し、複雑度連動の行数目安
（軽微 ≤150 / 標準 ≤300 / 複雑 ≤600、1000 超は分割検討）と簡潔化の規律（コード逐語転載禁止 /
Traceability 1 要件 1 行 等）を規定した。architect.md / developer.md にロール別の要約を反映。
すべて repo-template 側と byte 一致同期。

## 変更ファイル

1. `.claude/rules/design-principles.md`（×2 copies）— 「警告: 1000 行〜」節 → 「分量バジェット（#331）」節へ拡張（既存 1000 行規定は内包維持）。Budget overflow check（タスク件数）との別概念注記
2. `.claude/agents/architect.md`（×2）— 必読ルールの design-principles 行にバジェット要約を追記
3. `.claude/agents/developer.md`（×2）— 「補足ノート」節に impl-notes.md ≤120 行目安と守り方を追記（partial 報告の契約上必須記述は例外と明記）

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| 1.1〜1.4 | design-principles.md「分量バジェット」節（表 + 規律 4 項目） | 文面確認 |
| 1.5 | 同節冒頭の blockquote（タスク件数ゲートとの区別） | 文面確認 |
| 2.1 | architect.md 必読ルール行の追記 | 文面確認 |
| 2.2 / 2.3 | developer.md 補足ノート節の追記（例外明記含む） | 文面確認 |
| 3.1 | `diff -r` 空（rules / agents とも） | 検証結果参照 |
| 3.2 | Mechanical Checks 正準 regex のある節は無変更（design-review-gate.md / tasks-generation.md 自体を触っていない） | `git diff --stat` |
| 3.3 | 必須セクション表は無変更 | 文面確認 |

## 検証結果

- `diff -r .claude/rules repo-template/.claude/rules` → 空 / `diff -r .claude/agents repo-template/.claude/agents` → 空
- 変更は markdown 3 種 × 2 コピーのみ（スクリプト・テンプレート不変）。テストスイートに影響なし
- ハーネス mirror regex の正準（design-review-gate.md / tasks-generation.md）は**ファイル自体を未変更**

## 設計上の判断

- **機械 enforcement を入れない**: まず規約として導入し、#325 の token-usage 実測で効果を確認後、
  必要なら design-review-gate の Mechanical Checks への追加を別 Issue で検討（gate 追加は
  ハーネス regex mirror の整備が必要で、本 Issue のスコープを超える）
- **既存 1000 行規定の温存**: 後方互換（既存の参照・運用文書からのリンク先を壊さない）

## 確認事項（PR レビュワー向け）

- 目安値（150/300/600）は本リポジトリの実測（#68: 669 行 / #66: 924 行はいずれも「複雑」相当）
  から逆算した経験則。consumer repo（アプリ系）でも妥当かは運用で調整可（規約値の変更は
  markdown 編集のみ）
