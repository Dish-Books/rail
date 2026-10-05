defmodule Rail.Pipeline.Utils.WriteScratchFile do
  @moduledoc """
  Writes a file Rail owns in scratch to a hidden name and renames it into place, so
  a panel, an approval or the evidence route never reads half of it.
  """

  @doc """
  Writes `content` to `path`, creating its folder, and returns `:ok`.
  """
  def write_scratch_file(path, content) do
    dir = Path.dirname(path)
    temporary = Path.join(dir, ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp")

    File.mkdir_p!(dir)
    File.write!(temporary, content)
    File.rename!(temporary, path)
  end
end
