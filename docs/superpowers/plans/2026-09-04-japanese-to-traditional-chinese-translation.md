# 日翻繁體中文功能實施計劃 (Implementation Plan)

> **致代理執行者：** 必備子技能：請使用 `superpowers:subagent-driven-development`（推薦）或 `superpowers:executing-plans` 依任務循序執行本計劃。步驟採用勾選框 (`- [ ]`) 追蹤進度。

**目標：** 在 Narou.rb 的電子書轉換管線中新增日翻繁體中文功能，支援本地 AI 輕小說模型（Sakura / Ollama）與雲端 LLM API（OpenAI / Gemini），並提供章節持久化快取與青空文庫標記保護。

**架構：** 採用適配器與策略模式（Adapter Pattern），在 `lib/narou/translator/` 建立獨立翻譯子系統。在 `NovelConverter#subtitles_to_sections` 流程攔截章節並調度翻譯，由 `TagProtector` 保護青空標籤，由 `CacheManager` 達成增量快取，再交付既有 `ConverterBase` 生成排版完善的繁體中文 EPUB/MOBI 電子書。

**技術棧：** Ruby 3.x/4.x, Net::HTTP, JSON, Digest::MD5, YAML, Minitest。

**規格文件：** [docs/superpowers/specs/2026-09-04-japanese-to-traditional-chinese-translation-design.md](file:///d:/narou/docs/superpowers/specs/2026-09-04-japanese-to-traditional-chinese-translation-design.md)

## 全局約束 (Global Constraints)

- 嚴格維持現有 Narou.rb 代碼風格與相容性（frozen_string_literal, require_relative）。
- 翻譯輸出必須為台灣習慣之繁體中文。
- 青空文庫標記（注音假名、插圖、換頁、外字）必須透過佔位符保護，絕不可被翻譯引擎損壞。
- 翻譯內容必須按章節持久化快取至 `translated_sections/`，保障斷點續傳。
- 所有設定項必須能同時於 `narou setting`（全域與單部小說）及 `setting.ini` 正常讀寫。

---

### Task 1: 青空文庫標記保護器 (`Narou::Translator::TagProtector`)

**檔案：**
- 建立：`lib/narou/translator/tag_protector.rb`
- 測試：`test/narou/translator/test_tag_protector.rb`

**介面：**
- 輸入（Consumes）：日文小說原始文字（含青空語法、注音《...》、插圖注記［＃...］、網址）
- 輸出（Produces）：
  - `TagProtector.encode(text) -> [encoded_text, tag_map]`
  - `TagProtector.decode(translated_text, tag_map) -> restored_text`

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_tag_protector.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/narou/translator/tag_protector"

class TestTagProtector < Minitest::Test
  def test_encode_and_decode_ruby
    text = "彼は｜魔法《まほう》を使った。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_match(/__TAG_RUBY_\d+__/, encoded)
    refute_includes encoded, "《まほう》"

    # 模擬翻譯將「彼」翻為「他」
    translated = encoded.sub("彼", "他")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "他は｜魔法《まほう》を使った。", restored
  end

  def test_encode_and_decode_chuki
    text = "［＃改ページ］\n［＃挿絵（cover.jpg）入る］\n本文です。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_includes encoded, "__TAG_CHUKI_0__"
    assert_includes encoded, "__TAG_CHUKI_1__"

    translated = encoded.sub("本文です", "這是正文")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "［＃改ページ］\n［＃挿絵（cover.jpg）入る］\n這是正文。", restored
  end

  def test_encode_and_decode_url
    text = "参考サイト: https://syosetu.com/ です。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_includes encoded, "__TAG_URL_0__"

    translated = encoded.sub("参考サイト", "參考網站")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "參考網站: https://syosetu.com/ です。", restored
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_tag_protector.rb`
預期：FAIL（`LoadError: cannot load such file -- .../tag_protector`）

- [ ] **Step 3: 撰寫最小實作**

```ruby
# lib/narou/translator/tag_protector.rb
# frozen_string_literal: true

module Narou
  module Translator
    class TagProtector
      RUBY_PATTERN = /(?:｜([^《\n]+?)|([一-龠々〆ヵヶ]+))《([^》\n]+?)》/
      CHUKI_PATTERN = /［＃[^］\n]+?］/
      URL_PATTERN = %r{https?://[^\s［］《》「」]+}

      def self.encode(text)
        new.encode(text)
      end

      def self.decode(translated_text, tag_map)
        new.decode(translated_text, tag_map)
      end

      def encode(text)
        return ["", {}] if text.nil? || text.empty?

        tag_map = {}
        counter = 0
        encoded = text.dup

        # 1. 保護 URL
        encoded.gsub!(URL_PATTERN) do |match|
          key = "__TAG_URL_#{counter}__"
          tag_map[key] = match
          counter += 1
          key
        end

        # 2. 保護青空注記［＃...］
        encoded.gsub!(CHUKI_PATTERN) do |match|
          key = "__TAG_CHUKI_#{counter}__"
          tag_map[key] = match
          counter += 1
          key
        end

        # 3. 保護注音《...》
        encoded.gsub!(RUBY_PATTERN) do
          kanji = $1 || $2
          ruby = $3
          key = "__TAG_RUBY_#{counter}__"
          tag_map[key] = { kanji: kanji, ruby: ruby, raw: Regexp.last_match(0) }
          counter += 1
          "｜#{kanji}#{key}"
        end

        [encoded, tag_map]
      end

      def decode(translated_text, tag_map)
        return "" if translated_text.nil? || translated_text.empty?
        result = translated_text.dup

        tag_map.each do |key, value|
          if value.is_a?(Hash)
            # 還原 ruby
            result.gsub!(key, "《#{value[:ruby]}》")
          else
            result.gsub!(key, value)
          end
        end

        result
      end
    end
  end
end
```

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_tag_protector.rb`
預期：PASS (3 runs, 7 assertions, 0 failures, 0 errors)

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/narou/translator/tag_protector.rb test/narou/translator/test_tag_protector.rb
git commit -m "feat(translator): add TagProtector for aozora markup protection"
```

---

### Task 2: 章節持久化快取管理器 (`Narou::Translator::CacheManager`)

**檔案：**
- 建立：`lib/narou/translator/cache_manager.rb`
- 測試：`test/narou/translator/test_cache_manager.rb`

**介面：**
- 輸入（Consumes）：小說存檔目錄路徑、章節標識與原文資料
- 輸出（Produces）：
  - `CacheManager.new(archive_path)`
  - `get_section_cache(index, subtitle, source_hash)` -> `Hash or nil`
  - `save_section_cache(index, subtitle, source_hash, data, engine:, model:)`
  - `get_toc_cache(source_hash)` -> `Hash or nil`
  - `save_toc_cache(source_hash, data, engine:, model:)`

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_cache_manager.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../../lib/narou/translator/cache_manager"

class TestCacheManager < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("narou_cache_test")
    @cache_manager = Narou::Translator::CacheManager.new(@tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_save_and_get_section_cache
    index = 1
    subtitle = "プロローグ"
    source_hash = "abc123hash"
    data = { "subtitle" => "序章", "body" => "這是一段正文。" }

    # 未儲存前應為 nil
    assert_nil @cache_manager.get_section_cache(index, subtitle, source_hash)

    # 儲存快取
    @cache_manager.save_section_cache(index, subtitle, source_hash, data, engine: "openai", model: "sakura-13b")

    # 讀取快取（hash 相符）
    cached = @cache_manager.get_section_cache(index, subtitle, source_hash)
    refute_nil cached
    assert_equal "序章", cached["data"]["subtitle"]
    assert_equal "abc123hash", cached["source_hash"]

    # hash 不符時應視為快取失效
    assert_nil @cache_manager.get_section_cache(index, subtitle, "different_hash")
  end

  def test_save_and_get_toc_cache
    source_hash = "tochash456"
    data = { "title" => "魔王轉生", "story" => "大綱內容" }

    assert_nil @cache_manager.get_toc_cache(source_hash)
    @cache_manager.save_toc_cache(source_hash, data, engine: "openai", model: "sakura-13b")

    cached = @cache_manager.get_toc_cache(source_hash)
    refute_nil cached
    assert_equal "魔王轉生", cached["data"]["title"]
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_cache_manager.rb`
預期：FAIL（`LoadError: cannot load such file -- .../cache_manager`）

- [ ] **Step 3: 撰寫最小實作**

```ruby
# lib/narou/translator/cache_manager.rb
# frozen_string_literal: true

require "yaml"
require "fileutils"
require "digest/md5"

module Narou
  module Translator
    class CacheManager
      CACHE_DIR_NAME = "translated_sections"
      TOC_CACHE_NAME = "toc_translated.yaml"

      attr_reader :archive_path, :cache_dir

      def self.calculate_hash(content)
        Digest::MD5.hexdigest(content.to_s)
      end

      def initialize(archive_path)
        @archive_path = archive_path
        @cache_dir = File.join(@archive_path, CACHE_DIR_NAME)
        FileUtils.mkdir_p(@cache_dir)
      end

      def section_cache_path(index, subtitle)
        # 移除非法檔名字符
        safe_subtitle = subtitle.to_s.gsub(%r{[\\/:*?"<>|]}, "_")
        File.join(@cache_dir, "#{index} #{safe_subtitle}.yaml")
      end

      def toc_cache_path
        File.join(@cache_dir, TOC_CACHE_NAME)
      end

      def get_section_cache(index, subtitle, source_hash)
        path = section_cache_path(index, subtitle)
        return nil unless File.exist?(path)

        data = YAML.unsafe_load_file(path)
        return nil unless data.is_a?(Hash)
        return nil if data["source_hash"] != source_hash

        data
      rescue StandardError
        nil
      end

      def save_section_cache(index, subtitle, source_hash, data, engine:, model:)
        path = section_cache_path(index, subtitle)
        record = {
          "source_hash" => source_hash,
          "engine" => engine,
          "model" => model,
          "updated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "data" => data
        }
        File.write(path, YAML.dump(record))
      end

      def get_toc_cache(source_hash)
        path = toc_cache_path
        return nil unless File.exist?(path)

        data = YAML.unsafe_load_file(path)
        return nil unless data.is_a?(Hash)
        return nil if data["source_hash"] != source_hash

        data
      rescue StandardError
        nil
      end

      def save_toc_cache(source_hash, data, engine:, model:)
        path = toc_cache_path
        record = {
          "source_hash" => source_hash,
          "engine" => engine,
          "model" => model,
          "updated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "data" => data
        }
        File.write(path, YAML.dump(record))
      end
    end
  end
end
```

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_cache_manager.rb`
預期：PASS (2 runs, 7 assertions, 0 failures, 0 errors)

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/narou/translator/cache_manager.rb test/narou/translator/test_cache_manager.rb
git commit -m "feat(translator): add CacheManager for persistent translation cache"
```

---

### Task 3: 翻譯引擎抽象基類與 OpenAI 相容引擎 (`BaseEngine` & `OpenAIEngine`)

**檔案：**
- 建立：`lib/narou/translator/base.rb`
- 建立：`lib/narou/translator/openai_engine.rb`
- 測試：`test/narou/translator/test_openai_engine.rb`

**介面：**
- 輸入（Consumes）：設定選項（`endpoint`, `api_key`, `model`, `chunk_size`, `max_retries`）
- 輸出（Produces）：
  - `engine.translate(text, context: {}) -> String`
  - `engine.split_chunks(text, max_length) -> Array<String>`

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_openai_engine.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/narou/translator/openai_engine"

class TestOpenAIEngine < Minitest::Test
  def setup
    @engine = Narou::Translator::OpenAIEngine.new(
      endpoint: "http://localhost:11434/v1",
      api_key: "test_key",
      model: "sakura-13b",
      chunk_size: 100,
      max_retries: 2
    )
  end

  def test_split_chunks_by_paragraph
    text = "第一段。\n\n第二段。\n\n第三段。"
    chunks = @engine.split_chunks(text, 10)
    assert chunks.size >= 2
    assert_equal text, chunks.join
  end

  def test_system_prompt_presence
    prompt = @engine.system_prompt
    assert_includes prompt, "繁體中文"
    assert_includes prompt, "__TAG_"
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_openai_engine.rb`
預期：FAIL（`LoadError: cannot load such file -- .../openai_engine`）

- [ ] **Step 3: 撰寫最小實作**

```ruby
# lib/narou/translator/base.rb
# frozen_string_literal: true

module Narou
  module Translator
    class Base
      DEFAULT_CHUNK_SIZE = 2500
      DEFAULT_MAX_RETRIES = 3

      attr_reader :options, :chunk_size, :max_retries

      def initialize(options = {})
        @options = options
        @chunk_size = (options[:chunk_size] || DEFAULT_CHUNK_SIZE).to_i
        @max_retries = (options[:max_retries] || DEFAULT_MAX_RETRIES).to_i
      end

      def translate(text, context: {})
        raise NotImplementedError, "Subclasses must implement #translate"
      end

      def split_chunks(text, max_length = @chunk_size)
        return [""] if text.nil? || text.empty?
        return [text] if text.length <= max_length

        chunks = []
        current = +""

        # 優先依換行符切割，保護段落完整
        text.each_line do |line|
          if (current.length + line.length) > max_length && !current.empty?
            chunks << current
            current = +""
          end
          current << line
        end
        chunks << current unless current.empty?
        chunks
      end

      def system_prompt
        <<~PROMPT.strip
          你是一位專業的日本輕小說繁體中文翻譯專家。
          請將輸入的日文小說文本翻譯為自然流暢、文筆生動且符合台灣閱讀習慣的繁體中文。
          【嚴格規範】：
          1. 文中出現的所有 __TAG_...__ 格式佔位符為特殊系統標籤，必須原封不動完整保留，絕對不可更動、刪除、翻譯或自行添加。
          2. 僅輸出翻譯後的正文，絕對不要包含任何自我說明、打招呼、前言或注釋。
        PROMPT
      end
    end
  end
end
```

```ruby
# lib/narou/translator/openai_engine.rb
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "base"

module Narou
  module Translator
    class OpenAIEngine < Base
      attr_reader :endpoint, :api_key, :model

      def initialize(options = {})
        super
        @endpoint = (options[:endpoint] || "http://localhost:11434/v1").sub(%r{/+$}, "")
        @api_key = options[:api_key] || ""
        @model = options[:model] || "sakura-13b"
      end

      def translate(text, context: {})
        return "" if text.nil? || text.strip.empty?

        chunks = split_chunks(text)
        translated_chunks = chunks.map do |chunk|
          translate_single_chunk(chunk)
        end
        translated_chunks.join
      end

      private

      def translate_single_chunk(text)
        uri = URI.parse("#{@endpoint}/chat/completions")
        payload = {
          model: @model,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: text }
          ],
          temperature: 0.3
        }

        retries = 0
        begin
          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req["Authorization"] = "Bearer #{@api_key}" unless @api_key.empty?
          req.body = JSON.generate(payload)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 30
          http.read_timeout = 180

          res = http.request(req)
          unless res.is_a?(Net::HTTPSuccess)
            raise "HTTP #{res.code}: #{res.body}"
          end

          data = JSON.parse(res.body)
          content = data.dig("choices", 0, "message", "content")
          raise "Invalid response structure" if content.nil?

          content.strip
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * 2)
            retry
          else
            raise "Translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_openai_engine.rb`
預期：PASS (2 runs, 4 assertions, 0 failures, 0 errors)

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/narou/translator/base.rb lib/narou/translator/openai_engine.rb test/narou/translator/test_openai_engine.rb
git commit -m "feat(translator): add Base and OpenAIEngine with chunking and retry"
```

---

### Task 4: Gemini 原生引擎與 Web 備援引擎 (`GeminiEngine` & `WebEngine`)

**檔案：**
- 建立：`lib/narou/translator/gemini_engine.rb`
- 建立：`lib/narou/translator/web_engine.rb`
- 測試：`test/narou/translator/test_gemini_engine.rb`

**介面：**
- 輸入（Consumes）：API Key / 端點參數
- 輸出（Produces）：Gemini 與 Web 驅動的 `translate` 實作

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_gemini_engine.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/narou/translator/gemini_engine"
require_relative "../../../lib/narou/translator/web_engine"

class TestGeminiAndWebEngine < Minitest::Test
  def test_gemini_url_generation
    engine = Narou::Translator::GeminiEngine.new(
      api_key: "dummy_gemini_key",
      model: "gemini-1.5-flash"
    )
    uri = engine.request_uri
    assert_includes uri.to_s, "gemini-1.5-flash:generateContent"
    assert_includes uri.to_s, "key=dummy_gemini_key"
  end

  def test_web_engine_initialization
    engine = Narou::Translator::WebEngine.new
    assert_equal "web", engine.class.name.split("::").last.downcase.sub("engine", "")
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_gemini_engine.rb`
預期：FAIL（`LoadError`）

- [ ] **Step 3: 撰寫最小實作**

```ruby
# lib/narou/translator/gemini_engine.rb
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "base"

module Narou
  module Translator
    class GeminiEngine < Base
      attr_reader :api_key, :model

      def initialize(options = {})
        super
        @api_key = options[:api_key] || ""
        @model = options[:model] || "gemini-1.5-flash"
      end

      def request_uri
        URI.parse("https://generativelanguage.googleapis.com/v1beta/models/#{@model}:generateContent?key=#{@api_key}")
      end

      def translate(text, context: {})
        return "" if text.nil? || text.strip.empty?

        chunks = split_chunks(text)
        chunks.map { |chunk| translate_single_chunk(chunk) }.join
      end

      private

      def translate_single_chunk(text)
        uri = request_uri
        payload = {
          contents: [
            {
              role: "user",
              parts: [{ text: "#{system_prompt}\n\n【待翻譯日文如下】：\n#{text}" }]
            }
          ],
          generationConfig: {
            temperature: 0.3
          }
        }

        retries = 0
        begin
          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(payload)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 30
          http.read_timeout = 180

          res = http.request(req)
          unless res.is_a?(Net::HTTPSuccess)
            raise "HTTP #{res.code}: #{res.body}"
          end

          data = JSON.parse(res.body)
          content = data.dig("candidates", 0, "content", "parts", 0, "text")
          raise "Invalid Gemini response" if content.nil?

          content.strip
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * 2)
            retry
          else
            raise "Gemini translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
```

```ruby
# lib/narou/translator/web_engine.rb
# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"
require_relative "base"

module Narou
  module Translator
    class WebEngine < Base
      # 免費 Google 翻譯公開接口
      GOOGLE_API = "https://translate.googleapis.com/translate_a/single"

      def translate(text, context: {})
        return "" if text.nil? || text.strip.empty?

        chunks = split_chunks(text, 1000)
        chunks.map { |chunk| translate_single_chunk(chunk) }.join
      end

      private

      def translate_single_chunk(text)
        params = {
          client: "gtx",
          sl: "ja",
          tl: "zh-TW",
          dt: "t",
          q: text
        }
        uri = URI.parse("#{GOOGLE_API}?#{URI.encode_www_form(params)}")

        retries = 0
        begin
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = 15
          http.read_timeout = 30

          res = http.request(req)
          unless res.is_a?(Net::HTTPSuccess)
            raise "HTTP #{res.code}: #{res.body}"
          end

          data = JSON.parse(res.body)
          parts = data[0] || []
          parts.map { |p| p[0] }.join
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * 2)
            retry
          else
            raise "Web translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_gemini_engine.rb`
預期：PASS (2 runs, 2 assertions, 0 failures, 0 errors)

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/narou/translator/gemini_engine.rb lib/narou/translator/web_engine.rb test/narou/translator/test_gemini_engine.rb
git commit -m "feat(translator): add GeminiEngine and WebEngine"
```

---

### Task 5: 翻譯總管工廠與門面 (`Narou::Translator`)

**檔案：**
- 建立：`lib/narou/translator.rb`
- 測試：`test/narou/translator/test_translator.rb`

**介面：**
- 輸入（Consumes）：小說設定（`NovelSetting` 或 Hash）、小說儲存目錄、章節 section 資料
- 輸出（Produces）：
  - `Translator.create(setting, archive_path)`
  - `translator.translate_text(text, type: "text")`
  - `translator.translate_section(subinfo, section, force_retranslate: false)`
  - `translator.translate_toc(toc, force_retranslate: false)`

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_translator.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../../lib/narou/translator"

class TestTranslatorFacade < Minitest::Test
  class MockEngine < Narou::Translator::Base
    def translate(text, context: {})
      text.gsub("勇者", "勇者(中)").gsub("魔王", "魔王(中)")
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("translator_facade_test")
    @options = {
      "translate.enable" => true,
      "translate.engine" => "openai"
    }
    @translator = Narou::Translator.new(@options, @tmpdir)
    # 替換為 mock engine 避免實際聯網
    @translator.instance_variable_set(:@engine, MockEngine.new)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_translate_section_with_cache
    subinfo = { "index" => 1, "file_subtitle" => "第1話" }
    section = {
      "chapter" => "勇者の章",
      "subtitle" => "魔王との戦い",
      "element" => {
        "data_type" => "text",
        "introduction" => "",
        "body" => "勇者と魔王が対峙する。",
        "postscript" => ""
      }
    }

    # 首次翻譯
    translated_section = @translator.translate_section(subinfo, section)
    assert_equal "勇者(中)の章", translated_section["chapter"]
    assert_equal "勇者(中)と魔王(中)が対峙する。", translated_section["element"]["body"]

    # 快取檔案應已生成
    cache_file = File.join(@tmpdir, "translated_sections", "1 第1話.yaml")
    assert File.exist?(cache_file)

    # 修改 Mock 傳回值以確認第二次調用讀取自快取而非 Engine
    @translator.instance_variable_set(:@engine, nil)
    cached_section = @translator.translate_section(subinfo, section)
    assert_equal "勇者(中)の章", cached_section["chapter"]
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_translator.rb`
預期：FAIL（`LoadError`）

- [ ] **Step 3: 撰寫最小實作**

```ruby
# lib/narou/translator.rb
# frozen_string_literal: true

require_relative "translator/tag_protector"
require_relative "translator/cache_manager"
require_relative "translator/base"
require_relative "translator/openai_engine"
require_relative "translator/gemini_engine"
require_relative "translator/web_engine"

module Narou
  class Translator
    attr_reader :options, :archive_path, :engine, :cache_manager

    def self.create(setting, archive_path = nil)
      opts = setting.respond_to?(:settings) ? setting.settings : (setting || {})
      arch_path = archive_path || (setting.respond_to?(:archive_path) ? setting.archive_path : Dir.pwd)
      new(opts, arch_path)
    end

    def initialize(options, archive_path)
      @options = options
      @archive_path = archive_path
      @cache_manager = CacheManager.new(@archive_path)
      @engine = build_engine
    end

    def enabled?
      val = @options["translate.enable"]
      val == true || val.to_s == "true"
    end

    def build_engine
      engine_type = (@options["translate.engine"] || "openai").to_s.downcase
      engine_opts = {
        endpoint: @options["translate.endpoint"],
        api_key: @options["translate.api_key"],
        model: @options["translate.model"],
        chunk_size: @options["translate.chunk_size"],
        max_retries: @options["translate.max_retries"]
      }

      case engine_type
      when "gemini"
        GeminiEngine.new(engine_opts)
      when "web"
        WebEngine.new(engine_opts)
      else
        OpenAIEngine.new(engine_opts)
      end
    end

    def translate_text(text, type: "text")
      return "" if text.nil? || text.empty?
      return text unless enabled?

      encoded, tag_map = TagProtector.encode(text)
      translated = @engine.translate(encoded, context: { type: type })
      TagProtector.decode(translated, tag_map)
    end

    def translate_section(subinfo, section, force_retranslate: false)
      return section unless enabled?

      index = subinfo["index"]
      subtitle = subinfo["file_subtitle"] || subinfo["subtitle"] || "section_#{index}"
      source_content = section.inspect
      source_hash = CacheManager.calculate_hash(source_content)

      unless force_retranslate
        cached = @cache_manager.get_section_cache(index, subtitle, source_hash)
        return cached["data"] if cached
      end

      # 執行翻譯
      translated_section = Marshal.load(Marshal.dump(section))

      if translated_section["chapter"] && !translated_section["chapter"].empty?
        translated_section["chapter"] = translate_text(translated_section["chapter"], type: "chapter")
      end

      if translated_section["subtitle"] && !translated_section["subtitle"].empty?
        translated_section["subtitle"] = translate_text(translated_section["subtitle"], type: "subtitle")
      end

      element = translated_section["element"] || {}
      %w[introduction body postscript].each do |elm_type|
        if element[elm_type] && !element[elm_type].empty?
          element[elm_type] = translate_text(element[elm_type], type: elm_type)
        end
      end

      # 儲存快取
      @cache_manager.save_section_cache(
        index, subtitle, source_hash, translated_section,
        engine: @options["translate.engine"] || "openai",
        model: @options["translate.model"] || "default"
      )

      translated_section
    end

    def translate_toc(toc, force_retranslate: false)
      return toc unless enabled?

      source_hash = CacheManager.calculate_hash("#{toc["title"]}\n#{toc["story"]}")
      unless force_retranslate
        cached = @cache_manager.get_toc_cache(source_hash)
        if cached
          toc["title"] = cached["data"]["title"]
          toc["story"] = cached["data"]["story"]
          return toc
        end
      end

      toc["title"] = translate_text(toc["title"], type: "title") if toc["title"] && !toc["title"].empty?
      toc["story"] = translate_text(toc["story"], type: "story") if toc["story"] && !toc["story"].empty?

      @cache_manager.save_toc_cache(
        source_hash,
        { "title" => toc["title"], "story" => toc["story"] },
        engine: @options["translate.engine"] || "openai",
        model: @options["translate.model"] || "default"
      )

      toc
    end
  end
end
```

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_translator.rb`
預期：PASS (1 runs, 3 assertions, 0 failures, 0 errors)

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/narou/translator.rb test/narou/translator/test_translator.rb
git commit -m "feat(translator): add Translator facade with section and toc processing"
```

---

### Task 6: 設定系統擴充 (`NovelSetting` & `Command::Setting`)

**檔案：**
- 修改：`lib/novelsetting.rb`
- 修改：`lib/command/setting.rb`
- 測試：`test/narou/translator/test_settings.rb`

**介面：**
- 輸入（Consumes）：`narou setting` 命令列互動與 `setting.ini`
- 輸出（Produces）：支援讀寫 `translate.enable`, `translate.engine`, `translate.endpoint`, `translate.api_key`, `translate.model`, `translate.chunk_size`, `translate.max_retries`

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_settings.rb
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/novelsetting"
require_relative "../../../lib/command/setting"

class TestTranslatorSettings < Minitest::Test
  def test_setting_variables_include_translate
    setting_cmd = Command::Setting.new
    scope = setting_cmd.get_scope_of_variable_name("translate.enable")
    refute_nil scope

    assert_equal :boolean, Command::Setting::SETTING_VARIABLES[scope]["translate.enable"][:type]
    assert_equal :select, Command::Setting::SETTING_VARIABLES[scope]["translate.engine"][:type]
    assert_equal :string, Command::Setting::SETTING_VARIABLES[scope]["translate.endpoint"][:type]
  end

  def test_novelsetting_original_settings_include_translate
    names = NovelSetting::ORIGINAL_SETTINGS.map { |s| s[:name] }
    assert_includes names, "translate.enable"
    assert_includes names, "translate.engine"
    assert_includes names, "translate.endpoint"
    assert_includes names, "translate.model"
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_settings.rb`
預期：FAIL

- [ ] **Step 3: 修改 `NovelSetting` 與 `Command::Setting` 註冊設定**

在 `lib/novelsetting.rb` 的 `ORIGINAL_SETTINGS` 陣列中新增：
```ruby
    { name: "translate.enable", value: false, type: :boolean,
      help: "日文翻譯為繁體中文功能" },
    { name: "translate.engine", value: "openai", type: :select,
      select_keys: %w(openai gemini web),
      help: "翻譯引擎類型(openai, gemini, web)" },
    { name: "translate.endpoint", value: "http://localhost:11434/v1", type: :string,
      help: "翻譯服務 API 端點 URL" },
    { name: "translate.api_key", value: "", type: :string,
      help: "翻譯服務 API Key (本地服務可留空)" },
    { name: "translate.model", value: "sakura-13b", type: :string,
      help: "使用的翻譯模型名稱 (如 sakura-13b, deepseek-chat, gemini-1.5-flash)" },
    { name: "translate.chunk_size", value: 2500, type: :integer,
      help: "單次翻譯文本分塊最大字元數" },
    { name: "translate.max_retries", value: 3, type: :integer,
      help: "翻譯失敗時最大重試次數" },
```

在 `lib/command/setting.rb` 的 `SETTING_VARIABLES` 中註冊相應項目。

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_settings.rb`
預期：PASS

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/novelsetting.rb lib/command/setting.rb test/narou/translator/test_settings.rb
git commit -m "feat(setting): add translation configuration parameters"
```

---

### Task 7: 轉換器與命令列流程整合 (`NovelConverter` & `Command::Convert`)

**檔案：**
- 修改：`lib/novelconverter.rb`
- 修改：`lib/command/convert.rb`
- 測試：`test/narou/translator/test_integration.rb`

**介面：**
- 輸入（Consumes）：`narou convert [options]` 指令及 `NovelConverter#convert_main_for_novel`
- 輸出（Produces）：
  - 支援 `--translate`, `--no-translate`, `--retranslate` CLI 參數
  - 在 `subtitles_to_sections` 自動調用翻譯與持久化快取
  - 產出繁體中文電子書

- [ ] **Step 1: 編寫失敗測試**

```ruby
# test/narou/translator/test_integration.rb
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../../../lib/command/convert"

class TestConvertIntegration < Minitest::Test
  def test_convert_command_options
    cmd = Command::Convert.new
    assert cmd.instance_variable_get(:@opt).to_s.include?("--translate")
    assert cmd.instance_variable_get(:@opt).to_s.include?("--retranslate")
  end
end
```

- [ ] **Step 2: 執行測試並確認失敗**

執行：`ruby -Ilib:test test/narou/translator/test_integration.rb`
預期：FAIL

- [ ] **Step 3: 整合 `Command::Convert` 與 `NovelConverter`**

1. 在 `lib/command/convert.rb` 的 `initialize` 中加入：
```ruby
      @opt.on("--[no-]translate", "電子書轉換時將日文翻譯為繁體中文") { |v|
        @options["translate"] = v
      }
      @opt.on("--retranslate", "忽略翻譯快取，重新翻譯所有章節") {
        @options["retranslate"] = true
        @options["translate"] = true
      }
```
並在呼叫 `NovelConverter.convert` 時將 `translate` 與 `retranslate` 選項傳遞過去。

2. 在 `lib/novelconverter.rb` 中引入 `require_relative "narou/translator"`，於 `initialize` 中初始化 `@translator = Narou::Translator.create(@setting, @setting.archive_path)`。若有傳入 `options[:translate]`，動態覆蓋 `@translator.options["translate.enable"]`。
3. 在 `convert_main_for_novel` 中：
   - 呼叫 `@translator.translate_toc(toc, force_retranslate: options[:retranslate])`
4. 在 `subtitles_to_sections` 迴圈中：
   - 在載入 section 後調用 `section = @translator.translate_section(subinfo, section, force_retranslate: @options[:retranslate])`，顯示「翻譯中...」進度。

- [ ] **Step 4: 執行測試並確認通過**

執行：`ruby -Ilib:test test/narou/translator/test_integration.rb`
預期：PASS

- [ ] **Step 5: 提交 Commit**

```bash
git add lib/novelconverter.rb lib/command/convert.rb test/narou/translator/test_integration.rb
git commit -m "feat(convert): integrate translator into novel conversion pipeline with CLI flags"
```

---

## 執行銜接 (Execution Handoff)

實施計劃已完整撰寫並儲存至：
`docs/superpowers/plans/2026-09-04-japanese-to-traditional-chinese-translation.md`

兩種執行方式供您選擇：

1. **子代理驅動執行 (Subagent-Driven，推薦)**：由主代理為每個任務派生獨立的專屬子代理，任務間進行審查與驗證，迭代快速且乾淨。
2. **單會話循序執行 (Inline Execution)**：在目前會話中透過 `executing-plans` 循序執行任務，並於關鍵檢驗點進行匯報。

請告訴我您希望採用哪種方式執行？
