defmodule Rail.Pipeline.Schemas.QaReportTest do
  use ExUnit.Case, async: true

  alias Rail.Pipeline.Schemas.QaReport

  test "a verdict is a judgement on the whole change, and every one has a name" do
    assert QaReport.verdicts() == [:pass, :concerns, :fail]

    assert Enum.map(QaReport.verdicts(), &QaReport.verdict_label/1) == [
             "Passed",
             "Passed with concerns",
             "Failed"
           ]
  end
end
