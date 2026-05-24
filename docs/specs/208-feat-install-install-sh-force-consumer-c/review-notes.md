# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-25T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-208-impl-feat-install-install-sh-force-consumer-c
- HEAD commit: dfee1ab7d7e39ae57b14c82c895861192cee28e7
- Compared to: main..HEAD
- 変更ファイル: `install.sh` / `README.md` / `docs/specs/208-.../requirements.md` / `impl-notes.md` / `review-notes.md`
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節が**存在しない** → opt-out 解釈。
  通常の 3 カテゴリ（AC 未カバー / missing test / boundary 逸脱）のみで判定し、flag 観点の細目は適用しない。

## Verified Requirements

各 AC を install.sh のコード経路で追跡し、impl-notes.md の手動スモーク scenario（S1〜S6）と
照合した。`shellcheck install.sh` を独立に再実行し警告ゼロを確認。

- 1.1 — `--force` 単体で既存 CLAUDE.md を据え置き（`copy_claude_md_with_org` 通常経路 OVERWRITE→`SKIP (existing kept...)`、install.sh:511-514）。`--force` は `FORCE_CLAUDE_MD=false` のため通常経路を通る（install.sh:493）
- 1.2 — `--force` で `CLAUDE.md.org` を NEW/OVERWRITE 並置（install.sh:517-538）
- 1.3 — CLAUDE.md が template と同一なら `SKIP (identical)` + `.org` 不作成（install.sh:507-510）
- 1.4 — CLAUDE.md 不在は NEW 配置・`.org` 不作成（install.sh:497-506、NEW 分岐は flag 非依存）
- 1.5 — `--force` 単体で `.bak` 退避なし（`backup_claude_md_once` 発火条件を `FORCE_CLAUDE_MD=true` に限定、install.sh:1138 付近）
- 2.1 — `--force-claude-md` で `.bak` once-only 退避後 template 上書き（install.sh:468-490 + 呼び出し側 backup）
- 2.2 — `.bak` once-only 温存（既存 `backup_claude_md_once` のロジックに委譲、本 PR 未変更）
- 2.3 — `--force-claude-md` 経路は `.org` を参照・変更しない（install.sh:468-491）
- 2.4 — `FORCE_CLAUDE_MD=false` なら CLAUDE.md を上書きしない（`--force` の有無に関わらず通常経路、install.sh:468, 493）
- 2.5 — `--force --force-claude-md` 併用で agents/rules も CLAUDE.md も上書き（`FORCE` と `FORCE_CLAUDE_MD` は独立変数）
- 3.1/3.2 — `--force` で agents/rules を `.bak` once-only + 上書き（`copy_with_hybrid_overwrite` **未変更**、引き続き `FORCE` 参照）
- 3.3 — `--force` なしで `.bak` 既存なら SKIP（`copy_with_hybrid_overwrite` 未変更、diff に現れず regression 無し）
- 3.4 — ISSUE_TEMPLATE / workflows / labels（`copy_template_file` 等）未変更（diff 上 CLAUDE.md 経路以外に変更なし）
- 4.1 — 同一引数の再実行で SKIP（install.sh:507-510, 480-482）
- 4.2 — `.bak` once-only（`CLAUDE.md.bak` / `<file>.bak` とも初回のみ）
- 4.3 — CLAUDE.md 専用経路（`copy_claude_md_with_org`）が `.bak` を一切参照・改変しない（install.sh:450 コメント + 関数本体で確認）
- 5.1 — `--dry-run --force` で CLAUDE.md SKIP + `.org` NEW/OVERWRITE 分類。`DRY_RUN=false` ガードで FS 変更抑止（install.sh:520, 534）
- 5.2 — `--dry-run --force` で agents が BACKUP+OVERWRITE 分類（既存経路、未変更）
- 5.3 — `--dry-run --force-claude-md` で CLAUDE.md BACKUP+OVERWRITE 分類。`DRY_RUN=false` ガード（install.sh:485）
- 5.4 — 全分岐に `[ "$DRY_RUN" = "false" ]` ガードあり、分類ログのみ出力
- 6.1 — README に「`--force` 単体は CLAUDE.md 据え置き + `.org` 並置」migration note 追記（README diff: Migration セクション）
- 6.2 — README に `--force-claude-md` 記載（テーブル列 / 違い blockquote / フラグ表 / 使いどころ手順）
- 6.3 — install.sh ヘッダコメントに `--force` / `--force-claude-md` の CLAUDE.md 挙動差を記載（install.sh:18-26）
- 6.4 — `--help` 範囲を `sed -n '3,23p'` → `'3,28p'` に拡張し `--force-claude-md` 行を含む（install.sh:114）
- 6.5 — merge ガイド（CLAUDE_MD_ORG_HINT）で `--force-claude-md` 案内と `--force` 単体注記を追加（install.sh:1203-1205）
- NFR 1.1 — env var 追加なし（`FORCE_CLAUDE_MD` は内部変数のみ）。diff で env var 名変更なし
- NFR 1.2 — exit code 経路未変更（成功 0 / 未知オプション 1）
- NFR 1.3 — `[INSTALL]`/`[DRY-RUN]` prefix と `NEW`/`OVERWRITE`/`SKIP`/`BACKUP` 語彙を維持
- NFR 1.4 — フラグ無し通常経路が導入前と同一（据え置き + `.org` 並置）
- NFR 2.1 — root 実行検知ブロック未変更、新フラグは sudo を要求しない

## Findings

なし

## Summary

全 numeric AC（1.1〜6.5）および NFR 1.1〜2.1 に対応する実装をコード経路で確認し、すべて
カバー済み。`--force` の CLAUDE.md 上書き分岐を `FORCE_CLAUDE_MD` 駆動へ付け替え、`--force`
単体では CLAUDE.md を据え置く設計が正しく実装されている。本リポジトリの規約（unit test
フレームワーク無し、検証は shellcheck + 手動スモーク）に従い、impl-notes.md に S1〜S6 の
スモーク scenario と AC 対応表が記載されており missing test に該当しない。`shellcheck
install.sh` を再実行し警告ゼロを確認。tasks.md は不在で `_Boundary:_` 制約は無く、変更は
install.sh / README.md / spec 配下に限定され Out of Scope の不変対象（agents/rules 同期
ロジック・setup.sh・ラベル/workflow）に触れていない。

RESULT: approve
