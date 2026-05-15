# Requirements Document

## Introduction

idd-claude の watcher は Issue #104 / PR #105 で Stage C 完了時に PR の実在を verify する
仕組みを導入したが、その手前段である Stage A（Developer）・Stage A'（Developer 再実行）・
Stage B（Reviewer）・Stage C（PjM）の各完了処理には「ローカルに commit したが origin に
push していない」状態を検知する経路が無い。

実際に hitoshiichikawa/KeyNest #29 では Stage A / A' / B 完走後に Stage C で PjM が rate limit
即死し、12 commits + review-notes 1 commit が slot worktree にローカル滞留したまま watcher は
「Stage C 完了 / PR 作成済み」と虚偽報告した。hitoshiichikawa/idd-claude #104 でも Stage A 完了
時点で 4 commits が origin に未到達のまま Stage B（Reviewer）が走り、結果として後続 stage の
意思決定対象がローカルにしか存在しない事象が観測されている。

本要件は、各 stage 完了直後に「ローカル HEAD が upstream より進んでいないか」を verify し、
進んでいた場合は自動 push リトライを 1 回試みた上で、成否にかかわらず WARN ログと Issue
コメントで観測可能性を維持する経路を導入することをスコープとする。Stage 別の policy 詳細
（Stage B での扱い、Issue コメントの単独化粒度など）は Open Questions に残す。

## Requirements

### Requirement 1: Stage A 完了直後の push 状態 verify

**Objective:** As a watcher 運用者, I want Stage A（Developer）の Claude 実行が成功扱いで
終了した直後にローカル commit が origin に到達済みであることを verify したい, so that
Reviewer 起動時に origin と worktree の乖離による silent failure を防げる

#### Acceptance Criteria

1. When Stage A の Claude 実行が成功扱い（既存判定で完了とみなされる経路）で終了したとき, the Stage A Pipeline shall 完了宣言の前にローカル HEAD が当該ブランチの upstream より進んでいないかを verify する
2. If Stage A 完了時にローカル HEAD が upstream より進んでいることが検出された場合, the Stage A Pipeline shall 進んでいる commit 数と検出根拠を WARN レベルで `$LOG` に記録する
3. If Stage A 完了時にローカル HEAD が upstream に到達済み（ahead == 0）と確認できた場合, the Stage A Pipeline shall 従来どおりの成功メッセージを出力し、追加の副作用を発生させない
4. If Stage A 完了時の push 状態 verify 自体が一時的な原因（タイムアウト・git コマンド失敗等）で結果を確定できなかった場合, the Stage A Pipeline shall 安全側（未 push と同等扱い）に倒し、判定不能となった事象を `$LOG` に記録する

### Requirement 2: Stage A' 完了直後の push 状態 verify

**Objective:** As a watcher 運用者, I want Stage A'（Reviewer reject 差し戻しでの Developer
再実行）完了直後も Stage A と同等の push 状態 verify を行いたい, so that 再実行で追加された
commit が origin に届かないまま Round 2 Reviewer に渡ることを防げる

#### Acceptance Criteria

1. When Stage A' の Claude 実行が成功扱いで終了したとき, the Stage A' Pipeline shall 完了宣言の前にローカル HEAD が upstream より進んでいないかを verify する
2. If Stage A' 完了時にローカル HEAD が upstream より進んでいることが検出された場合, the Stage A' Pipeline shall 進んでいる commit 数と検出根拠を WARN レベルで `$LOG` に記録する
3. If Stage A' 完了時にローカル HEAD が upstream に到達済み（ahead == 0）と確認できた場合, the Stage A' Pipeline shall 従来どおりの成功メッセージを出力し、追加の副作用を発生させない

### Requirement 3: Stage B 完了直後の push 状態 verify

**Objective:** As a watcher 運用者, I want Stage B（Reviewer）完了直後も push 状態を verify
したい, so that Reviewer が `review-notes.md` を commit したまま push し損ねるケース・既存の
Stage A 由来 commit が依然未 push のままであるケースのいずれも後続 stage に持ち越さない

#### Acceptance Criteria

1. When Stage B の Claude 実行が成功扱い（reject / approve いずれも含む）で終了したとき, the Stage B Pipeline shall 完了宣言の前にローカル HEAD が upstream より進んでいないかを verify する
2. If Stage B 完了時にローカル HEAD が upstream より進んでいることが検出された場合, the Stage B Pipeline shall 進んでいる commit 数と検出根拠を WARN レベルで `$LOG` に記録する
3. If Stage B 完了時にローカル HEAD が upstream に到達済み（ahead == 0）と確認できた場合, the Stage B Pipeline shall 従来どおりの成功メッセージを出力し、追加の副作用を発生させない
4. Where Stage B が `review-notes.md` を Reviewer 出力として記録する役割を持つ場合, the Stage B Pipeline shall ahead > 0 検出時に「`review-notes.md` が origin に到達していない可能性」を識別可能なログ粒度で記録する

### Requirement 4: 自動 push リトライと観測可能性の維持

**Objective:** As a watcher 運用者, I want 未 push が検出された stage で自動 push を 1 回だけ
リトライしたい。ただし transient な失敗を黙って隠蔽せず、リトライ成功時にも WARN と Issue
コメントで通知することで、Developer / Reviewer サブエージェントの push 漏れ等の根本原因を
追跡可能なままにしたい, so that 「自動復旧して何も起こらなかった」状態を作らずに済む

#### Acceptance Criteria

1. If 任意の stage（A / A' / B）の完了 verify で ahead > 0 が検出された場合, the Stage Pipeline shall 当該 worktree から対象ブランチへの push を 1 回だけ自動でリトライする
2. When 自動 push リトライが成功（ahead == 0 に到達）したとき, the Stage Pipeline shall stage 進行を継続し、リトライが発火した事実・対象 stage・commit 数を WARN レベルで `$LOG` に記録する
3. When 自動 push リトライが成功したとき, the Stage Pipeline shall 当該 Issue に「自動 push リトライで復旧した」旨を識別可能な内容で 1 件以上の Issue コメントとして通知する
4. If 自動 push リトライが失敗した場合, the Stage Pipeline shall 当該 Issue を `claude-failed` として `mark_issue_failed` 経路で扱い、対応する stage 識別子（例: stageA / stageA-prime / stageB に相当する識別子）と未 push の根拠を渡す
5. If 自動 push リトライが失敗した場合, the Stage Pipeline shall 虚偽の成功メッセージ（「Stage X 完了」相当の正常完了ログ）を出力しない
6. The Stage Pipeline shall 自動 push リトライ回数を 1 回上限とし、無限リトライによる side effect 増殖を起こさない

### Requirement 5: 通常成功ケースでの後方互換性

**Objective:** As a watcher 運用者, I want push が成功している通常ケースで watcher の挙動が
本変更前後で観察可能な範囲で同一であってほしい, so that 既稼働の cron / launchd を壊さずに
新検出経路を有効化できる

#### Acceptance Criteria

1. While 各 stage 完了時にローカル HEAD が upstream に到達済み（ahead == 0）である場合, the Stage Pipeline shall 完了ログ・終了コード・ラベル遷移・Issue コメントの可観測な出力を本変更前と同一に保つ
2. The Stage Pipeline shall 既存の env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）と既存の stage 終了コードの意味（0 = 成功 / 99 = quota 検出 / それ以外 = 既存失敗）を変更しない
3. The Stage Pipeline shall 既存ラベル（`claude-picked-up` / `claude-failed` / `needs-quota-wait` 等）の遷移契約を変更しない

### Requirement 6: テストフィクスチャとリグレッションテスト

**Objective:** As a watcher 開発者, I want 「push 漏れ検出 → 自動 push 成功」「push 漏れ検出
→ 自動 push 失敗 → `claude-failed`」「ahead == 0 通常成功」の 3 経路を再現するテストを保持
したい, so that 将来の改修で同種リグレッションが入った際に早期検知できる

#### Acceptance Criteria

1. The Test Suite shall 「stage 完了時に ahead > 0 を検出し、自動 push リトライが成功して継続する」経路を再現するテストを `local-watcher/test/` 配下に保持する
2. The Test Suite shall 「stage 完了時に ahead > 0 を検出し、自動 push リトライが失敗して `claude-failed` 化する」経路を再現するテストを `local-watcher/test/` 配下に保持する
3. The Test Suite shall 「stage 完了時に ahead == 0 で通常成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
4. The Test Suite shall 上記テストを外部ネットワーク呼び出し（GitHub API / 実 origin への push）なしで実行できる形（fake コマンドまたはローカル bare repo 等の擬似環境）で構成する
5. The Test Suite shall 既存の `local-watcher/test/` 配下テスト群（`parse_review_result_test.sh` / `qa_detect_rate_limit_test.sh` / `stagec_pr_verify_test.sh` / `qa_run_claude_stage_test.sh` ほか）が本変更後も pass し続ける

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. While 通常成功ケース（ahead == 0）である場合, the Stage Pipeline shall verify 1 回あたりの追加レイテンシを 1 秒以内に収める（典型的なローカル git クエリの応答時間に閉じる前提）
2. The Stage Pipeline shall verify 用 git クエリ自体にタイムアウト上限（30 秒以内）を設け、ハング時にも stage 全体を無限待機させない

### NFR 2: 観測可能性

1. When 未 push 検出または自動 push リトライが発火したとき, the Stage Pipeline shall 検出経路（stage 識別子）・ahead 数値・リトライ結果を `$LOG` から事後に識別可能な単一行（または連続する複数行）として記録する
2. When 自動 push リトライ成功による Issue コメントが投稿されたとき, the Stage Pipeline shall コメント本文に Issue 番号・対象 stage 識別子・対象ブランチ・復旧した commit 数を含める
3. If 自動 push リトライ失敗で `claude-failed` 化が発生した場合, the Stage Pipeline shall 人間が原因を特定できる粒度（Issue 番号・対象 stage 識別子・対象ブランチ・未 push commit 数・push 失敗時の git エラー要約）でログを残す

### NFR 3: 後方互換性とロールアウト安全性

1. The Stage Pipeline shall 既存の cron / launchd 登録文字列・配置先パス（`~/bin/issue-watcher.sh`）・依存 CLI（`gh` / `jq` / `flock` / `git`）の前提を変更しない
2. The Stage Pipeline shall self-hosting 環境（idd-claude 自身を対象 repo として運用する dogfooding 経路）でも本変更が有効であり、既存稼働 watcher と非互換な状態を生まない

## Out of Scope

- Stage C（PjM）完了時の PR 実在 verify そのものの改修（Issue #104 / PR #105 で実装済み。
  ただし Stage C 完了直前の push 状態 verify が必要となる場合は別途切り出す）
- Developer / Reviewer / PjM サブエージェントのプロンプト本文の改修
  （Issue #106 本文「追加で検討したい再発防止策 1.」は別途切り出す）
- `qa_run_claude_stage` 共通 hook への post-condition 一本化リファクタ
  （Issue #106 本文「追加で検討したい再発防止策 2.」は別途切り出す）
- `_slot_run_issue` 終了直前の最終 sanity check の追加
  （Issue #106 本文「追加で検討したい再発防止策 3.」は別途切り出す）
- 自動リトライ回数を 2 回以上に拡張する変更 / リトライ間隔のチューニング機構
- GitHub Actions 経路（`.github/workflows/issue-to-pr.yml`、`IDD_CLAUDE_USE_ACTIONS=true` opt-in）
  への同等検出機構の移植
- Stage Checkpoint Resume（#68, `STAGE_CHECKPOINT_ENABLED=true`）固有の resume 経路に
  対する追加 verify 拡張
- 観測対象を `git rev-list --count @{u}..HEAD` 以外の指標（例: 個別ファイルの tracked 状態）に
  広げる変更
- 自動 push 失敗時の Issue コメント投稿（失敗時は `claude-failed` ラベル + log のみで通知し、
  人間運用に委ねる）

## Open Questions

- 自動 push リトライ成功時の Issue コメント通知について、Stage A / A' / B それぞれで個別に
  コメントを投稿するのか、`_slot_run_issue` 単位でまとめて 1 件に集約するのか（運用ノイズの
  許容度に依存する判断。本要件では「1 件以上」のみ規定し詳細は design 委ね）
- Stage B（Reviewer）は本来 commit を作らない設計だが、`review-notes.md` を Reviewer が
  commit する設計上の取り決めが現行スクリプトで保証されているかは Architect 側で確認したい
  （Issue #106 本文では「PjM が commit する」と「Reviewer 単体では commit しない」の両方の
  記述があり、本要件では「Stage B 完了時に ahead > 0 になり得る」前提で verify 経路を設けて
  いる）
- 自動 push リトライ時の push オプション（`--force-with-lease` 系を使うか、plain `push` の
  fast-forward のみに限るか）は実装ポリシーとして design 側で確定したい。本要件では
  「ahead == 0 に到達すれば成功」とのみ規定する
- `mark_issue_failed` に渡す stage 識別子文字列（`stageA-push-missing` 系の命名）は既存
  `stageC-pr-missing` との一貫性を見て design / 実装側で確定したい
