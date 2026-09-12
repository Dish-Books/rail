defmodule Rail.Tools.Utils.ResolveCacheTest do
  use ExUnit.Case, async: true

  import Rail.Tools.Utils.ResolveCache

  test "computes on a miss and reuses the value on a hit" do
    key = "cache_probe_#{System.unique_integer([:positive])}"

    assert fetch("/a:/b", key, fn -> "first" end) == "first"
    assert fetch("/a:/b", key, fn -> "second" end) == "first"
  end

  test "keys on the PATH so a changed PATH misses" do
    key = "cache_probe_#{System.unique_integer([:positive])}"

    assert fetch("/a", key, fn -> "under_a" end) == "under_a"
    assert fetch("/b", key, fn -> "under_b" end) == "under_b"
  end
end
