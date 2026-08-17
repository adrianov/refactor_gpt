# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/loader'

class TestPrimaryApiProxy < Minitest::Test
  def test_normalize_socks_schemes
    assert_equal 'socks5://127.0.0.1:1080', PrimaryApiProxy.normalize('socks://127.0.0.1:1080')
    assert_equal 'socks5://127.0.0.1:1080', PrimaryApiProxy.normalize('socks5h://127.0.0.1:1080')
    assert_equal 'http://proxy:8080', PrimaryApiProxy.normalize('http://proxy:8080')
  end

  def test_choose_prefers_socks5_over_other_dotenv_proxy
    env = {
      'PROXY_URL' => 'http://proxy:8080',
      'ALL_PROXY' => 'socks5://127.0.0.1:1080'
    }
    assert_equal 'socks5://127.0.0.1:1080', PrimaryApiProxy.resolve(nil, env)
  end

  def test_uses_proxy_url_from_dotenv
    env = {'PROXY_URL' => 'socks5://127.0.0.1:1080'}
    assert_equal 'socks5://127.0.0.1:1080', PrimaryApiProxy.resolve(nil, env)
  end

  def test_ignores_http_proxy_when_no_dotenv_proxy
    env = {'HTTPS_PROXY' => 'http://127.0.0.1:8118', 'HTTP_PROXY' => 'http://127.0.0.1:8118'}
    assert_nil PrimaryApiProxy.resolve(nil, env)
  end

  def test_explicit_proxy_url_included_and_socks_still_preferred
    env = {'ALL_PROXY' => 'socks://127.0.0.1:1080'}
    assert_equal 'socks5://127.0.0.1:1080', PrimaryApiProxy.resolve('http://explicit:9', env)
  end

  def test_returns_nil_when_no_proxy_configured
    assert_nil PrimaryApiProxy.resolve(nil, {})
  end
end
