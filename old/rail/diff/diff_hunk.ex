defmodule Rail.Diff.DiffHunk do
  @moduledoc false

  defdelegate new(opts), to: Rail.Domain.Diff.DiffHunk
end
