defmodule Rail.Learnings.Actions.SaveTaskProposal do
  @moduledoc """
  The curator on a task proposing a rule change, or revising one of its own still pending. It only ever proposes:
  a draft is a `proposed` rule until it is approved.
  """

  import Ecto.Query
  import Rail.Learnings.Utils.BroadcastLearningsChanged
  import Rail.Learnings.Utils.EnqueueEmbedding

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Learnings.Schemas.LearningProposal
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @draft_fields [:rule, :why, :kind, :roles, :path_glob]

  @doc """
  Saves `attrs` as a proposal of `task`'s. Returns `{:ok, proposal}`, or `{:error, reason}`: `:already_decided`,
  `:not_found` for a proposal not this task's or a rule not active in its project, `:bad_action`, or the invalid
  changeset.
  """
  def save_task_proposal(%Task{} = task, attrs) do
    # Only what the agent named changes; a key it left out keeps its value.
    attrs = Map.reject(attrs, fn {_key, value} -> value in [nil, []] end)

    result =
      Repo.transaction(fn ->
        case save(task, attrs) do
          {:ok, proposal} -> proposal
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    with {:ok, %LearningProposal{} = proposal} <- result do
      enqueue_embedding([Repo.preload(proposal, :learning).learning])
      broadcast_learnings_changed(task.project_id)
      {:ok, proposal}
    end
  end

  # Locked, so an Approve waits for the revise and approves what it wrote, or the revise finds it decided.
  defp save(%Task{id: task_id, project_id: project_id}, %{proposal: proposal_id} = attrs) when is_binary(proposal_id) do
    query =
      from p in LearningProposal,
        where: p.id == ^proposal_id and p.project_id == ^project_id and p.task_id == ^task_id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      %LearningProposal{status: :pending} = proposal -> revise(Repo.preload(proposal, :learning), attrs)
      %LearningProposal{} -> {:error, :already_decided}
      nil -> {:error, :not_found}
    end
  end

  defp save(%Task{} = task, %{action: "add"} = attrs) do
    with {:ok, draft} <- insert_draft(task.project_id, attrs), do: insert_proposal(task, :add, draft.id, [], attrs)
  end

  defp save(%Task{} = task, %{action: "rewrite"} = attrs) do
    with {:ok, rule} <- active_rule(task.project_id, attrs[:target]),
         {:ok, draft} <- insert_draft(task.project_id, attrs) do
      insert_proposal(task, :rewrite, draft.id, [rule.id], attrs)
    end
  end

  defp save(%Task{} = task, %{action: "retire"} = attrs) do
    with {:ok, rule} <- active_rule(task.project_id, attrs[:target]),
         do: insert_proposal(task, :retire, rule.id, [], attrs)
  end

  defp save(%Task{}, _attrs), do: {:error, :bad_action}

  defp revise(%LearningProposal{action: action, learning: draft} = proposal, attrs) when action in [:add, :rewrite] do
    with {:ok, _draft} <- draft |> Learning.changeset(Map.take(attrs, @draft_fields)) |> Repo.update(),
         do: retitle(proposal, attrs)
  end

  defp revise(%LearningProposal{} = proposal, attrs), do: retitle(proposal, attrs)

  defp retitle(%LearningProposal{} = proposal, attrs),
    do: proposal |> Ecto.Changeset.change(Map.take(attrs, [:title, :summary])) |> Repo.update()

  # Active only: the daily pass deletes a provisional rule it proposes to retire, and this proposal with it.
  defp active_rule(project_id, id) when is_binary(id) do
    case Repo.one(from l in Learning, where: l.id == ^id and l.project_id == ^project_id and l.status == :active) do
      %Learning{} = rule -> {:ok, rule}
      nil -> {:error, :not_found}
    end
  end

  defp active_rule(_project_id, _missing), do: {:error, :not_found}

  defp insert_draft(project_id, attrs) do
    %Learning{project_id: project_id, status: :proposed}
    |> Learning.changeset(Map.take(attrs, @draft_fields))
    |> Repo.insert()
  end

  defp insert_proposal(%Task{} = task, action, learning_id, target_ids, attrs) do
    proposed = %{action: action, learning_id: learning_id, target_ids: target_ids}

    %LearningProposal{project_id: task.project_id, task_id: task.id}
    |> LearningProposal.changeset(Map.merge(Map.take(attrs, [:title, :summary]), proposed))
    |> Repo.insert()
  end
end
