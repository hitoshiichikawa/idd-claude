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

### Task 3

- 採用方針: `REQUIRED_MODULES` 配列末尾に `needs-decisions-auto.sh` を追加（順序は機能的に任意。既存 `failed-recovery.sh` の隣で可読性も担保）。Triage 結果ハンドラ（`if [ "$STATUS" = "needs-decisions" ] && [ "$DECISION_COUNT" -gt 0 ]; then` ブロック、`local-watcher/bin/issue-watcher.sh:10519` 直後）の **冒頭**で `nda_evaluate_auto_continue "$TRIAGE_FILE"` を呼び、rc=0（auto-continue 成功）の場合は `slot_log` 1 行 + 即 `return 0` で既存処理を **すべて** skip。
- 重要な判断:
  - rc=0 経路では既存の `COMMENT` 組み立て + `gh issue comment` + `gh issue edit --remove-label "$LABEL_CLAIMED" --add-label "$LABEL_NEEDS_DECISIONS"` + `echo "🟡 #..."` + `slot_log "Triage 結果: needs-decisions"` + `return 0` の **全部**を skip する。これにより Issue は `needs-decisions` ラベル不付与 + `claude-claimed` 除去済（nda_auto_continue 内で除去）の状態となり、次サイクルで dispatcher の `gh issue list -label:"$LABEL_NEEDS_DECISIONS"` フィルタを通過して再 pickup される（design.md NFR 1.2「新規 pickup 経路を作らない」/ Req 3.3）。
  - rc=1 経路では分岐に **何も追加せず**そのまま既存の `COMMENT` 組み立てフローへ流す（本機能導入前と byte-equivalent / NFR 1.1, 1.3）。`local COMMENT` 宣言を nda 呼び出し後に置く形にして既存ロジックを破壊しないようにした。
  - `slot_log` メッセージには「#362」「auto-continue」「claude-claimed 除去済・次サイクル再 pickup 待機」を含め、grep ベースの運用観測（`grep auto-continue` / `grep "#362"`）を可能にした。`nda_log` 側で既に `action=auto-continue` が記録されるが、`slot_log` 経由のサイクル単位ログにも明示することで運用者の追跡コストを下げる狙い。
  - 配線位置の選択は design.md「Watcher Body Call Site」節に厳密準拠。`PATH_OVERLAP_CHECK` 永続化処理（行 10509-10517）の **後**かつ既存 needs-decisions 分岐の **冒頭**で呼ぶことで、edit_paths sticky comment 永続化（Req 3.4 fail-open）と本機能の auto-continue 判定が独立して動作することを保証。
- 残存課題: なし。task 4（triage-prompt.tmpl の classification field 追加）と task 5（PM agent 定義）が揃えば本機能の E2E 経路が完成する。task 6 で本配線（rc=0 / rc=1 双方）の AND 二重 opt-in を `extract_function` イディオムで unit test に集約予定（task 3 の `_Requirements_partial:_` 解消）。
- スモーク検証: `bash -n local-watcher/bin/issue-watcher.sh` / `shellcheck local-watcher/bin/issue-watcher.sh` 双方 pass。`module_loader_missing_test.sh` 7 件全 PASS（needs-decisions-auto.sh を欠落させた場合に loader が同様に検出することを別途確認）。`full_auto_enabled_test.sh` 28 件全 PASS（kill switch との依存に regression なし）。

### Task 4

- 採用方針: `triage-prompt.tmpl` の「## 「致命的に人間の判断が必要」と判定する基準（status 判定）」節（行 23-35）と「## 「Architect を挟むべき」と判定する基準（needs_architect 判定）」節（行 65 以降）の **間**に「## 分類タグ（classification）の判定基準」節を新規追加し、出力 JSON スキーマ（`decisions[]` 要素）に `"classification": "safe" | "human-only"` フィールドを `recommendation` の直後に追記（design.md 行 397-417 の JSON Contract に厳密準拠 / NFR 1.2）。スキーマ直後の補足箇条書きに `status = "needs-decisions"` 時は必須・`status = "ready"` 時は decisions 空配列なので出現余地なしの 1 行を追加した。
- 重要な判断:
  - 新規節の構成は (1) 概要 1 段落、(2) `human-only` の定義（4 カテゴリの bullet list）、(3) `safe` の条件（1 段落）、(4) fail-safe（最重要 / 確信が持てない場合は必ず human-only）の 4 サブセクションで固定。design.md「判定基準（triage-prompt.tmpl への追記内容）」節（行 427-435）と requirements.md Req 2.1〜2.5 / NFR 4.1 に 1:1 対応する記述順にした。`human-only` の 4 カテゴリ（機密 / コンプラ / 不可逆 / 外部影響）は design.md と完全に同一文言で列挙し、Architect の判断と Triage agent / PM agent の判断が一致するように字面を揃えた。
  - JSON スキーマの `classification` 追加位置は `recommendation` の直後（最末尾）。既存 5 fields（`topic` / `question` / `options` / `impact` / `recommendation`）の **位置・型・意味は不変**（NFR 1.2 / Req 5.1）。直前の `recommendation` 行末に `,` を追加して JSON 構文を維持。
  - 既存「- `status` が `ready` の場合、`decisions` は空配列にすること」箇条書きの **直下**に `classification` 必須性の説明を 1 行追加した。同レベルの箇条書きに並べることで Triage agent / PM agent が `decisions` 空 ↔ 非空の両ケースを並列に認識できる。
  - prompt template の挙動検証は LLM 側の応答品質に依存するため近接 unit test は不要（tasks.md 行 118 に明示）。本 task では構文整合（JSON 括弧バランス、コメント記法、既存節との位置関係）の目視確認のみで完結させ、E2E スモークは task 7 / 8 完了後の手動検証に委ねる。
  - `repo-template/local-watcher/bin/triage-prompt.tmpl` は **本 task で触らない**（task 8 の root↔repo-template 同期で別途処理）。
- 残存課題: なし。task 5（PM agent 定義の classification 出力責務追記）が揃えば PM 段の出力規約も完成する。
- スモーク検証: 編集後の `triage-prompt.tmpl` を目視確認し、(a) JSON スキーマの `{` / `}` / `[` / `]` の括弧バランスが取れていること、(b) `"classification": "safe" | "human-only"` が `recommendation` の直後に **カンマ区切り**で配置され、`decisions[]` 要素の最末尾 field となっていること、(c) 新規節「## 分類タグ（classification）の判定基準」が既存 status / needs_architect 判定節の **間**に位置し、見出し階層（`##` / `###`）が既存節と整合していること、(d) 補足箇条書きで `status = "needs-decisions"` 時の必須性と `status = "ready"` 時の出現余地なしを明示できていること、を確認した。
