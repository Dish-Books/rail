defmodule Rail.Tools.Actions.SyncSandboxImage do
  @moduledoc false

  import Rail.Tools.Utils.ReadSandboxHost

  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.HostConnection
  alias Rail.Tools.Schemas.SandboxHost

  @doc """
  Copies Rail's sandbox image to `host` through a tarball under the scratch root,
  reporting progress to its connection. Returns `:ok` or `{:error, reason}` in words.
  """
  def sync_sandbox_image(%SandboxHost{id: host_id} = host) do
    dir = Path.join(Rail.scratch_root(), "sandbox-images")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{host_id}.tar")
    HostConnection.report_image(host_id, {:copying, 0, nil})

    try do
      with {:ok, _written} <- Docker.export_image(nil, Rail.sandbox_image(), path),
           {:ok, %File.Stat{size: total}} <- File.stat(path),
           {:ok, _loaded} <-
             Docker.load_image(host_id, path, &HostConnection.report_image(host_id, {:copying, &1, total})),
           {:ok, %{image: :current}} <- read_sandbox_host(host) do
        HostConnection.report_image(host_id, :current)
      else
        {:ok, %{image: :differs}} -> failed(host_id, "The image still differs after loading it.")
        {:error, reason} -> failed(host_id, reason)
      end
    after
      File.rm(path)
    end
  end

  defp failed(host_id, reason) do
    message =
      case reason do
        "" <> message ->
          message

        {:load_failed, message} ->
          message

        {:docker_api_error, status, body} ->
          with "" <> json <- body, {:ok, %{"message" => message}} <- Jason.decode(json) do
            message
          else
            _unreadable -> "Docker answered #{status}."
          end

        :host_unreachable ->
          "The host is unreachable."

        :timeout ->
          "The host did not answer in time."

        %{__exception__: true} = exception ->
          Exception.message(exception)

        other ->
          inspect(other)
      end

    HostConnection.report_image(host_id, {:failed, message})
    {:error, message}
  end
end
