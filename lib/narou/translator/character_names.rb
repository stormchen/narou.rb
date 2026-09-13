# frozen_string_literal: true

require "yaml"
require "fileutils"
require_relative "levenshtein"

module Narou
  module Translator
    class CharacterNames
      FILENAME = "character_names.yaml"
      
      attr_reader :archive_path, :characters
      
      def initialize(archive_path)
        @archive_path = archive_path
        @characters = []
      end
      
      def file_path
        File.join(@archive_path, FILENAME)
      end
      
      def load
        if File.exist?(file_path)
          data = load_yaml_file(file_path)
          @characters = data["characters"] || []
        else
          @characters = []
        end
        self
      rescue StandardError
        @characters = []
        self
      end
      
      def save
        File.write(file_path, YAML.dump({ "characters" => @characters }))
      end
      
      def any?
        @characters.any?
      end
      
      def prompt_fragment
        return "" unless any?

        lines = ["【角色名稱對照表】：", "翻譯時請嚴格按照以下對照表使用角色名稱，不得自行變更："]
        @characters.each do |char|
          lines << "#{char["original"]} → #{char["translation"]}"
        end
        lines.join("\n") + "\n"
      end
      
      def replacement_pairs
        pairs = []
        @characters.each do |char|
          correct = char["translation"].to_s.strip
          next if correct.empty?
          (char["alternatives"] || []).each do |wrong|
            w = wrong.to_s.strip
            next if w.empty? || w == correct
            pairs << [w, correct]
          end
        end
        pairs.uniq.sort_by { |wrong, _| -wrong.length }
      end
      
      def apply_replacements(text)
        return text if text.nil? || text.empty?
        pairs = replacement_pairs
        return text if pairs.empty?

        dict = pairs.to_h
        pattern = Regexp.union(dict.keys.map { |k| Regexp.new(Regexp.escape(k)) })
        text.gsub(pattern, dict)
      end
      
      def scan_inconsistencies
        cache_dir = File.join(@archive_path, "translated_sections")
        return {} unless Dir.exist?(cache_dir)

        target_translations = @characters.map { |c| c["translation"] }.compact.reject(&:empty?)
        return {} if target_translations.empty?

        known_alternatives = @characters.each_with_object({}) do |c, h|
          h[c["translation"]] = (c["alternatives"] || [])
        end

        needed_lengths = target_translations.flat_map do |t|
          len = t.chars.length
          [len - 1, len, len + 1]
        end.select { |l| l >= 2 }.uniq

        candidates = Hash.new { |h, k| h[k] = Hash.new(0) }

        Dir.glob(File.join(cache_dir, "*.yaml")).each do |path|
          next if path.end_with?("toc_translated.yaml")

          data = load_yaml_file(path)
          next unless data.is_a?(Hash) && data["data"].is_a?(Hash)

          texts = extract_texts_from_cache(data["data"])
          texts.each do |text|
            terms = extract_chinese_terms(text, needed_lengths)
            terms.each do |term|
              target_translations.each do |target|
                next if term == target
                next if term.include?(target)
                next if known_alternatives[target]&.include?(term)

                if Levenshtein.distance(term, target) == 1
                  candidates[target][term] += 1
                end
              end
            end
          end
        end

        result = {}
        candidates.each do |target, variants|
          next if variants.empty?
          result[target] = variants.map { |v, count| { variant: v, count: count } }.sort_by { |v| -v[:count] }
        end

        result
      end
      
      def apply_to_cache
        cache_dir = File.join(@archive_path, "translated_sections")
        return 0 unless Dir.exist?(cache_dir)
        
        modified_count = 0
        pairs = replacement_pairs
        return 0 if pairs.empty?
        
        Dir.glob(File.join(cache_dir, "*.yaml")).each do |path|
          next if path.end_with?("toc_translated.yaml")
          
          data = load_yaml_file(path)
          next unless data.is_a?(Hash) && data["data"].is_a?(Hash)
          
          changed = false
          cache_data = data["data"]
          
          ["chapter", "subtitle"].each do |key|
            if cache_data[key]
              new_val = apply_replacements(cache_data[key])
              if new_val != cache_data[key]
                cache_data[key] = new_val
                changed = true
              end
            end
          end
          
          if cache_data["element"]
            ["introduction", "body", "postscript"].each do |key|
              if cache_data["element"][key]
                new_val = apply_replacements(cache_data["element"][key])
                if new_val != cache_data["element"][key]
                  cache_data["element"][key] = new_val
                  changed = true
                end
              end
            end
          end
          
          if changed
            File.write(path, YAML.dump(data))
            modified_count += 1
          end
        end
        
        modified_count
      end
      
      private
      
      def load_yaml_file(path)
        if YAML.respond_to?(:unsafe_load_file)
          YAML.unsafe_load_file(path)
        else
          YAML.load_file(path)
        end
      end
      
      def extract_texts_from_cache(data)
        texts = []
        texts << data["chapter"] if data["chapter"]
        texts << data["subtitle"] if data["subtitle"]
        if data["element"]
          texts << data["element"]["introduction"] if data["element"]["introduction"]
          texts << data["element"]["body"] if data["element"]["body"]
          texts << data["element"]["postscript"] if data["element"]["postscript"]
        end
        texts
      end
      
      def extract_chinese_terms(text, lengths = [2, 3, 4])
        return [] if text.nil? || text.empty?
        valid_lengths = lengths.select { |l| l >= 2 }.uniq
        return [] if valid_lengths.empty?

        terms = []
        text.to_s.scan(/\p{Han}+/) do |chunk|
          chars = chunk.chars
          chunk_len = chars.length
          valid_lengths.each do |target_len|
            next if chunk_len < target_len
            (0..(chunk_len - target_len)).each do |i|
              terms << chars[i, target_len].join
            end
          end
        end
        terms
      end
    end
  end
end
