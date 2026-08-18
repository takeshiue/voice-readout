# Voice Readout - Developer & Agent Guidelines

このリポジトリ（`voice-readout`）は、AI CLI（Claude CLI, Codex, Antigravity CLI `agy`）の音声読み上げプラグイン/フック機能を提供します。

## 重要ドキュメント・設計方針

AI エージェントがこのリポジトリの改修や拡張を行う際は、以下の設計判断記録（ADR）を必ず参照してください。

- **[agy 対応および Python 一本化ロードマップ (ADR)](./docs/agy-design-and-python-migration.md)**
  - `agy`（Antigravity CLI）対応の設計方針。
  - 将来的な Windows `agy` 対応および、Bash/PowerShell 二重管理から **Python への一本化（クロスプラットフォーム統一）** に向けた段階的移行方針。
  - Windows での実行互換性（パス処理・UTF-8）を考慮した Python 部品化の指針。

## 基本アーキテクチャ概要

1. **フック層 (`hooks/`, `.claude-plugin/`, `.codex-plugin/`, `.agents/`)**
   - 各 CLI のライフサイクルイベント（`Stop`, `SessionStart`, `SessionEnd`, `PreToolUse` 等）を受け付ける。
   - `agy` などの同期実行フックでは、即座に応答（JSON `{}`）を返し、バックグラウンドワーカーに処理を委譲して CLI 操作をブロックしないこと。
2. **処理・抽出層 (`bin/`, Python コア)**
   - `transcript.jsonl` 等のログ解析、メッセージ抽出、マークダウン整形。
   - 将来の Python 統一を見据え、ロジックは Python モジュールとして実装・集約する。
3. **TTS / プラットフォーム制御層 (`bin/tts-lib.sh`, 将来の Python TTS モジュール)**
   - Android (Termux API / 通知バー停止スイッチ)、Windows (SAPI / PowerShell 停止ボタン)、クラウド TTS の排他制御およびキュー管理。
