# Implementation Notes — Issue #85

## 概要

`install.sh --repo <path>` / `--all` の延長線で、対象リポジトリの GitHub ラベル
（`auto-dev` / `claude-claimed` / `ready-for-review` 等）を自動セットアップする機能を
追加した。fail-soft 設計のため認証不足や API 失敗で install 全体は止まらず、
`--no-labels` / `IDD_CLAUDE_SKIP_LABELS=true` で完全 opt-out 可能。

## 変更ファイル

- `install.sh` — `--no-labels` 引数追加 + ラベル自動セットアップ helper 群追加 + 配置完了直後の hook
- `README.md` — 「GitHub ラベルの自動セットアップ (#85)」節を追加、既存「ラベル一括作成（推奨）」節に注記
- `docs/specs/85-feat-install-install-sh-repo-idd-claude/tasks.md` — Developer 自己管理のタスク計画
- `docs/specs/85-feat-install-install-sh-repo-idd-claude/impl-notes.md` — 本ファイル

`repo-template/.github/scripts/idd-claude-labels.sh` は **未変更**（既存 interface / 集計書式 / LABELS 定義を保つ Req 6.3 / 6.4 のため）。

## 設計上の判断（Open Questions への対応）

### Q1: 対象 repo `owner/repo` の特定方法の優先順位

**採用順序**:

1. `gh repo view --json nameWithOwner -q .nameWithOwner -R "$repo_path"` を最優先（gh が SSH/HTTPS の差異を吸収してくれる）
2. fallback として `git -C "$repo_path" remote get-url origin` を sed で正規化（SSH `git@github.com:owner/repo.git` / HTTPS `https://github.com/owner/repo.git` 双方を `owner/repo` 形式に）
3. それも失敗したら skip + 手動コマンド案内（Req 3.5）

**`--repo` 引数の意味**: 既存 install.sh 仕様どおり「ローカルパス」のまま据え置き。`owner/repo` 形式は内部的に解決する。後方互換性（Req 6.1）を壊さない判断。

### Q2: `IDD_CLAUDE_SKIP_LABELS=true` env による opt-out

**採用**。`--no-labels` と同等扱いし、env 値は `true|TRUE|True|1|yes|YES` を opt-out として解釈する。理由:

- `curl | bash` 経由のフローでは引数を渡しにくい場面がある（NFR 1.1 の cron-safe 性に有用）
- 既存 idd-claude が `IDD_CLAUDE_USE_ACTIONS` / `IDD_CLAUDE_REPO_URL` / `IDD_CLAUDE_BRANCH` / `IDD_CLAUDE_DIR` 等の `IDD_CLAUDE_*` env 命名規則を持つので命名整合性がある

opt-out 経路は両方が `[INSTALL] SKIP [labels] opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)` という単一メッセージに集約され、認証失敗等の skip と区別できる出力になっている（Req 4.2）。

### Q3: private fork での挙動

要件は **fail-soft 内で完走できれば足りる** としている。`gh repo view` / `gh label list` / `gh label create` のいずれも write 権限を要求する箇所は権限不足で失敗するため、当該失敗は `[INSTALL] FAIL [labels] ...` に集約され install 全体は exit 0 で完走する（Req 3.3）。private fork で成功させるためのベストエフォート対応（owner 切り替え提案等）は本 Issue のスコープ外として未実装。

### Q4: README の手動セットアップ節

**残す + 自動実行との関係を注記**（Req 7.4 への回答）。理由:

- 手動セットアップ経路（`cp -r` で配置するユーザー）が依然存在する
- 自動実行が `gh` 未認証等で skip された場合の fallback 必要
- `--force` で color / description を更新したい既存ユーザー向け

冒頭に warning blockquote を追加して「`install.sh --repo` を使った場合は手動実行は不要」と明記。

## 実装上の判断

- **dry-run 中はラベルスクリプトの存在チェックをスキップ**: dry-run はファイルを実際に配置しないので、`repo_path/.github/scripts/idd-claude-labels.sh` がまだ存在しない可能性がある。dry-run の予定表示が「labels script not found」になるのを避けるため、`gh` 不在 → slug 解決 → DRY-RUN return → 認証チェック → スクリプト存在チェック の順序にした。これは UX 上の判断で、AC 5.4 の「これから実行されるラベルセットアップ内容を表示」を素直に満たす書き方
- **`--force` を渡さない**: Req 2.5 で「既存ラベルの color / description を上書きしない」と明示されているため、自動実行は素の `bash <script> --repo <slug>` で起動し、既存値は保護する
- **集計行の grep**: `idd-claude-labels.sh` の集計書式（`新規作成: 0` 等の行）を sed でパースして `[INSTALL] OK [labels] created=N exists=N updated=N failed=N` のサマリ 1 行を出している。NFR 2.3 の grep 可能性を意識
- **call site**: `if $INSTALL_REPO; then ... REPO_HINT ... setup_repo_labels "$REPO_PATH"; fi` の中に配置。`INSTALL_LOCAL` のみ true の経路は通らないため Req 1.3 / 1.5 を構造的に保証
- **対話モード**: 対話で `INSTALL_REPO=true` になった場合も同じ if ブロックを通るので Req 1.4 を構造的に満たす

## AC → テスト手段マッピング

本リポジトリは bash + markdown が主な成果物のため unit test framework は無し（CLAUDE.md「テスト・検証」節）。AC は **shellcheck + 手動スモークテスト**で担保する。

| Req ID | 内容 | 確認方法 / 結果 |
|---|---|---|
| 1.1 | `--repo` 配置成功直後にラベル起動 | スモーク 2 / スモーク 6 で `🏷  GitHub ラベル自動セットアップ` 出力を観測 |
| 1.2 | `--all --repo <path>` でも起動 | スモーク 8 |
| 1.3 | `--local` 単独では起動しない | スモーク 1 で「ラベルセットアップ」セクションが出力に現れないことを確認 |
| 1.4 | 対話モードで repo 選択時に起動 | コード経路上、対話モードも `INSTALL_REPO=true` を立てるため同じ if ブロックを通る（構造的保証） |
| 1.5 | ラベル対象は対象 repo 1 件 | `setup_repo_labels` は引数 1 つで呼ばれ、内部で 1 つの slug しか解決しない |
| 2.1 | 必須ラベル全件新規作成 | 既存 `idd-claude-labels.sh` の挙動を委譲（Req 6.3 で interface 不変） |
| 2.2 | 不足分のみ追加 | 同上（labels.sh が `--force` なしでは既存をスキップ） |
| 2.3 | 全件存在時は noop | スモーク 6 で `created=0 exists=11 updated=0 failed=0` を観測 |
| 2.4 | 既存削除/リネームしない | `--force` を渡していない、削除 API も呼ばない |
| 2.5 | color / description 上書きしない | `--force` を渡していない |
| 3.1 | gh 不在時 skip | スモーク 7-1（`PATH=/tmp/no-gh-bin` で `gh CLI not found`） |
| 3.2 | gh 未認証時 skip | スモーク 7-2（`HOME=/tmp/empty-home` で `gh CLI is not authenticated`） |
| 3.3 | 権限なしで skip | API 失敗パスに集約され `FAIL` で skip。実権限テストは private fork 環境必要のため部分検証 |
| 3.4 | API 接続失敗時 skip | スモーク 2（`hitoshiichikawa/idd-test-fake` 存在しない repo で `[INSTALL] FAIL ... rc=1`） |
| 3.5 | skip 時に手動コマンドブロック提示 | スモーク 2 / 7-1 / 7-2 / 9 で `手動でラベル一括作成を実行するには:` ブロック出力 |
| 3.6 | コピペ可能な完全コマンド | 同上、`bash <path>/.github/scripts/idd-claude-labels.sh --repo <slug>` を出力 |
| 4.1 | `--no-labels` で完全 skip | スモーク 3 |
| 4.2 | opt-out と認証失敗の区別 | `opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)` メッセージ vs `gh CLI is not authenticated` メッセージで区別可能 |
| 4.3 | `--no-labels` × 他フラグ組み合わせ | スモーク 3 で `--repo` と組み合わせ確認、`--all` / `--dry-run` / `--force` も bool フラグで独立しているため影響なし |
| 4.4 | 既定値 false | `SKIP_LABELS=false` を初期化、env で変更時のみ true |
| 5.1 | 成功時要約表示 | スモーク 6 で `[INSTALL] OK [labels] created=0 exists=11 updated=0 failed=0` |
| 5.2 | skip 時に skip + 手動コマンド | スモーク 2 / 3 / 7-1 / 7-2 / 9 |
| 5.3 | 出力プレフィクス統一 | `[INSTALL]` prefix を踏襲、`log_label_action` ヘルパーで統一 |
| 5.4 | dry-run で API 呼ばずに plan 表示 | スモーク 4（`[INSTALL] DRY-RUN [labels] would run: bash ... --repo ...`） |
| 6.1 | 既存 install.sh フラグ意味不変 | `--repo` / `--local` / `--all` / `-h` / `--help` / `--dry-run` / `--force` の解釈を変更していない（diff 範囲は `--no-labels` 追加と末尾 hook 1 箇所のみ） |
| 6.2 | 対話モードのプロンプト不変 | 対話モードのコード（`if ! $INSTALL_LOCAL && ! $INSTALL_REPO; then ...`）は無変更 |
| 6.3 | idd-claude-labels.sh interface 不変 | `repo-template/.github/scripts/idd-claude-labels.sh` は無変更（git diff で確認） |
| 6.4 | LABELS 定義不変 | 同上 |
| 6.5 | 再 install で破壊しない | スモーク 5 で 2 回連続実行も同じ挙動 |
| 7.1 | README に自動実行記載 | `README.md` に「GitHub ラベルの自動セットアップ (#85)」節を追加 |
| 7.2 | `--no-labels` opt-out 記載 | 同節内で明記 |
| 7.3 | skip 時の手動 fallback 記載 | 同節末尾と既存「ラベル一括作成（推奨）」節の追記で説明 |
| 7.4 | 自動と手動の関係を矛盾なく説明 | 既存節冒頭に warning blockquote を追加（自動実行が成功した場合は手動 step 不要） |
| NFR 1.1 | 追加プロンプトを発行しない | `setup_repo_labels` は `read` を呼ばない |
| NFR 1.2 | sudo を要求しない | sudo を呼ぶ箇所なし |
| NFR 2.1 | 30 秒以内 | スモーク 6 で `time` 計測 ≈ 1.2 秒（end-to-end） |
| NFR 2.2 | タイムアウト時 skip | gh 自体のタイムアウト + シェルの非ゼロ rc を `FAIL` ログに集約。NFR 2.1 の 30s 超に達する API 異常は実観測の機会が無く、構造的保証のみ |
| NFR 2.3 | grep 可能な書式で記録 | `[INSTALL] (OK|SKIP|DRY-RUN|FAIL) [labels] ...` 形式 |
| NFR 3.1 | 認証情報を出力しない | gh の出力をそのまま流すが、gh 自体は token を mask する。install.sh 自体では token を扱わない |
| NFR 3.2 | 追加認証情報入力を要求しない | skip 時は `gh auth login` の案内のみ、対話プロンプトはなし |

## 手動スモークテスト記録（test plan）

実施環境: Linux 6.17.0 / bash 5 / shellcheck 0.10.0 / gh 2.89.0

### 1. shellcheck

```text
$ shellcheck install.sh repo-template/.github/scripts/idd-claude-labels.sh
(no output)  # clean
```

### 2. `--local` 単独でラベル処理が走らない

```text
$ ./install.sh --local 2>&1 | grep -E "(GitHub ラベル|labels)"
（出力なし）
```

→ Req 1.3, 1.5 OK

### 3. `--repo /tmp/idd85-test`（fake remote → API failure）

```text
$ ./install.sh --repo /tmp/idd85-test
...
🏷  GitHub ラベル自動セットアップ
   対象: hitoshiichikawa/idd-test-fake
Error: 既存ラベル一覧の取得に失敗しました: GraphQL: Could not resolve to a Repository ...
[INSTALL] FAIL      [labels] label setup partially failed (created=? failed=?, rc=1)
   手動でラベル一括作成を実行するには:
       cd /tmp/idd85-test
       bash .github/scripts/idd-claude-labels.sh
     または repo 外から:
       bash /tmp/idd85-test/.github/scripts/idd-claude-labels.sh --repo hitoshiichikawa/idd-test-fake
🎉 idd-claude のインストールが完了しました。
$ echo $?
0
```

→ Req 1.1, 3.4, 3.5, 3.6, 5.2, 5.3 OK / install 全体 exit 0

### 4. `--no-labels` opt-out

```text
$ ./install.sh --repo /tmp/idd85-test --no-labels
...
🏷  GitHub ラベル自動セットアップ
[INSTALL] SKIP      [labels] opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)
   手動でラベル一括作成を実行するには:
       cd /tmp/idd85-test
       bash .github/scripts/idd-claude-labels.sh
     または repo 外から:
       bash /tmp/idd85-test/.github/scripts/idd-claude-labels.sh
```

→ Req 4.1, 4.2, 4.3 OK

### 5. `IDD_CLAUDE_SKIP_LABELS=true` env による opt-out

```text
$ IDD_CLAUDE_SKIP_LABELS=true ./install.sh --repo /tmp/idd85-test
...
[INSTALL] SKIP      [labels] opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)
```

→ Open Question 2 への対応 OK

### 6. `--dry-run`

```text
$ ./install.sh --repo /tmp/idd85-test --dry-run
...
🏷  GitHub ラベル自動セットアップ
[INSTALL] DRY-RUN   [labels] would run: bash /tmp/idd85-test/.github/scripts/idd-claude-labels.sh --repo hitoshiichikawa/idd-test-fake
```

→ Req 5.4 OK / 実 API 呼び出しなし（fake remote にもかかわらずエラーが出ない）

### 7-1. gh 不在（PATH に gh が無い環境）

```text
$ env -i HOME=$HOME PATH=/tmp/no-gh-bin /tmp/no-gh-bin/bash -c './install.sh --repo /tmp/idd85-test'
...
[INSTALL] SKIP      [labels] gh CLI not found
```

→ Req 3.1 OK

### 7-2. gh 未認証

```text
$ env -i HOME=/tmp/empty-home PATH=/usr/bin:/bin bash -c './install.sh --repo /tmp/idd85-test'
...
[INSTALL] SKIP      [labels] gh CLI is not authenticated (run: gh auth login)
```

→ Req 3.2 OK

### 8. `--all --repo`

```text
$ ./install.sh --all --repo /tmp/idd85-test 2>&1 | grep -E "(GitHub ラベル|labels)"
🏷  GitHub ラベル自動セットアップ
[INSTALL] FAIL      [labels] label setup partially failed (created=? failed=?, rc=1)
```

→ Req 1.2 OK

### 9. owner/repo 解決失敗（origin remote なし）

```text
$ rm -rf /tmp/idd85-noremote && mkdir -p /tmp/idd85-noremote && cd /tmp/idd85-noremote && git init -q && cd -
$ ./install.sh --repo /tmp/idd85-noremote
...
[INSTALL] SKIP      [labels] could not resolve owner/repo from /tmp/idd85-noremote
```

→ slug 解決失敗時の skip 経路 OK

### 10. 実 repo（success path）

```text
$ git clone --depth 1 https://github.com/hitoshiichikawa/idd-claude /tmp/idd85-real
$ time ./install.sh --repo /tmp/idd85-real
...
🏷  GitHub ラベル自動セットアップ
   対象: hitoshiichikawa/idd-claude
📌 idd-claude ラベルを作成します
   対象: hitoshiichikawa/idd-claude

  auto-dev                  ... already exists (skipped; use --force to update)
  ...（11 ラベルすべて already exists）
[INSTALL] OK        [labels] created=0 exists=11 updated=0 failed=0
🎉 idd-claude のインストールが完了しました。

real    0m1.199s
```

→ Req 1.1, 2.3, 5.1, NFR 2.1 OK（idempotent / 既存ラベル保護 / 1.2s で完走）

### 11. 冪等性（連続 2 回実行）

```text
$ ./install.sh --repo /tmp/idd85-test ; ./install.sh --repo /tmp/idd85-test
（両回とも同じ FAIL ログ + 手動コマンド出力 / install 全体 exit 0）
```

→ Req 6.5 OK

### 12. `--help` の更新確認

```text
$ ./install.sh --help
...
#   --no-labels      対象リポジトリ配置時に走る GitHub ラベル自動セットアップを完全に skip
#                    （`IDD_CLAUDE_SKIP_LABELS=true` env でも同等の opt-out が可能）
```

## 確認事項（PR 本文への転記候補）

1. **`IDD_CLAUDE_SKIP_LABELS` env を採用**: 要件上は `--no-labels` のみ必須だが、`curl | bash` フローでの利便性のため env 経由 opt-out も追加した（Open Question 2）。後方互換性問題は無いが、追加 env 名のレビューをお願いしたい
2. **slug 解決の優先順位**: `gh repo view` 優先 → `git remote get-url origin` 正規表現 fallback の 2 段。env var `REPO` を解決源として加えるかは保留した（既存 install.sh の `--repo` 引数と意味衝突するため）。今後 watcher との整合のために env を増やす場合は別 Issue で議論したい（Open Question 1）
3. **private fork の権限不足ケース**: 現状 fail-soft で skip されるが、ベストエフォートで成功させるための owner 切り替え提案等は実装していない（Open Question 3, スコープ外）
4. **既存 README 「ラベル一括作成（推奨）」節**: 残して fallback 位置付けに格下げ（Open Question 4）。節を削除する案もあったが、手動セットアップ経路ユーザーへの後方互換性を優先した
5. **テストフレームワーク不在**: 本リポジトリは bash + markdown が主な成果物で unit test framework が無いため、検証は shellcheck + 手動スモークテスト（CLAUDE.md「テスト・検証」節準拠）に依拠している。設計上の妥当性は手動テスト 12 ケースで担保

## 派生タスク候補（次の Issue 候補）

- watcher 側（`local-watcher/bin/issue-watcher.sh`）からのラベル不足検知 + 自動補完（本 Issue では Out of Scope と明示）
- private fork での owner 切り替え提案（fail-soft 内のベストエフォート向上）
- `setup.sh` 経由での `--no-labels` 透過確認（実装上は引数透過するが E2E 確認が未実施）
