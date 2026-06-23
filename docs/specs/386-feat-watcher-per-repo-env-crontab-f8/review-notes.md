# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-23T08:30:17Z -->

## Reviewed Scope

- Branch: claude/issue-386-impl-feat-watcher-per-repo-env-crontab-f8
- HEAD commit: 916641e665e7dbed42b3bf3d989ae27f1882a8dd
- Compared to: main..HEAD
- Diff stat: 6 files changed, 1139 insertions(+), 1 deletion(-)
  - `README.md`（+129 行 / NFR 5.2・5.3）
  - `local-watcher/bin/issue-watcher.sh`（+26 行 / 挿入点と REQUIRED_MODULES 追加）
  - `local-watcher/bin/modules/env-loader.sh`（新規 +213 行 / 本体 module）
  - `local-watcher/test/env-loader_test.sh`（新規 +447 行 / 近接テスト 20 ケース）
  - `docs/specs/386-feat-watcher-per-repo-env-crontab-f8/{requirements,impl-notes}.md`（成果物）
- Feature Flag Protocol 採否: CLAUDE.md に該当節なし → opt-out 扱い、flag 细目は適用しない

## Verified Requirements

- **1.1** — `issue-watcher.sh` L57〜81 で REPO_SLUG 算出直後（全 `*_ENABLED` 系 default 評価より前）に `el_load` を呼ぶ。スモークテスト「env file あり → `full-auto=true` 反映」で flag 解決前に走ることを確認（impl-notes）
- **1.2** — `env-loader.sh` `el_resolve_env_file` の case `/*)` 絶対パス検査 → `el_apply_env_file` ループに分岐前 return。テスト Sub 1.1 / Sub 1.2（明示 + per-repo パス無視）
- **1.3** — `el_resolve_env_file` の `[ -n "${WATCHER_ENV_FILE:-}" ]` で未設定/空文字の場合に次候補へ。テスト Sub 1.3 / Sub 1.4
- **1.4** — per-repo パスの `[ -f ] && [ -r ]` で採用。テスト Sub 1.3
- **1.5** — `el_resolve_env_file` は候補なしで `return 1`。`el_load` は rc=1 で silent return。テスト Sub 1.6 / Sub 6.1（rc=0 / 出力なし）
- **2.1** — `el_apply_env_file` の `^([A-Za-z_][A-Za-z0-9_]*)=(.*)$` regex で 1 行 1 件を強制
- **2.2** — `case "$stripped" in ''|'#'*) continue ;;` で行頭 `#` を skip。テスト Sub 2.2
- **2.3** — 同じく空行 / 空白のみ行を `${raw%%[![:space:]]*}` の leading strip 後に `''` 判定で skip。テスト Sub 2.2（連続空行・空白行）
- **2.4** — `export "$key"` で後続処理へ供給。テスト Sub 2.1
- **3.1** — `eval "$key=\"$value\""` で `$HOME` を起動シェルが展開。テスト Sub 3.1（`/test/home/foo` 期待値）
- **3.2** — 同 eval で `$(...)` を実行。テスト Sub 3.2（`cat secret.txt` 経由で値取得）
- **3.3** — eval rc 非 0 で warn + unset + 後続継続。テスト Sub 3.3（`/nonexistent/command-that-fails` → 後続 KEY 反映）
- **3.4** — `el_log` / `el_warn` 実装が KEY 名 / パス / 行番号 / 失敗種別のみを受け取り、VALUE 本体は引数に取らない構造（コメントに明記）。テスト Sub 6.2（`should-not-be-logged` が log に出ないこと）
- **4.1** — `[ -n "${!key+x}" ]` 判定で既存 KEY を skip。テスト Sub 4.1（`INLINE_KEY=from-inline` 温存）
- **4.2** — テスト Sub 4.2（`FILE_ONLY=from-file` 反映）
- **4.3** — 実装は env ファイルに無い KEY を一切触らないため inline 値が温存される（構造的担保 + テスト Sub 1.6 / Sub 6.1 の不在時 no-op で副次的に確認）
- **4.4** — `${KEY+x}` で空文字値の KEY も「定義済み」扱い。テスト Sub 4.3（`INLINE_EMPTY=""` 温存）
- **5.1** — `el_load` 内で `el_resolve_env_file` rc=1 → silent return 0。テスト Sub 6.1（stdout/stderr 空 / rc=0）+ impl-notes スモークテスト 3 シナリオ
- **5.2** — 実装に新規 `*_ENABLED` gate を追加しておらず、`if [ -f "$IDD_ENV_LOADER_PATH" ]` でファイル存在のみを opt-in シグナルとする（構造的担保）
- **5.3** — テスト Sub 4.1 で inline 列挙の優先を確認 + スモーク 2「inline `FULL_AUTO_ENABLED=false` で env file の `true` を上書き」確認
- **6.1** — `[ ! -r "$env_file" ]` で `el_warn` + return 1。テスト Sub 5.3（chmod 0 環境で rc=1 + WARN）
- **6.2** — 正規表現不一致時 `el_warn "構文不正行 skip: $env_file:$lineno"`。テスト Sub 5.1（`=` なし）/ Sub 5.2（数字始まり KEY）
- **6.3** — eval 失敗時 `el_warn` + `unset "$key"`。テスト Sub 3.3
- **6.4** — Req 4.1 の precedence は eval 結果に関係なく適用される（既存 inline 定義 KEY は entry の `${!key+x}` でそもそも eval 自体に到達しない。構造的担保 + impl-notes 言及）
- **6.5** — warn メッセージに `"$env_file:$lineno"` を含める。テスト Sub 5.1 が `section5.env:1` を grep 検査
- **NFR 1.1** — テスト Sub 6.1（候補不在で stdout/stderr 空 / rc=0）+ スモーク 3
- **NFR 1.2** — diff で既存 env var 名・登録文字列に変更なし（新規挿入のみ）
- **NFR 1.3** — Sub 6.1 / スモーク 3 で byte 等価性確認
- **NFR 2.1** — `el_resolve_env_file` の `case "$path" in /*)` 絶対パス検査 + `[ -f ]` 通常ファイル + `[ -r ]` 読取権限の 3 段検査。テスト Sub 1.5（相対パス無視）
- **NFR 2.2** — テスト Sub 6.2（値 `should-not-be-logged` がログに含まれないことを否定確認）
- **NFR 2.3** — README に `chmod 600 "$HOME/.issue-watcher/owner-myrepo.env"` を明記
- **NFR 2.4** — 実装コメント / README に「運用者管理ファイル = 信頼境界の内側」「サニタイズしない」明記
- **NFR 3.1** — `el_log "env ファイル採用: $env_file"` を採用時に 1 行出力。テスト Sub 6.2
- **NFR 3.2** — `el_warn` がパス / 行番号 / 理由を含む。テスト Sub 5.1 / 5.2 / 5.3
- **NFR 3.3** — 候補なしで `el_load` が silent return（log を出さない）。テスト Sub 6.1
- **NFR 4.1** — impl-notes に `shellcheck` warning ゼロ / `bash -n` エラーなし記載
- **NFR 4.2** — env-loader_test.sh が 5 経路（採用 / precedence / `$(...)` / byte 等価 / 構文不正）すべてを fixture でカバー（PASS=20 FAIL=0）
- **NFR 5.1** — `repo-template/` に local-watcher copies は無く（root-only）、本機能は consumer 配布に影響しない構造（impl-notes 確認済）
- **NFR 5.2** — README に「探索順 / 形式（`KEY=VALUE`） / precedence / 推奨パーミッション」節を同一 PR で追加
- **NFR 5.3** — README に「移行ガイド」節（既存 inline 列挙を `KEY=VALUE` 転記 → precedence で段階移行 → crontab 最小化）を同一 PR で追加

## Boundary 確認

- 変更ファイル: README.md / issue-watcher.sh / modules/env-loader.sh（新規）/ test/env-loader_test.sh（新規）/ requirements.md / impl-notes.md
- 本 Issue は Architect 不在の直接実装経路（tasks.md 不在）。boundary は requirements.md と CLAUDE.md「機能追加ガイドライン」で照合
- 新規 module `env-loader.sh` は `el_` prefix を採用（CLAUDE.md §2 未使用 prefix）/ 関数定義のみ / `REQUIRED_MODULES` 配列に追記済み — §1〜§2 遵守
- 既存 env var 名・ラベル名・exit code・cron 登録文字列を変更しない — §3「禁止事項」遵守
- README 同一 PR 反映 / `diff -r .claude/{agents,rules}` 空（impl-notes 確認済）— §4 遵守
- 新規 gate env を導入せず、ファイル存在のみで opt-in（Req 5.2 / CLAUDE.md §3 後方互換）— §3 遵守
- 未信頼入力扱い: env ファイル本体は「運用者管理ファイル = 信頼境界の内側」（NFR 2.4）として `eval` 評価する明示的設計判断。要件側で承認済み（Out of Scope に「サニタイズ」「暗号化」を切出し）

逸脱は検出されず。

## Findings

なし。

## Summary

Req 1〜6 / NFR 1〜5 のすべての numeric ID が `env-loader.sh` 実装と `env-loader_test.sh`（20 ケース PASS）+ README 追記 + `issue-watcher.sh` 挿入点で観測可能にカバーされている。precedence（inline > env ファイル）は `${!key+x}` 構造的担保 + Sub 4.1 / 4.3 テストで二重に検証されており、候補不在時の byte 等価性は Sub 6.1 + スモーク 3 で確認済み。boundary 逸脱・missing test・AC 未カバー のいずれも検出されない。

RESULT: approve
