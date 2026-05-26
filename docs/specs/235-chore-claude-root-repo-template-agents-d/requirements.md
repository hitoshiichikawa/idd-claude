# Requirements Document

## Introduction

root `.claude/agents/` と `repo-template/.claude/agents/` は別系統で二重管理されており（root = idd-claude self-hosting が使用、repo-template = `install.sh --repo` で consumer repo へ配布）、片方だけの更新でドリフトが蓄積している。developer / reviewer / project-manager / product-manager の 4 agent は root 固有節と template 固有節がそれぞれ存在し、単純な一方向コピーでは実在コンテンツの消失や `main` の焼き込みを招くため修復できない。実害として、root の developer.md / reviewer.md に per-task ループ・BLOCKED 規約が無いまま idd-claude が当該機能を有効化して稼働している。本件は両系統を byte 一致に揃える reconciliation（同期作業）であり、agent の挙動規約・判定基準・責務を変える新機能ではない。あわせて再発防止のスモークチェックを CLAUDE.md に追記する。

## Requirements

### Requirement 1: 4 agent の root↔repo-template reconciliation（固有コンテンツの union 保全）

**Objective:** As a idd-claude メンテナ, I want 4 agent の root 固有節と template 固有節をいずれも失わず両系統へ反映する, so that root（self-hosting）と consumer 配布の双方が同一の機能内容で動作する

#### Acceptance Criteria

1. When developer / reviewer / project-manager / product-manager の reconciliation を行うとき, the Reconciliation Process shall 各 agent の root 固有節と template 固有節の union を両系統へ反映し、いずれの固有コンテンツも削除しない
2. The Reconciliation Process shall 4 agent それぞれの挙動規約・判定基準・責務を変更しない（節の統合とパラメータ化のみを行い、新たな判定基準・責務を追加しない）
3. If reconciliation 対象が architect / debugger / qa の 3 agent であるとき, the Reconciliation Process shall 当該 agent を変更しない（既に両系統一致のため対象外）

### Requirement 2: base ブランチ参照のプレースホルダ統一

**Objective:** As a idd-claude メンテナ, I want base ブランチ参照を両系統で `<BASE_BRANCH>` プレースホルダに統一する, so that root に `main` を焼き込まず orchestrator が解決値を渡す前提を満たす

#### Acceptance Criteria

1. The 4 agent shall base ブランチ参照を両系統で `<BASE_BRANCH>` プレースホルダに統一する
2. When root 側に `main..HEAD` 等の具体値が残存しているとき, the Reconciliation Process shall それを `<BASE_BRANCH>` プレースホルダへ置換する
3. The 4 agent shall root 系統に `main` などの base ブランチ具体値を焼き込まない

### Requirement 3: 両系統の byte 一致

**Objective:** As a idd-claude メンテナ, I want reconciliation 完了後に agents 両系統が byte 一致になる, so that consumer 配布漏れと root の規約欠落の双方を解消する

#### Acceptance Criteria

1. When reconciliation が完了したとき, the `diff -r .claude/agents repo-template/.claude/agents` shall 空（差分なし）を返す
2. While reconciliation が完了している状態, the `.claude/agents` と `repo-template/.claude/agents` の 4 agent ファイル shall 相互に byte 一致である

### Requirement 4: CLAUDE.md への再発防止スモーク追記

**Objective:** As a idd-claude メンテナ, I want CLAUDE.md の静的解析手順に byte 一致検証スモークを追記する, so that 以後の片系統更新によるドリフトを検出できる

#### Acceptance Criteria

1. The CLAUDE.md 静的解析節 shall root↔repo-template の agents と rules の byte 一致を検証するスモークコマンド（`diff -r .claude/agents repo-template/.claude/agents` および `diff -r .claude/rules repo-template/.claude/rules`）を含む
2. Where 追記したスモークが記載されているとき, the CLAUDE.md shall 当該 diff が差分を返した場合に二重管理規約違反である旨を明示する

## Non-Functional Requirements

### NFR 1: 後方互換性（consumer repo への影響）

1. The Reconciliation Process shall consumer repo へ配布される repo-template の 4 agent の機能内容を変更しない（template は既に新しく、root が template に追従するため consumer の機能挙動に差分が生じない）
2. If reconciliation により consumer 配布物の機能挙動が変わる差分が発生する場合, the Reconciliation Process shall README に migration note を追加する

### NFR 2: 着手前提の検証可能性

1. The Reconciliation Process shall PR #234 および PR #233 がマージ済みであることを前提として着手する（両者は git log で確認済み）

## Out of Scope

- agent の新たな判定基準・責務・挙動規約の追加（本件はパラメータ化と節の統合のみ）
- architect / debugger / qa の 3 agent への変更（既に両系統一致）
- `.claude/rules/` の reconciliation（#233 で実施済み。本件のスモークは rules の検証コマンドを含むが、rules 本体の修正は対象外）
- CLAUDE.md / README の consumer 固有内容の同期（両者は root 用 / repo-template 用に内容が異なってよく二重管理規約の対象外）
- どの節をどう統合するか・パラメータ化の実装方法（design / Developer の領分。本件は design レスで Developer が直接実装する）
- 自動チェック（CI lint / pre-commit hook）による byte 一致の強制（本件はスモークコマンドの手順追記にとどめる）

## Open Questions

- なし
