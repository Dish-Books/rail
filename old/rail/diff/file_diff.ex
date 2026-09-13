defmodule Rail.Diff.FileDiff do
  @moduledoc false

  defdelegate new(attrs), to: Rail.Domain.Diff.FileDiff
end
