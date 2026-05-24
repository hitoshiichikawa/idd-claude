# Requirements Document

## Introduction

consumer リポ（idd-claude テンプレートを配置した実プロジェクト）へ agents / rules の更新だけを安全に同期したいケースで、現状の `install.sh` には安全な手段がない。`--force` なしでは既存 `.bak` 起因で `.claude/*.md` が stale なまま据え置かれ、`--force` を付けると agents / rules は更新される一方で consumer がプロジェクト固有に編集した `CLAUDE.md` まで汎用 template で上書きされてしまう（live が汎用版に置換され、技術スタック・コード規約・Feature Flag 採否などが失われる）。watcher の各 subagent は runtime で consumer の `CLAUDE.md` を読むため、復元するまで誤った前提で動作する重大な問題が初回 `--force` で確実に発生する。本要件は `--force` 単体では `CLAUDE.md` を絶対に template 上書きせず、agents / rules / ISSUE_TEMPLATE 等の idd-claude 配布物のみ force 同期できるようにすることを定義する。

## Requirements

### Requirement 1: `--force` 単体での CLAUDE.md 保護

**Objective:** As a consumer リポの運用者, I want `--force` を付けても自分の `CLAUDE.md` が template で上書きされないこと, so that agents / rules を force 同期してもプロジェクト固有の技術スタック・規約・Feature Flag 採否が失われない

#### Acceptance Criteria

1. When `--force` を指定して install.sh を実行し既存 `CLAUDE.md` が template と差分あり, the install.sh shall 既存 `CLAUDE.md` を live で据え置き template 上書きを行わない
2. When `--force` を指定して install.sh を実行し既存 `CLAUDE.md` が template と差分あり, the install.sh shall 最新 template を `CLAUDE.md.org` として並置する（`.org` 不在なら新規作成、`.org` 既存かつ差分ありなら最新 template に更新）
3. When `--force` を指定して install.sh を実行し既存 `CLAUDE.md` が template と内容同一, the install.sh shall `CLAUDE.md` と `CLAUDE.md.org` のいずれも作成・変更しない
4. When `--force` を指定して install.sh を実行し対象パスに `CLAUDE.md` が不在, the install.sh shall template を `CLAUDE.md` として新規配置し `CLAUDE.md.org` は作成しない
5. While `--force` 単体が指定された状態, the install.sh shall `CLAUDE.md` を `CLAUDE.md.bak` へ退避する処理を実行しない

### Requirement 2: CLAUDE.md 明示オプトイン上書き（`--force-claude-md`）

**Objective:** As a 従来の完全上書き挙動を必要とする運用者, I want CLAUDE.md を template で上書きする明示フラグ, so that 意図的に template へ揃えたいときだけ旧来の上書き挙動を呼び出せる

#### Acceptance Criteria

1. When `--force-claude-md` を指定して install.sh を実行し既存 `CLAUDE.md` が template と差分あり, the install.sh shall 既存 `CLAUDE.md` を `CLAUDE.md.bak` へ once-only 退避してから template で上書きする
2. While `--force-claude-md` が指定された状態, the install.sh shall 既存 `CLAUDE.md.bak` を再退避せず温存する（once-only 規律）
3. When `--force-claude-md` を指定して install.sh を実行し CLAUDE.md を template 上書きする, the install.sh shall `CLAUDE.md.org` を作成・変更しない
4. Where `--force-claude-md` が指定されていない, the install.sh shall `CLAUDE.md` を template で上書きしない（`--force` の有無に関わらず）
5. When `--force-claude-md` と `--force` を併用して install.sh を実行, the install.sh shall agents / rules を force 同期しつつ `CLAUDE.md` を template 上書きする

### Requirement 3: agents / rules の force 同期維持

**Objective:** As a consumer リポの運用者, I want `--force` で `.claude/agents/` `.claude/rules/` の stale を確実に更新できること, so that developer.md 等の規約追記を手動コピーなしで同期できる

#### Acceptance Criteria

1. When `--force` を指定して install.sh を実行し `.claude/agents/*.md` または `.claude/rules/*.md` が template と差分ありかつ `<file>.bak` 不在, the install.sh shall `<file>.bak` を once-only 退避してから template で上書きする
2. When `--force` を指定して install.sh を実行し `.claude/agents/*.md` または `.claude/rules/*.md` が template と差分ありかつ `<file>.bak` 既存, the install.sh shall 既存 `.bak` を温存したまま template で上書きする
3. While `--force` が指定されていない状態, when `.claude/agents/*.md` または `.claude/rules/*.md` が差分ありかつ `<file>.bak` 既存, the install.sh shall 当該ファイルを SKIP し `use --force to overwrite` 警告を表示する
4. The install.sh shall ISSUE_TEMPLATE / workflows / labels script 等 CLAUDE.md 以外の idd-claude 配布物について `--force` 導入前と同一の配置挙動を維持する

### Requirement 4: 冪等性の不変

**Objective:** As a 運用者, I want 検証済みの冪等性が壊れないこと, so that install.sh を consumer 同期の正規ツールとして繰り返し安全に実行できる

#### Acceptance Criteria

1. When 同一引数で install.sh を 2 回以上実行し対象ファイルが template と内容同一, the install.sh shall 2 回目以降を SKIP し対象ファイルを変更しない
2. The install.sh shall `CLAUDE.md.bak` および `<file>.bak` を初回のみ作成しその後の再実行で内容を変更しない（once-only 規律）
3. While いずれのオプションが指定された状態でも, the install.sh shall 既存 `CLAUDE.md.bak` を読み取り・上書き・削除しない（CLAUDE.md 専用ロジック経路から `.bak` を改変しない）

### Requirement 5: dry-run 出力分類の整合

**Objective:** As a 運用者, I want `--dry-run` の予定操作表示が実挙動と一致すること, so that 実行前に CLAUDE.md が保護されることを確認できる

#### Acceptance Criteria

1. When `--dry-run --force` を指定して install.sh を実行し既存 `CLAUDE.md` が差分あり, the install.sh shall `CLAUDE.md` を SKIP（据え置き）+ `CLAUDE.md.org` を NEW/OVERWRITE として分類表示する
2. When `--dry-run --force` を指定して install.sh を実行し `.claude/agents/*.md` または `.claude/rules/*.md` が差分あり, the install.sh shall 当該ファイルを OVERWRITE（必要時 BACKUP 付き）として分類表示する
3. When `--dry-run --force-claude-md` を指定して install.sh を実行し既存 `CLAUDE.md` が差分あり, the install.sh shall `CLAUDE.md` を BACKUP + OVERWRITE として分類表示する
4. While `--dry-run` が指定された状態, the install.sh shall いかなるファイルシステム変更も行わずに分類表示のみ出力する

### Requirement 6: 文書化と migration note

**Objective:** As a 既存の `--force` 利用者, I want 挙動変更が明記されていること, so that 「`--force` で CLAUDE.md が更新されなくなる」点を把握して運用を調整できる

#### Acceptance Criteria

1. The README shall 「`--force` 指定時も `CLAUDE.md` は据え置き + `CLAUDE.md.org` 並置になり template 上書きされない」旨を migration note として明記する
2. The README shall CLAUDE.md を template 上書きしたい場合に `--force-claude-md` を使用する旨を明記する
3. The install.sh ヘッダコメント shall `--force` と `--force-claude-md` の CLAUDE.md に対する挙動差を記載する
4. When `-h` または `--help` を指定して install.sh を実行, the install.sh shall `--force-claude-md` を含むオプション一覧を表示する
5. While 既存 `CLAUDE.md` が据え置かれ template が `.org` として並置された状態, the install.sh shall merge ガイドメッセージで CLAUDE.md 上書き手段として `--force-claude-md` を案内する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The install.sh shall 既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `IDD_CLAUDE_SKIP_LABELS` 等）の意味と既定値を変更しない
2. The install.sh shall 既存の exit code（成功時 0、未知オプション時 1）の意味を変更しない
3. The install.sh shall `log_action` のログ書式（`[INSTALL]` / `[DRY-RUN]` prefix と `NEW` / `OVERWRITE` / `SKIP` / `BACKUP` の語彙）を維持する
4. While `--force` も `--force-claude-md` も指定されていない通常経路, the install.sh shall 本変更導入前と同一の挙動（CLAUDE.md 据え置き + 差分時 `.org` 並置）を保つ

### NFR 2: ユーザースコープ前提の維持

1. The install.sh shall いかなる新規オプション経路でも sudo を要求しない（root 実行検知を維持する）

## Out of Scope

- LaunchDarkly / Unleash 等の外部 Feature Flag SaaS 連携（Feature Flag Protocol スコープ外）
- 既存 consumer リポに残る stale な `CLAUDE.md.bak` の自動マイグレーションや復元
- `CLAUDE.md.org` の自動 merge / 自動取り込み（手動 merge ガイドの提示のみ）
- agents / rules 同期そのもののアルゴリズム変更（既存 `copy_with_hybrid_overwrite` の挙動は維持し、CLAUDE.md 経路の分離のみが対象）
- GitHub ラベルセットアップ / ISSUE_TEMPLATE / workflow 配置ロジックの変更
- setup.sh（ローカル watcher 配置）側の挙動変更

## Open Questions

確認事項（設計者・人間が判断すべき点）:

1. **`--force-claude-md` オプトインの採否（PM 推奨: 採用）**: 本要件では Issue 代替案に沿って `--force-claude-md` を新設し、`--force` 単体では CLAUDE.md を一切上書きしない方針を採用した。採用理由は (a) Issue の主害（`--force` が consumer 固有 CLAUDE.md を silent 上書き）を確実に解消する、(b) 従来の完全上書き能力を意図明示フラグの背後に温存し manual copy への退化を防ぐ、(c) 既存 `copy_claude_md_with_org` の `FORCE=true` 分岐を新フラグ `FORCE_CLAUDE_MD` 駆動に付け替えるだけで実装影響を局所化できる、の 3 点。もし運用上の単純さを最優先し「`--force` で CLAUDE.md は完全に触らない（上書き手段を install.sh から廃止し手動運用に委ねる）」線を選ぶ場合は Requirement 2 を削除する判断が必要。設計着手前に確定したい。
2. **フラグ名の確定**: `--force-claude-md` を canonical とするか、`--force-claude` 等の短縮形を許容するか。env var による override（例: `FORCE_CLAUDE_MD=true`）を併せて提供するかは Architect 判断（既存 env var 互換性 NFR 1.1 を壊さない範囲）。
3. **既存 README 記述の更新範囲**: README には現状「`--force` 指定時は CLAUDE.md を template 上書きする」旨が複数箇所（オプション表 / 例示出力 / migration note）に記載されている。これらを今回の挙動に合わせて全面改訂する範囲は design.md で File Structure Plan として確定する。
