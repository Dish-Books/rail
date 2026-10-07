defmodule Rail.Pipeline.Actions.SavePlan do
  @moduledoc """
  Checks a plan the architect saved and writes it where `read_plan/1` reads it, with the
  design option it was written for beside it, so that option is still named after the pick deletes it.

  A plan saved once the task has left Plan with an approved plan replaces that one, so the next Engineer run
  builds from the revision. Nothing is published to the issue again.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.RecordImplementationPlan
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.ImplementationPlan
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @heading ~r/\A## Implementation plan\s*(\n|\z)/

  @doc """
  Saves `attrs` as `task`'s plan: the `plan` itself and, optionally, the `design` option key it was
  written for. Returns `{:ok, plan}` as `read_plan/1` reads it, or `{:error, changeset}`.
  """
  def save_plan(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{identifier: identifier}} = task = Repo.preload(task, :issue)
    options = design_options(task)

    changeset =
      {%{}, %{plan: :string, design: :string}}
      |> cast(attrs, [:plan, :design])
      |> update_change(:plan, &String.trim/1)
      |> validate_required([:plan])
      |> validate_format(:plan, @heading, message: "must open with the `## Implementation plan` heading")
      |> ImplementationPlan.validate_structure(:plan)
      |> validate_design(options)

    with {:ok, saved} <- apply_action(changeset, :insert) do
      dir = Path.join(task.scratch_path, "plans")
      write_scratch_file(Path.join(dir, "#{identifier}.md"), saved.plan <> "\n")

      case Enum.find(options, &(&1.key == saved[:design])) do
        %{key: key, title: title} ->
          write_scratch_file(design_path(dir, identifier), Jason.encode!(%{key: key, title: title}))

        nil ->
          File.rm(design_path(dir, identifier))
      end

      # Read as it is now: the Architect may have been handed the work before the approval landed.
      with %Task{stage: stage} = now when stage != :plan <- Repo.get(Task, task.id),
           {:ok, _approved} <- Pipeline.get_implementation_plan(now) do
        record_implementation_plan(now, saved.plan)
      end

      Pipeline.broadcast_output_saved(task)

      {:ok, Pipeline.read_plan(task)}
    end
  end

  defp design_options(%Task{} = task) do
    case Pipeline.read_design(task, pages: false) do
      %{options: options} -> options
      nil -> []
    end
  end

  defp validate_design(changeset, options) do
    keys = Enum.map(options, & &1.key)

    validate_change(changeset, :design, fn :design, key ->
      cond do
        keys == [] -> [design: "names an option, but no design options are saved; leave it out"]
        key in keys -> []
        true -> [design: "#{key} is not a saved design option; it is one of #{Enum.join(keys, ", ")}"]
      end
    end)
  end

  defp design_path(dir, identifier), do: Path.join(dir, "#{identifier}.design.json")
end
