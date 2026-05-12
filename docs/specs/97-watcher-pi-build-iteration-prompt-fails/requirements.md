# 要件定義: PR Iteration prompt の E2BIG 修正（大きな PR diff 対応）

- Issue: [#97](https://github.com/hitoshiichikawa/idd-claude/issues/97) "watcher: pi_build_iteration_prompt fails with E2BIG when PR diff exceeds 128KB (single env var limit)"
- 関連 Issue: [#92](https://github.com/hitoshiichikawa/idd-claude/issues/92)（Reviewer prompt 側の同種 E2BIG 修正、コミット `6e73820` で着地済み）、[#96](https://github.com/hitoshiichikawa/idd-claude/issues/96)（同 PR で観測された別件 / 本要件のスコープ外）
- 対象ファイル想定: `local-watcher/bin/issue-watcher.sh`（`pi_build_iteration_prompt` 周辺）、`local-watcher/bin/iteration-prompt.tmpl`、`local-watcher/bin/iteration-prompt-design.tmpl`

## Introduction

`local-watcher/bin/issue-watcher.sh` の `pi_build_iteration_prompt` 関数は、PR Iteration 用プロンプト（impl 用 `iteration-prompt.tmpl` / design 用 `iteration-prompt-design.tmpl`）に `gh pr diff` の全文を `PI_PR_DIFF` という単一の環境変数経由で `awk` の `ENVIRON[]` から注入している。差分が 128 KB（Linux `MAX_ARG_STRLEN` = 131,072 B、`exec(2)` が単一 env var 値に課す上限）を超えると、`awk` 子プロセスの起動が `E2BIG` で失敗し、Iteration ステージが終了コード 126 で落ちる（2026-05-11 KeyNest repo PR #7 / 約 715 KB の diff で実発生）。

本機能では、PR Iteration プロンプトから inline diff を撤廃し、Iteration サブエージェント自身が `Bash` ツールで差分を取得する手順をプロンプトに明示することで、差分サイズに依存せず Iteration ステージが起動できるようにする。Reviewer prompt 側で先行採用された方針（Issue #92 / コミット `6e73820`）と一貫させ、idd-claude 自身も self-hosting で同じ修正の恩恵を受けられるようにする。プロンプトの出力契約（commit + push / 返信動作）、round 制御、kind 判定（impl / design）、後方互換性（env var 名・ラベル名・cron 文字列・exit code）は維持する。

## Requirements

### Requirement 1: PR Iteration プロンプトの inline diff 撤廃

**Objective:** As a watcher 運用者, I want PR Iteration プロンプトに `gh pr diff` 全文を埋め込まない方式に切り替えたい, so that 大きな差分の PR でも Iteration ステージが `Argument list too long` で失敗せずに起動できる

#### Acceptance Criteria

1. When `pi_build_iteration_prompt` がプロンプトを生成するとき, the PR Iteration Prompt Builder shall PR diff の全文を生成プロンプトの本文に含めない
2. When `pi_build_iteration_prompt` がプロンプトを生成するとき, the PR Iteration Prompt Builder shall `awk` 子プロセスに対して PR diff 全文を保持する単一の環境変数（現行 `PI_PR_DIFF` に相当する値）を export しない
3. When PR diff が 128 KB を超える PR に対して PR Iteration ステージを起動したとき, the watcher shall `pi_build_iteration_prompt` の終了コードを 0 で返し、後続の `claude --print` 起動まで到達する
4. When PR diff の取得が失敗または空であっても, the PR Iteration Prompt Builder shall プロンプト生成自体を成功させる（プロンプト本文に `(diff の取得に失敗)` のような fallback 文字列を残さない）
5. The PR Iteration Prompt Builder shall impl 用 template（`iteration-prompt.tmpl`）と design 用 template（`iteration-prompt-design.tmpl`）の両方に対して同じ撤廃方針を適用する

### Requirement 2: Iteration サブエージェントによる差分自己取得手順の提示

**Objective:** As a PR Iteration サブエージェント, I want プロンプトから差分取得手順を明示的に受け取りたい, so that Bash ツールで自力で差分を取得して修正判断ができる

#### Acceptance Criteria

1. The PR Iteration Prompt Builder shall プロンプト本文に差分概要を `git diff --stat <base>..<head>` または `gh pr diff <PR 番号> --repo <REPO>` で取得する旨を明示する
2. The PR Iteration Prompt Builder shall プロンプト本文にファイル単位の詳細差分が必要な場合は `git diff <base>..<head> -- <path>` 等で取得する旨を明示する
3. The PR Iteration Prompt Builder shall 差分取得手順の説明に `BASE_REF`（PR の base branch 名）・`HEAD_REF`（PR の head branch 名）・`PR_NUMBER`・`REPO` の実値を埋め込んだ形で記載する（Iteration サブエージェントがそのままコピペで実行できる粒度）
4. The PR Iteration Prompt Builder shall impl 用 / design 用いずれのプロンプトでも、差分取得手順の説明箇所を 1 箇所以上含める

### Requirement 3: 既存の Iteration 契約・round 制御の維持

**Objective:** As a watcher 運用者, I want PR Iteration ステージの動作契約と round 制御を変えずに保ちたい, so that 既稼働のパイプライン（kind 判定・着手 marker・round 上限・PjM 起動条件）に影響を与えない

#### Acceptance Criteria

1. The PR Iteration Prompt Builder shall プロンプト本文に PR 番号・PR タイトル・PR URL・base branch 名・head branch 名・round 番号・最大 round 数・関連 Issue 番号・`SPEC_DIR` の各 identifier を引き続き含める
2. The PR Iteration Prompt Builder shall プロンプト本文に line コメント JSON / 一般コメント JSON / `requirements.md` 本文の各セクションを引き続き含める（これらは PR diff とは独立した文脈であり撤廃対象ではない）
3. The watcher shall PR Iteration ステージの kind 判定（impl / design / none / ambiguous）と分岐ロジックを変更しない
4. The watcher shall PR Iteration の round 上限（`PR_ITERATION_MAX_ROUNDS`）と escalate 動作（`claude-failed` 昇格）を変更しない
5. The watcher shall PR Iteration の着手 marker・着手コメント・fresh context Claude 起動・base branch 復帰の各動作を変更しない

### Requirement 4: 後方互換性の維持

**Objective:** As a 既稼働 watcher のユーザー, I want 既存環境がそのまま動き続けてほしい, so that 本変更の取り込みで手元の cron / launchd / consumer repo 設定を直さなくて済む

#### Acceptance Criteria

1. The watcher shall `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `PR_ITERATION_DEV_MODEL` / `PR_ITERATION_MAX_ROUNDS` / `PR_ITERATION_MAX_TURNS` / `PR_ITERATION_GIT_TIMEOUT` を含む既存の環境変数名・既定値・参照方法を変更しない
2. The watcher shall PR Iteration ステージで使用するラベル（`needs-iteration` / `claude-failed` 等）の名前・付与/剥がしのタイミングを変更しない
3. The watcher shall exit code の意味（正常 / 処理対象なし / エラー / escalate / skip）を変更しない
4. The watcher shall `~/bin/issue-watcher.sh` を起動する cron 登録文字列を変更しない（インストール側の文言を変えない）
5. Where `PI_PR_DIFF` 環境変数を内部実装として参照していた箇所のみが存在する場合, the watcher shall 外部公開 API としては当該変数を提供していないため削除して良い（外部から `PI_PR_DIFF` を設定しても挙動が変わらないことが期待値）

### Requirement 5: テンプレート整合性

**Objective:** As a watcher 保守者, I want テンプレートと prompt builder の間でプレースホルダ仕様が一致してほしい, so that 将来テンプレートを編集した際にプレースホルダの取りこぼし / 未展開が混入しないことを担保できる

#### Acceptance Criteria

1. When `pi_build_iteration_prompt` がテンプレートをレンダリングしたとき, the PR Iteration Prompt Builder shall 出力中に `{{PR_DIFF}}` の文字列を残さない
2. The PR Iteration Prompt Builder shall 撤廃対象でないプレースホルダ（`{{REPO}}` / `{{PR_NUMBER}}` / `{{PR_TITLE}}` / `{{PR_URL}}` / `{{HEAD_REF}}` / `{{BASE_REF}}` / `{{ROUND}}` / `{{MAX_ROUNDS}}` / `{{ISSUE_NUMBER}}` / `{{SPEC_DIR}}` / `{{LINE_COMMENTS_JSON}}` / `{{GENERAL_COMMENTS_JSON}}` / `{{REQUIREMENTS_MD}}`）については引き続きすべて展開する
3. If テンプレート中に `{{PR_DIFF}}` が残置されていた場合, the PR Iteration Prompt Builder shall 当該テンプレートを修正対象として扱う（impl / design 両系の `iteration-prompt*.tmpl` を一括で対応する）

## Non-Functional Requirements

### NFR 1: プロンプトサイズ上限

1. The PR Iteration Prompt Builder shall 1 回のプロンプト生成で `claude --print` に渡される引数バイト数を 131,072 B（Linux `MAX_ARG_STRLEN`）未満に抑える
2. The PR Iteration Prompt Builder shall `awk` に export する各環境変数の値長を 131,072 B 未満に抑える（diff 全文を保持する単一変数を持たない）
3. The PR Iteration Prompt Builder shall プロンプト出力バイト数が PR diff 規模に依存せず、概ね一定（diff 内容を含まないため数 KB〜数十 KB 程度）に収まる

### NFR 2: 静的解析

1. When `shellcheck local-watcher/bin/issue-watcher.sh` を実行したとき, the build pipeline shall 本変更によって新規に発生する警告を 0 件にする

### NFR 3: 観測性・互換性確認

1. When `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で実行したとき, the watcher shall 「処理対象の Issue なし」で正常終了する（既存スモークテスト結果を変えない）
2. When diff が 128 KB を超える PR に対して PR Iteration ステージを起動したとき, the watcher shall ログに E2BIG / `Argument list too long` 由来のエラーを記録せず、Claude 起動ログまで到達する

### NFR 4: self-hosting 安全性

1. When 本変更後の `local-watcher/bin/issue-watcher.sh` を idd-claude 自身に対して稼働させたとき, the watcher shall 自身の repo の大規模 diff を含む PR に対しても PR Iteration ステージを起動できる（dogfooding 適合）

## Out of Scope

- Reviewer prompt（Issue #92 / コミット `6e73820` で対応済み）の再修正
- Stage C PjM プロンプト（Issue #96 で対応済み）の修正
- Triage / Developer 初回起動 / 設計 PR Stage A など、PR Iteration 以外のステージのプロンプト構造変更
- `claude --print` を stdin で渡す方式（例: `claude --print < tmpfile`）への移行
- PR diff の要約・トリミング・分割送信などの代替アルゴリズム導入
- LaunchDarkly / Unleash 等の外部 Feature Flag 連携や、差分サイズに応じたモデル切替などの新規機能
- `claude` CLI 側の制限緩和や upstream 修正
- PR Iteration の出力契約（commit + push / 返信動作 / `RESULT:` 行など）変更

## Open Questions

- なし（Issue #97 本文・Reviewer 修正の先例（#92）・現行コード（`local-watcher/bin/issue-watcher.sh` の `pi_build_iteration_prompt`）で本要件を確定できる。Issue 投稿者は案 4「Claude に `gh pr diff` を実行させる」が Reviewer 修正と一貫すると述べており、Issue にコメントは付いていないが本要件は当該方針と等価な「inline diff の撤廃」を Acceptance Criteria の中核に据える。具体的にどの bash 実装パターン（tempfile + getline、`gh pr diff` 指示の inline 化、それらの併用）で AC 1.x / 2.x を満たすかは design.md の領分とする）
