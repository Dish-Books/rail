defmodule Rail.Issues.Workers.CopyLinearFile do
  @moduledoc """
  Copies one Linear upload into R2 for a project moving into Rail, so a slow or failing file costs only its own retries
  and every file copied before it is kept. The last file a move waits on queues the move again, which then writes the
  tickets.
  """
  use Oban.Worker,
    queue: :linear_files,
    max_attempts: 5,
    unique: [keys: [:copy_id], states: :incomplete, period: :infinity]

  import Ecto.Query

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.LinearFileCopy
  alias Rail.Issues.Tracker.Local
  alias Rail.Issues.Workers.MoveToLocalTracker
  alias Rail.Linear.Client, as: Linear
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project
  alias Rail.Repo

  @doc "The job copying `copy`."
  def new_copy(%LinearFileCopy{id: id, project_id: project_id}), do: new(%{copy_id: id, project_id: project_id})

  @doc "Tells the projects page a move's files changed, as `{:tracker_move_progress, project_id}` on `\"tracker_moves\"`."
  def broadcast_progress(project_id),
    do: Phoenix.PubSub.broadcast(Rail.PubSub, "tracker_moves", {:tracker_move_progress, project_id})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"copy_id" => copy_id}} = job) do
    # A copy already settled, or one whose project is gone, has nothing left to do.
    with %LinearFileCopy{state: :pending} = copy <- Repo.get(LinearFileCopy, copy_id),
         {:ok, %Project{} = project} <- Projects.get_project(copy.project_id) do
      case copy_file(project, copy) do
        {:ok, copied_url} -> settle(copy, state: :copied, copied_url: copied_url)
        :gone -> settle(copy, state: :gone)
        {:error, reason} -> fail(job, copy, reason)
      end
    else
      _settled -> :ok
    end
  end

  # Stored as a file uploaded to the ticket in Rail would be. One Linear had already lost keeps its old address.
  defp copy_file(%Project{} = project, %LinearFileCopy{issue_id: issue_id, url: "https://uploads.linear.app/" <> path}) do
    filename = path |> String.split("?") |> hd() |> Path.basename()

    case Linear.get_asset(project, path) do
      {:ok, content_type, body} -> Local.upload_asset(%Issue{id: issue_id}, filename, content_type, body)
      {:error, {:linear_api_error, 404, _body}} -> :gone
      {:error, _reason} = error -> error
    end
  end

  # Locked on the project, so of two last files settling together exactly one sees nothing left and queues the move.
  # A failed file holds the move until someone tries again.
  defp settle(%LinearFileCopy{id: id, project_id: project_id}, changes) do
    {:ok, _result} =
      Repo.transaction(fn ->
        Repo.one!(from(p in Project, where: p.id == ^project_id, select: p.id, lock: "FOR UPDATE"))

        Repo.update_all(from(c in LinearFileCopy, where: c.id == ^id and c.state == :pending),
          set: [{:updated_at, DateTime.utc_now()} | changes]
        )

        unsettled = from(c in LinearFileCopy, where: c.project_id == ^project_id and c.state in [:pending, :failed])
        if not Repo.exists?(unsettled), do: %{project_id: project_id} |> MoveToLocalTracker.new() |> Oban.insert!()
      end)

    broadcast_progress(project_id)
    :ok
  end

  # Oban retries the file until its last attempt, unless Linear or R2 refused it outright; then it waits as failed.
  defp fail(%Oban.Job{attempt: attempt, max_attempts: max_attempts}, %LinearFileCopy{} = copy, reason) do
    final? = attempt >= max_attempts or refused?(reason)

    if final? do
      Repo.update_all(from(c in LinearFileCopy, where: c.id == ^copy.id and c.state == :pending),
        set: [state: :failed, error: calculate_error(copy, reason, attempt), updated_at: DateTime.utc_now()]
      )

      broadcast_progress(copy.project_id)
    end

    if final? and attempt < max_attempts, do: {:cancel, reason}, else: {:error, reason}
  end

  defp refused?(:no_workspace_token), do: true

  defp refused?({kind, status, _body}) when kind in [:linear_api_error, :r2_error],
    do: status in 400..499 and status not in [408, 429]

  defp refused?(_reason), do: false

  defp calculate_error(%LinearFileCopy{identifier: identifier, url: url}, reason, attempt) do
    tries = if attempt > 1, do: " after #{attempt} tries", else: ""

    case reason do
      {:linear_api_error, status, _body} -> "Linear answered #{status} for a file on #{identifier} (#{url})#{tries}."
      {:r2_error, status, _body} -> "Rail's file storage answered #{status} for a file on #{identifier} (#{url})#{tries}."
      :no_workspace_token -> "Rail has no Linear token for this project's workspace."
      %{__exception__: true} = e -> "Copying a file on #{identifier} (#{url}) stopped (#{Exception.message(e)})#{tries}."
    end
  end
end
