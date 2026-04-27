# 実装ノート — Issue #31 idd-claude-labels.sh の冪等性バグ修正

## 採用した実装方針

`gh label list` を **1 回だけ呼び出して全既存ラベルを連想配列にキャッシュ**するアプローチを採用した。

### 検討した代替案と却下理由

1. **`gh label view <name>` で個別存在判定（PM 推奨案）**
   - `gh label view` サブコマンドは現行 `gh` CLI に存在しない（`gh label`
     のサブコマンドは `clone` / `create` / `delete` / `edit` / `list` のみ）。
     実機検証で全件 FAILED となり棄却。
2. **`gh api repos/{owner}/{repo}/labels/{name}` で個別取得**
   - `--repo` 引数なし時に owner/repo を自前で解決する必要があり、複雑化する。
   - ラベル数 9 件 = API コール 9 回となり、レート制限的にも不利。
3. **採用案: `gh label list --limit 1000 --json name` を 1 回呼び出してキャッシュ**
   - API コール 1 回で済む。
   - `--limit 1000` で件数上限・ページネーション境界の取りこぼし懸念を解消（NFR 2.3）。
   - 取得自体が失敗したら（API 不達 / 認証失敗 / 権限不足）即座に `exit 1`、
     真の失敗のみを失敗として扱う契約に合致（Req 2.4）。

### 主な変更点

- `gh label list ... --limit 100 | grep -qx` のフォールバック判定を撤廃。
- 事前に全既存ラベル名を `declare -A EXISTING_LABELS` の連想配列にキャッシュ。
- 各ラベルの分岐を「キャッシュ参照 → 既存／未存在」の単純な O(1) 判定に変更。
- `gh label list` 失敗時は即時 `exit 1` し、stderr にエラーメッセージを出力。
- 依存に `jq` を明記（CLAUDE.md の前提と一致）。`command -v jq` 事前チェック追加。

### 修正前後の挙動比較

| シナリオ | 修正前（バグあり） | 修正後 |
|---|---|---|
| 全ラベル既存・`--force` なし | ラベルにより一部「FAILED」誤分類 → exit 1 | 全件「既存スキップ」 → exit 0 |
| 一部既存・`--force` なし | 既存ラベルが「FAILED」誤分類リスク | 既存はスキップ、不足分のみ「新規作成」 |
| 全ラベル既存・`--force` 付き | 「上書き更新」9 → exit 0（変化なし） | 「上書き更新」9 → exit 0 |
| 真の API 失敗 | `gh label list` 1 回目失敗時に `gh label list` で再試行する 2 段構え | 即時 exit 1 でエラーを stderr に出力 |
| ページネーション境界（label > 30） | `--limit 100` でも越境すれば取りこぼし | `--limit 1000` で実用上回避 |

## 検証結果

### 静的解析

- `shellcheck` は当該環境にインストール不可（sudo パスワード要求）。
- 代替として `bash -n` の構文チェックを両ファイルで実行 → OK。
- 既存規約（`set -euo pipefail`、`"$var"` クォート、配列展開 `"${arr[@]}"`、
  `command -v`）はすべて維持。新規追加した連想配列展開も適切にクォートしている。

### 同期確認

```
diff -u .github/scripts/idd-claude-labels.sh \
        repo-template/.github/scripts/idd-claude-labels.sh
# → 差分なし（exit 0）
```

### スモークテスト（実 GitHub API、対象 repo: `hitoshiichikawa/idd-claude`）

| # | シナリオ | 結果 | 担保される AC |
|---|---|---|---|
| 1 | 全既存・`--force` なし | 既存スキップ 9 / 失敗 0 / exit 0 | 1.1, 1.4, 1.5, 2.1, 2.3, 4.1-4.4 |
| 2 | 全既存・`--force` 付き | 上書き更新 9 / 失敗 0 / exit 0 | 3.1, 3.2 |
| 3 | 未知引数 `--bogus` | stderr エラー + exit 1 | 5.5 |
| 4 | `--help` | ヘルプ出力 + exit 0 | 5.4 |
| 5 | `-f` 短エイリアス | `--force` と同じ結果 | 5.3 |
| 6 | 1 ラベル削除 → 再実行 | 新規作成 1 / 既存スキップ 8 / 失敗 0 / exit 0 | 1.2 |
| 7 | `--repo owner/name` 引数 | カレント以外の repo を対象に正常動作 | 5.2 |
| 7' | `--repo` に存在しない repo | stderr エラー + exit 1（`gh label list` 失敗） | 2.2, 2.4 |
| 8 | 同一引数で連続実行 | 2 回目: 新規作成 0 / 失敗 0 / exit 0 | 1.3, NFR 1.1 |

### コードレベルでの真の失敗時 exit 1 経路

- `gh label list` 失敗時: 行 86 `if ! EXISTING_LABELS_JSON=$(...)` → 行 88 `exit 1`
- `gh label create` 失敗時: 各分岐内で `FAILED=$((FAILED+1))` 計上 → 末尾 `if [ "$FAILED" -gt 0 ]; then exit 1`

## 後方互換性の確認

| 項目 | 確認結果 |
|---|---|
| 引数（`--repo` / `--force` / `-f` / `-h` / `--help`） | 維持（Smoke 3〜7） |
| 環境変数 | 元から未使用（変更なし） |
| exit code 意味（0=成功、1=失敗） | 維持。`gh label list` 失敗時の exit 1 を新規追加（要件 Req 2.4 で要請されている振る舞い） |
| 出力フォーマット | `📌` 装飾、ラベル行 `%-25s ... <status>`、`already exists (skipped; use --force to update)` 文言、`== 結果 ==` 見出し、4 サマリ行（新規作成 / 既存スキップ / 上書き更新 / 失敗）すべて維持 |
| ラベル定義（名前・色・description） | 9 ラベルを一切改変せず（Req 6.1, 6.3） |
| sudo 不要 | 維持 |
| root 配置と template 配置の同期 | `diff` 無差分（Req 6.2） |

### 新規依存

- `jq`: CLAUDE.md 「依存 CLI: `gh`, `jq`, `flock`, `git`」に記載済み。idd-claude
  プロジェクト全体で前提済みなので新規プラットフォーム要件は発生しない。スクリプト
  冒頭コメントとヘッダの「依存:」行に追記し、`command -v jq` チェックを追加した。

## 各 AC への対応箇所メモ

| 要件 ID | 対応箇所 |
|---|---|
| Req 1.1 | 全既存時 → for ループで全件 EXISTS 計上（行 100-101, 107-108） |
| Req 1.2 | 既存／未存在の分岐（行 100 / 行 113） |
| Req 1.3 | 連想配列キャッシュにより 2 回目も同じ結果（NFR 1.1 と同根拠） |
| Req 1.4 | 既存ラベル分岐は FAILED に到達しない |
| Req 1.5 | 行 107-108 で EXISTS 加算 |
| Req 2.1 | 末尾 `if FAILED > 0` 判定で 0 のとき exit 0 |
| Req 2.2 | `gh label create` 失敗時 / `gh label list` 失敗時の双方で exit 1 |
| Req 2.3 | 既存スキップは FAILED にならない（旧バグ解消） |
| Req 2.4 | 行 44-46 (`command -v gh`) と行 86-89（`gh label list` 失敗時） |
| Req 3.1 | `--force` 分岐で UPDATED 加算（行 102-105） |
| Req 3.2 | UPDATED のみ加算され FAILED 0 維持 |
| Req 3.3 | `gh label create --force` 失敗時のみ FAILED 加算 |
| Req 4.1 | `printf "  %-25s ... " "$NAME"` で行頭整形を維持 |
| Req 4.2 | `already exists (skipped; use --force to update)` 文言維持 |
| Req 4.3 | サマリ 4 行のラベル名・順序維持 |
| Req 4.4 | `== 結果 ==` 見出し維持 |
| Req 4.5 | `📌` 装飾維持 |
| Req 5.1〜5.5 | 引数解析ブロックを未変更（行 23-42） |
| Req 6.1 | LABELS 配列 9 件未変更 |
| Req 6.2 | root と template を `diff` で同期確認済み |
| Req 6.3 | LABELS 配列の name / color / description を一切改変せず |
| NFR 1.1 | Smoke 8 で実証 |
| NFR 1.2 | for ループで 1 ラベル 1 行出力 |
| NFR 1.3 | CREATED + EXISTS + UPDATED + FAILED の合算が常に 9 になる構造 |
| NFR 1.4 | 失敗時に `printf "  %-25s ... " "$NAME"` 後に `echo "FAILED"` |
| NFR 2.1 | 引数名・env var・exit code 意味を維持 |
| NFR 2.2 | sudo 不要 |
| NFR 2.3 | `--limit 1000` で件数上限のマージン確保 |

## 残課題・確認事項

- **shellcheck 未実行**: 当該実行環境にインストールできなかった。CI 等で
  `shellcheck` が利用可能な環境では PR で再確認することを推奨。
  既存スクリプトと同じコーディングパターン（`set -euo pipefail`、配列展開、
  `command -v`、`>/dev/null 2>&1`）を踏襲しているため、新規警告の混入リスクは
  低いと判断。
- **`gh label list --limit 1000` の上限**: GitHub の単一ページ取得上限は 100 で、
  `gh` CLI 内部で paginate される実装。`--limit 1000` は idd-claude の 9 ラベル
  および一般的な repo のラベル数（数十件）に対して十分な safety margin だが、
  極端な repo（1000+ ラベル）では取りこぼし可能性が残る。idd-claude の運用上は
  現実的に発生しないため許容範囲と判断。
- **真の API 失敗時の挙動シミュレーション**: 不正な repo 名指定（Smoke 7 初回）で
  `gh label list` 失敗時の exit 1 経路は実機確認できた。認証失敗・レート制限などの
  シミュレーションはしていないが、いずれも `gh` の非ゼロ exit を伴うため同じ経路
  に乗る。
