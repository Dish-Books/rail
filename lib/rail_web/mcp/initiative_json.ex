defmodule RailWeb.Mcp.InitiativeJSON do
  @moduledoc false

  alias Rail.Initiatives.Schemas.Initiative

  @doc "Each initiative's progress and expected date; its project must be loaded."
  def index(%{initiatives: initiatives, today: today}), do: %{initiatives: Enum.map(initiatives, &data(&1, today))}

  defp data(initiative, today) do
    %{
      name: initiative.name,
      project: initiative.project.key,
      percent_done: Initiative.calculate_percent(initiative),
      done: initiative.done_count,
      total: initiative.ticket_count,
      expected_on: initiative.expected_on,
      due: Initiative.calculate_due_text(initiative, today),
      url: RailWeb.Endpoint.url() <> "/initiatives/" <> initiative.id
    }
  end
end
