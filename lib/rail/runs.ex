defmodule Rail.Runs do
  @moduledoc """
  Context for agent CLI execution, argv/prompt building, process spawning,
  stream following, and run lifecycle management.
  """

  use Supervisor

  alias Rail.Runs.Actions

  @doc """
  Starts the processes this context owns: the registry followers name themselves
  in, the supervisor they run under, and the boot-time adoption pass.
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Rail.Runs.FollowerRegistry},
      Rail.Runs.FollowerSupervisor,
      Rail.Runs.Boot
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # Argv and prompt building

  defdelegate append_pending_answer(run, answer, opts \\ []), to: Actions.AppendPendingAnswer
  defdelegate build_args(opts), to: Actions.BuildArgs
  defdelegate build_prompt(opts), to: Actions.BuildPrompt
  defdelegate chat_prompt(message), to: Actions.ChatPrompt
  defdelegate detect_question(line, opts \\ []), to: Actions.DetectQuestion
  defdelegate detect_questions(line, opts \\ []), to: Actions.DetectQuestion

  # Process lifecycle and execution

  defdelegate start_os_process(run, argv), to: Actions.StartOsProcess
  defdelegate stop_os_process(os_process, opts \\ []), to: Actions.StopOsProcess

  # Persistence and query helpers

  defdelegate start_or_resume_run(task, role, worktree_path), to: Actions.StartOrResumeRun
  defdelegate create_run(attrs), to: Actions.CreateRun
  defdelegate get_run(id), to: Actions.GetRun
  defdelegate update_run(run, attrs), to: Actions.UpdateRun
  defdelegate get_os_process(id), to: Actions.GetOsProcess
  defdelegate get_active_os_process(run), to: Actions.GetActiveOsProcess
  defdelegate list_os_processes(opts \\ []), to: Actions.ListOsProcesses
  defdelegate list_run_events(run, opts \\ []), to: Actions.ListRunEvents
  defdelegate append_run_event(run, line), to: Actions.AppendRunEvent
end
