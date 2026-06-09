# Implementation Notes — Issue #303

## 概要

per-task Reviewer ループ運用下で、Architect が「実行時挙動の変更」と「対応 regression /
failure-path / safety-fallback テスト追加」を異なる task に分割しつつ、先行 task の
`_Requirements:_` に当該テスト側 AC を残したままにすると、per-task Reviewer が
`missing test` カテゴリで誤 reject する事故が発生する問題（idd-codex で複数回観測）に対し、
Architect / Developer / Reviewer 共通の task-boundary contract を明文化した。

本 Issue は **design-less impl**（Architect 不在）であり、tasks.md は生成していない。

## 変更ファイル一覧と理由

### prompt / rule 変更（root と repo-template の両系統に byte-identical で反映）

- `.claude/rules/tasks-generation.md` / `repo-template/.claude/rules/tasks-generation.md`
  - `_Requirements_partial:_` を新規 optional アノテーションとして追加（アノテーション表）
  - 新節「task-test 境界整合の規約（per-task Reviewer 運用時 / Issue #303）」を新設し、
    Architect への要求 / partial 明示の canonical 記法 / dedicated regression test task の
    境界制約 / Developer・Reviewer の参照 / 後方互換性を記述
- `.claude/agents/architect.md` / `repo-template/.claude/agents/architect.md`
  - 「重要なアノテーション」節に `_Requirements_partial:_` を追加
  - 新節「task-test 境界整合（per-task Reviewer 運用時の入力契約 / Issue #303）」を追加し、
    5 項目（default 同 task テスト / behavior-changing 必須テスト / 同 task 内テスト必須
    カテゴリ / deferred の partial 明示 / dedicated regression test task の境界）を要約
  - 自己レビュー checkbox に「task-test 境界整合」項目を追加
- `.claude/agents/developer.md` / `repo-template/.claude/agents/developer.md`
  - 「per-task ループ下での Implementer の責務」節に「task-test 境界整合の責務（Issue #303）」
    を追加。当該 task 内テスト実装責務 / partial 明示の解釈 / 同 task 内テストが書けない
    ときの差し戻し手順 / AC 範囲外テスト禁止を記述
- `.claude/agents/reviewer.md` / `repo-template/.claude/agents/reviewer.md`
  - 「per-task ループ下での Reviewer の責務」節に「task-test 境界整合と partial 明示の
    取り扱い（Issue #303）」を追加。partial 明示 AC を `missing test` reject 対象外とする /
    partial subset 妥当性違反は `boundary 逸脱`（細目: partial spec violation）で reject /
    partial 明示なし AC は通常通り `missing test` 判定 を規定

### fixture（検証用 / NFR 3.1）

- `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/tasks-violation.md`
  — behavior-changing task が同 task テスト指示なし & partial 明示なしの違反パターン
- `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/tasks-partial-ok.md`
  — partial 明示で合法化されたパターン（先行 task + dedicated test task）
- `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/tasks-same-task-ok.md`
  — 同 task 内テスト指示で合法な canonical パターン
- `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/test-task-boundary.sh`
  — awk ベースの違反検出スクリプト。3 fixture すべてが期待結果と一致することを検証

## 設計判断（Open Question 解消）

### partial 明示の canonical 記法（requirements.md Open Question (a) vs (b)）

requirements.md の Open Question は「(a) 行内サフィックス方式 `_Requirements: 1.1 (partial),
1.2_` vs (b) 独立アノテーション方式 `_Requirements_partial: 1.1_`」を Architect 段階で
決定するよう求めていた。本 Issue は design-less impl のため、Developer 段階で判断した。

**採用**: **(b) 独立アノテーション方式 `_Requirements_partial:_`**

採用理由:

1. **既存アノテーション規約との整合**: `_Requirements:_` / `_Boundary:_` / `_Depends:_` と
   同じ「アンダースコア + キー + 値」スタイルで自然に並ぶ。新キー追加が既存パースに
   影響しない
2. **既存 `_Requirements:_` パース規約を壊さない**: 行内サフィックス (a) は
   `tasks-generation.md` の `_Requirements:_` 説明（「説明や括弧書きは付けない」）と
   矛盾する。独立アノテーション (b) は既存規約を変更せず追加導入できる
3. **Mechanical Check との非干渉**: `_Requirements_partial:_` 行は checkbox enforcement
   check の判定パターン `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` にマッチせず、Budget
   overflow check の `^- \[ \]\*? [0-9]+\. ` にもマッチしない。既存 Mechanical Checks に
   影響を与えない（NFR 1.3 / Req 5.3）
4. **機械的パースしやすい**: 行頭が固定 prefix `_Requirements_partial:` で検出でき、
   awk / grep の単純な行マッチで処理可能。inline 括弧解析が不要

### shell-level fixture を本 spec で実装するか（requirements.md Open Question 2）

本 spec で実装した。`docs/specs/303--bug-architect-task-per-task-review/test-fixtures/` に
3 fixture + 1 検証スクリプトを配置。`bash test-task-boundary.sh` で 3 fixture すべてが
期待通り判定されることを確認済み（pass=3 fail=0）。

## 受入基準 → 反映箇所のトレース

### Requirement 1（task と test の境界整合 / Architect ルール）

- 1.1 — `.claude/rules/tasks-generation.md` 「task-test 境界整合の規約」節「Architect への
  要求」の項目 1 / `.claude/agents/architect.md` 「task-test 境界整合」節の項目 1
- 1.2 — `.claude/rules/tasks-generation.md` 「Architect への要求」項目 3（同 task 内テスト
  必須カテゴリの列挙: regression coverage / failure path / API・parse failure handling /
  stale data safety / safety-side fallback） / `.claude/agents/architect.md` の同記述
- 1.3 — `.claude/rules/tasks-generation.md` 「Architect への要求」項目 2（behavior-changing
  task は最低限の regression / shell-level test 追加を同 task 内に含める）
- 1.4 — `.claude/rules/tasks-generation.md` 「partial 明示の canonical 記法」節（deferred 時の
  partial 明示または `_Requirements:_` からの除外を要求）
- 1.5 — `.claude/rules/tasks-generation.md` 「partial 明示の canonical 記法」節（独立
  アノテーション方式 `_Requirements_partial:_` を 1 つに固定。代替記法は禁止）

### Requirement 2（dedicated regression test task の境界制約）

- 2.1 — `.claude/rules/tasks-generation.md` 「dedicated regression test task の境界制約」
  項目 1（`_Requirements:_` 重複制御 / partial 解消関係明示）
- 2.2 — 同節項目 2（スコープを E2E / 統合テスト / coverage 補完等に限定）
- 2.3 — 同節項目 3（partial 解消の責務 / deferred 先 task の tasks.md 上明示）

### Requirement 3（Developer / Reviewer の参照整合）

- 3.1 — `.claude/agents/developer.md` 「task-test 境界整合の責務」節「当該 task 内のテスト
  実装責務」項目
- 3.2 — `.claude/agents/developer.md` 「同 task 内テストが書けないとき」項目（spec 書き換え
  禁止と PR 本文「確認事項」/ Issue コメントでの Architect 差し戻し提案）
- 3.3 — `.claude/agents/reviewer.md` 「task-test 境界整合と partial 明示の取り扱い」節
  「partial 明示なし AC は通常通り `missing test` 判定」項目
- 3.4 — `.claude/agents/reviewer.md` 同節「`_Requirements_partial:_` 明示 AC は `missing
  test` reject 理由としない」項目
- 3.5 — `.claude/rules/tasks-generation.md` の「task-test 境界整合の規約」節を Architect /
  Developer / Reviewer の **3 agents の共通参照点** として宣言し、agents 側からも
  cross-link している（`.claude/agents/{architect,developer,reviewer}.md` から
  `tasks-generation.md` の該当節へリンク）

### Requirement 4（root / repo-template の二重管理整合）

- 4.1, 4.2, 4.3 — `cp` で root → repo-template に byte-identical 反映。
  `diff -r .claude/agents repo-template/.claude/agents` および
  `diff -r .claude/rules repo-template/.claude/rules` が両方とも空であることを確認
  （後述「検証手順」参照）

### Requirement 5（既存運用との後方互換）

- 5.1 — `.claude/rules/tasks-generation.md` 「task-test 境界整合の規約」節冒頭で
  「`PER_TASK_LOOP_ENABLED=true` 運用時のみ適用 / 未指定 / `=true` 以外では本節は適用されず
  既存単一 Developer 一括実装フローの挙動は変化しない」を明示
- 5.2 — 同節「後方互換性」節「既に main に merge 済みの `tasks.md` に対する遡及的な
  書き換えは要求しない」項目
- 5.3 — 同節「後方互換性」節「既存の `_Requirements:_` / `_Boundary:_` / `_Depends:_` /
  `(P)` / `- [ ]*` の各アノテーション規約を破壊的に変更しない」項目

### NFR 1（後方互換性）

- NFR 1.1 — 各エージェント prompt の新節冒頭で `PER_TASK_LOOP_ENABLED` 未指定 / `=true` 以外
  では適用しないことを明示
- NFR 1.2 — 同上
- NFR 1.3 — `_Requirements_partial:_` 行は既存 Mechanical Checks（checkbox enforcement /
  Budget overflow / verify block well-formed）の判定パターンにマッチしないことを確認済み。
  `tasks-generation.md` 「後方互換性」節で明示

### NFR 2（規約整合性）

- NFR 2.1 — `_Requirements_partial:_` は既存アノテーション規約（`_Requirements:_` /
  `_Boundary:_` / `_Depends:_`）と同スタイルで導入し、矛盾しない
- NFR 2.2 — root と repo-template の両系統に byte-identical で反映済み（後述「検証手順」）
- NFR 2.3 — partial 明示の canonical を独立アノテーション方式 1 つに固定。代替記法（行内
  サフィックス / 散文 / HTML コメント）を **禁止** と明記

### NFR 3（検証容易性）

- NFR 3.1 — `docs/specs/303--bug-architect-task-per-task-review/test-fixtures/` に 3 fixture
  + awk ベースの検証スクリプト `test-task-boundary.sh` を配置。スクリプトは「test-coverage
  キーワードなし & partial 明示なし」を違反として検出し、3 fixture すべてが期待結果と
  一致する（pass=3 fail=0）

## 検証手順（実行コマンドと結果）

```bash
# 1. root と repo-template の byte-identical 検証
diff -r .claude/agents repo-template/.claude/agents
# → 出力なし（exit 0）
diff -r .claude/rules repo-template/.claude/rules
# → 出力なし（exit 0）

# 2. fixture スモークテスト（NFR 3.1）
bash docs/specs/303--bug-architect-task-per-task-review/test-fixtures/test-task-boundary.sh
# → [PASS] tasks-violation.md: 違反 1 件検出（期待: >=1 件 / 違反）
#    [PASS] tasks-same-task-ok.md: 違反 0 件（期待: 合法）
#    [PASS] tasks-partial-ok.md: 違反 0 件（期待: 合法）
#    summary: pass=3 fail=0

# 3. shellcheck
shellcheck docs/specs/303--bug-architect-task-per-task-review/test-fixtures/test-task-boundary.sh
# → SHELLCHECK_OK（exit 0）
shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh
# → exit 0（既存 baseline 維持 / 警告なし）

# 4. 既存 budget overflow fixture の regression 確認
for f in docs/specs/131-feat-architect-tasks-md-budget-overflow/test-fixtures/tasks-*.md; do
  count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$f")
  echo "$f -> count=$count"
done
# → tasks-10.md=10 / tasks-11.md=11 / tasks-13.md=13 / tasks-14.md=14（regression なし）

# 5. checkbox enforcement regex の非干渉確認
grep -nE '^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ' docs/specs/303--bug-architect-task-per-task-review/test-fixtures/tasks-partial-ok.md
# → タスク行 2 件のみマッチ（_Requirements_partial:_ 行はマッチせず）
```

## 確認事項

- **Open Question (a) vs (b)** は本 spec が design-less impl のため Developer 段階で
  独自判断した（採用: (b)）。要件定義の Open Question セクションは Architect 判断を
  想定していたが、本 Issue は Architect 不在のため Developer が代行した形となる。
  人間レビュワーは canonical 記法の選択（独立アノテーション方式 vs 行内サフィックス方式）
  の妥当性を確認してください
- **既存 spec への遡及適用は行っていない**（Req 5.2 / NFR 1.1 通り）。既に main に merge
  済みの `tasks.md` で同種の問題があった場合の後始末は本 spec のスコープ外
- **fixture 検証スクリプトの強度**: 違反検出は「test-coverage キーワード（`テスト追加` /
  `regression` / `test` / `fixture` / `E2E` / `単体テスト` / `統合テスト`）の有無」と
  「`_Requirements_partial:_` 明示の有無」を見るヒューリスティック。本検証スクリプトは
  **Mechanical Check として watcher に組み込んでいない**（推奨どまり）。理由は実装側
  Mechanical Check に組み込むかは Architect 経由の別 Issue として議論すべき判断であり、
  本 spec の AC（NFR 3.1）は「機械的に検証できる構造を持つ」までを要求しているため。
  watcher 統合は別 Issue として切り出すことを推奨

## 次の Issue として切り出すべき派生タスク

1. **watcher 側の Mechanical Check 統合**: `_Requirements_partial:_` の subset 妥当性
   検証（partial 列挙 ID が `_Requirements:_` の subset であること）と、test-coverage 系
   AC を含む task に対する「同 task 内テスト指示 or partial 明示」の chsek を Architect の
   `design-review-gate.md` Mechanical Checks に追加する Issue
2. **idd-codex 側の同期**: 本 spec は Out of Scope で「idd-codex 側 #6 / #13 の実装復旧は
   対象外」と明記しているが、idd-codex 側にも `.codex/agents/*` の同等更新が必要

## per-task ループ運用との関係

本 Issue は design-less impl のため tasks.md / 進捗マーカーの per-task ループは適用されず、
単一 Developer での実装を行った。

STATUS: complete
