# 実装ノート — #364 stage-a-verify のパス不在 diff false-fail 防止

## 概要

(A) Architect 側の root-cause fix（`.claude/rules/tasks-generation.md` に「パス存在前提」節を追加）と
(B) stage-a-verify 側の defense-in-depth fix（`diff` の `exit=2` + `No such file or directory` を
WARN 降格扱い）を同一 PR で実装した。real なテスト/lint/shellcheck 失敗（exit=1 等）/ `diff` の
content 差分（exit=1）/ timeout（exit=124）の判定は従来どおり維持し、後方互換性を NFR 1.1 で
保証する。

## 変更したファイル

- `.claude/rules/tasks-generation.md` — 「構造化 verify ブロック」節に「パス存在前提」節を追加
  （Req 1.1〜1.5）。idd-claude 特有の注意（`repo-template/local-watcher/` 不在）と canonical な
  同期 diff 対象（`.claude/agents` / `.claude/rules` の 2 系統）、不確定パスへの存在ガード書式
  （`[ -d path ] && diff ...`）を canonical として規定
- `repo-template/.claude/rules/tasks-generation.md` — 上記と byte 一致で同期（CLAUDE.md
  「機能追加ガイドライン §4」）
- `local-watcher/bin/modules/stage-a-verify.sh`
  - 新規純粋関数 `_sav_is_path_missing_diff_failure(rc, stderr_text)`: exit=2 + stderr に
    `No such file or directory` + `diff:` 始まり行を全て満たす場合のみ 0 を返す（Req 2.1, 2.5, NFR 2.1）
  - 新規純粋関数 `_sav_extract_missing_path(stderr_text)`: stderr から `diff: <path>: No such
    file or directory` 形式の最初の path を抽出（Req 4.2）。grep 無マッチ時は空文字で安全 return
  - `stage_a_verify_run` の Execute ブロック修正:
    - stderr を `mktemp` 経由の一時ファイルに別捕捉（bash Process Substitution + tee）。同時に
      $LOG にも append して既存 grep 経路を維持（NFR 1.1）
    - rc 非 0 分岐の冒頭で `_sav_is_path_missing_diff_failure` を呼び、true なら
      WARN ログ 1 行（`reason=verify-path-missing path=<path> exit=$rc cmd=<quoted>`）+
      `_SAV_LAST_OUTCOME=warn-skipped` + return 0（Req 2.1〜2.3, 4.1〜4.3）
    - real fail（exit=1 等）/ diff content 差分 / timeout は従来分岐そのまま（Req 2.4, 3.1）
    - 連結コマンドの「real fail + path-missing 混在」は bash -c が real fail の exit code を
      返すため自然に従来 fail 経路に倒れる（Req 2.5）
  - `_SAV_LAST_OUTCOME` コメントに `warn-skipped` を追記（success と区別される run サマリ outcome）
- `local-watcher/test/stage_a_verify_path_missing_test.sh` — 新規追加テスト 43 ケース
  - Section 1: `_sav_is_path_missing_diff_failure` 単体（8 ケース / Req 2.1, 2.4, 2.5, 3.1, NFR 2.1）
  - Section 2: `_sav_extract_missing_path` 単体（4 ケース / Req 4.2）
  - Section 3: `stage_a_verify_run` 統合（31 ケース / Req 2.1〜2.5, 3.1, 3.2, 4.1〜4.4, NFR 1.1, 2.2(a)(b)(c)）
- `README.md`
  - 「失敗・異常系」節に WARN 降格挙動を追記（Req 2 全体 / NFR 3.1）
  - 「ログ grep 方法」節に WARN 降格 body 形式と filter 例を追記（Req 4.3）
  - run-summary `stage-a-verify` 列の enum に `warn-skipped` を追加（Req 4.4）
  - 「暫定 `STAGE_A_VERIFY_ENABLED=false` の撤去前提（#364 fix リリース後）」節を新規追加
    （Req 5.2）

## AC Traceability（requirements.md ↔ テスト）

| AC ID | 担保テスト |
|---|---|
| Req 1.1〜1.5（tasks-generation rule 明文化） | `.claude/rules/tasks-generation.md` / `repo-template/.claude/rules/tasks-generation.md` の追加節（`diff -r .claude/rules repo-template/.claude/rules` が空＝byte 一致同期確認済み） |
| Req 2.1 (exit=2 + ENOENT → WARN) | `_sav_is_path_missing_diff_failure` Case 1.1 / `stage_a_verify_run` Case 3.1 |
| Req 2.2 (round counter 不変 + 差し戻し / escalate なし) | Case 3.1 の `round counter 不変`・`mark_issue_failed 呼ばれない`・`gh issue comment 呼ばれない` 3 アサート |
| Req 2.3 (WARN ログに reason + path 記録) | Case 3.1 の `WARN log 1 行以上`・`reason=verify-path-missing 含む`・`検出パス含む` 3 アサート |
| Req 2.4 (real fail は従来挙動) | Case 1.3, 1.4, 1.5, 1.6, 3.2, 3.3, 3.5 |
| Req 2.5 (連結 real fail 優先) | Case 1.2, 3.6, 3.7（real fail 不在の連結は WARN 降格） |
| Req 3.1 (success path 不変) | Case 3.4 |
| Req 3.2 (DISABLED 既存挙動) | Case 3.5 |
| Req 3.3〜3.5 (env 名・既定値・解決順序不変) | 既存 `stage_a_verify_round1_defer_test.sh` 8 ケース・既存 stage-a-verify.sh の `stage_a_verify_resolve_command` 構造を改変していないことで担保 |
| Req 4.1 (WARN prefix ログ) | Case 3.1, 3.7 |
| Req 4.2 (cmd + 原因 stderr 含む WARN 行) | Case 3.1（cmd 断片と path 両方を含むことを assert） |
| Req 4.3 (grep 抽出可能性) | Case 3.1 の `grep '\[.*\] stage-a-verify: WARN'` 抽出アサート |
| Req 4.4 (run サマリ outcome 区別) | Case 3.1, 3.7 の `_SAV_LAST_OUTCOME=warn-skipped` アサート |
| Req 5.1 (README 反映) | README.md の追記 3 箇所 |
| Req 5.2 (撤去前提 doc 明示) | README.md「暫定 `STAGE_A_VERIFY_ENABLED=false` の撤去前提」節（本ファイル末尾「merge & deploy 後」節も参照） |
| Req 5.3 (撤去後の false-fail 不発生) | Case 3.1（fix 適用下でパス不在が WARN 降格＝false-fail にならない）+ Case 3.4（既存 success 不変） |
| NFR 1.1 (byte-equivalent な外部副作用) | Case 3.3, 3.4, 3.5 の既存挙動温存アサート |
| NFR 1.2 (stage_a_verify_run 戻り値契約 0/1/2 不変) | Case 3.1 (warn-skipped → 0), 3.2 (round1 → 1), 3.5 (disabled → 0)。round2→2 は既存 `stage_a_verify_round1_defer_test.sh` で担保 |
| NFR 1.3 (rule 既存規約破壊なし) | `_Requirements:_` / `_Boundary:_` / 構造化 verify ブロック等の既存節は触らず追加節のみ |
| NFR 2.1 (shellcheck / bash -n) | 検証結果欄を参照 |
| NFR 2.2(a) | Case 3.1 |
| NFR 2.2(b) | Case 3.2 |
| NFR 2.2(c) | Case 3.3 |
| NFR 2.3 (root↔repo-template byte 一致) | `diff -r .claude/rules repo-template/.claude/rules` 空（検証欄） |
| NFR 3.1 (README に挙動反映) | README.md 追記 3 箇所 |
| NFR 3.2 (rule byte 一致同期) | 同 NFR 2.3 |
| NFR 4.1〜4.2 (cron.log 観測性 / 固定 prefix) | Case 3.1 の WARN ログ assert |

## 検証結果（要約）

- `bash -n local-watcher/bin/modules/stage-a-verify.sh` → OK
- `shellcheck local-watcher/bin/modules/stage-a-verify.sh` → OK（警告ゼロ）
- `bash -n local-watcher/test/stage_a_verify_path_missing_test.sh` → OK
- `shellcheck local-watcher/test/stage_a_verify_path_missing_test.sh` → OK
- `bash local-watcher/test/stage_a_verify_path_missing_test.sh` → **PASS=43 / FAIL=0**
- `bash local-watcher/test/stage_a_verify_round1_defer_test.sh` → PASS（既存テスト不破壊）
- 全 `local-watcher/test/*_test.sh` を 1 回ずつ実行 → **ALL TESTS PASSED**（既存テスト不破壊）
- `diff -r .claude/agents repo-template/.claude/agents` → empty（byte 一致）
- `diff -r .claude/rules repo-template/.claude/rules` → empty（byte 一致）

## 設計判断

- **stderr 別捕捉の手法**: bash Process Substitution（`2> >(tee -a "$LOG" "$_stderr_path" >/dev/null)`）
  を採用。`mktemp` 失敗時は WARN 降格判定を skip し従来経路に倒す（fail-open）ことで、稀な mktemp
  失敗が gate 挙動を壊さないようにした。`wait` で Process Substitution の子孫終了を確実に待つことで、
  後続の `cat _stderr_path` が空を返す race condition を回避
- **判定の厳密化**: パス不在判定は (rc=2) ∧ (stderr に `No such file or directory`) ∧
  (stderr に `^diff:` 行) の 3 条件全てが必要。これにより、別コマンドが偶然 `exit=2` + ENOENT を
  返すケース（例: `cat: ...: No such file or directory` で別コマンドが exit=2）を WARN 降格対象から
  除外し、`diff` 自身のパス不在エラーだけに絞った
- **連結コマンドの解釈**: bash -c は連結全体の最終 exit code を返す。`exit 1 && diff ...` のような
  `&&` 連結で先頭が real fail した場合、bash -c は exit=1 を返し WARN 降格判定の rc=2 条件に
  マッチしないため自然に従来の round1/round2 経路に倒れる（Req 2.5）。逆に `true ; diff ...` の
  `;` 連結で末尾の path-missing が exit=2 を支配する場合は WARN 降格対象になる（real fail を
  含まない連結ケース）。これは Req 2.5 の「real fail を優先」原則を bash 標準の exit code 伝搬で
  自動的に満たす形になっており、追加の watcher 側パースは不要
- **WARN ログの 1 行集約**: reason / path / exit / cmd を 1 行にまとめた。複数行に分けると
  `grep` で並列抽出時に pairing miss が起きる可能性があるため、`reason=verify-path-missing
  path=... exit=... cmd=...` の固定キー順で 1 行にまとめた（NFR 4.2）
- **outcome `warn-skipped` の追加**: `_SAV_LAST_OUTCOME` の値域に `warn-skipped` を追加し、
  run-summary の `stage-a-verify=` 列で success と区別可能にした。これにより運用者が
  「false-fail 救済が連続発生する spec」を cron.log の run-summary 行から事後追跡できる（Req 4.4）。
  `rs_record_sav` は state 値を `RUN_SUMMARY_SAV` に格納するのみで enum check は無いため、
  新規 outcome をそのまま受理する（既存挙動と非干渉）

## merge & deploy 後の運用解除手順（DoD）

本 fix のリリース後、以下の手順で暫定運用を解除できる:

1. PR merge → `cd ~/.idd-claude && git pull && ./install.sh --local` で
   `$HOME/bin/modules/stage-a-verify.sh` を更新
2. 任意の Architect ルート（tasks.md に構造化 verify ブロックを持つ）spec で 1 サイクル稼働
   させ、`grep '\[.*\] stage-a-verify: WARN.*reason=verify-path-missing'
   $HOME/.issue-watcher/logs/<repo>/cron.log` で WARN 降格行が観測できることを確認
   （実際には Architect が tasks-generation rule に従って書けば WARN 降格は発生しないため、
   観測無しでも問題ない。観測無し = root-cause fix が機能して WARN 不要な状態）
3. 暫定で cron / launchd に入れていた `STAGE_A_VERIFY_ENABLED=false` を撤去
4. 撤去後の cron.log で `stage-a-verify: SUCCESS exit=0` または
   `SKIPPED reason=no-verify-task-in-tasks-md` 行が出ることを確認（gate がデフォルト有効に
   復帰し、false-fail も発生しない状態）

## 確認事項（推測せず残した点）

requirements.md の Open Questions に列挙されている以下 3 点は、本実装では安全側既定で処理した:

1. **WARN 降格時の round counter リセット要否** — 本実装では Req 2.2 に従い round counter を
   「触らない」（増やさない / 減らさない）。過去に real fail で round=1 まで進んでいた場合、
   その状態は WARN 降格を挟んでも温存される。これは「過去 round 状態をそのまま維持」する
   保守的設計。リセット要望が運用上発生した場合は別 Issue で議論
2. **連結コマンドの優先順位** — 本実装では bash -c の最終 exit code 伝搬に依拠した形で
   「real fail 優先」を実現した（Case 3.6, 3.7）。複雑な連結（複数 real fail と複数 path-missing
   の混在）でも、bash -c は最後に実行されたコマンドの exit code を返すため、末尾が real fail なら
   従来 fail 経路、末尾が path-missing で rc=2 ならば WARN 降格と判定する。これは仕様として
   一貫しているが、`||` 連結等で意図と異なる結果になり得る場合は運用ログで観測して別 Issue で議論
3. **パス不在検出の実装手段** — 本実装は事後判定（diff 実行後の exit=2 + stderr 解析）を採用。
   事前 scan（awk で `diff -r` の引数を抽出して `[ -d path ]` で先回り確認）は採用しなかった。
   理由: 事後判定は (a) 連結コマンドや変数展開を含む verify を構造解析せずに済む / (b) 実際の
   diff の挙動に依拠するため Architect 側のミスを正確に検出できる / (c) 将来 diff 以外の
   コマンドへの拡張余地を残せる（現在は diff のみ Req 範囲 / Out of Scope）

## STATUS

STATUS: complete
