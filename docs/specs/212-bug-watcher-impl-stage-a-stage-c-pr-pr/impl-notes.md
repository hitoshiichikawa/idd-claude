# 実装ノート（Issue #212）

## 変更概要

Stage A の worker が「PR 作成禁止」制約に違反して PjM まで越境し PR を作成した場合、Stage C が
サイクル開始時（`stage_checkpoint_resolve_resume_point`）の 1 回限りの観測しか行わないため、
同一サイクル内で先行作成された PR を検出できず 2 本目の impl PR を作成してしまう不具合
（2026-05-25 Cycle B の PR#210 / PR#211 重複の実例）を、Stage C の PR 作成直前に既存 PR を
再確認する冪等ガードで多重防御する。

### 切り出した関数

- `stage_c_existing_pr_guard()`（`local-watcher/bin/issue-watcher.sh`、`stage_checkpoint_resolve_resume_point`
  の直後に定義）
  - 既存観測ヘルパ `stage_checkpoint_find_impl_pr`（stdout=`<pr_number>,<state>`、rc 0=あり/1=なし/2=API エラー）
    を再利用。
  - `STAGE_CHECKPOINT_ENABLED=true`（既定）時のみ実行。`true` 以外では副作用ゼロで即 `return 1`。
  - 戻り値契約: `return 0` = 既存 PR 検出で新規作成を抑止（呼び出し側が pipeline を `return 0` 停止）/
    `return 1` = 作成方向へ進む（none / gate off / gh API エラー / 想定外 state）。
  - OPEN / MERGED は `sc_log` のみ（Issue コメントなし）、CLOSED は `gh issue edit --add-label needs-decisions`
    + `gh issue comment` 1 件（`mark_issue_failed` は使わず `claude-failed` を付与しない）。
  - gh API エラー（rc=2）は `sc_warn`（二重 PR の可能性を明示）+ `sc_log` を出して作成方向へフォールバック。

### call site の配線

`run_impl_pipeline` の Stage C 直前（`echo "--- Stage C 実行..."` の直後、`_assert_base_branch_resolved`
の前）に以下を挿入:

```bash
if stage_c_existing_pr_guard; then
  echo "✅ #$NUMBER: 既存 impl PR を検出（Stage C 冪等ガード）→ 新規 PR 作成を抑止して停止" | tee -a "$LOG"
  return 0
fi
```

既存 TERMINAL_OK 処理（resolve 段階）の `✅` 表示 / return 0 / ログ書式に揃えた。

## AC 対応表（requirement ID → 担保テスト / 実装）

すべて `local-watcher/test/stage_c_existing_pr_guard_test.sh`（実装関数を awk 抽出して source、
`gh` / `stage_checkpoint_find_impl_pr` を fake で注入）で担保。

| AC | 内容 | 担保 |
|---|---|---|
| 1.1 | gate=true 時に Stage C 直前で既存 PR を観測 | OPEN/MERGED/CLOSED 各ケースで `stage_checkpoint_find_impl_pr` が呼ばれログ出力されることを assert |
| 1.2 | gate!=true 時は本ガードを実行せず従来挙動維持 | `gate=false` / `gate=任意値` で return 1 / gh 未呼出 / ログ無を assert |
| 1.3 | OPEN/MERGED/CLOSED を区別判定 | 各 state で異なる挙動（ログ内容・gh 呼出数）を assert |
| 1.4 | サイクル開始時の 1 回だけでなく Stage C 直前にも実施 | call site 配線を実装。テストの sanity grep で配線存在を確認 |
| 2.1 | OPEN 検出時に新規 PR を作成しない | OPEN: return 0（後続作成へ進まない） |
| 2.2 | OPEN 検出時に return 0 で停止 | OPEN: return 0 を assert |
| 2.3 | OPEN 検出時に PR 番号・状態を既存ログ書式でログ出力 | OPEN: ログに `state=OPEN` / `210,OPEN` を assert |
| 2.4 | OPEN 検出時に Issue コメントを投稿しない | OPEN: gh 呼出 0 回を assert |
| 3.1 | MERGED 検出時に新規 PR を作成しない | MERGED: return 0 |
| 3.2 | MERGED 検出時に着地済みとみなし return 0 停止 | MERGED: return 0 を assert |
| 3.3 | MERGED 検出時に PR 番号・状態をログ出力 | MERGED: ログに `state=MERGED` / `208,MERGED` を assert |
| 3.4 | MERGED 検出時に Issue コメントを投稿しない | MERGED: gh 呼出 0 回を assert |
| 4.1 | CLOSED 検出時に新規 PR を作成しない | CLOSED: return 0 |
| 4.2 | CLOSED 検出時に `needs-decisions` 付与 | CLOSED: gh 呼出に `--add-label needs-decisions` を assert |
| 4.3 | CLOSED 検出時に PR 番号 + 人間判断要旨のコメントを 1 件投稿 | CLOSED: gh 呼出 2 回 / `issue comment 212` を assert |
| 4.4 | CLOSED 検出時に `claude-failed` を付与しない | CLOSED: gh 呼出文字列に `claude-failed` を含まないことを assert |
| 4.5 | CLOSED 検出時に return 0 で停止 | CLOSED: return 0 を assert |
| 5.1 | 既存 PR 無し時に従来どおり PR 作成へ進む | none: return 1 を assert |
| 5.2 | 既存 PR 無し通常ケースで user-observable 挙動不変 | none: gh 未呼出 / ログ無を assert（副作用ゼロ） |
| 6.1 | gh API エラー時に警告ログ出力 | API エラー: ログに `WARN:` を assert |
| 6.2 | gh API エラー時に作成方向へフォールバック | API エラー: return 1 を assert |
| 6.3 | gh API エラー時に二重 PR の可能性を警告ログ出力 | API エラー: ログに `二重 PR` を assert |
| NFR 1.1 | 既存 PR 無し通常フローで PR 作成本数（1 本）不変 | none ケースで return 1 → 従来の作成経路へ（gh 副作用ゼロ） |
| NFR 1.2 | gate!=true 時に差分を一切生じさせない | gate=false/任意値で return 1 / gh 未呼出 / ログ無 |
| NFR 1.3 | env var 名の意味・既定値不変 | `STAGE_CHECKPOINT_ENABLED` 既定 true を流用、新 env var 追加なし |
| NFR 1.4 | ラベル遷移契約不変 | CLOSED は既存 `LABEL_NEEDS_DECISIONS` のみ付与、`claude-failed` 不付与（assert 済み） |
| NFR 1.5 | exit code の意味不変 | OPEN/MERGED/CLOSED は既存 TERMINAL_OK と同じ return 0、それ以外は従来経路 |
| NFR 1.6 | 既存ログ行書式不変 | `sc_log` / `sc_warn`（既存 `stage-checkpoint:` prefix）を流用。TERMINAL_OK の `✅` 表示も踏襲 |
| NFR 2.1 | 同一 head に 2 回以上到達しても 1 本を超えない | gate=true + OPEN/MERGED/CLOSED で作成抑止（return 0）を assert |
| NFR 2.2 | self-hosting 再実行で重複 PR を生成しない | 既存 PR 検出時に return 0 停止（同上） |
| NFR 3.1 | 抑止理由を grep 可能な粒度でログ出力 | `stage-c-guard: ... reason=reuse-open-pr|already-merged|human-closed` を出力 |
| NFR 3.2 | API エラー時の判定根拠を grep 可能な粒度でログ出力 | `existing-impl-pr=unknown reason=gh-api-error fallback=create` を出力 |

OPEN/MERGED/CLOSED/none/API エラーの 5 分岐 + gate off（false / 任意値）= 計 26 アサーション、全 pass。

## 検証コマンドと結果

```text
bash -n local-watcher/bin/issue-watcher.sh
  → OK（構文エラーなし）

shellcheck local-watcher/bin/issue-watcher.sh
  → 警告件数 5 件（すべて SC2317 info の既存指摘。main baseline も 5 件で増減なし。
     新規コードに起因する警告はゼロ）

shellcheck local-watcher/test/stage_c_existing_pr_guard_test.sh
  → CLEAN（file-wide disable=SC2317,SC2034 を shebang 直後に配置。
     既存 stagec_pr_verify_test.sh と同じ false positive 抑止方針）

bash local-watcher/test/stage_c_existing_pr_guard_test.sh
  → PASS 26 / FAIL 0

local-watcher/test/*.sh 全 15 ファイル
  → 全 PASS（既存テストの回帰なし）
```

### Red → Green の確認

実装関数を awk で抽出して source する方式のため、gate チェックを削除した watcher コピーに
対してテストを走らせると `gate=false: return 1` 等が FAIL することを確認済み（テストが実装を
実際に exercise していることの裏取り）。

## 後方互換の確認

- 新 env var を導入していない。`STAGE_CHECKPOINT_ENABLED`（既定 true / #112）を流用し意味・既定値を変更しない（NFR 1.3）。
- `STAGE_CHECKPOINT_ENABLED` が `true` 以外（明示 `false` / 任意値 / unset 以外の非 true）では本ガードは
  1 行も実行されず `return 1` で従来の作成経路へ抜ける（Req 1.2 / NFR 1.2）。テストで gh 未呼出・ログ無を assert。
- ラベル遷移契約: CLOSED でも既存 `LABEL_NEEDS_DECISIONS` のみ付与。`claude-failed` は付与しない（NFR 1.4、assert 済み）。
- exit code: OPEN/MERGED/CLOSED は既存 TERMINAL_OK と同一の return 0、none/API エラー/想定外は従来経路。Stage C 成功 0 / 失敗 1 の意味を変えない（NFR 1.5）。
- ログ書式: 既存 `sc_log` / `sc_warn`（`stage-checkpoint:` prefix）と TERMINAL_OK の `✅`/`tee -a "$LOG"` 表示を踏襲（NFR 1.6）。
- 既存テスト 15 本すべて回帰なし。shellcheck 警告件数も main と同一（5 件、すべて既存 SC2317 info）。

## 実装上の判断

- 巨大な分岐を Stage C インラインに埋め込まず、判定 + 副作用を担う単一関数 `stage_c_existing_pr_guard`
  として切り出した（CLAUDE.md「単一責務の関数」/ テスト容易性）。call site は `if guard; then echo + return 0; fi`
  の 4 行のみで、既存ログ・return 契約を壊さない。
- ガードの戻り値設計は `0=抑止（停止）/ 1=作成へ進む` とし、call site で `if guard; then return 0; fi` と
  自然に書けるようにした。none / API エラー / 想定外 state はすべて「作成方向（return 1）」に集約。
- gate チェックは call site ではなくガード関数内に置いた。これによりガード単体テストで gate off の
  no-op を直接 assert でき、call site から見ると「gate を意識せず常に呼ぶだけ」で済む（call site の
  認知負荷を下げ、将来 gate 条件が変わってもガード内で完結する）。
- `stage_checkpoint_find_impl_pr` が想定外の state を返す経路（現状の jq select では OPEN/MERGED/CLOSED
  のみ通すため到達しないはず）も防御的に「作成方向フォールバック + 警告ログ」で扱い、silent fail を作らない。

## 配置先（成果物）

- 実装: `local-watcher/bin/issue-watcher.sh`（`stage_c_existing_pr_guard` 定義 + Stage C call site 配線）
- テスト: `local-watcher/test/stage_c_existing_pr_guard_test.sh`（新規）
- ドキュメント: `README.md`「Stage Checkpoint (#68)」節に Stage C 再確認ガード（#212）の 1 段落を追記

## 確認事項（レビュワー判断ポイント）

- requirements.md と矛盾する点・未解決の不明点は検出されなかった。「Resolved Decisions」で
  gate 範囲 / API エラーフォールバック / OPEN・MERGED の通知方針はすべて確定済みであり、その通りに実装した。
- README 追記は Stage Checkpoint 節に 1 段落のみとした（正常フローでは挙動不変のため過剰更新を避ける判断）。
  オプション機能一覧（README 1186 行付近の `STAGE_CHECKPOINT_ENABLED` 行）は既存記述のままで、本ガードは
  同 env var の傘下機能として扱った。別行を起こすべきか否かはレビュワー判断に委ねる。

STATUS: complete
