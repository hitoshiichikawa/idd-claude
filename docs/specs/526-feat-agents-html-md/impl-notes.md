# 実装ノート（#526 人間レビュー用成果物の HTML 並行生成）

## 実装サマリ

| Task | 内容 |
|---|---|
| 1 | `watcher-config.sh` に `SPEC_HTML_*` opt-in gate と正規化を追加（`AUTO_REBASE_MODE` 同型 case）。既定有効化フラグ正規化ループには含めない。シェル回帰テスト `watcher_config_spec_html_test.sh` 同梱 |
| 2 | 新規 module `modules/spec-html.sh`（prefix `shx_` / 関数定義のみ）を実装し `REQUIRED_MODULES` に登録（`tasks-count-gate.sh` の後 / `slot-worker.sh` より前）。ユニットテスト `spec-html_test.sh` 同梱 |
| 3 | `slot-worker.sh` `_slot_run_issue` の design rc=0（tc hook 直後）/ impl rc=0（return 0 前）に `shx_run_for_spec_dir \|\| true` を配線。統合テスト `slot_worker_spec_html_hook_test.sh` 同梱 |
| 4 | root `.gitignore` に `docs/specs/**/*.html` を追加（Req 7.2 / 版管理除外の既定案） |
| 5 | README にオプション機能行 + 専用詳細節 + ディレクトリツリー、CLAUDE.md prefix 表 `shx_` 行を追記 |
| 6 | 全体整合検証（静的解析 / 全テスト / no-op 回帰 / smoke） |

実装上の判断:
- `SPEC_HTML_RENDER_CMD` の既定値は `{OUT}` / `{IN}` の `}` を含むため `"${VAR:-default}"` に直書きすると
  bash が最初の `}` を展開終端と誤認して壊れる。brace を含まない中間変数経由で default を与えた
  （`watcher-config.sh` の該当ブロック / 検証済み）。
- `shx_render_one` は `SPEC_HTML_RENDER_CMD` を **トークン分割の後**に `{IN}`/`{OUT}` を置換して配列実行する。
  置換値（path）がスペースを含んでも再分割されず引数注入を防ぐ（NFR 5.1）。副作用として、render コマンド
  テンプレ自体に「スペースを含むクォート引数」は書けない（複雑な変換は wrapper script 化で対応）。
- gate OFF は `shx_run_for_spec_dir` 早期 return で **ログ副作用ゼロ**（NFR 1.1）。Req 1.3 の「1 行 log」は
  config 側で **不正値のときのみ** WARN を出し、未設定 / 明示 `false` は無ログとして両立させた。

## 検証結果

| コマンド | 結果 |
|---|---|
| `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/watcher-config.sh local-watcher/bin/modules/*.sh` | 警告ゼロ |
| `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| `bash local-watcher/test/watcher_config_spec_html_test.sh` | PASS 25 / FAIL 0 |
| `bash local-watcher/test/spec-html_test.sh` | PASS 36 / FAIL 0 |
| `bash local-watcher/test/slot_worker_spec_html_hook_test.sh` | PASS 11 / FAIL 0 |
| `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules repo-template/.claude/rules` | 空（本機能は agents/rules 非変更） |

smoke（本 spec dir に対し実施 / **pandoc は本環境に未インストール**）:
- (a) gate ON + pandoc 不在 → `shx_render_available` が WARN 記録 + `shx_run_for_spec_dir` return 0、.html 0 件（Req 5 / NFR 2）
- (b) gate ON + 代替 CLI `cp`（`SPEC_HTML_RENDER_CMD="cp {IN} {OUT}"`）→ 実在 3 対象（requirements/design/tasks）の .html を生成、
  summary log `targets=3 ok=3 fail=0` return 0、**.md 全ファイル md5 不変**（Req 3.1 正準維持 / 2.1 / 2.4）
- (c) gate OFF → return 0・無ログ・.html 0 件（Req 1.4 / NFR 1.1）
- cleanup 後 spec dir に未追跡ファイル残留なし（生成 .html は `.gitignore` 対象 / Req 7.2）

## AC カバレッジ（1 要件 1 行）

| Req | 担保 |
|---|---|
| 1.1 | `shx_enabled` + config 正規化。`watcher_config_*`（ENABLED 8 ケース）/ `spec-html_*`（shx_enabled 7 ケース）/ smoke(c) |
| 1.2 | `shx_run_for_spec_dir`。smoke(b) |
| 1.3 | config case で不正値のみ 1 行 WARN + `false` 正規化。`watcher_config_*`（log 5 ケース / TIMEOUT 7 ケース） |
| 1.4 | call site `\|\| true` + gate 早期 return。`slot_worker_*`（gate OFF return 0 / 無ログ）/ smoke(c) |
| 2.1 | design/impl hook → `shx_render_one`。`slot_worker_*` / `spec-html_*`（render_one 成功）/ smoke(b) |
| 2.2 | `SPEC_HTML_TARGETS` 既定 + `shx_target_files`。`watcher_config_*`（既定値）/ `spec-html_*`（実在 3 件列挙） |
| 2.3 | `SPEC_HTML_TARGETS` 既定に impl-notes/review-notes 含む。`watcher_config_*`（既定値）/ `spec-html_*`（不在は除外） |
| 2.4 | `shx_html_path`（`<name>.md`→`<name>.html`）。`spec-html_*`（html_path 3 ケース） |
| 2.5 | `SPEC_HTML_RENDER_CMD`（既定 pandoc gfm→html5）+ `shx_render_one` 実行経路。`spec-html_*`（cp 代替で置換+実行検証）/ smoke(b)。※ pandoc 実描画の忠実性は下記確認事項参照 |
| 3.1 | module は .html のみ Write・.md read-only。`spec-html_*`（.md 不変）/ smoke(b)（md5 不変） |
| 3.2 | 本機能は機械ゲートに触れず .html を読む経路なし。`slot_worker_*`（構造検証）/ 設計不変 |
| 3.3 | agents/rules 非変更。`diff -r` 空 |
| 3.4 | .html を読む経路なし + fail-open。`slot_worker_*`（render 失敗でも return 0） |
| 4.1 | 両 hook が毎回上書き再生成。`slot_worker_*` / smoke(b) |
| 4.2 | `shx_render_one` 無条件上書き（手編集非保護）。`spec-html_*`（render_one） |
| 5.1 | `shx_run_for_spec_dir` 常に return 0 + `\|\| true`。`spec-html_*`（全失敗/一部失敗でも return 0）/ `slot_worker_*` |
| 5.2 | `shx_warn`（対象ファイル名付き）。`spec-html_*`（失敗時 warn）/ smoke(a) |
| 5.3 | hook `\|\| true` + module return 0 固定で exit code 不変。`spec-html_*` / `slot_worker_*` |
| 6.1 | worktree 内 Write のみ（module に gh/network 呼び出しなし）。コードレビュー + smoke(b) |
| 6.2 | 外部アップロードは別 opt-in gate 前提・本 spec 未実装（予約名 `SPEC_HTML_UPLOAD_ENABLED`）。README 記載 |
| 6.3 | 閲覧手段（ローカル checkout 参照）を README 詳細節に記載 |
| 7.1 | commit + generated 扱い（`linguist-generated`）は **不採用**（design 確認事項 2）。代替として design に記録済み |
| 7.2 | `.gitignore` `docs/specs/**/*.html`。`git check-ignore` で除外確認済み |
| NFR 1.1/1.2/1.3 | gate 既定 OFF・既存 env 名不変・新 label/cron/exit code なし。全テスト + smoke(c) |
| NFR 2.1/2.2 | 新規 runtime なし・pandoc は opt-in 配下 skip-if-missing・README setup 明記。smoke(a) |
| NFR 3.1 | `shx_log`/`shx_warn`（skip 理由/成功/失敗/summary）。smoke(a)(b) のログ |
| NFR 4.1/4.2/4.3 | agents/rules 非変更（`diff -r` 空）・consumer setup を README 同期 |
| NFR 5.1 | basename allowlist（path separator/`..` 除外）+ 全 quote + NUMBER 既検証。`spec-html_*`（path-traversal 除外） |
| NFR 6.1 | `shellcheck` / `bash -n` 警告ゼロ |
| NFR 7.1/7.2 | 同一 PR で README / CLAUDE.md 更新 |

## 確認事項

design の「確認事項（人間レビュー向け）」5 項目（生成手段=pandoc 既定 / 版管理=.gitignore 除外 /
対象 5 ファイル / 閲覧経路=ローカル checkout / consumer `.gitignore` は README 案内）は Architect の
確定案を **そのまま実装**した。以下は実装で気づいた点で、人間判断・レビューの材料として残す:

1. **pandoc 未インストール環境での検証範囲**: 本 watcher 環境に pandoc が無いため、Req 2.5 の
   「.md 内容を反映した可読 HTML」の **実描画忠実性は live 検証していない**。`shx_render_one` の
   テンプレ置換 + timeout 実行 + rc 判定 + .md 不変は代替 CLI（`cp`）で end-to-end 検証済み。
   pandoc 依存採用の是非は design 確認事項 1 の通り人間承認事項。運用有効化前に実行環境への
   pandoc インストールが前提（README に明記）。
2. **`SPEC_HTML_RENDER_CMD` の語彙制約**: テンプレは whitespace でトークン分割するため、
   「スペースを含むクォート引数」を持つ変換コマンドは表現できない（引数注入予防とのトレードオフ）。
   複雑な変換が必要な場合は wrapper script を `SPEC_HTML_RENDER_BIN` に指定する運用で回避可能。
   design の env 表は本制約を明示していないため、必要なら design 追記を Architect に提案する余地あり。
3. **Req 1.3 の「1 行 log」実装位置**: design Traceability は Req 1.3 を「config case 正規化 + 1 行 log」と
   規定。NFR 1.1（既定 OFF はログ副作用ゼロ）と両立させるため、config case を `true|false`（無ログ）と
   不正値（1 行 WARN）に分離した。未設定 / 明示 `false` は無ログ。設計意図と整合と判断したが、
   config-source 時 stderr へ 1 行出る点（サイクルごと 1 回）はレビューで確認されたい。

STATUS: complete
