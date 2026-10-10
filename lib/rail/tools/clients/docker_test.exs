defmodule Rail.Tools.Clients.DockerTest do
  use Rail.DataCase, async: true

  alias Rail.Tools.Clients.Docker

  test "reads what Rail's machine has over its socket" do
    Req.Test.expect(Docker, fn conn ->
      assert {conn.method, conn.host, conn.request_path} == {"GET", "docker", "/info"}
      Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 68_719_476_736})
    end)

    assert {:ok, %{"NCPU" => 16, "MemTotal" => 68_719_476_736}} = Docker.info(nil)
  end

  test "reaches a connected host through the loopback port its connection bridges, and a host with none not at all" do
    host_id = "hst_#{System.unique_integer([:positive])}"
    assert {:error, :host_unreachable} = Docker.info(host_id)

    {:ok, _owner} = Registry.register(Rail.Tools.HostRegistry, host_id, %{state: :connected, port: 40_123})

    Req.Test.expect(Docker, fn conn ->
      assert {conn.host, conn.port, conn.request_path} == {"127.0.0.1", 40_123, "/images/rail-sandbox:latest/json"}
      Req.Test.json(conn, %{"Id" => "sha256:rail"})
    end)

    assert {:ok, %{"Id" => "sha256:rail"}} = Docker.inspect_image(host_id, "rail-sandbox:latest")
  end

  test "exports an image to a file, and loads one reporting the bytes sent" do
    path = Path.join(System.tmp_dir!(), "image-#{System.unique_integer([:positive])}.tar")
    on_exit(fn -> File.rm(path) end)
    image = :binary.copy("x", 1_500_000)

    Req.Test.expect(Docker, 2, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/images/get"} ->
          assert conn.query_string == "names=rail-sandbox%3Alatest"
          Plug.Conn.send_resp(conn, 200, image)

        {"POST", "/images/load"} ->
          assert conn.query_string == "quiet=true"
          assert Plug.Conn.get_req_header(conn, "content-type") == ["application/x-tar"]
          {:ok, ^image, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          Plug.Conn.send_resp(conn, 200, ~s({"stream":"Loaded image: rail-sandbox:latest\n"}\n))
      end
    end)

    assert {:ok, _written} = Docker.export_image(nil, "rail-sandbox:latest", path)
    assert File.read!(path) == image

    test_pid = self()
    assert {:ok, _output} = Docker.load_image(nil, path, &send(test_pid, {:sent, &1}))
    assert_received {:sent, 1_048_576}
    assert_received {:sent, 1_500_000}
  end

  test "a load Docker answers 200 to but could not do is an error" do
    path = Path.join(System.tmp_dir!(), "image-#{System.unique_integer([:positive])}.tar")
    File.write!(path, "not a tarball")
    on_exit(fn -> File.rm(path) end)

    Req.Test.expect(Docker, fn conn ->
      Plug.Conn.send_resp(
        conn,
        200,
        ~s(not json\n{"errorDetail":{"message":"unexpected EOF"},"error":"unexpected EOF"}\n)
      )
    end)

    assert {:error, {:load_failed, "unexpected EOF"}} = Docker.load_image(nil, path, fn _sent -> :ok end)
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

  test "lists a container's processes with what each holds in memory" do
    Req.Test.expect(Docker, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/containers/c0ffee/top"}
      assert URI.decode_query(conn.query_string) == %{"ps_args" => "-eo pid,ppid,rss,comm"}
      Req.Test.json(conn, %{"Titles" => ["PID", "PPID", "RSS", "COMMAND"], "Processes" => [["7", "1", "2048", "claude"]]})
    end)

    assert {:ok, %{"Processes" => [["7", "1", "2048", "claude"]]}} = Docker.top("c0ffee")
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

  test "runs a command in a running container and reads back what it printed and how it exited" do
    Req.Test.expect(Docker, 3, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/containers/c0ffee/exec"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          assert %{
                   "Cmd" => ["/bin/sh", "-c", "scripts/seed"],
                   "Env" => ["RAIL_PORT_BASE=20300"],
                   "WorkingDir" => "/srv/worktree",
                   "User" => "1000:1000",
                   "AttachStdout" => true,
                   "AttachStderr" => true
                 } = Jason.decode!(body)

          conn |> Plug.Conn.put_status(201) |> Req.Test.json(%{"Id" => "exec1"})

        {"POST", "/exec/exec1/start"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert %{"Detach" => false, "Tty" => false} = Jason.decode!(body)
          out = "Signed up a@rail.test\n"
          err = "warning\n"

          conn
          |> Plug.Conn.put_resp_content_type("application/vnd.docker.multiplexed-stream")
          |> Plug.Conn.send_resp(
            200,
            <<1, 0, 0, 0, byte_size(out)::32, out::binary, 2, 0, 0, 0, byte_size(err)::32, err::binary>>
          )

        {"GET", "/exec/exec1/json"} ->
          Req.Test.json(conn, %{"ExitCode" => 3, "Running" => false})
      end
    end)

    assert {:ok, %{output: "Signed up a@rail.test\nwarning\n", exit_code: 3}} =
             Docker.exec_in_container(
               "c0ffee",
               ["/bin/sh", "-c", "scripts/seed"],
               %{"RAIL_PORT_BASE" => "20300"},
               "/srv/worktree"
             )
  end

  test "says what Docker refused, and what never reached it" do
    Req.Test.expect(Docker, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such container: gone"})
    end)

    assert {:error, {:docker_api_error, 404, %{"message" => "No such container: gone"}}} =
             Docker.inspect_container("gone")

    Req.Test.expect(Docker, &Req.Test.transport_error(&1, :enoent))

    assert {:error, %Req.TransportError{reason: :enoent}} = Docker.info(nil)
  end
end
