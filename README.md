# Pinpix — 截圖標註工具（macOS）

取代 Skitch 的截圖標註 App。截圖後，編輯視窗**一定開在你目前的螢幕與桌面的最上層**，而且全程只用同一個視窗。

Pinpix 是選單列 App（才能在全螢幕 App 上截圖）。從「應用程式」、Launchpad 或選單列圖示打開會出現主面板，可以在那裡截圖、設定快捷鍵、自動複製、自動存檔、登入時啟動。編輯視窗左側是工具列，最下面是「顏色」和「粗細」兩個按鈕（點了才展開）。圖形、文字工具右下角有小三角形：已選中時再點一次，可以切換矩形／圓角矩形／橢圓／直線或文字效果。拖曳視窗上緣或浮動列的空白處可以移動視窗。

## 使用方式

| 動作 | 操作 |
|---|---|
| 截圖 | `⇧⌘2`（可在主面板更改）→ 拖曳選取範圍 / 點一下截取視窗 / `Esc` 或再按一次快捷鍵取消 |
| 箭頭 | `A`，按住 `⇧` 鎖定 45° |
| 圖形 | `R`，可切換矩形 / 圓角矩形 / 橢圓 / 直線，按住 `⇧` 畫正方形或正圓（直線則鎖定 45°） |
| 文字 | `T`；選取後：上方「a」一鍵切換描邊 / 醒目 / 一般，左右把手調整文字框寬度（自動換行），右下角縮放字級；`Enter` 完成，`⌥Enter` 換行，雙擊可重新編輯 |
| 畫筆 | `P` |
| 馬賽克 | `M`，框起來的範圍就會打上馬賽克 |
| 裁切 | `C`，框自動套在整張截圖上；拖曳四邊或四角往內裁、往外延伸（補設定的底色），也可在底部輸入寬高；`Enter` 套用、`Esc` 取消 |
| 調整截圖大小 | 點視窗左下角的尺寸 |
| 選取 / 移動 / 縮放 | 點物件就能選取，拖曳可移動，拖曳控制點可縮放；選取後改顏色、大小會直接套用到該物件 |
| 刪除 | `Delete` |
| 復原 / 重做 | `⌘Z` / `⇧⌘Z` |
| 複製 | `⌘C`（預設已經自動複製） |
| 另存新檔 | `⌘S`（PNG / JPEG） |
| 拖曳輸出 | 按住底部的「拖曳」，拖到其他 App 或桌面 |
| 貼上圖片來標註 | 在編輯視窗按 `⌘V` |

標註超出截圖時，畫布會立即延伸（底色預設白色，可在主面板改成黑色或透明），輸出的圖也會完整包含。截圖和每次修改標註後，結果都會**自動放進剪貼簿**，可以直接貼到 LINE、Slack 等 App。預設**不會存檔**；如果需要，可以在主面板打開「自動存檔到 圖片 › Pinpix」。

## 安裝

Pinpix 目前只提供原始碼，需要自己在 Mac 上編譯。步驟如下：

### 需求

- macOS 14 (Sonoma) 以上
- [Xcode](https://apps.apple.com/app/xcode/id497799835)（從 App Store 安裝，並至少打開一次完成初始設定）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`（沒有 Homebrew 請先到 [brew.sh](https://brew.sh) 安裝）

### 步驟

```bash
git clone https://github.com/juliahw1111/pinpix.git pinpix
cd pinpix
./Scripts/build.sh --install   # 建置並安裝到「應用程式」，完成後自動開啟
```

只想建置、不安裝的話，去掉 `--install`，產物在 `build/Pinpix.app`。

### 第一次使用

1. Pinpix 是選單列 App，開啟後看選單列的圖示，沒有 Dock 圖示。
2. 第一次截圖時，macOS 會詢問「螢幕錄製」權限，到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許 Pinpix，然後重新開啟 App。
3. `build.sh` 使用臨時簽章（不需要開發者帳號），所以每次重新建置後可能需要重新授權螢幕錄製。

### 常見問題

- **`xcodebuild` 要求 Xcode**：執行 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`。
- **找不到 `xcodegen`**：執行 `brew install xcodegen`。
- **建置失敗**：完整紀錄在 `build/xcodebuild.log`。

## 上架 Mac App Store

1. 加入 [Apple Developer Program](https://developer.apple.com/programs/)（US$99 / 年）。
2. 在 `project.yml` 填入 `DEVELOPMENT_TEAM`（你的 Team ID），並把 `PRODUCT_BUNDLE_IDENTIFIER` 改成你自己的（例如 `com.你的名字.pinpix`）。
3. 執行 `xcodegen generate`，然後用 Xcode 打開 `Pinpix.xcodeproj`。
4. 在 [App Store Connect](https://appstoreconnect.apple.com) 建立 App，填入相同的 Bundle ID。
5. 在 Xcode 依序執行 Product › Archive → Distribute App → App Store Connect。
6. 在 App Store Connect 填寫說明、截圖、隱私權政策網址（Pinpix 不收集任何資料），然後送審。

已經符合的上架要求：App Sandbox、Hardened Runtime、使用 ScreenCaptureKit 截圖（沒有呼叫私有 API 或外部指令）、App 圖示。

## 程式結構

- `Pinpix/App`：App 進入點、選單列圖示、全域快捷鍵
- `Pinpix/Capture`：截圖與選取範圍畫面
- `Pinpix/Editor`：標註模型與繪製、畫布互動、編輯視窗
- `Pinpix/Settings`：偏好設定
