# Requirements Document

## Introduction

Issue #132 は Developer エージェントの turn budget overflow（60 turn 上限の到達）と
内部 TODO トラッキング由来の overhead（TaskCreate / TaskUpdate が全 tool call の 29% を
占めていた）を改善するための **umbrella 親 Issue** です。本体の実装は 3 つのサブ Issue
（#133 / #134 / #135）に分割され、いずれも CLOSED かつ main に merge 済みです。
人間運用者は Issue #132 のコメントで rollout 順 Option A（#A→#B→#C すなわち #133→#134→#135）
を承認済みであり、3 件すべての merge が完了した現時点では、umbrella としての close-out
（締めくくり）作業のみが残っています。

本要件は「umbrella を閉じてよいと判断するための受入基準」を定義します。具体的には、
3 サブ Issue の成果物がリポジトリ内に揃っていることの確認、関連する規約 / エージェント
定義ファイルへの変更が実際に反映されていることの確認、umbrella spec ディレクトリへの
集約ドキュメント整備、README / CLAUDE.md レベルでの umbrella 視点の追加更新要否判定、
の 4 観点をカバーします。本要件は新規 feature 実装ではなく、umbrella クローズ作業の
完了基準を AC として束縛することを目的とします。

## Requirements

### Requirement 1: サブ Issue 完了の検証可能性

**Objective:** As a repository maintainer, I want umbrella #132 配下の 3 サブ Issue（#133 / #134 / #135）が closed かつ merge 済みであり、各 spec ディレクトリに成果物が存在することをリポジトリ内で確認できる, so that umbrella を閉じる前に各サブ Issue の完了状態を独立に検証できる

#### Acceptance Criteria

1. The Close-Out Process shall サブ Issue #133 の spec ディレクトリ（`docs/specs/133-feat-architect-developer-tasks-md-checkb/`）に `requirements.md` と `impl-notes.md` が存在することを umbrella close-out 前に確認する
2. The Close-Out Process shall サブ Issue #134 の spec ディレクトリ（`docs/specs/134-feat-developer-taskcreate-taskupdate-tas/`）に `requirements.md` と `impl-notes.md` が存在することを umbrella close-out 前に確認する
3. The Close-Out Process shall サブ Issue #135 の spec ディレクトリ（`docs/specs/135-feat-developer-independent-tool-1-turn-p/`）に `requirements.md` と `impl-notes.md` が存在することを umbrella close-out 前に確認する
4. If 上記 3 spec ディレクトリのいずれかに `requirements.md` または `impl-notes.md` が欠落している場合, the Close-Out Process shall umbrella close-out を保留し、欠落事実と原因を `docs/specs/132-feat-developer-developer-turn-budget-ove/impl-notes.md` に記録する
5. The Close-Out Process shall 3 サブ Issue のいずれかが closed 状態でない場合 umbrella close-out を保留する

### Requirement 2: 規約・エージェント定義ファイルへの反映確認

**Objective:** As a repository maintainer, I want 3 サブ Issue が変更すべきだった規約 / エージェント定義ファイルに、当該サブ Issue の趣旨に対応する変更が実際に取り込まれていることを umbrella レベルで再確認できる, so that 個別サブ Issue の merge 漏れや revert 事故に umbrella close-out 時点で気付ける

#### Acceptance Criteria

1. The Close-Out Process shall `.claude/rules/tasks-generation.md` に「すべての実装タスク行が `- [ ]` または `- [ ]*` の checkbox 形式で開始する」規約（#133 由来）が含まれていることを確認する
2. The Close-Out Process shall `.claude/rules/design-review-gate.md` に「tasks.md checkbox enforcement check」（#133 由来）が Mechanical Checks セクションに含まれていることを確認する
3. The Close-Out Process shall `.claude/agents/architect.md` に「tasks.md の checkbox 形式必須化」と整合したテンプレート・品質チェックリスト項目（#133 由来）が含まれていることを確認する
4. The Close-Out Process shall `.claude/agents/developer.md` に「TaskCreate / TaskUpdate の使用制限」節（#134 由来）が含まれていることを確認する
5. The Close-Out Process shall `.claude/agents/developer.md` に「Tool 呼び出しの並列化規律」または同等趣旨の規律ステートメント（#135 由来）が含まれていることを確認する
6. If 上記 5 項目のいずれかが該当ファイルに含まれていない場合, the Close-Out Process shall umbrella close-out を保留し、不足事実と該当サブ Issue 番号を `docs/specs/132-feat-developer-developer-turn-budget-ove/impl-notes.md` に記録する

### Requirement 3: umbrella spec ディレクトリの整備

**Objective:** As a repository maintainer, I want umbrella Issue #132 の趣旨と close-out 状態を集約した spec ディレクトリと `impl-notes.md` を残す, so that 後続の運用者が umbrella の全体像と 3 サブ Issue への入口を 1 箇所から辿れる

#### Acceptance Criteria

1. The Close-Out Process shall `docs/specs/132-feat-developer-developer-turn-budget-ove/` ディレクトリに `requirements.md`（本ファイル）と `impl-notes.md` を残す
2. The `impl-notes.md` shall umbrella #132 の趣旨（Developer turn budget overflow / TaskCreate overhead 29% の問題と 10% 以下 / 2.5+ tool call per turn への改善目標）を 1 段落以上で要約する
3. The `impl-notes.md` shall 3 サブ Issue（#133 / #134 / #135）の spec ディレクトリへの相対パスリンクをそれぞれ 1 件以上記載する
4. The `impl-notes.md` shall rollout 順 Option A（#133 → #134 → #135）が人間運用者承認のもとで適用された旨を記録する
5. Where Requirement 1 / Requirement 2 の確認結果に不足や懸念が発生した場合, the `impl-notes.md` shall 当該事実と対応方針（別 Issue 起票 / 暫定回避 / 既知の制約として受容 等）を 1 項目以上記録する

### Requirement 4: README / CLAUDE.md への umbrella レベル更新要否判定

**Objective:** As a repository maintainer, I want umbrella レベルで README または CLAUDE.md に追加更新が必要かを明示的に判定し、不要と結論した場合もその根拠を残す, so that umbrella close-out 時点で「漏れによる README 不整合」と「意図的な non-update」を区別できる

#### Acceptance Criteria

1. The Close-Out Process shall README.md と CLAUDE.md について umbrella #132 として追加更新が必要かを明示的に判定する
2. When 各サブ Issue（#133 / #134 / #135）が README または CLAUDE.md の必要箇所を既に更新していると判定したとき, the Close-Out Process shall 追加更新を行わず、その判定根拠を `docs/specs/132-feat-developer-developer-turn-budget-ove/impl-notes.md` に記録する
3. If umbrella レベルで補完すべき README または CLAUDE.md の不整合をクローズ前に発見した場合, the Close-Out Process shall 同一 PR 内で補完するか、別 Issue として起票するかを判断し、いずれの方針を採ったかを `impl-notes.md` に記録する
4. The Close-Out Process shall README / CLAUDE.md の挙動説明と各サブ Issue で更新済みの規約 / エージェント定義の間に矛盾が無いことを目視確認する

### Requirement 5: スコープ境界の維持

**Objective:** As a repository maintainer, I want umbrella close-out 作業のスコープが 3 サブ Issue の完了確認とドキュメント集約に限定され、新規 feature や挙動変更を含まないことを束縛する, so that close-out PR が unintended な挙動変更を引き連れず、レビュー範囲を予測可能に保てる

#### Acceptance Criteria

1. The Close-Out Process shall 3 サブ Issue で merge 済みの規約 / エージェント定義 / テンプレートの挙動を変更しない
2. The Close-Out Process shall 新規の規律 / 数値目標 / 計測機構 / ハード制限を本 umbrella close-out に追加導入しない
3. If umbrella close-out 中に追加対応が必要な事項が発見された場合, the Close-Out Process shall 当該事項を別 Issue として起票する方針を採り、本 close-out PR にコード変更として含めない
4. The Close-Out Process shall 既存の env var 名 / ラベル名 / cron 登録文字列 / exit code 意味の後方互換性を変更しない

## Non-Functional Requirements

### NFR 1: 検証可能性

1. The Close-Out Process shall Requirement 1 / Requirement 2 で要求する各確認項目を、第三者（人間レビュワーや別エージェント）がリポジトリ checkout 状態で 10 分以内に独立に再確認できる粒度で `impl-notes.md` に記録する
2. The `impl-notes.md` 内の確認結果記録 shall 確認対象ファイルへの相対パス、対象節の見出し名または行範囲、確認時のコミット SHA または日時のいずれか 1 つ以上を含む

### NFR 2: 既存ドキュメント整合性

1. The umbrella `requirements.md` および `impl-notes.md` shall 既存ルール群（`.claude/rules/ears-format.md` / `requirements-review-gate.md` / `design-principles.md` / `tasks-generation.md` / `design-review-gate.md` / `feature-flag.md`）と矛盾する記述を含まない
2. The umbrella close-out 成果物 shall `.claude/rules/issue-dependency.md` の canonical 記法（`Parent:` / `Depends on:` 等）と整合した形でサブ Issue を参照する

### NFR 3: 言語方針との整合

1. The umbrella `requirements.md` および `impl-notes.md` shall CLAUDE.md「言語方針」節に従い、本文は日本語ベースで記述し、EARS トリガーキーワード（`When` / `If` / `While` / `Where` / `shall`）と識別子 / ファイルパス / コマンド名は英語固定で記述する

## Out of Scope

- 各サブ Issue（#133 / #134 / #135）の規約 / エージェント定義そのものの追加変更や挙動修正（merge 済みの内容に対する変更は別 Issue で扱う）
- Developer 実行ログからの TaskCreate / TaskUpdate 比率や tool call/turn 比率の **本 close-out PR 内での新規計測**（計測手順は #134 / #135 で定義済み、本 umbrella では計測手順自体の変更や新規実行は要求しない）
- harness（`local-watcher/bin/issue-watcher.sh`）への自動計測機構や自動ダッシュボードの追加
- 他エージェント（PM / Architect / Reviewer / Project Manager / Debugger）への並列化規律 / TaskCreate 制限の横展開
- TaskCreate / TaskUpdate のハード制限（tool 自体の無効化）導入
- Claude Code SDK 側への subagent-specific reminder 抑制機能追加の実装
- 既に merge 済みの過去 Developer 実行（ログ / PR）への遡及的な計測・是正・retrofit
- 新規サブ Issue の追加切り出し（必要が判明した場合は別 Issue として独立起票し、本 umbrella の close-out には含めない）

## Open Questions

なし。Issue #132 本文の論点（rollout 順）は人間運用者により Option A（#133 → #134 → #135）で承認済み、かつ 3 サブ Issue は既に CLOSED かつ main に merge 済みであるため、umbrella close-out に必要な人間判断は完了している。

なお、Issue #132 当初の効果目標（TaskCreate / TaskUpdate 比率 29% → 10% 以下、tool call/turn 比率 1.7 → 2.5+）の **実測による達成判定** は #134 / #135 の各 requirements で計測手段 / 達成目標が既に束縛されており、本 umbrella requirements としては再記述しない。close-out 後の実測トラッキングが必要な場合は別 Issue として独立に起票する想定である。
