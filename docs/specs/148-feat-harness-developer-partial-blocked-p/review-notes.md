# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-7 timestamp=2026-05-22T15:25:00Z -->

## Reviewed Scope

- Branch: claude/issue-148-impl-feat-harness-developer-partial-blocked-p
- HEAD commit: 01bba4a7c5a2978c473a18a835a7f389298b3266
- Compared to: main..HEAD
- 差分規模: 19 files changed, 1367 insertions(+), 8 deletions(-)
- 主要変更: `local-watcher/bin/issue-watcher.sh` に 4 helper 関数 + 5 箇所の gate 挿入 /
  developer.md・reviewer.md（self-hosting + repo-template の 4 ファイル）への prompt 追記 /
  README に Migration Notes 追加 / spec 配下に 8 fixture + 3 smoke スクリプト
- Feature Flag Protocol: CLAUDE.md に `## Feature Flag Protocol` 節の `**採否**: opt-in` 宣言なし
  → opt-out として解釈し、flag 観点の細目チェックは適用せず通常 3 カテゴリで判定

## Verified Requirements

- **1.1** (`partial_blocked` 定義) — `.claude/agents/developer.md` / `repo-template/.claude/agents/developer.md`
  の「# 出力契約（impl-notes.md 末尾の STATUS 行）」節で定義。`detect_partial_status` fixture
  `status-partial-blocked.md` で動作確認（test-detect.sh case 2 pass）
- **1.2** (`partial_overrun` 定義) — 同上の節 + fixture `status-partial-overrun.md`（test-detect.sh case 3 pass）
- **1.3** (`complete` 互換改変なし) — `detect_partial_status` の status 行不在時 return 1 / ファイル
  不在 return 2 を `handle_partial_status` が共に continue 扱い（test-detect.sh case 4, 5 /
  test-handle-partial.sh case 1, 2 pass）。NFR 1.1 / 1.4 を構造的に保証
- **1.4** (`partial_blocked` の halt 理由 + 残タスク出力) — developer.md「partial 報告時の追加出力（必須）」節で
  `## Partial Halt Reason` / `## Pending Tasks` の 2 セクション必須化
- **1.5** (`partial_overrun` の commit 範囲 + 残タスク出力) — 同上 + `build_partial_escalation_comment`
  が `git log --oneline ${BASE_BRANCH}..HEAD` で commit 一覧を出力（test-build-comment.sh case 1 pass）
- **2.1** (turn budget 残 10 未満で `partial_overrun` 自己判断) — developer.md「自己判断による partial の
  報告条件」節で `turn budget 残量が 10 turn 未満` + 安全 commit boundary 停止を明記
- **2.2** (外部依存で `partial_blocked` 自己判断) — 同節で「未 merge の依存 Issue / 設計矛盾 / 環境不備」
  の 3 種を例示
- **2.3** (partial は failure ではない旨) — developer.md「partial は failure ではない（重要）」段落で
  「意図的なエスカレーション」「疑似 complete 禁止」を明記
- **2.4** (`partial_overrun` 時は安全 commit 可能範囲で停止) — 同 2.1 と同節で「直前の安全な commit
  boundary で停止」を明記
- **3.1** (`partial_blocked` 検出で Reviewer skip) — `handle_partial_status` return 10 →
  `run_impl_pipeline` の 5 箇所すべての gate 挿入点で `case 10) return 0` → Reviewer 起動分岐に
  到達しない（issue-watcher.sh L8411 / L8449 / L8554 / L8666 / L8772、test-handle-partial.sh case 3 pass）
- **3.2** (`partial_overrun` 検出で Reviewer skip) — 同上（test-handle-partial.sh case 4 pass）
- **3.3** (`partial_blocked` で `needs-decisions` 付与) — `mark_issue_needs_decisions` の `gh issue edit
  --add-label needs-decisions`（test-handle-partial.sh case 3 で `--add-label needs-decisions` /
  `--remove-label claude-claimed` / `--remove-label claude-picked-up` を gh.log で検証）
- **3.4** (`partial_overrun` で `needs-decisions` 付与) — 同上（test-handle-partial.sh case 4）
- **3.5** (partial 検出時に local commit を破棄せず remote push) — gate 挿入位置はすべて
  `verify_pushed_or_retry` の **後**（既存の `echo "✅ Stage A 完了"` の直後）。partial 検出時点で
  既に push 済の commit はそのまま remote に残る。`handle_partial_status` は branch / commit を
  一切触らない設計
- **3.6** (partial 検出時にエスカレーションコメント 1 件投稿) — `mark_issue_needs_decisions` の
  `gh issue comment` 1 回呼出（test-handle-partial.sh case 3, 4 で `issue comment 148` を検証）
- **4.1** (コメントに halt 理由) — `build_partial_escalation_comment` の `## Halt 理由` セクションで
  impl-notes.md `## Partial Halt Reason` を awk 抽出（test-build-comment.sh case 1 で fixture
  「依存 Issue #999 が未 merge」検証）
- **4.2** (コメントに commit 一覧 + branch 名) — `## Push 済み commit 一覧`（git log --oneline）+
  `### 検知情報` の branch 行（test-build-comment.sh case 1 で「対象 branch」と「#148」を検証）
- **4.3** (コメントに残タスク一覧) — `## 残タスク一覧`（impl-notes.md `## Pending Tasks` 優先、
  fallback で tasks.md の `- [ ]\\*?` 行を grep）（test-build-comment.sh case 3 で fallback 経路を検証）
- **4.4** (コメントに推奨アクション選択肢) — `## 推奨アクション` 固定リスト 3 種
  （test-build-comment.sh case 1 で「依存 Issue を先に進める」「Issue を分割する」「手動で続行する」
  全て検証）
- **4.5** (コメントに status code 識別固定文字列) — 本文 **先頭** に `<!-- idd-claude:partial-status:${status_code} -->`
  HTML コメントを heredoc で配置（test-build-comment.sh case 1, 2 で先頭行 first line 等価検証）
- **5.1** (needs-decisions 中は Developer 自動起動なし) — 既存 dispatcher の除外フィルタを
  そのまま再利用（新規変更ゼロ）。本機能は副作用としてラベルを付けるだけで、dispatcher の
  pickup 判定ロジックには触らない
- **5.2** (needs-decisions 中は Reviewer 自動起動なし) — 同上（Reviewer は Slot Runner 内で起動 =
  needs-decisions 付き Issue は Slot に入らない既存挙動を再利用）
- **5.3** (needs-decisions 除去後は通常 pickup) — 同上の inverse（既存挙動再利用）
- **NFR 1.1** (`complete` の出力フォーマット破壊なし) — `detect_partial_status` の status 行不在 =
  return 1 → `handle_partial_status` return 0 → gate 構造で既存挙動完全保持
  （test-handle-partial.sh case 1, 2 で gh API 呼出ゼロ + return 0 を検証）
- **NFR 1.2** (既存 env var 名の意味改変なし) — 新規 env var ゼロ（diff および README で確認）。
  `REPO` / `REPO_DIR` / `BASE_BRANCH` / `DEV_MODEL` / `SPEC_DIR_REL` / `LOG` 等の参照は read のみ
- **NFR 1.3** (既存ラベル遷移契約の意味改変なし) — `LABEL_NEEDS_DECISIONS` 既存変数のみ使用
  （L62）。`LABEL_FAILED` (`claude-failed`) は付与しない（`mark_issue_needs_decisions` の規約 /
  test-handle-partial.sh case 3, 4 で `--add-label claude-failed` が gh.log に出ないことを間接検証）
- **NFR 1.4** (`complete` 従来通り = 既存挙動と同一) — 既存 stage-a-verify gate / Stage B 起動経路は
  本機能で変更されない（diff で issue-watcher.sh の既存 echo / verify_pushed_or_retry 周辺は
  unchanged）。partial gate が status 行不在 / complete で return 0 を返すと既存挙動に到達
- **NFR 2.1** (partial 検出を grep 可能ログで記録) — `handle_partial_status` の
  `[$(date)] [$REPO] partial-status: detected issue=#... status=... branch=...` ログを
  `$LOG` および標準出力に `tee -a` で出力（test-handle-partial.sh case 6 で
  `partial-status: detected issue=#148 status=partial_blocked branch=...` を grep 検証）
- **NFR 2.2** (コメントに本機能由来識別固定文字列) — Req 4.5 と同一実装の
  `<!-- idd-claude:partial-status:... -->` HTML コメント本文先頭（test-build-comment.sh）
- **NFR 3.1** (不正 status code は `claude-failed` + Reviewer skip) — `handle_partial_status` の
  `*)` 分岐で `mark_issue_failed` 実行 + return 1（test-handle-partial.sh case 5 で
  `--add-label claude-failed` を gh.log で検証 + `needs-decisions` 未付与を間接検証）
- **NFR 3.2** (parse 失敗は既存失敗時挙動と互換) — `detect_partial_status` の rc=2 (ファイル不在) /
  rc=1 (行不在) は `handle_partial_status` で continue 扱い（既存挙動と差分なし /
  test-detect.sh case 4, 5）

### Boundary 確認

tasks.md の `_Boundary:_` で許可されたコンポーネントの差分のみであることを `git diff --stat` で確認:

- `local-watcher/bin/issue-watcher.sh`（Task 3-7 で許可）
- `.claude/agents/developer.md` + `repo-template/.claude/agents/developer.md`（Task 1）
- `.claude/agents/reviewer.md` + `repo-template/.claude/agents/reviewer.md`（Task 2）
- `README.md`（Task 8）
- `docs/specs/148-*/`（impl-notes.md, tasks.md, test fixtures, test scripts）

未許可コンポーネントへの差分は検出されず。boundary 逸脱なし。

### Feature Flag Protocol 採否確認

`CLAUDE.md` には `## Feature Flag Protocol` 節の `**採否**:` 行が存在しない（リポジトリ自身は
opt-in を宣言していない）。よって本判定では flag 観点の細目（旧パス温存 / if(flag) 分岐 /
flag-off path mutation 等）は **適用せず**、通常の 3 カテゴリ（AC 未カバー / missing test /
boundary 逸脱）のみで判定（Req 4.1, 4.2 / NFR 1.1 準拠）。

### スモークテスト再実行結果（reviewer 側で再走）

| スクリプト | アサート件数 | 結果 |
|---|---|---|
| `test-detect.sh` | 8 | 8 pass / 0 fail |
| `test-build-comment.sh` | 15 | 15 pass / 0 fail |
| `test-handle-partial.sh` | 16 | 16 pass / 0 fail |
| `shellcheck -S warning local-watcher/bin/issue-watcher.sh` | — | 警告 0 件（clean） |

合計 39 件のアサーション全て pass。Developer 自己申告と一致。

## Findings

なし

## Summary

Issue #148 の Developer 出力契約拡張（`partial_blocked` / `partial_overrun` 1st-class シグナル）
の実装は、requirements.md の Req 1〜5 / NFR 1〜3 すべての AC を観測可能な実装 + smoke test +
prompt 文言で漏れなくカバーしており、tasks.md の boundary 内に変更が収まっている。
39 件の smoke assertion 全 pass、shellcheck warning level クリーン、status 行不在 / complete
の場合に gh API 呼出ゼロ = 既存挙動と外形等価であることも確認済み。

RESULT: approve
