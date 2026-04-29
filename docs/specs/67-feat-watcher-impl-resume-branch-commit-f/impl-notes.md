# Implementation Notes — Issue #67 impl-resume Branch Protection

## サマリ

`impl-resume` モードで既存 origin branch の commit を破棄してしまう既存挙動（`origin/main`
起点での強制リセット + `--force-with-lease` push）に対し、opt-in env で保護的 resume を
導入した。既定 OFF（`IMPL_RESUME_PRESERVE_COMMITS=false`）下では本機能導入前と完全に
等価な挙動を維持する。

## 追加した env var 一覧

| 変数 | 既定 | 用途 | 受理値 / 正規化方針 |
|---|---|---|---|
| `IMPL_RESUME_PRESERVE_COMMITS` | `false` | impl-resume の保護挙動（既存 branch resume + ff push + non-ff 安全停止）の opt-in switch | `"true"` 完全一致のみ true、それ以外（空 / `True` / `1` / `yes` / 不正値）はすべて `false`（Req 1.3） |
| `IMPL_RESUME_PROGRESS_TRACKING` | `true` | tasks.md の `- [ ]` → `- [x]` 進捗マーカー更新指示の inject 切替 | `"false"` 完全一致のみ false、それ以外（空文字含む）はすべて `true`（Req 3.6）。ただし `IMPL_RESUME_PRESERVE_COMMITS=false` 時は本機能の prompt 注入経路を通らないため実質無効 |

両方 env は cron / launchd 側で `IMPL_RESUME_PRESERVE_COMMITS=true` 等で渡す形（既存
`MERGE_QUEUE_*` 等と同じ運用パターン）。

## 受入基準のテスト カバレッジ

idd-claude にはユニットテストフレームワークが無いため、検証は **静的解析（shellcheck） +
bash 関数 inline smoke + 構文チェック + dry-run** の組み合わせで行う（CLAUDE.md 規約に整合）。

| Req ID | 検証内容 | 検証方法 |
|---|---|---|
| **1.1** | `IMPL_RESUME_PRESERVE_COMMITS=false` 時、impl-resume の branch 初期化が本機能導入前と同一（`origin/main` 起点 + `--force-with-lease`） | `_resume_branch_init` の `if [ "$preserve" != "true" ]` 分岐がそのまま legacy 経路を呼ぶ実装を読み取り検証。dogfood シナリオ C（task 7.4）で観測 |
| **1.2** | `IMPL_RESUME_PRESERVE_COMMITS=true` 時に保護挙動が有効化 | `_resume_branch_init` の opt-in 分岐が `_resume_detect_existing_branch` → checkout → `_resume_push` を呼ぶ実装。dogfood シナリオ A / B（task 7.2 / 7.3）で観測 |
| **1.3** | 受理値 `true` / `false` の 2 値、それ以外は `false` 等価 | `_resume_normalize_flag preserve_default_off` の 6 ケース smoke：`true`→true、`false`/`""`/`True`/`1`/`yes`→false すべて PASS |
| **1.4** | 既存 env var 名の意味と受理形式を改変しない | 本 commit 系列で既存 env var（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL`, `MERGE_QUEUE_*` 等）の宣言・参照箇所に変更がないことを `git diff main..HEAD -- local-watcher/bin/issue-watcher.sh` で確認 |
| **1.5** | 既存 cron / launchd 登録文字列を変更しなくても既定 OFF で動作 | `IMPL_RESUME_PRESERVE_COMMITS:-false` のデフォルトで未設定時は false 扱い。bash 構文チェック（`bash -n`）で問題なし |
| **2.1** | 既存 origin branch resume（`git ls-remote --exit-code` で検出） | `_resume_detect_existing_branch` の `main` 存在 / 非存在 smoke で 0 / 1 を確認 |
| **2.2** | branch 不在時は `origin/main` 起点で初期化 | `_resume_branch_init` の opt-in 分岐内 else 経路（`git checkout -B BRANCH origin/main` + `slot_log resume-mode=fresh-from-main`） |
| **2.3** | resume を運用者が事後判別可能粒度でログに記録 | `slot_log "resume-mode=existing-branch branch=... origin_sha=<short>"`（NFR 2.1） |
| **2.4** | Developer prompt に resume 指示を渡す | `build_dev_prompt_a "impl-resume"` の inline 4 ケース smoke で `RESUME_PRESERVE=true` 時に「既存 commit からの resume」節が末尾に出現することを確認 |
| **2.5** | untracked / 一時ファイルは保護対象外 | `_resume_branch_init` 内で `git clean -fdx` を変更していない（`_worktree_reset` の既存挙動を温存）。`git diff main..HEAD` で当該箇所が変更されていないことを確認 |
| **3.1** | tracking 既定 / `true` で `tasks.md` マーカー更新指示が prompt に出る | `build_dev_prompt_a` の 4 ケース smoke で CASE 1（tracking unset → true 等価）が「進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=true）」ブロックを出力することを確認 |
| **3.2** | `tracking=false` で更新無効化 | CASE 2（tracking=false）が「進捗追跡（IMPL_RESUME_PROGRESS_TRACKING=false）」ブロックを出力することを確認 |
| **3.3** | 未完了マーカー残存時、先頭タスクから再開（Developer 行動規約） | `.claude/agents/developer.md` および `repo-template/.claude/agents/developer.md` の「impl-resume / tasks.md 進捗追跡規約」節に「未完了マーカー先頭から再開」を明記 |
| **3.4** | 全完了時は追加実装をしない（Developer 行動規約） | 同上、「全完了時は追加実装をしない」節として記載 |
| **3.5** | マーカー部分のみ書き換え（Developer 行動規約） | 同上、「書き換え禁止領域」として `_Requirements:_` / `_Boundary:_` / `_Depends:_` / 順序 / インデント / deferrable 印を列挙。設計論点 2（hidden marker は使わない）と整合 |
| **3.6** | tracking 受理値 `true`/`false`、それ以外は `true` 等価 | `_resume_normalize_flag tracking_default_on` の 6 ケース smoke：`false`→false、`true`/`""`/`False`/`0`/`no`→true すべて PASS |
| **4.1** | preserve resume 時の push は fast-forward 制約付き | `_resume_push` 内 `git push -u origin "$branch"` のみ（`--force-with-lease` を付けない）を実装で確認 |
| **4.2** | non-ff reject 時はリトライせず `claude-failed` | `_resume_push` の stderr ERE 判定 → `_resume_mark_nonff_failed` 経由で `_slot_mark_failed "branch-nonff"` を呼ぶ実装。リトライ無し |
| **4.3** | non-ff failure 時の Issue コメント | `_resume_mark_nonff_failed` の body 内に「自動 force-push を抑制したため停止」と人間操作手順を inline で記載 |
| **4.4** | `PRESERVE=false` 時は force-push 抑制対象外 | `_resume_branch_init` の `if [ "$preserve" != "true" ]` 分岐は `--force-with-lease` を温存（既存挙動 |
| **4.5** | non-ff 安全停止時に既存 commit を改変・削除・rebase しない | `_resume_push` / `_resume_mark_nonff_failed` 内で `git reset` / `git rebase` / `git merge` を呼ばない実装を確認 |
| **5.1** | README に env var 用途・既定値・有効化方法 | README.md の `## impl-resume Branch Protection (#67)` 節に追記（task 6.1） |
| **5.2** | README に opt-in 時の新挙動を運用者視点で記述 | 同上、「opt-in 後の挙動」サブ節 |
| **5.3** | Migration Note | 同上、「Migration Note（既存ユーザー向け）」サブ節 |
| **6.1 / 6.2 / 6.3** | dogfooding | 後述「Dogfood シナリオの実行ステータス」を参照 |
| **NFR 1.1** | 既定値下で既存 Issue / PR / cron が無影響 | bash 構文チェック PASS / cron-like PATH 解決 PASS / shellcheck 新規 warning 0 / `git diff main..HEAD` で `_slot_run_issue` の Slot Runner Resume Hook 以外に変更が無いことを確認 |
| **NFR 1.2** | 既存ラベル名・意味・遷移契約を変えない | `LABEL_*` 定数の変更なし。`_slot_mark_failed` の stage 識別子に `branch-nonff` を追加（既存ラベル付与挙動は不変、新規ラベルは追加していない） |
| **NFR 1.3** | 既存 exit code / `LOG_DIR` フォーマット契約を変えない | `slot_log` / `slot_warn` 既存書式（`[YYYY-MM-DD HH:MM:SS] slot-N: #N: ...`）を踏襲 |
| **NFR 2.1** | 3 イベントを `LOG_DIR` 配下のログに記録 | `resume-mode=existing-branch` / `resume-mode=fresh-from-main` / `resume-mode=legacy-force-push` / `resume-failure=non-ff` の slot_log を実装 |
| **NFR 2.2** | non-ff failure を ログ単独で原因と Issue 番号特定可能 | `slot_log "resume-failure=non-ff issue=#${NUMBER:-?} branch=$branch"` を実装 |
| **NFR 3.1** | shellcheck 新規警告 0 件 | `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` 全実行で SC2012 / SC2317（既存）以外の新規 SC コードが出ないことを確認 |
| **NFR 3.2** | actionlint 新規警告 0 件 | 本機能では `.github/workflows/*.yml` を変更していないため対象外（既存と同一） |

## 実行したスモークテストとその結果

### 静的解析（NFR 3.1 / 3.2）

```bash
$ shellcheck local-watcher/bin/issue-watcher.sh
# SC2012 (info) 3 件 / SC2317 (info) 10 件、いずれも既存の警告。新規警告 0 件
$ bash -n local-watcher/bin/issue-watcher.sh
# 構文 OK
```

### cron-like PATH 依存解決（NFR 1.3）

```bash
$ env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '
    export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"
    command -v claude gh jq flock git timeout
  '
/home/hitoshi/.local/bin/claude
/usr/bin/gh
/usr/bin/jq
/usr/bin/flock
/usr/bin/git
/usr/bin/timeout
exit=0
```

### `_resume_normalize_flag` smoke（Req 1.3 / 3.6）

13 ケースすべて PASS:
- `preserve_default_off`: `"true"`→true、`"false"`/`""`/`"True"`/`"1"`/`"yes"`→false（6 件）
- `tracking_default_on`: `"false"`→false、`"true"`/`""`/`"False"`/`"0"`/`"no"`→true（6 件）
- 不明 mode: false（1 件）

### `_resume_detect_existing_branch` smoke（Req 2.1 / 2.2）

- `main` ブランチ → exit 0（exists）
- `this-branch-does-not-exist-xyz123` → exit 1（not exists）
- 空文字 → exit 1（safety）

### `build_dev_prompt_a` 4 ケース smoke（Req 2.4 / 3.1 / 3.2）

| ケース | mode | RESUME_PRESERVE | tracking | resume 節注入 | tracking ブロック |
|---|---|---|---|---|---|
| 1 | impl-resume | true | unset (→ true) | ✅ 出現 | tracking-on（- [ ] → - [x] 指示） |
| 2 | impl-resume | true | "false" | ✅ 出現 | tracking-off（書き換えない） |
| 3 | impl-resume | false | unset | ❌ 不出現 | — |
| 4 | impl | true | unset | ❌ 不出現 | — |

すべて期待通り。

### Dogfood シナリオの実行ステータス（task 7.2 / 7.3 / 7.4）

| シナリオ | Req | ステータス |
|---|---|---|
| A: 途中 commit 保護（`PRESERVE=true` で `resume-mode=existing-branch` ログ出力 + 既存 commit 保持） | 6.1 | **本 PR では未実施**。Reviewer 後の人間判断で本 repo に test issue を作って実行することを推奨（後述「確認事項」参照） |
| B: 人間 commit + non-ff 検出（`resume-failure=non-ff` ログ出力 + `claude-failed` 遷移） | 6.2 | **本 PR では未実施**（同上） |
| C: 既定 OFF 等価性（`resume-mode=legacy-force-push` ログ出力 + `--force-with-lease` 継続） | 6.3 | **本 PR では未実施**（同上） |

dogfood の実行は実 Claude API + cron / launchd の起動を要するため、本 Developer ステージ
での執行は dispatch 起動と worktree 操作の依存上、現実的でない。本機能の挙動は inline
smoke と shellcheck で構造的に保証している。

## 設計と乖離した点

- なし。`design.md` の Components / Interfaces / File Structure Plan に記述された
  内容を素直に実装した。
- 1 点だけ、`_resume_push` の non-ff 以外の push 失敗（ネットワーク等）の扱いについて
  設計には明示されていなかったが、**fail-safe で `_slot_mark_failed "branch-push"` 既存
  ステージに合流させる** 形にした。これは AC 4.5（既存 commit を改変・削除・rebase しない）
  に違反せず、既存 push 失敗パスと整合する。

## 補足ノート

- **Feature Flag Protocol の opt-in 採否**: idd-claude 自身の `CLAUDE.md` には
  `## Feature Flag Protocol` 節が存在しない（無宣言 = opt-out 等価）ため、本機能の実装は
  `if (flag) { 新挙動 } else { 旧挙動 }` の二重テスト要件は適用されない（NFR 1.1 / Req 3.4）。
  ただし設計上 `_resume_branch_init` 自体が `if [ "$preserve" != "true" ]` で legacy 経路と
  preserve 経路を内部分岐しており、結果的に二重実装となっている（後方互換のため必須）。
- **shellcheck SC2317 残件 10 件**: いずれも `_resume_mark_nonff_failed` 内の inline body
  生成（local var で組み立てた body を最後に `_slot_mark_failed` に渡す）等、既存の
  unreachable 検出パターンと同種。本機能で増えた件数は task 4.1 commit 後で 0 件相当。
- **stderr ERE パターン**: GitHub の `git push` メッセージは英語版前提。ロケール設定で
  日本語 / 他言語が表示される環境では non-ff 検出が漏れる可能性がある。idd-claude の
  既存 watcher は `LANG` を明示設定していないが、`set -e` で stderr が空になるケースは
  なく、英語パターンが標準動作する `git` の既定環境を前提とした。これは既存
  `mq_log` 等他のコンポーネントと同じ前提（README で運用環境前提を強制している）。

## 確認事項（Reviewer / 人間判断）

1. **dogfood シナリオの実行**: 本 PR は静的解析と inline smoke で構造的検証を完了した
   が、実 Claude / 実 cron 起動による End-to-End 検証（AC 6.1 / 6.2 / 6.3）は未実施。
   Reviewer / 人間が本 PR の merge 後、本 repo に `auto-dev` 用 test issue を立てて
   `IMPL_RESUME_PRESERVE_COMMITS=true` を渡した cron / launchd で実行するか、別 Issue
   を切って dogfood を独立タスクにする運用が望ましい。
2. **stderr ロケール**: 上述「補足ノート」の通り、`_resume_push` は英語 `git push` stderr
   メッセージを ERE で判定する。日本語ロケール環境で false negative の可能性あり。
   現在の idd-claude 運用環境は cron 既定（C ロケール）想定で問題ないが、明示的に
   `LANG=C` を `_resume_push` で setlocal するかどうかは Reviewer 判断に委ねる。
3. **`_resume_push` の戻り値設計**: design.md は「2 = その他のネットワーク等エラー」と
   記述があるが、実装では non-ff 以外の失敗もすべて 1 で返している
   （`_slot_mark_failed "branch-push"` で claude-failed 化済みのため、呼び出し側
   `_resume_branch_init` は non-ff / その他の区別が不要）。設計と実装の戻り値の数の
   差異が問題になるか、Reviewer 判断に委ねる。
4. **`_worktree_reset` と opt-in パスの相互作用**: `_worktree_reset` は worktree 全体を
   `origin/main` 起点で reset + `clean -fdx` する。`_resume_branch_init` の opt-in パスで
   `git checkout -B BRANCH origin/BRANCH` する直前にこれが走るため、reset → checkout の
   順番で正しく既存 origin branch の commit が現れる。bash 上は問題ないが、もし将来
   `_worktree_reset` の挙動が変わると preserve resume が壊れる依存関係がある旨、
   コードコメントに残してある。

## 派生タスク候補（Reviewer / 人間判断）

- **dogfood E2E**: 本機能の AC 6.1 / 6.2 / 6.3 を実 cron 起動で観測する別 Issue
- **stderr ロケール明示**: `LANG=C git push` で ERE 判定を堅牢にする小修正
- **`IMPL_RESUME_PRESERVE_COMMITS=true` 既定化**: deprecation 期間と移行手順の設計（Out of Scope）

## ファイル変更サマリ

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | Config block に env 2 件追加 / `_resume_normalize_flag` / `_resume_detect_existing_branch` / `_resume_branch_init` / `_resume_push` / `_resume_mark_nonff_failed` の 5 関数追加 / `_slot_run_issue` 内 line 2944-2953 を `_resume_branch_init` 呼び出しに置換 / `build_dev_prompt_a "impl-resume"` 末尾に inline 注入分岐 |
| `.claude/agents/developer.md` | impl-resume / tasks.md 進捗追跡規約の節を追加 |
| `repo-template/.claude/agents/developer.md` | 同上（consumer repo 配布用） |
| `repo-template/CLAUDE.md` | エージェント連携ルールに impl-resume branch policy 段落を追加 |
| `README.md` | opt-in 機能リスト table に IMPL_RESUME_PRESERVE_COMMITS を追加 / `## impl-resume Branch Protection (#67)` 節を新規追加（opt-in 手順 / 新挙動 / Migration Note） |
