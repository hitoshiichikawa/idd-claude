# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-08T02:18:50Z -->

## Reviewed Scope

- Branch: claude/issue-89-impl-feat-watcher-template-base-branch-env-gi
- HEAD commit: 1ca2fbb67256aa0776b024caeb0d1f7b70935424
- Compared to: main..HEAD

CLAUDE.md の `## Feature Flag Protocol` 節は存在しないため opt-out として解釈。flag 観点の細目は適用せず、通常 3 カテゴリで判定。

## Verified Requirements

- 1.1 — `local-watcher/bin/issue-watcher.sh:75` で `BASE_BRANCH` を resolved 値として確立、G1-G7 の全置換（L276-277, L1826/1865/1987/1994, L3683/3709, L4036/4063/4462, Stage A/A'/B/C heredoc）で参照
- 1.2 — `BASE_BRANCH="${BASE_BRANCH:-main}"`（L75）の bash 既定値展開
- 1.3 — `git checkout -B "$BRANCH" "origin/${BASE_BRANCH}"`（L4036, L4063, L4462）, `worktree add --detach ... "origin/${BASE_BRANCH}"`（L3683）
- 1.4 — `git -C "$wt" reset --hard "origin/${BASE_BRANCH}"`（L3709）+ slot_log L4263
- 1.5 — `build_reviewer_prompt` の `git diff "${BASE_BRANCH}..HEAD"`（L2746）と prompt 内 `Compared to: ${BASE_BRANCH}..HEAD`（L2781）
- 1.6 — safety-net `git checkout "$BASE_BRANCH"`（L1826/1865/1987/1994）+ MERGE_QUEUE_BASE_BRANCH 連鎖参照
- 1.7 — 起動時 `echo` 1 行（L260）で `base-branch=... merge-queue-base=...` を出力
- 2.1 — `MERGE_QUEUE_BASE_BRANCH="${MERGE_QUEUE_BASE_BRANCH:-${BASE_BRANCH}}"`（L89）連鎖 default。smoke test #3 row 2 で確認
- 2.2 — `MERGE_QUEUE_BASE_BRANCH` が明示されていれば優先。smoke test #3 row 3/4
- 2.3 — 双方未設定時は `main`。smoke test #3 row 1
- 2.4 — env var 名 `MERGE_QUEUE_BASE_BRANCH` 不変（コードで grep 確認）
- 3.1 — root + repo-template 両 workflow に `env.BASE_BRANCH: ${{ vars.IDD_CLAUDE_BASE_BRANCH || 'main' }}`、checkout `ref: ${{ env.BASE_BRANCH }}`、`Create working branch from base` step
- 3.2 — `vars.IDD_CLAUDE_BASE_BRANCH || 'main'` のフォールバック
- 3.3 — prompt heredoc の `${{ env.BASE_BRANCH }}` 展開（4 箇所、initial mode + impl-resume mode の双方）
- 3.4 — `if: vars.IDD_CLAUDE_USE_ACTIONS == 'true'` を変更していない（diff で確認）
- 4.1 — watcher heredoc（Stage A/A'/B/C, L2585/2646/2649/2672/2681/2731/2746/2748/2781/2810/2845, design 経路 L4509/4518）+ 3 agent template の全 `<BASE_BRANCH>` 化
- 4.2 — project-manager.md の `base: <BASE_BRANCH>` 2 箇所（L26, L165）
- 4.3 — reviewer.md / developer.md の `git diff <BASE_BRANCH>..HEAD` / `git log --oneline <BASE_BRANCH>..HEAD`、watcher 側の build_reviewer_prompt 内 `${BASE_BRANCH}..HEAD`
- 4.4 — template に「未指定時の既定は `main`」補足注記、reviewer.md の入力契約節に `<BASE_BRANCH>` 解説段落を追加
- 5.1 — worktree が `origin/${BASE_BRANCH}` 最新化（L3709, L4263）されるため `EXISTING_SPEC_DIR` 検出は base 上の状態を見る（structurally 担保）
- 5.2 — `_resume_branch_init` L4036（PRESERVE=false 経路）, L4063（PRESERVE=true + branch 不在経路）が `origin/${BASE_BRANCH}` 起点
- 5.3 — env var 名 `IMPL_RESUME_PRESERVE_COMMITS` 不変（diff で確認）
- 5.4 — slot_log `resume-mode=fresh-from-base branch=$BRANCH base=$BASE_BRANCH`（L4068）で `main` ハードコード除去、resume_section heredoc も `${BASE_BRANCH}` 展開（L2646/2649）
- 6.1 — README 新節「ブランチ運用と `BASE_BRANCH`」に役割・既定値・cron / launchd / Actions 設定方法を記載
- 6.2 — README 新節に 4 ステップ gitflow 移行手順（develop 作成 → cron 編集 → 次 tick 反映 → dogfood 確認）
- 6.3 — README 新節に 5 行の Resolution Truth Table を表で明示
- 6.4 — root + repo-template CLAUDE.md の「`main` への直接 push」→「base ブランチ（既定 `main`、`BASE_BRANCH` 設定によっては `develop` 等）への直接 push」に一般化、repo-template/CLAUDE.md L135 の `origin/main` も `origin/<BASE_BRANCH>（未指定時は main）` に
- 6.5 — README 新節「dogfood 確認手順」に 6 ステップ（test issue 起票 → ラベル付与 → cron 待ち → PR base 観測 → log 観測）
- 7.1 — `install.sh` 未変更、template 配布物のデフォルトは `vars.IDD_CLAUDE_BASE_BRANCH || 'main'`
- 7.2 — smoke test #1 で 222 行の prompt 出力が `BASE_BRANCH=main` 既定時に byte-equivalent
- 7.3 — `install.sh` を変更しないため `BASE_BRANCH` 設定は consumer repo に強制されない
- NFR 1.1 — smoke test #1（既定 main で prompt byte-equivalent）+ G1-G7 全置換が `BASE_BRANCH=main` 時に変更前と同一展開
- NFR 1.2 — 既存 env var 名（`MERGE_QUEUE_BASE_BRANCH`, `IMPL_RESUME_PRESERVE_COMMITS` 等）すべて温存
- NFR 1.3 — cron / launchd 起動文字列を変更していない（env 追加のみ）
- NFR 1.4 — exit code / ラベル / 遷移契約のコード変更は引数置換のみで logic 不変
- NFR 2.1 — `install.sh` / `setup.sh` 未変更
- NFR 2.2 — sudo を要求する手順を追加していない
- NFR 3.1 — `BASE_BRANCH` 未設定で従来挙動継続。merge 後の人間観測に委ねる旨が impl-notes.md に明記（合理的に scope 外）
- NFR 3.2 — `set -euo pipefail` + 既存 `_slot_mark_failed` 経路に乗せる（silent fail なし）。worktree-reset 失敗時の log は `origin/${BASE_BRANCH}` を含む（L4260）
- NFR 4.1 — 起動時 log L260
- NFR 4.2 — worktree reset / branch init log の `origin/${BASE_BRANCH}` 表記（L3687, L4263, L4260）

## Findings

なし

## Summary

requirements.md の全 numeric ID（Req 1.1〜7.3 + NFR 1.1〜4.2）について、`local-watcher/bin/issue-watcher.sh` の Config Block + G1〜G7 全置換、両 workflow YAML の `env.BASE_BRANCH` 注入、3 agent template のハイブリッド一般化（`<BASE_BRANCH>` 表記 + 補足注記）、CLAUDE.md 文言一般化、README の migration note + Resolution Truth Table + dogfood 手順により、設計通り完全にカバーされている。tasks.md の `_Boundary:_` 違反なし。impl-notes.md の Static Analysis（shellcheck / actionlint / bash -n / grep）と Manual Smoke Tests #1〜#5 が design.md の Testing Strategy 全項目に対応しており、本リポジトリの「unit test framework なし、静的解析 + 手動スモークテスト + dogfood」の検証規約を満たす。残存 `\bmain\b` リテラルもすべて意図的（既定値定義 / コメント / 慣用語）で impl-notes.md に説明あり。

RESULT: approve
