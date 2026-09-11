defmodule Rail.Pipeline.Utils.CarriedReports do
  @moduledoc """
  The findings the other gates left on a change, for handing to the engineer.
  """

  import Ecto.Query
  import Rail.Runs.Utils.AssistantLog

  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Roles
  alias Rail.Roles.Schemas.Role
  alias Rail.Runs.Schemas.RoleRun

  @doc """
  The carried gate reports block for the engineer, or `""` when there is nothing
  to carry.

  Each role named in `task.outstanding_reports` contributes what its latest run
  said, read from that run's log. `:except` drops one role, for the gate whose
  own findings are already being handed over separately.
  """
  def carried_reports(%Task{} = task, opts \\ []) do
    except_role_id = Keyword.get(opts, :except)

    sections =
      task.outstanding_reports
      |> List.wrap()
      |> Enum.reject(&(&1 == except_role_id))
      |> Enum.flat_map(&section_for(task, &1))

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

  defp section_for(%Task{} = task, role_id) do
    findings =
      from(r in RoleRun,
        where: r.task_id == ^task.id and r.role_id == ^role_id,
        order_by: [desc: r.inserted_at],
        limit: 1,
        select: r.id
      )
      |> Repo.one()
      |> assistant_log()
      |> String.trim()

    if findings == "" do
      []
    else
      ["### #{resolve_role_name(role_id)}\n\n#{findings}"]
    end
  end

  defp resolve_role_name(role_id) do
    case Roles.get_role(id: role_id) do
      {:ok, %Role{name: name}} when is_binary(name) and name != "" -> name
      _other -> to_string(role_id)
    end
  end
end
