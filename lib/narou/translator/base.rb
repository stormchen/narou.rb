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

        lines = text.scan(/.*?\n|.+$/)
        lines.each do |line|
          if line.length > max_length
            sub_lines = line.scan(/.{1,#{max_length}}(?:[。！？\n]|$)|.{1,#{max_length}}/)
            sub_lines.each do |sub_line|
              if (current.length + sub_line.length) > max_length && !current.empty?
                chunks << current
                current = +""
              end
              current << sub_line
            end
          else
            if (current.length + line.length) > max_length && !current.empty?
              chunks << current
              current = +""
            end
            current << line
          end
        end
        chunks << current unless current.empty?
        chunks
      end

      def system_prompt
        <<~PROMPT.strip
          你是一位精通日本網路小說（Web 小說、網文流派）的資深輕小說翻譯家。請將輸入的日文網文文本流暢地翻譯成【台灣正體中文 / 繁體中文（zh-TW）】。請嚴格遵守以下網文翻譯原則：

          【翻譯原則】：
          1. 文風要求：保持網路小說節奏明快、生動流暢的閱讀感。口語化對白要自然生動，避免死板生硬的機器翻譯腔。
          2. 系統與技能面板：網文中若出現角色屬性、技能、道具、系統提示音（如使用 【】、「」 標記的內容），請將專有名詞翻譯得具有遊戲與日系輕小說感（例如：將「経験値」譯為「經驗值」、「限界突破」譯為「突破極限」）。
          3. 人稱與語境補全：日文小說常省略主詞。請務必結合上下文脈絡，精確判斷說話者與受詞的關係，適時補全正確的人稱代詞（他/她/你/我），嚴禁男女主稱混淆。
          4. 網路與二次元梗：若遇到日本論壇梗、彈幕用語或中二病台詞，請轉化為台灣讀者熟悉的對應二次元網路用語。
          5. 標籤與格式保護（最高優先級）：
             - 文本中出現的所有 __TAG_...__ 格式佔位符為特殊系統標籤，必須原封不動完整保留在對應的中文位置，絕對不可修改、翻譯、刪除或自行增減。
             - 保留原始文本的段落換行、空格與排版結構。
          6. 輸出規範：僅輸出翻譯後的正體中文正文，絕對不要包含任何前言、後記、個人說明、問候或翻譯注釋。
        PROMPT
      end
    end
  end
end
