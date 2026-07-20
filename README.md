# voice-readout

Claude Code のやり取りを、画面を見なくても声で追えるようにするプラグイン。スマートフォン（Termux）での利用を前提にしている。

## できること

- **応答の読み上げ**：Claude の応答が終わるたびに、内容を音声で読み上げる。要約して一文で読む「要約モード」と、コード部分を除いて本文をそのまま読む「フル読み上げモード」を切り替えられる。
- **許可確認・入力待ちの読み上げ**：「Bash を実行してもいいですか」のようなツール許可確認や、入力待ちで放置されたときにも声で知らせる。応答が終わっていないと発火しない Stop フックだけでは拾えない場面をカバーする。
- **口調**：どちらのモードも、Claude 本人が一人称で語りかける口調（第三者が実況しているような「〜ということですね」調にはしない）。デフォルトは短く普通の話し言葉。「甘い口調」はオプションのペルソナ設定で、有効にすると「〜なのよ」「〜してくれる？」のような親しみを込めた話し方になる。
- **読み上げエンジンの故障検知と復旧サポート**：Android 側の音声合成サービスが固まって読み上げが止まったとき、①②の手順つき通知を出し、タップひとつで強制停止すべきアプリの設定画面まで飛べる。裏では自動復旧ウォッチャーが動いていて、直った瞬間を検知して声で知らせ、通知を消す。
- **オン・オフの切替**：応答の読み上げ、許可確認の読み上げをそれぞれ個別に、チャットで指示するだけで止められる。
- **読み上げエンジンの切替（オプション）**：デフォルトは「オンデバイス」（Android 標準の TTS を Termux:API 経由で使う、完全オフライン）。Gemini API の TTS（Google AI Studio の API キーで利用）や、Inworld の Realtime TTS-1.5 Mini（低レイテンシ寄りのクラウドTTS）に切り替えることもできる。ネットワークが必要になる代わりに、より自然で表情豊かな音声にできる可能性がある。

## Termux:API との関係

読み上げの実体は `termux-tts-speak` コマンドで、これは **Termux:API** という別アプリ（`com.termux.api`）が仲介して Android 標準の音声合成機能を呼び出す仕組みになっている。関係を図にすると：

```
Claude Code (Stop / Notification フック)
        │
        ▼
termux-tts-speak（Termux 側のコマンド）
        │
        ▼
Termux:API アプリ ── Android の音声合成機能を呼び出す
        │
        ▼
Google 音声認識と音声合成サービス（実際に声を合成するエンジン）
```

このプラグインは Termux:API アプリと直接連携しているため、**Termux:API アプリがインストールされていないと動作しない**。また、この経路のどこかが詰まると読み上げが止まる：

- **Google の音声合成エンジンが固まる**：エンジン自体の既知の持病。バックグラウンドで強制終了されたりクラッシュしたりする。
- **Termux:API がその「詰まった接続」を握ったまま残る**：エンジン側を直しても、Termux:API 内に壊れた接続が残っていると読み上げは復活しない。実運用では**こちらを先に強制停止する方が復旧率が高い**と分かっている。

そのため故障通知は「①まず Termux:API を強制停止 → ②直らなければ Google 音声も」の順で案内している。

## インストール方法

前提として、スマートフォン（Termux）側に以下が入っている必要がある：

- **Termux**（本体）
- **Termux:API アプリ**（Play ストア等からインストール。上記の仲介役）
- Termux 側に `termux-api` パッケージ（`pkg install termux-api` 等）
- `jq`（JSON パース用。`pkg install jq`）

プラグイン自体はこのリポジトリ（`mobile-claude-tools` マーケットプレイス）経由で有効化する。`~/.claude/settings.json` の `enabledPlugins` に以下が入っていれば有効：

```json
"voice-readout@mobile-claude-tools": true
```

インストール直後は追加設定なしで動く（要約モード・全読み上げオンがデフォルト）。バッテリー最適化でアプリがバックグラウンド終了されるとハングの原因になるため、**Termux:API と Google 音声サービスの両方を「バッテリー使用量→制限なし」に設定しておく**ことを推奨する（設定→アプリ→各アプリ→バッテリー使用量）。

## 使えるオプション

すべてチャットで「〜して」と頼むだけで切り替わる（裏で `bin/toggle.sh` が実行される）。設定は端末側の `${CLAUDE_PLUGIN_DATA}/voice-readout-config` に保存され、次回以降のセッションにも引き継がれる。

| 頼み方の例 | 効果 |
|---|---|
| 「音声読み上げをオフにして」 | 応答の読み上げ・許可確認の読み上げを両方オフ |
| 「音声読み上げをオンに戻して」 | 両方オン |
| 「応答の読み上げだけオフにして」 | 応答終了時の読み上げのみオフ（許可確認は継続） |
| 「許可確認の読み上げだけオフにして」 | 許可確認・入力待ちの読み上げのみオフ（応答読み上げは継続） |
| 「フル読み上げにして」 | 要約せず、コードを除いた本文をそのまま読む |
| 「要約読み上げに戻して」 | 一文要約に戻す（デフォルト） |
| 「甘い口調にして」 | ペルソナ（`personas/persona.md`）を適用。親しみを込めた甘い話し方になる |
| 「普通の口調に戻して」 | ペルソナ設定を外す。短く普通の話し言葉に戻る（デフォルト） |
| 「Gemini の TTS に切り替えて」（要 API キー） | **応答の要約読み上げだけ** Gemini API TTS に切替 |
| 「Inworld の TTS に切り替えて」（要 API キー） | **応答の要約読み上げだけ** Inworld Realtime TTS-1.5 Mini に切替 |
| 「ElevenLabs の TTS に切り替えて」（要 API キー） | **応答の要約読み上げだけ** ElevenLabs（eleven_flash_v2_5）に切替 |
| 「オンデバイスの読み上げに戻して」 | Android 標準 TTS（Termux:API 経由）に戻す（デフォルト） |

許可確認・入力待ちの読み上げ（Notification フック）は、この設定に関わらず**常にオンデバイス固定**。理由は下記の速度比較を参照。

### モードの違い

| | 要約モード（デフォルト） | フル読み上げモード |
|---|---|---|
| 内容 | Haiku が一文に要約 | 本文をほぼそのまま（コード・URL・Markdown記号は除去） |
| 口調 | 甘い一人称口調 | 素の文章（口調演出なし） |
| 向いている場面 | 短時間でテンポよく状況を把握したい | 要約だと何を言われているか分かりにくいとき、正確に内容を追いたいとき |
| 読み上げ時間 | 数秒〜十数秒 | 内容量に応じて数十秒〜数分（背景処理なので操作はブロックしない） |

## 故障時の対応（読み上げが聞こえないとき）

1. スマホに ⚠️ 通知が届く（①Termux:API → ②Google音声の順、頻発防止のため 30 分に一度まで）
2. 通知（または「設定画面を開く」ボタン）をタップして開いた画面で「強制停止」を押す
3. 直らなければ②の通知でも同様に強制停止
4. 裏の自動復旧ウォッチャーが読み上げの復活を検知すると「直ったみたいよ」と声で知らせ、通知を自動で消す

## ファイル構成

```
voice-readout/
├── hooks/hooks.json           Stop / Notification フックの登録
├── bin/
│   ├── tts-lib.sh              読み上げ・通知・故障検知・TTSバックエンド切替の共通処理
│   ├── summarize-and-speak.sh  Stop フック本体（要約 or フル読み上げ）
│   ├── notify-speak.sh         Notification フック本体（許可確認・入力待ち）
│   ├── recovery-watcher.sh     故障後、復旧を自動検知するウォッチャー
│   ├── toggle.sh                オン/オフ・モード・ペルソナ切替の設定変更コマンド
│   └── speak-text.sh            任意のファイル/標準入力の文章をそのまま読み上げる手動コマンド（フックではない。Stop フックの要約・整形処理を一切通さない）
├── personas/
│   └── persona.md               口調プリセット（甘い口調）。中身を書き換えれば別の口調にもできる
└── README.md                   このファイル
```

### 口調（ペルソナ）の仕組み

口調の指定はスクリプトに直接書かれておらず、`personas/persona.md` という別ファイルに分離されている。「甘い口調にして」と頼むとこの内容が端末側の設定（`${CLAUDE_PLUGIN_DATA}/voice-readout-persona.md`）にコピーされて有効になり、「普通の口調に戻して」と頼むとそのファイルが削除されてデフォルト（短く普通の話し言葉）に戻る。

- 要約モードでは、このペルソナの内容が Haiku への指示に追加される形で反映される。
- 許可確認・入力待ちの読み上げ（固定フレーズ）は LLM を通さないため、ペルソナが有効かどうかで 2 パターンの定型文を出し分けている。
- `personas/persona.md` の中身を書き換えれば、別の口調に差し替えることもできる。

### 読み上げエンジン（バックエンド）の仕組み

読み上げの音声そのものを生成するエンジンも切り替えられる。全体の設計は「読み上げる内容の3段階」×「TTSエンジンの4択」というマトリクスになっている：

| 内容の段階 | 何を読むか | 使えるTTSエンジン |
|---|---|---|
| ① 通知（Notification） | 許可確認・入力待ち | **オンデバイス固定**（速度優先、下記の実測により決定） |
| ② 要約（Stop・summaryモード） | 応答を一文に要約 | オンデバイス（デフォルト）／Gemini／Inworld／ElevenLabs から選択可 |
| ③ 全文読み上げ（Stop・fullモード） | 応答をほぼそのまま | ②と同じ設定を共有する（独立した設定はない） |

①は常にオンデバイス固定。②③はどちらも同じ `TTS_BACKEND` 設定を参照するため、「Gemini に切り替えて」「Inworld に切り替えて」「ElevenLabs に切り替えて」と頼むと要約モードでもフルモードでもそのバックエンドが使われる（フルモードは文章が長くなりがちなので、クラウド系だと読み上げ完了までかなり長くかかる点は下記の速度実測を参照）。

| | ondevice（デフォルト） | gemini | inworld | elevenlabs |
|---|---|---|---|---|
| 実体 | Android 標準 TTS（Termux:API 経由）。「ondevice」は配送経路の名前で、実際に声を合成しているのは Google のオンデバイス音声合成エンジン | Gemini API の TTS モデル（`gemini-2.5-flash-preview-tts` 等）。音声データを `termux-media-player` 経由で Android の MediaPlayer に渡して再生する | Inworld の Realtime TTS-1.5 Mini（`inworld-tts-1.5-mini`）。レスポンスがそのまま完成した WAV ファイルなので、Gemini と違い ffmpeg 変換なしで直接 `termux-media-player` に渡す | ElevenLabs の `eleven_flash_v2_5`。レスポンスが生のMP3バイト列（JSON/base64ではない）で返るので、そのままファイル保存して `termux-media-player` に渡す |
| ネットワーク | 不要（完全オフライン） | 必要 | 必要 | 必要 |
| 費用 | 無料 | Google AI Studio の無料枠内なら無料（枠を超えると課金。最新の料金は AI Studio 側で要確認） | 無料枠あり（Mini は $5/100万文字と低単価。最新の料金は Inworld の pricing ページで要確認） | 無料枠あり（月10,000クレジット≒約10分、商用不可）。最新の料金は ElevenLabs の pricing ページで要確認 |
| 故障傾向 | 今日ずっと対処してきたハング（Google エンジン／Termux:API 側の詰まり）が起きうる | Gemini 側は今のところ未検証。API 障害時は自動でオンデバイス側にフォールバックする | Inworld 側も今のところ未検証。API 障害時は自動でオンデバイス側にフォールバックする | ElevenLabs 側も今のところ未検証。API 障害時は自動でオンデバイス側にフォールバックする |
| セットアップ | 不要（インストール直後から動く） | [Google AI Studio](https://aistudio.google.com/) で API キーを取得し、`toggle.sh gemini-key <キー>` で設定する必要がある | [Inworld Portal](https://platform.inworld.ai/) で API キーを取得し、`toggle.sh inworld-key <キー>` で設定する必要がある | [ElevenLabs](https://elevenlabs.io/) で API キーを取得し、`toggle.sh elevenlabs-key <キー>` で設定する必要がある |

**API キーの保存場所**：Gemini・Inworld・ElevenLabs 共通で `${CLAUDE_PLUGIN_DATA}/voice-readout.env` に `KEY=値` の形式でまとめて保存される（`chmod 600`）。バックエンドが増えてもこの1ファイルにキーが集約される設計。

**セットアップ手順（Gemini）**：
1. Google AI Studio で API キーを取得する
2. チャットで「Gemini の TTS 用の API キーは ○○ です」のように伝える（裏で `toggle.sh gemini-key <キー>` を実行）
3. 「Gemini の TTS に切り替えて」で backend を切替（裏で `toggle.sh backend gemini` を実行）

**セットアップ手順（Inworld）**：
1. [Inworld Portal](https://platform.inworld.ai/) で API キーを取得する
2. チャットで「Inworld の TTS用の API キーは ○○ です」のように伝える（裏で `toggle.sh inworld-key <キー>` を実行）
3. 「Inworld の TTS に切り替えて」で backend を切替（裏で `toggle.sh backend inworld` を実行）

**セットアップ手順（ElevenLabs）**：
1. [ElevenLabs](https://elevenlabs.io/) で API キーを取得する
2. チャットで「ElevenLabs の TTS 用の API キーは ○○ です」のように伝える（裏で `toggle.sh elevenlabs-key <キー>` を実行）
3. 「ElevenLabs の TTS に切り替えて」で backend を切替（裏で `toggle.sh backend elevenlabs` を実行）

デフォルトの声・モデル・言語は環境変数で上書きできる：Inworld は `VOICE_READOUT_INWORLD_VOICE`（既定 `Olivia`、英語ネイティブの若い英国系女性声。Hina/Asuka/Sarah/Selene/Evelyn と聴き比べた上で2026-07-20に選定）/ `VOICE_READOUT_INWORLD_MODEL`（既定 `inworld-tts-1.5-mini`）/ `VOICE_READOUT_INWORLD_LANG`（既定 `ja`）、ElevenLabs は `VOICE_READOUT_ELEVENLABS_VOICE`（既定 `blVzlvngVR9lhf4Gflnk` = アカウントのマイボイス「アマテラステラス2」、middle-aged・ja-kanto）/ `VOICE_READOUT_ELEVENLABS_MODEL`（既定 `eleven_flash_v2_5`）。日本語に強い声を探したい場合は各社のダッシュボードで試聴して差し替える。

Gemini・Inworld・ElevenLabs いずれも、バックエンドが失敗した場合（キー未設定、API エラー、タイムアウトなど）は、その回だけ自動的にオンデバイスバックエンドで読み上げ直すフォールバックが入っているため、切り替えても無音になることはない。

**速度の実測（2026-07-20、4バックエンドを同一セッション内・同一文章で計測。読み上げ完了までの時間）**：

| 文章の長さ | オンデバイス | Gemini | Inworld | ElevenLabs |
|---|---|---|---|---|
| 短文（22字） | 8.8秒 | 20.8秒 | 15.9秒 | 14.6秒 |
| 中文（79字） | 16.8秒 | 39.5秒 | 26.0秒 | 25.1秒 |
| 長文（211字） | 34.4秒 | 59.9秒 | 49.9秒 | 46.5秒 |

オンデバイス比では、Gemini は1.7〜2.4倍、Inworld は1.5〜1.8倍、ElevenLabs は1.4〜1.7倍の時間がかかる。**この実測では ElevenLabs が3社中もっとも速く、僅差で Inworld、Gemini がはっきり遅い**という順序になった（公開ベンチマークでは Inworld Mini の方が Time-to-First-Audio は短いとされているが、ここでの計測は「音声が鳴り終わるまでの合計時間」で、両者の読み上げ速度・API往復のばらつきも含むため、単純な TTFA 比較とは前提が異なる点に注意）。文章が長くなるほど固定の通信コストの割合が薄まり、オンデバイスとの差は縮む傾向。この差が、許可確認の読み上げにはクラウド系を使わない（常にオンデバイス固定にしている）理由。

**クラウド系を使うなら、この実測ではまず ElevenLabs、僅差で Inworld を推奨**：どちらも Gemini より明確に速い。ElevenLabs は音声表現力（本家の音声タグ機能）でも定評があるため、速度と表現力を両立したい場合の第一候補になる。Gemini はテキスト内感情タグを試したいときの選択肢として残している。

（旧バージョンの実測値はテスト文言が異なり単純比較できないため、今回まとめて同条件で取り直した。長文の Gemini は初回計測時に `curl --max-time 20` のタイムアウトに引っかかって失敗しており、Gemini・Inworld・ElevenLabs とも45秒に緩めて計測している。）
