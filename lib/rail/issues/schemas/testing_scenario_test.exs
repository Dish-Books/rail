defmodule Rail.Issues.Schemas.TestingScenarioTest do
  use ExUnit.Case, async: true

  alias Rail.Issues.Schemas.TestingScenario

  test "the agent's scenario is unmarked, has an id of its own and keeps at most 500 characters" do
    assert %TestingScenario{id: "tsc_" <> _id, source: :agent, result: nil, images: []} =
             scenario = TestingScenario.agent(String.duplicate("a", 600))

    assert String.length(scenario.title) == 500
    refute TestingScenario.agent("One").id == TestingScenario.agent("One").id
  end

  test "a tester's scenario is trimmed, and a blank or overlong one is refused" do
    assert {:ok, %TestingScenario{id: "tsc_" <> _id, title: "Open the page", source: :tester, result: nil}} =
             %{title: "  Open the page \n"} |> TestingScenario.tester_changeset() |> Ecto.Changeset.apply_action(:insert)

    refute TestingScenario.tester_changeset(%{title: "   "}).valid?
    refute TestingScenario.tester_changeset(%{}).valid?
    refute TestingScenario.tester_changeset(%{title: String.duplicate("a", 501)}).valid?
    assert TestingScenario.tester_changeset(%{title: String.duplicate("a", 500)}).valid?
  end

  test "a result is Passed or Failed, a note is kept as typed, and each result is named" do
    scenario = TestingScenario.agent("Open it")

    assert %Ecto.Changeset{valid?: true, changes: %{result: :failed, note: " Cut off "}} =
             TestingScenario.result_changeset(scenario, %{"result" => "failed", "note" => " Cut off "})

    assert %Ecto.Changeset{valid?: true, changes: %{note: ""}} =
             TestingScenario.result_changeset(%{scenario | note: "Was"}, %{"note" => ""})

    refute TestingScenario.result_changeset(scenario, %{"result" => "skipped"}).valid?
    refute TestingScenario.result_changeset(scenario, %{"note" => String.duplicate("a", 10_001)}).valid?

    assert ["Passed", "Failed"] = Enum.map(TestingScenario.results(), &TestingScenario.result_label/1)
    assert TestingScenario.result_label(nil) == "Not marked"
  end
end
