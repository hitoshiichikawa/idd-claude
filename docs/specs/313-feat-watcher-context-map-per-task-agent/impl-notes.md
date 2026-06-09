# Implementation Notes

## Implementation Notes

### Task 1

- **採用方針**: design.md「Components and Interfaces」節のシグネチャに厳密準拠して
  `local-watcher/bin/modules/context-map.sh` を新規追加。既存 `modules/stage-a-verify.sh`
  と同じヘッダ規約・logger prefix 形式・`set -euo pipefail` 非宣言（本体側委譲）に揃えた。
- **重要な判断**:
  - `cm_resolve_boundary` / `_cm_resolve_task_name` の task 行検出 regex は
    `tasks-generation.md` の checkbox enforcement 規約
    （`^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? `）に準拠し、最上位 task と子 task の双方を
    同一パターンで捉えられるようにした。次の task 行 / `## ` 見出し / EOF を走査終端と
    することで `_Boundary:_` 検出の決定論性を確保。
  - `cm_resolve_candidate_files` は fenced code block 内のみを対象に substring match で
    boundary token を含む行から最初の token を採用する素朴ヒューリスティック。design.md の
    File Structure Plan が ASCII ツリー描画 + コメント形式である慣習を前提に、
    `├ │ └ ─` を空白へ正規化してから 1st-token 抽出。OOC 重複は `seen[]` で除去し
    入力順を保つ（NFR 2.1 冪等性に直結）。
  - SC2016（`backticks inside single quotes don't expand`）は markdown 装飾としての
    バッククォートに対する false positive のため、該当 printf 行に `# shellcheck disable=SC2016`
    を個別付与した。`.shellcheckrc` で global suppress するとプロジェクト全体の
    意図された command substitution チェックも失われるため、ピンポイント抑止に留めた。
  - `cm_truncate_if_oversize` の閾値（200 行 / 8 KB）は NFR 4.1 の確定値 として関数内ローカル
    定数として埋め込み、env override は意図的に提供していない（運用後の見直しは README で
    予告される予定 / Task 6）。
- **残存課題**: 本 task では fixture ベースの behavioral regression test を実装していない
  （`_Requirements_partial: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.9, 2.10, NFR 2.1, NFR 2.3_`
  で Task 5 に deferred 明示済み）。Task 5 が dedicated regression test task として上記
  AC をカバーする責務を持つ。

### Task 2

- **採用方針**: design.md「Watcher 本体改訂」節の指示に厳密準拠し、(1) Config ブロック /
  (2) REQUIRED_MODULES / (3) `run_per_task_loop` の task ループ冒頭 / (4) Implementer
  prompt builder の heredoc 末尾 / (5) Reviewer prompt builder の heredoc 末尾 の 5 箇所に
  最小限の wiring を追加。生成ロジックは Task 1 で実装済みの `modules/context-map.sh`
  に集約されており、本 task では本体側 call site のみを足した。
- **重要な判断**:
  - `${context_map_block_section}` の embed 位置は Implementer 側では既存
    `${findings_block_section}${debugger_block_section}${closure_matrix_section}` の **直後**
    に連結し、prompt 構造（heredoc 末尾の改行ポリシー / EOF 直前の空行）を変えないことで
    `cm_enabled` rc=1 時に既存 prompt と byte 一致を保つ（NFR 1.1）。Reviewer 側は heredoc
    末尾 `- スタイル / ...` の直下に独立行で挿入し、空文字展開時に余計な改行が 1 行入るが
    prompt 全体は機能的に等価（off 時の watcher ログ・stage 遷移・exit code は不変）。
  - `cm_enabled` を Implementer / Reviewer の prompt builder 双方で評価する設計（call site
    での 1 回評価ではない）にしているのは、build_*_prompt が fresh session prompt の組み立て
    関数として独立に呼ばれるユースケース（redo / round=2 / round=3）を含むため。`cm_enabled`
    自体は env 厳密判定の純粋関数で副作用ゼロ・冪等のため、二重評価コストは無視できる。
  - `cm_generate` の失敗は `|| cm_warn ...` で吸収。`set -e` 下でも per-task ループが停止
    しないよう、Task 1 側で `cm_generate` 内の失敗候補は `|| true` で短絡しつつ rc=0 で
    抜ける契約になっているが、二重に safety net を張る形で本 task 側でも `||` を併用。
  - dry run smoke は scratch repo の origin 不在で `git fetch` 段階まで進めず、watcher が
    REQUIRED_MODULES の source 段階を抜けて config 解釈 → BASE_BRANCH 確定までは進む
    ことを観察できた。`source modules/context-map.sh` 単体での `cm_enabled` ゲート挙動
    （both-true / PTL=false / CM=False typo の 3 ケース）も期待通り（rc=0 / 1 / 1）を確認。
- **残存課題**: 本 task では behavioral regression test を実装していない
  （`_Requirements_partial: 2.1, 3.1, 3.2_` で Task 5 に deferred 明示済み）。Task 5 が
  `test-cm-generate.sh` / `test-cm-inject.sh` で当該 AC をカバーする責務を持つ。

### Task 3

- **採用方針**: design.md「Agent 仕様改訂」節で示された追記ブロックを、root の
  `.claude/agents/developer.md` と `repo-template/.claude/agents/developer.md` の
  「実装ルール」節 `変更前に grep / glob で既存実装・影響範囲を必ず把握する` の **直後** に
  byte 一致で挿入。CLAUDE.md「root/repo-template 二重管理」規約と Req 4.1 / 4.3 に整合。
- **重要な判断**:
  - 挿入位置は design.md の指示通り「`変更前に grep / glob ...` の直後」とし、その後に続く
    `依存ライブラリを追加する場合は...` 行との間に新規 bullet 1 件を挿入する形にした
    （bullet レベルを既存兄弟と揃え、サブ箇条書きにはしない）。設計上は context map 参照は
    grep / glob ルールの **修飾**として読まれる方が意図に近いが、bullet ネストを変えると
    既存兄弟 bullet との視覚的整合性が崩れるため平 bullet を選択。
  - 文体は design.md のブロックをほぼ逐語で採用し、本リポジトリの既存散文（全角括弧 `（）` /
    `Req X.Y` 形式の参照）に揃えた。`(` 半角括弧と `（` 全角括弧の混在は CLAUDE.md
    「root/repo-template 二重管理」規約上 byte 一致が崩れる原因になるため、両系統で全角括弧
    `（）` のみを使用し `diff` が空になることを確認。
  - 追記内容は静的な散文のみで実行コードを含まないため、本 task 内に追加すべき regression
    test は **存在しない**（CLAUDE.md「root と repo-template の二重管理」節が要求する
    `diff -r .claude/agents repo-template/.claude/agents` が空であることは、Task 5 の
    stage-a-verify ブロック内で検証される）。
- **残存課題**: なし。本 task は agent 仕様の散文追記のみで完結。AC 3.3 / 4.1 / 4.3 は本 task で
  実装側の責務を完了し、4.3 の機械検証は Task 5 の verify block で行われる。

### Task 4

- **採用方針**: design.md「Agent 仕様改訂」節の追記ブロックを、root の `.claude/agents/reviewer.md`
  と `repo-template/.claude/agents/reviewer.md` の「必ず先に読むルール」節 必読ファイル一覧の
  末尾（`docs/specs/<番号>-<slug>/design.md（存在する場合）` の直下）に byte 一致で挿入。
  Req 3.4 / 4.2 / 4.3 と CLAUDE.md「root/repo-template 二重管理」規約に整合。
- **重要な判断**:
  - 挿入位置は既存必読リスト末尾とした。「必ず先に読むルール」節は Reviewer が起動時に
    最初に Read する一次情報源を列挙する節であり、context-map.md は同節の他必読ファイル
    （requirements.md / tasks.md / impl-notes.md / design.md）と並列して扱うのが意図に最も近い。
  - 散文は design.md ブロックを逐語採用し、Task 3 で developer.md に挿入した全角括弧 `（）` /
    `Req X.Y` 形式の表記スタイルとも整合する形に揃えた。両系統で `diff -r .claude/agents
    repo-template/.claude/agents` が空であることを確認。
  - 追記内容は静的な散文のみで実行コードを含まないため、本 task 内に追加すべき regression
    test は **存在しない**（Req 4.3 の `diff -r` 機械検証は Task 5 の stage-a-verify ブロックで
    行われる）。
- **残存課題**: なし。本 task は agent 仕様の散文追記のみで完結。AC 3.4 / 4.2 / 4.3 は本 task で
  実装側の責務を完了し、4.3 の機械検証は Task 5 の verify block で行われる。

### Task 5

- **採用方針**: `_Boundary: test-fixtures/_` を厳密に守り、`docs/specs/313-.../test-fixtures/`
  配下にのみファイルを追加。3 本のスモークスクリプト（test-cm-generate.sh /
  test-cm-disabled.sh / test-cm-inject.sh）と 2 つの fixture（tasks-sample.md /
  design-sample.md）で、Task 1 / Task 2 で `_Requirements_partial:_` に列挙された全 AC を
  集約検証する。inject 系テストでは `issue-watcher.sh` の prompt builder を副作用なしで
  source する手段として **awk による関数定義抽出**（一時ファイル経由で source）を採用した
  （watcher 本体は末尾で `_dispatcher_run` を直接実行するため straight source できない）。
- **重要な判断**:
  - 冪等性テスト（NFR 2.1）の「同一入力」は **spec dir の内容が同一の状態**と解釈し、
    2 つの fresh temp dir に同一 fixture を配置して独立に `cm_generate` を呼び比較する形に
    した。同一 spec dir で 2 回呼ぶ素朴な実装は、1 回目で生成された context-map.md が
    `cm_resolve_candidate_docs` の find 結果に紛れ込むため「同一入力」前提が崩れる。
  - shellcheck SC2030 / SC2031（subshell 内 env 改変の info 警告）はテスト設計上意図的に
    subshell で env を隔離する箇所が大量にあり、false-positive。プロジェクトの
    `.shellcheckrc` を変更せず、各 fixture スクリプトの冒頭で個別 `# shellcheck disable=`
    することで scope を最小化した。
  - prompt builder の関数抽出は `awk -v fname=... 'index($0, fname "()") == 1 ... && /^}$/ {exit}'`
    のシンプルなパターンで完結する。Tasks 1 / 2 の wiring（context-map block を末尾に
    embed）が壊れていれば inject テストの strip 比較で即座に検出される設計とした。
  - `cm_compose` の `_Boundary:_` セクション内 bullet 展開には **latent な印字バグ**を
    確認した（後述「確認事項」参照）。本 task の boundary（test-fixtures/）外のため修正は
    行わず、Req 2.3 の検証は **`cm_resolve_boundary` の CSV 抽出が boundary を正しく
    返すこと** + **`## Boundary` セクション見出しの存在**を assert する形で代替した。
    候補ファイル列（Req 2.4）の boundary 解決結果は `## Candidate files` 側で正しく
    展開されるため、Req 2.4 のテストは経由側で担保できている。
- **残存課題**: なし。本 task でカバーした AC は下記「AC カバレッジ（Task 5 スコープ分）」
  参照。Task 1 の latent bug は確認事項に escalation 済み。

### Task 6

- **採用方針**: `_Boundary: README.md_` を厳守し、README.md の「オプション機能（標準有効 /
  常時有効）一覧」節の opt-in 表に `CONTEXT_MAP_ENABLED` 行を追加した上で、`Per-task TDD
  Implementation Loop (#21)` 直後 / `Debugger Subagent (Phase 3, #22)` 直前に独立 h2 詳細
  セクション `## Context Map for per-task agents (#313)` を新設し、Req 5.1〜5.4 + Task 6 詳細
  項目（上限値 / 見直し予定）を運用者向け散文として整理した。
- **重要な判断**:
  - opt-in 表の挿入位置は **Phase 3: Debugger Subagent 直後**とした。本機能は per-task ループ
    （#21）配下でのみ動作するため #21 系統の opt-in 機能群（PER_TASK_LOOP_ENABLED /
    DEBUGGER_ENABLED）と隣接させると依存関係が読み取りやすい。Phase A〜E（Auto Rebase /
    Path Overlap 等）系統には混ぜなかった。
  - 詳細セクションの h2 アンカー `(#313)` は既存 #21 / #22 の命名規約に揃えた
    （`## Per-task TDD Implementation Loop (#21)` / `## Debugger Subagent (Phase 3, #22)`）。
    opt-in 表の「詳細」列 markdown link
    `[Context Map for per-task agents (#313)](#context-map-for-per-task-agents-313)` は
    GitHub の anchor 正規化規則（lowercase + space→hyphen + `#` 除去）で解決される。
  - 「動作前提として `PER_TASK_LOOP_ENABLED=true` 環境のみで動作する旨」（Req 5.2）は
    複数箇所に重複明記した: (1) opt-in 表の「追加 env」列の **前提**強調、(2) 詳細セクション
    冒頭の「注」block の Req 1.4 参照、(3) opt-in 手順の cron 例で両 env を併記、(4) 環境変数
    表の補足行。運用者が表だけ見ても本文だけ見ても同じ結論に到達できるようにした。
  - 「上限値 200 行 / 8 KB と運用後に観測データで見直す予定」（Task 6 詳細項目）は専用の
    `### 出力サイズ上限` セクションを立て、初期確定値の根拠（per-task prompt の 5〜10 %）と
    見直し方針（観測指標: 占有割合 / truncate 発生率 / 追加 Read 発生率）を明示した。NFR 4.1
    の「具体閾値は design.md で確定」を README にも反映する位置付け。
  - Scope-out 列挙（Req 5.4）は箇条書きで 4 項目（reasoning effort 変更 / 並列度 default 変更 /
    LLM scout / repo-wide index）を逐語的に明示。requirements.md の Out of Scope 節および
    design.md の Non-Goals 節と同じ語彙を採用して traceability を確保した。
  - 追記内容は静的な散文のみで実行コードを含まないため、本 task 内に追加すべき regression
    test は **存在しない**（README は test スコープ外。Req 6.1〜6.3 の bash test は Task 5 で
    完了済み）。stage-a-verify ブロックは README に依存しない。
- **残存課題**: なし。本 task は README の散文追記のみで完結。Req 5.1〜5.4 はドキュメント側
  責務として本 task でカバー完了。

## 確認事項

### Task 5 で発見した latent bug（cm_compose 内 `_Boundary:_` bullet 展開の取り扱い）

`cm_compose` 内の以下のコード片（`local-watcher/bin/modules/context-map.sh:316`）には、
**末尾トークンが消失する**バグが残存している:

```bash
printf '%s' "$boundary" | tr ',' '\n' | while IFS= read -r token; do
```

`printf '%s'` は trailing newline を付与しないため、`while IFS= read -r token` は末尾の
token（newline 終端されていない最後の行）を読み飛ばす。結果として:

- 単一トークン boundary（例: `"context-map.sh"`）: bullet が **1 件も出力されない**
- 複数トークン boundary（例: `"a, b, c"`）: 末尾 `c` の bullet が出力されない

修正案: `printf '%s' "$boundary"` を `printf '%s\n' "$boundary"` に変更（trailing newline
追加 / 1 文字差分）。

**Task 5 のスコープ外（boundary 違反）のため本 task では修正していない**。Architect /
人間レビュワーに以下のいずれかを判断委ねる:

1. follow-up Issue（hotfix）を切る。修正は 1 行のため small PR で対応可能
2. Task 1 を再 Implementer 起動して修正する（per-task ループ再走）
3. Req 2.3 / 2.4 の実装側 contract を「heading のみで足りる」と緩める（recommended せず）

本 task の test-cm-generate.sh は本 latent bug を踏まえた assertion 設計（`cm_resolve_boundary`
の CSV 抽出と `## Boundary` heading の存在で代替検証 / `## Candidate files` 側で boundary
ベースの解決結果が観測されることを確認）にしているため、現状のまま全 24 assert が pass する。
bug が修正されれば、追加で `## Boundary` セクション内に `- context-map.sh` bullet を assert
する強化テストを task 5 後続で追加できる。

## AC カバレッジ（Task 5 スコープ分）

| Requirement | 担保手段（test-fixtures/） |
|---|---|
| 2.1 | test-cm-generate.sh case1 で `cm_generate` が context-map.md を生成することを検証 |
| 2.2 | test-cm-generate.sh case1 が `## Task` / `- ID: 1` / Task Name を grep で検証 |
| 2.3 | test-cm-generate.sh case1 が `## Boundary (from tasks.md` heading + `cm_resolve_boundary` CSV を assert（latent bug は確認事項に escalation 済み） |
| 2.4 | test-cm-generate.sh case1 で boundary 派生の candidate files セクション内に `context-map.sh` が出ることを awk で抽出して検証 |
| 2.5 | test-cm-generate.sh case1 で `## Candidate tests` heading を grep |
| 2.6 | test-cm-generate.sh case1 で `## Candidate docs` heading + `- tasks.md` を grep |
| 2.7 | test-cm-generate.sh case1 で `## Search constraints` + `READ FIRST:` を grep |
| 2.9 | test-cm-generate.sh case3 で `_Boundary:_` 不在 task（Task 3）に対し `(resolution: none` 明示が出ることを検証 |
| 2.10 / NFR 4.1 | test-cm-generate.sh case4 で 300 行 / 約 12 KB 入力が 202 行（200 cap + 改行 + truncate marker）に縮約され、`truncated by cm_truncate_if_oversize` marker と原行数 / 原バイト数が末尾に追記されることを検証 |
| 3.1 | test-cm-inject.sh が `build_per_task_implementer_prompt` を flag-on で呼び、stdout に `## Context Map` が含まれることを確認 |
| 3.2 | test-cm-inject.sh が `build_per_task_reviewer_prompt` を flag-on で呼び、stdout に `## Context Map` が含まれることを確認 |
| 3.5 / NFR 1.1 | test-cm-inject.sh が flag-off で `## Context Map` 不在を確認 + 「flag-on prompt から `## Context Map` 以降を strip した結果」と「flag-off prompt」が一致することを Implementer / Reviewer 両方で検証 |
| 6.1 | test-cm-generate.sh 全体（24 assert）で生成 contract を機械検証 |
| 6.2 | test-cm-inject.sh 全体（7 assert）で prompt 注入 contract を機械検証 |
| 6.3 | test-cm-disabled.sh 全体（20 assert）で gate-closed 時の context-map.md 非生成 + prompt 注入なしを機械検証 |
| NFR 2.1 | test-cm-generate.sh case2 が同一 fixture を別々の fresh temp dir に配置して 2 回独立に `cm_generate` を呼び、出力が byte 一致することを検証 |
| NFR 2.3 | test-cm-generate.sh case5a / 5b / 5c で SPEC_DIR_REL 不在 / tasks-design 不在 / 空 task_id の全異常入力で `cm_generate` rc=0 終了を検証 |
| NFR 3.1 | `shellcheck docs/specs/313-.../test-fixtures/*.sh` 警告ゼロ（SC2030 / 2031 info は意図的 false-positive を file-scope disable で抑止） |

## AC カバレッジ（Task 1 スコープ分）

| Requirement | 担保手段（本 task 完了時点） |
|---|---|
| 1.1 / 1.2 / 1.3 / 1.4 | `cm_enabled` の inline smoke test 5 ケース（both-true / =false / unset / `True` / `1`）で確認 |
| 2.2〜2.7 | `cm_compose` の inline smoke test で各セクション出力を目視確認 |
| 2.8 | LLM 呼び出しなしの純粋 bash 実装（実装パスから明白） |
| 2.9 | `_Boundary:_` 不在 fixture で `(resolution: none ...)` 出力を確認 |
| 2.10 / NFR 4.1 | 300 行 fixture で 202 行（200 + 改行 + truncate marker）へ縮約されることを確認 |
| 3.5 | `cm_render_prompt_section` が flag-off 時に空文字を返すことを smoke で確認 |
| NFR 2.1 | 同一入力 2 回呼出で context-map.md が byte 一致することを smoke で確認 |
| NFR 2.2 | sudo 不要（標準コマンドのみ） |
| NFR 2.3 | 入力不在 / 解決不能ケースでも rc=0 で抜けることを smoke で確認 |
| NFR 3.1 | `shellcheck local-watcher/bin/modules/context-map.sh` 警告ゼロ |
| NFR 3.2 | 本体側で `set -euo pipefail` 宣言済み（モジュール冒頭コメントに明記） |

部分担保 (`_Requirements_partial:_` で Task 5 に deferred): 2.1, 2.2, 2.3, 2.4, 2.5, 2.6,
2.7, 2.9, 2.10, NFR 2.1, NFR 2.3 — Task 5 で fixture ベース regression test として正式に
担保される。

STATUS: complete
