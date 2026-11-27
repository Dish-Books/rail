defmodule Rail.Tools.Utils.StartSandbox do
  @moduledoc false

  import Ecto.Query
  import Rail.Tools.Utils.LoginMounts
  import Rail.Tools.Utils.PickBackend
  import Rail.Tools.Utils.StopSandbox

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.Schemas.Backend
  alias Rail.Tools.Schemas.OsProcess
  alias Rail.Tools.Schemas.Sandbox
  alias Rail.Types.Cpus

  @gib 1024 ** 3
  @runner "/opt/rail/rail-runner"
  @arches %{"x86_64" => "amd64", "amd64" => "amd64", "aarch64" => "arm64", "arm64" => "arm64"}
  @seed_poll_ms 500

  @doc """
  Makes sure `os_process`'s task has a container running on its sandbox's disk that `os_process` can run in, and
  returns `{:ok, sandbox}`, or `{:error, reason}` when none could be started.

  A running container is used as it is, with its CPU shares raised to what its commands now reserve, unless an agent
  turn needs another account's login: the admission line holds such a turn until the container is idle, and it is made
  again here on that account. A sandbox with no container gets one, carrying the login of the account the turn is on,
  or for a command the one its run's role would be placed on. `os_process` carries its task down to the project, its
  run down to the role, and its backend.
  """
  def start_sandbox(%OsProcess{task: %Task{} = task} = os_process, %{cpus: cpus}) do
    {sandbox, new?} =
      case Repo.one(from s in Sandbox, where: s.task_id == ^task.id and s.status != :ended) do
        %Sandbox{} = sandbox -> {sandbox, false}
        nil -> {insert(task), true}
      end

    login = login(os_process, sandbox)

    cond do
      Sandbox.live?(sandbox) and login == sandbox.backend_id ->
        share(sandbox, os_process)
        {:ok, sandbox}

      Sandbox.live?(sandbox) ->
        sandbox |> stop_sandbox() |> start(os_process, login, cpus, false)

      true ->
        start(sandbox, os_process, login, cpus, new?)
    end
  end

  defp insert(%Task{project: %Project{} = project} = task) do
    id = UXID.generate!(prefix: "sbx")

    %Sandbox{id: id, task_id: task.id}
    |> Sandbox.changeset(%{
      engine: :docker,
      image: project.sandbox_image || Rail.sandbox_image(),
      volume: "rail-#{id}",
      status: :stopped
    })
    |> Repo.insert!()
  end

  # An agent turn needs its own account's login; a command keeps whatever the container has, or takes the account its
  # run's next turn would most likely go to.
  defp login(%OsProcess{kind: :agent, backend_id: backend_id}, %Sandbox{}), do: backend_id

  defp login(%OsProcess{}, %Sandbox{backend_id: backend_id}) when is_binary(backend_id), do: backend_id

  defp login(%OsProcess{run: %Run{role: %Role{cli: cli, model: model}}}, %Sandbox{}) do
    case pick_backend(cli, model, nil) do
      {placed, %Backend{id: id}} when placed in [:ok, :held] -> id
      _none -> nil
    end
  end

  defp start(%Sandbox{} = sandbox, %OsProcess{task: %Task{} = task} = os_process, login, cpus, new?) do
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    backend = login && Repo.get(Backend, login)
    File.mkdir_p!(task.scratch_path)

    with {:ok, tar} <- runner_archive(),
         {:ok, _volume} <- Docker.create_volume(sandbox.volume, sandbox.id),
         :ok <- if(new?, do: seed(sandbox, task), else: :ok),
         body = body(sandbox, os_process, task, backend, token, cpus),
         {:ok, %{"Id" => id}} <- Docker.create_sandbox_container(sandbox.id, body),
         {:ok, _started} <- put_and_start(id, tar) do
      sandbox
      |> Sandbox.changeset(%{
        status: :starting,
        container_id: id,
        token_hash: :crypto.hash(:sha256, token),
        backend_id: backend && backend.id,
        started_at: DateTime.utc_now(),
        connected_at: nil,
        ready_at: nil,
        stopped_at: nil
      })
      |> Repo.update()
    end
  end

  defp body(%Sandbox{} = sandbox, %OsProcess{} = os_process, %Task{} = task, backend, token, cpus) do
    login =
      case backend do
        %Backend{} -> login_mounts(backend, [Backend.session_dir(backend, task.worktree_path)])
        nil -> %{binds: [], tmpfs: %{}}
      end

    toolchain =
      case {Rail.toolchain_volume(), Rail.mise_data_dir()} do
        {volume, dir} when is_binary(volume) and is_binary(dir) ->
          [%{"Type" => "volume", "Source" => volume, "Target" => dir, "ReadOnly" => true}]

        _none ->
          []
      end

    %{
      "Image" => sandbox.image,
      "Entrypoint" => [@runner],
      "Cmd" => [],
      "Env" => ["RAIL_SANDBOX_URL=#{Rail.sandbox_url()}", "RAIL_SANDBOX_TOKEN=#{token}"],
      "User" => "0:0",
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => ["#{task.scratch_path}:#{task.scratch_path}" | login.binds],
        "Mounts" => [%{"Type" => "volume", "Source" => sandbox.volume, "Target" => task.worktree_path} | toolchain],
        "Tmpfs" => login.tmpfs,
        "CpuShares" => round(os_process.reserved_cpus * 1024),
        "NanoCpus" => cpus * 1_000_000_000,
        "OomScoreAdj" => 500,
        "ShmSize" => Rail.sandbox_shm_size_gb() * @gib
      }
    }
  end

  # CPU time is weighed, not capped: a busier container gets a larger share when every one wants more.
  defp share(%Sandbox{id: id, container_id: container_id}, %OsProcess{id: os_process_id, reserved_cpus: cpus}) do
    others =
      Repo.one(
        from p in OsProcess,
          where: p.sandbox_id == ^id and p.status in [:starting, :running] and p.id != ^os_process_id,
          select: type(coalesce(sum(p.reserved_cpus), 0), Cpus)
      )

    _updated = Docker.update_container(container_id, %{"CpuShares" => round((others + cpus) * 1024)})
    :ok
  end

  defp put_and_start(id, tar) do
    with {:ok, _put} <- Docker.put_archive(id, "/", tar),
         {:ok, started} <- Docker.start_container(id) do
      {:ok, started}
    else
      {:error, reason} ->
        _removed = Docker.remove_container(id, force: true)
        {:error, reason}
    end
  end

  # The runner for the host's architecture, as a tar Docker unpacks at the root of a container before it starts.
  defp runner_archive do
    with {:ok, %{"Architecture" => machine}} <- Docker.info(),
         path = Path.join([Rail.runner_dir(), "linux-#{Map.get(@arches, machine, machine)}", "rail-runner"]),
         {:ok, binary} <- path |> File.read() |> said(path) do
      {:ok, tar([{"opt/", 0o755, nil}, {"opt/rail/", 0o755, nil}, {"opt/rail/rail-runner", 0o755, binary}])}
    end
  end

  # A task from before sandboxes had disks of their own has its checkout on Rail's disk, which its first disk takes a
  # copy of, as files: no git of Rail's runs in it.
  defp seed(%Sandbox{volume: volume}, %Task{worktree_path: path}) do
    if File.dir?(Path.join(path, ".git")) do
      body = %{
        "Image" => Rail.sandbox_image(),
        "Cmd" => ["cp", "-a", "/from/.", "/to/"],
        "User" => "0:0",
        "HostConfig" => %{
          "Binds" => ["#{path}:/from:ro"],
          "Mounts" => [%{"Type" => "volume", "Source" => volume, "Target" => "/to"}]
        }
      }

      with {:ok, %{"Id" => id}} <- Docker.create_agent_container(body) do
        try do
          with {:ok, _started} <- Docker.start_container(id), do: copied(id)
        after
          _removed = Docker.remove_container(id, force: true)
        end
      end
    else
      :ok
    end
  end

  defp copied(id) do
    case Docker.inspect_container(id) do
      {:ok, %{"State" => %{"Status" => "exited", "ExitCode" => 0}}} ->
        :ok

      {:ok, %{"State" => %{"Status" => "exited", "ExitCode" => code}}} ->
        {:error, "Copying the task's checkout onto its sandbox's disk exited with #{code}"}

      {:ok, %{"State" => %{"Status" => _running}}} ->
        Process.sleep(@seed_poll_ms)
        copied(id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The few entries Docker needs, in the POSIX ustar format: a header block each, contents padded to 512, two empty
  # blocks to end.
  defp tar(entries) do
    blocks =
      Enum.map(entries, fn {name, mode, contents} ->
        size = if contents, do: byte_size(contents), else: 0
        header = header(name, mode, size, if(contents, do: "0", else: "5"))
        [header, contents || "", :binary.copy(<<0>>, rem(512 - rem(size, 512), 512))]
      end)

    IO.iodata_to_binary([blocks, :binary.copy(<<0>>, 1024)])
  end

  defp header(name, mode, size, type) do
    fields = fn checksum ->
      [
        pad(name, 100),
        octal(mode, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        checksum,
        type,
        pad("", 100),
        "ustar\0",
        "00",
        pad("", 32),
        pad("", 32),
        octal(0, 8),
        octal(0, 8),
        pad("", 155),
        pad("", 12)
      ]
    end

    sum = "        " |> fields.() |> IO.iodata_to_binary() |> :binary.bin_to_list() |> Enum.sum()
    checksum = String.pad_leading(Integer.to_string(sum, 8), 6, "0") <> <<0, 32>>
    IO.iodata_to_binary(fields.(checksum))
  end

  defp octal(value, width), do: String.pad_leading(Integer.to_string(value, 8), width - 1, "0") <> <<0>>

  defp pad(text, width), do: text <> :binary.copy(<<0>>, width - byte_size(text))

  defp said({:ok, binary}, _path), do: {:ok, binary}
  defp said({:error, reason}, path), do: {:error, "#{path}: #{:file.format_error(reason)}"}
end
