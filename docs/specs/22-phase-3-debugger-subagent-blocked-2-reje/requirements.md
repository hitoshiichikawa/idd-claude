# Requirements Document

## Introduction

現行の Reviewer / Developer サイクル（Issue #20 で導入された Round 1 + 1 回差し戻し）では、
Round 2 reject 時点で `claude-failed` に escalate され、人間が原因究明（外部ライブラリの ABI、
フレームワーク内部の挙動、CI 環境固有の制約など、Developer の単一 context では見えない隠れた
前提）を肩代わりする必要がある。また Developer 自身が「context 内では原因不明」と判断した
場合も、現状は `claude-failed` 経路で人間に escalate するしかない。

本機能では **Debugger サブエージェント** を新設し、(a) Reviewer Round 2 reject の直前、
または (b) Developer が `impl-notes.md` に `BLOCKED: <reason>` を明示宣言した時点で、
clean context + web search 可の独立 Claude CLI セッションで起動する。Debugger は **コードを
書き換えず Fix Plan のみを `debugger-notes.md` に出力**し、後続の Developer 再起動プロンプトに
その Fix Plan を注入することで、context 汚染なしに再試行できるようにする。

本機能は **opt-in（`DEBUGGER_ENABLED=true` で明示有効化）** であり、既定では未指定 / `=false`
として現行の Reviewer Round 1/2 + `claude-failed` 経路が一切変化しない。Phase 2（Issue #21）
の per-task loop が有効な場合は、task 単位で同じ Debugger トリガー判定を適用する。

## Requirements

### Requirement 1: opt-in による既存挙動の保全

**Objective:** As a 既存 install 済みリポジトリの運用者, I want 本機能を opt-in でのみ有効化したい, so that 既定では現行の Reviewer Round 1/2 + `claude-failed` 経路が一切変化せず移行コストを発生させない

#### Acceptance Criteria

1. While `DEBUGGER_ENABLED` 環境変数が未設定または `false` である間, the Issue Watcher shall Issue #20 で確立された Reviewer Round 1 / Round 2 + `claude-failed` 付与経路を本機能導入前と同一の挙動で動作させる
2. While `DEBUGGER_ENABLED` 環境変数が未設定または `false` である間, the Issue Watcher shall Developer が `impl-notes.md` に `BLOCKED: <reason>` を出力したか否かを判定材料に用いず、現行の Developer 失敗時遷移（`claude-failed` 付与）をそのまま適用する
3. The Issue Watcher shall `DEBUGGER_ENABLED` の受理値を `true` / `false` の 2 値とし、それ以外の値（空文字 / `1` / `True` / 不正値 / 大文字小文字違い）は `false` と等価に扱う
4. The Issue Watcher shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `REVIEWER_MODEL` 等）の意味と受理形式を本変更で改変しない
5. The Issue Watcher shall 既存ラベル（`auto-dev` / `claude-claimed` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-decisions` / `skip-triage` / `needs-rebase` / `needs-iteration` / `staged-for-release`）の名称・付与契約・遷移意味を本機能で変更しない

### Requirement 2: Debugger サブエージェントの定義と入出力契約

**Objective:** As a 開発者, I want Debugger エージェントが他のエージェント（PM / Architect / Developer / Reviewer / PjM）と同階層に独立サブエージェントとして配置されること, so that 既存エージェントの責務に巻き込まれず、根本原因分析の責務に専念できる

#### Acceptance Criteria

1. The Repository shall `repo-template/.claude/agents/debugger.md` に Debugger エージェント定義を配置し、idd-claude self-hosting 用に同階層へ同内容を配置する
2. When Debugger エージェントが起動される, the Debugger Agent shall 対象タスクの `tasks.md` 該当行 / `requirements.md` の関連 AC / Developer の `impl-notes.md` ログ / Reviewer の `review-notes.md` reject 理由 / `git diff <BASE_BRANCH>..HEAD` / web search 結果を入力として参照できる状態で実行される
3. When Debugger エージェントが終了する, the Debugger Agent shall `docs/specs/<番号>-<slug>/debugger-notes.md` を新規作成または追記し、Fix Plan（根本原因 / 具体的修正手順 / 関連 web search 結果の引用）を構造化 markdown 形式で書き出す
4. The Debugger Agent shall コードファイル（`docs/specs/<番号>-<slug>/` 配下を除く実装ファイル）を書き換えず、ラベル付け替えやコミット作成を行わない
5. The Debugger Agent shall `requirements.md` / `design.md` / `tasks.md` / `review-notes.md` を書き換えない
6. The Debugger Agent shall 同じ Issue で過去に Reviewer / Developer 役を担った Claude CLI セッションの context を継承せず、fresh な独立 Claude CLI セッションで起動される

### Requirement 3: Reviewer Round 2 reject 直前の Debugger 起動

**Objective:** As a 開発者, I want Reviewer Round 2 reject の直前に Debugger を 1 回だけ介在させたい, so that 現行の `claude-failed` escalate に直行する前に、外部ライブラリ ABI や CI 固有制約などの隠れた前提を root cause 分析できる

#### Acceptance Criteria

1. While `DEBUGGER_ENABLED=true` である間, when Reviewer Round 2（Stage B'）が `reject` を出力した, the Issue Watcher shall `claude-failed` 付与の直前に Debugger を fresh な Claude CLI セッションで 1 回だけ起動する
2. When Debugger が Fix Plan を `debugger-notes.md` に出力して正常終了した, the Issue Watcher shall Developer を再起動（Stage A''）し、Debugger の Fix Plan を当該 Developer のプロンプトに inline で注入する
3. When Debugger 経由の Developer 再起動（Stage A''）が正常終了した, the Issue Watcher shall Reviewer Round 3（Stage B''）を fresh な Claude CLI セッションで起動する
4. When Reviewer Round 3 が `approve` を出力した, the Issue Watcher shall 通常の approve 後遷移（PjM 起動経路）に進む
5. When Reviewer Round 3 が `reject` を出力した, the Issue Watcher shall 無条件に `claude-failed` を付与し、Debugger の再々起動を行わない
6. If Debugger 自身が非 0 exit で異常終了した, the Issue Watcher shall `claude-failed` を付与し、Developer の再起動（Stage A''）も Reviewer Round 3 も実行しない

### Requirement 4: Developer 自己宣言 BLOCKED 経路の Debugger 起動

**Objective:** As a 開発者, I want Developer 自身が「単一 context では原因究明不可能」と判断した場合に Debugger に処理を委譲したい, so that 不毛な Stage A' 再試行を経由せず、根本原因分析に直行できる

#### Acceptance Criteria

1. While `DEBUGGER_ENABLED=true` である間, when Developer（Stage A）が `impl-notes.md` に `BLOCKED: <reason>` 行を明示宣言した状態で終了した, the Issue Watcher shall 現行の Stage A' 自動再実行を実行せず、代わりに Debugger を fresh な Claude CLI セッションで 1 回だけ起動する
2. The Issue Watcher shall `impl-notes.md` の `BLOCKED: <reason>` 行の検出を行頭の固定文字列マッチ（半角コロン + 半角スペース + 任意の reason 文字列）で行い、`reason` 部の自由文字列を改変せず Debugger 入力に渡す
3. When BLOCKED 経路で Debugger が Fix Plan を `debugger-notes.md` に出力して正常終了した, the Issue Watcher shall Developer を再起動（Stage A'）し、Debugger の Fix Plan を当該 Developer のプロンプトに inline で注入する
4. When BLOCKED 経路で Debugger 経由の Developer 再起動（Stage A'）が正常終了した, the Issue Watcher shall 通常の Reviewer Round 1 / Round 2 サイクルに進む
5. The Developer Agent shall `BLOCKED: <reason>` 宣言を「自身の context では原因究明不可能と判断した場合に限る最終手段」として扱い、通常の実装失敗や軽微なエラーでは宣言しない
6. The Developer Agent shall `BLOCKED: <reason>` 宣言時に reason 部へ「何を試したか」「何が分からなかったか」「Debugger が web search すべき疑問点」を平文で記載する

### Requirement 5: Debugger 起動回数上限と無限ループ防止

**Objective:** As a 既存 install 済みリポジトリの運用者, I want Debugger 起動回数に明確な上限を設けたい, so that 連続 reject や BLOCKED の繰り返しによるコスト暴走と無限ループを未然に防止する

#### Acceptance Criteria

1. The Issue Watcher shall 1 Issue（Phase 2 `PER_TASK_LOOP_ENABLED=true` 時は 1 task）あたり Debugger の起動回数を最大 1 回に制限する
2. While 同一 Issue（または同一 task）で過去に Debugger が 1 回起動済みである間, when 後続のサイクル（Reviewer reject や BLOCKED 宣言）が発生した, the Issue Watcher shall Debugger を再起動せず、`claude-failed` 付与に直行する
3. The Issue Watcher shall Reviewer 起動回数の上限を「Round 1 + Round 2 + Round 3（Debugger 経由）」の最大 3 回に固定する
4. The Issue Watcher shall Developer 起動回数の上限を「Stage A + Stage A'（または Stage A''）」の最大 3 回（初回 + Reviewer 差し戻し 1 回 + Debugger 経由 1 回）に固定する
5. The Issue Watcher shall Debugger 起動済み状態の判定を `debugger-notes.md` の存在または当該サイクル内のラベル / ログ記録など事後判別可能な手段で行い、再 pickup 時にも上限を遵守する

### Requirement 6: Phase 2 per-task loop との統合

**Objective:** As a 開発者, I want Phase 2（Issue #21）の per-task loop 有効時に Debugger も task 単位で起動すること, so that task 間で Debugger の context が混入せず、各 task の責務境界が保たれる

#### Acceptance Criteria

1. While `DEBUGGER_ENABLED=true` かつ `PER_TASK_LOOP_ENABLED=true` である間, when 1 件の task で Reviewer Round 2 reject が発生した, the Issue Watcher shall Debugger を当該 task 単位で 1 回起動し、他の task の context を Debugger に渡さない
2. While `DEBUGGER_ENABLED=true` かつ `PER_TASK_LOOP_ENABLED=true` である間, when 1 件の task で Developer が `BLOCKED: <reason>` を宣言した, the Issue Watcher shall Debugger を当該 task 単位で 1 回起動し、他の task の context を Debugger に渡さない
3. The Issue Watcher shall task 単位 Debugger の上限を 1 task あたり最大 1 回に固定し、複数 task で各 1 回ずつの起動を許容する
4. While `DEBUGGER_ENABLED=true` かつ `PER_TASK_LOOP_ENABLED=false`（既定）である間, the Issue Watcher shall Debugger を Issue 単位で 1 回のみ起動する（Phase 2 未有効環境での後方互換）
5. The Debugger Agent shall task 単位起動時に `tasks.md` の当該 task 行 / 当該 task の `_Requirements:_` で参照される AC のみを入力対象とし、他 task の context を参照しない

### Requirement 7: env vars と運用者向け制御

**Objective:** As a 既存 install 済みリポジトリの運用者, I want Debugger の有効化・モデル選択・実行予算を env var で制御したい, so that 運用環境ごとに opt-in 判断とコスト上限を独立に管理できる

#### Acceptance Criteria

1. The Issue Watcher shall `DEBUGGER_ENABLED` env を新設し、既定値を `false`（opt-in）とする
2. The Issue Watcher shall `DEBUGGER_MODEL` env を新設し、既定値を `claude-opus-4-7` とし、`REVIEWER_MODEL` と同様の override 方式で運用者が変更可能とする
3. The Issue Watcher shall `DEBUGGER_MAX_TURNS` env を新設し、既定値を `40` とし、運用者が変更可能とする
4. When Debugger を起動する, the Issue Watcher shall Debugger の Claude CLI セッションが web search 機能を行使可能な permission mode で起動されるように設定する
5. The Issue Watcher shall `DEBUGGER_ENABLED` / `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` のいずれを未指定にしても、既存環境変数の挙動契約（`DEV_MODEL` / `REVIEWER_MODEL` / `TRIAGE_MODEL` 等）に影響を与えない

### Requirement 8: ドキュメント整合と運用者向け説明

**Objective:** As a 既存 install 済みリポジトリの運用者, I want README およびエージェント定義から本機能の opt-in 手順・起動条件・上限を確認したい, so that 適用判断と移行手順を 1 次情報源から完結できる

#### Acceptance Criteria

1. The Documentation shall README に Debugger サブエージェント（opt-in）節を追加し、`DEBUGGER_ENABLED` / `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` の用途・既定値・有効化方法を運用者視点で記述する
2. The Documentation shall README に opt-in 時の Stage 遷移（Round 2 reject 経路 / BLOCKED 経路 / Round 3 reject → `claude-failed`）を運用者視点で記述する
3. The Documentation shall `repo-template/CLAUDE.md` のエージェント連携ルール節に Debugger の責務（コード書き換えなし / 判定なし / Fix Plan 出力のみ / 1 Issue or 1 task あたり最大 1 回）を追記する
4. The Documentation shall `repo-template/.claude/agents/developer.md` に `BLOCKED: <reason>` 宣言の規約（最終手段の位置付け / reason 部の記載指針）を追記する
5. The Documentation shall README に Migration Note として「既定では `DEBUGGER_ENABLED=false` で従来挙動が維持される」「opt-in 後も Round 2 reject / BLOCKED 宣言が発生しない Issue は挙動不変」「Debugger 1 回起動分の追加 Claude CLI コストが発生する」旨を明記する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall `DEBUGGER_ENABLED` 未設定 / `=false` 下で、本機能導入前にピックアップ済みの Issue・既存 PR・既存 cron 設定が中断・誤遷移・誤完了・誤 fail を起こさない状態を維持する
2. The Issue Watcher shall 既存 exit code の意味と既存ログ出力先（`LOG_DIR` 配下）のフォーマット契約を本機能で変更しない
3. The Issue Watcher shall Issue #20（Reviewer 差し戻しループ）および Issue #21（Phase 2 per-task loop）で確立された挙動契約を本機能で変更しない

### NFR 2: 観測可能性

1. The Issue Watcher shall `DEBUGGER_ENABLED=true` 下で Debugger を起動するたびに、「Debugger 起動」「Debugger 終了結果（正常 / 異常）」「Fix Plan 出力（`debugger-notes.md` の生成・追記）」「Round 3 結果（approve / reject / 異常）」を `LOG_DIR` 配下のログに事後判別可能な粒度で記録する
2. The Issue Watcher shall Debugger 関連ログエントリに、時刻 prefix と processor prefix の間に Issue #119 規約で確立された `[$REPO]` 識別子を 1 つだけ挿入する
3. The Issue Watcher shall ログエントリに対象 Issue 番号（および Phase 2 有効時は task numeric ID）を含めて記録する

### NFR 3: コスト上限と運用者可視性

1. The Documentation shall README に「Debugger 起動 1 回あたり web search を含む最大 `DEBUGGER_MAX_TURNS`（既定 40）ターンの Claude CLI 実行コストが追加される」旨を運用者が事前判断可能な形で記載する
2. The Issue Watcher shall Debugger 1 回 + Stage A''（Debugger 経由 Developer 再起動）1 回 + Reviewer Round 3 1 回が本機能で追加される最大コストであることを README で明示する

### NFR 4: 静的解析クリーン

1. The Issue Watcher script shall `shellcheck local-watcher/bin/issue-watcher.sh` 実行において新規警告を 0 件に保つ
2. The Workflow YAML（変更が及ぶ場合）shall `actionlint` 実行において新規警告を 0 件に保つ

### NFR 5: 独立性とコンテキスト隔離

1. While Debugger を起動している間, the Issue Watcher shall Debugger の Claude CLI セッションを Developer / Reviewer の過去セッションと共有しない独立 context で起動する
2. The Debugger Agent shall 起動時に他のエージェント（PM / Architect / Developer / Reviewer / PjM）の役割を兼任せず、Fix Plan 出力のみを責務とする

## Out of Scope

- **Reviewer Round 1 reject 直前での Debugger 介入**: Round 1 は Developer self-fix で十分なケースが多いという経験則に基づき、本 Issue では Round 2 直前まで遅延させる（コスト効率の観点。将来検討課題）
- **Debugger の複数回起動**: 1 Issue（または 1 task）あたり最大 1 回に固定。複数回起動して試行錯誤させる仕組みは将来課題
- **Debugger 専用のテスト実行**: Debugger は判定 + Fix Plan 出力のみ。テストは Debugger 経由で再起動された Developer が実行する
- **web search 結果のキャッシュ機構**: 同じ原因を複数 Issue で踏んだ場合の知見共有は別 Issue
- **web search のドメイン allowlist / 追加 permission 制約**: 本 Issue では Claude CLI default の permission mode を採用し、追加制約は加えない（Open Question 3 推奨案を採用）
- **Debugger context の Reviewer / Developer 兼任**: 本 Issue では完全 fresh（独立性確保）の方針を採用する（Open Question 4 推奨案を採用）
- **Phase 2 (Issue #21) 完了前の per-task BLOCKED トリガー**: Phase 2 closed までは Round 2 reject 経路（Issue 単位）のみで導入する。本 Issue の per-task 統合要件（Requirement 6）は Phase 2 完了を前提とする（Open Question 5 推奨案を採用）
- **Debugger Fix Plan のフォーマットを YAML / JSON 等の構造化データに切り替える検討**: 本 Issue では構造化 markdown 形式を採用する（Open Question 2 推奨案を採用）
- **GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への Debugger 経路移植**
- **Debugger 起動条件を「BLOCKED 宣言のみ」「Round 1 / 2 / BLOCKED 全部」のいずれかに変更する検討**: 本 Issue では「Round 2 reject + BLOCKED 宣言の 2 トリガー」を採用する（Open Question 1 推奨案を採用）

## Open Questions

- なし（Issue 本文 Open Questions 1〜5 はすべて推奨案で確定済み。本 requirements の Out of Scope に該当する将来検討課題として記録）
