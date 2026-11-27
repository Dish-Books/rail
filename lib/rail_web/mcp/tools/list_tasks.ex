defmodule RailWeb.Mcp.Tools.ListTasks do
  @moduledoc """
  Lists tasks newest first, in one project or every project you can open: each one's ticket, stage, assignee, branch,
  pull request, and what it waits on its assignee for now. Pass waiting with assignee `me` for what waits on you: a wait
  keeps its id while it lasts, so skip ids you have already shown. Pass a task's identifier to list_findings to read
  what Review found.
  """

  use Anubis.Server.Component, type: :tool, annotations: %{readOnlyHint: true}

  import RailWeb.Utils.FindMcpAssignee
  import RailWeb.Utils.McpErrorResponse

  alias Anubis.Server.Response
  alias Rail.Pipeline
  alias Rail.Projects
  alias Rail.Scope
  alias RailWeb.Mcp.TaskJSON

  # Merged tasks are cleaned up straight after, so there is no merged stage to list.
  @stages %{"plan" => :plan, "implement" => :engineer, "review" => :review, "finalize" => :finalize}

  schema do
    field :project, :string,
      description: "A project's key or name, from list_projects. Left out, every project you can open."

    field :assignee, :string, description: "`me`, or a GitHub login: tasks whose ticket they are assigned."
    field :stage, {:enum, Map.keys(@stages)}, description: "Only tasks at this stage."

    field :waiting, :boolean,
      default: false,
      description: "Only tasks waiting on their assignee now. With assignee `me`, what waits on you."
  end

  @impl true
  def execute(params, %{assigns: %{current_scope: scope}} = frame) do
    with {:ok, project} <- if(params[:project], do: Projects.find_project(scope, params[:project]), else: {:ok, nil}),
         {:ok, owner_user_id} <- find_mcp_assignee(scope, params[:assignee]) do
      # Left out, only the projects the person can open: every project only for an admin.
      project_id = if(project, do: project.id, else: Scope.project_ids(scope))

      waits =
        [project_id: project_id, owner_user_id: owner_user_id]
        |> Pipeline.list_waits()
        |> Map.new(&{&1.run.task_id, &1})

      tasks =
        [
          project_id: project_id,
          owner_user_id: owner_user_id,
          stage: @stages[params[:stage]],
          order_by: [desc: :inserted_at, desc: :id],
          preload: [issue: :owner_user]
        ]
        |> Pipeline.list_tasks()
        |> Enum.filter(&(not params.waiting or Map.has_key?(waits, &1.id)))

      {:reply, Response.json(Response.tool(), TaskJSON.index(%{tasks: tasks, waits: waits})), frame}
    else
      {:error, reason} -> {:reply, mcp_error_response(reason), frame}
    end
  end
end
