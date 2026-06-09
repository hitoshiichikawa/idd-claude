# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-08T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-294-impl-feat-watcher-pretooluse-guard-hook-base
- HEAD commit: 6cd87dc7106b107c9e264aa2daec765827cee6b9
- Compared to: main..HEAD（merge-base 4678de8 起点で実差分を確認。`main` 側に独立進行した
  変更は本レビュー対象外として除外し、294 関連 commit 18 件のみを判定対象とした）

## Verified Requirements

### Req 1 (後方互換性 / opt-in gate)

- **1.1** — `gh_is_enabled` が `[ "${IDD_CLAUDE_HOOKS_ENABLED:-}" = "true" ]` で **lowercase 厳密一致**
  判定。`gh_build_args` が opt-out 時 `CLAUDE_HOOK_ARGS=()` 空配列構築
  (`local-watcher/bin/modules/guard-hook.sh:55-57, 216-226`)
- **1.2** — opt-out 時に空配列展開 `"${CLAUDE_HOOK_ARGS[@]}"` で引数が一切追加されない
  (`local-watcher/bin/issue-watcher.sh` 11 箇所の挿入位置)。`IDD_HOOK_BASE_BRANCH` の export は
  `gh_is_enabled` 内側のみで実行されるため env 集合も opt-out 時は不変 (`:715-718`)
- **1.3** — 既存 env var 名 (`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` /
  `DEV_MODEL` / `BASE_BRANCH` 等) の意味と既存 exit code / ラベル名は本 PR で変更されていない。
  新規 exit code 11/12/13 は opt-in 時の新規経路のみで既存経路に上書きはない
- **1.4** — `install.sh` 新規 helper (`install_guard_hooks` / `copy_hook_settings_with_substitution` /
  `resolve_hooks_install_dir`) は `cp` / `mkdir -p` / `chmod` / `sed` のみ使用、sudo 非要求

### Req 2 (G1: base 宛 push deny)

- **2.1** bare push — fixture `g1-base-push-bare.json` deny + reason `base branch push denied` 確認
- **2.2** `HEAD:base` srcdst — fixture `g1-base-push-srcdst.json` deny。`extract_dst_from_refspec`
  が `${rs#*:}` で dst 抽出 (`idd-guard.sh:214-223`)
- **2.3** `:base` delete — fixture `g1-base-push-delete-colon.json` deny。`+` 除去 + colon 分割で
  dst='base' を取り出す
- **2.4** `+base` plus-refspec — fixture `g1-base-push-plus-refspec.json` deny
- **2.5** `git -C path push` global options — fixture `g1-base-push-with-C.json` deny。
  `extract_push_tokens` が `-C` / `--git-dir=` / `--work-tree=` / `-c k=v` を skip (`:158-208`)
- **2.6** 暗黙 remote — fixture `g1-base-push-implicit-remote.json` deny。`analyze_push` が
  positional=1 件のときに base 名一致を refspec 扱いに格上げ (`:285-302`)
- **2.7** deny reason に ref 名を含む — `"base branch push denied: ref=$rs (base=$base_branch)"`
  (`:322`)。fixture expected.tsv で `base branch push denied` substring 確認

### Req 3 (G2: 無条件 force deny)

- **3.1** `-f` — fixture `g2-force-short.json` deny
- **3.2** `--force` — fixture `g2-force-long.json` deny
- **3.3** refspec 先頭 `+` (base 以外でも deny) — fixture `g2-force-refspec-plus.json` deny。
  `refspec_has_plus_prefix` でチェック (`:343-348`)
- **3.4** `--force-with-lease(=value)` で base 以外は allow — fixtures `g2-allow-lease.json` /
  `g2-allow-lease-value.json` allow。`has_force=0 && has_lease=1` 経路で deny されない
- **3.5** deny reason — `"unconditional force push denied: use --force-with-lease"` を含む
  (`:339, 346`)

### Req 4 (G0: install dir 自己保護)

- **4.1** Edit on install dir → deny — fixture `g0-edit-self.json` deny。`check_g0_path` が
  prefix 一致で robust に検出 (`:106-118`)
- **4.2** Write on install dir → deny — fixture `g0-write-self.json` deny。
  `NotebookEdit` も `g0-notebookedit-self.json` で同様に deny
- **4.3** Bash mutation コマンド → deny (best-effort) — fixtures `g0-bash-rm-self.json` /
  `g0-bash-sed-i-self.json` deny。`check_g0_bash` が literal 検出 + mutation keyword 両方一致で
  deny (`:121-149`)
- **4.4** best-effort 明示 — `local-watcher/hooks/README.md` L47 と `README.md` L5366-5370 で
  「Bash 経由 mutation 検出は best-effort、全件捕捉を保証しない」を明記

### Req 5 (fail-closed 起動ゲート)

- **5.1** claude version 取得 + `IDD_CLAUDE_HOOKS_MIN_VERSION` 比較 — `gh_preflight` が
  `claude --version` を取得し `gh_compare_semver` で **数値ベース**比較 (`:141-167`)
- **5.2** version 未満で非ゼロ exit + stderr — `return 11` + `gh_error` 2 行 (version 不足理由 +
  復旧ヒント)。Task 7 smoke 4 で `IDD_CLAUDE_HOOKS_MIN_VERSION=99.0.0` で exit=11 観測
- **5.3** smoke test 実行 — `gh_preflight` step 3 で固定 fixture JSON を hook に流して
  exit 0 + `"decision"` リテラル不在を確認 (`:187-202`)
- **5.4** smoke test 失敗で非ゼロ exit — `return 13`
- **5.5** silent fallback なし — `if gh_is_enabled; then gh_preflight || exit $?; ...` で
  preflight 失敗時に即 `exit $?`、fallback 経路を持たない (`issue-watcher.sh:715-718`)

### Req 6 (配布スコープ限定)

- **6.1** user-scope 配置 — `install.sh` の `INSTALL_LOCAL` ブロックで
  `$HOME/.idd-claude/hooks/` に 3 ファイル配置 (`install.sh:1365-1373`)
- **6.2** `repo-template/` 配下に追加なし — `git diff 4678de8..HEAD -- repo-template/` に
  guard-hook 関連の変更なし (294 関連 commit が `repo-template/` を一切触っていない)
- **6.3** consumer `.claude/` 配下に配布なし — `INSTALL_REPO` ブロックは未変更、
  `copy_template_file` / `copy_agents_rules` シーケンスに本 helper を呼ばない
- **6.4** 後続 Issue 起票が前提として明示 — `README.md` Migration Note L5392-5404 で
  「**後続の別 Issue として独立に承認・起票される前提**」を明文化。実際の Issue 起票責務は
  PjM / 人間にあり Implementer 範囲外 (Summary 参照)

### NFR

- **NFR 1.1** 互換性 — opt-out 時の挙動互換は impl-notes Task 7 smoke 3 で「timestamp 以外
  完全一致」+「`guard-hook:` log 行が一切出ない」で確認済み
- **NFR 1.2** sudo なし — Req 1.4 と同じ実装で担保
- **NFR 1.3** `IDD_CLAUDE_HOOKS_MIN_VERSION` env override 可 — `${IDD_CLAUDE_HOOKS_MIN_VERSION:-2.1.167}`
  でハードコードせず env default で上書き可能
- **NFR 2.1** shellcheck 警告ゼロ — `shellcheck install.sh local-watcher/bin/issue-watcher.sh
  local-watcher/bin/modules/guard-hook.sh local-watcher/hooks/idd-guard.sh` を Reviewer 再実行
  でも警告ゼロを確認
- **NFR 2.2** actionlint — 本機能で `.github/workflows/*.yml` の変更なし (該当なし)
- **NFR 3.1〜3.4** 既知の限界文書化 — `README.md` L5353-5374 / `local-watcher/hooks/README.md`
  L41-48 で 4 項目すべて明示
- **NFR 4.1, 4.2** 二重管理規約への影響なし — `.claude/agents` / `.claude/rules` 未変更、
  `repo-template/.claude/` 未変更

### Reviewer 再実行による検証

- `bash docs/specs/294-feat-watcher-pretooluse-guard-hook-base/test-fixtures/run-tests.sh` →
  **29/29 green** (G0:5 / G1:6 / G2:5 / Allow:13)
- `shellcheck install.sh local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/guard-hook.sh
  local-watcher/hooks/idd-guard.sh` → 警告ゼロ
- `git log main..HEAD` で 294 関連 18 commit 確認、`git diff --stat 4678de8..HEAD` で実差分の
  境界が tasks.md `_Boundary:_` 範囲内であることを目視確認

## Findings

なし

## Summary

全 Requirements (1.1〜1.4, 2.1〜2.7, 3.1〜3.5, 4.1〜4.4, 5.1〜5.5, 6.1〜6.4) と全 NFR
(1.1〜1.3, 2.1〜2.2, 3.1〜3.4, 4.1〜4.2) に対応する実装またはテスト fixture を確認した。
hook 本体は 29/29 green、shellcheck 警告ゼロ、watcher 配線は 11 箇所の `claude --print`
起動行末尾に `"${CLAUDE_HOOK_ARGS[@]}"` 注入を確認。境界は `local-watcher/hooks/` /
`local-watcher/bin/modules/guard-hook.sh` / `issue-watcher.sh` / `install.sh` / `README.md` /
spec 配下に閉じ、`repo-template/` / consumer `.claude/` への配布なし。

Req 6.4 の「consumer 配布の後続 Issue 起票」は Developer 側で README Migration Note および
impl-notes 確認事項として明示されているが、実際の Issue 起票自体は PjM / 人間の責務であり
Implementer 範囲外の operational item として **Reviewer は reject 理由としない**。PjM が
PR 本文「確認事項」に従って consumer 配布 Issue を起票することを別途確認されたい。

RESULT: approve
