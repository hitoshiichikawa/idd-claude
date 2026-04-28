# 実装ノート: Phase 4 Feature Flag Protocol（CLAUDE.md 明文化）

## 実装サマリ

Issue #23 の要件に従い、Feature Flag Protocol を **プロジェクト単位 opt-in / opt-out 規約** として
明文化した。watcher / install.sh / GitHub Actions ワークフローには手を入れず、テンプレート
（`repo-template/**`）とエージェント定義（`.claude/agents/*`）への追記のみで実現している
（後方互換性最優先）。

### 変更ファイル一覧

| ファイル | 変更内容 | 主な対応 Req |
|---|---|---|
| `repo-template/.claude/rules/feature-flag.md` | **新規作成** 規約詳細（141 行） | 2.1, 2.2, 2.3, 2.4, 2.5, 5.1, 5.2, 5.3, 6.1, 6.2, 6.3, NFR 2.1, NFR 2.2, NFR 3.1 |
| `.claude/rules/feature-flag.md` | **新規作成** repo-template と同内容（self-hosting 用、141 行） | 2.1 |
| `repo-template/CLAUDE.md` | 末尾に `## Feature Flag Protocol` 節を追加（35 行・既存節順序保全） | 1.1, 1.2, 1.4, NFR 1.2, NFR 2.1, NFR 2.2 |
| `.claude/agents/developer.md` | 必読フロー + 実装フローに opt-in 分岐を追記（+29 行） | 3.1, 3.2, 3.3, 3.4, NFR 1.1, 1.3 |
| `repo-template/.claude/agents/developer.md` | root developer.md と同期更新（+29 行） | 3.1, 3.2, 3.3, 3.4 |
| `.claude/agents/reviewer.md` | 必読フロー + 判定基準に opt-in 観点を追記（+37 -4 行） | 4.1, 4.2, 4.3, 4.4, NFR 1.1 |
| `repo-template/.claude/agents/reviewer.md` | root reviewer.md と同期更新（+37 -4 行） | 4.1, 4.2, 4.3, 4.4 |
| `CLAUDE.md`（root） | 共通ルール表に `feature-flag.md` を 1 行追加 | 2.1 |
| `README.md` | Phase 4 マーカー更新 + opt-in 機能一覧追記 + 専用節 + Migration note | 1.1, 1.2, 1.4, NFR 1.1 |

### コミット数

合計 9 commit（タスク 1.1, 1.2, 2.1, 3.1, 3.2, 4.1, 4.2, 5.1, 5.2 が 1:1 で commit に対応）。
optional テストタスク `- [ ]* 6` は本ノートで結果を記録（commit はこのノートを含めて 10 件目）。

## AC カバレッジマップ

各 requirement numeric ID をどのファイル変更で担保したか:

| AC | 担保箇所 |
|---|---|
| **1.1** CLAUDE.md に専用節 | `repo-template/CLAUDE.md` line 179 `## Feature Flag Protocol`（grep で確認）|
| **1.2** opt-in / opt-out 書式提示 | `repo-template/CLAUDE.md` line 185 `**採否**: opt-out` + コメントで opt-in 例 / `repo-template/.claude/rules/feature-flag.md` 採用宣言サンプル |
| **1.3** 宣言なし → opt-out フォールバック | `.claude/agents/developer.md` line 26-28 / `.claude/agents/reviewer.md` line 28-30（節がない / 値が opt-in 以外なら通常フロー） |
| **1.4** opt-out デフォルト明記 | `repo-template/CLAUDE.md` line 181 `> **デフォルトは opt-out です**` / `repo-template/.claude/rules/feature-flag.md` 冒頭 |
| **2.1** rules ディレクトリに規約詳細ファイル | `repo-template/.claude/rules/feature-flag.md` + root `.claude/rules/feature-flag.md` 新規作成 |
| **2.2** 宣言記述書式の提示 | `feature-flag.md` `## 採否宣言の書式` セクション |
| **2.3** flag 名命名・初期値・有効化条件 | `feature-flag.md` `## Flag 命名と初期値` セクション |
| **2.4** カバー要件 | `feature-flag.md` `## Implementer が満たすべき要件` チェックリスト |
| **2.5** 外部 SaaS を扱わない明記 | `feature-flag.md` `## Non-Goals` 節（LaunchDarkly / Unleash / GrowthBook 列挙除外） |
| **3.1** opt-in 時の Implementer プロンプトに flag 裏実装指示 | `.claude/agents/developer.md` line 71-84 `## opt-in 時の追加実装フロー` |
| **3.2** 両系統が同一テストスイートで実行可能 | `.claude/agents/developer.md` line 78 / `feature-flag.md` `## 両系統テスト` |
| **3.3** flag-off パスの不変性 | `.claude/agents/developer.md` line 79 / `feature-flag.md` Implementer チェックリスト |
| **3.4** opt-out 時は通常の単一実装 | `.claude/agents/developer.md` line 26-28 / line 84（追加フロー適用しない明記） |
| **4.1** opt-in 時の Reviewer プロンプトに flag 観点 | `.claude/agents/reviewer.md` line 24-33 `## Feature Flag Protocol 採否確認` + line 55-59 boundary 逸脱細目 |
| **4.2** opt-out 時は flag 観点なし | `.claude/agents/reviewer.md` line 28-29 / line 71（細目を適用しない明記） |
| **4.3** flag-off パスの差分等価確認 | `.claude/agents/reviewer.md` line 61-69 `### opt-in 時の確認手順` |
| **4.4** flag-off 変化なら reject | `.claude/agents/reviewer.md` line 55-59 boundary 逸脱細目 (a)(b)(c)(d) |
| **5.1** 両系統実行 | `feature-flag.md` `## 両系統テスト` |
| **5.2** いずれか失敗で全体失敗 | `feature-flag.md` `## 両系統テスト` 内のチェックリスト |
| **5.3** 実行責務（local / CI）の指針 | `feature-flag.md` `## 両系統テスト` 内 (a)(b)(c) 選択肢 |
| **6.1** クリーンアップ PR 義務 | `feature-flag.md` `## クリーンアップ責務` |
| **6.2** クリーンアップ起票責務 | `feature-flag.md` line 73「人間が umbrella Issue 完了時に手動で起票」 |
| **6.3** 残存 flag の棚卸し方針 | `feature-flag.md` line 76「同時に active flag が 5 個を超えたら棚卸し Issue を起票」 |
| **NFR 1.1** 既存プロジェクトへの後方互換性 | watcher 不変 + `.claude/agents/*.md` で「opt-in 以外は通常フローと等価」明記 + Smoke 1（install.sh dry-run で `.bak` 退避を確認） |
| **NFR 1.2** 既存節見出しを破壊しない | Smoke 2（`grep -E '^## '` で既存 9 節 + 参考資料 + 新規 1 節すべて hit、順序保全） |
| **NFR 2.1** 1 ページ内可読性 | `feature-flag.md` 141 行 / Feature Flag 節 36 行（いずれも目安以内） |
| **NFR 2.2** 採用宣言サンプル 1 つずつ | `feature-flag.md` `## 採用宣言サンプル` に opt-in / opt-out 例 1 つずつ |
| **NFR 3.1** 言語・基盤非依存 | `feature-flag.md` 内に言語固有のコード例なし。命名は「lower_snake_case 推奨。プロジェクトの言語慣習に合わせて...」と抽象化 |

## 手動スモークテストの結果

### Smoke 1: install.sh 冪等性確認 (NFR 1.1)

```bash
TMPDIR=$(mktemp -d /tmp/scratch-pre-XXXX)
cat > "$TMPDIR/CLAUDE.md" <<'EOF'
# Old CLAUDE.md (pre-feature-flag)
EOF
bash ./install.sh --dry-run --repo "$TMPDIR"
```

結果:
- `[DRY-RUN] BACKUP    .../CLAUDE.md → CLAUDE.md.bak`（既存 CLAUDE.md は `.bak` で保護される）
- `[DRY-RUN] OVERWRITE .../CLAUDE.md`（新規テンプレートで上書き予定）
- `[DRY-RUN] NEW       .../.claude/rules/feature-flag.md`（新規ファイルとしてコピー予定）

→ install.sh は変更不要で、既存挙動のまま新規 `feature-flag.md` を配布できる（Req 設計通り）。

### Smoke 2: 既存節見出しの保全 (NFR 1.2)

```bash
grep -E '^## ' repo-template/CLAUDE.md
```

結果:
```
## 技術スタック
## コード規約
## テスト規約
## ブランチ・コミット規約
## 禁止事項
## エージェント連携ルール
## エージェントが参照する共通ルール（`.claude/rules/`）
## PR 品質チェック（PjM が PR 作成時に確認する項目）
## 機密情報の扱い
## Feature Flag Protocol  ← 新規追加
## 参考資料
```

→ 既存 9 節 + 参考資料の見出しテキスト・階層を一切変更せず、`## Feature Flag Protocol` を 1 節
追加（`## 機密情報の扱い` と `## 参考資料` の間に挿入）。NFR 1.2 を満たす。

### Smoke 3: 行数確認 (NFR 2.1)

```bash
wc -l repo-template/.claude/rules/feature-flag.md
# → 141 lines (200 行以内目安をクリア)

awk '/^## Feature Flag Protocol/,/^## 参考資料/' repo-template/CLAUDE.md | wc -l
# → 36 lines (60 行以内目安をクリア)
```

### Smoke 4: opt-in / opt-out 解釈ロジックの記述確認 (Req 1.3, 3.4, 4.2)

`.claude/agents/developer.md` line 26-28:
```
- 節が存在しない、または値が `opt-in` 以外（`opt-out` / 空 / 不正値 / typo / 大文字小文字違い）:
  **通常フローで実装**（追加 Read 不要。既存挙動と完全に等価 / Req 1.3, 3.4, NFR 1.1）
```

`.claude/agents/reviewer.md` line 28-29:
```
- 節が存在しない、または値が `opt-in` 以外（`opt-out` / 空 / 不正値 / typo / 大文字小文字違い）:
  **通常の 3 カテゴリ判定のみ**（既存挙動を保持。flag 観点の確認は **行わない**）
```

→ opt-out フォールバックの記述が両エージェントに含まれており、Req 1.3 / 3.4 / 4.2 を満たす。

### Smoke 5: shellcheck / actionlint 対象なし

Phase 4 では bash / yaml は変更していない（design.md 通り）:
- `.sh` ファイル変更: なし
- `.yml` / `.yaml` ファイル変更: なし
- markdown のみ変更（9 ファイル）

→ shellcheck / actionlint は実行不要。

### Smoke 6: 完全な E2E（dogfooding）— 後続 Issue で実施推奨

idd-claude 自身は Out of Scope の通り opt-out のままなので、本 PR では E2E 実施なし。
本 PR merge 後、別の test issue を立てて、Developer / Reviewer が opt-out フローで通常通り
動くこと（既存挙動と等価）を確認する dogfooding スモークを実施することを推奨（NFR 1.1 の最終
担保）。

## 確認事項（PR 本文に転記）

### 1. design.md / requirements.md との差分・解釈

設計書通りに実装した。要件・設計に対する解釈変更や追加は行っていない。

### 2. 後方互換性の担保

- watcher (`local-watcher/bin/issue-watcher.sh`) は **変更していない**（design.md の "Out of Modification" に明記）
- `install.sh` も **変更していない**（既存の `cp -R repo-template/. <target>/` ベースの配置で
  新規 `feature-flag.md` も自動的にコピーされる）
- 既存ラベル / 既存 env var / 既存 cron 登録文字列の変更は **一切ない**
- 既存 `repo-template/CLAUDE.md` の節は順序・見出しテキスト・h2 階層をすべて保全

### 3. dogfooding（idd-claude 自身）の採否

design.md / requirements.md の Out of Scope の通り、idd-claude 本体の `## Feature Flag Protocol`
節は **追加していない**（本リポジトリは現状 opt-out として動作する）。本リポジトリ自体を
opt-in にするかは別 Issue で意思決定する。

### 4. Migration note

既 installed の consumer repo は、`./install.sh --repo /path/to/consumer-repo` を再実行しても
`CLAUDE.md` は `.bak` バックアップで保護され上書きされない。Phase 4 への移行は **手動で
`## Feature Flag Protocol` 節を追加する必要がある**。新規 install では `repo-template/CLAUDE.md`
の節がそのまま配置される（デフォルト値は opt-out のため挙動変化なし）。

README の Migration note 節 + Phase 4 専用節（`## Feature Flag Protocol (#23 Phase 4)`）に
記載済み。

### 5. 派生タスク候補（次の Issue として切り出すべきもの）

- **idd-claude 自身（dogfooding）の採否決定**: 別 Issue として切り出し、Phase 5 として位置づけるか議論
- **Feature Flag Protocol の E2E スモークテスト**: 別 Issue で opt-in 採用テストプロジェクトを
  立て、Developer / Reviewer が `feature-flag.md` を Read してチェックリストに従う挙動を実機確認
- **採否宣言の grep ヘルパー**: 任意機能として、`<!-- idd-claude:feature-flag-protocol opt-in -->`
  マーカーを `grep` で機械抽出する helper script を別 Issue で検討（現状は LLM 解釈のみ）

## 確認事項なし（design / requirements との矛盾なし）

実装中に design.md / requirements.md との矛盾は見つからなかった。設計判断 Open Question は
すべて design.md で解決済み:

- クリーンアップ PR 起票責務 → 「人間が umbrella Issue 完了時に手動起票」（feature-flag.md line 73）
- テスト両系統実行責務 → 「規約上の指針提示にとどめる」3 選択肢を併記（feature-flag.md `## 両系統テスト`）
- 採否宣言ブロック形式 → 専用 markdown section + 固定 bold 行（採用済み）
- idd-claude 自身の採否 → Out of Scope（本 PR では宣言節を追加しない）

## テスト・lint・build

本リポジトリは bash + markdown + GitHub Actions YAML 構成で unit test framework なし。
今回の変更は markdown 9 ファイルのみで、bash / yaml への変更はないため:

- `npm test`: 該当なし（package.json なし）
- `npm run lint`: 該当なし
- `npm run build`: 該当なし
- `shellcheck`: 変更ファイルなし
- `actionlint`: 変更ファイルなし
- markdown linter: 手動で見出し階層・コードフェンス言語タグ・相対リンクを確認済み

→ 検証は静的検査（grep）+ 手動スモークテストの組み合わせで行う方針（CLAUDE.md "テスト・検証"
節と整合）。
