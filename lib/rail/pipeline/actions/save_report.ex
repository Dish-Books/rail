defmodule Rail.Pipeline.Actions.SaveReport do
  @moduledoc """
  Saves what the engineer, QA or the code reviewer has to say about its round, in place of its last report. Nobody
  relays between agents: a report is how the next one, and the review after it, hears what this one did or saw.
  """

  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @roles [:engineer, :qa, :review]

  @doc """
  Saves `report` as `role`'s on `task`. Returns `{:ok, report}` trimmed, or `{:error, :empty_report}`.
  """
  def save_report(%Task{} = task, role, report) when role in @roles and is_binary(report) do
    case String.trim(report) do
      "" ->
        {:error, :empty_report}

      trimmed ->
        write_scratch_file(Path.join([task.scratch_path, "reports", "#{role}.md"]), trimmed <> "\n")
        Pipeline.broadcast_output_saved(task)
        {:ok, trimmed}
    end
  end
end
