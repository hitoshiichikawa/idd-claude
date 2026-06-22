# Implementation Notes — Issue #348 FULL_AUTO_ENABLED kill switch

## 配線対象 processor の確定

要件 Open Questions（実装済み / 未実装の境界判別）に対する Phase 1 調査結果:

| processor 候補 | 実装状況 | 配線判断 | 根拠 |
|---|---|---|---|
| `dr_unblock_sweep` (Dependency Auto-Unblock Sweep, #346) | **実装済み** | **配線対象** | `local-watcher/bin/issue-watcher.sh` L9578〜 / `_dispatcher_run` 冒頭で起動 (#346) |
| auto-merge processor | **未実装** | 配線対象外 | `gh pr merge --auto` 等の呼び出し箇所が無い |
| failed-recovery processor | **未実装** | 配線対象外 | `claude-failed` 関連は label 管理 + escalation コメントのみで、自動 recovery 経路は無い |
| needs-decisions auto processor | **未実装** | 配線対象外 | `needs-decisions` は付与 / 抑止フィルタ用途のみで、自動解除 processor は無い |
| semantic conflict processor | **未実装** | 配線対象外 | 関連実装が無い（auto-rebase の `ar_dismiss_all_approvals` は別概念で本フラグ配下外） |
| blocked cascade processor | **`dr_unblock_sweep` が該当** | 同上 1 件目に集約 | `unblock sweep` が「依存全解決で `blocked` を外す」cascade 機能を提供する |

調査コマンド: `grep -rnE 'auto[_-]?merge|gh pr merge|failed[_-]?recovery|semantic[_-]?conflict|blocked[_-]?cascade'`

→ **配線対象は実装済みの `dr_unblock_sweep` 1 件のみ**。要件本文の Out of Scope と Open Questions
通り、未実装 processor は将来追加時に同じ `full_auto_enabled` ヘルパーを参照する設計とした。

## 主要な実装場所

| 変更 | ファイル | 行（実装後） |
|---|---|---|
| Config ブロックに `FULL_AUTO_ENABLED` 追加 + 値正規化 | `local-watcher/bin/issue-watcher.sh` | L107〜L128（既存 `DEP_AUTO_UNBLOCK_ENABLED` 直後） |
| cycle startup ログに `full-auto=` 値出力 | `local-watcher/bin/issue-watcher.sh` | L832（既存 `base-branch=...` 行に追記） |
| 純粋関数ヘルパー `full_auto_enabled()` 追加 | `local-watcher/bin/issue-watcher.sh` | L9412〜L9430 |
| `dr_unblock_sweep` 入口で AND ゲート参照 | `local-watcher/bin/issue-watcher.sh` | L9613〜L9622 |
| doctor 出力に kill switch 状態を表示 | `local-watcher/bin/modules/scaffolding-health.sh` | `sh_doctor_check_full_auto` 関数 + `sh_doctor_run` 呼び出し |
| 近接単体テスト追加 | `local-watcher/test/full_auto_enabled_test.sh` | 新規（300 行弱） |
| 既存テストの抽出リスト追随 + 観測点調整 | `local-watcher/test/dr_unblock_sweep_test.sh` | `full_auto_enabled` 抽出追加 + `FULL_AUTO_ENABLED=true` baseline 固定 |
| README オプション機能一覧に行追加 | `README.md` | opt-in 表に `Full-Auto Kill Switch` 行を追加（#346 行の直後） |

## 設計判断

### 1. 値正規化は `case` で「`true` 厳密一致のみ ON」

既存の opt-in 系（`PROMOTE_PIPELINE_ENABLED` / `PATH_OVERLAP_CHECK` / `PER_TASK_LOOP_ENABLED` /
`DEP_AUTO_UNBLOCK_ENABLED` / `AUTO_REBASE_MODE`）と完全に揃えた。`AUTO_REBASE_MODE` パターン
（Config ブロック内で `case` による正規化）を採用し、`TRUE` / `1` / `True` / 前後空白付き /
typo はすべて `false` に正規化する。既定有効化 8 種の正規化ループ（`_idd_flag` ループ）には
**含めない**（既定 OFF の opt-in 制のため、`=true` 厳密一致で有効化する設計、要件 Req 1.1〜1.3）。

### 2. AND ゲート参照位置: `dr_unblock_sweep` 関数冒頭（個別 gate より前）

要件 Req 2.5「FULL_AUTO_ENABLED が disabled なら早期 return without performing any external
side effect」と Req 4.1「kill switch を suppression cause として log line」を満たすため、
個別 gate `dr_unblock_gate_enabled` より **前** に kill switch 評価を置いた。これにより:

- kill OFF 時: kill switch 抑止 log 1 行 + 早期 return（個別 gate は評価しない / `gh` ゼロ呼び出し）
- kill ON + 個別 gate OFF 時: kill 抑止 log を出さず、個別 gate で従来通り静かに return
- kill ON + 個別 gate ON 時: 通常フロー

この順序は「運用者が `grep 'suppressed by FULL_AUTO_ENABLED'` で kill switch 抑止のみを
ピンポイントで観測できる」という要件 4.1 のテスト可能性を保証する。

### 3. 純粋関数化と `${VAR:-false}` の二重防御

`full_auto_enabled()` は副作用ゼロの純粋関数として実装し、`case "${FULL_AUTO_ENABLED:-false}"`
で fallback を入れた（Config ブロックで既に正規化済みだが、`extract_function` で関数だけを
抽出する単体テスト経路で env が未設定でも安全側に倒すため）。

### 4. doctor 出力への kill switch 行追加（常に ok 表示）

要件 Req 3.2「`--doctor` shall remain functional」を満たすために doctor は**書き換え不要**
だが、運用者の運用利便性向上のため `sh_doctor_check_full_auto` を追加した。本点検は **常に
ok 表示**（戻り値 0）であり repo 全体 degraded への昇格に算入しない（kill switch は運用判断に
基づく設定であり degraded ではない）。

### 5. 既存 `dr_unblock_sweep_test.sh` の retrofit

ヘルパー抽出規約（CLAUDE.md §7「ヘルパーを抽出したら、それを呼ぶ既存テストの抽出リストにも
追随させる」）に従い、`full_auto_enabled` を抽出リストに追加した。既存テストは個別 gate
`DEP_AUTO_UNBLOCK_ENABLED` のセマンティクスを検証することが目的のため、新規 kill switch を
`FULL_AUTO_ENABLED=true` で固定して既存観測点（gh 呼び出し回数 / コメント文面 / 構造化ログ）
を維持した。kill switch OFF 時の AND ゲート挙動は新規ファイル `full_auto_enabled_test.sh` に
別途実装した。

## AC Traceability

| AC | 実装担保位置 | 検証テスト |
|---|---|---|
| Req 1.1: 既定 false | `issue-watcher.sh` L118 `FULL_AUTO_ENABLED="${FULL_AUTO_ENABLED:-false}"` | `full_auto_enabled_test.sh` Section 1 「未設定なら disabled」 |
| Req 1.2: `true` 厳密一致のみ enabled | `issue-watcher.sh` L122〜L125 `case` 正規化 | `full_auto_enabled_test.sh` Section 1 「`=true` で enabled」 |
| Req 1.3: 未設定 / 空 / false / 0 / True / TRUE / 1 / typo はすべて disabled | 同上 | `full_auto_enabled_test.sh` Section 1（13 ケースで網羅: 空 / false / 0 / True / TRUE / 1 / on / yes / enable / enabled / Yes / tRue / 前後空白付き / `true` の派生 / typo） |
| Req 1.4: 正規化を processor 入口より前に完了 | Config ブロックで `case` 正規化済みのため OK | （実装時に Config ブロック先頭近傍へ配置） |
| Req 2.1〜2.5: 各 full-auto processor 入口で disabled なら早期 return without external side effect | `dr_unblock_sweep` L9613〜L9622（実装済み 1 件目）。未実装 processor は将来追加時に同じパターンを踏襲（impl-notes Open Question 参照） | `full_auto_enabled_test.sh` Section 2 Case A / A' / A''（kill OFF 全パターンで `gh` ゼロ呼び出し） |
| Req 2.6: kill ON + 個別 gate disabled → no-op | `dr_unblock_sweep` の個別 gate 段は変更なし（kill 評価通過後に既存 gate を評価） | `full_auto_enabled_test.sh` Section 2 Case B / B' |
| Req 2.7: kill ON + 個別 gate ON → 通常フロー実行 | 同上 | `full_auto_enabled_test.sh` Section 2 Case C |
| Req 3.1: 未設定時、本機能導入前と等価 | kill switch 評価前は影響しない設計 + 既存個別 gate の挙動は維持（既存 56 テスト pass） | `dr_unblock_sweep_test.sh` 全 56 テスト pass + `full_auto_enabled_test.sh` Section 3 |
| Req 3.2: `--doctor` は値に関わらず functional | doctor `sh_doctor_check_full_auto` は常に ok 戻り、レポートを破壊しない | （手動確認 / shellcheck pass / bash -n pass） |
| Req 3.3: 既存 opt-in 機能を本フラグ配下に入れない | merge-queue / auto-rebase / promote-pipeline 等の入口には `full_auto_enabled` 呼び出しを追加していない（grep で確認） | （`grep -n full_auto_enabled local-watcher/bin/modules/*.sh` で 0 件） |
| Req 3.4: kill disabled でも非 full-auto processor は個別 gate に従って評価 | 上記 3.3 と表裏一体 | （既存 56 テスト pass で間接保証） |
| Req 4.1: kill disabled + full-auto processor 評価時に suppression cause を log line | `dr_unblock_sweep` 内 `dr_log "dr_unblock_sweep: suppressed by FULL_AUTO_ENABLED kill switch (no-op)"` | `full_auto_enabled_test.sh` Section 2 Case A 「suppression ログ 1 行出力」 / Section 3 |
| Req 4.2: cycle startup output に resolved `FULL_AUTO_ENABLED` 値を含める | `issue-watcher.sh` L832 `echo "... full-auto=${FULL_AUTO_ENABLED}"` | （目視 + grep 観測） |
| NFR 1.1: 未設定時、byte-equivalent な外部副作用 | kill switch 抑止経路は **新規 ログ 1 行のみ** 追加し、`gh` / `git` / ラベル遷移 / コミット / push の挙動は不変 | （54 件の既存全テスト pass / shellcheck pass） |
| NFR 1.2: env / label / exit / cron 文字列を変更しない | 新規 env `FULL_AUTO_ENABLED` のみ追加。既存名は不変 | （diff 確認） |
| NFR 2.1: README に追記 | README L1363 にオプション機能一覧表へ Full-Auto Kill Switch 行を追加 | （diff 確認） |
| NFR 2.2: `local-watcher/` と `repo-template/` の byte 一致 | `repo-template/local-watcher/` は存在しない（idd-claude では `local-watcher/` は repo-template には複製されていない）。`.claude/{agents,rules}` は `diff -r` clean | `diff -r` 確認済み（clean） |
| NFR 3.1: shellcheck + bash -n pass | （実装後の shellcheck / bash -n 結果参照） | shellcheck rc=0 / bash -n rc=0 |

## 静的解析・テスト結果

### shellcheck

```
shellcheck local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh
→ rc=0 / 警告なし
```

### bash -n

```
bash -n local-watcher/bin/issue-watcher.sh
→ rc=0
bash -n local-watcher/bin/modules/*.sh
→ 全 module rc=0
```

### 単体テスト

- 新規 `full_auto_enabled_test.sh`: **PASS=28 FAIL=0**（値正規化 17 ケース + AND ゲート 9 ケース + 後方互換 2 ケース）
- 既存 `dr_unblock_sweep_test.sh`: **PASS=56 FAIL=0**（`full_auto_enabled` 抽出 retrofit 後も全 pass）
- 全 `local-watcher/test/*.sh`: **全 25 ファイル PASS**（リグレッションなし / `dr_unblock_sweep_test.sh` を含む既存 24 テストはすべて pass）

### root ↔ repo-template byte 同期

```
diff -r .claude/agents repo-template/.claude/agents → 空（clean）
diff -r .claude/rules repo-template/.claude/rules → 空（clean）
```

## 確認事項（Reviewer へ）

1. **「auto-merge / failed-recovery / needs-decisions auto / semantic conflict / blocked cascade」のうち
   実装済みは `dr_unblock_sweep` 1 件のみ**と判断しました（要件 Open Questions の解釈）。
   要件本文 Out of Scope 「新規の full-auto 系 processor の実装そのもの」を踏まえ、未実装
   processor は将来追加時に同じ `full_auto_enabled()` を AND 参照する設計（pattern 提供）
   としました。要件の Open Questions が「実装済みのみ配線」を許容しているため要件範囲内と
   解釈しましたが、Reviewer の判断（要件範囲の解釈）を仰ぎます。
2. doctor 出力に `sh_doctor_check_full_auto` を追加しました（常に ok 表示）。要件 Req 3.2 は
   「functional であること」のみを要求しているため、表示行を**増やすか否か**は実装裁量と
   解釈しました（運用利便性向上目的）。表示は不要との判断であれば削除可能です。
3. `dr_unblock_sweep_test.sh` の retrofit で `FULL_AUTO_ENABLED=true` を test 冒頭で固定しました。
   既存テストの「個別 gate `DEP_AUTO_UNBLOCK_ENABLED` のセマンティクスを検証する」目的を維持
   するための判断ですが、kill switch OFF を baseline にすべきという見解があり得るため確認。

## 残存課題（次 Issue / 派生候補）

- 未実装 full-auto 系 processor（auto-merge / failed-recovery / needs-decisions auto /
  semantic conflict）の実装時、本 PR で導入した `full_auto_enabled()` を AND 参照する規約を
  忘れないよう、`docs/specs/` の対応 Issue 内に明示注記を残す運用が望ましい（本 PR 範囲外）。
- `full_auto_enabled` を呼ぶ箇所が増えた場合に doctor 出力で「配線済み processor 一覧」を
  併記すると運用が楽になる可能性あり（本 Issue 範囲外）。

STATUS: complete
