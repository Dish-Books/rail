defmodule Rail.Pipeline.Utils.SendRunMessage do
  @moduledoc """
  Sends one more message to a run that already exists.

  No brief is rebuilt and no scratch is prepared: the run's conversation is resumed
  where it left off and the text is handed to the agent as the next turn. What the
  turn means when it exits is `:is_chat`'s business — a chat turn rides alongside the
  stage, anything else settles it.
  """

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs
  alias Rail.Runs.Schemas.Run

  @doc """
  Spawns the next turn on `run` carrying `text`.

  Options are `:is_chat`, false by default, and `:allow_fun`, passed through to the
  spawn.
  """
  def send_run_message(%Run{} = run, text, opts \\ []) when is_binary(text) do
    run = Repo.preload(run, [:task, role: :backend])

    case run do
      %Run{task: %Task{} = task, role: %Role{} = role} ->
        argv =
          Runs.build_args(
            backend: role.backend,
            prompt: text,
            model: role.model,
            reasoning_effort: role.reasoning_effort || "high",
            system_prompt: role.system_prompt,
            conversation_id: run.conversation_id,
            work_dir: task.worktree_path
          )

        Runs.start_os_process(run, argv, Keyword.take(opts, [:is_chat, :allow_fun]))

      _incomplete ->
        {:error, :invalid_state}
    end
  end
end
