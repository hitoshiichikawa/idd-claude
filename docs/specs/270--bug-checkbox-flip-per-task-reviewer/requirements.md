# Requirements Document

## Introduction

per-task ループ実行中、ある親タスク（子タスクを内包するタスク）配下の全子タスクの実装と
Reviewer 通過が完了したあと、watcher は親タスクの完了マーク（`tasks.md` 上で
`- [ ] 4.` → `- [x] 4.` の checkbox flip のみ）を独立コミット（`docs(tasks): mark <id> as done`）
として積む。続けて per-task ループはこの親タスクに対しても `run_per_task_reviewer` を起動する
が、対象 diff range には `tasks.md` の 1 行 checkbox flip しか含まれず、Reviewer エージェントは
レビュー観点上の指摘事項が無いと判断して `review-notes.md` をディスクに書き出さない
（chat に `RESULT: approve` を出すのみで `editFileCount=0`）。結果として `parse_review_result`
が `review-notes.md` 不在で失敗（rc=2 / `parse-failed`）し、watcher は本来 approve 相当であった
このサイクルを `per-task-reviewer-error` カテゴリで `claude-failed` 化してしまう。

親タスクの完了マーク commit には対応する `_Requirements:_` 由来の実装差分がそもそも存在せず
（実装も Reviewer 判定も子タスク側で完了済み）、Reviewer 起動自体が無意味であるため、
watcher 側でこの状況を検出して Reviewer 起動をスキップし、approve 扱いで per-task ループを
継続させる。LLM 呼び出し削減によるトークン節約と実行時間短縮も副次的に得られる。

## Requirements

### Requirement 1: 親タスク + checkbox-only diff の Reviewer 起動スキップ

**Objective:** As an idd-claude 運用者, I want per-task ループが親タスク完了マーク commit に対して Reviewer 起動を自動でスキップする, so that 子タスクで既にレビュー済みの内容に対する無意味な Reviewer 起動と、それに伴う `parse-failed` 由来の `claude-failed` 化を防げる

#### Acceptance Criteria

1. When per-task ループが次に処理する task が「子タスクを 1 件以上持つ親タスク」であり、かつ当該 task の diff range に含まれる変更ファイルが `tasks.md` のみである, the per-task Loop shall `run_per_task_reviewer` を起動せずに当該 task の Reviewer フェーズをスキップする
2. When 上記スキップ条件が成立, the per-task Loop shall 当該 task の Reviewer 結果を approve 扱い（後続のディスパッチャ分岐で `rev_rc=0` 相当）として後続処理を継続する
3. When 上記スキップ条件が成立, the per-task Loop shall `review-notes.md` の不在 / 空の状態を理由に `claude-failed` を付与しない
4. When 上記スキップが発生, the per-task Loop shall 当該 task のスキップ発生を識別可能な単一行ログを `$LOG` に出力し、ログ行には task ID とスキップ理由（親タスクかつ checkbox-only diff である旨）が含まれる
5. When スキップ後に後続 task（兄弟タスク / 後続親タスク）が pending として残っている, the per-task Loop shall 通常の pending 順序に従って後続 task の処理を継続する
6. When スキップ後に後続 task が存在せず per-task ループが完走した, the watcher shall 既存の Stage B Reviewer / PR 作成等の後続フェーズに通常通り遷移する

### Requirement 2: 「親タスク」の判定方法

**Objective:** As an idd-claude 運用者, I want スキップ対象を機械的・決定論的に判定する, so that 通常タスクや子タスクへの誤適用を起こさず、既存の per-task Reviewer 動作との互換性を保てる

#### Acceptance Criteria

1. The per-task Loop shall 「親タスク」を「`tasks.md` 上で当該 task ID を prefix とする子タスク（例: 親 `4` に対する `4.1`, `4.2`, `4.1.1` 等）が `tasks.md` の checkbox 行として 1 件以上存在する task」と定義する
2. When 判定対象 task ID に対応する子タスクが `tasks.md` 上に 1 件も存在しない, the per-task Loop shall 当該 task を「子を持たない通常タスク」として扱い、Requirement 1 のスキップ対象外とする
3. When 判定対象 task ID 自体が numeric 階層の最下層（例: `1.2`, `2.3.1` のように更に下位を持たない ID）, the per-task Loop shall 当該 task を Requirement 1 のスキップ対象外とする
4. The per-task Loop shall 子タスクの完了 / 未完了状態（`- [x]` か `- [ ]` か）に関わらず、子タスクの存在のみで親タスク判定を成立させる
5. The per-task Loop shall deferrable 印（`- [ ]*`）の子タスクも子タスク存在判定の対象に含める

### Requirement 3: 「tasks.md only diff」の判定方法

**Objective:** As an idd-claude 運用者, I want 「diff が tasks.md の checkbox flip のみ」であることを決定論的に検証する, so that 親タスクであっても tasks.md 以外の実装差分が混在するケースで Reviewer 起動が誤ってスキップされない

#### Acceptance Criteria

1. The per-task Loop shall 当該 task の diff range（`pt_resolve_diff_range` が返す `range_start..range_end`）に含まれる **変更ファイル集合**を取得し、その集合が `tasks.md`（spec ディレクトリ配下の単一ファイル）のみで構成されることを Requirement 1 のスキップ成立条件の必要条件とする
2. If diff range に `tasks.md` 以外のファイル（実装ファイル / テストファイル / 他の spec ファイル等）が 1 件でも含まれる, the per-task Loop shall Requirement 1 のスキップを行わず、従来通り Reviewer を起動する
3. If diff range の解決自体が失敗した（`pt_resolve_diff_range` が rc!=0）, the per-task Loop shall Requirement 1 のスキップ判定を行わず、既存の diff-range-resolve-failed 経路に従って処理する
4. The per-task Loop shall `tasks.md` 内の変更が当該 task ID の checkbox flip（`- [ ]` → `- [x]`）のみで構成されることを Requirement 1 のスキップ成立条件として要求する
5. If `tasks.md` 内の変更が当該 task ID の checkbox flip 以外の編集（他 task の checkbox 編集、`_Requirements:_` 行の編集、新規行追加、コメント編集等）を含む, the per-task Loop shall Requirement 1 のスキップを行わず、従来通り Reviewer を起動する

### Requirement 4: 回帰互換性

**Objective:** As an idd-claude 運用者, I want 本変更が既存の per-task Reviewer 動作を破壊しない, so that 既稼働の自動開発パイプライン（既存 spec の per-task ループ実行）に regression が発生しない

#### Acceptance Criteria

1. When 判定対象 task が子タスク（`1.1`, `2.3.1` 等の階層下位 ID で、自身は子タスクを持たない）, the per-task Loop shall 従来通り `run_per_task_reviewer` を起動する
2. When 判定対象 task が子タスクを持たない最上位 task（例: 単独タスク `5.` で配下に `5.1` 等が存在しない）, the per-task Loop shall 従来通り `run_per_task_reviewer` を起動する
3. When 判定対象 task が親タスクであるが diff range に `tasks.md` 以外の変更を含む, the per-task Loop shall 従来通り `run_per_task_reviewer` を起動する
4. When 既存の per-task Reviewer の reject → Implementer 再起動 → Reviewer round=2 / Debugger Gate → Reviewer round=3 のループに到達するケース, the per-task Loop shall 本変更導入前と同一の制御フローおよび戻り値分岐を維持する
5. The per-task Loop shall 本変更導入前から成功していた既存 spec の per-task ループ実行において、ループ完走後の最終状態（claude-claimed → 完了ラベル遷移 / PR 作成）が本変更導入前と等価であることを保証する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The per-task Loop shall 本変更を有効化するための追加の環境変数 opt-in を要求せず、既定で Requirement 1 のスキップ判定を有効として動作する
2. The per-task Loop shall 本変更を含まない過去の watcher バージョンが書き出した進捗（`- [x]` 済み tasks.md、既存 marker commit）と互換に動作する（既存 spec の resume 実行で破綻しない）
3. The per-task Loop shall `tasks.md` が不在 / 当該 task ID の checkbox 行が存在しない等の異常系では Requirement 1 のスキップ判定を行わず、既存の fail-safe 経路（`pt_check_task_completed` rc=2 経路と同等の保守的扱い）に倒す

### NFR 2: 観測可能性

1. The per-task Loop shall Requirement 1 のスキップ発生時に、`per-task: task=<id> reviewer skipped reason=parent-task-checkbox-only-diff` の形式に相当する 1 行ログを `$LOG` に出力し、運用者が `grep reviewer skipped` で件数把握可能な状態にする
2. The per-task Loop shall スキップ判定の根拠（子タスク存在検出 / diff range の変更ファイル集合 / tasks.md 内変更行の判定結果）を、デバッグ時に追跡可能な粒度で `$LOG` に残す（最低でも task ID と判定経路の識別子を含む）
3. The per-task Loop shall スキップ判定が成立しなかった場合（親タスクだが diff に他ファイルを含む等）に、判定をスキップせず通常経路に進んだ旨を識別する追加ログを **新規には出さない**（既存ログ量を増やさない後方互換）

### NFR 3: 性能

1. The per-task Loop shall Requirement 1 のスキップ判定（子タスク存在検出 + diff range 変更ファイル集合取得 + tasks.md 内変更行内容判定）を、対象 task 1 件あたり既存の Reviewer 起動 1 回（通常数十秒〜数分）と比較して無視可能な追加レイテンシ（目安として 1 秒以内）で完了させる
2. When Requirement 1 のスキップが成立, the per-task Loop shall Reviewer 用の `claude --print` プロセス起動を抑制し、対応する LLM 呼び出しトークンと実行時間を消費しない

## Out of Scope

- `run_per_task_reviewer` 関数本体（Reviewer が `review-notes.md` を書き出すか否かの挙動）のリトライ / 再生成ロジック追加。本 spec は Reviewer 起動自体を抑止する設計に倒し、Reviewer の出力不安定性は別 Issue で扱う
- Reviewer エージェント側の prompt 改修（`review-notes.md` を必ず書き出させるための prompt 強化）。本 spec の対象外
- Stage B Reviewer（全体 Reviewer / PR 直前のレビュー）のスキップ判定。本 spec は per-task ループ内の per-task Reviewer のみを対象とする
- 親タスク以外の文脈で diff が `tasks.md` checkbox flip のみになるケース（人間が手動で進捗マーカーだけ進めた等）への一般化。本 spec は per-task ループが自動生成する親タスク完了マーク commit のみを対象とする
- `tasks-generation.md` / `design-review-gate.md` 等の Architect 向け規約改訂。本変更は watcher 側のランタイム挙動のみで完結する
- 既存 spec の `tasks.md` / `review-notes.md` への遡及的修正（retrofit）

## Open Questions

- なし（Issue 本文・既存実装の親タスク判定ヘルパー `pt_extract_pending_tasks` / `pt_check_task_completed`・親タスク完了マーク commit 規約 `docs(tasks): mark <id> as done` から実装可能性が確認できているため、本フェーズで人間判断を要する曖昧点はない）
