# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-19T14:46:50Z -->

## Reviewed Scope

- Branch: claude/issue-114-impl-bug-watcher-stage-checkpoint-resume-docs
- HEAD commit: 9ab0476a3cdcbc6dca6604b0d7944e736297cbae
- Compared to: main..HEAD
- 変更ファイル:
  - `local-watcher/bin/issue-watcher.sh` (+234 -8)
  - `local-watcher/test/normalize_slug_test.sh` (新規, 146 行)
  - `local-watcher/test/slug_match_guard_test.sh` (新規, 211 行)
  - `docs/specs/114-.../requirements.md` (新規)
  - `docs/specs/114-.../impl-notes.md` (新規)
- 備考: `tasks.md` / `design.md` は本 spec dir に存在しない（Triage で Architect 非起動だった
  ため tasks.md は未生成。境界判定は requirements.md の Out of Scope と影響ファイル範囲で実施）。

## Verified Requirements

- **1.1** — `_slot_run_issue` 冒頭 (`local-watcher/bin/issue-watcher.sh:4957-4958`) で
  `EXPECTED_SLUG=$(_normalize_slug "$TITLE")` により Issue タイトル由来の expected-slug を導出。
- **1.2** — `_stage_checkpoint_assert_slug_match`
  (`local-watcher/bin/issue-watcher.sh:4783-4807`) が basename から `<N>-` プレフィックスを
  剥がして `found-slug` を取り出し expected と比較。`slug_match_guard_test.sh` Case 5/6 で
  番号部分一致を不一致扱い、`<N>-` 1 回剥がしの境界を検証。
- **1.3** — 一致時の継続: `_slot_run_issue:4974-4990` で一致候補を採用し従来どおり
  impl-resume に進む。`slug_match_guard_test.sh` Case 1（match → return 0 + slug-match ログ）。
- **1.4** — 不一致時の中止: `_slot_run_issue:4993-4996` および
  `_stage_checkpoint_assert_slug_match:4805-4807` で escalate + return 1。
  `slug_match_guard_test.sh` Case 2（mismatch → return 1 + slug-mismatch ログ + escalate 呼出）。
- **1.5** — 複数候補が全て不一致: `_slot_run_issue:4970-4996` で `SPEC_CANDIDATES` を全件
  scan, 一致候補なしなら先頭候補で escalate して return 1。
- **1.6** — `docs/specs/<N>-*/` 不在時: `_slot_run_issue:5005-5007` で
  `SLUG="$EXPECTED_SLUG"` のみ採用し従来経路に倒す。
- **2.1** — `_resume_branch_assert_slug_match`
  (`local-watcher/bin/issue-watcher.sh:4826-4868`) が
  `git ls-remote --heads origin "refs/heads/claude/issue-<N>-impl-*"` で候補列挙し
  `<branch-slug>` 抽出。
- **2.2** — 同関数 line 4854-4862 で expected と一致したブランチがあれば `match_found=true`
  → return 0。呼び出し元 `_slot_run_issue:5178-5180` は従来どおり `_resume_branch_init` へ。
- **2.3** — 同関数 line 4865-4867 で mismatch 時 escalate + return 1。`_slot_run_issue` は
  return 1 で Issue を skip。
- **3.1** — `_slug_mismatch_escalate` (`local-watcher/bin/issue-watcher.sh:4751-4761`) が
  `gh issue edit --remove-label claude-claimed --add-label needs-decisions` を発射。
  `slug_match_guard_test.sh` Case 2 の escalate stub で kind=spec-dir + expected/found/target
  引数を assert。
- **3.2** — 同関数 line 4760 で `gh issue comment` を 1 件投稿（body に種別 / 対象 Issue /
  expected / found / target / 次の手順を含む）。
- **3.3** — `_stage_checkpoint_assert_slug_match` / `_resume_branch_assert_slug_match` 双方の
  mismatch 経路で return 1 し、`_slot_run_issue:4986, 4995, 5178` がそのまま return 1 して
  当該 Issue を skip。
- **3.4** — mismatch 経路では `_resume_branch_init` および新規 SLUG 採用 / spec dir 生成 /
  ブランチ作成のいずれにも到達しない。escalate 副作用は `gh issue edit` / `gh issue comment` /
  `slot_log` のみで、既存 spec dir / ブランチへの mv / rm / push --force は無し（NFR 2.2 兼）。
- **4.1** — `_stage_checkpoint_assert_slug_match:4801` で
  `stage-checkpoint: slug-match issue=#<N> expected=<slug> found=<slug>` を 1 行出力。
  `slug_match_guard_test.sh` Case 1 で assert。
- **4.2** — 同関数 line 4805 で
  `stage-checkpoint: slug-mismatch issue=#<N> expected=<slug> found=<slug>` を 1 行出力
  （NFR 3.2 の 3 値 issue/expected/found を含む）。`slug_match_guard_test.sh` Case 2 で assert。
- **4.3** — `_resume_branch_assert_slug_match:4861, 4865` で
  `resume-branch: slug-match|slug-mismatch issue=#<N> expected=<slug> found=<slug>` を
  1 行出力。コード上で直接観測可能（impl-notes.md「担保テスト」表 4.3 で明示紐付け済）。
- **5.1** — `_normalize_slug` (`local-watcher/bin/issue-watcher.sh:4719-4727`) が lowercase 化 /
  `[^a-z0-9]+` → `-` 縮約 / 40 文字 cut / 末尾ハイフン除去 を順に適用。
  `normalize_slug_test.sh` 全 11 ケース（基本 ASCII / 連続非英数字 / 40 文字切り詰め / 先頭数字 /
  Unicode / 空入力 / 大文字 / legacy 等価性 / 冪等性 / 末尾ハイフン / 先頭ハイフン保持）。
- **5.2** — 共通関数 `_normalize_slug` を expected-slug 導出 (line 4958) と新規 SLUG 導出
  (line 5007) の両経路から参照。`normalize_slug_test.sh` の冪等性ケースで再適用安全性も担保。
- **5.3** — 旧 inline 正規化 (`tr [:upper:] [:lower:] | sed -E 's/[^a-z0-9]+/-/g' | cut -c1-40 | sed -E 's/-+$//'`)
  は `_slot_run_issue` から削除済（grep で同一ファイル内の同等パターン重複なしを確認: line
  4725-4726 の `_normalize_slug` 本体 1 か所のみ）。
- **NFR 1.1** — match 経路では LOG 1 行追加以外の挙動変化なし。`normalize_slug_test.sh` の
  legacy 等価性ケースで既存 inline 実装と同一出力を assert。
- **NFR 1.2** — 既存 env var 名 / `stage-checkpoint:` prefix / `needs-decisions` ラベル /
  cron 登録文字列は不変。新規追加分 (`resume-branch:` prefix) は新規イベントのみで既存
  prefix に干渉しない。
- **NFR 1.3** — `SPEC_CANDIDATES` 空時は `SLUG="$EXPECTED_SLUG"` のみで `SPEC_DIR_REL`
  構築は従来通り。
- **NFR 2.1** — `_stage_checkpoint_assert_slug_match` で NUMBER 未設定 / `<N>-` prefix 欠落
  時は mismatch 扱いに倒し escalate。`slug_match_guard_test.sh` Case 3/4 で assert。
  `_resume_branch_assert_slug_match` のネットワーク失敗時の「不在扱い → 0」設計は
  impl-notes.md 設計判断 #2 で明示（既存 `_resume_detect_existing_branch` と整合）。
- **NFR 2.2** — escalate 経路は `gh issue edit` (ラベル付け替えのみ) + `gh issue comment`
  + `slot_log` のみで、既存 spec dir / ブランチへの mv / rm / push --force は無し。
- **NFR 3.1** — LOG 行はすべて `echo "..." | tee -a "$LOG"` の単一 echo（line 4801, 4805,
  4861, 4865）で改行を含まない。
- **NFR 3.2** — slug-mismatch ログ行に issue 番号 / expected / found の 3 値を含む
  (`slug_match_guard_test.sh` Case 2 で assert)。

## Findings

なし

## Summary

requirements.md の全 numeric AC (Req 1.1〜1.6 / 2.1〜2.3 / 3.1〜3.4 / 4.1〜4.3 / 5.1〜5.3) と
全 NFR (1.1〜1.3 / 2.1〜2.2 / 3.1〜3.2) が `local-watcher/bin/issue-watcher.sh` の新規
3 関数 (`_normalize_slug` / `_stage_checkpoint_assert_slug_match` /
`_resume_branch_assert_slug_match` + escalate ヘルパ `_slug_mismatch_escalate`) と
`_slot_run_issue` の改修で実装されている。新規 2 テスト (`normalize_slug_test.sh` 11 ケース /
`slug_match_guard_test.sh` 13 アサーション) で Req 1 / 3 / 4.1 / 4.2 / 5 / NFR 2.1 が
網羅され、いずれも `bash test/*.sh` で全件 PASS。境界は watcher コア + 該当テスト + 本 spec
dir に限定され、Out of Scope（`pi_build_iteration_prompt` / watcher 外正規化重複）は適切に
残置され impl-notes.md にも明記。`shellcheck` の新規警告 0（pre-existing SC2317 / SC2012 のみ、
本変更で SC2012 が 1 件減少）。後方互換性（既存 env var / ラベル / cron 登録文字列 / 既存ログ
prefix）はすべて保持。

RESULT: approve
