# 実装ノート: #200 Dispatcher FIFO + hotfix 優先

## 概要

ローカル watcher の Dispatcher 候補処理順を FIFO（Issue 番号昇順 = 古いものから）に変更し、
`hotfix` ラベル付き Issue を非 hotfix より先に投入する 2 段優先を導入した。あわせて `hotfix`
ラベルを両ラベルスクリプトに新設し、README に migration note を追記した。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh` — `LABEL_HOTFIX` 定義追加 + `_dispatcher_run` の候補取得・ソートロジック変更
- `.github/scripts/idd-claude-labels.sh` — `hotfix` ラベル定義追加（`【Issue 用】` prefix 付き）
- `repo-template/.github/scripts/idd-claude-labels.sh` — `hotfix` ラベル定義追加（prefix なし、template 規約準拠）
- `README.md` — 候補処理順の解説節 + migration note + ラベル一覧（3 箇所: ラベル表 / 手動 create コマンド / 状態遷移表）
- `docs/specs/200-feat-watcher-dispatcher-fifo-hotfix/test-order.sh` — ソート挙動スモークテスト
- `docs/specs/200-feat-watcher-dispatcher-fifo-hotfix/test-fixtures/{hotfix-query,all-query}.json` — 検証用 fixture

## 実装方式の選択理由

### `--limit` 取りこぼし問題への対策（Req 3.1 / 3.2）

`gh issue list` の既定順は created-desc（新しいもの優先）。単純に「`--limit 5` で 5 件切り出して
から jq でソート」すると、母集団切り出しが created-desc で行われるため、6 件目以降の古い候補や
hotfix を母集団に含められず取りこぼす。

**採用した方式: 2 クエリ + jq 2 段ソート**

1. **hotfix ティアクエリ**: `--label hotfix` + `--search "... sort:created-asc"` で hotfix のみを
   作成日時昇順（= 概ね番号昇順）に `--limit 5` 取得 → 最も古い hotfix が母集団先頭に必ず入る
2. **全候補クエリ**: 従来フィルタ + `--search "... sort:created-asc"` で hotfix/非 hotfix 混在を
   作成日時昇順に `--limit 5` 取得 → 最も古い非 hotfix が母集団先頭に必ず入る
3. 両結果を結合 → `unique_by(.number)` で dedup → `(tier, number)` の 2 段ソート →
   先頭 `$DISPATCH_LIMIT`（=5）件に切り詰め

これにより「最も古い hotfix」「最も古い通常 Issue」のいずれも、limit による母集団切り出しで
漏れない。`created-asc` を母集団取得の基準にすることで Req 1.3（番号昇順 ≒ created-asc）とも整合。

代替案（十分大きい limit を 1 クエリで取って jq だけでソート）は、auto-dev 候補が将来大量に
積み上がったときに 1 クエリの limit を膨らませる必要があり、`--limit` の「1 サイクルで評価する
候補件数上限」という意味（Req 3.3）を曖昧にするため採らなかった。2 クエリ方式は各クエリの
limit を従来の 5 に固定でき、`--limit` の意味を据え置ける。

### hotfix 判定の jq 構成（Req 2.4 安全側フォールバック）

```jq
map(. + { _is_hotfix: ((.labels // []) | map(.name) | index($hotfix) != null) })
| unique_by(.number)
| sort_by([ (if ._is_hotfix then 0 else 1 end), .number ])
```

- `.labels // []`: `.labels` が欠落（キー不在）または `null` の場合は空配列にフォールバック →
  `index("hotfix")` は `null` → `_is_hotfix=false`（非 hotfix ティア）。Req 2.4 の安全側に倒す。
- tier を hotfix=0 / 非 hotfix=1 に写像し `(tier, number)` 昇順で安定ソート → hotfix 全件が
  非 hotfix より先（Req 2.1）、同一ティア内は番号昇順（Req 2.2 / 2.3 / 1.1）。
- 全候補クエリ側にも hotfix が含まれるため、仮に hotfix 専用クエリが空でも全候補クエリ側の
  ラベル情報から `_is_hotfix=true` を正しく検出できる（fixture Case E で検証）。

### 後方互換性の保全（Req 1.4 / 5.1 / 5.2 / 5.3）

- 投入ループ（`while read`）以降の Pre-Claim Filter / Open Design PR Guard / Path Overlap Gate /
  slot 探索 / claim / Slot Runner fork は **一切変更していない**。`$issues` は従来同様
  `echo "$issues" | jq -c '.[]'` で 1 件ずつ feed され、各要素は従来と同じ
  `number/title/body/url/labels` フィールドを持つ。
- 除外フィルタ（`-label:...` 群）・取得フィールド・`--limit 5` は両クエリで従来と同一。
- 両クエリが空なら `issues=[]` → `count=0` → 既存の「処理対象の Issue なし」+ `return 0` が発火
  （Req 5.3、fixture 外の手動確認で検証済み）。
- env var 名 / exit code / ログ prefix / 既存ラベル名は不変（Req 5.1 / 5.2）。

## hotfix ラベルの色・description

- 色: `d93f0b`（橙赤）。既存赤系（`blocked=b60205` / `claude-failed=e74c3c` / `st-failed=d73a4a`）と
  区別できる別 hex を選定。
- description: live 側 `【Issue 用】 hotfix 優先処理対象（Dispatcher が非 hotfix より先に投入）`、
  template 側はプレフィックスなしの同等説明（template 規約に準拠）。
- 既存ラベルの name/color/description は不変。追加のみ。冪等性は既存スクリプトの
  `EXISTING_LABELS` チェックでそのまま担保される（Req 4.3 / 4.4 / NFR 1.2）。

## 検証結果

### shellcheck（NFR 1.1）

- `shellcheck local-watcher/bin/issue-watcher.sh`: 既存の SC2317（info, ログ関数の "unreachable"
  誤検知）が **本変更前と同一箇所（5 件、行番号は +4 シフトのみ）**。本変更による新規警告ゼロ。
  stash 前後比較で findings の行番号集合が完全一致（983/1237/2647/5259/5773 → 987/1241/2651/5263/5777）。
- `shellcheck .github/scripts/idd-claude-labels.sh repo-template/.github/scripts/idd-claude-labels.sh`:
  exit 0、警告ゼロ。
- `bash -n local-watcher/bin/issue-watcher.sh`: syntax OK（プロセス置換 `--slurpfile <(...)` も含め
  bash として構文妥当）。

### ソート挙動スモークテスト

`bash docs/specs/200-feat-watcher-dispatcher-fifo-hotfix/test-order.sh` → **PASS=6 FAIL=0**。

本体 `_dispatcher_run` の結合 + 2 段ソート jq 式と同一ロジックを fixture で検証:

- Case A（limit 5 切り詰め, hotfix 混在 + label 欠落/null）: `[120,305,50,201,202]`（hotfix 先頭, 各ティア番号昇順）
- Case B（limit 2）: `[120,305]`（hotfix ティアが先頭占有 = 取りこぼし回避 Req 3.1/3.2）
- Case C（hotfix 不在）: `[3,7,9]`（全件番号昇順 Req 1.2）
- Case D（複数 hotfix）: `[40,88,12]`（hotfix 同士も番号昇順 Req 2.3, 非 hotfix 後置 Req 2.1）
- Case E（labels 欠落/null）: `[8,2,5]`（欠落/null は非 hotfix 安全側 Req 2.4, all 側 hotfix 判定）
- Case F（決定性）: 同一入力で同一順序（NFR 2.1）

### dry-run

`REPO=owner/test` 等の dry-run は `gh` 認証・実在 repo を要するため、本サンドボックスでは
ソートロジックを fixture スモークテストで代替検証した。empty-both-queries → count=0 → 早期
return の経路は手動 jq 実行で確認済み（Req 5.3）。

## 受入基準 → テスト/検証の対応

| AC | 担保 |
|---|---|
| 1.1 候補を番号昇順で投入 | test-order Case A/C/D（`sort_by([tier, .number])`） |
| 1.2 hotfix 不在は全件番号昇順 | test-order Case C |
| 1.3 番号昇順 ≒ created-asc 等価観測 | 取得クエリ `sort:created-asc`（実装方式）+ Case A/C |
| 1.4 pick 順以外の挙動を不変に保つ | 投入ループ以降を無変更（diff で確認）/ `$issues` の要素 shape 不変（手動 jq 確認） |
| 2.1 hotfix を非 hotfix より先 | test-order Case A/B/D |
| 2.2 同一ティア内は番号昇順 | test-order Case A/C/D |
| 2.3 複数 hotfix は番号昇順 | test-order Case D |
| 2.4 ラベル不在/欠落は非 hotfix 安全側 | test-order Case A(202/203)/E（`.labels // []`） |
| 2.5 2 段のみ（多段なし） | 実装が `if hotfix then 0 else 1` の 2 値のみ（コードレビュー観点） |
| 3.1 上限超でも tier 優先 + 番号昇順 | test-order Case A/B |
| 3.2 最古 Issue/hotfix を取りこぼさない | test-order Case B（2 クエリ各 created-asc 取得） |
| 3.3 limit 意味を不変に保つ | `DISPATCH_LIMIT=5` を各クエリ `--limit` に維持 |
| 4.1 hotfix を作成対象に含める | 両 labels スクリプトの `LABELS` 配列に追加（shellcheck exit 0） |
| 4.2 live/template 双方に含める | 両ファイル編集済み |
| 4.3 再実行で冪等 | 既存 `EXISTING_LABELS` チェックを流用（既存スクリプト機構） |
| 4.4 既存ラベル不変 | 追加のみ・既存行無変更（diff で確認） |
| 5.1 env/exit/log prefix 不変 | 投入ループ・終端ログ無変更、`LABEL_*` 追加のみ |
| 5.2 既存ラベル名不変 | 既存 `LABEL_*` 変数・labels 定義無変更 |
| 5.3 対象なし時の正常終了維持 | empty-both → count=0 → 既存 return 0 経路（手動 jq 確認） |
| 5.4 README migration note | README に migration note 節追記 |
| NFR 1.1 shellcheck 警告ゼロ | 上記 shellcheck 結果（新規警告ゼロ） |
| NFR 1.2 追加のみ・削除/改名なし | labels diff が追加 1 行のみ |
| NFR 2.1 順序決定性 | test-order Case F |

## 限界・確認事項

- **gh の `sort:created-asc` と Issue 番号昇順の差**: GitHub の作成日時順と Issue 番号順は通常
  一致するが、厳密には別軸。母集団取得は `created-asc`、最終的な tier 内順序は **Issue 番号昇順**
  （jq `sort_by(.number)`）で確定するため、最終投入順は番号昇順で決定的（Req 1.1 / NFR 2.1）。
  created-asc は「母集団に最古候補を確実に含める」ためのヒューリスティックとして用いている。
  通常運用で番号順と作成順が乖離するのは過去 Issue を後から `auto-dev` 付与する稀なケースのみで、
  その場合でも最終順序は番号昇順なので AC は満たす。
- **2 クエリによる API コール 1 回増**: 1 サイクルあたり `gh issue list` が 1 回増える。候補
  取得は cron tick ごとに 1 度なので影響は軽微。レート制限の観点でも従来の Pre-Claim Filter 等の
  per-Issue GraphQL 呼び出しに比べ無視できる。
- **test-order.sh は本体ロジックの「コピー検証」**: 本リポジトリには bash unit test フレームワークが
  ないため、本体 `_dispatcher_run` の jq 式と同一ロジックを test-order.sh に複製して fixture 検証
  している（CLAUDE.md「手動スモークテスト」方針に準拠）。本体の jq 式を変更する際は test-order.sh
  も追従すること（スクリプト冒頭コメントに明記）。
- 要件・design に曖昧点なし（requirements.md Open Questions も「なし」）。確認事項として
  Architect/PM へ差し戻す矛盾は検出していない。

STATUS: complete
