# 実装ノート — #112 feat(watcher): opt-in env var 9 種をデフォルト true に変更

## 変更ファイル一覧

- `local-watcher/bin/issue-watcher.sh` — 8 種の `:-false` → `:-true` 反転、Config
  ブロック末尾に値正規化ループ追加、`run_impl_pipeline` 冒頭の Stage Checkpoint gate を
  `${STAGE_CHECKPOINT_ENABLED:-false}` → `${STAGE_CHECKPOINT_ENABLED:-true}` に揃え。
  関連コメントを「初回導入は opt-in（デフォルト false）」から「標準機能としてデフォルト
  有効（#112）」相当の文言に書き換え。
- `README.md` — 「オプション機能一覧」節を再構成し、デフォルト有効 8 種を専用表に分離。
  表上部にインライン migration note を追加。各機能セクション（Phase A / Re-check / PR
  Iteration / 設計 PR 拡張 / Design Review Release / Quota-Aware / impl-resume Branch
  Protection / Stage Checkpoint）の環境変数表を「`true`」既定 / 推奨欄「無効化する場合
  のみ `false`」に統一。cron 例を反転（明示 opt-out 例）。
- `CLAUDE.md` — 禁止事項節「opt-in gate なしで新しい外部サービス呼び出しを有効化」に
  #112 のデフォルト反転が本禁止事項の対象外である注記を追加（Req 4.5）。
- `repo-template/CLAUDE.md` — `impl-resume の branch policy` 節を「#112 以降デフォルト
  有効」表記に書き換え。PR Iteration 設計 PR 拡張の opt-in 表記も同様に更新。
- `repo-template/.claude/agents/developer.md` — 「impl-resume / tasks.md 進捗追跡規約」
  節の opt-in 表記を「#112 以降デフォルト有効、`=false` 明示で無効化」に修正。
- `repo-template/.claude/agents/project-manager.md` — `PR_ITERATION_DESIGN_ENABLED` /
  `DESIGN_REVIEW_RELEASE_ENABLED` の有効化前提注記を「#112 以降デフォルト有効」に更新。
- `.claude/agents/developer.md` — repo-template と同じ内容を root 配下にも反映
  （self-hosting 用）。

## 対象 env var と前後の既定値

| env var | 旧既定 | 新既定 | 変更タイプ |
|---|---|---|---|
| `MERGE_QUEUE_ENABLED` | `false` | `true` | デフォルト反転 |
| `MERGE_QUEUE_RECHECK_ENABLED` | `false` | `true` | デフォルト反転 |
| `PR_ITERATION_ENABLED` | `false` | `true` | デフォルト反転 |
| `PR_ITERATION_DESIGN_ENABLED` | `false` | `true` | デフォルト反転 |
| `DESIGN_REVIEW_RELEASE_ENABLED` | `false` | `true` | デフォルト反転 |
| `STAGE_CHECKPOINT_ENABLED` | `false` | `true` | デフォルト反転 |
| `QUOTA_AWARE_ENABLED` | `false` | `true` | デフォルト反転 |
| `IMPL_RESUME_PRESERVE_COMMITS` | `false` | `true` | デフォルト反転 |
| `IMPL_RESUME_PROGRESS_TRACKING` | `true` | `true` | **変更なし**（既に true） |

## スモークテスト結果

### shellcheck（NFR 2.1）

```
$ shellcheck local-watcher/bin/issue-watcher.sh -S warning
$ echo $?
0
```

warning 以上の指摘ゼロを維持。`info` レベルの SC2317 / SC2012 は本変更前から
存在する既存 pattern であり、本変更で増えていない。

### cron-like 最小 PATH（NFR 2.2）

```
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq flock git timeout'
/usr/bin/gh
/usr/bin/jq
/usr/bin/flock
/usr/bin/git
/usr/bin/timeout
```

`claude` は `$HOME/.local/bin` 等にあるため最小 PATH では出ないが、watcher 冒頭の
`export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"` で
PATH を補正する仕組みは不変。

### dry run（処理対象なしで正常起動）

```
$ REPO=owner/test REPO_DIR=/tmp/test-repo-112 bash local-watcher/bin/issue-watcher.sh
[2026-05-18 15:24:13] base-branch=main merge-queue-base=main
remote: Repository not found.
fatal: repository 'https://github.com/owner/test.git/' not found
```

`base-branch=main merge-queue-base=main` の log prefix が不変であることを確認
（Req 3.5 / NFR 1.3）。fatal は fake remote URL に対するもので、本変更とは無関係。

### env var 値解釈の機械検証（自作テストスクリプト、合計 50 ケース）

Config ブロックを subshell に切り出して各 env 値に対して正規化結果を assertion する
スクリプトで以下を検証:

- **Test 1**: unset 時 9 種すべてが `true` に解決される（Req 1.1〜1.9）→ 9/9 PASS
- **Test 2**: `=false` 明示時 9 種すべてが `false` に解決される（Req 2.1〜2.9, 3.2）
  → 9/9 PASS
- **Test 3**: `=true` 明示時 9 種すべてが `true` に解決される（Req 3.1 / NFR 1.1）
  → 9/9 PASS
- **Test 4**: 非 false 値（空文字 / `0` / `False` / `Yes` / `enabled` 等）が `true` に
  解決される（Req 2.10）→ 15/15 PASS

加えて downstream gate の振る舞いを確認（`[ "$VAR" != "true" ]` で skip 判定）:

- unset / =true / =Yes / =enabled / =0 / =False / =空文字 → executed
- =false → skipped
- → 8/8 PASS

### 既存テストスイート（合計 161 件、全 PASS）

| ファイル | テスト数 | 結果 |
|---|---|---|
| `parse_review_result_test.sh` | 20 | PASS |
| `qa_detect_rate_limit_test.sh` | 11 | PASS |
| `qa_run_claude_stage_test.sh` | 24 | PASS |
| `stagec_pr_verify_fallback_test.sh` | 36 | PASS |
| `stagec_pr_verify_retry_test.sh` | 43 | PASS |
| `stagec_pr_verify_test.sh` | 9 | PASS |
| `verify_pushed_or_retry_test.sh` | 18 | PASS |

特に `qa_run_claude_stage_test.sh` の opt-out テストでは `QUOTA_AWARE_ENABLED=false`
を export して既存挙動互換が保たれることを直接検証している。本変更後も全 24 ケースが
PASS したため、`=false` 明示時の opt-out 挙動が崩れていないことを確認。

## 変更しなかった箇所と理由

### `IMPL_RESUME_PROGRESS_TRACKING` のデフォルト値

#67 導入時から既に `:-true` であり、Req 1.9 「未設定で起動した場合、進捗追跡規約を
有効として動作させる」を既に満たしている。本 PR では値の整合性のため `=false` 解釈と
他値解釈は変更したが、`:-true` のリテラルそのものは据え置き。

### `IMPL_RESUME_PRESERVE_COMMITS=false` 時の `IMPL_RESUME_PROGRESS_TRACKING` 強制 off
構造

requirements.md 「確認事項（PM 推奨）」の方針に従い、現行構造を維持。
`_resume_branch_init` で `RESUME_PRESERVE="false"` が export されると、Stage A prompt
の `if [ "$mode" = "impl-resume" ] && [ "${RESUME_PRESERVE:-false}" = "true" ]; then`
gate で resume_section 全体が空文字のままになり、結果的に進捗追跡指示も注入されない。
本変更で `IMPL_RESUME_PRESERVE_COMMITS` がデフォルト true に反転するため未指定時は
両機能とも有効になり、`=false` 明示時は両機能とも off となる意味論を維持
（Req 5.3 / 5.4 / NFR 1.1）。

### `_resume_normalize_flag` 関数本体

Config ブロック冒頭の正規化ループで全 9 種を既に厳密 2 値（`true` / `false`）に整形
してから本関数に渡すため、関数の `preserve_default_off` mode（`"true"` 完全一致のみ
true、それ以外は false）も `tracking_default_on` mode（`"false"` 完全一致のみ false、
それ以外は true）も、pre-normalized 値に対しては期待通りに動作する。`preserve_default_off`
という mode 名は #67 当時の命名のまま据え置き、コメントで「#112 以降 Config ブロック
冒頭で正規化済みの値を受け取るため後方互換」と説明を追加。

### `run_impl_pipeline` 冒頭の `${STAGE_CHECKPOINT_ENABLED:-false}` → `:-true` 変更

Config ブロックの正規化ループを通過すれば変数値は厳密 2 値だが、関数を直接 eval する
テスト経路など Config ブロックを通らない呼び出しが存在し得るため、防御的に `:-true`
へ揃えた。これは挙動を変えないが、Config ブロック未通過パスでの安全側 default を
新規定（true）に揃える整合性改善。

### 既存コメント中の `(#XX, opt-in)` 等の歴史的記述

履歴の文脈として残置（例: #66 / #67 / #68 の導入時点では opt-in だった事実）。
ただし「default false」「デフォルト無効」と書かれた現状認識を誤誘導する記述は
すべて「#112 でデフォルト反転」表記に置き換えた。

## 確認事項（レビュワー向け）

- **`run_impl_pipeline` 冒頭 gate を `:-false` から `:-true` に変更した点**:
  Config ブロックを通過する正常経路では本変更は no-op。テスト経路など Config ブロックを
  通らない呼び出しがあった場合の防御的整合性改善として実施した。当該変更が好ましく
  ない場合は別 commit で revert 可能。
- **README の「opt-in（既定 OFF、明示的に有効化が必要）」表に Feature Flag Protocol /
  PARALLEL_SLOTS / GitHub Actions を残置した点**: これら 3 機能は今回のデフォルト反転
  対象外（Out of Scope）であり、引き続き opt-in 制御。`PARALLEL_SLOTS` は数値（1=直列）
  で `=true/false` の 2 値挙動ではないため、本 PR の正規化ロジックの対象外。
- **`Feature Flag Protocol` 節は今回変更対象外** だが、idd-claude / repo-template の
  CLAUDE.md には引き続き `**採否**: opt-out` が宣言されており（requirements.md Out of
  Scope）、Developer / Reviewer エージェントの単一実装パスは維持されている。
- **Migration Note の置き場所**: PM 推奨に従いインライン追記（表上部に集中、各機能
  セクションでも個別 #112 注釈を併記）。changelog 節新設は行っていない。

## 受入基準とテストの対応

| AC | 検証方法 |
|---|---|
| Req 1.1 (`MERGE_QUEUE_ENABLED` 未設定で有効化) | 自作 flag 正規化テスト Test 1（unset → `true`）+ downstream gate Test（→ executed） |
| Req 1.2 (`MERGE_QUEUE_RECHECK_ENABLED` 未設定で有効化) | 同上（変数名違いで同パターン） |
| Req 1.3 (`PR_ITERATION_ENABLED` 未設定で有効化) | 同上 |
| Req 1.4 (`PR_ITERATION_DESIGN_ENABLED` 未設定で有効化) | 同上 |
| Req 1.5 (`DESIGN_REVIEW_RELEASE_ENABLED` 未設定で有効化) | 同上 |
| Req 1.6 (`STAGE_CHECKPOINT_ENABLED` 未設定で有効化) | 同上 |
| Req 1.7 (`QUOTA_AWARE_ENABLED` 未設定で有効化) | 同上。さらに `qa_run_claude_stage_test.sh` の opt-in テスト 23 件で実機能パス検証 |
| Req 1.8 (`IMPL_RESUME_PRESERVE_COMMITS` 未設定で有効化) | 同上 |
| Req 1.9 (`IMPL_RESUME_PROGRESS_TRACKING` 未設定で有効化) | 同上（既存 `:-true` 維持） |
| Req 2.1〜2.9 (各 env=false で skip) | 自作テスト Test 2 + downstream gate Test（=false → skipped） |
| Req 2.10 (=false 以外はすべて true) | 自作テスト Test 4（空文字 / `0` / `False` / `Yes` / `enabled` → `true`）|
| Req 3.1 (=true 明示時 100% 同一) | 自作テスト Test 3 + 既存 154 件テスト全 PASS |
| Req 3.2 (=false 明示時 100% 同一 opt-out) | `qa_run_claude_stage_test.sh` の opt-out テスト 3 件 PASS |
| Req 3.3 (env var 名 / スペル / exit code 不変) | コードレビュー（変更なし） |
| Req 3.4 (ラベル名不変) | コードレビュー（変更なし） |
| Req 3.5 (log prefix `base-branch=` 不変) | dry run で `[時刻] base-branch=main merge-queue-base=main` 出力確認 |
| Req 4.1〜4.3 (README 表 / 既定列 / migration note) | README diff 確認 |
| Req 4.4 (issue-watcher.sh のコメント書き換え) | 8 ヶ所のブロックを「デフォルト有効」表現に統一済み |
| Req 4.5 (CLAUDE.md 禁止事項節への注記) | CLAUDE.md L154 に migration note 参照を追加 |
| Req 5.1 (preserve=true && tracking=true → 進捗追跡指示注入) | コードレビュー（既存 if 分岐維持） |
| Req 5.2 (preserve=true && tracking=false → 指示なし) | コードレビュー（既存 if 分岐維持） |
| Req 5.3 (preserve=false → tracking 値に関わらず指示なし) | コードレビュー（`RESUME_PRESERVE=false` 時 `resume_section=""` 維持） |
| Req 5.4 (preserve=false を impl-resume 保護全体の opt-out として扱う構造を破壊しない) | `_resume_branch_init` の if 分岐維持 |
| NFR 1.1〜1.3 (既存運用後方互換) | 既存 24 件 `qa_run_claude_stage_test.sh` 含む全 161 件テスト PASS、log prefix 不変、env var 名不変 |
| NFR 2.1 (shellcheck warning ゼロ) | `shellcheck -S warning local-watcher/bin/issue-watcher.sh` exit 0 |
| NFR 2.2 (cron-like 最小 PATH で起動) | `env -i HOME=$HOME PATH=/usr/bin:/bin` で依存解決確認 |
| NFR 3.1 (dogfooding 中の現行パイプライン非破壊) | self-hosting でも `=true` 明示済みの cron は無影響、`=false` 明示済みも無影響 |
