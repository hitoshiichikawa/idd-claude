# Requirements Document

## Introduction

idd-claude の Issue Watcher は現状、単一プロセスが `flock` で 1 サイクル全体を直列化し、
ピックアップ済み Issue を 1 件ずつ `git checkout -B` で同じ作業ツリーに切り替えながら処理する。
このため、複数の `auto-dev` Issue が同時に到着しても 1 件目の Claude セッションが終わるまで
2 件目に着手できず、Claude Max の 5 時間ウィンドウや人間の待ち時間を有効活用できない。
本フェーズ（Phase C / 親 Issue #13）は、watcher の「入口」を slot 並列化することで
複数 Issue を同時並行に開発できるようにする。各 slot は専用の `git worktree` で物理隔離し、
Dispatcher は単一プロセスで Issue pickup と `claude-picked-up` ラベル付与を atomic に行うことで
同じ Issue が 2 slot に投入される label レースを排除する。
hot file 競合の予防（Phase E / #18）や merge queue 側の並列 rebase（Phase A / #14・Phase D / #17）は
本フェーズの対象外。

## Requirements

### Requirement 1: 並列度設定と既定値

**Objective:** As a watcher operator, I want 並列度を環境変数で制御し、デフォルトでは現状と同じ直列挙動にしたい, so that 既存の cron / launchd 設定を一切変えずに段階的に opt-in できる

#### Acceptance Criteria

1. The Issue Watcher shall 並列度を制御する環境変数 `PARALLEL_SLOTS` を読み取る
2. Where `PARALLEL_SLOTS` が未設定である, the Issue Watcher shall 並列度を `1`（直列・本機能導入前と同じ挙動）として動作する
3. If `PARALLEL_SLOTS` の値が正の整数として解釈できない, the Issue Watcher shall そのサイクルを中断し、watcher ログに ERROR レベル相当で原因を記録する
4. While `PARALLEL_SLOTS=1` で動作している, the Issue Watcher shall 本機能導入前のサイクル動作（同時実行 1 件・既存ログ書式・既存 Issue 処理順序の見え方）と外形的に同一であること
5. The README.md shall `PARALLEL_SLOTS` の意味・デフォルト値・推奨される運用上の上限の指針を明記する

### Requirement 2: 単一プロセス内 Dispatcher と claim atomicity

**Objective:** As a watcher operator, I want 1 プロセス内で Issue の取得と `claude-picked-up` ラベル付与を原子的に完結させたい, so that 同じ Issue が 2 つの slot に同時に投入される label レースを構造的に排除できる

#### Acceptance Criteria

1. The Issue Watcher shall 1 サイクル内で Dispatcher を単一プロセスとして起動し、空き slot への Issue 投入を逐次（1 Issue ずつ）行う
2. When Dispatcher が処理対象 Issue を 1 件 pop した, the Dispatcher shall 当該 Issue に `claude-picked-up` ラベルを付与してから slot にバックグラウンド起動を委譲する
3. If `claude-picked-up` ラベル付与に失敗した, the Dispatcher shall 当該 Issue の slot 起動を中止し、watcher ログに WARN レベル相当で原因を記録した上で次の Issue へ進む
4. The Dispatcher shall 同一サイクル内で同一 Issue 番号を 2 つ以上の slot に同時投入しない
5. While いずれかの slot が処理中である, the Dispatcher shall 空き slot がある限り次の対象 Issue を pop して投入する
6. The Dispatcher shall サイクル終了前に起動済みの全 slot のバックグラウンド処理の完了を待ち合わせてから自身のプロセスを終了する
7. If Dispatcher プロセス自体が異常終了した, the Issue Watcher shall 既に `claude-picked-up` が付与されている Issue を次回サイクルで自動的に再ピックアップしない（既存の `claude-picked-up` 終端ガードを維持する）

### Requirement 3: Per-slot 永続 Worktree

**Objective:** As a watcher operator, I want 各 slot が専用の永続 git worktree を持つようにしたい, so that 同時実行中の slot 同士が同じ作業ツリーを書き換える物理競合を構造的に防げる

#### Acceptance Criteria

1. The Issue Watcher shall 各 slot に対して `$HOME/.issue-watcher/worktrees/<repo-slug>/slot-N/` を専用作業ディレクトリとして割り当てる（N は 1 以上 `PARALLEL_SLOTS` 以下の整数）
2. When 当該 slot 用の worktree ディレクトリが未初期化である, the Issue Watcher shall 該当 slot の worktree をその場で 1 度だけ作成する（既存の repo クローンと連動した worktree として）
3. While 当該 slot 用の worktree ディレクトリが既に存在する, the Issue Watcher shall その worktree を再利用し、再作成しない
4. When slot に Issue が投入された, the slot Worker shall 自身の worktree を `origin/main` の最新状態に強制リセットし、追跡外の作業ファイル・ディレクトリを除去する
5. The slot Worker shall 自身の worktree 内のみで Claude Code を起動し、他 slot の worktree や元の `REPO_DIR` 直下の作業ツリーへの書き込みを行わない
6. If 該当 slot の worktree 初期化（作成または最新化）に失敗した, the slot Worker shall その Issue 処理を中止し、watcher ログに WARN 以上で原因を記録した上で当該 Issue の `claude-picked-up` を `claude-failed` に置き換える
7. The Issue Watcher shall worktree 用ベースディレクトリを repo ごと（`<repo-slug>` 単位）に分離し、複数 repo を並行運用する場合でも worktree パスが衝突しないようにする

### Requirement 4: Per-slot ロックと多重起動防止

**Objective:** As a watcher operator, I want slot ごとに独立した lock を取り、グローバルな単一インスタンス lock に依存しない設計にしたい, so that 複数 slot が真に並列に動きつつ、同一 slot の二重起動だけを確実に防げる

#### Acceptance Criteria

1. The Issue Watcher shall 各 slot に対して `$HOME/.issue-watcher/<repo-slug>-slot-N.lock` を専用 lock ファイルとして割り当てる
2. When slot Worker が処理を開始する, the slot Worker shall 自身の slot lock を非ブロッキングで取得する
3. If slot lock の取得に失敗した（既に同 slot のプロセスが動いている）, the slot Worker shall 当該 Issue の処理を中止し、watcher ログに INFO 以上で「slot 多重起動を回避した」旨を記録する
4. The Issue Watcher shall slot 間で別ファイルの lock を使い、ある slot の処理が他 slot の処理開始をブロックしない
5. The Issue Watcher shall 既存の repo 単位多重起動防止（`LOCK_FILE` による cron 多重起動防止）を Dispatcher プロセス自身に対して引き続き適用する

### Requirement 5: SLOT_INIT_HOOK（依存セットアップ用 opt-in フック）

**Objective:** As a watcher operator, I want slot worktree 初期化のタイミングで任意の依存セットアップ（パッケージインストール等）を差し込めるようにしたい, so that 言語ランタイムや依存ツールの準備をユーザースクリプトに委ねられる

#### Acceptance Criteria

1. The Issue Watcher shall フック実行ファイルの絶対パスを指す環境変数 `SLOT_INIT_HOOK` を読み取る
2. Where `SLOT_INIT_HOOK` が未設定または空文字である, the Issue Watcher shall フックを起動しない（本機能導入前と同じ挙動）
3. Where `SLOT_INIT_HOOK` に存在する実行可能ファイルパスが指定されている, the slot Worker shall 自身の worktree を `origin/main` 最新状態にリセットした直後・Claude Code 起動前の 1 度だけ、当該フックを起動する
4. The slot Worker shall フックを起動する際、`PARALLEL_SLOTS` / `REPO` / `REPO_DIR` 等の既存環境変数に加え、当該 slot を識別する slot 番号と worktree パスを環境変数として子プロセスに渡す
5. The slot Worker shall フックを起動する際、シェル文字列の `eval` を行わず、絶対パス指定の実行ファイルとして直接子プロセス起動する
6. If `SLOT_INIT_HOOK` で指定されたパスが存在しないまたは実行権限がない, the slot Worker shall 当該 Issue の処理を中止し、watcher ログに ERROR レベル相当で原因を記録した上で `claude-picked-up` を `claude-failed` に置き換える
7. If フックが非ゼロ exit code で終了した, the slot Worker shall 当該 Issue の処理を中止し、watcher ログにフックの exit code と stderr 末尾を記録した上で `claude-picked-up` を `claude-failed` に置き換える
8. The README.md shall `SLOT_INIT_HOOK` の責任分界（フック内のコマンドはユーザー責任で実行され、idd-claude 側は内容を検査しない）を明記する

### Requirement 6: 並列実行時の可観測性

**Objective:** As a watcher operator, I want 並列実行中でもどの slot がどの Issue を処理しているかをログから即座に追えるようにしたい, so that 障害発生時に slot ごとに切り分けて原因を特定できる

#### Acceptance Criteria

1. The Issue Watcher shall 各 slot Worker が出力するログ行に、当該 slot 番号と処理中 Issue 番号を grep 可能な形で含める
2. The Issue Watcher shall 各 slot Worker のログを slot 番号と Issue 番号で識別可能なファイルパスに出力し、ログ行が他 slot のファイルに混入しないようにする
3. The Dispatcher shall サイクル開始時に「処理対象 Issue 件数」と「利用可能 slot 数」をログに記録する
4. The Dispatcher shall 各 Issue の slot 投入時刻と完了時刻をログに記録する
5. The Issue Watcher shall ログのタイムスタンプ書式（`[YYYY-MM-DD HH:MM:SS]`）を既存 watcher と同一に保つ

### Requirement 7: 既存運用との後方互換性

**Objective:** As an existing watcher user, I want 既存の cron 登録・env var・ラベル・lock パス・exit code を一切変えずに本機能を opt-in できるようにしたい, so that 既稼働環境を破壊せずに段階的に並列化できる

#### Acceptance Criteria

1. The Issue Watcher shall 既存の環境変数（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `MERGE_QUEUE_ENABLED` 等）の名称・意味・デフォルト値を変更しない
2. The Issue Watcher shall 既存の cron / launchd 登録文字列（`$HOME/bin/issue-watcher.sh` を起動するエントリ）が `PARALLEL_SLOTS` 未指定でも従来通り動作することを保証する
3. The Issue Watcher shall 既存ラベル（`auto-dev` / `claude-picked-up` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `needs-decisions` / `skip-triage` / `needs-rebase` / `needs-iteration`）の名称・意味・付与契約を変更しない
4. The Issue Watcher shall 既存の終端ラベル除外ロジック（`claude-picked-up` 等が付与済みの Issue を再ピックアップしない）を本機能でも維持する
5. The Issue Watcher shall 既存の exit code の意味を変更しない
6. While `PARALLEL_SLOTS=1` で動作している, the Issue Watcher shall slot 1 用の worktree のみを使用し、他の slot 用ディレクトリ・lock ファイルを生成しない

### Requirement 8: DoD 検証可能性

**Objective:** As a reviewer, I want 親 Issue #16 の DoD 各項目が外部から観察可能な挙動として検証できるようにしたい, so that PR レビュー時に挙動確認手順を機械的に再現できる

#### Acceptance Criteria

1. The Issue Watcher shall `PARALLEL_SLOTS=1` での動作と本機能導入前の動作の同等性を、ログ・成果物（PR の作成有無）レベルで観察可能にする
2. The Issue Watcher shall `PARALLEL_SLOTS=2` で 2 件の `auto-dev` Issue が時間的に重なって処理されることを、各 slot のログ出力タイムスタンプから観察可能にする
3. The Issue Watcher shall 同一サイクル内で同じ Issue 番号が 2 つの slot のログに同時に現れない（claim atomicity）ことを、slot ログ突合で検証可能にする
4. The Issue Watcher shall 並列実行中の各 slot が他 slot の作業ファイルを書き換えていないことを、slot worktree の独立性から観察可能にする（互いに干渉した形跡が残らない）
5. The Issue Watcher shall `SLOT_INIT_HOOK` 指定時にフックが各 slot 初期化で 1 度ずつ呼び出されたことを、ログから観察可能にする

## Non-Functional Requirements

### NFR 1: 性能・スループット

1. While `PARALLEL_SLOTS=N` (N ≥ 2) で動作している, the Issue Watcher shall N 件の処理対象 Issue が存在するとき、それらを概ね並列に進行させ、N 件直列処理時の総所要時間より明確に短縮する（具体的には 2 件並列時に直列の 50%〜70% 程度を目安とする）
2. The Dispatcher shall slot 投入のオーバーヘッド（label 付与から子プロセス起動まで）を 1 Issue あたり 5 秒以内に収める

### NFR 2: 安全性

1. The Issue Watcher shall 各 slot Worker の異常終了が他 slot の処理を巻き込んで停止させない（1 slot の失敗で全 slot が落ちない）
2. The Dispatcher shall slot Worker からのいかなる戻り値・標準出力にも依存せず、`claude-picked-up` ラベル付与のみで claim を成立させる
3. The Issue Watcher shall `SLOT_INIT_HOOK` を起動する際、フック文字列をシェルに展開させず、絶対パス起動のみを許容することで意図しないコマンド注入を構造的に防ぐ

### NFR 3: 観測可能性

1. The Issue Watcher shall slot 番号を含む識別語（例: `slot-1:` / `slot-2:`）を各 slot ログ行の prefix として grep 可能な形で出力する
2. The Issue Watcher shall slot ログのファイル分離により、`PARALLEL_SLOTS=2` 以上でもログ行が混ざらない（読み手が `slot-N` / `Issue #M` の組み合わせを後追いで再現できる）

### NFR 4: 互換性・運用性

1. The Issue Watcher shall worktree ベースディレクトリ・slot lock ファイルパスのうち、`PARALLEL_SLOTS=1` で利用しない slot 用のリソース（slot-2 以降のディレクトリ・lock）を作成しない
2. The Issue Watcher shall worktree 用ディスクスペースが不足する状況に備え、worktree 配置先（`$HOME/.issue-watcher/worktrees/`）のディスク使用上の前提（フル clone × N 倍に近い容量を要する旨）を README に明記する

## Out of Scope

- ホットファイル（同一ファイルを複数 Issue が同時に編集する）の予防・検知（Phase E / #18 の範囲）
- merge queue 側の並列 rebase ワーカー（Phase A / #14・Phase D / #17 の範囲）
- 複数 repo にまたがる横断 Dispatcher（既存通り、複数 repo は cron 側で別エントリとして並列に回す前提を維持）
- slot 間で Issue の優先度・依存関係を解決するスケジューリング
- GitHub Actions 版ワークフロー（`.github/workflows/issue-to-pr.yml`）への並列化機能の組み込み
- worktree 配下の依存キャッシュ共有・ホストレベルのリソース制御（CPU / メモリ quota）
- 動的な `PARALLEL_SLOTS` 増減（サイクル途中での slot 数変更）
- Claude Max 利用枠（5 時間ウィンドウ）の自動制御・残量検知
- merge queue / PR Iteration / Design Review Release Processor 等、既存サブプロセッサーの並列化（本フェーズは「入口（Issue 処理）」の並列化のみを対象）

## Open Questions

- 既存 cron 登録は `$HOME/bin/issue-watcher.sh` を 1 プロセス起動する形だが、Phase C ではこの 1 プロセスが Dispatcher 役を兼ね、内部で slot Worker をバックグラウンド起動する設計でよいか（= 既存 cron 登録文字列を一切変えない前提）。それとも Dispatcher と slot Worker を別実行ファイルに分割する設計を許容するか
- `SLOT_INIT_HOOK` 失敗時、本要件では「当該 Issue を `claude-failed` に遷移して次の Issue に進む」設計としたが、ユースケースによっては「watcher サイクル全体を fail-fast 中断する」方が望ましい（依存セットアップ系は repo 全体の前提なので 1 件失敗したら全件失敗扱いにすべき、という見方）可能性がある。どちらの方針が運用上望ましいか確認したい
- `PARALLEL_SLOTS` の推奨値の指針（Issue 本文では「2 or 3。Claude Max 5h window 的には 2 が無難」と示唆）を README にどこまで具体的に記載するか。特定モデルプランに依存する数値はメンテナンス負荷が高いため、「2 を初期推奨、3 以上は Max 枠と相談」程度の抽象表現に留めてよいか
- 既存 `MERGE_QUEUE_ENABLED` / `PR_ITERATION_ENABLED` / `DESIGN_REVIEW_RELEASE_ENABLED` 等のサブプロセッサーは Dispatcher 起動の前後どちらで実行するか。本要件では「Phase C は入口並列化のみで、サブプロセッサーは現状の直列起動位置を維持する」前提だが、Architect 側で配置を変えたいケースが出る可能性があるため、配置の自由度を design.md 側に委ねてよいか確認したい
