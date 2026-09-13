defmodule RailWeb.Utils.FormatTokensTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.FormatTokens

  test "small counts read as themselves" do
    assert format_tokens(0) == "0"
    assert format_tokens(500) == "500"
  end

  test "thousands compact to K, dropping a trailing zero" do
    assert format_tokens(1_500) == "1.5K"
    assert format_tokens(2_000) == "2K"
  end

  test "millions compact to M" do
    assert format_tokens(1_230_000) == "1.23M"
    assert format_tokens(2_500_000) == "2.5M"
  end

  test "no count is no tokens" do
    assert format_tokens(nil) == "0"
    assert format_tokens(nil, suffix: true) == "0 tokens"
  end

  test "the suffix agrees with the count" do
    assert format_tokens(1, suffix: true) == "1 token"
    assert format_tokens(2, suffix: true) == "2 tokens"
  end

  test "a float rounds to the nearest token" do
    assert format_tokens(1_500.4) == "1.5K"
  end
end
