# Requirements Document

## Introduction

idd-claude の watcher セッションが異常終了（クラッシュ / OOM / ハング強制 kill / マシン再起動）
すると、処理中だった Issue が `claude-picked-up` または `claude-claimed` ラベルのまま取り残される。
dispatcher はこれらのラベル付き Issue を「処理中」とみなして候補から除外するため、復旧手段が
人間によるラベル手動除去のみとなり、無期限停止につながる（実例: #374 が約 2.7 時間放置）。
本機能 Stale Pickup Reaper は、アクティブな処理セッションが存在しないまま閾値を超えて
pickup 系ラベルが滞留している Issue を検出し、`claude-picked-up` / `claude-claimed` を除去して
`auto-dev` 状態へ復帰させ、次サイクルでの再 pickup（`IMPL_RESUME_PRESERVE_COMMITS` による
impl-resume 続行）を可能にする。failed-recovery（#359）が `claude-failed` のみを対象とする
gap を埋める位置づけであり、opt-in gate（既定 OFF）下でのみ起動して既存挙動を保つ。

## Requirements

### Requirement 1: Stale Pickup Reaper の起動制御

**Objective:** As a idd-claude 運用者, I want Stale Pickup Reaper を明示的 opt-in でのみ起動させる, so that 既定運用では本機能導入前と同一の挙動を維持し、誤検出による二重処理リスクを排除できる

#### Acceptance Criteria

1. Where `STALE_PICKUP_REAPER_ENABLED=true` が成立する, the Stale Pickup Reaper shall 通常の watcher サイクル内で起動する
2. If `STALE_PICKUP_REAPER_ENABLED` が未設定または `true` 以外の値である, the Stale Pickup Reaper shall 起動せず、対象 Issue への副作用を行わない
3. If `STALE_PICKUP_REAPER_ENABLED` の値が `true` / `false` 以外の文字列（typo / 不正値）である, the Stale Pickup Reaper shall 安全側（無効）として扱い起動しない
4. While `STALE_PICKUP_REAPER_ENABLED` が無効である, the watcher shall 本機能導入前と完全に同一の外部挙動（Issue / PR への副作用なし）を保つ

### Requirement 2: 復旧対象の選定

**Objective:** As a Stale Pickup Reaper, I want 復旧対象となる Issue を明確に定義する, so that 他 Processor の領分と衝突せず、正当な待機状態の Issue を誤って revert しない

#### Acceptance Criteria

1. When watcher サイクルが Stale Pickup Reaper を起動した, the Stale Pickup Reaper shall `claude-picked-up` ラベル付き Issue を復旧候補として走査する
2. When watcher サイクルが Stale Pickup Reaper を起動した, the Stale Pickup Reaper shall `claude-claimed` ラベル付き Issue を復旧候補として走査する
3. If 対象 Issue が `needs-decisions` / `awaiting-design-review` / `needs-quota-wait` / `blocked` / `hold` 等の人間判断待ち・正当な待機状態を示すラベルを持つ, the Stale Pickup Reaper shall 当該 Issue を復旧候補から除外する
4. If 対象 Issue が `claude-failed` ラベルを持つ, the Stale Pickup Reaper shall 当該 Issue を復旧候補から除外する（failed-recovery / #359 の領分）
5. The Stale Pickup Reaper shall 対象 Issue の選定走査自体を `gh` API のラベル絞り込みで行い、走査対象でない Issue へ副作用を発生させない

### Requirement 3: アクティブセッション判定（誤検出防止）

**Objective:** As a Stale Pickup Reaper, I want アクティブな処理セッションが存在する Issue を絶対に revert しない, so that 二重処理 / branch 競合 / 進行中作業の喪失を防ぐ

#### Acceptance Criteria

1. When 復旧候補 Issue のアクティブ判定を行う, the Stale Pickup Reaper shall 「claim 時に付与されたタイムスタンプ marker の経過時間が閾値超」「対応する slot ロックが保持されていない」「対応する watcher セッションが存在しない」の 3 観点すべてが「非アクティブ」を示す場合に限り当該 Issue を非アクティブと判定する
2. If 上記 3 観点のいずれか 1 つでも「アクティブの可能性あり」を示す, the Stale Pickup Reaper shall 当該 Issue を非アクティブと判定せず、復旧アクションを行わない
3. While アクティブ判定を実行している, the Stale Pickup Reaper shall 判定対象 Issue へラベル変更・コメント投稿・branch 操作などの副作用を行わない
4. If アクティブ判定の根拠データ（タイムスタンプ marker / slot ロック情報 / セッション情報）の取得自体に失敗した, the Stale Pickup Reaper shall 当該 Issue を「アクティブの可能性あり」として扱い、復旧アクションを行わない
5. The Stale Pickup Reaper shall アクティブ判定の根拠（経過時間 / ロック保持有無 / セッション有無）の判定結果を 1 行ログとして記録する

### Requirement 4: 閾値とその設定

**Objective:** As a idd-claude 運用者, I want pickup 系ラベル滞留の許容時間を env で調整できる, so that watcher サイクル間隔・実装 Issue の典型実装時間との整合を運用側で取れる

#### Acceptance Criteria

1. The Stale Pickup Reaper shall 滞留閾値（分単位）を env（例 `STALE_PICKUP_REAPER_THRESHOLD_MINUTES`）で受け取り、既定値として 45 分を採用する
2. While 復旧候補 Issue の pickup 系ラベル付与からの経過時間が閾値未満である, the Stale Pickup Reaper shall 当該 Issue を非アクティブ判定の対象とせず、復旧アクションを行わない
3. If 閾値 env が未設定 / 非整数 / 0 以下の値である, the Stale Pickup Reaper shall 既定値 45 分を採用する
4. Where 閾値が有効な整数（分）として与えられた, the Stale Pickup Reaper shall その値を分単位の経過時間判定に用いる

### Requirement 5: 復旧アクションと状態遷移

**Objective:** As a Stale Pickup Reaper, I want 非アクティブと判定された Issue を `auto-dev` 状態へ復帰させる, so that 次の watcher サイクルで dispatcher が再 pickup し impl-resume が継続できる

#### Acceptance Criteria

1. When 復旧候補 Issue が非アクティブと判定された, the Stale Pickup Reaper shall 当該 Issue から `claude-picked-up` ラベルを除去する
2. When 復旧候補 Issue が非アクティブと判定された, the Stale Pickup Reaper shall 当該 Issue から `claude-claimed` ラベルを除去する
3. When 復旧アクションを実行した, the Stale Pickup Reaper shall 当該 Issue に `auto-dev` ラベルが残存していることを確認し、欠落していれば付与する
4. When 復旧アクションを実行した, the Stale Pickup Reaper shall 終端理由（stale-pickup orphan）と経過時間を含む 1 行ログをログ出力先へ記録する
5. The Stale Pickup Reaper shall 同一 Issue に対する復旧アクションを冪等に保ち、既に `auto-dev` 状態へ復帰済みの Issue を再対象化したときに副作用を二重に発生させない
6. If 復旧アクション中にラベル除去・付与が失敗した, the Stale Pickup Reaper shall 失敗内容をログへ記録し、当該 Issue の状態を中途半端に残さない（後続サイクルでの再評価が可能な状態に留める）

### Requirement 6: branch 不在時の扱い

**Objective:** As a Stale Pickup Reaper, I want 対応する impl branch が存在しない Issue でも安全に復旧できる, so that 後段の re-pickup フロー（impl-resume / 新規 impl）が破綻しない

#### Acceptance Criteria

1. When 復旧候補 Issue に対応する impl branch（例 `claude/issue-<番号>-*`）が存在しない, the Stale Pickup Reaper shall ラベル復旧を継続し、branch 不在を理由に処理を中断しない
2. When 復旧候補 Issue に対応する impl branch が存在しかつ非アクティブと判定された, the Stale Pickup Reaper shall branch を削除・改変せず、次サイクルの impl-resume が `IMPL_RESUME_PRESERVE_COMMITS` の規約に従って既存 branch から続行できる状態を保つ
3. The Stale Pickup Reaper shall branch 状態（存在 / 不在）を判定根拠として記録するが、branch 状態のみを理由に「アクティブ」と判定しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Stale Pickup Reaper shall 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `SLOT_LOCK_DIR` / `FULL_AUTO_ENABLED` 等）の名前・意味を変更しない
2. The Stale Pickup Reaper shall 既存ラベル名（`claude-picked-up` / `claude-claimed` / `auto-dev` / `needs-decisions` / `awaiting-design-review` / `needs-quota-wait` / `blocked` / `claude-failed`）の名前・付与契約を変更しない
3. While `STALE_PICKUP_REAPER_ENABLED=false` または未設定である, the watcher shall 本機能導入前と完全に同一の外部挙動（Issue / PR / branch / ログへの副作用なし）を保つ

### NFR 2: 冪等性と再起動耐性

1. The Stale Pickup Reaper shall 同一 Issue に対する同一サイクル内の重複起動を内部状態または外部ロックで防止する
2. While watcher プロセスが終了またはサイクル跨ぎで再起動した, the Stale Pickup Reaper shall 永続化済みの状態（タイムスタンプ marker / アクティブ判定根拠）を必要範囲で継承する
3. The Stale Pickup Reaper shall 永続化ファイルを `$HOME/.issue-watcher/` 配下に配置し、TOCTOU 安全な方法で読み書きする（`/tmp` 配下の予測可能名は使用しない）

### NFR 3: セキュリティ

1. The Stale Pickup Reaper shall Issue 番号・ラベル名・branch 名・コメント本文といった未信頼入力を `gh` / `git` / `jq` / `bash` 等へ渡すとき、quote / `--arg` `--argjson` / `--` 区切り / 数値 ID `^[0-9]+$` 検証・branch 名サニタイズを適用する
2. The Stale Pickup Reaper shall secrets を含む環境変数を Issue コメントおよびログへ出力しない

### NFR 4: 可観測性

1. When Stale Pickup Reaper が復旧候補の選定・アクティブ判定・復旧アクション・スキップ判定を行った, the Stale Pickup Reaper shall 該当イベント種別と Issue 番号を 1 行ログとしてログ出力先へ記録する
2. While アクティブ判定で「アクティブの可能性あり」と判定して復旧アクションを見送った場合, the Stale Pickup Reaper shall 見送り理由（どの観点でアクティブ判定したか）を 1 行ログとして記録する

### NFR 5: 静的解析と近接テスト

1. The Stale Pickup Reaper 配布物 shall `shellcheck` を警告ゼロ、`bash -n` をエラーなしでクリアする
2. The Stale Pickup Reaper shall 「orphan 検出 → 復旧アクション」「アクティブ Issue の非 revert」「同一 Issue への冪等な再適用」の 3 経路に対する近接テスト（`local-watcher/test/` 配下に stub ベースで配置）を備える

### NFR 6: テンプレート同期

1. The Stale Pickup Reaper 配布物（新規 env var の README 記載 / ラベルセット定義 / 関連スクリプト）shall root `.claude/` / root `local-watcher/` と `repo-template/` 配下の対応物で byte 一致または機能等価で同期される

## Out of Scope

- `claude-failed` ラベル付き Issue の自動復旧（#359 failed-recovery の責務）
- auto-merge 待ち PR の CI 失敗解析と修正試行（#359 failed-recovery の責務）
- 通算 attempt budget による終端管理（本機能は冪等な状態復帰のみを担い、attempt カウンタは持たない）
- `needs-decisions` / `awaiting-design-review` 等の正当な待機状態の Issue を自動継続させる挙動
- impl branch の自動削除 / rebase / push 操作
- watcher セッションのプロセス監視・自動再起動・ヘルスチェック機構
- Stale Pickup Reaper 内部の関数構成 / 公開 IF シグネチャ / 状態ファイル名・スキーマ詳細 / タイムスタンプ marker の付与方式（コメント / 状態ファイル / 別経路の選択は Architect の責務）
- Stale Pickup Reaper を `FULL_AUTO_ENABLED` 配下に置くか単独 gate で運用するかの判断（Architect の責務）

## Open Questions

- なし（Issue 本文・関連 Issue #359・既存 dispatcher のラベル運用契約から要件確定可能）

## 関連

- Related: #359
- Related: #374

## レビュー結果

- Mechanical Checks: numeric ID 階層 OK / 各要件に EARS 形式 AC を 1 件以上含む OK / 実装語彙の混入なし OK
- 判断レビュー: スコープ境界（failed-recovery / impl-resume / watcher セッション監視）を Out of Scope で明示、誤検出回避（Requirement 3）を最重要 AC として配置、後方互換（NFR 1）を確認 — 1 パスで確定
