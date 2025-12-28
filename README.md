# 鼠鬚管輸入法 - 雙拼增強版

> 基於 [rime/squirrel](https://github.com/rime/squirrel) 的功能增強版本

[](https://github.com/maplemusk/squirrel-double-pinyin/releases)
[![License](https://img.shields.io/badge/license-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0.html)
[![Original](https://img.shields.io/badge/forked%20from-rime%2Fsquirrel-green)](https://github.com/rime/squirrel)

---

## ✨ 新增功能

本版本在原版鼠鬚管基礎上新增：

- 🎹 **智能雙拼鍵位提示** - 獨立懸浮窗顯示雙拼鍵位參考
- 📚 **支持 7 種主流方案** - 小鶴、自然碼、微軟、搜狗、智能ABC、紫光、加加
- 🤖 **自動方案識別** - 根據當前輸入方案自動顯示對應鍵位
- ⚙️ **可配置開關** - 通過配置文件自由啟用/禁用

![功能演示](<img width="1063" height="541" alt="Hints-0001" src="https://github.com/user-attachments/assets/0f001cc4-0071-468e-a66a-9f1c05e2f49b" />
)
<img width="1117" height="553" alt="Hints-0002" src="https://github.com/user-attachments/assets/1906e4cc-8c39-49ac-9a39-85e806529ec7" />


<img width="1063" height="541" alt="Hints-0001" src="https://github.com/user-attachments/assets/0f882a83-f4ec-4166-a45b-8a63ea485825" />

---

## 📦 安裝

### 系統要求

- macOS 13.0 或更高版本

### 安裝步驟

1. 從 [Releases](https://github.com/maplemusk/squirrel-double-pinyin/releases/latest) 下載最新的 `.pkg` 安裝包
2. 雙擊安裝
3. **重要：** 安裝後請登出並重新登錄
4. 在「系統設定 → 鍵盤 → 文字輸入」中添加「鼠鬚管」

詳細安裝說明請參考 [用戶使用指南](docs/用戶使用指南.md)

---

## ⚙️ 配置雙拼提示功能

編輯 `~/Library/Rime/squirrel.custom.yaml`：

```yaml
patch:
  double_pinyin_hints:
    enabled: true  # 改為 false 可禁用
