# Implementation Notes — #412 PR Reviewer Adjudicator default-flip + merge gate visibility

## 設計判断

### 1. 既定反転の正規化パターン

`PR_REVIEWER_ADJUDICATOR_ENABLED` の既定反転は、#112 で導入済の「default ON / `=false`
厳密一致で OFF」パターン（`MERGE_QUEUE_ENABLED` / `PR_ITERATION_ENABLED` 他 8 種）を踏襲。
2 段正規化:

- 1 段目（変数宣言ブロック、`local-watcher/bin/issue-watcher.sh:685-695` 付近）: `:-true` 既定 +
  `case false) :;; *) true` でローカル正規化。
- 2 段目（`デフォルト有効化フラグの値正規化` ループ、`issue-watcher.sh:1355-1374` 付近）:
  `PR_REVIEWER_ADJUDICATOR_ENABLED` を `for _idd_flag in ...` リストに追加し、最終的に
  `"true"` / `"false"` の 2 値に固定。

これにより未設定 / 空 / `True` / `TRUE` / `1` / `0` / typo はすべて `"true"` に、明示
`"false"` のみ `"false"` に正規化される（Req 1.1〜1.5）。`adj_gate_enabled` は厳密 `=true`
判定のため、契約は不変（Req 5.2 / Req 5.5）。

### 2. fallback 既定 `passthrough` を維持

要件 2.1 が「未設定 = passthrough 相当で初期化」と明示しているため、`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL`
の既定値は **変更せず**（コメントだけ更新）。理由: adjudicator が default ON で全 consumer repo
で常時起動する状態でも、claude exec の SPOF（quota / rate-limit / timeout / parse 失敗）を
catch-up 経路へ吸収できる構造を残すため。`legitimate` モードに既定変更すると `claude exec
失敗 → 全 finding legitimate → claude-review = failure` の即 block 経路が default となり、
catch-up 経路の SPOF 緩和効果を捨てることになる。Architecture Decision: claude-review
publisher contention の SPOF 緩和方針と整合。Req 2.1, 2.4, 2.5 を充足。

### 3. merge gate 可視化の実装方針 / 配置先

ガイダンス 4 と CLAUDE.md「機能追加ガイドライン §1」に従い、**新規モジュールは作らず**
`local-watcher/bin/modules/pr-reviewer.sh` 末尾に `mgv_*` namespace（merge gate visibility）で
4 関数 + 1 processor を同居。既存 `process_claude_review_status_catchup` の隣接処理として
配置することで「`claude-review` publisher 経路の責務群」が同一モジュール内にまとまる。

判定要素:

- `mgv_claude_review_required` — `gh api repos/{owner}/{repo}/branches/{branch}/protection` で
  `required_status_checks.contexts` を取得し `claude-review` の有無を判定。404（protection 未設定）
  は rc=2 で fail-safe（呼び出し元 skip）。
- `mgv_pr_has_claude_review_status` — `gh api repos/{owner}/{repo}/commits/{sha}/statuses` を
  読み、`claude-review` context の publish 履歴があるかを判定。
- `mgv_pr_has_adjudicator_marker` — `gh pr view --json comments` で `<!-- idd-claude:pr-adjudicator
  sha=<sha> -->` marker の存在を判定（`pr_catchup_should_defer_for_adjudicator` と同方式）。
- `mgv_add_attention_label` / `mgv_remove_attention_label` — `needs-merge-gate-attention` ラベルの
  冪等付与・解消（Req 4.3）。
- `process_claude_review_merge_gate_visibility` — 1 サイクル冒頭で `mgv_claude_review_required`
  を 1 回呼び、required でなければ即 return 0（NFR 1.1 ほぼ no-op）。required なら open PR を
  scan し、`claude-review` status 既 publish or adjudicator marker あり → label 解消、両方
  ともない → label 付与 + 1 行観測ログ（Req 4.1, 4.2, 4.3）。

新規ラベル `needs-merge-gate-attention` を `root` と `repo-template` の
`.github/scripts/idd-claude-labels.sh` 両系統に同期反映。

### 4. 起動時ログへの追加

`issue-watcher.sh:1517` の cycle startup ログに `pr-reviewer-adjudicator=${PR_REVIEWER_ADJUDICATOR_ENABLED}`
を追加（Req 1.6 / NFR 2.2）。運用者は `grep pr-reviewer-adjudicator= cron.log` で各サイクルの
解決値を事後に確認できる。`=false` 明示の opt-out 環境を識別する目的を兼ねる。

### 5. shellcheck SC2153 回避

mgv_claude_review_required の引数を `base_branch` ではなく `base_branch_arg` と命名。
既存コード（line 866 / 1414 の trap / base_ref 設定）が `${BASE_BRANCH}` グローバル env を
参照しており、同名ローカル変数を新規導入すると shellcheck info SC2153
（"Possible misspelling: BASE_BRANCH may not be assigned"）が新規発火するため、
変数名を差別化して回避。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`
  - L661-695: `PR_REVIEWER_ADJUDICATOR_ENABLED` 既定値 / 正規化 case 文 / コメント更新
  - L1348-1366: 「デフォルト有効化フラグの値正規化」ループに `PR_REVIEWER_ADJUDICATOR_ENABLED`
    を追加
  - L1517: cycle startup ログに `pr-reviewer-adjudicator=` を追加
  - L1960-1969: `process_claude_review_merge_gate_visibility` の dispatch を追加
- `local-watcher/bin/modules/adjudicator.sh`
  - L14-17 / L54-58: `adj_gate_enabled` の前提コメントを default ON 化に追従
- `local-watcher/bin/modules/pr-reviewer.sh`
  - L1898-2103（追加）: `mgv_*` ヘルパー群 + `process_claude_review_merge_gate_visibility`
- `local-watcher/test/pr_reviewer_adjudicator_default_on_test.sh`（新規 / 16 cases）
- `local-watcher/test/mgv_merge_gate_visibility_test.sh`（新規 / 15 cases）
- `local-watcher/test/adj_resolve_gate_test.sh`: 冒頭コメントを default-flip 整合性に更新
  （テスト本体は契約不変のため変更なし）
- `.github/scripts/idd-claude-labels.sh`: `needs-merge-gate-attention` 追加
- `repo-template/.github/scripts/idd-claude-labels.sh`: 同期追加
- `README.md`:
  - 行 1489 オプション機能一覧表で adjudicator 既定値を `true`（opt-out）に更新
  - 行 2987 以降の Adjudicator 節を opt-out 既定 ON 表現に書き換え
  - `claude-review` publisher 契約節を追加（3 publisher の責務分担を明示）
  - 推奨設定の組み合わせ表を追加（4 シナリオ × env 値）
  - Migration Note に既定反転の migration / 新規ラベル / 起動時ログを追記
  - 停滞 PR 可視化の運用手順を「`claude-review` 必須化シフトの consumer 手順」に追加（Req 4.5）

## AC Traceability

| AC ID | 要件サマリ | 実装 | テスト |
|---|---|---|---|
| 1.1 | 未設定 → adjudicator ON | `issue-watcher.sh:685-695` `:-true` + case + 正規化ループ | `pr_reviewer_adjudicator_default_on_test.sh: Req 1.1` |
| 1.2 | 空文字 → ON | 同上 | 同 test: Req 1.2 |
| 1.3 | `=true` → ON | 同上 | 同 test: Req 1.3 |
| 1.4 | `=false` → OFF | 同上 | 同 test: Req 1.4 / 5.1 |
| 1.5 | `True` / `TRUE` / `1` / `0` / typo → ON | 同上 | 同 test: Req 1.5 (8 cases) |
| 1.6 | 起動時ログで判別 | `issue-watcher.sh:1517` `pr-reviewer-adjudicator=` 追加 | cron-like dry-run で目視確認（impl-notes 検証ログ要約参照） |
| 2.1 | 未設定 = passthrough 既定 | `issue-watcher.sh:714-718` 既定値維持（変更なし） | 既存 `adj_*` tests で fallback パス検証済 |
| 2.2 | `=legitimate` → 徹底安全側モード | 既存 case 文不変 | 既存 adj 系 tests |
| 2.3 | typo / 空 → passthrough 正規化 | 既存 case 文不変 | 既存 adj 系 tests |
| 2.4 | claude 失敗時の fallback 分岐 | `adjudicator.sh` 既存実装（不変） | 既存 adj 系 tests |
| 2.5 | README に根拠明示 | `README.md` 「`PR_REVIEWER_ADJUDICATOR_FALLBACK_ON_FAIL` の意味」節更新 | 手動レビュー |
| 3.1 | publisher 責務分担を README に明示 | `README.md` 新規節「`claude-review` publisher 契約」 | 手動レビュー |
| 3.2 | marker 判定規則を README に明示 | `README.md` 既存節「動作概要 5.」+ publisher 契約節 | 手動レビュー |
| 3.3 | codex 併用時の推奨組み合わせ | `README.md` 新規節「推奨設定の組み合わせ」（4 シナリオ表） | 手動レビュー |
| 3.4 | migration note | `README.md` Migration Note 節更新（既定反転 + 新規ラベル + ログ追加） | 手動レビュー |
| 3.5 | コメント「opt-in / 既定 OFF」削除 | `issue-watcher.sh:661-685` / `adjudicator.sh:14-17, 54-58` | 手動レビュー |
| 4.1 | 停滞状態を判別可能なログ | `pr-reviewer.sh:process_claude_review_merge_gate_visibility` 1 行ログ | `mgv_merge_gate_visibility_test.sh` Req 4.1 (3 cases) |
| 4.2 | 可視化手段（ラベル / コメント / status）1 つ以上 | `needs-merge-gate-attention` ラベル付与 | 同 test (helper functions) |
| 4.3 | 解消時の冪等取り消し | ケース 1（status 既 publish）/ ケース 2（marker あり）で `mgv_remove_attention_label` | 同 test Req 4.3 (3 cases) |
| 4.4 | fallback 経路を優先（marker 不在で発火） | marker 判定で `passthrough` の skip 動作と整合 | 同 test Req 4.4 |
| 4.5 | 推奨対応手順を README に明示 | `README.md` consumer 手順節に「5. 停滞 PR 可視化」追加 | 手動レビュー |
| 5.1 | `=false` 明示環境は本変更前と等価 | case 文 + 正規化ループで `false` 厳密一致のみ OFF | `pr_reviewer_adjudicator_default_on_test.sh: Req 5.1` |
| 5.2 | `=true` 明示環境は ON 維持 | 同上（=true 明示も ON に正規化） | 同 test: Req 5.2 |
| 5.3 | 他の `PR_REVIEWER_ADJUDICATOR_*` env 不変 | `issue-watcher.sh:691-728` 変更なし | 既存 adj 系 tests |
| 5.4 | env 名 / path / exit code / cron 文字列不変 | 名称・経路すべて維持 | 既存テスト群（78 件 pass）で網羅 |
| 5.5 | ラベル名 / commit status 名不変 | 不変 | 同 |
| 5.6 | log prefix 不変 | `adj_log` / `pr_log` の prefix 形式不変 | 同 |
| 6.1 | root ↔ repo-template agents byte 一致 | `diff -r` で空（変更ゼロ） | `diff -r .claude/agents repo-template/.claude/agents` |
| 6.2 | root ↔ repo-template rules byte 一致 | 同上 | `diff -r .claude/rules repo-template/.claude/rules` |
| 6.3 | README は同一 PR で更新 | 上記 README 更新 | 手動レビュー |
| 6.4 | コメントと README の整合 | `issue-watcher.sh` / `adjudicator.sh` コメントと README 表記を同期 | 手動レビュー |
| 7.1 | shellcheck 警告ゼロ | 全モジュール shellcheck 0 警告 | `shellcheck local-watcher/bin/*.sh modules/*.sh ...` rc=0 |
| 7.2 | 最小 PATH で default ON 起動 | cron-like dry-run で `pr-reviewer-adjudicator=true` 出力確認 | 検証ログ要約参照 |
| 7.3 | 各 env 値での解決スモーク | 16 cases の正規化 test | `pr_reviewer_adjudicator_default_on_test.sh` |
| 7.4 | dry-run exit code 維持 | cron-like dry-run で REPO_DIR 不在まで到達 | 検証ログ要約参照 |
| NFR 1.1 | `=false` 環境で副作用ゼロ | `adj_gate_enabled` 厳密 `=true` 判定で early return | 既存 `adj_integration_no_op_test.sh` |
| NFR 1.2 | `=true` 環境で機能セット維持 | 既存 adj 経路不変 | 既存 adj 系 tests |
| NFR 1.3 | env / ラベル / status / exit code / log prefix 不変 | 上記 5.x 群と同 | 78 tests |
| NFR 2.1 | 観測ログ粒度維持 | `adj_log_summary` 1 行サマリ不変 + merge-gate 可視化は 1 行 / PR | 検証ログ要約参照 |
| NFR 2.2 | 可視化発火の根拠 grep 可能 | `merge-gate-visibility:` prefix + required ステータス名 + 不在理由を含む 1 行 | 手動目視 |
| NFR 3.1 | self-hosting で merge 直後の壊れない | 既存 `claude-failed` 等のラベル運用に影響なし / `passthrough` 既定維持で SPOF 緩和 | 設計判断 2 参照 |

## 確認事項（後段 Reviewer / PjM への申し送り）

1. **default ON 化の self-hosting 即時影響**: 本 PR が main に merge された瞬間、idd-claude
   自身の watcher が次サイクルから adjudicator 経路で動作します。`PR_REVIEWER_ENABLED=true`
   を有効化していない場合は adjudicator hook が `pr_run_review_for_pr` の中で発火しないため
   影響なしですが、有効化済みなら全 open PR で adjudicator が走ります。pilot 観察の準備として
   `cron.log` の `[adjudicator]` prefix を監視することを推奨。

2. **merge gate 可視化の watcher 自身への影響**: `process_claude_review_merge_gate_visibility`
   は 1 サイクル冒頭で `gh api repos/.../branches/main/protection` を必ず 1 回呼びます。
   idd-claude 自身の main branch protection に `claude-review` を required にしていなければ
   即 return 0 で副作用ゼロ。required にしている場合は `needs-merge-gate-attention` ラベルが
   付与される PR が出てくる可能性があるので、初回 cycle の `cron.log` 確認を推奨。

3. **`PR_REVIEWER_ENABLED=true` の前提**: README とコード本文では何度も明記していますが、
   adjudicator hook 自体が `pr_run_review_for_pr` の末尾で呼ばれるため、`PR_REVIEWER_ENABLED=false`
   の repo では adjudicator は default ON でも実際には起動しません。altpocket-server #139 の
   ような codex 過剰指摘問題に対する効果は `PR_REVIEWER_ENABLED=true` の repo に限定されます。
   要件 1.1 の文意は「`PR_REVIEWER_ADJUDICATOR_ENABLED` を追加設定なしで既定 ON」と解釈し、
   `PR_REVIEWER_ENABLED` 側の既定値は変更していません（Out of Scope と整合）。

4. **既存テスト `adj_resolve_gate_test.sh` の意図**: `adj_gate_enabled` 関数の契約は本 PR で
   不変です（厳密 `=true` 一致のみ ON）。本テストは正規化後の値を直接受け取った場合の判定を
   検証しており、既定反転後も同テストは pass し続けます。冒頭コメントだけ「正規化前の値での
   既定挙動は別ファイル `pr_reviewer_adjudicator_default_on_test.sh` で検証」と追記しました。

5. **`needs-merge-gate-attention` ラベル展開タイミング**: 新規ラベルは `idd-claude-labels.sh`
   再実行時に展開されます。本 PR を merge した既存 consumer repo は、次回 `./install.sh
   --local` または手動 `gh label list` 補完で当該ラベルを作成しなければ、`mgv_add_attention_label`
   が `gh pr edit --add-label` 失敗で WARN を出す可能性があります。WARN は silent fail に
   なっていないため動作の妨げにはなりませんが、運用ドキュメントに「本 PR merge 後に
   `idd-claude-labels.sh` 再実行を推奨」と明記する余地がある（README Migration Note には
   入れています）。

## 検証ログ要約

- `shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` → rc=0（警告ゼロ）
- `actionlint .github/workflows/*.yml` → rc=0
- `bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/pr-reviewer.sh local-watcher/bin/modules/adjudicator.sh` → OK
- `diff -r .claude/agents repo-template/.claude/agents` → 出力なし（byte 一致）
- `diff -r .claude/rules repo-template/.claude/rules` → 出力なし（byte 一致）
- 全 78 テスト（`local-watcher/test/*.sh`）pass / fail=0
  - 新規 `pr_reviewer_adjudicator_default_on_test.sh` 16 cases pass
  - 新規 `mgv_merge_gate_visibility_test.sh` 15 cases pass
  - 既存 `adj_resolve_gate_test.sh` 8 cases pass（契約不変）
- cron-like 最小 PATH（`env -i HOME=$HOME PATH=/usr/bin:/bin`）スモーク起動:
  - 起動時 1 行サマリログに `pr-reviewer-adjudicator=true` を出力（Req 1.6 / 7.2 充足）
  - 後段は `REPO_DIR` 未配置で停止（Req 7.4 の「処理対象なし」相当の正常 exit code 維持は本
    smoke 環境では確認できないが、当該分岐の挙動は本 PR で touch していない）

STATUS: complete
