# Implementation Plan

- [x] 1. core_utils.sh に sec_log / sec_warn / sec_error ロガー 3 関数を追加
  - 既存 `pr_log` / `pi_log` / `mq_log` と同形式（`[$(date '+%F %T')] [$REPO] security-review: $*`）で末尾に追記
  - `sec_warn` / `sec_error` は `>&2` に出力
  - 既存ロガー関数は変更しない（追記のみ）
  - shellcheck `local-watcher/bin/modules/core_utils.sh` が警告ゼロ
  - _Requirements: NFR 3.1, NFR 5.1_

- [x] 2. modules/security-review.sh を新規作成し、純粋関数群（marker / mode 解決 / 候補抽出 / 既存判定）を実装
- [x] 2.1 ファイル冒頭コメント（用途・配置先・依存・セットアップ参照先）と関数スケルトンを配置
  - 既存 `modules/pr-reviewer.sh` 冒頭の comment スタイルに倣う
  - `set -euo pipefail` は本体側で宣言済みのため宣言しない
  - _Requirements: NFR 1.1, NFR 5.1_
- [x] 2.2 `sec_build_marker` を実装（`<!-- idd-claude:security-review sha=<sha> kind=<kind> -->` を stdout 出力）
  - 引数: `$1 = sha`, `$2 = kind`（`security-review` / `security-review-clean` / `scan-failed`）
  - 末尾改行なし
  - _Requirements: 3.4, 6.1, 6.4_
- [x] 2.3 `sec_check_strict_request` を実装（strict 要求 env が来ても WARN + advisory 固定で続行）
  - `SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_STRICT` 等の env が `advisory` 以外なら WARN 1 行
    （「strict は本 spec 未実装 / 別 Issue 待ち」）後、stdout に常に `advisory` を 1 行
  - 未設定 / 空 / `advisory` → 無言で `advisory` を stdout
  - _Requirements: 5.1, 5.2, 5.3_
- [x] 2.4 `sec_fetch_candidate_prs` を実装（`gh pr list` + jq フィルタ）
  - server-side: `--state open --search "-draft:true"`
  - client-side fail-safe: `select(.isDraft == false)` + `select(.headRefName | test($pattern))` + `select(.headRepositoryOwner.login == $owner)`
  - 取得失敗時は WARN + `echo "[]"` で degraded path
  - _Requirements: 2.1, 2.3_
- [x] 2.5 `sec_already_processed` を実装（既存コメント走査で `(sha, kind)` AND 一致を判定）
  - `gh api /repos/$REPO/issues/<n>/comments` + `jq -e any(.[]; (.body // "") | test("idd-claude:security-review sha=" + $sha + "[^>]*kind=" + $kind))`
  - kind 3 値（`security-review` / `security-review-clean` / `scan-failed`）すべてで動作
  - 取得失敗時は安全側で「既存扱い (rc=0)」に倒し重複投稿を防ぐ
  - _Requirements: 2.4, 6.2, 6.3, NFR 4.1_
- [x] 2.6 `sec_resolve_spec_dir` を実装（ブランチ名から spec ディレクトリを解決）
  - 入力: `$1 = pr_branch`（例: `claude/issue-279-design-feat-watcher-security-review-opt-in-pr-d`）
  - 解決順序: ブランチ名から `^claude/issue-(\d+)-` で issue 番号抽出 → `docs/specs/<番号>-*/` glob → 1 件マッチで採用、0 件 / 2 件以上で空文字
  - 戻り値 0 固定（特定不可は空文字で表現）
  - _Requirements: 3.5_

- [ ] 3. スキャン実行とコメント投稿の関数群を実装
- [x] 3.1 `sec_execute_security_review` を実装（subshell + EXIT trap + read-only invariant 検査）
  - 引数: head_ref / base_ref / pr_number / out_file / err_file / result_file
  - subshell 内で `git fetch origin <head>` → `git checkout -B <head> origin/<head>` を timeout 付きで実行
  - `eval` 不使用、`bash -c "$resolved_cmd"` で実行
  - 実行後 `git status --porcelain` で workspace 変更検査、検出時は `git checkout -- .` で破棄し `result=ran:<rc>:modified` を記録
  - 結果トークン: `fetch-fail` / `checkout-fail` / `ran:<rc>:clean` / `ran:<rc>:modified`
  - 既存 `pr_execute_review_command`（#261 pr-reviewer.sh）と同形パターン
  - _Requirements: 2.2, 2.6, NFR 4.1_
- [x] 3.2 `sec_post_review_comment` / `sec_post_clean_comment` / `sec_post_error_comment` を実装
  - 共通: 本文末尾に `sec_build_marker` で marker を埋め込む
  - `sec_post_review_comment`（kind=security-review）: 冒頭に `## セキュリティレビュー結果`
    見出し + 検出件数行 + review_text 本文
  - `sec_post_clean_comment`（kind=security-review-clean）: 冒頭に
    `## セキュリティレビュー結果: クリーン` 見出し + 「検出 0 件 / モデル名 / skill 名」
    の 1〜2 行（Req 3.3 確定）
  - `sec_post_error_comment`（kind=scan-failed）: 冒頭に
    `## セキュリティレビュー結果（実行エラー）` 見出し + `sec_already_processed` で
    `(sha, kind)` 重複を事前判定し既存なら skip
  - 投稿失敗時は WARN + rc=1
  - _Requirements: 2.6, 3.1, 3.2, 3.3, 3.4, 6.1, 6.2, 6.4_
- [x] 3.3 `sec_write_security_notes` を実装（spec ディレクトリ配下に `security-notes.md` を出力）
  - 入力: pr_number / sha / spec_dir / finding_count / severity_summary / review_text
  - spec_dir が空文字またはディレクトリ不在 → WARN 1 行 + return 0（書き出し skip / 安全側）
  - 既存ファイルの先頭付近に `Last SHA: <sha>` 行が同一であれば overwrite skip（idempotency / NFR 4.1）
  - フォーマット: design.md「`security-notes.md` フォーマット」節のテンプレートに従う
    （H1 タイトル + hidden marker + Last SHA / Last Run / Model / Skill / Finding Count
    ヘッダー + Severity Summary 表 + Findings 本文）
  - 書き出し失敗は WARN + rc=1（PR コメント投稿側を阻害しない）
  - _Requirements: 3.5, NFR 4.1_
- [ ] 3.4 `sec_run_review_for_pr` を実装（1 PR 分のスキャン統括）
  - 重複判定（`kind=security-review` / `kind=security-review-clean` のいずれかの marker
    が既存なら rc=2 で skip）
  - prompt / cmd template 展開（`SECURITY_REVIEW_PROMPT` + `SECURITY_REVIEW_CLAUDE_CMD`
    プレースホルダ置換、shell metacharacter 検査）
  - `sec_execute_security_review` 呼び出し → 結果トークン分岐
  - 出力末尾に `SECURITY_REVIEW_CLEAN` センチネル行を検出 → 検出 0 件と判定 →
    `sec_post_clean_comment` + `sec_write_security_notes`（件数 0）
  - センチネル不在 + 出力非空 → 検出 ≥ 1 件と判定 → `sec_post_review_comment` +
    `sec_write_security_notes`（実件数）
  - 失敗系（exec rc != 0 / workspace modified / 出力空 / Skill tool 経由起動失敗の
    ヒューリスティック判定）→ `sec_post_error_comment` 投稿
  - spec ディレクトリ解決は `sec_resolve_spec_dir` 経由（特定不可なら notes 書き出し skip
    のみ、PR コメントは通常投稿）
  - _Requirements: 2.2, 2.4, 2.6, 3.1, 3.2, 3.3, 3.4, 3.5, 6.1〜6.4_

- [ ] 4. entrypoint `process_security_review` を実装し、issue-watcher.sh に配線
- [ ] 4.1 `process_security_review` を実装（opt-in gate / strict 検出 / 候補列挙 / truncate / ループ / サマリ）
  - 早期 return: `[ "${SECURITY_REVIEW_ENABLED:-false}" != "true" ] && return 0`（1 行ログ）
  - `sec_check_strict_request` を呼び advisory 固定値を取得（strict 要求検出時の WARN を含む）
  - サイクル開始サマリ: `mode=advisory max_prs=N git_timeout=Ns exec_timeout=Ns head_pattern=... model=claude-opus-4-8`
  - 候補 0 件 → サマリログのみで return
  - `SECURITY_REVIEW_MAX_PRS` で truncate（total / target / overflow をログ、既存 #261 踏襲）
  - 各 PR で `sec_run_review_for_pr` を呼び rc 集計
  - サイクル終了サマリ: `reviewed=N clean=N skip=N fail=N errored=N overflow=N notes_written=N notes_skipped=N`
  - 最後に保険で `git checkout "$BASE_BRANCH"` で復帰
  - return 0 固定（dispatcher fail-continue）
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.5, 5.1, 5.2, 5.3, NFR 1.1, NFR 3.1_
- [ ] 4.2 `issue-watcher.sh` Config ブロックに env var 群を追加 (P)
  - 既存 `# ─── PR Reviewer Processor 設定 (#261) ───` 節の **後** に新規節
    `# ─── Security Review Processor 設定 (#279) ───` を追加
  - env var を `${VAR:-default}` 形式で解決（design.md「Environment Variables」表に従う:
    `SECURITY_REVIEW_ENABLED` / `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` /
    `SECURITY_REVIEW_MODEL`（既定 `claude-opus-4-8`）/ `SECURITY_REVIEW_MAX_TURNS` /
    `SECURITY_REVIEW_HEAD_PATTERN` / `SECURITY_REVIEW_MAX_PRS` /
    `SECURITY_REVIEW_GIT_TIMEOUT` / `SECURITY_REVIEW_EXEC_TIMEOUT`）
  - **strict 関連 env（`SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` 等）は
    本 spec で導入しない**（別 Issue で確定）
  - 既存 `_idd_flag` 正規化ループには **含めない**（opt-in 機能のため）
  - 既存 env var の名前・既定値・既存 Config ブロックは変更しない
  - _Requirements: 1.1, 5.1, 5.3, NFR 1.1, NFR 1.2_
  - _Boundary: issue-watcher.sh Config block_
- [ ] 4.3 `REQUIRED_MODULES` 配列に `"security-review.sh"` を追加 (P)
  - 末尾追加（順序は機能的任意 / bash 遅延束縛）
  - _Requirements: NFR 1.1_
  - _Boundary: issue-watcher.sh REQUIRED_MODULES_
- [ ] 4.4 dispatcher call site に `process_security_review` 呼び出しを 1 行追加
  - 既存 `process_pr_reviewer || pr_warn "..."` の **直後**、
    `process_pr_iteration || pi_warn "..."` の **直前** に配置
  - `process_security_review || sec_warn "process_security_review が想定外のエラーで終了しました（後続 Issue 処理は継続）"`
  - 既存 fail-continue 規約踏襲
  - _Requirements: 1.3, 4.4, NFR 1.1_
  - _Boundary: issue-watcher.sh dispatcher call site_

- [ ] 5. README.md にドキュメント追記（同一 PR 内で実施 / NFR 6.2）
  - 「オプション機能一覧」§ の opt-in 表に `SECURITY_REVIEW_ENABLED` 行を追加
  - 新規 h2 セクション「Security Review Processor (#279)」を `## PR Reviewer Processor (#261)` の **直後** に追加
  - 含める内容: 概要 / advisory 固定の旨 / 既定 OFF / 動作フロー / 環境変数表（モデル既定値
    `claude-opus-4-8` を明示）/ 利用例 cron 行 / クリーン時にもコメント投稿される旨 /
    `security-notes.md` が `docs/specs/<番号>-<slug>/` 配下に runtime で書き出される旨 /
    既知の制約（strict 拡張は **別 Issue として分割済み**、本 spec では未実装）/
    Migration Note（既存ユーザー向け、env 未設定なら byte 等価）
  - 言語方針に従い日本語ベース、env var 名は英語固定
  - _Requirements: NFR 6.1, NFR 6.2_

- [ ] 6. 静的解析と手動スモークテスト
  - `shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` が警告ゼロ
  - `actionlint .github/workflows/*.yml` が警告ゼロ（本機能で workflow 変更はないが既存ベースラインの非回帰確認）
  - `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` が空（本機能で agents/rules を編集しないことの確認 / NFR 7.2）
  - cron-like 最小 PATH 解決スモーク: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git'` が成功
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo SECURITY_REVIEW_ENABLED=true $HOME/bin/issue-watcher.sh` を対象なし状態で流し、`security-review:` prefix の opt-in 有効サマリログが 1 行記録され、他既存ログが本機能導入前と非回帰
  - opt-in OFF（`SECURITY_REVIEW_ENABLED` 未設定）で同 watcher を流し、`security-review:` prefix ログが 1 行も出ないこと（NFR 1.1 byte 等価）
  - _Requirements: NFR 1.1, NFR 5.1, NFR 7.2_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の
構造化ブロックで宣言する。bash モジュール / 本体 / 既存スクリプト群への shellcheck と
workflow YAML への actionlint、および root ↔ repo-template の二重管理ドリフト検査を併せる。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/security-review.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh && \
  actionlint .github/workflows/*.yml && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
