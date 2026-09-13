defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear

  def upload_asset(target, filename, content_type, data_binary) do
    with {:ok, token} <- workspace_token(target) do
      Linear.file_upload(token, filename, content_type, byte_size(data_binary), data_binary)
    end
  end
end
