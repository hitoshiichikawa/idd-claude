# Requirements Document

## Introduction

`claude-failed` ラベルが付いた Issue から人間が手動復旧した際に、watcher が「閉じたはずの fail」を再 pickup して既存の手作りした実装 PR を force-push で破壊する事故が 2026-04-29 に発生した（Issue #52 の Reviewer parse-failed [#63] からの復旧時、PR #62 が orphan 化）。

事故の根因は 2 件: (a) 復旧手順が明文化されておらず、`claude-failed` の除去だけでは `auto-dev` が残るため次の cron tick で再 pickup されてしまう運用上の脆弱性、(b) watcher が Issue に紐付く既存 impl PR の存在を一切確認せず impl-resume を起動する構造的な脆弱性。

本機能では (1) ドキュメント / ラベル description / escalation コメント上での復旧手順明文化と、(2) watcher 側の Issue pickup 直後における既存 impl PR 検出による再 pickup 抑制の 2 層で再発を防止する。後方互換性のため、watcher の既存 env var / ラベル名 / cron 登録文字列 / exit code 意味は変更しない。

## Requirements

### Requirement 1: 既存 impl PR が存在する Issue の再 pickup 抑制

**Objective:** As a watcher 運用者, I want 既存 impl PR が紐付いている Issue を watcher が自動的に skip してくれること, so that 手動で作成または復旧した PR が次の cron tick で force-push 破壊されない

#### Acceptance Criteria

1. When `auto-dev` ラベル付き Issue が pickup 候補として選定された直後で、かつ Issue を claim する前に, the Issue Watcher shall その Issue に紐付く linked PR の存在と state を確認する
2. When 当該 Issue に linked impl PR が存在し、その state が OPEN である, the Issue Watcher shall その Issue を当該サイクルで skip し、claim ラベル（`claude-claimed` / `claude-picked-up`）を付与しない
3. When 当該 Issue に linked impl PR が存在し、その state が MERGED である, the Issue Watcher shall その Issue を当該サイクルで skip し、claim ラベル（`claude-claimed` / `claude-picked-up`）を付与しない
4. When linked impl PR の確認結果に基づいて Issue を skip する, the Issue Watcher shall skip 理由（Issue 番号 / 検出した PR 番号 / PR state）を識別可能な prefix 付きで watcher ログに記録する
5. When 当該 Issue に linked impl PR が存在せず、または存在しても state が CLOSED（merge なし）のみである, the Issue Watcher shall 既存の pickup フローに従って Issue を claim し処理を続行する
6. The Issue Watcher shall design PR（PjM が `Refs #N` 形式で参照する設計 PR）と impl PR（PjM が `Closes #N` 形式で参照する実装 PR）を区別して扱い、design PR は本要件の skip 判定対象に含めない
7. If linked PR の取得 API 呼び出しが失敗（タイムアウト / 4xx / 5xx）した, the Issue Watcher shall 当該 Issue を当該サイクルで skip し、API 失敗を識別可能な prefix 付きで watcher ログに記録する

### Requirement 2: 手動復旧手順のラベル description への明文化

**Objective:** As a 手動復旧を行う運用者, I want `claude-failed` ラベル description から正しい復旧手順を読み取れること, so that ラベル除去順序を間違えて再 pickup 事故を起こさない

#### Acceptance Criteria

1. The Label Provisioning Script shall `claude-failed` ラベルの description に「手動復旧時は `ready-for-review` を先に付与してから `claude-failed` を除去する」旨の指示を含める
2. The Label Provisioning Script shall `claude-failed` ラベル description を GitHub のラベル description 上限（100 文字）以内に収める
3. When `--force` オプション付きで Label Provisioning Script を再実行する, the Label Provisioning Script shall 既存ラベルの description を本要件の文言で上書き更新する
4. The Label Provisioning Script shall `claude-failed` のラベル名と color 値（既存値）を変更しない

### Requirement 3: escalation コメントテンプレへの復旧手順明記

**Objective:** As a `claude-failed` 状態の Issue を復旧する運用者, I want Issue に投稿された escalation コメントから正しい復旧手順を読み取れること, so that ラベル除去のみで復旧を試みる誤操作が防止される

#### Acceptance Criteria

1. When watcher が Issue を `claude-failed` に遷移させて escalation コメントを投稿する, the Issue Watcher shall そのコメント本文に「ラベル操作の正しい順序: `ready-for-review` を先に付与してから `claude-failed` を除去する」旨を含める
2. The Issue Watcher shall escalation コメントに「順序を間違えると watcher が次サイクルで再 pickup し、既存 PR が orphan 化する可能性がある」旨の注意書きを含める
3. When PR が既に作成済みでない（impl PR が無い）状況で `claude-failed` に遷移する, the Issue Watcher shall escalation コメントに「PR が無い場合の復旧手順」（`claude-failed` 除去のみで再 pickup される）を補足として含める
4. The Issue Watcher shall 既存の escalation コメント投稿経路（impl 系 stage 失敗 / Reviewer round=2 reject / non-ff push 失敗 / Stage Checkpoint round=2 残骸検出 等）すべてで本要件の手順記述を含める

### Requirement 4: README への手動復旧手順の追加

**Objective:** As a watcher を新規セットアップする運用者, I want README から手動復旧の正しい手順を学べること, so that 復旧操作を初回から正しく実行できる

#### Acceptance Criteria

1. The README shall `claude-failed` 状態の Issue から手動復旧する手順節を含める
2. The README shall 復旧手順節において「PR が既に作成済みかどうか」で操作が分岐することを明示する
3. The README shall PR が既に作成済みの場合の手順として「`ready-for-review` を先に付与 → `claude-failed` を除去」の順序と、順序を逆にした場合の事故リスク（既存 PR の orphan 化）を記述する
4. The README shall PR が無い場合の手順として「`claude-failed` を除去すると次サイクルで再 pickup される」旨を記述する
5. The README shall 本要件で記述した手順節へ、ラベル説明表 / Issue 状態遷移節 / `claude-failed` に言及する既存箇所からの相互参照を含める

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Issue Watcher shall 既存の env var 名（`REPO` / `REPO_DIR` / `LOG_DIR` / `LOCK_FILE` / `TRIAGE_MODEL` / `DEV_MODEL` 等）を改名しない
2. The Issue Watcher shall 既存の cron / launchd 登録文字列を変更しない（追加 env var が必要な場合は default 値ありで導入する）
3. The Issue Watcher shall 既存の exit code 意味（0 = 正常 / 非ゼロ = 致命的失敗）を変更しない
4. The Label Provisioning Script shall 既存ラベル（`auto-dev` / `claude-claimed` / `claude-picked-up` / `needs-decisions` / `awaiting-design-review` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` / `needs-quota-wait`）の name と color を改変しない
5. While 当該 Issue に linked impl PR が存在しない通常運用条件下で, the Issue Watcher shall 本機能導入前と同一の pickup 挙動（Issue を claim して Triage / impl / impl-resume を起動する）を行う

### NFR 2: 可観測性

1. The Issue Watcher shall 既存 impl PR 検出による skip ログを、grep で集計可能な識別 prefix 付きで出力する
2. The Issue Watcher shall skip ログに Issue 番号・検出した linked PR 番号・PR state（OPEN / MERGED / CLOSED）を含める
3. When 同一サイクル内で複数 Issue が skip 対象になった, the Issue Watcher shall それぞれの skip 理由を独立した行として watcher ログに記録する

### NFR 3: 静的解析と検証

1. The Issue Watcher shall `shellcheck` 警告ゼロを維持する
2. The Label Provisioning Script shall `shellcheck` 警告ゼロを維持する
3. The dogfood test 手順 shall claude-failed 状態の Issue + 既存 OPEN impl PR の組み合わせで watcher が当該 Issue を skip することを確認できる手順を含める
4. The dogfood test 手順 shall claude-failed 状態の Issue + 既存 CLOSED（merge なし）impl PR の組み合わせで watcher が処理を続行することを確認できる手順を含める

### NFR 4: API レート制限耐性

1. The Issue Watcher shall pickup 候補 Issue が複数件存在する場合でも、linked PR 確認の API 呼び出しが GitHub のレート制限に該当する閾値を超えないように呼び出し回数を制御する
2. If linked PR 確認の API 呼び出し中にレート制限エラー（HTTP 429 等）が観測された, the Issue Watcher shall 当該 Issue を skip し、レート制限を識別可能な prefix 付きでログに記録する

## Out of Scope

- Reviewer parse-failed そのものの修正（Issue #63 で対応中）
- Phase C 並列化における impl-resume の force-push 挙動全般（impl-resume の正規動作として維持）
- 設計 PR（`claude/issue-<N>-design-*`）の close / merge 状態と Issue ラベルの自動連動（Issue #40 / DRR の責務）
- 人間が `claude-failed` を除去した瞬間に `ready-for-review` を自動付与する仕組み（Issue 本文の対策 3。本要件では Requirement 1 の watcher 側 PR 検出で代替する）
- 既に発生した事故ログ（PR #62 orphan 化）のバックフィル / 修復
- linked PR 検出による skip 判定を bypass する明示的な opt-out フラグ（運用上必要になった時点で別 Issue で検討）
- 複数の impl PR が同一 Issue に紐付く場合の優先度判定の詳細（state 判定上は OPEN > MERGED > CLOSED の包含関係で十分。詳細は design に委ねる）

## Open Questions

> 以下は Architect が design.md 着手時に確定する設計判断ポイント。Issue 本文に示唆があるものは「示唆あり」として記載するが、最終決定は Architect が行う。

- linked impl PR 検出の API 方式（GraphQL `closingIssuesReferences` を採用するか、REST `gh pr list --search` 系で代替するか、ls-remote ベースで代替するか）。Issue 本文では GraphQL 方式が「推奨」とされており、PjM の impl PR は `Closes #N` 形式で本文記述するため `closingIssuesReferences` で取得可能（Issue #40 の design.md で言及されている「PjM が `Refs #N` を使うため `closingIssuesReferences` が空集合になる」制約は **設計 PR にのみ適用** されることに注意）
- 判定タイミング（claim 前 vs worktree reset 後）。Issue 本文では「claim 前」が示唆されており、Requirement 1.1 でも「claim する前」と規定したが、具体的な実装位置（Dispatcher 関数内 / Slot 関数内 / 他処理系との順序）は design に委ねる
- API レート制限の具体的な対策方法（per-cycle キャッシュ / pickup 候補件数の上限 / 単一 GraphQL クエリでの batch 取得 / fail-open vs fail-closed の選択）。NFR 4 では「呼び出し回数を制御する」「レート制限時は skip + ログ」の動作観点のみを規定し、実装手段は design に委ねる
- linked PR の「impl PR / design PR」判別ロジック（head branch pattern `^claude/issue-<N>-impl-` で判定するか、PR 本文内の `Closes #N` / `Refs #N` で判定するか、`closingIssuesReferences` の含有有無で判定するか）。Requirement 1.6 で区別する義務のみを規定し、判別手段は design に委ねる
- escalation コメント投稿経路の網羅範囲（既存実装には複数の経路があり、Requirement 3.4 で「すべての経路」を要求しているが、対象とする具体的な関数群と差分量の見積もりは design に委ねる）
