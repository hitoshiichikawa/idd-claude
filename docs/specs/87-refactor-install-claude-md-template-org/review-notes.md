# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-01T04:53:08Z -->

## Reviewed Scope

- Branch: claude/issue-87-impl-refactor-install-claude-md-template-org
- HEAD commit: bc0a0e3c6abe2a59e875208005893191f3330095
- Compared to: main..HEAD
- Feature Flag Protocol: 採否節なし → opt-out 解釈（flag 観点の追加チェックは適用せず、通常 3 カテゴリ判定のみ）

## Verified Requirements

すべて Reviewer 自身による `/tmp/review87-XXXX` への scratch repo 配置スモークテストで再検証済み（impl-notes.md のシナリオ A〜F + dry-run 4 種を独立に再実行）。

- 1.1 — `install.sh:483-490` (`copy_claude_md_with_org` の NEW 分岐) / 検証: 不在状態で `[INSTALL] NEW <repo>/CLAUDE.md` を観測、内容は template と sha256 一致
- 1.2 — `install.sh:483-490` (NEW 分岐で `.org` を作らない) / 検証: 不在からの NEW 配置後 `CLAUDE.md.org` 不在を確認
- 1.3 — `install.sh:486` (`log_action "NEW" "$dest"`) / 検証: NEW ログ 1 行のみ出力
- 2.1 — `install.sh:496-499` (OVERWRITE 経路で本体は SKIP として明示、cp しない) / 検証: 既存カスタム CLAUDE.md（"# My Project Custom..."）が install 前後で sha256 完全一致
- 2.2 — `install.sh:502-508` (`.org` 不在 → NEW 並置) / 検証: `[INSTALL] NEW <repo>/CLAUDE.md.org` を観測、`.org` の内容は template と sha256 一致
- 2.3 — `install.sh:512-515` (`.org` 既存 + 内容同一 → SKIP) / 検証: 再 install で `[INSTALL] SKIP <repo>/CLAUDE.md.org (identical to template)` を観測
- 2.4 — `install.sh:516-523` (`.org` 既存 + 差分 → OVERWRITE + `CLAUDE_MD_ORG_TOUCHED=true`) / 検証: stale `.org` を手動配置後 `[INSTALL] OVERWRITE <repo>/CLAUDE.md.org (refresh from template)`、再実行後 `.org` ハッシュは template と一致
- 2.5 — `install.sh:492-494` (SKIP 分岐で `.org` 触らず) / 検証: 既存 CLAUDE.md = template の repo に対し `[INSTALL] SKIP <repo>/CLAUDE.md (identical to template)` のみ、`.org` 不在
- 2.6 — `install.sh:745-750` (`copy_claude_md_with_org` と `copy_agents_rules` が直列で独立呼び出し、共有状態は `CLAUDE_MD_ORG_TOUCHED` のみで agents/rules 経路に影響しない) / 検証: シナリオ B / D の双方で `.claude/agents/` `.claude/rules/` が NEW 配置され、`.org` 判定は CLAUDE.md 単独で確定
- 3.1 — `install.sh:453-475` (FORCE=true 分岐の OVERWRITE 経路 `(--force)` 注記) / 検証: `--force` 指定で `[INSTALL] OVERWRITE <repo>/CLAUDE.md (--force)`、本体ハッシュが template と一致
- 3.2 — `install.sh:742-744` (FORCE=true 時のみ `backup_claude_md_once` を呼ぶ) + `backup_claude_md_once` (291-308) / 検証: `.bak` 不在から `[INSTALL] BACKUP <repo>/CLAUDE.md → CLAUDE.md.bak` を観測、`.bak` の内容は上書き前 CLAUDE.md と sha256 一致
- 3.3 — `install.sh:300-307` (既存 `.bak` あれば `SKIP (existing .bak preserved)`) / 検証: 既存 .bak ありで `--force` 実行、`[INSTALL] SKIP <repo>/CLAUDE.md.bak (existing .bak preserved)` + `.bak` ハッシュ不変
- 3.4 — `install.sh:453-475` (FORCE 分岐は `.org` を触らない) / 検証: シナリオ E / F-2 共に install 後 `.org` 不在
- 3.5 — `copy_with_hybrid_overwrite` (318-375) は変更なし、agents/rules への `--force` の意味（差分時に強制 OVERWRITE、`.bak` once-only 温存）は不変。`copy_claude_md_with_org` 内の `(--force)` 注記は Req 3 範囲内 / 検証: git diff 上 318-375 行範囲に変更なし
- 4.1 — `install.sh:300-307` (once-only 規律で既存 `.bak` を変更しない) + 通常経路では `backup_claude_md_once` を呼ばない (`install.sh:742-744`) / 検証: シナリオ F-1 / F-2 共に既存 `.bak` ハッシュ不変
- 4.2 — `copy_claude_md_with_org` 内に `.bak` 参照なし（grep で確認） / 検証: 既存 `.bak` を入力にしても `.org` 内容は template そのもの（`.bak` のコピーではない）
- 4.3 — `install.sh:737-747` (FORCE=false 時 `backup_claude_md_once` をスキップし、`copy_claude_md_with_org` のみを呼ぶ。後者は `.bak` 有無に関係なく `.org` 並置を判定) / 検証: シナリオ F-1 で既存 .bak ありの状態でも `.org` が NEW 配置される
- 5.1 — シナリオ C-1 (再 install で `[INSTALL] SKIP CLAUDE.md` + `[INSTALL] SKIP CLAUDE.md.org`、両ファイルのハッシュが 1 回目終了時点と一致)
- 5.2 — `install.sh:124-139` (DRY_RUN=true で `[DRY-RUN]` prefix) + 各 `cp` を `if [ "$DRY_RUN" = "false" ]` でガード / 検証: dry-run 4 シナリオ全てで `.org` / `.bak` / `CLAUDE.md` のハッシュ不変・ファイル新設なし
- 5.3 — Reviewer 検証: `--dry-run`（NEW / SKIP / OVERWRITE）と `--dry-run --force`（BACKUP / OVERWRITE / SKIP）の組合せで実実行と同じ 4 分類が `[DRY-RUN]` prefix 付きで出力されることを確認
- 6.1 — `install.sh:791-808` (`CLAUDE_MD_ORG_TOUCHED=true` 時のみ heredoc で merge ガイド表示) + `install.sh:508`, `install.sh:522` (NEW / OVERWRITE 時のみ true 化) / 検証: シナリオ B（`.org` NEW）と C-2（`.org` OVERWRITE）でガイド表示
- 6.2 — シナリオ A（CLAUDE.md NEW）/ D（CLAUDE.md SKIP）/ C-1（`.org` SKIP）でガイド非表示を観測
- 6.3 — `README.md:207-255` (`#### CLAUDE.md の .org 並置 (#87)` 節 1 つで NEW / SKIP / OVERWRITE / BACKUP / `--force` 経路と merge 手順を網羅)
- 6.4 — `README.md:244-254` (Migration note を `#87` と `#36` の 2 段構成に拡張、新規定→従来挙動への戻し方として `--force` を案内)
- NFR 1.1 — git diff 上、env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `IDD_CLAUDE_SKIP_LABELS`）の解釈変更なし
- NFR 1.2 — 既存フラグ（`--repo`, `--local`, `--all`, `--dry-run`, `--force`, `--no-labels`）の意味変更なし。`--force` の挙動は CLAUDE.md 経路で本 Issue が定義する範囲（Req 3）に閉じ、agents/rules への意味（`copy_with_hybrid_overwrite`）は無変更
- NFR 1.3 — sudo 検知ブロック (`install.sh:35-46`) は無変更
- NFR 1.4 — exit code の意味（0=成功 / 非 0=失敗）変更なし。新規 `Error: $org exists but is not a regular file` 経路 (`install.sh:524-528`) のみ追加だが、これは既存の `Error: source file not found` (`install.sh:198-201`, `install.sh:444-446`) と同じく異常時の `return 1` なので意味的整合
- NFR 2.1 — `log_action "NEW|SKIP|OVERWRITE|BACKUP" <path> [<note>]` を 1 行ログとして stdout に出力、各シナリオで観測
- NFR 2.2 — `log_action` (`install.sh:124-139`) は `printf '%s %-9s %s %s\n'` で agents/rules 配置ログと同一フォーマット
- NFR 3.1 — `setup_repo` 内で `copy_agents_rules` / `copy_template_file`（ISSUE_TEMPLATE / workflows / scripts）の呼び出しは無変更（git diff 上 749-763 行に変更なし）

## Findings

なし。

## Summary

要件 1.1〜6.4 + NFR 1〜3 全項目を独立 scratch repo でのスモークテスト（A〜F + dry-run 4 種 + 独立性検証）で再検証し、`install.sh:411-534` の `copy_claude_md_with_org` 実装、`install.sh:737-747` の `setup_repo` 内呼び出し切替、`install.sh:791-808` の merge ガイド分岐、README の `.org` 節と Migration note 2 段構成いずれも要件と一致した。`shellcheck install.sh` クリーン、env var / フラグ / exit code / sudo 不要 / 範囲外ファイル取り扱いの後方互換性も維持されている。Reject 該当なし。

RESULT: approve
