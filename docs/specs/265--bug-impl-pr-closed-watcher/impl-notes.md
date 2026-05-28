# 実装メモ: Issue #265 — CLOSED 未マージ impl PR を resume 地点判定から除外

## 概要

`local-watcher/bin/issue-watcher.sh` の `stage_checkpoint_find_impl_pr` が PR の state
`CLOSED`（未マージ）も「既存 impl PR あり = Stage C 完了相当」として返していたため、
人間が `claude-failed` ラベルを外して再開を試みても、watcher が CLOSED PR を「TERMINAL_OK」
扱いで即停止する事故が再現していた（Issue #265）。

本修正では `stage_checkpoint_find_impl_pr` の jq 採用ロジックを **OPEN を最優先 / 次に
MERGED / CLOSED は既定で除外** に組み替え、CLOSED 未マージ PR のみが存在するケースを
「既存 impl PR なし」と等価に扱うよう変更した。Issue #212 の Stage C CLOSED ガード
（`needs-decisions` 付与経路、Out of Scope）は `stage_c_existing_pr_guard` だけが
`include_closed=true` を渡す形で温存している。

## 変更ファイル一覧

- `local-watcher/bin/issue-watcher.sh`
  - `stage_checkpoint_find_impl_pr`: jq 採用ロジック組み替え + `include_closed` 引数追加 +
    CLOSED 除外の観測ログ追加
  - `stage_c_existing_pr_guard`: `stage_checkpoint_find_impl_pr true` で呼ぶよう変更
    （Issue #212 経路を保持）
  - `stage_checkpoint_resolve_resume_point` の Decision Table コメント更新
  - `stage_a_crossing_probe` / `spec_artifacts_completeness_guard` のドキュメントコメント更新
- `docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/`
  - `closed-only.json` / `open-only.json` / `merged-only.json` / `empty.json`
  - `open-and-closed.json` / `merged-and-closed.json` / `open-merged-closed.json`
  - `test-find-impl-pr.sh`（7 fixture × 2 mode = 14 ケースの jq クエリ再現スクリプト）

## jq 修正前後の差分（簡潔）

修正前（Bug）:

```jq
[.[] | select(.state == "OPEN" or .state == "MERGED" or .state == "CLOSED")] | .[0] // empty
```

CLOSED も「あり」扱い → resume 判定が `TERMINAL_OK` になり pipeline が停止する。

修正後（Fix）:

```bash
open_pr=$(  echo "$prs" | jq -r '[.[] | select(.state == "OPEN")]   | .[0] // empty')
merged_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "MERGED")] | .[0] // empty')
closed_pr=$(echo "$prs" | jq -r '[.[] | select(.state == "CLOSED")] | .[0] // empty')

if   [ -n "$open_pr"   ]; then found="$open_pr"
elif [ -n "$merged_pr" ]; then found="$merged_pr"
elif [ -n "$closed_pr" ] && [ "$include_closed" = "true" ]; then found="$closed_pr"
fi
```

- OPEN > MERGED > (include_closed=true 時のみ CLOSED) の採用優先順位を bash で表現
  （単一 jq 式での `if/elif/else` よりも可読性 + テスト容易性を優先）
- CLOSED を除外したケースで `find-impl-pr: excluded-closed pr=#<N> count=<C> reason=...`
  の観測ログを `stage-checkpoint:` prefix で 1 行出力（Req 4.1, 4.3 / NFR 2.1）

## 越境観測ヘルパ / 完全性ガード側の確認結果

| 呼び出し元 | 渡す include_closed | CLOSED 検出時の挙動 | Req 整合 |
|---|---|---|---|
| `stage_checkpoint_resolve_resume_point` | false（既定） | rc=1 = 既存 PR なし → 後段 checkpoint へ進む | Req 1.1, 1.4 |
| `stage_a_crossing_probe` | false（既定） | rc=1 = 越境根拠として記録しない | Req 3.3 |
| `spec_artifacts_completeness_guard` | false（既定） | pr_state="(none)"→補完起動条件外 | Req 3.4 |
| `stage_c_existing_pr_guard` | **true**（明示） | 従来どおり needs-decisions + Issue コメント | Out of Scope（#212 維持） |

変更要否: いずれもヘルパ側で吸収され、コードフロー自体は変更不要（`stage_c_existing_pr_guard`
の 1 引数追加のみ）。OPEN / MERGED の動作は本修正前と完全に同一（NFR 1.4）。

## 実行した verify コマンドと結果

```sh
$ shellcheck local-watcher/bin/issue-watcher.sh
EXIT=0  (警告ゼロ)

$ shellcheck local-watcher/bin/modules/*.sh
EXIT=0  (警告ゼロ)

$ shellcheck docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/test-find-impl-pr.sh
EXIT=0  (警告ゼロ)

$ bash docs/specs/265--bug-impl-pr-closed-watcher/test-fixtures/test-find-impl-pr.sh
Summary: PASS=14 FAIL=0
EXIT=0
```

verify 対象詳細（fixture × mode マトリクス）:

| fixture | include_closed=false | include_closed=true | カバー Req |
|---|---|---|---|
| `empty.json` | NONE | NONE | Req 1.4 縮退 |
| `closed-only.json` | NONE | `101,CLOSED` | Req 1.1, 1.4（既定） + #212 経路（include_closed=true）|
| `open-only.json` | `201,OPEN` | `201,OPEN` | Req 1.2, 3.1 |
| `merged-only.json` | `301,MERGED` | `301,MERGED` | Req 1.3, 3.2 |
| `open-and-closed.json` | `201,OPEN` | `201,OPEN` | Req 1.5（OPEN 優先）|
| `merged-and-closed.json` | `301,MERGED` | `301,MERGED` | Req 1.5（MERGED 優先）|
| `open-merged-closed.json` | `202,OPEN` | `202,OPEN` | Req 1.5（OPEN > MERGED 優先）|

stage-a-verify gate（#125 / #224）は本 spec が design-less impl（PM 直 → Dev、`tasks.md` 不在）
のため **gate 対象外（SKIP）**。設計思想どおり watcher は verify コマンドを推測せず、
本ステージで実施した上記 shellcheck + 再現スクリプトの結果を impl-notes.md に転記している。

## 受入基準の達成確認（requirement ID → テスト対応）

| Req ID | 担保するテスト |
|---|---|
| 1.1 (CLOSED のみ → 停止根拠から除外) | `closed-only/default = NONE` |
| 1.2 (OPEN → 既存挙動維持) | `open-only/*` / `open-and-closed/*` |
| 1.3 (MERGED → 既存挙動維持) | `merged-only/*` / `merged-and-closed/*` |
| 1.4 (CLOSED のみ → 既存 PR なし扱い) | `closed-only/default = NONE` / `empty/default = NONE` |
| 1.5 (OPEN/MERGED + CLOSED 混在 → OPEN/MERGED 優先) | `open-and-closed/*` / `merged-and-closed/*` / `open-merged-closed/*` |
| 2.1 (claude-failed 除去後の自動再開継続) | jq rc=1 = 「既存 PR なし」→ `resolve_resume_point` の `input: existing-impl-pr=none` 経路に乗り後段 checkpoint へ進む（コード追跡確認） |
| 2.2 (CLOSED PR への副作用なし) | 既定経路で `stage_c_existing_pr_guard` の CLOSED 分岐に到達せず（include_closed=false）、ラベル / コメント / close 操作は発火しない |
| 2.3 (既存 Decision Table を本要件導入前と同一規則で適用) | resolve_resume_point の Decision Table は変更なし。CLOSED-only → existing-impl-pr=none 経路で従来の D-1〜D-7 分岐に乗る |
| 3.1 (OPEN: Stage C 冪等ガード挙動不変) | `open-only/include_closed=true`、Stage C guard 内 OPEN 分岐に到達（コード追跡） |
| 3.2 (MERGED: Stage C 冪等ガード挙動不変) | `merged-only/include_closed=true`、Stage C guard 内 MERGED 分岐に到達（コード追跡） |
| 3.3 (越境観測ヘルパ: OPEN/MERGED のみ越境記録 / CLOSED 除外) | `stage_a_crossing_probe` が `find_impl_pr` を include_closed=false で呼ぶ。jq テストでは CLOSED-only → NONE = `STAGE_A_CROSSING_DETECTED=no` 経路 |
| 3.4 (spec 完全性ガード: MERGED のみ docs-only 補完起動 / OPEN/CLOSED/none は起動しない) | `spec_artifacts_completeness_guard` が `find_impl_pr` を include_closed=false で呼ぶ。CLOSED-only → pr_state="(none)" → MERGED マッチに到達しない（コード追跡） |
| 4.1 / 4.3 (CLOSED 除外時の `stage-checkpoint:` prefix 観測ログ 1 行以上) | 新規追加: `sc_log "find-impl-pr: excluded-closed pr=#... count=... reason=closed-unmerged-not-stop-signal ..."` |
| 4.2 (Stage A 再開時の既存 Decision Table ログ出力) | 既存 `sc_log "decision: START_STAGE=A reason=..."` 経路に変更なし |
| NFR 1.1 / 1.2 (`STAGE_CHECKPOINT_ENABLED=true` 以外は 1 行も実行せず) | 既存 gate `[ "${STAGE_CHECKPOINT_ENABLED:-true}" != "true" ] && return` を本修正で触っていない |
| NFR 1.3 (既存ラベル名 / Issue 候補抽出フィルタ不変) | mark_issue_failed / LABEL_* 系の参照を変更していない |
| NFR 1.4 (OPEN / MERGED 1 件以上存在する全ケースで挙動不変) | 上表「open*」「merged*」fixture が修正前後で同一結果（pre-fix 1 件目採用 = post-fix OPEN/MERGED 優先採用、いずれも OPEN/MERGED が含まれていれば OPEN/MERGED を返す） |
| NFR 2.1 (3 段書式 `[YYYY-MM-DD HH:MM:SS] stage-checkpoint:` で grep 抽出可能) | 既存 `sc_log` 関数を流用するため書式は完全一致 |
| NFR 3.1 / 3.2 (read-only 観測、副作用なし) | 新規追加した観測ログ以外に副作用なし。`gh pr list` は元から read-only |

## 補足ノート

- requirements.md 内で曖昧だった点なし。Out of Scope の境界（#212 経路保持）は include_closed
  引数で明示的に分離した
- 旧挙動を選ぶ env var を追加していない（Out of Scope と整合）
- 1 PR head に同一 state の PR が複数ある稀なケース（履歴的にあり得ない想定）では、`gh pr list`
  が返す配列の最初の 1 件を採用する。OPEN/MERGED が複数の状況自体が異常状態なので本修正の
  スコープ外（既存挙動を踏襲）
- 観測ログ追加で `LOG` 環境変数を参照する点は既存の `sc_log` / `sc_warn` と同じ前提

## 確認事項

なし。要件・修正方針とも明確で、Out of Scope の境界も `include_closed` パラメータで分離した。

STATUS: complete
