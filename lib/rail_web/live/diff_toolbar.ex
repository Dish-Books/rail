defmodule RailWeb.Live.DiffToolbar do
  @moduledoc """
  The diff pane's toolbar, a component of its own so that its counts move
  without patching every line of the pane.
  """
  use RailWeb, :live_component

  alias RailWeb.Components.DiffPane

  @impl true
  def render(assigns), do: DiffPane.diff_toolbar(assigns)
end
