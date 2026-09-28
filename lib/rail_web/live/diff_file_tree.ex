defmodule RailWeb.Live.DiffFileTree do
  @moduledoc """
  The list of files beside the diff, a component of its own so that a mark or a
  selection patches the list and not every line of the pane.
  """
  use RailWeb, :live_component

  alias RailWeb.Components.DiffPane

  @impl true
  def render(assigns), do: DiffPane.diff_file_tree(assigns)
end
