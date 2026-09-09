defmodule Rail.Artifacts.Actions.AssetUrl do
  @moduledoc false

  @doc """
  Builds the local asset proxy URL path for an artifact asset.
  """
  def asset_url(kind, id) do
    "/assets/#{kind}/#{id}"
  end
end
