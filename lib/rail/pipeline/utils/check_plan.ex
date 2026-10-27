defmodule Rail.Pipeline.Utils.CheckPlan do
  @moduledoc false

  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Round
  alias Rail.Pipeline.Schemas.Task

  @doc """
  Checks that `task`'s plan is whole enough to send on: a ticket, a plan and, when there are design options, a
  pick the plan is saved for with a screenshot as new as its page. Returns `{:ok, round, design}`, `design` being
  `{option, screenshot}` or `nil` when no screen changes, or `{:error, reason}` naming what is missing.
  """
  def check_plan(%Task{} = task) do
    with {:ok, %Round{} = round} <- plan(task),
         {:ok, design} <- design(task, round) do
      {:ok, round, design}
    end
  end

  defp plan(%Task{} = task) do
    case Pipeline.read_plan(task) do
      %Round{plan: plan} = round when is_binary(plan) -> {:ok, round}
      %Round{} -> {:error, :no_plan}
      nil -> {:error, :no_ticket}
    end
  end

  # With no options there is no screen, and the ticket goes out alone.
  defp design(%Task{} = task, %Round{design: design}) do
    written_for = design && design.key

    case Pipeline.read_design(task, pages: false) do
      %{options: []} -> {:ok, nil}
      %{picked: nil} -> {:error, :nothing_picked}
      %{picked: ^written_for, options: options} -> options |> Enum.find(&(&1.key == written_for)) |> screenshot()
      %{picked: _other} -> {:error, :plan_not_for_pick}
      nil -> {:ok, nil}
    end
  end

  # The screenshot is the published thing, so one older than its page would publish a design nobody approved.
  defp screenshot(option) do
    with {:ok, %File.Stat{mtime: html_mtime}} <- File.stat(option.html_path, time: :posix),
         {:ok, %File.Stat{mtime: screenshot_mtime}} <- File.stat(option.screenshot_path, time: :posix) do
      if screenshot_mtime >= html_mtime,
        do: {:ok, {option, File.read!(option.screenshot_path)}},
        else: {:error, :stale_screenshot}
    else
      {:error, _missing} -> {:error, :screenshot_missing}
    end
  end
end
