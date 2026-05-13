# Requirements Document

## Introduction

idd-claude を multi-branch（`develop` を base にした gitflow 系）運用するリポジトリでは、
feature PR を `develop` に merge した時点で GitHub の Issue auto-close（`Closes #N` リンクによる
自動 close）は発火しない。auto-close は **default branch にマージされた PR** でのみ発火する
ためで、`BASE_BRANCH=develop` 運用下では「develop には載ったが main にはまだ届いていない
Issue」が `ready-for-review` / open のまま滞留し、リリース可視性が下がる。

本機能は idd-claude 標準ラベルセットに `staged-for-release` を追加し、上記の中間状態を運用者が
ラベル 1 つで把握できるようにする。本ラベルは **人間または将来 automation が手動付与する前提**
であり、本 Issue ではラベル定義の配布と運用ドキュメント整備のみを行う（自動付与・自動除去の
automation 自体は Out of Scope）。同時に、Triage / Dispatcher / PR Iteration が
`staged-for-release` 中の Issue を誤って再 pickup しないよう、既存ポーリングクエリの除外条件に
同ラベルを加える。

なお、single-branch（`BASE_BRANCH` 未設定 = `main` のみ）運用では本ラベルは意味を持たない。
ラベル定義自体は全リポジトリに配布されるが、運用上の使用は multi-branch 運用のみが対象である。

## Requirements

### Requirement 1: ラベル定義の追加（idd-claude 標準ラベルセット）

**Objective:** As a idd-claude 利用リポジトリ運用者, I want `staged-for-release` ラベルが
idd-claude の一括ラベル作成スクリプトで作成されること, so that 各リポジトリで個別に
`gh label create` を打たずに、標準ラベルセットの一部として一括配布できる。

#### Acceptance Criteria

1. When 運用者が idd-claude の一括ラベル作成スクリプトを実行する, the Labels Setup Script shall `staged-for-release` という名前のラベルを GitHub リポジトリに作成する
2. When `staged-for-release` ラベルを作成する, the Labels Setup Script shall ラベル色 `b8e0d2` を設定する
3. When `staged-for-release` ラベルを作成する, the Labels Setup Script shall description に「`develop` に merge 済み、`main` 到達待ち」という意味が読み取れる文字列を設定する
4. While `staged-for-release` ラベルが既に存在する状態で `--force` オプション無しで再実行された, the Labels Setup Script shall 当該ラベルを上書きせず skip 結果として報告する
5. While `staged-for-release` ラベルが既に存在する状態で `--force` オプション付きで再実行された, the Labels Setup Script shall 当該ラベルの color と description を上書き更新する
6. The Labels Setup Script shall `staged-for-release` を「Issue に適用するラベル」として扱い、既存 idd-claude 標準ラベルの description における 適用先 prefix（【Issue 用】 / 【PR 用】）規約に整合させる
7. The Labels Setup Script shall idd-claude 自身用（self-hosting）の一括ラベル作成スクリプトと、consumer 配布用テンプレートの一括ラベル作成スクリプトの両系統で、同一の名前・色・description で `staged-for-release` を提供する

### Requirement 2: ポーリングクエリでの除外

**Objective:** As a idd-claude watcher 運用者, I want `staged-for-release` ラベルが付いた
Issue を auto-dev の再 pickup 対象から除外したい, so that release を待つ間に Triage /
Dispatcher / PR Iteration が誤って同じ Issue を再処理しない。

#### Acceptance Criteria

1. While Issue に `staged-for-release` ラベルが付与されている, the Watcher Polling Query shall 当該 Issue を auto-dev pickup の候補から除外する
2. The README.md ポーリングクエリ節 shall `-label:staged-for-release` を除外条件として明示する
3. When 運用者が README.md のポーリングクエリ節を参照する, the README.md shall `-label:staged-for-release` の除外目的（release 待ちの Issue を再 pickup しないため）を 1〜2 行の運用注記として併記する

### Requirement 3: ラベル状態遷移ドキュメントの更新

**Objective:** As a idd-claude リポジトリ運用者, I want README.md の「ラベル状態遷移まとめ」節
に `staged-for-release` の位置付けが書かれていること, so that ラベルを見ただけで
「適用先 = Issue」「付与主 = 人間 もしくは future automation」「意味 = `develop` merge 済み /
`main` 到達待ち」を即座に判別できる。

#### Acceptance Criteria

1. The README.md ラベル一覧テーブル shall `staged-for-release` の行を含む
2. The README.md ラベル一覧テーブル shall `staged-for-release` の「適用先」列に `Issue` を記載する
3. The README.md ラベル一覧テーブル shall `staged-for-release` の「付与主」列に「人間（もしくは future automation）」の旨を記載する
4. The README.md ラベル一覧テーブル shall `staged-for-release` の「意味」列に `develop` merge 済み・`main` 到達待ちの旨を記載する
5. The README.md 状態遷移図 shall `staged-for-release` を補助フローとして併記し、本ラベルが既存の main 系遷移とは独立した「`develop` merge 後 → `main` 到達待ち」の中間状態であることを示す
6. The README.md ラベル状態遷移節 shall `staged-for-release` が multi-branch 運用（`BASE_BRANCH=develop` 等）でのみ意味を持ち、single-branch（`main` only）運用では使う必要がない旨を 1〜2 行で明記する

### Requirement 4: 既存挙動・既存ラベルへの後方互換性

**Objective:** As a idd-claude 既存利用リポジトリ運用者, I want 既存のラベル名・色・description・
状態遷移挙動が `staged-for-release` 追加によって変更されないこと, so that 既存運用や、すでに
作成済みのラベル付き Issue が壊れない。

#### Acceptance Criteria

1. The Labels Setup Script shall 既存ラベル（`auto-dev` / `needs-decisions` / `awaiting-design-review` / `claude-claimed` / `claude-picked-up` / `ready-for-review` / `claude-failed` / `skip-triage` / `needs-rebase` / `needs-iteration` / `needs-quota-wait`）の名前・色・description を `staged-for-release` 追加に伴って変更しない
2. While `BASE_BRANCH` が未設定（既定 `main`）のリポジトリで運用されている, the Labels Setup Script shall `staged-for-release` ラベルを作成するが、ラベルが Issue に付与されない限り既存 pickup 挙動に影響を与えない
3. If 既に他用途で `staged-for-release` という名前のラベルが手動作成されているリポジトリで `--force` 無しで再実行された, the Labels Setup Script shall 当該ラベルを skip して既存値を保持する
4. The Labels Setup Script shall 再実行（`--force` の有無に関わらず）に対して冪等であり、`staged-for-release` 追加によって複数回実行時のラベル状態が不整合にならない

### Requirement 5: 関連ドキュメントとの整合

**Objective:** As a idd-claude 利用リポジトリ運用者, I want ラベル一覧を列挙している他の
ドキュメントが `staged-for-release` 追加と整合していること, so that README.md と
QUICK-HOWTO.md の間で「作成されるラベル一覧」が乖離して運用者が混乱しない。

#### Acceptance Criteria

1. When 運用者が `QUICK-HOWTO.md` の「作成されるラベル」一覧を参照する, the QUICK-HOWTO.md shall `staged-for-release` を含むラベル一覧を提示する
2. The Documentation Set shall ラベル名 `staged-for-release` を全ドキュメントで完全一致（lowercase, ハイフン区切り）で記載する
3. If 他に `staged-for-release` への言及・除外条件の追記が必要な箇所がドキュメント側で見つかった場合, the Documentation Set shall 当該箇所も同 PR 内で更新する（grep ベースで網羅）

## Non-Functional Requirements

### NFR 1: 後方互換性

1. The Labels Setup Script shall `staged-for-release` 追加後も、既存の運用者向けインターフェース（コマンド呼び出し方法・`--force` オプション・終了コードの意味）を変更しない
2. The Watcher Polling Query shall `-label:staged-for-release` の追加によって、既存除外条件（`-label:needs-iteration`, `-label:needs-quota-wait` 等）の解釈・挙動が変わらない
3. The Documentation Set shall `staged-for-release` 追加に伴って既存ラベルのテーブル行・状態遷移図の表現を編集する場合でも、既存ラベルの「適用先」「付与主」「意味」記述の意味を変更しない

### NFR 2: 一意性・可視性

1. The Labels Setup Script shall `staged-for-release` のラベル色 `b8e0d2` が既存 idd-claude 標準ラベルの色（`1f77b4` / `f1c40f` / `e67e22` / `c39bd3` / `9b59b6` / `2ecc71` / `e74c3c` / `95a5a6` / `fbca04` / `d4c5f9` / `c5def5`）と重複しないことを満たす
2. The Documentation Set shall 運用者が GitHub Issue 一覧画面で `staged-for-release` ラベルだけをフィルタ条件として指定すれば、`develop` merge 済み・`main` 到達待ちの Issue 集合を 1 クエリで取得できる旨を README.md に記述する

### NFR 3: 冪等性

1. The Labels Setup Script shall 同一リポジトリで N 回（N >= 2）連続実行しても、`staged-for-release` のラベル数が常に 1 個で、name / color / description が宣言通りの値に収束する

## Out of Scope

- `develop` への PR merge イベントに反応して `staged-for-release` を **自動付与** する automation（GitHub Actions workflow / watcher 拡張等）。本 Issue ではラベル定義の配布と運用ドキュメント整備のみを行う
- `main` への release PR merge イベントに反応して `staged-for-release` を **自動除去** する automation
- `staged-for-release` 付与後の Issue を自動 close する機構（GitHub auto-close が `main` merge 時に発火することで本ラベルが「意味を失う」前提に依存する）
- single-branch（`BASE_BRANCH` 未設定 = `main` のみ）運用での `staged-for-release` 活用シナリオ。ラベル定義は配布されるが、運用上の使用は想定しない
- 既存ラベル（`auto-dev` / `ready-for-review` 等）の名前・色・description の変更
- 他ツール（外部 issue tracker / プロジェクト管理 SaaS 等）への `staged-for-release` 状態のミラーリング

## Open Questions

- なし（ラベル名 `staged-for-release`、色 `b8e0d2`、description 方針はいずれも Issue 本文と
  人間コメントで確定済み）
