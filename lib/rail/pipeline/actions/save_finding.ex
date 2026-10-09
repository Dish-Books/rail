defmodule Rail.Pipeline.Actions.SaveFinding do
  @moduledoc """
  Saves what the Review lead says about one finding. A new key is raised in the current round against HEAD's
  commit and checked whole; a known key only gets a dated note in the round it is said in, and its status,
  so nothing it said when raised is ever rewritten. A Fix finding a pass finds still failing is carried into
  that round with its ruling, and one ruled Don't fix is not argued again.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.AttachEvidence

  alias Rail.Git
  alias Rail.Learnings
  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Saves the finding in `attrs` on `task`. Returns `{:ok, finding}` as the row now stands, or
  `{:error, changeset}` naming what was refused.
  """
  def save_finding(%Task{} = task, attrs) when is_map(attrs) do
    task = Repo.preload(task, :issue)
    attrs = stringify(attrs)
    said = %{round: length(Pipeline.read_review(task)) + 1, at: DateTime.utc_now(), commit: head(task)}

    result =
      case is_binary(attrs["key"]) && Repo.get_by(Finding, task_id: task.id, key: attrs["key"]) do
        %Finding{decision: :skip} = finding ->
          {:error, finding |> change() |> add_error(:key, "was ruled Don't fix by the human, so leave it be")}

        %Finding{} = finding ->
          note(task, finding, attrs, said)

        _new ->
          raise_finding(task, attrs, said)
      end

    with {:ok, finding} <- result do
      Pipeline.broadcast_output_saved(task)
      {:ok, finding}
    end
  end

  defp raise_finding(%Task{} = task, attrs, said) do
    build = fn evidence ->
      %Finding{task_id: task.id, round: said.round, raised_in: said.commit}
      |> Finding.raise_changeset(Map.put(attrs, "evidence", evidence))
      |> change(link(task, attrs["checklist_rule"]))
      |> Finding.note_changeset(%{note: Map.merge(said, %{kind: :raised, text: attrs["note"]})})
    end

    with {:ok, changeset} <- attach_then(build, task, attrs["key"], attrs["evidence"], said) do
      Repo.insert(changeset)
    end
  end

  defp note(%Task{} = task, %Finding{} = finding, attrs, said) do
    status = attrs["status"] || finding.status

    build = fn evidence ->
      changeset =
        Finding.note_changeset(finding, %{
          status: status,
          evidence: evidence,
          note: Map.merge(said, %{kind: :pass, status: status, text: attrs["note"]})
        })

      carried? =
        finding.decision == :fix and get_field(changeset, :status) == :not_fixed and finding.carried_round != said.round

      if carried?,
        do: Finding.note_changeset(changeset, %{carried_round: said.round, note: Map.put(said, :kind, :carried)}),
        else: changeset
    end

    with {:ok, changeset} <- attach_then(build, task, finding.key, attrs["evidence"], said) do
      Repo.update(changeset)
    end
  end

  # Checked as cited before anything is copied, so a refused save leaves no file behind in the finding's folder.
  defp attach_then(build, %Task{} = task, key, cited, said) do
    entries = if is_list(cited), do: cited, else: []

    with %Ecto.Changeset{valid?: true} <- build.(entries),
         {:ok, attached} <- attach_evidence(task, key, entries, said) do
      {:ok, build.(attached)}
    else
      %Ecto.Changeset{} = refused -> {:error, refused}
      {:error, text} -> {:error, add_error(build.(entries), :evidence, text)}
    end
  end

  defp link(%Task{project_id: project_id}, id) when is_binary(id) do
    case Learnings.list_learnings(ids: [id], project_id: project_id) do
      {:ok, [%Learning{kind: :calibration}]} -> %{rule_id: nil, suppressed_by_id: id}
      {:ok, [%Learning{}]} -> %{rule_id: id, suppressed_by_id: nil}
      {:ok, []} -> %{rule_id: nil, suppressed_by_id: nil}
    end
  end

  defp link(%Task{}, _no_rule), do: %{rule_id: nil, suppressed_by_id: nil}

  defp head(%Task{} = task) do
    if Task.worktree_present?(task), do: Git.branch_fingerprint(task.worktree_path)[:head_sha]
  end

  # Tool calls arrive with string keys and tests write atoms; one shape is read either way.
  defp stringify(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value
end
