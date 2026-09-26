defmodule Rail.Triage.Workers.TriageThread do
  @moduledoc """
  Runs one triage pass on a thread. A pass that finds another holding the thread
  snoozes until it is done.
  """
  use Oban.Worker,
    queue: :triage,
    max_attempts: 3,
    unique: [keys: [:thread_id], states: [:available, :scheduled]]

  alias Rail.Repo
  alias Rail.Triage
  alias Rail.Triage.Schemas.Thread

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"thread_id" => thread_id}}) do
    case Repo.get(Thread, thread_id) do
      %Thread{} = thread -> Triage.triage_thread(thread)
      nil -> :ok
    end
  end

  # The agent has thirty minutes; this leaves it room to be stopped and cleaned up after.
  @impl Oban.Worker
  def timeout(_job), do: to_timeout(minute: 40)
end
