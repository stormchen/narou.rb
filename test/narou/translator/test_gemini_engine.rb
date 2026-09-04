# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "net/http"
require_relative "../../../lib/narou/translator/gemini_engine"

class TestGeminiEngine < Minitest::Test
  def setup
    @engine = Narou::Translator::GeminiEngine.new(
      api_key: "test_gemini_key",
      model: "gemini-1.5-flash",
      chunk_size: 20,
      max_retries: 2,
      retry_delay: 0
    )
  end

  # ==========================================
  # 基本屬性與 URI 組裝測試
  # ==========================================

  def test_gemini_engine_initialization
    assert_equal "test_gemini_key", @engine.api_key
    assert_equal "gemini-1.5-flash", @engine.model
    assert_equal 20, @engine.chunk_size
    assert_equal 2, @engine.max_retries
    assert_equal 0.0, @engine.retry_delay

    # 測試預設值
    default_engine = Narou::Translator::GeminiEngine.new
    assert_equal "", default_engine.api_key
    assert_equal "gemini-1.5-flash", default_engine.model
    assert_equal 2500, default_engine.chunk_size
    assert_equal 3, default_engine.max_retries
    assert_equal 2.0, default_engine.retry_delay
  end

  def test_request_uri
    uri = @engine.request_uri
    assert_equal "generativelanguage.googleapis.com", uri.host
    assert_equal "/v1beta/models/gemini-1.5-flash:generateContent", uri.path
    assert_equal "key=test_gemini_key", uri.query

    custom_engine = Narou::Translator::GeminiEngine.new(
      api_key: "custom_key_123",
      model: "gemini-1.5-pro"
    )
    custom_uri = custom_engine.request_uri
    assert_equal "/v1beta/models/gemini-1.5-pro:generateContent", custom_uri.path
    assert_equal "key=custom_key_123", custom_uri.query
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
      candidates: [
        {
          content: {
            parts: [
              { text: "這是 Gemini 翻譯後的繁體中文。" }
            ]
          }
        }
      ]
    }.to_json

    result = nil
    with_mock_http(lambda { |req|
      captured_request = req
      fake_http_response("200", response_body)
    }) do
      result = @engine.translate("これはテストです。")
    end

    assert_equal "這是 Gemini 翻譯後的繁體中文。", result

    # 驗證 HTTP 請求標頭與路徑
    assert_equal "/v1beta/models/gemini-1.5-flash:generateContent?key=test_gemini_key", captured_request.path
    assert_equal "application/json", captured_request["Content-Type"]

    # 驗證 HTTP Payload
    payload = JSON.parse(captured_request.body)
    assert_equal 0.3, payload["generationConfig"]["temperature"]
    assert_equal 1, payload["contents"].size
    assert_equal "user", payload["contents"][0]["role"]

    prompt_text = payload["contents"][0]["parts"][0]["text"]
    assert_includes prompt_text, "繁體中文"
    assert_includes prompt_text, "【待翻譯日文如下】：\nこれはテストです。"
  end

  def test_translate_multiple_chunks
    engine = Narou::Translator::GeminiEngine.new(
      api_key: "test_key",
      chunk_size: 10,
      retry_delay: 0
    )

    call_count = 0
    text = "第一行日文。\n第二行日文。\n第三行日文。\n"
    result = nil

    with_mock_http(lambda { |_req|
      call_count += 1
      response_body = {
        candidates: [
          { content: { parts: [{ text: "Gemini片段#{call_count}。" }] } }
        ]
      }.to_json
      fake_http_response("200", response_body)
    }) do
      result = engine.translate(text)
    end

    assert call_count >= 2, "應該分割成多個區塊進行請求"
    assert_includes result, "Gemini片段1。"
    assert_includes result, "Gemini片段2。"
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
        response_body = {
          candidates: [
            { content: { parts: [{ text: "重試後成功翻譯" }] } }
          ]
        }.to_json
        fake_http_response("200", response_body)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "重試後成功翻譯", result
  end

  def test_translate_retry_on_network_exception_and_then_succeed
    attempts = 0
    result = nil

    with_mock_http(lambda { |_req|
      attempts += 1
      if attempts == 1
        raise Errno::ECONNRESET, "Connection reset by peer"
      else
        response_body = {
          candidates: [
            { content: { parts: [{ text: "連線重置後重試成功" }] } }
          ]
        }.to_json
        fake_http_response("200", response_body)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "連線重置後重試成功", result
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
    assert_includes err.message, "Gemini translation failed after 3 attempts"
    assert_includes err.message, "503"
  end

  def test_translate_invalid_response_structure_missing_text
    err = nil

    with_mock_http(lambda { |_req|
      fake_http_response("200", { candidates: [] }.to_json)
    }) do
      err = assert_raises(RuntimeError) do
        @engine.translate("テスト")
      end
    end

    assert_includes err.message, "Gemini translation failed after 3 attempts"
    assert_includes err.message, "Invalid Gemini response structure: missing text"
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
