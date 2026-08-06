# Implementation Plan

各タスクは 1 commit 単位で独立完了可能。導入順は「config gate → module → call site 配線 →
版管理 → ドキュメント → 全体検証」。opt-in gate `SPEC_HTML_ENABLED` は既定 OFF のため、各タスク
commit 時点で未設定環境の観測可能挙動は導入前と不変（NFR 1.1）。

- [x] 1. watcher-config.sh に SPEC_HTML_* gate と正規化を追加
  - `local-watcher/bin/watcher-config.sh` の opt-in gate 群近傍（`AUTO_REBASE_MODE` 等の `case` 正規化前例に倣う）へ
    `SPEC_HTML_ENABLED`（既定 `false` / `true` 厳密一致のみ ON・他は `case` で `false` に正規化）を追加（Req 1.1, 1.3）
  - 併せて `SPEC_HTML_RENDER_BIN`（既定 `pandoc`）/ `SPEC_HTML_RENDER_CMD`（既定 `pandoc -f gfm -t html5 -s -o {OUT} {IN}`）/
    `SPEC_HTML_TIMEOUT`（既定 `60` / 非整数・≤0 は `60` へ正規化）/ `SPEC_HTML_TARGETS`
    （既定 `requirements.md design.md tasks.md impl-notes.md review-notes.md`）を定義（design env 表と一致）
  - 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `BASE_BRANCH` 等）は不変（NFR 1.2）。
    既定有効化フラグの正規化ループには加えない（opt-in 既定 OFF のため / `AUTO_REBASE_MODE` と同扱い）
  - 正規化のシェルレベル回帰テストを本タスク内に追加（`SPEC_HTML_ENABLED` の `true`/未設定/空/`True`/`1`/typo →
    ON/OFF 判定、`SPEC_HTML_TIMEOUT` の非整数・負値 → 既定 60。source 後の値検証。安全側 fallback の AC のため同 task 内必須）
  - _Requirements: 1.1, 1.3_

- [x] 2. spec-html.sh module を実装し REQUIRED_MODULES へ登録
  - `local-watcher/bin/modules/spec-html.sh` を新規作成（prefix `shx_` / 関数定義のみ・トップレベル副作用なし /
    ファイル冒頭に用途・配置先・依存・prefix・family 非該当を明記。`tasks-count-gate.sh` のヘッダ様式を踏襲）
  - 公開関数を実装（design「Service Interface」準拠）: `shx_log`/`shx_warn`/`shx_error`（prefix `spec-html:` / grep 可能 3 段）、
    `shx_enabled`（`SPEC_HTML_ENABLED == true` 厳密一致 / Req 1.2）、`shx_render_available`（`command -v "$SPEC_HTML_RENDER_BIN"` /
    不在で warn+1 / Req 5）、`shx_target_files`（`SPEC_HTML_TARGETS` basename allowlist の実在 regular file のみ絶対パス列挙 / Req 2.2, 2.3）、
    `shx_html_path`（`<name>.md`→`<name>.html` 純粋 / Req 2.4）、`shx_render_one`（`SPEC_HTML_RENDER_CMD` の `{IN}`/`{OUT}` 置換 +
    `timeout "$SPEC_HTML_TIMEOUT"` 実行 / 成功時 .html 生成・失敗は対象名付き warn + 非 0 / Req 2.5, 4.2, 5.2）、
    `shx_run_for_spec_dir`（gate→available→列挙→各 `shx_render_one`→成功/失敗件数 summary log / **常に return 0** / Req 5.1, 5.3, NFR 3.1）
  - `.md` は read-only 入力とし一切書き換えない（.html のみ Write / Req 3.1）。外部ネットワーク / gh を呼ばない（ローカル生成 / Req 6.1）
  - 未信頼入力対策: spec dir path は `NUMBER`（`^[0-9]+$` 既検証）+ 固定 basename allowlist から構成し、変数は全 quote、
    allowlist 外・path 構成要素の異常は列挙から除外（NFR 5.1）
  - `local-watcher/bin/issue-watcher.sh` の `REQUIRED_MODULES` 配列へ `"spec-html.sh"` を 1 要素追加（slot-worker.sh より前に配置）
  - `local-watcher/test/spec-html_test.sh` を新規追加（`extract_function` 隔離抽出 + `test/lib/test-helpers.sh` source）。
    `shx_enabled`（true のみ ON / typo OFF）、`shx_html_path`、`shx_target_files`（実在のみ列挙）、`shx_render_available`（stub コマンド存在/不在）、
    `shx_run_for_spec_dir`（gate OFF no-op return 0 / CLI 不在 skip return 0 / render stub 失敗でも return 0）を live 依存なしで検証
    （failure-path / safety fallback の AC のため同 task 内必須）
  - _Requirements: 1.2, 2.2, 2.3, 2.4, 2.5, 3.1, 4.2, 5.1, 5.2, 5.3, 6.1_
  - _Depends: 1_

- [x] 3. slot-worker.sh の design / impl 完了直後に生成 hook を配線
  - `local-watcher/bin/modules/slot-worker.sh` `_slot_run_issue` の design 分岐 rc=0 case、
    `tc_run_post_architect_check || true` の **直後**に `shx_run_for_spec_dir || true` を 1 行追加（design 段 / Req 2.1, 4.1）
  - 同関数 impl 分岐 `_impl_rc` case 0（`✅ ... 完了`）に `shx_run_for_spec_dir || true` を 1 行追加（impl 段 / impl-notes・review-notes を含む / Req 2.1, 4.1）
  - 双方 `|| true` で fail-open。gate OFF 時は module 早期 return で副作用ゼロ（Req 1.4）。機械ゲート / エージェント連携の .md 契約には一切触れない
    （.html を読む経路を追加しない = Req 3.2, 3.3, 3.4 を構造的に保証）
  - 本タスク内にシェルレベル統合テストを追加（`shx_run_for_spec_dir` を stub 化し、gate ON で対象数だけ生成トリガ /
    gate OFF で no-op / render 失敗が本流戻り値に伝播しないことを、call site 到達順で検証。behavior-changing のため同 task 内必須）
  - _Requirements: 1.4, 2.1, 3.2, 3.3, 3.4, 4.1_
  - _Depends: 2_

- [x] 4. 生成 .html を版管理から除外（既定方針 = .gitignore） (P)
  - ルート `.gitignore` に `docs/specs/**/*.html` を追加し、生成 .html を版管理対象外にする（Req 7.2）。
    生成は claude セッションの commit / PR 作成後・`git add` なしで走るため当該 PR に混入しないが、後続 `git add -A` の巻き込みも本除外で防ぐ
  - commit 版管理（Req 7.1: `.gitattributes` の `linguist-generated`）は **不採用**（design 確認事項 2 参照）。リモート閲覧要求が確定した場合の代替として design に記録済み
  - consumer の `.gitignore` は install 管理外のため本タスクでは触らず、opt-in setup として README（task 5）で 1 行追加を案内する（NFR 4.3）
  - _Requirements: 7.2_
  - _Boundary: .gitignore_

- [x] 5. README / CLAUDE.md のドキュメント整合 (P)
  - `README.md`「オプション機能一覧」相当節に、`SPEC_HTML_ENABLED`（既定 false・opt-in）と補助 env（`SPEC_HTML_RENDER_BIN` /
    `SPEC_HTML_RENDER_CMD` / `SPEC_HTML_TIMEOUT` / `SPEC_HTML_TARGETS`）の一覧・既定値・有効化手順を追記（NFR 7.1）
  - 閲覧経路（ローカル checkout での worktree 参照方法）と consumer `.gitignore` への 1 行追加、依存 CLI（pandoc）の setup 要件を明記（Req 6.3 / NFR 2.2）
  - 外部アップロードは本機能とは別の opt-in gate 前提で本 spec 未実装である旨（予約名 `SPEC_HTML_UPLOAD_ENABLED`）を記載（Req 6.2）
  - `README.md`「ディレクトリ構成」ツリーへ `spec-html.sh` を追加。`CLAUDE.md` 機能追加ガイドライン §2 prefix 表へ `shx_` 行を追加（NFR 7.2）
  - 本機能は `.claude/agents` / `.claude/rules` を変更しないため `diff -r .claude/agents repo-template/.claude/agents` /
    `diff -r .claude/rules repo-template/.claude/rules` が空のまま（ドリフト非導入）であることを確認（NFR 4.1, 4.2, 4.3）
  - _Requirements: 6.2, 6.3_
  - _Boundary: README.md, CLAUDE.md_
  - _Depends: 2_

- [ ] 6. 全体整合の検証（no-op 回帰・静的解析・smoke）
  - gate 既定 OFF で main loop の処理順序・生成成果物・ログ出力先が導入前と一致すること（call site `|| true` 経路が no-op）を統合的に確認（Req 1.1 / NFR 1.1）
  - `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh` 新規警告ゼロ・
    `bash -n local-watcher/bin/issue-watcher.sh` OK を確認（NFR 6.1）
  - dry-run（対象なし・`SPEC_HTML_ENABLED` 未設定）で `処理対象の Issue なし` 正常終了、`SPEC_HTML_ENABLED=true` + pandoc で本 spec dir の .html 生成 + .md 無変更を smoke 確認
  - スコープは統合 / smoke / no-op 回帰に限定（各 unit テストは task 1〜3 に同梱済み）
  - _Requirements: 1.1_
  - _Depends: 1, 2, 3, 4, 5_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを宣言する。
対象パスは tasks.md commit 時点で存在するもののみ（新規 module / test は glob と各 task 内実行でカバー）。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh && bash -n local-watcher/bin/issue-watcher.sh
```
