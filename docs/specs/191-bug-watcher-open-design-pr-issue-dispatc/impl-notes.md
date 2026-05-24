# 実装ノート（Issue #191）

## 実装サマリ

design フェーズの Issue が open な design PR（`claude/issue-<N>-design-*` head）を持って
いるのに保護ラベル（`awaiting-design-review` / `blocked`）が外れていると、watcher が当該
Issue を再 pickup して design モードを再実行し、PjM が人間レビュー済み design PR をクローズ
して作り直す事故（#180 / PR #184）が起きていた。本実装では claim 直前ガードに「open な
design PR が存在すれば触らない」最後の砦を追加し、ラベル保護が外れても design PR が破壊的に
再生成されないことを担保する。

design.md / tasks.md は本 Issue では生成されておらず（Architect 非起動の bug fix）、
`requirements.md` を正本として直接実装した。

## 変更ファイル

- `local-watcher/bin/issue-watcher.sh`
  - `check_open_design_pr` 関数を新規追加（`check_existing_impl_pr` 直後 / 旧 9967 行付近）
  - candidate ループの Pre-Claim Filter 呼び出し（`check_existing_impl_pr` の直後）に
    `check_open_design_pr` 呼び出しを追加
- `README.md`
  - Pre-Claim Filter の運用ガイド節（`claude-failed` 手動復旧手順内）に「open design PR
    ガード（Issue #191 以降）」の説明と暫定運用ガイド（保護ラベルを design PR merge まで
    外さない）を追記（NFR 2.1）

## 追加したガードの検出方式

- **既存ガードとの分離**: 既存 `check_existing_impl_pr` は GraphQL
  `closedByPullRequestsReferences`（GitHub が auto-close キーワード `Closes`/`Fixes`/
  `Resolves` でのみ収集 → impl PR に集約される逆引き field）から impl PR のみを skip 対象とし、
  design PR は `reason=design-pr-in-closing-refs` で明示的に ignore する。よって open design
  PR の存在は impl ガードでは抑止できない。本実装はラベル保護とも impl ガードとも独立した
  新ガードとして追加（二重防御 / Req 2）。
- **linked 非依存の head ref 検出（Req 1.4）**: PjM の design PR テンプレートは `Refs #N`
  （auto-close キーワードではない）を使うため、design PR は Issue に GitHub 上 linked とは
  限らない。そこで既存 `drr_find_merged_design_pr`（#40 / #80）と同方式で
  `gh pr list --state open --search "is:pr is:open claude/issue-<N>-design- in:head"` により
  head ref ベースで検出する。linked か否かに依存しない。
- **strict prefix による厳密一致（Req 1.5）**: GitHub の text search はトークン分解
  （"claude" / "issue" / "N" / "design"）で他 Issue 用 design PR もヒットさせる（noisy）。
  そこで server-side は候補取得に留め、最終一致は jq で
  `headRefName | startswith("claude/issue-<N>-design-")` の strict prefix 判定を行う。
  これにより `#19` の探索が `claude/issue-191-design-*` を誤検出しない（境界スモークで確認済み）。
  複数件マッチ時は PR 番号最大（= 最新）を採用。
- **OPEN 限定（Req 1.3）**: `--state open` を server-side で指定しているため、CLOSED/MERGED の
  design PR は jq フィルタに到達しない。open な design PR が存在しないケースでは
  `reason=no-open-design-pr` で `continue`（exit 0）する。

## fail-safe の倒し方（Req 3）

- `gh pr list` の非ゼロ終了（API 失敗 / timeout）→ skip（exit 1）。レート制限は
  `reason=design-pr-probe-rate-limited`、それ以外は `reason=design-pr-probe-failed` で記録。
- jq parse 失敗 → skip（exit 1、`reason=design-pr-probe-jq-parse-error`）。
- 入力 Issue 番号が空 / 非数値 → skip（exit 1、`reason=invalid-issue-number-design-guard`）。
- 既存 `check_existing_impl_pr` の「失敗はすべて skip 側に倒す」方針と整合させた。
- GitHub API 呼び出しは既存 `DRR_GH_TIMEOUT`（既定 `MERGE_QUEUE_GIT_TIMEOUT` → 60 秒）で
  ラップ。新規 env var は追加していない（NFR 1.2 / 1.3）。

## 可視性（Req 4）

- skip / continue 判定は既存 Pre-Claim 系の `pclp_log` / `pclp_warn`（prefix
  `pre-claim-probe:`）で 1 行 `key=value` 形式で出力。
- skip 時は `skip issue=#<N> pr=#<P> reason=open-design-pr-exists` の形式で Issue 番号・
  検出した PR 番号・理由を機械可読に含む。

## 非干渉・後方互換

- 本ガードは candidate ループ（Issue pickup 経路）の `check_existing_impl_pr` の直後にのみ
  挿入。`PR_ITERATION_DESIGN_ENABLED` 等の PR 駆動 design 反復経路には一切触れていない（Req 5）。
- design PR を持たない通常 Issue では `gh pr list` 結果が空 → `continue`（exit 0）で
  本機能導入前と等価（NFR 1.1）。env var 名 / exit code 意味 / ラベル契約 / cron 登録文字列 /
  ログ出力先は不変（NFR 1.2）。

## 実施した検証と結果

- `shellcheck local-watcher/bin/issue-watcher.sh`:
  - `-S warning` で実行 → 警告・エラー **0 件**（exit 0）。
  - info レベルの `SC2317`（unreachable / 間接呼び出し）は本変更前から存在する既存メッセージで、
    新規追加箇所（新関数・呼び出し）には info も含めて新規指摘なし（行範囲を grep で確認）。
- cron-like 最小 PATH の依存解決:
  `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c 'command -v gh jq flock git'` → 全解決（rc=0）。
- strict head 一致の境界スモーク（jq フィルタを抽出した bash 関数で検証、全 PASS）:
  - `#19` 探索が noisy 候補集合（`#19` head と `#191` head 混在）から `#19` の PR のみ採用、
    `#191` は誤検出しない。
  - `#191` 探索が同集合から `#191` の PR のみ採用。
  - 空配列 → 採用なし（continue）。
  - impl head のみ → design 一致なし（continue）。
  - 同一 Issue の複数 open design PR → 最大 PR 番号（最新）採用。
  - `headRefName: null` → 防御して採用なし。
- dry run（`REPO=owner/test ... issue-watcher.sh`）: 実 `gh` 認証・ネットワーク依存のため
  本環境では未実施。検出ロジックは上記関数抽出スモークで境界を確認した。

## 受入基準とテスト・実装の対応

| AC | 担保方法 |
|---|---|
| 1.1 open design PR 存在時に dispatch skip | `check_open_design_pr` が `reason=open-design-pr-exists` で exit 1 → candidate ループで `continue`。境界スモークで open 検出を確認 |
| 1.2 保護ラベルなしでも design 再実行を起動しない | ガードはラベルと独立に head ref で検出。ラベル除外より後段の claim 直前で必ず評価 |
| 1.3 CLOSED/MERGED のみなら skip せず後続へ | `--state open` で server-side 絞り込み → open 不在で `reason=no-open-design-pr` continue。スモーク（空配列・impl head）で確認 |
| 1.4 linked 非依存検出 | GraphQL linked field ではなく `gh pr list ... in:head` head ref ベース検出 |
| 1.5 Issue 番号厳密一致 | jq `startswith("claude/issue-<N>-design-")` strict prefix。`#19` vs `#191` 境界スモークで確認 |
| 2.1 ラベルベース除外の維持 | 既存 candidate query / `po_check_dispatch_gate` 等を変更せず、新ガードを追加のみ |
| 2.2 ラベル外れ時も open design PR 単体で抑止 | ガードはラベル状態を参照せず head ref のみで判定 |
| 3.1 検出失敗時 skip | `gh pr list` 非ゼロ / jq parse 失敗 → exit 1（skip） |
| 3.2 timeout / レート制限時 skip | `timeout` でラップ、rate-limit 検知時専用 reason で exit 1（skip） |
| 4.1 skip 理由と PR 番号をログ記録 | `pclp_log "skip issue=#N pr=#P reason=open-design-pr-exists"` |
| 4.2 既存 Pre-Claim 系と同形式 | `pclp_log`/`pclp_warn`（prefix `pre-claim-probe:`）の `key=value` 形式を使用 |
| 5.1 / 5.2 PR Iteration 非干渉 | ガードは Issue pickup 経路（candidate ループ）にのみ挿入。PR 駆動経路は不変 |
| NFR 1.1 通常 Issue 不変 | design PR 不在で continue（導入前と等価）。スモーク（空配列）で確認 |
| NFR 1.2 env/exit/ラベル/cron/ログ不変 | 新規 env var なし。`DRR_GH_TIMEOUT` 再利用。ログは既存 pclp_*。exit code 意味は claim 直前ガードと同一（0=continue / 1=skip） |
| NFR 1.3 60 秒タイムアウト規律 | `timeout "${DRR_GH_TIMEOUT:-${MERGE_QUEUE_GIT_TIMEOUT:-60}}"` でラップ |
| NFR 2.1 README 暫定運用ガイド | README Pre-Claim Filter 運用節に「保護ラベルを design PR merge まで外さない」を追記 |

## 確認事項

- **sticky comment 通知（Open Questions）**: requirements.md の Open Questions に「skip 時に
  Issue へ sticky comment で通知すべきか」が人間の決定回答未取得として残っている。Out of Scope
  に明記されているため本実装では通知機能を **実装していない**。必要なら別 Issue として起票要。
- **dry run E2E**: 実 `gh` 認証・ネットワークを要する dry run / E2E は本環境で未実施。検出ロジック
  境界は jq フィルタ抽出スモークで確認済みだが、実 GitHub API 応答に対する `gh pr list --search`
  のトークン分解挙動は、既存 `drr_find_merged_design_pr`（#40 / #80）の同方式実装の前提を踏襲して
  いる（同方式が運用実績あり）。

STATUS: complete
