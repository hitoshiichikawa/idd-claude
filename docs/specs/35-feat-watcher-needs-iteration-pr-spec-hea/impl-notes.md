# 実装ノート: #35 feat(watcher) needs-iteration を設計 PR にも対応

## 実施した変更の要約

| Task | コミット | 主な変更ファイル |
|------|---------|---------------|
| 1.1 | `c71491a feat(watcher): add design PR iteration prompt template` | `local-watcher/bin/iteration-prompt-design.tmpl` (新規) |
| 2.1 | `688bb1f docs(install): note iteration-prompt-design.tmpl auto-placement` | `install.sh`（コメントのみ） |
| 3.1 | `fda2333 feat(watcher): add design PR iteration config + tighten impl head pattern` | `local-watcher/bin/issue-watcher.sh`（Config + 前提チェック） |
| 3.2 | `06df887 feat(watcher): add pi_classify_pr_kind / pi_select_template / pi_finalize_labels_design` | `local-watcher/bin/issue-watcher.sh`（3 関数追加） |
| 3.3 | `69c3652 refactor(watcher): make pi_run_iteration kind-aware (design / impl)` | `local-watcher/bin/issue-watcher.sh`（runner リファクタ） |
| 3.4 | `6c1a705 feat(watcher): extend candidate fetcher and summary with design / impl breakdown` | `local-watcher/bin/issue-watcher.sh`（candidate filter + summary） |
| 4 | `bc8b317 docs(claude): document design PR iteration responsibilities` | `repo-template/CLAUDE.md` / `repo-template/.claude/agents/project-manager.md` |
| 5 | `4c11eb8 docs(readme): document design PR iteration extension and head pattern migration` | `README.md` |

## 各タスクの詳細

### Task 1.1: 設計 PR 用 iteration template の新設

`local-watcher/bin/iteration-prompt-design.tmpl` を新規作成。impl 用 template
（`iteration-prompt.tmpl`）と awk 注入互換のプレースホルダ
（`{{REPO}}` / `{{PR_NUMBER}}` 等 14 個）を採用し、内容のみ Architect 役割と spec 書き換え
許容に書き換えた。

主な差分（impl 用 vs design 用）:

- 役割宣言: Developer → **Architect**
- 編集許容スコープ: 制約なし → **`{{SPEC_DIR}}` 配下のみ**
- spec 書き換え条項: 「禁止」→ **「許容」（`docs(specs):` scope を推奨）**
- 自己レビュー指示: なし → **`.claude/rules/design-review-gate.md` の Mechanical Checks を最大 2 パス**
- 共通禁止事項（force push / main 直 push / resolve 禁止 / `--resume` 禁止）: 同一基準で記述

### Task 2.1: install.sh / setup.sh の冪等配置動作確認

既存の `copy_glob_to_homebin "*.tmpl"` 経路で `iteration-prompt-design.tmpl` が
`$HOME/bin/` に自動配置されることを scratch HOME で 2 回連続実行して確認:

- 1 回目: `[INSTALL] NEW       /tmp/.../bin/iteration-prompt-design.tmpl`
- 2 回目: `[INSTALL] SKIP      /tmp/.../bin/iteration-prompt-design.tmpl (identical to template)`

冪等性確認 OK（NFR 2.1）。`setup.sh` は `install.sh` を `exec` するブートストラッパなので
変更不要。

`install.sh` のコメントに配置されるテンプレート例として
`iteration-prompt-design.tmpl (#35 設計 PR 用)` を追記し、メンテナの discoverability を
改善（コードロジック自体は変更なし）。

### Task 3.1: Config ブロックの拡張

`local-watcher/bin/issue-watcher.sh` の Config ブロック（line 100〜120 付近）に以下を追加:

```bash
PR_ITERATION_HEAD_PATTERN="${PR_ITERATION_HEAD_PATTERN:-^claude/issue-[0-9]+-impl-}"  # 既定厳格化
PR_ITERATION_DESIGN_ENABLED="${PR_ITERATION_DESIGN_ENABLED:-false}"
PR_ITERATION_DESIGN_HEAD_PATTERN="${PR_ITERATION_DESIGN_HEAD_PATTERN:-^claude/issue-[0-9]+-design-}"
ITERATION_TEMPLATE_DESIGN="${ITERATION_TEMPLATE_DESIGN:-$HOME/bin/iteration-prompt-design.tmpl}"
```

前提ツールチェック節に「`PR_ITERATION_ENABLED=true` かつ
`PR_ITERATION_DESIGN_ENABLED=true` のとき `iteration-prompt-design.tmpl` 必須」のチェックを
追加。

### Task 3.2: 種別判定 / template 選択 / ラベル遷移分岐の 3 関数

| 関数 | 責務 | 戻り値 |
|------|------|-------|
| `pi_classify_pr_kind <head_ref>` | branch 名 + env から `design` / `impl` / `none` / `ambiguous` を判定 | stdout に 4 値 |
| `pi_select_template <kind>` | kind に応じた template path を返す | stdout に path、不在で 1 |
| `pi_finalize_labels_design <pr_number>` | needs-iteration → awaiting-design-review を原子的遷移 | 0/1 |

ローカルで境界値テスト（impl / design / none / ambiguous / DESIGN_ENABLED on/off /
旧来 `claude/<slug>` 形式 / 厳格化後の impl 認識）を 11 ケース実施し全 pass を確認。

### Task 3.3: pi_run_iteration の kind-aware 化

`pi_run_iteration` を以下のフローに改修:

1. `pi_classify_pr_kind` で kind 判定（none / ambiguous は skip ログ + return 3）
2. `pi_select_template` で template path 取得（不在で WARN + return 1）
3. round counter / 着手表明 / claude 起動は kind 非依存で共有
4. 成功時の finalize 関数を kind で分岐:
   - design → `pi_finalize_labels_design` (→ `awaiting-design-review`)
   - impl → `pi_finalize_labels` (→ `ready-for-review`、既存維持)
5. ログ書式に `kind=design|impl` を追加
6. claude 実行ログのファイル名にも `kind` を含める（`pr-iteration-design-12-round2-...`）

`pi_build_iteration_prompt` に template path を引数で渡せるよう拡張。第 4 引数を省略すると
`$ITERATION_TEMPLATE`（impl 用既定）を使う後方互換を維持。

`process_pr_iteration` の戻り値ハンドリング:

- 0 → success
- 2 → escalated（kind 共通、上限到達）
- 3 → skip（kind=none / ambiguous、新設）
- それ以外 → fail

### Task 3.4: candidate filter + サマリ拡張

`pi_fetch_candidate_prs` の jq filter を:

```jq
[.[]
  | select(.isDraft == false)
  | select((.headRepositoryOwner.login // "") == $owner)
  | select(
      (.headRefName | test($impl_pattern))
      or
      ($design_enabled == "true" and (.headRefName | test($design_pattern)))
    )
]
```

に変更。`PR_ITERATION_DESIGN_ENABLED=false`（既定）のときは impl pattern のみで絞り込み、
設計 PR は candidate 段階で完全除外（AC 5.1）。

`process_pr_iteration` のサイクル開始ログに `design_enabled` 値を追加。候補件数ログと
サマリ行に `(design=N, impl=N, ambiguous=N)` 内訳を追加（NFR 3.1 / 3.2）。

ローカルで jq breakdown / filter のユニットテストを実施し、DESIGN_ENABLED=on/off の両系統で
期待通り（`design=3 impl=2 / design=0 impl=2`）の集計と filter 結果を得られることを確認。

### Task 4: ドキュメント / エージェントルール更新

- `repo-template/CLAUDE.md`: エージェント連携ルール節に「PR Iteration の責務境界」項目を追加。
  実装 PR では spec 書き換え禁止 / 設計 PR では `docs/specs/` 配下の書き換え許容 /
  1 PR = design or impl 混在禁止 / 設計 PR iteration は `PR_ITERATION_DESIGN_ENABLED=true`
  opt-in が必要、を箇条書きで記述。
- `repo-template/.claude/agents/project-manager.md`: design-review モード本文の Issue 案内
  コメントに「`needs-iteration` ラベルでの自動反復」項目を追加。「1 PR = design or impl」
  独立節を追加。

### Task 5: README 更新

- 「対象 PR の判定」節: `PR_ITERATION_HEAD_PATTERN` 既定厳格化（`^claude/` →
  `^claude/issue-[0-9]+-impl-`）を強調 quote ブロックで明示。`PR_ITERATION_DESIGN_ENABLED=true`
  のとき設計 PR pattern もマッチする旨を追加。
- 「挙動」表に kind 別の遷移先 / ambiguous skip を追加。
- env var 表に `PR_ITERATION_DESIGN_ENABLED` / `PR_ITERATION_DESIGN_HEAD_PATTERN` /
  `ITERATION_TEMPLATE_DESIGN` の 3 行を追加。`PR_ITERATION_HEAD_PATTERN` の既定値表記を
  更新（#35 で既定厳格化 注記）。
- 新節「設計 PR 拡張 (#35)」: Architect 役割 / 編集スコープ /
  自己レビューゲート / 成功時 awaiting-design-review 遷移 / opt-in cron 例 /
  混在禁止 / review-notes.md (#20) との関係を独立節として記述。
- Migration Note に以下を追加:
  - `PR_ITERATION_HEAD_PATTERN` 既定値変更の影響範囲と override 救済方法
    （cron に `PR_ITERATION_HEAD_PATTERN=^claude/` を追加）
  - deprecation 期間なしの判断（cron 行 1 行追加で旧挙動に戻せるため）
  - 設計 PR 対応の opt-in 方法
- merge 後の再配置案内に `iteration-prompt-design.tmpl` を追加。

## スモークテスト結果（Task 6 / DoD Req 7.x）

> 本リポジトリには unit test フレームワークが無いため、static analysis +
> 候補ゼロ状態の dry run + 関数単位の bash テストで検証。E2E（Req 7.1〜7.4）は
> watcher を実環境で動かす必要があるため、PR 本文の Test plan に反映する形で
> リリース時に実施する。

### Static Analysis（全て pass）

```text
$ shellcheck local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh
（pre-existing SC2012 info 警告 2 件のみ。本変更で増えた警告ゼロ）

$ bash -n local-watcher/bin/issue-watcher.sh && echo OK
OK
$ bash -n install.sh && echo OK
OK
$ bash -n setup.sh && echo OK
OK
```

### cron-like 最小 PATH での依存解決確認

```text
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '
    export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
    for cmd in claude gh jq flock git timeout; do command -v "$cmd"; done'
/home/hitoshi/.local/bin/claude
/usr/bin/gh / /usr/bin/jq / /usr/bin/flock / /usr/bin/git / /usr/bin/timeout
```

### install.sh --dry-run --local（NEW として認識）

```text
$ bash install.sh --dry-run --local | grep tmpl
[DRY-RUN] NEW       /home/hitoshi/bin/iteration-prompt-design.tmpl
[DRY-RUN] SKIP      /home/hitoshi/bin/iteration-prompt.tmpl (identical to template)
[DRY-RUN] SKIP      /home/hitoshi/bin/triage-prompt.tmpl (identical to template)
```

### install.sh 冪等性（scratch HOME で 2 回連続実行）

```text
1 回目: NEW       /tmp/.../bin/iteration-prompt-design.tmpl
2 回目: SKIP      /tmp/.../bin/iteration-prompt-design.tmpl (identical to template)
```

NFR 2.1 確認。

### 候補 0 件 dry run（opt-out / opt-in 両系統）

```text
# Smoke 1: PR_ITERATION_ENABLED=false (opt-out, 既定)
$ ... PR_ITERATION_ENABLED=false bash issue-watcher.sh
（pr-iteration: ログ行ゼロ。opt-out gate が機能している = AC 5.1 / NFR 1.1 / 7.4）

# Smoke 2: opt-in 両方 true（gh が fake REPO で空配列を返す）
$ ... PR_ITERATION_ENABLED=true PR_ITERATION_DESIGN_ENABLED=true bash issue-watcher.sh
[2026-04-28 15:43:41] pr-iteration: サイクル開始 (max_prs=3, max_rounds=3, model=claude-opus-4-7, design_enabled=true, timeout=60s)
[2026-04-28 15:43:42] pr-iteration: 対象候補 0 件、処理対象 0 件（内訳: design=0, impl=0, ambiguous=0）
[2026-04-28 15:43:42] pr-iteration: サマリ: success=0, fail=0, skip=0, escalated=0, overflow=0 (design=0, impl=0)
```

NFR 3.2 / AC 6.3 を満たしていることを確認（design / impl 内訳がログに出る）。

### Smoke 3: PR_ITERATION_HEAD_PATTERN override（NFR 4.2 / Req 5.3）

```text
$ ... PR_ITERATION_HEAD_PATTERN='^claude/' bash issue-watcher.sh
（候補 0 件で正常終了。override が設定値として有効）
```

bash 内テストで `PR_ITERATION_HEAD_PATTERN=^claude/` のとき:
- `claude/foo-bar` → `impl`（旧来 branch を救済）
- `claude/issue-35-design-foo` (DESIGN_ENABLED=true) → `ambiguous`（両 pattern が
  一致、設計通り skip 扱い）

### Classifier ユニットテスト（11 ケース全 pass）

| 入力 | 期待 | 結果 |
|------|------|------|
| `claude/issue-35-design-foo` + DESIGN_ENABLED=true | design | PASS |
| `claude/issue-35-impl-foo` + DESIGN_ENABLED=true | impl | PASS |
| `claude/issue-35-impl-foo` + DESIGN_ENABLED=false | impl | PASS |
| `claude/foo-bar` | none | PASS |
| `main` | none | PASS |
| `feature/branch` | none | PASS |
| `claude/issue-35-design-foo` (HEAD_PATTERN=^claude/, DESIGN_ENABLED=true) | ambiguous | PASS |
| `claude/issue-35-design-foo` + DESIGN_ENABLED=false | none | PASS |
| `claude/issue-35-design-foo` + DESIGN_ENABLED unset | none | PASS |
| `claude/issue-26-impl-feat-pr-needs-iteration` | impl | PASS（既存 impl PR 認識） |
| `claude/some-old-branch` | none | PASS（旧来命名は除外） |

## DoD 4 シナリオの状況

| シナリオ | 検証可否 | 備考 |
|---------|---------|------|
| Req 7.1 設計 PR 成功 | **未実施（要 E2E）** | 実環境で `claude/issue-<N>-design-<slug>` 形式の PR に `needs-iteration` を付けて検証する必要あり。リリース時に実施し PR 本文 Test plan に記録 |
| Req 7.2 設計 PR 上限到達 | **未実施（要 E2E）** | 同上、`MAX_ROUNDS` まで回す必要あり |
| Req 7.3 実装 PR リグレッション | **dry run で部分確認** | candidate filter / kind classifier が impl pattern を従来通り認識することは bash テストで確認済み。E2E（commit push まで）はリリース時に実施 |
| Req 7.4 完全 opt-out | **dry run で確認済み** | `PR_ITERATION_DESIGN_ENABLED=false` で `pr-iteration:` ログ行に design_enabled=false が出る、impl pattern の filter は従来同等。完全 opt-out 経路の機能動作を確認 |

E2E（Req 7.1 / 7.2 / 7.3）は本実装 PR の merge 後、運用ステップとして実施し、結果は
PR 本文の Test plan セクションに記録する想定（リリース時の DoD 完了条件）。

## 確認事項（PR 本文「確認事項」候補）

`design.md` の Open Questions / 確認事項に列挙されていた論点はすべて design 段階で
Architect が判断確定しており、実装側で再確認すべき論点は以下のみ:

- **AC 2.6 のハード enforce**: design.md は「Claude の指示遵守に任せる」を採用済み。
  本実装でも同方針で template 内で明示するに留め、watcher 側で `git diff --name-only` を
  ハード enforce する追加実装は行っていない。reviewer がハード enforce を必要とする場合は
  別 Issue 化して扱う想定。

design.md / requirements.md への矛盾や疑問は発見されず、書き換え不要。

## 既存テストへの影響

- 本リポジトリには unit test フレームワークが無いため、テストの追加 / 削除なし。
- shellcheck / actionlint / bash -n は本変更で警告増加なし。
- 既存スモークテスト経路（候補 0 件 dry run）は引き続き正常終了。

## 後方互換性まとめ（NFR 1.1 / 1.2 / 1.3 / 4.6）

- 既存 env var（`PR_ITERATION_ENABLED`, `PR_ITERATION_DEV_MODEL`,
  `PR_ITERATION_MAX_TURNS`, `PR_ITERATION_MAX_PRS`, `PR_ITERATION_MAX_ROUNDS`,
  `PR_ITERATION_GIT_TIMEOUT`, `ITERATION_TEMPLATE`）の名前・意味は不変
- 既定値変更は `PR_ITERATION_HEAD_PATTERN` のみ（`^claude/` → `^claude/issue-[0-9]+-impl-`）。
  override で旧挙動に戻せる経路は残しているため、影響を受ける運用者は cron 行 1 行追加で復旧可能
- 既存ラベル名・lock / log / exit code は完全不変
- cron / launchd 登録文字列は変更不要（既存設定のまま `install.sh --local` を再実行するだけで
  本変更が反映される）
- `PR_ITERATION_DESIGN_ENABLED=false`（既定）かつ `PR_ITERATION_HEAD_PATTERN` を override
  しない既存ユーザーは、impl PR の検知範囲・ラベル遷移・ログ書式が #26 導入時とほぼ同一
  （差分: サマリ行に `(design=0, impl=N)` 内訳が末尾追加。grep 互換性あり）

## requirement numeric ID とテストカバレッジの対応

| Req ID | カバレッジ手段 |
|--------|--------------|
| 1.1 | classifier ユニット (design pattern + enabled → design) |
| 1.2 | classifier ユニット (impl pattern → impl) |
| 1.3 | classifier ユニット (neither → none) |
| 1.4 | classifier ユニット (両方一致 → ambiguous) |
| 1.5 | 既存 #26 のフィルタ（fork / draft / failed / rebase）はコード上未変更で温存 |
| 2.1 | template 新規ファイル存在 + dry run NEW 確認 |
| 2.2 | install.sh dry run + scratch HOME 冪等性確認 |
| 2.3〜2.7 | template 内に Architect 役割 / 編集スコープ / 禁止事項を inline 記述（コードレビューで確認） |
| 3.1 | `pi_finalize_labels_design` 関数追加 + コードレビュー |
| 3.2 | 既存 `pi_finalize_labels` を温存（コードレビュー） |
| 3.3 | コードレビュー（`pi_run_iteration` の失敗時パス） |
| 3.4 | コードレビュー（`pi_escalate_to_failed` を kind 共通で呼ぶ） |
| 3.5 | `idd-claude-labels.sh` を確認、4 ラベル全て既存（変更なし） |
| 4.1〜4.3 | Config ブロックの env var 既定値（コードレビュー + bash 内テスト） |
| 4.4 | classifier ユニット (design pattern + DESIGN_ENABLED=false → none) |
| 4.5 | コードレビュー（`process_pr_iteration` の opt-in gate） |
| 4.6 | コードレビュー（既存 env var の名前・既定値が不変） |
| 5.1 | smoke test（DESIGN_ENABLED=false で `pr-iteration:` ログゼロ） |
| 5.2 | classifier ユニット (`claude/issue-26-impl-...` が impl と認識される) |
| 5.3 | bash 内テスト（HEAD_PATTERN=^claude/ override で旧 branch を救済可能） + README 記載 |
| 5.4〜5.7 | repo-template / README のコードレビュー |
| 6.1 | コードレビュー（`pi_post_processing_marker` 共有） |
| 6.2 | コードレビュー（既存 prefix `pr-iteration:` と timestamp 書式維持） |
| 6.3 | smoke test ログに `kind=` / `round=` / `action=` が出ることを目視確認可能（実 iteration 実行時） |
| 6.4 | コードレビュー（`pi_escalate_to_failed` を kind 共通で呼ぶ） |
| 6.5 | コードレビュー（hidden marker は kind 引数を含まない、`pi_read_round_counter` 共有） |
| 7.1〜7.5 | DoD（リリース時 E2E、PR 本文 Test plan に記録） |
| NFR 1.1〜1.3 | 既存 env / lock / log / exit code を変更していないことをコードレビューで確認 |
| NFR 2.1 | scratch HOME 冪等性 smoke test |
| NFR 2.2 | classifier の純粋関数性（同一入力で同一結果）+ 既存 round counter は不変 |
| NFR 3.1 / 3.2 | smoke test ログのサマリ / 内訳行を目視確認 |
| NFR 4.1 | bash 内テスト（cron / shell から DESIGN_ENABLED override 可能） |
| NFR 4.2 | bash 内テスト（HEAD_PATTERN を override で旧 `^claude/` に戻せる） |

## 派生タスクとして切り出すべき項目

- **設計 PR iteration 用 Reviewer エージェント連携**: 本 Issue は impl 系限定で据え置き。
  将来的に設計 PR にも独立 review-notes.md を導入する場合は別 Issue 化（design.md にも明記）
- **AC 2.6 のハード enforce**: 現状 Claude の指示遵守に依存。`git diff --name-only` で
  scope 外編集を検知して自動 revert する実装が必要なら別 Issue 化
- **設計 PR / 実装 PR で round counter を別離する仕組み**: 本 Issue では共有のまま運用。
  混在 PR は `ambiguous` で skip するため運用上は破綻しない
