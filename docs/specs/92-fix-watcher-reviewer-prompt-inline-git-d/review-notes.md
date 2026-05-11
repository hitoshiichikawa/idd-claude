# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-11T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-92-impl-fix-watcher-reviewer-prompt-inline-git-d
- HEAD commit: 4cd80c87d0812b8961aff7c1444eaadf4f96f85d
- Compared to: main..HEAD
- Changed files (git diff --stat main..HEAD):
  - `.claude/agents/reviewer.md` (+2/-2)
  - `repo-template/.claude/agents/reviewer.md` (+2/-2)
  - `local-watcher/bin/issue-watcher.sh` (build_reviewer_prompt only, +21/-10)
  - `docs/specs/92-fix-watcher-reviewer-prompt-inline-git-d/impl-notes.md` (new, +139)
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節なし → opt-out 解釈。
  flag 観点の細目チェックは適用しない（standard 3 カテゴリ判定のみ）。
- 参考: `tasks.md` / `design.md` は本 Issue では生成されていない（Architect 未起動の bug-fix）。
  Boundary は requirements.md の Out of Scope と Requirements 文面（`build_reviewer_prompt`
  関数 / reviewer.md 1 行追記）から推定して照合した。

## Verified Requirements

- 1.1 — `build_reviewer_prompt` から `## 最新差分（${BASE_BRANCH}..HEAD）` 節と
  ` ```diff ` コードブロックを削除。生成 prompt で `grep -c '## 最新差分'` = 0,
  `grep -c '` + "```" + `diff'` = 0 を確認（local-watcher/bin/issue-watcher.sh:2778-2794）
- 1.2 — slot-1 worktree で `build_reviewer_prompt 1 "(none)"` の `wc -c` = 2,976 B
  （< 131,072 B）。impl-notes.md の測定（87KB diff 環境でも 2,863 B）とも一致
- 1.3 — `diff_content` 変数取得・fallback 分岐を削除。空 diff / git 失敗時の fallback
  テキスト（「差分が取得できませんでした」等）は prompt に残置されておらず、
  関数自体が `git diff` を呼ばないため diff 取得失敗の概念がない。`/tmp` 配下（非 git）でも
  prompt 生成成功（exit=0）を確認
- 1.4 — `- BRANCH       : ...` / `- HEAD commit  : ...` / `- BASE_BRANCH  : ...` の
  3 identifier 行が prompt 内に存在（issue-watcher.sh:2761-2763）
- 2.1 — `git diff --stat ${BASE_BRANCH}..HEAD` を「## 差分の取得」節に明示
  （issue-watcher.sh:2786）
- 2.2 — `git diff ${BASE_BRANCH}..HEAD -- <path>` を同節に明示（issue-watcher.sh:2791）
- 2.3 — heredoc 展開で `${BASE_BRANCH}` が `main` に置換されることを実測確認
  （`git diff --stat main..HEAD` が prompt 内に literal で出現）
- 3.1 — 「最終行は必ず `RESULT: approve` または `RESULT: reject` で終わること」を維持
  （issue-watcher.sh:2802）
- 3.2 — 「AC 未カバー / missing test / boundary 逸脱 の 3 つに限定」を維持
  （issue-watcher.sh:2801）
- 3.3 — `（round=${round} / 最大 2 round）を実施してください。` を冒頭に維持
  （issue-watcher.sh:2752）。`ROUND : 1` 行も併存
- 3.4 — `- PREV_RESULT  : ${prev_result}` 行を維持（issue-watcher.sh:2766）
- 3.5 — `requirements.md / design.md / tasks.md / 既存実装コード / テストコードを書き換えないこと`,
  `` `git add` / `git commit` / `git push` / `gh` を実行しないこと ``,
  `スタイル / 命名 / lint / フォーマットの観点での reject はしないこと` の 3 行が
  `## 制約` セクションに維持されている（issue-watcher.sh:2805-2808）
- 4.1 — `BASE_BRANCH` / `REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` /
  `DEV_MODEL` の参照は今回の diff に含まれない（`git diff main..HEAD --name-only`
  でも watcher の該当箇所は build_reviewer_prompt のみ）
- 4.2 — `claude-reviewing` / `claude-failed` 等のラベル操作箇所には変更なし（diff 範囲外）
- 4.3 — exit code に関わる箇所には変更なし
- 4.4 — Reviewer 差し戻しループ・round 制御ロジックは呼び出し側で、今回 diff の範囲外
- 4.5 — `install.sh` / `setup.sh` / cron 登録文字列に関する変更なし
- NFR 1.1 — prompt 2,976 B（< 131,072 B）を測定
- NFR 1.2 — `build_reviewer_prompt` が `git diff` を呼ばない設計に変更され、出力サイズが
  差分内容と独立。impl-notes.md の 87KB diff 環境測定（2,863 B）と一致
- NFR 2.1 — `shellcheck local-watcher/bin/issue-watcher.sh` を実行。exit=0。残存警告
  （SC2317 / SC2012）は全て本変更と無関係な既存行（302, 904, 1050-1052, 1664, 2017, 2299, 3889）。
  本変更（2740 周辺）由来の新規警告は 0 件
- NFR 3.1 — caller（dry-run の no-target 経路）には変更なし。impl-notes.md の dry-run 結果と整合
- NFR 3.2 — `git` リポジトリ外（`/tmp`）でも `build_reviewer_prompt` が成功（head_sha は
  `(unknown)` に fallback）。差分空でも prompt 生成は成立
- NFR 4.1 — `repo-template/.claude/agents/reviewer.md` および root 用 mirror
  `.claude/agents/reviewer.md` の双方が同期更新されており self-hosting で齟齬なし

## Findings

なし

## Summary

`build_reviewer_prompt` から inline diff 全文を撤廃し、reviewer サブエージェントへの
差分取得手順提示に切り替える設計。実測で prompt は約 3 KB の固定サイズに収まり、AC 1.1 〜
NFR 4.1 まで全て担保されている。reviewer.md の補足修正も Out of Scope の許容範囲（1 行追記
程度）に収まり、判定ルール・出力契約に変更なし。境界・後方互換・shellcheck いずれもクリア。

RESULT: approve
