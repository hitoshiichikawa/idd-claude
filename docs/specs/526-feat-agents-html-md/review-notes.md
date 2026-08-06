# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-08-06T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-526-impl-feat-agents-html-md
- HEAD commit: 0de37e50441865eb85a77535dcce80e271500f0e
- Compared to: main..HEAD
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が存在しないため通常の 3 カテゴリ判定のみ（flag 観点は適用せず）

## Verified Requirements

- 1.1 — `shx_enabled`（`spec-html.sh:67`）+ config case 正規化（`watcher-config.sh` SPEC_HTML_ENABLED ブロック）。`watcher_config_spec_html_test.sh`（ENABLED 8 ケース）/ `spec-html_test.sh`（shx_enabled 7 ケース）/ `spec-html_test.sh` run gate OFF no-op
- 1.2 — `shx_run_for_spec_dir`（`spec-html.sh:195`）。`spec-html_test.sh`「全成功 → return 0 / summary ok=2」
- 1.3 — config case で不正値のみ 1 行 WARN + `false` 正規化（`watcher-config.sh`）。`watcher_config_spec_html_test.sh`「不正値 yes/True → 正規化 log あり」「未設定/明示 false/true → 無ログ」+ TIMEOUT 7 ケース。NFR 1.1 と両立させるため未設定/明示 false は無ログ（下記 Summary 補足参照）
- 1.4 — call site `shx_run_for_spec_dir || true` + gate 早期 return。`slot_worker_spec_html_hook_test.sh`（gate OFF return 0）/ `spec-html_test.sh`（gate OFF 無ログ）
- 2.1 — design/impl hook → `shx_render_one`。`slot_worker_spec_html_hook_test.sh`（hook 隣接構造検証）/ `spec-html_test.sh`（render_one 成功で .html 生成）
- 2.2 — `SPEC_HTML_TARGETS` 既定 + `shx_target_files`（`spec-html.sh:115`）。`watcher_config_spec_html_test.sh`（既定値）/ `spec-html_test.sh`（requirements/design/tasks 実在 3 件列挙）
- 2.3 — 既定 TARGETS に impl-notes/review-notes を含み、不在は除外。`watcher_config_spec_html_test.sh`（既定値）/ `spec-html_test.sh`（不在 impl-notes 除外）
- 2.4 — `shx_html_path`（`spec-html.sh:95`）。`spec-html_test.sh`（html_path 3 ケース、同一 dir 維持）
- 2.5 — `SPEC_HTML_RENDER_CMD`（既定 pandoc gfm→html5）を token 分割後 `{IN}`/`{OUT}` 置換して実行（`shx_render_one`）。`spec-html_test.sh`（cp 代替 CLI で置換+実行検証 / .html 生成）。pandoc 実描画の live 検証は環境未導入のため未実施だが、変換機構（テンプレ置換→外部 CLI 実行→.html 生成）は end-to-end で検証済み
- 3.1 — module は .html のみ Write・.md read-only。`spec-html_test.sh`（render_one 後 .md 内容不変）
- 3.2 — 本機能は既存機械ゲートに 1 行も触れず .html を読む経路を追加しない。diff 上 hook は `shx_run_for_spec_dir` 呼び出しのみ（.html 生成専用）。`slot_worker_spec_html_hook_test.sh`（構造検証）
- 3.3 — agents/rules 非変更。`diff -r .claude/agents repo-template/.claude/agents` / rules 双方空
- 3.4 — .html を読む経路なし + fail-open。`slot_worker_spec_html_hook_test.sh`（render 失敗でも本流 return 0）
- 4.1 — design/impl 両 hook が毎回上書き再生成。`slot_worker_spec_html_hook_test.sh`（hook 到達）/ `spec-html_test.sh`（render_one）
- 4.2 — `shx_render_one` 無条件上書き（手編集非保護）。`spec-html_test.sh`（cp による上書き）
- 5.1 — `shx_run_for_spec_dir` 常に return 0 + call site `|| true`。`spec-html_test.sh`（全失敗/一部失敗でも return 0）/ `slot_worker_spec_html_hook_test.sh`
- 5.2 — `shx_warn`（対象ファイル名付き / `spec-html.sh:168`）。`spec-html_test.sh`（失敗時 design.md 名付き warn）
- 5.3 — hook `|| true` + module return 0 固定で exit code 不変。`spec-html_test.sh` / `slot_worker_spec_html_hook_test.sh`
- 6.1 — worktree 内 Write のみ。`grep` で module に curl/wget/gh/ssh/scp 等の外部呼び出しなしを確認（コメント参照のみ）
- 6.2 — 外部アップロードは別 opt-in gate 前提・本 spec 未実装（予約名 `SPEC_HTML_UPLOAD_ENABLED`）。README「外部アップロードは本 spec 未実装」節に記載
- 6.3 — 閲覧手段（ローカル checkout 参照）を README「閲覧経路」節に記載
- 7.1 — `Where ... コミットする方針を採用する場合` の条件付き AC。design 判断で .gitignore 除外（7.2）を採用したため本条件は非採用。代替（`.gitattributes linguist-generated`）を design 確認事項 2 に記録
- 7.2 — root `.gitignore` に `docs/specs/**/*.html` 追加。`git check-ignore docs/specs/526-.../design.html` で除外を確認
- NFR 1.1/1.2/1.3 — gate 既定 OFF・既存 env 名不変・新 label/cron/exit code なし。全テスト + gate OFF 無ログ検証
- NFR 2.1/2.2 — 新規 runtime なし・pandoc は skip-if-missing・README setup 明記。`spec-html_test.sh`（CLI 不在 skip return 0）
- NFR 3.1 — `shx_log`/`shx_warn`（skip 理由/成功/失敗/summary）
- NFR 4.1/4.2/4.3 — agents/rules 非変更（`diff -r` 空）・consumer setup を README 同期
- NFR 5.1 — basename allowlist（path separator/`..` 除外）+ 全 quote + NUMBER 既検証。`spec-html_test.sh`（path-traversal エントリ除外）
- NFR 6.1 — `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh` 警告ゼロ + `bash -n` OK を reviewer 側で再実行確認
- NFR 7.1/7.2 — 同一 PR で README（オプション機能一覧 + 専用節 + ディレクトリツリー）/ CLAUDE.md（prefix 表 `shx_` 行）更新

## Findings

なし

## Summary

全 numeric AC（Req 1-7 / NFR 1-7）に観測可能な実装またはテストが対応。3 新規テスト（`spec-html_test.sh` 36 / `watcher_config_spec_html_test.sh` 25 / `slot_worker_spec_html_hook_test.sh` 11 = 計 72 件）を reviewer 側で再実行し全 PASS、`shellcheck` + `bash -n` 警告ゼロ、agents/rules の `diff -r` 空を確認。tasks.md の `_Boundary:_`（task4 `.gitignore` / task5 `README.md, CLAUDE.md`）逸脱なし、非 `(P)` タスクの変更も design File Structure Plan 内（watcher-config.sh / spec-html.sh / issue-watcher.sh REQUIRED_MODULES / slot-worker.sh call site）に収まる。gate 既定 OFF・fail-open・return 0 固定で後方互換を確保。

補足（当該 impl PR の reject 理由には含めない設計レベルの指摘）: (1) impl-notes 確認事項 3 の Req 1.3 と NFR 1.1 の緊張関係は、`true`/`false` を無ログ・不正値のみ 1 行 WARN に分離する形で harmonize されており design Traceability と整合するが、`false` 明示時のログ要否は設計 iteration での確認余地がある。(2) `SPEC_HTML_RENDER_CMD` の whitespace token 分割制約（クォート引数不可）は design env 表に未明記で、必要なら design 追記を Architect へ還流すべき。いずれも現行確定 spec を満たしており、別 Issue / 設計 iteration の領分。

RESULT: approve
