# Implementation Plan

- [x] 1. 構造化 verify ブロック抽出関数の新設（stage-a-verify.sh）
- [x] 1.1 `stage_a_verify_extract_verify_block` を新設し、センチネル直後 fence を厳密パースする
  - センチネル `<!-- stage-a-verify -->` のアンカー行検出（trim 後の厳密一致）
  - アンカー直後（空行スキップ後）の最初の非空行が fence 開始でなければ malformed → return 1
  - fence 言語タグ（` ```sh ` / ` ```bash ` 等）を読み飛ばし中身のみ抽出
  - fence 未クローズ（EOF まで閉じない）/ 中身が空（trim 後すべて空）は malformed → return 1
  - well-formed なら fence 中身を改行・インデント込みでそのまま stdout に出力（複数行 / `&&` 保持）
  - 複数アンカー+fence がある場合は最初の 1 つのみ採用（決定論）
  - `tasks.md` 不在は return 1（ブロック無扱い）。副作用なし（書き換えない）
  - awk は POSIX ERE で記述し既存 `extract_command` の流儀に合わせる
  - モジュールヘッダコメントの用途リストに新関数を追記
  - _Requirements: 1.1, 1.4, 1.5, NFR 3.1, NFR 3.2, NFR 4.1_
  - _Boundary: stage_a_verify_extract_verify_block_

- [x] 2. resolve 順序の 4 段連鎖化と source ログ（stage-a-verify.sh）
- [x] 2.1 `stage_a_verify_resolve_command` を 4 段 fallback 連鎖へ変更する
  - 第 1 段 `extract_verify_block` 成功 → 採用（source=structured-block）し以降を試さない（短絡）
  - 第 2 段 `STAGE_A_VERIFY_COMMAND` 非空 → 採用（source=env-command）
  - 第 3 段 `extract_command`（heuristic）成功 → 採用（source=heuristic）
  - いずれも不可 → return 1（SKIPPED）
  - 解決手段名を `sav_log` で `source=<手段>` の 1 行に出力（stdout はコマンド本体のみに保つ）
  - design-less impl（tasks.md 不在）は第 1/第 3 段が return 1 → 既存の env/SKIPPED 順序に一致
  - 構造化ブロック無しの既存 spec が従来どおり env/heuristic に到達することを確認（後方互換）
  - _Requirements: 1.2, 2.1, 2.2, 2.3, 2.4, 2.5, NFR 1.1, NFR 2.1, NFR 2.2_
  - _Boundary: stage_a_verify_resolve_command_
  - _Depends: 1.1_

- [x] 2.2 構造化ブロック由来コマンドの Gate 3 bypass を `stage_a_verify_run` に組み込む
  - resolve が解決手段をモジュールスコープ変数（`_SAV_RESOLVED_SOURCE`）へ記録
  - `stage_a_verify_run` の Gate 3 を「env 非空 または source=structured-block」のとき bypass に拡張
  - heuristic 経路の defense-in-depth（keyword 行頭一致）は従来どおり維持
  - `bash -c` へのコマンド受け渡し・失敗ハンドラ・round counter・exit code は無変更
  - _Requirements: 1.4, NFR 1.2, NFR 1.4_
  - _Boundary: stage_a_verify_run, stage_a_verify_resolve_command_
  - _Depends: 2.1_

- [x] 3. tasks-generation ルールへ構造化 verify ブロック規約を追加
- [x] 3.1 `.claude/rules/tasks-generation.md` に「構造化 verify ブロック」節を追加する
  - センチネル `<!-- stage-a-verify -->` + 直後 fence の canonical 書式を定義
  - 中身は散文ではなく実行可能コマンド（複数行 / `&&` 可）であることを要求
  - 既存 checkbox 規約・numeric ID 階層規約と非干渉（ブロックはタスク行でなく count/checkbox regex に非マッチ）であることを明記
  - verify 対象が無い spec はブロック省略可（heuristic/env/SKIPPED に倒れる）旨を記載
  - 配置場所の推奨（`## Verify` 見出し配下等、見出しは任意）を例示
  - _Requirements: 4.1, 4.3, 4.4, 1.3, 3.1_
  - _Boundary: tasks-generation rule_

- [x] 3.2 `.claude/agents/architect.md` の tasks.md テンプレに verify ブロック宣言手順を追記 (P)
  - tasks.md テンプレ節に構造化 verify ブロックの宣言例を追加
  - Developer はブロックを書き換えない / 矛盾は PR「確認事項」で指摘する信頼モデルを明記
  - _Requirements: 4.2, 3.2, 3.3_
  - _Boundary: architect.md_
  - _Depends: 3.1_

- [x] 4. design-review-gate に well-formed Mechanical Check を追加
- [x] 4.1 `.claude/rules/design-review-gate.md` に「verify block well-formed check」節を追加する (P)
  - 既存 Mechanical Checks（Budget overflow / checkbox enforcement）と同じ節構造で追加
  - well-formed 判定（センチネル存在 / 直後 fence / fence 閉じ / 中身非空）を参照実装として明記し、モジュール側 awk と同一基準である旨の相互参照を置く
  - malformed 検出時は違反報告し確定前修正を促す（最大 2 パス）
  - 適用範囲を新規生成 tasks.md に限定し既存 spec を遡及違反としない
  - Req 5.3（verify 対象あり+ブロック/env 両無）は warn 止まり（reject しない）と規定
  - _Requirements: 5.1, 5.2, 5.3, 5.4_
  - _Boundary: design-review-gate rule_
  - _Depends: 3.1_

- [x] 5. README へ解決順序と escape hatch 位置づけを文書化
- [x] 5.1 README の「Stage A Verify Gate (#125)」節を更新する
  - 解決順序「構造化ブロック → STAGE_A_VERIFY_COMMAND → heuristic → SKIPPED」を追記
  - 構造化ブロックを第一手段として説明し、env を散文誤認回避の固定用途 escape hatch と位置づけ
  - env var 表の `STAGE_A_VERIFY_COMMAND` 用途文言を「最優先で実行」から「ブロック不在時に参照する固定 escape hatch」へ修正し migration note を併記
  - env var 名・既定値（`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` / `STAGE_A_VERIFY_COMMAND`）は変更しないことを文書上も保証
  - 状態遷移 Mermaid に解決手段分岐を追記
  - _Requirements: 6.1, 6.2, 6.3, NFR 1.3_
  - _Boundary: README_
  - _Depends: 2.1_

- [x] 6. fixture + smoke script による抽出ロジックの境界回帰確認
- [x] 6.1 `test-fixtures/` と smoke script を追加し抽出ロジックを回帰確認する
  - 8 fixture を追加（well-formed / multiline / lang-tag / multiple / no-fence / unclosed / empty / no-block-heuristic）
  - smoke script で各 fixture の期待抽出コマンドと return code を assert（#131/#160 慣習踏襲）
  - 既存 #160 heuristic fixture が同一結果を返す回帰（NFR 1.1）を smoke で確認
  - `shellcheck local-watcher/bin/modules/stage-a-verify.sh` 警告ゼロを確認
  - _Requirements: 5.1, NFR 1.1, NFR 3.1_
  - _Boundary: stage_a_verify_extract_verify_block, stage_a_verify_resolve_command_
  - _Depends: 1.1, 2.1_

- [ ]* 6.2 Gate 3 bypass の回帰スモークを追加
  - 構造化ブロック由来コマンドが keyword 非該当でも実行される経路を fixture で確認
  - _Requirements: 1.4, NFR 1.4_

## Verify

本 spec の実装後、watcher が再実行すべき verify コマンドを以下の構造化ブロックで宣言する。

<!-- stage-a-verify -->
```sh
shellcheck --severity=warning local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh && bash docs/specs/224-feat-watcher-stage-a-verify-verify-archi/test-fixtures/test-extract.sh
```
