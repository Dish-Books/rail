defmodule Rail.Learnings.Workers.ScheduleCurators do
  @moduledoc """
  The 06:00 UTC cron: queues a curator pass for every active project.
  """
  use Oban.Worker, queue: :learnings, max_attempts: 1

  alias Rail.Learnings.Workers.CurateLearnings
  alias Rail.Projects
  alias Rail.Scope

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    for project <- Projects.list_projects(Scope.for_system()), project.active do
      %{project_id: project.id} |> CurateLearnings.new() |> Oban.insert!()
    end

    :ok
  end
end
