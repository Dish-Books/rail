defmodule Rail.Workflows.Schemas.WorkflowTest do
  use ExUnit.Case, async: true

  alias Rail.Workflows.Schemas.Workflow
  alias Rail.Workflows.Schemas.WorkflowDefinition

  test "a weekly schedule is next due at its time on its weekday" do
    weekly = %Workflow{definition: %WorkflowDefinition{schedule: "0 9 * * 1"}}

    # 2026-10-12 is a Monday.
    assert ~U[2026-10-12 09:00:00Z] = Workflow.calculate_next_run_at(weekly, ~U[2026-10-12 08:59:30.123456Z])
    assert ~U[2026-10-19 09:00:00Z] = Workflow.calculate_next_run_at(weekly, ~U[2026-10-12 09:00:00Z])
    assert ~U[2026-10-19 09:00:00Z] = Workflow.calculate_next_run_at(weekly, ~U[2026-10-14 12:00:00Z])
  end

  test "a daily schedule is next due today before its time and tomorrow after it" do
    daily = %Workflow{definition: %WorkflowDefinition{schedule: "0 6 * * *"}}

    assert ~U[2026-10-12 06:00:00Z] = Workflow.calculate_next_run_at(daily, ~U[2026-10-12 05:00:00Z])
    assert ~U[2026-10-13 06:00:00Z] = Workflow.calculate_next_run_at(daily, ~U[2026-10-12 06:00:01Z])
  end

  test "an invalid file is never due" do
    assert nil == Workflow.calculate_next_run_at(%Workflow{definition: nil}, ~U[2026-10-12 05:00:00Z])
  end
end
