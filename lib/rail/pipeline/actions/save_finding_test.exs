defmodule Rail.Pipeline.Actions.SaveFindingTest do
  use Rail.DataCase, async: true

  alias Rail.Issues
  alias Rail.Pipeline
  alias Rail.Pipeline.Schemas.Finding
  alias Rail.Pipeline.Schemas.FindingEvidence
  alias Rail.Pipeline.Schemas.FindingNote

  setup %{project: project} do
    Req.Test.expect(Rail.Linear, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "issueCreate" => %{
            "success" => true,
            "issue" => %{"id" => "lin_svf_1", "identifier" => "SVF-1", "title" => "Save Finding"}
          }
        }
      })
    end)

    {:ok, issue} = Issues.create_issue(system_scope(), project, %{description: "Save Finding"})
    {:ok, task} = Pipeline.create_task(issue, :review)
    worktree = create_temp_git_repo()
    {:ok, task} = Pipeline.update_task(task, %{worktree_path: worktree})
    head = worktree |> git!(["rev-parse", "HEAD"]) |> String.trim()
    on_exit(fn -> File.rm_rf(task.scratch_path) end)
    Phoenix.PubSub.subscribe(Rail.PubSub, "outputs:#{task.id}")

    %{
      task: task,
      head: head,
      attrs: %{
        "key" => "send-twice",
        "kind" => "screen",
        "raised_by" => "explorer",
        "title" => "Send stays enabled while a round is on its way",
        "problem" => "A second click sends the same comments twice.",
        "screen" => "Engineer tab, Diff toolbar",
        "steps" => ["Comment on 2 lines", "Click Send", "Click it again"],
        "check" => "send-once",
        "fix" => "Disable Send from the click until the server answers.",
        "why" => "Two runs for one round.",
        "rule" => "A round is sent once, however many times Send is pressed.",
        "severity" => "major",
        "recommendation" => "fix",
        "places" => [%{"screen" => "Engineer tab, Diff toolbar", "steps" => ["Click Send"]}],
        "evidence" => [%{"name" => "count", "kind" => "note", "text" => "2 deliveries"}]
      }
    }
  end

  test "a new finding is raised in the round running against HEAD's commit, and broadcast", %{
    task: %{id: task_id} = task,
    head: head,
    attrs: attrs
  } do
    assert {:ok,
            %Finding{
              key: "send-twice",
              kind: :screen,
              round: 1,
              raised_in: ^head,
              status: :open,
              steps: ["Comment on 2 lines", "Click Send", "Click it again"],
              evidence: [%FindingEvidence{text: "2 deliveries", commit: ^head}],
              notes: [%FindingNote{kind: :raised, round: 1, commit: ^head}]
            }} = Pipeline.save_finding(task, attrs)

    assert_received {:output_saved, ^task_id}
  end

  test "a finding saved on a commit after round 1 was closed is raised in round 2", %{task: task, attrs: attrs} do
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])

    assert {:ok, %Finding{round: 2, notes: [%FindingNote{round: 2}]}} = Pipeline.save_finding(task, attrs)
  end

  test "a new finding without evidence, over a limit or holding markup is refused naming the field", %{
    task: task,
    attrs: attrs
  } do
    assert {:error, changeset} = Pipeline.save_finding(task, Map.delete(attrs, "evidence"))
    assert %{evidence: ["needs at least one highlighted code range, screenshot, file or note"]} = errors_on(changeset)

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "title" => String.duplicate("x", 91)})
    assert %{title: ["should be at most 90 character(s)"]} = errors_on(changeset)

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "problem" => "</invoke> sent twice"})
    assert %{problem: ["holds tool-call markup; write it as plain text"]} = errors_on(changeset)

    assert Pipeline.list_findings(task) == []
  end

  # The lead saves it again in the same turn, which it can only do knowing which piece is wrong and why.
  test "a new finding with a bad evidence entry is refused naming the entry and what is wrong", %{
    task: task,
    attrs: attrs
  } do
    for {entry, said} <- [
          {%{"name" => "passwd", "kind" => "log", "path" => "../../../../etc/passwd"},
           %{path: ["cannot climb out of the QA directory"]}},
          {%{"name" => "The handler", "kind" => "code", "file" => "lib/a.ex"},
           %{file: ["code evidence needs the `file` and `line` it highlights"]}},
          {%{"name" => "Odd", "kind" => "bogus", "text" => "x"}, %{kind: ["is invalid"]}},
          {%{"name" => "Note", "kind" => "note"}, %{path: ["evidence needs a file or some text"]}}
        ] do
      assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "evidence" => [entry]})
      assert %{evidence: [^said]} = errors_on(changeset)
    end
  end

  # Copied rather than pointed at, so a later pass writing over the original changes nothing the human was shown.
  test "a cited screenshot is copied into the finding's folder and outlives the original", %{
    task: task,
    head: head,
    attrs: attrs
  } do
    qa = Path.join(task.scratch_path, "qa")
    source = Path.join(qa, "shots/send-twice-1.jpg")
    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "jpeg bytes")
    File.touch!(source, 1_700_000_000)
    taken_at = DateTime.from_unix!(1_700_000_000_000_000, :microsecond)

    cited = %{
      "name" => "Send twice",
      "kind" => "screenshot",
      "path" => "shots/send-twice-1.jpg",
      "browser" => "explorer-1",
      "commit" => "made up",
      "taken_at" => "2001-01-01T00:00:00Z"
    }

    assert {:ok,
            %Finding{
              evidence: [
                %FindingEvidence{
                  path: "evidence/send-twice/" <> copied,
                  commit: ^head,
                  browser: "explorer-1",
                  taken_at: ^taken_at,
                  text: nil
                }
              ]
            }} = Pipeline.save_finding(task, %{attrs | "evidence" => [cited]})

    assert String.ends_with?(copied, "-send-twice-1.jpg")
    File.write!(source, "a later pass's picture")
    File.rm!(source)
    assert File.read!(Path.join([qa, "evidence/send-twice", copied])) == "jpeg bytes"
  end

  # Read in when attached, so the panel shows it from the row and needs no file opened.
  test "a text log's opening is read into the finding, a long one is cut short, and text given is kept", %{
    task: task,
    attrs: attrs
  } do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(qa)
    File.write!(Path.join(qa, "server.log"), "[error] boom\n")
    File.write!(Path.join(qa, "long.log"), String.duplicate("a", 20_000))
    # The limit is in bytes, so it can land inside a character, and half of one is not text.
    File.write!(Path.join(qa, "wide.log"), String.duplicate("a", 16_383) <> "é and more")
    marker = "\n[cut short here; open the file for the rest]"
    cut = String.duplicate("a", 16_384) <> marker
    wide = String.duplicate("a", 16_383) <> marker

    assert {:ok,
            %Finding{
              evidence: [
                %FindingEvidence{path: "evidence/send-twice/" <> _server, text: "[error] boom\n"},
                %FindingEvidence{path: "evidence/send-twice/" <> _long, text: ^cut},
                %FindingEvidence{path: "evidence/send-twice/" <> _wide, text: ^wide},
                %FindingEvidence{path: "evidence/send-twice/" <> _quoted, text: "[error] boom"}
              ]
            }} =
             Pipeline.save_finding(task, %{
               attrs
               | "evidence" => [
                   %{"name" => "The crash", "kind" => "log", "path" => "server.log"},
                   %{"name" => "The whole run", "kind" => "log", "path" => "long.log"},
                   %{"name" => "The accented run", "kind" => "log", "path" => "wide.log"},
                   %{"name" => "The line", "kind" => "log", "path" => "server.log", "text" => "[error] boom"}
                 ]
             })
  end

  # An agent wrote these, so whatever they hold is attached as a file and never read in as text.
  test "a binary, non-UTF-8, empty, half-text or tool-call-holding file is attached without text", %{
    task: task,
    attrs: attrs
  } do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(qa)
    File.write!(Path.join(qa, "dump.bin"), <<0xFF, 0xFE, 0x00, 0x81, "x">>)
    File.write!(Path.join(qa, "latin.log"), <<"caf", 0xE9, " au lait">>)
    File.write!(Path.join(qa, "quiet.log"), "")
    File.write!(Path.join(qa, "turns.log"), String.duplicate("a", 9_000) <> <<0xFF>>)
    File.write!(Path.join(qa, "agent.log"), "[tool] save_finding\n</invoke>\n")

    evidence =
      for file <- ["dump.bin", "latin.log", "quiet.log", "turns.log", "agent.log"],
          do: %{"name" => file, "kind" => "log", "path" => file}

    assert {:ok,
            %Finding{
              evidence: [
                %FindingEvidence{path: "evidence/send-twice/" <> _dump, text: nil},
                %FindingEvidence{path: "evidence/send-twice/" <> _latin, text: nil},
                %FindingEvidence{path: "evidence/send-twice/" <> _quiet, text: nil},
                %FindingEvidence{path: "evidence/send-twice/" <> _turns, text: nil},
                %FindingEvidence{path: "evidence/send-twice/" <> _agent, text: nil}
              ]
            }} = Pipeline.save_finding(task, %{attrs | "evidence" => evidence})
  end

  test "a file already attached to the finding is cited again without another copy", %{task: task, attrs: attrs} do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    File.write!(Path.join(qa, "shots/bill.jpg"), "jpeg bytes")
    shot = %{"name" => "The bill", "kind" => "screenshot", "path" => "shots/bill.jpg"}

    assert {:ok, %Finding{evidence: [%FindingEvidence{path: attached}]}} =
             Pipeline.save_finding(task, %{attrs | "evidence" => [shot]})

    assert {:ok, %Finding{evidence: [%FindingEvidence{path: ^attached}, %FindingEvidence{path: ^attached}]}} =
             Pipeline.save_finding(task, %{
               "key" => "send-twice",
               "status" => "not_fixed",
               "evidence" => [%{shot | "path" => attached}]
             })

    assert [_one] = File.ls!(Path.join(qa, "evidence/send-twice"))
  end

  test "evidence naming a file that is not there is refused, naming it, and nothing is copied", %{
    task: task,
    attrs: attrs
  } do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    File.write!(Path.join(qa, "shots/bill.jpg"), "jpeg bytes")

    cited = [
      %{"name" => "The bill", "kind" => "screenshot", "path" => "shots/bill.jpg"},
      %{"name" => "the log", "kind" => "log", "path" => "server.log"}
    ]

    assert {:error, changeset} = Pipeline.save_finding(task, %{attrs | "evidence" => cited})
    assert %{evidence: ["server.log is not a file in " <> _qa_dir]} = errors_on(changeset)
    refute File.exists?(Path.join(qa, "evidence"))
    assert Pipeline.list_findings(task) == []
  end

  # A link could name any file on the machine, and the copy is what the panel serves.
  test "a symlink or a directory is not a file to attach", %{task: task, attrs: attrs} do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    outside = Path.join(System.tmp_dir!(), "svf-outside-#{System.unique_integer([:positive])}.log")
    File.write!(outside, "secret")
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(qa, "linked.log"))

    for path <- ["linked.log", "shots"] do
      assert {:error, changeset} =
               Pipeline.save_finding(task, %{attrs | "evidence" => [%{"name" => "x", "kind" => "log", "path" => path}]})

      assert %{evidence: [refused]} = errors_on(changeset)
      assert refused =~ "#{path} is not a file in "
    end

    refute File.exists?(Path.join(qa, "evidence"))
  end

  # Checked as cited before anything is copied, so a refused save leaves nothing in the finding's folder.
  test "an invalid finding citing a real file copies nothing", %{task: task, attrs: attrs} do
    qa = Path.join(task.scratch_path, "qa")
    File.mkdir_p!(Path.join(qa, "shots"))
    File.write!(Path.join(qa, "shots/bill.jpg"), "jpeg bytes")

    assert {:error, changeset} =
             Pipeline.save_finding(task, %{
               attrs
               | "title" => String.duplicate("x", 91),
                 "evidence" => [%{"name" => "The bill", "kind" => "screenshot", "path" => "shots/bill.jpg"}]
             })

    assert %{title: ["should be at most 90 character(s)"]} = errors_on(changeset)
    refute File.exists?(Path.join(qa, "evidence"))
  end

  test "a later note citing a missing or climbing path is refused, and the finding is unchanged", %{
    task: task,
    attrs: attrs
  } do
    {:ok, %Finding{id: id}} = Pipeline.save_finding(task, attrs)

    assert {:error, changeset} =
             Pipeline.save_finding(task, %{
               "key" => "send-twice",
               "status" => "not_fixed",
               "evidence" => [%{"name" => "x", "kind" => "log", "path" => "gone.log"}]
             })

    assert %{evidence: ["gone.log is not a file in " <> _qa_dir]} = errors_on(changeset)

    assert {:error, %Ecto.Changeset{valid?: false}} =
             Pipeline.save_finding(task, %{
               "key" => "send-twice",
               "status" => "not_fixed",
               "evidence" => [%{"name" => "x", "kind" => "log", "path" => "../outside.log"}]
             })

    assert [%Finding{id: ^id, status: :open, evidence: [%FindingEvidence{text: "2 deliveries"}]}] =
             Pipeline.list_findings(task)
  end

  # A round is a read of a new HEAD, so a pass saved again on the commit round 1 read is still round 1.
  test "saving a known key again at the HEAD round 1 read notes round 1", %{task: task, head: head, attrs: attrs} do
    {:ok, %Finding{id: id}} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)

    assert {:ok,
            %Finding{
              id: ^id,
              notes: [%FindingNote{kind: :raised, round: 1}, %FindingNote{kind: :pass, round: 1, commit: ^head}]
            }} = Pipeline.save_finding(task, %{"key" => "send-twice", "status" => "fixed", "note" => "Sent once now."})
  end

  test "saving a known key again notes the round and commit, and leaves what it said as raised", %{
    task: task,
    attrs: attrs
  } do
    {:ok, %Finding{id: id}} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])
    head = task.worktree_path |> git!(["rev-parse", "HEAD"]) |> String.trim()

    assert {:ok,
            %Finding{
              id: ^id,
              problem: "A second click sends the same comments twice.",
              fix: "Disable Send from the click until the server answers.",
              screen: "Engineer tab, Diff toolbar",
              status: :fixed,
              notes: [
                %FindingNote{kind: :raised, round: 1},
                %FindingNote{kind: :pass, round: 2, commit: ^head, status: :fixed, text: "Sent once now."}
              ]
            }} =
             Pipeline.save_finding(task, %{
               "key" => "send-twice",
               "status" => "fixed",
               "note" => "Sent once now.",
               "problem" => "Something else entirely.",
               "fix" => "Rewrite it all."
             })
  end

  test "a Fix finding a later round finds still failing is carried into that round, once", %{
    task: task,
    attrs: attrs
  } do
    {:ok, raised} = Pipeline.save_finding(task, attrs)
    {:ok, %{round: 1}} = Pipeline.save_review(task)
    {:ok, _ruled} = Pipeline.decide_finding(system_scope(), raised, :fix)
    git!(task.worktree_path, ["commit", "--allow-empty", "-m", "Fix round 1"])
    still_failing = %{"key" => "send-twice", "status" => "not_fixed", "note" => "Still sends twice."}

    assert {:ok,
            %Finding{
              carried_round: 2,
              decision: :fix,
              status: :not_fixed,
              notes: [
                %FindingNote{kind: :raised},
                %FindingNote{kind: :ruling},
                %FindingNote{kind: :pass, round: 2, status: :not_fixed},
                %FindingNote{kind: :carried, round: 2}
              ]
            } = carried} = Pipeline.save_finding(task, still_failing)

    assert Finding.outstanding?(carried)
    refute Finding.undecided?(carried)

    assert {:ok, %Finding{notes: notes}} = Pipeline.save_finding(task, still_failing)
    assert [:raised, :ruling, :pass, :carried, :pass] = Enum.map(notes, & &1.kind)
  end

  describe "a Fix finding saved fixed" do
    setup %{task: task, attrs: attrs} do
      places = [%{"file" => "lib/send.ex", "line" => 3}, %{"file" => "lib/resend.ex", "line" => 9}]
      {:ok, raised} = Pipeline.save_finding(task, %{attrs | "places" => places})
      {:ok, ruled} = Pipeline.decide_finding(system_scope(), raised, :fix)

      %{
        ruled: ruled,
        report: %{
          "key" => "send-twice",
          "status" => "fixed",
          "covered" => [1],
          "left" => [%{"place" => 2, "reason" => " Generated from send.ex. "}],
          "test" => %{"file" => "test/send_test.exs", "name" => "sends once"},
          "files" => ["lib/send.ex", "lib/send.ex", " "],
          "note" => "Disabled on click."
        }
      }
    end

    test "is the fix round's report, with the commit left for the hand-over to note", %{task: task, report: report} do
      assert {:ok,
              %Finding{
                status: :fixed,
                fixed_in: nil,
                places: [%{left_reason: nil}, %{left_reason: "Generated from send.ex."}],
                notes: [
                  %FindingNote{kind: :raised},
                  %FindingNote{kind: :ruling},
                  %FindingNote{
                    kind: :fix,
                    round: 1,
                    commit: nil,
                    covered: ["lib/send.ex:3"],
                    left: ["lib/resend.ex:9: Generated from send.ex."],
                    files: ["lib/send.ex"],
                    test: "test/send_test.exs: sends once",
                    text: "Disabled on click."
                  }
                ]
              } = fixed} = Pipeline.save_finding(task, report)

      refute Finding.outstanding?(fixed)
    end

    test "that covers no place is refused", %{task: task, report: report} do
      assert {:error, changeset} = Pipeline.save_finding(task, Map.delete(report, "covered"))
      assert %{covered: ["is the numbers of the places, from 1, the fix covers"]} = errors_on(changeset)
    end

    test "that names no test is refused", %{task: task, report: report} do
      for test <- [nil, %{"file" => "test/send_test.exs"}, %{"file" => " ", "name" => "sends once"}] do
        assert {:error, changeset} = Pipeline.save_finding(task, %{report | "test" => test})
        assert %{test: ["is the `file` and `name` of the test that failed before the fix"]} = errors_on(changeset)
      end
    end

    test "that leaves a place without a reason is refused", %{task: task, report: report} do
      assert {:error, changeset} = Pipeline.save_finding(task, %{report | "left" => [%{"place" => 2, "reason" => " "}]})
      assert %{left: ["needs the reason the fix leaves each place it lists"]} = errors_on(changeset)
    end

    test "that leaves a place unaccounted for is refused, and saves nothing", %{task: task, report: report} do
      assert {:error, changeset} = Pipeline.save_finding(task, Map.delete(report, "left"))

      assert %{
               covered: [
                 "leaves place 2 unaccounted for: cover it, or list it in `left` with the reason the fix leaves it"
               ]
             } =
               errors_on(changeset)

      assert [%Finding{status: :open}] = Pipeline.list_findings(task)
    end

    # A finding from before places has none to account for, so the test is the whole report.
    test "with no places needs only its test", %{task: task, ruled: ruled, report: report} do
      ruled |> Ecto.Changeset.change() |> Ecto.Changeset.put_embed(:places, []) |> Repo.update!()

      assert {:ok, %Finding{status: :fixed, notes: notes}} =
               Pipeline.save_finding(task, Map.drop(report, ["covered", "left", "files"]))

      assert %FindingNote{kind: :fix, covered: [], left: [], files: []} = List.last(notes)
    end
  end

  test "a finding ruled Don't fix is not argued again", %{task: task, attrs: attrs} do
    {:ok, raised} = Pipeline.save_finding(task, attrs)
    {:ok, _dismissed} = Pipeline.decide_finding(system_scope(), raised, :skip)

    assert {:error, changeset} = Pipeline.save_finding(task, %{"key" => "send-twice", "status" => "not_fixed"})
    assert %{key: ["was ruled Don't fix by the human, so leave it be"]} = errors_on(changeset)
  end

  test "a checklist rule's id links the finding, and a calibration rule's suppresses it", %{
    task: task,
    project: project,
    attrs: attrs
  } do
    %{id: checklist_id} = learning(project, %{rule: "Send once", kind: :convention})
    %{id: calibration_id} = learning(project, %{rule: "Don't flag a missing @doc", kind: :calibration})

    assert {:ok, %Finding{rule_id: ^checklist_id, suppressed_by_id: nil}} =
             Pipeline.save_finding(task, Map.put(attrs, "checklist_rule", checklist_id))

    assert {:ok, %Finding{rule_id: nil, suppressed_by_id: ^calibration_id}} =
             Pipeline.save_finding(task, Map.put(%{attrs | "key" => "missing-doc"}, "checklist_rule", calibration_id))

    assert {:ok, %Finding{rule_id: nil, suppressed_by_id: nil}} =
             Pipeline.save_finding(task, Map.put(%{attrs | "key" => "made-up-rule"}, "checklist_rule", "lrn_none"))
  end

  test "a task with no worktree on disk raises with no commit", %{task: task, attrs: attrs} do
    {:ok, gone} = Pipeline.update_task(task, %{worktree_path: "/nonexistent/svf"})

    assert {:ok, %Finding{raised_in: nil}} =
             Pipeline.save_finding(gone, Map.new(attrs, fn {k, v} -> {String.to_existing_atom(k), v} end))
  end
end
