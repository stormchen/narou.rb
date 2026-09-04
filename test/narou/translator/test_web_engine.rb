# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "net/http"
require "uri"
require_relative "../../../lib/narou/translator/web_engine"

class TestWebEngine < Minitest::Test
  def setup
    @engine = Narou::Translator::WebEngine.new(
      chunk_size: 20,
      max_retries: 2,
      retry_delay: 0
    )
  end

  # ==========================================
  # 基本屬性測試
  # ==========================================

  def test_web_engine_initialization
    assert_equal 20, @engine.chunk_size
    assert_equal 2, @engine.max_retries
    assert_equal 0.0, @engine.retry_delay

    # 測試預設值
    default_engine = Narou::Translator::WebEngine.new
    assert_equal 2500, default_engine.chunk_size
    assert_equal 3, default_engine.max_retries
    assert_equal 2.0, default_engine.retry_delay
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
    response_body = [
      [
        ["這是第一句翻譯。", "これは最初の一文です。", nil, nil, 1],
        ["這是第二句翻譯。", "これは二番目の一文です。", nil, nil, 1]
      ],
      nil,
      "ja"
    ].to_json

    result = nil
    with_mock_http(lambda { |req|
      captured_request = req
      fake_http_response("200", response_body)
    }) do
      result = @engine.translate("これは最初の一文です。これは二番目の一文です。")
    end

    assert_equal "這是第一句翻譯。這是第二句翻譯。", result

    # 驗證 HTTP 請求為 GET 且包含 User-Agent
    assert_equal "GET", captured_request.method
    assert_includes captured_request["User-Agent"], "Mozilla/5.0"

    # 驗證 Query 參數
    uri = URI.parse("https://translate.googleapis.com#{captured_request.path}")
    query_params = URI.decode_www_form(uri.query).to_h
    assert_equal "gtx", query_params["client"]
    assert_equal "ja", query_params["sl"]
    assert_equal "zh-TW", query_params["tl"]
    assert_equal "t", query_params["dt"]
    assert_equal "これは最初の一文です。これは二番目の一文です。", query_params["q"]
  end

  def test_translate_multiple_chunks
    # WebEngine 內部預設切分長度為 1000
    # 建立一個超過 1000 字元且由多行構成的文字
    line = "これはとても長い文章のテストです。" * 20 + "\n"
    text = line * 4 # 約 1360+ 字元

    call_count = 0
    result = nil

    with_mock_http(lambda { |_req|
      call_count += 1
      response_body = [
        [["網頁翻譯區塊#{call_count}。", "原文", nil, nil, 1]],
        nil,
        "ja"
      ].to_json
      fake_http_response("200", response_body)
    }) do
      result = @engine.translate(text)
    end

    assert call_count >= 2, "超過 1000 字元應該分割成多個區塊進行請求"
    assert_includes result, "網頁翻譯區塊1。"
    assert_includes result, "網頁翻譯區塊2。"
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
        fake_http_response("429", "Too Many Requests")
      else
        response_body = [
          [["重試成功翻譯", "テスト", nil, nil, 1]],
          nil,
          "ja"
        ].to_json
        fake_http_response("200", response_body)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "重試成功翻譯", result
  end

  def test_translate_retry_on_network_exception_and_then_succeed
    attempts = 0
    result = nil

    with_mock_http(lambda { |_req|
      attempts += 1
      if attempts == 1
        raise Errno::ETIMEDOUT, "Connection timed out"
      else
        response_body = [
          [["超時重試後成功", "テスト", nil, nil, 1]],
          nil,
          "ja"
        ].to_json
        fake_http_response("200", response_body)
      end
    }) do
      result = @engine.translate("テスト")
    end

    assert_equal 2, attempts
    assert_equal "超時重試後成功", result
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
    assert_includes err.message, "Web translation failed after 3 attempts"
    assert_includes err.message, "503"
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
