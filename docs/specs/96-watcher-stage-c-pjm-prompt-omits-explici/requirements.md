# Requirements Document

## Introduction

idd-claude は `BASE_BRANCH` 環境変数（Actions 経路では `IDD_CLAUDE_BASE_BRANCH`）で
PR の base を切り替える単一の真実源を持つが、現状の Watcher が組み立てる Stage C プロンプト
（および design モードの単発プロンプト、Actions ワークフローの相当プロンプト）には PjM
サブエージェントに対して「PR の base を解決済みの base ブランチに合わせよ」という肯定的な指示が存在しない。
唯一の言及は「`${BASE_BRANCH}` に直接 push しないこと」という否定形の制約だけであり、PjM
（`project-manager` サブエージェント）は `gh pr create --base` を省略 → GitHub のデフォルト
（多くの場合 `main`）が選ばれる結果として、`BASE_BRANCH=develop` を設定しているリポジトリでも
PR が `main` を base に作られる事故が発生している。本 Issue では、PjM が必ず解決済み base
ブランチを `--base` で明示するよう、Watcher プロンプト・Actions プロンプト・PjM エージェント
定義の役割境界で観察可能な振る舞いを定義する。後方互換性として、`BASE_BRANCH` 未設定時は
従来どおり `main` にフォールバックする挙動を保つ。

## Requirements

### Requirement 1: PjM が作成する PR の base ブランチ整合性

**Objective:** As an idd-claude 運用者, I want PjM が作成する PR の base が常に Watcher で解決された `BASE_BRANCH` と一致すること, so that `BASE_BRANCH=develop` を設定したリポジトリで PR が誤って `main` を base に作られる事故が起きない

#### Acceptance Criteria

1. When PjM サブエージェントが implementation モードで PR を作成するとき, the Watcher Orchestration Prompt shall PjM に対し「`--base <解決済み BASE_BRANCH 値>` を明示して PR を作成せよ」という肯定的な指示を含める
2. When PjM サブエージェントが design-review モードで設計 PR を作成するとき, the Watcher Orchestration Prompt shall PjM に対し「`--base <解決済み BASE_BRANCH 値>` を明示して設計 PR を作成せよ」という肯定的な指示を含める
3. When `BASE_BRANCH=develop` が設定された状態で Watcher が PjM を起動して PR を作成したとき, the Resulting Pull Request shall `baseRefName=develop` で作成される
4. When `BASE_BRANCH` 環境変数が未設定の状態で Watcher が PjM を起動して PR を作成したとき, the Resulting Pull Request shall `baseRefName=main` で作成される
5. If 解決済み `BASE_BRANCH` 値が空文字または未定義としてプロンプトに渡されようとした場合, the Watcher Orchestration Layer shall PR 作成段階に進ませず、当該サイクルを失敗扱いとして人間にエスカレーションする

### Requirement 2: PjM 起動指示における base ブランチの一意な伝達

**Objective:** As a PjM エージェント, I want 解決された base ブランチ名がプロンプトから一意に読み取れること, so that `<BASE_BRANCH>` がプレースホルダ文字列なのか実際の値なのかを推測する余地が無くなる

#### Acceptance Criteria

1. The Watcher Orchestration Prompt shall PjM 起動セクション内で base ブランチを「実値（リテラル文字列）」として 1 箇所以上に提示する
2. When プロンプト内で base ブランチが指示されるとき, the Watcher Orchestration Prompt shall プレースホルダ表記（`<BASE_BRANCH>` / `${BASE_BRANCH}` 等）ではなく、当該サイクルの解決済み実値を埋め込む
3. The Project Manager Agent Definition shall PR 作成時の `--base` 引数値を「呼び出し元プロンプトに記載された解決済み base ブランチ値を一意に採用する」と明記する
4. If PjM 起動プロンプト内に base ブランチの実値が含まれていない場合, the Project Manager Agent shall PR 作成を中断し、Issue に `claude-failed` ラベルを付与して人間にエスカレーションする

### Requirement 3: PR 作成後の base 整合性検証

**Objective:** As an idd-claude 運用者, I want PR 作成直後に base ブランチが期待値であることを検証してほしい, so that 万一 PjM が指示に従わずデフォルト base で PR を作成しても、誤マージ前に検出して切り戻せる

#### Acceptance Criteria

1. When PjM が `gh pr create` の実行を完了したとき, the Project Manager Agent shall 作成された PR の `baseRefName` を取得し、Watcher から受け取った解決済み `BASE_BRANCH` 値と一致するか検証する
2. If 検証の結果 `baseRefName` が解決済み `BASE_BRANCH` 値と異なる場合, the Project Manager Agent shall 当該 PR の base を解決済み `BASE_BRANCH` 値に修正する、または PR 作成を失敗扱いとして Issue に状況を報告する
3. The Project Manager Agent shall 検証結果（一致 / 不一致 / 修正実施の有無）を Watcher のログまたは PR 作成サマリから操作者が確認可能な形で残す

### Requirement 4: 既存挙動の後方互換性

**Objective:** As an idd-claude 既存ユーザー, I want 本機能の導入によって `BASE_BRANCH` を設定していない既存リポジトリの挙動が変化しないこと, so that 既稼働の cron / launchd / GitHub Actions セットアップが暗黙裏に壊れない

#### Acceptance Criteria

1. When `BASE_BRANCH` 環境変数が未設定の状態で Watcher を実行したとき, the Watcher shall 解決後の base ブランチ値として `main` を採用する（本機能導入前と同一）
2. When `BASE_BRANCH` 環境変数が未設定の状態で PjM が PR を作成したとき, the Resulting Pull Request shall `baseRefName=main` で作成される（本機能導入前と同一）
3. The Project Manager Agent Definition shall design-review モードと implementation モードの双方で base ブランチを明示する規約を採用し、片方のモードだけ規約を導入する状態を作らない
4. The Watcher Orchestration Prompt shall 既存の `${BASE_BRANCH} に直接 push しないこと` という否定形の制約を維持する（base 明示の追加指示はこの制約と矛盾しない補強として並置される）

### Requirement 5: 経路間の挙動一貫性

**Objective:** As an idd-claude 運用者, I want Local Watcher 経路と GitHub Actions 経路で PR の base 解決挙動が一致すること, so that 利用経路を切り替えても PR base の挙動差で混乱しない

#### Acceptance Criteria

1. When GitHub Actions 経路で PjM 相当の手順により PR が作成されたとき, the Actions Workflow Prompt shall PjM に対して `--base <解決済み IDD_CLAUDE_BASE_BRANCH 値>` を明示する指示を含める
2. When Local Watcher と GitHub Actions の両経路で同一の `BASE_BRANCH` / `IDD_CLAUDE_BASE_BRANCH` 値が設定されているとき, the Resulting Pull Request shall 両経路で同一の `baseRefName` 値で作成される
3. The Watcher Orchestration Prompt and Actions Workflow Prompt shall design モード（設計 PR）と impl / impl-resume モード（実装 PR）の全モードで base 明示指示をカバーする

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher shall `BASE_BRANCH` 未設定リポジトリで本機能導入前と同一の PR base（`main`）を生成し続ける
2. The Watcher shall 既存の env var 名（`BASE_BRANCH` / `IDD_CLAUDE_BASE_BRANCH`）・既存のラベル名・既存の exit code 意味を変更しない

### NFR 2: 可観測性

1. The Project Manager Agent shall PR 作成完了時に「`--base` に指定した値」「作成された PR の `baseRefName`」「両者が一致したか」のいずれかを操作者が PR 本文・PR コメント・Watcher ログのいずれかから確認可能な形で残す
2. If base 不整合が検出された場合, the Project Manager Agent shall 検出事実とその後の対応（自動修正 / 失敗エスカレーション）を Issue コメントまたは Watcher ログから 1 回の操作で追跡可能にする

### NFR 3: ドキュメント整合性

1. When 本機能による挙動変更が確定したとき, the README and PjM Agent Definition shall PR base 解決の規約を整合的に説明する記述を持つ（README の「ブランチ運用と `BASE_BRANCH`」節と `.claude/agents/project-manager.md` の base 引数の規約が矛盾しない）

## Out of Scope

- `BASE_BRANCH` の値そのものの自動推定（リポジトリのデフォルトブランチ検出など）。本 Issue では Watcher が env から受け取った値を「正として」PjM に渡す挙動だけを扱う
- `MERGE_QUEUE_BASE_BRANCH` の挙動変更（Phase A Merge Queue Processor の rebase 対象 base は本 Issue のスコープ外）
- 既存 PR の base を一括で修正する移行スクリプト（本機能は本機能適用後に新規作成される PR にのみ作用する）
- Triage プロンプトおよび Reviewer プロンプトの修正（PR を作成しない役割のため base 明示は不要）
- `.claude/agents/project-manager.md` の auto-close キーワード検出ロジックなど、PR base 解決以外の規約改修

## Open Questions

- なし（Issue 本文に「修正案」「副次案」が明示されており、観察可能な振る舞いとして要件化可能。実装手段（どの bash 関数を編集するか、`gh pr view --json baseRefName` をどこで呼ぶか等）は design.md の領分）
