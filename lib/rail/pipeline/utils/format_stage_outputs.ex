defmodule Rail.Pipeline.Utils.FormatStageOutputs do
  @moduledoc false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task

  @doc """
  The files `task`'s earlier custom stages saved, each under its stage's name, as a section of a brief opening with
  `lead`, or `""` when none did. `except` leaves out the stage asking, whose own file is not an earlier one.
  """
  def format_stage_outputs(%Task{} = task, lead, except \\ nil) do
    case Enum.reject(Pipeline.read_stage_outputs(task), &(&1.name == except)) do
      [] ->
        ""

      outputs ->
        files = Enum.map_join(outputs, "\n\n", &~s(<stage_output stage="#{&1.name}">\n#{&1.markdown}\n</stage_output>))
        "\n#{lead}\n\n#{files}\n"
    end
  end
end
