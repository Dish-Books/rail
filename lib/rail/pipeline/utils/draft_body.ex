defmodule Rail.Pipeline.Utils.DraftBody do
  @moduledoc false

  alias Rail.Issues.Schemas.Issue

  @doc """
  The placeholder a draft pull request opens with, which is also how Rail knows
  a description is still its own to replace.
  """
  def draft_body(%Issue{url: url}) do
    ready = "Opened by Rail as a draft. It is marked ready for review once the change is ready to merge."
    if is_binary(url), do: "#{url}\n\n#{ready}", else: ready
  end
end
