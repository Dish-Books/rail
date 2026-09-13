defmodule Rail.Pipeline.Actions.ApproveProductPlan do
  @moduledoc """
  Publishes the ticket a product run wrote, and enters the next stage.

  The product run writes its ticket into scratch and nothing else — everything
  that makes the ticket real happens here, because a human has to read it first.
  The UI only offers this once it has the file to show, so the file is there by
  the time this runs.

  Approving is a one-way door: the run latches `:done`, and a run already there is
  refused rather than publishing its ticket twice.
  """

  import Rail.Pipeline.Utils.ParseTicket

  alias Rail.Issues
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Approves the ticket `run` wrote and enters the stage after product.

  `opts[:skip_design]` says which that is: `false` (the default) hands the ticket
  to the designer, `true` straight to the architect. Returns `{:ok, run}` — the
  run that was handed in, latched done.
  """
  def approve_product_plan(%Run{} = run, opts \\ []) do
    run = Repo.preload(run, task: [:issue, :runs])

    with :ok <- approvable(run),
         {:ok, %Issue{} = issue} <- issue_for(run),
         :ok <- publish(run.task, issue) do
      enter_next(run, opts)
    end
  end

  defp approvable(%Run{stage_outcome: :done}), do: {:error, :already_approved}
  defp approvable(%Run{task: %Task{stage: stage}}) when stage != :product, do: {:error, {:invalid_stage, stage}}

  defp approvable(%Run{task: %Task{} = task}) do
    if Task.running?(task), do: {:error, :stage_running}, else: :ok
  end

  defp issue_for(%Run{task: %Task{issue: %Issue{} = issue}}), do: {:ok, issue}
  defp issue_for(%Run{}), do: {:error, :no_issue}

  # The ticket the product agent wrote replaces the issue's title and body. Linear
  # hears about it from the sync that write enqueues.
  defp publish(%Task{scratch_path: scratch_path}, %Issue{} = issue) do
    ticket =
      [scratch_path, "tickets", "#{issue.identifier}.md"]
      |> Path.join()
      |> File.read!()
      |> parse_ticket()

    case Issues.update_issue(issue, %{title: ticket.title, description: ticket.description}) do
      {:ok, _issue} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # The run has said all it is going to: latch it before the next stage starts, so
  # nothing that happens there can send this one round again.
  defp enter_next(%Run{} = run, opts) do
    {:ok, run} = run |> Run.changeset(%{stage_outcome: :done}) |> Repo.update()
    stage = if Keyword.get(opts, :skip_design, false), do: :architect, else: :design
    {:ok, _next} = Pipeline.enter_stage(run.task, stage, opts)

    {:ok, run}
  end
end
