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
          http.read_timeout = 600

          res = http.request(req)
          unless res.is_a?(Net::HTTPSuccess)
            raise "HTTP #{res.code}: #{res.body}"
          end

          data = JSON.parse(res.body)
          content = data.dig("choices", 0, "message", "content")
          raise "Invalid response structure: choices[0].message.content missing" if content.nil?

          content.strip
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
