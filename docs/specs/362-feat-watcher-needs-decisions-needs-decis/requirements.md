# Requirements Document

## Introduction

idd-claude の Triage / PM パイプラインは、現状すべての `needs-decisions` ケースで自動進行を停止し、
人間の判断を待つ。この運用は安全だが、`safe`（明確な推奨デフォルトを持ち、機密・コンプラ・不可逆・
外部影響のいずれにも該当しない）論点まで人間ボトルネックに張り付くため、運用効率を下げている。
本機能は Triage / PM が `needs-decisions` 出力時に **分類タグ**（`safe` / `human-only`）を付与し、
新規 env `NEEDS_DECISIONS_MODE` の値に応じて `safe` のみを **PM の第一推奨**で自動続行可能にする。
`human-only`（機密・コンプラ・不可逆・外部影響）は CLAUDE.md「機密情報の扱い」「禁止事項」と整合
させるため、いかなるモードでも自動続行しない。本機能は `FULL_AUTO_ENABLED`（#348 kill switch）配下の
full-auto 系 processor として位置付け、kill switch OFF / 個別 gate 既定（`all-human`）では導入前と
完全に等価な挙動を保つ。パイロット運用先は altpocket-server を想定する。

## 決定済み事項（Issue 本文より）

本要件定義は、Issue #362 本文に明記されている以下の決定事項を前提とする（コメント 0 件のため
本文が唯一の決定源）:

- **分類タグ**: `safe` / `human-only` の 2 値（D-09）
- **`human-only` の定義**: 機密・コンプラ・不可逆・外部影響のいずれかに該当する論点
- **モード**: `NEEDS_DECISIONS_MODE` = `all-human`（既定）/ `classified` / `all-auto`
- **不正値・未設定**: `all-human` に正規化（安全側）
- **自動続行時の採用**: PM の第一推奨（recommendation）
- **kill switch 配下**: `FULL_AUTO_ENABLED`（#348）の AND 二重 opt-in
- **非スコープ**: 分類精度向上のための PM プロンプト改善（必要なら別 Issue）

## Requirements

### Requirement 1: モード env の正規化

**Objective:** As an idd-claude operator, I want the mode env to be normalized to one of three discrete values with a safety-first default, so that typo / 不正値で意図せず自動続行が走るリスクを排除できる

#### Acceptance Criteria

1. The watcher Config block shall declare `NEEDS_DECISIONS_MODE` with a default value of `all-human`
2. When `NEEDS_DECISIONS_MODE` is set to the exact string `all-human`, the watcher shall treat the mode as `all-human`
3. When `NEEDS_DECISIONS_MODE` is set to the exact string `classified`, the watcher shall treat the mode as `classified`
4. When `NEEDS_DECISIONS_MODE` is set to the exact string `all-auto`, the watcher shall treat the mode as `all-auto`
5. If `NEEDS_DECISIONS_MODE` is unset, empty, or set to any value other than the three canonical strings above, the watcher shall normalize the mode to `all-human`
6. The watcher shall complete the `NEEDS_DECISIONS_MODE` normalization before any needs-decisions auto-continue decision is evaluated

### Requirement 2: 分類タグの付与

**Objective:** As an idd-claude operator, I want Triage / PM to label every `needs-decisions` output with a classification tag, so that 後段の自動続行判定が機械可読な根拠で動作できる

#### Acceptance Criteria

1. When Triage / PM emits a `needs-decisions` outcome, the Triage / PM agent shall attach exactly one classification tag chosen from `safe` or `human-only`
2. The Triage / PM agent shall classify a decision as `human-only` if the decision involves any of: 機密情報 / コンプライアンス / 不可逆な変更 / 外部影響
3. The Triage / PM agent shall classify a decision as `safe` only if it has an explicit recommended default (PM 第一推奨) and does not match any `human-only` criterion in 2.2
4. If a decision cannot be confidently classified as `safe`, the Triage / PM agent shall fall back to `human-only`
5. The Triage / PM agent shall record the classification tag in a machine-readable form that the watcher can read in the same cycle without re-invoking the agent

### Requirement 3: 自動続行の発火条件（正常系）

**Objective:** As an idd-claude operator, I want `safe` decisions to auto-continue with the PM's primary recommendation under controlled modes, so that 安全な論点が人間ボトルネックで停滞しない

#### Acceptance Criteria

1. When `NEEDS_DECISIONS_MODE` is `classified` and the classification tag is `safe`, the watcher shall auto-continue the Issue using the PM's first recommendation (recommendation 配列の先頭要素)
2. When `NEEDS_DECISIONS_MODE` is `all-auto` and the classification tag is `safe`, the watcher shall auto-continue the Issue using the PM's first recommendation
3. While the watcher auto-continues a `safe` decision, the watcher shall remove the `needs-decisions` label so that 後続のサイクルで再 Triage / 実装フローに復帰できる
4. While the watcher auto-continues a `safe` decision, the watcher shall record on the Issue (コメント or ログ) which recommendation was adopted so that 運用者が事後監査できる

### Requirement 4: human-only の絶対停止（最重要・異常系）

**Objective:** As an idd-claude operator, I want `human-only` decisions to halt unconditionally regardless of mode, so that 機密・コンプラ・不可逆・外部影響が自動続行で漏れるリスクをゼロにできる

#### Acceptance Criteria

1. If the classification tag is `human-only`, the watcher shall halt the Issue in `needs-decisions` regardless of `NEEDS_DECISIONS_MODE` value
2. If the classification tag is `human-only` and `NEEDS_DECISIONS_MODE` is `classified`, the watcher shall not auto-continue
3. If the classification tag is `human-only` and `NEEDS_DECISIONS_MODE` is `all-auto`, the watcher shall not auto-continue
4. If the classification tag is missing or unrecognized on a `needs-decisions` Issue, the watcher shall treat it as `human-only` and halt
5. If both `safe` and `human-only` tags appear on a single Issue, the watcher shall treat the Issue as `human-only` and halt

### Requirement 5: 既定モード・kill switch との関係（後方互換）

**Objective:** As an idd-claude operator, I want the default mode and the `FULL_AUTO_ENABLED` kill switch to keep current behavior intact, so that 本機能導入が既存運用に副作用を与えない

#### Acceptance Criteria

1. While `NEEDS_DECISIONS_MODE` is `all-human`, the watcher shall produce externally identical behavior to the pre-introduction state for all `needs-decisions` Issues
2. If `FULL_AUTO_ENABLED` is disabled, the watcher shall not auto-continue any `needs-decisions` Issue regardless of `NEEDS_DECISIONS_MODE` value or classification tag
3. When `FULL_AUTO_ENABLED` is enabled and `NEEDS_DECISIONS_MODE` is `all-human`, the watcher shall not auto-continue any `needs-decisions` Issue
4. When `FULL_AUTO_ENABLED` is enabled and `NEEDS_DECISIONS_MODE` is `classified` or `all-auto`, the watcher shall require both conditions to be satisfied before evaluating the classification tag (AND 二重 opt-in)
5. The watcher shall not gate existing non-full-auto features (Triage / PM / Architect / Developer / PjM 等) behind `NEEDS_DECISIONS_MODE`

### Requirement 6: 観測可能性

**Objective:** As an idd-claude operator, I want to observe why a `needs-decisions` Issue was or was not auto-continued, so that 運用ログから判断根拠を後追いできる

#### Acceptance Criteria

1. When the watcher evaluates a `needs-decisions` Issue, the watcher shall emit a log line that includes the resolved `NEEDS_DECISIONS_MODE`, the classification tag, and the final action (`auto-continue` / `halt`)
2. When the watcher suppresses auto-continue due to `FULL_AUTO_ENABLED=false`, the watcher shall emit a log line that identifies the kill switch as the suppression cause
3. When the watcher suppresses auto-continue due to `human-only` classification, the watcher shall emit a log line that identifies the classification as the suppression cause
4. The watcher shall include the resolved `NEEDS_DECISIONS_MODE` value in the cycle startup output so that 運用者が現在のモードを確認できる

## Non-Functional Requirements

### NFR 1: 後方互換性

1. While `NEEDS_DECISIONS_MODE` is unset or set to `all-human`, the watcher shall produce byte-equivalent external side effects (gh / git API 呼び出し / ラベル遷移 / コミット / push) to the pre-introduction state for any `needs-decisions` Issue
2. The watcher shall not rename, repurpose, or remove existing env var names (`FULL_AUTO_ENABLED` / `LABEL_NEEDS_DECISIONS` 等), label names (`needs-decisions` / `claude-claimed` 等), exit code semantics, or cron registration strings as part of this change
3. The watcher shall preserve the existing `needs-decisions` 付与経路（Partial Status Gate #148 / Spec Completeness #219 / Tasks Count #131 / その他）の挙動を変更しない（本機能は既付与 Issue の自動続行可否のみを判定する）

### NFR 2: ドキュメント / 同期

1. The README shall list `NEEDS_DECISIONS_MODE` in the optional feature section with the three canonical values, default value, AND-semantics note with `FULL_AUTO_ENABLED`, and pre-introduction equivalence guarantee for `all-human`
2. The repository shall keep `local-watcher/` ↔ `repo-template/` byte-equivalent for files under shared dual-management scope (`.claude/agents/` / `.claude/rules/` / workflows / labels script) after the change
3. The Triage / PM agent definitions shall document the classification tag semantics (`safe` / `human-only` の判定基準) in their canonical source under `.claude/agents/` and mirror to `repo-template/.claude/agents/`

### NFR 3: 静的解析・テスト

1. The watcher script shall pass `shellcheck` and `bash -n` after the change is applied
2. The repository shall include 近接 test (`local-watcher/test/`) that covers at minimum the following cases: `human-only` halts under `classified` / `human-only` halts under `all-auto` / `safe` auto-continues under `classified` / unset mode behaves as `all-human` / `FULL_AUTO_ENABLED=false` suppresses auto-continue
3. The repository shall include 近接 test that covers the env normalization for at least one invalid / typo value (`Classified` / `auto` / 空文字列 等) falling back to `all-human`

### NFR 4: セキュリティ・運用境界

1. The watcher shall treat any decision involving 機密情報・API key・OAuth token・個人情報・コンプライアンス・契約・不可逆な外部副作用 as `human-only`, consistent with CLAUDE.md「機密情報の扱い」「禁止事項」
2. While `NEEDS_DECISIONS_MODE` is `all-auto`, the watcher shall still enforce 4.1 / 4.4 / 4.5 (human-only halts) as a hard safety boundary

## Out of Scope

- 分類精度向上のための Triage / PM プロンプト改善（Issue 本文「非スコープ」明記。必要なら別 Issue で扱う）
- 既存 `needs-decisions` 付与経路（Partial Status Gate / Spec Completeness / Tasks Count / その他）の挙動変更
- 既存個別 gate（auto-merge / failed-recovery / merge-queue / auto-rebase / promote-pipeline 等）の値・名前・既定値の変更
- 分類タグの後付け retrofit（本機能導入前に付与済みの `needs-decisions` Issue は対象外。新規付与分から適用）
- 自動続行時に採用しなかった recommendation 候補の履歴保存（採用したものは記録するが、不採用候補の永続化は範囲外）
- `NEEDS_DECISIONS_MODE` 設定変更の hot reload（cron 次サイクル以降に反映される運用で十分）
- 分類タグの段階化（`safe-low` / `safe-medium` 等の細分化）
- パイロット運用先（altpocket-server）以外の repo への展開判断（運用ロールアウト計画）

## Open Questions

- 分類タグの **格納場所**（GitHub ラベル / Issue body マーカー / triage JSON フィールド 等）は design.md の領分。要件としては「watcher が同サイクル内で機械可読に読める形」が必須（Req 2.5）
- PM の「第一推奨」がない（recommendation 配列が空 / null）`safe` 出力をどう扱うか → 本要件では「`safe` 判定の前提に recommendation 存在が含まれる」と解釈する（Req 2.3）。Issue で明示要望がないため、Triage / PM 側で recommendation 必須化することで吸収可能。実装時に Architect が PM プロンプトの recommendation 必須化を design.md で扱う想定
- 自動続行後に Issue に残すコメント文面（運用監査用）の必須記載項目（採用 recommendation 本文 / 採用根拠 / モード値）は design.md / Architect の領分

## 関連

- Depends on: #348
- Related: D-08, D-09
