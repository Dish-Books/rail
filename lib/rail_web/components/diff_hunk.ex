defmodule RailWeb.Components.DiffHunk do
  @moduledoc """
  A finding's excerpt of a file, drawn with the diff pane's rows and a bracket beside the lines it names.

  What a finding points at is a few lines rather than a file, so it borrows the pane's rows rather than
  letting a second copy of them drift, and marks its lines in a gutter so no row changes color.
  """
  use RailWeb, :html

  attr :rows, :list, required: true

  def diff_hunk(assigns) do
    # Each row with the rows either side of it, the last padded with one that is not named.
    neighbors = Enum.chunk_every([false | Enum.map(assigns.rows, &(&1[:named?] == true))], 3, 1, [false])
    assigns = assign(assigns, :rows, Enum.zip_with(assigns.rows, neighbors, &{&1, bracket(&2)}))

    ~H"""
    <div data-qa="diff_hunk" class="diff-body">
      <div class="diff-rows">
        <.diff_row :for={{row, bracket} <- @rows} row={row} gutter bracket={bracket} />
      </div>
    </div>
    """
  end

  # A named row's place in the bracket is read off its neighbors, so a run of them draws one unbroken line.
  defp bracket([_before, false, _after]), do: nil
  defp bracket([false, true, false]), do: :only
  defp bracket([false, true, true]), do: :start
  defp bracket([true, true, false]), do: :end
  defp bracket([true, true, true]), do: :middle
end
