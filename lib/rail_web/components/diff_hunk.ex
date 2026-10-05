defmodule RailWeb.Components.DiffHunk do
  @moduledoc """
  One hunk's rows, drawn the way the diff pane draws them.

  What a finding points at is a few lines of a change rather than a file, so it
  borrows the pane's rows rather than letting a second copy of them drift.
  """
  use RailWeb, :html

  attr :rows, :list, required: true

  def diff_hunk(assigns) do
    ~H"""
    <div data-qa="diff_hunk" class="diff-body">
      <div class="diff-rows">
        <.diff_row :for={row <- @rows} row={row} />
      </div>
    </div>
    """
  end
end
