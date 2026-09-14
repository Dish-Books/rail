defmodule Rail.Pipeline.Actions.PickDesignOption do
  @moduledoc """
  Records which of the designer's options the human chose, and tells the designer.

  The pick is Rail's, not the agent's: it is written to `<scratch>/design/picked`,
  a file the brief tells the designer never to write. Everything after it is a
  conversation, so the designer hears about it the way it hears anything else,
  as a message from the human.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Picks the option `key` from the design `run` produced.

  Returns `{:ok, run}` once the designer has been told, the message sent or queued.
  """
  def pick_design_option(%Run{} = run, key) when is_binary(key) do
    run = Repo.preload(run, [task: :runs], force: true)

    with :ok <- pickable(run.task),
         {:ok, option} <- option(run.task, key),
         {:ok, _delivery, sent} <- Pipeline.send_message(run, message(option)) do
      File.write!(Path.join([run.task.scratch_path, "design", "picked"]), option.key)
      {:ok, sent}
    end
  end

  defp pickable(%Task{stage: stage}) when stage != :design, do: {:error, {:invalid_stage, stage}}

  defp pickable(%Task{} = task) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp option(%Task{} = task, key) do
    case Pipeline.read_design(task) do
      %{picked: picked} when is_binary(picked) -> {:error, :already_picked}
      %{options: options} -> options |> Enum.find(&(&1.key == key)) |> found()
      nil -> {:error, :design_not_found}
    end
  end

  defp found(nil), do: {:error, :option_not_found}
  defp found(option), do: {:ok, option}

  defp message(option) do
    """
    I picked #{option.title} (#{option.key}). From here on we refine only that option: \
    change #{option.key}.html, retake #{option.key}.png every time it changes, and leave \
    manifest.json and the other options as they are.
    """
  end
end
