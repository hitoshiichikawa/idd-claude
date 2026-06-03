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
