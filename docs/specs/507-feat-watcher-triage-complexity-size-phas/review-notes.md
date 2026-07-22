# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4-8 timestamp=2026-07-22T09:08:01Z -->

## Reviewed Scope

- Branch: claude/issue-507-impl-feat-watcher-triage-complexity-size-phas
- HEAD commit: 71a7a5c9e572ddacebdfe563d0e383bffb037b86
- Compared to: main..HEAD

変更ファイル 12 件（labels script 2 系統 / triage-prompt.tmpl / model-router.sh 新規 /
model_router_test.sh 新規 / watcher-config.sh / issue-watcher.sh / slot-worker.sh /
README.md / CLAUDE.md / spec 配下 tasks.md checkbox + impl-notes.md）。

Reviewer 自身で `tasks.md` の `## Verify` 構造化ブロック全体を再実行し、
`shellcheck`（5 ファイル + テスト本体）警告ゼロ / `bash -n` OK /
`model_router_test.sh` **PASS: 146, FAIL: 0** / labels parity 抽出比較 rc=0 /
`diff -r .claude/agents` `diff -r .claude/rules` 差分なし を確認済み。
`module_loader_missing_test.sh`（7 件）も PASS を確認。

## Verified Requirements

### Requirement 1（Triage による Issue サイズ判定 / TriagePromptTemplate）

- 1.1 — `triage-prompt.tmpl` JSON 例に `"complexity": "small" | "medium" | "large"` を追加、新設節「complexity の出力指示」で 1 値出力を指示
- 1.2 — 同 JSON 例に `complexity_reason`（1〜2 行の根拠）を追加、節本文でも明記
- 1.3 — 判定基準「`small` — 単一〜少数ファイルの軽微な変更（既存関数内のロジック改善 / 文言変更 / テスト・ドキュメント追加のみ）」
- 1.4 — 判定基準「`medium` — 数ファイルにまたがるが設計判断が自明（新規ヘルパー追加程度）」
- 1.5 — 判定基準「`large` — 複数モジュール横断 / 新規外部連携 / 永続構造・スキーマ変更のいずれか」
- 1.6 — 固定ルール「`needs_architect` を `true` と判定した Issue は必ず `large`」
- 1.7 — 固定ルール「境界で確信を持てない場合はより大きい側」（迷いの具体例付き）
- 1.8 — 固定ルール「`complexity` は変更規模の観点のみで判定し `needs_architect` の判定基準・値・意味は変更しない」。既存 `needs_architect` 判定基準節への差分は 0 行（`git diff` で確認）

### Requirement 2（additive 拡張と後方互換）

- 2.1 — 既存 6 keys のキー行への差分 0 行。変更は `edit_paths` 閉じ括弧の `]`→`],`（末尾追加に伴う JSON 構文上の必然）のみで位置・型・意味は不変
- 2.2 — 追加は `complexity` / `complexity_reason` の 2 keys のみ（diff で確認）
- 2.3 — `mr_parse_triage_complexity` が key 不在時に空文字を返す（Unit 2「complexity key 欠落（旧テンプレート由来）は空文字」）
- 2.4 — 不正 JSON / ファイル不在 / 空ファイルでも rc=0 + 空文字（Unit 4）。call site は `|| true` で rc 吸収（W9）
- 2.5 — call site が `$STATUS` / `$NEEDS_ARCHITECT` / `$MODE` を読み書きしないことを W8 が gate ブロック抽出 + grep で検証

### Requirement 3（opt-in gate と既定無効）

- 3.1 — `watcher-config.sh:MODEL_ROUTING_ENABLED="${MODEL_ROUTING_ENABLED:-false}"`（W2 が宣言行リテラル一致で検証）+ Unit 5「未設定は rc=1」
- 3.2 — `mr_is_enabled` は `= "true"` 厳密一致（Unit 5 / I1 の正常付与経路）
- 3.3 — Unit 5 が `""` / `false` / `off` / `True` / `TRUE` / `1` / `0` / `ture` / `yes` / `enabled` の 10 種で rc=1 を検証。W3 が #112 の既定 true 正規化ループ非混入を検証
- 3.4 — I5（gate 未設定 / 不正値 5 種で gh 0 回・ログ 0 行・rc=1）+ W6（`mr_persist_size_label` 呼び出しが gate 内 1 箇所のみ）
- 3.5 — `triage-prompt.tmpl` に「`complexity` / `complexity_reason` は watcher 側の設定（gate）に依らず常時出力すること」を明記
- 3.6 — W4 が `MODEL_ROUTING_*` の追加 gate 宣言 0 件であることを config + module 横断 grep で検証

### Requirement 4（size ラベルによる永続化）

- 4.1 — I1 が許可値 3 種それぞれで rc=0 / `gh issue edit` 1 回 / pflag 規則で解決した `--add-label` 値が `size:<c>` であることを検証
- 4.2 — I4（既存 `size:large` あり → rc=3 / add-label 0 回）+ Unit 6
- 4.3 — I4「人間 override の `size:small` が優先され rc=3」（Triage 由来と区別しない）
- 4.4 — I4「人間 override 時も add-label 0 回（重複・併存を生じさせない）」
- 4.5 — call site が `skip-triage` 分岐の `else` 枝内（Triage 実行経路）に配置。W7 が行番号順序で構造的非付与を検証
- 4.6 — 同上、`HAS_EXISTING_SPEC`（impl-resume）分岐より後 = `else` 枝内（W7）
- 4.7 — `mr_persist_size_label` rc=3 分岐の skip ログ（既存 size:* あり / 先在ラベル優先の理由を明示）。I4 が "skip" 文字列と Issue 番号を検証

### Requirement 5（fail-safe / fail-open）

- 5.1 — I2（空文字・第 2 引数省略で rc=2 / gh 0 回 / WARN 1 行）+ Unit 2
- 5.2 — `mr_persist_size_label` 冒頭のラベル名構成前 `case small|medium|large` 厳密一致。I3 が 6 種の不正値で rc=2 / gh 0 回を検証
- 5.3 — I6「add-label 失敗は rc=5（fail-open）」+ WARN にラベル名・Issue 番号、call site は `|| true`
- 5.4 — I6（labels 取得失敗 rc=4 / JSON 解析不能 rc=4、いずれも add-label 0 回）+ Unit 6 rc=2
- 5.5 — module に `--remove-label` の実行行が 0 件（コメント行除外の grep アサーション）。`--add-label` のみ使用でラベル遷移契約に非干渉
- 5.6 — 全 rc 分岐（0/2/3/4/5）でログ 1 行を出力。I2 / I3 / I6 が「WARN 1 行」を `wc -l` で検証

### Requirement 6 / 7（ラベル定義プロビジョニングと二重管理・ドキュメント）

- 6.1 — `.github/scripts/idd-claude-labels.sh` の `LABELS=()` 末尾に `size:small` / `size:medium` / `size:large` の 3 行
- 6.2 — 両系統とも `git diff` は追加 3 行 / 削除 0 行（既存 name / color / description への差分なし）
- 6.3 — 既存の冪等ロジック（`EXISTING_LABELS` 連想配列による存在チェック → skip、`--force` 時のみ更新）に乗るのみで変更なし
- 6.4 — description は `【Issue 用】` prefix 付き、実測 44 / 44 / 50 文字（100 文字以内）
- 6.5 — color は 6 桁小文字 hex（`c2e0c6` / `fef2c0` / `f7c6c7`）で既存表記と同規約
- 7.1 — root と repo-template の追加 3 行が同一文字列・同一相対位置（配列末尾）。`size:` 行抽出 diff が rc=0
- 7.2 — 追加 3 行以外の既存行差分（#54 由来ドリフト）は両系統とも未変更
- 7.3 — README「オプション機能一覧」opt-in 表に `MODEL_ROUTING_ENABLED` 行（既定 `false` / `=true` 厳密一致 / それ以外は安全側 OFF / gate OFF 時 API 0 回・ログ 0 行）
- 7.4 — README 新規節に size ラベル 3 種の意味表、人間 override（先在ラベル優先）、誤付与時の訂正手順（剥がす → 次回 Triage で再付与）
- 7.5 — README「ディレクトリ構成」ツリーに `model-router.sh` 行
- 7.6 — CLAUDE.md 機能追加ガイドライン §2 prefix 表に `mr_` 行
- 7.7 — 上記 README / CLAUDE.md 更新は同一ブランチ・同一 PR 内（commit `e4f5f98`）

### Requirement 8（検証可能性）

- 8.1 — `shellcheck`（model-router / slot-worker / watcher-config / issue-watcher / labels script / テスト本体）警告ゼロを Reviewer が再実行して確認
- 8.2 — `bash -n local-watcher/bin/modules/model-router.sh` OK
- 8.3 — `local-watcher/test/model_router_test.sh` を既存命名規約で追加。`lib/test-helpers.sh` を source し `extract_function` + gh stub の既存イディオムを踏襲
- 8.4 — 5 ケース（許可値 3 種正常付与 I1 / 欠落 I2 / 不正値 I3 / 既存 `size:*` I4 / gate 無効 I5）をすべて実装
- 8.5 — `size:` 行抽出比較で両系統 3 行一致（Reviewer 再実行で rc=0）。whole-file diff は verify に含まれていない
- 8.6 — impl-notes.md「手動スモーク手順の記録」ケース A（gate 有効 + ラベル未作成 → rc=5 / WARN 1 行 / 継続）を実出力付きで記録

### Non-Functional Requirements

- NFR 1.1 — I5 が gate 無効時のログ 0 行 / gh 0 回 / rc=1 を検証（スモーク B と一致）
- NFR 1.2 — 既存 env var 名 / ラベル名 / cron 文字列 / ログ出力先に変更なし（追加は新規 env 1 件 + 新規ラベル 3 件のみ）
- NFR 1.3 — gate 既定 `false` により未設定 consumer 環境は導入前と同一外部挙動
- NFR 2.1 — `mr_log` に `#<issue>` と `complexity=<値>` を含む 1 行（I1 が両者を検証）
- NFR 2.2 — WARN に `[$REPO]` prefix（`mr_warn` 定義）・Issue 番号・理由を含む（I2 / I6）
- NFR 2.3 — `mr_log` / `mr_warn` は既存 `po_log` / `po_warn` と同一形式・同一出力先（slot stdout = cron ログ経路）
- NFR 3.1 — I7 が正常経路の gh 総数 2 回（view 1 + edit 1）を検証
- NFR 3.2 — I5 が gate 無効時の gh 0 回を検証
- NFR 3.3 — 追加は Triage prompt の指示文のみで追加 LLM 起動なし（diff で確認）
- NFR 3.4 — tool 実行経路を増やす記述なし（指示文のみ）。turn 上限 15 の変更なし
- NFR 4.1 — 未信頼値はラベル名構成直前に `case` 厳密一致。Unit 3 / I3 が注入狙い文字列（`small; rm -rf /` / `--add-label` / `large,claude-failed`）を弾くことを検証
- NFR 4.2 — `jq --arg` で prefix を束縛（フィルタ inline 展開なし）、`gh` へは全変数クォート + `--add-label=<値>` の `=` 束縛形で値をフラグへ構文的に束縛。I1 が解決後ラベル値と `positionals=1` を pflag 規則の stub で検証（補足は下記 Summary 参照）
- NFR 4.3 — `complexity_reason` は module 内に一切出現せず、ラベル名・コマンド引数の構成に不使用

## Findings

なし

## Summary

全 63 AC について実装またはテストによる担保を確認し、`tasks.md` の `_Boundary:_` を逸脱する変更
（宣言外コンポーネントへの変更）も検出しなかった。verify ブロックを Reviewer 側で再実行し
shellcheck 警告ゼロ / `model_router_test.sh` 146 PASS / parity・同期 diff 差分なしを確認済み。

補足（**当該 impl PR の reject 理由には含めない**設計レベルの指摘 / 別経路へ還流すべき事項）:

1. `gh issue edit` の `--add-label` 引数形式について、design.md:196・298・384 および tasks.md task 3 は
   `--add-label -- "size:${complexity}"` を指定しているが、実装は `--add-label="$label_name"` の
   `=` 束縛形を採用している（impl-notes.md 確認事項 1）。pflag は値を取るフラグの直後の引数を無条件に
   値として消費するため設計どおりの `--` 形では Req 4.1 が実機で必ず未達となる点が実機 `gh` 2.96.0 で
   裏取りされており、`=` 束縛形は NFR 4.2 の保護意図（未信頼値がフラグとして解釈されない）を等価に満たす。
   impl PR は現行確定 AC（4.1 と NFR 4.2 の双方）を満たしているため reject 事由とせず、design.md 記述の
   追随修正要否は設計 iteration / 別 Issue の判断に委ねる。
2. #54 由来の repo-template labels script ドリフトは requirements / design 双方で Out of Scope 宣言済みで
   あり、本 PR の判定対象外。
3. impl-notes.md 確認事項 4 の既存 flaky テスト（`publish_terminal_failure_artifacts_test.sh` 等）は
   分岐元でも再現する本変更と無関係の既存事象であり、本 PR の reject 事由としない（別 Issue 起票が推奨）。

RESULT: approve
