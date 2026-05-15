# Requirements Document

## Introduction

idd-claude の watcher は Issue #108 / PR #109 で Stage C 完了直後の PR 実在 verify を retry-with-backoff
化し、即時 / 5 秒 / 10 秒 / 20 秒（合計 35 秒、最大 4 回）のリトライ系列で GitHub の eventual
consistency に起因する false negative を吸収する設計を導入した。しかし KeyNest #32（2026-05-15）の
実観測で、PR 作成から **73 秒経過後も対象ブランチを head に持つ PR を一覧／取得するクエリが空応答を返す**
edge cache lag が確認され、watcher は 4/4 試行すべて空応答で打ち切り、実際には PR が存在しているにも
かかわらず `claude-failed` を誤付与した。

原因は (a) 35 秒のリトライ合計待機が edge cache lag の上限を吸収しきれない点と、(b) 単一クエリ系
エンドポイント（`gh pr view --head` 系）の edge cache に張り付いた場合に代替経路への切り替え手段が
無い点である。本要件は、(1) リトライ合計待機を有意に延長すること、(2) リトライ系列の末尾で代替 API
経路（List Pulls API への直接アクセス）への fallback を 1 度だけ試みること、の 2 点で false negative を
さらに抑制する。スコープは `local-watcher/bin/issue-watcher.sh` の Stage C verify 区間に限定し、
Stage A 系 push verify（Issue #106 で対応済み）には影響を与えない。既存 env var 名・ラベル名・exit code・
`stageC-pr-missing` 識別子は維持する。

## Requirements

### Requirement 1: リトライ合計待機の延長

**Objective:** As a watcher 運用者, I want Stage C PR verify のリトライ合計待機を 35 秒から有意に延長したい,
so that 73 秒以上の edge cache lag が観測される実運用ケースで false negative が `claude-failed` 誤付与に
直結しないようにできる

#### Acceptance Criteria

1. The Stage C Verify Pipeline shall リトライ系列全体の合計待機時間（個々の試行 RTT を除く sleep の合計）を 130 秒以上に拡張する
2. The Stage C Verify Pipeline shall リトライ試行回数の上限を 5 回以上 6 回以下とし、上限到達後は自動でこれ以上リトライしない
3. The Stage C Verify Pipeline shall リトライ試行の間に挿入する待機列を単調非減少なバックオフとして構成する
4. When 1 回目の PR 取得試行で対象ブランチに紐づく PR が確認できたとき, the Stage C Verify Pipeline shall 追加のリトライを行わず即時に成功扱いで継続する
5. When N 回目（N >= 2）の PR 取得試行で初めて PR が確認できたとき, the Stage C Verify Pipeline shall 残りのリトライを行わずに成功扱いで継続する
6. The Stage C Verify Pipeline shall 1 回の PR 取得試行あたりの待ち時間に 15 秒以下のタイムアウト上限を設け、単一試行のハングがリトライ系列全体を無限に止めることを防ぐ

### Requirement 2: 代替 API 経路への fallback

**Objective:** As a watcher 運用者, I want 主経路（ブランチ head を指定する PR 取得クエリ）が
全リトライで空応答を返した場合に、edge cache が独立な代替経路（List Pulls API への直接アクセス）で
もう 1 度だけ PR を探したい, so that 主経路の edge cache に張り付いた事象を独立な経路で救える可能性を
1 ターン分追加できる

#### Acceptance Criteria

1. If 主経路のリトライ系列が全試行で空応答 / 非 0 終了 / タイムアウトとなった場合, the Stage C Verify Pipeline shall リトライ上限到達後に 1 度だけ代替 API 経路で対象ブランチに紐づく open PR を探索する
2. When 代替 API 経路の探索で対象ブランチに紐づく open PR が 1 件以上返ったとき, the Stage C Verify Pipeline shall その結果を成功扱いとして verify を継続する
3. If 代替 API 経路の探索が空応答を返した場合, the Stage C Verify Pipeline shall 当該 Issue を既存の `stageC-pr-missing` 識別子で `claude-failed` 化する
4. If 代替 API 経路の呼び出しがネットワーク失敗 / 認証失敗 / タイムアウト / 非 0 終了で完了した場合, the Stage C Verify Pipeline shall 代替経路の結果を「PR 不在」と等価に扱い、当該 Issue を既存の `stageC-pr-missing` 識別子で `claude-failed` 化する
5. The Stage C Verify Pipeline shall 代替 API 経路の呼び出しに 15 秒以下のタイムアウト上限を設ける
6. The Stage C Verify Pipeline shall 代替 API 経路を主経路と独立に 1 回だけ呼び出し、代替経路自体のリトライは行わない
7. While 主経路のいずれかの試行で PR が確認できたケースである場合, the Stage C Verify Pipeline shall 代替 API 経路を呼び出さない

### Requirement 3: 観測可能性とログ粒度

**Objective:** As a watcher 運用者, I want 主経路リトライと代替経路探索の進捗・結果を $LOG から事後に
再構成したい, so that false negative の頻度・edge cache lag の典型分布・代替経路 fallback の発火頻度を
把握し、将来のチューニング判断ができる

#### Acceptance Criteria

1. When N 回目（N >= 2）の主経路リトライ試行が走るとき, the Stage C Verify Pipeline shall 試行回数・対象 Issue 番号・対象ブランチ・試行結果（成功 / 空応答 / 非 0 終了 / タイムアウト）を識別可能な単一行を `$LOG` に記録する
2. When 主経路リトライの末に PR が確認できたとき, the Stage C Verify Pipeline shall 成功までに要した試行回数を `$LOG` から事後に識別できる粒度で記録する
3. When 代替 API 経路の探索が呼び出されたとき, the Stage C Verify Pipeline shall 代替経路の呼び出し開始・結果（成功 / 空応答 / 失敗）・対象 Issue 番号・対象ブランチを `$LOG` から事後に識別できる粒度で記録する
4. When 代替 API 経路の探索で PR が確認できたとき, the Stage C Verify Pipeline shall 「主経路全試行失敗 / 代替経路で救済」事実を $LOG から事後に識別できる粒度で記録する
5. If 主経路と代替経路の両方で PR が確認できず `claude-failed` 化が発生した場合, the Stage C Verify Pipeline shall Issue 番号・対象ブランチ・主経路試行回数・最終試行の失敗要因・代替経路の最終結果を人間が原因特定できる粒度で `$LOG` に記録する
6. When 1 回目の主経路試行で即時に PR が確認できたとき, the Stage C Verify Pipeline shall 本変更前と同じ「Stage C 完了 / PR 作成済み」相当の成功ログを出力する

### Requirement 4: 既存挙動の後方互換性

**Objective:** As a watcher 運用者, I want 通常成功ケース（1 回目で PR が確認できるケース）で watcher の
外形挙動が本変更前後で観察可能な範囲で同一であってほしい, so that 既稼働の cron / launchd を壊さずに
本リトライ拡張と fallback 経路を有効化できる

#### Acceptance Criteria

1. While 1 回目の主経路リトライ試行で PR が確認できる場合, the Stage C Verify Pipeline shall 終了コード・ラベル遷移・Issue コメント・成功ログの外形を本変更前と同一に保つ
2. The Stage C Verify Pipeline shall 既存の env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` / `STAGEC_VERIFY_SLEEP_CMD` 等）と stage 終了コードの意味（0 = 成功 / 99 = quota 検出 / それ以外 = 既存失敗）を変更しない
3. The Stage C Verify Pipeline shall 既存ラベル（`claude-picked-up` / `claude-failed` / `needs-quota-wait` 等）の遷移契約を変更しない
4. The Stage C Verify Pipeline shall 既存の `stageC-pr-missing` 識別子文字列を `claude-failed` 化の根拠コードとして引き続き使用する
5. The Stage C Verify Pipeline shall Stage A / Stage A' / Stage B 完了直後の push 状態 verify（Issue #106 で導入）の挙動を変更しない
6. The Stage C Verify Pipeline shall Issue #108 で導入された主経路リトライの「1 回目で成功した場合に追加ログを出さない」外形契約を保つ
7. Where バックオフ系列・主経路リトライ最大試行回数を運用者が運用環境で override する必要がある場合, the Stage C Verify Pipeline shall 既存 env var 名と衝突しない env var で override を許容しつつ、未指定時のデフォルト値で Req 1.1 / 1.2 を満たす

### Requirement 5: テストカバレッジ

**Objective:** As a watcher 開発者, I want 「主経路 1 回目で成功」「主経路途中試行で初めて成功」
「主経路全試行失敗 → 代替経路で救済」「主経路全試行失敗 → 代替経路も失敗」の 4 経路を再現するテストを
保持したい, so that 将来の改修で同種リグレッションが入った際に早期検知できる

#### Acceptance Criteria

1. The Test Suite shall 「主経路 1 回目の試行で PR が確認できて即時成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
2. The Test Suite shall 「主経路の途中試行（N >= 2）で初めて PR が確認できて成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
3. The Test Suite shall 「主経路全試行で PR が確認できず、代替 API 経路で PR が見つかって成功する」経路を再現するテストを `local-watcher/test/` 配下に保持する
4. The Test Suite shall 「主経路全試行で PR が確認できず、代替 API 経路でも空応答が返って `claude-failed` 化する」経路を再現するテストを `local-watcher/test/` 配下に保持する
5. The Test Suite shall 「主経路全試行で PR が確認できず、代替 API 経路の呼び出しがネットワーク失敗 / 認証失敗 / タイムアウト / 非 0 終了で完了して `claude-failed` 化する」経路を再現するテストを `local-watcher/test/` 配下に保持する
6. The Test Suite shall Issue #108 で導入された既存の `stagec_pr_verify_test.sh` および `stagec_pr_verify_retry_test.sh` の全テストケースが本変更後も pass し続ける
7. The Test Suite shall 上記テストを外部ネットワーク呼び出し（実 GitHub API 通信）なしで実行できる形（fake コマンドによる挙動差し替え等の擬似環境）で構成する
8. The Test Suite shall リトライ間の待機を実時間で消化せず、テスト 1 件あたりの所要時間を 30 秒以内に収められる構成を取る

## Non-Functional Requirements

### NFR 1: パフォーマンス

1. While 1 回目の主経路試行で PR が確認できる通常成功ケースである場合, the Stage C Verify Pipeline shall verify 全体の追加レイテンシを Issue #108 適用時点から 1 秒以内の増分に収める
2. The Stage C Verify Pipeline shall 主経路リトライ系列全体に費やす時間（sleep の合計）を 130 秒以上 180 秒以下に収める
3. The Stage C Verify Pipeline shall 1 回の主経路 PR 取得試行を 15 秒以下で強制終了するタイムアウト上限を持つ
4. The Stage C Verify Pipeline shall 代替 API 経路の呼び出しを 15 秒以下で強制終了するタイムアウト上限を持つ
5. If 主経路と代替経路がいずれも `claude-failed` 化に至る最悪ケースである場合, the Stage C Verify Pipeline shall Stage C 完了通知から `claude-failed` 化までの所要時間を 200 秒以下に収める

### NFR 2: 観測可能性

1. When リトライ系列の任意の主経路試行が完了したとき, the Stage C Verify Pipeline shall 当該試行の結果（成功 / 空応答 / 非 0 終了 / タイムアウト）を `$LOG` から事後に識別可能な形で残す
2. When 代替 API 経路の呼び出しが完了したとき, the Stage C Verify Pipeline shall 当該呼び出しの結果（成功 / 空応答 / 非 0 終了 / タイムアウト / 認証失敗）を `$LOG` から事後に識別可能な形で残す
3. The Stage C Verify Pipeline shall 主経路リトライ・代替経路探索の全ログを単一 Issue / 単一 watcher run のスコープで突合できる識別子（Issue 番号・対象ブランチ）と併せて出力する

### NFR 3: 後方互換性とロールアウト安全性

1. The Stage C Verify Pipeline shall 既存の cron / launchd 登録文字列・配置先パス（`~/bin/issue-watcher.sh`）・依存 CLI（`gh` / `jq` / `flock` / `git` / `timeout`）の前提を変更しない
2. The Stage C Verify Pipeline shall self-hosting 環境（idd-claude 自身を対象 repo として運用する dogfooding 経路）でも本変更が有効であり、既存稼働 watcher と非互換な状態を生まない
3. While 同一 Issue に対して watcher が複数回 verify を試行するケースである場合, the Stage C Verify Pipeline shall リトライ・fallback の副作用（Issue コメント / ラベル付け替え / 外部 API 状態変更）を冪等に保つ
4. Where バックオフ系列・主経路リトライ最大試行回数を運用者が env var で override したい場合, the Stage C Verify Pipeline shall 未指定時のデフォルト値で本要件の Req 1.1 / 1.2 / NFR 1.2 を満たし、override 時もこれらの上限・下限を守れる範囲で許容する

## Out of Scope

- Stage C の PR 取得を REST 系から GraphQL 系へ切り替える代替案（Issue #108 Out of Scope を踏襲）
- Stage A / Stage A' / Stage B 完了直後の push 状態 verify への改修（Issue #106 で対応済み）
- リトライ系列途中での Issue コメント通知（リトライ進捗・代替経路発火は `$LOG` のみで観測し、ノイズ抑制のため Issue 側には出さない）
- 代替 API 経路の探索自体に対する追加リトライ（代替経路は 1 ターンのみとし、edge cache が両経路で同時に張り付いた事象は別 Issue で扱う）
- PjM サブエージェントのプロンプト改修による「PR 未作成のまま空転終了する」根本原因の解消
- GitHub Actions 経路（`.github/workflows/issue-to-pr.yml`、`IDD_CLAUDE_USE_ACTIONS=true` opt-in）への同等リトライ機構の移植
- LaunchDarkly 等の外部 Feature Flag SaaS との連携（CLAUDE.md `## Feature Flag Protocol` は opt-out のため本要件でも flag 裏実装は要求しない）
- 主経路と代替経路の両方が空応答に終わった際に「true negative（PR 未作成）」と「false negative（両経路で edge cache lag）」を区別する追加判定ロジック
- バックオフ系列・最大試行回数のデフォルト値そのものの将来再チューニング（観測蓄積後に別 Issue で扱う）

## Open Questions

- バックオフ系列のデフォルト値（Req 1.1 / 1.2 / NFR 1.2 の範囲内で「5s / 10s / 20s / 40s / 60s」「合計 135s / 6 試行」を Issue 本文では提案）の最終確定値は設計で詰める。本要件では合計待機 130 秒以上・上限 180 秒以下・試行回数 5〜6 回の範囲で許容する
- env var による override を導入するか否か、導入する場合の env var 名と入力フォーマット（カンマ区切り秒数 / スペース区切り / 個別 env var 等）は本要件では規定せず、設計側で後方互換性方針と併せて確定する
- 代替 API 経路の具体的なクエリ手段（Issue 本文では `gh api repos/{owner}/{repo}/pulls?head={owner}:BRANCH&state=open` を例示）と、`{owner}` プレフィックスを `REPO` から派生させる方法は設計／実装側で確定する。本要件では「主経路と独立な edge cache 経路で対象ブランチに紐づく open PR を 1 回探索する」の振る舞いのみを規定する
- 代替経路が PR を救済した事実を将来 Issue コメントへ通知するかは本要件では「不要」（Out of Scope 参照）。運用観測で fallback 発火率が高い場合は別 Issue で再要件化する
