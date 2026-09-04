# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../lib/narou/translator"

class TestTranslatorFacade < Minitest::Test
  class MockEngine < Narou::Translator::Base
    attr_accessor :call_count

    def initialize(options = {})
      super
      @call_count = 0
    end

    def translate(text, context: {})
      @call_count += 1
      text.gsub("勇者", "勇者(中)")
          .gsub("魔王", "魔王(中)")
          .gsub("冒険", "冒險(中)")
          .gsub("タイトル", "標題(中)")
          .gsub("あらすじ", "故事大綱(中)")
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("translator_facade_test")
    @options = {
      "translate.enable" => true,
      "translate.engine" => "openai"
    }
    @translator = Narou::Translator.new(@options, @tmpdir)
    @mock_engine = MockEngine.new
    @translator.instance_variable_set(:@engine, @mock_engine)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_create_factory_method_with_hash
    translator = Narou::Translator.create(@options, @tmpdir)
    assert translator.enabled?
    assert_equal @tmpdir, translator.archive_path
  end

  def test_create_factory_method_with_setting_object
    mock_setting = Object.new
    settings_hash = { "translate.enable" => true, "translate.engine" => "gemini" }
    mock_setting.define_singleton_method(:settings) { settings_hash }
    mock_setting.define_singleton_method(:archive_path) { "/mock/archive/path" }

    translator = Narou::Translator.create(mock_setting)
    assert translator.enabled?
    assert_equal "/mock/archive/path", translator.archive_path
    assert_instance_of Narou::Translator::GeminiEngine, translator.engine
  end

  def test_enabled_detection
    assert @translator.enabled?

    t_string = Narou::Translator.new({ "translate.enable" => "true" }, @tmpdir)
    assert t_string.enabled?

    t_disabled = Narou::Translator.new({ "translate.enable" => false }, @tmpdir)
    refute t_disabled.enabled?

    t_nil = Narou::Translator.new({}, @tmpdir)
    refute t_nil.enabled?

    t_str_false = Narou::Translator.new({ "translate.enable" => "false" }, @tmpdir)
    refute t_str_false.enabled?
  end

  def test_build_engine_selection
    t_openai = Narou::Translator.new({ "translate.engine" => "openai" }, @tmpdir)
    assert_instance_of Narou::Translator::OpenAIEngine, t_openai.engine

    t_gemini = Narou::Translator.new({ "translate.engine" => "gemini" }, @tmpdir)
    assert_instance_of Narou::Translator::GeminiEngine, t_gemini.engine

    t_web = Narou::Translator.new({ "translate.engine" => "web" }, @tmpdir)
    assert_instance_of Narou::Translator::WebEngine, t_web.engine

    t_default = Narou::Translator.new({}, @tmpdir)
    assert_instance_of Narou::Translator::OpenAIEngine, t_default.engine
  end

  def test_translate_text_when_disabled
    disabled_translator = Narou::Translator.new({ "translate.enable" => false }, @tmpdir)
    text = "勇者と魔王"
    assert_equal "勇者と魔王", disabled_translator.translate_text(text)
  end

  def test_translate_text_empty_and_nil
    assert_equal "", @translator.translate_text("")
    assert_equal "", @translator.translate_text(nil)
  end

  def test_translate_text_with_tag_protection
    text = "彼は｜勇者《ゆうしゃ》と戦った。"
    result = @translator.translate_text(text)
    # 標籤保護還原，勇者被翻譯為 勇者(中)
    assert_equal "彼は｜勇者(中)《ゆうしゃ》と戦った。", result
  end

  def test_translate_section_when_disabled
    disabled_translator = Narou::Translator.new({ "translate.enable" => false }, @tmpdir)
    subinfo = { "index" => 1, "subtitle" => "第1話" }
    section = { "subtitle" => "勇者の登場", "element" => { "body" => "魔王の城" } }

    result = disabled_translator.translate_section(subinfo, section)
    assert_same section, result
  end

  def test_translate_section_flow_and_caching
    subinfo = { "index" => 1, "file_subtitle" => "第1話" }
    section = {
      "chapter" => "勇者の章",
      "subtitle" => "魔王との戦い",
      "element" => {
        "data_type" => "text",
        "introduction" => "冒険の始まり",
        "body" => "勇者と魔王が対峙する。",
        "postscript" => "次回もお楽しみに"
      }
    }

    # 首次翻譯
    translated_section = @translator.translate_section(subinfo, section)
    assert_equal "勇者(中)の章", translated_section["chapter"]
    assert_equal "魔王(中)との戦い", translated_section["subtitle"]
    assert_equal "冒險(中)の始まり", translated_section["element"]["introduction"]
    assert_equal "勇者(中)と魔王(中)が対峙する。", translated_section["element"]["body"]
    assert_equal "次回もお楽しみに", translated_section["element"]["postscript"]

    # 快取檔案應已產生
    cache_file = File.join(@tmpdir, "translated_sections", "1 第1話.yaml")
    assert File.exist?(cache_file), "快取檔案必須存在"

    initial_call_count = @mock_engine.call_count
    assert initial_call_count > 0

    # 第二次呼叫，移除 engine 確保直接讀取快取
    @translator.instance_variable_set(:@engine, nil)
    cached_section = @translator.translate_section(subinfo, section)
    assert_equal "勇者(中)の章", cached_section["chapter"]
    assert_equal "魔王(中)との戦い", cached_section["subtitle"]
    assert_equal "勇者(中)と魔王(中)が対峙する。", cached_section["element"]["body"]
  end

  def test_translate_section_force_retranslate
    subinfo = { "index" => 1, "file_subtitle" => "第1話" }
    section = {
      "chapter" => "勇者の章",
      "subtitle" => "魔王との戦い",
      "element" => { "body" => "勇者参上" }
    }

    # 首次翻譯
    @translator.translate_section(subinfo, section)
    calls_after_first = @mock_engine.call_count

    # 強制重新翻譯，即便有快取也必須再次調用 Engine
    @translator.translate_section(subinfo, section, force_retranslate: true)
    assert @mock_engine.call_count > calls_after_first
  end

  def test_translate_toc_flow_and_caching
    toc = {
      "title" => "魔王の物語",
      "story" => "これは勇者と魔王のあらすじです。"
    }

    # 首次翻譯
    translated_toc = @translator.translate_toc(toc)
    assert_equal "魔王(中)の物語", translated_toc["title"]
    assert_equal "これは勇者(中)と魔王(中)の故事大綱(中)です。", translated_toc["story"]

    # 檢查 TOC 快取檔案
    toc_cache_file = File.join(@tmpdir, "translated_sections", "toc_translated.yaml")
    assert File.exist?(toc_cache_file), "TOC 快取檔案必須存在"

    # 第二次呼叫（無 engine），驗證快取命中
    @translator.instance_variable_set(:@engine, nil)
    toc_from_cache = {
      "title" => "魔王の物語",
      "story" => "これは勇者と魔王のあらすじです。"
    }
    cached_result = @translator.translate_toc(toc_from_cache)
    assert_equal "魔王(中)の物語", cached_result["title"]
    assert_equal "これは勇者(中)と魔王(中)の故事大綱(中)です。", cached_result["story"]
  end

  def test_translate_toc_when_disabled
    disabled_translator = Narou::Translator.new({ "translate.enable" => false }, @tmpdir)
    toc = { "title" => "魔王", "story" => "勇者" }
    result = disabled_translator.translate_toc(toc)
    assert_equal "魔王", result["title"]
    assert_equal "勇者", result["story"]
  end
end
