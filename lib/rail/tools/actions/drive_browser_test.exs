defmodule Rail.Tools.Actions.DriveBrowserTest do
  use Rail.DataCase, async: true

  alias Rail.Tools

  # The page is a form the stubs read and change, so these are about the loop;
  # what Chrome does with an action is `ExecuteBrowserActionTest`'s.
  setup do
    {:ok, session} =
      Agent.start_link(fn ->
        %{title: "New bill", labels: [{"amount", "Amount"}], values: %{"amount" => ""}, location: nil}
      end)

    # Shaped like `priv/browser/snapshot.js`: a field once to type into and once to
    # click, a dropdown once per option it is not already set to.
    stub(Tools, :observe_browser, fn session ->
      form = Agent.get(session, & &1)

      fields =
        Enum.flat_map(form.labels, fn {node, label} ->
          field = %{"node" => node, "role" => "textbox", "label" => label, "value" => form.values[node]}

          [Map.put(field, "kind", "fill"), Map.merge(field, %{"kind" => "click", "label" => "Open #{label}"})]
        end)

      location =
        for {value, label} <- [{"memorial", "Bori Memorial"}, {"montrose", "Bori Montrose"}],
            is_binary(form.location) and label != form.location do
          %{
            "node" => "location",
            "role" => "combobox",
            "label" => "Location → #{label}",
            "kind" => "select",
            "value" => value,
            "current_value" => form.location
          }
        end

      save = %{"node" => "save", "role" => "button", "label" => "Save", "kind" => "click", "value" => ""}
      wait = %{"id" => "wait", "kind" => "wait", "label" => "Wait for the page to update"}

      {:ok,
       %{
         "url" => "file:///bill.html",
         "title" => form.title,
         "text" => form.title,
         "actions" => fields ++ [save | location] ++ [wait],
         "marker" => :erlang.phash2(form)
       }}
    end)

    # Typing sets the field, Save puts the amount in the title, a dropdown takes the option chosen.
    stub(Tools, :execute_browser_action, fn session, action, text ->
      Agent.update(session, fn form ->
        case action do
          %{"kind" => "fill", "node" => node} -> put_in(form, [:values, node], text)
          %{"node" => "save"} -> %{form | title: "Saved #{form.values["amount"]}"}
          %{"kind" => "select", "label" => "Location → " <> label} -> %{form | location: label}
          _other -> form
        end
      end)

      {:ok, action["label"]}
    end)

    # The choice is checked against what was actually offered, so a test builds
    # its answers from the question rather than from numbers it guessed.
    choosing = fn questions, name, choice ->
      true = choice in Map.keys(questions[name]["criteria"])

      %{"choice" => choice, "confidence" => 1.0}
    end

    # TypeSafe is asked what to do; every test says what it answers. Answering is
    # a function of the question so a test does not have to know the element
    # numbering in advance.
    answering = fn answers ->
      Req.Test.stub(Rail.TypeSafe, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"questions" => questions, "state" => state} = Jason.decode!(body)

        Req.Test.json(conn, %{"answers" => answers.(questions, state)})
      end)
    end

    %{session: session, answering: answering, choosing: choosing}
  end

  test "carries out an instruction and says what it did", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    assert {:ok, receipt} = Tools.drive_browser(session, "click Save")
    assert [%{operation: "CLICK", action: "Save"} | _rest] = receipt.executed
  end

  test "types only what the caller supplied", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, _receipt} = Tools.drive_browser(session, "fill in the amount", text: "1234.50")

    assert Agent.get(session, & &1.values["amount"]) == "1234.50"
  end

  # The one thing a decision cannot supply. Rather than inventing a value, the
  # step stops and hands the question back.
  test "stops and asks when a field needs a value nobody gave it", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, %{outcome: {:needs_text, "Amount"}, executed: []}} =
             Tools.drive_browser(session, "fill in the amount")
  end

  test "several actions for one instruction", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))
      done = state["already_done"]

      operation =
        cond do
          "Save" in done -> "DONE"
          "Amount" in done -> "CLICK"
          true -> "TYPE_TEXT"
        end

      %{
        "operation" => choosing.(questions, "operation", operation),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", save["index"])
      }
    end)

    assert {:ok, %{title: "Saved 99.00", executed: executed}} =
             Tools.drive_browser(session, "enter the amount and save", text: "99.00")

    assert [%{operation: "TYPE_TEXT"}, %{operation: "CLICK", action: "Save"}] = executed
  end

  test "reports what the page cannot do", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, _state ->
      %{
        "operation" => choosing.(questions, "operation", "BLOCKED"),
        "click_target" => choosing.(questions, "click_target", "1"),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    assert {:ok, %{outcome: :blocked, executed: []}} = Tools.drive_browser(session, "delete the invoice")
  end

  test "a pass is told about each action as it happens", %{session: session, answering: answering, choosing: choosing} do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    watcher = self()

    assert {:ok, _receipt} =
             Tools.drive_browser(session, "click Save", on_action: &send(watcher, {:acted, &1}))

    assert_received {:acted, %{operation: "CLICK", action: "Save"}}
  end

  # The gap between reading a page and acting on it is real. Nothing was done, so
  # the recovery is the whole of it: read the page again and decide afresh.
  test "a page that moved under the decision is read again rather than given up on", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))
      operation = if state["already_done"] == [], do: "CLICK", else: "DONE"

      %{
        "operation" => choosing.(questions, "operation", operation),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    expect(Tools, :execute_browser_action, fn _session, _action, _text -> {:error, {:refused, "gone", nil}} end)
    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :done, executed: [%{operation: "CLICK", action: "Save"}]}} =
             Tools.drive_browser(session, "click Save")
  end

  test "an action the browser refuses stops the instruction", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:error, :no_text_to_type} end)

    assert {:error, :no_text_to_type} = Tools.drive_browser(session, "click Save")
  end

  # A page navigating when it is read again has nothing to read, and the step
  # that already landed is still worth reporting.
  test "a page that cannot be read again still reports what was done", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    {:ok, page} = Tools.observe_browser(session)

    expect(Tools, :observe_browser, fn _session -> {:ok, page} end)
    expect(Tools, :observe_browser, fn _session -> {:error, :navigating} end)
    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :done, error: :navigating, executed: [%{action: "Save"}]}} =
             Tools.drive_browser(session, "click Save")
  end

  # A control that refuses twice over a page that has not moved is not a race
  # being lost, it is the page's answer - and what refused it is the finding.
  test "a control that keeps refusing stops the instruction and says why", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text ->
      {:error, {:refused, "covered", ~s(div "Saving")}}
    end)

    refused = {:refused, %{label: "Save", why: "covered", by: ~s(div "Saving")}}

    assert {:ok, %{outcome: ^refused, executed: []}} = Tools.drive_browser(session, "click Save")
  end

  # A step that leaves the page as it found it, chosen again, is a step doing
  # something other than what was asked.
  test "the same step over a page that did not move stops after the second", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      save = Enum.find(state["elements"], &(&1["label"] == "Save"))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", save["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "save"} end)

    assert {:ok, %{outcome: :not_moving, executed: executed}} = Tools.drive_browser(session, "click Save")
    assert length(executed) == 1
  end

  # An instruction that keeps finding something else to do is stopped by the
  # budget rather than by a page that stopped changing.
  test "an instruction that never finishes is stopped by its budget", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    # Alternating, so no step is ever the one just taken and only the budget can
    # end this. The count is its own because what the decider is told about what
    # has been done stops growing after ten.
    taken = :counters.new(1, [])

    answering.(fn questions, state ->
      :counters.add(taken, 1, 1)
      wanted = if rem(:counters.get(taken, 1), 2) == 0, do: "Save", else: "Amount"
      target = Enum.find(state["elements"], &(&1["label"] == wanted))

      %{
        "operation" => choosing.(questions, "operation", "CLICK"),
        "click_target" => choosing.(questions, "click_target", target["index"]),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    stub(Tools, :execute_browser_action, fn _session, _action, _text -> {:ok, "acted"} end)

    assert {:ok, %{outcome: :too_many_actions, executed: executed}} = Tools.drive_browser(session, "click about")
    assert length(executed) == 30
  end

  # A dropdown offers every option but the one it is set to, so a decider stuck
  # on it sets it one way and then back again. Every step changes the page and
  # names a different option, so no single step looks stuck - the page coming
  # back to where it has already been is what does.
  test "a page set one way and back again is stopped as going in circles", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    Agent.update(session, &%{&1 | location: ""})

    answering.(fn questions, _state ->
      offered = questions["select_target"]["criteria"] |> Map.keys() |> Enum.sort() |> hd()

      %{
        "operation" => choosing.(questions, "operation", "SELECT"),
        "select_target" => choosing.(questions, "select_target", offered),
        "click_target" => choosing.(questions, "click_target", "1"),
        "type_text_target" => choosing.(questions, "type_text_target", "1")
      }
    end)

    assert {:ok, %{outcome: :going_in_circles, executed: executed}} =
             Tools.drive_browser(session, "the line has a GL account")

    assert length(executed) < 10
    assert Enum.all?(executed, &(&1.operation == "SELECT"))
  end

  # A single value is for one field. Typed, it is used up: the decider choosing
  # the next field along is how a price ends up in the notes.
  test "a single value is typed into one field and no other", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    Agent.update(session, &%{&1 | labels: [{"notes", "Notes"} | &1.labels], values: Map.put(&1.values, "notes", "")})

    answering.(fn questions, state ->
      wanted = if state["already_done"] == [], do: "Amount", else: "Notes"
      field = Enum.find(state["elements"], &(&1["label"] == wanted))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", field["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, %{outcome: {:needs_text, "Notes"}, executed: [%{action: "Amount", text: "2724.04"}]}} =
             Tools.drive_browser(session, "the unit price is 2724.04", text: "2724.04")

    assert Agent.get(session, & &1.values["notes"]) == ""
  end

  # Chosen again for the field it already went into, the typing is done rather
  # than done twice.
  test "a single value is typed once, however often its field is chosen", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))

      %{
        "operation" => choosing.(questions, "operation", "TYPE_TEXT"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, %{outcome: :done, executed: [%{action: "Amount"}]}} =
             Tools.drive_browser(session, "the amount is 2724.04", text: "2724.04")
  end

  # A caller that named every field is filling a form, and each field is looked
  # up however many have been typed before it.
  test "values fill one field after another", %{session: session, answering: answering, choosing: choosing} do
    Agent.update(session, &%{&1 | labels: [{"notes", "Notes"} | &1.labels], values: Map.put(&1.values, "notes", "")})

    answering.(fn questions, state ->
      {operation, wanted} =
        case length(state["already_done"]) do
          0 -> {"TYPE_TEXT", "Amount"}
          1 -> {"TYPE_TEXT", "Notes"}
          _done -> {"DONE", "Amount"}
        end

      field = Enum.find(state["elements"], &(&1["label"] == wanted))

      %{
        "operation" => choosing.(questions, "operation", operation),
        "type_text_target" => choosing.(questions, "type_text_target", field["index"]),
        "click_target" => choosing.(questions, "click_target", "1")
      }
    end)

    assert {:ok, %{outcome: :done, executed: [%{action: "Amount"}, %{action: "Notes"}]}} =
             Tools.drive_browser(session, "the bill is filled in", values: %{"Amount" => "12", "Notes" => "Produce"})
  end

  # The caller keys its values by the field as the page labels it, so one call
  # fills a form - and a label the page writes differently still matches.
  test "values are matched to the field they were keyed for", %{
    session: session,
    answering: answering,
    choosing: choosing
  } do
    answering.(fn questions, state ->
      amount = Enum.find(state["elements"], &(&1["label"] == "Amount"))
      done? = state["already_done"] != []

      %{
        "operation" => choosing.(questions, "operation", if(done?, do: "DONE", else: "TYPE_TEXT")),
        "click_target" => choosing.(questions, "click_target", "1"),
        "type_text_target" => choosing.(questions, "type_text_target", amount["index"])
      }
    end)

    assert {:ok, %{executed: [%{text: "12.50"}]}} =
             Tools.drive_browser(session, "the amount is 12.50", values: %{"Amount" => "12.50"})

    assert {:ok, %{executed: [%{text: "13.50"}]}} =
             Tools.drive_browser(session, "the amount is 13.50", values: %{"amount field" => "13.50"})
  end

  # An answer Rail did not offer never reaches the page.
  test "refuses a decision that names something that was not offered", %{session: session} do
    Req.Test.stub(Rail.TypeSafe, fn conn ->
      Req.Test.json(conn, %{
        "answers" => %{
          "operation" => %{"choice" => "FLY", "confidence" => 1.0}
        }
      })
    end)

    assert {:error, {:type_safe_unusable_answer, :operation, :choice_not_offered}} =
             Tools.drive_browser(session, "click Save")
  end
end
