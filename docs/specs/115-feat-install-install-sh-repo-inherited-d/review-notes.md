# Review Notes — Issue #115 (round 1)

<!-- idd-claude:review round=1 model=claude-opus-4-7 -->

## Reviewed Scope

- Branch: claude/issue-115-impl-feat-install-install-sh-repo-inherited-d
- HEAD commit: 59feccf46e207b327d3183767c094a82d7a9ab08
- Compared to: main..HEAD
- 変更ファイル: `install.sh` (+389), `README.md` (+49), `QUICK-HOWTO.md` (+70),
  `docs/specs/115-*/requirements.md` (+159), `docs/specs/115-*/impl-notes.md` (+304)
- Feature Flag Protocol: 対象 repo の `CLAUDE.md` に節無し → opt-out として解釈、
  flag 観点の細目チェックは適用しない

## Summary

Issue #115（install.sh の inherited specs / claude branches 警告機能）の実装は、
requirements.md の Requirement 1〜8 と NFR 1〜3 のすべての numeric ID について、
`install.sh` 内の追加関数群（`detect_inherited_specs` / `detect_inherited_claude_branches` /
`detect_orphan_claude_branches` / `print_inherited_footer` / `detect_inherited_artifacts`）と
README / QUICK-HOWTO の追加節で観測可能にカバーされている。reviewer 独立 context で
クリーン repo / D-1 inherited / 4 件超過 / `--local` 単独の 4 シナリオを再実行し、
impl-notes.md 記載の出力と一致することを確認した。boundary 逸脱・missing test は無し。

## Verified Requirements

- 1.1 — `detect_inherited_specs` (install.sh:760-818) + 独立 smoke で `docs/specs/99-legacy-feature/` 検出を確認
- 1.2 — `detect_inherited_claude_branches` (install.sh:878-) + `_list_claude_issue_branches` の regex `^claude/issue-[0-9]+-(design|impl)-`
- 1.3 — `detect_orphan_claude_branches` の `missing*2 > total` 判定（過半数 = >50%、整数演算）
- 1.4 — `print_inherited_footer` 内 "この警告を無視しても install 自体は正常完了しています（exit 0）"
- 1.5 — footer 内 "詳細手順: README.md / QUICK-HOWTO.md の「fork / mirror clone から導入するときの注意」節"
- 2.1 — `/tmp/rev115-clean` での独立 smoke: inherited 系出力 0 件を確認
- 2.2 — `detect_inherited_specs` の `printf '%s' "$name" | grep -Eq '^[0-9]+-'` 二重ガード
- 2.3 — `_list_claude_issue_branches` exit 10 (origin 未設定で無音) + `inherited_skip_log` (ls-remote 失敗時 1 行ログ)
- 2.4 — `detect_inherited_artifacts` は `if $INSTALL_REPO; then ... fi` 内 (install.sh:1203) で呼ばれ、
  `--local --dry-run` 独立 smoke で inherited 系出力 0 件を確認
- 3.1 — 関数群はすべて return 0 / 1 で抜け、install 全体の exit code に影響しない
- 3.2 — `_list_claude_issue_branches` 失敗時に `inherited_skip_log` → return 1 で D-2/D-3 skip、install 継続
- 3.3 — `detect_orphan_claude_branches` 内で gh 未認証 / repo_slug 解決失敗 / gh issue list 失敗の各経路で D-3 のみ skip
- 3.4 — `inherited_skip_log` (install.sh:734-743) が `[INSTALL] INFO: [inherited] <reason>` を stderr 出力
- 4.1 — D-1/D-2/D-3 関数は DRY_RUN による early return を持たず、`--dry-run` 下でも実行される
- 4.2 — `inherited_prefix` が `DRY_RUN=true` で `[DRY-RUN] WARNING:` を返す（独立 smoke で確認）
- 4.3 — 同関数が `DRY_RUN=false` で `[INSTALL] WARNING:` を返す（impl-notes Smoke Test 6）
- 4.4 — `git ls-remote --heads`（read-only）と `gh issue list --json number`（read-only）のみで書き込み API なし
- 5.1 — `[INSTALL] WARNING:` / `[DRY-RUN] WARNING:` プレフィックスが既存 `[INSTALL] SKIP` 等と整合
- 5.2 — `[docs-specs]` / `[claude-branches]` / `[orphan-branches]` 3 カテゴリ別に書式分離、先頭 3 件 + `(+N more)`（4 件 smoke で `(+1 more)` 確認）
- 5.3 — `print_inherited_footer` が "無視しても install は完了" と README/QUICK-HOWTO 参照を含む
- 6.1 — `setup.sh` の diff 無し（既存の `exec bash install.sh "$@"` で引数透過は据え置き）
- 6.2 — `setup.sh` 経由でも `install.sh` を呼ぶため同じ判定ロジックが走る
- 7.1 — README.md 追加節 "fork / mirror clone から導入するときの注意（履歴持ち込み警告 #115）"
- 7.2 — README.md 内クリーンアップ手順（`rm -rf docs/specs/<番号>-<slug>/` / `git push origin --delete`）
- 7.3 — QUICK-HOWTO.md 追加節 "5.5 fork / mirror clone から導入するときの注意（履歴持ち込み警告）"
- 7.4 — README.md "警告を無視した場合の影響" 段落で watcher の force push / 誤 resume リスクを明示
- 8.1 — 既存オプション解析（install.sh:81-93）に diff なし、追加処理は新規関数群のみ
- 8.2 — 対話モード（install.sh:1092 前後）に diff なし
- 8.3 — クリーン repo（`/tmp/rev115-clean`）独立 smoke で本機能由来出力 0 件を確認
- 8.4 — 追加コードは `git` / `gh` / `sed` / `awk` / `grep` のみ使用（`sed` `awk` `grep` は POSIX 標準）
- NFR 1.1 — `timeout 10` を `git ls-remote` と `gh issue list` に被覆
- NFR 1.2 — timeout 失敗 / `gh` 未認証 / repo_slug 解決失敗 すべて `inherited_skip_log` で skip 継続
- NFR 2.1 — `[INSTALL] WARNING: [<category>] ...` および `[INSTALL] INFO: [inherited] ...` は grep 可能
- NFR 2.2 — gh から取得するフィールドは `nameWithOwner` / `number` のみで token 漏出経路なし
- NFR 3.1 — `read -r` 等の対話プロンプトは追加無し
- NFR 3.2 — sudo 要求の追加無し

## Findings

なし。

## 判定根拠

- requirements.md の全 numeric ID（Req 1.1〜8.4 と NFR 1.1〜3.2）に対応する実装または
  ドキュメント反映が観測可能であり、独立 smoke で主要シナリオ（クリーン / D-1 検出 / 4 件超過 /
  `--local` 単独）の挙動が impl-notes.md と一致した
- `tasks.md` は当該 spec ディレクトリに不在だが、本 Issue は `needs-architect` ラベル無しで
  Architect が起動していないため、`_Boundary:_` アノテーションの形式定義自体が存在しない。
  Developer の変更範囲（`install.sh` の追記 + README/QUICK-HOWTO の追記）は Issue 本文の
  「影響範囲のヒント」と整合しており、自然なスコープ境界を逸脱していない
- 検出 3 種が同一テストスイート内で実行され、`shellcheck install.sh` も exit 0 でクリーン
- Feature Flag Protocol は対象 repo で opt-out（節未宣言）のため、flag 観点の細目チェックは
  適用対象外

RESULT: approve
