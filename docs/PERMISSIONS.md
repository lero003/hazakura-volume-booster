# 権限・配布

> 関連: [企画書 §権限説明](../hazakura-amp企画書.md) / [RISKS §App Sandbox と Audio Capture](./RISKS.md) / [DEVELOPMENT](./DEVELOPMENT.md)

Hazakura Amp!は、Macの「**再生されている音**」にソフトウェアから手を入れるアプリである以上、**OSの権限モデル・配布形態・プライバシーポリシー**の扱いに慎重である必要がある。ユーザにとって「音量を上げるだけのアプリ」が、なぜかマイク権限を要求してきたら不信感を覚えるし、その逆もしかり。

このドキュメントでは、macOSのオーディオ/サンドボックス/署名/公証/Privacy Manifest/配布経路の観点を整理する。

## 全体方針

1. **システム音の加工は「音のキャプチャ」だが、録音/外部送信は一切しない**。これを公式の説明文と Privacy Manifest で明示する。
2. **マイク（インプット）は使わない**。`NSMicrophoneUsageDescription` は **書かない**。`com.apple.security.device.audio-input` entitlementも有効にしない。
3. **システム出力を `Core Audio Tap` で扱うために、`NSAudioCaptureUsageDescription` は必ず書く**。これは「マイク」ではなく「システム出力キャプチャの意図」をユーザに説明するキー。
4. **Sandbox は v0.1 では OFF**、v0.2 以降で再評価。Notarized DMG 配布は v0.2 で整備。
5. **Hardened Runtime は ON**。ライブラリ検証は v0.2 以降。
6. **Privacy Manifest** を整備し、**データ収集ゼロ**を宣言する。

---

## macOSの権限整理

### マイク vs システム出力タップ — 明確に分離する

| 用途 | 必要になり得るもの | Hazakura Amp! での扱い |
|---|---|---|
| マイク入力 | `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` | **使わない（記述しない）** |
| **システム出力タップ** | **`NSAudioCaptureUsageDescription`（Info.plist）**。Sandbox下では制約あり | **使う** |
| オーディオルーティングの操作 | `com.apple.security.device.audio`（古いentitlement） | **不要想定** |
| アクセシビリティ/入力監視（ホットキー） | `com.apple.security.accessibility` 相当のユーザ許可 | v0.2 で必要になるか **実装方式次第で回避** |

> 重要: 日本語で「音声キャプチャ」と書くと **マイク入力** を連想させやすい。Hazakura Amp!が行うのは **出力のタップ** であり、**マイクへのアクセス要求は出さない**。アプリ内の文言・README・App Store 説明でも、マイクという言葉を使わない。`NSMicrophoneUsageDescription` を **書かない** ことが、マイク不使用の最も強いシグナル。
>
> 一方、`Core Audio Tap` で他アプリのシステム出力を扱う場合、macOS は **「システム音声キャプチャ」のため Info.plist の `NSAudioCaptureUsageDescription` を要求する**（マイクとは別のキー）。これを **書かない** と Core Audio Tap 自体が起動できない。**マイク不使用の方針は維持しつつ、システム出力キャプチャの説明は明示的に書く**。

### Info.plist に書くもの（v0.1 想定）

```xml
<key>LSUIElement</key>
<true/> <!-- Dockに出さず、メニューバーのみ -->

<!-- システム出力タップのため必須。マイクではないことを明示 -->
<key>NSAudioCaptureUsageDescription</key>
<string>Hazakura Amp! uses access to system audio output to apply a local volume boost. It does not record, store, or transmit audio.</string>

<!-- マイクは使わないため書かない
<key>NSMicrophoneUsageDescription</key>
<string>...</string>
-->
```

`LSUIElement` を `true` にすることで、**プロセス名がDockに出ず、メニューバー常駐だけが唯一の手がかり**になる。これは「常駐型ユーティリティ」としてのUI上の基本姿勢。

### Entitlements（v0.1: Sandbox OFF想定）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- v0.1: Sandbox OFF -->
    <!-- v0.2 以降で再評価 -->

    <!-- Hardened Runtime -->
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <false/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <false/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key>
    <false/>
</dict>
</plist>
```

> v0.1ではSandboxを切る。**これは意図的な選択**。詳細は [RISKS §App Sandbox](./RISKS.md) 参照。

> **「Hazakura Amp! uses access to system audio output to apply a local volume boost.」** という英文は、ユーザに「出力を使っている」「録音しない」を同時に伝える最短表現。和訳はアプリ内文言の節を参照。

### 関連するApple公式の指針

- `NSAudioCaptureUsageDescription`: Core Audio Tap 等で **システム出力をキャプチャ** するアプリ向けに、macOS が説明する目的を要求する Info.plist キー
- `NSMicrophoneUsageDescription`: **マイク入力** に使われる（Hazakura Amp! では無関係）
- `com.apple.security.device.audio-input` entitlement: **内蔵マイク録音や Core Audio の入力アクセス** 用。**システム出力タップ** とは別物。Hazakura Amp! では有効にしない

---

## App Sandbox を切る理由と影響（v0.1）

### 切る理由

- システム出力タップを **`Core Audio Tap` 経由で行う**にあたり、Sandbox 化によって必要な API が制限される可能性が高い
- v0.1は**動作確認とDoD達成**が最優先であり、配布前提が薄い
- Sandboxを切ってNotarize を通すこと自体は可能（Developer ID 配布では一般的）

### 影響

- Mac App Store への提出は不可
- 一部ユーザが「Sandboxなしで動作している」と警戒する可能性がある
- 透明性を担保するため、README・製品ページに**「Sandbox非対応」と「音声処理スコープ」**を明記する

### v0.2 での再評価

v0.2で以下を判断:

- App Store 配布を目指すか（目指さない可能性が高い）
- 目指す場合、Sandbox + 必要最小限の entitlements でシステムタップが可能か PoC
- 目指さない場合、Sandbox OFF のまま Developer ID 配布前提を継続

---

## Hardened Runtime / Notarization

### Hardened Runtime

- v0.1から **必ず ON**
- `Allow Execution of JIT-compiled Code` / `Allow Unsigned Executable Memory` は **false**
- `Library Validation` を有効化（自作dylibを読み込まない）

### Notarization（v0.2 で導入）

v0.1のDoDには含めない。v0.2 で:

1. Developer ID アプリ署名
2. `notarytool` での公証送信
3. Staple チケットの付与
4. Gatekeeper で開けることをローカル確認

```bash
# ビルド・エクスポート・公証
xcodebuild -exportArchive -archivePath build/HazakuraAmp.xcarchive \
  -exportPath build/ -exportOptionsPlist ExportOptions.plist

xcrun notarytool submit build/HazakuraAmp.dmg \
  --apple-id <apple-id> --team-id <team-id> \
  --password <app-specific-password> --wait

xcrun stapler staple build/HazakuraAmp.dmg
```

### Gatekeeper で「開けない」と言われた場合

- Staple 漏れ → `xcrun stapler staple` 再実行
- 公証 reject → `xcrun notarytool log <submission-id>` で理由確認
- entitlements 違反 → 該当 entitlement を削除/変更

---

## Privacy Manifest (`PrivacyInfo.xcprivacy`)

macOS 14以降、App Store 配布ではほぼ必須。Hazakura Amp!は**データ収集ゼロ**を宣言する。

### 配置

```
hazakura-amp/
└── hazakura-amp/
    └── Resources/
        └── PrivacyInfo.xcprivacy
```

### 想定内容（v0.2 で確定）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <!-- 使用するAPIに応じて宣言。例:
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array><string>CA92.1</string></array>
        </dict>
        -->
    </array>
</dict>
</plist>
```

> 重要: **`NSPrivacyCollectedDataTypes` は空配列**を維持する。ユーザの音声データや設定値を一切「収集」していないことを宣言する。タップした音声をアプリ内で加工して出力しているだけで、どこにも送信しない。

---

## アプリ内文言（プライバシー説明）

企画書 §権限説明 の方針を、UI 上でユーザにどう提示するかを具体化する。

### 初回起動時のダイアログ（任意、v0.1は出さない・v0.2で検討）

```
Hazakura Amp! は、Macで再生中の音声をメニューバーから持ち上げるためのアプリです。

このアプリは、Macで再生されている音声を一時的に処理し、音量を調整するために
音声出力へのアクセスを使用します。録音や外部送信は一切行いません。
```

### ポップオーバー内の「？」/Aboutメニュー

```
Hazakura Amp!

外部スピーカーのつまみを触らず、Macの音量をソフトウェアから持ち上げます。

- システム音を一時的に加工して音量ブーストします
- マイクは使用しません
- 録音・送信は一切行いません
- ドライバをインストールしません

Hazakura Amp!は小さな常駐型ユーティリティです。
```

### README / 製品ページ

```
Hazakura Amp! は、Macで再生中の音声をメニューバーから一時的に大きくする
ための軽量ユーティリティです。ドライバをインストールせず、録音や外部送信を
行いません。マイクへのアクセスは要求しません。
```

---

## 配布経路

### v0.1（ローカルビルド）

- 開発者本人＋αがローカルビルドで使う
- 配布はしない
- READMEにインストール手順は不要

### v0.2（Developer ID 配布 / Notarized DMG）

- 公式サイトまたは GitHub Releases で DMG を配布
- App Store には出さない方針（Sandbox 起因 + 規模の小ささ）
- アンインストールは「`Applications` から `Hazakura Amp!.app` を削除」するだけのシンプル運用
- アンインストール時に `~/Library/Application Support/HazakuraAmp/` 等を作成した場合はそれも削除する手順を README に記載

### v0.2以降で再評価

- App Store 配布を本気で目指すか
- Homebrew Cask での配布
- Sparkle 等の自動アップデート機構
- Mac App Store 外の第三者ストア（Setapp 等）

---

## 関連リスク・依存

- [RISKS §App Sandbox と Audio Capture](./RISKS.md) — Sandbox を切る/切らない判断の根拠
- [RISKS §macOS 26+ への依存](./RISKS.md) — macOS 26+ に限定する理由
- [DEVELOPMENT §リリース前段](./DEVELOPMENT.md) — 署名・公証のコマンド例

---

## チェックリスト（v0.1コミット前）

- [ ] `Info.plist` に `LSUIElement = true`
- [ ] `Info.plist` に **`NSAudioCaptureUsageDescription`** を**必ず書く**（Core Audio Tap を起動するために必要）
- [ ] `NSMicrophoneUsageDescription` を**書かない**（書くと逆にマイク使用と疑念を持たれる）
- [ ] Entitlementsに **`com.apple.security.device.audio-input` を含めない**（マイク関連）
- [ ] Entitlementsで Hardened Runtime の各項目を確認
- [ ] Sandbox は OFF（`com.apple.security.app-sandbox` を含めない）
- [ ] READMEに「マイク不使用・録音/送信なし」を明記
- [ ] ポップオーバーの About/？ に同じ説明を表示
- [ ] Privacy Manifest は v0.2 で導入、v0.1 はプレースホルダのみ
