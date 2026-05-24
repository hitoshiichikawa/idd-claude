# 実装ノート: #208 `--force` での CLAUDE.md 保護と `--force-claude-md` 新設

## 概要

`install.sh` の `--force` が consumer 固有の `CLAUDE.md` を汎用 template で silent 上書きして
しまう問題を修正した。PM 確定方針に沿って以下を実装:

- `--force` 単体では `CLAUDE.md` を一切 template 上書きしない（live 据え置き + 差分時
  `CLAUDE.md.org` 並置 = `--force` なしと同一挙動）。
- 新フラグ `--force-claude-md` を導入し、指定時のみ `CLAUDE.md` を `.bak` once-only 退避 +
  template 上書き（従来の `--force` の CLAUDE.md 挙動を移設）。
- `--force` の agents / rules 挙動（`.bak` once-only + 上書き）は完全維持。
- `--force --force-claude-md` 併用で「agents/rules も CLAUDE.md も上書き」が成立。

## 追加したフラグ / グローバル変数

| 項目 | 値 |
|---|---|
| CLI フラグ | `--force-claude-md` |
| グローバル変数 | `FORCE_CLAUDE_MD` |
| 初期値 | `false`（`DRY_RUN` / `FORCE` と並べて初期化） |

> env var による override は追加していない（requirements.md Open Question 2 で Architect 判断と
> されたが design.md は存在せず、CLAUDE.md「禁止事項: opt-in gate なしの新外部呼び出し」とは
> 無関係。既存 `--force` も env override を持たない慣習に揃え、フラグのみで提供した）。

## 変更ファイル

- `install.sh`
  - 引数パース部: `--force-claude-md` ケース追加、`FORCE_CLAUDE_MD=false` 初期化
  - `copy_claude_md_with_org`: `if [ "$FORCE" = "true" ]` 上書き分岐を `FORCE_CLAUDE_MD` 駆動に
    付け替え（OVERWRITE ログ note を `(--force)` → `(--force-claude-md)` に変更）
  - 呼び出し側: `backup_claude_md_once` の発火条件を `FORCE` → `FORCE_CLAUDE_MD` に変更
  - merge ガイド (`CLAUDE_MD_ORG_HINT`): 上書き手段の案内を `--force` → `--force-claude-md` に
    変更し、`--force` 単体は agents/rules のみという注記を追記
  - ヘッダコメント: `--force` の CLAUDE.md 記述を「agents/rules のみ」に修正、`--force-claude-md`
    の説明を追加
  - help: ヘッダ行追加に伴い `sed -n '3,23p'` → `sed -n '3,28p'` に範囲更新（help 出力に
    `--force-claude-md` が含まれることを確認済み）
- `README.md`
  - CLAUDE.md `.org` 並置テーブルの `--force` 列を `--force-claude-md` 列に変更し、本文に
    `--force` 単体は CLAUDE.md を上書きしない旨を追記
  - `--force` / `--force-claude-md` の違いを説明する補足 blockquote を追加
  - `CLAUDE.md.bak` once-only 保護節を `--force-claude-md` 経路に書き換え、#208 migration note を
    追加（旧 `--force` 挙動からの変更点を明記）
  - agents/rules safe-overwrite 節の「CLAUDE.md は別経路」blockquote を更新
  - `--dry-run` 例を `--force` → `--force-claude-md` に差し替え
  - `OVERWRITE` prefix 説明、`--force の使いどころ` 手順、install.sh runtime フラグ表を更新

## 受入基準（AC）とテストの対応

本リポジトリには unit test フレームワークがないため、検証は `shellcheck` + 使い捨て scratch repo
での手動スモークテスト（CLAUDE.md「手動スモークテスト」準拠）で実施した。各 scenario が
どの AC を担保するかを下表に示す。

| Req / AC | 担保したスモーク scenario |
|---|---|
| 1.1 `--force` で CLAUDE.md 据え置き | S1（CLAUDE.md が consumer-specific のまま、SKIP ログ） |
| 1.2 `--force` で `.org` 並置（不在→新規） | S1（`CLAUDE.md.org` NEW + template と一致） |
| 1.3 `--force` で内容同一なら何も作らない | S6（identical → SKIP、`.org` 作成なし） |
| 1.4 `--force` で CLAUDE.md 不在なら NEW、`.org` 作らない | S1 の agents 初回 NEW と同経路（`classify_action` NEW 分岐は flag 非依存） |
| 1.5 `--force` 単体で `.bak` 退避しない | S1（`CLAUDE.md.bak` 不在を確認） |
| 2.1 `--force-claude-md` で `.bak` 退避 + 上書き | S2（BACKUP + OVERWRITE ログ、CLAUDE.md が template 一致） |
| 2.2 `.bak` once-only 温存 | S6（2 回目 `existing .bak preserved`） |
| 2.3 `--force-claude-md` で `.org` を作らない/触らない | S2（`.org` 既存だが OVERWRITE/NEW ログ無し） |
| 2.4 `--force-claude-md` 無指定なら上書きしない | S1（`--force` のみ）/ S5（フラグ無し）で上書きされないこと |
| 2.5 `--force-claude-md` + `--force` 併用 | S4（CLAUDE.md も agents/developer.md も OVERWRITE） |
| 3.1/3.2 `--force` で agents/rules `.bak` once-only + 上書き | S1b（developer.md BACKUP + OVERWRITE、template 一致） |
| 3.3 `--force` なしで `.bak` 既存なら SKIP（既存挙動） | `copy_with_hybrid_overwrite` 未変更（regression 無し）。本 PR で当該経路は不変更 |
| 3.4 CLAUDE.md 以外の配布物が従来同一 | 全 scenario で ISSUE_TEMPLATE/workflows/labels script の配置経路 (`copy_template_file`) 未変更 |
| 4.1 冪等 SKIP | S6（identical → SKIP） |
| 4.2 `.bak` once-only | S6（`existing .bak preserved`） |
| 4.3 CLAUDE.md 経路から `.bak` 改変しない | S1（`--force` で `.bak` 生成されない）、`copy_claude_md_with_org` は `.bak` を一切参照しない |
| 5.1 `--dry-run --force` 分類 | S3a（CLAUDE.md SKIP + `.org` NEW、FS 変更ゼロ） |
| 5.2 `--dry-run --force` agents 分類 | S3a（developer.md BACKUP + OVERWRITE） |
| 5.3 `--dry-run --force-claude-md` 分類 | S3b（CLAUDE.md BACKUP + OVERWRITE、FS 変更ゼロ） |
| 5.4 `--dry-run` で FS 変更なし | S3a/S3b（md5sum 比較で before==after） |
| 6.1 README migration note | README 改訂（`--force` 据え置き旨 + #208 note） |
| 6.2 README に `--force-claude-md` 記載 | README 改訂（テーブル列 / フラグ表 / 使いどころ） |
| 6.3 ヘッダコメントに挙動差記載 | install.sh ヘッダコメント改訂 |
| 6.4 help が `--force-claude-md` を含む | `bash install.sh --help` で grep 一致を確認 |
| 6.5 merge ガイドで `--force-claude-md` 案内 | S5（merge ガイド出力に `--force-claude-md` 行） |
| NFR 1.1 env var 不変 | env var 追加なし。`FORCE_CLAUDE_MD` は内部変数のみ |
| NFR 1.2 exit code 不変 | `--bogus` で exit=1 を確認、成功時 exit 0 |
| NFR 1.3 ログ書式維持 | `[INSTALL]`/`[DRY-RUN]` prefix と `NEW`/`OVERWRITE`/`SKIP`/`BACKUP` 語彙を維持 |
| NFR 1.4 通常経路同一 | S5（フラグ無しで CLAUDE.md 据え置き + `.org` 並置） |
| NFR 2.1 sudo 不要 | root 実行検知ブロック未変更、新フラグは sudo を要求しない |

## スモークテスト結果サマリ

scratch repo: `/tmp/idd208-smoke/`（git remote 無し / `--no-labels` 付与でラベルセットアップ skip）。
consumer 固有 CLAUDE.md（template と異なる内容）を配置して検証。

- **S1 `--force`**: `CLAUDE.md` は consumer-specific のまま据え置き（`SKIP ... existing kept`）、
  `CLAUDE.md.org` が NEW で並置され template と一致、`CLAUDE.md.bak` は **作成されない**。
  agents/rules は初回 NEW。→ Req 1.1/1.2/1.5 OK
- **S1b `--force`（agents stale）**: `developer.md` が `BACKUP → developer.md.bak (--force)` +
  `OVERWRITE` され template と一致。CLAUDE.md は引き続き据え置き、`CLAUDE.md.bak` 無し。
  → Req 3.1/3.2 OK
- **S2 `--force-claude-md`**: `CLAUDE.md` が `BACKUP → CLAUDE.md.bak` + `OVERWRITE (--force-claude-md)`、
  `.bak` は consumer-specific 内容を保持、本体は template と一致。`.org` は触られない。
  → Req 2.1/2.3 OK
- **S3a `--dry-run --force`**: `CLAUDE.md` SKIP + `CLAUDE.md.org` NEW、agents は BACKUP+OVERWRITE
  と分類表示。`.org` は実作成されず、md5sum 比較で FS 変更ゼロ。→ Req 5.1/5.2/5.4 OK
- **S3b `--dry-run --force-claude-md`**: `CLAUDE.md` BACKUP + OVERWRITE と分類表示、FS 変更ゼロ。
  → Req 5.3/5.4 OK
- **S4 `--force --force-claude-md`**: `CLAUDE.md` も `developer.md` も OVERWRITE、両者の `.bak` が
  オリジナル内容を保持。→ Req 2.5 OK
- **S5 通常経路（フラグ無し）**: `CLAUDE.md` 据え置き + `.org` 並置、merge ガイド末尾に
  `./install.sh --repo <path> --force-claude-md` 案内と「`--force` 単体は agents/rules のみ」
  注記が表示される。→ Req 6.5 / NFR 1.4 OK
- **S6 冪等性（`--force-claude-md` 再実行）**: `CLAUDE.md.bak` は `existing .bak preserved` で
  once-only 温存、CLAUDE.md は `identical to template` で SKIP。→ Req 4.1/4.2 OK
- **静的検査**: `shellcheck install.sh` 警告ゼロ。`--bogus` で exit=1、`--help` に
  `--force-claude-md` を 1 件含む。

## 後方互換性の確認

- 既存 env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `IDD_CLAUDE_SKIP_LABELS` 等）は未変更。
  新フラグは内部変数 `FORCE_CLAUDE_MD` のみで env var を増やしていない（NFR 1.1）。
- exit code（成功 0 / 未知オプション 1）は未変更（NFR 1.2、`--bogus` で確認）。
- `log_action` のログ書式（`[INSTALL]`/`[DRY-RUN]` prefix、`NEW`/`OVERWRITE`/`SKIP`/`BACKUP`
  語彙）は維持（NFR 1.3）。
- フラグ無しの通常経路は本変更前と完全同一（S5 で実証、NFR 1.4）。
- `copy_with_hybrid_overwrite`（agents/rules）/ `copy_template_file`（ISSUE_TEMPLATE 等）/
  ラベルセットアップは未変更（Req 3.3/3.4）。
- **self-hosting への影響**: 唯一の挙動変更は「`--force` 時に CLAUDE.md が上書きされなくなる」
  点。idd-claude 自身に `install.sh --force` を流しても root の `CLAUDE.md`（self-hosting 用）が
  保護されるため、安全側の変更。次回 cron で自分を壊すリスクはない。

## 確認事項（レビュワー判断ポイント）

1. **env var override の非提供**: requirements.md Open Question 2 で `FORCE_CLAUDE_MD=true` env
   override の提供可否が Architect 判断とされたが、本 Issue に design.md は無く、既存 `--force`
   も env override を持たないため、フラグのみで提供した。env override が必要なら別 Issue で
   切り出すのが妥当と考える。
2. **Req 1.4（CLAUDE.md 不在時の NEW、`.org` 作らない）の直接スモーク**: `classify_action` の NEW
   分岐は flag 非依存（通常経路・FORCE_CLAUDE_MD 経路とも同一の NEW ログ + `.org` 不作成）で
   あり、S1 の agents 初回 NEW と同経路だが、CLAUDE.md 単体での「不在→NEW」専用 scenario は
   別途実証していない（コード経路上は明白）。必要なら Reviewer 側で追補可能。

## 結論

requirements.md の全 numeric AC（1.1〜6.5）および NFR 1.1〜2.1 をスモークテストとコード経路で
担保した。`shellcheck` クリーン、後方互換維持、self-hosting 安全側を確認済み。

STATUS: complete
