# Review Notes

<!-- idd-claude:review round=2 model=claude-opus-4-7 timestamp=2026-05-26T00:00:00Z -->

## Reviewed Scope

- Branch: claude/issue-224-impl-feat-watcher-stage-a-verify-verify-archi
- HEAD commit: f578e702344adbd58996a37fdfcf9a0c27d9bf91
- Compared to: main..HEAD

round=2（再 review）。round=1 は「抽出関数 `stage_a_verify_extract_verify_block` は実装済みだが
orphan（`resolve_command` 未呼び出し）で、Task 2〜6 が未実施 / committed test 不在」として
reject（Findings 1〜5）。本 round では各 Finding の是正が観測可能挙動・規約・文書・テストの
レベルで成立しているかを重点確認した。差分は 16 ファイル（+844 / -34）。CLAUDE.md に
`## Feature Flag Protocol` 節は存在しないため opt-out として扱い、flag 観点の細目は適用せず
通常の 3 カテゴリ判定を適用した。`shellcheck --severity=warning`（issue-watcher.sh + modules/*.sh）
はクリーン、smoke script は全 14 ケース pass（いずれも reviewer 側で再実行して確認。lint /
test 結果は参考情報であり lint 単独では reject しない）。

## Verified Requirements

- 1.1 — `stage_a_verify_resolve_command`（stage-a-verify.sh）第 1 段で `stage_a_verify_extract_verify_block` を呼び、well-formed ブロック成功時は short-circuit でそのコマンドのみ採用。smoke `resolve(block-well-formed.md, env=...)` が source=structured-block を assert
- 1.2 — 第 1 段成功時に `return 0` で短絡し heuristic（第 3 段）に到達しない。smoke の structured-block ケースが env を無視して block を採用することで観測確認
- 1.3 — tasks-generation.md「中身は散文ではなく実行可能コマンド」節 + architect.md 宣言手順で要求を明文化
- 1.4 — `extract_verify_block` の awk が fence 中身を raw 改行込みで保持。smoke `block-multiline.md`（`&&` + 行継続）が改行込み抽出を assert。実行は既存 `bash -c "$cmd"`（無変更）に委譲
- 1.5 — センチネル + fence 構造限定パースで散文と構造分離。smoke malformed 群（no-fence / unclosed / empty）が return 1
- 2.1 — 第 2 段 `STAGE_A_VERIFY_COMMAND` 非空で env-command 採用。smoke `resolve(no-block-heuristic.md, env='my-env-cmd')` が source=env-command を assert
- 2.2 — 第 3 段 heuristic 抽出。smoke `resolve(no-block-heuristic.md, env='')` が source=heuristic を assert
- 2.3 — いずれも不可なら `return 1`（SKIPPED）。smoke `resolve(block-empty.md, env='')` が rc=1 source=none を assert
- 2.4 — 構造化ブロック + env 双方存在時はブロック優先（単一決定論順序）。smoke の env-should-be-ignored ケースで実証
- 2.5 — design-less impl（tasks.md 不在）は第 1/第 3 段が return 1 → env→SKIPPED 順序に一致（`extract_verify_block` 冒頭の `[ -f ... ] || return 1`）
- 3.1, 3.2, 3.3 — architect.md「信頼モデル（Architect 定義・Developer 不可侵）」節で設計成果物化・Developer 不変・矛盾時の確認事項指摘を明文化
- 4.1, 4.3, 4.4 — tasks-generation.md「構造化 verify ブロック」節（canonical 書式 / 実コマンド必須 / checkbox・numeric ID 規約非干渉）
- 4.2 — architect.md tasks.md テンプレに `<!-- stage-a-verify -->` + fence の宣言例と宣言手順を追記
- 5.1, 5.2 — design-review-gate.md「verify block well-formed check」節（well-formed 判定 + malformed 違反報告、モジュール側 awk と同一基準の相互参照）
- 5.3 — 同節「verify 対象あり + ブロック/env 両無」は warn 止まり（reject しない）と規定
- 5.4 — 同節「適用範囲」で既存 merge 済み spec を遡及違反としないと明記
- 6.1, 6.2, 6.3 — README「解決順序（fallback 連鎖）」節 + env var 表で第一手段・4 段連鎖・固定 escape hatch 位置づけを記載
- NFR 1.1 — 構造化ブロック無しの既存 spec は第 1 段素通り → env/heuristic に到達。smoke の no-block-heuristic / block-no-fence ケースで後退実証。既存 `extract_command` / `_sav_cmd_starts_with_keyword` は無変更
- NFR 1.2 — `stage_a_verify_run` Gate 1（`STAGE_A_VERIFY_ENABLED=false`）は無変更
- NFR 1.3 — env var 名・既定値は不変。README に #224 migration note（変わったのは用途説明のみ）を併記
- NFR 1.4 — Gate 3 bypass 拡張のみで `bash -c` 受け渡し・失敗ハンドラ・round counter・exit code・ラベル遷移は無変更
- NFR 2.1 — 各解決段で `sav_log "resolve source=<手段>"` を stderr に出力
- NFR 2.2 — 既存 `sav_log` 3 段 prefix 書式を維持（新規 source ログも同経路）
- NFR 3.1 — `extract_verify_block` は決定論パース（最初のブロックのみ採用）。source sidecar は resolve 冒頭でリセットし残値誤判定を回避
- NFR 3.2 — `extract_verify_block` は tasks.md を読み取りのみ（書き換えなし）
- NFR 4.1 — 任意のコマンド文字列を抽出対象とし特定 build tool に非依存

## Findings

なし

## Summary

round=1 の Findings 1〜5 はすべて是正済み。Finding 1（resolve 4 段連鎖化 + Gate 3 bypass）は
`resolve_command` の構造化ブロック第 1 段化と sidecar 経由 source 共有で観測可能挙動として成立、
Finding 2〜4（tasks-generation / architect / design-review-gate / README）の規約・文書も追加され、
Finding 5（missing test）は 8 fixture + smoke script（全 14 ケース pass）で解消。全 numeric ID
（Req 1〜6 / NFR 1〜4）が実装またはテストでカバーされ、boundary 逸脱・AC 未カバー・missing test
いずれも検出されなかったため approve。

RESULT: approve
