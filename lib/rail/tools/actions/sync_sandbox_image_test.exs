defmodule Rail.Tools.Actions.SyncSandboxImageTest do
  use Rail.DataCase, async: true
  use Oban.Testing, repo: Rail.Repo

  alias Rail.Tools
  alias Rail.Tools.Clients.Docker
  alias Rail.Tools.HostRegistry
  alias Rail.Tools.Workers.SyncSandboxImage

  setup do
    {:ok, host} = Tools.create_sandbox_host(system_scope(), %{name: "build-04", ssh_address: "rail@10.0.4.14"})
    # Stands in for the host's connection: Docker reaches it, and the copy's reports arrive here.
    {:ok, _owner} = Registry.register(HostRegistry, host.id, %{state: :connected, port: 1})
    %{host: host, tarball: Path.join([Rail.scratch_root(), "sandbox-images", "#{host.id}.tar"])}
  end

  test "exports Rail's image, loads it into the host reporting what was sent, and removes the tarball",
       %{host: host, tarball: tarball} do
    image = :binary.copy("layer", 500_000)

    Req.Test.stub(Docker, fn conn ->
      case {conn.method, conn.host, conn.request_path} do
        {"GET", "docker", "/images/get"} ->
          assert URI.decode_query(conn.query_string) == %{"names" => "rail-sandbox:latest"}
          Plug.Conn.send_resp(conn, 200, image)

        {"POST", "127.0.0.1", "/images/load"} ->
          {:ok, ^image, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
          Plug.Conn.send_resp(conn, 200, ~s({"stream":"Loaded image: rail-sandbox:latest\\n"}\n))

        {"GET", "127.0.0.1", "/info"} ->
          Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3})

        {"GET", _rail_or_host, "/images/rail-sandbox:latest/json"} ->
          Req.Test.json(conn, %{"Id" => "sha256:rail"})
      end
    end)

    assert :ok = Tools.sync_sandbox_image(host)

    assert_received {:"$gen_cast", {:image, {:copying, 0, nil}}}
    assert_received {:"$gen_cast", {:image, {:copying, 1_048_576, 2_500_000}}}
    assert_received {:"$gen_cast", {:image, {:copying, 2_500_000, 2_500_000}}}
    assert_received {:"$gen_cast", {:image, :current}}
    refute File.exists?(tarball)
  end

  test "a load Docker refuses inside its answer is a failed copy with Docker's reason", %{host: host, tarball: tarball} do
    Req.Test.stub(Docker, fn conn ->
      case conn.request_path do
        "/images/get" ->
          Plug.Conn.send_resp(conn, 200, "tarball")

        "/images/load" ->
          Plug.Conn.send_resp(
            conn,
            200,
            ~s({"errorDetail":{"message":"no space left on device"},"error":"no space left on device"})
          )
      end
    end)

    assert {:error, "no space left on device"} = Tools.sync_sandbox_image(host)
    assert_received {:"$gen_cast", {:image, {:failed, "no space left on device"}}}
    refute File.exists?(tarball)
  end

  test "names why a copy failed in words", %{host: host} do
    Req.Test.stub(Docker, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"message" => "No such image"})
    end)

    assert {:error, "No such image"} = Tools.sync_sandbox_image(host)

    Req.Test.stub(Docker, fn conn ->
      case conn.request_path do
        "/images/get" ->
          Plug.Conn.send_resp(conn, 200, "tarball")

        "/images/load" ->
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "archive/tar: invalid header"})
      end
    end)

    assert {:error, "archive/tar: invalid header"} = Tools.sync_sandbox_image(host)

    Req.Test.stub(Docker, fn conn ->
      case {conn.host, conn.request_path} do
        {"docker", "/images/get"} -> Plug.Conn.send_resp(conn, 200, "tarball")
        {"127.0.0.1", "/images/load"} -> Plug.Conn.send_resp(conn, 200, "")
        {"127.0.0.1", "/info"} -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3})
        {"127.0.0.1", "/images/rail-sandbox:latest/json"} -> Req.Test.json(conn, %{"Id" => "sha256:old"})
        {"docker", "/images/rail-sandbox:latest/json"} -> Req.Test.json(conn, %{"Id" => "sha256:rail"})
      end
    end)

    assert {:error, "The image still differs after loading it."} = Tools.sync_sandbox_image(host)

    Req.Test.stub(Docker, fn conn ->
      case {conn.host, conn.request_path} do
        {"docker", "/images/get"} -> Plug.Conn.send_resp(conn, 200, "tarball")
        {"127.0.0.1", "/images/load"} -> Plug.Conn.send_resp(conn, 200, "")
        {"127.0.0.1", "/info"} -> Req.Test.json(conn, %{"NCPU" => 16, "MemTotal" => 64 * 1024 ** 3})
        {"127.0.0.1", "/images/rail-sandbox:latest/json"} -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
        {"docker", "/images/rail-sandbox:latest/json"} -> Req.Test.json(conn, %{"Id" => "sha256:rail"})
      end
    end)

    assert {:error, "Docker answered 500."} = Tools.sync_sandbox_image(host)

    Req.Test.stub(Docker, fn conn ->
      case conn.request_path do
        "/images/get" -> Plug.Conn.send_resp(conn, 200, "tarball")
        "/images/load" -> Req.Test.transport_error(conn, :econnreset)
      end
    end)

    assert {:error, "connection reset by peer"} = Tools.sync_sandbox_image(host)

    stub(File, :stat, fn _path -> {:error, :enoent} end)
    assert {:error, ":enoent"} = Tools.sync_sandbox_image(host)
  end

  test "a host whose connection is down fails the copy as unreachable", %{host: host} do
    Registry.unregister(HostRegistry, host.id)
    Req.Test.stub(Docker, fn conn -> Plug.Conn.send_resp(conn, 200, "tarball") end)

    assert {:error, "The host is unreachable."} = Tools.sync_sandbox_image(host)
  end

  test "the job copies to a host still listed, one job per host at a time, and skips a removed one", %{host: host} do
    Req.Test.stub(Docker, fn conn -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{}) end)
    assert :ok = perform_job(SyncSandboxImage, %{host_id: host.id})
    assert_received {:"$gen_cast", {:image, {:copying, 0, nil}}}
    assert_received {:"$gen_cast", {:image, {:failed, "Docker answered 500."}}}

    {:ok, _first} = %{host_id: host.id} |> SyncSandboxImage.new() |> Oban.insert()
    {:ok, %Oban.Job{conflict?: true}} = %{host_id: host.id} |> SyncSandboxImage.new() |> Oban.insert()
    assert [_one] = all_enqueued(worker: SyncSandboxImage, args: %{host_id: host.id})

    {:ok, _removed} = Tools.remove_sandbox_host(system_scope(), host)
    assert :ok = perform_job(SyncSandboxImage, %{host_id: host.id})
    refute_received {:"$gen_cast", {:image, {:copying, 0, nil}}}
  end

  test "a host that does not answer the check after loading fails the copy as too slow", %{host: host} do
    Req.Test.stub(Docker, fn conn ->
      case conn.request_path do
        "/images/get" -> Plug.Conn.send_resp(conn, 200, "tarball")
        "/images/load" -> Plug.Conn.send_resp(conn, 200, "")
        "/info" -> Process.sleep(:infinity)
      end
    end)

    assert {:error, "The host did not answer in time."} = Tools.sync_sandbox_image(host)
  end
end
