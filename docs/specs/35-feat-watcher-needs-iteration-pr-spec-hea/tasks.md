# Implementation Plan

> 順序: 1 → 2 → 3 → 4 → 5 → 6 を直列で進める。タスク 4・5 は読み取り専用 docs 変更なので
> （P）並列可。タスク 3 の watcher 本体実装はタスク 1（design template）が先行している必要がある
> （`pi_select_template` がファイル存在を要求するため）。

- [ ] 1. 設計 PR 用 iteration template の新設
- [ ] 1.1 `local-watcher/bin/iteration-prompt-design.tmpl` を新規作成
  - design.md「Components and Interfaces / Template Layer / Design Iteration Template」の
    Template Skeleton と Responsibilities & Constraints に従う
  - Architect 役割を inline 展開（外部 Read 参照しない）
  - 編集許容スコープを `docs/specs/<N>-<slug>/` 配下のみと明記し、scope 外編集は commit せず
    返信で別 Issue 化を推奨させる
  - 自己レビュー指示として `.claude/rules/design-review-gate.md` の Mechanical Checks を
    最大 2 パスで実行する旨を含める
  - 共通禁止事項（force push / main 直 push / レビュースレッドの resolve・unresolve /
    --resume・--continue・--session-id）を impl 用 template と同一基準で記述
  - spec 書き換え許容（impl 用 template の「requirements.md / design.md / tasks.md 書き換え禁止」
    条項を **持たない**）
  - awk 変数注入を impl 用 template と互換に保つため、プレースホルダ `{{REPO}}` `{{PR_NUMBER}}`
    `{{PR_TITLE}}` `{{PR_URL}}` `{{HEAD_REF}}` `{{BASE_REF}}` `{{ROUND}}` `{{MAX_ROUNDS}}`
    `{{ISSUE_NUMBER}}` `{{SPEC_DIR}}` `{{LINE_COMMENTS_JSON}}` `{{GENERAL_COMMENTS_JSON}}`
    `{{PR_DIFF}}` `{{REQUIREMENTS_MD}}` を採用する
  - commit メッセージは Conventional Commits 一般遵守、`docs(specs):` scope を推奨と明記
  - _Requirements: 2.1, 2.3, 2.4, 2.5, 2.6, 2.7_

- [ ] 2. install.sh / setup.sh の冪等配置動作確認
- [ ] 2.1 `install.sh` の `copy_glob_to_homebin "*.tmpl"` 経路で `iteration-prompt-design.tmpl` が
       自動配置されることを `--dry-run --local` で検証
  - 既存ロジック（`copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"`）は変更
    不要。`iteration-prompt-design.tmpl` をタスク 1 で配置すれば NEW として列挙される想定
  - `install.sh` 冒頭コメント / もしくは README 側に「local-watcher/bin/*.tmpl は自動配置される」
    旨を明示（既に書かれている場合は更新不要）
  - `setup.sh` は `install.sh` を `exec` するだけのため変更不要、整合性のみ確認
  - 冪等性: 同一内容なら SKIP、差分時のみ OVERWRITE になることを確認（NFR 2.1）
  - _Requirements: 2.2_
  - _Depends: 1.1_

- [ ] 3. issue-watcher.sh への種別判定 + template 選択 + ラベル遷移分岐の追加
- [ ] 3.1 Config ブロックの拡張（`# ─── PR Iteration Processor 設定 (#26) ───` 節）
  - `PR_ITERATION_HEAD_PATTERN` の既定値を `^claude/` から `^claude/issue-[0-9]+-impl-` に変更
    （NFR 4.2 で override 経路は維持）
  - `PR_ITERATION_DESIGN_ENABLED="${PR_ITERATION_DESIGN_ENABLED:-false}"` を追加
  - `PR_ITERATION_DESIGN_HEAD_PATTERN="${PR_ITERATION_DESIGN_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"`
    を追加
  - `ITERATION_TEMPLATE_DESIGN="${ITERATION_TEMPLATE_DESIGN:-$HOME/bin/iteration-prompt-design.tmpl}"`
    を追加
  - 前提ツールチェック節（L156〜L162 付近）に「`PR_ITERATION_ENABLED=true` かつ
    `PR_ITERATION_DESIGN_ENABLED=true` のとき `iteration-prompt-design.tmpl` 必須」を追加
  - _Requirements: 4.1, 4.2, 4.3, 4.6, NFR 4.1, NFR 4.2_
- [ ] 3.2 `pi_classify_pr_kind` / `pi_select_template` / `pi_finalize_labels_design` の新設
  - `pi_classify_pr_kind <head_ref>` — design.md の優先順序（ambiguous → design+enabled →
    design+disabled=none → impl → none）で 4 値を stdout に返す
  - `pi_select_template <kind>` — kind=design なら `$ITERATION_TEMPLATE_DESIGN`、impl なら
    `$ITERATION_TEMPLATE` を返す。ファイル不在で non-zero return + WARN
  - `pi_finalize_labels_design <pr_number>` — `gh pr edit --remove-label needs-iteration
    --add-label awaiting-design-review` を 1 コマンドで原子的発行
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 3.1, 4.4_
- [ ] 3.3 `pi_run_iteration` を kind 引数で分岐するようリファクタ
  - `pi_classify_pr_kind` で kind 判定 → `none` / `ambiguous` は skip ログを出して return 3
  - `pi_select_template` で template path 取得（template 不在で WARN + return 1）
  - 成功時の `pi_finalize_labels` 呼び出しを kind に応じて `pi_finalize_labels_design` か既存
    `pi_finalize_labels` に分岐
  - `pi_escalate_to_failed` は kind 共通（既存のまま、Req 3.4）
  - 着手表明（`pi_post_processing_marker`）と round counter 読み取り（`pi_read_round_counter`）は
    kind 非依存で共有（Req 6.1, 6.5）
  - ログ書式に `kind=design|impl` を追加し、grep で集計可能にする
    （例: `pi_log "PR #${pr_number}: kind=${kind} round=${next_round}/${MAX} action=success"`、Req 6.3 / NFR 3.1）
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 6.1, 6.2, 6.3, 6.4, 6.5, NFR 1.2, NFR 2.2, NFR 3.1_
- [ ] 3.4 `pi_fetch_candidate_prs` の jq filter 拡張と `process_pr_iteration` のサマリ拡張
  - jq filter で head pattern 判定を「impl pattern OR (DESIGN_ENABLED=true AND design pattern)」
    に変更
  - `process_pr_iteration` のサイクル開始ログとサマリ行に design / impl 内訳を追加
    （NFR 3.2）
  - 既存除外フィルタ（fork / draft / claude-failed / needs-rebase）は不変（Req 1.5）
  - return 3 (skip) を集計するカウンタを追加し、サマリに含める
  - _Requirements: 1.5, 4.4, 4.5, 5.1, 5.2, NFR 3.1, NFR 3.2_

- [ ] 4. ドキュメント / エージェントルール更新 (P)
  - `repo-template/CLAUDE.md` のエージェント連携ルール節に「設計 PR iteration の挙動と、
    Architect / Developer エージェントの責務境界（実装 PR では spec 書き換え禁止 /
    設計 PR では `docs/specs/` 配下の書き換え許容）」を追記
  - `repo-template/.claude/agents/project-manager.md` の design-review モード本文に
    「設計 PR iteration（`needs-iteration`）は次サイクルで反復対応される」「1 PR = design or impl
    のどちらか（混在禁止）」を明示
  - _Requirements: 5.4, 5.7_
  - _Boundary: Documentation_

- [ ] 5. README.md への migration note + env var 表追加 (P)
  - `## PR Iteration Processor (#26)` 節に「設計 PR 拡張 (#35)」サブ節を追加
  - env var 表に `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_DESIGN_HEAD_PATTERN` を追加し、
    `PR_ITERATION_HEAD_PATTERN` の既定値表記を `^claude/issue-[0-9]+-impl-` に更新
  - Migration Note ブロックに 3 項目追加:
    - `PR_ITERATION_HEAD_PATTERN` 既定値変更（旧 `^claude/` → 新 `^claude/issue-[0-9]+-impl-`）
    - 旧来 branch 命名（`claude/<slug>` 等）の救済方法: cron に
      `PR_ITERATION_HEAD_PATTERN=^claude/` を追加して旧挙動に戻す
    - 設計 PR 対応の opt-in: cron に `PR_ITERATION_DESIGN_ENABLED=true` を追加
  - 「1 PR = design or impl のどちらか（混在禁止）」を独立した節として記述
  - Phase A との住み分け表に design / impl の行を追記（任意）
  - _Requirements: 5.3, 5.4, 5.5, 5.6_
  - _Boundary: Documentation_

- [ ] 6. 静的解析 + DoD スモークテスト 4 シナリオの実施と Test plan 記録
  - `shellcheck local-watcher/bin/issue-watcher.sh install.sh setup.sh` — 警告ゼロ
  - `actionlint .github/workflows/*.yml` — workflow に意図しない参照変更なし
  - `bash -n local-watcher/bin/issue-watcher.sh` — 構文エラーなし
  - cron-like 最小 PATH での依存解決:
    `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git timeout'`
  - 候補 PR ゼロ状態での dry run 確認:
    `PR_ITERATION_ENABLED=true PR_ITERATION_DESIGN_ENABLED=true REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh`
  - DoD 4 シナリオ（独立に実施、PR 本文「Test plan」セクションに結果記録）:
    - **Req 7.1 設計 PR 成功**: `claude/issue-<N>-design-<slug>` に `needs-iteration` 付与 →
      成功時 `awaiting-design-review` 遷移
    - **Req 7.2 設計 PR 上限到達**: 同 PR を `MAX_ROUNDS` まで回す → `claude-failed` 昇格 +
      エスカレコメント
    - **Req 7.3 実装 PR リグレッション**: 既存 `claude/issue-<N>-impl-<slug>` に `needs-iteration`
      付与 → `#26` 導入時と同一の挙動（成功時 `ready-for-review`、上限時 `claude-failed`）
    - **Req 7.4 完全 opt-out**: `PR_ITERATION_DESIGN_ENABLED=false`（既定）かつ
      `PR_ITERATION_HEAD_PATTERN` を override しない既存設定で、設計 PR が起動せず impl PR の
      挙動 / ログ書式が `#26` 導入時と一致
  - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, NFR 1.1, NFR 1.2, NFR 1.3_

- [ ]* 7. （optional）design / impl 種別ログのサマリ集計テスト
  - watcher の cron ログから `grep 'pr-iteration:' | grep 'kind=design'` で起動・成功・失敗・
    上限超過の件数が集計可能であることを確認
  - 本タスクは grep 観点が NFR 3.1 / 3.2 を満たしている確認のための補助。スモークテスト
    （タスク 6）の副産物として実施可能
  - _Requirements: NFR 3.1, NFR 3.2_

---

## 自己レビュー（Architect 確認用）

### Mechanical Checks（Pass）

- **Requirements traceability**: requirements.md の全 numeric ID（1.1〜1.5, 2.1〜2.7, 3.1〜3.5,
  4.1〜4.6, 5.1〜5.7, 6.1〜6.5, 7.1〜7.5, NFR 1.1〜1.3, NFR 2.1〜2.2, NFR 3.1〜3.2, NFR 4.1〜4.2）
  がすべて design.md の Requirements Traceability 表で言及され、tasks.md の `_Requirements:_` で
  参照されている
- **File Structure Plan の充填**: 1 新規ファイル + 6 変更ファイルが具体パスで列挙済み（"TBD" なし）
- **orphan component なし**: design.md Components のすべて（Kind Classifier / Template Selector /
  Label Transitioner / Iteration Runner / Candidate Fetcher / Config Block / Design Iteration
  Template / README / CLAUDE.md / project-manager.md）が File Structure Plan の対応ファイルに紐付く

### 判断レビュー（Pass）

- **要件カバレッジ**: 全 numeric ID が具体的なコンポーネント・契約・フロー・運用判断のいずれかで
  裏打ち済み
- **アーキテクチャ準備**: Kind Classifier の 4 値分類ロジック / Iteration Runner の戻り値
  （0/1/2/3）/ Label Transitioner の原子的 add+remove が、Developer が実装手順で迷わない粒度で
  記述済み
- **実行可能性**: タスク 1（template 新設）→ 3（watcher 本体）の順序依存を `_Depends:_` で明示。
  4・5 は docs のみで（P）並列可
- **隠れた要件発明なし**: 「AC 2.6 の hard-enforce」「review-notes.md 連携」「commit 規約強制」
  は requirements.md「確認事項」に列挙されていた論点を、Architect 判断として明示的に「やらない」
  と確定している（要件を勝手に増やしていない）
