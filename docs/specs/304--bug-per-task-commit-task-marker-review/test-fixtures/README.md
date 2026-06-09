# test-fixtures — Issue #304 回帰テスト

Issue #304（per-task ループの marker commit / Reviewer review range 整合性）で導入する
post-marker commit 検出 hook の挙動を、idd-codex #14 と同型の commit shape を持つ
一時 git repo fixture で検証する smoke script 群。

## 概要

per-task Implementer ループでは、各タスクの完了時に
`docs(tasks): mark <id> as done` marker commit を積み、watcher はその marker を
per-task Reviewer の review range の終端として利用する。Reviewer reject /
Debugger guidance 後に Implementer が修正 commit を旧 marker より後ろに残すと、
`pt_resolve_diff_range` の range_end が marker で止まり、修正 commit が
Reviewer の判定対象から漏れる（silent range truncation）。

本 fixture は以下を検証する:

- watcher 側に追加する `pt_detect_post_marker_commits` が marker..HEAD の
  post-marker commit を正しく列挙する
- `pt_handle_post_marker_commits` の `extend-range` / `fail-with-diagnostic` 両
  recovery mode が決定論的な rc / stdout / stderr を返す
- silent truncate が起きうるシナリオで、hook が無ければ commit が漏れる事実を
  明示的に assert し、hook 併用で検出できることを担保する

## 実行方法

```sh
bash docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/test-post-marker-detect.sh
```

`SMOKE_RESULT: pass` が出力されれば全 assertion が通っている。`SMOKE_RESULT: fail`
の場合、参照実装と本 fixture の参照実装ミラーが乖離している、または
post-marker 検出 hook の挙動が期待値からずれている。

shellcheck も合わせて実行することを推奨:

```sh
shellcheck docs/specs/304--bug-per-task-commit-task-marker-review/test-fixtures/test-post-marker-detect.sh
```

## 検証対象 case 一覧

| Case | シナリオ | 検証する関数 | 対応 Requirement |
|------|---------|--------------|------------------|
| case-1 | marker 後に commit 無し（既存挙動温存） | `pt_detect_post_marker_commits` rc=1 / stdout 空 | 5.2, NFR 1.3 |
| case-2 | marker + 修正 commit 2 件（idd-codex #14 同型） | `pt_detect_post_marker_commits` rc=0 / SHA list 出力 | 5.1, 5.2 |
| case-3 | `POST_MARKER_RECOVERY_MODE=fail-with-diagnostic` | `pt_handle_post_marker_commits` rc=5 / 範囲非出力。env 未設定 / 不正値も default 化されて rc=5 | 5.2, 2.2 |
| case-4 | `POST_MARKER_RECOVERY_MODE=extend-range` | `pt_handle_post_marker_commits` rc=0 / 新 range pair `<range_start>\t<HEAD>` 出力 | 5.2, 2.2 |
| case-5 | silent truncate 不許容（hook が無いと commit が漏れる証拠 + hook で検出できることの担保） | `pt_resolve_diff_range` の range_end が marker で止まり、post-marker commit が `range_start..range_end` の外に置かれることを assert + `pt_detect_post_marker_commits` で当該 commit を検出 | 5.3 |

## 参照実装ミラー方針

本 fixture は `pt_resolve_diff_range` / `pt_detect_post_marker_commits` /
`pt_handle_post_marker_commits` の **参照実装**を本 script 内に複製する形式を
取る（既存 `docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh`
と同形式）。これは:

- watcher 本体 (`local-watcher/bin/issue-watcher.sh`) を起動せずに smoke 単体で
  挙動を検証可能にする
- task 2〜4 の `issue-watcher.sh` 関数追加と本 fixture を **並行で書ける**
  （本 fixture を task 1 で先に書き、task 2〜4 で同期の取れた実装を入れる）

ためである。fixture と本体実装が乖離した場合、本 fixture は **本体実装側を
fixture に再同期する** ことを原則とする（既存 fixture と同じ方針）。

## 関連参照

- 要件: `../requirements.md`（Req 5.1〜5.3 が本 fixture の責務範囲）
- 設計: `../design.md`「Testing Strategy / Components and Interfaces」節
- 既存 fixture（同形式の先例）:
  `docs/specs/164-bug-watcher-per-task-reviewer-task-id-ma/test-pt-resolve.sh`
- 本体実装（task 2〜4 で追加予定）:
  `local-watcher/bin/issue-watcher.sh` の以下関数
  - `pt_detect_post_marker_commits`（`pt_resolve_diff_range` 直後）
  - `pt_handle_post_marker_commits`（`pt_detect_post_marker_commits` 直後）
  - `pt_mark_post_marker_commits_detected`（`pt_mark_diff_range_resolve_failed`
    と同セクション）
