defmodule Rail.Pipeline.Schemas.DiffCommentTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.DiffComment

  setup do
    first =
      for n <- 1..20,
          do: %{kind: :line, index: n, line_kind: if(n == 10, do: :added, else: :context), text: "line #{n}  "}

    second = [
      %{kind: :line, index: 21, line_kind: :deleted, text: "gone"},
      %{kind: :line, index: 22, line_kind: :added, text: "new"}
    ]

    rows =
      [%{kind: :hunk_header, text: "@@ -1,20 +1,20 @@"}] ++
        first ++ [%{kind: :gap}, %{kind: :hunk_header, text: "@@"}] ++ second

    %{rows: rows}
  end

  test "the block is the line's hunk cut to six lines either side, glyphs kept and the line marked", %{rows: rows} do
    assert DiffComment.calculate_context_text(rows, Enum.find(rows, &(&1[:index] == 10))) ==
             Enum.join(
               ["    line 4", "    line 5", "    line 6", "    line 7", "    line 8", "    line 9", "> + line 10"] ++
                 ["    line 11", "    line 12", "    line 13", "    line 14", "    line 15", "    line 16"],
               "\n"
             )
  end

  test "the block never crosses into the next hunk", %{rows: rows} do
    assert DiffComment.calculate_context_text(rows, Enum.find(rows, &(&1[:index] == 21))) == "> - gone\n  + new"
    assert DiffComment.calculate_context_text(rows, Enum.find(rows, &(&1[:index] == 1))) =~ ~r/\A>   line 1\n    line 2/
  end

  test "a line the rows do not hold has no block" do
    assert DiffComment.calculate_context_text([], %{kind: :line, index: 3}) == ""
  end

  test "a comment with an empty block, or a blank line, is valid" do
    changeset =
      DiffComment.changeset(%DiffComment{}, %{
        path: "a.ex",
        line_kind: :context,
        line: 3,
        line_text: "",
        context_text: "",
        filter: :branch,
        body: "Why blank?"
      })

    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :context_text) == ""
  end
end
