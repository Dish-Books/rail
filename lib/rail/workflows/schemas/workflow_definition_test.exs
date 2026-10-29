defmodule Rail.Workflows.Schemas.WorkflowDefinitionTest do
  use ExUnit.Case, async: true

  alias Rail.Workflows.Schemas.WorkflowDefinition

  test "a file with a name, instructions and a cron schedule parses" do
    text = """
    name: Dependency updates
    schedule: "0 9 * * 1"
    instructions: |
      Update Elixir and npm dependencies to their latest compatible versions.
    """

    assert {:ok,
            %WorkflowDefinition{
              name: "Dependency updates",
              schedule: "0 9 * * 1",
              instructions: "Update Elixir and npm dependencies to their latest compatible versions."
            }} = WorkflowDefinition.parse(text)
  end

  test "text that is not YAML says so" do
    assert {:error, "not YAML: " <> _reason} = WorkflowDefinition.parse("name: [")
  end

  test "bytes that are not UTF-8 say so" do
    assert {:error, "not UTF-8 text"} = WorkflowDefinition.parse(<<0xFF, 0xFE, 0x00>>)
  end

  test "YAML that is not a map says so" do
    assert {:error, "not a map of name, schedule and instructions"} = WorkflowDefinition.parse("- a\n- b\n")
  end

  test "an empty file names every missing field" do
    assert {:error, message} = WorkflowDefinition.parse("")
    assert message =~ "name can't be blank"
    assert message =~ "instructions can't be blank"
    assert message =~ "schedule can't be blank"
  end

  test "a missing field is named" do
    assert {:error, "instructions can't be blank"} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\n")
  end

  test "an unknown key is refused" do
    assert {:error, "keys Rail does not know: \"owner\""} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nowner: dana\n")
  end

  test "a file skipping product and design parses with them as its skipped steps" do
    assert {:ok, %WorkflowDefinition{skip: [:product, :design]}} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nskip: [product, design]\n")

    assert {:ok, %WorkflowDefinition{skip: []}} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\n")
  end

  test "a file skipping a step Rail does not have names it and the steps there are" do
    assert {:error, "skip names qa, which Rail cannot skip; the steps are product, design, architect, demo"} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nskip: [design, qa]\n")

    assert {:error,
            "skip names %{\"product\" => true}, which Rail cannot skip; the steps are product, design, architect, demo"} =
             WorkflowDefinition.parse(
               "name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nskip:\n  - product: true\n"
             )

    assert {:error, "skip is not a list; the steps are product, design, architect, demo"} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\nskip: design\n")
  end

  test "a file naming an assignee parses with their login, and one without has none" do
    assert {:ok, %WorkflowDefinition{assignee: "dana"}} =
             WorkflowDefinition.parse(~s(name: Sweep\nschedule: "0 6 * * *"\ninstructions: Go\nassignee: " dana "\n))

    assert {:ok, %WorkflowDefinition{assignee: nil}} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"0 6 * * *\"\ninstructions: Go\n")
  end

  test "a schedule that is not a cron expression is refused" do
    assert {:error, "schedule is not a cron expression: " <> _reason} =
             WorkflowDefinition.parse("name: Sweep\nschedule: every monday\ninstructions: Go\n")
  end

  test "a reboot schedule is refused, since it has no time" do
    assert {:error, "schedule is not a time"} =
             WorkflowDefinition.parse("name: Sweep\nschedule: \"@reboot\"\ninstructions: Go\n")
  end

  test "a value that is not text is refused" do
    assert {:error, "name is invalid"} =
             WorkflowDefinition.parse("name: [1, 2]\nschedule: \"0 6 * * *\"\ninstructions: Go\n")
  end

  test "a daily or one-weekday schedule reads in words, any other as its expression" do
    label = &WorkflowDefinition.schedule_label(%WorkflowDefinition{schedule: &1})

    assert "Mondays at 09:00" = label.("0 9 * * 1")
    assert "Thursdays at 14:05" = label.("5 14 * * THU")
    assert "Every day at 06:00" = label.("0 6 * * *")
    assert "Every day at 00:00" = label.("@daily")
    assert "0 9 * * 1-5" = label.("0 9 * * 1-5")
    assert "0 9 1 * *" = label.("0 9 1 * *")
    assert "*/15 * * * *" = label.("*/15 * * * *")
  end
end
