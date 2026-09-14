defmodule Rail.Pipeline.Utils.DesignRunFinished do
  @moduledoc """
  Where a finished design run leaves its task.

  The designer's options stay in scratch until a human picks one and approves
  it: nothing is captured here and nothing moves. What a design run can get wrong
  is leaving fewer than three complete options behind, and that is recorded on
  the run so the stage stays open for the message that fixes it.
  """

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Run
  alias Rail.Repo

  @doc "Finishes `run` as the design stage."
  def design_run_finished(%Run{} = run, _opts) do
    design = Pipeline.read_design(run.task)
    options = if design, do: design.options, else: []
    incomplete = Enum.reject(options, &(is_binary(&1.html) and File.regular?(&1.screenshot_path)))

    error =
      cond do
        design == nil -> "The designer did not write design/manifest.json."
        length(options) != 3 -> "The designer wrote #{length(options)} design options, not 3."
        incomplete != [] -> "Design options missing a page or screenshot: #{Enum.map_join(incomplete, ", ", & &1.key)}."
        true -> nil
      end

    {:ok, finished} = run |> Run.changeset(%{error: error}) |> Repo.update()
    %{finished | task: run.task, role: run.role}
  end
end
