defmodule Rail.Workflows.Actions.SyncWorkflows do
  @moduledoc false

  import Ecto.Query
  import Rail.Workflows.Utils.BroadcastWorkflowsChanged

  alias Rail.Git
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo
  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  require Logger

  @directory ".rail/workflows"
  @replace [:definition, :next_run_at, :removed_at, :updated_at]

  @doc """
  Reads `project`'s workflow files from its fetched default branch and brings their rows in line: a new or
  changed schedule moves the next due time, an invalid file has none, and a row whose file is gone is marked
  removed. The pause is left alone. Broadcasts when anything changed.

  Returns `{:ok, changed}`, how many rows were written, or `{:error, output}` when git could not list the branch.
  """
  def sync_workflows(%Project{} = project) do
    with {:ok, paths} <- Git.list_default_branch_files(project, @directory) do
      files =
        for path <- paths, Path.extname(path) in [".yml", ".yaml"], into: %{} do
          {path, read(project, path)}
        end

      # Locked, so a start moving a due time on is never written back over with the one read here.
      {:ok, rows} =
        Repo.transaction(fn ->
          existing =
            Map.new(
              Repo.all(from w in Workflow, where: w.project_id == ^project.id, lock: "FOR UPDATE"),
              &{&1.path, &1}
            )

          now = DateTime.utc_now()

          rows =
            files
            |> Map.merge(existing, fn _path, file, _workflow -> file end)
            |> Map.keys()
            |> Enum.flat_map(&row(project, existing, files, &1, now))

          Repo.insert_all(Workflow, rows, on_conflict: {:replace, @replace}, conflict_target: [:project_id, :path])
          rows
        end)

      if rows != [], do: broadcast_workflows_changed(project)

      {:ok, length(rows)}
    end
  end

  # A file that cannot be read starts nothing, the same as one that does not parse.
  defp read(project, path) do
    case Git.read_default_branch_file(project, path) do
      {:ok, text} -> WorkflowDefinition.parse(text)
      {:error, output} -> {:error, output}
    end
  end

  # The row as it should be now, or nothing when it already is.
  defp row(project, existing, files, path, now) do
    workflow = Map.get(existing, path, %Workflow{project_id: project.id, path: path})

    wanted =
      case Map.fetch(files, path) do
        {:ok, {:ok, definition}} ->
          kept? = workflow.next_run_at != nil and same_schedule?(workflow.definition, definition)

          next =
            if kept?,
              do: workflow.next_run_at,
              else: Workflow.calculate_next_run_at(%{workflow | definition: definition}, now)

          %{definition: definition, next_run_at: next, removed_at: nil}

        {:ok, {:error, message}} ->
          if workflow.definition != nil or workflow.id == nil or workflow.removed_at != nil,
            do: Logger.warning("#{project.name}'s #{path} is invalid, so it starts nothing: #{message}")

          %{definition: nil, next_run_at: nil, removed_at: nil}

        :error ->
          %{definition: workflow.definition, next_run_at: nil, removed_at: workflow.removed_at || now}
      end

    if workflow.id != nil and Map.take(workflow, Map.keys(wanted)) == wanted do
      []
    else
      [
        Map.merge(wanted, %{
          id: workflow.id || UXID.generate!(prefix: "wfl"),
          project_id: project.id,
          path: path,
          paused: workflow.paused,
          inserted_at: workflow.inserted_at || now,
          updated_at: now
        })
      ]
    end
  end

  defp same_schedule?(%WorkflowDefinition{schedule: schedule}, %WorkflowDefinition{schedule: schedule}), do: true
  defp same_schedule?(_before, _after), do: false
end
