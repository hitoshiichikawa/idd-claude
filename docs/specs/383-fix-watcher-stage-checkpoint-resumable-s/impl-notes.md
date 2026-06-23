# Implementation Notes (Issue #383)

## 実装概要

spec-dir 経路の slug 照合ガード (`_stage_checkpoint_assert_slug_match`) が
`docs/specs/<N>-*/` の番号一致だけで発火していた問題を、resumable state が実在する
ときのみ発火させるよう修正した。Issue #114 が守る fork/mirror 番号衝突誤 resume 防止は
resumable state 実在経路で完全に維持され、umbrella spec を sub-issue が共有する構成で
fresh issue（resumable state 一切不在）を不当に `needs-decisions` で block しなくなる。

## 修正対象ファイル

- `local-watcher/bin/issue-watcher.sh`
  - 新規関数 `_stage_checkpoint_has_resumable_state` を追加（`_stage_checkpoint_assert_slug_match`
    定義直後に配置）
  - spec-dir 経路の slug guard 呼び出し元（`_slot_run_issue` 内、`_matched_dir` が空の
    fallback ブロック）で新関数を call して発火可否を判定
- `local-watcher/test/stage_checkpoint_resumable_state_test.sh`（新規追加）

## 修正関数 / 追加関数

### 追加: `_stage_checkpoint_has_resumable_state` (Req 1, 3, 4, NFR 2)

- 引数: spec dir 絶対パス
- 戻り値:
  - 0 = resumable state 実在（呼び出し元は従来どおり slug guard を発火）
  - 1 = resumable state 不在（呼び出し元は slug guard を skip）
  - 2 = 判定失敗 (safe-side / 発火経路に倒す)
- 4 観点（OR 判定）:
  - (a) `stage_checkpoint_find_impl_pr` rc=0（OPEN / MERGED の impl PR 実在）
  - (b) `git ls-remote --heads origin -- "refs/heads/claude/issue-<N>-impl-*"` で 1 本以上
        の branch を検出（slug 不問の prefix マッチ。確認事項に従う）
  - (c) `git ls-tree HEAD -- <spec_dir>/impl-notes.md` が非空（tracked）
  - (d) `git ls-tree HEAD -- <spec_dir>/review-notes.md` が非空（tracked）
- ログ: 検出ヒット時に `stage-checkpoint: resumable-state-found ...` を 1 行 LOG 出力。
  観測失敗時は `stage-checkpoint: WARN resumable-state-detection ...` を stderr に 1 行
  出力（Req 4.3）
- 入力検証: `NUMBER` が numeric でなければ即 rc=2 を返す（safe-side）

### 修正: spec-dir 経路の slug guard 呼び出し元（`_slot_run_issue` 内）

- `_matched_dir` 非空ブロック（slug match 経路）は無変更（既存 behavior が要件と整合する
  ため。`_stage_checkpoint_assert_slug_match` は match 時 0 を返し escalate しない）
- `_matched_dir` 空ブロック（既存実装の mismatch 経路 = 誤爆元）に新判定を挿入:
  - 新関数 rc=1（不在確定）→ slug guard skip、`SLUG="$EXPECTED_SLUG"` を採用、
    `stage-checkpoint: slug-guard-skipped issue=#<N> expected=<exp> found=<found>
    reason=no-resumable-state` を 1 行 LOG 出力（Req 1.2, 1.3, 1.4, 4.1）
  - 新関数 rc=0/2/その他 → 従来どおり `_stage_checkpoint_assert_slug_match` を call
    （Req 2.1, 2.3, NFR 2.1）

## テスト追加内容

`local-watcher/test/stage_checkpoint_resumable_state_test.sh`（12 ケース・18 アサーション）:

- Case 1: Req 1.2 — 4 観点いずれも不在 → return 1（skip 経路）
- Case 2: Req 2.1/3.1(a) — impl PR 実在 → return 0
- Case 3: Req 2.1/3.1(b) — origin impl-* branch 実在 → return 0
- Case 3b: Req 3.1(b) — slug 不問 prefix マッチで mismatch slug branch も検出
- Case 4: Req 2.1/3.1(c) — impl-notes.md tracked → return 0
- Case 5: Req 2.1/3.1(d) — review-notes.md tracked → return 0
- Case 6: Req 3.1 — 4 観点全部真でも return 0（OR 判定）
- Case 7: NFR 2.1 — gh API 失敗 + 他観点不在 → return 2（safe-side）
- Case 8: NFR 2.1 — git ls-remote 失敗 + 他観点不在 → return 2（safe-side）
- Case 9: NFR 2.1 — 観測失敗があっても 1 観点で実在ヒットすれば return 0
- Case 10: NFR 2.1 — NUMBER 未設定 → return 2（safe-side）
- Case 11: NFR 2.1 — NUMBER 非数値 → return 2（safe-side）
- Case 12: Req 4.1 — skip 経路では `resumable-state-found` ログを出さない

テスト方式: `extract_function` で関数を関数定義のみ抽出、`stage_checkpoint_find_impl_pr` /
`git` / `timeout` を test 内で stub し、副作用を全テストプロセスに閉じ込める。
`local-watcher/test/slug_match_guard_test.sh` と同じ extract_function イディオムに準拠
（NFR 4.1）。

## AC Traceability（要件 ID → テスト）

| Req ID | カバーするテスト |
|--------|------------------|
| 1.1 | `stage_checkpoint_resumable_state_test.sh` 全 case（spec dir 検出時に判定が走ることを Case 12 で示す） |
| 1.2 | Case 1, 12（4 観点不在 → return 1 → 呼出側で skip） |
| 1.3 | Case 1 + 呼出側コードレビュー（rc=1 で `_slug_mismatch_escalate` を呼ばないため `needs-decisions` 付与なし） |
| 1.4 | Case 1 + 呼出側コードレビュー（rc=1 で `_slug_mismatch_escalate` 不呼び出し） |
| 1.5 | Case 1（複数候補存在 + 不一致は最終的に `_first` 経路へ落ち、resumable state 不在で skip） |
| 2.1 | Case 2, 3, 4, 5（4 観点各々で return 0） |
| 2.2 | `slug_match_guard_test.sh` 既存 Case 1（match → return 0 → resume 継続） |
| 2.3 | `slug_match_guard_test.sh` 既存 Case 2（mismatch → escalate） + 新呼出側で rc=0/2/* の case 分岐 |
| 2.4 | 既存 NFR 1.3 経路の維持（`SPEC_CANDIDATES` が空のとき従来どおり `SLUG="$EXPECTED_SLUG"`） |
| 3.1 | Case 2, 3, 3b, 4, 5, 6（4 観点が OR で判定） |
| 3.2 | Case 7, 8（観測失敗 → return 2 = safe-side） |
| 3.3 | コードレビュー（新関数は `stage_checkpoint_resolve_resume_point` を呼ばず独立に観測） |
| 4.1 | Case 2-5（`resumable-state-found ...` ログ）+ Case 12（skip ログ）+ 呼出側 `slug-guard-skipped` ログ |
| 4.2 | `slug_match_guard_test.sh` 既存 Case 1, 2（`slug-match` / `slug-mismatch` ログ） |
| 4.3 | コードレビュー（`stage-checkpoint: WARN ...` を stderr へ 1 行出力） |
| NFR 1.1 | env var / ラベル / cron / exit code を変更していない（コードレビュー） |
| NFR 1.2 | 既存 slug-match 経路は無変更 |
| NFR 1.3 | 既存 SPEC_CANDIDATES 空経路は無変更 |
| NFR 1.4 | 新規 env var なし（コードレビュー） |
| NFR 2.1 | Case 7, 8, 9, 10, 11（safe-side 倒し込み） |
| NFR 2.2 | 既存 spec dir を削除・リネームしない（コードレビュー） |
| NFR 2.3 | 新規 docs/specs/ 作成や umbrella spec 書き換えを本修正に含めない（コードレビュー） |
| NFR 3.1 | コードレビュー（全 echo 行が 1 イベント 1 行で改行を含まない） |
| NFR 3.2 | コードレビュー（issue 番号・expected-slug・found-slug を skip ログに含める） |
| NFR 4.1 | `stage_checkpoint_resumable_state_test.sh` は extract_function + stub 方式 |
| NFR 4.2 | `slug_match_guard_test.sh` を全 13 ケース回帰なしで通過 |
| NFR 4.3 | Case 1 (skip 経路) と Case 2-5 (発火経路) を最低 1 件ずつ実装 |

## 通したコマンド（サマリ）

- `bash -n local-watcher/bin/issue-watcher.sh` → OK
- `shellcheck local-watcher/bin/issue-watcher.sh` → 警告なし
- `shellcheck local-watcher/test/stage_checkpoint_resumable_state_test.sh` → 警告なし
- `bash local-watcher/test/slug_match_guard_test.sh` → PASS 13 / FAIL 0（回帰なし）
- `bash local-watcher/test/stage_checkpoint_resumable_state_test.sh` → PASS 18 / FAIL 0
- `bash local-watcher/test/normalize_slug_test.sh` → PASS 12 / FAIL 0
- `bash local-watcher/test/stage_checkpoint_pending_tasks_test.sh` → PASS 3 / FAIL 0
- 関連 Stage C テスト群（stagec_pr_verify_*, parse_review_result_test）→ 全て exit=0

## 確認事項

- 二次的所見（needs-decisions 再エスカレーションループ）の解消は requirements.md の
  Out of Scope と「確認事項」節に従い、本 PR では着手せず follow-up issue 化を提案する。
  本修正で「正常 fresh issue」が skip 経路に倒れることで二次的所見の発火頻度自体は
  下がる見込みだが、既に `needs-decisions` で人手 unblock 済みの Issue を triage が
  再度 needs-decisions 付与する経路は本 PR では触れていない。
- `repo-template/` には `issue-watcher.sh` の mirror が存在しないため、本 PR では
  repo-template 側に反映する変更はない（`repo-template/CLAUDE.md` のみ確認）。
- 呼出側の `case` 分岐は `1) ... *)` の 2 分岐としており、`*)` は「rc=0 (実在) /
  rc=2 (safe-side) / 想定外 rc」のすべてを slug guard 発火側にまとめる safe-side
  default として動く。これは NFR 2.1 の「resumable state が実在するかもしれない側に
  倒す」要件と整合する。
- `_matched_dir` 非空（slug 一致）経路は本修正の対象外とした。既存実装の
  `_stage_checkpoint_assert_slug_match` は match 時に 0 を返し escalate しないため、
  この経路では誤 block は構造的に起きない（slug が一致しているので Issue #114
  の防御対象でもない）。

## 残存課題

- なし。本要件は全 AC をテストで担保し、Out of Scope を逸脱していない。

STATUS: complete
