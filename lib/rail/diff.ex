defmodule Rail.Diff do
  @moduledoc """
  Convenience module delegating diff operations to Domain Diff modules.
  """
  alias Rail.Domain.Diff.UnifiedDiffParser

  defdelegate parse(diff), to: UnifiedDiffParser
end
