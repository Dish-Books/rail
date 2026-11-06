defmodule RailWeb.Utils.StageOutputRecipients do
  @moduledoc """
  Which stages get a custom stage's file, said as the page says it: "Review gets this file", or "Plan, Implement and
  Review get this file".
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task

  @doc "Names every stage `issue`'s sequence runs after its custom stage `name`, as a sentence without its stop."
  def stage_output_recipients(%Issue{} = issue, name) do
    later =
      issue
      |> Issue.calculate_stages()
      |> Enum.drop_while(&(&1 != {:custom, name}))
      |> Enum.drop(1)
      |> Enum.map(&Task.stage_label/1)

    case later do
      [one] -> "#{one} gets this file"
      many -> "#{Enum.join(Enum.drop(many, -1), ", ")} and #{List.last(many)} get this file"
    end
  end
end
