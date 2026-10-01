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

  test "a report with nothing found, or with evidence on every finding, proves itself" do
    shown = %{name: "the total", kind: :screenshot, path: "evidence/total.png", text: nil}

    assert QaReport.unproven(%QaReport{findings: []}) == []

    assert QaReport.unproven(%QaReport{
             findings: [%{key: "one", title: "One", evidence: [shown], refused: ["../x is outside the QA folder"]}]
           }) == []
  end

  test "a finding with no evidence left is named, with whatever Rail refused, in report order" do
    shown = %{name: "the total", kind: :screenshot, path: "evidence/total.png", text: nil}

    report = %QaReport{
      findings: [
        %{key: "bare", title: "Bare", evidence: [], refused: []},
        %{key: "proven", title: "Proven", evidence: [shown], refused: []},
        %{key: "climbs", title: "Climbs", evidence: [], refused: ["../../tmp/x.csv is outside the QA folder"]}
      ]
    }

    assert QaReport.unproven(report) == [
             %{key: "bare", title: "Bare", refused: []},
             %{key: "climbs", title: "Climbs", refused: ["../../tmp/x.csv is outside the QA folder"]}
           ]

    assert QaReport.evidence_reminder_limit() == 2
  end
end
