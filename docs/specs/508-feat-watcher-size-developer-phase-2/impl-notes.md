# 実装ノート: #508 Model Routing Phase 2（size ラベル → Developer モデル）

> 分量が目安の 120 行を超過（132 行）。requirements.md の AC が 8 要件 × 計 41 項目あり、
> 1 要件 1 行の traceability 表だけで 31 行を占めるため（重複説明・コード転載はしていない）。

design.md / tasks.md は本 Issue には存在しない（requirements.md のみが入力・正準）。以下は
requirements.md の AC に忠実に実装した結果と、実装時に下した判断の記録。

## 変更ファイル

| ファイル | 変更内容 |
|---|---|
| `local-watcher/bin/modules/model-router.sh` | 純粋関数 `mr_extract_size_label` / `mr_resolve_dev_model` を追加（module 冒頭ヘッダも Phase 2 を反映） |
| `local-watcher/bin/modules/slot-worker.sh` | `_slot_apply_dev_model_routing` を追加し `_slot_run_issue` 冒頭から 1 回呼ぶ（family マニフェストも更新） |
| `local-watcher/bin/watcher-config.sh` | `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM`（既定は空）を追加 |
| `local-watcher/test/model_router_test.sh` | Phase 2 の近接テスト（Unit P1 / P2、Integration P3、Wiring P4）を追加 |
| `README.md` | オプション機能一覧の行 / ステージ別モデル表 / Phase 2 専用節 / Phase 1 節のリンク / ディレクトリ構成 |

`repo-template/` に `local-watcher/` は存在しない（`.claude` と `.github` のみ）ため、modules の
ミラー同期は対象外。`install.sh` は `modules/*.sh` を glob 配布するため installer 変更も不要。

## 設計判断

1. **gate 判定は Slot Runner 側に置き、Model Router には持たせない**（Req 1.7 / 1.8 / 5.2）。
   Req 1.8 が解決結果の入力を「size 値 + `DEV_MODEL` / `DEV_MODEL_SMALL` / `DEV_MODEL_MEDIUM`」に
   **限定列挙**しているため、`MODEL_ROUTING_ENABLED` を解決規則の入力に加えると決定性の定義が
   ぶれる。gate 無効時に「読み取りも解決も行わない」責務は Req 5.2 / 5.3 が Slot Runner に
   置いている。Phase 1 の `mr_persist_size_label` は副作用（gh 呼び出し）を持つため
   defense-in-depth の gate を内包しているが、純粋関数である Phase 2 の解決規則には同じ理由が
   成り立たないと判断した（テスト P2-8 で「gate 値に依存しない」ことを固定）。
2. **ラベル読み取りを純粋関数として model-router.sh 側に分離**（`mr_extract_size_label`）。
   Req 3.2〜3.5 の判定（0 件 / 2 件以上 / 厳密一致失敗）を `_slot_run_issue` の巨大関数内に
   inline すると近接テストで検証できないため、判定を rc（1/2/3）で返す純粋関数に切り出し、
   適用と log のみを slot 側の小関数に置いた。これにより Req 8.5 / 8.6 / 8.7 が
   `extract_function` の既存イディオムで直接検証できる。
3. **正規表現照合に外部コマンドを使わない**。`^size:(small|medium|large)$` は bash `case` の
   完全一致で表現し、未信頼なラベル名を `grep` 等へ一切渡さない（NFR 3.1 / 3.2）。結果として
   `--` によるオプション解釈打ち切りが不要な構造になった（Phase 1 の `gh --add-label=` 逸脱と
   同種の落とし穴を最初から回避）。
4. **差し込み位置は `LABELS` 確定直後ではなく `exec > >(tee -a "$SLOT_LOG")` の直後**
   （`slot_log "Worker 起動"` の次行）。理由は (a) ログを cron ログと slot ログの双方に残すため
   （Req 6.3）、(b) worktree 初期化・Triage よりは前で「slot 起動時点のラベル集合」の意味を
   保てるため（Req 3.1 / 4.1）。テスト P4-7 で「LABELS 行より後・`_worktree_ensure` より前」を
   構造的に固定した。
5. **fallback 理由をログに出す**（Req 6.2）。size 表示は固定トークン（`none` / `multiple` /
   `invalid`）のみで、未信頼なラベル生値はログへ出さない（NFR 3.3 / テスト P3-6 で固定）。
6. **`DEV_MODEL` が空という想定外状態では再代入しない**（fail-open / Req 5.6）。WARN を 1 行
   残して処理を継続する。

## AC トレーサビリティ

| 要件 | 担保するテスト（`local-watcher/test/model_router_test.sh`） |
|---|---|
| 1.1 / 1.2 / 1.3 | P2-1（3 値 × 対応設定あり）/ P2-4（片側設定の独立性） |
| 1.4 | P2-2（`huge` / `SMALL` / 空 / 引数省略 → `DEV_MODEL`） |
| 1.5 | P2-3（空文字 / unset）/ P3-3（二重 opt-in） |
| 1.6 | P2-5（未知のモデル ID をそのまま返す） |
| 1.7 | P2-7（gh 0 回 / ログ 0 行 / 入力変数を書き換えない）/ P1-5 |
| 1.8 | P2-6（同一入力 → 同一出力）/ P2-8 / P3-9（冪等） |
| 2.1 / 2.2 | P4-1（既定空の宣言行）/ P4-2（モデル ID 非埋め込み） |
| 2.3 | P3-3（gate 有効 + 設定なし → `DEV_MODEL`） |
| 2.4 / 2.6 | P4-4（`DEV_MODEL` 宣言行の不変） |
| 2.5 | P4-3（追加は 2 個のみ / `DEV_MODEL_LARGE` なし） |
| 3.1 | P3-2（適用）/ P4-7（call site が LABELS 確定後） |
| 3.2 | P1-1（厳密一致 3 種 / 無関係ラベル混在） |
| 3.3 | P1-2 / P3-4（size ラベルなし → `DEV_MODEL`） |
| 3.4 | P1-3 / P3-5（`size:*` 複数 → `DEV_MODEL`） |
| 3.5 | P1-4 / P3-6（`size:huge` / `size:Small` / 末尾空白 / 注入狙い） |
| 3.6 | P3-8（サブシェル内で解決結果が有効）/ P4-7（worktree 初期化前の 1 回解決） |
| 3.7 | P3-8（親プロセスの `DEV_MODEL` 不変） |
| 3.8 / 3.9 | P4-6（適用ヘルパー / model-router.sh が他の `*_MODEL` を参照しない） |
| 4.1 | P4-7（call site 1 箇所）/ P3-9 |
| 4.2 / 4.3 | P4-8（call site が Triage 消費部より前 = 再解決しない） |
| 4.4 / 4.5 / 4.6 | P3-2（起動時ラベルに `size:*` があれば適用。3 経路とも同一コードパス） |
| 5.1 | P4-5（gate は `mr_is_enabled` のみ / 独自 gate 変数なし）/ 既存 W4 |
| 5.2 / 5.3 | P3-1（gate 8 表現 + unset で `DEV_MODEL` 据え置き・ログ 0 行・外部コマンド 0 回） |
| 5.4 | P3-1（`True` / `TRUE` / `1` / `on` / typo を安全側へ正規化） |
| 5.5 | P4-9（`--model "$DEV_MODEL"` call site 不変）/ P4-4 |
| 5.6 | P3-7（解決結果が空 → 据え置き + WARN 1 行 + rc=0） |
| 6.1 | P3-2（Issue 番号 / size 値 / モデル ID の 3 項目を 1 行に含む） |
| 6.2 | P3-3 / P3-4 / P3-5 / P3-6（`fallback=DEV_MODEL` と理由） |
| 6.3 | 差し込み位置（`exec > >(tee -a "$SLOT_LOG")` 直後 / `mr_log` は既存 processor と同一経路） |
| 6.4 | 各ケースの「ログは 1 行」アサーション / P3-7（WARN 1 行） |
| 7.1〜7.6 | README（オプション機能一覧 / ステージ別モデル表 / Phase 2 節 / 実装と同一 PR） |
| 8.1〜8.7 | 下記「検証結果」/ P1〜P4 一式 |

## 検証結果

| コマンド | 結果 |
|---|---|
| `bash -n`（変更 4 ファイル） | すべて OK（AC 8.2） |
| `shellcheck local-watcher/bin/*.sh local-watcher/bin/modules/*.sh install.sh setup.sh .github/scripts/*.sh` | 警告ゼロ（AC 8.1） |
| `shellcheck local-watcher/test/model_router_test.sh` | 警告ゼロ |
| `bash local-watcher/test/model_router_test.sh` | PASS 309 / FAIL 0（Phase 1 の 146 を含む。Phase 2 で 163 追加） |
| `local-watcher/test/*.sh` 全 99 本 | 98 pass / 1 flaky（下記） |
| `diff -r .claude/agents repo-template/.claude/agents` / `.claude/rules` | 差分なし |

- **Red → Green 確認**: 実装を一時的に壊して（small 解決を `DEV_MODEL` 固定 / 複数ラベル
  fail-safe の閾値変更 / gate 判定の除去）24 件が FAIL することを確認し、復元後 0 FAIL に
  戻ることを確認した。
- **flaky（本変更とは無関係 / 既存）**: `publish_terminal_failure_artifacts_test.sh` が
  数回に 1 回 rc=141（SIGPIPE）で終了する。FAIL アサーションは 0 件で、`printf ... | grep -q`
  イディオムと `pipefail` の組み合わせに起因する既存の不安定性。**変更前の HEAD を別 worktree に
  展開して同様に再現する**ことを確認済み（本 PR の変更は pr-reviewer 系に一切触れていない）。

## Open Questions への対応状況

| Open Question | 対応 |
|---|---|
| 適用タイミングのギャップの受容可否（最重要） | requirements.md の暫定採用（受容 / Req 4.2 の既知の制約）に従って実装。Triage 後の再解決は行っていない。README に「⚠️ 初回 Triage 経路では効きません」と効く 3 経路を明記した。**人間判断は未確定**（下記「確認事項」1） |
| design セッションへの適用可否 | Req 3.6 に従い design セッションにも適用（除外していない）。README「適用範囲」に design セッションを含むと明記した |
| `DEV_MODEL_LARGE` を将来追加するか | 本 Phase では追加しない（Req 1.3 / 2.5）。additive で追加できる形は維持（`mr_resolve_dev_model` の `large` 分岐にコメントで明示） |
| 既定値を空にする判断の是非 | requirements.md の二重 opt-in を採用（既定空 / モデル ID 非埋め込み） |
| 誤付与ラベルの運用手順 | README Phase 2 節に「ラベルを剥がす → 次回 Triage で再付与」を Phase 2 固有の注意として再掲した |
| fallback 時のログ粒度 | 可観測性優先で 1 行出力（Req 6.2）。`fallback=DEV_MODEL` で機械的に絞り込める形式にした |

## 確認事項（レビュワー判断ポイント）

1. **初回 Triage 経路で routing が効かない件**（requirements.md 最重要 Open Question）。本実装は
   Issue 本文および Req 4.1〜4.3 の指示どおり「slot 起動時点の 1 回解決」で確定しており、
   Triage 直後の再解決は行っていない。実運用で最も多い経路（新規 Issue の Triage → 実装）では
   コスト削減効果が出ないため、**Triage 直後の再解決を別 Issue として起票するかどうか**は
   人間判断が必要。
2. **`_slot_apply_dev_model_routing` を slot-worker.sh に置いた分割**。Issue の指示は
   「`_slot_run_issue` 冒頭に差し込み」だったが、近接テスト（Req 8.5 / 8.6 / 8.7）が
   `_slot_run_issue` 全体を隔離抽出できないため、gate + 適用 + ログを小関数へ切り出し
   call site を 1 行にした。要件上の subject（Slot Runner）と実装ファイルは一致している。
3. **fallback ログのノイズ**。gate 有効かつ size ラベル未付与の Issue が大半の環境では
   `fallback=DEV_MODEL` 行が毎 Issue 出る。requirements.md の可観測性優先方針に従ったが、
   運用開始後にノイズが問題になれば出力条件の見直しを別 Issue で検討したい。
4. **`size:large` に対する `DEV_MODEL_LARGE` 不在**。`large` は `DEV_MODEL` 固定のため、
   将来 `large` だけ別モデルにしたくなった時点で `DEV_MODEL` の位置づけ（既定値か `large` 専用か）
   の再定義が必要（requirements.md の Open Question をそのまま残置）。

STATUS: complete
