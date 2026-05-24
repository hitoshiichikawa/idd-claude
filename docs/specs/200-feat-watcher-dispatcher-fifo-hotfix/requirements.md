# Requirements Document

## Introduction

ローカル watcher の Dispatcher は、`auto-dev` 付きの処理対象 Issue を取得して先頭から順に
slot へ投入するが、現状の候補取得クエリは `--sort` も jq ソートも持たないため GitHub の
既定順（作成日時の降順 = 新しい Issue 優先）で処理される。これは「古い Issue から消化する」
という運用者の直観（FIFO）と矛盾し、古い積み残し Issue が新規 Issue に追い越され続ける。
本機能は Dispatcher の候補処理順を FIFO（Issue 番号昇順 = 古いものから）に変更し、
さらに `hotfix` ラベル付き Issue を非 hotfix Issue より先に処理する 2 段優先を導入する。
取得件数上限（`--limit`）との順序整合・後方互換性（env var / exit code / ログ prefix /
既存ラベル不変）を厳守し、pick 順序以外の Dispatcher 挙動（path-overlap / holder 判定 /
awaiting-slot 等）は一切変更しない。

## Requirements

### Requirement 1: デフォルト FIFO 処理順

**Objective:** As a watcher の運用者, I want Dispatcher が処理対象 Issue を Issue 番号昇順（古いものから）で dispatch すること, so that 古い積み残し Issue が新規 Issue に追い越されず順番に消化される

#### Acceptance Criteria

1. When Dispatcher が 1 サイクル分の処理対象 Issue を slot へ投入するとき, the Dispatcher shall Issue 番号昇順（小さい番号 = 古いものから）の順序で投入する
2. While `hotfix` ラベルがどの候補にも付与されていない状態, when Dispatcher が候補を処理するとき, the Dispatcher shall 全候補を Issue 番号昇順で処理する
3. The Dispatcher shall Issue 番号昇順順序を GitHub の作成日時昇順（created-asc / 古いものから）と等価な観測順序として扱う
4. When Dispatcher が候補を投入するとき, the Dispatcher shall pick 順序のみを本要件で規定し、path-overlap 判定・holder 判定・awaiting-slot 遷移・claim ラベル付与の挙動を本機能導入前と同一に保つ

### Requirement 2: hotfix ラベルによる優先上書き

**Objective:** As a watcher の運用者, I want `hotfix` ラベル付き Issue を非 hotfix Issue より先に処理させること, so that 緊急対応の Issue を古い通常 Issue より優先的に slot へ投入できる

#### Acceptance Criteria

1. When 候補集合に `hotfix` ラベル付き Issue と非 hotfix Issue が混在するとき, the Dispatcher shall すべての `hotfix` Issue を非 hotfix Issue より先に投入する
2. While 同一ティア内（`hotfix` 同士、または非 hotfix 同士）, when Dispatcher が候補を投入するとき, the Dispatcher shall そのティア内で Issue 番号昇順（FIFO）を維持する
3. When 複数の `hotfix` Issue が候補に含まれるとき, the Dispatcher shall それら `hotfix` Issue 同士を Issue 番号昇順で投入する
4. If 候補 Issue に `hotfix` ラベルが付与されていない（または取得結果にラベル情報が欠落している）, the Dispatcher shall 当該 Issue を非 hotfix ティアの候補として安全側に扱う
5. The Dispatcher shall 優先ティアを `hotfix` 単一ラベルの 2 段（hotfix / 非 hotfix）のみとし、多段優先度を導入しない

### Requirement 3: 取得件数上限との順序整合

**Objective:** As a watcher の運用者, I want 候補取得の件数上限（`--limit`）が FIFO / hotfix 優先順を歪めないこと, so that 上限切り出しによって本来優先されるべき古い Issue や hotfix Issue が取りこぼされない

#### Acceptance Criteria

1. When 処理対象 Issue が取得件数上限を超えて存在するとき, the Dispatcher shall hotfix ティア優先かつ各ティア内 Issue 番号昇順で評価したうえで先頭から投入対象を選ぶ
2. If 処理対象 Issue が取得件数上限を超えて存在するとき, the Dispatcher shall 順序上先頭に来るべき候補（最も古い Issue・最も古い hotfix Issue）を、件数上限による母集合切り出しで取りこぼさない
3. The Dispatcher shall 取得件数上限の値そのものの意味（1 サイクルで投入対象として評価する候補件数の上限）を本機能導入前と同一に保つ

### Requirement 4: hotfix ラベルの新設と配布

**Objective:** As a idd-claude の運用者, I want `hotfix` ラベルがラベル一括作成スクリプトで作成・配布されること, so that live repo と consumer repo の双方で hotfix 優先運用を有効化できる

#### Acceptance Criteria

1. When ラベル一括作成スクリプトを実行するとき, the ラベルスクリプト shall `hotfix` ラベルを作成対象に含める
2. The ラベルスクリプト shall `hotfix` ラベルを live 用（`.github/scripts/idd-claude-labels.sh`）と template 用（`repo-template/.github/scripts/idd-claude-labels.sh`）の双方の定義に含める
3. When `hotfix` ラベルが既に対象 repo に存在する状態でラベルスクリプトを再実行するとき, the ラベルスクリプト shall 既存ラベルを破壊せず冪等に振る舞う
4. The ラベルスクリプト shall 既存ラベルの name / color / description を本機能導入前と同一に保つ

### Requirement 5: 後方互換性と移行案内

**Objective:** As a 既存 watcher 運用者, I want デフォルト処理順の変更が告知され既存契約が維持されること, so that 既存 cron / launchd / consumer repo の運用を壊さずに移行できる

#### Acceptance Criteria

1. The Dispatcher shall 既存 env var 名・exit code の意味・ログ出力 prefix を本機能導入前と同一に保つ
2. The Dispatcher shall 既存ラベル名（claim 用・除外用ラベル等）を本機能導入前と同一に保つ
3. While 処理対象 Issue が存在しない状態, when Dispatcher を実行するとき, the Dispatcher shall 本機能導入前と同等の正常終了挙動（対象なしメッセージ + exit 0）を維持する
4. Where デフォルト処理順が新しい Issue 優先から古い Issue 優先（FIFO）へ変わる, the README shall 当該挙動変更を migration note として明記する

## Non-Functional Requirements

### NFR 1: 静的解析・後方互換性の検証可能性

1. When `local-watcher/bin/issue-watcher.sh` および両ラベルスクリプトを変更したとき, the 変更成果物 shall `shellcheck` を警告ゼロで通過する
2. The ラベルスクリプト shall `hotfix` ラベル追加を既存ラベルセットへの追加のみで実現し、既存ラベルの削除・改名を行わない

### NFR 2: 順序の決定性

1. When 同一の候補集合に対して Dispatcher を複数回実行するとき, the Dispatcher shall 同一の投入順序（hotfix ティア優先 + 各ティア Issue 番号昇順）を毎回再現する

## Out of Scope

- 多段優先度ラベル（`priority:high` / `priority:low` 等の 3 段以上のティア）の導入。本機能は `hotfix` 単一ラベル 2 段のみ（YAGNI、別 Issue で扱う）
- path-overlap 判定・holder 判定・awaiting-slot 遷移・Pre-Claim Filter・Open Design PR Guard 等、pick 順序以外の Dispatcher ロジックの変更
- 取得件数上限の値（既定 5）そのものの変更
- Triage / PR Iteration / Promote Pipeline 等、Dispatcher の Issue pickup 経路以外のキュー順序変更
- ラベルの自動付与（`hotfix` は人間が手動付与する運用前提。自動判定ロジックは含めない）
- consumer repo への既存配布済みラベルの遡及的再配布の自動トリガー（`idd-claude-labels.sh` 再実行は運用者の手動操作）

## Open Questions

- なし（Issue 本文で FIFO 定義 = Issue 番号昇順 ≒ created-asc、hotfix 単一ラベル 2 段、ラベル不在時の安全側フォールバック、`--limit` 順序整合の要件、後方互換性方針がいずれも明示されている。`--limit` を満たす具体的取得方式（`sort:created-asc` 付与 / 2 段クエリ / 十分な limit + jq 2 キーソート 等）の選択は実装方式であり design.md / Developer の領分として委譲する）
