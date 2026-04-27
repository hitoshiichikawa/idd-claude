# Implementation Notes: install.sh 冪等性バグ修正と配置漏れ予防 (#36)

## 実装サマリ

`install.sh` に以下のヘルパー関数群を追加し、既存の `setup_repo` / `setup_local_watcher` ブロック
の個別 `cp` 呼び出しをヘルパー経由に置換した。

- 出力／分類層: `log_action` / `files_equal` / `classify_action` / `ensure_dir`
- ファイル操作層: `copy_template_file` / `copy_glob_to_homebin` / `backup_claude_md_once` /
  `copy_with_hybrid_overwrite` / `copy_agents_rules`
- グローバルフラグ: `DRY_RUN` / `FORCE`、CLI フラグ `--dry-run` / `--force` を追加し `-h` / `--help`
  にも記載

`local-watcher/bin/` 配下の `*.sh` / `*.tmpl` をワイルドカード配置に切り替えたため、新規
`*.tmpl` / `*.sh` 追加で `install.sh` を書き換えなくて済むようになった。

## 完了タスク

design.md / tasks.md の numeric ID 順に消化:

| Task ID | 内容 | Commit |
|---|---|---|
| 1.1 / 1.2 / 1.3 | ヘルパー関数群（出力／分類層 + ファイル操作層 + ハイブリッド safe-overwrite）の追加 | `feat(install): add idempotency helpers (log_action / classify / copy_*)` |
| 2.1 | `--dry-run` / `--force` 引数パースとヘルプ更新 | `feat(install): add --dry-run / --force flags and update help` |
| 3.1 | `setup_repo` ブロックの個別 cp をヘルパー呼び出しに置換 | `refactor(install): replace setup_repo cp calls with idempotent helpers` |
| 4.1 | `setup_local_watcher` ブロックのワイルドカード化 | `refactor(install): wildcard-deploy local-watcher/bin via copy_glob_to_homebin` |
| 5.1 | `setup.sh` の引数透過確認（修正不要） | （docs only、本ファイルに記録） |
| 6.1 | README に冪等性ポリシー節を追加 | `docs(readme): document install.sh idempotency policy and --dry-run` |
| 7.1 | shellcheck と統合スモークテスト | （本ファイル末尾の Test Results 参照） |
| - | CLAUDE.md ハンドラの design.md 解釈差分修正 | `fix(install): treat CLAUDE.md body as meta-file after once-only backup` |

タスク 8（dogfood E2E、deferrable）は dry-run 経路のみ実施（破壊的変更を本 repo に直接当てたくない
ため、実 install までは行っていない）。

## 設計判断・解釈の補足

### CLAUDE.md ハンドラを `copy_with_hybrid_overwrite` から `copy_template_file` に変更

design.md 「setup_repo ブロック」セクションでは「CLAUDE.md も agents/rules と同じハイブリッド
ポリシーで処理する関数を呼ぶ」と記載されていたが、その直後の設計判断で:

> （`<repo>/CLAUDE.md.bak` が既にあるので、ハイブリッド側は `.bak` 退避をスキップしてそのまま
> OVERWRITE / SKIP のみを行う）

と記述されており、**`backup_claude_md_once` で `.bak` を作った直後に hybrid を呼ぶと、`.bak` 既存
状態で OVERWRITE が走る**ことを期待していた。

しかし実装上 `copy_with_hybrid_overwrite` は agents/rules 用に「`.bak` 既存 + `--force` なし =
SKIP（カスタム編集を予告なく失わせない）」という要件 3.1 の精神を実装している。これを CLAUDE.md
にそのまま適用すると:

- 利用者の既存 CLAUDE.md → `backup_claude_md_once` が `.bak` に退避 → `copy_with_hybrid_overwrite`
  が「`.bak` 既存」を検知して SKIP（`use --force to overwrite`）→ template 由来 CLAUDE.md が
  配置されない

これは要件 2.5（CLAUDE.md 不在時はテンプレート由来 CLAUDE.md を新規配置する）および要件 5.4
（従来配置されていたファイル群を引き続き配置する）に対する後方互換違反となる。

**判断**: design.md の「ハイブリッド側は `.bak` 退避をスキップして OVERWRITE / SKIP のみ」という
**意図**を、agents/rules とは異なる経路で実現する形に補正した。すなわち CLAUDE.md は:

1. `backup_claude_md_once` で `.bak` once-only 退避（`.bak` がなければ作る、あれば触らない）
2. `copy_template_file`（meta files 用、`.bak` を作らない、既存と同一なら SKIP / 差分ありなら
   無条件 OVERWRITE）で本体を配置

これにより、要件 2.x（`.bak` once-only 保護）と要件 5.4（template 由来 CLAUDE.md は常に配置）の
両方を満たし、design.md の「ハイブリッド側は OVERWRITE / SKIP のみ」の意図とも整合する。

design.md 自体は書き換えていない（人間レビュー済みのため）。本判断は「確認事項」として PR 本文に
明記する。

### `--dry-run` 中の重複 BACKUP 表記

dogfood dry-run（`./install.sh --repo .`）で、最初の修正前は CLAUDE.md について `[DRY-RUN]
BACKUP CLAUDE.md → CLAUDE.md.bak` が 2 回出ていた（`backup_claude_md_once` と
`copy_with_hybrid_overwrite` が両方とも `.bak` 不在を検知したため）。これは上記の CLAUDE.md ハンドラ
変更で解消した。

### `--dry-run` 後の dry-run で BACKUP のみ残るケース

design.md の「Dry-run Tests 3: 実 install 後の `--dry-run` で SKIP のみ」は理想形だが、初回 install
後（CLAUDE.md.bak がまだ存在しない状態）で再度 dry-run すると:

```
[DRY-RUN] BACKUP    /path/CLAUDE.md → CLAUDE.md.bak
[DRY-RUN] SKIP      /path/CLAUDE.md (identical to template)
[DRY-RUN] SKIP      /path/.claude/agents/...md (identical to template)
...
```

のように `BACKUP` 行が出る。これは「次回実行時に `.bak` を作る」という once-only 規律と整合する
**想定挙動**。要件 4.5 の本質は「dry-run の `NEW` / `OVERWRITE` 分類が実実行と一致する」ことで、
これは検証済み。要件 2 や 4 はこの BACKUP 表記を禁じていない。

ただ、CLAUDE.md.bak を含む完全な冪等点に到達するには、対象 repo に最初から CLAUDE.md.bak が
あれば 2 回目以降は SKIP のみ（BACKUP も出ない）になる。

### `setup.sh` 経由の `--dry-run` 透過

`setup.sh` の最終行 `exec bash "$IDD_CLAUDE_DIR/install.sh" "$@"` が全引数を透過するため、
`install.sh` 側で `--dry-run` を受理するように追加するだけで `setup.sh --dry-run` も成立する
（DR-4）。setup.sh 自体の修正は不要。

E2E 検証は `setup.sh` の git clone 部分がネットワーク依存（および本リポジトリ自身を IDD_CLAUDE_DIR
にすると fetch/checkout 周りで競合する）のため、静的確認 + install.sh 単体動作で代替した。実
ネット環境での E2E は本実装後の運用で必要に応じて確認する。

## 受入基準達成確認

各 requirement numeric ID をどのテストで担保したかを以下に記す。テストは `/tmp/scratch-*` の
使い捨て環境での手動スモークテスト（design.md「Integration Tests」「Dry-run Tests」全項目）で
実施した。

| Req ID | 概要 | 担保テスト |
|---|---|---|
| 1.1 | `*.sh` の宣言的配置 | `--local --dry-run` で `issue-watcher.sh` が `(chmod +x)` 付きで列挙 |
| 1.2 | `*.tmpl` の宣言的配置 | `--local --dry-run` で `triage-prompt.tmpl` / `iteration-prompt.tmpl` が列挙 |
| 1.3 | 新規 `*.tmpl` 追加で install.sh 修正不要 | `local-watcher/bin/iteration-prompt-design.tmpl` を一時追加 → `--local --dry-run` で `[DRY-RUN] NEW iteration-prompt-design.tmpl` 列挙確認（IT-6） |
| 1.4 | `*.sh` への chmod +x 一括付与 | `copy_glob_to_homebin --executable` 経路、`(chmod +x)` ノートで観測 |
| 1.5 | 既存ファイル集合の同等性 | IT-1 で 15 ファイル NEW（CLAUDE.md / agents 6 / rules 5 / .github 3）を全配置確認 |
| 1.6 | マッチ 0 件で正常終了 | helpers 単体テスト: `copy_glob_to_homebin /tmp/empty "*.nope"` で `SKIP (no files matched)` + exit 0 |
| 2.1 | 初回バックアップ | IT-2: `BACKUP CLAUDE.md → CLAUDE.md.bak` が観測、`USER_ORIGINAL` が bak に温存 |
| 2.2 | 既存 .bak は上書きしない | IT-3: 2 回目実行で `SKIP (existing .bak preserved)` + bak 不変 |
| 2.3 | 保持を標準出力に記録 | `[INSTALL] SKIP CLAUDE.md.bak (existing .bak preserved)` のログ確認 |
| 2.4 | 連続再実行で .bak 内容不変 | IT-3: md5sum diff で bak 不変を確認 |
| 2.5 | CLAUDE.md 不在時はバックアップしない | IT-1: scratch 空ディレクトリで `BACKUP` 行が出ないことを確認（`backup_claude_md_once` の no-op 分岐） |
| 3.1 | 無告知の上書きをしない | IT-4: developer.md カスタム編集 → `BACKUP developer.md → developer.md.bak (custom edits detected)` + `OVERWRITE`、無告知ではない |
| 3.2 | 不在ファイルは新規配置 | IT-1: agents/rules 全ファイル NEW |
| 3.3 | NEW/OVERWRITE/SKIP のファイル単位ログ | log_action 単体テスト + IT-1〜5 全工程で観測 |
| 3.4 | --force opt-in で上書き許可 | IT-5: `--force` で `OVERWRITE` 実行 |
| 3.5 | 上書き時の事後復元手段（.bak） | IT-4: developer.md.bak が CUSTOM EDIT を保持 |
| 3.6 | --help でポリシー文書化 | `install.sh --help` 出力に `--dry-run` / `--force` の挙動説明 4 行追記 |
| 4.1 | --dry-run でファイルシステム不変 | DR-1: `--dry-run` 後の find で 0 件 |
| 4.2 | 各ファイルパスを stdout に列挙 | DR-1 出力 41 行（agents/rules/.github/CLAUDE.md 全網羅） |
| 4.3 | NEW/OVERWRITE/SKIP の判別可能な形式 | `[DRY-RUN] <ACTION> <path> [<note>]` 統一フォーマット |
| 4.4 | dry-run で exit 0 | dry-run スモーク全工程で exit 0 |
| 4.5 | dry-run と実実行の分類が一致 | DR-2: `grep '^\[DRY-RUN\] NEW'` の集合と `grep '^\[INSTALL\] NEW'` の集合が `diff` で一致 |
| 4.6 | --help に --dry-run 記載 | install.sh ヘッダコメント 19-20 行に記載 |
| 5.1 | 既存起動形式の維持 | `--repo` / `--local` / `--all` / `-h` / `--help` 全て従来通り受理（追加フラグのみ） |
| 5.2 | 既存 env var 名・意味・既定値を変えない | install.sh で env var を新規参照していない（DRY_RUN/FORCE はフラグのみ） |
| 5.3 | cron / launchd 登録文字列の書き換え不要 | watcher 配置先 `$HOME/bin/issue-watcher.sh` 不変、CRON_HINT 無変更 |
| 5.4 | 配置ファイル群は従来と同じ | IT-1 で従来同等の 15 ファイル配置を確認、CLAUDE.md ハンドラ修正で template 由来配置を保証 |
| 5.5 | ラベル定義の名前変更なし | `idd-claude-labels.sh` は本改修で touch しない（copy_template_file で配置するだけ） |
| 5.6 | sudo 警告の維持 | sudo 検知ブロック（行 24-35）無変更 |
| 6.1 | README に CLAUDE.md.bak 仕様記載 | README 「冪等性ポリシーと再実行時の挙動」節 |
| 6.2 | README に agents / rules 上書き挙動記載 | 同上、5 パス決定表 |
| 6.3 | README に --dry-run 使い方記載 | 同上、出力例 + prefix 表 + setup.sh 経由透過説明 |
| 6.4 | 既存利用者の追加手順がない／最小である | README Migration Note |
| NFR 1.1 | 連続再実行で差分なし | IT-3, IT-4 で bak / 配置ファイルの md5 不変を確認 |
| NFR 1.2 | --dry-run のみで副作用切替 | `DRY_RUN` フラグ一元化、各ヘルパー内分岐 |
| NFR 2.1 | 各操作の path と分類を stdout 出力 | log_action 統一フォーマット |
| NFR 2.2 | エラーは stderr + 非ゼロ exit | 既存 `echo ... >&2 + exit 1` 維持、新規エラー（例: `cmp` 不在）は同パターン |
| NFR 3.1 | $HOME 配下のみで完結 | 配置先は `$HOME/bin` / `$HOME/Library` / `$REPO_PATH` のみ。新規 sudo 不要 |

## Test Results

### 静的解析

```
$ shellcheck install.sh
(no warnings)

$ bash -n install.sh
(no errors)
```

### Integration Tests（design.md 準拠、6 項目）

| # | テスト | 結果 |
|---|---|---|
| IT-1 | 初回 install で全ファイル NEW（CLAUDE.md なし scratch） | OK（15 NEW、副作用は scratch 内のみ） |
| IT-2 | 既存ユーザ CLAUDE.md → BACKUP+OVERWRITE | OK（USER_ORIGINAL が bak に温存） |
| IT-3 | 再実行で CLAUDE.md.bak 温存 + agents/rules SKIP | OK（bak preserved + identical to template） |
| IT-4 | agents/developer.md カスタム → BACKUP+OVERWRITE → 再々実行 SKIP | OK（once-only 規律で SECOND CUSTOM が bak に入らない） |
| IT-5 | `--force` で OVERWRITE のみ、bak 温存 | OK（bak md5 不変） |
| IT-6 | `local-watcher/bin/` に新規 `*.tmpl` 追加 → `--local --dry-run` で NEW 列挙 | OK（4 ファイル全部検出） |

### Dry-run Tests（design.md 準拠、4 項目）

| # | テスト | 結果 |
|---|---|---|
| DR-1 | `--dry-run` でファイルシステム未変更 | OK（scratch 内 entry 0 件） |
| DR-2 | dry-run の NEW 集合と実 install の NEW 集合が一致 | OK（diff 結果が空） |
| DR-3 | 実 install 後の dry-run で NEW なし | OK（残るのは BACKUP（CLAUDE.md.bak がまだ無いケース）と SKIP） |
| DR-4 | setup.sh 経由透過 | 静的確認 OK（最終行 `exec bash ... "$@"`）+ install.sh 単体で `--dry-run` 動作確認 |

### Dogfood E2E (dry-run only)

```
$ ./install.sh --repo . --dry-run
[DRY-RUN] BACKUP    /home/hitoshi/github/idd-claude-watcher/CLAUDE.md → CLAUDE.md.bak
[DRY-RUN] OVERWRITE /home/hitoshi/github/idd-claude-watcher/CLAUDE.md
[DRY-RUN] SKIP      ...architect.md (identical to template)
... (agents 6, rules 5, .github 3 全て SKIP identical to template)
[DRY-RUN] SKIP      .../idd-claude-labels.sh (identical to template)
```

self-hosting で agents/rules/.github 系は同期済み、CLAUDE.md は本 repo の `./CLAUDE.md` と
`repo-template/CLAUDE.md` が異なる（前者がプロジェクト全体ガイド、後者がテンプレート）ため
`OVERWRITE` 表記が出るのは想定挙動。実 install は破壊的影響を避けるため未実施。

## 確認事項（PR 本文への候補）

PM / Architect / Reviewer に確認したい論点:

1. **CLAUDE.md ハンドラを `copy_with_hybrid_overwrite` から `copy_template_file` に変更**
   - design.md の文章では「CLAUDE.md も hybrid」と書かれているが、設計意図（「ハイブリッド側は
     `.bak` 退避をスキップして OVERWRITE / SKIP のみ」）と要件 2.5 / 5.4（template を新規配置 /
     従来配置を維持）に整合させるため、本実装では別経路（meta files 経路）を採用した
   - design.md の該当記述を将来の改修で更新するかどうかは Architect 判断
2. **「`--dry-run` 後 SKIP のみ」の Dry-run Test 3 の解釈**
   - 初回 install 後の dry-run では `CLAUDE.md.bak` がまだ無いため `BACKUP` 行が出る。これは
     once-only 規律と整合する想定挙動だが、design.md の Test 3 表現は厳密ではない
3. **dogfood 実 install の未実施**
   - 本リポジトリ自身に対する実 install (`./install.sh --repo .`) は dry-run のみ確認した。実 install
     は別 Issue で本 repo の `repo-template/` 同期作業として走らせるのが安全
