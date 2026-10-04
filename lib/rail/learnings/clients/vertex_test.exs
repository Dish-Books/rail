defmodule Rail.Learnings.Clients.VertexTest do
  use Rail.DataCase, async: true

  alias Rail.Learnings.Clients.Vertex

  test "embeds at the global endpoint under Goth's project, on its token, at 3072 dimensions" do
    stub(Rail, :goth_enabled?, fn -> true end)
    stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)
    stub(Goth.Config, :get, fn :project_id -> {:ok, "rail-testing"} end)

    Req.Test.expect(Vertex, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert conn.host == "aiplatform.googleapis.com"

      assert conn.request_path ==
               "/v1/projects/rail-testing/locations/global/publishers/google/models/gemini-embedding-001:predict"

      assert ["Bearer test_token"] = Plug.Conn.get_req_header(conn, "authorization")

      assert %{
               "instances" => [%{"content" => "Use the factory", "task_type" => "RETRIEVAL_DOCUMENT"}],
               "parameters" => %{"outputDimensionality" => 3072}
             } = Jason.decode!(body)

      Req.Test.json(conn, %{"predictions" => [%{"embeddings" => %{"values" => [0.5, 0.25]}}]})
    end)

    assert {:ok, [0.5, 0.25]} = Vertex.embed("Use the factory", "RETRIEVAL_DOCUMENT")
    assert Vertex.model() == "gemini-embedding-001"
  end

  test "an answer that is not an embedding is an error" do
    stub_vertex()
    Req.Test.stub(Vertex, &Req.Test.json(&1, %{"predictions" => []}))

    assert {:error, {:vertex_error, 200, %{"predictions" => []}}} = Vertex.embed("text", "RETRIEVAL_QUERY")
  end

  test "a request that never arrives is an error" do
    stub_vertex()
    Req.Test.stub(Vertex, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Req.TransportError{reason: :econnrefused}} = Vertex.embed("text", "RETRIEVAL_QUERY")
  end

  test "with Goth off it returns an error and sends nothing" do
    assert {:error, :goth_disabled} = Vertex.embed("Use the factory", "RETRIEVAL_DOCUMENT")
  end

  describe "Goth failing" do
    setup do
      stub(Rail, :goth_enabled?, fn -> true end)
      stub(Goth.Config, :get, fn :project_id -> {:ok, "rail-testing"} end)
      Req.Test.stub(Vertex, fn _conn -> flunk("a request was sent without a token") end)
      :ok
    end

    test "an exit fetching the token is an error, not a crash" do
      stub(Goth, :fetch, fn Rail.Goth -> exit(:timeout) end)
      assert {:error, {:goth_unavailable, :timeout}} = Vertex.embed("text", "RETRIEVAL_QUERY")

      stub(Goth, :fetch, fn Rail.Goth -> {:error, :refused} end)
      assert {:error, {:goth_unavailable, :refused}} = Vertex.embed("text", "RETRIEVAL_QUERY")
    end

    test "no project, or credentials that do not resolve, are errors" do
      stub(Goth, :fetch, fn Rail.Goth -> {:ok, %Goth.Token{token: "test_token"}} end)

      stub(Goth.Config, :get, fn :project_id -> :error end)
      assert {:error, :no_project_id} = Vertex.embed("text", "RETRIEVAL_QUERY")

      stub(Goth.Config, :get, fn :project_id -> raise "no credentials" end)
      assert {:error, {:goth_unavailable, %RuntimeError{}}} = Vertex.embed("text", "RETRIEVAL_QUERY")
    end
  end
end
