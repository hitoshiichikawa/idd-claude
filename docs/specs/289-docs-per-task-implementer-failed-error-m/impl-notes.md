# Implementation Notes (#289)

## 概要

per-task Implementer ループ運用で頻発する `per-task-implementer-failed` /
`error_max_turns` 失敗について、運用者が独力で原因切り分け・対応選択・復旧操作を完遂できる
ように、README / QUICK-HOWTO / tasks-generation.md（root + repo-template）を **ドキュメント
追加のみ**で整備した。watcher / agent 実装コードおよび既存 env / ラベル / 既定値の意味は
変更していない（Req 8.1〜8.5 / NFR 1.1）。

## 変更ファイル一覧

| ファイル | 種別 | 変更概要 |
|---|---|---|
| `repo-template/.claude/rules/tasks-generation.md` | 追記 | 「turn 予算ガイドライン（per-task Implementer ループ運用時の粒度指針）」節を新設（Req 6, 7） |
| `.claude/rules/tasks-generation.md` | 追記 | 上記と **byte 一致**で追記（CLAUDE.md「二重管理」節 / Req 8.5） |
| `README.md` | 追記 | (1) Per-task TDD Implementation Loop 節の env 表に `DEV_MAX_TURNS` を項目化（Req 5）、(2) ## トラブルシューティング 節に `### per-task-implementer-failed / error_max_turns 対応` サブ節を新設（Req 1, 2, 3, 4 / NFR 2, 3） |
| `QUICK-HOWTO.md` | 追記 | §6 トラブルシューティングに最頻出ケースの要約を追加し、README への双方向相互リンクを設置（Req 1.5 / NFR 2.2） |

## コミット一覧

- `docs(rules): tasks-generation に turn 予算ガイドラインを追記`
- `docs(readme): per-task-implementer-failed / error_max_turns の対応節を追加`
- `docs(quick-howto): per-task-implementer-failed の要約と README 相互リンクを追加`

## 主要判断（解釈の確定）

### `DEV_MAX_TURNS` env 項目の配置場所

要件 5.3 で「既存 `PR_ITERATION_MAX_TURNS` の記載と整合させる」とあるため、README 内の env
一覧表のいずれかに追加する必要がある。候補は以下:

- (A) PR Iteration Processor (#26) 節の env 表（line 2682 付近）
- (B) Reviewer Gate (#20 Phase 1) 節の env 表（line 3647 付近）
- (C) Per-task TDD Implementation Loop (#21) 節の env 表（line 4767 付近）

`DEV_MAX_TURNS` は **per-task Implementer の 1 タスクあたり turn 上限** として最も強く文脈を
持ち、また本 Issue が per-task ループ運用での失敗対応を主目的とすることから (C) を採用した。
(A) / (B) は別 processor / 別ゲートの env なので、`DEV_MAX_TURNS` を併記すると却って文脈が
混乱する。Open Question「配置先の選択」（requirements.md 末尾）と整合する判断。

### tasks-generation.md の数値（`DEV_MAX_TURNS=60`）の踏み込み度

Open Question「`DEV_MAX_TURNS`（既定 60）以内に収まる粒度」と数値を明示するか / 定性表現に
留めるかの選択について、本実装では **要件 7.1 の明示採用に従い数値を明示**した。理由:

- 運用者が「目安」を即座に判断できる方が、設計時に turn 予算を意識する誘因として効きやすい
- 既定値 60 自体は本 spec のスコープ外で変更しない（Req 5.5）ため、追従コストは最小限
- 将来 `DEV_MAX_TURNS` の既定が変わる場合は本節の数値を 1 箇所更新するだけで済む（root +
  repo-template の byte 一致で同期）

### Mechanical Check として宣言しない設計

要件 7.4 に従い、turn 予算ガイドラインは **推奨どまり**として、`design-review-gate.md` の
Mechanical Check（reject 条件）には宣言していない。理由は tasks-generation.md「強度（推奨
どまり / Mechanical Check 不在）」節に列挙したとおり、turn 消費量の事前見積もり困難性と
数値追従コストを踏まえた判断。

### 復旧手順のラベル操作順序

NFR 3.1 / 3.2 / Req 4.2 を踏まえ、impl PR が既に存在するケースでは
**`ready-for-review` を先に付与 → `claude-failed` を除去**の順序を必ず守る運用とした。
要件文では Req 4.3 で「破壊事象の概要と回避策を警告として記述」とあり、README の復旧手順
冒頭に blockquote 形式の警告ブロックを置いている。

### README の Troubleshooting 配置場所

要件 1.1 で「README から見つけたい」、NFR 2.1 で「目次から 2 ホップ以内」とあるため、
既存の `## トラブルシューティング` 節（line 5438）配下に `### per-task-implementer-failed
/ error_max_turns 対応` を新設した。既存 h2 配下に h3 を追加するだけで階層構造を維持し、
GitHub 自動目次から 1 ホップで到達できる。NFR 1.1 の既存セクション一意性も維持。

## 検証結果

### 二重管理規約の byte 一致確認

```
$ diff -r .claude/rules repo-template/.claude/rules
$ diff -r .claude/agents repo-template/.claude/agents
$ echo $?
0
```

両 diff とも空（byte 一致）。CLAUDE.md「二重管理」節および Req 8.5 を満たす。

### 数値整合性確認

- `local-watcher/bin/issue-watcher.sh:512` の `DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"` と
  本 PR 追記中の `既定 60` / `DEV_MAX_TURNS=60` が一致
- `Per-task TDD Implementation Loop` 節の既存ログ例 `max-turns=60` とも一致
- 既存 README 内 `DEV_MAX_TURNS` 参照 7 箇所はすべて既存記述で、本 PR では追加 1 箇所（env 表
  項目化）のみ。既存記述は改変していない

### 既存 env / ラベル / cron の変更なし確認

- `DEV_MAX_TURNS` / `PR_ITERATION_MAX_TURNS` / `REVIEWER_MAX_TURNS` / `DEV_MODEL` 等の env 名・
  既定値・意味は本 PR で **一切変更していない**（README env 表は項目追加のみ / Req 8.1）
- `claude-failed` / `per-task-implementer-failed` / `ready-for-review` の **付与契約 / 遷移
  意味は変更していない**（Troubleshooting 節での説明追加のみ / Req 8.2）
- watcher / agent 実装コード（`local-watcher/bin/issue-watcher.sh` / `.claude/agents/*.md`）は
  本 PR で一切編集していない（Req 8.3）
- 既存 `tasks-generation.md` の checkbox 必須化 / Budget overflow check / 構造化 verify ブロック
  規約は **削除・改変なし**、新節を末尾に追記したのみ（Req 8.4）

### 内部リンク（相対パス）の妥当性

- README → `./repo-template/.claude/rules/tasks-generation.md`（既存パス、ファイル実在）
- QUICK-HOWTO → `./README.md#per-task-implementer-failed--error_max_turns-対応`（README 内に
  対応する `### per-task-implementer-failed / error_max_turns 対応` 見出し追加済み。GitHub の
  自動 anchor 生成規則: バッククォート除去 / 半角スペース → `-` / 連続 `-` 保持 で
  `per-task-implementer-failed--error_max_turns-対応` となる）
- tasks-generation.md → README の Troubleshooting 節への参照は名称参照のみで、ハードな相対
  リンクは含めていない（rules は repo-template として配布されるため、配布先 repo に README が
  常に存在するとは限らないことを考慮）

### 言語方針の準拠

- 本文は **日本語ベース**（CLAUDE.md「言語方針」）
- env 名 / ラベル名 / コマンド名 / フェンスドコードブロック内の bash コマンドは **英語固定**
- EARS トリガーキーワード（`When` / `If` / `While` / `Where` / `shall`）は本 PR 範囲では未使用
  （Troubleshooting 節は自然文記述 / 要件記述ではないため）

### 絵文字の使用

- README の Troubleshooting 節で警告に `⚠️` を 1 箇所使用（NFR 3.2「順序を誤った場合のリスクを
  警告ブロック…で…視覚的に区別」要件への対応）。CLAUDE.md「ステータス表示に限定」方針に
  合致する範囲
- それ以外（QUICK-HOWTO / tasks-generation.md）では新規絵文字を追加していない

### 既存 git history の温存

- 既存 commit を破壊する操作（`git reset` / `git rebase` / `--force`）は一切実施せず
- 既存 main 上の `tasks-generation.md` / README / QUICK-HOWTO の既存記述は **追記のみ**で改変なし

## AC とテスト対応の対応表

本 spec はドキュメント変更のみで、実行可能な test runner による検証対象は持たない（NFR 1.1）。
代わりに各 AC に対する成果物の所在を以下に列挙する:

| AC | 検証根拠（成果物の所在） |
|---|---|
| 1.1 | README L5476 `### per-task-implementer-failed / error_max_turns 対応` 見出し（`per-task-implementer-failed` / `error_max_turns` を見出しに含む）|
| 1.2 | README L5482〜L5618 に「症状」「原因」「診断手順」「対応の優先順位」「ラベルの意味と次アクション」「復旧手順」の 6 観点を記載（5 観点を超える） |
| 1.3 | README L5493〜L5497 で「`error_max_turns` は許容 turn 上限到達で exit した状態であり必ずしも実テスト失敗を意味しない」旨を明示 |
| 1.4 | README L5567〜L5573 ラベル意味表に `claude-failed` / `per-task-implementer-failed` / `ready-for-review` を列挙し、次アクションを併記 |
| 1.5 | QUICK-HOWTO L269〜L290 に最頻出ケース要約と README 相互リンク（双方向リンク完成） |
| 2.1 | README L5511〜L5517 診断表に「ログ上の文字列・終了理由・ラベル遷移」観点で 529 過負荷と区別 |
| 2.2 | 上記表に「テストフレームワークの fail 出力」「`RESULT: reject`」観点で実テスト失敗との区別 |
| 2.3 | 上記表で 529 過負荷シグナル時の対応として「再 pickup で回復し得る」旨を記載 |
| 2.4 | 上記表で実テスト失敗時に手動仕上げ or Reviewer / Debugger 経路を案内 |
| 2.5 | README L5519〜L5520 で「error_max_turns に該当する場合は対応の優先順位節を参照」と接続 |
| 3.1 | README L5523〜L5562 に「(1) タスク粒度の是正 → (2) `DEV_MAX_TURNS` 一時引き上げ → (3) 手動仕上げ」を 3 段階で明示 |
| 3.2 | README L5527〜L5532 で親タスク細分化 + 「UI = 1 component + 1 test = 1 task」分割指針を記載 |
| 3.3 | README L5536〜L5547 で `DEV_MAX_TURNS` 引き上げを「一時的・その場限り」と明示、cron 恒久書き換えを非推奨と記載 |
| 3.4 | README L5551〜L5556 で手動仕上げを最終手段とし、「同一タスクで `per-task-implementer-failed` が 2 回連続観測」「`DEV_MAX_TURNS` を 1.5〜2 倍にしても通過しない」を判断基準として記載 |
| 3.5 | README L5559〜L5565 表で各優先順位の後続挙動への影響を運用者目線で記載 |
| 4.1 | README L5582〜L5594 「A. impl PR がまだ存在しないケース」で `claude-failed` 除去手順を記載 |
| 4.2 | README L5596〜L5611 「B. impl PR が既に存在するケース」で `ready-for-review` 先付与 → `claude-failed` 後除去の順序を明示 |
| 4.3 | README L5577〜L5580 警告 blockquote で順序誤りによる破壊事象（進行中 PR への想定外 commit / force push 可能性）と回避策（順序遵守）を記載 |
| 4.4 | README L5588〜L5594 / L5605〜L5611 で復旧後の期待ラベル状態と次アクションを A / B 各ケースで明示 |
| 4.5 | README L5613〜L5615 で「運用者が実行する操作（ラベル付与・除去の順序）として記述」「watcher 内部の関数名・コードパスには踏み込まない」と明示 |
| 5.1 | README L4772 env 表に `DEV_MAX_TURNS` 項目を追加、既定値 60、意味、推奨レンジ感（粒度是正優先）を記載 |
| 5.2 | 同上：「多い場合はタスクが大きすぎる兆候。恒久引き上げより粒度是正を優先」を推奨欄に記載 |
| 5.3 | 同上：既存 `PR_ITERATION_MAX_TURNS` / `REVIEWER_MAX_TURNS` と同じ 4 列表形式（変数 / デフォルト / 推奨 / 用途）で整合 |
| 5.4 | 同上：「値変更は次回 watcher 起動時から有効で、cron / launchd の再登録不要」「per-task ループの 1 タスクあたり Claude 実行 turn 数上限。Issue 全体ではなくタスク単位で各 fresh session に適用される」を用途欄に明示 |
| 5.5 | `DEV_MAX_TURNS` の既定値（60）は本 PR で **変更していない**（`issue-watcher.sh:512` `DEV_MAX_TURNS="${DEV_MAX_TURNS:-60}"` のまま）|
| 6.1 | tasks-generation.md（両系統）「turn 予算ガイドライン」節 →「fresh session 仕様（前提）」配下で「タスクごとに新規 Claude session で起動」「turn カウンタも各タスクで 0 から始まる」を明示 |
| 6.2 | 同上：「一度 `error_max_turns` で失敗したタスクは、再試行時も同一タスク内で再び 0 turn から開始」を明示 |
| 6.3 | README L5503〜L5506 blockquote で fresh session 含意（タスク間の turn 累積を増やす / Issue 全体の turn 枠を引き上げる発想が無効）を要約 |
| 7.1 | tasks-generation.md（両系統）「粒度指針（推奨）」配下で「1 タスクは `DEV_MAX_TURNS`（既定 60）以内に収まる粒度を目安とする」を明示 |
| 7.2 | 同上：「frontend / UI / テストが重い責務は細かく切る」「UI = 1 component + 1 test = 1 task を目安とする」を含む |
| 7.3 | 同節「既存ガイドラインとの関係」で「3〜10 件目安」「checkbox 必須化」との非矛盾（補助として機能）を明示 |
| 7.4 | 同節「強度（推奨どまり / Mechanical Check 不在）」で reject 条件として宣言しないことを明示 |
| 7.5 | 同節 blockquote で「設計段階で 1 タスクの turn 予算を意識することが、運用時の `error_max_turns` 発生確率を直接下げる最も効果の高い手段」と根拠を記載 |
| 8.1 | env 名（`DEV_MAX_TURNS` / `PR_ITERATION_MAX_TURNS` / `DEV_MODEL` 等）の名称・意味・既定値を本 PR で変更していない（diff 検証済み）|
| 8.2 | ラベル（`claude-failed` / `per-task-implementer-failed` / `ready-for-review`）の名称・付与契約・遷移意味を変更していない |
| 8.3 | watcher / agent 実装コードを編集していない（git status / git diff で確認） |
| 8.4 | 既存 `tasks-generation.md` の checkbox 必須化 / Budget overflow check / 構造化 verify ブロック規約を削除・改変していない（節末尾に新節追加のみ） |
| 8.5 | `diff -r .claude/rules repo-template/.claude/rules` が空（byte 一致）|
| NFR 1.1 | 既存 h2 / h3 階層構造を破壊せず、既存サブ節（`claude` が見つからない / OAuth / 多重起動など）の一意性を維持 |
| NFR 1.2 | 日本語ベース記述（識別子・env 名・ラベル名等の英語固定語彙は除く） |
| NFR 1.3 | 既存 `PR_ITERATION_*` の説明（line 2682）と語彙・記述スタイルを揃え、`REVIEWER_MAX_TURNS`（line 3651）と表形式を統一 |
| NFR 2.1 | 既存 `## トラブルシューティング` 節（README 目次直接配下の h2）配下に h3 として配置 → 目次から 2 ホップで到達 |
| NFR 2.2 | README → tasks-generation.md、README ↔ QUICK-HOWTO の双方向相互リンク完成 |
| NFR 2.3 | 見出し / 本文に `per-task-implementer-failed` / `error_max_turns` / `claude-failed` を含めテキスト検索で発見可能 |
| NFR 3.1 | 復旧手順記述でラベル操作順序を実行手順本文中に必ず明示（README L5599〜L5611 の bash コマンド列） |
| NFR 3.2 | 順序誤りリスクを警告 blockquote として記載（README L5577〜L5580） |

## 確認事項（レビュワー判断ポイント）

1. **GitHub anchor の slug 確定**: README の `### \`per-task-implementer-failed\` / \`error_max_turns\` 対応`
   見出しから自動生成される anchor は本 PR で `#per-task-implementer-failed--error_max_turns-対応`
   と仮定している。GitHub の slug 生成は「バッククォート除去 / 半角スペース → `-` / `/` 除去
   / 連続 `-` 保持」のため、`per-task-implementer-failed` + ` / ` (`-`-`-`) + `error_max_turns`
   = `per-task-implementer-failed--error_max_turns` の **連続ハイフン 2 つ**となる想定。PR レビュー
   時に実際の merge 後 anchor をクリックして遷移できるか確認すること。
2. **`DEV_MAX_TURNS` 項目の README 配置**: 「Per-task TDD Implementation Loop (#21)」節内の
   env 表に配置した（最も強い文脈接続のため）。別案として独立 `### 環境変数（共通）` 節を新設して
   そこに集約する選択肢もあるが、本 spec のスコープ外（Out of Scope の「他 env の説明拡充は対象外」）
   と判断した。
3. **手動仕上げの判断閾値**: 要件 3.4 で「観測可能な閾値」を求められたため「2 回連続観測 /
   1.5〜2 倍引き上げ後も通過しない」を採用したが、これは経験値ベースの目安。実運用での観測蓄積後
   に Issue として閾値見直しを切り出す余地あり（Open Question「将来ロジック改善の派生 Issue」と整合）。
4. **QUICK-HOWTO の要約の詳細度**: 最頻出ケースの要約 + 詳細リンクの構成とし、復旧手順そのものは
   重複させていない。Open Question「配置先の選択」で示された「README 一次配置 / QUICK-HOWTO 要約」
   構成を採用。レビュワー判断で重複度を増やす（QUICK-HOWTO にラベル順序の bash コマンドも併載）
   方針もあり得るが、二重管理コストを考慮して要約版に留めた。

## 派生 Issue 候補（本 PR スコープ外）

- per-task ループの自動タスク分割 / 自動 `DEV_MAX_TURNS` 引き上げ等のロジック改善（Open Questions
  の「将来ロジック改善の派生 Issue」と整合）
- `error_max_turns` 以外の Implementer 失敗モード（panic / OOM 等）の Troubleshooting 節追加
  （Out of Scope に列挙）
- `DEBUGGER_ENABLED=true` 環境での実テスト失敗時 Debugger 経路への詳細リンク強化

## ローカルブランチ状態

- ブランチ: `claude/issue-289-impl-docs-per-task-implementer-failed-error-m`
- 本 PR で積んだ commit:
  1. `docs(rules): tasks-generation に turn 予算ガイドラインを追記`
  2. `docs(readme): per-task-implementer-failed / error_max_turns の対応節を追加`
  3. `docs(quick-howto): per-task-implementer-failed の要約と README 相互リンクを追加`
  4. `docs(spec): add impl-notes for #289`（本ファイルの commit、最後に追加）
- origin への push は本 Developer 段階では行わず、後段の watcher / PjM ステージに委ねる

STATUS: complete
