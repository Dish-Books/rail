defmodule RailWeb.Utils.DiffFileNameTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.DiffFileName

  test "a nested file is its directory and its name" do
    assert diff_file_name(%{display_path: "lib/rail/filter.ex"}) == %{dir: "lib/rail/", name: "filter.ex"}
  end

  test "a file at the root has no directory" do
    assert diff_file_name(%{display_path: "mix.exs"}) == %{dir: nil, name: "mix.exs"}
  end

  test "a rename stays one piece" do
    assert diff_file_name(%{display_path: "lib/old.ex → lib/new.ex"}) == %{dir: nil, name: "lib/old.ex → lib/new.ex"}
  end
end
