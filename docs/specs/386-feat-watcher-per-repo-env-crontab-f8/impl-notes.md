# Implementation Notes — Issue #386 / F8

## 採用した module 構成と挿入点

- **module**: `local-watcher/bin/modules/env-loader.sh`（新規作成）
- **関数 prefix**: `el_`（新規未使用 prefix。CLAUDE.md §2 prefix 表に追記候補）
- **公開関数**:
  - `el_log` / `el_warn`: 既存 `fr_log` / `sn_log` と同形式の `[$REPO] env-loader:` 3 段 prefix
  - `el_resolve_env_file`: `WATCHER_ENV_FILE`（絶対パス）→ `$HOME/.issue-watcher/<REPO_SLUG>.env` の
    探索順で 1 つを stdout 出力、候補なし時 rc=1（純粋関数 / NFR 2.1 検証付き）
  - `el_apply_env_file`: 1 行ずつパースして export（precedence は `${KEY+x}` で判定）
  - `el_load`: public entry point（候補なしで silent no-op）
- **本体差し込み位置**: `local-watcher/bin/issue-watcher.sh` で REPO_SLUG 算出（line 57）の
  直後に **単独 source + `el_load` 呼出**。`REQUIRED_MODULES` への追加（line 1052）も併せて
  行い、開発時 / 本番配布の両方で module 欠落時に明示 exit する safety net を維持。
- **挿入位置の理由**: 本体内のすべての `*_ENABLED` 系 `${VAR:-default}` 評価より前で実行
  する必要がある（env ファイル経由で供給された値が Config 行で参照される）。Module loader
  本体（line 1052）より前に置く必要があるため、env-loader.sh のみ単独 source する 2 段構成。
  env-loader.sh は他 module に依存しない自己完結関数群のみで構成されるため、単独 source
  しても前方参照を踏まない。

## precedence 実現方式（inline cron env > env ファイル）

bash の **`${KEY+x}` 構文**（KEY が定義済みなら `"x"`、未定義なら空文字を返す）を用いて
「env に既に定義済みか」を判定。env-loader は **未定義 KEY のみ** export することで、
inline cron env の値を温存する。

- 空文字値の KEY も「定義済み」として扱う（inline での明示 unset と区別しない / Req 4.4）
- 本体の `KEY="${KEY:-default}"` 形式は `:-` を使うため空文字は default に置換されるが、
  env-loader は `${KEY+x}` で「key 存在性」のみを見る（NFR 1.3 後方互換性）

## `$HOME` / `$(...)` 値評価の実現方式

- env ファイルは「運用者管理ファイル = 信頼境界の内側」（NFR 2.4）として扱い、`eval` で
  起動シェルの展開を借りる
- ただし `eval "export $key=\"$value\""` 形式は POSIX 上 **export の rc を返す** ため、
  内部の command 置換失敗（非 0 終了）が rc=0 で覆い隠されてしまう
- 対策: **2 段構成** で実装
  1. `eval "$key=\"$value\""` （単純代入のみ）で値評価を試行。代入の rc は内部 command
     置換の rc を継承するため、コマンド置換失敗が rc=1 として観測される
  2. 代入成功時のみ `export "$key"`（既存変数の export 属性付与のみ、失敗しない）
- これにより、Req 3.2（正常コマンド置換）と Req 3.3（コマンド置換失敗 skip + 継続）の
  両方を満たす

## 異常系ハンドリング方針

| 異常系 | 挙動 | 対応 AC |
|---|---|---|
| ファイル不在 | silent return 0（no-op） | Req 5.1 / NFR 1.1 / NFR 3.3 |
| ファイル読取不能（権限不足等） | el_warn + return 1 | Req 6.1 |
| 構文不正行（`=` なし / 無効 KEY） | el_warn（パス + 行番号付き） + 当該行 skip + 後続継続 | Req 6.2 / 6.5 |
| コマンド置換失敗 | el_warn（パス + 行番号 + KEY 名）+ 当該 KEY skip + 後続継続 + unset で痕跡除去 | Req 3.3 / 6.3 |
| 採用後の値ログ | 採用パスのみ 1 行 log（値は出さない） | NFR 2.2 / NFR 3.1 |
| 候補なし時のログ | 一切出さない（通常運用の標準ログを増やさない） | NFR 3.3 |

## 後方互換確認の根拠（不在時のコードパス byte 等価性）

`issue-watcher.sh` への差し込みは以下の最小 7 行のみ:

```bash
IDD_ENV_LOADER_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)/modules/env-loader.sh"
if [ -f "$IDD_ENV_LOADER_PATH" ]; then
  # shellcheck source=/dev/null
  . "$IDD_ENV_LOADER_PATH"
  el_load
fi
unset IDD_ENV_LOADER_PATH
```

env ファイル不在時の `el_load` の挙動:
1. `el_resolve_env_file` が rc=1 で即 return（stdout / stderr いずれにも出力なし）
2. `el_load` が rc=0 で即 return（log なし）

つまり「候補なし」のとき、本体起動シーケンスへの実質的な影響は:
- 関数定義のメモリ消費（数 KB）
- `el_load` 1 回の関数呼び出しオーバーヘッド（< 1ms）

環境変数集合 / ログ出力 / exit code は不在時と完全に同一（NFR 1.1 / 1.3 byte 等価性は
意味的に維持 / 物理的には関数定義行が増えるが本体起動経路に観測可能な変化はない）。

`REQUIRED_MODULES` への追加（line 1052）は本体 module loader の冪等な再 source であり、
関数定義の上書きのみで副作用はない（既存 module の double-source 慣行と同等）。

スモークテストで 3 シナリオを確認:
1. env file あり → `full-auto=true` 反映
2. env file あり + inline `FULL_AUTO_ENABLED=false` → `full-auto=false` 反映（inline 勝ち）
3. env file なし → env-loader ログなし / 起動経路完全不変

## 追加テストの一覧と狙い

`local-watcher/test/env-loader_test.sh`（20 ケース、全 PASS）

| Section | テスト | 対応 AC |
|---|---|---|
| 1.1〜1.7 | el_resolve_env_file の探索順（明示 / per-repo fallback / 不在 / 相対パス無視 / 読取不能 fallback） | Req 1.1〜1.5 / NFR 2.1 |
| 2.1〜2.2 | KEY=VALUE 反映 / コメント・空行 skip | Req 2.2〜2.4 |
| 3.1〜3.3 | `$HOME` 展開 / `$(...)` 評価 / 置換失敗 skip + 後続継続 | Req 3.1〜3.3 / 6.3 |
| 4.1〜4.3 | inline > env ファイル / env ファイル単独採用 / 空文字 inline も「定義済み」 | Req 4.1〜4.4 |
| 5.1〜5.3 | 構文不正行 skip + warn / 無効識別子 KEY skip / 読取不能ファイル warn + rc=1 | Req 6.1 / 6.2 / 6.5 |
| 6.1〜6.2 | el_load entry point: 候補不在で no-op / 採用時 1 行ログ（値は出さない） | Req 5.1 / NFR 1.1 / NFR 2.2 / NFR 3.1 / NFR 3.3 |

## 同期確認結果

- `diff -r .claude/agents repo-template/.claude/agents` → 空（rc=0）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（rc=0）
- `repo-template/` 配下に local-watcher copies なし（root-only 配布、install.sh 経由）→ 確認済
- README.md に「per-repo env ファイル（crontab 行長限界の解消 / F8 / Issue #386）」節を追加
  - 探索順 / 形式 / precedence / 推奨パーミッション / 異常系 / 移行ガイド / Out of Scope を網羅
  - NFR 5.2 / 5.3 同一 PR 同期義務を満たす
- `install.sh` の module 配布は `copy_glob_to_homebin ... "*.sh"` のため、新規 module は
  install.sh 改修なしで自動配布される（既存 #177 Part 1 の設計を踏襲）

## 検証結果

| ツール | 結果 |
|---|---|
| `bash -n` (env-loader.sh / issue-watcher.sh / env-loader_test.sh) | OK |
| `shellcheck` (env-loader.sh / issue-watcher.sh / install.sh / setup.sh) | warning ゼロ |
| `shellcheck` (env-loader_test.sh) | info SC2016 のみ（CLAUDE.md「info 許容」基準内） |
| `bash local-watcher/test/env-loader_test.sh` | PASS=20 FAIL=0 |
| `bash local-watcher/test/full_auto_enabled_load_order_test.sh` | PASS=3 FAIL=0（既存回帰なし） |
| `bash local-watcher/test/module_loader_missing_test.sh` | PASS=7 FAIL=0（既存回帰なし） |
| `bash local-watcher/test/full_auto_enabled_test.sh` | PASS=28 FAIL=0（既存回帰なし） |
| `bash local-watcher/test/normalize_slug_test.sh` | PASS=12 FAIL=0（既存回帰なし） |
| `bash local-watcher/test/repo_prefix_log_test.sh` | PASS=36 FAIL=0（既存回帰なし） |
| `--doctor` smoke test（env file 採用 / inline override / 候補なし） | 3 経路すべて期待通り |

## AC Traceability

| Req | 担保 |
|---|---|
| Req 1.1 | env-loader.sh は issue-watcher.sh L60 で REPO_SLUG 算出直後に source・el_load 実行（flag 解決より前） |
| Req 1.2 | `el_resolve_env_file` テスト Sub 1.1 / 1.2（絶対パス採用 / 他候補無視） |
| Req 1.3 | テスト Sub 1.3 / 1.4（未設定 / 空文字で per-repo パス採用） |
| Req 1.4 | テスト Sub 1.3（per-repo パス採用） |
| Req 1.5 | テスト Sub 1.6（候補不在で rc=1 / silent） |
| Req 2.1〜2.4 | テスト Sub 2.1 / 2.2 / 3.1 / 3.2（KEY=VALUE / コメント / 空行 / 値展開） |
| Req 3.1 | テスト Sub 3.1（`$HOME` 展開） |
| Req 3.2 | テスト Sub 3.2（`$(...)` 評価） |
| Req 3.3 | テスト Sub 3.3 / 5.1（コマンド置換失敗 skip + 後続継続） |
| Req 3.4 | NFR 2.2 と同等。el_log / el_warn は値を含めない（実装上の制約） |
| Req 4.1〜4.4 | テスト Sub 4.1 / 4.2 / 4.3（inline > env ファイル / 単独 KEY / 空文字も定義済み扱い） |
| Req 5.1 | テスト Sub 6.1（候補不在で no-op、出力なし、rc=0） |
| Req 5.2 | 新規 gate env を追加していない（実装の構造的担保） |
| Req 5.3 | precedence テスト（Sub 4.1）で inline 列挙の従来挙動を確認 |
| Req 6.1 | テスト Sub 5.3（読取不能ファイルで warn + rc=1） |
| Req 6.2 | テスト Sub 5.1 / 5.2（構文不正 / 無効 KEY 行 skip + warn） |
| Req 6.3 | テスト Sub 3.3（コマンド置換失敗で当該 KEY 未設定維持） |
| Req 6.4 | テスト Sub 4.1 + 上記 Req 6.3 の組合せで担保（inline 補完が利く構造） |
| Req 6.5 | テスト Sub 5.1（warn に `section5.env:1` 形式でパスと行番号を含む） |
| NFR 1.1〜1.3 | スモーク 3 経路で env 集合・ログ・exit code 不変を確認 |
| NFR 2.1 | el_resolve_env_file の `case "$path" in /*)` 絶対パス検査 + `[ -f ] && [ -r ]` 通常ファイル + 読取権限検査 |
| NFR 2.2 | テスト Sub 6.2（採用ログにパスのみ・値は含まない） |
| NFR 2.3 | README.md「推奨パーミッション」節で `chmod 600` を明記 |
| NFR 2.4 | 実装上 `eval` を使い、サニタイズしない方針 |
| NFR 3.1 | テスト Sub 6.2（採用時 1 行 stdout ログ） |
| NFR 3.2 | テスト Sub 5.1 / 5.2 / 5.3（skip 理由 / 行番号を warn に含む） |
| NFR 3.3 | テスト Sub 6.1（候補不在で出力なし） |
| NFR 4.1 | `shellcheck` warning ゼロ / `bash -n` エラーなし |
| NFR 4.2 | env-loader_test.sh が 5 経路（採用 / precedence / `$(...)` / byte 等価 / 構文不正）すべてを fixture でカバー |
| NFR 5.1 | `repo-template/` に local-watcher copies は無く（root-only）、本機能は consumer 配布に影響しない（install.sh glob で自動配布） |
| NFR 5.2 | README.md に探索順 / 形式 / precedence / 推奨パーミッションを記述 |
| NFR 5.3 | README.md に「移行ガイド（既存 inline 列挙 → env ファイル）」節を記述 |

## 確認事項

なし。

- 要件定義は EARS 形式の AC が numeric ID で揃っており実装方針は一意に決まる
- design.md / tasks.md は本機能では作成されていないが（小規模実装のため Architect 起動不要）、
  実装上の判断は本 impl-notes.md に集約

STATUS: complete
