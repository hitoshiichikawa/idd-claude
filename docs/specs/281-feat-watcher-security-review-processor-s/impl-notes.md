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

### Task 7

- 採用方針: `sec_write_security_notes` のシグネチャ末尾に `mode` / `threshold` / `blocking_count` / `decision` の 4 引数を追加（`${7:-advisory}` / `${8:--}` / `${9:-0}` / `${10:-advisory-only}` で省略時 advisory 既定値に倒し NFR 1.1 後方互換性を保証）、Severity Summary 表の直下に `## Threshold Decision` セクション（Mode / Threshold / Blocking Count / Decision の 4 行 bullet）を追加。`sec_run_review_for_pr` のクリーン経路（line 941 付近）と検出経路（line 987 付近）の双方で `_sec_resolved_mode` に基づき適切な mode / threshold / blocking_count / decision を計算して渡す。既存 idempotency（Last SHA 一致時 overwrite skip）と先頭メタ / Severity Summary 表 / Findings 本文の出力は 1 文字も変更せず、新規セクションを既存出力の途中に挿入するだけの最小差分（NFR 1.1 / NFR 4.1）。
- 重要な判断:
  - **クリーン経路（total_findings=0）での decision 計算**: tasks.md は「既存呼び出し元（advisory 経路）はデフォルト値 ... を渡す」と指示しているが、クリーン経路は advisory / strict 双方の mode で到達しうる（strict + clean = 検出 0 件 = `_strict_threshold` の評価枝に入らない）。design.md L542-544 の Decision 値マッピングは mode と blocking_count の組合せで定義されているため、クリーン経路では `_sec_resolved_mode` を参照して mode=strict 時は `decision=label-skipped` + `threshold=$(sec_resolve_block_severity)`、mode=advisory 時は `decision=advisory-only` + `threshold=-` を渡す形に分岐させた。これは tasks.md の literal interpretation（クリーン経路も advisory デフォルトを渡す）から一歩踏み込んだ判断だが、design.md の Decision 値定義との semantic 整合を優先（strict モードで動いたことを security-notes.md に記録できる方が運用者観測上有益）。
  - **検出経路（total_findings>0）での decision 計算**: `_sec_resolved_mode = strict` かつ `_strict_blocking_count > 0` → `decision=label-applied`、`_sec_resolved_mode = strict` かつ `_strict_blocking_count = 0` → `decision=label-skipped`、それ以外（advisory）→ `decision=advisory-only` + `threshold=-`。design.md L542-544 のマッピングに厳密準拠。
  - **`sec_apply_block_labels` の rc 結果は decision に反映しない設計**: design.md L307 の Req 3.5「判定結果（付与有無 / 件数 / 閾値以上件数 / 閾値値）を 1 行ログ」は `sec_apply_block_labels` 内のログ責務（task 5 で実装済み）であり、security-notes.md の `Decision` 値は「strict 判定として label 付与を試みたか / advisory で判定対象外か」のレベルで記録する設計とした。`sec_apply_block_labels` 失敗時（gh pr edit 失敗 / marker 投稿失敗）も `decision=label-applied` のまま記録する（fail-continue 規約 + 次サイクルで再付与の冪等性により self-healing）。
  - **shellcheck 抑制不要**: 既存 SC2016 disable コメント（task 5 で導入）以外の新規 inline 抑制は不要。`${10:-...}` も標準 bash 構文として shellcheck 警告ゼロを確認。
  - **smoke 検証（手動 5 ケース）**: (1) advisory 明示引数 → advisory-only/-/0 出力、(2) strict + blocking=3 → label-applied/high/3 出力、(3) strict + blocking=0 → label-skipped/high/0 出力、(4) 同一 SHA で 2 回呼び出し → 2 回目は overwrite skip（既存 idempotency 不変）、(5) 引数 7..10 を省略した呼び出し → advisory デフォルト値（NFR 1.1 後方互換）。すべて期待値一致。
- 残存課題:
  - 本 task で `sec_run_review_for_pr` 内に追加したクリーン経路の `_sec_resolved_mode` 参照は、task 8 で `process_security_review` が `_sec_resolved_mode` を設定するまで `_sec_resolved_mode:-advisory` の default 展開で advisory に倒れる。これは task 6 で確立した `${_sec_resolved_mode:-}` 安全参照パターンと整合し、task 8 完了で初めて strict クリーン経路の decision=label-skipped 出力が activate される。
  - task 8 ではモジュール内グローバル `_sec_resolved_threshold` も導入される予定だが、本 task のクリーン経路ではローカルで `sec_resolve_block_severity` を再評価する設計とした（クリーン経路は呼び出し頻度が低く再評価コストが無視できる + task 8 のグローバル変数依存を本 task に持ち込まない / 段階導入の安全側）。task 8 完了後にローカル再評価をグローバル `_sec_resolved_threshold` 参照に置き換える refactor は許容されるが、本機能の挙動には影響しない。
  - 確認事項: tasks.md task 7 の「既存呼び出し元（advisory 経路）はデフォルト値 ... を渡す」記述は、クリーン経路で strict mode が解決済みのケースを literal には advisory として記録する読みも可能だが、design.md L542-544 の Decision 値定義との整合を優先してクリーン経路でも mode を参照する分岐実装を採用した。tasks.md / design.md の書き換えは禁止のため本判断を impl-notes に記録のみ。Reviewer / PM レビュー時に literal interpretation を採用すべきと判断された場合は本 task の修正で対応する（簡易：分岐を撤去して常に advisory 既定値を渡す）。

### Task 8

- 採用方針: `process_security_review` 冒頭で `mode = sec_check_strict_request` / `threshold = sec_resolve_block_severity` を解決し、モジュール内グローバル `_sec_resolved_mode` / `_sec_resolved_threshold` に退避（design.md L484-485 の契約に従い task 6 / 7 から参照可能にする）。cycle start ログから `strict=not-implemented (split to #281)` 表記を削除し `threshold=${threshold}` を新規追加（Req 1.3, 2.5, NFR 3.1）。`blocked` / `skipped_blocked` カウンタはモジュール内グローバル `_sec_blocked_count` / `_sec_skipped_blocked_count` を `process_security_review` 冒頭で 0 リセットし、`sec_apply_block_labels` 内で重複 skip 時 → `_sec_skipped_blocked_count++` / 新規付与成功時 → `_sec_blocked_count++` という最小差分のインクリメントを埋め込み、3 ヶ所のサマリログ（候補 0 件 / iterate 対象なし / 通常終了）すべてに `blocked=${_sec_blocked_count} skipped_blocked=${_sec_skipped_blocked_count}` を追記（design.md L602）。
- 重要な判断:
  - **カウンタの実装場所**: 起動指示書では「`sec_apply_block_labels` の rc / 重複 skip を呼び出し元（sec_run_review_for_pr の strict 経路）でカウントする」「`sec_apply_block_labels` の責務範囲を逸脱しないよう注意」の両方が記載されていたが、rc=0 が「新規付与成功」と「重複 skip」の双方を返すため呼び出し元から rc だけでは区別不能。impl-notes Task 5 で確立された「`sec_apply_block_labels` 内部 `sec_already_processed` ブロックで重複判定 → 早期 return」設計が既にあり、その分岐点でカウンタをインクリメントするのが最小差分。`|| true` で吸収する既存設計（task 5 / task 6）は維持されており、カウンタ更新は副作用のみで rc 契約に影響しない（呼び出し元は引き続き `|| true` で吸収可能 / NFR 1.1）。
  - **`_sec_resolved_threshold` の shellcheck SC2034 抑制**: 本 task 時点で `_sec_resolved_threshold` は task 6 のローカル `_strict_threshold=$(sec_resolve_block_severity)` 再評価により未参照（task 6 が impl-notes Task 7「残存課題」で記載した通り、本 task 8 完了後にローカル再評価をグローバル参照に置き換える refactor は許容されるが本機能挙動には影響しない判断）。design.md L484 の契約「mode / threshold をモジュール内グローバルに退避」に従い設定だけは行い、`# shellcheck disable=SC2034` を inline 抑制した。実測では shellcheck 0.10.0 で警告は出なかったが、将来の version 変動への safety で抑制コメントを残置。
  - **3 ヶ所のサマリログ全てに blocked カウンタを追記**: 「候補 PR なし」「iterate 対象なし」「通常終了」のいずれの分岐でも `_sec_blocked_count` / `_sec_skipped_blocked_count` は冒頭で 0 リセット済みのため、すべてのサマリログで blocked カウンタを安全に表示できる。これにより運用者は「watcher が起動したが PR がなく blocked=0」と「watcher が起動して PR loop を回し blocked=N」を統一フォーマットでログから集計可能（Req NFR 3.1）。
  - **既存 advisory 経路の byte 等価性**: cycle start ログから `strict=not-implemented (split to #281)` 表記が削除されたため、`mode=advisory` の cycle start ログ自体は #279 から **文字列レベルで変化**するが、tasks.md task 8 が「cycle start ログから ... を削除」と明示的に指示しているため意図された変更（design.md L478-486 のフォーマット変更指示と整合）。advisory 経路の他ログ（候補 PR 列挙ログ / severity 集計ログ / Threshold Decision セクション）は一切変更していない（NFR 1.1）。`exec_timeout=unsets` の "unset" + "s" 連結（SECURITY_REVIEW_EXEC_TIMEOUT 未設定時）も #279 から継承された既存挙動で本 task では触らない。
  - smoke 検証（手動 8 ケース）: (1) MODE=strict → cycle log `mode=strict threshold=high`、(2) MODE 未設定 → `mode=advisory threshold=high`、(3) MODE=invalid → WARN + `mode=advisory threshold=high`、(4) MODE=strict + BLOCK_SEVERITY=medium → `mode=strict threshold=medium`、(5) BLOCK_SEVERITY=BadValue → WARN + `threshold=high`、(6) `sec_apply_block_labels` 重複 skip 2 回 → `blocked=0 skipped_blocked=2`、(7) ENABLED=false → 早期 return / ログ出力なし、(8) globals 設定確認 → `_sec_resolved_mode=strict _sec_resolved_threshold=critical`。すべて期待値一致。
  - shellcheck `local-watcher/bin/modules/security-review.sh` 警告ゼロ（info level 含む）。
- 残存課題:
  - task 9（README 追記）は未完了。本 task で導入したカウンタ仕様（`blocked` / `skipped_blocked`）の運用者向け説明は README に追記される予定（tasks.md task 9 の責務）。
  - `_sec_resolved_threshold` グローバルは task 6 のローカル再評価と重複しているが、本機能挙動に影響しないため refactor 見送り（impl-notes Task 7 残存課題と整合）。将来の clean-up で `sec_run_review_for_pr` 内の `_strict_threshold=$(sec_resolve_block_severity)` 再評価を `_strict_threshold="${_sec_resolved_threshold}"` に置き換える形で 1 関数呼び出し分の効率改善が可能だが、本 task の Boundary（`process_security_review`）外のため対応しない。
  - 確認事項: design.md L600 の「`strict 判定 blocking=N threshold=high label-applied=yes|no|skipped`」記述は task 6 で既に実装した `strict 判定 blocking=N threshold=...` ログと差分がある（`label-applied=...` 部分が未実装）。本 task の Boundary は `process_security_review` のみのため、L600 の追加項目は task 6 の修正範囲となり本 task では触れていない。Reviewer / PM レビューで指摘された場合は task 6 の修正で対応すべき。

### Task 9

- 採用方針: README.md の「Security Review Processor (#279)」節を対象に、(1) `### 環境変数`表に 3 行追記 / (2) 表直下の disclaimer 引用ブロックを参照案内 1 行に置換 / (3)「既知の制約」内の strict 拡張表記を撤去 / (4) 新規サブ節「### strict モード（#281）」を `### 利用方法（opt-in 手順）` の直後に追加 / (5)「オプション機能一覧」opt-in 表（line 1284 周辺）に `SECURITY_REVIEW_MODE` / `SECURITY_REVIEW_BLOCK_SEVERITY` の 2 行を追加。env var 名・ラベル名は英語固定、本文は日本語ベース（CLAUDE.md 言語方針準拠）。
- 重要な判断:
  - **既存「Security Review Processor」opt-in 表行の説明文を更新**: 既存行の説明「**advisory 固定**でマージブロックは行わない / strict 拡張は別 Issue #281」は #281 実装完了後の現在 stale となるため、「既定は **advisory 固定**でマージブロックを行わない / strict モードは `SECURITY_REVIEW_MODE=strict` で別途有効化（#281）」に更新した。task 9 の literal interpretation では「行を追加」とのみ指示されていたが、既存行の表記が誤情報となるのを避けるため最小差分で文言を更新した（design.md L264-269 の「strict 拡張は別 Issue として分割済み表記を撤去」の精神に従う / 確認事項として下記に明記）。
  - **新規サブ節の配置位置**: tasks.md / design.md ともに配置位置の明示指定がなかったため、`### 利用方法（opt-in 手順）` の直後・`### 既知の制約` の直前に配置。これにより「利用方法 → strict モード詳細 → 既知の制約 → Migration Note」の論理的な読み流れを保ち、運用者が cron 例を見た直後に strict モードの opt-in 例を参照できる。
  - **strict サブ節の cron 例 2 種**: 「最小 strict 化」例と「閾値・ラベル名カスタマイズ」例の 2 種を載せた。これは Migration Note 内に `SECURITY_REVIEW_BLOCK_SEVERITY` / `SECURITY_REVIEW_BLOCK_LABEL` の override 方法を実例として示し、ドキュメント独立で運用判断が可能になるようにした（tasks.md 指示の「Migration Note: `bash .github/scripts/idd-claude-labels.sh --force` で新規ラベル作成、既存 env / 既存ラベル / cron / exit code は不変」を満たす）。
  - **「既知の制約」節からの strict 拡張 bullet 撤去**: tasks.md 指示「『既知の制約 - strict 拡張は別 Issue として分割済み』表記を撤去」に従い、既存の bullet「**advisory 固定 / マージブロックなし**: ... strict モード ... 未実装 ... 別 Issue に分割済み ...」（6 行）を bullet ごと撤去した。残った 3 bullet（`/security-review` 起動経路の制約 / `security-notes.md` の自動 commit はしない / spec ディレクトリ特定不可時は notes 書き出しを skip）は #281 で挙動が変わらないためそのまま温存。
  - **`### advisory 固定の挙動` 節（line 2270-2284 周辺）は撤去しなかった**: 当該節の本文「strict モードは ... 別 Issue #281 として分割」は #281 完成後の現在 stale だが、task 9 の Boundary は「Security Review Processor (#279) 節」全体ではなく明示的に列挙された箇所（環境変数表 / disclaimer 引用 / 既知の制約 / 新規 strict モードサブ節 / オプション機能一覧）に限定されると解釈した。`### advisory 固定の挙動` 節の文言更新は別 task / 別 PR の責務として残置。
  - 言語方針: 本文は日本語ベース、env var 名（`SECURITY_REVIEW_MODE` 等）・ラベル名（`needs-security-fix` / `needs-iteration`）・コマンド名（`bash .github/scripts/idd-claude-labels.sh --force`）は英語固定。EARS トリガーキーワードは含まない（説明文のため）。
- 残存課題:
  - 確認事項 1: `### advisory 固定の挙動（マージブロックなし）` 節（README L2270-2284）は #279 spec の本文として書かれているため、本 task では撤去・更新を見送った。当該節は #281 strict モード実装後の現在「strict モードは ... 別 Issue #281 として分割」と stale な記述を持つ。Reviewer / PM レビューで「節の本文も更新すべき」と判断された場合は本 task の修正範囲を拡張して当該節も strict モードに言及するよう更新する（追加 commit で対応可能）。
  - 確認事項 2: オプション機能一覧の既存「Security Review Processor」行の説明文を minor 更新した（task 9 literal interpretation は「行を追加」のみだったが、既存行が誤情報となるのを避ける目的）。Reviewer が「既存行は触らないべき」と判断した場合は元の文言「**advisory 固定**でマージブロックは行わない / strict 拡張は別 Issue #281」に戻す（追加 commit で対応可能）。
  - 残存タスク: task 10（静的解析と手動スモークテスト）は per-task ループ内では別 task として扱われる。本 task の追加分は README.md のみであり shellcheck / actionlint / 二重管理整合性 (`diff -r .claude/agents repo-template/.claude/agents` 等) には影響しない（NFR 7.2 構造的に保証）。

### Task 10

- 採用方針: tasks.md task 10 で列挙された 6 種の検証（shellcheck / actionlint / 二重管理 diff × 2 / `idd-claude-labels.sh` の新規ラベル確認 / isolated smoke × 2）をすべて非破壊的に実行し、結果サマリのみを本セクションに記録。実装コードへの追加変更はゼロ（task 10 は検証のみのゲート task）。
- 重要な判断:
  - **shellcheck（5 ファイル）**: `local-watcher/bin/modules/security-review.sh local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh` を一括実行し exit=0 / 出力ゼロを確認（PASS）。task 1〜9 の各 task で個別に shellcheck を通していた結果が、全モジュール一括実行でも警告ゼロを維持していることを最終確認。
  - **actionlint**: `.github/workflows/*.yml` 全 workflow に対して exit=0 / 出力ゼロを確認（PASS）。本機能で workflow 変更はないが、非回帰確認として実行。
  - **二重管理 diff（`.claude/agents` / `.claude/rules`）**: `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` の双方が exit=0 / 出力ゼロ（PASS）。本機能では agents / rules を 1 ファイルも編集していないことを構造的に確認（NFR 7.2）。
  - **`idd-claude-labels.sh` の新規ラベル確認**: 本検証は `gh` CLI 認証 + 実 scratch repo 作成が必要なため、tasks.md 原文で許容された代替手段「スクリプトの LABELS 配列に `needs-security-fix` 行が含まれることを grep 検証する形でも可」を採用。`grep -n needs-security-fix .github/scripts/idd-claude-labels.sh` で line 81 にラベル定義行が存在することを確認（PASS）。実際の `gh label create` 動作は task 1 完了時に LABELS 配列形式（`name|color|description`）の規約準拠を確認済みであり、本 task では追加の実 API 呼び出しは不要と判断（NFR 5.1 観点では構造検証で十分）。
  - **isolated smoke（cycle start ログ）**: `/tmp/smoke-281-task10.sh` を作成し、`sec_log` / `sec_warn` を最小スタブで定義 + `sec_fetch_candidate_prs` を `echo "[]"` でモックして候補 PR ゼロ状態を再現。`SECURITY_REVIEW_MODE=strict` で `cycle start: mode=strict threshold=high` を、`SECURITY_REVIEW_MODE` 未設定で `cycle start: mode=advisory threshold=high` を観測（双方 PASS）。サマリログの `blocked=0 skipped_blocked=0` カウンタも task 8 仕様通り両ケースで出力されることを確認。
  - **#279 byte 等価性**: MODE 未設定時の cycle start ログは `mode=advisory threshold=high max_prs=unset ...` の形式で、#279 の cycle start ログ（`strict=not-implemented (split to #281)` 表記を持つ）と **literal な byte レベルでは差分がある**（task 8 で `strict=not-implemented` 表記を削除し `threshold=` を追加したため）。これは tasks.md task 8 が明示的に指示した変更であり、NFR 1.1 が要求する「観測可能な advisory 経路の挙動」自体（PR 検出件数 / コメント投稿 / security-notes 書き出し）は不変であることを task 6〜8 の smoke で確認済み。本 task の smoke は「cycle start ログのフォーマット仕様（`mode=...` / `threshold=...` トークン）が task 8 の意図通りであること」の確認であり、NFR 1.1 の意味的な byte 等価性（advisory 経路の review / label / notes 挙動）は task 6 / 7 / 8 の smoke で別途確認済み。
- 残存課題:
  - 本 task の検証はすべて PASS。本 spec の全 10 task が完了したため、後続 task は存在しない。
  - 確認事項: tasks.md task 10 原文の「`bash .github/scripts/idd-claude-labels.sh --repo <test-repo>` で新規ラベル `needs-security-fix` が作成されること（scratch repo で確認）」については `gh` CLI 認証付き scratch repo 作成が必要なため未実施。代替として LABELS 配列の grep 検証で構造的に保証した。Reviewer / PM レビューで「実 API 呼び出しによる確認が必要」と判断された場合は、別途 dogfooding repo（idd-claude 自身）に対して `bash .github/scripts/idd-claude-labels.sh --force` を実行することで検証可能（merge 後の運用 deployment ステップに相当）。
  - 検証用 fixture `/tmp/smoke-281-task10.sh` は `/tmp` 配下に置いた一時スクリプトであり、リポジトリには commit しない（既存の smoke fixture は spec 配下に保存する慣習だが、本 task の検証内容は impl-notes 本文で完全に再現可能であり、また `sec_log` / `sec_warn` のモック内容も上記に列挙したため、追加の fixture ファイルは不要と判断）。
