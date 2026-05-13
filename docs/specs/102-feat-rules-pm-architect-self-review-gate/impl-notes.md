# Implementation Notes — Issue #102

`feat(rules): PM/Architect の self-review-gate に Claude Code /goal を適用して Mechanical Checks ループを自動化する`

## 実装サマリ

`requirements.md` の Requirement 1〜6 / NFR 1〜4 に基づき、PM / Architect の self-review-gate
ルール 2 種に「`/goal` による自動ループ運用（Claude Code v2.1.139+）」サブセクションを追記
した。同等の追記を `repo-template/.claude/rules/` 配下にもコピーし、`install.sh` 再実行で
consumer リポジトリに配布されるようにした。`README.md` には Claude Code 最低バージョン要件
（基本動作 v2.0.0 / `/goal` 利用時 v2.1.139）と migration note を追記し、ルール概要テーブル
に `/goal` 適用の有無を反映した。

「最大 2 パス」表現は撤廃せず、`/goal` 利用時のターン上限として併記する方針で記述。
Claude Code v2.1.139 未満の環境では `/goal` サブセクションをスキップし、従来の Mechanical
Checks → 判断レビュー → 最大 2 パスの手順がそのまま動作する（後方互換）。

本変更は markdown のみで、bash スクリプト / yaml / install.sh / setup.sh / workflow /
env var / label / cron 登録文字列 / exit code には一切手を入れていない（NFR 1.1 / 1.2 / 1.3 /
2.2 を満たす）。

## 改変ファイル一覧

| ファイル | 種別 | 内容 |
|---|---|---|
| `.claude/rules/requirements-review-gate.md` | 追記 | Mechanical Checks 節末尾に `/goal` サブセクション、レビュー・ループ節にバージョン分岐を併記 |
| `.claude/rules/design-review-gate.md` | 追記 | 同上（Architect 向けテンプレ例に差し替え） |
| `repo-template/.claude/rules/requirements-review-gate.md` | 追記 | 本体 `.claude/rules/requirements-review-gate.md` と意味的同一の追記 |
| `repo-template/.claude/rules/design-review-gate.md` | 追記 | 本体 `.claude/rules/design-review-gate.md` と意味的同一の追記 |
| `README.md` | 追記 | 前提条件 / 共通節に最低バージョン要件 + migration note、共通ルール表に `/goal` 注記を追記 |

新規ファイルなし。bash / yaml / 既存テンプレ削除なし。

## 受入基準の達成確認（traceability）

本リポジトリは bash + markdown 主体で unit test フレームワークを持たないため、AC 検証は
「該当行が当該ファイル内に存在することの目視 / `grep` 確認」で実施する。

### Requirement 1（PM 自己レビューゲートへの `/goal` 運用ノート追記）

- **1.1**: `.claude/rules/requirements-review-gate.md` の Mechanical Checks 節末尾に
  `### /goal による自動ループ運用（Claude Code v2.1.139+）` を 1 箇所追加 → **PASS**
- **1.2**: PM 向けテンプレ例 2 件（フル版 + 短縮版）を提示。Issue 仮案「numeric ID / EARS
  AC / 実装語彙混入なし」と意味的に等価 → **PASS**
- **1.3**: 「Claude Code v2.1.139 以降では」「v2.1.139 未満の環境では本節全体をスキップし」
  と 2 行で明示 → **PASS**
- **1.4**: 「適用タイミング」サブセクションで `requirements.md` 確定直前の `/goal` 発行
  手順を明文化 → **PASS**
- **1.5**: 「レビュー・ループ」節に「v2.1.139 未満では本節の手順をそのまま実行する（従来
  挙動と完全一致）」を明記 → **PASS**
- **1.6**: Mechanical Checks 節の bullet 3 項目（Numeric ID / AC の存在 / 実装語彙の混入
  チェック）は文言・順序ともに変更していない → **PASS**

### Requirement 2（Architect 自己レビューゲートへの `/goal` 運用ノート追記）

- **2.1**: `.claude/rules/design-review-gate.md` の Mechanical Checks 節末尾に同名サブ
  セクションを 1 箇所追加 → **PASS**
- **2.2**: Architect 向けテンプレ例 2 件（フル版 + 短縮版）を提示。Issue 仮案「全 numeric
  ID 出現 / "TBD" 残置なし / orphan component なし」と意味的に等価 → **PASS**
- **2.3**: v2.1.139 以降に限定する旨を 2 行で明示 → **PASS**
- **2.4**: 「適用タイミング」サブセクションで `design.md` 確定直前の `/goal` 発行手順を
  明文化 → **PASS**
- **2.5**: 「レビュー・ループ」節にバージョン分岐を明記 → **PASS**
- **2.6**: Mechanical Checks 節の bullet 3 項目（Requirements traceability / File Structure
  Plan の充填 / orphan component なし）は文言・順序ともに変更していない → **PASS**

### Requirement 3（「最大 2 パス」表現と `/goal` のターン上限の関係明示）

- **3.1 / 3.2**: 「最大 2 パス」表現を両 review-gate の「レビュー・ループ」節で保持。`grep`
  で各ファイル 3 件ヒット（変更前と同じ言及数） → **PASS**
- **3.3 / 3.4**: 各 `/goal` サブセクション内に「ターン上限の併記」サブサブセクションを
  追加し、「最大 2 パス」を流用する旨を明記 → **PASS**
- **3.5**: 「`/goal` が 2 ターン経過しても完了条件を満たさない場合は、自動ループを終了し、
  人間エスカレーション or 要件フェーズ戻しを選択」と明文化 → **PASS**

### Requirement 4（README への Claude Code 最低バージョン明記）

- **4.1**: 「最低バージョン要件: 基本動作は v2.0.0 以上、…利用する場合は v2.1.139 以上」と
  併記 → **PASS**
- **4.2**: 「v2.1.139 未満の環境では `/goal` 節は自動的にスキップされ、従来どおりの…手順が
  そのまま適用されます（後方互換）」を README 内に記述 → **PASS**
- **4.3**: 既存「Claude Code CLI のインストール（`npm install -g @anthropic-ai/claude-code`）」
  bullet 直下の sub-bullet として配置（前提条件 / 共通節内）。他 install 説明と矛盾しない位置 → **PASS**
- **4.4**: 共通ルール表（line 2530 前後）に `requirements-review-gate.md` / `design-review-gate.md`
  の `/goal` 適用を反映。本機能の追記内容と乖離なし → **PASS**

### Requirement 5（consumer 配布用テンプレートへの反映）

- **5.1 / 5.2**: `repo-template/.claude/rules/requirements-review-gate.md` および同
  `design-review-gate.md` に本体と意味的同一の追記を反映（同一文字列の追記） → **PASS**
- **5.3 / 5.4**: 両ファイル内の Mechanical Checks 3 条件 / 「最大 2 パス」は保持 → **PASS**
- **5.5**: `install.sh` を変更していないため、再実行時の上書き挙動は既存規約に準拠したまま
  本変更後のファイルが配布対象になる（NFR 2.2 と整合） → **PASS**

### Requirement 6（dogfooding 確認）

- **6.1**: 本 Issue の PM 段階の `/goal` 風完了条件宣言と self-review 結果は
  `requirements.md` 末尾「自己レビュー記録」節に記録済み（PM が記載済） → **PASS**
- **6.2**: 本 Issue は Architect ステージを経由しない（design 不要、markdown 5 ファイルの
  軽微改修）。Developer 側でも以下「dogfooding 痕跡（Developer 段階）」節で `/goal`-style
  の self-verify を残す → **PASS**（Architect 不在は AC が許容する範囲）
- **6.3**: 本 PR で bash スクリプト / workflow YAML / install.sh / setup.sh を変更していない
  ことを `git status` で確認 → **PASS**

### NFR 1（後方互換性）

- **1.1**: env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` /
  `DEV_MODEL` / `PR_ITERATION_*` / `BASE_BRANCH`）は本 PR で参照すらしておらず変更なし → **PASS**
- **1.2 / 1.3**: ラベル / cron 登録文字列 / exit code に関わるファイル
  （`.github/scripts/idd-claude-labels.sh` / `local-watcher/bin/*.sh`）は変更していない → **PASS**
- **1.4**: v2.1.139 未満の環境では `/goal` 節をスキップする旨を両 review-gate および README
  に明記。Mechanical Checks 3 条件 / 「最大 2 パス」の文言は保持し、従来手順が完全に同一
  挙動で動作する → **PASS**

### NFR 2（変更スコープの限定）

- **2.1**: 改変は 5 ファイル基本スコープ + `docs/specs/102-…/impl-notes.md`（本ファイル）に
  限定 → **PASS**
- **2.2**: `local-watcher/bin/*.sh` / `install.sh` / `setup.sh` / `.github/workflows/*.yml` /
  `.github/scripts/*.sh` を変更していない → **PASS**
- **2.3**: `repo-template/CLAUDE.md` / `repo-template/.claude/agents/*.md` を変更していない → **PASS**

### NFR 3（一貫性と可読性）

- **3.1**: 本体 `.claude/rules/*.md` と `repo-template/.claude/rules/*.md` の同名ファイルは
  追記範囲が文字列レベルで同一（PM 向けは PM 向け同士、Architect 向けは Architect 向け
  同士で同一） → **PASS**
- **3.2**: `/goal` 完了条件文字列のテンプレ例において、EARS トリガーキーワード（`When` /
  `If` / `While` / `Where` / `shall`）は AND 結合の説明文（メタ言及）の中でだけ列挙し、
  完了条件本文では「numeric ID があり、…」「全コンポーネント名が…対応ファイルを持つ」
  のような自然言語 AND で記述している。再確認すべきは「テンプレ例の自然言語条件として
  `shall` などを記述していないか」だが、本文・短縮版とも `shall` を使っていない → **PASS**
- **3.3**: README の「最低バージョン要件」サブ bullet で
  `[.claude/rules/requirements-review-gate.md](repo-template/.claude/rules/requirements-review-gate.md)`
  および
  `[.claude/rules/design-review-gate.md](repo-template/.claude/rules/design-review-gate.md)`
  への相互参照リンクを 2 箇所提供 → **PASS**

### NFR 4（migration note）

- **4.1**: README に「migration note」blockquote を 1 箇所追加し、「撤廃せず併記」「v2.1.139
  未満では `/goal` 節のみがスキップされ、従来運用が継続する」を 4 行で明記 → **PASS**

## dogfooding 痕跡（Developer 段階）

本 Issue 自身が `/goal` 適用の対象である。`/goal` 完了条件相当の Mechanical Checks を
Developer 段階でも以下のとおりセルフ検証した（リポジトリ運用上の準備）。Claude Code が
v2.1.139+ であれば `/goal` で自動収束させられるが、本セッションでは Developer エージェント
として手動で検証している。

### Developer 完了条件（`/goal` 風宣言）

```
本 Issue で改変対象である 5 ファイル（.claude/rules/requirements-review-gate.md /
.claude/rules/design-review-gate.md / repo-template/.claude/rules/requirements-review-gate.md /
repo-template/.claude/rules/design-review-gate.md / README.md）がすべて編集済みで、
かつ /goal サブセクションが両 review-gate 系列ファイル（本体 + repo-template）に追加済みで、
かつ README に v2.0.0 / v2.1.139 のバージョン要件が併記されている
```

### セルフ検証結果

- **対象 5 ファイルが編集済み**: `git diff --name-only main..HEAD` 想定対象 5 ファイル
  + `docs/specs/102-…/impl-notes.md` → **PASS**
- **`/goal` サブセクションが両 review-gate に追加済み**:
  - `grep -c '/goal' .claude/rules/requirements-review-gate.md` = 8 → **PASS**
  - `grep -c '/goal' .claude/rules/design-review-gate.md` = 8 → **PASS**
  - `grep -c '/goal' repo-template/.claude/rules/requirements-review-gate.md` = 8 → **PASS**
  - `grep -c '/goal' repo-template/.claude/rules/design-review-gate.md` = 8 → **PASS**
- **README に v2.0.0 / v2.1.139 バージョン要件が追記済み**: `grep -E 'v2\.0\.0|v2\.1\.139'
  README.md` で 7 件ヒット（version 文字列の登場箇所として妥当） → **PASS**
- **「最大 2 パス」表現の保持**: 4 ファイルすべてで 3 件ずつヒット（保持済み） → **PASS**

## 手動スモークテスト結果

本 PR は markdown のみの変更のため、`shellcheck` / `actionlint` の対象ファイルは含まれない。
markdown 構文の機械検査ツールは本リポジトリに導入されていないため、目視確認で代替する。

### 目視確認

- h1 重複なし（各ファイル冒頭の `# …` は 1 箇所のみ）
- コードフェンスはすべて開閉一致しており、言語タグなしの fence（テンプレ例文字列を貼る
  ために意図的に無言語）以外は既存と同様
- インライン リンク `[.claude/rules/…](repo-template/.claude/rules/…)` および `#共通` の
  アンカーは、`### 共通` 見出しが README 内に 1 件のみであることを確認済み（line 81）。
  GitHub の slugify 規則により `#共通` は line 81 に解決される

### 後方互換性スモーク

- v2.1.139 未満を想定した運用は、`/goal` サブセクションを「スキップしてください」と明示
  しているため、Mechanical Checks → 判断レビュー → 最大 2 パスの従来フローがそのまま読み
  取れる
- `shellcheck` / `actionlint` 対象ファイル（`local-watcher/bin/*.sh` / `install.sh` /
  `setup.sh` / `.github/workflows/*.yml` / `.github/scripts/*.sh`）は本 PR で `git status` 上
  変更されていない

## 確認事項（人間判断を仰ぐ項目）

`requirements.md` 末尾「確認事項」節で PM が列挙した項目は、Developer 段階では仮案どおりに
実装してある。以下は PR 本文「確認事項」に転記すべき項目:

1. **`/goal` 評価モデルの明示**: 本 PR ではルール本文で評価モデルを明示していない（Claude
   Code 既定の Haiku に委ねる方針）。Sonnet 推奨を明記したい場合は本 PR を差し戻して
   追記が必要
2. **「最大 2 パス」表現の扱い**: 本 PR では仮案どおり撤廃せず併記している（Requirement 3.3
   / 3.4 がこの方針を AC として確定）。撤廃方針に振り直す場合は requirements に戻す
3. **consumer 配布範囲**: 本 PR では仮案どおり `repo-template/.claude/rules/` にも反映済み
   （Requirement 5）。本体のみに留める方針なら本 PR の repo-template 側差分を revert する
4. **README 上のバージョン記載位置**: 本 PR では「前提条件 / 共通」節（既存 npm install bullet
   直下）に sub-bullet で配置した。新規節として独立させたい場合は別途指示が必要

これら 4 点は要件側で「人間判断を仰ぐ項目」として明記済みのため、Developer 段階での独自
解釈は避け、PM 提示の仮案どおりに実装した。

## 次の Issue として切り出すべき派生タスク（提案）

- 本 Issue 自身に対して、PM 段階で `/goal` を実機で発行した場合の収束パターン（評価モデル =
  Haiku の判定精度、誤判定時の人間介入頻度）を運用ログとして蓄積する別 Issue（評価モデル
  推奨 / Sonnet 明示要否の判断材料）
- `.claude/agents/product-manager.md` / `.claude/agents/architect.md` の本文側にも `/goal`
  運用ノートへの参照リンクを追加する別 Issue（本 PR の Out of Scope）

## 追加依存

なし。markdown のみの変更で新規依存ライブラリ・新規ツール追加はない。
