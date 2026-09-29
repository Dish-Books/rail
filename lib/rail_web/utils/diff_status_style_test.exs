defmodule RailWeb.Utils.DiffStatusStyleTest do
  use ExUnit.Case, async: true

  import RailWeb.Utils.DiffStatusStyle

  test "a file the change did not only edit says what became of it" do
    assert %{color: "text-emerald-500", label: "new file"} = diff_status_style(:added)
    assert %{color: "text-rose-500", label: "deleted"} = diff_status_style(:deleted)
    assert %{color: "text-violet-500", label: "renamed"} = diff_status_style(:renamed)
  end

  test "an edited file has a colour but no label" do
    assert %{color: "text-amber-500", label: nil, tint: nil} = diff_status_style(:modified)
  end
end
