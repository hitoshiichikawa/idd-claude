# Implementation Notes (#273)

## Implementation Notes

### Task 1

- 採用方針: `265-*/test-find-impl-pr.sh` と同形式で fixture + `grep -cE` ベースの回帰スクリプトを追加し、`sc_tasks_unchecked_count` 中核 regex `^- \[ \]\*? [0-9]+\. ` の挙動を 3 fixture（unchecked 残存 / 全完了 / 空）で固定する。
- 重要な判断: `grep -cE` はマッチ 0 件時に rc=1 + stdout=`0` を返すため、`|| echo 0` パターンを使うと「`0\n0`」と重複出力されてしまう（実装中に regression として観測）。`count=$(grep -cE ...) || count=0` 形式で受けて stdout 単独に整える方が安全。task 2/3 で実装する `sc_tasks_unchecked_count()` 本体でも同じ落とし穴があるため、本知見を引き継ぐ。また `tasks-with-unchecked.md` には deferrable `- [ ]* N. ...` を含めなかった（正本 regex の `\*?` は deferrable もマッチさせるため、含めると期待値が 3 件になり「最上位 unchecked のみ 2 件」のシンプルな assertion が壊れる。本 fixture の責務は判定 regex のサニティチェックに限定し、deferrable の挙動確認は task 3 以降の本体実装で扱う方針）。
- 残存課題: 本 fixture は判定 regex の sanity check のみで、task 2 (`sc_issue_state`) / task 3 (`sc_tasks_unchecked_count` 本体: rc=0/1/2 の 3 値) / task 4 (`stage_checkpoint_find_impl_pr` の MERGED ガード inject) の挙動回帰は別途必要。task 3 実装時に本 fixture を `sc_tasks_unchecked_count()` から `REPO_DIR/SPEC_DIR_REL/tasks.md` 経由で読ませる薄い integration を追加するかは task 3 担当者に委ねる（現状は judgment regex の単体確認に留める）。

### Task 2

- 採用方針: `gh issue view "$NUMBER" --repo "$REPO" --json state --jq '.state' 2>/dev/null` の stdout を `case` 文で `OPEN` / `CLOSED` の 1 トークンに限定検証し、それ以外は rc=1 + stdout 空に倒す read-only ヘルパとして `sc_issue_state()` を `stage_checkpoint_has_impl_notes` 直後に追加。
- 重要な判断: (1) `gh` 末尾に `|| true` を付けて pipefail / set -e 環境下でも rc を握り潰し、`case` の whitelist 判定で OPEN/CLOSED 以外（空文字 / 不正トークン / API エラーで stderr 抑止後の空 stdout）を一律 rc=1 にまとめた。これにより design.md L196-198 の「rc=1=API 失敗・stdout 空」契約と一致させ、呼び出し側 task 4 は rc 単独で safe fallback に倒せる。(2) Task 1 で得た知見「`grep -cE` の rc=1 + stdout=`0` 重複出力」は本関数では非該当（`gh` の出力は単一 JSON 値 1 トークンで複数行化しない）だが、stdout を 1 トークン保証する責務は同じ思想で `case` whitelist を採用した。(3) `stderr` は `2>/dev/null` で抑止し、cron.log 汚染を防止（NFR 2.1 の grep 抽出可能性維持）。
- 残存課題: なし（task 4 で `issue_state=$(sc_issue_state); issue_rc=$?` の呼び出し契約と完全に一致）。
