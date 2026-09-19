defmodule Rail.TypeSafe.ClientTest do
  use ExUnit.Case, async: true

  alias Rail.TypeSafe

  @state %{page: %{url: "/bills/new", title: "Bill"}, elements: []}

  @questions %{
    operation: %{type: "choice", criteria: %{"CLICK" => "Click something", "DONE" => "Finished"}},
    click_target: %{type: "choice", criteria: %{"1" => "[1] Save", "2" => "[2] Cancel"}}
  }

  # Every refusal below is an answer that would otherwise become a click, so each
  # test differs only in the answer TypeSafe gives back.
  setup do
    answering = fn operation ->
      Req.Test.expect(TypeSafe, fn conn -> Req.Test.json(conn, %{"answers" => %{"operation" => operation}}) end)

      TypeSafe.ask(@state, %{operation: @questions.operation})
    end

    %{answering: answering}
  end

  test "answers every question from one round trip" do
    Req.Test.expect(TypeSafe, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      sent = Jason.decode!(body)

      assert sent["model"] == "jev-latest"
      assert sent["state"]["page"]["url"] == "/bills/new"
      assert sent["questions"] |> Map.keys() |> Enum.sort() == ["click_target", "operation"]

      Req.Test.json(conn, %{
        "answers" => %{
          "operation" => %{"choice" => "CLICK", "confidence" => 0.9, "probabilities" => %{"CLICK" => 0.8}},
          "click_target" => %{"choice" => "1", "confidence" => 0.7}
        }
      })
    end)

    # What TypeSafe says beyond the choice and its confidence is not carried, so
    # a caller cannot come to depend on a shape Rail does not check.
    assert {:ok, %{operation: %{choice: "CLICK", confidence: 0.9}, click_target: %{choice: "1", confidence: 0.7}}} =
             TypeSafe.ask(@state, @questions)
  end

  test "asking nothing costs nothing" do
    assert {:ok, %{}} = TypeSafe.ask(@state, %{})
  end

  # The choice becomes an element to click, so it has to be one Rail offered.
  # That is the whole of what is checked on the way back.
  test "refuses a choice that was never offered", %{answering: answering} do
    assert {:error, {:type_safe_unusable_answer, :operation, :choice_not_offered}} =
             answering.(%{"choice" => "SCROLL_DOWN", "confidence" => 1.0})
  end

  test "refuses a question that came back unanswered" do
    Req.Test.expect(TypeSafe, fn conn -> Req.Test.json(conn, %{"answers" => %{}}) end)

    assert {:error, {:type_safe_unusable_answer, _name, :no_answer}} = TypeSafe.ask(@state, @questions)
  end

  # Worth another attempt, unlike everything else.
  test "says when TypeSafe is the thing that is wrong" do
    Req.Test.expect(TypeSafe, fn conn -> Plug.Conn.send_resp(conn, 503, "upstream is down") end)

    assert {:error, {:type_safe_unavailable, 503, "upstream is down"}} = TypeSafe.ask(@state, @questions)
  end

  test "says when the answer is not the shape agreed" do
    Req.Test.expect(TypeSafe, fn conn -> Req.Test.json(conn, %{"something" => "else"}) end)

    assert {:error, {:type_safe_unusable_response, 200, _detail}} = TypeSafe.ask(@state, @questions)
  end

  test "says when it could not be reached at all" do
    Req.Test.expect(TypeSafe, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, {:type_safe_unavailable, :transport, _message}} = TypeSafe.ask(@state, @questions)
  end
end
