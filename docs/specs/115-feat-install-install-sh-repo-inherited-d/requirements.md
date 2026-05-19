# Requirements Document

## Introduction

既存リポジトリ（特に fork や `git push --mirror` で履歴を持ち込んだ repo）に
`install.sh --repo <path>` で idd-claude を導入すると、引き継がれた古い `docs/specs/<N>-*/`
ディレクトリや `claude/issue-<N>-*` ブランチが新しい Issue 番号と衝突し、watcher が誤った
spec を resume 対象に選んでしまう事故が発生した。本機能は install 時にこの「履歴持ち込み」
の兆候を検出し、ユーザーに警告を提示することで事前にクリーンアップを促す。インストール
自体は止めず（exit 0）、新規 dependency を追加せず（`gh` / `git` 既存依存内で完結）、
クリーンな新規 repo では既存出力との差分ゼロを保証する fail-soft 設計とする。

## Requirements

### Requirement 1: 履歴持ち込みの検出と警告表示

**Objective:** As a fork/mirror 由来のリポジトリに idd-claude を導入するユーザー, I want install 直後に引き継がれた spec / ブランチの存在を警告される, so that watcher が古い spec を誤って resume する事故を未然に防げる

#### Acceptance Criteria

1. When `install.sh --repo <path>` がテンプレート配置に成功した後、対象リポジトリに `docs/specs/<N>-*/` 形式（`<N>` は 1 文字以上の数字）のディレクトリが 1 件以上存在する, the Install Helper shall 「inherited な docs/specs/ が検出された」旨の警告を 1 件以上出力する
2. When `install.sh --repo <path>` がテンプレート配置に成功した後、対象リポジトリの `origin` リモートに `claude/issue-<N>-(design|impl)-*` 形式のブランチが 1 件以上存在する, the Install Helper shall 「inherited な claude/issue-* ブランチが検出された」旨の警告を 1 件以上出力する
3. When `install.sh --repo <path>` がテンプレート配置に成功した後、対象リポジトリの `origin` リモートに `claude/issue-<N>-*` 形式のブランチが存在し、かつそれらブランチの `<N>` の過半数が対象リポジトリの現存 Issue 番号集合に含まれない, the Install Helper shall 「fork/mirror 由来の可能性が高い」旨の警告を出力する
4. The Install Helper shall 警告メッセージ本体に「この警告を無視しても install 自体は正常完了している」旨を明示する
5. The Install Helper shall 警告メッセージ本体に推奨対応（古い `docs/specs/` ディレクトリと `claude/issue-*` ブランチの確認・削除手順を README / QUICK-HOWTO へのリンクとして案内）を含める

### Requirement 2: false positive ゼロの保証

**Objective:** As a クリーンな新規リポジトリに idd-claude を初めて導入するユーザー, I want 検出ロジックが誤発火しない, so that 警告ノイズで実害のない指摘に煩わされない

#### Acceptance Criteria

1. When 対象リポジトリに `docs/specs/<N>-*/` 形式ディレクトリが 1 件も存在せず、かつ `origin` に `claude/issue-*` ブランチが 1 件も存在しない, the Install Helper shall 本機能由来の警告を 1 件も出力しない
2. While `docs/specs/` ディレクトリ自体は存在するが `<N>-*/` 形式（先頭が数字 + ハイフン）のサブディレクトリを含まない, the Install Helper shall Requirement 1.1 の警告を出力しない
3. While `origin` リモートが未設定もしくは到達不能, the Install Helper shall Requirement 1.2 / 1.3 の警告を出力せず、原因を 1 行以上ログに残して継続する
4. The Install Helper shall 本機能の検出処理を、テンプレート配置が成功した対象リポジトリに対してのみ実行する（`install.sh --local` のみ指定時は実行しない）

### Requirement 3: fail-soft とインストール継続

**Objective:** As a 警告が出ても install を完走させたいユーザー, I want 検出処理の失敗が install 全体を止めない, so that テンプレート配置という主目的を中断されない

#### Acceptance Criteria

1. The Install Helper shall 本機能による警告が 1 件以上出力された場合でも、install 全体の exit code を 0 のまま維持する
2. If 検出処理（`git` / `gh` 呼び出し）が認証エラー・ネットワーク失敗・タイムアウト等で部分的または全部失敗する, the Install Helper shall 検出処理を skip し、install 全体は exit 0 で完走する
3. If 対象リポジトリへの GitHub Issue 一覧取得が失敗する, the Install Helper shall Requirement 1.3 の判定のみを skip し、Requirement 1.1 / 1.2 の判定は継続する
4. The Install Helper shall 本機能の検出処理が skip された場合、skip 理由を 1 行以上 stdout / stderr に記録する

### Requirement 4: dry-run 対応

**Objective:** As a `--dry-run` で事前に挙動を確認したいユーザー, I want 警告判定が dry-run でも実施され、警告内容が事前に見える, so that 本番実行前に対象リポジトリの履歴状態を把握できる

#### Acceptance Criteria

1. When `install.sh --repo <path> --dry-run` が指定される, the Install Helper shall Requirement 1.1 / 1.2 / 1.3 の検出処理を実行する
2. While `--dry-run` 指定下で警告を出力する, the Install Helper shall 警告行を `[DRY-RUN] WARNING:` プレフィックスで出力する
3. While `--dry-run` 指定なしで警告を出力する, the Install Helper shall 警告行を `[INSTALL] WARNING:`（または既存ログ書式と整合する WARNING ステータス）プレフィックスで出力する
4. The Install Helper shall `--dry-run` 下では検出処理においてもファイルシステム / リモート API への書き込みを発生させない

### Requirement 5: 出力・ユーザー可視性

**Objective:** As a install を眺めているユーザー, I want 警告が既存ログ書式と整合し、原因と次アクションが 1 画面で把握できる, so that 何が起きたか・次に何をすべきかを即座に判断できる

#### Acceptance Criteria

1. The Install Helper shall 本機能の警告出力プレフィックスを既存 install ステップ（テンプレート配置・ラベルセットアップ）と統一感のある形式で出力する
2. While 検出された inherited 項目が複数ある, the Install Helper shall 検出カテゴリ（docs/specs / claude/issue-* ブランチ / Issue 番号不一致）ごとに区別可能な書式で 1 件以上の例（先頭数件のディレクトリ名・ブランチ名）を提示する
3. The Install Helper shall 警告ブロックの最後に「無視しても install は完了している」旨と、README / QUICK-HOWTO の該当節への参照を含める

### Requirement 6: setup.sh からの引数透過

**Objective:** As a `setup.sh`（curl ワンライナー bootstrap）経由で idd-claude を導入するユーザー, I want install.sh が受け取るオプションが setup.sh からも透過される, so that 既存ユーザーが同じ警告動作を curl 経由でも受け取れる

#### Acceptance Criteria

1. The Bootstrap Helper（setup.sh）shall `install.sh` への引数透過（`--repo` / `--dry-run` 等）を本機能の追加で変更しない
2. When ユーザーが `setup.sh` 経由で `--repo` を指定して install を実行する, the Install Helper shall 本機能の警告判定を Requirement 1〜5 と同一の条件で実施する

### Requirement 7: ドキュメント反映

**Objective:** As a README / QUICK-HOWTO を読んで idd-claude を導入する新規ユーザー, I want fork/mirror 由来 repo の注意点と警告対応手順が明文化されている, so that 警告を見た時に何をすべきか自己解決できる

#### Acceptance Criteria

1. The README shall fork / mirror 由来のリポジトリに idd-claude を導入する際の注意（inherited な `docs/specs/` / `claude/issue-*` ブランチがあると watcher が誤動作し得る旨）を 1 節以上で明記する
2. The README shall 警告が出た場合の推奨対応手順（古い `docs/specs/` ディレクトリと `claude/issue-*` ブランチを削除・整理する手順）を 1 ブロック以上で明記する
3. The QUICK-HOWTO（または README 同等節）shall 同一 PR 内で「fork/mirror から導入するときの注意」節を追加する
4. The README shall 警告を無視して install を続行することの影響（watcher が古い spec を resume 対象に選ぶ可能性）を明示する

### Requirement 8: 後方互換性

**Objective:** As a 既稼働の `install.sh` ユーザー, I want 既存オプション・出力フォーマットが壊れない, so that 既稼働の consumer repo / cron / CI が無修正で動き続ける

#### Acceptance Criteria

1. The Install Helper shall 既存 `install.sh` オプション（`--repo` / `--local` / `--all` / `--dry-run` / `--force` / `--no-labels` / `-h` / `--help`）の意味と挙動を本機能の追加で変更しない
2. The Install Helper shall 既存の対話モードのプロンプト文言・順序・分岐を本機能の追加で変更しない
3. While 対象リポジトリがクリーンな新規 repo（Requirement 2.1 の条件を満たす）である, the Install Helper shall 本機能の追加前と stdout / stderr の出力差分をゼロに保つ
4. The Install Helper shall 本機能の追加で `install.sh` の新規外部依存（`gh` / `git` / `jq` 以外のコマンド）を発生させない

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. While 検出処理を実行する, the Install Helper shall 検出処理全体（D-1 / D-2 / D-3 の合計）を 10 秒以内で完了する（GitHub API 通常応答時を想定）
2. If 検出処理が NFR 1.1 の上限を超えそうな状況になる, the Install Helper shall タイムアウトまたはエラー扱いで skip し、install 全体を停滞させない

### NFR 2: 観測性

1. The Install Helper shall 本機能の判定結果（警告発火 / 全項目クリア / skip）を grep 可能な書式で stdout または stderr に記録する
2. The Install Helper shall 警告本文のいずれの行にも認証情報（GitHub token 等）を出力しない

### NFR 3: 非対話・cron-safe

1. The Install Helper shall 本機能の検出処理で標準入力からの追加プロンプトを発行しない（`curl | bash` 経由・非 TTY 環境で停止しない）
2. The Install Helper shall 本機能の検出処理に伴って sudo / 管理者権限を要求しない

## Out of Scope

- 旧 `docs/specs/<N>-*/` ディレクトリ / 旧 `claude/issue-*` ブランチの自動削除（destructive 操作は install.sh が勝手にやらない、案内のみ）
- watcher 側（`local-watcher/bin/issue-watcher.sh` / `.github/workflows/issue-to-pr.yml`）でのスラグ照合ガードや resume 対象選定の改善（別 Issue で扱う）
- 検出された inherited な spec / ブランチを「どの Issue に再割当てするか」「マージするか」の自動推定
- `install.sh --local` のみ指定時の検出処理（ローカル watcher 配置には対象リポジトリの概念が存在しないため）
- GitHub Actions 経由の install フロー対応（本機能は `install.sh` 側のみ）
- 警告メッセージの多言語対応（既存 install.sh と同じ日本語ベースのみ）
- D-3 における「現存 Issue 番号と一致しない比率」の閾値そのものをユーザーが env var 等で調整できる仕組み（実装側で固定値を決め打ちする）

## PM 判断: D-3 を MUST に含めるか

Issue 本文の「仮案・判断を委ねたい点」に挙がっていた D-3（origin の `claude/issue-*` ブランチを
現存 Issue 番号と突合し、対応 Issue 無しが大半なら fork 持ち込みの可能性大として警告）について、
PM として **MUST（Requirement 1.3 として明文化）** と判断した。理由は以下:

1. **新規依存が発生しない**: `install.sh` は既に `gh` を依存に持つ（`install.sh:580, 628` で
   `command -v gh` / `gh repo view` / `gh auth status` を使用済み）。D-3 で `gh issue list`
   を追加で呼ぶことは新規依存にはあたらない（README / CLAUDE.md の依存一覧と整合）
2. **fail-soft で false positive リスクを抑えられる**: Requirement 3.3 で「Issue 一覧取得失敗時は
   D-3 のみ skip、D-1 / D-2 は継続」と規定したため、`gh` 未認証 / private repo で Issue 取得不能な
   場合でも D-1 / D-2 は機能する
3. **Issue 本文の懸念は別形で解消済み**: Issue 本文の「`gh api` を呼ぶため install.sh の依存が
   増えるなら D-1/D-2 のみで足りる」という懸念は前提が成立しない（既に `gh` 依存済み）ため、
   懸念の根拠が無くなる

D-3 を MUST に含めることで、fork/mirror 由来 repo の検出精度を高め、本機能の主目的（事故防止）
を達成する。なお、D-3 単体が発火条件を満たすために必要な「過半数が現存 Issue 番号に含まれない」
の具体的閾値（過半数 / 全件 / N 件未満一致 など）は **設計フェーズ（Architect）に委ねる**
判断とする（要件としては「過半数」と表現し、設計で確定）。

## Open Questions

- D-3 の「現存 Issue 番号に含まれない」判定で、closed Issue を母集合に含めるか open のみとするか
  （fork 元で close 済み Issue にブランチが残っていることは普通にあり得るため、closed 含む方が
  false positive を減らせる可能性がある）。設計フェーズで GitHub API コール仕様と合わせて決定
- 警告メッセージ内で「先頭数件の例」を提示する際の件数（3 件 / 5 件 / 全件）。設計で UX 観点から確定
- 既存の Issue 本文には QUICK-HOWTO.md の名指しがあるが、現リポジトリには README.md のみが
  存在する（`docs/QUICK-HOWTO.md` / ルート `QUICK-HOWTO.md` 共に未確認）。
  Requirement 7.3 のドキュメント反映先を「README.md の独立節として追加」とするか
  「新規に QUICK-HOWTO.md を作成」とするかは設計フェーズで決定。本要件では「QUICK-HOWTO（または
  README 同等節）」と両論併記している
