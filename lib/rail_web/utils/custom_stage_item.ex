defmodule RailWeb.Utils.CustomStageItem do
  @moduledoc """
  The task page's item for one custom stage of an issue's sequence, named in the URL by the stage's position, since a
  stage's name is the workflow file's own text.
  """

  alias Rail.Issues.Schemas.Issue
  alias Rail.Issues.Schemas.IssueStage

  @doc """
  Returns `%{key:, name:, position:}` for the custom stage `name`, or for an item key such as `"stage-3"`, of
  `issue`'s sequence, or nil when it has no such custom stage.
  """
  def custom_stage_item(%Issue{stages: stages}, "stage-" <> number) do
    with {position, ""} <- Integer.parse(number),
         %IssueStage{stage: :custom, name: name} <- position > 0 && Enum.at(stages, position - 1) do
      %{key: "stage-#{position}", name: name, position: position}
    else
      _no_such_stage -> nil
    end
  end

  def custom_stage_item(%Issue{stages: stages}, {:custom, name}) do
    Enum.find_value(Enum.with_index(stages, 1), fn {stage, position} ->
      match?(%IssueStage{stage: :custom, name: ^name}, stage) &&
        %{key: "stage-#{position}", name: name, position: position}
    end)
  end

  def custom_stage_item(%Issue{}, _other), do: nil
end
