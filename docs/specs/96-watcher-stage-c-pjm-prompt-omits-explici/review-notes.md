# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-12T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-96-impl-watcher-stage-c-pjm-prompt-omits-explici
- HEAD commit: 2450f73436001017c2a971a5bacf98a7c3f53113
- Compared to: main..HEAD
- 変更ファイル: `local-watcher/bin/issue-watcher.sh` / `.github/workflows/issue-to-pr.yml` /
  `repo-template/.claude/agents/project-manager.md` / `README.md` /
  `docs/specs/96-.../requirements.md` / `docs/specs/96-.../impl-notes.md`
- Feature Flag Protocol: `CLAUDE.md` に `## Feature Flag Protocol` 節が存在しないため
  **opt-out として解釈**（通常の 3 カテゴリ判定のみ実施）

## Verified Requirements

- **Req 1.1** — `local-watcher/bin/issue-watcher.sh:2862-2872` の `build_dev_prompt_c` 内に
  「PR の base ブランチ（必ず明示）」節を新設し、`必ず --base ${BASE_BRANCH} を明示してください`
  という肯定形指示を含めている。また Step 2 (line 2882) と 制約 (line 2891-2892) にも併記
- **Req 1.2** — `local-watcher/bin/issue-watcher.sh:4574-4584` の design モード DEV_PROMPT に
  同等の「PR の base ブランチ（必ず明示）」節を追加。Step 2 (line 4548) と 制約 (line 4591-4592)
  にも併記
- **Req 1.3** — heredoc 展開で `${BASE_BRANCH}` の実値（例: `develop`）がプロンプトに埋め込まれ、
  PjM 側は `project-manager.md:17-19` の規約に従って `--base <resolved-base>` を必須化。
  watcher 側 prompt + PjM agent definition の二重指示で観測可能。実 PR の `baseRefName=develop`
  は dogfood E2E で観測する設計（impl-notes 確認事項に明記）
- **Req 1.4** — `BASE_BRANCH="${BASE_BRANCH:-main}"`（line 75）は未変更。未設定時は `main` が
  解決され、prompt には `--base main` がリテラルとして埋め込まれる
- **Req 1.5** — `_assert_base_branch_resolved`（line 2564-2569）を新設。Stage C 入口
  （line 3344-3349）と design 分岐入口（line 4529-4534）で空値検証 → `mark_issue_failed` /
  `_slot_mark_failed` 経由で `claude-failed` ラベル付与してエスカレ
- **Req 2.1** — `build_dev_prompt_c` および design DEV_PROMPT 内で base 実値が 3-4 箇所
  （「PR の base ブランチ」節 / Step 2 / `gh pr edit` 例 / 制約節）に出現
- **Req 2.2** — heredoc 内 `${BASE_BRANCH}` はシェルで実値に展開され、プロンプト本文には
  リテラル文字列として埋め込まれる。`<BASE_BRANCH>` プレースホルダ文字列は本文に残存しない
  （impl-notes 確認済み）
- **Req 2.3** — `repo-template/.claude/agents/project-manager.md:16-58` の「PR の base ブランチ
  解決」共通節と、design-review モード (line 70-72) / implementation モード (line 213-215) の
  両 `base:` 行を「`--base <resolved-base>` を必ず明示する」に書き換え
- **Req 2.4** — `project-manager.md:50-58`「プロンプトに base 実値が含まれていない場合
  （escalation）」サブ節で、PR 作成中断 + `claude-failed` 付与 + Issue コメント報告を規定
- **Req 3.1** — `project-manager.md:28-42` の検証コードブロックで
  `gh pr view <PR> --json baseRefName --jq '.baseRefName'` 取得 + 比較を規定。watcher prompt
  本文（line 2869-2870 / 4580-4581）にも同手順を併記
- **Req 3.2** — `project-manager.md:33-41` で不一致時の自動修正 `gh pr edit --base` 1 回試行 +
  失敗時の `claude-failed` 付与 + PR 作成失敗扱いを規定
- **Req 3.3** — `project-manager.md:43-45` および watcher prompt（line 2870-2871 / 4581-4582）
  で「結果（一致 / 不一致 / 修正実施の有無）を PR 本文の『確認事項』または Issue コメントに
  1 行記載」を規約化
- **Req 4.1** — `BASE_BRANCH:-main` 既定値解決は line 75 で不変。NFR 1.1 と同じ実装裏付け
- **Req 4.2** — 未変更の既定チェーンに加え、prompt が `--base main` を明示する形で `main` を
  最終的に PR base に伝播
- **Req 4.3** — `project-manager.md` 共通節（line 16-58）は design-review / implementation の
  両モードから参照される配置。両モードの `base:` 行に同じ規約が反映されている
- **Req 4.4** — 既存の `${BASE_BRANCH} に直接 push しないこと` 行が `issue-watcher.sh` 内で 4 箇所
  すべて残存（line 2698 / 2748 / 2890 / 4590）。追加された `--base 省略禁止` 文は補強として並置
- **Req 5.1** — `.github/workflows/issue-to-pr.yml:188-200`（impl-resume）と 250-263（initial）
  の双方に「PR の base ブランチ（必ず明示）」節を追加し、`--base ${{ env.BASE_BRANCH }}` 指示を
  Step 2 / 制約節と合わせて 3 箇所以上に併記
- **Req 5.2** — Local Watcher 経路と Actions 経路で同一の規約（PjM agent definition）を共有し、
  かつ両経路の prompt に同じ表現で base 明示指示が入る
- **Req 5.3** — Watcher の design / Stage C、Actions の impl-resume / initial(design+impl 兼用) の
  すべてに base 明示節が追加されている（4 箇所すべて grep で確認）
- **NFR 1.1** — `${BASE_BRANCH:-main}` チェーン未変更（line 75）
- **NFR 1.2** — env var 名（`BASE_BRANCH` / `IDD_CLAUDE_BASE_BRANCH`）、既存ラベル名、
  exit code 意味のいずれも変更なし
- **NFR 2.1** — PjM の `--base` 指定値 / 作成された `baseRefName` / 一致可否のいずれかを
  PR 本文・PR コメント・Issue コメントから観察可能とする運用が `project-manager.md` と
  watcher prompt の双方で明文化
- **NFR 2.2** — 不整合検出時の自動修正 / 失敗エスカレ手順が `project-manager.md` の検証節に
  1 セクションに集約
- **NFR 3.1** — README の「PR base の明示と検証（Issue #96）」サブ節と
  `project-manager.md` の「PR の base ブランチ解決」共通節が同じ規約を整合的に記述

## Findings

なし

## Summary

`requirements.md` の全 numeric AC（1.1-1.5 / 2.1-2.4 / 3.1-3.3 / 4.1-4.4 / 5.1-5.3 / NFR 1.1-1.2 /
NFR 2.1-2.2 / NFR 3.1）について、watcher / Actions / project-manager.md / README の各成果物で
観測可能な実装裏付けを確認。後方互換性（`BASE_BRANCH:-main` の既定チェーン、否定形制約の維持、
env var 名・ラベル名・exit code 意味の不変）も保たれている。CLAUDE.md「テスト規約」の手動スモーク
テスト＋静的解析方針に従い、impl-notes で 4 件のスモークテスト結果（`develop` / `impl-resume` /
`main` / 空値ガード）と shellcheck / actionlint クリーンを Developer が記録済み。境界逸脱は無し。

RESULT: approve
