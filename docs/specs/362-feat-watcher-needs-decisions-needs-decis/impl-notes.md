# Implementation Notes

## Implementation Notes

### Task 1

- 採用方針: `FULL_AUTO_ENABLED` 正規化直後（行 132 直後）に `NEEDS_DECISIONS_MODE` Config block を追加し、cycle startup ログ（行 981）末尾に `needs-decisions-mode=${NEEDS_DECISIONS_MODE}` を追記した。既存 `AUTO_REBASE_MODE` の `case ... esac` パターン（3 値以外を安全側 fallback）を踏襲。
- 重要な判断:
  - 正規化 case の `*)` フォールバックは `all-human` 固定（NFR 1.1 / Req 1.5 安全側）。
  - cycle startup ログは **末尾追記のみ**で既存 grep（`base-branch=` / `full-auto=` 等）を破壊しない（NFR 1.1 / Req 6.4）。
  - 既存 `FULL_AUTO_ENABLED` ブロックの「デフォルト有効化フラグの値正規化」ループに加えず、独立した case 文で正規化する（`FULL_AUTO_ENABLED` の opt-in 制を踏襲）。
  - 配置コメントには Req 1.1〜1.6 / NFR 1.1 / 6.4 への参照を含め、`FULL_AUTO_ENABLED` との AND 二重 opt-in 関係を明示。
- 残存課題: なし（task 2 以降の module 実装 + 配線で本機能の挙動を完成させる）。
- スモーク検証: `bash -n` / `shellcheck` pass。`awk` で Config block を抽出して `env -i` 配下で評価し、7 パターン（unset / 空 / `auto` / `Classified` / `all-human` / `classified` / `all-auto`）について期待通りの正規化結果（不正値はすべて `all-human`、正規値 3 種はそのまま）を確認。

### Task 2

- 採用方針: `local-watcher/bin/modules/needs-decisions-auto.sh` を新規 module として追加し、全 8 関数（`nda_log` / `nda_warn` / `nda_error` / `nda_resolve_mode_enabled` / `nda_extract_classification` / `nda_extract_first_recommendation` / `nda_auto_continue` / `nda_evaluate_auto_continue`）を 1 ファイルに集約。既存 `auto-merge.sh` / `failed-recovery.sh` の冒頭コメント形式・3 段 prefix ロガー・`set -euo pipefail` 不宣言（本体側で宣言済）・関数定義のみ（トップレベル副作用ゼロ）を踏襲した。
- 重要な判断:
  - `nda_extract_classification` の jq は `decisions == null / 非 array / length=0` の 3 ケースを冒頭で畳んで "human-only" に倒し、その後 `any(. == "human-only")` → `all(. == "safe")` → else "human-only" の優先順で評価する（Req 4.5 混在ケースの安全側倒し + Req 4.4 欠落/不明値の fail-safe を 1 つの jq 式で表現）。値の sanitize は `--arg` 不要（外部入力を jq filter に inline 展開しないため）。
  - `nda_auto_continue` は design.md「Halt fallback の順序」節に厳密準拠し、(1) comment → (2) label remove の順で実行し、(1) 失敗時は (2) を skip。「コメント不在 + claude-claimed 除去済」オーファン状態（次サイクルで再 pickup されるが監査ログなし）を回避。`gh issue comment --body` に渡す本文は heredoc で組み立て、`bash -c` / `eval` には流さない（NFR 4.1）。
  - `nda_evaluate_auto_continue` の判定順序は kill switch → mode → classification → recommendation の 4 段で、kill switch 段で先に止めることで API 呼び出しゼロを保証（NFR 1.1）。各段の halt ログには `cause=<理由>` を含めて grep 可能にした（Req 6.x）。
  - ファイル不在は `[ ! -f ]` で早期 fail-safe（jq に渡る前に "human-only" / rc=1 へ倒す）。`tr` 使用は recommendation 先頭 80 文字を 1 行ログに収めるための改行→空白置換のみで、shellcheck 警告ゼロ。
- 残存課題: なし。task 3 で本体配線（REQUIRED_MODULES 登録 + Triage 結果ハンドラ分岐）、task 4 で triage-prompt.tmpl の classification field 追加、task 6 で `extract_function` イディオムを用いた本格 unit test を追加する想定（本 task では関数定義のみ。partial 明示済の AC のテストは task 6 で集約解消）。
- スモーク検証: `bash -n local-watcher/bin/modules/needs-decisions-auto.sh` / `shellcheck local-watcher/bin/modules/needs-decisions-auto.sh` 双方 pass。`/tmp/nda-smoke/` で module を source し、(a) `nda_resolve_mode_enabled` 7 パターン、(b) `nda_extract_classification` 10 パターン（safe / human-only / 混在 / 欠落 / null / 空配列 / 不正 JSON / 不在 file / decisions key 不在 / decisions null / decisions 非配列）、(c) `nda_extract_first_recommendation` 5 パターン（正常 / null / 空 / 配列空 / file 不在）、(d) `nda_evaluate_auto_continue` 3 シナリオ（kill OFF halt / kill ON+safe+rec 自動続行 rc=0 / kill ON+human-only halt）、(e) `nda_auto_continue` の gh comment 失敗 / gh edit 失敗の 2 経路、をすべて期待通り観測。
