defmodule RailWeb.Live.DiffFile do
  @moduledoc """
  One file of the diff pane, a component of its own so that marking it reviewed
  or re-reading it patches this file and not every line of the pane.
  """
  use RailWeb, :live_component

  alias RailWeb.Components.DiffPane

  @impl true
  def render(assigns), do: DiffPane.diff_file(assigns)
end
