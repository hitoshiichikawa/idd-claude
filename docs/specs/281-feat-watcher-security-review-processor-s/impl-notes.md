# Implementation Notes (#281)

## Implementation Notes

### Task 1

- 採用方針: LABELS 配列末尾（`hotfix` 行直後）に `needs-security-fix` を 1 行追加し、既存 16 行の name / color / description は一切変更しない（NFR 1.2）。color は既存 PR 用警告色との一貫性のため `d73a4a`（`st-failed` と同色）を採用、description は仕様文字列をそのまま使用し 83 chars（100 chars 上限内）であることを確認。
- 重要な判断:
  - `repo-template/.github/scripts/idd-claude-labels.sh` は design.md「Modified Files」の対象外（design.md line 257-262 で明示的に repo-template 側不変と宣言）かつ root とは既に系統的に乖離している（root のみ 【PR 用】/【Issue 用】prefix 運用）ため、本 task では編集しない。二重管理規約（CLAUDE.md）が対象とするのは `.claude/{agents,rules}` のみで `.github/scripts/` は対象外であることも確認済み。
  - shellcheck はラベル配列追加のみのため警告ゼロを維持。
- 残存課題: なし（task 2 以降は別 task として独立しており、本 task の判断が後続に伝播する事項はない）。

### Task 2

- 採用方針: 既存「`# ─── Security Review Processor 設定 (#279) ───`」節の末尾（`SECURITY_REVIEW_EXEC_TIMEOUT` 行直後）に新規節「`# ─── Security Review Processor strict モード設定 (#281) ───`」を追加し、`SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` / `SECURITY_REVIEW_BLOCK_LABEL` の 3 env を `${VAR:-default}` 形式で宣言。既定値はそれぞれ `advisory` / `high` / `needs-security-fix` で #279 動作と byte 等価（Req 1.5 / 2.2 / NFR 1.1）。
- 重要な判断:
  - tasks.md 原文では「既存節の末尾に 3 行追加」と指示されていたが、design.md「Modified Files」L250-255 では「strict 関連 env を Config ブロックに追加」までしか拘束しておらず、観測しやすさのため #281 専用サブ節（コメントヘッダ付き）として切り出す方が後続 task 3〜9 で env 群を一望できる。`SECURITY_REVIEW_EXEC_TIMEOUT` の直下にサブ節を作っても「Security Review Processor 設定 (#279) 節の末尾の延長」として読めるため tasks.md の Boundary（`issue-watcher.sh Config block`）に違反しない判断。
  - 各 env のコメントブロックに「既定値 / 許容値 / 不正値時の safe-fallback 挙動 / 厳密一致判定」を明記。これは design.md「環境変数」表（L548-556）の内容を inline 化したもので、運用者が `grep -B 10 SECURITY_REVIEW_MODE issue-watcher.sh` で挙動を即座に確認できる（NFR 3.1 観測可能性の一環）。
  - `SECURITY_REVIEW_BLOCK_LABEL` のコメントで「`needs-iteration` は本 env で制御せずハードコード」を明記。これは design.md L554 の「`needs-iteration` の同時付与は本 env で制御しない（必須付与のためハードコード）」を Config 側にも反映し、task 5 (`sec_apply_block_labels`) 実装時の境界誤認を予防する目的。
  - shellcheck 警告ゼロを確認（コメント + 既存パターン踏襲の `${VAR:-default}` 宣言のみで新規 lint 対象なし）。
- 残存課題: なし（task 3 以降はモジュール側 `modules/security-review.sh` の実装であり、本 task の Config 宣言形式が後続の env 読み出しパターンを拘束する点はない。`${SECURITY_REVIEW_MODE:-advisory}` で Config 側が既に既定値を解決するため、モジュール側関数は `$SECURITY_REVIEW_MODE` を直接参照すればよく fallback 不要）。

### Task 3

- 採用方針: 既存 `sec_check_strict_request` 直後（`sec_fetch_candidate_prs` の直前）に `sec_resolve_block_severity` / `sec_severity_at_or_above` / `sec_count_blocking_findings` の 3 関数を純粋関数として追加。既存 advisory 経路・既存関数群には一切手を入れず副作用なし（NFR 1.1）。配置位置は「severity / strict 関連ヘルパが集約される」目的で sec_check_strict_request の直下を選択（design.md「Service Interface」節の関数列挙順とも整合）。
- 重要な判断:
  - `sec_resolve_block_severity` の不正値判定はホワイトリスト完全一致のみ（design.md L612 のテスト戦略「大文字混在 → high + WARN」に従い、`HIGH` / `Critical` / 前後空白付き等もすべて不正値として WARN + `high` fallback）。これにより shell metacharacter / コマンドインジェクションも構造的に防御（design.md Security Considerations）。未設定 / 空文字列は WARN なしで既定 `high` を採用（Req 2.2、本機能導入前と byte 等価）。
  - `sec_severity_at_or_above` は 25 通り（5 severity × 5 threshold）全パターンを smoke で検証。入力が 5 値以外なら rc=2 を返す防御的設計を保持（呼び出し元は既に `sec_resolve_block_severity` 経由で正規化済みの値を渡す前提だが、purely defensive）。
  - `sec_count_blocking_findings` の sed 抽出パターンは既存 `sec_write_security_notes`（L525-529）で既に確立された `'s/.*<key>=\([0-9][0-9]*\).*/\1/p'` パターンを完全踏襲し、既存と一貫した数値抽出ロジックを採用。malformed input（空文字 / "garbage data" 等）でも安全側で "0" を返してラベル付与判定をスキップさせる（Req 5.3 安全側設計）。threshold 不正値でも "0" を返す防御層を入れた（呼び出し元が `sec_resolve_block_severity` を経由する前提でも到達しない想定だが、合成テストで動作確認済み）。
  - `for pair in "critical:$crit" "high:$high" ...` の collection 走査スタイルは bash 移植性の高い `${pair%%:*}` / `${pair##*:}` パラメータ展開で sev/count を分解する設計を採用。shellcheck 警告ゼロ。
  - smoke 検証（手動）: 12 種の `sec_resolve_block_severity` 入力 / 9 通りの `sec_severity_at_or_above` ordinal 比較 / 11 種の `sec_count_blocking_findings` 入力（design.md L612-616 の境界例「閾値 medium で critical=1 high=2 medium=3 → 6 件」を含む）すべて期待値一致。WARN は stderr のみに出力されることも確認（stdout 単一 token 契約を破壊しない）。
- 残存課題:
  - 本 task では `sec_run_review_for_pr` の改修・呼び出し挿入は実施しない（task 6 の責務）。本 3 関数は task 6 で `if [ "$mode" = "strict" ] && [ "$total_findings" -gt 0 ]; then threshold=$(sec_resolve_block_severity); blocking_count=$(sec_count_blocking_findings "$severity_summary" "$threshold"); ...` 形式で組み合わせて使用される予定（design.md L457-468）。
  - 本 task の純粋関数 3 つはすべて既存 advisory 経路から呼ばれないため、`SECURITY_REVIEW_MODE != strict` 環境では関数定義が読み込まれるだけで実行されず副作用ゼロ（NFR 1.1 byte 等価が構造的に保証される）。

### Task 4

- 採用方針: `sec_check_strict_request` を `case "$mode" in strict) → "strict" / advisory|"" → "advisory" / *) → WARN + "advisory" esac` の純粋な mode 解決関数に書き換え、`SECURITY_REVIEW_STRICT` 非空時は deprecated alias WARN を 1 行だけ追加で出す形に統一（mode 解決には影響させない）。stdout 単一 token 契約（"strict" または "advisory" の 1 行）と既存 #279 advisory パス byte 等価（NFR 1.1）の両方を満たす。
- 重要な判断:
  - `SECURITY_REVIEW_MODE=""`（明示的空文字）は `advisory|""` の case 節でマッチさせ、未設定と同様に WARN なし advisory 解釈とした（Req 1.1 の "未設定 / 空文字 / `advisory`" 列挙に従う）。一方で `" strict "` のような空白混入値は厳密一致しないため不正値分岐で WARN + advisory fallback となり、Req 1.4 の design.md L612 テスト戦略「大文字混在 → WARN」と一貫した防御的設計を保持。
  - `SECURITY_REVIEW_STRICT` 非空時の WARN メッセージは「deprecated alias / mode 切替には SECURITY_REVIEW_MODE=strict を使用してください / 本 env は mode 解決に影響しません」と運用者誘導を明示。#279 の WARN メッセージ（「strict は本 spec 未実装 / 別 Issue #281 待ち」）は #281 で実装完了したため文言ごと刷新したが、WARN 出力 1 行・stderr のみ・mode 変更なしという観測挙動は #279 と完全同一に保つ（sudden break 回避）。
  - `STRICT=1 + MODE=strict` の組み合わせ（11 ケース smoke の Case 9）では「STRICT は無視されるが MODE で strict 解釈」となり WARN 1 行 + stdout "strict" を返す。これは「`SECURITY_REVIEW_STRICT` のみ set した運用者は #279 と同じく advisory のまま、`SECURITY_REVIEW_MODE=strict` を明示した運用者のみ strict 化する」という Req 1.2 / NFR 1.1 双方を満たす境界設計。
  - smoke 検証（手動 11 ケース）: `MODE=strict` / 未設定 / 空 / `advisory` / `invalid` / `Strict`（typo） / `' strict '`（空白混入） / `STRICT=1` 単独 / `STRICT=1 + MODE=strict` / `STRICT=foo + MODE=invalid`（WARN 2 件） / `STRICT='' + MODE=strict`（空文字は WARN なし）すべて期待値一致。stdout / stderr 分離も確認済み（WARN は stderr のみ）。
- 残存課題:
  - 本 task では `sec_run_review_for_pr` の strict 経路への配線は実施しない（task 6 の責務）。`sec_check_strict_request` の戻り値は task 8 で `process_security_review` 内のモジュール内グローバル `_sec_resolved_mode` に退避され、task 6 でループ内から参照される予定（design.md L472-475）。
  - 確認事項: モジュール冒頭の概要 comment（line 14 `# - strict 要求検出: sec_check_strict_request（advisory 固定 fallback、Req 5.3）`）は #281 task 4 で挙動を切り替えたため記述が古くなっているが、task 4 の Boundary（`sec_check_strict_request` 関数のみ）に厳密に従い本 task では編集を見送った（task 3 で追加した 3 関数も同概要に列挙されていないため、別 task / 別 PR で概要を一括更新するのが望ましい）。

### Task 5

- 採用方針: `sec_count_blocking_findings` 直後（severity / strict 系ヘルパが集約される位置）に新規関数 `sec_apply_block_labels` を追加。`gh pr edit --add-label "${SECURITY_REVIEW_BLOCK_LABEL},needs-iteration"` の 1 コマンドで 2 枚を原子付与し、hidden marker (`kind=security-block`) コメントを 1 件投稿して SHA 単位の冪等性を確立する設計（design.md L414-426 / Req 3.1 / 4.4 / NFR 4.1）。既存関数（`sec_run_review_for_pr` / `process_security_review` / `sec_post_*`）には一切手を入れず、関数定義の追加のみ（NFR 1.1）。
- 重要な判断:
  - **marker コメント本文の決定**: design.md には body 固定テンプレ指定がないため、(a) 冒頭に運用者向け視認用の `<!-- security-block marker for SHA <sha> -->` 注記行（visible / hidden 双方読める短い説明）、(b) 1 行サマリ「strict モードによりマージ阻害ラベル `<label>` / `needs-iteration` を付与しました（blocking=N threshold=high）」（運用者が gh UI / GitHub UI 双方で判断材料を得られる / Req 3.5 ログと整合）、(c) 末尾に `sec_build_marker` 出力（kind=security-block）を append、の 3 ブロック構成を採用。これは既存 `sec_post_clean_comment` の「短い説明 + 構造化メタ情報 + marker」と整合したパターン。
  - **エラーハンドリング 2 段**: (a) `gh pr edit` 失敗 → WARN + return 1（次サイクルで再付与可、コメント投稿側を阻害しない fail-continue 既存規約）、(b) ラベル付与成功 + marker 投稿失敗 → WARN + return 1（design.md L589「次サイクルで再付与＝gh pr edit --add-label の冪等性により副作用なし」を明示的に注記）。後者の挙動は GitHub `gh pr edit --add-label` が同名ラベルの重複付与に対して **冪等**（既に付与済みなら何もせず exit 0）であることを利用して、自己回復可能なエラー設計とした。これを関数 docstring の「エラーハンドリング」節に明示。
  - **stdout 汚染なし**: 本関数は stdout に何も出力しない（観測ログは sec_log/sec_warn の stderr のみ）。これは `sec_post_*_comment` と同じ契約で、呼び出し元 task 6 が rc を `|| true` で吸収できるよう設計（design.md L465 の使用例 `sec_apply_block_labels "$pr_number" "$sha" "$blocking_count" "$threshold" || true` と整合）。
  - **shellcheck SC2016 抑制**: marker コメント body の printf format 文字列内に markdown コードフェンス用バッククォート（`` ` ``）リテラルが含まれるため、`# shellcheck disable=SC2016` を inline 付与。これは既存 `sec_substitute_placeholders` / `sec_run_review_for_pr` で確立済みのパターンを踏襲（root の `.shellcheckrc` は SC2317/SC2012 のみ disable しており SC2016 は対象外のため inline 抑制が必要）。
  - smoke 検証（手動 4 ケース）: (1) 重複検出 → rc=0 + skip log 1 行、(2) `gh pr edit` 失敗 → rc=1 + WARN 1 行、(3) 全成功 → rc=0 + 成功 log 1 行（labels=needs-security-fix+needs-iteration blocking=5 threshold=medium sha=ghi789）、(4) edit ok / comment 失敗 → rc=1 + WARN 1 行（冪等性 fallback の注記付き）すべて期待値一致。stdout 出力ゼロも確認。
- 残存課題:
  - 本 task では `sec_run_review_for_pr` の strict 経路配線は実施しない（task 6 の責務）。task 6 で `if [ "$_sec_resolved_mode" = "strict" ] && [ "$total_findings" -gt 0 ]; then threshold=$(sec_resolve_block_severity); blocking_count=$(sec_count_blocking_findings "$severity_summary" "$threshold"); ... sec_apply_block_labels "$pr_number" "$sha" "$blocking_count" "$threshold" || true; fi` 形式で `sec_post_review_comment` 直後に挿入される予定（design.md L457-468）。
  - 本関数は task 6 配線まで呼び出し元が存在しないため、`SECURITY_REVIEW_MODE != strict` 環境では関数定義が load されるだけで実行されず副作用ゼロ（NFR 1.1 byte 等価が構造的に保証される）。
  - 確認事項: marker コメント冒頭の visible 注記（`<!-- security-block marker for SHA ... -->`）は HTML コメント記法のため GitHub UI 上では非表示。運用者が gh API レスポンス本文を直接見たときの可読性を狙ったものだが、UI 上は本文 1 行サマリのみが表示される。これは design.md にも明示されていない設計判断（裁量の範囲内）。

### Task 6

- 採用方針: `sec_run_review_for_pr` の「検出 ≥ 1 件分岐」内、`sec_log "PR #${pr_number}: 検出 ${total_findings} 件"` の直後かつ `sec_post_review_comment` 呼び出しの直前に strict 判定枝を挿入。`${_sec_resolved_mode:-}` で安全参照し厳密一致 `"strict"` のみ枝に入る。blocking_count > 0 → design.md L496-501 の override note を `review_text` に append + `sec_apply_block_labels` を `|| true` で呼び出し（fail-continue / Req 4.5, 3.1, 3.4）。blocking_count = 0 → ラベル付与なし、sec_log で 1 行記録（Req 3.2）。
- 重要な判断:
  - `_sec_resolved_mode` 未配線時の no-op 構造保証: 本 task の時点で `_sec_resolved_mode` は task 8 まで設定されない（design.md L471-475）。`${_sec_resolved_mode:-}` 形式で参照し未定義時は空文字に展開、`[ "$..." = "strict" ]` の厳密一致は false となるため strict 経路全体が dead code 化する。これにより task 8 完了まで本 task の追加コードが既存 advisory 経路の挙動に影響を与えないことが構造的に保証される（NFR 1.1 byte 等価）。
  - **override note append タイミング**: design.md L491-494「呼び出し元（sec_run_review_for_pr の strict 経路）で `review_text` の末尾に override note を append してから関数呼び出しする方式」に従い、blocking_count > 0 を判定した時点で `review_text` 自身を `printf '%s\n\n%s' "$review_text" "$override_note"` で書き換え、後続の `sec_post_review_comment "$pr_number" "$sha" "$review_text"` がそのまま末尾 override note 付きで投稿する。`sec_post_review_comment` 関数自体のシグネチャは変えない（最小差分原則）。
  - **`sec_apply_block_labels` 呼び出しタイミング**: `sec_post_review_comment` 成功後（rc=0 の if 文を抜けた後）に実行する。コメント投稿失敗時は `return 1` で早期復帰するため、ラベル付与の前に必ずコメント投稿が成功している。`|| true` で吸収するのは design.md L465 の使用例と整合し、ラベル付与失敗が `sec_write_security_notes` を阻害しないようにするため（fail-continue）。
  - **blocking_count = 0 と blocking_count > 0 の両分岐ログ**: blocking_count > 0 では `strict 判定 blocking=${...} threshold=${...}`、blocking_count = 0 では `strict 判定 blocking=0 threshold=${...}（閾値以上検出なし、ラベル付与なし）` を sec_log で記録（Req 3.5 / NFR 3.1）。後者を明示的にログ出力することで「strict モードで動いたが閾値未満だった」状態を運用者が判定できる。
  - **override_note 本文の `SECURITY_REVIEW_BLOCK_LABEL` 参照**: design.md のテンプレは `needs-security-fix` 固定文字列だが、実装では `${SECURITY_REVIEW_BLOCK_LABEL:-needs-security-fix}` で env から動的解決にした。これは task 5 の `sec_apply_block_labels` が `$SECURITY_REVIEW_BLOCK_LABEL` をラベル名として使うため、override note 本文とラベル名の整合を env 側で一元化する目的（運用者が `SECURITY_REVIEW_BLOCK_LABEL=custom-block` 等にカスタマイズしたときに override note とラベル名が一致する）。design.md L496-501 のテンプレ文言は意味的に保持。
  - smoke 検証（手動 6 ケース）: (1) `_sec_resolved_mode` unset → advisory 経路 byte 等価（override note なし / ラベル付与なし）、(2) `_sec_resolved_mode="advisory"` → 同上、(3) strict + threshold=high → critical=1+high=1 で blocking=2 → override note append + sec_apply_block_labels 呼び出し、(4) strict + threshold=critical → critical=1 のみで blocking=1 → 同上、(5) strict だが severity トークン皆無で total_findings=0 → strict 枝に入らず（`total_findings > 0` 条件で gate）、(6) strict + threshold=high で low/info のみ検出 (blocking=0) → override note なし / ラベル付与なし / `閾値以上検出なし` log 出力。すべて期待値一致。
  - shellcheck `local-watcher/bin/modules/security-review.sh` 警告ゼロ。
- 残存課題:
  - 本 task の strict 経路は **task 8** で `process_security_review` が `_sec_resolved_mode` を設定するまで activate されない（dead code 状態）。task 8 完了で初めて `_sec_resolved_mode="strict"` がループ内に伝播し、本 task の追加コードが意図通りに動作する設計（design.md L471-475 と整合）。
  - **task 7** で `sec_write_security_notes` のシグネチャに `mode` / `threshold` / `blocking_count` / `decision` 引数が追加される予定だが、本 task では既存シグネチャ（6 引数）のまま `sec_write_security_notes` を呼び出している。task 7 完了時に呼び出し元（本 task で挿入した strict 経路と既存 advisory 経路の双方）の引数追加が必要。
  - `_strict_blocking_count` / `_strict_threshold` ローカル変数のスコープは関数内（`local` 宣言）であり、`sec_run_review_for_pr` の `return` で確実に破棄される（次 PR 処理に状態を持ち越さない / 副作用なし）。
