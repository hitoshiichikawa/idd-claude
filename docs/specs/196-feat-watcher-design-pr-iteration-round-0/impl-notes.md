# 実装ノート（Issue #196）

## 結論

Issue #196 が要求する literal な変更（design PR iteration の round 上限デフォルトを
`0` → 非0（例 `3`）にする）は **実装しませんでした**。理由は、Issue の前提が実コード・
README の `max_rounds=0` の意味論と **正反対** であり、literal に実装すると Issue の目的とは
逆の効果（design 反復の打ち切り）と後方互換性の破壊を招くためです。これは Developer 単独で
解決できない仕様矛盾であり、PM / Architect への差し戻しが必要と判断しました。

CLAUDE.md「エージェント連携ルール」の「Developer は仕様を追加・解釈しない。不明点は
PM / Architect に差し戻す」に従い、コード変更（`issue-watcher.sh` / `README.md`）および
spec 成果物（`requirements.md` / `design.md` / `tasks.md`）の新規作成は **行っていません**。

---

## 確認事項（PM 差し戻し）

### 1. 発見した矛盾の要約（Issue 前提 vs 実コード/README）

Issue #196 は次の前提に立っています:

- 「design は既定 `0` round = 実質反復しない」
- 「design iteration は実際には 1 度も反復しない」
- したがって「round 上限デフォルトを `0` → 非0（例 `3`）にすれば、設計 PR の
  `needs-iteration` が既定で機能するようになる」

しかし **実コードと README はいずれも `max_rounds=0` を「無制限反復」の sentinel として
定義** しています。`0` は「反復しない」ではなく「**round 数超過による escalate を行わない
（= 無制限に反復する）**」を意味します。つまり Issue の前提は実装の意味論と **正反対** です。

### 2. 裏付けとなる file:line 参照（独立検証済み）

検証は対象ブランチ HEAD (`72884e5`、`main` と同一) のコードと README を直接 Read して
独立に実施しました。

- **`max_rounds=0` の sentinel 定義（コメント）**:
  `local-watcher/bin/issue-watcher.sh:3713`
  > `# 出力: stdout に 0 以上の整数（`0` は無制限の sentinel / Req 2）`
- **design の default_value = 0**:
  `local-watcher/bin/issue-watcher.sh:3738-3740`（`design)` ケースで `default_value="0"`）
- **`max_display="無制限"` 表示**:
  `local-watcher/bin/issue-watcher.sh:4713-4717`
  （`if [ "$max_rounds" = "0" ]; then max_display="無制限"`）
- **escalate ゲートが `max_rounds=0` をスキップする核心箇所**:
  `local-watcher/bin/issue-watcher.sh:4734-4741`
  ```sh
  # Issue #122 Req 2.1 / 2.3: max_rounds=0 は「round 数超過のみによる escalate を行わない」
  # （AC 2.1: design / AC 2.3: impl）。max_rounds>0 のときは round >= max で escalate。
  if [ "$max_rounds" != "0" ] && [ "$round" -ge "$max_rounds" ]; then
    ...
    pi_escalate_to_failed ...
    return 2
  fi
  ```
  `max_rounds=0` のとき左辺 `[ "$max_rounds" != "0" ]` が偽となり、escalate ゲート全体が
  **スキップ** されます。escalate されないだけで、その後の `next_round` 計算・着手表明・
  Claude 起動（`issue-watcher.sh:4743` 以降）は **round 数に関係なく毎回実行** されます。
  すなわち `0` = 反復停止ではなく **無制限反復** です。
- **README の `max_rounds=0`=無制限 記述（複数箇所、いずれも独立に確認）**:
  - `README.md:1784` — 「design 既定 `0`=無制限、#122」
  - `README.md:1852` — 挙動表「design は既定 `0` = 無制限」
  - `README.md:1884` — env 表「`PR_ITERATION_MAX_ROUNDS_DESIGN` 既定 `0`（無制限）…
    `0` は **「round 数超過のみによる escalate を行わない」** sentinel（無制限）」
  - `README.md:2063` — migration note「両 env と旧 env がすべて未設定の場合のみ
    impl=3 / design=0（無制限）に倒れます」
- **`0` でも no-progress 検知は有効（暴走防止は別経路で既に存在）**:
  `README.md:1786-1787` / `README.md:1884` 末尾 — `PR_ITERATION_NO_PROGRESS_LIMIT`（既定 3）
  により、`0`（無制限）設定でも無進捗ループは別経路で検知・escalate される。

### 3. `0 → 3` を literal に実装した場合の実害

- **逆効果**: Issue の目的は「design 反復を有効化する」ことだが、現状 `0`=無制限で
  **design 反復はすでに既定で機能している**（`PR_ITERATION_DESIGN_ENABLED` が #112 以降
  既定 `true`、`README.md:1833` / `1887`）。`0 → 3` にすると、現在無制限に反復している
  設計 PR が round 3 で打ち切られ `claude-failed` に escalate されるようになる。これは
  「反復を有効化する」のではなく「反復を **3 round で停止** する」変更であり、Issue の
  目的と逆方向。
- **後方互換性の破壊**: CLAUDE.md「禁止事項」の「後方互換性を壊す変更を無告知で入れる
  （…exit code 意味変更）」「既存機能のデフォルト値変更」に該当する挙動変更。現在
  `design=0`（無制限）で運用中の設計 PR の escalate 挙動が変わる（3 round 超過で
  `claude-failed` 付与）。migration note なしには入れられない破壊的変更。
- **仕様の不在**: この変更を正当化する `requirements.md` / `design.md` / `tasks.md` が
  spec ディレクトリに **一切存在しない**（現状 `review-notes.md` のみ）。Developer は
  仕様を著作・解釈してはならないため、literal 実装の根拠が無い。

### 4. spec 成果物の不在により Developer 単独では実装できない

`docs/specs/196-feat-watcher-design-pr-iteration-round-0/` 配下には `review-notes.md` しか
存在せず、`requirements.md` / `design.md` / `tasks.md` がいずれも無い。前段の Reviewer も
同様の理由（差分ゼロ・spec 不在）で reject 済み（`review-notes.md` の Finding 1）。

Issue の前提自体が実装の意味論と矛盾しているため、たとえ spec があっても literal 実装は
不適切である。PM が Issue の意図を確認し、必要なら要件を起こし直す段階が必要。

### 5. PM / 人間向けの選択肢（提案。Developer は判断を確定しない）

以下は提案であり、最終判断は PM / 人間に委ねます。

- **選択肢 A（Issue を invalid として close）**: design iteration は `PR_ITERATION_DESIGN_ENABLED`
  既定 `true` かつ `design=0`（無制限）で **既に既定で機能している**。Issue の前提
  （「design は反復しない」）が事実誤認であれば、Issue #196 を invalid として close する。
- **選択肢 B（観測事実なら別箇所を再調査する Issue に切り直し）**: もし「設計 PR の
  `needs-iteration` が実際に効いていない」という **観測** が事実なら、原因は round 上限
  （`0`=無制限）ではなく別箇所（例: 設計 PR の検出条件 `PR_ITERATION_DESIGN_HEAD_PATTERN`、
  ラベル遷移、`PR_ITERATION_DESIGN_ENABLED` の解決、no-progress 検知の誤発火等）にある。
  再現条件とログ（`grep 'pr-iteration:' ... | grep 'kind=design'`、`README.md:1860-1872`）を
  添えて原因調査の Issue に切り直す。
- **選択肢 C（暴走防止の安全上限を design にも設けたい別目的なら、意図的変更として扱う）**:
  もし真の目的が「design 反復にも暴走防止の有限上限を設けたい」であれば、それは
  `0 → N` の **意図的なデフォルト値変更**（後方互換性に影響する）として扱う。その場合は
  PM が「なぜ有限上限が必要か」「既存 no-progress 検知（既定 3）との役割分担」「migration
  note の要否」を明示した requirements を起こし直し、Architect が design.md / tasks.md を
  整備したうえで実装する。Developer はその spec が揃ってから着手する。

---

## 検証手順（本サイクルで実施した内容）

- `git rev-parse HEAD main` で HEAD == main（`72884e5`）を確認（差分ゼロを独立確認）
- `issue-watcher.sh` の `pi_resolve_max_rounds`（3729-3764 行）/ `pi_run_iteration` の
  escalate ゲート（4708-4741 行）を Read し、`max_rounds=0`=無制限 sentinel の意味論を確認
- `README.md` の 1784 / 1852 / 1884 / 2063 行付近を Read し、コードと README が同一意味論
  （`0`=無制限）であることを確認
- 本サイクルでは **コード変更を行わない**（inverted change を入れない）方針のため、
  shellcheck / actionlint への影響は無し（impl-notes.md のみの追加）

## 補足

- 本ブランチは `claude/issue-196-impl-...` だが、上記の通りコード実装は保留し、確認事項の
  記録に留めた。`requirements.md` / `design.md` / `tasks.md` は新規作成していない（PM /
  Architect の責務）。

## Partial Halt Reason

`partial_blocked`（外部要因による進行不能）。Issue #196 の前提（design `max_rounds=0` =
実質反復しない）が、実コード（`local-watcher/bin/issue-watcher.sh:4734-4741` の escalate
ゲートが `max_rounds=0` をスキップ）および README（`1784` / `1852` / `1884` / `2063` 行で
`0`=無制限と明記）の意味論と **正反対** であることを独立検証で確認した。literal な `0 → 3`
変更は Issue の目的（反復を有効化）と逆効果（反復を 3 round で打ち切り escalate）であり、
かつ現在 `design=0`（無制限）で稼働中の設計 PR の挙動を変える後方互換性破壊である。

加えて、この変更を正当化する `requirements.md` / `design.md` / `tasks.md` が spec
ディレクトリに一切存在せず（現状 `review-notes.md` のみ）、Developer は仕様を著作・解釈
してはならない（CLAUDE.md「Developer は仕様を追加・解釈しない。不明点は PM / Architect に
差し戻す」）。よって PM / Architect の判断（Issue 前提の再確認・要件の再起票・原因再調査）が
必須であり、Developer 単独では正当な実装ができないため halt する。

## Pending Tasks

（`tasks.md` が存在しないため、Issue が暗黙に要求していた作業を以下に列挙する）

- [ ] design PR iteration の round 上限デフォルト `0` の扱いについて、Issue #196 の前提と
      実装の意味論の矛盾を PM が解消する（選択肢 A/B/C のいずれかを確定する）
- [ ] 矛盾解消後に正当な `requirements.md` / `design.md` / `tasks.md` を PM / Architect が整備する
- [ ] （選択肢 C を採る場合のみ）`pi_resolve_max_rounds` の design `default_value` 変更を
      後方互換性 migration note 付きで実装する

STATUS: partial_blocked
