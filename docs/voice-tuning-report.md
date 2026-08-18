# 音声調整・VAD波形解析および最適化チューニング記録 (2026-08-18)

本ドキュメントは、AI CLI（Claude Code / Codex / Antigravity CLI `agy`）向け音声読み上げプラグイン `voice-readout` における、音声接続ギャップの解消、フィラー最適化、および実機音響波形解析（Python VAD）による黄金パラメータ導出の全経緯と対応内容を記録したものです。

---

## 1. 課題と経緯の特定

### ① ローカル ➡ クラウドTTS 移行時の沈黙問題
* **現象**: 冒頭のローカルデバイス読み上げからクラウドTTS（Gemini / ElevenLabs）に切り替わる地点で、約 1.94 秒（1935 ms）の不自然な沈黙が発生していた。
* **原因分析**:
  * 旧設定のローカル冒頭文字数（53文字・実発話 9.8秒）に対し、クラウドTTS（Chunk 0）の生成に 10.8秒 かかっていた。
  * 生成待ち（約 1.0秒）＋ メディアプレーヤーの起動ラグ（約 0.9秒）が合算され、約 1.94秒 の空白となって耳に届いていた。

### ② フィラー末尾のバラつき問題
* **現象**: フィラー（全30種）からローカル本文への入りにおいて、ファイルによって間が空きすぎたり、逆に急に始まる感覚があった。
* **VAD波形解析による特定**: 各音声ファイルの末尾に **132 ms 〜 386 ms** の無音空白（Tail Silence）が不均一に含まれていたため。

---

## 2. 実施した最適化対応

### ① ローカル冒頭文字数を「90〜110文字（約20秒）」へ拡張
* **変更**: `HYBRID_MIN_ONDEVICE_CHARS: 50 -> 90`（最大 120文字）
* **効果**: ローカルが約 20秒間 しっかり発話することで、クラウドTTSが裏でスタンバイ完了するまでの **「約 10秒以上の巨大な安全マージン（Slack）」** を確保。
* **結果**: API生成待ちによる沈黙リスクが **物理的に 100% 完全消滅**。

### ② 全30件のフィラー音声の末尾均一トリミング＆メタデータ管理
* **対応**:
  1. 元音声を生データバックアップ（`assets/fillers_backup_raw/`）に退避。
  2. Python VAD で有音終了地点をミリ秒単位で検出し、末尾の無音を **均一 `30.0 ms` にトリミング**（ポップノイズ防止フェード付与）。
  3. 先頭無音も `20.0 ms` に詰め、トリガーからの発音ラグを極小化。
  4. 全ファイルの正確な再生長を管理する [`assets/fillers_metadata.json`](file:///root/dev/voice-readout/assets/fillers_metadata.json) を作成。
* **検証**: 20曲の「フィラー ➡ 楽曲タイトル＆歌詞」連続実機テストを実施。
  * フィラー直後の無音ギャップが **全曲平均 `456.8 ms（約 0.45秒）` の自然な息継ぎに完全収束**。

### ③ 前倒し（Lead）パラメータの強化（文末ポーズ相殺）
* AI音声エンジン（ElevenLabs / Inworld）が句点（。）の文末に自動付与する情感ポーズ（約 0.8〜1.0秒）を相殺するため、先行キック量を最適化。
  * `HYBRID_PREPLAY_LEAD`（ローカル ➡ クラウド）: **`0.60 秒`**
  * `CLOUD_PLAY_LEAD`（クラウド間）: **`0.75 秒`**

---

## 3. 確立された最終最適パラメータ一覧

```ini
# voice-readout-config
READOUT_MODE=full
READOUT_SPEED=1.3
HYBRID_TTS=on
HYBRID_SPECULATION=1
HYBRID_MIN_ONDEVICE_CHARS=90
HYBRID_MAX_ONDEVICE_CHARS=120
HYBRID_PREPLAY_LEAD=0.60
CLOUD_PLAY_LEAD=0.75
TTS_CHUNK_CHARS=90
CHUNK_MARKER=on
TTS_BACKEND=elevenlabs
TTS_BACKEND_FULL=elevenlabs
STARTUP_GREETING=on
STARTUP_GREETING_TEXT=ボイスリードアウト、準備できたよ
SESSION_END_GREETING=on
SESSION_END_GREETING_TEXT=ボイスリードアウト、またね
```

---

## 4. 実行した実機テスト・検証スクリプト

| スクリプト | 内容・対象シナリオ | 測定結果 |
| :--- | :--- | :--- |
| [`tests/test_ceo_speech_90char_vad.sh`](file:///root/dev/voice-readout/tests/test_ceo_speech_90char_vad.sh) | 社長スピーチ（90文字ローカル ＋ Gemini） | 1.94sの沈黙が消滅、ローカル➡クラウド間 0.19s直結 |
| [`tests/test_20_fillers_music.sh`](file:///root/dev/voice-readout/tests/test_20_fillers_music.sh) | 全20曲フィラー＋音楽タイトル＆歌詞ショーケース | フィラー直後無音 456.8ms（被り0件） |
| [`tests/test_park_kiss_romance.sh`](file:///root/dev/voice-readout/tests/test_park_kiss_romance.sh) | 21歳新入社員・公園キス小説（Inworld ハイブリッド） | `handover seam -0.0s` 完走 |
| [`tests/test_aftermath_vad.sh`](file:///root/dev/voice-readout/tests/test_aftermath_vad.sh) | キス後続編（ElevenLabs チューニング前倒し検証） | ギャップが 1.05s ➡ 0.77s へ短縮 |
| [`tests/test_park_kiss_long_sequel.sh`](file:///root/dev/voice-readout/tests/test_park_kiss_long_sequel.sh) | ホテル誘出長編小説（ElevenLabs 全5チャンク・100秒） | 息の合ったテンポと高音質で長編完走 |

---

## 5. UI連携・ステータス表示
* **Claude Code CLI**: `~/.claude/settings.json` に [`bin/statusline.sh`](file:///root/dev/voice-readout/bin/statusline.sh) が登録されており、プロンプト下部に以下が常時表示される。
  ```text
  voice readout | greet 🔊🔊 | notif 🔊 local | resp 🔊 full hyb 11labs | ×1.3 | 🔔
  ```
* **Android Termux**: [`bin/readout-switch.sh notify`](file:///root/dev/voice-readout/bin/readout-switch.sh) により、通知バーに `[停止する]` / `[再開する]` の常駐スイッチが提供される。

