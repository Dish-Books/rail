defmodule Rail.Issues.Actions.UploadAsset do
  @moduledoc false

  import Rail.Issues.Utils.TokenResolver

  alias Rail.Issues.Clients.Linear
  alias Rail.Projects.Schemas.LinearWorkspace
  alias Rail.Projects.Schemas.Project

  def upload_asset(filename, content_type, data_binary) when is_binary(filename) do
    upload_asset(filename, content_type, data_binary, [])
  end

  def upload_asset(%Project{} = project, filename, content_type, data_binary) do
    upload_asset(filename, content_type, data_binary, project: project)
  end

  def upload_asset(%LinearWorkspace{} = workspace, filename, content_type, data_binary) do
    upload_asset(filename, content_type, data_binary, workspace: workspace)
  end

  def upload_asset(filename, content_type, data_binary, opts) when is_binary(filename) and is_list(opts) do
    target = Keyword.get(opts, :project) || Keyword.get(opts, :workspace)

    with {:ok, token} <- workspace_token(target) do
      size = byte_size(data_binary)
      Linear.file_upload(token, filename, content_type, size, data_binary)
    end
  end
end
