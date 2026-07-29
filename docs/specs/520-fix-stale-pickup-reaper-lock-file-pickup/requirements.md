# Requirements Document

## Introduction

Stale Pickup Reaper（#379）は、watcher セッションの異常終了で `claude-picked-up` /
`claude-claimed` ラベルが取り残された孤児 Issue を、3 観点（marker 経過時間 / slot ロック非保持 /
セッション不在）の AND 判定で「非アクティブ」と確定した場合にのみ `auto-dev` へ自動復帰させる。
しかし、セッション不在判定（本書では `sess` 値と呼ぶ）に構造的な誤りがあり、`STALE_PICKUP_REAPER_ENABLED=true`
を有効化しても孤児が回収されない事象が feedman 運用で 2 回発生した（feedman#223 / feedman#234）。

原因は、slot lock file の保持プロセスを問い合わせる手段（`fuser` / `lsof` 等）が **利用可能でありながら
保持プロセスを 1 件も返さない**（＝保持者が既に死んでいる）状態を、根拠取得失敗として safe-side
（セッションの可能性あり = `sess=1`）に倒していた点にある。flock 方式の lock file は保持プロセスが死んでも
ファイル自体はディスクに残るため、「file 存在 + 保持者なし」はまさに検出したい「孤児」状態そのものである。
これを生存扱いにするため、一度でも lock file が残ると reaper は当該 repo で永久に機能しなくなる。

本修正は、#379 の Req 3.4（根拠取得失敗時の safe-side fallback）の意図を「保持プロセス問い合わせ手段が
**不在**のときのみ safe-side」に限定・修正し、「手段は利用可能だが保持者が検出されない」ケースを
「セッションなし（`sess=0`）」と正しく判定させる。生存中セッションの誤回収ゼロは引き続き最優先で維持する。

## Requirements

### Requirement 1: 無保持の残存 lock file をセッションなしと判定する

**Objective:** As a idd-claude 運用者, I want 保持プロセスが存在しない残存 lock file を「セッションなし」と判定させる, so that 一度残存した lock file が原因で孤児 pickup が永久に回収されなくなる状態を解消できる

#### Acceptance Criteria

1. When 対象 repo の slot lock file が存在し、保持プロセス問い合わせ手段（`fuser` / `lsof` 等）が利用可能で、当該 lock file を保持しているプロセスが 1 件も検出されない, the Stale Pickup Reaper shall セッション存在判定を `sess=0`（セッションなし）とする
2. When slot lock file が存在し、保持プロセスの pid を取得したが取得した pid がすべて非生存（生存確認に失敗）である, the Stale Pickup Reaper shall セッション存在判定を `sess=0`（セッションなし）とする
3. When 対象 repo の slot lock file が 1 つも存在しない, the Stale Pickup Reaper shall セッション存在判定を `sess=0`（セッションなし）とする

### Requirement 2: 生存セッションの保護（誤回収ゼロ維持）

**Objective:** As a idd-claude 運用者, I want 実際に処理中のセッションが保持する lock file を「セッションあり」と判定させ続ける, so that 進行中作業の pickup ラベルが誤って剥がされる二重処理・branch 競合を防げる

#### Acceptance Criteria

1. When slot lock file が存在し、当該 lock file を保持している生存プロセスが 1 件以上検出される, the Stale Pickup Reaper shall セッション存在判定を `sess=1`（セッションの可能性あり）とする
2. While 複数の slot lock file が存在する, when いずれか 1 つでも生存する保持プロセスが検出される, the Stale Pickup Reaper shall セッション存在判定を `sess=1` とし、他 slot が無保持であっても `sess=0` へ倒さない

### Requirement 3: 問い合わせ手段不在時の safe-side fallback の限定

**Objective:** As a idd-claude 運用者, I want 保持プロセスを観測する手段自体が使えない環境でのみ安全側に倒させる, so that #379 Req 3.4 の保守的 fallback を維持しつつ、その適用範囲を過剰に広げない

#### Acceptance Criteria

1. If slot lock file は存在するが保持プロセスを問い合わせる手段（`fuser` / `lsof` 等）がいずれも利用できない, the Stale Pickup Reaper shall セッション存在判定を `sess=1`（セッションの可能性あり）として safe-side に倒す
2. The Stale Pickup Reaper shall #379 Req 3.4（根拠取得失敗時の safe-side fallback）の適用範囲を「保持プロセス問い合わせ手段が不在のとき」に限定し、「手段は利用可能だが保持プロセスが検出されないとき」を safe-side 扱いから除外する

### Requirement 4: セッション判定理由のログ判別可能性

**Objective:** As a idd-claude 運用者, I want `sess` 値がどの根拠で決まったかをログから区別できるようにする, so that 「保持者あり」「保持者なし」「ツール不在」のどれで判定が確定したかを事後調査で切り分けられる

#### Acceptance Criteria

1. The Stale Pickup Reaper shall 判定根拠ログにおいて既存の `age` / `lock` / `sess` の各フィールド形式を維持する
2. When 生存する保持プロセスを検出して `sess=1` と判定した, the Stale Pickup Reaper shall その判定理由が「保持 pid あり」であるとログから判別できる形で記録する
3. When 保持プロセスが検出されず `sess=0` と判定した, the Stale Pickup Reaper shall その判定理由が「保持者なし」であるとログから判別できる形で記録する
4. When 問い合わせ手段の不在により `sess=1` と判定した, the Stale Pickup Reaper shall その判定理由が「ツール不在」であるとログから判別できる形で記録する

### Requirement 5: 孤児 pickup の自動回収（到達ゴール）

**Objective:** As a idd-claude 運用者, I want 閾値を超過した無保持の孤児 Issue が自動回収されるようにする, so that GitHub API rate limit 等でラベル除去に失敗した Issue を人間の手動復旧なしで復帰できる

#### Acceptance Criteria

1. When 孤児 Issue に対し「marker 経過時間が閾値超」「対応 slot ロック非保持」「セッション存在判定 `sess=0`」の 3 観点がすべて成立する, the Stale Pickup Reaper shall 当該 Issue を非アクティブと確定し復旧アクション（pickup 系ラベル除去 → `auto-dev` 復帰）へ進む
2. While 無保持の残存 lock file がディスク上に残っている, the Stale Pickup Reaper shall 当該 lock file の存在のみを理由に閾値超過の孤児 Issue を回収対象外へ固定しない

### Requirement 6: 回帰防止テスト

**Objective:** As a idd-claude メンテナ, I want 誤判定の再現条件と正常系の双方をテストで固定する, so that 本修正の効果を検証しつつ将来の退行を防止できる

#### Acceptance Criteria

1. The Stale Pickup Reaper のテスト shall 無保持の残存 lock file（保持プロセス問い合わせ手段が利用可能かつ保持者なし）を再現する fixture を備え、セッション存在判定が `sess=0` になることを検証する
2. The Stale Pickup Reaper のテスト shall 実プロセスが lock file を保持中の正常系 fixture を備え、セッション存在判定が `sess=1` になることを検証する
3. The Stale Pickup Reaper のテスト shall 既存 Section 10d（空の保持者問い合わせ結果に対して従来 `sess=1`（rc=1）を固定していたケース）の期待値を `sess=0`（rc=0）へ反転し、当該反転が本修正による意図的な期待値変更であることをテスト内コメントで明示する

## Non-Functional Requirements

### NFR 1: 誤回収ゼロの維持（安全性）

1. The Stale Pickup Reaper shall 生存中の watcher / claude セッションが保持する pickup 系ラベルを本修正の前後で 1 件も誤って除去しない（誤回収件数 = 0 を維持する）

### NFR 2: OS 間の判定同一性

1. The Stale Pickup Reaper shall Linux（`fuser` 経路）と macOS（`lsof` 経路）とで、同一の lock file 保持状態に対し同一のセッション存在判定結果（`sess` 値）を返す

### NFR 3: 後方互換性

1. The Stale Pickup Reaper shall 既存の 3 観点 AND 判定契約（marker 経過時間 / slot ロック非保持 / セッション不在が全て「非アクティブ」のときのみ非アクティブ確定）を変更しない
2. The Stale Pickup Reaper shall marker 経過時間判定と slot ロック保持判定の観測挙動を変更せず、本修正の対象をセッション存在判定に限定する
3. The Stale Pickup Reaper shall 既存 env var 名 / ラベル名 / ログ prefix（`stale-pickup:`）/ 判定フィールド名（`age` / `lock` / `sess`）を変更しない

### NFR 4: 静的解析とドキュメント同期

1. The Stale Pickup Reaper 配布物 shall `shellcheck` を警告ゼロ、`bash -n` をエラーなしでクリアする
2. The Stale Pickup Reaper 配布物 shall セッション判定の safe-side 適用範囲の限定（「ツール不在時のみ safe-side」）を README の該当記述と整合させる

## Traceability

- 元機能: #379（`docs/specs/379-feat-watcher-claude-picked-up-issue-reap/`）。本 Issue は #379 Req 3.4（根拠取得失敗時の safe-side fallback）の適用範囲を「問い合わせ手段の不在時」に限定・修正する位置づけ。
- 対象挙動: #379 Req 3.1 観点 3（セッション存在判定）/ Req 3.4（safe-side fallback）。
- 既存テスト: `local-watcher/test/sr_activity_check_test.sh` Section 10（Requirement 6 AC3 が Section 10d の期待値を反転する）。
- 実運用トリガ: feedman#223（2026-07-27）/ feedman#234（2026-07-29）の孤児化 2 事例。

## Out of Scope

- resumable return 時の `claude-picked-up` 除去リトライ強化（別 Issue へ分割可）
- GitHub API rate limit 対策そのもの
- marker 経過時間判定・slot ロック保持判定のロジック変更（本修正はセッション存在判定のみを対象）
- 3 観点 AND 判定の観点追加 / 削除 / 重み変更
- watcher セッションのプロセス監視・自動再起動・ヘルスチェック機構
- 修正すべきコード行の指定・内部関数構成・関数シグネチャの決定（Architect / Developer の責務）
- 判定根拠ログの全面フォーマット再設計（既存 `age` / `lock` / `sess` 形式を保つ範囲での判定理由付加に限定）

## Open Questions

- なし（Issue 本文が唯一の正準ソース。Issue コメントには bot の起動通知のみで人間の追加決定事項はない）

## 関連

- Related: #379
