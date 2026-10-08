defmodule Rail.Tools.Clients.Docker do
  @moduledoc """
  The Docker Engine API, over the host's socket, for the containers Rail runs
  sandboxes in.

  It makes the call and hands back what Docker said: `{:ok, body}` for any 2xx or
  a 304 (already started, already stopped), `{:error, {:docker_api_error, status,
  body}}` for the rest, and `{:error, reason}` for a request that never got there.
  """

  @label "dev.railai.sandbox"

  def config, do: Application.get_env(:rail, :docker, [])

  @doc "What the machine has: `NCPU`, `MemTotal` and the rest of `docker info`."
  def info, do: request(method: :get, url: "/info")

  @doc """
  Creates the container for OS process `os_process_id` from a create `body`,
  named after the process and labelled with it, so Rail can find it again.
  """
  def create_container(os_process_id, body) when is_map(body) do
    labels = Map.put(body["Labels"] || %{}, @label, os_process_id)

    request(
      method: :post,
      url: "/containers/create",
      params: [name: "rail-#{os_process_id}"],
      json: Map.put(body, "Labels", labels)
    )
  end

  @doc """
  Creates the one container the shared browser runs in, under the fixed name
  `rail-browser`. It carries no sandbox label, so nothing that sweeps settled
  sandboxes ever mistakes it for one.
  """
  def create_browser_container(body) when is_map(body) do
    request(method: :post, url: "/containers/create", params: [name: "rail-browser"], json: body)
  end

  def start_container(id), do: request(method: :post, url: "/containers/#{id}/start")

  @doc "Stops a container, giving it `timeout_seconds` after SIGTERM before SIGKILL."
  def stop_container(id, timeout_seconds) when is_integer(timeout_seconds) do
    request(method: :post, url: "/containers/#{id}/stop", params: [t: timeout_seconds])
  end

  def inspect_container(id), do: request(method: :get, url: "/containers/#{id}/json")

  @doc "One reading of a container's CPU and memory, rather than a stream of them."
  def stats(id), do: request(method: :get, url: "/containers/#{id}/stats", params: [stream: false])

  @doc """
  Removes a container. `force: true` kills it first if it is still running, which
  Docker otherwise refuses to remove.
  """
  def remove_container(id, opts \\ []) do
    request(method: :delete, url: "/containers/#{id}", params: Keyword.take(opts, [:force]))
  end

  @doc "Every container carrying `label`, running or exited."
  def list_containers(label) do
    request(method: :get, url: "/containers/json", params: [all: true, filters: Jason.encode!(%{label: [label]})])
  end

  @doc """
  Runs `command`, an argv, inside the running container `id` as the sandbox's
  user, from `working_dir` with `env` added to the container's own, and returns
  `{:ok, %{output:, exit_code:}}`, stdout and stderr interleaved as written.
  """
  def exec_in_container(id, command, env, working_dir) when is_list(command) and is_map(env) do
    body = %{
      "Cmd" => command,
      "Env" => Enum.map(env, fn {key, value} -> "#{key}=#{value}" end),
      "WorkingDir" => working_dir,
      "User" => "1000:1000",
      "AttachStdout" => true,
      "AttachStderr" => true
    }

    # The caller bounds how long a command may take, so the stream is waited on for as long as it runs.
    with {:ok, %{"Id" => exec}} <- request(method: :post, url: "/containers/#{id}/exec", json: body),
         {:ok, stream} <-
           request(
             method: :post,
             url: "/exec/#{exec}/start",
             json: %{Detach: false, Tty: false},
             receive_timeout: :infinity
           ),
         {:ok, %{"ExitCode" => exit_code}} <- request(method: :get, url: "/exec/#{exec}/json") do
      {:ok, %{output: demultiplex(stream, []), exit_code: exit_code}}
    end
  end

  # Without a TTY Docker frames each write with its stream and length.
  defp demultiplex(<<_stream, 0, 0, 0, size::32, payload::binary-size(size), rest::binary>>, acc),
    do: demultiplex(rest, [acc, payload])

  defp demultiplex(_end_or_partial, acc), do: IO.iodata_to_binary(acc)

  defp request(options) do
    [base_url: "http://docker", unix_socket: Keyword.get(config(), :socket_path, "/var/run/docker.sock")]
    |> Req.new()
    |> Req.merge(Keyword.get(config(), :req_options, []))
    |> Req.request(options)
    |> case do
      {:ok, %{status: status, body: body}} when status in 200..299 or status == 304 -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:docker_api_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end
end
