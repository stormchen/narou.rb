# frozen_string_literal: true

module Narou
  module Translator
    class Base
      DEFAULT_CHUNK_SIZE = 1500
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
