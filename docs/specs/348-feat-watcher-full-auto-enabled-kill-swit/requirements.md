# Requirements Document

## Introduction

idd-claude には複数の full-auto 系 processor（auto-merge / failed-recovery / needs-decisions auto /
semantic conflict / blocked cascade）が存在し、これらは個別の opt-in gate によって有効化される。
不具合発生時に「全 full-auto 挙動を即座に no-op に倒したい」運用ニーズに応えるため、上位の
**単一 kill switch** として `FULL_AUTO_ENABLED` env を導入する。本フラグは個別 gate と AND 関係で
動作し、`FULL_AUTO_ENABLED=true` かつ個別 gate=true の場合のみ full-auto 系 processor が発火する
（二重 opt-in）。未設定 / `false` / typo はすべて安全側 `false` に正規化し、導入前と等価な挙動を
保つ。既存の opt-in 機能（merge-queue / auto-rebase / promote-pipeline 等）は本フラグ配下に
入れず、独立した opt-in のまま維持する（後方互換性）。

## Requirements

### Requirement 1: kill switch env の正規化

**Objective:** As an idd-claude operator, I want a single env var that normalizes to a strict boolean, so that 不具合時に typo / 不正値で意図せず full-auto が走るリスクを排除できる

#### Acceptance Criteria

1. The watcher Config block shall declare `FULL_AUTO_ENABLED` with a default value of `false`
2. When `FULL_AUTO_ENABLED` is set to the exact string `true`, the watcher shall treat the kill switch as enabled
3. If `FULL_AUTO_ENABLED` is unset, empty, `false`, `0`, `True`, `TRUE`, `1`, or any other value, the watcher shall treat the kill switch as disabled
4. The watcher shall complete the `FULL_AUTO_ENABLED` normalization before any full-auto processor entry point is evaluated

### Requirement 2: full-auto 系 processor の入口での参照（AND 二重 opt-in）

**Objective:** As an idd-claude operator, I want full-auto processors to require both the kill switch AND their individual gate, so that 1 つの env を倒すだけで全 full-auto 挙動を即停止できる

#### Acceptance Criteria

1. If `FULL_AUTO_ENABLED` is disabled, the auto-merge processor shall early-return without performing any external side effect
2. If `FULL_AUTO_ENABLED` is disabled, the failed-recovery processor shall early-return without performing any external side effect
3. If `FULL_AUTO_ENABLED` is disabled, the needs-decisions auto processor shall early-return without performing any external side effect
4. If `FULL_AUTO_ENABLED` is disabled, the semantic conflict processor shall early-return without performing any external side effect
5. If `FULL_AUTO_ENABLED` is disabled, the blocked cascade processor shall early-return without performing any external side effect
6. When `FULL_AUTO_ENABLED` is enabled and a full-auto processor's individual gate is disabled, the watcher shall keep that processor as no-op
7. When `FULL_AUTO_ENABLED` is enabled and a full-auto processor's individual gate is enabled, the watcher shall allow that processor to execute its normal flow

### Requirement 3: 後方互換性と既存診断の保全

**Objective:** As an idd-claude operator, I want existing diagnostic tooling and non-full-auto features to remain unaffected, so that kill switch 導入が既存運用に副作用を与えない

#### Acceptance Criteria

1. While `FULL_AUTO_ENABLED` is unset, the watcher shall behave identically to the pre-introduction state for all observable outputs
2. The `issue-watcher.sh --doctor` subcommand shall remain functional regardless of `FULL_AUTO_ENABLED` value
3. The watcher shall not gate existing opt-in features (merge-queue / auto-rebase / promote-pipeline / その他既存 opt-in 機能) behind `FULL_AUTO_ENABLED`
4. When `FULL_AUTO_ENABLED` is disabled, the watcher shall continue to evaluate non-full-auto processors (Triage / PM / Architect / Developer / PjM / merge-queue / auto-rebase / その他既存 opt-in 機能) according to their own gates

### Requirement 4: 観測可能性

**Objective:** As an idd-claude operator, I want to observe whether the kill switch suppressed a full-auto processor in a given cycle, so that 「動かなかった理由」を運用ログから判別できる

#### Acceptance Criteria

1. When `FULL_AUTO_ENABLED` is disabled and a full-auto processor entry point is evaluated, the watcher shall emit a log line that identifies the kill switch as the suppression cause
2. The watcher shall include the resolved `FULL_AUTO_ENABLED` value in cycle startup output so that 運用者が現在の kill switch 状態を確認できる

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `FULL_AUTO_ENABLED` is unset, the watcher shall produce byte-equivalent external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push) to the pre-introduction state for any Issue/PR that would not have been touched by full-auto processors
2. The watcher shall not rename, repurpose, or remove existing env var names, label names, exit code semantics, or cron registration strings as part of this change

### NFR 2: ドキュメント / 同期

1. The README shall list `FULL_AUTO_ENABLED` in the optional feature section with default value, AND-semantics note, and pre-introduction equivalence guarantee
2. The repository shall keep `local-watcher/` and `repo-template/` byte-equivalent for files under shared dual-management scope after the change

### NFR 3: 静的解析

1. The watcher script shall pass `shellcheck` and `bash -n` after the change is applied

## Out of Scope

- 既存 opt-in 機能（merge-queue / auto-rebase / promote-pipeline / pr-iteration / pr-reviewer /
  security-review / design-review-release / stage-checkpoint / stage-a-verify / quota-aware /
  debugger / hooks / dep-auto-unblock 等）の本フラグ配下への取り込み
- 新規の full-auto 系 processor の実装そのもの（本 Issue は kill switch 配線のみ）
- 既存個別 gate（auto-merge / failed-recovery / needs-decisions auto / semantic conflict /
  blocked cascade の各 gate）の値・名前・既定値の変更
- `FULL_AUTO_ENABLED` 設定変更の hot reload（cron 次サイクル以降に反映される運用で十分）
- kill switch の段階化（severity 別 / 機能別グループ別）

## Open Questions

- 「auto-merge / failed-recovery / needs-decisions auto / semantic conflict / blocked cascade」の
  各 processor について、現時点で実装済みのもの・未実装のものの境界は本要件の AC では区別して
  いない（実装済みのみ配線し、未実装のものは将来追加時に同じ kill switch を参照する設計とする
  ことを想定。配線対象の確定は design.md / tasks.md の領分）

## 関連

- Parent: #13
- Related: D-17, D-02
