# Codexへのインストール

このリポジトリをローカルで開発している場合は、次の2コマンドでCodexへ登録する。

```sh
codex plugin marketplace add /このリポジトリの絶対パス
codex plugin add voice-readout@voice-readout
```

GitHubから導入する場合は、ローカルパスの代わりにリポジトリ名を渡す。

```sh
codex plugin marketplace add takeshiue/voice-readout
codex plugin add voice-readout@voice-readout
```

導入状態は次で確認できる。

```sh
codex plugin list
```

`voice-readout@voice-readout` が `installed, enabled` なら導入できている。初回またはフック定義を更新した後は、Codex内で`/hooks`を開き、voice-readoutのコマンドフックを確認して信頼する。フックを読み込むため、新しいCodexセッションを開始する。

Claude Code向けの導入手順とフック定義には影響しない。
