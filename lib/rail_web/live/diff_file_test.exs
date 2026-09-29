defmodule RailWeb.Live.DiffFileTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import Rail.Git.Utils.ParseDiff

  alias RailWeb.Live.DiffFile

  setup do
    [file] =
      parse_diff("""
      diff --git a/lib/rail/invoices/filter.ex b/lib/rail/invoices/filter.ex
      --- a/lib/rail/invoices/filter.ex
      +++ b/lib/rail/invoices/filter.ex
      @@ -1,2 +1,2 @@
       defmodule Filter do
      -  def filter(list), do: list
      +  def filter(list, vendor), do: Enum.filter(list, vendor)
      """)

    %{
      section: %{
        id: file.path,
        target: nil,
        file: file,
        rows: file.rows,
        viewed?: false,
        collapsed?: false,
        expanded_gaps: %{}
      }
    }
  end

  test "names the file and the directory it sits in, over its lines", %{section: section} do
    html = render_component(DiffFile, section)

    assert html =~ "lib/rail/invoices/"
    assert html =~ "filter.ex"
    assert html =~ ~s(data-kind="added")
  end

  test "names both sides of a renamed file", %{section: section} do
    [renamed] =
      parse_diff("diff --git a/lib/old_name.ex b/lib/new_name.ex\n--- a/lib/old_name.ex\n+++ b/lib/new_name.ex\n")

    assert render_component(DiffFile, %{section | file: renamed, rows: []}) =~ "lib/old_name.ex → lib/new_name.ex"
  end

  test "the caret that folds it says which file", %{section: section} do
    assert render_component(DiffFile, section) =~ ~s(aria-label="Fold lib/rail/invoices/filter.ex")
  end

  test "a collapsed file is only its header", %{section: section} do
    html = render_component(DiffFile, %{section | collapsed?: true})

    refute html =~ ~s(data-kind="added")
    assert html =~ "filter.ex"
  end

  test "says it has been read", %{section: section} do
    assert render_component(DiffFile, %{section | viewed?: true}) =~ ~s(aria-pressed="true")
  end

  test "calls out what became of a file the change did not only edit", %{section: section} do
    for {status, label} <- [added: "new file", deleted: "deleted", renamed: "renamed"] do
      assert render_component(DiffFile, %{section | file: %{section.file | status: status}}) =~ label
    end

    refute render_component(DiffFile, section) =~ "diff_status_badge"
  end
end
