defmodule Rail.Pipeline.Actions.SavePlan do
  @moduledoc """
  Checks a plan the architect saved and writes it where `read_plan/1` reads it; it
  stays a file until approval, so architect tasks in flight approve unchanged.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @heading ~r/\A## Implementation plan\s*(\n|\z)/

  @doc """
  Saves `content` as `task`'s plan. Returns `{:ok, plan}` or `{:error, changeset}`.
  """
  def save_plan(%Task{} = task, content) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)

    changeset =
      {%{}, %{content: :string}}
      |> cast(%{content: content}, [:content])
      |> update_change(:content, &String.trim/1)
      |> validate_required([:content])
      |> validate_format(:content, @heading, message: "must open with the `## Implementation plan` heading")

    with {:ok, %{content: plan}} <- apply_action(changeset, :insert) do
      write_scratch_file(Path.join([task.scratch_path, "plans", "#{identifier}.md"]), plan <> "\n")
      Pipeline.broadcast_output_saved(task)

      {:ok, plan}
    end
  end
end
