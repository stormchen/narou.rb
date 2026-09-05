# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../../lib/narou/translator/cache_manager"

class TestCacheManager < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("narou_cache_test")
    @cache_manager = Narou::Translator::CacheManager.new(@tmpdir)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_save_and_get_section_cache
    index = 1
    subtitle = "プロローグ"
    source_hash = "abc123hash"
    data = { "subtitle" => "序章", "body" => "這是一段正文。" }

    assert_nil @cache_manager.get_section_cache(index, subtitle, source_hash)

    @cache_manager.save_section_cache(index, subtitle, source_hash, data, engine: "openai", model: "sakura-13b")

    cached = @cache_manager.get_section_cache(index, subtitle, source_hash)
    refute_nil cached
    assert_equal "序章", cached["data"]["subtitle"]
    assert_equal "abc123hash", cached["source_hash"]
    assert_equal "sakura-13b", cached["model"]

    assert_nil @cache_manager.get_section_cache(index, subtitle, "different_hash")
  end

  def test_save_and_get_toc_cache
    source_hash = "tochash456"
    data = { "title" => "魔王轉生", "story" => "大綱內容" }

    assert_nil @cache_manager.get_toc_cache(source_hash)
    @cache_manager.save_toc_cache(source_hash, data, engine: "openai", model: "sakura-13b")

    cached = @cache_manager.get_toc_cache(source_hash)
    refute_nil cached
    assert_equal "魔王轉生", cached["data"]["title"]
  end

  def test_calculate_hash
    hash1 = Narou::Translator::CacheManager.calculate_hash("測試內容")
    hash2 = Narou::Translator::CacheManager.calculate_hash("測試內容")
    hash3 = Narou::Translator::CacheManager.calculate_hash("不同內容")

    assert_equal hash1, hash2
    refute_equal hash1, hash3
  end

  def test_section_cache_path_sanitizes_subtitle
    index = 2
    dangerous_subtitle = 'Chapter 1: "Hero" / <Villain>? *Warning* | \\'
    path = @cache_manager.section_cache_path(index, dangerous_subtitle)

    refute_match(%r{[\\/:*?"<>|]}, File.basename(path))
    assert File.basename(path).start_with?("2 Chapter 1_ _Hero_ _ _Villain__ _Warning_ _ _")
  end

  def test_corrupted_cache_file_handling
    index = 3
    subtitle = "損毀章節"
    path = @cache_manager.section_cache_path(index, subtitle)
    File.write(path, "invalid: [yaml: broken: content")

    assert_nil @cache_manager.get_section_cache(index, subtitle, "any_hash")
  end

  def test_get_section_cache_with_array_of_hashes
    index = 4
    subtitle = "多雜湊比對"
    source_hash = "correct_hash_1"
    data = { "subtitle" => "多雜湊", "body" => "內容" }

    @cache_manager.save_section_cache(index, subtitle, source_hash, data, engine: "openai", model: "sakura-13b")

    # 單一符合
    assert @cache_manager.get_section_cache(index, subtitle, ["other_hash", "correct_hash_1"])
    # 都不符合
    assert_nil @cache_manager.get_section_cache(index, subtitle, ["other_hash_1", "other_hash_2"])
  end
end
