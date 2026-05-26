# 実装ノート (#243 flock skip 経路 path-overlap 可視化)

## Implementation Notes

### Task 1

- **採用方針**: 可視化専用ロックファイルパス `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `issue-watcher.sh` の config ブロックに env override 可能・既定無害値（`${LOG_DIR}/flock-skip-visibility.lock`）で 1 行追加した（design.md の canonical 書式準拠）。
- **重要な判断**:
  - 配置位置は `LOG_DIR` / `LOCK_FILE` 定義（370-371 行）の直後とした。design.md の指示（`PATH_OVERLAP_CHECK` 近傍 = 336 行付近、ただし `LOG_DIR` 定義 370 行より後ろ）のうち「LOG_DIR が参照できる位置」を最優先し、`${LOG_DIR}` を安全に参照できる LOG_DIR/LOCK_FILE 定義直後を選択した。
  - 既存 env var の名前・順序・書式は一切変更せず、新規行の追加のみ（後方互換 / Req 6.5 / NFR 1.1）。既定値は `PATH_OVERLAP_CHECK=off` 環境では未参照のため挙動に影響しない。
  - shellcheck はこの追加行で新規警告ゼロ。既存の SC2317（info / 間接呼び出し ERROR ロガーへの誤検知）11 件は変更前から存在し本変更とは無関係であることを `git stash` 比較で確認済み。
- **残存課題**: なし。本 config は task 2（`po_run_flock_skip_visibility` が `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を `exec 201>` で参照）の前提となる。task 2 以降の関数追加・フック挿入・テスト・README は未着手（本起動の対象外）。

### Task 2

- **採用方針**: `po_check_dispatch_gate` の overlap 判定コア（809-878 行）を `po__visibility_evaluate_candidate` として切り出し（評価規約を分岐させず同一の po_* 関数群を再利用）、その上に専用 flock + 候補列挙 + 候補ループの `po_run_flock_skip_visibility` を `promote-pipeline.sh` の `po_check_dispatch_gate` 直後へ追加した。
- **重要な判断**:
  - `po__visibility_evaluate_candidate` は `po_check_dispatch_gate` 本体と同一の関数・引数（`po_load_edit_paths` / `po_resolve_holder_labels "dispatch"` / `po_collect_inflight_issues` / `po_compute_overlap` / `po_apply_awaiting_slot` / `po_clear_awaiting_slot`）を用い、dispatch 固有の return（0=続行/1=skip）を捨てて戻り値を warn 判定用（0=完了/1=警告）に再定義した（Req 7.1 / 7.2）。ログには通常経路の `po_log` 書式に `route=flock-skip` 経路識別子を前置した（NFR 4.1 / 4.2）。
  - 候補列挙の除外句（`vis_search_filter`）は design.md の設計判断どおり `_dispatcher_run` の `local search_filter` を共有せず本関数内で自前再構築した。除外集合に処理中ラベル（`LABEL_CLAIMED` / `LABEL_PICKED`）を含めることで Req 2.4 を構造的に保証する。`flock -n 201` 取得失敗時は `route=flock-skip visibility skipped` 抑止ログを出し（Req 4.2）、全エラー経路で fd close + `return 0` の fail-open とした（NFR 3.2 / NFR 1.1）。
  - shellcheck はこの追加で新規警告ゼロ（`.shellcheckrc` 導入済みで baseline もクリーン）。`bash -n` 構文チェックも pass。
- **残存課題**: task 3（`issue-watcher.sh` の flock skip ブロック 578-582 行への `po_run_flock_skip_visibility || true` フック挿入）が本関数の唯一の呼び出し元として未着手。task 4（`test-flock-skip-visibility.sh` スモーク）/ task 5（README）も未着手。これらは別の fresh Implementer 起動で消化される。tasks.md の stage-a-verify ブロックは task 4 で作成される test スクリプトを参照するため、本起動の検証は shellcheck のみで実施した。

### Task 3

- **採用方針**: `issue-watcher.sh` の flock skip ブロック（`flock -n 200 || { ... }` の失敗ブロック内）に、既存スキップログ出力後 / `exit 0` 直前で `if [ "${PATH_OVERLAP_CHECK:-off}" = "true" ]; then po_run_flock_skip_visibility || true; fi` フックを挿入した（design.md「State transition（flock skip ブロック）」節の canonical どおり）。
- **重要な判断**:
  - 実際の flock skip ブロックは task 1 の config 行追加により design.md 記載の 578-582 行から **584-588 行へ +6 シフト**していたが、ブロックの内容（`exec 200>"$LOCK_FILE"` / `flock -n 200 || { echo "...スキップ"; exit 0 }`）は design canonical と一致していたため、行番号差は無視して内容一致で安全に編集できた。
  - 既存スキップログ（`echo "[$(date '+%F %T')] 他のインスタンスが実行中のためスキップ"`）は書式不変で温存（Req 6.5）。フックは flock 失敗ブロック内にのみ置き、flock 成功時の通常 dispatch 経路（`cd "$REPO_DIR"` 以降）には一切介入しないため、Req 1.4 / NFR 1.2（通常経路非介入）が制御フローとして構造的に保証される。
  - `exit 0` の値・意味は不変（NFR 1.1）。`PATH_OVERLAP_CHECK` が off/未設定/不正値のときは gate に入らず従来と完全一致（Req 6.1/6.2）。`|| true` で `po_run_flock_skip_visibility` の戻り値に関わらず exit 0 を維持（NFR 3.2 と二重防御）。
  - shellcheck はこの追加で新規警告ゼロ（`git stash` で baseline 比較 → diff なしを確認）。`bash -n` 構文チェックも pass。
- **残存課題**: task 4（`test-flock-skip-visibility.sh` スモーク作成）/ task 5（README 更新）が未着手。本フックにより `po_run_flock_skip_visibility` の唯一の呼び出し元が結線されたため、task 4 のスモークは opt-in gate / 専用ロック多重起動抑止 / 候補クエリの claim 除外を mock で検証可能になる。tasks.md の stage-a-verify ブロックは task 4 で作成される test スクリプトを参照するため、本起動の検証は shellcheck + bash -n のみで実施した（test スクリプトはまだ存在せず本 task のスコープ外）。

### Task 4

- **採用方針**: `test-fixtures/test-flock-skip-visibility.sh` を新規作成し、#221 の `test-holder-labels.sh` の慣習（module を直接 source / 本体 Config 相当の global 束縛 / gh 関数スタブ / PASS/FAIL カウントで非 0 exit）を踏襲して `po_run_flock_skip_visibility` の純ロジックを mock gh 環境で検証した（実 API・ネットワークに触れない）。
- **重要な判断**:
  - 各検証ケースの assert 文字列は推測せず実装の実書式に厳密一致させた。抑止ログは `po_run_flock_skip_visibility` の実ログ `route=flock-skip visibility skipped`、除外句は `vis_search_filter` の実書式 `-label:"claude-claimed"` / `-label:"claude-picked-up"`、候補列挙は `--label auto-dev --state open` を grep して assert している。
  - 多重起動抑止ケースは別 fd（210）で同一 lock file（`PATH_OVERLAP_VISIBILITY_LOCK_FILE`）を `flock -n 210` 保持した状態で関数を呼び、関数内の `flock -n 201` を確実に失敗させる構成とした。flock 非解決環境では検証不能なので冒頭で `command -v flock` を確認し未解決時は SKIP（exit 0）する（CI/cron 最小 PATH への配慮）。
  - 差分等価（NFR 1.1）は「opt-in off では本体 flock skip フックが `po_run_flock_skip_visibility` を呼ばない（=副作用ゼロ）」ことと「関数を直接呼んでも off/未設定/不正値では gh を 1 度も呼ばず return 0」の両面で検証した。mock gh は全 argv を `gh-calls.log` に記録し、状態変更系（`--add-label` / `--remove-label` / `issue comment` / `api -X PATCH`）の不在を grep で確認している。
  - 自己完結性: `mktemp -d` の一時 dir と lock file を `trap ... EXIT` で cleanup し、self-hosting 環境を汚さない。再実行で壊れない冪等構成。shellcheck はこのファイルで警告ゼロ（`SC2034` / `SC2317` は source 経由の間接参照ゆえファイル冒頭で明示 disable）。
- **残存課題**: task 5（README の Path Overlap Checker (Phase E) 節への flock skip 可視化サブ節追記 / env var 表への `PATH_OVERLAP_VISIBILITY_LOCK_FILE` 追記 / Migration Note）が未着手。本 task の test は実装側（task 2/3）の挙動を検証するもので、README ドキュメントの正確性は別途 task 5 で担保される。

### Task 5

- **採用方針**: README の「Path Overlap Checker (Phase E)」節を 4 箇所更新した（推測せず実装の実書式を Grep / Read で照合してから記載）。記載した env var 名・既定値・ログ書式はすべて先行 task の実装（`promote-pipeline.sh` の `po_run_flock_skip_visibility` / `po__visibility_evaluate_candidate`、`issue-watcher.sh` の config 行 377 行・フック）と一致させた。
- **重要な判断**:
  - ログ書式は実装から確認した実文言に厳密一致させた。起動ログ `path-overlap: route=flock-skip path-overlap visibility 開始`（`po_log` prefix `path-overlap:` + 経路識別子前置）、overlap 検出 `route=flock-skip overlap detected candidate=#<N> paths=... holders=...`（実装は `holders=${holders_for_log}` / holder なしは `holders=-`）、多重起動抑止 `route=flock-skip visibility skipped (別の可視化パスが進行中 lock=<lock_file>)` を README にそのまま転記した。
  - 「別インスタンス稼働（flock skip）時の対象範囲」注記は、従来「flock skip 中はそのインスタンスが何も評価しないためシグナルを残せない」だった記述を「`PATH_OVERLAP_CHECK=true` なら path-overlap 可視化パスだけは実行される」へ更新した。ただし flock skip 経路は read＋label/comment のみで claim/dispatch を行わないため、busy-wait（#228）の連続 tick カウントは実行しないことを明記し、可視化機構（path-overlap 可視化 #243 / busy-wait #228）の経路差を誤読されないよう書き分けた。
  - env var 表は既存 2 行（`PATH_OVERLAP_CHECK` / `PATH_OVERLAP_BUSY_WAIT_THRESHOLD`）と同一の 3 列書式（変数 / 既定 / 用途）で `PATH_OVERLAP_VISIBILITY_LOCK_FILE` を 1 行追加した。既定値は実装の `${PATH_OVERLAP_VISIBILITY_LOCK_FILE:-${LOG_DIR}/flock-skip-visibility.lock}` に合わせ `$LOG_DIR/flock-skip-visibility.lock` と表記。
- **残存課題**: なし。task 1〜5 がすべて完了し本 Issue の全 task を消化した。README はドキュメント変更のため build/test 不要（実装側 task 1〜4 が shellcheck + bash -n + スモークで検証済み）。flag 残存等の派生タスクなし（本機能は opt-in gate 配下の機能追加であり Feature Flag Protocol の対象ではない / CLAUDE.md に opt-in 宣言なし）。
