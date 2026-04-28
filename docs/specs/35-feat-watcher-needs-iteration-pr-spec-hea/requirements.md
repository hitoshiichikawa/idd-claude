# Requirements: feat(watcher): needs-iteration を設計 PR にも対応

## Overview / Stakeholder Context

idd-claude の PR Iteration Processor（`#26` で導入）は現状 **実装 PR（`claude/issue-<N>-impl-...`）専用**で、
設計 PR（`claude/issue-<N>-design-...`）には反応しない。設計レビュー指摘の反映は人間が
ローカルで Claude Code を立ち上げ直すか、PR を close → 再 Triage する必要があり、
反復ループが片肺になっている。

加えて、現行の head branch pattern 既定値 `^claude/` は idd-claude 規約外の `claude/foo` ブランチも
拾ってしまう恐れがあり、誤検知の余地を残している。

**ステークホルダ**:

- **watcher 運用者**: 既存 cron / launchd 設定を一切変えずに、設計 PR の自動反復を opt-in で取り込みたい
- **設計 PR レビュワー**: `needs-iteration` ラベルを 1 つ付けるだけで、Architect 文脈を保った修正サイクルを回したい
- **既存ユーザー（実装 PR のみ運用中）**: 何もしなければ挙動が変わらないことを保証されたい

**成功イメージ**:

- 設計 PR でも実装 PR と同じ「ラベル 1 つ」運用で反復できる
- 設計 PR の iteration では `requirements.md` / `design.md` / `tasks.md` を **Architect として書き換える** ことが許容される（実装 PR ではこれは禁止のまま）
- head branch pattern が idd-claude 由来 PR に厳格化され、誤検知が排除される
- `PR_ITERATION_DESIGN_ENABLED=false`（既定）のままなら、本機能導入前と挙動が完全に一致する

---

## Scope

### In Scope

- 反復対象 PR の **branch 名による種別判定**（design / impl / 対象外）
- 設計 PR 用 iteration テンプレート `iteration-prompt-design.tmpl` の新設と install.sh / setup.sh 経由の配置
- 設計 PR 用ラベル遷移（成功時 `needs-iteration` → `awaiting-design-review`、失敗時は `claude-failed` 昇格）
- 環境変数の追加（`PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_DESIGN_HEAD_PATTERN`）と既定値の厳格化（`PR_ITERATION_HEAD_PATTERN` を `^claude/issue-[0-9]+-impl-` に絞る）
- 既存 impl iteration の挙動・契約・既定値（既存 env / ラベル / lock / exit code）の温存
- 「1 PR = design or impl のどちらか（混在禁止）」の運用ルール明文化
- 設計 PR の編集許容スコープ（`docs/specs/<N>-<slug>/` 配下のみ）の明文化
- 設計 PR iteration 時の自己レビュー（`.claude/rules/design-review-gate.md` 準拠）実施の明文化
- DoD のスモークテスト 4 件のシナリオ独立化

### Out of Scope

- **同一 PR への design + impl 混在運用**（spec 編集と実装変更を 1 PR に同居させる運用）
- `requirements.md` 自体への遡及的大規模修正（設計 PR iteration では `requirements.md` の小幅整合修正は許容するが、要件を作り直す運用は本 Issue の範囲外）
- design PR の複数ラウンドを 1 commit に **squash** する自動化
- iteration round counter を design / impl で **別離** する仕組み（現行 PR body marker を共用する）
- review-notes.md（`#20` Phase 1 Reviewer）連携での自動判定
- commit メッセージ規約のテンプレート強制
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への組み込み
- `^claude/issue-[0-9]+-(design|impl)-` 以外の旧来形式（例: `claude/foo`、`claude/issue-23-...` で `-design-` / `-impl-` が無いもの）の救済

---

## Requirements

### Requirement 1: PR 種別判定（branch 名ベース）

**ユーザーストーリー / 動機**: As a watcher operator, I want PR iteration の対象判定を head branch 名で
design / impl / 対象外に分岐したい, so that 設計 PR と実装 PR で異なる template とラベル遷移を適用できる。

#### Acceptance Criteria

1.1 When PR Iteration Processor が `needs-iteration` ラベル付き open PR を評価する, the PR Iteration Processor shall その PR の head branch 名が **design head pattern**（既定 `^claude/issue-[0-9]+-design-`）にマッチする場合は **design 種別** として扱う

1.2 When PR Iteration Processor が `needs-iteration` ラベル付き open PR を評価する, the PR Iteration Processor shall その PR の head branch 名が **impl head pattern**（既定 `^claude/issue-[0-9]+-impl-`）にマッチする場合は **impl 種別** として扱う

1.3 If 対象 PR の head branch 名が design head pattern と impl head pattern のいずれにも合致しない, the PR Iteration Processor shall その PR を反復対象から除外しログに skip 理由を記録する

1.4 If 対象 PR の head branch 名が design head pattern と impl head pattern の **両方** に合致する（運用上は発生しない想定の保険）, the PR Iteration Processor shall 当該 PR を反復対象から除外し WARN 相当のログに「ambiguous branch」を記録する

1.5 The PR Iteration Processor shall 既存の fork 除外 / draft 除外 / `claude-failed` 除外 / `needs-rebase` 除外（既存 AC 1.3〜1.5 / 8.4 相当）の判定を design / impl いずれの種別にも同一基準で適用する

---

### Requirement 2: 設計 PR 専用テンプレートの新設と配置

**ユーザーストーリー / 動機**: As a design PR reviewer, I want 設計 PR の iteration が Architect 役割で
動作し、`docs/specs/<N>-<slug>/` 配下の spec 群を書き換えられる template が watcher にバンドルされてほしい,
so that 設計指摘の反映で commit が積まれた瞬間に design.md / tasks.md が更新される。

#### Acceptance Criteria

2.1 The idd-claude template set shall 設計 PR 専用の iteration prompt テンプレート（`iteration-prompt-design.tmpl` 相当の名称）を `local-watcher/bin/` 配下にソースとして含む

2.2 When `install.sh` または `setup.sh` がローカル watcher をインストールまたは更新する, the installer shall 新テンプレートを既存テンプレート（`iteration-prompt.tmpl` / `triage-prompt.tmpl`）と同じ配置先（`$HOME/bin/`）に冪等に配置する

2.3 The 設計 PR 用 iteration template shall **Architect 役割で起動された旨**と **`docs/specs/<N>-<slug>/` 配下のみ編集可** であることをエージェント向け指示として明記する

2.4 The 設計 PR 用 iteration template shall 修正確定前に `.claude/rules/design-review-gate.md` の自己レビューゲートを実行する旨をエージェント向け指示として明記する

2.5 The 設計 PR 用 iteration template shall 実装 PR 用 template に存在する「`requirements.md` / `design.md` / `tasks.md` の書き換え禁止」条項を **設計 PR では適用しない**（spec 書き換えを許容する）

2.6 If 設計 PR の iteration 中に `docs/specs/<N>-<slug>/` の **外側** へのファイル変更が発生した, the PR Iteration Processor shall 当該 iteration を失敗として扱い `needs-iteration` ラベルを残置する（許容スコープ違反は失敗扱い）

2.7 The 設計 PR 用 iteration template shall force push 全般（`--force` / `--force-with-lease`）の禁止、`main` への直接 push の禁止、レビュースレッドの resolve / unresolve 禁止、`--resume` / `--continue` / `--session-id` の禁止を、実装 PR 用 template と同一基準で明記する

---

### Requirement 3: ラベル遷移の分岐

**ユーザーストーリー / 動機**: As a reviewer, I want 設計 PR と実装 PR で iteration 完了時のラベル遷移先が
それぞれの次フェーズ（設計レビュー or 実装レビュー）と整合してほしい, so that ラベル一覧から「次に自分が何をすべきか」を一覧で判断できる。

#### Acceptance Criteria

3.1 When 設計 PR の iteration が成功した（commit push もしくは返信のみで正常完了した）, the PR Iteration Processor shall 対象 PR から `needs-iteration` ラベルを除去し `awaiting-design-review` ラベルを付与する

3.2 When 実装 PR の iteration が成功した（commit push もしくは返信のみで正常完了した）, the PR Iteration Processor shall 対象 PR から `needs-iteration` ラベルを除去し `ready-for-review` ラベルを付与する（既存 `#26` AC 6.2 の挙動を維持）

3.3 If 設計 PR の iteration が失敗した（Claude 実行失敗 / push 失敗 / 編集スコープ違反等）, the PR Iteration Processor shall 既存と同様に `needs-iteration` ラベルを残置し watcher ログに WARN 相当で原因を記録する

3.4 When 設計 PR の累計 iteration 回数が上限値（`PR_ITERATION_MAX_ROUNDS`）に到達した, the PR Iteration Processor shall 対象 PR から `needs-iteration` ラベルを除去し `claude-failed` ラベルに昇格させる（実装 PR と同一基準）

3.5 The idd-claude ラベル一覧管理スクリプト（`.github/scripts/idd-claude-labels.sh` 相当）shall 本機能で必要となるラベル群（`needs-iteration` / `awaiting-design-review` / `ready-for-review` / `claude-failed`）が冪等に作成・維持できる状態を保つ

---

### Requirement 4: 環境変数の追加と既存変数の厳格化

**ユーザーストーリー / 動機**: As an existing watcher user, I want 設計 PR 対応の有効化を独立フラグで
opt-in できるようにし、かつ head branch pattern の既定値が idd-claude 由来 PR のみを拾うように
厳格化されてほしい, so that 既存運用に影響を与えず段階的に新機能を採用できる。

#### Acceptance Criteria

4.1 The Issue Watcher shall 設計 PR 対応の有効化フラグ（環境変数 `PR_ITERATION_DESIGN_ENABLED`）を読み取り、未設定時は既定値 `false`（無効）を用いる

4.2 The Issue Watcher shall 設計 PR の head branch pattern を制御する環境変数（`PR_ITERATION_DESIGN_HEAD_PATTERN`）を読み取り、未設定時は既定値 `^claude/issue-[0-9]+-design-` を用いる

4.3 The Issue Watcher shall 実装 PR の head branch pattern 既定値（環境変数 `PR_ITERATION_HEAD_PATTERN`）を **`^claude/issue-[0-9]+-impl-`** とする（旧既定値 `^claude/` から厳格化する）

4.4 Where `PR_ITERATION_DESIGN_ENABLED` が `true` ではない（未設定 / `false` / 不正値）, the PR Iteration Processor shall 設計 PR を反復対象から除外する（branch が design pattern にマッチしても起動しない）

4.5 Where `PR_ITERATION_ENABLED` が `true` ではない, the PR Iteration Processor shall 設計 / 実装いずれの PR に対しても起動せず、`PR_ITERATION_DESIGN_ENABLED` の値に関わらず本機能全体が無効化される

4.6 The Issue Watcher shall 既存の env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_ENABLED`, `PR_ITERATION_ENABLED`, `PR_ITERATION_DEV_MODEL`, `PR_ITERATION_MAX_TURNS`, `PR_ITERATION_MAX_PRS`, `PR_ITERATION_MAX_ROUNDS`, `PR_ITERATION_GIT_TIMEOUT`）の意味と既定値を変更しない

---

### Requirement 5: 後方互換性と「1 PR = design or impl」の混在禁止

**ユーザーストーリー / 動機**: As an existing watcher user with running cron jobs, I want 本変更の取り込みで
既存 impl PR の運用が壊れないこと、および「設計と実装が 1 PR に混在しない」運用ルールが明文化されることを
求める, so that 既存の cron / launchd を変更せずに本変更を取り込め、かつ設計 PR と実装 PR が混ざることによる
ラベル遷移の曖昧性を避けられる。

#### Acceptance Criteria

5.1 Where `PR_ITERATION_DESIGN_ENABLED=false`（既定）, the PR Iteration Processor shall 本機能導入前（`#26`）と完全に同一の挙動で動作する（impl PR の検知範囲・ラベル遷移・ログ書式・round counter の挙動が不変）

5.2 The Issue Watcher shall 既存 impl PR が `PR_ITERATION_HEAD_PATTERN` の既定値変更（`^claude/` → `^claude/issue-[0-9]+-impl-`）後も既存 branch 命名規約（`claude/issue-<N>-impl-<slug>`）に合致する限り従来通り反復対象になることを保証する

5.3 If 旧来の branch 命名（`claude/<slug>` のような `issue-<N>-(design|impl)-` 形式に従わない）の PR に `needs-iteration` が付いている, the PR Iteration Processor shall 既定 pattern では当該 PR を対象から除外し、運用者が必要なら `PR_ITERATION_HEAD_PATTERN` を override して救済できる旨を README に明記する

5.4 The README.md shall 「1 PR = design or impl のどちらか（混在禁止）」の運用ルールを記述する

5.5 The README.md shall 既定値変更（`PR_ITERATION_HEAD_PATTERN` の旧 `^claude/` → 新 `^claude/issue-[0-9]+-impl-`）を migration note として記述し、override 方法を併記する

5.6 The README.md shall `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_DESIGN_HEAD_PATTERN` の名称・既定値・有効化方法・対象 branch pattern を記述する

5.7 The CLAUDE.md shall 設計 PR iteration の挙動と、Architect / Developer エージェントの責務境界（実装 PR では spec 書き換え禁止 / 設計 PR では `docs/specs/` 配下の書き換え許容）を記述する

---

### Requirement 6: 着手表明・ロギング・round counter の共有

**ユーザーストーリー / 動機**: As a watcher operator, I want 設計 PR の iteration も既存実装 PR の iteration と
同じログ書式・着手表明・round counter で観測できることを求める, so that grep / 集計の運用が
種別を問わず一貫して機能する。

#### Acceptance Criteria

6.1 When PR Iteration Processor が design / impl いずれの PR の iteration を開始した, the PR Iteration Processor shall 既存と同じ着手表明（PR body の hidden marker 更新 + 着手コメント投稿）を実施する

6.2 The PR Iteration Processor shall design / impl 両種別の iteration ログを既存と同一の prefix（`pr-iteration:`）と timestamp 書式（`[YYYY-MM-DD HH:MM:SS]`）で出力する

6.3 The PR Iteration Processor shall 各 PR の iteration ログに「PR 番号」「種別（design / impl）」「round 数」「実施したアクション（commit+push / 返信のみ / 失敗 / 上限超過）」を 1 行以上で識別可能な形式で出力する

6.4 The PR Iteration Processor shall design / impl いずれの種別についても、上限超過時のエスカレーションコメント（`PR_ITERATION_MAX_ROUNDS` 到達時の人間向けアナウンス）を投稿する

6.5 The PR Iteration Processor shall round counter（PR body hidden marker）を design / impl 種別で共有し、別離しない（種別が混在する PR は Requirement 1.4 で対象外として扱われるため、共有で破綻しない）

---

### Requirement 7: スモークテスト（DoD 検証シナリオ）

**ユーザーストーリー / 動機**: As a release reviewer, I want 本変更が「設計 PR が回る」「失敗 PR が落ちる」
「既存 impl PR が壊れない」「opt-out で完全無影響」の 4 シナリオで検証されることを求める, so that マージ前に
リスクを最小化できる。

#### Acceptance Criteria

7.1 The release verification process shall **設計 PR 成功シナリオ** を実施する: `PR_ITERATION_ENABLED=true` かつ `PR_ITERATION_DESIGN_ENABLED=true` で、`claude/issue-<N>-design-<slug>` ブランチの設計 PR に `needs-iteration` を付与した結果、commit push もしくは返信のみで正常完了し、最終ラベルが `awaiting-design-review` に遷移することを確認する

7.2 The release verification process shall **設計 PR 失敗シナリオ** を実施する: 設計 PR の iteration が `PR_ITERATION_MAX_ROUNDS` に到達した結果、`needs-iteration` が外れて `claude-failed` に昇格し、エスカレーションコメントが投稿されることを確認する

7.3 The release verification process shall **実装 PR リグレッションシナリオ** を実施する: 既存の `claude/issue-<N>-impl-<slug>` ブランチの実装 PR に `needs-iteration` を付与した結果、本変更導入前と同一の挙動（成功時に `ready-for-review` へ遷移、上限到達時に `claude-failed` へ昇格）が再現されることを確認する

7.4 The release verification process shall **完全 opt-out シナリオ** を実施する: `PR_ITERATION_DESIGN_ENABLED=false`（既定）かつ既存設定で watcher を 1 サイクル流した結果、設計 PR の `needs-iteration` ラベルに対して PR Iteration Processor が起動せず、impl PR の挙動と既存ログ書式が `#26` 導入時と一致することを確認する

7.5 The release verification process shall 上記 4 シナリオの結果を PR 本文の「Test plan」セクションに記録する

---

## Non-Functional Requirements

### NFR 1: 後方互換性

1.1 The Issue Watcher shall 既存ラベル名（`needs-iteration`, `awaiting-design-review`, `ready-for-review`, `claude-failed`, `auto-dev`, `claude-picked-up`, `needs-decisions`, `skip-triage`, `needs-rebase`）の名前・意味・付与契約を変更しない

1.2 The Issue Watcher shall 既存の lock ファイルパス・ログ出力先・exit code の意味を変更しない

1.3 The Issue Watcher shall 既存の cron / launchd 登録文字列（実行コマンド・引数）が本変更の取り込み後も再起動なしに動作することを保証する

### NFR 2: 冪等性と再現性

2.1 The installer shall `install.sh` / `setup.sh` を再実行しても新テンプレート（`iteration-prompt-design.tmpl`）の配置結果が変わらない（同一内容なら SKIP、差分時のみ OVERWRITE）

2.2 The PR Iteration Processor shall 同一 PR への複数サイクル評価でラベル遷移と round counter の更新結果が決定的（観測可能な状態が同一入力に対して同一）であることを保証する

### NFR 3: 観測可能性

3.1 The PR Iteration Processor shall 設計 PR / 実装 PR それぞれの起動・成功・失敗・上限超過の件数が、既存 watcher ログを grep するだけで集計可能な識別語でマークされることを保証する

3.2 The PR Iteration Processor shall サイクル開始時のログに「対象候補 PR 件数」を design / impl 種別ごとに区別可能な形式で記録する

### NFR 4: env var override 性

4.1 The Issue Watcher shall すべての新規環境変数（`PR_ITERATION_DESIGN_ENABLED`, `PR_ITERATION_DESIGN_HEAD_PATTERN`）について、cron / launchd / shell から設定した値が既定値を override することを保証する

4.2 The Issue Watcher shall `PR_ITERATION_HEAD_PATTERN` の既定値変更（厳格化）後も、運用者が同変数を override することで旧来 pattern（`^claude/`）相当の挙動に戻せることを保証する

---

## 確認事項（人間レビュー必要 / 設計フェーズで決定）

以下は Issue 本文「未解決の設計論点」セクションに対応する。PM では決め打ちせず、Architect / 人間に判断を委ねる:

- **Architect 役割の prompt 内表現方法**: 設計 PR template 内で Architect 役割を inline 展開するか、`Read` ツールで `.claude/agents/architect.md` を参照させるか。template の自己完結性と保守性のトレードオフを Architect が判断する
- **`review-notes.md`（`#20` Phase 1 Reviewer）との関係**: 設計 PR でも Reviewer エージェントが起動する設計になるか、design PR は Reviewer 対象外（impl のみ）に据え置くかは、`#20` の現状仕様に照らして Architect が判断する
- **commit メッセージ規約のテンプレート化**: 設計 PR iteration 時の commit メッセージに `docs(specs):` scope を強制するか、Conventional Commits 一般遵守に留めるかを Architect が判断する
- **`PR_ITERATION_HEAD_PATTERN` 既定値変更の影響範囲評価**: 旧既定値 `^claude/` で運用していた既存 watcher 利用者がいるか、いる場合の migration アナウンス手段（README note のみで足りるか、deprecation 期間を設けるか）は人間（メンテナ）が判断する
- **`docs/specs/<N>-<slug>/` 外編集の検出粒度**（AC 2.6）: `git diff --name-only` で発見次第 fail させるのか、Claude 側の指示遵守のみに任せるのかは Architect が判断する
- **設計 PR で `requirements.md` 整合修正をどこまで許容するか**: 設計指摘で要件が間違っていたと判明した場合、設計 PR 内で `requirements.md` を直すのか、要件は別 PR / Issue で扱うのか。Out of Scope では「遡及的大規模修正」を除外しているが、軽微な整合修正の境界線は Architect / 人間が判断する
