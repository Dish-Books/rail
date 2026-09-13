defmodule Rail.Pipeline.DetectedQuestion do
  @moduledoc """
  A question an agent asked mid-run, parsed out of its prose.

  Carries the prompt, any offered options, and the task/role it was asked under.
  `Rail.Pipeline.Actions.DetectQuestion` builds these; `Rail.Pipeline.register_question/3`
  turns one into a persisted `Rail.Pipeline.Schemas.Question`.
  """

  @enforce_keys [:prompt]
  defstruct [
    :id,
    :prompt,
    :task_id,
    :role_id,
    :context_summary,
    options: []
  ]
end
