# Implementation Plan

- [ ] 1. Developer prompt に STATUS 行・partial 自己判断・後方互換規約を追記
  - `.claude/agents/developer.md` に「# 出力契約（impl-notes.md 末尾の STATUS 行）」
    セクションを新設し、`STATUS: complete` / `partial_blocked` / `partial_overrun` の
    出力フォーマットを明記
  - 同セクション配下に「partial 報告時の追加出力」（`## Partial Halt Reason` /
    `## Pending Tasks`）の必須出力規約を追加
  - 「自己判断による partial の報告条件」サブセクションで turn budget 残量 10 未満で
    `partial_overrun`、外部依存進行不能時に `partial_blocked` を報告する条件を明記
  - 「partial は failure ではない」段落でエスカレーション意図と「疑似 complete 禁止」を明示
  - 「既存『complete』との後方互換」段落で status 行不在 = complete fallback を明記
  - `repo-template/.claude/agents/developer.md` に **完全同一の追記内容** を同期反映
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 2.1, 2.2, 2.3, 2.4, NFR 1.1_

- [ ] 2. Reviewer prompt に partial 経路では起動されない旨を informational 追記
  - `.claude/agents/reviewer.md` に「## partial status との関係（informational）」段落を追加
  - 既存 3 カテゴリ判定基準（AC 未カバー / missing test / boundary 逸脱）は変更しない
  - `repo-template/.claude/agents/reviewer.md` に同一内容を同期反映
  - _Requirements: 3.1, 3.2, NFR 1.3_

- [ ] 3. orchestrator に `detect_partial_status` helper を追加
  - `local-watcher/bin/issue-watcher.sh` の Debugger Gate セクション
    （`detect_blocked_marker` 付近 / L6592 周辺）に新規 helper を追加
  - 関数規約: 引数 = impl-notes.md path、stdout = status code 値、return = 0/1/2
    （0 = STATUS 行検出、1 = STATUS 行不在、2 = ファイル不在）
  - 行頭固定 ERE `^STATUS: (.+)$` で grep、複数マッチ時は最終行採用、値は trim
  - list marker `- ` / blockquote `> ` / インデント prefix は検出対象外
  - 単体動作確認用に 8 種類の入力 fixture（complete / partial_blocked / partial_overrun /
    不在 / ファイル不在 / 不正値 / 複数行 / list marker 装飾）でスモークテスト
  - shellcheck をクリーンに保つ
  - _Requirements: 1.1, 1.2, 1.3, NFR 1.1, NFR 3.2_

- [ ] 4. orchestrator に `build_partial_escalation_comment` helper を追加
  - `local-watcher/bin/issue-watcher.sh` の `qa_build_escalation_comment` (L758) と
    同セクション帯に新規 helper を追加
  - 引数 4 つ: `<status_code> <impl_notes_path> <tasks_md_path> <branch>`
  - 本文先頭に識別 HTML コメント `<!-- idd-claude:partial-status:${STATUS_CODE} -->` を出力
  - impl-notes.md の `## Partial Halt Reason` セクションを抽出して「## Halt 理由」に転載
  - `git log --oneline ${BASE_BRANCH}..HEAD` の結果を「## Push 済み commit 一覧」に転載
  - 「## 残タスク一覧」は impl-notes.md `## Pending Tasks` セクションを優先抽出し、
    なければ tasks.md の `- [ ]` 行を grep してフォールバック
  - 「## 推奨アクション」は固定リスト（依存 Issue 先行 / Issue 分割 / 手動続行）
  - 「## 次の手順」で `needs-decisions` ラベル除去で次サイクル自動 pickup される旨を明記
  - footer に「本コメントは Partial Status Gate (#148) が自動投稿しました」を追加
  - shellcheck をクリーンに保つ
  - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, NFR 2.2_

- [ ] 5. orchestrator に `mark_issue_needs_decisions` helper を追加
  - `local-watcher/bin/issue-watcher.sh` の `mark_issue_failed` (L7858) 直後に
    新規 helper を追加
  - `gh issue edit` で `LABEL_CLAIMED` / `LABEL_PICKED` を除去 → `LABEL_NEEDS_DECISIONS`
    を付与（既存 `qa_handle_quota_exceeded` と同形式で 1 コマンドで原子的に発行）
  - `gh issue comment` で渡された本文を投稿
  - 失敗時は warn 吸収（best-effort）、return 0 always
  - `LABEL_FAILED` (`claude-failed`) は **付与しない**（NFR 1.3 / 既存ラベル併存禁止）
  - shellcheck をクリーンに保つ
  - _Requirements: 3.3, 3.4, 3.6, NFR 1.3_

- [ ] 6. orchestrator に `handle_partial_status` coordinator helper を追加
  - `local-watcher/bin/issue-watcher.sh` の `mark_issue_needs_decisions` 直後に
    coordinator 関数を追加
  - 引数なし、env var 経由で `NUMBER` / `BRANCH` / `REPO` / `REPO_DIR` / `SPEC_DIR_REL`
    / `LOG` / `BASE_BRANCH` を参照
  - return 値: 0 = continue / 10 = partial 検出済（呼出側は run_impl_pipeline から
    return 0） / 1 = 不正 status（mark_issue_failed 実行済）
  - 分岐: detect_partial_status の戻り値 (1/2) と stdout 値 (complete / partial_blocked /
    partial_overrun / 不正) に応じて continue / escalate / failed を選択
  - partial 検出時に grep 可能なログ行 `[$(date)] partial-status: detected issue=#... status=... branch=...`
    を `$LOG` および標準出力に出力（NFR 2.1）
  - 不正値時は `[$(date)] partial-status: invalid issue=#... status='...'` ログ + `mark_issue_failed`
  - shellcheck をクリーンに保つ
  - _Requirements: 1.3, 3.1, 3.2, 3.5, NFR 1.1, NFR 1.4, NFR 2.1, NFR 3.1, NFR 3.2_

- [ ] 7. `run_impl_pipeline` の Stage A 完了直後 5 箇所に gate を挿入
  - `local-watcher/bin/issue-watcher.sh` の `run_impl_pipeline` 内、以下 5 箇所に
    `handle_partial_status` 呼出を挿入（return 値で分岐）:
    - L8114 付近: per-task loop 完了後（`echo "✅ #$NUMBER: Stage A 完了（per-task loop）"`
      直後）
    - L8141 付近: 通常 Developer 完了後（`echo "✅ #$NUMBER: Stage A 完了"` 直後）
    - L8236 付近: Stage A' (BLOCKED 経路) 完了後（`echo "✅ #$NUMBER: Stage A' (BLOCKED 経路) 完了 ..."` 直後）
    - L8337 付近: Stage A' (Reviewer reject 差し戻し) 完了後（`echo "✅ #$NUMBER: Stage A' 完了"` 直後）
    - L8432 付近: Stage A'' (Debugger 経由) 完了後（`echo "✅ #$NUMBER: Stage A'' 完了"` 直後）
  - 各挿入点の挿入パターン（共通）:
    ```bash
    local _partial_rc=0
    handle_partial_status || _partial_rc=$?
    case "$_partial_rc" in
      0)  : ;;             # continue（既存フロー）
      10) return 0 ;;       # partial 検出: Reviewer skip + 正常終了
      *)  return 1 ;;       # 不正 status: mark_issue_failed 実行済
    esac
    ```
  - 挿入位置は stage-a-verify gate (`stage_a_verify_run`, L8268) の **前**
    （設計判断「gate 挿入位置」: partial → stage-a-verify の相対順序）
  - 既存の Stage A 完了 echo / verify_pushed_or_retry 呼出は **変更しない**
  - shellcheck をクリーンに保つ
  - _Requirements: 3.1, 3.2, 3.5, NFR 1.1, NFR 1.4_

- [ ] 8. README に Migration Notes (#148) を追記
  - `README.md` の既存 migration notes セクション（または「オプション機能一覧」末尾）に
    「Developer partial status codes (#148)」項目を追加
  - 記載内容:
    - 新規 status code `partial_blocked` / `partial_overrun` の意味
    - default-on（opt-in / opt-out env var なし）
    - 後方互換性（status 行不在 / `complete` は既存挙動と等価）
    - `needs-decisions` ラベル自動付与の挙動と人間運用フロー
    - 識別 HTML コメント `<!-- idd-claude:partial-status:... -->` で本機能由来 / 既存
      `needs-decisions` 由来（PM フェーズ情報不足 / Architect budget overflow 等）を区別する旨
    - **Actions 経路 (`IDD_CLAUDE_USE_ACTIONS=true`) では本機能は未実装** であり、
      local watcher 経路のみで動作する旨を明記（NFR 1.1 を Actions 経路でも構造的に保証）
  - 関連: `.claude/agents/developer.md` / `.claude/agents/reviewer.md` の追記内容への参照リンク
  - _Requirements: NFR 1.1, NFR 1.2, NFR 1.3_

- [ ]* 9. dogfooding E2E スモークテスト
  - 本 repo (idd-claude self-hosting) に test Issue を立て、Developer に意図的に
    `STATUS: partial_blocked` を出させて end-to-end の挙動を確認
  - 確認項目:
    - watcher ログに `partial-status: detected issue=#... status=partial_blocked` が記録される
    - Issue に `needs-decisions` ラベルが付き、`claude-claimed` / `claude-picked-up` が
      除去される
    - エスカレーションコメントが 1 件投稿され、識別 HTML コメント / Halt 理由 / commit 一覧 /
      残タスク / 推奨アクション / 次の手順がすべて含まれる
    - Reviewer が起動されていない（次 Stage に進んでいない）
    - 人間が `needs-decisions` を外すと次サイクルで通常 pickup される
  - 不正 status code（`STATUS: foo` 等）のケースで `claude-failed` 付与を確認
  - `STATUS: complete` 明示 / status 行不在 の両方で既存挙動（Reviewer 起動）と等価で
    あることを確認（NFR 1.1 / 1.4 のレグレッション確認）
  - スモークテストの実行結果を本 Issue にコメントで記録
  - _Requirements: NFR 1.1, NFR 1.4, NFR 2.1, NFR 2.2, NFR 3.1_
