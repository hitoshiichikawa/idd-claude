# 実装ノート（#520 / Stale Pickup Reaper セッション判定の誤 safe-side 修正）

## 概要

`sr_check_session`（`local-watcher/bin/modules/stale-pickup-reaper.sh`）のセッション存在
判定を修正した。従来は「観測手段（fuser/lsof）が利用可能でありながら保持者を 1 件も返さない」
状態を根拠取得失敗として safe-side（`sess=1`）に倒していたため、flock 方式の残存 lock file が
1 度でも残ると reaper が当該 repo で永久に機能しなかった（feedman#223 / #234）。

本修正で当該状態を「保持者が既に死んでいる = 孤児」寄り（`sess=0`）に扱い、safe-side
fallback は「観測手段（fuser/lsof）自体が不在」のときに限定した（#379 Req 3.4 の適用範囲修正）。

## 実装方式（判定マトリクス）

`sr_check_session` の分岐（`stale-pickup-reaper.sh:sr_check_session`）:

- lock file 不在 → `return 0`（reason=`no-lockfile`）
- fuser/lsof 双方不在 → `return 1`（reason=`tool-absent` / safe-side 維持）
- ツール利用可能で全 lock file を走査:
  - 保持者問い合わせが空 → 早期 return せず次 lock file へ継続（**修正核心**。旧 `return 1` を撤去）
  - 生存 pid を 1 件でも検出 → `return 1`（reason=`holder-alive`）
  - 取得 pid が全て非生存 → 継続
  - 走査完了で生存保持者なし → `return 0`（reason=`no-holder`）

判定理由は新規グローバル `SR_SESSION_REASON` に surface し、`sr_is_active` が既存 `sess=N` の
直後に `sess_reason=<token>` を **別フィールド**として 1 行ログに追記する（既存 `age`/`lock`/`sess`
のフィールド名・形式は不変 / NFR 3.3）。`sess=N` を機械パースする箇所は本テストの
`grep -qE 'age=[0-9]+ lock=[0-9]+ sess=[0-9]+'` のみで、末尾追記により非破壊であることを確認済み。

## AC トレーサビリティ（1 要件 1 行）

| AC | 担保テスト（`local-watcher/test/sr_activity_check_test.sh`） |
|---|---|
| Req 1.1 | 10d（空 fuser → rc=0）/ 10f（累積で無保持を継続） |
| Req 1.2 | 10c（非生存 pid → rc=0 / pid_max により当環境 skip、Section 11 で AND 側担保）+ 10d |
| Req 1.3 | 10a（lock file 不在 → rc=0 / reason=no-lockfile） |
| Req 2.1 | 10b（生存 pid → rc=1 / reason=holder-alive） |
| Req 2.2 | 10f（無保持 + 生存保持者の複数 lock file → rc=1） |
| Req 3.1 | 10e（binary 実在時 skip）+ 10g（PATH 空で決定論的に rc=1 / tool-absent） |
| Req 3.2 | 10g（tool-absent 経路のみ safe-side）/ Section 10d が no-holder を safe-side 除外 |
| Req 4.1 | Section 11（`age=N lock=N sess=N` 形式維持）+ 10h（sess=N 保持） |
| Req 4.2 | 10b + 10h（sess_reason=holder-alive をログ追記） |
| Req 4.3 | 10d + 10h（sess_reason=no-holder をログ追記） |
| Req 4.4 | 10g + 10h（sess_reason=tool-absent をログ追記） |
| Req 5.1 | Section 11 全 0 → inactive（3 観点 AND）/ 既存 `sr_recovery_action_test.sh` Section 13 |
| Req 5.2 | Section 10d/10f が「無保持 lock file の存在のみで固定しない」を担保 |
| Req 6.1 | 10d（無保持残存 lock file fixture → sess=0） |
| Req 6.2 | 10b（実プロセス保持中 → sess=1） |
| Req 6.3 | 10d（Section 10d 期待値を rc=1→rc=0 へ反転 / テスト内コメントで #520 明示） |
| NFR 1.1 | Section 11 の 8 通り AND（生存保持者・fresh・lock 保持で keep=誤回収ゼロ） |
| NFR 2 | fuser/lsof 双方が同一下流ロジック（空→継続 / pid→kill -0）を通る構造で同一判定 |
| NFR 3.1〜3.3 | marker_age/slot_lock/AND 契約・env/label/prefix/フィールド名を不変（本修正は session のみ） |
| NFR 4.1 | `bash -n` / `shellcheck` クリア（下記） |
| NFR 4.2 | README「アクティブセッション判定」節を safe-side 限定の語義へ更新 |

## 検証結果（サマリ）

- `bash -n local-watcher/bin/modules/stale-pickup-reaper.sh` → OK
- `bash -n local-watcher/test/sr_activity_check_test.sh` → OK
- `shellcheck local-watcher/bin/modules/stale-pickup-reaper.sh` → 警告ゼロ（.shellcheckrc baseline 尊重）
- `sr_activity_check_test.sh` → PASS=40 FAIL=0
- `sr_recovery_action_test.sh` → PASS=40 FAIL=0
- `sr_wiring_test.sh` → PASS=61 FAIL=0
- `sr_marker_state_test.sh` → PASS=64 FAIL=0
- `diff -r .claude/agents repo-template/.claude/agents` → 空（未変更）
- `diff -r .claude/rules repo-template/.claude/rules` → 空（未変更）

## 環境依存の skip（既存挙動 / 本修正前と同一）

- 10c: `pid_max=4194304 > 99999` のため大値 pid の不在保証不可で skip。全 pid 非生存経路は
  Section 11 の AND 判定で担保。
- 10e: fuser/lsof binary が当環境に実在するため関数 stub 経路を構成できず skip（既存仕様）。
  tool-absent 経路は 10g（PATH 空サブシェル）で全環境決定論的に担保するよう追加した。

## 確認事項

- なし。requirements.md（唯一の正準ソース）と矛盾なく実装できた。design.md / tasks.md は
  本 spec dir に存在せず（バグ修正のため Architect 不介在）、単一実装パスで完了した。

STATUS: complete
