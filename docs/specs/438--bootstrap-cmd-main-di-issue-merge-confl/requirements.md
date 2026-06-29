# Requirements Document

## Introduction

複数のドメイン Issue が同一の単一 bootstrap ファイル（`cmd/api/main.go` 等の DI 配線 + Mount スロット）を編集するため、並行 PR が bootstrap ファイルで merge conflict を必ず起こす。この衝突は import の和集合 + 各 Mount の併記で解決できる「加算的（両配線が共存可能）」なものだが、現状の `auto-rebase`（Phase D）の `mechanical` / `semantic` 判定は「変更 path が `MECHANICAL_PATHS` allowlist に閉じているか」だけを見ており、conflict hunk の内容（追加のみか・削除/変更を含むか）を区別しない。結果として bootstrap を含む impl PR は常に `semantic` 扱いになり、approve が dismiss されて `ready-for-review` に出戻り、機械的に解決可能な衝突が人手に落ちる。

本 Issue は 2 つの独立した改善を要件化する。提案1 は idd-claude 運用面の改善で、bootstrap path の「追加行のみの加算的衝突」を安全に `mechanical` 扱いできる緩和経路を導入する。提案2 はテンプレート/設計ガイド面の改善で、`main.go` 一極集中編集を原理的に解消する self-register（registry）パターンを Architect 向け設計指針に追記する。両者は独立した価値を持ち、それぞれ独立タスクに分割可能な形で要件化する。

## Requirements

### Requirement 1: 加算的衝突を判定する緩和の opt-in 制御

**Objective:** As a watcher 運用者, I want bootstrap path の加算的衝突緩和を明示宣言時のみ起動する gate, so that 既存運用に影響を与えずに段階的へ導入できる

#### Acceptance Criteria

1. When 加算的衝突緩和を有効化する env gate が未設定または無効値である, the Auto Rebase Processor shall 緩和を一切起動せず本機能導入前と同一の `mechanical` / `semantic` 判定を行う
2. When 加算的衝突緩和を有効化する env gate が有効値である, the Auto Rebase Processor shall 当該緩和の判定経路を起動する
3. If 加算的衝突緩和を有効化する env gate の値が有効値でも無効値でもない不正値である, the Auto Rebase Processor shall 無効値と同等に扱い緩和を起動しない
4. Where 加算的衝突緩和が有効である場合でも、緩和の判定対象 path を宣言する設定が空である, the Auto Rebase Processor shall いかなる path も加算的緩和の対象とせず従来判定にフォールバックする

### Requirement 2: 加算的衝突の安全判定（追加行のみ・削除/変更なし）

**Objective:** As a watcher 運用者, I want 「両 side とも追加行のみで削除/変更を含まない」衝突だけを加算的と判定する厳密な条件, so that 削除/変更を含む衝突を誤って機械解決してコードを破壊しない

#### Acceptance Criteria

1. While 加算的衝突緩和が有効である, when 当該 rebase の conflict hunk が運用者の宣言した bootstrap path に閉じておりかつ各 conflict hunk が両 side とも追加行のみで削除/変更を含まない, the Auto Rebase Processor shall その rebase を `mechanical` と判定する
2. If conflict hunk のいずれかが削除行または変更行を含む, the Auto Rebase Processor shall その rebase を加算的緩和の対象外とし `semantic` 判定にフォールバックする
3. If 変更 path のうち 1 つでも運用者の宣言した bootstrap path のいずれにも一致しない, the Auto Rebase Processor shall その rebase を加算的緩和の対象外とし `semantic` 判定にフォールバックする
4. If 加算的かどうかの判定に必要な diff / hunk 情報の取得に失敗する, the Auto Rebase Processor shall その rebase を `semantic` 判定に倒す（保守的フォールバック）
5. While 加算的衝突緩和が有効である, when 加算的衝突を `mechanical` と判定した, the Auto Rebase Processor shall 判定根拠（対象 path と加算的と判定した理由）を運用者が追跡できるログに記録する

### Requirement 3: 加算的 `mechanical` 判定後の副作用とゲート維持

**Objective:** As a watcher 運用者, I want 加算的衝突を `mechanical` 判定したときの副作用を既存 `mechanical` 経路と同一に保つ, so that 既存の auto-merge ゲートと検証前提を崩さない

#### Acceptance Criteria

1. When 加算的衝突を `mechanical` と判定した, the Auto Rebase Processor shall 既存 `mechanical` 経路と同一の副作用（approve 維持・`needs-rebase` 除去のみ）に留め、追加コメントを投稿しない
2. While 加算的衝突緩和が有効である, the Auto Rebase Processor shall 和集合解決後の PR を既存の必須 status check（CI / レビューゲート）を経由してから auto-merge へ到達させ、それらの検証ゲートを迂回しない
3. When 加算的衝突を `mechanical` と判定し approve を維持した, the Auto Rebase Processor shall 既存の approve dismissal / `ready-for-review` 復帰 / 説明コメント投稿（従来 `semantic` 経路の副作用）を行わない

### Requirement 4: self-register パターンの設計指針追記

**Objective:** As an Architect（idd-claude が生成する設計の作成者）, I want ドメインごとに init で router へ自己登録する registry パターンの設計指針, so that 単一 bootstrap への一極集中編集を避け並行 Issue の bootstrap 衝突を原理的に解消できる

#### Acceptance Criteria

1. The `design-principles.md` shall 単一 bootstrap への DI 配線/Mount 集中が並行実装の merge conflict ホットスポットになる課題と、self-register（registry）パターンによる回避指針を記述する
2. Where 複数のドメインが同一 bootstrap の配線スロットへ加算的に追記する設計を Architect が検討している, the `design-principles.md` shall self-register パターンを評価対象として提示する
3. The `design-principles.md` shall 当該指針が「必須」か「推奨」かの強制レベルを誤読されない形で明示する

### Requirement 5: 設計指針の二重管理同期

**Objective:** As a idd-claude メンテナ, I want self-register 指針追記を root と repo-template の両系統へ byte 一致で反映する, so that consumer 配布物にドリフトが生じない

#### Acceptance Criteria

1. When `.claude/rules/design-principles.md` に self-register 指針を追記する, the 変更 shall `repo-template/.claude/rules/design-principles.md` にも同一内容で反映され、両ファイルが byte 一致する
2. The 両系統の `design-principles.md` shall `diff` で差分ゼロであることを満たす

## Non-Functional Requirements

### NFR 1: 後方互換性

1. When 加算的衝突緩和を有効化する env gate が未設定である, the Auto Rebase Processor shall 本機能導入前と完全に同一の外部挙動（判定結果・副作用・ログ・exit code）を示す
2. The 本変更 shall 既存 env var 名（`AUTO_REBASE_MODE` / `MECHANICAL_PATHS` 等）・ラベル名・exit code の意味・cron 登録文字列・ログ出力先のいずれも無告知で変更しない
3. When `MECHANICAL_PATHS` allowlist のみが設定され加算的緩和 gate が未設定である, the Auto Rebase Processor shall 従来どおり path allowlist 照合のみで `mechanical` / `semantic` を判定する

### NFR 2: 安全側フォールバック

1. If 緩和の判定に用いる情報が不完全・取得不能・解釈不能である, the Auto Rebase Processor shall `semantic` 側（人間レビュー gate を保護する側）へ倒す
2. The Auto Rebase Processor shall 削除行または変更行を含む conflict hunk を加算的緩和の `mechanical` 対象に決して含めない

### NFR 3: 可観測性

1. When 加算的緩和の判定を行った, the Auto Rebase Processor shall 判定結果（`mechanical` / `semantic`）と判定理由を運用者が後追いできるログへ出力する

### NFR 4: ドキュメント整合

1. When 加算的緩和の外部挙動（新 env gate・判定条件）を追加する, the README shall 同一変更で「オプション機能一覧」相当の該当節へ当該 env gate と既定値・migration note を反映する

## Out of Scope

- AST diff / 言語パーサによる意味的差分判定（言語依存度が高く、提案1 は「追加行のみ・削除/変更なし」の構文的判定に限定する）
- bootstrap 以外の任意ソースファイルにおける加算的衝突の一般的 mechanical 化（対象は運用者が宣言した bootstrap path に限定）
- merge-queue（Phase A）側の conflict 解消ロジックそのものの変更（提案1 の緩和を merge-queue にも入れるかは確認事項）
- self-register パターンを idd-claude が生成する設計へ自動適用・強制する仕組み（提案2 は `design-principles.md` への指針追記に留め、Architect の判断材料を増やすことが目的）
- 特定言語/フレームワーク（Go 等）固有の registry 実装テンプレートの提供
- Claude semantic resolution（Phase D-12 / `AUTO_REBASE_SEMANTIC`）の挙動変更

## Open Questions

- 加算的緩和を有効化する env gate の名称・既定値（既定 OFF の opt-in 制とすることは確定だが、命名は未確定）。
- 加算的緩和の対象 bootstrap path を、既存 `MECHANICAL_PATHS` とは別の専用 env var で宣言するか、`MECHANICAL_PATHS` を流用しつつ別途「加算的判定を許す path」を宣言するか。
- 緩和を `auto-rebase`（Phase D）だけに入れるか、merge-queue（Phase A）の conflict 経路にも入れるか。
- 「加算的」の判定単位（conflict hunk 単位か、ファイル単位か）と、conflict マーカー間に空行のみ・コメントのみが入るケースを追加扱いに含めるか。
- self-register 指針の強制レベルを「必須」とするか「推奨」に留めるか（提案2 本文は idd-claude が生成する設計の改善「指針」と表現しており、推奨止まりが妥当と思われるが未確定）。
- 和集合解決後の `go build` / `vet` / `test` が green であることを緩和経路内で検証する責務を持つか、それとも既存の必須 status check（Requirement 3.2）に委ねるかの切り分け。
