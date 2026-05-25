# Implementation Plan

- [ ] 1. config / ラベル定義の追加（基盤）
- [ ] 1.1 `issue-watcher.sh` に `TC_HARD_MAX` env var と `LABEL_TC_OVERRIDE` を追加
  - config ブロック（L324-327 付近）に `TC_HARD_MAX="${TC_HARD_MAX:-}"` を追加（未設定＝無制限）
  - LABEL 定義群（L62 付近）に `LABEL_TC_OVERRIDE="tc-override"` を追加
  - 既存 `TC_ENABLED` / `TC_WARN_LOWER` / `TC_WARN_UPPER` / `TC_ESCALATE_LOWER` の名前・既定値は不変
  - _Requirements: 8.1, 8.2, NFR 1.2_
- [ ] 1.2 2 系統の `idd-claude-labels.sh` に `tc-override` ラベルを追加 (P)
  - `.github/scripts/idd-claude-labels.sh` と `repo-template/.github/scripts/idd-claude-labels.sh` の `LABELS` 配列に同名・同 color(`0e8a16`)・同義 description で 1 行追加
  - 既存ラベルの name / color / description は変更しない（追加のみ）。冪等再実行を壊さない
  - _Requirements: 7.1, 7.2, NFR 1.4_
  - _Boundary: idd-claude-labels.sh_

- [ ] 2. override シグナル検出関数 `tc_resolve_override` の実装
- [ ] 2.1 `tc_resolve_override` を TC gate セクションに追加
  - `gh issue view "$NUMBER" --json labels,comments` でラベルと reason マーカーを取得
  - 決定表（design.md）に従い honor(rc=0) / no-honor(rc=1) を返し、reason-code を `tc_log` に記録
  - honor 時は stdout に `actor=<login|unknown> reason=<sanitized>` を 1 行出力
  - reason 抽出: `idd-claude:tc-override reason="([^"]*)"` capture。空 reason は `missing-justification`、複数マーカーは `ambiguous-signal`、gh 失敗は `fetch-failed` で no-honor（fail-safe）
  - actor は reason マーカーを含むコメントの `author.login`、取得不能時は `unknown` に degrade
  - per-issue スコープ（`$NUMBER` のみ評価）。ラベル単独 / マーカー単独は no-honor（二要素必須）
  - _Requirements: 1.1, 1.3, 3.1, 3.3, 4.1, 4.2, 5.2, 6.1, 6.2, 7.2, 7.3, NFR 1.1, NFR 3.1_

- [ ] 3. ハード上限判定 `tc_hard_max_exceeded` の実装
- [ ] 3.1 `tc_hard_max_exceeded` を TC gate セクションに追加 (P)
  - `TC_HARD_MAX` 未設定 / 空 / 非整数は無制限扱い（rc=1 = 未超過）、非整数時は `tc_warn`
  - `count > TC_HARD_MAX` で rc=0（超過）、超過時に `reason-code=hard-max-exceeded count=<C>` を `tc_log`
  - _Requirements: 8.1, 8.2, 8.3_
  - _Boundary: tc_hard_max_exceeded_

- [ ] 4. 証跡コメント `tc_post_override_comment` と冪等マーカー一般化
- [ ] 4.1 `tc_already_posted_marker_present` を `kind=override` 対応に一般化
  - `kind` 引数に応じて marker prefix を `tasks-count-overflow`（warning/escalation 既存）と `tasks-count-override`（override 新規）で切り替える
  - 既存 `warning` / `escalation` 呼び出しの挙動を不変に保つ（後方互換）
  - _Requirements: 2.3_
- [ ] 4.2 `tc_post_override_comment` を実装
  - 件数・適用閾値・actor・理由・Developer 続行許可の旨・取り消し導線を含む本文を投稿
  - 末尾に `<!-- idd-claude:tasks-count-override kind=honored issue=<N> count=<C> -->` を付与
  - 冪等性: `tc_already_posted_marker_present "$N" "override"` で重複 skip。投稿失敗は `tc_warn` のみ・戻り値 0（fail-open）
  - _Requirements: 2.2, 2.3, NFR 2.2, NFR 3.2_
  - _Depends: 4.1_

- [ ] 5. orchestrator `tc_run_post_architect_check` の escalate 分岐改修
- [ ] 5.1 escalate ケースに override 経路を挿入
  - `tc_resolve_override "$NUMBER"` を呼び、honor 可 かつ `tc_hard_max_exceeded` が false のとき `tc_post_override_comment` を呼び `tc_add_needs_decisions_label` を呼ばない
  - honor 可 かつ hard-max 超過、または no-honor のときは既存の `tc_post_escalation_comment` + `tc_add_needs_decisions_label`
  - honor 時に件数・actor・理由を `tc_log` で記録（`override=honored`）
  - `normal` / `warn` 分岐は不変（件数 < 閾値で override を一切評価しない）。戻り値は常に 0
  - 候補抽出クエリ（L6899）には触れない（needs-decisions 未付与により候補に残る経路を成立させる）
  - _Requirements: 1.1, 1.2, 1.4, 2.1, 3.2, 5.1, 8.1, NFR 1.4_
  - _Depends: 2.1, 3.1, 4.2_

- [ ] 6. bot 誤発火防止の設計保証点検
- [ ] 6.1 watcher が override シグナルを生成しないことをコードレベルで確認
  - 全 tc_* 関数に `tc-override` ラベル付与 / `idd-claude:tc-override reason=` マーカー投稿のコードパスが無いことを確認
  - 証跡マーカー `kind=honored` が `reason="..."` シグナルマーカーと名前・属性で区別され、次サイクルで誤検知されないことを確認
  - 確認結果を `impl-notes.md` に記録
  - _Requirements: 7.1, 7.2, 7.3_

- [ ] 7. ドキュメント更新（README 同一 PR 反映）
- [ ] 7.1 README の Tasks Count Gate 節とオプション機能一覧表を更新
  - 「Tasks Count Gate (#147)」節に override の運用手順（`tc-override` ラベル + reason マーカー）・シグナル契約・証跡コメント形式・取り消し方法を追記
  - 既存挙動との互換性節に「override 非適用時は #147 既定と同一」「既に needs-decisions 付与済み Issue は対象外（手動除去後に再宣言）」を明記
  - オプション機能一覧表（L1188 付近）に `TC_HARD_MAX`（既定 未設定＝無制限）を追記
  - _Requirements: 5.2, 8.1, NFR 1.1, NFR 1.3, NFR 2.1_

- [ ]* 8. 境界 fixture とスモークスクリプトの追加
- [ ]* 8.1 `tc_resolve_override` の判定境界 fixture とスモークを追加
  - `test-fixtures/comments-honor.json` / `comments-missing-reason.json` / `comments-ambiguous.json` を作成
  - `test-override.sh` で honor / missing-justification / ambiguous / fetch-failed の rc と reason-code を回帰確認
  - _Requirements: 1.1, 3.1, 4.1, NFR 3.1_
