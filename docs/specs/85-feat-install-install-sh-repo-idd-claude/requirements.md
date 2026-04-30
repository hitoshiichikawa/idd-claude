# Requirements Document

## Introduction

`install.sh --repo <path>` でテンプレートを配置した直後の対象リポジトリには、idd-claude が
状態遷移に使う必須ラベル（`auto-dev` / `claude-claimed` / `ready-for-review` 等）がまだ
存在しない。そのため初回 cron で watcher が claim ラベルの付与に失敗し
（"claude-claimed ラベル付与に失敗、slot-1 を解放して次 Issue へ" 等）、ユーザーは別途
`bash .github/scripts/idd-claude-labels.sh` を手動実行する手間を要する。本機能では
`install.sh --repo` の延長線でラベルセットアップを自動化し、認証不足や API 失敗時にも
install 全体を止めない fail-soft な挙動と、再実行時の冪等性、`--no-labels` による opt-out を
提供する。既存の `idd-claude-labels.sh` の interface・既存 `install.sh` オプションの
後方互換性は破壊しない。

## Requirements

### Requirement 1: ラベル自動セットアップの実行範囲

**Objective:** As a 対象リポジトリにテンプレートを配置するユーザー, I want install 直後に必須ラベルが対象 repo に揃う, so that 初回 cron で watcher がラベル付与に失敗せず Issue を処理できる

#### Acceptance Criteria

1. When `install.sh --repo <path>` がテンプレート配置に成功した直後, the Install Helper shall 対象リポジトリ向けにラベルセットアップ処理を起動する
2. When `install.sh --all` で対象リポジトリパスが指定されている, the Install Helper shall 対象リポジトリ向けにラベルセットアップ処理を起動する
3. When `install.sh --local` のみが指定されている, the Install Helper shall ラベルセットアップ処理を起動しない
4. When `install.sh` を引数なしの対話モードで起動し対話で対象リポジトリ配置を選択した, the Install Helper shall その選択された対象リポジトリ向けにラベルセットアップ処理を起動する
5. The Install Helper shall ラベルセットアップ処理の対象を対象リポジトリ 1 件に限定する（ローカル watcher の `$HOME` 配下にはラベル概念が存在しないため）

### Requirement 2: 冪等性と既存ラベルの保護

**Objective:** As a 既に idd-claude を導入済みのリポジトリ運用者, I want 再 install してもラベルが破壊されない, so that 既存の Issue / PR に紐づくラベル状態を失わず安全に再 install できる

#### Acceptance Criteria

1. When 対象リポジトリに必須ラベルがまだ 1 件も存在しない状態で初回 install が成功する, the Install Helper shall 必須ラベル全件を新規作成する
2. When 対象リポジトリに必須ラベルが部分的に存在する, the Install Helper shall 不足しているラベルのみを追加し、既存ラベルは変更しない
3. When 対象リポジトリに必須ラベル全件が既に存在する, the Install Helper shall 新規作成・更新を行わずに完了する
4. The Install Helper shall ラベルセットアップ処理の中で既存ラベルを削除またはリネームしない
5. While ラベル名・色・説明文の上書き更新は本機能のスコープ外, the Install Helper shall 既存ラベルの color / description を上書きしない

### Requirement 3: 認証・権限・API 失敗時の fail-soft 動作

**Objective:** As a `gh` 未認証 / 対象 repo への write 権限なし / API 一時障害下でセットアップを進めたいユーザー, I want ラベル部分が失敗しても install 全体は完走してくれる, so that テンプレート配置という主目的を中断されない

#### Acceptance Criteria

1. If `gh` CLI が `command -v` で見つからない, the Install Helper shall ラベルセットアップを skip し、install 全体は exit 0 で完走する
2. If `gh` が未認証である, the Install Helper shall ラベルセットアップを skip し、install 全体は exit 0 で完走する
3. If 対象リポジトリへの label 書き込み権限が無い, the Install Helper shall ラベルセットアップを skip し、install 全体は exit 0 で完走する
4. If GitHub API への接続失敗 / レート制限 / 一時的エラーで一部または全部のラベル作成が失敗する, the Install Helper shall ラベルセットアップを skip 扱いとし、install 全体は exit 0 で完走する
5. While ラベルセットアップが skip 扱いとなった, the Install Helper shall 後続の対象リポジトリ手順サマリ出力（既存）の前後いずれかで skip 理由と手動実行コマンドを 1 ブロック以上提示する
6. If ラベルセットアップが skip 扱いとなった, the Install Helper shall ユーザーがコピー & 貼り付けで再実行できる完全な手動コマンド文字列を出力に含める

### Requirement 4: opt-out オプション

**Objective:** As a CI / 別ツールでラベルを自前管理しているリポジトリ運用者, I want `--no-labels` でラベル処理を完全に止められる, so that 自分の運用と競合させずに install のみ走らせられる

#### Acceptance Criteria

1. When `install.sh --repo <path> --no-labels` が指定される, the Install Helper shall ラベルセットアップ処理を完全に skip する
2. When `--no-labels` が指定された skip, the Install Helper shall 認証失敗時の skip と区別できる出力（opt-out である旨）を提示する
3. When `--no-labels` が `--all` / `--repo` / `--dry-run` / `--force` のいずれと組み合わされる, the Install Helper shall 他オプションの挙動を変えずにラベル処理のみを抑止する
4. The Install Helper shall `--no-labels` を既定値（off）として扱い、無指定時はラベルセットアップを試行する

### Requirement 5: 出力・ユーザー可視性

**Objective:** As a install を眺めているユーザー, I want ラベル処理の結果が他ステップと同じ書式で見える, so that 何が起きたか・次に何をすべきかを 1 画面で把握できる

#### Acceptance Criteria

1. While ラベルセットアップが成功裏に完了する, the Install Helper shall 「ラベルセットアップが完了した」旨と、作成数・既存スキップ数を 1 行以上で要約表示する
2. While ラベルセットアップが skip 扱いとなる, the Install Helper shall skip した事実を出力し、Requirement 3.5 の手動実行コマンドを併記する
3. The Install Helper shall ラベルセットアップ部の出力プレフィクスを既存の install ステップ（テンプレート配置等）と統一感のある形式で出力する
4. While `--dry-run` が指定されている, the Install Helper shall 実 API 呼び出しを行わずに「これから実行されるラベルセットアップ内容」を表示する

### Requirement 6: 後方互換性

**Objective:** As a 既存 `install.sh` / `idd-claude-labels.sh` ユーザー, I want 既存 interface が壊れない, so that 既稼働の consumer repo / cron / CI が無修正で動き続ける

#### Acceptance Criteria

1. The Install Helper shall 既存 `install.sh` オプション `--repo` / `--local` / `--all` / `-h` / `--help` / `--dry-run` / `--force` の意味と挙動を本機能の追加で変更しない
2. The Install Helper shall 既存の対話モードのプロンプト文言・順序・分岐を本機能の追加で変更しない
3. The Install Helper shall 既存 `idd-claude-labels.sh` の引数仕様（`--repo` / `--force` / `-h` / `--help`）・exit code 意味・stdout サマリ書式を変更しない
4. The Install Helper shall 既存 `idd-claude-labels.sh` の `LABELS=(...)` で定義されたラベル名・色・説明文を本機能の追加で変更しない
5. While 既存 consumer repo に再 install が走る, the Install Helper shall 配置済みファイル・既存ラベルに対して破壊的変更を引き起こさない

### Requirement 7: README ドキュメント反映

**Objective:** As a README を読んで idd-claude を導入する新規ユーザー, I want 自動ラベル作成が走ることがドキュメントに記載されている, so that 手動 step を二重実行したり「ラベルが勝手にできた」と困惑することがなくなる

#### Acceptance Criteria

1. The README shall `install.sh --repo` 経由のセットアップ手順節で、ラベルセットアップが自動実行される旨を明記する
2. The README shall `--no-labels` で opt-out できる旨と、その推奨ユースケースを明記する
3. The README shall 認証不足等で skip された場合に手動 fallback 手順（`bash .github/scripts/idd-claude-labels.sh`）に進めばよいことを明記する
4. While 既存の手動セットアップ節（"ラベル一括作成（推奨）"）が残る, the README shall 自動実行と手動実行の関係（自動が走った場合は手動 step を改めて実行する必要はない）を矛盾なく説明する

## Non-Functional Requirements

### NFR 1: 非対話・cron-safe

1. The Install Helper shall ラベルセットアップ部で標準入力からの追加プロンプトを発行しない（`curl | bash` 経由・非 TTY 環境で停止しない）
2. The Install Helper shall ラベルセットアップに伴って sudo / 管理者権限を要求しない

### NFR 2: パフォーマンスと観測性

1. While ラベルセットアップを実行する, the Install Helper shall 既存の対象リポジトリ全体 install 1 回あたりの所要時間に対し、ラベルセットアップが正常終了する場合は 30 秒以内で完了する（GitHub API 通常応答時を想定）
2. If GitHub API 応答が NFR 2.1 の上限を超えそうな状況になる, the Install Helper shall タイムアウトまたはエラー扱いで skip し、install 全体を停滞させない
3. The Install Helper shall ラベルセットアップ結果（成功 / skip / 失敗カテゴリ）を grep 可能な書式で stdout または stderr に記録する

### NFR 3: セキュリティ

1. The Install Helper shall API 認証情報（token 等）を stdout / stderr / ログに出力しない
2. The Install Helper shall ラベルセットアップが skip された場合に、`gh auth login` を促す案内以外の追加認証情報入力を要求しない

## Out of Scope

- Watcher 側（`local-watcher/bin/issue-watcher.sh` / GitHub Actions workflow）からのラベル自動補完
- `setup.sh`（curl パイプ用 bootstrap）独自のラベル処理。`setup.sh` は最終的に `install.sh` を exec するので、本機能の対象は `install.sh` 側のみ
- `idd-claude-labels.sh` 自体の機能拡張（色変更・説明文更新・ラベル削除等）
- 既存ラベルの color / description の上書き更新（`--force` の自動付与）
- GitHub Actions 経由の install フロー対応
- ラベルセット定義の追加・変更（必須ラベル一覧は `idd-claude-labels.sh` 側の真実源を踏襲）
- private fork など、対象リポジトリの種別ごとの個別最適化（fail-soft の枠内で動けば足りるとする）

## Open Questions

以下の点は Issue 本文 "判断を委ねたい点" として作成者が明示的に挙げており、要件定義段階での
推測ではなく **設計フェーズ（Architect）または人間判断** に委ねます。

- 対象リポジトリ `owner/repo` の特定方法の優先順位（`git -C <path> remote get-url origin` パース / 環境変数 `REPO` / `--repo owner/name` 形式の引数導入のいずれを優先するか）。なお現在の `install.sh --repo` は **ローカルパス** を受け取る仕様であり、`owner/repo` 形式の引数導入は後方互換性検討が必要
- `--no-labels` の代替として `IDD_CLAUDE_SKIP_LABELS=true` env var でも opt-out 可能にすべきか（現要件では `--no-labels` のみを必須としている）
- private fork で `gh label create --repo "$REPO"` がそのまま機能するかの検証範囲（fail-soft で skip されれば要件上は満たせるが、ベストエフォートで成功させる対応をどこまで取り込むか）
- 自動ラベルセットアップが成功した場合の README 既存「手動でラベル一括作成」節の扱い（節を残す / 「fallback として」と注記する / 削除する のいずれにするか）
