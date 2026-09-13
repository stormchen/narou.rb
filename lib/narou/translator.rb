# frozen_string_literal: true

require_relative "translator/tag_protector"
require_relative "translator/character_names"
require_relative "translator/cache_manager"
require_relative "translator/base"
require_relative "translator/openai_engine"
require_relative "translator/gemini_engine"
require_relative "translator/web_engine"
require_relative "translator/process_lock"

module Narou
  module Translator
    class << self
      def create(setting, archive_path = nil)
        opts = setting.respond_to?(:settings) ? setting.settings : (setting || {})
        arch_path = archive_path || (setting.respond_to?(:archive_path) ? setting.archive_path : Dir.pwd)
        new(opts, arch_path)
      end

      def new(options, archive_path)
        Manager.new(options, archive_path)
      end
    end

    class Manager
      include Translator

      attr_reader :options, :archive_path, :engine, :cache_manager, :process_lock, :character_names

      def initialize(options, archive_path)
        @options = options || {}
        @archive_path = archive_path
        @cache_manager = CacheManager.new(@archive_path)
        @character_names = CharacterNames.new(@archive_path).load
        @process_lock = ProcessLock.new(@archive_path)
        @engine = build_engine
      end

      def with_lock(&block)
        return yield unless enabled?
        @process_lock.synchronize(&block)
      end

      def enabled?
        val = @options["translate.enable"]
        val == true || val.to_s == "true"
      end

      def build_engine
        engine_type = (@options["translate.engine"] || "openai").to_s.downcase
        engine_opts = {
          endpoint: @options["translate.endpoint"],
          api_key: @options["translate.api_key"],
          model: @options["translate.model"],
          chunk_size: @options["translate.chunk_size"],
          max_retries: @options["translate.max_retries"],
          character_names: @character_names
        }.compact

        case engine_type
        when "gemini"
          GeminiEngine.new(engine_opts)
        when "web"
          WebEngine.new(engine_opts)
        else
          OpenAIEngine.new(engine_opts)
        end
      end

      def translate_text(text, type: "text")
        return "" if text.nil? || text.empty?
        return text unless enabled?

        encoded, tag_map = TagProtector.encode(text)
        translated = @engine.translate(encoded, context: { type: type })
        result = TagProtector.decode(translated, tag_map)
        result = @character_names.apply_replacements(result) if @character_names.any?
        result
      end

      def apply_name_fix_to_cache
        return 0 unless enabled? && @character_names.any?
        @character_names.apply_to_cache
      end

      def translate_section(subinfo, section, force_retranslate: false)
        return section unless enabled?

        index = subinfo["index"]
        subtitle = subinfo["file_subtitle"] || subinfo["subtitle"] || "section_#{index}"
        source_content = section.inspect
        source_hash = CacheManager.calculate_hash(source_content)

        unless force_retranslate
          candidate_hashes = [source_hash]
          data_type = section.dig("element", "data_type") || "text"
          if data_type != "text"
            aozora_section = Marshal.load(Marshal.dump(section))
            aozora_element = aozora_section["element"] || {}
            aozora_element.delete("data_type")
            require_relative "../html" unless defined?(HTML)
            html = HTML.new
            aozora_element.each do |text_type, elm_text|
              html.string = elm_text
              aozora_element[text_type] = html.to_aozora(pre_html: data_type == "pre_html")
            end
            candidate_hashes << CacheManager.calculate_hash(aozora_section.inspect)
          end

          cached = @cache_manager.get_section_cache(index, subtitle, candidate_hashes)
          if cached
            cached_data = cached["data"]
            cached_data["element"]&.delete("data_type")
            return cached_data
          end
        end

        # 建立深層副本
        translated_section = Marshal.load(Marshal.dump(section))

        if translated_section["chapter"] && !translated_section["chapter"].empty?
          translated_section["chapter"] = translate_text(translated_section["chapter"], type: "chapter")
        end

        if translated_section["subtitle"] && !translated_section["subtitle"].empty?
          translated_section["subtitle"] = translate_text(translated_section["subtitle"], type: "subtitle")
        end

        element = translated_section["element"] || {}
        data_type = element.delete("data_type") || "text"
        if data_type != "text"
          require_relative "../html" unless defined?(HTML)
          html = HTML.new
          %w[introduction body postscript].each do |elm_type|
            if element[elm_type] && !element[elm_type].empty?
              html.string = element[elm_type]
              element[elm_type] = html.to_aozora(pre_html: data_type == "pre_html")
            end
          end
        end

        %w[introduction body postscript].each do |elm_type|
          if element[elm_type] && !element[elm_type].empty?
            element[elm_type] = translate_text(element[elm_type], type: elm_type)
          end
        end

        @cache_manager.save_section_cache(
          index, subtitle, source_hash, translated_section,
          engine: @options["translate.engine"] || "openai",
          model: @options["translate.model"] || "default"
        )

        translated_section
      end

      def translate_toc(toc, force_retranslate: false)
        return toc unless enabled?

        source_hash = CacheManager.calculate_hash("#{toc["title"]}\n#{toc["story"]}")
        unless force_retranslate
          cached = @cache_manager.get_toc_cache(source_hash)
          if cached
            toc["title"] = cached["data"]["title"]
            toc["story"] = cached["data"]["story"]
            return toc
          end
        end

        toc["title"] = translate_text(toc["title"], type: "title") if toc["title"] && !toc["title"].empty?
        toc["story"] = translate_text(toc["story"], type: "story") if toc["story"] && !toc["story"].empty?

        @cache_manager.save_toc_cache(
          source_hash,
          { "title" => toc["title"], "story" => toc["story"] },
          engine: @options["translate.engine"] || "openai",
          model: @options["translate.model"] || "default"
        )

        toc
      end
    end
  end
end
