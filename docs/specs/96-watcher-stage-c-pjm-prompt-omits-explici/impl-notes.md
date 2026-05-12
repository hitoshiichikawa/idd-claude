# 実装ノート — Issue #96 / Stage C PjM プロンプトに base ブランチを明示する

## 概要

Stage C / design-review / Actions の各 PjM 起動プロンプトに、当該サイクルの **解決済み
`BASE_BRANCH` 実値**（リテラル文字列）を埋め込み、`gh pr create --base <resolved-base>` の
明示を必須化した。あわせて `repo-template/.claude/agents/project-manager.md` に「PR の base
ブランチ解決」節を追加し、PjM サブエージェントが `--base` を省略しないことと、PR 作成後の
`baseRefName` 検証手順を規約として明文化した。

## 変更ファイル

1. `local-watcher/bin/issue-watcher.sh`
   - `_assert_base_branch_resolved` 関数を新設（Stage C / design 分岐に挿入する空値ガード）
   - `build_dev_prompt_c` に「PR の base ブランチ（必ず明示）」節を追加し、`gh pr create --base ${BASE_BRANCH}` を肯定形で指示
   - `run_impl_pipeline` の Stage C 入口で `_assert_base_branch_resolved` を呼び出し、空なら `mark_issue_failed` で `claude-failed` を付与
   - design モード分岐（旧 4484 行目周辺）の `DEV_PROMPT` heredoc に同等の「PR の base ブランチ（必ず明示）」節を追加
   - design 分岐入口でも `_assert_base_branch_resolved` を呼び出し、空なら `_slot_mark_failed` で `claude-failed` を付与
2. `.github/workflows/issue-to-pr.yml`
   - `impl-resume` 経路のプロンプトに「PR の base ブランチ（必ず明示）」節と `--base ${{ env.BASE_BRANCH }}` 指示を追加
   - `initial`（design / impl 兼用）経路のプロンプトにも同じ節を追加。Step 2 の各サブエージェント起動指示に `--base` 明示を併記
3. `repo-template/.claude/agents/project-manager.md`
   - 冒頭に「PR の base ブランチ解決（design-review / implementation 共通）」節を新設
   - 両モード（design-review / implementation）の `base:` 行を「`--base <resolved-base>` を必ず明示する」に書き換え
   - PR 作成後の `baseRefName` 検証手順と escalation 手順を追加
4. `README.md`
   - 「ブランチ運用と `BASE_BRANCH`」節の末尾に「PR base の明示と検証（Issue #96）」サブ節を追加

## AC Traceability

| Requirement | 対応箇所 | 検証 |
|---|---|---|
| Req 1.1 | `issue-watcher.sh:build_dev_prompt_c` に「PR の base ブランチ（必ず明示）」節を追加し、`--base ${BASE_BRANCH}` を肯定形で記述 | 後述「スモークテスト 1 (impl)」で `--base develop` がリテラル出力されることを確認 |
| Req 1.2 | `issue-watcher.sh` design モード DEV_PROMPT heredoc に同等の節を追加 / Actions workflow の initial 経路にも追加 | grep 結果に `--base ${BASE_BRANCH}` / `--base ${{ env.BASE_BRANCH }}` の両方が出ることを確認 |
| Req 1.3 | watcher が `BASE_BRANCH=develop` で PjM 起動 → prompt 内 `--base develop` 指示 + PjM 側で `--base` 明示 → PR は `baseRefName=develop` で作成される（観測手順は dogfood E2E で人間が確認する） | 設計判断のみ。E2E は本 PR merge 後の dogfood で観測 |
| Req 1.4 | `BASE_BRANCH` 未設定時の既定 `main` チェーン（`BASE_BRANCH="${BASE_BRANCH:-main}"`）は不変。prompt は `main` をリテラルとして埋め込む | 後述「スモークテスト 3 (BASE_BRANCH=main)」で確認 |
| Req 1.5 | `_assert_base_branch_resolved` を新設し Stage C / design 入口で呼ぶ。空値検出時は `claude-failed` ラベル付与で人間にエスカレ | 後述「スモークテスト 4 (空値ガード)」で rc=1 + stderr を確認 |
| Req 2.1 | prompt の複数箇所（「PR の base ブランチ」節 / 進め方 Step 2 / 制約節）に解決済み base 実値を埋め込み | スモークテスト 1〜3 の出力で 4 箇所以上に `develop` / `main` のリテラルが出ることを確認 |
| Req 2.2 | heredoc で `${BASE_BRANCH}` を展開済みリテラルとして埋め込む（プレースホルダ表記なし） | grep + スモークテストで `<BASE_BRANCH>` 表記がプロンプト本文に残っていないことを確認 |
| Req 2.3 | `project-manager.md` 冒頭の「PR の base ブランチ解決」節に「呼び出し元プロンプトに記載された解決済み base ブランチ値を `--base <base>` で必ず明示」と明記 | 文面を確認（line 17-19） |
| Req 2.4 | 同節「プロンプトに base 実値が含まれていない場合（escalation）」サブ節で PR 作成中断 + `claude-failed` を規定 | 文面を確認（line 50-58） |
| Req 3.1 | `project-manager.md` 「PR 作成後の検証」サブ節に `gh pr view --json baseRefName` の取得手順を明記 / watcher prompt 本文にも同じ手順を併記 | スモークテスト 1 の出力に `gh pr view <PR> --json baseRefName --jq '.baseRefName'` が含まれることを確認 |
| Req 3.2 | `project-manager.md` 「PR 作成後の検証」サブ節で不一致時の `gh pr edit --base` または失敗エスカレ手順を明記 | 文面を確認（line 30-42） |
| Req 3.3 | `project-manager.md` で検証結果を PR 本文 / PR コメント / Issue コメントのいずれかに 1 行記載するよう規定。watcher prompt 本文にも併記 | スモークテスト 1 の出力に「結果（一致 / 不一致 / 修正実施の有無）を PR 本文の『確認事項』または Issue コメントに 1 行記載」の文面が含まれることを確認 |
| Req 4.1 | `BASE_BRANCH` 未設定時の `main` 既定値解決は不変（`issue-watcher.sh:75` の `${BASE_BRANCH:-main}` は触っていない） | スモークテスト 3 で確認 |
| Req 4.2 | 同上。PjM は `--base main` を明示するため `baseRefName=main` で作成される（既存挙動と一致） | E2E は本 PR merge 後の dogfood で観測 |
| Req 4.3 | `project-manager.md` の「PR の base ブランチ解決」節は design-review / implementation の **共通節** として冒頭に配置。両モードの実施事項に同じ参照が入っている | 文面を確認 |
| Req 4.4 | 既存の「`${BASE_BRANCH}` に直接 push しないこと」否定形制約は維持。base 明示の追加指示は補強として並置 | grep で `${BASE_BRANCH} に直接 push しないこと` 行が変更前と同様に残っていることを確認 |
| Req 5.1 | `.github/workflows/issue-to-pr.yml` の `impl-resume` および `initial` 経路に「PR の base ブランチ（必ず明示）」節と `--base ${{ env.BASE_BRANCH }}` を追加 | grep 結果で workflow 内に `--base ${{ env.BASE_BRANCH }}` が複数箇所出ることを確認 |
| Req 5.2 | 両経路で同じ `BASE_BRANCH` / `IDD_CLAUDE_BASE_BRANCH` 値を読み取り PjM に明示するため、結果として同じ `baseRefName` の PR が作成される | E2E は本 PR merge 後の dogfood で観測 |
| Req 5.3 | watcher の design / impl / impl-resume 全モード、および Actions の impl-resume / initial（design / impl 兼用）の全モードに base 明示指示が入る | grep + 文面確認 |
| NFR 1.1 | `BASE_BRANCH` 未設定リポジトリでは prompt が `--base main` を指示。`main` を base とした PR 作成は本機能導入前と同等 | スモークテスト 3 |
| NFR 1.2 | env var 名（`BASE_BRANCH` / `IDD_CLAUDE_BASE_BRANCH`）・ラベル名・exit code 意味は変更していない | grep 結果で既存名がそのまま使われていることを確認 |
| NFR 2.1 | PjM は `--base` 指定値 / `baseRefName` / 一致可否のいずれかを PR 本文・PR コメント・Watcher ログから確認可能な形で残す（`project-manager.md` で規約化 + watcher prompt で指示） | 規約として明文化 |
| NFR 2.2 | 不整合検出時の自動修正・失敗エスカレ手順を `project-manager.md` の検証節で 1 セクションに集約 | 文面を確認 |
| NFR 3.1 | README の「PR base の明示と検証（Issue #96）」サブ節と `project-manager.md` の「PR の base ブランチ解決」節は整合的に同じ規約を説明している | 文面を確認 |

## 検証結果

### shellcheck

```bash
shellcheck local-watcher/bin/issue-watcher.sh install.sh setup.sh .github/scripts/*.sh
```

- 既存の info-level warning（SC2317 = unreachable command, SC2012 = `ls` 利用）が 10 件出るが、
  これらはすべて本 PR 変更外の既存箇所。**本 PR で追加された新規 warning は 0 件**
- 本 PR で追加した `_assert_base_branch_resolved` 関数 / Stage C / design 分岐の追加コードは
  クリーン

### actionlint

```bash
actionlint .github/workflows/issue-to-pr.yml
```

- 既存 warning 2 件（line 111 の `ls` 利用 / `github.event.issue.title` を inline script で
  使用）がそのまま残るが、これらは本 PR 変更外の Detect mode step。本 PR で追加した prompt
  本文の変更は actionlint に新たに引っかかっていない（prompt は heredoc 内文字列で
  shellcheck 対象外）

### スモークテスト（プロンプト文字列の目視確認）

`bash` で `build_dev_prompt_c` 関数を `eval` 抽出し、`BASE_BRANCH=develop` / `BASE_BRANCH=main`
で実プロンプト文字列を生成して目視確認した。

- **テスト 1**: `BASE_BRANCH=develop, MODE=impl` → プロンプト内に `--base develop` がリテラル
  として 3 箇所（「PR の base ブランチ」節 / 進め方 Step 2 / `gh pr edit` 修正例）に出現
- **テスト 2**: `BASE_BRANCH=develop, MODE=impl-resume` → 同上 + 設計 PR 検索文に `develop` が
  追加で 1 箇所出現
- **テスト 3**: `BASE_BRANCH=main` → `--base main` がリテラルとして 3 箇所に出現（既定値ケース、
  本機能導入前と等価な base が指示される）
- **テスト 4**: `_assert_base_branch_resolved` を `BASE_BRANCH=""` / 未設定 / `develop` / `main` で
  実行し、空値時のみ rc=1 + stderr エラー、非空時は rc=0 を確認

### 完了条件（手動確認）

- [x] Stage C プロンプトに `--base <literal>` 指示が肯定形で含まれる
- [x] design モードプロンプトに `--base <literal>` 指示が肯定形で含まれる
- [x] Actions workflow の両プロンプトに `--base ${{ env.BASE_BRANCH }}` 指示が含まれる
- [x] `project-manager.md` の冒頭に共通の base 解決規約節がある
- [x] `BASE_BRANCH` 空値ガードが Stage C / design の両入口に挿入されている
- [x] `BASE_BRANCH` 未設定時の既定 `main` 解決ロジックは変更されていない（NFR 1.1）
- [x] shellcheck / actionlint で新規 warning が発生していない
- [x] README に新規規約のセクションが追加されている

## 設計上の判断

### prompt 注入箇所を「複数箇所」に分散させた理由（Req 2.1）

Req 2.1 は「PjM 起動セクション内で base ブランチを実値として 1 箇所以上に提示」を要求。本実装では
さらに防御的に **3〜4 箇所**に同じリテラルを散らした:

1. 「PR の base ブランチ（必ず明示）」専用節（プロンプト先頭、PjM の目に必ず止まる位置）
2. 「進め方」Step 2 の `base:` 行（既存テンプレートの自然な配置）
3. `gh pr edit` の修正例コマンド文（不整合時の自動修正で参照）
4. 制約節の `--base 省略禁止` 文

冗長だが、LLM プロンプトでは「同じ指示を複数箇所に置く方が確実に守られる」傾向があり、Issue
本文の根本原因が「否定形制約だけだと PjM が `--base` を省略する」だったことを踏まえた防御策。

### 後方互換性の担保（Req 4 / NFR 1）

- `BASE_BRANCH="${BASE_BRANCH:-main}"` の正規化行（`issue-watcher.sh:75`）は **一切触っていない**
- 既存の `${BASE_BRANCH} に直接 push しないこと` 否定形制約も維持（Req 4.4）
- 未設定 → `main` 解決 → `--base main` 指示 → `baseRefName=main` の PR 作成、という挙動は本機能
  導入前と差分等価

### Feature Flag Protocol の採否

`CLAUDE.md` の `## Feature Flag Protocol` 節は `**採否**: opt-out` のため、本 Issue は **通常の
単一実装パス**で実装した。flag 裏実装は導入していない。

## 確認事項（PR レビュワー向け）

- Req 1.3 / Req 1.4 / Req 4.2 / Req 5.2 の E2E 観測（実際に develop / main を base とした PR が
  生成されること）は、本 PR merge 後の self-hosting dogfood Issue で人間が確認する想定。本実装
  PR 内では prompt 文面の目視確認のみで AC を満たしたとみなしている
- `project-manager.md` の `<resolved-base>` 表記は意図的なプレースホルダ（PjM がプロンプトから
  読み取る値の位置を示す）。これは Req 2.2 の「プレースホルダ表記禁止」とは別の文脈（agent 定義
  本文 vs. PjM 起動プロンプト本文）と解釈している。要件文面の「Watcher Orchestration Prompt」
  の対象範囲は watcher / Actions が組み立てる PjM 起動プロンプト本文に限定され、agent 定義書の
  例示記法は対象外と読んだ
- design-review 経路は watcher 側の最初の design 分岐でのみ走り、PjM iteration 経路（design PR
  に `needs-iteration` が付いた場合）は新規 PR 作成を行わないため対象外（Stage C / design の
  PjM 起動経路のみが本 Issue のスコープ）

## 派生タスク候補

- PjM の base 検証ロジック（`baseRefName` 比較 + 自動 `gh pr edit` 修正）を watcher 側のシェル
  ヘルパに切り出すか検討（現状は LLM プロンプトに手順を埋め込んだ規約のみ。LLM の指示遵守に
  依存している）。失敗時の `claude-failed` 付与までを watcher 側の post-Stage C 検証で機械的に
  保証する別 Issue を切る余地あり
