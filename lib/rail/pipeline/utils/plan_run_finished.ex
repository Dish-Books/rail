defmodule Rail.Pipeline.Utils.PlanRunFinished do
  @moduledoc """
  Where a finished Plan run leaves its task: nothing is captured and nothing moves until a human approves.

  What a Plan turn can get wrong is ending short, and that is recorded on the run so the step stays
  open for the message that fixes it. No options at all is a change with no screen, and is fine.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc "Finishes `run` as the Plan step."
  def plan_run_finished(%Run{} = run, _opts) do
    task = Repo.preload(run.task, :issue)
    design = Pipeline.read_design(task, pages: false)
    options = if design, do: design.options, else: []
    incomplete = Enum.reject(options, &(File.regular?(&1.html_path) and File.regular?(&1.screenshot_path)))

    error =
      cond do
        Pipeline.read_ticket(task) == nil ->
          "The Plan agent did not save a ticket."

        options != [] and design.picked == nil and length(options) != 3 ->
          "The Plan agent saved #{length(options)} design options. It needs 3, or a pick."

        incomplete != [] ->
          "Saved design options missing a page or screenshot: #{Enum.map_join(incomplete, ", ", & &1.key)}."

        Pipeline.read_plan(task) == nil ->
          "The Plan agent did not save a plan."

        true ->
          nil
      end

    # A clean check leaves the run as the exit settled it, error and all.
    if is_binary(error) do
      {:ok, failed} = run |> Run.changeset(%{error: error}) |> Repo.update()
      %{failed | task: run.task, role: run.role}
    else
      run
    end
  end
end
