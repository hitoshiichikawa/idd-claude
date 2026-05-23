# Requirements Document

## Introduction

idd-claude #125 で導入された Stage A Verify Module は、`tasks.md` の verify セクションから
build/test/lint コマンドを抽出して `bash -c` で再実行するゲートである。現状の抽出ロジックは
キーワードの **部分一致**（`index(line, keyword) > 0`）で行に hit したら **行全体**を採用するため、
たとえば `- lint 緑: \`./gradlew :app:lintDebug\` で新規 error なし` のような **散文 + backtick で
コマンドを引用した行** をそのまま shell に渡してしまい、shell は行頭の "lint" を実行ファイルと
解釈して `exit 127`（command not found）を返す。結果として Developer 実装が正しく完了して
いるにもかかわらず Stage A が連続失敗し、最終的に `claude-failed` ラベルで人間にエスカレートされる。

本要件は、抽出ロジックを **GFM のインラインコード規約に従って backtick 内の中身を優先的に
コマンド本体として取り出す**ように補正し、backtick が無い従来の生コマンド行（例: `./gradlew test`
を行頭から書く形式）も従来通り扱えるようにする。`STAGE_A_VERIFY_COMMAND` env による
escape hatch、`STAGE_A_VERIFY_ENABLED=false` による完全 opt-out、既存ログ規約・差し戻し境界
（Issue #122 整合の round=1/2）はそのまま維持する。

## Requirements

### Requirement 1: backtick で囲まれたコマンドの優先抽出

**Objective:** As a watcher 運用者, I want backtick で引用されたコマンドが行全体ではなくコード
スパン内の中身として抽出されること, so that 散文 + backtick で書かれた verify 行が `exit 127`
で Stage A を落とさなくなる。

#### Acceptance Criteria

1. When verify 行に 1 つ以上のインラインコードスパン（` `` ` で囲まれた範囲）が存在し、その
   いずれかが抽出キーワード集合に一致するとき, the Watcher Stage A Verify Module shall
   一致したコードスパン内の中身（backtick を含まない文字列）を抽出結果として採用する。
2. When verify 行に複数のインラインコードスパンが存在し、そのうち複数が抽出キーワード集合に
   一致するとき, the Watcher Stage A Verify Module shall 同一行内で**最初**に一致したコード
   スパンの中身を抽出結果として採用する。
3. When 抽出キーワード集合に一致するインラインコードスパンを含む verify 行が `tasks.md` 内に
   複数行存在するとき, the Watcher Stage A Verify Module shall 末尾（ファイル末尾に最も近い
   もの）に出現した 1 行のコードスパンを採用する。
4. The Watcher Stage A Verify Module shall インラインコードスパン抽出時に、スパン外の散文・
   日本語・markdown 装飾を抽出結果に含めない。

### Requirement 2: backtick が無い従来形式の後方互換

**Objective:** As a watcher 運用者, I want backtick の無い従来の生コマンド行（行頭から
`./gradlew test` 等を書く形式）が #125 導入前と同等に抽出されること, so that 既に main で
稼働している consumer repo の verify セクションが本修正で挙動変化しない。

#### Acceptance Criteria

1. When verify 行に backtick で囲まれたインラインコードスパンが存在せず、行本体が抽出キーワード
   集合に一致するとき, the Watcher Stage A Verify Module shall 当該行から markdown 装飾
   （行頭の `- ` リスト記号 / 行頭末尾の空白 / numeric ID prefix / checkbox 等）を除いた残り
   全体を抽出結果として採用する。
2. When backtick 不在の verify 行が `tasks.md` 内に複数存在するとき, the Watcher Stage A
   Verify Module shall 末尾（ファイル末尾に最も近いもの）に出現した 1 行を採用する。
3. When `tasks.md` 内に backtick 抽出に該当する行と backtick 不在の生コマンド行が混在する
   とき, the Watcher Stage A Verify Module shall ファイル末尾に最も近い verify 行を採用し、
   その行が backtick を含むか否かに応じて Requirement 1.1 または Requirement 2.1 のいずれかの
   抽出規則を適用する。

### Requirement 3: 複数行 fenced code block の扱い

**Objective:** As a watcher 運用者, I want \`\`\`bash ... \`\`\` 等の複数行 fenced code block を
誤って 1 行として連結実行しないこと, so that 複数行 fenced ブロックを含む verify セクションが
誤動作で Stage A を落とさない。

#### Acceptance Criteria

1. When verify セクションに複数行 fenced code block（` ``` ` フェンスで囲まれた範囲）のみが
   存在し、インラインコードスパンや backtick 不在の生コマンド行が存在しないとき, the Watcher
   Stage A Verify Module shall 当該 verify セクションを抽出対象として認識せず SKIPPED として
   処理を継続する。
2. If 複数行 fenced code block 内の行を誤抽出した結果として shell が解釈不可能なコマンドを
   実行することになるとき, the Watcher Stage A Verify Module shall 当該抽出を行わず SKIPPED
   として処理を継続する。

### Requirement 4: env escape hatch と opt-out の維持

**Objective:** As a 運用者, I want 既存の env 制御（`STAGE_A_VERIFY_COMMAND` /
`STAGE_A_VERIFY_ENABLED`）が本修正後も従来と同一の優先順位・意味で動作すること, so that
未対応形式の verify セクションを持つ consumer repo が env 1 個で escape できる運用が継続する。

#### Acceptance Criteria

1. Where `STAGE_A_VERIFY_COMMAND` env が非空値で設定されているとき, the Watcher Stage A
   Verify Module shall `tasks.md` 解析（backtick 抽出を含む）を bypass し、当該 env 値を
   最優先で実行コマンドとして採用する。
2. While `STAGE_A_VERIFY_ENABLED` が `false` に設定されているとき, the Watcher Stage A
   Verify Module shall stage-a-verify を実行せず、本修正導入前および #125 導入前と
   user-observable に同一の Stage A 完了判定を行う。
3. The Watcher Stage A Verify Module shall `STAGE_A_VERIFY_COMMAND` /
   `STAGE_A_VERIFY_ENABLED` / `STAGE_A_VERIFY_TIMEOUT` の env 名・既定値・意味を本修正で
   変更しない。

### Requirement 5: SKIPPED 経路と観測可能性

**Objective:** As a 運用者, I want backtick 抽出と fallback 抽出のいずれにも該当しない
verify セクションが exit 127 ではなく明示的な SKIPPED として記録されること, so that 散文の
verify セクションでも cron.log から原因を grep 抽出でき、誤動作で Stage A を落とさない。

#### Acceptance Criteria

1. If verify セクションが Requirement 1.1〜Requirement 3.2 のいずれの抽出規則にも該当しない
   とき, the Watcher Stage A Verify Module shall verify 再実行を行わず SKIPPED として
   処理を継続する。
2. When SKIPPED となるとき, the Watcher Stage A Verify Module shall cron.log に
   `stage-a-verify: SKIPPED` を含む結果行を 1 件出力し、SKIPPED 理由（抽出不可 / fenced
   code block のみ / その他）を運用者が grep で識別可能な形式で記録する。
3. The Watcher Stage A Verify Module shall 抽出した shell コマンドを実行する前に、当該
   コマンドが空文字列でないこと、および行頭が抽出キーワード集合のいずれかで始まることを
   確認し、いずれかを満たさない場合は再実行を行わず SKIPPED とする。

### Requirement 6: 既存 verify 経路の挙動不変

**Objective:** As a エージェント運用設計者, I want 本修正が #125 で導入された verify ゲートの
他の責務（差し戻し・エスカレート境界、ログ規約、責務境界）を一切変更しないこと, so that
#125 / #122 / #119 で確定済みの契約が崩れない。

#### Acceptance Criteria

1. The Watcher Stage A Verify Module shall 抽出ロジック以外の挙動（差し戻し境界 round=1/2、
   `claude-failed` 遷移、`stage-a-verify:` ログ prefix、Reviewer / PjM / Developer の責務
   境界）を本修正で変更しない。
2. When 抽出に成功した shell コマンドの再実行 exit code が 0 以外であるとき, the Watcher
   Stage A Verify Module shall 既存（#125）の round=1/2 境界規則に従って差し戻しまたは
   `claude-failed` エスカレートを判定する。
3. The Watcher Stage A Verify Module shall 既存 env 名（`REPO`, `REPO_DIR`, `LOG_DIR`,
   `LOCK_FILE`, `TRIAGE_MODEL`, `DEV_MODEL` 等）の意味・既定値を変更しない。

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Watcher Stage A Verify Module shall backtick を含まない既存形式の verify 行
   （例: 行頭から `./gradlew assembleDebug` を書く形式）に対し、本修正導入前と同一の
   抽出結果を返す。
2. While `STAGE_A_VERIFY_ENABLED` が未設定または `false` であるとき, the Watcher Stage A
   Verify Module shall #125 導入前と user-observable に同一の Stage A 完了判定を行う。
3. The Watcher Stage A Verify Module shall 既存ラベル名（`auto-dev`, `claude-claimed`,
   `claude-picked-up`, `claude-failed`, `needs-iteration` 等）の意味と遷移契約を変更しない。

### NFR 2: 性能

1. The Watcher Stage A Verify Module shall `tasks.md` の抽出処理（backtick 抽出を含む）を
   当該ファイルの行数に対して線形時間（O(N) ※N は行数）で完了する。

### NFR 3: 観測可能性

1. The Watcher Stage A Verify Module shall 本修正で追加される backtick 抽出経路と SKIPPED
   経路のいずれにおいても、cron.log に `[$REPO] stage-a-verify:` prefix 付きの結果行を
   1 件以上出力する。
2. When 抽出結果として採用したコマンドを再実行するとき, the Watcher Stage A Verify Module
   shall 当該コマンド文字列を運用者が grep で識別可能な形式で cron.log に記録する。

### NFR 4: 回帰検出

1. The Watcher Stage A Verify Module shall 以下 4 種の verify 行パターンに対する fixture
   テストを保持する: (a) backtick 内に keyword、(b) backtick 外の散文に keyword（誤抽出
   防止）、(c) backtick 不在の生コマンド行、(d) 複数行 fenced code block のみ。
2. The Watcher Stage A Verify Module shall 抽出キーワード集合の追加・削除があったとき、
   上記 fixture テストで回帰検出可能な形にする。

## Out of Scope

- 抽出キーワード集合そのものの拡張（新言語サポート追加）。本 Issue は **抽出方式の補正**に
  限定し、対応言語の追加は別 Issue とする。
- `tasks.md` の verify 行を本格的な markdown AST パーサで解析する高度ヒューリスティクス
  （言語非依存・bash + awk のみの方針を維持する）。
- Stage B / Stage C の verify ゲート追加。
- Reviewer / PjM / Developer の責務境界の変更。
- 既に `claude-failed` で停止している過去 Issue の遡及的な再実行・修復。
- `STAGE_A_VERIFY_COMMAND` env の構文拡張（複数コマンド指定・shell 関数指定等）。
- 外部 Feature Flag SaaS との連携や A/B テスト機能（本リポジトリは Feature Flag Protocol
  opt-out のため）。

## Open Questions

なし。

仕様確定済みの判断事項:

- backtick 優先方針: Issue 本文「修正方針の候補」のうち **方針 1（backtick 抽出を優先）**を採用。
  方針 2（行頭一致厳格化）は backtick の無い既存形式との互換性が崩れるため不採用。方針 3
  （fenced code block 優先）は本要件 Requirement 3 で「fenced のみは SKIPPED」として扱うことで
  誤動作回避の側面のみ取り込み、抽出対象としては採用しない。
- 複数 backtick が同一行に並ぶ場合: 同一行内の最初に keyword 一致した backtick の中身を採用
  （Requirement 1.2）。実運用で複数 backtick が並ぶ verify 行は稀であり、明確な優先順位を
  定義することで決定論的にする。
- 複数行 fenced code block の扱い: 抽出対象にせず SKIPPED（Requirement 3.1）。fenced ブロック
  内の複数行をどう連結するかは bash の解釈と相性が悪く、誤動作リスクが大きいため。fenced
  ブロックを使う運用者は `STAGE_A_VERIFY_COMMAND` env で明示指定する想定。
- 後方互換維持の優先度: backtick 不在の既存形式（行頭から `./gradlew test` を書く形式）の
  抽出結果は本修正で **完全に維持**する。これは #125 導入後すでに main で稼働している
  consumer repo（本 repo の dogfooding を含む）への影響を最小化するため。
