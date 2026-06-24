# Implementation Notes

## 確認事項

なし

## Implementation Notes

### Task 1
- 採用方針: `core_utils.sh` 末尾に `adj_log` / `adj_warn` / `adj_error` の 3 関数を既存 `pr_log` / `pi_log` と同形式（`[YYYY-MM-DD HH:MM:SS] [$REPO] adjudicator:` prefix）で追加。`issue-watcher.sh` Config ブロックの `PR_REVIEWER_STATUS_CHECK_ENABLED`（#349 / line 638-659）直後・`SECURITY_REVIEW_ENABLED`（#279 / line 661 以降）直前に「PR Reviewer Adjudicator 設定 (#404)」節を追加し、6 env を `${VAR:-default}` で解決。
- 重要な判断: (1) `ENABLED` の正規化は既存 `PR_REVIEWER_STATUS_CHECK_ENABLED` の `case … in true) … *) false ;;` パターンを踏襲（Req 5.5 既存規約整合）。(2) `EXEC_TIMEOUT` / `MAX_FINDINGS` の数値正規化は既存 `PR_REVIEWER_EXEC_FAIL_LIMIT`（issue-watcher.sh:603-611）と同じ `case ''|*[!0-9]*) … *) lt 1 ;;` イディオムを採用。(3) `FALLBACK_ON_FAIL` の既定は design.md「Architecture Decision: claude-review publisher contention」と「env var 仕様」表に従い `passthrough`（adjudicator SPOF 緩和 / 独立 Reviewer の verdict 尊重）に倒し、コメントに根拠を 1 段落で明記。(4) `MODEL` は空文字の場合に既定 `claude-sonnet-4-5` へ追加 fallback する明示分岐を入れた（`${VAR:-default}` だけだと `=""` 明示の場合に空文字が通る既知挙動の救済）。
- 残存課題: なし。本 task 終了時点で gate OFF 既定下の挙動は未変更（adjudicator.sh / REQUIRED_MODULES への登録は task 3 のスコープ。task 2 以降が `adj_log` / 6 env を消費する前提を整備済み）。検証結果: `bash -n` / `shellcheck` 警告ゼロ / 既存テスト 3 種（pr_publish_commit_status / pr_publish_claude_status_from_branch / pr_default_prompt）退行ゼロ / env 解決スモークで既定値 6 件 + 不正値正規化 4 件 + 合法 ON 値 5 件をすべて期待値どおり確認。

### Task 2
- 採用方針: `local-watcher/bin/adjudicator-prompt.tmpl` を 185 行で新規作成。冒頭コメントブロックは既存 `iteration-prompt.tmpl` / `triage-prompt.tmpl` の style（用途 / 配置先 / 依存 / 関連 / プレースホルダ一覧）に整合させ、本文は `pr_default_prompt`（pr-reviewer.sh:691）の単一波括弧 `{PR}` 規約に倣う。本文構造は「役割宣言 → 対象 PR メタ → REVIEW_TEXT 埋め込み → id 採番規約 → requirements.md 埋め込み → 分類基準（legitimate a-d / excessive 候補 a-d / 迷ったら legitimate）→ 全指摘 1:1 対応の義務 → read-only 制約 → JSON 出力契約」の順に並べた。
- 重要な判断: (1) **placeholder 規約の選定**: `iteration-prompt.tmpl` の `{{PR_NUMBER}}` 二重波括弧 style と `pr_default_prompt` の `{PR}` 単一波括弧 style のどちらに整合させるかが論点。adj は pr-reviewer.sh の bash パラメータ置換（`${var//\{PR\}/$pr}`）で扱う前提のため `pr_default_prompt` 側の単一波括弧に揃え、選定根拠を冒頭コメントの NOTE に明記。(2) **id 採番規約の明示**: design.md「Data Models」では `id: 1` 以降の整数を要求するが、adjudicator.sh 側 parse 結果に依存させると round-trip 不整合の余地が残る。本テンプレ内で「`## 指摘事項` 配下 bullet 行を登場順に id=1, 2, 3 と独立採番」を Claude 側に明示し、adj 側 parse 順序とは独立にした（design.md「Components and Interfaces」の `adj_extract_findings` 戻り値順と Claude 採番が一致する前提を明文化）。(3) **重複指摘の扱い**: design.md Open Q2「重複は別 finding として excessive 判定」を default としているため、本テンプレでも「集約はしない」「重複は別 finding として個別判定」を明示してプロンプト挙動を確定。(4) **「迷ったら legitimate」原則の根拠を本文に書く**: 単に「迷ったら legitimate」と命じるだけでなく、「実害指摘の見落とし（excessive 誤判定 → merge 後にバグ発覚）」が最悪 outcome、「legitimate 過判定は反復 round が 1 つ増えるだけ」が次悪 outcome であることを明示し、Claude が確信度の低い判定で excessive に倒すインセンティブを構造的に下げた（Req 1.4 の徹底）。(5) **コードフェンスで囲まない指示**: `claude --output-format json` が raw JSON を期待し、再 strip をしない呼び出しパスを前提に、出力本文を ` ``` ` で囲まないことを 2 箇所（read-only 制約節と JSON 出力契約節）で再強調。
- 残存課題: なし。本 task 終了時点で `adjudicator-prompt.tmpl` はディスク上に存在するが、参照する `adj_classify_findings` 本体（task 4）は未実装のため実行経路は発火しない。install.sh の既存 `copy_glob_to_homebin "$LOCAL_WATCHER_DIR/bin" "*.tmpl" "$HOME/bin"`（install.sh:1357）が glob で自動配布するため install.sh は touch せず、`grep -n 'tmpl' install.sh` で当該行が健在であることを確認済み。検証結果: `shellcheck` 警告ゼロ（.sh 群の非退行確認） / 既存テスト 3 種 PASS=178 FAIL=0 / `diff -r .claude/agents repo-template/.claude/agents` 差分ゼロ / `diff -r .claude/rules repo-template/.claude/rules` 差分ゼロ / placeholder 7 種（`{PR}` / `{SHA}` / `{BASE}` / `{HEAD}` / `{REVIEW_TEXT}` / `{SPEC_DIR}` / `{REQUIREMENTS_MD}`）すべてテンプレ内に存在することを `grep -oE '\{[A-Z_]+\}' ... | sort -u` で確認 / JSON schema キー 11 種（`decisions` / `summary` / `total` / `legitimate` / `excessive` / `verdict` / `reason` / `severity` / `id` / `file` / `line`）すべてテンプレ内に出現することを確認。

## AC Traceability

| Requirement | 担保方法 |
|---|---|
| Req 5.1（opt-in gate / 安全側正規化） | `PR_REVIEWER_ADJUDICATOR_ENABLED` の `case true) ... *) false` 正規化、`FALLBACK_ON_FAIL` の `legitimate|passthrough` 以外を `passthrough` に倒す `case`、数値 env の `case ''|*[!0-9]*) ... lt 1` 正規化（env 解決スモークで `True` / `invalid_value` / `abc` / `-5` がすべて既定値に倒れることを確認） |
| Req 5.3（既存 env 名・既定値・意味の不変性） | 既存 env 名（`PR_REVIEWER_STATUS_CHECK_ENABLED` / `SECURITY_REVIEW_ENABLED` / 周辺）は touch せず、新規 6 env のみ追加。既存テスト 3 種が PASS=178 で退行ゼロを確認 |
| Req 5.5（既存 exit code・ログ stderr/stdout 契約の不変性） | `adj_log` は stdout、`adj_warn` / `adj_error` は `>&2`。既存 `pr_log` / `pi_log` / `sec_log` 群と同一の関数シグネチャを保持。Config 節は env 解決と正規化のみで exit code を変更しない |
| Req 4.4（ログ prefix・timestamp 書式の既存規約整合） | 3 関数の出力書式が `[YYYY-MM-DD HH:MM:SS] [$REPO] adjudicator:` で既存 `pr_log` 等と byte レベルで揃う（diff 確認） |

## 検証コマンドと結果

| コマンド | 結果 |
|---|---|
| `bash -n local-watcher/bin/modules/core_utils.sh` | OK |
| `bash -n local-watcher/bin/issue-watcher.sh` | OK |
| `shellcheck local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh` | 警告ゼロ |
| `bash local-watcher/test/pr_publish_commit_status_test.sh` | PASS=74 FAIL=0 |
| `bash local-watcher/test/pr_publish_claude_status_from_branch_test.sh` | PASS=52 FAIL=0 |
| `bash local-watcher/test/pr_default_prompt_test.sh` | PASS=52 FAIL=0 |
| env 解決スモーク（既定値 / 不正値 / 合法 ON 値の 3 系統） | 既定 6 env 期待値一致、不正値 4 件すべて既定に正規化、合法 ON 値 5 件透過 |

STATUS: complete
