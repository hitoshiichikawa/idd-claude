# Implementation Notes (#379)

## Implementation Notes

### Task 1

採用方針: Config ブロック直後に `sr_is_enabled` を暫定実装（task 2 で module へ移送予定）。failed-recovery の二重 opt-in（Req 1.x）と異なり Stale Pickup Reaper は単独 gate（`STALE_PICKUP_REAPER_ENABLED=true` 厳密一致）のみで起動する（design.md "FULL_AUTO_ENABLED 配下に置くか単独 gate か" の判定根拠 1〜3 / Req 1.1〜1.4）。

重要な判断:
- **暫定配置**: `sr_is_enabled` を `issue-watcher.sh` の Config ブロック直後に置く方針は task 1 仕様の明示要件。task 2 で `modules/stale-pickup-reaper.sh` を新規作成する際にここから移送する（暫定実装である旨をコメントで明示済み）。`extract_function` イディオムでテストから切り出せるよう、トップレベル副作用なしの関数定義のみとした
- **Config 正規化方針**: 4 つの数値 env（`THRESHOLD_MINUTES` / `MAX_ISSUES` / `GH_TIMEOUT`）は `case '' | *[!0-9]*` で非整数を検出し、`-le 0` で 0 以下を弾く `failed-recovery` (#359) と同パターン。`ENABLED` は `case`/`true`/`*` の 2 分岐で「true 厳密一致以外は false」へ正規化する simple gate
- **logger 配置**: `sr_log` / `sr_warn` / `sr_error` は `fr_log` 直後（行 159 付近）に追加。prefix `stale-pickup` + `[$REPO]` 3 段で grep 検索性を維持
- **「デフォルト有効化フラグの値正規化」ループに含めない**: 既定 false の新規 opt-in のため、`#112` の 8 種既定 true 反転対象とは別軸（failed-recovery と同方針）

残存課題:
- task 2 で `modules/stale-pickup-reaper.sh` を新規作成し、暫定配置した `sr_is_enabled` をそこへ移送する必要がある。移送時は `issue-watcher.sh` 側から本関数定義ブロックを **削除**して module 側へ移し、`REQUIRED_MODULES` 順 source 後に `declare -F sr_is_enabled` が成立することを確認する（task 6 の本体配線で `REQUIRED_MODULES` への登録を行う）
- task 1 時点ではテスト fixture が `extract_function "$WATCHER_SH" "sr_is_enabled"` で本体から切り出している。task 2 移送後は `MODULE_SH="$SCRIPT_DIR/../bin/modules/stale-pickup-reaper.sh"` 側から抽出する形に変更する必要がある（移送 task で同時に test fixture も更新する）

### Task 2

採用方針: `modules/stale-pickup-reaper.sh` を新規作成し、task 1 で本体に暫定配置していた `sr_is_enabled` と新規 3 関数（`sr_marker_path` / `sr_load_marker` / `sr_save_marker`）を集約。失敗時 fail-open（`{}` 返却）+ atomic write（mktemp → mv -f）+ `jq --arg`/`--argjson` 全引数 sanitize の三本柱で永続化レイヤを構築（`fr_state_path` / `fr_load_state` / `fr_save_state` と同型）。

重要な判断:
- **module 冒頭コメントを `failed-recovery.sh` と同パターンに統一**: 用途 / 配置先 / 依存 / セットアップ参照先の 4 ブロック構成。`set -euo pipefail` を宣言しない / `sr_log` / `sr_warn` / `sr_error` は再定義しない（core_utils.sh 集約）旨も明記し、後続 task で同 module に関数追加するときの規約が一目で分かる形にした
- **`sr_is_enabled` の本体側削除と Config 直後コメント差替え**: 本体側の関数定義ブロックを完全削除し、Config ブロック直後に「`sr_is_enabled` / 永続化レイヤは module に集約」「`REQUIRED_MODULES` 登録は task 6」とだけ書いた短コメントへ差し替え。Config 正規化ブロック（5 env）は task 1 の通り温存
- **labels_json の空文字 fail-safe**: 呼出側が空文字を渡したケース（後続 task で初回観測時に `[]` を渡し忘れる事故等）を想定し、`sr_save_marker` 内で空文字 → `[]` 正規化を 2 段防御（`-n` テストで空チェック / jq 結果の空チェック）にした。`jq` は空入力に対して rc=0 + 空出力を返すため、空出力を素通すと後続 `--argjson last_known_labels ""` が失敗する罠を回避
- **test 抽出元の切替**: `extract_function "$WATCHER_SH" "sr_is_enabled"` を `extract_function "$MODULE_SH" "sr_is_enabled"` へ変更し、新規 3 関数も同 module から抽出。`MODULE_SH` 不在検証ブロックを `WATCHER_SH` のものと同パターンで追加
- **Section 6 jq sanitize 検証**: `"`, `\`, `$`, `` ` ``, 改行 を含む値で injection が起きずに literal 保持されることを 4 field（first_seen_at / last_seen_at / status / revert_at）について確認。`labels_json` 要素中の特殊文字（`"with\\backslash`）も literal 保持を確認

残存課題:
- task 3 で `sr_fetch_candidates`（gh API filter）を実装する際、本 task の `sr_save_marker` が要求する 4 引数（first_seen_at / last_seen_at / labels_json / status / revert_at）を呼出側から正しく生成する必要がある。`labels_json` は `gh issue list --json labels` の出力を `jq -c '[.labels[].name]'` で配列文字列化して渡すのが自然
- task 5 で `process_stale_pickup_reaper` orchestrator から本 layer を呼ぶときに、observing → reverted 状態遷移を `sr_save_marker` の `status` / `revert_at` 引数の組で表現することを確認した（observing 時は `revert_at=""`、reverted 時は `revert_at=<now ISO 8601>`）

### Task 3

採用方針: `sr_fetch_candidates` を `modules/stale-pickup-reaper.sh` 末尾の新規 `Candidate Selection Layer` セクションに追加し、`failed-recovery.sh` の `fr_fetch_failed_issues` と同型の 4 段ガード（timeout / JSON 検証 / 空入力 / 非 array fallback）を踏襲。`gh --search` の `label:"A" OR label:"B"` 構文は server-side で安定しないため、`claude-picked-up` / `claude-claimed` の **2 クエリを個別発行** → `jq` の `unique_by(.number)` で結合 + dedup する設計（design.md "API Contract" 節 + tasks.md task 3 仕様に準拠 / Req 2.1, 2.2, 2.5）。

重要な判断:
- **`hold` ラベルは literal 文字列で扱う**: tasks.md / design.md 双方が `-label:"hold"` を literal で記述しており、`LABEL_HOLD` 定数は本体 `issue-watcher.sh:59-97` に存在しないため新規 LABEL 定数を追加せず literal で渡す方針を採用（grep 確認済み / 新規 LABEL 定数追加は禁止 / CLAUDE.md「機能追加ガイドライン §3」の後方互換規約と整合）。それ以外の除外ラベル（`claude-failed` / `needs-decisions` / `awaiting-design-review` / `needs-quota-wait` / `blocked` / `staged-for-release`）は既存 `LABEL_*` 定数を参照する
- **2 クエリ分離 + jq 結合の選択**: `failed-recovery.sh` は単一クエリで `label:"A" label:"B"` の AND だけを使うため 1 クエリ完結だが、SPR は **2 ラベルの OR** を扱う必要があり、`gh --search` の OR / 単一 search 内 union が server-side で安定しないため別クエリ + client-side dedup（jq `unique_by(.number)`）の方式を採用した。design.md の "API Contract" 節も `gh issue list --search "label:\"<picked\|claimed>\""` の擬似記法で 2 クエリ展開を前提とする
- **truncate は jq 側で `.[0:N]`**: `--limit "$STALE_PICKUP_REAPER_MAX_ISSUES"` を各クエリに付けても 2 クエリ合算で 2N まで膨れるため、結合後に jq `.[0:$limit]` で最終 truncate する（NFR 1.2 の上限契約を完全準拠）。`--argjson limit` 経由で sanitize（NFR 3.1）
- **stub テストで `gh` / `timeout` を関数化**: `failed-recovery.sh` も含め、本体は `timeout <sec> gh ...` で直接呼ぶ実装パターンのため、bash 関数として `timeout()` / `gh()` を test fixture で定義することで stub 可能になる。tasks.md 仕様の「`timeout()` も関数定義する形」を採用し、production コードに `${SR_TIMEOUT_CMD:-timeout}` のような間接呼び出しを入れない（既存 `fr_fetch_failed_issues` と同じ直接呼び出しパターンを温存）
- **gh stub の stdout / trace 分離**: 初回実装で関数定義レベル `} >> "$SR_GH_TRACE"` で stdout 全体を redirect していたため、`cat "$SR_GH_PICKED_RESPONSE"` の出力も trace 側に流れて caller `$(gh ...)` が空文字を受け取る trap に遭遇。trace 書き込みは `{ printf ...; } >> "$SR_GH_TRACE"` のブロック単位で隔離する形に修正し、関数本体の stdout は JSON response として保つ構造に整理した

残存課題:
- task 4 で `sr_check_marker_age` / `sr_check_slot_lock` / `sr_check_session` / `sr_is_active` を実装する際、本 task の `sr_fetch_candidates` が返す JSON の各要素（`{number, labels, title, url, updatedAt}`）から marker.last_known_labels 更新値を生成する必要がある。`jq -c '[.labels[].name]'` で配列文字列化して `sr_save_marker` の第 4 引数に渡すパターンが自然
- task 5 の `process_stale_pickup_reaper` orchestrator から本関数を呼ぶときに、`STALE_PICKUP_REAPER_GH_TIMEOUT` の Config 正規化（task 1 で `--state open` / `--repo` と共に確立済み）が呼び出し時点で解決されることを確認した（遅延束縛 / `sr_marker_path` と同パターン）

### Task 4

採用方針: `modules/stale-pickup-reaper.sh` 末尾に新規 `Active Decision Layer` セクションを追加し、3 観点 AND 判定の 4 関数（`sr_check_marker_age` / `sr_check_slot_lock` / `sr_check_session` / `sr_is_active`）を集約。設計の戻り値語義（`sr_is_active`: 0=keep / 1=inactive 確定）を `if sr_is_active` の自然構文で表現できるように 3 観点関数も「0=非アクティブ寄り / 1 以上=アクティブの可能性あり」に揃え、AND 結合は `[ "$age" = "0" ] && [ "$lock" = "0" ] && [ "$sess" = "0" ]` のシンプル分岐で表現した（誤検出回避を最優先 / Req 3.1〜3.5）。

重要な判断:
- **`slot_lock` の rc=2 解釈**: tasks.md / design.md は `flock` 失敗（権限等）を rc=2「保持の可能性あり」とするが、`flock` の rc は「取得失敗（他プロセス保持中）」と「flock binary 失敗」両方を非 0 で返すため、実装上は「`command -v flock` 失敗のみ rc=2」「`flock -n` の取得失敗は rc=1（保持中）」に分離した。これにより本 layer の `sr_is_active` で AND 判定するときに `rc=1` も `rc=2` も同等に「アクティブ可能性あり」として扱える（`[ "$lock" = "0" ]` 判定で 1 / 2 双方が「非 0 = keep 寄与」になる / Req 3.4 と整合）
- **`date` の OS 互換**: GNU date `-d "$first_seen_at" +%s` を優先、失敗時 BSD date `-j -f "%Y-%m-%dT%H:%M:%SZ" "$first_seen_at" "+%s"` を fallback として試行。両方失敗時は safe-side fresh（rc=1）に倒す。GNU date は ISO 8601 を直接認識するが BSD date は format 指定が必須のため、`sr_save_marker` で書き出す ISO 8601 UTC 形式（`%Y-%m-%dT%H:%M:%SZ`）に format を固定した
- **3 観点関数の引数互換性**: tasks.md は 4 関数すべて `"<marker_json>"` を引数に取る設計だが、現実装では `sr_check_slot_lock` / `sr_check_session` は marker_json を参照しない（lock file glob と pid 取得のみ）。将来拡張用に `_marker_json="${1:-}"` で引数を受け取り `:` で no-op 参照（SC2034 抑止）する形で互換性を維持。これにより `sr_is_active` 側は引数を素通しできる（呼出規約統一）
- **`sr_check_session` の pid 取得失敗を safe-side で即 return**: 各 lock file から pid を取得できないケース（fuser/lsof 失敗・空出力）は「保持の可能性あり」として `return 1` で即終了する。設計上「全 pid 検査して全て非生存なら no-session」と書きたいが、pid 取得失敗を「pid 不在 = 非アクティブ」と誤読すると誤検出になるため、保守的に「1 lock でも pid 取得不能なら may-have-session」に倒した（Req 3.4 と整合）
- **`sr_log` を `sr_is_active` 内で呼ぶ**: design.md は判定根拠を 1 行ログとして記録する（Req 3.5 / NFR 4.1 / NFR 4.2）。`sr_log` は core_utils.sh に集約済みのため `module/stale-pickup-reaper.sh` 側で再定義しない。issue 番号は marker_json の `.issue` から `jq -r '.issue // "?"'` で抽出（不在時は `?` で fallback）
- **テストでの flock 保持の同期**: Section 9c の「別プロセスで flock 保持中」を構成するために、background subshell + named pipe (実態は `mktemp` ファイル) で「flock 取得完了」を同期する設計を採用。`flock -x 9 -c "sleep 30"` を直接 background させると flock 取得が完了する前に親が `sr_check_slot_lock` を呼ぶ race condition があり、ready_file の消失を最大 5 秒 poll で待つ形に整理。test 終了時に `kill $bg_pid` + `wait` で確実に背景プロセスを掃除し、後続 section に影響させない
- **Section 10 の 99999 pid 不在保証**: Linux `/proc/sys/kernel/pid_max` が 99999 を超える環境（例: 4194304）では 99999 が現役 pid である可能性があるため、pid_max を読み出して 99999 < pid_max のときは Section 10c を SKIP する判定を入れた。同様に Section 10e は fuser / lsof の binary 実在環境で「双方不在ケース」を構成できないため SKIP。SKIP 判定を入れることでテストが環境依存で false-fail しない設計
- **Section 11 の sr_is_active stub テスト構造**: 3 観点関数を bash 関数として上書きし、戻り値（`age_rc` / `lock_rc` / `sess_rc`）を 2^3 = 8 通りで網羅。test 終了時に `unset -f sr_check_*` で stub を解除し、後続 section に影響させない。`extract_function` で本物を再 source する保険も入れた（現実装では Section 11 が最終 section だが、将来 section 追加時の安全弁）

残存課題:
- task 5 で `process_stale_pickup_reaper` orchestrator から `sr_is_active` を呼ぶときに、3 観点の判定結果（age / lock / sess）を `sr_log` の出力経由でも観測できるため、orchestrator 側で重複ログを出さないこと（`sr_log "issue=#N skip ..."` 等は active 判定で十分代替可能）
- task 5 の `sr_revert_to_auto_dev` は branch を触らない（`git` を呼ばない / Req 6.2）契約があり、本 task 4 で「branch 状態を見ない」（Req 6.3）と完全に整合する。Active Decision Layer は branch を一切走査しないことを実装でも確認済み

### Task 5

採用方針: `modules/stale-pickup-reaper.sh` 末尾に新規 2 セクション（Recovery Action Layer + Orchestrator Layer）を追加し、`sr_revert_to_auto_dev` と `process_stale_pickup_reaper` を集約。1 PATCH で複数 `--remove-label` を発行する既存パターン（`issue-watcher.sh:4794` round=1 defer / `mark_issue_needs_decisions` と同型）に揃え、auto-dev 残存確認は `gh issue view --json labels` の独立 GET で行い欠落時のみ 2 回目 PATCH で `--add-label` を発行する二段構成を採用（Req 5.1〜5.3）。orchestrator は二段ガード（`sr_is_enabled` / `SR_PROCESSED_THIS_CYCLE`）+ fail-continue ループで `process_failed_recovery` と同型の構造に統一した（NFR 5.2）。

重要な判断:
- **`SR_PROCESSED_THIS_CYCLE` の初期化位置**: in-memory set はモジュール source 時に `SR_PROCESSED_THIS_CYCLE="${SR_PROCESSED_THIS_CYCLE:-}"` で空文字に初期化。bash プロセスごと再初期化されるため、cron tick → 新規プロセス起動の流れで自動的にクリアされる。watcher サイクル中に process_stale_pickup_reaper が複数回呼ばれた場合（基本ないが防衛的）でも値が継承される設計
- **idempotent check の 2 重実装**: `sr_revert_to_auto_dev` 関数内と `process_stale_pickup_reaper` orchestrator 内の両方で `SR_PROCESSED_THIS_CYCLE` を check する二重防御を採用。orchestrator 段で短絡することで gh API 呼び出しを節約しつつ、`sr_revert_to_auto_dev` を直接呼ばれるケース（テスト fixture / 将来の他経路）でも no-op 保証を維持
- **gh stub の view 識別**: Section 12 のテストでは `gh issue edit ... --remove-label ...` と `gh issue view --json labels` を 1 つの stub 関数で処理するため、引数列に `view` / `edit` / `--remove-label` / `--add-label` のどれが含まれるかで分岐する設計を採用。前任の Section 7 stub（search 文字列ベース）と異なる構造のため、Section 13 では別 stub セット（`SR13_*`）として完全に分離した
- **fixture marker の age=60m 設定**: Section 12 では実時刻ベースで age を計算する `sr_revert_to_auto_dev` のログ出力を「age=Nm」の Nm 形式で grep 検証する必要があったため、fixture marker の first_seen_at を 2026-06-22T10:00:00Z（テスト実行時刻より過去）に固定し、age が常に正の整数になる形にした
- **不正 issue 番号 reject の網羅性**: `^[0-9]+$` 検証で reject すべき値として `abc` / `12; rm -rf /` / 空文字 / 負数 `-1` / 小数 `1.5` の 5 ケースを網羅。bash `case` の `*[!0-9]*` パターンが負号・小数点・空白・記号すべてを reject 対象として扱うことを fixture で確認した（NFR 3.1 / セキュリティ規約: 数値 ID 検証）
- **process_stale_pickup_reaper の 2 段ガード分離**: gate OFF（`sr_is_enabled` rc=1）と「同サイクル重複起動」の 2 段を異なる check として分離。前者は orchestrator 起動直後の `return 0`、後者は候補ループ内の `continue` で表現する。Section 13a/13b の gh 呼び出し 0 回 assert が前者を構造的に検証する（NFR 1.1）
- **active 経路でも sr_save_marker は呼ぶ**: design.md の orchestrator 擬似コードに従い、active 判定（keep）でも marker は observing として save する（first_seen_at の起算点を残し、次サイクル以降の閾値判定が成立するようにする）。Section 13c で「active 経路でも save 1 件以上発生」を確認

残存課題:
- task 6 で本体の `REQUIRED_MODULES` 配列に `stale-pickup-reaper.sh` を追加し、call site を `process_failed_recovery || fr_warn ...` の直後に追記する作業が残る。本 task 5 時点では module の関数定義のみで本体配線がないため、cron 実行時にはまだ `process_stale_pickup_reaper` は呼ばれない（gate OFF と同じ no-op 状態 / NFR 1.1 と整合）
- task 7 で README / CLAUDE.md への反映（オプション機能一覧 + 専用節 + prefix 表）が残る。本 task で追加した env / 関数 / 状態ファイル schema を運用者ドキュメントに反映する必要がある

## AC Traceability（task 3 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 2.1 | search 文字列に `label:"claude-picked-up"` 含む | `local-watcher/test/stale_pickup_reaper_test.sh:Section 7a` |
| Req 2.2 | search 文字列に `label:"claude-claimed"` 含む | 同上 Section 7a |
| Req 2.3 | 人間判断待ち 6 ラベル（needs-decisions / awaiting-design-review / needs-quota-wait / blocked / staged-for-release / hold）の `-label:"..."` 除外を search に含む | 同上 Section 7a（6 ラベル個別 assert） |
| Req 2.4 | `-label:"claude-failed"` 除外を search に含む（failed-recovery 領分との分離） | 同上 Section 7a |
| Req 2.5 | 2 クエリ結合後 jq `unique_by(.number)` で dedup（#100 重複が 1 件に集約）+ server-side filter のみ使用 | 同上 Section 7a（dedup 3 件 assert） |
| NFR 1.2 | `--repo owner/test-repo` / `--state open` / `--limit 20` / `--json number,labels,title,url,updatedAt` の伝達 / `STALE_PICKUP_REAPER_MAX_ISSUES=5` で動的反映 | 同上 Section 7a + 7e |
| NFR 3.1 | 既存 `LABEL_*` 定数参照 / jq `--argjson limit` 経由（literal 展開しない） | 同上 Section 7a（label 文字列が定数値と一致） |
| NFR 5.2 | gh 失敗（rc≠0）/ 非 JSON 出力 / 空文字で `[]` + `sr_warn` 1 行以上 + rc=0（fail-continue） | 同上 Section 7b / 7c / 7d |
| 設計 timeout | `timeout 60` で gh 呼び出しを保護（`STALE_PICKUP_REAPER_GH_TIMEOUT` 反映） | 同上 Section 7a（SR_TIMEOUT_TRACE 検証） |

## 検証コマンド（task 3 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/core_utils.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/stale-pickup-reaper.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 116 assertions PASS
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
diff -r .claude/agents repo-template/.claude/agents   # 空
diff -r .claude/rules repo-template/.claude/rules     # 空
```

## AC Traceability（task 1 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 1.1 | `ENABLED=true で rc=0` | `local-watcher/test/stale_pickup_reaper_test.sh:Section 1` |
| Req 1.2 | `ENABLED=false / 未設定で rc=1` | 同上 Section 1 + Section 0 (`bash -c` 直接検証) |
| Req 1.3 | `True / TRUE / 1 / on / yes / typo / 空白で rc=1` | 同上 Section 1 + Section 0 (normalize_enabled) |
| Req 1.4 | env / stdout / stderr 副作用なし | 同上 Section 1b |
| Req 4.1 | THRESHOLD 既定 45 (未設定) | 同上 Section 0 (`bash -c` 直接検証) |
| Req 4.3 | THRESHOLD 不正値 → 45 | 同上 Section 0 (normalize_threshold) |
| Req 4.4 | THRESHOLD 正常整数はそのまま | 同上 Section 0 (normalize_threshold) |
| NFR 1.1 | gate OFF 既定で env 副作用なし | 同上 Section 1 (未設定 rc=1) / Section 0 (`bash -c` 既定 false) |
| NFR 1.3 | gate OFF で stderr 副作用ゼロ | 同上 Section 1b |

## AC Traceability（task 2 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 5.5 | save → load 往復で schema 全 field（issue / first_seen_at / last_seen_at / last_known_labels / status / revert_at）保持 / 状態遷移（observing → reverted） | `local-watcher/test/stale_pickup_reaper_test.sh:Section 3` |
| NFR 2.2 | 不在ファイルで `{}` fail-open / 再読込で値継承 | 同上 Section 5（不在 / 破損 fail-open） |
| NFR 2.3 | atomic rename（中間 tmp file 不残存） / ネスト dir 自動作成 / 破損ファイル後の救済 save | 同上 Section 4 + Section 5 |
| NFR 3.1 | jq `--arg` / `--argjson` 全引数 sanitize（`"` / `\` / `$` / `` ` `` / 改行 / labels 要素中の特殊文字） | 同上 Section 6 |
| 設計 sr_marker_path | 絶対パス算出 / state dir 切替で追従（遅延束縛） | 同上 Section 2 |

## 検証コマンド（task 2 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/issue-watcher.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/stale-pickup-reaper.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 91 assertions PASS
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
```

## AC Traceability（task 4 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 3.1 (観点 1) | 閾値超で rc=0 (aged) / 閾値未満で rc=1 (fresh) / 境界 45 分で rc=0 | `local-watcher/test/stale_pickup_reaper_test.sh:Section 8a, 8b, 8c` |
| Req 3.1 (観点 2) | lock file 不在 / 空 lock file / flock 保持中で 3 経路 rc 検証 | 同上 Section 9a, 9b, 9c |
| Req 3.1 (観点 3) | lock file 不在 / 自プロセス pid / 不在 pid で session 検出 | 同上 Section 10a, 10b, 10c |
| Req 3.1 (AND) | 8 通り 2^3 組み合わせで「全 0 のみ rc=1, 他は rc=0」を assert | 同上 Section 11（8 ケース） |
| Req 3.2 | 1 観点でも rc>0 のとき sr_is_active が rc=0 (keep) を返す（7 ケース assert） | 同上 Section 11 |
| Req 3.3 | 全関数 read-only / gh を呼ばない（実装で gh 参照ゼロ + テストで stub なしで動く） | `local-watcher/bin/modules/stale-pickup-reaper.sh` の Active Decision Layer（grep 確認） |
| Req 3.4 | first_seen_at 不在 / date parse 失敗 / pid 取得失敗 / flock 不在 / lock=2 (判定不能) → safe-side | 同上 Section 8d, 8e, 8f / 10d, 10e / 11（lock=2 ケース） |
| Req 3.5 | `age=N lock=N sess=N` 形式の判定根拠を 1 行ログ記録 | 同上 Section 11（ログ形式 grep assert） |
| Req 4.2 | 閾値未満で復旧対象外（rc=1 fresh） | 同上 Section 8a |
| Req 4.4 | 閾値 env 変更で判定境界も追従（10 分閾値で 5 分 fresh / 15 分 aged） | 同上 Section 8g |
| Req 6.3 | branch 状態を見ない（実装で `git` 参照ゼロ） | `local-watcher/bin/modules/stale-pickup-reaper.sh` の Active Decision Layer（grep 確認） |
| NFR 4.1 | 判定イベント種別と issue 番号 (#42) を 1 行ログ記録 | 同上 Section 11（`grep issue=#42` assert） |
| NFR 4.2 | 見送り（keep）理由の `age=N lock=N sess=N` を 1 行ログ記録 | 同上 Section 11（keep ログ件数 + 値形式 grep） |

## 検証コマンド（task 4 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/test/stale_pickup_reaper_test.sh local-watcher/bin/issue-watcher.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 144 assertions PASS (53 件追加)
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
```

## AC Traceability（task 5 範囲）

| AC | テスト | 場所 |
|----|--------|------|
| Req 3.1 (NFR 3.1) | issue 番号 `^[0-9]+$` 検証で 5 ケース（`abc` / `12; rm -rf /` / 空文字 / `-1` / `1.5`）を reject | `local-watcher/test/stale_pickup_reaper_test.sh:Section 12d` |
| Req 5.1 | 1 PATCH 内で `--remove-label claude-picked-up` を発行 | 同上 Section 12a |
| Req 5.2 | 1 PATCH 内で `--remove-label claude-claimed` を発行（同一 PATCH 内に 2 種同時） | 同上 Section 12a |
| Req 5.3 | auto-dev 残存時は `--add-label auto-dev` を呼ばない / 欠落時のみ 2 回目 PATCH で付与 | 同上 Section 12a + 12c |
| Req 5.4 | 1 行ログ（`reason=stale-pickup orphan` / `age=Nm` / `prev_labels=csv`）を `sr_log` で記録 | 同上 Section 12a |
| Req 5.5 | 同サイクル 2 回目呼び出しが idempotent no-op（gh 0 回呼ばれない）/ marker save が observing → reverted の 2 状態遷移を踏む | 同上 Section 12b + Section 13e |
| Req 5.6 | 1 回目 PATCH 失敗時 rc=1 + sr_warn 記録 / in-memory set に append しない（次サイクル再評価可）/ revert 失敗時 orchestrator も WARN を記録 | 同上 Section 12e + Section 13f |
| Req 6.1 | branch 不在でも `sr_revert_to_auto_dev` は git を呼ばない（実装で git 参照ゼロ） | `local-watcher/bin/modules/stale-pickup-reaper.sh` Recovery Action Layer（grep 確認） |
| Req 6.2 | branch 温存（`git` を呼ばない / Recovery Action Layer 全体で git 参照ゼロ） | 同上 |
| NFR 1.1 | gate OFF（`STALE_PICKUP_REAPER_ENABLED=false` / 未設定）で gh が 1 回も呼ばれない（構造的検証） | 同上 Section 13a + 13b |
| NFR 1.2 | 既存ラベル契約（claude-picked-up / claude-claimed / auto-dev）を変更せず remove / add の組み合わせのみで状態遷移 | 同上 Section 12a + 12c（追加ラベル定数なし） |
| NFR 2.1 | `SR_PROCESSED_THIS_CYCLE` in-memory set への append / case 短絡で 2 回目 no-op を実現 | 同上 Section 12a + 12b |
| NFR 3.1 | gh コマンドに `--` を伝達してオプション解釈打ち切り / 数値 ID 検証 | 同上 Section 12a + 12d |
| NFR 3.2 | secrets を含む env を Issue コメント・ログに出さない（実装で `GH_TOKEN` 等の出力ゼロ） | `local-watcher/bin/modules/stale-pickup-reaper.sh` Recovery Action Layer（grep 確認） |
| NFR 5.2 | revert 失敗時も orchestrator は rc=0 を返す（fail-continue / watcher サイクル落ちない） | 同上 Section 13f |

## 検証コマンド（task 5 範囲）

```sh
shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/bin/modules/core_utils.sh local-watcher/bin/issue-watcher.sh local-watcher/test/stale_pickup_reaper_test.sh
bash -n local-watcher/bin/modules/stale-pickup-reaper.sh local-watcher/test/stale_pickup_reaper_test.sh local-watcher/bin/issue-watcher.sh
bash local-watcher/test/stale_pickup_reaper_test.sh   # 184 assertions PASS (40 件追加 = Section 12: 25 + Section 13: 15)
bash local-watcher/test/fr_state_test.sh              # 51 assertions PASS（regression）
```

## 確認事項

なし（task 5 仕様内で完結 / 既存仕様との整合性確認済み）。

STATUS: complete
