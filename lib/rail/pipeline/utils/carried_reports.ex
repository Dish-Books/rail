defmodule Rail.Pipeline.Utils.CarriedReports do
  @moduledoc """
  Utilities for collecting and formatting carried gate reports from `outstanding_reports`.
  """

  import Ecto.Query

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  Builds the carried gate reports text block for the engineer, excluding any role specified in `:except`.
  Returns an empty string if no gate reports are found.
  """
  def build_carried_gate_reports(%Task{} = task, opts \\ []) do
    except_role_id = Keyword.get(opts, :except)
    sections = collect_report_sections(task, except_role_id)

    if sections == [] do
      ""
    else
      "\n\n---\n\n" <>
        "Also outstanding: what the other gates last reported on this change, " <>
        "which nothing has carried to you until now and nothing else will. " <>
        "Some of it is nits they signed off over; some of it is changes they " <>
        "asked for and had no pass left to press. You are already in this " <>
        "branch: clear what is still true, and say which ones you are leaving " <>
        "and why.\n\n" <>
        Enum.join(sections, "\n\n")
    end
  end

  @doc """
  Collects all report sections as `{role_id, role_name, output_content}` triples.
  """
  def collect_report_entries(%Task{} = task, except_role_id \\ nil) do
    role_ids = Enum.reject(task.outstanding_reports || [], &(&1 == except_role_id))

    Enum.flat_map(role_ids, fn role_id ->
      run =
        Repo.one(
          from r in RoleRun,
            where: r.task_id == ^task.id and r.role_id == ^role_id,
            order_by: [desc: r.inserted_at],
            limit: 1
        )

      output = if run && run.output, do: String.trim(run.output), else: ""

      if output == "" do
        []
      else
        role_name = resolve_role_name(role_id)
        [{role_id, role_name, output}]
      end
    end)
  end

  defp collect_report_sections(%Task{} = task, except_role_id) do
    task
    |> collect_report_entries(except_role_id)
    |> Enum.map(fn {_role_id, role_name, output} ->
      "### #{role_name}\n\n#{output}"
    end)
  end

  defp resolve_role_name(role_id) do
    case Repo.get(Role, role_id) do
      %Role{name: name} when is_binary(name) and name != "" -> name
      _other -> to_string(role_id)
    end
  end
end
