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
  @named %{kind: :line, line_kind: :added, old_line: nil, new_line: 3, text: "send(round)", named?: true}
  @context %{kind: :line, line_kind: :context, old_line: 2, new_line: 2, text: "def handle do"}
  @excerpt %{
    path: "lib/a.ex",
    display_path: "lib/a.ex",
    additions: 2,
    deletions: 1,
    in_diff?: true,
    changed?: true,
    rows: [@context, @named],
    missing: nil,
    hidden_lines: 0,
    other_changes: 0
  }

  describe "comments on its pieces" do
    setup do
      finding = %{
        @finding
        | rule: "A round is sent once.",
          places: [%FindingPlace{file: "lib/a.ex", line: 3, label: "handle/1"}, %FindingPlace{file: "lib/b.ex", line: 9}],
          notes: [%FindingNote{round: 1, kind: :raised, at: @at, commit: "abcdef1234"}]
      }

      %{finding: finding}
    end

    test "each whole piece offers a + named for it, and none when the reader cannot comment", %{finding: finding} do
      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component([finding: finding, offered: true] ++ @attrs)
        |> Floki.parse_fragment!()

      assert [
               "Comment on Title",
               "Comment on Problem",
               "Comment on Where",
               "Comment on Fix",
               "Comment on Why fix",
               "Comment on Rule",
               "Comment on Place 1, handle/1",
               "Comment on Place 2",
               "Comment on Round 1, raised"
             ] = doc |> Floki.find("[data-qa=finding_comment_add]") |> Floki.attribute("aria-label")

      assert ["note"] =
               doc
               |> Floki.find("[data-qa=finding_note] [data-qa=finding_comment_add]")
               |> Floki.attribute("phx-value-piece")

      assert [_first, "1"] =
               doc
               |> Floki.find("[data-qa=finding_place] [data-qa=finding_comment_add]")
               |> Enum.map(&(&1 |> Floki.attribute("phx-value-index") |> List.first()))

      # app.css shows a + whose parent is hovered or holds the focus, so each is a direct child of its piece.
      assert doc
             |> Floki.find("[data-qa=finding_comment_add]")
             |> Enum.all?(&(&1 |> Floki.attribute("class") |> hd() =~ "line-comment-add"))

      assert length(Floki.find(doc, "[class*='group/line'] > [data-qa=finding_comment_add]")) == 9

      # A piece with no text to quote takes no comment.
      assert [] =
               (&FindingDetail.finding_detail/1)
               |> render_component([finding: %{finding | problem: ""}, offered: true] ++ @attrs)
               |> Floki.parse_fragment!()
               |> Floki.find("[data-qa=finding_problem] [data-qa=finding_comment_add]")

      assert [] =
               (&FindingDetail.finding_detail/1)
               |> render_component([finding: finding] ++ @attrs)
               |> Floki.parse_fragment!()
               |> Floki.find("[data-qa=finding_comment_add]")
    end

    test "the reader's unsent comments show under their pieces with the tray's numbers, and the box under its piece",
         %{finding: finding} do
      on_title = %{id: "fcm_0", body: "Say who."}
      on_fix = %{id: "fcm_1", body: "Guard it higher up."}
      on_place = %{id: "fcm_2", body: "And its caller."}

      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(
          [
            finding: finding,
            offered: true,
            comments: %{{:title, nil} => [{on_title, 1}], {:fix, nil} => [{on_fix, 2}], {:place, 1} => [{on_place, 3}]},
            draft: %{piece: :note, index: 0, body: "Half typed"}
          ] ++ @attrs
        )
        |> Floki.parse_fragment!()

      # The header does not scroll, so the title's comments are drawn in the body under a caption, not under it.
      assert [] = Floki.find(doc, "[data-qa=finding_title] [data-qa=document_comment]")
      [title] = Floki.find(doc, "[data-qa=finding_title_comments]")
      assert Floki.text(title) =~ ~r/Title\s+1\s+You\s+Not sent\s+Remove\s+Say who./

      [fix] = Floki.find(doc, "[data-qa=finding_fix] [data-qa=document_comment]")
      assert Floki.text(fix) =~ ~r/2\s+You\s+Not sent\s+Remove\s+Guard it higher up./

      assert ["remove_finding_comment"] =
               fix |> Floki.find("[data-qa=document_comment_remove]") |> Floki.attribute("phx-click")

      assert [_second_place] = Floki.find(doc, "#finding-place-2 [data-qa=document_comment]")
      assert [] = Floki.find(doc, "#finding-place-1 [data-qa=document_comment]")

      [box] = Floki.find(doc, "[data-qa=finding_note] #finding-comment-form")
      assert ["Comment on Round 1, raised"] = box |> Floki.find("textarea") |> Floki.attribute("aria-label")
      assert box |> Floki.find("textarea") |> Floki.text() == "Half typed"
      assert [_one_box] = Floki.find(doc, "#finding-comment-form")
    end
  end

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

  test "the Where's code says what it leaves out, and an attached log shows its text, commit, time and browser" do
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
    code = %{@excerpt | hidden_lines: 1, other_changes: 2}

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: @finding, where_code: code, filed: filed] ++ @attrs)
      |> Floki.parse_fragment!()

    assert "1 more changed line and 2 other changes in this file." =
             doc |> Floki.find("[data-qa=finding_diff] [data-qa=finding_code_footer]") |> Floki.text() |> String.trim()

    assert ["Open in Diff"] =
             doc |> Floki.find("[data-qa=finding_open_in_diff]") |> Enum.map(&String.trim(Floki.text(&1)))

    assert "boom" = doc |> Floki.find("[data-qa=finding_evidence_text]") |> Floki.text()
    taken = doc |> Floki.find("[data-qa=finding_evidence_taken]") |> Floki.text()
    assert taken =~ "abcdef1"
    assert taken =~ "QA explorer 2"
    assert taken =~ "Open"
  end

  # Only a commit the branch still has has a view to open.
  test "Raised in, Fixed in and Open in Diff open their commit in the Diff item at the finding's file" do
    raised = String.duplicate("a", 40)
    fixed = String.duplicate("b", 40)
    gone = String.duplicate("c", 40)
    finding = %{@finding | raised_in: raised, fixed_in: fixed}
    labels = %{raised => "Engineer", fixed => "Fix round 1"}

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: finding, where_code: @excerpt, labels: labels] ++ @attrs)
      |> Floki.parse_fragment!()

    assert [open] = Floki.find(doc, "[data-qa=finding_open_in_diff]")
    assert Floki.text(open) =~ "Open aaaaaaa in Diff"
    assert Floki.attribute(open, "phx-value-commit") == [raised]
    assert Floki.attribute(open, "phx-value-file") == ["lib/a.ex"]

    assert [raised_link] = Floki.find(doc, "[data-qa=finding_raised_in] [data-qa=finding_commit_link]")
    assert [fixed_link] = Floki.find(doc, "[data-qa=finding_fixed_in] [data-qa=finding_commit_link]")
    assert Floki.attribute(raised_link, "phx-click") == ["open_diff"]
    assert Floki.attribute(raised_link, "phx-value-commit") == [raised]
    assert Floki.attribute(fixed_link, "phx-value-commit") == [fixed]
    assert Floki.attribute(fixed_link, "phx-value-file") == ["lib/a.ex"]
    assert doc |> Floki.find("[data-qa=finding_fixed_in]") |> Floki.text() =~ "Fix round 1"

    rebased =
      (&FindingDetail.finding_detail/1)
      |> render_component(
        [finding: %{finding | raised_in: gone, fixed_in: nil}, where_code: @excerpt, labels: labels] ++ @attrs
      )
      |> Floki.parse_fragment!()

    assert [] = Floki.find(rebased, "[data-qa=finding_commit_link]")
    assert rebased |> Floki.find("[data-qa=finding_raised_in]") |> Floki.text() =~ "ccccccc"
    assert [] = rebased |> Floki.find("[data-qa=finding_open_in_diff]") |> Floki.attribute("phx-value-commit")
  end

  describe "a finding that applies in several places" do
    setup do
      raised = String.duplicate("a", 40)

      finding = %{
        @finding
        | rule: "A round is sent once.",
          raised_in: raised,
          places: [
            %FindingPlace{file: "lib/a.ex", line: 3, label: "handle/1"},
            %FindingPlace{file: "lib/b.ex", line: 40, end_line: 42, label: "resend/1"},
            %FindingPlace{file: "lib/c.ex", line: 9},
            %FindingPlace{screen: "Engineer tab", label: "Send button", steps: ["Open the tab", "Click Send"]}
          ]
      }

      unchanged = %{
        @excerpt
        | path: "lib/b.ex",
          display_path: "lib/b.ex",
          changed?: false,
          other_changes: 2,
          rows: [Map.merge(@context, %{new_line: 40, text: "resend(round)", named?: true})]
      }

      outside = %{unchanged | path: "lib/c.ex", display_path: "lib/c.ex", in_diff?: false, other_changes: 0}

      %{
        finding: finding,
        raised: raised,
        attrs:
          [
            finding: finding,
            where_code: @excerpt,
            where_place: 0,
            place_codes: %{1 => unchanged, 2 => outside},
            head: "9e4f1c2aaaa",
            labels: %{raised => "Engineer"}
          ] ++ @attrs
      }
    end

    test "every place is a numbered card, each code place with its code drawn and its lines bracketed", %{
      attrs: attrs
    } do
      doc = (&FindingDetail.finding_detail/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert doc |> Floki.find("[data-qa=finding_places]") |> Floki.text() =~ "Applies in 4 places"

      assert ["1", "2", "3", "4"] =
               doc |> Floki.find("[data-qa=finding_place] [aria-label^=Place]") |> Enum.map(&String.trim(Floki.text(&1)))

      assert [_one, _two, _three] = Floki.find(doc, "[data-qa=finding_place] [data-qa=finding_code]")
      assert doc |> Floki.find("#finding-place-1 [data-bracket=only]") |> Floki.text() =~ "send(round)"
      assert doc |> Floki.find("#finding-place-2 [data-bracket=only]") |> Floki.text() =~ "resend(round)"
      assert doc |> Floki.find("#finding-rule") |> Floki.text() =~ "A round is sent once."
      refute doc |> Floki.find("#finding-rule") |> Floki.text() =~ "Applies in"
    end

    test "the place on the Where's lines is the card tagged Where, and no Where box is drawn", %{
      attrs: attrs,
      raised: raised
    } do
      doc = (&FindingDetail.finding_detail/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert [] = Floki.find(doc, "[data-qa=finding_diff]")
      assert [_where] = Floki.find(doc, "#finding-place-1 [data-qa=finding_place_where]")
      assert [_only_one] = Floki.find(doc, "[data-qa=finding_place_where]")

      assert [open] = Floki.find(doc, "#finding-place-1-open-in-diff")
      assert Floki.text(open) =~ "Open aaaaaaa in Diff"
      assert Floki.attribute(open, "phx-value-commit") == [raised]

      # Every other card opens the whole branch at its file.
      assert [other] = Floki.find(doc, "#finding-place-2-open-in-diff")
      assert String.trim(Floki.text(other)) == "Open in Diff"
      assert Floki.attribute(other, "phx-value-commit") == []
      assert Floki.attribute(other, "phx-value-file") == ["lib/b.ex"]
    end

    test "a Where on none of its places keeps the Where box, bracketed, above untagged cards", %{attrs: attrs} do
      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.merge(attrs, where_place: nil, place_codes: %{0 => @excerpt}))
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("[data-qa=finding_diff] [data-bracket=only]") |> Floki.text() =~ "send(round)"
      assert [] = Floki.find(doc, "[data-qa=finding_place_where]")
      assert [_code] = Floki.find(doc, "#finding-place-1 [data-qa=finding_code]")
    end

    test "unchanged lines carry the chip, with Open in Diff only for a file in the branch's diff", %{attrs: attrs} do
      doc = (&FindingDetail.finding_detail/1) |> render_component(attrs) |> Floki.parse_fragment!()

      assert [_chip] = Floki.find(doc, "#finding-place-2 [data-qa=finding_code_unchanged_chip]")
      assert [_open] = Floki.find(doc, "#finding-place-2-open-in-diff")
      assert doc |> Floki.find("#finding-place-2 [data-qa=finding_code_unchanged]") |> Floki.text() =~ "on 9e4f1c2"

      assert [_chip] = Floki.find(doc, "#finding-place-3 [data-qa=finding_code_unchanged_chip]")
      assert [] = Floki.find(doc, "#finding-place-3-open-in-diff")

      assert [] = Floki.find(doc, "#finding-place-1 [data-qa=finding_code_unchanged_chip]")
      assert doc |> Floki.find("#finding-place-1 [data-qa=diff_stat]") |> Floki.text() =~ "+2"

      outside = %{@excerpt | changed?: false, in_diff?: false}

      box =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.merge(attrs, where_place: nil, where_code: outside))
        |> Floki.parse_fragment!()

      assert [_chip] = Floki.find(box, "[data-qa=finding_diff] [data-qa=finding_code_unchanged_chip]")
      assert [] = Floki.find(box, "[data-qa=finding_open_in_diff]")
    end

    test "a Where box and a card in a file the branch deletes keep their header, note and Open in Diff", %{
      attrs: attrs
    } do
      deleted = %{
        @excerpt
        | path: "lib/b.ex",
          display_path: "lib/b.ex",
          additions: 0,
          deletions: 12,
          changed?: false,
          rows: [],
          missing: :deleted
      }

      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.put(attrs, :place_codes, %{1 => deleted}))
        |> Floki.parse_fragment!()

      [card] = Floki.find(doc, "#finding-place-2")
      assert Floki.text(card) =~ "lib/b.ex:40-42"
      assert Floki.text(card) =~ "resend/1"
      assert card |> Floki.find("[data-qa=diff_stat]") |> Floki.text() =~ "12"
      assert card |> Floki.find("[data-qa=finding_code_missing]") |> Floki.text() =~ "The branch deletes this file."
      assert ["lib/b.ex"] = card |> Floki.find("#finding-place-2-open-in-diff") |> Floki.attribute("phx-value-file")
      assert [] = Floki.find(card, "[data-qa=finding_code_unchanged_chip]")
      assert [] = Floki.find(card, "[data-qa=diff_hunk]")

      box =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.merge(attrs, where_place: nil, where_code: deleted))
        |> Floki.parse_fragment!()

      [where] = Floki.find(box, "[data-qa=finding_diff]")
      assert Floki.text(where) =~ "lib/b.ex"
      assert where |> Floki.find("[data-qa=finding_code_missing]") |> Floki.text() =~ "The branch deletes this file."
      assert ["lib/b.ex"] = where |> Floki.find("[data-qa=finding_open_in_diff]") |> Floki.attribute("phx-value-file")
      assert [] = Floki.find(where, "[data-qa=finding_code_unchanged_chip]")
      assert [] = Floki.find(where, "[data-qa=diff_hunk]")
    end

    test "a screen card shows its numbered steps, with no code and no Open in Diff", %{attrs: attrs} do
      doc = (&FindingDetail.finding_detail/1) |> render_component(attrs) |> Floki.parse_fragment!()

      [card] = Floki.find(doc, "#finding-place-4")
      assert Floki.text(card) =~ "Engineer tab"
      assert ["Open the tab", "Click Send"] = card |> Floki.find("ol li") |> Enum.map(&Floki.text/1)
      assert [] = Floki.find(card, "[data-qa=finding_code]")
      assert [] = Floki.find(card, "[data-qa=finding_place_open_in_diff]")
    end

    test "each card reads covered or left by the latest fix, and an untouched finding's neither", %{
      attrs: attrs,
      finding: finding
    } do
      untouched = (&FindingDetail.finding_detail/1) |> render_component(attrs) |> Floki.parse_fragment!()
      assert [] = Floki.find(untouched, "[data-qa=finding_place_fix]")

      [first, second | rest] = finding.places

      fixed = %{
        finding
        | status: :fixed,
          places: [first, %{second | left_reason: "Only on staging."} | rest],
          notes: [%FindingNote{round: 1, kind: :fix, at: @at, test: "test/a_test.exs: once"}]
      }

      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.put(attrs, :finding, fixed))
        |> Floki.parse_fragment!()

      fixes =
        doc
        |> Floki.find("[data-qa=finding_place_fix]")
        |> Enum.map(&(&1 |> Floki.text() |> String.split() |> Enum.join(" ")))

      assert [
               "Covered by fix round 1",
               "Left by fix round 1: Only on staging.",
               "Covered by fix round 1",
               "Covered by fix round 1"
             ] = fixes
    end

    test "a card's comments and its open box sit under that card", %{attrs: attrs} do
      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(
          Keyword.merge(attrs,
            offered: true,
            comments: %{{:place, 2} => [{%{id: "fcm_1", body: "Use it here too."}, 1}]},
            draft: %{piece: :place, index: 1, body: "And here"}
          )
        )
        |> Floki.parse_fragment!()

      assert doc |> Floki.find("#finding-place-3 [data-qa=document_comment]") |> Floki.text() =~ "Use it here too."
      assert [box] = Floki.find(doc, "#finding-place-2 #finding-comment-form")
      assert ["Comment on Place 2, resend/1"] = box |> Floki.find("textarea") |> Floki.attribute("aria-label")

      assert ["Comment on Place 2, resend/1"] =
               doc |> Floki.find("#finding-place-2 > [data-qa=finding_comment_add]") |> Floki.attribute("aria-label")
    end
  end

  test "a finding with one place keeps the Where box, bracketed, and its plain row in the Rule box" do
    finding = %{
      @finding
      | rule: "A round is sent once.",
        places: [%FindingPlace{file: "lib/b.ex", line: 9, label: "elsewhere", left_reason: "Generated."}],
        notes: [%FindingNote{round: 2, kind: :fix, at: @at, test: "test/a_test.exs: once"}]
    }

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: finding, where_code: @excerpt, where_place: nil] ++ @attrs)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("[data-qa=finding_diff] [data-bracket=only]") |> Floki.text() =~ "send(round)"
    assert [] = Floki.find(doc, "[data-qa=finding_places]")
    assert [row] = Floki.find(doc, "#finding-rule li[data-qa=finding_place]")
    assert Floki.text(row) =~ "lib/b.ex:9"
    assert row |> Floki.text() |> String.split() |> Enum.join(" ") =~ "Left by fix round 2: Generated."
    assert [] = Floki.find(row, "[data-qa=finding_code]")
    assert doc |> Floki.find("#finding-rule") |> Floki.text() =~ "Applies in 1 place"
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
            files: ["lib/bills_live.ex"],
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
             "Fixed in 2222222; covers Engineer tab; leaves lib/b.ex:1: Out of reach; changes lib/bills_live.ex; " <>
               "test that failed first: test/a_test.exs: sends once"

    assert checked =~ "Checked fixed on 2222222"
    assert doc |> Floki.find("[data-qa=finding_fixed_in]") |> Floki.text() =~ "Fix round 3"
    assert doc |> Floki.find("[data-qa=finding_round]") |> Floki.text() =~ "Round 1, carried into round 3"
    assert doc |> Floki.find("[data-qa=finding_places]") |> Floki.text() =~ "Applies in 2 places"

    assert doc
           |> Floki.find("#finding-place-1 [data-qa=finding_place_fix]")
           |> Floki.text()
           |> String.split()
           |> Enum.join(" ") ==
             "Left by fix round 3: Out of reach"

    assert [] = Floki.find(doc, "[data-qa=decide_fix]")
  end

  test "a fixed finding leads with Fixed in its commit, and nothing on it is red or amber but a failing note" do
    finding = %{
      @finding
      | severity: :blocker,
        decision: :fix,
        status: :fixed,
        fixed_in: "2222222bbbb",
        notes: [
          %FindingNote{round: 1, kind: :raised, at: @at, commit: "1111111aaaa"},
          %FindingNote{round: 2, kind: :pass, at: @at, status: :not_fixed, commit: "1111111aaaa"},
          %FindingNote{round: 2, kind: :fix, at: @at, commit: "2222222bbbb", test: "test/a_test.exs: sends once"}
        ]
    }

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: finding, labels: %{"2222222bbbb" => "Fix round 2"}] ++ @attrs)
      |> Floki.parse_fragment!()

    assert "Fixed in 2222222 · Fix round 2" =
             doc |> Floki.find("#finding-outcome") |> Floki.text() |> String.split() |> Enum.join(" ")

    assert doc |> Floki.attribute("#finding-outcome", "class") |> Enum.join() =~ "text-emerald-700"

    assert doc |> Floki.find("#finding-meta") |> Floki.text() =~
             ~r/\A\s*Raised as\s+blocker\s+·\s+Code\s+·\s*Round 1\s*·\s*1 of 1\s*\z/

    assert doc |> Floki.attribute("#finding-severity", "class") |> Enum.join() =~ "bg-slate-100"
    assert doc |> Floki.attribute("[data-qa=finding_recommendation] span", "class") |> Enum.join() =~ "bg-slate-400"
    assert doc |> Floki.find("[data-qa=finding_fixed_in]") |> Floki.text() =~ "2222222"

    assert doc |> Floki.find("[data-qa=finding_history]") |> Floki.text() |> String.split() |> Enum.join(" ") =~
             "Fixed in 2222222; test"

    # A pass that found it fixed, with no fix round behind it, names the commit alone.
    passed = %{
      finding
      | notes: [%FindingNote{round: 2, kind: :pass, at: @at, status: :fixed, commit: "2222222bbbb"}]
    }

    assert "Fixed in 2222222" =
             (&FindingDetail.finding_detail/1)
             |> render_component([finding: passed] ++ @attrs)
             |> Floki.parse_fragment!()
             |> Floki.find("#finding-outcome")
             |> Floki.text()
             |> String.split()
             |> Enum.join(" ")

    # Only the note that it was once still failing is red.
    assert [_failing_note] = Floki.find(doc, "[class*=text-red-], [class*=bg-red-], [class*=-amber-]")
    assert doc |> Floki.find("[class*=text-red-]") |> Floki.text() =~ "Still failing on 1111111"
  end

  test "a finding fixed before Rail noted its commit reads Fixed, with no Fixed in line and nothing not yet" do
    finding = %{
      @finding
      | status: :fixed,
        raised_in: "1111111aaaa",
        notes: [%FindingNote{round: 1, kind: :fix, at: @at, commit: nil, test: "test/a_test.exs: sends once"}]
    }

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: finding] ++ @attrs)
      |> Floki.parse_fragment!()

    assert "Fixed · Fix round 1" =
             doc |> Floki.find("#finding-outcome") |> Floki.text() |> String.split() |> Enum.join(" ")

    assert [] = Floki.find(doc, "[data-qa=finding_fixed_in]")
    refute doc |> Floki.find("[data-qa=finding_commits]") |> Floki.text() =~ "Fixed in"
    refute Floki.text(doc) =~ "not yet"

    assert doc |> Floki.find("[data-qa=finding_note]") |> Floki.text() |> String.split() |> Enum.join(" ") =~
             "Fixed; test that failed first: test/a_test.exs: sends once"
  end

  test "every state leads its own status line, and its severity keeps its tint only while still to decide or fix" do
    failing = %FindingNote{round: 2, kind: :pass, at: @at, status: :not_fixed, commit: "3333333cccc"}

    cases = [
      {%{@finding | severity: :blocker, raised_by: :review_lead}, true, "Rule on it once the round finishes",
       "text-blue-600", "bg-red-100", "bg-red-500", "Review lead"},
      {%{@finding | severity: :major}, false, "Needs your call", "text-blue-600", "bg-amber-100", "bg-amber-500",
       "Code reviewer"},
      {%{@finding | severity: :minor, decision: :fix}, false, "Fix", "text-slate-700", "bg-amber-50", "bg-amber-400",
       "Code reviewer"},
      {%{@finding | severity: :nit, decision: :fix, status: :not_fixed, recommendation: :skip, notes: [failing]}, false,
       "Still failing · on 3333333", "text-red-600", "bg-slate-100 text-slate-600", "bg-slate-400", "Code reviewer"},
      {%{@finding | severity: :blocker, decision: :fix, status: :not_fixed}, false, "Still failing", "text-red-600",
       "bg-red-100", "bg-red-500", "Code reviewer"},
      {%{@finding | severity: :blocker, decision: :skip, raised_by: :explorer}, false, "Don't fix", "text-slate-700",
       "bg-slate-100 text-slate-500", "bg-slate-400", "QA explorer"},
      {%{@finding | severity: :major, suppressed_by_id: "lrn_quiet"}, false, "Suppressed", "text-slate-700",
       "bg-slate-100 text-slate-500", "bg-slate-400", "Code reviewer"}
    ]

    for {finding, running, state, color, tint, dot, raiser} <- cases do
      doc =
        (&FindingDetail.finding_detail/1)
        |> render_component(Keyword.put([finding: finding] ++ @attrs, :running, running))
        |> Floki.parse_fragment!()

      assert ^state = doc |> Floki.find("[data-qa=finding_state]") |> Floki.text() |> String.split() |> Enum.join(" ")
      assert doc |> Floki.attribute("#finding-outcome", "class") |> Enum.join() =~ color
      assert doc |> Floki.attribute("#finding-severity", "class") |> Enum.join() =~ tint
      assert doc |> Floki.find("#finding-severity") |> Floki.text() |> String.trim() == to_string(finding.severity)
      assert doc |> Floki.attribute("[data-qa=finding_recommendation] span", "class") |> Enum.join() =~ dot
      assert doc |> Floki.find("[data-qa=finding_recommendation]") |> Floki.text() =~ raiser
      assert [] = Floki.find(doc, "[data-qa=finding_fixed_in]")
      refute doc |> Floki.find("[data-qa=finding_commits]") |> Floki.text() =~ "Fixed in"
    end
  end

  test "a finding whose ruling changed since the fix plan says so and keeps its ruling buttons" do
    finding = %{@finding | decision: :skip}

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: finding, ruling_was: :fix] ++ @attrs)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#finding-ruling-changed") |> Floki.text() =~ "Ruling changed since the fix plan · was Fix"
    assert [_fix] = Floki.find(doc, "#decide-fix-send-twice")
    assert [_skip] = Floki.find(doc, "#decide-skip-send-twice")

    doc =
      (&FindingDetail.finding_detail/1)
      |> render_component([finding: %{finding | decision: :fix}, ruling_was: :skip] ++ @attrs)
      |> Floki.parse_fragment!()

    assert doc |> Floki.find("#finding-ruling-changed") |> Floki.text() =~ "was Don't fix"

    doc = (&FindingDetail.finding_detail/1) |> render_component([finding: finding] ++ @attrs) |> Floki.parse_fragment!()
    assert Floki.find(doc, "#finding-ruling-changed") == []
  end
end
