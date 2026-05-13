# 実装ノート: #100 `staged-for-release` ラベル追加

## 概要

`requirements.md` の確定済み仕様（PM 由来）に従い、以下を実施した。

- idd-claude 標準ラベルセットに `staged-for-release` を追加（self-hosting 側 / consumer template 側の両系統）
- watcher polling query の除外条件に `-label:"staged-for-release"` を追加（Req 2.1）
- README.md のラベル一覧テーブル・状態遷移まとめ・ポーリングクエリ・状態遷移図（補助フロー）・運用注記を更新
- QUICK-HOWTO.md の「作成されるラベル」列挙を追従

Feature Flag Protocol は本リポジトリ（idd-claude self-hosting）の `CLAUDE.md` に `## Feature
Flag Protocol` 節が存在しないため、**opt-out** として扱い、通常の単一実装パスで実装した
（`.claude/rules/feature-flag.md` は読まずに通常フロー）。

## 変更ファイル一覧

| ファイル | 変更内容 | 対応 AC |
|---|---|---|
| `.github/scripts/idd-claude-labels.sh` (line 76) | `LABELS` 配列に `staged-for-release\|b8e0d2\|【Issue 用】 develop に merge 済み、main 到達待ち（multi-branch 運用専用）` を追加 | Req 1.1, 1.2, 1.3, 1.6, 1.7 / NFR 2.1, 3.1 |
| `repo-template/.github/scripts/idd-claude-labels.sh` (line 72) | 同上（self-hosting と consumer template の両系統で同一の name / color / description） | Req 1.7 |
| `local-watcher/bin/issue-watcher.sh` (line 69, line 4720-4730 付近) | `LABEL_STAGED_FOR_RELEASE` 定数を追加 / Dispatcher `gh issue list` の `--search` 引数に `-label:"$LABEL_STAGED_FOR_RELEASE"` を追加 | Req 2.1 / NFR 1.2 |
| `README.md` line 395（ラベル一括作成テーブル） | `staged-for-release` の行を追加 | Req 1.1, 5.3 |
| `README.md` line 411（手動 gh コマンド列挙） | `gh label create staged-for-release ...` を追加 | Req 1.1, 1.2, 1.3, 5.3 |
| `README.md` line 785（ラベル状態遷移まとめテーブル） | `staged-for-release` の行（適用先=Issue / 意味 / 付与主）を追加 | Req 3.1, 3.2, 3.3, 3.4 |
| `README.md` line 798（ポーリングクエリブロック） | `-label:staged-for-release` を除外条件に追加 | Req 2.2 |
| `README.md` line 810-815（除外条件の運用注記） | `-label:staged-for-release` の目的（multi-branch 運用、release 待ち Issue の再 pickup 防止、1 クエリでの集合取得）を 6 行で追記 | Req 2.3 / NFR 2.2 |
| `README.md` line 843-861（状態遷移図の補助フロー） | `ready-for-review` → `staged-for-release` → `closed`（auto-close 発火）の補助フローを追加し、multi-branch 運用専用である旨と Out of Scope（自動付与・自動除去）を明記 | Req 3.5, 3.6 |
| `QUICK-HOWTO.md` line 72-74 | 「作成されるラベル」列挙に `needs-quota-wait` と `staged-for-release` を追加 | Req 5.1, 5.2 |

注: `QUICK-HOWTO.md` には既に `needs-quota-wait` が抜けていた既存 inconsistency があった。
本 PR では `staged-for-release` の追加に伴い、同行内で `needs-quota-wait` も同時追記した
（Req 5.3「他に追記が必要な箇所がドキュメント側で見つかった場合、同 PR 内で更新する」に該当）。

## AC → 実装の対応マップ

### Requirement 1: ラベル定義の追加

| AC | 実装箇所 |
|---|---|
| 1.1 ラベル `staged-for-release` を作成 | `.github/scripts/idd-claude-labels.sh:76`, `repo-template/.github/scripts/idd-claude-labels.sh:72` |
| 1.2 ラベル色 `b8e0d2` | 同上（`\|b8e0d2\|`） |
| 1.3 description に「develop merge 済み、main 到達待ち」 | 同上（description 部分） |
| 1.4 既存ラベル存在時 `--force` 無し → skip 報告 | 既存 LABELS ループの `[ -n "${EXISTING_LABELS[$NAME]:-}" ]` 分岐（line 122）。staged-for-release は同ループ内で扱われるため自動的に満たす |
| 1.5 既存ラベル存在時 `--force` 付き → 上書き更新 | 同上ループ内の `--force` 分岐（line 114-120） |
| 1.6 description に `【Issue 用】` prefix | description 文字列の先頭に `【Issue 用】` を付与した |
| 1.7 self-hosting / consumer template で同一の name/color/description | 両ファイルで一字一句同一（`diff` で IDENTICAL 確認） |

### Requirement 2: ポーリングクエリでの除外

| AC | 実装箇所 |
|---|---|
| 2.1 Watcher Polling Query が当該 Issue を auto-dev pickup から除外 | `local-watcher/bin/issue-watcher.sh:4730` の `gh issue list --search` に `-label:"$LABEL_STAGED_FOR_RELEASE"` を追加 |
| 2.2 README ポーリングクエリ節に `-label:staged-for-release` を明示 | `README.md:798` |
| 2.3 除外目的を 1〜2 行の運用注記として併記 | `README.md:810-815`（6 行で multi-branch 運用文脈と 1 クエリ取得性まで含めて記述） |

### Requirement 3: ラベル状態遷移ドキュメントの更新

| AC | 実装箇所 |
|---|---|
| 3.1 ラベル一覧テーブルに `staged-for-release` の行 | `README.md:785` |
| 3.2 「適用先」列に `Issue` | 同行「Issue」 |
| 3.3 「付与主」列に「人間（もしくは future automation）」 | 同行「人間（もしくは future automation）／解除は `main` merge 時に GitHub auto-close で…」 |
| 3.4 「意味」列に `develop` merge 済み・`main` 到達待ち | 同行「`develop` merge 済み、`main` 到達待ち（multi-branch 運用専用…）」 |
| 3.5 状態遷移図に補助フローを併記 | `README.md:843-853`（補助フロー ASCII） |
| 3.6 multi-branch 専用 / single-branch では使用不要の旨を明記 | `README.md:813-815` および `855-861`（2 箇所で記述） |

### Requirement 4: 既存挙動・既存ラベルへの後方互換性

| AC | 実装箇所 |
|---|---|
| 4.1 既存 11 ラベルの name/color/description を変更しない | 既存 11 行は無変更（diff で確認） |
| 4.2 `BASE_BRANCH` 未設定リポジトリでも既存 pickup 挙動に影響なし | 新除外条件は `staged-for-release` ラベル付与 Issue のみに作用。single-branch 運用ではラベル付与しない想定なので影響なし（NFR 1.2） |
| 4.3 手動作成済みラベルがある場合 `--force` 無し → skip | 既存ループ分岐 `[ -n "${EXISTING_LABELS[$NAME]:-}" ]` が `staged-for-release` にも適用される |
| 4.4 再実行に対して冪等 | 既存ループの冪等性を `staged-for-release` 行が継承する（独自分岐なし） |

### Requirement 5: 関連ドキュメントとの整合

| AC | 実装箇所 |
|---|---|
| 5.1 QUICK-HOWTO.md のラベル一覧に `staged-for-release` を提示 | `QUICK-HOWTO.md:72-74` |
| 5.2 全ドキュメントで `staged-for-release`（lowercase, ハイフン区切り）完全一致 | grep で確認: `README.md` / `QUICK-HOWTO.md` / `local-watcher/bin/issue-watcher.sh` / `.github/scripts/idd-claude-labels.sh` / `repo-template/.github/scripts/idd-claude-labels.sh` 全てで `staged-for-release` |
| 5.3 他の言及箇所も同 PR 内で更新（grep ベース） | watcher の polling query を grep で発見し更新（後述「確認事項」参照） |

### NFR 1: 後方互換性

| NFR | 実装箇所 |
|---|---|
| 1.1 既存運用者向け IF（コマンド呼び出し / `--force` / 終了コード）を変更しない | スクリプト本体（argparse / `--force` 処理 / `exit` ロジック）は無変更 |
| 1.2 既存除外条件（`-label:needs-iteration` 等）の解釈・挙動が変わらない | 既存 8 個の除外条件は順序・引用符・spacing を維持し、末尾に `-label:"$LABEL_STAGED_FOR_RELEASE"` を append しただけ |
| 1.3 既存ラベル行の「適用先」「付与主」「意味」記述を変更しない | 既存 11 行を一切編集していない |

### NFR 2: 一意性・可視性

| NFR | 実装箇所 |
|---|---|
| 2.1 ラベル色 `b8e0d2` が既存 11 色と衝突しない | grep で確認: `1f77b4 / f1c40f / e67e22 / c39bd3 / 9b59b6 / 2ecc71 / e74c3c / 95a5a6 / fbca04 / d4c5f9 / c5def5` のいずれとも一致しない |
| 2.2 GitHub Issue 一覧で `label:staged-for-release` 単独で集合取得できる旨を README に記述 | `README.md:812-813`（除外条件説明節内で記述） |

### NFR 3: 冪等性

| NFR | 実装箇所 |
|---|---|
| 3.1 N 回連続実行でラベル数が常に 1 個に収束 | 既存ループの冪等性（`EXISTING_LABELS` キャッシュ + skip/force 分岐）を継承 |

## スモークテスト結果

| 検証 | 実行コマンド | 結果 |
|---|---|---|
| Bash syntax check (top-level labels) | `bash -n .github/scripts/idd-claude-labels.sh` | OK |
| Bash syntax check (repo-template labels) | `bash -n repo-template/.github/scripts/idd-claude-labels.sh` | OK |
| Bash syntax check (watcher) | `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| shellcheck (labels scripts) | `shellcheck .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh` | 警告ゼロ |
| shellcheck (watcher) | `shellcheck local-watcher/bin/issue-watcher.sh` | 既存の info レベル SC2317/SC2012 のみ。本 PR の差分箇所では新規警告ゼロ |
| Help 表示 | `bash .github/scripts/idd-claude-labels.sh --help` | 既存 help が正しく表示される |
| 両 script の `staged-for-release` 行が完全一致 | `diff <(grep -o '"staged-for-release\|[^"]*"' top) <(grep -o '"staged-for-release\|[^"]*"' template)` | IDENTICAL |
| 色 `b8e0d2` の重複なし | `grep -oE '"[a-z-]+\|[0-9a-f]{6}\|' .github/scripts/idd-claude-labels.sh \| sort -u` | 12 色全て一意 |

注: `gh label create` 実環境 E2E は `gh auth` / 実 repo を必要とするため、ローカルでは
未実施（CI 側 または手動セットアップ時に確認できる）。冪等性は既存 LABELS ループの
構造を変更していないため、既存ラベル 11 個と同等に振る舞う。

## 確認事項（レビュワー判断ポイント）

### 1. `local-watcher/bin/issue-watcher.sh` の変更を本 PR に含めた根拠

タスク指示の「想定される実装箇所」では README / labels script / QUICK-HOWTO.md のみが
明示されていたが、requirements.md の **Req 2.1**（`While Issue に staged-for-release が
付与されている, the Watcher Polling Query shall 当該 Issue を auto-dev pickup の候補から
除外する`）は **operational component としての watcher polling query** に対する要件である
ため、`.github/scripts/idd-claude-labels.sh` / README 更新だけでは満たせない（README の
ポーリングクエリは「人間が GitHub Issue 一覧で打つクエリの記述」と「watcher の実 query」の
両方が記載されている）。

本 PR では `local-watcher/bin/issue-watcher.sh` の Dispatcher polling query に
`-label:"$LABEL_STAGED_FOR_RELEASE"` を追加した。これにより、

- README ポーリングクエリの記述（Req 2.2）
- watcher の実 query（Req 2.1）

の両方が一致する。レビュワーは本変更が Req 2.1 の正しい解釈かを確認してほしい。

### 2. `repo-template/.github/scripts/idd-claude-labels.sh` の既存 description prefix 不整合

`repo-template` 側の既存 LABELS は `auto-dev|1f77b4|自動開発対象` のように `【Issue 用】`
prefix が無い行が多い（`needs-quota-wait` のみ prefix 付き）。一方 top-level の
`.github/scripts/idd-claude-labels.sh` は全行に `【Issue 用】 / 【PR 用】` prefix が付いて
いる（Issue #54 由来）。

本 PR では `staged-for-release` 行のみを **両 script で完全一致**（`【Issue 用】` prefix
付き）にした（Req 1.7）。既存行の prefix 不整合は本 Issue のスコープ外（NFR 1.3「既存
ラベルの記述意味を変更しない」）。**この prefix 不整合の解消は別 Issue として切り出すべき**
であれば、PjM に伝達してほしい。

### 3. QUICK-HOWTO.md の既存 inconsistency（`needs-quota-wait` 抜け）

`QUICK-HOWTO.md` line 72-73 のラベル列挙には、`needs-quota-wait`（Issue #66）と
`staged-for-release`（Issue #100）の両方が抜けていた。本 PR では Req 5.3「他に追記が
必要な箇所がドキュメント側で見つかった場合、同 PR 内で更新する」に従い、
`needs-quota-wait` も同時に追記した。これが本 Issue のスコープ拡大として許容されるか
レビュワーに判断を委ねる（不要なら `needs-quota-wait` だけ別 PR に分離して revert 可能）。

### 4. 状態遷移図の表現（`ready-for-review` → `staged-for-release` の経路）

Req 3.5 は「`staged-for-release` を補助フローとして併記し、既存の main 系遷移とは独立した
中間状態であることを示す」とのみ要求しているため、本 PR では既存の状態遷移図 ASCII を
そのまま残し、**直後に補助フローの ASCII ブロックを追加**する形にした（既存図を編集すると
NFR 1.3「既存ラベルの記述意味を変更しない」に抵触するリスクがある）。レビュワーは
この「補助フローを別ブロックで併記」の形が Req 3.5 の意図を満たすか確認してほしい。

### 5. `repo-template/.github/scripts/idd-claude-labels.sh` の変更が既 installed consumer repo に
   反映されない件

`repo-template/**` の変更は `install.sh` 再実行で初めて consumer repo に反映される（既
installed repo は手動再実行が必要）。これは本 Issue 固有の問題ではなく idd-claude 全体の
配布モデルに由来する制約。Migration note としては README の `### Migration Note（既存
ユーザー向け）` 節に類似 case（needs-quota-wait 追加時）の記述があるため、運用者は
`bash .github/scripts/idd-claude-labels.sh` の再実行で `staged-for-release` のみ "created"
となることを期待できる。**本 PR では migration note の専用節は追加していない**（Issue #66
での needs-quota-wait 追加時と同じ運用モデルなので、追加が必要ならレビュワーから指摘
してほしい）。

## 補足: 次の Issue として切り出す候補

- **`repo-template/.github/scripts/idd-claude-labels.sh` の `【Issue 用】 / 【PR 用】` prefix
  整合化**: 既存 10 行に prefix を付けて top-level スクリプトと完全一致させる refactor。
  本 Issue では Req 1.7 を `staged-for-release` 行のみに適用したが、既存行も整合化すべき
  か別途検討が必要
- **`develop` merge 検知に伴う `staged-for-release` 自動付与 automation**（Req Out of Scope）:
  GitHub Actions workflow か watcher 拡張で実装可能
- **`main` 到達時の自動除去 + auto-close 確認 automation**（Req Out of Scope）
