defmodule Rail.Diff.FileDiffTest do
  use Rail.DataCase, async: true

  alias Rail.Diff.FileDiff

  test "new/1 delegates to Rail.Domain.Diff.FileDiff" do
    diff = FileDiff.new(%{status: :modified, digest: "d1", new_path: "lib/foo.ex"})
    assert diff.path == "lib/foo.ex"
  end
end
