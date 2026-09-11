defmodule Rail.Runs.Boot do
  @moduledoc """
  Reconciles in-flight runs at application boot.
  """
  use Task, restart: :transient

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Rail.Backends.Schemas.Backend
  alias Rail.Pipeline
  alias Rail.Repo
  alias Rail.Runs
  alias Rail.Runs.Follower
  alias Rail.Runs.FollowerSupervisor
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Tools

  @default_starting_timeout_seconds 60

  @doc """
  Starts the Boot reconciliation task in the supervision tree.
  """
  def start_link(opts \\ []) do
    Task.start_link(__MODULE__, :run, [opts])
  end

  @doc """
  Runs adoption if runs tables exist and adoption is enabled.
  """
  def run(opts \\ []) do
    if Application.get_env(:rail, :adopt_on_boot, true) and tables_exist?() do
      adopt_live_runs(opts)
    else
      :ok
    end

    # coveralls-ignore-start (defensive rescue on boot failure)
  rescue
    _error ->
      :ok
      # coveralls-ignore-stop
  end

  @doc """
  Adopts all in-flight runs on the current node.
  """
  def adopt_live_runs(opts \\ []) do
    current_node = Keyword.get(opts, :node) || to_string(Node.self())
    timeout_seconds = Keyword.get(opts, :timeout_seconds, @default_starting_timeout_seconds)
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    runs =
      Repo.all(
        from r in Run,
          where: r.node == ^current_node and r.status in [:starting, :running],
          preload: [:role_run],
          order_by: [asc: r.started_at]
      )

    Enum.map(runs, fn run ->
      adopt_single_run(run, now, timeout_seconds, opts)
    end)
  end

  defp adopt_single_run(run, now, timeout_seconds, opts) do
    cond do
      run.status == :starting and is_nil(run.os_pid) ->
        handle_starting_run(run, now, timeout_seconds)

      is_integer(run.os_pid) and run.os_pid > 0 and Tools.os_process_alive?(run.os_pid) ->
        handle_live_run(run, opts)

      true ->
        handle_dead_run(run, now, opts)
    end
  end

  defp handle_starting_run(run, now, timeout_seconds) do
    started_at = run.started_at || run.inserted_at
    diff = DateTime.diff(now, started_at, :second)

    if diff > timeout_seconds do
      {:ok, updated_run} =
        run
        |> Run.changeset(%{status: :finished})
        |> Repo.update()

      if run.role_run do
        error_msg = "Spawn timed out: process never acquired a PID after #{diff}s"

        {:ok, _updated_role_run} =
          run.role_run
          |> RoleRun.changeset(%{
            status: :finished,
            completed_at: now,
            exit_code: -1,
            error: error_msg
          })
          |> Repo.update()
      end

      {:failed_starting, updated_run}
    else
      {:still_starting, run}
    end
  end

  defp handle_live_run(run, opts) do
    case Registry.lookup(Rail.Runs.FollowerRegistry, run.id) do
      [{pid, _val}] ->
        {:already_following, run, pid}

      [] ->
        max_seq =
          if run.role_run do
            Repo.one(
              from e in Rail.Runs.Schemas.RunEvent,
                where: e.role_run_id == ^run.role_run.id,
                select: max(e.seq)
            ) || 0
          else
            0
          end

        follower_opts = [
          run: run,
          role_run: run.role_run,
          stream_path: run.stream_path,
          os_pid: run.os_pid,
          next_seq: max_seq + 1,
          skip_log_lines: (run.role_run && run.role_run.attempt_log_lines) || 0,
          backend: backend_for(run.role_run),
          on_finished: Keyword.get(opts, :on_finished)
        ]

        case FollowerSupervisor.start_follower(follower_opts) do
          {:ok, follower_pid} ->
            allow_sandbox(follower_pid)
            {:adopted_live, run, follower_pid}

          # coveralls-ignore-start (follower supervisor start failure)
          {:error, reason} ->
            {:error, run, reason}
            # coveralls-ignore-stop
        end
    end
  end

  # A stream is parsed by the backend that wrote it, so adoption reads the backend off
  # the role that produced the run rather than guessing.
  defp backend_for(%RoleRun{} = role_run) do
    case Repo.preload(role_run, role: :backend) do
      %RoleRun{role: %{backend: %Backend{} = backend}} -> backend
      _unconfigured -> %Backend{name: :claude}
    end
  end

  defp backend_for(_role_run), do: %Backend{name: :claude}

  # coveralls-ignore-start (test sandbox fallback)
  defp allow_sandbox(pid) do
    if Code.ensure_loaded?(Sandbox) do
      Sandbox.allow(Repo, self(), pid)
    end
  rescue
    _error -> :ok
  end

  # coveralls-ignore-stop

  defp handle_dead_run(run, now, opts) do
    role_run = run.role_run || Repo.get(RoleRun, run.role_run_id)
    backend = backend_for(role_run)

    event_state =
      Runs.new_event_state(backend,
        task_id: run.task_id,
        role_id: (role_run && role_run.role_id) || "",
        conversation_id: role_run && role_run.conversation_id
      )

    {lines, err_lines} = read_entire_stream_and_err(run.stream_path)

    updated_event_state =
      Enum.reduce(lines, event_state, fn line, acc ->
        Runs.parse_line(acc, line)
      end)

    raw_stderr =
      err_lines
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")

    error =
      compute_dead_error(
        updated_event_state.result_error,
        raw_stderr,
        updated_event_state.saw_result,
        run.os_pid
      )

    exit_code =
      compute_dead_exit_code(
        updated_event_state.saw_result,
        updated_event_state.result_error,
        raw_stderr
      )

    {:ok, updated_run} =
      run
      |> Run.changeset(%{status: :adopted_dead})
      |> Repo.update()

    if role_run do
      role_run_attrs = %{
        status: :finished,
        completed_at: now,
        exit_code: exit_code,
        error: error,
        usage: updated_event_state.usage,
        conversation_id: updated_event_state.conversation_id || role_run.conversation_id
      }

      {:ok, updated_role_run} =
        role_run
        |> RoleRun.changeset(role_run_attrs)
        |> Repo.update()

      outcome = %{
        exit_code: exit_code,
        error: error,
        usage: updated_event_state.usage,
        conversation_id: updated_event_state.conversation_id || role_run.conversation_id,
        detected_questions: updated_event_state.detected_questions,
        run: updated_run,
        role_run: updated_role_run
      }

      # Questions register before the run settles, so whoever handles `on_finished`
      # already sees the task parked on them.
      if role_run.task_id && updated_event_state.detected_questions != [] && updated_run.kind != :chat do
        Pipeline.register_questions(
          role_run.task_id,
          role_run.id,
          updated_event_state.detected_questions
        )
      end

      if is_function(Keyword.get(opts, :on_finished), 2) do
        opts[:on_finished].(updated_run, outcome)
      else
        Runs.on_run_finished(updated_run, outcome)
      end

      Phoenix.PubSub.broadcast(Rail.PubSub, "run:#{role_run.id}", {:run_finished, updated_run, outcome})
    end

    {:adopted_dead, updated_run}
  end

  defp compute_dead_error(result_error, raw_stderr, saw_result, os_pid) do
    cond do
      is_binary(result_error) and result_error != "" and raw_stderr != "" ->
        "#{result_error}\n#{raw_stderr}"

      is_binary(result_error) and result_error != "" ->
        result_error

      raw_stderr != "" ->
        raw_stderr

      saw_result ->
        nil

      true ->
        "Reattached to pid #{os_pid || "unknown"}, which ended without reporting a result."
    end
  end

  defp compute_dead_exit_code(saw_result, result_error, raw_stderr) do
    if saw_result and is_nil(result_error) and raw_stderr == "" do
      0
    else
      -1
    end
  end

  defp read_entire_stream_and_err(stream_path) do
    lines =
      if File.exists?(stream_path) do
        case File.read(stream_path) do
          {:ok, binary} ->
            binary
            |> Follower.decode_utf8_lenient()
            |> String.split("\n")
            |> Enum.reject(&(&1 == ""))

          # coveralls-ignore-start (defensive read failure)
          _error ->
            []
            # coveralls-ignore-stop
        end
      else
        []
      end

    err_lines = Follower.drain_err_file("#{stream_path}.err")
    {lines, err_lines}
  end

  defp tables_exist? do
    SQL.table_exists?(Repo, "runs") and
      SQL.table_exists?(Repo, "role_runs")

    # coveralls-ignore-start (defensive rescue if db connection fails during boot)
  rescue
    _error ->
      false
      # coveralls-ignore-stop
  end
end
