defmodule Rail.Issues.Actions.GetAsset do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue
  alias Rail.Linear.Client, as: Linear

  @doc """
  Fetches a file Linear holds for `issue`, as the workspace that can read it.

  Linear serves an uploaded file only to a token, so an `<img>` in a description
  cannot fetch one itself; this is what the page's own URL reaches instead.
  """
  def get_asset(%Issue{project: project}, path) when is_binary(path) do
    Linear.get_asset(project, path)
  end
end
