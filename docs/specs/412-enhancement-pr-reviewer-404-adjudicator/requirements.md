# Requirements Document

## Introduction

#404 で導入された **PR Reviewer Adjudicator**（codex の指摘を Claude が legitimate / excessive に
裁定し、`needs-iteration` と `claude-review` の最終判定を握る Processor）は、`PR_REVIEWER_ADJUDICATOR_ENABLED=true`
の明示 opt-in を要するため、**production の全 consumer repo で未有効化**のままになっている。結果として、
codex の過剰指摘 / nitpick が `needs-iteration` を駆動し続け、impl PR の pr-iteration が scope-creep
する事象（altpocket-server #139 等で観測）が解消されていない。さらに `claude-review` を branch
protection の required status に採用済の repo では、adjudicator も Reviewer catch-up も publish せず、
merge gate を満たせない PR が黙って滞留する可能性がある。

人間の `needs-decisions` 解消コメントにより、以下の方針が確定済である:

- 案 A（adjudicator を **default ON / opt-out**）で進める。`=false` 厳密一致のみ OFF とし、それ以外
  （未設定 / 空 / `True` / `TRUE` / `1` / typo）はすべて安全側＝有効に正規化する。
- `claude-review` の publisher 契約（adjudicator / Reviewer catch-up / codex-review の関係）と codex
  運用時の推奨設定を README / 運用ドキュメントに明記する。
- `claude-review` 必須化 repo で adjudicator も Reviewer catch-up も発火せず merge gate を満たせない
  PR が生じる状態を可視化する（sit-and-wait で詰まらせない）。
- opt-out 化に伴う `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` 既定（現状 `passthrough`）の妥当性を
  確認する。

本変更は idd-claude 自身（self-hosting）にも即時影響する。merge された瞬間に watcher 自身の挙動が
変わり、adjudicator が全 repo で有効化される。既存 env var 名・他の `PR_REVIEWER_ADJUDICATOR_*` env
の意味・cron 登録文字列・`=false` 明示済 OFF 環境の挙動は不変であり、後方互換ポリシーを維持する。

## Requirements

### Requirement 1: `PR_REVIEWER_ADJUDICATOR_ENABLED` の既定反転（default ON / opt-out）

**Objective:** As an idd-claude operator, I want adjudicator を追加設定なしで既定有効にしたい, so that 全 consumer repo で codex の過剰指摘 bypass が発動し、`needs-iteration` の scope-creep が起きない

#### Acceptance Criteria

1. When `PR_REVIEWER_ADJUDICATOR_ENABLED` が未設定の状態で watcher が起動した場合, the Watcher shall adjudicator 経路を有効として動作させ、codex 出力に対する legitimate / excessive 裁定と `claude-review` publish を実施する
2. When `PR_REVIEWER_ADJUDICATOR_ENABLED` が空文字で設定された状態で watcher が起動した場合, the Watcher shall adjudicator 経路を有効として動作させる
3. When `PR_REVIEWER_ADJUDICATOR_ENABLED=true` が明示された状態で watcher が起動した場合, the Watcher shall adjudicator 経路を有効として動作させる
4. When `PR_REVIEWER_ADJUDICATOR_ENABLED=false` が明示された状態で watcher が起動した場合, the Watcher shall adjudicator 経路を無効化し、本変更導入前の opt-in 既定 OFF と等価な挙動（claude / gh / git の追加呼び出しゼロ、adjudicator marker / コメント / status 投稿ゼロ）で動作させる
5. If `PR_REVIEWER_ADJUDICATOR_ENABLED` に `=false` 以外の値（`False` / `FALSE` / `0` / `True` / `TRUE` / `1` / typo 等）が明示された場合, the Watcher shall 当該値を安全側＝有効に正規化し、adjudicator 経路を有効として動作させる
6. The Watcher shall 起動時に adjudicator 経路の有効 / 無効状態を運用者が事後に判別できる形でログに残す

### Requirement 2: `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` 既定の見直し

**Objective:** As an idd-claude operator, I want adjudicator が常時 ON 前提となった後でも fallback 既定が SPOF を生まないことを確認したい, so that adjudicator の claude 実行失敗時に merge gate が永久 block されない

#### Acceptance Criteria

1. When `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` が未設定の状態で watcher が起動した場合, the Watcher shall fallback verdict を「adjudicator 自体を実行しなかったかのように扱い既存 Reviewer catch-up に委譲する」モード（passthrough 相当）で初期化する
2. When `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL=legitimate` が明示された状態で watcher が起動した場合, the Watcher shall fallback verdict を「全 finding を legitimate に倒し `claude-review = failure` を publish する徹底安全側」モードで動作させる
3. If `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` に既定モード / `legitimate` 以外の値（typo / 大文字違い / 空文字等）が明示された場合, the Watcher shall 当該値を既定モード（passthrough 相当）に正規化する
4. While adjudicator が claude exec 失敗 / rate-limit / timeout 等で verdict を確定できない状態, the Watcher shall fallback verdict の選択に応じて、(a) 既定モードでは既存 Reviewer catch-up に `claude-review` の publish を委譲し、(b) `legitimate` モードでは `needs-iteration` を維持して `claude-review = failure` を publish する
5. The Watcher shall fallback verdict 既定値の妥当性判断根拠（SPOF 緩和 / claude-review publisher contention）を運用者が参照できる形で README に明示する

### Requirement 3: README / 運用ドキュメントへの `claude-review` publisher 契約と codex 運用ガイドの明記

**Objective:** As an idd-claude operator running consumer repos, I want `claude-review` の publisher 契約と codex 運用時の推奨設定を運用ドキュメントから把握したい, so that adjudicator default ON 化後に branch protection / codex 共用構成を誤運用しない

#### Acceptance Criteria

1. The README.md shall `claude-review` commit status の publisher として adjudicator / Reviewer catch-up / codex-review の責務分担と発火順序を明示する節を持つ
2. The README.md shall adjudicator marker（`<!-- idd-claude:pr-adjudicator sha=<sha> -->`）の存在 / 不在による Reviewer catch-up の defer / 引き継ぎ動作の判定規則を明示する
3. The README.md shall codex を併用する運用について、adjudicator default ON 化後に推奨される `PR_REVIEWER_ENABLED` / `PR_REVIEWER_ADJUDICATOR_ENABLED` / `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` の組み合わせと、`claude-review` を branch protection の required status に追加する際の手順を明示する
4. The README.md shall 本変更による既定値反転（opt-in / 既定 OFF → opt-out / 既定 ON、`=false` で無効化可）を運用者が認識できる migration note を持つ
5. The `local-watcher/bin/issue-watcher.sh` shall `PR_REVIEWER_ADJUDICATOR_ENABLED` 宣言行直上のコメントから「完全な opt-in / 既定 OFF」相当の文言を削除または「既定 ON / `=false` で opt-out」表現に書き換える

### Requirement 4: `claude-review` 必須化 repo における merge gate 不充足 PR の可視化

**Objective:** As an idd-claude operator, I want `claude-review` を required status に採用した repo で adjudicator も Reviewer catch-up も発火せず merge gate を満たせない PR を検知したい, so that sit-and-wait で詰まった PR を黙って放置せず、人間判断や運用是正に回せる

#### Acceptance Criteria

1. While 監視対象 PR が `claude-review` を required status に持ち、当該 PR の head sha に対して adjudicator marker と Reviewer catch-up publish のいずれも記録されていない状態, the Watcher shall 当該 PR が merge gate 不充足のまま停滞していることを運用者が事後に判別できる形でログに残す
2. When 上記の停滞状態を検知した場合, the Watcher shall 当該 PR に対して停滞状態を示すラベル付与 / コメント投稿 / commit status publish のいずれかの可視化手段を 1 つ以上提供する
3. The Watcher shall 上記の可視化手段を、対象状態が解消（adjudicator 発火 / Reviewer catch-up 発火 / required status 設定変更）された後に冪等に取り消すか、運用者が手動で解除できる経路を提供する
4. If 当該 PR の head sha に対して adjudicator が exec 失敗 / rate-limit / timeout で marker を投稿していない場合, the Watcher shall `PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` の選択に基づく fallback 経路（passthrough 既定: catch-up 委譲 / legitimate: 即 failure publish）を優先し、両経路とも publish に至らない場合のみ本要件 4.1 の可視化を発火させる
5. The README.md shall 本可視化手段の発火条件と、運用者が停滞 PR を解消するための推奨対応手順（required status 設定見直し / 人間 admin merge / adjudicator 設定再点検）を明示する

### Requirement 5: 後方互換性（既存 env / ラベル / cron 登録文字列の不変性）

**Objective:** As an idd-claude operator running existing cron / launchd entries, I want 本変更後も既存登録文字列を書き換えずに同じ挙動が得られたい, so that idd-claude 更新によって運用中の自動化が壊れない

#### Acceptance Criteria

1. When `PR_REVIEWER_ADJUDICATOR_ENABLED=false` を既存 cron / launchd で明示している環境が本変更後に watcher を起動した場合, the Watcher shall 本変更前の opt-in 既定 OFF と完全に同一の挙動（claude / gh / git の追加呼び出しゼロ、adjudicator 関連 marker / コメント / status / ログ行ゼロ）で動作させる
2. When `PR_REVIEWER_ADJUDICATOR_ENABLED=true` を既存 cron / launchd で明示している環境が本変更後に watcher を起動した場合, the Watcher shall 本変更前の opt-in 有効時と機能的に同一の adjudicator 挙動で動作させる
3. The Watcher shall 本変更で `PR_REVIEWER_ADJUDICATOR_ENABLED` 以外の `PR_REVIEWER_ADJUDICATOR_*` env var の名称・既定値・意味・正規化規則を変更しない（`PR_REVIEWER_ADJUDICATOR_MODEL` / `PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT` / `PR_REVIEWER_ADJUDICATOR_PROMPT` / `PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS` を含む）
4. The Watcher shall 本変更で `PR_REVIEWER_ADJUDICATOR_ENABLED` の env var 名称・参照 path・exit code の意味・cron 登録文字列の解釈規則を変更しない
5. The Watcher shall 本変更で adjudicator が利用するラベル名（`needs-iteration` 等）と commit status 名（`claude-review` / `codex-review`）の意味を変更しない
6. While watcher 起動直後に解決済 env 値をログに出力する処理が存在する間, the Watcher shall 既存の log prefix 文字列を変更しない

### Requirement 6: ドキュメント二重管理同期（root ↔ repo-template / README）

**Objective:** As an idd-claude maintainer, I want 本変更に関係する agents / rules / README / コメント記述を root と repo-template の両系統で同期したい, so that consumer repo 配布物との片系統ドリフトが起きない

#### Acceptance Criteria

1. The repository shall 本変更後、root の `.claude/agents/` と `repo-template/.claude/agents/` の `diff -r` 結果が空（byte 一致）である状態を維持する
2. The repository shall 本変更後、root の `.claude/rules/` と `repo-template/.claude/rules/` の `diff -r` 結果が空（byte 一致）である状態を維持する
3. Where 本変更が adjudicator の挙動説明・既定値・migration note を README に追加する場合, the repository shall 同一 PR 内で当該記述を root README と consumer 向け配布対象（該当する場合）に整合させる
4. The repository shall `local-watcher/bin/issue-watcher.sh` 内の adjudicator 関連コメントの記述（既定値 / opt-in 表現）を本変更後の挙動と整合させ、README の記述と矛盾しない状態に保つ

### Requirement 7: 静的解析・スモークテスト

**Objective:** As an idd-claude maintainer, I want 本変更後の watcher が既存検証ハーネスを通過することを確認したい, so that self-hosting で merge 直後に watcher 挙動が破綻しない

#### Acceptance Criteria

1. The `local-watcher/bin/issue-watcher.sh` shall 本変更後も `shellcheck` を警告ゼロで通過する
2. The Watcher shall cron-like 最小 PATH（`env -i HOME=$HOME PATH=/usr/bin:/bin`）でも `PR_REVIEWER_ADJUDICATOR_ENABLED` 未設定時に既定 ON で起動できる
3. When `PR_REVIEWER_ADJUDICATOR_ENABLED` 未設定 / `=false` 明示 / `=true` 明示 / `=False` / `=1` / typo の各値で watcher を起動した場合, the Watcher shall 各値に対する解決後の有効 / 無効状態が Requirement 1 の AC 1〜5 と一致することをスモークテストで確認できる
4. The Watcher shall 本変更後、対象 Issue / PR を未生成のスモーク起動で「処理対象の Issue なし」相当の正常終了 exit code を維持する

## Non-Functional Requirements

### NFR 1: 既存運用との後方互換性

1. The Watcher shall 本変更前に `PR_REVIEWER_ADJUDICATOR_ENABLED=false` を明示していた cron / launchd エントリで、追加変更なしに本変更後も同一の opt-out 状態が保たれる（adjudicator 関連の追加呼び出し・ログ行・コメント・ラベル・status 投稿はゼロ）
2. The Watcher shall 本変更前に `PR_REVIEWER_ADJUDICATOR_ENABLED=true` を明示していた cron / launchd エントリで、追加変更なしに本変更後も同一の adjudicator 機能セットが有効に保たれる
3. The Watcher shall 本変更で env var 名・ラベル名・commit status 名・exit code の意味・log prefix を変更しない（運用者が grep / アラート設定を書き換える必要が生じない）

### NFR 2: 観測可能性

1. The Watcher shall 本変更後の adjudicator 経路において、1 PR 裁定あたりの観測ログ増加が本変更前の adjudicator 有効時と同等の粒度（既存 `adj_log_summary` / `pr-iteration:` サマリ 1 行）に収まる
2. The Watcher shall Requirement 4 の停滞 PR 可視化発火時、可視化の根拠（required status 名 / adjudicator marker 不在 / catch-up 不発火）を運用者が事後に grep できる形でログに残す

### NFR 3: self-hosting 影響の最小化

1. While idd-claude 自身が自リポジトリ上で watcher 経路を運用している間, the Watcher shall 本変更による merge 直後の adjudicator default ON 化により、進行中の PR / Issue 処理パイプライン（PR Reviewer / PR Iteration / Reviewer catch-up）の挙動が予期せず壊れない（既存 cron 登録の env 明示が無効化される副作用を生まない）

## Out of Scope

- 他の `PR_REVIEWER_ADJUDICATOR_*` env var（`PR_REVIEWER_ADJUDICATOR_MODEL` / `PR_REVIEWER_ADJUDICATOR_EXEC_TIMEOUT` / `PR_REVIEWER_ADJUDICATOR_PROMPT` / `PR_REVIEWER_ADJUDICATOR_MAX_FINDINGS`）の既定値変更・正規化規則変更・名称変更
- `PR_REVIEWER_ENABLED`（PR Reviewer Processor 自体の opt-in gate）の既定値変更
- 設計 PR (`claude/issue-<N>-design-*`) に対する `claude-review` publisher 経路の追加（#404 と同じく impl PR スコープ限定。設計 PR ゲートは別 Issue）
- adjudicator-prompt.tmpl の判定基準改訂（legitimate / excessive 分類規則の見直し）
- codex / antigravity 以外のレビューツール対応の追加
- GitHub Actions ワークフロー側（`IDD_CLAUDE_USE_ACTIONS=true` 経路）における adjudicator 既定値の扱い
- consumer repo の branch protection 設定を watcher 側から自動切替する機能の追加

## Open Questions

- なし（人間の `needs-decisions` 解消コメントにより、案 A 採用 / 値正規化方針 / fallback 既定見直し / README publisher 契約明記 / 停滞 PR 可視化 / 二重管理同期 / self-hosting 留意が確定済。実装方針の詳細は Architect 領分とし、本要件定義では扱わない）
