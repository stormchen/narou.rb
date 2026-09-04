# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "net/http"
require_relative "../../../lib/narou/translator/openai_engine"

class TestOpenAIEngine < Minitest::Test
  def setup
    @engine = Narou::Translator::OpenAIEngine.new(
      endpoint: "http://localhost:11434/v1",
      api_key: "test_key",
      model: "sakura-13b",
      chunk_size: 20,
      max_retries: 2,
      retry_delay: 0
    )
  end

  # ==========================================
  # Base 類別功能測試
  # ==========================================

  def test_base_defaults_and_options
    base = Narou::Translator::Base.new
    assert_equal 2500, base.chunk_size
    assert_equal 3, base.max_retries

    custom = Narou::Translator::Base.new(chunk_size: 1000, max_retries: 5)
    assert_equal 1000, custom.chunk_size
    assert_equal 5, custom.max_retries
  end

  def test_base_translate_raises_not_implemented
    base = Narou::Translator::Base.new
    assert_raises(NotImplementedError) do
      base.translate("こんにちは")
    end
  end

  def test_split_chunks_by_paragraph
    text = "第一段落內容。\n第二段落內容。\n第三段落內容。\n"
    chunks = @engine.split_chunks(text, 15)
    assert chunks.size >= 2
    assert_equal text, chunks.join
  end

  def test_split_chunks_single_line_exceeding_max_length
    text = "一" * 50
    chunks = @engine.split_chunks(text, 20)
    assert_equal [text], chunks
  end

  def test_split_chunks_empty_or_nil
    assert_equal [""], @engine.split_chunks("")
    assert_equal [""], @engine.split_chunks(nil)
  end

  def test_system_prompt_contains_requirements
    prompt = @engine.system_prompt
    assert_includes prompt, "繁體中文"
    assert_includes prompt, "__TAG_"
    assert_includes prompt, "台灣"
  end

  # ==========================================
  # OpenAIEngine 基本屬性與邊界測試
  # ==========================================

  def test_openai_engine_initialization
    assert_equal "http://localhost:11434/v1", @engine.endpoint
    assert_equal "test_key", @engine.api_key
    assert_equal "sakura-13b", @engine.model
    assert_equal 20, @engine.chunk_size
    assert_equal 2, @engine.max_retries

    # 測試 endpoint 結尾斜線過濾
    engine_with_slash = Narou::Translator::OpenAIEngine.new(endpoint: "https://api.openai.com/v1///")
    assert_equal "https://api.openai.com/v1", engine_with_slash.endpoint
  end

  def test_translate_empty_or_nil
    assert_equal "", @engine.translate("")
    assert_equal "", @engine.translate(nil)
    assert_equal "", @engine.translate("   \n\t  ")
  end

  # ==========================================
  # HTTP 模擬與請求組裝測試
  # ==========================================

  def test_translate_single_chunk_successful_request
    captured_request = nil
    response_body = {
      choices: [
        { message: { role: "assistant", content: "這是翻譯後的繁體中文。" } }
      ]
    }.to_json

    result = nil
    with_mock_http(lambda { |req|
      captured_request = req
      fake_http_response("200", response_body)
    }) do
      result = @engine.translate("これはテストです。")
    end

    assert_equal "這是翻譯後的繁體中文。", result

    # 驗證 HTTP 請求標頭與路徑
    assert_equal "/v1/chat/completions", captured_request.path
    assert_equal "application/json", captured_request["Content-Type"]
    assert_equal "Bearer test_key", captured_request["Authorization"]

    # 驗證 HTTP Payload
    payload = JSON.parse(captured_request.body)
    assert_equal "sakura-13b", payload["model"]
    assert_equal 0.3, payload["temperature"]
    assert_equal 2, payload["messages"].size
    assert_equal "system", payload["messages"][0]["role"]
    assert_includes payload["messages"][0]["content"], "繁體中文"
    assert_equal "user", payload["messages"][1]["role"]
    assert_equal "これはテストです。", payload["messages"][1]["content"]
  end

  def test_translate_multiple_chunks
    engine = Narou::Translator::OpenAIEngine.new(
      endpoint: "http://localhost:11434/v1",
      chunk_size: 10,
      retry_delay: 0
    )

    call_count = 0
    text = "第一行日文。\n第二行日文。\n第三行日文。\n"
    result = nil

    with_mock_http(lambda { |_req|
      call_count += 1
      fake_http_response("200", { choices: [{ message: { content: "片段#{call_count}。" } }] }.to_json)
    }) do
      result = engine.translate(text)
    end

    assert call_count >= 2, "應該分割成多個區塊進行請求"
    assert_includes result, "片段1。"
    assert_includes result, "片段2。"
  end

  # ==========================================
  # 重試機制與錯誤處理測試
  # ==========================================

  def test_translate_retry_on_server_error_and_then_succeed
    attempts = 0
    result = nil

    with_mock_http(lambda { |_req|
      attempts += 1
      if attempts == 1
        fake_http_response("500", "Internal Server Error")
      else
        fake_http_response("200", { choices: [{ message: { content: "成功翻譯" } }] }.to_json)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "成功翻譯", result
  end

  def test_translate_retry_on_network_exception_and_then_succeed
    attempts = 0
    result = nil

    with_mock_http(lambda { |_req|
      attempts += 1
      if attempts == 1
        raise Errno::ECONNREFUSED, "Connection refused"
      else
        fake_http_response("200", { choices: [{ message: { content: "連線成功後翻譯" } }] }.to_json)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "連線成功後翻譯", result
  end

  def test_translate_retry_exhausted_raises_error
    attempts = 0
    err = nil

    with_mock_http(lambda { |_req|
      attempts += 1
      fake_http_response("503", "Service Unavailable")
    }) do
      err = assert_raises(RuntimeError) do
        @engine.translate("テスト")
      end
    end

    # max_retries 為 2，加上第 1 次初始請求，共嘗試 3 次 (attempts == 3)
    assert_equal 3, attempts
    assert_includes err.message, "Translation failed after 3 attempts"
    assert_includes err.message, "503"
  end

  def test_translate_invalid_response_structure
    err = nil

    with_mock_http(lambda { |_req|
      fake_http_response("200", { error: "something wrong" }.to_json)
    }) do
      err = assert_raises(RuntimeError) do
        @engine.translate("テスト")
      end
    end

    assert_includes err.message, "Translation failed after 3 attempts"
    assert_includes err.message, "Invalid response structure"
  end

  private

  def with_mock_http(handler)
    original_request = Net::HTTP.instance_method(:request)
    Net::HTTP.define_method(:request) do |req, *args, &blk|
      handler.call(req)
    end
    yield
  ensure
    Net::HTTP.define_method(:request, original_request)
  end

  def fake_http_response(code, body)
    res = Net::HTTPResponse.send(:response_class, code).new("1.1", code, "Message")
    res.instance_variable_set(:@read, true)
    res.body = body
    res
  end
end
