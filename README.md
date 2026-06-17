# Hazakura Boost

> Macの小さい音を、メニューバーからすぐ持ち上げる。

**Hazakura Boost**（リポジトリ名: `hazakura-volume-booster`）は、Macのシステム音量をメニューバーから一時的にブーストする常駐型ユーティリティアプリです。YouTubeや配信、講義動画、古い音源など「最大音量でも小さすぎる」コンテンツを、外部スピーカーやモニターの物理ボリュームを触らずに聞こえやすくします。

ドライバ非依存・アプリ別ミキサー非対応・EQ非対応という割り切りで、Mac全体の音を「**少し大きくする**」ことだけに集中します。

## ステータス

**フェーズ: v0.1 public beta / Core Audio PoC**

- ✅ 企画書 [`hazakura-volume-booster企画書.md`](./hazakura-volume-booster企画書.md)
- ✅ 準備ドキュメント（本リポジトリの `docs/`）
- ✅ **Core Audio Tap + ScreenCaptureKit PoC**（[`spike/core-audio-tap`](./spike/core-audio-tap)）
- ✅ メニューバーUI / 0%〜400%スライダー / 右クリック終了 / Dev診断表示
- ✅ 手元環境での音量ブースト確認（100% / 200% / 400%）
- ⚠️ 署名済みDMG・公証・自動アップデートは未整備
- ⚠️ v0.1 は実験的なベータ。音質・遅延・権限まわりは継続検証中

## クイックリンク

| ドキュメント | 内容 |
|---|---|
| [`hazakura-volume-booster企画書.md`](./hazakura-volume-booster企画書.md) | プロダクト企画の一次資料。コンセプト・想定ユーザー・MVP機能・やらないこと |
| [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) | 技術アーキ・コンポーネント構成・データフロー・技術選定理由 |
| [`docs/ROADMAP.md`](./docs/ROADMAP.md) | v0.1〜v0.4+ のマイルストーンとDoneの定義 |
| [`docs/TECH_SPIKE.md`](./docs/TECH_SPIKE.md) | **Core Audio Tap PoC**。v0.1 着手前に通す技術検証の Done 条件 |
| [`docs/DEVELOPMENT.md`](./docs/DEVELOPMENT.md) | 開発環境・ビルド/テスト手順・コード規約・ブランチ戦略 |
| [`docs/RISKS.md`](./docs/RISKS.md) | 技術リスク・既知の落とし穴・未解決の論点 |
| [`docs/PERMISSIONS.md`](./docs/PERMISSIONS.md) | macOSのAudio/Sandbox/Hardened Runtime/Notarization方針 |
| [`docs/UI_DESIGN.md`](./docs/UI_DESIGN.md) | アイコン・ポップオーバー・状態表現・アクセシビリティ |
| [`spike/core-audio-tap/README.md`](./spike/core-audio-tap/README.md) | 現在動いている v0.1 beta PoC のビルド・起動手順 |

## 現在の実装

v0.1 beta は `spike/core-audio-tap/` の PoC 実装を現在の実体として扱います。

- ScreenCaptureKit でシステム音声を取得
- Core Audio process tap を `.muted` で使い、元音の二重再生を抑制
- `PCMFloatRingBuffer` 経由で `AVAudioSourceNode` から加工後音を出力
- ゲインは 0%〜400% を対象とし、100%未満では小さく、100%超では簡易ソフトリミッタで過大なクリッピングを抑制
- Dev モードで capture buffer / render call / output gain / event log を確認可能

これは配布製品ではなく、手元で使える public beta PoC です。録音・保存・外部送信は行いません。

## ビルド・テスト

```bash
cd spike/core-audio-tap

xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  test

xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  build

./scripts/build_release_candidate.sh
```

起動:

```bash
open spike/core-audio-tap/build/Build/Products/Debug/CoreAudioTapPoC.app
```

普段の開発確認は `Debug` / Apple Development 署名、GitHub Release 前の確認は `./scripts/build_release_candidate.sh` で作る `Release` / Developer ID 署名の app を使います。公証と staple は外部配布直前の別工程です。

## 企画書の要点（要約）

- **対応OS**: macOS 26以降（古いmacOSは対象外。仮想オーディオデバイス等の複雑化を回避するため）
- **配布形態**: ドライバ不要。アプリ単体で動くことを優先
- **MVPスコープ**:
  1. メニューバー常駐
  2. ブーストスライダー 0%〜400%
  3. 開始/停止
  4. 状態表示（%）
  5. 終了時の安全処理
- **やらないこと**: アプリ別ミキサー / タブ別音量 / EQ / ノイズ除去 / 録音 / 配信ミキサー / 複数出力先 / 古いmacOS対応 / 高度な音割れ防止
- **コア体験**: 外部スピーカーのつまみを触らず、メニューバーだけで音を持ち上げる

## ポジショニング（差別化）

`Background Music` や `SoundSource` のような多機能な音声制御アプリとは異なる、**「全体ブースト専用」**の小さなMacユーティリティとして位置づけます。

- アプリ別ミキサーではなく、全体ブーストに集中
- メニューバーだけで完結
- ドライバ不要の軽量設計
- 外部スピーカー利用者に刺さる

## 名称の使い分け

| 名称 | 用途 |
|---|---|
| **Hazakura Boost** | プロダクト名・UI表示・App Store表記・README・リリースノート |
| **hazakura-volume-booster** | リポジトリ名・Xcodeプロジェクト名・Bundle Identifierの一部候補 |

リポジトリ名から変更する予定が現時点で無いため、**両者は同じものを指す**として扱います。

## 次のアクション

1. `spike/core-audio-tap/` の PoC を v0.1 本体プロジェクトへ昇格するか判断する
2. 強制終了・スリープ復帰・出力デバイス変更時の安全性を追加検証する
3. Developer ID署名 / Notarized DMG / Privacy Manifest を配布前に整備する
4. README と `docs/` の計画文書を、PoC結果に合わせて順次更新する

## ライセンス

Hazakura Boost はプロプライエタリソフトウェアです。詳細は [`LICENSE`](./LICENSE) を参照してください。
