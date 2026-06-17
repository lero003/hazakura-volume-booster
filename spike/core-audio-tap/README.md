# Core Audio Tap PoC

> 親: `hazakura-volume-booster/` ルート  
> 関連: [`docs/TECH_SPIKE.md`](../../docs/TECH_SPIKE.md) / [`docs/ARCHITECTURE.md`](../../docs/ARCHITECTURE.md) / [`docs/RISKS.md`](../../docs/RISKS.md) / [`docs/PERMISSIONS.md`](../../docs/PERMISSIONS.md)

Hazakura Boost v0.1 beta の現在の実体になっている技術検証（PoC）。

このPoCは、当初想定した「Core Audio Tap + aggregate device + IO proc」の純Core Audio経路ではなく、次の折衷構成で動いている。

- **Core Audio process tap**: 他プロセスの元音を `.muted` で止め、二重再生を防ぐ
- **ScreenCaptureKit audio**: システム音声をアプリ内へ取り込む
- **PCMFloatRingBuffer**: capture側とrender側の時間差を吸収する
- **AVAudioEngine / AVAudioSourceNode**: ring bufferを読み、ゲイン処理後の音を出力する

つまり、現在のPoCは「Core Audio Tapで直接IOProcを駆動する」実装ではない。旧経路のコードと記録は、失敗した技術検証として残している。

## 経緯（なぜこの構成か）

最初の実装は `AVAudioEngine.inputNode` を **tap のみを内包する aggregate device** に切り替える方針だった。結果、起動時に **`kAudioUnitErr_FailedInitialization` (-10875)** で失敗。

その後 `AudioDeviceCreateIOProcID` を試したが IO proc が呼ばれず、`HALOutput AudioUnit` への移行も `CurrentDevice` で失敗した。

現在は、Core Audio process tap を **元音ミュート用**に使い、音声取得は ScreenCaptureKit、出力は AVAudioEngine に分離している。これにより、v0.1 beta として必要な「音を持ち上げる」「二重再生を避ける」「Dev診断で状態を見る」は成立している。

## このPoCが検証すること

- **macOS 26 上でシステム出力相当の音声をアプリ内へ取り込める**こと
- 取り込んだ PCM を **ring buffer + AVAudioSourceNode** 経由で線形ゲインし、default output へ戻せること
- **元音と加工後音が二重に鳴らない**こと（エコー防止: `muteBehavior = .muted`）
- 0% / 100% / 200% / 400% の差が**聴感で分かる**こと
- 100% 復帰が**1秒以内**に効くこと
- アプリ終了で **Core Audio process tap / aggregate device が解放される**こと

## データフロー

```
[他アプリの音声]
   ├─ Core Audio process tap (muteBehavior=.muted → 元音を止める)
   └─ ScreenCaptureKit audio capture
        ↓
     PCMFloatRingBuffer
        ↓
     AVAudioSourceNode (`GainProcessor.applyLimitedGain`)
        ↓
     AVAudioEngine main mixer
        ↓
[スピーカー / ヘッドホン]
```

`muteBehavior = .muted` のおかげで、tap対象の元音が直接出にくくなる。自アプリのAVAudioEngine出力はtap対象から除外し、加工後音だけを聴こえる経路にする。

## ディレクトリ構成

```
spike/core-audio-tap/
├── README.md                          (このファイル)
├── project.yml                        (xcodegen 用プロジェクト定義)
├── CoreAudioTapPoC.xcodeproj/         (xcodegen で生成)
├── CoreAudioTapPoC/
│   ├── CoreAudioTapPoCApp.swift       (@main, MenuBarExtra)
│   ├── CoreAudioTapPoC-Bridging-Header.h   (旧IOProc実験用。active経路では未使用)
│   ├── ContentView.swift              (SwiftUI: Slider / Start-Stop / Quit / Dev)
│   ├── Audio/
│   │   ├── BoostAudioPipeline.swift   (active: ScreenCaptureKit + ring buffer + AVAudioEngine)
│   │   ├── ScreenCaptureAudioSource.swift
│   │   ├── PCMFloatRingBuffer.swift
│   │   ├── SystemTap.swift            (process tap + aggregate device。元音ミュート用)
│   │   ├── PoCAudioEngine.swift       (Swift 側オーケストレータ)
│   │   ├── GainProcessor.swift        (linear gain + soft limiter)
│   │   └── AudioIOProc.h/.mm          (旧IOProc実験。active経路では未使用)
│   └── Resources/
│       ├── Info.plist                 (NSAudioCaptureUsageDescription 入り, LSUIElement=true)
│       └── CoreAudioTapPoC.entitlements (Hardened Runtime ON, Sandbox OFF)
└── CoreAudioTapPoCTests/
    └── GainProcessorTests.swift       (linear→dB 変換の単体テスト)
```

## 前提条件

- macOS 26.0 以降
- Xcode 26 以降
- Homebrew（xcodegen インストール用）

```bash
brew install xcodegen
```

## ビルド・テスト

```bash
cd spike/core-audio-tap

# プロジェクト生成（project.yml から）
xcodegen generate

# クリーンビルド
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  clean build

# Developer ID 署名の Release 候補ビルド（公証は別工程）
./scripts/build_release_candidate.sh

# ユニットテスト
xcodebuild \
  -project CoreAudioTapPoC.xcodeproj \
  -scheme CoreAudioTapPoC \
  -destination 'platform=macOS' \
  -derivedDataPath build \
  test
```

## 起動手順

```bash
open build/Build/Products/Debug/CoreAudioTapPoC.app
```

普段の開発と単体テストは `Debug` / `Apple Development` 署名を使う。GitHub Release 前の手元確認は `Release` / `Developer ID Application` 署名の `build/Build/Products/Release/CoreAudioTapPoC.app` を使う。外部配布する場合は、この Release 候補に対して notarization / staple を別工程で通してから配布する。

初回起動時に **`NSAudioCaptureUsageDescription` の OS ダイアログ**が出るので「許可」する。  
以降はメニューバーにアイコンが表示されるので、クリックしてポップオーバーを開き、「開始」を押す。操作UIは 0%〜400% スライダー、開始/停止、終了、Dev 診断に絞っている。Dev モードをONにすると capture buffer / render call / output gain / available frames / underrun / dropped frames / health / event log を確認できる。`Copy` で app version / build / status / health / recent events を含む診断スナップショットをクリップボードへコピーできる。

Hazakura Boost はシステム音をローカル処理して音量を持ち上げる。録音・保存・外部送信はしない。マイク権限も要求しない。

## 検証チェックリスト

現在の v0.1 beta PoC で重点的に確認する手動チェック:

```
[ ] YouTube 音声を取得できた（Start 直後から聴こえる）
[ ] 0% で音量を絞れる
[ ] 100%（素通し）で原音と同等に聴こえる
[ ] 200% / 400% で音量が明確に上がる
[ ] 元音と加工後音が二重に鳴らない
[ ] スライダーで 100% に戻せる
[ ] アプリ終了で通常出力に戻る
[ ] ⌘Q / Quit で gain=1.0 → stop の安全停止ログが出る
[ ] スリープ前に 100% へ戻り、復帰後は自動復元または手動 Start で保存値へ戻る
[ ] 強制終了後に OS 側に tap/routing が残らない
[ ] 権限拒否でクラッシュしない（Setting > Privacy で拒否して再起動）
[ ] マイク権限ダイアログが出ない
[ ] レイテンシが許容範囲
[ ] ブツ音・ノイズが常用不能なほど出ない
```

### 2026-06-17 手動観測メモ

- 10分程度の連続再生では、聴感上のノイズ・無音化・常用不能なブツ音は確認されていない。
- 5〜10分再生時の underrun はおおむね 25〜30 程度、dropped frames は 0。現行 health 判定では低頻度 underrun として `Watch` 扱いにする。
- スリープ復帰直後は ScreenCaptureKit が display/window 不在を返す場合がある。この場合は完全自動 Start を追わず、`Start required after wake` として手動 Start 待ちにする。
- 復帰後の手動 Start では、再度の権限ダイアログなしに音源ブーストへ戻れることを確認済み。
- Activity Monitor 強制終了後の `system_profiler SPAudioDataType | grep -i 'hbb-poc'` は、まだこのメモでは未確認。

### 強制終了の検証手順

```bash
# アプリ稼働中に Activity Monitor を開いて CoreAudioTapPoC を強制終了
# その直後に、tap / aggregate device が残っていないか確認:
system_profiler SPAudioDataType | grep -i 'hbb-poc'

# 何も出なければ OK（OS 側が完全解放している）
# もし出てきたら、Tech Spike 撤退ラインに到達。v0.1 延期。
```

## 状態確認（ログ）

`Console.app` で以下をフィルタすると便利:

- subsystem: `dev.keisetsu.hazakura-volume-booster.poc`
- category: `SystemTap` / `PoCAudioEngine`

## 撤退ライン

`docs/TECH_SPIKE.md §撤退ライン` と一致:

- 「出力をタップして戻す」ラウンドトリップが成立しない（IO proc 登録が失敗する等）
- 200ms を超える体感遅延が避けられない
- 強制終了で OS 側に tap/routing が残る
- エコー（原音と加工後音の二重再生）が避けられない

**いずれか1つでも成立しなければ v0.1 の実装には進まない**。  
縮退案（自プロセス音声のみ）は技術デモ扱いとし、MVP としては採用しない。

## ファイル対応

| ファイル | 役割 | 対応する設計ドキュメント |
|---|---|---|
| `BoostAudioPipeline.swift` | active 実装。ScreenCaptureKit capture、ring buffer、AVAudioEngine出力を接続 | [ARCHITECTURE §3 Audio Engine層](../../docs/ARCHITECTURE.md) / [RISKS §3 レイテンシ](../../docs/RISKS.md) |
| `ScreenCaptureAudioSource.swift` | ScreenCaptureKit audio buffer を ring buffer へ書き込む | [TECH_SPIKE](../../docs/TECH_SPIKE.md) |
| `PCMFloatRingBuffer.swift` | capture/render間のバッファ。ゲインと簡易リミッタを適用 | [RISKS §3 レイテンシ](../../docs/RISKS.md) / [RISKS §4 音割れ](../../docs/RISKS.md) |
| `SystemTap.swift` | CATapDescription + AggregateDevice。active経路では主に元音ミュート用 | [ARCHITECTURE §3](../../docs/ARCHITECTURE.md) / [RISKS §1 Core Audio Tap の実現性](../../docs/RISKS.md) |
| `PoCAudioEngine.swift` | Swift 側オーケストレータ、UI バインド、start/stop と gain 状態管理 | [ARCHITECTURE §データフロー](../../docs/ARCHITECTURE.md) |
| `GainProcessor.swift` | linear→dB の数式ヘルパと soft limiter | [ARCHITECTURE §3 ゲインの実装方式](../../docs/ARCHITECTURE.md) |
| `AudioIOProc.h` / `.mm` | 旧IOProc実験の残骸。active経路では未使用 | [JOURNAL](./JOURNAL.md) |
| `Info.plist` | NSAudioCaptureUsageDescription、LSUIElement | [PERMISSIONS §Info.plist](../../docs/PERMISSIONS.md) |
| `*.entitlements` | Hardened Runtime、App Sandbox OFF | [PERMISSIONS §Entitlements](../../docs/PERMISSIONS.md) |
| `CoreAudioTapPoC-Bridging-Header.h` | 旧IOProc実験用。active経路では未使用 | — |
| `CoreAudioTapPoCApp.swift` | `MenuBarExtra` 常駐エントリポイント | [ARCHITECTURE §1 UI Layer](../../docs/ARCHITECTURE.md) |

## 次のステップ

v0.1 beta PoC から次に進む場合:

1. 強制終了・スリープ復帰・出力デバイス変更時の挙動を確認する
2. Dev 診断の health / underrun / dropped frames / available frames を見ながら10分以上の連続再生を確認する。dropped frames は Warning、低頻度 underrun は Watch として聴感と合わせて判断する
3. `docs/TECH_SPIKE.md` の結果欄を更新する
4. この `spike/core-audio-tap/` の実装を本体プロジェクトへ昇格するか判断する
5. Developer ID署名 / Notarized DMG / Privacy Manifest を整備する
