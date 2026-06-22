#!/usr/bin/env bash
# dep-cycle-detect.sh — watcher の Dependency Cycle Detection モジュール（Issue #368 / D-16）
#
# 用途:
#   `auto-dev` + `blocked` + OPEN な Issue 集合の依存エッジ（`Depends on:` /
#   `前提依存:` / `Blocked by:`）から有向グラフを構築し、閉路（自己ループ + 任意長 N の閉路）
#   を検出して、閉路メンバー Issue に `needs-decisions` ラベル + 説明コメントを冪等に
#   付与する。検出された閉路メンバーは #346 Dependency Auto-Unblock Sweep の
#   `blocked` 自動解除対象から除外され、人間判断にエスカレートされる。
#
#   - dc_gate_enabled          : 起動 gate 評価（既存 `DEP_AUTO_UNBLOCK_ENABLED` 配下に同居）
#   - dc_normalize_targets     : 対象 Issue 番号集合の正規化（CSV / 改行混在を空白区切りへ）
#   - dc_extract_edges         : 単一 Issue 本文 → 当該 Issue 起点の有向エッジ列を抽出
#   - dc_build_graph_lines     : JSON 配列（[{number, body}]）→ "src dst" 改行区切りエッジ列
#   - dc_find_cycles           : エッジ列 → 閉路ごとに 1 行（空白区切り、ソート + uniq 済み）
#   - dc_has_cycle_marker      : 既存コメントに本機能由来マーカーがあるか（冪等性判定）
#   - dc_format_cycle_comment  : 閉路メンバーから説明コメント本文を生成（純粋関数）
#   - dc_escalate_member       : 単一 Issue に対する needs-decisions 付与 + コメント投稿
#   - dc_cycle_sweep           : エントリポイント。閉路検出 + エスカレーション + cycle-member
#                                set（_DC_CYCLE_MEMBERS）の export
#
# 配置先:
#   $HOME/bin/modules/dep-cycle-detect.sh（install.sh が local-watcher/bin/modules/ から配置する）
#
# 依存:
#   - 本モジュールは issue-watcher.sh 本体から `source` される前提（単体起動しない）。
#   - `set -euo pipefail` は本体側で宣言済みのため、本モジュールでは宣言せず関数定義のみを持つ。
#   - ロガーは本体側の `dr_log` / `dr_warn` を再利用する（Req 6.1〜6.5 / 既存 dr_* と同形式）。
#   - 既存 `dr_extract_deps` / `dr_unblock_gate_enabled` / `full_auto_enabled` を遅延束縛で参照。
#   - 外部 CLI: gh / jq / grep / awk / sort。
#   - 関数 prefix `dc_` を namespace として採用する（新規未使用 prefix / CLAUDE.md §2）。
#
# セットアップ参照先:
#   README.md（オプション機能一覧・ラベル状態遷移まとめ）/ install.sh（modules 配置ロジック）
#   設計参照: docs/specs/368-feat-watcher-cycle-needs-decisions-d-16/requirements.md

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Constants
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 説明コメントに埋め込む監査識別子（NFR 4.2 / Req 4.3）。
# `<!-- ... -->` は GitHub UI 上は不可視。grep / jq から検出可能。冪等性判定に使う（Req 5.2）。
# shellcheck disable=SC2034  # 抽出した個別関数の遅延束縛 / 既存 dr_* と同パターン
DC_CYCLE_MARKER='<!-- idd-claude:dep-cycle-detected:v1 -->'

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 引数: なし
# 戻り値: 0 = gate ON / 1 = gate OFF（既定 / 不正値 / typo）
# 副作用: なし（純粋関数）
#
# 本機能は #346 Dependency Auto-Unblock Sweep と協調動作する前処理であり、独立 env var を
# 追加せず既存 `DEP_AUTO_UNBLOCK_ENABLED` 配下に同居する（Req 1.1〜1.3 / CLAUDE.md §3 後方互換）。
# 値正規化に失敗した状態（未設定 / 空 / `False` / `True` / `1` / `on` / typo）は
# すべて OFF として扱う（NFR 1.1 安全側）。
#
# 既存 `dr_unblock_gate_enabled` を呼ぶことで gate 判定ロジックの単一情報源を維持する
# （CLAUDE.md §4「rule↔harness の canonical 相互参照」）。
dc_gate_enabled() {
  dr_unblock_gate_enabled
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Pure Graph Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 引数 $1 = 対象 Issue 番号集合（任意区切り: 空白 / カンマ / 改行）
# stdout = 空白区切りの正規化された対象 Issue 番号集合（重複排除 + 数値昇順）
# 副作用なし（純粋関数）
#
# `dc_build_graph_lines` / `dc_extract_edges` で「エッジ先が対象集合に含まれるか」を判定する
# ために、CSV / 改行混在 / 重複あり入力を正規化する（Req 2.2 / NFR 5.1）。
# 数値以外の入力は安全側で除外する（CLAUDE.md §5 / 数値 ID `^[0-9]+$` 検証）。
dc_normalize_targets() {
  local raw="$1"
  # 空入力では grep が rc=1 を返して set -e 下のパイプライン全体が失敗するため、
  # 早期 return する（NFR 3.1 安全側）。
  if [ -z "$raw" ]; then
    return 0
  fi
  printf '%s\n' "$raw" \
    | tr ',\t ' '\n' \
    | grep -E '^[0-9]+$' \
    | sort -u -n \
    | tr '\n' ' ' \
    | sed -E 's/ +$//'
}

# 引数:
#   $1 = src Issue 番号（数字のみ / 数値検証は呼び出し側で済ませる）
#   $2 = src Issue 本文（多行 string）
#   $3 = 対象 Issue 番号集合（dc_normalize_targets 出力 = 空白区切り）
# stdout = "<src> <dst>" 形式のエッジを 1 行 1 件で改行区切り出力。空入力では空。
# 副作用なし（純粋関数）
#
# `dr_extract_deps` で抽出した依存先 Issue 番号のうち、対象集合（auto-dev+blocked+OPEN）に
# 含まれるものだけをエッジとして残す（Req 2.2: 対象外 Issue がエッジ先のエッジは閉路判定から除外）。
# 自己ループ（src == dst）はそのまま残す（Req 3.1）。
dc_extract_edges() {
  local src="$1"
  local body="$2"
  local targets="$3"

  # `dr_extract_deps` は純粋関数（gh 呼ばず）。issue-watcher.sh 本体側で定義済みであり
  # 遅延束縛で参照される（NFR 1.2 / 既存 dr_* 流用）。
  local deps
  deps=$(dr_extract_deps "$body" 2>/dev/null || true)
  [ -z "$deps" ] && return 0

  # 対象集合を grep -F 用に改行区切りへ正規化
  local targets_lines
  targets_lines=$(printf '%s\n' "$targets" | tr ' ' '\n' | grep -E '^[0-9]+$' || true)
  [ -z "$targets_lines" ] && return 0

  # deps のうち targets_lines に含まれるものだけを残す（"-w" で完全一致、数値混入防止のため
  # `-F` でリテラル比較）
  local dst
  while IFS= read -r dst; do
    [ -z "$dst" ] && continue
    if printf '%s\n' "$targets_lines" | grep -qxF -- "$dst"; then
      printf '%s %s\n' "$src" "$dst"
    fi
  done <<<"$deps"
}

# 引数 $1 = JSON 配列（gh issue list --json number,body の出力相当 / `[{number,body}, ...]`）
# stdout = "<src> <dst>" 形式エッジ列（改行区切り、ソート + uniq 済み）
# 副作用なし（純粋関数 / jq に未信頼入力を渡す際は --argjson で構造化）
#
# 入力 JSON から (1) 対象 Issue 番号集合を抽出 → (2) 各 Issue 本文から依存エッジを抽出する。
# 入力が空配列 / 不正 JSON の場合は空 stdout で 0 終了（NFR 3.1 安全側）。
dc_build_graph_lines() {
  local issues_json="$1"

  # 対象 Issue 番号集合（jq で number 抽出 → 正規化）
  local nums
  if ! nums=$(printf '%s' "$issues_json" \
        | jq -r '.[]?.number | tostring' 2>/dev/null); then
    return 0
  fi
  [ -z "$nums" ] && return 0

  local targets
  targets=$(dc_normalize_targets "$nums")
  [ -z "$targets" ] && return 0

  # 各 Issue について本文を取り出してエッジ抽出。
  local count i src body
  count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  [ -z "$count" ] && return 0
  [ "$count" = "0" ] && return 0

  for ((i=0; i<count; i++)); do
    src=$(printf '%s' "$issues_json" | jq -r ".[$i].number" 2>/dev/null)
    [ -z "$src" ] || ! [[ "$src" =~ ^[0-9]+$ ]] && continue
    body=$(printf '%s' "$issues_json" | jq -r ".[$i].body // \"\"" 2>/dev/null)
    dc_extract_edges "$src" "$body" "$targets"
  done | sort -u
}

# 引数 $1 = "<src> <dst>" 形式エッジ列（改行区切り）
# stdout = 検出した閉路を 1 行 1 件で出力。各行は閉路メンバー Issue 番号を空白区切り
#         （数値昇順 + uniq 済み）。
# 副作用なし（純粋関数）
#
# Tarjan の強連結成分（SCC）分解により閉路を検出する。SCC のうち以下に該当する成分が「閉路」:
#   - サイズ >= 2 の SCC（多ノード閉路 / Req 3.2, 3.3）
#   - サイズ 1 の SCC でかつ自己ループを持つもの（A→A / Req 3.1）
#
# Tarjan は O(V+E)（NFR 2.3）。SCC 出力をメンバー昇順にソート + 全閉路を SCC root の最小値
# でソート（Req 3.3, NFR 4.1 出力決定性）。
#
# 純粋関数として実装し、グラフは awk のローカル連想配列で完結させる（NFR 5.1 セキュリティ /
# bash 連想配列の global 汚染回避）。
dc_find_cycles() {
  local edges="$1"
  [ -z "$edges" ] && return 0

  # awk で Tarjan SCC を実装。再帰は awk の関数ローカルスコープで完結する。
  # 自己ループは別 set として明示記録し、SCC サイズ 1 の判定で利用する。
  printf '%s\n' "$edges" | awk '
    BEGIN { idx_counter = 0; sp = 0 }

    # エッジ読み込み: src dst（数値）
    NF == 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
      src = $1; dst = $2
      # 隣接リストを文字列連結で持つ（key=src, value="dst1 dst2 ..."）
      if (src in adj) { adj[src] = adj[src] " " dst } else { adj[src] = dst }
      # ノード登録（dst もノード）
      if (!(src in nodes)) { nodes[src] = 1; node_list[++node_count] = src }
      if (!(dst in nodes)) { nodes[dst] = 1; node_list[++node_count] = dst }
      # 自己ループフラグ（SCC サイズ 1 の閉路判定に使用 / Req 3.1）
      if (src == dst) { self_loop[src] = 1 }
    }

    END {
      # Tarjan: iterative 実装で深い再帰を避ける（NFR 2.3 / awk 再帰制限の回避）
      for (i = 1; i <= node_count; i++) {
        v = node_list[i]
        if (!(v in idx)) {
          tarjan_iterative(v)
        }
      }

      # SCC を root ノード（SCC 内最小番号）でソートして出力
      # scc_groups[root] = "n1 n2 ..."
      n_groups = 0
      for (root in scc_groups) { groups_keys[++n_groups] = root }
      # 数値昇順ソート（awk の sort/asort は POSIX 範囲外なので手書きの単純ソート）
      for (a = 1; a <= n_groups; a++) {
        for (b = a + 1; b <= n_groups; b++) {
          if (groups_keys[a] + 0 > groups_keys[b] + 0) {
            tmp = groups_keys[a]; groups_keys[a] = groups_keys[b]; groups_keys[b] = tmp
          }
        }
      }
      for (g = 1; g <= n_groups; g++) {
        root = groups_keys[g]
        members = scc_groups[root]
        # members を数値昇順 + uniq でソート（Req 3.3 / NFR 4.1 出力決定性）
        m_count = split(members, m_arr, " ")
        # 単純ソート
        for (a = 1; a <= m_count; a++) {
          for (b = a + 1; b <= m_count; b++) {
            if (m_arr[a] + 0 > m_arr[b] + 0) {
              tmp = m_arr[a]; m_arr[a] = m_arr[b]; m_arr[b] = tmp
            }
          }
        }
        # uniq
        out = ""; prev = ""
        for (a = 1; a <= m_count; a++) {
          if (m_arr[a] != prev) {
            out = (out == "") ? m_arr[a] : out " " m_arr[a]
            prev = m_arr[a]
          }
        }
        # サイズ 1 で自己ループのみ閉路として採用、サイズ >= 2 は無条件で閉路
        size = split(out, dummy, " ")
        if (size >= 2) {
          print out
        } else if (size == 1 && (out in self_loop)) {
          print out
        }
      }
    }

    # iterative Tarjan
    function tarjan_iterative(start,    stack_v, stack_i, sp2, top, v, next_i, adj_list, neigh_count, neigh, j, w) {
      sp2 = 0
      stack_v[++sp2] = start
      stack_i[sp2] = 0
      idx[start] = idx_counter
      low[start] = idx_counter
      idx_counter++
      on_stack[start] = 1
      ts[++sp] = start

      while (sp2 > 0) {
        v = stack_v[sp2]
        next_i = stack_i[sp2]

        adj_list = (v in adj) ? adj[v] : ""
        neigh_count = (adj_list == "") ? 0 : split(adj_list, neigh, " ")

        if (next_i < neigh_count) {
          stack_i[sp2] = next_i + 1
          w = neigh[next_i + 1]
          if (!(w in idx)) {
            idx[w] = idx_counter
            low[w] = idx_counter
            idx_counter++
            on_stack[w] = 1
            ts[++sp] = w
            stack_v[++sp2] = w
            stack_i[sp2] = 0
          } else if (w in on_stack) {
            if (idx[w] + 0 < low[v] + 0) {
              low[v] = idx[w]
            }
          }
        } else {
          # 全隣接を消化 → SCC root 判定
          if (low[v] + 0 == idx[v] + 0) {
            # SCC として ts スタックから v までを取り出す
            scc = ""
            do {
              w = ts[sp--]
              delete on_stack[w]
              scc = (scc == "") ? w : scc " " w
            } while (w != v)
            scc_groups[v] = scc
          }
          # parent に low を伝搬
          if (sp2 > 1) {
            parent = stack_v[sp2 - 1]
            if (low[v] + 0 < low[parent] + 0) {
              low[parent] = low[v]
            }
          }
          sp2--
        }
      }
    }
  '
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Escalation Layer
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 引数 $1 = 対象 Issue 番号（数字のみ）
# stdout = なし（戻り値で表現）
# 戻り値: 0 = 既存コメントに本機能由来マーカー検出（既通知 / Req 5.2）
#         1 = 未通知 or gh 取得失敗（安全側で「投稿済扱い」にして再投稿抑止 / NFR 3.2）
# 副作用: read-only gh API のみ
#
# `gh issue view --json comments` で対象 Issue のコメント本文を一括取得し、
# `DC_CYCLE_MARKER` を grep する（Req 5.2, 5.3 冪等性 / NFR 6.1）。
dc_has_cycle_marker() {
  local issue_num="$1"
  local comments_json
  if ! comments_json=$(gh issue view "$issue_num" --repo "$REPO" \
        --json comments 2>/dev/null); then
    # 取得失敗 → 安全側で「投稿済扱い」にして再投稿抑止（NFR 3.2）
    dr_warn "issue=#${issue_num} gh issue view --json comments 失敗（cycle marker 検出 skip / 投稿済扱い）"
    return 0
  fi
  if printf '%s' "$comments_json" \
      | jq -r '.comments[]?.body // ""' 2>/dev/null \
      | grep -qF -- "$DC_CYCLE_MARKER"; then
    return 0
  fi
  return 1
}

# 引数:
#   $1 = 当該 Issue 番号
#   $2 = 閉路メンバー集合（空白区切り、数値昇順 / dc_find_cycles 出力 1 行）
# stdout = 説明コメント本文（多行 markdown / DC_CYCLE_MARKER 付き）
# 副作用なし（純粋関数 / Req 4.2, 4.3 / NFR 5.2 未信頼入力の安全展開）
#
# 閉路メンバー番号は数値検証済みであることを呼び出し側で保証する前提。コメントテンプレートへの
# 展開時は単なる数値列なので追加エスケープは不要だが、本文中の `#N` 記法を逐次組み立てる。
dc_format_cycle_comment() {
  local issue_num="$1"
  local members="$2"

  # メンバーを `#N` リストへ整形（空白区切り → "#N1, #N2, ..."）
  local member_csv
  member_csv=$(printf '%s\n' "$members" \
    | tr ' ' '\n' \
    | grep -E '^[0-9]+$' \
    | awk '{ printf "#%s, ", $0 }' \
    | sed -E 's/, $//')

  cat <<EOF_DC_CYCLE
🔁 依存グラフに閉路を検出しました（cycle detection / D-16）。

本 Issue は以下の閉路メンバーに含まれており、\`Depends on:\` 系の依存関係が循環している
ため、自動処理（\`blocked\` ラベルの自動解除など）が進められません。人間判断にエスカレート
するため \`needs-decisions\` ラベルを付与しました。

### 閉路メンバー

${member_csv}

### 次の手順

1. 上記閉路メンバー Issue 間の依存関係（\`Depends on:\` / \`前提依存:\` / \`Blocked by:\`）を確認し、
   閉路を構成するエッジのいずれかを切断してください（依存記法の修正 / 設計の見直し）
2. 閉路解消後、本 Issue から \`needs-decisions\` ラベルを**手動で除去**してください
3. 次回 cron tick で本 Issue の依存ゲート判定が再評価されます

### 補足

本通知は本機能由来であることを判定可能なマーカーを含み、後続 tick で重複投稿されません
（冪等 / NFR 6.1）。本ラベル付与中は #346 Dependency Auto-Unblock Sweep による
\`blocked\` 自動解除はスキップされます。

${DC_CYCLE_MARKER}
EOF_DC_CYCLE
}

# 引数:
#   $1 = 対象 Issue 番号
#   $2 = 閉路メンバー集合（空白区切り）
# 戻り値:
#   0 = 処理完了（付与済 skip / 付与 + コメント成功 / 中途失敗いずれも 0）
#   非 0 は使わない（fail-open / NFR 3.2）
# 副作用:
#   - 既通知判定 → 既通知なら何もせず skip ログ
#   - 未通知 → `gh issue edit --add-label needs-decisions` + `gh issue comment` を順に実行
#   - 各分岐で `dr_log` / `dr_warn` 構造化ログ 1 行（Req 6.3, 6.4, 6.5）
#
# 付与順序: 「ラベル先 → コメント後」（Req 4.5 / NFR 3.2）。ラベル失敗時はコメント投稿せず
# 次 Issue へ進む（Req 4.5）。ラベル成功 + コメント失敗時は警告ログを残して次 Issue へ
# （Req 4.6 / NFR 3.2 中途半端でも次 tick で冪等補正可能）。
dc_escalate_member() {
  local issue_num="$1"
  local members="$2"

  # 数値検証（NFR 5.1 / CLAUDE.md §5）
  if ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
    dr_warn "issue=#${issue_num} cycle escalate skip: 数値検証失敗"
    return 0
  fi

  # 冪等性チェック（Req 5.1, 5.2 / NFR 6.1）
  if dc_has_cycle_marker "$issue_num"; then
    dr_log "issue=#${issue_num} verdict=cycle_already_notified members=${members}"
    return 0
  fi

  # ラベル付与（Req 4.1）
  if ! gh issue edit "$issue_num" --repo "$REPO" \
        --add-label "$LABEL_NEEDS_DECISIONS" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} gh issue edit --add-label ${LABEL_NEEDS_DECISIONS} 失敗 / コメント投稿せず skip"
    return 0
  fi

  # コメント投稿（Req 4.2, 4.3）
  local body
  body=$(dc_format_cycle_comment "$issue_num" "$members")
  if ! gh issue comment "$issue_num" --repo "$REPO" --body "$body" >/dev/null 2>&1; then
    dr_warn "issue=#${issue_num} cycle 説明コメント投稿に失敗（ラベルは付与済）"
    return 0
  fi

  dr_log "issue=#${issue_num} verdict=cycle_escalated members=${members}"
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Entry Point
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# 引数 $1 = `gh issue list --json number,body` 相当の JSON 配列
# stdout = なし（_DC_CYCLE_MEMBERS グローバル変数に空白区切り集合を export）
# 戻り値 = 常に 0（個別 Issue の成否は内部ログで表現 / NFR 3.2 fail-open）
# 副作用:
#   - 閉路検出 → 各閉路メンバーに対して dc_escalate_member 適用
#   - 構造化ログ 1 行/閉路 + 1 行/サマリ（Req 6.1, 6.2）
#   - _DC_CYCLE_MEMBERS グローバル変数を「空白区切りの閉路メンバー Issue 番号集合」に設定
#     （`dr_unblock_sweep` が auto-unblock 対象から除外するために参照する / AT-j）
#
# gate 判定 + full-auto kill switch（AND 二重 opt-in）は呼び出し側 `dr_unblock_sweep` で評価
# 済み前提。本関数は dr_unblock_sweep が取得済みの `issues_json` をそのまま受け取って
# グラフ構築から処理開始する（NFR 2.2 / 本文取得 API を二重呼び出ししない）。
dc_cycle_sweep() {
  local issues_json="${1:-[]}"

  # cycle members の初期化（前回 tick の値が残らないように）
  _DC_CYCLE_MEMBERS=""
  export _DC_CYCLE_MEMBERS

  # グラフ構築
  local edges
  edges=$(dc_build_graph_lines "$issues_json")

  # エッジゼロ → 閉路は存在しない。サマリログ 1 行（Req 6.2）。
  local target_count
  target_count=$(printf '%s' "$issues_json" | jq 'length' 2>/dev/null || echo 0)
  [ -z "$target_count" ] && target_count=0

  if [ -z "$edges" ]; then
    dr_log "dc_cycle_sweep: cycles=0 targets=${target_count} (no edges)"
    return 0
  fi

  # 閉路検出
  local cycles
  cycles=$(dc_find_cycles "$edges")

  if [ -z "$cycles" ]; then
    dr_log "dc_cycle_sweep: cycles=0 targets=${target_count}"
    return 0
  fi

  # 各閉路に対するエスカレーション
  local cycle_line cycle_count=0 all_members=""
  while IFS= read -r cycle_line; do
    [ -z "$cycle_line" ] && continue
    cycle_count=$((cycle_count + 1))
    # 閉路ごとのサマリログ（Req 6.1 / NFR 4.1）
    dr_log "dc_cycle_sweep: cycle=${cycle_count} members=${cycle_line}"

    # メンバー集約（_DC_CYCLE_MEMBERS への展開用）
    all_members="${all_members:+${all_members} }${cycle_line}"

    # 各メンバーへエスカレーション
    local member
    for member in $cycle_line; do
      [ -z "$member" ] && continue
      if ! [[ "$member" =~ ^[0-9]+$ ]]; then
        dr_warn "dc_cycle_sweep: cycle=${cycle_count} 不正なメンバー番号 skip: ${member}"
        continue
      fi
      dc_escalate_member "$member" "$cycle_line" || true
    done
  done <<<"$cycles"

  # 全閉路メンバーを uniq + 空白区切りで _DC_CYCLE_MEMBERS に設定
  if [ -n "$all_members" ]; then
    _DC_CYCLE_MEMBERS=$(printf '%s\n' "$all_members" \
      | tr ' ' '\n' \
      | grep -E '^[0-9]+$' \
      | sort -u -n \
      | tr '\n' ' ' \
      | sed -E 's/ +$//')
    export _DC_CYCLE_MEMBERS
  fi

  dr_log "dc_cycle_sweep: cycles=${cycle_count} targets=${target_count} members=${_DC_CYCLE_MEMBERS}"
  return 0
}
