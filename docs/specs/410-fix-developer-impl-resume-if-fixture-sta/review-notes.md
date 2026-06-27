# Review Notes

<!-- idd-claude:review round=1 model=claude-opus-4.7 timestamp=2026-06-26T21:30:00Z -->

## Reviewed Scope

- Branch: claude/issue-410-impl-fix-developer-impl-resume-if-fixture-sta
- HEAD commit: 1e5c483b8734da2f0f89d09db456d537421625c8
- Compared to: main..HEAD
- Changed files:
  - `.claude/agents/developer.md`（+33 行）
  - `repo-template/.claude/agents/developer.md`（+33 行）
  - `docs/specs/410-fix-developer-impl-resume-if-fixture-sta/impl-notes.md`（新規 +65 行）

備考: 本 Issue は prompt 改修のみで Architect 起動なし。`tasks.md` / `design.md` は不在
（requirements.md Out of Scope で「prompt は markdown のため単体テストは Out of Scope」と
明記されており、本 Reviewer は requirements.md と差分の突き合わせで AC カバレッジを判定）。
CLAUDE.md には `## Feature Flag Protocol` 節の `**採否**: opt-in` 宣言が無いため、3 カテゴリ
判定のみで review を行った。

## Verified Requirements

- 1.1 — `.claude/agents/developer.md:289-293`「責務の明示」項で「fixture を新契約に追従させて
  全テストを green にする責務を Developer が負う」と明示
- 1.2 — 同 `:292`「自分の `tasks.md` の `_Boundary:_` 外であっても適用する」で boundary 外
  適用を明示
- 1.3 — 同 `:296-299`「許容される追従は 2 種類のみ」項で (a) 新規契約フィールド値追加 /
  (b) 既存フィールドの型変換・改名 を限定列挙
- 1.4 — 同 `:294-295`「適用範囲の限定」項で「新規公開 IF を追加していない場面で...他要因で
  失敗している場合は本節を適用しない（実装側の問題として扱う）」を明示
- 1.5 — 同 `:292-293`「impl / impl-resume の **両方**で適用され、impl-resume では特に強く
  要求される」で両モード適用と impl-resume の強要求文脈を併記
- 2.1 — 同 `:300-302`「verify が失敗している間は `tasks.md` 全 [x] を `STATUS: complete` の
  根拠とせず」で tasks 全 [x] 不十分を明示
- 2.2 — 同 `:301-302`「verify が green になるまで責務を継続する」で責務継続を明示
- 2.3 — 節見出し `:300`「stage-A-verify green > tasks.md 全 [x]」で優先順位を明文化（不等号
  `>` で明示）
- 2.4 — 同 `:303-305`「`partial_blocked` の温存」項で「既存 STATUS: partial_blocked 経路
  （halt 理由を impl-notes.md に記録）を引き続き利用できる」を明示
- 2.5 — 同 `:302`「**「verify 失敗のまま `STATUS: complete` を出力する」ことは禁止**」で
  明示禁止
- 3.1 — 節冒頭 `:285-286`「`# テスト作成ルール`「既存テストを壊さない」規定への **例外規定**」
  により既存規約の維持を前提とする位置付けを明示
- 3.2 — 節タイトル `:283` および `:285-287` で「fixture 追従責務」が「例外規定」「限定的な
  許容ケース」であることを明示
- 3.3 — `:306-310`「アサーション弱体化禁止」項で (a) 比較対象を緩める / (b) skip / コメント
  アウト / 削除 / (c) mock 強化 / (d) snapshot 盲目更新 の 4 種を列挙
- 3.4 — `:311-312`「判定軸」項で「入力データ追従は許容、期待結果緩和は禁止」の二分法を明文化
- 3.5 — `:313-314`「fixture 追従でも green にできないとき」項で「アサーション緩和を行わず、
  PR 本文『確認事項』または `impl-notes.md` で PM / Architect への差し戻しを提案」経路を明示
- 4.1 — `repo-template/.claude/agents/developer.md` に同一内容 (+33 行) を反映済み（diff 確認）
- 4.2 — `diff -r .claude/agents repo-template/.claude/agents` の出力が空であることを Reviewer
  自身が再実行して確認（exit code 0、no output）
- 4.3 — 追記は「テスト作成ルール」直後・「出力契約」の前に挿入され、既存節は一切書き換えて
  いない（既存 `^STATUS: (.+)$` 契約等は無変更）
- 4.4 — 節冒頭で `# テスト作成ルール` / `# やらないこと（領分違い）` への見出し参照リンクを
  記述し、重複記述を回避
- NFR 1.1 — STATUS 行（`STATUS: complete` / `STATUS: partial_blocked` / `STATUS: partial_overrun`）
  と regex の規定は一切書き換えられていない（diff で確認）
- NFR 1.2 — 既存 env var（`IMPL_RESUME_PRESERVE_COMMITS` 等）の言及・既定値は無変更
- NFR 1.3 — 既存節「impl-resume / tasks.md 進捗追跡規約」「per-task ループ下での Implementer
  の責務」「BLOCKED 宣言の規約」を diff 内で書き換えていない
- NFR 2.1 — 新規追記は 33 行（40 行以内の目安を遵守）
- NFR 2.2 — 許容/禁止行為を箇条書きで列挙、判定軸を 1 文で明文化しており、Developer から
  一義に読み取れる構成

## Findings

なし

## Summary

requirements.md の全 numeric ID（Req 1.1〜4.4 / NFR 1.1〜2.2）が `.claude/agents/developer.md`
の新規節 `:283-315` で 1 対 1 に担保されている。root と `repo-template/` が byte 一致である
ことを Reviewer 自身が `diff -r` で再確認。境界（prompt 二箇所と impl-notes.md のみ）も
逸脱なし。prompt 改修のため自動テスト不要が requirements.md Out of Scope に明記済みであり
missing test には該当しない。

RESULT: approve
