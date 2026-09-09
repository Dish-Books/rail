defmodule Rail.Pipeline.Actions.BringLocal do
  @moduledoc false

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Dispatcher
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Brings an issue local into the pipeline:
  - If a task already exists for this issue, returns `{:ok, existing_task}`.
  - Otherwise, transitions the Linear issue state to `:in_progress`, creates a new task
    at `:product` stage and `:queued` state, broadcasts a `pipeline_changed` event,
    triggers a queue pump on the Dispatcher, and returns `{:ok, task}`.
  """
  def bring_local(scope, issue, owner_user \\ nil)

  def bring_local(%Scope{system: true} = scope, %Issue{} = issue, owner_user) do
    do_bring_local(scope, issue, owner_user)
  end

  def bring_local(%Scope{user: %{}} = scope, %Issue{} = issue, owner_user) do
    do_bring_local(scope, issue, owner_user)
  end

  def bring_local(_scope, _issue, _owner_user), do: {:error, :not_authorized}

  defp do_bring_local(scope, issue, owner_user) do
    case Repo.one(from t in Task, where: t.issue_id == ^issue.id, limit: 1) do
      %Task{} = existing_task ->
        {:ok, existing_task}

      nil ->
        create_local_task(scope, issue, owner_user)
    end
  end

  defp create_local_task(scope, issue, owner_user) do
    project = Rail.Projects.get_project!(scope, issue.project_id)

    with {:ok, _updated_issue} <- Rail.Issues.move_state(scope, project, issue, :in_progress, owner_user),
         worktree_name = derive_worktree_name(issue),
         owner_user_id = resolve_owner_user_id(scope, owner_user),
         attrs = %{
           issue_id: issue.id,
           owner_user_id: owner_user_id,
           title: issue.title,
           description: issue.description,
           stage: :product,
           stage_state: :queued,
           worktree_name: worktree_name
         },
         {:ok, task} <- %Task{} |> Task.changeset(attrs, project.id) |> Repo.insert() do
      Rail.Pipeline.broadcast_pipeline_changed(%{task_id: task.id, event: :brought_local})
      pump_dispatcher()
      {:ok, task}
    end
  end

  defp derive_worktree_name(%Issue{branch_name: branch}) when is_binary(branch) and branch != "" do
    branch
  end

  defp derive_worktree_name(%Issue{identifier: identifier}) when is_binary(identifier) do
    identifier
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/i, "-")
  end

  defp resolve_owner_user_id(_scope, %{id: uid}) when is_binary(uid), do: uid
  defp resolve_owner_user_id(%Scope{user: %{id: uid}}, _owner_user) when is_binary(uid), do: uid
  defp resolve_owner_user_id(_scope, _owner_user), do: nil

  defp pump_dispatcher do
    if GenServer.whereis(Dispatcher) do
      Dispatcher.pump()
    end

    :ok
  end
end
