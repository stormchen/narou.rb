# Narou.rb 日翻繁體中文功能設計規格書 (Design Spec)

## 1. 概述 (Overview)

本規格定義如何在 Narou.rb 電子書轉換管線中新增「日文翻譯為繁體中文」之功能。本功能遵循 Narou.rb 既有模組化架構，採用適配器架構（Adapter Pattern）與管線截流設計，兼具「本地 AI 輕小說模型（如 Sakura / Ollama）」與「雲端現代大模型（如 DeepSeek / Gemini / OpenAI）」的無縫切換，並內建章節持久化快取與青空文庫排版標籤保護機制。

---

## 2. 系統架構 (Architecture)

### 2.1 模組劃分與檔案結構

於 `lib/narou/` 新增翻譯子系統：

```
lib/narou/
├── translator.rb               # 翻譯子系統入口與工廠（Factory）
└── translator/
    ├── base.rb                 # 翻譯引擎抽象基類（Base Engine）
    ├── openai_engine.rb        # OpenAI 相容協議引擎（對接 Sakura / Ollama / DeepSeek / vLLM）
    ├── gemini_engine.rb        # Google Gemini 原生 API 引擎
    ├── web_engine.rb           # 免費網頁端點引擎（備用降級方案）
    ├── cache_manager.rb        # 章節級持久化快取管理器
    └── tag_protector.rb        # 青空文庫標記保護器
```

並修改下列現有核心檔案：
- `lib/novelconverter.rb`：在章節轉換迴圈（`subtitles_to_sections`）與作品大綱（`toc`）處理中插入翻譯截流。
- `lib/novelsetting.rb`：註冊 `translate.*` 相關設定參數。
- `lib/command/setting.rb`：將翻譯設定變數納入 CLI 命令列管理介面。
- `lib/command/convert.rb`：擴充 `--translate`、`--no-translate`、`--retranslate` 命令列參數。

---

## 3. 詳細組件設計 (Component Specifications)

### 3.1 青空文庫標記保護器 (`Narou::Translator::TagProtector`)

#### 職責
防止 LLM 翻譯過程中破壞日文小說特殊的青空文庫語法、HTML 標記、插圖注記與 URL。

#### 保護規則
1. **青空注音標記（Ruby）**：
   - 格式：`｜漢字《ルビ》` 或 `漢字《ルビ》`
   - 處理：將標籤萃取並替換為 `__TAG_RUBY_N__` 佔位符，保留原文注音假名，翻譯完成後還原為 `｜[翻譯後漢字]《ルビ》`。
2. **青空排版標記（Chuki）**：
   - 格式：`［＃...］`（例如 `［＃改ページ］`、`［＃挿絵（...）入る］`）
   - 處理：替換為 `__TAG_CHUKI_N__`，翻譯結束後原樣還原。
3. **網址與自訂符號**：
   - 格式：`https?://...` 及外字碼
   - 處理：替換為 `__TAG_URL_N__`，翻譯結束後原樣還原。

#### 介面
- `encode(text)` -> `[encoded_text, tags_dictionary]`
- `decode(translated_text, tags_dictionary)` -> `restored_text`

---

### 3.2 翻譯引擎適配層 (`Narou::Translator::Engine`)

#### 3.2.1 抽象基類 (`Base`)
- `initialize(options)`
- `translate(text, context: {})` -> `String`
- `chunk_translate(text, chunk_size: 2500)` -> `String`（處理超長文本切分與拼接）

#### 3.2.2 OpenAI 相容引擎 (`OpenAIEngine`)
- **適用對象**：
  - 本地輕小說微調模型（如 Sakura-13B / 7B 經 llama.cpp / vLLM 暴露的 API）
  - 本地 Ollama 服務 (`http://localhost:11434/v1`)
  - 雲端服務（DeepSeek, OpenAI, Groq 等）
- **呼叫規格**：
  - HTTP POST `${endpoint}/chat/completions`
  - Headers: `Authorization: Bearer ${api_key}`, `Content-Type: application/json`
  - System Prompt：
    ```
    你是一位專業的日本輕小說繁體中文翻譯專家。
    請將輸入的日文輕小說文字翻譯為自然流暢、符合台灣閱讀習慣的繁體中文。
    保留所有 __TAG_...__ 佔位符不可更動、刪除或自行添加。
    僅輸出翻譯結果，不要包含任何前言、註釋或解釋。
    ```

#### 3.2.3 Gemini 引擎 (`GeminiEngine`)
- **適用對象**：Google AI Studio API (Gemini 1.5 Flash / Pro)。
- **呼叫規格**：
  - HTTP POST `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${api_key}`

#### 3.2.4 Web 引擎 (`WebEngine`)
- **適用對象**：免 API Key 的網頁端點（Google Translate / Bing 爬蟲逆向），作為快速體驗與備用方案。

---

### 3.3 章節持久化快取管理器 (`Narou::Translator::CacheManager`)

#### 職責
將翻譯後的章節儲存於磁碟，實現增量翻譯與斷點續傳。

#### 儲存規劃
- 存放路徑：小說存檔目錄下的 `translated_sections/`（例如 `novels/n1234ab/translated_sections/`）。
- 命名規則：與原始章節檔案一致（例如 `1 第一話.yaml`、`toc_translated.yaml`）。
- 快取資料格式（YAML）：
  ```yaml
  source_hash: "a3f5b7..."     # 日文原文內容 MD5
  engine: "openai"
  model: "sakura-13b"
  updated_at: "2026-09-04 21:45:00"
  data:
    chapter: "第一章 異世界生活"
    subtitle: "第一話 轉生與啟程"
    introduction: "..."
    body: "..."
    postscript: "..."
  ```

#### 命中與更新邏輯
1. 讀取章節時，計算原日文內容之 MD5。
2. 若快取存在且 `source_hash` 相符且未指定 `--retranslate`，直接讀取快取傳回。
3. 若快取不存在或原日文內容有更新，進行線上/本地翻譯並將成果寫入快取。

---

### 3.4 轉換管線整合 (`NovelConverter`)

在 `lib/novelconverter.rb` 內：
1. 在 `convert_main_for_novel` 中：
   - 翻譯 `toc["title"]`、`toc["story"]`。
2. 在 `subtitles_to_sections` 迴圈中：
   - 檢查並調用 `translator.translate_section(section)`。
   - 保證終端進度條（ProgressBar）可正確顯示翻譯與轉換進度。
3. 翻譯後的章節傳入原有 `ConverterBase` 進行後續青空文庫標準化處理（全形半形、引號處理、縮排、橫豎排支援等）。

---

## 4. 設定項目與命令列參數 (Configuration & CLI)

### 4.1 `setting.ini` 與 `narou setting`

| 設定名稱 | 型態 | 預設值 | 說明 |
| :--- | :--- | :--- | :--- |
| `translate.enable` | boolean | `false` | 是否啟用日翻繁體中文功能 |
| `translate.engine` | select (`openai`, `gemini`, `web`) | `openai` | 翻譯引擎類型 |
| `translate.endpoint` | string | `http://localhost:11434/v1` | API 端點 URL（支援本地或雲端） |
| `translate.api_key` | string | `""` | API 金鑰（本地服務可填任意值或留空） |
| `translate.model` | string | `sakura-13b` | 使用之模型識別代碼 |
| `translate.chunk_size` | integer | `2500` | 超長文本單次翻譯分塊字數限制 |
| `translate.max_retries`| integer | `3` | 網路或 API 呼叫失敗時重試次數 |

### 4.2 `narou convert` 參數擴充

- `--translate`：強制開啟翻譯（覆蓋目前設定）。
- `--no-translate`：強制關閉翻譯（覆蓋目前設定）。
- `--retranslate`：忽略既有快取，重新翻譯所有章節。

---

## 5. 錯誤處理與容錯機制 (Error Handling & Reliability)

1. **網路逾時與 Rate Limit**：
   - 遇到 HTTP 429 或 5xx、連線逾時時，使用指數退避（Exponential Backoff，1s, 2s, 4s）自動重試。
2. **斷點續傳保證**：
   - 每話翻譯完畢立即原子化儲存快取。若中途斷線或手動終止（Ctrl+C），再次執行 `narou convert` 會從未翻譯的話數繼續。
3. **佔位符保護校驗**：
   - 若模型回傳的文本中缺少相應的 `__TAG_...__` 佔位符，觸發告警並進行佔位符補救或記錄稽核日誌。

---

## 6. 驗證與測試計畫 (Verification Plan)

### 6.1 自動化單元測試 (RSpec)
- `spec/narou/translator/tag_protector_spec.rb`：青空語法、注音、插圖標籤替換與還原精確性。
- `spec/narou/translator/cache_manager_spec.rb`：快取寫入、雜湊比對、快取命中與失效。
- `spec/narou/translator/openai_engine_spec.rb`：模擬 API Request/Response、錯誤重試。

### 6.2 整合測試
- 建立一份含有注音假名、章節標題、前言與後記的日文測試章節。
- 執行 `narou convert`，確認：
  1. 成功生成繁體中文 EPUB/MOBI。
  2. 青空文庫標籤無毀損。
  3. `translated_sections/` 正常生成快取。
  4. 二次轉換秒速完成（命中快取）。
