# アーキテクチャ

> 関連: [企画書 §技術方針](../hazakura-volume-booster企画書.md) / [ROADMAP](./ROADMAP.md) / [RISKS](./RISKS.md) / [PERMISSIONS](./PERMISSIONS.md)

Hazakura Boostの中核は、**「Macのシステム音を一時的にタップし、ゲインを掛けてから出力へ戻す」**という一本のパイプラインです。Macの音量をソフトウェアから持ち上げるには、原則としてこの「タップ → ゲイン → 出力」のどこかに割り込む必要があります。

このドキュメントは、v0.1〜v0.2を視野に入れたシステム全体のアーキ・主要コンポーネント・データフロー・技術選定の理由を整理します。

## 全体像

```
┌───────────────────────────────────────────────────────────────┐
│                          UI Layer                            │
│   ┌──────────────────────────┐    ┌──────────────────────┐  │
│   │ MenuBarExtra (SwiftUI)   │◀──▶│ Popover / 状態バインド │  │
│   └──────────────────────────┘    └──────────────────────┘  │
└────────────────────────┬──────────────────────────────────────┘
                         │ @EnvironmentObject
                         ▼
┌───────────────────────────────────────────────────────────────┐
│                       State / Controller                     │
│   ┌──────────────────────────────────────────────────────┐   │
│   │ BoostController (@MainActor, ObservableObject)      │   │
│   │  - state: BoostState { configuredGain, isEnabled }  │   │
│   │  - setBoost / setEnabled / resetTo100 / shutdown     │   │
│   │  - (DI: AudioEngineProtocol, BoostSettings)         │   │
│   └──────────────────────────────────────────────────────┘   │
└────────────────────────┬──────────────────────────────────────┘
                         │ protocol AudioEngineProtocol
                         ▼
┌───────────────────────────────────────────────────────────────┐
│                     Audio Engine Layer                       │
│   ┌──────────────┐    ┌────────────────┐    ┌──────────────┐ │
│   │ System Tap   │──▶│ AVAudioEngine  │──▶│ Output Device │ │
│   │ (Core Audio  │    │ + GainProcessor│    │  (Default)    │ │
│   │  Tap on      │    │  = AVAudioUnitEQ│    │               │ │
│   │  default     │    │  .globalGain    │    │               │ │
│   │  output)     │    │  or custom AU)  │    │               │ │
│   │              │    │ + (option)      │    │               │ │
│   │              │    │   Soft Limiter  │    │               │ │
│   └──────────────┘    └────────────────┘    └──────────────┘ │
└───────────────────────────────────────────────────────────────┘
```

v0.1では、UIとState、Audio Engineの3層に分けて考えます。**Audio EngineはUIから直接触らせず、必ず `BoostController` を介して操作する**ことをルールとします（テスト容易性・安全な終了処理のため）。`BoostController` は **コンストラクタ注入（DI）** によって `AudioEngineProtocol` と `BoostSettings` を受け取り、**シングルトンに依存しない**ようにします（テスト時にスタブへ差し替え可能）。

## コンポーネント

### 1. UI Layer（SwiftUI + MenuBarExtra）

役割:
- メニューバー常駐のエントリポイント
- ポップオーバーの表示
- ブースト率/有効状態の表示

主な型（予定）:
- `HazakuraBoostApp` … `@main` の `App`
- `MenuBarContent` … `MenuBarExtra` の中身
- `BoostPopoverView` … ポップオーバーのSwiftUIビュー
- `BoostSliderView` … 0%〜400%のSlider
- `StatusLabel` … 「100%」「Boost 180%」など状態ラベル

### 2. State / Controller層

役割:
- 現在の `BoostState` を保持（configuredGain と isEnabled）
- UI ↔ Audio Engineの橋渡し
- ライフサイクル管理（起動/終了時の安全な停止）
- 設定の永続化（UserDefaults への debounce 付き書き込み）

`BoostState` は表示用の `displayPercent` と出力用の `effectiveGain` を導出するだけの不変量に近い構造体とし、**「Slider値は保持するが OFF のときは出力を 1.0 に固定する」** という仕様を型で表現する。

```swift
struct BoostState: Equatable {
    /// 0.0 ... 4.0（linear gain）。UI / 永続化はこの値。
    var configuredGain: Double

    /// ON = configuredGain を反映、OFF = 1.0 固定
    var isEnabled: Bool

    /// オーディオ出力に乗せる実効ゲイン
    var effectiveGain: Double { isEnabled ? configuredGain : 1.0 }

    /// UI表示用（例: 100, 180, 300）。100 のとき "100%"、それ以外は "Boost NN%"。
    var displayPercent: Int { Int((configuredGain * 100).rounded()) }

    static let neutral = BoostState(configuredGain: 1.0, isEnabled: true)
}
```

主な型（予定）:
- `BoostController: ObservableObject`（**`@MainActor`**）
  - `@Published private(set) var state: BoostState`
  - `func setGain(_ gain: Double, persist: Bool = true)` … 即時AudioEngineへ反映、persist=true のとき永続化キューに積む
  - `func setEnabled(_ enabled: Bool)`
  - `func resetTo100()`
  - `func shutdown()` … AudioEngineへ gain=1.0 → stop を依頼し、保存をflush
  - コンストラクタ: `init(audioEngine: AudioEngineProtocol, settings: BoostSettings)`
- `BoostSettings` … UserDefaultsの読み書き。`load()` で必ずクランプ、`save(_:)` は debounce（後述）
- `AudioEngineProtocol` … Audio層のテスト用抽象。実体は `SystemAudioEngine`

注: 状態管理は「AppKitの `NSStatusItem` パターン」を避け、**SwiftUIの `@StateObject` / `@EnvironmentObject`** に統一します。状態同期のソース・オブ・トゥルースは `BoostController.state` 1つだけ。`BoostController.shared` のような **シングルトンは使わない**（DIに統一する）。

### 3. Audio Engine層

役割:
- システム音声のタップ（取得）
- ゲイン適用（+12.04 dB 相当までの linearGain 4.0 領域をカバー）
- （可能なら）簡易 soft clip / ピークリミッタ
- 出力デバイスへの送出

**ゲインの実装方式**（重要）:

> 現在の `spike/core-audio-tap/` v0.1 beta PoC は、下記の当初案Aではなく、ScreenCaptureKitで取得したPCMを `PCMFloatRingBuffer` に入れ、`AVAudioSourceNode` で読み出す際に `GainProcessor.applyLimitedGain` を適用している。以下は本体化時に再評価する設計候補として残す。

`AVAudioMixerNode.outputVolume`（=`AVAudioMixing.volume`）の有効範囲は **0.0〜1.0** で、**100% を超えるブーストには使えない**。400%（=+12.04 dB相当）を成立させるために、以下のいずれかで実装する。

- **案A（既定）**: `AVAudioUnitEQ` の `bands[0].gain`（dB 単位）で信号全体を持ち上げる
  - 内部の linearGain を `20 * log10(gain)` で dB に変換して `globalGain` に反映
  - 0.0 → -∞ dB（無音）、1.0 → 0 dB、4.0 → +12.04 dB
  - UI上のSlider値と `effectiveGain` はそのまま linear（0.0〜4.0）で扱い、AudioEngine側の適用時のみ dB 変換
- **案B**: カスタム `AUAudioUnit` を render callback に挿入し、PCM に直接 gain を乗算（より低レイテンシだが実装重）
- **案C**: 案Aが安定しない場合の保険として、`AVAudioEngine` 内のオフライン render block でPCMにゲインを乗じてから再生する方式

v0.1 では **案A を最優先**、必要に応じて 案B/C にフォールバックする。

**タップの実現方式**:

- **案α（既定）**: `Core Audio Tap` を使い、macOS 26上でシステム出力をプロセス内へ取り込み、案Aでゲインを掛けてからデフォルト出力へ戻す
  - ドライバ不要で「タップして加工して戻す」が可能になり得る
  - `docs/TECH_SPIKE.md` のPoCでは、この純Core Audio IOProc経路は active 実装として採用しない判断になった
- **現在のv0.1 beta PoC**: Core Audio process tap は元音のミュートに使い、音声取得は ScreenCaptureKit、出力は ring buffer + AVAudioEngine に分離する
  - v0.1 beta として手元利用できる状態まで到達
  - 追加の安全検証と配布整備が必要
- 案αが成立しなければ v0.1 は保留し、**縮退版（自プロセス音声のみ）には逃げない**（自プロセス音声だけのデモは Hazakura Boost の価値提案に合わないため）

> 重要: **macOS 26+ のみを対象**とする。Core Audio Tap の過去OS API availability は参考情報扱いとし、実装・検証・DoD は **macOS 26 で固定**する。Availability分岐で実装を複雑化させない。

詳細は [RISKS.md](./RISKS.md)、[TECH_SPIKE.md](./TECH_SPIKE.md)、[ROADMAP §v0.1](./ROADMAP.md#v01-mvp) を参照。

## データフロー

### 起動時

```
HazakuraBoostApp.init()
   └─▶ @StateObject controller = BoostController(
           audioEngine: SystemAudioEngine(),  // 未起動（stopped）
           settings: BoostSettings()
       )
   └─▶ controller.loadFromSettings()         // configuredGain / isEnabled を復元
         ├─▶ state を published 更新（AudioEngine はまだ start しない）
         └─▶ MenuBarExtra が出るが、Boost はまだ「未起動」状態

初回ポップオーバーオープン時
   └─▶ 「Start boost」を押す
         └─▶ controller.start()
               ├─▶ AudioEngine.start()       // Core Audio Tap 要求 → OSダイアログ
               ├─▶ state.isEnabled = true
               └─▶ 永続化（debounce）
```

> 起動直後に **AudioEngine.start() を呼ばない**。システムタップのOSダイアログを、**ユーザのアクションの直後**に出す。`LSUIElement = true` の常駐アプリは初回起動が静かすぎて信用されにくいので、**ポップオーバー内で意図的に説明→有効化**の導線を作る。

### ユーザーがスライダーを動かしたとき

```
BoostSliderView (onChange)
   └─▶ controller.setGain(1.8, persist: false)   // drag 中はメモリ更新のみ
         ├─▶ @Published state.configuredGain を更新
         └─▶ AudioEngine.applyGain(1.8)            // 音は即時反映

BoostSliderView (onEditingChanged: false)          // drag 終了
   └─▶ controller.setGain(1.8, persist: true)     // 永続化（debounce or 即時）
         └─▶ BoostSettings.save（300〜500ms debounce）
```

> **drag 中の UserDefaults 書き込みは行わない**。Sliderイベントは細かいため、ドラッグの終端または debounce（300〜500ms）でまとめて保存する。drag 中の音反映は即時。

### ユーザーが「100%に戻す」を押したとき

```
ResetButton
   └─▶ controller.resetTo100()
         ├─▶ state.configuredGain = 1.0
         ├─▶ AudioEngine.applyGain(1.0)
         └─▶ 永続化（即時反映でもよい）
```

### ユーザーが ON/OFF トグルを切り替えたとき

```
Toggle
   └─▶ controller.setEnabled(false)
         ├─▶ state.isEnabled = false          // configuredGain は保持
         └─▶ AudioEngine.applyGain(state.effectiveGain)   // == 1.0
```

> OFF 時は `state.configuredGain` を保持したまま、AudioEngine への適用値だけ `effectiveGain = 1.0` に切り替える。ON に戻すと `configuredGain` まで復帰する。スライダーのつまみ位置も保持。

### 終了時

```
明示的な終了（NSApp.terminate / ⌘Q / メニュー「Quit」）
   └─▶ controller.shutdown()
         ├─▶ AudioEngine.applyGain(1.0)       // まずニュートラルへ
         ├─▶ AudioEngine.stop()                // tap / aggregate device 解放
         ├─▶ 設定を flush（debounceキャンセルして即時保存）
         └─▶ App終了

スリープ前
   └─▶ NSWorkspace.willSleepNotification
         └─▶ controller.resetTo100()           // gain=1.0、configuredGain は保持
   復帰時
   └─▶ didWakeNotification
         └─▶ controller.restoreFromSettings()  // isEnabled と configuredGain を復元
```

> **方針（現実的な表現）**: **通常終了、`⌘Q`、メニュー終了、スリープ前**では `shutdown()` を必ず通す。  
> **クラッシュ / SIGKILL / Activity Monitor からの強制終了**ではアプリ側の `shutdown()` 実行は **保証しない**。  
> 代わりになる方針: AudioEngine は **OS に永続状態を残さない設計**にし、プロセス終了時に tap / aggregate device / routing が **OS 側で自動解放される**ことを PoC（[TECH_SPIKE.md](./TECH_SPIKE.md)）で確認する。  
> さらに **OS の再起動を跨いでも**極端な音量で固定されないよう、ハードウェア側のリミッタと組み合わせて検証する。

## 技術選定の理由

| 項目 | 採用 | 理由 |
|---|---|---|
| SwiftUI | ✅ | macOS 26+ ターゲットでは `MenuBarExtra` 等の宣言的APIが揃っており、状態バインドが書きやすい |
| `MenuBarExtra` | ✅ | macOS 13+。ステータスバーアイコンとポップオーバーの最小実装が揃う |
| Core Audio Tap | ✅ (試行) | ドライバ非依存でシステム音をプロセス内へ取り込める。**macOS 26+ で成立可否を PoC**（[TECH_SPIKE.md](./TECH_SPIKE.md)）|
| `AVAudioEngine` | ✅ | ゲイン/ミキシング/接続管理をSwiftから扱いやすい |
| `AVAudioUnitEQ.globalGain` | ✅ (既定) | **0%超のゲインは `AVAudioMixing.volume`（有効範囲0〜1）では不可**。dB ゲインで持ち上げる |
| カスタム `AUAudioUnit` / render callback | ✅ (任意) | 案Aで性能/品質が足りない場合の代替 |
| App Sandbox | ⚠️ 検証 | Audio Captureの可否と配布形態（App Store / Direct / Notarized DMG）の両面で要検証 |
| Hardened Runtime | ✅ | Notarize前提 |
| 仮想オーディオデバイス作成 | ❌ | 「ドライバ常設型」化を避けたい企画書の意図に反するため |
| ドライバ (HAL/DriverKit) | ❌ | 同上 |

## ディレクトリ構成（v0.1 想定）

実際のXcodeプロジェクトは未作成のため、雛形のみ示す。

```
hazakura-volume-booster/
├── hazakura-volume-booster企画書.md
├── README.md
├── docs/
│   ├── ARCHITECTURE.md   ← このファイル
│   ├── ROADMAP.md
│   ├── DEVELOPMENT.md
│   ├── RISKS.md
│   ├── PERMISSIONS.md
│   └── UI_DESIGN.md
└── hazakura-volume-booster/   ← Xcodeプロジェクト ルート
    ├── App/
    │   ├── HazakuraBoostApp.swift
    │   └── AppDelegate.swift    (NSApp終了時の安全停止用)
    ├── UI/
    │   ├── MenuBarContent.swift
    │   ├── BoostPopoverView.swift
    │   └── BoostSliderView.swift
    ├── State/
    │   ├── BoostController.swift
    │   └── BoostSettings.swift
    ├── Audio/
    │   ├── AudioEngine.swift
    │   ├── SystemTap.swift
    │   └── GainProcessor.swift
    ├── Resources/
    │   ├── Assets.xcassets
    │   ├── Info.plist
    │   └── HazakuraBoost.entitlements
    └── Tests/
        ├── BoostControllerTests.swift
        └── AudioEngineTests.swift
```

命名規則は Apple の Swift API Design Guidelines に準拠しつつ、Audio系は役割を動詞+目的で表現（`SystemTap` / `GainProcessor`）。

## 設計上の不変条件（Invariants）

コードレビューとテストの基準にするため、守るべき不変条件を明文化します。

1. **`effectiveGain = 1.0` が「ニュートラル」**: システム音は `effectiveGain == 1.0` のとき限りなく素通しに近くあること。`configuredGain == 1.0` または `isEnabled == false` のいずれか一方でも満たせば成立。
2. **AudioEngineは UIから直接触らない**: 必ず `BoostController` 経由。
3. **`shutdown()` を経由する通常終了では gain を 1.0 へ戻してから stop する**。クラッシュ/強制終了は対象外（[データフロー §終了時](#データフロー) の現実的な保証方針に従う）。
4. **状態は `BoostController.state` を単一のソース・オブ・トゥルースとする**: ビュー側で `configuredGain` / `isEnabled` を別途保持しない。表示用には `displayPercent` 導出プロパティを使う。
5. **Audio処理はバックグラウンドキュー（または専用 actor）で行う**: メインスレッドでPCMデータを触らない。
6. **権限未付与 / 起動失敗時は機能を無効化**: `effectiveGain = 1.0` へ強制フォールバックし、UIで明示。
7. **設定書き込みは debounce**: Slider drag 中の UserDefaults 連発書き込みを避ける。
8. **DI 必須**: `BoostController` は `AudioEngineProtocol` を **コンストラクタ注入**で受け取る。**シングルトンに依存しない**。

## 未解決の論点（要検証・要決定）

- [ ] **システムタップの実現方式**: [`docs/TECH_SPIKE.md`](./TECH_SPIKE.md) の PoC で成立可否を **必ず先に** 確認する。成立しなければ v0.1 は延期。
- [ ] **ゲインの実装方式**: `AVAudioUnitEQ.globalGain`（dB）を既定で採用、性能不足ならカスタム `AUAudioUnit` にフォールバック。
- [ ] **App Sandboxの有効/無効**: システム音声タップを許可するために Sandbox を切る必要があるか、切らずに最小限の entitlements で行けるかは v0.1 の PoC と並行して評価。
- [ ] **デフォルト出力デバイスの変化への追従**: v0.1 は **クラッシュ回避とリスタート促しに留め、自動追従は v0.2**（[ROADMAP §v0.1 受け入れチェックリスト / 出力デバイス](./ROADMAP.md#v01-受入チェックリスト) 参照）。通知は `AVAudioEngineConfigurationChangeNotification` または Core Audio の `AudioObjectAddPropertyListener`（`kAudioHardwarePropertyDefaultOutputDevice` / `kAudioDevicePropertyDeviceIsAlive`）で受け、`AVAudioSession.routeChangeNotification` は **macOS ネイティブでは使わない**。
- [ ] **スリープ/復帰時の挙動**: スリープ前に `resetTo100()`（configuredGain は保持）、復帰時に `restoreFromSettings()`。
- [ ] **プロセス間シングルトン性**: 同じユーザでアプリが二重起動された場合の扱い。SingleInstance ロック + 既存前面化。
- [ ] **設定ファイルフォーマット**: UserDefaults のみで十分か、JSONやplistの独自ファイルにするか。
- [ ] **ローカライズ**: 初期リリースは英語UIで先行、和訳は v0.2 以降。

これらは v0.1 着手前に、PoC または短い実装実験で回答を得る。
