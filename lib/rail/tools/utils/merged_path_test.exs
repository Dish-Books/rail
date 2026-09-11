defmodule Rail.Tools.Utils.MergedPathTest do
  use ExUnit.Case, async: true

  alias Rail.Tools.Utils.MergedPath

  test "merges and deduplicates in search order" do
    home = System.get_env("HOME") || "/Users/test"
    segments = MergedPath.merged_path("/inherited/bin:/common/bin") |> String.split(":")

    assert hd(segments) == "/inherited/bin"
    assert "/common/bin" in segments
    assert "#{home}/.local/bin" in segments
    assert "#{home}/bin" in segments
    assert "/opt/homebrew/bin" in segments
    assert "/usr/bin" in segments
    assert "/bin" in segments

    assert length(segments) == length(Enum.uniq(segments))
  end

  test "handles an empty system path" do
    assert String.contains?(MergedPath.merged_path(""), "/usr/bin")
  end
end
