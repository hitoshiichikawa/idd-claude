# 要件定義: 設計成果物の分量バジェット導入

- Issue: [#331](https://github.com/hitoshiichikawa/idd-claude/issues/331) "rules: design.md / impl-notes.md に分量バジェットを導入する"
- 対象ファイル想定: `.claude/rules/design-principles.md`、`.claude/agents/architect.md`、`.claude/agents/developer.md`（いずれも repo-template 側と byte 一致同期）

## Introduction

実測で design.md が 1 Issue あたり 669 行（#68）〜924 行（#66）に達している。設計書は高単価モデルの出力トークンとして生成された後、Developer・Reviewer・PR iteration が繰り返し入力として読み込むため、肥大の影響は多段に増幅される。impl-notes.md も 180〜383 行の実績がある。現行 design-principles.md の閾値「1000 行で警告」は bash スクリプト規模の機能には緩すぎ、複雑度に応じた目安と「短く書くための具体的な規律」が存在しない。本機能は既存規約の必須セクション・ゲート判定を変えずに、行数バジェットと簡潔化規律を追加する。

## Requirements

### Requirement 1: design.md の分量バジェット（design-principles.md）

#### Acceptance Criteria

1. The design-principles.md shall 複雑度連動の行数目安（軽微 ≤150 行 / 標準 ≤300 行 / 複雑 ≤600 行）を表形式で規定する
2. The design-principles.md shall 既存の「1000 行を超えたら複雑すぎる（分割検討）」の規定を維持する
3. The design-principles.md shall 目安超過時の扱いを「即 reject ではなく、超過理由を Overview 直後に 1〜3 行で明記」と規定する
4. The design-principles.md shall 簡潔化の規律として「既存コード片の逐語転載禁止（file:line 参照で代替）」「新規コードは契約（シグネチャ・入出力・エラー値）まで」「Requirements Traceability は 1 要件 1 行」「繰り返し構造の 1 回記述」を規定する
5. The design-principles.md shall 本バジェットが `design-review-gate.md` の Budget overflow check（タスク件数 / #147・#216）とは別概念であることを明記する

### Requirement 2: agent 定義への反映

#### Acceptance Criteria

1. The architect.md shall 「必ず先に読むルール」の design-principles 参照に分量バジェット節（目安値と規律の要約）への言及を含める
2. The developer.md shall impl-notes.md の分量目安（120 行以内）と守り方（テスト結果はサマリのみ・AC Traceability 1 要件 1 行・コード逐語転載禁止・超過時は理由明記）を規定する
3. The developer.md shall partial 報告の必須 2 セクション等、既存の出力契約上必要な記述を分量目安の例外として明示する

### Requirement 3: 同期・非破壊

#### Acceptance Criteria

1. The リポジトリ shall `.claude/{rules,agents}` と `repo-template/.claude/{rules,agents}` を byte 一致で同期する
2. The リポジトリ shall design-review-gate / tasks-generation の Mechanical Checks（Budget overflow check / checkbox enforcement / verify block）の判定基準・正準 regex を変更しない
3. The リポジトリ shall design.md の必須セクション集合を変更しない

## Out of Scope

- 行数の機械的 enforcement（harness gate 化）。まずは規約として導入し、効果を実測してから検討
- review-notes.md の分量規定（現状 92〜133 行で適正）
- requirements.md の分量規定（EARS の網羅性とトレードオフのため今回は対象外）
