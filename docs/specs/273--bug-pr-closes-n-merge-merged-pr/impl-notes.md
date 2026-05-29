# Implementation Notes (#273)

## Implementation Notes

### Task 1

- 採用方針: `265-*/test-find-impl-pr.sh` と同形式で fixture + `grep -cE` ベースの回帰スクリプトを追加し、`sc_tasks_unchecked_count` 中核 regex `^- \[ \]\*? [0-9]+\. ` の挙動を 3 fixture（unchecked 残存 / 全完了 / 空）で固定する。
- 重要な判断: `grep -cE` はマッチ 0 件時に rc=1 + stdout=`0` を返すため、`|| echo 0` パターンを使うと「`0\n0`」と重複出力されてしまう（実装中に regression として観測）。`count=$(grep -cE ...) || count=0` 形式で受けて stdout 単独に整える方が安全。task 2/3 で実装する `sc_tasks_unchecked_count()` 本体でも同じ落とし穴があるため、本知見を引き継ぐ。また `tasks-with-unchecked.md` には deferrable `- [ ]* N. ...` を含めなかった（正本 regex の `\*?` は deferrable もマッチさせるため、含めると期待値が 3 件になり「最上位 unchecked のみ 2 件」のシンプルな assertion が壊れる。本 fixture の責務は判定 regex のサニティチェックに限定し、deferrable の挙動確認は task 3 以降の本体実装で扱う方針）。
- 残存課題: 本 fixture は判定 regex の sanity check のみで、task 2 (`sc_issue_state`) / task 3 (`sc_tasks_unchecked_count` 本体: rc=0/1/2 の 3 値) / task 4 (`stage_checkpoint_find_impl_pr` の MERGED ガード inject) の挙動回帰は別途必要。task 3 実装時に本 fixture を `sc_tasks_unchecked_count()` から `REPO_DIR/SPEC_DIR_REL/tasks.md` 経由で読ませる薄い integration を追加するかは task 3 担当者に委ねる（現状は judgment regex の単体確認に留める）。
