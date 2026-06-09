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

## 確認事項

特になし（design.md と requirements.md の整合性は確認済み。tasks.md の本 task 仕様も
矛盾なく実装可能だった）。

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
