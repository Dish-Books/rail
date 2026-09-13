defmodule Rail.Pipeline.Utils.StartDesignRun do
  @moduledoc """
  Prepares the scratch tree the design stage works in.

  The designer reads the approved ticket and writes its directions back as files,
  so both places have to exist before the agent does. This is the only thing the
  design stage needs that no other stage does, which is why `enter_stage/3` calls
  it rather than carrying a branch for it.
  """

  alias Rail.Domain.TicketBody
  alias Rail.Issues.Schemas.Issue
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Repo

  @doc """
  Writes `task`'s ticket into scratch and makes the directory designs land in.
  """
  def start_design_run(%Task{scratch_path: scratch_path} = task) when is_binary(scratch_path) do
    File.mkdir_p!(Path.join(scratch_path, "design"))

    case Repo.preload(task, :issue) do
      %Task{issue: %Issue{} = issue} -> write_ticket(scratch_path, issue)
      %Task{} -> :ok
    end

    :ok
  end

  defp write_ticket(scratch_path, %Issue{} = issue) do
    tickets_dir = Path.join(scratch_path, "tickets")
    File.mkdir_p!(tickets_dir)

    content =
      TicketBody.format(%TicketBody{
        title: issue.title || "",
        description: issue.description || "",
        priority: issue.priority,
        estimate: issue.estimate
      })

    tickets_dir |> Path.join("#{issue.identifier}.md") |> File.write!(content)
  end
end
