defmodule Rail.Runs do
  @moduledoc """
  Context for agent CLI execution, argv/prompt building, process spawning,
  stream following, and run lifecycle management.
  """

  import Ecto.Query

  alias Rail.Domain.RunFailure
  alias Rail.Repo
  alias Rail.Runs.AgyEvents
  alias Rail.Runs.ArgvBuilder
  alias Rail.Runs.Boot
  alias Rail.Runs.ClaudeEvents
  alias Rail.Runs.Follower
  alias Rail.Runs.PromptBuilder
  alias Rail.Runs.PruneRunEvents
  alias Rail.Runs.QuestionDetector
  alias Rail.Runs.Schemas.RoleRun
  alias Rail.Runs.Schemas.Run
  alias Rail.Runs.Schemas.RunEvent
  alias Rail.Runs.Spawner
  alias Rail.Runs.ToolSummarizer

  @boot_id_key {__MODULE__, :boot_id}

  defdelegate build_argv(opts), to: ArgvBuilder
  defdelegate build_prompt(opts), to: PromptBuilder
  defdelegate chat_prompt(message), to: PromptBuilder
  defdelegate build_chat_prompt(message), to: PromptBuilder
  defdelegate detect_question(line, opts \\ []), to: QuestionDetector
  defdelegate prune_run_events(opts \\ []), to: PruneRunEvents
  defdelegate summarize_tool_input(params), to: ToolSummarizer
  defdelegate summarize_tool_input(tool_name, params), to: ToolSummarizer

  @doc """
  Determines whether a failure is transient and retryable.
  """
  def transient?(failure), do: RunFailure.transient?(failure)

  @doc """
  Returns the unique boot identifier for this BEAM node runtime.
  """
  def boot_id do
    case :persistent_term.get(@boot_id_key, nil) do
      id when is_binary(id) ->
        id

      nil ->
        id = UXID.generate!()
        :persistent_term.put(@boot_id_key, id)
        id
    end
  end

  @doc """
  Overrides the boot identifier for testing.
  """
  def debug_set_boot_id(id) when is_binary(id) do
    :persistent_term.put(@boot_id_key, id)
    :ok
  end

  @doc """
  Resets the boot identifier.
  """
  def reset_boot_id do
    :persistent_term.erase(@boot_id_key)
    :ok
  end

  @doc """
  Initializes an event accumulator state struct for either `:claude` or `:agy`.
  """
  def new_event_state(backend, opts \\ [])

  # Process lifecycle and execution

  def new_event_state(:claude, opts), do: ClaudeEvents.new(opts)

  def new_event_state(backend, opts) when is_binary(backend) do
    if String.downcase(backend) == "claude" do
      ClaudeEvents.new(opts)
    else
      AgyEvents.new(opts)
    end
  end

  def new_event_state(_other_backend, opts) do
    AgyEvents.new(opts)
  end

  @doc """
  Parses a raw line from an agent NDJSON stdout stream into the accumulator state.
  """
  def parse_line(%ClaudeEvents{} = state, line), do: ClaudeEvents.parse_line(state, line)
  def parse_line(%AgyEvents{} = state, line), do: AgyEvents.parse_line(state, line)

  @doc """
  Dispatches a decoded NDJSON event map to the appropriate backend handler.
  """

  # Persistence and query helpers

  def parse_event(%ClaudeEvents{} = state, event), do: ClaudeEvents.handle_event(state, event)
  def parse_event(%AgyEvents{} = state, event), do: AgyEvents.handle_event(state, event)

  def parse_event(backend, event) when is_atom(backend) or is_binary(backend) do
    state = new_event_state(backend)
    parse_event(state, event)
  end

  @doc """
  Spawns a detached CLI runner, records the `runs` row, and starts its Follower.
  """
  def start_run(role_run, kind, argv, opts \\ []) do
    Spawner.spawn_run(role_run, kind, argv, opts)
  end

  @doc """
  Terminates an active agent execution by run, role_run, or task ID.
  """
  def stop_run(run_or_role_run_or_task_id, opts \\ []) do
    Follower.stop_run(run_or_role_run_or_task_id, opts)
  end

  @doc """
  Checks if there is an active execution run (:starting or :running) for the given task ID.
  """
  def running?(task_id) when is_binary(task_id) do
    Repo.exists?(
      from r in Run,
        where: r.task_id == ^task_id and r.status in [:starting, :running]
    )
  end

  def running?(_other), do: false

  @doc false
  defdelegate is_running?(task_id), to: __MODULE__, as: :running?

  @doc """
  Reconciles and adopts in-flight runs on this node.
  """
  def adopt_live_runs(opts \\ []) do
    Boot.adopt_live_runs(opts)
  end

  @doc """
  Callback invoked when a run completes execution.
  """
  def on_run_finished(run, outcome) do
    Phoenix.PubSub.broadcast(Rail.PubSub, "runs", {:run_finished, run, outcome})
    {:ok, outcome}
  end

  @doc """
  Creates a new role run record.
  """
  def create_role_run(attrs) do
    %RoleRun{}
    |> RoleRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a role run by ID.
  """
  def get_role_run(id), do: Repo.get(RoleRun, id)

  @doc """
  Gets a role run by ID, raising if not found.
  """
  def get_role_run!(id), do: Repo.get!(RoleRun, id)

  @doc """
  Updates a role run record.
  """
  def update_role_run(%RoleRun{} = role_run, attrs) do
    role_run
    |> RoleRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Gets a run by ID.
  """
  def get_run(id), do: Repo.get(Run, id)

  @doc """
  Gets a run by ID, raising if not found.
  """
  def get_run!(id), do: Repo.get!(Run, id)

  @doc """
  Lists runs matching criteria.
  """
  def list_runs(opts \\ []) do
    query = from(r in Run, order_by: [desc: r.inserted_at])

    query =
      Enum.reduce(opts, query, fn
        {:role_run_id, role_run_id}, q -> where(q, [r], r.role_run_id == ^role_run_id)
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
  def list_active_runs(opts \\ []) do
    list_runs([{:status, :running} | opts])
  end

  @doc """
  Lists all run events for a role run ordered by sequence.
  """
  def list_run_events(role_run_id, opts \\ []) do
    limit = Keyword.get(opts, :limit)

    query =
      from(e in RunEvent,
        where: e.role_run_id == ^role_run_id,
        order_by: [asc: e.seq]
      )

    query = if limit, do: limit(query, ^limit), else: query
    Repo.all(query)
  end

  @doc """
  Appends an individual log or transcript line to the run_events table for a role run,
  maintaining sequential ordering and broadcasting to PubSub subscribers.
  """
  def append_run_event(role_run_or_id, line) do
    role_run_id =
      case role_run_or_id do
        %RoleRun{id: id} -> id
        id when is_binary(id) -> id
      end

    max_seq =
      Repo.one(
        from e in RunEvent,
          where: e.role_run_id == ^role_run_id,
          select: max(e.seq)
      ) || 0

    now = DateTime.utc_now()

    event_attrs = %{
      role_run_id: role_run_id,
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
      "run:#{role_run_id}",
      {:run_events, role_run_id, [event]}
    )

    event
  end

  @doc """
  Looks up the Follower GenServer PID for a given run ID if running.
  """
  def get_follower_pid(run_id) do
    case Registry.lookup(Rail.Runs.FollowerRegistry, run_id) do
      [{pid, _value}] -> pid
      _other -> nil
    end
  end
end
