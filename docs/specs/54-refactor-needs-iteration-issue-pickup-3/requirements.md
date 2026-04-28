# Requirements Document

## Introduction

`needs-iteration` ラベルは PR Iteration Processor が処理する **PR 専用ラベル**だが、人間（レビュワー）が誤って Issue 側に付与しても GitHub のラベル機構自体は防げない。実際、PR #51 のレビュー反復用 `needs-iteration` を Issue #16 に誤付与し、`ready-for-review` を Issue から外した結果、watcher の Issue 取得クエリがその Issue を再 pickup → impl-resume 起動 → 既存 PR #51 が force push で close される事故が発生した。本要件定義は、この種の人為ミスを「コード」「ドキュメント」「エージェントプロンプト」の 3 層で構造的に止めるための observable な要件を定義する。スコープは防御の定着までで、誤付与の自動修正・通知や GitHub API 側でのラベルスコープ強制は扱わない。

## Requirements

### Requirement 1: Watcher の Issue 取得クエリでの `needs-iteration` 除外

**Objective:** As an idd-claude 運用者, I want watcher が Issue 側に誤って `needs-iteration` が付いている場合に当該 Issue を pickup しないこと, so that PR レビュー反復用ラベルの誤付与によって既存 PR が壊される事故を防げる

#### Acceptance Criteria

1. While `auto-dev` ラベルが付与された Issue に `needs-iteration` ラベルも同時に付与されている, the Issue Watcher shall その Issue を本サイクルの処理対象から除外する
2. When 対象 Issue が `needs-iteration` だけを理由に除外された, the Issue Watcher shall 対象なしと同等のログ（"処理対象の Issue なし" もしくは件数 0 のサイクルログ）を残し、追加のエラー扱いはしない
3. While `auto-dev` ラベルが付与された Issue に `needs-iteration` が付いていない（従来どおりの状態）, the Issue Watcher shall 既存の除外ラベル（`needs-decisions` / `awaiting-design-review` / `claude-picked-up` / `ready-for-review` / `claude-failed`）の判定ロジックを変更せず、従来と同一の pickup 挙動を維持する
4. If 人間が `needs-iteration` を Issue から手動で除去した, the Issue Watcher shall 次サイクル以降、当該 Issue を通常の候補として再評価する

### Requirement 2: ラベル定義での「適用先」明示

**Objective:** As an idd-claude を導入したリポジトリの利用者, I want GitHub のラベル一覧画面で各ラベルが PR 用か Issue 用かを description から読み取れること, so that レビュワーがラベルを付ける時点で誤った対象（Issue / PR）に貼るリスクが下がる

#### Acceptance Criteria

1. The Label Setup Script shall PR 専用ラベル（少なくとも `needs-iteration`, `needs-rebase`）の description 文字列に「PR 用」であることを明示する prefix を含める
2. The Label Setup Script shall Issue 専用ラベル（少なくとも `auto-dev`, `needs-decisions`, `awaiting-design-review`, `claude-picked-up`, `ready-for-review`, `claude-failed`, `skip-triage`）の description 文字列に「Issue 用」であることを明示する prefix を含める
3. The Label Setup Script shall 各ラベルの description が GitHub のラベル description 上限（100 文字）を超えないこと
4. When 利用者が `--force` 付きで Label Setup Script を再実行した, the Label Setup Script shall 既存ラベルの description を新しい「適用先」prefix 付き description に更新する
5. The Label Setup Script shall ラベルの **name** および **color** を本要件によって変更しない（既存運用の互換性維持）

### Requirement 3: README の「ラベル状態遷移まとめ」での適用先明示

**Objective:** As an idd-claude を新規セットアップする運用者, I want README のラベル一覧から各ラベルの適用先（Issue / PR）が一目で読み取れること, so that ローカル運用ルールを書く際に誤った対象にラベルを付ける運用を防げる

#### Acceptance Criteria

1. The README shall 「ラベル状態遷移まとめ」のラベル一覧で、各ラベルの適用先（Issue / PR / 両方のいずれか）を読み取れる形式（列追加 / 別表分割 / 注釈付与のいずれか）で記載する
2. The README shall 少なくとも `needs-iteration`, `needs-rebase` を **PR 適用** として明示する
3. The README shall 少なくとも `auto-dev`, `needs-decisions`, `awaiting-design-review`, `claude-picked-up`, `ready-for-review`, `claude-failed`, `skip-triage` を **Issue 適用** として明示する
4. The README shall 既存の「意味」「付与主」情報を本要件によって削除しない（追記・列追加・分割いずれの方式でも既存情報は保つ）

### Requirement 4: PjM エージェント PR コメントでのラベル付与先誘導

**Objective:** As 設計 PR / 実装 PR の作成主, I want PjM エージェントが投稿する PR 案内コメントに「レビュー反復用ラベルは PR に付ける」旨が明記されていること, so that 受け取った人間がラベルを Issue に貼る誤操作を起こしにくくなる

#### Acceptance Criteria

1. When PjM エージェントが design-review モードで設計 PR の案内コメントを Issue に投稿する, the PjM Agent shall 「レビュー反復を回す場合は **この PR に** `needs-iteration` ラベルを付与する（Issue ではない）」旨を案内文に含める
2. When PjM エージェントが implementation モードで実装 PR の案内コメントを Issue に投稿する, the PjM Agent shall 「レビュー反復を回す場合は **この PR に** `needs-iteration` ラベルを付与する（Issue ではない）」旨を案内文に含める
3. The PjM Agent Template shall 上記 1, 2 の文言を、root（`.claude/agents/project-manager.md`）と template（`repo-template/.claude/agents/project-manager.md`）の双方で同等に記載する
4. The PjM Agent Template shall 既存の案内項目（merge 手順 / やり直し手順 / `awaiting-design-review` ラベル除去誘導 等）を本要件によって削除しない

### Requirement 5: 3 層防御の整合性

**Objective:** As an idd-claude メンテナ, I want コード防御・ラベル description・README・PjM テンプレの 4 箇所が同じ「`needs-iteration` は PR 専用」という主張に整合していること, so that 一部だけ更新されて運用ガイドが分裂する状況を防げる

#### Acceptance Criteria

1. The Documentation Set shall ラベル description の prefix（Req 2）、README の適用先表記（Req 3）、PjM テンプレの誘導文（Req 4）のいずれにおいても、`needs-iteration` を **PR 適用** として一貫して扱う
2. While `needs-iteration` ラベルが Issue 側に付与された誤運用シナリオ, the Issue Watcher shall その Issue を impl 系モード（impl / impl-resume）の対象として起動しない（Req 1 を満たしつつ、Documentation Set との主張矛盾が無いこと）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 既存環境変数名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `LABEL_NEEDS_ITERATION` 等）の名称・意味・既定値を本変更で変更しない
2. The Issue Watcher shall 本変更後も既存 cron / launchd 登録文字列（`issue-watcher.sh` の起動コマンド）を変更不要のまま維持する
3. The Issue Watcher shall 本変更後も既存のラベル遷移契約（`auto-dev` → `claude-picked-up` → `ready-for-review` / `claude-failed` 等）を変更しない（本要件は除外条件を 1 つ追加するのみで、遷移先・付与主・removal 主の責務は変えない）
4. The Label Setup Script shall ラベル名そのもの（`needs-iteration`, `auto-dev` 等）と色を本変更で変更せず、既存リポジトリで `--force` を付けずに再実行した場合は description 差分があっても既存ラベルを上書きしない（既存挙動の維持）
5. The PjM Agent Template shall 既存テンプレ参照箇所（PR 本文テンプレの構造 / コメント文言の固定 phrase）の API 互換性を破らない範囲で文言追記のみを行う

### NFR 2: 静的解析クリーン

1. The Modified Shell Script shall `shellcheck` を警告ゼロで通過する（`local-watcher/bin/issue-watcher.sh`, `.github/scripts/idd-claude-labels.sh` を含む）

### NFR 3: ドキュメント二重管理整合

1. While `local-watcher/bin/issue-watcher.sh` の Issue 取得クエリを変更した, the Documentation Set shall README のラベル状態遷移まとめ・ポーリングクエリ例の記述と整合した状態に更新される（querying ロジックと README が乖離しない）

### NFR 4: 検証可能性

1. The Defense Mechanism shall 「Issue に `needs-iteration` を誤付与し `ready-for-review` を除去した状態で watcher を 1 サイクル動かしても、当該 Issue が pickup されない」ことを手動スモークテストで確認できる手順が PR 本文の Test plan に記載される

## Out of Scope

- ラベルの **名前**・**色** そのものの変更
- GitHub API レベル（ラベル種別・スコープ）でラベル適用先を強制する仕組み
- PR 用ラベルが Issue に誤付与された際の自動修正・自動通知（YAGNI）
- PR Iteration Processor 自体の挙動変更（成功時遷移先・round 上限など）
- `claude-claimed` 系ラベルの分割（Issue #52 で別扱い）
- 既存の `needs-iteration` 誤付与履歴の自動マイグレーション（人間が手動で剥がす想定）

## Open Questions

- README の「ラベル状態遷移まとめ」のフォーマット（既存表に「適用先」列を追加するか、PR 用と Issue 用で表自体を分割するか）。要件としては「適用先が読み取れること」までで、設計選択は Architect / Developer に委ねる
- ラベル description は GitHub の 100 文字制限がある。「【PR 用】」のような prefix を付与した結果、既存の日本語 description が 100 文字を超えるラベルがある場合、description 本文を短縮するか prefix 表現を簡素化するかの判断が必要（短縮可否は Architect / Developer 段階で文字数を実測してから決定）
- PjM の PR 案内コメントが冗長化する懸念。既存案内（merge 手順 / やり直し手順）と並記する位置・トーン（補足注として置くか、独立行として置くか）は Developer の文言調整に委ねる
