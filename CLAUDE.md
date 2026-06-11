# プロジェクトガイド（Claude Code 全エージェント共通）

このファイルは Claude Code 本体および全サブエージェントが毎回参照するプロジェクト憲章です。
**すべてのエージェントは、作業開始前にこのファイルを読み直してください。**

---

## このリポジトリについて

**idd-claude はツール / テンプレートリポジトリ** です。他の repo に配置する開発ワークフローテンプレートと、ローカル watcher スクリプト一式を提供します。

**重要: self-hosting (dogfooding)**: idd-claude 自身も idd-claude のワークフロー対象 repo として運用しています（`repo-template/` 一式を root にも配置）。**あなたが編集している watcher スクリプトやテンプレートそのものが、次回 cron 実行であなた自身を動かす**ことを意識してください。後方互換性と冪等性が極めて重要です。

**構成要素**:

- `local-watcher/` — ローカル実行用 bash スクリプト (`issue-watcher.sh`, Triage prompt template)
- `repo-template/` — 他 repo に配置するテンプレート (CLAUDE.md, agents, rules, ISSUE_TEMPLATE, workflows, labels script)
- `install.sh` / `setup.sh` — インストーラ（ユーザースコープ、sudo 不要）
- `README.md` — 設計思想とセットアップ手順の主要ドキュメント
- `.github/workflows/issue-to-pr.yml` — GitHub Actions 版ワークフロー（`IDD_CLAUDE_USE_ACTIONS=true` で opt-in）

アプリケーションコード（JS/TS/Python バックエンド等）はありません。本体は **bash + markdown + GitHub Actions YAML**。

---

## 言語方針（思考言語と出力言語）

idd-claude self-hosting 上で稼働するすべての Claude エージェント（PM / Architect / Developer /
Reviewer / PjM）は、以下の方針で **内部思考言語と出力言語を使い分ける**こと。reasoning トークン
消費を抑制しつつ、運用者・レビュワーの可読性を維持するための規約です。

### 基本原則

- **内部思考（reasoning / chain-of-thought / 内部スクラッチパッド）は英語ベース**で行う
  （英語の方が同等内容を表現するのに必要なトークン数が少ないため）
- **ユーザーが直接読むアウトプットは日本語ベース**で出力する（運用者の可読性優先）
- 言及されていない種別は **既定で日本語ベース**を選択する（fallback ルール）

### 種別ごとの言語選択

| 種別 | 言語 | 補足 |
|---|---|---|
| LLM の内部 reasoning / scratchpad | **英語** | ユーザーに見えない領域。トークン効率優先 |
| GitHub Issue / PR の本文・コメント・レビューコメント | **日本語** | 運用者・レビュワー向け |
| `docs/specs/<番号>-<slug>/` 配下の markdown（`requirements.md` / `design.md` / `tasks.md` / `impl-notes.md` / `review-notes.md`） | **日本語** | 成果物の本文 |
| EARS トリガーキーワード（`When` / `If` / `While` / `Where` / `shall`） | **英語固定** | `.claude/rules/ears-format.md` の規約に従う。可変部のみ日本語可 |
| Conventional Commits プレフィックス（`feat` / `fix` / `docs` / `refactor` / `chore` / `test`） | **英語固定** | prefix と scope は ASCII |
| ブランチ名（`claude/issue-<番号>-<slug>`） | **英語固定** | slug は ASCII（lowercase ハイフン区切り） |
| 識別子・コマンド名・ファイルパス・env var 名・ラベル名 | **英語固定** | コード／運用と整合させる |
| コミットメッセージ本文（prefix 後の説明部分） | **日本語ベース** | 既存 git log 慣習に準拠（混在許容、技術用語の英語そのまま記述は可） |
| PR タイトル | **日本語ベース** | prefix（`feat(scope):` 等）は英語固定、説明部分は日本語 |
| bash スクリプトのログ出力（`echo` 文字列等） | **混在許容** | 既存実装に準拠。新規追加分は日本語ベースを推奨するが、既存実装の書き換えは本方針の対象外 |
| `.claude/agents/*.md` のエージェント定義本文 | **日本語** | 人間運用者向けの指示書きであり、エージェント自身の出力ではない |

### 既存規約との整合

- EARS の英語固定トリガーキーワードは本方針の例外規定に含まれる（reasoning 中もそのまま英語表記を保持）
- Conventional Commits / ブランチ命名規約 / 識別子は英語固定。日本語化しない
- 本方針と `.claude/rules/*.md` の他ルールに矛盾が生じた場合、エージェントは独自解釈で確定せず
  PM / 人間にエスカレーションする

---

## 技術スタック

- **スクリプト**: bash 4+ (Linux / macOS / WSL)
- **依存 CLI**: `gh`, `jq`, `flock`（Linux 標準、macOS は `brew install util-linux`）, `git`
- **GitHub Actions**: `actions/checkout`, `anthropics/claude-code-action` 等
- **モデル**: Triage は Sonnet 4.6、本実装は Opus 4.7 (1M context) をデフォルト
- **ランタイム追加なし**: Node.js / Python 等は依存しない

---

## コード規約

### bash スクリプト（本リポジトリのコア成果物）

- 冒頭で `set -euo pipefail` を必ず宣言
- 変数展開は常にクォート (`"$var"`, 配列は `"${arr[@]}"`)
- `which` ではなく `command -v` でコマンドの存在確認
- `~` ではなく `$HOME` を使う（cron は `~` を展開しない事故が起きる）
- ファイル冒頭のコメントで「用途 / 配置先 / 依存 / セットアップ参照先」を明記する（現行 `issue-watcher.sh` / `install.sh` 参照）
- 環境変数は `"${VAR:-default}"` で override 可能にし、**既存 env var 名（`REPO`, `REPO_DIR`, `LOG_DIR`, `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）は後方互換性のため壊さない**
- 破壊的操作（`git checkout`, `rm -rf`, `git push --force*`）の前に前提条件を check
- エラーメッセージは `>&2` に出す。標準出力は機械可読な結果用に予約する

### markdown（テンプレート類）

- h1 はファイル先頭 1 つのみ、以降は階層を一貫させる
- コードフェンスには言語タグを付ける（` ```bash ` / ` ```yaml ` 等）
- 内部リンクは相対パス、コード箇所は `file_path:line_number` 形式
- 絵文字はステータス表示に限定して節度を持つ

### yaml (GitHub Actions workflow)

- `actionlint` をクリアすること
- `permissions:` は最小権限に絞る
- secrets は `${{ secrets.NAME }}` で参照、echo しない

### 全体共通

- 単一責務の関数・セクションに分割する
- 設定値（URL、path prefix、default 値）はファイル冒頭の config ブロックにまとめる
- silent fail を作らない（失敗は exit code / log で明示）

---

## テスト・検証

**本リポジトリには unit test フレームワークはありません**。検証は以下の組み合わせ:

### 静的解析

- `shellcheck local-watcher/bin/*.sh install.sh setup.sh .github/scripts/*.sh` — 警告ゼロを目指す（accepted な info 級 false-positive は root の `.shellcheckrc` で抑止＝`SC2317`/`SC2012`。これにより stage-a-verify の素 `shellcheck` verify ブロックも accepted baseline を反映して通る）
- `actionlint .github/workflows/*.yml` — workflow YAML の検査
- `diff -r .claude/agents repo-template/.claude/agents` — root↔repo-template の agents の byte 一致検証（差分が出たら二重管理規約違反。片系統だけ更新したドリフトを検出する）
- `diff -r .claude/rules repo-template/.claude/rules` — root↔repo-template の rules の byte 一致検証（差分が出たら二重管理規約違反。片系統だけ更新したドリフトを検出する）

### 手動スモークテスト（変更した成果物ごとに実施）

- **`install.sh` 変更時**: 使い捨て scratch repo を `/tmp` に作り、`./install.sh --repo /tmp/scratch` を実行して冪等性とファイル配置を確認
- **`setup.sh` 変更時**: `IDD_CLAUDE_DIR=/tmp/setup-test bash setup.sh` で新規クローン / 既存ディレクトリ双方で動くこと
- **`issue-watcher.sh` 変更時**:
  - cron-like 最小 PATH での依存解決: `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v claude gh jq flock git'`（`local-watcher/bin/issue-watcher.sh` 冒頭の PATH prepend を経由して解決されること）
  - dry run: `REPO=owner/test REPO_DIR=/tmp/test-repo $HOME/bin/issue-watcher.sh` を対象なし状態で流し、`処理対象の Issue なし` で正常終了すること
  - E2E: 本リポジトリに test issue を立てて watcher が Triage → PR 作成までできるか

### 冪等性

- `install.sh` / `setup.sh` / `.github/scripts/idd-claude-labels.sh` は再実行で破壊しない
- 既存ファイルがある場合は `.bak` バックアップまたは `--force` で opt-in 上書き

### dogfooding (E2E)

- 大きい機能変更は、本 repo 自身に対して `auto-dev` Issue を立てて watcher が正しく拾えるかで最終確認する

---

## ブランチ・コミット規約

- ブランチ名: `claude/issue-<番号>-<slug>` を原則とする
- コミット: [Conventional Commits](https://www.conventionalcommits.org/) に準拠
  - `feat(scope): ...` / `fix(scope): ...` / `docs(scope): ...` / `refactor(scope): ...` / `chore(scope): ...` / `test(scope): ...`
  - 典型的な scope: `watcher` / `install` / `setup` / `workflow` / `claude`（`repo-template/CLAUDE.md`）/ `readme` / `labels`
- 1 PR = 1 Issue を原則とする（スコープが膨らむ場合は PM が分割提案）

---

## 禁止事項

- base ブランチ（既定 `main`、`BASE_BRANCH` 設定によっては `develop` 等）への直接 push
- `.env` / Secrets 実値のコミット、スクリプト内 API Key ハードコード
- **後方互換性を壊す変更を無告知で入れる**（既存 env var 名変更 / cron 登録文字列の変更 / ラベル名変更 / exit code 意味変更）。破る場合は README に migration note を書き、必要なら deprecation 期間を設ける
- **sudo を必要とする手順の追加**（idd-claude はユーザースコープ前提。`install.sh` / `setup.sh` の root 実行検知を外さない）
- モデル ID のハードコード（env default で override 可能にする。`TRIAGE_MODEL` / `DEV_MODEL` 参照）
- **opt-in gate なしで新しい外部サービス呼び出しを有効化**（`.github/workflows/issue-to-pr.yml` が `IDD_CLAUDE_USE_ACTIONS=true` で opt-in になっている設計を踏襲）。**注**: #112 で実施した「既に main で稼働しデフォルト false で配置された機能」のデフォルト反転（`MERGE_QUEUE_ENABLED` 等 8 種）は本禁止事項の対象外。新規外部サービス呼び出しの追加ではなく、既存機能のデフォルト値変更であるため。詳細は README の「オプション機能一覧」節の migration note を参照
- `repo-template/**` の破壊的変更を、既 installed の consumer repo への影響評価なしに入れる
- テストをコメントアウトして PR を出す（scope 外に分離する場合は Issue を切る）

---

## エージェント連携ルール

- **Product Manager** は実装方針を書かない。要件と受入基準の明確化に専念
- **Architect**（条件付き起動）は要件を変更しない。モジュール構成 / シェルスクリプト分割 / env var 設計 / 後方互換性方針 / ラベル体系 / template 互換性等の設計に専念
- **Developer** は仕様を追加・解釈しない。不明点は PM / Architect に差し戻す
- **Reviewer**（impl 系モードで自動起動）は Developer 完了後の独立レビューのみを担当し、要件・設計・実装・テストの追加や書き換えを行わない。判定は AC 未カバー / missing test / boundary 逸脱 の 3 カテゴリに限定する（スタイル / lint 観点では reject しない）
- **Project Manager** はコードを変更しない。PR 作成と進捗管理に専念
- Architect は Triage の `needs_architect: true` 時のみ PM と Developer の間に挟まれる
- Architect が起動した Issue では **設計 PR ゲート**を経由する
- Reviewer は impl / impl-resume の Developer 完了直後に **独立 context** で起動され、reject 時は Developer に最大 1 回だけ自動差し戻し、再 reject では `claude-failed` で人間に委ねる（差し戻しループは Reviewer 最大 2 回 / Developer 最大 2 回で打ち切り）
- Developer は `design.md` / `tasks.md` を書き換えない（人間レビュー済みのため）。矛盾は PR 本文「確認事項」で指摘する
- 成果物は `docs/specs/<番号>-<slug>/` 配下に保存する
  - `requirements.md`（PM）— EARS 形式の AC、numeric 階層 ID
  - `design.md`（Architect）— File Structure Plan / Components and Interfaces / Traceability
  - `tasks.md`（Architect）— `_Requirements:_` / `_Boundary:_` / `_Depends:_` / `(P)` アノテーション
  - `impl-notes.md`（Developer、補足）
  - `review-notes.md`（Reviewer、impl 系モードのみ）— 判定結果と Findings / 最終行 `RESULT: approve|reject`

### idd-claude 特有の設計上の注意

- **`local-watcher/bin/issue-watcher.sh` の変更**: 既稼働の cron / launchd を壊さない（env var 名、exit code 意味、ログ出力先、ラベル遷移契約を保つ）
- **`repo-template/**` の変更**: 既に installed の consumer repo にも影響する（`install.sh` 再実行で上書きされる）。破壊的変更は migration note 必須
- **`idd-claude-labels.sh` のラベルセット**: ラベル追加は OK、既存ラベル削除 / 名前変更は deprecation 期間を経てから
- **モデル ID デフォルト更新**: 既存ユーザが明示 override している前提で、env default のみ更新
- **README との二重管理**: 挙動を変えたら必ず README の該当箇所も同じ PR で更新する
- **root `.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` の二重管理**: 両者は別系統（root = idd-claude self-hosting が使用 / `repo-template/` = `install.sh --repo` で consumer repo に配布）。片方だけ更新すると **consumer に変更が届かない**か **idd-claude 自身が古い規約で動く**ドリフトが発生する（実例: #224 の構造化 verify ブロック規約・architect.md が root のみ更新で consumer 未配布／per-task ループ・BLOCKED 規約が repo-template のみで root の Developer・Reviewer に欠落）。`.claude/agents/*.md` / `.claude/rules/*.md` を変更したら **同一 PR で両系統に byte 一致で反映する**こと（逆方向も同様）。agents の base ブランチ参照は両系統とも `<BASE_BRANCH>` プレースホルダに統一し、root にも具体値 `main` を焼き込まない（orchestrator が解決値を prompt の `Compared to:` ヘッダで渡すため idd-claude でも正しく動く）。反映後に `diff -r .claude/agents repo-template/.claude/agents` と `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する。**CLAUDE.md / README は consumer 固有内容を持つため本規約の対象外**（それぞれ root 用 / `repo-template/` 用に内容が異なってよい）
- **Phase B Promote Pipeline (#15)**: `PROMOTE_PIPELINE_ENABLED=true` の **明示的 opt-in 制**で、未設定 / `false` の場合は導入前と完全に同一の挙動を保つ。2-branch model（`BASE_BRANCH != PROMOTION_TARGET_BRANCH`）でのみ起動する。`staged-for-release` ラベルは #100 の人間付与運用と同一ラベルを共有し、source 区別はしない。revert / promote はすべて `--force-with-lease` または fast-forward 限定で `--force`（無条件）は使わない

---

## 機能追加ガイドライン（コード・概念の散逸防止）

idd-claude は `local-watcher/bin/issue-watcher.sh`（約 1 万行）+ `modules/` + installer +
GitHub Actions workflow + テンプレート群で構成され、processor / gate / opt-in 機能が継続的に
追加されてきた。**新機能を追加するとき、コードと概念が散逸しないために以下を守る**。本節は
「禁止事項」「コード規約」「エージェント連携ルール / idd-claude 特有の設計上の注意」を束ねる
実務指針であり、矛盾する場合はそれらと本節を併せて読み、独自解釈で確定せず人間にエスカレーション
すること。

### 1. 配置: 本体 inline ではなく module へ切り出す

- **新しい processor / まとまった機能は `local-watcher/bin/modules/<name>.sh` に新規ファイルとして
  足す**。`issue-watcher.sh` 本体へ inline で大きな機能を継ぎ足さない（本体は config /
  module loader / call site / main loop / `--doctor` dispatch に寄せる）。既存の切り出し実績:
  `quota-aware.sh` / `merge-queue.sh` / `auto-rebase.sh` / `promote-pipeline.sh` /
  `pr-reviewer.sh` / `pr-iteration.sh` / `security-review.sh` / `stage-a-verify.sh` /
  `context-map.sh` / `guard-hook.sh` / `scaffolding-health.sh` / `run-summary.sh` /
  `core_utils.sh`（低レベル共通）。
- module は**関数定義のみ**を置きトップレベル副作用を持たせない（`extract_function` テスト
  イディオムと module loader の前提）。本体の `REQUIRED_MODULES` ローダ（同階層 `modules/` を
  source）に登録し、`install.sh` が `$HOME/bin/modules/` へ配布することを確認する。
- 「どの module に置くか」が曖昧な小機能は、責務が最も近い既存 module に同居させ、独立性が
  出てきた段階で切り出す（投機的な新規 module を作らない）。

### 2. 命名: module ごとに関数 prefix namespace を 1 つ持つ

- 各 module は 2〜4 文字の **関数 prefix** を 1 つ持ち、その module の全関数を prefix で
  namespace する。新 module は**新しい未使用の prefix** を割り当て、ファイル冒頭コメントに明記する。

  | prefix | module / 領域 |
  |---|---|
  | `qa_` | quota-aware（ロガー `qa_log` 等は core_utils に同居） |
  | `mq_` / `mqr_` | merge-queue |
  | `ar_` | auto-rebase |
  | `pp_` / `po_` | promote-pipeline（pp=Promote / po=Path Overlap） |
  | `pr_` | pr-reviewer |
  | `pi_` | pr-iteration |
  | `sec_` | security-review |
  | `cm_` | context-map |
  | `gh_` | guard-hook |
  | `sh_` | scaffolding-health |
  | `stage_a_verify_` / `sav_` | stage-a-verify |
  | `rs_` | run-summary |
  | `pt_` / `sc_` / `tc_` / `dr_` | issue-watcher 本体内（per-task / stage checkpoint / tasks-count / dependency-resolver） |

- env var 名・ラベル名・コマンド名・ファイルパスは **英語固定**（言語方針に従う）。

### 3. opt-in gate と後方互換（最重要）

- **外部挙動を変える新機能・新しい外部サービス呼び出しは env gate で opt-in 化し、既定値は
  導入前と完全に同一の挙動（no-op）に倒す**。実績パターン: `*_ENABLED=true`（既定 false） /
  `*_MODE=off`（既定 off） / `IDD_CLAUDE_USE_ACTIONS=true`。gate 未設定・不正値・typo は
  **安全側（無効）** に解決する（起動時に正規化を入れる。例: `AUTO_REBASE_MODE` は `case` で
  `claude` 以外を `off` に丸める）。
- 既存の **env var 名 / ラベル名 / exit code 意味 / cron 登録文字列 / ログ出力先** を無告知で
  壊さない。破壊的変更は README に migration note を書き、必要なら deprecation 期間を設ける
  （「禁止事項」と整合）。
- `repo-template/**` の変更は既 installed の consumer にも影響する。破壊的変更は影響評価 +
  migration note 必須。

### 4. 二重管理・同期の鉄則（ドリフト防止）

- **root `.claude/{agents,rules}/` と `repo-template/.claude/{agents,rules}/` は byte 一致**。
  片方だけ更新しない。変更後に `diff -r .claude/agents repo-template/.claude/agents` と
  `diff -r .claude/rules repo-template/.claude/rules` が空であることを確認する。
- **workflow（`.github/workflows/issue-to-pr.yml` ↔ `repo-template/...`）とラベル script
  （`idd-claude-labels.sh` ↔ `repo-template/...`）も同期させる**。consumer 配布物（workflow /
  labels / modules）に機能を足したら repo-template 側にも反映する（過去にラベル
  `needs-security-fix` 欠落・base-branch 明示プロンプト欠落のドリフトが発生）。`CLAUDE.md` /
  `README` は consumer 固有内容を持つため byte 一致対象外。
- **挙動を変えたら同一 PR で README の該当箇所も更新する**（README は主要ドキュメント）。
- rule が canonical でハーネスが regex を mirror する関係（例: tasks 件数 count regex ↔
  `tc_count_tasks`、verify block well-formed 判定 ↔ `stage_a_verify_extract_verify_block`）は、
  **rule 側を正準として先に更新**し、相互参照コメントを残してドリフトを防ぐ。

### 5. 未信頼 GitHub 入力の取り扱い（セキュリティ / #318）

watcher は Issue/PR 本文・コメント・ラベル・ブランチ名・branch 上ファイルという**未信頼入力**を
`gh` / `git` / `bash -c` / `claude --permission-mode bypassPermissions` に流す。新機能で
これらを扱うときは:

- 変数展開は常にクォート（`"$var"` / 配列は `"${arr[@]}"`）。`jq` へ渡す未信頼値は **`--arg` /
  `--argjson`**（フィルタ文字列へ inline 展開しない）。
- `grep` / `git` / `gh` に未信頼値を渡すときは **`--` でオプション解釈を打ち切る**（`-` 始まりの
  branch 名・pattern によるフラグ注入を防ぐ）。
- 数値 ID は `^[0-9]+$`、commit SHA は `^[0-9a-f]{40}$` で**使用直前に検証**してからパス・URL・
  git revision に使う（path 横断・引数注入の予防）。
- `sed` の置換文字列に未信頼値を入れる場合は `\` / `&` / 区切り文字を網羅エスケープする。
- GitHub Actions では未信頼値・step 出力を `${{ }}` で `run:` 本体へ直接展開せず **`env:` 経由**で
  渡す。`permissions:` は最小権限（既定で不要な `id-token: write` 等を付与しない）。
- LLM プロンプトインジェクション（Issue 本文が bypassPermissions エージェントへ渡る点）は
  idd-claude の設計上の前提であり、`auto-dev` 付与をメンテナ権限に限定する**運用ゲート**で
  受容している。新機能でこの前提（信頼境界）を広げない。

### 6. 状態ファイル・一時ファイルの配置

- 永続的な状態ファイルは予測可能名の `/tmp` ではなく **`$HOME/.issue-watcher/`** 配下を優先する
  （symlink TOCTOU 予防。`LOG_DIR` / `SLOT_LOCK_DIR` が既にこの方針）。一時ファイルは可能なら
  `mktemp` を使い、配置先を env で override 可能にする。

### 7. テストの近接配置

- 新 module / 新関数には `local-watcher/test/<name>_test.sh` を追加し、既存の
  **`extract_function` で単一関数を隔離抽出 → stub → 観測**するイディオムを踏襲する。
  純粋関数（副作用なし）は入出力 fixture で、副作用を伴う関数は `gh` / `git` を stub して
  呼び出しトレースで検証する。**ヘルパーを抽出したら、それを呼ぶ既存テストの抽出リストにも
  追随させる**（隔離抽出の特性上、依存関数を明示 source する必要がある）。

### 8. 機能追加 PR 提出前チェックリスト

- [ ] 大きな機能は本体 inline ではなく `modules/<name>.sh`、prefix namespace を割当
- [ ] 外部挙動変更は env gate で opt-in、既定は後方互換 no-op、不正値は安全側に正規化
- [ ] 既存 env var / ラベル / exit code / cron 文字列を壊していない（破壊時は migration note）
- [ ] `shellcheck` / `actionlint` クリーン、`bash -n` OK、近接テスト追加・通過
- [ ] root ↔ repo-template（agents / rules / workflow / labels）同期、`diff -r` 空を確認
- [ ] 挙動変更を README に同一 PR で反映、rule↔harness の canonical 相互参照を更新
- [ ] 未信頼入力の取り扱い（quote / `--arg` / `--` / ID・SHA 検証 / Actions env 間接化）を確認

---

## エージェントが参照する共通ルール（`.claude/rules/`）

各エージェントは作業前に以下のルールを `Read` で読み込む:

| ルールファイル | 参照エージェント | 役割 |
|---|---|---|
| `ears-format.md` | PM | AC の EARS 記法（When / If / While / Where / shall） |
| `requirements-review-gate.md` | PM | requirements.md の自己レビュー（Mechanical + 判断、最大 2 パス） |
| `design-principles.md` | Architect | design.md の必須セクションと詳細度の方針 |
| `design-review-gate.md` | Architect | design.md の自己レビュー（traceability / File Structure Plan 充填 / orphan 検出） |
| `tasks-generation.md` | Architect / Developer | tasks.md のアノテーション規約と numeric ID 階層 |
| `feature-flag.md` | Developer / Reviewer | Feature Flag Protocol opt-in 宣言時の規約詳細（命名・両系統テスト・クリーンアップ責務） |
| `issue-dependency.md` | PM / Triage / Architect | Issue 間依存・親子関係の canonical 記法（`Depends on:` / `Parent:` 他）と互換 alias マッピング |

ルール群は [cc-sdd](https://github.com/gotalab/cc-sdd)（MIT License, Copyright gotalab）から adapt したものです。

---

## PR 品質チェック（PjM が PR 作成時に確認する項目）

- [ ] すべての受入基準に対応する実装がある
- [ ] `shellcheck` / `actionlint` がクリーン（該当ファイルを変更した場合）
- [ ] 手動スモークテストの結果を PR 本文の「Test plan」に記載
- [ ] 既存 env var 名 / ラベル / cron 登録文字列の後方互換性を確認
- [ ] README / CLAUDE.md / 該当 rule ファイルが更新されている（挙動変更時）
- [ ] 破壊的変更がある場合は README に migration note を追加
- [ ] PR 本文に「確認事項」セクションがある（レビュワー判断ポイントを明示）

---

## 機密情報の扱い

本リポジトリは OSS として公開されるツール / テンプレートです。扱わないもの:

- API keys / OAuth tokens の実値
- 作者個人名義の非公開 path / URL を例示用以外の形でハードコード
- 本番環境の認証情報

Issue 本文に実値が含まれた場合、PM エージェントは実装を進めず `needs-decisions` で人間にエスカレーションする。

---

## 参考資料

- サブエージェント定義: `.claude/agents/*.md`
- Triage プロンプト: `local-watcher/bin/triage-prompt.tmpl`（配置先: `~/bin/triage-prompt.tmpl`）
- Watcher 実装: `local-watcher/bin/issue-watcher.sh`（配置先: `~/bin/issue-watcher.sh`）
- ワークフロー全体像・セットアップ手順: `README.md`
- パイプライン全体設計: Issue #13（フェーズ別実装: #14〜#18）
