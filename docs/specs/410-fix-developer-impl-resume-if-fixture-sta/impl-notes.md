# Implementation Notes — Issue #410

## 改修内容

`.claude/agents/developer.md`（root）と `repo-template/.claude/agents/developer.md`
（template）に **新規節 1 つ**を追加した:

- 節タイトル: `# 新規公開 IF 追加で壊れた既存テストの fixture 追従責務（Issue #410）`
- 配置位置: 既存「# テスト作成ルール」節の **直後**（root: 283 行目〜315 行目 / 全 33 行）
- 既存節は一切書き換えていない（NFR 1.3: 既存節「impl-resume / tasks.md 進捗追跡規約」
  「per-task ループ下での Implementer の責務」「BLOCKED 宣言の規約」を温存）
- 既存節への参照リンクを節冒頭に明示し（`# テスト作成ルール` / `# やらないこと（領分違い）`）、
  本節が「例外規定」「限定的な許容ケース」であることを示した（Req 4.4）

## AC Traceability

prompt は markdown のため自動テストは無し。文言レビューで担保（requirements.md Out of Scope に
明記）。各 AC の担保箇所は root の `.claude/agents/developer.md:283-315` の同一節内で確認可能。

| Req ID | 担保箇所（節内記述） |
|--------|---------------------|
| 1.1 | 「責務の明示」項: fixture を新契約に追従させて green にする責務を明示 |
| 1.2 | 「責務の明示」項: 「自分の `tasks.md` の `_Boundary:_` 外であっても適用」 |
| 1.3 | 「許容される追従は 2 種類のみ」項: (a) フィールド値追加 / (b) 型変換・改名 |
| 1.4 | 「適用範囲の限定」項: 新規公開 IF を追加していない場面は本節適用外 |
| 1.5 | 「責務の明示」項: impl / impl-resume の両方に適用、impl-resume で強く要求 |
| 2.1 | 「stage-A-verify green > tasks.md 全 [x]」項: 全 [x] を complete 根拠としない |
| 2.2 | 同上: verify が green になるまで責務継続 |
| 2.3 | 同上の見出し記号「>」で優先順位を明文化 |
| 2.4 | 「`partial_blocked` の温存」項: boundary 不可時は既存 partial_blocked 経路を温存 |
| 2.5 | 「stage-A-verify green > tasks.md 全 [x]」項: 「verify 失敗のまま complete 出力禁止」 |
| 3.1 | 節冒頭の `# テスト作成ルール` 参照: 「既存テストを壊さない」既存規約の維持 |
| 3.2 | 節冒頭の「例外規定」明示: fixture データ追従に限り許容 |
| 3.3 | 「アサーション弱体化禁止」項: 禁止行為 4 種を (a)〜(d) で列挙 |
| 3.4 | 「判定軸」項: 入力データ追従 vs 期待結果緩和の二分法 |
| 3.5 | 「fixture 追従でも green にできないとき」項: PR 確認事項 / impl-notes.md 差し戻し |
| 4.1 | 同一内容を `repo-template/.claude/agents/developer.md` にも反映 |
| 4.2 | `diff -r .claude/agents repo-template/.claude/agents` 出力空を確認 |
| 4.3 | 既存節を温存した位置・文言で追記（テスト作成ルール直後 / STATUS 契約等は触れず） |
| 4.4 | 節冒頭で `# テスト作成ルール` / `# やらないこと（領分違い）` への参照リンクで重複回避 |
| NFR 1.1 | STATUS 契約・regex `^STATUS: (.+)$` を変更せず |
| NFR 1.2 | 既存 env var（`IMPL_RESUME_PRESERVE_COMMITS` 等）の意味・既定値を変更せず |
| NFR 1.3 | 既存節「impl-resume / tasks.md 進捗追跡規約」等を未変更で温存 |
| NFR 2.1 | 新規節 33 行（40 行以内の目安を遵守） |
| NFR 2.2 | 許容/禁止行為を短い箇条書きで例示、判定軸を一文で明文化 |

## byte 一致確認

```
$ diff -r .claude/agents repo-template/.claude/agents
（出力なし）
$ diff -r .claude/rules repo-template/.claude/rules
（出力なし）
```

両ディレクトリとも byte 一致（Req 4.1, 4.2 充足）。

## 確認事項

- なし。requirements.md の Open Questions も「なし」とされており、解釈の余地は実装中に
  発生しなかった
- prompt 改修内容の単体テストは Out of Scope（requirements.md 末尾で明記）。本節の有効性は
  dogfooding（idd-claude self-hosting + consumer repo 配布後の E2E 観察）で担保される

STATUS: complete
