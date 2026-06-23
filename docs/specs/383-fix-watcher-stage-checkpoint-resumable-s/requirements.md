# Requirements Document

## Introduction

watcher の Stage Checkpoint Resume スラグ照合ガード `_stage_checkpoint_assert_slug_match`
（`local-watcher/bin/issue-watcher.sh:9410`）は、`docs/specs/<N>-*/` に
番号一致するディレクトリが存在するだけで発火する設計になっており（呼び出し元
`local-watcher/bin/issue-watcher.sh:10545` および `:10554`）、resumable state
（既存 impl PR / `claude/issue-<N>-impl-*` ブランチ / tracked な `impl-notes.md` /
`review-notes.md`）の有無を一切判定していない。

このため umbrella issue + sub-issue 構成で 1 つの spec dir
（例: `docs/specs/1-<umbrella-slug>/`）を共有しているリポジトリでは、
sub-issue #1 のように番号プレフィックスが衝突する fresh issue（impl ブランチも
checkpoint も存在しない）が、Issue タイトル由来 slug と spec dir slug の
不一致だけを根拠に `needs-decisions` でブロックされる。回避策（spec dir 番号の改番）は
存在するが、full-auto 初手の依存グラフ先頭でこれが起きると後続全 Issue が止まる。

本要件は、`stage_checkpoint_resolve_resume_point`
（`local-watcher/bin/issue-watcher.sh:1879`）が impl-PR / impl-notes.md /
review-notes.md / origin の impl-* ブランチで定義する **resumable state**
の概念をスラグ照合ガード側にも適用し、resumable state が実在する場合のみ
slug guard を発火させて Issue #114 の fork/mirror 衝突誤 resume 防止を維持しつつ、
resumable state 不在の fresh issue を不当にブロックしないよう挙動を補正することを目的とする。

## Requirements

### Requirement 1: spec-dir 経路の slug guard を resumable state 実在時のみ発火させる

**Objective:** As a watcher 運用者, I want spec-dir 経路の slug 照合ガードを resumable state が実在するときに限定して発火させること, so that umbrella spec を sub-issue と共有する構成で fresh issue が誤って block されない

#### Acceptance Criteria

1. When watcher が Issue 処理開始時に `docs/specs/<N>-*/` を検出したとき, the Watcher shall 当該 Issue について「resumable state が実在するか」を判定したうえで slug guard を発火するか決定する
2. If `docs/specs/<N>-*/` が存在し、かつ resumable state が一切実在しない（impl PR 不在 / `claude/issue-<N>-impl-*` origin ブランチ不在 / tracked な `impl-notes.md` 不在 / tracked な `review-notes.md` 不在）とき, the Watcher shall slug guard を発火させず Stage A を新規実装として継続する
3. When Requirement 1.2 の経路で slug guard を skip したとき, the Watcher shall 当該 Issue に `needs-decisions` ラベルを付与しない
4. When Requirement 1.2 の経路で slug guard を skip したとき, the Watcher shall `_slug_mismatch_escalate` を呼び出さずスラグ不一致コメントを投稿しない
5. While `docs/specs/<N>-*/` が複数存在し expected-slug と一致するものが無いケースでも resumable state が一切実在しないとき, the Watcher shall Requirement 1.2 と同じ skip 経路に倒す

### Requirement 2: resumable state 実在時の slug guard 挙動を維持する

**Objective:** As a watcher 運用者, I want resumable state が実在する Issue では従来どおり slug guard を発火させること, so that Issue #114 の fork/mirror clone 番号衝突誤 resume 防止が回帰なしで維持される

#### Acceptance Criteria

1. When `docs/specs/<N>-*/` が存在し、かつ resumable state（impl PR / `claude/issue-<N>-impl-*` origin ブランチ / tracked な `impl-notes.md` / tracked な `review-notes.md` の少なくとも 1 つ）が実在するとき, the Watcher shall expected-slug と found-slug を照合する
2. When Requirement 2.1 の照合で expected-slug と found-slug が一致したとき, the Watcher shall 従来どおり Stage Checkpoint Resume を継続する
3. If Requirement 2.1 の照合で expected-slug と found-slug が一致しないとき, the Watcher shall Issue #114 の既存挙動と同一の経路（`needs-decisions` 付与・1 件のコメント投稿・当該 Issue 処理 skip）を選択する
4. While `docs/specs/<N>-*/` が存在しないとき, the Watcher shall 本 Issue 修正前と同一の新規スラグ導出経路を選択する

### Requirement 3: resumable state の定義と判定範囲

**Objective:** As a watcher 開発者, I want resumable state の定義を 1 か所で表現すること, so that spec-dir 経路の slug guard と既存 Stage Checkpoint Resume 判定で同じ「実体観測」が共有される

#### Acceptance Criteria

1. The Watcher shall 「resumable state が実在する」を以下 4 観点のいずれか 1 つ以上が真であることと定義する: (a) `stage_checkpoint_find_impl_pr` が OPEN または MERGED 状態の impl PR を 1 件以上検出する, (b) origin 上に `refs/heads/claude/issue-<N>-impl-*` 形式の branch が 1 本以上存在する, (c) 当該 Issue branch HEAD（または検出対象の spec dir）上で `impl-notes.md` が tracked である, (d) 当該 Issue branch HEAD（または検出対象の spec dir）上で `review-notes.md` が tracked である
2. The Watcher shall Requirement 3.1 の 4 観点をいずれも検出失敗（gh API エラー・ネットワーク失敗・タイムアウト）したときも slug guard を skip する側に倒さない（NFR 2 の safe-side 規約に従う）
3. The Watcher shall Requirement 3.1 の判定結果を `stage_checkpoint_resolve_resume_point` の判定経路から独立に観測可能とし、spec-dir 経路 slug guard の発火可否判定にだけ用いる

### Requirement 4: 判定経路のログ可観測性

**Objective:** As a watcher 運用者, I want slug guard を skip した経路と発火した経路をログから機械的に区別できること, so that 障害発生時に grep で原因を辿れる

#### Acceptance Criteria

1. When Requirement 1.2 / 1.5 の skip 経路に入ったとき, the Watcher shall ログに `stage-checkpoint:` prefix で 1 行のイベントを記録し issue 番号・expected-slug・found-slug・skip 理由（resumable state 不在）を含める
2. When Requirement 2.1 の照合経路に入ったとき, the Watcher shall 既存 `stage-checkpoint: slug-match` / `stage-checkpoint: slug-mismatch` ログを従来と同形式で 1 行記録する
3. When Requirement 3.1 の判定中に I/O エラーや gh API 失敗を観測したとき, the Watcher shall ログに `stage-checkpoint: WARN` 形式で観測失敗の事実を 1 行記録する

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher shall 既存の環境変数名（`STAGE_CHECKPOINT_ENABLED` 等）・既存ラベル名（`needs-decisions` / `claude-claimed`）・cron 登録文字列・exit code 意味を変更しない
2. While Issue 番号もスラグも一致し resumable state が実在する spec dir が存在するとき, the Watcher shall Issue #114 導入後の Stage Checkpoint Resume 経路（resume-mode・ブランチ起点・push 戦略）と完全に同一の挙動を選択する
3. While `docs/specs/<N>-*/` が存在しないとき, the Watcher shall 本 Issue 修正前と同一の新規スラグ導出経路を選択する
4. The Watcher shall 本 Issue の挙動変更を新規 env var の opt-in gate なしで適用する（既存挙動は「resumable state 実在時に slug guard を発火」というスーパーセットに包含されるため、後方互換 no-op として導入できる）

### NFR 2: 異常系の安全側挙動

1. If Requirement 3.1 の resumable state 判定の途中で gh API エラー・ネットワーク失敗・タイムアウトを観測したとき, the Watcher shall 「resumable state が実在するかもしれない」側に倒し（=従来挙動と同じ slug guard 発火経路を選択する）誤った skip による fork/mirror 誤 resume を発生させない
2. The Watcher shall 既存 spec dir / 既存ブランチを自動削除・自動リネーム・自動上書きしない
3. While slug guard を skip する判定経路を選択しているとき, the Watcher shall 当該 Issue に対して新規 `docs/specs/<N>-<slug>/` ディレクトリを作成したり既存 umbrella spec を書き換えたりする処理を本修正の責務として追加しない（後続 Stage A 実装が判断する）

### NFR 3: ログ出力の運用基準

1. The Watcher shall Requirement 4 の各ログ行を 1 イベント 1 行で出力し改行を含めない
2. The Watcher shall Requirement 4 のログ行に issue 番号・expected-slug・found-slug の 3 値をすべて含める（skip 経路でも found-slug を出力できないケースは空文字または `(none)` リテラルとする）

### NFR 4: テスト方針

1. The Watcher shall 本要件の判定ロジックを `local-watcher/test/` 配下の既存テスト方式（`extract_function` で関数を関数定義のみ抽出 → `gh` / `slot_log` / `_slug_mismatch_escalate` 等の副作用関数を stub → 観測）に従って検証可能な単位に分割して実装する
2. The Watcher shall 既存の `local-watcher/test/slug_match_guard_test.sh` の検証観点（slug-match / slug-mismatch / NUMBER 未設定 / spec dir prefix 不一致）を回帰させない
3. The Watcher shall Requirement 1.2 の skip 経路と Requirement 2.1 の発火経路を最低 1 件ずつ test fixture で検証する

## Out of Scope

- 二次的所見（watcher 自身のエスカレーションコメントが stale 化して Triage が
  `needs-decisions` を再起票するループ）の解消。Issue 本文「スコープ外」節は
  「slug ガードの誤爆解消に限定」と明言しており、二次的所見は別 issue として
  follow-up 化する。「確認事項」節に follow-up 化判断を明示する
- 「1 umbrella spec を複数 sub-issue で共有する」構成自体の idd-claude
  一級サポート（Issue 本文「スコープ外」節と同一）
- watcher 自身がエスカレーションコメントを条件解消時に自動 close / 注記する
  機構の新規追加（二次的所見の根本解決に該当するため follow-up）
- Triage プロンプト側の過去 watcher コメントを未解決決定事項として誤読する
  挙動の修正（PM/Triage プロンプト変更を要するため follow-up）
- `_resume_branch_assert_slug_match`（`local-watcher/bin/issue-watcher.sh:9453`）
  の挙動変更。ブランチ経路は元々 origin に impl-* ブランチが存在することを
  前提に発火する設計のため resumable state 判定が暗黙に組み込まれており、
  本要件のスコープ外
- スラグ正規化規則（Issue #114 Req 5 の `_normalize_slug`）の変更
- `needs-decisions` ラベル以外へのエスカレーション先切替

## 確認事項

- 二次的所見（needs-decisions 再エスカレーションループ）の扱い:
  Issue 本文「受入基準」節の (二次) 項目には記載があるが、同 Issue「スコープ外」節は
  「本 Issue は slug ガードの誤爆解消に限定」と明言している。コメント欄に
  人間からの追加指示は存在しない（Path Overlap Checker と watcher 起動通知のみ）。
  PM 判断として **本 Issue では Out of Scope に倒し、follow-up issue 化を提案する**
  方針を採用した。Architect / Developer は本判断を上書きしないこと。
  もし運用上「同じ PR で二次的所見もまとめて解消したい」という要求がある場合は、
  本 requirements を再オープンし Requirement 5 として追加する（現時点では追加しない）。
- Requirement 3.1 で定義した resumable state の 4 観点（impl PR / impl-* origin
  ブランチ / impl-notes.md tracked / review-notes.md tracked）の AND/OR 条件は
  「OR（1 つでも真なら resumable state 実在）」と確定。設計判断として
  `stage_checkpoint_resolve_resume_point` が個別観点を独立に観測している
  既存挙動と整合させた（impl-notes 単独でも Stage B 以降へ resume するため）
- Requirement 3.1 (b) の origin ブランチ判定について、spec-dir 経路 slug guard の
  時点では BRANCH 変数（`claude/issue-<N>-impl-<slug>`）の slug 部がまだ
  expected-slug ベースで確定していない可能性がある。実装では
  `_resume_branch_assert_slug_match` と同様に `git ls-remote --heads origin
  "refs/heads/claude/issue-<N>-impl-*"` で **slug 不問の prefix マッチ**を
  行うこと（特定 slug ブランチに限定すると mismatch ブランチを resumable state
  として検出できず本 Issue が解消しないため）
- NFR 1.4 の「opt-in gate なし」判断について、idd-claude の原則は「外部挙動を
  変える機能は env gate で opt-in」だが、本修正は「従来 block していた fresh
  issue を block しない方向への緩和」であり、Issue #114 が守る fork/mirror
  誤 resume 防止は resumable state 実在時の発火経路で完全に維持される。
  CLAUDE.md「opt-in gate と後方互換」節の趣旨（既定挙動の no-op 維持）と整合する
  ため gate なしでよいと判断した

## 関連

- Depends on: なし
- Parent: なし
- Related: #114（Stage Checkpoint Resume slug 照合ガードの原典）
