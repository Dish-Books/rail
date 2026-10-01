defmodule Rail.Tools.Utils.EnsureBrowserHost do
  @moduledoc """
  Makes sure the one Chrome every task's browser lives in is up, and says where
  to reach it.

  One Chrome, a browser context and a tab per task: each task gets cookies and
  storage of its own, and there is one process to keep alive rather than one per
  pass. It runs where sandboxes do - its own `rail-browser` container under
  Docker, a detached process beside Rail otherwise - so it outlives Rail, and a
  deploy leaves every tab where it was.

  Its profile lives under `Rail.browser_root/0`, which is how it is found again:
  Chrome writes the port it took and its own websocket path into
  `DevToolsActivePort` once it is listening. A port that still answers is a
  Chrome that is still up. Nothing here speaks HTTP to it, so there is nothing to
  mock and nothing to race.

  Starting is serialised across the cluster, so two tasks asking at once get one
  Chrome between them.
  """

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker

  @chrome_candidates [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium",
    "/usr/bin/chromium-browser"
  ]

  @container "rail-browser"
  @gib 1024 ** 3
  @ready_timeout_ms 15_000
  @launch_attempts 2
  @poll_interval_ms 100

  @doc """
  Returns `{:ok, %{url: url, port: port}}` for the shared Chrome, starting it if
  it is not answering. `url` is its browser-level websocket.

  `opts` takes `:ready_timeout_ms` for how long a Chrome that was just started
  gets to answer, and `start: false` to only ask - `{:error, :down}` rather than
  a Chrome started just to be told something about the tabs it does not have.
  """
  def ensure_browser_host(opts \\ []) do
    :global.trans({:rail_browser_host, self()}, fn ->
      case {answering(), Keyword.get(opts, :start, true)} do
        {{:ok, host}, _start} -> {:ok, host}
        {:down, false} -> {:error, :down}
        {:down, true} -> start(Rail.sandbox_runtime(), opts)
      end
    end)
  end

  defp profile, do: Path.join(Rail.browser_root(), "profile")
  defp log_path, do: Path.join(Rail.browser_root(), "chrome.log")

  defp answering do
    with {:ok, contents} <- File.read(Path.join(profile(), "DevToolsActivePort")),
         [port, path] <- contents |> String.trim() |> String.split("\n"),
         {port, ""} <- Integer.parse(port),
         {:ok, socket} <- :gen_tcp.connect(~c"127.0.0.1", port, [], 1_000) do
      :gen_tcp.close(socket)
      {:ok, %{url: "ws://127.0.0.1:#{port}#{path}", port: port}}
    else
      _down -> :down
    end
  end

  # A Chrome that did not exit cleanly leaves its `SingletonLock`, and the next
  # one refuses the profile rather than risk it - so the locks go, and the stale
  # address with them, before anything starts.
  defp clear_profile do
    File.mkdir_p!(profile())
    File.rm(Path.join(profile(), "DevToolsActivePort"))
    for lock <- Path.wildcard(Path.join(profile(), "Singleton*")), do: File.rm(lock)
  end

  defp start(:local, opts), do: start_local(opts, @launch_attempts)
  defp start(:docker, opts), do: start_container(opts)

  # Chrome now and then hangs before it listens, a forked child stuck on a lock it
  # inherited, so one that never answers is killed with its children and started again.
  defp start_local(opts, attempts_left) do
    clear_profile()
    File.rm(log_path())

    with {:ok, executable} <- executable(),
         {:ok, _port, os_pid} <-
           Tools.spawn_os_process(executable, chrome_args(profile()), stdout_path: log_path(), stderr_path: log_path()) do
      case await(opts) do
        {:ok, host} ->
          {:ok, host}

        {:error, _never_answered} when attempts_left > 1 ->
          Tools.terminate_os_process(os_pid, group: true)
          start_local(opts, attempts_left - 1)

        {:error, reason} ->
          Tools.terminate_os_process(os_pid, group: true)
          {:error, reason}
      end
    end
  end

  # The container restarts Chrome itself if it dies, so the only thing left to
  # do for one that exists is make sure it is running and wait for it.
  defp start_container(opts) do
    with :ok <- container_running() do
      await(opts)
    end
  end

  defp container_running do
    case Docker.inspect_container(@container) do
      {:ok, %{"State" => %{"Running" => true}}} ->
        :ok

      {:ok, %{"Id" => id}} ->
        with {:ok, _started} <- Docker.start_container(id), do: :ok

      {:error, {:docker_api_error, 404, _body}} ->
        clear_profile()

        with {:ok, %{"Id" => id}} <- Docker.create_browser_container(container()),
             {:ok, _started} <- Docker.start_container(id) do
          :ok
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Host networking, so Rail and every agent sandbox reach it on localhost, and
  # the same /srv/rail binds, so its profile is where Rail reads the address from.
  # The locks are cleared on every start, because Docker restarting a crashed
  # Chrome is also a start.
  defp container do
    %{
      "Image" => Rail.sandbox_image(),
      "Cmd" => [
        "/bin/sh",
        "-c",
        ~s(rm -f "$0"/Singleton* "$0"/DevToolsActivePort; exec chromium "$@"),
        profile() | chrome_args(profile())
      ],
      "User" => "1000:1000",
      "Labels" => %{"dev.railai.browser" => "true"},
      "HostConfig" => %{
        "NetworkMode" => "host",
        "Binds" => Rail.sandbox_binds(),
        "NanoCpus" => Rail.browser_cpus() * 1_000_000_000,
        "Memory" => Rail.browser_memory_gb() * @gib,
        "MemorySwap" => Rail.browser_memory_gb() * @gib,
        "ShmSize" => Rail.browser_shm_size_gb() * @gib,
        "Init" => true,
        "RestartPolicy" => %{"Name" => "unless-stopped"}
      }
    }
  end

  # Every flag here is about making the browser Rail's rather than the machine's:
  # its own profile, no first-run interruptions, nothing throttled because no
  # window is in front, and nothing shared with a Chrome a human has open.
  defp chrome_args(profile) do
    [
      "--headless=new",
      # Chrome picks the port and writes it into the profile, so it can never
      # collide with a Chrome somebody else started on the usual one.
      "--remote-debugging-port=0",
      "--remote-allow-origins=*",
      "--user-data-dir=#{profile}",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-timer-throttling",
      "--disable-renderer-backgrounding",
      "--disable-backgrounding-occluded-windows",
      "--disable-gpu",
      # A container has no user namespaces for Chrome's sandbox, and it only opens our own apps.
      "--no-sandbox",
      "about:blank"
    ]
  end

  defp executable do
    case Enum.find(@chrome_candidates, &File.exists?/1) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:error, :chrome_not_found}
    end
  end

  defp await(opts) do
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :ready_timeout_ms, @ready_timeout_ms)
    poll(deadline)
  end

  defp poll(deadline) do
    case answering() do
      {:ok, host} ->
        {:ok, host}

      :down ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@poll_interval_ms)
          poll(deadline)
        else
          {:error, {:devtools_never_answered, last_words()}}
        end
    end
  end

  # Chrome's log says why it never came up. Beside Rail it is a file in the
  # browser's root; in a container it is the container's own output.
  defp last_words do
    case File.read(log_path()) do
      {:ok, log} -> log |> String.split("\n", trim: true) |> Enum.take(-20) |> Enum.join("\n")
      {:error, reason} -> "chrome.log unreadable: #{reason}"
    end
  end
end
