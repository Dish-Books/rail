defmodule Rail.Pipeline.Actions.FileFindingIssues do
  @moduledoc """
  Files a tracker issue for each finding a Send read as ruled New issue, oldest first, as `Finding.calculate_issue/2`
  writes it. Each finding is filed under its row lock, so a second Send or a ruling waits and then finds it filed.
  """

  import Ecto.Query

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo
  alias Rail.Scope

  @doc """
  Files `findings` on `task`, its issue and project loaded, as the scope's user. Returns `{:ok, filed}`, or
  `{:error, {:issue_not_filed, title}, filed}` when the tracker refuses one, which stops the filing there.
  """
  def file_finding_issues(%Scope{} = scope, %Task{} = task, findings) when is_list(findings) do
    result =
      findings
      |> Enum.sort_by(&{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})
      |> Enum.reduce_while({:ok, []}, &file(scope, task, &1, &2))
      |> then(fn
        {:ok, filed} -> {:ok, Enum.reverse(filed)}
        {:error, reason, filed} -> {:error, reason, Enum.reverse(filed)}
      end)

    # Every open tab shows the issues filed, whether or not the tracker refused a later one.
    if match?({:ok, [_filed | _rest]}, result) or match?({:error, _reason, [_filed | _rest]}, result),
      do: Pipeline.broadcast_output_saved(task)

    result
  end

  # The tracker call sits inside the lock: a claim column would leave a finding locked by a crash before it.
  defp file(%Scope{} = scope, %Task{} = task, %Finding{id: id}, {:ok, filed}) do
    fn ->
      finding = Repo.one!(from f in Finding, where: f.id == ^id and f.task_id == ^task.id, lock: "FOR UPDATE")

      with true <- Finding.awaiting_issue?(finding),
           {:ok, issue} <- Issues.create_issue(scope, task.project, Finding.calculate_issue(finding, task)) do
        %{(finding |> Ecto.Changeset.change(issue_id: issue.id) |> Repo.update!()) | issue: issue}
      else
        false -> :skipped
        {:error, _reason} -> Repo.rollback({:issue_not_filed, finding.title})
      end
    end
    |> Repo.transaction()
    |> case do
      {:ok, :skipped} -> {:cont, {:ok, filed}}
      {:ok, %Finding{} = finding} -> {:cont, {:ok, [finding | filed]}}
      {:error, reason} -> {:halt, {:error, reason, filed}}
    end
  end
end
