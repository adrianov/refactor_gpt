# frozen_string_literal: true

require 'minitest/autorun'
require 'uri'
require_relative '../lib/loader'

class TestPrimaryApiHttp < Minitest::Test
  def teardown
    ENV.delete('HTTP_PROXY')
    ENV.delete('HTTPS_PROXY')
  end

  def test_session_post_hides_https_proxy
    ENV['HTTPS_PROXY'] = 'http://127.0.0.1:8118'
    http = Object.new
    def http.post(...)
      URI('https://openrouter.ai').find_proxy
    end
    session = PrimaryApiHttp::Session.new(http)
    assert_nil session.post('https://example.test')
    assert_equal 'http://127.0.0.1:8118', ENV['HTTPS_PROXY']
  end
end
