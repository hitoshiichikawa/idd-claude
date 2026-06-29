# 実装ノート（Issue #433: Design PR Reviewer の空虚 approve バグ修正）

## 概要

Design PR Reviewer が spec 本文を作業ツリーから `cat` で読んでいたため、base チェックアウト中の
watcher 作業ツリーには新規設計 PR の spec dir が存在せず、全観点が `(none)` になり空虚 approve
が出ていたバグを修正。spec 本文を **head ブランチの git ref（`origin/<head_ref>`）** から取得
するよう変更し、取得不能時は Claude を起動せず `pending` 据え置きする fail-closed を追加した。

## 変更ファイルと AC 対応

| ファイル | 変更内容 | AC |
|---|---|---|
| `local-watcher/bin/modules/pr-design-reviewer.sh` | `pdr_invoke_reviewer`: 作業ツリー `[ -d ]`+`cat` を `git cat-file -e "origin/<ref>:<path>"`→`git show ...` に置換（adjudicator.sh L693-704 同方式）。Claude 起動前に fail-closed 判定（spec dir 空 / 3 ファイル全取得不能 → rc=3）+ WARN を追加。`pdr_run_review_for_pr`: rc=3 を既存 pending 据え置き（rc=2）へ写像し観測ログ 1 行を追加 | Req 1.1-1.5 / 2.1-2.5 / 3.1-3.2 / 4.3 / NFR 1.4 / 3.1 |
| `local-watcher/bin/design-review-prompt.tmpl` | 「spec dir 不在 / ファイル不在 → 保守的 approve」記述を「spec 本文取得不能は fail-closed で本プロンプトに到達しない / 部分 `(none)` のみ保守的判定」へ修正。3 観点判定基準・reject 禁止事項・read-only 制約は不変 | Req 5.1 / 5.3 |
| `README.md` | Design PR Reviewer 節（カタログ行 L1498 / 動作概要 / 典型運用例 / トレードオフ）を fail-closed = `pending` 据え置きと整合する記述へ更新（同一 PR） | Req 5.2 |
| `local-watcher/test/pdr_invoke_reviewer_spec_fetch_test.sh` | 新規。git ref 取得経路・fail-closed・部分取得境界を検証 | Req 1 / 2 / 3 / 4 |
| `local-watcher/test/pdr_fail_closed_pending_test.sh` | 新規。rc=3→rc=2 写像・副作用ゼロ・観測ログ・非回帰を検証 | Req 2.4 / NFR 1.4 / 3.1 |

## fail-closed の rc 設計と既存 rc=2 経路との整合

- `pdr_invoke_reviewer` に **新 rc=3**（spec 本文取得不能）を追加。Claude 起動の **前**に評価し、
  `spec_dir_rel` 空（Req 2.2）または 3 ファイル全取得不能（Req 2.1/2.3）で rc=3 を返す。
  既存 rc=1（exec 失敗）/ rc=2（workspace-modified）と衝突しない値を選定。
- `pdr_run_review_for_pr` の既存 `[ "$invoke_rc" -ne 0 ]` 分岐が rc=3 も捕捉するため、
  **rc=2（pending 据え置き）へ写像**。`pdr_run_review_for_pr` の exit code 意味（0/1/2）は不変
  （NFR 1.4）。fail-closed と exec 失敗で観測ログ文言を分岐（NFR 3.1）。
- これにより fail-closed は既存 exec 失敗時 pending 据え置き経路と **同一の status / ラベル契約**
  （marker・コメント・status を投稿しない / 次サイクル再試行 / Req 2.4）を共有する。

## 部分取得の扱い

AC 2.1 は「1 つも取得できない」が fail-closed 条件。よって **3 ファイル中 1 つでも取得できれば
fail-closed しない**（`fetched_count > 0`）。取得できなかったファイルのみ `(none)` を埋め込み、
prompt 側の「部分 `(none)` は保守的判定」に委ねる（Req 1.4 / 1.5）。テスト ケース 4 で境界を担保。

## 追加テストと実行結果

- `pdr_invoke_reviewer_spec_fetch_test.sh`: PASS 18 / FAIL 0
- `pdr_fail_closed_pending_test.sh`: PASS 7 / FAIL 0
- 既存 pdr テスト全件 非回帰: already_processed 12 / apply_decision 38 / classify 10 /
  no_op 16 / parse_verdict 34 / resolve_gate 14 すべて FAIL 0
- `bash -n` 全対象 OK / `shellcheck`（module + 新テスト 2 本）警告ゼロ
- `diff -r .claude/agents repo-template/.claude/agents` / `diff -r .claude/rules ...` ともに空

## AC Traceability（担保テスト）

| AC | 担保 |
|---|---|
| 1.1 / 1.2 / 1.3 | spec_fetch ケース 1（各ファイル実本文がプロンプトに埋め込まれる） |
| 1.4 | spec_fetch ケース 4（取得不能ファイルは `(none)`） |
| 1.5 | spec_fetch ケース 1（取得成功時 `(none)` を埋め込まない）/ ケース 4（取得分は実本文） |
| 2.1 / 2.3 | spec_fetch ケース 2（全取得不能 → rc=3）/ fail_closed_pending ケース 1 |
| 2.2 | spec_fetch ケース 3（spec dir 空 → rc=3） |
| 2.4 | fail_closed_pending ケース 1（rc=2 写像 / 副作用ゼロ） |
| 2.5 | spec_fetch ケース 2/3（Claude 未起動） |
| 2.6 | 既存 pdr_no_op テスト（ラベル / status 契約不変）で間接担保 |
| 3.1 | spec_fetch ケース 2（WARN に解決済み dir + 取得不能の事実） |
| 3.2 | fail_closed_pending ケース 1（fail-closed で verdict=approve 完了ログを出さない） |
| 4.1 / 4.2 / 4.3 | fail_closed_pending ケース 4（取得成功時の parse/validate→approve 経路 非回帰） |
| 5.1 / 5.3 | design-review-prompt.tmpl 更新（コードレビューで確認） |
| 5.2 | README 更新（コードレビューで確認） |
| NFR 1.1-1.4 | 既存 env / ラベル / status 名 / exit code 不変（pdr 全テスト非回帰 + コードレビュー） |
| NFR 2.1 | diff -r 空（module/template は repo-template にコピーなし） |
| NFR 3.1 | fail_closed_pending ケース 1（pending 据え置きの観測ログ 1 行） |

## 確認事項（requirements.md Open Questions の引き継ぎ + 実装判断）

- **① fail-closed の非 approve 手段の確定**: 本実装は requirements.md の第一候補
  「`pending` 据え置き + 次サイクル再試行」（既存 rc=2 経路への写像）で確定した。Issue 本文が
  幅を持たせた `reject`（`needs-iteration` 付与による Architect 反復起動）案を採るべきか
  （新規設計 PR の spec dir 解決不能は PR 構成の異常であり反復で是正を促せる利点）は人間判断を
  仰ぎたい。第一候補で確定してよいか確認したい。
- **② 人間 escalation 素通しガードのスコープ可否**: コメント（PR#55 / ae-mdm #52）で提示された
  「判定本文に未解決の確認事項 / 人間 escalation を含む設計 PR の approve 保留」ガードは、
  requirements.md で Out of Scope（別 Issue 候補）と判断されている。本 Issue（データ供給バグの
  修正）に同梱すべきか別 Issue とするかは人間判断を仰ぎたい。本実装には含めていない。
- **③ 部分取得の扱い（実装判断）**: AC 2.1「1 つも取得できない」に厳密に従い、3 ファイル中 1 つ
  でも取得できれば fail-closed しない実装とした（取得不能分は `(none)` で prompt の保守的判定に
  委譲）。これが意図どおりか確認したい（より厳格に「3 ファイル全取得必須」とする選択肢もある）。

STATUS: complete
