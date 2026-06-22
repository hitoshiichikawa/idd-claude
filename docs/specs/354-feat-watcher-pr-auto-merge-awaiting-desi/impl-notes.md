# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `local-watcher/bin/modules/auto-merge.sh` (#352) を雛形にコピーし、`am_` → `amd_` /
  `AUTO_MERGE_` → `AUTO_MERGE_DESIGN_` / `auto-merge:` → `auto-merge-design:` の mechanical
  rename + design 用差分（ready-for-review 必須を削除、needs-iteration 除外を追加）で構築
- 重要な判断:
  - `amd_should_enable_for_pr` から `LABEL_READY` 必須チェックを削除（design PR に
    `ready-for-review` ラベルを付与しないため）
  - `LABEL_NEEDS_ITERATION` 除外を追加（Req 6.4 / 設計 PR iteration 中は merge 抑止）。
    server-side `gh pr list --search` 文字列にも `-label:"$LABEL_NEEDS_ITERATION"` を追加
  - head pattern による排他は `AUTO_MERGE_DESIGN_HEAD_PATTERN` (`^claude/issue-.*-design`)
    の client-side filter で impl PR と自然分離（Req 2.6, 6.7）。impl PR の
    `^claude/issue-.*-impl` head は本 pattern にマッチしないため二重防御として機能
  - tempfile prefix も `am-merge-stderr-` → `amd-merge-stderr-` に置換し、#352 との
    同時実行時にも一意性を保つ
- 残存課題: 本 task では module 単体の関数定義のみで、本体 Config / loader / call site への
  配線（task 2 / 3 / 4）が未完。`LABEL_NEEDS_ITERATION` は本体 `issue-watcher.sh` 側で
  既存定義済みであることを確認済み（line 73 で `LABEL_NEEDS_ITERATION="needs-iteration"`
  として定義されており、本 module 内では遅延束縛で参照可能）

### Task 2

- 採用方針: 既存 `─── Auto-Merge Processor 設定 (#352) ───` ブロック（line 232-250）の
  直後（PR Iteration ブロックの前）に `─── Design Auto-Merge Processor 設定 (#354) ───`
  ブロックを新規挿入。4 env (`AUTO_MERGE_DESIGN_ENABLED` / `_MAX_PRS` / `_GIT_TIMEOUT` /
  `_HEAD_PATTERN`) を `:-default` 形式で宣言し既定 OFF を保証
- 重要な判断:
  - `_HEAD_PATTERN` の既定値は `^claude/issue-.*-design`（#352 の `^claude/issue-.*-impl`
    と対称）。両者は env override 可能で互いに独立に倒せる
  - 既存 `AUTO_MERGE_*`（impl 用、line 232-250）の宣言を一切書き換えず append-only で配置
    （NFR 2.2 の env 名・既定値温存）
  - ブロック冒頭コメントに #352 と同形で「AND 二重 opt-in」「既定 OFF」「`=true` 厳密一致
    以外は OFF」「impl PR との非干渉」「`DESIGN_REVIEW_RELEASE_ENABLED` (#40) との独立共存」
    を明記。task 3 (cycle log 拡張) と task 4 (main loop 配線) が依存する文脈を Config
    ブロック側に集約することで grep 起点を一本化
- 残存課題: 本 task では Config 宣言のみで、`REQUIRED_MODULES` への
  `auto-merge-design.sh` 追加 (task 3) と cycle startup ログへの
  `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` 追加 (task 3) は未着手。
  main loop の `process_auto_merge_design` 呼び出し配線も task 4 で別途実施

### Task 3

- 採用方針: `REQUIRED_MODULES` 配列に `"auto-merge-design.sh"` を `"auto-merge.sh"`
  の直後に挿入し（#352 との対称配置 / NFR 6.2）、cycle startup ログ行に
  `auto-merge-design=${AUTO_MERGE_DESIGN_ENABLED}` を `auto-merge=` と `full-auto=`
  の間に append する 2 箇所の最小編集で task を完結（Req 9.4）
- 重要な判断:
  - REQUIRED_MODULES への挿入位置は `auto-merge.sh` 直後とした。loader 自身は遅延束縛で
    順序非依存だが、可読性 / 対称性 / #352 との grep 整合を優先（design.md の File
    Structure Plan 内 module 順序記述とも整合）
  - startup ログ位置は `auto-merge=...` と `full-auto=...` の間に挟む形を採用。impl 用 /
    design 用 / kill switch という機能順での並びを保ち、運用者の grep 観察を容易にする。
    既定値（unset 時）でも `auto-merge-design=false` が明示出力されることをスモークで確認
    （`env -u AUTO_MERGE_DESIGN_ENABLED ...` で `auto-merge-design=false` 出力を観測）
  - 本体の他 echo 文・他 env 既定値・他 loader entry は一切触らず diff を 4 行追加 / 2 行
    削除に局所化（NFR 2.1, 2.2, 2.3 / 後方互換）
- 残存課題: main loop への `process_auto_merge_design` 呼び出し配線が task 4 で未着手。
  REQUIRED_MODULES で関数定義の前方参照は解決済みのため、task 4 では本体 line 1014
  付近の `process_auto_merge || am_warn ...` 直後への 1 行追加で配線が完了する見込み

### Task 4

- 採用方針: `process_auto_merge || am_warn ...` (line 1024) の直後に
  `process_auto_merge_design || amd_warn ...` を 1 行追加し、impl Auto-Merge (#352) と
  対称配置で main loop に配線。順序は #352 直後 / Promote Pipeline 前を維持（Req 5.4 / 8.4）
- 重要な判断:
  - 配線箇所の直上 comment block (8 行) は #352 の comment block と並列構造で記述し、
    grep / 可読性を担保（AND 二重 opt-in 要件 / head pattern による非干渉 / #40 共存 /
    配置順序の根拠 を明示）
  - 既存 `process_auto_merge` 呼び出し行・他 processor 呼び出し順序は一切変更せず、
    diff を 10 行追加のみに局所化（NFR 2.3 後方互換）
  - shellcheck / bash -n / 既存 `auto-merge_test.sh` 56 件 PASS / dry-run smoke で
    `auto-merge-design=false` ログ出力到達 / `cd: /tmp/test-repo-354` で想定通り
    終了することを確認済み（task 3 で配線済の cycle startup ログが配線後も壊れない
    ことを兼ねて検証）
- 残存課題: 本 task で配線完了。task 5 で新規 fixture テスト
  (`auto-merge-design_test.sh`) を追加する際の参照点として、`process_auto_merge_design`
  が main loop の `process_auto_merge` 直後で確実に呼ばれることをスモークで確認済み
  （test fixture 設計上の前提として活用可能）

### Task 5

- 採用方針: 既存 `local-watcher/test/auto-merge_test.sh` (#352) を雛形にコピーし、
  `am_` → `amd_` / `AUTO_MERGE_` → `AUTO_MERGE_DESIGN_` / 抽出 module `auto-merge.sh`
  → `auto-merge-design.sh` の mechanical rename + design 用差分（`ready-for-review`
  必須テスト削除 / `needs-iteration` 除外テスト追加 / 全 fixture を `-design` head
  branch に書き換え / Case I を「impl PR → skip」に反転）で構築。61 件 PASS / 0 FAIL
- 重要な判断:
  - shellcheck SC2034 抑止: 既存 `auto-merge_test.sh` は file-level `disable=SC2034`
    のみで実際は SC2034 警告が exit 1 で残存（shellcheck 仕様で file-level disable は
    次行のみに効くため）。本 task では各代入直前に inline `# shellcheck disable=SC2034`
    を付与し、shellcheck クリーン（警告ゼロ）を達成。コメント本文に `=` を含む文字列
    （例: `disable=SC2034`）を書くと SC1072 で directive parse 失敗するため、文中の
    `=` は inline コード表記を避けて平文で記述
  - `build_pr_json` の labels_csv 引数: design 版では `ready-for-review` 必須要件が
    無いため、labels_csv に空文字列を渡してラベル無し fixture を作る形に変更。
    既存 helper の awk ベース parser は空文字 / 単一ラベルの両方に対応済み（既存
    実装のまま流用可能）
  - Case I の反転: 既存 `auto-merge_test.sh` の Case I「設計 PR → skip」を、
    design 版では「実装 PR (`-impl` pattern) → skip」に反転（Req 2.6 / 6.7 / 非干渉
    の二重防御を fixture でも検証）。head pattern による client-side filter で
    impl PR が排他されることを統合経路でも確認
  - exactly-once 検証: Case D で `gh pr merge.*--auto.*--squash.*--delete-branch.*-- 100`
    を正規表現で 1 回マッチさせる assert を追加し、Req 3.1 の `gh pr merge --auto
    --squash --delete-branch -- <N>` 形式（NFR 1.2 `--` 打ち切り）まで含めて検証
- 残存課題: なし。次 task (6) は別の既存テストファイル `pr_publish_commit_status_test.sh`
  に design head fixture を追加する作業で、本 task の auto-merge-design_test.sh とは
  別 module（pr-reviewer.sh）への fixture 追加であり独立。task 5 の成果物は task 6 /
  task 7 / task 8 の verify ブロックの回帰確認対象として活用される

### Task 6

- 採用方針: `local-watcher/test/pr_publish_commit_status_test.sh` の既存 Section 1–4
  （Issue #349 由来）は **一切変更せず**、Section 4 Case 4.E の直後に新規
  `Section 5: design PR head fixture (Issue #354 Req 4)` を append-only で追加。
  design.md「Design Decisions」(A) で確定済みの「`pr_publish_*` は head pattern を
  区別しない既存設計」を fixture でも明示するため、design PR らしい局所定数
  (`DESIGN_PR=200` / `DESIGN_SHA=40hex` / `DESIGN_TARGET_URL`) を Section 5 冒頭で
  宣言し、`pr_publish_codex_status` / `pr_publish_claude_status` を呼ぶ 6 ケース
  (5.A〜5.F) を追加（PASS=74 / FAIL=0、baseline 53 → +21 新規 assertion）
- 重要な判断:
  - **本 task はモジュール側コード変更なし**（Req 4.x はテスト追加・ドキュメント明示
    のみで satisfy）: design.md の Decision (A) で「`pr_fetch_candidate_prs` の head
    pattern 既定 `^claude/` は design PR を **既にカバー**しており、`pr_publish_*` の
    AND 二重 opt-in も head pattern を区別しない」ため、design PR head sha に対する
    publish 経路は #349 実装そのままで成立する。本 task は **既存挙動の事実を fixture
    で固定化する**回帰防止層を追加するだけで、`modules/pr-reviewer.sh` は読むだけ
    （編集禁止）。Section 5 冒頭コメントにこの設計上の含意を明記し、Reviewer / 将来の
    pattern 変更時の参照点を残した
  - **PR_REVIEWER_STATUS_CHECK_ENABLED 経由 OFF と FULL_AUTO_ENABLED 経由 OFF の差異**:
    Case 5.C（PR gate OFF）と Case 5.D（FULL_AUTO OFF）を独立 case として分離。
    既存仕様「suppression log は cycle あたり最大 1 行」「FULL_AUTO OFF suppression は
    #348 既存 kill switch ログに委譲」に従い、5.C のみ
    `count_logs "suppressed by PR_REVIEWER_STATUS_CHECK_ENABLED"` を 1 行 assert、
    5.D は suppression log なし（#348 既存ログに委譲）を inline コメントで明示。
    Req 4.6 の disabled 経路が **2 つの env 経由のいずれでも遮断される**ことを
    fixture レベルで保証
  - **Case 5.E で Req 4.5 補強**: 既存 Section 4 Case 4.A は target_url の blob URL
    先頭 (`https://github.com/owner/test-repo/blob/`) だけ検証しており、head sha が
    target_url に正しく伝播することを assert していなかった。Case 5.E では
    `assert_contains "target_url に DESIGN_SHA を含む" "$gh_line" "$DESIGN_SHA"` を
    blob URL prefix 検証と 2 段で重ね、Req 4.5（head sha が変わったら新 sha へ
    publish される）の既存挙動を従来より厳密に固定化（コード変更ゼロで既存挙動の
    追加保護のみ）
  - **fixture 定数の宣言場所**: 既存 `VALID_SHA` / `VALID_PR` 宣言箇所 (line 194
    付近) ではなく **Section 5 冒頭で局所宣言**することで、既存 Section 1–4 との
    境界を明確化（Section 1–4 は引数として VALID_PR / VALID_SHA を使い続け、
    Section 5 のみ DESIGN_PR / DESIGN_SHA を使う形）。これにより既存ケースの diff
    ゼロを保証
- 残存課題:
  - **shellcheck 既存 false-positive (本 task スコープ外 / 別 Issue 候補)**:
    `pr_publish_commit_status_test.sh` line 36 の Japanese コメントに含まれる
    「`shellcheck` からは未使用に見える」「本ファイル全体で `SC2034` を抑止する」が、
    shellcheck の directive parser に「`shellcheck`」キーワード + 直後の `SC2034` を
    未完成 directive として認識され、pre-existing で SC1072 / SC1073 が発火している
    （Issue #349 の commit 75873df 時点から存在）。CLAUDE.md「テスト・検証」節の
    shellcheck 対象パスは `local-watcher/bin/*.sh install.sh setup.sh
    .github/scripts/*.sh` であり `local-watcher/test/` 配下は含まれないため、本
    false-positive は CI / stage-a-verify gate を blocking しない。Section 1–4
    改変禁止制約下では本 task では修正不能。コメント本文中の語を別語に置換するだけ
    で解消するため、別 Issue で扱うのが妥当
  - **task 7 (README) / task 8 (全体 verify) への引き継ぎ**: 本 task で追加した
    21 新規 assertion が回帰確認対象として活用される。stage-a-verify gate の verify
    ブロック (tasks.md line 124–136) は `bash local-watcher/test/
    pr_publish_commit_status_test.sh` を含んでおり、PASS=74 / FAIL=0 が task 8 で
    そのまま reproduce される見込み

### Task 7

- 採用方針: 既存 `## Auto-Merge Processor (#352)` 節（line 2218 開始 / 約 100 行）を
  雛形に、命名置換（`auto-merge:` → `auto-merge-design:` / `AUTO_MERGE_` →
  `AUTO_MERGE_DESIGN_` / 「実装 PR」→「設計 PR」 / `^claude/issue-.*-impl` →
  `^claude/issue-.*-design`）と design 用差分（`ready-for-review` 必須削除 /
  `needs-iteration` 除外追加 / merge 後の `awaiting-design-review` 除去は #40 が担当
  と明示）を反映した新規節 `## Design Auto-Merge Processor (#354)` を、既存 #352 節の
  終端 `---` 区切り直後（line 2320 の `## PR Reviewer Processor (#261)` 直前）に append。
  オプション機能一覧表 (line 1346 付近) には #352 行 (line 1364) の直後に
  `AUTO_MERGE_DESIGN_ENABLED` 行を 7 カラム揃えで挿入
- 重要な判断:
  - **小節構造の完全対称化**: #352 節と同じ 9 小節（概要 / 対象 PR の条件 / 前提となる
    repo 設定 / 有効化方法 / 異常系 / 観測ログ / `DESIGN_REVIEW_RELEASE_ENABLED` 共存 /
    後方互換 / merge 後の再配置）で構成。Reviewer / 将来の保守者が #352 ↔ #354 を 1:1 で
    grep 比較できる形を最優先（NFR 4.1 / 4.2）。「対象 PR の条件」直下に `> 実装 PR との
    差分` 注記を **blockquote** で追加し、`ready-for-review` 必須削除 + `needs-iteration`
    除外追加の差分理由を明示
  - **#40 との共存節を独立小節として配置**: 当初 `### `[`DESIGN_REVIEW_RELEASE_ENABLED`](...)`
    のような複合 anchor を試みたが、GitHub の markdown anchor 生成規則で予期せぬ衝突を
    招くため、シンプルな日本語見出し `### DESIGN_REVIEW_RELEASE_ENABLED (#40) との共存`
    として両 processor の責務分担（本 #354 = PR 単位 auto-merge / #40 = Issue 単位ラベル
    除去）を表で読み下せる形に整理。NFR 4.3「`awaiting-design-review` は触らない」が
    本文と表の両方で明示される
  - **既存節への相互リンク 4 種**: `[#352](#auto-merge-processor-352)` /
    `[#349](#pr-reviewer-commit-status-publishing-349)` /
    `[#40](#design-review-release-processor-40)` /
    `[#348 kill switch](#full-auto-kill-switch)` を概要・運用設定・後方互換・観測ログの
    各小節に散りばめ、片方向リンクではなく双方向に辿れる文脈を整備。anchor は既存 README で
    実例のある形式（`grep -n` で既存箇所を確認）のみを使用
  - **`merge 後の再配置`注記**: 既存 #261 (line 2483) / #279 (line 2900) と同形の
    `cd ~/.idd-claude && git pull && ./install.sh --local` 文面を採用。本機能は新規 module
    `modules/auto-merge-design.sh` を追加するため、`REQUIRED_MODULES` ローダの起動時 fail
    を避けるための再配置が必須である旨を明示
  - **オプション機能一覧表**: 7 カラム形式（機能 / 制御変数 / 既定 / 正規化規則 / 追加 env /
    詳細 / 関連）を #352 行と同じ密度で記述。差分は (1) head pattern を `-design` に置換、
    (2) `ready-for-review` ラベル必須記述を削除、(3) `needs-iteration` 除外を追加、(4) impl
    PR を head pattern により排他する旨を明記、(5) `DESIGN_REVIEW_RELEASE_ENABLED` (#40)
    との分担を併記、の 5 箇所
  - **検証**: stage-a-verify gate の verify ブロック（tasks.md line 124-136）で宣言された
    全コマンド (shellcheck / actionlint / bash -n / auto-merge-design_test.sh /
    auto-merge_test.sh / pr_publish_commit_status_test.sh / full_auto_enabled_test.sh /
    diff -r) を本 task 完了時点でローカル再実行し、shellcheck OK / actionlint OK /
    bash -n OK / PASS=61 (auto-merge-design) / PASS=56 (auto-merge) / PASS=74
    (pr_publish_commit_status) / PASS=28 (full_auto_enabled) / diff -r empty を確認
- 残存課題: なし。本 task で実装系（task 1-4）/ テスト系（task 5-6）/ README 系（task 7）
  が完了し、tasks.md の最後の未完 task は task 8（全体 verify）。task 8 は本 task の verify
  実行をそのまま reproduce + dry-run smoke / install scratch test の追加検証で完了する見込み

### Task 8

- 採用方針: tasks.md line 124-136 の `<!-- stage-a-verify -->` ブロックで宣言された 10
  コマンドを順次実行し全 PASS を確認、加えて dry-run smoke で cycle 開始ログに
  `auto-merge-design=false` が含まれることを観測。fail は 1 件もなく impl-notes.md「確認事項」
  への追加列挙は不要
- 重要な判断:
  - shellcheck: `local-watcher/bin/modules/auto-merge-design.sh` / `issue-watcher.sh` /
    `install.sh` / `setup.sh` / `.github/scripts/*.sh` で警告ゼロ (exit=0)。`.shellcheckrc` の
    SC2317 / SC2012 accepted baseline を反映済 / NFR 5.1 達成
  - actionlint: `.github/workflows/*.yml` クリーン (exit=0)。本 spec で workflow は変更
    しないが回帰確認として要件通り実施
  - bash -n: `auto-merge-design.sh` / `issue-watcher.sh` 両方とも構文 OK
  - 新規テスト: `bash local-watcher/test/auto-merge-design_test.sh` PASS=61 FAIL=0
    （task 5 結果と完全一致）
  - 既存テスト回帰確認 (NFR 2.3): `auto-merge_test.sh` PASS=56 FAIL=0 / `pr_publish_commit_status_test.sh`
    PASS=74 FAIL=0 / `full_auto_enabled_test.sh` PASS=28 FAIL=0。task 4-7 で観測した既存挙動
    と完全一致
  - diff -r (NFR 4.4): `.claude/agents` / `.claude/rules` ともに root ↔ repo-template 差分
    ゼロ (exit=0)。本 spec では `.claude/{agents,rules}` を編集しなかったため期待通り
  - dry-run smoke (Req 9.4 / NFR 2.1): `REPO=owner/test REPO_DIR=/tmp/test-repo-354-task8 bash local-watcher/bin/issue-watcher.sh`
    で cycle 開始ログ 1 行目に `base-branch=main merge-queue-base=main auto-rebase=claude auto-merge=false auto-merge-design=false full-auto=false`
    を観測。`auto-merge-design=false` が `auto-merge=` と `full-auto=` の間に正しく出力され
    （task 3 で配線した位置）、続いて `cd: /tmp/test-repo-354-task8: No such file or directory`
    で early exit (task 4 learnings 記載通りの想定挙動)
  - install scratch test (任意): `install.sh` は `IDD_CLAUDE_BIN_DIR` 等の bin dir override
    env を提供しておらず常に `$HOME/bin` に書き込む実装 (line 1349-1365)。実行すると現在
    稼働中の watcher の `$HOME/bin/modules/` を実際に書き換える破壊的操作になるため、task 8
    の指示に従い実施を見送り。本 spec の merge 後は README task 7 で追記済の `cd ~/.idd-claude && git pull && ./install.sh --local`
    手順で `$HOME/bin/modules/auto-merge-design.sh` が配置される運用フローに従う想定
- 残存課題: なし。本 spec の全 task (1-8) 完了
