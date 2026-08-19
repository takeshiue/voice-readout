#!/bin/bash
# voice-readout installer
set -eu

echo "Starting voice-readout environment setup..."

# 1. 共通環境のセットアップ（必要に応じて）
# 依存パッケージ(jq, curl, ffmpeg)などの確認もここで行えますが、
# 今回は agy ラッパーのインストールをメインに行います。

# 2. agy がインストールされているかチェック
if command -v agy >/dev/null 2>&1; then
    echo "[OK] 'agy' (Antigravity CLI) is installed."
    echo "Installing 'agys' wrapper to /usr/local/bin/agys ..."
    
    cat << 'WRAPPER_EOF' > /usr/local/bin/agys
#!/bin/bash
# agys - Antigravity CLI wrapper with Voice Readout

# 1. 起動時の挨拶を鳴らす（Claude Codeと同じ session-greet.sh を利用）
echo '{"source":"startup"}' | /root/dev/voice-readout/bin/session-greet.sh >/dev/null 2>&1

# 2. 本体を起動（ユーザーのチャットループ）
agy "$@"

# 3. 終了時の処理（/exit や Ctrl+D で抜けた場合）
/root/dev/voice-readout/bin/cancel.sh >/dev/null 2>&1
echo '{}' | /root/dev/voice-readout/bin/session-farewell.sh >/dev/null 2>&1
WRAPPER_EOF

    chmod +x /usr/local/bin/agys
    echo "[Success] 'agys' command installed successfully!"
    echo "You can now start Antigravity CLI with voice readout by running: agys"
else
    echo "[Skip] 'agy' (Antigravity CLI) is not found in PATH."
    echo "Skipping installation of 'agys' wrapper."
    echo "If you only use Claude Code or Codex, no further action is needed."
fi

echo "Setup complete."
