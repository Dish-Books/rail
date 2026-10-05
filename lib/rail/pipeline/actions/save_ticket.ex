defmodule Rail.Pipeline.Actions.SaveTicket do
  @moduledoc """
  Checks a ticket the product agent saved and writes it where `read_ticket/1` reads
  it; a refused save leaves the earlier ticket as it was.
  """

  import Ecto.Changeset
  import Rail.Pipeline.Utils.FormatTicket
  import Rail.Pipeline.Utils.WriteScratchFile

  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @types %{
    title: :string,
    description: :string,
    priority: Ecto.ParameterizedType.init(Ecto.Enum, values: Issue.priorities()),
    estimate: :integer
  }

  @doc """
  Saves `attrs` as `task`'s ticket, a priority or estimate left out keeping the last
  save's, or the issue's. Returns `{:ok, ticket}` as `read_ticket/1` reads it, or `{:error, changeset}`.
  """
  def save_ticket(%Task{} = task, attrs) when is_map(attrs) do
    %Task{issue: %Issue{} = issue} = task = Repo.preload(task, :issue)
    given = attrs |> Enum.reject(fn {_field, value} -> is_nil(value) end) |> Map.new()

    changeset =
      {kept(task, issue), @types}
      |> cast(given, Map.keys(@types))
      |> update_change(:title, &String.trim/1)
      |> update_change(:description, &String.trim/1)
      |> validate_required([:title, :description])
      |> validate_format(:title, ~r/\A[^\n]*\z/, message: "must be one line")
      |> validate_number(:estimate, greater_than_or_equal_to: 0, message: "must be zero or more")

    with {:ok, ticket} <- apply_action(changeset, :insert) do
      saved = %{issue | title: ticket.title, description: ticket.description}
      saved = %{saved | priority: ticket.priority, estimate: ticket.estimate}

      write_scratch_file(Path.join([task.scratch_path, "tickets", "#{issue.identifier}.md"]), format_ticket(saved))
      Pipeline.broadcast_output_saved(task)

      {:ok, Pipeline.read_ticket(task)}
    end
  end

  # What a save leaves out stands as the last save set it, or else as the issue has it.
  defp kept(%Task{} = task, %Issue{} = issue) do
    case Pipeline.read_ticket(task) do
      %{priority: priority, estimate: estimate} ->
        %{priority: priority || issue.priority, estimate: estimate || issue.estimate}

      nil ->
        %{priority: issue.priority, estimate: issue.estimate}
    end
  end
end
