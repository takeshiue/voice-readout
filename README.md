# voice-readout

Claude Code のやり取りを、画面を見なくても声で追えるようにするプラグイン。スマートフォン（Termux）での利用を前提にしている。

インストール直後から追加設定なしで喋る。オン/オフ・モード・声の切替は、すべてチャットで「〜して」と頼むだけ。

- [できること](#できること)
- [動作環境（構成）](#動作環境構成) — 入れる前に読む
- [インストール方法](#インストール方法) / [アンインストール](#アンインストール)
- [使えるオプション](#使えるオプション) — 日々の操作はここ
- [ステータスライン](#ステータスライン今の状態を一目で見る)
- [起動時の挨拶](#起動時の挨拶動作確認) / [終了時の挨拶](#終了時の挨拶)
- [声が聞こえないとき](#故障時の対応読み上げが聞こえないとき)
- [ストップスイッチ](#ストップスイッチ確実に黙らせる) — とにかく黙らせたいとき
- [ファイル構成](#ファイル構成)

**なぜそういう作りなのか**（実測値・設計の理由・エンジンごとの癖）は [docs/design.md](docs/design.md) に分けてある。使うだけなら読まなくてよい。

## できること

- **応答の読み上げ** — Claude の応答が終わるたびに声で読む。一文に要約する「要約モード」と、コードを除いて本文をそのまま読む「フル読み上げモード」がある
- **許可確認・入力待ちの読み上げ** — 「Bash を実行してもいいですか」や、入力待ちで放置されたときも声で知らせる。画面を見ていなくても自分の番が分かる
- **オン・オフの切替** — 応答・許可確認をそれぞれ個別に、チャットで止められる
- **起動時／終了時の挨拶** — 起動時の一言は「今ちゃんと音が出るか」の確認を兼ねる（固まっていればその場で故障通知が走る）
- **読み上げエンジンの切替** — 既定は完全オフラインのオンデバイス（Android 標準 TTS）。Gemini / Inworld / ElevenLabs にも切り替えられ、**機能ごとに独立して**指定できる
- **話速の指標** — どのエンジンで喋っても同じ速さになる。1.0＝毎分約300字
- **故障検知と自動復旧** — エンジンが固まったら手順つき通知を出し、直った瞬間を検知して声で知らせる
- **ステータスライン表示** — 今どれがオンで、どのエンジンで喋るのかを1行で常時表示
- **ストップスイッチ** — Claude も設定も環境変数も一切経由せず、通知のボタン1つで全読み上げを黙らせる

## 動作環境（構成）

このプラグインは、**Android スマホの上に3層を重ねた環境**で動かすことを想定している。

```
Android スマホ
└─ Termux（アプリ）                     … termux-tts-speak / termux-notification /
   │                                       termux-media-player を提供（Termux:API 経由で
   │                                       Android の音声合成・通知に橋渡し）
   └─ proot-distro の Ubuntu            … apt が使える普通の Linux。ここに Claude Code と
      │                                    このプラグインが入っている
      └─ Claude Code                    … 実際に対話しているもの。Stop / Notification
                                           フックからこのプラグインの読み上げが動く
```

ポイントは、**Claude Code は「Termux そのもの」ではなく、Termux の中で proot-distro で起動した Ubuntu の中で動いている**こと。読み上げの実体である `termux-tts-speak` などは Termux 側のコマンドなので、**Ubuntu(proot) の `PATH` に Termux の `bin` ディレクトリ（`/data/data/com.termux/files/usr/bin`）を通しておく**ことでフック（proot 側で実行される）から呼べるようにしている。この橋渡しが構成の要。

そのため、必要なものが**どちらの層に要るか**が分かれる：

| 層 | 入れるもの | 入れ方 |
|---|---|---|
| Android / Termux | Termux 本体、**Termux:API アプリ**、`termux-api` パッケージ | Play ストア等＋ `pkg install termux-api` |
| Ubuntu (proot) | Claude Code、このプラグイン、`jq`（＋クラウドTTSを使うなら `curl` `ffmpeg`） | Claude Code のインストール手順＋ `apt install jq curl ffmpeg` |

> **`termux-*` 以外はすべて proot 側に要る**。フックが動くのが proot 側だからで、`jq` を Termux 側に入れても読み上げは動かない。何がどの機能に要るかは [前提を揃える](#前提を揃える) の表を参照。

### 起動と利用の流れ

1. Termux を開く
2. proot-distro で Ubuntu に入る（例：`proot-distro login ubuntu`）
3. Ubuntu の中で Termux の bin に PATH を通す（`.bashrc` 等に入れておくと毎回不要）：
   ```sh
   export PATH="$PATH:/data/data/com.termux/files/usr/bin"
   ```
4. `claude` で Claude Code を起動する
5. あとは普通に会話するだけ。Claude の応答が終わるたびに声で読み上げ、許可確認・入力待ちも声で知らせる（追加設定なしで動く）

読み上げのオン/オフやモード切替は、すべてチャットで「〜して」と頼むだけ（[使えるオプション](#使えるオプション)）。

## インストール方法

### 前提を揃える

以下が入っている必要がある（どちらの層に入れるかは [動作環境](#動作環境構成) も参照）：

**Android / Termux 側**

- **Termux**（本体）
- **Termux:API アプリ**（Play ストア等からインストール。Android の音声合成・通知への仲介役）
- `termux-api` パッケージ（`pkg install termux-api`。`termux-tts-speak` 等を提供）

**Ubuntu (proot) 側**（Claude Code が動く層）

- **Claude Code**
- Termux の bin に PATH が通っていること（`export PATH="$PATH:/data/data/com.termux/files/usr/bin"`）
- 下記のコマンド類

フックは proot 側で動くので、**`termux-*` 以外はすべて proot 側に要る**。必要なものは使う機能によって変わる：

| コマンド | 入れ方 | いつ要るか | 無いとどうなるか |
|---|---|---|---|
| `jq` | `apt install jq` | **常に**（フックが受け取る JSON を読む） | 読み上げが動かない |
| `curl` | `apt install curl` | クラウドTTS（Gemini / Inworld / ElevenLabs）を使うとき | そのエンジンが失敗し、オンデバイスに落ちる |
| `ffmpeg` | `apt install ffmpeg` | **Gemini は必須**（返ってくる生 PCM を WAV に変換するため）。ElevenLabs の音量・速度調整、チャンクマーカーにも使う | Gemini が使えない。ElevenLabs は音量・速度調整だけ効かなくなる |
| `ffprobe` | `ffmpeg` に同梱 | ElevenLabs のチャンク再生 | 継ぎ目に数秒の無音が入る |
| `flock` `setsid` | `util-linux`（通常は最初から入っている） | 復旧ウォッチャー／起動・終了の挨拶 | ウォッチャーが二重起動する／挨拶が鳴らない |
| `ps` `pkill` | `procps`（同上） | エンジンの詰まり検出／アンインストール | 詰まりを自動復旧できない |

`awk` `sed` `grep` `find` `timeout` `mktemp` `base64` などは Ubuntu の基本パッケージに含まれるので、通常は意識しなくてよい。

オンデバイス読み上げだけで使うなら、**追加で入れるのは `jq` だけ**でよい。クラウドTTSまで使うなら `jq curl ffmpeg` の3つ：

```sh
apt install jq curl ffmpeg
```

入っているかどうかは、proot 側でこれを実行すれば一覧で分かる：

```sh
for c in jq curl ffmpeg ffprobe flock setsid ps \
         termux-tts-speak termux-media-player termux-notification; do
  command -v "$c" >/dev/null 2>&1 && echo "OK      $c" || echo "MISSING $c"
done
```

`termux-*` が MISSING なら、Termux 側の `pkg install termux-api` か、PATH が通っていない。

### プラグインを入れる

このリポジトリ自体がマーケットプレイスを兼ねている（`.claude-plugin/marketplace.json` を同梱）。Claude Code の中で次の2つを打つ：

```
/plugin marketplace add takeshiue/voice-readout
/plugin install voice-readout@voice-readout
```

1行目でこのリポジトリをマーケットプレイスとして登録し、2行目でその中の `voice-readout` プラグインを入れる。`/plugin` だけを打つと対話メニューが開くので、そちらから選んでもよい。

**中身を書き換えて使いたい場合**は、クローンしてローカルのディレクトリを登録する（`git pull` した内容がそのまま反映され、自分の変更も即座に効く）：

```sh
git clone https://github.com/takeshiue/voice-readout.git
```
```
/plugin marketplace add /クローンした場所/voice-readout
/plugin install voice-readout@voice-readout
```

どちらの入れ方でも、有効になると `~/.claude/settings.json` の `enabledPlugins` に次の行が入る（手で書いても同じ）：

```json
"voice-readout@voice-readout": true
```

### 更新のされ方（入れる前に知っておくこと）

**このプラグインのスクリプトは、セッションの開始・終了・応答のたびに自動で実行される。** フックとはそういう仕組みで、実行のたびに許可を求めたりはしない。つまり「どのコードが自分の端末で走るか」は、入れた時点ではなく**更新した時点**で決まる。

| 入れ方 | 更新のタイミング | 何が入るか |
|---|---|---|
| GitHub から（`marketplace add takeshiue/voice-readout`） | `claude plugin update voice-readout` を**自分で実行したとき**だけ（Claude Code の再起動で反映）。放っておけば入れた版のまま | 実行時点の**既定ブランチの最新**。特定のタグやバージョンに固定する仕組みは無い |
| ローカルのクローンを登録 | `git pull` した内容がそのまま次回起動から動く | 手元のブランチの内容 |

どちらも、更新すれば**その時点の新しいコードが以後すべてのセッションで自動実行される**。他人のリポジトリを追いかける以上、更新の前に差分を見るかどうかは各自の判断になる（`git log`／GitHub の compare で確認できる）。自分で書き換えて使う場合は、ローカル登録にしておけば「自分が読んだコードしか走らない」状態を保てる。

### 動いたことを確認する

**フックは Claude Code の起動時に読み込まれるので、インストール後に一度再起動する。** 起動して「ボイスリードアウト、準備できたよ」と聞こえれば成功。聞こえない場合は [声が聞こえないとき](#故障時の対応読み上げが聞こえないとき) を参照。

インストール直後は追加設定なしで動く（要約モード・全読み上げオンがデフォルト）。

### 推奨設定

バッテリー最適化でアプリがバックグラウンド終了されるとハングの原因になるため、**Termux:API と Google 音声サービスの両方を「バッテリー使用量→制限なし」に設定しておく**ことを推奨する（設定→アプリ→各アプリ→バッテリー使用量）。

ステータスライン（今どの機能がオンかの常時表示）を使う場合は、別途 `settings.json` への登録が必要 → [ステータスライン](#ステータスライン今の状態を一目で見る)

### アンインストール

このプラグインは Android 側と proot 側の**両方**に置き土産をするので、プラグインを消しただけでは終わらない。後始末用のスクリプトを同梱している。

クローンして使っている場合は、そのディレクトリで：

```sh
bash bin/uninstall.sh
```

マーケットプレイス経由で入れた場合、置き場所はバージョン番号を含む（`~/.claude/plugins/cache/voice-readout/voice-readout/<版>/`）ので、探してから実行する：

```sh
bash "$(find ~/.claude/plugins -path '*voice-readout*' -name uninstall.sh | head -1)"
```

確認プロンプトを飛ばすなら `--yes`、設定と API キーを残したいなら `--keep-data`。中身は消す前に一覧で示され、`y` と答えるまで何もしない。

やってくれること：

| | 内容 |
|---|---|
| 常駐通知の削除 | ストップスイッチと故障通知。**`--ongoing` で出しているのでスワイプでは消せず**、`termux-notification-remove` が要る。**プラグインより先に**消さないと、ボタンが存在しないスクリプトを叩く状態で残る |
| `statusLine` の解除 | `~/.claude/settings.json` から削除（**このプラグインを指しているときだけ**。別のスクリプトを指していれば触らない。元ファイルは `.bak-voice-readout` として残す） |
| 設定・APIキー・ログの削除 | `~/.claude/plugins/data/voice-readout-voice-readout/` |
| Termux 側の残骸の削除 | `~/.voice-readout-stopped` / `~/.voice-readout-switch.sh` / `~/.voice-readout-tmp/` |
| 復旧ウォッチャーの停止 | 常駐したまま残っている場合 |

**プラグイン本体の削除だけは自分で行う。** パッケージの削除はパッケージマネージャ（Claude Code）の仕事なので、スクリプトはそこには手を出さず、最後にコマンドを表示して終わる：

```
/plugin uninstall voice-readout@voice-readout
/plugin marketplace remove voice-readout
```

ターミナルからなら `claude plugin uninstall voice-readout@voice-readout`。

**API キーは発行元でも失効させること。** ローカルのファイルを消してもキー自体は生きている。使わなくなったキーは各サービスのダッシュボード（Google AI Studio / Inworld Portal / ElevenLabs）で削除しておく。

### 音声の一時ファイルだけ消したい

`~/.voice-readout-tmp/` は読み上げのたびに音声ファイルを置く場所で、**チャンク音声（`vr-*`）以外は自動削除されない**ため使っているうちに溜まる（十数MBになることがある）。アンインストールせず容量だけ空けたいときは、ここを消せばよい。次の読み上げで必要なものは作り直される。

```sh
rm -rf ~/.voice-readout-tmp/
```

## 使えるオプション

すべてチャットで「〜して」と頼むだけで切り替わる（裏で `bin/toggle.sh` が実行される）。設定は端末側のデータディレクトリ（`${CLAUDE_PLUGIN_DATA}`、無い場合は `~/.claude/plugins/data/voice-readout-voice-readout/`）の `voice-readout-config` に保存され、次回以降のセッションにも引き継がれる。

| 頼み方の例 | 効果 |
|---|---|
| 「音声読み上げをオフにして」 | 応答の読み上げ・許可確認の読み上げを両方オフ |
| 「音声読み上げをオンに戻して」 | 両方オン |
| 「応答の読み上げだけオフにして」 | 応答終了時の読み上げのみオフ（許可確認は継続） |
| 「許可確認の読み上げだけオフにして」 | 許可確認・入力待ちの読み上げのみオフ（応答読み上げは継続） |
| 「フル読み上げにして」 | 要約せず、コードを除いた本文をそのまま読む |
| 「要約読み上げに戻して」 | 一文要約に戻す（デフォルト） |
| 「読み上げを1.3倍にして」 | 話速の指標を変更（裏で `toggle.sh speed 1.3`。全エンジンに効く。1.0＝毎分約300字、既定1.2、範囲0.5〜2.0） |
| 「もう少しゆっくり読んで」 | 同じく指標を下げる |
| 「起動の挨拶をオフにして」 | セッション開始時の挨拶読み上げをオフ（裏で `toggle.sh greeting off`。応答・許可確認の読み上げとは独立） |
| 「起動の挨拶をオンに戻して」 | 起動時の挨拶をオン（デフォルト） |
| 「起動の挨拶を『〜』にして」 | 挨拶の文言を変更（裏で `toggle.sh tune STARTUP_GREETING_TEXT <文言>`） |
| 「終わりの挨拶をオフにして」 | セッション終了時の挨拶クリップをオフ（裏で `toggle.sh farewell off`。起動の挨拶・読み上げとは独立） |
| 「終わりの挨拶をオンに戻して」 | 終了時の挨拶をオン（デフォルト） |
| 「Gemini の TTS に切り替えて」（要 API キー） | **全機能の既定**を Gemini API TTS に切替（個別に上書きしていない機能すべてに効く） |
| 「Inworld の TTS に切り替えて」（要 API キー） | **全機能の既定**を Inworld Realtime TTS-1.5 Mini に切替 |
| 「ElevenLabs の TTS に切り替えて」（要 API キー） | **全機能の既定**を ElevenLabs（eleven_flash_v2_5）に切替 |
| 「オンデバイスの読み上げに戻して」 | 全機能の既定を Android 標準 TTS（Termux:API 経由）に戻す（デフォルト） |
| 「フルの読み上げだけ Inworld にして」（等） | **その機能だけ**エンジンを上書き（通知／要約／フル／ファイルを個別指定。裏で `toggle.sh backend-<機能>`） |
| 「チャンクマーカーをオンにして」 | クラウド読み上げの継ぎ目にキュー音を鳴らす確認用モード（裏で `toggle.sh chunk-marker on`。既定オフ。詳細は [design.md](docs/design.md#クラウド読み上げのチャンク再生と継ぎ目マーカー)） |
| 「チャンクマーカーをオフにして」 | 確認用モードを終了（デフォルト） |

読み上げエンジンは**4つの機能ごとに独立して選べる**（通知・要約・フル・ファイル読み上げ）。「Gemini に切り替えて」のような指定は全機能共通の既定を変え、「通知だけオンデバイスのままにして」のような指定はその機能だけを上書きする。既定は4機能とも「オンデバイス」。詳細は [design.md](docs/design.md#読み上げエンジンバックエンドの仕組み) を参照。

### 調整値（config ファイル）

上のオン/オフ・モード・バックエンドに加えて、動作の細かな調整値もすべて同じ config ファイル（データディレクトリの `voice-readout-config`）に集約されている。`toggle.sh init` が既定値で書き出すので、何が変えられるかはファイルを見れば分かる。変更は `toggle.sh tune <KEY> <VALUE>`（またはファイルを直接編集）。同名の環境変数 `VOICE_READOUT_<KEY>` を付ければ、その1回だけ config より優先される。

| KEY | 既定 | 意味 |
|---|---|---|
| `ONDEVICE_MAX_CHARS` | 240 | オンデバイスの1回あたり文字数上限（超過で要約に劣化） |
| `TTS_CHUNK_CHARS` | 100 | オンデバイス読み上げのチャンク長 |
| `TTS_CHUNK_RETRIES` | 4 | チャンクごとの再試行回数 |
| `TTS_RETRY_WAIT_BASE` | 20 | 再試行の待機ベース秒（線形バックオフ） |
| `TTS_RETRY_WAIT` | 90 | 再試行の待機上限秒 |
| `PREFLIGHT_TIMEOUT` | 10 | エンジン応答確認のタイムアウト秒 |
| `WATCH_INTERVAL` | 120 | 復旧ウォッチャーの probe 間隔秒 |
| `LOG_MAX_BYTES` | 1048576 | ログ自動ローテーションの閾値バイト（**1世代あたり**。超えると `voice-readout.log` → `voice-readout.log.1` に退避して新しいログを開始するので、2世代で最大この2倍まで使う） |
| `READOUT_SPEED` | 1.2 | **全エンジン共通の話速指標**（1.0＝毎分約300字）。下の速度キーはこれから自動算出される |
| `TTS_RATE` | auto | オンデバイスの速度（`auto`＝指標から算出。数値を書けばそのエンジンだけ上書き） |
| `GEMINI_SPEED` | auto | Gemini の速度（同上） |
| `INWORLD_SPEAKING_RATE` | auto | Inworld の速度（同上） |
| `TTS_PITCH` | 1.0 | ピッチ |
| `NOTIFY_COOLDOWN` | 1800 | 故障通知のクールダウン秒 |
| `STARTUP_GREETING` | on | セッション開始時の挨拶読み上げの on/off |
| `STARTUP_GREETING_TEXT` | ボイスリードアウト、準備できたよ | 起動時に読み上げる挨拶の文言。**製品名はカタカナで書く** — 英字 `readout` は TTS が「レッドアウト」と読む |
| `SESSION_END_GREETING` | on | セッション終了時の挨拶クリップの on/off |
| `SESSION_END_GREETING_TEXT` | ボイスリードアウト、またね | 終了時に画面へ表示する文言（音声は固定クリップ。表示のみ） |
| `WARM_SKIP_WINDOW` | 120 | 直前の読み上げ成功からこの秒数以内なら、オンデバイスのエンジン応答確認（約2秒）を省く。0 で無効 |
| `OVERFLOW_PIPELINE` | off | 長文時に「冒頭を先に読み、裏で全体を要約する」パイプラインの on/off（[design.md](docs/design.md#長文パイプライン冒頭を先に読み裏で要約する)） |
| `OVERFLOW_OPENING_CHARS` | 150 | そのパイプラインで先に読む冒頭の文字数（要約の生成時間をこの読み上げで隠す） |
| `CLOUD_FIRST_CHUNK_CHARS` | 80 | クラウド読み上げの1つ目のチャンク長（短いほど喋り出しが早い） |
| `CLOUD_CHUNK_CHARS` | 200 | クラウド読み上げの2つ目以降のチャンク長 |
| `CLOUD_PLAY_LEAD` | 1.4 | 次チャンクを何秒早くかぶせるか（継ぎ目の隙間対策） |
| `CLOUD_HTTP_TIMEOUT` | 45 | クラウド API 呼び出しのタイムアウト秒 |
| `CHUNK_MARKER` | off | 継ぎ目にキュー音を鳴らす確認用モードの on/off |
| `ELEVENLABS_GAIN` | 1.0 | ElevenLabs の音量倍率（他エンジンと音量を揃えるため） |
| `ELEVENLABS_ATEMPO` | auto | ElevenLabs の速度（生成後に ffmpeg で加工。同上） |
| `ELEVENLABS_MODEL` | eleven_flash_v2_5 | 使用モデル（`eleven_v3` は表現力が高い代わりに速度指定が効かない） |

### モードの違い

| | 要約モード（デフォルト） | フル読み上げモード |
|---|---|---|
| 内容 | Haiku が一文に要約 | 本文をほぼそのまま（コード・URL・Markdown記号は除去） |
| 口調 | 甘い一人称口調 | 素の文章（口調演出なし） |
| 向いている場面 | 短時間でテンポよく状況を把握したい | 要約だと何を言われているか分かりにくいとき、正確に内容を追いたいとき |
| 読み上げ時間 | 数秒〜十数秒 | 内容量に応じて数十秒〜数分（背景処理なので操作はブロックしない） |

## ステータスライン（今の状態を一目で見る）

「次の応答は喋るのか、黙るのか」を毎回チャットで訊かずに済むよう、Claude Code のコンソール最下部に現在の状態を1行で表示できる。

**インストール後、最初に Claude Code を起動したときに自動で登録され、その起動のうちに出る。** 何もしなくてよい（この自動登録は1インストールにつき1回だけ。自分で消した場合は消えたまま復活しない）。

なお、プラグインを入れた**そのセッションには出ない**。フックは起動時に読み込まれるので、入れたばかりのプラグインのフックはそのセッションでは動いていない。「入れる → 起動し直す → 出る」で、起動は1回だけ挟まる。

手で操作したいときは次を実行する。チャットで「ステータスラインを出して」と頼んだ場合も同じものが動く：

```sh
bash <プラグイン>/bin/statusline.sh --install     # 登録
bash <プラグイン>/bin/statusline.sh --uninstall   # 解除
```

`~/.claude/settings.json`（＝個人設定）に、スクリプト自身の絶対パスが書き込まれる。**パスを人が打つ必要はない。** 反映に再起動は要らない（Claude Code は設定ファイルを監視していて、次にやり取りしたときの再描画から出る）。

<details>
<summary>細かい挙動</summary>

- **自動登録の仕組み**：プラグインのインストールを知らせるイベントは Claude Code に無いので、SessionStart フック（`statusline.sh --repair`）が「このプラグインのデータディレクトリにマーカーが無い＝入れたばかり」を初回の合図として使う。登録するのは `statusLine` が**未登録のときだけ**で、既に何か入っていれば触らない。マーカーはデータディレクトリごと消えるため、入れ直したときは改めて登録される
- **登録したその起動で表示させる仕掛け**：素直に書き込むだけだと、表示が出るのは*さらに次*の起動だった（起動が合計3回必要だった）。Claude Code は `settings.json` を監視していて再起動なしに反映するが、SessionStart フックが走るのは「設定を読み終えた後・監視が始まる前」の隙間で、肝心の初回登録の書き込みだけが誰にも見られずに素通りするため。対策として、登録に成功したら切り離したワーカー（`statusline.sh --nudge`）が**約1・2・4・8・16・32秒後に同じ内容を書き直す**。監視が動き出した後の最初の1回が効いて表示が出る。残りは中身の変わらない読み直しで、実害はない。秒数を決め打ちにしないのは、起動にかかる時間が端末次第（低速なディスクへの初回展開と、温まった状態での再起動は別物）だから。この30秒の間に `--uninstall` や手編集で登録が別物になったら、そこで打ち切る
- 書き込み先は `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json`。別のファイルに書きたい場合は `--file <パス>`
- **個人設定に書く理由**：プラグインは全セッションで有効なので表示も全セッションに要る。またプロジェクトの `.claude/settings.json` は git で共有されることが多く、そこに端末固有の絶対パスを書くと他の人の環境を壊す
- 既に**別のスクリプト**が `statusLine` に登録されている場合は、奪わずに中止する（置き換えるなら `--force`）
- **`"command": "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh"` と書いてあると、何も表示されない。** フックはこの書き方で登録するので手が滑りやすいが、statusLine はプラグインのコンポーネントではないためこの変数は展開されず、`/bin/statusline.sh` の実行に失敗して**エラーも出ずに黙る**。`--install` はこれを自分の壊れた登録と認識して絶対パスに直す（`--force` は要らない）。`--uninstall` でも消せる
- そのプロジェクトの設定に `statusLine` があると**そちらが優先される**（キー単位で上書きされるため）。カレントディレクトリにそれを見つけた場合は警告を出す
- 書き換え前に `settings.json.bak-voice-readout` を残す
- **マーケットプレイス経由で入れた場合、更新するとプラグインの置き場所（バージョン番号を含むパス）が変わる。** これは起動時に自動で直る：SessionStart フックが `statusline.sh --repair` を実行し、登録されているパスが古ければ書き直す（**未登録なら何もしない**＝勝手に登録はしない。他のスクリプトを指していれば触らない。値が正しければ書き込まない）。直した場合はログに `[info] statusline: repaired stale path ...` が残る
  - 旧バージョンのディレクトリは Claude Code が14日後に自動削除するため、**更新直後は古いパスのまま動き、しばらく経ってから突然表示が消える**。自動修復はこの遅れて出る壊れ方を防ぐためのもの

手で書く場合はこの形（`${CLAUDE_PLUGIN_ROOT}` はここでは展開されないので絶対パスで）：

```json
"statusLine": { "type": "command", "command": "/絶対パス/voice-readout/bin/statusline.sh" }
```

</details>

表示はこうなる：

```
greet 🔊🔊 | notif 🔊 local | resp 🔊 sum gemini | speed ×1.2 | 🔔
```

**この行に出るものはすべて、その場で切り替えられる**（表示専用の項目はない）。何を表していて、どう変えるかの対応：

| 区画 | 意味 | 設定キー | 変え方（チャット／コマンド） |
|---|---|---|---|
| `greet` の左 🔊 | **起動**の挨拶 | `STARTUP_GREETING` | 「起動の挨拶をオフにして」／`toggle.sh greeting off` |
| `greet` の右 🔊 | **終了**の挨拶 | `SESSION_END_GREETING` | 「終わりの挨拶をオフにして」／`toggle.sh farewell off` |
| `notif` の 🔊 | 許可確認・入力待ちの読み上げ | `NOTIFICATION_READOUT` | 「許可確認の読み上げだけオフにして」／`toggle.sh notification off` |
| `notif` のエンジン名 | 通知に使うエンジン | `TTS_BACKEND_NOTIFICATION` | 「通知だけ Inworld にして」／`toggle.sh backend-notification inworld` |
| `resp` の 🔊 | 応答の読み上げ | `STOP_READOUT` | 「応答の読み上げだけオフにして」／`toggle.sh stop off` |
| `resp` の `sum`／`full` | 要約モードか全文モードか | `READOUT_MODE` | 「フル読み上げにして」／`toggle.sh mode full` |
| `resp` のエンジン名 | そのモードで使うエンジン | `TTS_BACKEND_SUMMARY`／`_FULL` | 「要約だけ Gemini にして」／`toggle.sh backend-summary gemini` |
| `speed ×1.2` | 話速の指標（1.0＝毎分約300字。どのエンジンで喋っていても同じ意味） | `READOUT_SPEED` | 「読み上げを1.3倍にして」／`toggle.sh speed 1.3` |
| `🔔` | チャンク区切りマーカー（on のときだけ表示） | `CHUNK_MARKER` | 「チャンクマーカーをオンにして」／`toggle.sh chunk-marker on` |
| `🛑 ALL MUTED` | ストップスイッチが押されている（他の表示は出さない。トグルが on でも鳴らないため） | ― （設定ファイルではなく固定パスのファイル） | 通知の［再開］ボタン／`readout-switch.sh resume`（現在値は `readout-switch.sh status`） |

挨拶にエンジン名が付かないのは、挨拶が固定クリップまたは起動確認用の生 TTS で、機能別のエンジン選択を持たないため。両方のトグルをまとめて変える「音声読み上げをオフにして」（`toggle.sh all off`）は `notif` と `resp` の2つに効き、挨拶には効かない。

アイコンは 🔊＝オン、🔇＝オフ。エンジン名は狭い画面に収めるため表示だけ短くしてある（**設定値そのものは従来どおり**で、`toggle.sh backend ondevice` のような指定は長い名前のまま）：

| 表示 | 設定値 |
|---|---|
| `local` | `ondevice`（端末内で合成。ネットワーク不要） |
| `gemini` | `gemini` |
| `inworld` | `inworld` |
| `11labs` | `elevenlabs` |

この行はフックとまったく同じ config ファイル・同じストップスイッチのパスを読むので、**表示と実際に鳴るかどうかが食い違うことはない**。

## 起動時の挨拶（動作確認）

Claude Code のセッションが始まると、`SessionStart` フック（`bin/session-greet.sh`）が短い挨拶を一度だけ読み上げる。デフォルトの文言は「ボイスリードアウト、準備できたよ」。

製品名をカタカナで書いているのは意図的で、**英字の `voice-readout` を渡すと TTS が「レッドアウト」と読む**（`read` は発音が2通りある単語で、`readout` を辞書に持たないエンジンは `read` + `out` に分解し過去形の /red/ を選ぶ）。文言を差し替えるときも同じ理由でカタカナ表記を勧める。

- **目的**：起動直後に「今この端末で読み上げが使える状態か」を耳ではっきり確認できる。鳴れば正常、鳴らなければエンジンが固まっている。
- **本番と同じ経路で鳴らす**：事前録音クリップ（`termux-media-player` 経由）ではなく、通常の読み上げと同じ**生の TTS 経路**（`speak()`）を通す。クリップだと TTS エンジンが死んでいても鳴ってしまい確認にならないため。挨拶が鳴らずに失敗した場合は、通常の読み上げ失敗とまったく同じ**故障通知＋自動復旧ウォッチャー**が起動時点で走る。長期アイドル明けの“エンジンが冷えて固まりやすい最初の1回”を、最初の応答ではなく起動時という予測可能なタイミングに前倒しできる。
- **鳴るタイミング**：新規起動（`startup`）と再開（`resume`、`claude --resume`/`--continue`）のときだけ。`/clear` や自動要約（compact）後の再開では鳴らさない（作業中に頻発してうるさいため）。
- **ストップスイッチを尊重**：［停止］が入っているときは挨拶も鳴らない（`speak()` が最初に判定するため）。
- **設定**：`STARTUP_GREETING`（on/off、既定 on）と `STARTUP_GREETING_TEXT`（文言）で変えられる。応答・許可確認の読み上げとは独立していて、「音声読み上げを全部オフにして」では挨拶は止まらない（挨拶は「起動の挨拶をオフにして」で個別に止める）。

## 終了時の挨拶

Claude Code のセッションが終わると、`SessionEnd` フック（`bin/session-farewell.sh`）が事前録音クリップ「お疲れ様。またね。」（`assets/session-end.wav`）を一度再生する。

- **なぜ事前録音クリップなのか（起動時の挨拶と逆）**：起動時の挨拶は“エンジンが生きているかの確認”が目的なので生 TTS を通す。終了時の挨拶にはその目的がなく、むしろ**セッションが閉じる瞬間に確実に鳴り切ること**が重要。生 TTS はエンジン往復に数秒かかり、プロセス終了で途中で切れうる。事前録音クリップなら `termux-media-player` が Android のメディアサービスに再生を委ねるため、**このフックのプロセスが終了処理で閉じても再生は最後まで続く**（実機で検証済み）。TTS エンジンの固まりにも左右されない。
- **鳴るタイミング**：本当にセッションが終わるとき。`/clear`（同じセッションの再起動。戻ってくれば起動の挨拶が鳴る）では鳴らさない。
- **ストップスイッチを尊重**：［停止］が入っていれば鳴らない。
- **設定**：`SESSION_END_GREETING`（on/off、既定 on）。「終わりの挨拶をオフにして」で個別に止められる（応答・許可確認・起動の挨拶とは独立）。クリップ差し替えは `assets/session-end.wav` を置き換えるだけ（生成は [design.md](docs/design.md#決まり文句の事前録音音声) と同じ Gemini/Aoede レシピ）。

## 故障時の対応（読み上げが聞こえないとき）

1. スマホに ⚠️ 通知が届く（①Termux:API → ②Google音声の順、頻発防止のため 30 分に一度まで）
2. 通知（または「設定画面を開く」ボタン）をタップして開いた画面で「強制停止」を押す
3. 直らなければ②の通知でも同様に強制停止
4. 裏の自動復旧ウォッチャーが読み上げの復活を検知すると「直ったみたいよ」と声で知らせ、通知を自動で消す

## ストップスイッチ（確実に黙らせる）

読み上げが暴走しているとき、ユーザーは画面を見ず**耳だけで**状況に対処していることが多い。そのため、他のどの仕組みよりも確実に効く独立したスイッチを用意している。`bin/readout-switch.sh` と `speak()` 冒頭の1行だけの、コードベースの中で最も単純な仕掛け。

**なぜ他の設定を全部無視するのか**：ストップスイッチは**固定の絶対パス** `~/.voice-readout-stopped`（Termux 側のホーム）にファイルが1つあるかどうかだけを見る。このパスは `CLAUDE_PLUGIN_DATA` から組み立てていない——その環境変数を差し替えることが、通常のトグルを迂回してしまう典型的な経路だからだ。判定は `speak()` の**いちばん最初**、設定を読むよりも、オン/オフのトグルよりも、バックエンドを決めるよりも前に行う。ファイルがあれば、何があっても喋らない。

**操作方法**：

```
readout-switch.sh stop     # 全読み上げを停止する（ファイルを作成）
readout-switch.sh resume   # 読み上げを再開する（ファイルを削除）
readout-switch.sh status   # 現在の状態を表示
readout-switch.sh notify   # 状態通知を出し直す
```

実際には、スマホの通知に常駐する1枚のボタンで切り替えるのが基本。1枚の通知が状態とアクションを兼ねていて、「読み上げ 有効」＋［停止］⇄「読み上げ 停止中」＋［再開］とトグルする。

**Termux とコンテナの境界**：通知ボタンの操作は Termux 側で実行され、そこからはこのコンテナの中（`/root`）は見えない。止めたい対象そのものに依存するスイッチは、スイッチとして成立しない。そのため `readout-switch.sh` は、Termux のホームに自己完結した小さなトグルスクリプト（`~/.voice-readout-switch.sh`）を設置し、通知ボタンはそれを実行する。ボタンはファイルを切り替えると同時に**通知を逆の状態で出し直す**（初期の版は単純な touch/rm で、ラベルが古いまま残って「停止中なのに再開ボタンが無い」状態にユーザーを取り残してしまった）。

**できないこと**：**いま喋っているチャンクは必ず最後まで鳴る**。停止は次のチャンクの直前で効き、残りを破棄する。発話中のオンデバイス呼び出しを SIGKILL すると読み上げエンジンが固まり、アプリを手動で強制停止するまで復旧しない（理由は [design.md](docs/design.md#オンデバイス読み上げの長さ制限) 参照）。途中で切るコストの方が大きいので、飛んでいるチャンクだけは鳴らしきる設計にしている。

## ファイル構成

```
voice-readout/
├── hooks/hooks.json           SessionStart / SessionEnd / Stop / Notification フックの登録
├── bin/
│   ├── tts-lib.sh              読み上げ・通知・故障検知・TTSバックエンド切替の共通処理
│   ├── summarize-and-speak.sh  Stop フック本体（要約 or フル読み上げ）
│   ├── notify-speak.sh         Notification フック本体（許可確認・入力待ち）
│   ├── recovery-watcher.sh     故障後、復旧を自動検知するウォッチャー
│   ├── toggle.sh                オン/オフ・モード・話速・バックエンド切替の設定変更コマンド
│   ├── readout-switch.sh        ストップスイッチ（全読み上げを黙らせる独立スイッチ。設定・環境変数を一切経由しない）
│   ├── session-greet.sh         SessionStart フック本体（起動/再開時に挨拶を1回読み上げ、音が出るかを即確認）
│   ├── session-farewell.sh      SessionEnd フック本体（終了時に挨拶クリップを1回再生）
│   ├── statusline.sh            コンソール最下部に現在の状態を1行表示（settings.json の statusLine に登録して使う）
│   ├── speak-text.sh            任意のファイル/標準入力の文章をそのまま読み上げる手動コマンド（フックではない。Stop フックの要約・整形処理を一切通さない）
│   └── uninstall.sh             後始末コマンド（常駐通知・statusLine 登録・設定/鍵/ログ・Termux 側の残骸を削除。プラグイン本体の削除は Claude Code に任せる）
├── assets/
│   ├── overflow-notice.wav      「長文のため要約にします。」（上限超過時の断り）
│   ├── notify-permission-request.wav  「実行許可を求めています」
│   ├── notify-permission.wav    「実行許可の確認が待っています」
│   ├── notify-idle.wav          「入力を待っています」
│   ├── notify-generic.wav       「確認が必要です」
│   ├── recovery.wav             「読み上げ、直ったみたいよ。お待たせしちゃってごめんね」
│   ├── session-end.wav          「お疲れ様。またね。」（終了時の挨拶）
│   ├── summary-bridge.wav       要約読み上げの前置き
│   └── chunk-marker.wav         チャンク区切りのキュー音（確認用モードのときだけ鳴る）
└── README.md                   このファイル
```

`assets/*.wav` は、内容が固定の“決まり文句”を Gemini の良い声（Aoede、20歳くらいの明るいアナウンサー口調で生成）で**事前録音**した音声。実行時はオンデバイスの合成をせず、この WAV を `termux-media-player` で再生する（API キー不要・オフライン・エンジンを固まらせない）。詳細は [design.md](docs/design.md#決まり文句の事前録音音声) を参照。
