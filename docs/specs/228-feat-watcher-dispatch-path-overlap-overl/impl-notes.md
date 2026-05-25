# 実装ノート（#228 dispatch 見送りの可視化）

## 概要

dispatch 見送り（path-overlap / 多忙サイクル待ち / overlap 取りこぼし）を Issue 上に必ず
可視化する。Requirement 1（path-overlap 見送りコメント）・Requirement 2（prefix 欠落の
overlap 検出頑健性）は既存実装（#187 / #221）で既に成立しているため**回帰検証**で担保し、
Requirement 3（多忙サイクル待ちの可視化）を新規実装した。本機能は既存 `PATH_OVERLAP_CHECK=true`
の opt-in gate 配下でのみ動作する。

## 変更ファイル

- `local-watcher/bin/modules/promote-pipeline.sh` — 多忙サイクル待ち可視化の関数群を追加
  （`po_busy_wait_state_dir` / `po_busy_wait_tick` / `po_busy_wait_reset` /
  `po_apply_busy_wait_signal` / `po_check_busy_wait`）。既存 po_* 関数は無変更。
- `local-watcher/bin/issue-watcher.sh` — (1) 新 env var `PATH_OVERLAP_BUSY_WAIT_THRESHOLD`
  の Config 定義を追加、(2) dispatcher の busy-wait 経路（空き slot 確保失敗で当該サイクルを
  見送る地点 / `if [ -z "$slot" ]`）に `po_check_busy_wait` を配線、(3) dispatch 成功見込み
  時に `po_busy_wait_reset` を配線。
- `README.md` — 「Path Overlap Checker (Phase E)」節に env var 行・「多忙サイクル待ちの
  可視化（#228）」サブセクション・観測ログ例・Migration Note を追加。
- `docs/specs/228-feat-watcher-dispatch-path-overlap-overl/test-dispatch-visibility.sh` —
  スモークテスト（新規）。

## Open Questions の決定内容（requirements.md 末尾）

### 1. 可視化閾値・単位・永続化方法

- **新 env var**: `PATH_OVERLAP_BUSY_WAIT_THRESHOLD`（既存命名規約 大文字スネーク、
  `"${VAR:-default}"` で override 可能）。
- **既定値**: `5`。**単位は cron tick 数**（経過時間ではなく「見送りが観測された連続
  サイクル数」）。cron 間隔 `*/2` 分なら 5 tick ≒ 10 分相当で、transient（数 tick で解消）を
  確実に除外するノイズ抑制側の保守的値。
- **フォールバック**: `0` / 空 / 非数値は安全側（連投しない）で既定 `5` に倒す。
- **継続待機判定状態の永続化**: **ローカル state ファイル** `$LOG_DIR/busy-wait-state/issue-<N>.tick`
  に連続見送り tick 数（整数）を持つ。GitHub API を一切呼ばずに継続 tick を数えるため、
  in-flight 列挙回数・edit_paths 読み出し回数を本機能導入前から増やさない（NFR 4 厳守）。
  `LOG_DIR` は repo ごとに分離済みのため repo 間で衝突しない。dispatch 成功時に
  `po_busy_wait_reset` で state ファイルを削除し、次に再び見送られたら 1 から数え直す。

### 2. 可視化シグナルの実現手段

- 既存 `awaiting-slot` ラベルを**流用**（path-overlap 見送りと共有）。これにより既存の
  自然解消経路（`po_clear_awaiting_slot`）がそのまま busy-wait 由来の `awaiting-slot` も
  解消でき、Req 3.3 のシグナル除去を追加コードなしで満たす。
- sticky comment は**専用 marker** `<!-- idd-claude:busy-wait:v1 -->` で 1 件に集約。
  既存 `awaiting-slot:v1` / `edit-paths:v1` marker とは別管理のため、既存マーカー契約は
  一切変更しない（Req 5.3）。

### 3. flock レベル cron tick skip 時の対象範囲

- 別インスタンスが flock を握って tick 全体が skip される間は、そのインスタンスは何も
  評価しないためシグナルを残せない（実装上不可能）。可視化は「次に flock を取得して
  dispatch ループを回せたインスタンス」が、空き slot 不足で見送った候補に対して連続 tick を
  数え直し、閾値到達時に行う形にした。
- 全 slot を別インスタンスが lock している状況（`_dispatcher_find_free_slot` が全 slot で
  失敗し `slot=""` で次サイクルへ持ち越す経路）も同一の busy-wait 経路で可視化される。
- 対象範囲は「当該サイクルで dispatch 評価され、全 gate 通過後に空き slot を確保できなかった
  候補」（= 次サイクル先頭候補に限定せず、評価された各候補）。これは実装上の自然な単位で、
  全 open candidate を別途列挙する追加 API 呼び出しを増やさない（NFR 4）。

## 実装上の判断

- **既存の path-overlap 見送りコメント（Req 1）と多忙サイクル待ち（Req 3）を別 marker で
  分離**: path-overlap は「path が重複している」理由、busy-wait は「slot 不足」理由で本文が
  異なるため、同一 sticky に混ぜず別コメントにした。両者とも `awaiting-slot` ラベルは共有。
- **Req 1.4（ラベル付与失敗でもコメント継続）は既存 `po_apply_awaiting_slot`（#187）で
  既に成立**。busy-wait 側 `po_apply_busy_wait_signal` も同方針でラベル失敗時にコメント投稿を
  継続する。
- **Req 2 は #221 の normalize（top-level 粒度突合）で成立済み**。`po_compute_overlap` は
  candidate / holder 双方を同一 `normalize` 関数で top-level 化して突合するため、prefix 付き
  full path が holder top-level と一致するケース・ルート直下ファイルの一致を検出できる。
  #221 実例（candidate `["modules/","README.md"]` 予測）では `modules` vs `local-watcher` は
  top-level 不一致だが、共通の `README.md` が overlap として残るため「false-negative で
  見送りもコメントも一切出ない」事故は再発しない（回帰テストで担保）。

## 新 env var とデフォルト

| env var | 既定 | 単位 | 有効化条件 |
|---|---|---|---|
| `PATH_OVERLAP_BUSY_WAIT_THRESHOLD` | `5` | cron tick 数（連続見送りサイクル数） | `PATH_OVERLAP_CHECK=true` のときのみ作用。`0` / 空 / 非数値は既定 5 にフォールバック |

## Test plan

### 静的解析

- `shellcheck -S warning local-watcher/bin/issue-watcher.sh local-watcher/bin/modules/promote-pipeline.sh docs/specs/228-.../test-dispatch-visibility.sh`
  → warning/error レベル **0 件**（既存の SC2317 info はロガー間接呼び出しに対する既存
  指摘で本変更とは無関係）。
- `bash -n` で main / module ともに構文 OK。

### スモークテスト

- `bash docs/specs/228-feat-watcher-dispatch-path-overlap-overl/test-dispatch-visibility.sh`
  → **PASS=29 FAIL=0**。gh をスタブ化し実 API を呼ばずに検証。state ディレクトリは
  `mktemp -d` で隔離。

### 既存回帰

- `bash docs/specs/221-feat-watcher-path-overlap-holder-base-de/test-fixtures/test-holder-labels.sh`
  → **PASS=8 FAIL=0**（#221 の holder ラベル集合・search_query ゼロ差分が無回帰）。

## 受入基準 → テスト対応表

| AC | 担保 |
|---|---|
| Req 1.1 / 1.2 / 1.3 | 既存 `po_apply_awaiting_slot`（#18 / #187）で成立済み。`po_check_dispatch_gate` の overlap 検出経路で sticky comment 投稿 + `awaiting-slot` 付与 + holders 表形式表示（既存テスト・本実装で無変更）。 |
| Req 1.4（ラベル付与失敗でもコメント継続） | 既存 `po_apply_awaiting_slot`（#187）で成立。busy-wait 側 `po_apply_busy_wait_signal` も同方針。 |
| Req 2.1（prefix 欠落 top-level 一致で検出） | test: 「full path candidate が holder top-level と一致」「ルート直下ファイル top-level 一致」「#221 回帰: prefix 欠落 modules/ 不一致でも共通 README.md が overlap」 |
| Req 2.2（false-negative 時も Req 1 成立） | Req 2.1 回帰ケースで overlap が非空になることを担保（overlap 非空 → `po_check_dispatch_gate` が既存経路で Req 1 を発火）。 |
| Req 2.3（candidate/holder 同一正規化） | test:「./ 連続スラッシュの揺れを同一 normalize で吸収」「candidate/holder 双方を同一規約で top-level 化」 |
| Req 2.4（candidate 空配列は阻止しない） | test:「candidate 空配列は overlap 空」 |
| Req 3.1（slot 不足で閾値超過継続なら可視化） | test:「tick が 1→2→3 単調増加」「閾値到達で可視化シグナル発生」 |
| Req 3.2（別インスタンス稼働でも可視化） | 同一 busy-wait 経路で可視化（`_dispatcher_find_free_slot` 全失敗 = `slot=""` も同経路）。test の tick/閾値判定で担保。README に対象範囲を明記。 |
| Req 3.3（要因解消でシグナル除去/更新） | dispatch 成功時 `po_busy_wait_reset`（test:「reset 後 tick 1 から」）+ 既存 `po_clear_awaiting_slot` でラベル除去。 |
| Req 3.4（閾値未満は可視化なし） | test:「閾値未満では gh 呼び出し発生しない」「閾値 0/非数値は既定 5 にフォールバック」 |
| Req 4.1 / 4.2（冪等・1 件集約） | `po_apply_busy_wait_signal` が marker 検索 → PATCH/create で 1 件集約。test:「state ファイルは 1 件に保たれる」 |
| Req 4.3（解消時ラベル除去） | 既存 `po_clear_awaiting_slot`（無変更）。 |
| Req 4.4（解消時コメント更新/残置） | busy-wait sticky comment は事後監査用に残置（既存 `po_clear_awaiting_slot` 方針と整合）。README 明記。 |
| Req 5.1 / 5.2（off で完全 no-op） | test: 7 種の非 true 値（off / 空 / false / 0 / True / 1 / enabled）で gh 呼び出しゼロ・state ファイル非生成。 |
| Req 5.3（既存マーカー契約不変） | 新 marker `busy-wait:v1` を別管理。既存 `awaiting-slot:v1` / `edit-paths:v1` 無変更。 |
| Req 5.4（env var / ラベル遷移契約不変） | 既存 env var / ラベル名は無変更。新 env var 追加のみ。 |
| Req 5.5（single-branch で overlap 判定不変） | #221 既存テストで holder 集合・search_query ゼロ差分を担保（無回帰確認）。 |
| NFR 1.1 / 1.2（ノイズ抑制） | 閾値未満は無音。1 見送り状態 = sticky 1 件（marker 集約）。test で担保。 |
| NFR 2.1 / 2.2（冪等・再試行） | state ファイル 1 件収束（test）。投稿失敗時は次 tick で再試行（marker 検索で重複生成しない）。 |
| NFR 3.1 / 3.2（可観測性） | `po_check_busy_wait` / `po_apply_busy_wait_signal` が tick / threshold / reason を含む 1 行ログを stdout に出力。README 観測ログ節に明記。 |
| NFR 4.1 / 4.2（API 呼び出し増やさない） | tick カウントはローカル state ファイルのみ（GitHub API 不使用）。test:「tick カウントは GitHub API を一切呼ばない」。in-flight 列挙・edit_paths 読み出しは既存経路のまま増やさない。 |

## 確認事項

- **path-overlap 見送りの「sticky comment 連投防止」（Req 4 全般）**: 既存
  `po_apply_awaiting_slot` は `awaiting-slot` 未付与時のみ呼ばれる（`po_check_dispatch_gate`
  の `[ -z "$has_awaiting" ]` 分岐）ため、overlap 継続中は 2 回目以降コメント更新されない
  既存挙動を踏襲した。busy-wait 側は毎回 PATCH 更新で tick 数を反映する（連投ではなく
  同一コメントの更新）。本機能の範囲では既存 path-overlap コメントの更新頻度は変えていない。
- **多忙サイクル待ちの「対象 Issue の一意特定」（Open Question 3）**: 実装上、別インスタンスが
  flock skip 中の tick ではシグナルを残せない点は構造的制約であり、本実装では「次に評価
  できたインスタンスが継続待機を検出して可視化する」形に倒した。これは要件 Req 3.2 の
  「待機対象 Issue へシグナルを残す」を満たすが、skip された tick 数そのものは（評価して
  いないため）tick カウントに含まれない。運用上はノイズ抑制側に倒した保守的な挙動であり、
  人間判断を要する矛盾ではないと判断した（impl-notes に記録）。

## STATUS

全タスク（Req 1〜5 / NFR 1〜4）の実装・回帰検証・テスト・README 更新を完了。

STATUS: complete
