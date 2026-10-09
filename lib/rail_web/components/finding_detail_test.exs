defmodule RailWeb.Components.FindingDetailTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Rail.Learnings.Schemas.Learning
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote
  alias Rail.Pipeline.Schemas.FindingPlace
  alias RailWeb.Components.FindingDetail

  @at ~U[2026-10-09 12:00:00Z]
  @finding %Finding{
    key: "send-twice",
    kind: :code,
    raised_by: :code_reviewer,
    round: 1,
    title: "Send twice",
    problem: "Sends twice.",
    file: "lib/a.ex",
    line: 3,
    fix: "Guard it.",
    why: "Two runs.",
    severity: :major,
    recommendation: :fix,
    places: [],
    evidence: [],
    notes: []
  }
  @attrs [position: 1, count: 1, decidable: true, running: false, neighbours: %{}, target: nil]

  test "a suppressed finding names the rule that suppressed it, and offers only Fix" do
    finding = %{@finding | suppressed_by_id: "lrn_quiet"}

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component(
        [finding: finding, suppressor: %Learning{id: "lrn_quiet", rule: "Don't flag a missing @doc"}] ++ @attrs
      )
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=finding_suppressor]") |> Floki.text() =~ "Don't flag a missing @doc"
    assert [_fix] = Floki.find(doc, "[data-qa=decide_fix]")
    assert [] = Floki.find(doc, "[data-qa=decide_skip]")
    assert "Suppressed" = doc |> Floki.find("[data-qa=finding_state]") |> Floki.text() |> String.trim()
  end

  test "the code range says what it leaves out, and an attached log shows its text, commit, time and browser" do
    hunk = %{display_path: "lib/a.ex", additions: 2, deletions: 1, rows: [], hidden_lines: 1, other_hunks: 2}

    log = %FindingEvidence{
      kind: :log,
      name: "server log",
      path: "evidence/send-twice/1-a.log",
      text: "boom",
      commit: "abcdef1234",
      taken_at: @at,
      browser: "explorer-2"
    }

    filed = [%{index: 0, evidence: log, kind: :inline, url: "/findings/send-twice/evidence/0"}]

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: @finding, hunk: hunk, diff_link: "/tasks/t?diff", filed: filed] ++ @attrs)
      |> Floki.parse_fragment!()

    assert "1 more line and 2 more other changes in this file." =
             doc |> Floki.find("[data-qa=finding_other_hunks]") |> Floki.text() |> String.trim()

    assert [_link] = Floki.find(doc, "[data-qa=finding_open_in_diff]")
    assert "boom" = doc |> Floki.find("[data-qa=finding_evidence_text]") |> Floki.text()
    taken = doc |> Floki.find("[data-qa=finding_evidence_taken]") |> Floki.text()
    assert taken =~ "abcdef1"
    assert taken =~ "QA explorer 2"
    assert taken =~ "Open"
  end

  test "a picked screenshot shows full size, and a PDF or other file shows its own icon and no text" do
    shot = %FindingEvidence{kind: :screenshot, name: "Send twice", path: "evidence/send-twice/1-a.png"}
    pdf = %FindingEvidence{kind: :log, name: "report", path: "evidence/send-twice/2-a.pdf"}
    other = %FindingEvidence{kind: :log, name: "dump", path: "evidence/send-twice/3-a.bin"}

    filed = [
      %{index: 0, evidence: shot, kind: :screenshot, url: "/evidence/0"},
      %{index: 1, evidence: pdf, kind: :pdf, url: "/evidence/1"},
      %{index: 2, evidence: other, kind: :file, url: "/evidence/2"}
    ]

    shown =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: @finding, filed: filed] ++ @attrs)
      |> Floki.parse_fragment!()

    assert [_img] = Floki.find(shown, "#finding-evidence img[src='/evidence/0']")
    assert shown |> Floki.find("[data-qa=finding_evidence_taken]") |> Floki.text() =~ "Full size"
    assert [_pdf] = Floki.find(shown, "#finding-evidence-1 .pi-file-pdf")
    assert [_file] = Floki.find(shown, "#finding-evidence-2 .pi-file")

    picked =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: @finding, filed: filed, filed_index: 2] ++ @attrs)
      |> Floki.parse_fragment!()

    assert [] = Floki.find(picked, "[data-qa=finding_evidence_text]")
    assert [] = Floki.find(picked, "#finding-evidence img")
    assert picked |> Floki.find("[data-qa=finding_evidence_taken] a[href='/evidence/2']") |> Floki.text() =~ "Open"
  end

  test "the picked piece is the one at that place in the whole evidence list, the code range counted" do
    shot = %FindingEvidence{kind: :screenshot, name: "Send twice", path: "evidence/send-twice/1-a.png"}
    log = %FindingEvidence{kind: :log, name: "server log", path: "evidence/send-twice/2-a.log", text: "boom"}

    # Index 0 is the code range, which gets no evidence tab of its own.
    filed = [
      %{index: 1, evidence: shot, kind: :screenshot, url: "/evidence/1"},
      %{index: 2, evidence: log, kind: :inline, url: "/evidence/2"}
    ]

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: @finding, filed: filed, filed_index: 2] ++ @attrs)
      |> Floki.parse_fragment!()

    assert "boom" = doc |> Floki.find("[data-qa=finding_evidence_text]") |> Floki.text()
    assert ["true"] = doc |> Floki.find("#finding-evidence-2") |> Floki.attribute("aria-selected")
  end

  test "the history reads each note in its round, naming who ruled and what each fix covered" do
    finding = %{
      @finding
      | raised_by: :explorer,
        kind: :screen,
        file: nil,
        line: nil,
        screen: "Engineer tab",
        steps: ["Click Send"],
        carried_round: 3,
        decision: :fix,
        status: :fixed,
        raised_in: "1111111aaaa",
        fixed_in: "2222222bbbb",
        rule: "Send once",
        places: [
          %FindingPlace{screen: "Engineer tab", label: "the toolbar", left_reason: "Out of reach"},
          %FindingPlace{file: "lib/b.ex", line: 1}
        ],
        evidence: [%FindingEvidence{kind: :note, name: "count", text: "2", browser: "explorer-1"}],
        notes: [
          %FindingNote{round: 1, kind: :raised, at: @at, commit: "1111111aaaa", text: "Seen twice"},
          %FindingNote{round: 1, kind: :ruling, at: @at, decision: :fix, by_id: "usr_me"},
          %FindingNote{round: 1, kind: :ruling, at: @at, decision: :skip, by_id: "usr_dana"},
          %FindingNote{round: 1, kind: :ruling, at: @at, decision: :fix, by_id: "usr_gone"},
          %FindingNote{round: 2, kind: :pass, at: @at, status: :not_fixed, commit: "3333333cccc", text: "Still"},
          %FindingNote{round: 3, kind: :carried, at: @at},
          %FindingNote{round: 2, kind: :pass, at: @at, status: :open},
          %FindingNote{
            round: 3,
            kind: :fix,
            at: @at,
            commit: "2222222bbbb",
            covered: ["Engineer tab"],
            left: ["lib/b.ex:1: Out of reach"],
            test: "test/a_test.exs: sends once"
          },
          %FindingNote{round: 4, kind: :pass, at: @at, status: :fixed, commit: "2222222bbbb"}
        ]
    }

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component(
        [
          finding: finding,
          names: %{"usr_dana" => "Dana"},
          viewer_id: "usr_me",
          labels: %{"2222222bbbb" => "Fix round 3"}
        ] ++ @attrs
      )
      |> Floki.parse_fragment!()

    assert [
             "Round 1" <> raised,
             "Round 1" <> mine,
             "Round 1" <> dana,
             "Round 1" <> someone,
             "Round 2" <> failing,
             "Round 3" <> carried,
             "Round 2" <> open,
             "Fix round 3" <> fixed,
             "Round 4" <> checked
           ] =
             doc
             |> Floki.find("[data-qa=finding_note]")
             |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

    assert raised =~ "Raised on 1111111, from qa explorer 1: Seen twice"
    assert mine =~ "You ruled Fix"
    assert dana =~ "Dana ruled Don't fix"
    assert someone =~ "Someone ruled Fix"
    assert failing =~ "Still failing on 3333333: Still"
    assert carried =~ "Carried into round 3 with its Fix ruling"
    assert open =~ "Still open"

    assert fixed =~
             "Fixed in 2222222; covers Engineer tab; leaves lib/b.ex:1: Out of reach; test that failed first: test/a_test.exs: sends once"

    assert checked =~ "Checked fixed on 2222222"
    assert doc |> Floki.find("[data-qa=finding_fixed_in]") |> Floki.text() =~ "Fix round 3"
    assert doc |> Floki.find("[data-qa=finding_round]") |> Floki.text() =~ "Round 1, carried into round 3"
    assert doc |> Floki.find("[data-qa=finding_rule]") |> Floki.text() =~ "Applies in 2 places"
    assert doc |> Floki.find("[data-qa=finding_rule]") |> Floki.text() =~ "Left as it is: Out of reach"
    assert [] = Floki.find(doc, "[data-qa=decide_fix]")
  end

  test "every severity, state and raiser reads as itself" do
    cases = [
      {%{@finding | severity: :blocker, raised_by: :review_lead}, true, "Rule on it once the round finishes",
       "Review lead"},
      {%{@finding | severity: :minor, decision: :fix}, false, "Fix", "Code reviewer"},
      {%{@finding | severity: :nit, decision: :fix, status: :not_fixed, recommendation: :skip}, false, "Still failing",
       "Code reviewer"},
      {%{@finding | decision: :skip, raised_by: :explorer}, false, "Don't fix", "QA explorer"}
    ]

    for {finding, running, state, raiser} <- cases do
      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.put([finding: finding] ++ @attrs, :running, running))
        |> Floki.parse_fragment!()

      assert ^state = doc |> Floki.find("[data-qa=finding_state]") |> Floki.text() |> String.trim()
      assert doc |> Floki.find("[data-qa=finding_recommendation]") |> Floki.text() =~ raiser
    end
  end
end
