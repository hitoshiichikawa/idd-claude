# Requirements Document

## Introduction

idd-claude の watcher は Issue #104 / PR #105 で Stage C 完了直後に「PjM が PR を実際に作成したか」を
GitHub から問い合わせて verify する経路を導入した。しかしこの verify は GitHub 側の整合性遅延（eventual
consistency）を考慮しておらず、PjM が PR を正常に作成した直後でも一定確率で「PR が見つからない」と判定
されて `claude-failed` 化する事象が観測されている。実例として、PR 作成から 25 秒後の verify で対象ブランチ
に紐づく PR が検出されず、実際には GitHub 上に当該 PR が存在していたケースが報告されている。

原因は、対象ブランチを head に持つ PR を一覧／取得するクエリ系エンドポイントが、新規作成された PR を
直後数十秒〜数分で確実にヒットさせる保証を持たないためである。Stage C verify は PjM 完了から数十秒以内
に実行されるため、この遅延ウィンドウに入りやすい。

本要件は、Stage C 完了直後の PR 実在 verify を **retry-with-backoff** によりリトライ可能化し、整合性遅延
に起因する false negative を実用的な確率で吸収しつつ、PR が真に作成されていないケース（PjM 空転）も合計
35 秒以内に `claude-failed` 化して既存運用と矛盾しないようにする。スコープは `local-watcher/bin/issue-watcher.sh`
の Stage C verify 区間に限定し、Stage A 系の push verify（Issue #106 で対応済み）には影響を与えない。

## Requirements

### Requirement 1: Stage C PR verify の retry-with-backoff 化

**Objective:** As a watcher 運用者, I want Stage C 完了直後の PR 実在 verify を一定回数までリトライしたい,
so that GitHub 側の整合性遅延に起因する false negative を実用的な確率で吸収できる

#### Acceptance Criteria

1. When Stage C の Claude 実行が成功扱いで終了したとき, the Stage C Verify Pipeline shall 対象ブランチに紐づく PR が GitHub 側で参照可能になるまで最大 4 回まで取得を試行する
2. When 1 回目の PR 取得試行で対象ブランチに紐づく PR が確認できたとき, the Stage C Verify Pipeline shall 追加のリトライを行わず即時に成功扱いで継続する
3. When N 回目（N >= 2）の PR 取得試行で初めて PR が確認できたとき, the Stage C Verify Pipeline shall 残りのリトライを行わずに成功扱いで継続する
4. The Stage C Verify Pipeline shall 各リトライ試行の間に段階的な待機（即時 / 5 秒 / 10 秒 / 20 秒）を挿入し、リトライ系列全体の合計待機時間を 35 秒以内に収める
5. The Stage C Verify Pipeline shall 1 回の PR 取得試行あたりの待ち時間に 15 秒のタイムアウト上限を設け、単一試行のハングがリトライ系列全体を無限に止めることを防ぐ
6. The Stage C Verify Pipeline shall 自動リトライ上限を 4 回とし、無限リトライによる副作用増殖を起こさない

### Requirement 2: 真正な失敗ケースでの確定挙動

**Objective:** As a watcher 運用者, I want PjM が PR を 1 件も作成しないまま空転終了した場合でも、リトライ
系列を抜けたあと現行と同等の `claude-failed` 化が確実に走ってほしい, so that PR が永続的に作成されないバグ
が長時間検知されないまま放置されることを防げる

#### Acceptance Criteria

1. If 4 回すべてのリトライ試行で対象ブランチに紐づく PR が確認できなかった場合, the Stage C Verify Pipeline shall 当該 Issue を既存の `stageC-pr-missing` 識別子で `claude-failed` 化する
2. If 全リトライ失敗で `claude-failed` 化が発生した場合, the Stage C Verify Pipeline shall 「Stage C 完了 / PR 作成済み」相当の成功ログを出力しない
3. While リトライ系列が進行している間 the Stage C Verify Pipeline shall リトライ系列全体に費やす時間を Stage C 完了通知から起算して 35 秒以内に収める
4. If 個々のリトライ試行が一時的な失敗（タイムアウト・コマンド非 0 終了・空応答）で終わった場合, the Stage C Verify Pipeline shall 当該試行は失敗扱いとしつつ次の試行まで打ち切らず、上限回数まで継続する

### Requirement 3: 観測可能性とログ粒度

**Objective:** As a watcher 運用者, I want リトライ系列の進捗を $LOG から事後に再構成したい, so that
false negative の頻度や整合性遅延の典型分布を把握し、将来のリトライ回数チューニング判断ができる

#### Acceptance Criteria

1. When N 回目（N >= 2）のリトライ試行が走るとき, the Stage C Verify Pipeline shall 試行回数・対象 Issue 番号・対象ブランチを識別可能な単一行を `$LOG` に記録する
2. When リトライの末に PR が確認できたとき, the Stage C Verify Pipeline shall 成功までに要した試行回数を `$LOG` から事後に識別できる粒度で記録する
3. If 全リトライ失敗で `claude-failed` 化が発生した場合, the Stage C Verify Pipeline shall Issue 番号・対象ブランチ・試行回数・最終試行の失敗要因を人間が原因特定できる粒度で `$LOG` に記録する
4. When 1 回目の試行で即時に PR が確認できたとき, the Stage C Verify Pipeline shall 本変更前と同じ「Stage C 完了 / PR 作成済み」相当の成功ログを出力する

### Requirement 4: 既存挙動の後方互換性

**Objective:** As a watcher 運用者, I want 通常成功ケース（1 回目で PR が確認できるケース）で watcher の
外形挙動が本変更前後で観察可能な範囲で同一であってほしい, so that 既稼働の cron / launchd を壊さずに
リトライ経路を有効化できる

#### Acceptance Criteria

1. While 1 回目のリトライ試行で PR が確認できる場合, the Stage C Verify Pipeline shall 終了コード・ラベル遷移・Issue コメント・成功ログの外形を本変更前と同一に保つ
2. The Stage C Verify Pipeline shall 既存の env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）と stage 終了コードの意味（0 = 成功 / 99 = quota 検出 / それ以外 = 既存失敗）を変更しない
3. The Stage C Verify Pipeline shall 既存ラベル（`claude-picked-up` / `claude-failed` / `needs-quota-wait` 等）の遷移契約を変更しない
4. The Stage C Verify Pipeline shall 既存の `stageC-pr-missing` 識別子文字列を `claude-failed` 化の根拠コードとして引き続き使用する
5. The Stage C Verify Pipeline shall Stage A / Stage A' / Stage B 完了直後の push 状態 verify（Issue #106 で導入）の挙動を変更しない

### Requirement 5: テストカバレッジ

**Objective:** As a watcher 開発者, I want 「1 回目で成功」「途中試行で初めて成功」「全試行失敗」の 3 経路を
再現するテストを保持したい, so that 将来の改修で同種リグレッションが入った際に早期検知できる

#### Acceptance Criteria

1. The Test Suite shall 「1 回目の試行で PR が確認できて即時成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
2. The Test Suite shall 「1 回目は空応答、2 回目以降の試行で初めて PR が確認できて成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
3. The Test Suite shall 「全試行で PR が確認できず `claude-failed` 化する」経路を再現するテストを `local-watcher/test/` 配下に保持する
4. The Test Suite shall 既存の `stagec_pr_verify_test.sh` の全テストケースが本変更後も pass し続ける
5. The Test Suite shall 上記テストを外部ネットワーク呼び出し（実 GitHub API 通信）なしで実行できる形（fake コマンドによる挙動差し替え等の擬似環境）で構成する
6. The Test Suite shall リトライ間の待機を実時間で消化せず、テスト 1 件あたりの所要時間を 30 秒以内に収められる構成を取る

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. While 1 回目の試行で PR が確認できる通常成功ケースである場合, the Stage C Verify Pipeline shall verify 全体の追加レイテンシを本変更前から 1 秒以内の増分に収める
2. The Stage C Verify Pipeline shall リトライ系列全体に費やす時間を Stage C 完了通知から起算して 35 秒以内に収める
3. The Stage C Verify Pipeline shall 1 回の PR 取得試行を 15 秒以内に強制終了するタイムアウト上限を持つ

### NFR 2: 観測可能性

1. When リトライ系列の任意の試行が完了したとき, the Stage C Verify Pipeline shall 当該試行の結果（成功 / 空応答 / 非 0 終了 / タイムアウト）を `$LOG` から事後に識別可能な形で残す
2. The Stage C Verify Pipeline shall リトライ系列の全試行ログを単一 Issue / 単一 watcher run のスコープで突合できる識別子（Issue 番号・対象ブランチ）と併せて出力する

### NFR 3: 後方互換性とロールアウト安全性

1. The Stage C Verify Pipeline shall 既存の cron / launchd 登録文字列・配置先パス（`~/bin/issue-watcher.sh`）・依存 CLI（`gh` / `jq` / `flock` / `git` / `timeout`）の前提を変更しない
2. The Stage C Verify Pipeline shall self-hosting 環境（idd-claude 自身を対象 repo として運用する dogfooding 経路）でも本変更が有効であり、既存稼働 watcher と非互換な状態を生まない

## Out of Scope

- Stage C の PR 取得を REST 系から GraphQL 系へ切り替える代替案（Issue 本文では「当面は retry-with-backoff が安全側」と整理されているため別 Issue 切り出し）
- Stage A / Stage A' / Stage B 完了直後の push 状態 verify への改修（Issue #106 で対応済みであり、本要件は Stage C verify に限定）
- リトライ回数を 4 回より多く拡張する変更 / 待機スケジュール（即時 / 5 秒 / 10 秒 / 20 秒）の動的チューニング機構
- リトライ系列に費やす時間上限（35 秒）を超える長時間待機モード
- Stage C 完了直前の push 状態 verify の追加（Issue #106 Out of Scope を踏襲）
- PjM サブエージェントのプロンプト改修による「PR 未作成のまま空転終了する」根本原因の解消
- GitHub Actions 経路（`.github/workflows/issue-to-pr.yml`、`IDD_CLAUDE_USE_ACTIONS=true` opt-in）への同等リトライ機構の移植
- リトライ系列途中での Issue コメント通知（リトライ進捗は `$LOG` のみで観測し、ノイズ抑制のため Issue 側には出さない）

## Open Questions

- リトライ待機スケジュール（即時 / 5 秒 / 10 秒 / 20 秒、合計 35 秒）は Issue 本文の提案値をそのまま採用しているが、将来の運用観測で典型遅延が大きく外れた場合の見直し閾値は本要件では規定しない
- 「対象ブランチに紐づく PR」を取得する具体的なクエリ手段（既存実装は `gh pr view --head` 系）は design / 実装側で確定する。本要件では「対象ブランチに紐づく PR が GitHub 側で参照可能か」の判定結果のみを規定する
- リトライ成功時に「N 回目で成功した」事実を Issue コメントとして通知するかは本要件では「不要」（Out of Scope 参照）としているが、将来 false negative 発生率の運用観測のために Issue コメント化に切り替える可能性がある（その場合は別 Issue で再要件化）
