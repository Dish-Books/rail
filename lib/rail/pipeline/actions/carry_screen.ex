defmodule Rail.Pipeline.Actions.CarryScreen do
  @moduledoc """
  Carries a screen state an earlier round shot into the task's current round as it is, for a state the round's
  change left alone, so the latest round's screens keep it without a retake. Its commit and time stay the picture's.
  """

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Stamps the newest shot of the state `key` on `task` with its current round. Returns `{:ok, shot}`, or
  `{:error, :not_found}` when no shot of it is left and `{:error, :current}` when this round already has it.
  """
  def carry_screen(%Task{} = task, key) do
    round =
      case Pipeline.read_plan(task) do
        %Round{number: number} -> number
        nil -> 0
      end

    case Enum.find(Pipeline.list_screens(task, all_rounds: true), &(&1.key == key)) do
      %{round: ^round} ->
        {:error, :current}

      %{} = shot ->
        shot = %{shot | round: round}
        record = Path.join([task.scratch_path, "qa", Path.rootname(shot.file) <> ".json"])
        write_scratch_file(record, shot |> Map.delete(:findings) |> Jason.encode!())
        Pipeline.broadcast_output_saved(task)

        {:ok, shot}

      nil ->
        {:error, :not_found}
    end
  end
end
