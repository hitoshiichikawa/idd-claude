# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:25:00Z -->

## Reviewed Scope

- Branch: claude/issue-208-impl-feat-install-install-sh-force-consumer-c
- HEAD commit: acc580d
- Compared to: main..HEAD
- 変更ファイル: `install.sh` / `README.md` / `docs/specs/208-.../requirements.md` / `impl-notes.md`
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が**存在しない** → opt-out 解釈。
  通常の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）のみで判定し、flag 観点の細目は適用しない。

## Verified Requirements

各 AC を install.sh のコード経路と、`/tmp` の使い捨て scratch repo での独立スモークテストで追跡した
（consumer 固有 CLAUDE.md を配置し `--no-labels` / git remote 無しで実行）。

- 1.1 — `--force` 単体で既存 CLAUDE.md を据え置き（`copy_claude_md_with_org` 通常経路 OVERWRITE→`SKIP (existing kept...)`）。Test A で md5sum 不変を確認
- 1.2 — `--force` で `CLAUDE.md.org` を NEW 並置（install.sh:517-523）。Test A で `.org` 生成・template 一致を確認
- 1.3 — `--force` で CLAUDE.md が template と同一なら `SKIP (identical)` + `.org` 不作成（classify_action SKIP 分岐）。Test M で `.org` 不作成を確認
- 1.4 — CLAUDE.md 不在で `--force` 指定でも NEW 配置・`.org` 不作成（install.sh:498-506、NEW 分岐は flag 非依存）。Test K で確認
- 1.5 — `--force` 単体で `.bak` 退避なし（呼び出し側 `backup_claude_md_once` 発火条件を `FORCE_CLAUDE_MD` に限定、install.sh:1141）。Test A で `.bak` 不在を確認
- 2.1 — `--force-claude-md` で `.bak` once-only 退避後 template 上書き（install.sh:468-490 + 1141）。Test C で `.bak`=consumer 内容 / 本体=template を確認
- 2.2 — `.bak` once-only 温存（`backup_claude_md_once` の `.bak` 既存→SKIP、install.sh:316-318）。Test G で `existing .bak preserved` を確認
- 2.3 — `--force-claude-md` で `.org` を作成・変更しない（FORCE_CLAUDE_MD 分岐は `.org` を参照しない）。Test C で確認
- 2.4 — `--force-claude-md` 無指定なら CLAUDE.md を上書きしない（`--force` の有無に関わらず通常経路）。Test A / Test J で確認
- 2.5 — `--force --force-claude-md` 併用で agents/rules も CLAUDE.md も上書き。Test L で両者 OVERWRITE を確認
- 3.1/3.2 — `--force` で agents/rules を `.bak` once-only 退避 + 上書き（`copy_with_hybrid_overwrite` **未変更**、`FORCE` を引き続き参照）。Test B で developer.md BACKUP+OVERWRITE を確認
- 3.3 — `--force` なしで `.bak` 既存なら SKIP（`copy_with_hybrid_overwrite` 未変更で regression 無し）。当該経路に本 PR の変更が及んでいないことを diff で確認
- 3.4 — ISSUE_TEMPLATE / workflows / labels script の配置（`copy_template_file` 等）未変更。diff 上 CLAUDE.md 経路以外に変更なし
- 4.1 — 同一引数の再実行で SKIP。Test G で `identical to template` SKIP を確認
- 4.2 — `.bak` once-only（`CLAUDE.md.bak` / `<file>.bak` とも初回のみ）。Test G で確認
- 4.3 — CLAUDE.md 専用経路（`copy_claude_md_with_org`）が `.bak` を一切参照・改変しない（コード上 `.bak` 参照なし）
- 5.1 — `--dry-run --force` で CLAUDE.md SKIP + `.org` NEW 分類。Test D で確認
- 5.2 — `--dry-run --force` で agents が BACKUP+OVERWRITE 分類。Test F で reviewer.md の BACKUP+OVERWRITE を確認
- 5.3 — `--dry-run --force-claude-md` で CLAUDE.md BACKUP+OVERWRITE 分類。Test E で確認
- 5.4 — `--dry-run` で FS 変更なし。Test D/E で before==after（md5sum 集計）を確認
- 6.1 — README に「`--force` 単体は CLAUDE.md 据え置き + `.org` 並置」migration note 追記（README:298-315, 337-344）
- 6.2 — README に `--force-claude-md` 記載（テーブル列 / 違い blockquote / フラグ表 / 使いどころ）
- 6.3 — install.sh ヘッダコメントに `--force` / `--force-claude-md` の挙動差を記載（install.sh:18-26）
- 6.4 — `--help` に `--force-claude-md` を含む（`sed -n '3,28p'` に範囲拡張）。Test H で grep 一致を確認
- 6.5 — merge ガイドで `--force-claude-md` を案内（install.sh:1203-1205）。Test A / Test J で出力を確認
- NFR 1.1 — env var 追加なし（`FORCE_CLAUDE_MD` は内部変数のみ）。diff で env var 名変更が無いことを確認
- NFR 1.2 — exit code 不変（成功 0 / 未知オプション 1）。Test I で `--bogus` → exit 1 を確認
- NFR 1.3 — `[INSTALL]`/`[DRY-RUN]` prefix と `NEW`/`OVERWRITE`/`SKIP`/`BACKUP` 語彙を維持（全スモークログで確認）
- NFR 1.4 — フラグ無し通常経路が導入前と同一。Test J で 据え置き + `.org` 並置を確認
- NFR 2.1 — root 実行検知ブロック未変更、新フラグは sudo を要求しない（diff で当該ブロック不変更を確認）

## Findings

なし

## Summary

全 numeric AC（1.1〜6.5）および NFR 1.1〜2.1 を独立スモークテスト（Test A〜M）とコード経路で検証し、
すべてカバー済み。`--force`（agents/rules 経路 = `copy_with_hybrid_overwrite`）と `--force-claude-md`
（CLAUDE.md 経路 = `copy_claude_md_with_org` + `backup_claude_md_once`）の分離は局所的で、Out of Scope
（agents 同期アルゴリズム / ISSUE_TEMPLATE / labels）への侵食や後方互換破壊は検出されなかった。
`shellcheck install.sh` 警告ゼロ。missing test・boundary 逸脱なし。

RESULT: approve
