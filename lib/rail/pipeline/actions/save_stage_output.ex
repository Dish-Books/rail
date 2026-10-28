defmodule Rail.Pipeline.Actions.SaveStageOutput do
  @moduledoc """
  Saves the markdown a custom stage's agent wrote, in place of its last save. It is the stage's whole output: the
  person approving it reads it, and every later stage is given it.
  """

  import Rail.Pipeline.Utils.StageOutputPath
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.IssueStage
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves `attrs.markdown` as the output of the custom stage `task` is at. Returns `{:ok, markdown}` trimmed,
  `{:error, :empty_output}`, or `{:error, {:invalid_stage, stage}}` once the task is at any other stage.
  """
  def save_stage_output(%Task{} = task, %{markdown: markdown}) when is_binary(markdown) do
    # Read again, so a turn still going after its stage was approved cannot write over what was approved.
    task = Task |> Repo.get!(task.id) |> Repo.preload(:issue)

    with {:ok, position} <- position(task),
         trimmed when trimmed != "" <- String.trim(markdown) do
      write_scratch_file(stage_output_path(task, position, task.custom_stage), trimmed <> "\n")
      Pipeline.broadcast_output_saved(task)
      {:ok, trimmed}
    else
      "" -> {:error, :empty_output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp position(%Task{stage: :custom, custom_stage: name, issue: issue}) do
    case Enum.find_index(issue.stages, &match?(%IssueStage{stage: :custom, name: ^name}, &1)) do
      index when is_integer(index) -> {:ok, index + 1}
      nil -> {:error, {:invalid_stage, :custom}}
    end
  end

  defp position(%Task{stage: stage}), do: {:error, {:invalid_stage, stage}}
end
