# 実装ノート: #216 harness tasks-count 計数の canonical 整合

## 概要

harness 側 `local-watcher/bin/issue-watcher.sh` の `tc_count_tasks` の count 抽出 regex を、
Architect 正準（`design-review-gate.md` の Budget overflow check）と同一の
`^- \[ \]\*? [0-9]+\. ` に整合させた。これにより、Architect が「budget 内（≤10 最上位）」と
確定した設計を harness が「≥11（全 checkbox 計上）」と誤って escalate する二重計上を解消する。
閾値・env var 名・マーカー文字列・exit code 意味・ラベル遷移契約は一切変更していない。

## 変更ファイルと変更概要

| ファイル | 変更概要 |
|---|---|
| `local-watcher/bin/issue-watcher.sh` | `tc_count_tasks` の grep regex を旧 `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` → canonical `^- \[ \]\*? [0-9]+\. ` に変更。関数冒頭コメントを新セマンティクス（最上位・未完了のみ、子/完了除外、最上位 deferrable は含む）に書き換え、正準が design-review-gate.md である旨と相互参照を明記。warning / escalation コメント文言を「最上位・未完了ベース」に追従。 |
| `tests/local-watcher/tasks-count/extract-driver.sh` | `_TC_EXPECTED` を canonical 計数に更新（tasks-mixed-checkbox 8:warn→4:normal）。新 fixture tasks-toplevel-vs-flat.md を 7:normal で登録。 |
| `tests/local-watcher/tasks-count/fixtures/tasks-toplevel-vs-flat.md` | 新規回帰 fixture（子タスク除外・完了 `[x]` 除外をロック。旧計数 15 / canonical 7）。 |
| `tests/local-watcher/tasks-count/perf-driver.sh` | 生成 tasks.md を子タスク `$i.$sub` → 最上位 `$i.` に変更し、canonical regex がマッチする計数経路の最悪ケースを計測。 |
| `README.md` | 「Tasks Count Gate (#147)」節のカウント対象記述を canonical 整合に更新 + migration note 追記。 |
| `.claude/rules/design-review-gate.md` | Count 抽出 regex 節に harness への逆参照を 1 段落追記（計数定義 regex / 散文は不変）。 |

## 新旧 regex の対比

| | 旧 (〜#147) | 新 (#216 / canonical) |
|---|---|---|
| regex | `^- \[[ x]\]\*? [0-9]+(\.[0-9]+)*\.? ` | `^- \[ \]\*? [0-9]+\. ` |
| 未完了最上位 `- [ ] 1.` | 計上 | 計上 |
| 最上位 deferrable `- [ ]* 2.` | 計上 | 計上 |
| 子タスク `- [ ] 1.1` | 計上 | **除外**（`.` 直後が空白でない） |
| 完了 `- [x] 3.` | 計上 | **除外**（checkbox を `\[ \]` に固定） |
| 完了 deferrable `- [x]* 4.1` | 計上 | **除外** |

## 各 fixture の新旧件数表

実測（`grep -cE` 直接計測）:

| fixture | 旧計数 (全 checkbox) | 新計数 (canonical) | 新 classification |
|---|---|---|---|
| tasks-7.md | 7 | 7 | normal |
| tasks-8.md | 8 | 8 | warn |
| tasks-10.md | 10 | 10 | warn |
| tasks-11.md | 11 | 11 | escalate |
| tasks-empty.md | 0 | 0 | normal |
| tasks-mixed-checkbox.md | 8 | **4** | **normal**（旧 warn から変化） |
| tasks-toplevel-vs-flat.md（新規） | 15 | **7** | normal |

tasks-7/8/10/11/empty は最上位・未完了のみで構成されるため件数不変（実測で確認済み）。

## 手動スモークテスト結果（Test plan 転記用）

```text
# 1. shellcheck（新規 SC2006/SC2215 警告ゼロ。残存は既存の SC2317 info のみ）
$ shellcheck local-watcher/bin/issue-watcher.sh
  → 新規 warning なし（既存の SC2317 info: ログ関数の間接呼び出し、本変更前から存在）
$ shellcheck tests/local-watcher/tasks-count/extract-driver.sh tests/local-watcher/tasks-count/perf-driver.sh
  → クリーン（SHELLCHECK OK）

# 2. fixture/driver 回帰テスト
$ bash tests/local-watcher/tasks-count/extract-driver.sh
  → summary: pass=17 fail=0 total=17 / exit=0

# 3. パフォーマンステスト（NFR 2.1 決定性 / 旧 NFR 3.1 性能）
$ bash tests/local-watcher/tasks-count/perf-driver.sh
  → tc_count_tasks: count=20000 elapsed=2ms / PASS / exit=0

# 4. canonical 整合（Req 1.5）: tc_count_tasks == `grep -cE '^- \[ \]\*? [0-9]+\. '`
  tasks-mixed-checkbox.md : tc_count_tasks=4  canonical_grep=4  MATCH
  tasks-toplevel-vs-flat.md: tc_count_tasks=7  canonical_grep=7  MATCH
  tasks-11.md             : tc_count_tasks=11 canonical_grep=11 MATCH
```

## 受入基準のテスト担保

| AC | 担保方法 |
|---|---|
| Req 1.1（最上位 numeric ID 未完了のみ計数） | regex 変更 + tasks-7/8/10/11 fixture（最上位未完了のみ件数一致） |
| Req 1.2（子タスク `1.1` 除外） | tasks-mixed-checkbox.md（子 1.1/1.2 を除外し 4 件）/ tasks-toplevel-vs-flat.md（子多数を除外し 7 件） |
| Req 1.3（完了 `[x]` 除外） | tasks-mixed-checkbox.md（完了 5. 除外）/ tasks-toplevel-vs-flat.md（完了 3./7.1 等を除外） |
| Req 1.4（最上位 deferrable `- [ ]*` 含む） | tasks-mixed-checkbox.md（deferrable 2. を計数に含めて 4 件）/ tasks-toplevel-vs-flat.md（deferrable 8. を計数に含めて 7 件） |
| Req 1.5（Architect 計数と同一件数） | 手動スモーク 4（3 fixture で tc_count_tasks == canonical grep が MATCH） |
| Req 2.1（最上位・未完了ベースを分類対象に） | extract-driver の classification 列が新 count で normal/warn/escalate に分岐（17 ケース pass） |
| Req 2.2（impl-resume 一部 `[x]` 済みで残未完了件数判定） | 完了 `[x]` 除外 = 残未完了件数判定。tasks-toplevel-vs-flat.md（完了行を除外して 7 件）で担保 |
| Req 2.3（真に ≥11 は引き続き escalate） | tasks-11.md（11:escalate）が変更後も escalate を維持（driver pass） |
| Req 2.4（閾値不変） | classify 境界値テスト（0/7/8/9/10/11/50）が既定閾値 8/10/11 で従来通り pass。閾値 env var を変更していないことをコード差分で確認 |
| Req 3.1（両所に同一 regex 明記） | issue-watcher.sh コメント + design-review-gate.md の双方に `^- \[ \]\*? [0-9]+\. ` を明記 |
| Req 3.2（harness ドキュメントに正準と相互参照） | tc_count_tasks コメントに正準=design-review-gate.md である旨 + 相互参照。逆方向も design-review-gate.md に 1 段落追記 |
| Req 3.3（README 整合） | README「Tasks Count Gate」節を canonical 計数に更新 |
| Req 3.4（回帰テストが子/完了/deferrable を含む tasks.md を検証） | tasks-mixed-checkbox.md / tasks-toplevel-vs-flat.md（4 種 checkbox + 子 + 完了 + deferrable を含む） |
| Req 4.1（per-issue override #214 非依存） | 計数ロジックは override シグナルを参照しない（tc_count_tasks は tasks.md のみを入力とする純粋関数。コード差分で確認） |
| Req 4.2（per-task-loop #21 非変更） | per-task-loop 関連コード（`PER_TASK_LOOP_ENABLED` 経路）に変更なし（差分は tc_count_tasks / コメント / コメント文言のみ） |
| NFR 1.1（TC_ENABLED 非 true で挙動不変） | tc_should_run の opt-out 分岐は未変更。tc_count_tasks は gate 通過後にのみ呼ばれる |
| NFR 1.2（README に migration note） | README に migration note 追記 |
| NFR 1.3（env var 名 / マーカー文字列不変） | env var 名・`<!-- idd-claude:tasks-count-overflow ... -->` マーカーともに未変更（コード差分で確認） |
| NFR 2.1（決定性） | tc_count_tasks は環境状態に依存しない pure grep。perf-driver の繰り返し計測で同一件数 |

## 実装上の判断・解釈

- **最上位 deferrable `- [ ]*` の扱い**: requirements.md Req 1.4 / Open Questions に従い、
  「正準 regex の一致挙動に厳密一致させる」方針を採用。canonical regex `^- \[ \]\*? [0-9]+\. ` は
  `\*?` により最上位 deferrable に一致する（＝計数に含む）ため、harness もそれに従う。
- **warning / escalation コメント文言**: 件数の意味が「最上位・未完了ベース」に変わったことが
  運用者に伝わるよう、検知件数行に「最上位 numeric ID の未完了タスクのみ。子タスク `1.1` /
  完了済み `- [x]` は計数対象外。#216 で Architect の Budget overflow check 計数と整合」を追記
  （閾値の数値・env var 名・マーカー文字列は不変）。
- **perf-driver.sh の生成内容変更**: 旧版は子タスク `$i.$sub` のみを生成しており、新 canonical
  regex では全行が非マッチ（count=0）になっていた。計数経路の最悪ケース（regex マッチ）を
  実際に計測するため、生成行を最上位 `$i.` に変更した。性能 assert（<1s）・決定性は不変。
- **shellcheck**: heredoc 内のコメント文言にバックティック（`` `1.1` `` 等）を直書きすると
  SC2006/SC2215 が出るため、既存実装と同様にバックスラッシュエスケープ（`` \`1.1\` ``）した。
  残存する SC2317 info（ログ関数が間接呼び出しで unreachable と判定される）は本変更前から
  存在する既存警告であり、新規には増やしていない。

## 確認事項（人間判断 / レビュワー向け）

1. **design-review-gate.md 散文の deferrable 自己矛盾（未解決・人間判断にエスカレーション）**:
   正準 regex `^- \[ \]\*? [0-9]+\. ` は最上位 deferrable `- [ ]*` に一致する（＝計数に**含む**）一方、
   design-review-gate.md / tasks-generation.md の散文は「`- [ ]*`（deferrable テストタスク）は本
   カウントでは数えません」と記載しており**自己矛盾**している。本 Issue は Architect 側 regex 変更を
   スコープ外とするため、harness は regex の一致挙動に厳密一致させた（Req 1.4 = deferrable を計数に
   含む）。散文側を regex に合わせて「最上位 deferrable は含む」と書き換えるか、将来 regex を
   `^- \[ \]\? ...` 相当（deferrable を除外）へ見直すかは、requirements.md Open Questions に従い
   **本 PR では確定せず人間判断にエスカレーション**する。新規 fixture tasks-toplevel-vs-flat.md /
   tasks-mixed-checkbox.md は「deferrable を計数に含む」前提で期待値を組んでいるため、将来散文側を
   「除外」方向で確定した場合は fixture 期待値の再調整が必要になる。

2. **計数定義の二重管理リスク（lint 化の要否は人間判断）**: bash（harness）と LLM ルール
   （Architect）は実行基盤が異なり共有コードを持てないため、本変更は同一 regex を両所に明記し
   相互参照する「ドキュメントで担保」方式を採った（Req 3.1 / 3.2）。将来両所の regex 文字列が
   乖離した際に機械的に検知する仕組み（例: 2 ファイルの regex リテラル一致を検査する lint /
   smoke）の導入要否は本 Issue のスコープ外であり、requirements.md Open Questions に従い人間判断に
   委ねる。

3. **既存 main 上の他 fixture/script への影響なし**: 変更は tasks-count スイート（extract-driver /
   perf-driver / fixtures）に閉じており、他の test driver（stage-a-verify 等）には触れていない。

STATUS: complete
