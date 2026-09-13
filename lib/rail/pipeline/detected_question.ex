defmodule Rail.Pipeline.DetectedQuestion do
  @moduledoc """
  A question an agent asked mid-run, parsed out of its prose.

  Carries the prompt and any offered options. `Rail.Pipeline.Utils.DetectQuestions`
  builds these; `Rail.Pipeline.register_question/2` turns one into a persisted
  `Rail.Pipeline.Schemas.Question`.
  """

  @enforce_keys [:prompt]
  defstruct [
    :prompt,
    :context_summary,
    options: []
  ]
end
