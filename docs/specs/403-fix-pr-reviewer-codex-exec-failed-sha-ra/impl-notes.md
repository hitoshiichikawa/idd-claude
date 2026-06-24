# 実装ノート (Issue #403)

## 概要

`pr-reviewer.sh` の `kind=exec-failed` 経路に「同一 head sha での連続失敗カウンタの永続化」
「上限到達による候補除外と advisory コメント」「stderr 末尾優先抜粋 + artifact 保存」を追加し、
codex / antigravity の rate-limit 持続事故を防ぐ。本機能は **既定 ON** だが、`PR_REVIEWER_ENABLED=true`
の opt-in 経路の中でのみ動作し、env override で従来挙動に戻せる安全側拡張。

## 採用した設計判断と理由

### 1. 連続失敗カウンタの保持媒体: **PR body の hidden marker** を採用

- **理由**: pr-iteration の no-progress-streak marker パターン（`<!-- idd-claude:pr-iteration ... no-progress-streak=K -->`）
  と整合し、(a) cron 多重稼働 / multi-host watcher で **同一 state を共有**できる、
  (b) FS race condition がない、(c) 既存テストイディオムをそのまま流用できる、(d) state file
  方式に必要な dir 作成・lock・cleanup ロジックが不要、という利点がある。
- **marker 形式**: `<!-- idd-claude:pr-reviewer-exec-fail-streak sha=<sha> streak=<N> tool=<tool> last-updated=<ISO8601> -->`
  prefix を pr-iteration とは別の `pr-reviewer-exec-fail-streak` にすることで、既存 marker
  （`idd-claude:pr-reviewer sha=... kind=...`）と prefix が衝突せず、`pi_general_filter_self`
  / `idd-claude:pr-iteration` prefix 判定とも干渉しない。

### 2. 上限到達時の遷移先: **advisory コメント 1 回投稿のみ（ラベル付与なし）** を採用

- **理由**: `claude-failed` を付けると Failed Recovery Processor との重複セマンティクスが発生し、
  `needs-quota-wait` 等の新ラベル追加は別 Issue スコープを広げる。advisory コメントのみなら
  既存ラベル運用と完全に干渉せず、人間運用者の判断（新 commit 押す / quota 復旧待つ）に委ねられる。
- 重複防止は既存 `pr_already_processed` の (sha, kind) marker 判定を流用（`kind=exec-fail-escalated`
  を新規追加）。同一 sha・同一 marker が既に在れば再投稿しない。

### 3. artifact 保存方式: **コメント本文の抜粋拡張（8KB）+ $HOME/.issue-watcher/... 配下保存** の両方

- **理由**: コメント本文は GitHub UI で運用者が即時参照できる。artifact ファイルは watcher
  host のみで参照可能だが、1MB 超の長文 stderr 全体を保持して詳細調査に使える。
  両者を併用し、コメント本文に artifact path を明記することで `cron / Actions` どちらでも
  コメント本文での真因特定を保証し、watcher host ssh 可能ならさらに詳細な調査もできる。
- 保存先: `$HOME/.issue-watcher/pr-reviewer-artifacts/<owner_repo>/pr-<N>-<sha8>-<tool>-<ts>.log`
  CLAUDE.md 機能追加ガイドライン 6（`/tmp` 直下を避け `$HOME/.issue-watcher/` 配下を使う）に準拠。

### 4. `PR_REVIEWER_EXEC_FAIL_LIMIT` 既定値: **3**

- pr-iteration の `PR_ITERATION_NO_PROGRESS_LIMIT` 既定 3 と整合させた。
- 観測データでは 1 回の `exec-failed` だけで rate-limit を疑う必要はないが、3 回連続なら
  外部要因がほぼ確実（一時的なネットワーク揺らぎなら 1-2 回で解消する）。

## 追加した env var 一覧

| 名前 | 既定値 | 正規化方針 |
|---|---|---|
| `PR_REVIEWER_EXEC_FAIL_LIMIT` | `3` | 非数値 / 0 以下 / 空文字は `3` に正規化 |
| `PR_REVIEWER_STDERR_EXCERPT_BYTES` | `8192` | 非数値 / 0 以下 / 空文字は `8192` に正規化 |
| `PR_REVIEWER_STDERR_ARTIFACT_DIR` | `$HOME/.issue-watcher/pr-reviewer-artifacts` | 空文字なら artifact 保存 skip（fail-safe） |
| `PR_REVIEWER_STDERR_ARTIFACT_MAX_BYTES` | `1048576` (1MB) | 非数値 / 0 以下 / 空文字は `1048576` に正規化 |

## 新規追加した関数一覧

| 関数 | 責務 |
|---|---|
| `pr_extract_exec_fail_streak` | marker 文字列から (sha, streak) を抽出する純粋関数。複数 marker は末尾を採用（pr-iteration と整合） |
| `pr_read_exec_fail_streak` | `gh pr view --json body` 経由で marker を取得し (sha, streak) を返す。失敗時は安全側 `\t0`（Req 1.5） |
| `pr_write_exec_fail_streak` | `gh pr edit --body` で marker を新値で書き換え。既存 marker は sed で置換、不在時は末尾追記 |
| `pr_reset_exec_fail_streak` | 同一 sha でレビュー成功時 / sha 変化時に streak=0 で書き戻し。既に 0+sha 一致なら no-op（冪等性） |
| `pr_increment_exec_fail_streak` | exec-failed 確定時の +1 加算。sha 変化検出時は 1 から再スタート（Req 1.2 fail-safe） |
| `pr_exec_fail_limit_reached` | 上限到達判定（候補除外 / advisory コメント用）。記録 sha と現在 sha 不一致時は未到達扱い |
| `pr_truncate_stderr_tail` | `tail -c N` で末尾優先 N バイト抜粋（prompt echo に埋もれない / Req 3.4） |
| `pr_save_stderr_artifact` | `$HOME/.issue-watcher/...` 配下保存。1MB 超は末尾優先で truncate。未信頼入力検証あり |
| `pr_post_exec_fail_escalation_comment` | 上限到達時の advisory コメント 1 回投稿。(sha, kind=exec-fail-escalated) marker で重複防止 |

## 既存正常系不変の根拠

- **`pr_resolve_tool` / `pr_check_tool_installed` / `pr_check_tool_authenticated` / `pr_fetch_candidate_prs`**:
  まったく触らない（Req 4.3）。
- **`pr_run_review_for_pr` の正常系（review 投稿到達経路）**:
  - 既存の重複判定 (`pr_already_processed` for `kind=review`) を最初に通る分岐は変更なし
  - 新規追加: 当該分岐後に streak 観測ログを 1 行追加 + 上限到達判定（streak=0 + sha 一致なら従来通り）
  - 成功時の `pr_post_review_comment` 呼び出し直後に `pr_reset_exec_fail_streak` を追加したが、
    streak が既に 0 かつ sha 一致の場合は `gh pr edit` を発火しない（NFR 4.2 冪等性）
- **`kind=conflict-tool` / `kind=not-installed` / `kind=not-authenticated`**:
  `pr_broadcast_error_to_prs` 経路は完全に未改変（Req 4.4）。
- **`pr_post_error_comment` / `pr_post_review_comment` / `pr_detect_iteration_keyword` /
  `pr_add_iteration_label` / `pr_publish_codex_status` / `pr_publish_claude_status`**:
  関数本体に変更なし。呼び出し側で渡す引数（detail メッセージ）に streak 情報を含めるだけ。
- **`process_pr_reviewer` cycle start / summary log**: 既存 token は維持し、新 token
  (`exec_fail_limit` / `stderr_excerpt_bytes` / `escalated`) を末尾に追加（既存 grep の後方互換維持）。
- **既存 env var 名 / 既定値 / 受理値域**: 未変更（NFR 1.3）。

## 検証

### 静的解析

- `shellcheck local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/issue-watcher.sh local-watcher/test/pr_reviewer_exec_fail_streak_test.sh`: PASS（警告ゼロ）
- `bash -n` 両ファイル: PASS

### テスト

- 新規 `local-watcher/test/pr_reviewer_exec_fail_streak_test.sh`: **54 件 PASS / 0 件 FAIL**
- 全 61 テストファイル: **0 件 FAIL**（既存テスト破壊なし）

### root ↔ repo-template 同期

- `diff -r .claude/agents repo-template/.claude/agents`: 差分なし
- `diff -r .claude/rules repo-template/.claude/rules`: 差分なし
- `repo-template/local-watcher/` ディレクトリは存在しないため `local-watcher/` 配下の変更の
  sync は不要（CLAUDE.md「二重管理」の対象外 / `install.sh` 経由でユーザー環境に配置される）

## AC Traceability

| Requirement | 担保箇所 |
|---|---|
| Req 1.1 (streak +1 永続化) | `pr_increment_exec_fail_streak` / 呼び出し: workspace-modified / exec-failed / 空出力の 3 経路 / test Section 4 |
| Req 1.2 (sha 変化時リセット) | `pr_increment_exec_fail_streak` の sha 変化検出ロジック + `pr_reset_exec_fail_streak` / test Section 4.B / 5.C |
| Req 1.3 (成功時リセット) | `pr_run_review_for_pr` の成功 path 末尾 `pr_reset_exec_fail_streak` 呼び出し / test Section 5.B |
| Req 1.4 (永続化媒体) | PR body hidden marker `idd-claude:pr-reviewer-exec-fail-streak` / test Section 1 (extract) / 2 (read) / 3 (write) |
| Req 1.5 (read/write 失敗時の安全側) | `pr_read_exec_fail_streak` / `pr_write_exec_fail_streak` の WARN ログ + 安全側 fallback / test Section 2.B / 3.C |
| Req 1.6 (観測ログ 1 行) | `pr_run_review_for_pr` 冒頭の `pr_log "exec-fail-streak observe ..."` |
| Req 2.1 (未到達時継続) | `pr_exec_fail_limit_reached` rc=1 / test Section 6.A |
| Req 2.2 (上限到達時候補除外) | `pr_run_review_for_pr` 冒頭の `pr_exec_fail_limit_reached` チェック + 早期 return / test Section 6.B / 6.C |
| Req 2.3 (advisory コメント 1 回) | `pr_post_exec_fail_escalation_comment` + `pr_already_processed` 重複防止 / test Section 9 |
| Req 2.4 (同一 sha 継続中は抑止) | 早期 return 設計上、新 sha 観測まで再開しない / test Section 6.D |
| Req 2.5 (sha 変化時候補再投入) | `pr_exec_fail_limit_reached` の sha 不一致 → 未到達 / test Section 6.D |
| Req 2.6 (PR 独立) | 各関数が PR 番号でスコープを限定。共有状態を持たない |
| Req 2.7 (遷移先選択 = advisory のみ) | `pr_post_exec_fail_escalation_comment` 内でラベル付与経路なし / test Section 9.A |
| Req 3.1 (stderr 8KB 抜粋) | `pr_truncate_stderr_tail "$err_file" "$PR_REVIEWER_STDERR_EXCERPT_BYTES"` / test Section 7 |
| Req 3.2 (コメント本文に exit / tool / streak / sha / artifact) | exec-failed 経路の `detail` printf 拡張 |
| Req 3.3 (観測ログ 1 行) | exec-failed 経路の `pr_warn "exec-failed pr=#... sha=... tool=... exit=... streak=... artifact=..."` |
| Req 3.4 (1MB 超は末尾優先 truncate) | `pr_save_stderr_artifact` 内の `tail -c $max_bytes` 経路 / test Section 8.B |
| Req 3.5 (artifact は $HOME/.issue-watcher/ 配下) | `pr_save_stderr_artifact` 既定 `$HOME/.issue-watcher/pr-reviewer-artifacts` / test Section 8.A |
| Req 4.1 (streak=0 時の挙動不変) | 既存 review 経路を不変のまま保ち、streak=0+sha 一致時は reset が no-op |
| Req 4.2 (VERDICT → needs-iteration 経路不変) | `pr_detect_iteration_keyword` / `pr_add_iteration_label` 未改変 |
| Req 4.3 (候補列挙の挙動不変) | `pr_fetch_candidate_prs` 未改変 |
| Req 4.4 (kind=conflict-tool 等の broadcast 不変) | `pr_broadcast_error_to_prs` 未改変 |
| NFR 1.1 (PR_REVIEWER_ENABLED 経路内で既定 ON) | 本機能は `process_pr_reviewer` 内でのみ呼ばれる構造（既存設計を維持） |
| NFR 1.2 (env 不正値の安全側正規化) | issue-watcher.sh Config ブロックの case 正規化 / test Section 6（limit fixture）|
| NFR 1.3 (既存 env 不変) | 既存 env var 一切変更なし |
| NFR 1.4 (新 env は `PR_REVIEWER_` prefix / 関数は `pr_` prefix) | 命名遵守 |
| NFR 2.1 (上限既定 3) | `PR_REVIEWER_EXEC_FAIL_LIMIT="${...:-3}"` |
| NFR 2.2 (新 sha で抑止解除) | `pr_exec_fail_limit_reached` sha 不一致 → 未到達 / test Section 6.D |
| NFR 3.1 (サマリログにエスカレート件数) | `process_pr_reviewer` の summary log に `escalated=${escalated}` 追加 |
| NFR 3.2 (exec-failed WARN ログ 1 行) | exec-failed 経路の `pr_warn "exec-failed pr=#... sha=... tool=... exit=... streak=... limit=... artifact=..."` |
| NFR 4.1 (root ↔ repo-template byte 一致) | repo-template に local-watcher/ は無いため対象外。.claude/ は未変更 |
| NFR 4.2 (冪等性 / 重複コメント抑止) | `pr_reset_exec_fail_streak` no-op 分岐 / `pr_already_processed` 既存重複防止 / test Section 5.A / 9.B |
| NFR 4.3 (PR_REVIEWER_ENABLED!=true で early return) | 既存 `process_pr_reviewer` 早期 return を維持 |

## 確認事項（Reviewer / Architect への持ち越し）

- **要件矛盾なし**: 設計判断は全て requirements.md の Open Questions の安全側デフォルトに沿った
  ものを採用。Architect ステージが挟まれていないため、本 PR で Architect 判断が必要な箇所は無い。
- **既定 ON の妥当性**: NFR 1.1 は「`PR_REVIEWER_ENABLED=true` で従来運用されている消費者にとって
  既定挙動として有効化（既定 ON）」と明示しているため、追加 opt-in gate（`PR_REVIEWER_EXEC_FAIL_PROTECTION_ENABLED`
  等）は導入しなかった。env override (`PR_REVIEWER_EXEC_FAIL_LIMIT=999999`) で実質従来挙動に
  戻せるため後方互換性は維持される。
- **streak 観測ログの場所**: `pr_run_review_for_pr` 冒頭（`kind=review` 重複判定通過後）に追加した。
  Req 1.6 の「サイクル毎の観測ログ」を字義的に解釈すれば `process_pr_reviewer` の cycle start
  log に出すべきだが、PR 単位の情報なので per-PR の処理時点で出す方が運用上有用と判断した。
- **artifact dir 内のファイル累積**: 本変更では cleanup ロジックを入れていない（`Out of Scope`
  「過去サイクルで蓄積した exec-failed コメントの遡及的 cleanup」と類比的に位置付け）。将来的に
  `$HOME/.issue-watcher/pr-reviewer-artifacts/` が肥大化した場合は別 Issue で対処する。
- **`Out of Scope` 確認**: 指数バックオフ / tick 内 sleep は導入していない（tick 単位の候補除外のみ採用）。

STATUS: complete
