# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "cgi"
require_relative "base"

module Narou
  module Translator
    class WebEngine < Base
      GOOGLE_API = "https://translate.googleapis.com/translate_a/single"
      attr_reader :retry_delay

      def initialize(options = {})
        super
        @retry_delay = (options[:retry_delay] || 2.0).to_f
      end

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
        query_string = URI.encode_www_form(params)
        uri = URI.parse("#{GOOGLE_API}?#{query_string}")

        retries = 0
        begin
          req = Net::HTTP::Get.new(uri.request_uri)
          req["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

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
          translated_text = parts.map { |p| p[0] }.join
          translated_text.strip
        rescue StandardError => e
          retries += 1
          if retries <= @max_retries
            sleep(retries * @retry_delay) if @retry_delay > 0
            retry
          else
            raise "Web translation failed after #{retries} attempts: #{e.message}"
          end
        end
      end
    end
  end
end
