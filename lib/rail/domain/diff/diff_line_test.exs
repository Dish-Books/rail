defmodule Rail.Domain.Diff.DiffLineTest do
  use Rail.DataCase, async: true

  alias Rail.Domain.Diff.DiffLine

  test "new/1 creates a DiffLine struct from map" do
    assert %DiffLine{
             kind: :added,
             old_line_number: nil,
             new_line_number: 5,
             text: "IO.puts(:hello)",
             line_index_in_file: 2
           } =
             DiffLine.new(%{
               kind: :added,
               old_line_number: nil,
               new_line_number: 5,
               text: "IO.puts(:hello)",
               line_index_in_file: 2
             })
  end

  test "new/1 creates a DiffLine struct from keyword list" do
    assert %DiffLine{
             kind: :deleted,
             old_line_number: 10,
             new_line_number: nil,
             text: "old_fn()",
             line_index_in_file: nil
           } =
             DiffLine.new(
               kind: :deleted,
               old_line_number: 10,
               new_line_number: nil,
               text: "old_fn()"
             )
  end

  test "new/1 defaults text to empty string and line numbers to nil" do
    assert %DiffLine{
             kind: :context,
             old_line_number: nil,
             new_line_number: nil,
             text: "",
             line_index_in_file: nil
           } = DiffLine.new(%{kind: :context})
  end
end
