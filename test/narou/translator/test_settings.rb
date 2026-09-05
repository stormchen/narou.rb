# frozen_string_literal: true

ARGV << "--no-plugins" unless ARGV.include?("--no-plugins")
gem "minitest", "< 6"
require "minitest/autorun"
require "forwardable"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/narou_logger"
require_relative "../../../lib/commandbase"
require_relative "../../../lib/command/convert"
require_relative "../../../lib/novelsetting"
require_relative "../../../lib/command/setting"

class TestTranslatorSettings < Minitest::Test
  TRANSLATE_VARS = %w(
    translate.enable
    translate.engine
    translate.endpoint
    translate.api_key
    translate.model
    translate.chunk_size
    translate.max_retries
  ).freeze

  def setup
    @tmpdir = Dir.mktmpdir("narou_setting_test")
    FileUtils.mkdir_p(File.join(@tmpdir, ".narou"))
    @original_root_dir_method = Narou.method(:root_dir)
    @original_global_setting_dir_method = Narou.method(:global_setting_dir)
    tmpdir = @tmpdir
    Narou.define_singleton_method(:root_dir) { Pathname(tmpdir) }
    Narou.define_singleton_method(:global_setting_dir) { Pathname(tmpdir).join(".narousetting") }
    Inventory.clear
  end

  def teardown
    orig = @original_root_dir_method
    orig_global = @original_global_setting_dir_method
    Narou.define_singleton_method(:root_dir) { orig.call }
    Narou.define_singleton_method(:global_setting_dir) { orig_global.call }
    Inventory.clear
    FileUtils.remove_entry(@tmpdir)
  end

  # 1. 測試 NovelSetting::ORIGINAL_SETTINGS 包含所有 translate 變數與其型別、預設值
  def test_novelsetting_original_settings_include_translate
    names = NovelSetting::ORIGINAL_SETTINGS.map { |s| s[:name] }
    TRANSLATE_VARS.each do |var|
      assert_includes names, var, "#{var} should be included in ORIGINAL_SETTINGS"
    end

    settings_map = NovelSetting::ORIGINAL_SETTINGS.each_with_object({}) { |s, h| h[s[:name]] = s }

    assert_equal :boolean, settings_map["translate.enable"][:type]
    assert_equal false, settings_map["translate.enable"][:value]

    assert_equal :select, settings_map["translate.engine"][:type]
    assert_equal "openai", settings_map["translate.engine"][:value]
    assert_equal %w(openai gemini web), settings_map["translate.engine"][:select_keys]

    assert_equal :string, settings_map["translate.endpoint"][:type]
    assert_equal "http://localhost:11434/v1", settings_map["translate.endpoint"][:value]

    assert_equal :string, settings_map["translate.api_key"][:type]
    assert_equal "", settings_map["translate.api_key"][:value]

    assert_equal :string, settings_map["translate.model"][:type]
    assert_equal "sakura-13b", settings_map["translate.model"][:value]

    assert_equal :integer, settings_map["translate.chunk_size"][:type]
    assert_equal 2500, settings_map["translate.chunk_size"][:value]

    assert_equal :integer, settings_map["translate.max_retries"][:type]
    assert_equal 3, settings_map["translate.max_retries"][:value]
  end

  # 2. 測試 NovelSetting 實例讀取與寫入、型別檢查與動態方法定義
  def test_novelsetting_instance_read_and_write
    setting = NovelSetting.new(@tmpdir, true, true)
    setting.load_settings
    # 測試 set_attribute 不會因為 key 包含 '.' 而崩潰，並成功建立動態方法
    setting.set_attribute

    # 預設值檢查 (透過 [] 與 send)
    assert_equal false, setting["translate.enable"]
    assert_equal false, setting.send("translate.enable")
    assert_equal "openai", setting["translate.engine"]
    assert_equal "openai", setting.send("translate.engine")
    assert_equal "http://localhost:11434/v1", setting["translate.endpoint"]
    assert_equal "http://localhost:11434/v1", setting.send("translate.endpoint")
    assert_equal "", setting["translate.api_key"]
    assert_equal "sakura-13b", setting["translate.model"]
    assert_equal 2500, setting["translate.chunk_size"]
    assert_equal 3, setting["translate.max_retries"]

    # 寫入新值測試 (透過 []= 與 send=)
    setting["translate.enable"] = true
    assert_equal true, setting["translate.enable"]
    assert_equal true, setting.send("translate.enable")

    setting.send("translate.enable=", false)
    assert_equal false, setting["translate.enable"]
    assert_equal false, setting.send("translate.enable")

    setting.send("translate.engine=", "gemini")
    assert_equal "gemini", setting["translate.engine"]

    setting.send("translate.endpoint=", "https://api.openai.com/v1")
    assert_equal "https://api.openai.com/v1", setting["translate.endpoint"]

    setting.send("translate.api_key=", "sk-123456")
    assert_equal "sk-123456", setting["translate.api_key"]

    setting.send("translate.model=", "gemini-1.5-flash")
    assert_equal "gemini-1.5-flash", setting["translate.model"]

    setting.send("translate.chunk_size=", 1500)
    assert_equal 1500, setting["translate.chunk_size"]

    setting.send("translate.max_retries=", 5)
    assert_equal 5, setting["translate.max_retries"]

    # 型別檢查測試：賦予錯誤型別應拋出 Helper::InvalidVariableType
    assert_raises(Helper::InvalidVariableType) do
      setting["translate.enable"] = "not_a_boolean"
    end
    assert_raises(Helper::InvalidVariableType) do
      setting.send("translate.chunk_size=", "not_an_integer")
    end
  end

  # 3. 測試 Command::Setting::SETTING_VARIABLES 包含 global translate 變數
  def test_command_setting_variables_include_global_translate
    global_vars = Command::Setting::SETTING_VARIABLES[:global]
    TRANSLATE_VARS.each do |var|
      assert global_vars.key?(var), "Global settings should include #{var}"
    end

    assert_equal :boolean, global_vars["translate.enable"][:type]
    assert_equal :select, global_vars["translate.engine"][:type]
    assert_equal %w(openai gemini web), global_vars["translate.engine"][:select_keys]
    assert_equal :string, global_vars["translate.endpoint"][:type]
    assert_equal :string, global_vars["translate.api_key"][:type]
    assert_equal :string, global_vars["translate.model"][:type]
    assert_equal :integer, global_vars["translate.chunk_size"][:type]
    assert_equal :integer, global_vars["translate.max_retries"][:type]
  end

  # 4. 測試 Command::Setting 針對 translate 變數的 casting_variable 與 scope 判斷
  def test_command_setting_casting_and_scope
    setting_cmd = Command::Setting.new

    scope = setting_cmd.get_scope_of_variable_name("translate.enable")
    assert_equal :global, scope

    # 測試合法值轉換
    scope, val = setting_cmd.casting_variable("translate.enable", "true")
    assert_equal :global, scope
    assert_equal true, val

    scope, val = setting_cmd.casting_variable("translate.engine", "gemini")
    assert_equal :global, scope
    assert_equal "gemini", val

    scope, val = setting_cmd.casting_variable("translate.chunk_size", "3000")
    assert_equal :global, scope
    assert_equal 3000, val

    # 測試非法 select 值拋出例外
    assert_raises(Command::Setting::InvalidSelectValue) do
      setting_cmd.casting_variable("translate.engine", "invalid_engine")
    end

    # 測試非法型別拋出例外
    assert_raises(Helper::InvalidVariableType) do
      setting_cmd.casting_variable("translate.enable", "not_boolean")
    end
  end

  # 5. 測試 default.translate.* 與 force.translate.* 在 local 設定中自動同步生成
  def test_default_and_force_settings_automatically_included
    local_vars = Command::Setting::SETTING_VARIABLES[:local]
    TRANSLATE_VARS.each do |var|
      assert local_vars.key?("default.#{var}"), "Local settings should include default.#{var}"
      assert local_vars.key?("force.#{var}"), "Local settings should include force.#{var}"
    end

    assert_equal :boolean, local_vars["default.translate.enable"][:type]
    assert_equal :string, local_vars["force.translate.endpoint"][:type]
  end
end
