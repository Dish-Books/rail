defmodule Rail.Tools.LoginSession do
  @moduledoc """
  Drives one `claude auth login` for a backend.

  The CLI prints a sign-in URL, then waits on stdin for the code the sign-in page
  hands back. This process holds the CLI open across that gap: it hands the URL
  to whoever started it, and writes the code to the CLI when it arrives.

  A session belongs to the process that started it and ends with it, so a
  closed page cannot leave a CLI waiting. One that is never finished expires.

  The code does not always come through Rail: the CLI also opens a browser whose
  sign-in page hands the code straight back to it. A CLI that finishes that way,
  after its URL went out and before any code arrived, tells the owner with
  `{:backend_login_exited, session, :ok | {:error, reason}}`.
  """
  use GenServer, restart: :temporary

  import Rail.Tools.Utils.BackendEnv
  import Rail.Tools.Utils.Env

  alias Rail.Tools
  alias Rail.Tools.Schemas.Backend

  @args ["auth", "login", "--claudeai"]
  @url_regex ~r{https://\S+/oauth/authorize\S*}
  @prompt_regex ~r/^.*prompted >\s*/
  @expires_after to_timeout(minute: 10)

  def start_link({%Backend{} = backend, owner}) when is_pid(owner) do
    GenServer.start_link(__MODULE__, {backend, owner})
  end

  @doc "Waits for the CLI to print its sign-in URL."
  def await_url(session), do: GenServer.call(session, :await_url, 30_000)

  @doc "Hands the CLI the code from the sign-in page and waits for it to finish."
  def submit_code(session, code), do: GenServer.call(session, {:submit_code, code}, 60_000)

  @impl true
  def init({%Backend{} = backend, owner}) do
    Process.flag(:trap_exit, true)
    Process.monitor(owner)
    Process.send_after(self(), :expire, @expires_after)

    config_dir = Backend.config_dir(backend)
    File.mkdir_p!(config_dir)

    port =
      Port.open({:spawn_executable, backend.executable_path}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: @args,
        cd: config_dir,
        env: port_env(backend)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    {:ok,
     %{
       owner: owner,
       port: port,
       os_pid: os_pid,
       output: "",
       submitted_at: 0,
       url: nil,
       waiting: nil,
       exit_status: nil
     }}
  rescue
    error -> {:stop, {:spawn_failed, Exception.message(error)}}
  end

  @impl true
  def handle_call(:await_url, _from, %{url: url} = state) when is_binary(url) do
    {:reply, {:ok, url}, state}
  end

  # coveralls-ignore-start (only after a CLI exited before its URL was asked for)
  def handle_call(_request, _from, %{exit_status: status} = state) when is_integer(status) do
    {:stop, :normal, {:error, failure(state)}, state}
  end

  # coveralls-ignore-stop

  def handle_call(:await_url, from, state) do
    {:noreply, %{state | waiting: {:url, from}}}
  end

  # A CLI that has just exited may have closed its port before its exit status
  # is handled; that status is already on its way and answers the caller.
  def handle_call({:submit_code, code}, from, state) do
    state = %{state | waiting: {:code, from}, submitted_at: byte_size(state.output)}
    Port.command(state.port, code <> "\n")
    {:noreply, state}
  rescue
    # coveralls-ignore-start (only when the CLI exits in the same instant)
    ArgumentError ->
      {:noreply, %{state | waiting: {:code, from}, submitted_at: byte_size(state.output)}}
      # coveralls-ignore-stop
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = %{state | output: state.output <> data}

    case {state.url, Regex.run(@url_regex, state.output)} do
      {nil, [url]} -> {:noreply, reply_url(%{state | url: url})}
      _unchanged -> {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | exit_status: status}

    case {state.waiting, state.url} do
      {{:code, from}, _url} when status == 0 ->
        GenServer.reply(from, :ok)
        {:stop, :normal, state}

      {{_waiting_for, from}, _url} ->
        GenServer.reply(from, {:error, failure(state)})
        {:stop, :normal, state}

      {_nobody, url} when is_binary(url) ->
        result = if status == 0, do: :ok, else: {:error, failure(state)}
        send(state.owner, {:backend_login_exited, self(), result})
        {:stop, :normal, state}

      # coveralls-ignore-start (the CLI exited before whoever started it asked for the URL)
      {_nobody, _no_url} ->
        # The next to ask is told why there is no URL.
        {:noreply, state}
        # coveralls-ignore-stop
    end
  end

  def handle_info({:DOWN, _ref, :process, _owner, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(:expire, state) do
    with {_waiting_for, from} <- state.waiting, do: GenServer.reply(from, {:error, :expired})
    {:stop, :normal, state}
  end

  # The port is linked, so its closing arrives as an exit this process traps.
  # coveralls-ignore-start (arrives after the exit status, usually once stopped)
  def handle_info({:EXIT, _port, _reason}, state), do: {:noreply, state}
  # coveralls-ignore-stop

  @impl true
  def terminate(_reason, %{exit_status: nil, os_pid: os_pid}) do
    Tools.terminate_os_process(os_pid, grace_period: 100)
  end

  def terminate(_reason, _state), do: :ok

  defp reply_url(%{waiting: {:url, from}, url: url} = state) do
    GenServer.reply(from, {:ok, url})
    %{state | waiting: nil}
  end

  # coveralls-ignore-start (a URL printed before anyone asked for it is kept for when they do)
  defp reply_url(state), do: state
  # coveralls-ignore-stop

  # What the CLI said last is why it gave up. Once a code has been sent, only
  # what came after counts, less the prompt it answered, which ends without a
  # newline and so shares a line with the answer.
  defp failure(%{output: output, submitted_at: submitted_at, exit_status: status}) do
    said = binary_part(output, submitted_at, byte_size(output) - submitted_at)

    line = said |> String.trim() |> String.split("\n") |> List.last() |> String.replace(@prompt_regex, "")

    case String.trim(line) do
      "" -> "Sign-in exited with code #{status}"
      reason -> reason
    end
  end

  defp port_env(backend) do
    backend
    |> backend_env()
    |> env()
    |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end
end
