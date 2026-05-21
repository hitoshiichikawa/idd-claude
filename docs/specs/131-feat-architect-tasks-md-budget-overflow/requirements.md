# Requirements Document

## Introduction

KeyNest #91 において、Developer エージェントが 60 turn の上限に到達して PR 作成に失敗し、
キャッシュトークンを消費したまま打ち切られる事例が発生した。根本原因は、Architect が生成した
`tasks.md` が `.claude/rules/tasks-generation.md` の「3〜10 件」ガイドラインを超えていたにも
かかわらず、Architect がその逸脱を事前検知せず確定してしまった点にある。

本機能では、Architect が `tasks.md` を確定する直前に **件数ベースの機械的な事前検知**
（Phase 1 / MVP）を導入し、Developer が turn budget を超過する前に Architect 段階で
consolidate（タスク統合）または split proposal（分割提案）による人間エスカレーションへ
誘導することで、自動実装パイプライン全体の失敗率と無駄なトークン消費を削減する。

Phase 2（推定 turn 数による soft warning）および Phase 3（実績データによるキャリブレーション）
は本要件のスコープ外候補とし、確認事項に明示する。

## Scope

### In Scope

- Architect エージェントが `tasks.md` 確定前に実行する **件数ベースの budget overflow 検知**
- 件数閾値に応じた enforcement パスの規定（consolidate / split proposal / `needs-decisions` ラベル付与）
- `design.md` に追記する `## Split Proposal` セクションの構造規定
- 検知ロジックの判定境界（10 / 11 / 13 / 14 件）のテスト容易性確保
- `.claude/rules/*.md` および `.claude/agents/architect.md`、ならびに `repo-template/` 配下の
  対応ファイルへの規約反映

### Out of Scope

- Developer 側の turn budget そのものの動的緩和（`MAX_TURNS` の自動調整など）
- Developer 内部の TaskCreate / TaskUpdate 呼び出し overhead の削減
- 推定 turn 数による soft warning（Phase 2 候補。確認事項参照）
- 実績データに基づく重み付けキャリブレーション（Phase 3 候補。確認事項参照）
- 既に main にマージ済みの過去 `tasks.md` への retroactive 適用
- Triage / PM / Developer / Reviewer など Architect 以外のエージェントのフロー変更

## Requirements

### Requirement 1: 件数ベースの budget overflow 判定

**Objective:** As an Architect agent, I want `tasks.md` のタスク件数を機械的に判定する手順を
持ちたい, so that Developer が turn budget を超過する前に過大な分割を検知できる。

#### Acceptance Criteria

1. When Architect が `tasks.md` を確定する直前のレビュー段階に到達したとき, the Architect Review Gate shall タスク件数を機械的にカウントする。
2. When カウント結果が 10 件以下のとき, the Architect Review Gate shall 追加アクションなしで pass と判定する。
3. When カウント結果が 11 件以上 13 件以下のとき, the Architect Review Gate shall まず consolidate（タスク統合）を試行することを Architect に要求する。
4. If consolidate 試行後もカウント結果が 11 件以上 13 件以下のままのとき, the Architect Review Gate shall `design.md` に `## Split Proposal` セクションを追加することを Architect に要求する。
5. When カウント結果が 14 件以上のとき, the Architect Review Gate shall consolidate を経由せず `## Split Proposal` セクション追加を強制する。
6. When `## Split Proposal` セクションを追加したとき, the Architect agent shall 対応する Issue に `needs-decisions` ラベルを付与する。
7. The Architect Review Gate shall 件数判定の対象と count 方法（どのマーカー／見出しを 1 件として数えるか）を `.claude/rules/` 配下の規約ファイルに明文化する。

### Requirement 2: Split Proposal セクションの構造

**Objective:** As a human reviewer, I want `## Split Proposal` セクションに分割判断に必要な
情報が揃っていることを期待する, so that 機械的な閾値超過通知だけでなく、Issue 分割の妥当性を
レビュー時に判断できる。

#### Acceptance Criteria

1. When Architect が `## Split Proposal` セクションを `design.md` に追加するとき, the Architect agent shall 分割が必要と判定した根拠（タスク件数・consolidate 試行結果の要約）を含める。
2. When Architect が `## Split Proposal` セクションを `design.md` に追加するとき, the Architect agent shall 分割候補となるサブ Issue 単位の名称と各サブ Issue が含むタスク群を列挙する。
3. The `## Split Proposal` セクション shall 分割後の各サブ Issue について、当該機能の `requirements.md` 上の対応 requirement ID（numeric ID）を明示する。
4. If 分割候補が Architect の判断で確定できないとき, the Architect agent shall `## Split Proposal` セクションに「人間判断を要する論点」を箇条書きで列挙する。

### Requirement 3: Escalation 経路

**Objective:** As an operator of idd-claude self-hosting, I want budget overflow が検出された
Issue が自動で人間判断待ち状態に遷移することを期待する, so that watcher が誤って Developer を
起動して再び turn budget 超過を起こすことを防げる。

#### Acceptance Criteria

1. When Architect agent が `## Split Proposal` セクションを追加したとき, the Architect agent shall 対応する Issue に `needs-decisions` ラベルを付与した状態で設計 PR を作成する。
2. While `needs-decisions` ラベルが付与されている間, the Issue Watcher shall 当該 Issue に対する Developer フェーズの自動起動を抑止する。
3. The Architect agent shall 設計 PR 本文に「budget overflow による split proposal 起票」である旨と、関連する `## Split Proposal` セクションへの参照を含める。
4. If 件数判定が pass（10 件以下）のとき, the Architect agent shall `needs-decisions` ラベル付与を行わない。

### Requirement 4: 後方互換性とテンプレート二重管理の整合

**Objective:** As an idd-claude maintainer, I want 本機能の規約反映が既存の self-hosting
運用と消費 repo（`repo-template/` 経由で配布された規約を持つ repo）を破壊しないことを期待する,
so that 既存ユーザーの Architect 実行が無告知で挙動変更しない。

#### Acceptance Criteria

1. When 本機能の規約が `.claude/rules/` および `.claude/agents/` に追加されたとき, the idd-claude repository shall `repo-template/` 配下の対応ファイルに同等の内容を反映する。
2. The idd-claude repository shall 既存の `tasks-generation.md` の「3〜10 件目安」ガイドラインと矛盾しない形で新しい件数閾値（10 / 11–13 / 14+）を規約に統合する。
3. When 既存の `tasks.md`（件数 ≤ 10 の正常ケース）が Architect レビューを通過するとき, the Architect Review Gate shall 本機能追加前と同じく追加アクションなしで pass と判定する。
4. If 件数判定ロジックを `.claude/rules/` に追加したことで `repo-template/` 既配置の consumer repo が次回 `install.sh` 再実行時に挙動変更を受けるとき, the idd-claude repository shall `README.md` に migration note を記載する。

### Requirement 5: 判定境界のテスト容易性

**Objective:** As an Architect agent (self-hosted on idd-claude), I want 件数判定の境界値が
回帰テストで確認できる状態であることを期待する, so that 規約改定や count ロジック変更時に
境界の挙動退行を検出できる。

#### Acceptance Criteria

1. The Architect Review Gate shall 判定境界（10 件 / 11 件 / 13 件 / 14 件）それぞれに対応する期待動作（pass / consolidate / split / forced split）を規約ファイル内のテストケースまたは fixture として参照可能にする。
2. When 件数 10 / 11 / 13 / 14 の各境界ケースに対してレビューを実行したとき, the Architect Review Gate shall 各ケースで Requirement 1 の AC 2〜5 に対応する分岐に一意に到達する。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The idd-claude repository shall 既に main で稼働している Architect の挙動を、`tasks.md` 件数が 10 件以下の場合に限り本機能導入前と完全に同一に保つ。
2. If 規約追加によって既存の `.claude/rules/tasks-generation.md` の既存 ID・既存セクション見出しを変更する必要があるとき, the idd-claude repository shall `README.md` に migration note を追加し、既存利用者への影響を明示する。

### NFR 2: 観測可能性

1. When budget overflow を検知したとき, the Architect agent shall 設計 PR 本文または PR コメントに、検知した件数と適用した分岐（consolidate / split / forced split）を明示する。
2. The Architect agent shall `needs-decisions` ラベル付与の理由として「tasks.md budget overflow」を識別可能な文字列として PR 本文に含める。

### NFR 3: テンプレート二重管理

1. The idd-claude repository shall `.claude/rules/` および `.claude/agents/` への変更と `repo-template/` 配下の対応変更を同一 PR で行う。
2. If `repo-template/` 配下と root の `.claude/` 配下の内容が乖離する状態を検出した場合, the idd-claude repository shall PR レビュー時に乖離点を確認事項として PR 本文に列挙する。

## Open Questions

以下は Issue 本文の「確認事項」および PM がドラフト中に気づいた追加の不明点。実装着手前に
Issue コメントで人間判断を仰ぐことを推奨する。

1. **閾値 10 / 11 の妥当性**: 過去事例では 11 件で成功・失敗が混在する。10 件を pass 上限とする
   選択は妥当か。あるいは「11 件は warning に留めて 12 件から escalation」など、より緩い
   設定が望ましいか。
2. **False positive の救済経路**: 本来 11 件以上でも完了可能な軽量タスク群であった場合、
   人間は `skip-triage` ラベルでバイパス可能とする運用で十分か。それとも本機能専用の
   bypass ラベル（例: `skip-budget-check`）を新設すべきか。
3. **Phase 1 単独で十分か / Phase 2 まで本 Issue に含めるか**: 件数ベース（Phase 1）のみで
   #91 と同型の事故を再発防止できる見込みか。それとも推定 turn 数による soft warning
   （Phase 2）まで実装しないと採用基準を満たさないか。
4. **件数のカウント対象**: Issue 本文は `## T-` セクション数を例示しているが、現行
   `.claude/rules/tasks-generation.md` は `- [ ] 1.` / `- [ ] 1.1` の numeric 階層 ID 形式を
   採用しており、`## T-` 見出し形式とは一致しない。実際の count 対象は (a) numeric ID の
   最上位タスク数（`- [ ] 1.` / `- [ ] 2.` ...）か、(b) 子タスクを含む全 checkbox 数か、
   (c) 別途新設する見出しマーカーか。design.md フェーズで確定が必要だが、要件としても
   人間判断を仰ぎたい。
5. **`needs-decisions` ラベルの意味多重化**: 既存運用で `needs-decisions` は PM フェーズで
   情報不足時にも付与される。budget overflow 由来かどうかを後段の運用で識別する必要が
   ある場合、専用ラベル（例: `tasks-budget-overflow`）を併用するか、PR 本文の識別文字列
   （NFR 2.2）のみで十分か。
6. **`design.md` ではなく `tasks.md` 末尾に Split Proposal を置く案との比較**: Issue 本文は
   `design.md` 追記を前提とするが、Split Proposal は実装計画の補足という性質上 `tasks.md`
   末尾に置く方が自然な可能性がある。配置先の最終確定を人間判断にエスカレーションしたい。
