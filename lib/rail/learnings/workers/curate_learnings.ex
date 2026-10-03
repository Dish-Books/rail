defmodule Rail.Learnings.Workers.CurateLearnings do
  @moduledoc """
  Runs one project's daily curator pass, unique on the project for 20 hours so a retry or a second node never runs another;
  a failed pass leaves its observations to tomorrow's.
  """
  use Oban.Worker,
    queue: :learnings,
    max_attempts: 1,
    unique: [keys: [:project_id], period: 20 * 60 * 60]

  alias Rail.Learnings
  alias Rail.Projects
  alias Rail.Projects.Schemas.Project

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"project_id" => project_id}}) do
    with {:ok, %Project{} = project} <- Projects.get_project(project_id),
         {:ok, _pass} <- Learnings.curate_learnings(project) do
      :ok
    else
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
