defmodule Rail.Tools.Utils.ReadSandboxHost do
  @moduledoc false

  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.SandboxHost

  @timeout 5_000

  @doc """
  What host `host` has, `{:ok, %{cpus, memory_gb, image}}`, `image` being
  `:current` when its sandbox image is Rail's and `:differs` otherwise.
  """
  def read_sandbox_host(%SandboxHost{id: host_id}) do
    task =
      Task.async(fn ->
        with {:ok, %{"NCPU" => cpus, "MemTotal" => memory}} <- Docker.info(host_id),
             {:ok, %{"Id" => rail_image}} <- Docker.inspect_image(nil, Rail.sandbox_image()),
             {:ok, host_image} <- host_image(host_id) do
          {:ok,
           %{
             cpus: cpus,
             memory_gb: div(memory, 1024 ** 3),
             image: if(host_image == rail_image, do: :current, else: :differs)
           }}
        end
      end)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, read} -> read
      nil -> {:error, :timeout}
    end
  end

  defp host_image(host_id) do
    case Docker.inspect_image(host_id, Rail.sandbox_image()) do
      {:ok, %{"Id" => image}} -> {:ok, image}
      {:error, {:docker_api_error, 404, _missing}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end
end
