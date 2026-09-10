defmodule RailWebTest do
  use ExUnit.Case, async: true

  test "static_paths returns list of static paths" do
    paths = RailWeb.static_paths()
    assert "assets" in paths
  end
end
