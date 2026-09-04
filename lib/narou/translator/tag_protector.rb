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
        return translated_text.dup if tag_map.nil? || tag_map.empty?

        result = translated_text.dup

        tag_map.each do |key, value|
          if value.is_a?(Hash)
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
