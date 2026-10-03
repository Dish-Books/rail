defmodule Rail.Pipeline.Actions.PickDesignOption do
  @moduledoc """
  Records which of the designer's options the human chose, and tells the designer.

  The pick is Rail's, not the agent's: it is written to `<scratch>/design/picked`,
  a file the brief tells the designer never to write. Everything after it is a
  conversation, so the designer hears about it the way it hears anything else,
  as a message from the human. The pick also deletes the options not picked.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Picks the option `key` from the design `run` produced, telling the designer as
  the scope's user.

  Returns `{:ok, run}` once the designer has been told, the message sent or queued.
  """
  def pick_design_option(%Scope{} = scope, %Run{} = run, key) when is_binary(key) do
    run = Repo.preload(run, [task: :runs], force: true)
    dir = Path.join(run.task.scratch_path, "design")

    with :ok <- pickable(run.task),
         {:ok, option, others} <- option(run.task, key),
         {:ok, _delivery, sent} <- Pipeline.send_message(scope, run, message(option)) do
      manifest = Path.join(dir, "manifest.json")
      %{"options" => entries} = manifest |> File.read!() |> Jason.decode!()
      entry = Enum.find(entries, &match?(%{"key" => ^key}, &1))
      File.write!(manifest, Jason.encode!(%{"options" => [entry]}, pretty: true))

      # An option may never have had its screenshot taken.
      for other <- others, path <- [other.html_path, other.screenshot_path] do
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
        end
      end

      File.write!(Path.join(dir, "picked"), option.key)
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
      %{options: options} -> options |> Enum.split_with(&(&1.key == key)) |> found()
      nil -> {:error, :design_not_found}
    end
  end

  defp found({[], _others}), do: {:error, :option_not_found}
  defp found({[option | _duplicates], others}), do: {:ok, option, others}

  defp message(option) do
    """
    I picked #{option.title} (#{option.key}). From here on we refine only that option: \
    change #{option.key}.html and retake #{option.key}.png every time it changes. The other \
    options are deleted and manifest.json now lists only #{option.key}; keep it that way.
    """
  end
end
