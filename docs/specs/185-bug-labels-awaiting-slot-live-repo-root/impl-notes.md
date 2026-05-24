# 実装ノート: #185 awaiting-slot ラベルの live repo root 同期

## 概要

self-hosting 運用中の idd-claude 本体 repo で、Phase E Path Overlap Checker が付与する
`awaiting-slot` ラベルが root の labels スクリプトに存在せず、live repo でラベル作成
スクリプトを実行しても delay 状態が可視化されなかった双方向ドリフトを解消する。本 spec の
スコープは (1) root への additive 追加と root/template の name|color parity 回復、
(2) install.sh 経由の冪等伝播の確認・明文化の 2 点。watcher フォールバック堅牢化（観点 3）は
#187 に分離済みでスコープ外。

## 実装した変更（ファイルごと）

### 1. `.github/scripts/idd-claude-labels.sh`（fix(labels) c9c5316）

- `LABELS=( ... )` 配列に `awaiting-slot|c5def5|【Issue 用】 hot file 競合予防で同サイクル
  dispatch を見送り中（Phase E Path Overlap Checker が付与・除去）` を **additive** に追加。
- 配置位置は template と揃え `st-failed` と `blocked` の間に挿入。
- description は template の定義（既に #54 由来の `【Issue 用】` prefix を持つ）をそのまま流用。
- **root の既存ラベル行は一切変更していない**（name / color / description とも不変。#54 regression 防止）。

### 2. `docs/specs/185-.../check-label-parity.sh`（test(labels) 2d02082）

- root と template の labels スクリプトから `"<name>|<6 桁 hex color>|` ペアを抽出して
  sort + diff し、差分があれば非ゼロ exit + stderr に diff、一致すれば exit 0 を返す
  standalone スクリプト。
- #131 の `test-count.sh` パターンに倣い `docs/specs/<番号>-<slug>/` 配下に配置。
- **このスクリプトは手動 / 将来の CI 化用の fixture であり、現時点ではどの自動導線
  （install.sh / watcher / GitHub Actions）からも自動実行されない**（冒頭コメントに明記）。
  consumer repo へ配布されないよう `.github/scripts` ではなく docs/specs 配下に置いた。

### 3. `install.sh`（docs(install) 1f6cf3e）

- `setup_repo_labels "$REPO_PATH"` 呼び出し箇所に、再 install 時に最新の
  `idd-claude-labels.sh` が再配置され全 LABELS ループで未存在ラベルだけ新規作成される旨の
  説明コメントを追加（**挙動変更なし・コメントのみ**）。

### 4. `README.md`（docs(install) 1f6cf3e）

- 「GitHub ラベルの自動セットアップ (#85)」節に「新ラベルの再 install 伝播 (#185)」の bullet を
  追加。既存ラベルは skip され冪等性を維持する旨も明記。
- なお `awaiting-slot` は README のラベル一覧表（line 462 付近）・手動 `gh label create` 例
  （line 481 付近）・ラベル付与者一覧（line 900 付近）に既に記載済みだったため、追加記載は不要。

## 追加ラベル定義（name / color / 初期挙動）

| name | color | description | 初期挙動 |
|---|---|---|---|
| `awaiting-slot` | `c5def5` | 【Issue 用】 hot file 競合予防で同サイクル dispatch を見送り中（Phase E Path Overlap Checker が付与・除去） | root スクリプト実行時に未存在なら新規作成。既存なら skip（`--force` 時のみ更新）。Phase E Path Overlap Checker が付与・自動除去 |

## install.sh 伝播導線の確認結果（Req 2）

実態調査の結果、伝播導線は **既に main で完備されており不足は無い**（Req 2.4 の補強は不要）:

- `install.sh:1142-1145` の `copy_template_file` が **template の** `idd-claude-labels.sh`
  （`$REPO_TEMPLATE_DIR/.github/scripts/idd-claude-labels.sh`）を対象 repo へコピーする。
  template は既に `awaiting-slot` を持つため、**consumer repo は再 install するだけで
  `awaiting-slot` を取得できる**（本 spec 以前から成立）。
- `install.sh:1196` の `setup_repo_labels "$REPO_PATH"` が配置済みスクリプトを `--repo` 付きで
  起動し、`idd-claude-labels.sh` の `for spec in "${LABELS[@]}"` ループが未存在ラベルのみ
  `gh label create`、既存ラベルは skip する（`--force` なし）。これにより冪等伝播が成立（Req 2.1 / 2.2 / NFR 1.1）。
- 本 spec の root スクリプトへの `awaiting-slot` 追加は、**idd-claude 本体（self-hosting）の
  live repo** で root スクリプトを直接実行した場合に `awaiting-slot` が作成されるようにする
  ためのもの（root スクリプトは dogfooding 用の self コピー）。

## 解釈・判断メモ

- requirements.md のみ存在し design.md / tasks.md は無い（PM フェーズのみで Architect 未起動の
  小規模 bug fix）。タスク順序はオーケストレーター指示の番号順で消化。
- **NFR 2 / Open Question の判断**: parity 検証自動化手段は「standalone スクリプト追加 /
  CI チェック追加 / 手動確認手順の文書化」の選択肢が委ねられていた。オーケストレーター判断に
  従い **軽量な standalone parity スクリプトを docs/specs 配下に追加**する方針を採用（CI workflow は
  automation surface を増やさないため追加しない）。スクリプトは手動 / 将来の CI 化用 fixture。
- **root CLAUDE.md に `## Feature Flag Protocol` 節は無い** → opt-out として解釈し、通常フローで実装。
- `local-watcher/` および `repo-template/**` は本 spec のスコープ外につき一切編集していない。

## Test plan（実行コマンドと結果）

| 検証 | コマンド | 結果 |
|---|---|---|
| name\|color parity diff | `diff <(grep -oE '"[a-z-]+\|[0-9a-f]{6}\|' .github/scripts/idd-claude-labels.sh \| sort) <(grep -oE '"[a-z-]+\|[0-9a-f]{6}\|' repo-template/.github/scripts/idd-claude-labels.sh \| sort)` | 差分ゼロ・exit 0（PARITY OK） |
| labels スクリプト構文 | `bash -n .github/scripts/idd-claude-labels.sh` | syntax OK |
| awaiting-slot 出現回数 | `grep -c '^  "awaiting-slot\|c5def5\|' .github/scripts/idd-claude-labels.sh` | 1（重複なし） |
| shellcheck（labels + install） | `shellcheck .github/scripts/idd-claude-labels.sh install.sh` | exit 0（警告ゼロ） |
| parity スクリプト happy path | `bash docs/specs/185-.../check-label-parity.sh` | exit 0（parity OK） |
| parity スクリプト drift path | temp tree（root から awaiting-slot 除去）で実行 | exit 1 + stderr に diff 出力（期待どおり失敗検知） |
| parity スクリプト shellcheck | `shellcheck docs/specs/185-.../check-label-parity.sh` | exit 0（警告ゼロ） |
| install.sh 構文 | `bash -n install.sh` | syntax OK |
| install.sh dry-run スモーク | `bash install.sh --repo /tmp/scratch --dry-run` | labels 配置 + `would run: bash .../idd-claude-labels.sh --repo owner/scratch` を表示・exit 0 |
| install.sh opt-out 維持 | `bash install.sh --repo /tmp/scratch --dry-run --no-labels` | `SKIP [labels] opt-out (--no-labels / IDD_CLAUDE_SKIP_LABELS)` を出力（Req 3.3 / 3.5 不変） |

actionlint は workflow YAML を変更していないため不要。labels スクリプトは live repo を変更
しないよう直接実行はせず、`bash -n` + parity diff + dry-run スモークで検証した。

## 受入基準カバレッジ（requirement ID → 担保手段）

| AC | 担保手段 |
|---|---|
| 1.1（root スクリプトが awaiting-slot 作成を試みる） | root LABELS 配列への additive 追加（c9c5316）。awaiting-slot 出現回数 grep = 1 / dry-run スモークで `would run` 確認 |
| 1.2（root/template の name+color parity） | parity diff コマンド = 差分ゼロ / `check-label-parity.sh` happy path exit 0 |
| 1.3（additive のみ・既存ラベル不変） | `git diff main..HEAD -- .github/scripts/idd-claude-labels.sh` が 1 行追加のみ。既存行に変更なし |
| 1.4（#54 prefix を温存・template 側 prefix 無しに合わせない） | root 既存ラベル行を一切変更していない。追加行も #54 prefix 付き description を採用 |
| 1.5（parity は name+color 集合一致のみ判定・description 完全一致を要求しない） | `check-label-parity.sh` は `"<name>\|<color>\|` のみ抽出し description を比較対象外とする |
| 2.1（再実行で未存在ラベルを作成） | install.sh の copy_template_file → setup_repo_labels → LABELS ループ導線確認。dry-run スモークで `would run` 確認 |
| 2.2（既存ラベル skip・冪等） | `idd-claude-labels.sh` の `--force` なしパスが「already exists (skipped)」分岐。NFR 1 と同じ |
| 2.3（伝播導線を README / install.sh コメントで明文化） | README「新ラベルの再 install 伝播 (#185)」bullet 追加 + install.sh コメント追加（1f6cf3e） |
| 2.4（不足があれば補強） | 実態調査で導線は完備と確認。不足なしのため明文化のみ（Option A） |
| 2.5（削除・改名・color 変更をしない） | install.sh は `--force` なしで起動（既存値保護）。本変更は additive のみ |
| 3.1（既存ラベルの name/color 不変） | additive 追加のみ。parity diff で既存ペアに差分なし |
| 3.2（--repo / --force の意味不変） | labels スクリプトの引数処理を変更していない |
| 3.3（--no-labels / IDD_CLAUDE_SKIP_LABELS opt-out 不変） | dry-run --no-labels スモークで SKIP 出力を確認 |
| 3.4（REPO 等 env var 名と exit code 意味不変） | install.sh / labels スクリプトの env var・exit code を変更していない |
| 3.5（opt-out 時はラベル作成せず導入前と同一挙動） | dry-run --no-labels スモークで label 処理 skip を確認 |
| NFR 1（2 回連続実行で 0 件作成・同一状態） | labels スクリプトの既存ラベル skip 分岐（`--force` なし）で担保。冪等性は導線で確認 |
| NFR 2.1（parity 検証手段が差分を検出し非ゼロ件で失敗報告） | `check-label-parity.sh` drift path で exit 1 + stderr diff を確認 |
| NFR 2.2（自動化要否を Open Questions に委ねる旨明示） | requirements.md の Open Questions に明示済み。本実装で standalone スクリプト採用を選択し本ノートに判断を記録 |
| NFR 3（挙動変更時に README を同一変更内で更新） | README の自動セットアップ節を同一変更（1f6cf3e）で更新 |

## 確認事項

なし。

- requirements.md と実装の間に矛盾は検出されなかった。
- design.md / tasks.md は存在せず（小規模 bug fix のため PM フェーズのみ）、書き換え対象は無い。
- スコープ境界（`local-watcher/` 不編集・`repo-template/**` 不編集）を遵守した。

STATUS: complete
