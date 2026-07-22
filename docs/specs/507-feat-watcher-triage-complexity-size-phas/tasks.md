# Implementation Plan

- [x] 1. size ラベル 3 種を labels script 2 系統へ additive parity で追加する (P)
  - `.github/scripts/idd-claude-labels.sh` の `LABELS=()` 配列末尾に `size:small` / `size:medium` /
    `size:large` の 3 行を追加する（`name|color|description` 形式 / design.md「`size:*` ラベル定義案」表）
  - color は 6 桁小文字 hex（`c2e0c6` / `fef2c0` / `f7c6c7`）、description は `【Issue 用】` prefix +
    100 文字以内とする
  - `repo-template/.github/scripts/idd-claude-labels.sh` へ **同一文字列・同一相対位置（配列末尾）**で
    同じ 3 行を追加する（additive parity）。root と repo-template は **着手時点で既に byte 一致して
    いない**（#54 由来のドリフト）ため、whole-file 一致を目指してはならない
  - repo-template 側では周辺の旧エントリに `【Issue 用】` prefix が無いが、**parity 優先**で
    prefix ありのまま追加する（root と同一文字列にすることを最優先する）
  - 既存行（両系統とも）の name / color / description を 1 文字も変更しない。#54 由来の既存差分は
    本 Issue では是正しない（別 Issue の領分）
  - 検証（同 task 内）: 両系統から `size:` エントリ行のみを抽出して比較し、同一の 3 行になることを
    確認する（`diff <(grep -E '^[[:space:]]*"size:(small|medium|large)\|' A) <(... B)`）。
    加えて `shellcheck .github/scripts/idd-claude-labels.sh` が警告ゼロであること、`git diff` で
    既存行への差分がゼロ行であることを確認する
  - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5, 7.1, 7.2_
  - _Boundary: LabelProvisioner_

- [x] 2. Triage prompt に `complexity` / `complexity_reason` を additive 追加する (P)
  - `local-watcher/bin/triage-prompt.tmpl` の出力 JSON スキーマ例に、`edit_paths` の**後ろ**へ
    `complexity`（`small` / `medium` / `large` の 1 値）と `complexity_reason`（1〜2 行）を追加する
  - 新規節「`## complexity の出力指示（モデルルーティング Phase 1）`」を末尾に追加し、
    3 段階の判定基準・`needs_architect: true` は `large` 固定・境界時は大きい側へ倒す旨を明記する
  - 既存 6 keys（`status` / `needs_architect` / `architect_reason` / `rationale` / `decisions` /
    `edit_paths`）の位置・型・意味、および既存の `needs_architect` 判定基準節には一切手を入れない
  - `complexity` は watcher 側の gate に依らず常時出力する旨をテンプレートに明記する
  - 追加は指示文のみとし、追加の tool 実行・ファイル書き込み経路を増やさない（turn 上限 15 を超過させない）
  - 検証（同 task 内）: 変更後テンプレートの JSON 例を `jq .` に通してパース可能なことを確認し、
    既存 6 keys 部分の `git diff` がゼロ行であることを確認する
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 2.1, 2.2, 3.5, NFR 3.3, NFR 3.4_
  - _Boundary: TriagePromptTemplate_

- [x] 3. `modules/model-router.sh` を新設し近接テストを追加する
  - `local-watcher/bin/modules/model-router.sh` を新規作成する（ファイル冒頭コメントに用途 / 配置先 /
    依存 / 設計参照 / prefix `mr_` を明記。**関数定義のみ・トップレベル副作用なし**）
  - `mr_log` / `mr_warn` を定義する（`[ts] [$REPO] model-router:` の 3 段 prefix / WARN は `>&2`）
  - `mr_is_enabled` を定義する（`"${MODEL_ROUTING_ENABLED:-false}"` が `true` に厳密一致するときのみ rc=0）
  - `mr_parse_triage_complexity <triage_json_path>` を定義する（純粋関数 / stdout は正規化値または空文字 /
    rc=0 always。key 不在・`null`・非文字列・許可値外・jq 失敗・ファイル不在をすべて空文字へ倒す）
  - `mr_has_size_label <labels_json> [<prefix>]` を定義する（rc 0=既存あり / 1=なし / 2=判定不能。
    `jq --arg` で prefix を束縛し、フィルタ文字列へ未信頼値を inline 展開しない）
  - `mr_persist_size_label <issue_number> <complexity>` を定義する（design.md「戻り値契約」表の rc 0〜5 /
    gate 二重防御 / 許可値の `case` 厳密一致を **ラベル名構成の直前**に実施 / `gh` へは
    `--add-label -- "size:${complexity}"` と `--` でオプション解釈を打ち切り / 全分岐でログ 1 行）
  - 正常経路の `gh` 呼び出しは labels 取得 1 回 + 付与 1 回の計 2 回以下、gate 無効時は 0 回に抑える
  - `local-watcher/test/model_router_test.sh` を新規作成する（`lib/test-helpers.sh` を source し、
    `extract_function` で対象関数を隔離抽出 → `gh` を stub して呼び出しトレースを観測する既存イディオム）
  - テストは design.md「Testing Strategy」の Unit 1〜6 と Integration I1〜I7 を実装する
    （許可値 3 種の正常付与 / `complexity` 欠落 / 不正値 / 既存 `size:*` あり / gate 無効の 5 ケースを必ず含む）
  - _Requirements: 2.3, 2.4, 3.1, 3.2, 3.3, 3.4, 4.1, 4.2, 4.3, 4.4, 4.7, 5.1, 5.2, 5.3, 5.4, 5.5, 5.6, 8.3, 8.4, NFR 2.1, NFR 2.2, NFR 3.1, NFR 3.2, NFR 4.1, NFR 4.2, NFR 4.3_
  - _Boundary: ModelRouterModule, ModelRouterTest_

- [x] 4. gate 変数の宣言と module ローダ登録を行う
  - `local-watcher/bin/watcher-config.sh` の Phase E gate 群（`PATH_OVERLAP_CHECK` 付近）の直後に
    `MODEL_ROUTING_ENABLED="${MODEL_ROUTING_ENABLED:-false}"` を宣言し、opt-in / 既定無効 /
    `true` 厳密一致・不正値は安全側という意図をコメントで明記する
  - 当該変数を #112 の「デフォルト有効化フラグの値正規化」ループに **含めない**（新規 opt-in のため）
  - Phase 1 / Phase 2 共通の単一 gate であり Phase 別 gate を設けない旨をコメントに残す
  - `local-watcher/bin/issue-watcher.sh` の `REQUIRED_MODULES` 配列へ `"model-router.sh"` を
    `"path-overlap.sh"` の直後に追加する
  - 既存 env var 名 / ラベル名 / cron 登録文字列 / ログ出力先を変更しない
  - 検証（同 task 内）: `model_router_test.sh` に wiring アサーション 2 件（`REQUIRED_MODULES` への登録 /
    `watcher-config.sh` の既定値宣言）を grep ベースで追加する
  - _Requirements: 3.1, 3.3, 3.6, NFR 1.2, NFR 1.3_
  - _Boundary: WatcherConfig, ModuleLoader_
  - _Depends: 3_

- [x] 5. slot-worker.sh の Triage 消費部に call site を配線する
  - `local-watcher/bin/modules/slot-worker.sh` の Phase E edit_paths 永続化ブロック（L498-511）の
    **直後**、`needs-decisions` 分岐（L513）より前に、design.md「Wiring」節の擬似構造どおりの
    gate ブロックを 1 つ挿入する
  - ブロック内は `mr_is_enabled` → `mr_parse_triage_complexity` → `mr_persist_size_label` の 3 呼び出しに
    限定し、戻り値を吸収して後続へ伝播させない（Triage の成功／失敗判定を変えない）
  - `$STATUS` / `$NEEDS_ARCHITECT` / `$MODE` を読み書きせず、mode 判定・needs-decisions 経路を変更しない
  - `skip-triage` / `impl-resume` 経路は Triage ブロックごと迂回されるため、追加のラベル判定を書かない
    （call site の位置で非付与を構造的に保証する）
  - 検証（同 task 内）: `model_router_test.sh` に wiring アサーションを追加する
    （gate ブロックが Phase E ブロックより後に存在すること / gate 外に `mr_persist_size_label` 呼び出しが
    無いこと / `skip-triage` 分岐側に呼び出しが無いこと）
  - _Requirements: 2.5, 3.4, 4.5, 4.6, 8.4, NFR 1.1, NFR 2.3_
  - _Boundary: SlotWorkerTriageConsumer, ModelRouterTest_
  - _Depends: 3, 4_

- [ ] 6. README / CLAUDE.md を同一 PR で更新する (P)
  - `README.md`「ディレクトリ構成」ツリーの modules 一覧に `model-router.sh` 行を追加する
  - `README.md`「オプション機能（標準有効 / 常時有効）一覧」の **opt-in（既定 OFF）** 表に
    `MODEL_ROUTING_ENABLED` 行（既定 `false` / `=true` 厳密一致のみ有効 / それ以外は安全側 OFF /
    無効時は完全 no-op）を追加する
  - `README.md` に新規節「Model Routing Phase 1: Triage complexity → size ラベル (#507)」を追加し、
    `size:small` / `size:medium` / `size:large` の意味、既存ラベル優先の人間 override 運用、
    誤付与時の訂正手順（ラベルを剥がす → 次回 Triage で再付与）、`idd-claude-labels.sh` 再実行手順、
    migration note（未設定環境は導入前と完全同一）を記述する
  - `CLAUDE.md` 機能追加ガイドライン §2 の prefix 表に `mr_` 行（model-router / #507）を追加する
  - 検証（同 task 内）: 追加した節・表行から参照する env var 名・ラベル名・module 名が実装と一致することを
    `grep` で突き合わせる（README / CLAUDE.md は byte 一致同期対象外のため repo-template への反映は行わない）
  - _Requirements: 7.3, 7.4, 7.5, 7.6, 7.7_
  - _Boundary: OperatorDocs_

- [ ] 7. 最終検証（静的解析 / 近接テスト / parity 抽出比較 / 手動スモーク手順）
  - `shellcheck` を変更した全 bash スクリプト（新規 module / slot-worker / watcher-config /
    issue-watcher / labels script）に対して実行し警告ゼロを確認する
  - `bash -n` を新規 module と変更した既存スクリプトに対して実行する
  - `bash local-watcher/test/model_router_test.sh` が全ケース PASS することを確認する
  - labels script の parity を **`size:` エントリ行の抽出比較**で確認する（whole-file diff は
    使わない。#54 由来の既存ドリフトにより正しい実装でも必ず非 0 exit になるため）
  - byte 一致同期対象である `.claude/agents` / `.claude/rules` の 2 系統について
    `diff -r` が空であることを確認する
  - 手動スモーク手順を `impl-notes.md` に記録する: gate 有効かつ `size:*` 未作成の repo で
    「ラベル付与失敗 → WARN 1 行 → Triage 継続」となること、gate 未設定環境で本機能由来のログ・
    API 呼び出しがゼロであること
  - _Requirements: 8.1, 8.2, 8.5, 8.6, NFR 1.1_
  - _Depends: 1, 2, 3, 4, 5, 6_

## Verify

本 spec の実装後、watcher（stage-a-verify gate）が再実行すべき verify コマンドを構造化ブロックで
宣言する。新規 bash module + 本体配線 + labels script の additive parity のため、静的解析 + 近接
テスト + parity 抽出比較 + byte 一致同期 diff を対象に含める。

labels script は **whole-file diff を含めない**（root ↔ repo-template は #54 由来のドリフトにより
着手前から不一致で、whole-file 比較は正しい実装でも必ず非 0 exit を返し Stage A を false-fail
させるため / `tasks-generation.md`「パス存在前提」節と同根の #364 事故類型）。代わりに Req 8.5 の
`size:` エントリ行の抽出比較を用いる。プロセス置換 `<(...)` は stage-a-verify が
`bash -c "cd \"$REPO_DIR\" && <cmd>"`（`local-watcher/bin/modules/stage-a-verify.sh:989`）で実行する
ため利用可能（`sh` ではなく `bash` で評価される）。`repo-template/local-watcher/` は構造的に存在
しないため diff 対象に含めない。

<!-- stage-a-verify -->
```sh
shellcheck local-watcher/bin/modules/model-router.sh local-watcher/bin/modules/slot-worker.sh local-watcher/bin/watcher-config.sh local-watcher/bin/issue-watcher.sh .github/scripts/idd-claude-labels.sh && \
  bash -n local-watcher/bin/modules/model-router.sh && \
  bash local-watcher/test/model_router_test.sh && \
  diff <(grep -E '^[[:space:]]*"size:(small|medium|large)\|' .github/scripts/idd-claude-labels.sh) <(grep -E '^[[:space:]]*"size:(small|medium|large)\|' repo-template/.github/scripts/idd-claude-labels.sh) && \
  diff -r .claude/agents repo-template/.claude/agents && \
  diff -r .claude/rules repo-template/.claude/rules
```
