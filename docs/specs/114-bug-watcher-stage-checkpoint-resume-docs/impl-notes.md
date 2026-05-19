# 実装ノート (Issue #114)

## 概要

watcher の Stage Checkpoint Resume を「Issue 番号 + 正規化スラグ」の 2 軸で照合する
ガードを導入し、fork / mirror clone 由来の番号衝突で無関係な過去 Issue の
`docs/specs/<N>-*/` / `claude/issue-<N>-impl-*` ブランチを誤って resume する事故を防ぐ。

## 実装ステップ

1. `_normalize_slug` を共通関数として `local-watcher/bin/issue-watcher.sh` に追加
   - Req 5.1（lowercase 化 / 非英数字をハイフン 1 個に縮約 / 40 文字切り詰め / 末尾ハイフン除去）
   - 既存 inline 実装（`_slot_run_issue` 内）と差分等価（NFR 1.1）
2. `_slug_mismatch_escalate` 共通エスカレーションヘルパを追加
   - `claude-claimed` 除去 → `needs-decisions` 付与 → Issue コメント 1 件投稿 → `slot_log`
   - Req 3.1, 3.2, 3.3, 3.4
3. `_stage_checkpoint_assert_slug_match` を追加（Req 1, 4.1, 4.2）
   - spec dir basename から `<N>-` プレフィックスを剥がして `found-slug` を抽出
   - match 時は `stage-checkpoint: slug-match issue=#N expected=<slug> found=<slug>` を 1 行 LOG
   - mismatch 時は `stage-checkpoint: slug-mismatch ...` を 1 行 LOG + escalate
4. `_resume_branch_assert_slug_match` を追加（Req 2, 4.3）
   - `git ls-remote --heads origin "refs/heads/claude/issue-<N>-impl-*"` で候補列挙
   - 候補無し / ネットワーク失敗時は「不在扱い」で 0 を返す（NFR 2.1 安全側 + 既存
     `_resume_detect_existing_branch` と整合）
   - 候補有り + いずれかが expected と一致 → match
   - 候補有り + 一致なし → mismatch + escalate
   - `resume-branch: slug-match|slug-mismatch issue=#N expected=<slug> found=<slug>` を 1 行 LOG
5. `_slot_run_issue` の spec dir 検出ロジックを改修（line 4953 周辺）
   - 旧 inline スラグ計算を `_normalize_slug` に置換（Req 5.2, 5.3）
   - `docs/specs/<N>-*/` を glob で全件列挙し expected-slug と照合
   - 一致候補があれば従来どおり impl-resume 継続
   - 一致候補が無く非空なら mismatch escalate + return 1（Issue skip）
   - 候補自体が無ければ新規スラグ導出（Req 1.6）
6. `_resume_branch_init` 呼び出し直前に `_resume_branch_assert_slug_match "$SLUG"` を挿入
7. テスト追加
   - `local-watcher/test/normalize_slug_test.sh`: 11 ケース（正規化規則・冪等性・legacy 等価性）
   - `local-watcher/test/slug_match_guard_test.sh`: 13 ケース（match / mismatch / NUMBER 未設定 /
     `<N>-` prefix 欠落 / 番号部分一致 / `<N>-` を 1 回だけ剥がす境界）

## 設計判断

### 1. `_resume_branch_assert_slug_match` で `ls-remote` を glob 検索する設計
Req 2.1 は「`claude/issue-<N>-impl-*` 形式の既存リモートブランチを resume 候補として
検出したとき」と書かれているため、単一の `BRANCH` 名だけを `_resume_detect_existing_branch`
で問い合わせる現行設計では「異なるスラグの origin branch」を構造的に発見できない。
そこで `git ls-remote --heads origin "refs/heads/claude/issue-<N>-impl-*"` で
glob 検索する独立関数を追加した。`_resume_detect_existing_branch` 自体は単一名検索
の役割を保ち、後方互換性を維持する（NFR 1.2）。

### 2. ネットワーク失敗時の安全側挙動
`ls-remote` がタイムアウト / 失敗した場合、`_resume_branch_assert_slug_match` は
「候補なし」として 0 を返す。これは `_resume_detect_existing_branch` の既存挙動
（ネットワーク失敗を「不在」扱い）と整合し、後続の `_resume_branch_init` が
`fresh-from-base` 経路に倒れることで impl-resume が中断されずに継続できる。
mismatch を見逃すリスクは残るが、ネットワーク不調時に Issue を `needs-decisions` に
倒すと cron 周期ごとに人間判断が必要になる運用負荷が大きいため、安全側 = 継続を選択した。

### 3. `_slug_mismatch_escalate` を `_slot_mark_failed` の薄い wrapper にしなかった理由
`_slot_mark_failed` は `claude-failed` ラベルを付与するが、本要件 Req 3.1 は
`needs-decisions` 付与（= 人間が答えれば次サイクルで再 pickup）を要求している。
意味的に別のエスカレーション経路なので、独立関数として実装した。

### 4. EXISTING_SPEC_DIR の `ls -d` を glob ループに置換
shellcheck SC2012 ("Use find instead of ls") を解消し、複数候補を正しく扱うため
`for _spec_glob in "$WT/docs/specs/${NUMBER}-"*; do ... done` パターンに切り替えた。
副作用として shellcheck 警告が 1 件減った（pre-existing SC2012 が消えた）。

### 5. 既存 `pi_build_iteration_prompt` の `ls -d` には手を付けない
line 1771 の同様 `ls -d` パターンは PR Iteration の prompt builder で本要件の対象外
（Out of Scope: watcher 外プロンプト関連は手をつけない）。pre-existing SC2012 は
そのまま残置する。

## 受入基準と担保テスト

| Req ID | 担保 |
|---|---|
| 1.1 | `_slot_run_issue` 冒頭で `EXPECTED_SLUG=$(_normalize_slug "$TITLE")` を導出 |
| 1.2 | `_stage_checkpoint_assert_slug_match` が basename から `<N>-` を剥がして比較。`slug_match_guard_test.sh` Case 5/6 |
| 1.3 | `slug_match_guard_test.sh` Case 1 (match → return 0) |
| 1.4 | `slug_match_guard_test.sh` Case 2 (mismatch → return 1) |
| 1.5 | `_slot_run_issue` で `SPEC_CANDIDATES` 全件チェック後に一致無しなら escalate |
| 1.6 | `_slot_run_issue` で `${#SPEC_CANDIDATES[@]} -eq 0` なら `_normalize_slug` を新規 SLUG として採用 |
| 2.1 | `_resume_branch_assert_slug_match` が `ls-remote --heads origin "refs/heads/claude/issue-<N>-impl-*"` で glob 検索 |
| 2.2 | 同関数で match 検出時 0 を返し、呼び出し元 `_resume_branch_init` は従来通り |
| 2.3 | 同関数で mismatch 時に escalate + return 1。呼び出し元 `_slot_run_issue` が return 1 で Issue skip |
| 3.1 | `_slug_mismatch_escalate` が `--remove-label claude-claimed --add-label needs-decisions` を 1 つの `gh issue edit` で実行 |
| 3.2 | `_slug_mismatch_escalate` が `gh issue comment` で 1 件投稿 |
| 3.3 | spec-dir/resume-branch 双方で mismatch 時に `return 1` し、`_slot_run_issue` の戻り値で Issue を skip |
| 3.4 | mismatch ルートでは `_resume_branch_init` / 新規 SLUG 経路に到達しないため、ブランチ作成 / spec dir 生成 / 削除は行わない |
| 4.1 | `slug_match_guard_test.sh` Case 1 で `stage-checkpoint: slug-match issue=#114 expected=... found=...` を assert |
| 4.2 | `slug_match_guard_test.sh` Case 2 で `stage-checkpoint: slug-mismatch ...` を assert |
| 4.3 | `_resume_branch_assert_slug_match` が `resume-branch: slug-match\|slug-mismatch ...` を 1 行出力 |
| 5.1 | `normalize_slug_test.sh` 全 11 ケース |
| 5.2 | `_normalize_slug` を expected-slug 導出 / 新規 SLUG 導出から参照（spec dir 検出は basename 剥がしのため別経路） |
| 5.3 | `_slot_run_issue` 内の旧 inline 正規化 sed パイプは削除済（grep で `tr '[:upper:]' '[:lower:]'` の重複が無いことを `grep -c` で確認可能） |
| NFR 1.1 | 一致ケースでは LOG 1 行追加以外の挙動変化なし。`normalize_slug_test.sh` で legacy 等価性を assert |
| NFR 1.2 | 既存 env var / ラベル名 / ログ prefix `stage-checkpoint:` / cron 登録文字列は不変 |
| NFR 1.3 | `SPEC_CANDIDATES` 空時は `SLUG="$EXPECTED_SLUG"` のみ。`SPEC_DIR_REL` 構築は従来通り |
| NFR 2.1 | `_stage_checkpoint_assert_slug_match` で NUMBER 未設定 / prefix 欠落時は mismatch 扱い。`_resume_branch_assert_slug_match` でネットワーク失敗は「候補なし」扱い |
| NFR 2.2 | 既存 spec dir / ブランチに対して mv / rm / push --force は実行しない（escalate は label + comment のみ） |
| NFR 3.1 | LOG 行はすべて単一 `echo` で改行を含まない |
| NFR 3.2 | LOG 行に issue / expected / found の 3 値を含む（Case 2 で assert） |

## スモークテスト結果

- `bash -n local-watcher/bin/issue-watcher.sh` → syntax OK
- `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh local-watcher/test/*.sh` → 新規警告 0（pre-existing SC2317 / SC2012 のみ。SC2012 は本変更で 1 件減少）
- `bash local-watcher/test/normalize_slug_test.sh` → PASS: 11, FAIL: 0
- `bash local-watcher/test/slug_match_guard_test.sh` → PASS: 13, FAIL: 0
- 既存テスト全件（parse_review_result / qa_detect_rate_limit / qa_run_claude_stage / stagec_pr_verify\* / verify_pushed_or_retry）も再実行して PASS

## 確認事項（レビュワー向け）

1. **`_resume_branch_assert_slug_match` のネットワーク失敗時の挙動**
   ls-remote 失敗を「候補なし」として扱い resume を継続する設計（impl-notes.md 設計判断 #2）。
   逆方向の選択（ネットワーク失敗時も escalate）も可能。運用負荷との trade-off。
2. **Req 2 の発火条件の解釈**
   現実装では「MODE=impl-resume に入った後（= spec dir 一致が確定した後）」にブランチ slug
   照合を行う。spec dir 不在で MODE != impl-resume の場合、ブランチ照合は走らない。
   要件文面では明示されていないが、自然な解釈と判断した。レビューで指摘あれば再考。
3. **`_normalize_slug` の 40 文字切り詰めと先頭ハイフン**
   切り詰めの結果として先頭がハイフンになるケースを規約上 OK としている
   （`normalize_slug_test.sh` Case "先頭ハイフンは保持"）。Issue タイトルの実用例で
   このケースが発生することは稀だが、テストで規約挙動を明示している。
4. **`pi_build_iteration_prompt` 内の line 1771 `ls -d`**
   同じ番号衝突リスクが PR Iteration の prompt builder にもあるが、Out of Scope に従い
   本 PR では触らない。Reviewer から派生 Issue 起票を提案いただきたい。

## 派生タスク候補

- PR Iteration の `pi_build_iteration_prompt` (line 1771) にもスラグ照合を効かせる
- README に「fork / mirror clone と Issue 番号衝突」セクションを追加し、本ガードの存在と
  `needs-decisions` での停止挙動を運用者に説明する
- watcher 外の正規化重複（Triage prompt template / repo-template/ 配下）の単一定義化
