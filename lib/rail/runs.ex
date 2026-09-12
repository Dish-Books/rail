defmodule Rail.Runs do
  @moduledoc """
  Context for agent CLI execution, argv/prompt building, process spawning,
  stream following, and run lifecycle management.
  """

  import Ecto.Query

  alias Rail.Backends.Schemas.Backend
  alias Rail.Domain.RunFailure
  alias Rail.Repo
  alias Rail.Runs.Actions
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.Boot
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.Follower
  alias Rail.Runs.Schemas.OsProcess
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Runs.ToolSummarizer

  defdelegate append_pending_answer(run, answer, opts \\ []), to: Actions.AppendPendingAnswer
  defdelegate build_args(opts), to: Actions.BuildArgs
  # Process lifecycle and execution
  defdelegate build_prompt(opts), to: Actions.BuildPrompt
  defdelegate chat_prompt(message), to: Actions.ChatPrompt
  defdelegate detect_question(line, opts \\ []), to: Actions.DetectQuestion
  defdelegate detect_questions(line, opts \\ []), to: Actions.DetectQuestion
  defdelegate summarize_tool_input(params), to: ToolSummarizer
  defdelegate summarize_tool_input(tool_name, params), to: ToolSummarizer

  # Persistence and query helpers
  @doc """
  Determines whether a failure is transient and retryable.
  """
  def transient?(failure), do: RunFailure.transient?(failure)

  @doc """
  Initializes an event accumulator state struct for either `:claude` or `:agy`.
  """
  def new_event_state(backend, opts \\ [])

  def new_event_state(%Backend{name: :claude}, opts), do: ClaudeEvents.new(opts)
  def new_event_state(%Backend{}, opts), do: AgyEvents.new(opts)

  @doc """
  Parses a raw line from an agent NDJSON stdout stream into the accumulator state.
  """
  def parse_line(%ClaudeEvents{} = state, line), do: ClaudeEvents.parse_line(state, line)
  def parse_line(%AgyEvents{} = state, line), do: AgyEvents.parse_line(state, line)

  @doc """
  Dispatches a decoded NDJSON event map to the appropriate backend handler.
  """

  def parse_event(%ClaudeEvents{} = state, event), do: ClaudeEvents.handle_event(state, event)
  def parse_event(%AgyEvents{} = state, event), do: AgyEvents.handle_event(state, event)

  def parse_event(%Backend{} = backend, event) do
    backend
    |> new_event_state()
    |> parse_event(event)
  end

  @doc """
  Spawns a detached CLI runner, records the `runs` row, and starts its Follower.
  """
  defdelegate start_os_process(run, kind, argv, opts \\ []), to: Actions.StartOsProcess

  @doc """
  Terminates an active agent execution by os process, run, or task ID.
  """
  def stop_os_process(os_process_or_run_or_task_id, opts \\ []) do
    Follower.stop_os_process(os_process_or_run_or_task_id, opts)
  end

  @doc """
  Checks if there is an active execution run (:starting or :running) for the given task ID.
  """
  def running?(task_id) when is_binary(task_id) do
    Repo.exists?(
      from r in OsProcess,
        where: r.task_id == ^task_id and r.status in [:starting, :running]
    )
  end

  def running?(_other), do: false

  @doc false
  defdelegate is_running?(task_id), to: __MODULE__, as: :running?

  @doc """
  Reconciles and adopts in-flight runs on this node.
  """
  def adopt_live_os_processes(opts \\ []) do
    Boot.adopt_live_os_processes(opts)
  end

  @doc """
  Callback invoked when a run completes execution.
  """
  def on_os_process_finished(os_process, outcome) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "os_processes", {:os_process_finished, os_process, outcome})
    {:ok, outcome}
  end

  @doc """
  Marks the run for a task/role pair as running, creating it on first use.
  """
  defdelegate start_or_resume_run(task, role, worktree_path), to: Actions.StartOrResumeRun

  @doc """
  Creates a new run record.
  """
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a run by ID.
  """
  def get_run(id), do: Repo.get(Run, id)

  @doc """
  Gets the latest run for a task, optionally filtering by role_id.
  """
  def get_latest_run_for_task(task_id, role_id \\ nil)

  def get_latest_run_for_task(task_id, role_id) when is_binary(task_id) do
    query =
      from(r in Run,
        where: r.task_id == ^task_id,
        order_by: [desc: r.inserted_at, desc: r.id],
        limit: 1
      )

    query =
      cond do
        is_binary(role_id) and role_id != "" ->
          where(query, [r], r.role_id == ^role_id)

        is_atom(role_id) and role_id != nil ->
          role_str = Atom.to_string(role_id)
          where(query, [r], r.role_id == ^role_str)

        true ->
          query
      end

    case Repo.one(query) do
      %Run{} = os_process -> {:ok, os_process}
      nil -> {:error, :not_found}
    end
  end

  def get_latest_run_for_task(_task_id, _role_id), do: {:error, :not_found}

  @doc """
  Gets a run by ID, raising if not found.
  """
  def get_run!(id), do: Repo.get!(Run, id)

  @doc """
  Updates a run record.
  """
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets a run by ID.
  """
  def get_os_process(id), do: Repo.get(OsProcess, id)

  @doc """
  Gets a run by ID, raising if not found.
  """
  def get_os_process!(id), do: Repo.get!(OsProcess, id)

  @doc """
  Lists runs matching criteria.
  """
  def list_os_processes(opts \\ []) do
    query = from(r in OsProcess, order_by: [desc: r.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:run_id, run_id}, q -> where(q, [r], r.run_id == ^run_id)
        {:task_id, task_id}, q -> where(q, [r], r.task_id == ^task_id)
        {:node, node}, q -> where(q, [r], r.node == ^node)
        {:status, status}, q -> where(q, [r], r.status == ^status)
        _other, q -> q
      end)

    Repo.all(query)
  end

  @doc """
  Lists all active runs (:starting or :running).
  """
  def list_active_os_processes(opts \\ []) do
    list_os_processes([{:status, :running} | opts])
  end

  @doc """
  Lists all run events for a run ordered by sequence.
  """
  def list_run_events(run_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from(e in RunEvent,
        where: e.run_id == ^run_id,
        order_by: [asc: e.seq]
      )

    query = if limit, do: limit(query, ^limit), else: query
    Repo.all(query)
  end

  @doc """
  Appends an individual log or transcript line to the run_events table for a run,
  maintaining sequential ordering and broadcasting to PubSub subscribers.
  """
  def append_run_event(run_or_id, line) do
    run_id =
      case run_or_id do
        %Run{id: id} -> id
        id when is_binary(id) -> id
      end

    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.run_id == ^run_id,
          select: max(e.seq)
      ) || 0

    now = DateTime.utc_now()

    event_attrs = %{
      run_id: run_id,
      seq: max_seq + 1,
      line: line,
      inserted_at: now,
      updated_at: now
    }

    {:ok, event} =
      %RunEvent{}
      |> RunEvent.changeset(event_attrs)
      |> Repo.insert()

    Phoenix.PubSub.broadcast(
      Rail.PubSub,
      "run:#{run_id}",
      {:run_events, run_id, [event]}
    )

    event
  end

  @doc """
  Looks up the Follower GenServer PID for a given run ID if running.
  """
  def get_follower_pid(os_process_id) do
    case Registry.lookup(Rail.Runs.FollowerRegistry, os_process_id) do
      [{pid, _value}] -> pid
      _other -> nil
    end
  end
end
