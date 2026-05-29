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

### Task 3

- 採用方針: `sc_issue_state` の直後に `sc_tasks_unchecked_count()` を追加。design.md L218-258 の契約（rc=0/1/2 の 3 値、stdout は十進整数 1 トークン、read-only）と `.claude/rules/tasks-generation.md` の Budget overflow count 抽出 regex `^- \[ \]\*? [0-9]+\. ` に完全一致させた。関数冒頭コメントに正本 regex の参照先（tasks-generation.md / design-review-gate.md）を明記し、両者は別実行基盤のため共有コードを持てず同一 regex を多重記述してドリフトを防ぐ根拠を残した。
- 重要な判断: (1) **tasks.md 文面と Task 1 learning の矛盾点**を Task 1 learning 側で解決した。tasks.md L38 には `count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$path" 2>/dev/null || echo 0)` と書かれているが、Task 1 で観測された通り `grep -cE` は 0 件マッチで rc=1 + stdout="0" を返すため、コマンド置換内 `|| echo 0` を加えると 0 件時に `0\n0` の重複出力になり `count="0\n0"` という多行値になる事故が起きる。本実装では Task 1 learning に従い `count=$(grep -cE '^- \[ \]\*? [0-9]+\. ' "$path" 2>/dev/null) || count=0` 形式を採用し、stdout 単独の整数 1 トークン保証（design.md L257 Postconditions）を達成した。tasks.md 文面は **設計意図**（rc 個別ハンドリング・stdout 整数 1 トークン・safe fallback）を示すものであり、Developer は spec の意図を達成する最適形を選ぶ責務がある旨は Task 3 prompt でも明示されていたため、tasks.md 本文書き換え禁止規約に抵触せずに方針採用した。(2) `[ -f "$path" ]` false → rc=2 / `[ -r "$path" ]` false → rc=1 の順序は design.md L229-235 の通り。「ファイル不在は design-less impl と同等の正常系」「読み取り権限なしは I/O 失敗の異常系」を rc 値で区別することで、呼び出し側 task 4 が `case` 文 1 つで terminal/non-terminal を切り分けられる契約を確立した。
- 残存課題: なし（task 4 で `tasks_unchecked=$(sc_tasks_unchecked_count); tasks_rc=$?` の呼び出し契約と完全に一致）。`shellcheck` 警告ゼロを維持、`test-merged-guard.sh` 3 fixture PASS を維持、隔離環境での rc=0/1/2 3 値挙動も sanity OK。
