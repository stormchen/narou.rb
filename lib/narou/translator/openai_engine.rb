# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "base"

module Narou
  module Translator
    class OpenAIEngine < Base
      attr_reader :endpoint, :api_key, :model, :retry_delay

      def initialize(options = {})
        super
        @endpoint = (options[:endpoint] || "http://localhost:11434/v1").to_s.sub(%r{/+$}, "")
        @api_key = options[:api_key] || ""
        @model = options[:model] || "sakura-13b"
        @retry_delay = options.key?(:retry_delay) ? options[:retry_delay].to_f : 2.0
        is_sakura = @model.to_s.downcase.include?("sakura")
        if is_sakura
          user_chunk_size = options[:chunk_size].to_i
          @chunk_size = (user_chunk_size > 0 && user_chunk_size != DEFAULT_CHUNK_SIZE) ? user_chunk_size : 600
        else
          @chunk_size = (options[:chunk_size] || DEFAULT_CHUNK_SIZE).to_i
        end
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

      def build_messages(text)
        if @model.to_s.downcase.include?("sakura")
          [
            { role: "system", content: "你是一个轻小说翻译模型，可以流畅通顺地以日本轻小说的风格将日文翻译成繁体中文，并联系上下文正确使用词汇。保留所有__TAG_开头的特殊标记。" },
            { role: "user", content: "将下面的日文文本翻译成繁体中文：\n#{text}" }
          ]
        else
          [
            { role: "system", content: system_prompt },
            { role: "user", content: text }
          ]
        end
      end

      def translate_single_chunk(text)
        uri = URI.parse("#{@endpoint}/chat/completions")
        is_sakura = @model.to_s.downcase.include?("sakura")
        max_tokens = [[(text.length * 3).ceil + 256, 512].max, 4096].min
        payload = {
          model: @model,
          messages: build_messages(text),
          temperature: is_sakura ? 0.1 : 0.3,
          max_tokens: max_tokens
        }
        payload[:frequency_penalty] = 0.2 if is_sakura

        retries = 0
        begin
          req = Net::HTTP::Post.new(uri.request_uri)
          req["Content-Type"] = "application/json"
          req["Authorization"] = "Bearer #{@api_key}" unless @api_key.empty?
          req.body = JSON.generate(payload)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = (uri.scheme == "https")
          http.open_timeout = 30
          http.read_timeout = 300

          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          res = http.request(req)
          t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          unless res.is_a?(Net::HTTPSuccess)
            raise "HTTP #{res.code}: #{res.body}"
          end

          data = JSON.parse(res.body)
          content = data.dig("choices", 0, "message", "content")
          raise "Invalid response structure: choices[0].message.content missing" if content.nil?

          cleaned = content.strip
          # 過濾連續單一字符異常重複（例如連續超過10個相同字符）
          cleaned = cleaned.gsub(/(.)\1{9,}/, '\1')
          # 過濾長度在 6~300 字元之間的子字串連續循環重複（重複3次以上時截斷為保留1次）
          cleaned.gsub(/(.{6,300}?)\1{2,}/m, '\1')
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * @retry_delay) if @retry_delay.positive?
            retry
          else
            raise "Translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
