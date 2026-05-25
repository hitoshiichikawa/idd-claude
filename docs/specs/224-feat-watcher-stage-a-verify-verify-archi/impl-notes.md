# Implementation Notes

本ファイルは Developer が per-task ループで追記する実装補足。各 task の採用方針・
重要判断・残存課題・確認事項を記録する。

## Implementation Notes

### Task 1

- **採用方針**: `local-watcher/bin/modules/stage-a-verify.sh` に純関数
  `stage_a_verify_extract_verify_block` を新設。センチネル `<!-- stage-a-verify -->`
  直後の fenced code block を awk 状態機械（state 0/1/2）で厳密パースし、well-formed
  なブロック中身を改行・インデント込みで stdout に出力する。

- **重要な判断**:
  - センチネル直後性は awk の `state==1` で表現。アンカー検出後、空行は任意個スキップし、
    最初の非空行が fence 開始（trim 後 ` ``` ` 始まり）でなければ `done_flag=1` で打ち切り
    （malformed → 中身を出さず END で return 1 相当）。fence 以外の非空行が先に来るケースを
    確実に malformed 化できる。
  - 中身保持は fence 内行を `raw`（trim 前）のまま `buf` に `\n` 区切りで蓄積し、END で
    `printf "%s\n", buf` 出力。`&&` 連結・行継続 `\`・インデントの意味を壊さない（Req 1.4）。
  - malformed 時の return 契約は「stdout 空 + return 1」で統一。well-formed 条件は
    `closed && nonblank`（fence が閉じ、かつ中身に trim 後非空行が 1 行以上）の AND で判定。
    未クローズ（EOF まで `closed=0`）・空ブロック（`nonblank=0`）はいずれも出力しない。
  - 決定論性は最初のブロック処理完了後 `done_flag=1` を立て以降の入力を無視することで担保
    （複数アンカー+fence は最初の 1 つのみ採用、NFR 3.1）。
  - 既存 `stage_a_verify_extract_command` の awk 流儀（`raw`/`line` 変数命名、`^[[:space:]]*```` の
    fence 判定、コメント密度）に合わせ、既存 awk を拡張せず独立関数として分離した
    （抽出基準が「行頭 keyword 一致」と「センチネル + fence 構造」で根本的に異なるため）。

- **検証結果**:
  - `shellcheck local-watcher/bin/modules/stage-a-verify.sh` 警告ゼロ。
  - アドホックスモークで 10 境界を確認（well-formed 単一行 / multiline+`&&` / ` ```sh ` 言語タグ /
    センチネル+fence 無し / 未クローズ / 空ブロック / 複数ブロック→先頭のみ / tasks.md 不在 /
    空行スキップ後 fence / センチネル前後空白+インデント保持）。すべて設計契約どおり
    （well-formed=rc 0・中身出力 / malformed・無し=rc 1・stdout 空）。
  - `git diff` で本変更が 109 行追加のみ・削除行ゼロであることを確認。`extract_command` /
    `resolve_command` / `_sav_cmd_starts_with_keyword` / `stage_a_verify_run` は無変更で既存挙動を温存。

- **残存課題（次 task に影響する事項）**:
  - resolve への組み込み（4 段連鎖の第 1 段化）は **task 2.1** の担当。本 task では
    `stage_a_verify_resolve_command` は無変更。
  - 構造化ブロック由来コマンドの Gate 3 bypass（`_SAV_RESOLVED_SOURCE` 共有）は **task 2.2** の担当。
  - 抽出ロジックの正式 fixture 群 + smoke script（`test-fixtures/`）は **task 6.1** の担当。
    本 task のスモークはアドホックで commit には含めていない。

### 是正対応（Reviewer round=1 reject 後）

Reviewer round=1 は「Task 1.1 の抽出関数は実装済みだが orphan（`resolve_command` から
未呼び出し）で、Task 2〜6 が未実施」として reject した（Findings 1〜5）。以下のとおり
各 Required Action を実装し、観測可能挙動・規約・文書・テストを揃えた。

- **Finding 1（Task 2.1）— resolve 4 段連鎖化**: `stage_a_verify_resolve_command` を
  「構造化ブロック → `STAGE_A_VERIFY_COMMAND` → heuristic → SKIPPED」の 4 段 fallback へ変更。
  第 1 段で `stage_a_verify_extract_verify_block` 成功時に短絡採用（以降を試さない）。各段で
  `sav_log "resolve source=<手段>"` を stderr に出し、stdout はコマンド本体のみに保つ
  （複数行コマンドをそのまま返せる）。design-less impl（tasks.md 不在）は第 1/第 3 段が
  return 1 → 既存の env→SKIPPED 順序に一致（後方互換、Req 2.5 / NFR 1.1）。

- **Finding 1（Task 2.2）— Gate 3 bypass を structured-block へ拡張**: `stage_a_verify_run`
  の Gate 3 を「`STAGE_A_VERIFY_COMMAND` 非空 **または** source=structured-block」のとき
  bypass に拡張。heuristic 経路の `_sav_cmd_starts_with_keyword` 行頭一致は従来どおり維持。
  `bash -c` 受け渡し・失敗ハンドラ・round counter・exit code・ログ契約は無変更（NFR 1.4）。

  - **重要な判断（サブシェル境界の補強）**: design.md「Decision: source の stage_a_verify_run
    への伝達方法」採用案はモジュールスコープ変数 `_SAV_RESOLVED_SOURCE` の共有を想定するが、
    `stage_a_verify_run` は resolve を command substitution（`cmd=$(stage_a_verify_resolve_command)`）
    で呼ぶため、サブシェル内の変数代入は親プロセス（run）へ伝播しない。そこで設計意図を保ちつつ
    実機で成立させるため、既存 round counter sidecar（`.stage-a-verify-round`）と同一流儀の
    source sidecar（`.stage-a-verify-source`）を併用する。resolve が確定 source をモジュール変数
    （同一プロセス内呼び出し用）と sidecar（サブシェル越え用）の双方へ書き、run は
    `_sav_read_resolved_source` で読み戻して Gate 3 判定に使う。sidecar は resolve 冒頭で
    毎回リセットし、前回の残値で誤 bypass しない。sidecar 書き込み失敗は致命とせず、
    Gate 3 が heuristic 同様の defense-in-depth に倒れる安全側設計（`sav_warn` 止まり）。

- **Finding 2（Task 3.1 / 3.2）— 規約・プロンプト明文化**: `.claude/rules/tasks-generation.md`
  に「構造化 verify ブロック」節（センチネル `<!-- stage-a-verify -->` + 直後 fence の canonical
  書式、実行可能コマンド必須、checkbox/budget regex 非干渉、省略可、配置推奨）を追加。
  `.claude/agents/architect.md` の tasks.md テンプレ節に宣言例と「Developer はブロックを
  書き換えない／矛盾は PR 確認事項で指摘」する信頼モデルを追記（Req 3.1〜3.3, 4.1〜4.4, 1.3）。

- **Finding 3（Task 4.1）— well-formed Mechanical Check**: `.claude/rules/design-review-gate.md`
  に「verify block well-formed check」節を既存 Mechanical Checks と同一構造で追加。well-formed
  判定（センチネル存在／直後 fence／fence 閉じ／中身非空）を参照実装として明記し、モジュール側
  awk（`stage_a_verify_extract_verify_block`）と同一基準である旨の相互参照を置いた。適用範囲は
  新規生成 tasks.md に限定（既存 spec は遡及違反としない、Req 5.4）。Req 5.3（verify 対象あり
  +ブロック/env 両無）は warn 止まり（reject しない）と規定。

- **Finding 4（Task 5.1）— README**: 「Stage A Verify Gate (#125)」節に解決順序
  「構造化ブロック → `STAGE_A_VERIFY_COMMAND` → heuristic → SKIPPED」を追記し、構造化ブロックを
  第一手段、env を散文誤認回避の固定 escape hatch と位置づけた。`STAGE_A_VERIFY_COMMAND` の
  用途文言を「最優先で実行」から「ブロック不在時に参照する固定 escape hatch」へ修正し
  migration note を併記。env var 名・既定値は不変であることを文書上も保証（Req 6.1〜6.3, NFR 1.3）。

- **Finding 5（Task 6.1）— fixture + smoke**: `test-fixtures/` に 8 fixture
  （well-formed / multiline / lang-tag / multiple / no-fence / unclosed / empty / no-block-heuristic）
  と smoke script `test-extract.sh`（tasks.md の Verify ブロックが参照するパス名と一致）を追加。
  各 fixture の期待抽出コマンド・return code と、resolve の 4 段 fallback（structured-block の
  env 優先・env-command・heuristic・SKIPPED）を assert（全 14 ケース pass）。`shellcheck
  --severity=warning local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh` は警告ゼロ。

- **Task 6.2（deferrable `- [ ]*`）**: Gate 3 bypass 専用の回帰スモークは optional のため
  本是正では未追加（checkbox は `- [ ]*` のまま）。structured-block の Gate 3 bypass 自体は
  Task 6.1 smoke の resolve ケース（source=structured-block 判定）で間接的に確認済み。

- **検証結果**: `shellcheck --severity=warning`（issue-watcher.sh + modules/*.sh）警告ゼロ。
  `bash docs/specs/224-feat-watcher-stage-a-verify-verify-archi/test-fixtures/test-extract.sh`
  で全 14 ケース pass。tasks.md の Verify ブロックコマンド（shellcheck && test-extract.sh）が
  手元で exit 0 を返すことを確認。既存テスト・既存 `stage_a_verify_extract_command` /
  `_sav_cmd_starts_with_keyword` の挙動は無変更（後方互換維持）。

- **確認事項**: なし（requirements.md / design.md / tasks.md の内容は不変。tasks.md は
  checkbox 更新のみ）。
