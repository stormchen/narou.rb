# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "base"

module Narou
  module Translator
    class GeminiEngine < Base
      attr_reader :api_key, :model, :retry_delay

      def initialize(options = {})
        super
        @api_key = options[:api_key] || ""
        @model = options[:model] || "gemini-1.5-flash"
        @retry_delay = (options[:retry_delay] || 2.0).to_f
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
          raise "Invalid Gemini response structure: missing text" if content.nil?

          content.strip
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * @retry_delay) if @retry_delay > 0
            retry
          else
            raise "Gemini translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
