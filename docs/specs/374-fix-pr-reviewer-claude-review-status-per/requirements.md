# Requirements Document

## Introduction

`PR_REVIEWER_STATUS_CHECK_ENABLED=true` + `FULL_AUTO_ENABLED=true` の AND 二重 opt-in が
成立した環境において、`codex-review` commit status は PR head sha に対して正しく publish される一方、
`claude-review` commit status は **per-task ループ運用（`PER_TASK_LOOP_ENABLED=true`）では一度も
publish されない**。Issue #349 が要件化した「Claude Reviewer の最終 `RESULT:` を `claude-review`
context として PR head sha に publish する」契約（#349 Req 3.x / 4.x）が per-task 経路で
構造的に成立しない状態にある。

根本原因は、per-task ループの Reviewer round=1〜3 直後で claude-review status を publish する
試行が、PjM による impl PR 作成より **前** の時間軸に並んでいることにある。publish 関数は
ブランチから `gh pr list --head <branch>` で PR を解決して head sha を取得する設計のため、
PR がまだ存在しないタイミングでは PR 解決に失敗し、WARN ログを残して skip して終わる。
altpocket #85 の実トレースでは Reviewer round=1 approve 完了から PjM の PR 作成までに
約 1 分 40 秒のタイムラグが観測されている。

本要件は、per-task / 非 per-task いずれの実装経路でも、PR が GitHub 側に存在する状態で
`claude-review` commit status が PR head sha に publish され、かつ Reviewer の最新 `RESULT:`
（approve / reject）と整合した状態に収束することを保証する。後方互換として、AND 二重 opt-in が
無効な既定環境では本修正後も commit status を一切 publish せず、外形挙動を導入前と完全に
等価に保つ。

## Requirements

### Requirement 1: per-task 経路での `claude-review` status publish の発火

**Objective:** As an idd-claude operator, I want claude-review commit status to be published against the impl PR head sha when per-task loop completes a Reviewer round, so that auto-merge の required status checks が per-task 運用環境でも `claude-review` を観測でき、ゲートが構造的に成立しないという現状の不具合が解消される

#### Acceptance Criteria

1. When per-task loop の Reviewer round=1〜3 のいずれかが approve を出し、かつ AND 二重 opt-in が成立し、かつ対応する impl PR が GitHub 側に存在する状態に到達した, the PR Reviewer Processor shall context `claude-review` / state `success` の commit status を PR head sha に対して 1 回 publish する
2. When per-task loop の Reviewer round=1〜3 のいずれかが reject を出し、かつ AND 二重 opt-in が成立し、かつ対応する impl PR が GitHub 側に存在する状態に到達した, the PR Reviewer Processor shall context `claude-review` / state `failure` の commit status を PR head sha に対して 1 回 publish する
3. The PR Reviewer Processor shall per-task 経路で publish する `claude-review` status の context 名・state 解決規則（approve→success / reject→failure）・description 長制限を、非 per-task 経路（#349 Req 3.1〜3.3）と一致させる
4. When PjM が impl PR を作成する前に Reviewer の `RESULT:` が確定した, the PR Reviewer Processor shall PR 作成完了後に当該 Reviewer の `RESULT:` を反映した `claude-review` status の publish が 1 回以上行われることを保証する
5. The PR Reviewer Processor shall 同一 impl PR 内で複数 task が連続して Reviewer round を完了した場合、各 task の最終 `RESULT:` を反映した最新の `claude-review` status が PR head sha に対して観測可能な状態に収束させる

### Requirement 2: 非 per-task 経路の挙動温存

**Objective:** As an idd-claude operator, I want non per-task 経路の `claude-review` publish 挙動を本修正で変更しないようにしたい, so that 既に正しく publish できている経路（Reviewer round=1〜3 / Debugger 経由 round=3 / Issue #349 で確立済み）が回帰しない

#### Acceptance Criteria

1. While `PER_TASK_LOOP_ENABLED` が `=true` 以外（既定 OFF）かつ AND 二重 opt-in が成立している, the PR Reviewer Processor shall 非 per-task 経路の Reviewer round=1〜3 完了直後に `claude-review` status を従来どおり PR head sha に publish する
2. The PR Reviewer Processor shall 非 per-task 経路の publish 呼び出し位置（Stage B / Stage B' / Debugger 経由 Stage B''）における外形挙動（呼び出し回数・state・description・target_url）を本修正前後で一致させる
3. The PR Reviewer Processor shall 非 per-task 経路では本修正前と同様に impl PR が既に存在する状態でのみ publish が試行されることを維持する

### Requirement 3: PR 未作成時 / parse 失敗時の安全な skip

**Objective:** As an idd-claude operator, I want publish 試行のタイミング不整合や `review-notes.md` parse 失敗が watcher パイプラインを停止させないようにしたい, so that GitHub API のタイミングや想定外の状態が原因で claude-failed に倒れる事故を防げる

#### Acceptance Criteria

1. If publish 試行時点で対応する impl PR が GitHub 側に解決できない（branch から PR が引けない）, the PR Reviewer Processor shall WARN レベルのログを 1 行残し commit status の publish を行わずに当該試行を skip する
2. If `review-notes.md` が存在しない, the PR Reviewer Processor shall WARN レベルのログを 1 行残し commit status の publish を行わずに当該試行を skip する
3. If `review-notes.md` を `parse_review_result` で解釈できない（最終 `RESULT:` 行不在 / 不正値）, the PR Reviewer Processor shall WARN レベルのログを 1 行残し commit status の publish を行わずに当該試行を skip する
4. When publish 試行が PR 未作成・review-notes.md 不在・parse 失敗のいずれかで skip された, the PR Reviewer Processor shall watcher パイプライン（per-task ループ継続 / PjM PR 作成 / 後続 Reviewer round / claude-failed 判定）を停止させずに後続処理を続行する
5. The PR Reviewer Processor shall WARN ログ 1 行に「Issue 番号」「branch 名」「round 番号（既知時）」「skip 理由（PR 未解決 / file 不在 / parse 失敗のいずれか）」を含めて、原因特定が grep 1 回で完了する形にする

### Requirement 4: PR 作成後の最終 publish 整合（latest-wins）

**Objective:** As an idd-claude operator, I want PjM の impl PR 作成完了後に当該 PR head sha 上で `claude-review` status が Reviewer の最終 `RESULT:` を反映する状態に収束することを保証したい, so that auto-merge ゲートが古い PR 不在時の WARN skip のまま claude-review status 欠落で永遠に成立しない事態を防ぐ

#### Acceptance Criteria

1. When per-task ループの最終 Reviewer round が `RESULT: approve` を出して PjM が impl PR を作成完了した, the PR Reviewer Processor shall PR head sha に対して context `claude-review` / state `success` の commit status が観測可能な状態に到達することを保証する
2. When per-task ループの最終 Reviewer round が `RESULT: reject` を出して PjM が impl PR を作成完了した, the PR Reviewer Processor shall PR head sha に対して context `claude-review` / state `failure` の commit status が観測可能な状態に到達することを保証する
3. When 同一 PR head sha に対して同一 context `claude-review` で複数回 publish が行われた, the PR Reviewer Processor shall GitHub Commit Status API の "latest wins per (sha, context)" セマンティクスにより最新の `RESULT:` を反映した state が表示される状態に収束させる（#349 Req 4.3 と整合）
4. While impl PR が GitHub 側に存在しない状態, the PR Reviewer Processor shall PR head sha に対する `claude-review` status の publish を試行しない（試行しても解決不能なため Req 3.1 で skip される / 副作用ゼロ）

### Requirement 5: 後方互換と既定動作の温存

**Objective:** As an idd-claude operator, I want AND 二重 opt-in が無効な既定環境の挙動を本修正で一切変更しないようにしたい, so that 本修正をデプロイした既存 consumer repo が `claude-review` status の publish 試行・追加 API 呼び出し・追加ログ出力に巻き込まれない

#### Acceptance Criteria

1. While `PR_REVIEWER_STATUS_CHECK_ENABLED` が `=true` 以外（既定 `false`）, the PR Reviewer Processor shall `claude-review` status の publish 関連 API 呼び出し（`gh api -X POST /repos/.../statuses/<sha>` / `gh pr list --head <branch>` 等）を一切発火させない
2. While `FULL_AUTO_ENABLED` が `=true` 以外（既定 `false`）, the PR Reviewer Processor shall `claude-review` status の publish 関連 API 呼び出しを一切発火させない（#348 kill switch 配下 / #349 Req 1.4 と整合）
3. The PR Reviewer Processor shall `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` env var 名・正規化規則・kill switch セマンティクスを本修正で変更しない
4. The PR Reviewer Processor shall 既存の env var 名・ラベル名・exit code 意味・cron 登録文字列・ログ出力先・PR コメント投稿の挙動を本修正で変更しない
5. While AND 二重 opt-in が無効, the PR Reviewer Processor shall 従来どおり `review-notes.md` の commit / push / PR コメント投稿挙動を一切変更せず、運用者がコメントから `RESULT:` を確認できる状態を維持する（#349 Req 6.x と整合）

### Requirement 6: 同期と配布の整合性

**Objective:** As an idd-claude メンテナ, I want 本修正が root 配下の watcher / module と installed consumer 配下（`$HOME/bin/...`）の双方で同一挙動になることを保証したい, so that `install.sh` 経由で配布される watcher にも修正が確実に反映され、本 Issue が「修正したのに動かない」と再発しないようにする

#### Acceptance Criteria

1. The Installer shall `install.sh` が `local-watcher/bin/issue-watcher.sh` および `local-watcher/bin/modules/*.sh` を `$HOME/bin/` 配下へ冪等にコピーする既存挙動を維持し、本修正後のファイルがそのまま配布される
2. The Issue Watcher shall README の該当箇所（`PR_REVIEWER_STATUS_CHECK_ENABLED` / `claude-review` status の動作説明や既知の制約に関する記述があれば）と整合した状態で本修正を反映する
3. When 本修正をデプロイ済みの環境で per-task ループ運用（`PER_TASK_LOOP_ENABLED=true`）の eligible Issue を投入した, the PR Reviewer Processor shall PjM が impl PR を作成した後に当該 PR head sha に対して `claude-review` commit status が観測される状態に到達する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The PR Reviewer Processor shall 本修正前後で AND 二重 opt-in 無効環境の外部観測挙動（exit code / stderr 出力 / ラベル遷移 / 外部副作用の有無 / PR コメント投稿）を一致させる
2. The PR Reviewer Processor shall 本修正後も `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` 正規化規則（`=true` 厳密一致、それ以外を OFF）を維持する
3. The PR Reviewer Processor shall 本修正後も既存の `publish_claude_review_status` / `pr_publish_claude_status` 関数シグネチャ（引数・戻り値・既存呼び出し位置の round 番号引数）に対する直接破壊的変更を行わない（呼び出し位置の追加 / 補完は許容）

### NFR 2: 静的検査

1. The Issue Watcher shall 本修正後の `local-watcher/bin/issue-watcher.sh` および `local-watcher/bin/modules/pr-reviewer.sh` が `bash -n` で構文エラー 0、`shellcheck` で `.shellcheckrc` を踏まえた baseline 上の警告増加 0 を満たす
2. The Test Suite shall 追加した近接テストの bash スクリプトが `bash -n` / `shellcheck` クリーンであることを満たす

### NFR 3: 可観測性

1. When publish が成功した, the PR Reviewer Processor shall PR 番号・head sha・context・state を含む 1 行のログを既存ロガー粒度（`pr_log`）と同形式で stdout に出力する（#349 NFR 1.x と整合）
2. When publish が PR 未解決・file 不在・parse 失敗のいずれかで skip された, the PR Reviewer Processor shall skip 理由を識別可能な WARN ログを 1 行残し silent fail にしない（#349 Req 5.x と整合）
3. The PR Reviewer Processor shall AND 二重 opt-in OFF 時の suppression ログを既存契約どおり「サイクルあたり最大 1 行」に制限する（#349 Req 7.2 と整合）

### NFR 4: 回帰防止テスト粒度

1. The Test Suite shall per-task 経路で「Reviewer round=1 approve / reject 後に publish 試行が PR 作成完了後に成立すること」を再現できる近接テストを `local-watcher/test/` 配下に追加する
2. The Test Suite shall 上記近接テストを既存テストランナ（`local-watcher/test/` 配下の bash テストイディオム）から起動可能な単一スクリプトとして提供する
3. If `publish_claude_review_status` の呼び出し位置が再び PR 作成より前に戻る回帰がコミットされた, the Test Suite shall 該当テストを fail させ、どの呼び出し位置が PR 未作成の時間軸に並んでいるかを 1 件以上特定可能な形で出力する

## Out of Scope

- `codex-review` commit status publish ロジックの変更（本 Issue は `claude-review` 経路の不具合修正に限定し、codex 側は #349 確定済みの挙動を維持する）
- `pr_publish_commit_status` / `pr_publish_claude_status` の API call レイヤ・state 解決ロジック・description 長制限の変更（#349 で確立済み）
- `PR_REVIEWER_STATUS_CHECK_ENABLED` / `FULL_AUTO_ENABLED` の env var 名・正規化規則・kill switch 概念の再設計（#348 / #349 で確定済み）
- `review-notes.md` の `RESULT:` 規約・`parse_review_result` 関数本体の変更（既存契約をそのまま流用）
- Debugger Gate 経由 Reviewer round=3（非 per-task 経路）の publish 呼び出し位置の変更（既に PR 存在状態で publish される経路のため対象外）
- per-task ループ自体のタイミング設計変更（task 単位 Reviewer の起動順序 / Debugger Gate / fail-fast セマンティクス）— 本修正はあくまで `claude-review` status の publish タイミングに限定する
- branch protection / required status checks 側の設定（GitHub 側設定 / consumer 運用責務）
- altpocket-server 等 consumer repo 側での auto-merge ラベル運用・PR テンプレートの調整
- `codex-review` 不在 / 失敗時の auto-merge ゲート挙動（D-03 / D-04 / 関連 Issue で扱う領域）

## Open Questions

- なし（Issue #374 本文・既存コード（`publish_claude_review_status` 呼び出し位置 12 箇所 / `pr_publish_claude_status` 実装）・関連 Issue #349 の確定済み契約を突き合わせることで、修正方針スコープ（PR 作成後再 publish フックの導入 / pr-reviewer.sh 内 publish 経路追加 / 両者併用）の選択は Architect の領域として委ね、本要件は publish 成立タイミングと AC ベースの外形契約に限定して記述した。要件レベルで人間判断が必要な未解決項目は識別されなかった）
