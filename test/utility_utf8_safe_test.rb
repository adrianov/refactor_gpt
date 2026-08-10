# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/loader"

class UtilityUtf8SafeTest < Minitest::Test
  def test_utf8_safe_allows_strip_under_us_ascii_locale
    old_external = Encoding.default_external
    old_internal = Encoding.default_internal
    Encoding.default_external = Encoding::US_ASCII
    Encoding.default_internal = nil

    raw = "ceacbda Fix Timepad — Москва\n".dup.force_encoding(Encoding::US_ASCII)
    assert_equal Encoding::US_ASCII, raw.encoding
    assert_raises(Encoding::CompatibilityError) { raw.strip }

    safe = Utility.utf8_safe(raw)
    assert_equal Encoding::UTF_8, safe.encoding
    assert_equal "ceacbda Fix Timepad — Москва", safe.strip
  ensure
    Encoding.default_external = old_external
    Encoding.default_internal = old_internal
  end
end
