defmodule Rail.Tools.Actions.ResolveTest do
  use ExUnit.Case, async: true

  alias Rail.Tools

  test "returns path unchanged if it contains a slash" do
    assert Tools.resolve("/usr/bin/custom_tool") == "/usr/bin/custom_tool"
    assert Tools.resolve("./relative_tool") == "./relative_tool"
  end

  test "finds existing executable and caches it" do
    resolved = Tools.resolve("sh")
    assert byte_size(resolved) > 0
    assert String.ends_with?(resolved, "/sh")
    assert File.exists?(resolved)

    assert Tools.resolve("sh") == resolved
  end

  test "falls back to bare name if not found on PATH" do
    assert Tools.resolve("definitely_not_a_real_binary_xyz_123") ==
             "definitely_not_a_real_binary_xyz_123"
  end
end
