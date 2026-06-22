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

### Task 5

- 採用方針: `.claude/agents/product-manager.md` の「# Triage モードで呼ばれた場合」節（行 120-124）末尾に空行 1 行を挟んで 7 行の classification 出力責務段落を追記した（要件レンジ 5-8 行内）。詳細判定基準は重複記載せず `triage-prompt.tmpl` を canonical 参照する形に統一し、本ファイルは summary + canonical 参照に留めた（NFR 2.3）。
- 重要な判断:
  - 追記内容の構成は (1) `status = "needs-decisions"` 時の `classification: "safe" | "human-only"` **必須**出力、(2) `human-only` の 4 カテゴリ（機密 / コンプラ / 不可逆 / 外部影響）の概略列挙 + `safe` の条件、(3) 詳細判定基準は `triage-prompt.tmpl` 側 canonical 参照、(4) fail-safe（確信が持てない場合は **必ず** `human-only`）の 4 点で固定。design.md 行 437-450「PM agent 定義の拡張」節と requirements.md NFR 2.3 に 1:1 対応する記述順にした。
  - `triage-prompt.tmpl` への参照リンクは agent ファイル（`.claude/agents/product-manager.md`）からの相対パス `[triage-prompt.tmpl](../../local-watcher/bin/triage-prompt.tmpl)` を使用。実在パス（`/home/hitoshi/.issue-watcher/worktrees/hitoshiichikawa-idd-claude/slot-1/local-watcher/bin/triage-prompt.tmpl`）を事前確認した上で `[`triage-prompt.tmpl`](../../local-watcher/bin/triage-prompt.tmpl)` の markdown link 形式で配置し、リンク自体は markdown 構文準拠（fence 内バッククォート + 外側 `[]()` リンク）にした。
  - フィールド名（`classification` / `safe` / `human-only` / `decisions` / `status` / `needs-decisions`）は CLAUDE.md「言語方針」に従って英語固定とし、説明文は日本語ベースで既存「# Triage モードで呼ばれた場合」節の文体（「〜してください」体）に合わせた。
  - `repo-template/.claude/agents/product-manager.md` は **本 task で触らない**（task 8 の root↔repo-template 同期で別途処理 / CLAUDE.md「機能追加ガイドライン § 4」）。
- 残存課題: なし。task 6（近接 unit test 集約解消）/ task 7（README 更新）/ task 8（root↔repo-template 同期）の後続で本機能の E2E 経路と配布形態が完成する。
- スモーク検証: 編集後の `.claude/agents/product-manager.md` を目視確認し、(a) 追記内容が 7 行（126-132 行）で要件レンジ 5-8 行内に収まっていること、(b) 既存節「# Triage モードで呼ばれた場合」の末尾に空行 1 行を挟んで配置され見出し階層（`#`）が崩れていないこと、(c) canonical 参照 `[triage-prompt.tmpl](../../local-watcher/bin/triage-prompt.tmpl)` が明示され実在パスを指していること、(d) fail-safe（確信が持てない場合は **必ず** `human-only`）が明示されていること、(e) 詳細判定基準の重複記載がなく `human-only` 4 カテゴリは概略列挙に留まっていること、を確認した。markdown lint レベル（h1 1 箇所のみ / コードフェンス整合 / リンク構文整合）も保持。

### Task 6

- 採用方針: `local-watcher/test/needs_decisions_auto_test.sh` を新規作成。既存 `full_auto_enabled_test.sh` / `auto-merge_test.sh` の `extract_function` イディオム（awk による単一関数切り出し + eval + stub）を踏襲し、nda モジュールの全 8 関数（`nda_log` / `nda_warn` / `nda_error` / `nda_resolve_mode_enabled` / `nda_extract_classification` / `nda_extract_first_recommendation` / `nda_auto_continue` / `nda_evaluate_auto_continue`）と本体 `full_auto_enabled`（#348）を抽出して隔離 evaluate。本体 Config block の正規化挙動も `awk` で `NEEDS_DECISIONS_MODE=` 開始から `esac` までを抽出し `env -i` 配下で snippet 評価する 2 段構成（task 1 partial 解消の AC 1.5 確実なカバレッジのため）。
- 重要な判断:
  - 8 セクション構成は tasks.md `_Requirements_partial:_` の解消を全網羅する設計順序にした: Section 1 (`nda_resolve_mode_enabled` / Req 1.5, NFR 3.3 / task 1, 2.2 partial) → Section 2 (本体 Config block / task 1 partial の 1.5 完全カバー) → Section 3 (`nda_extract_classification` fail-safe / Req 2.4, 2.5, 4.4, 4.5, NFR 4.2 / task 2.2 partial) → Section 4 (`nda_extract_first_recommendation` / Open Question (b)) → Section 5 (`nda_auto_continue` 3 経路 / Req 3.3, 3.4 / task 2.3 partial) → Section 6 (kill OFF / mode=all-human halt / Req 5.2, 5.3, NFR 1.1 / task 2.4 partial) → Section 7 (AND 二重 opt-in / Req 3.1, 3.2, 5.4 / task 2.4, 3 partial) → Section 8 (human-only halt hard boundary / Req 4.1, 4.2, 4.3, 4.5, NFR 4.2 / task 2.4, 3 partial)。
  - `nda_auto_continue` のヒアドキュメント (`body=$(cat <<EOF ... EOF)`) を含む関数本体を `extract_function` で正常に抽出可能であることを事前確認した。awk の終端条件 `$0 == "}"` がヒアドキュメント内に出現しないことを `grep '^}$'` で検証（モジュール側の `}` 行は関数境界の 8 箇所のみ、ヒアドキュメント本文は `${var}` 形式 interpolation のみで standalone `}` 行を含まない）。
  - gh stub は `GH_COMMENT_FAIL` / `GH_EDIT_FAIL` の 2 つのグローバルフラグで `gh issue comment` / `gh issue edit` の挙動を制御可能にし、Section 5 の 3 経路（comment 失敗 / edit 失敗 / 全成功）を 1 つの stub で網羅。`nda_log` / `nda_warn` / `nda_error` も stub で `LOG_LOG` / `WARN_LOG` ファイルへ記録し、`count_logs` / `count_warns` / `count_calls` の 3 ヘルパで grep ベースの観測を統一（既存 `full_auto_enabled_test.sh` の `count_calls` パターンを踏襲）。
  - Section 2 の本体 Config block 隔離 evaluate は `env -i HOME="$HOME" PATH="$PATH" NEEDS_DECISIONS_MODE="$input_val" bash -c "$snippet"` 形式で外部環境変数の影響を排除。`unset` ケースは `NEEDS_DECISIONS_MODE` 引数自体を渡さないことで `${NEEDS_DECISIONS_MODE:-all-human}` の fallback path を確実にテスト。
  - shellcheck の SC2034 警告（`REPO` / `LABEL_CLAIMED` 等の indirect 参照変数）は既存 `full_auto_enabled_test.sh` / `auto-merge_test.sh` と同等の警告水準で残置。stage-a-verify gate の verify block は `local-watcher/bin/modules/needs-decisions-auto.sh` と `local-watcher/bin/issue-watcher.sh` のみ shellcheck 対象としており、test file は対象外（task 6 で警告ゼロ化する責務はないと判断、既存パターン整合性を優先）。
  - `repo-template/local-watcher/test/needs_decisions_auto_test.sh` は **本 task で触らない**（task 8 の root↔repo-template 同期で別途処理 / CLAUDE.md「機能追加ガイドライン § 4」）。
- 残存課題: なし。本 task で task 1〜2.4 / 3 の全 `_Requirements_partial:_` 宣言が unit test レイヤで解消され、per-task Reviewer の `missing test` カテゴリ判定の対象 AC は全 task の `_Requirements:_` 列挙 AC に対して充足された状態となる。task 7（README 更新）/ task 8（root↔repo-template 同期）の後続で本機能の配布形態と運用ドキュメントが完成する。
- スモーク検証: `bash -n local-watcher/test/needs_decisions_auto_test.sh` pass。`bash local-watcher/test/needs_decisions_auto_test.sh` で **72 PASS / 0 FAIL** を確認（Section 1: 7 / Section 2: 8 / Section 3: 13 / Section 4: 6 / Section 5: 11 / Section 6: 6 / Section 7: 10 / Section 8: 11）。`shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh` および双方の `bash -n` も pass（stage-a-verify gate の verify block 関連箇所が回帰なし）。

### Task 7

- 採用方針: `README.md` の opt-in 表（line 1345 配下）に `NEEDS_DECISIONS_MODE` 1 行を Failed Recovery (#359) 行の直後に追加し、Full-Auto Kill Switch 行（line 1368）の説明文を「現在の配線対象は #346 + #352 + #354 + #349 + #359 + #362 の 6 系統」に整合更新。さらに `## needs-decisions Auto-Continue (#362)` 詳細節を Failed Recovery Processor (#359) の直後（Design Review Release Processor #40 の直前 / line 3587 近辺）に新設。既存 `Auto-Merge Processor (#352)` / `Failed Recovery Processor (#359)` 節と同じ `##` 階層で 8 サブセクション構成（概要 + 対象条件 + 3 値モード表 + AND 二重 opt-in 判定順序 + human-only 絶対停止 + 自動続行挙動 + 観測ログ grep 例 + cron 例 + 後方互換 + pilot 運用 + merge 後再配置）。
- 重要な判断:
  - **Full-Auto Kill Switch 行説明文の整合修正**（task 指示の「Dependency Auto-Unblock Sweep + needs-decisions auto」より整合優先）: tasks.md task 7 指示文では「Dependency Auto-Unblock Sweep + needs-decisions auto」と更新するよう書かれているが、既存 README で Auto-Merge (#352) / Design Auto-Merge (#354) / PR Reviewer Commit Status (#349) / Failed Recovery (#359) 行が **既に独自に AND 二重 opt-in 配線済**である事実と矛盾するため、「現在の配線対象は #346 + #352 + #354 + #349 + #359 + #362 の 6 系統」と全配線対象を明示する形に整合更新した（CLAUDE.md「機能追加ガイドライン § 4 README との二重管理」/ 既存記述との整合優先）。task 指示文より整合を優先する判断は本 task の Architect / Reviewer に簡潔に共有する想定。
  - **opt-in 表の配置位置**: Failed Recovery (#359) 行の直後 + Security Review strict モード (#360) 行の直前に配置（full-auto 系 processor グルーピングに揃える / kill switch との AND 評価を持つ既存行群と隣接）。task 指示で示唆された「Auto-Merge Processor の直前を推奨」もあるが、関連 issue 番号順（#359 → #362）かつ AND 二重 opt-in を持つ既存行群の連続性を優先した。
  - **詳細節の配置位置**: Failed Recovery Processor (#359) の直後（line 3587 / Design Review Release Processor #40 の直前）に配置。Auto-Merge Processor (#352) の近傍も検討したが、(a) Failed Recovery と本機能はいずれも **`FULL_AUTO_ENABLED` との AND 二重 opt-in を持つ full-auto 系 processor** という共通性、(b) Issue 番号順（#359 → #362）、(c) Failed Recovery 節末尾の `## ⚠️ merge 後の再配置が必要` パターンを本節でも同形式で踏襲できる、の 3 点で隣接配置の方が読みやすいと判断。
  - **アンカーリンク形式**: opt-in 表内の `[needs-decisions Auto-Continue (#362)](#needs-decisions-auto-continue-362)` は GitHub の自動 slugify 規則（h2 見出し `## needs-decisions Auto-Continue (#362)` → lowercase + `()` 除去 + space → ハイフン）で一致する。既存 `[Auto-Merge Processor (#352)](#auto-merge-processor-352)` パターンと厳密に整合。
  - **詳細節内のリンク参照**: 既存 `needs-decisions` 付与経路（Partial Status Gate #148 / Spec Completeness #219 / Tasks Count #131）の文脈解説と各既存節へのリンクを含めることで、本機能の対象範囲（Triage 出力 JSON 経路のみ）と非対象範囲（watcher 内部ガード経路）の境界を明示した（NFR 1.3 既存付与経路 touch なし）。
  - **`all-auto` モードの危険性明示**: 詳細節「3 値モードの意味と挙動」表の直後に明示的な引用ブロック（`> **`all-auto` の危険性**: ...`）を配置し、pilot 運用での `classified` 推奨を明文化（CLAUDE.md「機密情報の扱い」「禁止事項」との整合 / NFR 4.x）。
  - **cron 設定例の併記**: `classified`（pilot 推奨）と `all-auto`（明示 opt-in / 危険）の両方を併記し、`all-auto` 側に「**危険 / 明示 opt-in / 実運用での誤分類率観測後のみ推奨**」の警告を本文 + cron コメント両方に重複記載した（cron 設定をコピペする運用者の誤設定リスク低減）。
  - **`repo-template/README.md` は触らない**: CLAUDE.md「機能追加ガイドライン § 4 二重管理」では `.claude/{agents,rules}` と `local-watcher/bin/` の root↔repo-template byte 一致が canonical 対象であり、README は consumer 固有内容を持つため byte 一致対象外（CLAUDE.md「root ↔ repo-template の二重管理・同期」節）。本 task では root の `README.md` のみ編集し、`repo-template/README.md` は touch しない。
- 残存課題: なし。task 8（root↔repo-template 二重管理同期）で `local-watcher/bin/issue-watcher.sh` / `local-watcher/bin/triage-prompt.tmpl` / `local-watcher/bin/modules/needs-decisions-auto.sh` / `local-watcher/test/needs_decisions_auto_test.sh` / `.claude/agents/product-manager.md` の 5 ファイルを `repo-template/` 配下に同期する責務が後続する。
- スモーク検証: 編集後の `README.md` を目視確認し、(a) 新規 opt-in 表行が Failed Recovery (#359) 行直後に配置され表 column 整合（7 列）が維持されていること、(b) Full-Auto Kill Switch 行の説明文が「現在の配線対象は #346 + #352 + #354 + #349 + #359 + #362 の 6 系統」に更新され既存記述（auto-merge / failed-recovery 等の独自 AND 配線）と矛盾しないこと、(c) 新規詳細節 `## needs-decisions Auto-Continue (#362)` が `## Failed Recovery Processor (#359)` の直後 + `## Design Review Release Processor (#40)` の直前に配置され `##` 階層整合、(d) アンカーリンク `#needs-decisions-auto-continue-362` が opt-in 表行と詳細節の double anchor 整合（grep で 1 件のみ確認）、(e) markdown 構文（コードフェンス `cron` / `bash` / `text` の言語タグ、表 column 整合、リンク `[]()` 構文）が破綻していないこと、を確認。stage-a-verify gate の verify block コマンド（`shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh && bash -n ... && bash local-watcher/test/needs_decisions_auto_test.sh`）を再実行し、**全 72 PASS / 0 FAIL** + `shellcheck` 警告ゼロを再確認（task 6 の verify block 整合性を破壊していないこと）。`diff -r .claude/agents repo-template/.claude/agents` と `diff -r local-watcher/bin repo-template/local-watcher/bin` は task 8 の責務のため本 task では確認しない。

### Task 8

- 採用方針: CLAUDE.md「機能追加ガイドライン § 4 二重管理・同期の鉄則」に準拠し、root の `.claude/agents/product-manager.md` を `repo-template/.claude/agents/product-manager.md` に `cp -p` で byte 一致同期した。task 指示の 5 ファイル候補のうち、実際に同期対象となったのはこの 1 ファイルのみ。
- 重要な判断:
  - **`repo-template/local-watcher/` ディレクトリは存在しない**: `local-watcher/bin/issue-watcher.sh` / `local-watcher/bin/triage-prompt.tmpl` / `local-watcher/bin/modules/needs-decisions-auto.sh` / `local-watcher/test/needs_decisions_auto_test.sh` の 4 ファイルは **repo-template 配下に配布されていない** ことを確認した（`ls -la repo-template/` で `.claude` / `.github` / `CLAUDE.md` の 3 エントリのみ、`find repo-template -type d` でも `local-watcher` 配下なし）。これらは `install.sh` 経由で root から `$HOME/bin/` に直接配布される配布形態であり、repo-template byte 一致対象外。`diff -r local-watcher/bin repo-template/local-watcher/bin` は exit 2（ディレクトリ不在）を返すため、検証は `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` の 2 つに絞った。
  - **`.claude/rules` は元から差分ゼロ**: 本 task 着手時点で `diff -r .claude/rules repo-template/.claude/rules` は exit 0（差分なし）。task 1〜7 の編集対象に `.claude/rules/*.md` が含まれなかったため整合性は維持されていた。
  - **`.claude/agents/product-manager.md` のみ 8 行差分**: task 5 で root の `product-manager.md` に追記した classification 出力責務 7 行 + 末尾改行の合計 8 行差分を `cp -p`（mode/timestamp 保持）で repo-template に反映。`diff -r` 再実行で exit 0 を確認。
  - **stage-a-verify gate の verify block を再実行**: `shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh` 警告ゼロ / `bash -n` 両ファイル pass / `bash local-watcher/test/needs_decisions_auto_test.sh` で **72 PASS / 0 FAIL** を再確認。task 6 / 7 の verify block 整合性は本 task の sync 操作で破壊されていない（README / agent ファイルの編集は shell scripts に影響しない）。
  - `repo-template/README.md` / `repo-template/CLAUDE.md` は consumer 固有内容を持つため byte 一致対象外（CLAUDE.md「root ↔ repo-template の二重管理・同期」節）。本 task では一切 touch していない。
- 残存課題: なし。本 task で Issue #362 の全 8 task（env 正規化 / module 追加 / 本体配線 / Triage prompt 拡張 / PM agent 追記 / 近接 unit test / README 更新 / repo-template 同期）が完了し、needs-decisions Auto-Continue 機能の実装は完成した。`PROMOTE_PIPELINE_ENABLED` 系の opt-in gate 同様、`NEEDS_DECISIONS_MODE=all-human`（既定）では本機能導入前と完全に同一の挙動を保つため、merge 後の cron 即時反映は安全。
- スモーク検証: `diff -r .claude/agents repo-template/.claude/agents` exit 0、`diff -r .claude/rules repo-template/.claude/rules` exit 0、`shellcheck local-watcher/bin/modules/needs-decisions-auto.sh local-watcher/bin/issue-watcher.sh && bash -n local-watcher/bin/modules/needs-decisions-auto.sh && bash -n local-watcher/bin/issue-watcher.sh && bash local-watcher/test/needs_decisions_auto_test.sh` で `72 PASS / 0 FAIL` を確認。`git diff --stat` で `repo-template/.claude/agents/product-manager.md` のみ 8 行追加（task 5 と同形の差分）。`repo-template/local-watcher/` は不在のため `diff -r local-watcher/bin repo-template/local-watcher/bin` は意図通り exit 2、本 task の検証対象外。

STATUS: complete
