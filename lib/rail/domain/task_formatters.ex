defmodule Rail.Domain.TaskFormatters do
  @moduledoc """
  Task formatting and presentation helpers for LiveViews and components.
  Delegates all operations to `Rail.Domain.Formatters`.
  """

  alias Rail.Domain.Formatters

  defdelegate stage_label(task, opts \\ []), to: Formatters
  defdelegate stage_state_icon(task), to: Formatters
  defdelegate stage_state_color(task), to: Formatters
  defdelegate stage_state_color_class(task, variant \\ :text), to: Formatters
  defdelegate shows_as_conflicted?(task), to: Formatters
  defdelegate has_merge_conflicts?(task), to: Formatters
  defdelegate uses_design?(task, opts \\ []), to: Formatters
  defdelegate ticket_for(task), to: Formatters
  defdelegate plan_for(task), to: Formatters
end
