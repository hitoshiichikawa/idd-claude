# 実装ノート (#161)

## 採用案と決定事項

オーケストレーターからの確定指示に従い、**案 A（既存表に列追加）** で実装した。

- 既存表（L1097-1124、計 2 表）に **「正規化規則」列** と **「追加 env（必須/推奨）」列** の
  2 列を追加（Req 1.1, 2.1, 2.2, 2.3, 2.4）
- 列順序: `機能 | 制御変数 | 既定 | 正規化規則 | 追加 env（必須/推奨） | 詳細 | 関連`
  （`既定` の右隣に正規化規則を置き、有効化操作の文脈を維持。詳細リンクと関連 Issue 列は末尾に温存）
- 「常時有効」表（L1146-1149）と `install.sh` runtime フラグ表（L1157-）は対象外（Out of Scope, Req 4.4）
- 既存 cron 最小例 / 個別無効化例ブロック（L1129-1142 相当）は **温存**（NFR 2.2）
- 既存 `#112` migration note ブロックも **温存**（役割が「default 反転の説明」であり今回の
  「列構造変更の説明」とは別レイヤ）

## migration note の配置

表の直前に **新規 1 段落**として配置した（既存 `#112` migration note の直後・「デフォルト有効」
表の直前）。理由:

- 既存 `#112` migration note は default 反転の事後説明であり、今回の改訂は「表構造変更」と
  役割が別 → 同一ブロックに統合せず、独立した段落として置く方が読みやすい（オーケストレーター
  からの「Developer 判断で良い」指示にも準拠）
- 直前配置により、2 表の双方に migration note の範囲が及ぶことを誤読されない

## 各機能行の env 抽出根拠

各行の **追加 env（必須/推奨）** 値は、README の Phase 別詳細セクションを正本として抽出した。
推測値は含めない（オーケストレーター指示）。

### デフォルト有効表

| 行 | 抽出元（README 行番号） | 採用した env |
|---|---|---|
| Phase A: Merge Queue Processor | L1208-1216 環境変数表 | 推奨: `MERGE_QUEUE_HEAD_PATTERN`（既定 `^claude/`）、`MERGE_QUEUE_MAX_PRS`（既定 `5`）。`MERGE_QUEUE_GIT_TIMEOUT` 等の knob は Out of Scope 規定（全数列挙しない）に従って割愛 |
| `needs-rebase` 自動再評価ループ | L1216 `MERGE_QUEUE_RECHECK_MAX_PRS` | knob のみ存在し必須・主要推奨無し → `—` |
| PR Iteration Processor | L1727-（PR Iteration セクション）/ Out of Scope 規定 | 必須無し、主要推奨無し → `—` |
| PR Iteration 設計 PR 拡張 | L2-（設計 PR 拡張 #35）/ 同上 | `—` |
| Design Review Release Processor | L2102-（#40）/ 同上 | `—` |
| Quota-Aware Watcher | L2503-（#66）/ 同上 | `—` |
| impl-resume Branch Protection | L2842-2845 環境変数表 | 推奨: `IMPL_RESUME_PROGRESS_TRACKING`（既定 `true`、`=false` で進捗追跡指示の注入のみ抑制）。`IMPL_RESUME_PRESERVE_COMMITS=false` 時の no-op 規約も併記（Req 2.4 失敗モード明示） |
| impl-resume tasks.md 進捗追跡 | L2845-2846 + Migration Note | 必須前提: `IMPL_RESUME_PRESERVE_COMMITS=true`。`=false` 時は値に関わらず注入されない（Req 2.4 / 5.3 / 5.4） |
| Stage Checkpoint Resume | L2937-（#68）/ 同上 | `—`（knob は存在するが Out of Scope 規定で割愛） |
| Stage A Verify Gate | L3088-3094 環境変数表 | 推奨: `STAGE_A_VERIFY_TIMEOUT`（既定 `600` 秒）、`STAGE_A_VERIFY_COMMAND`（未対応言語向け escape hatch） |
| Tasks Count Gate | L3261-3266 環境変数表 | 推奨: `TC_WARN_LOWER`（既定 `8`）、`TC_WARN_UPPER`（既定 `10`）、`TC_ESCALATE_LOWER`（既定 `11`）。非整数フォールバックの挙動も併記（L3268-3269） |

### opt-in 表

| 行 | 抽出元（README 行番号） | 採用した env |
|---|---|---|
| Phase B: Promote Pipeline Processor | L1371-1379 環境変数表（特に `ST_CHECK_RUN_NAME` 未設定時の WARN + skip 挙動が L1375 に明記） | **必須**: `ST_CHECK_RUN_NAME`（Req 3.1 直接対応、サイレント skip 防止の最重要 env）。推奨: `PROMOTION_TARGET_BRANCH`（既定 `main`、L1374）、`PROMOTE_MODE`（既定 `on-demand`、L1376） |
| Phase C: 並列化 | L2275-2280 環境変数表 + L2282-2283 fail モード | 推奨: `SLOT_INIT_HOOK`（L2278）、`WORKTREE_BASE_DIR`（L2279、既定 `$HOME/.issue-watcher/worktrees`）。`PARALLEL_SLOTS` 自体は 2 値 opt-in ではなく整数型のため、正規化規則欄で「整数。`1` で直列、`>=2` で並列。`0` / 負数 / 非数値 / 空文字 / 先頭ゼロは ERROR ログ + `exit 1`（サイクル中断）」を明示（オーケストレーター指示通り） |
| Phase D: Auto Rebase | L1499-1508 環境変数表 + L1501 normalization 仕様 | 推奨: `MECHANICAL_PATHS`（L1502。空のままだと全件 semantic 扱いになる挙動を併記、Req 2.4 失敗モード）。`AUTO_REBASE_MODEL` / `MAX_TURNS` 等は Out of Scope 規定で割愛 |
| Phase E: Path Overlap Checker | L1626-1628 環境変数表 + 詳細セクション全般 | 連動: `MECHANICAL_PATHS`（Phase D と共有）。オーケストレーター指示通り「PATH_OVERLAP_CHECK には連動 `MECHANICAL_PATHS`」を反映 |
| Phase 2: Per-task TDD Loop | L3411-3414 環境変数表 | 推奨: `PER_TASK_MAX_TASKS`（L3414。既定 `0`=無制限、暴走防止用）。Req 3.4 直接対応 |
| Phase 3: Debugger Subagent | L3552-3556 環境変数表 | 任意: `DEBUGGER_MODEL`（既定 `claude-opus-4-7`、L3555）、`DEBUGGER_MAX_TURNS`（既定 `40`、L3556）。Req 3.5 直接対応 |
| Feature Flag Protocol | `.claude/rules/feature-flag.md` / 既存表セル | 「env 列に env 名を誤記しない」（Req 1.5）に従い、追加 env 列は `—`。正規化規則欄に「`CLAUDE.md` の宣言節で `**採否**: opt-in` を **lowercase 厳密一致**で記述」を明示 |
| GitHub Actions ワークフロー | L658-708（README Actions 節）| 同上、env ではないため追加 env 列は `—`。正規化規則欄に「Repository Variable に `true` を厳密一致で設定」を明示 |

## 正規化規則の根拠

### 「`=false` 以外はすべて有効」型（デフォルト有効 11 行）

`#112` Migration Note（L1083-1095）に「値の解釈は **`=false` 以外はすべて有効**、空文字 / `0` /
`False` / typo はすべて `true` として扱われる」と明記されているため、これを各行で繰り返し参照
する形にした（Req 2.2 直接対応）。

例外: `IMPL_RESUME_PRESERVE_COMMITS` のみ、L2844 で「`=false` 以外（`Yes` / `1` / 空文字 /
typo / 不正値）はすべて `true` 等価」と既存表記が `Yes` / `1` を例示しているため、その例示を
温存。

### 「`=true` 厳密一致のみ有効」型（opt-in 4 行: Phase B / Phase E / Phase 2 / Phase 3）

各 Phase 詳細セクションの「`=true` 厳密一致のみ有効」等の既存記述を要約した（L1373 /
L1628 / L3413 / L3554）。Req 2.3 / 3.2 / 3.3 直接対応。

### 「`=claude` 厳密一致のみ有効」型（Phase D 1 行）

L1501「`claude` で有効化、それ以外（未設定 / `off` / `on` / `true` / typo）はすべて `off` に
正規化」を要約。Req 3.2 直接対応。

### 整数型（Phase C 1 行）

L2282-2283「正の整数として解釈できない（`0` / 負数 / 非数値 / 空文字 / 先頭ゼロ等）場合、watcher
は ERROR ログを出力してそのサイクルを中断（`exit 1`）」を 1 行に圧縮。オーケストレーター指示
の「整数。`1` で直列、`>=2` で並列」表記を採用。

### `CLAUDE.md` 宣言節 / Repository Variable（Feature Flag Protocol / Actions）

オーケストレーター指示通り、env var ではないため列ヘッダ「制御変数」名を温存しつつ、
セル本文で「`CLAUDE.md` の宣言節」「GitHub Repository Variable」と明記。Req 1.5 直接対応。

## 後方互換性チェック

- **既存 anchor の温存**（Req 5.2）: すべての `[...](#anchor)` リンクは元の anchor を維持。
  詳細セクション側の見出し ID は変更していない（README の Phase 別見出しは無編集）
- **既存 cron 最小例ブロック** （`### opt-in` 表の直後、L1129-1142 相当）: 温存。表のすぐ後ろに
  そのまま続く構造を維持（NFR 2.2）
- **既存 `#112` migration note ブロック**: 温存。今回の #161 migration note は別段落として
  独立配置（重複は無し / 役割が別）
- **env var の追加・削除・既定値変更・名称変更なし**（Req 5.1, Out of Scope）: README 文書改訂のみ
- **「常時有効」「`install.sh` runtime フラグ」表**: 列追加せず温存（Req 4.4 / Out of Scope）

## レンダリング上の注意（横スクロール）

GitHub web の table 描画は手元で動作確認できないため、以下を記録:

- 表が **5 列 → 7 列に増加** したため、列幅次第で **横スクロールが発生する見込み**
- ただし idd-claude README は元々 GitHub web 表示前提で広い表が多く（Phase 別環境変数表 4 列 +
  説明列など）、設計上の例外ではない。PM 暫定推奨でも「許容できる可能性が高い」と判断済み
- 縦方向の行高は 1 行に維持（NFR 2.1「1 機能 1 行のスキャナビリティ」）

## テスト・検証

CLAUDE.md「テスト・検証」節準拠で、本 PR の変更内容（README.md のみ）には:

- **shellcheck**: 対象外（bash スクリプト変更なし）
- **actionlint**: 対象外（workflow YAML 変更なし）
- **markdown リンク切れ目視確認**: 既存 anchor を維持（`#promote-pipeline-processor-phase-b` /
  `#auto-rebase-processor-phase-d` / `#path-overlap-checker-phase-e` /
  `#per-task-tdd-implementation-loop-21` / `#debugger-subagent-phase-3-22` /
  `#feature-flag-protocol-23-phase-4` / `#step-3-b-github-actions-をセットアップ代替` /
  各デフォルト有効機能の anchor）。表中の `[...](#...)` リンクは元のままセル位置だけが
  右に移動した形

## 受入基準への対応（要件 numeric ID 別）

| Req ID | 対応箇所 |
|---|---|
| 1.1 | 2 表の全行に「正規化規則」「追加 env（必須/推奨）」「詳細リンク」を併記 |
| 1.2 | 必須追加 env が存在しない行は `—`（em dash）で明示。空欄は不使用 |
| 1.3 | 各行の env 群（制御変数 + 追加 env）だけで「サイレント skip」を回避できるよう必須 env を `**必須**:` で強調表示 |
| 1.4 | 「デフォルト有効」「opt-in」両節の全機能行に適用 |
| 1.5 | Feature Flag Protocol / GitHub Actions の 2 行で「制御変数」セルに env ではないことを明示し、追加 env 列を `—` とした |
| 2.1 | 全行に「正規化規則」列を追加 |
| 2.2 | デフォルト有効 11 行すべてに「`=false` 厳密一致のみ無効。それ以外（空文字 / `0` / `False` / typo）はすべて有効」を併記 |
| 2.3 | Phase B / D / E / 2 / 3 の opt-in 5 行で厳密一致の文字列とそれ以外 OFF への正規化を併記 |
| 2.4 | Phase B 行で `ST_CHECK_RUN_NAME` 未設定時の「サイレント skip」、Phase D で `MECHANICAL_PATHS` 空時の「全件 semantic 扱い」、impl-resume 進捗追跡で「`IMPL_RESUME_PRESERVE_COMMITS=false` 時の no-op」を各行 1 行で明示 |
| 3.1 | Phase B 行に `ST_CHECK_RUN_NAME` を **必須** ラベル付きで明示 |
| 3.2 | Phase D 行に「`=claude` 厳密一致のみ有効、それ以外（`on` / `true` / 大文字小文字違い / typo）はすべて OFF」を明示 |
| 3.3 | Phase E 行に「`=true` 厳密一致のみ有効、`on` / `1` / `True` は OFF」を明示 |
| 3.4 | Phase 2 行に `PER_TASK_MAX_TASKS` を暴走防止 knob として明示 |
| 3.5 | Phase 3 行に `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` を任意 knob として明示 |
| 4.1 | 各機能行の「詳細」列に Phase 別セクションへの anchor リンクを 1 件以上維持 |
| 4.2 | env の完全仕様（既定値・許容値範囲）は Phase 別セクションを正本とし、一覧表側は要約に留めた |
| 4.3 | 表直前 migration note に「一覧表と詳細セクションが食い違う場合は詳細セクションを正本とする」を明示 |
| 4.4 | 「常時有効」「`install.sh` runtime フラグ」表は無変更 |
| 5.1 | env var 変更なし（README 文書改訂のみ） |
| 5.2 | 既存 anchor を破壊していない |
| 5.3 | 表直前に 1 段落の migration note を新設（列構造変更の意図を明示） |
| NFR 1.1 | 「有効化キー」「必須追加 env」「正規化規則」を一覧表内で 1 度ずつ記述 |
| NFR 1.2 | 表側は要約、Phase 別詳細セクションが正本である旨を migration note で宣言 |
| NFR 1.3 | 食い違い時は詳細セクションを正本とする旨を migration note で明示 |
| NFR 2.1 | 1 機能 1 行のスキャナビリティを維持（行の縦分割なし） |
| NFR 2.2 | 既存 cron 最小例 / 個別無効化例ブロックを温存 |
| NFR 3.1 | 説明文は日本語、env var 名 / コマンド名 / 値リテラル（`true` / `false` / `claude` / `=true` 等）は英語固定 |
| NFR 3.2 | EARS トリガーキーワードは使わず、自然な日本語の運用者向け説明 |

## 確認事項（Reviewer / 人間レビュワーへ）

以下は Developer 判断で確定したが、要件定義の「確認事項」（requirements.md L99-111）の一部を
カバーしているため、改めて明示しておく:

1. **採用案**: A（既存表に列追加）— オーケストレーター指示で確定
2. **`PARALLEL_SLOTS` の正規化規則表記**: 「整数。`1` で直列、`>=2` で並列。`0` / 負数 /
   非数値 / 空文字 / 先頭ゼロは ERROR ログ + `exit 1`（サイクル中断）」を採用。オーケストレーター
   指示の最小表記に詳細セクションの fail モード情報を 1 行で追記
3. **`IDD_CLAUDE_USE_ACTIONS` の列名**: 既存「制御変数」列名は温存し、セル本文で
   「GitHub Repository Variable。**env var ではない**」と明記する方向を採用（オーケストレーター
   指示通り）
4. **推奨 env / knob の粒度**: 各機能ごとに 0〜3 件に絞った。全数列挙はしない（オーケストレーター
   指示）
5. **migration note の配置**: 表直前に独立した 1 段落として新規追加した（既存 `#112` ブロック
   への追記ではない）。「Developer 判断で良い」指示の範囲内で、読みやすさ優先で独立配置とした

## 補足ノート

- 設計 / 実装で追加した依存ライブラリ: なし（README.md 文書改訂のみ）
- 派生タスクとして切り出すべき事項:
  - 列数増加に伴う GitHub web 表示の横スクロール挙動を実際の repo ページで確認する（手動チェック、
    本 PR の merge 後 1 度確認すれば十分）
  - 案 C（`docs/feature-flags.md` 切り出し）採用を将来検討する場合は別 Issue として起票
    （Out of Scope 規定）
- 言語方針との整合: README 本文は日本語ベース、env 名 / コマンド名 / ラベル名 / 値リテラルは
  英語固定（NFR 3.1 適合）
