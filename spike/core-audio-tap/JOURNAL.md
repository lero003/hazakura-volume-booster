# Hazakura Boost PoC 作業記録 (JOURNAL)

> 親: [`hazakura-volume-booster/`](../)  
> 関連: [`README.md`](./README.md) / [`docs/TECH_SPIKE.md`](../../docs/TECH_SPIKE.md) / [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) / [`docs/RISKS.md`](../../docs/RISKS.md) / [`docs/PERMISSIONS.md`](../../docs/PERMISSIONS.md)

## TL;DR (2026-06-17 時点)

- 純Core Audio経路（AVAudioEngine inputNode / AudioDeviceCreateIOProcID / HALOutput AudioUnit）はいずれも v0.1 beta の active 経路としては不採用
- 現在は **Core Audio process tap で元音を muted にし、ScreenCaptureKit audio → PCMFloatRingBuffer → AVAudioSourceNode** で加工後音を出す構成
- ユーザー手元確認で、音量ブースト、二重再生の抑制、音質劣化の軽減は v0.1 beta として許容範囲に到達
- `daily-use-ok` に向け、コード側では Quit / `⌘Q` / スリープ前の neutral gain、二重起動抑止、出力デバイス変更時の安全停止、Dev 診断拡張と health 判定を追加済み
- 計画ドキュメント（`docs/` 配下 8 本）は完成済み、レビュー反映済み
- 残る主な確認は、強制終了後の残骸確認、スリープ復帰・出力デバイス変更の実機挙動、10分以上の連続再生、配布用署名・公証
- 詳細は後述の「PoC 試行の歴史」「現コードの構成」「検証チェックリスト」を参照

## 環境

| 項目 | 値 |
|---|---|
| Mac model | Mac16,9 |
| OS | macOS 26.5.1 (25F80) |
| Xcode | 26.5 (17F42) |
| Swift | 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101) |
| macOS SDK | 26.5 |
| Deployment target | macOS 26.0+ |
| xcodegen | 2.45.4 (Homebrew) |
| 作業ディレクトリ | `spike/core-audio-tap/` |

## 完成済みドキュメント

| パス | 状態 |
|---|---|
| `hazakura-volume-booster企画書.md` | ✅ 一次資料（未改変） |
| `README.md` | ✅ |
| `docs/ARCHITECTURE.md` | ✅ ちかちゃんレビュー反映済み |
| `docs/ROADMAP.md` | ✅ 〃 |
| `docs/DEVELOPMENT.md` | ✅ 〃 |
| `docs/RISKS.md` | ✅ 〃 |
| `docs/PERMISSIONS.md` | ✅ 〃 |
| `docs/UI_DESIGN.md` | ✅ 〃 |
| `docs/TECH_SPIKE.md` | ✅ 〃（v0.1 着手前に PoC 合格が条件） |
| `spike/core-audio-tap/README.md` | ✅ v0.1 beta PoC の active 構成へ更新 |
| `spike/core-audio-tap/project.yml` | ✅ |
| `spike/core-audio-tap/CoreAudioTapPoC/Resources/Info.plist` | ✅ `NSAudioCaptureUsageDescription` 入り |
| `spike/core-audio-tap/CoreAudioTapPoC/Resources/CoreAudioTapPoC.entitlements` | ✅ Hardened Runtime 必須項目のみ |
| `spike/core-audio-tap/CoreAudioTapPoC-Bridging-Header.h` | ✅ `AudioIOProc.h` インポート（残置、未使用） |

## PoC 試行の歴史（v0 → v2）

すべて **macOS 26.5.1 / Xcode 26.5 / Swift 6.3.2** 上で実施。

### v0: AVAudioEngine + `setDeviceID`（失敗）

**アプローチ**:
- `AVAudioEngine.inputNode` に `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` で aggregate device を流し込む
- `AVAudioUnitEQ.globalGain` でゲイン制御

**エラー**:
```
kAudioUnitErr_FailedInitialization (-10875)
```

**症状**: 
- aggregate 作成は成功
- engine.start() で -10875
- エンジン初期化段階で input AudioUnit が aggregate device を受け付けず死亡

**教訓**:
- `AVAudioEngine` は「tap しかない aggregate」を input device として起動できない
- Apple 公式の `Capturing system audio with Core Audio taps` サンプルも `AVAudioEngine` ではなく HAL レベル API を使っている

### v1: `AudioDeviceCreateIOProcID`（失敗）

**アプローチ**:
- `AudioDeviceCreateIOProcID(aggregate, AudioIOProcImpl, ...)` で IO proc を直接登録
- `AudioDeviceStart(aggregate, ioProcID)` で開始
- IO proc 内で tap → 加工 → 出力バッファへ書き戻し

**追加対応**:
- `kAudioAggregateDeviceTapAutoStartKey: true` を aggregate description に追加
- `kAudioAggregateDeviceSubDeviceListKey` を `[]` → `[defaultOutputUID]` に変更（ループバック出力のため）

**エラー**:
```
1852797029 (0x6E616369 'naci')
```

**症状**:
- `AudioDeviceCreateIOProcID` 成功
- `AudioDeviceStart` 成功
- しかし **IO proc が一度も呼ばれない**（呼び出しカウンタが 0 のまま固定）
- mute = `.muted` → `.unmuted` に変えても同じ
- sub-device を空にしてみても同じ

**教訓**:
- macOS 26 の `AudioDeviceCreateIOProcID` + aggregate (tap 入り) は、IO proc を駆動しない
- Apple 公式サンプルは ioproc を使うが、これは aggregate ではなく「他の録音用 HAL デバイス」向け
- audiotee プロジェクトも同じ問題に遭遇し、回避策として `AudioUnit` パターンへ移行

**残骸ファイル**:
- `CoreAudioTapPoC/Audio/AudioIOProc.h` / `AudioIOProc.mm`（**未使用、削除検討**）
- `CoreAudioTapPoC/CoreAudioTapPoC-Bridging-Header.h`（これへの import が残ったまま）

### v2: HALOutput AudioUnit + render callback（失敗）

**アプローチ**:
- `AudioComponentInstanceNew(kAudioUnitSubType_HALOutput)` で AudioUnit を開く
- `kAudioOutputUnitProperty_EnableIO` (input) = true
- `kAudioOutputUnitProperty_CurrentDevice` = aggregateID
- `kAudioUnitProperty_StreamFormat` を output / input 両バスに Float32/stereo/48kHz で設定
- `kAudioUnitProperty_SetRenderCallback` で output (bus 0) に callback 設定
- `AudioUnitInitialize` → `AudioOutputUnitStart`
- render callback 内で `AudioUnitRender` (input bus 1) → ゲイン乗算 → 出力 (bus 0) へ

**エラー**:
```
CurrentDevice failed (OSStatus=-10851 '0xFFFFD59D')
```
- `-10851` = `kAudioUnitErr_InvalidPropertyValue`

**症状**:
- EnableIO (input) は成功
- CurrentDevice で死亡

**教訓（推定）**:
- aggregate が **private** であることが原因の可能性
  → `kAudioAggregateDeviceIsPrivateKey: false` を試す価値あり
- aggregate の input stream が **live でない** 可能性
  → 待機時間を増やす、aggregate の stream 状態を PoC 開始前に確認
- audiotee は **non-private + sub-device なし** 構成で動いている

## 現コードの構成

```
spike/core-audio-tap/
├── project.yml                         xcodegen 用定義（.mm 含む、Bridging Header 設定済み）
├── CoreAudioTapPoC.xcodeproj/          xcodegen で生成（git管理外でも再生成可）
├── CoreAudioTapPoC/
│   ├── CoreAudioTapPoCApp.swift         @main
│   ├── ContentView.swift                SwiftUI: Slider + 100/200/400/0% + Start/Stop + Diagnostics
│   ├── CoreAudioTapPoC-Bridging-Header.h  (旧IOProc実験用。active経路では未使用)
│   ├── Audio/
│   │   ├── BoostAudioPipeline.swift     active: ScreenCaptureKit + ring buffer + AVAudioEngine
│   │   ├── ScreenCaptureAudioSource.swift ScreenCaptureKit audio capture
│   │   ├── PCMFloatRingBuffer.swift     capture/render 間のバッファ
│   │   ├── SystemTap.swift              CATapDescription + Aggregate device（元音ミュート用）
│   │   ├── AudioIOProc.h / .mm          残置（v1 アプローチのコード、active経路では未使用）
│   │   ├── GainProcessor.swift          linear→dB の数式ヘルパ + soft limiter
│   │   └── PoCAudioEngine.swift         Swift 側オーケストレータ
│   └── Resources/
│       ├── Info.plist                   NSAudioCaptureUsageDescription 入り
│       └── CoreAudioTapPoC.entitlements Hardened Runtime 必須項目のみ
└── CoreAudioTapPoCTests/
    └── GainProcessorTests.swift        ゲイン処理、診断、ring buffer、tap description など
```

## 各ファイルの状態と既知の問題

| ファイル | 状態 | 備考 |
|---|---|---|
| `BoostAudioPipeline.swift` | ✅ active | ScreenCaptureKit capture、ring buffer、AVAudioEngine 出力を接続 |
| `ScreenCaptureAudioSource.swift` | ✅ active | ScreenCaptureKit audio buffer を ring buffer へ書き込む |
| `PCMFloatRingBuffer.swift` | ✅ active | capture/render間の吸収。短すぎるtrimでブツ音が出たため latency budget を拡大済み |
| `SystemTap.swift` | ✅ active | `muteBehavior = .muted`、自アプリ bundle id を除外して二重再生を抑える |
| `PoCAudioEngine.swift` | ✅ active | 診断タイマーで capture/render/gain/underrun/drop を UI に表示。Quit / sleep / wake / 出力変更の安全側処理を集約 |
| `ContentView.swift` | ✅ active | `DiagnosticsView`、Dev toggle、copy diagnostics を含む |
| `AudioIOProc.h/.mm` | ❌ 未使用 | v1 IOProc経路の残骸。active経路では呼ばれていない |
| `GainProcessor.swift` | ✅ active | linear gain と soft limiter。テスト対象 |
| `Info.plist` | ✅ 動作確認済み | `NSAudioCaptureUsageDescription` 入り、`LSUIElement = true` |
| `entitlements` | ✅ 動作確認済み | App Sandbox OFF、Hardened Runtime 必須項目 |

## ユーザ側で観測された症状のサマリ

| 試行 | Start 結果 | 聞こえ方 | Diagnostics |
|---|---|---|---|
| v0 (AVAudioEngine) | -10875 エラーで停止 | 無音 | n/a |
| v1 sub-device 込み | 'naci' (1852797029) で停止 | 無音 | IO proc calls: 0 固定 |
| v1 sub-device 空 | ステータスは `running` まで進む | **元音は聞こえる** | IO proc calls: **0 のまま** |
| v2 (HALOutput AudioUnit) | CurrentDevice failed (-10851) | n/a（停止） | n/a |

**重要な所見**: v1 sub-device 空のケースで「元音は聞こえる」が「IO proc は一度も呼ばれない」状態は、**tap が起動して default output の音声は流れているが、aggregate IO 駆動経路が存在しない**ことを示している。

## 採用した仮説と残した仮説

### 採用: ring buffer + AVAudioEngine 出力

ScreenCaptureKit から PCM を受け取り、**ring buffer に書き込む**。出力は別経路で、**AVAudioEngine + `AVAudioSourceNode`** が ring buffer を読んで default device へ出力する。

**メリット**:
- aggregate 側（HALOutput 縛り）から逃れられる
- 出力経路は実績ある AVAudioEngine
- v0.1 への移植パスがそのまま見える

**デメリット**:
- 実装量が増える（ring buffer の lock-free 設計）
- 低レイテンシは多少犠牲になる可能性（ring buffer 経由のぶん）

**結果**:
- `AVAudioSourceNode` から ring buffer を読んで Float32 stereo で出力できた
- 短すぎる latency budget はブツ音の原因になり得るため、余裕を持たせた
- 元音ミュートには Core Audio process tap を併用する

### 未採用: aggregate を non-private にしてみる

`kAudioAggregateDeviceIsPrivateKey: true` が AudioUnit 側の CurrentDevice 受付拒否に影響している可能性。

**確認方法**:
- `SystemTap.swift` の `createAggregateDevice` で `kAudioAggregateDeviceIsPrivateKey: false` に変更
- v2 (HALOutput AudioUnit) をそのまま再テスト

**期待結果**:
- CurrentDevice が成功 → v2 構成が成立 → IO proc (render callback) が呼ばれる
- 音量変化まで行ければ `mute = .muted` に戻して v0.1 へ

### 採用済み: ScreenCaptureKit フォールバック

`ScreenCaptureKit` の `SCStream` でシステム音声をキャプチャする方法。Apple が別途用意している音声キャプチャ API。

**メリット**:
- Core Audio Tap より上のレイヤで、将来的に安定する可能性がある
- audiotee が Core Audio Tap で詰まっている事実を踏まえた代替案

**デメリット**:
- 別 API の学習コスト
- `AVAudioEngine` との統合パターンが別途必要

**結果**: 現在の v0.1 beta PoC の入力経路として採用。

## 再開手順

### 環境再現

```bash
cd spike/core-audio-tap

# 既存のプロセスを kill（過去のアタッチが残っている可能性があるため）
pkill -f CoreAudioTapPoC.app 2>/dev/null

# xcodegen で再生成
xcodegen generate

# ビルド
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  clean build

# テスト
xcodebuild -project CoreAudioTapPoC.xcodeproj -scheme CoreAudioTapPoC -destination 'platform=macOS' -derivedDataPath build test
```

### ログ採取コマンド

```bash
# subsystem フィルタで永続ログ
log show --predicate 'subsystem == "dev.keisetsu.hazakura-volume-booster.poc"' --last 5m --info

# ライブ監視（Start 押す前に走らせるとリアルタイムで流れる）
log stream --predicate 'subsystem == "dev.keisetsu.hazakura-volume-booster.poc"' --level info
```

### 検証チェックリスト（`docs/TECH_SPIKE.md` の Done 条件）

```
[ ] YouTube 音声を取得できた
[ ] 100%（素通し）で原音と同等に聴こえる
[ ] 200% / 400% で音量が明確に上がる
[ ] 元音と加工後音が二重に鳴らない
[ ] 100% 復帰できる
[ ] アプリ終了で通常出力に戻る
[ ] スリープ前にゲインが 1.0 へ戻る
[ ] スリープから復帰して保存値へ復元する
[ ] 強制終了後に OS 側に tap/routing が残らない
[ ] 権限拒否でクラッシュしない
[ ] マイク権限ダイアログが出ない
[ ] レイテンシが 200ms 未満の体感
```

## 撤退判断（PoC 撤退ライン）

`docs/TECH_SPIKE.md` で定義:

- システム音のタップ→戻しのラウンドトリップが成立しない
- 200ms を超える体感遅延が避けられない
- 強制終了で OS 側に tap/routing が残る
- エコー（原音と加工後音の二重再生）が避けられない

→ 純Core Audio IOProc経路は v0.1 beta の active 実装としては不採用。現在は ScreenCaptureKit + ring buffer + AVAudioEngine 出力の折衷構成で継続する。

## 変更履歴

- **2026-06-14**: 初版作成
  - v0 (AVAudioEngine) → -10875 で失敗
  - v1 (AudioDeviceCreateIOProcID) → IO proc 未呼出で失敗
  - v2 (HALOutput AudioUnit) → CurrentDevice failed (-10851) で失敗
  - 次のアクション: 仮説 A（ring buffer + AVAudioEngine 出力）または仮説 B（aggregate を non-private）
- **2026-06-14（修正）**: v1 アプローチを再評価・再構成
  - `AudioUnitInput.swift`（v2 / HALOutput AudioUnit）を削除
  - `AudioIOProc.mm`（v1 / `AudioDeviceCreateIOProcID`）を再採用
  - `SystemTap.setup()` で aggregate device を **default output** に設定し、IO proc 駆動経路を確保
  - `SystemTap.teardown()` で元の default output デバイスを必ず復元
  - `muteBehavior` を `.unmuted`（デバッグ用）から `.muted` に変更し、エコー防止
  - `PoCAudioEngine` に `configuredGain` / `isEnabled` / `effectiveGain` の状態管理を追加
  - `CoreAudioTapPoCApp` を `WindowGroup` から `MenuBarExtra` に変更（`LSUIElement = true`）
  - `ContentView` に ON/OFF トグル・100%復帰・終了ボタンを追加
  - ビルド成功、単体テスト 4/4 pass、アプリ起動確認
  - 未検証項目: 実際の音声ループバック（ユーザー環境での聴感チェックが必要）
- **2026-06-17**: v0.1 beta PoC の active 構成を更新
  - Core Audio process tap は元音ミュートに使う
  - ScreenCaptureKit audio capture → PCMFloatRingBuffer → AVAudioSourceNode 出力へ変更
  - soft limiter と latency budget 拡大で音割れ・ブツ音を軽減
  - 単体テスト 19/19 pass、Debug build 成功
- **2026-06-17（daily-use-ok safety slice）**:
  - Quit / `⌘Q` / termination で `gain=1.0` を先に適用してから backend を停止する API を追加
  - スリープ前 neutral / 復帰後 restored gain、出力デバイス変更時の安全停止、二重起動抑止を追加
  - Dev 診断に available frames / underrun count / dropped frames / latest buffer size と copy diagnostics を追加
  - 単体テスト 23/23 pass
- **2026-06-17（diagnostic health slice）**:
  - Dev 診断に `OK` / `Watch` / `Warning` の health 判定を追加
  - 5分再生で underrun 30 / render 15,809 / dropped 0 相当は Watch として扱うテストを追加
  - 単体テスト 27/27 pass
- **2026-06-17（sleep wake recovery slice）**:
  - スリープ前は `gain=1.0` 適用後に ScreenCaptureKit / AVAudioEngine / process tap を停止するよう変更
  - 復帰後は保存済み gain / ON-OFF 設定を使って fresh start する
  - 単体テスト 29/29 pass
