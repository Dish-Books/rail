defmodule Rail.Tools.Utils.DecodeUtf8LenientTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.DecodeUtf8Lenient

  test "passes valid UTF-8 through untouched" do
    assert decode_utf8_lenient("plain ascii and émoji 🚀") == "plain ascii and émoji 🚀"
  end

  test "replaces an incomplete multibyte sequence" do
    assert decode_utf8_lenient(<<224, 160>>) =~ "�"
  end

  test "replaces invalid bytes but keeps the text around them" do
    decoded = decode_utf8_lenient(<<"before ", 255, " after">>)

    assert decoded =~ "before "
    assert decoded =~ " after"
    assert decoded =~ "�"
  end
end
