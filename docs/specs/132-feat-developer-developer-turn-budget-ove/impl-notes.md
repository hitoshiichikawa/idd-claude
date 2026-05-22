# Implementation Notes — Issue #132 (Umbrella Close-Out)

## Umbrella の趣旨要約

Issue #132 は Developer エージェントの **turn budget overflow**（典型 60 turn 上限の到達）
および **内部 TODO トラッキング由来の overhead**（TaskCreate / TaskUpdate が全 tool call の
29% を占めていた事象）を改善するための **umbrella 親 Issue** です。改善目標は (1) TaskCreate /
TaskUpdate 比率を 29% → 10% 以下に削減し、(2) tool call/turn 比率を 1.7 → 2.5+ に押し上げ
ることで、tool call 予算を実装本体（テスト追加 / commit / AC 達成）に振り向け、turn budget
overrun による Developer 自動失敗を抑制することです。本体実装は 3 件のサブ Issue に分割
され、いずれも CLOSED かつ main に merge 済みとなっています。本 umbrella では新規 feature
実装は行わず、サブ Issue の完了状態確認とドキュメント集約のみを行います（Requirement 5 の
スコープ境界）。

## サブ Issue 一覧（rollout Option A 順）

人間運用者は Issue #132 のコメント上で rollout 順 **Option A**（`#A → #B → #C` すなわち
**#133 → #134 → #135**）を承認しており、本承認のもとで以下の順序で main に merge され
ました。各 spec ディレクトリへの相対パスは本ファイルから見たものです。

1. **#133** — feat(architect/developer): tasks.md の checkbox 形式を必須化し、Developer
   は checkbox 編集で進捗を表現する
   ([`../133-feat-architect-developer-tasks-md-checkb/`](../133-feat-architect-developer-tasks-md-checkb/))
2. **#134** — feat(developer): TaskCreate / TaskUpdate の使用を `tasks.md` にない緊急対応
   のみに制限
   ([`../134-feat-developer-taskcreate-taskupdate-tas/`](../134-feat-developer-taskcreate-taskupdate-tas/))
3. **#135** — feat(developer): independent な tool 操作を 1 turn にまとめて parallel call
   で実行する規律を強化
   ([`../135-feat-developer-independent-tool-1-turn-p/`](../135-feat-developer-independent-tool-1-turn-p/))

## 確認時のリポジトリ状態（NFR 1.2）

- 確認時 git SHA: `75ae4afb8575f7e873306b6d15126bc8dba367a3`（main HEAD）
- 確認日: 2026-05-22
- ブランチ: `claude/issue-132-impl-feat-developer-developer-turn-budget-ove`（本 close-out 作業ブランチ）

## Requirement 1 の確認結果（サブ Issue 完了の検証）

| AC | 確認対象 | 確認結果 |
|---|---|---|
| 1.1 | `docs/specs/133-feat-architect-developer-tasks-md-checkb/` 配下の `requirements.md` と `impl-notes.md` | **存在確認 OK**（`ls -la` で 2 ファイル + `review-notes.md` を確認） |
| 1.2 | `docs/specs/134-feat-developer-taskcreate-taskupdate-tas/` 配下の `requirements.md` と `impl-notes.md` | **存在確認 OK**（同上） |
| 1.3 | `docs/specs/135-feat-developer-independent-tool-1-turn-p/` 配下の `requirements.md` と `impl-notes.md` | **存在確認 OK**（同上） |
| 1.4 | 上記いずれかに欠落があった場合の保留条件 | 該当なし（全ファイル揃っている） |
| 1.5 | サブ Issue 3 件の closed 状態 | **3 件すべて CLOSED 確認**（`gh issue view 133/134/135 --json state` で `"state":"CLOSED"`） |

## Requirement 2 の確認結果（規約・エージェント定義への反映確認）

すべて Grep ベースで反映を確認しました。確認対象ファイルは self-hosting 側（`.claude/`
配下）です。

| AC | 確認対象ファイル | 確認した節 / 行 | 確認結果 |
|---|---|---|---|
| 2.1 | `.claude/rules/tasks-generation.md` | L31 `## Checkbox 形式の必須化`, L33-77 規約本文 | **OK**（#133 由来。「すべての実装タスク行が `- [ ]` または `- [ ]*` の checkbox 形式で開始する」明示） |
| 2.2 | `.claude/rules/design-review-gate.md` | L46 Mechanical Checks 箇条書き + L102 `### tasks.md checkbox enforcement check` | **OK**（#133 由来。Mechanical Checks セクションへの項目追加 + サブセクション展開を確認） |
| 2.3 | `.claude/agents/architect.md` | L221 `## Checkbox 形式の必須化`, L257-262 品質チェックリスト項目 | **OK**（#133 由来。テンプレ・規約・チェックリスト 3 箇所に反映） |
| 2.4 | `.claude/agents/developer.md` | L200 `## TaskCreate / TaskUpdate の使用制限（Issue #134 以降適用）` | **OK**（#134 由来。許容ケースの限定列挙、reminder への defensive 応答禁止、進捗の正本は checkbox 規約を含む） |
| 2.5 | `.claude/agents/developer.md` | L55 `# Tool 呼び出しの並列化規律（Issue #135 以降適用）` | **OK**（#135 由来。規律ステートメント / 並列化すべき具体例 / 直列にすべきケース / 数値ガイド / 過度な並列化への注意を含む） |
| 2.6 | 上記いずれかに欠落がある場合の保留条件 | — | 該当なし（5 項目すべて反映確認済み） |

### 補足: `repo-template/` 配下の同期状況

#134 / #135 由来の Developer 規約は `repo-template/.claude/agents/developer.md` にも反映済み
を Grep で確認しました（`Tool 呼び出しの並列化規律` / `TaskCreate / TaskUpdate の使用制限`
ともに同ファイルにヒット）。一方で #133 由来の checkbox 規約については以下を発見しました:

- `repo-template/.claude/agents/architect.md` には `Checkbox 形式の必須化` 節が **未反映**
- `repo-template/.claude/rules/tasks-generation.md` / `repo-template/.claude/rules/design-review-gate.md`
  ともに #133 由来の checkbox 規約 / Mechanical Check 追加が **未反映**

これは #133 の責務範囲（consumer repo にも同じ規約を配布する `repo-template/` 配下への
同期）であり、本 umbrella #132 の close-out スコープ（Requirement 5: 3 サブ Issue で
merge 済みの内容を変更しない）からは外れる事項です。**対応方針**: 本 close-out では補完
せず、別 Issue として独立に起票することを推奨します（Requirement 5.3 に則り、追加対応が
必要な事項は別 Issue 化）。具体的なタイトル案: `chore(template): #133 の checkbox 規約を
repo-template/ 配下に同期`。

なお self-hosting 側（idd-claude 自身が次回 cron 実行で参照する `.claude/` 配下）には #133
の全規約が反映済みであるため、umbrella #132 が直接目標とする「Developer / Architect の
挙動改善」は self-hosting 範囲では達成済みです。consumer repo（idd-claude を install した
他リポジトリ）への配布は次回 `install.sh` 再実行時に repo-template を base として上書き
されるため、上記同期が未完了のままだと consumer 側に #133 の checkbox 規約が伝播しません。

## Requirement 3 の確認結果（umbrella spec ディレクトリの整備）

- AC 3.1: `docs/specs/132-feat-developer-developer-turn-budget-ove/` ディレクトリに
  `requirements.md`（PM 作成済み）と本 `impl-notes.md`（本ファイル）を配置 → **OK**
- AC 3.2: umbrella の趣旨を本ファイル冒頭「Umbrella の趣旨要約」節で 1 段落以上で要約 → **OK**
- AC 3.3: 3 サブ Issue spec ディレクトリへの相対パスリンクを「サブ Issue 一覧」節に各 1 件
  記載 → **OK**
- AC 3.4: rollout Option A（#133 → #134 → #135）が人間運用者承認のもとで適用された旨を
  「サブ Issue 一覧」節で明記 → **OK**
- AC 3.5: Requirement 2 で発見した repo-template 同期不足について、本ノート「Requirement 2
  の補足」節に対応方針（別 Issue 起票推奨）を記載 → **OK**

## Requirement 4 の確認結果（README / CLAUDE.md への umbrella レベル更新要否判定）

### 判定: README.md / CLAUDE.md / repo-template/CLAUDE.md ともに **追加更新不要**

判定根拠:

1. **CLAUDE.md（root）と `repo-template/CLAUDE.md`**: Grep で `#132` / `#133` / `#134` /
   `#135` / `umbrella` / `turn budget` / `TaskCreate` のいずれにもヒットなしを確認。
   両 CLAUDE.md は **エージェント運用憲章**（言語方針 / コード規約 / 禁止事項 / エージェント
   連携ルール）を扱うレイヤであり、個別 Issue 由来の Developer / Architect の作業手順詳細
   （checkbox 必須化 / TaskCreate 制限 / 並列化規律）は **エージェント定義ファイル
   `.claude/agents/*.md` および規約 `.claude/rules/*.md`** が一次的な情報源です。各サブ
   Issue がそれぞれの担当ファイル（`developer.md` / `architect.md` / `tasks-generation.md`
   / `design-review-gate.md`）を更新済みであり、CLAUDE.md レベルで重複参照を追加する必要
   は無いと判断しました。
2. **README.md**: `umbrella` / `turn budget` / `TaskCreate` の関連語を Grep した結果、既に
   `turn budget` についての説明（5 件のヒット）が記述されており、`partial_overrun` / Developer
   の halt 判断などの運用観点での扱いが説明されています。これらは #148（partial halt 機構）
   などの別 Issue で整備された記述であり、本 umbrella #132 のサブ Issue で追加変更すべき
   箇所はありません。具体的には:
   - README L3236 付近: turn budget 超過の事前抑止に関する記述
   - README L3676 付近: Reviewer 起動と turn budget の関係
   - README L3689 付近: `partial_overrun` ステータスの表
   - README L3759 付近: `partial_overrun` 判定の数値基準
   - README L3993 付近: Developer の turn budget 概念紹介

   これらの記述は umbrella #132 のサブ Issue（#133 / #134 / #135）が変更すべき範囲では
   なく、本 close-out で追加更新する必要はありません。
3. **README / CLAUDE.md と各サブ Issue で更新済みの規約 / エージェント定義の矛盾チェック**:
   目視で確認した範囲では、CLAUDE.md の「エージェント連携ルール」節で Developer が
   `design.md` / `tasks.md` を書き換えないこと、PR 品質チェック項目に shellcheck / actionlint
   が含まれること、後方互換性の維持が必須であること等が記述されており、これらは #133 / #134 /
   #135 のサブ Issue 規約と **整合**（矛盾なし）であることを確認しました。

### AC 4 の達成状況

| AC | 内容 | 結果 |
|---|---|---|
| 4.1 | README.md / CLAUDE.md について umbrella として追加更新が必要かを明示的に判定 | **OK**（上記「判定: 追加更新不要」） |
| 4.2 | サブ Issue が必要箇所を更新済みと判定したときに追加更新を行わず、根拠を impl-notes に記録 | **OK**（上記「判定根拠」1〜3） |
| 4.3 | umbrella レベルで補完すべき不整合を発見した場合の方針判断 | 該当する不整合は **発見せず**（repo-template 同期不足は Requirement 2 補足に別 Issue 化推奨として記録済み。README / CLAUDE.md 本文には不整合なし） |
| 4.4 | README / CLAUDE.md と各サブ Issue で更新済みの規約 / エージェント定義の間に矛盾が無いことを目視確認 | **OK**（上記「判定根拠」3） |

## Requirement 5 の確認結果（スコープ境界の維持）

本 close-out で実施した変更は **本 `impl-notes.md` の追加のみ** です。

| AC | 内容 | 遵守状況 |
|---|---|---|
| 5.1 | 3 サブ Issue で merge 済みの規約 / エージェント定義 / テンプレートの挙動を変更しない | **OK**（本 close-out では `.claude/rules/*.md` / `.claude/agents/*.md` / `repo-template/**` を一切変更していない） |
| 5.2 | 新規の規律 / 数値目標 / 計測機構 / ハード制限を追加導入しない | **OK**（追加導入なし） |
| 5.3 | 追加対応が必要な事項が発見された場合は別 Issue として起票する方針を採る | **適用**（repo-template 同期不足を別 Issue 起票推奨として Requirement 2 補足に記録） |
| 5.4 | 既存の env var 名 / ラベル名 / cron 登録文字列 / exit code 意味の後方互換性を変更しない | **OK**（本 close-out では bash スクリプト / workflow / install スクリプト群を一切変更していない） |

## 非機能要件の充足

- **NFR 1.1 / 1.2**: 本 impl-notes の確認結果は確認対象ファイルの相対パス、対象節の見出し名、
  確認時の git SHA（`75ae4afb...`）を含む粒度で記録しており、第三者がリポジトリ checkout
  状態で 10 分以内に再確認可能。
- **NFR 2.1**: 本ファイルは既存ルール群（`ears-format.md` / `requirements-review-gate.md` /
  `design-principles.md` / `tasks-generation.md` / `design-review-gate.md` / `feature-flag.md`）
  と矛盾する記述を含まない（規約への参照のみで、規約自体の解釈変更や上書きをしていない）。
- **NFR 2.2**: サブ Issue の参照は canonical 記法に整合（`Parent:` 配下の sub Issue として
  Issue 番号 `#133` / `#134` / `#135` を使用、`Depends on:` の cross-Issue 依存は本 close-out
  では使用しない）。
- **NFR 3.1**: 本文は日本語ベース、EARS トリガーキーワード / ファイルパス / コマンド名 /
  Issue 番号は英語固定で記述。

## 不足や懸念

- **発見した不足**: `repo-template/.claude/agents/architect.md` および
  `repo-template/.claude/rules/tasks-generation.md` / `repo-template/.claude/rules/design-review-gate.md`
  に #133 由来の checkbox 必須化規約が未反映。詳細は Requirement 2 の「補足」節を参照。
- **対応方針**: 本 close-out では補完せず、別 Issue として独立に起票する（Requirement 5.3
  の方針に従う）。
- **その他の懸念**: なし

## 確認事項

なし。本 umbrella close-out に必要な人間判断（rollout 順 Option A の承認）は Issue #132
コメントで完了済みであり、本 close-out 作業は Issue #132 本文と requirements.md の AC
（Requirement 1〜5 / NFR 1〜3）に従って機械的に完了可能でした。

repo-template 同期不足の別 Issue 起票についても、本ファイル「Requirement 2 の補足」節で
具体案（タイトル案 `chore(template): #133 の checkbox 規約を repo-template/ 配下に同期`）
を提示済みであり、人間運用者の判断ポイントは「(a) 別 Issue として起票するか / (b) 既知の
制約として受容するか」の二択のみです。

## 受入基準のテスト・検証マッピング

本 Issue は docs / spec 集約作業であり、コード変更を伴わないため unit test は追加しません。
各 AC は **本 impl-notes.md 内の該当節への記述**で担保します。

| Requirement | AC | 担保箇所 |
|---|---|---|
| 1 | 1.1〜1.5 | 本ファイル「Requirement 1 の確認結果」節 |
| 2 | 2.1〜2.6 | 本ファイル「Requirement 2 の確認結果」節 + 「補足」節 |
| 3 | 3.1〜3.5 | 本ファイル全体（特に冒頭〜「サブ Issue 一覧」節、および「Requirement 3 の確認結果」節） |
| 4 | 4.1〜4.4 | 本ファイル「Requirement 4 の確認結果」節 |
| 5 | 5.1〜5.4 | 本ファイル「Requirement 5 の確認結果」節 |
| NFR 1 | 1.1〜1.2 | 本ファイル「非機能要件の充足」節 |
| NFR 2 | 2.1〜2.2 | 本ファイル「非機能要件の充足」節 |
| NFR 3 | 3.1 | 本ファイル全体（言語方針への準拠） |

STATUS: complete
