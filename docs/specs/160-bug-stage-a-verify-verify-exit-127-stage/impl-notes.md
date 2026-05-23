# Implementation Notes — #160 Stage A Verify backtick 抽出

## 着手前メモ

### 要件サマリ

- Req 1: backtick で囲まれたコマンドを優先抽出（行内の最初に keyword 一致した backtick の中身）
- Req 2: backtick が無い行は従来通り行全体抽出（後方互換）
- Req 3: 複数行 fenced code block（` ``` `）のみは SKIPPED 扱い
- Req 4: env escape hatch / opt-out は不変
- Req 5: SKIPPED 経路の cron.log への明示
- Req 6: 既存責務境界・ログ規約・差し戻し contracts は不変

### 修正対象

`local-watcher/bin/issue-watcher.sh` の `stage_a_verify_extract_command()`（L5463 〜 L5548）。

### 設計上の判断

1. **awk 1 パスを維持**: NFR 2 線形時間 O(N) を満たすため、既存 awk スクリプトに backtick
   抽出ロジックと fenced state machine を追加する形で実装。
2. **fenced code block 判定**: 行頭が `` ``` `` で始まる行（任意の空白前置き許容、その後 lang
   指定の有無問わず）を fence の境界として扱う。in-fence な行は keyword 一致を行わない。
3. **inline code span 抽出**: 行内に backtick が **2 個以上**ある場合のみ inline code span
   候補ありと判定する。最初のペアから順に走査し、内側に keyword が一致した最初のペアを採用
   する（Req 1.2）。
4. **複数行追跡**: 「末尾に最も近い 1 行」を取るので、`last_result` を更新しつつ最終行まで走査
   して END で出力する既存のロジックを踏襲する。
5. **後方互換**: backtick を含まない既存形式（fixture: tasks-gradlew.md / tasks-mixed.md 等）
   の抽出結果は **本修正で変化させない**（NFR 1.1）。既存 12 fixture の expected を変えない
   範囲で実装する。

### 実装計画（1 commit にまとめる）

1. `stage_a_verify_extract_command()` の awk スクリプトを差し替え（fenced state machine +
   backtick 優先 + line fallback）。
2. fixture を 4 種追加（NFR 4.1）:
   - `tasks-backtick-with-prose.md`: `- lint 緑: \`./gradlew :app:lintDebug\` で新規 error なし`
     形式（本 Issue の本丸の再現）
   - `tasks-backtick-multi.md`: 同一行に backtick が複数並ぶケース（最初に keyword 一致した中身採用）
   - `tasks-fenced-only.md`: 複数行 fenced block のみ → SKIPPED
   - `tasks-prose-keyword-only.md`: backtick 無しの散文に keyword が部分一致するケース
     → 後方互換維持: 行全体採用（既存挙動を保つ。本 issue の本丸を解決する手段は backtick
     優先で、散文オンリーは v1 の SKIPPED とすると後方互換崩れる）
3. `tests/local-watcher/stage-a-verify/extract-driver.sh` の期待値テーブルを 4 件追加。
4. shellcheck で警告ゼロ確認。

### 後方互換ジレンマと判断

要件 Req 1.4 は「インラインコードスパン抽出時にスパン外の散文を含めない」となっており、これは
backtick **がある** 行の話。一方 Req 2.1 は backtick **不在** 行は markdown 装飾を除いた残り
全体を採用、と既存挙動を温存している。

問題は「backtick **不在** で keyword が散文に部分一致する場合」（例: `lint を実行する`）。
これは既存 fixture には無いが、論理的に発生し得る。本実装では:

- **方針**: backtick **不在の場合は従来通り**（既存 fixture が期待する挙動）
- **理由**: 既存 fixture は markdown bullet + 単純コマンドのパターンを多数想定しており、
  これらを SKIPPED に倒すと既存稼働 consumer repo の挙動が変わる（NFR 1.1 違反）
- 散文だけの場合は運用者が `STAGE_A_VERIFY_COMMAND` で escape する設計（Req 4.4 / NFR 2.2）

## 実装結果

### 変更ファイル

1. `local-watcher/bin/issue-watcher.sh` — `stage_a_verify_extract_command()`
   関数内の awk スクリプトを改修（L5511-L5612 周辺、66 行追加）
2. `tests/local-watcher/stage-a-verify/extract-driver.sh` — 期待値テーブルに 4
   fixture 分のエントリ追加（12 行追加）
3. 新規 fixture 4 ファイル:
   - `tests/local-watcher/stage-a-verify/fixtures/tasks-backtick-with-prose.md`
   - `tests/local-watcher/stage-a-verify/fixtures/tasks-backtick-multi.md`
   - `tests/local-watcher/stage-a-verify/fixtures/tasks-fenced-only.md`
   - `tests/local-watcher/stage-a-verify/fixtures/tasks-backtick-and-bare-mix.md`

### 実装ロジック概要

awk 1 パス走査の中で以下の判定を順に行う:

1. **fenced code block 境界判定**: 行頭が `^[[:space:]]*```` で始まる行を fence
   境界として `in_fence` flag をトグル。`in_fence == 1` の行は keyword 一致を
   行わず `next`（Req 3.1）。
2. **markdown 装飾除去**: 既存と同じ regex で行頭 bullet / checkbox / numeric
   prefix / 末尾空白を除去。
3. **inline code span スキャン**: backtick ペアを順に走査し、最初に keyword
   一致した span 内の中身を `last` に保持して当該行は確定（Req 1.1, 1.2）。
4. **fallback (backtick 不在 or 不一致)**: 行内 backtick 数を `gsub` でカウント。
   2 個以上ある（= 散文 + backtick だが keyword はスパン外）なら抽出候補から
   除外（Req 1.4 / Req 5.1）。0〜1 個（既存形式）なら従来通り行全体を keyword 部分
   一致で判定（Req 2.1 後方互換）。
5. **末尾優先**: 既存と同様に「最後に hit した行」を保持して END で 1 行出力
   （Req 1.2 / 2.2 / 2.3）。

### 後方互換性確認

既存 12 fixture (`tasks-gradlew.md` 〜 `tasks-empty.md`) の期待値は本修正で
**一切変更しなかった**。全 16 fixture pass で既存挙動温存（NFR 1.1）を構造的に
担保している。

### env / ラベル / ログ規約

`STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_COMMAND` / `STAGE_A_VERIFY_TIMEOUT`
の意味・既定値・優先順位は本修正で **一切変更していない**（Req 4.3 / NFR 1.1）。
ログ prefix `[$REPO] stage-a-verify:` も既存と同形式のまま（NFR 3.1）。
SKIPPED 経路（fenced only / keyword 一致なし）は既存の `SKIPPED reason=
no-verify-task-in-tasks-md` ログを引き続き 1 行出力する（Req 5.2）。

## テスト結果

### shellcheck

```
$ shellcheck local-watcher/bin/issue-watcher.sh 2>&1 | grep -c 'In .*line'
```

修正箇所（L5511-L5612 周辺）に **新規警告ゼロ**。残存する全 SC2317 (info)
warnings は pre-existing で本修正と無関係。

### 単体スモークテスト（extract-driver.sh）

```
$ bash tests/local-watcher/stage-a-verify/extract-driver.sh
  ok   tasks-backtick-and-bare-mix.md
  ok   tasks-backtick-multi.md
  ok   tasks-backtick-with-prose.md
  ok   tasks-bundle.md
  ok   tasks-cargo.md
  ok   tasks-deferrable.md
  ok   tasks-empty.md
  ok   tasks-fenced-only.md
  ok   tasks-go.md
  ok   tasks-gradlew.md
  ok   tasks-make.md
  ok   tasks-mixed.md
  ok   tasks-no-verify.md
  ok   tasks-npm.md
  ok   tasks-pytest.md
  ok   tasks-shellcheck.md

summary: pass=16 fail=0 total=16
```

### Issue #160 本丸シナリオの再現確認

Issue body にある `KeyNest` の tasks.md 末尾と完全同等の入力で抽出結果が
**`./gradlew :app:lintDebug`**（散文部 / 日本語 / backtick を含まない）になることを
スクリプトで確認した。修正前は同入力で `lint 緑: \`./gradlew :app:lintDebug\` で
新規 error なし` という行全体が返り、`bash -c` で `lint` を `command not found`
(exit 127) として実行していた。修正後は backtick の中身のみが `bash -c` に渡される
ため、`./gradlew` を REPO_DIR で実行する正規パスとなる。

## 要件カバレッジ（AC ↔ テスト）

| Requirement | 担保するテスト |
|-------------|----------------|
| Req 1.1 (backtick 中身を優先抽出) | `tasks-backtick-with-prose.md`, `tasks-backtick-and-bare-mix.md` |
| Req 1.2 (複数 backtick → 最初の keyword 一致) | `tasks-backtick-multi.md` |
| Req 1.3 (複数行存在 → 末尾最も近い) | `tasks-backtick-and-bare-mix.md`（後段の backtick 行を採用） |
| Req 1.4 (スパン外の散文を含めない) | `tasks-backtick-with-prose.md`（散文「lint 緑: 」と「で新規 error なし」が結果に混入しないことを期待値で固定） |
| Req 2.1 (backtick 無し行は装飾除去後の行全体採用) | `tasks-gradlew.md`, `tasks-mixed.md`, `tasks-deferrable.md`（既存 fixture が継続 pass） |
| Req 2.2 (backtick 無し複数行 → 末尾最も近い) | `tasks-mixed.md`（既存）, `tasks-npm.md`（既存）|
| Req 2.3 (混在時はファイル末尾最近の行に Req1/Req2 規則適用) | `tasks-backtick-and-bare-mix.md` |
| Req 3.1 (fenced のみ → SKIPPED) | `tasks-fenced-only.md`（期待 = 空文字列） |
| Req 3.2 (fenced 内行を誤抽出しない) | `tasks-fenced-only.md`（中に `./gradlew` 等を含むが抽出しない） |
| Req 4.1 (`STAGE_A_VERIFY_COMMAND` 優先) | 既存 `stage_a_verify_resolve_command` を変更していないため契約温存（コードレベル確認） |
| Req 4.2 (`STAGE_A_VERIFY_ENABLED=false` で完全 opt-out) | 既存 `stage_a_verify_run` Gate 1 を変更していないため契約温存 |
| Req 4.3 (env 名・既定値不変) | Config ブロック未変更（差分 0 行） |
| Req 5.1 (抽出規則 1〜3.2 不該当時は SKIPPED) | `tasks-no-verify.md`, `tasks-empty.md`, `tasks-fenced-only.md` |
| Req 5.2 (SKIPPED 時の cron.log 出力) | 既存 `stage_a_verify_run` の SKIPPED 分岐温存（コードレベル） |
| Req 5.3 (実行前 chk: 非空 + 行頭 keyword 開始) | 抽出関数の戻り値 1 で SKIPPED 経路に流す既存契約温存 |
| Req 6.1〜6.3 (差し戻し・ログ・env 名規約不変) | `_sav_handle_failure` / `stage_a_verify_run` / Config ブロック未変更（diff stat 0 行） |
| NFR 1.1〜1.3 (後方互換) | 既存 12 fixture が継続 pass |
| NFR 2.1 (O(N) 線形) | awk 1 パス維持（内側ループは行ごとに backtick ペア数 ≤ 行長で打ち切り。最悪 O(N × max-backticks-per-line)、実運用では backtick は 1 行に 1〜数個なので実質 O(N)） |
| NFR 3.1〜3.2 (観測可能性) | ログ規約変更なし |
| NFR 4.1 (4 種 fixture 保持) | `tasks-backtick-with-prose.md`(a), `tasks-backtick-multi.md`+`tasks-no-verify.md`(b 誤抽出防止系), `tasks-gradlew.md` 他(c bare line), `tasks-fenced-only.md`(d) |

注: Req 5.3「行頭が抽出キーワード集合のいずれかで始まること」については、本修正
では実行直前の追加検証ロジックを **追加していない**（既存 `stage_a_verify_run`
の挙動を変更しないため）。backtick 抽出経路では中身が必ず keyword 一致した
span であるため自然に Req 5.3 を満たす。行 fallback 経路は従来通り部分一致を
許容する（既存 fixture 互換のため）。

## 確認事項（Reviewer / 人間判断）

1. **Req 5.3 の解釈について**: 「抽出した shell コマンドを実行する前に、当該
   コマンドが空文字列でないこと、および行頭が抽出キーワード集合のいずれかで
   始まることを確認」とあるが、これを **抽出関数側で行うか、実行側で行うか**
   仕様上明示されていない。本実装は backtick 経路を強化する範囲に限定し、実行
   直前の追加検証は導入しなかった。fallback 経路（backtick 不在の散文に keyword
   が部分一致するケース）で行頭一致を厳格化すると既存 fixture（`tasks-mixed.md`
   の `./gradlew assembleDebug && ./gradlew test` 等の冒頭 `./gradlew` で OK、
   一方で `pytest` が冒頭から始まる fixture との非対称が出る）の挙動が変わる
   可能性があり、本 Issue のスコープを超える後方互換破壊リスクがあるため見送った。
   Reviewer が Req 5.3 の厳密適用を求める場合は別 Issue で対応提案する。

2. **副次事象「outcome=needs-iteration / 差し戻し と書かれているのに claude-failed」**:
   Issue #160 本文に「メッセージの整合性も別途確認が必要かもしれない。本 issue の
   主題ではない」と明記されており、本 PR では扱っていない。`run_impl_pipeline` 側
   の挿入ブロックで `_sav_rc=1` 時に `echo "🔁 ... 差し戻し（次 tick で再試行）"`
   とログを出した直後に `return 1`、呼び出し側で `claude-failed` 扱いになっている
   フローがあるが、これは Stage Checkpoint との協調挙動なので Issue を切り直して
   別途整理する方が安全。

3. **fenced code block 内に keyword が無いケースの判定**: 本実装は in_fence 中の
   行を一律 `next` で skip する。fenced 内に意図的に `./gradlew` 等を書いた運用
   は意図的に SKIPPED 扱いになる（Req 3.1 / 3.2）。これは仕様確定済み事項
   （requirements.md L181-L190）に従う設計だが、運用者が fenced ブロックを唯一の
   verify 表現として使っている場合は `STAGE_A_VERIFY_COMMAND` env で escape する
   必要がある旨を README に追記すべきか確認したい（本 PR では README 変更を
   入れていない）。

STATUS: complete
