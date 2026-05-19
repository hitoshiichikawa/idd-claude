# 実装ノート: #115 install.sh inherited specs / claude branches 警告

## Open Questions に対する Developer の確定判断

`requirements.md` の Open Questions 3 件を以下のとおり確定した（PM から委ねられた範囲内、
要件追加・解釈変更には踏み込まない）。

### Q1. D-3 の「現存 Issue 番号に含まれない」判定で closed Issue を母集合に含めるか

**確定**: `--state all`（open + closed）を採用する。

理由:
- fork 元で close 済み Issue にブランチが残っているケースは普通にあり得る。closed を
  除外すると false positive（fork/mirror 警告が誤って出る）が増える
- `gh issue list --state all --limit 1000 --json number --jq '.[].number'` で 1 コール
  完結。1000 件上限は NFR 1.1（10 秒以内）と整合
- `gh` の rate limit に与える影響は単発呼び出しで軽微

### Q2. 警告メッセージで提示する先頭数件の件数

**確定**: 各カテゴリ **先頭 3 件**まで提示し、超過分は `(+N more)` で件数を示す。

理由:
- ターミナル 1 画面に複数カテゴリを並べる UX で 3 件×3 カテゴリ=最大 9 行 + サマリ + 助言
  フッターで 1 画面に収まる
- 検出件数 0/1/2 件のときも特殊扱い不要（max 3 制限が自然に効く）
- カテゴリ別の合計件数は警告ヘッダ行に「X 件検出されました」と必ず明示するので、3 件超でも
  ユーザーが全件数を把握できる

### Q3. README / QUICK-HOWTO 反映先

**確定**: 両方に節を追加する。
- `QUICK-HOWTO.md`: 既存 6 章「トラブルシューティング」の直前に独立節 **5.5** として追加
  （Step 5「最初の Issue で動かしてみる」の直後、watcher を起動する前にユーザーが警告を
  見るタイミングと整合）
- `README.md`: 既存「GitHub ラベルの自動セットアップ (#85)」の直下に
  `#### fork / mirror clone から導入するときの注意（履歴持ち込み警告 #115）` として追加
  （配置完了直後の自動検出機能というカテゴリで同居させると読者が探しやすい）

理由:
- Issue 本文と requirements 7.3 で「QUICK-HOWTO（または README 同等節）」と両論併記
  だったが、QUICK-HOWTO.md は実在しており（リポジトリ root）、簡潔な fast-path として
  別途読者がいる。両方に書くのが冗長度より参照性で勝る

## 実装ポイント

### 追加した関数（install.sh）

| 関数名 | 役割 |
|---|---|
| `inherited_prefix` | `--dry-run` 値に応じて `[DRY-RUN] WARNING:` / `[INSTALL] WARNING:` を切り替えて返す |
| `inherited_skip_log` | 検出が skip された理由を `[INSTALL] INFO: [inherited] <reason>` 形式で stderr に出力（grep 可能） |
| `warn_inherited` | 警告本文を stderr に出力し、`INHERITED_WARNED_PREVIOUSLY=true` を立てる |
| `detect_inherited_specs` | D-1: `docs/specs/<数字>-*/` ディレクトリを検出して警告 |
| `_list_claude_issue_branches` | origin の `claude/issue-<数字>-(design\|impl)-*` ブランチ名を 1 行 1 件で stdout に返す（exit 10 = origin 未設定で無音 skip） |
| `detect_inherited_claude_branches` | D-2: ブランチを検出して警告し、結果をグローバル変数 `INHERITED_BRANCHES` に格納 |
| `detect_orphan_claude_branches` | D-3: `INHERITED_BRANCHES` の `<番号>` を `gh issue list --state all` と突合し、過半数が現存 Issue に無ければ警告 |
| `print_inherited_footer` | 警告が 1 件以上出ていた場合のみ末尾フッター（「無視しても install は完了」/ README ・ QUICK-HOWTO 参照）を 1 度だけ出力 |
| `detect_inherited_artifacts` | エントリポイント。D-1 → D-2 → D-3 → footer の順に呼ぶ |

### 呼び出し位置

`install.sh` の `if $INSTALL_REPO; then ... fi` ブロックで、`setup_repo_labels "$REPO_PATH"` の
直後に `detect_inherited_artifacts "$REPO_PATH"` を追加した（Issue #85 ラベル自動セットアップと
同じ「配置完了直後」のタイミング、`--local` 単独時は呼ばれない）。

### 設計上の判断ポイント

1. **subshell 回避のためグローバル変数 `INHERITED_BRANCHES` を採用**
   - 当初 `branches=$(detect_inherited_claude_branches ...)` のように command substitution で
     渡そうとしたが、subshell 内で `INHERITED_WARNED_PREVIOUSLY=true` を立てても親シェルに
     伝わらず、末尾フッターが表示されない問題が発生した
   - グローバル変数 `INHERITED_BRANCHES` に格納する形にして親シェルでフラグが立つよう修正

2. **`origin` 未設定は「無音 skip」**（exit code 10 の特殊扱い）
   - clean 新規 repo（`git init` 直後で origin 未設定）では Req 8.3 の「出力差分ゼロ」を
     満たすため、skip 理由ログ自体も出さない
   - 一方、origin はあるが ls-remote が失敗するケース（ネットワーク不通・認証エラー）は
     skip 理由を 1 行残す（Req 3.4）

3. **タイムアウト保護**: `git ls-remote` と `gh issue list` に `timeout 10` を被せた
   （NFR 1.1 / 1.2）。`timeout` コマンドが無い環境ではフォールバックで素のコマンドを実行する

4. **D-3 の閾値「過半数」**: 整数演算で `missing*2 > total` として実装
   （= 50% より大きい）。requirements の文言「過半数」と一致

## 後方互換性の確認

| 確認項目 | 結果 |
|---|---|
| `--help` 出力が従来通り | OK（変更なし） |
| 既存オプション `--repo` / `--local` / `--all` / `--dry-run` / `--force` / `--no-labels` の解釈 | OK（変更なし） |
| 対話モード（引数なし）のプロンプト文言・順序・分岐 | OK（変更なし） |
| 既存 env var (`IDD_CLAUDE_SKIP_LABELS` 等) の解釈 | OK（変更なし） |
| **clean 新規 repo の stdout/stderr 出力差分**（Req 8.3） | OK（本機能由来の出力 0 行を確認） |
| 新規外部依存（`gh` / `git` / `jq` 以外）の発生 | なし（既存依存内で完結） |
| `setup.sh` からの引数透過（`--repo` / `--dry-run`） | OK（`setup.sh` 側は無変更、`exec bash install.sh "$@"` でそのまま透過） |
| `--local` 単独時の本機能発火 | なし（`if $INSTALL_REPO` ブロック内のため呼ばれない / Req 2.4） |

## shellcheck の結果

```bash
$ shellcheck install.sh
(no output, exit 0)
```

警告ゼロでクリア。`# shellcheck disable=` は既存の SC2086 disable（D-3 内の
`$cmd_prefix gh issue list ...` で意図的に変数を分割展開する箇所、1 箇所のみ）を
追加した。理由は行内コメントで明記。

## Test plan（手動スモークテスト結果）

### Smoke Test 1: clean new repo (false positive zero)

```bash
tmp_repo=$(mktemp -d)
git init "$tmp_repo"
git -C "$tmp_repo" commit --allow-empty -m init
bash install.sh --repo "$tmp_repo" --dry-run
```

出力サマリ:
- inherited-related lines: **0** (expected 0)
- exit: **0** (expected 0)

→ Req 2.1 / 8.3 の「クリーンな新規 repo では本機能由来の出力ゼロ」を満たす。

### Smoke Test 2: D-1 inherited docs/specs/

```bash
tmp_repo=$(mktemp -d)
git init "$tmp_repo"
git -C "$tmp_repo" commit --allow-empty -m init
mkdir -p "$tmp_repo/docs/specs/99-legacy-feature"
bash install.sh --repo "$tmp_repo" --dry-run
```

出力サマリ:
```
[DRY-RUN] WARNING: [docs-specs] inherited な docs/specs/ ディレクトリが 1 件検出されました。...
[DRY-RUN] WARNING: [docs-specs]   - docs/specs/99-legacy-feature/
[DRY-RUN] WARNING: ─────────────────────────────────────────────────────
[DRY-RUN] WARNING: この警告を無視しても install 自体は正常完了しています（exit 0）。
[DRY-RUN] WARNING: 推奨対応:
[DRY-RUN] WARNING:   - 古い docs/specs/<N>-*/ ディレクトリを確認し、不要なら削除してください
[DRY-RUN] WARNING:   - 古い claude/issue-* ブランチを git push origin --delete <branch> で削除してください
[DRY-RUN] WARNING: 詳細手順: README.md / QUICK-HOWTO.md の「fork / mirror clone から導入するときの注意」節
[DRY-RUN] WARNING: ─────────────────────────────────────────────────────
```
- exit: **0**

→ Req 1.1 / 1.4 / 1.5 / 4.2 を満たす。

#### サブテスト 2b: docs/specs/ あるが `<数字>-*/` 不在（Req 2.2）

```bash
mkdir -p "$tmp_repo/docs/specs/templates" "$tmp_repo/docs/specs/howto"
```

出力サマリ: inherited-related lines **0** → Req 2.2 を満たす。

#### サブテスト 2c: 4 件検出（先頭 3 件 + `(+N more)`）

`docs/specs/{99,42,7,11}-*` を作成 → 出力に `(+1 more)` が表示されることを確認。

### Smoke Test 3: D-2 inherited claude/issue-* branches

```bash
tmp_repo=$(mktemp -d)
git init --bare "$tmp_repo/origin.git"
git init "$tmp_repo/work"
git -C "$tmp_repo/work" commit --allow-empty -m init
git -C "$tmp_repo/work" branch -M main
git -C "$tmp_repo/work" remote add origin "$tmp_repo/origin.git"
for b in claude/issue-100-impl-feat-foo claude/issue-200-design-bar; do
  git -C "$tmp_repo/work" branch "$b" main
done
git -C "$tmp_repo/work" push origin --all
bash install.sh --repo "$tmp_repo/work" --dry-run
```

出力サマリ:
```
[DRY-RUN] WARNING: [claude-branches] inherited な claude/issue-* ブランチが 2 件検出されました。...
[DRY-RUN] WARNING: [claude-branches]   - claude/issue-100-impl-feat-foo
[DRY-RUN] WARNING: [claude-branches]   - claude/issue-200-design-bar
[DRY-RUN] INFO: [inherited] owner/repo を解決できず D-3（Issue 番号突合）を skip します
```
- exit: **0**

→ Req 1.2 / 3.3 / 3.4 を満たす（D-3 のみ skip、install 全体は exit 0）。

#### サブテスト 3b: bogus ブランチ（regex 不一致）は検出されない

`claude/issue-bogus-no-num` を origin に push しても warning に出てこないことを確認。
→ 正規表現フィルタが効いている。

### Smoke Test 4: D-3 orphan trigger（gh をスタブして検証）

stub gh で `nameWithOwner=test-owner/test-repo`、`gh issue list` の出力を `1\n2\n3` に固定。
fake ブランチ `claude/issue-99991-...` `99992` `99993` を作成して install.sh を実行:

```
[DRY-RUN] WARNING: [claude-branches] inherited な claude/issue-* ブランチが 3 件検出されました。...
[DRY-RUN] WARNING: [orphan-branches] claude/issue-* ブランチの過半数（3/3）が対象 repo の現存 Issue 番号に存在しません。...
[DRY-RUN] WARNING: [orphan-branches]   - Issue #99991（現存しない）
[DRY-RUN] WARNING: [orphan-branches]   - Issue #99992（現存しない）
[DRY-RUN] WARNING: [orphan-branches]   - Issue #99993（現存しない）
```
→ Req 1.3 を満たす。

#### サブテスト 4b: 1/4（25%）missing → orphan 警告は出ない

`claude/issue-{1,2,3,999}` + `gh issue list` が `1..5` を返す → 1/4 のみ missing
（過半数未満）。orphan warning は **出ない**。
→ 「過半数」閾値が正しく機能。

### Smoke Test 5: 後方互換性

```bash
bash install.sh --help                                       # exit 0
bash install.sh --repo /tmp/scratch --no-labels --dry-run --force  # exit 0
```
→ 既存オプションすべて従来通り動作。

### Smoke Test 6: 非 dry-run の `[INSTALL] WARNING:` プレフィックス

`--dry-run` を外して同じ D-1 シナリオを流すと、警告行プレフィックスが `[INSTALL] WARNING:`
（dry-run 版の `[DRY-RUN] WARNING:` から切替）になることを確認。exit 0。

## 受入基準（Requirement numeric ID）の達成確認

本リポジトリは bash + markdown のため unit-test framework は無く、手動スモークテストで
担保する（CLAUDE.md「テスト・検証」節に準拠）。各 AC が以下のスモークテストで担保されている:

| Requirement | 担保するテスト |
|---|---|
| 1.1 | Smoke Test 2（D-1 警告出力） |
| 1.2 | Smoke Test 3（D-2 警告出力） |
| 1.3 | Smoke Test 4（D-3 orphan 警告 + 4b で「過半数未満は出ない」） |
| 1.4 | Smoke Test 2（フッター「無視しても install は完了している」を確認） |
| 1.5 | Smoke Test 2（フッターに README / QUICK-HOWTO 参照行を確認） |
| 2.1 | Smoke Test 1（clean repo で本機能由来出力 0 行） |
| 2.2 | Smoke Test 2b（`docs/specs/` あるが `<数字>-*/` 不在で出力 0 行） |
| 2.3 | Smoke Test 3 末尾の `INFO: [inherited] owner/repo を解決できず...` skip ログ + Smoke Test 1（origin 未設定で無音） |
| 2.4 | `bash install.sh --local --dry-run` で inherited 系出力 0 行を確認 |
| 3.1 | 全テストで exit 0 維持 |
| 3.2 | Smoke Test 3（D-3 が skip でも全体 exit 0） |
| 3.3 | Smoke Test 3（D-2 は警告、D-3 のみ skip） |
| 3.4 | Smoke Test 3 末尾の skip 理由ログ |
| 4.1 | Smoke Test 2 / 3 / 4 すべて `--dry-run` 下で検出処理が走る |
| 4.2 | Smoke Test 2 / 3 / 4 の `[DRY-RUN] WARNING:` プレフィックス |
| 4.3 | Smoke Test 6 の `[INSTALL] WARNING:` プレフィックス |
| 4.4 | `--dry-run` 下では `git ls-remote` （読み取り）と `gh issue list` （読み取り）のみで書き込み API 呼び出しが発生しない（コード review） |
| 5.1 | 警告プレフィックス `[INSTALL] WARNING:` / `[DRY-RUN] WARNING:` は既存 `[INSTALL] SKIP` / `[DRY-RUN] NEW` 等と同じ書式系統 |
| 5.2 | Smoke Test 2 で `[docs-specs]` / `[claude-branches]` / `[orphan-branches]` の 3 カテゴリ別書式を確認 |
| 5.3 | Smoke Test 2 のフッター 6 行（無視 OK + README/QUICK-HOWTO 参照）を確認 |
| 6.1 | `setup.sh` 側は無変更（既存 `exec bash install.sh "$@"` でそのまま透過） |
| 6.2 | `setup.sh` 経由でも `install.sh` を直接叩いた場合と同じ判定ロジックを通る（透過のため） |
| 7.1 | README.md「fork / mirror clone から導入するときの注意（履歴持ち込み警告 #115）」節を追加 |
| 7.2 | README.md / QUICK-HOWTO.md 両方の節で `git push origin --delete` 等の手順を明示 |
| 7.3 | QUICK-HOWTO.md「5.5 fork / mirror clone から導入するときの注意」節を追加 |
| 7.4 | README.md 該当節「警告を無視した場合の影響」段落を明示 |
| 8.1 | Smoke Test 5 で全既存オプション動作確認 |
| 8.2 | 対話モードの prompt 文字列は **変更していない**（コード diff で確認） |
| 8.3 | Smoke Test 1 で出力差分ゼロを確認 |
| 8.4 | コード review で `gh` / `git` / `jq` 以外を呼んでいないことを確認 |
| NFR 1.1 | `timeout 10` を `git ls-remote` / `gh issue list` に被せる |
| NFR 1.2 | `timeout` 失敗時は skip ログを残して継続（fail-soft） |
| NFR 2.1 | `[INSTALL] WARNING: [<category>] ...` 形式で grep 可能 |
| NFR 2.2 | 警告本文に token 等を出力する経路なし（gh の `nameWithOwner` / `number` のみ取得） |
| NFR 3.1 | `read -r` 等は新規追加していない（コード review で確認） |
| NFR 3.2 | sudo を要求する処理を追加していない |

## 確認事項（Reviewer / 人間判断ポイント）

1. **Open Questions 3 件の Developer 判断について PM / Architect 観点で reject ありますか？**
   - Q1: closed Issue 含む（`--state all`）
   - Q2: 先頭 3 件 + `(+N more)`
   - Q3: README + QUICK-HOWTO 両方

2. **D-3 の警告メッセージ文言**: 現在「fork/mirror clone 由来の可能性が高いです」と
   断定気味の書き方をしている。誤検出時（例: 大規模リポジトリで Issue を物理削除した
   ケース）に過剰反応とならないよう、文末を「可能性があります」程度に弱める案も
   ありえます。要件 1.3 は「fork/mirror 由来の可能性が高い旨」と書かれているので
   現状文言は要件文と一致しているが、UX 観点で reviewer の判断を仰ぐ。

3. **`gh issue list --limit 1000`**: 1000 件超の超大規模 repo では一部の Issue 番号が
   検出母集合から漏れて、本来現存する Issue を「orphan」と誤判定する可能性がある。
   閾値「過半数」のおかげで実害は出にくいが、Out of Scope の「閾値の env var 化」を
   将来 Issue として切り出すなら検討項目になる。

4. **dogfooding 上の自爆リスク**: 本機能を merge して main に乗ると、次回 install.sh
   再実行（idd-claude 自身の `repo-template/` 再配置時）で本リポジトリ自身も検出対象に
   なる。本リポジトリには `claude/issue-*` ブランチが大量にあるため、自分自身で警告が
   出続けることになる。これは「設計どおりの動作」だが、警告が常に出るのが煩わしいと
   reviewer / 人間が判断する場合は、`IDD_CLAUDE_SKIP_INHERITED_CHECK=true` のような
   env opt-out を追加する選択肢がある（要件外なので今回は実装していない）。

## 派生タスク候補（次の Issue 候補）

- 警告閾値（D-3 の「過半数」）の env var 調整（Out of Scope）
- watcher 側の slug 照合ガード（Out of Scope、別 Issue で扱う）
- 本機能の opt-out env var（`IDD_CLAUDE_SKIP_INHERITED_CHECK`）追加（dogfooding ノイズ対策）
