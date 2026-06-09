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
