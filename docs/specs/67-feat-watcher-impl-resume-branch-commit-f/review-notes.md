# Review Notes — Issue #67 impl-resume Branch Protection

<!-- idd-claude:review round=1 model=claude-opus-4-7 reviewer=manual-recovery -->

## Reviewed Scope

- Branch       : `claude/issue-67-impl-feat-watcher-impl-resume-branch-commit-f`
- HEAD commit  : `1cd47e22f638153faeca4bc1fa8bcc1f62e89452`
- Compared to  : `29a2917..HEAD` (branch divergence point on main)
- Round        : 1 (manual reviewer recovery; auto-watcher hit parse-failed in #63 bug)
- Files in scope:
  - `local-watcher/bin/issue-watcher.sh`
  - `.claude/agents/developer.md`
  - `repo-template/.claude/agents/developer.md`
  - `repo-template/CLAUDE.md`
  - `README.md`
  - `docs/specs/67-feat-watcher-impl-resume-branch-commit-f/impl-notes.md`

## Verified Requirements (AC coverage)

すべての numeric requirement ID を `requirements.md` から抽出し、実装または検証手段とのマッピングを以下に記録する。

| Req | Coverage | Evidence |
|---|---|---|
| 1.1 | impl + smoke | `local-watcher/bin/issue-watcher.sh:2905-2920`（`preserve != "true"` 分岐で legacy `git checkout -B BRANCH origin/main` + `git push --force-with-lease` を温存）+ `slot_log "resume-mode=legacy-force-push"` |
| 1.2 | impl | `local-watcher/bin/issue-watcher.sh:2922-2945`（`preserve == "true"` 分岐で保護経路を有効化） |
| 1.3 | impl + smoke | `local-watcher/bin/issue-watcher.sh:2822-2845` の `_resume_normalize_flag preserve_default_off`。Reviewer 側 inline smoke で `true→true / false/empty/True/1/yes→false` の 6 ケース PASS を再確認 |
| 1.4 | impl（無変更を保証） | `git diff 29a2917..HEAD -- local-watcher/bin/issue-watcher.sh` に既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_*` 等）の改変なし |
| 1.5 | impl | `local-watcher/bin/issue-watcher.sh:173,181` が `:-false` / `:-true` の env デフォルトを採用。cron 文字列に新規 env を追記しなくても既定挙動で動作 |
| 2.1 | impl + smoke | `local-watcher/bin/issue-watcher.sh:2859-2870` `_resume_detect_existing_branch`（`git ls-remote --exit-code --heads origin refs/heads/$branch`）+ `_resume_branch_init:2925-2932` で existing 分岐 |
| 2.2 | impl | `local-watcher/bin/issue-watcher.sh:2933-2940` で branch 不在時に `origin/main` から checkout して `resume-mode=fresh-from-main` を log |
| 2.3 | impl | `slot_log "resume-mode=existing-branch branch=$BRANCH origin_sha=$origin_sha"` (line 2932) — 運用者がログから事後判別可能 |
| 2.4 | impl + smoke | `local-watcher/bin/issue-watcher.sh:1900-1980` の `build_dev_prompt_a` 末尾 inline 注入。`RESUME_PRESERVE=true` 時のみ resume 指示節を出力 |
| 2.5 | impl（無変更を保証） | `_worktree_reset` の `git clean -fdx` 既存実装に diff なし。untracked / 一時ファイルは保護対象外として温存 |
| 3.1 | impl | `build_dev_prompt_a` (line 1916-1932) の `tracking == "true"` 分岐で「`- [ ]` → `- [x]` 行内編集 + `docs(tasks): mark <id> as done` 専用 commit」指示を出力 |
| 3.2 | impl | 同関数 (line 1933-1940) の `tracking == "false"` 分岐で「進捗マーカーは書き換えない」指示を出力 |
| 3.3 | doc + impl | `.claude/agents/developer.md` および `repo-template/.claude/agents/developer.md` に「未完了タスクの先頭から再開」明記。`build_dev_prompt_a` 末尾 prompt にも inline 記載 |
| 3.4 | doc + impl | 同上「全完了時は追加実装をしない」明記。prompt 内にも記載 |
| 3.5 | doc | `.claude/agents/developer.md`（および repo-template）「書き換え禁止領域」節で `_Requirements:_` / `_Boundary:_` / `_Depends:_` / 順序 / インデント / deferrable 印を列挙 |
| 3.6 | impl + smoke | `_resume_normalize_flag tracking_default_on`（line 2829-2836）+ inline smoke 6 ケース PASS（`false→false / true/empty/False/0/no→true`） |
| 4.1 | impl | `local-watcher/bin/issue-watcher.sh:2974,2977` の `git push -u origin "$branch"` に force 系オプション無し |
| 4.2 | impl | `_resume_push:2999-3003` で non-ff stderr 検出 → `_resume_mark_nonff_failed` → `_slot_mark_failed "branch-nonff"` で claude-failed 化。リトライ無し |
| 4.3 | impl | `_resume_mark_nonff_failed:3035-3066` の Issue コメント body に「自動 force-push を抑制」「人間が衝突解消後 `claude-failed` 除去で再 pickup」「対象 branch / Issue 番号」「stderr tail」を含める |
| 4.4 | impl | `_resume_branch_init:2905-2918` の legacy 経路で `--force-with-lease` を温存 |
| 4.5 | impl（不在を保証） | `_resume_push` / `_resume_mark_nonff_failed` 内に `git reset` / `git rebase` / `git merge` の呼び出し無し |
| 5.1 | doc | `README.md:1677-1788` の「impl-resume Branch Protection (#67)」節に env var 表 / 既定値 / 有効化方法を追記 |
| 5.2 | doc | 同節「opt-in 後の挙動」サブ節で運用者視点の挙動説明（既存 origin branch resume / `tasks.md` 進捗追跡 / non-ff 検出と claude-failed 遷移） |
| 5.3 | doc | 同節「Migration Note（既存ユーザー向け）」サブ節で「既定で従来挙動維持」「opt-in 後も新規 branch は従来通り」「進行中 Issue は無影響」を明記 |
| 6.1 | deferred | impl-notes.md「Dogfood シナリオの実行ステータス」で本 PR 内未実施を明示。AC 6.x は実 cron / 実 Claude API 起動を要するため Reviewer ステージでの実行は構造上不可。inline smoke + 静的解析で構造的に保証 |
| 6.2 | deferred | 同上 |
| 6.3 | deferred | 同上 |
| NFR 1.1 | impl + diff | 既定値下で `_resume_branch_init` legacy 経路は本機能導入前と完全等価。bash -n PASS / cron-like PATH 解決 PASS / shellcheck 新規 warning 0 件で構造的に保証 |
| NFR 1.2 | impl（無変更を保証） | `LABEL_*` 定数に diff なし。`_slot_mark_failed` の stage 識別子に `branch-nonff` を追加するのみ（既存ラベル付与挙動は不変、新規ラベルは追加していない） |
| NFR 1.3 | impl（無変更を保証） | `slot_log` / `slot_warn` 既存書式踏襲、exit code 意味改変なし、`LOG_DIR` 配下のログファイル先変更なし |
| NFR 2.1 | impl | `slot_log "resume-mode=existing-branch"` / `resume-mode=fresh-from-main` / `resume-mode=legacy-force-push` / `resume-failure=non-ff` を実装。3 イベント全て事後判別可能 |
| NFR 2.2 | impl | `slot_log "resume-failure=non-ff issue=#${NUMBER:-?} branch=$branch"`（line 3002）で原因 + Issue 番号 + branch を 1 行ログに記録 |
| NFR 3.1 | smoke | Reviewer 側で `shellcheck local-watcher/bin/issue-watcher.sh` 再実行：SC2012 / SC2317 のみ計 8 件、すべて line 696-3147 範囲の **既存** info 警告（本 PR で追加された新規関数 `_resume_*` 群および line 173/181 の Config block / line 1900-1980 の prompt 注入には新規警告なし） |
| NFR 3.2 | smoke | `.github/workflows/*.yml` 変更なし（`git diff 29a2917..HEAD -- .github/` で workflow YAML に変更が無いことを確認）。actionlint 対象外 |

## Boundary Compliance

`tasks.md` の `_Boundary:_` 注釈と実際の変更ファイル対応:

- Task 1.1 / 1.2 / 2.1 / 2.2 / 3.1 / 3.2 / 4.1 / 4.2 (`local-watcher/bin/issue-watcher.sh`): 該当ファイルのみを編集、boundary 遵守 ✓
- Task 5.1 (`.claude/agents/developer.md`, `repo-template/.claude/agents/developer.md`): 該当 2 ファイルのみを編集 ✓
- Task 6.1 (`README.md`): 該当ファイルのみを編集 ✓
- Task 6.2 (`repo-template/CLAUDE.md`): 該当ファイルのみを編集 ✓

`requirements.md` / `design.md` / `tasks.md` への書き換えなし（CLAUDE.md「Developer は `design.md` / `tasks.md` を書き換えない」規約に整合）✓

`impl-notes.md` の追加のみ（Developer 補足ノートとして許可される範囲）✓

`_worktree_reset` / `_slot_mark_failed` / `slot_log` / `slot_warn` 等の既存ヘルパは流用のみで改変なし（既存 stage 識別子に `branch-nonff` を追加することは設計許容範囲）✓

## Test / Verification Coverage

idd-claude にユニットテストフレームワークが無い前提（CLAUDE.md「テスト・検証」節）で、検証は静的解析 + bash inline smoke + 手動 dogfood の組合せで行う。

- 静的解析: `shellcheck` / `bash -n` / `actionlint`（対象外） すべてクリア
- inline smoke: `_resume_normalize_flag` 13 ケース / `_resume_detect_existing_branch` 3 ケース / `build_dev_prompt_a` 4 ケース、impl-notes.md に結果記録あり、Reviewer 側で normalize_flag 6 ケースを再実行し PASS
- dogfood (AC 6.1 / 6.2 / 6.3): impl-notes.md「確認事項」で merge 後の運用者責務として明示的に deferred。実 cron / 実 Claude API 起動を要するため Developer worktree 内では実行不可。Reviewer judgment としてはこの deferral を **missing test とは判定しない**（CLAUDE.md「テスト・検証」節の dogfood 項に「大きい機能変更は…test issue を立てて watcher が正しく拾えるかで最終確認する」とあり、別 Issue 切り出しが許容される運用慣行に整合）

## Findings

なし（no findings）。

3 カテゴリ判定基準（AC 未カバー / missing test / boundary 逸脱）のいずれにも該当する逸脱を検出しなかった。スタイル / 命名 / lint / フォーマット観点では reject しない方針に従い、impl-notes.md の「確認事項」3 項目（dogfood 実行 / stderr ロケール / `_resume_push` 戻り値設計）はすべて非 reject 案件として人間判断に委ねる。

## Summary

requirements.md の Req 1.1〜6.3 + NFR 1.1〜3.2 のすべてを実装または明示的 deferral でカバー。`_resume_branch_init` の Strategy Pattern（legacy / preserve）が opt-in flag で安全に分岐し、既定 OFF 下では本機能導入前と完全等価な挙動を保つ。`_resume_push` の non-ff 検出と `_resume_mark_nonff_failed` の Issue コメント / ログ仕様が AC 4.x / NFR 2.x を満たす。後方互換性（NFR 1.x）は env var 既定値・既存ラベル不変・既存ログ書式踏襲で構造的に保証されている。dogfood 3 シナリオは Developer worktree 制約により deferred で documented。

RESULT: approve
