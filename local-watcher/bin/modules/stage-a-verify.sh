#!/usr/bin/env bash
# shellcheck shell=bash
# stage-a-verify.sh — watcher の Stage A Verify ゲートモジュール
#
# 用途:
#   issue-watcher.sh から切り出した Stage A Verify Module (#125) の関数定義を集約する。
#   Stage A（Developer 実装）完了直前に tasks.md 末尾の build/test/lint コマンド（verify
#   タスク）を watcher 自身が REPO_DIR で独立再実行し、Developer の自己申告のみで build
#   不通が Stage A を通過するのを防ぐゲート。STAGE_A_VERIFY_ENABLED で gate。
#   - sav_log / sav_warn / sav_error           : `stage-a-verify:` prefix logger
#   - _sav_cmd_starts_with_keyword             : verify keyword 行頭一致判定
#   - stage_a_verify_extract_command           : tasks.md 末尾走査 + keyword 一致抽出
#   - stage_a_verify_extract_verify_block       : tasks.md センチネル付き構造化 verify ブロックの厳密パース抽出
#   - stage_a_verify_resolve_command           : 構造化ブロック → env → heuristic → SKIPPED の 4 段 fallback 連鎖
#   - stage_a_verify_round_path / _read_round / _bump_round / _reset_round
#                                              : sidecar による round counter 永続化
#   - _sav_handle_failure                      : round=1 差し戻し / round=2 escalate
#   - stage_a_verify_run                       : 統合ランナー（戻り値 0=pass / 1=差し戻し / 2=claude-failed）
#
# 分割の経緯（#181 design.md decision 2）:
#   Part 1 境界マップは Stage A Verify を impl-gates.sh へ集約する想定だったが、Issue #181
#   のスコープは stage_a_verify_run / sav_* のみで sc_*（Stage Checkpoint）/ tc_*（Tasks Count）
#   は対象外のため、独立モジュール stage-a-verify.sh として分離する。元コードでは
#   sav_* は 2 つの非連続領域（Region 1: logger〜reset_round / Region 2: _sav_handle_failure /
#   stage_a_verify_run）に分かれていたが、source は全関数を実行前に読み込むため 1 ファイルへ
#   統合しても挙動は等価（元コードの「順序維持」コメントは可読性配慮でランタイム要件ではない）。
#
# 配置先:
#   $HOME/bin/modules/stage-a-verify.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - グローバル変数（$REPO / $REPO_DIR / $SPEC_DIR_REL / $LOG_DIR / $NUMBER /
#     $STAGE_A_VERIFY_ENABLED / $STAGE_A_VERIFY_COMMAND / $STAGE_A_VERIFY_TIMEOUT 等）は
#     本体冒頭の Config ブロックで定義済み。bash の遅延束縛により呼び出し時に解決される。
#   - cross-module 呼び出し: _sav_handle_failure → mark_issue_failed（impl-pipeline 系 / 本体）。
#     stage_a_verify_run → _sav_handle_failure。いずれも run_impl_pipeline 実行前に全モジュールが
#     source されるため、呼び出し時点で定義済みであり挙動不変。
#   - call site（run_impl_pipeline 内の stage_a_verify_run）は本体に残置する。
#   - 外部 CLI: gh / git。
#
# セットアップ参照先:
#   - 設計: docs/specs/181-feat-watcher-issue-watcher-sh-part-3-pr/design.md（decision 2）
#   - 機能設計: docs/specs/125-feat-watcher-stage-a-tasks-md-verify-bui/design.md

# stage-a-verify 専用ロガー（既存 qa_log と同形式 / Issue #119 規約）。
# 行頭 `[YYYY-MM-DD HH:MM:SS] [$REPO] stage-a-verify:` の 3 段 prefix を維持し、
# `grep '\[.*\] stage-a-verify:'` で全件抽出可能（NFR 4.1, NFR 4.2）。
sav_log() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: $*"
}
sav_warn() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: WARN: $*" >&2
}
sav_error() {
  echo "[$(date '+%F %T')] [$REPO] stage-a-verify: ERROR: $*" >&2
}

# ─── _sav_cmd_starts_with_keyword ───
#
# 抽出した shell コマンド ($1) が verify keyword 集合のいずれかで「行頭一致」
# するかを確認する。`stage_a_verify_run` の Gate 3 として `stage_a_verify_extract_command`
# 側の strict 抽出に対する defense-in-depth として使う（#160 Req 5.3）。
#
# 注: keyword 集合の Single Source of Truth は `stage_a_verify_extract_command`
#     内の awk script に渡される `_SAV_KEYWORDS` である。本関数の keyword リストは
#     当該定義と **完全一致** している必要があり、追加時は両方を更新すること
#     （tasks-generation.md の design.md「Components and Interfaces /
#     stage_a_verify_extract_command」を参照）。
#     抽出関数側で既に行頭一致を保証しているため、本関数のチェックが SKIPPED に
#     倒すケースは「将来抽出関数の挙動が緩んだ場合のセーフティネット」と
#     「将来の caller 拡張」を想定したもの。
#
# 入力: $1 = 抽出済み shell コマンド文字列
# 戻り値: 0 = いずれかの keyword で開始 / 1 = 一致しない（= SKIPPED 候補）
_sav_cmd_starts_with_keyword() {
  local cmd="$1"
  case "$cmd" in
    "./gradlew"*) return 0 ;;
    "gradle "*) return 0 ;;
    "mvn "*) return 0 ;;
    "npm test"*) return 0 ;;
    "npm run"*) return 0 ;;
    "npm ci"*) return 0 ;;
    "pnpm "*) return 0 ;;
    "yarn "*) return 0 ;;
    "cargo "*) return 0 ;;
    "go test"*) return 0 ;;
    "go build"*) return 0 ;;
    "go vet"*) return 0 ;;
    "pytest"*) return 0 ;;
    "python -m pytest"*) return 0 ;;
    "python -m unittest"*) return 0 ;;
    "make test"*) return 0 ;;
    "make build"*) return 0 ;;
    "make check"*) return 0 ;;
    "make verify"*) return 0 ;;
    "bundle exec"*) return 0 ;;
    "rake "*) return 0 ;;
    "dotnet test"*) return 0 ;;
    "dotnet build"*) return 0 ;;
    "shellcheck"*) return 0 ;;
    "actionlint"*) return 0 ;;
    "tox "*) return 0 ;;
    "swift test"*) return 0 ;;
    "swift build"*) return 0 ;;
  esac
  return 1
}

# ─── stage_a_verify_extract_command ───
#
# `tasks.md` を 1 パスで走査し、抽出キーワード集合に一致した行のうち
# **末尾（ファイル末尾に最も近いもの）** 1 行を stdout に出力する（Req 1.1, 1.2）。
# 抽出は言語非依存な文字列パターンのみで行う（AST 解析しない、Req 1.5 / NFR 2.1）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 抽出成功 / 1 = 一致なし or tasks.md 不在
# stdout: 抽出した shell コマンド 1 行（成功時のみ）
#
# 抽出キーワード集合は design.md「Components and Interfaces /
# stage_a_verify_extract_command」で確定したもの。新言語追加時はここに 1 行追加する
# だけで対応可能。未対応言語は `STAGE_A_VERIFY_COMMAND` env で escape する。
stage_a_verify_extract_command() {
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  [ -f "$tasks_path" ] || return 1

  # 言語非依存 keyword 集合。1 行 1 keyword で空白区切り（awk 内で再分割）。
  # 各 keyword は「行に部分一致したら verify タスクとみなす」最小単位。
  #   - `./gradlew` / `gradle ` / `mvn ` : JVM 系 build tool
  #   - `npm test` / `npm run` / `npm ci` / `pnpm ` / `yarn ` : Node.js 系
  #     （`npm install` は依存解決なので含めない）
  #   - `cargo ` : Rust
  #   - `go test` / `go build` / `go vet` : Go
  #   - `pytest` / `python -m pytest` / `python -m unittest` : Python
  #   - `make test` / `make build` / `make check` / `make verify` : make（target 限定）
  #   - `bundle exec` / `rake ` : Ruby
  #   - `dotnet test` / `dotnet build` : .NET
  #   - `shellcheck` / `actionlint` : shell 系プロジェクト（idd-claude 自身を含む）
  #   - `tox ` : Python tox
  #   - `swift test` / `swift build` : Swift
  local _SAV_KEYWORDS
  _SAV_KEYWORDS=$'./gradlew\n'
  _SAV_KEYWORDS+=$'gradle \n'
  _SAV_KEYWORDS+=$'mvn \n'
  _SAV_KEYWORDS+=$'npm test\n'
  _SAV_KEYWORDS+=$'npm run\n'
  _SAV_KEYWORDS+=$'npm ci\n'
  _SAV_KEYWORDS+=$'pnpm \n'
  _SAV_KEYWORDS+=$'yarn \n'
  _SAV_KEYWORDS+=$'cargo \n'
  _SAV_KEYWORDS+=$'go test\n'
  _SAV_KEYWORDS+=$'go build\n'
  _SAV_KEYWORDS+=$'go vet\n'
  _SAV_KEYWORDS+=$'pytest\n'
  _SAV_KEYWORDS+=$'python -m pytest\n'
  _SAV_KEYWORDS+=$'python -m unittest\n'
  _SAV_KEYWORDS+=$'make test\n'
  _SAV_KEYWORDS+=$'make build\n'
  _SAV_KEYWORDS+=$'make check\n'
  _SAV_KEYWORDS+=$'make verify\n'
  _SAV_KEYWORDS+=$'bundle exec\n'
  _SAV_KEYWORDS+=$'rake \n'
  _SAV_KEYWORDS+=$'dotnet test\n'
  _SAV_KEYWORDS+=$'dotnet build\n'
  _SAV_KEYWORDS+=$'shellcheck\n'
  _SAV_KEYWORDS+=$'actionlint\n'
  _SAV_KEYWORDS+=$'tox \n'
  _SAV_KEYWORDS+=$'swift test\n'
  _SAV_KEYWORDS+=$'swift build'

  # awk 1 パス走査で「直近で keyword に一致した行」を変数 last に保持し、
  # ファイル末尾まで読んだら最後の保持値を出力する（= 末尾に最も近い 1 行、
  # Req 1.2 / #160 Req 1.3, 2.2, 2.3）。O(N) 線形時間（NFR 3.1 / #160 NFR 2.1）。
  #
  # #160 修正: backtick で囲まれたインラインコードスパン（`...`）が行内にあり、
  #   その中身が keyword に一致した場合、**スパン内の中身のみ** を抽出する
  #   （Req 1.1）。散文 + backtick で書かれた verify 行（例: `- lint 緑:
  #   \`./gradlew :app:lintDebug\` で新規 error なし`）が exit 127 を起こす
  #   regression（#125 で導入）を解消する。
  #   同一行に複数のインラインコードスパンが存在する場合は、最初に keyword に
  #   一致したスパンの中身を採用（Req 1.2）。
  #   行内に backtick がペアで存在せず、行全体が keyword に部分一致した場合は
  #   従来通り「装飾除去後の行全体」を採用する（Req 2.1 / 後方互換）。
  #   複数行 fenced code block（` ``` ` フェンスで囲まれた範囲）内の行は
  #   抽出対象から除外する（Req 3.1）。
  # 装飾 strip:
  #   - 行頭の "- " / "  - " / "  - [ ] " 等の markdown bullet と list checkbox
  #   - 行頭 / 行末の空白
  # 抽出結果は装飾を除いたコマンド本体のみ（後段の `bash -c` で実行可能な形）。
  local result
  result=$(awk -v kws="$_SAV_KEYWORDS" '
    BEGIN {
      n = split(kws, ARR, "\n")
      last = ""
      in_fence = 0
    }
    {
      raw = $0
      # 複数行 fenced code block の境界判定（行頭 ``` で開閉、言語タグ任意）。
      # in_fence 状態の行は keyword マッチ対象から除外する（#160 Req 3.1, 3.2）。
      if (raw ~ /^[[:space:]]*```/) {
        in_fence = (in_fence == 0) ? 1 : 0
        next
      }
      if (in_fence) { next }

      line = raw
      # markdown bullet / checkbox / アスタリスク（deferrable 印）の装飾除去
      sub(/^[[:space:]]+/, "", line)
      sub(/^-[[:space:]]+/, "", line)
      sub(/^\[[[:space:]xX]\]\*?[[:space:]]+/, "", line)
      sub(/^[0-9]+(\.[0-9]+)*[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)

      # インラインコードスパン抽出（#160 Req 1.1, 1.2）:
      #   バッククォートで囲まれた中身を順に走査し、最初に keyword に**行頭一致**
      #   したスパンの中身を採用する。
      #   #160 round=2 (Req 5.3): `index(candidate, kw) > 0` だと
      #   `cd app && ./gradlew test` のように冒頭が keyword 以外のスパンも
      #   採用してしまい、`bash -c "cd app && ..."` が走って意図せず副作用を起こす
      #   恐れがあるため `== 1` （= 行頭一致）に厳格化する。span の冒頭が keyword
      #   で始まらない場合は当該 span を抽出対象から外し、次の span を走査する。
      span_hit = 0
      span_content = ""
      tail = line
      while (1) {
        p1 = index(tail, "`")
        if (p1 == 0) { break }
        rest = substr(tail, p1 + 1)
        p2 = index(rest, "`")
        if (p2 == 0) { break }
        candidate = substr(rest, 1, p2 - 1)
        for (i = 1; i <= n; i++) {
          kw = ARR[i]
          if (kw == "") continue
          if (index(candidate, kw) == 1) {
            span_content = candidate
            span_hit = 1
            break
          }
        }
        if (span_hit) { break }
        tail = substr(rest, p2 + 1)
      }
      if (span_hit) {
        last = span_content
        next
      }

      # backtick 無し / backtick はあるが keyword 不一致の場合は、装飾除去後の
      # 行全体が keyword で**行頭一致**するか判定する（#160 Req 2.1 後方互換 +
      # Req 5.3）。
      # ただし line に backtick がペアで含まれる場合は「散文+backtick で keyword は
      # スパン外にしか出現しない」ケース（#160 の本丸 regression）なので行全体採用
      # は誤動作を起こす。よって backtick ペアが存在する場合は line fallback を
      # 行わず、当該行を抽出候補から除外する（Req 1.4 / Req 5.1）。
      # #160 round=2 (Req 5.3): 部分一致 `index(...) > 0` だと
      # `lint を実行する` のような散文の "lint" を `./gradlew :app:lintDebug`
      # 等とマッチさせる可能性があるため、行頭一致 `index(...) == 1` に厳格化する。
      # 既存 12 fixture はいずれも装飾除去後の行頭が keyword で始まるため挙動不変。
      bt_count = gsub(/`/, "`", line)
      if (bt_count >= 2) { next }

      for (i = 1; i <= n; i++) {
        kw = ARR[i]
        if (kw == "") continue
        if (index(line, kw) == 1) {
          last = line
          break
        }
      }
    }
    END {
      if (last != "") print last
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── stage_a_verify_extract_verify_block ───
#
# `tasks.md` のセンチネル付き構造化 verify ブロックから、verify コマンドを
# 決定論的に抽出する純関数（Req 1.1, 1.4, 1.5 / NFR 3.1, NFR 3.2, NFR 4.1）。
# 散文をコマンドと誤認するヒューリスティック抽出（#160/#219/#221 で誤発火）を
# 構造的に避けるための input 契約パス。本関数はヒューリスティック抽出
# （stage_a_verify_extract_command）とは抽出基準が根本的に異なる
# （行頭 keyword 一致 vs センチネル + fence 構造）ため、既存 awk を拡張せず
# 独立関数として分離する（design.md「Components and Interfaces」）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = well-formed ブロック抽出成功 / 1 = ブロック無し or malformed or tasks.md 不在
# stdout: 抽出したコマンド（成功時のみ。複数行は改行・インデント込みで保持）
#
# パース規約（design.md「パース規約（決定論化の詳細）」と同一基準）:
#   - センチネル: 行を trim した結果が厳密に `<!-- stage-a-verify -->` に一致する行を
#     アンカー行とする（前後空白許容、行内の他テキストは不可）。
#   - 直後性: アンカー行の次行以降で空行を任意個スキップした後の最初の非空行が
#     fence 開始（trim 後 ``` で始まる）であること。fence 以外の非空行が先に来たら
#     malformed → return 1。
#   - fence 言語タグ（```sh / ```bash 等）は読み飛ばし、タグ自体は中身に含めない。
#   - fence 終了: 次に現れる trim 後 ``` 行で閉じる。EOF まで閉じなければ malformed。
#   - 中身: fence 開始行と終了行の間の全行。trim 後すべて空なら malformed（空ブロック扱い）。
#     非空なら元の改行・インデントを保持して出力（`&&` 連結や複数行コマンドの意味を壊さない）。
#   - 複数ブロック: 上記を満たす最初のアンカー + fence のみ採用し、以降は無視（決定論）。
#
# 副作用なし（tasks.md を書き換えない、NFR 3.2）。同一入力に同一結果（NFR 3.1）。
stage_a_verify_extract_verify_block() {
  local tasks_path="$REPO_DIR/$SPEC_DIR_REL/tasks.md"
  [ -f "$tasks_path" ] || return 1

  # awk 1 パス走査で「最初の well-formed アンカー + fence」を状態機械で抽出する。
  # state 遷移:
  #   0 = アンカー未検出。trim 後が厳密にセンチネルの行を見つけたら state=1。
  #   1 = アンカー検出済・fence 開始待ち。空行はスキップ。最初の非空行が fence 開始
  #       （trim 後 ``` で始まる）なら state=2、それ以外の非空行なら malformed として
  #       打ち切り（done=1 のまま中身を出さず終了 → END で return 1 相当）。
  #   2 = fence 内・中身収集中。trim 後 ``` の行で閉じて done=1。閉じる前に EOF なら
  #       未クローズ → 中身を出さない。fence 内の各行は raw のまま buf に蓄積する
  #       （元の改行・インデントを保持、Req 1.4）。
  # closed=1 かつ 中身が trim 後非空のときのみ buf を改行込みで出力する。
  # 一致した最初のブロックで done=1 とし、以降は state=0 のまま何もしない（決定論）。
  local result
  result=$(awk '
    BEGIN {
      state = 0       # 0=アンカー待ち / 1=fence 開始待ち / 2=fence 内
      done_flag = 0   # 最初のブロックを処理し終えたら 1（以降は無視）
      closed = 0      # fence が閉じたか
      nonblank = 0    # fence 中身に非空行が 1 行でもあったか
      buf = ""        # fence 中身バッファ（raw を改行区切りで蓄積）
      buf_n = 0       # buf に積んだ行数
    }
    {
      if (done_flag) { next }

      raw = $0
      # trim（行頭行末の空白除去）した判定用文字列を作る。
      t = raw
      sub(/^[[:space:]]+/, "", t)
      sub(/[[:space:]]+$/, "", t)

      if (state == 0) {
        # アンカー行検出（trim 後の厳密一致）。行内の他テキストは不可。
        if (t == "<!-- stage-a-verify -->") {
          state = 1
        }
        next
      }

      if (state == 1) {
        # アンカー直後の空行は任意個スキップ。
        if (t == "") { next }
        # 最初の非空行が fence 開始でなければ malformed → 打ち切り。
        if (t ~ /^```/) {
          state = 2
          next
        }
        done_flag = 1   # malformed。中身を出さずに以降を無視。
        next
      }

      if (state == 2) {
        # fence 終了行（trim 後 ``` で開始）で閉じる。言語タグは開始行のみに付く
        # 想定だが、終了行は単独の ``` が canonical。trim 後 ``` 始まりで閉じる。
        if (t ~ /^```/) {
          closed = 1
          done_flag = 1
          next
        }
        # fence 内の中身は raw のまま蓄積（元の改行・インデントを保持、Req 1.4）。
        if (t != "") { nonblank = 1 }
        if (buf_n == 0) { buf = raw } else { buf = buf "\n" raw }
        buf_n++
        next
      }
    }
    END {
      # well-formed 条件: fence が閉じ、かつ中身に非空行が 1 行以上ある。
      if (closed && nonblank) {
        printf "%s\n", buf
      }
    }
  ' "$tasks_path")

  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# ─── _SAV_RESOLVED_SOURCE ───
#
# 直近の `stage_a_verify_resolve_command` がどの解決手段でコマンドを確定したかを
# 記録するモジュールスコープ変数（design.md「Decision: source の stage_a_verify_run
# への伝達方法」採用案）。値域: structured-block / env-command / heuristic / 空（未解決）。
# `stage_a_verify_run` の Gate 3 bypass 判定が参照する。resolve 呼び出しの度に冒頭で
# 初期化され、前回呼び出しの残値で誤判定しない（NFR 3.1）。
#
# 注意（サブシェル境界）: `stage_a_verify_run` は resolve を command substitution
# （`cmd=$(stage_a_verify_resolve_command)`）で呼ぶため、サブシェル内で代入した
# `_SAV_RESOLVED_SOURCE` は親（run）のプロセスへ伝播しない。そこで resolve は確定した
# source を round counter と同じ流儀の sidecar（`.stage-a-verify-source`）へも書き出し、
# run 側は `_sav_read_resolved_source` でそれを読み戻して Gate 3 判定に使う。モジュール変数
# 代入（同一プロセス内呼び出し用）と sidecar 書き出し（サブシェル越え用）を併用することで、
# 設計の「source をモジュールスコープで共有する」意図をサブシェル境界でも成立させる。
_SAV_RESOLVED_SOURCE=""

# ─── _SAV_LAST_OUTCOME（run サマリ用 outcome 露出 / #239 task 5） ───
#
# 直近の `stage_a_verify_run` がどの outcome で抜けたかを記録するモジュールスコープ変数。
# 値域: success / skip / disabled / round1 / round2 / warn-skipped / warn-tool-missing / 空（未実行）。
# `warn-skipped` は #364 で追加（パス不在 `diff` 失敗を WARN 降格して Stage A 続行した outcome）で、
# success と区別して run サマリ上で false-fail 救済の発生を観測可能にする（Req 4.4 / NFR 4.2）。
# `warn-tool-missing` は #422 で追加（verify ツール（lint / build 等）の未インストール起因の
# exit 127 を WARN 降格して Stage A 続行した outcome）で、`warn-skipped` と 1 対 1 区別される
# （#422 Req 4.4）。両者ともに「real なコード品質失敗とは別軸の WARN 降格」として観測可能。
# `stage_a_verify_run` は
# call site（run_impl_pipeline）と同一プロセスで呼ばれる（command substitution ではない）
# ため、ここに代入した値は call site から読める（_SAV_RESOLVED_SOURCE のサブシェル境界問題は
# resolve が command substitution で呼ばれることに起因するもので、run 自体には当てはまらない）。
# call site は本変数を読み `rs_record_sav` に渡して run サマリの `stage-a-verify=` を確定する。
#
# 設計意図: stage_a_verify_run の戻り値（0/1/2）だけでは success/skip/disabled の 3 状態
# （いずれも return 0）を区別できないため（Req 4.2 が skip/disabled の明示を要求）、戻り値
# 契約を変えずに outcome を別チャネル（本変数）で露出する。`sav_log` の既存出力フォーマット・
# 既存ログ行は一切変更しない（NFR 1.1）。本変数は変数代入のみの副作用で、ラベル遷移 / exit
# code / 既存ログ行に影響しない（NFR 1.2）。
_SAV_LAST_OUTCOME=""

# ─── _sav_source_path ───
#
# source sidecar の絶対パスを stdout に出す。round counter sidecar
# （`stage_a_verify_round_path`）と同じ spec dir 配下に `.stage-a-verify-source` を置く。
# worktree slot ごとの `$REPO_DIR` が自然に slot 隔離を担保する。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 絶対パス（必ず 1 行）
_sav_source_path() {
  printf '%s\n' "$REPO_DIR/$SPEC_DIR_REL/.stage-a-verify-source"
}

# ─── _sav_set_resolved_source ───
#
# 解決手段名 ($1) をモジュール変数 `_SAV_RESOLVED_SOURCE` と source sidecar の双方へ記録する。
# モジュール変数は同一プロセス内呼び出し用、sidecar は command substitution のサブシェル
# 境界を越えて `stage_a_verify_run`（親プロセス）へ source を伝える用途。sidecar 書き込み
# 失敗は致命ではない（Gate 3 が heuristic 同様の defense-in-depth に倒れるだけ）ため警告に留める。
#
# 入力: $1 = 解決手段名（structured-block / env-command / heuristic）
_sav_set_resolved_source() {
  _SAV_RESOLVED_SOURCE="$1"
  local path
  path=$(_sav_source_path)
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '%s\n' "$1" > "$path" 2>/dev/null || \
    sav_warn "source sidecar 書き込みに失敗 path=$path source=$1（Gate 3 bypass 判定が defense-in-depth に倒れます）"
}

# ─── _sav_read_resolved_source ───
#
# source sidecar から直近の解決手段名を stdout に出す。不在 / 読み取り不能なら空文字。
# `stage_a_verify_run` が Gate 3 bypass 判定のために読む（サブシェル越えの source 共有）。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 解決手段名 1 行（不在時は空）
_sav_read_resolved_source() {
  local path
  path=$(_sav_source_path)
  if [ -f "$path" ]; then
    head -n1 "$path" 2>/dev/null | tr -d '[:space:]'
  fi
}

# ─── _sav_reset_resolved_source ───
#
# source sidecar を削除する。resolve 冒頭で前回値をクリアし、未解決（SKIPPED）時に
# 古い source が残って次回 run の Gate 3 判定を誤らせないようにする。不在時は no-op。
_sav_reset_resolved_source() {
  local path
  path=$(_sav_source_path)
  rm -f "$path" 2>/dev/null || true
}

# ─── stage_a_verify_resolve_command ───
#
# verify コマンドを 4 段の fallback 連鎖で決定論的に解決する（design.md「Components and
# Interfaces / stage_a_verify_resolve_command」/ Req 2）。解決順序:
#   1. 構造化 verify ブロック（stage_a_verify_extract_verify_block 成功）→ source=structured-block
#   2. `STAGE_A_VERIFY_COMMAND` env 非空 → source=env-command（散文誤認回避の固定 escape hatch）
#   3. ヒューリスティック抽出（stage_a_verify_extract_command 成功）→ source=heuristic
#   4. いずれも不可 → return 1（SKIPPED, Req 2.3）
# 各段で解決した手段名を `_SAV_RESOLVED_SOURCE` に記録し、`sav_log` で `source=<手段>` の
# 1 行を stderr に出す（NFR 2.1）。stdout はコマンド本体のみに保つ（複数行コマンドを
# そのまま返せるよう、source ログは stdout に混ぜない）。
#
# 構造化ブロックを env の上に置くため、ブロックを持たない既存 spec は第 1 段を素通りし
# env（設定済みなら）または heuristic に到達 → 本機能導入前と user-observable に同一
# （NFR 1.1）。design-less impl（tasks.md 不在）は第 1/第 3 段が return 1 となり、結果として
# 既存の env→SKIPPED 順序に一致する（Req 2.5）。
#
# design-less impl（tasks.md 不在）の SKIPPED は未実装の取りこぼしではなく、
# 「watcher は verify コマンドを推測しない」設計思想（#224 / #228 / #230）に基づく
# 意図された仕様である。tasks.md を持たない design-less impl で verify を推測すると
# 散文誤認事故（#160 / #219 / #221）と同根の問題に逆戻りするため、推測せず SKIP する。
# regression は Developer のテストと Reviewer の AC 判定で担保する（README「Stage A
# Verify Gate (#125)」節参照）。
#
# 入力: 環境変数 STAGE_A_VERIFY_COMMAND / REPO_DIR / SPEC_DIR_REL
# 戻り値: 0 = 解決成功 / 1 = SKIPPED（いずれの手段でも解決不能）
# stdout: 解決した shell コマンド（成功時のみ。構造化ブロック由来は複数行を改行込みで保持）
# stderr: source=<structured-block|env-command|heuristic> の 1 行（sav_log 経由、NFR 2.1）
# 副作用: モジュールスコープ変数 _SAV_RESOLVED_SOURCE を設定する
stage_a_verify_resolve_command() {
  # 前回呼び出しの残値で Gate 3 bypass を誤判定しないよう、毎回冒頭で初期化する
  # （モジュール変数 + sidecar の双方）。
  _SAV_RESOLVED_SOURCE=""
  _sav_reset_resolved_source

  local cmd

  # ── 第 1 段: 構造化 verify ブロック（input 契約・最優先） ──
  if cmd=$(stage_a_verify_extract_verify_block); then
    _sav_set_resolved_source "structured-block"
    sav_log "resolve source=structured-block" >&2
    printf '%s\n' "$cmd"
    return 0
  fi

  # ── 第 2 段: STAGE_A_VERIFY_COMMAND env（固定 escape hatch） ──
  if [ -n "${STAGE_A_VERIFY_COMMAND:-}" ]; then
    _sav_set_resolved_source "env-command"
    sav_log "resolve source=env-command" >&2
    printf '%s\n' "$STAGE_A_VERIFY_COMMAND"
    return 0
  fi

  # ── 第 3 段: ヒューリスティック抽出（後方互換 fallback） ──
  if cmd=$(stage_a_verify_extract_command) && [ -n "$cmd" ]; then
    _sav_set_resolved_source "heuristic"
    sav_log "resolve source=heuristic" >&2
    printf '%s\n' "$cmd"
    return 0
  fi

  # ── いずれも不可: SKIPPED ──
  return 1
}

# ─── _sav_state_dir ───
#
# round counter を置く永続化先ベースディレクトリを stdout に出す（#246）。
# 旧実装は worktree 配下（`$REPO_DIR/$SPEC_DIR_REL/`）に置いていたが、毎サイクル
# 冒頭の worktree reset（`git reset --hard` + `git clean -fdx`）で untracked/ignored
# が消去されるため counter も消え、連続失敗時に round が毎回 1 にリセットされて
# round=2（escalate）へ到達しない無限 round=1 ループが発生していた（#238/#239/#243）。
#
# これを避けるため、永続化先を **worktree 外**（`$HOME/.issue-watcher/` 配下、LOG_DIR
# と同流儀の `$HOME/.issue-watcher/<種別>/$REPO_SLUG`）へ移す。`$HOME/.issue-watcher/`
# は `$REPO_DIR` の外なので `git clean -fdx` の対象外＝worktree reset で消えない。
# テスト容易性のため新規 optional env var `STAGE_A_VERIFY_STATE_DIR` で base を上書き
# 可能にする（既定付き / 既存 env var 名と非衝突）。
#
# REPO_SLUG が未設定の場合は REPO から防御的に派生し silent fail を避ける（CLAUDE.md 規約）。
#
# 入力: 環境変数 STAGE_A_VERIFY_STATE_DIR（任意） / REPO_SLUG（任意） / REPO（fallback 用）
# stdout: 絶対パス（必ず 1 行 / 末尾スラッシュなし）
_sav_state_dir() {
  local repo_slug="${REPO_SLUG:-}"
  if [ -z "$repo_slug" ]; then
    # REPO_SLUG 未設定時は REPO（owner/name）から派生。REPO も無ければ "_unknown"。
    repo_slug="$(printf '%s' "${REPO:-_unknown}" | tr '/' '-')"
  fi
  printf '%s\n' "${STAGE_A_VERIFY_STATE_DIR:-$HOME/.issue-watcher/state/$repo_slug}"
}

# ─── _sav_round_key ───
#
# round counter を Issue 番号 + branch で一意化するキーを stdout に出す（#246 / Req 3.x）。
# branch にはスラッシュ（`claude/issue-246-impl-...`）が含まれるためファイル名に使えるよう
# 非英数字（`/` 含む）を `-` へサニタイズする。BRANCH 不在時は SLUG、それも無ければ
# SPEC_DIR_REL 由来へ防御的にフォールバックし silent fail を避ける。
#
# 入力: 環境変数 NUMBER / BRANCH（任意） / SLUG（任意） / SPEC_DIR_REL（任意）
# stdout: ファイル名に使えるキー文字列（必ず 1 行）
_sav_round_key() {
  local number="${NUMBER:-0}"
  local ref="${BRANCH:-}"
  if [ -z "$ref" ]; then
    ref="${SLUG:-}"
  fi
  if [ -z "$ref" ]; then
    # SPEC_DIR_REL（docs/specs/<N>-<slug>）の basename から派生。
    ref="$(basename "${SPEC_DIR_REL:-_nobranch}")"
  fi
  # 英数字・ドット・アンダースコア・ハイフン以外を `-` へサニタイズ（`/` 含む）。
  local sanitized
  sanitized="$(printf '%s' "$ref" | tr -c 'A-Za-z0-9._-' '-')"
  printf '%s\n' "${number}-${sanitized}"
}

# ─── stage_a_verify_round_path ───
#
# round counter ファイルの絶対パスを stdout に出す。永続化先は worktree 外の
# state dir（`_sav_state_dir`）配下に Issue 番号 + branch で一意化したキー
# （`_sav_round_key`）で `<key>.stage-a-verify-round` を 1 つ置く（#246）。
# worktree slot / repo 隔離は state dir の REPO_SLUG と key の branch が担保する。
#
# 入力: 環境変数 STAGE_A_VERIFY_STATE_DIR / REPO_SLUG / REPO / NUMBER / BRANCH / SLUG
# stdout: 絶対パス（必ず 1 行）
stage_a_verify_round_path() {
  local base key
  base=$(_sav_state_dir)
  key=$(_sav_round_key)
  printf '%s\n' "$base/$key.stage-a-verify-round"
}

# ─── stage_a_verify_read_round ───
#
# round counter を stdout に整数で出す。ファイル不在は "0"（未失敗）。
# 不正な内容（非数値）は安全側で "0" にフォールバック。
#
# 入力: 環境変数 REPO_DIR / SPEC_DIR_REL
# stdout: 整数 1 行 ("0" / "1" / "2" 等)
# 戻り値: 0（read は失敗しない設計）
stage_a_verify_read_round() {
  local path
  path=$(stage_a_verify_round_path)
  local val=""
  if [ -f "$path" ]; then
    val=$(head -n1 "$path" 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "0"
  fi
}

# ─── stage_a_verify_bump_round ───
#
# round counter を 1 増やして永続化する。不在からの初回呼び出しは "1" を書く。
# 書き込み失敗（disk full / permission denied 等）は sav_error で警告し、
# 呼び出し元（_sav_handle_failure）は read_round の結果が 0 のままになるので
# 差し戻し挙動（round=1）に倒れる安全側設計。
#
# 戻り値: 0 = 書き込み成功 / 1 = 書き込み失敗
stage_a_verify_bump_round() {
  local path cur next
  path=$(stage_a_verify_round_path)
  cur=$(stage_a_verify_read_round)
  next=$((cur + 1))
  # spec dir 自体が存在しない場合は SKIPPED 経路で呼ばれていないはずだが、念のため mkdir -p
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  if ! printf '%d\n' "$next" > "$path" 2>/dev/null; then
    sav_error "round counter 書き込みに失敗 path=$path next=$next"
    return 1
  fi
  return 0
}

# ─── stage_a_verify_reset_round ───
#
# round counter sidecar を削除する。SUCCESS / claude-failed escalate 後に呼ぶ。
# 不在時は no-op（rm -f の挙動に従う）。
stage_a_verify_reset_round() {
  local path
  path=$(stage_a_verify_round_path)
  rm -f "$path" 2>/dev/null || true
}

# ─── _sav_is_path_missing_diff_failure ───
#
# verify コマンドの実行失敗（非 0 exit）が「`diff` のパス不在」に **限定** されるかを判定する
# 純粋関数（#364 Req 2.1 / NFR 2.1）。WARN 降格と real なコード品質失敗を区別するための
# defense-in-depth として、`stage_a_verify_run` の Execute 後ブロックから呼ばれる。
#
# 判定条件（すべて満たすときに 0 = 「パス不在のみ」）:
#   - exit code が 2（GNU diff の "trouble" / errors during processing。content 差分は exit=1）
#   - stderr に `No such file or directory` 文字列を含む（GNU diff のパス不在エラーメッセージ）
#   - stderr に `diff:` 始まりのエラー行を含む（誤判定回避: 別コマンドが偶然 exit=2 + ENOENT を
#     吐いたケースを除外し、`diff` 自身のエラーだけを WARN 対象に絞る）
#
# Req 2.5（連結コマンド中で real fail と path-missing が混在した場合の優先）に従い、本関数は
# 上記 3 条件のいずれかを欠く場合に 1 を返し、real fail として既存 round counter 経路を維持する。
# 具体的には:
#   - exit=1（diff の content 差分）→ 既存挙動（real fail）として round1/round2 へ進む（Req 3.1）
#   - exit=124（timeout）→ 既存挙動（real fail）（Req 2.4）
#   - exit=2 だが `No such file or directory` を含まない（権限エラー等）→ real fail として扱う
#   - exit=2 + `No such file or directory` だが `diff:` 始まり行がない（別コマンドの ENOENT）→ real fail
#
# 入力:
#   $1 = 整数 rc（実行 exit code）
#   $2 = stderr 全文（multi-line 可）
# 戻り値: 0 = 「パス不在のみによる失敗」/ 1 = それ以外（real fail として既存経路を維持）
# 副作用: なし（純粋関数、Req 3.1 / NFR 2.1）
_sav_is_path_missing_diff_failure() {
  local rc="$1"
  local stderr_text="${2:-}"
  # 整数 rc を防御的に検証（非整数なら real fail として扱う）
  case "$rc" in
    2) ;;
    *) return 1 ;;
  esac
  # `No such file or directory` 文字列の存在確認（GNU diff のパス不在エラーメッセージ）
  case "$stderr_text" in
    *"No such file or directory"*) ;;
    *) return 1 ;;
  esac
  # `diff:` で始まる行が含まれることを確認（誤判定回避: diff 自身のエラーに限定）
  if ! printf '%s' "$stderr_text" | grep -q '^diff:'; then
    return 1
  fi
  return 0
}

# ─── _sav_extract_missing_path ───
#
# stderr から `diff:` のパス不在エラーメッセージに含まれるパスを抽出する純粋関数（#364 Req 4.2）。
# GNU diff のエラーフォーマットは `diff: <path>: No such file or directory` 形式。stderr に
# 複数行ある場合は最初に検出した行のパスを返す（NFR 4.2 で 1 行以上の根拠を記録する要件は
# 「最初の検出 1 件」で十分に満たせる）。
#
# パス抽出は sed で `^diff: ` と `: No such file or directory$` を剥がす方式。マッチしない
# 場合は空文字を返す（呼び出し側は空文字も許容するロギングを行う）。
#
# 入力: $1 = stderr 全文
# stdout: 抽出したパス（1 行）。抽出失敗時は空文字
# 副作用: なし（純粋関数）
_sav_extract_missing_path() {
  local stderr_text="${1:-}"
  # grep 無マッチ時は exit=1 となり caller の `set -e` を巻き込む可能性があるため `|| true`
  # で吸収する。pipeline 全体は常に exit=0 で返し、stdout に空文字を出す（仕様: マッチしない
  # 場合は空文字を返す）。
  local matched=""
  matched=$(printf '%s' "$stderr_text" \
    | grep -m1 '^diff:.*: No such file or directory$' \
    || true)
  if [ -z "$matched" ]; then
    return 0
  fi
  printf '%s' "$matched" | sed -e 's|^diff: ||' -e 's|: No such file or directory$||'
}

# ─── _sav_is_tool_missing_failure ───
#
# verify コマンドの実行 exit code が「実行ファイル未検出（command not found / tool-missing）」
# に該当するかを判定する純粋関数（#422 Req 1.1 / NFR 3.1 / NFR 3.2）。WARN 降格と real なコード
# 品質失敗（exit=1 等）を区別するための defense-in-depth として、`stage_a_verify_run` の
# Execute 後ブロックから呼ばれる。
#
# POSIX shell の慣習では「コマンドが見つからない」場合の exit code は **127** に固定されている
# （`sh(1)` の "Exit Status" 規定）。本判定は当該 exit code のみを根拠とし、追加で stderr の
# `command not found` 文字列照合は **必須としない**。理由:
#   - bash -c 連結（`&&` / `||` / `;`）で全体 exit code が 127 となるケースはすべて先頭・途中・
#     末尾いずれかの「未検出コマンド」起因に限られる（exit 1 等の real fail があれば短絡し最終 exit
#     code は real fail のものになり、127 にはならない）。
#   - bash の Builtin `exit 127` で偽装することは理論上可能だが、verify ブロックは tasks.md の
#     構造化フェンスで人間レビューを経て確定する入力であり、意図的な偽装は運用前提に含めない。
#   - `command not found` メッセージは locale（LANG=ja_JP.UTF-8 等）で日本語化される場合があり、
#     文字列照合だけに依存すると環境差の取りこぼしが出る。
#
# Req 2.4（real fail と 127 の混在で最終 exit code が real fail のもの）と Req 2.5（exit=124
# timeout）は呼び出し側 `case "$rc"` の分岐順序で担保される: timeout（124）は本判定より前に
# 専用分岐へ抜け、real fail（127 以外の非 0）は本判定で 1 を返して既存 default 分岐へ戻る。
#
# 入力:
#   $1 = 整数 rc（実行 exit code）
#   $2 = stderr 全文（optional、本判定では使用しないが将来の併用判定に向けて受け入れる）
# 戻り値: 0 = 「tool-missing による失敗」/ 1 = それ以外
# 副作用: なし（純粋関数、NFR 3.1）
_sav_is_tool_missing_failure() {
  local rc="$1"
  # 整数 rc を防御的に検証（非整数なら real fail として扱う / 安全側）
  case "$rc" in
    127) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── _sav_extract_tool_name_from_cmd ───
#
# verify コマンド断片と stderr から、未導入と推定されるツール名を抽出する純粋関数
# （#422 Req 4.3 / NFR 3.1）。WARN ログに「どのツールが未導入か」の手がかりを 1 行で
# 含めて、運用者が cron.log を grep して環境構築判断できるようにする。
#
# 抽出戦略（優先順）:
#   1. stderr に bash の標準的な未検出エラーメッセージ
#      `bash: line N: <tool>: command not found`（locale=C / en の場合）が含まれていれば
#      その `<tool>` を抽出。連結コマンドのどの位置で 127 が出たかを stderr 経由で特定できる。
#   2. 上記マッチがなければコマンド断片の **最初の token**（パイプ / 連結区切り前）を採用。
#      これは「単一コマンドが 127 で落ちた」素直なケースで実用十分。
#   3. いずれでも抽出不能なら空文字を返す（呼び出し側は `(unknown)` 等で記録する）。
#
# 抽出に失敗しても WARN 降格挙動自体は変わらない（Req 4.3 は `Where 情報源がある場合` の
# 条件付き）。
#
# 入力:
#   $1 = cmd      — bash -c に渡された verify コマンド文字列（複数行 / 連結も含む）
#   $2 = stderr_text — 実行時 stderr 全文（optional）
# stdout: 抽出したツール名 1 行 / 抽出不能時は空文字
# 副作用: なし（純粋関数）
_sav_extract_tool_name_from_cmd() {
  local cmd="${1:-}"
  local stderr_text="${2:-}"
  # ── 戦略 1: stderr の `command not found` 行から抽出 ──
  # 例: `bash: line 1: golangci-lint: command not found`
  #     `bash: golangci-lint: command not found`（line N 抜けの bash variant 対策）
  # locale 依存（LANG=ja_JP の `... コマンドが見つかりません` 等）は本戦略では拾えないが、
  # 戦略 2 の cmd 先頭 token に fallback する設計で実用上問題ない。
  local matched=""
  matched=$(printf '%s' "$stderr_text" \
    | grep -m1 -E '^[A-Za-z_0-9./-]+: (line [0-9]+: )?[^:]+: command not found$' \
    || true)
  if [ -n "$matched" ]; then
    # `bash: line N: <tool>: command not found` または `bash: <tool>: command not found` から
    # `<tool>` を抽出。sed で前後を剥がす。
    local tool=""
    tool=$(printf '%s' "$matched" \
      | sed -E 's|^[A-Za-z_0-9./-]+: (line [0-9]+: )?([^:]+): command not found$|\2|')
    if [ -n "$tool" ]; then
      printf '%s\n' "$tool"
      return 0
    fi
  fi

  # ── 戦略 2: cmd 先頭 token を採用 ──
  # 行頭の空白を剥がしてから awk で `&&` / `||` / `;` / `|` の前の最初の token を取る。
  # `cd app && npm test` 等は `cd` が出るが、これは実態と乖離するため bash builtin
  # （cd / export / set 等）は除外して次の token を試す簡易判定を入れる。
  if [ -n "$cmd" ]; then
    local first_token=""
    # 1 行目のみを対象（複数行 cmd の場合の防御）
    first_token=$(printf '%s' "$cmd" \
      | head -n1 \
      | awk '{
          # 連結記号で区切る前の先頭トークンを取得
          n = split($0, parts, /[ \t]+/)
          for (i = 1; i <= n; i++) {
            tok = parts[i]
            if (tok == "") continue
            # bash builtin / 既知の prefix は skip して次を採用
            if (tok == "cd" || tok == "export" || tok == "set" || tok == "unset" \
                || tok == "if" || tok == "then" || tok == "while" || tok == "for") {
              continue
            }
            print tok
            exit
          }
        }')
    if [ -n "$first_token" ]; then
      printf '%s\n' "$first_token"
      return 0
    fi
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 以下は元 issue-watcher.sh では Region 2（mark_issue_failed 定義後の位置）に
# 置かれていた失敗ハンドラ / 統合ランナー。#181 Part 3 で Region 1 と 1 モジュールへ
# 統合した（source-before-execution により定義順序はランタイム挙動へ影響しない）。
# ─────────────────────────────────────────────────────────────────────────────

# ─── _sav_handle_failure ───
#
# stage_a_verify_run の失敗パス共通処理。round counter を bump し、
# round=1 なら Developer 差し戻し（Issue コメント投稿 + return 1）、
# round=2 以降なら mark_issue_failed 経由で claude-failed 化（return 2）。
# `needs-iteration` ラベルは Issue 側には付与しない既存契約（NFR 1.2）を維持。
#
# 入力:
#   $1 = kind ("timeout" | "exit")
#   $2 = detail (timeout 秒 | exit code)
# 戻り値:
#   1 = Developer 差し戻し（次 tick で stage-a-verify 再評価）
#   2 = claude-failed 付与済み（watcher 退出）
_sav_handle_failure() {
  local kind="$1"
  local detail="$2"
  stage_a_verify_bump_round || sav_error "round counter 書き込みに失敗（差し戻し挙動を強制）"
  local round
  round=$(stage_a_verify_read_round)
  case "$round" in
    1)
      sav_log "round=1 outcome=needs-iteration (Developer 差し戻し)"
      # round=1 差し戻しコメント。`needs-iteration` ラベルは PR 専用契約であり
      # Issue 側には付与しない（NFR 1.2 / 既存 L2860 / L5989 契約）。次 tick で
      # Stage Checkpoint が START_STAGE=B を返しても、Stage B 開始前の
      # stage-a-verify ゲートで再評価される（design.md「stage-a-verify と
      # Stage Checkpoint の協調」参照）。
      local comment_body
      comment_body="🔁 stage-a-verify が失敗しました（round=1 / ${kind}=${detail}）。

\`tasks.md\` 末尾の verify タスク（build/test/lint）を watcher が REPO_DIR で独立再実行したところ、exit code が 0 以外でした。

- 検出されたコマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- 次サイクルで Developer が再実装し、Stage B 開始前に stage-a-verify が再評価されます
- 修正後に \`./gradlew\` / \`npm test\` 等のローカル成功を確認してから commit/push してください

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      gh issue comment "$NUMBER" --repo "$REPO" --body "$comment_body" >/dev/null 2>&1 || \
        sav_warn "gh issue comment 投稿に失敗（差し戻し挙動は継続）"
      return 1
      ;;
    *)
      sav_log "round=$round outcome=claude-failed (escalate to human)"
      stage_a_verify_reset_round
      local extra_body
      extra_body="stage-a-verify（\`tasks.md\` 末尾 verify タスクの独立再実行）が連続 ${round} 回失敗しました（${kind}=${detail}）。

- 検出コマンドの実行結果はログ \`${LOG:-(unknown)}\` を参照
- \`tasks.md\` 末尾の build/test/lint コマンドをローカルで通してから \`claude-failed\` を外してください
- 一時的に gate を skip したい場合は cron / launchd 側で \`STAGE_A_VERIFY_ENABLED=false\` を渡してください（Req 4.1 / NFR 1.1）

本機能の詳細: README「Stage A Verify Gate (#125)」節 / Issue #125"
      mark_issue_failed "stageA-verify" "$extra_body"
      return 2
      ;;
  esac
}

# ─── _SAV_LAST_EXEC_ELAPSED / _SAV_LAST_EXEC_RC（_sav_exec_with_timeout 結果露出 / #377） ───
#
# 直近の `_sav_exec_with_timeout` 呼び出しの経過秒数と exit code を露出する
# モジュールスコープ変数。command substitution 経由ではなく call site が同一プロセスで
# 呼ぶため、ここに代入した値は呼び出し側から読める。
# _SAV_LAST_EXEC_RC は本ヘルパーの戻り値と同値（caller 側は `|| rc=$?` で受け取るのが標準）。
_SAV_LAST_EXEC_ELAPSED=0
_SAV_LAST_EXEC_RC=0

# ─── _sav_exec_with_timeout ───
#
# verify コマンドを wall-clock 制限付きで実行し、孫プロセスを含めて確実に終了させる
# ヘルパー（#377 Req 2.1〜2.5 / Req 3.1〜3.4）。テスト容易性のため `stage_a_verify_run`
# から切り出した独立関数として配置する。
#
# 設計上の二段防御:
#   1. `setsid` で verify cmd を新規 session（pgid leader）として起動する。これにより
#      cmd の子孫プロセス全体が単一の pgid に属し、後段の `kill -- -<pgid>` で一括終了
#      可能な状態を確立する（util-linux 標準 / macOS は brew 経由で提供、CLAUDE.md 既載）。
#   2. `timeout --kill-after=<grace> --signal=TERM` を維持し、wall-clock 上限到達時に
#      まず SIGTERM、grace 秒経過後に SIGKILL を送出する（既存契約 rc=124 / Req 2.3, 2.4）。
#   3. 復帰後（rc=124 時）に `kill -KILL -- -<pgid>` を best-effort で broadcast し、
#      timeout 経路で取り残された孫プロセスを確実に掃除する（Req 2.5）。setsid 由来の
#      pgid は子 bash のものではなく setsid セッション全体のリーダ pid と一致するため、
#      `kill -- -$child_pid` で session 配下を一括 kill できる。
#
# 出力経路（#377 Req 3.1〜3.4）:
#   - stdout / stderr とも process substitution を使わず、直接ファイルへリダイレクトする
#     ことで pipe 満杯による write block を物理的に排除する。
#   - 一時ファイル経路は caller（stage_a_verify_run）が mktemp で作成して渡す。本関数
#     自身は path を受け取るのみで、削除責務は caller 側にある。
#
# 入力:
#   $1 = cmd       — bash -c に渡す verify コマンド文字列
#   $2 = timeout   — wall-clock 上限秒数（整数。timeout コマンドの解釈に従う）
#   $3 = kill_after — grace 秒数（整数。SIGTERM 後の SIGKILL までの猶予）
#   $4 = stdout_path — stdout の書き出し先（"/dev/null" 許容）
#   $5 = stderr_path — stderr の書き出し先（"/dev/null" 許容）
# 戻り値: verify cmd の exit code（タイムアウト時は 124 / GNU timeout 規約）
# 副作用:
#   - _SAV_LAST_EXEC_RC / _SAV_LAST_EXEC_ELAPSED を更新（観測性 / Req 4.1）
#   - $REPO_DIR への cd（subshell 内で完結。caller 環境への副作用なし）
#   - rc=124 時に pgid 配下の残存プロセスへ SIGKILL を broadcast
_sav_exec_with_timeout() {
  local _cmd="$1"
  local _timeout="$2"
  local _kill_after="$3"
  local _stdout_path="$4"
  local _stderr_path="$5"
  local _rc=0
  local _start _end

  # 経過秒計測（date +%s ベース。$SECONDS は subshell 越えで巻き戻る場合があるため避ける）。
  _start=$(date +%s 2>/dev/null || echo 0)

  # setsid + timeout + bash -c で verify cmd を新規 session で起動する。
  # 起動形式について:
  #   - `setsid timeout ... bash -c "$_cmd"` を直接 background 起動して pid を取得する。
  #     setsid は新規 session を確立し、当該プロセスツリーは独立した process group を持つ。
  #     timeout は SIGTERM を bash に送るが、setsid 配下なので pgid 全体への broadcast は
  #     後段の `kill -- -<pgid>` で別途実施する（timeout の SIGTERM 単体では孫に届かない
  #     ことがあるため）。
  #   - 出力は process substitution ではなく直接 redirect で受ける（pipe deadlock 回避 /
  #     Req 3.1, 3.2）。
  setsid timeout --kill-after="${_kill_after}" --signal=TERM "${_timeout}" \
      bash -c "cd \"$REPO_DIR\" && $_cmd" \
      >"$_stdout_path" 2>"$_stderr_path" &
  local _child_pid=$!

  # 子プロセスの終了を待機。`wait` は signal 受信時に 128+signo を返す可能性があるが、
  # ここでは timeout 配下なので child pid が exit して通常 rc を返す前提（_rc は 0 / 非 0 /
  # 124 / 137 等）。
  wait "$_child_pid" 2>/dev/null || _rc=$?

  _end=$(date +%s 2>/dev/null || echo 0)
  _SAV_LAST_EXEC_ELAPSED=$(( _end - _start ))
  if [ "$_SAV_LAST_EXEC_ELAPSED" -lt 0 ]; then
    # 時計巻き戻り等の異常系では 0 にフォールバック（観測性ログの sanity）。
    _SAV_LAST_EXEC_ELAPSED=0
  fi

  # #377 Req 2.4, 2.5: timeout 強制終了経路（rc=124 / SIGKILL は 137）で、setsid セッション
  # 配下に孫プロセスが残っていれば pgid 全体に SIGKILL を broadcast する。kill 対象の
  # pgid は child の pid と一致する（setsid 直後の child が pgid leader になる規約）。
  # best-effort（既に exit 済みなら ESRCH で no-op）。silent fail を許容する（既に全プロセスが
  # 終了済みのケースが正常 / Req 2.5）。
  if [ "$_rc" -eq 124 ] || [ "$_rc" -eq 137 ]; then
    kill -KILL -- "-${_child_pid}" 2>/dev/null || true
  fi

  _SAV_LAST_EXEC_RC="$_rc"
  return "$_rc"
}

# ─── stage_a_verify_run ───
#
# Stage A Verify Module の統合ランナー。`run_impl_pipeline` の Stage A 成功直後・
# Stage B 開始直前から 1 度だけ呼ばれる。
#
# 入力 (環境変数経由):
#   REPO / REPO_DIR / SPEC_DIR_REL / NUMBER / LOG
#   STAGE_A_VERIFY_ENABLED / STAGE_A_VERIFY_TIMEOUT / STAGE_A_VERIFY_COMMAND
# 戻り値:
#   0 = SUCCESS / SKIPPED / DISABLED → Stage A 完全完了として続行
#   1 = FAILED (round=1) → 差し戻し済、次 tick で再試行
#   2 = FAILED (round=2 以降) → mark_issue_failed 済（claude-failed 付与）、watcher 退出
# 副作用:
#   - cron.log / $LOG に 1 行以上の `[$REPO] stage-a-verify:` ログ（NFR 4.1）
#   - round counter sidecar の read/bump/reset
#   - 失敗時に gh issue comment（round=1 差し戻し / round=2 は mark_issue_failed が発火）
#
# 不変条件:
#   - 1 回の呼び出しで `stage-a-verify:` 行を必ず 1 行以上出力（NFR 4.1）
#   - 抽出した cmd は `bash -c` に **そのまま**渡し、watcher 側で `&&` / `||` / `;` を
#     解釈しない（Req 1.3）
stage_a_verify_run() {
  # run サマリ用 outcome（#239 task 5）。各 return 直前で確定する。
  _SAV_LAST_OUTCOME=""
  # ── Gate 1: DISABLED ──
  # `STAGE_A_VERIFY_ENABLED=false` 明示時のみ skip（`=false` 厳密一致、Req 4.1 /
  # NFR 1.1）。`:-true` で `unset` も既定有効として扱う。
  if [ "${STAGE_A_VERIFY_ENABLED:-true}" = "false" ]; then
    sav_log "DISABLED reason=env-opt-out"
    _SAV_LAST_OUTCOME="disabled"
    return 0
  fi

  # ── Gate 2: SKIPPED（解決できない / 一致なし）──
  # design-less impl（tasks.md 不在）は resolve の全段が解決失敗となりここで SKIPPED に倒れる。
  # これは意図された仕様であり（#230）、round counter を増やさず Stage A を続行する。
  local cmd
  if ! cmd=$(stage_a_verify_resolve_command); then
    sav_log "SKIPPED reason=no-verify-task-in-tasks-md"
    _SAV_LAST_OUTCOME="skip"
    return 0
  fi
  # resolve は command substitution のサブシェルで実行されるため、サブシェル内で代入した
  # `_SAV_RESOLVED_SOURCE` は親（run）へ伝播しない。resolve が併せて書き出した source sidecar
  # を読み戻して Gate 3 判定に使う（サブシェル越えの source 共有、design.md Decision 採用案）。
  local resolved_source
  resolved_source=$(_sav_read_resolved_source)

  # ── Gate 3: SKIPPED（抽出した cmd が keyword で開始しない）──
  # heuristic 経路の `stage_a_verify_extract_command` 側で行頭一致を保証しているが、
  # defense-in-depth として実行直前にも確認する（#160 Req 5.3）。bypass 条件:
  #   - `STAGE_A_VERIFY_COMMAND` env が非空（運用者が明示指定した escape hatch 経路、Req 4.1）
  #   - 構造化ブロック由来（source=structured-block）。Architect が設計 PR で人間レビュー済みの
  #     input 契約であり、env 経路と同じ信頼境界として Gate 3 を免除する（#224 Req 3.1 /
  #     design.md「Decision: source の stage_a_verify_run への伝達方法」採用案）
  if [ -z "${STAGE_A_VERIFY_COMMAND:-}" ] && [ "$resolved_source" != "structured-block" ]; then
    if ! _sav_cmd_starts_with_keyword "$cmd"; then
      sav_log "SKIPPED reason=cmd-does-not-start-with-keyword cmd=$(printf '%q' "$cmd")"
      _SAV_LAST_OUTCOME="skip"
      return 0
    fi
  fi

  # ── Execute ──
  local _timeout="${STAGE_A_VERIFY_TIMEOUT:-600}"
  # #377: timeout 強制終了時の grace 値を env 化（既定 10 = 現行ハードコードと同値）。
  # 既定値で従来挙動を再現するため未設定時は完全に後方互換（Req 5.1, 5.2）。
  local _kill_after="${STAGE_A_VERIFY_KILL_AFTER:-10}"
  # cmd の shell エスケープは printf %q で安全側に倒し、ログ復元性を確保する。
  sav_log "EXEC issue=#${NUMBER:-?} timeout=${_timeout}s kill_after=${_kill_after}s cmd=$(printf '%q' "$cmd")"

  # #364 / #377: 出力を一時ファイル経由で捕捉する。
  #   - #364: stderr を別捕捉してパス不在 WARN 降格判定の入力にする。
  #   - #377: process substitution（`> >(tee ...)` / `2> >(tee ...)`）を完全に廃止し、
  #     stdout/stderr ともに直接 mktemp ファイルへリダイレクトする。process substitution は
  #     verify cmd の孫プロセスが pipe write-end を握り続けると read 側 subshell が EOF
  #     を受け取れず永久 wait する deadlock 経路を持っていた（#374 で 1h21m hang を観測）。
  #     一時ファイル方式なら write block が起きず、timeout signal の伝播が阻害されない
  #     （Req 3.1, 3.2）。verify 完了後に両 tempfile を $LOG へ append することで既存 grep
  #     経路（`grep '\[.*\] stage-a-verify:'` / FAILED / TIMEOUT 行抽出）を温存する（Req 3.3）。
  # 一時ファイルは mktemp で作り、ENV による予測攻撃を防ぐ（CLAUDE.md §5/§6 / NFR 4.2）。
  local _stdout_path _stderr_path
  _stdout_path=$(mktemp 2>/dev/null) || _stdout_path=""
  _stderr_path=$(mktemp 2>/dev/null) || _stderr_path=""

  local rc=0
  local _elapsed=0
  if [ -z "$_stdout_path" ] || [ -z "$_stderr_path" ]; then
    # mktemp 失敗時は WARN 降格判定（stderr 解析）を skip して従来挙動に倒す（fail-open）。
    # process substitution は使わず、ここでも redirect 経路で deadlock を回避する。
    sav_warn "mktemp に失敗したため stderr 捕捉せずに従来経路で実行"
    # 残ったほうの tempfile があれば掃除
    if [ -n "$_stdout_path" ]; then rm -f "$_stdout_path" 2>/dev/null || true; fi
    if [ -n "$_stderr_path" ]; then rm -f "$_stderr_path" 2>/dev/null || true; fi
    _stdout_path=""
    _stderr_path=""
    _sav_exec_with_timeout "$cmd" "$_timeout" "$_kill_after" "/dev/null" "/dev/null" || rc=$?
    _elapsed="${_SAV_LAST_EXEC_ELAPSED:-0}"
  else
    _sav_exec_with_timeout "$cmd" "$_timeout" "$_kill_after" "$_stdout_path" "$_stderr_path" || rc=$?
    _elapsed="${_SAV_LAST_EXEC_ELAPSED:-0}"
    # 既存 grep 経路維持のため stdout/stderr を $LOG へ append する（Req 3.3）。
    # 一時ファイル不在は theoretical だが防御的に check。
    if [ -f "$_stdout_path" ]; then
      cat "$_stdout_path" >> "$LOG" 2>/dev/null || true
    fi
    if [ -f "$_stderr_path" ]; then
      cat "$_stderr_path" >> "$LOG" 2>/dev/null || true
    fi
  fi

  local _stderr_text=""
  if [ -n "$_stderr_path" ] && [ -f "$_stderr_path" ]; then
    _stderr_text=$(cat "$_stderr_path" 2>/dev/null || true)
  fi
  # tempfile を確実に掃除（trap ではなく明示削除 / mktemp で予測不能名なので残置リスク低）。
  if [ -n "$_stdout_path" ]; then rm -f "$_stdout_path" 2>/dev/null || true; fi
  if [ -n "$_stderr_path" ]; then rm -f "$_stderr_path" 2>/dev/null || true; fi

  # ── 結果分岐 ──
  case "$rc" in
    0)
      sav_log "SUCCESS exit=0 elapsed=${_elapsed}s"
      stage_a_verify_reset_round
      _SAV_LAST_OUTCOME="success"
      return 0
      ;;
    124)
      # #377 Req 4.1, 4.2: 診断ログに elapsed と kill_after を追加し、事後解析で
      # 「設定 timeout に対して実際に何秒で kill されたか」を即座に特定できるようにする。
      sav_warn "TIMEOUT timeout=${_timeout}s kill_after=${_kill_after}s elapsed=${_elapsed}s exit=124 cmd=$(printf '%q' "$cmd")"
      local _hf_rc=0
      _sav_handle_failure "timeout" "$_timeout" || _hf_rc=$?
      # _sav_handle_failure 戻り値（1=round1 差し戻し / 2=round2 escalate）を run サマリ
      # outcome へマップ（Req 4.3）。戻り値はそのまま伝搬し既存契約を変えない（NFR 1.2）。
      case "$_hf_rc" in
        1) _SAV_LAST_OUTCOME="round1" ;;
        2) _SAV_LAST_OUTCOME="round2" ;;
      esac
      return "$_hf_rc"
      ;;
    127)
      # #422: exit 127 は POSIX 規約で「実行ファイル未検出（command not found）」を意味する。
      # watcher ホストに lint / build ツール（例: golangci-lint, node, go, gradle）が未インストール
      # という環境要因に過ぎず、コード自体は verify-clean であるため、real verify 失敗（exit=1 等）
      # と同列に round1 / round2 / `claude-failed` まで自動昇格させない（Req 1.1〜1.4）。
      # path-missing #364 と同様の WARN 降格として扱い、round counter は触らず Stage A を続行する
      # （戻り値 0 / 既存 SUCCESS / warn-skipped と同じ「Stage A 完全完了」契約）。
      # 連結コマンド（`&&` / `||` / `;`）で全体 exit code が 127 となるケースもすべてここで処理
      # する。real fail と 127 が混在し最終 exit code が real fail のもの（例: 1）となる場合は
      # 本分岐に到達せず default `*` 分岐の既存 real fail 経路へ落ちる（Req 2.4）。
      if _sav_is_tool_missing_failure "$rc"; then
        local _tool_name
        _tool_name=$(_sav_extract_tool_name_from_cmd "$cmd" "$_stderr_text")
        # WARN ログには (1) 識別固定 prefix（grep '\[.*\] stage-a-verify: WARN' で抽出可能 /
        # Req 4.1）、(2) reason=verify-tool-missing（path-missing と区別 / Req 4.2）、
        # (3) 推定ツール名（情報源があれば / Req 4.3）、(4) exit=127 と cmd 断片（Req 4.5）の
        # 4 要素を 1 行で記録する（NFR 4.2）。複数行に分けると grep 抽出時の脱漏や
        # ペアリングミスを誘発するため 1 行にまとめる。
        sav_warn "reason=verify-tool-missing tool=$(printf '%q' "${_tool_name:-(unknown)}") exit=$rc cmd=$(printf '%q' "$cmd")"
        # round counter は触らない（Req 1.1）。Stage A は続行する（戻り値 0 / Req 1.2）。
        # gh issue comment による差し戻しも行わない（Req 1.3）。
        _SAV_LAST_OUTCOME="warn-tool-missing"
        return 0
      fi
      # 防御的: _sav_is_tool_missing_failure が 0 を返さないケース（rc=127 だが将来の判定強化で
      # 偽装等を除外したケース）は real fail 経路へ落とす。現実装では到達しない。
      sav_warn "FAILED exit=$rc"
      local _hf_rc=0
      _sav_handle_failure "exit" "$rc" || _hf_rc=$?
      case "$_hf_rc" in
        1) _SAV_LAST_OUTCOME="round1" ;;
        2) _SAV_LAST_OUTCOME="round2" ;;
      esac
      return "$_hf_rc"
      ;;
    *)
      # #364: パス不在に起因する diff 失敗（exit=2 + `No such file or directory`）は
      # 「コード品質失敗」と区別して WARN 降格する。real なテスト/lint/shellcheck 失敗
      # （exit=1 等）/ diff content 差分（exit=1）/ timeout（exit=124、上記分岐）は従来どおり
      # round counter 経路で処理する（Req 2.4 / 3.1 / 3.2 / NFR 1.1）。
      # 連結コマンド中に real fail と path-missing が混在した場合、bash -c は連結全体の
      # 最終 exit code を返すため、real fail がいずれかのステップで起きていればここに
      # 到達する rc は real fail のものになる（Req 2.5）。
      if _sav_is_path_missing_diff_failure "$rc" "$_stderr_text"; then
        local _missing_path
        _missing_path=$(_sav_extract_missing_path "$_stderr_text")
        # WARN ログには (1) 識別固定 prefix（grep '\[.*\] stage-a-verify: WARN' で抽出可能 /
        # Req 4.3）、(2) reason=verify-path-missing、(3) 検出パス、(4) 実行 cmd 断片の 4 要素を
        # 1 行で記録する（Req 4.1 / 4.2 / NFR 4.2）。複数行に分けると grep 抽出時の脱漏や
        # ペアリングミスを誘発するため 1 行にまとめる。
        sav_warn "reason=verify-path-missing path=$(printf '%q' "${_missing_path:-(unknown)}") exit=$rc cmd=$(printf '%q' "$cmd")"
        # round counter は触らない（Req 2.2）。Stage A は続行する（戻り値 0 / 既存契約と整合）。
        _SAV_LAST_OUTCOME="warn-skipped"
        return 0
      fi
      sav_warn "FAILED exit=$rc"
      local _hf_rc=0
      _sav_handle_failure "exit" "$rc" || _hf_rc=$?
      case "$_hf_rc" in
        1) _SAV_LAST_OUTCOME="round1" ;;
        2) _SAV_LAST_OUTCOME="round2" ;;
      esac
      return "$_hf_rc"
      ;;
  esac
}
