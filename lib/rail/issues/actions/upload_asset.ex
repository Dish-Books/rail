defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  alias Rail.Linear.Client, as: Linear

  @doc """
  Uploads a file to Linear and returns the URL it can be linked from.
  """
  def upload_asset(target, filename, content_type, data_binary) do
    case Linear.file_upload(target, filename, content_type, data_binary) do
      {:ok, %{"fileUpload" => %{"uploadFile" => %{"assetUrl" => asset_url}}}} -> {:ok, asset_url}
      {:ok, _not_uploaded} -> {:error, {:linear_mutation_failed, "fileUpload"}}
      {:error, reason} -> {:error, reason}
    end
  end
end
