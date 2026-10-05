defmodule Rail.Pipeline.Schemas.QaReportTest do
  use Rail.DataCase, async: true

  alias Rail.Pipeline.Schemas.QaReport

  test "a verdict is a judgement on the whole change, and every one has a name" do
    assert QaReport.verdicts() == [:pass, :concerns, :fail]

    assert Enum.map(QaReport.verdicts(), &QaReport.verdict_label/1) == [
             "Passed",
             "Passed with concerns",
             "Failed"
           ]
  end

  test "a saved verdict needs a verdict Rail knows and a summary" do
    assert QaReport.changeset(%QaReport{}, %{"verdict" => "pass", "summary" => "It works."}).valid?

    assert %{verdict: ["is invalid"], summary: ["can't be blank"]} =
             errors_on(QaReport.changeset(%QaReport{}, %{"verdict" => "great"}))
  end
end
