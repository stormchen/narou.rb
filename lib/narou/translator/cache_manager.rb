# frozen_string_literal: true

require "yaml"
require "fileutils"
require "digest/md5"

module Narou
  module Translator
    class CacheManager
      CACHE_DIR_NAME = "translated_sections"
      TOC_CACHE_NAME = "toc_translated.yaml"

      attr_reader :archive_path, :cache_dir

      def self.calculate_hash(content)
        Digest::MD5.hexdigest(content.to_s)
      end

      def initialize(archive_path)
        @archive_path = archive_path
        @cache_dir = File.join(@archive_path, CACHE_DIR_NAME)
        FileUtils.mkdir_p(@cache_dir)
      end

      def section_cache_path(index, subtitle)
        safe_subtitle = subtitle.to_s.gsub(%r{[\\/:*?"<>|]}, "_")
        File.join(@cache_dir, "#{index} #{safe_subtitle}.yaml")
      end

      def toc_cache_path
        File.join(@cache_dir, TOC_CACHE_NAME)
      end

      def get_section_cache(index, subtitle, source_hash)
        path = section_cache_path(index, subtitle)
        return nil unless File.exist?(path)

        data = load_yaml_file(path)
        return nil unless data.is_a?(Hash)
        valid_hashes = source_hash.is_a?(Array) ? source_hash : [source_hash]
        return nil unless valid_hashes.include?(data["source_hash"])

        data
      rescue StandardError
        nil
      end

      def save_section_cache(index, subtitle, source_hash, data, engine:, model:)
        path = section_cache_path(index, subtitle)
        record = {
          "source_hash" => source_hash,
          "engine" => engine,
          "model" => model,
          "updated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "data" => data
        }
        File.write(path, YAML.dump(record))
      end

      def get_toc_cache(source_hash)
        path = toc_cache_path
        return nil unless File.exist?(path)

        data = load_yaml_file(path)
        return nil unless data.is_a?(Hash)
        return nil if data["source_hash"] != source_hash

        data
      rescue StandardError
        nil
      end

      def save_toc_cache(source_hash, data, engine:, model:)
        path = toc_cache_path
        record = {
          "source_hash" => source_hash,
          "engine" => engine,
          "model" => model,
          "updated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
          "data" => data
        }
        File.write(path, YAML.dump(record))
      end

      private

      def load_yaml_file(path)
        if YAML.respond_to?(:unsafe_load_file)
          YAML.unsafe_load_file(path)
        else
          YAML.load_file(path)
        end
      end
    end
  end
end
