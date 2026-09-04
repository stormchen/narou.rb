# frozen_string_literal: true

require "minitest/autorun"
require_relative "../../../lib/narou/translator/tag_protector"

class TestTagProtector < Minitest::Test
  def test_encode_and_decode_ruby
    text = "彼は｜魔法《まほう》を使った。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_match(/__TAG_RUBY_\d+__/, encoded)
    refute_includes encoded, "《まほう》"

    translated = encoded.sub("彼", "他")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "他は｜魔法《まほう》を使った。", restored
  end

  def test_encode_and_decode_chuki
    text = "［＃改ページ］\n［＃挿絵（cover.jpg）入る］\n本文です。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_includes encoded, "__TAG_CHUKI_0__"
    assert_includes encoded, "__TAG_CHUKI_1__"

    translated = encoded.sub("本文です", "這是正文")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "［＃改ページ］\n［＃挿絵（cover.jpg）入る］\n這是正文。", restored
  end

  def test_encode_and_decode_url
    text = "参考サイト: https://syosetu.com/ です。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_includes encoded, "__TAG_URL_0__"

    translated = encoded.sub("参考サイト", "參考網站")
    restored = Narou::Translator::TagProtector.decode(translated, map)
    assert_equal "參考網站: https://syosetu.com/ です。", restored
  end

  def test_encode_and_decode_nil_and_empty
    encoded, map = Narou::Translator::TagProtector.encode(nil)
    assert_equal "", encoded
    assert_equal({}, map)
    assert_equal "", Narou::Translator::TagProtector.decode(nil, map)

    encoded, map = Narou::Translator::TagProtector.encode("")
    assert_equal "", encoded
    assert_equal({}, map)
    assert_equal "", Narou::Translator::TagProtector.decode("", map)

    # tag_map 為 nil 或空
    assert_equal "任意文字", Narou::Translator::TagProtector.decode("任意文字", nil)
    assert_equal "任意文字", Narou::Translator::TagProtector.decode("任意文字", {})
  end

  def test_plain_text_without_tags
    text = "吾輩は猫である。名前はまだ無い。"
    encoded, map = Narou::Translator::TagProtector.encode(text)
    assert_equal text, encoded
    assert_empty map

    restored = Narou::Translator::TagProtector.decode(encoded, map)
    assert_equal text, restored
  end

  def test_mixed_complex_text
    text = <<~TEXT
      ［＃改ページ］
      勇者《ゆうしゃ》は｜伝説の剣《エクスカリバー》を手に入れた。
      詳細はこちら：https://example.com/item/123
      ［＃太字］冒険が始まる。［＃太字終わり］
    TEXT

    encoded, map = Narou::Translator::TagProtector.encode(text)

    refute_includes encoded, "《ゆうしゃ》"
    refute_includes encoded, "《エクスカリバー》"
    refute_includes encoded, "［＃改ページ］"
    refute_includes encoded, "https://example.com/item/123"
    refute_includes encoded, "［＃太字］"
    refute_includes encoded, "［＃太字終わり］"

    # 模擬翻譯過程（漢字部分與說明文字翻譯）
    translated = encoded
      .sub("勇者", "勇者")
      .sub("伝説の剣", "傳說之劍")
      .sub("を手に入れた", "入手了")
      .sub("詳細はこちら：", "詳細資訊在此：")
      .sub("冒険が始まる。", "冒險開始了。")

    restored = Narou::Translator::TagProtector.decode(translated, map)

    expected = <<~TEXT
      ［＃改ページ］
      ｜勇者《ゆうしゃ》は｜傳說之劍《エクスカリバー》入手了。
      詳細資訊在此：https://example.com/item/123
      ［＃太字］冒險開始了。［＃太字終わり］
    TEXT

    assert_equal expected, restored
  end
end
