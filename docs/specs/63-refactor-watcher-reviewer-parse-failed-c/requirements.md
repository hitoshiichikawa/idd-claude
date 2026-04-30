# Requirements Document

## Introduction

Issue #20 で導入された Reviewer Subagent Gate は、Reviewer の出力 `review-notes.md`
末尾の `RESULT: approve|reject` 行を watcher が抽出してフローを分岐させる契約に
依存している。Issue #52 の impl-resume 実行で、Reviewer は意味的には approve を判定したが、
`RESULT: approve` をバッククォート付きで本文中にインライン記述したため、現行の
Reviewer Result Parser（行頭厳密マッチ・末尾独立行のみ受理）が抽出に失敗し、watcher が
`parse-failed` → `claude-failed` ラベル付与でフロー全体を停止させた。約 21 分の
Developer + Reviewer 処理が廃棄され、人間が PjM ステップを手動補完する事態となった。

本 Issue は、(1) Reviewer Result Parser を「全文 scan + 最後のマッチ採用」方式に
緩和し出力フォーマットの揺らぎに対する耐性を上げること、(2) Reviewer の出力
フォーマット指示を強化し、独立行・装飾なし・OK/NG 例示で逸脱を抑止すること、
の 2 層防御で本事故の再発を防ぐ。後方互換性として、既存の「末尾独立行
`RESULT: approve`」スタイルの Reviewer 出力でも引き続き正常に approve / reject 判定
できることを保証する。

## Requirements

### Requirement 1: Reviewer 出力 parser の緩和（耐装飾性）

**Objective:** As a watcher 運用者, I want Reviewer 出力 parser がバッククォート等の
マークダウン装飾やインライン記述に耐えられること, so that Reviewer が意味的に
approve / reject を判定している限り、表記の揺らぎで `parse-failed` → `claude-failed`
に陥らないようにしたい

#### Acceptance Criteria

1. When the Reviewer Result Parser scans `review-notes.md` and the file contains exactly
   one `RESULT: approve` token in any line (with or without surrounding backticks,
   bullet markers, blockquote markers, or trailing prose), the Reviewer Result Parser
   shall extract `approve` as the final result and exit with success.
2. When the Reviewer Result Parser scans `review-notes.md` and the file contains exactly
   one `RESULT: reject` token in any line (with or without surrounding backticks,
   bullet markers, blockquote markers, or trailing prose), the Reviewer Result Parser
   shall extract `reject` as the final result and exit with success.
3. When the Reviewer Result Parser finds multiple `RESULT: approve|reject` tokens in
   `review-notes.md`, the Reviewer Result Parser shall adopt the **last** occurrence
   (file-order, ignoring decoration) as the final result.
4. When the Reviewer Result Parser scans a `review-notes.md` whose final line is the
   bare `RESULT: approve` or `RESULT: reject` (the historical format defined by Issue
   #20), the Reviewer Result Parser shall continue to extract the result with the same
   decision as before this change.
5. If `review-notes.md` does not exist, the Reviewer Result Parser shall signal a
   parse-failure to the watcher (treated as the existing `parse-failed` condition).
6. If `review-notes.md` exists but contains no `RESULT: approve|reject` token under any
   decoration, the Reviewer Result Parser shall signal a parse-failure to the watcher
   (treated as the existing `parse-failed` condition).
7. The Reviewer Result Parser shall recognize `approve` / `reject` only as lowercase
   tokens (e.g. `RESULT: APPROVE`, `RESULT: Approve` shall not be accepted), to keep
   the contract unambiguous and avoid silent acceptance of typos.

### Requirement 2: Findings 抽出の継続動作

**Objective:** As a watcher 運用者, I want Findings の Category / Target 抽出が parser
緩和後も従来どおり機能すること, so that reject 時の差し戻しメッセージとログに
カテゴリ・対象 ID を引き続き含められる

#### Acceptance Criteria

1. When the Reviewer Result Parser extracts `reject` from a `review-notes.md` that
   includes `**Category**:` and `**Target**:` lines under Findings (the format defined
   by Issue #20), the Reviewer Result Parser shall return the comma-joined Category
   list and the comma-joined Target ID list using the same output contract as before
   this change.
2. When the Reviewer Result Parser extracts `approve`, the Reviewer Result Parser shall
   return empty Category and empty Target ID fields (unchanged from current behavior).

### Requirement 3: Reviewer 出力フォーマット指示の強化

**Objective:** As a Reviewer subagent 保守者, I want Reviewer の出力規約が「独立行・
装飾なし・OK/NG 例示」を明示していること, so that 将来の Reviewer 起動でも
`RESULT:` 行が予測可能な形で末尾に出力され、parser 緩和に依存しすぎない多層防御が
保てる

#### Acceptance Criteria

1. The Reviewer Subagent Definition shall state that the `RESULT: approve` or
   `RESULT: reject` line must appear as the **final standalone line** of
   `review-notes.md`.
2. The Reviewer Subagent Definition shall state that the `RESULT:` line must contain
   no surrounding decoration (no backticks, no bullet markers, no blockquote markers,
   no trailing prose on the same line).
3. The Reviewer Subagent Definition shall include at least one OK example and at least
   one NG example illustrating the decoration / inline-prose pitfall observed in the
   Issue #52 incident.
4. Where the Reviewer Subagent Definition is duplicated for downstream consumer repos
   (template copy), the same strengthened format guidance shall be applied so that
   downstream repos receive the identical contract.

### Requirement 4: 後方互換性

**Objective:** As an idd-claude consumer, I want this fix to be transparent for
already-running watchers and existing PRs, so that no migration step is required and
no existing label / env var contract changes

#### Acceptance Criteria

1. The Watcher shall not introduce any new environment variables for this fix
   (Reviewer parser tuning is internal to the parser implementation).
2. The Watcher shall not change the name, semantics, or transition rules of any
   existing label (`auto-dev` / `claude-picked-up` / `ready-for-review` /
   `claude-failed` / `needs-iteration` / `needs-decisions` / `awaiting-design-review`
   / `needs-rebase` / `skip-triage`).
3. The Watcher shall preserve the existing exit code semantics and log line format used
   by the Reviewer stage (`round=N result=...`), so that downstream log parsers and
   alerting continue to work.
4. When an existing `review-notes.md` produced before this change (final standalone
   `RESULT: approve|reject` line) is re-parsed, the Watcher shall yield the same
   approve / reject decision as before this change.

### Requirement 5: ドキュメント整合

**Objective:** As an idd-claude maintainer, I want the README and the Reviewer agent
guidance to describe the relaxed parser contract and the strengthened output format
expectations, so that future contributors don't accidentally re-tighten the parser or
weaken the agent format guidance

#### Acceptance Criteria

1. The README shall describe, in the Reviewer 出力契約 section, that the parser scans
   the entire `review-notes.md` for `RESULT: approve|reject` tokens (decoration
   tolerated) and adopts the last occurrence.
2. The README shall continue to instruct Reviewer authors / template consumers that
   the canonical output places `RESULT:` as the final standalone line without
   decoration (i.e. the relaxed parser is a safety net, not a license to deviate).
3. Where the strengthened Reviewer format guidance is added to the agent definition
   files, the README cross-reference (if any) shall point to the updated location so
   that maintainers can locate the contract from a single entry point.

## Non-Functional Requirements

### NFR 1: 検証可能性（dogfood fixtures）

1. The Reviewer Result Parser shall be verifiable against a fixture replicating the
   Issue #52 incident (an `approve` token wrapped in backticks and embedded inline in
   prose), and the Parser shall yield `approve` for that fixture.
2. The Reviewer Result Parser shall be verifiable against a fixture containing an
   intentionally inline-decorated `RESULT: reject` token, and the Parser shall yield
   `reject` for that fixture.
3. The Reviewer Result Parser shall be verifiable against a fixture identical to the
   historical "final standalone line" format, and the Parser shall yield the same
   decision as the pre-change parser for that fixture.
4. The Reviewer Result Parser shall be verifiable against a fixture containing zero
   `RESULT:` tokens, and the Parser shall signal a parse-failure.

### NFR 2: 静的検査

1. The watcher shell script(s) modified for the parser change shall pass `shellcheck`
   with no new warnings introduced relative to the pre-change baseline.

### NFR 3: 観測可能性

1. When the Watcher invokes the Reviewer Result Parser and parsing succeeds, the
   Watcher shall log the resolved result (`approve` / `reject`) using the existing
   Reviewer stage log line format, so operators can audit decisions from the watcher
   log file.
2. If the Reviewer Result Parser signals parse-failure, the Watcher shall log
   `result=error reason=parse-failed` using the existing Reviewer stage log line
   format (unchanged from current behavior), so existing alerting on `parse-failed`
   continues to fire only for genuinely unparseable output.

## Out of Scope

- Reviewer Gate 自体の起動条件の変更（#20 本体仕様の範疇）
- Developer / PjM / Triage など Reviewer 以外の subagent 出力 parser の脆弱性修正
  （別 Issue で扱う）
- LLM hallucination 一般への対策
- `parse-failed` 時の自動 retry 機構（対策 4 (a) 候補。本 Issue では取り扱わない）
- `needs-human-review` 等の新規ラベル導入（対策 4 (b) 候補。本 Issue では
  取り扱わない）
- 既存 Issue / PR で発生済みの `claude-failed` への遡及対応（手動運用で対処）
- Reviewer 出力テキスト全体の構造変更（Findings フォーマットや Verified Requirements
  セクションの再設計）

## Open Questions（人間判断の確認事項）

以下は本 Issue 着手前に人間オーナーへの確認が望ましい論点です。**いずれの確認結果に
なっても本要件定義の Requirement 1〜5 / NFR 1〜3 のスコープは変わらない** ことを
前提に、必要なら追補 Issue を分離してください。

1. **対策 3（Reviewer self-discipline での最終行確認指示）の取り扱い**:
   Requirement 3 が prompt 強化（独立行・装飾なし・OK/NG 例示）までを必須にしている
   範囲で十分か、それとも Reviewer に「出力前に最終行を自己チェックする手順」を
   明示するところまで本 Issue で扱うか。
2. **Reviewer 以外の subagent への波及**: 同種の脆弱性が Triage（JSON 抽出）や
   PjM 出力にも潜在しないかの監査を、本 Issue で着手するか別 Issue に切るか。
   Out of Scope として切り離す案を本書では採用済み。
3. **既存 `claude-failed` Issue への遡及対応の方針**: 過去に parse-failed → claude-failed
   になった Issue を手動で再開するためのオペレーション手順（runbook）を本 Issue で
   README に追記するか、運用ノートに留めるか。Out of Scope として切り離す案を本書
   では採用済み。
4. **大文字小文字の許容範囲**（Requirement 1 AC 7 関連）: `RESULT: approve` を
   lowercase 完全一致のみとする現案で問題ないか、`Approve` / `APPROVE` も将来許容
   する余地を残すか。本書では「lowercase のみ受理（既存契約踏襲）」を既定としている。
