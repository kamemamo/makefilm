# MakeFilm

ムービオラのように**フィルムが縦に流れる**、Mac 用のカット編集アプリです。
横に伸びるタイムラインの代わりに、35mm フィルムを手で回すような感覚で素材を見て、印を付け、継いでいきます。
細かい仕上げは Final Cut Pro / Premiere Pro / DaVinci Resolve に引き継げます。

*A Moviola-inspired rough-cut editor for macOS: footage runs vertically like 35mm film through a gate. Cut here, finish in Final Cut Pro, Premiere Pro or DaVinci Resolve.*

## 特長

- **縦に流れるフィルム** — 左のフィルムに送り穴（1コマ4つ）・秒目盛り・グリースペンシルの IN/OUT 印。ドラッグ／スクロールで手回し、惰性付き。流れる向きは「上へ」（標準）と「下へ」（ムービオラ式）を切り替え可能
- **ゲートとしてのビューア** — 映像の上下に前後のコマ、左右にパーフォレーションとエッジナンバー。再生中は映写機のように1コマずつ送られる
- **ペダル** — −4×〜4× の速度、逆再生、フレーム単位のコマ送り（AVFoundation のネイティブ再生）
- **スプライスとトリムビン** — IN/OUT を付けて継ぐと、カットが尺に比例した長さでビンに吊るされる。ドラッグで並べ替え、ゲート位置で切る・外す、取り消し／やり直し
- **書き出し**
  - ファイル: H.264 (MP4)、HEVC、Apple ProRes 422 / 4444、音声のみ (M4A)、静止画 (PNG)。サイズは元／4K／1080p／720p（縮小のみ）
  - 編集ソフトへ引き継ぎ: **FCPXML 1.10**（Final Cut Pro・DaVinci Resolve）、**Final Cut Pro 7 XML**（Premiere Pro・DaVinci Resolve）。元の素材を参照するので再エンコードなし。カメラ素材のタイムコードや 23.976 などの NTSC レートにも対応

## 動作環境

- macOS 14 Sonoma 以降
- ビルドに Xcode（Swift 5.10 以降）

## ビルドと起動

```bash
cd mac
./scripts/build-app.sh               # build/MakeFilm.app ができる
./scripts/build-app.sh --universal   # 配布用（Apple Silicon + Intel）
open build/MakeFilm.app
```

ビルド済みのアプリは [Releases](https://github.com/kamemamo/makefilm/releases) からもダウンロードできます。バージョンは `mac/Info.plist` の `CFBundleShortVersionString` で管理し、アプリのヘッダーにも表示されます。

開発中は `swift run` でも起動できます（`cd mac && swift run MakeFilm ../samples/sample.mp4`）。引数に動画ファイルを渡すと素材として読み込みます。

## 操作

| キー | 動作 |
|---|---|
| Space | 再生／停止 |
| J / K / L | 逆再生（押すたびに速く）／停止／再生（押すたびに速く） |
| ← → | 1 フレーム戻す／送る（Shift で 1 秒） |
| ↑ ↓ | フィルムを上／下に送る（流れの向きに追従） |
| I / O | IN／OUT の印 |
| Return | スプライス（IN〜OUT をリールに継ぐ） |
| C | ゲート位置でフィルムを切る（リール） |
| X / Delete | ゲート位置のカットを外す（リール） |
| 1 / 2 | 素材／リール表示の切り替え |
| ⌘O / ⌘E / ⌘Z | 素材を開く／書き出し／取り消し |

フィルム・ビューア上のドラッグやスクロールでも手回しできます。

## Final Cut Pro などへの引き継ぎ

1. 書き出し（⌘E）→「編集ソフトで続ける」から Final Cut Pro（FCPXML）または Premiere Pro（XML）を選ぶ
2. Final Cut Pro: ファイル → 読み込む → XML… ／ Premiere Pro: ファイル → 読み込み… ／ DaVinci Resolve: ファイル → 読み込み → タイムライン…

XML は元の素材ファイルを参照します。書き出したあとは素材を移動しないでください。

## 構成

```
mac/                     Mac アプリ（SwiftUI + AVFoundation, Swift Package）
  Sources/MakeFilm/      ソース
  scripts/build-app.sh   .app を組み立てるスクリプト
index.html               最初の Web 試作（ブラウザで開くだけで動く）
samples/sample.mp4       動作確認用のテスト映像（ffmpeg で生成したカラーバー）
```

## 配布について

`build-app.sh` で作った .app はアドホック署名です。他の Mac で開くと「開発元を確認できない」と表示されます（「システム設定 → プライバシーとセキュリティ」の「このまま開く」で起動できます）。警告なしで配布するには Apple Developer Program での署名と公証が必要です。

## 仕様書

画面・操作・データモデル・書き出し形式などの詳細は [docs/SPEC.md](docs/SPEC.md) にまとめています。

## ライセンス

[MIT](LICENSE)
