# Core Audio Tap PoC（Technical Spike）

> 関連: [ARCHITECTURE §Audio Engine層](./ARCHITECTURE.md) / [RISKS §1 🔴 Core Audio Tap の実現性](./RISKS.md) / [ROADMAP §v0.1 MVP](./ROADMAP.md#v01-mvp) / [PERMISSIONS §Info.plist](./PERMISSIONS.md)

このドキュメントは、**Hazakura Boost v0.1 の実装に着手する前に必ず通す技術検証（PoC）**のゴール・Done 条件・撤退ラインを定義する。

## 現在の判定（2026-06-17）

当初想定した **Core Audio Tap + aggregate device + IO proc** のラウンドトリップ経路は、IO proc が駆動しない／HALOutput AudioUnit が aggregate device を受け付けないため、v0.1 beta の active 経路としては採用しない。

現在の v0.1 beta PoC は、次の折衷構成で動作している。

- Core Audio process tap: 元音を `.muted` にして二重再生を抑える
- ScreenCaptureKit: システム音声をアプリ内へ取り込む
- PCMFloatRingBuffer: capture/render間の時間差を吸収する
- AVAudioSourceNode: ring bufferを読み、ゲイン処理後の音を出力する

ユーザーの手元確認では、音量ブースト、二重再生の抑制、音質劣化の軽減は v0.1 beta として許容範囲に入った。10分連続再生とスリープ復帰後の手動Startも実用範囲に入っている。残る主な確認は、実再生中のActivity Monitor強制終了、出力デバイス変更、配布用公証である。

## ゴール

> **macOS 26 上で、システム出力を Core Audio Tap で取得し、+12.04 dB 相当（linearGain 4.0）のゲインを掛けて、デフォルト出力へ加工後の信号を戻せる**ことを確認する。

これに加えて、**強制終了時に OS 側が tap / aggregate device / routing を自動解放し、極端音量で固着しない**ことを実機で確認する。

## スコープ

- 対象 OS: **macOS 26.0 以降** のみ
- 対象アーキテクチャ: Apple Silicon / Intel 両方で macOS 26 が動く範囲
- 検証環境: 1台のクリーンな macOS 26 機（外部スピーカーまたは内蔵出力）
- 検証時間: 1 スプリント相当（数日）で Done/Not-Done を判定

## 成功条件（Done）

すべて満たすこと:

### 機能

- [ ] **タップ**: YouTube / Apple Music / Safari などのシステム再生音声を **他アプリの音声も含めて** プロセス内へ取り込める
- [ ] **ゲイン**: 取り込んだ PCM に `linearGain = 1.0`（= 0 dB, 素通し）を掛けたとき、**原音と同等に聴こえる**（聴感で差が無いこと）
- [ ] **ゲイン**: 取り込んだ PCM に `linearGain = 0.0` を掛けたとき、**音量を絞れる**（無音化は正常）
- [ ] **ゲイン**: 取り込んだ PCM に `linearGain = 2.0`（= +6.02 dB）を掛けたとき、**音量が明確に上がる**（聴感で分かる）
- [ ] **ゲイン**: 取り込んだ PCM に `linearGain = 4.0`（= +12.04 dB）を掛けたとき、**さらに明確に上がる**（聴感で分かる）
- [ ] **ラウンドトリップ**: 加工後 PCM を **デフォルト出力へ戻したとき、原音と加工後音が二重に鳴らない**（エコーやダブル再生が起きない）
- [ ] **ニュートラル復帰**: Slider を 1.0 へ戻すと、**1 秒以内に** 出力音がニュートラルへ戻る
- [ ] **アプリ終了**: アプリ終了時にゲイン 1.0 → stop のシーケンスを経て、**通常出力へ戻る**
- [ ] **スリープ/復帰**: スリープ前にゲイン 1.0、復帰後に保存値へ復元する

### 権限

- [ ] **Info.plist に `NSAudioCaptureUsageDescription` を書いた状態で、初回タップ時に OS ダイアログが出る**
- [ ] **許可後、追加ダイアログ無しで動作する**
- [ ] **拒否時にクラッシュせず、`effectiveGain = 1.0` にフォールバック**して通常再生だけが続く
- [ ] **マイク（`NSMicrophoneUsageDescription`）への要求は出ない**

### 強制終了の安全側

- [ ] Activity Monitor から "Force Quit" で終了した直後、**tap / aggregate device / routing が OS 側にゴミとして残らない**（`./spike/core-audio-tap/scripts/verify_shutdown_safety.sh` で確認）
- [ ] 強制終了直後の音量レベルが、**最後のゲイン値で固着していない**（= 通常音量 = 1.0 倍に戻る）

### レイテンシ・品質（v0.1 では定量基準は緩く）

- [ ] スライダー操作から体感で **200ms 以内**に音量変化が反映される（厳密な A/B 測定は v0.1 では不要）
- [ ] 加工音の明らかな劣化（金属的な歪み、常時鳴るノイズ）がない
- [ ] 加工後と原音の **位相ズレ/レイテンシ差が 100ms 未満**（ラウンドトリップが成立する範囲）

### コード・設定

- [ ] 上記の検証が **[`ARCHITECTURE.md`](./ARCHITECTURE.md) で定義した `AudioEngineProtocol`** 上で動作する（DI 経路が活きる）
- [ ] `BoostState` の `effectiveGain` 計算と、AudioEngine への適用値 dB 変換が一致する
- [ ] macOS 26 以外の API availability 分岐を **コードに残さない**（macOS 26 のみで成立する前提でよい）

## 撤退ライン

PoC の Done 条件が **いずれか一つでも満たせない** 場合:

- **v0.1 の実装には進まない**（延期）
- 自プロセス音声のみへの縮退は **MVP として採用しない**（技術デモ扱い）
- 代替手段として以下を評価する:
  1. **ScreenCaptureKit** の音声取り込みで代替できるか（システム音キャプチャ手段として Apple が別途用意している）
  2. 別プロダクト（Hazakura Mixer 等）として「アプリ別ミキサー」路線で再設計する
  3. Apple へ Feedback Assistant で機能要望を提出し、回答を待つ
- 撤退判断は ARCHITECTURE / RISKS / 本ドキュメントを残したまま、別途 **ADSR（Architecture Decision Record）** として記録する

## 検証手順（ドラフト）

参考手順。実際の Xcode プロジェクト初期化と並行で詰める。

```bash
# 1. PoC 用 Xcode プロジェクトを作成（v0.1 とは分離）
mkdir -p spike/core-audio-tap
# ... Xcode で新規 macOS App プロジェクト作成 ...

# 2. Info.plist に NSAudioCaptureUsageDescription を追加
# 3. システム出力の aggregate device / tap を確立する
# 4. AVAudioEngine で tap からの PCM を読み、globalGain を介して出力
# 5. 0% / 100% / 200% / 400% のスライダーまたは固定値でゲインを切り替え
# 6. 終了 → 再起動シナリオを確認
```

検証用チェックリスト（PoC 完了時に埋める）:

```
[ ] YouTube 音声を取得できた
[ ] 0% で音量を絞れる
[ ] 100%（素通し）で原音と同等に聴こえる
[ ] 200% / 400% で音量が明確に上がる
[ ] 元音と加工後音が二重に鳴らない
[ ] スライダーで 100% に戻せる
[ ] アプリ終了で通常出力に戻る
[ ] スリープ前にゲインが 1.0 へ戻る
[ ] スリープから復帰して保存値へ復元する
[ ] 強制終了後に `./scripts/verify_shutdown_safety.sh` が OK になる
[ ] 権限拒否でクラッシュしない
[ ] マイク権限ダイアログが出ない
[ ] レイテンシが 200ms 未満の体感
```

## 関連ドキュメント

- [ARCHITECTURE.md](./ARCHITECTURE.md) — AudioEngine 層・データフロー・不変条件
- [RISKS.md §1](./RISKS.md) — Core Audio Tap のリスクと撤退ライン
- [ROADMAP.md §v0.1](./ROADMAP.md#v01-mvp) — v0.1 の Done と受け入れ確認
- [PERMISSIONS.md](./PERMISSIONS.md) — `NSAudioCaptureUsageDescription`、Hardened Runtime、Privacy Manifest
- [DEVELOPMENT.md](./DEVELOPMENT.md) — ビルド・テスト・コード規約

## 変更履歴

- v2 (2026-06-17): 純Core Audio IOProc経路は不採用。ScreenCaptureKit + ring buffer + AVAudioEngine 出力を v0.1 beta PoC の active 経路として記録
- v1 (2026-06-14): 初版作成（ちかちゃんレビュー反映）
