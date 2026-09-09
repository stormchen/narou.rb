# frozen_string_literal: true

ARGV << "--no-plugins" unless ARGV.include?("--no-plugins")
gem "minitest", "< 6"
require "minitest/autorun"
require "forwardable"
require "tmpdir"
require "fileutils"
require "yaml"
require "stringio"

require_relative "../../../lib/narou_logger"
require_relative "../../../lib/commandbase"
require_relative "../../../lib/command/convert"
require_relative "../../../lib/novelconverter"
require_relative "../../../lib/novelsetting"
require_relative "../../../lib/narou/translator"

class TestConvertIntegration < Minitest::Test
  class MockEngine < Narou::Translator::Base
    attr_accessor :call_count, :suffix

    def initialize(options = {})
      super
      @call_count = 0
      @suffix = "（繁中）"
    end

    def translate(text, context: {})
      @call_count += 1
      "#{text}#{@suffix}"
    end
  end

  def setup
    @tmpdir = Dir.mktmpdir("narou_convert_integration_test")
    FileUtils.mkdir_p(File.join(@tmpdir, ".narou"))
    @archive_path = File.join(@tmpdir, "novel_data")
    FileUtils.mkdir_p(@archive_path)

    Narou.class_variable_set(:@@global_replace_pattern_pairs, [])
    SiteSetting.instance_variable_set(:@settings, nil)
    SiteSetting.instance_variable_set(:@narou, nil)

    @original_root_dir_method = Narou.method(:root_dir)
    @original_global_setting_dir_method = Narou.method(:global_setting_dir)
    tmpdir = @tmpdir
    Narou.define_singleton_method(:root_dir) { Pathname(tmpdir) }
    Narou.define_singleton_method(:global_setting_dir) { Pathname(tmpdir).join(".narousetting") }
    Inventory.clear

    # 建立 setting.ini
    @setting = NovelSetting.new(@archive_path, true, true)
    @setting.title = "勇者の冒険"
    @setting.author = "原作者"
    @setting.load_settings
    @setting.set_attribute
    @setting.load_replace_pattern

    # 建立 toc.yaml
    @toc = {
      "title" => "勇者の冒険",
      "author" => "原作者",
      "toc_url" => "https://ncode.syosetu.com/n1234a/",
      "story" => "これは魔王を倒す勇者の物語である。",
      "subtitles" => [
        {
          "index" => "1",
          "subtitle" => "プロローグ",
          "file_subtitle" => "プロローグ",
          "chapter" => "第一章"
        }
      ]
    }
    File.write(File.join(@archive_path, "toc.yaml"), YAML.dump(@toc))

    # 建立 本文/1 プロローグ.yaml
    section_dir = File.join(@archive_path, "本文")
    FileUtils.mkdir_p(section_dir)
    @section_data = {
      "subtitle" => "プロローグ",
      "chapter" => "第一章",
      "element" => {
        "data_type" => "text",
        "introduction" => "始まりの前書き。",
        "body" => "勇者は旅立った。\n魔王を討伐するために。",
        "postscript" => "終わりの後書き。"
      }
    }
    File.write(File.join(section_dir, "1 プロローグ.yaml"), YAML.dump(@section_data))

    @mock_engine = MockEngine.new
  end

  def teardown
    orig = @original_root_dir_method
    orig_global = @original_global_setting_dir_method
    Narou.define_singleton_method(:root_dir) { orig.call }
    Narou.define_singleton_method(:global_setting_dir) { orig_global.call }
    Inventory.clear
    SiteSetting.instance_variable_set(:@settings, nil)
    SiteSetting.instance_variable_set(:@narou, nil)
    FileUtils.remove_entry(@tmpdir)
  end

  # -------------------------------------------------------------
  # 1. Command::Convert CLI 選項解析測試
  # -------------------------------------------------------------
  def test_command_convert_options_parsing_translate
    cmd = Command::Convert.new
    cmd.parse_options!(["--translate"])
    assert_equal true, cmd.options["translate"]
  end

  def test_command_convert_options_parsing_no_translate
    cmd = Command::Convert.new
    cmd.parse_options!(["--no-translate"])
    assert_equal false, cmd.options["translate"]
  end

  def test_command_convert_options_parsing_retranslate
    cmd = Command::Convert.new
    cmd.parse_options!(["--retranslate"])
    assert_equal true, cmd.options["retranslate"]
    assert_equal true, cmd.options["translate"]
  end

  def test_command_convert_options_default_nil
    cmd = Command::Convert.new
    cmd.parse_options!(["dummy_target"])
    assert_nil cmd.options["translate"]
    assert_nil cmd.options["retranslate"]
  end

  # -------------------------------------------------------------
  # 2. NovelConverter Translator 初始化與選項覆蓋測試
  # -------------------------------------------------------------
  def test_novelconverter_has_translator_and_options
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    assert_respond_to converter, :translator
    assert_respond_to converter, :options
    assert_instance_of Narou::Translator::Manager, converter.translator
    refute converter.translator.enabled?
  end

  def test_novelconverter_options_override_translate_setting
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true }
    if converter.options[:translate] != nil
      converter.translator.options["translate.enable"] = converter.options[:translate]
    end
    assert converter.translator.enabled?

    converter.options = { translate: false }
    if converter.options[:translate] != nil
      converter.translator.options["translate.enable"] = converter.options[:translate]
    end
    refute converter.translator.enabled?
  end

  # -------------------------------------------------------------
  # 3. NovelConverter#convert_main_for_novel & subtitles_to_sections 測試
  # -------------------------------------------------------------
  def test_convert_main_for_novel_when_translation_enabled
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true }
    converter.translator.options["translate.enable"] = true
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    result_texts = converter.convert_main_for_novel
    assert_equal 1, result_texts.size
    full_text = result_texts.first

    # 驗證章節標題、前言、本文、後記、大綱等均包含翻譯後綴
    assert_includes full_text, "勇者の冒険（繁中）"
    assert_includes full_text, "これは魔王を倒す勇者の物語である。（繁中）"
    assert_includes full_text, "プロローグ（繁中）"
    assert_includes full_text, "第一章（繁中）"
    assert_includes full_text, "始まりの前書き。（繁中）"
    assert_includes full_text, "勇者は旅立った。"
    assert_includes full_text, "魔王を討伐するために。（繁中）"
    assert_includes full_text, "終わりの後書き。（繁中）"

    # 驗證翻譯快取是否有存入
    cache_mgr = converter.translator.cache_manager
    toc_cache = cache_mgr.get_toc_cache(
      Narou::Translator::CacheManager.calculate_hash("勇者の冒険\nこれは魔王を倒す勇者の物語である。")
    )
    assert toc_cache, "TOC 快取應該存在"
    assert_equal "勇者の冒険（繁中）", toc_cache["data"]["title"]

    assert @mock_engine.call_count > 0
  end

  def test_convert_main_for_novel_when_translation_disabled
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: false }
    converter.translator.options["translate.enable"] = false
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    result_texts = converter.convert_main_for_novel
    full_text = result_texts.first

    # 驗證未翻譯，保持原始文字且不含繁中後綴
    refute_includes full_text, "（繁中）"
    assert_includes full_text, "勇者の冒険"
    assert_includes full_text, "プロローグ"
    assert_equal 0, @mock_engine.call_count
  end

  # -------------------------------------------------------------
  # 4. NovelConverter#convert_main_for_text 測試
  # -------------------------------------------------------------
  def test_convert_main_for_text_when_translation_enabled
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true }
    converter.translator.options["translate.enable"] = true
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    raw_text = +"タイトル\n原作者\n勇者と魔王の冒険テキスト\n"
    converted = converter.convert_main_for_text(raw_text)
    assert_includes converted.first, "（繁中）"
    assert_includes converted.first, "勇者と魔王の冒険テキスト"
    assert @mock_engine.call_count > 0
  end

  def test_convert_main_for_text_when_translation_disabled
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: false }
    converter.translator.options["translate.enable"] = false
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    raw_text = +"タイトル\n原作者\n勇者と魔王の冒険テキスト\n"
    converted = converter.convert_main_for_text(raw_text)
    refute_includes converted.first, "（繁中）"
    assert_includes converted.first, "勇者と魔王の冒険テキスト"
    assert_equal 0, @mock_engine.call_count
  end

  # -------------------------------------------------------------
  # 5. Retranslate 選項測試（強制重新翻譯快取）
  # -------------------------------------------------------------
  def test_retranslate_option_forces_new_translation
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true, retranslate: false }
    converter.translator.options["translate.enable"] = true
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    # 第一次執行：產生快取
    converter.convert_main_for_novel
    initial_count = @mock_engine.call_count
    assert initial_count > 0

    # 換成第二個後綴（新譯文）
    @mock_engine.suffix = "（新譯）"

    # 第二次執行：未強制重新翻譯，應使用快取，call_count 不增加
    result_cached = converter.convert_main_for_novel
    assert_equal initial_count, @mock_engine.call_count
    assert_includes result_cached.first, "（繁中）"
    refute_includes result_cached.first, "（新譯）"

    # 第三次執行：指定 retranslate: true，應強制調用 engine 產生新譯文
    converter.options[:retranslate] = true
    result_retranslated = converter.convert_main_for_novel
    assert @mock_engine.call_count > initial_count
    assert_includes result_retranslated.first, "（新譯）"
  end

  def test_novelconverter_convert_file_with_translate_options
    text_path = File.join(@tmpdir, "test_novel.txt")
    File.write(text_path, "タイトル\n原作者\n勇者と魔王の冒険テキスト\n")

    orig_create = Narou::Translator.method(:create)
    mock = @mock_engine
    Narou::Translator.define_singleton_method(:create) do |setting, archive_path|
      inst = orig_create.call(setting, archive_path)
      inst.instance_variable_set(:@engine, mock)
      inst
    end

    begin
      res = NovelConverter.convert_file(text_path, translate: true)
      assert res[:converted_txt_paths]
      converted_content = File.read(res[:converted_txt_paths].first)
      assert_includes converted_content, "（繁中）"
      assert_includes converted_content, "勇者と魔王の冒険テキスト"

      res_disabled = NovelConverter.convert_file(text_path, translate: false)
      converted_disabled = File.read(res_disabled[:converted_txt_paths].first)
      refute_includes converted_disabled, "（繁中）"
    ensure
      Narou::Translator.define_singleton_method(:create) { |*args| orig_create.call(*args) }
    end
  end

  def test_convert_main_aborts_when_locked_by_another_process
    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true }
    converter.translator.options["translate.enable"] = true
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    lock_path = File.join(@archive_path, Narou::Translator::ProcessLock::LOCK_FILE_NAME)
    alive_pid = Process.ppid > 0 ? Process.ppid : 4
    File.write(lock_path, YAML.dump({ "pid" => alive_pid, "created_at" => Time.now.to_s, "novel_dir" => @archive_path }))

    err = assert_raises(SystemExit) do
      converter.convert_main
    end
    assert_equal Narou::EXIT_ERROR_CODE, err.status
  end

  def test_convert_main_preserves_newlines_when_section_has_html_data_type
    # 測試具有 data_type: html 的章節在翻譯後段落換行不會被清除
    section_dir = File.join(@archive_path, "本文")
    html_section_data = {
      "subtitle" => "プロローグ",
      "chapter" => "第一章",
      "element" => {
        "data_type" => "html",
        "introduction" => "",
        "body" => "<p id=\"L1\">第一行段落。</p>\n<p id=\"L2\">第二行段落。</p>\n<p id=\"L3\">第三行段落。</p>",
        "postscript" => ""
      }
    }
    File.write(File.join(section_dir, "1 プロローグ.yaml"), YAML.dump(html_section_data))

    converter = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter.options = { translate: true }
    converter.translator.options["translate.enable"] = true
    converter.translator.instance_variable_set(:@engine, @mock_engine)

    result_texts = converter.convert_main_for_novel
    full_text = result_texts.first

    # 確保多行文字沒有被合併為單一行，段落換行完整保留
    assert_includes full_text, "第一行段落。\n　第二行段落。\n　第三行段落。"
    refute_includes full_text, "第一行段落。第二行段落。第三行段落。"

    # 驗證第二次轉換（快取讀取情境），換行亦能完整保留
    converter2 = NovelConverter.new(@setting, nil, false, nil, stream_io: StringIO.new)
    converter2.options = { translate: true }
    converter2.translator.options["translate.enable"] = true
    converter2.translator.instance_variable_set(:@engine, @mock_engine)

    result_texts2 = converter2.convert_main_for_novel
    full_text2 = result_texts2.first
    assert_includes full_text2, "第一行段落。\n　第二行段落。\n　第三行段落。"
    refute_includes full_text2, "第一行段落。第二行段落。第三行段落。"
  end
end
