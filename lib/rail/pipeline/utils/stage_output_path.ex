defmodule Rail.Pipeline.Utils.StageOutputPath do
  @moduledoc false

  alias Rail.Pipeline.Schemas.Task

  @doc """
  Where the output of the custom stage `name`, at `position` from 1 in its issue's sequence, is kept in `task`'s
  scratch. The position keeps two names that read alike apart, and the name keeps the folder readable.
  """
  def stage_output_path(%Task{scratch_path: scratch_path}, position, name) when is_integer(position) do
    slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "-") |> String.trim("-")
    Path.join([scratch_path, "stages", "#{position}-#{slug}.md"])
  end
end
