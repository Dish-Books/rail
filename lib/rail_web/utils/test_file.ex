defmodule RailWeb.Utils.TestFile do
  @moduledoc """
  Whether a file in a diff is a test, so a reader can put the tests aside and read the change itself.
  """

  @test_dirs ["test", "tests", "__tests__", "spec", "specs", "__snapshots__"]

  @doc """
  True for a path under a test directory, or named the way the common test runners find tests:
  `filter_test.exs`, `filter.test.ts`, `filter_spec.rb`, `test_filter.py` or `FilterTest.java`.
  """
  def test_file?(path) do
    name = Path.basename(path)

    Enum.any?(Path.split(Path.dirname(path)), &(&1 in @test_dirs)) or
      Regex.match?(~r/[._-](tests?|spec)\.[^.\/]+$/, name) or
      Regex.match?(~r/^test_.+\.py$/, name) or
      Regex.match?(~r/[a-z0-9](Tests?|Spec)\.[^.\/]+$/, name)
  end
end
