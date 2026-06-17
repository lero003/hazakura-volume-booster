# リスクと既知の落とし穴

> 関連: [企画書 §音割れ / §やらないこと](../hazakura-amp企画書.md) / [ARCHITECTURE](./ARCHITECTURE.md) / [PERMISSIONS](./PERMISSIONS.md) / [ROADMAP](./ROADMAP.md)

Hazakura Amp!は、表面上は「スライダー1本のシンプルアプリ」に見えるが、根幹には**Macのシステムオーディオをリアルタイムに加工する**という落とし穴だらけの領域がある。このドキュメントでは、実装に踏み出す前に対処法と撤退ラインを決めておきたいリスクを列挙する。

リスクは以下のレーティングで評価する。

| 区分 | 意味 |
|---|---|
| 🔴 **High** | 実装可否そのものに関わる。撤退ラインの判断材料 |
| 🟠 **Medium** | 品質・体験を大きく毀損し得る。実装時に必ず検証 |
| 🟡 **Low** | 把握しておけば回避できる。ドキュメント化と周知で対処 |

---

## 1. 🔴 Core Audio Tap の実現性

**問題**: システム出力音をプロセス内へ取り込む方法は、macOS 14以降で `Core Audio Tap` が使えるようになった。**ただし v0.1 は macOS 26+ のみを対象**とし、過去の API availability は参考扱いとする。

- macOS 26 上で「システム出力をタップ → 加工 → 出力へ戻す」ラウンドトリップが成立するかは、**実装してみないとわからない**部分が多い
- サンドボックス下での挙動に制限がある
- 必要な Info.plist キー（`NSAudioCaptureUsageDescription`）を書かないと Core Audio Tap 自体が起動しない

**対策**:
- v0.1 着手前に **必ず [`docs/TECH_SPIKE.md`](./TECH_SPIKE.md) の PoC を実施**し、ラウンドトリップ成立可否を確定させる
- PoC の Done 条件を満たさない限り v0.1 の実装に **入らない**

**撤退ライン**:
- PoC で「出力をタップして戻す」経路が macOS 26 上で実現できないことが判明した場合 → **v0.1 全体を保留**する
- 縮退案として「**自プロセスが再生する音声のみ**にブースト」もあるが、これは **Hazakura Amp! の価値提案（YouTubeやシステム音を持ち上げる）を毀損する**ため MVP ではなく **技術デモ扱い**とし、製品リリースとしては採用しない
- v0.1 を延期し、ScreenCaptureKit の音声取り込みや別プロダクト（Hazakura Mixer 等）として再検討する

---

## 2. 🔴 App Sandbox と Audio Capture の相性

**問題**: App Store 配布を視野に入れると App Sandbox を有効にしたいが、

- システム出力を「キャプチャ」する行為が Sandbox 的に許可されるかは、entitlements の組み合わせに依存
- `com.apple.security.device.audio-input` は **入力（マイク）** 用であり、**システム出力タップ** には別のentitlementsが必要/不要な可能性がある
- 一方、Developer ID / Direct 配布であれば Sandbox 無しでもGatekeeper/Notarizeは通せるが、Appleの最近のガイドラインは Sandbox を事実上推奨

**対策**:
- v0.1は**App Sandbox OFF**で実装し、動作確認を優先
- 配布方針（App Store vs Direct DMG）を v0.2 で決定し、それに合わせて Sandbox の有効/無効を切り替える
- 詳細は [PERMISSIONS §App Sandbox](./PERMISSIONS.md) を参照

**撤退ライン**:
- App Store 配布を諦めてもよい（Hazakura Amp!は小さなユーティリティで、App Store審査のコストメリットが小さい可能性がある）

---

## 3. 🟠 レイテンシと audio glitch

**問題**: スライダー操作時にゲイン変更が音に反映されるまで数百msの遅延があると、体感品質が大きく下がる。逆に応答が速すぎると、急な音量ブーストで耳にダメージを与え得る。

**対策**:
- ゲインはスレッドセーフに更新する。**`AVAudioMixerNode.outputVolume`（=`AVAudioMixing.volume`）は有効範囲 0.0〜1.0 であり 100% 超のブーストには使えない**。400% (=+12.04 dB 相当) を成立させるために **`AVAudioUnitEQ` の `globalGain`（dB 単位）** を既定で採用する
  - 内部の linearGain（0.0〜4.0）を `20 * log10(gain)` で dB へ変換
  - 案A（AVAudioUnitEQ.globalGain）で性能/品質が足りなければ、**カスタム `AUAudioUnit` / render callback 内 PCM ゲイン**にフォールバック
- 急激なゲイン変化には**短いランプ（約50ms程度）**を掛けて耳への衝撃をやわらげる
- リミッタはv0.1では簡易（soft clip 程度）に留め、企画書「高度な音割れ防止はやらない」に従う

**撤退ライン**:
- 200msを超える体感遅延が避けられない場合、スライダー値の更新戦略を「操作中は内部値だけ更新し、ボタンを離した瞬間にゲイン反映」のように見直す

---

## 4. 🟠 音割れ（クリッピング）

**問題**: 企画書に記載の通り、400%ブーストは音割れ前提。ゲイン後の信号が `[-1.0, 1.0]` を超えると普通に歪む。

**対策**:
- ゲイン後に簡易的な**ピークノーマライゼーション**または**タナーリミッタ**を通す（v0.1で簡易実装）
- ただし「完全な音割れ防止」は企画書で明示的にやらないことにしている
- 過大入力時にUIで「⚠️ 音量が大きすぎます」表示する程度は v0.2で検討

**撤退ライン**:
- ここはあえて撤退しない。**音割れを許容する**ことが本プロダクトの立場

---

## 5. 🟠 終了時の音量リーク

**問題**: アプリが落ちたりユーザーが `⌘Q` で終了したときに、**最後に設定されたゲインが出力に固着**してしまうと、終了後に過大音量が出続けてしまう。これは Hazakura Amp! が直接的に引き起こし得る最悪の不具合。

**対策**（**現実的な保証範囲**）:
- **保証する範囲**: 明示的な終了（`NSApp.terminate` / `⌘Q` / メニュー「Quit」）、スリープ前、シャットダウン
  - これらの経路では `BoostController.shutdown()` を **必ず通す** 設計
  - `shutdown()` の中で:
    1. ゲインを `1.0` へ
    2. Audio Engine を `stop()`
    3. タップ/aggregate device の解放
    4. 設定を flush（debounceキャンセルして即時保存）
- **保証しない範囲**: クラッシュ / `SIGKILL` / Activity Monitor からの強制終了
  - アプリ側の `shutdown()` 実行は **保証できない**
  - 代わりに **AudioEngine を「OS に永続状態を残さない」設計**にする
  - プロセス終了時に tap / aggregate device / routing が **OS 側で自動解放される**ことを [`docs/TECH_SPIKE.md`](./TECH_SPIKE.md) の PoC で実機検証する
- 単体テストで「`shutdown()` 後、内部ゲイン状態が 1.0 である」ことを保証
- テスト不可能な強制終了経路は、PocC で「強制終了 → 再起動しても極端音量が出ない」ことをブラックボックステストで代替する

**撤退ライン**:
- 撤退不可。**v0.1 の DoD に直結**。PoC 段階で「強制終了後に極端音量が出る」ことが判明したら OS 再起動 or ハードウェアリミッタで被害を局限できる代替案（フォールバック）を v0.1 に追加する。

> 注: ROADMAP の v0.1 DoD に「Dockの強制終了」と書いていたが、`LSUIElement = true` で Dock に出ない本アプリでは「Activity Monitor からの強制終了」が正しい表現。表現を修正する（[ROADMAP.md](./ROADMAP.md) 参照）。

---

## 6. 🟠 スリープ/復帰とオーディオルーティング

**問題**:
- スリープするとオーディオルーティングが解除され、復帰時に再確立が必要
- 外部スピーカーがスリープで切断→復帰で別デバイスに切り替わる場合、想定外の音量で再生される可能性がある
- 出力デバイスの抜き差し（USB DACの着脱など）でオーディオルーティングが切り替わる

**対策**:
- `NSWorkspace.willSleepNotification` で `resetTo100()`（configuredGain は保持）
- `didWakeNotification` で保存済み設定を `restoreFromSettings()`
- **macOS ネイティブでは `AVAudioSession.routeChangeNotification` を使わない**。`AVAudioSession` は iOS / iPadOS / Mac Catalyst 寄りの抽象で、本アプリのような `MenuBarExtra` ベースの macOS ネイティブアプリの一次選択ではない
- 出力デバイス変更検知は **Core Audio の `AudioObject` property listener** を使う:
  - `kAudioHardwarePropertyDefaultOutputDevice` … デフォルト出力変更
  - `kAudioDevicePropertyDeviceIsAlive` … デバイスの生存
  - `kAudioDevicePropertyStreamConfiguration` / `kAudioDevicePropertyNominalSampleRate` … ストリーム構成の変化
  - `AVAudioEngineConfigurationChangeNotification` … engine 内部の構成変更通知（補助）
- v0.1 では **自動追従はせず、クラッシュ回避と UI 上の通知に留める**（[ROADMAP §v0.1 受け入れチェックリスト / 出力デバイス](./ROADMAP.md#v01-受入チェックリスト) 参照）。自動追従は v0.2

---

## 7. 🟡 起動/常駐プロセスの重複

**問題**: 同じユーザでアプリが二重起動されたとき、Audio Engine が2つ走り、出力が二重になる/互いに干渉する。

**対策**:
- 起動時に `NSApplication.shared.activate(ignoringOtherApps: true)` で既存を前面に出す
- または `SingleInstance` 系のロック（`flock(2)` / `NSLock` ファイル）で多重起動を拒否
- ログには「second instance launched and exited」を残す

---

## 8. 🟡 App Sandbox がないことによる批判/困惑

**問題**: Sandbox を切ると一部ユーザやレビューで「セキュリティ的に不安」と言われ得る。

**対策**:
- 企画書「権限説明」の方針で、**音声キャプチャの意図を明示**
- `PrivacyInfo.xcprivacy` を整備し、収集しない情報を宣言
- README/製品ページに「録音や外部送信は行わない」と明示
- 詳細は [PERMISSIONS §プライバシー説明](./PERMISSIONS.md) を参照

---

## 9. 🟡 macOS 26+ への依存

**問題**: macOS 26以降しかターゲットにしないことで、ユーザーベースが狭まる。古いMacで動かしたいユーザからの問い合わせが来る。

**対策**:
- 企画書通り、macOS 26+ に集中
- READMEの冒頭に「動作環境: macOS 26以降」を明示
- 古いmacOS対応が必要になった場合は v0.x 後期で再評価（v0.1〜v0.3では対応しない）

---

## 10. 🟡 配布経路の未確定

**問題**: v0.1でDeveloper ID署名/Notarize までやるかどうかは未確定。**Gatekeeperに弾かれるとユーザは導入できない**。

**対策**:
- v0.1はローカルビルドで使い、配布しない方針
- v0.2でDeveloper ID署名＋Notarize DMG を整備
- App Store 配布は別議論（[PERMISSIONS §配布経路](./PERMISSIONS.md) 参照）

---

## 11. 🟡 UserDefaults での設定永続化とマイグレーション

**問題**: UserDefaultsで `boostPercent` を持つと、不正値（NaN, 負数, 8.0など）が入ったときに起動直後から異常なゲインで再生される可能性。

**対策**:
- `BoostSettings.load()` で必ずクランプ（0.0〜4.0）
- 不正なら既定値（1.0）にフォールバック
- マイグレーション戦略をv0.2で定義（スキーマ versioning）

---

## 12. 🟡 アイコン・状態の視認性

**問題**: メニューバーにごちゃっと他の常駐アプリがいると、Hazakura Amp! のアイコンが埋もれて、**「いまONなのかOFFなのか、Boostが効いているのか」**が一目でわからない。

**対策**:
- 状態に応じてアイコンを切り替える（例: 100%=モノクロ、>100%=カラー）
- アイコンは SF Symbols を基本としつつ、独自デザインも v0.2 で検討
- 詳細は [UI_DESIGN.md](./UI_DESIGN.md) を参照

---

## リスク一覧（俯瞰）

| # | レーティング | リスク | 撤退ライン |
|---|---|---|---|
| 1 | 🔴 | Core Audio Tap の実現性 | **成立しなければ v0.1 全体を保留**。自プロセス音声のみへの縮退は MVP として採用しない |
| 2 | 🔴 | App Sandbox と Audio Capture | App Store を諦めても可 |
| 3 | 🟠 | レイテンシと audio glitch | 体感200ms超なら更新方式見直し（または AudioUnit 内部処理に切り替え）|
| 4 | 🟠 | 音割れ（クリッピング） | 撤退しない（割り切り） |
| 5 | 🟠 | 終了時の音量リーク | **撤退不可（DoD直結）**。通常終了は `shutdown()` で保証、強制終了は PoC で「OS が tap/routing を自動解放すること」を実機検証 |
| 6 | 🟠 | スリープ/復帰とオーディオルーティング | 通知は **Core Audio property listener + `NSWorkspace`** で吸収。`AVAudioSession` は使わない |
| 7 | 🟡 | 二重起動 | SingleInstance ロック |
| 8 | 🟡 | Sandbox 未設定への批判 | 説明文・Privacy Manifestで緩和 |
| 9 | 🟡 | macOS 26+ 依存 | READMEで明示 |
| 10 | 🟡 | 配布経路未確定 | v0.2で Developer ID 署名 |
| 11 | 🟡 | UserDefaults 不正値 | クランプと既定値フォールバック |
| 12 | 🟡 | アイコン視認性 | 状態別アイコン |
