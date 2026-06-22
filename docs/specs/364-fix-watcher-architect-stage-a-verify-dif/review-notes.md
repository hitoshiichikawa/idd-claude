# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-06-23T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-364-impl-fix-watcher-architect-stage-a-verify-dif
- HEAD commit: 11448a071f92d84b7eb570ea5c2c65c95fa83bc0
- Compared to: main..HEAD
- 変更ファイル数: 7（rule 2 系統 / README / spec 2 / 実装 1 / テスト 1）
- 変更行数: +952 / -7
- `STATUS: complete`（Developer 申告）
- `Feature Flag Protocol` 採否: 未宣言（CLAUDE.md に `## Feature Flag Protocol` の `**採否**:` 行なし）→ 3 カテゴリ判定のみ適用

## Verified Requirements

### Requirement 1（tasks-generation rule で存在しないパスの diff を抑止する）

- 1.1 — `.claude/rules/tasks-generation.md` L368-376「パス存在前提」節で「tasks.md commit 時点の作業ツリーに存在すること」を必須要件として明文化（diff main..HEAD)
- 1.2 — 同 L379-388「idd-claude 特有の注意」節で `repo-template/local-watcher/` 不在と `diff -r local-watcher/bin repo-template/local-watcher/bin` 形を verify に含めないことを明示
- 1.3 — 同 L390-403「root ↔ repo-template 同期 diff の canonical 対象」節で `.claude/agents` / `.claude/rules` の 2 系統に限定する旨を明示
- 1.4 — 同 L405-414「存在の不確定なディレクトリへの diff には存在ガードを置く」節で `[ -d <path> ] && diff -r ...` 書式を canonical として提示
- 1.5 — L372-378 で「構造化 verify ブロック」と「ヒューリスティック抽出」の双方に等しく適用される旨を明示

### Requirement 2（stage-a-verify が「パス不在」と「コード品質失敗」を区別する）

- 2.1 — `stage-a-verify.sh` の新規純粋関数 `_sav_is_path_missing_diff_failure(rc, stderr)` が exit=2 ∧ `No such file or directory` ∧ `^diff:` 行の 3 条件全てを満たす場合のみ 0 を返し、`stage_a_verify_run` の rc 非 0 分岐冒頭で呼ばれて WARN 降格に倒れる（test Case 1.1, 3.1）
- 2.2 — Case 3.1 で `round counter=0 のまま`・`MIF_CALLED=0`（mark_issue_failed 未呼出）・`gh issue comment` 文字列が `GH_ARGS_FILE` に不在を 3 件アサート
- 2.3 — Case 3.1 で `stage-a-verify: WARN`・`reason=verify-path-missing`・`nonexistent_a`（検出パス）3 件含むことをアサート
- 2.4 — `stage_a_verify_run` の rc=124 分岐は従来コードそのまま（diff コンテキストでは変更されず）。Case 1.3, 1.4, 1.5, 1.6, 3.2, 3.3, 3.5 でカバー
- 2.5 — bash -c の最終 exit code 伝搬に依拠して real fail を優先（Case 3.6 で `exit 1 && diff ...` が rc=1 を返し WARN 降格しないこと、Case 3.7 で `true ; diff <missing>` が WARN 降格になることを両極で検証）

### Requirement 3（既存 verify 経路の挙動を変えない / 後方互換）

- 3.1 — Case 3.4 で `true` verify が rc=0 / `_SAV_LAST_OUTCOME=success` / SUCCESS log に倒れることをアサート
- 3.2 — Case 3.5 で `STAGE_A_VERIFY_ENABLED=false` の disabled 経路が変更されないことをアサート
- 3.3 — env 名（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND` / `REPO` / `REPO_DIR`）の参照点に変更なし（diff 上で env 名宣言部は無変更）
- 3.4 — ラベル名（`auto-dev` / `claude-claimed` / `claude-failed` / `needs-iteration`）の取り扱いに変更なし
- 3.5 — `stage_a_verify_resolve_command` の解決順序（構造化 → env → ヒューリスティック）は無変更（diff は Execute ブロックの周辺のみ）

### Requirement 4（観測可能性）

- 4.1 — `stage-a-verify.sh` L944 `sav_warn "reason=verify-path-missing path=... exit=$rc cmd=..."` で WARN 行を 1 件出力（`sav_warn` は `[$REPO] stage-a-verify: WARN:` prefix を付与）
- 4.2 — WARN body に `path=<検出パス>` と `cmd=<printf %q quoted>` を含む（Case 3.1 でアサート）
- 4.3 — Case 3.1 の `grep '\[.*\] stage-a-verify: WARN'` 抽出が `reason=verify-path-missing` 含む行を返すことをアサート
- 4.4 — `_SAV_LAST_OUTCOME="warn-skipped"` を代入し（L943）、enum コメント（L412）に追記。run サマリ `stage-a-verify=` 列の README enum にも追加（README L756）

### Requirement 5（暫定運用解除の前提整備）

- 5.1 — `README.md` L5170-5187「暫定 `STAGE_A_VERIFY_ENABLED=false` の撤去前提」節と「失敗・異常系」節への WARN 降格追記（L5271-5285）、`stage-a-verify` outcome enum 追加（L756）
- 5.2 — README L5175-5179 で「`install.sh --local` 反映後に grep で WARN 観測 → 撤去可能」を明示。impl-notes.md L114-128 にも DoD として手順を記載
- 5.3 — Case 3.1（fix 適用下で WARN 降格 → false-fail なし）+ Case 3.4（既存 success 不変）で担保

### Non-Functional

- NFR 1.1 — Case 3.3, 3.4, 3.5 で既存挙動温存をアサート。`bash -c` への `cmd` 伝達は printf %q quoting も含めて従来 inline と同等
- NFR 1.2 — `stage_a_verify_run` 戻り値 0=success/skip/disabled/warn-skipped, 1=round1, 2=round2 を Case 3.1 / 3.2 / 3.5 で検証。warn-skipped は 0 に集約され契約（0=continue-stage-A）と整合
- NFR 1.3 — tasks-generation rule の既存節（`_Requirements:_` / `_Boundary:_` / 構造化 verify ブロック等）は触らず追加節のみ。diff main..HEAD で既存節への delete/modify なし
- NFR 2.1 — `shellcheck local-watcher/bin/modules/stage-a-verify.sh local-watcher/test/stage_a_verify_path_missing_test.sh` および `bash -n` を reviewer 側で再実行し OK 確認
- NFR 2.2 — 近接テスト 43 ケース新規追加・`bash local-watcher/test/stage_a_verify_path_missing_test.sh` を reviewer 側で再実行し `PASS=43 / FAIL=0` 確認
  - (a) パス不在 → WARN 降格: Case 3.1
  - (b) real lint fail → 従来 fail: Case 3.2
  - (c) diff content 差分 → 従来 fail: Case 3.3
- NFR 2.3 — `diff -r .claude/rules repo-template/.claude/rules` を reviewer 側で再実行し空（byte 一致）確認
- NFR 3.1 — README L5170-5187 / L5271-5285 / L756 への反映あり
- NFR 3.2 — `.claude/rules/tasks-generation.md` ↔ `repo-template/.claude/rules/tasks-generation.md` が byte 一致（同上）
- NFR 4.1 — `sav_warn` の出力に `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify: WARN:` prefix が付く既存挙動を継承
- NFR 4.2 — WARN 行は `reason=verify-path-missing path=... exit=... cmd=...` の固定キー順 1 行集約

## Boundary 確認

- 変更ファイル 7 件はすべて requirements.md のスコープ内（Watcher Stage A Verify Module / tasks-generation rule / README / spec / 近接テスト / repo-template 同期）
- Out of Scope 違反なし:
  - gate 廃止せず（維持）
  - 他 rule 群（design-principles / ears-format / requirements-review-gate 等）は無変更
  - 過去 Issue の遡及救済なし（forward-only 設計）
  - `diff` 以外のコマンドへの拡張なし
  - verify lint ツール追加なし
  - `local-watcher/` の `repo-template/` 配下ミラー化なし
- root ↔ repo-template 同期は `.claude/rules` 2 系統のみで CLAUDE.md §4 と整合

## Findings

なし

## Summary

要件定義の全 numeric ID（Req 1.1〜1.5 / 2.1〜2.5 / 3.1〜3.5 / 4.1〜4.4 / 5.1〜5.3 / NFR 1.1〜4.2）に対応する実装またはテストを diff 内で確認。43 ケースの近接テストが PASS、shellcheck・bash -n クリーン、root↔repo-template の `.claude/rules` byte 一致を reviewer 側で再検証済み。`_sav_is_path_missing_diff_failure` の 3 条件（exit=2 ∧ ENOENT ∧ `^diff:` 行）が誤判定回避を明確にしており、`bash -c` の exit code 伝搬に依拠した連結コマンド対応（Req 2.5）も Case 3.6（real fail 優先）/ Case 3.7（path-missing 単独）の両極で検証されている。Boundary 逸脱なし。Out of Scope の遵守を確認。

RESULT: approve
