defmodule Rail.Diff.UnifiedDiffParser do
  @moduledoc false

  defdelegate parse(diff), to: Rail.Domain.Diff.UnifiedDiffParser
end
