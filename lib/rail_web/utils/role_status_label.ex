defmodule RailWeb.Utils.RoleStatusLabel do
  @moduledoc """
  The line under a role's name on the task page: what that role is doing.

  `StageLabel` says this for the whole task, so it names the stage; a role tab
  already carries the name, so this says only the doing.
  """

  import RailWeb.Utils.StageLabel, only: [approval_label: 1]

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
  def role_status_label(%Role{}, %Run{status: :waiting_for_usage}, %Task{}), do: "waiting for usage"

  def role_status_label(%Role{stage: role_stage}, %Run{} = run, %Task{stage: stage} = task) do
    case {Run.state(run), role_stage == Task.role_stage(stage)} do
      {:done, true} -> waiting_label(task)
      {state, _at_its_stage} -> label(state)
    end
  end

  defp label(:running), do: "in progress"
  defp label(:waiting), do: "waiting for resources"
  defp label(:blocked), do: "needs an answer"
  defp label(:failed), do: "failed"
  defp label(:stopped), do: "stopped"
  defp label(:done), do: "done"

  # The tab and the header answer the same question, the tab in lower case.
  defp waiting_label(%Task{stage: :plan} = task), do: task |> approval_label() |> String.downcase()
  defp waiting_label(%Task{stage: :review} = task), do: task |> approval_label() |> String.downcase()

  defp waiting_label(%Task{}), do: "needs review"
end
