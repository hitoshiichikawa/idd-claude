# Implementation Notes — Issue #279

本 spec の per-task 実装中に発生した learning / 判断 / 残存課題を、Implementer
（fresh context 起動）が後続 task に引き継ぐためのメモ。

## Implementation Notes

### Task 1

- 採用方針: `core_utils.sh` 末尾の pr-reviewer 専用ロガー（`pr_log` / `pr_warn` /
  `pr_error`）の直後に `sec_log` / `sec_warn` / `sec_error` を追記し、prefix のみ
  `security-review:` に差し替えた。既存ロガー群（`qa_log` / `mq_log` / `pi_log` /
  `pr_log` 等）と完全に同じ 3 関数セットの形を踏襲。
- 重要な判断:
  - 関数の配置は `pr_log` 群の直後（既存の pr-reviewer 関連まとまりの末尾）に置き、
    `claude_log_detect_529` セクション（`# ─── Issue #259: ...` 罫線見出し）の前に
    挿入することで、ロガー群の連続性を保ちつつ既存 detector セクションへの干渉を避けた。
  - prefix 文字列は spec 指定どおり `security-review:`（ハイフン区切り、`:` の後に
    半角スペース 1 個）。これは後続 task で `sec_resolve_*` / `sec_run_review_for_pr`
    のログ出力でそのまま使われる。
  - `set -euo pipefail` は本モジュールでは宣言せず、本体 (`issue-watcher.sh`) 側の
    宣言を継承する既存規約に従った（モジュール冒頭の依存コメントに明記されている方針）。
- 残存課題:
  - なし。後続 task 2 以降は `sec_log` / `sec_warn` / `sec_error` を `modules/security-review.sh`
    から自由に呼び出せる前提で実装してよい（bash の遅延束縛により、本体 source 完了後に解決される）。

### Task 2

- 採用方針: `pr-reviewer.sh` の純粋関数群（`pr_build_marker` / `pr_fetch_candidate_prs` /
  `pr_already_processed`）を雛形に踏襲しつつ、marker prefix を
  `idd-claude:security-review` に置換、env 名を `SECURITY_REVIEW_*` に置換、
  WARN 関数を `sec_warn` に置換することで一貫した実装にした。
- 重要な判断:
  - **marker から tool= 属性を除外**: pr-reviewer は `codex` / `antigravity` の排他選択を
    扱うため tool= を marker に焼き込んでいるが、Security Review は単一実行ツール
    （`claude` CLI のみ）のため tool 識別子を marker に持たせない（design.md「State /
    Marker Contract」節 / Req 6.4 と一致）。これにより `sec_build_marker` の引数は
    `(sha, kind)` の 2 引数のみとなり、`sec_post_*_comment` 系（次 task 3.2 で実装）も
    シグネチャを簡素化できる
  - **`sec_resolve_spec_dir` の glob 件数判定**: bash の `nullglob` を一時的に有効化して
    マッチ 0 件時の glob リテラル残留を防止。呼び出し元の shopt 状態を破壊しないよう
    `shopt -q nullglob` で事前状態を退避し、関数末尾で元の状態に復元する設計とした。
    `BASH_REMATCH` で issue 番号を抽出後、配列展開 `("${REPO_DIR}/docs/specs/${issue_num}-"*/)`
    で件数判定し、1 件マッチで末尾スラッシュを除去した絶対パスを stdout 出力する
  - **`sec_check_strict_request` の WARN 経路**: `SECURITY_REVIEW_MODE` と
    `SECURITY_REVIEW_STRICT` の 2 env を独立検査し、いずれかに `advisory` 以外の値が
    入っていたら WARN を 1 行ずつ記録（両方非空なら WARN 2 行）。stdout には常に
    `advisory` 単一 token を返し、観測ログは stderr 側で完全分離する
  - **失敗時の fail-safe 方針**: `sec_already_processed` の gh API 失敗時は安全側で
    「既存扱い (rc=0)」を返し重複投稿を防ぐ（pr-reviewer と同方針）。`sec_fetch_candidate_prs`
    は WARN + `[]` で degraded path に倒し、サイクル全体を阻害しない
- 残存課題:
  - なし。本 task は純粋関数群のみで副作用を持たないため task 3 以降に伝播する制約はない。
    本モジュールはまだ `REQUIRED_MODULES` に未登録のため watcher 経由の動作確認は不可（次 task 4.3
    で登録予定）。スキャン実行系（`sec_execute_security_review` / `sec_post_*_comment` /
    `sec_write_security_notes` / `sec_run_review_for_pr` / `process_security_review`）と
    issue-watcher.sh への配線（Config / REQUIRED_MODULES / dispatcher call site）は
    次 task 3〜4 fresh 起動で追加する。

### Task 3

- 採用方針: `pr-reviewer.sh` の `pr_build_prompt_file` / `pr_substitute_placeholders` /
  `pr_execute_review_command` / `pr_post_review_comment` / `pr_post_error_comment` /
  `pr_run_review_for_pr` を雛形に踏襲し、tool= 属性のない 2 引数 marker（task 2 で確立）と
  単一実行ツール（claude CLI）前提に合わせて簡素化した。スキャン実行系（subshell + EXIT
  trap + read-only invariant 検査）と severity 集計 + security-notes.md 書き出しを追加。
- 重要な判断:
  - **prompt 渡し経路の二段対応**: design.md「CLI 起動契約」節の既定
    `SECURITY_REVIEW_CLAUDE_CMD` は `claude -p "$SECURITY_REVIEW_PROMPT" ...` の形で
    parent shell の env 変数を `bash -c` の subshell に継承させる経路を期待している。
    一方、pr-reviewer は `{PROMPT_FILE}` プレースホルダ + `$(cat '...')` 経路で argv に
    渡す方式を採用している。本実装は両経路に対応できるよう、`sec_build_prompt_file` で
    tempfile を作成 + `sec_substitute_placeholders` で `{PROMPT_FILE}` 置換 + `{BASE}/{HEAD}/{PR}`
    置換を行い、tempfile path を含む resolved_cmd を生成する。design.md 既定値は
    `SECURITY_REVIEW_PROMPT` env 経由でも動くため、運用者が `SECURITY_REVIEW_CLAUDE_CMD` を
    override して `--prompt-file {PROMPT_FILE}` 経路を選んでも互換性を保つ
  - **SECURITY_REVIEW_PROMPT の env 継承前提**: `sec_execute_security_review` は
    `bash -c "$resolved_cmd"` で subshell を起動するが、bash は parent shell の env を
    継承するため `$SECURITY_REVIEW_PROMPT` は subshell からも参照可能（export 不要）。
    issue-watcher.sh 本体は単一プロセスで全 processor を直列実行する設計のため、
    Config ブロックの `SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"` 解決
    （task 4.2 で追加予定）が本実装の動作前提となる
  - **severity 集計の近似実装**: review_text を完全 parse せず、`grep -E -i -c '\b<sev>\b'`
    で行カウントする近似実装を採用。Req 3.2 の「severity を含める」は Claude 側の出力に
    委ね、`security-notes.md` の Severity Summary 表は運用者向けの目安として記録する
    （正確な集計は人間判断 / 別 Issue 拡張対象）。0 件時は全 0、total は 5 種合算
  - **クリーン判定の単純センチネル**: `SECURITY_REVIEW_CLEAN` 行を grep `-qE` で検出する
    単純判定（design.md「CLI 起動契約」節の prompt 規約に依拠）。出力スキーマに依存せず、
    Skill tool 経由起動が失敗したケース（空出力）と区別できる
  - **kind=scan-failed 一本化**: 本 spec で実際に使用するエラー kind は `scan-failed` のみ
    （workspace-modified / exec-failed / empty-output / fetch-fail / checkout-fail を
    すべて scan-failed marker に集約）。pr-reviewer は kind を分岐させていたが、Security
    Review は marker 名前空間が独立しているため簡素化した。`sec_post_error_comment` の
    kind 引数は将来拡張のためインタフェースとして残す
  - **security-notes.md 原子書き出し**: tempfile に出力後 `mv` で置換し、書き込み途中
    状態を残さない。idempotency は `head -n 20 | grep -qF "Last SHA: <sha>"` で先頭付近の
    SHA 行と一致する場合 overwrite skip
- 残存課題:
  - **issue-watcher.sh 本体への配線は task 4 範囲**: 本 task では `process_security_review`
    entrypoint および Config ブロック / REQUIRED_MODULES / dispatcher call site は実装
    していない。`sec_run_review_for_pr` 単体では watcher サイクル全体は動作しない（次
    task 4 fresh 起動で配線予定）
  - **SECURITY_REVIEW_PROMPT 既定値の解決**: 本 task で実装した関数群は parent shell の
    env に `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` / `SECURITY_REVIEW_MODEL` /
    `SECURITY_REVIEW_GIT_TIMEOUT` / `SECURITY_REVIEW_EXEC_TIMEOUT` が解決済みであることを
    前提とする。task 4.2 で Config ブロック追加が完了するまで本機能は単体動作しない
  - **review_text コメントへの直接投稿**: Claude 出力をそのまま PR コメント本文に
    `gh pr comment --body` で渡すため、PR コメント API の上限（65,536 文字）を超えるケース
    は未対応。実機で長大な review_text が観測された場合は truncate 処理を別 Issue で検討

### Task 4

- 採用方針: 既存 `process_pr_reviewer` (#261) の cycle / truncate / loop パターンを完全に
  踏襲し、entrypoint `process_security_review` を `modules/security-review.sh` 末尾に追加、
  issue-watcher.sh の Config ブロック（PR Reviewer 節の直後）+ REQUIRED_MODULES 末尾 +
  dispatcher call site（PR Reviewer 直後・PR Iteration 直前）の 3 点配線を完了。
- 重要な判断:
  - **rc 集計の簡素化**: `sec_run_review_for_pr` の戻り値 `0/1/2/3` を
    `reviewed/fail/skip/errored` の 4 カテゴリにのみ集計し、`clean` / `notes_written` /
    `notes_skipped` の内訳は marker kind ログ（`kind=security-review-clean` /
    `security-notes.md 書き出し成功` 等）から事後識別する設計とした。サマリログには
    プレースホルダ値 0 を残し、運用者が grep でログ集計可能（pr-reviewer 同型の方針）。
    完全な内訳集計を望む場合は別 Issue で追加する余地を残す
  - **Config ブロックの SECURITY_REVIEW_PROMPT 既定値**: design.md「CLI 起動契約」節の
    記述どおり、Skill tool 経由 `/security-review` 起動を誘発する英文 + 末尾の
    `SECURITY_REVIEW_CLEAN` センチネル出力指示を 1 行で記述。`origin/${BASE_BRANCH:-main}`
    の `${BASE_BRANCH:-main}` は Config 解決時に展開される（先行行で `BASE_BRANCH` が
    既に解決済みのため）。一方 `SECURITY_REVIEW_CLAUDE_CMD` の `\$SECURITY_REVIEW_PROMPT`
    はバックスラッシュエスケープでリテラル温存し、`bash -c` subshell が env から展開する
    （pr-reviewer の `\$(cat '{PROMPT_FILE}')` と同形のリテラル温存パターン）
  - **strict 関連 env を導入しない**: `SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY`
    / `SECURITY_REVIEW_BLOCK_LABEL` 等の strict 関連 env は本 spec で Config ブロックに
    **含めない**（別 Issue #281 待ち）。`sec_check_strict_request` は env が来た場合のみ
    WARN + advisory fallback で吸収するため、Config 側の宣言は不要（Req 5.3 確定）
  - **dispatcher call site の配置根拠コメント**: 既存 `process_pr_reviewer` 直後・
    `process_pr_iteration` 直前の理由（advisory のためラベル競合なし / PR タイムライン上の
    時系列 / NFR 1.1 byte 等価）をコメントブロックに明示。将来 strict 拡張が別 Issue で
    導入された際にも本配置を維持する根拠が読み取れる
  - **dry run 検証**: REPO_DIR が GitHub remote を持たない環境では watcher が早期 fail する
    ため、stub gh で `process_security_review` を単独呼び出して `cycle start: mode=advisory ...`
    と `サマリ: ... reviewed=0 clean=0 ...（候補 PR なし）` の 2 行が記録されること、および
    `SECURITY_REVIEW_ENABLED` 未設定時には 1 行も出ないこと（NFR 1.1 byte 等価）を確認済み
- 残存課題:
  - **README ドキュメント追記は task 5 範囲**: 「オプション機能一覧」§ と新規 h2
    「Security Review Processor (#279)」節の追加は次 task 5 fresh 起動で実施する
    （本 task では README に手を入れていない / NFR 6.1）
  - **静的解析 + 二重管理ドリフト + cron-like PATH 解決のフルバッテリ verify は task 6 範囲**:
    本 task では task 4 の AC 検証用に `shellcheck` 3 ファイル / `bash -n` / grep 配線確認 /
    isolated process_security_review smoke の最小セットのみ実行。task 6 の構造化 verify
    ブロック全量（install.sh / setup.sh / .github/scripts/*.sh / actionlint /
    `diff -r .claude/...`）は次起動で実施する

STATUS: complete
