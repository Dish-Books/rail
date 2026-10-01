defmodule RailWeb.Utils.RoleStatusLabel do
  @moduledoc """
  The line under a role's name on the task page: what that role is doing.

  `StageLabel` says this for the whole task, so it names the stage; a role tab
  already carries the name, so this says only the doing.
  """

  alias Rail.Pipeline.Schemas.Run
  alias Rail.Pipeline.Schemas.Task
  alias Rail.Roles.Schemas.Role

  @doc """
  What `run` says `role` is doing on `task`. A `nil` run reads as not started.

  Only the role for the stage the task sits at can be waiting on a human, so it
  is the only one whose finished run says what to go and read.
  """
  def role_status_label(role, run, task)

  def role_status_label(%Role{}, nil, %Task{}), do: "not started"

  def role_status_label(%Role{stage: stage} = role, %Run{} = run, %Task{stage: stage}) do
    case Run.state(run) do
      :done -> waiting_label(stage)
      state -> label(state, role, run)
    end
  end

  def role_status_label(%Role{} = role, %Run{} = run, %Task{}), do: run |> Run.state() |> label(role, run)

  # QA's report was sent back for evidence, which is a different thing from QA
  # working or failing on its own.
  defp label(:running, %Role{stage: :qa}, %Run{evidence_reminders: reminders}) when reminders > 0, do: "fixing its report"

  defp label(:failed, %Role{stage: :qa}, %Run{evidence_reminders: reminders}) when reminders > 0, do: "report not valid"

  defp label(state, %Role{}, %Run{}), do: label(state)

  defp label(:running), do: "in progress"
  defp label(:waiting), do: "waiting for resources"
  defp label(:blocked), do: "needs an answer"
  defp label(:failed), do: "failed"
  defp label(:stopped), do: "stopped"
  defp label(:done), do: "done"

  defp waiting_label(:product), do: "review the ticket"
  defp waiting_label(:design), do: "review the designs"
  defp waiting_label(:architect), do: "review the plan"
  defp waiting_label(:review), do: "review the findings"
  defp waiting_label(_other), do: "needs review"
end
