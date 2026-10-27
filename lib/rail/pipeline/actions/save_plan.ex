defmodule Rail.Pipeline.Actions.SavePlan do
  @moduledoc """
  Saves what the Plan agent has of a task's initial plan onto its round: the ticket, the implementation plan and
  the design option the plan is written for, where `read_plan/1` reads them. A part left out stays as the last save left it, so the ticket can be
  saved before the plan exists. The task's first accepted save starts round 1.
  """

  import Ecto.Changeset

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @ticket ["title", "description", "priority", "estimate"]

  @doc """
  Saves `attrs` on `task`'s round: the ticket's `title`, `description`, `priority` and `estimate`, the `plan`, the
  `design` option key the plan is written for, and `record_demo`, whether the round should end with a demo. A
  priority or estimate never saved is the issue's.
  Returns `{:ok, round}`, `{:error, :round_approved}` once the plan is approved, or `{:error, changeset}`.
  """
  def save_plan(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{} = issue} = task = Repo.preload(task, :issue)

    given =
      attrs
      |> Map.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new(fn {field, value} -> {to_string(field), value} end)

    # Round 1 is made by the first save that is accepted, so a refused one leaves no round behind.
    round = Pipeline.read_plan(task) || %Round{task_id: task.id, number: 1}

    with %Round{approved_at: nil} <- round,
         {:ok, design} <- design(task, given),
         ticket = Map.merge(kept(round, issue), Map.take(given, @ticket)),
         attrs =
           given |> Map.take(["plan", "record_demo"]) |> Map.put("ticket", ticket) |> Map.merge(design),
         {:ok, saved} <- round |> Round.plan_changeset(attrs) |> Repo.insert_or_update() do
      Pipeline.broadcast_output_saved(task)
      {:ok, saved}
    else
      %Round{approved_at: %DateTime{}} -> {:error, :round_approved}
      {:error, changeset} -> {:error, changeset}
    end
  end

  # What the first save leaves out stands as the issue has it.
  defp kept(%Round{ticket: nil}, %Issue{} = issue) do
    Map.reject(%{"priority" => issue.priority, "estimate" => issue.estimate}, fn {_field, value} -> is_nil(value) end)
  end

  defp kept(%Round{}, %Issue{}), do: %{}

  # A plan saved naming no option is written for none, and a save without a plan leaves the option as it was.
  defp design(%Task{} = task, given) do
    options =
      case Pipeline.read_design(task, pages: false) do
        %{options: options} -> options
        nil -> []
      end

    keys = Enum.map(options, & &1.key)

    case {given, Enum.find(options, &(&1.key == given["design"]))} do
      {_given, %{key: key, title: title}} ->
        {:ok, %{"design" => %{"key" => key, "title" => title}}}

      {%{"design" => _key}, nil} when keys == [] ->
        refuse("names an option, but no design options are saved; leave it out")

      {%{"design" => key}, nil} ->
        refuse("#{key} is not a saved design option; it is one of #{Enum.join(keys, ", ")}")

      {%{"plan" => _plan}, nil} ->
        {:ok, %{"design" => nil}}

      {_ticket_only, nil} ->
        {:ok, %{}}
    end
  end

  defp refuse(message), do: {:error, add_error(cast({%{}, %{design: :string}}, %{}, []), :design, message)}
end
