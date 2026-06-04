# Implementation Plan

- [x] 1. Config ブロック: `SECURITY_REVIEW_PROMPT` / `SECURITY_REVIEW_CLAUDE_CMD` を export 化
  - `local-watcher/bin/issue-watcher.sh` の Security Review Processor 設定（L301-L337 周辺）
    のうち、L316 の `SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"` 宣言を
    `export SECURITY_REVIEW_PROMPT="${SECURITY_REVIEW_PROMPT:-...}"` 形式へ変更する
  - L329 の `SECURITY_REVIEW_CLAUDE_CMD="${SECURITY_REVIEW_CLAUDE_CMD:-...}"` も同様に
    `export SECURITY_REVIEW_CLAUDE_CMD="${SECURITY_REVIEW_CLAUDE_CMD:-...}"` 形式へ変更する
  - 既定値の文字列リテラル（`claude -p "$SECURITY_REVIEW_PROMPT" ...` 形式）は変更しない
    （Req 4.3 / NFR 1.2 の意味的内容温存）
  - 他の `SECURITY_REVIEW_*` env（`_ENABLED` / `_MODEL` / `_MAX_TURNS` / `_MAX_PRS` /
    `_HEAD_PATTERN` / `_GIT_TIMEOUT` / `_EXEC_TIMEOUT` / `_MODE` / `_BLOCK_SEVERITY` /
    `_BLOCK_LABEL` 等）は export しない（design.md「補強範囲を 2 変数に限定する理由」節
    参照）
  - L323-L328 のコメント「既定値中の `\$SECURITY_REVIEW_PROMPT` はリテラル保持し、bash -c
    subshell が env から展開する」は温存し、export が必要な理由を 1〜2 行のコメントで補強
    する
  - _Requirements: 1.1, 1.2, 4.1, 4.2, 4.3, NFR 1.1, NFR 1.2_

- [x] 2. `sec_execute_security_review` に空プロンプト・フェイルセーフを追加
  - `local-watcher/bin/modules/security-review.sh` の `sec_execute_security_review`
    （L559-L603）の subshell 内、`git checkout` 成功後・`timeout ... bash -c "$resolved_cmd"`
    起動の **直前** に空プロンプトガードを追加する
  - 追加内容: `if [ -z "${SECURITY_REVIEW_PROMPT:-}" ]; then sec_warn "..." ; printf 'empty-prompt\n' > "$result_file"; exit 0; fi`
  - `sec_warn` メッセージには「empty-prompt」識別語を含め、他の失敗原因（fetch-fail /
    checkout-fail / ran:*:modified / 非ゼロ終了 / 空出力）と運用者が区別できる形にする
    （NFR 2.2）
  - read-only invariant 検査（`git status --porcelain`）は本ガード経路では走らせない
    （CLI 未起動のためワークツリー変更は構造的に発生しない / design.md Components 節）
  - 既存 result_file token プロトコル（`fetch-fail` / `checkout-fail` / `ran:<rc>:<state>`）と
    名前空間衝突しないことを既存 case 文と突き合わせて確認する
  - _Requirements: 1.3, NFR 2.2_
  - _Depends: 1_

- [x] 3. `sec_run_review_for_pr` の case 分岐に `empty-prompt` 経路を追加
  - `local-watcher/bin/modules/security-review.sh` の `sec_run_review_for_pr` 内、result_file
    token 解析の case 文（L910-L915 周辺の `fetch-fail|checkout-fail)`）の後ろに
    `empty-prompt)` 分岐を追加する
  - 分岐処理: `sec_error` で「empty-prompt」識別語を含む 1 行を出し、
    `sec_post_error_comment "$pr_number" "$sha" "scan-failed" "<empty-prompt 識別文面>"`
    を呼び `return 3`（既存 scan-error 集計に合流 / Req 1.3）
  - エラーコメント本文には `SECURITY_REVIEW_PROMPT` の env 継承確認手順または
    `SECURITY_REVIEW_CLAUDE_CMD` の `{PROMPT_FILE}` 経路への切替検討を運用者向けに記載する
  - 既存「空出力なら scan-failed」分岐（L950-L955）は **温存**（CLI 起動後の output 側
    チェックとして独立 / design.md Error Handling 節）
  - _Requirements: 1.3, 3.3, NFR 2.2_
  - _Depends: 2_

- [x] 4. shellcheck 警告ゼロ確認 + コメント整合性確認
  - 変更ファイル 2 件（`local-watcher/bin/issue-watcher.sh` /
    `local-watcher/bin/modules/security-review.sh`）に対し `shellcheck` を実行し、警告ゼロを
    確認する（既存 `.shellcheckrc` で抑止された info 級は許容）
  - `local-watcher/bin/modules/security-review.sh` L555-557 のコメント「parent env に解決済み
    であるため」の表現を「Config ブロックで export 済みであるため」相当へ更新する
    （NFR 4.1 ドキュメント整合）
  - README の「オプション機能一覧」相当節を確認し、Security Review Processor の env 表記が
    本修正と矛盾しないことを確認、必要箇所のみ更新する（NFR 4.1）
  - _Requirements: NFR 3.1, NFR 4.1_
  - _Depends: 3_

- [x] 5. スモーク fixture を追加（export 継承 + 空プロンプト・フェイルセーフ）
  - `docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/` ディレクトリを
    作成し、以下の bash スモークスクリプトを配置する:
    - `test-export-inheritance.sh`: Config ブロックを source した上で
      `bash -c 'echo "$SECURITY_REVIEW_PROMPT"'` の子シェル出力が非空 default 値（先頭が
      `Use the /security-review skill` で始まる文字列）と一致することを確認
      （Req 1.1 / 1.2）
    - `test-empty-prompt-shortcircuit.sh`: `SECURITY_REVIEW_PROMPT=""` 状態で
      `sec_execute_security_review` のガード分岐を直接実行できる最小ハーネスを組み、
      result_file が `empty-prompt\n` であることと、ワークツリー変更が `git status --porcelain`
      で検出されないことを確認（Req 1.3）
    - `test-env-i-minimal.sh`: `env -i HOME=$HOME PATH=/usr/bin:/bin` で minimal env を構築
      し、`SECURITY_REVIEW_ENABLED=true SECURITY_REVIEW_PROMPT=test-prompt` で Config ブロック
      解決後の子シェル env が `test-prompt` を見えることを確認（NFR 1.3）
  - 各スクリプト末尾で `echo "OK: <test-name>"` を出し、非ゼロ exit で失敗を伝える既存
    fixture 慣習に揃える
  - _Requirements: 1.1, 1.2, 1.3, NFR 1.3, NFR 2.2_
  - _Depends: 3_

- [ ]* 6. opt-out 完全 no-op の回帰確認スモーク（deferrable）
  - `docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-opt-out-noop.sh`
    を追加し、`SECURITY_REVIEW_ENABLED=false`（および未設定 / `0` / `True` 等の typo）状態で
    `process_security_review` が戻り値 0 / 標準出力空 / `_sec_resolved_mode` 等のグローバル
    未設定 状態を返すことを確認する
  - 既存 #279 / #281 の opt-out 完全 no-op 挙動を本修正が壊していないことの defense-in-depth
  - _Requirements: 3.1, NFR 1.1_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを以下の構造化
ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/security-review.sh && \
  bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-export-inheritance.sh && \
  bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-empty-prompt-shortcircuit.sh && \
  bash docs/specs/286-fix-watcher-security-review-processor-sc/test-fixtures/test-env-i-minimal.sh
```
