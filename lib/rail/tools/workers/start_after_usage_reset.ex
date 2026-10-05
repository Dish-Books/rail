defmodule Rail.Tools.Workers.StartAfterUsageReset do
  @moduledoc """
  Starts a turn that waited for usage once the reset it waited for has passed,
  one job per turn, and snoozes to the next reset while every account is still used up.
  """
  use Oban.Worker,
    queue: :tools,
    max_attempts: 3,
    unique: [keys: [:os_process_id], states: :incomplete, period: :infinity]

  alias Rail.Tools

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"os_process_id" => os_process_id}}) do
    case Tools.start_after_usage_reset(os_process_id) do
      {:waiting_for_usage, resets_at} -> {:snooze, max(DateTime.diff(resets_at, DateTime.utc_now()), 1)}
      _started_stopped_or_failed -> :ok
    end
  end
end
