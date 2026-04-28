# Requirements Document

## Introduction

idd-claude では、未完成機能を main にマージしても既存挙動を壊さないようにする手段として
「Feature Flag Protocol」（実装パターン: `if (flag) { 新挙動 } else { 旧挙動 }`）の採用を提案している。
ただし、この規約はすべてのプロジェクトに一律で押し付けるべきではない。プロジェクトによっては
flag 残置による技術債を嫌う、あるいは挙動が単純で flag が不要なケースが多い。そこで、
Feature Flag Protocol を **プロジェクト単位で opt-in / opt-out できる規約として明文化**し、
採用したプロジェクトでのみ Implementer / Reviewer がその規約に従って動くようにする。
本要件は、その規約宣言・参照・適用ルールを定義する。

## Requirements

### Requirement 1: Feature Flag Protocol の採否宣言

**Objective:** As a プロジェクト保守者, I want 自プロジェクトが Feature Flag Protocol を採用するかを CLAUDE.md で宣言できる, so that エージェントの挙動を自プロジェクトの方針に合わせられる

#### Acceptance Criteria

1. The repo-template CLAUDE.md shall Feature Flag Protocol の採否を宣言するための専用節を含む
2. The repo-template CLAUDE.md shall 採用 (opt-in) と不採用 (opt-out) を明示する宣言の書式を提示する
3. If 対象プロジェクトの CLAUDE.md に採否宣言が存在しない場合, the エージェント挙動決定プロセス shall opt-out（不採用）として解釈する
4. The repo-template CLAUDE.md shall opt-out をデフォルトとする旨を読み手が誤読しない形で明記する

### Requirement 2: 規約詳細ドキュメント

**Objective:** As a エージェント（Implementer / Reviewer）, I want Feature Flag Protocol の規約詳細を参照できるドキュメントが存在する, so that 採用プロジェクトで一貫した実装・レビューができる

#### Acceptance Criteria

1. The .claude/rules ディレクトリ shall Feature Flag Protocol の規約詳細を記したルールファイルを含む
2. The 規約詳細ルールファイル shall CLAUDE.md における opt-in / opt-out 宣言の記述書式を提示する
3. The 規約詳細ルールファイル shall flag 名の命名方針・初期値・有効化条件の記述要領を提示する
4. The 規約詳細ルールファイル shall flag 裏実装でカバーすべき要件（旧パスの保存・テスト両系統・クリーンアップ PR）を一覧で示す
5. The 規約詳細ルールファイル shall LaunchDarkly 等の外部プラットフォーム連携を扱わない旨を明記する

### Requirement 3: opt-in プロジェクトでの Implementer 動作

**Objective:** As a Implementer エージェント, I want CLAUDE.md の宣言に従って flag 裏実装をするかを判断できる, so that 採用プロジェクトでは未完成機能を flag で隠して安全にマージできる

#### Acceptance Criteria

1. When 対象プロジェクトの CLAUDE.md が Feature Flag Protocol を opt-in と宣言している場合, the Implementer プロンプト shall 新規挙動を flag 裏で実装し旧パスを温存する指示を含む
2. While Feature Flag Protocol が opt-in な状態, when Implementer が新規挙動を実装する, the Implementer shall flag-on パスと flag-off パスの両方が同一テストスイートで実行可能な状態を維持する
3. While Feature Flag Protocol が opt-in な状態, the Implementer shall flag-off パスの挙動を本機能導入前と同一に保つ
4. Where Feature Flag Protocol が opt-out, the Implementer プロンプト shall 通常の単一実装パス（flag 不使用）の指示のみを含む

### Requirement 4: opt-in プロジェクトでの Reviewer 動作

**Objective:** As a Reviewer エージェント, I want CLAUDE.md の宣言に従って flag 適用を確認するかを判断できる, so that 採用プロジェクトでは flag 規約違反を検知し、未採用プロジェクトでは過剰チェックをしない

#### Acceptance Criteria

1. When 対象プロジェクトの CLAUDE.md が Feature Flag Protocol を opt-in と宣言している場合, the Reviewer プロンプト shall flag 適用観点（旧パス保存・テスト両系統・命名規約）の確認指示を含む
2. Where Feature Flag Protocol が opt-out, the Reviewer プロンプト shall flag 観点の確認指示を含めない
3. While Feature Flag Protocol が opt-in な状態, when Reviewer が新規挙動の差分を読む, the Reviewer shall flag-off パスの挙動が本機能導入前と等価であることを差分から確認できる
4. If opt-in 宣言下で flag-off パスの挙動が変化している差分が検出された場合, the Reviewer shall reject 判定を出す

### Requirement 5: テストの両系統実行

**Objective:** As a プロジェクト保守者, I want flag-on / flag-off の両方でテストが実行される, so that 採用プロジェクトで両パスの回帰を防げる

#### Acceptance Criteria

1. While Feature Flag Protocol が opt-in な状態, the テスト実行プロセス shall 同一テストスイートを flag-on と flag-off の 2 通りで実行する
2. If flag-on 実行と flag-off 実行のいずれかが失敗した場合, the テスト実行プロセス shall 全体結果を失敗として扱う
3. The 規約詳細ルールファイル shall 両系統実行の責務を担う場所（ローカルコマンド・CI のいずれか）の指針を示す

### Requirement 6: クリーンアップ責務

**Objective:** As a プロジェクト保守者, I want 全タスク完了後に flag と分岐コードが除去される, so that flag が技術債として残存しない

#### Acceptance Criteria

1. The 規約詳細ルールファイル shall opt-in 採用プロジェクトにおいて全タスク完了後に flag 定義と `if (flag)` 分岐を除去する別 PR を作成する義務を明文化する
2. The 規約詳細ルールファイル shall クリーンアップ PR の起票責務（誰が起票するか、Implementer か人間か）を明記する
3. If クリーンアップ前に flag を持つ機能が複数積み上がった場合, the 規約詳細ルールファイル shall 残存 flag の棚卸し方針（時期的目安または件数閾値）を提示する

## Non-Functional Requirements

### NFR 1: 既存プロジェクトへの後方互換性

1. While 対象プロジェクトの CLAUDE.md が更新されていない状態, the Implementer プロンプトと Reviewer プロンプトの flag 関連指示 shall 本変更導入前と機能的に等価である（opt-out デフォルトの帰結として）
2. The repo-template/CLAUDE.md への Feature Flag 節の追加 shall 既存節の見出しテキストや見出し階層を破壊しない

### NFR 2: ドキュメント可読性

1. The Feature Flag 節と規約詳細ルールファイル shall opt-in 採用判断に必要な情報（メリット・デメリット・推奨ケース・非推奨ケース）を 1 ページ内で読み切れる分量に収める
2. The 規約詳細ルールファイル shall 採用宣言サンプル（opt-in / opt-out それぞれ）を 1 つずつ含む

### NFR 3: 言語・基盤非依存性

1. The Feature Flag Protocol の規約 shall 特定プログラミング言語・特定 SaaS（LaunchDarkly / Unleash / GrowthBook 等）への依存を要求しない

## Out of Scope

- LaunchDarkly / Unleash / GrowthBook 等の外部 Feature Flag 管理プラットフォームとの連携・移行
- Flag 値を実行時に動的変更する仕組み（A/B テスト、段階リリース、ユーザー属性別出し分け）
- Flag のテレメトリ収集（採用率・有効化日時の自動集計）
- 既存 idd-claude 自身（dogfooding 対象）を opt-in にする/しないの判断（本 PR では宣言節を追加するのみで、idd-claude 本体の採否は別 Issue で判断）
- watcher / install.sh / setup.sh / GitHub Actions ワークフローへの flag 反映（本要件はテンプレート規約・エージェントプロンプト生成への反映に限定）

## Open Questions

- **クリーンアップ PR の起票責務**: クリーンアップ PR を Implementer エージェントが自動起票するか、人間が手動で起票するかを Architect / 人間が決定する必要がある。Requirement 6.2 の選択肢を明示してほしい
- **テスト両系統実行の実現場所**: Requirement 5.3 における flag-on / flag-off テスト実行の責務を、(a) Implementer がローカルでスクリプトとして実装する、(b) CI 設定で実行する、(c) 規約上の指針提示にとどめプロジェクト各自が決める、のいずれにするかが未確定
- **採否宣言ブロックの形式**: CLAUDE.md 内での宣言ブロック形式を YAML front-matter / 特定 marker section / プレーンテキスト見出しのいずれにするかは Architect 判断
- **idd-claude 自身（dogfooding）の採否**: 本リポジトリ自身が opt-in するか opt-out するかは別 Issue で意思決定（Out of Scope に明記）
