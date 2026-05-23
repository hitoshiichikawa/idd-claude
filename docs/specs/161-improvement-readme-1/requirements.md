# Requirements Document

## Introduction

idd-claude の README.md 「オプション機能（標準有効 / 常時有効）一覧」表（L1077 付近）は、
各機能の on/off フラグだけを 1 列で並べており、有効化に **追加で必要 / 推奨される環境変数**
や、値の **正規化規則**（`=true` 厳密一致 / `=claude` のみ有効 / `=false` 以外はすべて有効、等）
が併記されていない。そのため、運用者が「一覧表を見て cron に 1 行だけ追加」しても、
`ST_CHECK_RUN_NAME` 未設定で Phase B が静かに skip されるなど **サイレントに機能しない事故**
が発生する。本要件は、運用者が **README L1077 の表とその周辺だけを読めば cron / launchd の
opt-in 設定を完結できる**よう、一覧表の情報密度と他セクションとの導線を是正する。

## Requirements

### 1: オプション機能一覧表に「有効化時の必須/推奨パラメータ」を併記する

**Objective:** As a idd-claude を導入する運用者, I want オプション機能一覧表だけで各機能の opt-in に必要な全 env を把握したい, so that 一覧表外の節を 3 箇所以上参照せずに正しい cron / launchd 設定を 1 度で書ける

#### Acceptance Criteria

1. The README オプション機能一覧表 shall 各機能行に対し「有効化キー」「有効化キーの値正規化規則」「機能が動作するために追加で必須となる env（必須追加 env）」「動作には不要だが運用者が知るべき推奨 env（推奨 env / knob）」「当該機能の詳細セクションへの内部リンク」を併記する
2. While 当該機能に必須追加 env が存在しない場合（一覧表現は「なし」「`—`」等の明示マーカー）, the README オプション機能一覧表 shall その旨を明示的に表現する（空欄での暗黙省略を許さない）
3. When 運用者が一覧表行を読んだとき, the README オプション機能一覧表 shall その行に書かれた env 群だけを cron / launchd に列挙すれば当該機能が「サイレント skip」されない状態に達することを保証する
4. The README オプション機能一覧表 shall 一覧表に出現する全機能（「デフォルト有効」節および「opt-in」節の双方）に対して 1.1〜1.3 の併記要件を適用する
5. Where 機能の制御変数が環境変数ではない場合（Feature Flag Protocol のように `CLAUDE.md` の宣言節で制御する機能を含む）, the README オプション機能一覧表 shall env 列の代わりに「宣言場所」を併記し、env 列に env 名を誤記しない

### 2: 値の正規化規則を一覧表で明示する

**Objective:** As a idd-claude を導入する運用者, I want 「`=on` / `=true` / `=claude` のどれが効くのか」を一覧表で確認したい, so that typo によるサイレント OFF / サイレント有効化を一覧表の段階で気付ける

#### Acceptance Criteria

1. The README オプション機能一覧表 shall 各機能行に対して有効化キーが受け付ける値と、それ以外の値の解釈（=既定にフォールバックするのか、warn するのか）を併記する
2. Where 機能の有効化キーが「`=false` 以外はすべて有効」型（デフォルト有効に反転された 8 種＋ `IMPL_RESUME_PROGRESS_TRACKING` / `STAGE_A_VERIFY_ENABLED` / `TC_ENABLED` 等）の場合, the README オプション機能一覧表 shall 当該規則と「typo / 空文字 / `0` / `False` はすべて有効として扱われる」旨を併記する
3. Where 機能の有効化キーが「特定文字列の厳密一致のみ有効」型（例: `AUTO_REBASE_MODE=claude` / `PATH_OVERLAP_CHECK=true` / `PROMOTE_PIPELINE_ENABLED=true` / `PER_TASK_LOOP_ENABLED=true` / `DEBUGGER_ENABLED=true` 等）の場合, the README オプション機能一覧表 shall 「厳密一致する文字列」と「それ以外は OFF に正規化される」旨を併記する
4. If 有効化キーの値が必須追加 env と組み合わせて初めて意味を持つ場合（例: `PROMOTE_PIPELINE_ENABLED=true` + `ST_CHECK_RUN_NAME` 未設定の組み合わせで「WARN + skip」になる）, the README オプション機能一覧表 shall 当該失敗モードを 1 行で明示する

### 3: Issue が例示する 4 件のサイレント失敗事故を再発させない

**Objective:** As a idd-claude を導入する運用者, I want Issue #161 が指摘した 4 件の事故パターンを一覧表だけで防げる, so that 既存読者が同じ罠を踏まない

#### Acceptance Criteria

1. The README オプション機能一覧表 shall Phase B 行に対して `PROMOTE_PIPELINE_ENABLED=true` だけでは機能せず `ST_CHECK_RUN_NAME` の設定が必要であることを明示する
2. The README オプション機能一覧表 shall Phase D 行に対して `AUTO_REBASE_MODE` が `=claude` のみ有効であり `=on` / `=true` / 大文字小文字違いは OFF に正規化されることを明示する
3. The README オプション機能一覧表 shall Phase E 行に対して `PATH_OVERLAP_CHECK` が `=true` のみ有効であり `=on` / `=1` / `True` は OFF に正規化されることを明示する
4. The README オプション機能一覧表 shall Phase 2 行に対して `PER_TASK_LOOP_ENABLED=true` 時の暴走防止 knob として `PER_TASK_MAX_TASKS` が存在することを明示する
5. The README オプション機能一覧表 shall Phase 3 行に対して `DEBUGGER_ENABLED=true` 時に `DEBUGGER_MODEL` / `DEBUGGER_MAX_TURNS` が推奨 knob として存在することを明示する

### 4: 詳細セクションとの導線を維持する

**Objective:** As a idd-claude を導入する運用者, I want 一覧表で得た情報の根拠と詳細手順を Phase 別セクションで深掘りできる, so that 一覧表が「情報の入口」、Phase 別セクションが「情報の正本」という関係を保てる

#### Acceptance Criteria

1. The README オプション機能一覧表 shall 各機能行から当該機能の Phase 別詳細セクション（例: `Promote Pipeline Processor (Phase B)`、`Auto Rebase Processor (Phase D)` 等）への anchor リンクを 1 件以上維持する
2. While 一覧表に併記される env 説明が短縮表現である場合, the README Phase 別詳細セクション shall env の完全な仕様（既定値・許容値範囲・推奨値・ログ識別語）を引き続き正本として保持する
3. If 一覧表の併記内容と Phase 別詳細セクションの内容が食い違う場合, the README オプション機能一覧表 shall Phase 別詳細セクションを参照すべき旨を明示し、両者を 1 度の改訂で同期する責務を運用者ではなく README 改訂者に課す
4. The README オプション機能一覧表 shall 「常時有効（opt-out 不可）」節および「`install.sh` の runtime フラグ（参考）」節の既存構造を破壊しない（本要件のスコープは opt-in / デフォルト有効の 2 節に限定し、常時有効節は env 列追加の対象外）

### 5: 既存読者と既存 cron 設定への後方互換性

**Objective:** As a 既存 idd-claude 利用者, I want README 改訂で自分の cron / launchd 設定がそのまま動き続ける, so that 改訂が「README の見方が変わる」だけで「既存運用を壊さない」ことを保証できる

#### Acceptance Criteria

1. The README オプション機能一覧表 shall 既存運用に対して挙動変更を発生させない（README は文書であり、本要件は env var の追加・削除・既定値変更・名称変更を一切伴わない）
2. The README オプション機能一覧表 shall 既存 anchor（例: `#merge-queue-processor-phase-a`、`#promote-pipeline-processor-phase-b` 等）を温存し、外部からの直リンクを破壊しない
3. If 既存の一覧表の列構造を変更する場合, the README オプション機能一覧表 shall 既存読者向けに「列追加 / 列再構成の意図」を 1 段落以内で明示する（migration note 相当の補足を一覧表直前または直後に置く）

## Non-Functional Requirements

### NFR 1: 情報配置の単一情報源性

1. The README オプション機能一覧表 shall 「有効化キー」「必須追加 env」「正規化規則」を一覧表内で 1 度だけ記述し、同じ義務情報を別表・別節に重複定義しない
2. The README Phase 別詳細セクション shall env の完全仕様（既定値・許容範囲・ログ識別語）を引き続き正本として保持し、一覧表側はその要約に留める
3. If 一覧表と Phase 別詳細セクションが矛盾を示唆する場合, the README オプション機能一覧表 shall Phase 別詳細セクションを正本とする旨を読者が迷わず判定できるよう明示する

### NFR 2: 可読性と運用負荷

1. The README オプション機能一覧表 shall 1 機能 1 行のスキャナビリティを維持する（1 機能の説明を複数行・複数表に分割しない。ただし表とは別形式での補足は許容する）
2. The README オプション機能一覧表 shall 列幅増加に伴って同節内のサンプル cron ブロックを上書き / 削除しない（既存の最小 cron 例 / 個別無効化 cron 例の動作可能性を保つ）

### NFR 3: 言語方針との整合

1. The README オプション機能一覧表 shall 説明文を日本語ベースで記述し、env var 名 / コマンド名 / ラベル名 / 値リテラル（`true` / `false` / `claude` / `=true` 等）は英語固定で残す
2. The README オプション機能一覧表 shall EARS 形式の AC 由来語彙（`When` / `If` / `While` / `Where` / `shall`）を本文中に強制せず、自然な日本語の運用者向け説明として記述する

## Out of Scope

- 環境変数の追加・削除・既定値変更・名称変更（本 Issue は README 改訂であり、`local-watcher/bin/issue-watcher.sh` のコード変更は伴わない）
- 「常時有効（opt-out 不可）」節（Reviewer Gate / Developer Partial Status Codes）への列追加（その節は env 列を持たないため本要件の対象外）
- `install.sh` runtime フラグ表（`--dry-run` / `--force`）への列追加（機能 opt-in ではない）
- README 全体の章立て再編、README 行数削減を目的とした抜本的な分割（案 C の `docs/feature-flags.md` 切り出しを採用する場合のみ、要件追加として別 Issue を起票する）
- 一覧表に出現しない env（例: `MERGE_QUEUE_MAX_PRS` / `MERGE_QUEUE_GIT_TIMEOUT` 等の「動作 knob 中の knob」）の全数列挙（推奨 env 欄に主要 knob のみを抽出する）
- 自動チェック / CI lint による「README 一覧表と issue-watcher.sh の env 定義の同期性」検証（手動メンテで足りる現状運用を継続）
- 英語 README の追加 / 多言語化

## 確認事項

以下は requirements 段階で人間判断が必要な事項であり、design / impl 着手前に Issue コメントで決定すべきものとして列挙する。

- **採用案 A / B / C のいずれを採用するか**:
  - 案 A（既存表に列追加）: 後方互換性が高く、既存 anchor / 列順序を温存できる。横幅が増えるが、idd-claude README は元々 GitHub web 表示前提で広い表が多く、許容できる可能性が高い
  - 案 B（per-feature recipe カード）: 各機能を 1 つの小節として書き直し、`what` / `enable` / `required` / `recommended` / `details` をパラグラフ化。可読性は最高だが、「一覧性」が下がる
  - 案 C（`docs/feature-flags.md` 切り出し）: README の 3200+ 行という長さ問題に直接効くが、本 Issue の主目的（一覧表 1 箇所完結）と「ドキュメント分散の追加」がトレードオフ
  - **PM の暫定推奨**: 案 A（後方互換性 / Out of Scope の境界を最小化できる）。ただし Issue 起票者 / 人間レビュワーの最終判断を要する
- **`PARALLEL_SLOTS` の扱い**: `=1` で「直列」、`>=2` で並列の "数値型" opt-in であり、`true` / `false` 系の 2 値 opt-in とは性質が異なる。正規化規則欄をどう表現するか（「整数。`1` で直列、`>=2` で並列」等）を案 A 採用時の列フォーマットで仕様化する必要がある
- **`IDD_CLAUDE_USE_ACTIONS` の扱い**: env ではなく GitHub Repository Variable で制御するため、「env 列」ではなく「制御変数列」のヘッダ名を維持するか変更するか
- **「推奨 env / knob」欄の粒度**: 各機能ごとに `*_MAX_PRS` / `*_GIT_TIMEOUT` 等の動作 knob は数多く存在する。一覧表には「典型的に上書きしたくなるもの」だけを 2〜3 件抽出する基準で良いか
- **migration note の有無**: 既存読者に対する「列構造変更の意図」を一覧表直前に置くか、`#112` の既存 migration note ブロックに追記する形で吸収するか
