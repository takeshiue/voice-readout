# voice-readout

Claude Code のやり取りを、画面を見なくても声で追えるようにするプラグイン。スマートフォン（Termux）での利用を前提にしている。

インストール直後から追加設定なしで喋る。オン/オフ・モード・声の切替は、すべてチャットで「〜して」と頼むだけ。

**このファイルは「入れて動かすまで」を扱う。**

- **[使い方](docs/usage.md)** — 入れたあと、日々の操作で見るところ（切替の頼み方・ステータスライン・調整値・故障時の対応）
- **[設計ノート](docs/design.md)** — なぜそういう作りなのか（実測値・設計の理由・エンジンごとの癖）。使うだけなら読まなくてよい

## もくじ

- [できること](#できること)
- [動作環境（構成）](#動作環境構成) — 入れる前に読む
- [インストール](#インストール)
- [更新のされ方](#更新のされ方入れる前に知っておくこと)
- [アンインストール](#アンインストール)
- [ファイル構成](#ファイル構成)

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

それぞれの操作方法は [使い方](docs/usage.md) にある。

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

> **`termux-*` 以外はすべて proot 側に要る**。フックが動くのが proot 側だからで、`jq` を Termux 側に入れても読み上げは動かない。

### 起動と利用の流れ

1. Termux を開く
2. proot-distro で Ubuntu に入る（例：`proot-distro login ubuntu`）
3. Ubuntu の中で Termux の bin に PATH を通す（`.bashrc` 等に入れておくと毎回不要）：
   ```sh
   export PATH="$PATH:/data/data/com.termux/files/usr/bin"
   ```
4. `claude` で Claude Code を起動する
5. あとは普通に会話するだけ。Claude の応答が終わるたびに声で読み上げ、許可確認・入力待ちも声で知らせる（追加設定なしで動く）

### Windows での利用

Windows PC 上で Claude Code を使う場合も、追加インストールなしで動く。

- **フックの実行環境**: Claude Code は Windows では Hooks の実行に Git for Windows 同梱の Git Bash を使う。GitHub を使っている開発者はほぼ必ず Git 本体を入れているので、これは特別な準備なしに揃っている前提でよい。
- **オンデバイス読み上げ**: Android の `termux-tts-speak` の代わりに、Windows 標準搭載の PowerShell 経由で SAPI（`System.Speech`）を使う。API キーも追加インストールも不要。
- **`jq`**: proot 側と違い、Windows には既定で入っていない。ただし**必須ではない**——`jq` が無ければ、フックが受け取る JSON の読み取りは PowerShell の `ConvertFrom-Json` に自動でフォールバックする（`bin/json-lib.sh`）。入れれば入れたで、そちらが優先して使われる。
- **ステータスライン**: `~/.claude/settings.json` への登録（`.statusLine` フィールド）だけは `jq` での書き換えを前提にしている。`jq` が無い環境では自動登録がスキップされ、`bin/doctor.sh` または `bin/statusline.sh --install` が手で追加すべき1行を表示するので、それを `settings.json` に足せばよい。

導入後に `bash bin/doctor.sh` を実行すると、host / commands の欄に Windows 固有の項目（PowerShell・cygpath の有無）が出るので、まず詰まっていないかはそこで確認できる。

## インストール

### 1. 前提を揃える

**Android / Termux 側**

- **Termux**（本体）
- **Termux:API アプリ**（Play ストア等からインストール。Android の音声合成・通知への仲介役）
- `termux-api` パッケージ（`pkg install termux-api`。`termux-tts-speak` 等を提供）

**Ubuntu (proot) 側**（Claude Code が動く層）

- **Claude Code**
- Termux の bin に PATH が通っていること（`export PATH="$PATH:/data/data/com.termux/files/usr/bin"`）
- 下記のコマンド類

必要なコマンドは使う機能によって変わる：

| コマンド | 入れ方 | いつ要るか | 無いとどうなるか |
|---|---|---|---|
| `jq` | `apt install jq` | **常に**（フックが受け取る JSON を読む） | 読み上げが動かない |
| `curl` | `apt install curl` | クラウドTTS（Gemini / Inworld / ElevenLabs）を使うとき | そのエンジンが失敗し、オンデバイスに落ちる |
| `ffmpeg` | `apt install ffmpeg` | **Gemini は必須**（返ってくる生 PCM を WAV に変換するため）。ElevenLabs の音量・速度調整、チャンクマーカーにも使う | Gemini が使えない。ElevenLabs は音量・速度調整だけ効かなくなる |
| `ffprobe` | `ffmpeg` に同梱 | クラウドのチャンク再生 | 継ぎ目に数秒の無音が入る |
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

### 2. プラグインを入れる

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

### 3. 動いたことを確認する

**フックは Claude Code の起動時に読み込まれるので、インストール後に一度再起動する。** 起動して「ボイスリードアウト、準備できたよ」と聞こえれば成功。聞こえない場合は [声が聞こえないとき](docs/usage.md#声が聞こえないとき) を参照。

インストール直後は追加設定なしで動く（要約モード・全読み上げオンがデフォルト）。ステータスラインも、この最初の起動で自動的に登録されて出る。

### 4. 推奨設定

バッテリー最適化でアプリがバックグラウンド終了されるとハングの原因になるため、**Termux:API と Google 音声サービスの両方を「バッテリー使用量→制限なし」に設定しておく**ことを推奨する（設定→アプリ→各アプリ→バッテリー使用量）。

クラウドの声（Gemini / Inworld / ElevenLabs / Fish Audio）を使いたい場合は、API キーの登録が要る → [設計ノート](docs/design.md#読み上げエンジンバックエンドの仕組み)。**キーの登録だけはチャットではなくターミナルで行うこと。** 登録は2通りある：

- コマンドで1行ずつ設定する：`bash bin/toggle.sh gemini-key <キー>`（他のサービスも同様、`bin/toggle.sh --help` 参照）
- ファイルを開いて直接貼り付ける：`bash bin/toggle.sh env-template` で雛形ファイルを作成し、表示されたパスをエディタで開いて `=` の後ろに貼り付けて保存する（既存のファイルは上書きしない）

## 更新のされ方（入れる前に知っておくこと）

**このプラグインのスクリプトは、セッションの開始・終了・応答のたびに自動で実行される。** フックとはそういう仕組みで、実行のたびに許可を求めたりはしない。つまり「どのコードが自分の端末で走るか」は、入れた時点ではなく**更新した時点**で決まる。

| 入れ方 | 更新のタイミング | 何が入るか |
|---|---|---|
| GitHub から（`marketplace add takeshiue/voice-readout`） | `claude plugin update voice-readout` を**自分で実行したとき**だけ（Claude Code の再起動で反映）。放っておけば入れた版のまま | 実行時点の**既定ブランチの最新**。特定のタグやバージョンに固定する仕組みは無い |
| ローカルのクローンを登録 | `git pull` した内容がそのまま次回起動から動く | 手元のブランチの内容 |

どちらも、更新すれば**その時点の新しいコードが以後すべてのセッションで自動実行される**。他人のリポジトリを追いかける以上、更新の前に差分を見るかどうかは各自の判断になる（`git log`／GitHub の compare で確認できる）。自分で書き換えて使う場合は、ローカル登録にしておけば「自分が読んだコードしか走らない」状態を保てる。

## アンインストール

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

アンインストールせず、溜まった音声の一時ファイルだけ消したい場合は [使い方](docs/usage.md#音声の一時ファイルを消す) を参照。

## ファイル構成

```
voice-readout/
├── hooks/hooks.json           SessionStart / SessionEnd / Stop / Notification フックの登録
├── bin/
│   ├── tts-lib.sh              読み上げ・通知・故障検知・TTSバックエンド切替の共通処理
│   ├── summarize-and-speak.sh  Stop フック本体（要約 or フル読み上げ）
│   ├── response-text.sh        応答テキストの整形（コードブロック/URL/記法の除去）。Stop フック各種が共有する
│   ├── notify-speak.sh         Notification フック本体（許可確認・入力待ち）
│   ├── recovery-watcher.sh     故障後、復旧を自動検知するウォッチャー
│   ├── toggle.sh               オン/オフ・モード・話速・バックエンド切替の設定変更コマンド
│   ├── readout-switch.sh       ストップスイッチ（全読み上げを黙らせる独立スイッチ。設定・環境変数を一切経由しない）
│   ├── session-start.sh        SessionStart フック本体（常駐通知を先に出し、そのあと挨拶を読み上げる順番の調整役）
│   ├── session-greet.sh        起動/再開時に挨拶を1回読み上げ、音が出るかを即確認する（session-start.sh から呼ばれる）
│   ├── session-farewell.sh     SessionEnd フック本体（終了時に挨拶クリップを1回再生）
│   ├── statusline.sh           コンソール最下部に現在の状態を1行表示（settings.json の statusLine に登録して使う）
│   ├── speak-text.sh           任意のファイル/標準入力の文章をそのまま読み上げる手動コマンド（フックではない）
│   └── uninstall.sh            後始末コマンド（常駐通知・statusLine 登録・設定/鍵/ログ・Termux 側の残骸を削除）
├── assets/                     決まり文句の事前録音音声（*.wav）
├── docs/
│   ├── usage.md                使い方（切替・ステータスライン・調整値・故障時の対応）
│   └── design.md               設計ノート（なぜそうなっているか・実測値）
└── README.md                   このファイル
```

`assets/*.wav` は、内容が固定の“決まり文句”を Gemini の良い声（Aoede）で**事前録音**した音声。実行時はオンデバイスの合成をせず、この WAV を `termux-media-player` で再生する（API キー不要・オフライン・エンジンを固まらせない）。詳細は [設計ノート](docs/design.md#決まり文句の事前録音音声) を参照。
