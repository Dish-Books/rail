defmodule Rail.Tools.Clients.DockerTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Clients.Docker

  test "reads what the machine has" do
    Req.Test.expect(Docker, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/info"}
      Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 68_719_476_736})
    end)

    assert {:ok, %{"NCPU" => 16, "MemTotal" => 68_719_476_736}} = Docker.info()
  end

  test "creates a container named and labelled for its process" do
    Req.Test.expect(Docker, fn conn ->
      assert {conn.method, conn.request_path, conn.query_string} ==
               {"POST", "/containers/create", "name=rail-proc_1"}

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert %{"Image" => "rail-sandbox:latest", "Labels" => %{"dev.railai.sandbox" => "proc_1"}} = Jason.decode!(body)
      conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "c0ffee"})
    end)

    assert {:ok, %{"Id" => "c0ffee"}} = Docker.create_container("proc_1", %{"Image" => "rail-sandbox:latest"})
  end

  test "starts, stops and removes a container" do
    Req.Test.expect(Docker, 4, fn conn ->
      case {conn.method, conn.request_path, conn.query_string} do
        {"POST", "/containers/c0ffee/start", ""} -> Plug.Conn.send_resp(conn, 204, "")
        {"POST", "/containers/c0ffee/stop", "t=5"} -> Plug.Conn.send_resp(conn, 204, "")
        {"DELETE", "/containers/c0ffee", ""} -> Plug.Conn.send_resp(conn, 204, "")
        {"DELETE", "/containers/c0ffee", "force=true"} -> Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    assert {:ok, _started} = Docker.start_container("c0ffee")
    assert {:ok, _stopped} = Docker.stop_container("c0ffee", 5)
    assert {:ok, _removed} = Docker.remove_container("c0ffee")
    # A running container is only removed by force, which kills it first.
    assert {:ok, _killed} = Docker.remove_container("c0ffee", force: true)
  end

  test "inspects a container and reads its usage once" do
    Req.Test.expect(Docker, 2, fn conn ->
      case {conn.request_path, conn.query_string} do
        {"/containers/c0ffee/json", ""} -> Req.Test.json(conn, %{"State" => %{"Running" => true}})
        {"/containers/c0ffee/stats", "stream=false"} -> Req.Test.json(conn, %{"memory_stats" => %{"usage" => 1}})
      end
    end)

    assert {:ok, %{"State" => %{"Running" => true}}} = Docker.inspect_container("c0ffee")
    assert {:ok, %{"memory_stats" => %{"usage" => 1}}} = Docker.stats("c0ffee")
  end

  test "lists every container carrying a label, running or not" do
    Req.Test.expect(Docker, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert %{"all" => "true", "filters" => filters} = conn.query_params
      assert Jason.decode!(filters) == %{"label" => ["dev.railai.sandbox"]}
      Req.Test.json(conn, [%{"Id" => "c0ffee"}])
    end)

    assert {:ok, [%{"Id" => "c0ffee"}]} = Docker.list_containers("dev.railai.sandbox")
  end

  test "says what Docker refused, and what never reached it" do
    Req.Test.expect(Docker, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container: gone"})
    end)

    assert {:error, {:docker_api_error, 404, %{"message" => "No such container: gone"}}} =
             Docker.inspect_container("gone")

    Req.Test.expect(Docker, &Req.Test.transport_error(&1, :enoent))

    assert {:error, %Req.TransportError{reason: :enoent}} = Docker.info()
  end
end
