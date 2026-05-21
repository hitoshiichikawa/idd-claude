# 実装ノート（Issue #131）

本ノートは Developer が Issue #131（feat(architect): tasks.md の budget overflow を事前検知して
needs-decisions で escalation する仕組み）を実装した際の判断・暫定解釈・確認事項の記録です。

## 暫定解釈（要件 Open Questions に対する Developer の暫定方針）

要件定義（`requirements.md`）の Open Questions に対して、本実装では以下の暫定方針を採用しました。
**いずれも人間レビュー時に再検討を仰ぐ事項**です（後述「確認事項」を参照）。

### 1. 閾値 10 / 11 / 13 / 14 の妥当性

Issue 本文 draft の閾値をそのまま採用しました:

- ≤ 10 件: pass
- 11〜13 件: consolidate を試行 → 失敗時に split proposal
- ≥ 14 件: forced split（consolidate スキップ）

根拠: 過去事例（KeyNest #91）で 60 turn 超過が発生したのは tasks.md が 10 件超のケース。
10 件は `tasks-generation.md` の既存ガイドラインの上限と整合する自然な境界。11 件で即 escalation
ではなく consolidate を挟むのは false positive 救済のため。

### 2. False positive 救済経路

既存の `skip-triage` ラベルでバイパス可能とし、本機能専用の bypass ラベルは新設しません。

根拠: ラベル増殖を抑える方針（CLAUDE.md「禁止事項」: 既存ラベルセットを壊さない）と整合。
専用ラベルが将来必要になった場合は別 Issue として切り出す前提です。

### 3. Phase 1 単独で十分か

本 Issue では **Phase 1（件数ベース）のみ**を実装します。Phase 2（推定 turn 数による soft
warning）・Phase 3（実績データによるキャリブレーション）は本 PR スコープ外です。

根拠: Issue 本文に明示済み。Phase 2 / 3 は別 Issue としての分離を提案。

### 4. 件数 count 対象

**現行 `tasks-generation.md` の numeric ID 階層に合わせ、「最上位 numeric ID タスク」**
（`- [ ] 1.` / `- [ ] 2.` のように `^- \[ \]\*? <integer>\. ` で始まる行）を 1 件として
カウントします。

- 子タスク（`1.1` など）はカウント対象外
- deferrable テストタスク（`- [ ]*`）の整数 ID（例: `- [ ]* 3.`）は **カウント対象**
  （子タスク `- [ ]* 1.1` はマッチしない）

根拠: Issue 本文の `## T-` セクション例示は現行規約と不一致のため、実体に揃えました。
`## T-` 形式へ将来移行する場合は count 抽出 regex の更新が必要です。

### 5. `needs-decisions` ラベルの意味多重化

専用ラベル（例: `tasks-budget-overflow`）は **新設しません**。NFR 2.2 に従い、PR 本文に
**識別文字列「budget overflow による split proposal 起票」** を明記することで判別可能と
しました。

根拠: ラベル増殖を抑える方針と整合。後段運用で識別困難な場合は別 Issue で専用ラベル新設を
検討する余地を残します。

### 6. Split Proposal セクションの配置先

Issue 本文に従い **`design.md` 末尾** に `## Split Proposal` セクションを追加します。

根拠: Architect の領分は `design.md` / `tasks.md` であり、両者のうち「設計判断（分割提案）」は
設計サイドの `design.md` に置く方が自然。`tasks.md` 末尾配置案との比較は確認事項に列挙。

## 採用した count 抽出 regex

```
^- \[ \]\*? [0-9]+\. 
```

POSIX 互換の ERE（`grep -E`）で記述。意味:

- `^- \[ \]\*?` : 行頭 `- [ ]` または `- [ ]*`（`*?` は 0 回または 1 回の `*`）
- ` [0-9]+\. ` : 半角スペース + 整数 ID + `.` + 半角スペース

**この regex がマッチするケース**:

- `- [ ] 1. <title>` （通常の最上位タスク）
- `- [ ] 10. <title>` （2 桁の整数 ID も対応）
- `- [ ]* 3. <title>` （deferrable 印付き最上位タスク）

**この regex がマッチしないケース**:

- `- [ ] 1.1 <title>` （子タスク。`1.1` の後ろに `. ` が来ないため）
- `- [ ]* 1.1 <title>` （子タスクの deferrable 印付き）
- `  - [ ] 1. <title>` （インデントされたネスト項目）
- `- [x] 1. <title>` （完了タスク。本 check は確定前なので原則登場しないが、念のため除外）

検証は `test-count.sh` で 4 種類の境界 fixture に対して回しています。

## 配置先比較: `design.md` 末尾 vs `tasks.md` 末尾

| 観点 | design.md 末尾 | tasks.md 末尾 |
|---|---|---|
| 設計判断としての性質 | ◯ 設計サイドの判断として整合 | △ 実装計画の補足という見方もできる |
| Architect の領分との整合 | ◯ design.md は Architect が責務を持つ主要成果物 | ◯ tasks.md も Architect の成果物 |
| 人間レビュー時の発見しやすさ | ◯ design.md はレビュアーが先に読む | △ tasks.md は実装フェーズで参照されがち |
| 再分割後の取り扱い | ◯ サブ Issue 化後も親 Issue の設計記録として残せる | △ サブ Issue 化後 tasks.md が刷新されると消える懸念 |
| `tasks.md` 件数 enforcement との重複感 | ◯ 件数判定とは独立 | △ 件数の話を tasks.md 内で完結させる方が自然という見方も |

本実装では Issue 本文の指示に従い `design.md` 末尾配置を採用。確認事項として人間レビューに
最終確定を仰ぎます。

## 後方互換性確認: 件数 ≤ 10 の既存ケースで影響ゼロ

- `design-review-gate.md` の Budget overflow check 節は ≤ 10 件で `pass` 判定とし、追加アクションを
  発生させません
- `tasks-generation.md` の「3〜10 件目安」ガイドラインは撤廃せず、既存セクション ID・見出しを
  変更していません（NFR 1.2）
- `.claude/agents/architect.md` の「Budget overflow が検出された場合の対応」節も ≤ 10 件で
  pass として確定する旨を明示
- README.md の migration note にも「件数が 10 件以下の正常ケースでは追加アクションを発生させず、
  Architect の挙動は本機能導入前と完全に同一」と明記
- 既存運用での `tasks.md` は概ね 3〜10 件に収まる前提であり、本機能による挙動変更は実質的に
  発生しない見込み

## テンプレート二重管理の同期確認（NFR 3.1）

以下 3 ファイルを root と `repo-template/` で同期しました（diff で同一性確認済み）:

- `.claude/rules/design-review-gate.md`
- `.claude/rules/tasks-generation.md`
- `.claude/agents/architect.md`

## 実行した検証コマンド

```bash
# fixture スモークテスト
bash docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh

# shellcheck（新規追加スクリプト）
shellcheck docs/specs/131-feat-architect-tasks-md-budget-overflow/test-count.sh

# 二重管理同期確認
diff .claude/rules/design-review-gate.md repo-template/.claude/rules/design-review-gate.md
diff .claude/rules/tasks-generation.md repo-template/.claude/rules/tasks-generation.md
diff .claude/agents/architect.md repo-template/.claude/agents/architect.md
```

すべて期待通り（fixture テストは 4/4 pass、shellcheck はクリーン、3 ファイルとも diff なし）。

## 受入基準カバレッジ（requirements.md の numeric ID）

| Req ID | 対応箇所 | 検証手段 |
|---|---|---|
| 1.1 | `design-review-gate.md` Mechanical Checks セクション「Budget overflow check」 | `test-count.sh` が件数を機械的にカウント可能であることを確認 |
| 1.2 | `design-review-gate.md` 閾値表（≤10 pass） | fixture `tasks-10.md` で `pass` 判定を確認 |
| 1.3 | `design-review-gate.md` 閾値表（11–13 consolidate） / `architect.md` consolidate フロー | fixture `tasks-11.md` / `tasks-13.md` で `consolidate` 分類を確認 |
| 1.4 | `architect.md`「11〜13 件: consolidate を試行 → 失敗時 split proposal」 | レビュー時にフロー記述で確認（実行時挙動は人間判断） |
| 1.5 | `design-review-gate.md` 閾値表（≥14 forced split） / `architect.md` forced split フロー | fixture `tasks-14.md` で `forced_split` 分類を確認 |
| 1.6 | `architect.md`「`needs-decisions` ラベル付与の手順」 | レビュー時に手順記述で確認 |
| 1.7 | `design-review-gate.md` Count 抽出 regex セクション | regex が `.claude/rules/` 配下に明文化されていることをレビューで確認 |
| 2.1 | `architect.md` Split Proposal テンプレ「判定根拠」節 | テンプレ内に必須記載項目があることをレビューで確認 |
| 2.2 | `architect.md` Split Proposal テンプレ「分割候補」節 | 同上 |
| 2.3 | `architect.md` Split Proposal テンプレ「対応 requirement」項目 | 同上 |
| 2.4 | `architect.md` Split Proposal テンプレ「人間判断を要する論点」節 | 同上 |
| 3.1 | `architect.md` `needs-decisions` ラベル付与の手順（PR 本文への明示） | レビュー時に PR 本文要件で確認 |
| 3.2 | `architect.md` 「`While needs-decisions ラベルが付与されている間, the Issue Watcher shall ...`」を引用 | 既存 watcher 挙動に依存（本 Issue では変更しない） |
| 3.3 | `architect.md` PR 本文に含めるべき情報 1〜3（NFR 2.2 識別文字列 / 件数 / Split Proposal 参照） | レビュー時に PR 本文要件で確認 |
| 3.4 | `design-review-gate.md` ≤10 件 pass / `architect.md` ≤ 10 件 pass セクション | fixture `tasks-10.md` で追加アクションなしを確認 |
| 4.1 | NFR 3.1 同期（root と repo-template/）| diff で同一性を確認（上記） |
| 4.2 | `tasks-generation.md` 「件数 enforcement との関係」節で 3〜10 件目安と新閾値の関係を明記 | レビュー時に文言で確認 |
| 4.3 | `design-review-gate.md` ≤ 10 件 pass | 上記 1.2 と同じ fixture で確認 |
| 4.4 | `README.md` Architect Review Gate の Budget overflow check（#131）節 + migration note | レビュー時に README 該当節で確認 |
| 5.1 | `test-fixtures/tasks-10.md` / `tasks-11.md` / `tasks-13.md` / `tasks-14.md` + `test-count.sh` | スモークテスト 4/4 pass で確認 |
| 5.2 | `test-count.sh` の `classify` 関数が `pass` / `consolidate` / `forced_split` を一意に返す | スモークテストで各 fixture が期待分岐に到達することを確認 |
| NFR 1.1 | 後方互換性確認セクション参照 | fixture `tasks-10.md` で挙動不変を確認 |
| NFR 1.2 | 既存セクション・見出し未変更 | diff で確認 |
| NFR 2.1 | `architect.md` PR 本文に含めるべき情報 2（件数 / 分岐の明示） | レビュー時に PR 本文要件で確認 |
| NFR 2.2 | `architect.md` 識別文字列「budget overflow による split proposal 起票」を必須化 | レビュー時に文言で確認 |
| NFR 3.1 | 二重管理同期確認セクション参照 | diff で確認 |
| NFR 3.2 | （該当時のみ）PR レビューで乖離点を確認事項に列挙 | 本 PR では乖離なし。レビュー時に確認事項として運用ルールを確認 |

## 確認事項（人間レビュー時に最終確定を仰ぐ）

要件 Open Questions の再掲 ＋ Developer が実装中に気づいた追加項目:

1. **閾値 10 / 11 / 13 / 14 の最終確定**: 本 PR では Issue 本文 draft をそのまま採用。
   過去事例の追加調査で「11 件で大半成功するなら 12 件から escalation」等の調整余地があるか。
2. **`skip-triage` ラベルでのバイパス運用の十分性**: 専用 bypass ラベルが必要か。
3. **Phase 2 / 3 を別 Issue に切り出すべきか**: 本 PR は Phase 1 単独で完結。
4. **件数 count 対象を最上位 numeric ID タスクとする選択の妥当性**: 全 checkbox 数を対象に
   する案や、新設見出しマーカー（`## T-`）を導入する案との比較。
5. **`needs-decisions` ラベルの意味多重化**: 識別文字列で十分か、専用ラベル新設が望ましいか。
6. **Split Proposal セクションを `design.md` 末尾に置く判断の妥当性**: `tasks.md` 末尾配置案との
   比較は本ノートに記載。
7. **Architect エージェントへの `Bash` / `gh` ツール権限の追加是非**（本 PR ではスコープ外）:
   現状 Architect は `Read, Grep, Glob, Write` のみで `gh` を実行できないため、`needs-decisions`
   ラベル付与は PR 本文への明示で PjM / 運用者に委譲する設計とした。Architect が直接ラベル
   付与できる方が運用がスムーズな場合は別 Issue で `Bash` 権限の追加を検討。
8. **`test-count.sh` の CI 統合**: 現状はローカル実行のみ。`.github/workflows/` への組み込みが
   望ましいか、ルール改定時の手動確認で十分か。
9. **`## T-` セクション形式への将来移行**: Issue 本文の `## T-` 例示は現行規約と不一致。
   将来 `## T-` 見出し形式へ移行する場合、count 抽出 regex の更新が必要であることを本ノートに
   記録済み。

## 後続タスク候補（派生 Issue として切り出し）

- Phase 2: 推定 turn 数による soft warning
- Phase 3: 実績データ（過去 PR の Developer turn 消費量）によるキャリブレーション
- Architect エージェントへの `Bash`（`gh issue edit` 用）権限追加と直接ラベル付与化
- `test-count.sh` の CI 統合（`.github/workflows/idd-claude-rules-ci.yml` 等の新設）
