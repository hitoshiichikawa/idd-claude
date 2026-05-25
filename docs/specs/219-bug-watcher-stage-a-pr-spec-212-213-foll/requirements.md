# Requirements Document

## Introduction

#212（PR#213 で close 済み）は Stage C の下流冪等ガード（同一サイクル内で 2 本目の impl PR 作成を抑止し、既存 PR の状態を OPEN=再利用 / MERGED=着地済み停止 / CLOSED=人間判断委譲で分岐する）を追加したが、根本原因である「Stage A（PM + Developer のみ・PR 作成禁止のステージ）の worker が制約に反して Reviewer / PjM まで起動し先行 PR を作成する越境」は未対応のまま残った。越境は #204 / #216 の 2 件で観測され、いずれも tasks.md 不在の design-less impl 経路（Stage A フォールバック）で発生している。さらに、越境で作られた先行 PR が requirements.md / review-notes.md を含まないまま human merge されると、#213 の MERGED ガードが救済 PR を抑止し、spec ディレクトリが impl-notes.md のみの不完全状態で確定してしまう（#216 で実発生し、手動 PR#218 で補完された）。本要件は、(1) Stage A の越境を抑止・検出し後段へ引き継ぐこと、(2) 越境有無やどのステージが PR を作るかに関わらず最終的に main の spec ディレクトリが標準構成を満たすこと、の 2 領域を user/operator-observable な結果として定義する。実装手段の選択（越境検出 vs プロンプト弱化、補完 PR vs 完了ゲート）は `design.md` に委ねる。

## Requirements

### Requirement 1: Stage A の越境抑止（PR 作成・後段サブエージェント起動の禁止の実効性向上）

**Objective:** As a watcher 運用者, I want Stage A の worker が PR 作成や後段サブエージェント起動へ越境しないよう抑止すること, so that 先行 PR による spec 成果物の不完全化を発生源で減らせる

#### Acceptance Criteria

1. While Stage A を実行しているとき, the Stage A worker shall impl PR を作成しない
2. While Stage A を実行しているとき, the Stage A worker shall Reviewer サブエージェントを起動しない
3. While Stage A を実行しているとき, the Stage A worker shall project-manager（PjM）サブエージェントを起動しない
4. Where Stage A が design-less impl 経路（tasks.md 不在で Stage A へフォールバックした経路）であるとき, the Stage A プロンプト shall worker の責務を「PM + Developer の単一ステージ」に限定する記述を含み、フロー全体（Reviewer / PjM 起動・PR 作成）の完遂を促す表現を含めない

### Requirement 2: Stage A 完了直後の越境検出とログ記録

**Objective:** As a watcher 運用者, I want Stage A 完了直後に先行 PR の有無を観測して越境を検出・記録すること, so that 越境が起きた事実を後段の整合性チェックと運用判断に引き継げる

#### Acceptance Criteria

1. When Stage A が完了したとき, the Watcher shall 当該 head ブランチに紐づく impl PR が既に作成されているかを観測する
2. When Stage A 完了直後の観測で当該 head ブランチへの impl PR が既に存在することを検出したとき, the Watcher shall それを越境として既存ログ書式でログへ記録する
3. When 越境を検出してログへ記録したとき, the Watcher shall 検出した PR 番号と head ブランチを判定根拠としてログに含める
4. When 越境を検出したとき, the Watcher shall その検出結果を後段の spec 成果物完全性チェック（Requirement 3）へ引き継ぐ
5. While `STAGE_CHECKPOINT_ENABLED` が `true` 以外（明示 opt-out その他の任意の値）であるとき, the Watcher shall 本越境検出を実行せず本修正導入前と完全に同一の挙動を保つ

### Requirement 3: spec 成果物の完全性保証

**Objective:** As a watcher 運用者, I want 越境有無やどのステージが PR を作るかに関わらず最終的に main の spec ディレクトリが標準構成を満たすこと, so that spec ディレクトリが impl-notes.md のみの不完全状態で確定するのを防げる

#### Acceptance Criteria

1. The Watcher shall main の spec ディレクトリが標準構成（requirements.md / review-notes.md / impl-notes.md、design 系を含む Issue では追加で design.md / tasks.md）を満たすことを最終状態として保証する
2. When 当該 head ブランチの先行 impl PR が MERGED 済みであり、かつ spec ディレクトリに requirements.md または review-notes.md が不足していることを検出したとき, the Watcher shall 不足している spec 成果物の欠落を解消する処理を実行する
3. If spec 成果物の欠落を watcher が自動で解消できないとき, the Watcher shall その欠落を人間が判別可能な形でエスカレーションする
4. When spec 成果物の不足を検出したとき, the Watcher shall 不足しているファイル種別と対象 spec ディレクトリを判定根拠として既存ログ書式でログへ出力する
5. While spec ディレクトリが標準構成を既に満たしているとき, the Watcher shall 追加の補完処理を実行せず本修正導入前と同一の挙動を保つ

### Requirement 4: #213 Stage C 冪等ガードとの整合

**Objective:** As a watcher 運用者, I want 本機能が #213 の Stage C 冪等ガードの判定と衝突しないこと, so that 既存の二重 PR 防止挙動を退行させずに成果物完全性を上乗せできる

#### Acceptance Criteria

1. When 当該 head ブランチの既存 impl PR が OPEN / MERGED / CLOSED のいずれかで検出されたとき, the Watcher shall #213 の Stage C 冪等ガードの状態別分岐（OPEN=再利用 / MERGED=着地済み停止 / CLOSED=人間判断委譲）を退行させない
2. When 先行 impl PR が MERGED 済みで spec 成果物が不足しているケースを処理するとき, the Watcher shall #213 の MERGED ガードによる新規 impl PR 抑止を維持する
3. Where spec 成果物の補完が必要なとき, the Watcher shall その補完を impl PR とは区別される追従処理として扱い、新規 impl PR を二重に作成しない

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While 通常の design-full impl（tasks.md ありの impl-resume 経路）であるとき, the Watcher shall 本修正導入前と user-observable な挙動（PR 作成本数・成功ログ・return 値）を変えない
2. The Watcher shall 既存 env var 名（`STAGE_CHECKPOINT_ENABLED` 等）の意味と既定値を変更しない
3. The Watcher shall 既存のラベル遷移契約（`claude-picked-up` / `claude-failed` / `needs-decisions` の付与・除去の意味）を変更しない
4. The Watcher shall Stage 成功時の return 0 / 失敗時の return 1 という既存 exit code の意味を変更しない
5. The Watcher shall 既存ログ行の書式を変更しない

### NFR 2: 冪等性

1. While `STAGE_CHECKPOINT_ENABLED=true` であるとき, when 同一 head ブランチに対して越境検出または spec 成果物補完の処理が 2 回以上到達したとき, the Watcher shall 重複した補完 PR を作成しない
2. While self-hosting 環境（idd-claude 自身を対象 repo として運用する状態）であるとき, the Watcher shall 同一サイクルの再実行で重複した PR・重複したエスカレーションを生成しない

### NFR 3: 可観測性

1. When 越境を検出したとき, the Watcher shall 検出根拠（先行 PR 番号・head ブランチ・越境判定）を人間が grep で識別可能な粒度でログへ出力する
2. When spec 成果物の不足を検出または補完したとき, the Watcher shall 判定・処理根拠（不足ファイル種別・対象 spec ディレクトリ・補完/エスカレーションの別）を人間が grep で識別可能な粒度でログへ出力する

## Out of Scope

- 既に作成・MERGED されてしまった先行 impl PR 自体の自動 close / 自動削除 / 本文補正。
- #213 の Stage C 冪等ガードの状態別分岐ロジック（OPEN/MERGED/CLOSED）の変更（本要件は退行させない整合のみを求める）。
- `STAGE_CHECKPOINT_ENABLED=false`（明示 opt-out）環境での越境検出・成果物補完。本機能は Stage Checkpoint モジュールと整合させ opt-out 時は無効とする（NFR 1 / Requirement 2.5）。
- gh API 以外（GitHub Webhook / Actions 連携等）を用いた越境検出手段の導入。
- 越境を起こす claude サブエージェント実行系（Reviewer / PjM 起動制御）の watcher 外（プロンプト以外）のランタイム的強制（例: サブエージェント起動の物理的ブロック機構）。本要件はプロンプトによる責務限定（Requirement 1.4）と完了後の観測（Requirement 2）に限定する。
- 課題 1 と課題 2 の実装手段の確定（越境検出強化 vs プロンプト弱化、補完 docs-only 追従 PR vs Stage A 完了ゲートでの push 保証）。手段選択は `design.md` の領分とする（下記「確認事項」参照）。

## 確認事項（Open Questions）

- **課題 2 の解消手段（design 判断）**: spec 成果物の欠落解消を「MERGED 後の補完 docs-only 追従 PR 作成」で行うか「Stage A 完了ゲートで成果物 push を保証する（push 前提を満たさなければ Stage C へ進ませない）」で行うかは、Architect が後方互換性・冪等性・#213 ガードとの整合を踏まえて決定する。Requirement 3 は観測可能な最終結果（標準構成の充足）のみを規定する。
- **課題 1 の主対策（design 判断）**: 越境抑止を「Stage A 完了直後の越境観測＋後段引き継ぎ」（Requirement 2）に重きを置くか「design-less impl 時の Stage A プロンプトからオーケストレーター表現・フロー全体提示を弱める」（Requirement 1.4）に重きを置くか、両者の比重と具体的な記述変更は Architect が決定する。
- **補完 PR を採用する場合の MERGED ガードとの両立方式**: Requirement 4.3 で「impl PR と区別される追従処理」とした補完を、#213 の MERGED ガードがどの判定点で許容するか（補完専用の判定経路を設けるか、既存ガードの分岐に docs-only 例外を足すか）は design で確定する。
- **エスカレーション手段の具体**: Requirement 3.3 の「人間が判別可能な形でのエスカレーション」を `needs-decisions` ラベル付与＋Issue コメントで行うか、ログ警告のみに留めるかは、過剰通知を避ける既存方針（#212 の OPEN/MERGED はログのみ・CLOSED はコメント必須）との整合を見て design で確定する。
- 上記以外で人間判断が必要な未確定点は現時点でなし（Issue #219 はコメント 0 件で、人間による追加決定は未提示）。

## 関連

- Related: #212 #213 #204 #216
